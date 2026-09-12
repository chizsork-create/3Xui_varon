#!/usr/bin/env bash
set -Eeuo pipefail

VARON_BACKUP_DIR=${VARON_BACKUP_DIR:-/var/backups/3xui-varon}

backup_existing_installation() {
    local timestamp archive temp_list
    local -a candidates=(/etc/x-ui /etc/nginx /etc/letsencrypt "$VARON_STATE_DIR")

    require_root
    install -d -m 0700 "$VARON_BACKUP_DIR"
    temp_list=$(mktemp)
    for candidate in "${candidates[@]}"; do
        [[ -e "$candidate" ]] && printf '%s\n' "$candidate" >>"$temp_list"
    done

    if [[ ! -s "$temp_list" ]]; then
        rm -f -- "$temp_list"
        info "No existing 3X-UI, Nginx or certificate files to back up"
        return 0
    fi

    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    archive="$VARON_BACKUP_DIR/pre-change-$timestamp.tar.gz"
    tar --create --gzip --file "$archive" --absolute-names --acls --xattrs \
        --files-from "$temp_list"
    rm -f -- "$temp_list"
    chmod 0600 "$archive"
    ok "Backup created: $archive"
}
