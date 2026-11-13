#!/usr/bin/env bash
# test-gate-switch-java.sh [--mutate] -- in light mode the gate's switches meet 3:1 when off, under javac
# (NWP-20261117-29).
#
# WHY THIS IS COMMITTED. docs/backlog.md section C, "In light mode the gate's switches all but vanish when off": on
# lynx 2026102901 an off switch drew its track at 1.02:1 and its knob at 1.84:1 against the light page, because no
# switch set a tint and each took the dark Theme.Nowhere's colours. WCAG 2.1 1.4.11 asks 3:1 of the parts that show a
# control's state. GatePalette.java now holds four switch roles; it is pure java, compiled as-is with
# core/chooser/tests/gate-switch/GateSwitchCases.java. The cases check each LIGHT knob meets 3:1 on bg and on fieldBg,
# on and off differ, and the existing DARK roles are unchanged. GateSwitch.java uses android.*, so the PINS check it
# by source: its first statement returns for a dark palette, it sets both tint lists from the switch roles, and it
# holds no colour literal. They also check that every Switch ChooserActivity (8) and ProfileActivity (6) builds goes
# through GateSwitch.style(..., GatePalette.active()), and that ChooserActivity holds no colour literal.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-gate-switch-java.sh            # the cases and the pins
#   bash test-gate-switch-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ChooserActivity.java"
PROF="$SRCDIR/ProfileActivity.java"
CLS="$SRCDIR/GatePalette.java"
GS="$SRCDIR/GateSwitch.java"
CASES="$root/core/chooser/tests/gate-switch/GateSwitchCases.java"
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

# count <text> <fixed-string> -> how many times the string occurs (occurrences, not lines)
count() {
  printf '%s' "$1" | S="$2" perl -0ne '$n = () = /\Q$ENV{S}\E/g; print $n + 0'
}

FORBIDDEN='0[xX][0-9A-Fa-f]{8}|parseColor\(|Color\.(BLACK|WHITE|GRAY|DKGRAY|LTGRAY|RED|GREEN|BLUE|YELLOW|CYAN|MAGENTA)\b'
BARE='new android.widget.Switch(this)'
WRAPPED='GateSwitch.style(new android.widget.Switch(this), GatePalette.active())'

# wrapped <file> <pin> <want> -> rc 1 unless the file (comments stripped) builds <want> switches, each one wrapped
wrapped() {
  local t nb nw
  t=$(nocomment "$(cat "$1")")
  nb=$(count "$t" "$BARE"); nw=$(count "$t" "$WRAPPED")
  [ "$nb" = "$3" ] && [ "$nw" = "$3" ] && return 0
  echo "--- FAIL $2: $(basename "$1") builds $nb switches, $nw through $WRAPPED -- want $3 and $3" >&2
  printf '%s\n' "$t" | S="$BARE" T="$WRAPPED" awk 'index($0, ENVIRON["S"]) && !index($0, ENVIRON["T"])' \
    | head -3 | sed 's/^/      /' >&2
  return 1
}

# cases <GatePalette.java> -> 0 pass, 1 a case failed, 3 the class or the cases did not compile
cases() {
  local d
  d=$(mktemp -d -p "$W")
  cp "$1" "$d/GatePalette.java"; cp "$CASES" "$d/GateSwitchCases.java"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$d" "$d/GatePalette.java" "$d/GateSwitchCases.java" >&2 \
    || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d" com.nowhere.chooser.GateSwitchCases >&2 || return 1
}

