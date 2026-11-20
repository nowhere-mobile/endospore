#!/usr/bin/env bash
# test-logoff-fail-sheets-java.sh [--mutate] -- a failed sign-out's choice and its two second steps on held sheets,
# run under javac (NWP-20261208-22; docs/backlog.md, "Popups are plain dialogs: the choice pickers and the
# confirmations move to one bottom-sheet design", slice 3).
#
# WHY THIS IS COMMITTED. ProfileActivity.showLogoffFailedDialog offers the exits failedDialogExit chose, and
# confirmEndUnsaved / confirmRestartUnsaved are the steps before a session is dropped. All three stay until a button
# answers them (NWP-20261010-10), so each is a held sheet (SheetDialog.confirmHeld). LogoffFailSheets holds their words
# and the meaning of each button; it is pure java.util and is compiled here with PopupSheet and its cases. Source pins
# (comments stripped) hold what the cases cannot:
#   L1 the three methods hold no AlertDialog.Builder and no SheetDialog.confirm(, and each calls SheetDialog.confirmHeld(
#      once;
#   L2 showLogoffFailedDialog's USE_KEY arm sends DaemonSocket.roundTrip("ADOPT-FIDO2\n", 100000) and signs out on OK;
#   L3 confirmEndUnsaved maps END_CONFIRM_ACTS: END_CONFIRMED runs endUnsaved(msg, offline) and BACK re-shows the choice
#      with offline ? "LOCK-END" : "END"; confirmRestartUnsaved maps RESTART_CONFIRM_ACTS the same way, BACK with "RESTART";
#   L4 SheetDialog's 4-arg confirmHeld returns confirmSheet(ctx, m, actions, onLink, true), and show()'s held branch
#      still calls setCancelable(false);
#   L5 showLogoffFailedDialog maps LogoffFailSheets.acts(exit) to its runnables (END_UNSAVED, RESTART_UNSAVED, LOCK)
#      and opens Report an issue from the "Report this" link line.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-logoff-fail-sheets-java.sh            # the cases + the pins
#   bash test-logoff-fail-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
SHEETS="$SRC/LogoffFailSheets.java"
DIALOG="$SRC/SheetDialog.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/logoff-fail-sheets/LogoffFailSheetsCases.java"
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
for f in "$CASES" "$POPUP" "$PA" "$DIALOG"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <PopupSheet.java> <LogoffFailSheets.java> -> 0 pass, 1 a case failed or a class is missing (the only codes
# that convict a mutant), 3 it did not compile.
suite() {
  local popup="$1" sheets="$2" d out rc
  [ -f "$popup" ] || { echo "  FAIL  PopupSheet.java does not exist" >&2; return 1; }
  [ -f "$sheets" ] || { echo "  FAIL  LogoffFailSheets.java does not exist (the class is missing)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$popup" "$d/src/com/nowhere/chooser/PopupSheet.java"
  cp "$sheets" "$d/src/com/nowhere/chooser/LogoffFailSheets.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/LogoffFailSheetsCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then
    rm -rf "$d"; return 3
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.LogoffFailSheetsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  LogoffFailSheetsCases" >&2
  return 1
}

# code <file> -> the file without comment lines and trailing // comments.
code() { sed -E -e '/^[[:space:]]*(\/\/|\*|\/\*)/d' -e 's/[[:space:]]+\/\/[[:space:]].*$//' "$1"; }
# meth <code file> <name> -> the first such method's lines, from its 4-space declaration to its 4-space closing brace.
meth() {
  awk -v n="$2" '$0 ~ ("^    [a-zA-Z].* " n "\\(") && !f { f = 1 } f { print } f && /^    }$/ { exit }' "$1"
}
# meth4 <code file> -> SheetDialog's confirmHeld that takes onLink.
meth4() {
  awk '/^    [a-zA-Z].* confirmHeld\(.*Consumer<String> onLink\) \{$/ && !f { f = 1 } f { print } f && /^    }$/ { exit }' "$1"
}
# arm <method text> <CASE> -> the lines of `case <CASE>:` up to the next `case X:` or the method's end.
arm() {
  printf '%s\n' "$1" | awk -v c="$2" '
    $0 ~ ("^[[:space:]]+case " c ":") { f = 1; print; next }
    f && /^[[:space:]]+case [A-Z_]+:/ { exit }
    f { print }'
}
# has <text> <fixed string> -> 0 when the text holds it.
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
# count <text> <fixed string> -> how many times the text holds it.
count() {
  local t="$1" n=0
  while case "$t" in *"$2"*) true ;; *) false ;; esac; do t=${t#*"$2"}; n=$((n + 1)); done
  echo "$n"
}

# pins <ProfileActivity.java> <SheetDialog.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local paf dlf bad=0 b m n
  paf=$(mktemp -p "$W") || return 1
  dlf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"
  code "$2" > "$dlf"

  for m in showLogoffFailedDialog confirmEndUnsaved confirmRestartUnsaved; do
    b=$(meth "$paf" "$m")
    [ -n "$b" ] || { echo "  FAIL  L1 $m( not found" >&2; bad=1; continue; }
    has "$b" "AlertDialog.Builder" && { echo "  FAIL  L1 $m holds an AlertDialog.Builder" >&2; bad=1; }
    has "$b" "SheetDialog.confirm(" && { echo "  FAIL  L1 $m shows a sheet Back can close (SheetDialog.confirm()" >&2; bad=1; }
    n=$(count "$b" "SheetDialog.confirmHeld(")
    [ "$n" = 1 ] || { echo "  FAIL  L1 $m calls SheetDialog.confirmHeld( $n times, not once" >&2; bad=1; }
  done

  b=$(meth "$paf" showLogoffFailedDialog)
  m=$(arm "$b" USE_KEY)
  has "$m" 'final String r = DaemonSocket.roundTrip("ADOPT-FIDO2\n", 100000);' \
    || { echo "  FAIL  L2 the USE_KEY arm does not send DaemonSocket.roundTrip(\"ADOPT-FIDO2\\n\", 100000)" >&2; bad=1; }
  has "$m" 'doLogoff();' || { echo "  FAIL  L2 the USE_KEY arm does not sign out (doLogoff()) once the key is adopted" >&2; bad=1; }
  has "$b" "PopupSheet.Confirm m = LogoffFailSheets.failed(exit, msg, reportable);" \
    || { echo "  FAIL  L5 showLogoffFailedDialog does not show LogoffFailSheets.failed(exit, msg, reportable)" >&2; bad=1; }
  has "$b" "java.util.List<LogoffFailSheets.Act> acts = LogoffFailSheets.acts(exit);" \
    || { echo "  FAIL  L5 showLogoffFailedDialog does not map LogoffFailSheets.acts(exit)" >&2; bad=1; }
  has "$(arm "$b" END_UNSAVED)" "a[i] = () -> confirmEndUnsaved(msg);" \
    || { echo "  FAIL  L5 END_UNSAVED does not open confirmEndUnsaved(msg)" >&2; bad=1; }
  has "$(arm "$b" RESTART_UNSAVED)" "a[i] = () -> confirmRestartUnsaved(msg);" \
    || { echo "  FAIL  L5 RESTART_UNSAVED does not open confirmRestartUnsaved(msg)" >&2; bad=1; }
  has "$(arm "$b" LOCK)" "a[i] = () -> doColdLock();" || { echo "  FAIL  L5 LOCK does not call doColdLock()" >&2; bad=1; }
  has "$b" "SheetDialog.confirmHeld(this, m, a, m.lines.isEmpty() ? null : key -> showReportIssue());" \
    || { echo "  FAIL  L5 the Report this link line does not open showReportIssue()" >&2; bad=1; }

  b=$(meth "$paf" confirmEndUnsaved)
  has "$b" "java.util.List<LogoffFailSheets.Act> acts = LogoffFailSheets.END_CONFIRM_ACTS;" \
    || { echo "  FAIL  L3 confirmEndUnsaved does not map LogoffFailSheets.END_CONFIRM_ACTS" >&2; bad=1; }
  has "$(arm "$b" END_CONFIRMED)" "a[i] = () -> endUnsaved(msg, offline);" \
    || { echo "  FAIL  L3 confirmEndUnsaved's END_CONFIRMED does not run endUnsaved(msg, offline)" >&2; bad=1; }
  has "$(arm "$b" BACK)" 'a[i] = () -> showLogoffFailedDialog(msg, true, fresh, offline ? "LOCK-END" : "END");' \
    || { echo "  FAIL  L3 confirmEndUnsaved's BACK does not re-show the choice with offline ? \"LOCK-END\" : \"END\"" >&2; bad=1; }
  has "$b" "SheetDialog.confirmHeld(this, LogoffFailSheets.endConfirm(text), a, null);" \
    || { echo "  FAIL  L3 confirmEndUnsaved does not show LogoffFailSheets.endConfirm(text)" >&2; bad=1; }

  b=$(meth "$paf" confirmRestartUnsaved)
  has "$b" "java.util.List<LogoffFailSheets.Act> acts = LogoffFailSheets.RESTART_CONFIRM_ACTS;" \
    || { echo "  FAIL  L3 confirmRestartUnsaved does not map LogoffFailSheets.RESTART_CONFIRM_ACTS" >&2; bad=1; }
  has "$(arm "$b" RESTART_CONFIRMED)" "a[i] = () -> restartUnsaved();" \
    || { echo "  FAIL  L3 confirmRestartUnsaved's RESTART_CONFIRMED does not run restartUnsaved()" >&2; bad=1; }
  has "$(arm "$b" BACK)" 'a[i] = () -> showLogoffFailedDialog(msg, true, fresh, "RESTART");' \
    || { echo "  FAIL  L3 confirmRestartUnsaved's BACK does not re-show the choice with \"RESTART\"" >&2; bad=1; }
  has "$b" "SheetDialog.confirmHeld(this, LogoffFailSheets.restartConfirm(text), a, null);" \
    || { echo "  FAIL  L3 confirmRestartUnsaved does not show LogoffFailSheets.restartConfirm(text)" >&2; bad=1; }

  b=$(meth4 "$dlf")
  [ -n "$b" ] || { echo "  FAIL  L4 SheetDialog.confirmHeld(..., Consumer<String> onLink) not found" >&2; bad=1; }
  has "$b" "return confirmSheet(ctx, m, actions, onLink, true);" \
    || { echo "  FAIL  L4 the 4-arg confirmHeld does not return confirmSheet(ctx, m, actions, onLink, true)" >&2; bad=1; }
  b=$(meth "$dlf" show)
  n=$(printf '%s\n' "$b" | perl -0ne 'print scalar(() = /if \(held\) \{\n\s*dlg\.setCancelable\(false\);/g)')
  [ "$n" = 1 ] || { echo "  FAIL  L4 SheetDialog.show's held branch does not call dlg.setCancelable(false)" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# check_all <PopupSheet.java> <LogoffFailSheets.java> <ProfileActivity.java> <SheetDialog.java> -> 0 when the cases
# and every pin pass, 1 when one fails, 3 when the classes did not compile.
check_all() {
  local rc
  suite "$1" "$2"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$3" "$4" || rc=1
  return "$rc"
}

echo "== LogoffFailSheets, showLogoffFailedDialog, confirmEndUnsaved, confirmRestartUnsaved, SheetDialog.confirmHeld"
check_all "$POPUP" "$SHEETS" "$PA" "$DIALOG"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases + pins L1-L5"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <sheets|pa|dialog> <the assertion that must convict it> <perl-expr>
  local d c rc orig out
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in sheets) orig="$SHEETS" ;; dialog) orig="$DIALOG" ;; *) orig="$PA" ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    sheets) out=$(check_all "$POPUP" "$c" "$PA" "$DIALOG" 2>&1); rc=$? ;;
    dialog) out=$(check_all "$POPUP" "$SHEETS" "$PA" "$c" 2>&1); rc=$? ;;
    *) out=$(check_all "$POPUP" "$SHEETS" "$c" "$DIALOG" 2>&1); rc=$? ;;
  esac
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
  echo "  convicted $1 -- FAIL  $3"
  return 0
}

