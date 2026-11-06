#!/usr/bin/env bash
# test-help-cards-java.sh [--mutate] -- Profile › Help as step cards, run under javac (NWP-20261122-08).
#
# WHY THIS IS COMMITTED. Decision 2026-11-02 (docs/product-decisions.md, "Help at the gate covers the gate and Owner
# settings only, and Profile Help becomes picture step cards ...") makes each Profile Help topic a short run of cards,
# one picture and one or two lines a card. HelpCards holds the rules (pure, java.lang/java.util only) and is compiled
# here with HelpPages and its cases; they pin the step-to-card split (every page gives a card, 1 or 2 lines a card,
# every step kept in order), unique help_p<page>_c<card> slot names that are valid resource names, the position label
# and the swipe index that clamps at both ends. A source check (comment lines stripped) pins the card screen in
# ProfileActivity: showHelpPage and its helpers resolve HelpCards.slotName through getIdentifier, set the slot GONE
# when the id is 0, decode with ImageDecoder and loop an AnimatedImageDrawable, move through HelpCards.next and take a
# fling; and ProfileActivity imports nothing from androidx. The run prints the shot list: every slot, its card, and
# [animated] on the first cards that carry an animation.
#
# NWP-20261126-08. Decision 2026-11-03 ("... Profile Help's cards show where to tap", NWP-20261103-24) makes each card
# show where to tap. The cases pin HelpCards.path and text on real steps, the panel window (at most PANEL_ROWS rows,
# the row to tap always in it), a panel for every step with a path, one TOPIC_ICONS glyph per title, and the dots.
# The cases print every MENUS label; C6 finds each one as a string literal in ProfileActivity, so MENUS cannot drift
# from the screen. C5 pins the in-place topics: showHelp calls menuScreen once, and showHelpPage calls none.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-help-cards-java.sh            # the cases and the source check
#   bash test-help-cards-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
CARDS="${HELP_CARDS_SRC:-$SRC/HelpCards.java}"
PAGES="${HELP_PAGES_SRC:-$SRC/HelpPages.java}"
PROFILE="${HELP_PROFILE_SRC:-$SRC/ProfileActivity.java}"
CASES="$root/core/chooser/tests/help-cards/HelpCardsCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

# The card screen: showHelp, showHelpPage and their private helpers beside them.
SCREEN_METHODS='showHelp showHelpPage helpCardPicture helpCardDrop helpCardFling helpCardChips helpCardPanel helpTopicIcon'

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
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# suite <HelpCards.java> <HelpPages.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local cards="$1" pages="$2" d out rc
  [ -f "$cards" ] || { echo "  FAIL  HelpCards.java does not exist (the step cards are not built)" >&2; return 1; }
  [ -f "$pages" ] || { echo "  FAIL  HelpPages.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$cards" "$d/src/com/nowhere/chooser/HelpCards.java"
  cp "$pages" "$d/src/com/nowhere/chooser/HelpPages.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/HelpCardsCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.HelpCardsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# method <file> <signature-regex> -> the method from its signature to its closing "    }", comment lines stripped:
# a line whose first non-blank is "*" or "/*" goes, and so does everything from "//" to the end of a line.
method() {
  awk -v sig="$2" '$0 ~ sig { on = 1 } on { print } on && /^    }$/ { exit }' "$1" \
    | sed -e '/^[[:space:]]*\(\*\|\/\*\)/d' -e 's#//.*$##'
}

