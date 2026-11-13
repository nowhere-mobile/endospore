#!/usr/bin/env bash
# test-unbound-number.sh [--mutate] -- runs unbound_number_test.go (NWP-20261129-35): sealUnboundToOwner's OWNER and NONE
# replies carry "number" when the device owner's caller's-number opt-in is on, and only then, and FULL never does. The
# chooser's half is in core/chooser/test-tel-seal.sh and core/vendor-common/bin/test-tel-wire-java.sh. --mutate re-runs it
# against a COPY of core/agent under a temp root; the checked-out tree is never touched. Each mutant must be CONVICTED by
# a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/gotmp" "$W/tmp"
export GOTMPDIR="$W/gotmp" TMPDIR="$W/tmp"
RUN=(go test -count=1 -run '^TestUnboundNumber' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

SRC=telephony_owner.go
cp -a . "$W/agent"
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>: every match in the copy of $SRC
  local res rc
  cp -f "$SRC" "$W/agent/$SRC"
  python3 - "$W/agent/$SRC" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s)
if c<1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$(cd "$W/agent" && "${RUN[@]}" 2>&1); rc=$?
  score_mutant "$1" "$rc" "$res" || fails=$((fails+1))
}
mut "W4 the token on OWNER only" 'return unboundNoticeReply\("NONE"\), telVerdictUnbound' 'return "NONE\\n", telVerdictUnbound'
mut "W5 the token sent with the flag off" 'if noticeNumberGet\(\) == "1" \{\n\t\treturn word' 'if true {\n\t\treturn word'
mut "W6 the token added to FULL" 'return "FULL\\n", telVerdictOwnerFull' 'return unboundNoticeReply("FULL"), telVerdictOwnerFull'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
