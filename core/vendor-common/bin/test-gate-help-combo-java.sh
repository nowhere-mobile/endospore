#!/usr/bin/env bash
# test-gate-help-combo-java.sh [--mutate] -- the gate's Help combo screen, run under javac (NWP-20261130-11).
#
# WHY THIS IS COMMITTED. The row "There is no in-app Help" records the design Chester chose on 2026-11-06 ("Go with
# combo", NWP-20261105-27): the gate's ? opens a hero card, a skippable three-step intro, six topic tiles and a
# "Forgot your passphrase?" card, in the gate's light and dark colours. The chooser cannot be compiled off the build
# host, so this suite compiles GateHelpHome, GateHelpArt, GateHelpPages, HelpPages, GatePalette, GateHelpScreen,
# GateHelpTileGrid and GateHelpArtView against the stubs in core/chooser/tests/gate-help-combo/stubs, which record text,
# descriptions, clicks and colours. GateHelpComboCases then builds and walks the real view trees:
#   T1-T3 hero, grid, and each control's action; T4-T6, T9, T10 what each tile and the card open; T7, T8 the intro, its
#   three steps, Next and Skip; T11 no B4 word (decision 2026-10-31, Part B) in any word the screen shows, says or draws;
#   T12, T13 both palettes resolve, the contrast floors hold, and no colour comes from outside GatePalette; T14 every
#   control and picture has its own TalkBack description; T15-T17 source checks: no activity, link, pref, daemon or profile
#   name in the new classes, the icons are vector drawables in tile order, and ChooserActivity's three methods are wired.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-gate-help-combo-java.sh            # the cases
#   bash test-gate-help-combo-java.sh --mutate   # ... plus broken copies that must each FAIL by their named assertion
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
RES="$root/core/chooser/res"
T="$root/core/chooser/tests/gate-help-combo"
HELP_CASES="$root/core/chooser/tests/help-pages/HelpPagesCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
COMPILED='GateHelpHome GateHelpArt GateHelpPages HelpPages GatePalette GateHelpScreen GateHelpTileGrid GateHelpArtView'

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
[ -f "$T/GateHelpComboCases.java" ] || { echo "FAIL: missing the cases in $T" >&2; exit 2; }

mkdir -p "$W/stubs"
find "$T/stubs" -name '*.java' > "$W/stubs.txt"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$W/stubs" "@$W/stubs.txt" || { echo "FAIL: the stubs do not compile" >&2; exit 2; }

# suite <dir holding the sources and ChooserActivity.java> -> 0 pass, 1 a case failed or a class is missing, 3 no compile.
suite() {
  local dir="$1" d cls files=() rc
  for cls in $COMPILED; do
    [ -f "$dir/$cls.java" ] || { echo "  FAIL T0: $cls.java does not exist (the combo screen is not built)"; return 1; }
    files+=("$dir/$cls.java")
  done
  d=$(mktemp -d -p "$W") || return 3
  if ! "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -cp "$W/stubs" -d "$d" "${files[@]}" "$T/GateHelpComboCases.java"; then
    rm -rf "$d"; return 3
  fi
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -Dgatehelp.src="$dir" -Dgatehelp.res="$RES" \
    -Dgatehelp.chooser="$dir/ChooserActivity.java" -Dgatehelp.helpcases="$HELP_CASES" \
    -cp "$d:$W/stubs" com.nowhere.chooser.GateHelpComboCases; rc=$?
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# copy_sources <dest> -> the classes under test and ChooserActivity.java.
copy_sources() {
  local dest="$1" cls
  for cls in $COMPILED ChooserActivity; do
    [ ! -f "$SRC/$cls.java" ] || cp "$SRC/$cls.java" "$dest/"
  done
}

D0="$W/plain"; mkdir -p "$D0"; copy_sources "$D0"
suite "$D0"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its named assertion -- inert or non-compiling mutants prove nothing)"

# mut <label> <class> <assertions, space-separated> <perl-expr> -> 0 when the mutant fails with every named assertion.
mut() {
  local label="$1" cls="$2" want="$3" expr="$4" d out rc id miss=""
  d=$(mktemp -d -p "$W") || return 1
  copy_sources "$d"
  if ! perl -0pi -e "$expr" "$d/$cls.java"; then echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC/$cls.java" "$d/$cls.java"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(suite "$d" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $label"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $label -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
  for id in $want; do
    case "$out" in *"FAIL $id:"*) ;; *) miss="$miss $id" ;; esac
  done
  if [ -n "$miss" ]; then
    echo "  WRONG     $label -- failed, but not by:$miss"; printf '%s\n' "$out" | head -5; return 1
  fi
  echo "  CONVICTED $label by $want"
  return 0
}

fails=0
mut "H1 a tile unmapped" GateHelpHome "T4 T5" \
  's/(static String tileBody\(int i\) \{\n)/$1        if (i == 1) return null;\n/ or die' || fails=$((fails+1))
