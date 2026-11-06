#!/usr/bin/env bash
# test-profile-look-java.sh [--mutate] -- the Profile screen draws in the gate's light/dark look, under javac
# (NWP-20261117-21).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md (2026-10-29, "Profile and nApps follow the gate's light/dark look")
# puts Profile and every page under it in the gate's one device-wide look. The owner's choice lives in user 0's
# "nowhere_gate" prefs, which a signed-in user's process cannot read, so before this slice ProfileActivity drew dark
# whatever the gate showed. Now ChooserActivity.mirrorGateLook() copies the choice at each gate start into the Global
# setting GatePalette.GLOBAL_KEY, and ProfileActivity reads it before its first view. The CASES compile GatePalette.java
# as-is with core/chooser/tests/profile-look/ProfileLookCases.java: the key, the new roles (panel, panelLn, warn,
# outline, qrDark, qrLight), their LIGHT contrast and withAlpha. The PINS check the wiring the cases cannot see:
# ProfileActivity holds no colour literal, onCreate reads the key through forLook before super.onCreate, takes the
# light theme only in light mode, and applies the look before the AutoLogoffGate line; applyProfileLook sets every
# field; mirrorGateLook runs off the UI thread, right after applyGateLook(), and writes only when the value differs;
# the threat-model row names the Global key.
#
# A cases compile failure does not stop the pins: they still run, and the suite then returns 3.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-profile-look-java.sh            # the cases and the pins
#   bash test-profile-look-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
PA="$SRCDIR/ProfileActivity.java"
CLS="$SRCDIR/GatePalette.java"
ACT="$SRCDIR/ChooserActivity.java"
TM="$root/docs/threat-model.md"
CASES="$root/core/chooser/tests/profile-look/ProfileLookCases.java"
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
A11Y_IDS='^    private static final int A11Y_MOVE_(UP|DOWN) = 0x7e0b000[12];$'
PFIELDS='BG:bg INK:ink MUTED:muted ACCENT:accent ON_ACCENT:onAccent FIELD_BG:fieldBg FIELD_LN:fieldLn HINT:hint
FIELD_TX:fieldTx DANGER:danger ERROR_TX:error PANEL:panel PANEL_LN:panelLn WARN:warn OUTLINE:outline'
READ='GatePalette.forLook(android.provider.Settings.Global.getString(getContentResolver(), GatePalette.GLOBAL_KEY))'
THEME_LINE='        if (look == GatePalette.LIGHT) setTheme(android.R.style.Theme_Material_Light_NoActionBar);'

# cases <GatePalette.java> -> 0 pass, 1 a case failed, 3 the class or the cases did not compile
cases() {
  local d
  d=$(mktemp -d -p "$W")
  cp "$1" "$d/GatePalette.java"; cp "$CASES" "$d/ProfileLookCases.java"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$d" "$d/GatePalette.java" "$d/ProfileLookCases.java" >&2 \
    || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d" com.nowhere.chooser.ProfileLookCases >&2 || return 1
}

