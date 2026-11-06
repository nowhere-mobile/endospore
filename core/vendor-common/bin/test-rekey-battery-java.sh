#!/usr/bin/env bash
# test-rekey-battery-java.sh [--mutate] -- the background re-key's battery rule, run under javac (NWP-20261110-23).
#
# WHY THIS IS COMMITTED. The tie job's re-key pauses while the battery is under 20% and not charging (Chester,
# 2026-10-08; docs/product-decisions.md, the tie decision's "Battery" bullet). "Charging" is the battery status
# CHARGING or FULL, not plugged in (#65, 2026-10-22, NWP-20261117-19). The rule lives in RekeyBattery (java.* only)
# and is compiled here with its cases; source checks on the real ChooserActivity.java (comments stripped) pin that
# batteryAllowsRekey reads EXTRA_STATUS (default UNKNOWN), never EXTRA_PLUGGED, hands the sticky broadcast's values
# to RekeyBattery, keeps its null-intent false, and that the call site core/agent/tie_progress_test.go pins is still
# there verbatim.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS.
#
#   bash test-rekey-battery-java.sh            # the cases and the source checks
#   bash test-rekey-battery-java.sh --mutate  # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="${REKEY_BATTERY_SRC:-$SRC/RekeyBattery.java}"
CHOOSER="$SRC/ChooserActivity.java"
PIN="$root/core/agent/tie_progress_test.go"
CASES="$root/core/chooser/tests/rekey-battery/RekeyBatteryCases.java"
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
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# suite <RekeyBattery.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  RekeyBattery.java does not exist (the rule is not lifted)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/RekeyBattery.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/RekeyBatteryCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.RekeyBatteryCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# strip_comments <file> -> the Java source on stdout with // and /* */ comments removed (string and char literals kept).
strip_comments() {
  perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : " "}gse' "$1"
}

# source_check <ChooserActivity.java> <tie_progress_test.go> -> 0 when the wiring holds, 1 otherwise.
source_check() {
  local chooser="$1" pin="$2" code body line bad=0
  command -v perl >/dev/null 2>&1 || { echo "  FAIL  no perl: the comment-stripped source checks cannot run" >&2; return 1; }
  code=$(strip_comments "$chooser") || { echo "  FAIL  could not strip comments from $chooser" >&2; return 1; }
  body=$(printf '%s\n' "$code" | awk '/static boolean batteryAllowsRekey\(Context ctx\)/ { on = 1 } on { print } on && /^    }$/ { exit }')
  if [ -z "$body" ]; then echo "  FAIL  batteryAllowsRekey not found in $chooser" >&2; return 1; fi
  grep -qF 'return RekeyBattery.allows(level, scale, status);' <<<"$body" \
    || { echo "  FAIL  S1 batteryAllowsRekey does not return RekeyBattery.allows(level, scale, status)" >&2; bad=1; }
  grep -qF 'int status = b.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, android.os.BatteryManager.BATTERY_STATUS_UNKNOWN);' <<<"$body" \
    || { echo "  FAIL  S1 batteryAllowsRekey does not read EXTRA_STATUS with the UNKNOWN default" >&2; bad=1; }
  if grep -qF 'EXTRA_PLUGGED' <<<"$body"; then echo "  FAIL  S1 batteryAllowsRekey still reads EXTRA_PLUGGED" >&2; bad=1; fi
  grep -qF 'if (b == null) return false;' <<<"$body" \
    || { echo "  FAIL  S1 batteryAllowsRekey lost its null-intent false" >&2; bad=1; }
  grep -qF 'ACTION_BATTERY_CHANGED' <<<"$body" \
    || { echo "  FAIL  S1 batteryAllowsRekey no longer reads the sticky battery broadcast" >&2; bad=1; }
  line=': batteryAllowsRekey(app) ? "REKEY-ARM" : "REKEY-WAIT-BATTERY";'
  grep -qF -e "$line" "$pin" || { echo "  FAIL  S2 $pin lost its pinned call-site line" >&2; bad=1; }
  grep -qF -e "$line" <<<"$code" || { echo "  FAIL  S2 ChooserActivity.java lost the call-site line the agent pins" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
source_check "$CHOOSER" "$PIN" || { echo "FAILED (source)"; exit 1; }
echo "source: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates RekeyBattery.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/RekeyBattery.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutsrc() { # mutsrc <label> <perl-expr>   (mutates ChooserActivity.java; the source check must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$CHOOSER" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$CHOOSER" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  source_check "$c" "$PIN" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "M1 MIN_PCT 21" 's/MIN_PCT = 20/MIN_PCT = 21/' || fails=$((fails+1))
mut "M2 > for >=" 's/>= MIN_PCT/> MIN_PCT/' || fails=$((fails+1))
mut "M3 the CHARGING/FULL branch removed" 's/if \(status == STATUS_CHARGING \|\| status == STATUS_FULL\) return true;//' || fails=$((fails+1))
mut "M4 the scale check removed" 's/ && scale > 0//' || fails=$((fails+1))
mutsrc "M5 true on a null intent" 's/if \(b == null\) return false;/if (b == null) return true;/' || fails=$((fails+1))
mutsrc "M6 the null guard only inside a block comment" 's/if \(b == null\) return false;/\/* if (b == null) return false; *\/ if (b == null) return true;/' || fails=$((fails+1))
mutsrc "M7 the delegation only inside a line comment" 's/return RekeyBattery\.allows\(level, scale, status\);/return true; \/\/ return RekeyBattery.allows(level, scale, status);/' || fails=$((fails+1))
mutsrc "M8 the call site only inside a block comment" 's/(: batteryAllowsRekey\(app\) \? "REKEY-ARM" : "REKEY-WAIT-BATTERY";)/: true; \/* $1 *\//' || fails=$((fails+1))
mut "M9 FULL dropped" 's/ \|\| status == STATUS_FULL\)/)/' || fails=$((fails+1))
mut "M10 NOT_CHARGING counted as charging" 's/status == STATUS_FULL\)/status == STATUS_FULL || status == 4)/' || fails=$((fails+1))
mutsrc "M11 EXTRA_PLUGGED read back in place of EXTRA_STATUS" 's/android\.os\.BatteryManager\.EXTRA_STATUS, android\.os\.BatteryManager\.BATTERY_STATUS_UNKNOWN/android.os.BatteryManager.EXTRA_PLUGGED, 0/' || fails=$((fails+1))
mutsrc "M12 an absent status reads as CHARGING" 's/android\.os\.BatteryManager\.BATTERY_STATUS_UNKNOWN/android.os.BatteryManager.BATTERY_STATUS_CHARGING/' || fails=$((fails+1))
mutsrc "M13 the plugged-in shortcut re-added" 's/(\n[ ]+)(return RekeyBattery\.allows\(level, scale, status\);)/$1if (b.getIntExtra(android.os.BatteryManager.EXTRA_PLUGGED, 0) != 0) return true;$1$2/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
