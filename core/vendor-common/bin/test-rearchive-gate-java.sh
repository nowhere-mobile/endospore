#!/usr/bin/env bash
# test-rearchive-gate-java.sh [--mutate] -- NWP-20261102-15: which materialised on-demand app loses its APK mid-session
# (ReArchiveReceiver's #206 idle reclaim). Runs core/chooser/tests/rearchive-gate: the chooser's pure ReArchiveGate,
# compiled against its cases ALONE and EXECUTED, plus source checks (pins.py) that the receiver calls it.
# NWP-20261120-12 adds ReArchiveGate.armAt (a re-arm never moves a pending sweep later) to the cases, and pins s3-s7:
# arm decides through armAt, onReceive clears DUE before its re-arm, keepArmed arms only for a non-empty keep-set,
# CredentialService's "claims" branch (not "claimsLogin") calls keepArmed, and UnarchiveService still calls arm.
# NWP-20261122-10 (h51 #6) adds ReArchiveGate.holdsJob (the current keyboard, the always-on VPN, an accessibility
# service, a notification listener or a role holder keeps the app; the package matches exactly) and the visible and
# foreground-service times to archive's max. Pins s8-s11: the sweep reads every job source once, archives nothing
# when one cannot be read, and passes holdsJob and the four times to archive. Mutants G6-G10, R10 and R11 are new;
# G1 and G5 are re-pointed at the four-time max.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21. The pins need python3.
#
# --mutate re-runs the cases and the pins against broken copies of ReArchiveGate.java, ReArchiveReceiver.java and
# CredentialService.java, each of which must FAIL a named case or pin. A mutant that does not apply (INERT) or does
# not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-rearchive-gate-java.sh            # the cases and the pins
#   bash test-rearchive-gate-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-rearchive-gate-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
# ONE temp root: every class dir and mutant tree lives under it, and the EXIT trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
T=$ROOT/core/chooser/tests/rearchive-gate
command -v python3 >/dev/null 2>&1 || { echo "test-rearchive-gate-java: FAIL -- no python3 for the pins" >&2; exit 2; }
run() { JAVAC=$JAVAC JAVA=$JAVA bash "$T/run.sh" "$1" "$(mktemp -d -p "$W")"; }
pins() { python3 -I -B "$T/pins.py" "$1"; }
# Both legs always run, so a red case does not hide a red pin.
rc=0
run "$ROOT" || rc=1
pins "$ROOT" || rc=1
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
SRCS="ReArchiveGate.java ReArchiveReceiver.java CredentialService.java UnarchiveService.java"
mut() { # mut <label> <file under $CH> <perl-expr over it> <case or pin the mutant must fail>
  local d f out rc s
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for s in $SRCS; do cp "$ROOT/$CH/$s" "$d/$CH/$s"; done
  f="$d/$CH/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  rc=0
  out=$(run "$d" 2>&1) || rc=1
  out+=$'\n'$(pins "$d" 2>&1) || rc=1
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if grep -qF -- "error:" <<<"$out"; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not '$4'"; return 1
  fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
mut "G1 the materialise floor removed" ReArchiveGate.java 's/Math\.max\(lastFgsMs, lastUpdateMs\)/lastFgsMs/' \
  "fresh materialise, never used, is kept" || fails=$((fails+1))
mut "G2 boundary >= becomes >" ReArchiveGate.java 's/nowMs - last >= idleMs/nowMs - last > idleMs/' \
  "exactly idle since last is archived" || fails=$((fails+1))
mut "G3 the Never check removed" ReArchiveGate.java 's/if \(idleMs <= 0\) return false;//' \
  "Never idle 0 keeps even with last 0" || fails=$((fails+1))
mut "G4 override precedence flipped" ReArchiveGate.java 's/globalOverrideMs > 0 \? globalOverrideMs : profileIdleMs/profileIdleMs > 0 ? profileIdleMs : globalOverrideMs/' \
  "override beats the profile's value" || fails=$((fails+1))
mut "G5 max becomes min" ReArchiveGate.java 's/Math\.max\(Math\.max\(/Math.min(Math.max(/' \
  "lastUpdate later than lastUsed wins" || fails=$((fails+1))
mut "R1 armAt always returns want" ReArchiveGate.java \
  's/return pendingDueMs > nowMs && pendingDueMs <= wantMs \? pendingDueMs : wantMs;/return wantMs;/' \
  "armAt pending before want is kept" || fails=$((fails+1))
mut "R2 armAt keeps a past pending" ReArchiveGate.java 's/pendingDueMs > nowMs && //' \
  "armAt pending in the past is not pending" || fails=$((fails+1))
mut "R3 armAt keeps a later pending" ReArchiveGate.java 's/ && pendingDueMs <= wantMs//' \
  "armAt pending after want gives want" || fails=$((fails+1))
mut "R4 onReceive no longer clears DUE" ReArchiveReceiver.java 's/\n[ \t]*DUE\.set\(0L\);//' \
  "s4 onReceive clears DUE before its finally re-arms" || fails=$((fails+1))
mut "R5 the claims branch no longer calls keepArmed" CredentialService.java \
  's/\n[ \t]*ReArchiveReceiver\.keepArmed\(this\);//' \
  "s6 the claims branch calls keepArmed and claimsLogin does not" || fails=$((fails+1))
mut "R6 keepArmed arms with an empty keep-set" ReArchiveReceiver.java \
  's/if \(ProfileActivity\.ondemandKeepSet\(ctx\)\.isEmpty\(\)\) return;//' \
  "s5 keepArmed arms only on a non-empty ondemandKeepSet" || fails=$((fails+1))
mut "R7 arm sets the alarm at whenMs" ReArchiveReceiver.java \
  's/setAndAllowWhileIdle\(AlarmManager\.RTC, at, pi\)/setAndAllowWhileIdle(AlarmManager.RTC, whenMs, pi)/' \
  "s3 arm keeps the pending sweep through ReArchiveGate.armAt" || fails=$((fails+1))
mut "R8 arm no longer keeps the pending sweep" ReArchiveReceiver.java \
  's/if \(at == DUE\.get\(\) && at > 0\) return;//' \
  "s3 arm keeps the pending sweep through ReArchiveGate.armAt" || fails=$((fails+1))
mut "R9 claimsLogin also calls keepArmed" CredentialService.java \
  's/("claims-login apply -> " \+ r\.state\);)/$1 ReArchiveReceiver.keepArmed(this);/' \
  "s6 the claims branch calls keepArmed and claimsLogin does not" || fails=$((fails+1))
mut "G6 holdsJob always false" ReArchiveGate.java \
  's/(static boolean holdsJob\([^)]*\) \{)/$1 if (true) return false;/' \
  "the current keyboard is kept past idle" || fails=$((fails+1))
mut "G7 the package match as startsWith" ReArchiveGate.java \
  's/slash > 0 && pkg\.equals\(flat\.substring\(0, slash\)\)/flat.startsWith(pkg)/' \
  "com.foo.bar does not hold for com.foo" || fails=$((fails+1))
mut "G8 lastVisible dropped from the max" ReArchiveGate.java 's/Math\.max\(lastUsedMs, lastVisibleMs\)/lastUsedMs/' \
  "visible inside the window is kept" || fails=$((fails+1))
mut "G9 lastFgs dropped from the max" ReArchiveGate.java 's/Math\.max\(lastFgsMs, lastUpdateMs\)/lastUpdateMs/' \
  "a foreground service inside the window is kept" || fails=$((fails+1))
mut "G10 archive ignores holdsJob" ReArchiveGate.java 's/\n[ \t]*if \(holdsJob\) return false;//' \
  "a held job keeps an app past idle" || fails=$((fails+1))
mut "R10 sweep passes false for holdsJob" ReArchiveReceiver.java \
  's/lastFgs, lastUpdate, job\)/lastFgs, lastUpdate, false)/' \
  "s8 sweep passes holdsJob for each package to ReArchiveGate.archive before archive(ctx, pkg)" || fails=$((fails+1))
mut "R11 the read-failure path removed" ReArchiveReceiver.java \
  's/\n[ \t]*if \(failed != null\) \{.*?return;\n[ \t]*\}//s' \
  "s10 a failed job read returns before the loop" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
