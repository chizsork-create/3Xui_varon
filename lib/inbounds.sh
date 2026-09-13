#!/usr/bin/env bash
set -Eeuo pipefail

validate_inbound_name() {
    local value=$1
    [[ $value =~ ^[a-z][a-z0-9_-]{1,31}$ ]]
}

build_sniffing_json() {
    jq --compact-output --null-input '{enabled: true, destOverride: ["http", "tls", "quic"]}'
}

build_reality_inbound_payload() {
    local remark=$1 tag=$2 listen_port=$3 reality_sni=$4 reality_dest=$5
    local private_key=$6 public_key=$7 short_id=$8

    validate_inbound_name "$tag" || die "Invalid inbound tag: $tag"
    validate_tcp_port "$listen_port" || die "Invalid Reality port"
    [[ $reality_sni != */* && $reality_dest != */* ]] || die "Invalid Reality endpoint"

    jq --compact-output --null-input \
        --arg remark "$remark" --arg tag "$tag" --arg reality_sni "$reality_sni" \
        --arg dest "$reality_dest" --arg private_key "$private_key" --arg public_key "$public_key" --arg short_id "$short_id" \
        --argjson port "$listen_port" \
        --arg settings "$(jq -cn '{clients: [], decryption: "none"}')" \
        --arg stream_settings "$(jq -cn \
            --arg reality_sni "$reality_sni" --arg dest "$reality_dest" \
            --arg private_key "$private_key" --arg public_key "$public_key" --arg short_id "$short_id" \
            '{network: "tcp", security: "reality", tcpSettings: {acceptProxyProtocol: true, header: {type: "none"}}, realitySettings: {show: false, xver: 0, target: $dest, serverNames: [$reality_sni], privateKey: $private_key, shortIds: [$short_id], settings: {publicKey: $public_key, fingerprint: "firefox", serverName: $reality_sni, spiderX: "/"}}}')" \
        --arg sniffing "$(build_sniffing_json)" \
        '{remark: $remark, enable: true, listen: "127.0.0.1", port: $port, protocol: "vless", tag: $tag, settings: $settings, streamSettings: $stream_settings, sniffing: $sniffing, subSortIndex: 10}'
}

build_reality_host_group_payload() {
    local remark=$1 public_hostname=$2 reality_sni=$3
    shift 3

    (($# >= 1)) || die "At least one inbound ID is required for a Reality host group"
    [[ $public_hostname != */* && $public_hostname != :* ]] || die "Invalid public hostname"
    [[ $reality_sni != */* && $reality_sni != :* ]] || die "Invalid Reality SNI"

    jq --compact-output --null-input \
        --arg remark "$remark" --arg hostname "$public_hostname" --arg reality_sni "$reality_sni" \
        '{inboundIds: [$ARGS.positional[] | tonumber], remark: $remark, hosts: [$hostname], port: 443, security: "reality", sni: $reality_sni, alpn: [], fingerprint: "firefox"}' \
        --args "$@"
}

build_xhttp_inbound_payload() {
    local remark=$1 tag=$2 socket_path=$3 hostname=$4 path_segment=$5 certificate_file=$6 key_file=$7

    validate_inbound_name "$tag" || die "Invalid inbound tag: $tag"
    validate_nginx_path_segment "$path_segment" || die "Invalid XHTTP path"
    [[ $socket_path == /* && $hostname != */* ]] || die "Invalid XHTTP endpoint"

    jq --compact-output --null-input \
        --arg remark "$remark" --arg tag "$tag" --arg socket_path "${socket_path},0660" \
        --arg hostname "$hostname" --arg path "/${path_segment}" \
        --arg certificate_file "$certificate_file" --arg key_file "$key_file" \
        --arg settings "$(jq -cn '{clients: [], decryption: "none"}')" \
        --arg stream_settings "$(jq -cn \
            --arg hostname "$hostname" --arg path "/${path_segment}" \
            --arg certificate_file "$certificate_file" --arg key_file "$key_file" \
            '{network: "xhttp", security: "tls", xhttpSettings: {path: $path, mode: "packet-up"}, tlsSettings: {serverName: $hostname, alpn: ["h2", "http/1.1"], certificates: [{certificateFile: $certificate_file, keyFile: $key_file}]}}')" \
        --arg sniffing "$(build_sniffing_json)" \
        '{remark: $remark, enable: true, listen: $socket_path, port: 0, protocol: "vless", tag: $tag, settings: $settings, streamSettings: $stream_settings, sniffing: $sniffing, subSortIndex: 20}'
}

build_ws_inbound_payload() {
    local remark=$1 tag=$2 listen_port=$3 path_segment=$4

    validate_inbound_name "$tag" || die "Invalid inbound tag: $tag"
    validate_tcp_port "$listen_port" || die "Invalid WS port"
    validate_nginx_path_segment "$path_segment" || die "Invalid WS path"

    jq --compact-output --null-input \
        --arg remark "$remark" --arg tag "$tag" --arg path "/${path_segment}" \
        --argjson port "$listen_port" \
        --arg settings "$(jq -cn '{clients: [], decryption: "none"}')" \
        --arg stream_settings "$(jq -cn --arg path "/${path_segment}" '{network: "ws", security: "none", wsSettings: {path: $path}}')" \
        --arg sniffing "$(build_sniffing_json)" \
        '{remark: $remark, enable: true, listen: "127.0.0.1", port: $port, protocol: "vless", tag: $tag, settings: $settings, streamSettings: $stream_settings, sniffing: $sniffing, subSortIndex: 30}'
}

build_trojan_grpc_inbound_payload() {
    local remark=$1 tag=$2 listen_port=$3 service_name=$4

    validate_inbound_name "$tag" || die "Invalid inbound tag: $tag"
    validate_tcp_port "$listen_port" || die "Invalid Trojan gRPC port"
    validate_nginx_path_segment "$service_name" || die "Invalid Trojan gRPC service name"

    jq --compact-output --null-input \
        --arg remark "$remark" --arg tag "$tag" --arg service_name "$service_name" \
        --argjson port "$listen_port" \
        --arg settings "$(jq -cn '{clients: []}')" \
        --arg stream_settings "$(jq -cn --arg service_name "$service_name" '{network: "grpc", security: "none", grpcSettings: {serviceName: $service_name}}')" \
        --arg sniffing "$(build_sniffing_json)" \
        '{remark: $remark, enable: true, listen: "127.0.0.1", port: $port, protocol: "trojan", tag: $tag, settings: $settings, streamSettings: $stream_settings, sniffing: $sniffing, subSortIndex: 40}'
}

build_host_group_payload() {
    local remark=$1 hostname=$2 security=$3
    shift 3
    (($# >= 1)) || die "At least one inbound ID is required for a host group"
    [[ $hostname != */* && $hostname != :* ]] || die "Invalid public hostname"
    case "$security" in
        same|tls|reality) ;;
        *) die "Invalid host security: $security" ;;
    esac

    jq --compact-output --null-input \
        --arg remark "$remark" --arg hostname "$hostname" --arg security "$security" \
        '{inboundIds: [$ARGS.positional[] | tonumber], remark: $remark, hosts: [$hostname], port: 443, security: $security, sni: $hostname, alpn: ["h2", "http/1.1"], fingerprint: "chrome"}' \
        --args "$@"
}
