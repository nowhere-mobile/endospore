#!/usr/bin/env bash
# test-wifi-forget-trace-java.sh [--mutate] -- the gate's Wi-Fi mirror names which of Q027's three re-add paths ran,
# through gate.log's closed verbs (NWP-20261205-17).
#
# WHY THIS IS COMMITTED. Q027 (docs/product-decisions.md, 2026-10-20) orders a lynx repro of "a network forgotten at
# the gate comes back" before the fix, and names three paths that can re-add it: an adopt pass still running, an
# in-session capture that landed after the gate collected the queue, or a parked session that captured its own copy
# again. A locked build gives no logcat, so the gate report must name the path. WifiForgetTrace.java is the pure part
# (a RAM-only set of forgotten SSIDs, the count of adopt runs in flight, the verb pickers, and removeAndLookup, which
# looks the SSID up by the very id WifiForget removes); it is compiled UNCHANGED with WifiForget.java under javac and run with core/chooser/tests/wifi-forget-trace/WifiForgetTraceCases.java. The PINS read
# ChooserActivity.java and core/agent/gate_log.go (comments stripped) as data: every verb is in gateLogVerbs and `n`
# in gateLogKeys, maybeMirrorWifi ends its adopt run in a finally, forgetWifi records an SSID only on an OK reply, and
# no logcat line prints a trace value. The chooser cannot be compiled off the build host, so the call sites are pinned
# by source. What it does NOT prove: which path runs on lynx, which needs the repro and a gate report from a device.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS.
#
#   bash test-wifi-forget-trace-java.sh            # the cases and the pins
#   bash test-wifi-forget-trace-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
WFT="$DIR/WifiForgetTrace.java"
WF="$DIR/WifiForget.java"
CA="$DIR/ChooserActivity.java"
GL="$root/core/agent/gate_log.go"
CASES="$root/core/chooser/tests/wifi-forget-trace/WifiForgetTraceCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl" >&2; exit 2; }
export TMPDIR="$W"
"$JAVAC" -J-Djava.io.tmpdir="$W" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
for f in "$WF" "$CA" "$GL" "$CASES"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }; done

# strip <in> <out>: drop // and /* */ comments outside string and char literals.
strip() {
  perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : ""}gse' "$1" > "$2"
}

# has <file> <label> <fixed text>: a --- FAIL line when the file lacks the text.
has() {
  if grep -qF -- "$3" "$1"; then echo "--- PASS: pin: $2"; return 0; fi
  echo "--- FAIL: pin: $2"; return 1
}

# lacks <file> <label> <fixed text>: a --- FAIL line when the file holds the text.
lacks() {
  if grep -qF -- "$3" "$1"; then echo "--- FAIL: pin: $2"; return 1; fi
  echo "--- PASS: pin: $2"; return 0
}

# count <file> <fixed text>: how many times the text occurs.
count() {
  perl -0ne 'BEGIN { $n = 0 } $t = $ENV{PIN_TEXT}; $n++ while /\Q$t\E/g; END { print $n }' "$1"
}

# once <file> <label> <fixed text>: a --- FAIL line unless the text occurs exactly once.
once() {
  local n
  n=$(PIN_TEXT="$3" count "$1")
  if [ "$n" = 1 ]; then echo "--- PASS: pin: $2"; return 0; fi
  echo "--- FAIL: pin: $2 (found $n)"; return 1
}

# before <file> <label> <first text> <second text>: a --- FAIL line unless both occur and the first comes first.
before() {
  local p1 p2
  p1=$(grep -bo -F -- "$3" "$1" | head -1 | cut -d: -f1)
  p2=$(grep -bo -F -- "$4" "$1" | head -1 | cut -d: -f1)
  if [ -n "$p1" ] && [ -n "$p2" ] && [ "$p1" -lt "$p2" ]; then echo "--- PASS: pin: $2"; return 0; fi
  echo "--- FAIL: pin: $2"; return 1
}

