#!/usr/bin/env bash
set -Eeuo pipefail

VARON_REALITY_INTERNAL_PORT=${VARON_REALITY_INTERNAL_PORT:-8443}
VARON_TROJAN_INTERNAL_PORT=${VARON_TROJAN_INTERNAL_PORT:-1443}
VARON_WS_INTERNAL_PORT=${VARON_WS_INTERNAL_PORT:-16666}
VARON_XHTTP_SOCKET=${VARON_XHTTP_SOCKET:-/run/3xui-varon/xhttp.sock}
VARON_REALITY_DEST=${VARON_REALITY_DEST:-www.cloudflare.com:443}

generate_transport_identifiers() {
    VARON_XHTTP_PATH=$(generate_client_token 12)
    VARON_WS_PATH=$(generate_client_token 12)
    VARON_TROJAN_SERVICE=$(generate_client_token 12)
    VARON_REALITY_SHORT_ID=$(generate_client_token 8)
}

generate_reality_keypair() {
    local architecture xray_binary output

    architecture=$(normalize_cpu_architecture)
    xray_binary="/usr/local/x-ui/bin/xray-linux-${architecture}"
    [[ -x "$xray_binary" ]] || die "Xray binary is missing: $xray_binary"
    output=$("$xray_binary" x25519)
    VARON_REALITY_PRIVATE_KEY=$(sed -nE 's/^Private(Key| key):[[:space:]]*//p' <<<"$output")
    VARON_REALITY_PUBLIC_KEY=$(sed -nE 's/^(Public key|Password \(PublicKey\)):[[:space:]]*//p' <<<"$output")
    [[ -n $VARON_REALITY_PRIVATE_KEY && -n $VARON_REALITY_PUBLIC_KEY ]] \
        || die "Could not generate Reality key pair"
}

xui_response_object_id() {
    jq --exit-status -er '.obj.id | tonumber'
}

write_transport_state() {
    local destination=$1 temporary_state

    temporary_state=$(mktemp)
    {
        printf 'XHTTP_PATH=%q\n' "$VARON_XHTTP_PATH"
        printf 'WS_PATH=%q\n' "$VARON_WS_PATH"
        printf 'TROJAN_GRPC_SERVICE=%q\n' "$VARON_TROJAN_SERVICE"
        printf 'REALITY_SHORT_ID=%q\n' "$VARON_REALITY_SHORT_ID"
        printf 'REALITY_PUBLIC_KEY=%q\n' "$VARON_REALITY_PUBLIC_KEY"
    } >"$temporary_state"
    atomic_install_file "$temporary_state" "$destination" 0600
    rm -f -- "$temporary_state"
}

provision_default_transports() (
    local panel_host=$1 reality_host=$2 certificate_file=$3 key_file=$4
    local cookie_file response reality_id xhttp_id ws_id trojan_id client_payload

    validate_tcp_port "$VARON_REALITY_INTERNAL_PORT" || die "Invalid Reality internal port"
    validate_tcp_port "$VARON_TROJAN_INTERNAL_PORT" || die "Invalid Trojan internal port"
    validate_tcp_port "$VARON_WS_INTERNAL_PORT" || die "Invalid WS port"
    [[ -n ${VARON_PANEL_PATH:-} && -n ${VARON_SUBSCRIPTION_PATH:-} ]] \
        || die "Panel and subscription paths must be set before provisioning"
    [[ -n ${VARON_XHTTP_PATH:-} && -n ${VARON_WS_PATH:-} && -n ${VARON_TROJAN_SERVICE:-} ]] \
        || die "Transport identifiers must be generated before provisioning"
    [[ -n ${VARON_REALITY_PRIVATE_KEY:-} && -n ${VARON_REALITY_PUBLIC_KEY:-} && -n ${VARON_REALITY_SHORT_ID:-} ]] \
        || die "Reality keys must be generated before provisioning"

    cookie_file=$(xui_login "$panel_host" "$VARON_PANEL_PATH" \
        "$VARON_PANEL_USERNAME" "$VARON_PANEL_PASSWORD")
    trap 'rm -f -- "$cookie_file"' EXIT

    response=$(xui_api_post "$panel_host" "$VARON_PANEL_PATH" "$cookie_file" inbounds/add \
        "$(build_reality_inbound_payload 'Reality' 'reality-varon' "$VARON_REALITY_INTERNAL_PORT" "$reality_host" "$VARON_REALITY_DEST" "$VARON_REALITY_PRIVATE_KEY" "$VARON_REALITY_PUBLIC_KEY" "$VARON_REALITY_SHORT_ID")")
    reality_id=$(xui_response_object_id <<<"$response")

    response=$(xui_api_post "$panel_host" "$VARON_PANEL_PATH" "$cookie_file" inbounds/add \
        "$(build_xhttp_inbound_payload 'XHTTP' 'xhttp-varon' "$VARON_XHTTP_SOCKET" "$panel_host" "$VARON_XHTTP_PATH" "$certificate_file" "$key_file")")
    xhttp_id=$(xui_response_object_id <<<"$response")

    response=$(xui_api_post "$panel_host" "$VARON_PANEL_PATH" "$cookie_file" inbounds/add \
        "$(build_ws_inbound_payload 'WS' 'ws-varon' "$VARON_WS_INTERNAL_PORT" "$VARON_WS_PATH")")
    ws_id=$(xui_response_object_id <<<"$response")

    response=$(xui_api_post "$panel_host" "$VARON_PANEL_PATH" "$cookie_file" inbounds/add \
        "$(build_trojan_grpc_inbound_payload 'Trojan gRPC' 'trojan-grpc-varon' "$VARON_TROJAN_INTERNAL_PORT" "$VARON_TROJAN_SERVICE")")
    trojan_id=$(xui_response_object_id <<<"$response")

    xui_api_post "$panel_host" "$VARON_PANEL_PATH" "$cookie_file" hosts/add \
        "$(build_host_group_payload 'public-tls' "$panel_host" tls "$xhttp_id" "$ws_id" "$trojan_id")" >/dev/null
    xui_api_post "$panel_host" "$VARON_PANEL_PATH" "$cookie_file" hosts/add \
        "$(build_host_group_payload 'public-reality' "$reality_host" same "$reality_id")" >/dev/null

    client_payload=$(build_client_create_payload "$VARON_SHARED_CLIENT_JSON" \
        "$reality_id" "$xhttp_id" "$ws_id" "$trojan_id")
    xui_create_shared_client "$panel_host" "$VARON_PANEL_PATH" "$cookie_file" "$client_payload"
    ok "Created one client with a shared subscription across four transports"
)
