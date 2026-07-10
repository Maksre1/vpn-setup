"""Утилиты — генерация ключей, паролей, ссылок, QR-кодов."""
import os
import subprocess
import hashlib
import base64
import json
from datetime import datetime


def gen_password(length=24):
    """Генерация случайного пароля."""
    import secrets
    import string
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for _ in range(length))


def gen_random_path(prefix="sub", ext="txt"):
    """Генерация рандомного пути для подписки."""
    import secrets
    return f"{prefix}-{secrets.token_hex(8)}.{ext}"


def get_hysteria2_uri(config, server_ip, username=None, password=None):
    """Сформировать hysteria2:// URI."""
    auth_part = config.get("H2_PASS", "")
    if username and password:
        auth_part = f"{username}:{password}"
    elif password:
        auth_part = password

    if not auth_part:
        return ""
    return (
        f"hysteria2://{auth_part}@{server_ip}:{config.get('H2_PORT', 443)}"
        f"?obfs=salamander&obfs-password={config.get('H2_OBFS_PASS', '')}"
        f"&pinSHA256={config.get('H2_CERT_PIN', '')}"
        f"&sni={config.get('H2_CERT_CN', '')}"
    )


def get_mieru_uri(config, server_ip, username=None, password=None):
    """Сформировать mieru:// URI."""
    user = username or config.get("MIERU_USER", "")
    pwd = password or config.get("MIERU_PASS", "")
    if not pwd:
        return ""
    return (
        f"mieru://{server_ip}:{config.get('MIERU_PORT', 443)}"
        f"?username={user}"
        f"&password={pwd}"
        f"&network=udp#Mieru-Proxy"
    )


def gen_subscription_base64(uris):
    """Base64 подписка из списка URI."""
    content = "\n".join(u for u in uris if u)
    return base64.b64encode(content.encode()).decode()


def gen_qr_svg(text, size=200):
    """Генерация QR-кода как SVG (через python-qrcode или fallback)."""
    try:
        import qrcode
        import qrcode.image.svg
        qr = qrcode.QRCode(version=1, box_size=10, border=2)
        qr.add_data(text)
        qr.make(fit=True)
        factory = qrcode.image.svg.SvgImage
        img = qr.make_image(image_factory=factory)
        import io
        buf = io.BytesIO()
        img.save(buf)
        return buf.getvalue().decode()
    except ImportError:
        return None


def get_cert_fingerprint(cert_path):
    """Получить SHA-256 fingerprint сертификата."""
    try:
        r = subprocess.run(
            ["openssl", "x509", "-in", cert_path, "-noout", "-fingerprint", "-sha256"],
            capture_output=True, text=True, timeout=5
        )
        fp = r.stdout.strip().split("=", 1)[1].replace(":", "").lower()
        return fp
    except Exception:
        return ""


def gen_ecdsa_cert(cert_dir, cn="vpn-panel"):
    """Генерация самоподписанного ECDSA-сертификата."""
    key_path = os.path.join(cert_dir, "server.key")
    crt_path = os.path.join(cert_dir, "server.crt")
    if os.path.exists(key_path) and os.path.exists(crt_path):
        return key_path, crt_path

    os.makedirs(cert_dir, exist_ok=True)
    subprocess.run(
        ["openssl", "ecparam", "-genkey", "-name", "prime256v1", "-out", key_path],
        capture_output=True, timeout=10
    )
    subprocess.run(
        ["openssl", "req", "-new", "-x509",
         "-key", key_path, "-out", crt_path,
         "-days", "3650", "-nodes",
         "-subj", f"/CN={cn}/O=VPN-Panel/C=US"],
        capture_output=True, timeout=10
    )
    os.chmod(key_path, 0o600)
    os.chmod(crt_path, 0o644)
    return key_path, crt_path


def is_expired(expire_date):
    """Проверить, истёк ли срок действия."""
    if not expire_date or expire_date == "never":
        return False
    try:
        exp = datetime.strptime(expire_date, "%Y-%m-%d").date()
        return exp < date.today()
    except ValueError:
        return False


def format_expire(expire_date):
    """Отформатировать дату истечения."""
    if not expire_date or expire_date == "never":
        return "бессрочно"
    if is_expired(expire_date):
        return f"истёк ({expire_date})"
    return expire_date


def format_traffic(limit):
    if not limit or limit == 0 or str(limit) == "unlimited":
        return "безлимит"
    return f"{limit} ГБ"


def format_speed(limit):
    if not limit or limit == 0 or str(limit) == "unlimited":
        return "безлимит"
    return f"{limit} Мбит/с"
