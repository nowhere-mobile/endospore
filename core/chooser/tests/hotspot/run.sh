#!/usr/bin/env bash
# run.sh <Hotspot.java> <HotspotService.java> <HotspotReceiver.java> <AndroidManifest.xml> <ProfileActivity.java>
# (NWP-20261028-08; the ProfileActivity pins are NWP-20261028-11)
# Compiles Hotspot.java against HotspotCases and runs it, then pins the glue and the manifest as data.
# Exit: 0 pass, 1 a case or pin failed (the only code that convicts a mutant), 2 a file is missing, 3 compile failure.
set -uo pipefail
HS="${1:-}"; SV="${2:-}"; RC="${3:-}"; MF="${4:-}"; PA="${5:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
for f in "$HS" "$SV" "$RC" "$MF" "$PA" "$HERE/HotspotCases.java"; do
  [ -f "$f" ] || { echo "FAIL: missing ${f:-<unset>}" >&2; exit 2; }
done
if [ -z "${W:-}" ]; then W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT; fi
: "${JAVAC:=javac}" "${JAVA:=java}"
D=$(mktemp -d -p "$W") || exit 2
mkdir -p "$D/src/com/nowhere/chooser" "$D/out"
cp "$HS" "$D/src/com/nowhere/chooser/Hotspot.java"
cp "$HERE/HotspotCases.java" "$D/src/com/nowhere/chooser/HotspotCases.java"
"$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$D/out" "$D"/src/com/nowhere/chooser/*.java || exit 3
"$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.HotspotCases
rc=$?
if [ "$rc" -ne 0 ]; then [ "$rc" -eq 1 ] && exit 1 || exit 3; fi

fail=0
pin() { # pin <ok 0/1> <what>
  if [ "$1" -eq 0 ]; then echo "  pin ok: $2"; else echo "--- FAIL: pin: $2"; fail=1; fi
}
count() { grep -cF -- "$2" "$1" || true; }

# 1. the pure file stays pure
pin "$([ "$(grep -c android "$HS" || true)" -eq 0 ] && echo 0 || echo 1)" "Hotspot.java names nothing from the platform"
# 2/3. manifest
for p in TETHER_PRIVILEGED NETWORK_SETTINGS; do
  pin "$([ "$(count "$MF" "android.permission.$p")" -eq 1 ] && [ "$(count "$MF" "<uses-permission android:name=\"android.permission.$p\"/>")" -eq 1 ] && echo 0 || echo 1)" "$p declared once"
done
for c in "service:HotspotService" "receiver:HotspotReceiver"; do
  k="${c%%:*}"; n="${c##*:}"
  pin "$([ "$(count "$MF" "\".$n\"")" -eq 1 ] && [ "$(count "$MF" "<$k android:name=\".$n\" android:exported=\"false\"/>")" -eq 1 ] && echo 0 || echo 1)" "$n declared once, not exported, no intent-filter"
done
# 4/5. START's order: the check before any framework call, the owner before the start
body=$(awk '/private String start\(/{on=1} on{print} on&&/^    }$/{exit}' "$SV")
pin "$([ -n "$body" ] && echo 0 || echo 1)" "HotspotService.start( found"
chk=$(printf '%s\n' "$body" | grep -n 'Hotspot.mayStart(' | head -1 | cut -d: -f1)
fw=$(printf '%s\n' "$body" | grep -nE 'wifi\(|tether\(|wifi\.|tether\.|getSystemService|setSoftApConfiguration\(|startTethering\(' | head -1 | cut -d: -f1)
pin "$([ -n "$chk" ] && [ -n "$fw" ] && [ "$chk" -lt "$fw" ] && echo 0 || echo 1)" "mayStart comes before any WifiManager/TetheringManager call in START"
lk=$(printf '%s\n' "$body" | grep -n 'synchronized (LOCK)' | head -1 | cut -d: -f1)
pin "$([ -n "$chk" ] && [ -n "$lk" ] && [ "$lk" -lt "$chk" ] && printf '%s\n' "$body" | grep 'Hotspot.mayStart(' | grep -q 'ActivityManager.getCurrentUser()' && echo 0 || echo 1)" "START reads the foreground and checks mayStart INSIDE the lock the release takes (a queued start sees the session gone)"
pin "$(printf '%s\n' "$body" | grep -A1 'Hotspot.mayStart(' | grep -q 'R_CALLER' && echo 0 || echo 1)" "a refused start answers ERR-HS caller"
own=$(printf '%s\n' "$body" | grep -n '^ *owner = callerUser;$' | cut -d: -f1)
st=$(printf '%s\n' "$body" | grep -n 'startTethering(' | cut -d: -f1)
pin "$([ "$(printf '%s\n' "$own" | grep -c .)" -eq 1 ] && [ "$(printf '%s\n' "$st" | grep -c .)" -eq 1 ] && [ "$own" -lt "$st" ] && echo 0 || echo 1)" "the owner is assigned before startTethering"
pin "$([ "$(count "$SV" 'writeNoException')" -eq 0 ] && [ "$(count "$SV" 'reply.writeString(line)')" -eq 1 ] && echo 0 || echo 1)" "the reply is the bare string: no exception header"
# 6. identity
pin "$([ "$(count "$SV" 'UserHandle.myUserId() != 0')" -ge 1 ] && [ "$(count "$SV" 'Binder.getCallingUid()')" -ge 1 ] && [ "$(count "$SV" 'ActivityManager.getCurrentUser()')" -ge 1 ] && echo 0 || echo 1)" "service checks user 0, the calling uid and the foreground user"
# 7. receiver
rs=$(grep -n 'Hotspot.resetSsid(' "$RC" | head -1 | cut -d: -f1)
rp=$(grep -n 'Hotspot.resetPassphrase(' "$RC" | head -1 | cut -d: -f1)
sa=$(grep -n 'setSoftApConfiguration(' "$RC" | head -1 | cut -d: -f1)
pin "$([ -n "$rs" ] && [ -n "$rp" ] && [ -n "$sa" ] && [ "$sa" -gt "$rs" ] && [ "$sa" -gt "$rp" ] && [ "$(count "$RC" 'new java.security.SecureRandom()')" -ge 1 ] && echo 0 || echo 1)" "receiver sets a SecureRandom reset configuration"
pin "$([ "$(count "$RC" 'goAsync()')" -ge 1 ] && [ "$(count "$RC" '.finish()')" -ge 1 ] && [ "$(count "$RC" 'UserHandle.myUserId() != 0')" -ge 1 ] && echo 0 || echo 1)" "receiver is user 0 only and finishes its async result"
# 8. nothing logs, toasts or replies a name or passphrase
for f in "$SV" "$RC"; do
  logs=$(grep -n 'Log\.' "$f" || true)
  badlog=$(printf '%s\n' "$logs" | grep -iE 'ssid|pass' || true)
  incomplete=$(printf '%s\n' "$logs" | grep -v ');' | grep . || true)
  pin "$([ -z "$badlog" ] && [ -z "$incomplete" ] && echo 0 || echo 1)" "$(basename "$f"): no Log line names the ssid or passphrase"
  pin "$([ "$(grep -c Toast "$f" || true)" -eq 0 ] && echo 0 || echo 1)" "$(basename "$f"): no Toast"
done

# 9. the session's screen (NWP-20261028-11). Regions are cut by their markers/signatures, so another slice's edit of
# ProfileActivity elsewhere cannot move them.
region=$(awk '/NWP-20261028-11: Hotspot & tethering\./{on=1} on{print} /---- end NWP-20261028-11/{exit}' "$PA")
pin "$([ -n "$region" ] && echo 0 || echo 1)" "ProfileActivity: the Hotspot & tethering region found"
# the Preferences row is offered only through Hotspot.offered(sessionType, offlineSession), directly above its add
pin "$([ "$(count "$PA" 'rows.add("Hotspot & tethering");')" -eq 1 ] && grep -B1 'rows.add("Hotspot & tethering");' "$PA" | head -1 | grep -qF 'if (Hotspot.offered(sessionType, offlineSession)) {' && echo 0 || echo 1)" "the Preferences row is offered only through Hotspot.offered(sessionType, offlineSession)"
# the row sits after Mobile data and before Location services
mdl=$(grep -n 'rows.add("Mobile data");' "$PA" | head -1 | cut -d: -f1)
hsl=$(grep -n 'rows.add("Hotspot & tethering");' "$PA" | head -1 | cut -d: -f1)
ll=$(grep -n 'rows.add("Location services");' "$PA" | head -1 | cut -d: -f1)
pin "$([ -n "$mdl" ] && [ -n "$hsl" ] && [ -n "$ll" ] && [ "$mdl" -lt "$hsl" ] && [ "$hsl" -lt "$ll" ] && echo 0 || echo 1)" "the row is after Mobile data and before Location services"
# the saved config: one sibling file, read with parseConfig, written with configText through writeAtomic
pin "$([ "$(count "$PA" 'static final String HOTSPOT_FILE = "nowhere-hotspot";')" -eq 1 ] && echo 0 || echo 1)" "HOTSPOT_FILE is the sibling file nowhere-hotspot"
rd=$(awk '/private String\[\] savedHotspot\(\)/{on=1} on{print} on&&/^    }$/{exit}' "$PA")
pin "$(printf '%s\n' "$rd" | grep -q 'HOTSPOT_FILE' && printf '%s\n' "$rd" | grep -q 'Hotspot.parseConfig(' && echo 0 || echo 1)" "savedHotspot reads HOTSPOT_FILE through Hotspot.parseConfig"
wr=$(awk '/private boolean saveHotspot\(/{on=1} on{print} on&&/^    }$/{exit}' "$PA")
pin "$(printf '%s\n' "$wr" | grep -q 'Hotspot.configText(' && printf '%s\n' "$wr" | grep -q 'StoreInstaller.writeAtomic(' && printf '%s\n' "$wr" | grep -q 'HOTSPOT_FILE' && echo 0 || echo 1)" "saveHotspot writes Hotspot.configText to HOTSPOT_FILE with writeAtomic"
# the START reads the SAVED name and passphrase, never the fields
tap=$(awk '/private void hsTap\(/{on=1} on{print} on&&/^    }$/{exit}' "$PA")
pin "$(printf '%s\n' "$tap" | grep -qF 'final String[] saved = savedHotspot();' && printf '%s\n' "$tap" | grep -qF 'HotspotClient.start(ProfileActivity.this, type, saved[0], saved[1])' && [ "$(printf '%s\n' "$tap" | grep -c 'getText(')" -eq 0 ] && echo 0 || echo 1)" "the START sends the saved name and passphrase (savedHotspot), not the fields' text"
pin "$([ "$(printf '%s\n' "$region" | grep -c 'HotspotClient.start(')" -eq 1 ] && echo 0 || echo 1)" "one START call site"
# nothing in the screen logs, toasts or sends to the daemon the name or passphrase
bad=$(printf '%s\n' "$region" | perl -0ne 'while (/((?:Log\.|Toast\.makeText|sendDaemon\()[^;]*;)/g) { my $c = $1; print "$c\n" if $c =~ /\b(?:nameF|pwF|cfg|saved|ssid|pass|n|p)\b|\.getText\(/ }')
pin "$([ -z "$bad" ] && echo 0 || echo 1)" "no Log, Toast or sendDaemon statement in the hotspot screen names the name or passphrase"
pin "$([ "$(printf '%s\n' "$region" | grep -c 'sendDaemon(')" -eq 0 ] && echo 0 || echo 1)" "the hotspot screen sends nothing to the daemon socket"
# HotspotClient: the bind, the bounded wait, the unbind in a finally, no Log/Toast
HC="$(dirname "$PA")/HotspotClient.java"
pin "$([ -f "$HC" ] && grep -qF 'bindServiceAsUser(i, conn, Context.BIND_AUTO_CREATE, UserHandle.SYSTEM)' "$HC" && grep -qF 'up.await(BIND_WAIT_MS' "$HC" && grep -qF 'BIND_WAIT_MS = 5_000' "$HC" && grep -qF 'unbindService(conn)' "$HC" && [ "$(grep -cE 'Log\.|Toast' "$HC" || true)" -eq 0 ] && echo 0 || echo 1)" "HotspotClient binds user 0, waits 5 s, unbinds, and logs nothing"
# prefsText and prefsUpdated stay free of the hotspot (it is not a nowhere-prefs key)
for fn in 'static String prefsUpdated(' 'static String prefsText('; do
  b=$(awk -v f="$fn" 'index($0,f){on=1} on{print} on&&/^    }$/{exit}' "$PA")
  pin "$([ -n "$b" ] && ! printf '%s\n' "$b" | grep -qi 'hotspot' && echo 0 || echo 1)" "$fn... has no hotspot key"
done
[ "$fail" -eq 0 ] && { echo "hotspot pins passed"; exit 0; }
exit 1
