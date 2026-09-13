#!/usr/bin/env bash
set -Eeuo pipefail

check_ubuntu_2404() {
    [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ ${ID:-} == "ubuntu" && ${VERSION_ID:-} == "24.04" ]] \
        || die "Only Ubuntu 24.04 is supported (detected: ${PRETTY_NAME:-unknown})"
    ok "Ubuntu 24.04 detected"
}

resolve_ipv4() {
    local hostname=$1

    if command_exists getent; then
        getent ahostsv4 "$hostname" | awk 'NR == 1 { print $1; exit }'
    elif command_exists dig; then
        dig +short A "$hostname" | awk 'NF { print; exit }'
    fi
}

public_ipv4() {
    curl --fail --silent --show-error --max-time 8 https://api.ipify.org
}

check_hostname_points_to_server() {
    local hostname=$1 expected_ip=$2 resolved_ip
    resolved_ip=$(resolve_ipv4 "$hostname" || true)

    [[ -n "$resolved_ip" ]] || die "No IPv4 A record for $hostname"
    [[ $resolved_ip == "$expected_ip" ]] \
        || die "$hostname resolves to $resolved_ip, expected $expected_ip"
    ok "$hostname → $resolved_ip"
}

check_port_available() {
    local port=$1
    if command_exists ss && ss -ltnH "sport = :$port" | grep -q .; then
        die "TCP port $port is already in use"
    fi
    ok "TCP port $port is available"
}

run_preflight() {
    local base_domain=$1 panel_subdomain=$2
    local panel_host server_ip

    validate_domain_inputs "$base_domain" "$panel_subdomain"
    panel_host=$(make_hostname "$base_domain" "$panel_subdomain")

    info "Panel/subscription hostname: $panel_host"
    check_ubuntu_2404
    command_exists curl || die "curl is required"
    server_ip=$(public_ipv4) || die "Unable to detect the public IPv4 address"
    ok "Public IPv4: $server_ip"
    check_hostname_points_to_server "$panel_host" "$server_ip"
    check_port_available 80
    check_port_available 443
    ok "Preflight passed. No changes were made."
}
