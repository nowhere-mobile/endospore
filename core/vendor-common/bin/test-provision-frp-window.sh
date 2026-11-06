#!/usr/bin/env bash
# test-provision-frp-window.sh [<nowhere_provision.sh>] [--mutate] -- the pre-device-owner window hold
# (NWP-20261011-14): docs/owner-identity-spec.md §5.5 / docs/owner-claim-spec.md §7.1.
#
# WHY THIS IS COMMITTED. Between boot_completed and the device-owner claim, nowhere_provision.sh holds
# development_settings_enabled and adb_enabled at 0 so Build number x7 -> Developer options -> OEM unlocking is
# not left open. Every way that block breaks is silent: a dropped debuggable guard turns adb OFF on every dev
# device after a wipe (fighting the dev block that turns it on), a dropped owner_ok break fights the gate for five
# minutes, a dropped key leaves adb on, a raised cap outlives the window, and a dropped /dev/null redirect makes
# the cmd hand an su:s0 fd to system_server so it never runs under enforcing sepolicy. None of that logs. This
# suite pins the guard, the cap, the break, both keys, the stdio, the one log line and where the block sits.
#
# The block is extracted from nowhere_provision.sh BY ANCHOR (# FRP-WINDOW-BEGIN / # FRP-WINDOW-END), never
# copied; if the anchors move or vanish, extraction fails loudly rather than a stale copy passing forever.
# getprop, settings, sleep and owner_ok are stubbed as shell functions that record to a scratch dir; getprop
# answers only ro.debuggable and records anything else, so a guard pointed at the wrong prop fails the suite.
#
# The block runs under EACH shell found on PATH (bash, sh, dash, mksh -- nowhere_provision.sh is `#!/system/bin/sh`,
# mksh on the device), sourced with `.` from a generated run file, and every shell's own `-n` must parse it. The
# run file appends the running shell's identity (ksh:$KSH_VERSION, bash:$BASH_VERSION, or posix) to <case>/shell and
# the `I` check requires it to match the shell launched (mksh a KSH_VERSION, bash a BASH_VERSION, dash `posix`, sh
# whatever `sh` is on this host), because stderr is discarded and an error message would prove nothing.
#
#   bash test-provision-frp-window.sh            # the behaviour cases, under every shell found
#   bash test-provision-frp-window.sh --mutate   # ... plus seven mutations; each must FAIL under EVERY shell found
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SELF="$0"
SUT="${SUT:-$(dirname "$0")/nowhere_provision.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
echo "shells:$SHELLS"
SH_ID=$(env -u KSH_VERSION -u BASH_VERSION sh -c '_i="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; echo "${_i:-posix}"')

# id_matches <shell> <recorded identity>
id_matches() {
  case "$1" in
    bash) case "$2" in bash:?*) return 0 ;; esac ;;
    mksh) case "$2" in ksh:?*) return 0 ;; esac ;;
    dash) [ "$2" = posix ] && return 0 ;;
    sh) [ "$2" = "$SH_ID" ] && return 0 ;;
  esac
  return 1
}

extract_block() { sed -n '/^# FRP-WINDOW-BEGIN/,/^# FRP-WINDOW-END/p' "$1"; }

# first_line <ERE> <file> -> the line number of the first match, empty if none
first_line() { local n; n=$(grep -nE -m1 -e "$1" "$2" | cut -d: -f1); echo "${n:-}"; }

