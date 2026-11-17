#!/usr/bin/env bash
# test-ota-time-sheet-java.sh [--mutate] -- the install-time picker on the bottom sheet, run under javac
# (NWP-20261206-05; docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to one
# bottom-sheet design"; docs/product-decisions.md 2026-11-14, harvest 66, first bullet).
#
# WHY THIS IS COMMITTED. The picker keeps today's TimePicker inside SheetDialog's view slot, with a green Set, an
# outlined Any time and Not now. OtaTimeSheet is pure java.util and is compiled here with PopupSheet and its cases:
#   C1 the model breaks no popup rule and is ROUTINE;  C2 the buttons and their indexes;  C3 today's title;
#   C4 current() parses exactly "HH:MM" in range, else 3:00, and never throws;  C5 hhmm() is two digits, colon, two.
# Source pins (comments stripped, string-aware) hold what the cases cannot:
#   P1 showOtaTimePicker holds no AlertDialog.Builder;  P2 it calls SheetDialog.slot on OtaTimeSheet.model() once;
#   P3 the alarm is armed after a saved Set and cancelled after a saved Any time, once each;
#   P4 slot checks the rules and adds the slot view before the buttons;  P5 slot is not in show's ScrollView;
#   P6 the shared window helper sets Gravity.BOTTOM, and slot and show both use it.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-ota-time-sheet-java.sh            # the cases + the pins
#   bash test-ota-time-sheet-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
SHEET="$SRC/OtaTimeSheet.java"
DIALOG="$SRC/SheetDialog.java"
ACT="$SRC/ChooserActivity.java"
CASES="$root/core/chooser/tests/ota-time-sheet/OtaTimeSheetCases.java"
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
for f in "$CASES" "$POPUP" "$DIALOG" "$ACT"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <OtaTimeSheet.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that convict a
# mutant), 3 it did not compile.
suite() {
  local sheet="$1" d out rc
  [ -f "$sheet" ] || { echo "--- FAIL C1 OtaTimeSheet.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$POPUP" "$d/src/com/nowhere/chooser/PopupSheet.java"
  cp "$sheet" "$d/src/com/nowhere/chooser/OtaTimeSheet.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/OtaTimeSheetCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then
    rm -rf "$d"; return 3
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.OtaTimeSheetCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ]
}

# strip_java <file> -> the source without its comments, string- and char-literal aware (as test-gate-dialogs-java.sh)
strip_java() { perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|/\*.*?\*/|//[^\n]*}{defined $1 ? $1 : ""}gse' "$1"; }
# body <stripped file> <signature> -> the method from the line holding the signature to its closing brace
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}
# times <text> <fixed string> -> how many times the text holds the string
times() { S="$2" perl -0ne '$n = () = /\Q$ENV{S}\E/g; print $n + 0' <<<"$1"; }
# at <text> <fixed string> -> the offset of the first match, or -1
at() { S="$2" perl -0ne 'print index($_, $ENV{S})' <<<"$1"; }

