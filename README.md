# VPS VPN Setup: Mieru + Hysteria 2 + Xray + NaiveProxy + Cloudflare WARP

Автоматический скрипт для настройки личного VPN-сервера на Ubuntu / Debian / Rocky Linux.

## Компоненты

- **Mieru (mita)** — DPI-устойчивый протокол, TCP + UDP
- **Hysteria 2** — QUIC-протокол с обфускацией salamander, ECDSA-сертификаты
- **Xray-core** — VLESS/Reality, Trojan, Shadowsocks
- **NaiveProxy** — HTTPS forward proxy через Caddy
- **Cloudflare WARP** — сплит-маршрутизация VPN-трафика
- **VPN Panel** — Go веб-интерфейс для управления пользователями

## Требования

- Ubuntu 22.04/24.04, Debian 11/12, Rocky Linux
- Root-доступ
- SSH-порт 22 (или кастомный через `SSH_PORT`)

## Быстрый запуск

```bash
curl -fsSL https://raw.githubusercontent.com/Maksre1/vpn-setup/main/setup.sh -o setup.sh && sudo bash setup.sh
```

### Кастомный SSH-порт

```bash
SSH_PORT=2222 sudo -E bash setup.sh
```

## Управление

```bash
# Статус всех сервисов
sudo bash setup.sh --status

# Добавить пользователя
sudo bash setup.sh --add-user myuser

# Удалить пользователя
sudo bash setup.sh --remove-user myuser

# Ключи и ссылки панели
sudo bash setup.sh --keys

# Полное удаление
sudo bash setup.sh --uninstall
```

## Веб-панель

После установки панель доступна по адресу `https://IP:ПОРТ` (порт рандомный, выводится в конце установки).

Управление: пользователи, ключи, логи, настройки, рестарт сервисов.

## Проверка после установки

### WARP (сплит-маршрутизация)

```bash
# Прямой IP (должен быть IP сервера)
curl https://www.cloudflare.com/cdn-cgi/trace/ | grep warp
# Ожидается: warp=off

# Через WARP (от имени hysteria)
sudo -u hysteria curl https://www.cloudflare.com/cdn-cgi/trace/ | grep warp
# Ожидается: warp=on
```

### Статус сервисов

- **Mieru:** `systemctl status mita`
- **Hysteria 2:** `systemctl status hysteria-server`
- **Xray:** `systemctl status xray`
- **NaiveProxy:** `systemctl status caddy-naive`
- **WARP:** `wg show wgcf-warp`
- **Panel:** `systemctl status vpn-panel`

---

*Дисклеймер: Скрипт предоставляется "как есть" (As Is).*
