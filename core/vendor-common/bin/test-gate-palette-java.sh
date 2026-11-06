#!/usr/bin/env bash
# test-gate-palette-java.sh [--mutate] -- the gate's one palette, dark until the owner chooses light, under javac
# (NWP-20261115-15).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md (2026-10-26) gives the gate a light mode: dark on every phone until
# its owner chooses light in Owner settings, never the OS setting, and the boot frames stay black. Before this slice the
# gate drew in hard-coded colours, so a light mode meant editing every literal. GatePalette.java holds one dark set
# (today's colours) and one light set; it is pure java, compiled as-is with
# core/chooser/tests/gate-palette/GatePaletteCases.java. The cases check every DARK role is today's value, only an
# exact "light" reads LIGHT, the stored value round-trips, every LIGHT text role meets WCAG AA (4.5:1), the call
# buttons are the same in both sets, and the process starts DARK. The PINS check the wiring the cases cannot see:
# ChooserActivity holds no colour literal, applyGateLook() runs once in onCreate after the user-0 guard and before the
# first view, it reads "gate_look" through forLook and calls use(p), StatusLine's busy, error and spinner read
# GatePalette.active(), and themes.xml keeps the boot frames black.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-gate-palette-java.sh            # the cases and the pins
#   bash test-gate-palette-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ChooserActivity.java"
CLS="$SRCDIR/GatePalette.java"
SL="$SRCDIR/StatusLine.java"
THEME="$root/core/chooser/res/values/themes.xml"
CASES="$root/core/chooser/tests/gate-palette/GatePaletteCases.java"
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

# line_of <text> <fixed-string> -> "<count> <first line number>" of the lines holding the string (the string goes
# through the environment: awk -v would turn its \n into a newline)
line_of() {
  printf '%s\n' "$1" | S="$2" awk 'index($0, ENVIRON["S"]) { n++; if (!first) first=NR } END { print n+0, first+0 }'
}

# one <text> <fixed-string> <pin> -> the line number of the one line holding the string, or a failure (rc 1)
one() {
  local n l
  read -r n l <<<"$(line_of "$1" "$2")"
  [ "$n" = 1 ] || { echo "--- FAIL $3: $n lines hold: $2 -- want 1" >&2; return 1; }
  echo "$l"
}

# none_re <text> <ERE> <pin> -> rc 1 when any line matches the pattern
none_re() {
  local hits
  hits=$(printf '%s\n' "$1" | grep -nE "$2" || true)
  [ -z "$hits" ] || { echo "--- FAIL $3: $(printf "%s\n" "$hits" | wc -l) lines match $2:" >&2; printf '%s\n' "$hits" | head -5 | sed 's/^/      /' >&2; return 1; }
}

FORBIDDEN='0[xX][0-9A-Fa-f]{8}|parseColor\(|Color\.(BLACK|WHITE|GRAY|DKGRAY|LTGRAY|RED|GREEN|BLUE|YELLOW|CYAN|MAGENTA)\b'
FIELDS='BG:bg INK:ink MUTED:muted TAGLINE:tagline FIELD_BG:fieldBg FIELD_LN:fieldLn HINT:hint FIELD_TX:fieldTx
ACCENT:accent ON_ACCENT:onAccent FOOTER:footer TITLE:title HELP:help DANGER:danger ERROR_TX:error DOT_OFF:dotOff'

# cases <GatePalette.java> -> 0 pass, 1 a case failed, 3 the class or the cases did not compile
cases() {
  local d
  d=$(mktemp -d -p "$W")
  cp "$1" "$d/GatePalette.java"; cp "$CASES" "$d/GatePaletteCases.java"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$d" "$d/GatePalette.java" "$d/GatePaletteCases.java" >&2 \
    || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d" com.nowhere.chooser.GatePaletteCases >&2 || return 1
}

