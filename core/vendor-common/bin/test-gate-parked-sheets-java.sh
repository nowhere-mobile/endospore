#!/usr/bin/env bash
# test-gate-parked-sheets-java.sh [--mutate] -- the gate's sheets over a parked or an open session, run under javac
# (NWP-20261206-07; docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to one
# bottom-sheet design", slice 3, gate part 1).
#
# WHY THIS IS COMMITTED. Three gate dialogs are sheets now: Create refused over a locked session (routine, Resume it),
# Create refused over an open session (warning, Restart) and Install over a parked session (warning, Install). Their
# words are decided (Q123 2026-10-20, h46 #5 2026-10-28), so the sheets only split them. PopupSheet, GateParkedSheets and
# the word helpers lifted from ChooserActivity.java are compiled with core/chooser/tests/gate-parked-sheets and run.
# Source pins on ChooserActivity.java (comments stripped) hold what the cases cannot:
#   S1 showCreateOverColdLock, showCreateOverLiveSession and confirmInstallOverParked hold no AlertDialog.Builder;
#   S2 showCreateOverColdLock returns on resumeMode before the sheet, and Resume it tests !resumeMode again;
#   S3 showCreateOverLiveSession: slot 0 (Not now) is null, slot 1 (Restart) calls rebootForCreateOverLive;
#   S4 confirmInstallOverParked: the isFinishing guard comes first, slot 0 (Not now) is null, slot 1 (Install) is go.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-gate-parked-sheets-java.sh            # the cases + the pins
#   bash test-gate-parked-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
CA="$SRC/ChooserActivity.java"
GPS="$SRC/GateParkedSheets.java"
POPUP="$SRC/PopupSheet.java"
CASES="$root/core/chooser/tests/gate-parked-sheets/GateParkedSheetsCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
METHODS="parseColdLock createOverColdLockTitle createOverColdLockText createLiveText installOverParkedTitle installOverParkedContext installOverParkedLines installOverParkedText"

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
for f in "$CA" "$POPUP" "$CASES"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <ChooserActivity.java> <GateParkedSheets.java> -> 0 pass, 1 a case failed or a class or helper is missing (the
# only codes that convict a mutant), 3 it did not compile.
suite() {
  local ca="$1" gps="$2" d out rc m
  [ -f "$gps" ] || { echo "  FAIL  GateParkedSheets.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  {
    echo "package com.nowhere.chooser;"
    echo "final class Lifted {"
    for m in $METHODS; do
      # from the method's signature line to the brace that closes it (as core/chooser/tests/install-parked/run.sh)
      awk -v m="$m" '
        !on && index($0, "private static ") && index($0, " " m "(") { on=1; depth=0 }
        on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
      ' "$ca" | sed 's/private static/static/'
    done
    echo "}"
  } > "$d/src/com/nowhere/chooser/Lifted.java"
  for m in $METHODS; do
    grep -q " $m(" "$d/src/com/nowhere/chooser/Lifted.java" \
      || { echo "  FAIL  the lift missed $m" >&2; rm -rf "$d"; return 1; }
  done
  cp "$POPUP" "$d/src/com/nowhere/chooser/PopupSheet.java"
  cp "$gps" "$d/src/com/nowhere/chooser/GateParkedSheets.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/GateParkedSheetsCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.GateParkedSheetsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  GateParkedSheetsCases" >&2
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
# before <text> <first> <second> -> 0 when both occur and the first occurs before the second.
before() {
  local a b
  has "$1" "$2" && has "$1" "$3" || return 1
  a="${1%%"$2"*}"; b="${1%%"$3"*}"
  [ "${#a}" -lt "${#b}" ]
}

# pins <ChooserActivity.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local caf bad=0 b m cold live inst
  caf=$(mktemp -p "$W") || return 1
  code "$1" > "$caf"
  for m in showCreateOverColdLock showCreateOverLiveSession confirmInstallOverParked; do
    b=$(meth "$caf" "$m")
    [ -n "$b" ] || { echo "  FAIL  S1 $m( not found" >&2; bad=1; continue; }
    has "$b" "AlertDialog.Builder" && { echo "  FAIL  S1 $m holds an AlertDialog.Builder" >&2; bad=1; }
  done

  cold=$(meth "$caf" showCreateOverColdLock)
  before "$cold" "if (isFinishing() || resumeMode) return;" "SheetDialog.confirm(this," \
    || { echo "  FAIL  S2 showCreateOverColdLock does not return on resumeMode before the sheet" >&2; bad=1; }
  has "$cold" "if (p != null && !resumeMode) enterResumeMode(" \
    || { echo "  FAIL  S2 showCreateOverColdLock's Resume it does not test !resumeMode" >&2; bad=1; }

  live=$(meth "$caf" showCreateOverLiveSession)
  has "$live" "SheetDialog.confirm(this, GateParkedSheets.createLive(createLiveText())," \
    && has "$live" "new Runnable[] { null, () -> rebootForCreateOverLive() }" \
    || { echo "  FAIL  S3 showCreateOverLiveSession: slot 0 is not null or slot 1 does not reboot" >&2; bad=1; }

  inst=$(meth "$caf" confirmInstallOverParked)
  before "$inst" "if (isFinishing() || isDestroyed()) return;" "SheetDialog.confirm(this, GateParkedSheets.installOverParked(" \
    && has "$inst" "new Runnable[] { null, go }" \
    || { echo "  FAIL  S4 confirmInstallOverParked: the guard is not first, slot 0 is not null or slot 1 is not go" >&2; bad=1; }
  rm -f "$caf"
  [ "$bad" -eq 0 ]
}

# check_all <ChooserActivity.java> <GateParkedSheets.java> -> 0 when the cases and every pin pass, 1 when one fails, 3
# when the classes did not compile.
check_all() {
  local rc
  suite "$1" "$2"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$1" || rc=1
  return "$rc"
}

echo "== GateParkedSheets, the lifted ChooserActivity helpers, the three methods"
check_all "$CA" "$GPS"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases + pins S1-S4"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
MUT_DIR=
mut() { # mut <label> <ca|gps> <the assertion that must convict it> <perl-expr>
  local d c rc orig out
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in gps) orig="$GPS" ;; *) orig="$CA" ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    gps) out=$(check_all "$CA" "$c" 2>&1); rc=$? ;;
    *) out=$(check_all "$c" "$GPS" 2>&1); rc=$? ;;
  esac
  MUT_DIR="$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    3) echo "  BROKEN    $1 -- it did not compile"; return 1 ;;
  esac
  has "$out" "FAIL $3" || has "$out" "FAIL  $3" || {
    echo "  BROKEN    $1 -- it failed, but not by '$3':"; printf '%s\n' "$out" | grep FAIL | sed 's/^/            /'; return 1
  }
  echo "  convicted $1 -- FAIL $3"
}
fails=0
mut "G1 the split drops the last paragraph" gps "coldLock named: join equals createOverColdLockText" \
  's/i < parts\.length; i\+\+/i < parts.length - 1; i++/' || fails=$((fails + 1))
