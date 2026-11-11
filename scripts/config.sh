# Подключается из других скриптов: читает ~/.config/meetrec/env (KEY=value по строке),
# но НЕ перекрывает переменные, уже заданные в окружении/командной строке.
CONFIG="${MEETREC_CONFIG:-$HOME/.config/meetrec/env}"
if [[ -f "$CONFIG" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
    eval "already=\${$key+set}"
    if [[ -z "$already" ]]; then export "$key=$value"; fi
  done < "$CONFIG"
fi
