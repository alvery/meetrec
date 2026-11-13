#!/usr/bin/env bash
# Обработка записанной встречи:
#   mic + system (caf или m4a) → транскрипция (whisper.cpp + VAD) → transcript.md →
#   действия (~/.config/meetrec/actions.json: заметки, action items, outline…) → свои .md (claude -p)
#   Сегменты дорожек (track.caf, track.1.caf…) склеиваются по манифесту, паузы — тишиной.
#   В конце исходные .caf (~2 ГБ/час) сжимаются в .m4a (десятки МБ/час).
#   Технический лог пишется в process.log; если задан MEETREC_REPORT_HOST — отчёт уходит на сервер.
#   Переменные из ~/.config/meetrec/env не перекрывают заданные в командной строке.
#
# Использование: ./scripts/process.sh [--actions-only] ~/Meetings/2026-11-11-153000
#   --actions-only  транскрипт уже есть — только действия (повтор после ошибки шлюза, правка промптов)
#
# Переменные окружения (можно задать в ~/.config/meetrec/env):
#   WHISPER_MODEL        путь к ggml-модели (по умолчанию models/ggml-large-v3-turbo.bin)
#   VAD_MODEL            путь к silero VAD (по умолчанию models/ggml-silero-v5.1.2.bin; нет файла — без VAD)
#   WHISPER_LANG         язык: ru | en | auto (по умолчанию ru — для русской речи с англ. терминами)
#   MEETREC_ACTIONS      файл действий (по умолчанию ~/.config/meetrec/actions.json, нет — стандартные)
#   NOTES_CMD            shell-команда для действий (по умолчанию "claude -p");
#                        промпт передаётся последним аргументом, транскрипт — в stdin
#   KEEP_RAW=1           не сжимать исходные .caf
#   MEETREC_REPORT_HOST  user@server — автоматически отправлять технический отчёт (см. report.sh)
#   MEETREC_NOTES_HOST   user@server — писать заметки через claude -p на сервере (транскрипт уходит по SSH)
set -euo pipefail

# Флаг — через окружение: обёртка ниже перезапускает скрипт уже без него в аргументах.
if [[ "${1:-}" == "--actions-only" ]]; then export MEETREC_ACTIONS_ONLY=1; shift; fi
ACTIONS_ONLY="${MEETREC_ACTIONS_ONLY:-0}"
DIR="${1:?usage: process.sh [--actions-only] <meeting-dir>}"
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
# Заметки: на сервере (MEETREC_NOTES_HOST), если задан; иначе локальный claude -p.
if [[ -z "${NOTES_CMD:-}" && -n "${MEETREC_NOTES_HOST:-}" ]]; then
  NOTES_CMD="$ROOT/scripts/remote_notes.sh"
fi
NOTES_CMD="${NOTES_CMD:-claude -p}"

echo "=== process.sh $(date -u +%Y-%m-%dT%H:%M:%SZ), git $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
# Промежуточные wav (~115 МБ/час каждый) удаляем при любом исходе; код выхода — в лог.
# Замок: одна обработка на папку (повторный запуск из приложения/терминала испортил бы файлы).
# Остался после аварии (kill -9)? Удали каталог .processing в папке встречи.
LOCK="$DIR/.processing"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "❌ $DIR уже обрабатывается (есть $LOCK). Если это ошибка — удали $LOCK"
  exit 1
fi
trap 'status=$?; rm -f "$DIR"/*.16k.wav; rmdir "$LOCK" 2>/dev/null; echo "=== exit $status"' EXIT

# Сегменты дорожки по манифесту rec (<track>.segments: «файл<TAB>секунды от начала записи»).
# Печатает «offset<TAB>путь» по порядку; сегмент берётся как .caf или уже сжатый .m4a.
# Без манифеста — track.caf, track.1.caf… вплотную друг к другу (offset «-»).
segments() {
  local t="$1" manifest="$DIR/$1.segments" name off base ext
  if [[ -f "$manifest" ]]; then
    while IFS=$'\t' read -r name off || [[ -n "$name" ]]; do
      [[ -n "$name" ]] || continue
      base="$DIR/${name%.caf}"
      if   [[ -f "$base.caf" ]]; then printf '%s\t%s\n' "$off" "$base.caf"
      elif [[ -f "$base.m4a" ]]; then printf '%s\t%s\n' "$off" "$base.m4a"
      else echo "⚠️  сегмент $name из манифеста не найден" >&2
      fi
    done < "$manifest"
  else # без манифеста: track.caf, track.1.caf… вплотную друг к другу
    local i=0
    while :; do
      if [[ $i -eq 0 ]]; then name="$t"; else name="$t.$i"; fi
      if   [[ -f "$DIR/$name.caf" ]]; then printf -- '-\t%s\n' "$DIR/$name.caf"
      elif [[ -f "$DIR/$name.m4a" ]]; then printf -- '-\t%s\n' "$DIR/$name.m4a"
      else return 0
      fi
      i=$((i + 1))
    done
  fi
}

