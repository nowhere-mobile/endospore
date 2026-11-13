#!/usr/bin/env bash
# test-vpn-report-keys-java.sh [--mutate] -- NWP-20261202-04: the always-on VPN keys of an in-session issue report.
# Runs core/chooser/tests/vpn-report-keys: the chooser's pure VpnReportKeys, compiled against its cases ALONE and
# EXECUTED, plus source checks:
#   s1 ProfileActivity.reportStatus calls VpnReportKeys.keys( exactly once and names the three Secure keys
#      always_on_vpn_app, always_on_vpn_lockdown and nowhere_vpn_lockdown_pending;
#   s2 VpnReportKeys.java imports nothing from android;
#   s3 nothing on the path logs: no Log. in reportStatus, in vpnReportFile or in VpnReportKeys.java.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies of VpnReportKeys.java, each of which must FAIL a named case, and
# against broken copies of the sources the source checks read, each of which a named check must refuse. A mutant that
# does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-vpn-report-keys-java.sh            # the cases and the source checks
#   bash test-vpn-report-keys-java.sh --mutate   # ... plus the mutants
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
  echo "test-vpn-report-keys-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
# ONE temp root: every class dir and mutant tree lives under it, and the EXIT trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
run() { JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/vpn-report-keys/run.sh" "$1" "$(mktemp -d -p "$W")"; }
run "$ROOT" || { echo "FAILED"; exit 1; }

# body <file> <start pattern>: the method that starts at the pattern, up to its closing brace at four spaces.
body() { awk -v p="$2" 'index($0, p){f=1} f{print} f&&/^    }$/{exit}' "$1"; }

src_checks() {
  local pa vk rs rf n k miss bad hit
  pa="$1/$CH/ProfileActivity.java"
  vk="$1/$CH/VpnReportKeys.java"
  bad=0
  rs=$(body "$pa" 'static org.json.JSONObject reportStatus(')
  rf=$(body "$pa" 'private static String vpnReportFile(')
  n=$(grep -cF 'VpnReportKeys.keys(' <<<"$rs" || true)
  miss=
  for k in '"always_on_vpn_app"' '"always_on_vpn_lockdown"' '"nowhere_vpn_lockdown_pending"'; do
    [[ $rs == *"$k"* ]] || miss="$miss $k"
  done
  if [ -n "$rs" ] && [ "$n" = 1 ] && [ -z "$miss" ]; then
    echo "ok   s1 reportStatus calls VpnReportKeys.keys once and names the three Secure keys"
  else echo "FAIL s1 reportStatus must call VpnReportKeys.keys( once (found $n) and name the Secure keys (missing:${miss:- none})"; bad=1; fi
  hit=$(grep -n '^import android' "$vk" || true)
  if [ -f "$vk" ] && [ -z "$hit" ]; then echo "ok   s2 VpnReportKeys.java imports nothing from android"
  else echo "FAIL s2 VpnReportKeys.java must import nothing from android: ${hit:-no file}"; bad=1; fi
  hit=$(grep -n 'Log\.' <<<"$rs$rf" || true)
  hit="$hit$(grep -n 'Log\.' "$vk" || true)"
  if [ -n "$rf" ] && [ -z "$hit" ]; then echo "ok   s3 reportStatus, vpnReportFile and VpnReportKeys log nothing"
  else echo "FAIL s3 the VPN report path must log nothing (vpnReportFile found: $([ -n "$rf" ] && echo yes || echo no)): $hit"; bad=1; fi
  return "$bad"
}
src_checks "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <perl-expr over VpnReportKeys.java> <case id the mutant must fail>
  local d f out rc
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  f="$d/$CH/VpnReportKeys.java"
  cp "$ROOT/$CH/VpnReportKeys.java" "$f"
  if ! perl -0pi -e "$2" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/VpnReportKeys.java" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(run "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if grep -qF -- "error:" <<<"$out"; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $3 " <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the case '$3' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$3')"
}
smut() { # smut <label> <file under $CH> <perl-expr over it> <source check the mutant must fail>
  local d f out rc
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  cp "$ROOT/$CH/ProfileActivity.java" "$ROOT/$CH/VpnReportKeys.java" "$d/$CH/"
  f="$d/$CH/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(src_checks "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if ! grep -qF -- "FAIL $4 " <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the check '$4' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
mut "M1 vpn_live emits the live package" 's/else live = "other";/else live = liveApp;/' \
  "c9" || fails=$((fails+1))
mut "M2 pending compared with the record's package" 's/livePend\.equals\(liveApp\)/livePend.equals(rec[1])/' \
  "c2" || fails=$((fails+1))
mut "M3 any non-0 live lock maps to 1" 's/if \("1"\.equals\(liveLock\)\) block = "1";/if (!"0".equals(liveLock)) block = "1";/' \
  "c8" || fails=$((fails+1))
mut "M4 unread becomes none" 's/m\.put\("vpn_live", "unread"\);/m.put("vpn_live", "none");/' \
  "c4" || fails=$((fails+1))
mut "M5 vpn_record_block emitted for off" \
  's/if \("set"\.equals\(rec\[0\]\)\) m\.put\("vpn_record_block"/if ("set".equals(rec[0]) || "off".equals(rec[0])) m.put("vpn_record_block"/' \
  "c6" || fails=$((fails+1))
mut "M6 a bad package accepted as set" 's/return false;/return true;/' \
  "c7" || fails=$((fails+1))
smut "A1 the VpnReportKeys.keys loop deleted from reportStatus" ProfileActivity.java \
  's/\n\s*for \(java\.util\.Map\.Entry<String, String> e\n\s*: VpnReportKeys\.keys\([^\n]*\n[^\n]*\n\s*\}//' \
  "s1" || fails=$((fails+1))
smut "B1 VpnReportKeys imports android" VpnReportKeys.java \
  's/^package com\.nowhere\.chooser;\n/package com.nowhere.chooser;\n\nimport android.util.Log;\n/' \
  "s2" || fails=$((fails+1))
smut "B2 vpnReportFile logs its read error" ProfileActivity.java \
  's/(\} catch \(Throwable t\) \{\n)(\s*)(return VpnReportKeys\.UNREADABLE;)/$1$2android.util.Log.w("NowhereChooser", "vpn report read", t);\n$2$3/' \
  "s3" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
