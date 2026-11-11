# Подключается из других скриптов: читает ~/.config/meetrec/env (KEY=value по строке),
# но НЕ перекрывает переменные, уже заданные в окружении/командной строке.
# Поддерживает: `export KEY=...`, кавычки, `~` и `$HOME` в значении, комментарии `# ...`.
CONFIG="${MEETREC_CONFIG:-$HOME/.config/meetrec/env}"
if [[ -f "$CONFIG" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    if [[ ${#value} -ge 2 && ( "$value" == \"*\" || "$value" == \'*\' ) ]]; then
      value="${value:1:${#value}-2}"
    else
      value="${value%%[[:space:]]#*}"            # комментарий в конце строки без кавычек
      value="${value%"${value##*[![:space:]]}"}" # хвостовые пробелы
    fi
    if [[ "$value" == "~" || "$value" == "~/"* ]]; then value="$HOME${value:1}"; fi
    value="${value//\$HOME/$HOME}"
    eval "already=\${$key+set}"
    if [[ -z "$already" ]]; then export "$key=$value"; fi
  done < "$CONFIG"
fi
