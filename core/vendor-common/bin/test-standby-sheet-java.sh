#!/usr/bin/env bash
# test-standby-sheet-java.sh [--mutate] -- Auto standby when idle as a sheet of cards with two boxes, run under javac
# (NWP-20261206-04; docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to one
# bottom-sheet design", slice 2; docs/product-decisions.md "2026-11-14 — DECIDED: four answers to harvest 66").
#
# WHY THIS IS COMMITTED. The sheet replaces one dialog whose single Save wrote idle=, holdlock= and holdaudio= together.
# Now a card tap writes idle= and each box writes its own key on its toggle, each through presetGuard, and the gate is
# told only when the write landed. A box whose save was cancelled or failed must go back to the file's value, and the
# box's own settle must never save again. StandbySheets and PopupSheet are pure java.util and are compiled here with
# their cases. Source pins (comments stripped) hold what the cases cannot:
#   S1 showIdlePicker holds no AlertDialog.Builder and calls SheetDialog.pickerWithBoxes once;
#   S2 saveStandby calls presetGuard once, on a line before its writers (writeIdlePref, setPref(key, value));
#   S3 saveStandby calls sendLivePrefs once, only as `if (ok) live = sendLivePrefs();`;
#   S4 a box's undo settles it to the file's value, readPrefValue(StandbySheets.BOX_KEYS[i]);
#   S5 SheetDialog.pickerWithBoxes's settle sets the box and enables it and never calls onToggle; onToggle.toggled is
#      called once, from a click listener, and no OnCheckedChangeListener is set.
# The other pins of this picker moved with it: test-audio-hold-pref-java.sh, test-roamed-prefs-live-java.sh,
# test-setting-landed-java.sh, test-preset-picker-java.sh and test-profile-presets-java.sh.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran. --mutate also needs perl and python3 (mutant M7
# runs core/chooser/test-popup-rules.sh on its copy).
#
#   bash test-standby-sheet-java.sh            # the cases + the pins
#   bash test-standby-sheet-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
SS="$SRC/StandbySheets.java"
DIALOG="$SRC/SheetDialog.java"
PA="$SRC/ProfileActivity.java"
RULES="$root/core/chooser/test-popup-rules.sh"
CASES="$root/core/chooser/tests/standby-sheet/StandbySheetCases.java"
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

