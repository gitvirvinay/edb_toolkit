#!/usr/bin/env bash
# =============================================================================
# tests/paste-kit-unit.sh - unit tests for tools/make-paste-kit.sh
# Builds a kit from the committed repo, "pastes" every part into a scratch folder the way a
# person would (running each part file in a fresh bash), and checks the result.
# No database, no root, no network. Run: tests/paste-kit-unit.sh or make test.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: [%s]\n        got:      [%s]\n' "$1" "$2" "$3"; }
eq()   { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has()  { if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1" "...$2..." "$3"; fi; }
hasnt(){ if [[ $3 != *"$2"* ]]; then ok "$1"; else bad "$1" "no $2" "$3"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# the kit holds the COMMITTED state: compare against git archive of HEAD
mkdir -p "$T/expect"
git archive --prefix=edb_toolkit/ HEAD | tar -x -C "$T/expect"

# small parts (60 lines) so the test also covers many parts
out="$(DIST_DIR="$T/dist" bash tools/make-paste-kit.sh --lines 60 2>/dev/null)"
has "generator reports the parts" "Parts:" "$out"
KIT="$(echo "$out" | sed -n 's/^Paste kit: //p')"
[[ -d $KIT ]] && ok "kit folder created" || bad "kit folder created" "dir" "$KIT"
NPART="$(ls "$KIT"/part-*.sh | wc -l | tr -d ' ')"
[[ $NPART -ge 10 ]] && ok "many parts at 60 lines ($NPART)" || bad "many parts at 60 lines" ">=10" "$NPART"
[[ -f $KIT/finish.sh && -f $KIT/README.txt ]] && ok "finish.sh and README.txt exist" || bad "finish.sh and README.txt exist" "both" "missing"

# nothing in a part may need care when pasted: no tabs, no CR, no non-ASCII, short lines
cat "$KIT"/part-*.sh "$KIT"/finish.sh > "$T/all.txt"
eq "no carriage returns" "0" "$(grep -c $'\r' "$T/all.txt")"
eq "no tab characters" "0" "$(grep -c $'\t' "$T/all.txt")"
eq "plain ASCII only" "0" "$(LC_ALL=C grep -c '[^ -~]' "$T/all.txt")"
longest="$(awk '{ if (length($0) > m) m = length($0) } END { print m }' "$T/all.txt")"
[[ $longest -le 400 ]] && ok "no very long lines (longest $longest)" || bad "no very long lines" "<=400" "$longest"

paste_parts() {   # paste_parts <kit-dir> <work-dir>: run every part, in the order given by ls
    local p
    for p in "$1"/part-*.sh; do EDB_KIT_DIR="$2" bash "$p" >/dev/null 2>&1; done
}

# 1. the normal road
W="$T/w1"
paste_parts "$KIT" "$W"
fin="$(EDB_KIT_DIR="$W" bash "$KIT/finish.sh" 2>&1)"
has "finish reports the version" "is in $W/edb_toolkit" "$fin"
has "finish says what to do next" "sudo tools/install.sh" "$fin"
hasnt "finish has no failure" "FAILED" "$fin"
diff -r "$T/expect/edb_toolkit" "$W/edb_toolkit" -x VERSION >"$T/diff.txt" 2>&1
eq "unpacked tree equals the committed tree" "0" "$?"
[[ -s $W/edb_toolkit/VERSION ]] && ok "VERSION file written" || bad "VERSION file written" "non-empty" "empty"
[[ -x $W/edb_toolkit/tools/install.sh ]] && ok "executable bit kept" || bad "executable bit kept" "executable" "not"
[[ ! -e $W/edb_toolkit/conf/site.env ]] && ok "no site.env in the kit" || bad "no site.env in the kit" "absent" "present"

# 2. each part checks itself: a damaged paste says so
W="$T/w2"; cp "$KIT/part-02.sh" "$T/bad-part.sh"
awk 'NR==6 { sub(/./, "#") } { print }' "$KIT/part-02.sh" > "$T/bad-part.sh"
msg="$(EDB_KIT_DIR="$W" bash "$T/bad-part.sh" 2>&1)"
has "damaged part says DAMAGED" "DAMAGED" "$msg"
msg="$(EDB_KIT_DIR="$W" bash "$KIT/part-02.sh" 2>&1)"
has "good part says OK" "part 2 of $NPART: OK" "$msg"

# 3. a CRLF paste (some Windows tools) is caught too
sed 's/$/\r/' "$KIT/part-03.sh" > "$T/crlf-part.sh"
msg="$(EDB_KIT_DIR="$T/w3" bash "$T/crlf-part.sh" 2>&1)"
has "CRLF paste is caught" "DAMAGED" "$msg"

# 4. finish refuses when a part is missing
W="$T/w4"
for p in "$KIT"/part-*.sh; do [[ $p == */part-05.sh ]] && continue; EDB_KIT_DIR="$W" bash "$p" >/dev/null 2>&1; done
fin="$(EDB_KIT_DIR="$W" bash "$KIT/finish.sh" 2>&1)"
has "finish names the missing part" "missing part-05.b64" "$fin"
[[ ! -e $W/edb_toolkit ]] && ok "nothing unpacked when a part is missing" || bad "nothing unpacked when a part is missing" "absent" "present"
EDB_KIT_DIR="$W" bash "$KIT/part-05.sh" >/dev/null 2>&1
fin="$(EDB_KIT_DIR="$W" bash "$KIT/finish.sh" 2>&1)"
[[ -d $W/edb_toolkit ]] && ok "pasting the missing part then finishing works" || bad "pasting the missing part then finishing works" "unpacked" "$fin"

# 5. finish refuses to overwrite an existing unpacked copy
fin="$(EDB_KIT_DIR="$W" bash "$KIT/finish.sh" 2>&1)"
has "finish will not overwrite an existing copy" "already exists" "$fin"

# 6. leftovers from another kit version are caught by the whole-kit check
W="$T/w6"; paste_parts "$KIT" "$W"
printf 'AAAA\n' > "$W/part-99.b64"
fin="$(EDB_KIT_DIR="$W" bash "$KIT/finish.sh" 2>&1)"
has "stray part from another kit is caught" "do not add up" "$fin"

# 7. re-pasting a part is harmless
W="$T/w7"; paste_parts "$KIT" "$W"; paste_parts "$KIT" "$W"
fin="$(EDB_KIT_DIR="$W" bash "$KIT/finish.sh" 2>&1)"
hasnt "pasting everything twice still works" "FAILED" "$fin"

# 8. option checks
msg="$(bash tools/make-paste-kit.sh --lines 0 2>&1)"; rc=$?
eq "--lines 0 is refused" "1" "$rc"
msg="$(bash tools/make-paste-kit.sh --nope 2>&1)"; rc=$?
eq "unknown option is refused" "1" "$rc"

printf '\npaste-kit-unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
