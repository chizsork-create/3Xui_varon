#!/usr/bin/env python3
"""Install a loopback-only panel and one direct REALITY client before DNS is ready."""

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import secrets
import shlex
import socket
import sqlite3
import ssl
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

VERSION = "v3.10.0"
INSTALLER_SHA256 = "9684bae4f769b2127fcceceb4f200045657381311867529e6ba76c6b58e2825d"
XUI = Path("/usr/local/x-ui/x-ui")
RESULT = Path("/etc/x-ui/install-result.env")
STATE = Path("/etc/3xui-varon/bootstrap.json")


def object_value(value):
    """3X-UI versions return either JSON strings or decoded objects."""
    return json.loads(value) if isinstance(value, str) else value


def read_credentials(path):
    stat = path.stat()
    if stat.st_uid != 0 or stat.st_mode & 0o077:
        raise RuntimeError("Credential file must be root-owned and mode 600")
    values = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        words = shlex.split(value)
        if len(words) != 1:
            raise RuntimeError("Unsupported credential file format")
        values[key] = words[0]
    for key in ("XUI_USERNAME", "XUI_PASSWORD", "XUI_PANEL_PORT", "XUI_WEB_BASE_PATH", "XUI_API_TOKEN"):
        if not values.get(key):
            raise RuntimeError("Missing credential field: " + key)
    return values


def write_private(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".bootstrap-")
    try:
        with os.fdopen(fd, "w") as output:
            output.write(value)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def api(credentials, endpoint, payload=None):
    port = int(credentials["XUI_PANEL_PORT"])
    base = credentials["XUI_WEB_BASE_PATH"].strip("/")
    url = f"http://127.0.0.1:{port}/{base}/panel/api/{endpoint}"
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(url, data=data, headers={
        "Authorization": "Bearer " + credentials["XUI_API_TOKEN"],
        "Content-Type": "application/json",
    })
    # Local panel management must not pass through environment HTTP proxies.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=30) as response:
        result = json.load(response)
    if not result.get("success"):
        raise RuntimeError("3X-UI rejected " + endpoint)
    return result.get("obj")


def direct_payload(port, host, private_key, public_key, short_id):
    client = {"id": str(uuid.uuid4()), "email": "direct-main", "enable": True,
              "flow": "xtls-rprx-vision", "subId": secrets.token_hex(12),
              "totalGB": 0, "expiryTime": 0, "limitIp": 0, "tgId": "", "reset": 0}
    stream = {"network": "tcp", "security": "reality", "realitySettings": {
        "show": False, "xver": 0, "target": host + ":443", "serverNames": [host],
        "privateKey": private_key, "shortIds": [short_id],
        "settings": {"publicKey": public_key, "fingerprint": "chrome", "serverName": host, "spiderX": "/"},
    }}
    return {"remark": "Direct REALITY", "tag": f"inbound-{port}", "enable": True,
            "listen": "0.0.0.0", "port": port, "protocol": "vless", "expiryTime": 0,
            "up": 0, "down": 0, "total": 0,
            "settings": json.dumps({"clients": [client], "decryption": "none", "encryption": "none"}),
            "streamSettings": json.dumps(stream),
            "sniffing": json.dumps({"enabled": True, "destOverride": ["http", "tls"]})}


def select_existing(inbounds, port, recorded_id=None):
    matches = [item for item in inbounds if item["port"] == port]
    if not matches:
        if recorded_id is not None:
            raise RuntimeError("Recorded inbound is missing; refusing to recreate its client")
        return None
    if len(matches) != 1:
        raise RuntimeError("Ambiguous existing inbound")
    item = matches[0]
    stream = object_value(item["streamSettings"])
    clients = object_value(item["settings"]).get("clients", [])
    if (item["protocol"] != "vless" or not item["enable"]
            or stream.get("security") != "reality" or stream.get("network") != "tcp"
            or len(clients) != 1 or clients[0].get("flow") != "xtls-rprx-vision"
            or not clients[0].get("enable")
            or (recorded_id is not None and item["id"] != recorded_id)):
        raise RuntimeError("Existing inbound is not the expected single-client REALITY configuration")
    return item


