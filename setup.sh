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

# Обработчик ошибок для красивого вывода при аварийном выходе
cleanup_err() {
    local exit_code=$?
    local line_no=$1
    # Возвращаем автообновления обратно в работу при любом выходе
    if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
        systemctl start unattended-upgrades >> "$LOG_FILE" 2>&1 || true
    fi
    if [[ "$exit_code" -ne 0 ]]; then
        echo -e "\n${RED}[FAIL] Скрипт аварийно завершился на строке ${line_no} с кодом ошибки ${exit_code}.${NC}"
        echo -e "${YELLOW}Полный лог ошибки доступен в файле: ${LOG_FILE}${NC}"
        echo -e "${YELLOW}Вы можете просмотреть последние 20 строк лога командой:${NC}"
        echo -e "${BOLD}tail -n 20 ${LOG_FILE}${NC}\n"
    fi
}
trap 'cleanup_err $LINENO' EXIT

# ── Глобальные переменные ────────────────────────────────────────────────────
readonly LOG_FILE="/var/log/vpn-setup.log"
readonly STATE_DIR="/etc/vpn-setup-state"
readonly MIERU_CONFIG_DIR="/etc/mita"
readonly H2_CONFIG_DIR="/etc/hysteria"
readonly H2_CERT_DIR="/etc/hysteria/certs"
readonly INFO_FILE="/root/vpn-setup-info.txt"

SSH_PORT="${SSH_PORT:-22}"

# Цвета для вывода
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# =============================================================================
# Вспомогательные функции логирования и детекции ОС
# =============================================================================

init_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    echo "" >> "$LOG_FILE"
    echo "======================================" >> "$LOG_FILE"
    echo "Запуск setup.sh: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    echo "======================================" >> "$LOG_FILE"
}

log() {
    local msg="$1"
    echo -e "$msg" | tee -a "$LOG_FILE"
}

log_section() {
    log ""
    log "${CYAN}${BOLD}══════════════════════════════════════════${NC}"
    log "${CYAN}${BOLD}  $1${NC}"
    log "${CYAN}${BOLD}══════════════════════════════════════════${NC}"
}

log_step() { log "${YELLOW}  ▶ $1${NC}"; }
log_ok() { log "${GREEN}  [OK]${NC} $1"; }
log_fail() { log "${RED}  [FAIL]${NC} $1"; }
log_info() { log "        $1"; }

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
    while true; do
        port=$(( RANDOM % (range_max - range_min + 1) + range_min ))
        if ! ss -"${proto}"ln 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return 0
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
    log_section "Настройка DNS серверов"
    if is_done "setup_dns"; then
        log_ok "DNS уже настроен."
        return 0
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
    cat > /etc/resolv.conf.tmp <<EOF
# Сгенерировано setup.sh
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 1.0.0.1
EOF
    mv /etc/resolv.conf.tmp /etc/resolv.conf || true
    log_ok "/etc/resolv.conf обновлен"

    mark_done "setup_dns"
    log_ok "Шаг настройки DNS завершен."
}

# =============================================================================
# Новая функция: Синхронизация времени
# =============================================================================
sync_time() {
    log_section "Синхронизация времени сервера"
    if is_done "sync_time"; then
        log_ok "Время уже синхронизировано."
        return 0
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
    log_ok "Шаг синхронизации времени завершен."
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
    log_ok "Шаг 2 завершён."
}

# =============================================================================
# 3. detect_system_specs
# =============================================================================
detect_system_specs() {
    log_section "3. Определение характеристик сервера"

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
        LINK_SPEED_MBPS=$(ethtool "$NET_IFACE" 2>/dev/null | grep -i "Speed:" | grep -oP '\d+' | head -1 || echo 0)
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
        BUF_TIER="консервативный (RAM < 1 ГБ)"
    elif [[ $RAM_MB -lt 4096 ]]; then
        RMEM_MAX=$((16 * 1024 * 1024))
        WMEM_MAX=$((16 * 1024 * 1024))
        TCP_RMEM="4096 131072 16777216"
        TCP_WMEM="4096 131072 16777216"
        NETDEV_MAX_BACKLOG=5000
        SOMAXCONN=1024
        TCP_MAX_SYN_BACKLOG=1024
        BUF_TIER="средний (RAM 1-4 ГБ)"
    else
        RMEM_MAX=$((32 * 1024 * 1024))
        WMEM_MAX=$((32 * 1024 * 1024))
        TCP_RMEM="4096 131072 33554432"
        TCP_WMEM="4096 131072 33554432"
        NETDEV_MAX_BACKLOG=5000
        SOMAXCONN=2048
        TCP_MAX_SYN_BACKLOG=2048
        BUF_TIER="агрессивный (RAM >= 4 ГБ)"
    fi

    export BBR_AVAILABLE RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM NETDEV_MAX_BACKLOG SOMAXCONN TCP_MAX_SYN_BACKLOG NET_IFACE
    log_ok "Профиль буферов: $BUF_TIER"
    log_ok "Шаг 3 завершён."
}

