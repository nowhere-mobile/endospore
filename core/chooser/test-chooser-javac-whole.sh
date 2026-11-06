#!/usr/bin/env bash
# test-chooser-javac-whole.sh [--mutate] -- every chooser source compiles under javac with no Android classpath, and no
# error that needs no Android type is reported (NWP-20261118-14).
#
# WHY THIS IS COMMITTED. From 2026-10-23 (merge 97fa7ea47) to 2026-10-29 main's chooser did not compile: a
# `catch (Throwable t)` inside the lambda of startSyncStatusWatcher(), a method that declares `Thread t`, gave
# "variable t is already defined" (fixed by NWP-20261029-22). Every CI run was green, because the chooser suites lift
# single members into javac, and the Soong build of the whole app (NowhereChooser in core/vendor-common/Android.bp:
# chooser/src/**/*.java, chooser/mms/**/*.java, the aidl, zxing) runs only on the build host.
#
# The runner holds no android.jar, so this suite gives javac every .java under core/chooser/src and core/chooser/mms with
# only core/chooser/libs/*.jar on the classpath. javac then reports thousands of missing Android packages and symbols, and
# always exits non-zero: the exit status is ignored, the verdict is the -XDrawDiagnostics lines. -XDshould-stop.ifError=FLOW
# keeps javac going through attribution and flow analysis past those errors, so it reaches every method body. The suite
# FAILS only on the FATAL keys below, which need no Android type to be right and occur 0 times on main. Two controls must
# match, so "no findings" can never mean "never ran": a compiler.err.doesnt.exist (javac really ran without Android) and a
# compiler.err.cant.resolve* inside ChooserActivity.java (attribution reached its method bodies).
#
# What it cannot catch: a wrong type, a missing method or a bad override -- each needs the framework types. That is a
# compile against framework stubs the runner holds (docs/backlog.md, the row this suite is PARTIAL for).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-chooser-javac-whole.sh            # the whole-source compile and its verdict
#   bash test-chooser-javac-whole.sh --mutate   # ... plus planted breaks that must each FAIL, and checker mutants
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
CHOOSER="$root/core/chooser"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1; then
  JAVAC=$(command -v javac)
elif [ -x "$HOST_JDK/javac" ]; then
  JAVAC="$HOST_JDK/javac"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }

# The keys that fail the run. Each occurs 0 times on main, needs no Android type to be right, and a mutant below
# convicts it. Error recovery produces other keys on main (cant.resolve*, doesnt.exist,
# method.does.not.override.superclass, except.never.thrown.in.try, invalid.mref, unexpected.lambda, ...): never add one.
FATAL_KEYS="already.defined duplicate.class unreachable.stmt missing.ret.stmt"
# Without it javac stops before flow analysis, and unreachable.stmt / missing.ret.stmt are never reported (K3f).
FLOW_FLAG="-XDshould-stop.ifError=FLOW"

