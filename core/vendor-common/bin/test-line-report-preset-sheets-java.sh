#!/usr/bin/env bash
# test-line-report-preset-sheets-java.sh [--mutate] -- the gate's Unbind this line? and Send report? and Profile's
# presetGuard replace ask on the shared bottom sheet, run under javac (NWP-20261208-21; docs/backlog.md, "Popups are
# plain dialogs: the choice pickers and the confirmations move to one bottom-sheet design", slice 3).
#
# WHY THIS IS COMMITTED. The three were plain AlertDialogs with a Cancel button, and Unbind's red action was the plain
# positive button. LineReportPresetSheets models them in design A: Unbind red (red filled "Unbind", outlined "Keep the
# bindings"), Send report routine (green "Send", outlined "Not now"), the replace ask amber (green "Not now", red
# outlined "Replace"). LineReportPresetSheets, PopupSheet and PresetPicker (with the pure classes it needs) are compiled
# here with their cases (C1-C6). Source pins (comments stripped, braces counted outside literals) hold what the cases
# cannot:
#   Q1 buildBindSimScreen's Unbind row and buildReportScreen's send.setOnClickListener statement hold no
#      AlertDialog.Builder (control: What's sent and renderGateReportResult keep theirs);
#   Q2 the DELETE-BINDING send sits in unbindLine's slot 0, after the OwnerLanding guard, and slot 1 is null;
#   Q3 the REPORT-ISSUE gateReportJson(noteText, false) send sits in gateSendReport's slot 0, and slot 1 is null;
#   Q4 presetGuard's ASK arm holds no AlertDialog.Builder; slot 0 and the sheet's cancel listener run onCancel; slot 1
#      writes, then saves the Custom only under SettingLanded.landed(.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-line-report-preset-sheets-java.sh            # the cases + the pins
#   bash test-line-report-preset-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SHEETS="$SRC/LineReportPresetSheets.java"
ACT="$SRC/ChooserActivity.java"
PROF="$SRC/ProfileActivity.java"
DEPS="PopupSheet.java PresetPicker.java ProfilePresets.java SettingsText.java WipeChoice.java WipeOnSave.java"
CASES="$root/core/chooser/tests/line-report-preset-sheets/LineReportPresetSheetsCases.java"
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

# suite <LineReportPresetSheets> <ChooserActivity> <ProfileActivity> -> 0 pass, 1 a case or pin failed or a class is
# missing (the only codes that convict a mutant), 3 it did not compile.
suite() {
  local sheets="$1" act="$2" prof="$3" d f out rc
  [ -f "$sheets" ] || { echo "  FAIL  C0 LineReportPresetSheets.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  for f in $DEPS; do cp "$SRC/$f" "$d/src/com/nowhere/chooser/$f" || { rm -rf "$d"; return 3; }; done
  cp "$sheets" "$d/src/com/nowhere/chooser/LineReportPresetSheets.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/LineReportPresetSheetsCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then
    rm -rf "$d"; return 3
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.LineReportPresetSheetsCases \
        "$act" "$prof" 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

echo "== LineReportPresetSheets, PopupSheet, PresetPicker (+ pins in ChooserActivity.java and ProfileActivity.java)"
suite "$SHEETS" "$ACT" "$PROF"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
# mut <label> <sheets|act|prof> <the assertion that must convict it> <perl-expr> [<a second text the output must hold>]
mut() {
  local d c rc orig out s="$SHEETS" a="$ACT" p="$PROF"
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in sheets) orig="$SHEETS" ;; act) orig="$ACT" ;; *) orig="$PROF" ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in sheets) s="$c" ;; act) a="$c" ;; *) p="$c" ;; esac
  out=$(suite "$s" "$a" "$p" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
  case "$out" in
    *"FAIL  $3"*)
      if [ -n "${5:-}" ]; then
        case "$out" in *"$5"*) ;; *) echo "  WRONG     $1 -- FAIL  $3, but no '$5'"; return 1 ;; esac
        echo "  convicted $1 -- FAIL  $3 ($5)"; return 0
      fi
      echo "  convicted $1 -- FAIL  $3"; return 0 ;;
  esac
  echo "  WRONG     $1 -- it failed, but not on '$3':"; printf '%s\n' "$out" | grep -F FAIL | head -3
  return 1
}
fails=0
mut "M1 Unbind green filled"                  sheets "C1 unbindLine button 0" \
  's/new PopupSheet\.Button\(UNBIND, PopupSheet\.Style\.RED_FILLED\)/new PopupSheet.Button(UNBIND, PopupSheet.Style.GREEN_FILLED)/' \
  "a destructive action is on the green button" || fails=$((fails+1))
