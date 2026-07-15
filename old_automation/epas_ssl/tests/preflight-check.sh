#!/bin/bash
# ==============================================================================
# EPAS SSL PREFLIGHT CHECK - CRYPTO ASSET VALIDATION
# ==============================================================================
set -e

SECURITY_TOP=$1
PASSPHRASE_FILE="${SECURITY_TOP}/.passphrase"

log_check() { echo -e "[PREFLIGHT] $1"; }

if [ ! -f "${SECURITY_TOP}/server.key" ] || [ ! -f "${SECURITY_TOP}/server_chained.crt" ]; then
    log_check "[ERROR] Missing key or chained cert asset paths."
    exit 1
fi

# Decryption Strategy based on Passphrase Presence
if [ -f "$PASSPHRASE_FILE" ]; then
    KEY_MD5=$(openssl rsa -noout -modulus -in "${SECURITY_TOP}/server.key" -passin file:"$PASSPHRASE_FILE" | openssl md5)
else
    KEY_MD5=$(openssl rsa -noout -modulus -in "${SECURITY_TOP}/server.key" | openssl md5)
fi

CRT_MD5=$(openssl x509 -noout -modulus -in "${SECURITY_TOP}/server_chained.crt" | openssl md5)

if [ "$KEY_MD5" != "$CRT_MD5" ]; then
    log_check "[FAIL] Modulus mismatch detected! Key and Certificate do not align."
    exit 1
fi

log_check "[SUCCESS] Private key and Chained Certificate match perfectly."