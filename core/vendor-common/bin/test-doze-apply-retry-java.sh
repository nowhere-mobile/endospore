#!/usr/bin/env bash
# test-doze-apply-retry-java.sh [--mutate] -- NWP-20261116-14 (dn-1023 #3, docs/product-decisions.md 2026-10-24): the
# gate retries the login Doze read and reset until they hold, bounded at about 10 s, before the switch-in.
#
# WHY THIS IS COMMITTED. ChooserActivity.applyRoamedDozeApps read GET-DOZE-APPS ONCE and retried the reset
# (DozeAppsMirror.dropForeign) once. A read that failed once left the profile's own choices un-applied, and a reset
# that failed twice left a cold-locked profile's Unrestricted entry live for the arriving session through a shared
# appId. In both cases the session's sign-out capture could seal the wrong set. Now one attempt is the read and then
# the reset, and DozeApplyRetry.run repeats a failed attempt 1 s apart until 10 s after the first attempt ended.
#
# Two halves: the cases run DozeApplyRetry.java as is under javac on a fake clock with recorded sleeps (in
# core/chooser/tests/doze-apply-retry/), and source pins on applyRoamedDozeApps check that it calls
# DozeApplyRetry.run once, that the GET-DOZE-APPS read is inside the attempt and outside PUSH_DOZE_LOCK, that
# dropForeign is inside the attempt under PUSH_DOZE_LOCK, that the live record arms only after run and only on its
# result, and that the login call still precedes the switch-in. The java run has a hang guard (timeout 20), so a
# removed bound fails in seconds instead of hanging the suite.
# NWP-20261117-06 adds: DozeApplyRetry.mayCapture in the cases (only an exact UNARMED reply keeps the session's
# record), and pins that applyRoamedDozeApps sends DOZE-ARM after the arm decision, outside PUSH_DOZE_LOCK, carrying
# the outcome (armed[0], set once after the arm).
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against deliberately broken copies, each of which must fail a CASE or a PIN.
#
#   bash test-doze-apply-retry-java.sh            # the cases and the pins
#   bash test-doze-apply-retry-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
SRC="$CH/src/com/nowhere/chooser"
RETRY="$SRC/DozeApplyRetry.java"
ACT="$SRC/ChooserActivity.java"
CASES="$CH/tests/doze-apply-retry/DozeApplyRetryCases.java"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-doze-apply-retry-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
# One root: every temp of this suite lives inside $W.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# cases <DozeApplyRetry.java>: compiles it as is with the cases and runs them under a hang guard.
# Returns 0 every case passes, 1 a case failed or the run hung (timeout exit 124), 3 no compile.
cases(){
  local d out r
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser" "$d/out"
  cp "$1" "$d/src/com/nowhere/chooser/DozeApplyRetry.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/DozeApplyRetryCases.java"
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -d "$d/out" "$d/src/com/nowhere/chooser/DozeApplyRetry.java" \
      "$d/src/com/nowhere/chooser/DozeApplyRetryCases.java" 2>&1); then
    printf '%s\n' "$out" >&2; rm -rf "$d"; return 3
  fi
  out=$(timeout 20 "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.DozeApplyRetryCases 2>&1); r=$?
  rm -rf "$d"
  printf '%s\n' "$out" | sed 's/^/    /'
  [ "$r" = 124 ] && echo "    HUNG: the run did not end inside 20 s"
  case "$r" in 0) return 0 ;; *) return 1 ;; esac
}