fails=0
mut "X1 Stay signed in made RED_OUTLINED on RESTART" sheets "RESTART reportable=true button 0 style" \
  's/(case "RESTART":\n[^\n]*\n\s*\.add\(L_STAY, PopupSheet\.Style\.)GREEN_FILLED/${1}RED_OUTLINED/' || fails=$((fails+1))
mut "X2 KEY-END's acts swapped against its buttons" sheets "KEY-END reportable=true act 0" \
  's/(\.add\(L_USE_KEY, PopupSheet\.Style\.GREEN_FILLED, Act\.)USE_KEY\)(\n\s*\.add\(L_END_UNSAVED, PopupSheet\.Style\.RED_OUTLINED, Act\.)END_UNSAVED\)/${1}END_UNSAVED)${2}USE_KEY)/' || fails=$((fails+1))
mut "X3 Report this added to KEY-END"               sheets "KEY-END reportable=true no link line" \
  's/(case "KEY-END":\n[^\n]*\n\s*return new Exit\(FAILED_TONE, TITLE_CANT_SAVE, )false\)/${1}true)/' || fails=$((fails+1))
mut "X4 Got it relabelled OK"                       sheets "'' reportable=true no OK or Cancel" \
  's/\.add\(PopupSheet\.GOT_IT, /.add("OK", /' || fails=$((fails+1))
