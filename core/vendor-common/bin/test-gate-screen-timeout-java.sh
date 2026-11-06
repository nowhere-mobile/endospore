#!/usr/bin/env bash
# test-gate-screen-timeout-java.sh [--mutate] -- the gate's 30 s screen-off timeout, under javac (NWP-20261106-18).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md (Q073, 2026-10-20) decided the screen goes off after 30 s at the gate.
# GateScreenTimeout.java is pure java.lang and is compiled as-is with GateScreenTimeoutCases; the PINS below check the
# wiring cases cannot see (the onCreate call and its place after the push-doze line, the guarded write of
# Settings.System.SCREEN_OFF_TIMEOUT, the off-UI-thread Thread, and that nothing else in the chooser writes it: the only
# other writer allowed is ensureSessionScreenTimeout, a new session's 1 min, NWP-20261113-13, which
# test-session-screen-timeout-java.sh pins).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-gate-screen-timeout-java.sh            # the cases and the pins
#   bash test-gate-screen-timeout-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ChooserActivity.java"
CLS="$SRCDIR/GateScreenTimeout.java"
CASES="$root/core/chooser/tests/gate-screen-timeout/GateScreenTimeoutCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl" >&2; exit 2; }

# body <file> <signature-substring> -> the member from its signature line to the brace that closes it
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# suite <ChooserActivity.java> <GateScreenTimeout.java> <src dir whose other files P4 scans>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the class did not compile. Only 1 convicts a mutant.
suite() {
  local f="$1" cls="$2" dir="$3" b pre o oc onc src
  [ -f "$f" ] || { echo "  FAIL missing $f" >&2; return 2; }
  [ -f "$cls" ] || { echo "  FAIL missing $cls" >&2; return 2; }
  [ -f "$CASES" ] || { echo "  FAIL missing $CASES" >&2; return 2; }
  o=$(mktemp -d -p "$W")
  cp "$cls" "$CASES" "$o/"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$o" "$o/$(basename "$cls")" "$o/$(basename "$CASES")" \
    || { echo "  FAIL the class did not compile" >&2; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$o" com.nowhere.chooser.GateScreenTimeoutCases || return 1

  # P1: onCreate calls ensureGateScreenTimeout() exactly once, after the push-doze launch line
  b=$(body "$f" 'protected void onCreate(Bundle b)')
  onc=$(printf '%s\n' "$b" | grep -c 'ensureGateScreenTimeout();' || true)
  [ "$onc" = 1 ] || { echo "  PIN P1 onCreate calls ensureGateScreenTimeout() $onc times, not once" >&2; return 1; }
  [[ "$b" == *'ensurePushDozeExemptionAsync(getApplicationContext());'* ]] || {
    echo "  PIN P1 onCreate lost the ensurePushDozeExemptionAsync line" >&2; return 1; }
  pre=${b%%ensurePushDozeExemptionAsync(getApplicationContext());*}
  [[ "$pre" != *'ensureGateScreenTimeout();'* ]] || {
    echo "  PIN P1 ensureGateScreenTimeout() runs before the ensurePushDozeExemptionAsync line" >&2; return 1; }
  # P2: the write names SCREEN_OFF_TIMEOUT and GATE_MS, behind needsWrite(
  b=$(body "$f" 'private void ensureGateScreenTimeout()')
  [ -n "$b" ] || { echo "  PIN P2 ensureGateScreenTimeout() is missing" >&2; return 1; }
  printf '%s' "$b" | perl -0ne 'exit(/GateScreenTimeout\.needsWrite\(.*?Settings\.System\.putInt\([^;]*Settings\.System\.SCREEN_OFF_TIMEOUT[^;]*GateScreenTimeout\.GATE_MS/s ? 0 : 1)' || {
    echo "  PIN P2 no Settings.System.putInt(SCREEN_OFF_TIMEOUT, GATE_MS) behind GateScreenTimeout.needsWrite(" >&2; return 1; }
  # P3: Settings.System.putInt( sits between new Thread(() -> { and }, "nowhere-gate-screen-timeout").start();
  printf '%s' "$b" | perl -0ne 'exit(/new Thread\(\(\) -> \{.*?Settings\.System\.putInt\(.*?\}, "nowhere-gate-screen-timeout"\)\.start\(\);/s ? 0 : 1)' || {
    echo "  PIN P3 the write does not sit between new Thread(() -> { and }, \"nowhere-gate-screen-timeout\").start();" >&2; return 1; }
  # P4: no other write of the setting in the chooser sources: ChooserActivity may write it only inside
  # ensureGateScreenTimeout (the gate's 30 s) and ensureSessionScreenTimeout (a new session's 1 min, NWP-20261113-13)
  for src in "$dir"/*.java; do
    [ "$(basename "$src")" = ChooserActivity.java ] && continue
    if perl -0ne 'exit(/put(Int|Long|String)\s*\([^;]*(SCREEN_OFF_TIMEOUT|"screen_off_timeout")|settings put system screen_off_timeout/ ? 0 : 1)' "$src"; then
      echo "  PIN P4 $(basename "$src") writes screen_off_timeout" >&2; return 1; fi
  done
  oc=$(awk -v g='private void ensureGateScreenTimeout()' -v s='private void ensureSessionScreenTimeout(int uid)' '
    !on && (index($0, g) || index($0, s)) { on=1; depth=0 }
    on { n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) on=0; next }
    { print }' "$f")
  if printf '%s' "$oc" | perl -0ne 'exit(/put(Int|Long|String)\s*\([^;]*(SCREEN_OFF_TIMEOUT|"screen_off_timeout")|settings put system screen_off_timeout/ ? 0 : 1)'; then
    echo "  PIN P4 ChooserActivity writes screen_off_timeout outside ensureGateScreenTimeout and" \
      "ensureSessionScreenTimeout" >&2; return 1; fi
  echo "  pins ok"
  return 0
}

echo "== $ACT"
suite "$ACT" "$CLS" "$SRCDIR" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a case or a pin: rc 1 only)"
fails=0
# mut <label> <target: cls|act> <perl-expr>
mut() {
  local label="$1" target="$2" expr="$3" d rc a c
  d=$(mktemp -d -p "$W"); a="$d/ChooserActivity.java"; c="$d/GateScreenTimeout.java"
  cp "$ACT" "$a"; cp "$CLS" "$c"
  if [ "$target" = cls ]; then perl -0pi -e "$expr" "$c"; else perl -0pi -e "$expr" "$a"; fi
  if [ "$target" = cls ] && cmp -s "$c" "$CLS"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  if [ "$target" = act ] && cmp -s "$a" "$ACT"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$a" "$c" "$SRCDIR" >/dev/null 2>"$d/err"; rc=$?
  if [ "$rc" = 1 ]; then echo "  CONVICTED $label"
  else echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/err" | head -5; fails=$((fails+1)); fi
}
mut 'T1 GATE_MS 60_000' cls 's/GATE_MS = 30_000/GATE_MS = 60_000/'
mut 'T2 needsWrite inverted' cls 's/current != GATE_MS/current == GATE_MS/'
mut 'T3 onCreate call removed' act 's/^[ \t]*ensureGateScreenTimeout\(\);[^\n]*\n//m'
mut 'T4 Thread removed' act 's/new Thread\(\(\) -> \{(?=[^}]*?SCREEN_OFF_TIMEOUT)/((Runnable) () -> {/; s/\}, "nowhere-gate-screen-timeout"\)\.start\(\);/}).run();/'
mut 'T4b start() made run()' act 's/\}, "nowhere-gate-screen-timeout"\)\.start\(\);/}, "nowhere-gate-screen-timeout").run();/'
mut 'T5 Settings.Secure' act 's/(private void ensureGateScreenTimeout\(\).*?)Settings\.System\.putInt/$1Settings.Secure.putInt/s'
mut 'T6 call above the push-doze line' act 's/^([ \t]*)(ensurePushDozeExemptionAsync\(getApplicationContext\(\)\);[^\n]*\n)((?:.*\n)*?)([ \t]*ensureGateScreenTimeout\(\);[^\n]*\n)/$1$4$2$3/m'
mut 'T7 second write elsewhere' act 's/(private void ensureGateScreenTimeout\(\))/private void otherWrite(android.content.ContentResolver cr) { android.provider.Settings.System.putInt(cr, android.provider.Settings.System.SCREEN_OFF_TIMEOUT, 60000); }\n    $1/'
mut 'T8 third write in another method' act 's/(private void ensureSessionScreenTimeout\(int uid\))/private void thirdWrite(android.content.ContentResolver cr) { android.provider.Settings.System.putInt(cr, android.provider.Settings.System.SCREEN_OFF_TIMEOUT, 15000); }\n    $1/'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
