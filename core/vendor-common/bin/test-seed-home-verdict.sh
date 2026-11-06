#!/usr/bin/env bash
# test-seed-home-verdict.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's `seed-home` op reply (NWP-20261015-39, #122).
#
# WHY THIS IS COMMITTED. The seed-home op ran seed_home and then wrote a bare OK to $RES whatever happened -- no
# default-home, the tool missing, no launcher.db after the 25 s poll, rc 5 (dock not imported), a failed insert --
# so "page 2 seeded" and "page 2 never seeded" read the same (the user-build failure of DIA-20260810-01). seed_home
# now sets SEED_VERDICT on every branch and the op writes it to $RES in one redirect, `ERR-SEED noverdict` if a
# branch left it empty (an empty $RES never trips the worker poller's first-byte return).
#
# seed_home and the op arm are extracted from nowhere_roamd.sh BY ANCHOR, never copied. The tool, am, sleep,
# seed_aurora_installer and the descriptor are stubs under a temp root; the 25 s poll is not slept.
#
# Each case writes the two blocks, its variables and the stubs into a run file and executes that file in a CHILD of each
# shell found among bash, sh, dash and mksh (the device's /system/bin/sh), never by `eval` in this bash (NWP-20261113-41).
# mksh reads the poll's `[ "$i" -lt 25 ]` and `case "$rc"` on its own terms: a non-number in `[ x -lt 25 ]` is 0 there,
# so a broken bound is an UNBOUNDED poll on the device. The stub `sleep` therefore ends the run file on its 31st call
# (it writes RUNAWAY), and each run file runs under `timeout 30` when there is one, so such a poll fails that shell's
# case in seconds instead of hanging the suite. Each run file records the identity of the shell that ran it and the
# suite asserts it is the shell the case launched. A mutant is convicted only when it fails under EVERY shell found.
#
#   bash test-seed-home-verdict.sh            # the behaviour cases
#   bash test-seed-home-verdict.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every temp of the run lives inside W.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=""; for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
IDPROBE='_id="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; [ -n "$_id" ] || _id=posix; _pr=none; command -v print >/dev/null 2>&1 && _pr=builtin'
REF_SH=""; command -v sh >/dev/null 2>&1 && REF_SH=$(sh -c "$IDPROBE; printf '%s|%s\n' \"\$_id\" \"\$_pr\"")
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
sq(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
TO=""; command -v timeout >/dev/null 2>&1 && TO=yes
# runsh <shell> <run file> -> the child's rc (124 when `timeout 30` stopped it)
runsh(){ ${TO:+timeout 30} "$1" "$2" >/dev/null 2>&1; }
# idok <shell> <id file> -> 0 iff the file holds at least one line and every line is that shell's identity
idok(){
  local s="$1" f="$2" l n=0
  [ -s "$f" ] || return 1
  while IFS= read -r l; do
    n=$((n+1))
    case "$s" in
      bash) case "$l" in bash:*'|none') ;; *) return 1 ;; esac ;;
      dash) [ "$l" = 'posix|none' ] || return 1 ;;
      mksh) case "$l" in 'ksh:|'*) return 1 ;; ksh:?*'|builtin') ;; *) return 1 ;; esac ;;
      sh)   [ "$l" = "$REF_SH" ] || return 1 ;;
      *)    return 1 ;;
    esac
  done < "$f"
  [ "$n" -gt 0 ]
}
# notrun <shell> <case dir>: a run file that recorded no identity never launched -- a HARNESS error (noted in
# $W/harness, which suite turns into exit 2), never a behavioural FAIL a mutant could be convicted by. One that recorded
# the WRONG shell is noted in $W/notrun for suite's per-shell FAIL line.
notrun() {
  [ -s "$2/shell.id" ] || { echo "$1" >> "$W/harness"; return 1; }
  idok "$1" "$2/shell.id" || { echo "$1" >> "$W/notrun"; return 1; }
}

extract() {  # extract <roamd.sh>: seed_home, then the op arm's body (label and `;;` dropped)
  sed -n '/^seed_home() {$/,/^}$/p' "$1"
  echo '__ARM__'
  sed -n '/^  seed-home)$/,/^    ;;$/p' "$1" | sed '1d;$d'
}

