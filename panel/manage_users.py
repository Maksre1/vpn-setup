#!/usr/bin/env python3
import os
import sys
import argparse
import re
from datetime import datetime, date

# Добавляем путь к текущей директории в sys.path для импорта модулей панели
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from models import (
    get_db, init_db, sync_user_to_conf, remove_user_from_conf,
    update_mieru_users, update_hysteria_users
)
from utils import gen_password, is_expired

def do_add(args):
    username = args.username.strip()
    if not re.match(r"^[a-zA-Z0-9_-]{3,32}$", username):
        print(f"Ошибка: Недопустимое имя пользователя '{username}'. Разрешены только буквы, цифры, дефис и подчеркивание (3-32 символов).")
        sys.exit(1)

    conn = get_db()
    existing = conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
    if existing:
        conn.close()
        print(f"Ошибка: Пользователь '{username}' уже существует.")
        sys.exit(1)

    password = gen_password()
    expire = args.expire
    if expire != "never":
        try:
            datetime.strptime(expire, "%Y-%m-%d")
        except ValueError:
            conn.close()
            print("Ошибка: Неверный формат даты истечения. Используйте YYYY-MM-DD или 'never'.")
            sys.exit(1)

    traffic = args.traffic
    if traffic < 0:
        conn.close()
        print("Ошибка: Лимит трафика не может быть отрицательным.")
        sys.exit(1)

    speed = args.speed
    if speed < 0:
        conn.close()
        print("Ошибка: Лимит скорости не может быть отрицательным.")
        sys.exit(1)

    protocol = args.protocol
    if protocol not in ["all", "mieru", "hysteria2"]:
        conn.close()
        print("Ошибка: Недопустимый протокол. Допустимые: all, mieru, hysteria2.")
        sys.exit(1)

    import secrets
    sub_path = f"sub-{secrets.token_hex(8)}.txt"

    try:
        conn.execute(
            """INSERT INTO users (username, password, expire_date,
               traffic_limit_gb, speed_limit_mbps, protocol, sub_path, is_active)
               VALUES (?, ?, ?, ?, ?, ?, ?, 1)""",
            (username, password, expire, traffic, speed, protocol, sub_path)
        )
        conn.commit()
        
        user = conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
        sync_user_to_conf(user)
        update_mieru_users()
        update_hysteria_users()
        print(f"Пользователь '{username}' успешно создан.")
        print(f"Пароль: {password}")
        print(f"Подписка: {sub_path}")
    except Exception as e:
        print(f"Ошибка при создании пользователя: {e}")
        sys.exit(1)
    finally:
        conn.close()

def do_remove(args):
    username = args.username.strip()
    conn = get_db()
    user = conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
    if not user:
        conn.close()
        print(f"Ошибка: Пользователь '{username}' не найден.")
        sys.exit(1)

    try:
        conn.execute("DELETE FROM users WHERE username=?", (username,))
        conn.commit()
        remove_user_from_conf(username)
        update_mieru_users()
        update_hysteria_users()
        print(f"Пользователь '{username}' успешно удален.")
    except Exception as e:
        print(f"Ошибка при удалении пользователя: {e}")
        sys.exit(1)
    finally:
        conn.close()

def do_list(args):
    conn = get_db()
    users = conn.execute("SELECT * FROM users ORDER BY id").fetchall()
    conn.close()

    if not users:
        print("Нет пользователей.")
        return

    print(f"{'ID':<4} | {'Имя':<15} | {'Пароль':<10} | {'Истекает':<12} | {'Трафик (ГБ)':<11} | {'Скорость':<8} | {'Протокол':<9} | {'Статус':<8}")
    print("-" * 90)
    for u in users:
        status = "активен" if u["is_active"] == 1 else "выкл"
        if is_expired(u["expire_date"]):
            status = "истёк"
        print(f"{u['id']:<4} | {u['username']:<15} | {u['password'][:6] + '...':<10} | {u['expire_date']:<12} | {u['traffic_limit_gb']:<11} | {u['speed_limit_mbps']:<8} | {u['protocol']:<9} | {status:<8}")

def do_cleanup(args):
    conn = get_db()
    users = conn.execute("SELECT * FROM users WHERE is_active=1").fetchall()
    
    changes = 0
    today = date.today()
    
    for u in users:
        exp_date = u["expire_date"]
        if not exp_date or exp_date == "never":
            continue
        try:
            exp = datetime.strptime(exp_date, "%Y-%m-%d").date()
            if exp < today:
                print(f"Деактивация пользователя: {u['username']} (истёк: {exp_date})")
                conn.execute("UPDATE users SET is_active=0 WHERE id=?", (u["id"],))
                conn.commit()
                # Перечитываем обновленного пользователя для синхронизации
                updated = conn.execute("SELECT * FROM users WHERE id=?", (u["id"],)).fetchone()
                sync_user_to_conf(updated)
                changes += 1
        except Exception as e:
            print(f"Ошибка при проверке пользователя {u['username']}: {e}")

    if changes > 0:
        print(f"Деактивировано пользователей: {changes}. Обновление конфигурации...")
        update_mieru_users()
        update_hysteria_users()
    else:
        print("Нет истекших активных пользователей.")
    conn.close()

def main():
    init_db()

    parser = argparse.ArgumentParser(description="VPN Setup — CLI управления пользователями")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Add
    parser_add = subparsers.add_parser("add", help="Создать нового пользователя")
    parser_add.add_argument("username", help="Имя пользователя")
    parser_add.add_argument("--expire", default="never", help="Дата окончания (YYYY-MM-DD или never)")
    parser_add.add_argument("--traffic", type=int, default=0, help="Лимит трафика в ГБ (0 - безлимит)")
    parser_add.add_argument("--speed", type=int, default=0, help="Лимит скорости в Мбит/с (0 - безлимит)")
    parser_add.add_argument("--protocol", default="all", choices=["all", "mieru", "hysteria2"], help="Протокол доступа")

    # Remove
    parser_remove = subparsers.add_parser("remove", help="Удалить пользователя")
    parser_remove.add_argument("username", help="Имя пользователя")

    # List
    subparsers.add_parser("list", help="Вывести список пользователей")

    # Cleanup
    subparsers.add_parser("cleanup", help="Очистить истекших пользователей")

    args = parser.parse_args()

    if args.command == "add":
        do_add(args)
    elif args.command == "remove":
        do_remove(args)
    elif args.command == "list":
        do_list(args)
    elif args.command == "cleanup":
        do_cleanup(args)

if __name__ == "__main__":
    main()
