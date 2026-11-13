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
import urllib.error
import urllib.request

# Шлюз агента (OpenAI-совместимый: meetrec-gateway через SSH-туннель, Ollama, LiteLLM, OpenRouter…).
# Задан — действия идут через него; иначе — через notes-cmd (claude -p / remote_notes.sh).
GATEWAY_URL = os.environ.get("MEETREC_GATEWAY_URL", "").strip().rstrip("/")
GATEWAY_SSH = os.environ.get("MEETREC_GATEWAY_SSH", "").strip()
GATEWAY_PORT = os.environ.get("MEETREC_GATEWAY_PORT", "").strip() or "8787"
GATEWAY_TOKEN = os.environ.get("MEETREC_GATEWAY_TOKEN", "").strip()
GATEWAY_MODEL = os.environ.get("MEETREC_GATEWAY_MODEL", "").strip()
# Туннель — только когда свой адрес не задан (тогда адрес — локальный конец туннеля).
USE_TUNNEL = bool(GATEWAY_SSH) and not GATEWAY_URL
if USE_TUNNEL:
    GATEWAY_URL = f"http://127.0.0.1:{GATEWAY_PORT}/v1"


def first_model():
    """Модель по умолчанию не выбрана: берём первую из /models (другие шлюзы не знают «default»)."""
    req = urllib.request.Request(GATEWAY_URL + "/models", headers={"Authorization": f"Bearer {GATEWAY_TOKEN}"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.load(resp).get("data", [])
        return data[0]["id"] if data else ""
    except Exception:
        return ""

RESERVED = {"transcript.md", "meta.md", "mic.json", "system.json", "process.log", "rec.log", "results.json"}
MANIFEST = "results.json"  # что получилось в этом прогоне — его читает приложение

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
    try:
        return _run(action, out, cmd, stdin, meeting_dir)
    except Exception as e:  # одно сломанное действие не должно терять отчёт об остальных
        return action.get("name", "?"), out, False, f"{type(e).__name__}: {e}", 0.0


def ask_gateway(prompt, text, model):
    """POST /chat/completions → (ok, текст ответа или сообщение об ошибке)."""
    body = json.dumps({"model": model, "messages": [
        {"role": "system", "content": prompt}, {"role": "user", "content": text}]}).encode("utf-8")
    req = urllib.request.Request(GATEWAY_URL + "/chat/completions", data=body, method="POST",
                                 headers={"Content-Type": "application/json",
                                          "Authorization": f"Bearer {GATEWAY_TOKEN}"})
    try:
        with urllib.request.urlopen(req, timeout=900) as resp:
            data = json.load(resp)
        return True, data["choices"][0]["message"]["content"]
    except urllib.error.HTTPError as e:
        try:
            msg = json.load(e).get("error", {}).get("message", "")
        except Exception:
            msg = ""
        return False, f"шлюз HTTP {e.code}: {msg}"[:400]
    except Exception as e:
        return False, f"шлюз: {type(e).__name__}: {e}"[:400]


def _run(action, out, cmd, stdin, meeting_dir):
    started = time.time()
    if GATEWAY_URL:
        ok, result = ask_gateway(action.get("prompt", ""), stdin, action.get("model") or GATEWAY_MODEL)
        took = time.time() - started
        if not ok:
            return action.get("name", "?"), out, False, result, took
        tmp = os.path.join(meeting_dir, out + ".part")
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(result)
        os.replace(tmp, os.path.join(meeting_dir, out))
        return action.get("name", "?"), out, True, "", took
    proc = subprocess.run(["bash", "-c", cmd + ' "$1"', "action", action.get("prompt", "")],
                          input=stdin.encode("utf-8"), capture_output=True)
    took = time.time() - started
    if proc.returncode != 0:
        # claude -p пишет ошибки в stdout — показываем начало (это текст ошибки, не заметок).
        msg = (proc.stdout.decode("utf-8", "replace")[:300] + " " +
               proc.stderr.decode("utf-8", "replace")[-300:]).strip()
        return action.get("name", "?"), out, False, f"код {proc.returncode}: {msg}", took
    tmp = os.path.join(meeting_dir, out + ".part")
    with open(tmp, "wb") as f:
        f.write(proc.stdout)
    os.replace(tmp, os.path.join(meeting_dir, out))
    return action.get("name", "?"), out, True, "", took


def main():  # noqa: C901
    if len(sys.argv) != 4:
        sys.exit("usage: run_actions.py <meeting-dir> <actions.json> <notes-cmd>")
    meeting_dir, actions_path, cmd = sys.argv[1:]
    actions, source = load_actions(actions_path)
    enabled = [a for a in actions if a.get("enabled", True) and (a.get("prompt") or "").strip()]
    print(f"  действий: {len(enabled)} (из {os.path.basename(source)}); "
          + (f"через шлюз {GATEWAY_URL}" if GATEWAY_URL else f"через {cmd}"))
    if not enabled:
        write_manifest(meeting_dir, [])
        return 0
    global GATEWAY_MODEL
    if GATEWAY_URL:
        if USE_TUNNEL:
            tunnel = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tunnel.sh")
            t = subprocess.run(["bash", tunnel], capture_output=True, text=True)
            if t.returncode != 0:  # прежний results.json не трогаем — заметки прошлого прогона остаются видны
                print(f"  ❌ SSH-туннель к шлюзу не поднялся: {(t.stderr or t.stdout).strip()[:300]}")
                return 1
        if not GATEWAY_MODEL and any(not a.get("model") for a in enabled):
            GATEWAY_MODEL = first_model()
            if not GATEWAY_MODEL:
                print("  ❌ шлюз не отдал список моделей — выбери модель по умолчанию в настройках")
                return 1
        print(f"  модель по умолчанию: {GATEWAY_MODEL or '—'}")

    def read(name):
        p = os.path.join(meeting_dir, name)
        return open(p, encoding="utf-8", errors="replace").read() if os.path.isfile(p) else ""

    stdin = PREAMBLE + "\n# Meeting metadata\n\n" + (read("meta.md") or "—") + "\n\n# Transcript\n\n" + read("transcript.md")
    taken = set()
    jobs = [(a, output_name(a, taken)) for a in enabled]
    failed = 0
    results = []
    with cf.ThreadPoolExecutor(max_workers=min(4, len(jobs))) as pool:
        futures = [pool.submit(run, a, out, cmd, stdin, meeting_dir) for a, out in jobs]
        for fut in futures:
            name, out, ok, msg, took = fut.result()
            results.append({"name": name, "file": out, "ok": ok})
            if ok:
                print(f"  ✅ «{name}» → {out} ({took:.0f} с)")
            else:
                failed += 1
                print(f"  ❌ «{name}» ({took:.0f} с): {msg}")
    write_manifest(meeting_dir, results)
    return 1 if failed else 0


def write_manifest(meeting_dir, results):
    path = os.path.join(meeting_dir, MANIFEST)
    with open(path + ".part", "w", encoding="utf-8") as f:
        json.dump({"finished": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "results": results}, f, ensure_ascii=False, indent=2)
    os.replace(path + ".part", path)


if __name__ == "__main__":
    sys.exit(main())
