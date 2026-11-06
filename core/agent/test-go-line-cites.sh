#!/usr/bin/env bash
# test-go-line-cites.sh [--mutate] [--root DIR] -- NWP-20261124-26: no comment in core/agent cites a file of this repo
# by line number. main.go grows by hundreds of lines a week, so a line number in a comment is right the day it is
# written and names unrelated code soon after: headKey was cited as a salt computation, and gateLogAppendLocked's
# truncate-not-rename reason as a keystore path. Cite the function, constant or quoted log text instead.
# docs/check_line_cites.py holds the same rule for backlog.md and worklog.md.
#
# Reads Go files as data and runs no Go. It scans the comment text (the first `//` to the end of the line) of every
# core/agent/*.go and core/agent/blindrsa/*.go under the root, tests included, and FAILS on:
#   (a) <name>.<ext>:<digits>, where <name>.<ext> is the basename of a file `git ls-files` lists in the repo this
#       script lives in (an AOSP file such as ConnectivityService.java passes);
#   (b) `line <3+ digits>` / `lines <3+ digits>` not followed by `-<digit>` (a date passes; so does a range written
#       `lines <n>-<m>`, the same shape as a date -- rule (a) still catches `<file>:<n>-<m>`);
#   (c) a bare `:<3+ digits>` after the comment start, a space, `(` or `~` (a two-digit port passes).
# A string literal with no `//` before it is not scanned.
#
# EXCEPTIONS is a fixed list of (file, cited token). Each names why it stays. An exception that no longer matches its
# file is ALSO a failure ("stale exception: remove it"), so the list only shrinks.
#
# --root DIR scans DIR instead of this repo (DIR need not be a git checkout). --mutate copies core/agent's Go files
# into a temp tree, plants each case there and scans the copy: M1-M6 must fail, C1-C4 must pass, and a case that
# cannot be planted is a failure. Every planted citation is assembled at run time from fragments, so this file
# holds none literally.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd) || exit 2
REPO=$(git -C "$HERE" rev-parse --show-toplevel) || exit 2
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

ROOT="$REPO" MUTATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mutate) MUTATE=1 ;;
    --root) [ $# -ge 2 ] || { echo "usage: $0 [--mutate] [--root DIR]" >&2; exit 2; }; ROOT="$2"; shift ;;
    *) echo "usage: $0 [--mutate] [--root DIR]" >&2; exit 2 ;;
  esac
  shift
done
ROOT=${ROOT%/}

# file|token|why. The nine core/agent entries sit inside functions other tasks were editing when this suite landed;
# each comes out when its task merges and the citation is re-pointed.
EXCEPTIONS=(
  'core/agent/main.go|billing.go:1371-1373|capFlush, in flight in NOWHERE-1439/1441'
  'core/agent/main.go|billing.go:696-698|capFlush, in flight in NOWHERE-1439/1441'
  'core/agent/incremental_seal.go|line 762|walkChunks, in flight in NOWHERE-1440/1442/1443'
  'core/agent/incremental_seal.go|line 233|walkChunks, in flight in NOWHERE-1440/1442/1443'
  'core/agent/main.go|report_issue.go:210|handleLogin, in flight in another task'
  'core/agent/main.go|main.go:6309|handleLogin, in flight in another task'
  'core/agent/main.go|mediafs.go:678|kickMediad, in flight in NOWHERE-1459'
  'core/agent/main.go|nowhere_roamd.sh:566|kickMediad, in flight in NOWHERE-1459'
  'core/agent/main.go|nowhere_mediad.sh:130|kickMediad, in flight in NOWHERE-1459'
  'core/agent/resolver.go|:965-972|upstream AOSP LinkProperties.java line range, not a file of this repo'
)

NAMES="$W/basenames"
git -C "$REPO" ls-files | sed 's#.*/##' | sort -u >"$NAMES" || exit 2
[ -s "$NAMES" ] || { echo "--- FAIL: git ls-files listed nothing in $REPO"; exit 1; }

