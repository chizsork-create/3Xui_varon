#!/usr/bin/env python3
"""Migrate the bootstrap client to HTTPS/XHTTP through Cloudflare."""

import argparse
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import sqlite3
import subprocess
import time
import urllib.parse
import urllib.request

spec = importlib.util.spec_from_file_location("bootstrap_direct", Path(__file__).with_name("bootstrap-direct.py"))
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)

STATE = Path("/etc/3xui-varon/cloudflare.json")
HTTP = Path("/etc/nginx/conf.d/varon-cdn-http.conf")
WEB = Path("/etc/nginx/conf.d/varon-cdn-web.conf")
ROOT = Path("/var/www/varon-cdn")
TAG = "cloudflare-xhttp"


def valid_hostname(value):
    return len(value) <= 253 and "." in value and all(
        re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
        for label in value.split("."))


def http_config(hostname):
    return f"""# Managed by 3Xui Varon configure-cloudflare.py
server {{
    listen 80;
    server_name {hostname};
    server_tokens off;
    location ^~ /.well-known/acme-challenge/ {{ root {ROOT}; }}
    location / {{ return 301 https://$host$request_uri; }}
}}
"""


def ws_location(path, port):
    return f"""    location = {path} {{
        proxy_pass http://127.0.0.1:{port};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        add_header Cache-Control "no-store" always;
    }}
"""


def web_config(hostname, panel_path, panel_port, path, ws_routes=()):
    extra_locations = "".join(ws_location(route["path"], route["port"]) for route in ws_routes)
    return f"""# Managed by 3Xui Varon configure-cloudflare.py
server {{
    listen 443 ssl http2;
    server_name {hostname};
    server_tokens off;
    ssl_certificate /etc/letsencrypt/live/{hostname}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{hostname}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location = /health {{
        default_type text/plain;
        add_header Cache-Control "no-store" always;
        return 200 "varon-cdn-ready\\n";
    }}
    location ^~ {path}/ {{
        proxy_pass http://127.0.0.1:16666;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        client_max_body_size 0;
        add_header Cache-Control "no-store, no-transform" always;
        add_header X-Accel-Buffering no always;
    }}
    location = /{panel_path} {{ return 301 /{panel_path}/; }}
    location ^~ /{panel_path}/ {{
        proxy_pass http://127.0.0.1:{panel_port};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 1h;
        add_header Cache-Control "no-store" always;
    }}
{extra_locations}    location / {{
        default_type text/html;
        add_header Cache-Control "no-store" always;
        return 200 '<!doctype html><html lang="en"><title>Service</title><h1>Service online</h1></html>';
    }}
}}
"""


def xhttp_payload(path):
    return {"remark": "Cloudflare XHTTP", "tag": TAG, "enable": True,
            "listen": "127.0.0.1", "port": 16666, "protocol": "vless",
            "up": 0, "down": 0, "total": 0, "expiryTime": 0,
            "settings": json.dumps({"clients": [], "decryption": "none", "encryption": "none"}),
            "streamSettings": json.dumps({"network": "xhttp", "security": "none",
                "xhttpSettings": {"path": path, "mode": "packet-up"}}),
            "sniffing": json.dumps({"enabled": True, "destOverride": ["http", "tls"]})}


def cdn_link(uuid, hostname, path):
    query = urllib.parse.urlencode({"encryption": "none", "security": "tls", "sni": hostname,
        "fp": "chrome", "type": "xhttp", "path": path, "host": hostname,
        "mode": "packet-up", "alpn": "h2,http/1.1"})
    return f"vless://{uuid}@{hostname}:443?{query}#Zercalo-Cloudflare-XHTTP"


def checked_cdn_response(response):
    if not response.headers.get("CF-Ray") or response.read().strip() != b"varon-cdn-ready":
        raise RuntimeError("Public HTTPS health check did not pass through Cloudflare to this origin")


