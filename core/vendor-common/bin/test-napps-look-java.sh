#!/usr/bin/env bash
# test-napps-look-java.sh [--mutate] -- nApps and the two in-session chooser dialogs draw in the gate's light/dark
# look, under javac (NWP-20261117-31).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md (2026-10-29, "Profile and nApps follow the gate's light/dark look")
# puts nApps in the gate's one device-wide look; its inference puts MaterializingActivity and PlayFetchAskActivity
# there too. ChooserActivity.mirrorGateLook() copies the owner's choice into the Global setting
# GatePalette.GLOBAL_KEY (NWP-20261117-21). The two dialogs read it through GatePalette.forLook. nApps depends on the
# chooser for DATA ONLY (no classpath, no resource, no socket, no INTERNET), so NappsLook restates the key and holds
# its own two palettes; a Settings.Global read is data. The CASES compile NappsLook.java as-is with
# core/napps/tests/napps-look/NappsLookCases.java: the key, light() only for exactly "light", DARK unchanged, each
# LIGHT text role 4.5:1 on the LIGHT bg. The PINS check what the cases cannot see: NappsLook.GLOBAL_KEY equals
# GatePalette.GLOBAL_KEY; StoreActivity reads the key before super.onCreate, takes the light theme only in light mode,
# applies the look before its first view, holds no colour literal, no LocalSocket and no INTERNET permission;
# MaterializingActivity and PlayFetchAskActivity read GatePalette.GLOBAL_KEY before super.onCreate and take the light
# dialog theme only in light mode; MaterializingActivity's spinner takes look.accent, not StatusLine.BUSY.
#
# Exit codes: 0 pass, 1 a case or a pin failed (or a mutant survived), 2 a source is missing or no javac. A cases
# compile failure does not stop the pins: they still run, and the suite then fails.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-napps-look-java.sh            # the cases and the pins
#   bash test-napps-look-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
CSRC="$root/core/chooser/src/com/nowhere/chooser"
NSRC="$root/core/napps/src/com/nowhere/napps"
NL="$NSRC/NappsLook.java"
SA="$NSRC/StoreActivity.java"
MA="$CSRC/MaterializingActivity.java"
PF="$CSRC/PlayFetchAskActivity.java"
GP="$CSRC/GatePalette.java"
MAN="$root/core/napps/AndroidManifest.xml"
CASES="$root/core/napps/tests/napps-look/NappsLookCases.java"
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

# key_of <file> -> the literal of the one `static final String GLOBAL_KEY = "...";` line, or empty
key_of() {
  local hits n
  hits=$(nocomment "$(cat "$1")" | sed -nE 's/^[[:space:]]*static final String GLOBAL_KEY = "([^"]*)";[[:space:]]*$/\1/p')
  n=$(printf '%s' "$hits" | grep -c '^' || true)
  [ "$n" = 1 ] && printf '%s' "$hits"
}

FORBIDDEN='0[xX][0-9A-Fa-f]{8}|parseColor\(|Color\.(BLACK|WHITE|GRAY|DKGRAY|LTGRAY|RED|GREEN|BLUE|YELLOW|CYAN|MAGENTA)\b'
SFIELDS='BG:bg INK:ink MUTED:muted ACCENT:accent WARN:warn'
SREAD='NappsLook.light(android.provider.Settings.Global.getString(getContentResolver(), NappsLook.GLOBAL_KEY))'
STHEME='        if (light) setTheme(android.R.style.Theme_Material_Light_NoActionBar);'
GREAD='GatePalette.forLook(android.provider.Settings.Global.getString(getContentResolver(), GatePalette.GLOBAL_KEY))'
GTHEME='        if (look == GatePalette.LIGHT) setTheme(android.R.style.Theme_Material_Light_Dialog_NoActionBar);'

# cases <NappsLook.java> -> 0 pass, 1 a case failed, 3 the class or the cases did not compile
cases() {
  local d
  d=$(mktemp -d -p "$W")
  cp "$1" "$d/NappsLook.java"; cp "$CASES" "$d/NappsLookCases.java"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$d" "$d/NappsLook.java" "$d/NappsLookCases.java" >&2 \
    || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d" com.nowhere.napps.NappsLookCases >&2 || return 1
}

