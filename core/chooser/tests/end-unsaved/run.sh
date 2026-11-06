#!/usr/bin/env bash
# run.sh <ProfileActivity.java> <ChooserActivity.java> -- NWP-20261010-10: lift the pure sign-out-refusal helpers out of
# the chooser and run EndUnsavedCases against them under plain javac/java. NWP-20261013-20 adds the gate's lost-credit
# notice helpers from ChooserActivity.java, lifted into a second class (GateLifted) the same way. Every helper listed
# is private static and uses only java.lang / java.util, so the class compiles with no Android SDK. The compiler and VM come from $JAVAC / $JAVA (default: PATH);
# core/vendor-common/bin/test-end-unsaved-java.sh is the CI entry point and finds them.
#
# Exit codes, so a caller can tell a behaviour failure from a broken run: 1 = a case failed; 2 = a helper the list
# names is missing from the source (never a silent skip: the cases would run against a class missing the very method
# they exist for); 3 = the lifted class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ProfileActivity.java path/to/ChooserActivity.java}"
GATE="${2:?usage: run.sh path/to/ProfileActivity.java path/to/ChooserActivity.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
methods="logoffFailMessage sealReasonOf refusalFinal offerEndUnsaved refusalRestSaved refusalScopes refusalNames parseUnix joinAnd
refusalDeleted guardFinal blockingScope refusalScopeLabel useBlindDialog blindRestSaved refusalCause endUnsavedConfirmText
endUnsavedReplyMessage endUnsavedMayRetry sealScopeLabel mediaStuckCount failedDialogExit discardText
restartUnsavedConfirmText restartUnsavedReplyMessage restartWatchAction restartFailedMessage restartUnknownMessage
claimFailMessage creditLostWarning pushStuckCount endUnsavedOfflineText adoptFailMessage lastSaveHeldText"
gatemethods="creditLostNoticeStamp creditLostNoticeDue creditLostClearCommand creditLostNoticeText"
lift() { # lift <class> <source> <methods...>
  local cls="$1" src="$2" m; shift 2
  echo "final class $cls {"
  for m in "$@"; do
    # from the method's signature line to the brace that closes it
    awk -v m="$m" '
      !on && index($0, "private static ") && index($0, " " m "(") { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$src" | sed 's/private static/static/'
  done
  echo "}"
}
# shellcheck disable=SC2086 # the method lists are word lists
lift Lifted "$SRC" $methods > "$D/Lifted.java"
# shellcheck disable=SC2086
lift GateLifted "$GATE" $gatemethods > "$D/GateLifted.java"
for m in $methods; do grep -q " $m(" "$D/Lifted.java" || { echo "extraction missed $m" >&2; exit 2; }; done
for m in $gatemethods; do grep -q " $m(" "$D/GateLifted.java" || { echo "extraction missed $m" >&2; exit 2; }; done
cp "$here/EndUnsavedCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/GateLifted.java" "$D/EndUnsavedCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -cp "$D" EndUnsavedCases
