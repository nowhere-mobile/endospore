#!/usr/bin/env bash
# run.sh <chooser dir> -- NWP-20261010-13: run SmsNoticeCases against the chooser's message-notice and SMS-role code
# under plain javac/java. core/vendor-common/bin/test-sms-notice-java.sh resolves the JDK and is what CI runs.
#
# Two kinds of check. The pure decisions (each static, using only java.lang / java.util) are LIFTED BY NAME from the
# real sources into one class and EXECUTED by the cases; a helper that is missing, or found twice, stops the run rather
# than a stale copy passing. The wiring around them -- the call sites, the notice builder, the listener lifecycle, the
# role kick and its repair -- cannot run without Android, so each is PINNED byte for byte: pins/<Class>.<name>.txt
# holds the block, and a deliberate edit updates its pin in the same change (a failure names the first line that
# differs). The pins are edited by hand, never regenerated to make a failure go away.
#
# JAVAC and JAVA name the tools (default: javac, java on PATH). Exit status: 0 every case passed; 1 a case failed;
# 2 cannot run (a tool, a file or a helper missing); 3 the lifted helpers do not compile. --mutate counts only a 1.
set -uo pipefail
CH="${1:?usage: run.sh <core/chooser dir>}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
J="$CH/src/com/nowhere/chooser"
srcs=("$J/TelIngest.java" "$J/MessagingSuppressor.java" "$J/ChooserActivity.java" "$J/SmsDeliverReceiver.java" "$J/SmsRoleRoam.java")
manifest="$CH/AndroidManifest.xml"
for f in "${srcs[@]}" "$manifest" "$here/SmsNoticeCases.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
[ -d "$here/pins" ] || { echo "run.sh: no pins dir: $here/pins" >&2; exit 2; }
command -v "$JAVAC" >/dev/null 2>&1 && command -v "$JAVA" >/dev/null 2>&1   || { echo "run.sh: FAIL -- no javac/java ($JAVAC, $JAVA); this suite does not skip" >&2; exit 2; }

methods="noticeTag noticeRow rowQuery rowState noticeAction noticeActions mmsKey messageTapPackage messageTapAction
  sweepDelay nextIdleResweeps resweepDelay roamedSmsComponents substituteAppName
  isPackageName parseSmsRecord recordUnknown markerText parseMarker smsSignInPlan smsCaptureValue takeOverFromStandIn roleHeldBy smsRoleStep
  standInState repairStillValid materialiseTarget retryRefusedTarget takeoverStep"
consts="ROW_BLIND ROW_GONE NOTICE_CLEAR NOTICE_POLL NOTICE_KEEP GONE_GRACE_MS SMS_REPAIR_DELAY_MS"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
{
  echo "final class Lifted {"
  for k in $consts; do
    for f in "${srcs[@]}"; do
      grep -E "^[ \t]*(private )?static final [A-Za-z]+ $k = [^;]*;" "$f" | sed -E 's/^([ \t]*)(private )?static /\1static /'
    done
  done
  for m in $methods; do
    for f in "${srcs[@]}"; do
      # from the method's declaration (optional modifier, then 'static' -- never a call site) to the brace closing it
      awk -v m="$m" '
        !on && $0 ~ ("^[ \t]*(private |public )?static [^=;]* " m "\\(") { on=1; depth=0 }
        on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
      ' "$f" | sed -E 's/^([ \t]*)(private |public )?static /\1static /'
    done
  done
  echo "}"
} > "$D/Lifted.java"
for k in $consts; do
  n=$(grep -cE "^[ \t]*static final [A-Za-z]+ $k = " "$D/Lifted.java" || true)
  [ "$n" = 1 ] || { echo "run.sh: constant $k found $n time(s), want 1" >&2; exit 2; }
done
for m in $methods; do
  n=$(grep -cE "^[ \t]*static [^=;]* $m\(" "$D/Lifted.java" || true)
  [ "$n" = 1 ] || { echo "run.sh: helper $m found $n time(s), want 1" >&2; exit 2; }
done
cp "$here/SmsNoticeCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/SmsNoticeCases.java" || { echo "run.sh: the lifted helpers do not compile" >&2; exit 3; }
"$JAVA" -cp "$D" SmsNoticeCases "$manifest" "$J" "$here/pins"
