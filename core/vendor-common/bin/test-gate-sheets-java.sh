#!/usr/bin/env bash
# test-gate-sheets-java.sh [--mutate] -- the gate's two picker sheets, run under javac (NWP-20261204-18;
# docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to one bottom-sheet design",
# slice 2): Back up my data (showSyncIntervalPicker) and Restore data from… (pickRestoreDevice).
#
# WHY THIS IS COMMITTED. The chooser does not compile off the build host, so the two sheets hold only if a test holds
# them. GateSheets is pure java.util and is compiled here with PopupSheet, SyncChoices and its cases (titles, one card
# per label in order, none current, no rules breach). Source pins (comments stripped) hold what the cases cannot:
#   S1 showSyncIntervalPicker and pickRestoreDevice hold no AlertDialog.Builder;
#   S2 showSyncIntervalPicker assigns syncPicker from SheetDialog.picker on GateSheets.sync, after its isShowing guard
#      (one picker at a time, NWP-20261130-14);
#   S3 syncPicker is an android.app.Dialog and onPause still dismisses and nulls it (a screen-off closes the sheet);
#   S4 SheetDialog.picker returns the dialog it passed to show, and null for a null model;
#   S5 pickRestoreDevice sets restoreSrcUnit before roamLogin(name, pw, false), inside the onPick lambda.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-gate-sheets-java.sh            # the cases + the pins
#   bash test-gate-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
GS="$SRC/GateSheets.java"
CA="$SRC/ChooserActivity.java"
DIALOG="$SRC/SheetDialog.java"
CASES="$root/core/chooser/tests/gate-sheets/GateSheetsCases.java"
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
for f in "$CASES" "$CA" "$SRC/PopupSheet.java" "$SRC/SyncChoices.java"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <GateSheets.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that convict a mutant),
# 3 it did not compile.
suite() {
  local gs="$1" d out rc f
  [ -f "$gs" ] || { echo "  FAIL  GateSheets.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$gs" "$d/src/com/nowhere/chooser/GateSheets.java"
  for f in PopupSheet SyncChoices; do cp "$SRC/$f.java" "$d/src/com/nowhere/chooser/"; done
  cp "$CASES" "$d/src/com/nowhere/chooser/GateSheetsCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.GateSheetsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  GateSheetsCases" >&2
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
# count <text> <fixed string> -> the number of lines that hold it.
count() { local n; n=$(printf '%s\n' "$1" | grep -cF -- "$2"); echo "${n:-0}"; }
# lineof <text> <fixed string> -> the line number of the first line that holds it, or 0.
lineof() { local n; n=$(printf '%s\n' "$1" | grep -nF -- "$2" | head -1); echo "${n%%:*}" | sed 's/^$/0/'; }

# pins <ChooserActivity.java> <SheetDialog.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local caf dlf bad=0 b m n g p a c e r all
  caf=$(mktemp -p "$W") || return 1
  dlf=$(mktemp -p "$W") || return 1
  code "$1" > "$caf"
  code "$2" > "$dlf"
  all=$(cat "$caf")

  for m in showSyncIntervalPicker pickRestoreDevice; do
    b=$(meth "$caf" "$m")
    [ -n "$b" ] || { echo "  FAIL  S1 $m( not found" >&2; bad=1; continue; }
    has "$b" "AlertDialog.Builder" && { echo "  FAIL  S1 $m holds an AlertDialog.Builder" >&2; bad=1; }
  done

  b=$(meth "$caf" showSyncIntervalPicker)
  n=$(count "$b" 'if (syncPicker != null && syncPicker.isShowing()) return;')
  p=$(count "$b" 'syncPicker = SheetDialog.picker(this, GateSheets.sync(labels), w ->')
  if [ "$n" != 1 ] || [ "$p" != 1 ]; then
    echo "  FAIL  S2 showSyncIntervalPicker holds the isShowing guard $n time(s) and the syncPicker = SheetDialog.picker" \
         "assignment $p time(s), want 1 and 1" >&2; bad=1
  else
    g=$(lineof "$b" 'if (syncPicker != null && syncPicker.isShowing()) return;')
    a=$(lineof "$b" 'syncPicker = SheetDialog.picker(this, GateSheets.sync(labels), w ->')
    [ "$g" -lt "$a" ] || { echo "  FAIL  S2 the syncPicker assignment comes before the isShowing guard" >&2; bad=1; }
  fi

  n=$(printf '%s\n' "$all" | grep -cxF '    private android.app.Dialog syncPicker;'); n=${n:-0}
  [ "$n" = 1 ] || { echo "  FAIL  S3 the field '    private android.app.Dialog syncPicker;' occurs $n time(s), want 1" >&2; bad=1; }
  n=$(count "$(meth "$caf" onPause)" 'if (syncPicker != null) { syncPicker.dismiss(); syncPicker = null; }')
  [ "$n" = 1 ] || { echo "  FAIL  S3 onPause dismisses and nulls syncPicker $n time(s), want 1" >&2; bad=1; }

  b=$(meth "$dlf" picker)
  for p in 'static Dialog picker(' 'if (m == null) return null;'; do
    has "$b" "$p" || { echo "  FAIL  S4 SheetDialog.picker does not hold $p" >&2; bad=1; }
  done
  n=$(count "$b" 'return dlg;')
  if [ "$n" != 1 ]; then
    echo "  FAIL  S4 SheetDialog.picker holds 'return dlg;' $n time(s), want 1" >&2; bad=1
  else
    r=$(printf '%s\n' "$b" | grep -B1 -F 'return dlg;' | head -1 | sed -E 's/^[[:space:]]+//')
    [ "$r" = 'show(dlg, panel, false);' ] || { echo "  FAIL  S4 the line before 'return dlg;' is '$r', not 'show(dlg, panel, false);'" >&2; bad=1; }
  fi

  b=$(meth "$caf" pickRestoreDevice)
  n=$(count "$b" 'SheetDialog.picker(this, GateSheets.restore(labels), which -> {')
  m=$(count "$b" 'restoreSrcUnit = units.get(which)[0];')
  p=$(count "$b" 'roamLogin(name, pw, false);')
  if [ "$n" != 1 ] || [ "$m" != 1 ] || [ "$p" != 1 ]; then
    echo "  FAIL  S5 pickRestoreDevice holds the restore sheet $n, restoreSrcUnit $m and roamLogin $p time(s), want 1 each" >&2; bad=1
  else
    a=$(lineof "$b" 'SheetDialog.picker(this, GateSheets.restore(labels), which -> {')
    m=$(lineof "$b" 'restoreSrcUnit = units.get(which)[0];')
    c=$(lineof "$b" 'roamLogin(name, pw, false);')
    e=$(printf '%s\n' "$b" | awk -v a="$a" 'NR > a && /^ *\}\);$/ { print NR; exit }')
    e=${e:-0}
    if ! [ "$a" -lt "$m" ] || ! [ "$m" -lt "$c" ] || ! [ "$c" -lt "$e" ]; then
      echo "  FAIL  S5 pickRestoreDevice does not set restoreSrcUnit then call roamLogin inside the onPick lambda" \
           "(sheet $a, restoreSrcUnit $m, roamLogin $c, lambda end $e)" >&2; bad=1
    fi
  fi
  [ "$bad" -eq 0 ]
}

# check_all <GateSheets.java> <ChooserActivity.java> <SheetDialog.java> -> 0 when the cases and every pin pass, 1 when
# one fails, 3 when the classes did not compile.
check_all() {
  local rc
  suite "$1"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$2" "$3" || rc=1
  return "$rc"
}

echo "== GateSheets, ChooserActivity's two pickers, SheetDialog.picker"
check_all "$GS" "$CA" "$DIALOG"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases + pins S1-S5"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its own assertion -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <gs|dialog|chooser> <the assertion that must convict it> <perl-expr>
  local d c rc orig out
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in gs) orig="$GS" ;; dialog) orig="$DIALOG" ;; *) orig="$CA" ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$4" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    gs) out=$(check_all "$c" "$CA" "$DIALOG" 2>&1); rc=$? ;;
    dialog) out=$(check_all "$GS" "$CA" "$c" 2>&1); rc=$? ;;
    *) out=$(check_all "$GS" "$c" "$DIALOG" 2>&1); rc=$? ;;
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
mut "M1 sync marks an option current"           gs      "sync none current" 's/"", false\)\);/"", true));/' || fails=$((fails+1))
mut "M2 a label dropped"                        gs      "sync count"        's/(\n(\s+)return new PopupSheet\.Picker\(title, options\);)/\n$2if (!options.isEmpty()) options.remove(options.size() - 1);$1/' || fails=$((fails+1))
mut "M3 the restore title changed"              gs      "restore title"     's/RESTORE_TITLE = "Restore data from…";/RESTORE_TITLE = "Restore data from...";/' || fails=$((fails+1))
mut "M4 picker returns null always"             dialog  "S4"                's/return dlg;/return null;/' || fails=$((fails+1))
mut "M5 syncPicker no longer assigned"          chooser "S2"                's/syncPicker = SheetDialog\.picker\(this, GateSheets\.sync\(labels\),/SheetDialog.picker(this, GateSheets.sync(labels),/' || fails=$((fails+1))
mut "M6 the isShowing guard removed"            chooser "S2"                's/\n\s+if \(syncPicker != null && syncPicker\.isShowing\(\)\) return;//' || fails=$((fails+1))
mut "M7 the onPause dismiss removed"            chooser "S3"                's/\n\s+if \(syncPicker != null\) \{ syncPicker\.dismiss\(\); syncPicker = null; \}//' || fails=$((fails+1))
mut "M8 roamLogin before restoreSrcUnit is set" chooser "S5"                's/(\n\s+restoreSrcUnit = units\.get\(which\)\[0\];[^\n]*)(\n\s+roamLogin\(name, pw, false\);[^\n]*)/$2$1/' || fails=$((fails+1))
mut "M9 a Cancel builder put back"              chooser "S1"                's/(\n(\s+)SheetDialog\.picker\(this, GateSheets\.restore\(labels\))/\n$2new android.app.AlertDialog.Builder(this).setTitle("Restore data from…").setNegativeButton("Cancel", null).show();$1/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 9 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
