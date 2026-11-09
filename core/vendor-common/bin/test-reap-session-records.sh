#!/usr/bin/env bash
# test-reap-session-records.sh [<nowhere_roamd.sh>] [--mutate] [--baseline] -- the reap removes the departed
# session's per-uid package records from the state tmpfs (NWP-20261128-36).
#
# WHY THIS IS COMMITTED. grant_perms_for, a11y_apply, autofill_apply and reap_stale_ondemand write records in $STATE
# that name the session's packages, one file per uid: .declined.<uid>, .granted.<uid>, .a11ydone.<uid>,
# .autofilldone.<uid>, .odbatch3.<uid>.<b-part> and od-unparked.<uid> (+ its .tmp). Before this change only the
# next sign-in of the same uid cleared them (the `in` op), and ids are not reused within one system_server
# lifetime, so they stayed until power-off. The reap (the cleanstorage op) is the one point every session end
# converges on; it now removes them after the cutoff record (NWP-20261011-04). The odbatch3 glob keeps its dot, so
# the reap of uid 10 never takes uid 100's list. This suite plants the records of three uids, drives the REAL
# extracted cleanstorage op under every shell found, and asserts what is gone and what survived.
#
#   bash test-reap-session-records.sh                        # the cases
#   bash test-reap-session-records.sh --mutate               # ... plus mutants that must each be CONVICTED
#   bash test-reap-session-records.sh --baseline <old roamd> # R1 must FAIL on the code before this change
#
# Pure logic -- no device. The op and the functions it needs are EXTRACTED from nowhere_roamd.sh by anchor, never
# copied, and re-rooted to a temp tree. Every helper outside this scope is stubbed.
set -uo pipefail

MUTATE=no; BASE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; --baseline) BASE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for everything this suite makes; the EXIT trap is the only one.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=""
for s in bash dash mksh sh; do
  if command -v "$s" >/dev/null 2>&1; then SHELLS="$SHELLS $s"; else echo "skip $s: not found"; fi
done
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }

# --- extraction ---------------------------------------------------------------------------------------------
fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
op_of() { sed -n "/^if \\[ \"\\\$op\" = \"$2\" \\]; then\$/,/^fi\$/p" "$1"; }
reroot() { printf '%s\n' "$1" | sed -E 's#([" ])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

# build_body <roamd.sh> <out>: the re-rooted functions + op as one POSIX file, or exit 2 with EXTRACTION FAILED.
build_body() {
  local f="$1" out="$2" fn t funcs="" op n
  for fn in extra_user_paths userdir_has_record userdir_census userdir_census_fold reap_userdir_settle reap_userdir_take; do
    t=$(fn_of "$f" "$fn")
    [ -n "$t" ] || { echo "EXTRACTION FAILED: function $fn not found in $f" >&2; return 2; }
    funcs="$funcs$t"$'\n'
  done
  op=$(op_of "$f" cleanstorage)
  case "$op" in *'_reapleft'*'reap-ledger'*) ;; *) echo "EXTRACTION FAILED: cleanstorage op in $f" >&2; return 2 ;; esac
  case "$op" in *'rm -f "$STATE/.cutoff.$uid"'*) ;; *) echo "EXTRACTION FAILED: the cutoff line of the cleanstorage op in $f" >&2; return 2 ;; esac
  t=$(reroot "$funcs$op")
  n=$(nleft "$t")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: $n absolute /data path(s) left in live code" >&2; return 2; }
  printf '%s\n' "$t" > "$out"
}

