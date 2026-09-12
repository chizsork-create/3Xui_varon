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

printf 'config tests passed\n'
