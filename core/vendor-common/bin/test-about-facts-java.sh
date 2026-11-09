#!/usr/bin/env bash
# test-about-facts-java.sh [--mutate] -- the gate's "About" page, run under javac (NWP-20261030-07).
#
# WHY THIS IS COMMITTED. The page shows the holder ro.boot.verifiedbootstate, ro.boot.flash.locked, the build number and
# the security patch level, and says what it cannot prove (decision 2026-10-20, docs/product-decisions.md, item 3).
# Two things must not drift with green CI: the words (a yellow state read as green, an unknown value echoed as a state,
# "0" read as Locked would tell a holder a false thing) and the wiring (each row reads its own property, the
# cannot-prove sentence is on the page, Settings opens the page). AboutFacts holds the words (pure, java.lang/java.util
# only) and is compiled here with its cases; a source check over ChooserActivity pins the wiring.
# NWP-20261117-42: the Settings row and the page share one name, AboutFacts.TITLE (decision 2026-10-29). The source
# check pins the row's subtitle byte for byte and refuses the old name "About this phone" anywhere in ChooserActivity.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-about-facts-java.sh            # the cases and the source check
#   bash test-about-facts-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="${ABOUT_FACTS_SRC:-$SRC/AboutFacts.java}"
CHOOSER="$SRC/ChooserActivity.java"
CASES="$root/core/chooser/tests/about-facts/AboutFactsCases.java"
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

