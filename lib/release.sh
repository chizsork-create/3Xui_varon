#!/usr/bin/env bash
set -Eeuo pipefail

VARON_RELEASES_DIR=${VARON_RELEASES_DIR:-"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/releases"}
VARON_3XUI_RELEASE=${VARON_3XUI_RELEASE:-v3.7.0}

normalize_cpu_architecture() {
    case "${1:-$(uname -m)}" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) die "Unsupported CPU architecture: ${1:-unknown}" ;;
    esac
}

load_3xui_release() {
    local manifest="$VARON_RELEASES_DIR/3x-ui-${VARON_3XUI_RELEASE}.env"
    [[ -r "$manifest" ]] || die "No release manifest for 3X-UI ${VARON_3XUI_RELEASE}"
    # The manifest is versioned with this installer; never accept a user path.
    # shellcheck disable=SC1090
    source "$manifest"
    [[ ${VARON_3XUI_VERSION:-} == "$VARON_3XUI_RELEASE" ]] \
        || die "Invalid 3X-UI release manifest: $manifest"
}

select_3xui_asset() {
    local architecture=$1
    load_3xui_release

    case "$architecture" in
        amd64)
            VARON_3XUI_ASSET="x-ui-linux-amd64.tar.gz"
            VARON_3XUI_ASSET_SHA256=$VARON_3XUI_AMD64_SHA256
            ;;
        arm64)
            VARON_3XUI_ASSET="x-ui-linux-arm64.tar.gz"
            VARON_3XUI_ASSET_SHA256=$VARON_3XUI_ARM64_SHA256
            ;;
        *)
            die "No official 3X-UI asset configured for architecture: $architecture"
            ;;
    esac
    VARON_3XUI_ASSET_URL="https://github.com/MHSanaei/3x-ui/releases/download/${VARON_3XUI_VERSION}/${VARON_3XUI_ASSET}"
}

verify_sha256() {
    local expected=$1 file=$2
    printf '%s  %s\n' "$expected" "$file" | sha256sum --check --status \
        || die "SHA-256 verification failed: $file"
}

download_3xui_release() {
    local destination=$1 architecture
    command_exists curl || die "curl is required"
    command_exists sha256sum || die "sha256sum is required"
    architecture=$(normalize_cpu_architecture)
    select_3xui_asset "$architecture"

    curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
        --connect-timeout 15 --max-time 180 \
        --output "$destination" "$VARON_3XUI_ASSET_URL"
    verify_sha256 "$VARON_3XUI_ASSET_SHA256" "$destination"
    ok "Verified official 3X-UI ${VARON_3XUI_VERSION} (${architecture})"
}

assert_3xui_release_layout() {
    local release_root=$1
    [[ -f "$release_root/x-ui/x-ui" ]] || die "3X-UI archive does not contain x-ui binary"
    [[ -f "$release_root/x-ui/x-ui.sh" ]] || die "3X-UI archive does not contain x-ui.sh"
    [[ -f "$release_root/x-ui/x-ui.service.debian" ]] \
        || die "3X-UI archive does not contain Debian systemd unit"
}

assert_clean_3xui_target() {
    [[ ! -e /usr/local/x-ui && ! -e /etc/systemd/system/x-ui.service ]] \
        || die "3X-UI already exists; this installer only supports a clean install"
}

install_pinned_3xui_release() (
    local temporary_dir archive_file release_root

    require_root
    command_exists tar || die "tar is required"
    command_exists systemctl || die "systemctl is required"
    assert_clean_3xui_target

    temporary_dir=$(mktemp -d)
    trap 'rm -rf -- "$temporary_dir"' EXIT
    archive_file="$temporary_dir/3x-ui.tar.gz"
    release_root="$temporary_dir/release"
    mkdir -p "$release_root"

    download_3xui_release "$archive_file"
    tar --extract --gzip --file "$archive_file" --directory "$release_root" --no-same-owner --no-same-permissions
    assert_3xui_release_layout "$release_root"

    install -d -o root -g root -m 0755 /usr/local/x-ui /etc/x-ui /var/log/x-ui
    cp -a "$release_root/x-ui/." /usr/local/x-ui/
    chown -R root:root /usr/local/x-ui
    chmod 0755 /usr/local/x-ui/x-ui /usr/local/x-ui/x-ui.sh
    install -o root -g root -m 0644 "$release_root/x-ui/x-ui.service.debian" /etc/systemd/system/x-ui.service
    install -o root -g root -m 0755 "$release_root/x-ui/x-ui.sh" /usr/bin/x-ui
    systemctl daemon-reload

    ok "Pinned 3X-UI release installed; service has not been started yet"
)