mut "H2 two tile bodies swapped" GateHelpHome "T4" \
  's/TILE_PAGE = \{ 0, -1, -1, 3, -1, 2 \}/TILE_PAGE = { 3, -1, -1, 0, -1, 2 }/ or die' || fails=$((fails+1))
mut "H3 Skip removed from the intro" GateHelpScreen "T7 T8" \
  's/^\s*ll\.addView\(skip,[^\n]*\n//m or die' || fails=$((fails+1))
mut "H4 Skip goes to the next step" GateHelpScreen "T8" \
  's/skip\.setOnClickListener\(v -> nav\.show\(home\(c, p, nav\)\)\);/skip.setOnClickListener(v -> nav.show(intro(c, p, (step + 1) % GateHelpHome.INTRO.length, nav)));/ or die' \
  || fails=$((fails+1))
mut "H5 a tile's label dropped" GateHelpTileGrid "T14" \
  's/^\s*tile\.setContentDescription\([^\n]*\n//m or die' || fails=$((fails+1))
mut "H6 the Watch button's label dropped" GateHelpScreen "T14" \
  's/^\s*watch\.setContentDescription\([^\n]*\n//m or die' || fails=$((fails+1))
mut "H7 the intro reduced to two steps" GateHelpHome "T7" \
  's/^\s*\{ "Lock or log off",.*?\},\n//ms or die' || fails=$((fails+1))
mut "H8 the Forgot card removed from the home screen" GateHelpScreen "T3 T10" \
  's/^\s*ll\.addView\(forgotCard\([^\n]*\n//m or die' || fails=$((fails+1))
mut "H9 a B4 word in an intro line" GateHelpHome "T11" \
  's/Your profile comes down from your store\./Your profile comes down safely from your store./ or die' || fails=$((fails+1))
mut "H10 a role changed to muted" GateHelpArt "T12" \
  's/body = p\.hint;/body = p.muted;/ or die' || fails=$((fails+1))
mut "H11 a colour literal in the art view" GateHelpArtView "T13" \
  's/line\.setColor\(roles\.ink\);/line.setColor(0xFF123456);/ or die' || fails=$((fails+1))
mut "H12 page 3's log-off step removed" GateHelpPages "T9" \
  's/^\s*"Profile › Log off: sign out\.[^\n]*\n//m or die' || fails=$((fails+1))
mut "H13 two tile icons out of order" GateHelpTileGrid "T16" \
  's/R\.drawable\.ic_help_signin, R\.drawable\.ic_help_apps/R.drawable.ic_help_apps, R.drawable.ic_help_signin/ or die' || fails=$((fails+1))
mut "H14 a startActivity added to the screen" GateHelpScreen "T15" \
  's/(static View home\(Context c, GatePalette p, Nav nav\) \{\n)/$1        if (c == null) c.startActivity(null);\n/ or die' || fails=$((fails+1))
mut "H15 showGateHelp shows the old dialog list" ChooserActivity "T17" \
  's/runOnUiThread\(\(\) -> setContentView\(GateHelpScreen\.home\(this, GatePalette\.active\(\), gateHelpNav\(\)\)\)\);/runOnUiThread(() -> new android.app.AlertDialog.Builder(this).setItems(GateHelpPages.TITLES, null).show());/ or die' \
  || fails=$((fails+1))
mut "H16 Gate settings unreachable" GateHelpHome "T5" \
  's/TILE_ALSO = \{ 1, /TILE_ALSO = { -1, / or die' || fails=$((fails+1))
mut "H17 the encrypted store back in HERO_NODES" GateHelpHome "T11" \
  's/HERO_NODES = \{ "This phone", "Your store", "Any phone" \}/HERO_NODES = { "This phone", "Encrypted store", "Any phone" }/ or die' \
  || fails=$((fails+1))
mut "H18 HERO_DESCRIPTION says the encrypted store" GateHelpHome "T11" \
  's/saves your profile to your store/saves your profile to the encrypted store/ or die' || fails=$((fails+1))
mut "H19 the art view draws a literal, not HERO_NODES" GateHelpArtView "T11" \
  's/GateHelpHome\.HERO_NODES\[i\]/(i == 1 ? "Encrypted store" : GateHelpHome.HERO_NODES[i])/ or die' || fails=$((fails+1))
mut "H20 a tile's click goes to the wrong topic" GateHelpTileGrid "T3" \
  's/nav\.openTile\(index\)/nav.openTile((index + 1) % GateHelpHome.TILES.length)/ or die' || fails=$((fails+1))
mut "H21 the light palette ignored" GateHelpScreen "T13" \
  's/(static View intro\(Context c, GatePalette p, int step, Nav nav\) \{\n\s*GateHelpArt\.Roles r = GateHelpArt\.of\()p\)/$1GatePalette.DARK)/ or die' \
  || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