mut "X5 confirmEndUnsaved on SheetDialog.confirm (not held)" pa "L1 confirmEndUnsaved" \
  's/SheetDialog\.confirmHeld\(this, LogoffFailSheets\.endConfirm\(text\), a, null\);/SheetDialog.confirm(this, LogoffFailSheets.endConfirm(text), a, null);/' || fails=$((fails+1))
mut "X6 the adopt call removed"                     pa     "L2 the USE_KEY arm does not send" \
  's/final String r = DaemonSocket\.roundTrip\("ADOPT-FIDO2\x5cn", 100000\);/final String r = null;/' || fails=$((fails+1))
mut "X7 confirmEndUnsaved's Back re-shows END always" pa   "L3 confirmEndUnsaved's BACK" \
  's/showLogoffFailedDialog\(msg, true, fresh, offline \? "LOCK-END" : "END"\)/showLogoffFailedDialog(msg, true, fresh, "END")/' || fails=$((fails+1))
mut "X8 the held branch's setCancelable(false) removed" dialog "L4 SheetDialog.show's held branch" \
  's/(if \(held\) \{\n)\s*dlg\.setCancelable\(false\);\n/$1/' || fails=$((fails+1))
mut "X9 the Report this link opens nothing"         pa     "L5 the Report this link line" \
  's/SheetDialog\.confirmHeld\(this, m, a, m\.lines\.isEmpty\(\) \? null : key -> showReportIssue\(\)\);/SheetDialog.confirmHeld(this, m, a, null);/' || fails=$((fails+1))
mut "X10 the 4-arg confirmHeld not held"            dialog "L4 the 4-arg confirmHeld" \
  's/return confirmSheet\(ctx, m, actions, onLink, true\);/return confirmSheet(ctx, m, actions, onLink, false);/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 10 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
