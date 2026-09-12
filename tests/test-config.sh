#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$TEST_DIR/.." && pwd)

# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"

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

printf 'config tests passed\n'
