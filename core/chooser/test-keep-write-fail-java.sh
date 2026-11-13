#!/usr/bin/env bash
# test-keep-write-fail-java.sh [--mutate] -- a store install whose keep-set write fails is not reported as kept
# (NWP-20261105-03), run under javac.
#
# WHY THIS IS COMMITTED. StoreInstaller.keepAutoImpl's catch answered `return true` when reading or writing
# nowhere-appkeep threw, so no keep line landed and the caller still heard "kept": StoreService.getApp replied "OK <pkg>",
# nApps said "<app> added.", and at sign-out appcode_seal sealed no code for the app, which was gone at the next sign-in
# with nothing having said so. keepAutoImpl now answers what is on disk (false unless the line landed), getAppReply maps
# not-kept with the over-plan gate open to "OK-UNSAVED", and nApps words it. The fail-open that stays is the over-plan
# GATE's, in the caller. core/chooser/tests/keep-write-fail/run.sh lifts keepAutoImpl and getAppReply verbatim by anchor,
# stubs what they call, and runs KeepWriteFailCases, then source-checks the nApps branch order (startsWith("OK") would
# swallow OK-UNSAVED if it came first).
#
# NWP-20261129-38: keepAutoImpl also answers true for an Off nApps default and writes no line (pinned here: "APPDEF_OFF
# -> kept, no write"), so a Get on a profile whose nApps default is Off (the Zero preset) still said "<app> added.", and
# nothing else keeps that app. getApp now reads the default and getAppReply answers "OK-OFF" when the app has no keep
# line; nApps words it. An app already kept still answers "OK". run.sh adds source checks on the OK-OFF branch order and
# on getApp's wiring, because getApp itself talks to the daemon and cannot run here.
#
# Against the sources before NWP-20261129-38 this suite exits 2: getAppReply has three parameters, so its four-parameter
# signature does not extract. Before NWP-20261105-03 getAppReply did not exist; run.sh stubs that case to return null,
# so its cases fail. Its mutants:
#   K1 the catch back to `return true`   K2 `wrote = true` moved above writeAtomic
#   K3 getAppReply maps not-kept-not-overPlan to OK-SESSION-ONLY   K4 the nApps OK-UNSAVED branch after the generic OK
#   K5 getAppReply answers OK under an Off default   K6 the nApps OK-OFF branch after the generic OK
#   K7 getApp passes false for the flag   K8 getApp drops the keepSetHas term
# What it does NOT prove: the wording on a device.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-keep-write-fail-java.sh            # the cases
#   bash test-keep-write-fail-java.sh --mutate   # ... plus broken copies that must each FAIL the cases
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SI="$HERE/src/com/nowhere/chooser/StoreInstaller.java"
SS="$HERE/src/com/nowhere/chooser/StoreService.java"
SA="$HERE/../napps/src/com/nowhere/napps/StoreActivity.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
RUN="$HERE/tests/keep-write-fail/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite did NOT run and does not skip: install a JDK or" \
       "run it on the build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$SI" ] && [ -f "$SS" ] && [ -f "$SA" ] && [ -f "$RUN" ] || { echo "FAIL: missing a source or $RUN" >&2; exit 2; }

# One root for everything this suite creates (run.sh's work dir, every mutant copy); one trap.
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export KEEP_WRITE_FAIL_TMP="$W"

# suite <StoreInstaller.java> <StoreService.java> <StoreActivity.java> -> 0 pass, 1 a case failed (only this may convict a
# mutant), 2 a member did not extract, 3 compile failure.
suite() { bash "$RUN" "$1" "$2" "$3"; }

echo "== $SI"
suite "$SI" "$SS" "$SA"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by behaviour; one that does not apply or compile is a failure)"
mut() { # mut <label> <si|ss|sa> <perl-expr> [<lines-that-must-change>]
  local d m rc changed src; d=$(mktemp -d -p "$W"); m="$d/mutant.java"
  case "$2" in si) src="$SI" ;; ss) src="$SS" ;; *) src="$SA" ;; esac
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$src" "$m" | grep -c '^>' || true)
  if [ "$changed" -ne "${4:-1}" ]; then
    echo "  ERROR     $1 -- the mutation changed $changed line(s), expected ${4:-1}"; rm -rf "$d"; return 1; fi
  case "$2" in
    si) suite "$m" "$SS" "$SA" >/dev/null 2>&1; rc=$? ;;
    ss) suite "$SI" "$m" "$SA" >/dev/null 2>&1; rc=$? ;;
    *)  suite "$SI" "$SS" "$m" >/dev/null 2>&1; rc=$? ;;
  esac
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "K1 the catch back to return true" si 's/( {16}\/\/ is the over-plan gate.s, in the caller[^\n]*\n) {16}return wrote;/$1                return true;/' || fails=$((fails+1))
mut "K2 wrote = true moved above writeAtomic" si 's/( {16})(writeAtomic\(f, sb\.toString\(\)\);)\n {16}wrote = true;/$1wrote = true;\n$1$2/' || fails=$((fails+1))
mut "K3 getAppReply maps not-kept-not-overPlan to OK-SESSION-ONLY" ss 's/\(overPlan \? "OK-SESSION-ONLY " : "OK-UNSAVED "\)/"OK-SESSION-ONLY "/' || fails=$((fails+1))
mut "K4 the napps OK-UNSAVED branch moved after the generic OK" sa 's/( {16}\} else if \(r\.startsWith\("OK-UNSAVED"\)\) \{\n.*?\n)( {16}\} else if \(r\.startsWith\("OK-OFF"\)\) \{\n.*?\n)( {16}\} else if \(r\.startsWith\("OK"\)\) \{\n.*?\n)/$2$3$1/s' 4 || fails=$((fails+1))
mut "K5 getAppReply answers OK under an Off default" ss 's/\(notKeptByDefault \? "OK-OFF " : "OK "\)/"OK "/' || fails=$((fails+1))
mut "K6 the napps OK-OFF branch moved after the generic OK" sa 's/( {16}\} else if \(r\.startsWith\("OK-OFF"\)\) \{\n.*?\n)( {16}\} else if \(r\.startsWith\("OK"\)\) \{\n.*?\n)/$2$1/s' 2 || fails=$((fails+1))
mut "K7 getApp passes false for the flag" ss 's/getAppReply\(kept, overPlan, offDefault && !StoreInstaller\.keepSetHas\(StoreService\.this, pkg\), pkg\)/getAppReply(kept, overPlan, false, pkg)/' || fails=$((fails+1))
mut "K8 getApp drops the keepSetHas term" ss 's/offDefault && !StoreInstaller\.keepSetHas\(StoreService\.this, pkg\), pkg\)/offDefault, pkg)/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
