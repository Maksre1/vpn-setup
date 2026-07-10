import sys
import paramiko

def main():
    host = "87.120.196.10"
    port = 22
    username = "root"
    password = "CyesC3U50VYUvx5"

    print(f"Подключение к {host}:{port}...")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    
    try:
        client.connect(host, port=port, username=username, password=password, timeout=15)
        print("Соединение установлено!")
    except Exception as e:
        print(f"Ошибка подключения: {e}")
        sys.exit(1)

    # Синхронно удаляем ВСЕ маркеры предыдущей установки на VPS
    print("Полная очистка состояния установки на VPS...")
    stdin, stdout, stderr = client.exec_command("rm -rf /etc/vpn-setup-state/")
    stdout.channel.recv_exit_status()

    # Загружаем ЛОКАЛЬНЫЙ файл setup.sh по SFTP (он ТОЧНО самый свежий, так как берется прямо с нашего диска)
    print("Загрузка локального файла setup.sh по SFTP...")
    try:
        sftp = client.open_sftp()
        sftp.put("setup.sh", "setup.sh")
        sftp.close()
        print("Файл setup.sh загружен!")
    except Exception as e:
        print(f"Ошибка загрузки по SFTP: {e}")
        client.close()
        sys.exit(1)

    cmd = "bash setup.sh --setup"
    print(f"Выполнение команды на сервере: {cmd}\n")

    try:
        stdin, stdout, stderr = client.exec_command(cmd, get_pty=True)
        
        while True:
            line = stdout.readline()
            if not line:
                break
            print(line, end="")
            
        exit_status = stdout.channel.recv_exit_status()
        print(f"\nВыполнение завершено с кодом: {exit_status}")
        
    except Exception as e:
        print(f"Ошибка при выполнении: {e}")
    finally:
        client.close()

if __name__ == "__main__":
    main()
