#!/usr/bin/env bash
# test-owner-inbox-reply-java.sh [--mutate] -- NWP-20261128-12: the owner inbox tells a failed read from an empty one.
# Runs core/chooser/tests/owner-inbox-reply: OwnerInboxReply compiled and EXECUTED, the wiring in
# ChooserActivity.buildOwnerInboxScreen read from the source, and the daemon's reply read from
# core/agent/telephony_owner.go (tests/owner-inbox-reply/run.sh says how).
#
# WHY THIS IS COMMITTED. The daemon answers an empty inbox NONE. It never sends OK with no row. The screen cleared the
# unassigned-line notice only on OK with no row, so the NWP-20261017-32 clear never ran. The same screen showed every
# failed read (no answer, a cut-short read, ERR request, DENIED) as an empty inbox. Each part of the fix is one line a
# later edit can change without breaking a build.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against broken copies. Each copy must fail a CASE. A copy that does not apply, does not change
# the file or does not compile is a failure, never a pass.
#
#   bash test-owner-inbox-reply-java.sh            # the cases
#   bash test-owner-inbox-reply-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
AG="$ROOT/core/agent"
RUN="$CH/tests/owner-inbox-reply/run.sh"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-owner-inbox-reply-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
export JAVAC JAVA

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "== the cases =="
TMPDIR="$W" bash "$RUN" "$CH" "$AG"; rc=$?
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the suite did not pass (run.sh exit $rc: 1 a case, 2 cannot run, 3 no compile)"; fi

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ]; then
  echo
  echo "== mutations (each MUST be convicted by a case) =="
  mutate(){ # mutate <label> <file under $W> <sed script>
    local label="$1" rel="$2" script="$3" f orig r
    rm -rf "$W/c" "$W/agent"; mkdir -p "$W/c/src/com/nowhere/chooser" "$W/agent"
    cp "$CH"/src/com/nowhere/chooser/*.java "$W/c/src/com/nowhere/chooser/"
    cp "$AG/telephony_owner.go" "$W/agent/"
    f="$W/$rel"
    case "$rel" in c/*) orig="$CH/${rel#c/}" ;; agent/*) orig="$AG/${rel#agent/}" ;; *) no "MUTATION BROKEN (path): $label"; return ;; esac
    if ! sed -i "$script" "$f" 2>"$W/err"; then no "MUTATION BROKEN (sed): $label"; return; fi
    if cmp -s "$f" "$orig"; then no "MUTATION INERT: $label"; return; fi
    TMPDIR="$W" bash "$RUN" "$W/c" "$W/agent" >/dev/null 2>&1; r=$?
    case "$r" in
      1) ok "convicted: $label" ;;
      0) no "NOT CONVICTED: $label -- suite passes on broken code" ;;
      *) no "MUTATION BROKEN (run.sh exit $r, not a case): $label" ;;
    esac
  }
  C=c/src/com/nowhere/chooser/ChooserActivity.java
  R=c/src/com/nowhere/chooser/OwnerInboxReply.java
  G=agent/telephony_owner.go
  mutate "M1 of() maps NONE to FAILED"                 $R 's/if ("NONE".equals(head)) return EMPTY;/if ("NONE".equals(head)) return FAILED;/'
  mutate "M2 the EMPTY arm loses its cancel"           $C '/case OwnerInboxReply.EMPTY:/,/default:/{/cancelTelNotices/d}'
  mutate "M3 the FAILED arm shows the empty line"      $C '/case OwnerInboxReply.FAILED:/,/case OwnerInboxReply.EMPTY:/s/StatusLine.error(status, OwnerInboxReply.FAILED_LINE);/status.setText(OwnerInboxReply.EMPTY_LINE);/'
  mutate "M4 the list read back to roundTripLines"     $C '/private View buildOwnerInboxScreen()/,/^    }$/s/DaemonSocket.roundTripLinesOrNull(req, 30000)/DaemonSocket.roundTripLines(req, 30000)/'
  mutate "M5 shown == 0 shows the empty line"          $C 's/if (shown == 0) { StatusLine.error(status, OwnerInboxReply.FAILED_LINE);/if (shown == 0) { status.setText(OwnerInboxReply.EMPTY_LINE);/'
  mutate "M6 the daemon answers an empty inbox OK"     $G '/if len(lines) == 0 {/,/}/s/"NONE\\n"/"OK\\n"/'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
