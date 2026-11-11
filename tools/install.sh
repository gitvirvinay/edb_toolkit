#!/usr/bin/env bash
# =============================================================================
# tools/install.sh - install this copy of edb_toolkit on a server
#
#   sudo tools/install.sh [--yes]          (or: sudo make install)
#
# Works the same whichever way the files arrived:
#   * a Git checkout (git clone / git pull)     -> VERSION from git
#   * an unpacked bundle (tools/make-bundle.sh)  -> VERSION file inside the bundle
#
# Result: /opt/dba/edb_toolkit (PREFIX=... to change), owned by root, readable by
# everyone (dirs 755, files 644, *.sh 755): the database user can run the tools
# but cannot change scripts that root also runs.
#   * Host config is kept: conf/*.env in the installed copy (e.g. conf/site.env)
#     is never overwritten and never copied from the source.
#   * The previous install is kept as /opt/dba/edb_toolkit.prev (one-step rollback).
#   * /opt/dba/edb_toolkit/VERSION says which toolkit version this server runs.
#   * /usr/local/bin/epasenv -> /opt/dba/edb_toolkit/tools/epasenv.sh, so any user can
#     switch their shell with '. epasenv as17' (EPASENV_LINK=... to change, '' to skip).
#   * /opt/dba is the DBA team's folder (root-owned, 755); other DBA tools go beside edb_toolkit.
#   * Old location /opt/edb_toolkit (before 2026-11): its conf/*.env is carried over, the old copy is
#     kept as /opt/edb_toolkit.moved_<timestamp>, and /opt/edb_toolkit becomes a link to the new
#     place, so existing scripts, cron jobs and habits keep working.
# =============================================================================
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${SRC}/lib/common.sh"
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) die "Unknown argument: $1 (see --help)" ;;
esac

PREFIX="${PREFIX:-/opt/dba/edb_toolkit}"
require_root

# Guard rails: PREFIX is replaced as a whole, so it must clearly be a toolkit directory.
[[ $PREFIX == /* && $PREFIX =~ ^[A-Za-z0-9._/-]+$ && $PREFIX != *..* ]] \
    || die "PREFIX must be an absolute path (letters, digits, . _ - /): $PREFIX"
PREFIX="${PREFIX%/}"
[[ $(basename "$PREFIX") == edb_toolkit* ]] \
    || die "PREFIX must end in a directory named edb_toolkit* (got $PREFIX) - it is replaced on every install"
[[ "$(readlink -m "$SRC")" != "$(readlink -m "$PREFIX")" ]] \
    || die "This is already the installed copy ($PREFIX). Run install.sh from a Git checkout or an unpacked bundle."

# Version: bundle file first, then git, else unknown
if [[ -f $SRC/VERSION ]]; then
    VERSION=$(head -n1 "$SRC/VERSION")
elif command -v git >/dev/null 2>&1 && git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
    VERSION="$(git -C "$SRC" describe --tags --always --dirty 2>/dev/null) ($(git -C "$SRC" log -1 --format=%cd --date=short 2>/dev/null))"
else
    VERSION="unknown"
fi

CURRENT="none"
[[ -f $PREFIX/VERSION ]] && CURRENT=$(head -n1 "$PREFIX/VERSION")
show_config SRC PREFIX VERSION CURRENT
confirm_or_exit "install edb_toolkit ${VERSION} into ${PREFIX} (current: ${CURRENT}; it is kept as ${PREFIX}.prev)"

NEW="${PREFIX}.new.$$"
trap 'rm -rf "$NEW"' EXIT
mkdir -p "$NEW"

# Copy everything except Git metadata, build output, editor/OS junk and host config (*.env)
tar -C "$SRC" \
    --exclude=./.git --exclude=./dist --exclude='*.swp' --exclude='.DS_Store' --exclude='._*' \
    --exclude='./conf/*.env' \
    -cf - . | tar -C "$NEW" -xf -

# Old location (before the move to /opt/dba): a real directory there is an earlier install.
OLD_PREFIX="/opt/edb_toolkit"
MIGRATE_OLD=0
if [[ $PREFIX == /opt/dba/edb_toolkit && -d $OLD_PREFIX && ! -L $OLD_PREFIX ]]; then
    MIGRATE_OLD=1
    log_info "Found an earlier install in ${OLD_PREFIX} - its host config is carried over"
fi

# Keep this host's config: from the current install, else from the old location
CONF_FROM=""
if [[ -d $PREFIX/conf ]]; then CONF_FROM="$PREFIX/conf"
elif (( MIGRATE_OLD )) && [[ -d $OLD_PREFIX/conf ]]; then CONF_FROM="$OLD_PREFIX/conf"
fi
if [[ -n $CONF_FROM ]]; then
    for f in "$CONF_FROM"/*.env; do
        [[ -f $f ]] || continue
        cp -p "$f" "$NEW/conf/"
        log_info "Kept host config: conf/$(basename "$f") (from ${CONF_FROM})"
    done
fi

{
    echo "$VERSION"
    echo "installed $(date '+%F %T %Z') by ${SUDO_USER:-$(id -un)} from ${SRC}"
} > "$NEW/VERSION"

# Ownership and permissions: root-owned, world-readable, scripts executable; host config untouched
chown -R root:root "$NEW"
find "$NEW" -type d -exec chmod 755 {} +
find "$NEW" -type f ! -path "$NEW/conf/*.env" -exec chmod 644 {} +
find "$NEW" -type f -name '*.sh' -exec chmod 755 {} +

# Swap in: current -> .prev, new -> current
mkdir -p "$(dirname "$PREFIX")"
if [[ $(dirname "$PREFIX") == /opt/dba ]]; then
    chown root:root /opt/dba
    chmod 755 /opt/dba
fi
if [[ -d $PREFIX ]]; then
    rm -rf "${PREFIX}.prev"
    mv "$PREFIX" "${PREFIX}.prev"
fi
mv "$NEW" "$PREFIX"
trap - EXIT

# Old location -> compatibility link (the old copy is kept, never deleted)
if (( MIGRATE_OLD )); then
    MOVED="${OLD_PREFIX}.moved_$(date +%F_%H%M%S)"
    mv "$OLD_PREFIX" "$MOVED"
    ln -s "$PREFIX" "$OLD_PREFIX"
    log_info "Old install moved to ${MOVED}; ${OLD_PREFIX} now links to ${PREFIX}. Remove ${MOVED} once all is well."
fi

# '. epasenv' on every user's PATH (a root-owned link to the root-owned script)
EPASENV_LINK="${EPASENV_LINK-/usr/local/bin/epasenv}"
if [[ -n $EPASENV_LINK ]]; then
    if [[ -e $EPASENV_LINK && ! -L $EPASENV_LINK ]]; then
        log_warn "Not touching ${EPASENV_LINK}: it exists and is not a link (move it away, then re-run)"
    elif [[ -d $(dirname "$EPASENV_LINK") ]]; then
        ln -sfn "${PREFIX}/tools/epasenv.sh" "$EPASENV_LINK"
        log_info "Linked ${EPASENV_LINK} -> ${PREFIX}/tools/epasenv.sh  (use: . epasenv <cluster>)"
    else
        log_warn "$(dirname "$EPASENV_LINK") does not exist - no epasenv link created"
    fi
fi

log_audit "edb_toolkit ${VERSION} installed in ${PREFIX} (previous: ${CURRENT})"
log_info "Done. Roll back with: sudo mv ${PREFIX} ${PREFIX}.bad && sudo mv ${PREFIX}.prev ${PREFIX}"
