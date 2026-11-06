#!/usr/bin/env bash
# test-gate-mac-mode-java.sh [--mutate] -- the gate Wi-Fi join's three MAC choices, run under javac (NWP-20261106-05).
#
# WHY THIS IS COMMITTED. Q139 (docs/product-decisions.md): connectWifi pinned RANDOMIZATION_PERSISTENT, so every
# identity that joined an SSID presented the same MAC to that AP. A join now offers a new private address on each
# connection (default), the same private address for the network, or the real MAC. GateMacMode is a pure class
# compiled here with its cases; the PINS check that connectWifi writes macRandomizationSetting only through it and
# that buildWifiScreen renders and passes the choice through it.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-gate-mac-mode-java.sh            # the cases + pins
#   bash test-gate-mac-mode-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
MODE="$root/core/chooser/src/com/nowhere/chooser/GateMacMode.java"
ACT="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
CASES="$root/core/chooser/tests/gate-mac-mode/GateMacModeCases.java"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite reads ChooserActivity with perl, and there is none" >&2; exit 2; }
[ -f "$ACT" ] && [ -f "$CASES" ] || { echo "FAIL: missing $ACT or $CASES" >&2; exit 2; }

# suite <GateMacMode.java> <ChooserActivity.java> -> 0 pass, 1 a case or pin failed (the only code that convicts a
# mutant), 3 the class or the cases did not compile.
suite() {
  local mode="$1" act="$2" d out rc
  local bad=0
  # The two bodies the pins read, cut by text: from the signature to the next member at 4-space indent.
  local cw="" bw=""
  cw=$(perl -0ne 'print $1 if /(    private String connectWifi\(String ssid, String pw, String identity.*?)\n    (?:private |\/\*\*)/s' "$act")
  bw=$(perl -0ne 'print $1 if /(    private View buildWifiScreen\(\).*?)\n    (?:private |\/\*\*)/s' "$act")
  [ -n "$cw" ] || { echo "  PIN   the 6-argument connectWifi was not found" >&2; bad=1; }
  [ -n "$bw" ] || { echo "  PIN   buildWifiScreen was not found" >&2; bad=1; }
  # P1: connectWifi writes macRandomizationSetting only from GateMacMode.setting(macSel, always); the one other
  # assignment in the file is the mirror restore's stored int (WifiMirrorLine field 3), which is not a gate choice.
  printf '%s' "$cw" | perl -0ne 'my @a = /macRandomizationSetting\s*=/g; my @g = /cfg\.macRandomizationSetting = GateMacMode\.setting\(macSel, always\);/g; exit(@a == 1 && @g == 1 ? 0 : 1)' || {
    echo "  PIN   connectWifi must assign macRandomizationSetting exactly once, from GateMacMode.setting(macSel, always)" >&2; bad=1; }
  perl -0ne 'my @a = /macRandomizationSetting\s*=/g; exit(@a == 2 && /macRandomizationSetting = Integer\.parseInt\(e\[2\]\)/ ? 0 : 1)' "$act" || {
    echo "  PIN   ChooserActivity must assign macRandomizationSetting exactly twice: connectWifi's GateMacMode.setting(macSel, always) and maybeMirrorWifi's #118 carry Integer.parseInt(e[2]) (removing the carry or adding a third assignment both fail)" >&2; bad=1; }
  # P2: no RANDOMIZATION_PERSISTENT / RANDOMIZATION_NONE token in code (comments may name them).
  perl -0ne 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g; exit(/\bRANDOMIZATION_(?:PERSISTENT|NONE)\b/ ? 1 : 0)' "$act" || {
    echo "  PIN   ChooserActivity still names RANDOMIZATION_PERSISTENT or RANDOMIZATION_NONE in code" >&2; bad=1; }
  # P3: the platform's RANDOMIZATION_ALWAYS is read by reflection.
  printf '%s' "$cw" | perl -0ne 'exit(/WifiConfiguration\.class\.getDeclaredField\("RANDOMIZATION_ALWAYS"\)/ && /always = f\.getInt\(null\);/ ? 0 : 1)' || {
    echo "  PIN   connectWifi must read RANDOMIZATION_ALWAYS by reflection into always" >&2; bad=1; }
  # P4: the signatures.
  perl -0ne 'exit(/connectWifi\(String ssid, String pw, String identity, boolean ttls, boolean hidden, int macSel\) \{/ && /return connectWifi\(ssid, pw, "", false, false, GateMacMode\.DEFAULT\);/ ? 0 : 1)' "$act" || {
    echo "  PIN   connectWifi's signatures: the 6-argument form takes int macSel, the 2-argument one passes GateMacMode.DEFAULT" >&2; bad=1; }
  # P5: the screen renders the choice through GateMacMode.
  printf '%s' "$bw" | perl -0ne 'exit(/final int\[\] macSel = \{GateMacMode\.DEFAULT\};/ && /GateMacMode\.LABELS\[macSel\[0\]\]/ && /\(macSel\[0\] \+ 1\) % GateMacMode\.LABELS\.length/ && /macHint\.setText\(GateMacMode\.HINT\);/ && !/macKinds/ ? 0 : 1)' || {
    echo "  PIN   buildWifiScreen must use GateMacMode.DEFAULT, LABELS and HINT (no macKinds)" >&2; bad=1; }
  # P6: the handler snapshots macSel[0] at the tap and passes it.
  printf '%s' "$bw" | perl -0ne 'exit(/final int macMode = macSel\[0\];/ && /connectWifi\(ssid, pw, ident, ttls, hidden, macMode\)/ ? 0 : 1)' || {
    echo "  PIN   the connect handler must pass macSel[0] (as macMode) to connectWifi" >&2; bad=1; }
  # The class itself: missing (origin/main) is reported AFTER the pins, so every failure shows.
  [ -f "$mode" ] || { echo "  FAIL  GateMacMode.java does not exist" >&2; return 1; }
  [ "$bad" -eq 0 ] || return 1
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$mode" "$d/src/com/nowhere/chooser/GateMacMode.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/GateMacModeCases.java"
  "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java || return 3
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.GateMacModeCases 2>&1); rc=$?
  echo "$out"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

