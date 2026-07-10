"""Модели данных — SQLite + интеграция с vpn-users.conf"""
import sqlite3
import os
from datetime import datetime, date

DB_PATH = "/etc/vpn-panel/panel.db"
STATE_DIR = "/etc/vpn-setup-state"


def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = get_db()
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS admin (
            id INTEGER PRIMARY KEY,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password TEXT NOT NULL,
            expire_date TEXT DEFAULT 'never',
            traffic_limit_gb INTEGER DEFAULT 0,
            speed_limit_mbps INTEGER DEFAULT 0,
            protocol TEXT DEFAULT 'all',
            sub_path TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            is_active INTEGER DEFAULT 1
        );
    """)
    conn.commit()
    conn.close()


def load_env(path):
    """Загрузить .env файл в dict."""
    data = {}
    if not os.path.exists(path):
        return data
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, _, val = line.partition("=")
                val = val.strip().strip('"').strip("'")
                data[key.strip()] = val
    return data


def get_mieru_config():
    return load_env(f"{STATE_DIR}/mieru.env")


def get_hysteria2_config():
    return load_env(f"{STATE_DIR}/hysteria2.env")


def get_subscription_paths():
    return load_env(f"{STATE_DIR}/subscription_path")


def get_server_ip():
    import subprocess
    for url in ["https://api.ipify.org", "https://ifconfig.me", "https://icanhazip.com"]:
        try:
            r = subprocess.run(["curl", "-s", "--max-time", "5", url],
                               capture_output=True, text=True, timeout=8)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip()
        except Exception:
            continue
    return "UNKNOWN"


def get_server_specs():
    specs = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if "MemTotal" in line:
                    specs["ram_mb"] = int(line.split()[1]) // 1024
                    break
    except Exception:
        specs["ram_mb"] = 0
    try:
        with open("/proc/loadavg") as f:
            specs["load"] = f.read().strip().split()[:3]
    except Exception:
        specs["load"] = ["0", "0", "0"]
    try:
        specs["cpu_cores"] = os.cpu_count() or 0
    except Exception:
        specs["cpu_cores"] = 0
    try:
        r = subprocess.run(["uname", "-r"], capture_output=True, text=True, timeout=5)
        specs["kernel"] = r.stdout.strip()
    except Exception:
        specs["kernel"] = "unknown"
    try:
        r = subprocess.run(["uptime", "-p"], capture_output=True, text=True, timeout=5)
        specs["uptime"] = r.stdout.strip()
    except Exception:
        specs["uptime"] = "unknown"
    return specs


def get_service_status(name):
    import subprocess
    try:
        r = subprocess.run(
            ["systemctl", "is-active", name],
            capture_output=True, text=True, timeout=5
        )
        return r.stdout.strip() == "active"
    except Exception:
        return False


def get_all_service_statuses():
    services = {
        "Mieru (mita)": "mita",
        "Hysteria2": "hysteria-server",
        "Cloudflare WARP": "wg-quick@wgcf-warp",
        "fail2ban": "fail2ban",
        "VPN Panel": "vpn-panel",
        "Subscription Server": "vpn-sub",
    }
    result = {}
    for display_name, unit in services.items():
        result[display_name] = get_service_status(unit)
    return result


def restart_service(name):
    import subprocess
    r = subprocess.run(
        ["systemctl", "restart", name],
        capture_output=True, text=True, timeout=30
    )
    return r.returncode == 0


def get_logs(service, lines=50):
    import subprocess
    unit_map = {
        "mieru": "mita",
        "hysteria": "hysteria-server",
        "warp": "wg-quick@wgcf-warp",
        "fail2ban": "fail2ban",
        "panel": "vpn-panel",
    }
    unit = unit_map.get(service, service)
    r = subprocess.run(
        ["journalctl", "-u", unit, "--no-pager", "-n", str(lines), "--output=short-iso"],
        capture_output=True, text=True, timeout=10
    )
    return r.stdout


def sync_user_to_conf(user_row):
    """Синхронизация пользователя из SQLite в vpn-users.conf."""
    conf_path = f"{STATE_DIR}/vpn-users.conf"
    lines = []
    if os.path.exists(conf_path):
        with open(conf_path) as f:
            lines = [l.strip() for l in f if l.strip()]

    username = user_row["username"]
    new_line = f"{username}|{user_row['password']}|{user_row['expire_date']}|{user_row['traffic_limit_gb']}|{user_row['speed_limit_mbps']}|{user_row['protocol']}"

    updated = False
    for i, line in enumerate(lines):
        if line.startswith(f"{username}|"):
            lines[i] = new_line
            updated = True
            break
    if not updated:
        lines.append(new_line)

    os.makedirs(STATE_DIR, exist_ok=True)
    with open(conf_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(conf_path, 0o600)


def remove_user_from_conf(username):
    conf_path = f"{STATE_DIR}/vpn-users.conf"
    if not os.path.exists(conf_path):
        return
    with open(conf_path) as f:
        lines = [l.strip() for l in f if l.strip()]
    lines = [l for l in lines if not l.startswith(f"{username}|")]
    with open(conf_path, "w") as f:
        f.write("\n".join(lines) + "\n" if lines else "")


def update_mieru_users():
    """Пересобрать конфиг mita со всеми пользователями из БД."""
    import subprocess, json
    mieru = get_mieru_config()
    if not mieru.get("MIERU_PORT"):
        return

    conn = get_db()
    users = conn.execute("SELECT username, password FROM users WHERE is_active=1").fetchall()
    conn.close()

    users_json = [{"name": u["username"], "password": u["password"]} for u in users]

    config = {
        "portBindings": [
            {"port": int(mieru["MIERU_PORT"]), "protocol": "TCP"},
            {"port": int(mieru.get("MIERU_UDP_PORT", mieru["MIERU_PORT"])), "protocol": "UDP"}
        ],
        "users": users_json,
        "loggingLevel": "WARN",
        "mtu": 1400
    }

    config_path = "/tmp/mita_panel_config.json"
    with open(config_path, "w") as f:
        json.dump(config, f)

    subprocess.run(["mita", "apply", "config", config_path],
                   capture_output=True, timeout=10)
    os.remove(config_path)
    subprocess.run(["systemctl", "restart", "mita"],
                   capture_output=True, timeout=15)
