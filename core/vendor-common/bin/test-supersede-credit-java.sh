#!/usr/bin/env bash
# test-supersede-credit-java.sh [--mutate] -- NWP-20261016-47: a sign-in at the gate over a parked cold-locked session
# warns before it ends that session's unsaved storage credit (docs/product-decisions.md, 2026-10-16, "warn and tell").
# NWP-20261124-08 (2026-11-02, "twenty-four answers to the open-decisions list", #3): it asks over EVERY parked session,
# because the gate cannot learn whether that session has unsaved changes; GET-PARKED-CREDIT's LOST adds only the credit
# sentence.
# Runs core/chooser/tests/supersede-credit: the chooser's pure decision (when to ask, which reply warns), its copy, the
# wait's limit, Cancel's way back (only to a parked session a fresh GET-COLDLOCK still names), and the wiring in
# roamLogin and hideRestore, compiled and EXECUTED; the dialog's wait and the Cancel path are pinned byte for byte. The
# daemon half (GET-PARKED-CREDIT) is the Go suite core/agent/test-warn-and-tell.sh.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21; the version is printed first.
#
# --mutate re-runs the suite against broken copies of ChooserActivity.java, each of which must FAIL the case it names.
# A mutant that does not apply (INERT), fails some other way, or does not compile/extract (BROKEN) counts as a failure,
# never a pass.
#
#   bash test-supersede-credit-java.sh            # the cases
#   bash test-supersede-credit-java.sh --mutate   # ... plus the mutants
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
  echo "test-supersede-credit-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
SRC="$ROOT/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
run() { SC_TMP=$W JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/supersede-credit/run.sh" "$1"; }
run "$SRC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by the case it names; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <perl-expr> <case the mutant must fail>
  local d f out rc
  d=$(mktemp -d -p "$W"); f="$d/ChooserActivity.java"
  cp "$SRC" "$f"
  if ! perl -0pi -e "$2" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(run "$f" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -ne 1 ]; then echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1; fi
  if ! grep -qF -- "FAIL $3" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the case '$3'"; return 1
  fi
  echo "  convicted $1 (fails '$3')"
}
fails=0
# \x5c is a backslash and \x22 a double quote: a doubled backslash in a mutation is mangled by Git Bash's argument
# conversion, so none is used.
mut "J1 a create asks too" 's/return !isCreate && parkedUid > 0 && parkedUid != acceptedUid;/return parkedUid > 0 \&\& parkedUid != acceptedUid;/' \
  "probe: a create never asks (it is refused while a session is parked)" || fails=$((fails+1))
mut "J2 the accepted session is asked again" 's/return !isCreate && parkedUid > 0 && parkedUid != acceptedUid;/return !isCreate \&\& parkedUid > 0;/' \
  "probe: the sign-in that accepted this session's loss does not ask again" || fails=$((fails+1))
mut "J3 asked with no parked session" 's/return !isCreate && parkedUid > 0 && parkedUid != acceptedUid;/return !isCreate \&\& parkedUid != acceptedUid;/' \
  "probe: no parked session, no question" || fails=$((fails+1))
mut "J4 any answer adds the credit sentence" 's/return reply != null && "LOST"\.equals\(reply\.trim\(\)\);/return reply != null \&\& !reply.trim().isEmpty();/' \
  "reply: 'NONE' adds no credit sentence" || fails=$((fails+1))
mut "J5 a prefix of LOST adds the credit sentence" 's/return reply != null && "LOST"\.equals\(reply\.trim\(\)\);/return reply != null \&\& reply.trim().startsWith("LOST");/' \
  "reply: 'LOST 2' adds no credit sentence" || fails=$((fails+1))
mut "J6 the copy drops what is safe" 's/ Credit saved before that session is safe\."/"/' \
  "copy: with LOST it carries the credit sentence" || fails=$((fails+1))
mut "J7 the copy names an amount" 's/Signing in now ends a locked session/Signing in now ends 1 locked session/' \
  "copy: names no amount (no digit anywhere)" || fails=$((fails+1))
