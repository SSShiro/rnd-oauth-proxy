# RND: OAuth2/OIDC proxy перед Keycloak SSO

Тестовый стенд для сравнения решений, добавляющих OpenID Connect
аутентификацию через корпоративный Keycloak перед приложениями,
которые сами OIDC не поддерживают (`nginx-hello` — заглушка такого приложения).

Результаты исследования и сравнение решений:

- **[docs/oauth-proxy-rnd.md](docs/oauth-proxy-rnd.md)** — полный отчёт (требования,
  сравнительная таблица, разбор каждого решения, грабли внедрения, рекомендации).
- **[docs/oauth-proxy-rnd-confluence.txt](docs/oauth-proxy-rnd-confluence.txt)** —
  тот же отчёт в формате Confluence Wiki Markup, для импорта через
  Confluence → Space Tools → Content Tools → Import → Confluence Wiki Markup files.

## Структура

```
docker-compose.yml           # базовый стенд: Keycloak + nginx-hello (сеть oauth-net)
keycloak/import/             # автоимпортируемый realm "corp-sso" со всеми клиентами
nginx-hello/                 # тестовое "legacy" приложение без OIDC
proxies/
  oauth2-proxy/               # oauth2-proxy (порт 4180)
  gogatekeeper/                # gogatekeeper / Keycloak Gatekeeper (порт 4181)
  vouch-proxy/                # vouch-proxy + nginx auth_request (порт 4182)
  envoy/                       # нативный OAuth2-фильтр Envoy (порт 4183)
  traefik/                     # Traefik + ForwardAuth + oauth2-proxy (порт 4184)
  nginx-openresty/             # OpenResty + lua-resty-openidc (порт 4185)
  haproxy/                     # HAProxy + Lua auth-request + oauth2-proxy (порт 4186)
  pomerium/                     # Pomerium identity-aware proxy (порт 4187, TLS)
  apisix/                       # Apache APISIX + плагин openid-connect (порт 4188)
docs/oauth-proxy-rnd.md               # итоговый отчёт (Markdown)
docs/oauth-proxy-rnd-confluence.txt   # тот же отчёт для импорта в Confluence
```

## Запуск

```bash
# 1. Базовый стенд (обязателен для любого из решений ниже)
docker compose up -d

# 2. Добавить в /etc/hosts (нужно только для локального теста с хоста,
#    т.к. часть решений использует единый OIDC-endpoint и для браузера,
#    и для backend-вызовов):
echo "127.0.0.1 keycloak" | sudo tee -a /etc/hosts

# 3. Любое из решений, например oauth2-proxy:
docker compose -f proxies/oauth2-proxy/docker-compose.yml up -d
```

Keycloak admin console: http://localhost:8080/admin (`admin` / `admin12345`)
Realm: `corp-sso`. Тестовые пользователи: `testuser`/`Test12345!` (роль `app-user`),
`adminuser`/`Admin12345!` (роли `app-user`, `app-admin`).

| Решение | URL | Контейнер(ы) |
|---|---|---|
| oauth2-proxy | http://localhost:4180/ | oauth2-proxy |
| gogatekeeper | http://localhost:4181/ | gogatekeeper |
| vouch-proxy | http://localhost:4182/ | vouch-proxy, nginx-vouch-front |
| Envoy (native oauth2 filter) | http://localhost:4183/ | envoy |
| Traefik + ForwardAuth + oauth2-proxy | http://localhost:4184/ | traefik, oauth2-proxy-traefik |
| Nginx/OpenResty + lua-resty-openidc | http://localhost:4185/ | nginx-openresty |
| HAProxy + Lua auth-request + oauth2-proxy | http://localhost:4186/ | haproxy-oauth-rnd, oauth2-proxy-haproxy |
| Pomerium (identity-aware proxy) | https://hello.localhost:4187/ (самоподписанный TLS, `curl -k`) | pomerium |
| Apache APISIX + плагин openid-connect | http://localhost:4188/ | apisix |

Все 9 сценариев подняты и проверены end-to-end (полный Authorization Code
flow: редирект на Keycloak → логин → редирект обратно → 200 с содержимым
`nginx-hello`) в рамках этого RND.

Pomerium — единственное решение в стенде, работающее строго по HTTPS: его
CSRF-cookie всегда ставится с флагом `Secure` (без конфигурационного override),
поэтому по чистому HTTP callback распадается с `invalid CSRF token`. В реальном
браузере это не проблема (у `*.localhost` есть secure-context исключение), но
для честного end-to-end теста curl'ом в стенде используется самоподписанный
сертификат `proxies/pomerium/certs/` — используйте `curl -k` или добавьте
сертификат в доверенные локально.

## Важные нюансы стенда

- Все секреты клиентов (`*-secret-CHANGEME`) — тестовые, лежат в открытом виде
  в `keycloak/import/realm-export.json`. Для прод-стенда — только через
  секрет-менеджер/Vault, никогда в git.
- `sslRequired: none` и `secure-cookie/cookie.secure: false` в конфигах —
  только для HTTP RND-стенда. В проде обязателен TLS end-to-end.
- Несколько решений (vouch-proxy, HAProxy+oauth2-proxy, Envoy) чувствительны
  к согласованности hostname Keycloak между браузером и backend-вызовами —
  подробности см. в итоговом документе, раздел "Типовые грабли внедрения".
