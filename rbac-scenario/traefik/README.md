# RBAC-сценарий: Traefik OSS + два инстанса oauth2-proxy

Реализация path-based RBAC (`service2` → роль `Team2_Users`, `service2/admin`
→ роль `Team2_Admins`) поверх Traefik OSS. Порт **5187**.

## 1. Архитектура

У Traefik OSS нет нативного OIDC/RBAC middleware (нативный OIDC — функция
только платного Traefik Hub, см. основной стенд `proxies/traefik/`). Чтобы
получить path-based RBAC, здесь используются **два независимых инстанса
oauth2-proxy**, каждый со своим `--allowed-group`, и Traefik маршрутизирует
запрос к нужному через два разных `router` (по `PathPrefix`) с разными
`forwardAuth` middleware:

```
                         ┌─ PathPrefix(/admin)  ──► oauth2-proxy-...-admins (--allowed-group=Team2_Admins) ─┐
клиент ──► Traefik:5187 ─┤                                                                                   ├─► service2-backend:80
                         └─ PathPrefix(/)        ──► oauth2-proxy-...-users  (--allowed-group=Team2_Users)  ─┘

  + PathPrefix(/oauth2-admins/) ──► напрямую в admins-инстанс (его собственный OAuth callback)
  + PathPrefix(/oauth2-users/)  ──► напрямую в users-инстанс  (его собственный OAuth callback)
```

Каждый oauth2-proxy запущен с `--upstream=static://202` (forward-auth
режим — сам не проксирует, только отвечает 202/401/302) и своим
`--proxy-prefix` (`/oauth2-users` и `/oauth2-admins` соответственно), чтобы
их callback-пути НЕ пересекались на одном домене `service2.localhost:5187`
(у обоих был бы одинаковый `/oauth2/callback`, что несовместимо с
единственным внешним хостом). `forwardAuth.address` указывает на КОРЕНЬ
`/` каждого инстанса, а не на `/oauth2/auth` — тот endpoint всегда отдаёт
голый 401 без `Location` (известная грабля из основного стенда), а нужен
полноценный 302 на Keycloak при отсутствии сессии.

**Важная находка:** `--oidc-groups-claim=roles` заставляет oauth2-proxy
неявно добавить в запрос авторизации OAuth-scope `groups` (в дополнение к
`openid email profile`). В нашем realm нет client scope с именем `groups`
(роли приходят напрямую через protocol mapper, без обёртки в scope) —
Keycloak отвечает `invalid_scope`. Исправляется явным
`--scope="openid email profile"`, который переопределяет список
запрашиваемых scope целиком.

## 2. Конфигурация

- `docker-compose.yml` — Traefik (`traefik-rbac`, порт 5187 + 5287 dashboard)
  и два инстанса oauth2-proxy.
- `dynamic.yml` — 4 роутера (`admin-route`, `root-route`,
  `oauth2-users-callback`, `oauth2-admins-callback`) и 2 forwardAuth
  middleware.
- `traefik.yml` — статическая конфигурация (entryPoint `:80`, file-provider).

Ключевые CLI-флаги обоих oauth2-proxy инстансов:
```
--upstream=static://202
--proxy-prefix=/oauth2-users   (или /oauth2-admins)
--oidc-groups-claim=roles
--scope=openid email profile
--allowed-group=Team2_Users    (или Team2_Admins)
--set-xauthrequest=true        # отдаёт X-Auth-Request-Groups для отладки
```

## 3. Результаты тестов (реально выполнено)

