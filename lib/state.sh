#!/usr/bin/env bash
set -Eeuo pipefail

VARON_STATE_DIR=${VARON_STATE_DIR:-/etc/3xui-varon}
VARON_STATE_FILE=${VARON_STATE_FILE:-"$VARON_STATE_DIR/install.env"}

atomic_install_file() {
    local source_file=$1 destination=$2 mode=$3 destination_dir tmp_file

    destination_dir=$(dirname -- "$destination")
    # A system-owned directory (for example /etc/fail2ban/jail.d) may already
    # have intentionally readable permissions. Create new Varon directories
    # private, but never change mode bits on an existing parent directory.
    [[ -d "$destination_dir" ]] || install -d -m 0700 "$destination_dir"
    tmp_file=$(mktemp "$destination_dir/.varon.XXXXXX")
    install -m "$mode" "$source_file" "$tmp_file"
    mv -f -- "$tmp_file" "$destination"
}

write_install_state() {
    local base_domain=$1 panel_host=$2 reality_host=$3 ssh_port=$4
    local temporary_state

    temporary_state=$(mktemp)
    {
        printf 'STATE_VERSION=1\n'
        printf 'BASE_DOMAIN=%q\n' "$base_domain"
        printf 'PANEL_HOST=%q\n' "$panel_host"
        printf 'REALITY_HOST=%q\n' "$reality_host"
        printf 'SSH_PORT=%q\n' "$ssh_port"
    } >"$temporary_state"
    atomic_install_file "$temporary_state" "$VARON_STATE_FILE" 0600
    rm -f -- "$temporary_state"
}
