#!/bin/bash
# prune-graphene-trees.sh [--apply] [--previous-retired YYYY-MM-DD] [--root DIR] -- remove the GrapheneOS source trees
# the Endospore release no longer needs (NWP-20261105-37; docs/release-runbook.md section 1b, step 8).
#
# WHY. Every upstream sync puts a new tag in its own /mnt/build/graphene/grapheneos-<tag> beside the current one
# (section 1b), and each tree with its out dirs is several hundred GB; /mnt/build is shared with the farm's CI. A tree
# deleted by hand can be the one a release is still built from, the one a running build has open, or the only copy of
# the signing keys. This script decides, from what is on the host, which trees may go, and by default only says so.
#
# THE RULE (Chester, 2026-11-07: "we will have an overlap of two trees for a week or so. We should only remove it by
# end of next week"):
#   KEPT  the default tree: the one build-device.sh builds from (its ENDOSPORE_TREE default, read from the script).
#   KEPT  the previous release tree: the newest tree, other than the default, that holds a releases/<BN> directory --
#         the tree the fleet's last release came from -- until the default tree's own first release has been
#         published for 7 days. That date has no reliable record on the host (a release directory is written at
#         signing, not at publishing), so the operator states it: --previous-retired <the publish date of the first
#         release from the default tree>. Without it, or when it is less than 7 days ago, or when the default tree has
#         no releases/ yet, the previous tree is kept.
#   KEPT  any tree a running process has open (its cwd, an open file, or its command line under the tree).
#   KEPT  any tree whose own keys/ directory (not a link) is not confirmed by keys-home.sh, for every device in it,
#         to match the keys home with no warning: deleting it could delete the only copy of a device's keys.
#   REMOVABLE  every other /mnt/build/graphene/grapheneos-<10 digits> tree: a tree never released from, or an older
#         released tree than the previous one.
# Only a path matching ^<root>/grapheneos-[0-9]{10}$ is ever removed; <root>/vendor and anything else are never
# touched. Default is a DRY RUN: it prints every tree, why it is kept or removable, and the bytes it would free.
# --apply removes the removable trees, after re-checking each one is not busy. Exit 0 = done (dry run or apply),
# 2 = usage, 3 = an --apply removal failed.
# Pinned by test-prune-graphene-trees.sh (--mutate).
set -u
ROOT=/mnt/build/graphene
APPLY=0
RETIRED=""
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD_DEVICE="${PRUNE_BUILD_DEVICE:-$HERE/build-device.sh}"
KEYS_HOME_SH="${PRUNE_KEYS_HOME_SH:-$HERE/keys-home.sh}"
TODAY="${PRUNE_TODAY:-$(date -u +%F)}"
PROC="${PRUNE_PROC:-/proc}"   # tests point this at a fixture
OVERLAP_DAYS=7

usage() { echo "usage: $0 [--apply] [--previous-retired YYYY-MM-DD] [--root DIR]" >&2; [ -n "${1:-}" ] && echo "  $1" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --previous-retired) [ $# -ge 2 ] || usage "--previous-retired needs a date"; RETIRED="$2"; shift ;;
    --root) [ $# -ge 2 ] || usage "--root needs a directory"; ROOT="$2"; shift ;;
    *) usage "unknown argument: $1" ;;
  esac
  shift
done
ROOT="${ROOT%/}"
if [ -n "$RETIRED" ]; then
  date -u -d "$RETIRED" +%F >/dev/null 2>&1 && [ "$(date -u -d "$RETIRED" +%F)" = "$RETIRED" ] \
    || usage "--previous-retired: not a calendar date: $RETIRED"
fi

# The default tree, read from build-device.sh -- never written here, so this cannot drift from the build.
DEFAULT="$(sed -n 's|^TREE="\${ENDOSPORE_TREE:-\(.*\)}"$|\1|p' "$BUILD_DEVICE" | head -1)"
[ -n "$DEFAULT" ] || { echo "prune: cannot read the default tree from $BUILD_DEVICE (TREE= line moved?) -- refusing" >&2; exit 2; }
DEFAULT_NAME="$(basename "$DEFAULT")"

name_ok() { printf '%s\n' "$1" | grep -Eq '^grapheneos-[0-9]{10}$'; }
newest_bn() { ls -1 "$1/releases" 2>/dev/null | grep -E '^[0-9]{10}$' | LC_ALL=C sort | tail -1; }