# =============================================================================
# 4. tune_network
# =============================================================================
tune_network() {
    log_section "4. Настройка сетевых параметров ядра"

    if is_done "tune_network"; then
        log_ok "Шаг уже выполнен, пропускаем."
        return 0
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
    log_ok "Шаг 4 завершён."
}

# =============================================================================
# 5. install_mieru
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
    systemctl restart mita >> "$LOG_FILE" 2>&1 || systemctl start mita >> "$LOG_FILE" 2>&1 || true
    sleep 2

    mita apply config "$mita_config_file" >> "$LOG_FILE" 2>&1
    rm -f "$mita_config_file"

    systemctl restart mita >> "$LOG_FILE" 2>&1 || true
    ufw allow "$MIERU_PORT"/tcp comment "Mieru proxy" >> "$LOG_FILE" 2>&1

    mkdir -p "$STATE_DIR"
    local server_ip
    server_ip=$(get_server_ip)
    local mieru_uri="mieru://${server_ip}:${MIERU_PORT}?username=${MIERU_USER}&password=${MIERU_PASS}&network=tcp#Mieru-Proxy"

    cat > "$STATE_DIR/mieru.env" <<EOF
MIERU_PORT="${MIERU_PORT}"
MIERU_USER="${MIERU_USER}"
MIERU_PASS="${MIERU_PASS}"
MIERU_URI="${mieru_uri}"
MIERU_VERSION="${mita_version}"
EOF
    chmod 600 "$STATE_DIR/mieru.env"

    mark_done "install_mieru"
    log_ok "Шаг 5 завершён."
}

# =============================================================================
# 6. install_hysteria2
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

    local cert_sha256=""
    if [[ -f "$H2_CERT_DIR/server.crt" ]]; then
        cert_sha256=$(openssl x509 -in "$H2_CERT_DIR/server.crt" -noout -fingerprint -sha256 | cut -d'=' -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
    fi

    H2_URI="hysteria2://${H2_PASS}@${server_ip}:${H2_PORT}?obfs=salamander&obfs-password=${H2_OBFS_PASS}&pinSHA256=${cert_sha256}&sni=${H2_CERT_CN}"

    cat > "$STATE_DIR/hysteria2.env" <<EOF
H2_PORT="${H2_PORT}"
H2_PASS="${H2_PASS}"
H2_OBFS_PASS="${H2_OBFS_PASS}"
H2_CERT_CN="${H2_CERT_CN}"
H2_CERT_PIN="${cert_sha256}"
H2_URI="${H2_URI}"
H2_VERSION="$(hysteria version 2>/dev/null | head -n 1 || echo "unknown")"
EOF
    chmod 600 "$STATE_DIR/hysteria2.env"

    mark_done "install_hysteria2"
    log_ok "Шаг 6 завершён."
}

# =============================================================================
# 7. setup_warp
# =============================================================================
setup_warp() {
    log_section "7. Настройка Cloudflare WARP (wgcf)"

    # Загружаем порты из файлов состояния, если они есть
    if [[ -f "$STATE_DIR/mieru.env" ]]; then
        source "$STATE_DIR/mieru.env"
    fi
    if [[ -f "$STATE_DIR/hysteria2.env" ]]; then
        source "$STATE_DIR/hysteria2.env"
    fi

    if is_done "setup_warp"; then
        log_ok "Шаг уже выполнен, пропускаем."
        return 0
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
            return 0
        fi
    else
        log_ok "wgcf уже установлен"
    fi

    local warp_dir="/etc/wgcf"
    mkdir -p "$warp_dir"
    cd "$warp_dir"

    log_step "Регистрация нового WARP-аккаунта..."
    if [[ ! -f "$warp_dir/wgcf-account.toml" ]]; then
        if wgcf register --accept-tos >> "$LOG_FILE" 2>&1; then
            log_ok "WARP зарегистрирован"
        else
            log_fail "Регистрация WARP не удалась (Cloudflare API заблокировано или перегружено)."
            log_info "Пропуск настройки WARP. VPN будет работать напрямую без WARP."
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
    if [[ -n "$H2_PORT" ]]; then
        iptables -t mangle -A OUTPUT -p udp --sport "$H2_PORT" -j RETURN
    fi
    if [[ -n "$endpoint_ip" ]]; then
        if [[ "$endpoint_ip" =~ : ]]; then
            ip6tables -t mangle -A OUTPUT -d "$endpoint_ip" 2>/dev/null || true
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

    mark_done "setup_warp"
    log_ok "Шаг 7 завершён."
}

