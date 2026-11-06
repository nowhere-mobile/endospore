#!/usr/bin/env bash
# test-coldlock-cover-retire-java.sh [--mutate] -- the cold-lock cover retires on the gate's own timer when no
# onResume comes, run under javac (NWP-20261120-19).
#
# WHY THIS IS COMMITTED. Backlog row "THE GATE STAYS ON THE “Locking…” COVER AFTER A HAND-SWITCH TEARDOWN, UNTIL
# THE SCREEN IS CYCLED". The #134 cover was retired, and the GET-COLDLOCK reveal run, only from onResume. A
# hand-switch to user 0 arms the cover while the gate is already in front, so no onResume follows the cold lock and
# the gate sat on "Locking…" until the screen was cycled. doColdLock now asks the live gate to schedule the retire
# at the end of SWITCH_COVER_MS (scheduleColdCoverRetire); the timing and the act-or-not rule live in
# ColdCoverRetire, a pure class with no android.* import, compiled here with its cases. Source pins check that
# doColdLock schedules the retire after applySigningOutUi, that the retire runnable asks ColdCoverRetire.due and
# SwitchCoverHold.revealStandsAside before it clears coldLockIn, that its UI step re-checks revealStandsAside before
# applyColdLockReveal, that onResume and the runnable both reach applyColdLockReveal, and that onResume still holds
# both revealStandsAside guards.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-coldlock-cover-retire-java.sh            # the cases + source pins
#   bash test-coldlock-cover-retire-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src"
COPY="$SRC/com/nowhere/chooser/ColdCoverRetire.java"
ACT="$SRC/com/nowhere/chooser/ChooserActivity.java"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl, and there is none" >&2; exit 2; }
[ -f "$ACT" ] || { echo "FAIL: missing $ACT" >&2; exit 2; }

# The cases, written into the run's own temp dir (window 15000 ms, coldLockInAt 100000).
CASES="$W/ColdCoverRetireCases.java"
cat >"$CASES" <<'EOF'
package com.nowhere.chooser;

public final class ColdCoverRetireCases {
    private static int failed = 0;

    private static void check(String name, boolean ok) {
        System.out.println((ok ? "  ok    " : "  FAIL  ") + name);
        if (!ok) failed++;
    }

    public static void main(String[] args) {
        final long at = 100000L, win = 15000L;
        check("delayMs inside the window: the rest of the window plus 250 ms",
                ColdCoverRetire.delayMs(101000L, at, win) == 14250L);
        check("delayMs at the end of the window: 250 ms",
                ColdCoverRetire.delayMs(115000L, at, win) == 250L);
        check("delayMs after the window: 250 ms, never negative",
                ColdCoverRetire.delayMs(200000L, at, win) == 250L);
        check("due is false inside the window with coldLockIn set (the #134 cover holds)",
                !ColdCoverRetire.due(true, true, true, 101000L, at, win));
        check("due is true at the end of the window",
                ColdCoverRetire.due(true, true, true, 115000L, at, win));
        check("due is false with no cover up",
                !ColdCoverRetire.due(true, false, true, 120000L, at, win));
        check("due is false when this is not the live gate",
                !ColdCoverRetire.due(false, true, true, 120000L, at, win));
        check("due is true with coldLockIn already cleared and the cover up",
                ColdCoverRetire.due(true, true, false, 101000L, at, win));
        if (failed > 0) { System.out.println("  " + failed + " case(s) failed"); System.exit(1); }
    }
}
EOF

LOGLINE="cold-lock cover retired by the gate's own timer (no onResume came)"
STANDS='SwitchCoverHold.revealStandsAside(signingOut, resumeBusy, loginInProgress, switchingIn)'
TEARDOWN='        if (coverShown) { setContentView(gateView); coverShown = false; }'

# method <file> <ERE of the signature line> -> the method, from its signature to the first 4-space '}'.
method() {
  RE="$2" awk '$0 ~ ENVIRON["RE"] { on = 1 } on { print } on && /^    }$/ { exit }' "$1"
}
# line_of <text> <fixed string> -> the first line number holding it, or empty.
line_of() { grep -n -F -- "$2" <<<"$1" | head -1 | cut -d: -f1; }