# run_block <shell> <blockfile> <debuggable> <owner_ok_at> <dir> -- run the block, under that shell, against the
# stubs, wait for its child. owner_ok answers true from its <owner_ok_at>-th call on (0 = never).
run_block() {
  local sh="$1" blk="$2" dbg="$3" at="$4" d="$5"
  {
    printf 'D=%s; DEBUGGABLE=%s; OWNER_OK_AT=%s; LOG="$D/provision.log"\n' "$d" "$dbg" "$at"
    cat <<'RUN'
_nw_id="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; echo "${_nw_id:-posix}" >> "$D/shell"
getprop() {
  case "${1:-}" in
    ro.debuggable) echo "$DEBUGGABLE" ;;
    *) echo "getprop $*" >> "$D/unexpected"; echo "" ;;
  esac
}
settings() { echo "$*" >> "$D/settings"; }
sleep() { echo "${1:-}" >> "$D/slept"; }
owner_ok() {
  local c=0
  [ -f "$D/okcalls" ] && c=$(cat "$D/okcalls")
  c=$((c + 1)); echo "$c" > "$D/okcalls"
  [ "$OWNER_OK_AT" -gt 0 ] && [ "$c" -ge "$OWNER_OK_AT" ]
}
RUN
    printf '. %s\nwait\n' "$blk"
  } > "$d/run.sh"
  env -u KSH_VERSION -u BASH_VERSION "$sh" "$d/run.sh" >/dev/null 2>&1
}

# expected_passes <n> -> the settings calls of n full passes, in order
expected_passes() {
  local i=0
  while [ "$i" -lt "$1" ]; do
    echo "put global development_settings_enabled 0"
    echo "put global adb_enabled 0"
    i=$((i + 1))
  done
}

lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
val() { if [ -f "$1" ]; then cat "$1"; else echo none; fi; }

# extract <nowhere_provision.sh> -> BLK = the extracted block file (under $W); returns 2 when it cannot be extracted
# or when any shell found refuses to parse it
extract() {
  local f="$1" b e bl el s
  b=$(grep -c '^# FRP-WINDOW-BEGIN' "$f"); e=$(grep -c '^# FRP-WINDOW-END' "$f")
  if [ "$b" != 1 ] || [ "$e" != 1 ]; then
    echo "EXTRACTION FAILED: want exactly one # FRP-WINDOW-BEGIN and one # FRP-WINDOW-END in $f (got $b / $e)" >&2
    return 2
  fi
  bl=$(first_line '^# FRP-WINDOW-BEGIN' "$f"); el=$(first_line '^# FRP-WINDOW-END' "$f")
  if [ "$bl" -ge "$el" ]; then echo "EXTRACTION FAILED: # FRP-WINDOW-END (line $el) is not after BEGIN (line $bl) in $f" >&2; return 2; fi
  BLK=$(mktemp -p "$W"); extract_block "$f" > "$BLK"
  if [ ! -s "$BLK" ] || ! bash -n "$BLK" 2>/dev/null || ! sh -n "$BLK" 2>/dev/null; then
    echo "EXTRACTION FAILED: the block between the anchors is empty or does not parse (bash -n / sh -n) in $f" >&2
    return 2
  fi
  for s in $SHELLS; do
    "$s" -n "$BLK" 2>/dev/null || { echo "EXTRACTION FAILED: $s -n refuses the block between the anchors in $f" >&2; return 2; }
  done
}

