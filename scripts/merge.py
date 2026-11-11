#!/usr/bin/env python3
"""Склеивает две дорожки whisper.cpp (-oj) в один транскрипт с метками «Я» / «Они».

Использование: merge.py mic.json system.json > transcript.md
"""
import json
import sys


def load(path, speaker):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    segments = []
    for seg in data.get("transcription", []):
        text = seg.get("text", "").strip()
        if not text:
            continue
        segments.append((seg["offsets"]["from"], speaker, text))
    return segments


def ts(ms):
    s = ms // 1000
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: merge.py mic.json system.json")
    segments = load(sys.argv[1], "Я") + load(sys.argv[2], "Они")
    segments.sort(key=lambda s: s[0])

    print("# Транскрипт\n")
    print("_«Я» — мой микрофон, «Они» — собеседники (системный звук)._\n")
    last_speaker = None
    for start, speaker, text in segments:
        if speaker == last_speaker:
            print(text)  # продолжение реплики того же спикера
        else:
            print(f"\n**[{ts(start)}] {speaker}:** {text}")
            last_speaker = speaker


if __name__ == "__main__":
    main()