# run_case <shell> <block-file> <desc: yes|no> <tool: none|rc:out> <ldb: yes|no>
# -> "<RES>|<am calls>|<aurora calls>|<sleeps>"; "RUNAWAY|rc=<rc>" when the poll did not stop (the stub sleep's 31st
#    call, or `timeout 30`); "NOPARSE|" when the run file does not parse under <shell> (noted as a harness error)
# The run file's first line records the identity of the shell that runs it, so a runaway still leaves it.
run_case() {
  local sh="$1" blk="$2" desc="$3" tool="$4" ldb="$5" d rc
  d=$(mktemp -d -p "$W") || exit 2
  mkdir -p "$d/user/com.android.launcher3/databases"
  : > "$d/am"; : > "$d/aurora"; : > "$d/sleeps"
  [ "$ldb" = yes ] && : > "$d/user/com.android.launcher3/databases/launcher.db"
  [ "$desc" = yes ] && echo "x" > "$d/desc"
  case "$tool" in
    none) ;;
    *) printf '#!/bin/sh\n[ -n "%s" ] && echo "%s"\nexit %s\n' "${tool#*:}" "${tool#*:}" "${tool%%:*}" > "$d/tool"; chmod +x "$d/tool" ;;
  esac
  {
    printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$d/shell.id")"
    printf '%s\n' "$PRINT_SHIM"
    printf 'd=%s; RES=%s; LOG=%s; uid=10; USERDIR=%s; _sl=0\n' "$(sq "$d")" "$(sq "$d/res")" "$(sq "$d/log")" "$(sq "$d/user")"
    cat <<'STUB'
am() { echo "$*" >> "$d/am"; }
sleep() { _sl=$((_sl+1)); if [ "$_sl" -gt 30 ]; then echo RUNAWAY > "$d/runaway"; exit 97; fi; echo "$1" >> "$d/sleeps"; }
seed_aurora_installer() { echo "$1" >> "$d/aurora"; }
STUB
    sed '/^__ARM__$/,$d' "$blk" | sed -e "s@/system/etc/nowhere/default-home@$d/desc@" -e "s@/system/bin/nowhere_seed_home@$d/tool@"
    sed '1,/^__ARM__$/d' "$blk"
  } > "$d/run.sh"
  if ! "$sh" -n "$d/run.sh" >/dev/null 2>&1; then echo "$sh" >> "$W/harness"; echo 'NOPARSE|'; rm -rf "$d"; return; fi
  runsh "$sh" "$d/run.sh"; rc=$?
  notrun "$sh" "$d"
  if [ "$rc" = 124 ] || [ -f "$d/runaway" ]; then echo "RUNAWAY|rc=$rc"; rm -rf "$d"; return; fi
  printf '%s|%s|%s|%s\n' "$(cat "$d/res" 2>/dev/null)" "$(wc -l < "$d/am" 2>/dev/null || echo 0)" \
    "$(wc -l < "$d/aurora" 2>/dev/null || echo 0)" "$(wc -l < "$d/sleeps" 2>/dev/null || echo 0)"
  rm -rf "$d"
}