mut "M2 Keep the bindings first"              sheets "C4 unbindLine breaks no popup rule" \
  's/(new PopupSheet\.Button\(UNBIND, PopupSheet\.Style\.RED_FILLED\)),(\s*)(new PopupSheet\.Button\(KEEP_BINDINGS, PopupSheet\.Style\.OUTLINED\))/$3,$2$1/' \
  'a destructive sheet needs one red filled button first, then an outlined' || fails=$((fails+1))
mut "M3 Replace green, Not now outlined"      sheets "C3 replaceCustom button 1" \
  's/new PopupSheet\.Button\(PresetPicker\.REPLACE, PopupSheet\.Style\.RED_OUTLINED\)/new PopupSheet.Button(PresetPicker.REPLACE, PopupSheet.Style.GREEN_FILLED)/; s/(replaceCustom\(\) \{.*?)new PopupSheet\.Button\(PopupSheet\.NOT_NOW, PopupSheet\.Style\.GREEN_FILLED\)/$1new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.OUTLINED)/s' || fails=$((fails+1))
mut "M4 Send report's Not now says Cancel"    sheets "C5 gateSendReport has no OK or Cancel button" \
  's/(gateSendReport\(\) \{.*?)new PopupSheet\.Button\(PopupSheet\.NOT_NOW, PopupSheet\.Style\.OUTLINED\)/$1new PopupSheet.Button("Cancel", PopupSheet.Style.OUTLINED)/s' || fails=$((fails+1))
mut "M5 presetGuard's write moved to slot 0"  prof   "Q4 presetGuard's ASK arm" \
  's/\(\) -> \{ if \(onCancel != null\) onCancel\.run\(\); \},(\s*\(\) -> \{)\s*write\.run\(\);/() -> { write.run(); if (onCancel != null) onCancel.run(); },$1/' || fails=$((fails+1))
mut "M6 presetGuard's cancel listener gone"   prof   "Q4 presetGuard's ASK arm" \
  's/\n[ ]*if \(d != null\) d\.setOnCancelListener\(x -> \{ if \(onCancel != null\) onCancel\.run\(\); \}\);//' || fails=$((fails+1))
mut "M7 the report send moved to slot 1"      act    "Q3 Send report's slot 0" \
  's/LineReportPresetSheets\.gateSendReport\(\), new Runnable\[\] \{ \(\) -> \{/LineReportPresetSheets.gateSendReport(), new Runnable[] { null, () -> {/; s/(renderGateReportResult\(reply, noteText, msg, root\); \}\);\n\s*\}\)\.start\(\);\n\s*)\}, null \}, null\)\);/$1} }, null));/' || fails=$((fails+1))
mut "M8 Unbind's slot-0 guard removed"        act    "Q2 Unbind's slot 0" \
  's/(LineReportPresetSheets\.unbindLine\(\), new Runnable\[\] \{ \(\) -> \{)\n[ ]*if \(!OwnerLanding[^\n]*/$1/' || fails=$((fails+1))
mut "M9 an AlertDialog back in the Unbind row" act   "Q1 the Unbind row" \
  's/(final boolean owned = ownerSessionPass != null;\n)((?:[ ]*\/\/[^\n]*\n)*[ ]*SheetDialog\.confirm\(this, LineReportPresetSheets\.unbindLine\(\))/$1new android.app.AlertDialog.Builder(this).setTitle("x").show();\n$2/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 9 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