# method_of <file>: the lines of applyRoamedDozeApps with // comments dropped (its code holds no // in a literal)
method_of(){
  awk '
    !on && $0 == "    private void applyRoamedDozeApps(int uid) {" { on=1 }
    on { l=$0; sub(/\/\/.*$/, "", l); print l }
    on && $0 == "    }" { exit }
  ' "$1"
}
# lock_spans: on stdin a method body; prints "<open> <close>" for each synchronized (PUSH_DOZE_LOCK) block
lock_spans(){
  awk '
    { n=gsub(/\{/,"{"); c=gsub(/\}/,"}") }
    index($0, "synchronized (PUSH_DOZE_LOCK) {") { open[++k]=NR; base[k]=depth }
    { depth+=n-c; for (i=1;i<=k;i++) if (!done[i] && depth<=base[i]) { print open[i], NR; done[i]=1 } }
  '
}
# lineno <pattern> <text>: the line numbers holding the fixed string
lineno(){ grep -nF -- "$1" <<<"$2" | cut -d: -f1; }
# codecount <file> <pattern>: matches with comments blanked and string literals kept
codecount(){ perl -0777 -pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|/\*.*?\*/|//[^\n]*}{ defined $1 ? $1 : do { (my $c = $&) =~ tr/\n/ /c; $c } }gse' "$1" | grep -c -- "$2"; }
# in_span <line> <spans>: true when the line is inside one of the spans
in_span(){
  local ln=$1 s e
  while read -r s e; do
    [ -n "$s" ] || continue
    if [ "$ln" -gt "$s" ] && [ "$ln" -lt "$e" ]; then echo "$s $e"; return 0; fi
  done <<<"$2"
  return 1
}

# pins <ChooserActivity.java>: prints one "ok|no <label>" per pin on applyRoamedDozeApps
pins(){
  local m R E G D A X S Z spans span s e prev runs one=yes v
  m=$(method_of "$1")
  if [ -z "$m" ]; then echo "no control: applyRoamedDozeApps(int uid) not found"; return; fi
  R=$(lineno 'DozeApplyRetry.run(() -> {' "$m")
  E=$(grep -nE '^ *\}, android\.os\.SystemClock::elapsedRealtime, android\.os\.SystemClock::sleep\);$' <<<"$m" | cut -d: -f1)
  G=$(lineno 'DaemonSocket.roundTripLinesOrNull("GET-DOZE-APPS' "$m")
  D=$(lineno 'DozeAppsMirror.dropForeign(' "$m")
  A=$(lineno 'DozeAppsMirror.armLiveRecord(' "$m")
  X=$(lineno 'DozeAppsMirror.disarmLiveRecord();' "$m")
  S=$(lineno 'DaemonSocket.roundTrip("DOZE-ARM\n' "$m")
  for v in "R:$R" "E:$E" "G:$G" "D:$D" "A:$A" "X:$X" "S:$S"; do
    if [ "$(grep -c . <<<"${v#*:}")" != 1 ]; then echo "no control: anchor ${v%%:*} did not match exactly once in applyRoamedDozeApps"; one=no; fi
  done
  [ "$one" = yes ] && echo "ok control: every anchor matches exactly once in applyRoamedDozeApps"
  runs=$(codecount "$1" 'DozeApplyRetry\.run(')
  if [ "$runs" = 1 ] && [ "$(grep -c 'DozeApplyRetry\.run(' <<<"$m")" = 1 ]; then echo "ok applyRoamedDozeApps calls DozeApplyRetry.run once (once in the file)"
  else echo "no DozeApplyRetry.run is called $runs time(s) in ChooserActivity.java, not once, in applyRoamedDozeApps"; fi
  [ "$one" = yes ] || return
  if grep -qF 'boolean held = DozeApplyRetry.run(() -> {' <<<"$(sed -n "${R}p" <<<"$m")"; then echo "ok run's result is held"; else echo "no run's result is not assigned to held"; fi
  if [ "$R" -lt "$G" ] && [ "$G" -lt "$E" ]; then echo "ok the GET-DOZE-APPS read is inside the attempt"; else echo "no the GET-DOZE-APPS read is outside the attempt (no retry of the read)"; fi
  spans=$(lock_spans <<<"$m")
  if span=$(in_span "$D" "$spans"); then
    read -r s e <<<"$span"
    if [ "$s" -gt "$R" ] && [ "$e" -lt "$E" ]; then echo "ok dropForeign is inside the attempt, under PUSH_DOZE_LOCK"
    else echo "no the PUSH_DOZE_LOCK block around dropForeign is not inside the attempt"; fi
  else echo "no dropForeign is not under PUSH_DOZE_LOCK"; fi
  if in_span "$G" "$spans" >/dev/null; then echo "no the GET-DOZE-APPS read is inside a PUSH_DOZE_LOCK block"; else echo "ok the GET-DOZE-APPS read is outside every PUSH_DOZE_LOCK block"; fi
  prev=$(sed -n "$((A-1))p" <<<"$m")
  if [ "$A" -gt "$E" ] && [ "$prev" = '                if (held) {' ]; then echo "ok the live record arms only after run, guarded by its result"
  else echo "no the live record arm is not after run under 'if (held) {'"; fi
  if [ "$X" -lt "$R" ]; then echo "ok the earlier arm is dropped before the first attempt"; else echo "no disarmLiveRecord is not before the attempts"; fi
  if [ "$S" -gt "$A" ]; then echo "ok the DOZE-ARM send is after the arm decision (S > A)"
  else echo "no the DOZE-ARM send is not after the arm decision (S > A)"; fi
  if in_span "$S" "$spans" >/dev/null; then echo "no the DOZE-ARM send is inside a PUSH_DOZE_LOCK block"
  else echo "ok the DOZE-ARM send is outside every PUSH_DOZE_LOCK block"; fi
  if grep -qF 'armed[0] ? "armed" : "unarmed"' <<<"$(sed -n "${S}p" <<<"$m")"; then echo "ok DOZE-ARM carries the arm outcome"
  else echo "no DOZE-ARM does not carry armed[0] ? \"armed\" : \"unarmed\""; fi
  Z=$(lineno 'armed[0] = live;' "$m")
  if [ "$(grep -c . <<<"$Z")" = 1 ] && [ "$Z" -gt "$A" ]; then echo "ok armed[0] = live once, after the arm (A)"
  else echo "no armed[0] = live is not set exactly once after the arm (A)"; fi
  if awk '/int supersedeColdUid = -1;/ { inlogin = 1 }
      inlogin && /^                applyRoamedDozeApps\(uid\);/ && !a { a = NR }
      inlogin && /switchToUser\(uid/ && !s { s = NR }
      END { exit !(a > 0 && s > 0 && a < s) }' "$1"; then echo "ok the login apply still precedes the switchToUser( call"
  else echo "no the login apply does not precede the switchToUser( call"; fi
}
run_pins(){ # run_pins <file>: ok/no lines to the counters; returns 1 if any pin failed
  local line bad=0
  while IFS= read -r line; do
    case "$line" in ok\ *) ok "${line#ok }" ;; *) no "${line#no }"; bad=1 ;; esac
  done < <(pins "$1")
  return $bad
}

echo "== the cases =="
cases "$RETRY"; rc=$?
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the cases did not pass (exit $rc: 1 a case failed or hung, 3 no compile)"; fi
echo "== the applyRoamedDozeApps pins =="
run_pins "$ACT"; prc=$?
# a comment line added inside the method changes no pinned code
P=$(mktemp -p "$W")
sed 's|^    private void applyRoamedDozeApps(int uid) {$|&\n        // probe: a comment inside the apply|' "$ACT" > "$P"
if cmp -s "$P" "$ACT"; then no "probe copy is inert"
elif [ -z "$(pins "$P" | grep '^no ' || true)" ]; then ok "a comment added inside applyRoamedDozeApps leaves the pins green"
else no "a comment inside applyRoamedDozeApps broke a pin"; fi

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ] && [ "$prc" = 0 ]; then
  echo
  echo "== mutations (each MUST be convicted by a case or a pin) =="
  mutate(){ # mutate <case|pin> <label> <sed script>: case mutates DozeApplyRetry.java, pin ChooserActivity.java
    local kind=$1 label=$2 script=$3 d src copy r
    if [ "$kind" = case ]; then src=$RETRY; else src=$ACT; fi
    d=$(mktemp -d -p "$W"); copy="$d/$(basename "$src")"
    cp "$src" "$copy"
    if ! sed -i "$script" "$copy" 2>"$d/err"; then no "MUTATION BROKEN (sed): $label"; rm -rf "$d"; return; fi
    if cmp -s "$copy" "$src"; then no "MUTATION INERT: $label"; rm -rf "$d"; return; fi
    if [ "$kind" = case ]; then
      cases "$copy" >/dev/null 2>&1; r=$?
      case "$r" in
        1) ok "convicted: $label" ;;
        0) no "NOT CONVICTED: $label -- the cases pass on broken code" ;;
        *) no "MUTATION BROKEN (exit $r, not a case): $label" ;;
      esac
    else
      if [ -n "$(pins "$copy" | grep '^no ' || true)" ]; then ok "convicted: $label"; else no "NOT CONVICTED: $label -- the pins pass on broken code"; fi
    fi
    rm -rf "$d"
  }
  # The four the task names.
  mutate pin  "no retry of the read (the read moved out of the attempt)" '/DaemonSocket.roundTripLinesOrNull("GET-DOZE-APPS/d; s#^            boolean held = DozeApplyRetry.run(() -> {#            java.util.List<String> lines = DaemonSocket.roundTripLinesOrNull("GET-DOZE-APPS\\n", 30000);\n&#'
  mutate case "the bound removed (a failing attempt loops for ever; the hang guard convicts)" '/if (left <= 0) break;/d'
  mutate pin  "the live record arms after a failed run" 's#^                if (held) {#                if (true) {#'
  mutate pin  "the read inside the lock" 's#^\( *\)\(java.util.List<String> lines = DaemonSocket.roundTripLinesOrNull("GET-DOZE-APPS.*\)$#\1synchronized (PUSH_DOZE_LOCK) {\n\1\2\n\1}#'
  # More of the contract.
  mutate case "the last sleep is not cut to what is left" 's#Math.min(BACKOFF_MS, left)#BACKOFF_MS#'
  mutate case "the budget runs from the start, not from the first attempt's end" 's#final long start = nowMs.getAsLong();#final long start = 0;#'
  mutate case "the first read is not 30 s" 's#return FIRST_READ_MS;#return MIN_READ_MS;#'
  mutate case "a later read has no 1 s floor" 's#Math.max(MIN_READ_MS, BUDGET_MS - (nowMs - firstEndedMs))#(BUDGET_MS - (nowMs - firstEndedMs))#'
  mutate pin  "DozeApplyRetry.run is not called" 's#DozeApplyRetry.run(() -> {#((java.util.function.BooleanSupplier) () -> {#'
  mutate pin  "the reset runs outside PUSH_DOZE_LOCK" 's#^                synchronized (PUSH_DOZE_LOCK) {#                {#'
  # NWP-20261117-06: the session's capture decision, and the DOZE-ARM send.
  mutate case "mayCapture refuses ARMED" 's#return !"UNARMED".equals(reply);#return reply == null || "".equals(reply) || "NONE".equals(reply);#'
  mutate case "mayCapture refuses NONE" 's#return !"UNARMED".equals(reply);#return !"UNARMED".equals(reply) \&\& !"NONE".equals(reply);#'
  mutate case "mayCapture refuses an empty reply" 's#return !"UNARMED".equals(reply);#return !"UNARMED".equals(reply) \&\& !"".equals(reply);#'
  mutate case "mayCapture refuses no reply (null)" 's#return !"UNARMED".equals(reply);#return reply != null \&\& !"UNARMED".equals(reply);#'
  mutate case "mayCapture lets UNARMED capture" 's#return !"UNARMED".equals(reply);#return true;#'
  mutate pin  "the DOZE-ARM send moved inside the lock" 's#^\( *\)\(String ack = DaemonSocket.roundTrip("DOZE-ARM.*\)$#\1synchronized (PUSH_DOZE_LOCK) {\n\1\2\n\1}#'
  mutate pin  "DOZE-ARM always says armed" 's#armed\[0\] ? "armed" : "unarmed"#"armed"#'
  mutate pin  "the arm outcome never reaches DOZE-ARM" '/^ *armed\[0\] = live;/d'
  mutate pin  "DOZE-ARM sent before the arm decision" '/DaemonSocket.roundTrip("DOZE-ARM\\n/d; s#^            boolean held = DozeApplyRetry.run(() -> {#            String ack = DaemonSocket.roundTrip("DOZE-ARM\\n" + uid + "\\n" + (armed[0] ? "armed" : "unarmed") + "\\n", 3000);\n&#'
  mutate pin  "the earlier arm is dropped after the attempts" '/^        DozeAppsMirror.disarmLiveRecord(); /d; s#^\(            }, android.os.SystemClock::elapsedRealtime, android.os.SystemClock::sleep);\)$#\1\n            DozeAppsMirror.disarmLiveRecord();#'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
