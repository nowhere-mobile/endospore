#!/usr/bin/env bash
# test-save-lines-refresh-java.sh [--mutate] -- Your data repaints its save lines when a save lands while the screen
# is open, run under javac (NWP-20261121-04).
#
# WHY THIS IS COMMITTED. showYourData painted the headline, the sub-line, the apps line and the "Changed on this phone
# since the last save" count once (loadSealDelta), and only a manual Back up painted them again. A periodic save that
# landed while the screen was open stored the counted bytes, but the screen kept "~300 MB" changed until it was left
# and reopened (lynx 2026102201, NWP-20261024-18). Now the open screen reads GET-SEAL-LANDED every POLL_MS and runs
# loadSealDelta again once the stamp moves past the one the lines were painted for (SaveLinesRefresh). Drop a link
# (the poll never started, the load never records its stamp, or records it after SEAL-DELTA) and the screen goes stale
# again, with green CI.
#
# SaveLinesRefresh is pure java.lang and is compiled here with BackNowCycle (its one parser) and its cases. Source
# pins (comment lines stripped) hold showYourData, loadSealDelta, startSaveLinesPoll, onPause and onResume.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-save-lines-refresh-java.sh            # the cases and the pins
#   bash test-save-lines-refresh-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/SaveLinesRefresh.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/save-lines-refresh/SaveLinesRefreshCases.java"
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

# suite <SaveLinesRefresh.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  SaveLinesRefresh.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/SaveLinesRefresh.java"
  cp "$SRC/BackNowCycle.java" "$d/src/com/nowhere/chooser/"
  cp "$CASES" "$d/src/com/nowhere/chooser/SaveLinesRefreshCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.SaveLinesRefreshCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# mbody <file> <regex>: a method's body, from its signature to the closing brace at four spaces, comment lines dropped.
mbody() {
  RE="$2" awk '$0 ~ ENVIRON["RE"] { on = 1 } on && $0 !~ /^[ \t]*(\/\/|\*|\/\*)/ { print } on && /^    }$/ { exit }' "$1"
}
# fcount <body> <literal>: lines holding the fixed string.
fcount() { printf '%s\n' "$1" | S="$2" awk 'index($0, ENVIRON["S"]) { n++ } END { print n + 0 }'; }
# fline <body> <literal>: the first line number holding the fixed string, empty when none.
fline() { printf '%s\n' "$1" | S="$2" awk 'index($0, ENVIRON["S"]) { print NR; exit }'; }
# nline <body> <n>: line n, with its leading blanks dropped.
nline() { printf '%s\n' "$1" | sed -n "${2}p" | sed 's/^[ \t]*//'; }

