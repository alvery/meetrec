#!/usr/bin/env bash
# Обновить код, собрать и (по желанию) сразу запустить запись.
#
#   ./scripts/dev.sh               git pull + сборка
#   ./scripts/dev.sh rec [папка]   то же + запустить rec
#   ./scripts/dev.sh app           то же + собрать/переустановить/перезапустить meetrec.app
#
# Если сборка упала и задан MEETREC_REPORT_HOST — лог ошибок уходит на сервер
# (в ту же папку, что и отчёты): достаточно написать Claude «посмотри репорты».
# Отправляется только вывод компилятора, версии macOS/Swift и хеш коммита.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/config.sh"

case "${1:-}" in
  ""|rec|app) ;;
  *) echo "usage: ./scripts/dev.sh [rec [папка] | app]"; exit 1 ;;
esac

# Не удалось обновиться (нет сети, локальные правки) — не повод не записать встречу:
# предупреждаем и собираем/запускаем то, что есть.
echo "→ git pull"
if ! GIT_TERMINAL_PROMPT=0 git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 pull --ff-only; then
  echo "⚠️  git pull не удался — продолжаю с текущей версией кода"
fi

echo "→ swift build -c release"
build_log="$(mktemp)"
trap 'rm -f "$build_log"' EXIT
set +e
swift build -c release 2>&1 | tee "$build_log"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
  echo "❌ сборка не удалась (код $status)"
  if [[ -n "${MEETREC_REPORT_HOST:-}" ]]; then
    remote_dir="${MEETREC_REPORT_DIR:-meetrec-reports}"
    name="$(date -u +%Y%m%dT%H%M%SZ)-build-failed.md"
    {
      echo "# build failed"
      echo
      echo "- git: $(git rev-parse --short HEAD), локальных изменений: $(git status --porcelain | wc -l | tr -d ' ')"
      echo "- macOS: $(sw_vers -productVersion 2>/dev/null || echo '?')"
      echo "- swift: $(swift --version 2>&1 | head -1)"
      echo
      echo "## Ошибки"
      echo
      echo '```'
      grep -n 'error:' "$build_log" | head -n 50 || true
      echo '```'
      echo
      echo "## Полный лог (первые 2000 строк)"
      echo
      echo '```'
      head -n 2000 "$build_log"
      echo '```'
    } | ssh -o BatchMode=yes -o ConnectTimeout=10 "$MEETREC_REPORT_HOST" \
          "mkdir -p '$remote_dir' && cat > '$remote_dir/$name'" \
      && echo "📤 лог сборки отправлен — напиши Claude «посмотри репорты»" \
      || echo "⚠️  не удалось отправить лог сборки"
  fi
  exit "$status"
fi
echo "✅ собрано: .build/release/rec"

if [[ "${1:-}" == "app" ]]; then
  rm -f "$build_log"
  trap - EXIT
  exec "$ROOT/scripts/build-app.sh"
fi

if [[ "${1:-}" == "rec" ]]; then
  shift
  rm -f "$build_log"
  trap - EXIT
  exec "$ROOT/.build/release/rec" "$@"
fi
