#!/usr/bin/env bash
set -euo pipefail
umask 077     # temp files, key and bundle readable by the owner only

# -----------------------------------------------------------------------------
# generate-selfsigned-single.sh
# Generates an encrypted, self-signed PEM bundle for EDB AS 17.
# Usage: ./generate-selfsigned-single.sh [--env conf/site.env] [output_path] [domain] [days]
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) sed -n '5,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
load_env optional     # no setting is required; --env only lets conf/site.env share a log directory

OUTPUT_BUNDLE="${1:-/tmp/server_bundle.pem}"
DOMAIN="${2:-$(hostname -f 2>/dev/null || hostname)}"
DAYS="${3:-365}"
WORKDIR=$(mktemp -d)

trap 'rm -rf "$WORKDIR"' EXIT

log_info "Generating self-signed SSL bundle for: $DOMAIN (valid ${DAYS} days)"

# --- 1. Generate Root CA (unencrypted key is fine for a throwaway CA) ----------
openssl req -x509 -new -nodes -newkey rsa:4096 -days "$DAYS" \
  -keyout "$WORKDIR/rootCA.key" \
  -out "$WORKDIR/rootCA.crt" \
  -subj "/C=US/O=Enterprise/CN=EPAS-Local-Root-CA"

# --- 2. Generate encrypted Server Key -----------------------------------------
# Prompt for passphrase (mandatory, non-empty)
while true; do
    read -s -r -p "Set passphrase for server private key: " KEY_PASS
    echo
    [[ -n "$KEY_PASS" ]] || { log_warn "Passphrase cannot be empty."; continue; }
    read -s -r -p "Confirm passphrase: " KEY_PASS2
    echo
    [[ "$KEY_PASS" == "$KEY_PASS2" ]] && break || log_warn "Passphrases do not match."
done

# Passphrase via a 0600 file in the private WORKDIR - never on a command line (visible in ps)
printf '%s' "$KEY_PASS" > "$WORKDIR/pass"
KEY_PASS=""
openssl genrsa -aes256 -passout file:"$WORKDIR/pass" -out "$WORKDIR/server.key" 2048

# --- 3. Create CSR with SAN extension -----------------------------------------
cat > "$WORKDIR/server.ext" <<CSREOF
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${DOMAIN}
CSREOF

openssl req -new \
  -key "$WORKDIR/server.key" -passin file:"$WORKDIR/pass" \
  -out "$WORKDIR/server.csr" \
  -subj "/C=US/O=Enterprise/CN=${DOMAIN}"

# --- 4. Sign Server Certificate with Root CA ----------------------------------
openssl x509 -req -in "$WORKDIR/server.csr" \
  -CA "$WORKDIR/rootCA.crt" -CAkey "$WORKDIR/rootCA.key" -CAcreateserial \
  -out "$WORKDIR/server.crt" \
  -days "$DAYS" -sha256 \
  -extfile "$WORKDIR/server.ext"

# --- 5. Pack into unified PEM Bundle (Key + Cert + CA) ------------------------
# Order: server cert, root CA, encrypted key
cat "$WORKDIR/server.crt" "$WORKDIR/rootCA.crt" "$WORKDIR/server.key" > "$OUTPUT_BUNDLE"
chmod 0600 "$OUTPUT_BUNDLE"

log_info "Encrypted self-signed bundle created: $OUTPUT_BUNDLE"
log_info "Install it as the database OS user (it must be able to read the bundle):"
log_info "  sudo -iu enterprisedb $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/epas-ssl-setup.sh --bundle $OUTPUT_BUNDLE"
