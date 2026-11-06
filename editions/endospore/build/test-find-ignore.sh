#!/usr/bin/env bash
# test-find-ignore.sh [<build-device.sh>] -- exercise NWP-20260914-07's releases/ prune marker.
#
# WHY THIS IS COMMITTED. The marker's whole job is to close a race that only opens when two --release passes
# overlap, which is exactly the situation nobody runs on purpose. A guard like that is indistinguishable from
# one that has silently stopped working, and what it protects is expensive: the operator's passphrase entry,
# which cannot be replayed, on a pass that can die ~3 minutes in because another device's Soong finder walked
# into this device's half-unpacked otatools bundle.
#
# What it defends against is on record: out-tegu/.module_paths/files.db, written ~7s into the tegu --release
# pass on 2026-09-13, contains "releases/2026091306/release-frankel-2026091306". tegu's build walked into
# frankel's release output. It was harmless only because frankel's own per-directory marker had existed for
# 19 minutes by then.
#
# THE INVARIANT IS ORDERING, and that is most of what this checks: the marker must be created BEFORE the `m`
# that could walk the tree, and AFTER $TREE is set. Move it one line the wrong way and the window reopens
# SILENTLY -- the build still succeeds, every time, until the day two passes overlap.
#
# Lines are extracted from build-device.sh BY ANCHOR, never copied. If the anchors move, extraction is empty
# and every case fails loudly -- a test carrying its own stale copy would keep passing after the real code
# changed.
#
#   bash test-find-ignore.sh              # the behaviour + ordering cases
#   bash test-find-ignore.sh --mutate     # ... plus mutations that must each CONVICT the suite
#
# Pure logic -- no build, no device, no network. Safe to run anywhere bash runs.
set -uo pipefail

MUTATE=0
[ "${1:-}" = "--mutate" ] && { MUTATE=1; shift; }
SRC="${1:-$(dirname "$0")/build-device.sh}"
[ -f "$SRC" ] || { echo "no such script: $SRC"; exit 2; }

lineno_marker() { grep -n 'touch "\$TREE/releases/\.find-ignore"' "$1" | head -1 | cut -d: -f1; }
lineno_m()      { grep -n '^m \${JOBS:+-j\$JOBS} \$TARGETS' "$1" | head -1 | cut -d: -f1; }
lineno_tree()   { grep -n '^TREE=' "$1" | head -1 | cut -d: -f1; }

# suite <script> <label> [quiet] -> 0 all good, 1 something wrong. Own counters; never touches globals.
suite() {
  local f="$1" tag="$2" quiet="${3:-}" p=0 x=0 mk mm mt
  ok()  { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  bad() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  # ⚠ Every match below reads its input to the end: a here-string (`grep -q PAT <<<"$var"`) or
  # `grep -c PAT >/dev/null` on a pipe, never `cmd | grep -q`. Under pipefail grep -q exits at its first match,
  # the producer can die of SIGPIPE, and the pipeline fails: an absence check then passes on the code it exists
  # to reject, a presence check goes red at random (docs/backlog.md, "pipes into grep -q under pipefail").
  [ -n "$quiet" ] || echo "== $tag =="

  mk=$(lineno_marker "$f"); mm=$(lineno_m "$f"); mt=$(lineno_tree "$f")
  [ -n "$mk" ] || { bad "the prune marker line is ABSENT -- concurrent --release is unsafe"; echo "$p $x" >/dev/null; return 1; }
  [ -n "$mm" ] || { bad "could not find the \`m\` invocation (anchor moved?)"; return 1; }
  [ -n "$mt" ] || { bad "could not find TREE= (anchor moved?)"; return 1; }

  # THE invariant: before `m`, or the finder can walk releases/ before it is pruned.
  if [ "$mk" -lt "$mm" ]; then ok "marker is created BEFORE m ($mk < $mm)"
  else bad "marker at $mk is NOT before m at $mm -- the race window is open"; fi
  # $TREE must already be set, or the marker lands somewhere else entirely.
  if [ "$mt" -lt "$mk" ]; then ok "marker is created AFTER TREE= ($mt < $mk)"
  else bad "marker at $mk precedes TREE= at $mt -- it would write to the wrong path"; fi
  # It must never be able to abort a build that would otherwise work.
  if sed -n "${mk},$((mk+1))p" "$f" | grep -c 'fail ' >/dev/null; then
    bad "the marker line calls fail -- an unwritable releases/ must not abort the build"
  else ok "marker cannot abort the build"; fi

  [ -n "$quiet" ] || printf '  (%d ok, %d failed)\n' "$p" "$x"
  [ "$x" = 0 ]
}

# effect: the extracted lines must actually create the marker, twice, without failing.
effect() {
  local f="$1" tmp snippet rc p=0 x=0
  echo "== effect (run for real in a temp tree) =="
  snippet=$(grep -A1 'mkdir -p "\$TREE/releases" && touch' "$f")
  [ -n "$snippet" ] || { printf '  FAIL  could not extract the marker lines\n'; return 1; }
  tmp=$(mktemp -d)
  TREE="$tmp" bash -c "$snippet" >/dev/null 2>&1
  if [ -f "$tmp/releases/.find-ignore" ]; then printf '  ok    creates $TREE/releases/.find-ignore\n'; p=$((p+1))
  else printf '  FAIL  did NOT create the marker\n'; x=$((x+1)); fi
  TREE="$tmp" bash -c "$snippet" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 0 ]; then printf '  ok    second run exits 0 (idempotent)\n'; p=$((p+1))
  else printf '  FAIL  second run exited %s\n' "$rc"; x=$((x+1)); fi
  if [ -f "$tmp/releases/.find-ignore" ]; then printf '  ok    marker survives a second run\n'; p=$((p+1))
  else printf '  FAIL  marker vanished on the second run\n'; x=$((x+1)); fi
  rm -rf "$tmp"
  [ "$x" = 0 ]
}

suite "$SRC" "as committed"; RC=$?
effect "$SRC" || RC=1

[ "$MUTATE" = 0 ] && { echo; [ "$RC" = 0 ] && echo "suite passed" || echo "suite FAILED"; exit $RC; }
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo
echo "== mutations (each MUST be convicted) =="
MRC=0
# A mutation is CONVICTED when the suite fails on it. Scored separately: these failures are the point, so
# they must not be mistaken for the suite failing (the sibling test-tmpdir-guard.sh scores it the same way).
mutant() {  # $1 = label, $2 = file
  if suite "$2" "$1" quiet; then printf '  ⚠ SURVIVED  %s -- the suite does not test what it claims\n' "$1"; MRC=1
  else printf '  convicted   %s\n' "$1"; fi
  rm -f "$2"
}

m1=$(mktemp); grep -v 'touch "\$TREE/releases/\.find-ignore"' "$SRC" > "$m1"
mutant "marker deleted" "$m1"

m2=$(mktemp)
awk '/^mkdir -p "\$TREE\/releases" && touch/ {getline nxt; next}
     /^m \$\{JOBS:\+-j\$JOBS\} \$TARGETS/ {print; print "mkdir -p \"$TREE/releases\" && touch \"$TREE/releases/.find-ignore\""; next}
     {print}' "$SRC" > "$m2"
mutant "marker moved AFTER m (build still green; only concurrency breaks)" "$m2"

echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
