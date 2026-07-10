#!/usr/bin/env bash
# =============================================================================
# setup.sh — Автоматическая настройка VPS под личный VPN-сервер
# Совместимость: Ubuntu (все версии), Debian, Rocky Linux, CentOS, AlmaLinux
# Использование: bash setup.sh
#
# Компоненты: Mieru (mita), Hysteria2, Cloudflare WARP (wgcf)
# Лог: /var/log/vpn-setup.log
# =============================================================================

set -euo pipefail

# Цвета для вывода (до trap, чтобы cleanup_err мог их использовать)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# Обработчик ошибок для красивого вывода при аварийном выходе
cleanup_err() {
    local exit_code=$?
    local line_no=$1
    if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
        systemctl start unattended-upgrades 2>/dev/null || true
    fi
    if [[ "$exit_code" -ne 0 ]]; then
        printf "\n\n  ${RED}✗${NC}  Скрипт прервался на строке %s (код: %s)\n" "$line_no" "$exit_code"
    fi
}
trap 'cleanup_err $LINENO' EXIT

# ── Глобальные переменные ────────────────────────────────────────────────────
readonly LOG_FILE="/dev/null"
readonly STATE_DIR="/etc/vpn-setup-state"
readonly MIERU_CONFIG_DIR="/etc/mita"
readonly H2_CONFIG_DIR="/etc/hysteria"
readonly H2_CERT_DIR="/etc/hysteria/certs"
readonly INFO_FILE="/root/vpn-setup-info.txt"

# Рандомный путь для подписки (для безопасности — не угадать URL)
SUB_PATH="$(openssl rand -hex 16)"
CLASH_PATH="clash-$(openssl rand -hex 8).yaml"

SSH_PORT="${SSH_PORT:-22}"

# ── Прогресс-дисплей ────────────────────────────────────────────────────────

STEPS_TOTAL=10
STEP_INDEX=0
STEP_NAME=""
STEP_START_SEC=0
SETUP_START_SEC=0

_fmt_elapsed() {
    local secs=$(( $(date +%s) - $1 ))
    if [[ $secs -lt 60 ]]; then printf '%dс'   "$secs"
    else printf '%dм %dс' $(( secs / 60 )) $(( secs % 60 )); fi
}

step_begin() {
    STEP_INDEX=$(( STEP_INDEX + 1 ))
    STEP_NAME="$1"
    STEP_START_SEC=$(date +%s)
    printf "  ${CYAN}⧗${NC}  %-38s\r" "${STEP_NAME}..."
}

step_finish() {
    local t; t=$(_fmt_elapsed "$STEP_START_SEC")
    printf "  ${GREEN}✓${NC}  %-38s  ${GREEN}%s${NC}\n" "$STEP_NAME" "$t"
}

step_skip() {
    printf "  ${CYAN}✓${NC}  %-38s  ${CYAN}cached${NC}\n" "$STEP_NAME"
}

step_warn() {
    printf "  ${YELLOW}!${NC}  %-38s  ${YELLOW}%s${NC}\n" "$STEP_NAME" "${1:-пропущен}"
}

# =============================================================================
# Вспомогательные функции логирования и детекции ОС
# =============================================================================

init_log() {
    SETUP_START_SEC=$(date +%s)
    printf "\n  ${BOLD}${CYAN}VPN Server Auto-Setup${NC}\n"
    printf "  %s\n\n" "──────────────────────────────────────────────────────────"
}

log()         { :; }
log_section() { :; }
log_step()    { :; }
log_ok()      { :; }
log_info()    { :; }
log_fail()    {
    printf "\n\n  ${RED}✗${NC}  %s\n" "$1"
}

mark_done() {
    mkdir -p "$STATE_DIR"
    touch "$STATE_DIR/$1.done"
}

is_done() {
    [[ -f "$STATE_DIR/$1.done" ]]
}

wait_for_apt_locks() {
    log_step "Управление блокировками менеджера пакетов (apt/dpkg)..."
    
    # 1. Если активна служба автоматических фоновых обновлений Ubuntu, 
    # временно останавливаем её для мгновенной установки
    if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
        log_info "Фоновое обновление (unattended-upgrades) активно. Временно останавливаем его..."
        systemctl stop unattended-upgrades >> "$LOG_FILE" 2>&1 || true
    fi

    # 2. Ждем, если какие-то низкоуровневые процессы apt-get/dpkg/dnf/yum всё ещё завершают работу
    local i=0
    while pgrep -f "apt-get|dpkg|dnf|yum" >/dev/null 2>&1; do
        log_info "Процесс установки пакетов занят. Ожидаем завершения..."
        sleep 3
        i=$((i+3))
        if [[ "$i" -gt 60 ]]; then
            log_fail "Менеджер пакетов заблокирован сторонним процессом слишком долго. Пожалуйста, перезапустите скрипт позже."
            return 1
        fi
    done
    
    log_ok "Менеджер пакетов свободен."
    return 0
}

find_free_port() {
    local proto="${1:-tcp}"
    local range_min="${2:-20000}"
    local range_max="${3:-65000}"
    local port
    local attempts=0
    while true; do
        port=$(( RANDOM % (range_max - range_min + 1) + range_min ))
        if ! ss -"${proto}"ln 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return 0
        fi
        attempts=$((attempts + 1))
        if [[ $attempts -ge 100 ]]; then
            log_fail "Не удалось найти свободный порт в диапазоне ${range_min}-${range_max} за 100 попыток."
            return 1
        fi
    done
}

get_server_ip() {
    curl -s --max-time 5 https://api.ipify.org \
        || curl -s --max-time 5 https://ifconfig.me \
        || curl -s --max-time 5 https://icanhazip.com \
        || echo "UNKNOWN"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Ошибка: запустите скрипт от имени root (через sudo).${NC}"
        exit 1
    fi
}

# Определение дистрибутива и пакетного менеджера
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
        OS_LIKE=${ID_LIKE:-""}
    else
        OS_ID="unknown"
        OS_LIKE="unknown"
    fi

    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" || "$OS_LIKE" == *"debian"* || "$OS_LIKE" == *"ubuntu"* ]]; then
        PKG_MANAGER="apt"
    elif [[ "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" || "$OS_ID" == "centos" || "$OS_ID" == "fedora" || "$OS_LIKE" == *"rhel"* || "$OS_LIKE" == *"centos"* ]]; then
        PKG_MANAGER="dnf"
    else
        PKG_MANAGER="unknown"
    fi
    export PKG_MANAGER OS_ID
}

check_os() {
    detect_os
    if [[ "$PKG_MANAGER" == "unknown" ]]; then
        log_fail "Обнаружена неподдерживаемая ОС ($OS_ID). Рекомендуется Debian, Ubuntu или Rocky Linux."
        exit 1
    else
        log_ok "Поддерживаемая система: $OS_ID ($PKG_MANAGER)"
    fi
}

# =============================================================================
# Новая функция: Настройка DNS
# =============================================================================
setup_dns() {
    step_begin "DNS (настройка 1.1.1.1 / 8.8.8.8)"
    if is_done "setup_dns"; then
        step_skip; return 0
    fi

    log_step "Установка DNS-серверов Cloudflare и Google..."
    
    # 1. Если используется systemd-resolved
    if [ -f /etc/systemd/resolved.conf ]; then
        log_info "Настройка DNS через systemd-resolved..."
        cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak || true
        sed -i 's/^#\?DNS=.*/DNS=1.1.1.1 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888/' /etc/systemd/resolved.conf
        sed -i 's/^#\?FallbackDNS=.*/FallbackDNS=1.0.0.1 8.8.4.4/' /etc/systemd/resolved.conf
        systemctl restart systemd-resolved >> "$LOG_FILE" 2>&1 || true
        log_ok "systemd-resolved настроен и перезапущен"
    fi

    # 2. Традиционный /etc/resolv.conf
    log_info "Обновление /etc/resolv.conf..."
    chattr -i /etc/resolv.conf 2>/dev/null || true
    # На Ubuntu 22+/24+ /etc/resolv.conf является симлинком на systemd-resolved.
    # mv сломал бы симлинк, поэтому пишем напрямую в реальный файл назначения.
    local resolv_target="/etc/resolv.conf"
    if [ -L /etc/resolv.conf ]; then
        resolv_target=$(readlink -f /etc/resolv.conf)
        log_info "/etc/resolv.conf — симлинк, пишем в реальный путь: $resolv_target"
    fi
    cat > "$resolv_target" <<EOF
# Сгенерировано setup.sh
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 1.0.0.1
EOF
    log_ok "/etc/resolv.conf обновлен"

    mark_done "setup_dns"
    step_finish
}