# check <chooser root holding src/ and mms/> -> 0 when the controls match and no FATAL key is reported.
check() {
  local srcroot="$1" args out cp j diag nfiles ndiag nfind findings k
  args=$(mktemp -p "$W") || return 2
  out=$(mktemp -d -p "$W") || return 2
  find "$srcroot/src" "$srcroot/mms" -name '*.java' -type f 2>/dev/null | LC_ALL=C sort > "$args"
  nfiles=$(wc -l < "$args")
  cp=""
  for j in "$CHOOSER"/libs/*.jar; do [ -f "$j" ] && cp="${cp:+$cp:}$j"; done
  # $FLOW_FLAG is unquoted on purpose: empty in the K3f checker mutant, so it then passes no argument at all.
  # shellcheck disable=SC2086
  diag=$("$JAVAC" -J-Djava.io.tmpdir="$W" -XDrawDiagnostics $FLOW_FLAG -Xmaxerrs 1000000 -proc:none -implicit:none \
    -nowarn -encoding UTF-8 ${cp:+-cp "$cp"} -d "$out" @"$args" 2>&1)
  rm -rf "$out" "$args"
  ndiag=$(printf '%s\n' "$diag" | grep -cE '^[^ :]+\.java:[0-9]+:[0-9]+: compiler\.')
  if [ "$(printf '%s\n' "$diag" | grep -c ': compiler\.err\.doesnt\.exist:')" -eq 0 ]; then
    echo "  FAIL  control A: no compiler.err.doesnt.exist -- javac did not run over the chooser without Android" \
         "($nfiles files). javac printed:" >&2
    printf '%s\n' "$diag" | head -20 >&2
    return 1
  fi
  if [ "$(printf '%s\n' "$diag" | grep -cE '^ChooserActivity\.java:[0-9]+:[0-9]+: compiler\.err\.cant\.resolve')" -eq 0 ]; then
    echo "  FAIL  control B: no compiler.err.cant.resolve* inside ChooserActivity.java -- attribution did not reach its" \
         "method bodies. javac printed:" >&2
    printf '%s\n' "$diag" | head -20 >&2
    return 1
  fi
  findings=""
  for k in $FATAL_KEYS; do
    findings+=$(printf '%s\n' "$diag" | K="compiler.err.$k" awk '
      { i = index($0, ": " ENVIRON["K"]); if (!i) next
        rest = substr($0, i + 2 + length(ENVIRON["K"]))
        if (rest == "" || substr(rest, 1, 1) == ":") print }')
    findings+=$'\n'
  done
  findings=$(printf '%s' "$findings" | awk 'NF')
  if [ -n "$findings" ]; then
    nfind=$(printf '%s\n' "$findings" | wc -l)
    printf '%s\n' "$findings" | sed 's/^/  FAIL  /' >&2
    echo "  FAIL  $nfind diagnostic(s) of the FATAL keys ($FATAL_KEYS) in $nfiles files" >&2
    return 1
  fi
  echo "ok: $nfiles files compiled, $ndiag diagnostics seen, 0 of the FATAL keys (${FATAL_KEYS:-none})"
  return 0
}

echo "== the whole chooser source set under javac, no Android classpath =="
check "$CHOOSER" || { echo "FAIL: the whole-chooser javac check" >&2; exit 1; }

[ "$MUTATE" = yes ] || { echo "PASS"; exit 0; }

# copy_tree -> a fresh dir in $W holding copies of src/ and mms/.
copy_tree() {
  local d
  d=$(mktemp -d -p "$W") || return 2
  cp -R "$CHOOSER/src" "$CHOOSER/mms" "$d/" || return 2
  echo "$d"
}

# plant <file> <fixed-string anchor> <text> [<after-line>] -> inserts <text> (may hold \n) after the first line
# holding <anchor>; with <after-line>, only after a line holding that has been seen. Fails when nothing changed.
plant() {
  local f="$1" anchor="$2" text="$3" after="${4:-}" tmp
  tmp=$(mktemp -p "$W") || return 2
  A="$anchor" T="$text" S="$after" awk '
    BEGIN { on = (ENVIRON["S"] == "") }
    { print }
    !on && index($0, ENVIRON["S"]) { on = 1; next }
    on && !done && index($0, ENVIRON["A"]) { print ENVIRON["T"]; done = 1 }' "$f" > "$tmp" || return 2
  if cmp -s "$f" "$tmp"; then echo "  MUTANT DID NOT APPLY: anchor '$anchor' not found in $f" >&2; rm -f "$tmp"; return 2; fi
  mv "$tmp" "$f"
}

C=com/nowhere/chooser
convicted=0; failed=0

# source_mutant <name> <expected diagnostic regex> <plant command...> -> check must FAIL naming the expected diagnostic.
source_mutant() {
  local name="$1" want="$2" d o rc
  shift 2
  d=$(copy_tree) || { echo "NOT CONVICTED $name (copy failed)"; failed=$((failed + 1)); return; }
  if ! "$@" "$d"; then echo "NOT CONVICTED $name (the mutant did not apply)"; failed=$((failed + 1)); rm -rf "$d"; return; fi
  o=$(check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -ne 0 ] && [ "$(printf '%s\n' "$o" | grep -cE "$want")" -gt 0 ]; then
    echo "CONVICTED $name: $(printf '%s\n' "$o" | grep -E "$want" | head -1 | sed 's/^ *FAIL *//')"
    convicted=$((convicted + 1))
  else
    echo "NOT CONVICTED $name (rc=$rc):"; printf '%s\n' "$o" | tail -5; failed=$((failed + 1))
  fi
}

m1() { plant "$1/src/$C/ChooserActivity.java" '        Thread t = new Thread(() -> {' \
         '            try { } catch (Throwable t) { }' '    private void startSyncStatusWatcher() {'; }
m2() { plant "$1/src/$C/ProfileActivity.java" '        final boolean offline = offlineSession;' '        int offline = 0;'; }
m3() { plant "$1/src/$C/AutoLogoffGate.java" '    private AutoLogoffGate() {}' \
         $'    private static void dupe() {}\n    private static void dupe() {}'; }
