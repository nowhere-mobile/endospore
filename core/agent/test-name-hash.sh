#!/usr/bin/env bash
# test-name-hash.sh [--mutate] -- runs the '#'-in-a-name cases (name_hash_test.go; NWP-20261117-11, #54): CREATE,
# CREATE-CODE, PROMOTE and PROMOTE2 answer ERR-NAME for a name holding '#' (the agent's scope separator) before the
# store, the gateway, the enrollment bucket or the re-key worker is touched; sign-in is unchanged.
# --mutate re-runs them against main.go with one check broken in turn, restoring the file on exit. Each mutant names
# the ONE test that must convict it and counts only a `--- FAIL: <that test>` line; a mutant that fails to apply or
# to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
F=main.go
trap 'if [ -f "$W/$F.orig" ]; then cp -f "$W/$F.orig" "$F"; fi; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestNameHash|TestCreateLive' -v .)
MRUN=(go test -count=1 -run 'TestNameHash' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$W/$F.orig"
fails=0
mut() { # mut <id> <label> <want: the test that must fail>; the mutation itself is <id> in the python below
  local id=$1 label=$2 want=$3 res
  python3 - "$F" "$id" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$F.orig" "$F"; return; }
import sys
p, mid = sys.argv[1:3]
s = open(p).read()
# Each check is told apart by its own comment; a mutant applies only when its anchors occur exactly once.
tail = ('\t\tfmt.Fprint(os.Stderr, "[logind] create refused: the name holds \'#\' (ERR-NAME)\\n")\n'
        '\t\tfmt.Fprint(conn, "ERR-NAME\\n")\n')
head = "\tif strings.IndexByte(name, '#') >= 0 { // NWP-20261117-11 (#54): "
b1 = head + "'#' is the scope separator; the typed name alone decides\n" + tail + "\t\treturn false\n\t}\n"
b2 = head + "before the floor, the gateway, the code and the drain\n" + tail + "\t\treturn\n\t}\n"
b3 = (head + "a throwaway's name is fixed, so a retry cannot help\n"
      '\t\tfmt.Fprint(os.Stderr, "[logind] promote refused: the name holds \'#\' (ERR-NAME)\\n")\n'
      '\t\tfmt.Fprint(conn, "ERR-NAME\\n")\n\t\treturn "", "", "", false\n\t}\n')
end = "\t\treturn false\n\t}\n\treturn true\n}\n\n// headExistsStrict "
def once(*a): return all(s.count(x) == 1 for x in a)
n = None
if mid == "N1" and once(b1): n = s.replace(b1, "", 1)
if mid == "N2" and once(b2): n = s.replace(b2, "", 1)
if mid == "N3" and once(b3): n = s.replace(b3, "", 1)
if mid == "N4" and once(b1, end):
    n = s.replace(b1, "", 1).replace(end, "\t\treturn false\n\t}\n" + b1 + "\treturn true\n}\n\n// headExistsStrict ", 1)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$("${MRUN[@]}" 2>&1)
  if [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  elif [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
  else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
  cp -f "$W/$F.orig" "$F"
}
mut N1 "N1 the createPrecheck check removed" TestNameHash_CreateRefusesBeforeTheStore
mut N2 "N2 the handleCreateCode check removed" TestNameHash_CreateCodeRefusesBeforeTheDrain
mut N3 "N3 the promoteGuards check removed" TestNameHash_PromoteRefusesBeforeTheStoreAndTheRekey
mut N4 "N4 the create check moved after the existence probe" TestNameHash_CreateRefusesBeforeTheStore
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
