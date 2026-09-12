#!/usr/bin/env bash
set -Eeuo pipefail

VARON_CERTBOT_EMAIL=${VARON_CERTBOT_EMAIL:-}

validate_email_address() {
    local value=$1
    [[ $value =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

certificate_file_for_host() {
    local hostname=$1
    printf '/etc/letsencrypt/live/%s/fullchain.pem\n' "$hostname"
}

certificate_key_for_host() {
    local hostname=$1
    printf '/etc/letsencrypt/live/%s/privkey.pem\n' "$hostname"
}

issue_lets_encrypt_certificate() {
    local hostname=$1 webroot=$2 certificate_file certificate_key

    require_root
    validate_email_address "$VARON_CERTBOT_EMAIL" || die "A valid Let's Encrypt email is required"
    command_exists certbot || die "certbot is not installed"
    [[ -d "$webroot" ]] || die "ACME webroot is missing: $webroot"

    certbot certonly --webroot --webroot-path "$webroot" \
        --domain "$hostname" --email "$VARON_CERTBOT_EMAIL" \
        --agree-tos --non-interactive --keep-until-expiring
    certificate_file=$(certificate_file_for_host "$hostname")
    certificate_key=$(certificate_key_for_host "$hostname")
    [[ -r "$certificate_file" && -r "$certificate_key" ]] \
        || die "Let's Encrypt did not create the expected certificate files"
    ok "Let's Encrypt certificate issued for $hostname"
}

install_certificate_renew_hook() {
    local temporary_hook

    require_root
    temporary_hook=$(mktemp)
    cat >"$temporary_hook" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl reload nginx
systemctl try-restart x-ui
EOF
    atomic_install_file "$temporary_hook" /etc/letsencrypt/renewal-hooks/deploy/3xui-varon 0750
    rm -f -- "$temporary_hook"
}
