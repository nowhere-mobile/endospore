#!/usr/bin/env bash
# test-install-parked-java.sh [--mutate] -- NWP-20261101-15: an Install tapped at the gate while a session is parked
# asks first (Q062). Runs core/chooser/tests/install-parked: the title, the text, the ask-or-install decision and the
# listener's wiring, compiled and EXECUTED. It needs a JDK and FAILS without one.
#
# --mutate re-runs the suite against broken copies of ChooserActivity.java, each of which must FAIL a named case. A
# mutant that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-install-parked-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /'
SRC="$ROOT/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
run() { TMPDIR=$W JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/install-parked/run.sh" "$1"; }
run "$SRC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <perl-expr> <case the mutant must fail>
  local d f out rc
  d=$(mktemp -d -p "$W"); f="$d/ChooserActivity.java"
  cp "$SRC" "$f"
  if ! perl -0pi -e "$2" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$SRC" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  out=$(run "$f" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if ! grep -qF -- "FAIL $3" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the case '$3' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$3')"
}
fails=0
mut "I1 the listener sends OTA-APPLY without the GET-COLDLOCK read" 's/(install\.setOnClickListener\(v -> )new Thread\(\(\) -> \{.*?\}\)\.start\(\)\);/$1new Thread(() -> { daemonCmd("OTA-APPLY"); runOnUiThread(startInstall); }).start());/s' \
  "listener reads GET-COLDLOCK" || fails=$((fails+1))
mut "I2 the credit clause is never added" 's/\(creditLost \? " That includes storage credit it hasn.t saved\." : ""\)/""/' \
  "text: named, credit" || fails=$((fails+1))
mut "I3 an unanswered GET-COLDLOCK installs without asking" 's/ \|\| coldLockReply == null \|\| coldLockReply\.trim\(\)\.isEmpty\(\)//' \
  "ask: an empty reply warns" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
