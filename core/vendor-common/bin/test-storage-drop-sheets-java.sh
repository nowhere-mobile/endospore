#!/usr/bin/env bash
# test-storage-drop-sheets-java.sh [--mutate] -- the Storage screen's Stop keeping, Stop carrying and over-plan notice
# on the shared bottom sheet, run under javac (NWP-20261205-15; docs/backlog.md, "Popups are plain dialogs: the choice
# pickers and the confirmations move to one bottom-sheet design", slice 3, the Storage screen).
#
# WHY THIS IS COMMITTED. Stop keeping and Stop carrying LOOK destructive and are not: the green button is the safe way
# out (it keeps the app) and the red-outlined one runs applyStorageDrop as the old positive button did. StorageDropSheets
# is pure java.util and is compiled here with PopupSheet and its cases. Source pins (comments stripped) hold what the
# cases cannot:
#   S1 confirmStopKeeping, confirmStopCarrying and showOverPlanDialog hold no AlertDialog.Builder;
#   S2 the two stop methods call SheetDialog.confirm on their model with applyStorageDrop(pkg, repaint) in action slot 1
#      and null in slot 0;
#   S3 showOverPlanDialog still returns on isFinishing() || isDestroyed() before the sheet, keeps its try/catch, and
#      calls showStorageBreakdown() from slot 0.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-storage-drop-sheets-java.sh            # the cases + the pins
#   bash test-storage-drop-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
SHEETS="$SRC/StorageDropSheets.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/storage-drop-sheets/StorageDropSheetsCases.java"
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
for f in "$CASES" "$PA" "$POPUP"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <StorageDropSheets.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that convict a
# mutant), 3 it did not compile.
suite() {
  local sheets="$1" d out rc
  [ -f "$sheets" ] || { echo "  FAIL  StorageDropSheets.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$POPUP" "$d/src/com/nowhere/chooser/PopupSheet.java"
  cp "$sheets" "$d/src/com/nowhere/chooser/StorageDropSheets.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/StorageDropSheetsCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.StorageDropSheetsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  StorageDropSheetsCases" >&2
  return 1
}

# code <file> -> the file without comment lines and trailing // comments.
code() { sed -E -e '/^[[:space:]]*(\/\/|\*|\/\*)/d' -e 's/[[:space:]]+\/\/[[:space:]].*$//' "$1"; }
# meth <code file> <name> -> the method's lines joined into one, spaces squeezed, from its 4-space declaration to its
# 4-space closing brace; a wrapped call still matches.
meth() {
  awk -v n="$2" '$0 ~ ("^    [a-zA-Z].* " n "\\(") && !f { f = 1 } f { print } f && /^    }$/ { exit }' "$1" \
    | tr '\n' ' ' | tr -s ' '
}
# has <text> <fixed string> -> 0 when the text holds it.
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# pins <ProfileActivity.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local paf bad=0 b m k guard call
  paf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"

  for m in confirmStopKeeping confirmStopCarrying showOverPlanDialog; do
    b=$(meth "$paf" "$m")
    [ -n "$b" ] || { echo "  FAIL  S1 $m( not found" >&2; bad=1; continue; }
    has "$b" "AlertDialog.Builder" && { echo "  FAIL  S1 $m holds an AlertDialog.Builder" >&2; bad=1; }
  done

  for m in Keeping Carrying; do
    b=$(meth "$paf" "confirmStop$m")
    k="SheetDialog.confirm(this, StorageDropSheets.stop$m(String.valueOf(keptLabel(pkg))), new Runnable[] { null, () -> applyStorageDrop(pkg, repaint) }, null);"
    has "$b" "$k" \
      || { echo "  FAIL  S2 confirmStop$m does not call SheetDialog.confirm on stop$m with applyStorageDrop in slot 1" >&2; bad=1; }
  done

  b=$(meth "$paf" showOverPlanDialog)
  guard="if (isFinishing() || isDestroyed()) return;"
  call="SheetDialog.confirm(this, StorageDropSheets.overPlan(dispName(pkg, label)), new Runnable[] { () -> showStorageBreakdown(), null }, null);"
  if ! has "$b" "$guard"; then
    echo "  FAIL  S3 showOverPlanDialog does not return on isFinishing() || isDestroyed()" >&2; bad=1
  elif ! has "$b" "$call"; then
    echo "  FAIL  S3 showOverPlanDialog does not call SheetDialog.confirm on overPlan with showStorageBreakdown in slot 0" >&2; bad=1
  elif ! has "${b%%"$call"*}" "$guard"; then
    echo "  FAIL  S3 showOverPlanDialog shows the sheet before its isFinishing() || isDestroyed() guard" >&2; bad=1
  fi
  has "$b" "catch (Throwable ignore)" || { echo "  FAIL  S3 showOverPlanDialog lost its try/catch" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# check_all <StorageDropSheets.java> <ProfileActivity.java> -> 0 when the cases and every pin pass, 1 when one fails,
# 3 when the classes did not compile.
check_all() {
  local rc
  suite "$1"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$2" || rc=1
  return "$rc"
}

echo "== StorageDropSheets, ProfileActivity's Storage confirmations"
check_all "$SHEETS" "$PA"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases + pins S1-S3"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
# mut <label> <sheets|pa> <the assertion that must convict it> <perl-expr> [rules] -> 0 convicted. With "rules", the
# ProfileActivity mutant must also make test-popup-rules.sh report it as NEW.
mut() {
  local d c rc orig out sd rout rrc
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in sheets) orig="$SHEETS" ;; *) orig="$PA" ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    sheets) out=$(check_all "$c" "$PA" 2>&1); rc=$? ;;
    *) out=$(pins "$c" 2>&1); rc=$? ;;
  esac
  case "$rc" in
    0) echo "  SURVIVED  $1"; rm -rf "$d"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; rm -rf "$d"; return 1 ;;
  esac
  case "$out" in
    *"FAIL  $3"*) ;;
    *) echo "  WRONG     $1 -- it failed, but not on '$3':"; printf '%s\n' "$out" | grep -F FAIL | head -3
       rm -rf "$d"; return 1 ;;
  esac
  echo "  convicted $1 -- FAIL  $3"
  if [ "${5:-}" = rules ]; then
    sd="$d/src"
    mkdir -p "$sd"
    cp "$SRC"/*.java "$sd/"
    cp "$c" "$sd/ProfileActivity.java"
    rout=$(SRC_DIR="$sd" bash "$RULES" 2>&1); rrc=$?
    case "$rout" in
      *"NEW: ProfileActivity.java	confirmStopKeeping	R1	Cancel"*) ;;
      *) echo "  SURVIVED  $1 -- test-popup-rules.sh does not report it as NEW (rc=$rrc)"; rm -rf "$d"; return 1 ;;
    esac
    [ "$rrc" -ne 0 ] || { echo "  SURVIVED  $1 -- test-popup-rules.sh reports NEW but passes"; rm -rf "$d"; return 1; }
    echo "  convicted $1 -- test-popup-rules.sh reports NEW"
  fi
  rm -rf "$d"
  return 0
}
fails=0
mut "M1 stopKeeping's Stop button made GREEN_FILLED" sheets "stopKeeping stop button"  's/new PopupSheet\.Button\(STOP_KEEPING_IT, PopupSheet\.Style\.RED_OUTLINED\)/new PopupSheet.Button(STOP_KEEPING_IT, PopupSheet.Style.GREEN_FILLED)/' || fails=$((fails+1))
mut "M2 the stopCarrying actions swapped"           pa     "S2 confirmStopCarrying"   's/(stopCarrying\(String\.valueOf\(keptLabel\(pkg\)\)\),\s+)new Runnable\[\] \{ null, \(\) -> applyStorageDrop\(pkg, repaint\) \}/${1}new Runnable[] { () -> applyStorageDrop(pkg, repaint), null }/' || fails=$((fails+1))
mut "M3 overPlan's buttons swapped in order"        sheets "overPlan buttons"         's/(new PopupSheet\.Button\(SEE_SPACE, PopupSheet\.Style\.GREEN_FILLED\)),(\s+)(new PopupSheet\.Button\(PopupSheet\.NOT_NOW, PopupSheet\.Style\.OUTLINED\))/$3,$2$1/' || fails=$((fails+1))
mut "M4 a message line dropped"                     sheets "stopKeeping lines"        's/,\s+new PopupSheet\.Line\(STOP_KEEPING_LINE_2, null\)//' || fails=$((fails+1))
mut "M5 the label left out of a title"              sheets "stopCarrying title"       's/STOP_CARRYING_TITLE \+ label \+ QUESTION/STOP_CARRYING_TITLE + QUESTION/' || fails=$((fails+1))
mut "M6 the isFinishing guard removed"              pa     "S3 showOverPlanDialog"    's/(void showOverPlanDialog\(.*?)if \(isFinishing\(\) \|\| isDestroyed\(\)\) return;\n/$1/s' || fails=$((fails+1))
mut "M7 a .setNegativeButton(\"Cancel\" builder put back" pa "S1 confirmStopKeeping"  's/(void confirmStopKeeping\(final String pkg, final Runnable repaint\) \{\n)/${1}        new android.app.AlertDialog.Builder(this).setNegativeButton("Cancel", null).show();\n/' rules || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 7 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