# suite <WifiForgetTrace.java> <ChooserActivity.java> <gate_log.go> -> 0 pass, 1 a case or a pin failed, 3 compile.
suite() {
  local wft="$1" ca="$2" gl="$3" d s g w mm fw ck verbs vt v nv logs rc=0
  [ -f "$wft" ] || { echo "--- FAIL: WifiForgetTrace.java does not exist"; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser" "$d/out"
  cp "$wft" "$d/src/com/nowhere/chooser/WifiForgetTrace.java"
  cp "$WF" "$d/src/com/nowhere/chooser/WifiForget.java"
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -nowarn -d "$d/out" \
    "$d/src/com/nowhere/chooser/WifiForgetTrace.java" "$d/src/com/nowhere/chooser/WifiForget.java" "$CASES" 2>"$d/javac.err" || { head -20 "$d/javac.err"; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.WifiForgetTraceCases || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 1 ] || return 3

  s=$(mktemp -p "$W") || return 3
  g=$(mktemp -p "$W") || return 3
  w=$(mktemp -p "$W") || return 3
  strip "$ca" "$s"
  strip "$gl" "$g"
  strip "$wft" "$w"

  # P1 every verb WifiForgetTrace can return is in gateLogVerbs, and n is in gateLogKeys.
  vt=$(mktemp -p "$W") || return 3
  perl -0ne 'print $1 if /var gateLogVerbs = map\[string\]bool\{(.*?)\n\}/s' "$g" > "$vt"
  if [ ! -s "$vt" ]; then echo "--- FAIL: pin: P1 cannot cut gateLogVerbs"; rc=1; fi
  verbs=$(perl -ne 'print "$1\n" while /"(wifi-[a-z-]+)"/g' "$w" | sort -u)
  nv=$(printf '%s\n' "$verbs" | grep -c .)
  if [ "$nv" -ge 7 ]; then echo "--- PASS: pin: P1 WifiForgetTrace returns $nv distinct wifi- verbs"
  else echo "--- FAIL: pin: P1 WifiForgetTrace returns $nv distinct wifi- verbs, want at least 7"; rc=1; fi
  for v in $verbs; do
    has "$vt" "P1 \"$v\" is in gateLogVerbs" "\"$v\": true" || rc=1
  done
  if perl -ne '$f = 1 if /^var gateLogKeys = map\[string\]bool\{.*"n": true/; END { exit($f ? 0 : 1) }' "$g"; then
    echo "--- PASS: pin: P1 \"n\": true is in gateLogKeys"
  else
    echo "--- FAIL: pin: P1 \"n\": true is not in gateLogKeys"; rc=1
  fi

  # The three cuts: maybeMirrorWifi, forgetWifi and the Forget click thread.
  mm=$(mktemp -p "$W") || return 3
  fw=$(mktemp -p "$W") || return 3
  ck=$(mktemp -p "$W") || return 3
  perl -0ne 'print $1 if /(    void maybeMirrorWifi\(\) \{.*?\n    \}\n)/s' "$s" > "$mm"
  perl -0ne 'print $1 if /(^[^\n]*private String forgetWifi\(\).*?)(?=^[^\n]*\bprivate [^\n]*\()/ms' "$s" > "$fw"
  perl -0ne 'print $1 if /forget\.setOnClickListener\(v -> \{(.*?)\n        \}\);\n/s' "$s" > "$ck"
  [ -s "$mm" ] || { echo "--- FAIL: pin: cannot cut maybeMirrorWifi"; return 1; }
  [ -s "$fw" ] || { echo "--- FAIL: pin: cannot cut forgetWifi"; return 1; }
  [ -s "$ck" ] || { echo "--- FAIL: pin: cannot cut the forget click thread"; return 1; }

  # P2 maybeMirrorWifi starts one adopt run and finishes it inside a finally.
  once "$mm" "P2 maybeMirrorWifi calls WifiForgetTrace.adoptStarted() once" 'WifiForgetTrace.adoptStarted();' || rc=1
  once "$mm" "P2 maybeMirrorWifi calls WifiForgetTrace.adoptFinished() once" 'WifiForgetTrace.adoptFinished()' || rc=1
  if perl -0ne 'exit(/finally\s*\{[^{}]*WifiForgetTrace\.adoptFinished\(\)/ ? 0 : 1)' "$mm"; then
    echo "--- PASS: pin: P2 adoptFinished() sits inside a finally"
  else
    echo "--- FAIL: pin: P2 adoptFinished() is not inside a finally"; rc=1
  fi
  before "$mm" "P2 adoptStarted() comes before the pass loop" 'WifiForgetTrace.adoptStarted();' 'for (int pass = 0; pass < 3; pass++) {' || rc=1

  # P3 forgetWifi records the SSID only on an OK reply; the click thread never records and sends the forget verb.
  once "$fw" "P3 forgetWifi calls WifiForgetTrace.forgot( once" 'WifiForgetTrace.forgot(' || rc=1
  has "$fw" "P3 forgetWifi calls forgot( only inside a branch on an OK reply" \
    'if (r.startsWith("OK") && removedSsid[0] != null) WifiForgetTrace.forgot(removedSsid[0]);' || rc=1
  once "$fw" "P3 forgetWifi still calls WifiForget.run( once" 'WifiForget.run(' || rc=1
  has "$fw" "P3 Ops.remove looks the SSID up by the id it removes, into the holder forgot( reads" \
    'return WifiForgetTrace.removeAndLookup(netId, id -> wm.removeNetwork(id), ssidOf, removedSsid);' || rc=1
  once "$fw" "P3 forgetWifi reads the connected id once (WifiForget's connectedNetId), never for the SSID" \
    'getConnectionInfo()' || rc=1
  lacks "$ck" "P3 the click thread never calls WifiForgetTrace.forgot(" 'WifiForgetTrace.forgot(' || rc=1
  has "$ck" "P3 the click thread sends the forget verb with the in-flight count" \
    'GateTrace.ev(WifiForgetTrace.forgetVerb(ok, inFlight), "n", WifiForgetTrace.clampCount(inFlight));' || rc=1
  before "$ck" "P3 the in-flight count is read before the UI work" 'final int inFlight = WifiForgetTrace.inFlight();' 'runOnUiThread(' || rc=1
  before "$ck" "P3 the forget verb is sent after the UI work" 'runOnUiThread(' 'GateTrace.ev(WifiForgetTrace.forgetVerb(' || rc=1

  # P4 control: both cuts use WifiForgetTrace. Then no logcat line prints a trace value.
  has "$mm" "P4 control: maybeMirrorWifi uses WifiForgetTrace" 'WifiForgetTrace.' || rc=1
  has "$ck" "P4 control: the click thread uses WifiForgetTrace" 'WifiForgetTrace.' || rc=1
  logs=$(cat "$mm" "$ck" "$fw" | perl -0ne 'while (/android\.util\.Log\.\w+\((.*?)\);/gs) { $l = $1; print "$l\n" if $l =~ /WifiForgetTrace|readd|addedSsids|parked|inFlight|adopting|ssid\b/ }')
  if [ -z "$logs" ]; then
    echo "--- PASS: pin: P4 no android.util.Log line prints a WifiForgetTrace value"
  else
    echo "--- FAIL: pin: P4 an android.util.Log line prints a WifiForgetTrace value: $logs"; rc=1
  fi

  # P5 maybeMirrorWifi probes the cold lock, traces the collected queue and traces each pass's re-adds.
  has "$mm" "P5 maybeMirrorWifi probes GET-COLDLOCK for parked" \
    'parked = RerunReapRule.kindOf(pollDaemon("GET-COLDLOCK\n")) == RerunReapRule.COLD;' || rc=1
  has "$mm" "P5 maybeMirrorWifi sends the collect verb with the queue size" \
    'GateTrace.ev(WifiForgetTrace.collectVerb(parked), "n", WifiForgetTrace.clampCount(ents.size()));' || rc=1
  before "$mm" "P5 the collect verb is sent after the empty-queue return" 'if (ents.isEmpty()) return;' 'WifiForgetTrace.collectVerb(parked)' || rc=1
  before "$mm" "P5 SSIDs added are collected inside if (id >= 0)" 'if (id >= 0) {' 'addedSsids.add(e[0]);' || rc=1
  has "$mm" "P5 each pass counts the re-adds" 'int readd = WifiForgetTrace.readdCount(addedSsids);' || rc=1
  has "$mm" "P5 each pass sends the re-add verb only when it re-added" \
    'if (readd > 0) GateTrace.ev(WifiForgetTrace.readdVerb(pass), "n", WifiForgetTrace.clampCount(readd));' || rc=1
  before "$mm" "P5 the re-adds are traced after the pass's WIFI-ADOPT" 'WifiMirrorLine.adoptRequest(pass, added, present, failed)' 'int readd = WifiForgetTrace.readdCount(addedSsids);' || rc=1
  return "$rc"
}

echo "== $WFT"
out=$(suite "$WFT" "$CA" "$GL" 2>&1); rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
echo "PASS"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a --- FAIL; one that does not apply or compile is a failure)"
# mut <label> <which: wft|ca|gl> <perl-expr>
mut() {
  local d src m wf cf gf rc o
  d=$(mktemp -d -p "$W")
  wf="$WFT"; cf="$CA"; gf="$GL"
  case "$2" in wft) src="$WFT" ;; ca) src="$CA" ;; gl) src="$GL" ;; esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  case "$2" in wft) wf="$m" ;; ca) cf="$m" ;; gl) gf="$m" ;; esac
  o=$(suite "$wf" "$cf" "$gf" 2>&1); rc=$?
  case "$rc" in
    1) if [[ "$o" == *"--- FAIL"* ]]; then echo "  convicted $1"; return 0
       else echo "  BROKEN    $1 -- rc=1 without a --- FAIL"; return 1; fi ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 (R1, R2) readdVerb swaps pass 0 and late"           wft 's/pass <= 0 \? "wifi-readd" : "wifi-readd-late"/pass <= 0 ? "wifi-readd-late" : "wifi-readd"/' || fails=$((fails+1))
