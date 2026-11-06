#!/usr/bin/env bash
# test-fdroid-index-stage.sh [<stage-vendor.sh>] [--mutate] -- the Endospore stage refuses an F-Droid index set that
# does not match the fdroid-index.lock written beside it, or whose index-pubkey is not the agent's indexPubKey.
#
# WHY THIS IS COMMITTED (NWP-20261029-15). publish-fdroid-index.sh wrote the lock and nothing read it, and the
# stage installed any four files it found while its comment said "present + consistent". A set signed by another
# key, or altered or cut after publish, was baked; every phone then rejected the index on read and full-catalog
# search was empty for that release with nothing at build time saying why.
#
# The stage's F-Droid block is extracted from the real stage-vendor.sh BY ANCHOR, and each lock is written by
# publish-fdroid-index.sh's own step-4 block, so the writer and the reader are held to one format. If an anchor
# moves the suite exits 2.
#
#   bash test-fdroid-index-stage.sh                 # the cases against the real stage-vendor.sh
#   bash test-fdroid-index-stage.sh <stage-vendor>  # ... against another copy (how --mutate and the pre-fix run work)
#   bash test-fdroid-index-stage.sh --mutate        # ... plus broken copies that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SV=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SV="$a" ;; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
REAL_SV="$HERE/stage-vendor.sh"
PUBLISH="$HERE/../../../core/vendor-common/prebuilts/publish-fdroid-index.sh"
SV="${SV:-$REAL_SV}"
[ -f "$SV" ] || { echo "no stage-vendor.sh: $SV" >&2; exit 2; }
[ -f "$PUBLISH" ] || { echo "no publish-fdroid-index.sh: $PUBLISH" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf "  ok    %s\n" "$1"; }
no(){ FAIL=$((FAIL+1)); printf "  FAIL  %s\n" "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2] want [$3]"; }
has(){ case "$2" in *"$3"*) ok "$1" ;; *) no "$1 -- [$3] not in: $2" ;; esac; }

BLK="$W/stage.block"; sed -n '/^FDROID_INDEX_DIR=/,/^fi$/p' "$SV" > "$BLK"
case "$(cat "$BLK")" in *'baking without full-catalog search'*) ;; *) echo "EXTRACTION FAILED -- F-Droid block anchors moved in $SV" >&2; exit 2 ;; esac
WRITER="$W/lock.writer"; sed -n '/^LOCK=/,/^} > "\$LOCK"$/p' "$PUBLISH" > "$WRITER"
case "$(cat "$WRITER")" in *'index-pubkey'*) ;; *) echo "EXTRACTION FAILED -- step-4 lock block moved in $PUBLISH" >&2; exit 2 ;; esac

NAMES="index.json index.json.sig icons.pack icons.pack.sig"
AGENT_PUB="AGENTPUBKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
OTHER_PUB="OTHERPUBKEYBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="

# newrepo -> a scratch REPO whose index.go carries AGENT_PUB
newrepo(){
  local r; r=$(mktemp -d -p "$W")
  mkdir -p "$r/core/agent"
  printf 'package main\n\n// indexPubKey is the index key.\nvar indexPubKey = "%s"\n' "$AGENT_PUB" > "$r/core/agent/index.go"
  printf '%s' "$r"
}
# newset <pub> -> a directory holding the four files and the lock the publish script's own block writes
newset(){
  local d f; d=$(mktemp -d -p "$W")
  for f in $NAMES; do printf 'content of %s\n' "$f" > "$d/$f"; done
  ( set -euo pipefail; OUT="$d"; PUB="$1"; . "$WRITER" ) > /dev/null
  printf '%s' "$d"
}
# runstage <repo> <idxdir> -> sets RC, OUTP (stdout+stderr), DEST
runstage(){
  local repo="$1" idx="$2" s; s=$(mktemp -p "$W")
  DEST=$(mktemp -d -p "$W"); mkdir -p "$DEST/etc"
  { printf 'set -euo pipefail\nREPO=%q; DEST=%q; export FDROID_INDEX_DIR=%q\n' "$repo" "$DEST" "$idx"; cat "$BLK"; } > "$s"
  OUTP=$(bash "$s" 2>&1); RC=$?
}
staged(){ ls -A "$DEST/etc" | tr '\n' ' '; }
refused(){  # <label> -- exit 1, nothing staged
  is "$1: exit 1" "$RC" 1
  is "$1: nothing staged" "$(staged)" ""
}

echo "== (a) a good set =="
R=$(newrepo); S=$(newset "$AGENT_PUB"); runstage "$R" "$S"
is "good set: exit 0" "$RC" 0
for f in $NAMES; do cmp -s "$S/$f" "$DEST/etc/$f" && ok "good set: $f staged byte-identical" || no "good set: $f not staged byte-identical"; done

echo "== (b) no lock =="
S=$(newset "$AGENT_PUB"); rm -f "$S/fdroid-index.lock"; runstage "$R" "$S"
refused "no lock"

