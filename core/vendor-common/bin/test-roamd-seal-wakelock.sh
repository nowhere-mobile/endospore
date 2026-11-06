#!/usr/bin/env bash
# test-roamd-seal-wakelock.sh [--mutate] [<nowhere_roamd.sh>] -- NWP-20261117-02: the `out` op holds the kernel
# wakelock nowhere_seal from its start and releases it on every way the op can end.
#
# WHY THIS IS COMMITTED. The acquire and the release fail in OPPOSITE directions, and both fail silently:
#   * lose the ACQUIRE and a seal started with the screen on stalls when the screen goes off. On frankel
#     (2026102202, ticket NW-a17e164b51d3) one periodic seal took 20 m 35 s, and the CPU was suspended for 803 s of it.
#   * lose the RELEASE and a KERNEL wakelock leaks. It has no owner and no timeout: the phone does not suspend
#     again until it reboots.
# Neither shows in a build, a boot or a headless check.
#
# The helper block (SEAL_WL=nowhere_seal to the end of seal_wl_end) and the arm's wakelock block (inside `  out)`,
# from its first `    seal_wl_release` line to the first `    fi`) are extracted from nowhere_roamd.sh BY ANCHOR,
# never copied. An empty extraction stops the suite with EXTRACTION FAILED, exit 2.
#
# THE ONE TRANSFORM: the /sys/power/ paths are absolute, so they are redirected into each case's temp tree. Nothing
# else is altered. The kernel is emulated as test-otad-wakelock.sh does: a name written to wake_unlock leaves
# wake_lock. Each case runs the extracted text in a CHILD shell, so the block's own EXIT trap never replaces this
# suite's trap. The cases and the source pins run under every shell found of bash, sh, dash and mksh (mksh is the
# device's /system/bin/sh).
#
#   bash test-roamd-seal-wakelock.sh             # the behaviour cases and the source pins
#   bash test-roamd-seal-wakelock.sh --mutate    # ... plus 6 mutations that must each CONVICT the suite
#   ROAMD_SCRIPT=<path> bash test-roamd-seal-wakelock.sh   # run against another copy of roamd
#
# Pure shell: no build, no device, no root.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do
  case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac
done
SUT="${SUT:-${ROAMD_SCRIPT:-$(dirname "$0")/nowhere_roamd.sh}}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    [%s] %s\n' "$1" "$2"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  [%s] %s\n' "$1" "$2"; }

# --- extraction --------------------------------------------------------------------------------------------------
# A check here may require only text that EVERY mutant below keeps: a mutant that stops the extraction exits 2,
# and an exit 2 never counts as a conviction.
HELPERS=$(awk '
  /^SEAL_WL=nowhere_seal$/ { on = 1 }
  on { print }
  on && /^seal_wl_end\(\) \{$/ { inend = 1 }
  on && inend && /^}$/ { exit }
' "$SUT")
ACQ=$(awk '
  /^  out\)$/ { inarm = 1; next }
  inarm && !on && /^    seal_wl_release/ { on = 1 }
  on { print }
  on && /^    fi$/ { exit }
' "$SUT")
for need in 'seal_wl_release()' 'seal_susp()' 'seal_wl_end()' 'wake_unlock'; do
  case "$HELPERS" in *"$need"*) ;; *) echo "EXTRACTION FAILED: the helper block has no $need -- anchors moved" >&2; exit 2 ;; esac
done
for need in 'held' 'WARNING'; do
  case "$ACQ" in *"$need"*) ;; *) echo "EXTRACTION FAILED: the out arm's wakelock block has no $need -- anchors moved" >&2; exit 2 ;; esac
done

# --- shells ------------------------------------------------------------------------------------------------------
# sh is run even when it is bash: bash started as sh runs in POSIX mode, which is a different shell for traps.
SHELLS=()
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || { echo "  skip  shell $s not installed"; continue; }
  SHELLS+=("$p")
done
[ "${#SHELLS[@]}" -gt 0 ] || { echo "no shell to run under" >&2; exit 2; }

