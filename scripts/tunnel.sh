#!/usr/bin/env bash
# Поднимает (если ещё не поднят) SSH-туннель 127.0.0.1:PORT → сервер:127.0.0.1:PORT к meetrec-gateway.
# Тот же SSH-ключ, что и для отчётов; на сервере наружу ничего не открыто.
#   MEETREC_GATEWAY_SSH   user@server (обязательно)
#   MEETREC_GATEWAY_PORT  порт шлюза на сервере и локально (по умолчанию 8787)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/config.sh"
HOST="${MEETREC_GATEWAY_SSH:?задай MEETREC_GATEWAY_SSH (user@server)}"
PORT="${MEETREC_GATEWAY_PORT:-}"
PORT="${PORT:-8787}"

STATE_DIR="$HOME/.cache/meetrec"
STATE="$STATE_DIR/tunnel-$PORT"   # «host pid» туннеля, который поднял meetrec
mkdir -p "$STATE_DIR"

up() { nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; }

if up; then
  old_host="" old_pid=""
  if [[ -f "$STATE" ]]; then read -r old_host old_pid < "$STATE" || true; fi
  if [[ -n "${old_pid:-}" ]] && kill -0 "$old_pid" 2>/dev/null; then
    [[ "$old_host" == "$HOST" ]] && exit 0         # наш туннель к нужному серверу
    kill "$old_pid" 2>/dev/null || true            # наш, но к другому серверу — пересоздаём
    for _ in $(seq 1 20); do up || break; sleep 0.1; done
  else
    echo "порт 127.0.0.1:$PORT занят другим процессом (не туннелем meetrec) — смени порт шлюза" >&2
    exit 1
  fi
fi

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
pid="$(pgrep -n -f "ssh -f -N .*-L 127.0.0.1:$PORT:127.0.0.1:$PORT $HOST" || true)"
echo "$HOST ${pid:-}" > "$STATE"
for _ in $(seq 1 20); do up && exit 0; sleep 0.25; done
echo "туннель к $HOST:$PORT не поднялся" >&2
exit 1
