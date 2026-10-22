#!/usr/bin/env bash
# thales-kmip.sh — shared helpers for the 08-tde scripts (sourced, not run).
# Needs lib/common.sh loaded and the tde.env settings (THALES_*, DSM_DIR, SYSTEM_USER, SYSTEM_GROUP).

KMIP_CLIENT="${KMIP_CLIENT:-/usr/edb/kmip/client/edb_tde_kmip_client.py}"

# Default config for this module is conf/tde.env (it sources conf/site.env itself)
tde_default_env() {
    [ -n "$ENV_FILE" ] || [ ! -f "${TOOLKIT_ROOT}/conf/tde.env" ] || ENV_FILE="${TOOLKIT_ROOT}/conf/tde.env"
}

thales_check_settings() {
    THALES_PORT="${THALES_PORT:-5696}"
    DSM_DIR="${DSM_DIR:-/var/lib/edb/dsm}"
    require_vars THALES_HOST THALES_KEY_UUID THALES_USER THALES_PASS THALES_KEYFILE THALES_CERTFILE THALES_CAFILE SYSTEM_USER SYSTEM_GROUP DATA_TOP
    [[ "$THALES_PASS" != "<"* ]] || die "THALES_PASS is still the placeholder - export THALES_PASS=... (secrets manager) before running."
    [[ "$THALES_KEY_UUID" != *xxxxxxxx* ]] || die "THALES_KEY_UUID is still the placeholder in ${ENV_SOURCE}."
    local f; for f in "$THALES_KEYFILE" "$THALES_CERTFILE" "$THALES_CAFILE"; do [ -f "$f" ] || die "Certificate file not found: $f"; done
    THALES_WRAP_CMD="python3 ${KMIP_CLIENT} encrypt --out-file=%p --pykmip-config-file=${DSM_DIR}/pykmip.conf --key-uid=${THALES_KEY_UUID} --variant=thales"
    THALES_UNWRAP_CMD="python3 ${KMIP_CLIENT} decrypt --in-file=%p --pykmip-config-file=${DSM_DIR}/pykmip.conf --key-uid=${THALES_KEY_UUID} --variant=thales"
}

thales_install() {
    local pkg
    for pkg in python3-pykmip edb-tde-kmip-client; do
        rpm -q "$pkg" >/dev/null 2>&1 || { log_info "Installing ${pkg}..."; dnf install -y "$pkg" || die "dnf install ${pkg} failed."; }
    done
    [ -f "$KMIP_CLIENT" ] || die "${KMIP_CLIENT} not found after package install."
}

# Certificates + pykmip.conf in DSM_DIR (700, owned by SYSTEM_USER; key and conf 600)
thales_stage() {
    log_info "Staging client certificates and pykmip.conf in ${DSM_DIR}"
    install -d -m 0700 -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" "$DSM_DIR"
    install -m 0600 -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" "$THALES_KEYFILE"  "${DSM_DIR}/key.pem"
    install -m 0644 -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" "$THALES_CERTFILE" "${DSM_DIR}/cert.pem"
    install -m 0644 -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" "$THALES_CAFILE"   "${DSM_DIR}/ca.pem"
    [ ! -f "${DSM_DIR}/pykmip.conf" ] || cp -a "${DSM_DIR}/pykmip.conf" "${DSM_DIR}/pykmip.conf.bak.$(date +%Y%m%d%H%M%S)"
    ( umask 077
      cat > "${DSM_DIR}/pykmip.conf" <<PYKMIP
[client]
host=${THALES_HOST}
port=${THALES_PORT}
username=${THALES_USER}
password=${THALES_PASS}
keyfile=${DSM_DIR}/key.pem
certfile=${DSM_DIR}/cert.pem
ca_certs=${DSM_DIR}/ca.pem
PYKMIP
    )
    chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "${DSM_DIR}/pykmip.conf"
    chmod 0600 "${DSM_DIR}/pykmip.conf"
}

# tde_run CMD-WITH-%p FILE — run a wrap/unwrap command as SYSTEM_USER with %p replaced by FILE (stdin/stdout passed through)
# runuser (not sudo) keeps the environment, so a command using e.g. "-pass env:OLD_TDE_PASSPHRASE" works
tde_run() { local c="${1//%p/$2}"; runuser -u "$SYSTEM_USER" -- bash -c "$c"; }

# Encrypt + decrypt a random test value through Thales; stops the run on any mismatch
thales_roundtrip() {
    log_info "Testing KMIP encrypt/decrypt round trip against ${THALES_HOST}:${THALES_PORT}..."
    local tmp plain back
    tmp=$(runuser -u "$SYSTEM_USER" -- mktemp "${DSM_DIR}/roundtrip.XXXXXX")
    plain="edb-tde-roundtrip-$(date +%s)-${RANDOM}"
    printf '%s' "$plain" | tde_run "$THALES_WRAP_CMD" "$tmp" \
        || { rm -f "$tmp"; die "KMIP encrypt test FAILED - check host/port/certificates/user/key UUID."; }
    back=$(tde_run "$THALES_UNWRAP_CMD" "$tmp") || back=""
    rm -f "$tmp"
    [ "$back" = "$plain" ] || die "KMIP decrypt round trip MISMATCH - nothing has been changed."
    log_info "KMIP round trip OK."
}
