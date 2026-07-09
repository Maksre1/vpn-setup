#!/usr/bin/env bash
# =============================================================================
# setup.sh — Автоматическая настройка VPS под личный VPN-сервер
# Совместимость: Ubuntu 22.04 / 24.04, запуск от root
# Использование: bash setup.sh
#
# Компоненты: Mieru (mita), Hysteria2, Cloudflare WARP (wgcf)
# Лог: /var/log/vpn-setup.log
#
# Источники:
#   Mieru: https://github.com/enfein/mieru/blob/main/docs/server-install.md
#   Hysteria2: https://v2.hysteria.network/docs/advanced/Full-Server-Config/
# =============================================================================

set -euo pipefail

# ── Глобальные переменные ────────────────────────────────────────────────────
readonly LOG_FILE="/var/log/vpn-setup.log"
readonly STATE_DIR="/etc/vpn-setup-state"          # маркеры выполненных шагов
readonly MIERU_CONFIG_DIR="/etc/mita"
readonly H2_CONFIG_DIR="/etc/hysteria"
readonly H2_CERT_DIR="/etc/hysteria/certs"
readonly INFO_FILE="/root/vpn-setup-info.txt"

# SSH-порт (можно переопределить перед запуском: SSH_PORT=2222 bash setup.sh)
SSH_PORT="${SSH_PORT:-22}"

# Цвета для вывода в терминал
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# =============================================================================
# Вспомогательные функции логирования
# =============================================================================

# Инициализация лога
init_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    echo "" >> "$LOG_FILE"
    echo "======================================" >> "$LOG_FILE"
    echo "Запуск setup.sh: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    echo "======================================" >> "$LOG_FILE"
}

# Вывод в терминал И в лог одновременно
log() {
    local msg="$1"
    echo -e "$msg" | tee -a "$LOG_FILE"
}

log_section() {
    local title="$1"
    log ""
    log "${CYAN}${BOLD}══════════════════════════════════════════${NC}"
    log "${CYAN}${BOLD}  $title${NC}"
    log "${CYAN}${BOLD}══════════════════════════════════════════${NC}"
}

log_step() {
    log "${YELLOW}  ▶ $1${NC}"
}

log_ok() {
    log "${GREEN}  [OK]${NC} $1"
}

log_fail() {
    log "${RED}  [FAIL]${NC} $1"
}

log_info() {
    log "        $1"
}

# Пометить шаг как выполненный (для идемпотентности)
mark_done() {
    mkdir -p "$STATE_DIR"
    touch "$STATE_DIR/$1.done"
}

# Проверить, выполнен ли шаг
is_done() {
    [[ -f "$STATE_DIR/$1.done" ]]
}

# Найти свободный TCP/UDP порт в заданном диапазоне
find_free_port() {
    local proto="${1:-tcp}"   # tcp или udp
    local range_min="${2:-20000}"
    local range_max="${3:-65000}"
    local port
    while true; do
        port=$(( RANDOM % (range_max - range_min + 1) + range_min ))
        if ! ss -"${proto}"ln 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return 0
        fi
    done
}

# Получить внешний IP сервера
get_server_ip() {
    curl -s --max-time 5 https://api.ipify.org \
        || curl -s --max-time 5 https://ifconfig.me \
        || curl -s --max-time 5 https://icanhazip.com \
        || echo "UNKNOWN"
}

# Проверить, что скрипт запущен от root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Ошибка: скрипт должен быть запущен от root.${NC}"
        echo "Используйте: sudo bash setup.sh"
        exit 1
    fi
}

# Проверить совместимость ОС
check_os() {
    if ! grep -q -E "Ubuntu (22|24)\." /etc/os-release 2>/dev/null; then
        log_fail "Обнаружена неподдерживаемая ОС. Рекомендуется Ubuntu 22.04 или 24.04."
        log_info "Продолжение на ваш страх и риск..."
        sleep 3
    fi
}