mut "M2 (F2) forgetVerb ignores inFlight"                    wft 's/\n[^\n]*if \(inFlight > 0\) return "wifi-forget-midadopt";//' || fails=$((fails+1))
mut "M3 (C1) collectVerb ignores parked"                     wft 's/return parked \? "wifi-collect-parked" : "wifi-collect";/return "wifi-collect";/' || fails=$((fails+1))
mut "M4 (D1) readdCount counts every SSID"                   wft 's/s != null && FORGOTTEN\.contains\(s\)/s != null/' || fails=$((fails+1))
mut "M5 (P2) adoptFinished not in a finally"                 ca  's/\} finally \{\n(\s*)if \(adopting\) WifiForgetTrace\.adoptFinished\(\);\n\s*\}/}\n$1WifiForgetTrace.adoptFinished();/' || fails=$((fails+1))
mut "M6 (P3) forgot( called on an ERR reply"                 ca  's/if \(r\.startsWith\("OK"\) && removedSsid\[0\] != null\) WifiForgetTrace\.forgot/if (removedSsid[0] != null) WifiForgetTrace.forgot/' || fails=$((fails+1))
mut "M7 (P1) wifi-readd-late missing from gateLogVerbs"      gl  's/ "wifi-readd-late": true,//' || fails=$((fails+1))
mut "M8 (P1) key n missing from gateLogKeys"                 gl  's/, "n": true\}/}/' || fails=$((fails+1))
mut "M9 (I3) adoptFinished decrements below 0"               wft 's/IN_FLIGHT\.updateAndGet\(v -> v > 0 \? v - 1 : 0\)/IN_FLIGHT.decrementAndGet()/' || fails=$((fails+1))
mut "M10 (K4) clampCount has no upper bound"                 wft 's/n < 0 \? 0 : n > MAX_COUNT \? MAX_COUNT : n/n < 0 ? 0 : n/' || fails=$((fails+1))
mut "M11 (P3) the click thread calls forgot("                ca  's/(\n(\s*)final String r = forgetWifi\(\);\n)/$1$2WifiForgetTrace.forgot("x");\n/' || fails=$((fails+1))
mut "M12 (P4) a logcat line prints the re-add count"         ca  's/(\n(\s*)int readd = WifiForgetTrace\.readdCount\(addedSsids\);\n)/$1$2android.util.Log.i("NowhereChooser", "re-added " + readd);\n/' || fails=$((fails+1))
mut "M13 (P5) the collect verb is not sent"                  ca  's/\n[^\n]*GateTrace\.ev\(WifiForgetTrace\.collectVerb\(parked\)[^\n]*//' || fails=$((fails+1))
mut "M14 (B1) removeAndLookup looks the SSID up by another id than it removes" wft 's/ssid = lookup\.ssidOf\(netId\);/ssid = lookup.ssidOf(-netId);/' || fails=$((fails+1))
mut "M15 (B2) removeAndLookup keeps the SSID of a refused removal" wft 's/removed\[0\] = ok \? ssid : null;/removed[0] = ssid;/' || fails=$((fails+1))
mut "M16 (P3) forgetWifi reads the connected id again for the SSID" ca 's/ssidOf = netId -> \{/ssidOf = unused -> { int netId = wm.getConnectionInfo().getNetworkId();/' || fails=$((fails+1))
mut "M17 (P3) forgetWifi's remove does not look the SSID up" ca 's/return WifiForgetTrace\.removeAndLookup\(netId, id -> wm\.removeNetwork\(id\), ssidOf, removedSsid\);/return wm.removeNetwork(netId);/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
