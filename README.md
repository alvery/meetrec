<p align="center"><img src="docs/cover.svg" alt="meetrec — records your Zoom and Meet calls, transcribes on your Mac and writes the notes" width="100%"></p>

<p align="center"><b>English</b> · <a href="README.ru.md">Русский</a></p>

# meetrec

A lightweight meeting recorder for macOS. It lives in the menu bar, knows your calendar, records Zoom and
Google Meet without a bot joining the call, transcribes **on-device** (whisper.cpp on Apple Silicon) and writes
notes through **your own** AI agent. No subscription and no third-party cloud in the middle.

> The app UI is in Russian for now. Transcription defaults to Russian; set `WHISPER_LANG=en` or `auto`
> (see [Development](#development)) for other languages.

- **Calendar.** The menu bar ring counts down to your next meeting. A minute before it starts, a «Подключиться»
  (Join) panel appears with a mic and headphones check and the open tasks from the previous meeting in the same series.
- **Two-track recording.** «Я» (me) is your microphone, «Они» (them) is system audio, so speakers are
  separated exactly, with no ML diarization. When a meeting is on and Zoom takes the mic, meetrec offers to record.
  When the call ends, it offers to stop.
- **★ Marks.** Press ⌃⌥M during a recording to flag an important moment. The notes pay special attention to it.
- **Actions after recording.** Notes, action items, an outline or your own prompts, each written to its own
  `.md` in the meeting folder.
- **Plain files:** `~/Meetings/<date>-<meeting>/` holds the transcript, the notes and compressed audio.

## How it works

```
recording ──► mic.caf («Я», me)  +  system.caf («Они», them — Core Audio process tap)
                      │
                      ▼
       whisper.cpp + VAD on your Mac ──► transcript.md
                      │
                      ▼  transcript text only
       your agent (OpenAI-compatible API) ──► notes.md · action-items.md · outline.md …
```

**Audio never leaves your Mac.** The agent receives only the transcript text plus the meeting title and
attendees. Which agent that is is up to you (see [Notes agent](#notes-agent)).

## Install

You need **Apple Silicon**, **macOS 14.2+**, Xcode Command Line Tools (`xcode-select --install`) and
[Homebrew](https://brew.sh).

```bash
git clone https://github.com/alvery/meetrec.git && cd meetrec
./scripts/setup.sh        # whisper.cpp + large-v3-turbo and silero VAD models (~1.6 GB, once)
./scripts/build-app.sh    # builds meetrec.app, installs it to ~/Applications and launches it
```

On first launch meetrec asks for access to your **calendar**, **microphone** and **system audio recording**.
Allow all three. Google calendars are added in System Settings → Internet Accounts.

To update: `./scripts/dev.sh app` (git pull + build + relaunch).

### Stable code signature (recommended)

Without it macOS may ask for permissions again after every rebuild. Create a certificate once:

1. Keychain Access → Keychain Access menu → Certificate Assistant → Create a Certificate…
2. Name `meetrec-dev`, identity type «Self Signed Root», certificate type «Code Signing» → Create.
3. `mkdir -p ~/.config/meetrec && echo 'MEETREC_SIGN_ID=meetrec-dev' >> ~/.config/meetrec/env`, then `./scripts/build-app.sh`.

### Notes agent

Without an agent you only get the transcript; meetrec reminds you with a line in its window.
Set it up in ⚙ (⌘,) → **«Агент»** (Agent); the **«Проверить»** (Check) button tells you whether everything works. Options:

| Option | What to enter | Where the transcript is processed |
|---|---|---|
| **Your own server with Claude** (the author's setup) | «SSH-туннель к» (SSH tunnel to): `user@server`; token via «С сервера» (From server) | on your server, with your Claude subscription |
| **Any OpenAI-compatible API** | «Свой адрес API» (custom API URL), token, model | at the API provider |
| **Local model** (Ollama, LM Studio) | a URL like `http://127.0.0.1:11434/v1` | on your Mac |
| **Claude Code on this Mac** | explicitly, in `~/.config/meetrec/env`: `NOTES_CMD="/full/path/to/claude -p"` (`which claude`) | at Anthropic, with your subscription |

Your own server: on a server with [Claude Code](https://claude.com/claude-code) installed and logged in, run
`./gateway/install.sh` from this repository. It installs `meetrec-gateway` as a systemd service (listening only on
`127.0.0.1:8787`, nothing exposed to the internet) and creates a token. The Mac reaches it through an SSH tunnel
that meetrec opens by itself; key-based login is required (`ssh user@server true` without a password).

## Usage

The menu bar ring shows the state:

| Icon | Meaning |
|---|---|
| dimmed ring with «Я / Они» bars | no meetings in the next hour |
| arc fills clockwise | meeting in ≤ 60 min |
| shrinking pie | meeting in progress, pie is the time left |
| blinking dot | meeting in progress and the mic is busy: record? |
| **red** dot, ring is the time left | recording; the ring turns **yellow** 5 minutes before the end |
| ★ for a second | mark added |
| ⋯ / ✓ / ! | writing notes / done / failed |

Click the icon to open the window. It shows the next meeting and one main button for the current phase:
«Подключиться» (Join, ⌘J) or «Записать» (Record, ⌘R). While recording it shows track levels, «Метка» (Mark)
and «Остановить» (Stop, ⌘.). Below are the five most recent meetings. Click a meeting to open its notes;
if processing failed you see the reason and a ↻ retry button. Right-click for the transcript, folder, log,
re-running the actions or a full reprocess.

**Global hotkeys:** start / stop recording is set in ⚙ → «Горячая клавиша» (Hotkey): a double tap of
⌘ / ⌥ / ⌃ / ⇧ or your own shortcut. ★ mark is ⌃⌥M, active only while recording.

**Actions** are in ⚙ → «Действия» (Actions). The defaults are notes, action items and an outline
([`prompts/actions.default.json`](prompts/actions.default.json)). You can add your own, pick a model for each and
reorder them. They are stored in `~/.config/meetrec/actions.json`.

**Icon missing?** On MacBooks with a notch, macOS hides menu bar icons that don't fit to the left of it.
Move meetrec closer to the clock: hold ⌘ and drag the icon.

**Tips:** use headphones, otherwise the other side's voices also end up in your «Я» track. Notification sounds
and music during a call are recorded too.

## Development

```bash
swift build -c release                     # CLI: .build/release/rec
.build/release/rec ~/Meetings/test         # record from the terminal (Ctrl+C to stop)
./scripts/process.sh ~/Meetings/test       # process: whisper → transcript.md → actions
./scripts/process.sh --actions-only DIR    # actions only (the transcript already exists)
./scripts/mock-meeting.sh --day            # test meetings in a separate «meetrec-test» calendar
./scripts/mock-meeting.sh --clean          # remove them
```

When run from a terminal, permissions are granted to **the terminal app**. System audio has to be granted to
the terminal manually: Privacy & Security → Screen & System Audio Recording → the lower «System Audio Recording
Only» list → + → your terminal.

Processing settings live in `~/.config/meetrec/env` (`KEY=value`; command-line variables take precedence):

| Variable | Default | |
|---|---|---|
| `WHISPER_LANG` | `ru` | `ru`, `en` or `auto` |
| `WHISPER_MODEL` | `models/ggml-large-v3-turbo.bin` | any whisper.cpp ggml model |
| `NOTES_CMD` | `claude -p` | command for actions without a gateway (prefer a full path): prompt as the last argument, transcript on stdin |
| `KEEP_RAW` | `0` | `1` keeps the raw .caf files instead of compressing them to .m4a |
| `MEETREC_REPORT_HOST` | — | `user@server`: send a technical report over SSH after processing (no audio, no text) |

Debug reports (`scripts/report.sh`) are off unless `MEETREC_REPORT_HOST` is set. They contain only technical
data: versions, devices, file parameters and the `rec.log` / `process.log` logs. Audio, transcripts and notes are
never sent.

Changes are in [CHANGELOG.md](CHANGELOG.md), requirements and plans in [SPEC.md](SPEC.md) (both in Russian).
The app icon is drawn by `scripts/make-icon.swift`, the cover by `docs/make-cover.py`.

## License

[MIT](LICENSE)
