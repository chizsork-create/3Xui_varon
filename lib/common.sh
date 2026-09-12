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
