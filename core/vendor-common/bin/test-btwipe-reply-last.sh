#!/usr/bin/env bash
# test-btwipe-reply-last.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's btwipe arm answers last (NWP-20261129-20).
#
# WHY. runWorkerHeld returns at the first byte of $RES. The arm wrote $RES and only then ran log_scrub and
# reap_ledger_trim, so the next RW-lane op sent ctl.start to a oneshot that still ran. Init ignores that start, so the
# op waited for the #83 recovery. The next op's roam.log appends also landed inside the scrub's in-place rewrite.
#
# The arm is EXTRACTED from nowhere_roamd.sh by its head line to the first column-0 `fi`, and _ms by its `_ms() {` line
# (exit 2 on a miss). Stubs stand in for bt_reset, log_scrub and reap_ledger_trim. Each case runs under every shell the
# runner has (bash, sh, dash, mksh; BTWIPE_SHELLS=<paths> restricts the list).
#
#   bash test-btwipe-reply-last.sh               # the checks
#   bash test-btwipe-reply-last.sh --mutate      # ... plus mutants that must each CONVICT the suite under each shell
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

SHELLS=()
if [ -n "${BTWIPE_SHELLS:-}" ]; then
  read -r -a SHELLS <<< "$BTWIPE_SHELLS"
else
  seen=" "
  for s in bash sh dash mksh; do
    p=$(command -v "$s" 2>/dev/null) || continue
    r=$(readlink -f "$p")
    case "$seen" in *" $r "*) continue ;; esac
    seen="$seen$r "; SHELLS+=("$p")
  done
fi

ARM_HEAD='if [ "$op" = "btwipe" ]; then'
SCRUB_LINE='  log_scrub'
TRIM_LINE='  reap_ledger_trim /data/nowhere/reap-ledger "$(date +%s)"'
[ "$(grep -c -F -x "$ARM_HEAD" "$SUT")" = 1 ] || { echo "EXTRACTION FAILED: the btwipe head is not in $SUT exactly once" >&2; exit 2; }
awk -v h="$ARM_HEAD" '
  on && $0 == "fi" { print; exit }
  $0 == h { on = 1 }
  on { print }' "$SUT" > "$W/arm"
[ "$(tail -n 1 "$W/arm")" = fi ] || { echo "EXTRACTION FAILED: the btwipe arm has no column-0 fi in $SUT" >&2; exit 2; }
[ "$(grep -c -F -x "$SCRUB_LINE" "$W/arm")" = 1 ] || { echo "EXTRACTION FAILED: the btwipe arm has no single log_scrub line" >&2; exit 2; }
[ "$(grep -c -F -x "$TRIM_LINE" "$W/arm")" = 1 ] || { echo "EXTRACTION FAILED: the btwipe arm has no single reap_ledger_trim line" >&2; exit 2; }
[ "$(grep -c '^_ms() {' "$SUT")" = 1 ] || { echo "EXTRACTION FAILED: _ms is not in $SUT exactly once" >&2; exit 2; }
grep '^_ms() {' "$SUT" > "$W/ms"

# run_case <sh> <dir> <bt-rc>: the arm in its own runner, with stubs that record whether $RES exists at each call
run_case(){ local sh="$1" d="$2" rc="$3"
  {
    printf 'umask 022\n'
    printf 'op=btwipe; LOG=%s/log; RES=%s/res\n' "$d" "$d"
    printf 'BT_RC=%s\n' "$rc"
    printf 'bt_reset() { return $BT_RC; }\n'
    printf 'log_scrub() { if [ -e "$RES" ]; then s=PRESENT; else s=ABSENT; fi; echo "log_scrub RES=$s" >> %s/calls; }\n' "$d"
    printf 'reap_ledger_trim() { if [ -e "$RES" ]; then s=PRESENT; else s=ABSENT; fi; echo "reap_ledger_trim RES=$s" >> %s/calls; }\n' "$d"
    cat "$W/ms" "$W/arm"
    printf 'echo FELL-THROUGH > "$RES"\n'
  } > "$d/run.sh"
  "$sh" "$d/run.sh" >/dev/null 2>"$d/err"
}

printf 'log_scrub RES=ABSENT\nreap_ledger_trim RES=ABSENT\n' > "$W/want-calls"
printf 'OK\n' > "$W/want-OK"
printf 'ERR-BT\n' > "$W/want-ERR-BT"
TIMING='^\[roamd\] btwipe: log scrub and ledger trim took [0-9]+ms \(NWP-20261129-20\) '

