#!/usr/bin/env bash
set -Eeuo pipefail

render_xhttp_proxy_location() {
    local path_segment=$1 socket_path=$2 server_name=$3

    validate_nginx_path_segment "$path_segment" || die "Invalid XHTTP path"
    cat <<EOF
location ^~ /${path_segment} {
    proxy_pass https://unix:${socket_path}:;
    proxy_http_version 1.1;
    proxy_ssl_server_name on;
    proxy_ssl_name ${server_name};
    # The backend is a local Unix socket, not a remote TLS peer.
    proxy_ssl_verify off;
    proxy_set_header Connection "";
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_read_timeout 1h;
    proxy_send_timeout 1h;
    client_max_body_size 0;
}
EOF
}

render_stream_config() {
    local panel_host=$1 reality_host=$2 web_tls_port=$3 reality_port=$4

    cat <<EOF
map \$ssl_preread_server_name \$varon_sni_backend {
    hostnames;
    ${reality_host} varon_reality;
    ${panel_host} varon_web;
    default varon_web;
}

upstream varon_reality {
    server 127.0.0.1:${reality_port};
}

upstream varon_web {
    server 127.0.0.1:${web_tls_port};
}

server {
    listen 443;
    proxy_protocol on;
    proxy_pass \$varon_sni_backend;
    ssl_preread on;
}
EOF
}

render_web_vhost() {
    local panel_host=$1 web_tls_port=$2 certificate_file=$3 key_file=$4
    local cover_root=$5 xhttp_path=$6 xhttp_socket=$7

    cat <<EOF
server {
    listen 127.0.0.1:${web_tls_port} ssl http2 proxy_protocol;
    server_name ${panel_host};
    server_tokens off;

    ssl_certificate ${certificate_file};
    ssl_certificate_key ${key_file};
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    root ${cover_root};
    index index.html;

$(render_xhttp_proxy_location "$xhttp_path" "$xhttp_socket" "$panel_host")

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
}

ensure_xhttp_runtime_directory() {
    require_root
    getent group www-data >/dev/null || die "www-data group is missing"
    install -d -o root -g www-data -m 2710 /run/3xui-varon
}
