#!/usr/bin/env bash
# test-btlogoff-logoff-only.sh [<nowhere_roamd.sh>] [--mutate] -- the #154 .btlogoff marker clears the device's
# Bluetooth ONLY on the logoff's own seal (NWP-20261010-10, round 3).
#
# WHY THIS IS COMMITTED. sweepmedia writes the marker so the logoff seal that follows wipes the device's bonds. A
# sign-out that then FAILED (a refused or unpushed seal) kept its session -- and its marker -- and the next periodic
# seal that landed read it: bt_reset on a LIVE user, and the seal after that sealed the emptied pairings over the
# profile. A sweep that timed out could also write the marker after the daemon had given up on it. The `out` arm now
# honours the marker only when roam.req line 6 (the run kind) is "logoff", and drops it on any other run. Silent
# when it regresses -- the headset just disconnects -- so it is pinned. h49 #13 (NWP-20261119-03): a sign-out that
# stopped a running Back up now runs as "logoff-pinned", and the block treats it exactly as "logoff" (C6, C7, M4).
#
# The marker block of the `out` arm is extracted BY ANCHOR and run against temp files with bt_reset stubbed.
#
#   bash test-btlogoff-logoff-only.sh            # the cases
#   bash test-btlogoff-logoff-only.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# EVERY SHELL (NWP-20261112-32). The device runs the `out` arm under mksh (/system/bin/sh); the suite used to parse
# and eval the block in bash only. The block, its assignments and the bt_reset stub are now written into a runner
# file that each of bash, dash, mksh and sh (when sh is not one of those) found parses (`"$sh" -n`) and runs, every
# case tagged `[<sh>]`; the suite's own bookkeeping stays bash. A mutant is convicted only when EVERY shell found has
# its own `FAIL  [<sh>]` line. mksh reads a non-number in `[ x -eq 0 ]` as 0, silently, where bash and dash error:
# mutant N1 is that class, and C5 (a failed reset keeps the marker) is the case that convicts it under mksh.
#
# NWP-20261123-26: the WRITE side too. sweepmedia's `( : > "$STATE/.btlogoff" )` was unchecked: a marker that could
# not be written answered OK with no line, so the logoff seal did not wipe the bonds and nothing said so. The
# `sweepmedia)` arm is now also extracted by anchor (label to the first `    ;;`) and run with stop_mediad stubbed and
# /proc/mounts re-pointed at a fixture with no media mount. B1 plants .btlogoff as a DIRECTORY with one entry (a
# redirection onto a directory fails for any user, root included): the arm still answers OK and writes one `could NOT
# mark .btlogoff` line. B2 is the writable control. Both run under every shell, bash as --posix, so the bare-form
# mutant N-b (the op ends at a failed redirection on `:`) is convicted there too.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT

