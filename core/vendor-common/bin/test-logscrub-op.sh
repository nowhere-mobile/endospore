#!/usr/bin/env bash
# test-logscrub-op.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's credless `logscrub` op (NWP-20261027-02).
#
# WHY. The chooser removes a FAILED sign-in's throwaway user with dpm.removeUser and never sends CLEAN-STORAGE, so
# cleanstorage's log_scrub never runs for it and the typed name stays in login.log / roam.log until a later reap or
# the next boot. The login daemon now sends `logscrub` after the BLANK / BLANK NET reply. The op must run log_scrub
# with NO argument (no session is being reaped, so nothing is carried -- an argument would carry that uid's lines),
# answer OK in $RES at mode 600, and sit before the name/uid arg guard (the daemon sends no name), after btwipe's arm.
#
# The arm is EXTRACTED from nowhere_roamd.sh by its anchor (exit 2 if absent) and run with log_scrub stubbed to record
# its arguments, under every shell the runner has (bash, sh, dash, mksh; LOGSCRUB_SHELLS=<paths> restricts the list).
#
#   bash test-logscrub-op.sh               # the checks
#   bash test-logscrub-op.sh --mutate      # ... plus mutants that must each CONVICT the suite under each shell
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
if [ -n "${LOGSCRUB_SHELLS:-}" ]; then
  read -r -a SHELLS <<< "$LOGSCRUB_SHELLS"
else
  seen=" "
  for s in bash sh dash mksh; do
    p=$(command -v "$s" 2>/dev/null) || continue
    r=$(readlink -f "$p")
    case "$seen" in *" $r "*) continue ;; esac
    seen="$seen$r "; SHELLS+=("$p")
  done
fi

ARM_HEAD='if [ "$op" = "logscrub" ]; then'
ARM=$(awk -v h="$ARM_HEAD" '
  on && $0 == "fi" { print; exit }
  $0 == h { on = 1 }
  on { print }' "$SUT")
case "$ARM" in "$ARM_HEAD"*) ;; *) echo "EXTRACTION FAILED: the logscrub arm is absent from $SUT" >&2; exit 2 ;; esac

# Position: after the btwipe arm, before the arg guard that needs a name and uid.
L_ARM=$(grep -n -F -x "$ARM_HEAD" "$SUT" | head -1 | cut -d: -f1)
L_BT=$(grep -n -F -x 'if [ "$op" = "btwipe" ]; then' "$SUT" | head -1 | cut -d: -f1)
L_GUARD=$(grep -n -F -x '[ -n "$op" ] && [ -n "$name" ] && [ -n "$uid" ] || { echo "ERR-ARGS" > "$RES"; chmod 600 "$RES"; exit 0; }' "$SUT" | head -1 | cut -d: -f1)
[ -n "$L_BT" ] && [ -n "$L_GUARD" ] || { echo "EXTRACTION FAILED: btwipe arm or the arg guard not found" >&2; exit 2; }
if [ "$L_ARM" -gt "$L_BT" ] && [ "$L_ARM" -lt "$L_GUARD" ]; then ok "the arm sits after btwipe and before the name/uid guard"
else no "the arm is at line $L_ARM; it must be after btwipe ($L_BT) and before the guard ($L_GUARD)"; fi

# Count it once: a second arm would be dead code that reads like a second copy of the rule.
[ "$(grep -c -F -x "$ARM_HEAD" "$SUT")" = 1 ] && ok "exactly one logscrub arm" || no "more than one logscrub arm"

for sh in "${SHELLS[@]}"; do
  tag="[${sh##*/}]"
  C=$(mktemp -d -p "$W")
  {
    printf 'op=logscrub; name=; uid=; RES=%s/res\n' "$C"
    printf 'log_scrub() { echo "called:$#:$*" >> %s/calls; }\n' "$C"
    printf '%s\n' "$ARM"
    printf 'echo FELL-THROUGH > %s/res\n' "$C"
  } > "$C/arm.sh"
  "$sh" "$C/arm.sh" >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && ok "$tag exits 0" || no "$tag exit status $rc"
  [ "$(cat "$C/res" 2>/dev/null)" = OK ] && ok "$tag RES is OK" || no "$tag RES is '$(cat "$C/res" 2>/dev/null)'"
  mode=$(stat -c %a "$C/res" 2>/dev/null)
  [ "$mode" = 600 ] && ok "$tag RES is mode 600" || no "$tag RES mode is '$mode'"
  [ "$(cat "$C/calls" 2>/dev/null)" = "called:0:" ] && ok "$tag log_scrub called exactly once with no argument" \
    || no "$tag log_scrub calls: '$(cat "$C/calls" 2>/dev/null)'"
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite under each shell) =="
  # mutate <label> <file-producing command...>: one copy per mutant, the suite once per shell, each of which must fail
  mutate(){ local lbl="$1" m s; shift; m=$(mktemp -d -p "$W")
    if ! "$@" > "$m/m" 2>"$m/err"; then no "MUTATION BROKEN: $lbl: $(cat "$m/err")"; rm -rf "$m"; return; fi
    if cmp -s "$SUT" "$m/m"; then no "MUTATION INERT: $lbl"; rm -rf "$m"; return; fi
    for s in "${SHELLS[@]}"; do
      LOGSCRUB_SHELLS="$s" bash "$0" "$m/m" >/dev/null 2>&1
      if [ $? -eq 0 ]; then no "NOT CONVICTED under ${s##*/}: $lbl -- suite passes on broken code"; else ok "convicted under ${s##*/}: $lbl"; fi
    done
    rm -rf "$m"
  }
  # L1 drops the whole arm (the suite exits 2, which is a conviction: it never passes)
  l1(){ awk -v h="$ARM_HEAD" 'skip { if ($0 == "fi") skip = 0; next } $0 == h { skip = 1; next } { print }' "$SUT"; }
  # L4 moves the arm after the arg guard: the arm is written out once, then spliced in below the guard line
  l4(){ printf '%s\n' "$ARM" > "$W/l4.arm"
    awk -v h="$ARM_HEAD" -v armf="$W/l4.arm" -v g='[ -n "$op" ] && [ -n "$name" ] && [ -n "$uid" ] || { echo "ERR-ARGS" > "$RES"; chmod 600 "$RES"; exit 0; }' '
      skip { if ($0 == "fi") skip = 0; next }
      $0 == h { skip = 1; next }
      { print }
      $0 == g { while ((getline l < armf) > 0) print l }' "$SUT"; }
  mutate "L1: the arm removed" l1
  mutate "L2: log_scrub given \"\$uid\"" sed '/^if \[ "\$op" = "logscrub" \]; then$/,/^fi$/ s/^  log_scrub$/  log_scrub "$uid"/' "$SUT"
  mutate "L3: RES not written" sed '/^if \[ "\$op" = "logscrub" \]; then$/,/^fi$/ s/^  echo "OK" > "\$RES"$/  :/' "$SUT"
  mutate "L4: the arm moved after the name/uid guard" l4
fi

echo
echo "shells: ${SHELLS[*]}; $PASS ok, $FAIL failed"
[ "$FAIL" = 0 ]
