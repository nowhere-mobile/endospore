#!/usr/bin/env bash
# test-default-roles-java.sh [--mutate] -- NWP-20261202-05: the user's default-app roles roam (the browser, phone,
# assistant, caller ID, call redirection, wallet and notes roles), by SmsRoleRoam's rules with a bundled holder
# standing in where SMS has Messaging. Runs core/chooser/tests/default-roles: the chooser's pure DefaultRoles, compiled
# against its cases ALONE and EXECUTED (capture, apply and take-back per role), plus source checks (pins.py) that
# CredentialService, MessagingSuppressor, UnarchiveService and AppInstallReceiver call DefaultRoleRoam, that roamd's
# `in` op removes nowhere-roles-applied, and that no DefaultRoleRoam log line names an app.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21. The pins need python3.
#
# --mutate re-runs the cases and the pins against broken copies of DefaultRoles.java, DefaultRoleRoam.java,
# AppInstallReceiver.java and CredentialService.java, each of which must FAIL a named case or pin. A mutant that does
# not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-default-roles-java.sh            # the cases and the pins
#   bash test-default-roles-java.sh --mutate   # ... plus the mutants
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
  echo "test-default-roles-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
# ONE temp root: every class dir and mutant tree lives under it, and the EXIT trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
RD=core/vendor-common/bin/nowhere_roamd.sh
T=$ROOT/core/chooser/tests/default-roles
command -v python3 >/dev/null 2>&1 || { echo "test-default-roles-java: FAIL -- no python3 for the pins" >&2; exit 2; }
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
# R7 is live only while captureStep's marker guard is the one marker guard on the capture path.
GUARD='if (m == null) return null;'
n=$(grep -cF -- "$GUARD" "$ROOT/$CH/DefaultRoles.java")
[ "$n" = 1 ] || { echo "FAIL: '$GUARD' occurs $n times in DefaultRoles.java, not once (captureStep's guard)"; exit 1; }
SRCS="DefaultRoles.java DefaultRoleRoam.java CredentialService.java MessagingSuppressor.java UnarchiveService.java AppInstallReceiver.java"
mut() { # mut <label> <file under $CH> <perl-expr over it> <case or pin the mutant must fail>
  local d f out rc s named
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH" "$d/$(dirname "$RD")"
  for s in $SRCS; do cp "$ROOT/$CH/$s" "$d/$CH/$s"; done
  cp "$ROOT/$RD" "$d/$RD"
  f="$d/$CH/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  rc=0
  out=$(run "$d" 2>&1) || rc=1
  out+=$'\n'$(pins "$d" 2>&1) || rc=1
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if grep -qF -- "error:" <<<"$out"; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  # the named FAIL line: `FAIL <name>`, or `FAIL <ROLE WORD> <name>` for a per-role case
  named=$( { sed -nE 's/^FAIL //p' <<<"$out"; sed -nE 's/^FAIL [A-Z_]+ //p' <<<"$out"; } | awk -v n="$4" 'index($0, n) == 1 { print "hit" }')
  if [ -z "$named" ]; then
    echo "  BROKEN    $1 -- it failed, but not '$4'"; return 1
  fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
mut "R1 captureValue records a bundled holder while deferred" DefaultRoles.java \
  's/\n[ \t]*if \(m != null && \("deferred"\.equals\(m\[0\]\) \|\| "fallback"\.equals\(m\[0\]\)\) && "bundled"\.equals\(kind\)\) return null;//' \
  "bundled holder while deferred keeps the record" || fails=$((fails+1))
mut "R2 a bundled holder recorded with no record" DefaultRoles.java \
  's/\n[ \t]*if \("bundled"\.equals\(kind\) && record == null\) return null;//' \
  "bundled default assigned after the apply with no record records nothing" || fails=$((fails+1))
mut "R3 standInState clears the record" DefaultRoles.java \
  's/return "deferred";/return null;/' \
  "uninstall or archive while recorded keeps the record, deferred" || fails=$((fails+1))
mut "R4 takeoverStep assigns over a user app" DefaultRoles.java \
  's/\|\| "bundled"\.equals\(kind\) \? "assign" : "leave";/|| "bundled".equals(kind) ? "assign" : "assign";/' \
  "take-back on land: a user app holds it: leave" || fails=$((fails+1))
mut "R5 a marker of another serial accepted" DefaultRoles.java \
  's/if \(!session\.equals\(s\)\) return null;/if (s == null) return null;/' \
  "a marker of another session is not this session's apply" || fails=$((fails+1))
mut "R6 HOME added to ROLES" DefaultRoles.java \
  's/("android\.app\.role\.NOTES",)/$1\n            "android.app.role.HOME",/' \
  "HOME is never in ROLES" || fails=$((fails+1))
mut "R7 capture ignores the marker" DefaultRoles.java \
  's/\n[ \t]*if \(m == null\) return null;//' \
  "capture before the marker records nothing" || fails=$((fails+1))
mut "R8 the AppInstallReceiver hook removed" AppInstallReceiver.java \
  's/\n[ \t]*DefaultRoleRoam\.onMaterialised\(context, pkg\);[^\n]*//' \
  "p4 an install hands a recorded role back" || fails=$((fails+1))
mut "R9 the CredentialService call removed" CredentialService.java \
  's/ DefaultRoleRoam\.applyAtSignIn\(this\);//' \
  "p1 the smsrole branch runs SmsRoleRoam then DefaultRoleRoam" || fails=$((fails+1))
mut "R10 unknown flags read as a user app" DefaultRoles.java \
  's/if \(!readable\) return "unknown";/if (!readable) return "user";/' \
  "unknown flags record nothing" || fails=$((fails+1))
mut "R11 recordForCapture reads an unreadable record as empty" DefaultRoles.java \
  's/return recordUnknown\(isFile, length, content\) \? null : parseRecord\(content\);/return parseRecord(content);/' \
  "capture with an unreadable record keeps every role's record" || fails=$((fails+1))
mut "R12 capture parses a failed read as an empty record" DefaultRoleRoam.java \
  's/DefaultRoles\.recordForCapture\(rf\.isFile\(\), rf\.length\(\),\s*(read\(ctx, DefaultRoles\.RECORD\))\);\s*if \(rec == null\) \{.*?return;\s*\}/DefaultRoles.parseRecord($1);/s' \
  "p9 capture writes nothing while the record cannot be read" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
