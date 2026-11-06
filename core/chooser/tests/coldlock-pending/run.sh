#!/usr/bin/env bash
# run.sh <ChooserActivity.java> -- NWP-20261022-25: lift parsePendingColdLock, pendingReapDue and reapSupersededColdLock
# verbatim out of ChooserActivity.java by signature, and run ColdLockPendingCases against them under plain javac/java.
# The first two use only java.lang; the reap helper runs against minimal android.* stubs written here (a recording Log,
# a DevicePolicyManager whose removeUser is driven by a static mode) and a recording sendDaemon / cleanUserStorage.
# $JAVAC / $JAVA come from the caller (core/chooser/test-coldlock-pending-java.sh).
#
# What cannot run without Android is PINNED in the source: the pending probe is sent once, only when the GET-COLDLOCK
# snapshot named no parked session; its result reaches neither createRefusedForColdLock nor parkedCreditProbeDue; the
# reap sits in the committed-login branch, after the switch is posted, behind pendingReapDue and an isUserUnlocked read.
#
# Exit codes: 1 = a case or a pin failed; 2 = a member did not extract; 3 = the lifted class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ChooserActivity.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
methods="parsePendingColdLock pendingReapDue reapSupersededColdLock"
{
  echo "import android.content.Context;"
  echo "final class Lifted {"
  echo "    static class AdminReceiver {}"
  echo "    static final java.util.List<String> daemon = new java.util.ArrayList<>();"
  echo "    static final java.util.List<Integer> cleaned = new java.util.ArrayList<>();"
  echo "    String sendDaemon(String s) { daemon.add(s); android.util.Log.EVENTS.add(\"daemon:\" + s.trim()); return \"OK\"; }"
  echo "    static void cleanUserStorage(int uid) { cleaned.add(uid); android.util.Log.EVENTS.add(\"clean:\" + uid); }"
  for m in $methods; do
    # from the method's signature line to the brace that closes it
    awk -v m="$m" '
      !on && (index($0, "    private static ") == 1 || index($0, "    private void ") == 1) && index($0, " " m "(") { on=1; depth=0 }
      on { line=$0; if (depth==0) sub(/^    private /, "    ", line); print line; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$SRC"
  done
  echo "}"
} > "$D/Lifted.java"
for m in $methods; do
  [ "$(grep -cE "^    (static [A-Za-z]+|void) $m\(" "$D/Lifted.java")" = 1 ] || { echo "EXTRACTION FAILED: $m" >&2; exit 2; }
done
for m in $methods; do
  [ "$(grep -cE "^    private (static [A-Za-z]+|void) $m\(" "$SRC")" = 1 ] || { echo "EXTRACTION FAILED: $m is not in the source exactly once" >&2; exit 2; }
done

mkdir -p "$D/android/util" "$D/android/os" "$D/android/content" "$D/android/app/admin"
cat > "$D/android/util/Log.java" <<'EOF'
package android.util;
public final class Log {
    public static final java.util.List<String> EVENTS = new java.util.ArrayList<>();
    public static int i(String tag, String msg) { EVENTS.add("i:" + msg); return 0; }
    public static int w(String tag, String msg) { EVENTS.add("w:" + msg); return 0; }
    public static int w(String tag, String msg, Throwable t) { EVENTS.add("w:" + msg + " (" + t.getClass().getSimpleName() + ")"); return 0; }
}
EOF
cat > "$D/android/os/UserHandle.java" <<'EOF'
package android.os;
public final class UserHandle {
    public final int id;
    private UserHandle(int id) { this.id = id; }
    public static UserHandle of(int id) { return new UserHandle(id); }
}
EOF
cat > "$D/android/content/Context.java" <<'EOF'
package android.content;
public abstract class Context {
    public static final String DEVICE_POLICY_SERVICE = "device_policy";
    public abstract Object getSystemService(String name);
}
EOF
cat > "$D/android/content/ComponentName.java" <<'EOF'
package android.content;
public final class ComponentName {
    public ComponentName(Context c, Class<?> k) {}
}
EOF
cat > "$D/android/app/admin/DevicePolicyManager.java" <<'EOF'
package android.app.admin;
public class DevicePolicyManager {
    public static String mode = "true"; // "true" | "false" | "throw"
    public static int removed = -1;
    public boolean removeUser(android.content.ComponentName admin, android.os.UserHandle u) {
        if (mode.equals("throw")) throw new SecurityException("not the device owner");
        removed = u.id;
        return mode.equals("true");
    }
}
EOF
cp "$here/ColdLockPendingCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" -sourcepath "$D" "$D/Lifted.java" "$D/ColdLockPendingCases.java" || exit 3
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D" ColdLockPendingCases || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3

# --- the source pins ---------------------------------------------------------------------------------------------------
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; rc=1; }
# line_of <exact line>: its line number when it is in the source exactly once, else nothing
line_of() { [ "$(grep -cxF -- "$1" "$SRC" || true)" = 1 ] && grep -nxF -- "$1" "$SRC" | cut -d: -f1 || true; }
# block_end <start line>: the line where the brace opened on <start line> closes
block_end() {
  awk -v s="$1" 'NR>=s { n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && NR>s) { print NR; exit } if (depth==0 && n+c>0) { print NR; exit } }' "$SRC"
}

SNAP='            int supersedeColdUid = -1;'
GUARD='            if (supersedeColdUid <= 0) {'
PROBE='                try { pendingColdUid = parsePendingColdLock(sendDaemon("GET-COLDLOCK-PENDING\n")); } catch (Throwable ignore) {}'
l_snap=$(line_of "$SNAP"); l_guard=$(line_of "$GUARD"); l_probe=$(line_of "$PROBE")
l_cl=$(line_of '                String cl0 = sendDaemon("GET-COLDLOCK\n").trim();')
if [ -n "$l_snap" ] && [ -n "$l_guard" ] && [ -n "$l_probe" ] && [ -n "$l_cl" ] \
   && [ "$(grep -c 'GET-COLDLOCK-PENDING' "$SRC")" -ge 1 ] \
   && [ "$(grep -c 'sendDaemon("GET-COLDLOCK-PENDING' "$SRC")" = 1 ] \
   && [ "$l_probe" = $((l_guard + 1)) ] && [ "$(block_end "$l_guard")" = $((l_probe + 1)) ] && [ "$l_guard" -gt "$l_cl" ]; then
  pass "the pending probe is sent once, alone in an 'if (supersedeColdUid <= 0)' block after the GET-COLDLOCK snapshot"
else fail "the pending probe is sent once, alone in an 'if (supersedeColdUid <= 0)' block after the GET-COLDLOCK snapshot"; fi

n_cr=$(grep -c 'createRefusedForColdLock(' "$SRC" || true)
n_pc=$(grep -c 'parkedCreditProbeDue(' "$SRC" || true)
bad=$(grep -E 'createRefusedForColdLock\(|parkedCreditProbeDue\(' "$SRC" | grep -c 'pendingColdUid' || true)
if [ "$n_cr" = 2 ] && [ "$n_pc" = 2 ] && [ "$bad" = 0 ] \
   && [ "$(grep -c 'if (isCreate && createRefusedForColdLock(coldLock0)) {' "$SRC")" = 1 ] \
   && [ "$(grep -c 'if (parkedCreditProbeDue(isCreate, supersedeColdUid, supersedeLossAcceptedUid)) {' "$SRC")" = 1 ]; then
  pass "pendingColdUid reaches neither createRefusedForColdLock nor parkedCreditProbeDue"
else fail "pendingColdUid reaches neither createRefusedForColdLock nor parkedCreditProbeDue (calls: $n_cr/$n_pc, tainted: $bad)"; fi

l_switch=$(line_of '                runOnUiThread(() -> { switchingIn = true; switchingInAt = android.os.SystemClock.uptimeMillis(); signinWorkerRunning = false; switchingInCreate = isCreate; lockGate(false); switchToUser(uid, ownedLbls); finish(); }); // #50: cover the switch-in flash')
l_fail=$(line_of '                if (uid >= 0) stopRoamUser(uid); // blind: no access; gate/reboot reaps the empty user')
l_else=$(line_of '                } else if (pendingColdUid > 0) {')
l_read=$(line_of '                        stillUnlocked = pum == null || pum.isUserUnlocked(android.os.UserHandle.of(pendingColdUid));')
l_due=$(line_of '                    if (pendingReapDue(pendingColdUid, uid, stillUnlocked)) reapSupersededColdLock(appCtx, pendingColdUid, uid);')
if [ -n "$l_switch" ] && [ -n "$l_fail" ] && [ -n "$l_else" ] && [ -n "$l_read" ] && [ -n "$l_due" ] \
   && [ "$l_switch" -lt "$l_else" ] && [ "$l_else" -lt "$l_read" ] && [ "$l_read" -lt "$l_due" ] && [ "$l_due" -lt "$l_fail" ] \
   && [ "$(grep -c 'reapSupersededColdLock(appCtx, pendingColdUid' "$SRC")" = 1 ] \
   && [ "$(line_of '                    boolean stillUnlocked = true;')" -lt "$l_read" ] \
   && [ "$(line_of '                    } catch (Throwable t) { stillUnlocked = true; }')" -gt "$l_read" ]; then
  pass "the pending reap sits in the committed-login branch, after the switch is posted, behind an isUserUnlocked read (a throwing read counts as unlocked) and pendingReapDue"
else fail "the pending reap sits in the committed-login branch, after the switch is posted, behind an isUserUnlocked read (a throwing read counts as unlocked) and pendingReapDue"; fi

# the superseded-session reap and this one share the helper: the login thread no longer calls removeUser itself
l_rm=$(grep -n '\.removeUser(rAdmin, android.os.UserHandle.of(coldUid))' "$SRC" | cut -d: -f1 | head -n1)
l_h=$(grep -nE '^    private void reapSupersededColdLock\(' "$SRC" | cut -d: -f1)
if [ -n "$l_rm" ] && [ -n "$l_h" ] && [ "$l_rm" -gt "$l_h" ] && [ "$l_rm" -lt "$(block_end "$l_h")" ] \
   && ! grep -q 'removeUser(rAdmin, android.os.UserHandle.of(supersedeColdUid))' "$SRC"; then
  pass "both #123 reaps go through reapSupersededColdLock"
else fail "both #123 reaps go through reapSupersededColdLock"; fi
exit "$rc"