# =============================================================================
# 1. update_system
# =============================================================================
update_system() {
    log_section "1. Обновление системы и установка базовых утилит"

    if is_done "update_system"; then
        log_ok "Шаг уже выполнен, пропускаем."
        return 0
    fi

    log_step "Обновление списков пакетов (apt update)..."
    if DEBIAN_FRONTEND=noninteractive apt-get update -qq >> "$LOG_FILE" 2>&1; then
        log_ok "apt update"
    else
        log_fail "apt update завершился с ошибкой"
        return 1
    fi

    log_step "Обновление установленных пакетов (apt upgrade)..."
    if DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq >> "$LOG_FILE" 2>&1; then
        log_ok "apt upgrade"
    else
        log_fail "apt upgrade завершился с ошибкой"
        return 1
    fi

    log_step "Установка базовых утилит..."
    local pkgs=(
        curl wget unzip jq ufw net-tools
        wireguard wireguard-tools          # нужен для WARP (wg-quick)
        iptables iproute2                  # маршрутизация для WARP
        openssl                            # генерация TLS-сертификата
        ethtool                            # определение скорости интерфейса
        python3                            # используется скриптом mita
        build-essential                    # опциональные dev-зависимости
    )

    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >> "$LOG_FILE" 2>&1; then
        log_ok "Базовые утилиты установлены: ${pkgs[*]}"
    else
        log_fail "Не удалось установить часть пакетов. Проверьте $LOG_FILE"
        return 1
    fi

    # Включаем ip_forward (нужен для wg-quick и маршрутизации)
    log_step "Включение IP forwarding..."
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/10-ip-forward.conf
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/10-ip-forward.conf
    sysctl -p /etc/sysctl.d/10-ip-forward.conf >> "$LOG_FILE" 2>&1
    log_ok "IP forwarding включён"

    mark_done "update_system"
    log_ok "Шаг 1 завершён."
}

# =============================================================================
# 2. setup_firewall
# =============================================================================
setup_firewall() {
    log_section "2. Настройка брандмауэра (ufw)"

    if is_done "setup_firewall"; then
        log_ok "Шаг уже выполнен, пропускаем."
        return 0
    fi

    log_step "Сброс ufw в начальное состояние..."
    # Отключаем, чтобы не заблокировать себя при сбросе
    ufw --force disable >> "$LOG_FILE" 2>&1 || true
    ufw --force reset >> "$LOG_FILE" 2>&1

    log_step "Политика по умолчанию: входящие — запрещены, исходящие — разрешены..."
    ufw default deny incoming >> "$LOG_FILE" 2>&1
    ufw default allow outgoing >> "$LOG_FILE" 2>&1

    log_step "Разрешаем SSH на порту $SSH_PORT..."
    ufw allow "$SSH_PORT"/tcp comment "SSH" >> "$LOG_FILE" 2>&1
    log_ok "SSH порт $SSH_PORT открыт"

    log_step "Включаем ufw..."
    # IMPORTANT: разрешаем SSH до enable, иначе соединение оборвётся
    echo "y" | ufw enable >> "$LOG_FILE" 2>&1
    log_ok "ufw включён"

    # Блокировка ICMP echo через ufw (before.rules)
    log_step "Добавление блокировки ICMP ping в ufw before.rules..."
    local before_rules="/etc/ufw/before.rules"
    if ! grep -q "vpn-setup-icmp-block" "$before_rules" 2>/dev/null; then
        # Вставляем правило перед строкой COMMIT в секции filter
        sed -i '/^# End required lines/a # vpn-setup-icmp-block\n-A ufw-before-input -p icmp --icmp-type echo-request -j DROP' \
            "$before_rules" >> "$LOG_FILE" 2>&1
        log_ok "Блокировка ICMP ping добавлена в $before_rules"
    else
        log_ok "Блокировка ICMP ping уже присутствует"
    fi

    ufw reload >> "$LOG_FILE" 2>&1
    log_ok "ufw перезагружен"

    log_info "Открытые порты VPN-сервисов будут добавлены после генерации портов (шаги 5-6)."

    mark_done "setup_firewall"
    log_ok "Шаг 2 завершён."
}