if [[ "$ACTIONS_ONLY" == 1 && -s "$DIR/transcript.md" ]]; then
  echo "→ транскрипт уже есть — только действия"
else
command -v whisper-cli >/dev/null || { echo "❌ whisper-cli не найден. Запусти ./scripts/setup.sh"; exit 1; }
[[ -f "$MODEL" ]] || { echo "❌ Нет модели $MODEL. Запусти ./scripts/setup.sh"; exit 1; }

# VAD вырезает тишину: дорожки по большей части молчат (пока говорят другие),
# а на тишине whisper галлюцинирует («Субтитры сделал…»).
whisper_opts=(-m "$MODEL" -l "$LANG_CODE" -oj -sns) # без -np: он глушит и ошибки
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
  echo "→ $track: конвертирую сегменты в 16 kHz mono"
  concat_args=()
  i=0
  while IFS=$'\t' read -r off seg; do
    part="$DIR/$track.part$i.16k.wav"
    i=$((i + 1))
    # Пустой или битый сегмент (например, оборванный при переключении устройства) пропускаем.
    if afconvert -f WAVE -d LEI16@16000 -c 1 --mix "$seg" "$part" < /dev/null; then
      concat_args+=("$off" "$part")
    else
      rm -f "$part"
      echo "⚠️  пропускаю сегмент $(basename "$seg"): не читается (пустой?)"
    fi
  done < <(segments "$track")
  if [[ ${#concat_args[@]} -eq 0 ]]; then echo "❌ Нет пригодных сегментов дорожки $track в $DIR"; exit 1; fi
  echo "  сегментов: $(( ${#concat_args[@]} / 2 ))"
  # Один сегмент без смещения — склеивать нечего. Со смещением (system обычно стартует
  # на доли секунды позже mic) — через concat_wav, чтобы добавить тишину в начало.
  if [[ ${#concat_args[@]} -eq 2 && ( "${concat_args[0]}" == "-" || "${concat_args[0]}" == "0.000" ) ]]; then
    mv "${concat_args[1]}" "$DIR/$track.16k.wav"
  else
    python3 "$ROOT/scripts/concat_wav.py" "$DIR/$track.16k.wav" "${concat_args[@]}"
  fi
  rm -f "$DIR/$track".part*.16k.wav
  echo "→ $track: транскрибирую (whisper, lang=$LANG_CODE)"
  start=$(date +%s)
  # stdout whisper = текст транскрипта → не в лог; stderr (загрузка, ошибки, тайминги) — в лог.
  whisper-cli "${whisper_opts[@]}" -f "$DIR/$track.16k.wav" -of "$DIR/$track" > /dev/null
  echo "  готово за $(( $(date +%s) - start )) с"
  rm -f "$DIR/$track.16k.wav"
done

echo "→ склеиваю дорожки"
marks=(); [[ -f "$DIR/marks.txt" ]] && marks=("$DIR/marks.txt") # ★ — важные моменты, отмеченные во время записи
python3 "$ROOT/scripts/merge.py" "$DIR/mic.json" "$DIR/system.json" ${marks[@]+"${marks[@]}"} > "$DIR/transcript.md"
fi # ACTIONS_ONLY

# Действия (заметки, action items, outline… — настраиваются в приложении): параллельно,
# каждое — свой .md в папке встречи. Упавшее действие не мешает сжатию; код выхода — в конце.
echo "→ действия над транскриптом"
start=$(date +%s)
actions_status=0
python3 "$ROOT/scripts/run_actions.py" "$DIR" "${MEETREC_ACTIONS:-$HOME/.config/meetrec/actions.json}" "$NOTES_CMD" \
  || actions_status=$?
echo "  готово за $(( $(date +%s) - start )) с"

# Сжатие исходников — в самом конце и не фатально: заметки важнее.
# Битрейт выбирает afconvert под частоту/каналы дорожки.
if [[ "${KEEP_RAW:-0}" != "1" ]]; then
  for track in mic system; do
    while IFS=$'\t' read -r _ seg; do
      [[ "$seg" == *.caf ]] || continue
      out="${seg%.caf}.m4a"
      echo "→ $(basename "$seg"): сжимаю в m4a"
      if afconvert -f m4af -d aac "$seg" "$out.part"; then
        mv "$out.part" "$out" && rm "$seg"
      else
        rm -f "$out.part"
        echo "⚠️  не удалось сжать $(basename "$seg") — оставляю как есть"
      fi
    done < <(segments "$track")
  done
fi

echo "✅ $DIR/transcript.md"
exit "$actions_status"
