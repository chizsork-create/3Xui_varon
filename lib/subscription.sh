#!/usr/bin/env bash
set -Eeuo pipefail

normalize_subscription_path() {
    local value=${1#/}
    value=${value%/}
    [[ $value =~ ^[A-Za-z0-9_-]{8,64}$ ]] || die "Invalid subscription path"
    printf '%s\n' "$value"
}

build_subscription_url() {
    local hostname=$1 subscription_path=$2 sub_id=$3
    subscription_path=$(normalize_subscription_path "$subscription_path")
    [[ $hostname != */* && $hostname != :* && $sub_id =~ ^[A-Za-z0-9]+$ ]] \
        || die "Invalid subscription endpoint"
    printf 'https://%s/%s/%s\n' "$hostname" "$subscription_path" "$sub_id"
}

decode_subscription_body() {
    local body=$1 decoded
    if [[ $body =~ ^[A-Za-z0-9+/=[:space:]]+$ ]] && decoded=$(printf '%s' "$body" | base64 --decode 2>/dev/null); then
        printf '%s\n' "$decoded"
    else
        printf '%s\n' "$body"
    fi
}

subscription_contains_all_transports() {
    local content
    content=$(decode_subscription_body "$(cat)")

    grep -Fq 'vless://' <<<"$content" &&
        grep -Fq 'trojan://' <<<"$content" &&
        grep -Fq 'type=reality' <<<"$content" &&
        grep -Fq 'type=xhttp' <<<"$content" &&
        grep -Fq 'type=grpc' <<<"$content"
}

verify_subscription_url() {
    local hostname=$1 subscription_path=$2 sub_id=$3 response

    command_exists curl || die "curl is required"
    command_exists base64 || die "base64 is required"
    response=$(curl --fail --silent --show-error --insecure \
        --resolve "${hostname}:443:127.0.0.1" \
        --header 'Accept: text/plain, */*;q=0.1' \
        "$(build_subscription_url "$hostname" "$subscription_path" "$sub_id")") \
        || die "Subscription request failed"
    subscription_contains_all_transports <<<"$response" \
        || die "Subscription is missing Reality, XHTTP or Trojan gRPC"
    ok "Unified subscription contains Reality, XHTTP and Trojan gRPC"
}
