#!/usr/bin/env bash
# =============================================================================
# tools/make-paste-kit.sh - package the toolkit as TEXT you can paste into a terminal
#
#   tools/make-paste-kit.sh [--lines N]        (or: make paste-kit)
#
# For servers where nothing can be copied except text (no scp, no download, no zip).
# Builds dist/paste-kit-<version>/ from the COMMITTED state of the repo (git archive),
# the same content as make-bundle.sh, but cut into small plain-text parts:
#
#   part-01.sh ... part-NN.sh   paste each one into a terminal on the server (or save it
#                               with an editor and run: bash part-01.sh). Each part writes
#                               one slice of the archive and checks it with sha256, so a
#                               damaged paste is caught at once and only that part is repeated.
#   finish.sh                   paste last: checks every part, checks the whole archive,
#                               unpacks it into ~/edb_kit/edb_toolkit
#   README.txt                  the same steps in plain words
#
# Part size: --lines N base64 lines per part (default 500 = about 38 KB per part).
# Parts only hold letters, digits, + / = and a few fixed lines: nothing a terminal,
# an editor or a chat window will reformat. Written for bash 3.2 (macOS) and Linux.
# =============================================================================
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LINES=500
while [ $# -gt 0 ]; do
    case "$1" in
        --lines) LINES="${2:-}"; shift 2 ;;
        -h|--help) sed -n 2,24p "$0"; exit 0 ;;
        *) echo "make-paste-kit: unknown option: $1" >&2; exit 1 ;;
    esac
done
case "$LINES" in ''|*[!0-9]*|0) echo "make-paste-kit: --lines needs a positive number" >&2; exit 1 ;; esac

git rev-parse --git-dir >/dev/null 2>&1 || { echo "make-paste-kit: run this inside the Git checkout" >&2; exit 1; }

sha() {   # sha <file> -> hash only
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

VERSION="$(git describe --tags --always)"
DATE="$(git log -1 --format=%cd --date=short)"
if [ -n "$(git status --porcelain)" ]; then
    echo "WARNING: you have uncommitted changes - they are NOT in the kit (it contains commit $(git rev-parse --short HEAD))." >&2
fi

OUTDIR="${DIST_DIR:-dist}/paste-kit-${VERSION}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. the archive: same layout as make-bundle.sh (edb_toolkit/ ... plus a VERSION file)
git archive --format=tar --prefix=edb_toolkit/ HEAD | tar -x -C "$TMP"
printf '%s (%s)\n' "$VERSION" "$DATE" > "$TMP/edb_toolkit/VERSION"
COPYFILE_DISABLE=1 tar -C "$TMP" -cf - edb_toolkit | gzip -9n > "$TMP/kit.tar.gz"
TGZ_SHA="$(sha "$TMP/kit.tar.gz")"

# 2. text form: base64, 76 characters per line, then cut into parts
base64 < "$TMP/kit.tar.gz" | tr -d '\n' | fold -w 76 > "$TMP/kit.b64"
echo >> "$TMP/kit.b64"
B64_SHA="$(sha "$TMP/kit.b64")"
TOTAL_LINES="$(wc -l < "$TMP/kit.b64" | tr -d ' ')"
PARTS=$(( (TOTAL_LINES + LINES - 1) / LINES ))

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"
split -l "$LINES" "$TMP/kit.b64" "$TMP/chunk."

# shell snippet shared by every part: where to put things, which sha256 tool
HEADER_SHA='S=$(command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo "shasum -a 256")'

n=0
for chunk in "$TMP"/chunk.*; do
    n=$((n + 1))
    id="$(printf '%02d' "$n")"
    out="$OUTDIR/part-${id}.sh"
    {
        echo "# edb_toolkit paste kit ${VERSION} - part ${n} of ${PARTS}. Paste this whole file into the terminal."
        echo 'D="${EDB_KIT_DIR:-$HOME/edb_kit}"; mkdir -p "$D"'
        echo "$HEADER_SHA"
        echo "cat > \"\$D/part-${id}.b64\" <<'EDB_KIT_END'"
        cat "$chunk"
        echo "EDB_KIT_END"
        echo "(cd \"\$D\" && echo \"$(sha "$chunk")  part-${id}.b64\" | \$S -c - && echo \"part ${n} of ${PARTS}: OK\") || echo \"part ${n} of ${PARTS}: DAMAGED - paste this part again\""
    } > "$out"
done

# 3. finish.sh: whole-archive check and unpack
{
    echo "# edb_toolkit paste kit ${VERSION} - finish. Paste this after all ${PARTS} parts."
    echo 'D="${EDB_KIT_DIR:-$HOME/edb_kit}"'
    echo "$HEADER_SHA"
    echo 'dec() { base64 -d 2>/dev/null || base64 -D; }'
    cat <<EOF
(
  set -e
  cd "\$D"
  i=1; while [ \$i -le ${PARTS} ]; do f=\$(printf 'part-%02d.b64' \$i); [ -s "\$f" ] || { echo "missing \$f - paste that part first"; exit 1; }; i=\$((i+1)); done
  cat part-*.b64 > kit.b64
  echo "${B64_SHA}  kit.b64" | \$S -c - || { echo "parts do not add up to the right kit: an old part from another version may be in \$D"; exit 1; }
  dec < kit.b64 > kit.tar.gz
  echo "${TGZ_SHA}  kit.tar.gz" | \$S -c -
  [ ! -e edb_toolkit ] || { echo "\$D/edb_toolkit already exists - move it away first (mv edb_toolkit edb_toolkit.old)"; exit 1; }
  tar xzf kit.tar.gz
  echo; echo "edb_toolkit \$(cat edb_toolkit/VERSION) is in \$D/edb_toolkit"
  echo "Next: cd \$D/edb_toolkit && sudo tools/install.sh"
) || echo "FINISH FAILED - read the message above"
EOF
} > "$OUTDIR/finish.sh"

# 4. README.txt
cat > "$OUTDIR/README.txt" <<EOF
edb_toolkit ${VERSION} (${DATE}) - paste kit, ${PARTS} parts + finish.sh

On the server, as your own admin account (not enterprisedb), in a bash shell:

  1. Open part-01.sh on your laptop, select all, copy, paste into the terminal, press Enter.
     It ends with "part 1 of ${PARTS}: OK". If it says DAMAGED, paste the same part again.
     (Or: save the text with an editor on the server and run: bash part-01.sh)
  2. Do the same for part-02.sh ... part-$(printf '%02d' "$PARTS").sh, in any order.
  3. Paste finish.sh last. It checks every part and the whole kit, then unpacks to ~/edb_kit/edb_toolkit.
  4. cd ~/edb_kit/edb_toolkit && sudo tools/install.sh

Notes
  - The kit holds only committed files from commit $(git rev-parse --short HEAD); never your conf/site.env.
  - Pasting a part twice is harmless; it overwrites its own file.
  - To start clean after a failed attempt: rm -rf ~/edb_kit
  - Whole-kit checksum (sha256 of the archive): ${TGZ_SHA}
EOF

case "$OUTDIR" in /*) SHOWN="$OUTDIR" ;; *) SHOWN="$ROOT/$OUTDIR" ;; esac
echo "Paste kit: $SHOWN"
echo "Parts:     $PARTS (+ finish.sh, README.txt), up to $LINES lines each"
echo "Version:   $VERSION ($DATE)"
