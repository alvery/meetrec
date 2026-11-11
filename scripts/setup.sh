#!/usr/bin/env bash
# Ставит whisper.cpp и скачивает модель large-v3-turbo (~1.6 ГБ).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_NAME="${MODEL_NAME:-ggml-large-v3-turbo.bin}"

command -v brew >/dev/null || { echo "❌ Нужен Homebrew: https://brew.sh"; exit 1; }
command -v whisper-cli >/dev/null || brew install whisper-cpp

mkdir -p "$ROOT/models"
if [[ ! -f "$ROOT/models/$MODEL_NAME" ]]; then
  echo "→ качаю $MODEL_NAME"
  curl -L --fail -o "$ROOT/models/$MODEL_NAME.part" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME"
  mv "$ROOT/models/$MODEL_NAME.part" "$ROOT/models/$MODEL_NAME"
fi

command -v claude >/dev/null || echo "⚠️  claude CLI не найден — заметки не сгенерируются (или задай NOTES_CMD)."
echo "✅ Готово"
