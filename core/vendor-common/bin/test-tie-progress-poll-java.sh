#!/usr/bin/env bash
# test-tie-progress-poll-java.sh [--mutate] -- the Tie screen polls only while it is in front and something is still
# moving, run under javac (NWP-20261129-32).
#
# WHY THIS IS COMMITTED. showTieProgress looped on `while (up.get())`, and only the block's detach listener cleared
# `up`. So the poll outlived the screen three ways: Back during the SE-STATUS read (the block was already detached and
# the listener never fired), Home or screen off (the views stay attached), and every scope done. Each SE-PROGRESS takes
# sessionMu in the login daemon and up to a dozen store reads (seProgressReply), so a stray poll delays each materialise,
# Back up now and the sign-out behind it, with green CI. Now every pass asks TieProgressPoll first.
#
# TieProgressPoll is pure java.lang and is compiled here with its cases. Source pins (comment lines stripped) hold
# showTieProgress.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-tie-progress-poll-java.sh            # the cases and the pins
#   bash test-tie-progress-poll-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/TieProgressPoll.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/tie-progress-poll/TieProgressPollCases.java"
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

# suite <TieProgressPoll.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  TieProgressPoll.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/TieProgressPoll.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/TieProgressPollCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.TieProgressPollCases 2>&1); rc=$?
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
# wcount <body> <line>: lines that equal the string, indent included.
wcount() { printf '%s\n' "$1" | S="$2" awk '$0 == ENVIRON["S"] { n++ } END { print n + 0 }'; }

# pins <ProfileActivity.java> -> 0 when the wiring holds, 1 otherwise.
pins() {
  local pa="$1" bad=0 stp s l r
  stp=$(mbody "$pa" 'private void showTieProgress\(final LinearLayout prog\) \{')
  [ -n "$stp" ] || { echo "  FAIL  pins: showTieProgress body not found" >&2; bad=1; }

  # P1: `up` starts from whether the block is on screen, so a block already off screen never polls.
  [ "$(fcount "$stp" 'AtomicBoolean(prog.isAttachedToWindow())')" -eq 1 ] \
    || { echo "  FAIL  P1 up does not start from prog.isAttachedToWindow()" >&2; bad=1; }
  # P2: one step call, with the attachment, the activity's end, paused and settled.
  [ "$(fcount "$stp" 'TieProgressPoll.step(up.get(), isFinishing() || isDestroyed(), paused, settled)')" -eq 1 ] \
    && [ "$(fcount "$stp" 'TieProgressPoll.step(')" -eq 1 ] \
    || { echo "  FAIL  P2 showTieProgress does not ask TieProgressPoll.step(...) once with all four inputs" >&2; bad=1; }
  # P3: STOP ends the thread.
  [ "$(fcount "$stp" 'if (step == TieProgressPoll.Step.STOP) return;')" -eq 1 ] \
    || { echo "  FAIL  P3 STOP does not return" >&2; bad=1; }
  # P4: one read, in the READ branch, after the step check.
  s=$(fline "$stp" 'TieProgressPoll.step(')
  l=$(fline "$stp" 'if (step == TieProgressPoll.Step.READ) {')
  r=$(fline "$stp" 'sendDaemonMulti("SE-PROGRESS\n")')
  if [ "$(fcount "$stp" 'sendDaemonMulti("SE-PROGRESS\n")')" -ne 1 ] || [ -z "$s" ] || [ -z "$l" ] || [ -z "$r" ]; then
    echo "  FAIL  P4 showTieProgress does not hold one SE-PROGRESS read and a READ branch" >&2; bad=1
  elif [ "$s" -ge "$l" ] || [ "$l" -ge "$r" ]; then
    echo "  FAIL  P4 the SE-PROGRESS read is not inside the READ branch, after the step check" >&2; bad=1
  fi
  # P5: the reply decides settled.
  l=$(fline "$stp" 'settled = TieProgressPoll.settled(')
  if [ "$(fcount "$stp" 'settled = TieProgressPoll.settled(')" -ne 1 ] || [ -z "$l" ] || [ -z "$r" ] || [ "$l" -le "$r" ]; then
    echo "  FAIL  P5 settled is not set once from the SE-PROGRESS reply, after the read" >&2; bad=1
  fi
  # P6: a late reply never paints a block that left the screen.
  [ "$(fcount "$stp" 'if (up.get()) renderTieProgress(prog, r);')" -eq 1 ] \
    || { echo "  FAIL  P6 the paint is not under if (up.get())" >&2; bad=1; }
  # P7: the old loop is gone.
  [ "$(fcount "$stp" 'while (up.get())')" -eq 0 ] \
    || { echo "  FAIL  P7 while (up.get()) is still there" >&2; bad=1; }
  # P8: the detach listener still clears up.
  [ "$(fcount "$stp" 'up.set(false);')" -eq 1 ] \
    || { echo "  FAIL  P8 the detach listener does not clear up" >&2; bad=1; }
  # P9: every pass sleeps. The indent puts the sleep in the loop, outside the READ branch: inside it, WAIT would spin.
  [ "$(wcount "$stp" '                try { Thread.sleep(TieProgressPoll.POLL_MS); } catch (InterruptedException e) { return; }')" -eq 1 ] \
    || { echo "  FAIL  P9 the POLL_MS sleep is not on every pass" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
rc=0
suite "$SUT" || rc=1
pins "$PA" || { echo "FAILED (pins)"; rc=1; }
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "pins: ok"
[ "$MUTATE" = yes ] || { echo "PASS"; exit 0; }

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates TieProgressPoll.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/TieProgressPoll.java"
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
mut "T1 step reads while paused" 's/\n *if \(paused\) return Step\.WAIT;//' || fails=$((fails+1))
mut "T2 step ignores settled" 's/ \|\| settled\) return Step\.STOP;/) return Step.STOP;/' || fails=$((fails+1))
mutpin "T3 up starts true" 's/AtomicBoolean\(prog\.isAttachedToWindow\(\)\)/AtomicBoolean(true)/' || fails=$((fails+1))
mut "T4 settled true for any OK" \
  's/reply\.startsWith\("OK NONE"\)\) return true;/reply.startsWith("OK")) return true;/' || fails=$((fails+1))
mut "T5 settled false for OK NONE" \
  's/reply\.startsWith\("OK NONE"\)\) return true;/reply.startsWith("OK NONE")) return false;/' || fails=$((fails+1))
mutpin "T6 the SE-PROGRESS read moved before the step check" \
  's/(Step\.READ\) \{)\n *final String r = sendDaemonMulti\("SE-PROGRESS\\n"\);/$1/; s/(\n *final TieProgressPoll\.Step step =)/\n                final String r = sendDaemonMulti("SE-PROGRESS\\n");$1/' \
  || fails=$((fails+1))
mut "T7 settled true for an OK with no rows" 's/return rows > 0;/return true;/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "PASS: 7 of 7 mutants convicted" || { echo "== $fails mutant(s) not convicted"; exit 1; }
