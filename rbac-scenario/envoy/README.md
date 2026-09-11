# RBAC-сценарий: Envoy (нативные фильтры oauth2 + jwt_authn + rbac)

Path-based RBAC на одном домене (`service2.localhost:5186`, только HTTPS):
`/` требует роль `Team2_Users`, `/admin` требует роль `Team2_Admins`.
Реализовано **полностью нативно внутри Envoy**, без отдельного auth-сервиса
(в отличие от связок oauth2-proxy/Traefik/HAProxy из этого же RBAC-исследования).

## 1. Архитектура

У фильтра `envoy.filters.http.oauth2` (уже использованного в основном стенде,
`proxies/envoy/`) своего RBAC нет — он только аутентифицирует и, с
`forward_bearer_token: true`, пробрасывает access_token апстриму как
`Authorization: Bearer <token>`. Чтобы получить path-based RBAC прямо в
Envoy, выстроена цепочка из **трёх** HTTP-фильтров (порядок в `http_filters`
важен — исполняются последовательно):

1. **`envoy.filters.http.oauth2`** — Authorization Code Flow с Keycloak, как
   в основном стенде: `authorization_endpoint`/`token_endpoint` заданы
   вручную (нет discovery), SDS-секреты (`token-secret.yaml`,
   `hmac-secret.yaml`), обязательна секция `node: {id, cluster}` в
   bootstrap-конфиге. `forward_bearer_token: true`.
2. **`envoy.filters.http.jwt_authn`** — повторно валидирует ТОТ ЖЕ JWT
   (access_token, который только что положил `Authorization: Bearer`
   предыдущий фильтр) через JWKS Keycloak
   (`http://keycloak:8080/realms/corp-sso/protocol/openid-connect/certs`,
   `remote_jwks` с кэшем 300s), и кладёт весь payload токена (включая claim
   `roles` — массив строк) в dynamic metadata под ключом `jwt_payload`.
   `audiences: []` — валидация audience отключена, т.к. access_token
   Keycloak по умолчанию не содержит `aud` под наш client_id (там служебный
   `account`); полагаемся на issuer + подпись JWKS.
3. **`envoy.filters.http.rbac`** — верхнеуровневый экземпляр в
   `http_filters` оставлен "запрещающим всё по умолчанию" (`action: ALLOW`
   с пустыми `policies`), а реальные policy заданы **per-route** через
   `typed_per_filter_config` у КАЖДОГО route в `route_config` — они
   полностью переопределяют (replace, не merge) top-level конфиг для этого
   route. `principals` каждой policy матчит `metadata`, положенную
   `jwt_authn`, по пути `envoy.filters.http.jwt_authn` → `jwt_payload` →
   `roles`, используя `list_match.one_of` (т.к. `roles` — список, а не
   скаляр) с `string_match.exact` на нужную роль.

Route для `/admin` (с policy на `Team2_Admins`) стоит **раньше** catch-all
route `/` (с policy на `Team2_Users`) в списке `routes` — Envoy матчит
routes по порядку, первый подходящий побеждает.

## 2. Конфигурация

Итоговый `envoy.yaml` (ключевые фрагменты, полный файл — рядом):

```yaml
route_config:
  virtual_hosts:
  - domains: ["*"]
    routes:
    - match: { prefix: "/admin" }        # ОБЯЗАН быть раньше "/"
      route: { cluster: service2_backend }
      typed_per_filter_config:
        envoy.filters.http.rbac:
          "@type": ...RBACPerRoute
          rbac:
            rules:
              action: ALLOW
              policies:
                "admins-only":
                  permissions: [{ any: true }]
                  principals:
                  - metadata:
                      filter: envoy.filters.http.jwt_authn
                      path: [{key: jwt_payload}, {key: roles}]
                      value: {list_match: {one_of: {string_match: {exact: "Team2_Admins"}}}}
    - match: { prefix: "/" }
      route: { cluster: service2_backend }
      typed_per_filter_config:
        envoy.filters.http.rbac:
          ...  # аналогично, но "Team2_Users"

http_filters:
- name: envoy.filters.http.oauth2
  typed_config: { ... как в основном стенде, redirect_uri: https://service2.localhost:5186/callback ... }
- name: envoy.filters.http.jwt_authn
  typed_config:
    providers:
      keycloak:
        issuer: "http://keycloak:8080/realms/corp-sso"
        remote_jwks: { http_uri: { uri: ".../certs", cluster: keycloak }, cache_duration: {seconds: 300} }
        payload_in_metadata: "jwt_payload"
        audiences: []
    rules:
    - match: { prefix: "/" }
      requires: { provider_name: "keycloak" }
- name: envoy.filters.http.rbac
  typed_config: { rules: { action: ALLOW, policies: {} } }   # deny-by-default fallback
- name: envoy.filters.http.router
```

### TLS вместо HTTP — самостоятельная находка

