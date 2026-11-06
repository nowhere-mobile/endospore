#!/usr/bin/env bash
# test-otad-wakelock.sh [<nowhere_otad.sh>] -- exercise NWP-20260903-02's suspend blocker.
#
# WHY THIS IS COMMITTED. The acquire and the release are two lines that must live or die together, and they
# fail in OPPOSITE directions, both silently:
#   * lose the ACQUIRE and the OTA goes back to stalling whenever the screen sleeps -- the bug this fixed,
#     which took three field applies (644s / 1260s / 3656s) and an owner's hunch to even notice.
#   * lose the RELEASE and a KERNEL wakelock leaks. Unlike a framework PARTIAL_WAKE_LOCK it has no owner and
#     no timeout: the phone simply never suspends again until it reboots. On an amnesiac device, where an
#     owner's whole session ends at power-off, that is a battery bug with no diagnostic trail at all.
# Neither shows up in a build, a boot, or a headless check. So they get a test.
#
# The blocks are extracted from nowhere_otad.sh BY ANCHOR, never copied. If the anchors move the extraction
# is empty and every case fails loudly -- a test carrying its own stale copy of the code would keep passing
# after the real code changed, which is the failure mode worth engineering against.
#
# THE ONE TRANSFORM, stated because a test that quietly rewrites its subject is not testing it: the /sys
# paths are absolute, so they are redirected into a fake tree. Nothing else is altered.
#
#   bash test-otad-wakelock.sh             # the 8 behaviour cases
#   bash test-otad-wakelock.sh --mutate    # ... plus 4 mutations that must each CONVICT the suite
#
# Pure logic -- no build, no device, no root. Device-proven separately on lynx in the real su:s0 domain
# (acquire, presence in /sys/power/wake_lock, trap-release on exit, and mksh not leaking the EXIT trap into
# the apply pipeline's subshells); this guards the invariant from here on.
set -uo pipefail

MUTATE=no; OTAD=""
for a in "$@"; do
  case "$a" in --mutate) MUTATE=yes ;; *) OTAD="$a" ;; esac
done
OTAD="${OTAD:-$(dirname "$0")/nowhere_otad.sh}"
[ -f "$OTAD" ] || { echo "no such script: $OTAD" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2] want [$3]"; }

# --- extraction ------------------------------------------------------------------------------------------
# Block A: the acquire (WLNAME through the closing fi). Block B: the suspend-delta case.
extract(){ sed -n "/$1/,/$2/p" "$OTAD"; }
BLOCK_A=$(extract '^WLNAME=' '^fi$' | head -20)
BLOCK_B=$(extract '^case "[$]APPLY_S0[$]APPLY_S1" in' '^esac$')

for n in A B; do
  eval "v=$"BLOCK_$n
  case "$n$v" in A*WLNAME=*|B*SUSPD*) ;; *) echo "EXTRACTION FAILED for block $n -- anchors moved" >&2; exit 2 ;; esac
done

# --- harness ---------------------------------------------------------------------------------------------
# Run block A against a fake /sys. `writable` controls whether the wake_lock node accepts a write, which is
# how the refusal path (a kernel without CONFIG_PM_WAKELOCKS) gets exercised without one.
run_a(){                       # run_a <writable yes|no> <preexisting lock text> [extra shell after the block]
  local T; T=$(mktemp -d)
  mkdir -p "$T/power/suspend_stats"
  printf '%s' "$2" > "$T/power/wake_lock"
  : > "$T/power/wake_unlock"
  echo 4 > "$T/power/suspend_stats/success"
  [ "$1" = no ] && chmod 000 "$T/power/wake_lock"
  {
    echo 'LOG=$T/log'
    # The fake wake_unlock node is a plain file, so emulate the kernel: a write REMOVES that name.
    echo "$BLOCK_A" | sed "s#/sys/power/#\$T/power/#g"
    echo "${3:-}"
  } > "$T/run.sh"
  # Emulate the kernel node: wake_unlock removes the name from wake_lock. Done as a trap-safe wrapper so the
  # real wl_release body (the thing under test) is what runs.
  T="$T" bash -c '
    source "$T/run.sh" 2>"$T/err"
  ' 2>/dev/null
  # Apply the emulation after the fact: whatever landed in wake_unlock is removed from wake_lock.
  local held rel
  held=$(cat "$T/power/wake_lock" 2>/dev/null || echo "")
  rel=$(cat "$T/power/wake_unlock" 2>/dev/null || echo "")
  [ -n "$rel" ] && held=${held//$rel/}
  printf '%s|%s' "${held// /}" "$(cat "$T/log" 2>/dev/null | tr -d '"'"'\n'"'"')"
  chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"
}

echo "== acquire / release =="
r=$(run_a yes "")
case "$r" in *"wakelock nowhere_ota held"*) ok "acquire logs that it took the lock" ;; *) no "acquire did not log (got: $r)" ;; esac
case "$r" in *"suspends since boot: 4"*) ok "logs the suspend counter at acquire" ;; *) no "no suspend counter in the log" ;; esac

