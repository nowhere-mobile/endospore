#!/usr/bin/env bash
# test-cdc-goldens.sh [--mutate] -- runs cdc_golden_test.go (NWP-20261104-10); --mutate re-runs it against main.go and
# incremental_seal.go with each pinned input broken in turn, restoring both files on exit. Each mutant must be
# CONVICTED (a real --- FAIL; one that fails to apply or to compile counts as a failure).
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig" && cp incremental_seal.go "$W/incremental_seal.go.orig" || { rm -rf "$W"; exit 2; }
trap 'cp -f "$W/main.go.orig" main.go; cp -f "$W/incremental_seal.go.orig" incremental_seal.go; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run '^(TestEssentialChunksGolden|TestCDCBoundariesGolden|TestEssentialEntryTarHeaderShape)$' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <literal> <replacement>
  local label="$1" f="$2" res rc
  python3 - "$f" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the literal is not in $f exactly once"; fails=$((fails+1)); return; }
import sys
p, lit, rep = sys.argv[1:4]
s = open(p).read()
if s.count(lit) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(lit, rep))
PY
  res=$("${RUN[@]}" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $label"
  else echo "  SURVIVED  $label (rc=$rc, no --- FAIL)"; fails=$((fails+1)); fi
  cp -f "$W/$f.orig" "$f"
}
mut "C1 packChunk returns its input"     main.go 'return zstdEnc.EncodeAll(c, nil)' 'return c'
mut "C2 seal nonce from an unkeyed hash" main.go 'mac := hmac.New(sha256.New, key)' 'mac := sha256.New()'
mut "C3 tar uid 1"                       incremental_seal.go 'hdr.Uid, hdr.Gid = 0, 0' 'hdr.Uid, hdr.Gid = 1, 0'
mut "C4 cdcMax 128 KiB"                  main.go 'cdcMax  = 4 * 1024 * 1024' 'cdcMax  = 128 * 1024'
mut "C5 fragment gets a trailer"         incremental_seal.go 'return torn, tw.Flush()' 'return torn, tw.Close()'
mut "C6 gear seed +1"                    main.go 'x := uint64(0x9E3779B97F4A7C15)' 'x := uint64(0x9E3779B97F4A7C16)'
mut "C7 cdcMask 2^19-1"                  main.go 'cdcMask = (1 << 20) - 1' 'cdcMask = (1 << 19) - 1'
mut "C8 cdcMin 512 KiB"                  main.go 'cdcMin  = 256 * 1024' 'cdcMin  = 512 * 1024'
[ "$fails" -eq 0 ] || { echo "$fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
