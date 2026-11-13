#!/usr/bin/env bash
# Ставит whisper.cpp и скачивает модели: large-v3-turbo (~1.6 ГБ) и silero VAD (~1 МБ).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_NAME="${MODEL_NAME:-ggml-large-v3-turbo.bin}"

command -v brew >/dev/null || { echo "❌ Нужен Homebrew: https://brew.sh"; exit 1; }
if brew list --versions whisper-cpp >/dev/null 2>&1; then
  # нужна свежая версия с поддержкой --vad
  brew upgrade whisper-cpp || echo "⚠️  brew upgrade whisper-cpp не удался — VAD может быть недоступен"
elif command -v whisper-cli >/dev/null; then
  echo "⚠️  whisper-cli установлен не через brew ($(command -v whisper-cli)) — обнови его сам, нужна поддержка --vad"
else
  brew install whisper-cpp
fi

VAD_NAME="ggml-silero-v5.1.2.bin"

download() { # $1 = имя файла, $2 = URL
  [[ -f "$ROOT/models/$1" ]] && return
  echo "→ качаю $1"
  curl -L --fail -o "$ROOT/models/$1.part" "$2"
  mv "$ROOT/models/$1.part" "$ROOT/models/$1"
}

mkdir -p "$ROOT/models"
download "$MODEL_NAME" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME"
download "$VAD_NAME"   "https://huggingface.co/ggml-org/whisper-vad/resolve/main/$VAD_NAME"

command -v claude >/dev/null || echo "ℹ️  Для заметок подключи агента: meetrec → Настройки (⌘,) → «Агент» (см. README)."
echo "✅ Готово"
