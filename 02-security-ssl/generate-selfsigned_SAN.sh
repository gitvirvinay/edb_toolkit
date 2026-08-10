#!/usr/bin/env bash
set -euo pipefail

OUTPUT_BUNDLE="${1:-/tmp/server_bundle.pem}"
DAYS="${2:-365}"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# --- Define BOTH servers here ---
PRIMARY_HOST="server1.example.com"
PRIMARY_IP="192.168.1.11"
STANDBY_HOST="server2.example.com"
STANDBY_IP="192.168.1.12"

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

openssl genrsa -aes256 -passout pass:"$KEY_PASS" -out "$WORKDIR/server.key" 2048

# 3. CSR with MULTI-HOST SAN
cat > "$WORKDIR/server.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${PRIMARY_HOST}, DNS:${STANDBY_HOST}, IP:${PRIMARY_IP}, IP:${STANDBY_IP}
EOF

openssl req -new \
  -key "$WORKDIR/server.key" -passin pass:"$KEY_PASS" \
  -out "$WORKDIR/server.csr" \
  -subj "/C=US/O=Enterprise/CN=${PRIMARY_HOST}"

# 4. Sign
openssl x509 -req -in "$WORKDIR/server.csr" \
  -CA "$WORKDIR/rootCA.crt" -CAkey "$WORKDIR/rootCA.key" -CAcreateserial \
  -out "$WORKDIR/server.crt" \
  -days "$DAYS" -sha256 \
  -extfile "$WORKDIR/server.ext"

# 5. Bundle
cat "$WORKDIR/server.key" "$WORKDIR/server.crt" "$WORKDIR/rootCA.crt" > "$OUTPUT_BUNDLE"
chmod 0600 "$OUTPUT_BUNDLE"

echo "[SUCCESS] Bundle: $OUTPUT_BUNDLE"
echo "          SANs: ${PRIMARY_HOST}, ${STANDBY_HOST}, ${PRIMARY_IP}, ${STANDBY_IP}"
echo "[NOTE]    Copy this ONE bundle to both server1 and server2, then run epas-ssl-setup.sh on each."