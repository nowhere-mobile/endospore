#!/usr/bin/env bash
# test-claim-success-copy.sh [--mutate] -- what the claim screen says after CLAIM OK (NWP-20261014-33).
#
# A claim only FUNDS the wallet; the plan starts after the activation-jitter window (billing.go ActivateAfter),
# up to two days later. The screen used to say "Your storage plan is active" at once, identically for a first
# purchase and an extension, while Storage said "Purchased -- starting shortly". ProfileActivity.claimDoneText is
# the pure member that now picks the line from the GET-BILLING reply. It is EXTRACTED verbatim (brace-matched)
# from the shipped source and RUN under a real JVM; the two retired literals are grep-asserted absent.
# Needs a JDK and FAILS (exit 2) without one: javac/java from PATH, then the build VM's prebuilt JDK 21.
#
#   bash test-claim-success-copy.sh            # the truth table, byte-pinned
#   bash test-claim-success-copy.sh --mutate   # ... plus mutants that must each be CONVICTED
set -uo pipefail

PROFILE="$(cd "$(dirname "$0")" && pwd)/src/com/nowhere/chooser/ProfileActivity.java"
MUTATE=0
for a in "$@"; do
  case "$a" in
    --mutate) MUTATE=1 ;;
    *) echo "usage: $0 [--mutate]" >&2; exit 2 ;;
  esac
done

VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-claim-success-copy: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /'

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

extract() { # extract <file> <signature-fragment> -- the member, brace-matched
  python3 - "$1" "$2" <<'PY'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
i = src.find(sys.argv[2])
if i < 0:
    sys.stderr.write('NOT FOUND: ' + sys.argv[2] + '\n'); sys.exit(1)
j = src.index('{', i); depth = 0
for k in range(j, len(src)):
    if src[k] == '{': depth += 1
    elif src[k] == '}':
        depth -= 1
        if depth == 0:
            print(src[i:k+1]); sys.exit(0)
sys.stderr.write('UNBALANCED\n'); sys.exit(1)
PY
}

