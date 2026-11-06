#!/usr/bin/env bash
# test-tel-wire-java.sh [--mutate] -- NWP-20261022-11: the chooser half of the v2 SEAL-TEL wire, EXECUTED. Runs
# core/chooser/tests/tel-wire: TelArrival's telRequest, arrival ids, parse and untilAnswered, lifted by name from the
# real source and compiled under plain javac, against core/agent/testdata/tel-wire-v2.txt -- the fixture the daemon's
# Go test (core/agent/tel_wire_contract_test.go) reads too, so the two sides are checked against each other and not
# only against pins of their own text (core/chooser/test-tel-seal.sh pins TelArrival byte for byte and executes nothing).
# A retry is shown to resend the identical request, which is what lets the daemon seal a repeated arrival once.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner that
# never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21. --mutate re-runs it against deliberately
# broken copies of the LIFTED class (never the source), each of which must fail a case.
#
#   bash test-tel-wire-java.sh            # the cases
#   bash test-tel-wire-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
FIX="$ROOT/core/agent/testdata/tel-wire-v2.txt"
RUN="$CH/tests/tel-wire/run.sh"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-tel-wire-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
export JAVAC JAVA

# the one root every run's sources and classes live under (run.sh gets a subdirectory of it per baseline and per mutant)
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
RUNN=0
runit(){ # runit [<sed script>] -- one run.sh in its own fresh directory under $W
  RUNN=$((RUNN+1))
  bash "$RUN" "$CH" "$FIX" "${1:-}" "$W/run$RUNN"
}

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "== the cases =="
runit; rc=$?
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the suite did not pass (run.sh exit $rc: 1 a case, 2 cannot run, 3 no compile)"; fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ] && [ "$rc" = 0 ]; then
  echo
  echo "== mutations (each MUST be convicted by a case) =="
  mutate(){ # mutate <label> <sed script applied to the lifted TelArrival>
    runit "$2" >/dev/null 2>&1; local r=$?
    case "$r" in
      1) ok "convicted: $1" ;;
      0) no "NOT CONVICTED: $1 -- suite passes on broken code" ;;
      4) no "MUTATION INERT: $1" ;;
      *) no "MUTATION BROKEN (run.sh exit $r, not a case): $1" ;;
    esac
  }
  mutate "telRequest swaps when and mono" \
    's/b64(from) + "\\n" + when + "\\n"/b64(from) + "\\n" + mono + "\\n"/; s/^\( *\)+ mono + "\\n" + b64(body)/\1+ when + "\\n" + b64(body)/'
  mutate "telRequest sends <from> without base64" 's/+ b64(from) +/+ from +/'
  mutate "parse keeps the label base64-encoded" \
    's/r.label = new String(Base64.decode(f\[2\], Base64.NO_WRAP), StandardCharsets.UTF_8);/r.label = f[2];/'
  mutate "parse reads the live uid from f[i]" 's/Integer.parseInt(f\[i + 1\].trim())/Integer.parseInt(f[i].trim())/'
  mutate "mmsId ignores the transaction id" 's/txn != null \&\& !txn.isEmpty() ? "t" + txn : //'
  mutate "untilAnswered returns on ERR" 's/if (!"ERR".equals(last.kind)) return last;/return last;/'
  mutate "J1 parse never sets partial" 's/if ("PARTIAL".equals(f\[i\])) r.partial = true;//'
  mutate "J2 parse sets partial from STRIPPED" 's/"PARTIAL".equals(f\[i\])/"STRIPPED".equals(f[i])/'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