# source_check <ProfileActivity.java> -> 0 when the card screen holds, 1 otherwise.
source_check() {
  local profile="$1" screen="" m body k n idvar bad=0
  for m in $SCREEN_METHODS; do
    body=$(method "$profile" "private void $m\\\\(")
    [ -n "$body" ] || { echo "  FAIL  $m not found in $profile" >&2; bad=1; continue; }
    screen=$(printf '%s\n%s\n' "$screen" "$body")
  done
  [ -n "$screen" ] || return 1

  # C1 the picture slot is the drawable HelpCards.slotName names, looked up by getIdentifier.
  n=$(printf '%s\n' "$screen" | grep -F 'HelpCards.slotName(' | grep -F 'getIdentifier(' | grep -cF '"drawable"')
  [ "$n" -ge 1 ] || { echo "  FAIL  no line resolves HelpCards.slotName through getIdentifier(..., \"drawable\", ...)" >&2; bad=1; }

  # C2 an id of 0 (no picture yet) makes the slot GONE: the variable getIdentifier set is the one tested for 0.
  idvar=$(printf '%s\n' "$screen" | perl -ne 'print "$1\n" if /int\s+(\w+)\s*=\s*getResources\(\)\.getIdentifier\(/' \
            | head -1)
  if [ -z "$idvar" ]; then
    echo "  FAIL  no int is assigned from getResources().getIdentifier(" >&2; bad=1
  else
    n=$(printf '%s\n' "$screen" \
          | IDVAR="$idvar" perl -0ne '$v = quotemeta $ENV{IDVAR};
              $c = () = /if \(\s*$v\s*==\s*0\s*\)\s*\{\s*\w+\.setVisibility\((?:android\.view\.)?View\.GONE\)/g; print $c')
    [ "$n" -ge 1 ] || { echo "  FAIL  the slot is not set GONE when $idvar == 0" >&2; bad=1; }
  fi

  # C3 one picture decoded with ImageDecoder; an animated WebP loops.
  for k in 'ImageDecoder.decodeDrawable(' 'AnimatedImageDrawable' 'REPEAT_INFINITE' '.start()' '.stop()' \
           'GestureDetector' 'HelpCards.next(' 'HelpCards.position(' 'HelpCards.BACK' 'HelpCards.NEXT' \
           'HelpCards.path(' 'HelpCards.text(' 'HelpCards.panel(' 'HelpCards.dots(' 'HelpCards.chipSep()' \
           'HelpCards.icon('; do
    n=$(printf '%s\n' "$screen" | grep -cF "$k")
    [ "$n" -ge 1 ] || { echo "  FAIL  the card screen has no <$k>" >&2; bad=1; }
  done

  # C4 no androidx: the chooser gains no dependency, framework views only.
  n=$(sed -e '/^[[:space:]]*\(\*\|\/\*\)/d' -e 's#//.*$##' "$profile" | grep -c 'androidx')
  [ "$n" -eq 0 ] || { echo "  FAIL  ProfileActivity names androidx ($n line(s))" >&2; bad=1; }

  # C5 a topic opens in place: showHelp builds the one screen and calls showHelpPage; showHelpPage builds into the
  # body it is given (no screen of its own), and Back on its first card runs close.
  help=$(method "$profile" 'private void showHelp\\(\\)')
  page=$(method "$profile" 'private void showHelpPage\\(')
  n=$(printf '%s\n' "$help" | grep -cF 'menuScreen(')
  [ "$n" -eq 1 ] || { echo "  FAIL  showHelp calls menuScreen( $n time(s), want 1 (topics open in place)" >&2; bad=1; }
  n=$(printf '%s\n' "$help" | grep -cF 'showHelpPage(')
  [ "$n" -ge 1 ] || { echo "  FAIL  showHelp does not open a topic through showHelpPage" >&2; bad=1; }
  n=$(printf '%s\n' "$page" | grep -cE 'menuScreen\(|finishMenuScreen\(|setContentView\(')
  [ "$n" -eq 0 ] || { echo "  FAIL  showHelpPage builds a screen of its own, not the topic's body" >&2; bad=1; }
  n=$(printf '%s\n' "$page" | grep -cF 'close.run()')
  [ "$n" -ge 1 ] || { echo "  FAIL  Back on the first card does not close the topic (no close.run())" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# C6 MENUS against the screen.
# menus_check <cases output> <ProfileActivity.java> -> 0 when every MENUS label is a string literal on the screen.
menus_check() {
  local out="$1" profile="$2" src labels l n bad=0
  src=$(sed -e '/^[[:space:]]*\(\*\|\/\*\)/d' -e 's#//.*$##' "$profile")
  labels=$(printf '%s\n' "$out" | sed -n 's/^menu-label\t//p')
  [ -n "$labels" ] || { echo "  FAIL  the cases printed no MENUS label" >&2; return 1; }
  while IFS= read -r l; do
    n=$(printf '%s\n' "$src" | grep -cF "\"$l\"")
    [ "$n" -ge 1 ] || { echo "  FAIL  MENUS label <$l> is no string literal in ProfileActivity" >&2; bad=1; }
  done <<< "$labels"
  [ "$bad" -eq 0 ]
}

# run_all <HelpCards.java> <HelpPages.java> <ProfileActivity.java> -> 0 pass, 1 a check failed, 3 no compile.
run_all() {
  local rc out
  echo "== $1"
  out=$(suite "$1" "$2"); rc=$?
  echo "$out"
  [ "$rc" -eq 3 ] && return 3
  if [ "$rc" -eq 0 ]; then
    if menus_check "$out" "$3"; then echo "menus: ok"; else echo "FAILED (menus)"; rc=1; fi
  fi
  if source_check "$3"; then echo "source: ok"; else echo "FAILED (source)"; rc=1; fi
  return "$rc"
}

run_all "$CARDS" "$PAGES" "$PROFILE"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not apply or does not compile proves nothing)"

# mut <label> <cards|pages|profile> <perl-expr> -> 0 when the mutant is convicted.
mut() {
  local label="$1" which="$2" expr="$3" d orig c rc ca="$CARDS" pg="$PAGES" pr="$PROFILE"
  case "$which" in cards) orig="$CARDS" ;; pages) orig="$PAGES" ;; profile) orig="$PROFILE" ;; esac
  d=$(mktemp -d -p "$W") || return 1
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$expr" "$c"; then
    echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1
  fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$which" in cards) ca="$c" ;; pages) pg="$c" ;; profile) pr="$c" ;; esac
  run_all "$ca" "$pg" "$pr" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $label"; return 1 ;;
    1) echo "  CONVICTED $label"; return 0 ;;
    *) echo "  BROKEN    $label -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "MC1 a bullet starts its own card" cards 's/s\.startsWith\("•"\) && last != null && last\.length == 1/false/' \
  || fails=$((fails+1))
