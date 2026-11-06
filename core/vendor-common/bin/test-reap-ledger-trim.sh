#!/usr/bin/env bash
# test-reap-ledger-trim.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's reap_ledger_trim and its btwipe call (NWP-20261107-10, Q143).
#
# WHY. cleanstorage and bootsweep append a row to the durable /data/nowhere/reap-ledger per reap and nothing removed one,
# so an extraction read an unbounded timeline of every failed session end. Q143 bounds it: btwipe (every boot, and an
# offline sign-in) trims it to the last 20 rows, none 30 days old, and logs counts only.
#
# The helper is EXTRACTED from nowhere_roamd.sh by its `reap_ledger_trim() {` anchor to its closing `}` and the btwipe
# arm by its head line (exit 2 if either is absent), and run under every shell the runner has (bash, sh, dash, mksh;
# REAPTRIM_SHELLS=<paths> restricts the list).
#
#   bash test-reap-ledger-trim.sh               # the checks
#   bash test-reap-ledger-trim.sh --mutate      # ... plus mutants that must each CONVICT the suite under each shell
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
if [ -n "${REAPTRIM_SHELLS:-}" ]; then
  read -r -a SHELLS <<< "$REAPTRIM_SHELLS"
else
  seen=" "
  for s in bash sh dash mksh; do
    p=$(command -v "$s" 2>/dev/null) || continue
    r=$(readlink -f "$p")
    case "$seen" in *" $r "*) continue ;; esac
    seen="$seen$r "; SHELLS+=("$p")
  done
fi

FN=$(awk '
  on && $0 == "}" { print; exit }
  $0 == "reap_ledger_trim() {" { on = 1 }
  on { print }' "$SUT")
case "$FN" in "reap_ledger_trim() {"*) ;; *) echo "EXTRACTION FAILED: reap_ledger_trim is absent from $SUT" >&2; exit 2 ;; esac
ARM_HEAD='if [ "$op" = "btwipe" ]; then'
ARM=$(awk -v h="$ARM_HEAD" '
  on && $0 == "fi" { print; exit }
  $0 == h { on = 1 }
  on { print }' "$SUT")
case "$ARM" in "$ARM_HEAD"*) ;; *) echo "EXTRACTION FAILED: the btwipe arm is absent from $SUT" >&2; exit 2 ;; esac

NOW=2000000000
DAY=86400
PLANT=1999999123

# rows <count> <first-age-seconds> <step-seconds>: ascending time, shaped like the real rows
rows(){ awk -v n="$1" -v a="$2" -v s="$3" -v now="$NOW" 'BEGIN { for (i = 0; i < n; i++) printf "%d uid=%d class=residue left=%d\n", now - a + i * s, 100 + i, i }'; }

# run_case <sh> <dir> <now-arg> [<prelude>]: the helper over $dir/ledger, umask 022, log in $dir/log; <prelude> (an
# awk shim, NWP-20261126-17) goes before the helper
run_case(){ local sh="$1" d="$2" nw="$3" pre="${4:-}"
  { printf 'umask 022; LOG=%s/log\n' "$d"; printf '%s\n' "$pre"; printf '%s\n' "$FN"; printf 'reap_ledger_trim %s/ledger "%s"\n' "$d" "$nw"; } > "$d/run.sh"
  "$sh" "$d/run.sh" >/dev/null 2>&1
}
newcase(){ mktemp -d -p "$W"; }
# shim <dir> <body>: an awk function that runs <body> for the FILTER call only (the one that names `t=<dir>/ledger.tmp`)
# and lets every other call through to the real awk
shim(){ printf 'awk() { case "$*" in *" t=%s/ledger.tmp "*) %s ;; *) command awk "$@" ;; esac; }\n' "$1" "$2"; }
FAILED='[roamd] reap-ledger: trim FAILED -- the ledger is kept unchanged (NWP-20261126-17)'
# kept_unchanged <tag> <label> <dir> <rc>: the ledger is $dir/in byte for byte, one FAILED line, no counts line, no temp
kept_unchanged(){ local tag="$1" lbl="$2" d="$3" rc="$4" nf nk
  nf=$(grep -c -F "$FAILED" "$d/log" 2>/dev/null); nk=$(grep -c -F 'reap-ledger: kept ' "$d/log" 2>/dev/null)
  if [ "$rc" = 0 ] && cmp -s "$d/in" "$d/ledger" && [ "$nf" = 1 ] && [ "$nk" = 0 ] && [ ! -f "$d/ledger.tmp" ]; then
    ok "$tag $lbl"
  else
    no "$tag $lbl -- rc $rc, ledger $({ wc -l < "$d/ledger"; } 2>/dev/null) rows, FAILED x${nf:-?}, kept x${nk:-?}, files: $(ls "$d" | tr '\n' ' ')"
  fi; }