# pins <ChooserActivity.java> <SheetDialog.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local bad=0 act dlg ota slot win show k a b
  act=$(mktemp -p "$W") || return 1
  dlg=$(mktemp -p "$W") || return 1
  strip_java "$1" > "$act"
  strip_java "$2" > "$dlg"
  ota=$(body "$act" 'private void showOtaTimePicker(')
  slot=$(body "$dlg" 'static Dialog slot(')
  win=$(body "$dlg" 'private static void window(')
  show=$(body "$dlg" 'private static void show(')

  if [ -z "$ota" ]; then echo "--- FAIL P1 showOtaTimePicker( not found" >&2; bad=1
  else
    [ "$(times "$ota" 'AlertDialog.Builder')" = 0 ] || { echo "--- FAIL P1 showOtaTimePicker holds an AlertDialog.Builder" >&2; bad=1; }
    [ "$(times "$ota" 'SheetDialog.slot(this, OtaTimeSheet.model(), tp,')" = 1 ] \
      || { echo "--- FAIL P2 showOtaTimePicker does not call SheetDialog.slot(this, OtaTimeSheet.model(), tp, once" >&2; bad=1; }
    for k in 'if (saved) OtaTimeReceiver.arm(getApplicationContext(), hhmm);' \
             'if (saved) OtaTimeReceiver.cancel(getApplicationContext());'; do
      [ "$(times "$ota" "$k")" = 1 ] || { echo "--- FAIL P3 showOtaTimePicker does not hold once: $k" >&2; bad=1; }
    done
  fi

  if [ -z "$slot" ]; then echo "--- FAIL P4 SheetDialog.slot( not found" >&2; bad=1
  else
    [ "$(times "$slot" 'warn(PopupSheet.violations(m));')" = 1 ] \
      || { echo "--- FAIL P4 slot does not call warn(PopupSheet.violations(m))" >&2; bad=1; }
    a=$(at "$slot" 'panel.addView(slot,'); b=$(at "$slot" 'buttons(')
    { [ "$a" -ge 0 ] && [ "$b" -ge 0 ] && [ "$a" -lt "$b" ]; } \
      || { echo "--- FAIL P4 slot does not add the slot view before the buttons (slot at $a, buttons at $b)" >&2; bad=1; }
    [ "$(times "$slot" 'show(dlg, panel)')" = 0 ] || { echo "--- FAIL P5 slot is shown through show(dlg, panel)" >&2; bad=1; }
    [ "$(times "$slot" 'ScrollView')" = 0 ] || { echo "--- FAIL P5 slot holds a ScrollView" >&2; bad=1; }
    [ "$(times "$slot" 'window(dlg, panel);')" = 1 ] || { echo "--- FAIL P6 slot does not call window(dlg, panel)" >&2; bad=1; }
  fi
  [ "$(times "$win" 'Gravity.BOTTOM')" = 1 ] || { echo "--- FAIL P6 the window helper does not set Gravity.BOTTOM" >&2; bad=1; }
  [ "$(times "$show" 'window(dlg, scroll);')" = 1 ] || { echo "--- FAIL P6 show does not call window(dlg, scroll)" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# check_all <OtaTimeSheet.java> <ChooserActivity.java> <SheetDialog.java> -> 0 when the cases and every pin pass, 1
# when one fails, 3 when the classes did not compile.
check_all() {
  local rc
  suite "$1"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$2" "$3" || rc=1
  return "$rc"
}

echo "== OtaTimeSheet, showOtaTimePicker, SheetDialog.slot"
check_all "$SHEET" "$ACT" "$DIALOG"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases C1-C5 + pins P1-P6"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <sheet|dialog|act> <the assertion that must convict it> <perl-expr>
  local d c rc orig out
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in sheet) orig="$SHEET" ;; dialog) orig="$DIALOG" ;; *) orig="$ACT" ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    sheet) out=$(check_all "$c" "$ACT" "$DIALOG" 2>&1); rc=$? ;;
    dialog) out=$(check_all "$SHEET" "$ACT" "$c" 2>&1); rc=$? ;;
    *) out=$(check_all "$SHEET" "$c" "$DIALOG" 2>&1); rc=$? ;;
  esac
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
  case "$out" in
    *"--- FAIL $3"*) echo "  convicted $1 -- --- FAIL $3"; return 0 ;;
  esac
  echo "  WRONG     $1 -- it failed, but not on '$3':"; printf '%s\n' "$out" | grep -F FAIL | head -3
  return 1
}
fails=0
mut "M1 Set is outlined"                       sheet  "C1"                  's/new PopupSheet\.Button\(SET, PopupSheet\.Style\.GREEN_FILLED\)/new PopupSheet.Button(SET, PopupSheet.Style.OUTLINED)/' || fails=$((fails+1))
mut "M1 Set is outlined (C2)"                  sheet  "C2 Set"              's/new PopupSheet\.Button\(SET, PopupSheet\.Style\.GREEN_FILLED\)/new PopupSheet.Button(SET, PopupSheet.Style.OUTLINED)/' || fails=$((fails+1))
mut "M2 Any time and Not now swapped"          sheet  "C2"                  's/(new PopupSheet\.Button\(ANY_TIME, PopupSheet\.Style\.OUTLINED\)), (new PopupSheet\.Button\(PopupSheet\.NOT_NOW, PopupSheet\.Style\.OUTLINED\))/$2, $1/' || fails=$((fails+1))
mut "M3 Not now reads Cancel"                  sheet  "C1"                  's/new PopupSheet\.Button\(PopupSheet\.NOT_NOW, /new PopupSheet.Button("Cancel", /' || fails=$((fails+1))
mut "M4 current's range check dropped"         sheet  'C4 current("24:00")' 's/if \(h < 24 && m < 60\) return/if (true) return/' || fails=$((fails+1))
mut "M5 the default hour is 0"                 sheet  "C4"                  's/return new int\[\] \{ 3, 0 \};/return new int[] { 0, 0 };/' || fails=$((fails+1))
mut "M6 hhmm drops the leading zero"           sheet  "C5"                  's/"%02d:%02d"/"%d:%02d"/' || fails=$((fails+1))
mut "M7 an AlertDialog.Builder in the picker"  act    "P1"                  's/(\n(\s+)final int\[\] hm = OtaTimeSheet\.current\(cur\);)/$1\n$2new android.app.AlertDialog.Builder(this);/' || fails=$((fails+1))
mut "M8 the alarm armed after a failed save"   act    "P3"                  's/if \(saved\) (OtaTimeReceiver\.arm\()/$1/' || fails=$((fails+1))
mut "M9 slot adds the buttons first"           dialog "P4"                  's/(\n\s+panel\.addView\(slot, slp\);)(\n\s+panel\.addView\(buttons\(ctx, p, m, dlg, actions\), topMargin\(ctx, 16\)\);)(\n\s+window\(dlg, panel\);)/$2$1$3/' || fails=$((fails+1))
mut "M10 slot shown through show"              dialog "P5"                  's/window\(dlg, panel\);\n(\s+return dlg;)/show(dlg, panel);\n$1/' || fails=$((fails+1))
mut "M11 slot does not check the rules"        dialog "P4"                  's/(static Dialog slot\([^\n]*\n)\s+warn\(PopupSheet\.violations\(m\)\);\n/$1/' || fails=$((fails+1))
mut "M12 the sheet is not at the bottom"       dialog "P6"                  's/\n\s+w\.setGravity\(Gravity\.BOTTOM\);//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 13 mutations convicted (M1-M12; M1 twice, once per case)" || { echo "== $fails mutation(s) not convicted"; exit 1; }
