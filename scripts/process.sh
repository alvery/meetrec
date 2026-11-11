#!/usr/bin/env bash
# Обработка записанной встречи:
#   mic.caf + system.caf → транскрипция (whisper.cpp) → transcript.md → notes.md (claude -p)
#
# Использование: ./scripts/process.sh ~/Meetings/2026-11-11-153000
#
# Переменные окружения:
#   WHISPER_MODEL  путь к ggml-модели (по умолчанию models/ggml-large-v3-turbo.bin)
#   WHISPER_LANG   язык: ru | en | auto (по умолчанию ru — для русской речи с англ. терминами)
#   NOTES_CMD      чем писать заметки (по умолчанию "claude -p"); транскрипт идёт в stdin
#   KEEP_AUDIO=1   не удалять промежуточные 16 kHz wav
set -euo pipefail

DIR="${1:?usage: process.sh <meeting-dir>}"
DIR="$(cd "$DIR" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="${WHISPER_MODEL:-$ROOT/models/ggml-large-v3-turbo.bin}"
LANG_CODE="${WHISPER_LANG:-ru}"
NOTES_CMD="${NOTES_CMD:-claude -p}"

command -v whisper-cli >/dev/null || { echo "❌ whisper-cli не найден. Запусти ./scripts/setup.sh"; exit 1; }
[[ -f "$MODEL" ]] || { echo "❌ Нет модели $MODEL. Запусти ./scripts/setup.sh"; exit 1; }

for track in mic system; do
  src="$DIR/$track.caf"
  [[ -f "$src" ]] || { echo "❌ Нет $src"; exit 1; }
  echo "→ $track: конвертирую в 16 kHz mono"
  afconvert -f WAVE -d LEI16@16000 -c 1 --mix "$src" "$DIR/$track.16k.wav"
  echo "→ $track: транскрибирую (whisper, lang=$LANG_CODE)"
  start=$(date +%s)
  whisper-cli -m "$MODEL" -f "$DIR/$track.16k.wav" -l "$LANG_CODE" -oj -of "$DIR/$track" -np
  echo "  готово за $(( $(date +%s) - start )) с"
done

echo "→ склеиваю дорожки"
python3 "$ROOT/scripts/merge.py" "$DIR/mic.json" "$DIR/system.json" > "$DIR/transcript.md"

[[ "${KEEP_AUDIO:-0}" == "1" ]] || rm -f "$DIR"/*.16k.wav

echo "→ пишу заметки: $NOTES_CMD"
read -ra notes_cmd <<< "$NOTES_CMD"
"${notes_cmd[@]}" "$(cat "$ROOT/prompts/notes.md")" < "$DIR/transcript.md" > "$DIR/notes.md"

echo "✅ $DIR/transcript.md"
echo "✅ $DIR/notes.md"
