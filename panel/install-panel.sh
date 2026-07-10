#!/usr/bin/env bash
# install-panel.sh — Установка VPN Panel
set -euo pipefail

PANEL_DIR="/opt/vpn-panel"
STATE_DIR="/etc/vpn-setup-state"
PANEL_STATE="/etc/vpn-panel"
PANEL_PORT="${PANEL_PORT:-$(shuf -i 20000-65000 -n 1)}"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

printf "\n  ${CYAN}⧗${NC}  Установка VPN Panel (порт: %s)...\r" "$PANEL_PORT"

# 1. Установка зависимостей
pip3 install --break-system-packages flask flask-wtf 2>/dev/null || \
pip3 install flask flask-wtf 2>/dev/null || true

# 2. Копирование файлов
mkdir -p "$PANEL_DIR"/{templates,static,certs}
mkdir -p "$PANEL_STATE"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Копируем Python модули
for f in app.py models.py utils.py; do
    cp "$SCRIPT_DIR/$f" "$PANEL_DIR/$f" 2>/dev/null || true
done

# Копируем шаблоны
cp -r "$SCRIPT_DIR/templates/"* "$PANEL_DIR/templates/" 2>/dev/null || true

# Копируем статику
cp -r "$SCRIPT_DIR/static/"* "$PANEL_DIR/static/" 2>/dev/null || true

# 3. Генерация ECDSA-сертификата
if [[ ! -f "$PANEL_DIR/certs/server.key" ]]; then
    openssl ecparam -genkey -name prime256v1 \
        -out "$PANEL_DIR/certs/server.key" 2>/dev/null
    openssl req -new -x509 \
        -key "$PANEL_DIR/certs/server.key" \
        -out "$PANEL_DIR/certs/server.crt" \
        -days 3650 -nodes \
        -subj "/CN=vpn-panel/O=VPN/C=US" 2>/dev/null
    chmod 600 "$PANEL_DIR/certs/server.key"
    chmod 644 "$PANEL_DIR/certs/server.crt"
fi

# 4. Настройка systemd
sed "s|__PANEL_PORT__|${PANEL_PORT}|g" "$SCRIPT_DIR/vpn-panel.service" \
    > /etc/systemd/system/vpn-panel.service

systemctl daemon-reload
systemctl enable vpn-panel 2>/dev/null || true
systemctl restart vpn-panel 2>/dev/null || true

# 5. UFW
ufw allow "$PANEL_PORT"/tcp comment "VPN Panel" 2>/dev/null || true

# 6. Сохранение порта
echo "PANEL_PORT=\"${PANEL_PORT}\"" > "$STATE_DIR/panel.env"
chmod 600 "$STATE_DIR/panel.env"

# 7. Ожидание запуска и получение пароля
sleep 3
ADMIN_PASS=""
if [[ -f "$PANEL_STATE/admin_password.txt" ]]; then
    ADMIN_PASS=$(grep "admin:" "$PANEL_STATE/admin_password.txt" | cut -d: -f2)
fi

SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "YOUR_IP")

printf "  ${GREEN}✔${NC}  VPN Panel установлена.\n\n"
printf "  ${BOLD}Панель:${NC}     https://%s:%s\n" "$SERVER_IP" "$PANEL_PORT"
printf "  ${BOLD}Логин:${NC}      admin\n"
printf "  ${BOLD}Пароль:${NC}     %s\n\n" "${ADMIN_PASS:-проверьте /etc/vpn-panel/admin_password.txt}"
