# RBAC-сценарий: path-based роли на всех 9 oauth-proxy решениях

Расширение основного RND-стенда (`../proxies/`) вопросом: *«подходит ли
что-то из наших решений для более сложной авторизации, чем просто
закрыть доступ, например —*

- *закрыть доступ для `service1.example.com` просто авторизацией,*
- *закрыть доступ для `service2.example.com` для всех кроме роли `Team2_Users`,*
- *закрыть доступ для `service2.example.com/admin` для всех кроме роли `Team2_Admins`»?*

**Кейс 1 (`service1` — просто авторизация без ролей) отдельно не
пересобирался** — это ровно то, что уже реализовано и end-to-end
протестировано для всех 9 решений в основном стенде (`../proxies/`, порты
4180-4188). Здесь сосредоточена вся работа над **кейсами 2 и 3** — двумя
уровнями ролей на ПУТЯХ одного домена/приложения (`service2` /
`service2/admin`) — самой нетривиальной частью вопроса, где решения
реально расходятся по подходу.

Все 9 реализаций подняты, протестированы полной матрицей из 6 сценариев
(см. таблицу ниже) и задокументированы в собственном `README.md`.

## Быстрый старт

```bash
# 1. Базовый стенд (Keycloak + сеть oauth-net) — если ещё не поднят
docker compose up -d

# 2. Общий backend RBAC-сценария (service2-backend, без auth-логики)
docker compose -f rbac-scenario/docker-compose.yml up -d

# 3. Любое из решений, например gogatekeeper:
docker compose -f rbac-scenario/gogatekeeper/docker-compose.yml up -d

# 4. Проверка (пример):
./scripts/test-oidc-login.sh http://service2.localhost:5181/ team2user 'Team2User12345!'
```

`service2.localhost` резолвится в `127.0.0.1` автоматически (как и
`*.localhost` везде в этом репозитории). В `/etc/hosts` нужна только
стандартная запись `127.0.0.1 keycloak` (см. корневой README).

## Тестовые пользователи (добавлены в realm `corp-sso` специально для этого сценария)

| Пользователь | Пароль | Роли |
|---|---|---|
| `team2user` | `Team2User12345!` | `Team2_Users` |
| `team2admin` | `Team2Admin12345!` | `Team2_Users`, `Team2_Admins` |
| `testuser` (уже существовал) | `Test12345!` | `app-user` (без `Team2_*` — негативный тест) |

## Карта портов

| Решение | Порт | URL |
|---|---|---|
| [gogatekeeper](gogatekeeper/) | 5181 | http://service2.localhost:5181/ |
| [Pomerium](pomerium/) | 5182 | https://service2.localhost:5182/ (TLS обязателен, самоподписанный сертификат, `curl -k`) |
| [Apache APISIX](apisix/) | 5183 | http://service2.localhost:5183/ |
| [oauth2-proxy](oauth2-proxy/) | 5184 | http://service2.localhost:5184/ |
| [vouch-proxy](vouch-proxy/) | 5185 | http://service2.localhost:5185/ |
| [Envoy](envoy/) | 5186 | https://service2.localhost:5186/ (TLS обязателен, самоподписанный сертификат, `curl -k`) |
| [Traefik](traefik/) | 5187 | http://service2.localhost:5187/ (dashboard: 5287) |
| [OpenResty + lua-resty-openidc](nginx-openresty/) | 5188 | http://service2.localhost:5188/ |
| [HAProxy](haproxy/) | 5189 | http://service2.localhost:5189/ |

Каждый порт защищает `/` (роль `Team2_Users`) и `/admin` (роль
`Team2_Admins`) общего [`service2-backend`](service2-backend/) — backend не
содержит НИ строки авторизационной логики, весь RBAC — на стороне
прокси/балансировщика перед ним.

## Тестовая матрица (одинаковая для всех 9 решений)

| № | Сценарий | Ожидание |
|---|---|---|
| 1 | Без сессии → `GET /` | Редирект на Keycloak (302/303) |
| 2 | `team2user` → `GET /` | 200, контент "область Team2_Users" |
| 3 | `team2user` (та же сессия) → `GET /admin` | Отказ (403) |
| 4 | `team2admin` → `GET /` | 200 |
| 5 | `team2admin` (та же сессия) → `GET /admin` | 200, контент "область Team2_Admins" |
| 6 | `testuser` (без `Team2_*`) → `GET /` | Отказ (403) |

**Результат: 9/9 решений — 6/6 тестов пройдено.** Ни одно решение не
провалило саму задачу технически — вопрос не «можно ли», а «какой ценой».

## Сравнение подходов

