#!/usr/bin/env bash
# test-notice-sheets-java.sh [--mutate] -- the save ceremony's EXISTS and SPLIT notices and the sign-out and restart
# failure notice (ProfileActivity.showNotice) as warning sheets with one "Got it", run under javac (NWP-20261206-08;
# docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to one bottom-sheet design",
# slice 3).
#
# WHY THIS IS COMMITTED. Design A says a failure the user can only acknowledge takes the warning tone with one green
# "Got it" (Chester, 2026-11-15: "3301 amber"), and a button never says OK. NoticeSheets is pure java.util and is compiled here with PopupSheet and its cases. Source pins (comments
# stripped) hold what the cases cannot:
#   S1 showNotice and handlePromoteReply hold no AlertDialog.Builder;
#   S2 showNotice shows NoticeSheets.notDone(msg) and calls setCancelable(false) on the returned dialog, so the notice
#      stays until "Got it", as the OK dialog did;
#   S3 the EXISTS arm shows NoticeSheets.saveExists and its dismiss listener reopens the ceremony (showSaveCeremony());
#      the SPLIT arm shows NoticeSheets.saveSplit and its dismiss listener returns to the hub (showConfirm());
#   S4 SheetDialog.confirm returns confirmSheet(ctx, m, actions, onLink, false), and confirmSheet's last statement is
#      `return dlg;` (the callers above need the dialog it shows; NWP-20261206-17 put the body in confirmSheet).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-notice-sheets-java.sh            # the cases + the pins
#   bash test-notice-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
NOTICE="$SRC/NoticeSheets.java"
DIALOG="$SRC/SheetDialog.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/notice-sheets/NoticeSheetsCases.java"
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
for f in "$CASES" "$POPUP" "$PA" "$DIALOG"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <PopupSheet.java> <NoticeSheets.java> -> 0 pass, 1 a case failed or a class is missing (the only codes that
# convict a mutant), 3 it did not compile.
suite() {
  local popup="$1" notice="$2" d out rc
  [ -f "$popup" ] || { echo "  FAIL  PopupSheet.java does not exist" >&2; return 1; }
  [ -f "$notice" ] || { echo "  FAIL  NoticeSheets.java does not exist (the class is missing)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$popup" "$d/src/com/nowhere/chooser/PopupSheet.java"
  cp "$notice" "$d/src/com/nowhere/chooser/NoticeSheets.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/NoticeSheetsCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.NoticeSheetsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  NoticeSheetsCases" >&2
  return 1
}

# code <file> -> the file without comment lines and trailing // comments.
code() { sed -E -e '/^[[:space:]]*(\/\/|\*|\/\*)/d' -e 's/[[:space:]]+\/\/[[:space:]].*$//' "$1"; }
# meth <code file> <name> -> the method's lines, from its 4-space declaration to its 4-space closing brace.
meth() {
  awk -v n="$2" '$0 ~ ("^    [a-zA-Z].* " n "\\(") && !f { f = 1 } f { print } f && /^    }$/ { exit }' "$1"
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

# pins <ProfileActivity.java> <SheetDialog.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local paf dlf bad=0 b m hp last
  [ -f "$2" ] || { echo "  FAIL  S4 SheetDialog.java does not exist" >&2; return 1; }
  paf=$(mktemp -p "$W") || return 1
  dlf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"
  code "$2" > "$dlf"

  for m in showNotice handlePromoteReply; do
    b=$(meth "$paf" "$m")
    [ -n "$b" ] || { echo "  FAIL  S1 $m( not found" >&2; bad=1; continue; }
    has "$b" "AlertDialog.Builder" && { echo "  FAIL  S1 $m holds an AlertDialog.Builder" >&2; bad=1; }
  done

  b=$(meth "$paf" showNotice)
  has "$b" "android.app.Dialog d = SheetDialog.confirm(this, NoticeSheets.notDone(msg), null, null);" \
    || { echo "  FAIL  S2 showNotice does not show NoticeSheets.notDone(msg) through SheetDialog.confirm" >&2; bad=1; }
  has "$b" "if (d != null) d.setCancelable(false);" \
    || { echo "  FAIL  S2 showNotice does not call setCancelable(false) on the returned dialog" >&2; bad=1; }

  hp=$(meth "$paf" handlePromoteReply)
  b=$(arm "$hp" EXISTS)
  has "$b" "SheetDialog.confirm(this, NoticeSheets.saveExists(PromoteCopy.text(r)), null, null);" \
    || { echo "  FAIL  S3 the EXISTS arm does not show NoticeSheets.saveExists(PromoteCopy.text(r))" >&2; bad=1; }
  has "$b" "if (d != null) d.setOnDismissListener(x -> showSaveCeremony());" \
    || { echo "  FAIL  S3 the EXISTS arm's dismiss listener does not reopen the ceremony (showSaveCeremony())" >&2; bad=1; }
  has "$b" "showConfirm()" && { echo "  FAIL  S3 the EXISTS arm calls showConfirm()" >&2; bad=1; }
  b=$(arm "$hp" SPLIT)
  has "$b" "SheetDialog.confirm(this, NoticeSheets.saveSplit(PromoteCopy.text(r)), null, null);" \
    || { echo "  FAIL  S3 the SPLIT arm does not show NoticeSheets.saveSplit(PromoteCopy.text(r))" >&2; bad=1; }
  has "$b" "if (d != null) d.setOnDismissListener(x -> showConfirm());" \
    || { echo "  FAIL  S3 the SPLIT arm's dismiss listener does not return to the hub (showConfirm())" >&2; bad=1; }

  b=$(meth "$dlf" confirm)
  [ -n "$b" ] || { echo "  FAIL  S4 SheetDialog.confirm( not found" >&2; bad=1; }
  has "$b" "return confirmSheet(ctx, m, actions, onLink, false);" \
    || { echo "  FAIL  S4 SheetDialog.confirm does not return confirmSheet(ctx, m, actions, onLink, false)" >&2; bad=1; }
  b=$(meth "$dlf" confirmSheet)
  [ -n "$b" ] || { echo "  FAIL  S4 SheetDialog.confirmSheet( not found" >&2; bad=1; }
  last=$(printf '%s\n' "$b" | sed -e '$d' | awk 'NF { l = $0 } END { sub(/^[[:space:]]+/, "", l); print l }')
  [ "$last" = "return dlg;" ] \
    || { echo "  FAIL  S4 SheetDialog.confirmSheet's last statement is '$last', not 'return dlg;'" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# check_all <PopupSheet.java> <NoticeSheets.java> <ProfileActivity.java> <SheetDialog.java> -> 0 when the cases and
# every pin pass, 1 when one fails, 3 when the classes did not compile.
check_all() {
  local rc
  suite "$1" "$2"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$3" "$4" || rc=1
  return "$rc"
}

echo "== NoticeSheets, showNotice, handlePromoteReply, SheetDialog.confirm"
check_all "$POPUP" "$NOTICE" "$PA" "$DIALOG"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases + pins S1-S4"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <notice|pa|dialog> <the assertion that must convict it> <perl-expr> [<a second text the output must hold>]
  local d c rc orig out
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in notice) orig="$NOTICE" ;; dialog) orig="$DIALOG" ;; *) orig="$PA" ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    notice) out=$(check_all "$POPUP" "$c" "$PA" "$DIALOG" 2>&1); rc=$? ;;
    dialog) out=$(check_all "$POPUP" "$NOTICE" "$PA" "$c" 2>&1); rc=$? ;;
    *) out=$(check_all "$POPUP" "$NOTICE" "$c" "$DIALOG" 2>&1); rc=$? ;;
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
  if [ -n "${5:-}" ]; then
    case "$out" in
      *"$5"*) ;;
      *) echo "  WRONG     $1 -- it failed on '$3', but the output does not hold '$5'"; return 1 ;;
    esac
  fi
  echo "  convicted $1 -- FAIL  $3"
  return 0
}