# suite <ChooserActivity.java> <ProfileActivity.java> <GatePalette.java> <GateSwitch.java>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the cases did not compile. Only 1 convicts a mutant.
suite() {
  local act="$1" prof="$2" cls="$3" gs="$4" rc x b first flat la lc ld fails=0 nocompile=0
  for x in "$act" "$prof" "$cls" "$CASES"; do [ -f "$x" ] || { echo "  missing $x" >&2; return 2; }; done
  cases "$cls"; rc=$?
  case "$rc" in 0) ;; 1) fails=1 ;; 3) echo "  the class or the cases did not compile" >&2; nocompile=1 ;; *) return 2 ;; esac

  # W1/W2 every Switch the two activities build goes through GateSwitch.style(..., GatePalette.active()).
  wrapped "$act" W1 7 || fails=1
  wrapped "$prof" W2 6 || fails=1

  # S0 GateSwitch.java exists and declares style once.
  if [ ! -f "$gs" ]; then
    echo "--- FAIL S0: no GateSwitch.java at $gs" >&2; fails=1
  elif one "$(cat "$gs")" '    static android.widget.Switch style(android.widget.Switch sw, GatePalette p) {' S0 >/dev/null; then
    b=$(nocomment "$(body "$gs" 'static android.widget.Switch style(')")
    # S1 the first statement returns the switch untouched for null or a dark palette.
    first=$(printf '%s\n' "$b" | sed -n '2p' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ "$first" = 'if (sw == null || p == null || !p.lightBars) return sw;' ] || {
      echo "--- FAIL S1: style's first statement is: $first -- want the dark return" >&2; fails=1; }
    # S2 it sets both tint lists, once each.
    for x in 'sw.setThumbTintList(' 'sw.setTrackTintList('; do
      [ "$(count "$b" "$x")" = 1 ] || { echo "--- FAIL S2: style holds $(count "$b" "$x") $x -- want 1" >&2; fails=1; }
    done
    # S3 from the switch roles, disabled first, in the order {disabled, checked, default}.
    flat=$(printf '%s' "$b" | tr '\n' ' ' | tr -s ' ')
    for x in 'new int[] {p.fieldLn, p.switchThumbOn, p.switchThumbOff}' \
             'new int[] {p.fieldLn, p.switchTrackOn, p.switchTrackOff}'; do
      [ "$(count "$flat" "$x")" = 1 ] || { echo "--- FAIL S3: style does not hold $x once" >&2; fails=1; }
    done
    b=$(nocomment "$(cat "$gs")")
    if la=$(one "$b" '{-android.R.attr.state_enabled},' S3) && lc=$(one "$b" '{android.R.attr.state_checked},' S3) \
       && ld=$(one "$b" '        {},' S3); then
      [ "$la" -lt "$lc" ] && [ "$lc" -lt "$ld" ] || {
        echo "--- FAIL S3: state order: disabled at $la, checked at $lc, default at $ld" >&2; fails=1; }
    else fails=1
    fi
  else fails=1
  fi

  # S4/S5 no colour literal in GateSwitch or ChooserActivity, comments included.
  [ -f "$gs" ] && { none_re "$(cat "$gs")" "$FORBIDDEN" 'S4 a colour literal in GateSwitch' || fails=1; }
  none_re "$(cat "$act")" "$FORBIDDEN" 'S5 a colour literal in ChooserActivity' || fails=1

  [ "$nocompile" = 0 ] || return 3
  [ "$fails" = 0 ] || return 1
  echo "  pins ok"
}

echo "== $GS"
suite "$ACT" "$PROF" "$CLS" "$GS" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED: rc 1 with a --- FAIL line)"
fails=0
# mut <label> <target: act|prof|cls|gs> <perl-expr> [<substring the failure output must hold>]
mut() {
  local label="$1" target="$2" expr="$3" expect="${4:-}" d rc src copy
  d=$(mktemp -d -p "$W")
  cp "$ACT" "$d/ChooserActivity.java"; cp "$PROF" "$d/ProfileActivity.java"; cp "$CLS" "$d/GatePalette.java"
  cp "$GS" "$d/GateSwitch.java"
  case "$target" in
    act) src="$ACT"; copy="$d/ChooserActivity.java" ;;
    prof) src="$PROF"; copy="$d/ProfileActivity.java" ;;
    cls) src="$CLS"; copy="$d/GatePalette.java" ;;
    gs) src="$GS"; copy="$d/GateSwitch.java" ;;
  esac
  perl -0pi -e "$expr" "$copy"
  if cmp -s "$copy" "$src"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$d/ChooserActivity.java" "$d/ProfileActivity.java" "$d/GatePalette.java" "$d/GateSwitch.java" >"$d/out" 2>&1; rc=$?
  if [ "$rc" = 1 ] && grep -q -- '--- FAIL' "$d/out" && { [ -z "$expect" ] || grep -qF -- "$expect" "$d/out"; }; then
    echo "  CONVICTED $label"
    grep -m1 -- '--- FAIL' "$d/out" | sed 's/^/      /'
  else
    echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/out" | head -5; fails=$((fails+1))
  fi
}
mut 'M1 the dark return removed' gs 's/\n[ \t]*if \(sw == null \|\| p == null \|\| !p\.lightBars\) return sw;//' 'S1'
mut 'M2 one ChooserActivity site unwrapped (apSw)' act 's/(apSw = )GateSwitch\.style\(new android\.widget\.Switch\(this\), GatePalette\.active\(\)\)/${1}new android.widget.Switch(this)/' 'W1'
mut 'M3 one ProfileActivity site unwrapped (the hotspot row)' prof 's/row\.addView\(GateSwitch\.style\(new android\.widget\.Switch\(this\), GatePalette\.active\(\)\),/row.addView(new android.widget.Switch(this),/' 'W2'
mut 'M4 setThumbTintList removed' gs 's/\n[ \t]*sw\.setThumbTintList\(.*?\);//s' 'S2'
mut 'M5 LIGHT switchThumbOff lightened below 3:1' cls 's/(switchThumbOff\s*= light \? )0xFF6E7781/${1}0xFF9AA3AD/' 'contrast switchThumbOff'
mut 'M6 switchThumbOn equals switchThumbOff' cls 's/(switchThumbOn\s*= light \? )0xFF087658/${1}0xFF6E7781/' 'thumb on differs'
mut 'M7 a colour literal in GateSwitch' gs 's/p\.fieldLn, p\.switchThumbOn/0xFFCDD6E0, p.switchThumbOn/' 'S4'
mut 'M8 a site styled from DARK, not active()' act 's/(ownerSw = GateSwitch\.style\(new android\.widget\.Switch\(this\), )GatePalette\.active\(\)/${1}GatePalette.DARK/' 'W1'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
