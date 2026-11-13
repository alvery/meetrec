#!/usr/bin/env python3
"""Действия над транскриптом встречи (как actions в Shadow): каждое — промпт → Markdown-файл в папке встречи.

Использование: run_actions.py <папка-встречи> <actions.json> <notes-cmd>
  actions.json  — {"actions": [{"name", "enabled", "output", "prompt"}, ...]};
                  нет файла — берутся prompts/actions.default.json из репозитория
  notes-cmd     — shell-команда (claude -p / remote_notes.sh / …): промпт последним аргументом, вход в stdin

Действия идут параллельно. Каждое получает: пояснение + meta.md (название, время, участники) + транскрипт.
В лог печатаются только имена действий, тайминги и ошибки — не текст встречи.
"""
import concurrent.futures as cf
import json
import os
import subprocess
import sys
import time

RESERVED = {"transcript.md", "meta.md", "mic.json", "system.json", "process.log", "rec.log"}

PREAMBLE = """Below are the meeting metadata (if any) and an automatic transcript of the meeting.
«Я» is me (my microphone). «Они» are the other participants (system audio; individual speakers are not \
separated — infer who is speaking from context and the participant list). The transcript is machine-generated \
and may contain recognition errors, especially in names and technical terms — infer by meaning.
Write the result in the language the meeting was held in. Output only Markdown, without any preamble.
"""


def load_actions(path):
    default = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "prompts", "actions.default.json")
    for p in (path, default):
        if p and os.path.isfile(p):
            with open(p, encoding="utf-8") as f:
                return json.load(f).get("actions", []), p
    sys.exit("❌ нет файла действий (ни настроенного, ни стандартного)")


def output_name(action, taken):
    name = os.path.basename((action.get("output") or action.get("name") or "result").strip()) or "result"
    if not name.endswith(".md"):
        name += ".md"
    base, n = name[:-3], 2
    while name in taken or name in RESERVED:
        name, n = f"{base}-{n}.md", n + 1
    taken.add(name)
    return name


def run(action, out, cmd, stdin, meeting_dir):
    started = time.time()
    proc = subprocess.run(["bash", "-c", cmd + ' "$1"', "action", action["prompt"]],
                          input=stdin.encode("utf-8"), capture_output=True)
    took = time.time() - started
    if proc.returncode != 0:
        # claude -p пишет ошибки в stdout — показываем начало (это текст ошибки, не заметок).
        msg = (proc.stdout.decode("utf-8", "replace")[:300] + " " +
               proc.stderr.decode("utf-8", "replace")[-300:]).strip()
        return action["name"], out, False, f"код {proc.returncode}: {msg}", took
    tmp = os.path.join(meeting_dir, out + ".part")
    with open(tmp, "wb") as f:
        f.write(proc.stdout)
    os.replace(tmp, os.path.join(meeting_dir, out))
    return action["name"], out, True, "", took


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: run_actions.py <meeting-dir> <actions.json> <notes-cmd>")
    meeting_dir, actions_path, cmd = sys.argv[1:]
    actions, source = load_actions(actions_path)
    enabled = [a for a in actions if a.get("enabled", True) and (a.get("prompt") or "").strip()]
    print(f"  действий: {len(enabled)} (из {os.path.basename(source)})")
    if not enabled:
        return 0

    def read(name):
        p = os.path.join(meeting_dir, name)
        return open(p, encoding="utf-8", errors="replace").read() if os.path.isfile(p) else ""

    stdin = PREAMBLE + "\n# Meeting metadata\n\n" + (read("meta.md") or "—") + "\n\n# Transcript\n\n" + read("transcript.md")
    taken = set()
    jobs = [(a, output_name(a, taken)) for a in enabled]
    failed = 0
    with cf.ThreadPoolExecutor(max_workers=min(4, len(jobs))) as pool:
        futures = [pool.submit(run, a, out, cmd, stdin, meeting_dir) for a, out in jobs]
        for fut in futures:
            name, out, ok, msg, took = fut.result()
            if ok:
                print(f"  ✅ «{name}» → {out} ({took:.0f} с)")
            else:
                failed += 1
                print(f"  ❌ «{name}» ({took:.0f} с): {msg}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