suite() {  # suite <roamd.sh> <shell> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" s="$2" quiet="${3:-}" b p1 p2 nb p=0 x=0 out
  # every line carries the shell after its case id: "S6 [mksh] ..."
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s [%s] %s\n' "${1%% *}" "$s" "${1#* }"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s [%s] %s\n' "${1%% *}" "$s" "${1#* }"; }
  # stopped <id> <out>: a poll that did not stop is that case's FAIL -- never a pass, never a harness error
  stopped() { case "$2" in 'RUNAWAY|'*) no "$1 the poll did not stop"; return 1 ;; esac; }
  b=$(mktemp -p "$W") && p1=$(mktemp -p "$W") && p2=$(mktemp -p "$W") && nb=$(mktemp -p "$W") || return 2
  extract "$f" > "$b"
  if ! grep -q 'SEED_VERDICT' "$b" || ! grep -q '^__ARM__$' "$b" || [ "$(wc -l < "$b")" -lt 20 ]; then
    echo "EXTRACTION FAILED: seed_home / seed-home arm missing in $f" >&2; rm -f "$b" "$p1" "$p2" "$nb"; return 2
  fi
  if ! grep -q '/system/bin/nowhere_seed_home' "$b" || ! grep -q '/system/etc/nowhere/default-home' "$b"; then
    echo "EXTRACTION FAILED: tool/descriptor paths not found in $f" >&2; rm -f "$b" "$p1" "$p2" "$nb"; return 2
  fi
  sed '/^__ARM__$/,$d' "$b" > "$p1"; sed '1,/^__ARM__$/d' "$b" > "$p2"
  if ! bash -n "$p1" || ! bash -n "$p2"; then
    echo "EXTRACTION FAILED: extracted blocks do not parse in $f" >&2; rm -f "$b" "$p1" "$p2" "$nb"; return 2
  fi
  if ! "$s" -n "$p1" || ! "$s" -n "$p2"; then
    echo "EXTRACTION FAILED: extracted blocks do not parse under $s in $f" >&2; rm -f "$b" "$p1" "$p2" "$nb"; return 2
  fi
  : > "$W/notrun"; : > "$W/harness"

  out=$(run_case "$s" "$b" yes "0:seeded 3" yes)
  stopped S1 "$out" && case "$out" in 'OK SEEDED 3|1|1|0') ok "S1 seeded -> OK SEEDED 3, launcher force-stopped once" ;; *) no "S1 got '$out'" ;; esac
  out=$(run_case "$s" "$b" yes "0:skip: workspace already has 4 item(s)" yes)
  stopped S2 "$out" && case "$out" in 'OK SKIPPED nonempty|0|1|0') ok "S2 non-empty workspace -> OK SKIPPED nonempty, no force-stop" ;; *) no "S2 got '$out'" ;; esac
  out=$(run_case "$s" "$b" yes "0:" yes)
  stopped S3 "$out" && case "$out" in 'OK SKIPPED norows|0|1|0') ok "S3 descriptor yields no rows -> OK SKIPPED norows, no force-stop" ;; *) no "S3 got '$out'" ;; esac
  out=$(run_case "$s" "$b" no "0:seeded 3" yes)
  stopped S4 "$out" && case "$out" in 'OK NODESC|0|1|0') ok "S4 no default-home -> OK NODESC" ;; *) no "S4 got '$out'" ;; esac
  out=$(run_case "$s" "$b" yes none yes)
  stopped S5 "$out" && case "$out" in 'ERR-SEED notool|0|1|0') ok "S5 tool missing -> ERR-SEED notool" ;; *) no "S5 got '$out'" ;; esac
  out=$(run_case "$s" "$b" yes "0:seeded 3" no)
  stopped S6 "$out" && case "$out" in 'ERR-SEED nodb|0|1|25') ok "S6 no launcher.db after the poll -> ERR-SEED nodb (25 stubbed sleeps)" ;; *) no "S6 got '$out'" ;; esac
  out=$(run_case "$s" "$b" yes "5:" yes)
  stopped S7 "$out" && case "$out" in 'ERR-SEED nodock|0|1|0') ok "S7 rc 5 -> ERR-SEED nodock" ;; *) no "S7 rc 5 was reported as '$out'" ;; esac
  out=$(run_case "$s" "$b" yes "4:boom" yes)
  stopped S8 "$out" && case "$out" in 'ERR-SEED rc=4|0|1|0') ok "S8 failed insert -> ERR-SEED rc=4" ;; *) no "S8 got '$out'" ;; esac
  # captured first and filtered second, so the sed cannot hide a runaway
  out=$(run_case "$s" "$b" yes "0:seeded 3" yes)
  if stopped S9 "$out"; then
    out=$(printf '%s\n' "$out" | sed 's/^[^|]*|//')
    [ "$out" = '1|1|0' ] && ok "S9 aurora installer still runs" || no "S9 got '$out'"
  fi

  # S10: a seed_home that leaves no verdict must yield ERR-SEED noverdict, not an empty $RES.
  sed -e '/^seed_home() {$/,/^}$/{/^  SEED_VERDICT=""$/d;s/^\(  \[ -f "\$desc" \] || { echo .*\)SEED_VERDICT="OK NODESC"; return; }$/\1return; }/}' "$b" > "$nb"
  out=$(run_case "$s" "$nb" no "0:seeded 3" yes)
  stopped S10 "$out" && case "$out" in 'ERR-SEED noverdict|'*) ok "S10 a branch with no verdict -> ERR-SEED noverdict" ;; *) no "S10 got '$out'" ;; esac

  rm -f "$b" "$p1" "$p2" "$nb"
  if [ -s "$W/harness" ]; then echo "HARNESS ERROR: a run file left no identity or did not parse: $s did not run it" >&2; return 2; fi
  # run_case runs inside $( ), so a case that did not run under $s says so through $W/notrun
  if grep -qx "$s" "$W/notrun"; then no "identity: a case did not run under $s"; else ok "identity: every case ran under $s"; fi
  [ -n "$quiet" ] || printf '  -- [%s] %d ok, %d failed\n' "$s" "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "seed-home op verdict: $SUT"
