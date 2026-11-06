#!/usr/bin/env bash
# test-reap-rearm-java.sh [--mutate] -- the gate's REARM phase, run under javac (NWP-20261031-03).
#
# WHY THIS IS COMMITTED. A cold lock revoked after its reply by a logoff queues `REARM <uid>` on POLL-REAP
# (NWP-20261031-02). If the gate's reap watcher ignores it, the fire that queued the lock stays spent and a live
# session keeps no idle bound. ReapRearm.uid (pure) parses the line and is compiled here with its cases; a source
# check over ChooserActivity pins the branch: it parses with ReapRearm.uid, re-arms with
# IdleLogoffReceiver.NOLOCK_REGRACE_MS, and acks "REARM" AFTER the re-arm.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-reap-rearm-java.sh            # the cases and the source check
#   bash test-reap-rearm-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/ReapRearm.java"
CHOOSER="$SRC/ChooserActivity.java"
IDLE="$SRC/IdleLogoffReceiver.java"
CASES="$root/core/chooser/tests/reap-rearm/ReapRearmCases.java"
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

# suite <ReapRearm.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  ReapRearm.java does not exist (the parse is not lifted)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/ReapRearm.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/ReapRearmCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.ReapRearmCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# order <ChooserActivity.java> <IdleLogoffReceiver.java> -> 0 when the shipped branch holds, 1 otherwise.
order() {
  local chooser="$1" idle="$2" body bad=0 uid_t rearm_t ack_t
  body=$(awk '/else if \(reply\.startsWith\("REARM "\)\)/ { on = 1 } on { print } on && /^                }$/ { exit }' "$chooser")
  [ -n "$body" ] || { echo "  FAIL  the POLL-REAP chain has no REARM branch in $chooser" >&2; return 1; }
  uid_t=$(printf '%s\n' "$body" | awk '$0 !~ /^[ \t]*\/\// && /ReapRearm\.uid\(reply\)/ { print NR; exit }')
  rearm_t=$(printf '%s\n' "$body" | awk '$0 !~ /^[ \t]*\/\// && /rearmIdleShort\(app, IdleLogoffReceiver\.NOLOCK_REGRACE_MS\)/ { print NR; exit }')
  ack_t=$(printf '%s\n' "$body" | awk '$0 !~ /^[ \t]*\/\// && /ackReap\("REARM", uid\)/ { print NR; exit }')
  [ -n "$uid_t" ]   || { echo "  FAIL  the REARM branch does not parse with ReapRearm.uid" >&2; bad=1; }
  [ -n "$rearm_t" ] || { echo "  FAIL  the REARM branch does not call rearmIdleShort with NOLOCK_REGRACE_MS" >&2; bad=1; }
  [ -n "$ack_t" ]   || { echo "  FAIL  the REARM branch does not ack \"REARM\"" >&2; bad=1; }
  [ "$bad" -eq 0 ] || return 1
  [ "$uid_t" -lt "$rearm_t" ] || { echo "  FAIL  the parse is not before the re-arm" >&2; bad=1; }
  [ "$rearm_t" -lt "$ack_t" ] || { echo "  FAIL  the ack is not after the re-arm" >&2; bad=1; }
  grep -Eq '^\s+static final long NOLOCK_REGRACE_MS' "$idle" \
    || { echo "  FAIL  NOLOCK_REGRACE_MS is not package-private static final" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
order "$CHOOSER" "$IDLE" || { echo "FAILED (order)"; exit 1; }
echo "order: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates ReapRearm.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ReapRearm.java"
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
mutord() { # mutord <label> <perl-expr>   (mutates ChooserActivity.java; the order check must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1
  c="$d/ChooserActivity.java"
  cp "$CHOOSER" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$CHOOSER" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  order "$c" "$IDLE" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mutord "K1 the ack dropped" 's/\n\s+ackReap\("REARM", uid\);//' || fails=$((fails+1))
mutord "K2 rearmIdleShort dropped" 's/\n\s+rearmIdleShort\(app, IdleLogoffReceiver\.NOLOCK_REGRACE_MS\);//' || fails=$((fails+1))
mut "K3 uid() accepts a sign" 's/if \(c < .0. \|\| c > .9.\) return -1;/if ((c < \x270\x27 || c > \x279\x27) \&\& c != \x27-\x27) return -1;/' || fails=$((fails+1))
mutord "K4 the ack sends LOCK" 's/ackReap\("REARM", uid\)/ackReap("LOCK", uid)/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