suite() { # suite <ProfileActivity.java> [quiet] -> 0 pass, 1 fail, 3 extraction failed, 4 compile failed
  rm -f "$WORK/ClaimCopy.java" "$WORK"/*.class
  local body
  body=$(extract "$1" 'static String claimDoneText(String billingReply)') || { [ "${2:-}" = quiet ] || echo "EXTRACTION FAILED"; return 3; }
  {
    echo 'final class Lifted {'
    echo "$body"
    echo '}'
    cat <<'JAVA'
public class ClaimCopy {
  static int fails = 0;
  static void eq(String what, String got, String want) {
    if (want.equals(got)) System.out.println("  PASS  " + what);
    else { System.out.println("  FAIL  " + what + ": got \"" + got + "\", want \"" + want + "\""); fails++; }
  }
  public static void main(String[] a) {
    final String PENDING = "Code redeemed — your plan starts shortly. Its term is measured from when it starts.";
    final String EXTEND = "Code redeemed — your plan will be extended shortly; Storage shows the new end date once it applies.";
    final String PLAIN = "Code redeemed.";
    long far = System.currentTimeMillis() / 1000L / 604800L + 1000;
    eq("pending, never leased", Lifted.claimDoneText("OK credit=10 through=0 pending=1 plangb=10 periods=3"), PENDING);
    eq("pending, through absent", Lifted.claimDoneText("OK credit=10 pending=1"), PENDING);
    eq("pending on a live term", Lifted.claimDoneText("OK credit=10 through=" + far + " pending=1 epochsec=604800"), EXTEND);
    eq("pending on an expired term is not 'extended'", Lifted.claimDoneText("OK credit=10 through=5 pending=1"), PLAIN);
    eq("live term, nothing pending", Lifted.claimDoneText("OK credit=10 through=" + far), PLAIN);
    eq("balance below plan cost (no pending=)", Lifted.claimDoneText("OK credit=2 through=0"), PLAIN);
    eq("NONE", Lifted.claimDoneText("NONE"), PLAIN);
    eq("ERR", Lifted.claimDoneText("ERR timeout"), PLAIN);
    eq("null", Lifted.claimDoneText(null), PLAIN);
    eq("empty", Lifted.claimDoneText(""), PLAIN);
    eq("garbage", Lifted.claimDoneText("\u0000 pending=1 ???"), PLAIN);
    eq("non-numeric pending", Lifted.claimDoneText("OK through=0 pending=x"), PLAIN);
    for (String s : new String[] { PENDING, EXTEND, PLAIN }) {
      String l = s.toLowerCase();
      if (l.contains("active") || l.contains("credit") || l.contains("token") || l.contains("jitter")) {
        System.out.println("  FAIL  forbidden word in: " + s); fails++;
      }
    }
    System.out.println(fails == 0 ? "suite passed" : "suite FAILED (" + fails + ")");
    System.exit(fails == 0 ? 0 : 1);
  }
}
JAVA
  } > "$WORK/ClaimCopy.java"
  "$JAVAC" -nowarn -d "$WORK" "$WORK/ClaimCopy.java" 2>"$WORK/javac.err" || { [ "${2:-}" = quiet ] || head -5 "$WORK/javac.err"; return 4; }
  if [ "${2:-}" = quiet ]; then "$JAVA" -cp "$WORK" ClaimCopy >/dev/null 2>&1; else "$JAVA" -cp "$WORK" ClaimCopy; fi
}

# The handler must not carry the retired literals.
gone() { # gone <file> -> 0 when neither retired literal is present
  local hits
  hits=$(grep -nF -e 'Your storage plan is active' -e 'Your plan is active, but' "$1" || true)
  [ -z "$hits" ] || { echo "$hits"; return 1; }
}

suite "$PROFILE"; RC=$?
[ "$RC" -ge 3 ] && exit 2
if gone "$PROFILE"; then echo "  PASS  no retired 'is active' literal in ProfileActivity"
else echo "  FAIL  retired literal present"; RC=1; fi
[ "$MUTATE" = 0 ] && exit $RC
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo
echo "== mutations (each MUST be convicted) =="
MRC=0
mutant() { # mutant <label> <sed script> [literal: restore a retired literal]
  local m="$WORK/mut.java" rc=0
  sed "$2" "$PROFILE" > "$m"
  if cmp -s "$PROFILE" "$m"; then printf '  ⚠ NOT APPLIED %s\n' "$1"; MRC=1; return; fi
  if [ "${3:-}" = literal ]; then
    gone "$m" >/dev/null && rc=0 || rc=1
  else
    suite "$m" quiet; rc=$?
  fi
  case "$rc" in
    0) printf '  ⚠ SURVIVED  %s\n' "$1"; MRC=1 ;;
    1) printf '  convicted   %s\n' "$1" ;;
    *) printf '  ⚠ DID NOT BUILD %s\n' "$1"; MRC=1 ;;
  esac
}
CD='/static String claimDoneText(/,/^    }/'
mutant "M1 the old 'storage plan is active' line restored" 's/"Your code is redeemed, but saving/"Your plan is active, but saving/' literal
mutant "M2 the old success line restored"  "$CD s/\"Code redeemed\\.\"/\"Your storage plan is active — it's ready to use.\"/" literal
mutant "M3 pending claim says extended"    "$CD s/pending > 0 \&\& through <= 0/pending > 0 \&\& through < 0/"
mutant "M4 extension branch dropped"       "$CD s/through >= System.currentTimeMillis/through < System.currentTimeMillis/"
mutant "M5 pending ignored"                "$CD s/long through = -1, epochsec = 604800, pending = 0;/long through = -1, epochsec = 604800, pending = 0; if (true) return \"Code redeemed.\";/"
mutant "M6 pending wording explains jitter" "$CD s/Its term is measured from when it starts\\./Its term is measured from when it starts (jitter window)./"
echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