# suite <PopupSheet.java> <StandbySheets.java> -> 0 pass, 1 a case failed or a class is missing (the only codes that
# convict a mutant), 3 it did not compile.
suite() {
  local popup="$1" ss="$2" d out rc
  [ -f "$popup" ] || { echo "  FAIL  PopupSheet.java does not exist" >&2; return 1; }
  [ -f "$ss" ] || { echo "  FAIL  StandbySheets.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$popup" "$d/src/com/nowhere/chooser/PopupSheet.java"
  cp "$ss" "$d/src/com/nowhere/chooser/StandbySheets.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/StandbySheetCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.StandbySheetCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  StandbySheetCases" >&2
  return 1
}

# code <file> -> the file without comment lines and trailing // comments.
code() { sed -E -e '/^[[:space:]]*(\/\/|\*|\/\*)/d' -e 's/[[:space:]]+\/\/[[:space:]].*$//' "$1"; }
# meth <code file> <name> -> the method's lines, from its 4-space declaration to its 4-space closing brace.
meth() {
  awk -v n="$2" '$0 ~ ("^    [a-zA-Z].* " n "\\(") && !f { f = 1 } f { print } f && /^    }$/ { exit }' "$1"
}
# count <text> <fixed string> -> the number of lines holding it.
count() { printf '%s\n' "$1" | grep -cF -- "$2"; }
# first_line <text> <fixed string> -> the first line number holding it, empty when none.
first_line() { printf '%s\n' "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1; }
# has <text> <fixed string> -> 0 when the text holds it.
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# pins <ProfileActivity.java> <SheetDialog.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local paf dlf bad=0 sip ssb pwb g w settle line
  paf=$(mktemp -p "$W") || return 1
  dlf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"
  code "$2" > "$dlf"
  sip=$(meth "$paf" showIdlePicker)
  ssb=$(meth "$paf" saveStandby)
  pwb=$(meth "$dlf" pickerWithBoxes)
  [ -n "$sip" ] || { echo "  FAIL  S1 showIdlePicker( not found" >&2; bad=1; }
  [ -n "$ssb" ] || { echo "  FAIL  S2 saveStandby( not found" >&2; bad=1; }
  [ -n "$pwb" ] || { echo "  FAIL  S5 SheetDialog.pickerWithBoxes( not found" >&2; bad=1; }

  # S1: a sheet, not a dialog.
  if has "$sip" "AlertDialog.Builder" || [ "$(count "$sip" "SheetDialog.pickerWithBoxes(")" -ne 1 ]; then
    echo "  FAIL  S1 showIdlePicker holds an AlertDialog.Builder or not exactly one SheetDialog.pickerWithBoxes(" >&2; bad=1
  fi

  # S2: one guard call, before both writers.
  g=$(first_line "$ssb" "presetGuard(")
  w=$(first_line "$ssb" "writeIdlePref(")
  line=$(first_line "$ssb" "setPref(key, value)")
  if [ "$(count "$ssb" "presetGuard(")" -ne 1 ] || [ -z "$g" ] || [ -z "$w" ] || [ -z "$line" ] \
     || [ "$g" -ge "$w" ] || [ "$g" -ge "$line" ]; then
    echo "  FAIL  S2 saveStandby does not call presetGuard once, before writeIdlePref( and setPref(key, value)" >&2; bad=1
  fi

  # S3: the gate is told only when the write landed.
  line=$(printf '%s\n' "$ssb" | grep -F -- "sendLivePrefs(")
  if [ "$(count "$ssb" "sendLivePrefs(")" -ne 1 ] || ! [[ "$line" =~ ^\ *if\ \(ok\)\ live\ =\ sendLivePrefs\(\)\;$ ]]; then
    echo "  FAIL  S3 saveStandby does not send only as 'if (ok) live = sendLivePrefs();'" >&2; bad=1
  fi

  # S4: a cancelled or failed box save goes back to the file's value.
  has "$sip" '() -> settle.accept(!"0".equals(readPrefValue(StandbySheets.BOX_KEYS[i])))' \
    || { echo "  FAIL  S4 a box's undo does not settle it to readPrefValue(StandbySheets.BOX_KEYS[i])" >&2; bad=1; }

  # S5: settle never re-saves; the box saves from a click only.
  settle=$(printf '%s\n' "$pwb" | awk '!f && /settle = / { f = 1 } f { print } f && /^ *};$/ { exit }')
  if [ -z "$settle" ] || ! has "$settle" "setChecked(" || ! has "$settle" "setEnabled(true)" || has "$settle" "onToggle" \
     || [ "$(count "$pwb" "onToggle.toggled(")" -ne 1 ] || ! has "$pwb" "setOnClickListener(" \
     || has "$pwb" "setOnCheckedChangeListener"; then
    echo "  FAIL  S5 pickerWithBoxes's settle calls onToggle, or the box does not save from one click listener" >&2; bad=1
  fi
  [ "$bad" -eq 0 ]
}

# check_all <PopupSheet.java> <StandbySheets.java> <ProfileActivity.java> <SheetDialog.java> -> 0 when the cases and
# every pin pass, 1 when one fails, 3 when the classes did not compile.
check_all() {
  local rc
  suite "$1" "$2"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$3" "$4" || rc=1
  return "$rc"
}

echo "== StandbySheets, PopupSheet.Boxes, showIdlePicker, saveStandby, SheetDialog.pickerWithBoxes"
check_all "$POPUP" "$SS" "$PA" "$DIALOG"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases C1-C9 + pins S1-S5"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: --mutate needs python3 (M7), and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
# mut <label> <ss|popup|pa|dialog> <the assertion that must convict it> <perl-expr> [<popup-rules line that must also convict it>]
mut() {
  local d c rc orig out popup="$POPUP" ss="$SS" pa="$PA" dialog="$DIALOG" rules rrc
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in
    ss) orig="$SS"; c="$d/StandbySheets.java"; ss="$c" ;;
    popup) orig="$POPUP"; c="$d/PopupSheet.java"; popup="$c" ;;
    pa) orig="$PA"; c="$d/ProfileActivity.java"; pa="$c" ;;
    dialog) orig="$DIALOG"; c="$d/SheetDialog.java"; dialog="$c" ;;
    *) echo "  ERROR     $1 -- unknown file $2"; rm -rf "$d"; return 1 ;;
  esac
  cp "$orig" "$c"
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(check_all "$popup" "$ss" "$pa" "$dialog" 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && [ -n "${5:-}" ]; then
    # The scanner reads a whole source dir: give it the tree's sources with the mutant in place.
    mkdir -p "$d/src"
    cp "$SRC"/*.java "$d/src/"
    cp "$c" "$d/src/$(basename "$orig")"
    rules=$(TMPDIR="$W" SRC_DIR="$d/src" bash "$RULES" 2>&1); rrc=$?
  fi
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
  if ! has "$out" "FAIL  $3"; then
    echo "  WRONG     $1 -- failed, but not on '$3':"; printf '%s\n' "$out" | grep 'FAIL' | head -3; return 1
  fi
  if [ -n "${5:-}" ]; then
    if [ "$rrc" -eq 0 ] || ! has "$rules" "$5"; then
      echo "  WRONG     $1 -- test-popup-rules.sh did not report '$5' (rc=$rrc)"; return 1
    fi
    echo "  CONVICTED $1 -- by $3, and test-popup-rules.sh reports it NEW"
    return 0
  fi
  echo "  CONVICTED $1 -- by $3"
}
T=$'\t'
fails=0
mut "M1 MINS gains 2"              ss     "C1 MINS is"            's/static final int\[\] MINS = \{ 5, /static final int[] MINS = { 2, 5, /' || fails=$((fails+1))
mut "M2 current(\"2\") returns 1"  ss     'C3 current("2") is -1' 's/(if \(MINS\[i\] == minutes\) return i;\n *)return -1;/${1}return 1;/' || fails=$((fails+1))
mut "M3 current(\"\") returns -1"  ss     'C3 current("") is 1'   's/(static int current\(String idlePref\) \{\n *)int minutes = DEFAULT_MINUTES;/${1}int minutes = -1;/' || fails=$((fails+1))
mut "M4 boxes inverted"            ss     "C5 boxes"              's/Arrays\.asList\(!"0"\.equals\(holdlock\), !"0"\.equals\(holdaudio\)\)/Arrays.asList("0".equals(holdlock), "0".equals(holdaudio))/' || fails=$((fails+1))
mut "M5 boxValue inverted"         ss     "C6 boxValue"           's/return on \? "" : "0";/return on ? "0" : "";/' || fails=$((fails+1))
mut "M6 toast drops the suffix"    ss     "C7 toast(1, false)"    's/ \+ \(live \? "" : " — applies next sign-in"\)//' || fails=$((fails+1))
mut "M7 an AlertDialog kept"       pa     "S1 showIdlePicker"     's/(\n *)(final int cur = StandbySheets\.current\(readPrefValue\("idle"\)\);)/$1$2$1new android.app.AlertDialog.Builder(this).setNegativeButton("Cancel", null).show();/' \
  "NEW: ProfileActivity.java${T}showIdlePicker${T}R1${T}Cancel" || fails=$((fails+1))
mut "M8 write before presetGuard"  pa     "S2 saveStandby"        's/(\n *)(presetGuard\(PresetPicker\.change\(key, value\), \(\) -> \{)\n( *)(final boolean ok = [^\n]*;)/$1$4$1$2/' || fails=$((fails+1))
mut "M9 unconditional send"        pa     "S3 saveStandby"        's/if \(ok\) live = sendLivePrefs\(\);/live = sendLivePrefs();/' || fails=$((fails+1))
mut "M10 box undo removed"         pa     "S4 a box's undo"       's/\(\) -> settle\.accept\(!"0"\.equals\(readPrefValue\(StandbySheets\.BOX_KEYS\[i\]\)\)\)/() -> {}/' || fails=$((fails+1))
mut "M11 settle calls onToggle"    dialog "S5 pickerWithBoxes"    's/(box\.setEnabled\(true\);\n)( *\};)/$1                    onToggle.toggled(index, state, null);\n$2/' || fails=$((fails+1))
mut "M12 Boxes misses a mismatch"  popup  "C9 a size mismatch"    's/\n *if \(b\.labels\.size\(\) != b\.checked\.size\(\)\) out\.add\(R_EMPTY\);//' || fails=$((fails+1))
mut "M13 Boxes misses an \"&\""    popup  'C9 an "&" label'       's/for \(String l : b\.labels\) ampersand\(l, out\);//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "PASS: 13 of 13 mutants convicted" || { echo "== $fails mutant(s) not convicted"; exit 1; }
