# RBAC-сценарий: oauth2-proxy (path-based роли на одном домене)

Задача: `service2.localhost:5184/` — доступ только роли `Team2_Users`;
`service2.localhost:5184/admin` — доступ только роли `Team2_Admins`.

## Архитектура

У oauth2-proxy **нет** декларативного RBAC внутри одного инстанса —
`--allowed-group` действует на **весь** инстанс целиком, а не на отдельные
пути. Единственный способ получить два разных уровня доступа под одним
внешним доменом/портом — поднять **два независимых инстанса** oauth2-proxy
(каждый — полноценный reverse-proxy к общему backend) и поставить перед
ними nginx, который маршрутизирует запрос к нужному инстансу по пути:

```
                              ┌─────────────────────────────┐
                              │ nginx-oauth2-rbac-front :80  │
                              │  (published as :5184)        │
                              └───────────────┬───────────────┘
                    /admin, /oauth2-admins/*  │  /, /oauth2-users/*
                              ┌────────────────┴────────────────┐
                              ▼                                  ▼
        ┌──────────────────────────────────┐   ┌──────────────────────────────────┐
        │ oauth2-proxy-rbac-admins          │   │ oauth2-proxy-rbac-users           │
        │ --allowed-group=Team2_Admins      │   │ --allowed-group=Team2_Users       │
        │ --proxy-prefix=/oauth2-admins     │   │ --proxy-prefix=/oauth2-users      │
        │ --upstream=service2-backend:80    │   │ --upstream=service2-backend:80    │
        └──────────────────┬────────────────┘   └──────────────────┬────────────────┘
                            └───────────────┬───────────────────────┘
                                            ▼
                              service2-backend:80 (/ и /admin)
```

Ключевой нюанс: у каждого инстанса **свой** OIDC-callback путь
(`--proxy-prefix`), иначе оба инстанса конкурировали бы за один и тот же
`/oauth2/callback` на одном внешнем домене и nginx не смог бы понять, какому
из них адресован конкретный callback-запрос от Keycloak.

## Конфигурация

`oauth2-proxy-rbac-users` (аналогично `-admins`, с заменой `users`→`admins`
и `Team2_Users`→`Team2_Admins`):
```
--client-id=oauth2-proxy-rbac-users-client
--redirect-url=http://service2.localhost:5184/oauth2-users/callback
--proxy-prefix=/oauth2-users
--upstream=http://service2-backend:80
--oidc-groups-claim=roles      # источник "групп" — наш claim roles, а не стандартный groups
--scope=openid email profile   # ВАЖНО, см. "Найденная проблема" ниже
--allowed-group=Team2_Users
```

`nginx.conf` (front): `/admin` и `/oauth2-admins/*` → `oauth2-proxy-rbac-admins`;
всё остальное, включая `/oauth2-users/*`, → `oauth2-proxy-rbac-users`.

### Найденная проблема: `--oidc-groups-claim` автоматически запрашивает несуществующий OAuth-scope `groups`

При простом добавлении `--oidc-groups-claim=roles --allowed-group=...` без
явного `--scope` получили от Keycloak:
```
Location: .../callback?error=invalid_scope&error_description=Invalid+scopes:+openid+email+profile+groups
```
oauth2-proxy сам добавляет `groups` в список запрашиваемых OAuth-scope, как
только сконфигурирована групповая фильтрация — независимо от того, что имя
claim'а мы переопределили на `roles`. В нашем realm нет client scope с
именем `groups` (роли у нас — client-level protocol mapper, применяется
независимо от списка запрошенных scope), поэтому Keycloak отклоняет запрос
целиком. **Исправлено** явным `--scope=openid email profile` — это
полностью override'ит вычисляемый список scope и убирает лишний `groups`,
никак не влияя на claim `roles` (он приходит в токене независимо от scope,
т.к. привязан к клиенту напрямую).

## Результаты тестов (реально прогнано)

