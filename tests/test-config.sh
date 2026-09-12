#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$TEST_DIR/.." && pwd)

# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/security.sh"
source "$ROOT_DIR/lib/clients.sh"
# shellcheck source=../lib/panel.sh
source "$ROOT_DIR/lib/panel.sh"
# shellcheck source=../lib/release.sh
source "$ROOT_DIR/lib/release.sh"

assert_true() {
    "$@" || { printf 'Assertion failed: %s\n' "$*" >&2; exit 1; }
}

assert_false() {
    if "$@"; then
        printf 'Expected false: %s\n' "$*" >&2
        exit 1
    fi
}

assert_true is_dns_label vpn
assert_true is_dns_label vpn-1
assert_false is_dns_label -vpn
assert_false is_dns_label VPN
assert_true is_base_domain example.free-dns.tld
assert_false is_base_domain localhost
assert_false is_base_domain '-bad.example'
[[ $(make_hostname 'Example.Free-DNS.TLD' 'VPN') == 'vpn.example.free-dns.tld' ]]
assert_true validate_tcp_port 1
assert_true validate_tcp_port 65535
assert_false validate_tcp_port 0
assert_false validate_tcp_port 65536
assert_false validate_tcp_port ssh
assert_true validate_client_name varon
assert_true validate_client_name client_1
assert_false validate_client_name Varon
assert_false validate_client_name 1client
assert_true validate_panel_username panel-a1b2
assert_false validate_panel_username Admin
[[ $(normalize_cpu_architecture x86_64) == 'amd64' ]]
[[ $(normalize_cpu_architecture aarch64) == 'arm64' ]]
select_3xui_asset amd64
[[ $VARON_3XUI_ASSET == 'x-ui-linux-amd64.tar.gz' ]]
[[ $VARON_3XUI_ASSET_SHA256 == '0f8dd7baef3458f6591574e24814f322cf7f5e1e27f0a594683745e50be84ec5' ]]

release_fixture=$(mktemp -d)
trap 'rm -rf -- "$release_fixture"' EXIT
mkdir -p "$release_fixture/x-ui"
touch "$release_fixture/x-ui/x-ui" "$release_fixture/x-ui/x-ui.sh" "$release_fixture/x-ui/x-ui.service.debian"
assert_3xui_release_layout "$release_fixture"
rm -f "$release_fixture/x-ui/x-ui.sh"
if (assert_3xui_release_layout "$release_fixture"); then
    printf 'Invalid release layout was accepted\n' >&2
    exit 1
fi

printf 'config tests passed\n'
