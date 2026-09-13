#!/usr/bin/env bash
set -Eeuo pipefail

VARON_WEB_TLS_PORT=${VARON_WEB_TLS_PORT:-7443}
VARON_COVER_ROOT=${VARON_COVER_ROOT:-/var/www/3xui-varon}
VARON_NGINX_HTTP_CONFIG=${VARON_NGINX_HTTP_CONFIG:-/etc/nginx/conf.d/3xui-varon-http.conf}
VARON_NGINX_WEB_CONFIG=${VARON_NGINX_WEB_CONFIG:-/etc/nginx/conf.d/3xui-varon-web.conf}
VARON_NGINX_STREAM_CONFIG=${VARON_NGINX_STREAM_CONFIG:-/etc/nginx/stream-conf.d/3xui-varon.conf}
VARON_NGINX_STREAM_INCLUDE='include /etc/nginx/stream-conf.d/*.conf;'

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

render_panel_proxy_location() {
    local path_segment=$1 panel_port=$2

    validate_nginx_path_segment "$path_segment" || die "Invalid panel path"
    validate_tcp_port "$panel_port" || die "Invalid panel port"
    cat <<EOF
location = /${path_segment} {
    return 301 /${path_segment}/;
}

location ^~ /${path_segment}/ {
    proxy_pass http://127.0.0.1:${panel_port};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 1h;
}
EOF
}

render_ws_proxy_location() {
    local path_segment=$1 ws_port=$2

    validate_nginx_path_segment "$path_segment" || die "Invalid WS path"
    validate_tcp_port "$ws_port" || die "Invalid WS port"
    cat <<EOF
location ^~ /${path_segment} {
    proxy_pass http://127.0.0.1:${ws_port};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 1h;
}
EOF
}

render_subscription_proxy_location() {
    local path_segment=$1 subscription_port=$2

    validate_nginx_path_segment "$path_segment" || die "Invalid subscription path"
    validate_tcp_port "$subscription_port" || die "Invalid subscription port"
    cat <<EOF
location ^~ /${path_segment}/ {
    proxy_pass http://127.0.0.1:${subscription_port};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_buffering off;
}
EOF
}

render_trojan_grpc_proxy_location() {
    local service_name=$1 trojan_port=$2

    validate_nginx_path_segment "$service_name" || die "Invalid Trojan gRPC service name"
    validate_tcp_port "$trojan_port" || die "Invalid Trojan gRPC port"
    cat <<EOF
location ^~ /${service_name} {
    grpc_pass grpc://127.0.0.1:${trojan_port};
    grpc_set_header X-Real-IP \$remote_addr;
    grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    grpc_set_header X-Forwarded-Proto https;
    grpc_read_timeout 1h;
    grpc_send_timeout 1h;
}
EOF
}

render_stream_config() {
    local panel_host=$1 reality_sni=$2 web_tls_port=$3 reality_port=$4

    cat <<EOF
map \$ssl_preread_server_name \$varon_sni_backend {
    hostnames;
    ${reality_sni} varon_reality;
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

render_acme_http_vhost() {
    local panel_host=$1 cover_root=$2

    cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${panel_host};
    server_tokens off;
    root ${cover_root};

    location ^~ /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
}

render_web_vhost() {
    local panel_host=$1 web_tls_port=$2 certificate_file=$3 key_file=$4
    local cover_root=$5 xhttp_path=$6 xhttp_socket=$7 panel_path=$8 panel_port=$9
    local subscription_path=${10} subscription_port=${11} trojan_service=${12} trojan_port=${13}
    local ws_path=${14} ws_port=${15}

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

$(render_ws_proxy_location "$ws_path" "$ws_port")

$(render_panel_proxy_location "$panel_path" "$panel_port")

$(render_subscription_proxy_location "$subscription_path" "$subscription_port")

$(render_trojan_grpc_proxy_location "$trojan_service" "$trojan_port")

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

install_cover_site() {
    local source_file=${VARON_COVER_SITE_FILE:-"$ROOT_DIR/assets/cover-site/index.html"}

    [[ -r "$source_file" ]] || die "Cover site file is missing: $source_file"
    install -d -o root -g root -m 0755 "$VARON_COVER_ROOT"
    install -o root -g root -m 0644 "$source_file" "$VARON_COVER_ROOT/index.html"
}

ensure_nginx_stream_include() {
    local temporary_config

    require_root
    [[ -r /etc/nginx/nginx.conf ]] || die "nginx.conf is missing"
    if grep -Fqx 'stream {' /etc/nginx/nginx.conf && grep -Fq "$VARON_NGINX_STREAM_INCLUDE" /etc/nginx/nginx.conf; then
        return 0
    fi

    temporary_config=$(mktemp)
    grep -Fvx "$VARON_NGINX_STREAM_INCLUDE" /etc/nginx/nginx.conf >"$temporary_config" || true
    cat >>"$temporary_config" <<EOF

stream {
    ${VARON_NGINX_STREAM_INCLUDE}
}
EOF
    atomic_install_file "$temporary_config" /etc/nginx/nginx.conf 0644
    rm -f -- "$temporary_config"
}

install_acme_http_vhost() {
    local panel_host=$1 temporary_config

    require_root
    install -d -o root -g root -m 0755 "$VARON_COVER_ROOT"
    temporary_config=$(mktemp)
    render_acme_http_vhost "$panel_host" "$VARON_COVER_ROOT" >"$temporary_config"
    atomic_install_file "$temporary_config" "$VARON_NGINX_HTTP_CONFIG" 0644
    rm -f -- "$temporary_config"
    nginx -t
    systemctl reload nginx
}

install_nginx_proxy_stack() {
    local panel_host=$1 certificate_file=$2 key_file=$3
    local temporary_web temporary_stream

    require_root
    validate_tcp_port "$VARON_WEB_TLS_PORT" || die "Invalid Nginx TLS port"
    ensure_xhttp_runtime_directory
    install_cover_site
    install -d -o root -g root -m 0755 /etc/nginx/stream-conf.d
    ensure_nginx_stream_include

    temporary_web=$(mktemp)
    temporary_stream=$(mktemp)
    render_web_vhost "$panel_host" "$VARON_WEB_TLS_PORT" "$certificate_file" "$key_file" \
        "$VARON_COVER_ROOT" "$VARON_XHTTP_PATH" "$VARON_XHTTP_SOCKET" \
        "$VARON_PANEL_PATH" "$VARON_PANEL_INTERNAL_PORT" "$VARON_SUBSCRIPTION_PATH" \
        "$VARON_SUBSCRIPTION_INTERNAL_PORT" "$VARON_TROJAN_SERVICE" \
        "$VARON_TROJAN_INTERNAL_PORT" "$VARON_WS_PATH" "$VARON_WS_INTERNAL_PORT" >"$temporary_web"
    render_stream_config "$panel_host" "$VARON_REALITY_SNI" "$VARON_WEB_TLS_PORT" \
        "$VARON_REALITY_INTERNAL_PORT" >"$temporary_stream"
    atomic_install_file "$temporary_web" "$VARON_NGINX_WEB_CONFIG" 0644
    atomic_install_file "$temporary_stream" "$VARON_NGINX_STREAM_CONFIG" 0644
    rm -f -- "$temporary_web" "$temporary_stream"
    nginx -t
    systemctl reload nginx
}
