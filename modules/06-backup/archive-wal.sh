#!/usr/bin/env bash
# =============================================================================
# modules/06-backup/archive-wal.sh - archive_command helper (BACKUP_TOOL=basebackup)
#
#   Not run by hand. enable-wal-archiving.sh writes it into conf.d/06-archiving.conf as:
#     archive_command = '.../archive-wal.sh <ARCHIVE_TOP> %p %f'
#   The archive directory is baked into the command (not read from site.env) so archiving
#   never depends on conf/site.env still being there or unchanged.
#
# PostgreSQL retries archive_command until it returns 0, and expects the WAL file to be
# fully and safely on disk before that. So:
#   - never overwrite a different file already at the destination (the classic WAL-archiving
#     mistake: a changed primary after a failover re-archiving a segment number that was
#     already used, silently corrupting the archive);
#   - write under a temp name first and fsync it, then rename into place, so a crash or a
#     full disk never leaves a short, truncated file sitting under the real name.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

ARCHIVE_DIR="${1:?Usage: $0 <archive_dir> %p %f}"
SRC_PATH="${2:?Usage: $0 <archive_dir> %p %f}"
WAL_NAME="${3:?Usage: $0 <archive_dir> %p %f}"

[ -d "$ARCHIVE_DIR" ] || { log_error "Archive directory ${ARCHIVE_DIR} does not exist"; exit 1; }
[ -w "$ARCHIVE_DIR" ] || { log_error "Archive directory ${ARCHIVE_DIR} is not writable by $(whoami)"; exit 1; }
[ -r "$SRC_PATH" ]    || { log_error "Cannot read ${SRC_PATH}"; exit 1; }

DEST="${ARCHIVE_DIR}/${WAL_NAME}"

if [ -e "$DEST" ]; then
    if cmp -s "$SRC_PATH" "$DEST"; then
        log_info "${WAL_NAME} already archived (identical) - treating as success"
        exit 0
    fi
    log_error "${WAL_NAME} already exists in ${ARCHIVE_DIR} and differs from ${SRC_PATH} - refusing to overwrite (check for a split-brain or an old archive copy)"
    exit 1
fi

TMP="${DEST}.tmp.$$"
trap 'rm -f "$TMP"' EXIT

cp "$SRC_PATH" "$TMP"
sync "$TMP" 2>/dev/null || true     # fsync the data; portable-enough fallback if 'sync FILE' is unsupported
mv -f "$TMP" "$DEST"
trap - EXIT

log_debug "Archived ${WAL_NAME} -> ${DEST}"
