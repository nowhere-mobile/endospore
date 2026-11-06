#!/usr/bin/env bash
# test-owned-sims-java.sh [--mutate] -- the owned-SIM reply parse rules, run under javac (NWP-20261023-12).
#
# WHY THIS IS COMMITTED. Two chooser methods decide from a daemon reply whether a signed-in session may transmit:
# reapplyLiveTelVerdict (TEL-LIVE-OWNED: no owned SIM -> block SMS and calls, else lift and lock the SIMs) and
# lockOwnerSimsToBound (TEL-OWNED-ICCIDS at sign-in). A read cut short after the header looks like a complete answer to
# DaemonSocket.roundTripLines, and a re-verdict that wrongly blocks the owner crash-loops their Messaging. The parse now
# lives in OwnedSims.java (pure java.util), which core/chooser/tests/owned-sims/run.sh compiles and runs against
# OwnedSimsCases; the PINS below check the wiring cases cannot see: both methods read with roundTripLinesOrNull, parse
# through OwnedSims, the re-verdict returns on null before any restriction, and no log line carries the request.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (a suite that quietly passes because its tool is missing reads
# exactly like one that ran). javac comes from PATH, else from the build host's JDK below; the version is printed first.
#
#   bash test-owned-sims-java.sh            # the cases and the pins
#   bash test-owned-sims-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
PARSE="$root/core/chooser/src/com/nowhere/chooser/OwnedSims.java"
RUN="$root/core/chooser/tests/owned-sims/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl for its mutants" >&2; exit 2; }
[ -f "$SRC" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC or $RUN" >&2; exit 2; }

# body <file> <signature-substring> -> the member from its signature line to the brace that closes it
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# pins <ChooserActivity.java> -> 0 all hold, 1 one failed
pins() {
  local f="$1" b pre vis logs leak
  b=$(body "$f" 'private void reapplyLiveTelVerdict(')
  [[ "$b" == *'DaemonSocket.roundTripLinesOrNull("TEL-LIVE-OWNED'* && "$b" == *'OwnedSims.parseLive('* ]] || {
    echo "  PIN P1 reapplyLiveTelVerdict does not read with roundTripLinesOrNull and parse through OwnedSims.parseLive" >&2; return 1; }
  [[ "$b" != *'DaemonSocket.roundTripLines('* ]] || { echo "  PIN P2 reapplyLiveTelVerdict is back on roundTripLines" >&2; return 1; }
  # P3: the null return comes before the first restriction call or block
  pre=${b%%setUserRestriction*}
  [[ "$pre" != "$b" && "$pre" == *'== null'*'return;'* ]] || {
    echo "  PIN P3 reapplyLiveTelVerdict does not return on a null verdict before setUserRestriction" >&2; return 1; }
  pre=${b%%blockOutboundTelephony(*}
  [[ "$pre" != "$b" && "$pre" == *'== null'*'return;'* ]] || {
    echo "  PIN P3 reapplyLiveTelVerdict does not return on a null verdict before blockOutboundTelephony(" >&2; return 1; }
  b=$(body "$f" 'private void lockOwnerSimsToBound(')
  [[ "$b" == *'roundTripLinesOrNull("TEL-OWNED-ICCIDS'* && "$b" == *'OwnedSims.parseOwned('* ]] || {
    echo "  PIN P4 lockOwnerSimsToBound does not read with roundTripLinesOrNull and parse through OwnedSims.parseOwned" >&2; return 1; }
  [[ "$b" != *'DaemonSocket.roundTripLines('* ]] || { echo "  PIN P5 lockOwnerSimsToBound is back on roundTripLines" >&2; return 1; }
  # P6: no log line in lockOwnerSimsToBound carries the name, the passphrase or the request
  logs=$(printf '%s\n' "$b" | grep 'Log\.' || true)
  leak=$(printf '%s\n' "$logs" | grep -E '\+ *(name|pw)\b|\b(name|pw) *\+|TEL-OWNED-ICCIDS\\n"? *\+' || true)
  [ -z "$leak" ] || {
    echo "  PIN P6 a log line in lockOwnerSimsToBound concatenates the name, the passphrase or the request" >&2; return 1; }
  # P7 (NWP-20261109-23): applyOwnerSimLock decides through OwnedSims.target / stuck, with no iccEq of its own, and
  # writes the gate association only on the non-VISIBLE arm
  b=$(body "$f" 'private void applyOwnerSimLock(')
  [ "$(printf '%s\n' "$b" | grep -o 'OwnedSims\.target(' | wc -l)" -eq 1 ] || {
    echo "  PIN P7 applyOwnerSimLock does not call OwnedSims.target( exactly once" >&2; return 1; }
  [ "$(printf '%s\n' "$b" | grep -o 'OwnedSims\.stuck(' | wc -l)" -eq 1 ] || {
    echo "  PIN P7 applyOwnerSimLock does not call OwnedSims.stuck( exactly once" >&2; return 1; }
  [[ "$b" != *'iccEq('* ]] || { echo "  PIN P7 applyOwnerSimLock compares ICCIDs itself (iccEq()" >&2; return 1; }
  [ "$(printf '%s\n' "$b" | grep -o 'setSubscriptionUserHandle(sub, gate)' | wc -l)" -eq 1 ] || {
    echo "  PIN P7 applyOwnerSimLock does not write setSubscriptionUserHandle(sub, gate) exactly once" >&2; return 1; }
  pre=${b%%'if (tgt == OwnedSims.VISIBLE) {'*}
  [[ "$pre" != "$b" ]] || { echo "  PIN P7 applyOwnerSimLock has no 'if (tgt == OwnedSims.VISIBLE) {' arm" >&2; return 1; }
  pre=${b#*'if (tgt == OwnedSims.VISIBLE) {'}
  vis=${pre%%'} else {'*}
  [[ "$pre" != "$vis" && "$vis" != *'(sub, gate)'* && "${pre#*'} else {'}" == *'setSubscriptionUserHandle(sub, gate)'* ]] || {
    echo "  PIN P7 setSubscriptionUserHandle(sub, gate) is not only on the non-VISIBLE arm" >&2; return 1; }
  return 0
}

# suite <ChooserActivity.java> <OwnedSims.java> -> 0 pass, 1 a case or a pin failed, 2 the source is missing, 3 it did
# not compile. Only 1 may convict a mutant.
suite() {
  pins "$1" || return 1
  bash "$RUN" "$2" "$W"
}

echo "== $SRC"
suite "$SRC" "$PARSE" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- by behaviour or a pin: a mutant that does not apply or compile proves nothing)"
# mut <label> <which: parse|activity> <perl-expr>
mut() {
  local d m rc a p src; d=$(mktemp -d -p "$W"); a="$SRC"; p="$PARSE"
  if [ "$2" = parse ]; then m="$d/OwnedSims.java"; p="$m"; src="$PARSE"; else m="$d/ChooserActivity.java"; a="$m"; src="$SRC"; fi
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$a" "$p" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not apply or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 parseLive accepts uid 0"                  parse    's/if \(uid <= 0\) return null;/if (uid < 0) return null;/' || fails=$((fails+1))
mut "M2 parseLive returns an empty Live for null" parse    's/(static Live parseLive\(java\.util\.List<String> lines\) \{\n\s*)if \(lines == null \|\| lines\.isEmpty\(\)\) return null;/$1if (lines == null) return new Live(0, new java.util.LinkedHashSet<>());\n        if (lines.isEmpty()) return null;/' || fails=$((fails+1))
mut "M3 parseOwned keeps OK lines"                parse    's/ && !"OK"\.equals\(l\)//' || fails=$((fails+1))
mut "M4 parseOwned header only starts with OK"    parse    's/if \(!head\.equals\("OK"\)\) return null;/if (!head.startsWith("OK")) return null;/' || fails=$((fails+1))
mut "M5 reapplyLiveTelVerdict on roundTripLines"  activity 's/roundTripLinesOrNull\("TEL-LIVE-OWNED/roundTripLines("TEL-LIVE-OWNED/' || fails=$((fails+1))
mut "M6 the null check moves after the block"     activity 's/(            if \(v == null\) \{\n.*?\n                return;\n            \}\n)(.*?)(            android\.util\.Log\.i\("NowhereChooser", "re-verdict user )/$2$1$3/s' || fails=$((fails+1))
mut "S1 target compares with equals, not iccEq"  parse    's/BindFormFields\.iccEq\(o, iccid\)/o.equals(iccid)/' || fails=$((fails+1))
mut "S2 an unreadable ICCID is HIDE"              parse    's/(iccid\.trim\(\)\.isEmpty\(\)\) return )SKIP;/$1HIDE;/' || fails=$((fails+1))
mut "S3 a foreign SIM is VISIBLE"                 parse    's/(iccEq\(o, iccid\)\) return VISIBLE;\n\s*)return HIDE;/$1return VISIBLE;/' || fails=$((fails+1))
mut "S4 stuck(HIDE) accepts any non-null handle"  parse    's/handleUserId != null && handleUserId == 0/handleUserId != null/' || fails=$((fails+1))
mut "S5 stuck(VISIBLE) is inverted"               parse    's/(target == VISIBLE\) return handleUserId) == null;/$1 != null;/' || fails=$((fails+1))
mut "S6 applyOwnerSimLock hides on VISIBLE"       activity 's/if \(tgt == OwnedSims\.VISIBLE\) \{/if (tgt != OwnedSims.VISIBLE) {/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
