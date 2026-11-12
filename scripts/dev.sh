#!/usr/bin/env bash
# Обновить код, собрать и (по желанию) сразу запустить запись.
#
#   ./scripts/dev.sh               git pull + сборка
#   ./scripts/dev.sh rec [папка]   то же + запустить rec
#
# Если сборка упала и задан MEETREC_REPORT_HOST — лог ошибок уходит на сервер
# (в ту же папку, что и отчёты): достаточно написать Claude «посмотри репорты».
# Отправляется только вывод компилятора, версии macOS/Swift и хеш коммита.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/config.sh"

echo "→ git pull"
git pull --ff-only

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
      echo "- git: $(git rev-parse --short HEAD)"
      echo "- macOS: $(sw_vers -productVersion 2>/dev/null || echo '?')"
      echo "- swift: $(swift --version 2>&1 | head -1)"
      echo
      echo '```'
      tail -n 300 "$build_log"
      echo '```'
    } | ssh -o BatchMode=yes -o ConnectTimeout=10 "$MEETREC_REPORT_HOST" \
          "mkdir -p '$remote_dir' && cat > '$remote_dir/$name'" \
      && echo "📤 лог сборки отправлен — напиши Claude «посмотри репорты»" \
      || echo "⚠️  не удалось отправить лог сборки"
  fi
  exit "$status"
fi
echo "✅ собрано: .build/release/rec"

if [[ "${1:-}" == "rec" ]]; then
  shift
  exec "$ROOT/.build/release/rec" "$@"
fi
