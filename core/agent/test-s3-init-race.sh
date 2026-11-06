#!/usr/bin/env bash
# test-s3-init-race.sh [--mutate] -- runs s3_init_race_test.go (NWP-20261128-02). s3Init returns the store client and
# bucket it holds under s3InitMu, and every store call uses that pair for the whole call. R2
# (TestS3InitGlobalsOnlyInSetupAndResets, a go/ast scan, plain go test) keeps s3client and s3bucket inside s3Init and the
# two resets. R1 (TestS3InitRace_StoreSwitchDuringStoreCalls, go test -race) runs store calls against concurrent
# SET-STORE switches between two fake stores: no panic, no DATA RACE, no request for the other store's bucket. -race
# needs cgo, so a host without gcc fails here. --mutate re-runs R2 against a COPY of core/agent under a temp root, one
# caller broken in turn; the checked-out tree is never touched. Each mutant must be CONVICTED by a named `--- FAIL` of
# R2; one that fails to apply, or fails to compile, counts as a failure. Mutants: M1 s3GetMax's GetObject reads the
# global s3client; M2 s3PutGuarded's PutObject reads the global s3bucket; M3 s3ExistsErr (export_rekey.go) reads the
# global s3client; M4 handlePingStore's BucketExists reads both globals. The resets' environment writes under the lock
# are held by R1's bucket assertion only: convicting their removal needs an interleaving, so they have no CI mutant.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/gotmp" "$W/tmp"
export GOTMPDIR="$W/gotmp" TMPDIR="$W/tmp"
go version
R2=TestS3InitGlobalsOnlyInSetupAndResets
R1=TestS3InitRace_StoreSwitchDuringStoreCalls
R2RUN=(go test -count=1 -v -run "^$R2\$" .)

out=$("${R2RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
gccv=$(gcc --version 2>&1) || { printf '%s\n' "$gccv"; echo "FAIL: go test -race needs cgo, and gcc is missing"; exit 1; }
head -n 1 <<<"$gccv"
out=$(CGO_ENABLED=1 go test -race -count=1 -v -run "^$R1\$" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
races=$(grep -F 'WARNING: DATA RACE' <<<"$out" || true)
[ -z "$races" ] || { printf '%s\n' "$out"; echo "FAIL: the race detector reported a race"; exit 1; }
passed=$(grep -E "^--- PASS: $R1 \\(" <<<"$out" || true)
[ -n "$passed" ] || { printf '%s\n' "$out"; echo "FAIL: $R1 printed no --- PASS line"; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

cp -a . "$W/agent"
fails=0
mut() { # mut <label> <file> <function> <old> <new> [<old> <new> ...]  (literal replaces inside one function of the copy)
  local label="$1" file="$2" fn="$3" res rc named
  shift 3
  cp -f main.go "$W/agent/main.go"
  cp -f export_rekey.go "$W/agent/export_rekey.go"
  python3 -I - "$W/agent/$file" "$fn" "$@" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import sys
p, fn = sys.argv[1:3]
pairs = sys.argv[3:]
if not pairs or len(pairs) % 2:
    sys.exit(1)
s = open(p).read()
head = "\nfunc " + fn + "("
if s.count(head) != 1:
    sys.exit(1)
a = s.index(head)
b = s.find("\n}\n", a)
if b < 0:
    sys.exit(1)
body = s[a:b]
for old, new in zip(pairs[0::2], pairs[1::2]):
    if body.count(old) != 1:
        sys.exit(1)
    body = body.replace(old, new)
open(p, "w").write(s[:a] + body + s[b:])
PY
  res=$(cd "$W/agent" && "${R2RUN[@]}" 2>&1); rc=$?
  named=$(grep -F -- "--- FAIL: $R2 " <<<"$res" || true)
  if [ "$rc" -ne 0 ] && [ -z "$named" ] && [[ "$res" != *'build failed'* ]]; then
    echo "  BROKEN    $label -- the run failed without a --- FAIL line for $R2"
    tail -n 15 <<<"$res"
    fails=$((fails+1))
    return
  fi
  score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
}
mut "M1 s3GetMax's GetObject reads the global s3client" main.go s3GetMax \
  "cl, bk := s3Init()" "_, bk := s3Init()" \
  "cl.GetObject(" "s3client.GetObject("
mut "M2 s3PutGuarded's PutObject reads the global s3bucket" main.go s3PutGuarded \
  "cl, bk := s3Init()" "cl, _ := s3Init()" \
  "cl.PutObject(context.Background(), bk," "cl.PutObject(context.Background(), s3bucket,"
mut "M3 s3ExistsErr's StatObject reads the global s3client" export_rekey.go s3ExistsErr \
  "cl, bk := s3Init()" "_, bk := s3Init()" \
  "cl.StatObject(" "s3client.StatObject("
mut "M4 handlePingStore's BucketExists reads the globals" main.go handlePingStore \
  "cl, bk := s3Init()" "cl, _ := s3Init()" \
  "cl.BucketExists(ctx, bk)" "s3client.BucketExists(ctx, s3bucket)"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