# findings <root>: one "relpath<TAB>line<TAB>token" per citation in the comment text of the scanned Go files.
findings() {
  local root="$1" f
  local files=()
  for f in "$root"/core/agent/*.go "$root"/core/agent/blindrsa/*.go; do
    [ -f "$f" ] && files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || { echo "no Go files under $root/core/agent" >&2; return 2; }
  awk -v plen="$((${#root} + 1))" '
    NR == FNR { names[$0] = 1; next }
    {
      i = index($0, "//"); if (i == 0) next
      rel = substr(FILENAME, plen + 1)
      c = " " substr($0, i + 2)
      s = c
      while (match(s, /[A-Za-z0-9_][A-Za-z0-9_.-]*\.[A-Za-z0-9]+:[0-9]+(-[0-9]+)?/)) {
        t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        n = t; sub(/:.*/, "", n)
        if (n in names) print rel "\t" FNR "\t" t
      }
      s = c
      while (match(s, /[^A-Za-z0-9_]lines? [0-9][0-9][0-9]+/)) {
        t = substr(s, RSTART + 1, RLENGTH - 1); s = substr(s, RSTART + RLENGTH)
        if (substr(s, 1, 2) !~ /^-[0-9]/) print rel "\t" FNR "\t" t
      }
      s = c
      while (match(s, /[ (~]:[0-9][0-9][0-9]+(-[0-9]+)?/)) {
        t = substr(s, RSTART + 1, RLENGTH - 1); s = substr(s, RSTART + RLENGTH)
        print rel "\t" FNR "\t" t
      }
    }' "$NAMES" "${files[@]}"
}

# scan <root>: prints a --- FAIL line per citation and per stale exception; non-zero when there is any.
scan() {
  local root="$1" found rel ln tok e erel etok ewhy bad=0 i
  local used=()
  found=$(findings "$root") || { echo "--- FAIL: could not scan $root"; return 1; }
  for i in "${!EXCEPTIONS[@]}"; do used[i]=0; done
  while IFS=$'\t' read -r rel ln tok; do
    [ -n "$rel" ] || continue
    local allowed=0
    for i in "${!EXCEPTIONS[@]}"; do
      e="${EXCEPTIONS[i]}"; erel="${e%%|*}"; e="${e#*|}"; etok="${e%%|*}"
      if [ "$rel" = "$erel" ] && [ "$tok" = "$etok" ]; then allowed=1; used[i]=1; fi
    done
    [ "$allowed" -eq 1 ] && continue
    echo "--- FAIL: $rel:$ln: $tok -- cite the function, constant or log text, never a line number"
    bad=1
  done <<<"$found"
  for i in "${!EXCEPTIONS[@]}"; do
    [ "${used[i]}" -eq 1 ] && continue
    e="${EXCEPTIONS[i]}"; erel="${e%%|*}"; e="${e#*|}"; etok="${e%%|*}"; ewhy="${e#*|}"
    echo "--- FAIL: stale exception: $erel $etok ($ewhy) no longer matches -- remove it"
    bad=1
  done
  return "$bad"
}

