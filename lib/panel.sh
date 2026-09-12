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

wait_for_local_panel() {
    local panel_path=$1 attempt
    local -a host_args=()

    [[ -n ${VARON_XUI_LOCAL_HOST_HEADER:-} ]] && host_args=(--header "Host: $VARON_XUI_LOCAL_HOST_HEADER")
    for attempt in {1..30}; do
        if curl --fail --silent --show-error --max-time 2 \
            "${host_args[@]}" \
            "$(xui_local_panel_url "$VARON_PANEL_INTERNAL_PORT" "$panel_path")/" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    die "3X-UI did not start on its loopback listener"
}

write_panel_state() {
    local destination=$1 temporary_state

    temporary_state=$(mktemp)
    {
        printf 'PANEL_USERNAME=%q\n' "$VARON_PANEL_USERNAME"
        printf 'PANEL_PASSWORD=%q\n' "$VARON_PANEL_PASSWORD"
        printf 'PANEL_PATH=%q\n' "$VARON_PANEL_PATH"
        printf 'PANEL_INTERNAL_PORT=%q\n' "$VARON_PANEL_INTERNAL_PORT"
        printf 'SUBSCRIPTION_INTERNAL_PORT=%q\n' "$VARON_SUBSCRIPTION_INTERNAL_PORT"
    } >"$temporary_state"
    atomic_install_file "$temporary_state" "$destination" 0600
    rm -f -- "$temporary_state"
}

build_subscription_settings_payload() {
    local existing_settings=$1 panel_host=$2 subscription_path=$3
    local normalized_path

    normalized_path=$(normalize_subscription_path "$subscription_path")
    jq --compact-output \
        --arg panel_host "$panel_host" --arg subscription_path "/${normalized_path}/" \
        '. + {
            webListen: "127.0.0.1",
            webDomain: $panel_host,
            subEnable: true,
            subListen: "127.0.0.1",
            subPort: 2096,
            subPath: $subscription_path,
            subDomain: $panel_host,
            subCertFile: "",
            subKeyFile: "",
            subURI: ("https://" + $panel_host + $subscription_path),
            trustedProxyCIDRs: "127.0.0.1/32,::1/128"
        }' <<<"$existing_settings"
}

configure_panel_subscription_service() {
    local panel_path=$1 panel_host=$2 subscription_path=$3 cookie_file response settings payload

    cookie_file=$(xui_local_login "$VARON_PANEL_INTERNAL_PORT" "$panel_path" \
        "$VARON_PANEL_USERNAME" "$VARON_PANEL_PASSWORD")
    response=$(xui_local_api_post "$VARON_PANEL_INTERNAL_PORT" "$panel_path" \
        "$cookie_file" setting/all '{}')
    settings=$(jq --exit-status --compact-output '.obj' <<<"$response") || {
        rm -f -- "$cookie_file"
        die "3X-UI did not return its settings"
    }
    payload=$(build_subscription_settings_payload "$settings" "$panel_host" "$subscription_path")
    xui_local_api_post "$VARON_PANEL_INTERNAL_PORT" "$panel_path" \
        "$cookie_file" setting/update "$payload" >/dev/null
    rm -f -- "$cookie_file"
    ok "Subscription service is bound to 127.0.0.1"
}
