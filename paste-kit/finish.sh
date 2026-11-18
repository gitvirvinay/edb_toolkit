# edb_toolkit paste kit v3.3.0-1-g91048dd - finish. Paste this after all 8 parts.
D="${EDB_KIT_DIR:-$HOME/edb_kit}"
S=$(command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo "shasum -a 256")
dec() { base64 -d 2>/dev/null || base64 -D; }
(
  set -e
  cd "$D"
  i=1; while [ $i -le 8 ]; do f=$(printf 'part-%02d.b64' $i); [ -s "$f" ] || { echo "missing $f - paste that part first"; exit 1; }; i=$((i+1)); done
  cat part-*.b64 > kit.b64
  echo "d2aa5c65dd7f623afa9808ec1baea7a7b89969d040698738263fc2ed7fb971f2  kit.b64" | $S -c - || { echo "parts do not add up to the right kit: an old part from another version may be in $D"; exit 1; }
  dec < kit.b64 > kit.tar.gz
  echo "783e53fdaa80a81dff336dad3fd346ed7ef84283cb3d9406ca412f7340a30de1  kit.tar.gz" | $S -c -
  [ ! -e edb_toolkit ] || { echo "$D/edb_toolkit already exists - move it away first (mv edb_toolkit edb_toolkit.old)"; exit 1; }
  tar xzf kit.tar.gz
  echo; echo "edb_toolkit $(cat edb_toolkit/VERSION) is in $D/edb_toolkit"
  echo "Next: cd $D/edb_toolkit && sudo tools/install.sh"
) || echo "FINISH FAILED - read the message above"
