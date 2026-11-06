#!/usr/bin/env bash
# test-tmpdir-guard.sh [<build-device.sh>] -- exercise NWP-20260901-33's TMPDIR guard.
#
# WHY THIS IS COMMITTED. The guard exists to refuse a `--release` pass that cannot finish, and its whole
# value is in the REFUSAL -- a branch that never runs on a healthy host. A guard whose failure path is never
# exercised is indistinguishable from a guard that has silently stopped working, and this one protects the
# single most expensive step in the pipeline: the operator's passphrase entry, which cannot be replayed.
# What it is defending against is on record -- stallion, 2026090109, `e2fsdroid: No space left on device`,
# after three concurrent signing passes filled the 98 GB root disk.
#
# The block is extracted from build-device.sh BY ANCHOR, not copied. If the anchors move the extraction is
# empty and every case fails loudly, which is the point: a test holding its own stale copy of the code would
# keep passing after the real guard changed.
#
#   bash test-tmpdir-guard.sh              # the 9 behaviour cases
#   bash test-tmpdir-guard.sh --mutate     # ... plus 4 mutations that must each CONVICT the suite
#
# Pure logic -- no build, no device, no network. Safe to run anywhere bash runs.
set -uo pipefail

MUTATE=0
[ "${1:-}" = "--mutate" ] && { MUTATE=1; shift; }
SRC="${1:-$(dirname "$0")/build-device.sh}"
[ -f "$SRC" ] || { echo "no such script: $SRC"; exit 2; }

extract() {  # $1 = script -> stdout: the guard block
  local f="$1" a b
  a=$(grep -n '^if \[ "\$TMPFREE_GB" -lt 0 \]; then$' "$f" | head -1 | cut -d: -f1)
  [ -n "$a" ] || return 1
  b=$(awk -v a="$a" 'NR>a && /^fi$/ {c++; if (c==2) {print NR; exit}}' "$f")
  [ -n "$b" ] || return 1
  sed -n "${a},${b}p" "$f"
}

run_suite() {  # $1 = script -> prints results, returns nonzero if any case failed
  local f="$1" g pass=0 fail=0
  g=$(mktemp) || return 2
  if ! extract "$f" > "$g"; then echo "  FATAL: guard block not found (anchors moved)"; rm -f "$g"; return 2; fi

  one() {  # name, TMPFREE_GB, DO_RELEASE, want_rc, want_substring
    local out rc ok=1
    out=$(TMPFREE_GB="$2" DO_RELEASE="$3" TMPDIR=/fake bash -c '
            set -uo pipefail
            ts(){ echo TS; }
            fail(){ echo "== FAILED: $1 =="; exit 1; }
            source "$0"
            echo REACHED_END' "$g" 2>&1); rc=$?
    [ "$rc" = "$4" ] || ok=0
    grep -q -- "$5" <<<"$out" || ok=0
    if [ "$ok" = 1 ]; then pass=$((pass+1)); [ "$QUIET" = 1 ] || printf "  PASS  %-42s rc=%s\n" "$1" "$rc"
    else fail=$((fail+1)); [ "$QUIET" = 1 ] || printf "  FAIL  %-42s rc=%s (want %s)\n%s\n" "$1" "$rc" "$4" "$out"; fi
  }

  # The case that matters: a release pass on a too-small TMPDIR must REFUSE, not warn.
  one "release + 9 GiB  -> REFUSE"          9    1 1 "REFUSING"
  one "release + 19 GiB -> REFUSE"          19   1 1 "REFUSING"
  # At and above the floor it must proceed.
  one "release + 20 GiB -> proceed"         20   1 0 "REACHED_END"
  one "release + 5400 GiB -> proceed"       5400 1 0 "REACHED_END"
  # A build-only run is restartable and costs no prompt: warn, never block.
  one "build + 9 GiB -> warns"              9    0 0 "too little to sign with"
  one "build + 9 GiB -> still proceeds"     9    0 0 "REACHED_END"
  # Unmeasurable must NOT block: refusing on a failed measurement is a new footgun for an old one.
  one "unmeasured + release -> not blocked" -1   1 0 "NOT MEASURED"
  one "unmeasured + release -> proceeds"    -1   1 0 "REACHED_END"
  # The figure has to actually reach the log, or the operator cannot see what it decided on.
  one "reports the free figure"             37   1 0 "37 GiB free"

  rm -f "$g"
  [ "$QUIET" = 1 ] || { echo; echo "  PASS=$pass FAIL=$fail"; }
  SUITE_FAIL=$fail
  [ "$fail" = 0 ]
}

QUIET=0
echo "guard behaviour ($SRC):"
run_suite "$SRC"; RC=$?
[ "$MUTATE" = 0 ] && exit $RC
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo
echo "mutations (each must CONVICT the suite above):"
W=$(mktemp); MRC=0
mutate() {  # name, sed-expr, which cases should catch it
  cp "$SRC" "$W"; sed -i "$2" "$W"
  if cmp -s "$SRC" "$W"; then
    printf "  ⚠ NOT APPLIED  %-38s -- the expression matched nothing; this mutation proves NOTHING\n" "$1"
    MRC=1; return
  fi
  QUIET=1 SUITE_FAIL=0
  run_suite "$W" >/dev/null 2>&1
  if [ "${SUITE_FAIL:-0}" -gt 0 ]; then
    printf "  CONVICTED     %-38s (%s case(s) failed; via %s)\n" "$1" "$SUITE_FAIL" "$3"
  else
    printf "  ⚠ SURVIVED    %-38s -- the suite does not actually test this\n" "$1"
    MRC=1
  fi
  QUIET=0
}

mutate "floor 20 -> 0 (guard never trips)" 's/-lt 20 \]/-lt 0 ]/'                                 "the REFUSE cases"
mutate "drop the --release condition"      's/if \[ "\$DO_RELEASE" = 1 \]; then/if true; then/'    "the build-only cases"
mutate "unmeasured (-1) now blocks"        's/\[ "\$TMPFREE_GB" -ge 0 \] \&\& //'                  "the unmeasured cases"
mutate "refusal no longer exits"           's/fail "TMPDIR has only/: "TMPDIR has only/'           "rc on the REFUSE cases"
rm -f "$W"
echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