# =============================================================================
# 7.5. setup_subscription_server
# =============================================================================
setup_subscription_server() {
    log_section "7.5. Настройка веб-сервера подписки (vpn-sub)"

    if is_done "setup_sub_server"; then
        log_ok "Шаг уже выполнен, пропускаем."
        return 0
    fi

    log_step "Создание каталога веб-сервера..."
    mkdir -p /var/www/html

    log_step "Настройка systemd службы vpn-sub..."
    cat > /etc/systemd/system/vpn-sub.service <<EOF
[Unit]
Description=VPN Subscription Web Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/www/html
ExecStart=/usr/bin/python3 -m http.server 8080
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    log_step "Перезапуск службы vpn-sub..."
    systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
    systemctl enable vpn-sub >> "$LOG_FILE" 2>&1 || true
    systemctl restart vpn-sub >> "$LOG_FILE" 2>&1 || true

    log_step "Настройка брандмауэра для порта 8080..."
    ufw allow 8080/tcp comment "VPN subscription port" >> "$LOG_FILE" 2>&1

    mark_done "setup_sub_server"
    log_ok "Шаг 7.5 завершён."
}

# =============================================================================
# 8. print_summary
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
    if wg show wgcf-warp &>/dev/null 2>&1; then warp_status="активен"; fi

    local sub_content=""
    if [[ -n "${H2_URI:-}" ]]; then
        sub_content+="${H2_URI}"$'\n'
    fi
    if [[ -n "${MIERU_URI:-}" ]]; then
        sub_content+="${MIERU_URI}"$'\n'
    fi
    local sub_base64=""
    sub_base64=$(echo -n "$sub_content" | base64 | tr -d '\r\n')

    echo -n "$sub_base64" > /root/vpn-setup-sub.txt
    chmod 600 /root/vpn-setup-sub.txt

    mkdir -p /var/www/html
    echo -n "$sub_base64" > /var/www/html/sub.txt
    chmod 644 /var/www/html/sub.txt

    # Создаем singbox.json
    cat > /var/www/html/singbox.json <<JSON
{
  "outbounds": [
    {
      "type": "selector",
      "tag": "PROXY",
      "outbounds": [
        "Hysteria2-Proxy",
        "Mieru-Proxy",
        "direct"
      ]
    },
    {
      "type": "hysteria2",
      "tag": "Hysteria2-Proxy",
      "server": "${server_ip}",
      "server_port": ${H2_PORT:-443},
      "password": "${H2_PASS:-}",
      "obfs": {
        "type": "salamander",
        "password": "${H2_OBFS_PASS:-}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${H2_CERT_CN:-mail.example.com}",
        "insecure": false,
        "pinned_peer_cert_sha256": [
          "${H2_CERT_PIN:-}"
        ]
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
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
JSON
    chmod 644 /var/www/html/singbox.json

    cat > "$INFO_FILE" <<EOF
================================================================================
  VPN Server Setup — Информация для подключения
  Сервер IP: ${server_ip}
  Ссылка для Karing/Sing-box (JSON): http://${server_ip}:8080/singbox.json
================================================================================

  [0] ЕДИНАЯ ПОДПИСКА (Sub / V2ray Base64 format)
  Скопируйте этот блок в файл или загрузите на хостинг для раздачи подписки:
  ----------------------------------------------------------------------
  ${sub_base64}
  ----------------------------------------------------------------------

  [1] MIERU (mita)
  TCP порт:    ${MIERU_PORT:-НЕ ОПРЕДЕЛЁН}
  Пользователь: ${MIERU_USER:-НЕ ОПРЕДЕЛЁН}
  Пароль:      ${MIERU_PASS:-НЕ ОПРЕДЕЛЁН}

  Ссылка для Karing / других клиентов (Mieru URI):
  ${MIERU_URI:-не сгенерирована}

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

  Конфиг Mieru для Clash / Mihomo (YAML — скопируйте как новый профиль):
  ----------------------------------------------------------------------
  mixed-port: 7892
  allow-lan: false
  mode: rule
  log-level: info
  ipv6: false

  proxies:
    - name: Mieru-Proxy
      type: mieru
      server: ${server_ip}
      port: ${MIERU_PORT:-PORT}
      username: ${MIERU_USER:-USER}
      password: ${MIERU_PASS:-PASS}
      transport: TCP

  proxy-groups:
    - name: PROXY
      type: select
      proxies:
        - Mieru-Proxy
        - DIRECT

  rules:
    - MATCH, PROXY
  ----------------------------------------------------------------------

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
    print_summary
}

main "$@"
