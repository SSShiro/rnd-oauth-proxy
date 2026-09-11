# Pomerium — path-based RBAC (service2 / service2/admin)

Один инстанс Pomerium на порту **5182** (HTTPS), защищает единственный домен
`service2.localhost` с двумя уровнями доступа на одном и том же хосте:

| Путь | Требуемая роль |
|---|---|
| `/` (и всё остальное) | `Team2_Users` |
| `/admin` | `Team2_Admins` |

## 1. Архитектура

В отличие от gogatekeeper (один `resources`-список внутри одного инстанса) и
от oauth2-proxy/Traefik-паттерна (нужно несколько отдельных инстансов auth-сервиса
на каждую роль), Pomerium решает такую задачу **декларативно внутри одного
инстанса** через несколько `routes` с одинаковым `from`, но разным `prefix`:

```yaml
routes:
  - from: https://service2.localhost:5182
    prefix: /admin
    to: http://service2-backend:80
    policy:
      - allow: { and: [ { claim/roles: Team2_Admins } ] }

  - from: https://service2.localhost:5182
    to: http://service2-backend:80
    policy:
      - allow: { and: [ { claim/roles: Team2_Users } ] }
```

**Подтверждено тестами: Pomerium сам выбирает более специфичный route по
`prefix` (аналог longest-prefix-match) — порядок объявления в списке `routes`
роли не играет.** Запрос на `/admin` уходит именно в первый route (политика
`Team2_Admins`), а не во второй, даже если поменять их местами (проверено
отдельно — переставил routes местами, поведение не изменилось). Это выгодно
отличается от gogatekeeper, где `resources` матчатся по порядку объявления и
специфичное правило обязано стоять раньше catch-all.

Как и в основном стенде (`proxies/pomerium/`), у Pomerium отдельный
`authenticate_service_url` (`https://authenticate.service2.localhost:5182`) —
единая точка логина для всех routes этого инстанса, и CSRF/PKCE-cookie
всегда ставятся с флагом `Secure` (жёстко в коде), поэтому TLS обязателен
даже для локального теста — используется самоподписанный сертификат
(`certs/tls.crt`, `certs/tls.key`, SAN покрывает `*.localhost`) и `curl -k`.

## 2. Ключевая находка: синтаксис `claim/roles` для массива

В нашем токене claim `roles` — **массив** строк (`["Team2_Users", "Team2_Admins"]`
у team2admin). Официальная документация Pomerium Policy Language не
описывает явно семантику `claim/<name>: <value>` для массивовых claim'ов.

**Результат эмпирической проверки: простейший синтаксис `claim/roles: Team2_Admins`
работает сразу и корректно, реализуя семантику "содержит значение"
(array-contains), без необходимости `has`/`in`/другого специального
оператора.** Подтверждено дважды: `team2user` (roles=`[Team2_Users]`) получил
`403` на `/admin` (`claim/roles: Team2_Admins` не совпал) и `200` на `/`
(`claim/roles: Team2_Users` совпал); `team2admin` (roles=`[Team2_Users,
Team2_Admins]`) получил `200` на обоих путях. Перебирать альтернативные
варианты синтаксиса (`{has: ...}`, `{in: [...]}`) не понадобилось.

## 3. Конфигурация — ключевые поля

| Поле | Значение | Смысл |
|---|---|---|
| `address` | `:5182` | Порт data-plane |
| `certificate_file`/`certificate_key_file` | `certs/tls.crt`/`tls.key` | Самоподписанный TLS-сертификат (обязателен, см. выше) |
| `authenticate_service_url` | `https://authenticate.service2.localhost:5182` | Общий authenticate-hostname для всех routes этого инстанса |
| `idp_provider_url` | `http://keycloak:8080/realms/corp-sso` | Единый issuer — и для discovery, и для backend-вызовов (структурно защищено от hostname-рассинхронизации, см. находку про vouch-proxy в основном RND) |
| `idp_client_id`/`idp_client_secret` | `pomerium-rbac-client` / `pomerium-rbac-secret-CHANGEME` | |
| `databroker_storage_type: file` + `databroker_storage_connection_string` | `file:///pomerium/data/databroker` | Файловое хранилище сессий, без внешней БД — годится только для одного инстанса |
| `routes[].prefix` | `/admin` | Ограничивает route конкретным префиксом пути |
| `routes[].policy[].allow.and[].claim/roles` | `Team2_Admins` / `Team2_Users` | RBAC-правило по claim из токена |
| `pass_identity_headers: true` | | Пробрасывает `X-Pomerium-Claim-*` апстриму (не проверено на приёме на backend — см. ограничения) |

