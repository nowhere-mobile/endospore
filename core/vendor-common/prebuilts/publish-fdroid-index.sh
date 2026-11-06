#!/bin/bash
# publish-fdroid-index.sh -- Phase A pipeline for the app store's full-catalog F-Droid search
# (docs/store-fdroid-search.md). ONE command, meant to run periodically (cron) on the signing host:
#
#   1. trim-fdroid-index.py  -> verify F-Droid's PINNED repo cert (via entry.jar) + trim ALL apps -> index.json
#   2. build-icon-pack.py    -> fetch+downscale every icon -> icons.pack (ZIP keyed by pkg, served locally)
#   3. sign-catalog.sh sign  -> ed25519-sign BOTH with the SEPARATE index key -> index.json.sig / icons.pack.sig
#   4. write fdroid-index.lock -> the sha256 of all four files plus the index key's public half. The Endospore
#      stage (stage-vendor.sh) refuses a set that does not match the lock written beside it, or whose index-pubkey
#      is not the agent's indexPubKey (NWP-20261029-15); no lock is committed to the repo.
#   5. (optional) publish the four files to the R2 host that INDEX_URL points at, for the device's lazy refresh.
#
# The index key is an ONLINE/automation key (unlike the offline catalog key) -- it lives on THIS host so the job
# can sign each fresh index without a human. Smaller blast radius by design: a leak can push a poisoned index but
# canNOT forge a catalog override (separate key from catalogPubKey; see docs/store-fdroid-search.md).
#
#   publish-fdroid-index.sh [OUTDIR]        (default /mnt/build/fdroid-index)
#   env: INDEX_SIGNING_KEY (default /mnt/build/keys/index-signing.key), ABI (default arm64-v8a),
#        R2_DEST (e.g. "nowhere:nowhere/fdroid" -- if set, step 5 uploads; set without rclone it FAILS)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-/mnt/build/fdroid-index}
KEY=${INDEX_SIGNING_KEY:-/mnt/build/keys/index-signing.key}
ABI=${ABI:-arm64-v8a}
[ -f "$KEY" ] || { echo "FATAL index signing key not found: $KEY" >&2; exit 1; }

# The index key's public half must be the agent's indexPubKey. The Endospore stage checks only the BAKED set; the
# lazy-refresh set uploaded to the INDEX_URL host had no check, so a run with the wrong INDEX_SIGNING_KEY published
# a set every phone's REFRESH-INDEX rejects on read (index.go verifyEd25519) and still printed DONE. INDEX_GO
# lets a run outside a repo checkout point at a copy of index.go.
INDEX_GO=${INDEX_GO:-$HERE/../../agent/index.go}
AGENT_PUB=$(sed -n 's/^var indexPubKey = "\([^"]*\)".*/\1/p' "$INDEX_GO" 2>/dev/null || true)
case "$AGENT_PUB" in
  ""|*$'\n'*) echo "FATAL cannot read indexPubKey from $INDEX_GO" >&2; exit 1 ;;
esac
PUB=$(bash "$HERE/sign-catalog.sh" pubkey "$KEY")
if [ "$PUB" != "$AGENT_PUB" ]; then
  echo "FATAL the index key's public half is not index.go's indexPubKey -- nothing trimmed, signed or uploaded" >&2; exit 1
fi
mkdir -p "$OUT"

echo "=== [1/5] trim F-Droid index (verifies pinned repo cert) ==="
python3 "$HERE/trim-fdroid-index.py" "$OUT/index.json" --abi "$ABI"

echo "=== [2/5] build icon pack ==="
python3 "$HERE/build-icon-pack.py" "$OUT/index.json" "$OUT/icons.pack" --workers 24

echo "=== [3/5] sign both with the index key ==="
bash "$HERE/sign-catalog.sh" sign "$OUT/index.json" "$KEY" | sed 's/^/  /'
bash "$HERE/sign-catalog.sh" sign "$OUT/icons.pack" "$KEY" | sed 's/^/  /'
# fail-closed: refuse to publish a set that doesn't verify against the key's own public half
bash "$HERE/sign-catalog.sh" verify "$OUT/index.json" "$PUB" >/dev/null
bash "$HERE/sign-catalog.sh" verify "$OUT/icons.pack" "$PUB" >/dev/null
echo "  both signatures verify against $PUB"

echo "=== [4/5] hash-pin lockfile (reproducible /system bake) ==="
LOCK="$OUT/fdroid-index.lock"
{
  echo "# fdroid-index lockfile -- pin for a reproducible /system bake. Regenerated each publish."
  echo "# index-pubkey: $PUB"
  for f in index.json index.json.sig icons.pack icons.pack.sig; do
    echo "$(sha256sum "$OUT/$f" | cut -d' ' -f1)  $f"
  done
} > "$LOCK"
cat "$LOCK"

echo "=== [5/5] publish to R2 (INDEX_URL host) ==="
if [ -n "${R2_DEST:-}" ]; then
  command -v rclone >/dev/null || { echo "FATAL R2_DEST is set but rclone is not installed -- nothing uploaded" >&2; exit 1; }
  for f in index.json index.json.sig icons.pack icons.pack.sig; do
    rclone copyto "$OUT/$f" "$R2_DEST/$f"
  done
  echo "  uploaded 4 files to $R2_DEST"
else
  echo "  SKIPPED (set R2_DEST + install rclone to enable the device's lazy REFRESH-INDEX source)."
  echo "  The BAKED /system snapshot is produced from these files at build time regardless."
fi

echo "DONE: $(ls -la "$OUT"/index.json "$OUT"/icons.pack | awk '{s+=$5} END{printf \"%.1f MB signed index+icons\", s/1e6}')"
