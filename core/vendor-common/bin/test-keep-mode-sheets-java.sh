#!/usr/bin/env bash
# test-keep-mode-sheets-java.sh [--mutate] -- the per-app kept-mode picker and its sideload warning on the bottom sheet,
# run under javac (NWP-20261205-10; docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations
# move to one bottom-sheet design", slice 2).
#
# WHY THIS IS COMMITTED. Profile > Your apps opens a picker per app (showKeepModeDialog) and, before the first keep of a
# sideloaded app, a warning (showSideloadWarning). KeepModeSheets builds both as PopupSheet models; it is pure java.util
# and is compiled here with PopupSheet, AppFilter and the cases. Source pins (comments stripped) hold what the cases
# cannot:
#   S1 neither method holds an AlertDialog.Builder;
#   S2 showKeepModeDialog calls SheetDialog.picker on KeepModeSheets.picker and applies modes.get(which)[1];
#   S3 showSideloadWarning calls SheetDialog.confirm on KeepModeSheets.sideload(), action slot 0 null, onConfirm in 1.
# Mutant K7 also runs core/chooser/test-popup-rules.sh on the mutant copy, which must report it NEW.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-keep-mode-sheets-java.sh            # the cases + the pins
#   bash test-keep-mode-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
FILTER="$SRC/AppFilter.java"
SHEET="$SRC/KeepModeSheets.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/keep-mode-sheets/KeepModeSheetsCases.java"
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
for f in "$CASES" "$PA" "$POPUP" "$FILTER" "$RULES"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <KeepModeSheets.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that convict a
# mutant), 3 it did not compile.
suite() {
  local sheet="$1" d out rc
  [ -f "$sheet" ] || { echo "  FAIL  KeepModeSheets.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$POPUP" "$FILTER" "$d/src/com/nowhere/chooser/"
  cp "$sheet" "$d/src/com/nowhere/chooser/KeepModeSheets.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/KeepModeSheetsCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.KeepModeSheetsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  KeepModeSheetsCases" >&2
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
  local paf bad=0 b m k
  paf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"

  for m in showKeepModeDialog showSideloadWarning; do
    b=$(meth "$paf" "$m")
    [ -n "$b" ] || { echo "  FAIL  S1 $m( not found" >&2; bad=1; continue; }
    has "$b" "AlertDialog.Builder" && { echo "  FAIL  S1 $m holds an AlertDialog.Builder" >&2; bad=1; }
  done

  b=$(meth "$paf" showKeepModeDialog)
  for k in "SheetDialog.picker(this, KeepModeSheets.picker(" \
           "applyKeepMode(pkg, modes.get(which)[1], sideloaded, paint, preview, onChange)"; do
    has "$b" "$k" || { echo "  FAIL  S2 showKeepModeDialog does not hold $k" >&2; bad=1; }
  done

  b=$(meth "$paf" showSideloadWarning)
  for k in "SheetDialog.confirm(this, KeepModeSheets.sideload()," \
           "new Runnable[] { null, () -> { if (onConfirm != null) onConfirm.run(); } }"; do
    has "$b" "$k" || { echo "  FAIL  S3 showSideloadWarning does not hold $k" >&2; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

# check_all <KeepModeSheets.java> -> 0 when the cases and every pin pass, 1 when one fails, 3 when it did not compile.
check_all() {
  local rc
  suite "$1"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$PA" || rc=1
  return "$rc"
}

echo "== KeepModeSheets, showKeepModeDialog, showSideloadWarning"
check_all "$SHEET"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases + pins S1-S3"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
# lint <dir holding the mutant ProfileActivity.java> -> the popup-rules scan of that copy, with its exit code last.
lint() {
  local f
  for f in ChooserActivity.java PrivateDnsPromptActivity.java PrivateDnsWatch.java; do cp "$SRC/$f" "$1/"; done
  SRC_DIR="$1" TMPDIR="$W" bash "$RULES" 2>&1
  echo "rc=$?"
}
mut() { # mut <label> <sheet|pa> <the assertion that must convict it> <perl-expr> [lint]
  local d c rc orig out lo want
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in sheet) orig="$SHEET" ;; *) orig="$PA" ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    sheet) out=$(check_all "$c" 2>&1); rc=$? ;;
    *) out=$(pins "$c" 2>&1); rc=$? ;;
  esac
  if [ "${5:-}" = lint ]; then
    lo=$(lint "$d")
    want=$(printf 'NEW: ProfileActivity.java\tshowSideloadWarning\tR1\tCancel (baseline 0, found 1)')
    case "$lo" in
      *"$want"*"rc=1") ;;
      *) echo "  WRONG     $1 -- test-popup-rules.sh did not report it NEW:"; printf '%s\n' "$lo" | tail -3
         rm -rf "$d"; return 1 ;;
    esac
  fi
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
  case "$out" in
    *"FAIL  $3"*) echo "  convicted $1 -- FAIL  $3${5:+ (and test-popup-rules.sh: NEW)}"; return 0 ;;
  esac
  echo "  WRONG     $1 -- it failed, but not on '$3':"; printf '%s\n' "$out" | grep -F FAIL | head -3
  return 1
}
fails=0
mut "K1 the split keeps the dash in the name"     sheet "C1 name of option 0"  's/s\.substring\(0, k\)/s.substring(0, k + SEP.length())/' || fails=$((fails+1))
mut "K2 the description dropped"                  sheet "C1 description of option 0" 's/k < 0 \? "" : s\.substring\(k \+ SEP\.length\(\)\)/""/' || fails=$((fails+1))
mut "K3 current off by one"                       sheet "C2 checked 0: the current one is at 0" 's/i == checked;/i == checked + 1;/' || fails=$((fails+1))
mut "K4 a negative checked marks 0"               sheet "C2 checked -1: none current" 's/checked >= 0 && checked < n && i == checked/i == Math.max(0, checked)/' || fails=$((fails+1))
mut "K5 Keep it made GREEN_FILLED"                sheet "C7 exactly one GREEN_FILLED" 's/Button\(KEEP_IT, PopupSheet\.Style\.RED_OUTLINED\)/Button(KEEP_IT, PopupSheet.Style.GREEN_FILLED)/' || fails=$((fails+1))
mut "K6 onConfirm moved to slot 0"                pa    "S3 showSideloadWarning" 's/new Runnable\[\] \{ null, (\(\) -> \{ if \(onConfirm != null\) onConfirm\.run\(\); \}) \}/new Runnable[] { $1, null }/' || fails=$((fails+1))
mut "K7 a Cancel builder put back in showSideloadWarning" pa "S1 showSideloadWarning holds an AlertDialog.Builder" \
    's/(private void showSideloadWarning\(final Runnable onConfirm\) \{\n)/$1        new android.app.AlertDialog.Builder(this).setTitle("Keep a sideloaded app?").setNegativeButton("Cancel", null).show();\n/' lint || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 7 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
