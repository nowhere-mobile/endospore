#!/usr/bin/env bash
# test-gate-rollback-req.sh [--mutate] -- the gate's ROLLBACK-GATE request (NWP-20261016-20). The fenced
# `BEGIN/END gate-rollback-req` builder in ChooserActivity.java is lifted verbatim into a harness and run under
# javac/java: the request is exactly four lines, name, pass, then the secure-element secret (empty for a pass-only
# identity). A source pin asserts doGateRollback sends through the builder with seSecretHex(name).
#   bash test-gate-rollback-req.sh            # the invariants
#   bash test-gate-rollback-req.sh --mutate   # ... plus mutants that must each CONVICT
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/src/com/nowhere/chooser/ChooserActivity.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
# FAILS without a JDK, never skips (same rule as the other javac suites; the CI runner is the build VM).
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
    JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
    JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
    echo "FAIL: no javac on PATH or at $HOST_JDK; this suite does not skip" >&2; exit 2
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

suite() { # suite <ChooserActivity.java copy>
  local f="$1" d; d=$(mktemp -d -p "$W")
  {
    echo 'public class T {'
    sed -n '/BEGIN gate-rollback-req/,/END gate-rollback-req/p' "$f"
    cat <<'JAVA'
  static int fails = 0;
  static void eq(String what, String got, String want) {
    if (!got.equals(want)) { fails++; System.out.println("  FAIL  " + what + ": got [" + got.replace("\n", "|") + "]"); }
    else System.out.println("  ok    " + what);
  }
  public static void main(String[] a) {
    eq("hardened", gateRollbackRequest("n", "p", "abcd01"), "ROLLBACK-GATE\nn\np\nabcd01\n");
    eq("pass-only", gateRollbackRequest("n", "p", ""), "ROLLBACK-GATE\nn\np\n\n");
    System.exit(fails == 0 ? 0 : 1);
  }
}
JAVA
  } > "$d/T.java"
  "$JAVAC" -d "$d" "$d/T.java" 2>&1 || return 1
  "$JAVA" -cp "$d" T || return 1
  # doGateRollback sends through the builder, with the secret read on its worker thread
  local body; body=$(sed -n '/private void doGateRollback(/,/^    }$/p' "$f")
  case "$body" in *'sendDaemon(gateRollbackRequest(name, pw, seSecretHex(name)))'*) echo "  ok    doGateRollback sends the builder's request" ;;
    *) echo "  FAIL  doGateRollback does not send gateRollbackRequest(name, pw, seSecretHex(name))"; return 1 ;; esac
  case "$body" in *'new Thread(() -> {'*'seSecretHex'*) echo "  ok    seSecretHex runs inside the worker thread" ;;
    *) echo "  FAIL  seSecretHex is not inside the worker thread"; return 1 ;; esac
}

suite "$SUT" || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || { echo PASS; exit 0; }

bad=0
mut() { # mut <label> <sed-expr>
  local m="$W/m.java"
  sed -E "$2" "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation did not apply"; bad=$((bad+1)); return; fi
  if suite "$m" >/dev/null 2>&1; then echo "  SURVIVED  $1"; bad=$((bad+1)); else echo "  convicted $1"; fi
}
mut "M1 the builder drops the 3rd line" 's/ \+ pw \+ "\\n" \+ se \+ "\\n";/ + pw + "\\n";/'
mut "M2 doGateRollback reverted to the two-line literal" 's/sendDaemon\(gateRollbackRequest\(name, pw, seSecretHex\(name\)\)\)/sendDaemon("ROLLBACK-GATE\\n" + name + "\\n" + pw + "\\n")/'
[ "$bad" -eq 0 ] || { echo "MUTATION FAILED ($bad)"; exit 1; }
echo "PASS (mutants convicted)"
