#!/usr/bin/env python3
"""Add named users and CDN-compatible WebSocket alternatives to Cloudflare XHTTP."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import socket
import sqlite3
import subprocess
import time
import urllib.parse
import uuid

spec = importlib.util.spec_from_file_location("configure_cloudflare", Path(__file__).with_name("configure-cloudflare.py"))
cdn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cdn)
b = cdn.bootstrap
STATE = cdn.STATE.parent / "users.json"


def valid_names(names):
    return (bool(names) and len(names) <= 100
            and len({name.casefold() for name in names}) == len(names)
            and all(re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,31}", name) for name in names))


def ws_payload(route):
    settings = {"clients": []}
    if route["protocol"] == "vless":
        settings.update(decryption="none", encryption="none")
    return {"remark": "Cloudflare " + route["label"], "tag": route["tag"], "enable": True,
        "listen": "127.0.0.1", "port": route["port"], "protocol": route["protocol"],
        "up": 0, "down": 0, "total": 0, "expiryTime": 0,
        "settings": json.dumps(settings),
        "streamSettings": json.dumps({"network": "ws", "security": "none",
                                      "wsSettings": {"path": route["path"]}}),
        "sniffing": json.dumps({"enabled": True, "destOverride": ["http", "tls"]})}


def update_payload(record, name):
    # Normalized records use numeric id + uuid; Client updates require string id.
    fields = ("email", "subId", "password", "flow", "enable", "expiryTime", "totalGB",
              "limitIp", "limitHwid", "tgId", "group", "comment", "reset", "resetDay",
              "resetWeekday", "resetMax", "trafficReset", "trafficResetDay")
    payload = {key: record[key] for key in fields if key in record}
    payload["id"] = record["uuid"]
    payload.update(email=name, flow="", password=record.get("password") or secrets.token_hex(24))
    return payload


def new_client(name):
    return {"id": str(uuid.uuid4()), "email": name, "password": secrets.token_hex(24),
            "subId": secrets.token_hex(12), "flow": "", "enable": True,
            "totalGB": 0, "expiryTime": 0, "limitIp": 0, "tgId": 0, "reset": 0}


def subscription_settings(settings, hostname, path):
    cdn.subscription_location(path)  # Validate before updating API settings.
    result = dict(settings)
    result.update(subEnable=True, subListen="127.0.0.1", subPort=2096,
        subPath=path, subDomain=hostname, subCertFile="", subKeyFile="",
        subURI="https://" + hostname + path, subJsonEnable=True,
        subJsonAutoDetect=False, subJsonAlwaysArray=True,
        subJsonPath=path + "json/", subJsonURI="https://" + hostname + path + "json/")
    return result


def ws_link(record, hostname, route):
    protocol = route["protocol"]
    credential = record["uuid"] if protocol == "vless" else record["password"]
    params = {"security": "tls", "sni": hostname, "fp": "chrome", "type": "ws",
              "host": hostname, "path": route["path"], "alpn": "http/1.1"}
    if protocol == "vless":
        params["encryption"] = "none"
    label = urllib.parse.quote(record["email"] + "-" + route["label"])
    return (protocol + "://" + urllib.parse.quote(credential, safe="") + "@" + hostname
            + ":443?" + urllib.parse.urlencode(params) + "#" + label)


def ensure_route(api, route):
    existing = [item for item in api("inbounds/list") if item.get("tag") == route["tag"]]
    if existing:
        if len(existing) != 1:
            raise RuntimeError("Ambiguous managed WebSocket inbound")
        item = existing[0]
        stream = b.object_value(item["streamSettings"])
        if (item["protocol"] != route["protocol"] or item["port"] != route["port"]
                or item["listen"] != "127.0.0.1" or not item["enable"]
                or stream.get("network") != "ws" or stream.get("security") != "none"
                or stream.get("wsSettings", {}).get("path") != route["path"]):
            raise RuntimeError("Managed WebSocket settings differ; refusing to overwrite")
        return item["id"]
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", route["port"]))
    return api("inbounds/add", ws_payload(route))["id"]


def verify_generated(config, routes, records):
    by_port = {item.get("port"): item for item in config["inbounds"]}
    for route in [{"port": 16666, "protocol": "vless"}, *routes]:
        inbound = by_port.get(route["port"])
        if not inbound or inbound.get("listen") != "127.0.0.1":
            raise RuntimeError("Managed listener is missing or publicly exposed")
        clients = inbound["settings"].get("clients", [])
        field = "id" if route["protocol"] == "vless" else "password"
        expected_field = "uuid" if field == "id" else "password"
        for record in records:
            matches = [client for client in clients if client.get(field) == record[expected_field]]
            if len(matches) != 1 or matches[0].get("flow", ""):
                raise RuntimeError("Client is missing, duplicated, or has incompatible Vision flow")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--users", required=True, nargs="+",
                        help="First name is the owner of the existing bootstrap identity")
    parser.add_argument("--enable-subscriptions", action="store_true",
                        help="Publish each user's base64 and JSON subscriptions over verified HTTPS")
    args = parser.parse_args()
    if os.geteuid() != 0 or not valid_names(args.users):
        parser.error("Run as root; use unique ASCII names of 1-32 characters")
    if not cdn.STATE.exists():
        parser.error("Configure Cloudflare first")
    os.umask(0o077)
    state = json.loads(cdn.STATE.read_text())
    hostname = state["hostname"]
    if not cdn.valid_hostname(hostname):
        parser.error("Invalid recorded hostname")
    credentials = b.read_credentials(b.RESULT)
    api = lambda path, payload=None: b.api(credentials, path, payload)
    b.wait_panel(credentials)
    current_link = (STATE.parent / "cloudflare-main.txt").read_text().strip()
    primary_uuid = urllib.parse.urlsplit(current_link).username
    rows = api("clients/list")
    primary = next((record for record in rows if record["uuid"] == primary_uuid), None)
    if primary is None:
        parser.error("Existing owner identity is missing")
    collision = next((record for record in rows if record["email"] == args.users[0]), None)
    if collision and collision["uuid"] != primary_uuid:
        parser.error("First requested name belongs to another user")
    if STATE.exists():
        managed = json.loads(STATE.read_text())
        if managed["hostname"] != hostname or managed["primary_uuid"] != primary_uuid:
            parser.error("Recorded user installation differs")
    else:
        managed = {"hostname": hostname, "primary_uuid": primary_uuid, "transports": [
            {"tag": "cloudflare-vless-ws", "port": 16667, "protocol": "vless",
             "label": "VLESS-WS", "path": "/" + secrets.token_hex(18)},
            {"tag": "cloudflare-trojan-ws", "port": 16668, "protocol": "trojan",
             "label": "Trojan-WS", "path": "/" + secrets.token_hex(18)}]}
    routes = managed["transports"]
    if args.enable_subscriptions and not managed.get("subscription_path"):
        managed["subscription_path"] = "/" + secrets.token_hex(18) + "/"
    subscription_path = managed.get("subscription_path")
    if subscription_path:
        cdn.subscription_location(subscription_path)
    expected = {("cloudflare-vless-ws", 16667, "vless"), ("cloudflare-trojan-ws", 16668, "trojan")}
    if (len(routes) != 2 or {(r["tag"], r["port"], r["protocol"]) for r in routes} != expected
            or any(not re.fullmatch(r"/[a-f0-9]{36}", r["path"]) for r in routes)):
        parser.error("Invalid recorded WebSocket routes")
    old_web = cdn.WEB.read_text()
    if not old_web.startswith("# Managed by 3Xui Varon"):
        parser.error("Nginx file is not managed by this installer")
    backup = STATE.parent / ("x-ui-before-users-" + str(time.time_ns()) + ".db")
    with sqlite3.connect("/etc/x-ui/x-ui.db") as source, sqlite3.connect(backup) as destination:
        source.backup(destination)
    # Save random paths before additive API operations so interrupted runs can resume.
    b.write_private(STATE, json.dumps(managed, indent=2) + "\n")
    for route in routes:
        route["id"] = ensure_route(api, route)
    b.write_private(STATE, json.dumps(managed, indent=2) + "\n")
    targets = [state["inbound_id"], *(route["id"] for route in routes)]
    if primary["email"] != args.users[0] or not primary.get("password"):
        api("clients/update/" + urllib.parse.quote(primary["email"], safe=""),
            update_payload(primary, args.users[0]))
    known = {record["email"] for record in api("clients/list")}
    records = []
    for name in args.users:
        if name not in known:
            api("clients/add", {"client": new_client(name), "inboundIds": targets})
        payload = api("clients/get/" + urllib.parse.quote(name, safe=""))
        record = payload["client"]
        if not record.get("password"):
            api("clients/update/" + urllib.parse.quote(name, safe=""), update_payload(record, name))
            record = api("clients/get/" + urllib.parse.quote(name, safe=""))["client"]
        missing = sorted(set(targets) - set(payload["inboundIds"]))
        if missing:
            api("clients/" + urllib.parse.quote(name, safe="") + "/attach", {"inboundIds": missing})
        records.append(record)
    for route in routes:
        cdn.ensure_public_host(api, route["id"], hostname, route["path"],
                              remark="Cloudflare " + route["label"], alpn=("http/1.1",))
    try:
        if subscription_path:
            api("setting/update", subscription_settings(api("setting/all", {}), hostname, subscription_path))
        b.write_private(cdn.WEB, cdn.web_config(hostname, credentials["XUI_WEB_BASE_PATH"].strip("/"),
                                               int(credentials["XUI_PANEL_PORT"]), state["path"], routes, subscription_path))
        b.run("nginx", "-t")
        b.run("systemctl", "restart", "x-ui")
        b.wait_panel(credentials)
        verify_generated(json.loads(Path("/usr/local/x-ui/bin/config.json").read_text()),
                         routes, records)
        b.run("systemctl", "reload", "nginx")
        cdn.wait_https(hostname)
    except Exception:
        b.write_private(cdn.WEB, old_web)
        subprocess.run(["nginx", "-t"], check=False)
        subprocess.run(["systemctl", "reload", "nginx"], check=False)
        raise
    exports = STATE.parent / "users"
    for record in records:
        xhttp = cdn.cdn_link(record["uuid"], hostname, state["path"]).split("#")[0]
        links = [xhttp + "#" + urllib.parse.quote(record["email"] + "-VLESS-XHTTP"),
                 *(ws_link(record, hostname, route) for route in routes)]
        b.write_private(exports / (record["email"] + ".txt"), "\n".join(links) + "\n")
        if subscription_path:
            url = "https://" + hostname + subscription_path + urllib.parse.quote(record["subId"], safe="")
            b.write_private(exports / (record["email"] + "-subscription.txt"), url + "\n")
    managed["users"] = [record["email"] for record in records]
    b.write_private(STATE, json.dumps(managed, indent=2) + "\n")
    state["client_email"] = args.users[0]
    b.write_private(cdn.STATE, json.dumps(state, indent=2) + "\n")
    print("Users:", ", ".join(managed["users"]))
    print("Each user: VLESS XHTTP, VLESS WS, Trojan WS; verified TLS via Cloudflare.")
    print("Private import files:", exports)
    print("Owner UUID preserved; direct REALITY and Fail2ban remain absent.")


if __name__ == "__main__":
    main()
