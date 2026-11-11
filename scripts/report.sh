#!/usr/bin/env bash
# Собирает технический отчёт по встрече и отправляет его на сервер по SSH.
# Аудио, транскрипты и заметки НЕ отправляются — только система, устройства, параметры файлов и логи.
#
# Использование: ./scripts/report.sh <meeting-dir> [комментарий]
#
# Настройка (~/.config/meetrec/env):
#   MEETREC_REPORT_HOST=user@server     куда слать (любой хост из ~/.ssh/config тоже подойдёт)
#   MEETREC_REPORT_DIR=meetrec-reports  папка на сервере (относительно домашней)
set -euo pipefail
shopt -s nullglob

DIR="${1:?usage: report.sh <meeting-dir> [комментарий]}"
DIR="$(cd "$DIR" && pwd)"
NOTE="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/config.sh"
HOST="${MEETREC_REPORT_HOST:?задай MEETREC_REPORT_HOST в $CONFIG (например user@server)}"
REMOTE_DIR="${MEETREC_REPORT_DIR:-meetrec-reports}"

section() { printf '\n## %s\n\n```\n' "$1"; }
endsection() { printf '```\n'; }

report="$(mktemp)"
trap 'rm -f "$report"' EXIT

{
  echo "# meetrec report: $(basename "$DIR")"
  echo
  echo "- time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ -n "$NOTE" ]]; then echo "- note: $NOTE"; fi

  section "Система"
  sw_vers || true
  sysctl -n machdep.cpu.brand_string hw.memsize || true
  echo "git: $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?'), изменённых файлов: $(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  brew list --versions whisper-cpp 2>/dev/null || echo "whisper-cpp: ?"
  claude --version 2>/dev/null || echo "claude: ?"
  endsection

  section "Аудиоустройства"
  system_profiler SPAudioDataType 2>/dev/null || echo "(system_profiler недоступен)"
  endsection

  section "Файлы встречи"
  ls -la "$DIR" || true
  for f in "$DIR"/*.caf "$DIR"/*.m4a; do
    echo
    afinfo "$f" 2>&1 | grep -v '^[[:space:]]*$' | head -15 || true
  done
  endsection

  for logf in rec.log process.log; do
    section "$logf"
    if [[ -f "$DIR/$logf" ]]; then tail -n 400 "$DIR/$logf"; else echo "(нет)"; fi
    endsection
  done
} > "$report" 2>&1

base="$(basename "$DIR")"
name="$(date -u +%Y%m%dT%H%M%SZ)-${base//[^A-Za-z0-9._-]/_}.md"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
  "mkdir -p '$REMOTE_DIR' && cat > '$REMOTE_DIR/$name'" < "$report"
echo "📤 отчёт отправлен: $HOST:$REMOTE_DIR/$name"
