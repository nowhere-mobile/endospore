#!/usr/bin/env bash
# test-wallet-repair-java.sh [--mutate] -- Profile > Storage's warned wallet repair, run under javac (NWP-20261103-06).
#
# WHY THIS IS COMMITTED. The agent's REPAIR-WALLET verb (NWP-20261103-03) is reachable only from a screen, and Q153
# says that screen offers it only when the stored wallet is proven DAMAGED, behind a dialog that says what is given up,
# with Cancel the default. WalletRepairCopy (pure, java.lang only) holds the reply classifier and the copy and is
# compiled here with its cases; source checks over showStorage pin, byte for byte, that the CHECK runs on the plan
# thread and the button is created only under the DAMAGED verdict, that CONFIRM is sent only from the dialog's positive
# button after it disables the button, and that a repair repaints the summary only from the last GET-BILLING reply:
# the CONFIRM thread's one body write is the pinned repaint from lastBill[0], it never assigns lastBill[0] or
# lastEnt[0], CONFIRM is its only daemon call, and showStorage builds one GET-BILLING request in any send form.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-wallet-repair-java.sh            # the cases and the source checks
#   bash test-wallet-repair-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/WalletRepairCopy.java"
SCREEN="$SRC/ProfileActivity.java"
RUN="$root/core/chooser/tests/wallet-repair/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$RUN" ] || { echo "FAIL: missing $RUN" >&2; exit 2; }

# suite <WalletRepairCopy.java> <ProfileActivity.java> -> run.sh's code: 0 pass, 1 a check failed, 3 did not compile.
suite() {
  local d rc
  d=$(mktemp -d -p "$W") || return 3
  bash "$RUN" "$1" "$2" "$d"; rc=$?
  rm -rf "$d"
  return "$rc"
}

echo "== $SUT"
suite "$SUT" "$SCREEN" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <copy|screen> <perl-expr>
  local label="$1" kind="$2" expr="$3" d c orig rc
  d=$(mktemp -d -p "$W") || return 1
  if [ "$kind" = copy ]; then orig="$SUT"; c="$d/WalletRepairCopy.java"; else orig="$SCREEN"; c="$d/ProfileActivity.java"; fi
  cp "$orig" "$c"
  if ! perl -0pi -e "$expr" "$c"; then echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  if [ "$kind" = copy ]; then suite "$c" "$SCREEN" >/dev/null 2>&1; rc=$?; else suite "$SUT" "$c" >/dev/null 2>&1; rc=$?; fi
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $label"; return 1 ;;
    1) echo "  convicted $label"; return 0 ;;
    *) echo "  BROKEN    $label -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "U1 UNKNOWN shows the button" copy 's/return "DAMAGED"\.equals\(norm\(checkReply\)\);/return "DAMAGED".equals(norm(checkReply)) || "UNKNOWN".equals(norm(checkReply));/' || fails=$((fails+1))
mut "U2 the dialog drops the give-up sentence" copy 's/\s*\+ "Repairing gives that credit up, so credit you buy from now on is saved again\. "//' || fails=$((fails+1))
mut "U3 CONFIRM sent without the dialog" screen 's/secondaryButton\(WalletRepairCopy\.BUTTON_LABEL, \(\) -> \{/secondaryButton(WalletRepairCopy.BUTTON_LABEL, () -> { new Thread(() -> sendDaemon(WalletRepairCopy.CONFIRM_REQUEST)).start();/' || fails=$((fails+1))
mut "U4 the button is created outside the offerRepair gate" screen 's/if \(WalletRepairCopy\.offerRepair\(repairCheck\)\) runOnUiThread\(\(\) -> \{/if (WalletRepairCopy.offerRepair(repairCheck)) { } runOnUiThread(() -> {/' || fails=$((fails+1))
mut "U5 the button is not disabled before CONFIRM" screen 's/\n *repair\[0\]\.setEnabled\(false\);(\n *new Thread\(\(\) -> \{)/$1/' || fails=$((fails+1))
mut "U6 a repair re-reads GET-BILLING" screen 's/(\n( *)final String r = sendDaemon\(WalletRepairCopy\.CONFIRM_REQUEST\);)/$1\n${2}final String bill = WalletRepairCopy.repaired(r) ? sendDaemon("GET-BILLING\\n").trim() : null;/' || fails=$((fails+1))
mut "U7 a second dialog sends a second CONFIRM" screen 's/\n *if \(repair\[0\] == null \|\| !repair\[0\]\.isEnabled\(\)\) return;(\n *repair\[0\]\.setEnabled\(false\);)/$1/' || fails=$((fails+1))
mut "U8 a repair repaints from a fresh or empty bill" screen 's/if \(lastBill\[0\] != null\) body\.setText\(formatBilling\(lastBill\[0\], lastEnt\[0\]\)\);(\n *\} else \{)/lastBill[0] = ""; body.setText(formatBilling("", lastEnt[0]));$1/' || fails=$((fails+1))
mut "U9 a repair re-reads GET-BILLING through sendDaemonReply" screen 's/(\n( *)final String r = sendDaemon\(WalletRepairCopy\.CONFIRM_REQUEST\);)/$1\n${2}final String bill = WalletRepairCopy.repaired(r) ? sendDaemonReply("GET-BILLING\\n").text.trim() : null;/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
