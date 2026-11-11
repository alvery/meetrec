#!/usr/bin/env python3
"""Склеивает wav-файлы одного формата (16 kHz mono 16-bit после afconvert) в один.

Использование: concat_wav.py out.wav in1.wav [in2.wav ...]
"""
import sys
import wave


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: concat_wav.py out.wav in1.wav [in2.wav ...]")
    out_path, inputs = sys.argv[1], sys.argv[2:]
    with wave.open(out_path, "wb") as out:
        params = None
        for path in inputs:
            with wave.open(path, "rb") as w:
                p = (w.getnchannels(), w.getsampwidth(), w.getframerate())
                if params is None:
                    params = p
                    out.setnchannels(p[0])
                    out.setsampwidth(p[1])
                    out.setframerate(p[2])
                elif p != params:
                    sys.exit(f"{path}: формат {p} не совпадает с {params}")
                out.writeframes(w.readframes(w.getnframes()))


if __name__ == "__main__":
    main()