# suite <ProfileActivity.java> <GatePalette.java> <ChooserActivity.java> <threat-model.md>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the class or the cases did not compile (the pins
# still ran). Only 1 convicts a mutant.
suite() {
  local pa="$1" cls="$2" act="$3" tm="$4" rc x b n l pair fld role nocompile=no fails=0
  local lread lsuper ltheme lapply lgate luse lbars lmirror lgl lthr lput lif lcatch last
  for x in "$pa" "$cls" "$act" "$tm" "$CASES"; do [ -f "$x" ] || { echo "  missing $x" >&2; return 2; }; done
  cases "$cls"; rc=$?
  case "$rc" in
    0) ;;
    1) fails=1 ;;
    3) echo "  the class or the cases did not compile; the pins still run" >&2; nocompile=yes ;;
    *) return 2 ;;
  esac

  # R1 ProfileActivity draws no colour from a literal: no FORBIDDEN match but the two A11Y action ids, and no
  # StatusLine.BUSY or StatusLine.ERROR (those are the dark set's values).
  b=$(nocomment "$(cat "$pa")" | grep -vE "$A11Y_IDS" || true)
  none_re "$b" "$FORBIDDEN" 'R1 a colour literal in ProfileActivity' || fails=1
  none_re "$b" 'StatusLine\.(BUSY|ERROR)\b' 'R1 StatusLine.BUSY or ERROR in ProfileActivity' || fails=1

  # R2-R4 onCreate: the Global key read through forLook, then the light theme only in light mode, both before
  # super.onCreate; applyProfileLook(look) after it and before the AutoLogoffGate line. Profile never reads the
  # gate's own prefs (user 0's; this process cannot).
  b=$(nocomment "$(body "$pa" 'protected void onCreate(Bundle b) {')")
  if [ -z "$b" ]; then
    echo "--- FAIL R2: no onCreate(Bundle b) in $pa" >&2; fails=1
  else
    lsuper=$(one "$b" 'super.onCreate(b);' R2) || { lsuper=0; fails=1; }
    if lread=$(one "$b" "$READ" R2); then
      [ "$lsuper" -gt 0 ] && [ "$lread" -lt "$lsuper" ] || {
        echo "--- FAIL R2: the look is read at $lread, not before super.onCreate at $lsuper" >&2; fails=1; }
    else fails=1
    fi
    n=$(printf '%s\n' "$b" | grep -c 'setTheme(' || true)
    if [ "$n" != 1 ]; then echo "--- FAIL R3: $n setTheme( lines in onCreate, want 1" >&2; fails=1
    else
      l=$(printf '%s\n' "$b" | grep 'setTheme(' || true)
      ltheme=$(line_of "$b" 'setTheme('); ltheme=${ltheme#* }
      [ "$l" = "$THEME_LINE" ] || { echo "--- FAIL R3: the setTheme line is not under look == GatePalette.LIGHT: '$l'" >&2; fails=1; }
      [ "$lsuper" -gt 0 ] && [ "$ltheme" -lt "$lsuper" ] || {
        echo "--- FAIL R3: setTheme at $ltheme is not before super.onCreate at $lsuper" >&2; fails=1; }
    fi
    if lapply=$(one "$b" '        applyProfileLook(look);' R4) && lgate=$(one "$b" 'AutoLogoffGate.honoured(' R4); then
      [ "$lsuper" -gt 0 ] && [ "$lapply" -gt "$lsuper" ] && [ "$lapply" -lt "$lgate" ] || {
        echo "--- FAIL R4: order: super.onCreate at $lsuper, applyProfileLook at $lapply, AutoLogoffGate at $lgate" >&2
        fails=1; }
    else fails=1
    fi
  fi
  none_re "$(nocomment "$(cat "$pa")")" 'getSharedPreferences\("nowhere_gate"' 'R2 Profile reads the gate prefs' || fails=1

  # R5 applyProfileLook: use(p), every field from p, and the system bars last.
  b=$(nocomment "$(body "$pa" 'private void applyProfileLook(GatePalette p) {')")
  if [ -z "$b" ]; then
    echo "--- FAIL R5: no applyProfileLook(GatePalette p) in $pa" >&2; fails=1
  else
    luse=$(one "$b" '        GatePalette.use(p);' R5) || { luse=0; fails=1; }
    for pair in $PFIELDS; do
      fld=${pair%%:*}; role=${pair#*:}
      n=$(printf '%s\n' "$b" | grep -cE "^[[:space:]]*${fld}[[:space:]]*= p\.${role};[[:space:]]*\$" || true)
      [ "$n" = 1 ] || { echo "--- FAIL R5: $n lines set $fld = p.$role in applyProfileLook, want 1" >&2; fails=1; }
    done
    n=$(printf '%s\n' "$b" | grep -c '^' || true)
    last=$(printf '%s\n' "$b" | sed -n "$((n - 1))p" | sed 's/^[[:space:]]*//')
    [ "$last" = 'ChooserActivity.applyGateBars(getWindow(), p);' ] || {
      echo "--- FAIL R5: applyProfileLook does not end with ChooserActivity.applyGateBars(getWindow(), p): '$last'" >&2
      fails=1; }
  fi

  # R6 every colour field is declared not final, from GatePalette.DARK (ACCENT exactly as the Go pin holds it).
  one "$(cat "$pa")" '    private static int ACCENT    = GatePalette.DARK.accent;' R6 >/dev/null || fails=1
  for pair in $PFIELDS; do
    fld=${pair%%:*}; role=${pair#*:}
    n=$(grep -cE "^    private static int ${fld}[[:space:]]+= GatePalette\.DARK\.${role};" "$pa" || true)
    [ "$n" = 1 ] || { echo "--- FAIL R6: $n declarations of $fld from GatePalette.DARK.$role, want 1" >&2; fails=1; }
    n=$(grep -cE "private static final int ${fld}\b" "$pa" || true)
    [ "$n" = 0 ] || { echo "--- FAIL R6: $fld is still declared final" >&2; fails=1; }
  done

  # R7 ChooserActivity calls mirrorGateLook() once, in onCreate, on the line right after applyGateLook().
  n=$(nocomment "$(cat "$act")" | grep -cE '^[[:space:]]*mirrorGateLook\(\);' || true)
  [ "$n" = 1 ] || { echo "--- FAIL R7: $n mirrorGateLook(); statements in $act, want 1" >&2; fails=1; }
  b=$(nocomment "$(body "$act" 'protected void onCreate(Bundle b) {')")
  if [ -z "$b" ]; then echo "--- FAIL R7: no onCreate(Bundle b) in $act" >&2; fails=1
  elif lmirror=$(one "$b" 'mirrorGateLook();' R7) && lgl=$(one "$b" 'applyGateLook();' R7); then
    [ "$lmirror" = $((lgl + 1)) ] || {
      echo "--- FAIL R7: mirrorGateLook() at $lmirror is not right after applyGateLook() at $lgl" >&2; fails=1; }
  else fails=1
  fi

  # R8 mirrorGateLook: the application context, a new thread, the write only when the value differs, under a catch
  # of Throwable.
  b=$(nocomment "$(body "$act" 'private void mirrorGateLook() {')")
  if [ -z "$b" ]; then
    echo "--- FAIL R8: no mirrorGateLook() in $act" >&2; fails=1
  else
    for x in 'getApplicationContext()' 'GatePalette.valueFor(GatePalette.active() == GatePalette.LIGHT)' \
             'Settings.Global.getString(cr, GatePalette.GLOBAL_KEY)'; do
      one "$b" "$x" R8 >/dev/null || fails=1
    done
    if lthr=$(one "$b" 'new Thread(' R8) && lput=$(one "$b" 'putString(' R8) \
       && lif=$(one "$b" 'if (!want.equals(old)) {' R8) && lcatch=$(one "$b" 'catch (Throwable' R8); then
      [ "$lthr" -lt "$lif" ] && [ "$lif" -lt "$lput" ] && [ "$lput" -lt "$lcatch" ] || {
        echo "--- FAIL R8: order: new Thread at $lthr, the if at $lif, putString at $lput, catch at $lcatch" >&2
        fails=1; }
    else fails=1
    fi
  fi

  # R9 the threat-model row names the Global key and its writer, and keeps the gate-look pins.
  b=$(grep -F '| `shared_prefs/nowhere_gate.xml` |' "$tm" || true)
  n=$(printf '%s' "$b" | grep -c '^' || true)
  if [ "$n" != 1 ]; then echo "--- FAIL R9: $n nowhere_gate.xml rows in $tm, want 1" >&2; fails=1
  else
    for x in '`nowhere.gate_look`' 'mirrorGateLook' '`gate_look`' 'buildGateLookScreen' 'DURABLE-EXEMPT'; do
      case "$b" in *"$x"*) ;; *) echo "--- FAIL R9: the nowhere_gate.xml row does not hold $x" >&2; fails=1 ;; esac
    done
  fi

  [ "$nocompile" = yes ] && return 3
  [ "$fails" = 0 ] || return 1
  echo "  pins ok"
}

