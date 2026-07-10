#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — Полное удаление VPN Setup и панели
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

printf "\n  ${RED}⚠${NC}  ${BOLD}Полное удаление VPN Setup${NC}\n"
printf "  %s\n\n" "──────────────────────────────────────────────────────────"
printf "  ${YELLOW}Будет удалено:${NC}\n"
printf "  • Сервисы: mita, hysteria-server, WARP, vpn-panel, vpn-sub\n"
printf "  • Конфиги: /etc/hysteria, /etc/mita, /etc/vpn-setup-state\n"
printf "  • Панель: /opt/vpn-panel, /etc/vpn-panel\n"
printf "  • Пользователи: hysteria, mita, vpnsub\n"
printf "  • Правила: iptables, UFW, sysctl\n"
printf "  • Systemd-юниты\n\n"

read -rp "  Введите 'yes' для подтверждения: " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "  Отмена."
    exit 0
fi

printf "\n  ${CYAN}Удаление...${NC}\n\n"

# Останавливаем и отключаем сервисы
for svc in mita hysteria-server vpn-panel vpn-sub warp-routing "wg-quick@wgcf-warp" fail2ban; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done

# Удаляем systemd-юниты
for unit in mita hysteria-server vpn-panel vpn-sub warp-routing; do
    rm -f "/etc/systemd/system/${unit}.service"
done
systemctl daemon-reload 2>/dev/null || true

# Удаляем конфиги и данные
rm -rf /etc/hysteria
rm -rf /etc/mita
rm -rf /etc/wgcf
rm -rf /etc/wireguard/wgcf-warp.conf
rm -rf /etc/vpn-setup-state
rm -rf /etc/vpn-panel
rm -rf /opt/vpn-panel
rm -rf /var/www/html
rm -f /root/vpn-setup-info.txt
rm -f /root/vpn-setup-sub.txt
rm -f /etc/sysctl.d/99-vpn-tuning.conf
rm -f /etc/iptables/rules.v4
rm -f /usr/local/bin/vpn-setup
rm -f /usr/local/bin/wgcf

# Очищаем iptables
iptables -t mangle -F OUTPUT 2>/dev/null || true
iptables -t nat -F POSTROUTING 2>/dev/null || true
ip6tables -t mangle -F OUTPUT 2>/dev/null || true
ip rule del fwmark 0x1 table 200 2>/dev/null || true
ip link del wgcf-warp 2>/dev/null || true

# Удаляем ICMP-правило из UFW
sed -i '/vpn-setup-icmp-block/d' /etc/ufw/before.rules 2>/dev/null || true

# Удаляем пользователей
userdel -r hysteria 2>/dev/null || true
userdel -r vpnsub 2>/dev/null || true
userdel -r mita 2>/dev/null || true

# Удаляем pip-пакеты
pip3 uninstall -y flask flask-wtf 2>/dev/null || true

printf "\n  ${GREEN}✔${NC}  VPN Setup полностью удалён.\n\n"
