# HAProxy не умеет OIDC "из коробки" — паттерн auth-request реализуется
# через Lua-скрипт сообщества (github.com/TimWolla/haproxy-auth-request).
# Официальный alpine-образ собран с поддержкой Lua (USE_LUA=1).
FROM haproxy:2.9-alpine

USER root
RUN apk add --no-cache curl \
    && curl -fsSL -o /usr/local/etc/haproxy/auth-request.lua \
       https://raw.githubusercontent.com/TimWolla/haproxy-auth-request/master/auth-request.lua \
    # auth-request.lua делает require("haproxy-lua-http") — это submodule
    # haproxytech/haproxy-lua-http, кладём рядом как haproxy-lua-http.lua
    && curl -fsSL -o /usr/local/etc/haproxy/haproxy-lua-http.lua \
       https://raw.githubusercontent.com/haproxytech/haproxy-lua-http/master/http.lua \
    # haproxy-lua-http.lua, в свою очередь, требует чистый Lua JSON-модуль
    && curl -fsSL -o /usr/local/etc/haproxy/json.lua \
       https://raw.githubusercontent.com/rxi/json.lua/master/json.lua
USER haproxy
