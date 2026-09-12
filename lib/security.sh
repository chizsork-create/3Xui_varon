#!/usr/bin/env bash
set -Eeuo pipefail

render_fail2ban_sshd_jail() {
    local destination=$1 temporary_file

    temporary_file=$(mktemp)
    cat >"$temporary_file" <<'EOF'
[sshd]
enabled = true
backend = systemd
maxretry = 3
findtime = 10m
bantime = 24h
ignoreip = 127.0.0.1/8 ::1
EOF
    atomic_install_file "$temporary_file" "$destination" 0644
    rm -f -- "$temporary_file"
}

configure_ufw() {
    local ssh_port=$1 enable_udp_443=${2:-false}

    require_root
    validate_tcp_port "$ssh_port" || die "Invalid SSH port: $ssh_port"
    command_exists ufw || die "ufw is not installed"

    # Add access before changing policies, so an SSH session never relies on a
    # transient open firewall state.
    ufw allow "${ssh_port}/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    [[ $enable_udp_443 == true ]] && ufw allow 443/udp
    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable
    ok "UFW allows SSH:$ssh_port, HTTP:80 and HTTPS:443 only"
}

configure_fail2ban() {
    require_root
    command_exists fail2ban-client || die "fail2ban is not installed"
    render_fail2ban_sshd_jail /etc/fail2ban/jail.d/varon-sshd.local
    systemctl enable --now fail2ban
    systemctl restart fail2ban
    fail2ban-client status sshd >/dev/null
    ok "Fail2ban SSH jail enabled"
}

configure_security_updates() {
    local temporary_file

    require_root
    command_exists unattended-upgrade || die "unattended-upgrades is not installed"
    temporary_file=$(mktemp)
    cat >"$temporary_file" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    atomic_install_file "$temporary_file" /etc/apt/apt.conf.d/20auto-upgrades 0644
    rm -f -- "$temporary_file"
    systemctl enable apt-daily.timer apt-daily-upgrade.timer
    ok "Automatic security updates enabled"
}
