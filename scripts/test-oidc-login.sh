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
# Переменные окружения (опционально):
#   EXPECT_TEXT — строка, которую ищем в финальном ответе как признак успеха
#                 (по умолчанию "Hello World" — контент nginx-hello из основного
#                 стенда). Для RBAC-сценария (rbac-scenario/) используйте,
#                 например, EXPECT_TEXT="область Team2_Users".
#   JAR_OUT      — если задан, cookie jar после успешного логина копируется
#                  туда и НЕ удаляется по завершении скрипта (по умолчанию
#                  jar временный и удаляется) — удобно, чтобы потом вручную
#                  curl'ить другие пути (например /admin) той же сессией:
#                    JAR_OUT=/tmp/team2user.jar ./scripts/test-oidc-login.sh \
#                      http://service2.localhost:5181/ team2user 'Team2User12345!'
#                    curl -b /tmp/team2user.jar http://service2.localhost:5181/admin
#
# Требования: curl, python3 (только для html.unescape, без внешних зависимостей).
# Перед первым запуском один раз добавьте в /etc/hosts: 127.0.0.1 keycloak
# (нужно почти всем сценариям — Keycloak должен резолвиться с хоста так же,
# как внутри docker-сети oauth-net).

set -euo pipefail

EXPECT_TEXT="${EXPECT_TEXT:-Hello World}"
JAR_OUT="${JAR_OUT:-}"

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
echo "==> [3/3] Проверка результата (ищем: \"$EXPECT_TEXT\")"
if grep -q -- "$EXPECT_TEXT" "$RESULT"; then
  echo "УСПЕХ: ожидаемый контент найден в ответе."
  echo
  echo "--- Заголовки финального ответа (для проверки identity/claims) ---"
  curl -sS "${EXTRA_CURL_OPTS[@]}" -b "$JAR" -D - -o /dev/null "$URL" | grep -Ei "^HTTP|^x-"
  if [ -n "$JAR_OUT" ]; then
    cp "$JAR" "$JAR_OUT"
    echo
    echo "Cookie jar сохранён в $JAR_OUT (не будет удалён) — используйте для"
    echo "дальнейших запросов той же сессией: curl -b \"$JAR_OUT\" ${EXTRA_CURL_OPTS[*]:-} <URL>"
  fi
  exit 0
else
  echo "ОШИБКА: \"$EXPECT_TEXT\" не найден в финальном ответе."
  echo "--- Тело ответа (может быть страницей ошибки Keycloak/прокси) ---"
  cat "$RESULT"
  if [ -n "$JAR_OUT" ]; then
    cp "$JAR" "$JAR_OUT"
    echo "(Cookie jar всё равно сохранён в $JAR_OUT для отладки.)"
  fi
  exit 1
fi