echo "== $MODE"
suite "$MODE" "$ACT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <mode|act> <perl-expr>
  local d c a rc target; d=$(mktemp -d -p "$W") || return 1; c="$d/GateMacMode.java"; a="$d/ChooserActivity.java"
  cp "$MODE" "$c"; cp "$ACT" "$a"
  target="$c"; [ "$2" = act ] && target="$a"
  if ! perl -0pi -e "$3" "$target"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if cmp -s "$MODE" "$c" && cmp -s "$ACT" "$a"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  suite "$c" "$a" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "G1 choice 0 writes PERSISTENT"                   mode 's/case 0: return always >= 0 \? always : NON_PERSISTENT;/case 0: return PERSISTENT;/' || fails=$((fails+1))
mut "G2 the reflected value is ignored"               mode 's/case 0: return always >= 0 \? always : NON_PERSISTENT;/case 0: return NON_PERSISTENT;/' || fails=$((fails+1))
mut "G3 the fallback is PERSISTENT"                   mode 's/always : NON_PERSISTENT;/always : PERSISTENT;/' || fails=$((fails+1))
mut "G4 labels 0 and 1 swapped"                       mode 's/("New private address each connection \(default\)",\s*)("Same private address for this network",)/$2\n        $1/' || fails=$((fails+1))
mut "G5 the old hint restored"                        mode 's/"Randomized hides this phone.s hardware address\. The network can still recognise this phone\."/"Randomized hides this device from the network. Use the real MAC only if a network\x27s allowlist or captive portal needs it."/' || fails=$((fails+1))
mut "G6 connectWifi back to the PERSISTENT literal"   act  's/cfg\.macRandomizationSetting = GateMacMode\.setting\(macSel, always\);/cfg.macRandomizationSetting = android.net.wifi.WifiConfiguration.RANDOMIZATION_PERSISTENT;/' || fails=$((fails+1))
mut "G7 the handler passes DEFAULT whatever was picked" act 's/final int macMode = macSel\[0\];/final int macMode = GateMacMode.DEFAULT;/' || fails=$((fails+1))
mut "G8 the reflection reads another field"           act  's/getDeclaredField\("RANDOMIZATION_ALWAYS"\)/getDeclaredField("RANDOMIZATION_AUTO")/' || fails=$((fails+1))
mut "G9 connectWifi passes -1 instead of always"      act  's/GateMacMode\.setting\(macSel, always\)/GateMacMode.setting(macSel, -1)/g' || fails=$((fails+1))
# G10: maybeMirrorWifi is not edited by this slice; its #118 carry of the stored int is why a saved network keeps
# its mode until it is rejoined, and the file-wide pin must convict its removal.
mut "G10 the mirror restore drops the stored mode"    act  's/try \{ cfg\.macRandomizationSetting = Integer\.parseInt\(e\[2\]\); \} catch \(Throwable ignore\) \{\}//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