# pins <ProfileActivity.java> -> 0 when the wiring holds, 1 otherwise.
pins() {
  local pa="$1" bad=0 syd lsd ssp onr onp n l p s fin
  syd=$(mbody "$pa" 'private void showYourData\(\) \{')
  lsd=$(mbody "$pa" 'private void loadSealDelta\(\) \{')
  ssp=$(mbody "$pa" 'private void startSaveLinesPoll\(final TextView mine\) \{')
  onr=$(mbody "$pa" 'protected void onResume\(\) \{')
  onp=$(mbody "$pa" 'protected void onPause\(\) \{')
  # A missing body is reported and the checks still run, so each one shows what it holds.
  for n in syd lsd ssp onr onp; do [ -n "${!n}" ] || { echo "  FAIL  pins: $n body not found" >&2; bad=1; }; done

  # P1: showYourData starts the poll for its own headline view, after the first paint.
  l=$(fline "$syd" 'loadSealDelta();'); p=$(fline "$syd" 'startSaveLinesPoll(savedHeadTv);')
  if [ "$(fcount "$syd" 'loadSealDelta();')" -ne 1 ] || [ "$(fcount "$syd" 'startSaveLinesPoll(')" -ne 1 ] \
     || [ -z "$p" ]; then
    echo "  FAIL  P1 showYourData does not call loadSealDelta() and startSaveLinesPoll(savedHeadTv) once each" >&2; bad=1
  elif [ "$p" -le "$l" ]; then
    echo "  FAIL  P1 showYourData starts the poll before its loadSealDelta()" >&2; bad=1
  fi

  # P2: loadSealDelta marks itself loading first, records GET-SEAL-LANDED before SEAL-DELTA, and clears the mark in a
  # finally.
  [ "$(nline "$lsd" 2)" = 'new Thread(() -> {' ] && [ "$(nline "$lsd" 3)" = 'deltaLoading.set(true);' ] \
    || { echo "  FAIL  P2 loadSealDelta's thread does not start with deltaLoading.set(true)" >&2; bad=1; }
  p=$(printf '%s\n' "$lsd" | awk 'index($0, "saveLines.painted(") && index($0, "sendDaemon(\"GET-SEAL-LANDED\\n\")") { print NR; exit }')
  s=$(fline "$lsd" 'daemonLenReply("SEAL-DELTA\n"')
  if [ "$(fcount "$lsd" 'saveLines.painted(')" -ne 1 ] || [ -z "$p" ]; then
    echo "  FAIL  P2 loadSealDelta does not call saveLines.painted(...sendDaemon(\"GET-SEAL-LANDED\\n\")) once" >&2; bad=1
  elif [ -z "$s" ] || [ "$p" -ge "$s" ]; then
    echo "  FAIL  P2 loadSealDelta records GET-SEAL-LANDED after its SEAL-DELTA read" >&2; bad=1
  fi
  fin=$(fline "$lsd" '} finally {')
  if [ -z "$fin" ] || [ "$(nline "$lsd" $((fin + 1)))" != 'deltaLoading.set(false);' ]; then
    echo "  FAIL  P2 loadSealDelta does not clear deltaLoading in a finally" >&2; bad=1
  fi

  # P3: the poll stops on keepPolling, reads off the UI thread, repaints only when due, and ticks every POLL_MS.
  for s in 'if (!SaveLinesRefresh.keepPolling(savedHeadTv == mine, mine.isAttachedToWindow(), isFinishing())) return;' \
           'saveLines.due(stamp, deltaLoading.get() || paused)' 'SaveLinesRefresh.POLL_MS' \
           'SaveLinesRefresh.parseLanded(sendDaemon("GET-SEAL-LANDED\n"))' 'new Thread(' 'loadSealDelta();'; do
    [ "$(fcount "$ssp" "$s")" -ge 1 ] || { echo "  FAIL  P3 startSaveLinesPoll does not hold '$s'" >&2; bad=1; }
  done
  # The read is inside the thread: the thread opens before it.
  l=$(fline "$ssp" 'new Thread('); s=$(fline "$ssp" 'sendDaemon("GET-SEAL-LANDED\n")')
  [ -n "$l" ] && [ -n "$s" ] && [ "$l" -lt "$s" ] \
    || { echo "  FAIL  P3 startSaveLinesPoll reads GET-SEAL-LANDED outside its background thread" >&2; bad=1; }

  # P4: onResume clears paused, onPause sets it.
  [ "$(fcount "$onr" 'super.onResume();')" -eq 1 ] && [ "$(fcount "$onr" 'paused = false;')" -eq 1 ] \
    || { echo "  FAIL  P4 onResume does not call super.onResume() and set paused = false" >&2; bad=1; }
  [ "$(fcount "$onp" 'paused = true;')" -eq 1 ] \
    || { echo "  FAIL  P4 onPause does not set paused = true" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
pins "$PA" || { echo "FAILED (pins)"; exit 1; }
echo "pins: ok"
[ "$MUTATE" = yes ] || { echo "PASS"; exit 0; }

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates SaveLinesRefresh.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/SaveLinesRefresh.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation did not apply"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  CONVICTED $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutpin() { # mutpin <label> <perl-expr>   (mutates ProfileActivity.java; the pins must fail)
  local d c rc why
  d=$(mktemp -d -p "$W") || return 1; c="$d/ProfileActivity.java"
  cp "$PA" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$PA" "$c"; then echo "  INERT     $1 -- the mutation did not apply"; rm -rf "$d"; return 1; fi
  why=$(pins "$c" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  CONVICTED $1 --$(printf '%s\n' "$why" | grep -m1 'FAIL' | sed 's/^ *FAIL//')"
}
fails=0
mut "M1 parseLanded reads a bad reply as 0" \
  's/return BackNowCycle\.landedStamp\(reply\);/long v = BackNowCycle.landedStamp(reply); return v < 0 ? 0 : v;/' || fails=$((fails+1))
mut "M2 due is true for the stamp already painted" \
  's/if \(stamp == painted\) return false;/if (stamp == painted) return true;/' || fails=$((fails+1))
mut "M3 due ignores the hold" 's/\n *if \(hold\) return false;//' || fails=$((fails+1))
mut "M4 due is true on the seed" \
  's/(if \(painted == NOTHING\) \{\n *painted = stamp;\n *)return false;/${1}return true;/' || fails=$((fails+1))
mut "M5 keepPolling ignores attached" \
  's/return sameView && attached && !finishing;/return sameView \&\& !finishing;/' || fails=$((fails+1))
mut "M6 keepPolling ignores sameView" \
  's/return sameView && attached && !finishing;/return attached \&\& !finishing;/' || fails=$((fails+1))
mutpin "M7 showYourData never starts the poll" 's/\n *startSaveLinesPoll\(savedHeadTv\);[^\n]*//' || fails=$((fails+1))
mutpin "M8 loadSealDelta never records its stamp" \
  's/\n *saveLines\.painted\(SaveLinesRefresh\.parseLanded\(sendDaemon\("GET-SEAL-LANDED\\n"\)\)\);//' || fails=$((fails+1))
mutpin "M9 loadSealDelta records its stamp after the SEAL-DELTA read" \
  's/(private void loadSealDelta\(\) \{.*?)\n( *saveLines\.painted\(SaveLinesRefresh\.parseLanded\(sendDaemon\("GET-SEAL-LANDED\\n"\)\)\);)(.*?\n *String\[\] lr = daemonLenReply\("SEAL-DELTA\\n", 15000\);)/$1$3\n$2/s' \
  || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "PASS: 9 of 9 mutants convicted" || { echo "== $fails mutant(s) not convicted"; exit 1; }
