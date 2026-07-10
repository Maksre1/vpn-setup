"""VPN Panel — Flask веб-приложение."""
import os
import secrets
import functools
from datetime import datetime, date

from flask import (
    Flask, render_template, request, redirect, url_for,
    flash, session, jsonify, abort, Response
)
from werkzeug.security import generate_password_hash, check_password_hash

from models import (
    init_db, get_db, get_mieru_config, get_hysteria2_config,
    get_subscription_paths, get_server_ip, get_server_specs,
    get_all_service_statuses, restart_service, get_logs,
    sync_user_to_conf, remove_user_from_conf, update_mieru_users
)
from utils import (
    gen_password, gen_random_path, get_hysteria2_uri, get_mieru_uri,
    gen_subscription_base64, gen_qr_svg, is_expired,
    format_expire, format_traffic, format_speed
)

app = Flask(__name__)
app.secret_key = os.environ.get("PANEL_SECRET", secrets.token_hex(32))
app.config["SESSION_COOKIE_SECURE"] = True
app.config["SESSION_COOKIE_HTTPONLY"] = True

PANEL_PORT = os.environ.get("PANEL_PORT", "8443")


# ── Auth decorator ───────────────────────────────────────────────────────────
def login_required(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("admin_id"):
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated


# ── Context processors ───────────────────────────────────────────────────────
@app.context_processor
def inject_globals():
    return {
        "panel_port": PANEL_PORT,
        "now": datetime.now(),
    }


# ── Auth routes ──────────────────────────────────────────────────────────────
@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")

        conn = get_db()
        admin = conn.execute(
            "SELECT * FROM admin WHERE username=?", (username,)
        ).fetchone()
        conn.close()

        if admin and check_password_hash(admin["password_hash"], password):
            session["admin_id"] = admin["id"]
            session["admin_username"] = admin["username"]
            return redirect(url_for("dashboard"))

        flash("Неверный логин или пароль", "danger")
    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# ── Dashboard ────────────────────────────────────────────────────────────────
@app.route("/")
@login_required
def dashboard():
    statuses = get_all_service_statuses()
    specs = get_server_specs()
    server_ip = get_server_ip()

    conn = get_db()
    users = conn.execute("SELECT * FROM users ORDER BY id").fetchall()
    conn.close()

    active = sum(1 for u in users if not is_expired(u["expire_date"]) and u["is_active"])
    expired = sum(1 for u in users if is_expired(u["expire_date"]))
    total = len(users)

    return render_template("dashboard.html",
                           statuses=statuses, specs=specs,
                           server_ip=server_ip,
                           active=active, expired=expired, total=total)


@app.route("/api/status")
@login_required
def api_status():
    return jsonify(get_all_service_statuses())


# ── Users ────────────────────────────────────────────────────────────────────
@app.route("/users")
@login_required
def users_list():
    conn = get_db()
    users = conn.execute("SELECT * FROM users ORDER BY id").fetchall()
    conn.close()

    server_ip = get_server_ip()
    mieru = get_mieru_config()
    h2 = get_hysteria2_config()

    for u in users:
        u["_expired"] = is_expired(u["expire_date"])
        u["_expire_fmt"] = format_expire(u["expire_date"])
        u["_traffic_fmt"] = format_traffic(u["traffic_limit_gb"])
        u["_speed_fmt"] = format_speed(u["speed_limit_mbps"])
        # Генерируем ссылку
        uris = []
        if u["protocol"] in ("all", "hysteria2"):
            uris.append(get_hysteria2_uri(h2, server_ip))
        if u["protocol"] in ("all", "mieru"):
            uris.append(get_mieru_uri(mieru, server_ip))
        u["_sub_b64"] = gen_subscription_base64(uris)

    return render_template("users.html", users=users, server_ip=server_ip)


@app.route("/users/add", methods=["GET", "POST"])
@login_required
def user_add():
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        if not username:
            flash("Имя не может быть пустым", "danger")
            return redirect(url_for("user_add"))

        password = gen_password()
        expire = request.form.get("expire_date", "never")
        if expire == "custom":
            expire = request.form.get("expire_custom", "never")
        traffic = int(request.form.get("traffic_limit", 0))
        speed = int(request.form.get("speed_limit", 0))
        protocol = request.form.get("protocol", "all")

        # Срок
        expire_days = request.form.get("expire_preset", "0")
        if expire_days == "7":
            expire = (date.today() + __import__("datetime").timedelta(days=7)).isoformat()
        elif expire_days == "30":
            expire = (date.today() + __import__("datetime").timedelta(days=30)).isoformat()
        elif expire_days == "90":
            expire = (date.today() + __import__("datetime").timedelta(days=90)).isoformat()
        elif expire_days == "365":
            expire = (date.today() + __import__("datetime").timedelta(days=365)).isoformat()
        elif expire_days == "custom":
            expire = request.form.get("expire_custom", "never")
        else:
            expire = "never"

        sub_path = gen_random_path("sub", "txt")

        conn = get_db()
        try:
            conn.execute(
                """INSERT INTO users (username, password, expire_date,
                   traffic_limit_gb, speed_limit_mbps, protocol, sub_path)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (username, password, expire, traffic, speed, protocol, sub_path)
            )
            conn.commit()
            user = conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
            sync_user_to_conf(user)
            update_mieru_users()
            flash(f"Пользователь '{username}' создан. Пароль: {password}", "success")
        except Exception as e:
            flash(f"Ошибка: {e}", "danger")
        finally:
            conn.close()

        return redirect(url_for("users_list"))

    return render_template("user_edit.html", user=None, mode="add")


@app.route("/users/<int:user_id>/edit", methods=["GET", "POST"])
@login_required
def user_edit(user_id):
    conn = get_db()
    user = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
    if not user:
        conn.close()
        abort(404)

    if request.method == "POST":
        expire_days = request.form.get("expire_preset", "0")
        if expire_days == "7":
            expire = (date.today() + __import__("datetime").timedelta(days=7)).isoformat()
        elif expire_days == "30":
            expire = (date.today() + __import__("datetime").timedelta(days=30)).isoformat()
        elif expire_days == "90":
            expire = (date.today() + __import__("datetime").timedelta(days=90)).isoformat()
        elif expire_days == "365":
            expire = (date.today() + __import__("datetime").timedelta(days=365)).isoformat()
        elif expire_days == "custom":
            expire = request.form.get("expire_custom", user["expire_date"])
        else:
            expire = "never"

        traffic = int(request.form.get("traffic_limit", user["traffic_limit_gb"]))
        speed = int(request.form.get("speed_limit", user["speed_limit_mbps"]))
        protocol = request.form.get("protocol", user["protocol"])
        is_active = 1 if request.form.get("is_active") else 0

        conn.execute(
            """UPDATE users SET expire_date=?, traffic_limit_gb=?,
               speed_limit_mbps=?, protocol=?, is_active=?
               WHERE id=?""",
            (expire, traffic, speed, protocol, is_active, user_id)
        )
        conn.commit()
        updated = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
        sync_user_to_conf(updated)
        update_mieru_users()
        conn.close()

        flash(f"Пользователь '{user['username']}' обновлён", "success")
        return redirect(url_for("users_list"))

    conn.close()
    return render_template("user_edit.html", user=user, mode="edit")


@app.route("/users/<int:user_id>/delete", methods=["POST"])
@login_required
def user_delete(user_id):
    conn = get_db()
    user = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
    if user:
        conn.execute("DELETE FROM users WHERE id=?", (user_id,))
        conn.commit()
        remove_user_from_conf(user["username"])
        update_mieru_users()
        flash(f"Пользователь '{user['username']}' удалён", "success")
    conn.close()
    return redirect(url_for("users_list"))


@app.route("/users/<int:user_id>/reset-password", methods=["POST"])
@login_required
def user_reset_password(user_id):
    conn = get_db()
    user = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
    if user:
        new_pass = gen_password()
        conn.execute("UPDATE users SET password=? WHERE id=?", (new_pass, user_id))
        conn.commit()
        updated = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
        sync_user_to_conf(updated)
        update_mieru_users()
        flash(f"Пароль '{user['username']}' сброшен: {new_pass}", "success")
    conn.close()
    return redirect(url_for("users_list"))


# ── Keys ─────────────────────────────────────────────────────────────────────
@app.route("/keys")
@login_required
def keys():
    server_ip = get_server_ip()
    mieru = get_mieru_config()
    h2 = get_hysteria2_config()
    sub = get_subscription_paths()

    mieru_uri = get_mieru_uri(mieru, server_ip)
    h2_uri = get_hysteria2_uri(h2, server_ip)

    sub_content = "\n".join(u for u in [h2_uri, mieru_uri] if u)
    sub_b64 = gen_subscription_base64([h2_uri, mieru_uri])

    sub_path = sub.get("SUB_PATH", "sub.txt")
    clash_path = sub.get("CLASH_PATH", "clash.yaml")

    return render_template("keys.html",
                           server_ip=server_ip,
                           mieru=mieru, h2=h2,
                           mieru_uri=mieru_uri, h2_uri=h2_uri,
                           sub_b64=sub_b64,
                           sub_path=sub_path, clash_path=clash_path)


# ── Settings ─────────────────────────────────────────────────────────────────
@app.route("/settings", methods=["GET", "POST"])
@login_required
def settings():
    if request.method == "POST":
        action = request.form.get("action")
        service = request.form.get("service")
        if action == "restart" and service:
            ok = restart_service(service)
            flash(f"{'Сервис перезапущен' if ok else 'Ошибка перезапуска'}", "success" if ok else "danger")
        return redirect(url_for("settings"))

    return render_template("settings.html")


# ── Logs ─────────────────────────────────────────────────────────────────────
@app.route("/logs")
@login_required
def logs():
    service = request.args.get("service", "mieru")
    lines = int(request.args.get("lines", 50))
    log_text = get_logs(service, lines)
    return render_template("logs.html", log_text=log_text, selected=service, lines=lines)


@app.route("/api/logs/<service>")
@login_required
def api_logs(service):
    lines = int(request.args.get("lines", 50))
    return jsonify({"logs": get_logs(service, lines)})


# ── Init ─────────────────────────────────────────────────────────────────────
def _ensure_admin():
    """Создать дефолтного админа при первом запуске."""
    init_db()
    conn = get_db()
    if conn.execute("SELECT COUNT(*) FROM admin").fetchone()[0] == 0:
        default_pass = gen_password(16)
        conn.execute(
            "INSERT INTO admin (username, password_hash) VALUES (?, ?)",
            ("admin", generate_password_hash(default_pass))
        )
        conn.commit()
        os.makedirs("/etc/vpn-panel", exist_ok=True)
        with open("/etc/vpn-panel/admin_password.txt", "w") as f:
            f.write(f"admin:{default_pass}\n")
        os.chmod("/etc/vpn-panel/admin_password.txt", 0o600)
    conn.close()


if __name__ == "__main__":
    cert_dir = "/opt/vpn-panel/certs"
    key_file = os.path.join(cert_dir, "server.key")
    crt_file = os.path.join(cert_dir, "server.crt")

    if not os.path.exists(key_file):
        from utils import gen_ecdsa_cert
        gen_ecdsa_cert(cert_dir, "vpn-panel")

    # Создаём админа при старте
    _ensure_admin()

    port = int(PANEL_PORT)
    print(f"VPN Panel starting on port {port}...")
    app.run(host="0.0.0.0", port=port, ssl_context=(crt_file, key_file))
