#!/usr/bin/env bash
# =============================================================================
# update.sh — Обновление VPN Setup и панели
# Использование: bash update.sh [опции]
#   -y, --yes        Не задавать вопросов
#   --dry-run        Показать что будет сделано без выполнения
#   --force          Принудительное обновление без проверки версий
#   --status         Показать состояние установки
#   --repair         Восстановить сломанную установку
#   --help           Справка
# =============================================================================
set -euo pipefail

REPO="Maksre1/vpn-setup"
BRANCH="main"
STATE_DIR="/etc/vpn-setup-state"
PANEL_DIR="/opt/vpn-panel"
PANEL_STATE="/etc/vpn-panel"
BACKUP_DIR="/etc/vpn-setup-state/backups"
VERSION_FILE="/etc/vpn-setup-state/version"
SCRIPT_PATH="/usr/local/bin/vpn-setup"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

YES=false
DRY_RUN=false
FORCE=false
ACTION="update"

# ── Парсинг аргументов ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)       YES=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --force)        FORCE=true; shift ;;
        --status)       ACTION="status"; shift ;;
        --repair)       ACTION="repair"; shift ;;
        --help|-h)
            echo "Использование: bash update.sh [опции]"
            echo "  -y, --yes        Без вопросов"
            echo "  --dry-run        Предпросмотр без выполнения"
            echo "  --force          Принудительное обновление"
            echo "  --status         Состояние установки"
            echo "  --repair         Восстановление"
            echo "  --help           Справка"
            exit 0
            ;;
        *) echo "Неизвестный опция: $1"; exit 1 ;;
    esac
done

# ── Утилиты ─────────────────────────────────────────────────────────────────
info()    { printf "  ${CYAN}ℹ${NC}  %s\n" "$1"; }
ok()      { printf "  ${GREEN}✔${NC}  %s\n" "$1"; }
warn()    { printf "  ${YELLOW}!${NC}  %s\n" "$1"; }
fail()    { printf "  ${RED}✗${NC}  %s\n" "$1"; }

confirm() {
    if $YES; then return 0; fi
    read -rp "  Продолжить? [y/N] " ans
    [[ "$ans" =~ ^[yY] ]]
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        fail "Запустите от root: sudo bash update.sh $*"
        exit 1
    fi
}

get_server_ip() {
    curl -s --max-time 5 https://api.ipify.org \
        || curl -s --max-time 5 https://ifconfig.me \
        || echo "UNKNOWN"
}

# ── STATUS ───────────────────────────────────────────────────────────────────
do_status() {
    printf "\n  ${BOLD}${CYAN}VPN Setup — Состояние${NC}\n"
    printf "  %s\n\n" "──────────────────────────────────────────────────────────"

    # Версия
    if [[ -f "$VERSION_FILE" ]]; then
        info "Установленная версия: $(cat "$VERSION_FILE")"
    else
        warn "Версия не определена"
    fi

    # Проверка обновлений
    local remote_ver
    remote_ver=$(curl -fsSL "https://raw.githubusercontent.com/${REPO}/${BRANCH}/VERSION" 2>/dev/null || echo "unknown")
    if [[ "$remote_ver" != "unknown" && -f "$VERSION_FILE" ]]; then
        if [[ "$remote_ver" == "$(cat "$VERSION_FILE")" ]]; then
            ok "Последняя версия: $remote_ver"
        else
            warn "Доступно обновление: $remote_ver (установлена: $(cat "$VERSION_FILE"))"
        fi
    fi

    # Сервисы
    printf "\n  ${BOLD}Сервисы:${NC}\n"
    for svc in mita hysteria-server "wg-quick@wgcf-warp" fail2ban vpn-panel vpn-sub; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            ok "$svc"
        else
            warn "$svc (остановлен)"
        fi
    done

    # Панель
    if [[ -f "$STATE_DIR/panel.env" ]]; then
        source "$STATE_DIR/panel.env"
        local pass_file="$PANEL_STATE/admin_password.txt"
        local pass=""
        [[ -f "$pass_file" ]] && pass=$(grep "admin:" "$pass_file" | cut -d: -f2)
        printf "\n  ${BOLD}Панель:${NC}\n"
        info "Порт: ${PANEL_PORT:-?}"
        info "Пароль: ${pass:-не найден}"
    fi

    # Пользователи
    if [[ -f "$STATE_DIR/vpn-users.conf" ]]; then
        local count
        count=$(grep -c "." "$STATE_DIR/vpn-users.conf" 2>/dev/null || echo 0)
        printf "\n  ${BOLD}Пользователи:${NC} %s\n" "$count"
    fi

    # Порты
    printf "\n  ${BOLD}Порты:${NC}\n"
    [[ -f "$STATE_DIR/mieru.env" ]] && source "$STATE_DIR/mieru.env"
    [[ -f "$STATE_DIR/hysteria2.env" ]] && source "$STATE_DIR/hysteria2.env"
    info "Mieru TCP: ${MIERU_PORT:-?}  UDP: ${MIERU_UDP_PORT:-?}"
    info "Hysteria2: ${H2_PORT:-?}"
    info "Panel: ${PANEL_PORT:-?}"
    info "Subscription: 8080"

    printf "\n"
}