# =============================================================================
# 3. detect_system_specs — определение характеристик сервера
# =============================================================================
detect_system_specs() {
    log_section "3. Определение характеристик сервера"

    # Определяем RAM (в МБ)
    RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    log_step "RAM: ${RAM_MB} МБ"

    # Количество CPU-ядер
    CPU_CORES=$(nproc)
    log_step "CPU-ядра: ${CPU_CORES}"

    # Версия ядра
    KERNEL_VERSION=$(uname -r)
    log_step "Ядро Linux: $KERNEL_VERSION"

    # Проверка/загрузка модуля BBR
    log_step "Проверка доступности TCP BBR..."
    BBR_AVAILABLE=0
    if modprobe tcp_bbr 2>/dev/null; then
        if lsmod | grep -q "^tcp_bbr"; then
            BBR_AVAILABLE=1
            log_ok "Модуль tcp_bbr загружен и активен"
        fi
    fi

    if [[ $BBR_AVAILABLE -eq 0 ]]; then
        # Попытка добавить в modules-load
        echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf
        log_info "Модуль tcp_bbr добавлен в /etc/modules-load.d/tcp_bbr.conf (активируется при перезагрузке)"
        # Проверяем поддержку ядром
        if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            BBR_AVAILABLE=1
            log_ok "BBR доступен через sysctl (без явного модуля)"
        else
            log_fail "Модуль tcp_bbr недоступен в этом ядре. BBR не будет включён."
        fi
    fi

    # Скорость сетевого интерфейса (ethtool)
    log_step "Определение скорости сетевого интерфейса..."
    # Находим основной интерфейс (первый не-loopback с IPv4-маршрутом)
    NET_IFACE=$(ip route | awk '/default/{print $5; exit}')
    LINK_SPEED_MBPS=0
    if [[ -n "$NET_IFACE" ]]; then
        LINK_SPEED_MBPS=$(ethtool "$NET_IFACE" 2>/dev/null \
            | grep -i "Speed:" \
            | grep -oP '\d+' | head -1 || echo 0)
    fi

    if [[ -z "$LINK_SPEED_MBPS" || "$LINK_SPEED_MBPS" -eq 0 ]]; then
        log_info "ethtool не вернул реальную скорость (виртуальный интерфейс или недоступен)."
        log_info "Закладываем безопасные средние значения."
        LINK_SPEED_MBPS=0   # 0 = неизвестно
    else
        log_ok "Скорость интерфейса $NET_IFACE: ${LINK_SPEED_MBPS} Мбит/с"
    fi

    # ── Вычисление sysctl-буферов на основе RAM и CPU ────────────────────────
    log_step "Вычисление оптимальных сетевых буферов..."

    if [[ $RAM_MB -lt 1024 ]]; then
        # < 1 ГБ RAM: консервативные буферы (до нескольких МБ)
        RMEM_MAX=$((2 * 1024 * 1024))           #  2 МБ
        WMEM_MAX=$((2 * 1024 * 1024))           #  2 МБ
        TCP_RMEM="4096 87380 2097152"           # min/default/max
        TCP_WMEM="4096 65536 2097152"
        NETDEV_MAX_BACKLOG=2000
        SOMAXCONN=512
        TCP_MAX_SYN_BACKLOG=512
        BUF_TIER="консервативный (RAM < 1 ГБ)"

    elif [[ $RAM_MB -lt 4096 ]]; then
        # 1-4 ГБ RAM: средние значения
        RMEM_MAX=$((16 * 1024 * 1024))          # 16 МБ
        WMEM_MAX=$((16 * 1024 * 1024))          # 16 МБ
        TCP_RMEM="4096 131072 16777216"
        TCP_WMEM="4096 131072 16777216"
        NETDEV_MAX_BACKLOG=5000
        SOMAXCONN=1024
        TCP_MAX_SYN_BACKLOG=1024
        BUF_TIER="средний (RAM 1-4 ГБ)"

    else
        # > 4 ГБ RAM
        if [[ $CPU_CORES -ge 2 ]]; then
            # > 4 ГБ + ≥2 CPU: агрессивные буферы
            RMEM_MAX=$((67 * 1024 * 1024))      # ~64 МБ
            WMEM_MAX=$((67 * 1024 * 1024))      # ~64 МБ
            TCP_RMEM="4096 262144 67108864"
            TCP_WMEM="4096 262144 67108864"
            NETDEV_MAX_BACKLOG=10000
            SOMAXCONN=4096
            TCP_MAX_SYN_BACKLOG=4096
            BUF_TIER="агрессивный (RAM > 4 ГБ, CPU ≥ 2)"
        else
            # > 4 ГБ, но 1 CPU: умеренно-агрессивный
            RMEM_MAX=$((32 * 1024 * 1024))      # 32 МБ
            WMEM_MAX=$((32 * 1024 * 1024))
            TCP_RMEM="4096 131072 33554432"
            TCP_WMEM="4096 131072 33554432"
            NETDEV_MAX_BACKLOG=5000
            SOMAXCONN=2048
            TCP_MAX_SYN_BACKLOG=2048
            BUF_TIER="умеренный (RAM > 4 ГБ, CPU = 1)"
        fi
    fi

    # Экспортируем переменные для использования в tune_network
    export BBR_AVAILABLE RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM
    export NETDEV_MAX_BACKLOG SOMAXCONN TCP_MAX_SYN_BACKLOG
    export NET_IFACE

    log_ok "Профиль буферов: $BUF_TIER"
    log_info "  net.core.rmem_max         = $RMEM_MAX байт"
    log_info "  net.core.wmem_max         = $WMEM_MAX байт"
    log_info "  net.ipv4.tcp_rmem         = $TCP_RMEM"
    log_info "  net.ipv4.tcp_wmem         = $TCP_WMEM"

    log_ok "Шаг 3 завершён."
}

