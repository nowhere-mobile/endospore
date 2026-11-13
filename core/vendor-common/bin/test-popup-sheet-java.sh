#!/usr/bin/env bash
# test-popup-sheet-java.sh [--mutate] -- the shared bottom sheet's rules and the Privacy level sheets, run under javac
# (NWP-20261201-28; docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to one
# bottom-sheet design", slice 1).
#
# WHY THIS IS COMMITTED. The rules of design A (a button names its action, never OK or Cancel; "&" is spelled "and"; a
# destructive or risky action is never the green button) hold only if a test holds them. PopupSheet and PresetSheet are
# pure java.util and are compiled here with PresetPicker, ProfilePresets, WipeChoice, WipeOnSave, SettingsText and their
# cases. Source pins (comments stripped) hold what the cases cannot:
#   S1 the three Privacy level methods hold no AlertDialog.Builder;
#   S2 they call SheetDialog.picker and SheetDialog.confirm on the PresetSheet models;
#   S3 the two "offered" expressions of the preview, byte for byte;
#   S4 SheetDialog sets Gravity.BOTTOM and calls PopupSheet.violations;
#   S5 PresetPicker.java does not reference PopupSheet (four suites compile it alone).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-popup-sheet-java.sh            # the cases + the pins
#   bash test-popup-sheet-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
POPUP="$SRC/PopupSheet.java"
SHEET="$SRC/PresetSheet.java"
DIALOG="$SRC/SheetDialog.java"
PICKER="$SRC/PresetPicker.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/popup-sheet/PopupSheetCases.java"
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
for f in "$CASES" "$PA" "$PICKER" "$SRC/ProfilePresets.java" "$SRC/WipeChoice.java" "$SRC/WipeOnSave.java" "$SRC/SettingsText.java"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <PopupSheet.java> <PresetSheet.java> -> 0 pass, 1 a case failed or a class is missing (the only codes that
# convict a mutant), 3 it did not compile.
suite() {
  local popup="$1" sheet="$2" d out rc f
  [ -f "$popup" ] || { echo "  FAIL  PopupSheet.java does not exist" >&2; return 1; }
  [ -f "$sheet" ] || { echo "  FAIL  PresetSheet.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$popup" "$d/src/com/nowhere/chooser/PopupSheet.java"
  cp "$sheet" "$d/src/com/nowhere/chooser/PresetSheet.java"
  for f in PresetPicker ProfilePresets WipeChoice WipeOnSave SettingsText; do cp "$SRC/$f.java" "$d/src/com/nowhere/chooser/"; done
  cp "$CASES" "$d/src/com/nowhere/chooser/PopupSheetCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.PopupSheetCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  PopupSheetCases" >&2
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

# pins <ProfileActivity.java> <SheetDialog.java> <PresetPicker.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local paf bad=0 b m k dlg pp
  [ -f "$2" ] || { echo "  FAIL  S4 SheetDialog.java does not exist" >&2; return 1; }
  paf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"
  dlg=$(code "$2"); pp=$(code "$3")

  for m in showPresetPicker pickPreset showPresetPreview; do
    b=$(meth "$paf" "$m")
    [ -n "$b" ] || { echo "  FAIL  S1 $m( not found" >&2; bad=1; continue; }
    has "$b" "AlertDialog.Builder" && { echo "  FAIL  S1 $m holds an AlertDialog.Builder" >&2; bad=1; }
  done

  has "$(meth "$paf" showPresetPicker)" "SheetDialog.picker(this, PresetSheet.picker(" \
    || { echo "  FAIL  S2 showPresetPicker does not call SheetDialog.picker on PresetSheet.picker" >&2; bad=1; }
  has "$(meth "$paf" pickPreset)" "SheetDialog.confirm(this, PresetSheet.count(" \
    || { echo "  FAIL  S2 pickPreset does not call SheetDialog.confirm on PresetSheet.count" >&2; bad=1; }
  b=$(meth "$paf" showPresetPreview)
  has "$b" "SheetDialog.confirm(this, PresetSheet.preview(" \
    || { echo "  FAIL  S2 showPresetPreview does not call SheetDialog.confirm on PresetSheet.preview" >&2; bad=1; }

  for k in 'tie ? !"LOCAL".equals(sessionType)' 'locOffered(sessionType, offlineSession, locServicesAvailable())'; do
    has "$b" "$k" || { echo "  FAIL  S3 showPresetPreview does not hold $k" >&2; bad=1; }
  done

  for k in "Gravity.BOTTOM" "PopupSheet.violations("; do
    has "$dlg" "$k" || { echo "  FAIL  S4 SheetDialog.java does not hold $k" >&2; bad=1; }
  done

  has "$pp" "PopupSheet" && { echo "  FAIL  S5 PresetPicker.java references PopupSheet" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# check_all <PopupSheet.java> <PresetSheet.java> -> 0 when the cases and every pin pass, 1 when one fails, 3 when the
# classes did not compile.
check_all() {
  local rc
  suite "$1" "$2"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$PA" "$DIALOG" "$PICKER" || rc=1
  return "$rc"
}

echo "== PopupSheet, PresetSheet, SheetDialog"
check_all "$POPUP" "$SHEET"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases + pins S1-S5"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <popup|sheet|pa> <the assertion that must convict it> <perl-expr>
  local d c rc orig out
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in popup) orig="$POPUP" ;; sheet) orig="$SHEET" ;; *) orig="$PA" ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    popup) out=$(check_all "$c" "$SHEET" 2>&1); rc=$? ;;
    sheet) out=$(check_all "$POPUP" "$c" 2>&1); rc=$? ;;
    *) out=$(pins "$c" "$DIALOG" "$PICKER" 2>&1); rc=$? ;;
  esac
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
mut "M1 the OK/Cancel check removed"                 popup "R_OK_CANCEL OK"             's/if \(isOkOrCancel\(b\.label\)\) out\.add\(R_OK_CANCEL\);//' || fails=$((fails+1))
mut "M2 the & check removed"                         popup "R_AMPERSAND title"          's/if \(text != null && text\.indexOf\(.&.\) >= 0\) out\.add\(R_AMPERSAND\);//' || fails=$((fails+1))
mut "M3 the destructive-on-green check removed"      popup "R_GREEN_DESTRUCTIVE Delete" 's/if \(b\.style == Style\.GREEN_FILLED && isDestructiveVerb\(b\.label\)\) out\.add\(R_GREEN_DESTRUCTIVE\);//' || fails=$((fails+1))
mut "M4 DESTRUCTIVE allows GREEN_FILLED"             popup "R_DESTRUCTIVE_GREEN"        's/if \(c\.tone == Tone\.DESTRUCTIVE && green != 0\) out\.add\(R_DESTRUCTIVE_GREEN\);//' || fails=$((fails+1))
mut "M5 two current allowed"                         popup "R_TWO_CURRENT"              's/if \(current > 1\) out\.add\(R_TWO_CURRENT\);//' || fails=$((fails+1))
mut "M6 wipe 3 reads Wipe 6 h"                       sheet "chips of Standard"          's/case "3": return "Wipe 12 h";/case "3": return "Wipe 6 h";/' || fails=$((fails+1))
mut "M7 count's green button reads Cancel"           sheet "count no violations"        's/new PopupSheet\.Button\("Review the changes", PopupSheet\.Style\.GREEN_FILLED\)/new PopupSheet.Button("Cancel", PopupSheet.Style.GREEN_FILLED)/' || fails=$((fails+1))
mut "M8 a link line keeps its linkKey, not offered"  sheet "link case"                  's/open \? linkKey\(i\) : null/linkKey(i)/' || fails=$((fails+1))
mut "M9 showPresetPicker back to an AlertDialog"     pa    "S1 showPresetPicker"        's/SheetDialog\.picker\(this, PresetSheet\.picker\(saved, presetShown\(\), savedValues\), i -> pickPreset\(names\.get\(i\)\)\);/new android.app.AlertDialog.Builder(this).show();/' || fails=$((fails+1))
mut "M10 the loc expression changed"                 pa    "S3 showPresetPreview"       's/locOffered\(sessionType, offlineSession, locServicesAvailable\(\)\);\n(\s+linkOffered)/locOffered(sessionType, false, locServicesAvailable());\n$1/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 10 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