| Решение | Архитектура RBAC | Инстансов auth-логики | Декларативность |
|---|---|---|---|
| **gogatekeeper** | Встроенный `resources: [{uri, roles}]` | 1 | Полностью декларативно (YAML) |
| **Pomerium** | Встроенный `routes[].policy` с `claim/roles` | 1 | Полностью декларативно (YAML) |
| **Apache APISIX** | `openid-connect` + свой `serverless-pre-function` (Lua) на роль | 1 | Частично — auth декларативна, ролевая проверка написана вручную |
| **OpenResty + lua-resty-openidc** | Весь RBAC — Lua-код в `access_by_lua_block` | 1 | Нет — полностью императивный код |
| **HAProxy** | 1 auth-only oauth2-proxy + ACL-правила HAProxy | 1 (плюс ACL-логика в конфиге HAProxy) | Частично — ACL, не YAML-список |
| **oauth2-proxy (standalone)** | N отдельных инстансов (по одному на роль) + nginx-роутер | 2 (+ router) | Нет — размножение инстансов |
| **Traefik** | N отдельных инстансов oauth2-proxy + N ForwardAuth-роутеров | 2 (+ router) | Нет — размножение инстансов |
| **vouch-proxy** | vouch только аутентифицирует, RBAC — Lua в OpenResty front (ванильный nginx физически не смог — см. находку в `vouch-proxy/README.md`) | 2 (vouch + front) | Нет — и код, и лишний сервис |
| **Envoy (нативные фильтры)** | `oauth2` + `jwt_authn` + `rbac` фильтры, per-route policy | 1 | Технически декларативно (YAML), но ~140 строк raw-proto на 2 правила |

**Практический вывод (согласуется с основным RND-отчётом):**
**gogatekeeper** и **Pomerium** — единственные решения, где path-based
ролевой RBAC — это буквально несколько строк декларативного конфига в
ОДНОМ инстансе, без компромиссов. Everything else in the RND стенде либо
требует размножения auth-инстансов (**oauth2-proxy**, **Traefik**,
**vouch-proxy**), либо перекладывает ролевую логику на написанный вручную
код (**OpenResty**, **APISIX**, **HAProxy**), либо остаётся технически
декларативным, но крайне многословным (**Envoy**).

## Сквозные находки, актуальные для нескольких решений

- **`/admin/*` не матчит литеральный путь `/admin`** (без хвостового
  слэша) — воспроизведено на gogatekeeper и APISIX независимо (оба на
  основе радиксных роутеров). Нужно защищать И точный путь, И wildcard под
  ним отдельными правилами — иначе запрос без слэша тихо проваливается в
  менее строгий catch-all.
- **`--oidc-groups-claim=roles` у oauth2-proxy** неявно добавляет OAuth
  scope `groups` в запрос авторизации — Keycloak отвечает `invalid_scope`,
  если такого client scope нет в realm (у нас роли приходят через
  protocol mapper напрямую, без scope-обёртки). Воспроизведено в
  **oauth2-proxy-standalone** и **Traefik**-сценариях. Фикс — явный
  `--scope="openid email profile"`, переопределяющий список целиком.
  См. основной RND-документ — это дополняет уже известный список граблей.
- **CSRF/PKCE-cookie с жёстко зашитым `Secure`-флагом** — не только у
  Pomerium (уже задокументировано в основном RND), но и у **нативного
  OAuth2-фильтра Envoy** (`OauthNonce`/`CodeVerifier`). Оба требуют TLS
  даже для локального теста.
- **Ложные "успехи" тестового скрипта** — `test-oidc-login.sh` ищет
  подстроку `EXPECT_TEXT` в финальном ответе; если текст сообщения об
  отказе (например "Forbidden: требуется роль Team2_Users") сам содержит
  искомую подстроку, скрипт формально репортует "УСПЕХ" на негативном
  тесте. Воспроизведено в **vouch-proxy** и **nginx-openresty**-сценариях
  независимо. Реальный результат в обоих случаях подтверждён прямой
  проверкой кода ответа (403) — это нюанс методологии тестирования, а не
  дефект RBAC. При написании подобных тестов выбирайте `EXPECT_TEXT`, не
  пересекающийся с текстом сообщений об ошибке.
- **Общий `service2-backend`** первоначально отдавал `301` на `/admin` без
  хвостового слэша со внутренним Docker-hostname в `Location` (утечка
  топологии наружу через прокси) — исправлено (`location = /admin { alias
  ...; }` вместо стандартного поведения `ngx_http_index_module`), фикс
  общий для всех 9 решений.

## Структура

```
rbac-scenario/
  README.md              # этот файл
  docker-compose.yml      # общий service2-backend
  service2-backend/       # backend без авторизационной логики, / и /admin
  gogatekeeper/            # порт 5181
  pomerium/                # порт 5182 (TLS)
  apisix/                  # порт 5183
  oauth2-proxy/            # порт 5184
  vouch-proxy/              # порт 5185
  envoy/                    # порт 5186 (TLS)
  traefik/                  # порт 5187
  nginx-openresty/          # порт 5188
  haproxy/                  # порт 5189
```

Подробности каждой реализации (конфигурация, полные результаты тестов,
специфичные ограничения) — в `README.md` соответствующей директории.
