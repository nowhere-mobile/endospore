#!/usr/bin/env bash
# run.sh <NetPolicyWifi.java> <NetPolicyReceiver.java> <AndroidManifest.xml>   (NWP-20261210-17)
# Compiles NetPolicyWifi.java against NetPolicyWifiCases and runs P1-P6, then pins the receiver and the manifest as
# data (G1-G8 plus the contract pins X1-X6). The pins run even when the compile fails, so a baseline run names every
# failing assertion. Exit: 0 pass, 1 a case or pin failed (the only code that convicts a mutant), 2 a file is missing,
# 3 the pure class did not compile or run.
set -uo pipefail
PW="${1:-}"; RC="${2:-}"; MF="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
for f in "$PW" "$RC" "$MF" "$HERE/NetPolicyWifiCases.java"; do
  [ -f "$f" ] || { echo "FAIL: missing ${f:-<unset>}" >&2; exit 2; }
done
if [ -z "${W:-}" ]; then W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT; fi
: "${JAVAC:=javac}" "${JAVA:=java}"
D=$(mktemp -d -p "$W") || exit 2
mkdir -p "$D/src/com/nowhere/chooser" "$D/out"
cp "$PW" "$D/src/com/nowhere/chooser/NetPolicyWifi.java"
cp "$HERE/NetPolicyWifiCases.java" "$D/src/com/nowhere/chooser/NetPolicyWifiCases.java"
broken=0; fail=0
if "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$D/out" "$D"/src/com/nowhere/chooser/*.java; then
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.NetPolicyWifiCases
  rc=$?
  case "$rc" in 0) ;; 1) fail=1 ;; *) echo "--- BROKEN: the cases did not run (rc=$rc)"; broken=1 ;; esac
else
  echo "--- BROKEN: NetPolicyWifi.java does not compile against NetPolicyWifiCases (P1-P6 cannot run)"; broken=1
fi

pin() { # pin <ok 0/1> <case> <what>
  if [ "$1" -eq 0 ]; then echo "  pin ok: $2: $3"; else echo "--- FAIL: $2: $3"; fail=1; fi
}
count() { grep -cF -- "$2" "$1" || true; }
# The Java with its comments blanked (line numbers kept), so a comment can neither satisfy nor trip a code pin.
strip() { perl -0pe 's{/\*.*?\*/}{ (my $c = $&) =~ s/[^\n]//g; $c }gse; s{//[^\n]*}{}g' "$1"; }
PWC="$D/pw.code"; RCC="$D/rc.code"
strip "$PW" > "$PWC"; strip "$RC" > "$RCC"
ln() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }

# G1. the permission, declared once
pin "$([ "$(count "$MF" 'android.permission.MANAGE_NETWORK_POLICY')" -eq 1 ] && [ "$(count "$MF" '<uses-permission android:name="android.permission.MANAGE_NETWORK_POLICY"/>')" -eq 1 ] && echo 0 || echo 1)" G1 "MANAGE_NETWORK_POLICY declared exactly once"
# G2. the receiver, unexported, no intent-filter (the self-closing element cannot hold one)
pin "$([ "$(count "$MF" '".NetPolicyReceiver"')" -eq 1 ] && [ "$(count "$MF" '<receiver android:name=".NetPolicyReceiver" android:exported="false"/>')" -eq 1 ] && echo 0 || echo 1)" G2 "NetPolicyReceiver declared once, not exported, no intent-filter"
# G3. one write, only under the removed > 0 guard, and removed is NetPolicyWifi.removed's, assigned once
pin "$([ "$(count "$RCC" 'setNetworkPolicies(')" -eq 1 ] \
  && grep -qE '^ *if \(removed > 0\) npm\.setNetworkPolicies\(kept\.toArray\(new NetworkPolicy\[0\]\)\);$' "$RCC" \
  && [ "$(count "$RCC" 'int removed = NetPolicyWifi.removed(keep);')" -eq 1 ] \
  && [ "$(grep -cE '\bremoved *[-+*/]?= *[^=]' "$RCC" || true)" -eq 1 ] && echo 0 || echo 1)" G3 "setNetworkPolicies runs once, only when removed > 0"
# G4. the user-0 refusal, answered and returned, before any policy read and before goAsync
u0=$(grep -n '^ *if (UserHandle\.myUserId() != 0) {$' "$RCC" | head -1 | cut -d: -f1)
gp=$(ln "$RCC" 'getNetworkPolicies('); ga=$(ln "$RCC" 'goAsync()')
pin "$([ -n "$u0" ] && [ -n "$gp" ] && [ -n "$ga" ] && [ "$u0" -lt "$gp" ] && [ "$u0" -lt "$ga" ] \
  && sed -n "$((u0+1))p" "$RCC" | grep -qF 'setResultData(NetPolicyWifi.errLine(NetPolicyWifi.R_USER));' \
  && sed -n "$((u0+2))p" "$RCC" | grep -qE '^ *return;$' && echo 0 || echo 1)" G4 "the user-0 refusal (ERR-NP user) precedes goAsync and getNetworkPolicies"
