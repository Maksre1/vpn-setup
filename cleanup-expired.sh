#!/usr/bin/env bash
# =============================================================================
# cleanup-expired.sh — Деактивация истёкших пользователей (делегирование в Python CLI)
# =============================================================================
set -euo pipefail

LOG="/var/log/vpn-cleanup.log"
PANEL_DIR="/opt/vpn-panel"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

log "Запуск очистки истекших пользователей..."
if [[ -f "$PANEL_DIR/manage_users.py" ]]; then
    python3 "$PANEL_DIR/manage_users.py" cleanup >> "$LOG" 2>&1
    log "Очистка завершена."
else
    log "Ошибка: Скрипт manage_users.py не найден в $PANEL_DIR"
    exit 1
fi
