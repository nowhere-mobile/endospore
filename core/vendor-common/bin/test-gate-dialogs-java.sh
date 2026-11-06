#!/usr/bin/env bash
# test-gate-dialogs-java.sh [--mutate] -- the gate's dialogs and the QR scan screen follow its look, under javac
# (NWP-20261117-35).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md (2026-10-26) gives the gate a light mode like the storefront's, and
# its CLOSES WHEN asks every gate screen to draw from one palette with no colour literal outside it. NWP-20261115-15/-16
# built the palette and the switch, but every new AlertDialog.Builder(this) still resolved android:alertDialogTheme
# from the dark Theme.Nowhere, so on a light gate every confirmation, help sheet and refusal opened dark; and
# QrScanActivity drew three colour literals. Now themes.xml holds GateDialogLight (the platform's light alert dialog
# with GatePalette.LIGHT.accent) and GateLightDialogs (only alertDialogTheme, naming it); applyGateLook overlays
# GateLightDialogs on the gate's theme under p.lightBars, directly before applyGateBars; dialogContext() gives the two
# dialogs that build their own views (the time picker and the notice lines) the dialog's theme; and QrScanActivity
# reads three GatePalette roles that keep a camera's dark surround in both looks.
# The CASES (core/chooser/tests/gate-dialogs/GateDialogCases.java, compiled with GatePalette.java as-is) check the three
# roles equal the old literals in both sets and that the hint meets WCAG AA. The PINS check the wiring the cases cannot
# see: T1-T4 themes.xml (both styles, the overlay names the light dialog, its accent equals the LIGHT accent, the boot
# frames stay black), T5 applyGateLook, T6 no colour literal in QrScanActivity, T7-T9 the dialog-themed views.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-gate-dialogs-java.sh            # the cases and the pins
#   bash test-gate-dialogs-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ChooserActivity.java"
CLS="$SRCDIR/GatePalette.java"
QR="$SRCDIR/QrScanActivity.java"
THEME="$root/core/chooser/res/values/themes.xml"
CASES="$root/core/chooser/tests/gate-dialogs/GateDialogCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl" >&2; exit 2; }

# body <file> <signature-substring> -> the member from its signature line to the brace that closes it
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# nocomment <text> -> the text without its // comment lines, its /* */ lines and its trailing " // " comments
nocomment() {
  printf '%s\n' "$1" | awk '
    { s=$0; sub(/^[ \t]+/, "", s) }
    s ~ /^(\/\/|\*|\/\*)/ { next }
    { i=index($0, " // "); if (i) $0=substr($0, 1, i-1); print }'
}

