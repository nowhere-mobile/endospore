#!/usr/bin/env bash
# test-perms-relay-java.sh [--mutate] -- NWP-20261112-10: the user-0 half of permissions captured on change
# (docs/product-decisions.md, 2026-10-20, Q061). Backlog row "A permission answered in a session that never signs out
# is lost: permissions are captured only at sign-out".
#
# Runs core/chooser/tests/perms-relay (PermsRelayGate's armOn / relevant / mayRelay / QUIET_MS, compiled and EXECUTED),
# then source checks on the real files:
#   s1 the manifest requests OBSERVE_GRANT_REVOKE_PERMISSIONS (addOnPermissionsChangeListener enforces it);
#   s2 NowhereApp registers PermsLiveRecord at process birth;
#   s3 provisionRoamedApps disarms before it sends GRANT-PERMS, and arms after it, only through PermsRelayGate.armOn --
#      and nothing else in ChooserActivity arms;
#   s4 PermsLiveRecord listens with addOnPermissionsChangeListener, filters with PermsRelayGate.relevant, waits
#      PermsRelayGate.QUIET_MS, and relays with sendBroadcastAsUser to PermsCaptureReceiver behind PermsRelayGate.mayRelay;
#   s5 DozeAppsMirror's ACTION_USER_REMOVED receiver calls PermsLiveRecord.disarmFor(departed);
#   s6 roamd's grant_perms_for records the install-heal re-check (NWP-20261112-10, PermsCaptureRule).
# What it does not prove: the chooser is not compiled here (the build host's javac check is), and nothing runs on a
# device -- whether a user-0 listener hears another user's uid is the handset check.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies, each of which must be CONVICTED: a mutant that does not apply
# (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-perms-relay-java.sh            # the cases and source checks
#   bash test-perms-relay-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-perms-relay-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
SRCDIR="$ROOT/core/chooser/src/com/nowhere/chooser"
GATE="$SRCDIR/PermsRelayGate.java"
MAN="$ROOT/core/chooser/AndroidManifest.xml"
APP="$SRCDIR/NowhereApp.java"
CA="$SRCDIR/ChooserActivity.java"
PLR="$SRCDIR/PermsLiveRecord.java"
DAM="$SRCDIR/DozeAppsMirror.java"
ROAMD="$ROOT/core/vendor-common/bin/nowhere_roamd.sh"

# code <file>: the file with `//` comments and trailing blanks stripped (none of the lines checked holds `//` inside a string literal)
code() { sed -e 's#//.*$##' -e 's/[[:space:]]*$//' "$1"; }

# method <file> <signature line>: that method from its signature to the brace that closes it, `//` comments and string
# literals' contents stripped for the brace count. Empty when the signature is missing; __UNBALANCED__ when the braces
# never balance.
method() {
  awk -v sig="$2" '
    !on && $0 == sig { on=1 }
    on {
      c=$0; sub(/\/\/.*$/, "", c); sub(/[ \t]+$/, "", c); print c
      s=c; gsub(/"([^"\\]|\\.)*"/, "", s); gsub(/'\''([^'\''\\]|\\.)*'\''/, "", s)
      for (i=1;i<=length(s);i++) { ch=substr(s,i,1); if (ch=="{") d++; else if (ch=="}") { d--; if (d==0) { ok=1; exit } } }
    }
    END { if (on && !ok) print "__UNBALANCED__" }' "$1"
}

# lineof <fixed string> <text>: the 1-based line of its first occurrence, 0 when absent
lineof() {
  local n
  n=$(grep -nF -- "$1" <<<"$2" | head -1 | cut -d: -f1)
  echo "${n:-0}"
}

