#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# generate-selfsigned.sh
# Generates an encrypted, self-signed PEM bundle for EDB AS 17.
# Usage: ./generate-selfsigned.sh [output_path] [domain] [days]
# -----------------------------------------------------------------------------

OUTPUT_BUNDLE="${1:-/tmp/server_bundle.pem}"
DOMAIN="${2:-$(hostname -f)}"
DAYS="${3:-365}"
WORKDIR=$(mktemp -d)

trap 'rm -rf "$WORKDIR"' EXIT

echo "[INFO] Generating self-signed SSL bundle for: $DOMAIN (valid ${DAYS} days)"

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
    [[ -n "$KEY_PASS" ]] || { echo "Passphrase cannot be empty."; continue; }
    read -s -r -p "Confirm passphrase: " KEY_PASS2
    echo
    [[ "$KEY_PASS" == "$KEY_PASS2" ]] && break || echo "Passphrases do not match."
done

openssl genrsa -aes256 -passout pass:"$KEY_PASS" -out "$WORKDIR/server.key" 2048

# --- 3. Create CSR with SAN extension -----------------------------------------
cat > "$WORKDIR/server.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${DOMAIN}, IP:${DOMAIN}
EOF

openssl req -new \
  -key "$WORKDIR/server.key" -passin pass:"$KEY_PASS" \
  -out "$WORKDIR/server.csr" \
  -subj "/C=US/O=Enterprise/CN=${DOMAIN}"

# --- 4. Sign Server Certificate with Root CA ----------------------------------
openssl x509 -req -in "$WORKDIR/server.csr" \
  -CA "$WORKDIR/rootCA.crt" -CAkey "$WORKDIR/rootCA.key" -CAcreateserial \
  -out "$WORKDIR/server.crt" \
  -days "$DAYS" -sha256 \
  -extfile "$WORKDIR/server.ext"

# --- 5. Pack into unified PEM Bundle (Key + Cert + CA) ------------------------
# Order: encrypted key, server cert, root CA
cat "$WORKDIR/server.key" "$WORKDIR/server.crt" "$WORKDIR/rootCA.crt" > "$OUTPUT_BUNDLE"
chmod 0600 "$OUTPUT_BUNDLE"

echo "[SUCCESS] Encrypted self-signed bundle created: $OUTPUT_BUNDLE"
echo "[NOTE]    Run: ./epas-ssl-setup.sh --env epas.env --bundle $OUTPUT_BUNDLE"