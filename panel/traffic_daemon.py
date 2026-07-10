import time
import subprocess
import json
import requests
import threading
from models import get_db, sync_all_users_to_configs

def get_h2_traffic():
    """Запросить статистику трафика с API Hysteria2."""
    headers = {"Authorization": "hysteria_stats_secret"}
    try:
        r = requests.get("http://127.0.0.1:25413/traffic", headers=headers, timeout=5)
        if r.status_code == 200:
            return r.json()
    except Exception:
        pass
    return {}

def get_mieru_traffic():
    """Запросить статистику трафика Mieru через CLI."""
    try:
        res = subprocess.run(["mita", "get", "metrics"], capture_output=True, text=True, timeout=5)
        if res.returncode == 0:
            metrics = json.loads(res.stdout)
            return metrics.get("users", {})
    except Exception:
        pass
    return {}

def run_traffic_accounting():
    """Основной цикл опроса трафика."""
    last_mieru_traffic = {} # username -> total_bytes
    last_h2_traffic = {} # username -> total_bytes

    print("[Traffic Daemon] Запуск фонового потока учёта трафика...")
    while True:
        try:
            h2_stats = get_h2_traffic()
            mieru_stats = get_mieru_traffic()

            conn = get_db()
            users = conn.execute("SELECT id, username, traffic_limit_gb, used_traffic_bytes, is_active FROM users").fetchall()

            deactivate_needed = False
            for user in users:
                uname = user["username"]
                user_id = user["id"]

                # 1. Рассчитываем дельту Mieru
                m_total = 0
                if uname in mieru_stats:
                    m_total = (mieru_stats[uname].get("DownloadBytes", 0) + 
                               mieru_stats[uname].get("UploadBytes", 0))

                m_delta = 0
                if uname in last_mieru_traffic:
                    if m_total >= last_mieru_traffic[uname]:
                        m_delta = m_total - last_mieru_traffic[uname]
                    else:
                        m_delta = m_total  # Перезапуск службы Mieru сбросил счётчик
                elif m_total > 0:
                    # Инициализируем при первом обнаружении активности
                    last_mieru_traffic[uname] = m_total

                if m_total > 0:
                    last_mieru_traffic[uname] = m_total

                # 2. Рассчитываем дельту Hysteria2
                h2_total = 0
                if uname in h2_stats:
                    h2_total = h2_stats[uname].get("tx", 0) + h2_stats[uname].get("rx", 0)

                h2_delta = 0
                if uname in last_h2_traffic:
                    if h2_total >= last_h2_traffic[uname]:
                        h2_delta = h2_total - last_h2_traffic[uname]
                    else:
                        h2_delta = h2_total  # Перезапуск Hysteria2
                elif h2_total > 0:
                    last_h2_traffic[uname] = h2_total

                if h2_total > 0:
                    last_h2_traffic[uname] = h2_total

                # 3. Прибавляем трафик
                total_delta = m_delta + h2_delta
                if total_delta > 0:
                    new_used = user["used_traffic_bytes"] + total_delta
                    conn.execute("UPDATE users SET used_traffic_bytes=? WHERE id=?", (new_used, user_id))
                    
                    # Проверяем лимит
                    if user["traffic_limit_gb"] > 0:
                        limit_bytes = user["traffic_limit_gb"] * 1024 * 1024 * 1024
                        if new_used >= limit_bytes and user["is_active"] == 1:
                            conn.execute("UPDATE users SET is_active=0 WHERE id=?", (user_id,))
                            deactivate_needed = True
                            print(f"[Traffic Daemon] Пользователь '{uname}' заблокирован (превышен лимит {user['traffic_limit_gb']} ГБ)")

            conn.commit()
            conn.close()

            if deactivate_needed:
                sync_all_users_to_configs()

        except Exception as e:
            print(f"[Traffic Daemon] Ошибка цикла: {e}")

        time.sleep(30)

def start_traffic_daemon():
    t = threading.Thread(target=run_traffic_accounting, daemon=True)
    t.start()
