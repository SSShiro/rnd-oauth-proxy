# RBAC-сценарий: HAProxy — ролевая авторизация через ACL

Path-based RBAC на одном домене `service2.localhost:5189`:
- `/` — доступ только роли `Team2_Users`;
- `/admin` — доступ только роли `Team2_Admins`.

## 1. Архитектура

В отличие от основного стенда (`proxies/haproxy/`), где oauth2-proxy сам
решает пускать/не пускать (через `--allowed-group` на уровне ВСЕГО
инстанса), здесь используется другое разделение ответственности:

- **oauth2-proxy** (`oauth2-proxy-rbac-haproxy`) отвечает только за
  **аутентификацию** — валидный логин в Keycloak, без `--allowed-group`.
  Пускает любого залогиненного пользователя и возвращает на
  `/oauth2/auth` заголовок `X-Auth-Request-Groups` со списком ролей из
  claim `roles` (включён через `--oidc-groups-claim=roles` +
  `--set-xauthrequest=true`).
- **HAProxy** сам принимает финальное **ролевое решение** через ACL:
  смотрит на путь запроса (`/admin` или нет) и на содержимое заголовка
  `X-Auth-Request-Groups`, возвращённого auth-subrequest'ом, и решает —
  пропустить (`default_backend`) или отдать `403`.

Формат заголовка подтверждён эмпирически (см. раздел 3): значение —
список ролей через запятую без пробелов и без кавычек, например
`Team2_Users,Team2_Admins`. ACL матчит через `-m sub` (проверка
вхождения подстроки), это работает корректно и для одной роли, и для
списка из нескольких.

Ключевая деталь, унаследованная из основного стенда: `use_backend` в
HAProxy **не прерывает** остальные `http-request` правила того же
frontend — каждое auth/role-правило явно исключает `/oauth2/*` через
`!is_oauth2_path`, иначе редирект-луп.

## 2. Конфигурация

`docker-compose.yml` — два сервиса: `haproxy-rbac` (публикует `5189:80`,
собирается из `Dockerfile` — тот же, что в основном стенде, ставит
`haproxy-auth-request.lua` + `haproxy-lua-http` + `json.lua`) и
`oauth2-proxy-rbac-haproxy` (auth-only, порт наружу не публикуется).

Ключевые флаги oauth2-proxy:
```
--client-id=haproxy-rbac-client
--redirect-url=http://service2.localhost:5189/oauth2/callback
--upstream=static://202          # forward-auth режим, нет реального апстрима
--oidc-groups-claim=roles        # источник групп/ролей — наш claim "roles"
--set-xauthrequest=true          # включает X-Auth-Request-* в ответе
# БЕЗ --allowed-group — намеренно, роль проверяет HAProxy, не oauth2-proxy
```

`haproxy.cfg` — полный файл см. в директории; ключевая часть:
```
acl is_admin_path path_beg /admin
http-request lua.auth-request auth_request_backend /oauth2/auth unless is_oauth2_path
http-request set-header X-Auth-Request-Groups %[var(req.auth_response_header.x_auth_request_groups)] if { var(txn.auth_response_successful) -m bool } !is_oauth2_path

acl has_admin_role var(req.auth_response_header.x_auth_request_groups) -m sub Team2_Admins
acl has_user_role  var(req.auth_response_header.x_auth_request_groups) -m sub Team2_Users

http-request redirect location http://service2.localhost:5189/oauth2/start?rd=%[path] if !{ var(txn.auth_response_successful) -m bool } !is_oauth2_path
http-request deny status 403 if { var(txn.auth_response_successful) -m bool } is_admin_path  !has_admin_role !is_oauth2_path
http-request deny status 403 if { var(txn.auth_response_successful) -m bool } !is_admin_path !has_user_role  !is_oauth2_path
```

## 3. Результаты тестов

Все 6 сценариев прогнаны вживую через `scripts/test-oidc-login.sh` и
`curl` с сохранённым cookie jar. Реальные результаты:

| # | Сценарий | Ожидание | Факт |
|---|---|---|---|
| 1 | Без сессии → `GET /` | 302 на `/oauth2/start` | **302** ✅ |
| 2 | `team2user` → `GET /` | 200, `X-Auth-Request-Groups: Team2_Users` | **200**, заголовок ровно `Team2_Users` ✅ |
| 3 | `team2user` → `GET /admin` (та же сессия) | 403 | **403** ✅ |
| 4 | `team2admin` → `GET /` | 200 | **200**, заголовок `Team2_Users,Team2_Admins` ✅ |
| 5 | `team2admin` → `GET /admin` | 200, контент "Team2_Admins" | **200**, тело содержит "Team2_Admins" и "административная область" ✅ |
| 6 | `testuser` (без Team2_*) → `GET /` | 403 | **403** ✅ (важно: цепочка статусов `302, 302, 403` — то есть testuser УСПЕШНО прошёл аутентификацию у oauth2-proxy (иначе не было бы второго 302 на callback), отказ пришёл именно от HAProxy ACL, не от Keycloak/oauth2-proxy) |

Команды (пример для кейса 2):
```bash
JAR_OUT=/tmp/team2user_hp.jar EXPECT_TEXT="Team2_Users" \
  ./scripts/test-oidc-login.sh http://service2.localhost:5189/ team2user 'Team2User12345!'
curl -s -o /dev/null -w "%{http_code}\n" -b /tmp/team2user_hp.jar http://service2.localhost:5189/admin
```

## 4. Ограничения

- **Синтаксис ACL менее читаем, чем декларативный RBAC gogatekeeper.**
  Правило вида "путь X требует роль Y" здесь размазано по 3-4 строкам
  (`acl` + `set-header` + `deny`) вместо одного списка `resources:` —
  на 2 роли/пути ещё терпимо, но на 5-10 правил конфиг станет заметно
  сложнее поддерживать и ревьюить, чем декларативный YAML-список.
- **Жёсткая зависимость от точного формата заголовка** `X-Auth-Request-Groups`
  (не документирован как публичный контракт oauth2-proxy в плане формата
  сериализации — в этой версии это plain comma-separated, но при апгрейде
  версии oauth2-proxy стоит перепроверить, что формат не изменился).
- **Нет автоматической защиты от "забыл добавить `!is_oauth2_path`"** —
  как и в основном стенде, каждое новое auth/role-правило нужно вручную
  исключать из путей `/oauth2/*`, иначе получится redirect-loop. Это
  человеческий фактор, а не техническое ограничение, но он реален при
  расширении списка правил.
- **`-m sub` — проверка подстроки, не точного элемента списка.** Если в
  будущем появится роль `Team2_Admins_Readonly` рядом с `Team2_Admins`,
  подстрочный матч `-m sub Team2_Admins` ложно сработает и на неё —
  для продакшена нужнее `-m reg` с границами слова
  (`-m reg (^|,)Team2_Admins(,|$)`) либо HAProxy Data Plane API/map-файл
  со списком точных значений.
- В отличие от Traefik/oauth2-proxy-мультиинстанс подхода здесь **не нужно**
  городить `--proxy-prefix` и несколько инстансов oauth2-proxy — только
  один auth-only инстанс, что само по себе плюс к простоте эксплуатации.