## 4. Результаты тестов

Полная матрица прогнана через `scripts/test-oidc-login.sh` (для логина) +
ручной `curl` для повторных запросов той же cookie-сессией.

| № | Сценарий | Команда (кратко) | Ожидание | Результат |
|---|---|---|---|---|
| 1 | Без сессии → `/` | `curl -sk https://service2.localhost:5182/` | 302 на Keycloak | **ПРОЙДЕН** — `HTTP 302`, `Location: https://authenticate.service2.localhost:5182/.pomerium/sign_in?...` |
| 2 | `team2user` → `/` | `test-oidc-login.sh ... team2user 'Team2User12345!' -k` | 200, "Team2_Users" | **ПРОЙДЕН** — `HTTP 200`, найден текст |
| 3 | `team2user` (та же сессия) → `/admin/` | `curl -sk -b <jar> https://service2.localhost:5182/admin/` | Отказ | **ПРОЙДЕН** — `HTTP 403 Forbidden` |
| 4 | `team2admin` → `/` | `test-oidc-login.sh ... team2admin 'Team2Admin12345!' -k` | 200 | **ПРОЙДЕН** — `HTTP 200` |
| 5 | `team2admin` (та же сессия) → `/admin/` | `curl -sk -b <jar> https://service2.localhost:5182/admin/` | 200, "Team2_Admins" | **ПРОЙДЕН** — `HTTP 200`, найден текст |
| 6 | `testuser` (без ролей Team2_*) → `/` | `test-oidc-login.sh ... testuser 'Test12345!' -k` | Отказ | **ПРОЙДЕН** — `HTTP 403 Forbidden` |

Все 6/6 пройдены.

## 5. Ограничения и нюансы

- **TLS обязателен** — см. раздел 1, это не опция, а жёсткое требование
  Pomerium (Secure-флаг на CSRF-cookie нельзя отключить конфигурацией).
- **Отдельный authenticate-hostname** — в реальном деплое это означает
  дополнительную DNS-запись/сертификат помимо самого домена приложения.
- **`/admin` без завершающего слэша редиректит на `/admin/` с утечкой
  внутреннего hostname backend'а в заголовке `Location`** (`Location:
  http://service2-backend/admin/` вместо `https://service2.localhost:5182/admin/`).
  Это поведение самого `service2-backend` (стандартный nginx-редирект на
  каталог с индексом, `$scheme://$http_host` резолвится в internal
  Docker-имя, т.к. backend не настроен доверять `X-Forwarded-Host`/`Proto`)
  — **не специфично для Pomerium**, повторится и на других прокси этого
  RBAC-сценария, использующих тот же общий backend. В тестах выше
  использовался `/admin/` (с слэшем) в обход редиректа; сам backend вне
  зоны ответственности этой директории, не правил.
- **`pass_identity_headers`/`X-Pomerium-Claim-*` на приёме не проверялись** —
  аналогично основному RND-стенду (`proxies/pomerium/`), фронтовой Envoy
  внутри Pomerium исторически фильтрует нестандартные response-заголовки
  при попытке эхо-проверки через `add_header` на backend, поэтому факт
  доставки claims-заголовков на upstream остаётся неподтверждённым этим
  методом (сама авторизация при этом работает корректно и независимо от
  этого проброса).
- **Синтаксис `claim/<name>` для массивов** — работает как "contains" при
  простом сравнении со скалярным значением (см. раздел 2); официальная
  документация это явно не описывает, вывод сделан эмпирически.