# =============================================================================
# 4. tune_network — сетевая оптимизация
# =============================================================================
tune_network() {
    log_section "4. Настройка сетевых параметров ядра"

    if is_done "tune_network"; then
        log_ok "Шаг уже выполнен, пропускаем."
        return 0
    fi

    # Проверяем, что переменные установлены (шаг 3 должен быть выполнен)
    if [[ -z "${RMEM_MAX:-}" ]]; then
        log_fail "Переменные из detect_system_specs не установлены."
        return 1
    fi

    log_step "Запись параметров в /etc/sysctl.d/99-vpn-tuning.conf..."

    cat > /etc/sysctl.d/99-vpn-tuning.conf <<EOF
# Файл сгенерирован setup.sh $(date '+%Y-%m-%d %H:%M:%S')
net.ipv4.tcp_congestion_control = $(if [[ $BBR_AVAILABLE -eq 1 ]]; then echo "bbr"; else echo "cubic"; fi)
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = ${TCP_RMEM}
net.ipv4.tcp_wmem = ${TCP_WMEM}
net.ipv4.tcp_mtu_probing = 1
net.core.netdev_max_backlog = ${NETDEV_MAX_BACKLOG}
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${TCP_MAX_SYN_BACKLOG}
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65000
net.ipv4.tcp_fin_timeout = 30
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

    log_ok "Файл /etc/sysctl.d/99-vpn-tuning.conf записан"

    log_step "Применение параметров (sysctl --system)..."
    if sysctl --system >> "$LOG_FILE" 2>&1; then
        log_ok "sysctl --system выполнен"
    else
        log_fail "sysctl --system завершился с ошибкой. Проверить в $LOG_FILE"
        return 1
    fi

    # Дополнительное правило iptables для блокировки ICMP (двойная защита)
    if ! iptables -C INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null; then
        iptables -I INPUT -p icmp --icmp-type echo-request -j DROP
    fi

    mark_done "tune_network"
    log_ok "Шаг 4 завершён."
}

