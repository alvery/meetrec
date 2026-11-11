#!/usr/bin/env bash
# Обработка записанной встречи:
#   mic + system (caf или m4a) → транскрипция (whisper.cpp + VAD) → transcript.md → notes.md (claude -p)
#   В конце исходные .caf (~2 ГБ/час) сжимаются в .m4a (десятки МБ/час).
#   Технический лог пишется в process.log; если задан MEETREC_REPORT_HOST — отчёт уходит на сервер.
#   Переменные из ~/.config/meetrec/env не перекрывают заданные в командной строке.
#
# Использование: ./scripts/process.sh ~/Meetings/2026-11-11-153000
#
# Переменные окружения (можно задать в ~/.config/meetrec/env):
#   WHISPER_MODEL        путь к ggml-модели (по умолчанию models/ggml-large-v3-turbo.bin)
#   VAD_MODEL            путь к silero VAD (по умолчанию models/ggml-silero-v5.1.2.bin; нет файла — без VAD)
#   WHISPER_LANG         язык: ru | en | auto (по умолчанию ru — для русской речи с англ. терминами)
#   NOTES_CMD            shell-команда для заметок (по умолчанию "claude -p");
#                        промпт передаётся последним аргументом, транскрипт — в stdin
#   KEEP_RAW=1           не сжимать исходные .caf
#   MEETREC_REPORT_HOST  user@server — автоматически отправлять технический отчёт (см. report.sh)
set -euo pipefail

DIR="${1:?usage: process.sh <meeting-dir>}"
DIR="$(cd "$DIR" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/config.sh"

# Обёртка: перезапускаем себя, дублируя весь вывод в process.log. Родитель дожидается
# окончания конвейера (лог дописан полностью) и только потом отправляет отчёт.
# tee игнорирует Ctrl+C, чтобы лог не обрывался; родитель ловит INT обработчиком
# (а не игнорирует — иначе дочерний процесс унаследовал бы игнорирование).
if [[ -z "${MEETREC_PROCESS_CHILD:-}" ]]; then
  trap ':' INT
  set +e
  MEETREC_PROCESS_CHILD=1 "$0" "$@" 2>&1 | (trap '' INT; exec tee -a "$DIR/process.log")
  status=${PIPESTATUS[0]}
  if [[ -n "${MEETREC_REPORT_HOST:-}" ]]; then
    "$ROOT/scripts/report.sh" "$DIR" "process.sh exit $status" || echo "⚠️  не удалось отправить отчёт"
  fi
  exit "$status"
fi

MODEL="${WHISPER_MODEL:-$ROOT/models/ggml-large-v3-turbo.bin}"
VAD_MODEL="${VAD_MODEL:-$ROOT/models/ggml-silero-v5.1.2.bin}"
LANG_CODE="${WHISPER_LANG:-ru}"
NOTES_CMD="${NOTES_CMD:-claude -p}"

echo "=== process.sh $(date -u +%Y-%m-%dT%H:%M:%SZ), git $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
# Промежуточные wav (~115 МБ/час каждый) удаляем при любом исходе; код выхода — в лог.
trap 'status=$?; rm -f "$DIR"/*.16k.wav; echo "=== exit $status"' EXIT

command -v whisper-cli >/dev/null || { echo "❌ whisper-cli не найден. Запусти ./scripts/setup.sh"; exit 1; }
[[ -f "$MODEL" ]] || { echo "❌ Нет модели $MODEL. Запусти ./scripts/setup.sh"; exit 1; }

# VAD вырезает тишину: дорожки по большей части молчат (пока говорят другие),
# а на тишине whisper галлюцинирует («Субтитры сделал…»).
whisper_opts=(-m "$MODEL" -l "$LANG_CODE" -oj -np -sns)
whisper_help="$(whisper-cli --help 2>&1 || true)" # без пайпа в grep -q: иначе SIGPIPE + pipefail
if [[ "$whisper_help" != *--vad* ]]; then
  echo "⚠️  whisper-cli без поддержки VAD — обнови: brew upgrade whisper-cpp"
elif [[ ! -f "$VAD_MODEL" ]]; then
  echo "⚠️  VAD-модель не найдена ($VAD_MODEL) — возможны галлюцинации на тишине"
else
  whisper_opts+=(--vad -vm "$VAD_MODEL")
fi
echo "whisper: ${whisper_opts[*]}"

for track in mic system; do
  if   [[ -f "$DIR/$track.caf" ]]; then src="$DIR/$track.caf"
  elif [[ -f "$DIR/$track.m4a" ]]; then src="$DIR/$track.m4a"
  else echo "❌ Нет $DIR/$track.caf / .m4a"; exit 1
  fi
  echo "→ $track: конвертирую в 16 kHz mono"
  afconvert -f WAVE -d LEI16@16000 -c 1 --mix "$src" "$DIR/$track.16k.wav"
  echo "→ $track: транскрибирую (whisper, lang=$LANG_CODE)"
  start=$(date +%s)
  # stdout whisper = текст транскрипта → не в лог; stderr (ошибки, тайминги) — в лог.
  whisper-cli "${whisper_opts[@]}" -f "$DIR/$track.16k.wav" -of "$DIR/$track" > /dev/null
  echo "  готово за $(( $(date +%s) - start )) с"
  rm -f "$DIR/$track.16k.wav"
done

echo "→ склеиваю дорожки"
python3 "$ROOT/scripts/merge.py" "$DIR/mic.json" "$DIR/system.json" > "$DIR/transcript.md"

echo "→ пишу заметки: $NOTES_CMD"
# bash -c — чтобы NOTES_CMD мог содержать кавычки и аргументы с пробелами.
# Пишем во временный файл: при ошибке не останется пустого notes.md.
start=$(date +%s)
bash -c "$NOTES_CMD \"\$1\"" notes "$(cat "$ROOT/prompts/notes.md")" \
  < "$DIR/transcript.md" > "$DIR/notes.md.part"
mv "$DIR/notes.md.part" "$DIR/notes.md"
echo "  готово за $(( $(date +%s) - start )) с"

# Сжатие исходников — в самом конце и не фатально: заметки важнее.
# Битрейт выбирает afconvert под частоту/каналы дорожки.
if [[ "${KEEP_RAW:-0}" != "1" ]]; then
  for track in mic system; do
    [[ -f "$DIR/$track.caf" ]] || continue
    echo "→ $track: сжимаю исходник в m4a"
    if afconvert -f m4af -d aac "$DIR/$track.caf" "$DIR/$track.m4a.part"; then
      mv "$DIR/$track.m4a.part" "$DIR/$track.m4a" && rm "$DIR/$track.caf"
    else
      rm -f "$DIR/$track.m4a.part"
      echo "⚠️  не удалось сжать $track.caf — оставляю как есть"
    fi
  done
fi

echo "✅ $DIR/transcript.md"
echo "✅ $DIR/notes.md"