# suite <ChooserActivity.java> <GatePalette.java> <StatusLine.java> <themes.xml>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the class did not compile. Only 1 convicts a mutant.
suite() {
  local f="$1" cls="$2" sl="$3" theme="$4" rc x b ln lguard lpurge lview lread luse n pair fld role want fails=0
  for x in "$f" "$cls" "$sl" "$theme" "$CASES"; do [ -f "$x" ] || { echo "  missing $x" >&2; return 2; }; done
  cases "$cls"; rc=$?
  case "$rc" in 0) ;; 1) fails=1 ;; 3) echo "  the class or the cases did not compile" >&2; return 3 ;; *) return 2 ;; esac

  # P1 no colour literal anywhere in ChooserActivity, comments included.
  none_re "$(cat "$f")" "$FORBIDDEN" 'P1 a colour literal in ChooserActivity' || fails=1

  # P2 applyGateLook(); once in the file, inside onCreate, after the user-0 guard and purgeLoginResult(), before the
  # first view.
  n=$(grep -cE '^[[:space:]]*applyGateLook\(\);' "$f" || true)
  [ "$n" = 1 ] || { echo "--- FAIL P2: $n applyGateLook(); statements in $f, want 1" >&2; fails=1; }
  b=$(nocomment "$(body "$f" 'protected void onCreate(Bundle b) {')")
  if [ -z "$b" ]; then echo "--- FAIL P2: no onCreate(Bundle b) in $f" >&2; fails=1
  elif ln=$(one "$b" 'applyGateLook();' P2) && lguard=$(one "$b" 'android.os.UserHandle.myUserId() != 0' P2) \
       && lpurge=$(one "$b" 'purgeLoginResult();' P2) && lview=$(line_of "$b" 'new LinearLayout(this)'); then
    lview=${lview#* }
    [ "$ln" -gt "$lguard" ] && [ "$ln" -gt "$lpurge" ] && [ "$lview" -gt 0 ] && [ "$ln" -lt "$lview" ] || {
      echo "--- FAIL P2: order: user-0 guard at $lguard, purge at $lpurge, applyGateLook at $ln, first view at $lview" >&2
      fails=1; }
  else fails=1
  fi

  # P3 applyGateLook reads "gate_look" from nowhere_gate through forLook, calls use(p), then sets every field from p.
  b=$(nocomment "$(body "$f" 'private void applyGateLook() {')")
  if [ -z "$b" ]; then echo "--- FAIL P3: no applyGateLook() in $f" >&2; fails=1
  elif lread=$(one "$b" '        GatePalette p = GatePalette.forLook(getSharedPreferences("nowhere_gate", MODE_PRIVATE).getString(GatePalette.KEY, null));' P3) \
       && luse=$(one "$b" '        GatePalette.use(p);' P3); then
    [ "$luse" -gt "$lread" ] || { echo "--- FAIL P3: use(p) at $luse is not after the read at $lread" >&2; fails=1; }
    for pair in $FIELDS; do
      fld=${pair%%:*}; role=${pair#*:}
      n=$(printf '%s\n' "$b" | grep -cE "^[[:space:]]*${fld}[[:space:]]*= p\.${role};[[:space:]]*\$" || true)
      [ "$n" = 1 ] || { echo "--- FAIL P3: $n lines set $fld = p.$role in applyGateLook, want 1" >&2; fails=1; }
    done
  else fails=1
  fi

  # P4 every colour field is declared not final, from GatePalette.DARK (ACCENT exactly as the Go pin holds it).
  one "$(cat "$f")" '    private static int ACCENT    = GatePalette.DARK.accent;' P4 >/dev/null || fails=1
  for pair in $FIELDS; do
    fld=${pair%%:*}; role=${pair#*:}
    n=$(grep -cE "^    private static int ${fld}[[:space:]]+= GatePalette\.DARK\.${role};" "$f" || true)
    [ "$n" = 1 ] || { echo "--- FAIL P4: $n declarations of $fld from GatePalette.DARK.$role, want 1" >&2; fails=1; }
  done

  # P5 StatusLine: busy, error and the spinner read GatePalette.active(), and none of them names BUSY or ERROR.
  for x in 'static void busy(TextView tv, CharSequence text) {|sb.setSpan(new ForegroundColorSpan(GatePalette.active().accent), 1, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);' \
           'static void error(TextView tv, CharSequence text) {|sb.setSpan(new ForegroundColorSpan(GatePalette.active().error), 0, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);' \
           'Spinner(TextView host) {|arc.setColor(GatePalette.active().accent);'; do
    b=$(nocomment "$(body "$sl" "${x%%|*}")")
    want=${x#*|}
    if [ -z "$b" ]; then echo "--- FAIL P5: no ${x%%|*} in $sl" >&2; fails=1; continue; fi
    one "$b" "$want" P5 >/dev/null || fails=1
    none_re "$b" '\b(BUSY|ERROR)\b' "P5 ${x%%|*} names BUSY or ERROR" || fails=1
  done

  # P6 the boot frames stay black.
  for want in '<item name="android:windowSplashScreenBackground">#FF000000</item>' \
              '<item name="android:windowBackground">@android:color/black</item>'; do
    one "$(cat "$theme")" "$want" P6 >/dev/null || fails=1
  done

  [ "$fails" = 0 ] || return 1
  echo "  pins ok"
}

echo "== $ACT"
suite "$ACT" "$CLS" "$SL" "$THEME" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED: rc 1 with a --- FAIL line)"
fails=0
# mut <label> <target: cls|act|sl|theme> <perl-expr> [<substring the failure output must hold>]
mut() {
  local label="$1" target="$2" expr="$3" expect="${4:-}" d rc src copy
  d=$(mktemp -d -p "$W")
  cp "$ACT" "$d/ChooserActivity.java"; cp "$CLS" "$d/GatePalette.java"; cp "$SL" "$d/StatusLine.java"
  cp "$THEME" "$d/themes.xml"
  case "$target" in
    cls) src="$CLS"; copy="$d/GatePalette.java" ;;
    act) src="$ACT"; copy="$d/ChooserActivity.java" ;;
    sl) src="$SL"; copy="$d/StatusLine.java" ;;
    theme) src="$THEME"; copy="$d/themes.xml" ;;
  esac
  perl -0pi -e "$expr" "$copy"
  if cmp -s "$copy" "$src"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$d/ChooserActivity.java" "$d/GatePalette.java" "$d/StatusLine.java" "$d/themes.xml" >"$d/out" 2>&1; rc=$?
  if [ "$rc" = 1 ] && grep -q -- '--- FAIL' "$d/out" && { [ -z "$expect" ] || grep -qF -- "$expect" "$d/out"; }; then
    echo "  CONVICTED $label"
    grep -m1 -- '--- FAIL' "$d/out" | sed 's/^/      /'
  else
    echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/out" | head -5; fails=$((fails+1))
  fi
}
mut 'M1 forLook folds case' cls 's/LIGHT_VALUE\.equals\(stored\)/LIGHT_VALUE.equalsIgnoreCase(stored)/' 'forLook LIGHT'
mut 'M2 forLook(null) returns LIGHT' cls 's/return LIGHT_VALUE\.equals\(stored\) \?/return stored == null || LIGHT_VALUE.equals(stored) ?/' 'forLook null'
mut 'M3 DARK.accent one unit off' cls 's/(accent\s*= light \? 0xFF087658 : )0xFF4FD6AC/${1}0xFF4FD6AD/' 'DARK accent'
mut 'M4 LIGHT.muted fails contrast' cls 's/(muted\s*= light \? )0xFF5A6878/${1}0xFF9AA3AD/' 'contrast muted'
mut 'M5 the onCreate call removed' act 's/\n[ \t]*applyGateLook\(\);[^\n]*//' 'P2'
mut 'M6 the call moved below the first view' act 's/\n[ \t]*applyGateLook\(\);[^\n]*//; s/(LinearLayout ll = new LinearLayout\(this\);)/$1\n        applyGateLook();/' 'P2: order'
mut 'M7 emergencyLink back to its literal' act 's/emerg\.setTextColor\(DANGER\)/emerg.setTextColor(0xFFE05B5B)/' 'P1'
mut 'M8 StatusLine.error back to ERROR' sl 's/ForegroundColorSpan\(GatePalette\.active\(\)\.error\)/ForegroundColorSpan(ERROR)/' 'P5'
mut 'M9 the splash background light' theme 's/(windowSplashScreenBackground">)#FF000000/${1}#FFF6F8FA/' 'P6'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
