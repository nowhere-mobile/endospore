#!/usr/bin/env bash
# test-help-pages-java.sh [--mutate] -- the in-app Help pages, run under javac (NWP-20261119-16, NWP-20261122-05).
#
# WHY THIS IS COMMITTED. Decision 2026-10-31 (docs/product-decisions.md, Part B) gives the phone a Help section:
# features and how to use them only, never what they protect (B4). Decision 2026-11-02 splits it in two page sets:
# the gate's "?" reads GateHelpPages (signing in, Gate settings, Owner settings, a locked phone) and Profile › Help
# reads HelpPages (the six session topics). Both classes hold only words (pure, java.lang only) and are compiled here
# with their cases; they pin both page lists exactly and apart, 3 to 6 steps and at most 650 characters a page, and no
# B4 word in a body, for both sets. A source check (comment lines stripped) pins the two doors: showGateHelp builds
# its list from GateHelpPages.TITLES and shows GateHelpPages.body and moreLine with no other words than "Back" and
# "Got it", and reads no HelpPages; both Profile home arrays end with a "Help" row that runs showHelp; showHelp lists
# HelpPages.TITLES and opens a topic in place through showHelpPage, which builds its step cards from HelpPages.steps
# through HelpCards.cards, shows moreLine and runs close on Back from the first card (NWP-20261122-08,
# NWP-20261126-08); no Help method, the card screen's helpers (HELP_PAGE_HELPERS below) included, reads a profile name or a daemon reply.
# HelpCards is not compiled here: test-help-cards-java.sh runs its cases. The cases also pin Gate settings' sun/moon
# step byte for byte (NWP-20261124-15): "The sun or moon left of ? switches between light and dark, unless the owner
# has kept the look to Owner settings.", since the owner can hide the sun/moon (GateLookGlyph.OWNER_ONLY_KEY). That
# step made Gate settings 645 characters, so the page limit is 650 (it was 600 before NWP-20261124-15).
# NWP-20261126-03 (decision 2026-11-03): Store settings moved from Gate settings to Owner settings. The cases pin that
# Gate settings does not name it and that Owner settings' Lock screen clock step does, byte for byte (page 2 keeps 6
# steps). Gate settings is now 596 characters and Owner settings 622.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-help-pages-java.sh            # the cases and the source check
#   bash test-help-pages-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="${HELP_PAGES_SRC:-$SRC/HelpPages.java}"
GATE="${HELP_GATE_PAGES_SRC:-$SRC/GateHelpPages.java}"
CHOOSER="${HELP_CHOOSER_SRC:-$SRC/ChooserActivity.java}"
PROFILE="${HELP_PROFILE_SRC:-$SRC/ProfileActivity.java}"
CASES="$root/core/chooser/tests/help-pages/HelpPagesCases.java"
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
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# suite <HelpPages.java> <GateHelpPages.java> -> 0 pass, 1 a case failed or a class is missing, 3 did not compile.
suite() {
  local src="$1" gsrc="$2" d out rc
  [ -f "$src" ] || { echo "  FAIL  HelpPages.java does not exist (the Help pages are not built)" >&2; return 1; }
  [ -f "$gsrc" ] || { echo "  FAIL  GateHelpPages.java does not exist (the gate's Help pages are not built)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/HelpPages.java"
  cp "$gsrc" "$d/src/com/nowhere/chooser/GateHelpPages.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/HelpPagesCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.HelpPagesCases 2>&1); rc=$?
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

# The card screen's private helpers beside showHelpPage (NWP-20261122-08). S4 reads them with showHelpPage.
HELP_PAGE_HELPERS='helpCardPicture helpCardDrop helpCardFling helpCardChips helpCardPanel helpTopicIcon'

# source_check <ChooserActivity.java> <ProfileActivity.java> <HelpPages.java> <GateHelpPages.java> -> 0 when the
# wiring holds, 1 otherwise.
source_check() {
  local chooser="$1" profile="$2" pages="$3" gatepages="$4" gate home help page cardsrc h body k n lits rest arrays f bad=0
  gate=$(method "$chooser" 'private void showGateHelp\\(\\)')
  home=$(method "$profile" 'private void showConfirm\\(\\)')
  help=$(method "$profile" 'private void showHelp\\(\\)')
  page=$(method "$profile" 'private void showHelpPage\\(')
  [ -n "$gate" ] || { echo "  FAIL  showGateHelp not found in $chooser" >&2; return 1; }
  [ -n "$home" ] || { echo "  FAIL  showConfirm not found in $profile" >&2; return 1; }
  [ -n "$help" ] || { echo "  FAIL  showHelp not found in $profile" >&2; bad=1; }
  [ -n "$page" ] || { echo "  FAIL  showHelpPage not found in $profile" >&2; bad=1; }
  # cardsrc: showHelpPage and its helpers, for S4. S3's pins read showHelpPage alone.
  cardsrc="$page"
  for h in $HELP_PAGE_HELPERS; do
    body=$(method "$profile" "private void $h\\\\(")
    [ -n "$body" ] || { echo "  FAIL  $h not found in $profile" >&2; bad=1; }
    cardsrc=$(printf '%s\n%s\n' "$cardsrc" "$body")
  done

  # S1 the gate's "?": the Help list from GateHelpPages, a page from GateHelpPages, never a HelpPages (Profile's set),
  # and no words of its own but Back / Got it.
  for k in '.setTitle(GateHelpPages.indexTitle())' '.setItems(GateHelpPages.TITLES,' '.setTitle(GateHelpPages.TITLES[' \
           'GateHelpPages.body(' 'GateHelpPages.moreLine()' '"Back"' '"Got it"'; do
    n=$(printf '%s\n' "$gate" | grep -cF "$k")
    [ "$n" -ge 1 ] || { echo "  FAIL  showGateHelp has no <$k>" >&2; bad=1; }
  done
  n=$(printf '%s\n' "$gate" | grep -cE '(^|[^A-Za-z])HelpPages\.')
  [ "$n" -eq 0 ] || { echo "  FAIL  showGateHelp reads HelpPages (Profile › Help's set), not only GateHelpPages" >&2; bad=1; }
  lits=$(printf '%s\n' "$gate" | grep -o '"[^"]*"' | sort -u | grep -vxF -e '"Back"' -e '"Got it"' -e '"\n\n"')
  [ -z "$lits" ] || { echo "  FAIL  showGateHelp shows its own words: $(printf '%s' "$lits" | tr '\n' ' ')" >&2; bad=1; }
  n=$(printf '%s\n' "$gate" | grep -cE 'startActivity|Intent|setView\(|WebView|Uri\.')
  [ "$n" -eq 0 ] || { echo "  FAIL  showGateHelp leaves the dialogs (an activity, a view, a link)" >&2; bad=1; }

  # S2 both home arrays: "Help" last, and the runnable at the same index is showHelp.
  arrays=$(printf '%s\n' "$home" | perl -0ne '
    my @calls = /sectionCard\(ll, null,(.*?)\}, false\);/sg;
    print scalar(@calls), "\n";
    for my $c (@calls) {
      my ($l) = $c =~ /new String\[\]\{(.*?)\}/s; my ($r) = $c =~ /new Runnable\[\]\{(.*)$/s;
      my @l = map { s/^\s+|\s+$//gr } split /,/, ($l // "");
      my @r = map { s/^\s+|\s+$//gr } split /,(?=\s*\(\) ->)/, ($r // "");
      my ($li) = grep { $l[$_] eq q{"Help"} } 0..$#l; my ($ri) = grep { $r[$_] eq q{() -> showHelp()} } 0..$#r;
      printf "%d %d %s %s\n", scalar(@l), scalar(@r), $li // "-", $ri // "-";
    }')
  n=$(printf '%s\n' "$arrays" | head -1)
  [ "$n" = 2 ] || { echo "  FAIL  showConfirm has $n home arrays, want 2 (stored and throwaway)" >&2; bad=1; }
  while read -r nl nr li ri; do
    [ -n "$nl" ] || continue
    if [ "$li" = - ] || [ "$ri" = - ] || [ "$nl" != "$nr" ] || [ "$li" != "$ri" ] || [ "$li" != "$((nl - 1))" ]; then
      echo "  FAIL  a home array: $nl labels, $nr runnables, \"Help\" at <$li>, showHelp at <$ri>; want Help last, at the" \
           "same index" >&2; bad=1
    fi
  done < <(printf '%s\n' "$arrays" | tail -n +2)

  # S3 Profile › Help: the list is HelpPages.TITLES, and a topic opens in place under its row (NWP-20261126-08); its
  # cards come from HelpPages.steps through HelpCards.cards, moreLine shows under the last, and Back on the first
  # card closes the topic, so the list stays.
  for k in 'menuScreen(HelpPages.indexTitle(),' 'HelpPages.TITLES[' 'HelpPages.TITLES.length' 'showHelpPage(' \
           'finishMenuScreen(ll)'; do
    n=$(printf '%s\n' "$help" | grep -cF "$k")
    [ "$n" -ge 1 ] || { echo "  FAIL  showHelp has no <$k>" >&2; bad=1; }
  done
  for k in 'HelpPages.steps(' 'HelpCards.cards(' 'HelpPages.moreLine()' 'close.run()'; do
    n=$(printf '%s\n' "$page" | grep -cF "$k")
    [ "$n" -ge 1 ] || { echo "  FAIL  showHelpPage has no <$k>" >&2; bad=1; }
  done
  n=$(printf '%s\n' "$page" | grep -cF 'menuScreen(')
  [ "$n" -eq 0 ] || { echo "  FAIL  showHelpPage opens a screen of its own, not the topic in place" >&2; bad=1; }

  # S4 static text only: no Help method reads a profile name or a daemon reply, or joins one into a Help string.
  n=$(printf '%s\n%s\n%s\n' "$gate" "$help" "$cardsrc" \
        | grep -cE 'profileName|\bname\b|sendDaemon|daemonCmd|daemonLenReply|DaemonSocket|\breply\b|sessionType|getUserName')
  [ "$n" -eq 0 ] || { echo "  FAIL  a Help method reads a profile name or a daemon reply" >&2; bad=1; }
  rest=$(printf '%s\n' "$gate" | sed 's/GateHelpPages\.body(i) + "\\n\\n" + GateHelpPages\.moreLine()//')
  n=$(printf '%s\n%s\n%s\n' "$rest" "$help" "$cardsrc" | grep -cE '[^+]\+[^+=]')
  [ "$n" -eq 0 ] || { echo "  FAIL  a Help method joins something into a Help string" >&2; bad=1; }

  # S5 HelpPages and GateHelpPages are pure: java.* only.
  for f in "$pages" "$gatepages"; do
    [ -f "$f" ] || { echo "  FAIL  $f does not exist" >&2; bad=1; continue; }
    rest=$(sed -e '/^[[:space:]]*\(\*\|\/\*\)/d' -e 's#//.*$##' "$f" | grep -E '^import ' | grep -v '^import java\.')
    n=$(sed -e '/^[[:space:]]*\(\*\|\/\*\)/d' -e 's#//.*$##' "$f" | grep -c 'android\.')
    { [ -z "$rest" ] && [ "$n" -eq 0 ]; } || { echo "  FAIL  $(basename "$f") reaches outside java.*" >&2; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

# run_all <HelpPages.java> <GateHelpPages.java> <ChooserActivity.java> <ProfileActivity.java> -> 0 pass, 1 a check
# failed, 3 no compile.
run_all() {
  local rc
  echo "== $1 $2"
  suite "$1" "$2"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  if source_check "$3" "$4" "$1" "$2"; then echo "source: ok"; else echo "FAILED (source)"; rc=1; fi
  return "$rc"
}

run_all "$SUT" "$GATE" "$CHOOSER" "$PROFILE"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not apply or does not compile proves nothing)"

# The gate sheet as it stood before this slice, for M7.
cat > "$W/old-gate-help.txt" <<'OLD'
    private void showGateHelp() {
        runOnUiThread(() -> new android.app.AlertDialog.Builder(this)
                .setTitle("Signing in")
                .setMessage("Enter your profile name and passphrase, then tap Unlock. Nothing is kept on this "
                        + "phone — your apps and data come down from your store as you sign in.\n\n"
                        + "Using a security key?\n"
                        + "• USB-C key: plug it in, enter your passphrase, then touch the key when it blinks.\n"
                        + "• NFC key: enter your passphrase, then hold the key to the back of the phone.\n"
                        + "No security key? Ignore this — just sign in with your passphrase.\n\n"
                        + "Forgot your passphrase? Use the link below the Unlock button to recover with your "
                        + "12-word recovery code.")
                .setPositiveButton("Got it", (d, w) -> d.dismiss())
                .show());
    }
OLD

# mut <label> <pages|gate|chooser|profile> <perl-expr> -> 0 when the mutant is convicted.
mut() {
  local label="$1" which="$2" expr="$3" d orig c rc pg="$SUT" gp="$GATE" ch="$CHOOSER" pr="$PROFILE"
  case "$which" in pages) orig="$SUT" ;; gate) orig="$GATE" ;; chooser) orig="$CHOOSER" ;; profile) orig="$PROFILE" ;; esac
  d=$(mktemp -d -p "$W") || return 1
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! OLD_GATE="$W/old-gate-help.txt" perl -0pi -e "$expr" "$c"; then
    echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1
  fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$which" in pages) pg="$c" ;; gate) gp="$c" ;; chooser) ch="$c" ;; profile) pr="$c" ;; esac
  run_all "$pg" "$gp" "$ch" "$pr" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $label"; return 1 ;;
    1) echo "  CONVICTED $label"; return 0 ;;
    *) echo "  BROKEN    $label -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 a title renamed" pages 's/^(\s+)"Your apps",$/$1"Apps",/m' || fails=$((fails+1))
mut "M2 two titles swapped" pages \
  's/^(\s+)"Saving and storage",\n\s+"Locking and signing out",$/$1"Locking and signing out",\n$1"Saving and storage",/m' \
  || fails=$((fails+1))
mut "M3 a body given the word secure" pages 's/tap the mode beside an app/tap the mode beside a secure app/' \
  || fails=$((fails+1))
mut "M4 a body over 650 characters" gate \
  's/("Enter your profile name and passphrase, then tap Unlock\.")/$1 . " + \"" . ("x" x 600) . "\""/e' \
  || fails=$((fails+1))
mut "M5 a page with 2 steps" pages \
  's/(\{ \/\/ page 5[^\n]*\n(?:\s*"[^\n]*\n(?:\s*\+ "[^\n]*\n)*){2})(?:\s*"[^\n]*\n(?:\s*\+ "[^\n]*\n)*)+/$1/' \
  || fails=$((fails+1))
mut "M6 the throwaway array's Help row removed" profile \
  's/(new String\[\]\{"Security", "Preferences"), "Help"\}(,\s*new Runnable\[\]\{\(\) -> showSecurity\(\), \(\) -> showPreferences\(\)), \(\) -> showHelp\(\)\}/$1}$2}/' \
  || fails=$((fails+1))
mut "M7 showGateHelp reverted to its old literal sheet" chooser \
  'BEGIN { local $/; open my $f, "<", $ENV{OLD_GATE} or die; $old = <$f> } s/    private void showGateHelp\(\) \{\n.*?\n    \}\n/$old/s or die "M7: showGateHelp not found"' \
  || fails=$((fails+1))
mut "M8 \"Your apps\" added to the gate set" gate \
  's/^(\s+)"Signing in and creating a profile",$/$1"Signing in and creating a profile",\n$1"Your apps",/m or die "M8: title";
   s/^(\s+)\{ \/\/ page 1: Gate settings$/$1\{ \/\/ page 0b: Your apps\n$1    "Tap Your apps.",\n$1    "Tap an app.",\n$1    "Tap Back.",\n$1\},\n$1\{ \/\/ page 1: Gate settings/m or die "M8: page"' \
  || fails=$((fails+1))
mut "M9 showGateHelp pointed back at HelpPages" chooser \
  's/(    private void showGateHelp\(\) \{\n.*?\n    \}\n)/$1 =~ s#GateHelpPages\.#HelpPages.#gr/se or die "M9: showGateHelp not found"' \
  || fails=$((fails+1))
mut "M10 a Gate settings step given the word secure" gate 's/join a network/join a secure network/ or die "M10"' \
  || fails=$((fails+1))
mut "M11 the Owner settings page removed" gate \
  's/^\s+"Owner settings",\n//m or die "M11: title";
   s/^\s+\{ \/\/ page 2: Owner settings\n.*?^\s+\},\n//ms or die "M11: page"' \
  || fails=$((fails+1))
mut "M12 a seventh step on a gate page" gate \
  's/^(\s+)("Lock screen clock: [^\n]*"\n\s+\+ "[^\n]*",)$/$1$2\n$1"Tap Back.",/m or die "M12"' \
  || fails=$((fails+1))
mut "M13 (G6) the sun/moon step reverted to its text before NWP-20261124-15" gate \
  's/"The sun or moon left of \? switches between light and dark, unless the owner has kept the look to Owner "\n\s+\+ "settings\.",/"The sun or moon left of ? switches between light and dark.",/ or die "M13"' \
  || fails=$((fails+1))
mut "M14 Store settings named on Gate settings again" gate \
  's/"The gear at the top right opens Settings\. Wi-Fi: join a network\.",/"The gear at the top right opens Settings. Wi-Fi: join a network. Store settings: choose where profiles are saved.",/ or die "M14"' \
  || fails=$((fails+1))
mut "M15 Store settings dropped from Owner settings" gate \
  's/ Store settings: choose where profiles "\n\s+\+ "are saved\.",/",/ or die "M15"' \
  || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