# rules_new <perl-expr on ProfileActivity.java> <expected NEW line> -> 0 when test-popup-rules.sh, run on a copy of the
# chooser sources with the mutation, fails and reports the NEW line.
rules_new() {
  local d out rc
  command -v python3 >/dev/null 2>&1 || { echo "  ERROR     test-popup-rules.sh needs python3, and there is none"; return 1; }
  d=$(mktemp -d -p "$W") || return 1
  cp -R "$SRC" "$d/src" || { rm -rf "$d"; return 1; }
  perl -0pi -e "$1" "$d/src/ProfileActivity.java" || { echo "  ERROR     perl failed on the rules mutation"; rm -rf "$d"; return 1; }
  if cmp -s "$PA" "$d/src/ProfileActivity.java"; then echo "  INERT     the rules mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(TMPDIR="$W" SRC_DIR="$d/src" bash "$RULES" 2>&1); rc=$?
  rm -rf "$d"
  [ "$rc" -ne 0 ] || { echo "  SURVIVED  test-popup-rules.sh passed the mutant"; return 1; }
  case "$out" in
    *"$2"*) echo "  convicted test-popup-rules.sh -- $2"; return 0 ;;
  esac
  echo "  WRONG     test-popup-rules.sh failed, but not with '$2':"; printf '%s\n' "$out" | tail -5
  return 1
}

