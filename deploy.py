import os
import sys
import paramiko

def put_dir(sftp, local_dir, remote_dir):
    """Рекурсивная загрузка папки по SFTP."""
    print(f"Загрузка директории: {local_dir} -> {remote_dir}", flush=True)
    try:
        sftp.mkdir(remote_dir)
    except IOError:
        pass  # уже существует

    for item in os.listdir(local_dir):
        if item in [".git", "__pycache__", ".idea", ".DS_Store", "deploy.py"] or item.endswith(".go") or item == "go.mod" or item == "go.sum":
            continue
        local_path = os.path.join(local_dir, item)
        remote_path = remote_dir + "/" + item
        if os.path.isdir(local_path):
            put_dir(sftp, local_path, remote_path)
        else:
            sftp.put(local_path, remote_path)
            sftp.chmod(remote_path, 0o755 if item.endswith(".sh") or item.endswith(".py") or item in ("vpn-panel", "vpn-sub") else 0o644)

def main():
    host = "87.120.196.10"
    port = 22
    username = "root"
    password = "CyesC3U50VYUvx5"
    
    # 0. Локальная кросс-компиляция Go под Linux
    print("Компиляция Go бэкенда под Linux (amd64)...", flush=True)
    import subprocess
    env = os.environ.copy()
    env["GOOS"] = "linux"
    env["GOARCH"] = "amd64"
    env["CGO_ENABLED"] = "0"
    
    # Build vpn-panel
    res = subprocess.run(
        ["go", "build", "-ldflags=-s -w", "-o", "panel_go/vpn-panel", "./panel_go/main.go", "./panel_go/db.go", "./panel_go/routes.go", "./panel_go/traffic.go", "./panel_go/utils.go", "./panel_go/cli.go"],
        env=env, capture_output=True, text=True
    )
    if res.returncode != 0:
        print(f"Ошибка компиляции vpn-panel Go:\n{res.stderr}", flush=True)
        sys.exit(1)
        
    # Build vpn-sub
    res = subprocess.run(
        ["go", "build", "-ldflags=-s -w", "-o", "panel_go/vpn-sub", "./panel_go/sub.go"],
        env=env, capture_output=True, text=True
    )
    if res.returncode != 0:
        print(f"Ошибка компиляции vpn-sub Go:\n{res.stderr}", flush=True)
        sys.exit(1)
        
    print("Компиляция Go успешно завершена!", flush=True)

    print(f"Подключение к {host}:{port}...", flush=True)
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    
    try:
        client.connect(host, port=port, username=username, password=password, timeout=15)
        print("Соединение установлено!", flush=True)
    except Exception as e:
        print(f"Ошибка подключения: {e}", flush=True)
        sys.exit(1)

    # Синхронно удаляем маркеры предыдущей установки на VPS
    print("Очистка маркеров предыдущей установки...", flush=True)
    stdin, stdout, stderr = client.exec_command("rm -rf /etc/vpn-setup-state/")
    stdout.channel.recv_exit_status()
    
    # Удаляем старую vpn-setup папку
    print("Очистка старой директории vpn-setup на VPS...", flush=True)
    stdin, stdout, stderr = client.exec_command("rm -rf /root/vpn-setup")
    stdout.channel.recv_exit_status()

    # Загружаем ЛОКАЛЬНЫЙ репозиторий
    print("Начало рекурсивной загрузки по SFTP...", flush=True)
    try:
        sftp = client.open_sftp()
        local_dir = "/Users/maks/.gemini/antigravity/scratch/vpn-setup"
        put_dir(sftp, local_dir, "/root/vpn-setup")
        sftp.close()
        print("Все файлы загружены!", flush=True)
    except Exception as e:
        print(f"Ошибка загрузки по SFTP: {e}", flush=True)
        client.close()
        sys.exit(1)

    cmd = "cd /root/vpn-setup && bash setup.sh --setup"
    print(f"Выполнение команды на сервере: {cmd}\n", flush=True)

    try:
        stdin, stdout, stderr = client.exec_command(cmd, get_pty=True)
        
        while True:
            line = stdout.readline()
            if not line:
                break
            print(line, end="", flush=True)
            
        exit_status = stdout.channel.recv_exit_status()
        print(f"\nВыполнение завершено с кодом: {exit_status}", flush=True)
        
    except Exception as e:
        print(f"Ошибка при выполнении: {e}", flush=True)
    finally:
        client.close()

if __name__ == "__main__":
    main()
