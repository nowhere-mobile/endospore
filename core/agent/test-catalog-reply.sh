#!/usr/bin/env bash
# test-catalog-reply.sh [--mutate] -- runs the TestGetCatalogReply_* tests (NWP-20261119-31): GET-CATALOG's reply frame,
# `OK <len>\n` + the bytes, ERR-SIG and NONE. --mutate re-runs them against catalog.go with the frame broken in turn,
# restoring the file on exit. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile
# is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
CAT=catalog.go
trap '[ -f "$W/$CAT.orig" ] && cp -f "$W/$CAT.orig" "$CAT"; rm -rf "$W"' EXIT
RUN=(go test -count=1 -run 'TestGetCatalogReply' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$CAT" "$W/$CAT.orig"
fails=0
mut() { # mut <label> <regex pattern> <repl>
  local label="$1" pat="$2" rep="$3" res mrc
  if ! python3 - "$CAT" "$pat" "$rep" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  then
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return
  fi
  res=$("${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$res" || fails=$((fails+1))
  cp "$W/$CAT.orig" "$CAT"
}
mut "C1 header counts len(b)+1" 'fmt\.Fprintf\(conn, "OK %d\\n", len\(b\)\)' 'fmt.Fprintf(conn, "OK %d\n", len(b)+1)'
mut "C2 a newline after the bytes" '(fmt\.Fprintf\(conn, "OK %d\\n", len\(b\)\)\s*)conn\.Write\(b\)' \
  'fmt.Fprintf(conn, "OK %d\n", len(b))
	conn.Write(b)
	fmt.Fprint(conn, "\n")'
mut "C3 ERR-SIG and NONE swapped" 'fmt\.Fprint\(conn, "ERR-SIG\\n"\)(.*?)fmt\.Fprint\(conn, "NONE\\n"\)' \
  'fmt.Fprint(conn, "NONE\n") // present but untrusted
		} else {
			fmt.Fprint(conn, "ERR-SIG\n")'
mut "C4 header counts the baked file" 'fmt\.Fprintf\(conn, "OK %d\\n", len\(b\)\)' \
  'sb, _ := os.ReadFile(catalogSystemPath)
	fmt.Fprintf(conn, "OK %d\n", len(sb))'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