# =============================================================================
# Новая функция: Синхронизация времени
# =============================================================================
sync_time() {
    step_begin "Синхронизация времени (UTC + chrony)"
    if is_done "sync_time"; then
        step_skip; return 0
    fi

    log_step "Установка часового пояса UTC..."
    timedatectl set-timezone UTC || true

    log_step "Включение NTP синхронизации..."
    if command -v timedatectl &>/dev/null; then
        timedatectl set-ntp true || true
    fi

    log_step "Установка chrony для стабильного удержания времени..."
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq chrony >> "$LOG_FILE" 2>&1 || true
    elif [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf install -y -q chrony >> "$LOG_FILE" 2>&1 || true
    fi

    # Перезапускаем chrony
    if systemctl restart chrony >> "$LOG_FILE" 2>&1 || systemctl restart chronyd >> "$LOG_FILE" 2>&1; then
        log_ok "Служба chrony перезапущена"
    else
        log_info "chrony не запустился, пытаемся вызвать разовую синхронизацию..."
        chronyd -q 'server pool.ntp.org iburst' >> "$LOG_FILE" 2>&1 || true
    fi

    log_info "Текущее время сервера: $(date)"
    mark_done "sync_time"
    step_finish
}

# =============================================================================
# 1. update_system
# =============================================================================
update_system() {
    step_begin "Обновление системы и пакетов"

    if is_done "update_system"; then
        step_skip; return 0
    fi

    if [[ "$PKG_MANAGER" == "apt" ]]; then
        wait_for_apt_locks
        log_step "Обновление списков пакетов (apt update)..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >> "$LOG_FILE" 2>&1 || true
        log_step "Установка базовых утилит (apt)..."
        local pkgs=(curl wget unzip jq ufw net-tools wireguard wireguard-tools iptables iproute2 openssl ethtool python3 build-essential)
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >> "$LOG_FILE" 2>&1
        log_ok "Базовые утилиты установлены"
    elif [[ "$PKG_MANAGER" == "dnf" ]]; then
        wait_for_apt_locks
        log_step "Настройка EPEL репозитория для RHEL..."
        dnf install -y -q epel-release >> "$LOG_FILE" 2>&1 || true
        log_step "Установка базовых утилит (dnf)..."
        local pkgs=(curl wget unzip jq ufw net-tools wireguard-tools iptables iproute openssl ethtool python3)
        dnf install -y -q "${pkgs[@]}" >> "$LOG_FILE" 2>&1
        log_ok "Базовые утилиты установлены"
    fi

    mark_done "update_system"
    step_finish
}

# =============================================================================
# 2. setup_firewall
# =============================================================================
setup_firewall() {
    step_begin "Брандмауэр (UFW)"

    if is_done "setup_firewall"; then
        step_skip; return 0
    fi

    log_step "Сброс ufw в начальное состояние..."
    ufw --force disable >> "$LOG_FILE" 2>&1 || true
    ufw --force reset >> "$LOG_FILE" 2>&1

    ufw default deny incoming >> "$LOG_FILE" 2>&1
    ufw default allow outgoing >> "$LOG_FILE" 2>&1
    ufw allow "$SSH_PORT"/tcp comment "SSH" >> "$LOG_FILE" 2>&1
    echo "y" | ufw enable >> "$LOG_FILE" 2>&1

    log_step "Блокировка ICMP ping..."
    local before_rules="/etc/ufw/before.rules"
    if [ -f "$before_rules" ] && ! grep -q "vpn-setup-icmp-block" "$before_rules"; then
        sed -i '/^# End required lines/a # vpn-setup-icmp-block\n-A ufw-before-input -p icmp --icmp-type echo-request -j DROP' "$before_rules" >> "$LOG_FILE" 2>&1
    fi
    ufw reload >> "$LOG_FILE" 2>&1

    mark_done "setup_firewall"
    step_finish
}

# =============================================================================
# 3. detect_system_specs
# =============================================================================
detect_system_specs() {
    step_begin "Характеристики сервера"

    RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    log_step "RAM: ${RAM_MB} МБ"
    CPU_CORES=$(nproc)
    log_step "CPU-ядра: ${CPU_CORES}"
    KERNEL_VERSION=$(uname -r)
    log_step "Ядро Linux: $KERNEL_VERSION"

    log_step "Проверка доступности TCP BBR..."
    BBR_AVAILABLE=0
    if modprobe tcp_bbr 2>/dev/null; then
        if lsmod | grep -q "^tcp_bbr"; then BBR_AVAILABLE=1; fi
    fi
    if [[ $BBR_AVAILABLE -eq 0 ]] && grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        BBR_AVAILABLE=1
    fi

    if [[ $BBR_AVAILABLE -eq 1 ]]; then
        log_ok "BBR доступен"
    else
        log_fail "BBR не поддерживается ядром"
    fi

    NET_IFACE=$(ip route | awk '/default/{print $5; exit}')
    LINK_SPEED_MBPS=0
    if [[ -n "$NET_IFACE" ]]; then
        LINK_SPEED_MBPS=$(ethtool "$NET_IFACE" 2>/dev/null | grep -i "Speed:" | grep -oE '[0-9]+' | head -1 || echo 0)
    fi

    # Вычисление буферов
    if [[ $RAM_MB -lt 1024 ]]; then
        RMEM_MAX=$((2 * 1024 * 1024))
        WMEM_MAX=$((2 * 1024 * 1024))
        TCP_RMEM="4096 87380 2097152"
        TCP_WMEM="4096 65536 2097152"
        NETDEV_MAX_BACKLOG=2000
        SOMAXCONN=512
        TCP_MAX_SYN_BACKLOG=512
        QUIC_STREAM_BUF=4194304
        QUIC_CONN_BUF=8388608
    elif [[ $RAM_MB -lt 4096 ]]; then
        RMEM_MAX=$((16 * 1024 * 1024))
        WMEM_MAX=$((16 * 1024 * 1024))
        TCP_RMEM="4096 131072 16777216"
        TCP_WMEM="4096 131072 16777216"
        NETDEV_MAX_BACKLOG=5000
        SOMAXCONN=1024
        TCP_MAX_SYN_BACKLOG=1024
        QUIC_STREAM_BUF=8388608
        QUIC_CONN_BUF=20971520
    else
        RMEM_MAX=$((32 * 1024 * 1024))
        WMEM_MAX=$((32 * 1024 * 1024))
        TCP_RMEM="4096 131072 33554432"
        TCP_WMEM="4096 131072 33554432"
        NETDEV_MAX_BACKLOG=5000
        SOMAXCONN=2048
        TCP_MAX_SYN_BACKLOG=2048
        QUIC_STREAM_BUF=16777216
        QUIC_CONN_BUF=41943040
    fi

    export BBR_AVAILABLE RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM NETDEV_MAX_BACKLOG SOMAXCONN TCP_MAX_SYN_BACKLOG NET_IFACE QUIC_STREAM_BUF QUIC_CONN_BUF
    step_finish
}

# =============================================================================
# 4. tune_network
# =============================================================================
tune_network() {
    step_begin "Параметры сети (sysctl + BBR + IPv6-off)"

    if is_done "tune_network"; then
        step_skip; return 0
    fi

    cat > /etc/sysctl.d/99-vpn-tuning.conf <<EOF
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
# Отключение IPv6 для предотвращения утечек
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    sysctl --system >> "$LOG_FILE" 2>&1 || true

    if ! iptables -C INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null; then
        iptables -I INPUT -p icmp --icmp-type echo-request -j DROP
    fi

    mark_done "tune_network"
    step_finish
}

# =============================================================================
# 5. install_mieru
# =============================================================================
install_mieru() {
    step_begin "Mieru (mita)"

    if is_done "install_mieru"; then
        step_skip
        if [[ -f "$STATE_DIR/mieru.env" ]]; then
            source "$STATE_DIR/mieru.env"
        fi
        return 0
    fi

    local arch
    arch=$(uname -m)
    local deb_arch rpm_arch
    case "$arch" in
        x86_64)   deb_arch="amd64"; rpm_arch="x86_64" ;;
        aarch64)  deb_arch="arm64"; rpm_arch="aarch64" ;;
        *)
            log_fail "Неподдерживаемая архитектура: $arch."
            return 1
            ;;
    esac

    local mita_version
    mita_version=$(curl -s --max-time 15 \
        "https://api.github.com/repos/enfein/mieru/releases/latest" \
        | grep '"tag_name"' \
        | sed 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/' || echo "")

    # Если API гитхаба вернуло ошибку или исчерпан лимит запросов, используем стабильную версию
    if [[ -z "$mita_version" || "$mita_version" == *"limit"* || "$mita_version" == *"message"* ]]; then
        mita_version="3.34.0"
        log_info "GitHub API недоступен или лимит исчерпан. Используем стабильную версию Mieru: ${mita_version}"
    fi

    local file_name download_url
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        file_name="mita_${mita_version}_${deb_arch}.deb"
        download_url="https://github.com/enfein/mieru/releases/download/v${mita_version}/${file_name}"
    else
        file_name="mita-${mita_version}-1.${rpm_arch}.rpm"
        download_url="https://github.com/enfein/mieru/releases/download/v${mita_version}/${file_name}"
    fi

    local tmp_file="/tmp/${file_name}"
    log_step "Скачивание $file_name..."
    curl -L --max-time 120 -o "$tmp_file" "$download_url" >> "$LOG_FILE" 2>&1

    # Проверяем размер скачанного файла. Если размер меньше 1 МБ, значит скачалась ошибка (например, 504 Gateway Timeout на Github)
    local file_size=0
    if [[ -f "$tmp_file" ]]; then
        file_size=$(stat -c%s "$tmp_file" 2>/dev/null || stat -f%z "$tmp_file" 2>/dev/null || echo 0)
    fi

    if [[ $file_size -lt 1000000 ]]; then
        log_info "Файл поврежден (размер ${file_size} байт). Откатываемся на стабильную версию 3.33.0..."
        rm -f "$tmp_file"
        mita_version="3.33.0"
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            file_name="mita_${mita_version}_${deb_arch}.deb"
            download_url="https://github.com/enfein/mieru/releases/download/v${mita_version}/${file_name}"
        else
            file_name="mita-${mita_version}-1.${rpm_arch}.rpm"
            download_url="https://github.com/enfein/mieru/releases/download/v${mita_version}/${file_name}"
        fi
        tmp_file="/tmp/${file_name}"
        log_step "Повторное скачивание $file_name..."
        if ! curl -L --max-time 120 -o "$tmp_file" "$download_url" >> "$LOG_FILE" 2>&1; then
            log_fail "Не удалось скачать mita даже после отката на 3.33.0"
            return 1
        fi
        # Проверим повторно размер
        file_size=$(stat -c%s "$tmp_file" 2>/dev/null || stat -f%z "$tmp_file" 2>/dev/null || echo 0)
        if [[ $file_size -lt 1000000 ]]; then
            log_fail "Размер файла версии 3.33.0 также неверный: ${file_size} байт."
            return 1
        fi
        log_ok "Скачана версия 3.33.0"
    else
        log_ok "Скачано"
    fi

    log_step "Установка пакета mita..."
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        dpkg -i "$tmp_file" >> "$LOG_FILE" 2>&1
    else
        rpm -Uvh --force "$tmp_file" >> "$LOG_FILE" 2>&1
    fi
    rm -f "$tmp_file"

    MIERU_PORT=$(find_free_port tcp 20000 50000)
    MIERU_UDP_PORT=$(find_free_port udp 20000 50000)
    MIERU_USER="user_$(openssl rand -hex 4)"
    MIERU_PASS=$(openssl rand -base64 22 | tr -d '/+=' | head -c 24)

    local mita_config_file="/tmp/mita_server_config.json"
    cat > "$mita_config_file" <<EOF
{
    "portBindings": [
        {
            "port": ${MIERU_PORT},
            "protocol": "TCP"
        },
        {
            "port": ${MIERU_UDP_PORT},
            "protocol": "UDP"
        }
    ],
    "users": [
        {
            "name": "${MIERU_USER}",
            "password": "${MIERU_PASS}"
        }
    ],
    "loggingLevel": "WARN",
    "mtu": 1400
}
EOF

    systemctl enable mita >> "$LOG_FILE" 2>&1 || true
    systemctl restart mita >> "$LOG_FILE" 2>&1 || systemctl start mita >> "$LOG_FILE" 2>&1 || true
    sleep 2

    mita apply config "$mita_config_file" >> "$LOG_FILE" 2>&1
    rm -f "$mita_config_file"

    systemctl restart mita >> "$LOG_FILE" 2>&1 || true
    ufw allow "$MIERU_PORT"/tcp comment "Mieru TCP" >> "$LOG_FILE" 2>&1
    ufw allow "$MIERU_UDP_PORT"/udp comment "Mieru UDP" >> "$LOG_FILE" 2>&1

    mkdir -p "$STATE_DIR"
    local server_ip
    server_ip=$(get_server_ip)
    local mieru_uri="mieru://${server_ip}:${MIERU_PORT}?username=${MIERU_USER}&password=${MIERU_PASS}&network=udp#Mieru-Proxy"

    cat > "$STATE_DIR/mieru.env" <<EOF
MIERU_PORT="${MIERU_PORT}"
MIERU_UDP_PORT="${MIERU_UDP_PORT}"
MIERU_USER="${MIERU_USER}"
MIERU_PASS="${MIERU_PASS}"
MIERU_URI="${mieru_uri}"
MIERU_VERSION="${mita_version}"
EOF
    chmod 600 "$STATE_DIR/mieru.env"

    mark_done "install_mieru"
    step_finish
}

