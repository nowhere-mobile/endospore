#!/usr/bin/env bash
# test-security-sheets-java.sh [--mutate] -- the Security screen's two pickers as sheets of cards, run under javac
# (NWP-20261204-15; docs/backlog.md, "Popups are plain dialogs: the choice pickers and the confirmations move to one
# bottom-sheet design", slice 2).
#
# WHY THIS IS COMMITTED. "Erase a locked session after" and "Always-on VPN" are SheetDialog.picker sheets on the
# SecuritySheets models. A card that names the wrong label, or two cards marked current, or a tap that skips the save
# path, still compiles and shows. SecuritySheets is pure java.util and is compiled here with PopupSheet, WipeChoice,
# WipeOnSave and its cases. Source pins (comments stripped) hold what the cases cannot:
#   S1 neither showWipePicker nor showVpnPicker holds AlertDialog.Builder, setSingleChoiceItems or setNegativeButton;
#   S2 each calls SheetDialog.picker on its SecuritySheets model, and showVpnPicker passes the plain index (no Math.max);
#   S3 showWipePicker writes through `if (writeWipePref(idx)) live = sendLivePrefs();` inside the presetGuard lambda;
#   S4 showVpnPicker writes through writeVpnPick(pkg, lock) inside the picker lambda.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-security-sheets-java.sh            # the cases + the pins
#   bash test-security-sheets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SHEETS="$SRC/SecuritySheets.java"
PA="$SRC/ProfileActivity.java"
LINT="$root/core/chooser/test-popup-rules.sh"
CASES="$root/core/chooser/tests/security-sheets/SecuritySheetsCases.java"
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
for f in "$CASES" "$PA" "$SRC/PopupSheet.java" "$SRC/WipeChoice.java" "$SRC/WipeOnSave.java"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <SecuritySheets.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that convict a
# mutant), 3 it did not compile.
suite() {
  local sheets="$1" d out rc f
  [ -f "$sheets" ] || { echo "  FAIL  SecuritySheets.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$sheets" "$d/src/com/nowhere/chooser/SecuritySheets.java"
  for f in PopupSheet WipeChoice WipeOnSave; do cp "$SRC/$f.java" "$d/src/com/nowhere/chooser/"; done
  cp "$CASES" "$d/src/com/nowhere/chooser/SecuritySheetsCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then
    rm -rf "$d"; return 3
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.SecuritySheetsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  SecuritySheetsCases" >&2
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
# nlines <text> <fixed string> -> how many lines hold it.
nlines() { printf '%s\n' "$1" | grep -cF -- "$2"; }
# at <text> <line> <fixed string> -> the number of the first line after <line> that holds it, 0 when none does.
at() { printf '%s\n' "$1" | awk -v s="$2" -v k="$3" 'NR > s && index($0, k) { print NR; f = 1; exit } END { if (!f) print 0 }'; }
# ordered <text> <fixed string>... -> 0 when each string is on a line after the line of the one before.
ordered() {
  local t="$1" prev=0 n k
  shift
  for k in "$@"; do
    n=$(at "$t" "$prev" "$k")
    [ "$n" -gt "$prev" ] || return 1
    prev=$n
  done
}

WIPE_CALL='SheetDialog.picker(this, SecuritySheets.wipe(sel), idx ->'
VPN_CALL='SheetDialog.picker(this, SecuritySheets.vpn(labels, pkgs.indexOf(current[0])), idx -> {'

# pins <ProfileActivity.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local paf bad=0 b m k wb vb
  paf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"
  wb=$(meth "$paf" showWipePicker); vb=$(meth "$paf" showVpnPicker)
  rm -f "$paf"
  [ -n "$wb" ] || { echo "  FAIL  S1 showWipePicker( not found" >&2; return 1; }
  [ -n "$vb" ] || { echo "  FAIL  S1 showVpnPicker( not found" >&2; return 1; }

  for m in showWipePicker showVpnPicker; do
    if [ "$m" = showWipePicker ]; then b=$wb; else b=$vb; fi
    for k in "AlertDialog.Builder" "setSingleChoiceItems" "setNegativeButton"; do
      has "$b" "$k" && { echo "  FAIL  S1 $m holds $k" >&2; bad=1; }
    done
  done

  [ "$(nlines "$wb" "$WIPE_CALL")" -eq 1 ] \
    || { echo "  FAIL  S2 showWipePicker does not call SheetDialog.picker on SecuritySheets.wipe(sel) once" >&2; bad=1; }
  [ "$(nlines "$vb" "$VPN_CALL")" -eq 1 ] \
    || { echo "  FAIL  S2 showVpnPicker does not call SheetDialog.picker on SecuritySheets.vpn(labels, pkgs.indexOf(current[0])) once" >&2; bad=1; }
  has "$vb" "Math.max(" && { echo "  FAIL  S2 showVpnPicker clamps the current index with Math.max" >&2; bad=1; }

  { [ "$(nlines "$wb" 'writeWipePref(')" -eq 1 ] \
      && [ "$(nlines "$wb" 'if (writeWipePref(idx)) live = sendLivePrefs();')" -eq 1 ] \
      && ordered "$wb" "$WIPE_CALL" 'presetGuard(PresetPicker.change("wipe", String.valueOf(idx)), () -> {' \
           'if (writeWipePref(idx)) live = sendLivePrefs();' '}, () -> showSecurity()));'; } \
    || { echo "  FAIL  S3 showWipePicker does not write through writeWipePref(idx) inside the presetGuard lambda" >&2; bad=1; }

  { [ "$(nlines "$vb" 'writeVpnPick(')" -eq 1 ] \
      && ordered "$vb" "$VPN_CALL" 'String pkg = pkgs.get(idx);' 'String lock = vpnPickLockdown(current, pkg);' \
           'writeVpnPick(pkg, lock)' 'showSecurity();' '});'; } \
    || { echo "  FAIL  S4 showVpnPicker does not write through writeVpnPick(pkg, lock) inside the picker lambda" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# check_all <SecuritySheets.java> <ProfileActivity.java> -> 0 when the cases and every pin pass, 1 when one fails, 3
# when the classes did not compile.
check_all() {
  local rc
  suite "$1"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$2" || rc=1
  return "$rc"
}

echo "== SecuritySheets, showWipePicker, showVpnPicker"
check_all "$SHEETS" "$PA"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases C1-C6 + pins S1-S4"
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
    sheets) out=$(check_all "$c" "$PA" 2>&1); rc=$? ;;
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

# mut_cancel <label> -> a .setNegativeButton("Cancel" builder put back into showVpnPicker, in a copy of the whole
# source dir. CONVICTED only when S1 fails on the copy AND test-popup-rules.sh reports it as NEW.
mut_cancel() {
  local d c out rc lint lrc
  d=$(mktemp -d -p "$W") || return 1
  c="$d/src"
  mkdir -p "$c"
  cp "$SRC"/*.java "$c/"
  if ! perl -0pi -e 's/(\n)(        SheetDialog\.picker\(this, SecuritySheets\.vpn\()/$1        new android.app.AlertDialog.Builder(this).setTitle("Always-on VPN").setNegativeButton("Cancel", (d, w) -> showSecurity()).show();\n$2/' "$c/ProfileActivity.java"; then
    echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1
  fi
  if cmp -s "$PA" "$c/ProfileActivity.java"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(pins "$c/ProfileActivity.java" 2>&1); rc=$?
  lint=$(TMPDIR="$W" SRC_DIR="$c" bash "$LINT" 2>&1); lrc=$?
  rm -rf "$d"
  case "$out" in *"FAIL  S1 showVpnPicker holds setNegativeButton"*) ;; *)
    echo "  SURVIVED  $1 -- S1 did not fail (rc=$rc)"; return 1 ;;
  esac
  [ "$lrc" -ne 0 ] || { echo "  SURVIVED  $1 -- test-popup-rules.sh passed"; return 1; }
  case "$lint" in *NEW*) ;; *)
    echo "  WRONG     $1 -- test-popup-rules.sh failed (rc=$lrc), but not with NEW"; return 1 ;;
  esac
  echo "  convicted $1 -- FAIL  S1 showVpnPicker holds setNegativeButton, and test-popup-rules.sh NEW"
  return 0
}

fails=0
mut "M1 wipe marks every option current"            sheets "C1 wipe(0) marks only 0 current" 's/i == current\)/current >= 0)/' || fails=$((fails+1))
mut "M2 wipe's current off by one"                  sheets "C1 wipe(0) marks only 0 current" 's/WipeChoice\.LABELS\), sel\)/WipeChoice.LABELS), sel + 1)/' || fails=$((fails+1))
mut "M3 vpn ignores a negative index (marks 0)"     sheets "C4 vpn(-1) marks none"           's/cards\(VPN_TITLE, labels, current\)/cards(VPN_TITLE, labels, Math.max(0, current))/' || fails=$((fails+1))
mut "M4 a label replaced"                           sheets "C1 wipe(0) names the labels"     's/names\.get\(i\), Collections/i == 0 ? "Right away" : names.get(i), Collections/' || fails=$((fails+1))
mut "M5 showWipePicker writes outside presetGuard"  pa     "S3 showWipePicker"               's/\n *if \(writeWipePref\(idx\)\) live = sendLivePrefs\(\);//; s/(\n        final int sel = WipeChoice\.selected\([^\n]*)/$1\n        writeWipePref(sel);/' || fails=$((fails+1))
mut "M6 showVpnPicker passes Math.max(0, ...)"      pa     "S2 showVpnPicker"                's/SecuritySheets\.vpn\(labels, pkgs\.indexOf\(current\[0\]\)\)/SecuritySheets.vpn(labels, Math.max(0, pkgs.indexOf(current[0])))/' || fails=$((fails+1))
mut_cancel "M7 a .setNegativeButton(\"Cancel\" builder put back into showVpnPicker" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "PASS: 7 of 7 mutants convicted" || { echo "== $fails mutant(s) not convicted"; exit 1; }