echo "== $PA"
suite "$PA" "$CLS" "$ACT" "$TM"; rc=$?
case "$rc" in
  0) ;;
  1|3) echo "FAILED"; exit 1 ;;
  *) echo "FAILED (rc $rc)"; exit 2 ;;
esac
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED: rc 1 with a --- FAIL line)"
fails=0
# mut <label> <target: pa|cls|act|tm> <perl-expr> [<substring the failure output must hold>]
mut() {
  local label="$1" target="$2" expr="$3" expect="${4:-}" d rc src copy
  d=$(mktemp -d -p "$W")
  cp "$PA" "$d/ProfileActivity.java"; cp "$CLS" "$d/GatePalette.java"; cp "$ACT" "$d/ChooserActivity.java"
  cp "$TM" "$d/threat-model.md"
  case "$target" in
    pa) src="$PA"; copy="$d/ProfileActivity.java" ;;
    cls) src="$CLS"; copy="$d/GatePalette.java" ;;
    act) src="$ACT"; copy="$d/ChooserActivity.java" ;;
    tm) src="$TM"; copy="$d/threat-model.md" ;;
  esac
  perl -0pi -e "$expr" "$copy"
  if cmp -s "$copy" "$src"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$d/ProfileActivity.java" "$d/GatePalette.java" "$d/ChooserActivity.java" "$d/threat-model.md" >"$d/out" 2>&1
  rc=$?
  if [ "$rc" = 1 ] && grep -q -- '--- FAIL' "$d/out" && { [ -z "$expect" ] || grep -qF -- "$expect" "$d/out"; }; then
    echo "  CONVICTED $label"
    grep -m1 -- '--- FAIL' "$d/out" | sed 's/^/      /'
  else
    echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/out" | head -5; fails=$((fails+1))
  fi
}
mut 'M1 setTheme without the LIGHT test' pa 's/if \(look == GatePalette\.LIGHT\) setTheme/setTheme/' 'R3'
mut 'M2 applyProfileLook after the AutoLogoffGate return' pa 's/\n[ \t]*applyProfileLook\(look\);[^\n]*//; s/(doLogoff\(\);\n            return;\n        \})/$1\n        applyProfileLook(look);/' 'R4'
mut 'M3 Profile reads getSharedPreferences("nowhere_gate")' pa 's/android\.provider\.Settings\.Global\.getString\(getContentResolver\(\), GatePalette\.GLOBAL_KEY\)/getSharedPreferences("nowhere_gate", MODE_PRIVATE).getString(GatePalette.KEY, null)/' 'R2'
mut 'M4 planWarn back to 0xFFE0A34F' pa 's/planWarn\.setTextColor\(WARN\)/planWarn.setTextColor(0xFFE0A34F)/' 'R1'
mut 'M5 StatusLine.BUSY back' pa 's/valueOf\(ACCENT\)\); \/\/ NWP-20261007-13/valueOf(StatusLine.BUSY)); \/\/ NWP-20261007-13/' 'R1'
mut 'M6 mirrorGateLook on the UI thread' act 's/(private void mirrorGateLook\(\) \{\n[^\n]*\n[ \t]*)new Thread\(\(\) -> \{/$1\{/; s/\}, "nowhere-gate-look-mirror"\)\.start\(\);/}/' 'R8'
mut 'M7 the mirror call removed' act 's/\n[ \t]*mirrorGateLook\(\);[^\n]*//' 'R7'
mut 'M8 the write unconditional' act 's/if \(!want\.equals\(old\)\) \{/if (true) {/' 'R8'
mut 'M9 LIGHT warn below 4.5:1' cls 's/(warn\s*= light \? )0xFF8A5A00/${1}0xFFE0A34F/' 'K4'
mut 'M10 withAlpha drops the alpha' cls 's/ \| \(\(alpha & 0xFF\) << 24\)//' 'K9'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