# =============================================================================
# 5. install_mieru — установка прокси-сервера Mieru (mita)
# =============================================================================
install_mieru() {
    log_section "5. Установка Mieru (mita — серверный компонент)"

    if is_done "install_mieru"; then
        log_ok "Шаг уже выполнен, пропускаем."
        if [[ -f "$STATE_DIR/mieru.env" ]]; then
            # shellcheck source=/dev/null
            source "$STATE_DIR/mieru.env"
        fi
        return 0
    fi

    log_step "Определение архитектуры системы..."
    local arch
    arch=$(uname -m)
    local deb_arch
    case "$arch" in
        x86_64)   deb_arch="amd64" ;;
        aarch64)  deb_arch="arm64" ;;
        *)
            log_fail "Неподдерживаемая архитектура: $arch."
            return 1
            ;;
    esac

    log_step "Получение последней версии mita с GitHub..."
    local mita_version
    mita_version=$(curl -s --max-time 15 \
        "https://api.github.com/repos/enfein/mieru/releases/latest" \
        | grep '"tag_name"' \
        | sed 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/')

    if [[ -z "$mita_version" ]]; then
        log_fail "Не удалось получить версию mita из GitHub API"
        return 1
    fi

    local deb_file="mita_${mita_version}_${deb_arch}.deb"
    local download_url="https://github.com/enfein/mieru/releases/download/v${mita_version}/${deb_file}"
    local tmp_deb="/tmp/${deb_file}"

    log_step "Скачивание $deb_file..."
    if curl -L --max-time 120 --progress-bar -o "$tmp_deb" "$download_url" 2>&1 | tee -a "$LOG_FILE"; then
        log_ok "Скачано"
    else
        log_fail "Не удалось скачать mita с GitHub"
        return 1
    fi

    log_step "Установка пакета mita..."
    if dpkg -i "$tmp_deb" >> "$LOG_FILE" 2>&1; then
        log_ok "mita установлен"
    else
        log_fail "dpkg -i завершился с ошибкой."
        return 1
    fi
    rm -f "$tmp_deb"

    MIERU_PORT=$(find_free_port tcp 20000 50000)
    MIERU_USER="user_$(openssl rand -hex 4)"
    MIERU_PASS=$(openssl rand -base64 22 | tr -d '/+=' | head -c 24)

    local mita_config_file="/tmp/mita_server_config.json"
    cat > "$mita_config_file" <<EOF
{
    "portBindings": [
        {
            "port": ${MIERU_PORT},
            "protocol": "TCP"
        }
    ],
    "users": [
        {
            "name": "${MIERU_USER}",
            "password": "${MIERU_PASS}"
        }
    ],
    "loggingLevel": "INFO",
    "mtu": 1400
}
EOF

    systemctl enable mita >> "$LOG_FILE" 2>&1 || true
    systemctl start mita >> "$LOG_FILE" 2>&1 || {
        log_fail "Не удалось запустить службу mita"
        return 1
    }
    sleep 2

    if mita apply config "$mita_config_file" >> "$LOG_FILE" 2>&1; then
        log_ok "Конфигурация применена"
    else
        log_fail "Не удалось применить конфигурацию mita"
        return 1
    fi
    rm -f "$mita_config_file"

    mita start >> "$LOG_FILE" 2>&1 || true
    ufw allow "$MIERU_PORT"/tcp comment "Mieru proxy" >> "$LOG_FILE" 2>&1

    mkdir -p "$STATE_DIR"
    cat > "$STATE_DIR/mieru.env" <<EOF
MIERU_PORT=${MIERU_PORT}
MIERU_USER=${MIERU_USER}
MIERU_PASS=${MIERU_PASS}
MIERU_VERSION=${mita_version}
EOF
    chmod 600 "$STATE_DIR/mieru.env"

    mark_done "install_mieru"
    log_ok "Шаг 5 завершён."
}

