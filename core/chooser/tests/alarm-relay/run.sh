#!/usr/bin/env bash
# run.sh <CredentialService.java> <ProfileActivity.java> -- NWP-20261011-04: lift CredentialService.alarmRelayLine and relayLanded (pure,
# java.lang/java.util only) into a plain class and run AlarmRelayCases against it and against both relays' wiring. JAVAC and JAVA
# name the tools (default: javac, java on PATH); core/vendor-common/bin/test-alarm-relay-java.sh resolves them and is what
# CI runs. Exit 2 means the helper did not extract, 3 that the lifted class did not compile: neither proves anything about
# the logic.
set -uo pipefail
CS="${1:?usage: run.sh CredentialService.java ProfileActivity.java}"; PA="${2:?}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
{
  echo "final class Lifted {"
  for sig in "static String alarmRelayLine(" "static boolean relayLanded("; do
    awk -v sig="$sig" '
      !on && index($0, sig) { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$CS"
  done
  echo "}"
} > "$D/Lifted.java"
grep -q "alarmRelayLine(" "$D/Lifted.java" || { echo "extraction missed alarmRelayLine" >&2; exit 2; }
grep -q "static boolean relayLanded(" "$D/Lifted.java" || { echo "extraction missed relayLanded" >&2; exit 2; }
cp "$here/AlarmRelayCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/AlarmRelayCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D" AlarmRelayCases "$CS" "$PA"
