#!/usr/bin/env bash
# test-prebuilt-pins.sh -- NWP-20261011-22. Every prebuilt APK the shared Android.bp imports is pinned, and the
# committed ones reach the staged tree.
#
# WHY THIS EXISTS. WireGuard.apk is committed (c16fde47: not on F-Droid), but it had no row in
# default-apps.manifest (no sha, no stated source) and both stage-vendor.sh scripts rsync core/vendor-common with
# --exclude 'prebuilts/*.apk' to protect the fetched APKs -- which kept the committed one out too. A fresh stage
# failed Soong on "prebuilts/WireGuard.apk does not exist"; both lanes built only because a hand-copied APK sat in
# each staged tree. Each half is silent until a fresh tree.
#
#   (a) every `apk: "prebuilts/<X>.apk"` in core/vendor-common/Android.bp has a manifest row named <X>;
#   (b) every git-tracked prebuilts/*.apk has a manifest row marked `manual` whose SHA256 is the tracked blob's;
#   (c) the tracked-APK copy block of EACH stage-vendor.sh, extracted by its anchors and run against a fake repo,
#       stages a tracked APK (and not an untracked one), fails when it cannot copy one, and in a non-git export
#       stages WireGuard.apk;
#   (d) fetch-default-apps.sh, run against a scratch manifest with curl stubbed, never fetches a `manual` row:
#       absent -> it fails naming the source comment; present with the pin -> skipped. A plain row still fetches.
#
# --mutate re-runs the checks against broken copies, each of which must FAIL: the WireGuard row deleted (a), its
# sha altered (b), the copy block or its install dropped, or a failed copy swallowed, in each stage script (c), the
# `manual` column dropped (b, d).
#
# Needs bash, git, sha256sum, sed. Run from anywhere:  bash core/vendor-common/prebuilts/test-prebuilt-pins.sh [--mutate]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
MANIFEST="$HERE/default-apps.manifest"
BP="$ROOT/core/vendor-common/Android.bp"
FETCH="$HERE/fetch-default-apps.sh"
STAGES=("$ROOT/editions/endospore/build/stage-vendor.sh" "$ROOT/editions/diaspore/build/stage-vendor.sh")
for f in "$MANIFEST" "$BP" "$FETCH" "${STAGES[@]}"; do
  [ -r "$f" ] || { echo "cannot read $f" >&2; exit 2; }
done
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "$ROOT is not a git checkout" >&2; exit 2; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

rows() { sed -e 's/#.*//' "$1" | awk 'NF { print }'; }   # manifest data rows, comments stripped

