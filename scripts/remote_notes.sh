#!/usr/bin/env bash
# Генерация заметок на сервере, а не на маке: транскрипт (stdin) уходит по SSH
# в `claude -p` на сервере, заметки возвращаются в stdout. На сервере ничего не сохраняется.
#
# Использование (так его вызывает process.sh): remote_notes.sh "<промпт>" < transcript.md
# Сервер: MEETREC_NOTES_HOST, иначе MEETREC_REPORT_HOST.
set -euo pipefail
prompt="${1:?usage: remote_notes.sh <prompt> < transcript}"
host="${MEETREC_NOTES_HOST:-${MEETREC_REPORT_HOST:?задай MEETREC_NOTES_HOST или MEETREC_REPORT_HOST}}"

# Промпт передаём в base64 — без проблем с кавычками в удалённой команде.
prompt_b64="$(printf '%s' "$prompt" | base64 | tr -d '\n')"
# Неинтерактивная SSH-сессия может не видеть ~/.local/bin в PATH — добавляем явно.
ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
  "PATH=\"\$HOME/.local/bin:\$PATH\" claude -p \"\$(printf '%s' '$prompt_b64' | base64 -d)\""
