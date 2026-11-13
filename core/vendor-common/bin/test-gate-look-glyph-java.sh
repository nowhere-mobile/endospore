#!/usr/bin/env bash
# test-gate-look-glyph-java.sh [--mutate] -- the gate's sun/moon, which anyone can tap, under javac (NWP-20261117-25).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md (2026-10-29, "three answers — the gate clears its sign-in fields
# when the screen turns off ...", second bullet) puts the gate's light/dark choice on a sun/moon in the gate's
# top-right corner: a sun while the gate is dark, a moon while it is light, and a tap switches the one device-wide look
# with no owner passphrase. ~~Owner settings › Appearance stays.~~ (Superseded 2026-11-06, "Owner settings loses
# Appearance ...": NWP-20261130-13 removed its Light mode switch, so this sun/moon is the only light/dark control.)
# GateLookGlyph.java is pure java, compiled as-is with
# GatePalette.java and core/chooser/tests/gate-look-glyph/GateLookGlyphCases.java (sun(), next(), description() and
# the two strings). The PINS check the wiring the cases cannot see: onCreate adds the glyph to the top-right row once,
# before the help "?", with its sun flag and description from GateLookGlyph and its click to toggleGateLook();
# toggleGateLook's first statement refuses while a sign-in, resume or sign-out runs, it writes GatePalette.KEY with
# commit() (never apply()), recreate()s only on a commit that succeeded and shows GateLookCopy.FAILED otherwise; it
# sits after buildGateLookScreen (test-gate-look-java.sh's M10 anchors on the first GateLookCopy.FAILED);
# lockGateForm dims the glyph; LookGlyphView holds no colour literal and draws the storefront's moon; and
# docs/threat-model.md's nowhere_gate.xml row names toggleGateLook.
#
# NWP-20261124-15 (docs/product-decisions.md, 2026-11-02, "twenty-four answers ...", #11): the owner can make the look
# owner-only. The cases add shown() and the exact text of GateLookGlyph.OWNER_ONLY_KEY. G7 pins onCreate: it reads the
# key once before the glyph is created and sets the glyph GONE from GateLookGlyph.shown(...) before it is added (the
# view still exists, so lockGateForm dims it). G8 pins toggleGateLook: its second statement, right after the guard,
# returns when the key is true, before the first read and the first write.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-gate-look-glyph-java.sh            # the cases and the pins
#   bash test-gate-look-glyph-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ChooserActivity.java"
GLY="$SRCDIR/GateLookGlyph.java"
PAL="$SRCDIR/GatePalette.java"
TM="$root/docs/threat-model.md"
CASES="$root/core/chooser/tests/gate-look-glyph/GateLookGlyphCases.java"
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

