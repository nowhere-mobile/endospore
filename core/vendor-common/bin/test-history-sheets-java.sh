#!/usr/bin/env bash
# test-history-sheets-java.sh [--mutate] -- the History screen's two confirmations (Restore a snapshot: restore a
# version, delete a version) on the shared bottom sheet, run under javac (NWP-20261205-14; docs/backlog.md, "Popups are
# plain dialogs: the choice pickers and the confirmations move to one bottom-sheet design", slice 3).
#
# WHY THIS IS COMMITTED. Design A's rules hold only if a test holds them: the restore ask is a warning whose green
# button is the safe way out ("Keep my current data") and whose risky "Restore" is red-outlined; the delete ask is
# destructive, a red filled "Delete this version" first and an outlined "Keep this version" below. The delete words keep
# docs/product-decisions.md 2026-10-19's limits (never the current state, no size promised). HistorySheets, SnapshotCopy
# and PopupSheet are pure java.util and are compiled here with the cases. Source pins (comments stripped) hold what the
# cases cannot:
#   S1 confirmRollback and confirmDeleteSnapshot hold no AlertDialog.Builder;
#   S2 confirmRollback shows HistorySheets.rollback(label), with doRollback(version) on button 1 and nothing on button 0;
#   S3 confirmDeleteSnapshot shows HistorySheets.delete(label), with doDeleteSnapshot(version) on button 0 and nothing
#      on button 1.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-history-sheets-java.sh            # the cases + the pins
#   bash test-history-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
SNAP="$SRC/SnapshotCopy.java"
HIST="$SRC/HistorySheets.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/history-sheets/HistorySheetsCases.java"
RULES="$root/core/chooser/test-popup-rules.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
for f in "$CASES" "$PA" "$RULES"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <PopupSheet.java> <SnapshotCopy.java> <HistorySheets.java> -> 0 pass, 1 a case failed or a class is missing
# (the only codes that convict a mutant), 3 it did not compile.
suite() {
  local popup="$1" snap="$2" hist="$3" d out rc
  [ -f "$popup" ] || { echo "  FAIL  PopupSheet.java does not exist" >&2; return 1; }
  [ -f "$snap" ] || { echo "  FAIL  SnapshotCopy.java does not exist" >&2; return 1; }
  [ -f "$hist" ] || { echo "  FAIL  HistorySheets.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$popup" "$d/src/com/nowhere/chooser/PopupSheet.java"
  cp "$snap" "$d/src/com/nowhere/chooser/SnapshotCopy.java"
  cp "$hist" "$d/src/com/nowhere/chooser/HistorySheets.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/HistorySheetsCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then
    rm -rf "$d"; return 3
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.HistorySheetsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  HistorySheetsCases" >&2
  return 1
}

# code <file> -> the file without comment lines and trailing // comments.
code() { sed -E -e '/^[[:space:]]*(\/\/|\*|\/\*)/d' -e 's/[[:space:]]+\/\/[[:space:]].*$//' "$1"; }
# meth <code file> <name> -> the method's lines, from its 4-space declaration to its 4-space closing brace.
meth() {
  awk -v n="$2" '$0 ~ ("^    [a-zA-Z].* " n "\\(") && !f { f = 1 } f { print } f && /^    }$/ { exit }' "$1"
}
# has <text> <fixed string> -> 0 when the text holds it.
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# pins <ProfileActivity.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local paf bad=0 b m
  paf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"

  for m in confirmRollback confirmDeleteSnapshot; do
    b=$(meth "$paf" "$m")
    [ -n "$b" ] || { echo "  FAIL  S1 $m( not found" >&2; bad=1; continue; }
    has "$b" "AlertDialog.Builder" && { echo "  FAIL  S1 $m holds an AlertDialog.Builder" >&2; bad=1; }
  done

  b=$(meth "$paf" confirmRollback)
  has "$b" "SheetDialog.confirm(this, HistorySheets.rollback(label)" \
    || { echo "  FAIL  S2 confirmRollback does not call SheetDialog.confirm on HistorySheets.rollback(label)" >&2; bad=1; }
  has "$b" "new Runnable[] { null, () -> doRollback(version) }" \
    || { echo "  FAIL  S2 confirmRollback does not put doRollback(version) on button 1 and nothing on button 0" >&2; bad=1; }

  b=$(meth "$paf" confirmDeleteSnapshot)
  has "$b" "SheetDialog.confirm(this, HistorySheets.delete(label)" \
    || { echo "  FAIL  S3 confirmDeleteSnapshot does not call SheetDialog.confirm on HistorySheets.delete(label)" >&2; bad=1; }
  has "$b" "new Runnable[] { () -> doDeleteSnapshot(version), null }" \
    || { echo "  FAIL  S3 confirmDeleteSnapshot does not put doDeleteSnapshot(version) on button 0 and nothing on button 1" >&2; bad=1; }
  rm -f "$paf"
  [ "$bad" -eq 0 ]
}