# check_reply <tag> <dir> <rc> <reply>: the assertions B1 and B2 share
check_reply(){ local tag="$1" d="$2" rc="$3" want="$4"
  [ "$rc" = 0 ] && ok "$tag exit" || no "$tag exit: rc $rc, stderr: $(cat "$d/err")"
  cmp -s "$d/res" "$W/want-$want" && ok "$tag res is exactly $want" || no "$tag res: '$(cat "$d/res" 2>/dev/null)', want $want"
  [ "$(stat -c %a "$d/res" 2>/dev/null)" = 600 ] && ok "$tag res mode 600" || no "$tag res mode: $(stat -c %a "$d/res" 2>/dev/null)"
  cmp -s "$d/calls" "$W/want-calls" && ok "$tag calls: log_scrub then reap_ledger_trim, RES absent at both" || no "$tag calls: $(tr '\n' ';' 2>/dev/null < "$d/calls")"
}

for sh in "${SHELLS[@]}"; do
  tag="[${sh##*/}]"

  C=$(mktemp -d -p "$W"); run_case "$sh" "$C" 0; rc=$?
  check_reply "$tag B1" "$C" "$rc" OK
  [ "$(grep -c -F 'device cleared (btwipe)' "$C/log")" = 1 ] && ok "$tag B1 cleared line once" || no "$tag B1 cleared line count: $(cat "$C/log" 2>/dev/null)"
  [ "$(grep -c -E "$TIMING" "$C/log")" = 1 ] && ok "$tag B1 timing once, ms all digits" || no "$tag B1 timing: $(cat "$C/log" 2>/dev/null)"
  grep -q -s FELL-THROUGH "$C/res" && no "$tag B3 FELL-THROUGH after B1" || ok "$tag B3 no fall-through after B1"

  C=$(mktemp -d -p "$W"); run_case "$sh" "$C" 1; rc=$?
  check_reply "$tag B2" "$C" "$rc" ERR-BT
  [ "$(grep -c -F 'device NOT cleared (btwipe)' "$C/log")" = 1 ] && ok "$tag B2 not-cleared line once" || no "$tag B2 not-cleared line count: $(cat "$C/log" 2>/dev/null)"
  grep -q -s FELL-THROUGH "$C/res" && no "$tag B3 FELL-THROUGH after B2" || ok "$tag B3 no fall-through after B2"
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite under each shell) =="
  # edit <mutant>: the mutant of $SUT, scoped to the arm. The number of edits must be exact, or the mutant is BROKEN.
  edit(){ awk -v k="$1" -v h="$ARM_HEAD" '
    $0 == h { on = 1 }
    on && k == "N1" && sub(/; _btw=OK$/, "; _btw=OK; echo \"OK\" > \"$RES\"") { n++ }
    on && k == "N2" && sub(/; _btw=ERR-BT; fi$/, "; _btw=ERR-BT; echo \"ERR-BT\" > \"$RES\"; fi") { n++ }
    on && k == "N3" && /^  reap_ledger_trim / { print "  echo \"$_btw\" > \"$RES\""; n++ }
    on && (k == "N3" || k == "N4") && $0 == "  echo \"$_btw\" > \"$RES\"" { n++; next }
    on && k == "N5" && $0 == "  echo \"$_btw\" > \"$RES\"" { $0 = "  echo OK > \"$RES\""; n++ }
    on && k == "N6" && index($0, "  echo \"[roamd] btwipe: log scrub and ledger trim took ") == 1 { n++; next }
    on && $0 == "fi" { on = 0 }
    { print }
    END { exit !(n == (k == "N3" ? 2 : 1)) }' "$SUT"; }
  # mutate <mutant> <label> <assertion>...: CONVICTED means exit 1 and a FAIL line for each named assertion, per shell
  mutate(){ local k="$1" lbl="$2" m s t a out rc miss; shift 2; m=$(mktemp -d -p "$W")
    if ! edit "$k" > "$m/m"; then no "MUTATION BROKEN: $k: $lbl"; return; fi
    if cmp -s "$SUT" "$m/m"; then no "MUTATION INERT: $k: $lbl"; return; fi
    for s in "${SHELLS[@]}"; do
      t="${s##*/}"; out=$(BTWIPE_SHELLS="$s" bash "$0" "$m/m" 2>&1); rc=$?; miss=""
      for a in "$@"; do case "$out" in *"FAIL  [$t] $a"*) ;; *) miss="$miss '$a'" ;; esac; done
      if [ "$rc" = 1 ] && [ -z "$miss" ]; then ok "CONVICTED under $t: $k: $lbl"
      else no "NOT CONVICTED under $t: $k: $lbl (rc $rc, no FAIL for:$miss)"; fi
    done
  }
  mutate N1 "the OK reply written before log_scrub, as on main" "B1 calls"
  mutate N2 "the ERR-BT reply written before log_scrub" "B2 calls"
  mutate N3 "the reply written between log_scrub and the trim" "B1 calls"
  mutate N4 "the reply dropped" "B1 res" "B2 res"
  mutate N5 "the reply fixed to OK" "B2 res"
  mutate N6 "the timing line dropped" "B1 timing"
fi

echo
echo "shells: ${SHELLS[*]}; $PASS ok, $FAIL failed"
[ "$FAIL" = 0 ]
