#!/usr/bin/env bash
# =============================================================================
# cleanup-expired.sh — Автоочистка истёкших пользователей (cron)
# =============================================================================
set -euo pipefail

STATE_DIR="/etc/vpn-setup-state"
USERS_FILE="$STATE_DIR/vpn-users.conf"
LOG="/var/log/vpn-cleanup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

if [[ ! -f "$USERS_FILE" ]]; then
    exit 0
fi

TODAY=$(date +%s)
CHANGES=0

# Читаем пользователей и проверяем сроки
while IFS='|' -r read -r username password expire_date rest; do
    [[ -z "$username" ]] && continue
    [[ "$expire_date" == "never" ]] && continue

    expire_epoch=$(date -d "$expire_date" +%s 2>/dev/null || echo 0)
    if [[ "$expire_epoch" -gt 0 && "$expire_epoch" -lt "$TODAY" ]]; then
        log "Деактивация: $username (срок: $expire_date)"
        # Помечаем как неактивного (меняем is_active на 0)
        sed -i "s/^${username}|/DISABLED_${username}|/" "$USERS_FILE"
        CHANGES=$((CHANGES + 1))
    fi
done < "$USERS_FILE"

# Обновляем конфиг Mieru если были изменения
if [[ "$CHANGES" -gt 0 ]]; then
    log "Деактивировано пользователей: $CHANGES"

    # Пересобираем конфиг mita с активными пользователями
    if [[ -f "$STATE_DIR/mieru.env" ]]; then
        source "$STATE_DIR/mieru.env"
        users_json=""
        while IFS='|' -r read -r uname upass _rest; do
            [[ "$uname" == DISABLED_* ]] && continue
            [[ -z "$uname" ]] && continue
            users_json+="{\"name\":\"${uname}\",\"password\":\"${upass}\"},"
        done < "$USERS_FILE"
        users_json="[${users_json%,}]"

        cat > /tmp/mita_cleanup_config.json <<EOF
{
    "portBindings": [
        {"port": ${MIERU_PORT}, "protocol": "TCP"},
        {"port": ${MIERU_UDP_PORT}, "protocol": "UDP"}
    ],
    "users": ${users_json},
    "loggingLevel": "WARN",
    "mtu": 1400
}
EOF
        mita apply config /tmp/mita_cleanup_config.json 2>/dev/null || true
        rm -f /tmp/mita_cleanup_config.json
        systemctl restart mita 2>/dev/null || true
        log "Конфиг Mieru обновлён"
    fi
fi