mut "MC2 next does not clamp at n-1" cards 's/Math\.min\(n - 1, i \+ dir\)/i + dir/' || fails=$((fails+1))
mut "MC3 the GONE branch removed" profile 's/^\s*if \(id == 0\) \{ pic\.setVisibility\(View\.GONE\); return; \}\n//m' \
  || fails=$((fails+1))
mut "MC4 two pages share a slot name" cards 's/"help_p" \+ page \+ "_c" \+ card/"help_p0_c" + card/' || fails=$((fails+1))
mut "MC5 next does not clamp at 0" cards 's/Math\.max\(0, (Math\.min\(n - 1, i \+ dir\))\)/$1/' || fails=$((fails+1))
mut "MC6 the position label off by one" cards 's/\(i \+ 1\) \+ " of "/i + " of "/' || fails=$((fails+1))
mut "MC7 ProfileActivity imports androidx" profile \
  's/^(import android\.Manifest;)$/$1\nimport androidx.annotation.NonNull;/m' || fails=$((fails+1))
mut "MC8 the slot resolved by a fixed resource" profile \
  's/getIdentifier\(HelpCards\.slotName\(page, card\),/getIdentifier("help",/' || fails=$((fails+1))
mut "MC9 a two-line card joins a third line" cards 's/last\.length == 1\)/last.length >= 1)/' || fails=$((fails+1))
mut "MC10 steps() hands out the shared array" pages 's/return STEPS\[i\]\.clone\(\);/return STEPS[i];/' \
  || fails=$((fails+1))
mut "MC11 path() keeps the \": \" in the last chip" cards \
  's/step\.substring\(0, c\)\.split/step.substring(0, c + 2).split/' || fails=$((fails+1))
mut "MC12 panel() highlights the first row" cards \
  's/, start \+ shown\), at - start\);/, start + shown), 0);/' || fails=$((fails+1))
mut "MC13 the panel window drops the highlighted row" cards \
  's/Math\.min\(at - 1, all\.length - shown\)/Math.min(at + 1, all.length - shown)/' || fails=$((fails+1))
mut "MC14 a MENUS row renamed" cards 's/"Tie to this phone"/"Tie to the phone"/' || fails=$((fails+1))
mut "MC15 a Security row renamed on the screen" profile \
  's/labels\.add\("Auto-wipe when left locked"\)/labels.add("Auto-wipe when locked")/' || fails=$((fails+1))
mut "MC16 TOPIC_ICONS one short" cards 's/^[^\n]*\/\/ Privacy controls\n//m' || fails=$((fails+1))
mut "MC17 a topic opens on its own screen" profile \
  's/(private void showHelpPage\([^)]*\) \{\n)/$1        menuScreen(HelpPages.TITLES[page], HelpPages.indexTitle());\n/' \
  || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