for sh in "${SHELLS[@]}"; do
  tag="[${sh##*/}]"

  C=$(newcase); rows 25 $((25 * 3600)) 3600 > "$C/in"; cp "$C/in" "$C/ledger"; chmod 644 "$C/ledger"
  run_case "$sh" "$C" "$NOW"; rc=$?
  tail -n 20 "$C/in" > "$C/want"
  [ "$rc" = 0 ] && cmp -s "$C/want" "$C/ledger" && ok "$tag T1 25 recent rows -> the last 20, in order" || no "$tag T1 got: $(wc -l < "$C/ledger" 2>/dev/null) rows, rc $rc"
  mode=$(stat -c %a "$C/ledger" 2>/dev/null)
  [ "$mode" = 600 ] && [ ! -e "$C/ledger.tmp" ] && ok "$tag T8 mode 600 and no .tmp left" || no "$tag T8 mode '$mode', tmp: $(ls "$C"/ledger.tmp 2>&1)"
  [ "$(grep -c -F '[roamd] reap-ledger: kept 20 of 25 row(s) (last 20, under 30 days)' "$C/log")" = 1 ] && ok "$tag T9 one counts line" || no "$tag T9 log: $(cat "$C/log" 2>/dev/null)"
  C9=$(newcase); { rows 3 $((3 * 3600)) 3600; printf '%s uid=777 class=residue\n' "$PLANT"; } > "$C9/ledger"
  run_case "$sh" "$C9" "$NOW"
  leak=$(grep -c -E 'uid=|1999999|2000000' "$C9/log" 2>/dev/null)
  [ "$leak" = 0 ] && [ -s "$C9/log" ] && ok "$tag T9 the log holds counts only" || no "$tag T9 log leaks: $(cat "$C9/log" 2>/dev/null)"

  C=$(newcase); { rows 4 $((31 * DAY)) 60 > "$C/old"; rows 6 3600 60 > "$C/new"; paste -d'\n' "$C/old" "$C/new" | grep -v '^$'; } > "$C/ledger"
  run_case "$sh" "$C" "$NOW"
  cmp -s "$C/new" "$C/ledger" && ok "$tag T2 the 4 old rows dropped, the 6 others kept" || no "$tag T2 got: $(cat "$C/ledger" 2>/dev/null)"

  C=$(newcase); printf '%d uid=1 old\n%d uid=2 young\n' $((NOW - 2592000)) $((NOW - 2592000 + 1)) > "$C/ledger"
  run_case "$sh" "$C" "$NOW"
  [ "$(cat "$C/ledger" 2>/dev/null)" = "$((NOW - 2592000 + 1)) uid=2 young" ] && ok "$tag T3 exactly 30 days dropped, one second younger kept" || no "$tag T3 got: $(cat "$C/ledger" 2>/dev/null)"

  C=$(newcase); printf 'abc uid=1\n12a uid=2\n-5 uid=3\nx1 uid=4\n1.5 uid=5\n%d uid=6 good\n' $((NOW - 60)) > "$C/ledger"
  run_case "$sh" "$C" "$NOW"
  [ "$(cat "$C/ledger" 2>/dev/null)" = "$((NOW - 60)) uid=6 good" ] && ok "$tag T4 non-numeric first fields dropped" || no "$tag T4 got: $(cat "$C/ledger" 2>/dev/null)"

  C=$(newcase); rows 5 $((40 * DAY)) 60 > "$C/ledger"
  run_case "$sh" "$C" "$NOW"; rc=$?
  [ "$rc" = 0 ] && [ ! -e "$C/ledger" ] && [ ! -e "$C/ledger.tmp" ] && ok "$tag T5 all old -> the file removed" || no "$tag T5 ledger left: $(ls "$C")"

  C=$(newcase)
  run_case "$sh" "$C" "$NOW"; rc=$?
  [ "$rc" = 0 ] && [ ! -e "$C/ledger" ] && [ ! -e "$C/ledger.tmp" ] && ok "$tag T6 no ledger -> none created, exit 0" || no "$tag T6 rc $rc: $(ls "$C")"

  for bad in soon ""; do
    C=$(newcase); { rows 4 $((40 * DAY)) 60; rows 21 3600 60; } > "$C/in"; cp "$C/in" "$C/ledger"
    run_case "$sh" "$C" "$bad"
    tail -n 20 "$C/in" > "$C/want"
    if cmp -s "$C/want" "$C/ledger" && grep -q 'age cut skipped' "$C/log"; then ok "$tag T7 now='$bad' -> only the 20-row cut, and the log says so"
    else no "$tag T7 now='$bad' got $(wc -l < "$C/ledger" 2>/dev/null) rows; log: $(cat "$C/log" 2>/dev/null)"; fi
  done

  # NWP-20261126-17: a trim that cannot write its temp keeps the ledger. Before, it read the unwritten temp as "no row
  # kept" and deleted the ledger.
  C=$(newcase); rows 25 3600 60 > "$C/in"; cp "$C/in" "$C/ledger"; mkdir "$C/ledger.tmp"
  run_case "$sh" "$C" "$NOW"; rc=$?
  [ -d "$C/ledger.tmp" ] && kept_unchanged "$tag" "T-a the temp path is a directory -> the ledger kept, FAILED logged" "$C" "$rc" || no "$tag T-a the planted directory is gone"
  rmdir "$C/ledger.tmp" 2>/dev/null; [ ! -e "$C/ledger.tmp" ] || no "$tag T-a the planted directory could not be removed"

  C=$(newcase); rows 25 3600 60 > "$C/in"; cp "$C/in" "$C/ledger"
  run_case "$sh" "$C" "$NOW" "$(shim "$C" "printf 'x\\ny\\nz\\n' > $C/ledger.tmp; echo 3; return 2")"; rc=$?
  kept_unchanged "$tag" "T-b the filter awk exits 2 after 3 rows -> the ledger kept, FAILED logged" "$C" "$rc"

  C=$(newcase); rows 25 3600 60 > "$C/in"; cp "$C/in" "$C/ledger"; rows 19 3600 60 > "$C/short"
  run_case "$sh" "$C" "$NOW" "$(shim "$C" "cat $C/short > $C/ledger.tmp; echo 20; return 0")"; rc=$?
  kept_unchanged "$tag" "T-c a short temp (19 rows written, 20 printed) -> the ledger kept, FAILED logged" "$C" "$rc"

  C=$(newcase); rows 5 $((31 * DAY)) 60 > "$C/ledger"
  run_case "$sh" "$C" "$NOW"; rc=$?
  if [ "$rc" = 0 ] && [ ! -e "$C/ledger" ] && [ ! -e "$C/ledger.tmp" ] && [ "$(grep -c -F 'reap-ledger: kept 0 of 5 row(s) (last 20, under 30 days)' "$C/log")" = 1 ] \
     && [ "$(grep -c -F "$FAILED" "$C/log")" = 0 ]; then ok "$tag T-d every row 31+ days old -> the ledger removed, kept 0 of 5"
  else no "$tag T-d rc $rc, files: $(ls "$C" | tr '\n' ' '), log: $(cat "$C/log" 2>/dev/null)"; fi

  C=$(newcase)
  {
    printf 'op=btwipe; LOG=%s/log; RES=%s/res\n' "$C" "$C"
    printf 'bt_reset() { return 0; }\n'
    printf 'log_scrub() { echo "log_scrub:$#" >> %s/calls; }\n' "$C"
    printf 'reap_ledger_trim() { echo "trim:$#:$1:$2" >> %s/calls; }\n' "$C"
    printf '%s\n' "$ARM"
    printf 'echo FELL-THROUGH > %s/res\n' "$C"
  } > "$C/arm.sh"
  "$sh" "$C/arm.sh" >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$(cat "$C/res" 2>/dev/null)" = OK ] && ok "$tag T10 btwipe exits 0 with RES OK" || no "$tag T10 rc $rc, RES '$(cat "$C/res" 2>/dev/null)'"
  [ "$(sed -n 1p "$C/calls" 2>/dev/null)" = "log_scrub:0" ] && [ "$(wc -l < "$C/calls" 2>/dev/null)" = 2 ] && ok "$tag T10 log_scrub first, then exactly one more call" || no "$tag T10 calls: $(cat "$C/calls" 2>/dev/null)"
  line2=$(sed -n 2p "$C/calls" 2>/dev/null); a=${line2#trim:2:/data/nowhere/reap-ledger:}
  case "$line2:$a" in trim:2:/data/nowhere/reap-ledger:*:?*) case "$a" in *[!0-9]*) no "$tag T10 second arg not digits: '$line2'" ;; *) ok "$tag T10 reap_ledger_trim /data/nowhere/reap-ledger <digits>, after log_scrub" ;; esac ;; *) no "$tag T10 call line: '$line2'" ;; esac
