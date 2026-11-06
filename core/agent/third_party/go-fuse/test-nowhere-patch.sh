#!/usr/bin/env bash
# test-nowhere-patch.sh [--mutate] -- the vendored go-fuse still answers an unparseable request (NWP-20261016-31).
#
# Runs fuse/nowhere_patch_test.go, which pins the NOWHERE PATCH in Server.handleRequest: the Android kernel's
# FUSE_CANONICAL_PATH (opcode 2016) must get a -ENOSYS reply, not silence, or the app's read wedges forever
# (docs/on-demand-media.md). It also pins the log side (NWP-20261127-11): opcode 2016 logs ONE line per process
# (mediad runs one Server per media mount), and every other unknown opcode still logs. All five TestNowhere cases
# must report PASS.
#
# --mutate: six broken copies of fuse/server.go or fuse/request.go must each make a NAMED case FAIL --
#   drop-reply    the whole patch `if` block deleted (nothing written, the bounded read times out)
#   status-ok     `req.status = code` replaced by `req.status = OK` (a reply carrying Error 0)
#   guard-invert  the InHeader length guard inverted to `<` (a short request is answered, a good one is not)
#   quiet-all     request.go: parseRequest silent for every unknown opcode, not only 2016
#   once-removed  the 2016 line logged for every request, not only the first
#   per-server    the once-guard moved to a Server field (one line per mount, not per process)
# A mutant that does not change the file, or that does not compile, is an error, never a pass.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/bin:/usr/local/go/bin:$PATH"
# Every temp of the run is made inside work; TMPDIR puts go's there too.
work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
export TMPDIR="$work"

run_suite() { # <module dir> -> prints the verbose log, returns go test's status
  # -trimpath: --mutate tests copies at a new path on every run, and without it that path is in every compile's
  # cache key, so each run would add a full set of GOCACHE entries that are never hit again.
  (cd "$1" && go test -trimpath -count=1 -run 'TestNowhere' -v ./fuse/ 2>&1)
}

if [ "${1:-}" != "--mutate" ]; then
  rc=0
  log="$(run_suite "$HERE")" || rc=$?
  printf '%s\n' "$log"
  [ "$rc" -eq 0 ] || { echo "FAIL: pristine vendored go-fuse does not pass" >&2; exit 1; }
  for c in TestNowhereCanonicalPathGetsENOSYS TestNowhereShortRequestGetsNoReply \
    TestNowhereCanonicalPathLogsOnce TestNowhereOtherUnknownOpcodeStillLogs TestNowhereCanonicalPathOncePerProcess; do
    case "$log" in
      *"--- PASS: $c"*) ;;
      *) echo "FAIL: no '--- PASS: $c' line" >&2; exit 1 ;;
    esac
  done
  echo "PASS: vendored go-fuse replies -ENOSYS to FUSE_CANONICAL_PATH and logs it once per process"
  exit 0
fi

fail=0

mutate() { # <name> <case that must FAIL> <perl -0pe program> [file, default fuse/server.go]
  local name="$1" want="$2" prog="$3" file="${4:-fuse/server.go}"
  local dir="$work/$1" mlog="$work/$1.log" out
  mkdir -p "$dir"
  cp -R "$HERE/." "$dir/"
  perl -0pi -e "$prog" "$dir/$file"
  if cmp -s "$HERE/$file" "$dir/$file"; then
    echo "FAIL: mutant $name did not apply" >&2; fail=1; return
  fi
  if run_suite "$dir" >"$mlog"; then
    echo "FAIL: mutant $name SURVIVED" >&2; fail=1; return
  fi
  # A compile failure or the wrong case failing is not a conviction: the named case must report FAIL.
  out="$(cat "$mlog")"
  case "$out" in
    *"--- FAIL: $want "*) echo "convicted: $name (by $want)" ;;
    *) echo "FAIL: mutant $name not convicted by $want" >&2; cat "$mlog" >&2; fail=1 ;;
  esac
}

# Control: the pristine copy passes (a suite that fails everywhere convicts every mutant for free).
mkdir -p "$work/control"; cp -R "$HERE/." "$work/control/"
run_suite "$work/control" >"$work/control.log" || { echo "FAIL: control (pristine copy) does not pass" >&2; cat "$work/control.log" >&2; exit 1; }
echo "control passes"

mutate drop-reply TestNowhereCanonicalPathGetsENOSYS 's/\t\tif len\(req\.inputBuf\) >= int\(unsafe\.Sizeof\(InHeader\{\}\)\) \{.*?\n\t\t\}\n//s'
mutate status-ok TestNowhereCanonicalPathGetsENOSYS 's/req\.status = code\n/req.status = OK\n/'
mutate guard-invert TestNowhereCanonicalPathGetsENOSYS 's/(len\(req\.inputBuf\)) >= (int\(unsafe\.Sizeof\(InHeader\{\}\)\))/$1 < $2/'
mutate quiet-all TestNowhereOtherUnknownOpcodeStillLogs \
  's/\t\tif hdr\.Opcode != nowhereOpCanonicalPath \{[^\n]*\n\t\t\tlog\.Printf\("Unknown opcode %d", hdr\.Opcode\)\n\t\t\}\n//' \
  fuse/request.go
mutate once-removed TestNowhereCanonicalPathLogsOnce 's/nowhereCanonicalPathLogged\.CompareAndSwap\(false, true\)/true/'
mutate per-server TestNowhereCanonicalPathOncePerProcess \
  's/(type Server struct \{\n)/$1\tnowhereCanonicalPathLogged atomic.Bool\n/; s/\bnowhereCanonicalPathLogged\.CompareAndSwap/ms.nowhereCanonicalPathLogged.CompareAndSwap/'

[ "$fail" -eq 0 ] || exit 1
echo "all 6 mutants convicted"
