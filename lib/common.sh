#!/usr/bin/env bash
set -Eeuo pipefail

info() { printf '[info] %s\n' "$*"; }
ok() { printf '[ ok ] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die() { printf '[fail] %s\n' "$*" >&2; exit 1; }

require_value() {
    local flag=$1 value=$2
    [[ -n "$value" ]] || die "$flag is required"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

validate_tcp_port() {
    local port=$1
    [[ $port =~ ^[0-9]{1,5}$ ]] || return 1
    port=$((10#$port))
    ((port >= 1 && port <= 65535))
}

validate_nginx_path_segment() {
    local value=$1
    [[ $value =~ ^[A-Za-z0-9_-]{8,64}$ ]]
}

require_root() {
    [[ ${EUID:-1} -eq 0 ]] || die "Run this command as root"
}