# strip_java <file> -> the source without its comments, string- and char-literal aware (as core/chooser/tests/qrscan)
strip_java() { perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|/\*.*?\*/|//[^\n]*}{defined $1 ? $1 : ""}gse' "$1"; }

# line_of <text> <fixed-string> -> "<count> <first line number>" of the lines holding the string (the string goes
# through the environment: awk -v would turn its \n into a newline)
line_of() {
  printf '%s\n' "$1" | S="$2" awk 'index($0, ENVIRON["S"]) { n++; if (!first) first=NR } END { print n+0, first+0 }'
}

# count <text> <fixed-string> -> how many lines hold the string
count() {
  local n l
  read -r n l <<<"$(line_of "$1" "$2")"
  echo "$n"
}

# one <text> <fixed-string> <pin> -> the line number of the one line holding the string, or a failure (rc 1)
one() {
  local n l
  read -r n l <<<"$(line_of "$1" "$2")"
  [ "$n" = 1 ] || { echo "--- FAIL $3: $n lines hold: $2 -- want 1" >&2; return 1; }
  echo "$l"
}

# none <text> <fixed-string> <pin> -> rc 1 when any line holds the string
none() {
  local n
  n=$(count "$1" "$2")
  [ "$n" = 0 ] || { echo "--- FAIL $3: $n lines hold: $2 -- want 0" >&2; return 1; }
}

# none_re <text> <ERE> <pin> -> rc 1 when any line matches the pattern
none_re() {
  local hits
  hits=$(printf '%s\n' "$1" | grep -nE "$2" || true)
  [ -z "$hits" ] || { echo "--- FAIL $3: $(printf "%s\n" "$hits" | wc -l) lines match $2:" >&2; printf '%s\n' "$hits" | head -5 | sed 's/^/      /' >&2; return 1; }
}

# style <themes.xml> <name> -> the style block from its <style name="<name>" line to its </style>
style() {
  awk -v open="<style name=\"$2\"" '
    !on && index($0, open) { on=1 }
    on { print; if (index($0, "</style>")) exit }
  ' "$1"
}

# nth <text> <n> -> line n of the text, its leading space trimmed
nth() {
  printf '%s\n' "$1" | awk -v n="$2" 'NR == n { sub(/^[ \t]+/, ""); print; exit }'
}

# The same pattern as test-gate-palette-java.sh P1.
FORBIDDEN='0[xX][0-9A-Fa-f]{8}|parseColor\(|Color\.(BLACK|WHITE|GRAY|DKGRAY|LTGRAY|RED|GREEN|BLUE|YELLOW|CYAN|MAGENTA)\b'
APPLY='if (p.lightBars) getTheme().applyStyle(R.style.GateLightDialogs, true);'

# cases <GatePalette.java> -> 0 pass, 1 a case failed, 3 the class or the cases did not compile
cases() {
  local d
  d=$(mktemp -d -p "$W")
  cp "$1" "$d/GatePalette.java"; cp "$CASES" "$d/GateDialogCases.java"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$d" "$d/GatePalette.java" "$d/GateDialogCases.java" >&2 \
    || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d" com.nowhere.chooser.GateDialogCases >&2 || return 1
}

# suite <ChooserActivity.java> <GatePalette.java> <QrScanActivity.java> <themes.xml>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the class or the cases did not compile. Every pin runs
# even when the cases did not compile. Only 1 convicts a mutant.
suite() {
  local f="$1" cls="$2" qr="$3" theme="$4" rc x b n hex got want fails=0 nocomp=0
  for x in "$f" "$cls" "$qr" "$theme" "$CASES"; do [ -f "$x" ] || { echo "  missing $x" >&2; return 2; }; done
  cases "$cls"; rc=$?
  case "$rc" in 0) ;; 1) fails=1 ;; 3) echo "  the class or the cases did not compile" >&2; nocomp=1 ;; *) return 2 ;; esac

  # T1 both styles, once each.
  one "$(cat "$theme")" '<style name="GateDialogLight" parent="@android:style/Theme.Material.Light.Dialog.Alert">' T1 \
    >/dev/null || fails=1
  one "$(cat "$theme")" '<style name="GateLightDialogs">' T1 >/dev/null || fails=1

  # T2 GateLightDialogs holds exactly one item: alertDialogTheme naming GateDialogLight.
  b=$(style "$theme" GateLightDialogs)
  n=$(count "$b" '<item ')
  [ "$n" = 1 ] || { echo "--- FAIL T2: GateLightDialogs holds $n items, want 1" >&2; fails=1; }
  one "$b" '<item name="android:alertDialogTheme">@style/GateDialogLight</item>' T2 >/dev/null || fails=1

  # T3 GateDialogLight's colorAccent is GatePalette.LIGHT.accent.
  hex=$(perl -ne 'print $1 if /^\s*accent\s*= light \? 0x([0-9A-Fa-f]{8}) :/' "$cls")
  got=$(style "$theme" GateDialogLight | perl -ne 'print $1 if /<item name="android:colorAccent">(#[0-9A-Fa-f]{8})<\/item>/')
  if [ -z "$hex" ]; then echo "--- FAIL T3: no LIGHT accent read from $cls" >&2; fails=1
  else
    want="#$(printf '%s' "$hex" | tr 'a-f' 'A-F')"
    got=$(printf '%s' "$got" | tr 'a-f' 'A-F')
    [ "$got" = "$want" ] || { echo "--- FAIL T3: GateDialogLight colorAccent is '$got', want $want (GatePalette.LIGHT.accent)" >&2; fails=1; }
  fi

  # T4 the boot frames stay black (as test-gate-palette-java.sh P6).
  for want in '<item name="android:windowSplashScreenBackground">#FF000000</item>' \
              '<item name="android:windowBackground">@android:color/black</item>'; do
    one "$(cat "$theme")" "$want" T4 >/dev/null || fails=1
  done

  # T5 applyGateLook: the applyStyle line once, under p.lightBars, directly before its last statement applyGateBars.
  b=$(nocomment "$(body "$f" 'private void applyGateLook() {')")
  if [ -z "$b" ]; then echo "--- FAIL T5: no applyGateLook() in $f" >&2; fails=1
  else
    one "$b" "$APPLY" T5 >/dev/null || fails=1
    n=$(count "$b" 'applyStyle(')
    [ "$n" = 1 ] || { echo "--- FAIL T5: $n applyStyle( lines in applyGateLook, want 1" >&2; fails=1; }
    n=$(printf '%s\n' "$b" | wc -l)
    [ "$(nth "$b" "$n")" = '}' ] && [ "$(nth "$b" $((n-1)))" = 'applyGateBars(getWindow(), p);' ] \
      && [ "$(nth "$b" $((n-2)))" = "$APPLY" ] || {
        echo "--- FAIL T5: applyGateLook does not end with: $APPLY / applyGateBars(getWindow(), p); (got: $(nth "$b" $((n-2))) / $(nth "$b" $((n-1))))" >&2
        fails=1; }
  fi

  # T6 QrScanActivity holds no colour literal and no Color. constant, and draws from the three active() roles.
  b=$(strip_java "$qr")
  none_re "$b" "$FORBIDDEN" 'T6 a colour literal in QrScanActivity' || fails=1
  none_re "$b" '\bColor\.' 'T6 a Color. constant in QrScanActivity' || fails=1
  for want in 'GatePalette.active()' 'root.setBackgroundColor(pal.scanBg);' 'hint.setTextColor(pal.scanInk);' \
              'hint.setShadowLayer(8, 0, 0, pal.scanShadow);'; do
    one "$b" "$want" T6 >/dev/null || fails=1
  done

  # T7 showNoticePopup builds each notice line in the dialog's theme.
  b=$(nocomment "$(body "$f" 'private void showNoticePopup() {')")
  if [ -z "$b" ]; then echo "--- FAIL T7: no showNoticePopup() in $f" >&2; fails=1
  else
    one "$b" 'final Context dc = dialogContext();' T7 >/dev/null || fails=1
    one "$b" 'TextView line = new TextView(dc);' T7 >/dev/null || fails=1
    none "$b" 'TextView line = new TextView(this);' T7 || fails=1
  fi

  # T8 showOtaTimePicker builds its TimePicker in the dialog's theme.
  b=$(nocomment "$(body "$f" 'private void showOtaTimePicker(')")
  if [ -z "$b" ]; then echo "--- FAIL T8: no showOtaTimePicker( in $f" >&2; fails=1
  else
    one "$b" 'new android.widget.TimePicker(dialogContext());' T8 >/dev/null || fails=1
    none "$b" 'TimePicker(this)' T8 || fails=1
  fi

  # T9 dialogContext resolves alertDialogTheme from the activity's theme, as AlertDialog.Builder(this) does.
  one "$(cat "$f")" 'private Context dialogContext() {' T9 >/dev/null || fails=1
  b=$(nocomment "$(body "$f" 'private Context dialogContext() {')")
  if [ -z "$b" ]; then echo "--- FAIL T9: no dialogContext() in $f" >&2; fails=1
  else
    one "$b" 'getTheme().resolveAttribute(android.R.attr.alertDialogTheme, tv, true);' T9 >/dev/null || fails=1
    one "$b" 'return new android.view.ContextThemeWrapper(this, tv.resourceId);' T9 >/dev/null || fails=1
  fi

  [ "$nocomp" = 0 ] || return 3
  [ "$fails" = 0 ] || return 1
  echo "  pins ok"
}

