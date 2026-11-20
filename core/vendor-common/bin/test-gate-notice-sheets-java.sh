#!/usr/bin/env bash
# test-gate-notice-sheets-java.sh [--mutate] -- the gate's Repair SIM bindings ask, OTA notes and lost-credit notice on
# the shared bottom sheet, run under javac (NWP-20261206-17; docs/backlog.md, "Popups are plain dialogs: the choice
# pickers and the confirmations move to one bottom-sheet design", slice 3).
#
# WHY THIS IS COMMITTED. The three were plain AlertDialogs with an OK or a Cancel button. GateNoticeSheets models them in
# design A with today's words: the Repair ask is routine, "Repair" green and "Not now" outlined; the OTA notes and the
# lost-credit notice are routine with one "Got it". GateNoticeSheets, BindingsRepair and PopupSheet are pure java.util and
# are compiled here with their cases (C1-C6). Source pins (comments stripped) hold what the cases cannot:
#   S1 showOtaNotes, refreshCreditLostNotice and confirmRepairBindings hold no AlertDialog.Builder;
#   S2 confirmRepairBindings reads owned before the sheet, its action is slot 0 and slot 1 ("Not now") is null;
#   S3 showOtaNotes passes view.title and view.body to the sheet;
#   S4 refreshCreditLostNotice shows a HELD sheet (Back and a touch outside do not close it: NWP-20261013-20 clears the
#      notice only after it is seen) whose slot-0 action is the clear, and the file clears it from that one place;
#   S5 SheetDialog.show holds the sheet only when held: setCancelable(false) and setCanceledOnTouchOutside(false), else
#      today's setCanceledOnTouchOutside(true); confirmHeld passes held, confirm and picker do not. The file sets
#      setCanceledOnTouchOutside five times: the two branches, slot()'s own true (NWP-20261206-05's slot sheet is
#      shown through window(), not show()), and the live sheet's progress() false and confirm() true; it sets
#      setCancelable three times: the held branch and the live sheet's two (NWP-20261208-28).
# Mutant X4 changes creditLost alone: otaNotes and creditLost share one builder, so creditLost gets its own "OK" body.
# Mutant X9 also runs core/chooser/test-popup-rules.sh on the mutated tree, which must report the breach as NEW.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-gate-notice-sheets-java.sh            # the cases + the pins
#   bash test-gate-notice-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
REPAIR="$SRC/BindingsRepair.java"
SHEETS="$SRC/GateNoticeSheets.java"
ACT="$SRC/ChooserActivity.java"
DIALOG="$SRC/SheetDialog.java"
LINT="$root/core/chooser/test-popup-rules.sh"
CASES="$root/core/chooser/tests/gate-notice-sheets/GateNoticeSheetsCases.java"
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
"$JAVAC" -J-Djava.io.tmpdir="$W" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# suite <PopupSheet> <BindingsRepair> <GateNoticeSheets> -> 0 pass, 1 a case failed or a class is missing (the only
# codes that convict a mutant), 3 it did not compile.
suite() {
  local popup="$1" repair="$2" sheets="$3" d out rc
  [ -f "$popup" ] || { echo "  FAIL  C0 PopupSheet.java does not exist" >&2; return 1; }
  [ -f "$repair" ] || { echo "  FAIL  C0 BindingsRepair.java does not exist" >&2; return 1; }
  [ -f "$sheets" ] || { echo "  FAIL  C0 GateNoticeSheets.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$popup" "$d/src/com/nowhere/chooser/PopupSheet.java"
  cp "$repair" "$d/src/com/nowhere/chooser/BindingsRepair.java"
  cp "$sheets" "$d/src/com/nowhere/chooser/GateNoticeSheets.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/GateNoticeSheetsCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then
    rm -rf "$d"; return 3
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.GateNoticeSheetsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
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
# cnt <text> <fixed string> -> how many times the text holds it.
cnt() { local t="$1" n=0; while [[ "$t" == *"$2"* ]]; do n=$((n + 1)); t=${t#*"$2"}; done; echo "$n"; }
# at <text> <fixed string> -> the offset of its first occurrence, or -1.
at() { local p; [[ "$1" == *"$2"* ]] || { echo -1; return; }; p=${1%%"$2"*}; echo "${#p}"; }

OWN='final boolean owned = ownerSessionPass != null;'
REPAIR_SHEET='SheetDialog.confirm(this, GateNoticeSheets.repairBindings(), new Runnable[] { () -> {'
REPAIR_END='}, null }, null);'
SEND='sendDaemon("REPAIR-BINDINGS\n");'
OTA_SHEET='SheetDialog.confirm(this, GateNoticeSheets.otaNotes(view.title, view.body), null, null);'
HELD_SHEET='SheetDialog.confirmHeld(this, GateNoticeSheets.creditLost(CREDIT_LOST_TITLE,'
HELD_ACTION='new Runnable[] { () -> new Thread(() -> {'
CLEAR='sendDaemon(creditLostClearCommand(stamp))'

# pins <ChooserActivity.java> <SheetDialog.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local af df bad=0 b m k a e
  af=$(mktemp -p "$W") || return 1
  df=$(mktemp -p "$W") || return 1
  code "$1" > "$af"; code "$2" > "$df"

  for m in showOtaNotes refreshCreditLostNotice confirmRepairBindings; do
    b=$(meth "$af" "$m")
    [ -n "$b" ] || { echo "  FAIL  S1 $m( not found" >&2; bad=1; continue; }
    has "$b" "AlertDialog.Builder" && { echo "  FAIL  S1 $m holds an AlertDialog.Builder" >&2; bad=1; }
  done

  b=$(meth "$af" confirmRepairBindings)
  a=$(at "$b" "$REPAIR_SHEET"); e=$(at "$b" "$SEND")
  if [ "$(cnt "$b" "$OWN")" != 1 ] || [ "$a" -lt 0 ] || [ "$(at "$b" "$OWN")" -gt "$a" ] || [ "$e" -lt "$a" ] \
     || [ "$(cnt "$b" "$REPAIR_SHEET")" != 1 ] || [ "$(cnt "$b" "$REPAIR_END")" != 1 ] \
     || [ "$(at "$b" "$REPAIR_END")" -lt "$e" ]; then
    echo "  FAIL  S2 confirmRepairBindings does not read owned, then show the Repair sheet with the send in slot 0 and slot 1 null" >&2; bad=1
  fi

  has "$(meth "$af" showOtaNotes)" "$OTA_SHEET" \
    || { echo "  FAIL  S3 showOtaNotes does not show GateNoticeSheets.otaNotes(view.title, view.body)" >&2; bad=1; }

  b=$(meth "$af" refreshCreditLostNotice)
  a=$(at "$b" "$HELD_SHEET"); k=$(at "$b" "$HELD_ACTION"); e=$(at "$b" "$CLEAR")
  if [ "$a" -lt 0 ] || [ "$k" -lt "$a" ] || [ "$e" -lt "$k" ] || has "$b" "SheetDialog.confirm(" \
     || [ "$(grep -o -F 'creditLostClearCommand(stamp)' "$af" | wc -l | tr -d ' ')" != 1 ] \
     || [ "$(grep -c -F 'private android.app.Dialog creditLostDialog;' "$af")" != 1 ]; then
    echo "  FAIL  S4 refreshCreditLostNotice does not show a held sheet whose slot-0 action is the one clear" >&2; bad=1
  fi

  # S5: the held branch and the not-held branch, each once, and the three callers' flags.
  if ! perl -0e 'my $s = $ARGV[0]; exit($s =~ /if \(held\) \{\s*dlg\.setCancelable\(false\);\s*dlg\.setCanceledOnTouchOutside\(false\);\s*\} else \{\s*dlg\.setCanceledOnTouchOutside\(true\);\s*\}/ ? 0 : 1)' "$(meth "$df" show)" \
     || ! has "$(cat "$df")" "private static void show(Dialog dlg, LinearLayout panel, boolean held) {" \
     || [ "$(cnt "$(cat "$df")" 'setCancelable(')" != 3 ] || [ "$(cnt "$(cat "$df")" 'setCanceledOnTouchOutside(')" != 5 ] \
     || [ "$(cnt "$(meth "$df" slot)" 'dlg.setCanceledOnTouchOutside(true);')" != 1 ] \
     || ! has "$(meth "$df" confirmHeld)" "return confirmSheet(ctx, m, actions, null, true);" \
     || ! has "$(meth "$df" confirm)" "return confirmSheet(ctx, m, actions, onLink, false);" \
     || ! has "$(meth "$df" confirmSheet)" "show(dlg, panel, held);" \
     || ! has "$(meth "$df" picker)" "show(dlg, panel, false);"; then
    echo "  FAIL  S5 SheetDialog does not hold the sheet exactly when held (confirmHeld held; confirm and picker not)" >&2; bad=1
  fi
  rm -f "$af" "$df"
  [ "$bad" -eq 0 ]
}

# check_all <PopupSheet> <BindingsRepair> <GateNoticeSheets> <ChooserActivity> <SheetDialog> -> 0 when the cases and
# every pin pass, 1 when one fails, 3 when the classes did not compile.
check_all() {
  local rc
  suite "$1" "$2" "$3"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$4" "$5" || rc=1
  return "$rc"
}

echo "== GateNoticeSheets, BindingsRepair, PopupSheet (+ pins in ChooserActivity.java and SheetDialog.java)"
check_all "$POPUP" "$REPAIR" "$SHEETS" "$ACT" "$DIALOG"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
echo "ok: cases C1-C6 + pins S1-S5"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
# mut <label> <repair|sheets|act|dialog> <the assertion that must convict it> <perl-expr>
mut() {
  local d c rc orig out p="$POPUP" r="$REPAIR" s="$SHEETS" a="$ACT" g="$DIALOG"
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in repair) orig="$REPAIR" ;; sheets) orig="$SHEETS" ;; act) orig="$ACT" ;; *) orig="$DIALOG" ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in repair) r="$c" ;; sheets) s="$c" ;; act) a="$c" ;; *) g="$c" ;; esac
  out=$(check_all "$p" "$r" "$s" "$a" "$g" 2>&1); rc=$?
  MUTANT_DIR="$d"
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
# lint_new <mutated ChooserActivity.java> <expected NEW line> -> 0 when test-popup-rules.sh on a tree holding the
# mutant reports that NEW breach.
lint_new() {
  local t out
  t=$(mktemp -d -p "$W") || return 1
  cp -r "$SRC/." "$t/"
  cp "$1" "$t/ChooserActivity.java"
  out=$(SRC_DIR="$t" bash "$LINT" 2>&1)
  rm -rf "$t"
  case "$out" in *"$2"*) echo "  convicted X9 by test-popup-rules.sh -- $2"; return 0 ;; esac
  echo "  SURVIVED  X9 in test-popup-rules.sh -- no '$2'"; return 1
}
T=$'\t'
fails=0
mut "X1 Repair outlined and Not now green"           sheets "C1 repairBindings button 0"  's/new PopupSheet\.Button\("Repair", PopupSheet\.Style\.GREEN_FILLED\)/new PopupSheet.Button("Repair", PopupSheet.Style.OUTLINED)/; s/new PopupSheet\.Button\(PopupSheet\.NOT_NOW, PopupSheet\.Style\.OUTLINED\)/new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.GREEN_FILLED)/' || fails=$((fails+1))
rm -rf "${MUTANT_DIR:-}"
mut "X2 a word dropped from CONFIRM_AFTER"           repair "C2 CONFIRM_CONTEXT"          's/this phone\x27s own line/this phone\x27s line/' || fails=$((fails+1))
rm -rf "${MUTANT_DIR:-}"
mut "X3 otaNotes' title fixed"                       sheets "C3 otaNotes(X, Y)"           's/return gotIt\(title, body\);/return gotIt("What\x27s new", body);/' || fails=$((fails+1))
rm -rf "${MUTANT_DIR:-}"
mut "X4 creditLost's button OK"                      sheets "C4 creditLost(T, B)"         's/return gotIt\(title, text\);/return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, title, text, Collections.emptyList(), Collections.singletonList(new PopupSheet.Button("OK", PopupSheet.Style.GREEN_FILLED)));/' || fails=$((fails+1))
rm -rf "${MUTANT_DIR:-}"
mut "X5 the repair action in slot 1"                 act    "S2 confirmRepairBindings"    's/GateNoticeSheets\.repairBindings\(\), new Runnable\[\] \{ \(\) -> \{/GateNoticeSheets.repairBindings(), new Runnable[] { null, () -> {/; s/(\}, "nowhere-bindings-repair"\)\.start\(\);\n\s*)\}, null \}, null\);/$1} }, null);/' || fails=$((fails+1))
rm -rf "${MUTANT_DIR:-}"
mut "X6 the lost-credit notice on a plain confirm"   act    "S4 refreshCreditLostNotice"  's/SheetDialog\.confirmHeld\(this, GateNoticeSheets\.creditLost\(/SheetDialog.confirm(this, GateNoticeSheets.creditLost(/; s/(\}, "nowhere-credit-lost"\)\.start\(\) \})\);/$1, null);/' || fails=$((fails+1))
rm -rf "${MUTANT_DIR:-}"
mut "X7 setCancelable(false) dropped"                dialog "S5 SheetDialog"              's/\n\s*dlg\.setCancelable\(false\);//' || fails=$((fails+1))
rm -rf "${MUTANT_DIR:-}"
mut "X8 confirmHeld passes not held"                 dialog "S5 SheetDialog"              's/return confirmSheet\(ctx, m, actions, null, true\);/return confirmSheet(ctx, m, actions, null, false);/' || fails=$((fails+1))
rm -rf "${MUTANT_DIR:-}"
X9_EXPR='s/SheetDialog\.confirm\(this, GateNoticeSheets\.otaNotes\(view\.title, view\.body\), null, null\);/new android.app.AlertDialog.Builder(this).setTitle(view.title).setMessage(view.body).setPositiveButton("OK", null).show();/'
if mut "X9 an AlertDialog OK back in showOtaNotes"   act    "S1 showOtaNotes"             "$X9_EXPR"; then
  lint_new "$MUTANT_DIR/ChooserActivity.java" "NEW: ChooserActivity.java${T}showOtaNotes${T}R1${T}OK (baseline 0, found 1)" || fails=$((fails+1))
else
  fails=$((fails+1))
fi
rm -rf "${MUTANT_DIR:-}"
[ "$fails" -eq 0 ] && echo "== all 9 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
