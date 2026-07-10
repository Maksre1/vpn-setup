import os
import sys
import http.server
import socketserver

PORT = 8080
DIRECTORY = "/var/www/html"

class SecureHTTPRequestHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def do_GET(self):
        # Предотвращаем обращение к директориям (индексный листинг)
        target_path = self.translate_path(self.path)
        if os.path.isdir(target_path):
            self.send_error(403, "Forbidden: Directory listing is disabled")
            return

        # Белый список допустимых файлов
        filename = os.path.basename(target_path)
        allowed = False

        # Разрешаем singbox.json, clash.yaml
        if filename in ["singbox.json", "clash.yaml"]:
            allowed = True
        # Разрешаем пользовательские подписки sub-*.txt и main sub файлы
        elif filename.startswith("sub-") and filename.endswith(".txt"):
            allowed = True
        # Разрешаем рандомные 32-символьные hex-имена (основной sub_path)
        elif len(filename) >= 16 and all(c in "0123456789abcdef" for c in filename.partition(".")[0]):
            allowed = True

        if not allowed or not os.path.exists(target_path):
            self.send_error(404, "File Not Found")
            return

        super().do_GET()

    def log_message(self, format, *args):
        # Пишем логи в stderr (journald перехватит их в системный лог)
        sys.stderr.write("%s - - [%s] %s\n" %
                         (self.address_string(),
                          self.log_date_time_string(),
                          format % args))

def run():
    os.makedirs(DIRECTORY, exist_ok=True)
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", PORT), SecureHTTPRequestHandler) as httpd:
        print(f"Serving securely on port {PORT}...", flush=True)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nStopping server...", flush=True)

if __name__ == "__main__":
    run()
