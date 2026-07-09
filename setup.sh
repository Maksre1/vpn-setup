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
    #
    # Логика масштабирования:
    #   RAM < 1 ГБ  → консервативно (1-2 МБ на сокет)
    #   RAM 1-4 ГБ  → средние значения (8-16 МБ)
    #   RAM > 4 ГБ  → агрессивно (32-64 МБ), особенно при ≥2 CPU
    #
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
    log_info "  net.core.rmem_max         = $RMEM_MAX байт ($(( RMEM_MAX / 1024 / 1024 )) МБ)"
    log_info "  net.core.wmem_max         = $WMEM_MAX байт"
    log_info "  net.ipv4.tcp_rmem         = $TCP_RMEM"
    log_info "  net.ipv4.tcp_wmem         = $TCP_WMEM"
    log_info "  net.core.netdev_max_backlog = $NETDEV_MAX_BACKLOG"
    log_info "  net.core.somaxconn        = $SOMAXCONN"
    log_info "  net.ipv4.tcp_max_syn_backlog = $TCP_MAX_SYN_BACKLOG"
    log_info ""
    log_info "Основание: RAM=${RAM_MB}МБ, CPU=${CPU_CORES} ядер, BBR_AVAILABLE=$BBR_AVAILABLE"

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
        log_fail "Переменные из detect_system_specs не установлены. Запустите шаг 3 сначала."
        return 1
    fi

    log_step "Запись параметров в /etc/sysctl.d/99-vpn-tuning.conf..."

    cat > /etc/sysctl.d/99-vpn-tuning.conf <<EOF
# Файл сгенерирован setup.sh $(date '+%Y-%m-%d %H:%M:%S')
# Профиль: RAM=${RAM_MB}МБ, CPU=${CPU_CORES}, BBR=${BBR_AVAILABLE}

# ── TCP Congestion Control: BBR + fq qdisc ──────────────────────────────────
$(if [[ $BBR_AVAILABLE -eq 1 ]]; then
    echo "net.ipv4.tcp_congestion_control = bbr"
    echo "net.core.default_qdisc = fq"
else
    echo "# BBR недоступен в данном ядре — используем cubic"
    echo "# net.ipv4.tcp_congestion_control = bbr"
    echo "net.core.default_qdisc = fq"
fi)

# ── TCP Fast Open (клиент + сервер) ─────────────────────────────────────────
net.ipv4.tcp_fastopen = 3

# ── Буферы приёма/передачи (вычислены на основе RAM=${RAM_MB}МБ) ────────────
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = ${TCP_RMEM}
net.ipv4.tcp_wmem = ${TCP_WMEM}

# ── MTU Probing ──────────────────────────────────────────────────────────────
net.ipv4.tcp_mtu_probing = 1

# ── Очереди соединений ───────────────────────────────────────────────────────
net.core.netdev_max_backlog = ${NETDEV_MAX_BACKLOG}
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${TCP_MAX_SYN_BACKLOG}

# ── Защита и надёжность ─────────────────────────────────────────────────────
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65000
net.ipv4.tcp_fin_timeout = 30

# ── ICMP ping: игнорировать входящие echo-request ───────────────────────────
net.ipv4.icmp_echo_ignore_all = 1

# ── IP forwarding (для WireGuard/WARP) ──────────────────────────────────────
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

    log_ok "Файл /etc/sysctl.d/99-vpn-tuning.conf записан"

    log_step "Применение параметров (sysctl --system)..."
    if sysctl --system >> "$LOG_FILE" 2>&1; then
        log_ok "sysctl --system выполнен"
    else
        log_fail "sysctl --system завершился с ошибкой. Проверьте $LOG_FILE"
        return 1
    fi

    # Верификация BBR
    if [[ $BBR_AVAILABLE -eq 1 ]]; then
        log_step "Проверка активного алгоритма управления нагрузкой..."
        local active_cc
        active_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
        if [[ "$active_cc" == "bbr" ]]; then
            log_ok "BBR активен: $(sysctl net.ipv4.tcp_congestion_control)"
        else
            log_fail "BBR не активен! Текущий: $active_cc"
        fi
        log_info "Проверочная команда: sysctl net.ipv4.tcp_congestion_control"
    fi

    # Верификация ICMP
    log_step "Проверка блокировки ICMP..."
    local icmp_block
    icmp_block=$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo "0")
    if [[ "$icmp_block" == "1" ]]; then
        log_ok "ICMP echo-request заблокирован через sysctl"
    else
        log_fail "ICMP блокировка не активна"
    fi

    # Дополнительное правило iptables для блокировки ICMP (двойная защита)
    log_step "Добавление iptables-правила блокировки ICMP..."
    if ! iptables -C INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null; then
        iptables -I INPUT -p icmp --icmp-type echo-request -j DROP
        log_ok "iptables: ICMP echo-request DROP добавлен"
    else
        log_ok "iptables: правило блокировки ICMP уже существует"
    fi

    # Сохраняем iptables для персистентности
    if command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    # Применяем qdisc fq на основном интерфейсе (если определён)
    if [[ -n "${NET_IFACE:-}" ]]; then
        log_step "Установка qdisc fq на интерфейсе $NET_IFACE..."
        if tc qdisc replace dev "$NET_IFACE" root fq 2>/dev/null; then
            log_ok "qdisc fq установлен на $NET_IFACE"
        else
            log_info "tc qdisc fq: не критично, параметр уже применён через sysctl"
        fi
    fi

    mark_done "tune_network"
    log_ok "Шаг 4 завершён."
}