mut "J8 the question moved after the network wait" 's/(            \/\/ NWP-20261016-47 \(decided 2026-10-16, "warn and tell"\): this sign-in ends[^\n]*\n(?:            \/\/[^\n]*\n)*            if \(parkedCreditProbeDue\(isCreate, supersedeColdUid, supersedeLossAcceptedUid\)\) \{\n.*?\n            \}\n)(.*?            final boolean offline = !hasInternetWithGrace\(8000\);\n)/$2$1/s' \
  "wiring: the question comes before the network wait and before any user is created" || fails=$((fails+1))
mut "J9 Cancel goes ahead with the sign-in" 's/(                    backToParkedSession\(clNow, supersedeColdUid\);\n)                    return;\n/$1/' \
  "wiring: Cancel hands the form back, asks GET-COLDLOCK again, goes back only to that reply and ends the sign-in" || fails=$((fails+1))
# J10 is anchored on roamLogin's lead-in: Install at the gate (NWP-20261101-15) sends the same line, earlier in the file.
mut "J10 the probe asks another verb" 's/(if \(parkedCreditProbeDue\(isCreate, supersedeColdUid, supersedeLossAcceptedUid\)\) \{\n\s*String pc = "";\n\s*)try \{ pc = sendDaemon\("GET-PARKED-CREDIT\x5cn"\); \}/${1}try { pc = sendDaemon("GET-COLDLOCK\x5cn"); }/' \
  "anchor occurs exactly once: try { pc = sendDaemon(\"GET-PARKED-CREDIT\\n\"); } catch (Throwable ignore) {}" || fails=$((fails+1))
mut "J11 hideRestore keeps the accepted session" 's/(    private void hideRestore\(\) \{\n)        supersedeLossAcceptedUid = -1;[^\n]*\n/$1/' \
  "wiring: hideRestore forgets the accepted session before anything else" || fails=$((fails+1))
mut "J12 a NEEDKEY key-wait forgets the accepted session" 's/(                restoreSrcUnit = srcAtStart;\n)/$1                supersedeLossAcceptedUid = -1;\n/' \
  "wiring: a NEEDKEY key-wait keeps the accepted session (it is the same sign-in)" || fails=$((fails+1))
mut "J13 the warning can be dismissed with no answer" 's/(\.setMessage\(supersedeLossText\(creditLost\)\)\n\s*)\.setCancelable\(false\)/$1.setCancelable(true)/' \
  "pinned: confirmSupersedeLoss" || fails=$((fails+1))
mut "J14 a gate that goes away reads as Continue" 's/(shown\[0\]\.dismiss\(\); \}\);\n\s*)return false;/$1return true;/' \
  "pinned: confirmSupersedeLoss" || fails=$((fails+1))
mut "J15 Cancel lands on the fresh-login form" 's/(        runOnUiThread\(\(\) -> \{\n            if \(isFinishing\(\) \|\| resumeMode\) return;\n)            enterResumeMode\(p\[3\], p\[0\], "fido2"\.equals\(p\[1\]\), "pin"\.equals\(p\[2\]\)\);\n(        \}\);\n    \}\n\n    \/\*\* P4: switch the gate)/$1$2/' \
  "pinned: backToParkedSession" || fails=$((fails+1))
mut "J16 a committed sign-in keeps the accepted session" 's/(            if \(ok\) \{\n)                supersedeLossAcceptedUid = -1;[^\n]*\n/$1/' \
  "anchor occurs exactly once:             if (ok) {\\n                supersedeLossAcceptedUid = -1;" || fails=$((fails+1))
mut "J17 the warning waits with no limit" 's/return waitedMs >= 120_000L;/return false;/' \
  "limit: two minutes unanswered counts as Cancel" || fails=$((fails+1))
mut "J18 the wait never asks the limit" 's/if \(isFinishing\(\) \|\| isDestroyed\(\)\n\s*\|\| supersedeWarnExpired\(android\.os\.SystemClock\.elapsedRealtime\(\) - since\)\) \{/if (isFinishing() || isDestroyed()) {/' \
  "pinned: confirmSupersedeLoss" || fails=$((fails+1))