def check_generated(config, uuid):
    """Inspect actual core config: panel normalization can change client flows."""
    cdn = next((i for i in config["inbounds"] if i.get("port") == 16666), None)
    expected = {uuid} if isinstance(uuid, str) else set(uuid)
    if not cdn or cdn.get("listen") != "127.0.0.1":
        raise RuntimeError("Generated XHTTP listener/client differs from the expected topology")
    clients = cdn["settings"].get("clients", [])
    if ({client["id"] for client in clients} != expected or len(clients) != len(expected)
            or any(client.get("flow", "") for client in clients)):
        raise RuntimeError("Generated XHTTP client identity/flow changed")


def wait_https(hostname):
    # nginx reload is asynchronous; an old REALITY worker can still own 443 briefly.
    for _ in range(20):
        result = subprocess.run([
            "curl", "--fail", "--silent", "--show-error", "--max-time", "5",
            "--resolve", hostname + ":443:127.0.0.1", "https://" + hostname + "/health"],
            capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.strip() == "varon-cdn-ready":
            return
        time.sleep(1)
    raise RuntimeError("Local HTTPS did not become ready with a valid certificate")


def wait_port_free(port):
    for _ in range(30):
        try:
            with socket.socket() as probe:
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                probe.bind(("0.0.0.0", port))
            return
        except OSError:
            time.sleep(1)
    raise RuntimeError("Previous core still owns public port " + str(port))


def set_enabled(api, inbound_id, enabled):
    # 3X-UI's general update preserves the old enable flag; use its dedicated API.
    api("inbounds/setEnable/" + str(inbound_id), {"enable": enabled})
    if api("inbounds/get/" + str(inbound_id))["enable"] != enabled:
        raise RuntimeError("Panel did not apply the inbound enable flag")


def ensure_public_host(api, inbound_id, hostname, path, remark="Cloudflare public TLS", alpn=("h2", "http/1.1")):
    groups = [g for g in api("hosts/list") if g.get("remark") == remark]
    if groups:
        if len(groups) != 1:
            raise RuntimeError("Ambiguous Cloudflare host group")
        group = groups[0]
        if (group["inboundIds"] != [inbound_id]
                or group["hosts"] not in ([hostname], [hostname + ":443"])
                or group.get("port") != 443 or group.get("security") != "tls"
                or group.get("sni") != hostname or group.get("allowInsecure")
                or group.get("isDisabled") or group.get("path", "") not in ("", path)
                or group.get("hostHeader", "") not in ("", hostname)):
            raise RuntimeError("Existing Cloudflare host group differs; refusing to overwrite it")
        return group["groupId"]
    created = api("hosts/add", {"inboundIds": [inbound_id], "remark": remark,
        "hosts": [hostname], "port": 443, "security": "tls", "sni": hostname,
        "hostHeader": hostname, "path": path, "alpn": list(alpn),
        "fingerprint": "chrome", "allowInsecure": False})
    return created[0]["groupId"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--server-ip", required=True, type=ipaddress.IPv4Address)
    parser.add_argument("--remove-direct", action="store_true",
                        help="Remove the bootstrap REALITY inbound after CDN health checks pass")
    args = parser.parse_args()
    if os.geteuid() != 0 or not valid_hostname(args.hostname):
        parser.error("Run as root and supply a valid lowercase hostname")
    if not args.remove_direct:
        parser.error("This migration requires --remove-direct; it does not preserve public REALITY")
    if not bootstrap.STATE.exists():
        parser.error("Run bootstrap-direct.py first")
    os.umask(0o077)
    recorded = json.loads(bootstrap.STATE.read_text())
    if recorded["server_ip"] != str(args.server_ip):
        parser.error("Server IP differs from the recorded bootstrap")
    old_state = json.loads(STATE.read_text()) if STATE.exists() else None
    if old_state and old_state["hostname"] != args.hostname:
        parser.error("Hostname differs from the configured CDN; refusing to replace it")
    credentials = bootstrap.read_credentials(bootstrap.RESULT)
    api = lambda path, payload=None: bootstrap.api(credentials, path, payload)
    bootstrap.wait_panel(credentials)
    inbounds = api("inbounds/list")
    direct = next((i for i in inbounds if i["id"] == recorded["inbound_id"]), None)
    cdn = next((i for i in inbounds if i.get("tag") == TAG), None)
    if not old_state:
        if direct is None:
            parser.error("Bootstrap direct inbound is missing")
        bootstrap.select_existing([direct], direct["port"], recorded["inbound_id"])
    if old_state and (not cdn or cdn["id"] != old_state["inbound_id"]):
        parser.error("Recorded CDN inbound is missing or replaced")
    if cdn:
        stream = bootstrap.object_value(cdn["streamSettings"])
        if (cdn["listen"] != "127.0.0.1" or cdn["port"] != 16666
                or stream.get("network") != "xhttp" or stream.get("security") != "none"):
            parser.error("Existing CDN inbound has unexpected settings")
        path = stream["xhttpSettings"]["path"]
    else:
        if any(i["port"] == 16666 for i in inbounds):
            parser.error("XHTTP backend port belongs to another inbound")
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 16666))
        path = "/" + secrets.token_hex(18)
    source = direct if direct else cdn
    clients = bootstrap.object_value(source["settings"]).get("clients", [])
    if not clients or (not old_state and len(clients) != 1):
        parser.error("Expected exactly one existing client")
    client = clients[0]
    if old_state:
        old_link = (STATE.parent / "cloudflare-main.txt").read_text().strip()
        primary_id = urllib.parse.urlsplit(old_link).username
        client = next((item for item in clients if item["id"] == primary_id), None)
        if client is None:
            parser.error("Primary CDN client is missing; refusing to replace its identity")
    users_state = STATE.parent / "users.json"
    ws_routes = json.loads(users_state.read_text())["transports"] if users_state.exists() else []
    if any(not re.fullmatch(r"/[a-f0-9]{36}", route["path"])
           or route["port"] not in (16667, 16668) for route in ws_routes):
        parser.error("Invalid managed WebSocket routes")
    panel_path = credentials["XUI_WEB_BASE_PATH"].strip("/")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", panel_path) or not re.fullmatch(r"/[a-f0-9]{36}", path):
        parser.error("Invalid panel/XHTTP path")
    if not old_state:
        for config in (HTTP, WEB):
            if config.exists():
                parser.error("Nginx target file already exists: " + str(config))
        if not direct or direct["port"] != 443:
            with socket.socket() as probe:
                probe.bind(("0.0.0.0", 443))
    if not shutil.which("nginx") or not shutil.which("certbot"):
        bootstrap.run("apt-get", "update")
        bootstrap.run("apt-get", "install", "--yes", "--no-install-recommends", "nginx", "certbot")
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o755)
    ROOT.chmod(0o755)
    (ROOT / ".well-known" / "acme-challenge").mkdir(parents=True, exist_ok=True, mode=0o755)
    (ROOT / ".well-known").chmod(0o755)
    (ROOT / ".well-known" / "acme-challenge").chmod(0o755)
    hook = Path("/etc/letsencrypt/renewal-hooks/deploy/varon-cdn-nginx")
    files_before = {p: p.read_bytes() if p.exists() else None for p in (
        HTTP, WEB, hook, STATE, bootstrap.STATE, STATE.parent / "cloudflare-main.txt")}
    database_backup = STATE.parent / ("x-ui-before-cdn-" + str(time.time_ns()) + ".db")
    with sqlite3.connect("/etc/x-ui/x-ui.db") as source_db, sqlite3.connect(database_backup) as destination:
        source_db.backup(destination)
    old_direct = json.loads(json.dumps(direct)) if direct else None
    created_id = None
    direct_changed = False
    try:
        bootstrap.write_private(HTTP, http_config(args.hostname))
        bootstrap.run("nginx", "-t")
        bootstrap.run("systemctl", "enable", "--now", "nginx")
        bootstrap.run("systemctl", "reload", "nginx")
        bootstrap.run("certbot", "certonly", "--webroot", "-w", str(ROOT), "-d", args.hostname,
                      "--non-interactive", "--agree-tos", "--register-unsafely-without-email", "--keep-until-expiring")
        bootstrap.write_private(WEB, web_config(args.hostname, panel_path, int(credentials["XUI_PANEL_PORT"]), path, ws_routes))
        bootstrap.run("nginx", "-t")
        if not cdn:
            cdn = api("inbounds/add", xhttp_payload(path))
            created_id = cdn["id"]
        bound = bootstrap.object_value(cdn["settings"]).get("clients", [])
        if bound and not any(item["id"] == client["id"] for item in bound):
            raise RuntimeError("CDN inbound belongs to another client")
        if not bound:
            api("clients/" + urllib.parse.quote(client["email"], safe="") + "/attach", {"inboundIds": [cdn["id"]]})
        if direct:
            direct_changed = True
            set_enabled(api, direct["id"], False)
        bootstrap.run("systemctl", "restart", "x-ui")
        bootstrap.wait_panel(credentials)
        check_generated(json.loads(Path("/usr/local/x-ui/bin/config.json").read_text()),
                        [item["id"] for item in clients])
        if not old_state:
            wait_port_free(443)
        bootstrap.run("systemctl", "reload", "nginx")
        wait_https(args.hostname)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        request = urllib.request.Request("https://" + args.hostname + "/health",
                                         headers={"User-Agent": "curl/8.5.0"})
        with opener.open(request, timeout=30) as response:
            checked_cdn_response(response)
        bootstrap.write_private(hook, "#!/bin/sh\nset -eu\nnginx -t\nsystemctl reload nginx\n")
        hook.chmod(0o700)
        bootstrap.run("systemctl", "enable", "--now", "certbot.timer")
        state = {"hostname": args.hostname, "inbound_id": cdn["id"], "path": path,
                 "client_email": client["email"], "legacy_direct_id": recorded["inbound_id"]}
        bootstrap.write_private(STATE, json.dumps(state, indent=2) + "\n")
        link = cdn_link(client["id"], args.hostname, path)
        bootstrap.write_private(STATE.parent / "cloudflare-main.txt", link + "\n")
    except Exception:
        # Restore our files and the prior direct inbound; never replace the live DB.
        for file, content in files_before.items():
            if content is None:
                file.unlink(missing_ok=True)
            else:
                bootstrap.write_private(file, content.decode())
                if file == hook:
                    file.chmod(0o700)
        subprocess.run(["nginx", "-t"], check=False)
        subprocess.run(["systemctl", "reload", "nginx"], check=False)
        if created_id is not None:
            api("inbounds/del/" + str(created_id), {})
        if direct_changed:
            set_enabled(api, old_direct["id"], old_direct["enable"])
        if direct_changed or created_id is not None:
            bootstrap.run("systemctl", "restart", "x-ui")
        raise
    # Commit deletion last; a failed deletion can be safely retried using saved state.
    ensure_public_host(api, cdn["id"], args.hostname, path)
    if direct:
        api("inbounds/del/" + str(direct["id"]), {})
        bootstrap.run("systemctl", "restart", "x-ui")
        bootstrap.wait_panel(credentials)
    recorded.update(direct_removed=True, direct_port=None)
    bootstrap.write_private(bootstrap.STATE, json.dumps(recorded, indent=2) + "\n")
    (STATE.parent / "direct-main.txt").unlink(missing_ok=True)
    print("Panel: https://" + args.hostname + "/" + panel_path + "/")
    print("CDN link:", link)
    print("Direct REALITY removed; panel and XHTTP backend listen on loopback.")


if __name__ == "__main__":
    main()
