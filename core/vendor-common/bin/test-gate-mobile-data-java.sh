#!/usr/bin/env bash
# test-gate-mobile-data-java.sh [--mutate] -- the Owner settings Mobile data switch, run under javac (NWP-20261107-13).
#
# WHY THIS IS COMMITTED. The gate's own mobile-data value is what roamd's md_claim records as the baseline and
# md_release restores (docs/product-decisions.md, 2026-10-20, dn-1026 #5). GateMobileData.java decides the bound and
# the words and is pure Java, so it is compiled here and run against GateMobileDataCases; the screen glue in
# ChooserActivity.java (which javac cannot compile off the build host) is pinned by anchor: the row in the owner
# menu, the single USER-reason write inside a Thread, the bounded re-read, the switch set from the READ value, and no
# settings-key write of mobile_data anywhere in the chooser.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK.
#
#   bash test-gate-mobile-data-java.sh            # the cases and the pins
#   bash test-gate-mobile-data-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
GMD="$SRC/GateMobileData.java"
CA="$SRC/ChooserActivity.java"
CASES="$root/core/chooser/tests/gate-mobile-data/GateMobileDataCases.java"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl" >&2; exit 2; }
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }
TIMEOUT=""
command -v timeout >/dev/null 2>&1 && TIMEOUT="timeout 60"

# body <file> <signature-regex>: the method from its signature line to the line "    }" closing it.
body() {
  RE="$2" awk '$0 ~ ENVIRON["RE"] { on = 1 } on { print } on && /^    }$/ { exit }' "$1"
}

# count <text> <fixed-string>: how many lines of text contain the string.
count() {
  local c
  c=$(printf '%s\n' "$1" | grep -cF -e "$2" || true)
  echo "$c"
}

# suite <GateMobileData.java> <ChooserActivity.java>: 0 pass, 1 a case or a pin failed, 2 extraction, 3 compile.
suite() {
  local gmd="$1" ca="$2" d menu screen data setter thread rest n
  [ -f "$gmd" ] || { echo "  PIN   GateMobileData.java does not exist" >&2; return 1; }
  [ -f "$ca" ] || { echo "  PIN   ChooserActivity.java does not exist" >&2; return 1; }
  menu=$(body "$ca" 'private View buildOwnerMenu\(\)')
  screen=$(body "$ca" 'private View buildOwnerMobileDataScreen\(\)')
  data=$(body "$ca" 'private Boolean gateDataOn\(int sub\)')
  setter=$(body "$ca" 'private Boolean setGateData\(int sub, boolean want\)')
  [ -n "$menu" ] || { echo "  PIN   buildOwnerMenu not found" >&2; return 2; }

  # P1: the row, once, opening the screen, after the Lock screen clock row.
  n=$(count "$menu" 'settingsRow(GateMobileData.ROW, GateMobileData.ROW_SUB')
  [ "$n" = 1 ] || { echo "  PIN   buildOwnerMenu has the Mobile data row $n times, not once" >&2; return 1; }
  printf '%s\n' "$menu" | perl -0ne 'exit(/settingsRow\("Lock screen clock".*?buildGateClockScreen\(\)\)\), new LinearLayout\.LayoutParams\(MATCH, WRAP\)\);\s*ll\.addView\(settingsRow\(GateMobileData\.ROW, GateMobileData\.ROW_SUB,\s*v -> setContentView\(buildOwnerMobileDataScreen\(\)\)\)/s ? 0 : 1)' \
    || { echo "  PIN   the Mobile data row does not follow Lock screen clock and open buildOwnerMobileDataScreen" >&2; return 1; }

  # P2: the one write, USER reason, in a try, followed by a re-read bounded by settled().
  [ -n "$setter" ] || { echo "  PIN   setGateData not found" >&2; return 1; }
  n=$(grep -c 'setDataEnabledForReason(' "$ca")
  [ "$n" = 1 ] || { echo "  PIN   setDataEnabledForReason appears $n times in ChooserActivity, not once" >&2; return 1; }
  printf '%s\n' "$setter" | perl -0ne 'exit(/try \{[^}]*setDataEnabledForReason\(android\.telephony\.TelephonyManager\.DATA_ENABLED_REASON_USER, want\)/s ? 0 : 1)' \
    || { echo "  PIN   setGateData does not write DATA_ENABLED_REASON_USER inside a try" >&2; return 1; }
  printf '%s\n' "$setter" | perl -0ne 'exit(/while \(true\) \{\s*seen = gateDataOn\(sub\);.*?GateMobileData\.settled\(want, seen, [^\n]*break;\s*[^\n]*sleep\(GateMobileData\.STEP_MS\)/s ? 0 : 1)' \
    || { echo "  PIN   the re-read loop is not bounded by GateMobileData.settled" >&2; return 1; }

  # P3: the screen writes only inside the Thread and sets the switch from the read value.
  [ -n "$screen" ] || { echo "  PIN   buildOwnerMobileDataScreen not found" >&2; return 1; }
  thread=$(printf '%s\n' "$screen" | awk '/new Thread\(\(\) -> \{/ { on = 1 } on { print } on && /"nowhere-gate-mobiledata"\)\.start\(\);/ { exit }')
  case "$thread" in *"setGateData(sub, want)"*) ;; *) echo "  PIN   setGateData is not called inside the named Thread" >&2; return 1 ;; esac
  rest=$(printf '%s\n' "$screen" | awk '/new Thread\(\(\) -> \{/ { skip = 1 } !skip { print } skip && /"nowhere-gate-mobiledata"\)\.start\(\);/ { skip = 0 }')
  case "$rest" in *"setGateData("*) echo "  PIN   setGateData is called outside the Thread" >&2; return 1 ;; esac
  case "$thread" in *"b.setChecked(seen != null && seen);"*) ;; *) echo "  PIN   the switch is not set from the read value" >&2; return 1 ;; esac
  n=$(printf '%s\n' "$screen" | grep -c 'setChecked(want\|setChecked(!want\|setChecked(c)' || true)
  [ "$n" = 0 ] || { echo "  PIN   the switch is set from the tapped value" >&2; return 1; }
  case "$thread" in *"GateMobileData.toast(want, seen)"*) ;; *) echo "  PIN   the toast does not say what was read" >&2; return 1 ;; esac

  # P4: the read.
  case "$data" in *".isDataEnabled()"*) ;; *) echo "  PIN   gateDataOn does not read isDataEnabled()" >&2; return 1 ;; esac

  # P5: no settings-key write of mobile_data in any chooser source.
  n=$(grep -rnE 'Settings\.Global\.put[A-Za-z]*\([^;]*(mobile_data|MOBILE_DATA)|settings put global mobile_data' "$root/core/chooser/src" || true)
  [ -z "$n" ] || { echo "  PIN   a chooser source writes the mobile_data settings key: $n" >&2; return 1; }

  d=$(mktemp -d -p "$W") || return 2
  mkdir -p "$d/com/nowhere/chooser"
  cp "$gmd" "$d/com/nowhere/chooser/GateMobileData.java"
  sed -e '1i package com.nowhere.chooser;' "$CASES" > "$d/com/nowhere/chooser/GateMobileDataCases.java"
  if ! "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$d/out" \
      "$d/com/nowhere/chooser/GateMobileData.java" "$d/com/nowhere/chooser/GateMobileDataCases.java" > "$d/javac.out" 2>&1; then
    sed 's/^/    /' "$d/javac.out" >&2; rm -rf "$d"; return 3
  fi
  if ! $TIMEOUT "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.GateMobileDataCases > "$d/run.out" 2>&1; then
    grep -v '^ok' "$d/run.out" >&2 || true
    rm -rf "$d"; return 1
  fi
  [ "$MUTATE" = yes ] || sed 's/^/  /' "$d/run.out"
  rm -rf "$d"
  return 0
}