mut "J19 the limit stops while the phone sleeps" 's/supersedeWarnExpired\(android\.os\.SystemClock\.elapsedRealtime\(\) - since\)/supersedeWarnExpired(android.os.SystemClock.uptimeMillis() - since)/' \
  "pinned: confirmSupersedeLoss" || fails=$((fails+1))
mut "J20 Cancel goes back to the tap's snapshot" 's/backToParkedSession\(clNow, supersedeColdUid\);/backToParkedSession(coldLock0, supersedeColdUid);/' \
  "wiring: Cancel hands the form back, asks GET-COLDLOCK again, goes back only to that reply and ends the sign-in" || fails=$((fails+1))
mut "J21 the way back ignores which session is parked" 's/return p != null && Integer\.parseInt\(p\[0\]\) == parkedUid \? p : null;/return p;/' \
  "way back: a reply naming another uid is not gone back to" || fails=$((fails+1))
mut "J22 the copy promises a stored session's way out" 's/Cancel keeps that session\./Cancel to go back to that session: signing out of it tries to save again./' \
  "copy: makes no promise that holds for one kind of session only" || fails=$((fails+1))
# NWP-20261124-08: the question over every parked session; the reply picks only the credit sentence. K2/K4 anchor on the
# credit clause's second sentence, which installOverParkedText (earlier in the file) does not carry.
mut "K1 the dialog still gated on LOST (the code before NWP-20261124-08)" 's/if \(!confirmSupersedeLoss\(parkedCreditLost\(pc\)\)\) \{/if (parkedCreditLost(pc) \&\& !confirmSupersedeLoss(true)) {/' \
  "wiring: the dialog is reached whatever GET-PARKED-CREDIT answers" || fails=$((fails+1))
mut "K1b a gate before the question, its anchor kept" 's/(\n)(                if \(!confirmSupersedeLoss\(parkedCreditLost\(pc\)\)\) \{\n)/$1                if (parkedCreditLost(pc))$1$2/' \
  "wiring: the dialog is reached whatever GET-PARKED-CREDIT answers" || fails=$((fails+1))
mut "K2 the credit clause shown on NONE (helper)" 's/\(creditLost \? (" That includes storage credit it hasn\x27t saved\. Credit saved before)/(true ? $1/' \
  "copy: without LOST it names no credit" || fails=$((fails+1))
mut "K3 the credit clause shown on NONE (caller)" 's/confirmSupersedeLoss\(parkedCreditLost\(pc\)\)/confirmSupersedeLoss(true)/' \
  "wiring: the credit flag is parkedCreditLost(pc)" || fails=$((fails+1))
mut "K4 the clause dropped on LOST (helper)" 's/\(creditLost \? (" That includes storage credit it hasn\x27t saved\. Credit saved before)/(false ? $1/' \
  "copy: with LOST it carries the credit sentence" || fails=$((fails+1))
mut "K5 the clause dropped on LOST (dialog)" 's/\.setMessage\(supersedeLossText\(creditLost\)\)/.setMessage(supersedeLossText(false))/' \
  "pinned: confirmSupersedeLoss" || fails=$((fails+1))
mut "K6 Continue does not record the accepted session (a NEEDKEY retry asks twice)" 's/\n                supersedeLossAcceptedUid = supersedeColdUid;[^\n]*//' \
  "wiring: Continue records the accepted session, past the Cancel branch" || fails=$((fails+1))
mut "K7 a create asked" 's/if \(parkedCreditProbeDue\(isCreate, supersedeColdUid, supersedeLossAcceptedUid\)\) \{/if (parkedCreditProbeDue(false, supersedeColdUid, supersedeLossAcceptedUid)) {/' \
  "wiring: a create never reaches the question" || fails=$((fails+1))
mut "K8 the title names credit" 's/return "End the locked session\?";/return "Unsaved storage credit";/' \
  "copy: the title names no credit" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
