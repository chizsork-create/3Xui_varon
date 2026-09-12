#!/usr/bin/env bash
set -Eeuo pipefail

validate_client_name() {
    local value=$1
    [[ $value =~ ^[a-z][a-z0-9_-]{1,31}$ ]]
}

epoch_millis() {
    date +%s%3N
}

generate_client_uuid() {
    [[ -r /proc/sys/kernel/random/uuid ]] || die "Cannot generate UUID"
    cat /proc/sys/kernel/random/uuid
}

generate_client_token() {
    local bytes=${1:-12}
    command_exists openssl || die "openssl is required to generate client secrets"
    openssl rand -hex "$bytes"
}

build_vless_client_json() {
    local client_id=$1 email=$2 sub_id=$3 created_at=${4:-$(epoch_millis)}

    jq --compact-output --null-input \
        --arg id "$client_id" \
        --arg email "$email" \
        --arg sub_id "$sub_id" \
        --argjson created_at "$created_at" \
        '{
            id: $id,
            email: $email,
            enable: true,
            expiryTime: 0,
            totalGB: 0,
            limitIp: 0,
            tgId: "",
            subId: $sub_id,
            reset: 0,
            flow: "",
            created_at: $created_at,
            updated_at: $created_at
        }'
}

build_trojan_client_json() {
    local password=$1 email=$2 sub_id=$3 created_at=${4:-$(epoch_millis)}

    jq --compact-output --null-input \
        --arg password "$password" \
        --arg email "$email" \
        --arg sub_id "$sub_id" \
        --argjson created_at "$created_at" \
        '{
            password: $password,
            email: $email,
            enable: true,
            expiryTime: 0,
            totalGB: 0,
            limitIp: 0,
            tgId: "",
            subId: $sub_id,
            reset: 0,
            comment: "",
            created_at: $created_at,
            updated_at: $created_at
        }'
}

build_shared_client_json() {
    local client_id=$1 password=$2 email=$3 sub_id=$4 created_at=${5:-$(epoch_millis)}

    jq --compact-output --null-input \
        --arg id "$client_id" \
        --arg password "$password" \
        --arg email "$email" \
        --arg sub_id "$sub_id" \
        --argjson created_at "$created_at" \
        '{
            id: $id,
            password: $password,
            email: $email,
            enable: true,
            expiryTime: 0,
            totalGB: 0,
            limitIp: 0,
            tgId: 0,
            subId: $sub_id,
            reset: 0,
            flow: "",
            comment: "",
            created_at: $created_at,
            updated_at: $created_at
        }'
}

build_client_create_payload() {
    local shared_client=$1
    shift
    (($# >= 1)) || die "At least one inbound ID is required"

    jq --compact-output --null-input \
        --argjson client "$shared_client" \
        '{client: $client, inboundIds: [$ARGS.positional[] | tonumber]}' \
        --args "$@"
}

create_default_client_material() {
    local client_name=$1

    validate_client_name "$client_name" \
        || die "Client name must start with a lowercase letter and contain only a-z, 0-9, _ or -"
    VARON_CLIENT_NAME=$client_name
    VARON_CLIENT_SUB_ID=$(generate_client_token 8)
    VARON_CLIENT_UUID=$(generate_client_uuid)
    VARON_CLIENT_TROJAN_PASSWORD=$(generate_client_token 18)
    VARON_SHARED_CLIENT_JSON=$(build_shared_client_json \
        "$VARON_CLIENT_UUID" "$VARON_CLIENT_TROJAN_PASSWORD" \
        "$VARON_CLIENT_NAME" "$VARON_CLIENT_SUB_ID")
    VARON_VLESS_CLIENT_JSON=$(build_vless_client_json \
        "$VARON_CLIENT_UUID" "$VARON_CLIENT_NAME" "$VARON_CLIENT_SUB_ID")
    VARON_TROJAN_CLIENT_JSON=$(build_trojan_client_json \
        "$VARON_CLIENT_TROJAN_PASSWORD" "$VARON_CLIENT_NAME" "$VARON_CLIENT_SUB_ID")
}

write_client_state() {
    local destination=$1 temporary_state

    temporary_state=$(mktemp)
    {
        printf 'CLIENT_NAME=%q\n' "$VARON_CLIENT_NAME"
        printf 'CLIENT_SUB_ID=%q\n' "$VARON_CLIENT_SUB_ID"
        printf 'SUBSCRIPTION_PATH=%q\n' "$VARON_SUBSCRIPTION_PATH"
        printf 'CLIENT_UUID=%q\n' "$VARON_CLIENT_UUID"
        printf 'CLIENT_TROJAN_PASSWORD=%q\n' "$VARON_CLIENT_TROJAN_PASSWORD"
    } >"$temporary_state"
    atomic_install_file "$temporary_state" "$destination" 0600
    rm -f -- "$temporary_state"
}
