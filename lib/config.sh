#!/usr/bin/env bash
set -Eeuo pipefail

is_dns_label() {
    local value=$1
    [[ $value =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

is_base_domain() {
    local value=${1,,}
    local label

    [[ ${#value} -le 253 && $value == *.* ]] || return 1
    IFS='.' read -r -a labels <<< "$value"
    for label in "${labels[@]}"; do
        is_dns_label "$label" || return 1
    done
}

make_hostname() {
    local base_domain=${1,,} subdomain=${2,,}
    printf '%s.%s\n' "$subdomain" "$base_domain"
}

validate_domain_inputs() {
    local base_domain=$1 panel_subdomain=$2 reality_subdomain=$3

    is_base_domain "$base_domain" || die "Invalid base domain: $base_domain"
    is_dns_label "$panel_subdomain" || die "Invalid panel subdomain: $panel_subdomain"
    is_dns_label "$reality_subdomain" || die "Invalid REALITY subdomain: $reality_subdomain"
    [[ ${panel_subdomain,,} != ${reality_subdomain,,} ]] \
        || die "Panel and REALITY subdomains must differ"
}