# --- the simulated device -----------------------------------------------------------------------------------
# Stubs, POSIX, sourced by the run script. getprop returns the same start count twice, so the op takes its
# normal path; sleep returns at once.
cat > "$W/stubs.sh" <<'EOF'
userdir_recheck() { :; }; reap_retry_run() { :; }; reap_retry_add() { :; }; userdir_pending_add() { :; }
loc_release() { :; }; md_release() { :; }; dt_release() { :; }; dr_release() { :; }; hs_release() { :; }
ks_reap_clear() { :; }; stop_mediad() { :; }; log_scrub() { :; }; bt_reset() { return 0; }
keystore_push() { KS_VERDICT=sealed; }
sleep() { return 0; }
getprop() { [ "$1" = sys.system_server.start_count ] && echo 5; return 0; }
EOF

# The seven per-uid names, for uid <u>.
names() { printf '%s\n' ".declined.$1" ".granted.$1" ".a11ydone.$1" ".autofilldone.$1" "od-unparked.$1" "od-unparked.$1.tmp" ".odbatch3.$1.b1234abcd"; }

# mkroot: uid 10 removed; user 0's record present; the seven names planted for uid 10, 100 and 11; uid 10's
# cutoff record.
mkroot() {
  local u n
  R=$(mktemp -d -p "$W")
  mkdir -p "$R/state" "$R/data/nowhere" "$R/data/system/users/0" "$R/data/system/users/10"
  : > "$R/data/system/users/0.xml"
  for u in 10 100 11; do
    for n in $(names "$u"); do echo com.example.app > "$R/state/$n"; done
  done
  echo com.example.app > "$R/state/.cutoff.10"
}

# run <root> <shell> <body>: the op, as a script file, under <shell>. Its stderr goes to <root>/stderr.
run() {
  local r="$1" sh="$2" body="$3"
  {
    printf 'ROOT=%s\n' "'$r'"
    printf '%s\n' 'uid=10; op=cleanstorage; name=""; pass=""; LANE=rw'
    printf '%s\n' 'LOG="$ROOT/roam.log"; RES="$ROOT/res"; STATE="$ROOT/state"; KS_DROP="$ROOT/keystore-drop"'
    printf '%s\n' 'KS_CREDS="$STATE/ks-creds"; KS_EXPORT="$ROOT/ks-export"; KS_MAP="$ROOT/ks-map"; KS_KEEP="$ROOT/ks-keep"; KS_CENSUS="$ROOT/ks-census"'
    printf '%s\n' 'DE_PARK_ROOT="$STATE/coldde"'
    printf '. %s\n' "'$W/stubs.sh'"
    printf '. %s\n' "'$body'"
  } > "$r/run.sh"
  "$sh" "$r/run.sh" >/dev/null 2>"$r/stderr"
}

# --- the cases ----------------------------------------------------------------------------------------------
# Each case: case_<id> <shell> <body>; it prints one FAIL line per failed check and sets F=1 on any.
F=0
chk() { if "${@:2}"; then :; else echo "    FAIL $1"; F=1; fi; }
eqv() { [ "$1" = "$2" ]; }
rd() { cat "$1" 2>/dev/null || true; }
# left <root> <uid>: the names of <uid> still in state/; missing <root> <uid>: the names of <uid> gone.
left() { local n o=""; for n in $(names "$2"); do if [ -e "$1/state/$n" ]; then o="$o $n"; fi; done; printf '%s' "$o"; }
missing() { local n o=""; for n in $(names "$2"); do if [ ! -e "$1/state/$n" ]; then o="$o $n"; fi; done; printf '%s' "$o"; }

case_R1() {  # the reap of uid 10 takes all seven of its names
  local l
  mkroot; run "$R" "$1" "$2"
  chk "stderr is empty: $(rd "$R/stderr" | head -3)" eqv "$(rd "$R/stderr")" ""
  chk "RES is OK: $(rd "$R/res")" eqv "$(rd "$R/res")" OK
  l=$(left "$R" 10)
  chk "uid 10's records gone; left:$l" eqv "$l" ""
}
case_R2() {  # the records of uid 100 and uid 11 survive (the dot-anchored glob)
  local u m
  mkroot; run "$R" "$1" "$2"
  for u in 100 11; do
    m=$(missing "$R" "$u")
    chk "uid $u's records kept; missing:$m" eqv "$m" ""
  done
}
case_R3() {  # the cutoff record of uid 10 still goes (the existing line)
  mkroot; run "$R" "$1" "$2"
  chk "uid 10's cutoff record gone" eqv "$([ -e "$R/state/.cutoff.10" ] && echo present)" ""
}
CASES="R1 R2 R3"

