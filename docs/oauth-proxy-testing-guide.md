# Инструкция по развёртыванию и тестированию OAuth-Proxy стенда

Подробное пошаговое руководство: как поднять базовый стенд, как поднять
каждое из 9 решений, как именно в каждом из них реализована аутентификация/
авторизация через Keycloak, и как самостоятельно проверить работоспособность
каждой реализации — вручную через браузер и автоматически через готовый
скрипт.

Общий обзор решений, сравнение и рекомендации — в
[`oauth-proxy-rnd.md`](oauth-proxy-rnd.md). Этот документ — операционное
руководство "как запустить и проверить", а не сравнительный отчёт.

## Оглавление

- [0. Предварительные требования и базовый стенд](#0-предварительные-требования-и-базовый-стенд)
- [0.1. Общая методика тестирования](#01-общая-методика-тестирования)
- [1. oauth2-proxy](#1-oauth2-proxy)
- [2. gogatekeeper](#2-gogatekeeper)
- [3. vouch-proxy](#3-vouch-proxy)
- [4. Envoy (нативный OAuth2-фильтр)](#4-envoy-нативный-oauth2-фильтр)
- [5. Traefik + ForwardAuth + oauth2-proxy](#5-traefik--forwardauth--oauth2-proxy)
- [6. OpenResty + lua-resty-openidc](#6-openresty--lua-resty-openidc)
- [7. HAProxy + Lua auth-request + oauth2-proxy](#7-haproxy--lua-auth-request--oauth2-proxy)
- [8. Pomerium](#8-pomerium)
- [9. Apache APISIX + плагин openid-connect](#9-apache-apisix--плагин-openid-connect)
- [Приложение А: остановка и полная очистка стенда](#приложение-а-остановка-и-полная-очистка-стенда)
- [Приложение Б: как добавить пользователя без роли для негативных тестов RBAC](#приложение-б-как-добавить-пользователя-без-роли-для-негативных-тестов-rbac)

---

## 0. Предварительные требования и базовый стенд

### 0.1. Что нужно установить

- Docker Engine + Docker Compose plugin (`docker compose version` должен
  отработать без ошибок).
- `curl`, `python3` (используются в тестовом скрипте — без внешних
  зависимостей, только стандартная библиотека).
- `openssl` (только если захотите пересоздать самоподписанный сертификат
  для Pomerium — готовый уже лежит в репозитории).

### 0.2. Клонирование и первый запуск

```bash
git clone https://github.com/SSShiro/rnd-oauth-proxy.git
cd rnd-oauth-proxy

# Базовый стенд: Keycloak + тестовое приложение nginx-hello (без OIDC).
docker compose up -d

# Дождаться готовности Keycloak (обычно 20-40 секунд на первый старт):
until [ "$(docker inspect -f '{{.State.Health.Status}}' keycloak 2>/dev/null)" = "healthy" ]; do
  echo "Keycloak ещё не готов, ждём..."; sleep 3
done
echo "Keycloak готов."
```

### 0.3. Обязательная правка /etc/hosts

Несколько решений (vouch-proxy, Envoy, HAProxy+oauth2-proxy, Pomerium)
используют один и тот же hostname Keycloak и для редиректа браузера, и для
серверных вызовов (подробнее — в [`oauth-proxy-rnd.md`, раздел
6](oauth-proxy-rnd.md#6-типовые-грабли-внедрения-обнаружены-практически-в-рамках-rnd)).
Внутри docker-сети Keycloak называется `keycloak`; чтобы то же имя
резолвилось и с хост-машины (для тестирования curl'ом/браузером), один раз
добавьте:

```bash
echo "127.0.0.1 keycloak" | sudo tee -a /etc/hosts
```

Хосты `hello.localhost` и `authenticate.localhost` (нужны только для
Pomerium, раздел 8) добавлять не нужно — любые поддомены `*.localhost`
резолвятся в `127.0.0.1` автоматически (RFC 6761), это работает "из
коробки" в большинстве современных ОС.

### 0.4. Проверка Keycloak admin console

Откройте http://localhost:8080/admin в браузере, логин `admin` / пароль
`admin12345`. В левом верхнем углу переключите realm с `master` на
`corp-sso` — там уже должны быть:

- **Clients** — 9 клиентов, по одному на каждое решение (`oauth2-proxy-client`,
  `gogatekeeper-client`, `vouch-proxy-client`, `envoy-client`,
  `traefik-client`, `nginx-openresty-client`, `haproxy-client`,
  `pomerium-client`, `apisix-client`);
- **Users** — `testuser` (роль `app-user`) и `adminuser` (роли `app-user`,
  `app-admin`);
- **Realm roles** — `app-user`, `app-admin`.

Если раздела `corp-sso` нет — значит realm не импортировался; смотрите
`docker logs keycloak` на предмет ошибок импорта и убедитесь, что файл
`keycloak/import/realm-export.json` действительно смонтирован (проверяется
командой `docker inspect keycloak` → секция `Mounts`).

Учётные данные тестовых пользователей, используемые везде далее:

| Пользователь | Пароль | Роли |
|---|---|---|
| `testuser` | `Test12345!` | `app-user` |
| `adminuser` | `Admin12345!` | `app-user`, `app-admin` |

---

## 0.1. Общая методика тестирования

Для всех 9 решений применяется один и тот же сценарий проверки — полный
Authorization Code Flow:

```
Браузер → GET / (защищённый URL прокси)
        → 302 редирект на Keycloak authorize endpoint
        → форма логина Keycloak
        → POST username/password
        → 302 редирект обратно на callback прокси (с ?code=...)
        → прокси обменивает code на токен, ставит свою cookie-сессию
        → 302/200 редирект на исходный URL
        → 200 OK, виден контент nginx-hello ("Hello World")
```

### Способ А: вручную в браузере (рекомендуется хотя бы один раз проверить так)

1. Откройте URL решения (см. таблицу в конце README или в начале каждого
   раздела ниже) в приватном/инкогнито-окне (чтобы не мешали cookie от
   предыдущих тестов).
2. Вас должно перебросить на страницу логина Keycloak с заголовком "Sign in
   to Corp SSO (RND stand)".
3. Введите `testuser` / `Test12345!`, нажмите Sign In.
4. Вас должно вернуть на исходный URL с текстом "Hello World" — значит,
   аутентификация прошла и прокси пропустил запрос к защищённому
   приложению.
5. Откройте DevTools → Network → выберите первый запрос → вкладка
   Cookies/Headers, чтобы увидеть, какую cookie сессии выставил конкретный
   прокси (имя cookie у каждого решения своё — указано в соответствующем
   разделе ниже).
6. Обновите страницу (F5) — повторного логина быть не должно (сессия уже
   есть). Откройте DevTools и найдите заголовки/куки, которые прокси
   прокидывает на backend (см. раздел "Проверка identity" у каждого
   решения) — для этого также можно временно открыть саму страницу
   `nginx-hello` через `curl` с той же cookie (см. способ Б).

### Способ Б: автоматически через `scripts/test-oidc-login.sh`

В репозитории есть готовый скрипт, который проделывает весь сценарий выше
без браузера — сам находит форму логина Keycloak, отправляет учётные
данные, проверяет финальный результат и печатает заголовки ответа:

```bash
./scripts/test-oidc-login.sh <URL> [username] [password] [доп. опции curl...]
```

Примеры для всех 9 решений (используются далее в каждом разделе):

```bash
./scripts/test-oidc-login.sh http://localhost:4180/                              # oauth2-proxy
./scripts/test-oidc-login.sh http://localhost:4181/                              # gogatekeeper
./scripts/test-oidc-login.sh http://localhost:4182/                              # vouch-proxy
./scripts/test-oidc-login.sh http://localhost:4183/                              # Envoy
./scripts/test-oidc-login.sh http://localhost:4184/                              # Traefik
./scripts/test-oidc-login.sh http://localhost:4185/                              # OpenResty
./scripts/test-oidc-login.sh http://localhost:4186/                              # HAProxy
./scripts/test-oidc-login.sh https://hello.localhost:4187/ testuser 'Test12345!' -k   # Pomerium (TLS, самоподписанный сертификат)
./scripts/test-oidc-login.sh http://localhost:4188/                              # APISIX
```

Скрипт завершается кодом `0` и печатает "УСПЕХ", если контент `Hello World`
получен; кодом `1` с диагностикой — если что-то пошло не так (форма логина
не найдена, финальный ответ — страница ошибки и т.д.).

**Важно:** скрипт создаёт новый временный cookie-jar при каждом запуске,
поэтому его можно перезапускать сколько угодно раз подряд — предыдущая
сессия не мешает.

### Способ В: проверка "неаутентифицированного" пути (негативный тест)

Для любого решения справедливо: запрос без cookie сессии должен ВСЕГДА
получать редирект (302/303) на Keycloak, а не 200 и не сам контент
приложения. Проверяется одной командой (без `-L`, чтобы не проходить по
редиректу):

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:<порт>/
# ожидается: 302 (или 303 у gogatekeeper)
```

Если вместо этого возвращается `200` — значит, защита не работает
(например, забыли поднять прокси и достучались напрямую до
`nginx-hello`, что в штатной конфигурации стенда невозможно, т.к. у
`nginx-hello` не публикуется порт наружу — но стоит перепроверить именно
это, если увидите такое поведение).

---

## 1. oauth2-proxy

**Порт:** 4180 · **URL:** http://localhost:4180/ · **Паттерн:** выделенный reverse-proxy

### Как реализована авторизация

oauth2-proxy сконфигурирован через CLI-флаги прямо в
`proxies/oauth2-proxy/docker-compose.yml`:

| Флаг | Значение | Смысл |
|---|---|---|
| `--provider=oidc` | | Generic OIDC (не привязан к конкретному вендору) |
| `--oidc-issuer-url` | `http://keycloak:8080/realms/corp-sso` | Один-единственный URL: и для OIDC discovery, и для authorize/token/userinfo endpoints |
| `--client-id` / `--client-secret` | `oauth2-proxy-client` / `oauth2-proxy-secret-CHANGEME` | Учётные данные клиента из Keycloak |
| `--redirect-url` | `http://localhost:4180/oauth2/callback` | Должен точно совпадать с `redirectUris` клиента в realm-export.json |
| `--upstream` | `http://nginx-hello:80` | oauth2-proxy сам является reverse-proxy к приложению |
| `--cookie-secret` | (32-байтовый base64) | Ключ шифрования cookie-сессии (AES) |
| `--cookie-secure=false` | | Только для HTTP RND-стенда — в проде должно быть `true` |
| `--set-xauthrequest=true` | | Добавляет `X-Auth-Request-User/Email/Preferred-Username` в ответ (видно в DevTools) и в запрос к апстриму |
| `--pass-access-token` / `--pass-authorization-header` | `true` | Access-токен Keycloak пробрасывается апстриму как `Authorization: Bearer ...` |
| `--email-domain=*` | | Разрешить любой email-домен (грубая авторизация — здесь сознательно "пропускать всех", в проде обычно `--email-domain=corp.example.com` или `--allowed-group=...`) |

Файлы: `proxies/oauth2-proxy/docker-compose.yml`.

### Запуск

```bash
docker compose -f proxies/oauth2-proxy/docker-compose.yml up -d
docker logs oauth2-proxy --tail 20
# ожидаем строки вида:
#   "OAuthProxy configured for OpenID Connect Client ID: oauth2-proxy-client"
#   "Cookie settings: name:_oauth2_proxy ..."
```

### Тестирование

```bash
# Автоматически:
./scripts/test-oidc-login.sh http://localhost:4180/

# Негативный тест (без сессии — ожидаем 302):
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4180/

# Проверка identity-заголовков на защищённом приложении:
# (JAR получите из вывода test-oidc-login.sh, или залогиньтесь вручную curl'ом)
curl -s -b <jar> -D - -o /dev/null http://localhost:4180/ | grep -i x-auth-request
```

Ожидаемые заголовки: `X-Auth-Request-User`, `X-Auth-Request-Email:
testuser@corp.local`, `X-Auth-Request-Preferred-Username: testuser`,
`X-Auth-Request-Access-Token: eyJ...` (JWT). Имя cookie сессии в браузере:
`_oauth2_proxy`.

### Остановка

```bash
docker compose -f proxies/oauth2-proxy/docker-compose.yml down
```

---

## 2. gogatekeeper

**Порт:** 4181 · **URL:** http://localhost:4181/ · **Паттерн:** выделенный reverse-proxy с встроенным RBAC

### Как реализована авторизация

Конфигурация — YAML-файл `proxies/gogatekeeper/config.yml`, смонтированный
в контейнер и переданный через `--config`:

| Ключ | Значение | Смысл |
|---|---|---|
| `discovery-url` | `http://keycloak:8080/realms/corp-sso` | Аналог `--oidc-issuer-url` у oauth2-proxy |
| `client-id` / `client-secret` | `gogatekeeper-client` / `gogatekeeper-secret-CHANGEME` | |
| `redirection-url` | `http://localhost:4181` | gogatekeeper **сам добавляет** путь `/oauth/callback` — итоговый redirect_uri `http://localhost:4181/oauth/callback` должен совпадать с клиентом в Keycloak |
| `upstream-url` | `http://nginx-hello:80` | |
| `encryption-key` | 32-символьная строка | Ключ AES-256 для шифрования сессионных cookie |
| `enable-default-deny: false` | | **Важно:** по умолчанию `true`, конфликтует с явным правилом `resources: [{uri: "/*"}]` ниже — процесс не стартует, если не выставить `false` явно (см. "Частые проблемы" ниже) |
| `resources` | `uri: /*`, `roles: [app-user]` | **Настоящий RBAC на уровне путей** — пускает только пользователей с ролью `app-user` в токене. Это ключевое отличие от oauth2-proxy/vouch-proxy, где такой гранулярности нет "из коробки" |

Файлы: `proxies/gogatekeeper/config.yml`, `proxies/gogatekeeper/docker-compose.yml`.

### Запуск

```bash
docker compose -f proxies/gogatekeeper/docker-compose.yml up -d
docker logs gogatekeeper --tail 20
# ожидаем: "gatekeeper proxy service starting" и "protecting resource"
```

### Частые проблемы при запуске

Если в логах видите зацикленный рестарт с ошибкой:
```
[error] you've enabled default deny and at the same time defined own rules for /*
```
— это конфликт `enable-default-deny: true` (значение по умолчанию) с
собственным правилом `resources`. В репозитории это уже исправлено
(`enable-default-deny: false` в конфиге), но если редактируете `resources`
сами — не забывайте про эту опцию.

### Тестирование

```bash
./scripts/test-oidc-login.sh http://localhost:4181/
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4181/    # ожидаем 302
```

### Проверка именно RBAC (то, чего нет у большинства других решений)

Правило `resources` требует роль `app-user` — оба тестовых пользователя её
имеют, поэтому по умолчанию негативный сценарий не воспроизвести. Чтобы
проверить, что RBAC реально работает, а не просто "пропускает всех":

1. Создайте в Keycloak (Admin Console → Users → Add user, либо см.
   [Приложение Б](#приложение-б-как-добавить-пользователя-без-роли-для-негативных-тестов-rbac))
   пользователя `norole` без ролей.
2. Запустите `./scripts/test-oidc-login.sh http://localhost:4181/ norole 'NoRole12345!'`.
3. Ожидаемый результат — скрипт должен завершиться ошибкой (403 Forbidden
   от gogatekeeper вместо "Hello World"), в отличие от oauth2-proxy/vouch-proxy,
   где такой пользователь прошёл бы (там нет проверки ролей).

### Остановка

```bash
docker compose -f proxies/gogatekeeper/docker-compose.yml down
```

---

## 3. vouch-proxy

**Порт:** 4182 · **URL:** http://localhost:4182/ · **Паттерн:** auth-subrequest (nginx `auth_request`)

### Как реализована авторизация

Здесь **два** контейнера: `nginx-vouch-front` (публикует порт 4182,
реализует классический `auth_request`) и `vouch-proxy` (сам не проксирует
приложение — только валидирует сессию и ведёт OIDC-хендшейк).

**`proxies/vouch-proxy/nginx.conf`** — front-nginx:
```nginx
location = /validate { internal; proxy_pass http://vouch-proxy:9090/validate; ... }
location / {
    auth_request /validate;                 # подзапрос к vouch-proxy на каждый запрос
    error_page 401 = @error401;             # 401 -> редирект на /login
    proxy_pass http://nginx-hello:80;
    proxy_set_header X-Forwarded-User $auth_resp_x_vouch_user;   # проброс identity
}
```

**`proxies/vouch-proxy/config.yml`** — сам vouch-proxy:

| Ключ | Значение | Смысл |
|---|---|---|
| `vouch.allowAllUsers: true` | | Пускать любого успешно аутентифицированного (нет привязки к домену) |
| `vouch.cookie.domain: localhost` | | Обязателен при `allowAllUsers: true` |
| `vouch.jwt.secret` | ≥44 символа base64 | Ключ подписи собственной JWT-cookie vouch-proxy |
| `oauth.auth_url` | `http://keycloak:8080/.../auth` | Endpoint, на который редиректится браузер |
| `oauth.token_url` / `oauth.user_info_url` | `http://keycloak:8080/...` | Endpoint'ы для серверных вызовов — **обязаны** совпадать по hostname с `auth_url` (см. врезку ниже) |
| `oauth.callback_url` | `http://localhost:4182/auth` | Публично видимый callback, должен совпадать с клиентом в Keycloak |

> **Почему `auth_url`/`token_url`/`user_info_url` заданы одним и тем же
> хостом `keycloak:8080`.** У vouch-proxy (в отличие от oauth2-proxy) нет
> единого `issuer-url` — эти три endpoint'а задаются раздельно, и это
> реальная ловушка: Keycloak привязывает claim `iss` в токене к хосту, с
> которого браузер инициировал `/auth`. Если `auth_url` указать как
> `http://localhost:8080/...`, а `token_url`/`user_info_url` — как
> `http://keycloak:8080/...`, то вызов `/userinfo` получит `401
> unexpected end of JSON input` из-за рассинхронизации issuer'а. Подробный
> разбор — в [`oauth-proxy-rnd.md`, раздел 6](oauth-proxy-rnd.md#6-типовые-грабли-внедрения-обнаружены-практически-в-рамках-rnd).

Файлы: `proxies/vouch-proxy/config.yml`, `proxies/vouch-proxy/nginx.conf`,
`proxies/vouch-proxy/docker-compose.yml`.

### Запуск

```bash
docker compose -f proxies/vouch-proxy/docker-compose.yml up -d
docker logs vouch-proxy --tail 20
# ожидаем: "starting Vouch Proxy" без строк уровня "error"
```

### Тестирование

```bash
./scripts/test-oidc-login.sh http://localhost:4182/
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4182/    # ожидаем 302

# Проверка identity-заголовка, проброшенного через auth_request_set в nginx.conf:
curl -s -b <jar> -D - -o /dev/null http://localhost:4182/ | grep -i x-debug
```

Ожидаемый заголовок: `X-Debug-Remote-Email: testuser@corp.local`. Имя cookie
сессии в браузере: `VouchCookie`.

### Остановка

```bash
docker compose -f proxies/vouch-proxy/docker-compose.yml down
```

---

## 4. Envoy (нативный OAuth2-фильтр)

**Порт:** 4183 (data plane), 9901 (admin) · **URL:** http://localhost:4183/ · **Паттерн:** нативный фильтр, без отдельного auth-сервиса

### Как реализована авторизация

Вся логика — внутри `envoy.filters.http.oauth2` в `proxies/envoy/envoy.yaml`,
отдельного auth-сервиса нет:

| Параметр | Значение | Смысл |
|---|---|---|
| `authorization_endpoint` | `http://keycloak:8080/.../auth` | **Задан вручную** — у фильтра нет OIDC discovery |
| `token_endpoint.uri` | `http://keycloak:8080/.../token` | Вызывается самим Envoy изнутри docker-сети |
| `redirect_uri` / `redirect_path_matcher` | `http://localhost:4183/callback` | |
| `credentials.client_id` | `envoy-client` | |
| `credentials.token_secret` / `hmac_secret` | через SDS (`token-secret.yaml`, `hmac-secret.yaml`) | client_secret и ключ подписи cookie — в проде эти файлы заменяются на настоящий SDS/control-plane (Vault и т.п.) |
| `forward_bearer_token: true` | | Access-токен пробрасывается апстриму как `Authorization: Bearer` |
| `node: {id, cluster}` | обязательно в bootstrap-конфиге | Без этой секции Envoy падает при старте с ошибкой валидации, если используются SDS-секреты |

Файлы: `proxies/envoy/envoy.yaml`, `proxies/envoy/token-secret.yaml`,
`proxies/envoy/hmac-secret.yaml`, `proxies/envoy/docker-compose.yml`.

### Запуск

```bash
docker compose -f proxies/envoy/docker-compose.yml up -d
docker logs envoy --tail 30
# ошибок валидации конфига быть не должно; проверить, что слушает 10000:
curl -s http://localhost:9901/listeners
```

Панель администрирования Envoy (полезно для отладки): http://localhost:9901/
— там же `/clusters` (health апстримов `keycloak`/`nginx_hello`) и
`/config_dump` (итоговая эффективная конфигурация).

### Тестирование

```bash
./scripts/test-oidc-login.sh http://localhost:4183/
curl -sv http://localhost:4183/ 2>&1 | grep -i location
# в Location должен быть authorization_endpoint с параметром code_challenge=...
# (Envoy сам добавляет PKCE, даже если явно не просили)
```

Cookie, которые ставит фильтр (имена настраиваются через `cookie_names`,
здесь оставлены по умолчанию, проверено фактическими `Set-Cookie` в ответе):
`BearerToken`, `IdToken`, `RefreshToken`, `OauthHMAC`, `OauthExpires` — все с
флагом `Secure` независимо от `http`/`https` на клиенте.

### Остановка

```bash
docker compose -f proxies/envoy/docker-compose.yml down
```

---

## 5. Traefik + ForwardAuth + oauth2-proxy

**Порт:** 4184 (данные), 8082 (dashboard) · **URL:** http://localhost:4184/ · **Паттерн:** auth-subrequest (ForwardAuth)

### Как реализована авторизация

Traefik OSS не имеет нативного OIDC middleware (это функция только
платного Traefik Hub), поэтому используется связка `ForwardAuth` +
отдельный инстанс `oauth2-proxy-traefik`.

**`proxies/traefik/dynamic.yml`:**
```yaml
routers:
  hello-app:
    rule: "PathPrefix(`/`)"
    middlewares: ["oauth2-auth"]
    service: nginx-hello
  oauth2-callback:                        # /oauth2/* идёт напрямую в oauth2-proxy, БЕЗ middleware
    rule: "PathPrefix(`/oauth2/`)"
    service: oauth2-proxy-traefik

middlewares:
  oauth2-auth:
    forwardAuth:
      address: "http://oauth2-proxy-traefik:4180/"   # КОРЕНЬ oauth2-proxy, не /oauth2/auth!
      authResponseHeaders: ["X-Auth-Request-User", "X-Auth-Request-Email", ...]
```

> **Почему адрес forwardAuth — корень `/`, а не `/oauth2/auth`.** Endpoint
> `/oauth2/auth` предназначен для nginx `auth_request` и всегда отдаёт
> "голый" 401 без `Location`. oauth2-proxy-traefik запущен с
> `--upstream=static://202` (см. ниже) — при валидной сессии его корень
> отдаёт 202 (Traefik пропускает запрос), а без сессии — полноценный 302 на
> Keycloak, который Traefik ретранслирует браузеру как есть.

**`proxies/traefik/docker-compose.yml`**, сервис `oauth2-proxy-traefik`
(отдельный от основного oauth2-proxy на 4180 — свой client_id/secret,
свой redirect_uri, порт наружу не публикуется):
```
--client-id=traefik-client
--redirect-url=http://localhost:4184/oauth2/callback
--upstream=static://202        # forward-auth режим: нет реального upstream
--reverse-proxy=true
```

Файлы: `proxies/traefik/traefik.yml` (статическая конфигурация, entryPoints
+ путь к dynamic.yml), `proxies/traefik/dynamic.yml`,
`proxies/traefik/docker-compose.yml`.

### Запуск

```bash
docker compose -f proxies/traefik/docker-compose.yml up -d
docker logs traefik --tail 20
docker logs oauth2-proxy-traefik --tail 20
```

Дашборд Traefik (RND-only, включён через `--api.insecure`):
http://localhost:8082/dashboard/ — там наглядно видно роутеры, middleware и
health сервисов.

### Тестирование

```bash
./scripts/test-oidc-login.sh http://localhost:4184/
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4184/    # ожидаем 302
```

**Частая ошибка при самостоятельной модификации:** если направить
`forwardAuth.address` на `/oauth2/auth` вместо корня — получите
бесконечный "залипший" 401 без редиректа на логин (Traefik ретранслирует
голый 401 как есть, редиректа никогда не будет).

### Остановка

```bash
docker compose -f proxies/traefik/docker-compose.yml down
```

---

## 6. OpenResty + lua-resty-openidc

**Порт:** 4185 · **URL:** http://localhost:4185/ · **Паттерн:** нативный (Lua-код внутри воркеров nginx)

### Как реализована авторизация

Требует кастомный образ (`proxies/nginx-openresty/Dockerfile` на основе
`openresty/openresty:*-alpine-fat`, ставит `lua-resty-openidc` через `opm`)
— в отличие от всех auth_request-решений, здесь нет отдельного сервиса и
конфиг лежит прямо в `nginx.conf`:

```nginx
access_by_lua_block {
    local opts = {
        redirect_uri    = "/redirect_uri",
        discovery       = "http://keycloak:8080/realms/corp-sso/.well-known/openid-configuration",
        client_id       = "nginx-openresty-client",
        client_secret   = "nginx-openresty-secret-CHANGEME",
        scope           = "openid email profile",
        session_contents = { id_token = true, access_token = true },
    }
    local res, err = require("resty.openidc").authenticate(opts)
    ...
}
proxy_pass http://nginx-hello:80;
```

`discovery` указывает на полный `.well-known/openid-configuration` (не
просто issuer) — библиотека сама вытащит из него authorize/token/jwks
endpoints и закэширует в `lua_shared_dict discovery`.

**Известное ограничение сборки:** `opm` по умолчанию подтягивает
`lua-resty-session` v4.x (HKDF через `resty.openssl`), несовместимую с
OpenSSL-обвязкой в этом базовом образе — в Dockerfile версия явно
зафиксирована на `lua-resty-session=3.10`. Если пересобираете образ и
уберёте эту фиксацию — получите рантайм-ошибку `attempt to call field 'new'
(a nil value)`.

Файлы: `proxies/nginx-openresty/Dockerfile`,
`proxies/nginx-openresty/nginx.conf`,
`proxies/nginx-openresty/docker-compose.yml`.

### Запуск

Единственное решение в стенде, которое нужно **собирать** (кастомный образ):

```bash
docker compose -f proxies/nginx-openresty/docker-compose.yml up -d --build
docker logs nginx-openresty --tail 30
```

### Тестирование

```bash
./scripts/test-oidc-login.sh http://localhost:4185/
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4185/    # ожидаем 302
```

**Известный нюанс:** заголовки `X-Forwarded-User`/`X-Forwarded-Email`,
которые `access_by_lua_block` должен проставлять апстриму из
`res.id_token`, на практике не всегда долетают до debug-заголовков
`nginx-hello` в этой сборке (в отличие от аналогичной проверки для
oauth2-proxy) — сама аутентификация при этом работает корректно (доступ к
`Hello World` есть). Если будете дорабатывать конфиг для реального
использования — обязательно перепроверьте этот момент через
`ngx.log(ngx.ERR, ...)` внутри `access_by_lua_block`.

### Остановка

```bash
docker compose -f proxies/nginx-openresty/docker-compose.yml down
```

---

## 7. HAProxy + Lua auth-request + oauth2-proxy

**Порт:** 4186 · **URL:** http://localhost:4186/ · **Паттерн:** auth-subrequest (Lua-скрипт)

### Как реализована авторизация

У open-source HAProxy нет встроенного OIDC login flow. Используется
паттерн `TimWolla/haproxy-auth-request`: Lua-скрипт делает auth-subrequest
к отдельному инстансу `oauth2-proxy-haproxy` (аналогично Traefik-варианту —
свой client_id/secret, `--upstream=static://202`, порт не публикуется).

**`proxies/haproxy/Dockerfile`** — собирает образ `haproxy` с Lua-рантаймом
и скачивает `haproxy-auth-request.lua` + зависимости
(`haproxy-lua-http`, `json.lua`).

**`proxies/haproxy/haproxy.cfg`** — ключевая логика:
```
global
    lua-prepend-path /usr/local/etc/haproxy/?.lua
    lua-load /usr/local/etc/haproxy/auth-request.lua

frontend fe_main
    acl is_oauth2_path path_beg /oauth2/
    # auth-subrequest на КАЖДЫЙ запрос, кроме самих /oauth2/* путей:
    http-request lua.auth-request auth_request_backend /oauth2/auth unless is_oauth2_path
    http-request set-header X-Auth-Request-User %[var(...)] if {...} !is_oauth2_path
    http-request redirect location http://localhost:4186/oauth2/start if !{...} !is_oauth2_path
    use_backend be_oauth2_proxy if is_oauth2_path
    default_backend be_nginx_hello
```

> **Ключевая ловушка HAProxy:** `use_backend` НЕ прерывает выполнение
> остальных `http-request` правил того же frontend'а (в отличие от,
> например, `return`/`deny` в nginx). Поэтому каждое auth-related правило
> явно исключает `/oauth2/*` через `unless is_oauth2_path` / `!is_oauth2_path`
> — без этого получится бесконечный redirect-loop на `/oauth2/start`. Ещё
> один нюанс: `haproxy-lua-http` нормализует имена заголовков ответа к
> нижнему регистру, поэтому переменная называется
> `var(req.auth_response_header.x_auth_request_user)`, а не с исходным
> регистром заголовка.

Файлы: `proxies/haproxy/Dockerfile`, `proxies/haproxy/haproxy.cfg`,
`proxies/haproxy/docker-compose.yml`.

### Запуск

Требует сборки образа:

```bash
docker compose -f proxies/haproxy/docker-compose.yml up -d --build
docker logs haproxy-oauth-rnd --tail 20
docker logs oauth2-proxy-haproxy --tail 20
```

### Тестирование

```bash
./scripts/test-oidc-login.sh http://localhost:4186/
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4186/    # ожидаем 302

# Проверка identity-заголовков, проброшенных Lua-скриптом на апстрим:
curl -s -b <jar> -D - -o /dev/null http://localhost:4186/ | grep -i x-auth-request
```

### Остановка

```bash
docker compose -f proxies/haproxy/docker-compose.yml down
```

---

## 8. Pomerium

**Порт:** 4187 (только HTTPS!) · **URL:** https://hello.localhost:4187/ · **Паттерн:** выделенный identity-aware proxy

### Как реализована авторизация

Архитектурная особенность Pomerium — отдельный **"authenticate" hostname**,
общий для всех защищаемых приложений (в проде — реальный поддомен вида
`authenticate.corp.example.com`); именно на него регистрируется redirect_uri
у Keycloak, а не на hostname конкретного приложения. Здесь используются
`hello.localhost` (приложение) и `authenticate.localhost` (аутентификация)
— оба порта 4187, маршрутизация между ними идёт по HTTP `Host`-заголовку.

**`proxies/pomerium/config.yaml`:**

| Ключ | Значение | Смысл |
|---|---|---|
| `authenticate_service_url` | `https://authenticate.localhost:4187` | Общий authenticate-hostname |
| `idp_provider: oidc` / `idp_provider_url` | `http://keycloak:8080/realms/corp-sso` | Единый issuer — как у oauth2-proxy, структурно защищён от hostname-рассинхронизации |
| `idp_client_id` / `idp_client_secret` | `pomerium-client` / `pomerium-secret-CHANGEME` | |
| `databroker_storage_type: file` | + `databroker_storage_connection_string: file:///pomerium/data/databroker` | Файловое хранилище сессий — без внешней БД, годится только для одного инстанса |
| `routes[0].from` | `https://hello.localhost:4187` | Публичный адрес защищаемого приложения |
| `routes[0].to` | `http://nginx-hello:80` | Апстрим |
| `routes[0].policy` | `allow: or: [domain: {is: corp.local}]` | Грубая авторизация по домену email — можно расширять до `claim`-based правил (context-aware — сильная сторона Pomerium) |
| `certificate_file` / `certificate_key_file` | `proxies/pomerium/certs/tls.crt` / `tls.key` | Самоподписанный сертификат для `*.localhost` |

> **Почему обязателен TLS, даже для локального теста.** CSRF/PKCE/
> authenticate-cookie у Pomerium **всегда** ставятся с флагом `Secure` —
> это захардкожено в коде (`authenticate/csrf.go`), конфигурационного
> override нет. Простой `insecure_server: true` (без TLS) здесь НЕ
> сработает: callback гарантированно упадёт с `invalid CSRF token`, т.к.
> curl/скрипты не отправят Secure-cookie по чистому HTTP. В реальном
> браузере это работало бы и без сертификата (у `*.localhost` есть
> secure-context исключение из спецификации), но для честного теста
> `curl`-скриптом в этом стенде поднят самоподписанный TLS-сертификат.
> Подробности — в [`oauth-proxy-rnd.md`, раздел
> 6](oauth-proxy-rnd.md#6-типовые-грабли-внедрения-обнаружены-практически-в-рамках-rnd).

Файлы: `proxies/pomerium/config.yaml`, `proxies/pomerium/certs/`,
`proxies/pomerium/docker-compose.yml`.

### Запуск

```bash
docker compose -f proxies/pomerium/docker-compose.yml up -d
docker logs pomerium --tail 30
# НЕ должно быть строк "unknown config option" или "error"
```

### Тестирование

**Обязательно используйте `-k`** (игнорировать самоподписанный сертификат)
и хостнеймы `hello.localhost`/`authenticate.localhost`, а не `localhost`:

```bash
./scripts/test-oidc-login.sh https://hello.localhost:4187/ testuser 'Test12345!' -k

# Негативный тест:
curl -sk -o /dev/null -w "%{http_code}\n" https://hello.localhost:4187/    # ожидаем 302
```

В браузере просто откройте `https://hello.localhost:4187/` и подтвердите
предупреждение о самоподписанном сертификате ("Дополнительно" → "Перейти
на сайт (небезопасно)") — дальше сценарий стандартный.

**Если получаете ошибку `Invalid parameter: redirect_uri` от Keycloak** —
проверьте, что вы используете именно `https://` (не `http://`) и именно
`hello.localhost` (не `localhost`) — Keycloak сверяет redirect_uri
посимвольно с тем, что прописано в клиенте (`https://authenticate.localhost:4187/oauth2/callback`).

### Остановка

```bash
docker compose -f proxies/pomerium/docker-compose.yml down
```

---

## 9. Apache APISIX + плагин openid-connect

**Порт:** 4188 · **URL:** http://localhost:4188/ · **Паттерн:** API-шлюз с managed OIDC-плагином

### Как реализована авторизация

Используется **standalone-режим** APISIX (`config_provider: yaml`) — маршруты
читаются из локального `apisix.yaml`, etcd не нужен вообще (упрощение по
сравнению с классическим APISIX-развёртыванием).

**`proxies/apisix/config.yaml`:**
```yaml
deployment:
  role: data_plane
  role_data_plane:
    config_provider: yaml   # standalone, без etcd
```

**`proxies/apisix/apisix.yaml`** — декларативный маршрут с плагином:
```yaml
routes:
  - uri: /*
    upstream_id: nginx-hello
    plugins:
      openid-connect:
        client_id: apisix-client
        client_secret: apisix-secret-CHANGEME
        discovery: http://keycloak:8080/realms/corp-sso/.well-known/openid-configuration
        redirect_uri: http://localhost:4188/callback
        scope: openid email profile
        set_userinfo_header: true      # кладёт userinfo в заголовок X-Userinfo апстриму
        session:
          secret: apisix-session-secret-min16chars-CHANGEME   # >= 16 символов, требование плагина
upstreams:
  - id: nginx-hello
    nodes: { "nginx-hello:80": 1 }
```

Плагин `openid-connect` полностью open-source в APISIX (в отличие от
аналогичного плагина в Kong Gateway — там только Enterprise-tier). Важный
нюанс формата: `discovery` — это **полный URL**
`.well-known/openid-configuration`, а не просто issuer, как у части других
решений (легко перепутать при переносе конфигурации между решениями).

Файлы: `proxies/apisix/config.yaml`, `proxies/apisix/apisix.yaml`,
`proxies/apisix/docker-compose.yml`.

### Запуск

```bash
docker compose -f proxies/apisix/docker-compose.yml up -d
docker logs apisix --tail 30
```

### Тестирование

```bash
./scripts/test-oidc-login.sh http://localhost:4188/
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4188/    # ожидаем 302

# Проверка identity: заголовок X-Userinfo содержит base64(JSON) с claims.
curl -s -b <jar> -D - -o /dev/null http://localhost:4188/ | grep -i x-debug-userinfo
# декодировать вручную:
echo "<значение заголовка>" | base64 -d
# ожидаем что-то вроде:
#   {"roles":["app-user"],"name":"Test User","email_verified":true,
#    "preferred_username":"testuser","email":"testuser@corp.local",...}
```

### Остановка

```bash
docker compose -f proxies/apisix/docker-compose.yml down
```

---

## Приложение А: остановка и полная очистка стенда

Остановить конкретное решение (не трогая базовый стенд и остальные):

```bash
docker compose -f proxies/<имя>/docker-compose.yml down
```

Остановить вообще всё, включая базовый стенд:

```bash
for f in proxies/*/docker-compose.yml; do docker compose -f "$f" down; done
docker compose down
```

Полная очистка с удалением volume'ов (сессии Pomerium, состояние APISIX и
т.п.) и локально собранных образов (nginx-openresty, haproxy-oauth-rnd):

```bash
for f in proxies/*/docker-compose.yml; do docker compose -f "$f" down -v; done
docker compose down -v
docker rmi nginx-openresty-nginx-openresty haproxy-haproxy-oauth-rnd 2>/dev/null || true
```

## Приложение Б: как добавить пользователя без роли для негативных тестов RBAC

Понадобится для проверки RBAC у gogatekeeper (раздел 2). Через Admin
Console:

1. http://localhost:8080/admin → realm `corp-sso` → **Users** → **Add user**.
2. Username: `norole`, Email: `norole@corp.local`, First name: `No`, Last
   name: `Role`, Email verified: On → **Create**. (Email/имя/фамилия важны:
   без них при первом логине Keycloak потребует заполнить "Update Account
   Information" вместо перехода сразу к проверке ролей — собьёт с толку при
   тестировании.)
3. Вкладка **Credentials** → **Set password**: `NoRole12345!`, Temporary: **Off**.
4. Вкладку **Role mapping** не трогаем — по умолчанию у пользователя нет
   ролей `app-user`/`app-admin`.
5. Проверка: `./scripts/test-oidc-login.sh http://localhost:4181/ norole 'NoRole12345!'`
   должна завершиться ошибкой (gogatekeeper отдаст 403 вместо контента
   приложения), в отличие от oauth2-proxy/vouch-proxy/большинства других
   решений в этом стенде, где ролей на уровне прокси не проверяется вовсе.

Через Admin REST API (без браузера), если нужно автоматизировать:

```bash
ADMIN_TOKEN=$(curl -s -X POST http://localhost:8080/realms/master/protocol/openid-connect/token \
  -d "client_id=admin-cli" -d "username=admin" -d "password=admin12345" -d "grant_type=password" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# email/firstName/lastName обязательны: без них Keycloak на первом же логине
# потребует "Update Account Information" (VERIFY_PROFILE) вместо пропуска
# сразу к проверке ролей на прокси — это никак не связано с RBAC gogatekeeper,
# но собьёт с толку при первом прогоне теста.
curl -s -X POST http://localhost:8080/admin/realms/corp-sso/users \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d '{"username":"norole","email":"norole@corp.local","firstName":"No","lastName":"Role",
       "enabled":true,"emailVerified":true,
       "credentials":[{"type":"password","value":"NoRole12345!","temporary":false}]}'
```

Проверено практически: `./scripts/test-oidc-login.sh http://localhost:4181/ norole 'NoRole12345!'`
для такого пользователя действительно завершается ошибкой — в статусах
редиректов виден финальный `403 Forbidden` от gogatekeeper вместо `200 OK` с
`Hello World`.