| # | Сценарий | Ожидание | Результат |
|---|---|---|---|
| 1 | Без сессии → `GET /` | 302 на Keycloak | ✅ `curl -o /dev/null -w "%{http_code}"` → `302` |
| 2 | `team2user` → `GET /` | 200, "Team2_Users" | ✅ `X-Auth-Request-Groups: Team2_Users` в ответе |
| 3 | `team2user` (та же сессия) → `GET /admin` | Отказ | ✅ SSO-сессия Keycloak подхватилась автоматически (без повторного пароля) для admins-инстанса, но `--allowed-group=Team2_Admins` вернул **403 Forbidden** — роли не хватило |
| 4 | `team2admin` → `GET /` | 200 | ✅ `X-Auth-Request-Groups: Team2_Users,Team2_Admins` |
| 5 | `team2admin` (та же сессия) → `GET /admin` | 200, "Team2_Admins" | ✅ SSO подхватился автоматически, доступ разрешён |
| 6 | `testuser` (без Team2_*) → `GET /` | Отказ | ✅ `403 Forbidden`, "You do not have permission to access this resource" |

Команды воспроизведения (из корня репозитория):
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://service2.localhost:5187/         # тест 1

JAR_OUT=/tmp/u.jar EXPECT_TEXT="область Team2_Users" \
  ./scripts/test-oidc-login.sh http://service2.localhost:5187/ team2user 'Team2User12345!'   # тест 2
curl -s -b /tmp/u.jar -D - -o /dev/null -L http://service2.localhost:5187/admin              # тест 3

JAR_OUT=/tmp/a.jar EXPECT_TEXT="область Team2_Users" \
  ./scripts/test-oidc-login.sh http://service2.localhost:5187/ team2admin 'Team2Admin12345!' # тест 4
curl -s -b /tmp/a.jar -D - -o /dev/null -L http://service2.localhost:5187/admin              # тест 5

EXPECT_TEXT="область Team2_Users" \
  ./scripts/test-oidc-login.sh http://service2.localhost:5187/ testuser 'Test12345!'         # тест 6 (ожидаемо падает)
```

**Наблюдение про SSO:** переход между users- и admins-инстансами не требует
повторного ввода пароля — активная сессия Keycloak (`KEYCLOAK_SESSION`
cookie на `keycloak:8080`) переиспользуется автоматически при повторном
`/authorize`-запросе от второго клиента. Роль всё равно проверяется заново
на каждом инстансе независимо — SSO не обходит RBAC.

## 4. Ограничения этого подхода

- **Дублирование oauth2-proxy инстансов** — на каждую роль/уровень доступа
  нужен отдельный процесс с собственным client_id/secret в Keycloak,
  собственным `--proxy-prefix` и cookie-неймспейсом. Для N уровней ролей —
  N инстансов. У gogatekeeper/Pomerium это один декларативный список правил
  в одном инстансе.
- **Нет декларативного RBAC на уровне Traefik** — вся логика авторизации
  вынесена во внешние oauth2-proxy процессы; сам Traefik лишь маршрутизирует
  по пути к "правильному" из них. Middleware, которое бы читало заголовок
  ответа и сравнивало с ожидаемым значением ("если X-Groups не содержит Y —
  403"), в Traefik OSS нет.
- **Две независимые cookie-сессии на одном домене** — `_oauth2_proxy` от
  users-инстанса и от admins-инстанса это РАЗНЫЕ cookie с одним и тем же
  именем и путём `/`, они перезаписывают друг друга в браузере при
  переключении между `/` и `/admin`. На практике это не ломает
  аутентификацию (Keycloak SSO компенсирует), но означает, что "выход"
  (logout) с одного инстанса не разлогинивает второй, и в DevTools будет
  видна только последняя записанная cookie — что может путать при отладке.
- **Операционная сложность растёт с числом путей/ролей** — каждый новый
  уровень доступа = новый Keycloak client + новый контейнер + новый
  router/middleware в Traefik. Для 2 уровней (как здесь) это ещё приемлемо,
  для 5-6 — уже громоздко по сравнению с одним YAML-списком правил.

## Итог

Path-based RBAC на Traefik OSS реализуем и работает корректно (все 6
тестов пройдены), но требует размножения auth-сервисов вместо
декларативных правил — на практике это осознанный компромисс: если у
команды уже стандартизован Traefik и нет готовности разворачивать
gogatekeeper/Pomerium, эта схема рабочая, но кратно более многословная и с
худшей эргономикой сопровождения (каждое новое правило = новый сервис в
docker-compose/K8s, а не строка в YAML).
