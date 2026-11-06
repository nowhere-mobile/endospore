#!/usr/bin/env bash
# test-create-exists-strict.sh [--mutate] -- runs create_exists_strict_test.go plus the restored-profile and promote pins
# (NWP-20261103-04); --mutate re-runs it against main.go with each guard broken in turn, restoring the file on exit.
# Each mutant must be CONVICTED by a real `--- FAIL` (one that does not apply, or does not compile, is a failure).
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'if [ -f "$W/main.go.orig" ]; then mv -f "$W/main.go.orig" main.go; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
MAIN=main.go
RUN=(go test -count=1 -run 'CreateExistsStrict|RefusesARestoredProfile|Promote' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$W/main.go.orig"
fails=0
mut() { # mut <label> <regex pattern> <repl>
  local mout
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  mout=$("${RUN[@]}" 2>&1)
  if grep -q -- '--- FAIL' <<<"$mout"; then echo "  convicted $1"
  elif [ -n "$(grep -E '\[build failed\]|^# ' <<<"$mout")" ]; then echo "  NOBUILD   $1 -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" "$MAIN"
}
LENIENT='getRef("s3", headKey("s3", name, pass)) != "", error(nil)'
mut "M1 createPrecheck back to the lenient getRef" 'headExistsStrict\("s3", name, pass\)(?=\n\tif err != nil \{\n\t\t// A refused)' "$LENIENT"
mut "M2 promoteToStore back to the lenient getRef" 'headExistsStrict\("s3", name, pass\)(?=\n\tif perr != nil \{\n\t\tfmt\.Fprintf\(os\.Stderr, "\[logind\] promote: )' "$LENIENT"
mut "M3 handlePromote2 back to the lenient getRef" 'headExistsStrict\("s3", name, newpass\)' 'getRef("s3", headKey("s3", name, newpass)) != "", error(nil)'
mut "M4 the helper ignores the error" '(err = recovered\(func\(\) \{.*?\}\)\n\tif err != nil \{\n\t\treturn false, )err' '\g<1>nil'
mut "M5 the helper uses the lenient probe" 'headRefWith\(base, name, pass, refProbeStrict\)' 'headRefWith(base, name, pass, refProbe)'
mut "M6 the helper treats a tombstone as present" '_, val, _ := headRefWith\(base, name, pass, refProbeStrict\)\n\t\texists = val != ""' '_, val, have := headRefWith(base, name, pass, refProbeStrict)\n\t\texists = val != "" || have'
mut "M7 the failed-read reply is a bare BLANK" 'fmt\.Fprint\(conn, createFailReply\("BLANK", createStagingPath\(name, pass\)\)\)' 'fmt.Fprint(conn, "BLANK\\n")'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
