#!/usr/bin/env bash
# test-wifi-join-trace-java.sh [--mutate] -- NWP-20261207-15: every gate Wi-Fi join writes one gate.log line.
# Backlog section B, "The gate may be unable to join a WPA3-SAE-only AP at all ... (L6)" (docs/wifi-retention-spec.md
# L6, hardware check HW4). The row is an OPEN QUESTION whose answer is a device read, and a locked user build gives no
# logcat, so the gate now records each join: `wifi-join-<ok|assoc|noassoc|addfail|nowifi|err> sec=<n>`, where n is
# hundreds = reused a saved entry, tens = how the gate configured it (1 open, 2 psk, 3 eap), units = the AP's
# advertised security in the gate's last scan (0 not seen ... 4 sae only ... 7 other). Never the SSID.
# Compiles the chooser's pure WifiJoinTrace with core/chooser/tests/wifi-join-trace ALONE and EXECUTES the cases
# (C1-C4) against core/agent/gate_log.go, then checks the REAL ChooserActivity with comments dropped (S1-S4):
#   C1  apClass: [ESS] 1, psk 2, psk+sae transition 3, sae only 4, eap 5, owe 6, wep 7, null 0.
#   C2  joinCode open/psk/eap -> 1/2/3, else 0; code = (reused ? 100 : 0) + 10 * joinCode + apFor (124, 10, 34, 110).
#   C3  rememberScan replaces the whole map: an SSID absent from the newest scan reads 0; empty and null clear it.
#   C4  the six verb constants are in gate_log.go's gateLogVerbs and "sec" in gateLogKeys; the constants' names.
#   S1  the 6-argument connectWifi calls traceJoin exactly six times, one verb before each exit, all with
#       `reused, pw, identity, ssid`; `reused = true;` once, inside the findNet fallback.
#   S2  traceJoin sends GateTrace.ev(verb, WifiJoinTrace.KEY, WifiJoinTrace.code(...)) inside its own try/catch.
#   S3  scanWifi fills the map in the results loop and calls WifiJoinTrace.rememberScan(ap) once, after the loop.
#   S4  no android.util.Log call in connectWifi carries ssid; the catch keeps its Log.w and then traces ERR.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against broken copies of WifiJoinTrace, ChooserActivity and gate_log.go (J1-J9), each of which
# must FAIL a named check. A mutant that does not apply (INERT) or does not compile (BROKEN) counts as a failure.
#
#   bash test-wifi-join-trace-java.sh            # the cases and the source checks
#   bash test-wifi-join-trace-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-wifi-join-trace-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-wifi-join-trace-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
GL=core/agent/gate_log.go
CASES=$ROOT/core/chooser/tests/wifi-join-trace/WifiJoinTraceCases.java

# cases <root>: compile <root>'s WifiJoinTrace with the cases into a fresh dir and run them against <root>'s gate_log.go.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/WifiJoinTrace.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.WifiJoinTraceCases "$1/$GL"
}