# read_before <file> <read> <theme line> <pin> -> rc 1 unless onCreate(Bundle b) holds the read and the one setTheme
# line, both before the one super.onCreate(b); echoes the super.onCreate line number on success
read_before() {
  local f="$1" rd="$2" th="$3" pin="$4" b lsuper lread n l ltheme bad=0
  b=$(nocomment "$(body "$f" 'protected void onCreate(Bundle b) {')")
  [ -n "$b" ] || { echo "--- FAIL ${pin}: no onCreate(Bundle b) in $f" >&2; return 1; }
  lsuper=$(one "$b" 'super.onCreate(b);' "$pin") || return 1
  if lread=$(one "$b" "$rd" "$pin"); then
    [ "$lread" -lt "$lsuper" ] || {
      echo "--- FAIL ${pin}: the look is read at $lread, not before super.onCreate at $lsuper" >&2; bad=1; }
  else bad=1
  fi
  n=$(printf '%s\n' "$b" | grep -c 'setTheme(' || true)
  if [ "$n" != 1 ]; then echo "--- FAIL ${pin} theme: $n setTheme( lines in onCreate, want 1" >&2; bad=1
  else
    l=$(printf '%s\n' "$b" | grep 'setTheme(' || true)
    ltheme=$(line_of "$b" 'setTheme('); ltheme=${ltheme#* }
    [ "$l" = "$th" ] || { echo "--- FAIL ${pin} theme: the setTheme line is not under the light test: '$l'" >&2; bad=1; }
    [ "$ltheme" -lt "$lsuper" ] || {
      echo "--- FAIL ${pin} theme: setTheme at $ltheme is not before super.onCreate at $lsuper" >&2; bad=1; }
  fi
  [ "$bad" = 0 ] || return 1
  echo "$lsuper"
}

# suite <NappsLook.java> <StoreActivity.java> <MaterializingActivity.java> <PlayFetchAskActivity.java>
#       <GatePalette.java> <napps AndroidManifest.xml>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the class or the cases did not compile (the pins
# still ran). Only 1 convicts a mutant.
suite() {
  local nl="$1" sa="$2" ma="$3" pf="$4" gp="$5" man="$6" rc x b n pair fld role nocompile=no fails=0
  local kn kg lsuper lapply lui lret lbar
  for x in "$nl" "$sa" "$ma" "$pf" "$gp" "$man" "$CASES"; do [ -f "$x" ] || { echo "  missing $x" >&2; return 2; }; done
  cases "$nl"; rc=$?
  case "$rc" in
    0) ;;
    1) fails=1 ;;
    3) echo "  the class or the cases did not compile; the pins still run" >&2; nocompile=yes ;;
    *) return 2 ;;
  esac

  # N1 nApps restates the key; it must be GatePalette's, byte for byte (both literals read from source).
  kn=$(key_of "$nl"); kg=$(key_of "$gp")
  if [ -z "$kn" ] || [ -z "$kg" ]; then
    echo "--- FAIL N1: no single GLOBAL_KEY literal (NappsLook: '$kn', GatePalette: '$kg')" >&2; fails=1
  elif [ "$kn" != "$kg" ]; then
    echo "--- FAIL N1: NappsLook.GLOBAL_KEY '$kn' is not GatePalette.GLOBAL_KEY '$kg'" >&2; fails=1
  fi

  # S1 StoreActivity draws no colour from a literal: every colour comes from NappsLook.
  none_re "$(nocomment "$(cat "$sa")")" "$FORBIDDEN" 'S1 a colour literal in StoreActivity' || fails=1

  # S2/S3 onCreate reads the key through NappsLook.light and takes the light theme only in light mode, both before
  # super.onCreate.
  lsuper=$(read_before "$sa" "$SREAD" "$STHEME" 'S2') || { lsuper=0; fails=1; }

  # S4 applyLook(light) after super.onCreate and before the first view.
  b=$(nocomment "$(body "$sa" 'protected void onCreate(Bundle b) {')")
  if [ -n "$b" ] && lapply=$(one "$b" '        applyLook(light);' S4) \
     && lui=$(one "$b" '        setContentView(buildUi());' S4); then
    [ "$lsuper" -gt 0 ] && [ "$lapply" -gt "$lsuper" ] && [ "$lapply" -lt "$lui" ] || {
      echo "--- FAIL S4: order: super.onCreate at $lsuper, applyLook at $lapply, setContentView at $lui" >&2; fails=1; }
  else fails=1
  fi

  # S5 applyLook sets every field from the chosen set; dark returns before any bar call; light sets both bar flags.
  b=$(nocomment "$(body "$sa" 'private void applyLook(boolean light) {')")
  if [ -z "$b" ]; then
    echo "--- FAIL S5: no applyLook(boolean light) in $sa" >&2; fails=1
  else
    one "$b" 'NappsLook p = light ? NappsLook.LIGHT : NappsLook.DARK;' S5 >/dev/null || fails=1
    for pair in $SFIELDS; do
      fld=${pair%%:*}; role=${pair#*:}
      n=$(printf '%s\n' "$b" | grep -cE "^[[:space:]]*${fld}[[:space:]]*= p\.${role};[[:space:]]*\$" || true)
      [ "$n" = 1 ] || { echo "--- FAIL S5: $n lines set $fld = p.$role in applyLook, want 1" >&2; fails=1; }
    done
    if lret=$(one "$b" 'if (!light) return;' S5) && lbar=$(one "$b" 'setStatusBarColor(p.bg)' S5); then
      [ "$lret" -lt "$lbar" ] || { echo "--- FAIL S5: the dark return at $lret is not before the bar call at $lbar" >&2; fails=1; }
    else fails=1
    fi
    for x in 'setNavigationBarColor(p.bg)' 'APPEARANCE_LIGHT_STATUS_BARS' 'APPEARANCE_LIGHT_NAVIGATION_BARS'; do
      one "$b" "$x" S5 >/dev/null || fails=1
    done
  fi

  # S6 the five fields are not final, and start from the dark set.
  for pair in $SFIELDS; do
    fld=${pair%%:*}; role=${pair#*:}
    n=$(grep -cE "^    static int ${fld}[[:space:]]+= NappsLook\.DARK\.${role};\$" "$sa" || true)
    [ "$n" = 1 ] || { echo "--- FAIL S6: $n declarations of $fld from NappsLook.DARK.$role, want 1" >&2; fails=1; }
  done
  n=$(grep -cE 'static final int (BG|INK|MUTED|ACCENT|WARN)\b' "$sa" || true)
  [ "$n" = 0 ] || { echo "--- FAIL S6: $n colour fields are still final" >&2; fails=1; }

  # S7 the data-only split holds: no socket in StoreActivity, no INTERNET permission in the nApps manifest.
  none_re "$(nocomment "$(cat "$sa")")" 'LocalSocket' 'S7 a LocalSocket in StoreActivity' || fails=1
  none_re "$(cat "$man")" 'uses-permission[^>]*android\.permission\.INTERNET' 'S7 INTERNET in the nApps manifest' \
    || fails=1

  # M1/M2 MaterializingActivity; P1/P2 PlayFetchAskActivity: the Global key through forLook, then the light dialog
  # theme only in light mode, both before super.onCreate.
  read_before "$ma" "$GREAD" "$GTHEME" 'M1' >/dev/null || fails=1
  read_before "$pf" "$GREAD" "$GTHEME" 'P1' >/dev/null || fails=1

  # M3 the spinner takes the look's accent, not the dark set's StatusLine.BUSY.
  b=$(nocomment "$(cat "$ma")")
  none_re "$b" 'StatusLine\.BUSY\b' 'M3 StatusLine.BUSY in MaterializingActivity' || fails=1
  one "$b" 'spin.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(look.accent));' M3 >/dev/null \
    || fails=1

  [ "$nocompile" = yes ] && return 3
  [ "$fails" = 0 ] || return 1
  echo "  pins ok"
}

echo "== $SA, $MA, $PF"
suite "$NL" "$SA" "$MA" "$PF" "$GP" "$MAN"; rc=$?
case "$rc" in
  0) ;;
  1|3) echo "FAILED"; exit 1 ;;
  *) echo "FAILED (rc $rc)"; exit 2 ;;