# ── BACKUP ───────────────────────────────────────────────────────────────────
do_backup() {
    mkdir -p "$BACKUP_DIR"
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/backup_${ts}.tar.gz"

    info "Создание бэкапа..."
    tar czf "$backup_file" \
        -C / \
        etc/vpn-setup-state/ \
        etc/vpn-panel/ \
        opt/vpn-panel/ \
        2>/dev/null || true

    # Храним последние 10 бэкапов
    local count
    count=$(ls -1 "$BACKUP_DIR"/backup_*.tar.gz 2>/dev/null | wc -l)
    if [[ "$count" -gt 10 ]]; then
        ls -1t "$BACKUP_DIR"/backup_*.tar.gz | tail -n +11 | xargs rm -f
    fi

    ok "Бэкап: $backup_file"
}

# ── UPDATE ───────────────────────────────────────────────────────────────────
do_update() {
    printf "\n  ${BOLD}${CYAN}VPN Setup — Обновление${NC}\n"
    printf "  %s\n\n" "──────────────────────────────────────────────────────────"

    # Проверка текущей версии
    local current_ver="unknown"
    [[ -f "$VERSION_FILE" ]] && current_ver=$(cat "$VERSION_FILE")

    local remote_ver
    remote_ver=$(curl -fsSL "https://raw.githubusercontent.com/${REPO}/${BRANCH}/VERSION" 2>/dev/null || echo "unknown")

    if [[ "$remote_ver" == "unknown" ]]; then
        fail "Не удалось получить версию из GitHub"
        exit 1
    fi

    info "Текущая версия: $current_ver"
    info "Удалённая версия: $remote_ver"

    if [[ "$current_ver" == "$remote_ver" && "$FORCE" != "true" ]]; then
        ok "Уже последняя версия. Используйте --force для принудительного обновления."
        return 0
    fi

    if $DRY_RUN; then
        info "[DRY-RUN] Будут обновлены:"
        info "  - setup.sh → $SCRIPT_PATH"
        info "  - panel/ → $PANEL_DIR/"
        info "  - VERSION → $VERSION_FILE"
        return 0
    fi

    if ! $YES; then
        info "Будет обновлено: $current_ver → $remote_ver"
        confirm || return 0
    fi

    # Бэкап перед обновлением
    do_backup

    # Скачиваем обновления
    local tmp_dir
    tmp_dir=$(mktemp -d)
    info "Скачивание файлов..."
    curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" \
        -o "$tmp_dir/update.tar.gz" 2>/dev/null

    if [[ ! -s "$tmp_dir/update.tar.gz" ]]; then
        fail "Не удалось скачать обновление"
        rm -rf "$tmp_dir"
        exit 1
    fi

    tar xzf "$tmp_dir/update.tar.gz" -C "$tmp_dir" 2>/dev/null
    local src_dir="$tmp_dir/vpn-setup-${BRANCH}"

    # Обновляем setup.sh
    if [[ -f "$src_dir/setup.sh" ]]; then
        cp "$src_dir/setup.sh" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        ok "setup.sh обновлён"
    fi

    # Обновляем панель
    mkdir -p "$PANEL_DIR"
    curl -fsSL "https://raw.githubusercontent.com/${REPO}/${BRANCH}/panel_go/vpn-panel" -o "$PANEL_DIR/vpn-panel" 2>/dev/null || true
    curl -fsSL "https://raw.githubusercontent.com/${REPO}/${BRANCH}/panel_go/vpn-sub" -o "$PANEL_DIR/vpn-sub" 2>/dev/null || true
    chmod +x "$PANEL_DIR/vpn-panel" "$PANEL_DIR/vpn-sub" 2>/dev/null || true
    ok "Панель обновлена"

    # Сохраняем версию
    echo "$remote_ver" > "$VERSION_FILE"

    # Перезапуск сервисов
    info "Перезапуск сервисов..."
    systemctl restart vpn-panel 2>/dev/null || true

    rm -rf "$tmp_dir"
    ok "Обновление завершено: $remote_ver"
}