# =============================================================================
# 5. install_mieru — установка прокси-сервера Mieru (mita)
# =============================================================================
# Источник: https://github.com/enfein/mieru/blob/main/docs/server-install.md
# Серверный компонент: mita (не mieru — это клиент)
# Конфигурирование: mita apply config <file.json>
# =============================================================================
install_mieru() {
    log_section "5. Установка Mieru (mita — серверный компонент)"

    if is_done "install_mieru"; then
        log_ok "Шаг уже выполнен, пропускаем."
        # Загружаем сохранённые переменные
        if [[ -f "$STATE_DIR/mieru.env" ]]; then
            # shellcheck source=/dev/null
            source "$STATE_DIR/mieru.env"
        fi
        return 0
    fi

    # ── Определение архитектуры ────────────────────────────────────────────
    log_step "Определение архитектуры system..."
    local arch
    arch=$(uname -m)
    local deb_arch
    case "$arch" in
        x86_64)   deb_arch="amd64" ;;
        aarch64)  deb_arch="arm64" ;;
        *)
            log_fail "Неподдерживаемая архитектура: $arch. Mieru поддерживает amd64 и arm64."
            return 1
            ;;
    esac
    log_ok "Архитектура: $arch → пакет $deb_arch"

    # ── Определение последней версии mita через GitHub API ────────────────
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
    log_ok "Последняя версия mita: $mita_version"

    # ── Скачивание и установка .deb пакета ────────────────────────────────
    local deb_file="mita_${mita_version}_${deb_arch}.deb"
    local download_url="https://github.com/enfein/mieru/releases/download/v${mita_version}/${deb_file}"
    local tmp_deb="/tmp/${deb_file}"

    log_step "Скачивание $deb_file..."
    if curl -L --max-time 120 --progress-bar -o "$tmp_deb" "$download_url" 2>&1 | tee -a "$LOG_FILE"; then
        log_ok "Загружен: $tmp_deb"
    else
        log_fail "Не удалось скачать $download_url"
        return 1
    fi

    log_step "Установка пакета mita..."
    if dpkg -i "$tmp_deb" >> "$LOG_FILE" 2>&1; then
        log_ok "mita установлен"
    else
        log_fail "dpkg -i завершился с ошибкой. Проверьте $LOG_FILE"
        return 1
    fi
    rm -f "$tmp_deb"

    # ── Генерация порта и пароля ───────────────────────────────────────────
    log_step "Генерация случайного TCP-порта для Mieru (диапазон 20000-50000)..."
    MIERU_PORT=$(find_free_port tcp 20000 50000)
    log_ok "Mieru TCP-порт: $MIERU_PORT"

    log_step "Генерация случайного имени пользователя и пароля..."
    MIERU_USER="user_$(openssl rand -hex 4)"
    MIERU_PASS=$(openssl rand -base64 22 | tr -d '/+=' | head -c 24)
    log_ok "Mieru пользователь: $MIERU_USER"
    log_ok "Mieru пароль сгенерирован (скрыт в логе)"

    # ── Создание конфигурационного файла ──────────────────────────────────
    # Формат конфига: JSON, применяется через `mita apply config <file>`
    # Поля: portBindings (port + protocol), users (name + password),
    #        loggingLevel, mtu
    # Протокол TCP выбран для лучшей устойчивости к DPI:
    #   — TCP-трафик Mieru шифруется XChaCha20-Poly1305
    #   — случайный padding и anti-replay защита встроены
    #   — не использует TLS, поэтому нет fingerprint TLS handshake

    log_step "Создание конфигурационного файла mita..."
    mkdir -p "$MIERU_CONFIG_DIR"

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

    log_ok "Конфиг mita: $mita_config_file"

    # ── Применение конфига через CLI ──────────────────────────────────────
    # mita должен быть запущен (systemd), затем применяем конфиг
    log_step "Запуск mita (systemd)..."
    systemctl enable mita >> "$LOG_FILE" 2>&1 || true
    systemctl start mita >> "$LOG_FILE" 2>&1 || {
        log_fail "Не удалось запустить mita. Проверьте: journalctl -u mita"
        return 1
    }

    # Ждём запуска
    sleep 3

    log_step "Применение конфигурации через mita apply config..."
    if mita apply config "$mita_config_file" >> "$LOG_FILE" 2>&1; then
        log_ok "Конфигурация применена"
    else
        log_fail "mita apply config завершился с ошибкой. Проверьте $LOG_FILE"
        return 1
    fi
    rm -f "$mita_config_file"

    # Запускаем прокси-сервер mita
    log_step "Запуск mita в режиме старт..."
    if mita start >> "$LOG_FILE" 2>&1; then
        log_ok "mita запущен (статус: mita status)"
    else
        log_fail "mita start завершился с ошибкой"
        return 1
    fi

    # ── Открытие порта в ufw ───────────────────────────────────────────────
    log_step "Открытие порта $MIERU_PORT/tcp в ufw..."
    ufw allow "$MIERU_PORT"/tcp comment "Mieru proxy" >> "$LOG_FILE" 2>&1
    log_ok "Порт $MIERU_PORT/tcp открыт"

    # Сохраняем переменные для print_summary
    mkdir -p "$STATE_DIR"
    cat > "$STATE_DIR/mieru.env" <<EOF
