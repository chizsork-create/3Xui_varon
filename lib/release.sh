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
        --output "$destination" "$VARON_3XUI_ASSET_URL"
    verify_sha256 "$VARON_3XUI_ASSET_SHA256" "$destination"
    ok "Verified official 3X-UI ${VARON_3XUI_VERSION} (${architecture})"
}