# ── REPAIR ───────────────────────────────────────────────────────────────────
do_repair() {
    printf "\n  ${BOLD}${CYAN}VPN Setup — Восстановление${NC}\n"
    printf "  %s\n\n" "──────────────────────────────────────────────────────────"

    if ! $YES; then
        info "Будет.perform проверка и восстановление компонентов"
        confirm || return 0
    fi

    # 1. Проверяем файлы панели
    info "Проверка файлов панели..."
    local missing=0
    if [[ ! -f "$PANEL_DIR/vpn-panel" || ! -f "$PANEL_DIR/vpn-sub" ]]; then
        warn "Отсутствуют бинарные файлы панели"
        missing=1
    fi

    if [[ "$missing" -eq 1 ]]; then
        info "Скачивание недостающих файлов..."
        do_update
    fi

    # 4. Проверяем systemd
    info "Проверка systemd-юнитов..."
    for unit in vpn-panel hysteria-server mita; do
        if [[ -f "/etc/systemd/system/${unit}.service" ]]; then
            systemctl daemon-reload 2>/dev/null
            systemctl enable "$unit" 2>/dev/null || true
            if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
                warn "$unit не активен. Перезапуск..."
                systemctl restart "$unit" 2>/dev/null || true
            fi
        fi
    done

    # 5. Проверяем UFW
    info "Проверка файрвола..."
    if [[ -f "$STATE_DIR/panel.env" ]]; then
        source "$STATE_DIR/panel.env"
        if ! ufw status | grep -q "${PANEL_PORT}"; then
            warn "Порт панели ($PANEL_PORT) не открыт в UFW"
            ufw allow "${PANEL_PORT}/tcp" comment "VPN Panel" 2>/dev/null || true
        fi
    fi

    # 6. Проверяем пароль
    if [[ ! -f "$PANEL_STATE/admin_password.txt" ]]; then
        warn "Файл пароля отсутствует. Генерация..."
        mkdir -p "$PANEL_STATE"
        local pass
        pass=$(openssl rand -base64 18 | tr -d '/+=' | head -c 16)
        echo "admin:${pass}" > "$PANEL_STATE/admin_password.txt"
        chmod 600 "$PANEL_STATE/admin_password.txt"
        ok "Новый пароль: $pass"
    fi

    ok "Восстановление завершено"
}

# ── MAIN ─────────────────────────────────────────────────────────────────────
check_root

case "$ACTION" in
    update)  do_update ;;
    status)  do_status ;;
    repair)  do_repair ;;
esac