suite() {  # suite <shell> <nowhere_provision.sh> <blockfile> -> 0 all ok, 1 a case failed, 2 harness error
  local sh="$1" f="$2" blk="$3" d exp p=0 x=0 bl el ml fl al sl n m c k s o idbad="" first="" herr=""
  ok() { p=$((p+1)); printf '  ok    [%s] %s\n' "$sh" "$1"; }
  no() { x=$((x+1)); printf '  FAIL  [%s] %s\n' "$sh" "$1"; }
  idchk() {  # idchk <case> -- the case's child must have recorded exactly one line, the launched shell's identity
    local rec cnt
    rec=$(cat "$d/shell" 2>/dev/null); cnt=$(grep -c '' "$d/shell" 2>/dev/null)
    # no record, or not exactly one, means the child never ran as launched: a HARNESS error (exit 2), which is
    # never a behavioural FAIL and so can never convict a mutant
    if [ "$cnt" != 1 ]; then herr="$herr $1=${cnt:-0}lines"; return; fi
    [ -n "$first" ] || first="$rec"
    id_matches "$sh" "$rec" || idbad="$idbad $1=${rec:-none}"
  }
  bl=$(first_line '^# FRP-WINDOW-BEGIN' "$f"); el=$(first_line '^# FRP-WINDOW-END' "$f")

  # --- placement: below the marker early-exit and owner_ok/foreign_owner, above the claim ---
  ml=$(first_line '^\[ -f "\$MARK" \] && exit 0$' "$f"); fl=$(first_line '^foreign_owner\(\) \{$' "$f")
  sl=$(first_line '^am start -n com\.nowhere\.chooser' "$f"); al=$(first_line '^attempt=0$' "$f")
  if [ -n "$ml" ] && [ "$bl" -gt "$ml" ]; then ok "P1 the block is below the marker early-exit (an unmarked boot IS the window)"
  else no "P1 BEGIN line $bl, marker exit line '${ml}'"; fi
  if [ -n "$fl" ] && [ "$bl" -gt "$fl" ]; then ok "P2 the block is below foreign_owner() (owner_ok is defined above it)"
  else no "P2 BEGIN line $bl, foreign_owner line '${fl}'"; fi
  if [ -n "$sl" ] && [ "$el" -lt "$sl" ]; then ok "P3 the block is above the chooser am start"
  else no "P3 END line $el, am start line '${sl}'"; fi
  if [ -n "$al" ] && [ "$el" -lt "$al" ]; then ok "P4 the block is above the claim loop (attempt=0)"
  else no "P4 END line $el, attempt=0 line '${al}'"; fi

  # --- A: a debuggable build does nothing (the dev block below turns both keys ON) ---
  d=$(mktemp -d -p "$W"); run_block "$sh" "$blk" 1 0 "$d"
  if [ ! -e "$d/settings" ] && [ ! -e "$d/slept" ] && [ ! -e "$d/okcalls" ] && [ ! -e "$d/provision.log" ] \
     && [ ! -e "$d/unexpected" ]; then
    ok "A ro.debuggable=1 -> no settings call, no sleep, no owner_ok, no log line"
  else
    no "A ro.debuggable=1 got settings=$(lines "$d/settings") slept=$(lines "$d/slept") okcalls=$(val "$d/okcalls") log=$(lines "$d/provision.log") unexpected='$(val "$d/unexpected")'"
  fi
  idchk A; command rm -rf "$d"

  # --- B: never owned -> exactly 100 passes, each writing BOTH keys to 0, then stop ---
  d=$(mktemp -d -p "$W"); exp=$(mktemp -p "$W"); expected_passes 100 > "$exp"; run_block "$sh" "$blk" 0 0 "$d"
  if [ -f "$d/settings" ] && cmp -s "$exp" "$d/settings"; then ok "B1 never owned -> 100 passes, each zeroing development_settings_enabled then adb_enabled"
  else no "B1 never owned got $(lines "$d/settings") settings calls (want 200 in pass order)"; fi
  if [ "$(val "$d/okcalls")" = 100 ]; then ok "B2 owner_ok checked once per pass (100)"; else no "B2 owner_ok calls $(val "$d/okcalls")"; fi
  n=$(lines "$d/slept"); m=0; [ -f "$d/slept" ] && m=$(grep -cvx 3 "$d/slept")
  if [ "$n" = 100 ] && [ "$m" = 0 ]; then ok "B3 sleeps 3 s after every pass (100 x 3s = the 5 min cap)"; else no "B3 slept $n times, $m not 3 s"; fi
  n=$(lines "$d/provision.log"); c=0; [ -f "$d/provision.log" ] && c=$(grep -c 'pre-owner window: holding developer options/adb off until device owner' "$d/provision.log")
  if [ "$n" = 1 ] && [ "$c" = 1 ]; then ok "B4 the parent logs exactly one 'pre-owner window' line, the loop logs nothing"
  else no "B4 provision.log has $n line(s), $c matching"; fi
  if [ ! -e "$d/unexpected" ]; then ok "B5 only ro.debuggable is read"; else no "B5 unexpected: $(val "$d/unexpected")"; fi
  idchk B; command rm -rf "$d" "$exp"

  # --- C: owned at the 3rd check -> two passes, then the gate takes over ---
  d=$(mktemp -d -p "$W"); exp=$(mktemp -p "$W"); expected_passes 2 > "$exp"; run_block "$sh" "$blk" 0 3 "$d"
  if [ -f "$d/settings" ] && cmp -s "$exp" "$d/settings"; then ok "C1 owner_ok true on the 3rd check -> stops after 2 passes"
  else no "C1 owned at check 3 got $(lines "$d/settings") settings calls (want 4)"; fi
  o=$(val "$d/okcalls"); s=$(lines "$d/slept"); n=$(lines "$d/provision.log")
  if [ "$o" = 3 ] && [ "$s" = 2 ] && [ "$n" = 1 ] && [ ! -e "$d/unexpected" ]; then ok "C2 3 owner_ok checks, 2 sleeps, one log line"
  else no "C2 okcalls=$o slept=$s log=$n unexpected='$(val "$d/unexpected")'"; fi
  idchk C; command rm -rf "$d" "$exp"

  # --- D: every settings call keeps its stdio off system_server (the fd-passing denial at owner_ok) ---
  k=$(grep -c 'settings put global development_settings_enabled 0 </dev/null >/dev/null 2>&1$' "$blk")
  m=$(grep -c 'settings put global adb_enabled 0 </dev/null >/dev/null 2>&1$' "$blk")
  c=$(grep -c 'settings put' "$blk")
  if [ "$k" = 1 ] && [ "$m" = 1 ] && [ "$c" = 2 ]; then ok "D both settings calls carry </dev/null >/dev/null 2>&1, and there is no third write"
  else no "D redirected dev=$k adb=$m, settings put lines=$c"; fi

  if [ -z "$idbad" ]; then ok "I every executed case (3) recorded the $sh identity ($first)"
  else no "I a case recorded another shell than $sh:$idbad"; fi

  printf '  -- [%s] %d ok, %d failed\n' "$sh" "$p" "$x"
  if [ -n "$herr" ]; then printf '  HARNESS ERROR [%s] no single identity record (child did not run):%s\n' "$sh" "$herr"; return 2; fi
  [ "$x" -eq 0 ] && return 0 || return 1
}

