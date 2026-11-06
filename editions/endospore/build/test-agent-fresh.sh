#!/usr/bin/env bash
# test-agent-fresh.sh [<check-agent-fresh.sh>] -- exercise NWP-20260914-08's publisher freshness guard.
#
# WHY THIS IS COMMITTED. The guard's only job is to refuse, and its refusal path never runs on a healthy
# host -- the same shape as its siblings here. What it protects is the OTA marker every fielded device reads:
# a stale agent_host publishes silently, and it was rebuilt by hand before three consecutive releases purely
# because someone remembered.
#
# ⚠ THE CASE THAT MATTERS MOST IS EXIT 2. "Could not determine" must never collapse into "fine" -- that
# collapse is exactly what went wrong three times on 2026-09-13/14 (a wrong APK path that printed nothing, a
# javac of a file nobody had edited, and a `[ -s ]` that is true for a directory). A mutation below turns
# exit 2 into exit 0 and the suite must convict it.
#
#   bash test-agent-fresh.sh              # the behaviour cases
#   bash test-agent-fresh.sh --mutate     # ... plus mutations that must each CONVICT the suite
#
# Pure logic -- no build, no device, no network.
set -uo pipefail

MUTATE=0
[ "${1:-}" = "--mutate" ] && { MUTATE=1; shift; }
SUT="${1:-$(dirname "$0")/check-agent-fresh.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT"; exit 2; }

# One root for every temp this suite makes, removed on any exit.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# suite <script> [quiet] -> 0 if every case behaved
suite() {
  local sut="$1" quiet="${2:-}" p=0 x=0 tmp rc
  ok()  { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  bad() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }

  tmp=$(mktemp -d -p "$W")
  mkdir -p "$tmp/src"
  printf 'package main\n' > "$tmp/src/a.go"
  sleep 1
  : > "$tmp/bin"

  # 1. binary newer than every source -> fresh
  NOWHERE_AGENT_SRC="$tmp/src" bash "$sut" "$tmp/bin" >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && ok "fresh binary -> 0" || bad "fresh binary -> $rc, want 0"

  # 2. a source touched after the build -> STALE. This is the real-world case: git pull restamps it.
  sleep 1; touch "$tmp/src/a.go"
  NOWHERE_AGENT_SRC="$tmp/src" bash "$sut" "$tmp/bin" >/dev/null 2>&1; rc=$?
  [ "$rc" = 1 ] && ok "source newer than binary -> 1 (STALE)" || bad "stale binary -> $rc, want 1"

  # 3. source tree absent -> CANNOT DETERMINE, and it must NOT be 0
  NOWHERE_AGENT_SRC="$tmp/nope" bash "$sut" "$tmp/bin" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && ok "missing source -> 2 (cannot determine)" || bad "missing source -> $rc, want 2"

  # 4. no binary at all -> cannot determine, never a silent pass
  NOWHERE_AGENT_SRC="$tmp/src" bash "$sut" "$tmp/absent" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && ok "missing binary -> 2" || bad "missing binary -> $rc, want 2"

  # 5. a NON-.go file newer must NOT trip it (only source decides)
  : > "$tmp/bin"; sleep 1; : > "$tmp/src/notes.txt"
  NOWHERE_AGENT_SRC="$tmp/src" bash "$sut" "$tmp/bin" >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && ok "newer non-.go file does not trip it -> 0" || bad "non-.go tripped it -> $rc, want 0"

  # 6-8. the module files and assembly are build inputs too: each newer than the binary -> STALE
  mkdir -p "$tmp/src/third_party/x"
  : > "$tmp/bin"; sleep 1; : > "$tmp/src/go.mod"
  NOWHERE_AGENT_SRC="$tmp/src" bash "$sut" "$tmp/bin" >/dev/null 2>&1; rc=$?
  [ "$rc" = 1 ] && ok "go.mod newer than binary -> 1" || bad "go.mod newer -> $rc, want 1"
  : > "$tmp/bin"; sleep 1; : > "$tmp/src/go.sum"
  NOWHERE_AGENT_SRC="$tmp/src" bash "$sut" "$tmp/bin" >/dev/null 2>&1; rc=$?
  [ "$rc" = 1 ] && ok "go.sum newer than binary -> 1" || bad "go.sum newer -> $rc, want 1"
  : > "$tmp/bin"; sleep 1; : > "$tmp/src/third_party/x/y.s"
  NOWHERE_AGENT_SRC="$tmp/src" bash "$sut" "$tmp/bin" >/dev/null 2>&1; rc=$?
  [ "$rc" = 1 ] && ok "third_party .s newer than binary -> 1" || bad ".s newer -> $rc, want 1"

  rm -rf "$tmp"
  [ -n "$quiet" ] || printf '  (%d ok, %d failed)\n' "$p" "$x"
  [ "$x" = 0 ]
}

