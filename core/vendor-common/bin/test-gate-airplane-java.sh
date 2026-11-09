#!/usr/bin/env bash
# test-gate-airplane-java.sh [--mutate] -- the gate Settings Airplane mode switch, run under javac (NWP-20261109-21).
#
# WHY THIS IS COMMITTED. The gate's own airplane value is what roamd's dtclaim records when the next session first
# comes to the front and dtrelease restores at its release (docs/product-decisions.md, 2026-10-20, Q072).
# GateAirplane.java decides the bound and the words and is pure Java, so it is compiled here and run against
# GateAirplaneCases; the screen glue in ChooserActivity.java (which javac cannot compile off the build host) is pinned
# by anchor: the switch once in buildSettingsScreen between the Wi-Fi row and the Software update header, the single
# setAirplaneMode write reached only from inside a Thread, the bounded re-read, the switch set from the READ value,
# the verdict on the switch's own line (apMsg, never swMsg), and no settings-key write of airplane_mode_on anywhere
# in the chooser.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK.
#
#   bash test-gate-airplane-java.sh            # the cases and the pins
#   bash test-gate-airplane-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
GA="$SRC/GateAirplane.java"
CA="$SRC/ChooserActivity.java"
CASES="$root/core/chooser/tests/gate-airplane/GateAirplaneCases.java"
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

# line <text> <fixed-string>: the first line number of text holding the string, 0 when none.
line() {
  local n
  n=$(printf '%s\n' "$1" | grep -nF -e "$2" | head -1 | cut -d: -f1)
  echo "${n:-0}"
}

