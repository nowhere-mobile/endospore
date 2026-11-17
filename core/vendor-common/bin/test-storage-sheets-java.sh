#!/usr/bin/env bash
# test-storage-sheets-java.sh [--mutate] -- three Profile pickers as sheets of cards, run under javac (NWP-20261204-17;
# docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to one bottom-sheet design",
# slice 2: Backups while apps set up, Save automatically, Re-archive idle apps).
#
# WHY THIS IS COMMITTED. StorageSheets builds the three PopupSheet models: one card per option, its trade-off line under
# its name, and only an exact match current. It is pure java.util and is compiled here with PopupSheet, SealHold,
# SaveMode and its cases. Source pins (comments stripped) hold what the cases cannot:
#   S1 showSealHoldDialog, showSaveModeDialog and showReclaimDialog hold no AlertDialog.Builder;
#   S2 each calls SheetDialog.picker on its StorageSheets model;
#   S3 showSealHoldDialog and showSaveModeDialog still return on a failed write before they touch cur[0];
#   S4 showReclaimDialog still saves only inside presetGuard(PresetPicker.change("reclaim", ...)).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-storage-sheets-java.sh            # the cases + the pins
#   bash test-storage-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SHEETS="$SRC/StorageSheets.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/storage-sheets/StorageSheetsCases.java"
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
for f in "$CASES" "$PA" "$SRC/PopupSheet.java" "$SRC/SealHold.java" "$SRC/SaveMode.java"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <StorageSheets.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that convict a mutant),
# 3 it did not compile.
suite() {
  local sheets="$1" d out rc f
  [ -f "$sheets" ] || { echo "  FAIL  StorageSheets.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$sheets" "$d/src/com/nowhere/chooser/StorageSheets.java"
  for f in PopupSheet SealHold SaveMode; do cp "$SRC/$f.java" "$d/src/com/nowhere/chooser/"; done
  cp "$CASES" "$d/src/com/nowhere/chooser/StorageSheetsCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.StorageSheetsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  StorageSheetsCases" >&2
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
# count <text> <fixed string> -> how many lines of the text hold it.
count() { local n; n=$(printf '%s\n' "$1" | grep -cF -- "$2"); echo "${n:-0}"; }
# first_line <text> <fixed string> -> the number of the first line that holds it, 0 when none does.
first_line() { local n; n=$(printf '%s\n' "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1); echo "${n:-0}"; }

# pins <ProfileActivity.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local paf bad=0 b m k w c guard save
  paf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"

  for m in showSealHoldDialog showSaveModeDialog showReclaimDialog; do
    b=$(meth "$paf" "$m")
    [ -n "$b" ] || { echo "  FAIL  S1 $m( not found" >&2; bad=1; continue; }
    has "$b" "AlertDialog.Builder" && { echo "  FAIL  S1 $m holds an AlertDialog.Builder" >&2; bad=1; }
  done

  has "$(meth "$paf" showSealHoldDialog)" "SheetDialog.picker(this, StorageSheets.sealHold(cur[0]), which -> {" \
    || { echo "  FAIL  S2 showSealHoldDialog does not call SheetDialog.picker on StorageSheets.sealHold" >&2; bad=1; }
  has "$(meth "$paf" showSaveModeDialog)" "SheetDialog.picker(this, StorageSheets.saveMode(cur[0]), which -> {" \
    || { echo "  FAIL  S2 showSaveModeDialog does not call SheetDialog.picker on StorageSheets.saveMode" >&2; bad=1; }
  has "$(meth "$paf" showReclaimDialog)" "SheetDialog.picker(this, StorageSheets.reclaim(items, checked), which -> " \
    || { echo "  FAIL  S2 showReclaimDialog does not call SheetDialog.picker on StorageSheets.reclaim" >&2; bad=1; }

  for m in showSealHoldDialog:writeSealHold:SealHold showSaveModeDialog:writeSaveMode:SaveMode; do
    k=${m#*:}; c=${k#*:}; w=${k%%:*}; m=${m%%:*}
    b=$(meth "$paf" "$m")
    k="if (!$w($c.VALUES[which])) return;"
    if [ "$(count "$b" "$k")" -ne 1 ]; then
      echo "  FAIL  S3 $m does not hold '$k' exactly once" >&2; bad=1; continue
    fi
    if [ "$(first_line "$b" "cur[0] =")" -le "$(first_line "$b" "$k")" ]; then
      echo "  FAIL  S3 $m touches cur[0] before its failed-write return" >&2; bad=1
    fi
  done

  b=$(meth "$paf" showReclaimDialog)
  k='presetGuard(PresetPicker.change("reclaim", Long.toString(opts[which])), () -> {'
  guard=$(count "$b" "$k"); save=$(count "$b" "setReclaimIdleMs(")
  if [ "$guard" -ne 1 ] || [ "$save" -ne 1 ]; then
    echo "  FAIL  S4 showReclaimDialog holds the preset guard $guard time(s) and setReclaimIdleMs( $save time(s), want 1 and 1" >&2; bad=1
  elif [ "$(first_line "$b" "setReclaimIdleMs(")" -le "$(first_line "$b" "$k")" ]; then
    echo "  FAIL  S4 showReclaimDialog calls setReclaimIdleMs outside presetGuard" >&2; bad=1
  fi
  [ "$bad" -eq 0 ]
}

# check_all <StorageSheets.java> -> 0 when the cases and every pin pass, 1 when one fails, 3 when it did not compile.
check_all() {
  local rc
  suite "$1"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$PA" || rc=1
  return "$rc"
}

echo "== StorageSheets and the three ProfileActivity pickers"
check_all "$SHEETS"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases + pins S1-S4"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <sheets|pa> <the assertion that must convict it> <perl-expr>
  local d c rc orig out
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in sheets) orig="$SHEETS" ;; *) orig="$PA" ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    sheets) out=$(check_all "$c" 2>&1); rc=$? ;;
    *) out=$(pins "$c" 2>&1); rc=$? ;;
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
mut "M1 sealHold marks the first option current on no match" sheets "sealHold(bogus) current"       's/SealHold\.tradeoff\(v\), v\.equals\(cur\)\)/SealHold.tradeoff(v), v.equals(cur) || (v == SealHold.VALUES[0] \&\& !java.util.Arrays.asList(SealHold.VALUES).contains(cur)))/' || fails=$((fails+1))
mut "M2 sealHold descriptions dropped"                       sheets "sealHold(2) descriptions"      's/SealHold\.tradeoff\(v\), v\.equals/null, v.equals/' || fails=$((fails+1))
mut "M3 saveMode uses label for the description"             sheets "saveMode(always) descriptions" 's/SaveMode\.tradeoff\(v\), v\.equals/SaveMode.label(v), v.equals/' || fails=$((fails+1))
mut "M4 reclaim current off by one"                          sheets "reclaim(0) current"            's/i == current\)/i == current + 1)/' || fails=$((fails+1))
mut "M5 the failed-write return removed in showSealHoldDialog" pa   "S3 showSealHoldDialog"         's/if \(!writeSealHold\(SealHold\.VALUES\[which\]\)\) return;/writeSealHold(SealHold.VALUES[which]);/' || fails=$((fails+1))
mut "M6 showReclaimDialog saves outside presetGuard"         pa     "S4 showReclaimDialog"          's/(\n\s+)(presetGuard\(PresetPicker\.change\("reclaim")/$1setReclaimIdleMs(opts[which]);$1$2/' || fails=$((fails+1))
mut "M7 a Cancel builder put back in showSealHoldDialog"     pa     "S1 showSealHoldDialog"         's/(\n(\s+))(SheetDialog\.picker\(this, StorageSheets\.sealHold)/$1new android.app.AlertDialog.Builder(this).setTitle("Backups while apps set up").setNegativeButton("Cancel", null).show();$1$3/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 7 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
