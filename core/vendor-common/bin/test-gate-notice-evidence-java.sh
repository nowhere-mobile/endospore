#!/usr/bin/env bash
# test-gate-notice-evidence-java.sh [--mutate] -- NWP-20261204-12, backlog row "After a sign-out the gate can show a
# missed call from inside the session, and a location icon". Runs core/chooser/tests/gate-notice-evidence:
# GateNoticeEvidence's classifiers, compiled and EXECUTED, and source pins on the reads a gate issue report makes
# (tests/gate-notice-evidence/run.sh says how).
#
# WHY THIS IS COMMITTED. The row names three causes for what the gate shows after a sign-out: (A) the gate's own
# telephony and loss notices, (B) Telecom's own missed-call notice in user 0, and (C) the location icon from the
# chooser's fine-location grant. One gate report now tells them apart, with counts and fixed classes only, because the
# gate preview shows the report to whoever holds the phone. The pins hold that line: put() changes nothing, reads a
# notice by its tag only, and writes every key, "unreadable" when its read fails.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against broken copies, each of which must FAIL with its named case or pin: a mutant that does not
# apply (INERT) or fails some other way (BROKEN) counts as a failure, never a pass.
#
#   bash test-gate-notice-evidence-java.sh            # the cases
#   bash test-gate-notice-evidence-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W TMPDIR="$W"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
RUN="$CH/tests/gate-notice-evidence/run.sh"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-gate-notice-evidence-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 1
fi
export JAVAC JAVA
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran

echo "== $CH"
bash "$RUN" "$CH" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its named case or pin)"
mut() { # mut <label> <file under the chooser dir> <perl-expr> <text the failure must contain>
  local d f out rc
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$CH"/src/com/nowhere/chooser/*.java "$d/src/com/nowhere/chooser/"
  f="$d/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$f" "$CH/$2"; then echo "  INERT     $1"; rm -rf "$d"; return 1; fi
  out=$(bash "$RUN" "$d" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; printf '%s\n' "$out" | tail -n 5; return 1 ;;
  esac
  case "$out" in *"FAIL  $4"*) ;; *) echo "  BROKEN    $1 -- it failed, but not with '$4'"; printf '%s\n' "$out" | grep FAIL; return 1 ;; esac
  echo "  convicted $1 (by $4)"
}
G=src/com/nowhere/chooser/GateNoticeEvidence.java
C=src/com/nowhere/chooser/ChooserActivity.java
R=src/com/nowhere/chooser/MissedCallReceiver.java
fails=0
mut "E1 grantName swaps 1 and 2"                   $G 's/case 1: return "policy_granted";/case 1: return "policy_denied";/; s/case 2: return "policy_denied";/case 2: return "policy_granted";/' "C2" || fails=$((fails+1))
mut "E2 the loss tag counted as tel"               $G 's/else if \(lossTag\.equals\(t\)\) c\[1\]\+\+;/else if (lossTag.equals(t)) c[0]++;/' "C1" || fails=$((fails+1))
mut "E3 receiverState answers resolves for 0"      $G 's/if \(n == 0\) return "absent";/if (n == 0) return "resolves";/' "C3" || fails=$((fails+1))
mut "E4 the gateReportJson call removed"           $C 's/\n[ \t]*GateNoticeEvidence\.put\(this, st\);[^\n]*//' "P1" || fails=$((fails+1))
mut "E5 the increment removed"                     $R 's/\n[ \t]*RECEIVED\.incrementAndGet\(\);//' "P7" || fails=$((fails+1))
mut "E6 two keys share one try"                    $G 's/\n[ \t]*\} catch \(Throwable t\) \{ putQuiet\(st, "location_grant", "unreadable"\); \}\n[ \t]*try \{//' "P3" || fails=$((fails+1))
mut "E7 a key renamed"                             $G 's/"location_on"/"location_enabled"/g' "P2" || fails=$((fails+1))
mut "E8 roleName swaps held and not_held"          $G 's/return held \? "held" : "not_held";/return held ? "not_held" : "held";/' "C4" || fails=$((fails+1))
mut "E9 bucket returns the raw count"              $G 's/(static String bucket\(int n\) \{\n)/$1        if (n > 0) return String.valueOf(n);\n/' "C5" || fails=$((fails+1))
mut "E10 put() reads a notice's extras"            $G 's/(tags\[i\] = act\[i\]\.getTag\(\);)/$1 String x = String.valueOf(act[i].getNotification().extras);/' "P6" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
