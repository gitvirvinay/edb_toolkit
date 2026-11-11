#!/usr/bin/env bash
# Syntax-check every shell script; run shellcheck too when it is installed.
#   tests/lint.sh            -> fails only on syntax errors / CRLF line endings
#   STRICT=1 tests/lint.sh   -> also fails on shellcheck warnings
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0
mapfile -t FILES < <(find . -name '*.sh' -not -path './.git/*' | sort)
for f in "${FILES[@]}"; do
  if grep -q $'\r' "$f"; then echo "CRLF   $f"; fail=1; fi
  if ! bash -n "$f" 2>/tmp/lint.$$; then echo "SYNTAX $f"; cat /tmp/lint.$$; fail=1; fi
done
rm -f /tmp/lint.$$
echo "bash -n: ${#FILES[@]} scripts checked"
if command -v shellcheck >/dev/null 2>&1; then
  if ! shellcheck -S warning "${FILES[@]}"; then
    echo "shellcheck reported warnings"; [ "${STRICT:-0}" = "1" ] && fail=1
  fi
else
  echo "shellcheck not installed — skipped"
fi
exit $fail
