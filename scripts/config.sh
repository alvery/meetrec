# Подключается из других скриптов: читает ~/.config/meetrec/env и gateway.env (KEY=value по строке),
# но НЕ перекрывает переменные, уже заданные в окружении/командной строке.
# Поддерживает: `export KEY=...`, кавычки, `~` и `$HOME` в значении, комментарии `# ...`.
# gateway.env пишет приложение (настройки шлюза); env — ручной и важнее (читается первым).
for CONFIG in "${MEETREC_CONFIG:-$HOME/.config/meetrec/env}" "${MEETREC_GATEWAY_CONFIG:-$HOME/.config/meetrec/gateway.env}"; do
if [[ -f "$CONFIG" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    if [[ "$value" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ || "$value" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
      value="${BASH_REMATCH[1]}"                # в кавычках (+ необязательный комментарий)
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
done