echo "shells:$SHELLS"
echo "sh identity: $REF_SH"
for s in $SHELLS; do
  suite "$SUT" "$s"; rc=$?
  case "$rc" in 0) ;; 1) FAILED=1 ;; *) HARNESS=1 ;; esac
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT under every shell found):"
  mtmp=$(mktemp -d -p "$W") || exit 2
  mutate() {  # <label> <sed program>
    local label="$1" prog="$2" mf="$mtmp/r.sh" r s alive="" err=""
    if ! sed -E "$prog" "$SUT" > "$mf"; then printf '  ERR   %-64s sed program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    for s in $SHELLS; do
      suite "$mf" "$s" quiet >/dev/null 2>&1; r=$?
      case "$r" in
        0) alive="$alive $s" ;;
        1) ;;
        *) err="$err $s" ;;
      esac
    done
    if [ -n "$alive" ]; then printf '  XX    %-64s SURVIVED under:%s\n' "$label" "$alive"; MFAIL=1
    elif [ -n "$err" ]; then printf '  ERR   %-64s harness error (not a conviction) under:%s\n' "$label" "$err"; MFAIL=1
    else printf '  ok    %-64s convicted under every shell\n' "$label"; fi
  }
  mutate 'the op writes a bare OK unconditionally'        's@^    echo "\$\{SEED_VERDICT:-ERR-SEED noverdict\}" > "\$RES"$@    echo "OK" > "$RES"@'
  mutate 'the force-stop leaks out of the seeded arm'     's@^        skip:\*\) SEED_VERDICT@        skip:*) am force-stop --user "$uid" com.android.launcher3; SEED_VERDICT@'
  mutate 'rc 5 mapped to OK'                              's@SEED_VERDICT="ERR-SEED nodock"@SEED_VERDICT="OK"@'
  mutate 'the no-launcher.db branch without a verdict'    's@; SEED_VERDICT="ERR-SEED nodb"; return; \}@; return; }@'
  mutate 'the noverdict default removed'                  's@\$\{SEED_VERDICT:-ERR-SEED noverdict\}@$SEED_VERDICT@'
  # bash and dash: `[` errors on "x0", the poll ends at once (0 sleeps, not 25). mksh reads "x0" as 0: the poll is
  # unbounded, and the stub sleep's 31st call ends it (RUNAWAY) -- S6 fails under every shell, in seconds.
  mutate 'the poll bound compares a non-number'           's@\[ "\$i" -lt 25 \]@[ "x$i" -lt 25 ]@'
  # unbounded under EVERY shell: the proof, on a host with no mksh, that the bounded stub ends a runaway poll
  mutate 'the poll loses its bound'                       's@ && \[ "\$i" -lt 25 \]@@'
  # the runner ignores its shell argument and always runs bash: the identity check must convict it under every non-bash shell
  mutate_runner() {
    local s bad="" want="" cp="$mtmp/suite-runner.sh"
    sed 's/^runsh(){ \${TO:+timeout 30} "\$1" "\$2"/runsh(){ ${TO:+timeout 30} bash "$2"/' "$0" > "$cp"
    if cmp -s "$0" "$cp"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "the runner always runs bash"; MFAIL=1; return; fi
    for s in $SHELLS; do
      case "$s" in
        bash) ;;
        sh) case "$REF_SH" in bash:*) ;; *) want="$want $s" ;; esac ;;
        *) want="$want $s" ;;
      esac
    done
    [ -n "$want" ] || { printf '  n/a   %-64s no non-bash shell on this host (CI has dash and mksh)\n' "the runner always runs bash"; return; }
    bash "$cp" "$SUT" > "$mtmp/runner.out" 2>&1
    for s in $want; do grep -q "FAIL  [^ ]* \[$s\]" "$mtmp/runner.out" || bad="$bad $s"; done
    if [ -z "$bad" ]; then printf '  ok    %-64s convicted under:%s\n' "the runner always runs bash" "$want"
    else printf '  XX    %-64s SURVIVED under:%s\n' "the runner always runs bash" "$bad"; MFAIL=1; fi
  }
  # harness-error probe: a child that never launches must end the suite with exit 2 and HARNESS ERROR -- not exit 1
  # with FAIL lines, which a mutation run would count as a conviction
  probe() {  # probe <label> <sed program over this suite>
    local cp="$mtmp/suite-probe.sh" rc
    sed "$2" "$0" > "$cp"
    if cmp -s "$0" "$cp"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "$1"; MFAIL=1; return; fi
    bash "$cp" "$SUT" > "$mtmp/probe.out" 2>&1; rc=$?
    if [ "$rc" -eq 2 ] && grep -q 'HARNESS ERROR' "$mtmp/probe.out"; then printf '  ok    %-64s harness error, not a conviction\n' "$1"
    else printf '  XX    %-64s HARNESS ERROR NOT RAISED (rc %s)\n' "$1" "$rc"; MFAIL=1; fi
  }
  probe 'the child never launches' 's/^runsh(){ .*$/runsh(){ return 127; }/'
  mutate_runner
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; FAILED=1; }
fi

[ -z "${HARNESS:-}" ] || exit 2
exit "${FAILED:-0}"
