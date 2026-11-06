#!/usr/bin/env bash
# test-app-deps-java.sh [--mutate] -- NWP-20261118-21: what an on-demand tap materialises BEFORE the app itself
# (ProfileActivity's groupFor, groupDeps, appDeps and isStackMember; UnarchiveService.pendingDeps consumes appDeps).
# Runs core/chooser/tests/app-deps: the chooser's pure AppDeps, compiled against its cases ALONE and EXECUTED, plus
# source checks that ProfileActivity answers through it.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies of AppDeps.java, each of which must FAIL a named case. A mutant
# that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-app-deps-java.sh            # the cases
#   bash test-app-deps-java.sh --mutate   # ... plus the mutants
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
  echo "test-app-deps-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
# ONE temp root: every class dir and mutant tree lives under it, and the EXIT trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
run() { JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/app-deps/run.sh" "$1" "$(mktemp -d -p "$W")"; }
run "$ROOT" || { echo "FAILED"; exit 1; }

# ProfileActivity must answer through AppDeps: each body calls the matching method and holds no loop of its own.
bad=0
body() { awk -v n="$1" '$0 ~ "static .* " n "\\(android\\.content\\.Context" {f=1} f{print} f&&/^    }$/{exit}' "$ROOT/$CH/ProfileActivity.java"; }
for pair in groupFor:groupOf groupDeps:groupDeps appDeps:appDeps isStackMember:isStackMember; do
  m=${pair%%:*}; l=${pair#*:}
  b=$(body "$m")
  if [[ $b == *"AppDeps.$l("* && $b != *"for (String"* ]]; then echo "ok   s1 $m answers through AppDeps.$l"
  else echo "FAIL s1 $m must call AppDeps.$l and hold no loop of its own"; bad=1; fi
done
b=$(body appDeps)
if [[ $b =~ AppDeps\.appDeps\([^\;]*GMS_PKG,[[:space:]]*GSF_PKG,[[:space:]]*VENDING_PKG\) ]]; then
  echo "ok   s2 appDeps passes GMS_PKG, GSF_PKG, VENDING_PKG in that order"
else echo "FAIL s2 appDeps must pass GMS_PKG, GSF_PKG, VENDING_PKG to AppDeps.appDeps in that order"; bad=1; fi
[ "$bad" -eq 0 ] || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <perl-expr over AppDeps.java> <case the mutant must fail>
  local d f out rc
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  f="$d/$CH/AppDeps.java"
  cp "$ROOT/$CH/AppDeps.java" "$f"
  if ! perl -0pi -e "$2" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/AppDeps.java" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(run "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if grep -qF -- "error:" <<<"$out"; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $3" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the case '$3' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$3')"
}
fails=0
mut "D1 the deferred filter on the stack removed" 's/ && deferred\.contains\(s\)//' \
  "a Play client with vending not deferred pulls gms and gsf" || fails=$((fails+1))
mut "D2 the stack order vending-first" 's/\{ gms, gsf, vending \}/{ vending, gms, gsf }/' \
  "a Play client pulls gms, gsf, vending in that order" || fails=$((fails+1))
mut "D3 the entry exclusion removed (groupDeps)" 's/!p\.equals\(entry\) && //' \
  "the entry never appears in its own list" || fails=$((fails+1))
mut "D4 the explicit token loses to the default" \
  's/if \(e != null && !e\.isEmpty\(\)\) return e;\n        return defaults\.get\(pkg\);/String d = defaults.get(pkg);\n        if (d != null) return d;\n        if (e != null && !e.isEmpty()) return e;\n        return null;/' \
  "an explicit token beats the default" || fails=$((fails+1))
mut "D5 the stack added for a non-playDeps client" 's/ && playDeps\.contains\(entry\)//' \
  "a client not in playDeps pulls no stack" || fails=$((fails+1))
mut "D6 the stack-member check negated" 's/!isStackMember\(entry/isStackMember(entry/' \
  "a Play client pulls gms, gsf, vending in that order" || fails=$((fails+1))
mut "D7 the entry exclusion removed (stack loop)" 's/!s\.equals\(entry\) && //' \
  "the entry never appears in its own list" || fails=$((fails+1))
mut "D8 the empty-token fallback removed" 's/e != null && !e\.isEmpty\(\)/e != null/' \
  "an explicit empty token falls back to the default" || fails=$((fails+1))
mut "D9 the dedupe removed" \
  's/LinkedHashSet<String> deps = new LinkedHashSet<>\(groupDeps\(/List<String> deps = new ArrayList<>(groupDeps(/' \
  "no duplicates when a stack member shares the client's group" || fails=$((fails+1))
mut "D10 the stack member compares with the entry's own group" 's/String g = defaults\.get\(gms\);/String g = groupOf(gms, explicit, defaults);/' \
  "the entry never appears in its own list" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