# nocomment <text> -> the text without its // comment lines, its /* */ lines, its trailing " // " comments and its
# blank lines
nocomment() {
  printf '%s\n' "$1" | awk '
    { s=$0; sub(/^[ \t]+/, "", s) }
    s == "" { next }
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

# nth <text> <n> -> line n of the text, without its leading and trailing blanks
nth() {
  printf '%s\n' "$1" | awk -v n="$2" 'NR == n { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }'
}

# NOWHERE-1222's colour-literal pattern (test-gate-palette-java.sh), plus the Color.argb and Color.rgb builders.
FORBIDDEN='0[xX][0-9A-Fa-f]{8}|parseColor\(|Color\.(BLACK|WHITE|GRAY|DKGRAY|LTGRAY|RED|GREEN|BLUE|YELLOW|CYAN|MAGENTA)\b|Color\.(argb|rgb)\('
GLYPH_NEW='lookGlyph = new LookGlyphView(this, MUTED, getResources().getDisplayMetrics().density, GateLookGlyph.sun(GatePalette.active()));'
GLYPH_DESC='lookGlyph.setContentDescription(GateLookGlyph.description(GatePalette.active()));'
GLYPH_CLICK='lookGlyph.setOnClickListener(v -> toggleGateLook());'
GUARD='if (loginInProgress || resumeBusy || signingOut || switchingIn || coverShown || nfcLoginInFlight) return;'
READ='String stored = getSharedPreferences("nowhere_gate", MODE_PRIVATE).getString(GatePalette.KEY, null);'
WRITE='boolean ok = getSharedPreferences("nowhere_gate", MODE_PRIVATE).edit().putString(GatePalette.KEY, GateLookGlyph.next(stored)).commit();'
OWNER_READ='boolean lookOwnerOnly = getSharedPreferences("nowhere_gate", MODE_PRIVATE).getBoolean(GateLookGlyph.OWNER_ONLY_KEY, false);'
OWNER_GONE='if (!GateLookGlyph.shown(lookOwnerOnly)) lookGlyph.setVisibility(View.GONE);'
OWNER_REFUSE='if (getSharedPreferences("nowhere_gate", MODE_PRIVATE).getBoolean(GateLookGlyph.OWNER_ONLY_KEY, false)) return;'

# cases <GateLookGlyph.java> -> 0 pass, 1 a case failed, 3 the classes or the cases did not compile
cases() {
  local d
  d=$(mktemp -d -p "$W")
  [ -f "$1" ] || { echo "  no $1" >&2; return 3; }
  cp "$1" "$d/GateLookGlyph.java"; cp "$PAL" "$d/GatePalette.java"; cp "$CASES" "$d/GateLookGlyphCases.java"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$d" "$d/GateLookGlyph.java" "$d/GatePalette.java" \
    "$d/GateLookGlyphCases.java" >&2 || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d" com.nowhere.chooser.GateLookGlyphCases >&2 || return 1
}

# suite <ChooserActivity.java> <GateLookGlyph.java> <threat-model.md>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the class did not compile. Only 1 convicts a mutant.
suite() {
  local f="$1" gly="$2" tm="$3" rc x b all ln la lb lt ls lr lw lread lfail lif lclose n lo lg lgone lref fails=0
  for x in "$f" "$tm" "$PAL" "$CASES"; do [ -f "$x" ] || { echo "  missing $x" >&2; return 2; }; done
  cases "$gly"; rc=$?
  case "$rc" in 0) ;; 1) fails=1 ;; 3) echo "  the class or the cases did not compile" >&2; return 3 ;; *) return 2 ;; esac
  all=$(nocomment "$(cat "$f")")

  # G1 onCreate: the glyph, its sun flag, description and click, added to topRight once, before the help "?".
  b=$(nocomment "$(body "$f" 'protected void onCreate(Bundle b) {')")
  if [ -z "$b" ]; then echo "--- FAIL G1: no onCreate(Bundle) in $f" >&2; fails=1
  else
    for x in "$GLYPH_NEW" "$GLYPH_DESC" "$GLYPH_CLICK"; do one "$b" "$x" G1 >/dev/null || fails=1; done
    if la=$(one "$b" 'topRight.addView(lookGlyph, ' G1) && lb=$(one "$b" 'topRight.addView(helpIcon, ' G1); then
      [ "$la" -lt "$lb" ] || { echo "--- FAIL G1: the sun/moon at $la is not added before the help \"?\" at $lb" >&2; fails=1; }
    else fails=1
    fi
  fi
  one "$all" 'addView(lookGlyph' G1 >/dev/null || fails=1

  # G7 onCreate: the owner-only key read once, then the glyph created, then GONE from GateLookGlyph.shown(...), then
  # added; nothing else sets the glyph's visibility.
  b=$(nocomment "$(body "$f" 'protected void onCreate(Bundle b) {')")
  if lo=$(one "$b" "$OWNER_READ" G7) && lg=$(one "$b" "$GLYPH_NEW" G7) && lgone=$(one "$b" "$OWNER_GONE" G7) \
     && la=$(one "$b" 'topRight.addView(lookGlyph, ' G7); then
    [ "$lo" -lt "$lg" ] && [ "$lg" -lt "$lgone" ] && [ "$lgone" -lt "$la" ] || {
      echo "--- FAIL G7: key read at $lo, glyph created at $lg, GONE at $lgone, added at $la: want that order" >&2; fails=1; }
  else fails=1
  fi
  one "$all" 'lookGlyph.setVisibility(' G7 >/dev/null || fails=1

  # G2 toggleGateLook.
  b=$(nocomment "$(body "$f" 'private void toggleGateLook() {')")
  if [ -z "$b" ]; then echo "--- FAIL G2: no toggleGateLook() in $f" >&2; fails=1
  else
    # a: the guard is the first statement, before any getSharedPreferences.
    [ "$(nth "$b" 2)" = "$GUARD" ] || { echo "--- FAIL G2: the first statement of toggleGateLook is not the guard: $(nth "$b" 2)" >&2; fails=1; }
    # b: one read, then the write with commit(), never apply().
    if lread=$(one "$b" "$READ" G2) && lw=$(one "$b" "$WRITE" G2); then
      [ "$lread" -lt "$lw" ] || { echo "--- FAIL G2: the read at $lread is not before the write at $lw" >&2; fails=1; }
    else fails=1
    fi
    one "$b" 'putString(GatePalette.KEY, GateLookGlyph.next(' G2 >/dev/null || fails=1
    # G8: the owner-only refusal is the second statement, right after the guard, before the first read and write.
    [ "$(nth "$b" 3)" = "$OWNER_REFUSE" ] || { echo "--- FAIL G8: the second statement of toggleGateLook is not the owner-only return: $(nth "$b" 3)" >&2; fails=1; }
    if lref=$(one "$b" "$OWNER_REFUSE" G8) && lread=$(one "$b" "$READ" G8); then
      [ "$lref" -lt "$lread" ] || { echo "--- FAIL G8: the owner-only return at $lref is not before the read at $lread" >&2; fails=1; }
    else fails=1
    fi
    none_re "$b" '\.apply\(\)' 'G2 apply() in toggleGateLook' || fails=1
    # c: recreate() once, inside 'if (ok) {', followed by return.
    if lr=$(one "$b" 'recreate();' G2); then
      [ "$(nth "$b" $((lr + 1)))" = 'return;' ] || { echo "--- FAIL G2: recreate() is not followed by return: '$(nth "$b" $((lr + 1)))'" >&2; fails=1; }
      lif=$(printf '%s\n' "$b" | awk -v r="$lr" 'NR < r { s=$0; sub(/^[ \t]+/, "", s); if (s ~ /^if \(/) { l=NR; t=s } } END { print l+0 " " t }')
      lclose=$(printf '%s\n' "$b" | awk -v a="${lif%% *}" -v r="$lr" 'NR > a && NR < r { s=$0; sub(/^[ \t]+/, "", s); if (s ~ /^\}/) n++ } END { print n+0 }')
      if [ "${lif#* }" != 'if (ok) {' ] || [ "$lclose" != 0 ]; then
        echo "--- FAIL G2: recreate() is not inside 'if (ok) {': nearest if above is '${lif#* }', $lclose closing lines between" >&2; fails=1
      fi
      # d: the failure toast after the success branch.
      if lfail=$(one "$b" 'GateLookCopy.FAILED' G2); then
        [ "$lfail" -gt $((lr + 1)) ] || { echo "--- FAIL G2: GateLookCopy.FAILED at $lfail is not after the success branch" >&2; fails=1; }
      else fails=1
      fi
    else fails=1
    fi
  fi

  # G3 placement: toggleGateLook after buildGateLookScreen, whose GateLookCopy.FAILED stays the file's first.
  if lt=$(one "$all" 'private void toggleGateLook() {' G3) && ls=$(one "$all" 'private View buildGateLookScreen() {' G3); then
    read -r n ln <<<"$(line_of "$all" 'GateLookCopy.FAILED')"
    [ "$ls" -lt "$lt" ] && [ "$ln" -gt "$ls" ] && [ "$ln" -lt "$lt" ] || {
      echo "--- FAIL G3: buildGateLookScreen at $ls, toggleGateLook at $lt, first GateLookCopy.FAILED at $ln" >&2; fails=1; }
  else fails=1
  fi

  # G4 lockGateForm dims the glyph.
  b=$(nocomment "$(body "$f" 'private void lockGateForm(boolean lock) {')")
  x=$(printf '%s\n' "$b" | awk '/View\[\] vs = \{/ { on=1 } on { print } on && /\};/ { exit }')
  n=$(printf '%s\n' "$x" | grep -ow 'lookGlyph' | wc -l)
  [ "$n" = 1 ] || { echo "--- FAIL G4: lockGateForm's View[] list holds lookGlyph $n times, want 1" >&2; fails=1; }

  # G5 LookGlyphView: no colour literal (comments included, as test-gate-palette's P1), the caller's colour, the
  # storefront's moon.
  one "$all" '    private LookGlyphView lookGlyph;' G5 >/dev/null || fails=1
  b=$(body "$f" 'private static final class LookGlyphView extends android.view.View {')
  if [ -z "$b" ]; then echo "--- FAIL G5: no LookGlyphView in $f" >&2; fails=1
  else
    none_re "$b" "$FORBIDDEN" 'G5 a colour literal in LookGlyphView' || fails=1
    b=$(nocomment "$b")
    for x in 'LookGlyphView(android.content.Context c, int color, float density, boolean sun) {' '.setColor(color);' \
             '12.348f * s, oy + 11.652f * s, 8.2f * s' '17.052f * s, oy + 6.948f * s, 8.2f * s' \
             'android.graphics.Path.Op.DIFFERENCE'; do
      one "$b" "$x" G5 >/dev/null || fails=1
    done
  fi

  # G6 the threat-model row names the new writer.
  b=$(grep -F '| `shared_prefs/nowhere_gate.xml` |' "$tm" || true)
  n=$(printf '%s' "$b" | grep -c '^' || true)
  if [ "$n" != 1 ]; then echo "--- FAIL G6: $n nowhere_gate.xml rows in $tm, want 1" >&2; fails=1
  else
    for x in 'toggleGateLook' '`gate_look`' 'buildGateLookScreen' 'DURABLE-EXEMPT' 'the look last chosen'; do
      case "$b" in *"$x"*) ;; *) echo "--- FAIL G6: the nowhere_gate.xml row does not hold $x" >&2; fails=1 ;; esac
    done
  fi

  [ "$fails" = 0 ] || return 1
  echo "  pins ok"
}

