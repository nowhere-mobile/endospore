#!/usr/bin/env bash
# test-report-repair-sheets-java.sh [--mutate] -- Report an issue's Send report and Report sent, and Storage's Repair
# stored credit, on the shared bottom sheet, run under javac (NWP-20261206-06; docs/backlog.md, "Popups are plain
# dialogs: the choice pickers and the confirmations move to one bottom-sheet design", slice 3, Report an issue and
# Storage, part 1 of 2).
#
# WHY THIS IS COMMITTED. Send report and Report sent are routine: the green button sends the report, or closes the
# notice and re-opens Report an issue. Repair stored credit is a warning: the green Not now is the safe way out and the
# red-outlined Repair runs the CONFIRM. ReportRepairSheets is pure java.util and is compiled here with PopupSheet,
# WalletRepairCopy and its cases. Source pins over ProfileActivity (comments stripped) hold what the cases cannot:
#   S1 showReportIssue, sendReportOn and renderReportResult hold no AlertDialog.Builder;
#   S2 (NWP-20261208-28) Send report opens a live sheet whose slot 0 is inPlace: it reads the note and calls
#      sendReportOn, which changes the sheet to sending() before the REPORT-ISSUE send thread; slot 1 is null;
#   S3 renderReportResult calls appendTicket before any isFinishing() check and before the reportSent change, which
#      passes showReportIssue() in slot 0; a finished Activity gets no sheet change;
#   S4 Send shows no "Sending…" status line, and sendReportOn and renderReportResult hold no StatusLine.busy( or
#      StatusLine.error(;
#   S5 a failure changes the sheet to failed(reply), and its Try again (inPlace) sends the same noteText again.
# The repair sheet's wiring in showStorage is pinned by core/chooser/tests/wallet-repair/run.sh (U10 there).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-report-repair-sheets-java.sh            # the cases + the pins
#   bash test-report-repair-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
WALLET="$SRC/WalletRepairCopy.java"
SHEETS="$SRC/ReportRepairSheets.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/report-repair-sheets/ReportRepairSheetsCases.java"
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
for f in "$CASES" "$PA" "$POPUP" "$WALLET"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <ReportRepairSheets.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that convict a
# mutant), 3 it did not compile.
suite() {
  local sheets="$1" d out rc
  [ -f "$sheets" ] || { echo "  FAIL  ReportRepairSheets.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$POPUP" "$d/src/com/nowhere/chooser/PopupSheet.java"
  cp "$WALLET" "$d/src/com/nowhere/chooser/WalletRepairCopy.java"
  cp "$sheets" "$d/src/com/nowhere/chooser/ReportRepairSheets.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/ReportRepairSheetsCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.ReportRepairSheetsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  ReportRepairSheetsCases" >&2
  return 1
}

# code <file> -> the file without comment lines and trailing // comments.
code() { sed -E -e '/^[[:space:]]*(\/\/|\*|\/\*)/d' -e 's/[[:space:]]+\/\/[[:space:]].*$//' "$1"; }
# meth <code file> <declaration> -> the method's lines joined into one, spaces squeezed, from the line that starts with
# its full 4-space declaration (so a call site never matches) to its 4-space closing brace; a wrapped call still matches.
meth() {
  D="$2" awk '!f && index($0, ENVIRON["D"]) == 1 { f = 1 } f { print } f && /^    }$/ { exit }' "$1" \
    | tr '\n' ' ' | tr -s ' '
}
# has <text> <fixed string> -> 0 when the text holds it.
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# pins <ProfileActivity.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local paf bad=0 b m rest open send call ticket fin
  paf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"

  for m in showReportIssue sendReportOn renderReportResult; do
    b=$(meth "$paf" "    private void $m(")
    [ -n "$b" ] || { echo "  FAIL  S1 $m( not found" >&2; bad=1; continue; }
    has "$b" "AlertDialog.Builder" && { echo "  FAIL  S1 $m holds an AlertDialog.Builder" >&2; bad=1; }
  done

  b=$(meth "$paf" "    private void showReportIssue(")
  open='SheetDialog.confirmLive(this, ReportRepairSheets.sendReport(), new Runnable[] { SheetDialog.inPlace(() -> {'
  send='sendDaemon("REPORT-ISSUE\n" + reportRequestJson(noteText, false) + "\n")'
  if ! has "$b" "$open"; then
    echo "  FAIL  S2 showReportIssue does not open a live sendReport sheet with an inPlace action in slot 0" >&2; bad=1
  else
    rest=${b#*"$open"}
    if ! has "$rest" "}), null });"; then
      echo "  FAIL  S2 showReportIssue's sendReport actions do not end with a null slot 1" >&2; bad=1
    else
      rest=${rest%%"}), null });"*}
      { has "$rest" "final String noteText = note.getText().toString();" && has "$rest" "sendReportOn(sheet[0], statusTv, noteText);"; } \
        || { echo "  FAIL  S2 showReportIssue's slot 0 does not read the note and call sendReportOn" >&2; bad=1; }
    fi
  fi
  has "$b" '"Sending…"' && { echo "  FAIL  S4 showReportIssue shows a Sending… status line" >&2; bad=1; }

  b=$(meth "$paf" "    private void sendReportOn(")
  if ! has "$b" "sheet.progress(ReportRepairSheets.sending()); new Thread(() -> {"; then
    echo "  FAIL  S2 sendReportOn does not change the sheet to sending() before the send thread" >&2; bad=1
  elif ! has "${b#*"new Thread(() -> {"}" "$send"; then
    echo "  FAIL  S2 sendReportOn's thread does not send REPORT-ISSUE with reportRequestJson(noteText, false)" >&2; bad=1
  fi
  has "$b" "renderReportResult(reply, sheet, statusTv, noteText)" \
    || { echo "  FAIL  S2 sendReportOn does not pass the reply to renderReportResult with the sheet" >&2; bad=1; }

  b=$(meth "$paf" "    private void renderReportResult(")
  ticket='appendTicket(ticket, noteText);'
  fin='if (isFinishing() || isDestroyed()) return;'
  call='sheet.confirm(ReportRepairSheets.reportSent(ticket), new Runnable[] { () -> showReportIssue() });'
  if ! has "$b" "$call"; then
    echo "  FAIL  S3 renderReportResult does not change the sheet to reportSent with showReportIssue() in slot 0" >&2; bad=1
  elif ! has "${b%%"$call"*}" "$ticket"; then
    echo "  FAIL  S3 renderReportResult does not call appendTicket before the reportSent change" >&2; bad=1
  elif ! has "${b%%"$fin"*}" "$ticket"; then
    echo "  FAIL  S3 renderReportResult does not call appendTicket before its isFinishing() check" >&2; bad=1
  fi
  for m in sendReportOn renderReportResult; do
    b=$(meth "$paf" "    private void $m(")
    { has "$b" "StatusLine.busy(" || has "$b" "StatusLine.error("; } \
      && { echo "  FAIL  S4 $m holds StatusLine.busy( or StatusLine.error(" >&2; bad=1; }
  done

  b=$(meth "$paf" "    private void renderReportResult(")
  call='sheet.confirm(ReportRepairSheets.failed(reply),'
  if ! has "$b" "$call"; then
    echo "  FAIL  S5 renderReportResult does not change the sheet to failed(reply)" >&2; bad=1
  else
    rest=${b#*"$ticket"}
    { has "${rest%%"sheet.confirm(ReportRepairSheets.reportSent("*}" "$fin" && rest=${rest#*"return; }"} \
        && has "${rest%%"$call"*}" "$fin"; } \
      || { echo "  FAIL  S3 renderReportResult changes the sheet of a finished Activity" >&2; bad=1; }
    has "${b#*"$call"}" "SheetDialog.inPlace(() -> sendReportOn(sheet, statusTv, noteText))" \
      || { echo "  FAIL  S5 the failure sheet's Try again does not send the same noteText in place" >&2; bad=1; }
  fi
  [ "$bad" -eq 0 ]
}

# check_all <ReportRepairSheets.java> <ProfileActivity.java> -> 0 when the cases and every pin pass, 1 when one fails,
# 3 when the classes did not compile.
check_all() {
  local rc
  suite "$1"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$2" || rc=1
  return "$rc"
}

echo "== ReportRepairSheets, ProfileActivity's Report an issue sheets"
check_all "$SHEETS" "$PA"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases + pins S1-S5"
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
      *"NEW: ProfileActivity.java	showReportIssue	R1	Cancel"*) ;;
      *) echo "  SURVIVED  $1 -- test-popup-rules.sh does not report it as NEW (rc=$rrc)"; rm -rf "$d"; return 1 ;;
    esac
    [ "$rrc" -ne 0 ] || { echo "  SURVIVED  $1 -- test-popup-rules.sh reports NEW but passes"; rm -rf "$d"; return 1; }
    echo "  convicted $1 -- test-popup-rules.sh reports NEW"
  fi
  rm -rf "$d"
  return 0
}
fails=0
mut "R1 Send made OUTLINED"                      sheets "sendReport buttons"   's/new PopupSheet\.Button\(SEND, PopupSheet\.Style\.GREEN_FILLED\)/new PopupSheet.Button(SEND, PopupSheet.Style.OUTLINED)/' || fails=$((fails+1))
mut "R2 the ticket left out of reportSent"       sheets "reportSent context"   's/SENT_CONTEXT_START \+ ticket \+ SENT_CONTEXT_END/SENT_CONTEXT_START + SENT_CONTEXT_END/' || fails=$((fails+1))
mut "R3 Repair made GREEN_FILLED"                sheets "repairCredit buttons" 's/new PopupSheet\.Button\(WalletRepairCopy\.POSITIVE, PopupSheet\.Style\.RED_OUTLINED\)/new PopupSheet.Button(WalletRepairCopy.POSITIVE, PopupSheet.Style.GREEN_FILLED)/' || fails=$((fails+1))
mut "R4 repairCredit's buttons swapped"          sheets "repairCredit buttons" 's/(new PopupSheet\.Button\(WalletRepairCopy\.NEGATIVE, PopupSheet\.Style\.GREEN_FILLED\)),(\s+)(new PopupSheet\.Button\(WalletRepairCopy\.POSITIVE, PopupSheet\.Style\.RED_OUTLINED\))/$3,$2$1/' || fails=$((fails+1))
mut "R5 a MESSAGE sentence dropped from the lines" sheets "repairCredit message" 's/,\s+new PopupSheet\.Line\(REPAIR_LINE_2, null\)//' || fails=$((fails+1))
mut "R6 the send moved to slot 1"                pa     "S2 showReportIssue"   's/(ReportRepairSheets\.sendReport\(\), new Runnable\[\] \{ )(SheetDialog\.inPlace\(\(\) -> \{.*?\}\)), null \}\);/${1}null, ${2} });/s' || fails=$((fails+1))
mut "R7 a .setNegativeButton(\"Cancel\" builder put back" pa "S1 showReportIssue" 's/(\n    private void showReportIssue\(\) \{\n)/${1}        new android.app.AlertDialog.Builder(this).setNegativeButton("Cancel", null).show();\n/' rules || fails=$((fails+1))
mut "R8 ERR-NET mapped to the notice"            sheets "failed ERR-NET"       's/return !"ERR-NOGW"\.equals\(reply\)/return !"ERR-NET".equals(reply) && !"ERR-NOGW".equals(reply)/' || fails=$((fails+1))
mut "R9 ERR-TOOBIG retryable"                    sheets "failed ERR-TOOBIG"    's/ && !"ERR-TOOBIG"\.equals\(reply\)//' || fails=$((fails+1))
mut "R10 a sentence's word changed"              sheets "failureSentence ERR-DISABLED" 's/accepting reports/taking reports/' || fails=$((fails+1))
mut "R11 StatusLine.busy back in Send"           pa     "S4"                   's/(\n(\s*)final String noteText = note\.getText\(\)\.toString\(\);)/\n${2}StatusLine.busy(statusTv, "Sending…");$1/' || fails=$((fails+1))
mut "R12 Try again sends an empty note"          pa     "S5"                   's/inPlace\(\(\) -> sendReportOn\(sheet, statusTv, noteText\)\)/inPlace(() -> sendReportOn(sheet, statusTv, ""))/' || fails=$((fails+1))
mut "R13 appendTicket after the sheet"           pa     "S3"                   's/(\n[ \t]*appendTicket\(ticket, noteText\);[^\n]*)(.*?\n[^\n]*sheet\.confirm\(ReportRepairSheets\.reportSent\(ticket\)[^\n]*)/$2$1/s' || fails=$((fails+1))
mut "R14 a failure changes a finished Activity's sheet" pa "S3"                 's/(\n\s*return;\n\s*\}\n)\s*if \(isFinishing\(\) \|\| isDestroyed\(\)\) return;\n/$1/' || fails=$((fails+1))
mut "R15 the sending sheet dropped"              pa     "S2 sendReportOn"      's/\n\s*sheet\.progress\(ReportRepairSheets\.sending\(\)\);//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 15 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