# G5. the filter is NetPolicyWifi.keep over the match rules, and only kept policies are written
pin "$([ "$(count "$RCC" 'boolean[] keep = NetPolicyWifi.keep(rules, wifiRules());')" -eq 1 ] \
  && [ "$(count "$RCC" 'all[i].template.getMatchRule()')" -eq 1 ] \
  && [ "$(count "$RCC" 'if (keep[i] && all[i] != null) kept.add(all[i]);')" -eq 1 ] \
  && [ "$(count "$RCC" 'kept.add(')" -eq 1 ] && echo 0 || echo 1)" G5 "the filter goes through NetPolicyWifi.keep"
# G6. no Log or println statement names a template, network id/key, SSID or subscriber id; the one log is the reply
for f in "$PW" "$RC"; do
  bad=$(perl -0ne 'while (/((?:\bLog\s*\.\s*\w+|\bprintln|\bprintf|\bprint)\s*\((?:[^;"]|"(?:[^"\\]|\\.)*")*;)/g) { my $c = $1; print "$c\n" if $c =~ /template|networkId|wifiNetworkKey|ssid|subscriberId/i }' "$f")
  pin "$([ -z "$bad" ] && echo 0 || echo 1)" G6 "$(basename "$f"): no Log/println names template, networkId, wifiNetworkKey, ssid or subscriberId"
done
pin "$([ "$(grep -cE '\bLog\s*\.' "$RCC" || true)" -eq 1 ] && [ "$(count "$RCC" 'Log.i(TAG, "netpolicy wifi reset: " + line);')" -eq 1 ] && echo 0 || echo 1)" G6 "the receiver's one log line is the reply line"
# G7. no file path, no WifiConfigStore
for f in "$PW" "$RC"; do
  pin "$([ "$(grep -cE 'WifiConfigStore|/data' "$f" || true)" -eq 0 ] && echo 0 || echo 1)" G7 "$(basename "$f") names no WifiConfigStore and no /data path"
done
# G8. per-uid background policy stays: none of its setters is called
for f in "$PWC" "$RCC"; do
  pin "$([ "$(grep -cE '\b(setUidPolicy|addUidPolicy|removeUidPolicy|setRestrictBackground)\b' "$f" || true)" -eq 0 ] && echo 0 || echo 1)" G8 "$( [ "$f" = "$PWC" ] && echo NetPolicyWifi.java || echo NetPolicyReceiver.java) calls no per-uid or background-restriction setter"
done
# X1. the pure file stays pure
pin "$([ "$(grep -cE '^import android|android\.' "$PWC" || true)" -eq 0 ] && echo 0 || echo 1)" X1 "NetPolicyWifi.java names nothing from the platform"
# X2. the action gate and the async result, finished in a finally on the receiver's own single-thread executor
pin "$([ "$(count "$RCC" '!NetPolicyWifi.ACTION_RESET.equals(intent.getAction())) return;')" -eq 1 ] \
  && [ "$(count "$RCC" 'Executors.newSingleThreadExecutor()')" -eq 1 ] \
  && awk '/} finally {/{on=1} on' "$RCC" | grep -qF 'pr.setResultData(line);' \
  && awk '/} finally {/{on=1} on' "$RCC" | grep -qF 'pr.finish();' && echo 0 || echo 1)" X2 "action-gated, goAsync, result set and finished in a finally, own executor"
# X3. the exception map
pin "$(grep -A1 'catch (SecurityException e) {' "$RCC" | grep -qF 'NetPolicyWifi.errLine(NetPolicyWifi.R_DENIED)' \
  && grep -A1 'catch (Throwable e) {' "$RCC" | grep -qF 'NetPolicyWifi.errLine(NetPolicyWifi.R_FAILED)' && echo 0 || echo 1)" X3 "SecurityException is ERR-NP denied, any other Throwable ERR-NP failed"
# X4. the service lookup, and a null service is ERR-NP noservice
pin "$(grep -qF 'NetworkPolicyManager npm = NetworkPolicyManager.from(ctx);' "$RCC" \
  && grep -qF 'if (npm == null) return NetPolicyWifi.errLine(NetPolicyWifi.R_NOSERVICE);' "$RCC" && echo 0 || echo 1)" X4 "NetworkPolicyManager.from; null is ERR-NP noservice"
# X5. MATCH_WIFI plus the reflected MATCH_WIFI_WILDCARD, whose absence (only NoSuchFieldException) is skipped
pin "$(grep -qF 'getField("MATCH_WIFI_WILDCARD").getInt(null)' "$RCC" && grep -qF 'catch (NoSuchFieldException absent) {' "$RCC" \
  && [ "$(count "$RCC" 'NetworkTemplate.MATCH_WIFI}')" -eq 1 ] && [ "$(count "$RCC" '{NetworkTemplate.MATCH_WIFI, wildcard}')" -eq 1 ] && echo 0 || echo 1)" X5 "Wi-Fi rules: MATCH_WIFI plus a reflected MATCH_WIFI_WILDCARD when present"
# X6. the reply is NetPolicyWifi.reply's
pin "$([ "$(count "$RCC" 'return NetPolicyWifi.reply(removed);')" -eq 1 ] && echo 0 || echo 1)" X6 "the reply is NetPolicyWifi.reply(removed)"

[ "$broken" -eq 1 ] && exit 3
[ "$fail" -eq 0 ] && { echo "netpolicy wifi pins passed"; exit 0; }
exit 1