m4() { [ -f "$1/src/$C/TzSeed.java" ] || { echo "  MUTANT DID NOT APPLY: TzSeed.java is absent" >&2; return 2; }
       printf 'package com.nowhere.chooser;\nfinal class TzSeed {}\n' > "$1/src/$C/TzSeedDup.java"; }
m5() { plant "$1/src/$C/TzSeed.java" '    private TzSeed() {}' '    static void unreachable() { return; int x = 0; }'; }
m6() { plant "$1/src/$C/TzSeed.java" '    private TzSeed() {}' '    static int missingReturn() { }'; }

echo "== mutants: each must FAIL the check =="
source_mutant "M1 catch (Throwable t) in the lambda of startSyncStatusWatcher (the 2026-10-23 break)" \
  '^ *FAIL *ChooserActivity\.java:[0-9]+:[0-9]+: compiler\.err\.already\.defined: kindname\.variable, t, kindname\.method, startSyncStatusWatcher\(\)' m1
source_mutant "M2 a second int local named offline in ProfileActivity.showConfirm" \
  '^ *FAIL *ProfileActivity\.java:[0-9]+:[0-9]+: compiler\.err\.already\.defined: kindname\.variable, offline,' m2
source_mutant "M3 a duplicate method dupe() in AutoLogoffGate" \
  '^ *FAIL *AutoLogoffGate\.java:[0-9]+:[0-9]+: compiler\.err\.already\.defined: kindname\.method, dupe\(\)' m3
source_mutant "M4 a second class TzSeed in TzSeedDup.java" \
  '^ *FAIL *TzSeedDup\.java:[0-9]+:[0-9]+: compiler\.err\.duplicate\.class: com\.nowhere\.chooser\.TzSeed' m4
source_mutant "M5 a statement after return in TzSeed" \
  '^ *FAIL *TzSeed\.java:[0-9]+:[0-9]+: compiler\.err\.unreachable\.stmt' m5
source_mutant "M6 an int method with no return in TzSeed" \
  '^ *FAIL *TzSeed\.java:[0-9]+:[0-9]+: compiler\.err\.missing\.ret\.stmt' m6

echo "== checker mutants: each must show the check broken =="
# K1: the FATAL list emptied -- M1 must then pass, so the list is what convicts it.
k1() {
  local d o rc
  d=$(copy_tree) && m1 "$d" || { echo "NOT CONVICTED K1 (M1 did not apply)"; failed=$((failed + 1)); rm -rf "$d"; return; }
  o=$(FATAL_KEYS="" check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "CONVICTED K1 the FATAL list emptied: M1 is then NOT convicted ($o)"; convicted=$((convicted + 1))
  else echo "NOT CONVICTED K1 (M1 still failed with an empty FATAL list):"; printf '%s\n' "$o" | tail -5; failed=$((failed + 1)); fi
}
# K2: the source list emptied -- the check must FAIL on its controls, not pass on "no findings".
k2() {
  local d o rc
  d=$(mktemp -d -p "$W") && mkdir -p "$d/src" "$d/mms" || { echo "NOT CONVICTED K2 (no dir)"; failed=$((failed + 1)); return; }
  o=$(check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -ne 0 ] && [ "$(printf '%s\n' "$o" | grep -c 'FAIL  control A:')" -gt 0 ]; then
    echo "CONVICTED K2 the source list emptied: the check fails on control A"; convicted=$((convicted + 1))
  else echo "NOT CONVICTED K2 (rc=$rc):"; printf '%s\n' "$o" | tail -5; failed=$((failed + 1)); fi
}
# K3f: the FLOW flag removed -- javac stops before flow analysis, so M6 must then pass. (K3, the flag removed with M1, is
# not a checker mutant: M1 is reported during attribution, before flow, and is caught without the flag.)
k3f() {
  local d o rc
  d=$(copy_tree) && m6 "$d" || { echo "NOT CONVICTED K3f (M6 did not apply)"; failed=$((failed + 1)); rm -rf "$d"; return; }
  o=$(FLOW_FLAG="" check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "CONVICTED K3f the FLOW flag removed: M6 is then NOT convicted"; convicted=$((convicted + 1))
  else echo "NOT CONVICTED K3f (M6 still failed without the FLOW flag):"; printf '%s\n' "$o" | tail -5; failed=$((failed + 1)); fi
}
k1; k2; k3f

echo "mutants: $convicted convicted, $failed not"
[ "$failed" -eq 0 ] || { echo "FAIL: $failed mutant(s) not convicted" >&2; exit 1; }
echo "PASS"
