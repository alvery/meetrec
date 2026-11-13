#!/usr/bin/env bash
# Сборка и установка meetrec-gateway на сервере как пользовательского сервиса systemd.
# Слушает 127.0.0.1:8787 (только localhost); токен — ~/.config/meetrec/gateway-token.
set -euo pipefail
cd "$(dirname "$0")"
go build -o "$HOME/.local/bin/meetrec-gateway" .
mkdir -p "$HOME/.config/systemd/user"
cp meetrec-gateway.service "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now meetrec-gateway
systemctl --user restart meetrec-gateway
sleep 1
curl -fsS 127.0.0.1:8787/healthz >/dev/null && echo "✅ meetrec-gateway работает на 127.0.0.1:8787"
echo "Токен (вставь в meetrec → Настройки → Агент или нажми там «С сервера»): ~/.config/meetrec/gateway-token"
