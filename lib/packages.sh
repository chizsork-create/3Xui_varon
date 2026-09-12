#!/usr/bin/env bash
set -Eeuo pipefail

install_required_packages() {
    require_root
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install --yes --no-install-recommends \
        ca-certificates certbot curl fail2ban jq libnginx-mod-stream nginx \
        openssl unattended-upgrades ufw
    systemctl enable --now nginx
}
