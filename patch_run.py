"""
Целевой патч: перезапускает только шаги install_hysteria2 и setup_sub_server.
"""
import sys
import paramiko

HOST = "87.120.196.10"
PORT = 22
USERNAME = "root"
PASSWORD = "ttSrB93XbgTfZEW"

RESET_STEPS = ["install_hysteria2", "setup_sub_server"]

def main():
    print(f"Подключение к {HOST}:{PORT}...")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(HOST, port=PORT, username=USERNAME, password=PASSWORD, timeout=15)
        print("Соединение установлено!")
    except Exception as e:
        print(f"Ошибка: {e}"); sys.exit(1)

    for step in RESET_STEPS:
        marker = f"/etc/vpn-setup-state/{step}.done"
        print(f"  Сброс маркера: {marker}")
        stdin, stdout, stderr = client.exec_command(f"rm -f {marker}")
        stdout.channel.recv_exit_status()

    print("  Сброс hysteria2.env...")
    stdin, stdout, stderr = client.exec_command("rm -f /etc/vpn-setup-state/hysteria2.env")
    stdout.channel.recv_exit_status()

    print("\nЗагрузка setup.sh по SFTP...")
    sftp = client.open_sftp()
    sftp.put("setup.sh", "setup.sh")
    sftp.close()
    print("Загружен!\n" + "="*60)

    stdin, stdout, stderr = client.exec_command("bash setup.sh", get_pty=True)
    while True:
        line = stdout.readline()
        if not line: break
        print(line, end="")
    code = stdout.channel.recv_exit_status()
    print(f"\n{'='*60}\nКод завершения: {code}")
    client.close()

if __name__ == "__main__":
    main()