# pins <ChooserActivity.java> -> 0 clean, 1 a pin failed.
pins() {
  local act="$1" bad=0 resume cold sched apply n next l_due l_rsa1 l_rsa2 l_clear l_apply first
  resume=$(method "$act" '^    protected void onResume\(\) \{$' | sed 's,//.*$,,')
  cold=$(method "$act" '^    private static void doColdLock\(' | sed 's,//.*$,,')
  sched=$(method "$act" '^    private void scheduleColdCoverRetire\(\) \{$' | sed 's,//.*$,,')
  apply=$(method "$act" '^    private void applyColdLockReveal\(String cl\) \{$' | sed 's,//.*$,,')
  case "$resume" in *'lockGate(true)'*) ;; *) echo "  PIN control: the extraction did not find onResume" >&2; return 1 ;; esac
  case "$cold" in *'armWipeWatcher(app, uid);'*) ;; *) echo "  PIN control: the extraction did not find doColdLock" >&2; return 1 ;; esac
  [ -n "$sched" ] || { echo "  PIN R2 there is no 'private void scheduleColdCoverRetire() {'" >&2; bad=1; }
  [ -n "$apply" ] || { echo "  PIN R6 there is no 'private void applyColdLockReveal(String cl) {'" >&2; bad=1; }

  # R1: doColdLock's next statement after g.applySigningOutUi() schedules the retire; one call in the whole file.
  next=$(grep -v -E '^\s*$' <<<"$cold" | awk 'f { sub(/^[ \t]+/, ""); print; exit } /^[ \t]*g\.applySigningOutUi\(\);[ \t]*$/ { f = 1 }')
  [ "$next" = 'g.scheduleColdCoverRetire();' ] \
    || { echo "  PIN R1 doColdLock's statement after g.applySigningOutUi() is not g.scheduleColdCoverRetire(); (got: $next)" >&2; bad=1; }
  n=$(sed 's,//.*$,,' "$act" | grep -c -F 'scheduleColdCoverRetire();')
  [ "$n" = 1 ] || { echo "  PIN R1 scheduleColdCoverRetire(); is called $n time(s) in the file, want 1" >&2; bad=1; }

  # R2: the runnable asks ColdCoverRetire.due and revealStandsAside before it clears coldLockIn.
  if [ -n "$sched" ]; then
    for n in 'ColdCoverRetire.due(sLiveGate == this, coverShown, coldLockIn,' 'ColdCoverRetire.delayMs(' 'postDelayed('; do
      case "$sched" in *"$n"*) ;; *) echo "  PIN R2 scheduleColdCoverRetire does not hold '$n'" >&2; bad=1 ;; esac
    done
    l_due=$(line_of "$sched" 'ColdCoverRetire.due(')
    l_rsa1=$(line_of "$sched" "if ($STANDS) return;")
    l_clear=$(line_of "$sched" 'coldLockIn = false;')
    l_rsa2=$(grep -n -F -- "if ($STANDS) return;" <<<"$sched" | sed -n 2p | cut -d: -f1)
    l_apply=$(line_of "$sched" 'applyColdLockReveal(cl);')
    if [ -z "$l_due" ] || [ -z "$l_rsa1" ] || [ -z "$l_clear" ] || [ "$l_due" -ge "$l_clear" ] || [ "$l_rsa1" -ge "$l_clear" ]; then
      echo "  PIN R2 the retire runnable does not ask ColdCoverRetire.due and revealStandsAside before 'coldLockIn = false;'" >&2; bad=1
    fi
    # R3: the UI step re-checks revealStandsAside before applyColdLockReveal; GET-COLDLOCK, the log, no #73 sweep.
    if [ -z "$l_rsa2" ] || [ -z "$l_apply" ] || [ -z "$l_clear" ] || [ "$l_rsa2" -le "$l_clear" ] || [ "$l_rsa2" -ge "$l_apply" ]; then
      echo "  PIN R3 the retire's UI step does not re-check revealStandsAside before applyColdLockReveal(cl)" >&2; bad=1
    fi
    for n in 'sendDaemon("GET-COLDLOCK\n").trim()' "$LOGLINE" 'runOnUiThread(() -> {'; do
      case "$sched" in *"$n"*) ;; *) echo "  PIN R3 scheduleColdCoverRetire does not hold '$n'" >&2; bad=1 ;; esac
    done
    case "$sched" in *reapOrphanSecondaryUsers*) echo "  PIN R3 scheduleColdCoverRetire runs the #73 orphan-reap sweep" >&2; bad=1 ;; esac
  fi

  # R4: applyColdLockReveal is reached from onResume and from the retire runnable, and from nowhere else.
  n=$(sed 's,//.*$,,' "$act" | grep -c -F 'applyColdLockReveal(cl);')
  [ "$n" = 2 ] || { echo "  PIN R4 applyColdLockReveal(cl); is called $n time(s) in the file, want 2" >&2; bad=1; }
  n=$(grep -c -F 'applyColdLockReveal(cl);' <<<"$resume")
  [ "$n" = 1 ] || { echo "  PIN R4 onResume calls applyColdLockReveal(cl); $n time(s), want 1" >&2; bad=1; }
  n=$(grep -c -F 'applyColdLockReveal(cl);' <<<"$sched")
  [ "$n" = 1 ] || { echo "  PIN R4 scheduleColdCoverRetire calls applyColdLockReveal(cl); $n time(s), want 1" >&2; bad=1; }

  # R5: onResume still holds both revealStandsAside guards, and the #73 sweep stays there.
  n=$(grep -c -F 'SwitchCoverHold.revealStandsAside(' <<<"$resume")
  [ "$n" = 2 ] || { echo "  PIN R5 onResume calls SwitchCoverHold.revealStandsAside( $n time(s), want 2" >&2; bad=1; }
  case "$resume" in *reapOrphanSecondaryUsers*) ;; *) echo "  PIN R5 onResume lost the #73 orphan-reap sweep" >&2; bad=1 ;; esac

  # R6: applyColdLockReveal's first statement re-attaches the gate under the cover.
  if [ -n "$apply" ]; then
    first=$(sed '1d' <<<"$apply" | grep -v -E '^\s*$' | head -1)
    [ "$first" = "$TEARDOWN" ] || { echo "  PIN R6 applyColdLockReveal's first statement is not the cover teardown (got: $first)" >&2; bad=1; }
  fi
  return "$bad"
}

