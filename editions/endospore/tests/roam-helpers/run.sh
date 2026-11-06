#!/usr/bin/env bash
# run.sh <SyncRoam.java> <VpnAlwaysOn.java> <ProfileActivity.java> <nowhere_roamd.sh> -- NWP-20261010-15: compile
# np.SyncRoam and np.VpnAlwaysOn UNCHANGED against the fakes in fakes/ (a framework that refuses a root caller per
# switch and an authority with no adapter package, as GrapheneOS does), lift the chooser's pure VPN-picker statics out
# of ProfileActivity, run RoamHelperCases over all three, then feed the pick files the chooser code writes to roamd's
# own vpn_choice (under each of bash, dash and mksh that is installed), so the two halves of the pick format cannot
# drift apart. JAVAC and JAVA name the tools (default: javac, java on PATH);
# core/vendor-common/bin/test-roam-helpers-java.sh resolves them and is what CI runs.
set -euo pipefail
SYNC="${1:?usage: run.sh SyncRoam.java VpnAlwaysOn.java ProfileActivity.java nowhere_roamd.sh}"
VPN="${2:?}"; PA="${3:?}"; ROAMD="${4:?}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
methods="vpnCurrentFrom vpnPickLockdown vpnPickText vpnPickToast vpnPkgOk vpnUnsupportedText"
{
  echo "package np;"
  echo "final class Lifted {"
  for m in $methods; do
    # from the method's signature line to the brace that closes it
    awk -v m="$m" '
      !on && index($0, "private static ") && index($0, " " m "(") { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$PA" | sed 's/private static/static/'
  done
  echo "}"
} > "$D/Lifted.java"
for m in $methods; do grep -q " $m(" "$D/Lifted.java" || { echo "extraction missed $m" >&2; exit 2; }; done
mkdir -p "$D/classes" "$D/picks" "$D/np"
cp "$SYNC" "$D/np/SyncRoam.java"; cp "$VPN" "$D/np/VpnAlwaysOn.java"
"$JAVAC" -J-Djava.io.tmpdir="$D" -encoding UTF-8 -Xlint:-options -d "$D/classes" $(find "$here/fakes" -name '*.java') \
  "$D/np/SyncRoam.java" "$D/np/VpnAlwaysOn.java" "$D/Lifted.java" "$here/RoamHelperCases.java"
# roamd's own bound on the helper, so the cases can hold the helper's relaunch bound strictly inside it.
TMO=$(sed -n 's/^SYNC_TIMEOUT="\${NOWHERE_SYNC_TIMEOUT:-\([0-9][0-9]*\)}"$/\1/p' "$ROAMD")
[ -n "$TMO" ] || { echo "extraction missed SYNC_TIMEOUT in $ROAMD" >&2; exit 2; }
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D/classes" np.RoamHelperCases "$D/picks" "$TMO"

# The cross-language pin: roamd's vpn_choice must read exactly what the picker writes.
FN=$(sed -n '/^vpn_choice() {$/,/^}$/p' "$ROAMD")
[ -n "$FN" ] || { echo "extraction missed vpn_choice" >&2; exit 2; }
SHELLS=""; ABSENT=""
for sh in bash dash mksh; do
  if command -v "$sh" >/dev/null 2>&1; then SHELLS="$SHELLS $sh"; else ABSENT="$ABSENT $sh"; fi
done
echo "pin shells:$SHELLS"
for sh in $ABSENT; do echo "  skip  [$sh] not installed"; done
fails=0
pin() {  # pin <pick file> <want>, under every shell found (roamd runs under mksh on the device)
  local sh got
  for sh in $SHELLS; do
    got=$("$sh" -c "$FN
vpn_choice '$1' /nonexistent /nonexistent") || got="<exit $?>"
    if [ "$got" = "$2" ]; then echo "  ok    [$sh] vpn_choice reads $(basename "$1") as '$2'"
    else echo "  FAIL  [$sh] vpn_choice read $(basename "$1") as '$got', want '$2'"; fails=1; fi
  done
}
pin "$D/picks/pick-on" "pick com.y 1"
pin "$D/picks/pick-off" "pick - 0"
pin "$D/picks/pick-noblock" "pick com.z 0"
# Hand-written texts the picker never writes, so what vpn_choice answers to them is pinned exactly: an Off pick that
# carries lockdown=1 is clamped to 0 (the clamp), and a pick with no app= line or a bad character in the app is
# refused, which falls to the (absent) prefs.
printf 'app=\nlockdown=1\n' > "$D/picks/hand-off-lock1"
printf 'app=com.y\nlockdown=1\n' > "$D/picks/hand-on-lock1"
printf 'lockdown=1\n' > "$D/picks/hand-noapp"
printf 'app=com.x;rm\nlockdown=1\n' > "$D/picks/hand-badchar"
pin "$D/picks/hand-off-lock1" "pick - 0"
pin "$D/picks/hand-on-lock1" "pick com.y 1"
pin "$D/picks/hand-noapp" "none - 0"
pin "$D/picks/hand-badchar" "none - 0"
exit $fails