# run_cases <body> <cases> <quiet>: every case under every shell. RUN_FAILED lists `<case>[<shell>]` per failure.
run_cases() {
  local body="$1" cases="$2" quiet="${3:-}" c sh out failed=""
  for sh in $SHELLS; do
    for c in $cases; do
      F=0; "case_$c" "$sh" "$body" > "$W/case.out"; out=$(cat "$W/case.out")
      if [ "$F" = 0 ]; then [ -n "$quiet" ] || echo "  ok    $c [$sh]"
      else failed="$failed $c[$sh]"; [ -n "$quiet" ] || { echo "  FAIL  $c [$sh]"; printf '%s\n' "$out"; }
      fi
    done
  done
  RUN_FAILED="$failed"
}
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# --- main ---------------------------------------------------------------------------------------------------
BODY="$W/body.sh"
build_body "$SUT" "$BODY" || exit 2

if [ "$BASE" = yes ]; then
  echo "== baseline: $SUT (R1 must FAIL here) =="
  run_cases "$BODY" R1
  if [ -n "$RUN_FAILED" ]; then echo "baseline: R1 FAILS on the old code, as required"; exit 0; fi
  echo "baseline: R1 HOLDS on the old code -- it proves nothing"; exit 1
fi

echo "== cases: $SUT =="
rc=0
run_cases "$BODY" "$CASES"
[ -z "$RUN_FAILED" ] || rc=1

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ]; then
  echo "== mutants (each must be CONVICTED under every shell) =="
  # subst <in> <out> <from> <to>: on the lines tagged NWP-20261128-36 only, replace a fixed string; <to> "" with
  # <from> "#line" deletes the line.
  subst() {
    awk -v a="$3" -v b="$4" '
      index($0, "# NWP-20261128-36") && index($0, "rm -f") {
        if (a == "#line") next
        i = index($0, a); if (i) $0 = substr($0, 1, i - 1) b substr($0, i + length(a))
      }
      { print }' "$1" > "$2"
  }
  # mutant <id> <convicting case> <from> <to>
  mutant() {
    local id="$1" by="$2" m mb sh_ convicted=1
    m=$(mktemp -p "$W"); mb=$(mktemp -p "$W")
    subst "$SUT" "$m" "$3" "$4"
    if cmp -s "$SUT" "$m"; then echo "  FAIL  $id: the mutant did not apply"; rc=1; return; fi
    if ! build_body "$m" "$mb" 2>/dev/null; then echo "  FAIL  $id: the mutant could not be extracted"; rc=1; return; fi
    run_cases "$mb" "$by" quiet
    for sh_ in $SHELLS; do
      if has "$RUN_FAILED" "$by[$sh_]"; then echo "  CONVICTED $id by $by [$sh_]"
      else echo "  SURVIVED  $id ($by passes under $sh_)"; convicted=0; fi
    done
    [ "$convicted" = 1 ] || rc=1
  }
  mutant M1-line-removed R1 '#line' ''
  mutant M2-odbatch3-glob-widened R2 '"$STATE/.odbatch3.$uid".*' '"$STATE/.odbatch3.$uid"*'
  mutant M3-declined-dropped R1 ' "$STATE/.declined.$uid"' ''
  mutant M4-od-unparked-dropped R1 ' "$STATE/od-unparked.$uid" ' ' '
fi

if [ "$rc" = 0 ]; then echo "PASS: test-reap-session-records.sh"; else echo "FAILED: test-reap-session-records.sh"; fi
exit $rc
