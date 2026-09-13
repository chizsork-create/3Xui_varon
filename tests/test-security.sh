#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$TEST_DIR/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT

# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=../lib/state.sh
source "$ROOT_DIR/lib/state.sh"
# shellcheck source=../lib/security.sh
source "$ROOT_DIR/lib/security.sh"
# shellcheck source=../lib/nginx.sh
source "$ROOT_DIR/lib/nginx.sh"

VARON_STATE_DIR="$TEST_TMP/state"
VARON_STATE_FILE="$VARON_STATE_DIR/install.env"
jail_file="$TEST_TMP/jail.d/varon-sshd.local"

render_fail2ban_sshd_jail "$jail_file"
grep -qx 'maxretry = 3' "$jail_file"
grep -qx 'findtime = 10m' "$jail_file"
grep -qx 'bantime = 24h' "$jail_file"
grep -qx 'ignoreip = 127.0.0.1/8 ::1' "$jail_file"

write_install_state 'example.free-dns.tld' 'vpn.example.free-dns.tld' 22
[[ $(stat -c '%a' "$VARON_STATE_FILE") == '600' ]]
grep -qx 'PANEL_HOST=vpn.example.free-dns.tld' "$VARON_STATE_FILE"

xhttp_location=$(render_xhttp_proxy_location 'XhttpPath1' '/run/3xui-varon/xhttp.sock' 'vpn.example.free-dns.tld')
grep -Fqx '    proxy_pass https://unix:/run/3xui-varon/xhttp.sock:;' <<<"$xhttp_location"
grep -Fqx '    proxy_ssl_name vpn.example.free-dns.tld;' <<<"$xhttp_location"
if grep -Fq 'grpc_pass' <<<"$xhttp_location"; then
    printf 'XHTTP renderer must not emit grpc_pass\n' >&2
    exit 1
fi

panel_location=$(render_panel_proxy_location 'PanelPath1' 2053)
subscription_location=$(render_subscription_proxy_location 'SubPath01' 2096)
trojan_location=$(render_trojan_grpc_proxy_location 'TrojanSvc1' 1443)
grep -Fqx '    proxy_pass http://127.0.0.1:2053;' <<<"$panel_location"
grep -Fqx '    proxy_pass http://127.0.0.1:2096;' <<<"$subscription_location"
grep -Fqx '    grpc_pass grpc://127.0.0.1:1443;' <<<"$trojan_location"

stream_config=$(render_stream_config 'vpn.example.free-dns.tld' 'www.cloudflare.com' 7443 8443)
grep -Fqx '    www.cloudflare.com varon_reality;' <<<"$stream_config"
grep -Fqx '    server 127.0.0.1:7443;' <<<"$stream_config"
grep -Fqx '    proxy_protocol on;' <<<"$stream_config"

acme_vhost=$(render_acme_http_vhost 'vpn.example.free-dns.tld' '/var/www/3xui-varon')
grep -Fqx '    listen 80;' <<<"$acme_vhost"
grep -Fqx '    location ^~ /.well-known/acme-challenge/ {' <<<"$acme_vhost"

web_vhost=$(render_web_vhost 'vpn.example.free-dns.tld' 7443 '/cert.pem' '/key.pem' \
    '/var/www/3xui-varon' 'XhttpPath1' '/run/3xui-varon/xhttp.sock' 'PanelPath1' \
    2053 'SubPath01' 2096 'TrojanSvc1' 1443 'WsPath1' 16666)
grep -Fqx '    listen 127.0.0.1:7443 ssl http2 proxy_protocol;' <<<"$web_vhost"
grep -Fqx '    proxy_pass https://unix:/run/3xui-varon/xhttp.sock:;' <<<"$web_vhost"
grep -Fqx '    grpc_pass grpc://127.0.0.1:1443;' <<<"$web_vhost"

printf 'security tests passed\n'
