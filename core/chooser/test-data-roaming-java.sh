#!/usr/bin/env bash
# test-data-roaming-java.sh [--mutate] -- the gate's data-roaming receiver, run under javac (NWP-20261028-06).
#
# WHY THIS IS COMMITTED. The global data_roaming settings key is inert, so roamd asks the gate's chooser to write
# through TelephonyManager.setDataRoamingEnabled and parses one result line (docs/product-decisions.md, 2026-10-19).
# DataRoaming.java decides that line and is pure Java, so core/chooser/tests/data-roaming/run.sh compiles it directly
# and runs DataRoamingCases; the PINS below check the receiver glue (which javac does not compile here) and the
# manifest entry by anchor: the user-0 guard, the set-only write, the read-back loop bounded by readBackDone, the
# finally-delivered result, no global settings key, and a non-exported receiver without an intent-filter.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK.
#
#   bash test-data-roaming-java.sh            # the cases and the pins
#   bash test-data-roaming-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
DR="$DIR/DataRoaming.java"
RX="$DIR/DataRoamingReceiver.java"
MF="$root/core/chooser/AndroidManifest.xml"
RUN="$root/core/chooser/tests/data-roaming/run.sh"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl" >&2; exit 2; }
[ -f "$RUN" ] && [ -f "$MF" ] || { echo "FAIL: missing $RUN or $MF" >&2; exit 2; }

# pin <file> <label> <perl-regex>: a textual check on the source (anchors, not line numbers).
pin() {
  perl -0ne "exit(/$3/s ? 0 : 1)" "$1" || { echo "  PIN   $2" >&2; return 1; }
}

# absent <file> <label> <fixed-string>: the file must not contain the string.
absent() {
  local hit
  hit=$(grep -F -e "$3" "$1" || true)
  [ -z "$hit" ] || { echo "  PIN   $2" >&2; return 1; }
}

# suite <DataRoaming.java> <DataRoamingReceiver.java> <AndroidManifest.xml> -> 0 pass, 1 a case or a pin failed, 3 compile.
suite() {
  local dr="$1" rx="$2" mf="$3"
  [ -f "$dr" ] || { echo "  PIN   DataRoaming.java does not exist" >&2; return 1; }
  [ -f "$rx" ] || { echo "  PIN   DataRoamingReceiver.java does not exist" >&2; return 1; }
  pin "$rx" "onReceive does not open with the user-0 guard answering ERR-DR user" \
    'public void onReceive\(Context [a-z]+, Intent [a-z]+\) \{\s*if \(android\.os\.UserHandle\.myUserId\(\) != 0\) \{[^}]*DataRoaming\.errLine\("user"\)[^}]*return;' || return 1
  pin "$rx" "a telephony call or goAsync() comes before the user-0 guard" \
    'public void onReceive\(.*?\{(?:(?!getSystemService\(|setDataRoamingEnabled|getActiveSubscriptionInfo|goAsync\(\)).)*?UserHandle\.myUserId\(\) != 0' || return 1
  local n
  n=$(grep -c 'setDataRoamingEnabled(' "$rx")
  [ "$n" = 1 ] || { echo "  PIN   setDataRoamingEnabled is called $n times, not once" >&2; return 1; }
  pin "$rx" "setDataRoamingEnabled is not the first statement of the set branch's try" \
    'if \(isSet\) \{\s*try \{\s*TelephonyManager tm = [^\n]*\n\s*tm\.setDataRoamingEnabled\(value == 1\);' || return 1
  local loop
  loop=$(perl -0ne 'print $1 if /(while \(true\) \{.*?SystemClock\.sleep\(DataRoaming\.READBACK_STEP_MS\);\s*\})/s' "$rx")
  case "$loop" in *"getActiveSubscriptionInfo(sub)"*) ;; *) echo "  PIN   the read-back loop does not read the subscription" >&2; return 1 ;; esac
  case "$loop" in *"info.getDataRoaming() == SubscriptionManager.DATA_ROAMING_ENABLE"*) ;; *) echo "  PIN   the read-back loop does not read siminfo's getDataRoaming()" >&2; return 1 ;; esac
  case "$loop" in *"if (DataRoaming.readBackDone(isSet, value, seen, "*") break;"*) ;; *) echo "  PIN   the read-back loop does not stop through readBackDone" >&2; return 1 ;; esac
  pin "$rx" "the PendingResult is not finished in a finally" \
    '\} finally \{\s*pending\.setResult\(Activity\.RESULT_OK, line, null\);\s*pending\.finish\(\);' || return 1
  absent "$rx" "the receiver sets a result on itself after goAsync" "setResultCode(" || return 1
  absent "$rx" "the receiver sets a result on itself after goAsync" "setResultData(" || return 1
  for f in "$dr" "$rx"; do
    absent "$f" "$(basename "$f") touches the global settings class" "Settings.Global" || return 1
    absent "$f" "$(basename "$f") names the global data_roaming key" '"data_roaming' || return 1
  done
  absent "$dr" "DataRoaming.java is not pure Java" "import android." || return 1
  n=$(grep -c '\.DataRoamingReceiver"' "$mf")
  [ "$n" = 1 ] || { echo "  PIN   the manifest names .DataRoamingReceiver $n times, not once" >&2; return 1; }
  pin "$mf" "the manifest entry is not a self-closing, non-exported receiver" \
    '<receiver android:name="\.DataRoamingReceiver" android:exported="false"\/>' || return 1
  bash "$RUN" "$dr"
}

