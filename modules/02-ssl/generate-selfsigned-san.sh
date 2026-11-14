#!/usr/bin/env bash
set -euo pipefail
umask 077     # temp files, key and bundle readable by the owner only

# generate-selfsigned-san.sh — one self-signed bundle valid for BOTH primary and standby (test/lab use).
# Usage: $0 [--env conf/site.env] [output_bundle] [days]
#   IPs come from PRIMARY_HOST / STANDBY_HOST in the config; DNS names from PRIMARY_FQDN /
#   STANDBY_FQDN (config or environment) - if those are empty, only IP SANs are added - plus every name in
#   SSL_SHARED_NAMES (VIP / DNS alias). Lab use: production gets one certificate per server.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) sed -n '2,5p' "$0"; exit 0 ;; esac
load_env optional

OUTPUT_BUNDLE="${1:-/tmp/server_bundle.pem}"
DAYS="${2:-365}"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PRIMARY_IP="${PRIMARY_HOST:?PRIMARY_HOST is not set in the config}"
STANDBY_IP="${STANDBY_HOST:?STANDBY_HOST is not set in the config}"
PRIMARY_DNS="${PRIMARY_FQDN:-}"
STANDBY_DNS="${STANDBY_FQDN:-}"
SAN="IP:${PRIMARY_IP}, IP:${STANDBY_IP}"
# shared names (VIP / DNS alias, SSL_SHARED_NAMES) - epas-ssl-setup.sh requires them in every certificate
for n in ${SSL_SHARED_NAMES:-}; do
    if [[ $n =~ ^[0-9.]+$ || $n == *:*:* ]]; then SAN="${SAN}, IP:${n}"; else SAN="${SAN}, DNS:${n}"; fi
done
[[ -n "$STANDBY_DNS" ]] && SAN="DNS:${STANDBY_DNS}, ${SAN}"
[[ -n "$PRIMARY_DNS" ]] && SAN="DNS:${PRIMARY_DNS}, ${SAN}"
CN="${PRIMARY_DNS:-$PRIMARY_IP}"
show_config PRIMARY_IP STANDBY_IP PRIMARY_DNS STANDBY_DNS SSL_SHARED_NAMES OUTPUT_BUNDLE DAYS

echo "[INFO] Generating dual-host self-signed bundle..."

# 1. Root CA
openssl req -x509 -new -nodes -newkey rsa:4096 -days "$DAYS" \
  -keyout "$WORKDIR/rootCA.key" \
  -out "$WORKDIR/rootCA.crt" \
  -subj "/C=US/O=Enterprise/CN=EPAS-Local-Root-CA"

# 2. Encrypted server key
while true; do
    read -s -r -p "Set passphrase for server private key: " KEY_PASS; echo
    [[ -n "$KEY_PASS" ]] || continue
    read -s -r -p "Confirm passphrase: " KEY_PASS2; echo
    [[ "$KEY_PASS" == "$KEY_PASS2" ]] && break || echo "Mismatch."
done

# Passphrase via a 0600 file in the private WORKDIR - never on a command line (visible in ps)
printf '%s' "$KEY_PASS" > "$WORKDIR/pass"
KEY_PASS=""
openssl genrsa -aes256 -passout file:"$WORKDIR/pass" -out "$WORKDIR/server.key" 2048

# 3. CSR with MULTI-HOST SAN
cat > "$WORKDIR/server.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = ${SAN}
EOF

openssl req -new \
  -key "$WORKDIR/server.key" -passin file:"$WORKDIR/pass" \
  -out "$WORKDIR/server.csr" \
  -subj "/C=US/O=Enterprise/CN=${CN}"

# 4. Sign
openssl x509 -req -in "$WORKDIR/server.csr" \
  -CA "$WORKDIR/rootCA.crt" -CAkey "$WORKDIR/rootCA.key" -CAcreateserial \
  -out "$WORKDIR/server.crt" \
  -days "$DAYS" -sha256 \
  -extfile "$WORKDIR/server.ext"

# 5. Bundle
cat "$WORKDIR/server.crt" "$WORKDIR/rootCA.crt" "$WORKDIR/server.key" > "$OUTPUT_BUNDLE"
chmod 0600 "$OUTPUT_BUNDLE"

echo "[SUCCESS] Bundle: $OUTPUT_BUNDLE"
echo "          SANs: ${SAN}"
echo "[NOTE]    Copy this ONE bundle to both ${PRIMARY_DNS:-$PRIMARY_IP} and ${STANDBY_DNS:-$STANDBY_IP}, then run epas-ssl-setup.sh on each, as the database OS user (lab use - production gets one certificate per server from your CA)."