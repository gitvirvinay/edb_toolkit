#!/usr/bin/env bash
# =============================================================================
# tools/make-bundle.sh - package the toolkit for servers that cannot reach Git
#
#   tools/make-bundle.sh          (or: make bundle)
#
# Creates dist/edb_toolkit-<version>.tar.gz plus a .sha256 checksum file, from the
# COMMITTED state of the repo (git archive): uncommitted edits and local files such
# as conf/site.env are never included. The version is baked into a VERSION file.
#
# On the server:
#   sha256sum -c edb_toolkit-<version>.tar.gz.sha256      # file arrived intact?
#   tar xzf edb_toolkit-<version>.tar.gz
#   sudo edb_toolkit/tools/install.sh
#
# Runs on the DBA laptop too: written for bash 3.2 (macOS) and BSD/GNU tar.
# =============================================================================
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

git rev-parse --git-dir >/dev/null 2>&1 || { echo "make-bundle: run this inside the Git checkout" >&2; exit 1; }

VERSION="$(git describe --tags --always)"            # describes HEAD = what goes in the bundle
DATE="$(git log -1 --format=%cd --date=short)"
if [ -n "$(git status --porcelain)" ]; then
    echo "WARNING: you have uncommitted changes - they are NOT in the bundle (it contains commit $(git rev-parse --short HEAD))." >&2
fi

NAME="edb_toolkit-${VERSION}"
OUT="dist/${NAME}.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git archive --format=tar --prefix=edb_toolkit/ HEAD | tar -x -C "$TMP"
printf '%s (%s)\n' "$VERSION" "$DATE" > "$TMP/edb_toolkit/VERSION"

mkdir -p dist
# COPYFILE_DISABLE: stops macOS tar from adding hidden ._* metadata files
COPYFILE_DISABLE=1 tar -C "$TMP" -czf "$OUT" edb_toolkit

cd dist
if command -v sha256sum >/dev/null 2>&1; then sha256sum "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256"
else shasum -a 256 "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256"; fi

echo "Bundle:   $ROOT/$OUT"
echo "Checksum: $ROOT/dist/${NAME}.tar.gz.sha256"
echo "Version:  $VERSION ($DATE)"