# suite <GateAirplane.java> <ChooserActivity.java>: 0 pass, 1 a case or a pin failed, 2 extraction, 3 compile.
suite() {
  local ga="$1" ca="$2" d settings setter block thread rest n lw lr lb lc ll f
  [ -f "$ga" ] || { echo "  PIN   GateAirplane.java does not exist" >&2; return 1; }
  [ -f "$ca" ] || { echo "  PIN   ChooserActivity.java does not exist" >&2; return 1; }
  settings=$(body "$ca" 'private View buildSettingsScreen\(\)')
  setter=$(body "$ca" 'private Boolean setGateAirplane\(boolean want\)')
  [ -n "$settings" ] || { echo "  PIN   buildSettingsScreen not found" >&2; return 2; }

  # P1: the switch, once, in buildSettingsScreen, after the Wi-Fi row and before the Software update header.
  n=$(count "$settings" 'apSw.setText(GateAirplane.ROW);')
  [ "$n" = 1 ] || { echo "  PIN   buildSettingsScreen has the Airplane mode switch $n times, not once" >&2; return 1; }
  n=$(grep -cF 'setText(GateAirplane.ROW)' "$ca" || true)
  [ "$n" = 1 ] || { echo "  PIN   ChooserActivity has the Airplane mode switch $n times, not once" >&2; return 1; }
  lw=$(line "$settings" 'settingsRow("Wi-Fi"')
  lr=$(line "$settings" 'apSw.setText(GateAirplane.ROW);')
  lb=$(line "$settings" 'TextView swHdr = ')
  { [ "$lw" -gt 0 ] && [ "$lr" -gt "$lw" ] && [ "$lb" -gt "$lr" ]; } \
    || { echo "  PIN   the switch is not between the Wi-Fi row ($lw) and the Software update header ($lb): line $lr" >&2; return 1; }
  block=$(printf '%s\n' "$settings" | sed -n "$((lw + 2)),$((lb - 1))p")
  case "$block" in *"new android.widget.Switch(this)"*) ;; *) echo "  PIN   the block has no android.widget.Switch" >&2; return 1 ;; esac
  case "$block" in *"apSub.setText(GateAirplane.SUB);"*) ;; *) echo "  PIN   the subtitle is not under the switch" >&2; return 1 ;; esac
  case "$block" in *"final TextView apMsg = new TextView(this);"*) ;; *) echo "  PIN   the block has no own result line apMsg" >&2; return 1 ;; esac

  # P2: the one write, in a try, followed by a re-read bounded by settled().
  [ -n "$setter" ] || { echo "  PIN   setGateAirplane not found" >&2; return 1; }
  n=$(grep -c 'setAirplaneMode(' "$ca" || true)
  [ "$n" = 1 ] || { echo "  PIN   setAirplaneMode appears $n times in ChooserActivity, not once" >&2; return 1; }
  printf '%s\n' "$setter" | perl -0ne 'exit(/try \{[^}]*getSystemService\(android\.net\.ConnectivityManager\.class\)\.setAirplaneMode\(want\);/s ? 0 : 1)' \
    || { echo "  PIN   setGateAirplane does not call ConnectivityManager.setAirplaneMode inside a try" >&2; return 1; }
  printf '%s\n' "$setter" | perl -0ne 'exit(/while \(true\) \{.*?AIRPLANE_MODE_ON.*?GateAirplane\.settled\(want, seen, [^\n]*break;\s*[^\n]*sleep\(GateAirplane\.STEP_MS\)/s ? 0 : 1)' \
    || { echo "  PIN   the re-read loop is not bounded by GateAirplane.settled" >&2; return 1; }

  # P3: the helper is reached only from inside the named Thread.
  thread=$(printf '%s\n' "$block" | awk '/new Thread\(\(\) -> \{/ { on = 1 } on { print } on && /"nowhere-gate-airplane"\)\.start\(\);/ { exit }')
  case "$thread" in *"setGateAirplane(want)"*) ;; *) echo "  PIN   setGateAirplane is not called inside the named Thread" >&2; return 1 ;; esac
  rest=$(printf '%s\n' "$block" | awk '/new Thread\(\(\) -> \{/ { skip = 1 } !skip { print } skip && /"nowhere-gate-airplane"\)\.start\(\);/ { skip = 0 }')
  case "$rest" in *"setGateAirplane("*) echo "  PIN   setGateAirplane is called outside the Thread" >&2; return 1 ;; esac
  n=$(grep -c 'setGateAirplane(' "$ca" || true)
  [ "$n" = 2 ] || { echo "  PIN   setGateAirplane( appears $n times, not its declaration and the one call" >&2; return 1; }

  # P4: the switch is set from the read value, with the listener detached.
  printf '%s\n' "$thread" | perl -0ne 'exit(/apSw\.setOnCheckedChangeListener\(null\);\s*apSw\.setChecked\(seen != null && seen\);/s ? 0 : 1)' \
    || { echo "  PIN   the switch is not set from the read value with its listener detached" >&2; return 1; }
  n=$(printf '%s\n' "$block" | grep -c 'setChecked(want\|setChecked(!want\|setChecked(c)\|setChecked(b' || true)
  [ "$n" = 0 ] || { echo "  PIN   the switch is set from the tapped value" >&2; return 1; }

  # P5: the verdict goes to the switch's own line, never the Software update line or a Toast.
  case "$thread" in *"apMsg.setText(GateAirplane.toast(want, seen));"*) ;; *) echo "  PIN   the verdict is not written to apMsg" >&2; return 1 ;; esac
  case "$block" in *swMsg*|*settingVerdict*|*"Toast."*) echo "  PIN   the block references swMsg, settingVerdict or a Toast" >&2; return 1 ;; esac

  # P6: the initial state is the read, set before the listener is wired.
  case "$block" in *"android.provider.Settings.Global.AIRPLANE_MODE_ON, 0) == 1;"*) ;; *) echo "  PIN   the switch's state is not read from airplane_mode_on" >&2; return 1 ;; esac
  lc=$(line "$block" 'apSw.setChecked(apOn);')
  ll=$(printf '%s\n' "$block" | grep -nF 'apSw.setOnCheckedChangeListener(apSelf[0]);' | tail -1 | cut -d: -f1)
  { [ "$lc" -gt 0 ] && [ "${ll:-0}" -gt "$lc" ]; } \
    || { echo "  PIN   the read state is not set before the listener is wired" >&2; return 1; }

  # P7: no settings-key write of airplane_mode_on in any chooser source (the given ChooserActivity included).
  for f in "$ca" $(find "$root/core/chooser/src" -name '*.java' ! -name ChooserActivity.java); do
    perl -0ne 'exit(/Settings\.(Global|System)\.put\w*\([^;]*(AIRPLANE_MODE_ON|airplane_mode_on)|settings put global airplane_mode_on/s ? 1 : 0)' "$f" \
      || { echo "  PIN   $f writes the airplane_mode_on settings key" >&2; return 1; }
  done

  d=$(mktemp -d -p "$W") || return 2
  mkdir -p "$d/com/nowhere/chooser"
  cp "$ga" "$d/com/nowhere/chooser/GateAirplane.java"
  sed -e '1i package com.nowhere.chooser;' "$CASES" > "$d/com/nowhere/chooser/GateAirplaneCases.java"
  if ! "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$d/out" \
      "$d/com/nowhere/chooser/GateAirplane.java" "$d/com/nowhere/chooser/GateAirplaneCases.java" > "$d/javac.out" 2>&1; then
    sed 's/^/    /' "$d/javac.out" >&2; rm -rf "$d"; return 3
  fi
  if ! $TIMEOUT "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.GateAirplaneCases > "$d/run.out" 2>&1; then
    grep -v '^ok' "$d/run.out" >&2 || true
    rm -rf "$d"; return 1
  fi
  [ "$MUTATE" = yes ] || sed 's/^/  /' "$d/run.out"
  rm -rf "$d"
  return 0
}

