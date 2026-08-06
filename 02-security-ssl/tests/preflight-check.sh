#!/usr/bin/env bash
set -euo pipefail
SECURITY_TOP=$1
PASSPHRASE_FILE="${SECURITY_TOP}/.passphrase"

if [ ! -f "${SECURITY_TOP}/server.key" ] || [ ! -f "${SECURITY_TOP}/server_chained.crt" ]; then
    echo "[PREFLIGHT ERROR] Cryptographic assets are missing."
    exit 1
fi

if [ -f "$PASSPHRASE_FILE" ]; then
    KEY_MD5=$(openssl rsa -noout -modulus -in "${SECURITY_TOP}/server.key" -passin file:"$PASSPHRASE_FILE" 2>/dev/null | openssl md5)
else
    KEY_MD5=$(openssl rsa -noout -modulus -in "${SECURITY_TOP}/server.key" 2>/dev/null | openssl md5)
fi
CRT_MD5=$(openssl x509 -noout -modulus -in "${SECURITY_TOP}/server_chained.crt" 2>/dev/null | openssl md5)

if [ "$KEY_MD5" != "$CRT_MD5" ]; then
    echo "[PREFLIGHT FAIL] Modulus mismatch! Key and Cert do not align."
    exit 1
fi
echo "[PREFLIGHT SUCCESS] Modulus validation passed safely."
