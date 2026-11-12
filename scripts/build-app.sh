#!/usr/bin/env bash
# Собирает meetrec.app (приложение в строке меню), подписывает и ставит в ~/Applications, затем запускает.
#
# Подпись: MEETREC_SIGN_ID в ~/.config/meetrec/env — имя сертификата для подписи кода
# (см. README: «Постоянная подпись»). Без него — ad-hoc: работает, но macOS может заново
# спрашивать разрешения (микрофон, звук, календарь) после каждой пересборки.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/config.sh"

swift build -c release --product MeetrecApp

APP="$ROOT/.build/meetrec.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/MeetrecApp" "$APP/Contents/MacOS/meetrec"
VERSION="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.meetrec.app</string>
  <key>CFBundleName</key><string>meetrec</string>
  <key>CFBundleDisplayName</key><string>meetrec</string>
  <key>CFBundleExecutable</key><string>meetrec</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>meetrec записывает твою речь на созвонах (дорожка «Я»).</string>
  <key>NSAudioCaptureUsageDescription</key><string>meetrec записывает звук собеседников на созвонах (дорожка «Они»).</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>meetrec показывает ближайшую встречу, ссылку на подключение и участников.</string>
  <key>MeetrecRepoRoot</key><string>${ROOT}</string>
</dict>
</plist>
PLIST

SIGN_ID="${MEETREC_SIGN_ID:--}"
if [[ "$SIGN_ID" == "-" ]]; then
  echo "⚠️  подпись ad-hoc (MEETREC_SIGN_ID не задан) — разрешения могут спрашиваться после каждой пересборки"
fi
codesign --force --sign "$SIGN_ID" "$APP"

DEST="$HOME/Applications/meetrec.app"
mkdir -p "$HOME/Applications"
# Закрываем штатно (applicationShouldTerminate остановит идущую запись и закроет файлы);
# pkill — только если приложение не закрылось за 10 с.
if pgrep -x meetrec >/dev/null; then
  osascript -e 'tell application id "dev.meetrec.app" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -x meetrec >/dev/null || break; sleep 0.5; done
  pkill -x meetrec 2>/dev/null && sleep 1 || true
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
open "$DEST"
echo "✅ meetrec.app установлен в ~/Applications и запущен — иконка в строке меню"