# Shells, each run by its own name: bash, dash and mksh where found, then sh unless it is one of those (by realpath).
SHELLS=""; SEEN=" "
for cand in bash dash mksh sh; do
  p=$(command -v "$cand" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$SEEN" in *" $r "*) continue ;; esac
  SEEN="$SEEN$r "; SHELLS="$SHELLS $cand"
done
[ -n "$SHELLS" ] || { echo "no POSIX shell found" >&2; exit 2; }
# The same shim as test-log-name-scrub.sh's PRINT_SHIM: bash and dash have no `print`; mksh (the device's sh) does.
PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

# A line PREFIX (the extract matches with index()==1): the fixed line and M4's pre-h49-#13 mutant both start so.
ANCHOR='      if [ -f "$STATE/.btlogoff" ] && [ "$skind" != logoff ]'

# From the anchor through the SECOND closing `      fi` (the stale-marker block, then the honouring block).
extract() { awk -v a="$ANCHOR" 'index($0,a)==1{on=1} on{print} on&&/^      fi$/{n++; if(n==2) exit}' "$1"; }
# NWP-20261123-26: the sweepmedia arm, from its label to the first `    ;;` (test-sweepmedia-verify.sh's extract).
extract_sweep() { awk 'index($0,"  sweepmedia)")==1{on=1;next} on&&/^    ;;$/{exit} on{print}' "$1"; }

# suite <script> <shell> [quiet] -> 0 iff every case behaved under <shell>. FAIL lines print in quiet mode too: they
# are a mutant's evidence, per shell.
suite() {
  local f="$1" sh="$2" quiet="${3:-}" p=0 x=0 blk pf
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$sh" "$1"; }
  no(){ x=$((x+1)); printf '  FAIL  [%s] %s\n' "$sh" "$1"; }

  blk=$(extract "$f")
  case "$blk" in *'bt_reset ""'*) ;; *) no "EXTRACTION FAILED -- the .btlogoff block moved in $f"; return 2 ;; esac

  # runner <file> <dir> <kind> <bt_reset rc> -- the file "$sh" runs: the shim, the assignments, the stub, the block.
  runner() {
    { [ "$sh" = mksh ] || printf '%s\n' "$PRINT_SHIM"
      printf "skind='%s'\nuid=10\nSTATE='%s'\nLOG='%s/log'\n" "$3" "$2" "$2"
      printf "bt_reset(){ : > '%s/reset'; return %s; }\n" "$2" "$4"
      printf '%s\n' "$blk"
    } > "$1"
  }
  # Round 6: the block must still PARSE, or the suite would fail it for its syntax and call that a conviction.
  # NWP-20261112-32: parsed by the shell that runs it, from a file.
  pf=$(mktemp -p "$W") || return 2
  runner "$pf" "$W" logoff 0
  "$sh" -n "$pf" 2>/dev/null || { rm -f "$pf"; no "THE BLOCK DOES NOT PARSE under $sh in $f"; return 2; }
  rm -f "$pf"

  # run <kind> <marker yes|no> [<bt_reset rc>, default 0] -> "<RESET or NONE>|<marker KEPT or GONE>"
  run() {
    local d; d=$(mktemp -d -p "$W")
    [ "$2" = yes ] && : > "$d/.btlogoff"
    runner "$d/run.sh" "$d" "$1" "${3:-0}"
    "$sh" "$d/run.sh" >/dev/null 2>&1
    local r=NONE m=GONE
    [ -e "$d/reset" ] && r=RESET
    [ -e "$d/.btlogoff" ] && m=KEPT
    printf '%s|%s\n' "$r" "$m"
    command rm -rf "$d"
  }

  [ "$(run logoff yes)" = "RESET|GONE" ] && ok "C1 the logoff's own seal clears the device and the marker" \
    || no "C1 the logoff's seal did not clear the device"
  [ "$(run '' yes)" = "NONE|GONE" ] && ok "C2 a periodic seal drops a stale marker and clears NOTHING" \
    || no "C2 a periodic seal acted on a stale marker"
  [ "$(run manual yes)" = "NONE|GONE" ] && ok "C3 a Back-up-now seal drops it and clears nothing" \
    || no "C3 a manual seal acted on the marker"
  [ "$(run logoff no)" = "NONE|GONE" ] && ok "C4 a logoff with no marker clears nothing" || no "C4 reset without a marker"
  [ "$(run logoff yes 1)" = "RESET|KEPT" ] && ok "C5 a logoff whose reset fails keeps the marker for the retry" \
    || no "C5 a failed reset dropped the marker"
  [ "$(run logoff-pinned yes)" = "RESET|GONE" ] \
    && ok "C6 a pinned sign-out (h49 #13) clears the device and the marker, as a logoff does" \
    || no "C6 a pinned sign-out did not clear the device"
  [ "$(run logoff-pinned yes 1)" = "RESET|KEPT" ] && ok "C7 a pinned sign-out whose reset fails keeps the marker" \
    || no "C7 a pinned sign-out's failed reset dropped the marker"

  # B1/B2 (NWP-20261123-26): the sweepmedia arm writes the marker, and says so when it cannot.
  local sblk; sblk=$(extract_sweep "$f")
  case "$sblk" in *'/proc/mounts'*'.btlogoff'*'echo "OK" > "$RES"'*) ;;
    *) no "EXTRACTION FAILED -- the sweepmedia arm lost .btlogoff, its OK answer or its /proc/mounts read in $f"; return 2 ;; esac
  sblk=${sblk//\/proc\/mounts/\$MOUNTS}
  # srun <dir|writable> -> "<RES>|<could-NOT-mark lines naming user 10 and #154>|<marker file?>|<summary after it?>|<sentinel>"
  srun() {
    local d o= r=NONE n c l s=NO e=NO; d=$(mktemp -d -p "$W")
    mkdir "$d/state"; printf 'tmpfs /dev tmpfs rw 0 0\n' > "$d/mounts"
    [ "$1" = dir ] && { mkdir "$d/state/.btlogoff"; : > "$d/state/.btlogoff/entry"; }
    { [ "$sh" = mksh ] || printf '%s\n' "$PRINT_SHIM"
      printf "uid=10\nSTATE='%s/state'\nLOG='%s/log'\nRES='%s/res'\nMOUNTS='%s/mounts'\n" "$d" "$d" "$d" "$d"
      printf 'stop_mediad() { return 0; }\n%s\necho REACHED >> "%s/after"\n' "$sblk" "$d"
    } > "$d/run.sh"
    [ "$sh" = bash ] && o=--posix
    "$sh" $o "$d/run.sh" >/dev/null 2>&1
    [ -f "$d/res" ] && r=$(cat "$d/res")
    n=$(grep -F 'sweepmedia user 10: could NOT mark .btlogoff' "$d/log" 2>/dev/null | grep -cF '(#154)')
    [ -f "$d/state/.btlogoff" ] && s=FILE
    c=$(grep -nF 'could NOT mark' "$d/log" 2>/dev/null | head -n 1); c=${c%%:*}
    l=$(grep -nF 'sweepmedia (logoff pre-seal teardown) user 10: 0 media mount(s) left' "$d/log" 2>/dev/null | head -n 1); l=${l%%:*}
    [ -n "$l" ] && [ "$l" -gt "${c:-0}" ] && e=YES
    printf '%s|%s|%s|%s|%s\n' "$r" "$n" "$s" "$e" "$(cat "$d/after" 2>/dev/null)"
    chmod -R u+rwx "$d" 2>/dev/null; command rm -rf "$d"
  }
  local got
  got=$(srun dir)
  [ "$got" = "OK|1|NO|YES|REACHED" ] \
    && ok "B1 .btlogoff unwritable: OK answered, one could-NOT-mark line (user 10, #154), the summary follows (bash as --posix)" \
    || no "B1 .btlogoff unwritable: got '$got', want 'OK|1|NO|YES|REACHED'"
  got=$(srun writable)
  [ "$got" = "OK|0|FILE|YES|REACHED" ] && ok "B2 writable state: OK, the marker is written, no could-NOT-mark line" \
    || no "B2 writable state: got '$got', want 'OK|0|FILE|YES|REACHED'"

  # The kind the block keys on must be the one line 6 carries.
  grep -qF 'IFS= read -r sesec; IFS= read -r skind;' "$f" && ok "W1 skind is roam.req line 6" || no "W1 skind no longer read from line 6"

  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "== $SUT (shells:$SHELLS)"
rc=0
for sh in $SHELLS; do suite "$SUT" "$sh" || rc=1; done
[ "$rc" = 0 ] || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- by behaviour: a mutant that no longer extracts proves nothing)"
mut() { # mut <label> <perl-expr>
  local m rc sh out ev bad=0; m=$(mktemp -p "$W")
  # FAIL CLOSED (NWP-20261010-10, round 5): a perl error or an empty mutant used to read as "convicted", because the
  # suite fails on it -- for the wrong reason. Each is now its own failure, and so is a mutant whose block no longer
  # extracts (suite rc 2): a conviction must come from behaviour.
  if ! perl -0pe "$2" "$SUT" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; command rm -f "$m"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; command rm -f "$m"; return 1; fi
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; command rm -f "$m"; return 1; fi
  # NWP-20261112-32: convicted only when every shell found fails it with its own `FAIL  [<sh>]` line.
  for sh in $SHELLS; do
    out=$(suite "$m" "$sh" quiet 2>&1); rc=$?
    ev=$(grep -F -- "  FAIL  [$sh] " <<<"$out")
    case "$rc" in
      0) echo "  SURVIVED  $1 [$sh]"; bad=1 ;;
      1) if [ -n "$ev" ]; then echo "  convicted $1 [$sh]"; printf '%s\n' "$ev" | sed 's/^/      /'
         else echo "  UNPROVEN  $1 [$sh] -- rc 1 with no FAIL line of its own"; bad=1; fi ;;
      *) echo "  BROKEN    $1 [$sh] -- the mutant's block no longer extracts or parses (rc=$rc)"; bad=1 ;;
    esac
  done
  command rm -f "$m"
  [ "$bad" = 0 ]
}
fails=0
mut "M1 the logoff seal keeps its marker"           's/(        if bt_reset ""; then\n)          rm -f "\$STATE\/\.btlogoff"\n/$1/' || fails=$((fails+1))
mut "M2 a stale marker kept on a periodic seal"    's/(\[ "\$skind" != logoff-pinned \]; then\n)        rm -f "\$STATE\/\.btlogoff"\n/$1        true\n/' || fails=$((fails+1))
# M3 keeps the anchor line, so it convicts on behaviour (round 5, F5): a manual seal honouring the marker.
mut "M3 a manual seal clears Bluetooth too"         's/\n      if \[ -f "\$STATE\/\.btlogoff" \]; then\n/\n      if [ -f "\$STATE\/.btlogoff" ] || [ "\$skind" = manual ]; then\n/' || fails=$((fails+1))
# N1 (NWP-20261112-32): the reset's status compared as a non-number. bash and dash error on `[ x0 -eq 0 ]`, so the
# marker is kept and C1 convicts; mksh reads x0 and x1 as 0, silently, so a FAILED reset drops it and C5 convicts.
mut "N1 the reset's status read as a non-number"     's/(\n        )if bt_reset ""; then\n          rm -f "\$STATE\/\.btlogoff"\n/$1bt_reset ""; _brc=x\$?; if [ \$_brc -eq 0 ]; then\n          rm -f "\$STATE\/.btlogoff"\n/' || fails=$((fails+1))
# M4 (NWP-20261119-03): the exact pre-h49-#13 `!= logoff` test restored; the anchor prefix still extracts, C6 convicts.
mut "M4 the exact != logoff test restored"          's/ && \[ "\$skind" != logoff-pinned \]//' || fails=$((fails+1))
# N-a / N-b (NWP-20261123-26): the marker write's check dropped (silent again), and the write made bare (the op ends).
mut "N-a the .btlogoff write is unchecked again"     's/      if ! \( : > "\$STATE\/\.btlogoff" \) 2>> "\$LOG"; then\n[^\n]*\n      fi\n/      ( : > "\$STATE\/.btlogoff" )\n/' || fails=$((fails+1))
mut "N-b the .btlogoff write is bare"               's/      if ! \( : > "\$STATE\/\.btlogoff" \) 2>> "\$LOG"; then\n[^\n]*\n      fi\n/      : > "\$STATE\/.btlogoff"\n/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