def make_link(inbound, address):
    client = object_value(inbound["settings"])["clients"][0]
    reality = object_value(inbound["streamSettings"])["realitySettings"]
    public_key = reality.get("settings", {}).get("publicKey")
    if not public_key or not reality.get("shortIds"):
        raise RuntimeError("REALITY public key or short ID is missing")
    query = urllib.parse.urlencode({"encryption": "none", "security": "reality",
        "sni": reality["serverNames"][0], "fp": "chrome", "pbk": public_key,
        "sid": reality["shortIds"][0], "spx": "/", "type": "tcp", "flow": "xtls-rprx-vision"})
    return f"vless://{client['id']}@{address}:{inbound['port']}?{query}#Zercalo-Direct-REALITY"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def wait_panel(credentials):
    for _ in range(30):
        try:
            api(credentials, "inbounds/list")
            return
        except (OSError, urllib.error.URLError):
            time.sleep(1)
    raise RuntimeError("Panel did not become ready")


def install_panel(panel_port):
    if Path("/etc/x-ui/x-ui.db").exists() or Path("/etc/systemd/system/x-ui.service").exists():
        raise RuntimeError("Partial/existing installation detected; refusing to overwrite it")
    if run("dpkg", "--audit", capture_output=True, text=True).stdout.strip():
        raise RuntimeError("Package configuration is incomplete; repair dpkg before installing")
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", panel_port))
    # Apply the bind address before the installer's first service start.
    dropin = Path("/etc/systemd/system/x-ui.service.d/20-local-panel-listen.conf")
    write_private(dropin, "[Service]\nExecStartPre=/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1\n")
    url = f"https://raw.githubusercontent.com/MHSanaei/3x-ui/{VERSION}/install.sh"
    with urllib.request.urlopen(url, timeout=60) as response:
        installer = response.read()
    if hashlib.sha256(installer).hexdigest() != INSTALLER_SHA256:
        raise RuntimeError("Pinned official installer checksum mismatch")
    installer_path = STATE.parent / ("install-" + VERSION + ".sh")
    write_private(installer_path, installer.decode())
    env = dict(os.environ, DEBIAN_FRONTEND="noninteractive", XUI_NONINTERACTIVE="1",
               XUI_ENABLE_FAIL2BAN="false", XUI_SSL_MODE="none", XUI_DB_TYPE="sqlite",
               XUI_PANEL_PORT=str(panel_port), XUI_PASSWORD=secrets.token_hex(16))
    log_path = STATE.parent / "bootstrap-install.log"
    with open(log_path, "w") as log:
        os.chmod(log_path, 0o600)
        run("bash", str(installer_path), VERSION, env=env, stdout=log, stderr=subprocess.STDOUT)
    if run("dpkg", "--audit", capture_output=True, text=True).stdout.strip():
        raise RuntimeError("Package installation did not finish; inspect bootstrap-install.log")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-ip", required=True, type=ipaddress.IPv4Address)
    parser.add_argument("--panel-port", type=int, default=2053)
    parser.add_argument("--direct-port", type=int, default=8443)
    parser.add_argument("--target", default="www.apple.com")
    parser.add_argument("--adopt-official", action="store_true",
                        help="Adopt a panel installed by the official v3.10.0 installer; keep its clients")
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("Run as root")
    if os.uname().machine != "x86_64":
        parser.error("This bootstrap currently supports amd64 only")
    if not all(1024 <= p <= 65535 for p in (args.panel_port, args.direct_port)) or args.panel_port == args.direct_port:
        parser.error("Use distinct ports between 1024 and 65535")
    if not args.target or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-" for c in args.target):
        parser.error("Target must be a DNS hostname")
    os.umask(0o077)
    if (STATE.parent / "cloudflare.json").exists():
        parser.error("CDN is already configured; use configure-cloudflare.py for further updates")
    STATE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    old_state = json.loads(STATE.read_text()) if STATE.exists() else None
    if old_state and (old_state["server_ip"] != str(args.server_ip) or old_state["direct_port"] != args.direct_port):
        parser.error("Arguments differ from recorded bootstrap; refusing to change the connection")
    if XUI.exists():
        if not (args.adopt_official or old_state):
            parser.error("Panel exists; explicitly use --adopt-official to keep its existing configuration")
        version = run(str(XUI), "-v", capture_output=True, text=True).stdout.strip()
        if version != VERSION.lstrip("v"):
            parser.error("Existing panel version is unsupported; no downgrade will be performed")
    else:
        install_panel(args.panel_port)
    credentials = read_credentials(RESULT)
    if int(credentials["XUI_PANEL_PORT"]) != args.panel_port:
        parser.error("Existing panel port differs; refusing to change it")
    wait_panel(credentials)
    inbounds = api(credentials, "inbounds/list")
    inbound = select_existing(inbounds, args.direct_port, old_state["inbound_id"] if old_state else None)
    if inbound is None:
        with socket.socket() as probe:
            probe.bind(("0.0.0.0", args.direct_port))
        context = ssl.create_default_context()
        context.minimum_version = ssl.TLSVersion.TLSv1_3
        with socket.create_connection((args.target, 443), timeout=15) as sock:
            with context.wrap_socket(sock, server_hostname=args.target):
                pass
    backup = STATE.parent / ("x-ui-before-bootstrap-" + str(time.time_ns()) + ".db")
    with sqlite3.connect("/etc/x-ui/x-ui.db") as source, sqlite3.connect(backup) as destination:
        source.backup(destination)
    settings = api(credentials, "setting/all", {})
    settings.update(webListen="127.0.0.1", subListen="127.0.0.1", subEnable=False)
    api(credentials, "setting/update", settings)
    if inbound is None:
        key_output = run("/usr/local/x-ui/bin/xray-linux-amd64", "x25519", capture_output=True, text=True).stdout
        keys = dict(line.split(":", 1) for line in key_output.splitlines() if ":" in line)
        payload = direct_payload(args.direct_port, args.target, keys["PrivateKey"].strip(),
                                 keys["Password (PublicKey)"].strip(), secrets.token_hex(8))
        inbound = api(credentials, "inbounds/add", payload)
    run("systemctl", "restart", "x-ui")
    wait_panel(credentials)
    inbound = select_existing(api(credentials, "inbounds/list"), args.direct_port, inbound["id"])
    config = json.loads(Path("/usr/local/x-ui/bin/config.json").read_text())
    generated = [i for i in config["inbounds"] if i.get("port") == args.direct_port]
    if len(generated) != 1 or generated[0]["settings"]["clients"][0].get("flow") != "xtls-rprx-vision":
        raise RuntimeError("Generated Xray config lost Vision flow; do not use the link")
    link = make_link(inbound, str(args.server_ip))
    state = {"version": 1, "server_ip": str(args.server_ip), "direct_port": args.direct_port,
             "inbound_id": inbound["id"], "panel_port": args.panel_port}
    write_private(STATE, json.dumps(state, indent=2) + "\n")
    write_private(STATE.parent / "direct-main.txt", link + "\n")
    print("Panel is restricted to loopback; subscriptions disabled; Fail2ban not installed by bootstrap.")
    print("Credentials:", RESULT)
    print("SSH tunnel: ssh -N -L 2053:127.0.0.1:" + str(args.panel_port) + " root@" + str(args.server_ip))
    print("Local panel: http://127.0.0.1:2053/" + credentials["XUI_WEB_BASE_PATH"].strip("/") + "/")
    print("Direct link:", link)


if __name__ == "__main__":
    main()
