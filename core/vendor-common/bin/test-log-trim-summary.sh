#!/usr/bin/env bash
# test-log-trim-summary.sh [<nowhere_roamd.sh>] [--mutate] -- log_scrub's 1 MiB trim must carry the REAPED session's
# seal summary (`push: profile ... -> N chunks (...)`) across the cut, once, and never an earlier session's
# (NWP-20261017-01, docs/product-decisions.md 2026-10-15).
#
# WHY. The reap's own scrub runs LAST, and on a big profile the sign-out's push line sits in the first part of a
# >1 MiB roam.log, so the tail cut ate the one line that prices the logoff (observed on lynx, 2026-08-29: only
# `reap clean` survived). log_scrub <uid> now writes that session's summary lines (those after the file's last
# `[roamd] IN ... -> user <uid>` line that the cut would drop) behind one marker line, then the tail. The next
# session's IN line sits after them, so the next reap never selects them: nothing accumulates, no state file.
#
#   bash test-log-trim-summary.sh                # the cases, under every shell installed (bash, sh, dash, mksh)
#   bash test-log-trim-summary.sh --mutate       # ... plus mutants that must each CONVICT the suite
#
# log_scrub and the definitions it reads are EXTRACTED from nowhere_roamd.sh by anchor, never copied, and run re-rooted.
# Pure logic: no device, no store.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/nowhere_roamd.sh"; MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT   # every case root and --mutate's ~500 KB mutated copy of roamd

PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
SCRUB_DEFS="NOWHERE_LOGS LOG_KEEP_BYTES LOG_SCRUB_SED LOG_SCRUB_SED_PREV LOG_SCRUB_PROBE LOG_SCRUB_PROBE_OUT"
defs_of() {
  local v out="" n
  for v in $SCRUB_DEFS; do
    n=$(grep -c "^$v=" "$1")
    [ "$n" = 1 ] || { echo "EXTRACTION FAILED: $v= is defined $n times in $1, want 1" >&2; return 1; }
    out="$out$(grep "^$v=" "$1")"$'\n'
  done
  printf '%s' "$out"
}

KEEP=1048576
SEALNAME=zqsealname
IN12='[roamd] IN "'$SEALNAME'" -> user 12 (+de +media) Thu Oct 15 03:04:26 PM EDT 2026'
IN13='[roamd] IN "zqsealother" -> user 13 (+de +media) Thu Oct 15 03:09:26 PM EDT 2026'
# summ <name> <chunks>: the agent's seal summary, scope form (core/agent/main.go)
summ() { printf 'push: profile "%s" #media -> %s chunks (3 net-skipped, 0 crypto-skipped), gen 7\n' "$1" "$2"; }
filler() { yes '[roamd] filler line that is neither an IN line nor a seal summary, padding the log out to size ........' | head -n 12000; }

# run <shell> <root> <defs> <scrubfn> [uid]: the real function, re-rooted, in a fresh <shell>.
run() {
  local sh="$1" root="$2" script
  script="$root/run.sh"
  { printf 'ROOT=%s; STATE=%s/state; LOG=%s/log\n' "$root" "$root" "$root"
    [ "$sh" = mksh ] || printf '%s\n' "$PRINT_SHIM"
    printf '%s\n%s\nlog_scrub %s\n' "$3" "$4" "${5:-}"; } > "$script"
  "$sh" "$script" </dev/null >/dev/null 2>&1
}

