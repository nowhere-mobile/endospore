#!/usr/bin/env bash
# run.sh <WalletRepairCopy.java> <ProfileActivity.java> <scratch-dir> -- NWP-20261103-06.
# Compiles the copy with Cases.java and runs them, then checks showStorage's wiring. $JAVAC / $JAVA come from the
# caller; every temp is made under <scratch-dir>. Exit 0 pass, 1 a case or source check failed, 3 did not compile.
set -uo pipefail

COPY="$1"; PA="$2"; D="$3"
here=$(cd "$(dirname "$0")" && pwd)
bad=0

if [ ! -f "$COPY" ]; then echo "  FAIL  WalletRepairCopy.java does not exist"; exit 1; fi
mkdir -p "$D/src/com/nowhere/chooser" || exit 3
cp "$COPY" "$D/src/com/nowhere/chooser/WalletRepairCopy.java"
cp "$here/Cases.java" "$D/src/com/nowhere/chooser/Cases.java"
"$JAVAC" -encoding UTF-8 -d "$D/out" "$D"/src/com/nowhere/chooser/*.java || exit 3
out=$("$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.Cases 2>&1); rc=$?
echo "$out"
[ "$rc" -eq 0 ] || bad=1

# cnt <regex>: the non-comment lines on stdin matching it.
body=$(awk '/private void showStorage\(\) \{/ { on = 1 } on { print } on && /^    }$/ { exit }' "$PA")
if [ -z "$body" ]; then echo "  FAIL  showStorage not found in $PA"; exit 1; fi
cnt() { RE="$1" awk '$0 !~ /^[ \t]*\/\// && $0 ~ ENVIRON["RE"] { n++ } END { print n + 0 }'; }
# blk <lines>: how many times <lines> occur consecutively, byte for byte, in the lines on stdin.
blk() {
  B="$1" awk 'BEGIN { k = split(ENVIRON["B"], w, "\n") }
    { l[NR] = $0 }
    END {
      for (i = 1; i + k - 1 <= NR; i++) {
        ok = 1
        for (j = 1; j <= k; j++) if (l[i + j - 1] != w[j]) { ok = 0; break }
        if (ok) n++
      }
      print n + 0
    }'
}

n=$(printf '%s\n' "$body" | cnt 'sendDaemon\(WalletRepairCopy\.CHECK_REQUEST\)')
[ "$n" -eq 1 ] || { echo "  FAIL  showStorage does not send CHECK exactly once"; bad=1; }
n=$(printf '%s\n' "$body" | cnt 'if \(WalletRepairCopy\.offerRepair\(repairCheck\)\)')
[ "$n" -eq 1 ] || { echo "  FAIL  the offer is not gated on offerRepair(repairCheck)"; bad=1; }
# The offer, byte for byte: CHECK on the plan thread itself (not in a UI post), after GET-ENTITLEMENT and before
# that thread ends, and the button created only inside the offerRepair gate.
offer=$(printf '%s\n' \
  '            final String repairCheck = sendDaemon(WalletRepairCopy.CHECK_REQUEST);' \
  '            if (WalletRepairCopy.offerRepair(repairCheck)) runOnUiThread(() -> {' \
  '                if (isFinishing() || isDestroyed() || repair[0] != null) return;' \
  '                repair[0] = secondaryButton(WalletRepairCopy.BUTTON_LABEL, () -> {')
reg=$(printf '%s\n' "$body" | awk '!from && index($0, "sendDaemon(\"GET-ENTITLEMENT\\n\")") { from = NR; next }
  from && $0 == "        }).start();" { print "-- the plan thread ends --"; exit }
  from { print }')
case "$reg" in *"-- the plan thread ends --") ;; *) reg= ;; esac
n=$(printf '%s\n' "$reg" | blk "$offer")
[ "$n" -eq 1 ] || { echo "  FAIL  the repair offer is not the pinned block on the plan thread, after GET-ENTITLEMENT"; bad=1; }
n=$(cnt 'WalletRepairCopy\.BUTTON_LABEL' < "$PA")
[ "$n" -eq 1 ] || { echo "  FAIL  the repair button is not created exactly once"; bad=1; }
n=$(cnt 'WalletRepairCopy\.CONFIRM_REQUEST' < "$PA")
[ "$n" -eq 1 ] || { echo "  FAIL  CONFIRM is not sent from exactly one place"; bad=1; }
# The positive button, byte for byte: on the UI thread it refuses a second dialog's tap and disables the button,
# and only then starts the thread whose first act is CONFIRM.
pos=$(printf '%s\n' \
  '                            .setPositiveButton(WalletRepairCopy.POSITIVE, (d, w) -> {' \
  '                                if (repair[0] == null || !repair[0].isEnabled()) return;' \
  '                                repair[0].setEnabled(false);' \
  '                                new Thread(() -> {' \
  '                                    final String r = sendDaemon(WalletRepairCopy.CONFIRM_REQUEST);')
n=$(printf '%s\n' "$body" | blk "$pos")
[ "$n" -eq 1 ] || { echo "  FAIL  CONFIRM is not sent from the positive button that disables the button first"; bad=1; }
# CONFIRM writes only the proof and the seen-set, never the wallet, so a repair repaints from the last GET-BILLING
# reply. A second read that failed ("") would paint a live plan as the free tier, and every GET-USAGE repaint after
# it would repeat that. Over the CONFIRM thread's non-comment lines, from its CONFIRM line to its start(): the body
# is written once, by the pinned repaint; lastBill[0] and lastEnt[0] are never assigned; and CONFIRM is its only
# daemon call. Across showStorage, a GET-BILLING request is built exactly once, in any send form.
repaint='                                            if (lastBill[0] != null) body.setText(formatBilling(lastBill[0], lastEnt[0]));'
creg=$(printf '%s\n' "$body" | awk '
  !on && $0 == "                                    final String r = sendDaemon(WalletRepairCopy.CONFIRM_REQUEST);" { on = 1 }
  on && $0 == "                                }, \"nowhere-wallet-repair\").start();" { print "-- the CONFIRM thread ends --"; exit }
  on && $0 !~ /^[ \t]*\/\// { print }')
case "$creg" in *"-- the CONFIRM thread ends --") ;; *) creg= ;; esac
if [ -z "$creg" ]; then
  echo "  FAIL  the CONFIRM thread does not run from its CONFIRM line to its start()"; bad=1
else
  n=$(printf '%s\n' "$creg" | cnt 'body\.set[A-Z]|StatusLine\.[A-Za-z]+\(body[,)]')
  m=$(printf '%s\n' "$creg" | blk "$repaint")
  [ "$n" -eq 1 ] && [ "$m" -eq 1 ] \
    || { echo "  FAIL  a repair does not repaint the summary only from lastBill[0], by the pinned line"; bad=1; }
  n=$(printf '%s\n' "$creg" | cnt 'last(Bill|Ent)\[0\] *=([^=]|$)')
  [ "$n" -eq 0 ] || { echo "  FAIL  a repair assigns lastBill[0] or lastEnt[0]"; bad=1; }
  n=$(printf '%s\n' "$creg" | cnt 'sendDaemon|sendExport|sendPromote|daemonLenReply|DaemonSocket')
  [ "$n" -eq 1 ] || { echo "  FAIL  the CONFIRM thread makes a daemon call other than CONFIRM"; bad=1; }
fi
n=$(printf '%s\n' "$body" | cnt '"GET-BILLING')
[ "$n" -eq 1 ] || { echo "  FAIL  showStorage does not read GET-BILLING exactly once"; bad=1; }
n=$(cat "$PA" "$(dirname "$PA")/ChooserActivity.java" | cnt '"REPAIR-WALLET')
[ "$n" -eq 0 ] || { echo "  FAIL  a literal REPAIR-WALLET request is built outside WalletRepairCopy"; bad=1; }
n=$(printf '%s\n' "$body" | cnt '\.setNegativeButton\(WalletRepairCopy\.NEGATIVE')
[ "$n" -eq 1 ] || { echo "  FAIL  the dialog has no Cancel button"; bad=1; }
n=$(printf '%s\n' "$body" | cnt 'BUTTON_NEGATIVE\)')
[ "$n" -eq 1 ] || { echo "  FAIL  Cancel is not looked up to be focused"; bad=1; }
n=$(printf '%s\n' "$body" | cnt 'neg\.requestFocus\(\)')
[ "$n" -eq 1 ] || { echo "  FAIL  Cancel is not the default"; bad=1; }
[ "$bad" -eq 0 ] && echo "source: ok"
[ "$bad" -eq 0 ]
