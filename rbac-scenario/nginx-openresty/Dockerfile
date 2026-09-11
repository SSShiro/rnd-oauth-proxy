FROM openresty/openresty:1.25.3.1-alpine-fat

# alpine-fat содержит opm и luarocks, нужные для установки lua-resty-openidc и его зависимостей.
# lua-resty-session жёстко пинуется на 3.10: ветка 4.x использует HKDF через resty.openssl,
# который на этом базовом образе (OpenSSL из openresty-alpine) падает с "attempt to call field 'new' (a nil value)".
RUN opm get bungle/lua-resty-session=3.10 \
 && opm get zmartzone/lua-resty-openidc

COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
