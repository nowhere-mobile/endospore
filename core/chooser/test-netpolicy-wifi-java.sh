#!/usr/bin/env bash
# test-netpolicy-wifi-java.sh [--mutate] -- the gate's netpolicy Wi-Fi reset, under javac (NWP-20261210-17).
#
# WHY THIS IS COMMITTED. netpolicy keeps a session's Wi-Fi data warnings and limits device-wide and outside every
# user; docs/product-decisions.md 2026-11-14 (G06) decided the gate resets netpolicy's Wi-Fi templates through the
# platform and keeps the rest (the owner's mobile limits, the per-uid background policy). NetPolicyWifi.java is pure
# and runs under javac against NetPolicyWifiCases (P1-P6). NetPolicyReceiver and the manifest cannot compile off the
# build host, so tests/netpolicy-wifi/run.sh pins them as data (G1-G8, X1-X6). The build host's `m NowhereChooser`
# compiles the glue.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2).
#
#   bash test-netpolicy-wifi-java.sh            # the cases and pins
#   bash test-netpolicy-wifi-java.sh --mutate   # ... plus broken copies that must each FAIL the named case
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/src/com/nowhere/chooser"
PW="$S/NetPolicyWifi.java"; RC="$S/NetPolicyReceiver.java"; MF="$HERE/AndroidManifest.xml"
RUN="$HERE/tests/netpolicy-wifi/run.sh"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
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
for f in "$PW" "$RC" "$MF" "$RUN"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W

echo "== cases and pins"
bash "$RUN" "$PW" "$RC" "$MF"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its named case; one that does not apply, or compile, is a failure)"
# mut <label> <PW|RC|MF> <perl-expr> <convicting case, e.g. P1> <lines that must differ>
# A mutant whose run exits 0 SURVIVED; it is convicted only by exit 1 AND a `--- FAIL: <case>` line.
mut() {
  local d src name rc out changed
  d=$(mktemp -d -p "$W")
  cp "$PW" "$d/NetPolicyWifi.java"; cp "$RC" "$d/NetPolicyReceiver.java"; cp "$MF" "$d/AndroidManifest.xml"
  case "$2" in PW) name=NetPolicyWifi.java ;; RC) name=NetPolicyReceiver.java ;; MF) name=AndroidManifest.xml ;;
    *) echo "  ERROR     $1 -- unknown file $2"; rm -rf "$d"; return 1 ;; esac
  src="$d/$name"; cp "$src" "$src.orig"
  if ! perl -0pi -e "$3" "$src"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$src" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src.orig" "$src"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$src.orig" "$src" | grep -c '^[<>]' || true)
  if [ "$changed" -ne "$5" ]; then
    echo "  ERROR     $1 -- the mutation changed $changed line(s), expected $5"; rm -rf "$d"; return 1; fi
  out=$(bash "$RUN" "$d/NetPolicyWifi.java" "$d/NetPolicyReceiver.java" "$d/AndroidManifest.xml" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) case "$out" in
         *"--- FAIL: $4:"*) echo "  convicted $1 (by $4)"; return 0 ;;
         *) echo "  WRONG     $1 -- failed, but not by $4"; return 1 ;;
       esac ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 keep() is inverted" PW 's/k\[i\] = !wifi;/k[i] = wifi;/' P1 2 || fails=$((fails+1))
mut "M2 removed() counts the kept" PW 's/for \(boolean k : keep\) if \(!k\) n\+\+;/for (boolean k : keep) if (k) n++;/' P1 2 || fails=$((fails+1))
mut "M3 reply() is always OK NONE" PW 's/return removed <= 0 \? OK_NONE : OK_RESET \+ " " \+ removed;/return OK_NONE;/' P3 2 || fails=$((fails+1))
mut "M4 errLine() passes an unknown reason through" PW 's/\(REASONS\.contains\(r\) \? r : R_FAILED\)/r/' P5 2 || fails=$((fails+1))
mut "M5 the removed > 0 guard is dropped" RC 's/if \(removed > 0\) npm\.setNetworkPolicies/npm.setNetworkPolicies/' G3 2 || fails=$((fails+1))
mut "M6 the receiver is exported" MF 's/(NetPolicyReceiver" android:exported=")false"/${1}true"/' G2 2 || fails=$((fails+1))
mut "M7 the uses-permission is removed" MF 's/ *<uses-permission android:name="android\.permission\.MANAGE_NETWORK_POLICY"\/>\n//' G1 1 || fails=$((fails+1))
mut "M8 a Log line names p.template" RC 's/(\n( *)boolean\[\] keep = NetPolicyWifi\.keep\(rules, wifiRules\(\)\);\n)/$1$2for (NetworkPolicy p : all) Log.i(TAG, "policy " + p.template);\n/' G6 1 || fails=$((fails+1))
mut "M9 the user-0 check is removed" RC 's/ *if \(UserHandle\.myUserId\(\) != 0\) \{\n.*?\n *return;\n *\}\n//s' G4 4 || fails=$((fails+1))
mut "M10 the receiver sets a uid policy" RC 's/(\n( *)if \(removed > 0\) npm\.setNetworkPolicies)/\n$2npm.setUidPolicy(0, 0);$1/' G8 1 || fails=$((fails+1))
# Control: a comment edit must survive (the pins read code, not prose).
cd_=$(mktemp -d -p "$W")
cp "$PW" "$cd_/NetPolicyWifi.java"; cp "$RC" "$cd_/NetPolicyReceiver.java"; cp "$MF" "$cd_/AndroidManifest.xml"
perl -0pi -e 's/(\/\*\* MATCH_WIFI, plus MATCH_WIFI_WILDCARD)/$1 (control edit)/' "$cd_/NetPolicyReceiver.java"
if cmp -s "$RC" "$cd_/NetPolicyReceiver.java"; then echo "  ERROR     control -- the comment edit changed nothing"; fails=$((fails+1))
elif bash "$RUN" "$cd_/NetPolicyWifi.java" "$cd_/NetPolicyReceiver.java" "$cd_/AndroidManifest.xml" >/dev/null 2>&1; then
  echo "  control   a comment edit survives"
else echo "  ERROR     control -- a comment edit failed the suite"; fails=$((fails+1)); fi
rm -rf "$cd_"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
