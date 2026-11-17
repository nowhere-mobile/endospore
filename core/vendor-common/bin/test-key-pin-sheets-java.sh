#!/usr/bin/env bash
# test-key-pin-sheets-java.sh [--mutate] -- Profile > Security's three confirmations (Security keys' Remove, its
# "Confirm with a key" fresh tap, Session PIN's Remove PIN) on the shared bottom sheet, run under javac
# (NWP-20261206-16; docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to one
# bottom-sheet design", slice 3).
#
# WHY THIS IS COMMITTED. Design A's rules hold only if a test holds them: removing a key and removing the PIN are
# warnings whose green button is the safe way out ("Keep it") and whose risky "Remove" is red-outlined; the key's fresh
# tap is routine, a green "USB-C key" and an outlined "Not now" (no "Cancel"). Every word is the one the plain dialogs
# showed before this slice: the cases hold today's messages as literals and check that context and lines, joined by
# spaces, still equal them. KeyPinSheets and PopupSheet are pure java.util and are compiled here with the cases.
# Source pins (ProfileActivity.java, comments stripped, each method flattened to one line) hold what the cases cannot:
#   S1 confirmRemoveKey and showSessionPin hold no AlertDialog.Builder (showWorking, F03's, is a call, not a builder);
#   S2 confirmRemoveKey shows KeyPinSheets.removeKey(label, last) with nothing on button 0 and the confirmWithKey(last)
#      sheet on button 1, and REMOVE-FIDO2-KEY is sent only from that second sheet's button 0 -- never before the
#      green "USB-C key" is touched;
#   S3 showSessionPin's Remove click shows KeyPinSheets.removePin() with nothing on button 0 and the SET-PIN clear
#      thread on button 1 -- the green "Keep it" never clears the PIN.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-key-pin-sheets-java.sh            # the cases + the pins
#   bash test-key-pin-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
KPS="$SRC/KeyPinSheets.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/key-pin-sheets/KeyPinSheetsCases.java"
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
for f in "$CASES" "$PA" "$RULES"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <PopupSheet.java> <KeyPinSheets.java> -> 0 pass, 1 a case failed or a class is missing (the only codes that
# convict a mutant), 3 it did not compile.
suite() {
  local popup="$1" kps="$2" d out rc
  [ -f "$popup" ] || { echo "  FAIL  PopupSheet.java does not exist" >&2; return 1; }
  [ -f "$kps" ] || { echo "  FAIL  KeyPinSheets.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$popup" "$d/src/com/nowhere/chooser/PopupSheet.java"
  cp "$kps" "$d/src/com/nowhere/chooser/KeyPinSheets.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/KeyPinSheetsCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then
    rm -rf "$d"; return 3
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.KeyPinSheetsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  KeyPinSheetsCases" >&2
  return 1
}

# code <file> -> the file without comment lines and trailing // comments.
code() { sed -E -e '/^[[:space:]]*(\/\/|\*|\/\*)/d' -e 's/[[:space:]]+\/\/[[:space:]].*$//' "$1"; }
# meth <code file> <name> -> the method flattened to one line, from its 4-space declaration to its 4-space closing
# brace, every run of blanks one space (a re-wrap does not break a pin).
meth() {
  awk -v n="$2" '$0 ~ ("^    [a-zA-Z].* " n "\\(") && !f { f = 1 } f { print } f && /^    }$/ { exit }' "$1" \
    | tr '\n' ' ' | tr -s ' \t' ' '
}
# has <text> <fixed string> -> 0 when the text holds it.
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
# occurrences <text> <fixed string> -> how many times the text holds it.
occurrences() {
  local t="$1" n=0
  while has "$t" "$2"; do n=$((n+1)); t=${t#*"$2"}; done
  echo "$n"
}

KEY_ANCHOR='SheetDialog.confirm(this, KeyPinSheets.removeKey(label, last), new Runnable[] { null, () -> SheetDialog.confirm(this, KeyPinSheets.confirmWithKey(last), new Runnable[] { () -> {'
KEY_TAIL='"nowhere-fido2-remove").start(); }, null }, null) }, null);'
PIN_ANCHOR='SheetDialog.confirm(this, KeyPinSheets.removePin(), new Runnable[] { null, () -> new Thread(() -> {'
PIN_TAIL='}, "nowhere-clear-pin").start() }, null));'

# pins <ProfileActivity.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local paf bad=0 b m click
  paf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"

  for m in confirmRemoveKey showSessionPin; do
    b=$(meth "$paf" "$m")
    [ -n "$b" ] || { echo "  FAIL  S1 $m( not found" >&2; bad=1; continue; }
    has "$b" "AlertDialog.Builder" && { echo "  FAIL  S1 $m holds an AlertDialog.Builder" >&2; bad=1; }
  done

  b=$(meth "$paf" confirmRemoveKey)
  if ! has "$b" "$KEY_ANCHOR"; then
    echo "  FAIL  S2 confirmRemoveKey does not show removeKey(label, last) with nothing on button 0 and the" \
         "confirmWithKey(last) sheet on button 1, the removal on that sheet's button 0" >&2; bad=1
  else
    [ "$(occurrences "$b" "REMOVE-FIDO2-KEY")" -eq 1 ] \
      || { echo "  FAIL  S2 confirmRemoveKey does not send REMOVE-FIDO2-KEY exactly once" >&2; bad=1; }
    has "${b%%"$KEY_ANCHOR"*}" "REMOVE-FIDO2-KEY" \
      && { echo "  FAIL  S2 confirmRemoveKey sends REMOVE-FIDO2-KEY before the confirmWithKey sheet's button 0" >&2; bad=1; }
    has "${b#*"$KEY_ANCHOR"}" "$KEY_TAIL" \
      || { echo "  FAIL  S2 confirmRemoveKey's removal is not followed by nothing on both sheets' other button" >&2; bad=1; }
    has "${b##*"$KEY_TAIL"}" "REMOVE-FIDO2-KEY" \
      && { echo "  FAIL  S2 confirmRemoveKey sends REMOVE-FIDO2-KEY outside the confirmWithKey sheet's button 0" >&2; bad=1; }
  fi

  b=$(meth "$paf" showSessionPin)
  click=${b#*"remove.setOnClickListener("}
  if [ "$click" = "$b" ]; then
    echo "  FAIL  S3 showSessionPin has no remove.setOnClickListener(" >&2; bad=1
  elif ! has "$click" "$PIN_ANCHOR"; then
    echo "  FAIL  S3 showSessionPin's Remove does not show removePin() with nothing on button 0 and the clear" \
         "thread on button 1" >&2; bad=1
  else
    has "${click%%"$PIN_ANCHOR"*}" "SET-PIN" \
      && { echo "  FAIL  S3 showSessionPin's Remove sends SET-PIN before the removePin sheet's button 1" >&2; bad=1; }
    has "${click#*"$PIN_ANCHOR"}" "SET-PIN" \
      || { echo "  FAIL  S3 showSessionPin's Remove does not send SET-PIN from the removePin sheet's button 1" >&2; bad=1; }
    has "${click#*"$PIN_ANCHOR"}" "$PIN_TAIL" \
      || { echo "  FAIL  S3 showSessionPin's clear thread is not followed by the sheet's end (no third action)" >&2; bad=1; }
  fi
  rm -f "$paf"
  [ "$bad" -eq 0 ]
}

# check_all <PopupSheet.java> <KeyPinSheets.java> <ProfileActivity.java> -> 0 when the cases and every pin pass, 1
# when one fails, 3 when the classes did not compile.
check_all() {
  local rc
  suite "$1" "$2"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$3" || rc=1
  return "$rc"
}

echo "== KeyPinSheets, PopupSheet; confirmRemoveKey and showSessionPin's Remove PIN"
check_all "$POPUP" "$KPS" "$PA"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases + pins S1-S3"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
# rules_new <chooser src copy> -> 0 when test-popup-rules.sh, run on that copy, fails on a NEW confirmRemoveKey Cancel.
rules_new() {
  local out rc T=$'\t'
  out=$(TMPDIR="$W" SRC_DIR="$1" bash "$RULES" 2>&1); rc=$?
  [ "$rc" -eq 1 ] || { echo "  rules: exit $rc, wanted 1"; return 1; }
  has "$out" "NEW: ProfileActivity.java${T}confirmRemoveKey${T}R1${T}Cancel (baseline 0, found 1)" \
    || { echo "  rules: no NEW line for confirmRemoveKey's Cancel"; return 1; }
}
mut() { # mut <label> <kps|pa|pa+rules> <the assertion that must convict it> <perl-expr>
  local d c rc orig out
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in kps) orig="$KPS" ;; *) orig="$PA" ;; esac
  if [ "$2" = "pa+rules" ]; then
    cp -r "$SRC" "$d/src"
    c="$d/src/$(basename "$orig")"
  else
    c="$d/$(basename "$orig")"
    cp "$orig" "$c"
  fi
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    kps) out=$(check_all "$POPUP" "$c" "$PA" 2>&1); rc=$? ;;
    *) out=$(pins "$c" 2>&1); rc=$? ;;
  esac
  if [ "$2" = "pa+rules" ] && [ "$rc" -eq 1 ]; then
    if ! rules_new "$d/src"; then echo "  SURVIVED  $1 -- test-popup-rules.sh did not report it NEW"; rm -rf "$d"; return 1; fi
  fi
  rm -rf "$d"
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
fails=0
mut "K1 Remove made GREEN_FILLED"            kps      "removeKey last remove red-outlined" 's/REMOVE, PopupSheet\.Style\.RED_OUTLINED/REMOVE, PopupSheet.Style.GREEN_FILLED/' || fails=$((fails+1))
mut "K2 Keep it dropped"                     kps      "removeKey last keep green first"    's/new PopupSheet\.Button\(KEEP_IT, PopupSheet\.Style\.GREEN_FILLED\),\s*//' || fails=$((fails+1))
mut "K3 the removePin actions swapped"       pa       "S3 showSessionPin"                  's/new Runnable\[\] \{ null, \(\) -> new Thread\(\(\) -> \{/new Runnable[] { () -> new Thread(() -> {/; s/(\}, "nowhere-clear-pin"\)\.start\(\)) \}, null\)\);/$1, null }, null));/' || fails=$((fails+1))
mut "K4 confirmWithKey's slots swapped"      pa       "S2 confirmRemoveKey"                's/KeyPinSheets\.confirmWithKey\(last\), new Runnable\[\] \{ \(\) -> \{/KeyPinSheets.confirmWithKey(last), new Runnable[] { null, () -> {/; s/\}, null \}, null\) \}, null\);/} }, null) }, null);/' || fails=$((fails+1))
mut "K5 the label left out of the title"     kps      "removeKey last title"               's/REMOVE_KEY_TITLE_PREFIX \+ label \+ REMOVE_KEY_TITLE_SUFFIX/REMOVE_KEY_TITLE_PREFIX + REMOVE_KEY_TITLE_SUFFIX/' || fails=$((fails+1))
mut "K6 a line dropped"                      kps      "removeKey last join"                's/\n[ \t]*lines\.add\(new PopupSheet\.Line\(LAST_KEY_ADD_BACK, null\)\);//' || fails=$((fails+1))
mut "K7 a Cancel builder put back"           pa+rules "S1 confirmRemoveKey"                's/(private void confirmRemoveKey\([^\n]*\n[^\n]*\{\n)/$1        new android.app.AlertDialog.Builder(this).setTitle("Remove key?").setNegativeButton("Cancel", null).show();\n/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 7 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