# check_all <PopupSheet.java> <SnapshotCopy.java> <HistorySheets.java> <ProfileActivity.java> -> 0 when the cases and
# every pin pass, 1 when one fails, 3 when the classes did not compile.
check_all() {
  local rc
  suite "$1" "$2" "$3"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$4" || rc=1
  return "$rc"
}

echo "== HistorySheets, SnapshotCopy, PopupSheet; confirmRollback and confirmDeleteSnapshot"
check_all "$POPUP" "$SNAP" "$HIST" "$PA"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases + pins S1-S3"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
# rules_new <chooser src copy> -> 0 when test-popup-rules.sh, run on that copy, fails on a NEW confirmRollback Cancel.
rules_new() {
  local out rc T=$'\t'
  out=$(TMPDIR="$W" SRC_DIR="$1" bash "$RULES" 2>&1); rc=$?
  [ "$rc" -eq 1 ] || { echo "  rules: exit $rc, wanted 1"; return 1; }
  has "$out" "NEW: ProfileActivity.java${T}confirmRollback${T}R1${T}Cancel (baseline 0, found 1)" \
    || { echo "  rules: no NEW line for confirmRollback's Cancel"; return 1; }
}
mut() { # mut <label> <hist|pa|pa+rules> <the assertion that must convict it> <perl-expr>
  local d c rc orig out
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in hist) orig="$HIST" ;; *) orig="$PA" ;; esac
  if [ "$2" = "pa+rules" ]; then
    cp -r "$SRC" "$d/src"
    c="$d/src/$(basename "$orig")"
  else
    c="$d/$(basename "$orig")"
    cp "$orig" "$c"
  fi
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    hist) out=$(check_all "$POPUP" "$SNAP" "$c" "$PA" 2>&1); rc=$? ;;
    *) out=$(pins "$c" 2>&1); rc=$? ;;
  esac
  if [ "$2" = "pa+rules" ] && [ "$rc" -eq 1 ]; then
    if ! rules_new "$d/src"; then echo "  SURVIVED  $1 -- test-popup-rules.sh did not report it NEW"; rm -rf "$d"; return 1; fi
  fi
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
  case "$out" in
    *"FAIL  $3"*) echo "  convicted $1 -- FAIL  $3"; return 0 ;;
  esac
  echo "  WRONG     $1 -- it failed, but not on '$3':"; printf '%s\n' "$out" | grep -F FAIL | head -3
  return 1
}
fails=0
mut "H1 delete's red button made GREEN_FILLED"  hist     "delete no green"               's/DELETE_BUTTON, PopupSheet\.Style\.RED_FILLED/DELETE_BUTTON, PopupSheet.Style.GREEN_FILLED/' || fails=$((fails+1))
mut "H2 delete's Keep button dropped"           hist     "delete keep second"            's/,\s*new PopupSheet\.Button\(KEEP_VERSION, PopupSheet\.Style\.OUTLINED\)//' || fails=$((fails+1))
mut "H3 Restore made GREEN_FILLED"              hist     "rollback restore red-outlined" 's/RESTORE, PopupSheet\.Style\.RED_OUTLINED/RESTORE, PopupSheet.Style.GREEN_FILLED/' || fails=$((fails+1))
mut "H4 the rollback actions swapped"           pa       "S2 confirmRollback"            's/\{ null, \(\) -> doRollback\(version\) \}/{ () -> doRollback(version), null }/' || fails=$((fails+1))
mut "H5 the delete actions swapped"             pa       "S3 confirmDeleteSnapshot"      's/\{ \(\) -> doDeleteSnapshot\(version\), null \}/{ null, () -> doDeleteSnapshot(version) }/' || fails=$((fails+1))
mut "H6 the label left out of the context"      hist     "rollback context"              's/ROLLBACK_CONTEXT_PREFIX \+ label \+ ROLLBACK_CONTEXT_SUFFIX/ROLLBACK_CONTEXT_PREFIX + ROLLBACK_CONTEXT_SUFFIX/' || fails=$((fails+1))
mut "H7 a Cancel builder put back"              pa+rules "S1 confirmRollback"            's/(private void confirmRollback\([^\n]*\{\n)/$1        new android.app.AlertDialog.Builder(this).setTitle("Restore this version?").setNegativeButton("Cancel", null).show();\n/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 7 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
