#!/usr/bin/env python3
"""Склеивает сегменты дорожки (wav 16 kHz mono 16-bit после afconvert) в один файл,
ставя каждый сегмент на его момент начала: паузы между сегментами (перезапуск записи
при смене устройства) заполняются тишиной, чтобы дорожки «Я» и «Они» оставались синхронными.

Использование: concat_wav.py out.wav OFFSET1 in1.wav [OFFSET2 in2.wav ...]
OFFSET — секунды от начала записи (из манифеста rec) или «-» (вплотную к предыдущему).
"""
import sys
import wave

CHUNK = 1 << 16  # кадров за раз — потоковое чтение, константная память


def main():
    args = sys.argv[1:]
    if len(args) < 3 or len(args) % 2 != 1:
        sys.exit("usage: concat_wav.py out.wav OFFSET1 in1.wav [OFFSET2 in2.wav ...]")
    out_path, pairs = args[0], list(zip(args[1::2], args[2::2]))
    written = 0  # кадров записано в out
    with wave.open(out_path, "wb") as out:
        params = None
        for offset, path in pairs:
            with wave.open(path, "rb") as w:
                p = (w.getnchannels(), w.getsampwidth(), w.getframerate())
                if params is None:
                    params = p
                    out.setnchannels(p[0])
                    out.setsampwidth(p[1])
                    out.setframerate(p[2])
                elif p != params:
                    sys.exit(f"{path}: формат {p} не совпадает с {params}")
                frame_bytes = p[0] * p[1]
                if offset != "-":
                    gap = round(float(offset) * p[2]) - written
                    if gap < -p[2] // 2:  # сегмент начинается раньше, чем кончился предыдущий
                        print(f"  ⚠️  {path.rsplit('/', 1)[-1]}: перекрытие {-gap / p[2]:.2f} с с предыдущим "
                              f"сегментом — дальше дорожка может отставать на это время", file=sys.stderr)
                    if gap > 0:  # пауза перед сегментом → тишина
                        print(f"  {path.rsplit('/', 1)[-1]}: пауза {gap / p[2]:.2f} с заполнена тишиной",
                              file=sys.stderr)
                        while gap > 0:
                            n = min(gap, CHUNK)
                            out.writeframes(b"\0" * (n * frame_bytes))
                            written += n
                            gap -= n
                while True:
                    chunk = w.readframes(CHUNK)
                    if not chunk:
                        break
                    out.writeframes(chunk)
                    written += len(chunk) // frame_bytes


if __name__ == "__main__":
    main()
