#!/usr/bin/env bash
set -Eeuo pipefail

VARON_XUI_BIN=${VARON_XUI_BIN:-/usr/local/x-ui/x-ui}
VARON_PANEL_INTERNAL_PORT=${VARON_PANEL_INTERNAL_PORT:-2053}
VARON_SUBSCRIPTION_INTERNAL_PORT=${VARON_SUBSCRIPTION_INTERNAL_PORT:-2096}

validate_panel_username() {
    local value=$1
    [[ $value =~ ^[a-z][a-z0-9_-]{5,31}$ ]]
}

generate_panel_credentials() {
    local suffix
    suffix=$(generate_client_token 5)
    VARON_PANEL_USERNAME="panel-${suffix}"
    VARON_PANEL_PASSWORD=$(generate_client_token 24)
}

configure_fresh_panel() {
    local panel_path=$1

    require_root
    validate_nginx_path_segment "$panel_path" || die "Invalid panel path"
    validate_panel_username "$VARON_PANEL_USERNAME" || die "Invalid panel username"
    [[ -x "$VARON_XUI_BIN" ]] || die "3X-UI binary is missing"
    validate_tcp_port "$VARON_PANEL_INTERNAL_PORT" || die "Invalid panel internal port"

    "$VARON_XUI_BIN" setting \
        -username "$VARON_PANEL_USERNAME" \
        -password "$VARON_PANEL_PASSWORD" \
        -webBasePath "$panel_path" \
        -listenIP 127.0.0.1 \
        -port "$VARON_PANEL_INTERNAL_PORT" >/dev/null
    ok "3X-UI bootstrap is restricted to 127.0.0.1"
}

write_panel_state() {
    local destination=$1 temporary_state

    temporary_state=$(mktemp)
    {
        printf 'PANEL_USERNAME=%q\n' "$VARON_PANEL_USERNAME"
        printf 'PANEL_PASSWORD=%q\n' "$VARON_PANEL_PASSWORD"
        printf 'PANEL_INTERNAL_PORT=%q\n' "$VARON_PANEL_INTERNAL_PORT"
        printf 'SUBSCRIPTION_INTERNAL_PORT=%q\n' "$VARON_SUBSCRIPTION_INTERNAL_PORT"
    } >"$temporary_state"
    atomic_install_file "$temporary_state" "$destination" 0600
    rm -f -- "$temporary_state"
}
