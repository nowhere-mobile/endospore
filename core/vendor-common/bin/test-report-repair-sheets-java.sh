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
#   S1 showReportIssue and renderReportResult hold no AlertDialog.Builder;
#   S2 the REPORT-ISSUE send with reportRequestJson(noteText, false) sits in action slot 0 of the sendReport sheet,
#      and slot 1 is null;
#   S3 renderReportResult calls appendTicket before the reportSent sheet and passes showReportIssue() in slot 0.
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
  local paf bad=0 b m rest open send call ticket
  paf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"

  for m in showReportIssue renderReportResult; do
    b=$(meth "$paf" "    private void $m(")
    [ -n "$b" ] || { echo "  FAIL  S1 $m( not found" >&2; bad=1; continue; }
    has "$b" "AlertDialog.Builder" && { echo "  FAIL  S1 $m holds an AlertDialog.Builder" >&2; bad=1; }
  done

  b=$(meth "$paf" "    private void showReportIssue(")
  open='SheetDialog.confirm(this, ReportRepairSheets.sendReport(), new Runnable[] { () -> {'
  send='sendDaemon("REPORT-ISSUE\n" + reportRequestJson(noteText, false) + "\n")'
  if ! has "$b" "$open"; then
    echo "  FAIL  S2 showReportIssue does not open the sendReport sheet with an action in slot 0" >&2; bad=1
  else
    rest=${b#*"$open"}
    if ! has "$rest" "}, null }, null)"; then
      echo "  FAIL  S2 showReportIssue's sendReport actions do not end with a null slot 1" >&2; bad=1
    elif ! has "${rest%%"}, null }, null)"*}" "$send"; then
      echo "  FAIL  S2 showReportIssue's REPORT-ISSUE send is not in slot 0 of the sendReport sheet" >&2; bad=1
    fi
  fi

  b=$(meth "$paf" "    private void renderReportResult(")
  ticket='appendTicket(ticket, noteText);'
  call='SheetDialog.confirm(this, ReportRepairSheets.reportSent(ticket), new Runnable[] { () -> showReportIssue() }, null);'
  if ! has "$b" "$call"; then
    echo "  FAIL  S3 renderReportResult does not open the reportSent sheet with showReportIssue() in slot 0" >&2; bad=1
  elif ! has "${b%%"$call"*}" "$ticket"; then
    echo "  FAIL  S3 renderReportResult does not call appendTicket before the reportSent sheet" >&2; bad=1
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
mut "R6 the send moved to slot 1"                pa     "S2 showReportIssue"   's/(ReportRepairSheets\.sendReport\(\),\s+new Runnable\[\] \{ )(\(\) -> \{.*?)\}, null \}, null\)\)/${1}null, ${2}} }, null))/s' || fails=$((fails+1))
mut "R7 a .setNegativeButton(\"Cancel\" builder put back" pa "S1 showReportIssue" 's/(\n    private void showReportIssue\(\) \{\n)/${1}        new android.app.AlertDialog.Builder(this).setNegativeButton("Cancel", null).show();\n/' rules || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 7 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