# =============================================================================
# 6. install_hysteria2 — установка Hysteria2
# =============================================================================
install_hysteria2() {
    log_section "6. Установка Hysteria2"

    if is_done "install_hysteria2"; then
        log_ok "Шаг уже выполнен, пропускаем."
        if [[ -f "$STATE_DIR/hysteria2.env" ]]; then
            # shellcheck source=/dev/null
            source "$STATE_DIR/hysteria2.env"
        fi
        return 0
    fi

    log_step "Установка Hysteria2 через официальный скрипт..."
    if bash <(curl -fsSL https://get.hy2.sh/) >> "$LOG_FILE" 2>&1; then
        log_ok "Hysteria2 установлен"
    else
        log_fail "Не удалось установить Hysteria2"
        return 1
    fi

    H2_PORT=$(find_free_port udp 50001 65000)
    H2_PASS=$(openssl rand -base64 22 | tr -d '/+=' | head -c 24)
    H2_OBFS_PASS=$(openssl rand -base64 22 | tr -d '/+=' | head -c 24)

    log_step "Генерация самоподписанного TLS-сертификата..."
    mkdir -p "$H2_CERT_DIR"
    local cn_candidates=("mail.example.com" "cdn.example.net" "api.example.org")
    local cn_index=$(( RANDOM % ${#cn_candidates[@]} ))
    H2_CERT_CN="${cn_candidates[$cn_index]}"

    openssl req -x509 -newkey rsa:2048 \
        -keyout "$H2_CERT_DIR/server.key" \
        -out    "$H2_CERT_DIR/server.crt" \
        -days   3650 \
        -nodes \
        -subj   "/CN=${H2_CERT_CN}/O=Example/C=US" \
        >> "$LOG_FILE" 2>&1

    chmod 600 "$H2_CERT_DIR/server.key"
    chmod 644 "$H2_CERT_DIR/server.crt"

    cat > "$H2_CONFIG_DIR/config.yaml" <<EOF
listen: :${H2_PORT}
tls:
  cert: ${H2_CERT_DIR}/server.crt
  key:  ${H2_CERT_DIR}/server.key
auth:
  type: password
  password: ${H2_PASS}
obfs:
  type: salamander
  salamander:
    password: ${H2_OBFS_PASS}
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
EOF

    if ! id hysteria &>/dev/null; then
        useradd -r -s /sbin/nologin -d /etc/hysteria hysteria >> "$LOG_FILE" 2>&1
    fi

    chown -R hysteria:hysteria "$H2_CERT_DIR"
    chown hysteria:hysteria "$H2_CONFIG_DIR/config.yaml"

    cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
User=hysteria
Group=hysteria
ExecStart=/usr/local/bin/hysteria server -c ${H2_CONFIG_DIR}/config.yaml
Restart=always
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable hysteria-server >> "$LOG_FILE" 2>&1
    if systemctl start hysteria-server >> "$LOG_FILE" 2>&1; then
        log_ok "Сервис hysteria запущен"
    else
        log_fail "Не удалось запустить сервис hysteria-server"
        return 1
    fi

    ufw allow "$H2_PORT"/udp comment "Hysteria2" >> "$LOG_FILE" 2>&1
    local server_ip
    server_ip=$(get_server_ip)
    H2_URI="hysteria2://${H2_PASS}@${server_ip}:${H2_PORT}?obfs=salamander&obfs-password=${H2_OBFS_PASS}&insecure=1&sni=${H2_CERT_CN}"

    cat > "$STATE_DIR/hysteria2.env" <<EOF
H2_PORT=${H2_PORT}
H2_PASS=${H2_PASS}
H2_OBFS_PASS=${H2_OBFS_PASS}
H2_CERT_CN=${H2_CERT_CN}
H2_URI=${H2_URI}
H2_VERSION=$(hysteria version 2>/dev/null | head -n 1 || echo "unknown")
EOF
    chmod 600 "$STATE_DIR/hysteria2.env"

    mark_done "install_hysteria2"
    log_ok "Шаг 6 завершён."
}

# =============================================================================
# 7. setup_warp — Cloudflare WARP через wgcf
# =============================================================================
setup_warp() {
    log_section "7. Настройка Cloudflare WARP (wgcf)"

    if is_done "setup_warp"; then
        log_ok "Шаг уже выполнен, пропускаем."
        return 0
    fi

    # ── Установка wgcf ─────────────────────────────────────────────────────
    log_step "Установка wgcf..."
    local wgcf_url
    local wgcf_arch
    wgcf_arch=$(uname -m)
    case "$wgcf_arch" in
        x86_64)   wgcf_url="https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_amd64" ;;
        aarch64)  wgcf_url="https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_arm64" ;;
        *)
            log_fail "Неподдерживаемая архитектура для wgcf: $wgcf_arch"
            return 1
            ;;
    esac

    # Проверка скачивания wgcf с выводом ошибки
    if ! command -v wgcf &>/dev/null; then
        if curl -fsSL --max-time 60 -o /usr/local/bin/wgcf "$wgcf_url" >> "$LOG_FILE" 2>&1; then
            chmod +x /usr/local/bin/wgcf
            log_ok "wgcf установлен"
        else
            log_fail "Не удалось скачать wgcf с GitHub (таймаут соединения или репозиторий недоступен)."
            return 1
        fi
    else
        log_ok "wgcf уже установлен"
    fi

    # ── Регистрация WARP-аккаунта ──────────────────────────────────────────
    local warp_dir="/etc/wgcf"
    mkdir -p "$warp_dir"
    cd "$warp_dir"

    log_step "Регистрация нового WARP-аккаунта (wgcf register)..."
    if [[ ! -f "$warp_dir/wgcf-account.toml" ]]; then
        if wgcf register --accept-tos >> "$LOG_FILE" 2>&1; then
            log_ok "WARP аккаунт зарегистрирован"
        else
            log_fail "Регистрация WARP не удалась (Cloudflare API может быть недоступно/заблокировано)."
            return 1
        fi
    else
        log_ok "Аккаунт WARP уже зарегистрирован"
    fi

    # ── Генерация WireGuard-конфига ────────────────────────────────────────
    log_step "Генерация WireGuard-конфига (wgcf generate)..."
    if [[ ! -f "$warp_dir/wgcf-profile.conf" ]]; then
        if wgcf generate >> "$LOG_FILE" 2>&1; then
            log_ok "Профиль сгенерирован"
        else
            log_fail "Не удалось сгенерировать профиль WireGuard через wgcf"
            return 1
        fi
    else
        log_ok "WireGuard-профиль уже сгенерирован"
    fi

    # ── Адаптация профиля под отдельный интерфейс ─────────────────────────
    log_step "Адаптация wgcf-профиля (Split-Tunneling)..."
    local wg_conf_src="$warp_dir/wgcf-profile.conf"
    local wg_conf_dst="/etc/wireguard/wgcf-warp.conf"

    cp "$wg_conf_src" "$wg_conf_dst"
    sed -i 's|AllowedIPs = 0\.0\.0\.0/0|AllowedIPs = 0.0.0.0/1, 128.0.0.0/1|g' "$wg_conf_dst"
    sed -i 's|AllowedIPs = ::/0||g' "$wg_conf_dst"
    sed -i '/^PostUp/d'   "$wg_conf_dst"
    sed -i '/^PostDown/d' "$wg_conf_dst"

    # ── Поднятие WireGuard-интерфейса ─────────────────────────────────────
    log_step "Поднятие интерфейса wgcf-warp (wg-quick up)..."
    if wg show wgcf-warp &>/dev/null; then
        log_ok "wgcf-warp уже поднят"
    else
        # Пытаемся поднять интерфейс WireGuard
        if wg-quick up wgcf-warp >> "$LOG_FILE" 2>&1; then
            log_ok "wgcf-warp успешно поднят"
        else
            log_fail "Не удалось поднять wgcf-warp."
            log_info "ВОЗМОЖНАЯ ПРИЧИНА: у вас OpenVZ/LXC VPS, не поддерживающий модули ядра WireGuard."
            return 1
        fi
    fi

    systemctl enable "wg-quick@wgcf-warp" >> "$LOG_FILE" 2>&1 || true

    # ── Policy routing: только трафик Mieru и Hysteria2 через WARP ─────────
    log_step "Настройка сплит-маршрутизации (таблица 200, mark 0x1)..."

    if ! grep -q "^200 " /etc/iproute2/rt_tables; then
        echo "200 warp" >> /etc/iproute2/rt_tables
    fi

    local warp_iface="wgcf-warp"
    if ! ip route show table 200 2>/dev/null | grep -q "default"; then
        ip route add default dev "$warp_iface" table 200 2>/dev/null || true
    fi

    local mita_uid hysteria_uid
    mita_uid=$(id -u mita 2>/dev/null || echo "")
    hysteria_uid=$(id -u hysteria 2>/dev/null || echo "")

    setup_warp_routing_rules() {
        local uid="$1"
        local service="$2"
        if [[ -z "$uid" ]]; then return 0; fi
        if ! iptables -t mangle -C OUTPUT -m owner --uid-owner "$uid" -j MARK --set-mark 0x1 2>/dev/null; then
            iptables -t mangle -A OUTPUT -m owner --uid-owner "$uid" -j MARK --set-mark 0x1
        fi
    }

    setup_warp_routing_rules "$mita_uid"    "mita"
    setup_warp_routing_rules "$hysteria_uid" "hysteria"

    if ! ip rule show 2>/dev/null | grep -q "fwmark 0x1 lookup 200"; then
        ip rule add fwmark 0x1 table 200 priority 100
    fi

    # ── Персистентность правил ──────────────────────────────────────────────
    cat > /etc/network/if-up.d/warp-routing <<'ROUTING_SCRIPT'
#!/bin/bash
sleep 5
if ! grep -q "^200 " /etc/iproute2/rt_tables; then
    echo "200 warp" >> /etc/iproute2/rt_tables
fi
if ip link show wgcf-warp &>/dev/null; then
    ip route add default dev wgcf-warp table 200 2>/dev/null || true
fi
if ! ip rule show 2>/dev/null | grep -q "fwmark 0x1 lookup 200"; then
    ip rule add fwmark 0x1 table 200 priority 100 2>/dev/null || true
fi
for svc in mita hysteria; do
    uid=$(id -u "$svc" 2>/dev/null) || continue
    if ! iptables -t mangle -C OUTPUT -m owner --uid-owner "$uid" -j MARK --set-mark 0x1 2>/dev/null; then
        iptables -t mangle -A OUTPUT -m owner --uid-owner "$uid" -j MARK --set-mark 0x1 2>/dev/null || true
    fi
done
ROUTING_SCRIPT

    chmod +x /etc/network/if-up.d/warp-routing

    if command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    cat > /etc/systemd/system/warp-routing.service <<EOF
[Unit]
Description=WARP Policy Routing
After=network-online.target wg-quick@wgcf-warp.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/network/if-up.d/warp-routing

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable warp-routing >> "$LOG_FILE" 2>&1 || true

    mark_done "setup_warp"
    log_ok "Шаг 7 завершён."
}

# =============================================================================
# 8. print_summary — итоговый вывод строк подключения
# =============================================================================
print_summary() {
    log_section "8. Итоговая информация для подключения"

    if [[ -f "$STATE_DIR/mieru.env" ]]; then
        # shellcheck source=/dev/null
        source "$STATE_DIR/mieru.env"
    fi
    if [[ -f "$STATE_DIR/hysteria2.env" ]]; then
        # shellcheck source=/dev/null
        source "$STATE_DIR/hysteria2.env"
    fi

    local server_ip
    server_ip=$(get_server_ip)

    local warp_status="не активен"
    if wg show wgcf-warp &>/dev/null 2>&1; then
        warp_status="активен"
    fi

    cat > "$INFO_FILE" <<EOF
================================================================================
  VPN Server Setup — Информация для подключения
  Сервер IP: ${server_ip}
================================================================================

  [1] MIERU (mita)
  TCP порт:    ${MIERU_PORT:-НЕ ОПРЕДЕЛЁН}
  Пользователь: ${MIERU_USER:-НЕ ОПРЕДЕЛЁН}
  Пароль:      ${MIERU_PASS:-НЕ ОПРЕДЕЛЁН}

  Конфиг клиента Mieru JSON:
  {
    "profile": [
      {
        "profileName": "my-server",
        "user": { "name": "${MIERU_USER:-USER}", "password": "${MIERU_PASS:-PASS}" },
        "servers": [
          { "ipAddress": "${server_ip}", "portBindings": [ { "port": ${MIERU_PORT:-PORT}, "protocol": "TCP" } ] }
        ]
      }
    ],
    "rpcPort": 8964
  }

  [2] HYSTERIA2 (Salamander obfs + самоподписанный TLS)
  UDP порт:    ${H2_PORT:-НЕ ОПРЕДЕЛЁН}
  Пароль:      ${H2_PASS:-НЕ ОПРЕДЕЛЁН}
  OBFS пароль: ${H2_OBFS_PASS:-НЕ ОПРЕДЕЛЁН}
  TLS CN:      ${H2_CERT_CN:-НЕ ОПРЕДЕЛЁН}

  Ссылка для клиента:
  ${H2_URI:-не сгенерирована}

  [3] CLOUDFLARE WARP
  Статус:     ${warp_status}

================================================================================
EOF

    chmod 600 "$INFO_FILE"
    echo ""
    cat "$INFO_FILE"
    log_ok "Сведения сохранены в $INFO_FILE"
}

# =============================================================================
# MAIN — точка входа
# =============================================================================
main() {
    init_log
    log ""
    log "${BOLD}${CYAN}=== VPN Server Auto-Setup ===${NC}"
    check_root
    check_os

    update_system
    setup_firewall
    detect_system_specs
    tune_network
    install_mieru
    install_hysteria2
    setup_warp
    print_summary
}

main "$@"