all_shells() {  # all_shells <script> -> 0 all shells pass, 1 a case failed, 2 the block could not be extracted
  local sh r rc=0
  extract "$1" || return 2
  for sh in $SHELLS; do
    suite "$sh" "$1" "$BLK"; r=$?
    if [ "$r" = 2 ]; then rc=2; elif [ "$r" != 0 ] && [ "$rc" = 0 ]; then rc=1; fi
  done
  return $rc
}

echo "pre-device-owner window hold: $SUT"
all_shells "$SUT"; rc=$?
[ "$rc" = 0 ] || FAILED=$rc

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must FAIL under every shell found:$SHELLS):"
  MT=$(mktemp -d -p "$W")
  R='/^# FRP-WINDOW-BEGIN/,/^# FRP-WINDOW-END/ '   # every program is confined to the block
  # judge <label> <outfile> <rc> <required shells...>: convicted only on rc 1 and a FAIL line under EACH shell
  judge() {
    local label="$1" out="$2" rc="$3" s bad=""; shift 3
    for s in "$@"; do grep -q -e "FAIL  \[$s\]" "$out" || bad="$bad $s"; done
    if [ "$rc" = 1 ] && [ -z "$bad" ]; then printf '  ok    %-64s convicted under:%s\n' "$label" " $*"
    elif [ "$rc" != 0 ] && [ "$rc" != 1 ]; then printf '  ERR   %-64s harness error (rc=%s), not a conviction\n' "$label" "$rc"; MFAIL=1
    else printf '  XX    %-64s NOT CONVICTED (rc %s, no FAIL line under:%s)\n' "$label" "$rc" "$bad"; MFAIL=1; fi
  }
  mutate() {  # <label> <sed program>
    local label="$1" prog="$2" mf="$MT/p.sh" r
    if ! sed -E "$prog" "$SUT" > "$mf"; then printf '  ERR   %-64s sed program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    bash "$SELF" "$mf" > "$MT/out" 2>&1; r=$?
    judge "$label" "$MT/out" "$r" $SHELLS
  }
  mutate 'the debuggable guard is gone'                       "${R}"'s@^if \[ "\$\(getprop ro\.debuggable\)" != "1" \]; then$@if true; then@'
  mutate 'the owner_ok break is gone'                         "${R}"'s@^      owner_ok && break .*$@      :@'
  mutate 'adb_enabled is no longer written'                   "${R}"'s@^      settings put global adb_enabled 0 .*$@      :@'
  mutate 'the cap is 1000'                                    "${R}"'s@-lt 100 \]@-lt 1000 ]@'
  mutate 'a settings call hands its stdio to system_server'   "${R}"'s@^(      settings put global development_settings_enabled 0) </dev/null >/dev/null 2>&1$@\1@'
  mutate 'the parent no longer logs the hold'                 "${R}"'s@^  echo "\[provision\] pre-owner window: .*$@  :@'
  # harness mutant: run_block ignores its shell and always runs bash; the identity check must convict it under
  # every shell whose identity is not bash's
  label='run_block ignores its shell argument and always runs bash'
  req=""
  for s in $SHELLS; do
    case "$s" in bash) ;; sh) case "$SH_ID" in bash:*) ;; *) req="$req sh" ;; esac ;; *) req="$req $s" ;; esac
  done
  if [ "$(grep -c '^  env -u KSH_VERSION -u BASH_VERSION "\$sh" ' "$SELF")" != 1 ]; then
    printf '  ERR   %-64s launch line not found exactly once\n' "$label"; MFAIL=1
  else
    sed 's@^\(  env -u KSH_VERSION -u BASH_VERSION \)"\$sh" @\1bash @' "$SELF" > "$MT/suite.sh"
    if cmp -s "$SELF" "$MT/suite.sh"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "$label"; MFAIL=1
    elif [ -z "$req" ]; then
      printf '  n/a   %-64s no non-bash shell on this host (sh is %s); CI has mksh and dash\n' "$label" "$SH_ID"
    else
      bash "$MT/suite.sh" "$SUT" > "$MT/out" 2>&1; r=$?
      judge "$label" "$MT/out" "$r" $req
    fi
  fi
  # fault injection: every child launch fails. That is a HARNESS error: the suite must exit 2 (never 0, never the
  # 1 that convicts a mutant), so a launch failure during a mutant run can never be credited as a conviction.
  label='run_block child launches fail (fault injection) -> harness error, exit 2'
  sed 's@^\(  env -u KSH_VERSION -u BASH_VERSION \)"\$sh" @\1false @' "$SELF" > "$MT/fault.sh"
  if cmp -s "$SELF" "$MT/fault.sh"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "$label"; MFAIL=1
  else
    bash "$MT/fault.sh" "$SUT" > "$MT/out" 2>&1; r=$?
    if [ "$r" = 2 ] && grep -q 'HARNESS ERROR' "$MT/out"; then printf '  ok    %-64s exit 2, not a conviction\n' "$label"
    else printf '  XX    %-64s rc=%s, want 2 with a HARNESS ERROR line\n' "$label" "$r"; MFAIL=1; fi
  fi
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS CONVICTED" || { echo "PROBLEM: a mutation survived"; FAILED=${FAILED:-1}; [ "$FAILED" = 2 ] || FAILED=1; }
fi

exit "${FAILED:-0}"