# The previous release tree: the newest released tree other than the default, by its newest release BN.
PREV=""; PREV_BN=""
for t in "$ROOT"/grapheneos-*; do
  [ -d "$t" ] || continue
  n="$(basename "$t")"; name_ok "$n" || continue
  [ "$n" = "$DEFAULT_NAME" ] && continue
  bn="$(newest_bn "$t")"; [ -n "$bn" ] || continue
  if [ -z "$PREV_BN" ] || [ "$bn" \> "$PREV_BN" ]; then PREV="$n"; PREV_BN="$bn"; fi
done

overlap_over() {
  # true only when the default tree has released and the operator-stated publish date is >= 7 days ago
  [ -n "$RETIRED" ] || return 1
  [ -n "$(newest_bn "$ROOT/$DEFAULT_NAME")" ] || return 1
  local d0 d1; d0=$(date -u -d "$RETIRED" +%s); d1=$(date -u -d "$TODAY" +%s)
  [ $(( (d1 - d0) / 86400 )) -ge "$OVERLAP_DAYS" ]
}

busy() {
  # a process whose cwd, open file, or command line is under the tree
  local t="$1" p l
  for p in "$PROC"/[0-9]*; do
    l=$(readlink "$p/cwd" 2>/dev/null) && case "$l/" in "$t"/*) return 0 ;; esac
    for l in "$p"/fd/*; do
      l=$(readlink "$l" 2>/dev/null) || continue
      case "$l" in "$t"/*) return 0 ;; esac
    done
    { tr '\0' ' ' < "$p/cmdline"; } 2>/dev/null | grep -qF "$t/" && return 0  # a process can exit mid-scan
  done
  return 1
}

keys_unconfirmed() {
  # the tree holds its own keys/ dir; every device in it must match the keys home with no warning
  local t="$1" d out
  [ -d "$t/keys" ] && [ ! -L "$t/keys" ] || return 1
  for d in "$t"/keys/*/; do
    [ -d "$d" ] || continue
    out=$(sh "$KEYS_HOME_SH" "$t" "$(basename "$d")" 2>&1) || { echo "$out"; return 0; }
    printf '%s\n' "$out" | grep -qi 'warn' && { echo "$out"; return 0; }
  done
  return 1
}

size_of() { du -sxb "$1" 2>/dev/null | cut -f1; }

echo "prune: root $ROOT; default tree $DEFAULT_NAME; previous release tree ${PREV:-none}${PREV_BN:+ (newest release $PREV_BN)}; today $TODAY; ${RETIRED:+first release from the default published $RETIRED; }mode $([ $APPLY = 1 ] && echo APPLY || echo 'dry run')"
REMOVE=(); FREE=0
for t in "$ROOT"/*; do
  [ -d "$t" ] || continue
  n="$(basename "$t")"
  if ! name_ok "$n"; then echo "  kept   $n -- not a grapheneos-<tag> tree, never touched"; continue; fi
  if [ "$n" = "$DEFAULT_NAME" ]; then echo "  kept   $n -- the default tree (build-device.sh)"; continue; fi
  if [ "$n" = "$PREV" ] && ! overlap_over; then
    echo "  kept   $n -- the previous release tree ($PREV_BN): kept until the default tree's first release has been published $OVERLAP_DAYS days (--previous-retired <that date>)"; continue
  fi
  if busy "$t"; then echo "  kept   $n -- a running process has it open"; continue; fi
  if k=$(keys_unconfirmed "$t"); then echo "  kept   $n -- its own keys/ is not confirmed against the keys home: $k" | head -3; continue; fi
  s=$(size_of "$t"); s=${s:-0}
  echo "  REMOVE $n -- $( [ "$n" = "$PREV" ] && echo "previous release tree, overlap over" || { [ -n "$(newest_bn "$t")" ] && echo "an older release tree" || echo "never released from"; } ) ($((s / 1073741824)) GiB)"
  REMOVE+=("$t"); FREE=$((FREE + s))
done
echo "prune: ${#REMOVE[@]} tree(s) removable, $((FREE / 1073741824)) GiB"
[ "$APPLY" = 1 ] || { echo "prune: dry run -- nothing removed; re-run with --apply to remove them"; exit 0; }
rc=0
for t in "${REMOVE[@]}"; do
  name_ok "$(basename "$t")" && [ "$(dirname "$t")" = "$ROOT" ] || { echo "prune: refusing $t (path guard)" >&2; rc=3; continue; }
  busy "$t" && { echo "prune: $t became busy -- skipped" >&2; rc=3; continue; }
  rm -rf --one-file-system -- "$t" && echo "prune: removed $t" || { echo "prune: removing $t FAILED" >&2; rc=3; }
done
exit $rc