Изначально стенд поднимался на чистом HTTP (`http://service2.localhost:5186/`),
и падал на этапе callback с ошибкой `csrf token validation failed`. Причина:
у `envoy.filters.http.oauth2` cookie `OauthNonce`/`CodeVerifier` (PKCE/CSRF-
защита) **всегда** ставятся с флагом `Secure`, без конфигурационного
override — та же история, что и с CSRF-cookie у Pomerium в основном
RBAC-исследовании. Экспериментально подтверждено (см. историю команд):
curl отправляет Secure-cookie по чистому HTTP только для буквального хоста
`localhost` (собственная лояльность curl, не связана со спецификацией secure
context), но **не** для поддоменов вида `service2.localhost` — реальный
браузер обработал бы оба случая одинаково (secure-context исключение для
`*.localhost` из спецификации шире, чем то, что реализует curl). Решение —
самоподписанный сертификат (`certs/`) и `curl -k`, как и для Pomerium.

**Побочная находка:** приватный ключ сертификата, созданный `openssl`
локально, по умолчанию получает права `600` (только владелец) — Envoy
внутри контейнера работает под uid 101 (`envoy`), не имеющим доступа к
файлу с правами `600`, принадлежащему хостовому пользователю. Ошибка при
этом вводит в заблуждение: `Failed to load incomplete private key from
path` — на самом деле означает "не смог прочитать файл" (см. исходник
`tls_certificate_config_impl.cc`: `private_key_.empty()` после
`DataSource::read`), а не "файл повреждён/неполный", как можно подумать по
формулировке. Потребовался `chmod 644` на `tls.key`. Формат ключа (PKCS1
vs PKCS8) оказался тут ни при чём — это была ложная гипотеза, проверенная
и отброшенная в процессе отладки.

## 3. Результаты тестов

Все 6 пунктов тестовой матрицы пройдены (сессия каждого пользователя
сохранена в отдельный cookie jar через `JAR_OUT`, затем `/admin` проверялся
той же сессией отдельным `curl`):

| # | Сценарий | Ожидание | Реальный результат |
|---|---|---|---|
| 1 | Без сессии → `GET /` | 302 на Keycloak | `curl -sk -o /dev/null -w "%{http_code}"` → **302** ✅ |
| 2 | `team2user` → `GET /` | 200, "Team2_Users" | `test-oidc-login.sh` → **УСПЕХ**, текст найден ✅ |
| 3 | `team2user` (та же сессия) → `GET /admin` | 403 | `curl -sk -b jar .../admin` → **`HTTP/1.1 403 Forbidden`**, тело `RBAC: access denied` ✅ |
| 4 | `team2admin` → `GET /` | 200 | **УСПЕХ** ✅ |
| 5 | `team2admin` (та же сессия) → `GET /admin` | 200, "Team2_Admins" | **`HTTP/1.1 200 OK`**, тело содержит "Team2_Admins" (3 вхождения — заголовок+текст) ✅ |
| 6 | `testuser` (без Team2_*) → `GET /` | 403 | Цепочка редиректов дошла до `HTTP/1.1 403 Forbidden`, тело `RBAC: access denied` ✅ |

Все 6/6 пройдены без единого расхождения с ожиданием — связка
oauth2 + jwt_authn + rbac отработала корректно с первой рабочей конфигурации
(после исправления TLS/csrf и прав на ключ).

## 4. Ограничения

- **Объём и стиль конфигурации.** ~140 строк raw-proto YAML на ОДИН путь с
  ДВУМЯ ролями — заметно больше, чем декларативный список `resources` у
  gogatekeeper (7 строк) или policy-блок Pomerium. Каждая новая роль/путь —
  это ещё один блок `typed_per_filter_config` с полным дублированием
  структуры `metadata`/`path`/`value`. На 5-10 путей с разными ролями такой
  конфиг становится трудно читать и поддерживать вручную.
- **`Principal.metadata` — deprecated.** Envoy при старте явно предупреждает,
  что это поле будет удалено в пользу нового matcher API
  (`envoy.matching.matchers.metadata_matcher` через generic matcher API) —
  конфигурация рабочая СЕЙЧАС (v1.34), но потребует миграции в будущих
  версиях Envoy без обратной совместимости "навсегда".
- **Дублирование источника правды.** JWT валидируется ДВАЖДY: один раз
  неявно как часть OIDC-обмена в oauth2-фильтре, второй раз явно в
  jwt_authn для получения claims в metadata. Это не баг, а следствие того,
  что oauth2-фильтр не экспортирует claims токена в metadata сам —
  jwt_authn обязателен как "мост" между аутентификацией и RBAC-фильтром.
- **Ручной discovery/JWKS URL.** Как и в основном стенде — при смене
  realm/issuer нужно вручную поправить 3 места (authorization_endpoint,
  token_endpoint, jwt_authn.remote_jwks.http_uri), в отличие от
  `discovery-url`/`issuer_url` у gogatekeeper/oauth2-proxy/Pomerium.
- **Практическая рекомендация.** Такую конфигурацию имеет смысл писать
  руками только при уже стандартизованном "голом" Envoy без обвязки.
  Если в компании используется **Envoy Gateway**, `SecurityPolicy` CRD
  (генерирует oauth2-фильтр) и `AuthorizationPolicy`/JWT-based CRD заметно
  снижают объём ручного YAML и риск ошибки в глубоко вложенной
  proto-структуре — предпочтительный путь для прод-внедрения этого паттерна.
