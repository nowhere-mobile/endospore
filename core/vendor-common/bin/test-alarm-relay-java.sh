#!/usr/bin/env bash
# test-alarm-relay-java.sh [--mutate] -- NWP-20261011-04: the logoff's alarm relay names the alarm's owner. Runs
# core/chooser/tests/alarm-relay under javac: the shared SET-GATE-ALARM line, and that ProfileActivity's logoff relay and
# CredentialService's periodic relay both send it with the owner.
#
# WHY. The logoff's cutoff force-stops every package of the session, and a force-stop cancels the stopped app's alarms.
# The daemon keeps the package that owns the next alarm clock (docs/product-decisions.md, 2026-10-11: "Never stop the
# alarm app") -- and it learns that package only from this relay. The logoff's relay used to send the time alone, which
# also removed the owner the periodic relay had recorded. Silent when it regresses: the alarm simply never rings.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips would read green on a runner that never ran it.
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
  echo "test-alarm-relay-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 1
fi
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export JAVAC JAVA TMPDIR="$W"
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CS="$ROOT/core/chooser/src/com/nowhere/chooser/CredentialService.java"
PA="$ROOT/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
RUN="$ROOT/core/chooser/tests/alarm-relay/run.sh"

echo "== $CS + $PA"
bash "$RUN" "$CS" "$PA" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- by behaviour: a mutant that does not extract or compile proves nothing)"
mut() { # mut <label> <cs|pa> <perl-expr>
  local d rc; d=$(mktemp -d -p "$W")
  cp "$CS" "$d/CredentialService.java"; cp "$PA" "$d/ProfileActivity.java"
  local f="$d/CredentialService.java"; [ "$2" = pa ] && f="$d/ProfileActivity.java"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$f" "$( [ "$2" = pa ] && echo "$PA" || echo "$CS")"; then echo "  INERT     $1"; rm -rf "$d"; return 1; fi
  bash "$RUN" "$d/CredentialService.java" "$d/ProfileActivity.java" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "A1 the logoff relay sends the time alone again"  pa 's/sendDaemon\("SET-GATE-ALARM\\n" \+ line \+ "\\n"\)/sendDaemon("SET-GATE-ALARM\\n" + when + "\\n")/' || fails=$((fails+1))
mut "A2 the logoff relay never reads the owner"       pa 's/if \(ac != null && ac\.getShowIntent\(\) != null\) pkg = ac\.getShowIntent\(\)\.getCreatorPackage\(\);//' || fails=$((fails+1))
mut "A3 the owner sent for no alarm"                  cs 's/if \(when != 0L && pkg != null/if (pkg != null/' || fails=$((fails+1))
mut "A4 the user dropped from the pair"               cs 's/line = line \+ "\\t" \+ userId \+ "\\t" \+ pkg;/line = line + "\\t" + pkg;/' || fails=$((fails+1))
mut "A5 an unknown user still pairs"                  cs 's/ && userId >= 0\) \{/) {/' || fails=$((fails+1))
mut "A6 the logoff relay passes no owner"             pa 's/myUserId\(\), pkg\);/myUserId(), null);/' || fails=$((fails+1))
mut "A7 relayLanded returns true unconditionally"     cs 's/(static boolean relayLanded\(.*?)return false;/$1return true;/s' || fails=$((fails+1))
mut "A8 relayLanded loop makes one call"              cs 's/for \(int i = 0; i < tries; i\+\+\)/for (int i = 0; i < 1; i++)/' || fails=$((fails+1))
mut "A9 any non-empty reply counts as landed"         cs 's/r != null && r\.startsWith\("OK"\)/r != null \&\& !r.isEmpty()/' || fails=$((fails+1))
mut "A10 the relayed log moved out of if (landed)"    cs 's/if \(landed\) \{\n(\s*android\.util\.Log\.i\([^\n]*\n)\s*\} else \{/$1if (landed) {\n        } else {/' || fails=$((fails+1))
mut "A11 relayNextAlarm passes one try"               cs 's/(8000\), )2\)/${1}1)/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
