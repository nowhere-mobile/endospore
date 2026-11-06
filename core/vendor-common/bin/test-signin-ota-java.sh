#!/usr/bin/env bash
# test-signin-ota-java.sh [--mutate] -- NWP-20261101-12 (Q062): the gate says why when an OS update holds a sign-in.
# Runs core/chooser/tests/signin-ota: the pure decisions (which OTA-STATUS line holds a sign-in, which reply is the
# daemon's ERR-OTA), the text byte for byte, and the order of roamLogin's checks (the update check before
# GET-PARKED-CREDIT and the network wait; an ERR-OTA after ROAM-IN stops the created user before any verdict).
# The daemon half is core/agent/test-ota-signin-refusal.sh.
# NWP-20261117-12 (#30): the same for ERR-NOTMPFS (the state dir is not a tmpfs): the predicate, "This phone can't sign
# in safely. Restart it." byte for byte, and its three branches (the create chain, the ROAM-IN reply, which stops the
# created user first, and resume()'s NOTMPFS arm). The daemon half is core/agent/test-state-tmpfs.sh.
#
# It needs a JDK and FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs against broken copies of ChooserActivity.java; each must FAIL the case it names. A mutant that does
# not apply (INERT), or fails some other way (BROKEN), counts as a failure.
#
#   bash test-signin-ota-java.sh            # the cases
#   bash test-signin-ota-java.sh --mutate   # ... plus the mutants
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
  echo "test-signin-ota-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"
"$JAVAC" -version 2>&1 | sed 's/^/using /'
SRC="$ROOT/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
run() { JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/signin-ota/run.sh" "$1"; }
run "$SRC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by the case it names)"
mut() { # mut <label> <perl-expr> <case the mutant must fail>
  local d f out rc
  d=$(mktemp -d -p "$W"); f="$d/ChooserActivity.java"
  cp "$SRC" "$f"
  if ! perl -0pi -e "$2" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$SRC" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  out=$(run "$f" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -ne 1 ]; then echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1; fi
  if ! grep -qF -- "FAIL $3" <<<"$out"; then echo "  BROKEN    $1 -- it failed, but not the case '$3'"; return 1; fi
  echo "  convicted $1 (fails '$3')"
}
fails=0
mut "T1 APPLYING does not hold" 's/ \|\| otaStatusLine\.startsWith\("APPLYING"\)//' \
  "held: 'APPLYING 0.6.0' holds a sign-in" || fails=$((fails+1))
mut "T2 the update check removed" 's/            if \(signInHeldForUpdate\(otaStatusAndProg\(\)\[0\]\)\) \{\n.*?\n            \}\n//s' \
  "wiring: the update check comes after the create refusal and before GET-PARKED-CREDIT" || fails=$((fails+1))
mut "T3 the ROAM-IN arm keeps the user" 's/(if \(replyIsOtaRefusal\(reply\)\) \{\n)\s*if \(uid >= 0\) stopRoamUser\(uid\);\n/$1/' \
  "wiring: a ROAM-IN answered ERR-OTA stops the user, says why and returns before the verdict" || fails=$((fails+1))
mut "T4 the update check after GET-PARKED-CREDIT" 's/(            \/\/ NWP-20261101-12 \(Q062\): an update that is staging.*?\n            if \(signInHeldForUpdate.*?\n            \}\n)(.*?            if \(parkedCreditProbeDue\(.*?\n            \}\n)/$2$1/s' \
  "wiring: the update check comes after the create refusal and before GET-PARKED-CREDIT" || fails=$((fails+1))
mut "T5 the text drifts" 's/Sign in after that\."/Try again later."/' "text: byte for byte" || fails=$((fails+1))
# NWP-20261117-12 (#30): the ERR-NOTMPFS branches and their text.
mut "T6 the create NOTMPFS branch removed" 's/                if \(replyIsNoTmpfs\(cr\)\) \{.*?\n.*?\n.*?\n.*?\n                \}\n//' \
  "wiring: a create answered ERR-NOTMPFS says the restart text and returns (no user exists yet)" || fails=$((fails+1))
mut "T7 the ROAM-IN NOTMPFS branch removed" 's/            if \(replyIsNoTmpfs\(reply\)\) \{\n.*?\n.*?\n.*?\n.*?\n            \}\n//' \
  "wiring: a ROAM-IN answered ERR-NOTMPFS stops the user, says the restart text and returns before the verdict" || fails=$((fails+1))
mut "T8 the ROAM-IN NOTMPFS branch keeps the user" 's/(if \(replyIsNoTmpfs\(reply\)\) \{\n)\s*if \(uid >= 0\) stopRoamUser\(uid\);\n/$1/' \
  "wiring: a ROAM-IN answered ERR-NOTMPFS stops the user, says the restart text and returns before the verdict" || fails=$((fails+1))
mut "T9 the resume NOTMPFS arm removed" 's/                    else if \(v\.kind == ResumeReply\.NOTMPFS\) \{.*?\n                    \}\n//s' \
  "wiring: resume()'s NOTMPFS arm shows the restart text" || fails=$((fails+1))
mut "T10 the NOTMPFS text drifts" 's/sign in safely\. Restart it\."/sign in safely. Try again."/' \
  "notmpfs text: byte for byte" || fails=$((fails+1))
mut "T11 replyIsNoTmpfs matches a prefix" 's/return t\.substring\(0, e\)\.equals\("ERR-NOTMPFS"\);/return t.startsWith("ERR-NOTMPFS");/' \
  "notmpfs: 'ERR-NOTMPFSX' is not the refusal" || fails=$((fails+1))
mut "T12 the create NOTMPFS branch shows the update text" 's/(if \(replyIsNoTmpfs\(cr\)\) \{.*?\n\s*hideRestore\(\);\n\s*showMsg\()NO_TMPFS_TEXT/${1}UPDATE_INSTALLING_TEXT/' \
  "wiring: a create answered ERR-NOTMPFS says the restart text and returns (no user exists yet)" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