echo "== (c) each file altered after the lock =="
for f in $NAMES; do
  S=$(newset "$AGENT_PUB"); printf 'tampered\n' >> "$S/$f"; runstage "$R" "$S"
  refused "$f altered"
  has "$f altered: the message names the file" "$OUTP" "$f does not match"
done

echo "== (d) a name missing from the lock, and a name listed twice =="
for f in $NAMES; do
  S=$(newset "$AGENT_PUB"); grep -v "  $f\$" "$S/fdroid-index.lock" > "$S/lock.new"; mv "$S/lock.new" "$S/fdroid-index.lock"
  runstage "$R" "$S"; refused "$f missing from the lock"
done
S=$(newset "$AGENT_PUB"); grep '  icons.pack$' "$S/fdroid-index.lock" > "$S/dup"; cat "$S/dup" >> "$S/fdroid-index.lock"; rm -f "$S/dup"; runstage "$R" "$S"
refused "icons.pack listed twice"

echo "== (e) index-pubkey differs / absent =="
S=$(newset "$OTHER_PUB"); runstage "$R" "$S"
refused "a different index-pubkey"
has "a different index-pubkey: the message names the check" "$OUTP" "index-pubkey"
S=$(newset "$AGENT_PUB"); grep -v '^# index-pubkey: ' "$S/fdroid-index.lock" > "$S/lock.new"; mv "$S/lock.new" "$S/fdroid-index.lock"
runstage "$R" "$S"; refused "no index-pubkey line"

echo "== (f) index.go without the var =="
R2=$(newrepo); printf 'package main\n' > "$R2/core/agent/index.go"; S=$(newset "$AGENT_PUB"); runstage "$R2" "$S"
refused "index.go without indexPubKey"
R3=$(newrepo); rm -f "$R3/core/agent/index.go"; runstage "$R3" "$S"
refused "index.go unreadable"

echo "== (g) none of the four files =="
S=$(mktemp -d -p "$W"); runstage "$R" "$S"
is "no files: exit 0" "$RC" 0
has "no files: the skip line" "$OUTP" "baking without full-catalog search"
is "no files: nothing staged" "$(staged)" ""

echo "== (h) three of the four =="
for f in $NAMES; do
  S=$(newset "$AGENT_PUB"); rm -f "$S/$f"; runstage "$R" "$S"
  is "$f absent: exit 0" "$RC" 0
  has "$f absent: says incomplete" "$OUTP" "incomplete"
  is "$f absent: nothing staged" "$(staged)" ""
done

# --- --mutate: each broken copy of the stage must fail the suite (rc 1 -- not an extraction exit) -----------
if [ "$MUTATE" = yes ]; then
  echo "== mutations =="
  SELF="$HERE/$(basename "$0")"
  # mutate <label> <old> <new>: replace the first <old> in a copy of the real stage-vendor.sh
  mutate(){
    local label="$1" old="$2" new="$3" m rc
    m=$(mktemp -p "$W")
    python3 -I - "$REAL_SV" "$m" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if old not in s:
    sys.exit(3)
open(dst, "w").write(s.replace(old, new, 1))
PY
    rc=$?
    if [ "$rc" -ne 0 ]; then no "mutation '$label' did not apply"; return; fi
    bash "$SELF" "$m" > "$W/mut.out" 2>&1; rc=$?
    case "$rc" in
      1) ok "mutation convicted: $label" ;;
      0) no "mutation SURVIVED: $label" ;;
      *) no "mutation '$label' hit an extraction/setup exit (rc $rc), not a conviction" ;;
    esac
  }
  mutate "L1: the lock requirement is removed" \
    'FDROID_BAD="has no fdroid-index.lock"' 'FDROID_BAD=""'
  mutate "L2: the hash comparison is always true" \
    '      if [ "$(printf '"'%s\\n'"' "$FDROID_ROW" | sed -n 2p)" !=' \
    '      if false && [ "$(printf '"'%s\\n'"' "$FDROID_ROW" | sed -n 2p)" !='
  mutate "L3: the pubkey check is removed" \
    '    if [ -z "$FDROID_BAD" ]; then' '    if false; then'
  mutate "L4: the install moves before the checks" \
    '  FDROID_LOCK="$FDROID_INDEX_DIR/fdroid-index.lock"
' '  for f in $FDROID_NAMES; do install -m644 "$FDROID_INDEX_DIR/$f" "$DEST/etc/$f"; done
  FDROID_LOCK="$FDROID_INDEX_DIR/fdroid-index.lock"
'
  mutate "L5: a missing lock is treated as the skip branch" \
    'if [ "$FDROID_HAVE" -eq 4 ]; then' \
    'if [ "$FDROID_HAVE" -eq 4 ] && [ -f "$FDROID_INDEX_DIR/fdroid-index.lock" ]; then'
fi

echo
echo "test-fdroid-index-stage: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