# code <file> [<signature line>]: the method from its signature to its closing `    }` (the whole file with no
# signature), with whole-line comments dropped and trailing `//` comments stripped (a `//` inside a string is kept).
code() {
  perl -e '
    my ($f, $sig) = @ARGV; open(my $h, "<", $f) or die "$f: $!";
    my $in = defined($sig) ? 0 : 1;
    while (my $l = <$h>) {
      if (!$in) { next unless index($l, $sig) == 0; $in = 1; }
      last if defined($sig) && $l =~ /^    \}$/;
      next if $l =~ m{^\s*(//|\*|/\*)};
      $l =~ s{^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?![/*]))*)//.*$}{$1};
      print $l;
    }' "$@"
}

# pin <id> <what> <perl body over $c, exit 0 on pass> <<<"$code": one source check.
pin() {
  if perl -0e 'my $c = do { local $/; <STDIN> }; '"$3"; then echo "ok $1 $2"; else echo "FAIL $1 $2"; return 1; fi
}

# sources <root>: S1-S4 over <root>'s ChooserActivity.connectWifi, traceJoin and scanWifi.
sources() {
  local r=$1 cw tj sw bad=0
  cw=$(code "$r/$CH/ChooserActivity.java" "    private String connectWifi(String ssid, String pw, String identity, boolean ttls, boolean hidden, int macSel) {")
  tj=$(code "$r/$CH/ChooserActivity.java" "    private void traceJoin(String verb, boolean reused, String pw, String identity, String ssid) {")
  sw=$(code "$r/$CH/ChooserActivity.java" "    private java.util.List<String[]> scanWifi(boolean[] canScanOut) {")
  if [ -z "$cw" ]; then echo "FAIL S1 connectWifi not found"; bad=1
  else
    pin S1 "connectWifi traces each of its six exits once, with its own verb, before the return" '
      my $n = () = $c =~ /traceJoin\(/g; exit 1 unless $n == 6;
      my $a = () = $c =~ /traceJoin\(WifiJoinTrace\.[A-Z]+, reused, pw, identity, ssid\);/g; exit 1 unless $a == 6;
      for my $v (qw(OK ASSOC NOASSOC ADDFAIL NOWIFI ERR)) {
        my $k = () = $c =~ /traceJoin\(WifiJoinTrace\.$v,/g; exit 1 unless $k == 1;
      }
      exit 1 unless $c =~ /if \(wm == null\) \{\s*traceJoin\(WifiJoinTrace\.NOWIFI,[^;]*\);\s*return "ERR no Wi-Fi service/;
      exit 1 unless $c =~ /if \(netId < 0\) \{\s*traceJoin\(WifiJoinTrace\.ADDFAIL,[^;]*\);\s*return "ERR couldn.t add/;
      exit 1 unless $c =~ /NET_CAPABILITY_INTERNET\)\) \{\s*traceJoin\(WifiJoinTrace\.OK,[^;]*\);\s*return "OK";/;
      exit 1 unless $c =~ /if \(associated\) \{\s*traceJoin\(WifiJoinTrace\.ASSOC,[^;]*\);\s*return "OK";\s*\}/;
      exit 1 unless $c =~ /\}\s*traceJoin\(WifiJoinTrace\.NOASSOC,[^;]*\);\s*return "ERR couldn.t join/;
      exit 1 unless $c =~ /catch \(Throwable e\) \{[^}]*?traceJoin\(WifiJoinTrace\.ERR,[^;]*\);\s*return "ERR Wi-Fi connect failed/s;
      exit 1 unless $c =~ /^\s*boolean reused = false;\s*\n\s*try \{/m;
      my $r = () = $c =~ /reused = true;/g; exit 1 unless $r == 1;
      exit($c =~ /if \(netId >= 0\) \{ reused = true; cfg\.networkId = netId;/ ? 0 : 1);' <<<"$cw" || bad=1
  fi
  if [ -z "$tj" ]; then echo "FAIL S2 traceJoin not found"; bad=1
  else
    pin S2 "traceJoin sends the verb under WifiJoinTrace.KEY with WifiJoinTrace.code, inside its own try/catch" '
      my $e = q{GateTrace\.ev\(verb, WifiJoinTrace\.KEY, WifiJoinTrace\.code\(reused, WifiNetMatch\.joinSec\(pw, identity\), ssid\)\);};
      my $n = () = $c =~ /$e/g; exit 1 unless $n == 1;
      my $g = () = $c =~ /GateTrace\./g; exit 1 unless $g == 1;
      exit($c =~ /try \{\s*$e\s*\} catch \(Throwable/ ? 0 : 1);' <<<"$tj" || bad=1
  fi
  if [ -z "$sw" ]; then echo "FAIL S3 scanWifi not found"; bad=1
  else
    pin S3 "scanWifi records each SSID's class in the loop and calls rememberScan once, after it" '
      my $n = () = $c =~ /WifiJoinTrace\.rememberScan\(/g; exit 1 unless $n == 1;
      my $p = () = $c =~ /ap\.put\(ssid, WifiJoinTrace\.apClass\(r\.capabilities\)\);/g; exit 1 unless $p == 1;
      my $l = index($c, "for (android.net.wifi.ScanResult r : results)");
      my $b = index($c, "best.put(ssid,"); my $q = index($c, "ap.put(ssid,");
      my $m = index($c, "WifiJoinTrace.rememberScan(ap);"); my $o = index($c, "out.addAll(best.values());");
      exit 1 if $l < 0 || $b < 0 || $q < 0 || $m < 0 || $o < 0;
      exit(($l < $b && $b < $q && $q < $m && $m < $o && substr($c, $q, $m - $q) =~ /\}\s*$/) ? 0 : 1);' <<<"$sw" || bad=1
  fi
  if [ -n "$cw" ]; then
    pin S4 "no android.util.Log call in connectWifi carries ssid; the catch's record goes to gate.log too" '
      while ($c =~ /android\.util\.Log\.\w+\(([^;]*);/g) { exit 1 if $1 =~ /\bssid\b/; }
      exit($c =~ /catch \(Throwable e\) \{\s*android\.util\.Log\.w\("NowhereChooser", "wifi connect", e\);\s*traceJoin\(WifiJoinTrace\.ERR,/ ? 0 : 1);' <<<"$cw" || bad=1
  fi
  return "$bad"
}

# check <root>: 0 pass, 1 a failed check, 3 the cases did not compile.
check() {
  local rc=0 crc
  cases "$1"; crc=$?
  [ "$crc" -eq 3 ] && return 3
  [ "$crc" -eq 0 ] || rc=1
  sources "$1" || rc=1
  return "$rc"
}

check "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH" "$d/core/agent"
  for n in "$CH/WifiJoinTrace.java" "$CH/ChooserActivity.java" "$GL"; do
    cp "$ROOT/$n" "$d/$n"
  done
  f="$d/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -eq 3 ]; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then echo "  BROKEN    $1 -- it failed, but not '$4' (rc=$rc)"; return 1; fi
  echo "  convicted $1 (fails '$4')"
}
T=$CH/WifiJoinTrace.java
A=$CH/ChooserActivity.java
fails=0
mut "J1 SAE-only read as transition" "$T" 's/\? 3 : 4;/? 3 : 3;/' "C1 apClass(sae only)" || fails=$((fails+1))
mut "J2 PSK tested before SAE: transition and SAE-only collapse" "$T" 's/(\n[ \t]*if \(caps\.contains\("SAE"\)\)[^\n]*)(\n[ \t]*if \(caps\.contains\("PSK"\)\) return 2;)/$2$1/' "C1 apClass(psk+sae transition)" || fails=$((fails+1))
mut "J3 reused's 100 dropped" "$T" 's/\(reused \? 100 : 0\)/(reused ? 0 : 0)/' "C2 code(reused, psk, an sae-only AP)" || fails=$((fails+1))
mut "J4 rememberScan merges instead of replacing" "$T" 's/last = scan == null \? Collections\.<String, Integer>emptyMap\(\)\s*: Collections\.unmodifiableMap\(new HashMap<>\(scan\)\);/HashMap<String, Integer> m = new HashMap<>(last); if (scan != null) m.putAll(scan); last = m;/' "C3 apFor(a) after a scan without a" || fails=$((fails+1))
mut "J5 wifi-join-noassoc deleted from gateLogVerbs" "$GL" 's/ "wifi-join-noassoc": true,//' 'C4 "wifi-join-noassoc": true in gateLogVerbs' || fails=$((fails+1))
mut "J6 the ADDFAIL trace deleted" "$A" 's/\n[ \t]*traceJoin\(WifiJoinTrace\.ADDFAIL, reused, pw, identity, ssid\);//' S1 || fails=$((fails+1))
mut "J7 traceJoin sends key ms" "$A" 's/GateTrace\.ev\(verb, WifiJoinTrace\.KEY,/GateTrace.ev(verb, "ms",/' S2 || fails=$((fails+1))
mut "J8 the rememberScan call deleted" "$A" 's/^[ \t]*WifiJoinTrace\.rememberScan\(ap\);[^\n]*\n//m' S3 || fails=$((fails+1))
mut "J9 the catch's Log line names the SSID" "$A" 's/android\.util\.Log\.w\("NowhereChooser", "wifi connect", e\);/android.util.Log.w("NowhereChooser", "wifi connect " + ssid, e);/' S4 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
