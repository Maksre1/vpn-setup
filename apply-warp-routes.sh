#!/bin/bash
# apply-warp-routes.sh — Применение iptables-правил для WARP split-tunneling
# Вызывается из setup_warp и /etc/network/if-up.d/warp-routing

STATE_DIR="/etc/vpn-setup-state"
[ -f "$STATE_DIR/mieru.env" ] && source "$STATE_DIR/mieru.env"
[ -f "$STATE_DIR/hysteria2.env" ] && source "$STATE_DIR/hysteria2.env"
[ -f "$STATE_DIR/naiveproxy.env" ] && source "$STATE_DIR/naiveproxy.env"

# Таблица маршрутизации
mkdir -p /etc/iproute2
if [ ! -f /etc/iproute2/rt_tables ]; then
    cat > /etc/iproute2/rt_tables <<'EOF'
255	local
254	main
253	default
0	unspec
EOF
fi
if ! grep -q "^200 " /etc/iproute2/rt_tables; then
    echo "200 warp" >> /etc/iproute2/rt_tables
fi

# Маршрут по умолчанию через WARP
if ip link show wgcf-warp &>/dev/null; then
    ip route add default dev wgcf-warp table 200 2>/dev/null || true
fi

# Правило маршрутизации
if ! ip rule show 2>/dev/null | grep -q "fwmark 0x1 lookup 200"; then
    ip rule add fwmark 0x1 table 200 priority 100 2>/dev/null || true
fi

# Endpoint IP для исключения из петли
endpoint_ip=""
if [ -f "/etc/wireguard/wgcf-warp.conf" ]; then
    endpoint_ip=$(grep -i "^Endpoint" /etc/wireguard/wgcf-warp.conf | awk -F'=' '{print $2}' | tr -d ' ' | cut -d':' -f1 | tr -d '[]')
fi

# Очистка старых правил
iptables -t mangle -F OUTPUT 2>/dev/null || true
ip6tables -t mangle -F OUTPUT 2>/dev/null || true

# Loopback — пропуск
iptables -t mangle -A OUTPUT -o lo -j RETURN

# DNS — пропуск (чтобы резолвинг работал через прямой интерфейс)
iptables -t mangle -A OUTPUT -p udp --dport 53 -j RETURN
iptables -t mangle -A OUTPUT -p tcp --dport 53 -j RETURN

# VPN-сервисы — пропуск (не маршрутизировать через WARP)
if [ -n "${H2_PORT:-}" ]; then
    iptables -t mangle -A OUTPUT -p udp --sport "$H2_PORT" -j RETURN
fi
if [ -n "${MIERU_PORT:-}" ]; then
    iptables -t mangle -A OUTPUT -p tcp --sport "$MIERU_PORT" -j RETURN
fi
if [ -n "${MIERU_UDP_PORT:-}" ]; then
    iptables -t mangle -A OUTPUT -p udp --sport "$MIERU_UDP_PORT" -j RETURN
fi

# Endpoint WARP — пропуск (защита от петли маршрутизации)
if [ -n "$endpoint_ip" ]; then
    if [[ "$endpoint_ip" =~ : ]]; then
        ip6tables -t mangle -A OUTPUT -d "$endpoint_ip" -j RETURN 2>/dev/null || true
    else
        iptables -t mangle -A OUTPUT -d "$endpoint_ip" -j RETURN 2>/dev/null || true
    fi
fi

# Пометка трафика VPN-пользователей для маршрутизации через WARP
mita_uid=$(id -u mita 2>/dev/null)
if [ -n "$mita_uid" ]; then
    iptables -t mangle -A OUTPUT -m owner --uid-owner "$mita_uid" -j MARK --set-mark 0x1
fi
hysteria_uid=$(id -u hysteria 2>/dev/null)
if [ -n "$hysteria_uid" ]; then
    iptables -t mangle -A OUTPUT -m owner --uid-owner "$hysteria_uid" -j MARK --set-mark 0x1
fi

# NAT маскарадинг
iptables -t nat -D POSTROUTING -o wgcf-warp -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -o wgcf-warp -j MASQUERADE
