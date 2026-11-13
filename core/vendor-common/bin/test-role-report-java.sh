#!/usr/bin/env bash
# test-role-report-java.sh [--mutate] -- NWP-20261202-29: every issue report (the in-session one and DiagReportJob's
# scheduled one, both through ProfileActivity.reportStatus) carries default_roles, the class of each default-app role's
# holder in the calling user, never a package name. Runs core/chooser/tests/role-report: the chooser's pure RoleReport,
# compiled against its cases ALONE and EXECUTED, plus source checks (pins.py) that reportStatus puts the key exactly
# once and readDefaultRoles reads every role.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21. The pins need python3.
#
# --mutate re-runs the cases and the pins against broken copies of RoleReport.java and ProfileActivity.java, each of
# which must FAIL a named case or pin. A mutant that does not apply (INERT) or does not compile (BROKEN) counts as a
# failure, never a pass.
#
#   bash test-role-report-java.sh            # the cases and the pins
#   bash test-role-report-java.sh --mutate   # ... plus the mutants
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
  echo "test-role-report-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
# ONE temp root: every class dir and mutant tree lives under it, and the EXIT trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
T=$ROOT/core/chooser/tests/role-report
command -v python3 >/dev/null 2>&1 || { echo "test-role-report-java: FAIL -- no python3 for the pins" >&2; exit 2; }
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
SRCS="RoleReport.java ProfileActivity.java"
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
mut "B1 an updated system app reported as user" RoleReport.java 's/FLAG_SYSTEM \| FLAG_UPDATED_SYSTEM_APP/FLAG_SYSTEM/' \
  "an updated system app is bundled" || fails=$((fails+1))
mut "B2 unavailable reported as none" RoleReport.java 's/return "unavailable";/return "none";/' \
  "unavailable role is unavailable" || fails=$((fails+1))
mut "B3 null holders reported as none" RoleReport.java 's/if \(holders == null\) return "unreadable";/if (holders == null) return "none";/' \
  "null holders are unreadable" || fails=$((fails+1))
mut "B4 the holder's package name emitted instead of its class" RoleReport.java 's/return "user";/return holder;/' \
  "a user app is user" || fails=$((fails+1))
mut "B5 a role dropped from ROLES" RoleReport.java 's/\n[ \t]*\{"android\.app\.role\.NOTES", "notes"\},//' \
  "ten roles in order" || fails=$((fails+1))
mut "B6 the reportStatus put removed" ProfileActivity.java 's/\n[ \t]*st\.put\("default_roles", readDefaultRoles\(ctx\)\);//' \
  "p1 reportStatus puts default_roles exactly once" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