# suite <ColdCoverRetire.java> <ChooserActivity.java> -> 0 pass, 1 a case or pin failed (the only code that
# convicts a mutant), 3 the class or the cases did not compile.
suite() {
  local copy="$1" act="$2" d out rc bad=0
  pins "$act" || bad=1
  [ -f "$copy" ] || { echo "  FAIL  ColdCoverRetire.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$copy" "$d/src/com/nowhere/chooser/ColdCoverRetire.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/ColdCoverRetireCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.ColdCoverRetireCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && [ "$bad" -eq 0 ] && return 0
  return 1
}

echo "== $COPY"
suite "$COPY" "$ACT" || { echo "FAILED"; exit 1; }
echo "== all cases and source pins pass"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <copy|act> <perl-expr>
  local d c a rc target; d=$(mktemp -d -p "$W"); c="$d/ColdCoverRetire.java"; a="$d/ChooserActivity.java"
  cp "$COPY" "$c"; cp "$ACT" "$a"
  target="$c"; [ "$2" = act ] && target="$a"
  if ! perl -0pi -e "$3" "$target"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$COPY" "$c" && cmp -s "$ACT" "$a"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" "$a" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "C1 delayMs ignores coldLockInAt (fires at once)"   copy 's/coldLockInAt \+ windowMs - now/0L/' || fails=$((fails+1))
mut "C2 due ignores coverShown"                         copy 's/liveGate && coverShown && /liveGate && /' || fails=$((fails+1))
mut "C3 due ignores the window"                         copy 's/\(!coldLockIn \|\| now - coldLockInAt >= windowMs\)/true/' || fails=$((fails+1))
mut "C4 doColdLock does not schedule the retire"        act  's/\n[ ]*g\.scheduleColdCoverRetire\(\);[^\n]*//' || fails=$((fails+1))
mut "C5 the retire runnable skips revealStandsAside"    act  's/(private void scheduleColdCoverRetire\(\) \{.*?)\n[ ]*if \(SwitchCoverHold\.revealStandsAside\(signingOut, resumeBusy, loginInProgress, switchingIn\)\) return;/$1/s' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
