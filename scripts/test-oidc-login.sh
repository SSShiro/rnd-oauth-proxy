#!/usr/bin/env bash
# Универсальный скрипт для сквозной (end-to-end) проверки Authorization Code
# Flow через любой из oauth-proxy стендов этого репозитория, без браузера.
#
# Что делает:
#   1. GET на URL прокси -> проходит по цепочке редиректов до формы логина Keycloak;
#   2. вытаскивает "action" HTML-формы логина (там же session_code/execution/state);
#   3. POST'ит туда username/password, следуя редиректам обратно до защищённого приложения;
#   4. печатает цепочку HTTP-статусов и проверяет, что в финальном ответе есть "Hello World".
#
# Использование:
#   ./scripts/test-oidc-login.sh <URL> [username] [password] [доп. опции curl]
#
# Примеры:
#   ./scripts/test-oidc-login.sh http://localhost:4180/
#   ./scripts/test-oidc-login.sh http://localhost:4181/ testuser 'Test12345!'
#   ./scripts/test-oidc-login.sh https://hello.localhost:4187/ testuser 'Test12345!' -k
#
# Требования: curl, python3 (только для html.unescape, без внешних зависимостей).
# Перед первым запуском один раз добавьте в /etc/hosts: 127.0.0.1 keycloak
# (нужно почти всем сценариям — Keycloak должен резолвиться с хоста так же,
# как внутри docker-сети oauth-net).

set -euo pipefail

URL="${1:?Usage: $0 <url> [username] [password] [extra curl opts...]}"
USERNAME="${2:-testuser}"
PASSWORD="${3:-Test12345!}"
shift $(( $# >= 3 ? 3 : $# ))
EXTRA_CURL_OPTS=("$@")

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

JAR="$WORKDIR/cookies.txt"
LOGIN_PAGE="$WORKDIR/login.html"
HEADERS1="$WORKDIR/headers1.txt"
RESULT="$WORKDIR/result.html"
HEADERS2="$WORKDIR/headers2.txt"

echo "==> [1/3] GET $URL (ожидаем цепочку редиректов до формы логина Keycloak)"
curl -sS "${EXTRA_CURL_OPTS[@]}" -c "$JAR" -L -D "$HEADERS1" -o "$LOGIN_PAGE" "$URL"
echo "--- Статусы ---"
grep -E "^HTTP" "$HEADERS1"

ACTION="$(grep -oE 'action="[^"]+"' "$LOGIN_PAGE" | head -1 \
  | sed 's/action="//;s/"$//' \
  | python3 -c "import sys, html; print(html.unescape(sys.stdin.read()))")"

if [ -z "$ACTION" ]; then
  echo
  echo "!!! Форма логина Keycloak не найдена в ответе."
  echo "    Возможные причины: редирект не дошёл до Keycloak (проверьте, что"
  echo "    в /etc/hosts есть 'keycloak' и что базовый стенд поднят), либо"
  echo "    прокси уже отдал защищённый контент без логина (сессия из"
  echo "    предыдущего запуска ещё жива — используйте новый cookie jar,"
  echo "    этот скрипт создаёт его заново при каждом запуске)."
  echo
  echo "--- Первые 40 строк полученной страницы ---"
  head -40 "$LOGIN_PAGE"
  exit 1
fi

echo
echo "==> [2/3] POST учётных данных ($USERNAME) в форму логина Keycloak"
curl -sS "${EXTRA_CURL_OPTS[@]}" -c "$JAR" -b "$JAR" -L -D "$HEADERS2" -o "$RESULT" \
  --data-urlencode "username=$USERNAME" \
  --data-urlencode "password=$PASSWORD" \
  "$ACTION"
echo "--- Статусы ---"
grep -E "^HTTP" "$HEADERS2"

echo
echo "==> [3/3] Проверка результата"
if grep -q "Hello World" "$RESULT"; then
  echo "УСПЕХ: получен контент защищённого приложения nginx-hello."
  echo
  echo "--- Заголовки финального ответа (для проверки identity/claims) ---"
  curl -sS "${EXTRA_CURL_OPTS[@]}" -b "$JAR" -D - -o /dev/null "$URL" | grep -Ei "^HTTP|^x-"
  echo
  echo "Cookie jar сохранён во временном каталоге на время работы скрипта;"
  echo "для повторных ручных запросов с этой же сессией используйте:"
  echo "  curl -b \"$JAR\" ${EXTRA_CURL_OPTS[*]:-} \"$URL\"   # (файл будет удалён после завершения скрипта)"
  exit 0
else
  echo "ОШИБКА: 'Hello World' не найден в финальном ответе."
  echo "--- Тело ответа (может быть страницей ошибки Keycloak/прокси) ---"
  cat "$RESULT"
  exit 1
fi