| # | Сценарий | Ожидание | Результат |
|---|---|---|---|
| 1 | Без сессии → `GET /` | 302 на Keycloak | ✅ `HTTP/1.1 302 Found` |
| 2 | `team2user` → `GET /` | 200, "Team2_Users" | ✅ 200, `X-Auth-Request-Groups: Team2_Users` |
| 3 | `team2user` (та же сессия) → `GET /admin` | Отказ | ✅ `403 Forbidden` (страница oauth2-proxy "you do not have permission") |
| 4 | `team2admin` → `GET /` | 200 | ✅ 200 |
| 5 | `team2admin` → `GET /admin` | 200, "Team2_Admins" | ✅ 200, тело содержит "область Team2_Admins" |
| 6 | `testuser` (роль только `app-user`) → `GET /` | Отказ | ✅ `403 Forbidden` |

Интересная деталь теста 3: при переходе `team2user` с `/` на `/admin`
браузер попадает на **другой** oauth2-proxy-инстанс, у которого нет своей
сессии — его редиректит на Keycloak, но т.к. в Keycloak уже есть активная
SSO-сессия (SSO-cookie), логин-форма не показывается повторно — Keycloak
молча переиспользует сессию и сразу возвращает `code`. Admins-инстанс
обменивает код на токен, видит `groups=[Team2_Users]` (без `Team2_Admins`) и
сразу отдаёт `403`. Итог для пользователя ощущается как "просто отказ", хотя
технически это два *независимых* OIDC-flow за одним и тем же кликом browser
— важно понимать при отладке и мониторинге (в логах будет два отдельных
login-события в Keycloak на один "переход" пользователя).

## Ограничения этого подхода

1. **Нет декларативного RBAC** — в отличие от gogatekeeper (`resources: roles:`)
   или Pomerium (`policy: claim/...`), здесь роль = отдельный инстанс.
   Добавление третьей роли = третий инстанс + доп. правило в nginx.
2. **Линейный рост операционной сложности** с числом ролей: N ролей → N
   инстансов oauth2-proxy + N Keycloak-клиентов + N `--proxy-prefix` +
   разветвление в nginx.
3. **Два (потенциально больше) независимых cookie/сессии на одном
   внешнем домене** — по одной на инстанс (`_oauth2_rbac_users`,
   `_oauth2_rbac_admins`), у пользователя фактически параллельно живут
   разные "уровни" аутентификации к одному сайту. Не проблема для
   безопасности (наоборот, чётко разделяет привилегии), но усложняет
   отладку и logout (нужно чистить обе cookie для полного выхода).
2. **`--oidc-groups-claim` тянет за собой неявный scope `groups`**,
   который может не существовать в вашем realm — нужно явно
   переопределять `--scope`, иначе непонятная ошибка `invalid_scope` на
   этапе callback (см. выше). Грабля, которую легко не заметить, если не
   читать `docker logs` внимательно (пользователь просто увидит 403/502).
3. **Требует внешнего роутинг-слоя** (в проде — не голый nginx, а
   полноценный ingress/API-gateway с path-based routing) — сам oauth2-proxy
   эту задачу не решает.

## Как запустить и проверить

```bash
docker compose up -d                                         # базовый стенд (корень репо)
docker compose -f rbac-scenario/docker-compose.yml up -d     # общий backend
docker compose -f rbac-scenario/oauth2-proxy/docker-compose.yml up -d

./scripts/test-oidc-login.sh http://service2.localhost:5184/ team2user 'Team2User12345!'   # EXPECT_TEXT="Team2_Users" по умолчанию не задан — Hello World не найдётся, проверяйте вручную или через EXPECT_TEXT=
EXPECT_TEXT="Team2_Users" ./scripts/test-oidc-login.sh http://service2.localhost:5184/ team2user 'Team2User12345!'
EXPECT_TEXT="Team2_Admins" JAR_OUT=/tmp/j.jar ./scripts/test-oidc-login.sh http://service2.localhost:5184/admin team2admin 'Team2Admin12345!'
curl -s -o /dev/null -w "%{http_code}\n" -b /tmp/j.jar http://service2.localhost:5184/  # переиспользование сессии
```
