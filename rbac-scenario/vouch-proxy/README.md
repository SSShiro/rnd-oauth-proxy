# RBAC-сценарий: vouch-proxy

**Порт:** 5185 · **URL:** http://service2.localhost:5185/ · **Требуется:** `/` — роль `Team2_Users`, `/admin` — роль `Team2_Admins`

## 1. Архитектура

У vouch-proxy нет policy-движка — он только аутентифицирует
(`allowAllUsers: true`) и, благодаря `headers.claims: [roles]`, кладёт claim
`roles` в заголовок ответа `/validate`. Сам RBAC (разный доступ на `/` и
`/admin`) реализован **во front-прокси перед vouch-proxy**, а не в vouch-proxy.

Изначально front планировался на ванильном `nginx:1.27-alpine` (как в
основном стенде `proxies/vouch-proxy/`), но выяснилось, что классический
паттерн "`auth_request` + `auth_request_set` + `if`" для проверки РОЛИ (в
отличие от простой аутентификации) **не работает** на ванильном nginx —
подробности в разделе "Найденные проблемы". Поэтому front здесь —
`openresty/openresty:1.25.3.1-alpine` (не -fat, только встроенный
`ngx_http_lua_module`, без opm-пакетов) с одним маленьким
`access_by_lua_block` после `auth_request`.

Формат заголовка с ролями, который реально вернул vouch-proxy (подтверждено
логом при старте): **`X-Vouch-IdP-Claims-Roles`**, значение — сериализованный
Go-слайс вида `[Team2_Users]` (для одной роли) или `[Team2_Users Team2_Admins]`
(для нескольких, через пробел, без кавычек и запятых — НЕ JSON). Проверка на
принадлежность роли сделана через `string.find(roles, "Team2_Admins", 1, true)`
(поиск подстроки) — устойчиво к этому формату.

## 2. Конфигурация

`config.yml` (vouch-proxy):
```yaml
vouch:
  allowAllUsers: true
  cookie:
    secure: false
    domain: service2.localhost   # см. "Найденные проблемы" — НЕ "localhost"
  jwt:
    secret: "<32 байта base64>"
  headers:
    claims: [roles]
oauth:
  provider: oidc
  client_id: vouch-proxy-rbac-client
  client_secret: vouch-proxy-rbac-secret-CHANGEME
  auth_url: http://keycloak:8080/realms/corp-sso/protocol/openid-connect/auth
  token_url: http://keycloak:8080/realms/corp-sso/protocol/openid-connect/token
  user_info_url: http://keycloak:8080/realms/corp-sso/protocol/openid-connect/userinfo
  scopes: [openid, email, profile]
  callback_url: http://service2.localhost:5185/auth
```

`nginx.conf` (front, ключевая часть — `location /admin`, `location /`
аналогичен с `Team2_Users`):
```nginx
location /admin {
    auth_request /validate;
    auth_request_set $roles $upstream_http_x_vouch_idp_claims_roles;
    error_page 401 = @error401;

    access_by_lua_block {
        local roles = ngx.var.roles or ""
        if not string.find(roles, "Team2_Admins", 1, true) then
            ngx.status = 403
            ngx.say("Forbidden: требуется роль Team2_Admins")
            return ngx.exit(403)
        end
    }

    proxy_pass http://service2-backend:80;
    proxy_set_header Host $host;
}
```

## 3. Результаты тестов

Все 6 сценариев прогнаны через `scripts/test-oidc-login.sh` (с `JAR_OUT` для
сохранения сессии между запросами) плюс точечные `curl`:

| № | Сценарий | Ожидание | Результат |
|---|---|---|---|
| 1 | Без сессии → `GET /` | 302 на Keycloak | **302** ✅ |
| 2 | `team2user` → `GET /` | 200, "Team2_Users" | **200 OK**, тело содержит "область Team2_Users" ✅ |
| 3 | `team2user` (та же сессия) → `GET /admin` | 403 | **403 Forbidden: требуется роль Team2_Admins** ✅ |
| 4 | `team2admin` → `GET /` | 200 | **200 OK** ✅ |
| 5 | `team2admin` (та же сессия) → `GET /admin` | 200, "Team2_Admins" | **200 OK**, тело содержит "Team2_Admins" ✅ |
| 6 | `testuser` (без Team2_*) → `GET /` | 403 (vouch бы пропустил — `allowAllUsers: true` — отказывает именно Lua-проверка роли) | **403 Forbidden: требуется роль Team2_Users** ✅ |

Примечание по методологии: автоматический скрипт `test-oidc-login.sh` для
теста №6 ошибочно репортует "УСПЕХ", т.к. ищет подстроку `EXPECT_TEXT`
("Team2_Users"), а моя же 403-страница ("Forbidden: требуется роль
Team2_Users") эту подстроку тоже содержит — ложное срабатывание проверки, не
самого RBAC. Прямой `curl` с тем же cookie jar подтверждает реальный код
ответа: **403**.

## 4. Найденные проблемы (ключевые для этого RND)

**№1 — "if" не подходит для проверки claim после auth_request на ванильном nginx.**
Директива `if` в nginx выполняется в фазе **rewrite**, которая идёт РАНЬШЕ
фазы **access**, где работает `auth_request`. Наивный вариант
`auth_request /validate; auth_request_set $roles ...; if ($roles !~ ...) { return 403; }`
в одном `location` **не работает** — на момент выполнения `if` переменная
`$roles` ещё пуста (auth_request ещё не выполнился), и запрос получает 403
**даже без сессии вообще** (подтверждено эмпирически: без этого фикса тест
№1 выше возвращал 403 вместо 302). Обойти через второй `auth_request` в том
же `location` тоже нельзя — nginx явно запрещает больше одного `auth_request`
на location (`"auth_request" directive is duplicate`). Рабочее решение —
`access_by_lua_block` (OpenResty), который выполняется в правильной фазе.
Практический вывод: **связка "vouch-proxy + ванильный nginx" физически не
может сделать path-based RBAC без модуля скриптования** (Lua/njs) — это
следует явно указывать при выборе vouch-proxy для подобных задач.

**№2 — `cookie.domain: localhost` — cookie молча не сохраняется клиентом.**
Пример конфигурации в документации vouch-proxy (и в основном стенде этого
RND, где хост в точности `localhost`) использует `cookie.domain: localhost`.
При хосте `service2.localhost` это привело к тому, что curl (и любой
современный браузер) **отклоняет** `Set-Cookie` с `Domain=localhost` как cookie
для потенциального public suffix (защита от "cookie tossing" между
произвольными поддоменами `*.localhost`) — cookie тихо не сохраняется,
пользователь каждый раз выглядит неаутентифицированным → бесконечный
redirect-loop на `/login`. Фикс — `cookie.domain` должен точно совпадать с
фактическим hostname (`service2.localhost`), а не быть "более широким"
родительским доменом. Для прода вывод: `cookie.domain` в vouch-proxy должен
быть ровно тем доменом, где сервис реально живёт, а не преднамеренно
расширен "на будущее" — иначе тот же класс проблемы (PSL-рестрикция)
возникнет и с настоящими корпоративными доменами, если поддомен и заданный
`cookie.domain` не совпадают по глубине вложенности так, как ожидает клиент.

**Общий вывод:** vouch-proxy сам по себе для path-based RBAC не подходит
вообще (нет policy-движка) — вся логика выносится на front-прокси, и на
практике это означает **обязательный переход на OpenResty/Lua**, а не
ванильный nginx, что резко приближает эксплуатационную сложность к сценарию
`nginx-openresty` из этого же RBAC-набора (см. `../nginx-openresty/README.md`) —
только с лишним сетевым прыжком к vouch-proxy сверху и без пользы от его
широкого списка провайдеров (Keycloak и так поддерживается напрямую в
lua-resty-openidc).