esac
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED: rc 1 with a --- FAIL line)"
fails=0
total=0
# mut <label> <target: nl|sa|ma|pf> <perl-expr> [<substring the failure output must hold>]
mut() {
  local label="$1" target="$2" expr="$3" expect="${4:-}" d rc src copy
  total=$((total+1))
  d=$(mktemp -d -p "$W")
  cp "$NL" "$d/NappsLook.java"; cp "$SA" "$d/StoreActivity.java"; cp "$MA" "$d/MaterializingActivity.java"
  cp "$PF" "$d/PlayFetchAskActivity.java"; cp "$GP" "$d/GatePalette.java"; cp "$MAN" "$d/AndroidManifest.xml"
  case "$target" in
    nl) src="$NL"; copy="$d/NappsLook.java" ;;
    sa) src="$SA"; copy="$d/StoreActivity.java" ;;
    ma) src="$MA"; copy="$d/MaterializingActivity.java" ;;
    pf) src="$PF"; copy="$d/PlayFetchAskActivity.java" ;;
  esac
  perl -0pi -e "$expr" "$copy"
  if cmp -s "$copy" "$src"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$d/NappsLook.java" "$d/StoreActivity.java" "$d/MaterializingActivity.java" "$d/PlayFetchAskActivity.java" \
    "$d/GatePalette.java" "$d/AndroidManifest.xml" >"$d/out" 2>&1
  rc=$?
  if [ "$rc" = 1 ] && grep -q -- '--- FAIL' "$d/out" && { [ -z "$expect" ] || grep -qF -- "$expect" "$d/out"; }; then
    echo "  CONVICTED $label"
    grep -m1 -- '--- FAIL' "$d/out" | sed 's/^/      /'
  else
    echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/out" | head -5; fails=$((fails+1))
  fi
}
mut 'X1 StoreActivity setTheme without the light test' sa 's/if \(light\) setTheme\(/setTheme(/' 'S2 theme'
mut 'X2 StoreActivity reads the look after setContentView' sa 's/(\n[ \t]*light = NappsLook\.light\([^\n]*)(.*?setContentView\(buildUi\(\)\);)/$2$1/s' 'S2'
mut 'X3 a DARK value changed' nl 's/0xFF8FA3A6/0xFF8FA3A7/' 'D1 DARK muted'
mut 'X4 LIGHT warn below 4.5:1' nl 's/(warn\s*= light \? )0xFF8A5A00/${1}0xFFC08A2E/' 'A1 LIGHT warn'
mut "X5 NappsLook's key misspelt" nl 's/"nowhere\.gate_look"/"nowhere.gate_lok"/' 'N1'
mut "X6 MaterializingActivity's read removed" ma 's/\n[ \t]*look = GatePalette\.forLook\([^\n]*//' 'M1'
mut "X7 PlayFetchAskActivity's setTheme unconditional" pf 's/if \(look == GatePalette\.LIGHT\) setTheme\(/setTheme(/' 'P1 theme'
mut 'X8 a StoreActivity field back to a literal' sa 's/static int BG     = NappsLook\.DARK\.bg;/static int BG     = 0xFF0E1214;/' 'S1'
mut 'X9 the spinner back on StatusLine.BUSY' ma 's/valueOf\(look\.accent\)/valueOf(StatusLine.BUSY)/' 'M3'
mut 'X10 applyLook removed from onCreate' sa 's/\n[ \t]*applyLook\(light\);//' 'S4'
echo "--mutate: $((total - fails))/$total convicted"
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