# suite <roamd> <shell> [quiet] -> 0 all good, 1 a check failed, 2 the harness could not run.
suite() {
  local f="$1" sh="$2" quiet="${3:-}" p=0 x=0 tmp defs scrubfn n prog R fl
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  chk(){ if "$@"; then ok "$CASE"; else no "$CASE"; fi; }

  defs=$(defs_of "$f") || return 2
  scrubfn=$(fn_of "$f" log_scrub)
  [ -n "$scrubfn" ] || { echo "EXTRACTION FAILED: log_scrub not found" >&2; return 2; }
  n=$(grep -c '/data/nowhere/' <<<"$scrubfn")
  [ "$n" = 1 ] || { echo "EXTRACTION FAILED: log_scrub names /data/nowhere/ $n times, want 1" >&2; return 2; }
  scrubfn=${scrubfn//\/data\/nowhere\//\$ROOT\/data\/nowhere\/}
  prog=$(eval "$defs"; printf '%s' "$LOG_SCRUB_SED")
  [ -n "$prog" ] || { echo "EXTRACTION FAILED: LOG_SCRUB_SED did not evaluate" >&2; return 2; }

  tmp=$(mktemp -d -p "$W")
  # newroot <n>: a fresh root with the data dir and the state dir; echoes it
  newroot() { mkdir -p "$tmp/$1/data/nowhere" "$tmp/$1/state"; printf '%s' "$tmp/$1"; }
  fl() { printf '%s/data/nowhere/roam.log' "$1"; }
  mkl() { head -n 1 "$1" | sed "s/ across the trim .*/ across the trim/"; }
  first() { head -n "$2" "$1" | tail -n 1; }
  cnt() { grep -c -- "$1" "$2"; }
  local mk='[roamd] log_scrub: kept '
  filler > "$tmp/filler"

  # S1: user 12's session, two summaries near its top, then >1 MiB of filler; reap of 12.
  R=$(newroot s1)
  { printf '%s\n' "$IN12"; summ "$SEALNAME" 40; summ "$SEALNAME" 41; cat "$tmp/filler"; } > "$(fl "$R")"
  local before; before=$(wc -c < "$(fl "$R")")
  [ "$before" -gt $((KEEP + 4096)) ] || { echo "EXTRACTION FAILED: S1 fixture is not over the cap" >&2; rm -rf "$tmp"; return 2; }
  run "$sh" "$R" "$defs" "$scrubfn" 12 || true
  local out; out=$(fl "$R")
  CASE="S1 marker first, naming user 12 and 2 lines"; chk test "$(mkl "$out")" = "${mk}2 seal summary line(s) of user 12 across the trim"
  CASE="S1 the marker carries no name"; chk test "$(cnt "$SEALNAME" "$out")" = 0
  CASE="S1 both summaries carried, redacted, behind the marker"; chk test "$(first "$out" 2)|$(first "$out" 3)" = 'push: profile "<name>" #media -> 40 chunks (3 net-skipped, 0 crypto-skipped), gen 7|push: profile "<name>" #media -> 41 chunks (3 net-skipped, 0 crypto-skipped), gen 7'
  local carried; carried=$(head -n 3 "$out" | wc -c)
  CASE="S1 size is the cap plus the carried bytes"; chk test "$(wc -c < "$out")" -le $((KEEP + carried))
  CASE="S1 the tail is the ordinary tail"; chk test "$(tail -n 1 "$out")" = "$(tail -n 1 "$tmp/filler")"
  cp "$out" "$tmp/s1.out"

  # S2: the same file with no uid (the boot path): today's output, byte for byte, no marker.
  R=$(newroot s2)
  { printf '%s\n' "$IN12"; summ "$SEALNAME" 40; summ "$SEALNAME" 41; cat "$tmp/filler"; } > "$(fl "$R")"
  run "$sh" "$R" "$defs" "$scrubfn" || true
  { printf '%s\n' "$IN12"; summ "$SEALNAME" 40; summ "$SEALNAME" 41; cat "$tmp/filler"; } | sed -E "$prog" | tail -c "$KEEP" > "$tmp/s2.want"
  CASE="S2 no uid: no carry, byte for byte today's output"; chk cmp -s "$(fl "$R")" "$tmp/s2.want"

  # S3: S1's output, then user 13's session; reap of 13 carries ONLY 13's summary.
  R=$(newroot s3)
  { cat "$tmp/s1.out"; printf '%s\n' "$IN13"; summ zqsealother 5; cat "$tmp/filler"; } > "$(fl "$R")"
  run "$sh" "$R" "$defs" "$scrubfn" 13 || true
  out=$(fl "$R")
  CASE="S3 marker names user 13 and one line"; chk test "$(mkl "$out")" = "${mk}1 seal summary line(s) of user 13 across the trim"
  CASE="S3 user 13's summary is carried"; chk test "$(first "$out" 2)" = 'push: profile "<name>" #media -> 5 chunks (3 net-skipped, 0 crypto-skipped), gen 7'
  CASE="S3 user 12's lines and marker are gone"; chk test "$(cnt 'user 12 across' "$out")$(cnt ' -> 40 chunks' "$out")$(cnt ' -> 41 chunks' "$out")" = 000

  # S4: an EARLIER session of user 12 is not carried.
  R=$(newroot s4)
  { printf '%s\n' "$IN12"; summ "$SEALNAME" 71; printf '%s\n' "$IN12"; summ "$SEALNAME" 72; cat "$tmp/filler"; } > "$(fl "$R")"
  run "$sh" "$R" "$defs" "$scrubfn" 12 || true
  out=$(fl "$R")
  CASE="S4 only the last session's summary is carried"; chk test "$(mkl "$out")|$(cnt ' -> 72 chunks' "$out")|$(cnt ' -> 71 chunks' "$out")" = "${mk}1 seal summary line(s) of user 12 across the trim|1|0"

  # S5: under the cap: scrub only, no marker.
  R=$(newroot s5)
  { printf '%s\n' "$IN12"; summ "$SEALNAME" 40; echo small; } > "$(fl "$R")"
  run "$sh" "$R" "$defs" "$scrubfn" 12 || true
  out=$(fl "$R")
  CASE="S5 under the cap: no marker, scrub only"; chk test "$(cnt 'log_scrub: kept' "$out")|$(cnt ' -> 40 chunks' "$out")|$(wc -l < "$out")" = "0|1|3"

  # S6: 70 summaries: the newest 64.
  R=$(newroot s6)
  { printf '%s\n' "$IN12"; local i; for i in $(seq 1000 1069); do summ "$SEALNAME" "$i"; done; cat "$tmp/filler"; } > "$(fl "$R")"
  run "$sh" "$R" "$defs" "$scrubfn" 12 || true
  out=$(fl "$R")
  CASE="S6 the newest 64 carried"; chk test "$(mkl "$out")|$(first "$out" 2 | cut -d' ' -f6)|$(first "$out" 65 | cut -d' ' -f6)|$(cnt ' -> 1005 chunks' "$out")" = "${mk}64 seal summary line(s) of user 12 across the trim|1006|1069|0"

  # S7: a planted name inside a summary line is gone by value (S1's output holds no zqsealname; here, in the shape
  # the agent writes for a vault push as well)
  R=$(newroot s7)
  { printf '%s\n' "$IN12"; printf 'push: profile "%s" -> 9 chunks (1 net-skipped, 0 crypto-skipped), gen 2\n' "$SEALNAME"; cat "$tmp/filler"; } > "$(fl "$R")"
  run "$sh" "$R" "$defs" "$scrubfn" 12 || true
  out=$(fl "$R")
  CASE="S7 the planted name is gone, the summary kept"; chk test "$(cnt "$SEALNAME" "$out")|$(cnt ' -> 9 chunks' "$out")" = "0|1"

  # S8: user 12's session ended and user 13's began: the reap of 12 still carries 12's summaries.
  R=$(newroot s8)
  { printf '%s\n' "$IN12"; summ "$SEALNAME" 51; summ "$SEALNAME" 52; printf '%s\n' "$IN13"; cat "$tmp/filler"; } > "$(fl "$R")"
  run "$sh" "$R" "$defs" "$scrubfn" 12 || true
  out=$(fl "$R")
  CASE="S8 reap of 12 carries 12's two lines past 13's IN"; chk test "$(mkl "$out")|$(cnt ' -> 51 chunks' "$out")|$(cnt ' -> 52 chunks' "$out")" = "${mk}2 seal summary line(s) of user 12 across the trim|1|1"

  rm -rf "$tmp"
  [ -n "$quiet" ] || echo "  -- $p ok, $x failed"
  [ "$x" = 0 ]
}

SHELLS=bash
for s in sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
FAILED=0
echo "log trim summary: $SUT"
for s in $SHELLS; do
  echo "[$s]"
  suite "$SUT" "$s"; rc=$?
  [ "$rc" = 0 ] || { [ "$rc" = 2 ] && echo "HARNESS ERROR (rc=2): not a verdict"; FAILED=1; }
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT):"
  mtmp=$(mktemp -d -p "$W"); MN=0; MOK=0
  mutate() {
    local label="$1" needle="$2" repl="$3" src m rc
    MN=$((MN + 1))
    src=$(cat "$SUT")
    m=${src/"$needle"/}
    if [ "$m" = "$src" ]; then printf '  SKIP  %-60s needle not found -- a NO-OP\n' "$label"; return; fi
    if [ "${m/"$needle"/}" != "$m" ]; then printf '  SKIP  %-60s needle occurs more than once\n' "$label"; return; fi
    printf '%s\n' "${src/"$needle"/"$repl"}" > "$mtmp/roamd.sh"
    suite "$mtmp/roamd.sh" bash quiet >/dev/null 2>&1; rc=$?
    case "$rc" in
      1) printf '  ok    %-60s convicted\n' "$label"; MOK=$((MOK + 1)) ;;
      0) printf '  XX    %-60s SURVIVED\n' "$label" ;;
      *) printf '  ERR   %-60s harness error (rc=%s), no verdict\n' "$label" "$rc" ;;
    esac
  }
  mutate 'no boundary: summaries of earlier sessions are carried too' '[ "$_o" -gt "$_in" ] && ' ''
  mutate 'the boundary matches any uid'"'"'s IN line' '-> user $_u( |\$)' '-> user [0-9]+( |\$)'
  mutate 'the boundary is the FIRST IN line, not the last' '2>/dev/null | tail -n 1)' '2>/dev/null | head -n 1)'
  mutate 'the carry is taken from the unscrubbed file' "_c=\$(grep -b -E '^push: profile .* chunks \\(' \"\$STATE/.logscrub\"" "_c=\$(grep -b -E '^push: profile .* chunks \\(' \"\$_f\""
  mutate 'the 64-line cap is removed' 'done | tail -n 64)' 'done)'
  mutate 'the marker line is dropped' '          print -r -- "[roamd] log_scrub: kept $_n seal summary line(s) of user $_u across the trim $(date)"' '          :'
  if [ "$MOK" = "$MN" ]; then echo "ALL $MN MUTATIONS BEHAVED"
  else echo "PROBLEM: a mutation did not behave ($MOK of $MN convicted)"; FAILED=1; fi
fi

exit "$FAILED"
