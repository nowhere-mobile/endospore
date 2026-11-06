#!/usr/bin/env bash
# run.sh <ChooserActivity.java> -- NWP-20261010-16: lift the gate's pure create-over-cold-lock helpers out of the
# chooser and run CreateColdLockCases against them under plain javac/java. Every helper listed is private static and
# uses only java.lang, so the lifted class compiles with no Android SDK. The same file supplies the reply prefixes its
# create branch tests and the wiring the cases check. JAVAC and JAVA name the tools (default: javac, java on PATH);
# core/vendor-common/bin/test-create-coldlock-java.sh resolves them and is what CI runs.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ChooserActivity.java}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
methods="parseColdLock createRefusedForColdLock createReplyColdLocked createOverColdLockTitle createOverColdLockText"
{
  echo "final class Lifted {"
  for m in $methods; do
    # from the method's signature line to the brace that closes it
    awk -v m="$m" '
      !on && index($0, "private static ") && index($0, " " m "(") { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$SRC" | sed 's/private static/static/'
  done
  echo "}"
} > "$D/Lifted.java"
for m in $methods; do grep -q " $m(" "$D/Lifted.java" || { echo "extraction missed $m" >&2; exit 2; }; done
# The create branch's reply prefixes: every cr.startsWith("...") between the CREATE send and the recovery parse.
mapfile -t prefixes < <(awk '/String cr = code.isEmpty\(\)/{on=1} on{print} /String rec = parseRecovery\(cr\)/{exit}' "$SRC" \
  | grep -o 'cr\.startsWith("[^"]*")' | sed 's/^cr\.startsWith("//; s/")$//' | sort -u)
[ "${#prefixes[@]}" -gt 3 ] || { echo "found only ${#prefixes[@]} create-reply prefixes in $SRC" >&2; exit 2; }
echo "create-reply prefixes: ${prefixes[*]}"
cp "$here/CreateColdLockCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/CreateColdLockCases.java"
"$JAVA" -cp "$D" CreateColdLockCases "$SRC" "${prefixes[@]}"
