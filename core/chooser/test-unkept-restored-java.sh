#!/usr/bin/env bash
# test-unkept-restored-java.sh [--mutate] -- at sign-out an app this sign-in restored installed from #apps
# (nowhere-installed-restored) that has no keep line is recorded Off (NWP-20261203-24).
#
# WHY THIS IS COMMITTED. roamd's code-side drop is nowhere-appoff.list INTERSECT nowhere-appdrop.list, and the agent's
# carry re-emits every head package that the drop list does not name. captureAppDrops puts a restored, unkept app in
# the drop list, but nothing put it in the Off record, so a head that carried it once carried it at every later
# sign-out, though Your apps showed it Off. "2026-09-26 — DECIDED: an app switched Off leaves the store at the next
# roam, exactly like an app that was never kept". ProfileActivity.recordUnkeptRestoredOff now records it Off with
# StoreInstaller.recordTurnedOff (never recordUninstalled: an Off never mints the tombstone), between captureAppCode
# and captureAppDrops.
#
# WHAT RUNS. core/chooser/tests/unkept-restored/run.sh compiles UnkeptRestored.java with UnkeptRestoredCases (C1-C10).
# Then source checks (S1-S5) read ProfileActivity.java: the call order in doLogoffImpl, the null-read guard, the
# Off-only write, the predicate wiring and the count-only log line.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-unkept-restored-java.sh            # the cases and the source checks
#   bash test-unkept-restored-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PA0="$HERE/src/com/nowhere/chooser/ProfileActivity.java"
UR0="$HERE/src/com/nowhere/chooser/UnkeptRestored.java"
PA="${PA:-$PA0}"
UR="${UR:-$UR0}"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
RUN="$HERE/tests/unkept-restored/run.sh"
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
[ -f "$PA" ] && [ -f "$RUN" ] || { echo "FAIL: missing $PA or $RUN" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: the source checks need perl, and there is none" >&2; exit 2; }

# The one temp root: run.sh and every mutant live inside it, and the EXIT trap removes it on every path.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W

# lineof <text> <ERE>: the line number of the ONLY line of <text> matching <ERE>; empty when it is absent or repeated.
lineof() { local hits; hits=$(grep -nE "$2" <<<"$1" | cut -d: -f1); [ -n "$hits" ] && [ "$(wc -l <<<"$hits")" -eq 1 ] && echo "$hits"; }

# checks <ProfileActivity.java> -> 0 every source check holds, 1 one failed. Each ERE is anchored on the statement,
# so a commented-out line never matches.
checks() {
  local pa="$1" fails=0 logoff body c r d g e t ret
  logoff=$(awk '/private void doLogoffImpl\(final boolean forInstall\) \{/,/private void doColdLock\(\) \{/' "$pa")
  body=$(awk '
    !on && index($0, "    private void recordUnkeptRestoredOff() {") == 1 { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); x=gsub(/\}/,"}"); depth+=n-x; if (depth==0 && n+x>0) exit }
  ' "$pa")
  c=$(lineof "$logoff" '^[[:space:]]*captureAppCode\(\);')
  r=$(lineof "$logoff" '^[[:space:]]*recordUnkeptRestoredOff\(\);')
  d=$(lineof "$logoff" '^[[:space:]]*captureAppDrops\(\);')
  if [ -n "$c" ] && [ -n "$r" ] && [ -n "$d" ] && [ "$c" -lt "$r" ] && [ "$r" -lt "$d" ]; then
    echo "ok   S1 sign-out runs captureAppCode, then recordUnkeptRestoredOff, then captureAppDrops"
  else
    echo "FAIL S1 recordUnkeptRestoredOff is not called between captureAppCode and captureAppDrops at sign-out -- the" \
         "drop list and roamd's appoff INTERSECT appdrop do not see the Off record in the same sign-out"
    fails=$((fails+1))
  fi
  g=$(lineof "$body" '^[[:space:]]*if \(keptModes == null \|\| orphans == null\) \{$')
  t=$(lineof "$body" 'recordTurnedOff\(')
  e=""; ret=""
  if [ -n "$g" ]; then
    e=$(awk -v s="$g" 'NR>s && /^            }$/ {print NR; exit}' <<<"$body")
    [ -n "$e" ] && ret=$(awk -v s="$g" -v z="$e" 'NR>s && NR<z && /^[[:space:]]*return;$/ {print NR; exit}' <<<"$body")
  fi
  if [ -n "$g" ] && [ -n "$e" ] && [ -n "$ret" ] && [ -n "$t" ] && [ "$e" -lt "$t" ]; then
    echo "ok   S2 an unreadable keep-set or orphan record returns before any recordTurnedOff"
  else
    echo "FAIL S2 the null-read guard does not return before recordTurnedOff -- an unknown keep-set would record a kept" \
         "app Off"
    fails=$((fails+1))
  fi
  if [ -n "$body" ] && ! grep -q 'recordUninstalled' <<<"$body" \
     && [ -n "$(lineof "$body" '^[[:space:]]*for \(String p : sel\) StoreInstaller\.recordTurnedOff\(this, p\);$')" ]; then
    echo "ok   S3 each selected app is recorded with StoreInstaller.recordTurnedOff, never recordUninstalled"
  else
    echo "FAIL S3 the selected apps are not recorded with recordTurnedOff alone -- an Off must never mint the tombstone"
    fails=$((fails+1))
  fi
  if grep -qF 'UnkeptRestored.select(' <<<"$body" && grep -qF 'keptModes.keySet(), orphans, getPackageName(),' <<<"$body" \
     && grep -qF 'p -> isBundledSystem(pm, p), p -> UnarchiveService.hasInstalledCode(this, p));' <<<"$body" \
     && grep -qF 'UnarchiveService.INSTALLED_RESTORED' <<<"$body"; then
    echo "ok   S4 select gets the restored list, the keep-set, the orphans, the own package and both PackageManager tests"
  else
    echo "FAIL S4 UnkeptRestored.select is not wired to the restored list, keep-set, orphans, own package and predicates"
    fails=$((fails+1))
  fi
  # no log line in the method prints a package: only the count (sel.size()) and fixed file names
  if [ -n "$body" ] && grep -qF '"sign-out: " + sel.size()' <<<"$body" \
     && perl -ne 'exit 1 if /\+\s*(?:p|pkg|sel|text|keptModes|orphans)\s*(?:[+)]|$)/' <<<"$body"; then
    echo "ok   S5 the log lines name no package, only the count"
  else
    echo "FAIL S5 a log line in recordUnkeptRestoredOff prints a package or a list of packages"
    fails=$((fails+1))
  fi
  [ "$fails" -eq 0 ]
}