done

[ "$(grep -c -F 'reap_ledger_trim /data/nowhere/reap-ledger' "$SUT")" = 1 ] && ok "exactly one call site in roamd" || no "the call site count is not 1"

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite under each shell) =="
  mutate(){ local lbl="$1" m s; shift; m=$(mktemp -d -p "$W")
    if ! "$@" > "$m/m" 2>"$m/err"; then no "MUTATION BROKEN: $lbl: $(cat "$m/err")"; rm -rf "$m"; return; fi
    if cmp -s "$SUT" "$m/m"; then no "MUTATION INERT: $lbl"; rm -rf "$m"; return; fi
    for s in "${SHELLS[@]}"; do
      REAPTRIM_SHELLS="$s" bash "$0" "$m/m" >/dev/null 2>&1
      if [ $? -eq 0 ]; then no "NOT CONVICTED under ${s##*/}: $lbl -- suite passes on broken code"; else ok "convicted under ${s##*/}: $lbl"; fi
    done
    rm -rf "$m"
  }
  H='/^reap_ledger_trim() {$/,/^}$/'
  A='/^if \[ "\$op" = "btwipe" \]; then$/,/^fi$/'
  # m7 <roamd>: the call moved before log_scrub, never deleted. The mutated arm must hold exactly one call line, before
  # its one `  log_scrub`, or m7 refuses (BROKEN): a drifted anchor would make it a second M5, convicted by a count, and
  # T10's order check would never be proven.
  m7(){ awk '
    /^if \[ "\$op" = "btwipe" \]; then$/ { inarm = 1 }
    inarm && /^  reap_ledger_trim \/data\/nowhere\/reap-ledger / { next }
    inarm && /^  log_scrub$/ { print "  reap_ledger_trim /data/nowhere/reap-ledger \"$(date +%s)\"" }
    inarm && /^fi$/ { inarm = 0 }
    { print }' "$1" > "$W/m7" || return 1
    awk -v h="$ARM_HEAD" '
      on && $0 == "fi" { exit }
      $0 == h { on = 1 }
      on && /^  reap_ledger_trim \/data\/nowhere\/reap-ledger / { c++; if (!s) b++ }
      on && $0 == "  log_scrub" { s++ }
      END { exit !(c == 1 && b == 1 && s == 1) }' "$W/m7" || { echo "the arm is not one call line before one log_scrub" >&2; return 1; }
    cat "$W/m7"; }
  sed 's/^  log_scrub$/  log_scrub # drifted/' "$SUT" > "$W/drift"
  if m7 "$W/drift" >/dev/null 2>&1; then no "M7 takes a drifted log_scrub line (it would delete the call, a second M5)"
  else ok "M7 refuses a drifted log_scrub line"; fi
  # m4 <roamd>: the FIRST 20 qualifying rows kept instead of the last. Both edits must land exactly once, or m4 refuses
  # (BROKEN).
  m4(){ awk '
    /^reap_ledger_trim\(\) \{$/ { on = 1 }
    on && sub(/\{ r\[k % keep\] = \$0; k\+\+ \}/, "{ if (k < keep) r[k] = $0; k++ }") { a++ }
    on && sub(/s = k - keep; if \(s < 0\) s = 0/, "s = 0; if (k > keep) k = keep") { b++ }
    on && /^}$/ { on = 0 }
    { print }
    END { exit !(a == 1 && b == 1) }' "$1" > "$W/m4" || { echo "the ring-buffer anchors are not each present once" >&2; return 1; }
    cat "$W/m4"; }
  mutate "M1: the 20 bound -> 200" sed "$H s/-v keep=20 /-v keep=200 /" "$SUT"
  mutate "M2: the age cut removed" sed "$H s/now - \$1 < 2592000/1/" "$SUT"
  mutate "M3: < -> <= at the boundary" sed "$H s/< 2592000/<= 2592000/" "$SUT"
  mutate "M4: head instead of tail" m4 "$SUT"
  mutate "M5: the call removed from btwipe" sed "$A { /^  reap_ledger_trim \/data\/nowhere\/reap-ledger /d; }" "$SUT"
  mutate "M6: the chmod removed" sed "$H s/! chmod 600 \"\$_t\" || //" "$SUT"
  mutate "M7: the call before log_scrub" m7 "$SUT"
  mutate "M8: the awk status ignored" sed "$H { /^  \[ \"\$_rc\" = 0 \] || _bad=status\$/d; }" "$SUT"
  mutate "M9: the count comparison dropped" sed "$H s/ || _bad=short\$//" "$SUT"
  mutate "M10: an empty or 0 count removes the ledger (the old behaviour)" sed "$H s/^  if \[ -z \"\$_bad\" \] \&\& \[ \"\$_w\" = 0 \]; then\$/  if [ \"\${_w:-0}\" = 0 ]; then/" "$SUT"
  mutate "M11: the FAILED arm removes the ledger" sed "$H s/^    rm -f \"\$_t\"\$/    rm -f \"\$_f\" \"\$_t\"/" "$SUT"
fi

echo
echo "shells: ${SHELLS[*]}; $PASS ok, $FAIL failed"
[ "$FAIL" = 0 ]