# has <fixed string> <text>: true when the text holds it (no pipe into grep -q)
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# check <gate> <manifest> <NowhereApp> <ChooserActivity> <PermsLiveRecord> <DozeAppsMirror> <roamd>: the cases, then
# s1-s6. Returns 3 when the cases do not compile, 1 on any failed case or check.
check() {
  local gate=$1 man=$2 app=$3 ca=$4 plr=$5 dam=$6 roamd=$7 rc src b n l1 l2 l3 line
  JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/perms-relay/run.sh" "$gate"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL cases (run.sh rc=$rc)"; [ "$rc" -eq 3 ] && return 3; return 1; }
  # (s1) outside an XML comment: the manifest's comments never span the uses-permission line itself
  n=$(grep -cxF '  <uses-permission android:name="android.permission.OBSERVE_GRANT_REVOKE_PERMISSIONS"/>' "$man")
  [ "$n" = 1 ] || { echo "FAIL s1: the manifest requests OBSERVE_GRANT_REVOKE_PERMISSIONS $n time(s), want 1"; return 1; }
  echo "  ok   s1 the manifest requests OBSERVE_GRANT_REVOKE_PERMISSIONS"
  # (s2)
  src=$(code "$app")
  n=$(grep -cxF '        PermsLiveRecord.register(this);' <<<"$src")
  [ "$n" = 1 ] || { echo "FAIL s2: NowhereApp registers PermsLiveRecord $n time(s), want 1"; return 1; }
  echo "  ok   s2 NowhereApp registers PermsLiveRecord"
  # (s3)
  b=$(method "$ca" '    private void provisionRoamedApps(int uid) {')
  [ -n "$b" ] || { echo "FAIL s3: no provisionRoamedApps(int uid)"; return 1; }
  has __UNBALANCED__ "$b" && { echo "FAIL s3: provisionRoamedApps' braces never balance"; return 1; }
  l1=$(lineof 'PermsLiveRecord.disarm();' "$b")
  l2=$(lineof 'sendDaemonLines("GRANT-PERMS\n" + uid + "\n")' "$b")
  l3=$(lineof 'PermsLiveRecord.arm(' "$b")
  [ "$l1" -gt 0 ] && [ "$l2" -gt "$l1" ] && [ "$l3" -gt "$l2" ] \
    || { echo "FAIL s3: provisionRoamedApps does not disarm, then send GRANT-PERMS, then arm (lines $l1 $l2 $l3)"; return 1; }
  line=$(sed -n "${l3}p" <<<"$b" | tr -d ' ')
  [ "$line" = 'if(PermsRelayGate.armOn(granted.isEmpty()?null:granted.get(0)))PermsLiveRecord.arm(uid);' ] \
    || { echo "FAIL s3: the arm is not conditioned on PermsRelayGate.armOn of the GRANT-PERMS reply's first line"; return 1; }
  [ "$(sed -n "${l2}p" <<<"$b" | tr -d ' ')" = 'java.util.List<String>granted=sendDaemonLines("GRANT-PERMS\n"+uid+"\n");' ] \
    || { echo "FAIL s3: the GRANT-PERMS reply is not what armOn reads (granted)"; return 1; }
  n=$(code "$ca" | grep -c 'PermsLiveRecord\.arm(')
  [ "$n" = 1 ] || { echo "FAIL s3: PermsLiveRecord.arm( appears $n time(s) in ChooserActivity, want 1"; return 1; }
  echo "  ok   s3 GRANT-PERMS: disarm before the send, arm only through PermsRelayGate.armOn"
  # (s4)
  src=$(code "$plr")
  for line in 'addOnPermissionsChangeListener(uid -> onChanged(uid));' \
      'if (!PermsRelayGate.relevant(uid, liveUser)) return;' \
      'hh.postDelayed(r, PermsRelayGate.QUIET_MS);' \
      'if (!pending || !PermsRelayGate.mayRelay(cur, liveUser, unlocked)) return;' \
      'app.sendBroadcastAsUser(new Intent(app, PermsCaptureReceiver.class)' \
      'if (UserHandle.myUserId() != 0) return;'; do
    has "$line" "$src" || { echo "FAIL s4: PermsLiveRecord does not hold: $line"; return 1; }
  done
  l1=$(lineof 'if (!pending || !PermsRelayGate.mayRelay(cur, liveUser, unlocked)) return;' "$src")
  l2=$(lineof 'app.sendBroadcastAsUser(new Intent(app, PermsCaptureReceiver.class)' "$src")
  [ "$l2" -gt "$l1" ] || { echo "FAIL s4: the relay is sent before the mayRelay test"; return 1; }
  echo "  ok   s4 the relay targets PermsCaptureReceiver with sendBroadcastAsUser, behind relevant / QUIET_MS / mayRelay"
  # (s5)
  b=$(method "$dam" '    static void registerRemovalSweep(Context ctx) {')
  [ -n "$b" ] || { echo "FAIL s5: no DozeAppsMirror.registerRemovalSweep"; return 1; }
  has 'new android.content.IntentFilter(Intent.ACTION_USER_REMOVED)' "$b" \
    || { echo "FAIL s5: registerRemovalSweep no longer filters ACTION_USER_REMOVED"; return 1; }
  n=$(grep -cxF '                    PermsLiveRecord.disarmFor(departed);' <<<"$b")
  [ "$n" = 1 ] || { echo "FAIL s5: the USER_REMOVED receiver calls PermsLiveRecord.disarmFor(departed) $n time(s), want 1"; return 1; }
  echo "  ok   s5 the USER_REMOVED receiver disarms a departed session"
  # (s6)
  b=$(awk '/^grant_perms_for\(\) \{$/ { on=1 } on { print } on && /^}$/ { exit }' "$roamd")
  has 'NWP-20261112-10' "$b" && has 'PermsCaptureRule.keepCarried' "$b" \
    || { echo "FAIL s6: grant_perms_for does not record the NWP-20261112-10 install-heal re-check (PermsCaptureRule)"; return 1; }
  echo "  ok   s6 grant_perms_for records the install-heal re-check"
}
check "$GATE" "$MAN" "$APP" "$CA" "$PLR" "$DAM" "$ROAMD" || { echo "FAILED"; exit 1; }
echo "== all checks pass"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <gate|man|ca> <perl-expr> <text the failure must contain>
  local d f orig gate man ca out rc
  d=$(mktemp -d -p "$W"); gate=$GATE; man=$MAN; ca=$CA
  case "$2" in
    gate) orig=$GATE; f="$d/PermsRelayGate.java";  gate=$f ;;
    man)  orig=$MAN;  f="$d/AndroidManifest.xml";  man=$f ;;
    ca)   orig=$CA;   f="$d/ChooserActivity.java"; ca=$f ;;
    *) echo "  ERROR     $1 -- unknown target $2"; return 1 ;;
  esac
  cp "$orig" "$f"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$orig" "$f"; then echo "  INERT     $1"; return 1; fi
  out=$(check "$gate" "$man" "$APP" "$ca" "$PLR" "$DAM" "$ROAMD" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -ne 1 ]; then echo "  BROKEN    $1 -- rc=$rc (did not compile)"; return 1; fi
  case "$out" in *"$4"*) ;; *) echo "  BROKEN    $1 -- it failed, but not with '$4'"; return 1 ;; esac
  echo "  convicted $1"
}
fails=0
mut "M1 armOn always true" gate 's/return grantReplyFirstLine != null && grantReplyFirstLine\.startsWith\("OK"\);/return true;/' "FAIL armOn(\"ERR-x\")" || fails=$((fails+1))
mut "M2 relevant ignores the user" gate 's/return liveUser > 0 && changedUid \/ PER_USER_RANGE == liveUser;/return liveUser > 0;/' "FAIL relevant(10123, 10)" || fails=$((fails+1))
mut "M3 mayRelay ignores unlocked" gate 's/ && currentUser == liveUser && unlocked;/ && currentUser == liveUser;/' "FAIL mayRelay(10,10,false)" || fails=$((fails+1))
mut "M4 the arm moved before GRANT-PERMS" ca 's/(\n *PermsLiveRecord\.disarm\(\);)(\n[^\n]*sendDaemonLines\("GRANT-PERMS[^\n]*)\n *if \(PermsRelayGate\.armOn\([^\n]*\) PermsLiveRecord\.arm\(uid\);/$1\n        PermsLiveRecord.arm(uid);$2/' "FAIL s3" || fails=$((fails+1))
mut "M5 the manifest permission removed" man 's/\n  <uses-permission android:name="android\.permission\.OBSERVE_GRANT_REVOKE_PERMISSIONS"\/>//' "FAIL s1" || fails=$((fails+1))
mut "M6 QUIET_MS 0" gate 's/static final long QUIET_MS = 2000;/static final long QUIET_MS = 0;/' "FAIL QUIET_MS == 2000" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