echo "== $GMD"
suite "$GMD" "$CA"; rc=$?
[ "$rc" = 0 ] || { echo "FAILED (exit $rc)"; exit 1; }
echo "== pass"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not apply or compile proves nothing)"
# mut <label> <which: gmd|ca> <perl-expr>
mut() {
  local d gmdf caf src m rc
  d=$(mktemp -d -p "$W") || return 1
  gmdf="$GMD"; caf="$CA"
  case "$2" in
    gmd) src="$GMD"; gmdf="$d/GateMobileData.java" ;;
    ca) src="$CA"; caf="$d/ChooserActivity.java" ;;
  esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$gmdf" "$caf" > "$d/out" 2>&1; rc=$?
  case "$rc" in
    1) echo "  convicted $1" ;;
    0) echo "  SURVIVED  $1"; rm -rf "$d"; return 1 ;;
    *) echo "  BROKEN    $1 -- exit $rc, not a conviction"; sed 's/^/      /' "$d/out"; rm -rf "$d"; return 1 ;;
  esac
  rm -rf "$d"
}

fails=0
mut "M1 settled ignores the time bound" gmd 's/ \|\| elapsedMs >= READBACK_MS//' || fails=$((fails+1))
mut "M2 the toast confirms without the read-back" gmd 's/if \(seen != null && seen == want\) return want/if (true) return want/' || fails=$((fails+1))
mut "M3 the switch set from the tapped value" ca 's/b\.setChecked\(seen != null && seen\);/b.setChecked(want);/' || fails=$((fails+1))
mut "M4 the write moved onto the UI thread" ca 's/(private View buildOwnerMobileDataScreen\(\).*?)new Thread\(\(\) -> \{\s*final Boolean seen = setGateData\(sub, want\);/$1final Boolean seen = setGateData(sub, want);\n                new Thread(() -> {/s' || fails=$((fails+1))
mut "M5 the row removed from buildOwnerMenu" ca 's/        ll\.addView\(settingsRow\(GateMobileData\.ROW, GateMobileData\.ROW_SUB,\n[^\n]*\n//' || fails=$((fails+1))
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "== all mutations convicted"
