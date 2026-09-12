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

VARON_STATE_DIR="$TEST_TMP/state"
VARON_STATE_FILE="$VARON_STATE_DIR/install.env"
jail_file="$TEST_TMP/jail.d/varon-sshd.local"

render_fail2ban_sshd_jail "$jail_file"
grep -qx 'maxretry = 3' "$jail_file"
grep -qx 'findtime = 10m' "$jail_file"
grep -qx 'bantime = 24h' "$jail_file"
grep -qx 'ignoreip = 127.0.0.1/8 ::1' "$jail_file"

write_install_state 'example.free-dns.tld' 'vpn.example.free-dns.tld' \
    'reality.example.free-dns.tld' 22
[[ $(stat -c '%a' "$VARON_STATE_FILE") == '600' ]]
grep -qx 'PANEL_HOST=vpn.example.free-dns.tld' "$VARON_STATE_FILE"

printf 'security tests passed\n'
