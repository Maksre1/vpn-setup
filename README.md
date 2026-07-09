# VPS VPN Setup: Mieru + Hysteria 2 + Cloudflare WARP

Автоматический скрипт для настройки личного VPN-сервера на Ubuntu / Debian / Rocky Linux с поддержкой современных, устойчивых к блокировкам протоколов и сплит-маршрутизацией исходящего трафика через Cloudflare WARP.

## Возможности

1. **Оптимизация сети:** вычисление буферов `sysctl` под RAM и ядра CPU, TCP BBR + `fq`, TCP Fast Open, MTU Probing.
2. **Безопасность:** UFW (закрыты все порты кроме SSH и VPN), ICMP-block, fail2ban, SSH только по ключам.
3. **Mieru (mita):** DPI-устойчивый протокол с поддержкой **TCP + UDP** транспорта.
4. **Hysteria 2:** QUIC-протокол с обфускацией `salamander`, **ECDSA-сертификатами** и QUIC-буферами, масштабируемыми под RAM.
5. **Cloudflare WARP:** сплит-маршрутизация VPN-трафика через WARP (SSH идёт напрямую).
6. **Безопасная подписка:** URL для подписки генерируется как рандомный хеш (например, `http://IP:8080/a1b2c3d4e5f6...`), чтобы нельзя было перебрать ссылку.
7. **Многопользовательность:** добавление/удаление пользователей через `--add-user` / `--remove-user`.

## Требования

* **ОС:** Ubuntu 22.04/24.04, Debian, Rocky Linux, CentOS, AlmaLinux
* **Права:** root
* **SSH-порт:** 22 (или кастомный через `SSH_PORT`)

## Быстрый запуск

```bash
curl -fsSL https://raw.githubusercontent.com/Maksre1/vpn-setup/main/setup.sh -o setup.sh && sudo bash setup.sh
```

### Кастомный SSH-порт

```bash
SSH_PORT=2222 sudo -E bash setup.sh
```

## Управление

### Статус сервисов

```bash
sudo bash setup.sh --status
```

### Добавить пользователя

```bash
sudo bash setup.sh --add-user myuser
```

### Удалить пользователя

```bash
sudo bash setup.sh --remove-user myuser
```

### Полное удаление VPN-сервера

```bash
sudo bash setup.sh --uninstall
```

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

* **Mieru:** `systemctl status mita`
* **Hysteria 2:** `systemctl status hysteria-server`
* **WARP:** `wg show wgcf-warp`
* **fail2ban:** `systemctl status fail2ban`

---
*Дисклеймер: Скрипт предоставляется "как есть" (As Is). Вы используете его на свой страх и риск.*