# (a) <manifest> <Android.bp>
check_a() {
  local bad=0 x
  for x in $(sed -n 's/^[[:space:]]*apk:[[:space:]]*"prebuilts\/\([^"\/]*\)\.apk".*/\1/p' "$2"); do
    if ! rows "$1" | awk -v n="$x" '$1 == n { f = 1 } END { exit !f }'; then
      echo "  FAIL (a) Android.bp imports prebuilts/$x.apk but default-apps.manifest has no '$x' row"
      bad=1
    fi
  done
  [ -n "$(sed -n 's/^[[:space:]]*apk:[[:space:]]*"prebuilts\///p' "$2")" ] || { echo "  FAIL (a) no prebuilts apk found in $2"; bad=1; }
  return $bad
}

# (b) <manifest>  (against the real repo's index)
check_b() {
  local bad=0 n=0 f name row want got
  while IFS= read -r f; do
    n=$((n+1))
    name="$(basename "$f" .apk)"
    row="$(rows "$1" | awk -v n="$name" '$1 == n')"
    if [ -z "$row" ]; then
      echo "  FAIL (b) $f is git-tracked but has no manifest row (unpinned)"; bad=1; continue
    fi
    want="$(echo "$row" | awk '{ print $4 }')"
    got="$(git -C "$ROOT" cat-file blob ":$f" | sha256sum | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then
      echo "  FAIL (b) $name: manifest sha $want, tracked blob sha $got"; bad=1
    fi
    if [ "$(echo "$row" | awk '{ print $5 }')" != "manual" ]; then
      echo "  FAIL (b) $name is committed but its row is not marked manual (fetch would try F-Droid)"; bad=1
    fi
  done < <(git -C "$ROOT" ls-files -- 'core/vendor-common/prebuilts/*.apk')
  [ "$n" -gt 0 ] || { echo "  FAIL (b) no git-tracked prebuilts/*.apk (WireGuard.apk is expected)"; bad=1; }
  return $bad
}

# The block runs under the stage script's own `set -euo pipefail`. A fresh bash, not a subshell: errexit is
# ignored inside a subshell that is the left side of `||`, which would hide a failing copy.
run_block() { bash -c 'set -euo pipefail; REPO=$1; DEST=$2; mkdir -p "$DEST"; eval "$3"' _ "$2" "$3" "$1"; }

# (c) <stage-vendor.sh>
check_c() {
  local block d bad=0
  block="$(sed -n '/^# >>> tracked prebuilt APKs/,/^# <<< tracked prebuilt APKs/p' "$1")"
  if [ -z "$block" ]; then
    echo "  FAIL (c) $(basename "$(dirname "$(dirname "$1")")"): no tracked-APK copy block in $1"; return 1
  fi
  d="$(mktemp -d "$SCRATCH/c.XXXXXX")"
  # a git checkout: one tracked APK, one untracked (a fetched one -- the rsync protects those; not ours to copy)
  mkdir -p "$d/repo/core/vendor-common/prebuilts" "$d/dest"
  echo tracked > "$d/repo/core/vendor-common/prebuilts/Tracked.apk"
  echo fetched > "$d/repo/core/vendor-common/prebuilts/Fetched.apk"
  git -C "$d/repo" init -q && git -C "$d/repo" add core/vendor-common/prebuilts/Tracked.apk
  run_block "$block" "$d/repo" "$d/dest" >/dev/null || { echo "  FAIL (c) $1: block errored (git checkout)"; bad=1; }
  cmp -s "$d/repo/core/vendor-common/prebuilts/Tracked.apk" "$d/dest/prebuilts/Tracked.apk" \
    || { echo "  FAIL (c) $1: tracked APK not staged into DEST/prebuilts"; bad=1; }
  [ ! -e "$d/dest/prebuilts/Fetched.apk" ] || { echo "  FAIL (c) $1: an untracked APK was staged"; bad=1; }
  # a non-git export (nested inside another checkout, as a scratch dir can be: only $REPO's own root counts)
  git -C "$d" init -q
  mkdir -p "$d/export/core/vendor-common/prebuilts" "$d/dest2"
  echo wg > "$d/export/core/vendor-common/prebuilts/WireGuard.apk"
  run_block "$block" "$d/export" "$d/dest2" >/dev/null || { echo "  FAIL (c) $1: block errored (non-git export)"; bad=1; }
  cmp -s "$d/export/core/vendor-common/prebuilts/WireGuard.apk" "$d/dest2/prebuilts/WireGuard.apk" \
    || { echo "  FAIL (c) $1: WireGuard.apk not staged from a non-git export"; bad=1; }
  # a tracked APK missing from the worktree must fail the stage, not leave Soong to find the hole
  rm "$d/repo/core/vendor-common/prebuilts/Tracked.apk"
  if run_block "$block" "$d/repo" "$d/dest3" >/dev/null 2>&1; then
    echo "  FAIL (c) $1: a tracked APK that could not be copied did not fail the stage"; bad=1
  fi
  return $bad
}

# (d) <manifest to derive the scratch one from>
check_d() {
  local d bad=0 out wgsha
  d="$(mktemp -d "$SCRATCH/d.XXXXXX")"
  mkdir -p "$d/bin" "$d/vendor/x/prebuilts"
  cp "$FETCH" "$d/vendor/x/prebuilts/fetch-default-apps.sh"
  # curl stub: record the call, write a fixed body
  printf '#!/bin/sh\necho "$@" >> "%s/curl.log"\nwhile [ $# -gt 1 ]; do [ "$1" = -o ] && { echo plain > "$2"; exit 0; }; shift; done\nexit 22\n' "$d" > "$d/bin/curl"
  chmod +x "$d/bin/curl"
  local plainsha; plainsha="$(echo plain | sha256sum | cut -d' ' -f1)"
  wgsha="$(echo wg | sha256sum | cut -d' ' -f1)"
  # the WireGuard row and the comment above it, from the manifest under test, with the sha re-pointed at the fixture
  awk '/^#/ { c = c $0 "\n"; next } $1 == "WireGuard" { printf "%s", c; print; exit } { c = "" }' "$1" \
    | sed "s/^\(WireGuard[[:space:]].*[[:space:]]\)[0-9a-f]\{64\}/\1$wgsha/" > "$d/wg.rows"
  { echo "Plain org.example.plain 1 $plainsha"; cat "$d/wg.rows"; } > "$d/vendor/x/prebuilts/default-apps.manifest"
  fetch_run() { ( cd "$d" && PATH="$d/bin:$PATH" JNI_APPS=" " bash vendor/x/prebuilts/fetch-default-apps.sh ) 2>&1; }

  # absent -> fails, names the source, no F-Droid URL for WireGuard
  rm -f "$d/curl.log"
  if out="$(fetch_run)"; then echo "  FAIL (d) fetch succeeded with the manual WireGuard.apk absent"; bad=1; fi
  if grep -q 'wireguard' "$d/curl.log" 2>/dev/null; then echo "  FAIL (d) fetch tried F-Droid for the manual WireGuard row"; bad=1; fi
  grep -q 'MISSING manual prebuilt WireGuard.apk' <<<"$out" || { echo "  FAIL (d) no MISSING line for WireGuard"; bad=1; }
  grep -q 'COMMITTED in-repo' <<<"$out" || { echo "  FAIL (d) the failure does not print WireGuard's source comment"; bad=1; }
  grep -q 'org.example.plain_1.apk' "$d/curl.log" 2>/dev/null || { echo "  FAIL (d) a plain row was not fetched from F-Droid"; bad=1; }

  # present with the pin -> skipped, run succeeds
  echo wg > "$d/vendor/x/prebuilts/WireGuard.apk"
  rm -f "$d/curl.log"
  out="$(fetch_run)" || { echo "  FAIL (d) fetch failed with the manual WireGuard.apk present at its pin"; echo "$out" | sed 's/^/      /'; bad=1; }
  grep -q 'ok   WireGuard (cached, sha ok)' <<<"$out" || { echo "  FAIL (d) WireGuard not reported cached"; bad=1; }

  # present with another sha -> fails, file left in place
  echo other > "$d/vendor/x/prebuilts/WireGuard.apk"
  rm -f "$d/curl.log"
  if fetch_run >/dev/null; then echo "  FAIL (d) fetch accepted a manual APK with the wrong sha"; bad=1; fi
  grep -q 'wireguard' "$d/curl.log" 2>/dev/null && { echo "  FAIL (d) fetch tried F-Droid over a mismatched manual APK"; bad=1; }
  [ "$(cat "$d/vendor/x/prebuilts/WireGuard.apk")" = other ] || { echo "  FAIL (d) a mismatched manual APK was removed"; bad=1; }
  return $bad
}

run_all() { # <manifest> <stage scripts...>
  local m="$1" bad=0 s; shift
  check_a "$m" "$BP" && echo "  ok   (a) every Android.bp prebuilt APK has a manifest row" || bad=1
  check_b "$m"       && echo "  ok   (b) every tracked APK is a manual row pinned to its blob's sha" || bad=1
  for s in "$@"; do
    check_c "$s"     && echo "  ok   (c) $(basename "$(dirname "$(dirname "$s")")") stage-vendor.sh stages tracked APKs" || bad=1
  done
  check_d "$m"       && echo "  ok   (d) fetch-default-apps.sh never fetches a manual row" || bad=1
  return $bad
}

if [ "${1:-}" != "--mutate" ]; then
  if run_all "$MANIFEST" "${STAGES[@]}"; then echo "PASS: prebuilt APK pins and staging"; exit 0; fi
  echo "FAIL" >&2; exit 1
fi

# --mutate: each broken copy must be convicted by the check it targets.
survived=0
expect_fail() { # <label> <cmd...>
  if "${@:2}" >/dev/null 2>&1; then echo "  SURVIVED $1"; survived=$((survived+1)); else echo "  killed   $1"; fi
}
M="$SCRATCH/m"; mkdir -p "$M"
grep -v '^WireGuard[[:space:]]' "$MANIFEST" > "$M/no-wg.manifest"
expect_fail "WireGuard manifest row deleted -> (a)" check_a "$M/no-wg.manifest" "$BP"
wgsha="$(awk '$1 == "WireGuard" { print $4 }' "$MANIFEST")"
sed "s/$wgsha/$(printf '0%.0s' $(seq 64))/" "$MANIFEST" > "$M/bad-sha.manifest"
cmp -s "$MANIFEST" "$M/bad-sha.manifest" && { echo "mutation did not change the sha" >&2; exit 2; }
expect_fail "WireGuard sha altered -> (b)" check_b "$M/bad-sha.manifest"
sed 's/^\(WireGuard[[:space:]].*\)[[:space:]]manual[[:space:]]*$/\1/' "$MANIFEST" > "$M/not-manual.manifest"
cmp -s "$MANIFEST" "$M/not-manual.manifest" && { echo "mutation did not drop the manual column" >&2; exit 2; }
expect_fail "WireGuard not marked manual -> (b)" check_b "$M/not-manual.manifest"
expect_fail "WireGuard not marked manual -> (d)" check_d "$M/not-manual.manifest"
for s in "${STAGES[@]}"; do
  ed="$(basename "$(dirname "$(dirname "$s")")")"
  sed '/^# >>> tracked prebuilt APKs/,/^# <<< tracked prebuilt APKs/d' "$s" > "$M/$ed-noblock.sh"
  expect_fail "$ed copy block dropped -> (c)" check_c "$M/$ed-noblock.sh"
  # the block kept, its anchors kept, the copy itself gone
  sed '/^# >>> tracked prebuilt APKs/,/^# <<< tracked prebuilt APKs/{/install -m644/d}' "$s" > "$M/$ed-noinstall.sh"
  expect_fail "$ed copy line dropped -> (c)" check_c "$M/$ed-noinstall.sh"
  sed '/^# >>> tracked prebuilt APKs/,/^# <<< tracked prebuilt APKs/s/^\([[:space:]]*install -m644 .*\)$/\1 || true/' "$s" > "$M/$ed-swallow.sh"
  cmp -s "$s" "$M/$ed-swallow.sh" && { echo "mutation did not reach the install line" >&2; exit 2; }
  expect_fail "$ed copy failure swallowed -> (c)" check_c "$M/$ed-swallow.sh"
done
if [ "$survived" -eq 0 ]; then echo "PASS: every mutation killed"; exit 0; fi
echo "FAIL: $survived mutation(s) survived" >&2; exit 1