echo "== $DR"
suite "$DR" "$RX" "$MF" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not apply or compile proves nothing)"
# mut <label> <which: dr|rx|mf> <perl-expr>
mut() {
  local d drf rxf mff src m rc
  d=$(mktemp -d -p "$W") || return 1
  drf="$DR"; rxf="$RX"; mff="$MF"
  case "$2" in
    dr) src="$DR"; drf="$d/DataRoaming.java" ;;
    rx) src="$RX"; rxf="$d/DataRoamingReceiver.java" ;;
    mf) src="$MF"; mff="$d/AndroidManifest.xml" ;;
  esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$drf" "$rxf" "$mff" > "$d/out" 2>&1; rc=$?
  case "$rc" in
    1) echo "  convicted $1" ;;
    0) echo "  SURVIVED  $1"; rm -rf "$d"; return 1 ;;
    *) echo "  BROKEN    $1 -- exit $rc, not a conviction"; sed 's/^/      /' "$d/out"; rm -rf "$d"; return 1 ;;
  esac
  rm -rf "$d"
}

fails=0
mut "Q1 parseOp accepts set with value 2" dr 's/\(value == 0 \|\| value == 1\)/(value >= 0 && value <= 2)/' || fails=$((fails+1))
mut "Q2 pickSub keeps a non-positive extra" dr 's/if \(extraSub > 0\) return extraSub;/if (extraSub != -1) return extraSub;/' || fails=$((fails+1))
mut "Q3 errLine passes an unlisted reason through" dr 's/return "ERR-DR failed";/return "ERR-DR " + reason;/' || fails=$((fails+1))
mut "Q4 the user-0 guard removed" rx 's/if \(android\.os\.UserHandle\.myUserId\(\) != 0\) \{[^}]*\}\n//' || fails=$((fails+1))
mut "Q5 the read-back from the global key" rx 's/info\.getDataRoaming\(\) == SubscriptionManager\.DATA_ROAMING_ENABLE/android.provider.Settings.Global.getInt(app.getContentResolver(), "data_roaming" + sub, 0) == 1/' || fails=$((fails+1))
mut "Q6 the receiver exported" mf 's/(\.DataRoamingReceiver" android:exported=)"false"/$1"true"/' || fails=$((fails+1))
mut "Q7 readBackDone stops at once on a set whose read differs" dr 's/elapsedMs >= READBACK_MS;/elapsedMs >= 0;/' || fails=$((fails+1))
mut "Q8 the loop no longer asks readBackDone" rx 's/if \(DataRoaming\.readBackDone\([^\n]*\)\) break;/if (seen >= 0) break;/' || fails=$((fails+1))
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "== all mutations convicted"
