#!/usr/bin/env bash
# Тестовая встреча в отдельном календаре «meetrec-test» (рабочий календарь не трогаем).
#
#   ./scripts/mock-meeting.sh [через_минут] [длительность_минут] [название]
#       по умолчанию: через 2 мин, 15 мин, «Тестовый созвон meetrec»
#   ./scripts/mock-meeting.sh --clean     удалить все события календаря meetrec-test
#
# Ссылка — https://meet.google.com/new: «Подключиться» откроет новую комнату Meet,
# браузер займёт микрофон — можно проверить уведомление «Начинается… — Записать?».
# При первом запуске macOS спросит, можно ли терминалу управлять «Календарём» — разреши.
set -euo pipefail
CAL="meetrec-test"

if [[ "${1:-}" == "--clean" ]]; then
  osascript - "$CAL" <<'AS'
on run argv
  set calName to item 1 of argv
  tell application "Calendar"
    if exists calendar calName then
      delete (every event of calendar calName)
      return "удалены все события календаря " & calName
    end if
    return "календаря " & calName & " нет"
  end tell
end run
AS
  exit 0
fi

in_min="${1:-2}"
dur_min="${2:-15}"
title="${3:-Тестовый созвон meetrec}"
link="https://meet.google.com/new"

osascript - "$CAL" "$in_min" "$dur_min" "$title" "$link" <<'AS'
on run argv
  set calName to item 1 of argv
  set inMin to (item 2 of argv) as integer
  set durMin to (item 3 of argv) as integer
  set evTitle to item 4 of argv
  set joinLink to item 5 of argv
  set startDate to (current date) + inMin * minutes
  set endDate to startDate + durMin * minutes
  tell application "Calendar"
    if not (exists calendar calName) then make new calendar with properties {name:calName}
    tell calendar calName
      make new event with properties {summary:evTitle, start date:startDate, end date:endDate, url:joinLink, description:"Подключиться: " & joinLink}
    end tell
  end tell
  return "создано: «" & evTitle & "» " & (time string of startDate) & "–" & (time string of endDate) & " в календаре " & calName
end run
AS