# --- harness -----------------------------------------------------------------------------------------------------
# run_case <shell> <mode normal|refused> <tail>: the extracted text, then a line that deletes wake_unlock (so any
# later wake_unlock is a release after the body, never the pre-acquire release), a BODY-END mark, then <tail>.
# It sets these globals for the case: C_RC, C_HELD (names still held), C_REL (yes when released after the body),
# C_LOG, C_MARKS, C_ERR, C_MID (wake_lock at the end of the body).
run_case(){
  local sh="$1" mode="$2" tail="$3" T held rel n
  T=$(mktemp -d -p "$W")
  mkdir -p "$T/power/suspend_stats"
  : > "$T/power/wake_lock"; : > "$T/power/wake_unlock"
  echo 4 > "$T/power/suspend_stats/success"
  if [ "$mode" = refused ]; then rm -f "$T/power/wake_lock"; mkdir "$T/power/wake_lock"; fi
  {
    echo "LOG='$T/log'"
    echo 'uid=12'
    printf '%s\n' "$HELPERS" | sed "s#/sys/power/#$T/power/#g"
    printf '%s\n' "$ACQ" | sed "s#/sys/power/#$T/power/#g"
    echo "rm -f '$T/power/wake_unlock'"
    echo "cat '$T/power/wake_lock' > '$T/mid' 2>/dev/null"
    echo "echo BODY-END >> '$T/marks'"
    printf '%s\n' "$tail"
  } > "$T/run.sh"
  "$sh" "$T/run.sh" > "$T/out" 2> "$T/err"; C_RC=$?
  held=""; [ -f "$T/power/wake_lock" ] && held=$(cat "$T/power/wake_lock")
  rel=""; [ -f "$T/power/wake_unlock" ] && rel=$(cat "$T/power/wake_unlock")
  C_REL=no
  for n in $rel; do
    [ "$n" = nowhere_seal ] && C_REL=yes
    held=$(printf '%s\n' $held | grep -vxF "$n")
  done
  C_HELD=$(printf '%s' "$held" | tr -d '[:space:]')
  C_LOG=$(cat "$T/log" 2>/dev/null)
  C_MARKS=$(cat "$T/marks" 2>/dev/null)
  C_ERR=$(cat "$T/err" "$T/out" 2>/dev/null)
  C_MID=$(cat "$T/mid" 2>/dev/null)
  rm -rf "$T"
}
count(){ printf '%s\n' "$1" | grep -cF -- "$2"; }
has(){ case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# released_once <tag> <what>: the lock is released after the body, nothing is still held, one end line.
released_once(){
  local tag="$1" what="$2" c
  [ "$C_REL" = yes ] && ok "$tag" "$what: nowhere_seal released" || no "$tag" "$what: nowhere_seal NOT released (wake_lock still [$C_HELD])"
  [ -z "$C_HELD" ] && ok "$tag" "$what: nothing left held" || no "$tag" "$what: LOCK LEAKED [$C_HELD]"
  c=$(count "$C_LOG" 'out wakelock nowhere_seal released (suspends during seal:')
  [ "$c" = 1 ] && ok "$tag" "$what: one released line" || no "$tag" "$what: $c released lines (log: $C_LOG)"
}

for SH in "${SHELLS[@]}"; do
  tag=${SH##*/}
  echo "== [$tag] behaviour =="

  run_case "$SH" normal ''
  [ "$C_MID" = nowhere_seal ] && ok "$tag" "acquire writes nowhere_seal to wake_lock" || no "$tag" "acquire: wake_lock holds [$C_MID] at the end of the body"
  has "$C_LOG" 'out wakelock nowhere_seal held (suspends since boot: 4)' && ok "$tag" "acquire logs the start count" || no "$tag" "acquire log line missing (log: $C_LOG)"
  [ "$C_RC" = 0 ] && ok "$tag" "a clean end exits 0" || no "$tag" "a clean end exits $C_RC"
  released_once "$tag" "a clean end"
  has "$C_LOG" 'suspends during seal: 0)' && ok "$tag" "a clean end logs 0 suspends" || no "$tag" "end line has no 0 delta (log: $C_LOG)"

  run_case "$SH" normal 'exit 1'
  [ "$C_RC" = 1 ] && ok "$tag" "exit 1 keeps its status" || no "$tag" "exit 1 exits $C_RC"
  released_once "$tag" "exit 1"

  for sig in TERM:143 INT:130 HUP:129; do
    run_case "$SH" normal "kill -${sig%%:*} \$\$; echo AFTER-KILL >> \"\$(dirname \"\$LOG\")/marks\""
    [ "$C_RC" = "${sig##*:}" ] && ok "$tag" "SIG${sig%%:*} exits ${sig##*:}" || no "$tag" "SIG${sig%%:*} exits $C_RC, want ${sig##*:}"
    has "$C_MARKS" AFTER-KILL && no "$tag" "SIG${sig%%:*}: the op ran on after the signal" || ok "$tag" "SIG${sig%%:*} stops the op"
    released_once "$tag" "SIG${sig%%:*}"
  done

  run_case "$SH" normal '( exit 0 ); [ -e "$(dirname "$LOG")/power/wake_unlock" ] && echo SUBREL >> "$(dirname "$LOG")/marks"'
  has "$C_MARKS" SUBREL && no "$tag" "a subshell's exit released the lock" || ok "$tag" "a subshell's exit does not release"
  released_once "$tag" "the end after a subshell"

  run_case "$SH" refused ''
  # The one transform rewrote /sys/power/ in the WARNING text too, so the path is not matched.
  has "$C_LOG" 'out WARNING: ' && has "$C_LOG" '/power/wake_lock refused -- ' && ok "$tag" "a refused write logs the WARNING" || no "$tag" "a refused write logged no WARNING (log: $C_LOG)"
  has "$C_LOG" 'can stall while the screen is off (suspends since boot: 4)' && ok "$tag" "the WARNING carries the start count" || no "$tag" "the WARNING has no start count (log: $C_LOG)"
  has "$C_LOG" 'nowhere_seal held' && no "$tag" "a refused write logged held" || ok "$tag" "a refused write logs no held line"
  has "$C_MARKS" BODY-END && ok "$tag" "the op continues after a refused write" || no "$tag" "the op stopped at a refused write"
  [ "$C_RC" = 0 ] && ok "$tag" "a refused write never fails the op" || no "$tag" "a refused write: exit $C_RC"

  run_case "$SH" normal 'echo 9 > "$(dirname "$LOG")/power/suspend_stats/success"'
  has "$C_LOG" 'released (suspends during seal: 5)' && ok "$tag" "the end line carries the delta" || no "$tag" "the end line has no delta 5 (log: $C_LOG)"

  run_case "$SH" normal 'rm -f "$(dirname "$LOG")/power/suspend_stats/success"'
  has "$C_LOG" 'released (suspends during seal: unknown)' && ok "$tag" "a missing end count reads unknown" || no "$tag" "a missing end count (log: $C_LOG)"
  [ -z "$C_ERR" ] && ok "$tag" "a missing end count prints no error" || no "$tag" "a missing end count printed [$C_ERR]"
done

# --- source pins ---------------------------------------------------------------------------------------------------
# The pins read the WHOLE real script, and they run under EACH shell found, as the behaviour cases do: a mutant only
# a pin can see (the acquire moved, a second EXIT trap) must still FAIL on every shell's own line. Each run prints
# its own ok / FAIL lines under that shell's tag; a run that dies before its last check is a FAIL too.
# Comments are stripped first: full-line comments, and a trailing ` # ...` comment.
# The stripped script and the wakelock block go to FILES ($3, $4), and every check reads a file. mksh has no printf
# builtin, so `printf '%s\n' "$text"` passes the text as one argument to /usr/bin/printf, and the kernel refuses an
# argument over 128 KB (E2BIG); the stripped roamd is far larger. A pipe that a reader closes early also printed
# write errors under bash and dash.
PINS=$(mktemp -p "$W")
cat > "$PINS" <<'PINS_EOF'
SUT="$1"; TAG="$2"; SF="$3"; BF="$4"
ok(){ printf '  ok    [%s] %s\n' "$TAG" "$1"; }
no(){ printf '  FAIL  [%s] %s\n' "$TAG" "$1"; }
sed -E 's/^[[:space:]]*#.*//; s/[[:space:]]+#[[:space:]].*$//' "$SUT" > "$SF"
lines(){ grep -nE -- "$1" "$SF" | cut -d: -f1; }
OUT_L=$(lines '^  out\)$')
START_TXT='    echo "[roamd] out start user $uid $(date)" >> "$LOG"'
START_L=$(grep -nxF -- "$START_TXT" "$SF" | cut -d: -f1)
if [ "$(printf '%s\n' "$OUT_L" | grep -c .)" = 1 ] && [ "$(printf '%s\n' "$START_L" | grep -c .)" = 1 ]; then
  first=$(awk -v a="$OUT_L" 'NR > a && NF { print NR; exit }' "$SF")
  [ "$first" = "$START_L" ] && ok "the out arm opens with its unchanged out start line" || no "the first statement of the out arm is line $first, not the out start line ($START_L)"
else
  no "want one '  out)' line and one out start line, got [$OUT_L] [$START_L]"
  START_L=0
fi
ARMEND_L=$(awk -v a="${OUT_L:-0}" 'NR > a && /^  [a-z][a-z0-9_-]*\)$/ { print NR; exit }' "$SF")
PUSH_L=$(awk -v a="${OUT_L:-0}" -v e="${ARMEND_L:-0}" 'NR > a && NR < e && /(^|[[:space:];&|])_push [a-z]/ { print NR; exit }' "$SF")
ACQ_B=$(awk -v a="${OUT_L:-0}" 'NR > a && /^    seal_wl_release$/ { print NR; exit }' "$SF")
ACQ_E=$(awk -v b="${ACQ_B:-0}" 'NR > b && /^    fi$/ { print NR; exit }' "$SF")
ACQ_LOCK=$(awk -v b="${ACQ_B:-0}" -v e="${ACQ_E:-0}" 'NR > b && NR < e && /> \/sys\/power\/wake_lock/ { print NR; exit }' "$SF")
if [ -n "$ACQ_B" ] && [ -n "$ACQ_E" ] && [ -n "$ACQ_LOCK" ] && [ -n "$PUSH_L" ] && [ -n "$ARMEND_L" ] \
   && [ "$ACQ_B" -gt "$START_L" ] && [ "$ACQ_E" -lt "$PUSH_L" ] && [ "$PUSH_L" -lt "$ARMEND_L" ]; then
  ok "the acquire sits in the out arm, after out start and above its first _push call"
else
  no "the acquire is not between out start and the first _push call (block [$ACQ_B..$ACQ_E] lock [$ACQ_LOCK] out start [$START_L] _push [$PUSH_L] arm end [$ARMEND_L])"
fi
TRAPS=$(lines '(^|[;&|(]|then|do|else)[[:space:]]*trap[[:space:]]')
ntraps=0; outside=""
for l in $TRAPS; do
  ntraps=$((ntraps+1))
  if [ -z "$ACQ_B" ] || [ -z "$ACQ_E" ] || [ "$l" -lt "$ACQ_B" ] || [ "$l" -gt "$ACQ_E" ]; then outside="$outside $l"; fi
done
[ -z "$outside" ] && ok "every trap command lies inside the wakelock block" || no "trap command(s) outside the wakelock block at stripped line(s):$outside"
[ "$ntraps" = 4 ] && ok "the file has four trap commands" || no "the file has $ntraps trap commands, want 4"
sed -n "${ACQ_B:-1},${ACQ_E:-0}p" "$SF" > "$BF"
for want in "    trap seal_wl_end EXIT" "    trap 'seal_wl_end; trap - EXIT; exit 130' INT" \
            "    trap 'seal_wl_end; trap - EXIT; exit 143' TERM" "    trap 'seal_wl_end; trap - EXIT; exit 129' HUP"; do
  c=$(grep -cxF -- "$want" "$BF")
  [ "$c" = 1 ] && ok "one [${want#    }]" || no "$c of [${want#    }] in the wakelock block"
done
c=$(grep -cx 'SEAL_WL=nowhere_seal' "$SF")
[ "$c" = 1 ] && ok "SEAL_WL=nowhere_seal is set once" || no "SEAL_WL=nowhere_seal is set $c times"
c=$(grep -cxF 'seal_wl_release() { echo "$SEAL_WL" > /sys/power/wake_unlock 2>/dev/null; }' "$SF")
[ "$c" = 1 ] && ok "the release writes \$SEAL_WL to wake_unlock" || no "the release does not write \$SEAL_WL to wake_unlock"
c=$(grep -cxF '    if echo "$SEAL_WL" > /sys/power/wake_lock 2>/dev/null; then' "$BF")
[ "$c" = 1 ] && ok "the acquire writes \$SEAL_WL to wake_lock" || no "the acquire does not write \$SEAL_WL to wake_lock"
HLP_B=$(awk '$0 == "SEAL_WL=nowhere_seal" { print NR; exit }' "$SF")
HLP_E=$(awk -v b="${HLP_B:-0}" 'NR > b && /^}$/ { print NR; exit }' "$SF")
outside=""
for l in $(lines 'seal_wl_(release|end)|seal_susp|SEAL_WL|/sys/power/wake_(un)?lock'); do
  if [ -n "$HLP_B" ] && [ -n "$HLP_E" ] && [ "$l" -ge "$HLP_B" ] && [ "$l" -le "$HLP_E" ]; then continue; fi
  if [ -n "$ACQ_B" ] && [ -n "$ACQ_E" ] && [ "$l" -ge "$ACQ_B" ] && [ "$l" -le "$ACQ_E" ]; then continue; fi
  outside="$outside $l"
done
[ -z "$outside" ] && ok "no other line takes or releases the lock" || no "the lock is named outside its two blocks at stripped line(s):$outside"
echo PINS-DONE
PINS_EOF

for SH in "${SHELLS[@]}"; do
  tag=${SH##*/}
  echo "== [$tag] source pins =="
  out=$("$SH" "$PINS" "$SUT" "$tag" "$(mktemp -p "$W")" "$(mktemp -p "$W")" 2>&1); rc=$?
  printf '%s\n' "$out" | grep -v '^PINS-DONE$'
  PASS=$((PASS + $(printf '%s\n' "$out" | grep -c '^  ok    \[')))
  FAIL=$((FAIL + $(printf '%s\n' "$out" | grep -c '^  FAIL  \[')))
  if [ "$rc" != 0 ] || ! has "$out" PINS-DONE; then no "$tag" "the source pins did not run to the end (exit $rc)"; fi
done

# --- mutations -----------------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted under each listed tag) =="
  ALLTAGS=""
  for SH in "${SHELLS[@]}"; do ALLTAGS="$ALLTAGS ${SH##*/}"; done
  # mutate <name> <tags that must each show a FAIL line> <awk program applied to roamd>
  mutate(){
    local name="$1" want="$2" prog="$3" m out rc t miss=""
    m=$(mktemp -p "$W")
    awk "$prog" "$SUT" > "$m"
    if cmp -s "$m" "$SUT"; then no mutate "mutant did not apply: $name"; return; fi
    out=$(ROAMD_SCRIPT="" bash "$0" "$m" 2>&1); rc=$?
    if [ "$rc" != 1 ]; then no mutate "NOT CONVICTED: $name -- the suite exited $rc"; return; fi
    for t in $want; do
      has "$out" "  FAIL  [$t] " || miss="$miss $t"
    done
    [ -z "$miss" ] && ok mutate "convicted: $name (under$(printf ' %s' $want))" || no mutate "NOT CONVICTED under$miss: $name"
  }
  mutate "the EXIT trap removed" "$ALLTAGS" '$0 != "    trap seal_wl_end EXIT" { print }'
  mutate "the acquire removed" "$ALLTAGS" \
    '{ if ($0 == "    if echo \"$SEAL_WL\" > /sys/power/wake_lock 2>/dev/null; then") print "    if false; then"; else print }'
  mutate "the TERM trap without its exit" "$ALLTAGS" \
    '{ if ($0 == "    trap '"'"'seal_wl_end; trap - EXIT; exit 143'"'"' TERM") print "    trap '"'"'seal_wl_end'"'"' TERM"; else print }'
  # The moved block still extracts and still behaves, so only the source pins convict it, under each shell.
  mutate "the acquire moved below the first _push call" "$ALLTAGS" '
    /^  out\)$/ { inarm = 1 }
    inarm && !done && /^    seal_wl_release/ { grab = 1 }
    grab { blk = blk $0 "\n"; if ($0 == "    fi") { grab = 0; done = 1 }; next }
    { print }
    done && !put && /^    _push vault / { printf "%s", blk; put = 1 }'
  mutate "the release names a different lock" "$ALLTAGS" \
    '{ if (index($0, "seal_wl_release() { echo \"$SEAL_WL\" > /sys/power/wake_unlock") == 1) sub(/"\$SEAL_WL"/, "nowhere_ota"); print }'
  mutate "a second trap ... EXIT in another arm" "$ALLTAGS" \
    '{ print } $0 == "  in)" { print "    trap '"'"'true'"'"' EXIT" }'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