# suite <AboutFacts.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  AboutFacts.java does not exist (the page's words are not lifted)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/AboutFacts.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/AboutFactsCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.AboutFactsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# source_check <ChooserActivity.java> -> 0 when the wiring holds, 1 otherwise.
source_check() {
  local chooser="$1" about settings keys want k n bad=0 about_t last_t back_t row_n title_n old_n
  about=$(awk '/private View buildAboutScreen\(\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$chooser")
  settings=$(awk '/private View buildSettingsScreen\(\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$chooser")
  [ -n "$about" ] || { echo "  FAIL  buildAboutScreen not found in $chooser" >&2; return 1; }
  [ -n "$settings" ] || { echo "  FAIL  buildSettingsScreen not found in $chooser" >&2; return 1; }

  keys=$(printf '%s\n' "$about" | grep -o 'sysProp("[^"]*"' | sort | tr '\n' ' ')
  want='sysProp("ro.boot.flash.locked" sysProp("ro.boot.verifiedbootstate" sysProp("ro.build.version.incremental" sysProp("ro.build.version.security_patch" '
  [ "$keys" = "$want" ] || { echo "  FAIL  the page reads <$keys>, want exactly <$want>" >&2; bad=1; }

  for k in 'AboutFacts.bootState(sysProp("ro.boot.verifiedbootstate"' \
           'AboutFacts.bootloader(sysProp("ro.boot.flash.locked"' \
           'AboutFacts.orNotReported(sysProp("ro.build.version.incremental"' \
           'AboutFacts.orNotReported(sysProp("ro.build.version.security_patch"'; do
    n=$(printf '%s\n' "$about" | grep -cF "$k")
    [ "$n" -eq 1 ] || { echo "  FAIL  the page has $n of <$k>, want 1" >&2; bad=1; }
  done
  n=$(printf '%s\n' "$about" | grep -c 'setText(AboutFacts\.CANNOT_PROVE)')
  [ "$n" -eq 1 ] || { echo "  FAIL  the page shows AboutFacts.CANNOT_PROVE $n times, want 1" >&2; bad=1; }
  n=$(printf '%s\n' "$about" | grep -c 'setContentView(buildSettingsScreen())')
  [ "$n" -ge 1 ] || { echo "  FAIL  the page has no way back to Settings" >&2; bad=1; }
  n=$(printf '%s\n' "$about" | grep -cE 'new Thread|daemonCmd|DaemonSocket')
  [ "$n" -eq 0 ] || { echo "  FAIL  the page makes a daemon call or starts a thread; its reads are synchronous" >&2; bad=1; }

  about_t=$(printf '%s\n' "$settings" | awk '/settingsRow\(AboutFacts\.TITLE,/ { print NR; exit }')
  back_t=$(printf '%s\n' "$settings" | awk '/TextView back = new TextView\(this\);/ { print NR; exit }')
  if [ -z "$about_t" ]; then
    echo "  FAIL  Settings has no About row" >&2; bad=1
  else
    n=$(printf '%s\n' "$settings" | awk -v s="$about_t" 'NR >= s && NR <= s + 2 && /setContentView\(buildAboutScreen\(\)\)/ { c++ } END { print c + 0 }')
    [ "$n" -eq 1 ] || { echo "  FAIL  the About row does not open buildAboutScreen" >&2; bad=1; }
    last_t=$(printf '%s\n' "$settings" | awk -v a="$about_t" 'NR != a && /ll\.addView\(/ && !/ll\.addView\(back,/ { n = NR } END { print n + 0 }')
    { [ -n "$back_t" ] && [ "$last_t" -lt "$about_t" ] && [ "$about_t" -lt "$back_t" ]; } \
      || { echo "  FAIL  the About row is not the last row above Back" >&2; bad=1; }
  fi
  row_n=$(printf '%s\n' "$settings" | grep -cF 'settingsRow(AboutFacts.TITLE, "Verified boot, bootloader lock, build and patch level",')
  [ "$row_n" -eq 1 ] || { echo "  FAIL  the About row's subtitle is not \"Verified boot, bootloader lock, build and patch level\"" >&2; bad=1; }
  title_n=$(printf '%s\n' "$about" | grep -cF 'ownerColumn(AboutFacts.TITLE)')
  [ "$title_n" -eq 1 ] || { echo "  FAIL  the About page's title is not ownerColumn(AboutFacts.TITLE)" >&2; bad=1; }
  old_n=$(grep -cF 'About this phone' "$chooser")
  [ "$old_n" -eq 0 ] || { echo "  FAIL  ChooserActivity.java still says \"About this phone\" $old_n time(s)" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
source_check "$CHOOSER" || { echo "FAILED (source)"; exit 1; }
echo "source: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates AboutFacts.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/AboutFacts.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutsrc() { # mutsrc <label> <perl-expr>   (mutates ChooserActivity.java; the source check must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$CHOOSER" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$CHOOSER" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  source_check "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "A1 yellow mapped to the green text" 's/return "Verified with a custom key[^;]*?;/return "Verified \\u2014 checked at boot against the phone maker\x27s key";/s' || fails=$((fails+1))
mut "A2 the unknown arm echoes the raw value" 's/default:\n(\s+)return NOT_REPORTED;/default:\n$1return v;/' || fails=$((fails+1))
mut "A3 the lower-casing dropped" 's/\.toLowerCase\(Locale\.ROOT\)//' || fails=$((fails+1))
mut "A4 0 mapped to Locked" 's/t\.equals\("0"\)\) return "Unlocked"/t.equals("0")) return "Locked"/' || fails=$((fails+1))
mutsrc "A5 CANNOT_PROVE not shown on the page" 's/setText\(AboutFacts\.CANNOT_PROVE\)/setText("")/' || fails=$((fails+1))
mutsrc "A6 the Settings row removed" 's/ll\.addView\(settingsRow\(AboutFacts\.TITLE.*?\n.*?\n//' || fails=$((fails+1))
mutsrc "A7 verifiedbootstate read from a different key" 's/sysProp\("ro\.boot\.verifiedbootstate"/sysProp("ro.boot.vbmeta.device_state"/' || fails=$((fails+1))
mutsrc "A8 the About row moved back to right after Wi-Fi" 'my $blk; s/(        LinearLayout\.LayoutParams alp = [^\n]*\n        alp\.topMargin = dp\(22\);\n        ll\.addView\(settingsRow\(AboutFacts\.TITLE[^\n]*\n[^\n]*\n)\n?/$blk = $1; ""/e; die "A8: About block not found" unless defined $blk; s/(        ll\.addView\(settingsRow\("Wi-Fi"[^\n]*\n[^\n]*\n)/$1 . $blk/e' || fails=$((fails+1))
mut "A9 TITLE back to About this phone" 's/TITLE = "About";/TITLE = "About this phone";/' || fails=$((fails+1))
mutsrc "A10 the row names a literal About this phone" 's/settingsRow\(AboutFacts\.TITLE,/settingsRow("About this phone",/' || fails=$((fails+1))
mutsrc "A11 the page title a literal" 's/ownerColumn\(AboutFacts\.TITLE\)/ownerColumn("About")/' || fails=$((fails+1))
mutsrc "A12 the row's subtitle changed" 's/"Verified boot, bootloader lock, build and patch level"/"Verified boot, bootloader lock, build and patch"/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