T=$'\t'
BUILDER='    private void showNotice(String msg) {\n        new android.app.AlertDialog.Builder(this).setMessage(msg).setPositiveButton("OK", null).show();\n'
fails=0
mut "M1 a title emptied"                         notice "saveExists title"     's/SAVE_EXISTS_TITLE = "Not saved yet";/SAVE_EXISTS_TITLE = "";/' || fails=$((fails+1))
mut "M2 Got it made OUTLINED"                    notice "notDone one Got it"   's/PopupSheet\.GOT_IT, PopupSheet\.Style\.GREEN_FILLED/PopupSheet.GOT_IT, PopupSheet.Style.OUTLINED/' || fails=$((fails+1))
mut "M3 notDone's tone made ROUTINE"             notice "notDone tone"         's/(notDone\(String msg\) \{ return gotIt\(PopupSheet\.Tone\.)WARNING/${1}ROUTINE/' || fails=$((fails+1))
mut "M8 saveSplit's tone made DESTRUCTIVE"       notice "saveSplit violations" 's/(saveSplit\(String msg\) \{ return gotIt\(PopupSheet\.Tone\.)WARNING/${1}DESTRUCTIVE/' \
  'a lone "Got it" is only for the routine or the warning tone' || fails=$((fails+1))
mut "M4 setCancelable(false) removed"            pa     "S2 showNotice"        's/\n        if \(d != null\) d\.setCancelable\(false\);//' || fails=$((fails+1))
mut "M5 the EXISTS listener calls showConfirm()" pa     "S3 the EXISTS arm"    's/d\.setOnDismissListener\(x -> showSaveCeremony\(\)\);/d.setOnDismissListener(x -> showConfirm());/' || fails=$((fails+1))
# M6: the chooser would not compile either (confirmSheet returns Dialog, so a missing return is a javac error); the
# pins read text, so this suite still names S4.
mut "M6 return dlg; removed from confirmSheet"   dialog "S4 SheetDialog.confirmSheet's last" 's/(        show\(dlg, panel, held\);\n)        return dlg;\n/$1/' || fails=$((fails+1))
mut "M7 an OK builder put back in showNotice"    pa     "S1 showNotice"        "s/    private void showNotice\\(String msg\\) \\{\\n/$BUILDER/" || fails=$((fails+1))
rules_new "s/    private void showNotice\\(String msg\\) \\{\\n/$BUILDER/" \
  "NEW: ProfileActivity.java${T}showNotice${T}R1${T}OK (baseline 0, found 1)" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 8 mutations convicted (M7 by test-popup-rules.sh too)" \
  || { echo "== $fails mutation(s) not convicted"; exit 1; }
