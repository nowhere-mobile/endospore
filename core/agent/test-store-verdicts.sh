#!/usr/bin/env bash
# test-store-verdicts.sh [--mutate] -- runs store_verdicts_test.go and the store-verb caller tests (NWP-20261120-21):
# TEST-STORE and PING-STORE, driven through handleLogin against a local S3 fake, answer OK (200), ERR-AUTH (403),
# ERR-BUCKET (404), ERR-NET (a closed port), ERR-CONFIG (TEST-STORE, an endpoint with a path) and ERR-NOSTORE
# (PING-STORE, no keys). BucketExists sends a HEAD, whose error response has no body, so the 403 status arm is the only
# one that maps a wrong key to ERR-AUTH. PING-STORE answers OK MANAGED only in cap mode, a gateway and no keys; a
# self-hosted store with a GATEWAY_URL keeps its S3 probe (NWP-20261129-41). --mutate re-runs the tests against a COPY of core/agent under a temp root,
# main.go broken in turn; the checked-out tree is never touched. Each mutant must be CONVICTED by a `--- FAIL`; one
# that fails to apply, or fails to compile, counts as a failure. Each anchor is pinned byte for byte and must occur
# exactly once in its function. Mutants: M1 handleTestStore drops the 403 status arm; M2 handlePingStore drops it;
# M3 handleTestStore answers OK for a missing bucket; M4 handlePingStore answers ERR-AUTH for an unreachable store;
# M5 handlePingStore's managed arm keyed on GATEWAY_URL again.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/gotmp" "$W/tmp"
export GOTMPDIR="$W/gotmp" TMPDIR="$W/tmp"
RUN=(go test -count=1 -run '^TestStoreVerdict|^TestStoreVerbs' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp -a . "$W/agent"
fails=0
mut() { # mut <label> <function> <anchor> <replacement>  (a literal replace inside one function of the copy's main.go)
  local res rc
  cp -f main.go "$W/agent/main.go"
  python3 -I - "$W/agent/main.go" "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import sys
p, fn, old, new = sys.argv[1:5]
s = open(p).read()
head = "\nfunc " + fn + "("
if s.count(head) != 1:
    sys.exit(1)
a = s.index(head)
b = s.find("\n}\n", a)
if b < 0:
    sys.exit(1)
body = s[a:b]
if body.count(old) != 1:
    sys.exit(1)
open(p, "w").write(s[:a] + body.replace(old, new) + s[b:])
PY
  res=$(cd "$W/agent" && "${RUN[@]}" 2>&1); rc=$?
  score_mutant "$1" "$rc" "$res" || fails=$((fails+1))
}
T=$'\t'
AUTH="$T${T}if er.Code == \"InvalidAccessKeyId\" || er.Code == \"SignatureDoesNotMatch\" || er.StatusCode == 403 {"
NOSTATUS="$T${T}if er.Code == \"InvalidAccessKeyId\" || er.Code == \"SignatureDoesNotMatch\" {"
mut "M1 handleTestStore drops the 403 status arm" handleTestStore "$AUTH" "$NOSTATUS"
mut "M2 handlePingStore drops the 403 status arm" handlePingStore "$AUTH" "$NOSTATUS"
mut "M3 handleTestStore answers OK for a missing bucket" handleTestStore \
  "$T${T}fmt.Fprint(conn, \"ERR-BUCKET\\n\") // creds OK but the bucket is missing / not visible" \
  "$T${T}fmt.Fprint(conn, \"OK\\n\") // M3"
mut "M4 handlePingStore answers ERR-AUTH for an unreachable store" handlePingStore \
  "$T$T${T}fmt.Fprint(conn, \"ERR-NET\\n\") // can't reach the endpoint (DNS/TLS/host/offline)" \
  "$T$T${T}fmt.Fprint(conn, \"ERR-AUTH\\n\") // M4"
mut "M5 handlePingStore's managed arm keyed on GATEWAY_URL again" handlePingStore \
  "${T}if capMode() {" \
  "${T}if os.Getenv(\"GATEWAY_URL\") != \"\" {"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