echo "== as committed =="
suite "$SUT"; RC=$?

# NWP-20260919-06: THE GUARD MUST BE EXECUTABLE, because both callers gate on `[ -x ]` and SKIP it
# otherwise -- warning and proceeding. It was committed 100644, so it was skipped on every publish from a
# fresh checkout, and the 0.5.37 release published with a genuinely stale agent that the guard would have
# REFUSED. Nothing above this line can catch that: every case invokes the script through `bash`, which does
# not care about the mode, so the whole suite passes on a guard that can never run in production.
#
# ⚠ This asserts the COMMITTED mode via git, not the working-tree mode. A local `chmod +x` would make a
# working-tree check pass while the repo stayed broken for everyone else -- which is the state that shipped.
echo
echo "== the callers' gate: is the guard executable? =="
GITMODE="$(git -C "$(dirname "$SUT")" ls-files -s -- "$(basename "$SUT")" 2>/dev/null | awk '{print $1}')"
if [ -z "$GITMODE" ]; then
  printf '  ⚠ CANNOT DETERMINE  committed mode of %s (not a git checkout?)\n' "$(basename "$SUT")"
  RC=2   # "cannot determine" is not "fine" -- the rule this suite exists to enforce
elif [ "$GITMODE" = 100755 ]; then
  printf '  ok          committed mode %s -- `[ -x ]` in e4-ota-publish.sh/e4-ota-promote.sh will pass\n' "$GITMODE"
else
  printf '  FAIL        committed mode %s -- the callers gate on `[ -x ]`, so the guard is SILENTLY SKIPPED\n' "$GITMODE"
  printf '              fix: git update-index --chmod=+x %s\n' "$SUT"
  RC=1
fi

[ "$MUTATE" = 0 ] && { echo; [ "$RC" = 0 ] && echo "suite passed" || echo "suite FAILED"; exit $RC; }
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo
echo "== mutations (each MUST be convicted) =="
MRC=0
mutant() {  # $1 label, $2 sed expr
  local m; m=$(mktemp -p "$W"); sed "$2" "$SUT" > "$m"
  if suite "$m" quiet; then printf '  ⚠ SURVIVED  %s\n' "$1"; MRC=1
  else printf '  convicted   %s\n' "$1"; fi
  rm -f "$m"
}
# The one that matters: "cannot determine" silently becoming "fine".
mutant "cannot-determine downgraded to exit 0" 's/^  exit 2$/  exit 0/'
# The refusal stops refusing.
mutant "STALE downgraded to exit 0"            's/^  exit 1$/  exit 0/'
# The freshness question stops being asked at all.
mutant "the freshness question stops being asked" 's|^NEWER=.*|NEWER=""|'
# Only *.go counted: a go.mod/go.sum/.s change leaves a stale binary reading as fresh (convicted by c6).
mutant "find reverted to *.go only" "s|^NEWER=.*|NEWER=\"\$(find \"\$SRC\" -name '*.go' -newer \"\$AGENT\" -print -quit 2>/dev/null)\"|"
# ⚠ An earlier version of this mutation used -newer /dev/null. It was ENVIRONMENT-DEPENDENT -- /dev/null
# has a shifting mtime on some hosts, so the mutant was fresh or stale by luck and convicted nothing. A
# mutation that cannot fail is the same defect this whole guard exists to stop, one level up.

echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