# suite <UnkeptRestored.java> <ProfileActivity.java> -> 0 pass, 1 a case or check failed (only this may convict a
# mutant), 2 an input is missing, 3 the classes did not compile.
suite() {
  local rc=0
  bash "$RUN" "$1" || rc=$?
  [ "$rc" -le 1 ] || return "$rc"
  checks "$2" || rc=1
  return "$rc"
}

echo "== $UR + $PA"
suite "$UR" "$PA"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by the named case or check; one that does not apply or compile is a failure)"
# mut <label> <file: UR|PA> <perl-expr> <lines-that-must-change> <convicting case or check>
mut() {
  local label="$1" which="$2" expr="$3" want="$4" by="$5" d src m rc changed out
  d=$(mktemp -d -p "$W")
  if [ "$which" = UR ]; then src="$UR"; else src="$PA"; fi
  m="$d/$(basename "$src")"
  if ! perl -0pe "$expr" "$src" > "$m"; then echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $label -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$src" "$m" | grep -c "^[<>]")
  if [ "$changed" -ne "$want" ]; then
    echo "  ERROR     $label -- the mutation changed $changed line(s), expected $want"; rm -rf "$d"; return 1; fi
  rc=0
  if [ "$which" = UR ]; then out=$(suite "$m" "$PA" 2>&1) || rc=$?; else out=$(suite "$UR" "$m" 2>&1) || rc=$?; fi
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $label"; return 1 ;;
    1) if grep -qF "FAIL $by" <<<"$out"; then echo "  convicted $label -- by $by"; return 0; fi
       echo "  WRONG     $label -- it failed, but not on $by"; return 1 ;;
    *) echo "  BROKEN    $label -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 the kept filter removed" UR 's/^\s*if \(kept\.contains\(p\)\) continue;[^\n]*\n//m' 1 C2 || fails=$((fails+1))
mut "M2 the orphan filter removed" UR 's/^\s*if \(orphans\.contains\(p\)\) continue;[^\n]*\n//m' 1 C3 || fails=$((fails+1))
mut "M3 the Play-stack filter removed" UR 's/^\s*if \(PLAY_STACK\.contains\(p\)\) continue;[^\n]*\n//m' 1 C4 || fails=$((fails+1))
mut "M4 the bundled filter removed" UR 's/^\s*if \(bundled\.test\(p\)\) continue;[^\n]*\n//m' 1 C6 || fails=$((fails+1))
mut "M5 the installed filter removed" UR 's/^\s*if \(!installed\.test\(p\)\) continue;[^\n]*\n//m' 1 C7 || fails=$((fails+1))
mut "M6 the call moved after captureAppDrops()" PA \
  's/^(\s*)recordUnkeptRestoredOff\(\);\n(\s*captureAppDrops\(\);[^\n]*\n)/$2$1recordUnkeptRestoredOff();\n/m' 2 S1 || fails=$((fails+1))
mut "M7 the null-read guard's return removed" PA \
  's/(no restored app recorded Off \(NWP-20261203-24\)"\);\n)\s*return;\n(\s*\}\n\s*final android\.content\.pm\.PackageManager pm)/$1$2/' 1 S2 || fails=$((fails+1))
mut "M8 recordTurnedOff replaced by recordUninstalled" PA \
  's/StoreInstaller\.recordTurnedOff\(this, p\);/StoreInstaller.recordUninstalled(this, p);/' 2 S3 || fails=$((fails+1))
mut "M9 the own-package filter removed" UR 's/^\s*if \(p\.equals\(ownPkg\)\) continue;[^\n]*\n//m' 1 C5 || fails=$((fails+1))
mut "M10 the line is not trimmed" UR 's/String p = raw\.trim\(\);/String p = raw;/' 2 C8 || fails=$((fails+1))
mut "M11 the log line prints the selected packages" PA 's/"sign-out: " \+ sel\.size\(\)/"sign-out: " + sel/' 2 S5 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