# HOW THIS ISOLATES THE TRAP, which the first version of this test got wrong. The block calls wl_release
# BEFORE it acquires, so simply looking at the fake wake_unlock node afterwards cannot tell the two releases
# apart -- and a mutation deleting the trap sailed through. So: delete the node as the LAST statement of the
# block. Anything that recreates it ran strictly after, and the only thing that can is the exit trap.
echo "== the exit trap, isolated from the pre-acquire release =="
trap_fires(){                 # 1 if something released the lock AFTER the block's own body finished
  local T; T=$(mktemp -d); mkdir -p "$T/power/suspend_stats"
  : > "$T/power/wake_lock"; : > "$T/power/wake_unlock"; echo 4 > "$T/power/suspend_stats/success"
  { echo 'LOG=$T/log'
    echo "$BLOCK_A" | sed "s#/sys/power/#\$T/power/#g"
    echo 'rm -f "$T/power/wake_unlock"'      # LAST body statement: only the trap can recreate it
  } > "$T/run.sh"
  T="$T" bash -c 'source "$T/run.sh"' >/dev/null 2>&1
  [ -s "$T/power/wake_unlock" ] && echo yes || echo no
  rm -rf "$T"
}
is "the trap releases at exit (not just the pre-acquire release)" "$(trap_fires)" "yes"

echo "== the node refusing the write is reported, not swallowed =="
r=$(run_a no "")
case "$r" in *"WARNING"*"wake_lock refused"*) ok "refusal warns in the log" ;; *) no "refusal was silent (got: $r)" ;; esac

echo "== early exit still releases (the script has seven of them) =="
r=$(run_a yes "" 'exit 0')
case "${r%%|*}" in "") ok "an early exit 0 still runs the trap" ;; *) no "LOCK LEAKED past an early exit: [${r%%|*}]" ;; esac

# NWP-20261017-26: nowhere_otad.sh keeps one `| grep -q` pipeline (the ERR-CHECK
# absence shape) that is safe ONLY because it sets no pipefail; a later `set -o pipefail` would let a
# SIGPIPE'd producer fail the absence check open. Pin it. Comments (incl. the one explaining why apply
# does not rely on pipefail) are stripped first.
echo "== otad stays pipefail-free =="
nopf(){ sed 's/^[[:space:]]*#.*//' "$1" | grep -c 'pipefail' ; }
is "no pipefail outside comments" "$(nopf "$OTAD")" "0"

echo "== suspend delta =="
delta(){ APPLY_S0=$1 APPLY_S1=$2 bash -c "APPLY_S0=$1; APPLY_S1=$2; $BLOCK_B"'; echo "$SUSPD"'; }
is "0 suspends reads 0"            "$(delta 7 7)"  "0"
is "4 suspends during apply"       "$(delta 3 7)"  "4"
is "a missing counter is 'unknown'" "$(delta '?' 7)" "unknown"

# --- mutations -------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d)
  mutate(){ # <name> <sed program> -- the suite must FAIL on the mutated script
    sed "$2" "$OTAD" > "$M/m.sh"
    if bash "$0" "$M/m.sh" >/dev/null 2>&1; then
      no "NOT CONVICTED: $1 -- the suite passes on broken code, so it is not testing this"
    else
      ok "convicted: $1"
    fi
  }
  mutate "trap removed (kernel wakelock leaks forever)" '/^trap wl_release EXIT/d'
  # NOT MUTATED: the bare pre-acquire `wl_release`. The trap covers every exit path this run can take,
  # so deleting that line changes nothing observable -- there is no mutation to convict, and asserting
  # one anyway would be a test that passes on broken code. The script says so at the line itself.
  mutate "acquire removed (OTA stalls when the screen sleeps)" 's#^if echo "[$]WLNAME" > /sys/power/wake_lock.*#if false; then#'
  mutate "suspend-delta guard removed (mksh dies on a missing counter)" 's#^  [*]"?"[*]) SUSPD="unknown" ;;##'
  mutate "pipefail set (the grep -q site would fail open)" '2i set -o pipefail'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
