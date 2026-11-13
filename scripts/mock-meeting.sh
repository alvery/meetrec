#!/usr/bin/env bash
# Тестовая встреча в отдельном календаре «meetrec-test» (рабочий календарь не трогаем).
#
#   ./scripts/mock-meeting.sh [через_минут] [длительность_минут] [название]
#       по умолчанию: через 2 мин, 15 мин, «Тестовый созвон meetrec»
#   ./scripts/mock-meeting.sh --day       набор встреч для проверки новых функций (см. ниже)
#   ./scripts/mock-meeting.sh --clean     удалить все события календаря meetrec-test
#
# --day:
#   +3 мин  «Sync платформы» (10 мин)  — плашка «Подключиться» с проверкой звука; запиши, затем выйди из Meet
#                                         → через минуту «Остановить запись?»; ★ — ⌃⌥M во время записи
#   +13 мин «1:1 с Аней» (10 мин)       — встык: «Началась «1:1 с Аней»» + «Стоп и подключиться»;
#                                         за 5 мин до конца записи кольцо в строке меню желтеет
#   +40 мин «Sync платформы» (10 мин)   — второй раз: в карточке и на плашке задачи с первой встречи
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

create() { # через_минут длительность_минут название
  osascript - "$CAL" "$1" "$2" "$3" "https://meet.google.com/new" <<'AS'
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
}

if [[ "${1:-}" == "--day" ]]; then
  create 3 10 "Sync платформы"
  create 13 10 "1:1 с Аней"
  create 40 10 "Sync платформы"
  exit 0
fi

create "${1:-2}" "${2:-15}" "${3:-Тестовый созвон meetrec}"
