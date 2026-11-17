#!/usr/bin/env bash
# test-seal-refused-sheets-java.sh [--mutate] -- the sign-out refusal pair on the bottom sheet, run under javac
# (NWP-20261206-11; docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to one
# bottom-sheet design", slice 3, the sign-out group, part 2).
#
# WHY THIS IS COMMITTED. A sign-out refused for an unreadable app is a WARNING sheet whose green button is the safe way
# out ("Stay signed in") and whose risky "Sign out without ..." is red-outlined; that button opens a DESTRUCTIVE sheet
# whose red filled "Drop ... and sign out" records the app Off and signs out, with "Keep me signed in" back to the
# choice. A tone, a button style or a slot moved by one place still compiles and still shows a sheet, so it is pinned
# here. SealRefusedSheets is pure java.util and is compiled with PopupSheet and the cases (today's words as literals).
# Source pins on ProfileActivity.java (comments stripped, whitespace normalised) hold what the cases cannot:
#   S1 showSealRefusedDialog and confirmDropAndSignOut hold no AlertDialog.Builder;
#   S2 showSealRefusedDialog calls SheetDialog.confirm on SealRefusedSheets.refused with the actions
#      { null, confirmDropAndSignOut(pkgs, who, one, restSaved), showReportIssue() }, in that order;
#   S3 confirmDropAndSignOut calls SheetDialog.confirm on SealRefusedSheets.drop (many = pkgs.length > 1) with slot 0 the
#      "nowhere-dropsignout" thread (every recordTurnedOff, then runOnUiThread(this::doLogoff): NWP-20261029-19) and
#      slot 1 showSealRefusedDialog(pkgs, restSaved), byte for byte after normalising.
# Mutant M9 also runs core/chooser/test-appkeep-offmain.sh on its copy, which must FAIL P3.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-seal-refused-sheets-java.sh            # the cases + the pins
#   bash test-seal-refused-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
SHEETS="$SRC/SealRefusedSheets.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/seal-refused-sheets/SealRefusedSheetsCases.java"
OFFMAIN="$root/core/chooser/test-appkeep-offmain.sh"
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
for f in "$CASES" "$PA" "$POPUP" "$OFFMAIN"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <SealRefusedSheets.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that convict a
# mutant), 3 it did not compile.
suite() {
  local sheets="$1" d out rc
  [ -f "$sheets" ] || { echo "  FAIL  SealRefusedSheets.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$POPUP" "$d/src/com/nowhere/chooser/PopupSheet.java"
  cp "$sheets" "$d/src/com/nowhere/chooser/SealRefusedSheets.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/SealRefusedSheetsCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.SealRefusedSheetsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  SealRefusedSheetsCases" >&2
  return 1
}

# code <file> -> the file without comment lines and trailing // comments.
code() { sed -E -e '/^[[:space:]]*(\/\/|\*|\/\*)/d' -e 's/[[:space:]]+\/\/[[:space:]].*$//' "$1"; }
# meth <code file> <name> -> the method's lines, from its 4-space declaration to its 4-space closing brace.
meth() {
  awk -v n="$2" '$0 ~ ("^    [a-zA-Z].* " n "\\(") && !f { f = 1 } f { print } f && /^    }$/ { exit }' "$1"
}
# norm <text> -> one line, every run of whitespace one space.
norm() { printf '%s' "$1" | tr -s '[:space:]' ' '; }
# has <text> <fixed string> -> 0 when the text holds it.
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

S2_CALL='SheetDialog.confirm(this, SealRefusedSheets.refused(who, one, pkgs.length > 1, restSaved), new Runnable[] { null, () -> confirmDropAndSignOut(pkgs, who, one, restSaved), () -> showReportIssue() }, null);'
S3_CALL='SheetDialog.confirm(this, SealRefusedSheets.drop(who, one, pkgs.length > 1, restSaved), new Runnable[] { () -> new Thread(() -> { for (String pkg : pkgs) recordTurnedOff(pkg); runOnUiThread(this::doLogoff); }, "nowhere-dropsignout").start(), () -> showSealRefusedDialog(pkgs, restSaved) }, null);'

# pins <ProfileActivity.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local paf bad=0 m b refused drop
  paf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"
  for m in showSealRefusedDialog confirmDropAndSignOut; do
    b=$(meth "$paf" "$m")
    [ -n "$b" ] || { echo "  FAIL  S1 $m( not found" >&2; bad=1; continue; }
    has "$b" "AlertDialog.Builder" && { echo "  FAIL  S1 $m holds an AlertDialog.Builder" >&2; bad=1; }
  done
  refused=$(norm "$(meth "$paf" showSealRefusedDialog)")
  has "$refused" "$S2_CALL" \
    || { echo "  FAIL  S2 showSealRefusedDialog does not call SheetDialog.confirm on SealRefusedSheets.refused with { null, confirmDropAndSignOut, showReportIssue }" >&2; bad=1; }
  drop=$(norm "$(meth "$paf" confirmDropAndSignOut)")
  has "$drop" "$S3_CALL" \
    || { echo "  FAIL  S3 confirmDropAndSignOut does not call SheetDialog.confirm on SealRefusedSheets.drop with { the record-then-doLogoff thread, showSealRefusedDialog }" >&2; bad=1; }
  b=${drop//doLogoff/}
  [ $(( (${#drop} - ${#b}) / 8 )) -eq 1 ] \
    || { echo "  FAIL  S3 confirmDropAndSignOut names doLogoff other than once" >&2; bad=1; }
  rm -f "$paf"
  [ "$bad" -eq 0 ]
}

# check_all <SealRefusedSheets.java> <ProfileActivity.java> -> 0 when the cases and every pin pass, 1 when one fails,
# 3 when the classes did not compile.
check_all() {
  local rc
  suite "$1"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$2" || rc=1
  return "$rc"
}

echo "== PopupSheet, SealRefusedSheets, ProfileActivity's sign-out refusal pair"
check_all "$SHEETS" "$PA"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases + pins S1-S3"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <sheets|pa> <the assertion that must convict it> <perl-expr> [offmain]
  local d c rc orig out om omrc
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
  if [ "${5:-}" = offmain ]; then
    om=$(APPKEEP_PA="$c" bash "$OFFMAIN" 2>&1); omrc=$?
  fi
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
  case "$out" in
    *"FAIL  $3"*) ;;
    *) echo "  WRONG     $1 -- it failed, but not on '$3':"; printf '%s\n' "$out" | grep -F FAIL | head -3; return 1 ;;
  esac
  if [ "${5:-}" = offmain ]; then
    case "$omrc:$om" in
      1:*"FAIL P3"*) echo "  convicted $1 -- FAIL  $3, and test-appkeep-offmain.sh FAIL P3"; return 0 ;;
    esac
    echo "  WRONG     $1 -- test-appkeep-offmain.sh did not FAIL P3 (rc=$omrc):"; printf '%s\n' "$om" | tail -3
    return 1
  fi
  echo "  convicted $1 -- FAIL  $3"
  return 0
}
fails=0
mut "M1 the restSaved lines swapped"               sheets "refused lines"   's/restSaved \? REST_SAVED : REST_NOT_SAVED/restSaved ? REST_NOT_SAVED : REST_SAVED/' || fails=$((fails+1))
mut "M2 drop's restSaved line shown when false"    sheets "drop lines"      's/if \(restSaved\) lines\.add\(/if (!restSaved) lines.add(/' || fails=$((fails+1))
mut "M3 is/are swapped"                            sheets "refused title"   's/\(many \? " are blocking sign-out" : " is blocking sign-out"\)/(many ? " is blocking sign-out" : " are blocking sign-out")/' || fails=$((fails+1))
mut "M4 Stay signed in made OUTLINED"              sheets "refused buttons" 's/Button\(STAY, PopupSheet\.Style\.GREEN_FILLED\)/Button(STAY, PopupSheet.Style.OUTLINED)/' || fails=$((fails+1))
mut "M5 Sign out without made GREEN_FILLED"        sheets "refused buttons" 's/"Sign out without " \+ one, PopupSheet\.Style\.RED_OUTLINED/"Sign out without " + one, PopupSheet.Style.GREEN_FILLED/' || fails=$((fails+1))
mut "M6 Keep me signed in first"                   sheets "drop buttons"    's/(new PopupSheet\.Button\("Drop " \+ one \+ " and sign out", PopupSheet\.Style\.RED_FILLED\)),(\s*)(new PopupSheet\.Button\(KEEP, PopupSheet\.Style\.OUTLINED\))/$3,$2$1/' || fails=$((fails+1))
mut "M7 Drop made RED_OUTLINED"                    sheets "drop buttons"    's/" and sign out", PopupSheet\.Style\.RED_FILLED/" and sign out", PopupSheet.Style.RED_OUTLINED/' || fails=$((fails+1))
mut "M8 slots 1 and 2 swapped"                     pa     "S2"              's/\(\) -> confirmDropAndSignOut\(pkgs, who, one, restSaved\), \(\) -> showReportIssue\(\)/() -> showReportIssue(), () -> confirmDropAndSignOut(pkgs, who, one, restSaved)/' || fails=$((fails+1))
mut "M9 doLogoff moved to slot 1"                  pa     "S3"              's/\n *runOnUiThread\(this::doLogoff\);[^\n]*//; s/\(\) -> showSealRefusedDialog\(pkgs, restSaved\) \}, null\);/() -> runOnUiThread(this::doLogoff) }, null);/' offmain || fails=$((fails+1))
mut "M10 a builder back in showSealRefusedDialog"  pa     "S1"              's/(\n(\s*)SheetDialog\.confirm\(this, SealRefusedSheets\.refused\()/\n$2new android.app.AlertDialog.Builder(this).show();$1/' || fails=$((fails+1))
mut "M11 refused's several-apps line says is"    sheets "refused lines"   's/" are switched off for this profile and their data/" is switched off for this profile and their data/' || fails=$((fails+1))
mut "M12 drop's several-apps line says stays"     sheets "drop lines"      's/" stay switched off for this profile until you turn them back on/" stays switched off for this profile until you turn them back on/' || fails=$((fails+1))
mut "M13 drop's several-apps line in lower case"  sheets "drop lines"      's/capital\(one\) \+ " stay switched off/one + " stay switched off/' || fails=$((fails+1))
mut "M14 the drop call never says several"        pa     "S3"              's/SealRefusedSheets\.drop\(who, one, pkgs\.length > 1, restSaved\)/SealRefusedSheets.drop(who, one, false, restSaved)/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 14 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