out=$(scan "$ROOT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && out="${out:+$out$'\n'}ok   test-go-line-cites: no line-number citation in the comments of $ROOT/core/agent"
. "$HERE/suite-report.sh"
report_plain_run "$rc" "$out" || exit 1
[ "$MUTATE" -eq 1 ] || exit 0

# mkcopy: a fresh copy of this repo's core/agent Go files; prints its root.
mkcopy() {
  local d
  d=$(mktemp -d -p "$W") || return 1
  mkdir -p "$d/core/agent/blindrsa" || return 1
  cp "$REPO"/core/agent/*.go "$d/core/agent/" || return 1
  cp "$REPO"/core/agent/blindrsa/*.go "$d/core/agent/blindrsa/" || return 1
  printf '%s\n' "$d"
}

# plant_line <copy> <file> <text>: append a line; fails when it is not there afterwards.
plant_line() {
  local f="$1/$2" text="$3" got
  [ -f "$f" ] || return 1
  printf '%s\n' "$text" >>"$f" || return 1
  got=$(grep -cF -- "$text" "$f")
  [ "${got:-0}" -ge 1 ]
}

# strip_token <copy> <file> <token>: remove every copy of the token; fails when it was absent or is still there.
strip_token() {
  local f="$1/$2" tok="$3" got tmp
  [ -f "$f" ] || return 1
  got=$(grep -cF -- "$tok" "$f"); [ "${got:-0}" -ge 1 ] || return 1
  tmp=$(mktemp -p "$W") || return 1
  awk -v t="$tok" '{ o = ""; while ((i = index($0, t)) > 0) { o = o substr($0, 1, i - 1); $0 = substr($0, i + length(t)) } print o $0 }' \
    "$f" >"$tmp" || return 1
  mv -f "$tmp" "$f" || return 1
  got=$(grep -cF -- "$tok" "$f")
  [ "${got:-0}" -eq 0 ]
}

FAILS=0
# case_run <id> <expect FAIL|PASS> <must-show> <plant-op> <file> <text>: plant into a fresh copy and scan it. A FAIL
# case convicts only when the output matches <must-show>, a glob naming its own file and planted token (or "stale
# exception" for a strip).
case_run() {
  local id="$1" want="$2" show="$3" op="$4" file="$5" text="$6" d o r
  d=$(mkcopy) || { echo "  BROKEN    $id -- could not copy core/agent"; FAILS=$((FAILS + 1)); return; }
  if ! "$op" "$d" "$file" "$text"; then
    echo "  BROKEN    $id -- could not plant into $file"; FAILS=$((FAILS + 1)); rm -rf "$d"; return
  fi
  o=$(scan "$d" 2>&1); r=$?
  rm -rf "$d"
  if [ "$want" = FAIL ]; then
    if [ "$r" -ne 0 ] && [[ "$o" == *$show* ]]; then echo "  convicted $id"; return; fi
    echo "  SURVIVED  $id -- rc=$r, expected a failure naming: $show"
  else
    if [ "$r" -eq 0 ]; then echo "  passed    $id (control)"; return; fi
    echo "  WRONG     $id -- a control failed:"
  fi
  printf '%s\n' "$o" | tail -n 15
  FAILS=$((FAILS + 1))
}

echo "== mutations =="
base=$(mkcopy) || { echo "--- FAIL: could not copy core/agent"; exit 1; }
bo=$(scan "$base" 2>&1); br=$?
rm -rf "$base"
if [ "$br" -ne 0 ]; then
  printf '%s\n' "$bo"
  echo "--- FAIL: the unplanted copy does not scan clean, so no case can be judged"
  echo FAILED
  exit 1
fi
echo "  baseline  the unplanted copy scans clean"

GO=go MG=main RM=README SEE='// see '
c_main="$MG.$GO"':4242'
case_run M1 FAIL "core/agent/add_device.go:*: $c_main --" plant_line core/agent/add_device.go "$SEE$c_main"
case_run M2 FAIL "core/agent/cap_recover_test.go:*: $c_main --" plant_line core/agent/cap_recover_test.go "$SEE$c_main"
case_run M3 FAIL "core/agent/gate_log.go:*: line 742 --" plant_line core/agent/gate_log.go '// (line '"742)"
case_run M4 FAIL "stale exception: core/agent/main.go billing.$GO:696-698" strip_token core/agent/main.go "billing.$GO"':696-698'
case_run M5 FAIL "core/agent/add_device.go:*: $RM.md:12 --" plant_line core/agent/add_device.go "// $RM.md"':12'
case_run M6 FAIL "core/agent/main.go:*: :2796 --" plant_line core/agent/main.go '// pushProfile ~'":2796"
case_run C1 PASS "" plant_line core/agent/resolver.go '// ConnectivityService.java'":4840"
case_run C2 PASS "" plant_line core/agent/add_device.go '// the wait line '"2026-10-21"
case_run C3 PASS "" plant_line core/agent/add_device.go 'var _ = "see '"$c_main"'"'
case_run C4 PASS "" plant_line core/agent/add_device.go '// plain '":53"

if [ "$FAILS" -ne 0 ]; then echo "--- FAIL: $FAILS case(s) did not give their verdict"; echo FAILED; exit 1; fi
echo "ok   test-go-line-cites --mutate: M1-M6 convicted, C1-C4 passed"