echo "== $ACT"
suite "$ACT" "$GLY" "$TM" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED: rc 1 with a --- FAIL line)"
fails=0
# mut <label> <target: act|glyph|tm> <perl-expr> [<substring the failure output must hold>]
mut() {
  local label="$1" target="$2" expr="$3" expect="${4:-}" d rc src copy
  d=$(mktemp -d -p "$W")
  cp "$ACT" "$d/ChooserActivity.java"; cp "$GLY" "$d/GateLookGlyph.java"; cp "$TM" "$d/threat-model.md"
  case "$target" in
    act) src="$ACT"; copy="$d/ChooserActivity.java" ;;
    glyph) src="$GLY"; copy="$d/GateLookGlyph.java" ;;
    tm) src="$TM"; copy="$d/threat-model.md" ;;
  esac
  perl -0pi -e "$expr" "$copy"
  if cmp -s "$copy" "$src"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$d/ChooserActivity.java" "$d/GateLookGlyph.java" "$d/threat-model.md" >"$d/out" 2>&1; rc=$?
  if [ "$rc" = 1 ] && grep -q -- '--- FAIL' "$d/out" && { [ -z "$expect" ] || grep -qF -- "$expect" "$d/out"; }; then
    echo "  CONVICTED $label"
    grep -m1 -- '--- FAIL' "$d/out" | sed 's/^/      /'
  else
    echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/out" | head -5; fails=$((fails+1))
  fi
}
mut 'M1 next() returns the stored look' glyph 's/(static String next\(String stored\) \{\s*return )[^;]*;/${1}stored;/' 'K4'
mut 'M2 sun() inverted' glyph 's/return p != GatePalette\.LIGHT;/return p == GatePalette.LIGHT;/' 'K1'
mut 'M3 the guard removed' act 's/\n[ \t]*if \(loginInProgress \|\| resumeBusy[^\n]*//' 'G2'
mut 'M4 apply() for commit()' act 's/GateLookGlyph\.next\(stored\)\)\.commit\(\);/GateLookGlyph.next(stored)).apply();/' 'G2'
mut 'M5 recreate() also on a failed commit' act 's/(private void toggleGateLook\(\).*?\n[^\n]*GateLookCopy\.FAILED[^\n]*)/$1\n        recreate();/s' 'G2'
mut 'M6 lookGlyph dropped from lockGateForm' act 's/helpIcon, lookGlyph, /helpIcon, /' 'G4'
mut 'M7 the glyph added after the gear' act 's/(\n[ \t]*topRight\.addView\(lookGlyph,[^\n]*)(.*?\n[ \t]*topRight\.addView\(gear,[^\n]*)/$2$1/s' 'G1'
mut 'M8 toggleGateLook dropped from the threat-model row' tm 's/^(\| `shared_prefs\/nowhere_gate\.xml` \|[^\n]*)$/my $r = $1; $r =~ s{toggleGateLook}{}g; $r/me' 'G6'
mut 'M9 a colour literal in LookGlyphView' act 's/(LookGlyphView\(android\.content\.Context c, int color, float density, boolean sun\) \{)/$1\n            int unused = 0xFF000000;/' 'G5'
mut 'M10 toggleGateLook moved above buildGateLookScreen' act 's/(\n    \/\*\* NWP-20261115-16 \(docs\/product-decisions\.md, 2026-10-26\): the gate.s look.*?)(\n    \/\*\* NWP-20261117-25 \(docs\/product-decisions\.md, 2026-10-29[^\n]*.*?\n    private void toggleGateLook\(\) \{.*?\n    \}\n)/$2$1/s' 'G3'
mut "M11 a moon that is not the storefront's" act 's/17\.052f \* s, oy \+ 6\.948f \* s, 8\.2f \* s/16.84f * s, oy + 7.16f * s, 7f * s/' 'G5'
mut 'M12 (G1) the GONE line removed' act 's/\n[ \t]*if \(!GateLookGlyph\.shown\(lookOwnerOnly\)\) lookGlyph\.setVisibility\(View\.GONE\);//' 'G7'
mut "M13 (G2) toggleGateLook's owner-only return removed" act 's/\n[ \t]*if \(getSharedPreferences\("nowhere_gate", MODE_PRIVATE\)\.getBoolean\(GateLookGlyph\.OWNER_ONLY_KEY, false\)\) return;//' 'G8'
mut 'M14 (G5) shown() always true' glyph 's/return !ownerOnly;/return true;/' 'K9'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