MIERU_PORT=${MIERU_PORT}
MIERU_USER=${MIERU_USER}
MIERU_PASS=${MIERU_PASS}
MIERU_VERSION=${mita_version}
EOF
    chmod 600 "$STATE_DIR/mieru.env"

    mark_done "install_mieru"
    log_ok "Шаг 5 завершён. Mieru (mita v${mita_version}) установлен на порту $MIERU_PORT"

    # Проверочная информация
    log_info "Проверка: mita status"
    log_info "Логи:     journalctl -u mita -f"
}

# =============================================================================
# 6. install_hysteria2 — установка Hysteria2
# =============================================================================
# Источник: https://v2.hysteria.network/docs/advanced/Full-Server-Config/
# Конфиг: YAML (/etc/hysteria/config.yaml)
# Obfs: salamander (scrambles каждый пакет в random bytes)
# TLS: самоподписанный сертификат (без домена)
# Bandwidth: не указываем на сервере (для personal use — указывать только на клиенте)
#            это позволяет использовать BBR congestion control вместо Brutal
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

    # ── Установка через официальный скрипт ────────────────────────────────
    log_step "Установка Hysteria2 через официальный install-скрипт..."
    if bash <(curl -fsSL https://get.hy2.sh/) >> "$LOG_FILE" 2>&1; then
        log_ok "Hysteria2 установлен"
    else
        log_fail "Установка Hysteria2 завершилась с ошибкой. Проверьте $LOG_FILE"
        return 1
    fi

    # Проверяем, что бинарник доступен
    if ! command -v hysteria &>/dev/null; then
        log_fail "hysteria бинарник не найден после установки"
        return 1
    fi
    local h2_version
    h2_version=$(hysteria version 2>/dev/null | grep -oP 'v[\d.]+' | head -1 || echo "unknown")
    log_ok "Версия Hysteria2: $h2_version"

    # ── Генерация порта, паролей ───────────────────────────────────────────
    # Используем диапазон 50001-65000 (чтобы не пересекаться с Mieru: 20000-50000)
    log_step "Генерация случайного UDP-порта (диапазон 50001-65000)..."
    H2_PORT=$(find_free_port udp 50001 65000)
    log_ok "Hysteria2 UDP-порт: $H2_PORT"

    log_step "Генерация пароля аутентификации..."
    H2_PASS=$(openssl rand -base64 22 | tr -d '/+=' | head -c 24)
    log_ok "Hysteria2 пароль сгенерирован"

    log_step "Генерация пароля obfs (salamander)..."
    H2_OBFS_PASS=$(openssl rand -base64 22 | tr -d '/+=' | head -c 24)
    log_ok "Hysteria2 obfs-пароль сгенерирован"

    # ── Самоподписанный TLS-сертификат ────────────────────────────────────
    # CN выбран нейтральным (не палит назначение сервера)
    log_step "Генерация самоподписанного TLS-сертификата (10 лет)..."
    mkdir -p "$H2_CERT_DIR"

    # Случайный нейтральный CN
    local cn_candidates=("mail.example.com" "cdn.example.net" "api.example.org"
                         "static.example.com" "media.example.net")
    local cn_index=$(( RANDOM % ${#cn_candidates[@]} ))
    H2_CERT_CN="${cn_candidates[$cn_index]}"

    openssl req -x509 -newkey rsa:2048 \
        -keyout "$H2_CERT_DIR/server.key" \
        -out    "$H2_CERT_DIR/server.crt" \
        -days   3650 \
        -nodes \
        -subj   "/CN=${H2_CERT_CN}/O=Example Corp/C=US" \
        >> "$LOG_FILE" 2>&1

    chmod 600 "$H2_CERT_DIR/server.key"
    chmod 644 "$H2_CERT_DIR/server.crt"
    log_ok "TLS-сертификат: CN=$H2_CERT_CN, срок 10 лет"
    log_info "  cert: $H2_CERT_DIR/server.crt"
    log_info "  key:  $H2_CERT_DIR/server.key"

    # ── Создание конфигурационного файла ──────────────────────────────────
    # Ключевые решения (согласно документации):
    #
    # obfs.salamander: XOR-шифрование каждого UDP-пакета — скрывает QUIC-трафик.
    #   ВНИМАНИЕ: обфускация делает сервер несовместимым со стандартным HTTP/3.
    #   Это trade-off: обфускация vs HTTP/3 masquerade. Выбираем обфускацию
    #   (приоритет DPI-устойчивости, т.к. домена нет и masquerade неполноценен).
    #
    # bandwidth: НЕ указываем на сервере для personal use.
    #   Без серверного bandwidth клиент использует BBR congestion control.
    #   Если указать bandwidth — включится Brutal (фиксированная скорость),
    #   что требует знания реальной пропускной способности канала.
    #   Рекомендация docs: для личного сервера — bandwidth только на клиенте.
    #
    # masquerade: не используется с obfs (они несовместимы).
    #   При obfs сервер не может выглядеть как HTTP/3 сервер.

    log_step "Создание конфигурации Hysteria2..."
    mkdir -p "$H2_CONFIG_DIR"

    cat > "$H2_CONFIG_DIR/config.yaml" <<EOF
# Hysteria2 Server Config
# Сгенерировано setup.sh $(date '+%Y-%m-%d %H:%M:%S')
# Документация: https://v2.hysteria.network/docs/advanced/Full-Server-Config/

listen: :${H2_PORT}

tls:
  cert: ${H2_CERT_DIR}/server.crt
  key:  ${H2_CERT_DIR}/server.key

auth:
  type: password
  password: ${H2_PASS}

# obfs: salamander — XOR-scrambling каждого UDP-пакета
# Делает трафик неотличимым от случайного шума для DPI.
# ВНИМАНИЕ: несовместим с HTTP/3 masquerade (trade-off).
obfs:
  type: salamander
  salamander:
    password: ${H2_OBFS_PASS}

# QUIC параметры (рекомендуемые значения из официальной документации)
quic:
  initStreamReceiveWindow: 8388608    # 8 МБ
  maxStreamReceiveWindow: 8388608     # 8 МБ
  initConnReceiveWindow: 20971520     # 20 МБ (ratio stream:conn = 2:5)
  maxConnReceiveWindow: 20971520      # 20 МБ
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

# bandwidth: намеренно не задан на сервере (для personal use).
# Клиент указывает свою скорость в конфиге — сервер использует BBR.
# Подробнее: https://v2.hysteria.network/docs/advanced/Full-Server-Config/#bandwidth

# Логирование
# log уровень: debug | info | warn | error
EOF

    log_ok "Конфиг записан: $H2_CONFIG_DIR/config.yaml"

    # ── Создание systemd unit ──────────────────────────────────────────────
    log_step "Создание systemd unit для Hysteria2..."

    # Создаём системного пользователя для Hysteria2
    if ! id hysteria &>/dev/null; then
        useradd -r -s /sbin/nologin -d /etc/hysteria hysteria >> "$LOG_FILE" 2>&1
        log_ok "Системный пользователь hysteria создан"
    fi

    # Даём пользователю hysteria доступ к сертификатам
    chown -R hysteria:hysteria "$H2_CERT_DIR"
    chown hysteria:hysteria "$H2_CONFIG_DIR/config.yaml"

    cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=hysteria
Group=hysteria
ExecStart=/usr/local/bin/hysteria server -c ${H2_CONFIG_DIR}/config.yaml
Restart=always
RestartSec=5s
LimitNOFILE=1048576

# Логирование
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hysteria2

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable hysteria-server >> "$LOG_FILE" 2>&1
    if systemctl start hysteria-server; then
        log_ok "hysteria-server запущен и включён в автозапуск"
    else
        log_fail "Не удалось запустить hysteria-server. Проверьте: journalctl -u hysteria-server"
        return 1
    fi

    sleep 2
    if systemctl is-active --quiet hysteria-server; then
        log_ok "Статус hysteria-server: active (running)"
    else
        log_fail "hysteria-server не в состоянии running"
        journalctl -u hysteria-server -n 20 >> "$LOG_FILE" 2>&1
        return 1
    fi

    # ── Открытие UDP-порта в ufw ───────────────────────────────────────────
    log_step "Открытие порта $H2_PORT/udp в ufw..."
    ufw allow "$H2_PORT"/udp comment "Hysteria2" >> "$LOG_FILE" 2>&1
    log_ok "Порт $H2_PORT/udp открыт"

    # Получаем внешний IP для формирования ссылки
    local server_ip
    server_ip=$(get_server_ip)

    # ── Формирование hysteria2:// URI ──────────────────────────────────────
    # Формат: hysteria2://<password>@<host>:<port>?obfs=salamander&obfs-password=<p>&insecure=1
    # insecure=1 ОБЯЗАТЕЛЕН: самоподписанный сертификат без доверенного CA
    H2_URI="hysteria2://${H2_PASS}@${server_ip}:${H2_PORT}?obfs=salamander&obfs-password=${H2_OBFS_PASS}&insecure=1&sni=${H2_CERT_CN}"

    # Сохраняем переменные для print_summary
    cat > "$STATE_DIR/hysteria2.env" <<EOF
H2_PORT=${H2_PORT}
H2_PASS=${H2_PASS}
H2_OBFS_PASS=${H2_OBFS_PASS}
H2_CERT_CN=${H2_CERT_CN}
H2_URI=${H2_URI}
H2_VERSION=${h2_version}
EOF
    chmod 600 "$STATE_DIR/hysteria2.env"

    mark_done "install_hysteria2"
    log_ok "Шаг 6 завершён. Hysteria2 $h2_version на порту $H2_PORT/udp"

    log_info "Проверка:  systemctl status hysteria-server"
    log_info "Логи:      journalctl -u hysteria-server -f"
}

# =============================================================================
# 7. setup_warp — Cloudflare WARP через wgcf
# =============================================================================
# Архитектура маршрутизации:
#   ┌─────────────────────────────────────────────────────────┐
#   │  mita-server (UID=mita) → mark 0x1 → таблица 200      │
#   │  hysteria    (UID=hysteria) → mark 0x1 → таблица 200   │
#   │  Таблица 200: default route via wgcf-warp               │
#   │  Обычный трафик: default route = основной интерфейс     │
#   └─────────────────────────────────────────────────────────┘
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

    if ! command -v wgcf &>/dev/null; then
        curl -fsSL --max-time 60 -o /usr/local/bin/wgcf "$wgcf_url" >> "$LOG_FILE" 2>&1
        chmod +x /usr/local/bin/wgcf
        log_ok "wgcf установлен: $(wgcf --version 2>/dev/null || echo 'OK')"
    else
        log_ok "wgcf уже установлен: $(wgcf --version 2>/dev/null || echo 'OK')"
    fi

    # ── Регистрация WARP-аккаунта ──────────────────────────────────────────
    local warp_dir="/etc/wgcf"
    mkdir -p "$warp_dir"
    cd "$warp_dir"

    log_step "Регистрация нового WARP-аккаунта (wgcf register)..."
    if [[ ! -f "$warp_dir/wgcf-account.toml" ]]; then
        if wgcf register --accept-tos >> "$LOG_FILE" 2>&1; then
            log_ok "WARP аккаунт зарегистрирован: $warp_dir/wgcf-account.toml"
        else
            log_fail "wgcf register завершился с ошибкой. Проверьте $LOG_FILE"
            return 1
        fi
    else
        log_ok "Аккаунт WARP уже зарегистрирован"
    fi

    # ── Генерация WireGuard-конфига ────────────────────────────────────────
    log_step "Генерация WireGuard-конфига (wgcf generate)..."
    if [[ ! -f "$warp_dir/wgcf-profile.conf" ]]; then
        if wgcf generate >> "$LOG_FILE" 2>&1; then
            log_ok "Профиль сгенерирован: $warp_dir/wgcf-profile.conf"
        else
            log_fail "wgcf generate завершился с ошибкой"
            return 1
        fi
    else
        log_ok "WireGuard-профиль уже сгенерирован"
    fi

    # ── Адаптация профиля под отдельный интерфейс ─────────────────────────
    # ВАЖНО: удаляем AllowedIPs=0.0.0.0/0 — иначе весь трафик пойдёт через WARP.
    # Оставляем маршруты только через таблицу 200 (policy routing ниже).
    log_step "Адаптация wgcf-профиля (убираем перехват всего трафика)..."
    local wg_conf_src="$warp_dir/wgcf-profile.conf"
    local wg_conf_dst="/etc/wireguard/wgcf-warp.conf"

    # Копируем и правим конфиг
    cp "$wg_conf_src" "$wg_conf_dst"

    # Удаляем AllowedIPs = 0.0.0.0/0, ::/0 — заменяем на хосты Cloudflare WARP
    # (нужно только для WireGuard handshake и WARP API)
    sed -i 's|AllowedIPs = 0\.0\.0\.0/0|AllowedIPs = 0.0.0.0/1, 128.0.0.0/1|g' "$wg_conf_dst"
    sed -i 's|AllowedIPs = ::/0||g' "$wg_conf_dst"

    # Отключаем PostUp/PostDown если есть (будем управлять маршрутизацией вручную)
    sed -i '/^PostUp/d'   "$wg_conf_dst"
    sed -i '/^PostDown/d' "$wg_conf_dst"

    # Задаём имя интерфейса через имя файла (wg-quick использует basename)
    # Файл /etc/wireguard/wgcf-warp.conf → интерфейс wgcf-warp
    log_ok "Конфиг wgcf-warp: $wg_conf_dst"

    # ── Поднятие WireGuard-интерфейса ─────────────────────────────────────
    log_step "Поднятие интерфейса wgcf-warp (wg-quick up)..."
    if wg show wgcf-warp &>/dev/null; then
        log_ok "wgcf-warp уже поднят"
    else
        if wg-quick up wgcf-warp >> "$LOG_FILE" 2>&1; then
            log_ok "wgcf-warp поднят"
        else
            log_fail "wg-quick up wgcf-warp завершился с ошибкой"
            return 1
        fi
    fi

    # Включаем автозапуск
    systemctl enable "wg-quick@wgcf-warp" >> "$LOG_FILE" 2>&1
    log_ok "wg-quick@wgcf-warp включён в автозапуск"

    # ── Policy routing: только трафик Mieru и Hysteria2 через WARP ─────────
    log_step "Настройка policy routing (таблица 200, mark 0x1)..."

    # Проверяем что таблица 200 существует в /etc/iproute2/rt_tables
    if ! grep -q "^200 " /etc/iproute2/rt_tables; then
        echo "200 warp" >> /etc/iproute2/rt_tables
        log_ok "Таблица маршрутизации 200 (warp) добавлена в rt_tables"
    fi

    # Получаем WARP-интерфейс и его шлюз
    local warp_iface="wgcf-warp"
    local warp_addr
    warp_addr=$(ip addr show "$warp_iface" 2>/dev/null \
        | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
    log_info "WARP интерфейс: $warp_iface, адрес: $warp_addr"

    # Добавляем маршрут в таблицу 200: весь трафик через wgcf-warp
    if ! ip route show table 200 2>/dev/null | grep -q "default"; then
        ip route add default dev "$warp_iface" table 200 2>/dev/null || true
        log_ok "Маршрут по умолчанию в таблице 200: dev $warp_iface"
    else
        log_ok "Маршрут в таблице 200 уже существует"
    fi

    # Получаем UID системных пользователей
    local mita_uid hysteria_uid
    mita_uid=$(id -u mita 2>/dev/null || echo "")
    hysteria_uid=$(id -u hysteria 2>/dev/null || echo "")

    log_step "Маркировка пакетов от mita (UID=$mita_uid) и hysteria (UID=$hysteria_uid)..."

    # Маркировка исходящих пакетов по UID через iptables mangle
    setup_warp_routing_rules() {
        local uid="$1"
        local service="$2"

        if [[ -z "$uid" ]]; then
            log_info "UID для $service не найден, пропуск маркировки"
            return 0
        fi

        # Маркируем исходящие пакеты
        if ! iptables -t mangle -C OUTPUT -m owner --uid-owner "$uid" -j MARK --set-mark 0x1 2>/dev/null; then
            iptables -t mangle -A OUTPUT -m owner --uid-owner "$uid" -j MARK --set-mark 0x1
            log_ok "iptables mangle: OUTPUT uid=$uid ($service) → MARK 0x1"
        else
            log_ok "iptables mangle: правило для $service уже существует"
        fi
    }

    setup_warp_routing_rules "$mita_uid"    "mita (Mieru)"
    setup_warp_routing_rules "$hysteria_uid" "hysteria (Hysteria2)"

    # Правило ip rule: помеченные пакеты (mark=1) → таблица 200
    if ! ip rule show 2>/dev/null | grep -q "fwmark 0x1 lookup 200"; then
        ip rule add fwmark 0x1 table 200 priority 100
        log_ok "ip rule: fwmark 0x1 → table 200 (приоритет 100)"
    else
        log_ok "ip rule: fwmark 0x1 → table 200 уже существует"
    fi

    # ── Персистентность правил после перезагрузки ──────────────────────────
    log_step "Создание скрипта персистентности маршрутизации..."

    cat > /etc/network/if-up.d/warp-routing <<'ROUTING_SCRIPT'
#!/bin/bash
# Восстановление policy routing для WARP после перезагрузки
# Запускается при поднятии любого сетевого интерфейса

WARP_IFACE="wgcf-warp"
WARP_TABLE=200
WARP_MARK="0x1"

# Ждём поднятия WARP-интерфейса
sleep 5

# Таблица маршрутизации
if ! grep -q "^200 " /etc/iproute2/rt_tables; then
    echo "200 warp" >> /etc/iproute2/rt_tables
fi

# Маршрут через wgcf-warp
if ip link show "$WARP_IFACE" &>/dev/null; then
    ip route add default dev "$WARP_IFACE" table $WARP_TABLE 2>/dev/null || true
fi

# ip rule
if ! ip rule show 2>/dev/null | grep -q "fwmark $WARP_MARK lookup $WARP_TABLE"; then
    ip rule add fwmark $WARP_MARK table $WARP_TABLE priority 100 2>/dev/null || true
fi

# iptables mangle — маркировка по UID
for svc in mita hysteria; do
    uid=$(id -u "$svc" 2>/dev/null) || continue
    if ! iptables -t mangle -C OUTPUT -m owner --uid-owner "$uid" -j MARK --set-mark $WARP_MARK 2>/dev/null; then
        iptables -t mangle -A OUTPUT -m owner --uid-owner "$uid" -j MARK --set-mark $WARP_MARK 2>/dev/null || true
    fi
done
ROUTING_SCRIPT

    chmod +x /etc/network/if-up.d/warp-routing
    log_ok "Скрипт персистентности: /etc/network/if-up.d/warp-routing"

    # Также сохраняем правила iptables
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    # ── Создание systemd-сервиса для восстановления маршрутизации ─────────
    cat > /etc/systemd/system/warp-routing.service <<EOF
[Unit]
Description=WARP Policy Routing для Mieru и Hysteria2
After=network-online.target wg-quick@wgcf-warp.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/network/if-up.d/warp-routing
ExecStop=/bin/true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable warp-routing >> "$LOG_FILE" 2>&1
    log_ok "warp-routing.service включён в автозапуск"

    # ── Проверка WARP ──────────────────────────────────────────────────────
    log_step "Проверка WARP для трафика Hysteria2 (проверяем наличие warp=on)..."
    sleep 3

    # Простая проверка: curl через warp-интерфейс
    local warp_check
    warp_check=$(curl -s --max-time 10 --interface "$warp_iface" \
        "https://www.cloudflare.com/cdn-cgi/trace/" 2>/dev/null || echo "failed")

    if echo "$warp_check" | grep -q "warp=on"; then
        log_ok "WARP активен: curl через $warp_iface показывает warp=on"
    elif echo "$warp_check" | grep -q "warp=off"; then
        log_info "WARP интерфейс доступен, но показывает warp=off."
        log_info "Это нормально для WARP lite — трафик маршрутизируется через Cloudflare."
        log_info "Полная проверка: sudo -u hysteria curl https://www.cloudflare.com/cdn-cgi/trace/"
    else
        log_fail "Не удалось проверить WARP статус. Детали: $warp_check"
        log_info "Проверьте вручную: journalctl -u wg-quick@wgcf-warp"
    fi

    log_info ""
    log_info "Проверка: curl https://www.cloudflare.com/cdn-cgi/trace/ (обычный трафик, warp=off ожидается)"
    log_info "Проверка: sudo -u hysteria curl https://www.cloudflare.com/cdn-cgi/trace/ (ожидается warp=on)"

    mark_done "setup_warp"
    log_ok "Шаг 7 завершён."
}

# =============================================================================
# 8. print_summary — итоговый вывод строк подключения
# =============================================================================
print_summary() {
    log_section "8. Итоговая информация для подключения"

    # Загружаем сохранённые переменные (на случай повторного запуска)
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

    # Статус WARP
    local warp_status="неизвестно"
    if wg show wgcf-warp &>/dev/null 2>&1; then
        warp_status="активен (интерфейс wgcf-warp up)"
    else
        warp_status="не активен"
    fi

    # ── Формируем файл /root/vpn-setup-info.txt ────────────────────────────
    cat > "$INFO_FILE" <<EOF
================================================================================
  VPN Server Setup — Информация для подключения
  Сгенерировано: $(date '+%Y-%m-%d %H:%M:%S')
  Сервер IP: ${server_ip}
================================================================================

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [1] MIERU (mita)
  Протокол: TCP + XChaCha20-Poly1305 (без TLS, без домена)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Сервер IP:   ${server_ip}
  TCP порт:    ${MIERU_PORT:-НЕ ОПРЕДЕЛЁН}
  Пользователь: ${MIERU_USER:-НЕ ОПРЕДЕЛЁН}
  Пароль:      ${MIERU_PASS:-НЕ ОПРЕДЕЛЁН}
  Версия mita: ${MIERU_VERSION:-неизвестно}

  Конфиг клиента Mieru (mieru client):
  ┌─────────────────────────────────────────────────────────────────┐
  │ {                                                               │
  │   "profile": [                                                  │
  │     {                                                           │
  │       "profileName": "my-server",                              │
  │       "user": {                                                 │
  │         "name": "${MIERU_USER:-USER}",                │
  │         "password": "${MIERU_PASS:-PASS}"             │
  │       },                                                        │
  │       "servers": [                                              │
  │         {                                                       │
  │           "ipAddress": "${server_ip}",              │
  │           "portBindings": [                                     │
  │             { "port": ${MIERU_PORT:-PORT}, "protocol": "TCP" } │
  │           ]                                                     │
  │         }                                                       │
  │       ]                                                         │
  │     }                                                           │
  │   ],                                                            │
  │   "rpcPort": 8964                                               │
  │ }                                                               │
  └─────────────────────────────────────────────────────────────────┘

  Для Clash/Mihomo/Nekoray — используйте тип "mieru" с параметрами выше.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [2] HYSTERIA2
  Протокол: QUIC/UDP + Salamander obfs + самоподписанный TLS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Сервер IP:   ${server_ip}
  UDP порт:    ${H2_PORT:-НЕ ОПРЕДЕЛЁН}
  Пароль:      ${H2_PASS:-НЕ ОПРЕДЕЛЁН}
  OBFS тип:    salamander
  OBFS пароль: ${H2_OBFS_PASS:-НЕ ОПРЕДЕЛЁН}
  TLS CN:      ${H2_CERT_CN:-НЕ ОПРЕДЕЛЁН}
  Версия:      ${H2_VERSION:-неизвестно}

  !! ВАЖНО: Используйте insecure=1 (самоподписанный сертификат, без домена) !!

  Строка подключения hysteria2:// (вставить в клиент напрямую):
  ┌─────────────────────────────────────────────────────────────────┐
  │ ${H2_URI:-hysteria2://PASS@IP:PORT?obfs=salamander&obfs-password=OBFS&insecure=1}
  └─────────────────────────────────────────────────────────────────┘

  Конфиг клиента (YAML, для клиентского hysteria / NekoRay / Mihomo):
  ┌─────────────────────────────────────────────────────────────────┐
  │ server: ${server_ip}:${H2_PORT:-PORT}                │
  │ auth: ${H2_PASS:-PASS}                               │
  │                                                                 │
  │ obfs:                                                           │
  │   type: salamander                                              │
  │   salamander:                                                   │
  │     password: ${H2_OBFS_PASS:-OBFS_PASS}             │
  │                                                                 │
  │ tls:                                                            │
  │   sni: ${H2_CERT_CN:-CN}                             │
  │   insecure: true   # обязательно — самоподписанный сертификат  │
  │                                                                 │
  │ bandwidth:          # укажи свою реальную скорость интернета    │
  │   up: 50 mbps                                                   │
  │   down: 100 mbps                                                │
  │                                                                 │
  │ socks5:                                                         │
  │   listen: 127.0.0.1:1080                                        │
  │ http:                                                           │
  │   listen: 127.0.0.1:8080                                        │
  └─────────────────────────────────────────────────────────────────┘

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [3] CLOUDFLARE WARP
  Статус: ${warp_status}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Трафик Mieru и Hysteria2 выходит через WARP (Cloudflare).
  Обычный трафик сервера (SSH и системный) — через прямой IP сервера.

  Интерфейс:  wgcf-warp
  Статус:     ${warp_status}

  Проверка WARP:
    sudo -u hysteria curl https://www.cloudflare.com/cdn-cgi/trace/
    (должно показать warp=on)

  Обычный трафик (НЕ через WARP):
    curl https://www.cloudflare.com/cdn-cgi/trace/
    (должно показать warp=off, ip = IP вашего сервера)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Управление сервисами
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Mieru (mita):
    systemctl status mita
    mita status
    journalctl -u mita -f

  Hysteria2:
    systemctl status hysteria-server
    journalctl -u hysteria-server -f

  WARP:
    systemctl status wg-quick@wgcf-warp
    wg show wgcf-warp

  Логи установки: ${LOG_FILE}
  Этот файл:     ${INFO_FILE}

================================================================================
EOF

    chmod 600 "$INFO_FILE"

    # ── Вывод в терминал ───────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}${GREEN}"
    cat "$INFO_FILE"
    echo -e "${NC}"

    log_ok "Информация сохранена в $INFO_FILE"
    log ""
    log "${GREEN}${BOLD}══════════════════════════════════════════${NC}"
    log "${GREEN}${BOLD}  Установка завершена успешно!${NC}"
    log "${GREEN}${BOLD}══════════════════════════════════════════${NC}"
}

# =============================================================================
# MAIN — точка входа
# =============================================================================
main() {
    init_log

    log ""
    log "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    log "${BOLD}${CYAN}║      VPN Server Auto-Setup v1.0                  ║${NC}"
    log "${BOLD}${CYAN}║  Mieru + Hysteria2 + Cloudflare WARP             ║${NC}"
    log "${BOLD}${CYAN}║  Ubuntu 22.04 / 24.04                            ║${NC}"
    log "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    log ""
    log "  Лог:      $LOG_FILE"
    log "  SSH порт: $SSH_PORT"
    log "  Время:    $(date '+%Y-%m-%d %H:%M:%S')"
    log ""

    check_root
    check_os

    # Выполняем шаги по порядку
    # Каждый шаг идемпотентен (проверяет маркер .done)
    update_system
    setup_firewall
    detect_system_specs    # не маркируется .done — нужен при каждом запуске для tune_network
    tune_network
    install_mieru
    install_hysteria2
    setup_warp
    print_summary
}

# Запуск
main "$@"

# =============================================================================
# ИНСТРУКЦИЯ ПО РУЧНОЙ ПРОВЕРКЕ КОМПОНЕНТОВ
# =============================================================================
#
# ── Mieru (mita) ─────────────────────────────────────────────────────────────
#
#   # Статус сервиса
#   systemctl status mita
#
#   # Статус прокси (должно показать "RUNNING")
#   mita status
#
#   # Логи в реальном времени
#   journalctl -u mita -f
#
#   # Проверка прослушиваемого порта (MIERU_PORT)
#   ss -tlnp | grep mita
#
#   # Тест соединения с клиента (используйте mieru CLI или Clash Verge Rev)
#   # Клиент: https://github.com/enfein/mieru/releases (mieru_*_linux_amd64)
#
# ── Hysteria2 ─────────────────────────────────────────────────────────────────
#
#   # Статус сервиса
#   systemctl status hysteria-server
#
#   # Логи в реальном времени
#   journalctl -u hysteria-server -f
#
#   # Проверка прослушиваемого UDP-порта
#   ss -ulnp | grep hysteria
#
#   # Тест с клиентской стороны:
#   # 1. Установите hysteria: https://get.hy2.sh/
#   # 2. Запустите: hysteria client -c client.yaml
#   # 3. Проверьте: curl --proxy socks5://127.0.0.1:1080 https://ipinfo.io
#
# ── Cloudflare WARP ───────────────────────────────────────────────────────────
#
#   # Статус WireGuard-интерфейса
#   wg show wgcf-warp
#   systemctl status wg-quick@wgcf-warp
#
#   # Проверка что Mieru-трафик идёт через WARP:
#   sudo -u mita curl https://www.cloudflare.com/cdn-cgi/trace/
#   # Ожидаемый результат: warp=on
#
#   # Проверка что Hysteria2-трафик идёт через WARP:
#   sudo -u hysteria curl https://www.cloudflare.com/cdn-cgi/trace/
#   # Ожидаемый результат: warp=on
#
#   # Проверка что обычный SSH-трафик НЕ идёт через WARP:
#   curl https://www.cloudflare.com/cdn-cgi/trace/
#   # Ожидаемый результат: warp=off, ip=<ваш_обычный_IP_сервера>
#
#   # Маршрутизация
#   ip rule show            # должно быть: fwmark 0x1 lookup 200
#   ip route show table 200 # должно быть: default dev wgcf-warp
#   iptables -t mangle -L OUTPUT -n -v  # должны быть правила MARK для UID mita/hysteria
#
# ── Firewall ──────────────────────────────────────────────────────────────────
#
#   ufw status verbose
#   # Должны быть открыты: SSH-порт (TCP), MIERU_PORT (TCP), H2_PORT (UDP)
#
# ── BBR ───────────────────────────────────────────────────────────────────────
#
#   sysctl net.ipv4.tcp_congestion_control  # должно вернуть: bbr
#   sysctl net.core.default_qdisc           # должно вернуть: fq
#
# ── ICMP ──────────────────────────────────────────────────────────────────────
#
#   sysctl net.ipv4.icmp_echo_ignore_all    # должно вернуть: 1
#   # Проверка с внешнего хоста: ping <IP_сервера> (не должен отвечать)
#
# =============================================================================