echo "== $GA"
suite "$GA" "$CA"; rc=$?
[ "$rc" = 0 ] || { echo "FAILED (exit $rc)"; exit 1; }
echo "== pass"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not apply or compile proves nothing)"
# mut <label> <which: ga|ca> <perl-expr>
mut() {
  local d gaf caf src m rc
  d=$(mktemp -d -p "$W") || return 1
  gaf="$GA"; caf="$CA"
  case "$2" in
    ga) src="$GA"; gaf="$d/GateAirplane.java" ;;
    ca) src="$CA"; caf="$d/ChooserActivity.java" ;;
  esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$gaf" "$caf" > "$d/out" 2>&1; rc=$?
  case "$rc" in
    1) echo "  convicted $1" ;;
    0) echo "  SURVIVED  $1"; rm -rf "$d"; return 1 ;;
    *) echo "  BROKEN    $1 -- exit $rc, not a conviction"; sed 's/^/      /' "$d/out"; rm -rf "$d"; return 1 ;;
  esac
  rm -rf "$d"
}

fails=0
mut "M1 settled ignores the time bound" ga 's/ \|\| elapsedMs >= READBACK_MS//' || fails=$((fails+1))
mut "M2 the toast confirms without the read-back" ga 's/if \(seen != null && seen == want\) return want/if (true) return want/' || fails=$((fails+1))
mut "M3 the switch set from the tapped value" ca 's/apSw\.setChecked\(seen != null && seen\);/apSw.setChecked(want);/' || fails=$((fails+1))
mut "M4 the write moved onto the UI thread" ca 's/new Thread\(\(\) -> \{\n(\s*)final Boolean seen = setGateAirplane\(want\);/final Boolean seen = setGateAirplane(want);\n$1new Thread(() -> {/' || fails=$((fails+1))
mut "M5 the block removed from buildSettingsScreen" ca 's/\n        \/\/ Airplane mode beside Wi-Fi \(NWP-20261109-21.*?\n(\n        \/\/ Messages & calls \(#146\))/\n$1/s' || fails=$((fails+1))
mut "M6 a Settings.Global.putInt write added" ca 's/(\n(\s*)final Boolean seen = setGateAirplane\(want\);)/\n$2android.provider.Settings.Global.putInt(getContentResolver(),\n$2        android.provider.Settings.Global.AIRPLANE_MODE_ON, want ? 1 : 0);$1/' || fails=$((fails+1))
mut "M7 the verdict written to swMsg instead of apMsg" ca 's/apMsg\.setText\(GateAirplane\.toast/swMsg.setText(GateAirplane.toast/' || fails=$((fails+1))
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "== all mutations convicted"
