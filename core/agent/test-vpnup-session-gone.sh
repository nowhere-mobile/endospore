#!/usr/bin/env bash
# test-vpnup-session-gone.sh [--mutate] -- runs vpnup_session_gone_test.go (NWP-20261113-20, backlog "A `vpnup` worker
# op ran for a user after that user's reap": retryVpnup re-reads the marker before every try and stops once it is
# absent or names another uid); --mutate re-runs it against a COPY of the package with the check broken in turn. Each
# mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestVpnupSessionGone' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
# mut <label> <file> <python-regex> <replacement>: apply to the copy, run the suite there, then restore the file.
mut() {
  local label="$1" f="$2" res rc
  cp "$P/$f" "$W/orig.go" || exit 2
  if python3 - "$P/$f" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
    score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
CHECK='if _, _, mu, st := readRoamSessionState\(dest\); st == roamSessionAbsent \|\| \(mu != "" && mu != uid\) \{'
mut "M1 the check is dropped" main.go \
  "\t\t$CHECK\n.*?\n\t\t\}\n" ''
mut "M2 the check runs only before the first try" main.go \
  "$CHECK" \
  'if _, _, mu, st := readRoamSessionState(dest); i == 0 && (st == roamSessionAbsent || (mu != "" && mu != uid)) {'
mut "M3 the check compares the marker's name instead of its uid" main.go \
  "$CHECK" \
  'if mu, _, _, st := readRoamSessionState(dest); st == roamSessionAbsent || (mu != "" && mu != name) {'
mut "M4 the marker is read with readRoamSession and an empty uid stops" main.go \
  "$CHECK" \
  'if _, _, mu := readRoamSession(dest); mu == "" || mu != uid {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
