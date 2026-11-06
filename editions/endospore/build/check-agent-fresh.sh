#!/usr/bin/env bash
# check-agent-fresh.sh <agent-binary> -- is this agent_host built from the CURRENT core/agent source?
#
#   exit 0   fresh: no source file is newer than the binary
#   exit 1   STALE: at least one source file is newer -- the caller must refuse
#   exit 2   CANNOT DETERMINE -- the caller must say so out loud, never proceed quietly
#
# WHY THIS EXISTS. e4-ota-publish.sh and e4-ota-promote.sh both test only `[ -x "$AGENT" ]`. That answers
# "is there a file there", not "is it this code" -- so a binary built weeks ago publishes silently, and the
# thing it writes is the OTA marker every fielded device reads. Rebuilt by hand before three consecutive
# releases (0.5.33, 0.5.34, 0.5.35) purely because someone remembered; the fourth time nobody would have.
#
# ⚠ EXIT 2 IS NOT EXIT 0. The whole failure this guard exists to end is a check that cannot run being
# indistinguishable from a check that passed -- which happened three times in one day on 2026-09-13/14
# (a wrong APK path that printed nothing, a javac of a file nobody had edited, and a `[ -s ]` that was true
# for a directory). So "I could not find the source" is its own exit code and the callers print it.
#
# WHICH FILES COUNT: *.go, *.s, go.mod and go.sum anywhere under core/agent, third_party/ included. The .go
# and .s files are compiled in; go.mod and go.sum select every dependency compiled in (minio-go,
# klauspost/compress, x/crypto, bip39, the vendored go-fuse), so a bump that touches only those two changes
# the binary without touching a .go file. A newer non-source file (a README, notes) still does not trip it.
#
# Mtime comparison, deliberately, not a content hash: the question is "was the source touched after the
# binary was built", and `git pull` restamps exactly the files it changed. An unrelated .go file changing
# also trips it -- that is the safe direction, and the rebuild costs about ten seconds.
set -uo pipefail

AGENT="${1:-}"
[ -n "$AGENT" ] || { echo "usage: check-agent-fresh.sh <agent-binary>" >&2; exit 2; }
[ -f "$AGENT" ] || { echo "check-agent-fresh: no binary at $AGENT" >&2; exit 2; }

# The repo root is three levels up from editions/endospore/build/. Resolved from THIS script's own path so
# it keeps working from any cwd and from a linked worktree.
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${NOWHERE_AGENT_SRC:-$(cd "$HERE/../../.." 2>/dev/null && pwd)/core/agent}"

if [ ! -d "$SRC" ]; then
  echo "check-agent-fresh: CANNOT DETERMINE -- no agent source at $SRC" >&2
  exit 2
fi

# -print -quit: stop at the first newer file; we need existence, not a list.
NEWER="$(find "$SRC" \( -name '*.go' -o -name '*.s' -o -name 'go.mod' -o -name 'go.sum' \) -newer "$AGENT" -print -quit 2>/dev/null)"
FINDRC=$?
if [ "$FINDRC" != 0 ]; then
  echo "check-agent-fresh: CANNOT DETERMINE -- find failed over $SRC (rc=$FINDRC)" >&2
  exit 2
fi

if [ -n "$NEWER" ]; then
  echo "check-agent-fresh: STALE -- $(basename "$NEWER") is newer than $AGENT" >&2
  exit 1
fi
exit 0
