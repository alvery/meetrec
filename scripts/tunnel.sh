#!/usr/bin/env bash
# Поднимает (если ещё не поднят) SSH-туннель 127.0.0.1:PORT → сервер:127.0.0.1:PORT к meetrec-gateway.
# Тот же SSH-ключ, что и для отчётов; на сервере наружу ничего не открыто.
#   MEETREC_GATEWAY_SSH   user@server (обязательно)
#   MEETREC_GATEWAY_PORT  порт шлюза на сервере и локально (по умолчанию 8787)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/config.sh"
HOST="${MEETREC_GATEWAY_SSH:?задай MEETREC_GATEWAY_SSH (user@server)}"
PORT="${MEETREC_GATEWAY_PORT:-8787}"

up() { nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; }
up && exit 0

# Вывод ssh — во временный файл: ушедший в фон ssh (-f) иначе держал бы открытым stdout/stderr
# вызывающего (приложения, run_actions.py), и тот ждал бы конца вывода вечно.
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
if ! ssh -f -N -o BatchMode=yes -o ConnectTimeout=10 -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -L "127.0.0.1:$PORT:127.0.0.1:$PORT" "$HOST" >/dev/null 2>"$err"; then
  cat "$err" >&2
  exit 1
fi
for _ in $(seq 1 20); do up && exit 0; sleep 0.25; done
echo "туннель к $HOST:$PORT не поднялся" >&2
exit 1