mut "G2 named shows Got it" gps "coldLock named: Resume it green first" \
  's/new PopupSheet\.Button\(RESUME_IT, PopupSheet\.Style\.GREEN_FILLED\)/new PopupSheet.Button(PopupSheet.GOT_IT, PopupSheet.Style.GREEN_FILLED)/' \
  || fails=$((fails + 1))
mut "G3 Restart is GREEN_FILLED" gps "createLive: Restart RED_OUTLINED" \
  's/new PopupSheet\.Button\(RESTART, PopupSheet\.Style\.RED_OUTLINED\)/new PopupSheet.Button(RESTART, PopupSheet.Style.GREEN_FILLED)/' \
  || fails=$((fails + 1))
mut "G4 createLive's actions swapped" ca "S3 showCreateOverLiveSession" \
  's/new Runnable\[\] \{ null, \(\) -> rebootForCreateOverLive\(\) \}/new Runnable[] { () -> rebootForCreateOverLive(), null }/' \
  || fails=$((fails + 1))
mut "G5 go in slot 0" ca "S4 confirmInstallOverParked" \
  's/new Runnable\[\] \{ null, go \}/new Runnable[] { go, null }/' || fails=$((fails + 1))
mut "G6 the credit line is dropped" ca "install named credit: two lines" \
  's/\n[ \t]*if \(creditLost\) lines\.add\([^\n]*\n/\n/' || fails=$((fails + 1))
mut "G7 the resumeMode guard is removed" ca "S2 showCreateOverColdLock does not return on resumeMode" \
  's/(void showCreateOverColdLock\(.*?)if \(isFinishing\(\) \|\| resumeMode\) return;/${1}if (isFinishing()) return;/s' \
  || fails=$((fails + 1))
G8='s/(void showCreateOverLiveSession\(\) \{.*?if \(isFinishing\(\)\) return;\n)/${1}            new android.app.AlertDialog.Builder(this).setNegativeButton("Cancel", null).show();\n/s'
if mut "G8 a Cancel builder is put back" ca "S1 showCreateOverLiveSession holds an AlertDialog.Builder" "$G8"; then
  # The lint must catch it too: test-popup-rules.sh on a copy of the source with the mutant in place says NEW.
  lint=$(mktemp -d -p "$W")
  cp "$SRC"/*.java "$lint/"
  cp "$MUT_DIR/ChooserActivity.java" "$lint/ChooserActivity.java"
  out=$(SRC_DIR="$lint" bash "$root/core/chooser/test-popup-rules.sh" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && has "$out" "NEW: ChooserActivity.java	showCreateOverLiveSession	R1	Cancel"; then
    echo "  convicted G8 in test-popup-rules.sh -- NEW: ChooserActivity.java showCreateOverLiveSession R1 Cancel"
  else
    echo "  SURVIVED  G8 in test-popup-rules.sh (rc=$rc)"; fails=$((fails + 1))
  fi
else
  fails=$((fails + 1))
fi
[ "$fails" -eq 0 ] && echo "== all 8 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