echo "== $ACT"
suite "$ACT" "$CLS" "$QR" "$THEME" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED: rc 1 with a --- FAIL line)"
fails=0
# mut <label> <target: cls|act|qr|theme> <perl-expr> <substring the failure output must hold>
mut() {
  local label="$1" target="$2" expr="$3" expect="$4" d rc src copy
  d=$(mktemp -d -p "$W")
  cp "$ACT" "$d/ChooserActivity.java"; cp "$CLS" "$d/GatePalette.java"; cp "$QR" "$d/QrScanActivity.java"
  cp "$THEME" "$d/themes.xml"
  case "$target" in
    cls) src="$CLS"; copy="$d/GatePalette.java" ;;
    act) src="$ACT"; copy="$d/ChooserActivity.java" ;;
    qr) src="$QR"; copy="$d/QrScanActivity.java" ;;
    theme) src="$THEME"; copy="$d/themes.xml" ;;
  esac
  perl -0pi -e "$expr" "$copy"
  if cmp -s "$copy" "$src"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$d/ChooserActivity.java" "$d/GatePalette.java" "$d/QrScanActivity.java" "$d/themes.xml" >"$d/out" 2>&1; rc=$?
  if [ "$rc" = 1 ] && grep -q -- '--- FAIL' "$d/out" && grep -qF -- "$expect" "$d/out"; then
    echo "  CONVICTED $label"
    grep -m1 -F -- "$expect" "$d/out" | sed 's/^/      /'
  else
    echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/out" | head -5; fails=$((fails+1))
  fi
}
mut 'M1 applyStyle without the lightBars test' act 's/if \(p\.lightBars\) (getTheme\(\)\.applyStyle)/$1/' 'T5'
mut 'M2 the applyStyle line removed' act 's/\n[ \t]*if \(p\.lightBars\) getTheme\(\)\.applyStyle[^\n]*//' 'T5'
mut 'M3 GateDialogLight accent changed' theme 's/(colorAccent">)#FF087658/${1}#FF087659/' 'T3'
mut 'M4 alertDialogTheme names the dark platform dialog' theme 's/(alertDialogTheme">)\@style\/GateDialogLight/${1}\@android:style\/Theme.Material.Dialog.Alert/' 'T2'
mut 'M5 the QR background back to its literal' qr 's/root\.setBackgroundColor\(pal\.scanBg\)/root.setBackgroundColor(0xFF0B0F14)/' 'T6'
mut 'M6 LIGHT scanBg made light' cls 's/scanBg(\s*)= 0xFF0B0F14;/scanBg$1= light ? 0xFFF6F8FA : 0xFF0B0F14;/' 'LIGHT scanBg'
mut 'M7 the notice line back to the activity theme' act 's/TextView line = new TextView\(dc\);/TextView line = new TextView(this);/' 'T7'
mut 'M8 the TimePicker back to the activity theme' act 's/new android\.widget\.TimePicker\(dialogContext\(\)\)/new android.widget.TimePicker(this)/' 'T8'
mut 'M9 dialogContext resolves dialogTheme' act 's/android\.R\.attr\.alertDialogTheme, tv/android.R.attr.dialogTheme, tv/' 'T9'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