# =============================================================================
# 6. install_hysteria2
# =============================================================================
install_hysteria2() {
    step_begin "Hysteria2"

    if is_done "install_hysteria2"; then
        step_skip
        if [[ -f "$STATE_DIR/hysteria2.env" ]]; then
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

    mkdir -p "$H2_CERT_DIR"
    local cn_candidates=(
        "cdn.cloudflare.com"
        "dl.google.com"
        "www.microsoft.com"
        "apps.apple.com"
        "d1.awsstatic.com"
    )
    local cn_index=$(( RANDOM % ${#cn_candidates[@]} ))
    H2_CERT_CN="${cn_candidates[$cn_index]}"

    # ECDSA вместо RSA — быстрее handshake, меньше CPU
    openssl ecparam -genkey -name prime256v1 \
        -out "$H2_CERT_DIR/server.key" 2>/dev/null
    openssl req -new -x509 \
        -key "$H2_CERT_DIR/server.key" \
        -out "$H2_CERT_DIR/server.crt" \
        -days 3650 \
        -nodes \
        -subj "/CN=${H2_CERT_CN}/O=Example/C=US" \
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
  initStreamReceiveWindow: ${QUIC_STREAM_BUF}
  maxStreamReceiveWindow: ${QUIC_STREAM_BUF}
  initConnReceiveWindow: ${QUIC_CONN_BUF}
  maxConnReceiveWindow: ${QUIC_CONN_BUF}
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
EOF

    if ! id hysteria &>/dev/null; then
        useradd -r -s /sbin/nologin -d /etc/hysteria hysteria >> "$LOG_FILE" 2>&1 || true
    fi

    chown -R hysteria:hysteria "$H2_CERT_DIR" || true
    chown hysteria:hysteria "$H2_CONFIG_DIR/config.yaml" || true

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
    systemctl enable hysteria-server >> "$LOG_FILE" 2>&1 || true
    if systemctl restart hysteria-server >> "$LOG_FILE" 2>&1 || systemctl start hysteria-server >> "$LOG_FILE" 2>&1; then
        log_ok "Сервис hysteria запущен"
    else
        log_fail "Не удалось запустить hysteria-server"
        return 1
    fi

    ufw allow "$H2_PORT"/udp comment "Hysteria2" >> "$LOG_FILE" 2>&1
    local server_ip
    server_ip=$(get_server_ip)

    local cert_sha256_hex="" cert_sha256_b64=""
    if [[ -f "$H2_CERT_DIR/server.crt" ]]; then
        # Получаем отпечаток SHA-256 в hex-формате (для Clash fingerprint)
        cert_sha256_hex=$(openssl x509 -in "$H2_CERT_DIR/server.crt" -noout -fingerprint -sha256 \
            | cut -d'=' -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
        # Конвертируем hex → base64: sing-box и Hysteria2 URI требуют base64-формат
        cert_sha256_b64=$(echo "$cert_sha256_hex" | python3 -c "
import sys, binascii, base64
h = sys.stdin.read().strip()
print(base64.b64encode(binascii.unhexlify(h)).decode())
" 2>/dev/null || echo "$cert_sha256_hex")
    fi

    H2_URI="hysteria2://${H2_PASS}@${server_ip}:${H2_PORT}?obfs=salamander&obfs-password=${H2_OBFS_PASS}&pinSHA256=${cert_sha256_b64}&sni=${H2_CERT_CN}"

    cat > "$STATE_DIR/hysteria2.env" <<EOF
H2_PORT="${H2_PORT}"
H2_PASS="${H2_PASS}"
H2_OBFS_PASS="${H2_OBFS_PASS}"
H2_CERT_CN="${H2_CERT_CN}"
H2_CERT_PIN="${cert_sha256_b64}"
H2_CERT_PIN_HEX="${cert_sha256_hex}"
H2_URI="${H2_URI}"
H2_VERSION="$(hysteria version 2>/dev/null | head -n 1 || echo "unknown")"
EOF
    chmod 600 "$STATE_DIR/hysteria2.env"

    mark_done "install_hysteria2"
    step_finish
}

# =============================================================================
# 7. setup_warp
# =============================================================================
setup_warp() {
    step_begin "Cloudflare WARP"

    if is_done "setup_warp"; then
        step_skip; return 0
    fi

    # Загружаем порты из файлов состояния, если они есть
    if [[ -f "$STATE_DIR/mieru.env" ]]; then
        source "$STATE_DIR/mieru.env"
    fi
    if [[ -f "$STATE_DIR/hysteria2.env" ]]; then
        source "$STATE_DIR/hysteria2.env"
    fi

    log_step "Установка wgcf..."
    local wgcf_arch
    wgcf_arch=$(uname -m)
    local deb_arch
    case "$wgcf_arch" in
        x86_64)   deb_arch="amd64" ;;
        aarch64)  deb_arch="arm64" ;;
        *)
            log_fail "Неподдерживаемая архитектура для wgcf: $wgcf_arch"
            step_warn "не поддерживается на $wgcf_arch"
            return 0
            ;;
    esac

    local wgcf_version
    wgcf_version=$(curl -s --max-time 15 \
        "https://api.github.com/repos/ViRb3/wgcf/releases/latest" \
        | grep '"tag_name"' \
        | sed 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/')

    if [[ -z "$wgcf_version" ]]; then
        wgcf_version="2.2.31"
    fi

    local wgcf_url="https://github.com/ViRb3/wgcf/releases/download/v${wgcf_version}/wgcf_${wgcf_version}_linux_${deb_arch}"

    if ! command -v wgcf &>/dev/null; then
        if curl -L -fsSL --max-time 60 -o /usr/local/bin/wgcf "$wgcf_url" >> "$LOG_FILE" 2>&1; then
            chmod +x /usr/local/bin/wgcf
            log_ok "wgcf установлен"
        else
            log_fail "Не удалось скачать wgcf с GitHub (таймаут соединения)."
            log_info "Ссылка: $wgcf_url"
            log_info "Пропуск настройки WARP. VPN будет работать напрямую без WARP."
            step_warn "недоступен GitHub"
            return 0
        fi
    else
        log_ok "wgcf уже установлен"
    fi

    local warp_dir="/etc/wgcf"
    mkdir -p "$warp_dir"
    pushd "$warp_dir" >/dev/null

    log_step "Регистрация нового WARP-аккаунта..."
    if [[ ! -f "$warp_dir/wgcf-account.toml" ]]; then
        if wgcf register --accept-tos >> "$LOG_FILE" 2>&1; then
            log_ok "WARP зарегистрирован"
        else
            log_fail "Регистрация WARP не удалась (Cloudflare API заблокировано или перегружено)."
            log_info "Пропуск настройки WARP. VPN будет работать напрямую без WARP."
            step_warn "Cloudflare API недоступен"
            return 0
        fi
    else
        log_ok "WARP уже зарегистрирован"
    fi

    log_step "Генерация WireGuard-конфига..."
    if [[ ! -f "$warp_dir/wgcf-profile.conf" ]]; then
        if wgcf generate >> "$LOG_FILE" 2>&1; then
            log_ok "Профиль сгенерирован"
        else
            log_fail "Не удалось сгенерировать wgcf профиль."
            log_info "Пропуск настройки WARP. VPN будет работать напрямую без WARP."
            step_warn "ошибка генерации профиля"
            return 0
        fi
    else
        log_ok "Профиль уже сгенерирован"
    fi

    log_step "Адаптация wgcf-профиля (Split-Tunneling)..."
    local wg_conf_src="$warp_dir/wgcf-profile.conf"
    local wg_conf_dst="/etc/wireguard/wgcf-warp.conf"
    cp "$wg_conf_src" "$wg_conf_dst"
    sed -i '/^DNS =/d' "$wg_conf_dst"
    sed -i '/^\[Interface\]/a Table = off' "$wg_conf_dst"
    # Удаляем IPv6-адрес из Address, чтобы wg-quick не упал при отключенном IPv6
    sed -i -E 's/Address\s*=\s*([^,]+),\s*[a-fA-F0-9:]+\/[0-9]+/Address = \1/g' "$wg_conf_dst"
    sed -i 's|AllowedIPs = 0\.0\.0\.0/0|AllowedIPs = 0.0.0.0/1, 128.0.0.0/1|g' "$wg_conf_dst"
    sed -i 's|AllowedIPs = ::/0||g' "$wg_conf_dst"
    sed -i '/^PostUp/d'   "$wg_conf_dst"
    sed -i '/^PostDown/d' "$wg_conf_dst"

    log_step "Поднятие интерфейса wgcf-warp (wg-quick up)..."
    if wg show wgcf-warp &>/dev/null; then
        log_ok "wgcf-warp уже работает"
    else
        if wg-quick up wgcf-warp >> "$LOG_FILE" 2>&1; then
            log_ok "wgcf-warp поднят"
        else
            log_fail "Не удалось поднять wgcf-warp. Возможна LXC/OpenVZ виртуализация без поддержки WireGuard."
            log_info "Пропуск настройки WARP. VPN будет работать напрямую без WARP."
            step_warn "WireGuard не поддерживается"
            return 0
        fi
    fi

    systemctl enable "wg-quick@wgcf-warp" >> "$LOG_FILE" 2>&1 || true

    log_step "Настройка сплит-маршрутизации (таблица 200, mark 0x1)..."
    mkdir -p /etc/iproute2
    if [ ! -f /etc/iproute2/rt_tables ]; then
        cat > /etc/iproute2/rt_tables <<EOF
# reserved values
255	local
254	main
253	default
0	unspec
EOF
    fi

    if ! grep -q "^200 " /etc/iproute2/rt_tables; then
        echo "200 warp" >> /etc/iproute2/rt_tables
    fi

    if ! ip route show table 200 2>/dev/null | grep -q "default"; then
        ip route add default dev wgcf-warp table 200 2>/dev/null || true
    fi

    # Получаем endpoint IP для исключения из петли маршрутизации
    local endpoint_ip=""
    if [[ -f "/etc/wireguard/wgcf-warp.conf" ]]; then
        endpoint_ip=$(grep -i "^Endpoint" /etc/wireguard/wgcf-warp.conf | awk -F'=' '{print $2}' | tr -d ' ' | cut -d':' -f1 | tr -d '[]')
    fi

    local mita_uid hysteria_uid
    mita_uid=$(id -u mita 2>/dev/null || echo "")
    hysteria_uid=$(id -u hysteria 2>/dev/null || echo "")

    # Очищаем старые правила, если они были, чтобы избежать дублирования
    iptables -t mangle -D OUTPUT -o lo -j RETURN 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p udp --dport 53 -j RETURN 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p tcp --dport 53 -j RETURN 2>/dev/null || true
    if [[ -n "$MIERU_PORT" ]]; then
        iptables -t mangle -D OUTPUT -p tcp --sport "$MIERU_PORT" -j RETURN 2>/dev/null || true
    fi
    if [[ -n "${MIERU_UDP_PORT:-}" ]]; then
        iptables -t mangle -D OUTPUT -p udp --sport "$MIERU_UDP_PORT" -j RETURN 2>/dev/null || true
    fi
    if [[ -n "$H2_PORT" ]]; then
        iptables -t mangle -D OUTPUT -p udp --sport "$H2_PORT" -j RETURN 2>/dev/null || true
    fi
    if [[ -n "$endpoint_ip" ]]; then
        if [[ "$endpoint_ip" =~ : ]]; then
            ip6tables -t mangle -D OUTPUT -d "$endpoint_ip" -j RETURN 2>/dev/null || true
        else
            iptables -t mangle -D OUTPUT -d "$endpoint_ip" -j RETURN 2>/dev/null || true
        fi
    fi
    if [[ -n "$mita_uid" ]]; then
        iptables -t mangle -D OUTPUT -m owner --uid-owner "$mita_uid" -j MARK --set-mark 0x1 2>/dev/null || true
    fi
    if [[ -n "$hysteria_uid" ]]; then
        iptables -t mangle -D OUTPUT -m owner --uid-owner "$hysteria_uid" -j MARK --set-mark 0x1 2>/dev/null || true
    fi

    # Накатываем новые правила
    iptables -t mangle -A OUTPUT -o lo -j RETURN
    iptables -t mangle -A OUTPUT -p udp --dport 53 -j RETURN
    iptables -t mangle -A OUTPUT -p tcp --dport 53 -j RETURN
    if [[ -n "$MIERU_PORT" ]]; then
        iptables -t mangle -A OUTPUT -p tcp --sport "$MIERU_PORT" -j RETURN
    fi
    if [[ -n "${MIERU_UDP_PORT:-}" ]]; then
        iptables -t mangle -A OUTPUT -p udp --sport "$MIERU_UDP_PORT" -j RETURN
    fi
    if [[ -n "$H2_PORT" ]]; then
        iptables -t mangle -A OUTPUT -p udp --sport "$H2_PORT" -j RETURN
    fi
    if [[ -n "$endpoint_ip" ]]; then
        if [[ "$endpoint_ip" =~ : ]]; then
            ip6tables -t mangle -A OUTPUT -d "$endpoint_ip" -j RETURN 2>/dev/null || true
        else
            iptables -t mangle -A OUTPUT -d "$endpoint_ip" -j RETURN
        fi
    fi
    if [[ -n "$mita_uid" ]]; then
        iptables -t mangle -A OUTPUT -m owner --uid-owner "$mita_uid" -j MARK --set-mark 0x1
    fi
    if [[ -n "$hysteria_uid" ]]; then
        iptables -t mangle -A OUTPUT -m owner --uid-owner "$hysteria_uid" -j MARK --set-mark 0x1
    fi

    ip rule add fwmark 0x1 table 200 priority 100 2>/dev/null || true

    # Включаем маскарадинг в NAT
    iptables -t nat -D POSTROUTING -o wgcf-warp -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o wgcf-warp -j MASQUERADE

    cat > /etc/network/if-up.d/warp-routing <<'ROUTING_SCRIPT'
#!/bin/bash
sleep 5
STATE_DIR="/etc/vpn-setup-state"
[ -f "$STATE_DIR/mieru.env" ] && source "$STATE_DIR/mieru.env"
[ -f "$STATE_DIR/hysteria2.env" ] && source "$STATE_DIR/hysteria2.env"

mkdir -p /etc/iproute2
if [ ! -f /etc/iproute2/rt_tables ]; then
    cat > /etc/iproute2/rt_tables <<EOF
255	local
254	main
253	default
0	unspec
EOF
fi
if ! grep -q "^200 " /etc/iproute2/rt_tables; then
    echo "200 warp" >> /etc/iproute2/rt_tables
fi
if ip link show wgcf-warp &>/dev/null; then
    ip route add default dev wgcf-warp table 200 2>/dev/null || true
fi
if ! ip rule show 2>/dev/null | grep -q "fwmark 0x1 lookup 200"; then
    ip rule add fwmark 0x1 table 200 priority 100 2>/dev/null || true
fi

endpoint_ip=""
if [ -f "/etc/wireguard/wgcf-warp.conf" ]; then
    endpoint_ip=$(grep -i "^Endpoint" /etc/wireguard/wgcf-warp.conf | awk -F'=' '{print $2}' | tr -d ' ' | cut -d':' -f1 | tr -d '[]')
fi

iptables -t mangle -F OUTPUT 2>/dev/null || true
ip6tables -t mangle -F OUTPUT 2>/dev/null || true

iptables -t mangle -A OUTPUT -o lo -j RETURN
iptables -t mangle -A OUTPUT -p udp --dport 53 -j RETURN
iptables -t mangle -A OUTPUT -p tcp --dport 53 -j RETURN

if [ -n "$H2_PORT" ]; then
    iptables -t mangle -A OUTPUT -p udp --sport "$H2_PORT" -j RETURN
fi
if [ -n "$MIERU_PORT" ]; then
    iptables -t mangle -A OUTPUT -p tcp --sport "$MIERU_PORT" -j RETURN
fi
if [ -n "${MIERU_UDP_PORT:-}" ]; then
    iptables -t mangle -A OUTPUT -p udp --sport "$MIERU_UDP_PORT" -j RETURN
fi
if [ -n "$endpoint_ip" ]; then
    if [[ "$endpoint_ip" =~ : ]]; then
        ip6tables -t mangle -A OUTPUT -d "$endpoint_ip" -j RETURN 2>/dev/null || true
    else
        iptables -t mangle -A OUTPUT -d "$endpoint_ip" -j RETURN 2>/dev/null || true
    fi
fi

mita_uid=$(id -u mita 2>/dev/null)
if [ -n "$mita_uid" ]; then
    iptables -t mangle -A OUTPUT -m owner --uid-owner "$mita_uid" -j MARK --set-mark 0x1
fi
hysteria_uid=$(id -u hysteria 2>/dev/null)
if [ -n "$hysteria_uid" ]; then
    iptables -t mangle -A OUTPUT -m owner --uid-owner "$hysteria_uid" -j MARK --set-mark 0x1
fi

iptables -t nat -D POSTROUTING -o wgcf-warp -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -o wgcf-warp -j MASQUERADE
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
Requires=wg-quick@wgcf-warp.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/network/if-up.d/warp-routing

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable warp-routing >> "$LOG_FILE" 2>&1 || true
    systemctl start warp-routing >> "$LOG_FILE" 2>&1 || true

    popd >/dev/null

    mark_done "setup_warp"
    step_finish
}

# =============================================================================
# 7.5. setup_subscription_server
# =============================================================================
setup_subscription_server() {
    step_begin "Сервер подписок (:8080)"

    if is_done "setup_sub_server"; then
        step_skip; return 0
    fi

    if [[ -f "$STATE_DIR/subscription_path" ]]; then
        source "$STATE_DIR/subscription_path"
    fi
    mkdir -p "$STATE_DIR"
    echo "SUB_PATH=\"${SUB_PATH}\"" > "$STATE_DIR/subscription_path"
    echo "CLASH_PATH=\"${CLASH_PATH}\"" >> "$STATE_DIR/subscription_path"
    chmod 600 "$STATE_DIR/subscription_path"

    mkdir -p /var/www/html

    if ! id vpnsub &>/dev/null; then
        useradd -r -s /sbin/nologin -d /var/www/html vpnsub >> "$LOG_FILE" 2>&1 || true
    fi
    chown vpnsub:vpnsub /var/www/html || true
    chmod 755 /var/www/html || true

    cat > /etc/systemd/system/vpn-sub.service <<EOF
[Unit]
Description=VPN Subscription Web Server
After=network.target

[Service]
Type=simple
User=vpnsub
WorkingDirectory=/var/www/html
ExecStart=/usr/bin/python3 -m http.server 8080
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
    systemctl enable vpn-sub >> "$LOG_FILE" 2>&1 || true
    systemctl restart vpn-sub >> "$LOG_FILE" 2>&1 || true

    ufw allow 8080/tcp comment "VPN subscription port" >> "$LOG_FILE" 2>&1

    mark_done "setup_sub_server"
    step_finish
}

# =============================================================================
# 8. print_summary
# =============================================================================
print_summary() {
    log_section "8. Итоговая информация для подключения"

    if [[ -f "$STATE_DIR/mieru.env" ]]; then source "$STATE_DIR/mieru.env"; fi
    if [[ -f "$STATE_DIR/hysteria2.env" ]]; then source "$STATE_DIR/hysteria2.env"; fi
    if [[ -f "$STATE_DIR/subscription_path" ]]; then source "$STATE_DIR/subscription_path"; fi

    local server_ip
    server_ip=$(get_server_ip)

    local warp_status="не активен"
    if wg show wgcf-warp &>/dev/null 2>&1; then warp_status="активен"; fi

    # Генерация Base64-подписки
    local sub_content=""
    [[ -n "${H2_URI:-}" ]]    && sub_content+="${H2_URI}"$'\n'
    [[ -n "${MIERU_URI:-}" ]] && sub_content+="${MIERU_URI}"$'\n'
    local sub_base64
    sub_base64=$(echo -n "$sub_content" | base64 | tr -d '\r\n')

    # Сохраняем подписки на диске
    echo -n "$sub_base64" > /root/vpn-setup-sub.txt
    chmod 600 /root/vpn-setup-sub.txt

    mkdir -p /var/www/html
    echo -n "$sub_base64" > "/var/www/html/${SUB_PATH}"
    chmod 644 "/var/www/html/${SUB_PATH}"

    # singbox.json
    cat > /var/www/html/singbox.json <<JSON
{
  "outbounds": [
    {
      "type": "selector",
      "tag": "PROXY",
      "outbounds": ["Hysteria2-Proxy", "Mieru-Proxy", "direct"]
    },
    {
      "type": "hysteria2",
      "tag": "Hysteria2-Proxy",
      "server": "${server_ip}",
      "server_port": ${H2_PORT:-443},
      "password": "${H2_PASS:-}",
      "obfs": { "type": "salamander", "password": "${H2_OBFS_PASS:-}" },
      "tls": {
        "enabled": true,
        "server_name": "${H2_CERT_CN:-mail.example.com}",
        "insecure": false,
        "pinned_peer_cert_sha256": ["${H2_CERT_PIN_HEX:-}"]
      }
    },
    {
      "type": "mieru",
      "tag": "Mieru-Proxy",
      "server": "${server_ip}",
      "server_port": ${MIERU_PORT:-443},
      "username": "${MIERU_USER:-}",
      "password": "${MIERU_PASS:-}",
      "transport": "TCP"
    },
    { "type": "direct", "tag": "direct" }
  ]
}
JSON
    chmod 644 /var/www/html/singbox.json

    # clash.yaml
    cat > "/var/www/html/${CLASH_PATH}" <<EOF
mixed-port: 7892
allow-lan: false
mode: rule
log-level: warning
ipv6: false
find-process-mode: strict

# DNS
dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "*.localhost"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
    - "*.srv"
    - "*.msedge.net"
    - "stun.*.*"
    - "stun.*.*.*"
    - "+.stun.*.*"
    - "+.stun.*.*.*"
    - "+.stun.*.*.*.*"
    - "+.stun.*.*.*.*.*"
  default-nameserver:
    - 1.1.1.1
    - 8.8.8.8
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
  fallback:
    - https://1.1.1.1/dns-query
    - https://dns.google/dns-query
  fallback-filter:
    geoip: true
    geoip-code: RU
    ipcidr:
      - 240.0.0.0/4

proxies:
  - name: Hysteria2
    type: hysteria2
    server: ${server_ip}
    port: ${H2_PORT:-443}
    password: ${H2_PASS:-}
    obfs: salamander
    obfs-password: ${H2_OBFS_PASS:-}
    sni: ${H2_CERT_CN:-mail.example.com}
    fingerprint: ${H2_CERT_PIN_HEX:-}
    skip-cert-verify: false

  - name: Mieru
    type: mieru
    server: ${server_ip}
    port: ${MIERU_PORT:-443}
    username: ${MIERU_USER:-}
    password: ${MIERU_PASS:-}
    transport: UDP

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Auto
      - Hysteria2
      - Mieru
      - DIRECT

  - name: Auto
    type: url-test
    proxies:
      - Hysteria2
      - Mieru
    url: http://cp.cloudflare.com/generate_204
    interval: 300
    tolerance: 50

rules:
  # Локальные и служебные
  - GEOIP,private,DIRECT,no-resolve
  - DOMAIN-SUFFIX,local,DIRECT
  - DOMAIN-SUFFIX,localhost,DIRECT
  - DOMAIN-KEYWORD,localhost,DIRECT

  # Россия, Беларусь, Казахстан — напрямую
  - GEOIP,RU,DIRECT
  - GEOIP,BY,DIRECT
  - GEOIP,KZ,DIRECT

  # Популярные российские сервисы — напрямую
  - DOMAIN-SUFFIX,yandex.ru,DIRECT
  - DOMAIN-SUFFIX,yandex.com,DIRECT
  - DOMAIN-SUFFIX,ya.ru,DIRECT
  - DOMAIN-SUFFIX,yandex.net,DIRECT
  - DOMAIN-SUFFIX,yandex.ua,DIRECT
  - DOMAIN-SUFFIX,yandex.by,DIRECT
  - DOMAIN-SUFFIX,yandex.kz,DIRECT
  - DOMAIN-SUFFIX,yandex.cloud,DIRECT
  - DOMAIN-SUFFIX,yastatic.net,DIRECT
  - DOMAIN-SUFFIX,yacd.org,DIRECT
  - DOMAIN-SUFFIX,mail.ru,DIRECT
  - DOMAIN-SUFFIX,mailagent.ru,DIRECT
  - DOMAIN-SUFFIX,vk.com,DIRECT
  - DOMAIN-SUFFIX,vk.ru,DIRECT
  - DOMAIN-SUFFIX,mc.vk.com,DIRECT
  - DOMAIN-SUFFIX,ok.ru,DIRECT
  - DOMAIN-SUFFIX,odnoklassniki.ru,DIRECT
  - DOMAIN-SUFFIX,max.ru,DIRECT
  - DOMAIN-SUFFIX,max.com,DIRECT
  - DOMAIN-SUFFIX,icq.com,DIRECT
  - DOMAIN-SUFFIX,icq.ru,DIRECT
  - DOMAIN-SUFFIX,tamtam.ru,DIRECT
  - DOMAIN-SUFFIX,rt.ru,DIRECT
  - DOMAIN-SUFFIX,sberbank.ru,DIRECT
  - DOMAIN-SUFFIX,sber.ru,DIRECT
  - DOMAIN-SUFFIX,tinkoff.ru,DIRECT
  - DOMAIN-SUFFIX,tbank.ru,DIRECT
  - DOMAIN-SUFFIX,gosuslugi.ru,DIRECT
  - DOMAIN-SUFFIX,gov.ru,DIRECT
  - DOMAIN-SUFFIX,mos.ru,DIRECT
  - DOMAIN-SUFFIX,mts.ru,DIRECT
  - DOMAIN-SUFFIX,beeline.ru,DIRECT
  - DOMAIN-SUFFIX,megafon.ru,DIRECT
  - DOMAIN-SUFFIX,tele2.ru,DIRECT
  - DOMAIN-SUFFIX,rutube.ru,DIRECT
  - DOMAIN-SUFFIX,kinopoisk.ru,DIRECT
  - DOMAIN-SUFFIX,dzen.ru,DIRECT
  - DOMAIN-SUFFIX,auto.ru,DIRECT
  - DOMAIN-SUFFIX,avito.ru,DIRECT
  - DOMAIN-SUFFIX,ozon.ru,DIRECT
  - DOMAIN-SUFFIX,wildberries.ru,DIRECT
  - DOMAIN-SUFFIX,li.ru,DIRECT
  - DOMAIN-SUFFIX,song.link,DIRECT
  - DOMAIN-SUFFIX,sbercloud.ru,DIRECT
  - DOMAIN-SUFFIX,selectel.ru,DIRECT
  - DOMAIN-SUFFIX,time1.ru,DIRECT
  - DOMAIN-SUFFIX,moscowtime.ru,DIRECT
  - DOMAIN-SUFFIX,gtlingua.ru,DIRECT
  - DOMAIN-SUFFIX,sportmaster.ru,DIRECT

  # Прокси для всего остального
  - MATCH,Proxy
EOF
    chmod 644 "/var/www/html/${CLASH_PATH}"

    # Полный файл с креденциалами (для домашнего хранения)
    cat > "$INFO_FILE" <<EOF
================================================================================
  VPN Server Setup — полные креденциалы
  IP: ${server_ip}   |   WARP: ${warp_status}
================================================================================

  MIERU  |  порт: ${MIERU_PORT:-?}  |  пользователь: ${MIERU_USER:-?}  |  пароль: ${MIERU_PASS:-?}
  URI:   ${MIERU_URI:-не сгенерирована}

  HYSTERIA2  |  порт: ${H2_PORT:-?}  |  пароль: ${H2_PASS:-?}
  OBFS пароль: ${H2_OBFS_PASS:-?}  |  TLS CN: ${H2_CERT_CN:-?}
  URI:   ${H2_URI:-не сгенерирована}

  MIERU JSON конфиг:
  {"profile":[{"profileName":"my-server","user":{"name":"${MIERU_USER:-?}","password":"${MIERU_PASS:-?}"},"servers":[{"ipAddress":"${server_ip}","portBindings":[{"port":${MIERU_PORT:-0},"protocol":"TCP"}]}]}],"rpcPort":8964}

================================================================================
EOF
    chmod 600 "$INFO_FILE"

    # ──────────────────────────────────────────────────────────
    # Чистый вывод в терминал: только ссылки
    # ──────────────────────────────────────────────────────────
    local t; t=$(_fmt_elapsed "$SETUP_START_SEC")

    printf "\n  ${GREEN}✔${NC}  Настройка завершена за %s\n" "$t"
    printf "  %s\n" "──────────────────────────────────────────────────────────"
    printf "\n  ${BOLD}Ссылки для подключения:${NC}\n\n"

    printf "  ${CYAN}Karing / Sing-box:${NC}\n"
    printf "  → http://%s:8080/singbox.json\n\n" "$server_ip"

    printf "  ${CYAN}Clash Verge / Mihomo:${NC}\n"
    printf "  → http://%s:8080/%s\n\n" "$server_ip" "$CLASH_PATH"

    printf "  ${CYAN}V2Ray (единая подписка Base64):${NC}\n"
    printf "  → http://%s:8080/%s\n\n" "$server_ip" "$SUB_PATH"

    printf "  %s\n" "──────────────────────────────────────────────────────────"
    printf "  Полные креденциалы: ${BOLD}%s${NC}\n" "$INFO_FILE"

    # VPN Panel
    if [[ -f "$STATE_DIR/panel.env" ]]; then
        source "$STATE_DIR/panel.env"
        local panel_pass=""
        if [[ -f "/etc/vpn-panel/admin_password.txt" ]]; then
            panel_pass=$(grep "admin:" /etc/vpn-panel/admin_password.txt | cut -d: -f2)
        fi
        printf "\n  ${BOLD}VPN Panel:${NC}\n"
        printf "  → https://%s:%s\n" "$server_ip" "${PANEL_PORT:-?}"
        printf "  Логин: ${BOLD}admin${NC}  Пароль: ${BOLD}%s${NC}\n\n" "${panel_pass:-?}"
    fi
}

# =============================================================================
# UNINSTALL
# =============================================================================
do_uninstall() {
    printf "\n  ${RED}✗${NC}  Удаление VPN-сервера...\n\n"

    systemctl stop hysteria-server 2>/dev/null || true
    systemctl disable hysteria-server 2>/dev/null || true
    systemctl stop mita 2>/dev/null || true
    systemctl disable mita 2>/dev/null || true
    systemctl stop vpn-sub 2>/dev/null || true
    systemctl disable vpn-sub 2>/dev/null || true
    systemctl stop warp-routing 2>/dev/null || true
    systemctl disable warp-routing 2>/dev/null || true
    systemctl stop "wg-quick@wgcf-warp" 2>/dev/null || true
    systemctl disable "wg-quick@wgcf-warp" 2>/dev/null || true

    systemctl stop vpn-panel 2>/dev/null || true
    systemctl disable vpn-panel 2>/dev/null || true

    # Удаляем systemd-юниты
    rm -f /etc/systemd/system/hysteria-server.service
    rm -f /etc/systemd/system/vpn-sub.service
    rm -f /etc/systemd/system/warp-routing.service
    rm -f /etc/systemd/system/vpn-panel.service
    rm -f /etc/network/if-up.d/warp-routing

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

    # Очищаем iptables
    iptables -t mangle -F OUTPUT 2>/dev/null || true
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    ip6tables -t mangle -F OUTPUT 2>/dev/null || true
    ip rule del fwmark 0x1 table 200 2>/dev/null || true

    # Удаляем пользователей
    userdel -r hysteria 2>/dev/null || true
    userdel -r vpnsub 2>/dev/null || true
    userdel -r mita 2>/dev/null || true

    # Удаляем WARP-интерфейс
    ip link del wgcf-warp 2>/dev/null || true

    # Удаляем iptables-правило ICMP
    sed -i '/vpn-setup-icmp-block/d' /etc/ufw/before.rules 2>/dev/null || true

    systemctl daemon-reload 2>/dev/null || true

    printf "  ${GREEN}✔${NC}  VPN-сервер полностью удалён.\n\n"
}

# =============================================================================
# STATUS
# =============================================================================
do_status() {
    printf "\n  ${BOLD}${CYAN}VPN Server Status${NC}\n"
    printf "  %s\n\n" "──────────────────────────────────────────────────────────"

    # Mieru
    if systemctl is-active --quiet mita 2>/dev/null; then
        printf "  ${GREEN}●${NC}  Mieru (mita)         ${GREEN}работает${NC}\n"
    else
        printf "  ${RED}●${NC}  Mieru (mita)         ${RED}остановлен${NC}\n"
    fi

    # Hysteria2
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        printf "  ${GREEN}●${NC}  Hysteria2             ${GREEN}работает${NC}\n"
    else
        printf "  ${RED}●${NC}  Hysteria2             ${RED}остановлен${NC}\n"
    fi

    # WARP
    if wg show wgcf-warp &>/dev/null 2>&1; then
        printf "  ${GREEN}●${NC}  Cloudflare WARP       ${GREEN}активен${NC}\n"
    else
        printf "  ${YELLOW}●${NC}  Cloudflare WARP       ${YELLOW}не активен${NC}\n"
    fi

    # Subscription server
    if systemctl is-active --quiet vpn-sub 2>/dev/null; then
        printf "  ${GREEN}●${NC}  HTTPS-подписка (:8080) ${GREEN}работает${NC}\n"
    else
        printf "  ${RED}●${NC}  HTTPS-подписка (:8080) ${RED}остановлен${NC}\n"
    fi

    # fail2ban
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        printf "  ${GREEN}●${NC}  fail2ban              ${GREEN}работает${NC}\n"
    else
        printf "  ${YELLOW}●${NC}  fail2ban              ${YELLOW}не активен${NC}\n"
    fi

    # IP
    local server_ip
    server_ip=$(get_server_ip)
    printf "\n  IP сервера: ${BOLD}%s${NC}\n" "$server_ip"

    # Креденциалы
    if [[ -f "$STATE_DIR/mieru.env" ]]; then
        source "$STATE_DIR/mieru.env"
        printf "\n  ${CYAN}Mieru:${NC}  порт ${MIERU_PORT:-?} (TCP) / ${MIERU_UDP_PORT:-?} (UDP)\n"
    fi
    if [[ -f "$STATE_DIR/hysteria2.env" ]]; then
        source "$STATE_DIR/hysteria2.env"
        printf "  ${CYAN}Hysteria2:${NC} порт ${H2_PORT:-?} (UDP)\n"
    fi
    if [[ -f "$STATE_DIR/subscription_path" ]]; then
        source "$STATE_DIR/subscription_path"
        printf "\n  Подписка: ${BOLD}http://%s:8080/%s${NC}\n" "$server_ip" "${SUB_PATH:-?}"
    fi

    printf "\n"
}

# =============================================================================
# MULTI-USER
# =============================================================================
do_add_user() {
    local username="${1:-}"
    if [[ -z "$username" ]]; then
        printf "  ${RED}✗${NC}  Использование: setup.sh --add-user <имя>\n"
        exit 1
    fi

    local users_file="$STATE_DIR/vpn-users.conf"
    mkdir -p "$STATE_DIR"

    if grep -q "^${username}|" "$users_file" 2>/dev/null; then
        printf "  ${YELLOW}!${NC}  Пользователь '%s' уже существует.\n" "$username"
        return 0
    fi

    local password
    password=$(openssl rand -base64 22 | tr -d '/+=' | head -c 24)

    echo "${username}|${password}" >> "$users_file"
    chmod 600 "$users_file"

    # Обновляем конфиг Mieru с новым пользователем
    if [[ -f "$STATE_DIR/mieru.env" ]]; then
        source "$STATE_DIR/mieru.env"
        local users_json=""
        while IFS='|' read -r uname upass; do
            [[ -n "$uname" ]] && users_json+="{\"name\":\"${uname}\",\"password\":\"${upass}\"},"
        done < "$users_file"
        users_json="[${users_json%,}]"

        cat > /tmp/mita_users_config.json <<EOF
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
        mita apply config /tmp/mita_users_config.json 2>/dev/null || true
        rm -f /tmp/mita_users_config.json
        systemctl restart mita 2>/dev/null || true
    fi

    printf "  ${GREEN}✔${NC}  Пользователь '%s' добавлен. Пароль: ${BOLD}%s${NC}\n\n" "$username" "$password"
}

do_remove_user() {
    local username="${1:-}"
    if [[ -z "$username" ]]; then
        printf "  ${RED}✗${NC}  Использование: setup.sh --remove-user <имя>\n"
        exit 1
    fi

    local users_file="$STATE_DIR/vpn-users.conf"
    if [[ ! -f "$users_file" ]] || ! grep -q "^${username}|" "$users_file" 2>/dev/null; then
        printf "  ${YELLOW}!${NC}  Пользователь '%s' не найден.\n" "$username"
        return 0
    fi

    sed -i "/^${username}|/d" "$users_file"

    # Обновляем конфиг Mieru
    if [[ -f "$STATE_DIR/mieru.env" ]]; then
        source "$STATE_DIR/mieru.env"
        local users_json=""
        if [[ -s "$users_file" ]]; then
            while IFS='|' read -r uname upass _rest; do
                [[ -n "$uname" ]] && users_json+="{\"name\":\"${uname}\",\"password\":\"${upass}\"},"
            done < "$users_file"
            users_json="[${users_json%,}]"
        else
            users_json="[]"
        fi

        cat > /tmp/mita_users_config.json <<EOF
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
        mita apply config /tmp/mita_users_config.json 2>/dev/null || true
        rm -f /tmp/mita_users_config.json
        systemctl restart mita 2>/dev/null || true
    fi

    printf "  ${GREEN}✔${NC}  Пользователь '%s' удалён.\n\n" "$username"
}

# =============================================================================
# SHOW KEYS — вывод всех ключей и ссылок
# =============================================================================
do_show_keys() {
    printf "\n  ${BOLD}${CYAN}VPN Server — Мои ключи${NC}\n"
    printf "  %s\n\n" "──────────────────────────────────────────────────────────"

    local server_ip
    server_ip=$(get_server_ip)

    # Загружаем конфиги
    if [[ -f "$STATE_DIR/mieru.env" ]]; then source "$STATE_DIR/mieru.env"; fi
    if [[ -f "$STATE_DIR/hysteria2.env" ]]; then source "$STATE_DIR/hysteria2.env"; fi
    if [[ -f "$STATE_DIR/subscription_path" ]]; then source "$STATE_DIR/subscription_path"; fi

    # Ссылки
    printf "  ${BOLD}Ссылки для подключения:${NC}\n\n"
    printf "  ${CYAN}Karing / Sing-box:${NC}\n"
    printf "  → http://%s:8080/singbox.json\n\n" "$server_ip"
    printf "  ${CYAN}Clash Verge / Mihomo:${NC}\n"
    printf "  → http://%s:8080/%s\n\n" "$server_ip" "${CLASH_PATH:-clash.yaml}"
    printf "  ${CYAN}V2Ray (единая подписка):${NC}\n"
    printf "  → http://%s:8080/%s\n\n" "$server_ip" "${SUB_PATH:-sub.txt}"

    # Ключи
    printf "  ${BOLD}Ключи:${NC}\n\n"
    if [[ -n "${MIERU_URI:-}" ]]; then
        printf "  ${CYAN}Mieru:${NC}  порт %s (TCP) / %s (UDP)\n" "${MIERU_PORT:-?}" "${MIERU_UDP_PORT:-?}"
        printf "  URI: %s\n\n" "$MIERU_URI"
    fi
    if [[ -n "${H2_URI:-}" ]]; then
        printf "  ${CYAN}Hysteria2:${NC} порт %s (UDP)\n" "${H2_PORT:-?}"
        printf "  URI: %s\n\n" "$H2_URI"
    fi

    # Пользователи
    local users_file="$STATE_DIR/vpn-users.conf"
    if [[ -f "$users_file" ]] && [[ -s "$users_file" ]]; then
        printf "  ${BOLD}Пользователи:${NC}\n\n"
        printf "  ${BOLD}%-15s %-12s %-12s %-10s %-10s${NC}\n" "Имя" "Срок" "Трафик" "Скорость" "Протокол"
        printf "  %s\n" "──────────────────────────────────────────────────────────"
        while IFS='|' -r read -r uname upass uexpire utraffic uspeed uproto; do
            [[ -z "$uname" ]] && continue
            local expire_display="${uexpire:-бессрочно}"
            local traffic_display="${utraffic:-безлимит}"
            local speed_display="${uspeed:-безлимит}"
            local proto_display="${uproto:-all}"
            # Проверяем срок действия
            if [[ "$expire_display" != "never" && "$expire_display" != "бессрочно" ]]; then
                local expire_epoch
                expire_epoch=$(date -d "$expire_display" +%s 2>/dev/null || echo 0)
                local now_epoch
                now_epoch=$(date +%s)
                if [[ "$expire_epoch" -gt 0 && "$expire_epoch" -lt "$now_epoch" ]]; then
                    expire_display="${RED}истёк${NC}"
                fi
            fi
            printf "  %-15s %-22b %-12s %-10s %-10s\n" "$uname" "$expire_display" "$traffic_display" "$speed_display" "$proto_display"
        done < "$users_file"
        printf "\n"
    fi

    # Полный файл с креденциалами
    printf "  ${BOLD}Полные креденциалы:${NC} %s\n\n" "$INFO_FILE"
}

# =============================================================================
# INTERACTIVE MENU
# =============================================================================
show_banner() {
    clear
    printf "\n"
    printf "  ${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}\n"
    printf "  ${BOLD}${CYAN}║${NC}         ${BOLD}VPN Server Auto-Setup${NC}                        ${BOLD}${CYAN}║${NC}\n"
    printf "  ${BOLD}${CYAN}║${NC}  Mieru + Hysteria2 + Cloudflare WARP                ${BOLD}${CYAN}║${NC}\n"
    printf "  ${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
    printf "  ${BOLD}Описание:${NC}\n"
    printf "  Автоматическая настройка VPN-сервера на VPS.\n"
    printf "  Поддержка Mieru (TCP/UDP) и Hysteria2 (QUIC).\n"
    printf "  Сплит-маршрутизация через Cloudflare WARP.\n"
    printf "  Автоматическая оптимизация сетевого стека.\n"
    printf "\n"
}

show_menu() {
    printf "  ${BOLD}Выберите действие:${NC}\n\n"
    printf "  ${CYAN}1${NC})  Запустить настройку\n"
    printf "  ${CYAN}2${NC})  Мои ключи\n"
    printf "  ${CYAN}3${NC})  Добавить пользователя\n"
    printf "  ${CYAN}4${NC})  Удалить пользователя\n"
    printf "  ${CYAN}5${NC})  Статус сервера\n"
    printf "  ${CYAN}6${NC})  Удалить VPN-сервер\n"
    printf "  ${CYAN}0${NC})  Выход\n"
    printf "\n"
    printf "  ${BOLD}Ваш выбор [0-6]: ${NC}"
}

# =============================================================================
# ADD USER — интерактивное добавление с лимитами
# =============================================================================
do_add_user_interactive() {
    printf "\n  ${BOLD}${CYAN}Добавление пользователя${NC}\n"
    printf "  %s\n\n" "──────────────────────────────────────────────────────────"

    # Имя
    read -rp "  Имя пользователя: " username
    if [[ -z "$username" ]]; then
        printf "  ${RED}✗${NC}  Имя не может быть пустым.\n\n"
        return 1
    fi

    local users_file="$STATE_DIR/vpn-users.conf"
    mkdir -p "$STATE_DIR"
    if grep -q "^${username}|" "$users_file" 2>/dev/null; then
        printf "  ${YELLOW}!${NC}  Пользователь '%s' уже существует.\n\n" "$username"
        return 0
    fi

    local password
    password=$(openssl rand -base64 22 | tr -d '/+=' | head -c 24)

    # Срок действия
    printf "\n  ${BOLD}Срок действия:${NC}\n"
    printf "  ${CYAN}0${NC})  Бессрочно\n"
    printf "  ${CYAN}1${NC})  7 дней\n"
    printf "  ${CYAN}2${NC})  30 дней\n"
    printf "  ${CYAN}3${NC})  90 дней\n"
    printf "  ${CYAN}4${NC})  365 дней\n"
    printf "  ${CYAN}5${NC})  Своя дата (YYYY-MM-DD)\n"
    read -rp "  Выбор [0-5, по умолчанию 0]: " expire_choice
    expire_choice="${expire_choice:-0}"

    local expire_date="never"
    local expire_display="бессрочно"
    case "$expire_choice" in
        1) expire_date=$(date -d "+7 days" +%Y-%m-%d 2>/dev/null || date -v+7d +%Y-%m-%d 2>/dev/null); expire_display="7 дней" ;;
        2) expire_date=$(date -d "+30 days" +%Y-%m-%d 2>/dev/null || date -v+30d +%Y-%m-%d 2>/dev/null); expire_display="30 дней" ;;
        3) expire_date=$(date -d "+90 days" +%Y-%m-%d 2>/dev/null || date -v+90d +%Y-%m-%d 2>/dev/null); expire_display="90 дней" ;;
        4) expire_date=$(date -d "+365 days" +%Y-%m-%d 2>/dev/null || date -v+365d +%Y-%m-%d 2>/dev/null); expire_display="365 дней" ;;
        5) read -rp "  Дата окончания (YYYY-MM-DD): " expire_date
           expire_display="$expire_date" ;;
        *) expire_date="never"; expire_display="бессрочно" ;;
    esac

    # Лимит трафика
    printf "\n  ${BOLD}Лимит трафика:${NC}\n"
    printf "  ${CYAN}0${NC})  Безлимит\n"
    printf "  ${CYAN}1${NC})  10 ГБ\n"
    printf "  ${CYAN}2${NC})  50 ГБ\n"
    printf "  ${CYAN}3${NC})  100 ГБ\n"
    printf "  ${CYAN}4${NC})  500 ГБ\n"
    printf "  ${CYAN}5${NC})  Свой объём (ГБ)\n"
    read -rp "  Выбор [0-5, по умолчанию 0]: " traffic_choice
    traffic_choice="${traffic_choice:-0}"

    local traffic_limit="unlimited"
    local traffic_display="безлимит"
    case "$traffic_choice" in
        1) traffic_limit="10"; traffic_display="10 ГБ" ;;
        2) traffic_limit="50"; traffic_display="50 ГБ" ;;
        3) traffic_limit="100"; traffic_display="100 ГБ" ;;
        4) traffic_limit="500"; traffic_display="500 ГБ" ;;
        5) read -rp "  Объём (ГБ): " traffic_limit; traffic_display="${traffic_limit} ГБ" ;;
        *) traffic_limit="unlimited"; traffic_display="безлимит" ;;
    esac

    # Лимит скорости
    printf "\n  ${BOLD}Лимит скорости:${NC}\n"
    printf "  ${CYAN}0${NC})  Безлимит\n"
    printf "  ${CYAN}1${NC})  10 Мбит/с\n"
    printf "  ${CYAN}2${NC})  50 Мбит/с\n"
    printf "  ${CYAN}3${NC})  100 Мбит/с\n"
    printf "  ${CYAN}4${NC})  Своя скорость (Мбит/с)\n"
    read -rp "  Выбор [0-4, по умолчанию 0]: " speed_choice
    speed_choice="${speed_choice:-0}"

    local speed_limit="unlimited"
    local speed_display="безлимит"
    case "$speed_choice" in
        1) speed_limit="10"; speed_display="10 Мбит/с" ;;
        2) speed_limit="50"; speed_display="50 Мбит/с" ;;
        3) speed_limit="100"; speed_display="100 Мбит/с" ;;
        4) read -rp "  Скорость (Мбит/с): " speed_limit; speed_display="${speed_limit} Мбит/с" ;;
        *) speed_limit="unlimited"; speed_display="безлимит" ;;
    esac

    # Протокол
    printf "\n  ${BOLD}Протокол:${NC}\n"
    printf "  ${CYAN}0${NC})  Все (Hysteria2 + Mieru)\n"
    printf "  ${CYAN}1${NC})  Только Hysteria2\n"
    printf "  ${CYAN}2${NC})  Только Mieru\n"
    read -rp "  Выбор [0-2, по умолчанию 0]: " proto_choice
    proto_choice="${proto_choice:-0}"

    local proto_limit="all"
    local proto_display="все"
    case "$proto_choice" in
        1) proto_limit="hysteria2"; proto_display="Hysteria2" ;;
        2) proto_limit="mieru"; proto_display="Mieru" ;;
        *) proto_limit="all"; proto_display="все" ;;
    esac

    # Сохраняем пользователя
    echo "${username}|${password}|${expire_date}|${traffic_limit}|${speed_limit}|${proto_limit}" >> "$users_file"
    chmod 600 "$users_file"

    # Обновляем конфиг Mieru (добавляем пользователя)
    if [[ -f "$STATE_DIR/mieru.env" ]]; then
        source "$STATE_DIR/mieru.env"
        local users_json=""
        while IFS='|' read -r uname upass _rest; do
            [[ -n "$uname" ]] && users_json+="{\"name\":\"${uname}\",\"password\":\"${upass}\"},"
        done < "$users_file"
        users_json="[${users_json%,}]"

        cat > /tmp/mita_users_config.json <<EOF
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
        mita apply config /tmp/mita_users_config.json 2>/dev/null || true
        rm -f /tmp/mita_users_config.json
        systemctl restart mita 2>/dev/null || true
    fi

    # Генерируем ссылки для пользователя
    local sub_content=""
    if [[ "$proto_limit" == "all" || "$proto_limit" == "hysteria2" ]]; then
        [[ -n "${H2_URI:-}" ]] && sub_content+="${H2_URI}"$'\n'
    fi
    if [[ "$proto_limit" == "all" || "$proto_limit" == "mieru" ]]; then
        [[ -n "${MIERU_URI:-}" ]] && sub_content+="${MIERU_URI}"$'\n'
    fi
    local sub_base64
    sub_base64=$(echo -n "$sub_content" | base64 | tr -d '\r\n')
    local user_sub_path="sub-${username}-$(openssl rand -hex 4).txt"
    echo -n "$sub_base64" > "/var/www/html/${user_sub_path}"
    chmod 644 "/var/www/html/${user_sub_path}"

    printf "\n  ${GREEN}✔${NC}  Пользователь '${BOLD}%s${NC}' создан.\n\n" "$username"
    printf "  ${BOLD}Пароль:${NC}        %s\n" "$password"
    printf "  ${BOLD}Срок:${NC}          %s\n" "$expire_display"
    printf "  ${BOLD}Трафик:${NC}        %s\n" "$traffic_display"
    printf "  ${BOLD}Скорость:${NC}      %s\n" "$speed_display"
    printf "  ${BOLD}Протокол:${NC}      %s\n" "$proto_display"
    printf "\n"
    printf "  ${BOLD}Ссылка для клиента:${NC}\n"
    printf "  → http://%s:8080/%s\n\n" "$(get_server_ip)" "$user_sub_path"
}

