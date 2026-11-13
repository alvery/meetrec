#!/usr/bin/env python3
"""Склеивает две дорожки whisper.cpp (-oj) в один транскрипт с метками «Я» / «Они».

Использование: merge.py mic.json system.json [marks.txt] > transcript.md
  marks.txt — метки важных моментов (секунды от начала записи, по одной на строку), ставятся горячей клавишей.
"""
import json
import re
import sys

# Сегменты целиком из служебных меток: [BLANK_AUDIO], [музыка], (смех), *шум* ...
NON_SPEECH = re.compile(r"^\s*(?:(?:\[[^\]]*\]|\([^)]*\)|\*[^*]*\*|♪+)\s*)+$")

# Типичные галлюцинации whisper на тишине (артефакты обучения на субтитрах).
# Сегмент выкидывается, только если он *целиком* состоит из такой фразы —
# реальная речь вроде «Продолжение следует в четверг, тогда решим» остаётся.
HALLUCINATIONS = re.compile(
    r"(субтитры (сделал|создавал|подогнал)( \S+){1,2}"
    r"|редактор субтитров( \S+){1,2}( корректор( \S+){1,2})?"
    r"|продолжение следует|спасибо за просмотр|подписывайтесь на канал"
    r"|thanks for watching|subtitles by( \S+){1,3}|\S*amara\.org\S*)",
    re.IGNORECASE,
)
STRIP = " .,!?…-–—\"'«»"


def is_hallucination(text):
    return HALLUCINATIONS.fullmatch(text.strip(STRIP)) is not None


FILTERED = {"non_speech": 0, "hallucination": 0}


def load(path, speaker):
    # whisper.cpp может разрезать многобайтовый символ кириллицы между токенами
    with open(path, "rb") as f:
        data = json.loads(f.read().decode("utf-8", errors="replace"))
    segments = []
    for seg in data.get("transcription", []):
        text = seg.get("text", "").strip()
        if not text:
            continue
        if NON_SPEECH.match(text):
            FILTERED["non_speech"] += 1
            continue
        if is_hallucination(text):
            FILTERED["hallucination"] += 1
            continue
        segments.append((seg["offsets"]["from"], speaker, text))
    return segments


def load_marks(path):
    marks = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    marks.append((int(float(line.strip()) * 1000), "★", ""))
                except ValueError:
                    continue
    except FileNotFoundError:
        pass
    return marks


def ts(ms):
    s = ms // 1000
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit("usage: merge.py mic.json system.json [marks.txt]")
    me, them = load(sys.argv[1], "Я"), load(sys.argv[2], "Они")
    marks = load_marks(sys.argv[3]) if len(sys.argv) == 4 else []
    segments = sorted(me + them + marks, key=lambda s: s[0])
    # Статистика — в stderr (попадает в process.log), сам текст — только в stdout/файл.
    print(f"  сегментов: Я {len(me)}, Они {len(them)}; отфильтровано: служебных меток "
          f"{FILTERED['non_speech']}, галлюцинаций {FILTERED['hallucination']}", file=sys.stderr)

    print("# Транскрипт\n")
    print("_«Я» — мой микрофон, «Они» — собеседники (системный звук)._\n")
    last_speaker = None
    for start, speaker, text in segments:
        if speaker == "★":
            print(f"\n**[{ts(start)}] ★ Отметка: важный момент**")
            last_speaker = None  # следующая реплика — с новой строки и меткой времени
        elif speaker == last_speaker:
            print(text)  # продолжение реплики того же спикера
        else:
            print(f"\n**[{ts(start)}] {speaker}:** {text}")
            last_speaker = speaker


if __name__ == "__main__":
    main()
