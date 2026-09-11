# RBAC-сценарий: Apache APISIX + плагин openid-connect

Path-based RBAC на одном домене `service2.localhost:5183`:
- `/` (и всё кроме `/admin`) — требуется роль `Team2_Users`
- `/admin` — требуется роль `Team2_Admins`

## Архитектура

Один инстанс APISIX, standalone-режим (`config_provider: yaml`, без etcd),
как и в основном стенде (`proxies/apisix/`). Два `route` на общий upstream
`service2-backend:80`:

- `service2-admin` — `uris: [/admin, /admin/*]`, priority 10.
- `service2-root` — `uri: /*`, priority 1.

У плагина `openid-connect` нет встроенного "требовать роль X" — он только
аутентифицирует и (с `set_userinfo_header: true`) кладёт userinfo в
заголовок `X-Userinfo` запроса к upstream (base64 JSON). Роль проверяется
ДОПОЛНИТЕЛЬНЫМ плагином `serverless-pre-function` в той же route: он читает
`X-Userinfo`, декодирует base64+JSON, проверяет массив `roles` на нужное
значение, и если роли нет — `core.response.exit(403, {...})`.

**Критичный нюанс — порядок выполнения плагинов.** APISIX выполняет плагины
в порядке УБЫВАНИЯ `priority` (больше — раньше). У `openid-connect`
приоритет ~2599, у `serverless-pre-function` по умолчанию 10000 — то есть
без явного вмешательства role-check выполнился бы РАНЬШЕ аутентификации, и
`X-Userinfo` ещё не существовал бы. Решение — явно понизить приоритет
`serverless-pre-function` через `_meta.priority: 2000` (< 2599), чтобы он
гарантированно шёл ПОСЛЕ `openid-connect`. Проверено эмпирически: без этого
override role-check ломается (не видит заголовок / видит его от
предыдущего запроса), с ним — работает стабильно.

## Найденные и исправленные грабли

1. **`/admin/*` не матчит голый `/admin`** (без слэша) — запрос без
   слэша проваливался в route `/*` и проходил под проверкой `Team2_Users`
   вместо `Team2_Admins`. Исправлено: `uris: [/admin, /admin/*]` вместо
   одного `uri: /admin/*`.
2. **Bind-mount одного файла + редактирование хостовым инструментом
   (atomic replace/rename) не подхватывается APISIX standalone hot-reload**
   — контейнер продолжал видеть старую версию `apisix.yaml` по старому
   inode. Лечится через `docker compose up -d --force-recreate` после
   правки конфига вместо надежды на анонсированный APISIX-ем 1-секундный
   watch-reload. Это особенность конкретного докер bind-mount + способа
   записи файла инструментом редактирования, не баг APISIX как такового —
   но раз столкнулись, стоит знать при разработке конфигов.
3. **301-редирект backend'а с потерей порта** (`Location:
   http://service2.localhost/admin/` без `:5183`) — общая инфраструктурная
   деталь `service2-backend`, не специфична для APISIX (см. `git log` /
   комментарий в `rbac-scenario/service2-backend/nginx.conf` — исправлено
   через `location = /admin { alias ...; }` без редиректа).

## Тестовая матрица — все 6 сценариев пройдены

| № | Пользователь | Путь | Ожидание | Результат | Код |
|---|---|---|---|---|---|
| 1 | (нет сессии) | `/` | редирект на Keycloak | ✅ | `302` |
| 2 | `team2user` | `/` | 200, контент Team2_Users | ✅ | `200` |
| 3 | `team2user` | `/admin` | отказ | ✅ | `403` `{"message":"Forbidden: missing role Team2_Admins"}` |
| 4 | `team2admin` | `/` | 200 | ✅ | `200` |
| 5 | `team2admin` | `/admin` | 200, контент Team2_Admins | ✅ | `200` |
| 6 | `testuser` (без Team2_*) | `/` | отказ | ✅ | `403` `{"message":"Forbidden: missing role Team2_Users"}` |

Команды (из корня репозитория, после `docker compose -f
rbac-scenario/apisix/docker-compose.yml up -d`):

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://service2.localhost:5183/   # 1: 302

JAR_OUT=/tmp/team2user.jar EXPECT_TEXT="Team2_Users" \
  ./scripts/test-oidc-login.sh http://service2.localhost:5183/ team2user 'Team2User12345!'  # 2: успех
curl -s -o /dev/null -w "%{http_code}\n" -b /tmp/team2user.jar http://service2.localhost:5183/admin  # 3: 403

JAR_OUT=/tmp/team2admin.jar EXPECT_TEXT="Team2_Users" \
  ./scripts/test-oidc-login.sh http://service2.localhost:5183/ team2admin 'Team2Admin12345!'  # 4: успех
curl -s -o /dev/null -w "%{http_code}\n" -b /tmp/team2admin.jar http://service2.localhost:5183/admin  # 5: 200

JAR_OUT=/tmp/testuser.jar EXPECT_TEXT="Forbidden" \
  ./scripts/test-oidc-login.sh http://service2.localhost:5183/ testuser 'Test12345!'  # 6: 403
```

## Ограничения / выводы для сравнения с другими решениями

- В отличие от декларативного `resources: [{uri, roles}]` у gogatekeeper,
  здесь RBAC-логика — это **написанный вручную Lua-код** внутри
  `serverless-pre-function`, а не встроенная функция плагина
  `openid-connect`. Работает надёжно, но требует понимания порядка
  выполнения плагинов APISIX (см. грабли выше) — не очевидно "из коробки"
  для человека, не знакомого с внутренней моделью APISIX.
- Плюс такого подхода — гибкость: проверка роли может быть произвольно
  сложной (Lua), в т.ч. комбинировать несколько условий, обращаться к
  внешним сервисам и т.п. — то, что недоступно в декларативном
  `resources:` gogatekeeper или простом `allow/claim` у Pomerium.
- Формат `discovery` в плагине — это **полный URL**
  `.well-known/openid-configuration`, а не просто issuer (как у некоторых
  других решений) — источник ошибок при копировании конфигурации между
  решениями.
- Standalone-режим (без etcd) снова подтвердил себя как удачное упрощение
  для одноинстансового RND/dev-стенда — не пришлось поднимать etcd для
  двух route.
- Каждый route дублирует `openid-connect` конфиг — использован YAML-якорь
  (`&oidc-config` / `*oidc-config`), чтобы не копипастить client_id/secret
  дважды.

## Файлы

- `docker-compose.yml` — сервис `apisix-rbac`, порт `5183:9080`.
- `config.yaml` — standalone-конфигурация APISIX.
- `apisix.yaml` — два route с `openid-connect` + `serverless-pre-function`.