# =============================================================================
# FAIL2BAN + SSH HARDENING
# =============================================================================
setup_fail2ban() {
    step_begin "fail2ban + SSH hardening"

    if is_done "setup_fail2ban"; then
        step_skip; return 0
    fi

    # Установка fail2ban
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban >> "$LOG_FILE" 2>&1 || true
    elif [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf install -y -q epel-release >> "$LOG_FILE" 2>&1 || true
        dnf install -y -q fail2ban >> "$LOG_FILE" 2>&1 || true
    fi

    # Конфигурация fail2ban
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400
EOF

    systemctl enable fail2ban >> "$LOG_FILE" 2>&1 || true
    systemctl restart fail2ban >> "$LOG_FILE" 2>&1 || true

    # SSH hardening: отключение парольной аутентификации
    local sshd_config="/etc/ssh/sshd_config"
    if [[ -f "$sshd_config" ]]; then
        cp "$sshd_config" "${sshd_config}.bak" 2>/dev/null || true
        # Включаем pubkey-only если ещё не включён
        if ! grep -q "^PubkeyAuthentication yes" "$sshd_config" 2>/dev/null; then
            sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' "$sshd_config" 2>/dev/null || true
        fi
        if ! grep -q "^PasswordAuthentication no" "$sshd_config" 2>/dev/null; then
            sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' "$sshd_config" 2>/dev/null || true
        fi
        if ! grep -q "^ChallengeResponseAuthentication no" "$sshd_config" 2>/dev/null; then
            sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' "$sshd_config" 2>/dev/null || true
        fi
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    fi

    mark_done "setup_fail2ban"
    step_finish
}

# =============================================================================
# 9. setup_panel
# =============================================================================
setup_panel() {
    step_begin "VPN Panel (веб-интерфейс)"

    if is_done "setup_panel"; then
        step_skip; return 0
    fi

    PANEL_PORT=$(find_free_port tcp 20000 65000)

    # Установка зависимостей
    if ! python3 -c "import flask" 2>/dev/null; then
        pip3 install --break-system-packages flask flask-wtf 2>&1 | tail -3
        pip3 install flask flask-wtf 2>&1 | tail -3 || true
    fi

    # Копирование файлов панели
    local panel_dir="/opt/vpn-panel"
    mkdir -p "$panel_dir"/{templates,static,certs}
    mkdir -p /etc/vpn-panel

    # Скачиваем файлы панели из репозитория
    local repo_raw="https://raw.githubusercontent.com/Maksre1/vpn-setup/main/panel"
    for f in app.py models.py utils.py; do
        curl -fsSL "${repo_raw}/${f}" -o "${panel_dir}/${f}" >> "$LOG_FILE" 2>&1 || true
    done
    for f in base.html login.html dashboard.html users.html user_edit.html keys.html settings.html logs.html; do
        curl -fsSL "${repo_raw}/templates/${f}" -o "${panel_dir}/templates/${f}" >> "$LOG_FILE" 2>&1 || true
    done
    for f in style.css app.js; do
        curl -fsSL "${repo_raw}/static/${f}" -o "${panel_dir}/static/${f}" >> "$LOG_FILE" 2>&1 || true
    done

    # Генерация ECDSA-сертификата
    if [[ ! -f "$panel_dir/certs/server.key" ]]; then
        openssl ecparam -genkey -name prime256v1 \
            -out "$panel_dir/certs/server.key" 2>/dev/null
        openssl req -new -x509 \
            -key "$panel_dir/certs/server.key" \
            -out "$panel_dir/certs/server.crt" \
            -days 3650 -nodes \
            -subj "/CN=vpn-panel/O=VPN/C=US" 2>/dev/null
        chmod 600 "$panel_dir/certs/server.key"
        chmod 644 "$panel_dir/certs/server.crt"
    fi

    # Systemd unit
    cat > /etc/systemd/system/vpn-panel.service <<EOF
[Unit]
Description=VPN Management Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${panel_dir}
Environment=PANEL_PORT=${PANEL_PORT}
ExecStart=/usr/bin/python3 ${panel_dir}/app.py
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload 2>/dev/null

    # Генерируем пароль ДО запуска сервиса
    if [[ ! -f "/etc/vpn-panel/admin_password.txt" ]]; then
        local admin_pass
        admin_pass=$(openssl rand -base64 18 | tr -d '/+=' | head -c 16)
        echo "admin:${admin_pass}" > /etc/vpn-panel/admin_password.txt
        chmod 600 /etc/vpn-panel/admin_password.txt
    fi

    systemctl enable vpn-panel 2>/dev/null || true
    systemctl restart vpn-panel 2>/dev/null || true

    # Открываем порт в файрволе
    ufw allow "${PANEL_PORT}/tcp" comment "VPN Panel" 2>/dev/null || true
    ufw reload 2>/dev/null || true

    # Сохраняем порт
    echo "PANEL_PORT=\"${PANEL_PORT}\"" > "$STATE_DIR/panel.env"
    chmod 600 "$STATE_DIR/panel.env"

    sleep 2

    mark_done "setup_panel"
    step_finish
}

# =============================================================================
# MAIN — точка входа
# =============================================================================
main() {
    # Обработка аргументов командной строки (совместимость со старым форматом)
    case "${1:-}" in
        --uninstall)
            check_root
            do_uninstall
            exit 0
            ;;
        --status)
            do_status
            exit 0
            ;;
        --add-user)
            check_root
            do_add_user "${2:-}"
            exit 0
            ;;
        --remove-user)
            check_root
            do_remove_user "${2:-}"
            exit 0
            ;;
        --keys)
            do_show_keys
            exit 0
            ;;
        --setup)
            init_log
            check_root
            check_os
            setup_dns
            sync_time
            update_system
            setup_firewall
            detect_system_specs
            tune_network
            install_mieru
            install_hysteria2
            setup_warp
            setup_subscription_server
            setup_fail2ban
            setup_panel
            print_summary
            exit 0
            ;;
    esac

    # Интерактивное меню
    check_root
    show_banner

    while true; do
        show_menu
        read -r choice
        case "$choice" in
            1)
                check_os
                setup_dns
                sync_time
                update_system
                setup_firewall
                detect_system_specs
                tune_network
                install_mieru
                install_hysteria2
                setup_warp
                setup_subscription_server
                setup_fail2ban
                setup_panel
                print_summary
                printf "\n  Нажмите Enter для возврата в меню..."
                read -r
                show_banner
                ;;
            2)
                do_show_keys
                printf "\n  Нажмите Enter для возврата в меню..."
                read -r
                show_banner
                ;;
            3)
                do_add_user_interactive
                printf "\n  Нажмите Enter для возврата в меню..."
                read -r
                show_banner
                ;;
            4)
                read -rp "  Имя пользователя для удаления: " del_user
                do_remove_user "$del_user"
                printf "\n  Нажмите Enter для возврата в меню..."
                read -r
                show_banner
                ;;
            5)
                do_status
                printf "\n  Нажмите Enter для возврата в меню..."
                read -r
                show_banner
                ;;
            6)
                printf "\n  ${RED}Вы уверены? Это удалит всё! (yes/no): ${NC}"
                read -r confirm
                if [[ "$confirm" == "yes" ]]; then
                    do_uninstall
                    exit 0
                fi
                show_banner
                ;;
            0|q|Q)
                printf "\n  ${GREEN}До свидания!${NC}\n\n"
                exit 0
                ;;
            *)
                printf "  ${RED}Неверный выбор.${NC}\n\n"
                sleep 1
                show_banner
                ;;
        esac
    done
}

main "$@"

