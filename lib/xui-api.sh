#!/usr/bin/env bash
set -Eeuo pipefail

normalize_web_base_path() {
    local value=${1#/}
    value=${value%/}
    [[ -n "$value" ]] || die "3X-UI web base path cannot be empty"
    [[ $value =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid 3X-UI web base path"
    printf '%s\n' "$value"
}

xui_panel_url() {
    local hostname=$1 web_base_path=$2 normalized_path
    normalized_path=$(normalize_web_base_path "$web_base_path")
    printf 'https://%s/%s\n' "$hostname" "$normalized_path"
}

xui_api_url() {
    local hostname=$1 web_base_path=$2 endpoint=$3
    printf '%s/panel/api/%s\n' "$(xui_panel_url "$hostname" "$web_base_path")" "${endpoint#/}"
}

xui_success_response() {
    jq --exit-status -e '.success == true' >/dev/null
}

xui_login() {
    local hostname=$1 web_base_path=$2 username=$3 password=$4
    local cookie_file request_file response

    command_exists curl || die "curl is required"
    cookie_file=$(mktemp)
    request_file=$(mktemp)
    chmod 0600 "$cookie_file" "$request_file"
    jq --null-input --arg username "$username" --arg password "$password" \
        '{username: $username, password: $password}' >"$request_file"

    response=$(curl --fail --silent --show-error --insecure \
        --resolve "${hostname}:443:127.0.0.1" \
        --cookie-jar "$cookie_file" \
        --header 'Content-Type: application/json' \
        --data-binary "@$request_file" \
        "$(xui_panel_url "$hostname" "$web_base_path")/login") || {
        rm -f -- "$cookie_file" "$request_file"
        die "3X-UI login request failed"
    }
    rm -f -- "$request_file"
    xui_success_response <<<"$response" || {
        rm -f -- "$cookie_file"
        die "3X-UI rejected the installer session"
    }
    printf '%s\n' "$cookie_file"
}

xui_api_post() {
    local hostname=$1 web_base_path=$2 cookie_file=$3 endpoint=$4 payload=$5
    local request_file response

    request_file=$(mktemp)
    chmod 0600 "$request_file"
    printf '%s\n' "$payload" >"$request_file"
    response=$(curl --fail --silent --show-error --insecure \
        --resolve "${hostname}:443:127.0.0.1" \
        --cookie "$cookie_file" \
        --header 'Content-Type: application/json' \
        --data-binary "@$request_file" \
        "$(xui_api_url "$hostname" "$web_base_path" "$endpoint")") || {
        rm -f -- "$request_file"
        die "3X-UI API request failed: $endpoint"
    }
    rm -f -- "$request_file"
    xui_success_response <<<"$response" || die "3X-UI rejected API request: $endpoint"
    printf '%s\n' "$response"
}

xui_create_shared_client() {
    local hostname=$1 web_base_path=$2 cookie_file=$3 payload=$4

    xui_api_post "$hostname" "$web_base_path" "$cookie_file" clients/add "$payload" >/dev/null
}
