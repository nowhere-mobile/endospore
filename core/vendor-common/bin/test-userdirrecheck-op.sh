#!/usr/bin/env bash
# test-userdirrecheck-op.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's credless `userdirrecheck` op (NWP-20261107-12).
#
# WHY. Q037 (dn-1104 #2, 2026-10-21): a reap whose user record never goes keeps users/<uid> and queues the uid in
# $STATE/userdir-pending; roamd re-checks it before every read-write-lane op, but with no sign-in or sign-out after the
# reap nothing runs. The login daemon sends this op every 5 minutes while the queue is non-empty. The arm must run
# userdir_recheck on the READ-WRITE lane only (the read-only lane shares the top-level case, and a removal there would
# run concurrently with the read-write lane), answer OK in $RES at mode 600, and sit after logscrub's arm and before the
# name/uid arg guard (the daemon sends no name).
#
# The arm is EXTRACTED from nowhere_roamd.sh by its anchor (exit 2 if absent) and run with userdir_recheck stubbed to
# record its calls, under every shell the runner has (bash, sh, dash, mksh; USERDIRRECHECK_SHELLS=<paths> restricts it).
#
# NWP-20261123-26: and userdir_recheck itself, with a list it cannot rewrite. Its `( : > "$_f.tmp" )` meets a target
# that cannot be written when $STATE/userdir-pending.tmp is a DIRECTORY with one entry (a redirection onto a directory
# fails for any user, root included). Every append to it then fails too (echo is not a special builtin, so the shell
# goes on), and the final `mv -f` cannot move a directory over the list: the list is KEPT byte for byte, never emptied,
# and the function returns 0. That branch is safe, so no code changed: U1 pins it, U2 is the writable control. The
# function is extracted by its anchor with userdir_has_record and reap_userdir_take stubbed, under every shell, bash as
# --posix, so mutant U-m (the write made bare: the function ends there) is convicted. roamd runs `chmod 600` on the
# plant, which takes its x bit, so U1 restores it before it reads the case dir, and the EXIT trap does so too.
#
# NWP-20261126-18: a temp that was CREATED but took none, or not all, of its lines replaced the list. A and B queue 11
# and 12 (on record, kept) and 13 (clears). A plants userdir-pending.tmp as a symlink to /dev/full: the truncation
# succeeds and every append fails (ENOSPC), for any user. B defines an echo function that drops the kept line
# `12 left`, so the temp is one line short. In both the list must stay a regular file with its original bytes, the
# temp must go, and roam.log gets `(- of 2 lines)` or `(1 of 2 lines)`. The list is read only after `[ ! -L ]` and
# only with `head -c 4096`: unchecked code moves the symlink over it, and a read of /dev/full never ends. A chmod
# function refuses a symlink, so unchecked code cannot chmod /dev/full as root. Without /dev/full, A prints SKIP.
# Mutants U-c1..U-c4 remove the check, drop only the count comparison, compare with a constant, or remove the list.
# C and D (review RF-001) replace the count reader with a wc function: C prints the right count and exits 1, D prints
# `2x`. Both must keep the list and log `(- of 2 lines)`. E prints a padded `      2` and is the control: the list is
# rewritten. Mutants U-c5..U-c7 ignore the reader's exit status, drop the number check, or drop the padding strip.
#
#   bash test-userdirrecheck-op.sh               # the checks
#   bash test-userdirrecheck-op.sh --mutate      # ... plus mutants that must each CONVICT the suite under each shell
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

SHELLS=()
if [ -n "${USERDIRRECHECK_SHELLS:-}" ]; then
  read -r -a SHELLS <<< "$USERDIRRECHECK_SHELLS"
else
  seen=" "
  for s in bash sh dash mksh; do
    p=$(command -v "$s" 2>/dev/null) || continue
    r=$(readlink -f "$p")
    case "$seen" in *" $r "*) continue ;; esac
    seen="$seen$r "; SHELLS+=("$p")
  done
fi

ARM_HEAD='if [ "$op" = "userdirrecheck" ]; then'
GUARD='[ -n "$op" ] && [ -n "$name" ] && [ -n "$uid" ] || { echo "ERR-ARGS" > "$RES"; chmod 600 "$RES"; exit 0; }'
ARM=$(awk -v h="$ARM_HEAD" '
  on && $0 == "fi" { print; exit }
  $0 == h { on = 1 }
  on { print }' "$SUT")
case "$ARM" in "$ARM_HEAD"*) ;; *) echo "EXTRACTION FAILED: the userdirrecheck arm is absent from $SUT" >&2; exit 2 ;; esac

# Position: after the logscrub arm, before the arg guard that needs a name and uid.
L_ARM=$(grep -n -F -x "$ARM_HEAD" "$SUT" | head -1 | cut -d: -f1)
L_LOG=$(grep -n -F -x 'if [ "$op" = "logscrub" ]; then' "$SUT" | head -1 | cut -d: -f1)
L_GUARD=$(grep -n -F -x "$GUARD" "$SUT" | head -1 | cut -d: -f1)
[ -n "$L_LOG" ] && [ -n "$L_GUARD" ] || { echo "EXTRACTION FAILED: the logscrub arm or the arg guard not found" >&2; exit 2; }
if [ "$L_ARM" -gt "$L_LOG" ] && [ "$L_ARM" -lt "$L_GUARD" ]; then ok "the arm sits after logscrub and before the name/uid guard"
else no "the arm is at line $L_ARM; it must be after logscrub ($L_LOG) and before the guard ($L_GUARD)"; fi

# Count it once: a second arm would be dead code that reads like a second copy of the rule.
[ "$(grep -c -F -x "$ARM_HEAD" "$SUT")" = 1 ] && ok "exactly one userdirrecheck arm" || no "more than one userdirrecheck arm"

# NWP-20261123-26: userdir_recheck itself, re-rooted (/data/nowhere/ only: the ledger line it may write).
UDR=$(awk 'index($0,"userdir_recheck() {")==1{on=1} on{print} on&&/^}$/{exit}' "$SUT")
case "$UDR" in *': > "$_f.tmp"'*'mv -f "$_f.tmp" "$_f"'*) ;; *) echo "EXTRACTION FAILED: userdir_recheck's .tmp write or its mv moved in $SUT" >&2; exit 2 ;; esac
UDR=${UDR//\/data\/nowhere\//\$ROOT\/data\/nowhere\/}
# udr <sh> <case> <plant yes|no>: the list 11 (on record) and 12 (not), userdir_recheck once, then a sentinel line.
udr() { local sh="$1" c="$2" o=
  mkdir -p "$c/state" "$c/data/nowhere"; printf '11\n12\n' > "$c/state/userdir-pending"; cp "$c/state/userdir-pending" "$c/before"
  echo 11 > "$c/onrecord"
  [ "$3" = yes ] && { mkdir "$c/state/userdir-pending.tmp"; : > "$c/state/userdir-pending.tmp/entry"; }
  { printf "ROOT='%s'; STATE='%s/state'; LOG='%s/log'; uid=''\n" "$c" "$c" "$c"
    printf 'userdir_has_record() { [ "$1" = 0 ] && return 0; grep -qx -- "$1" "$ROOT/onrecord"; }\n'
    printf 'reap_userdir_take() { :; }\n%s\nuserdir_recheck; echo "rc=$?" > "$ROOT/after"\n' "$UDR"
  } > "$c/udr.sh"
  [ "${sh##*/}" = bash ] && o=--posix
  "$sh" $o "$c/udr.sh" >/dev/null 2>&1
}
# udr2 <sh> <case> <a|b|c|d|e> (NWP-20261126-18): the list 11, 12 (both on record) and 13 (clears), so two lines are kept.
# a: userdir-pending.tmp is a symlink to /dev/full, so the truncation succeeds and every append fails (ENOSPC).
# b: an echo function drops the kept line `12 left` and writes every other line, so the temp is one line short.
# c, d, e: a wc function stands in for the count reader. c prints the right count and exits 1 (a failed read), d
# prints `2x` (not a number), e prints `      2` (a padded count, as BSD wc does: the control, the list is rewritten).
# The chmod function refuses a symlink: code that chmods the temp unchecked would otherwise chmod /dev/full as root.
udr2() { local sh="$1" c="$2" o=
  mkdir -p "$c/state" "$c/data/nowhere"
  if [ "$3" = a ]; then printf '11\n12\n13\n' > "$c/state/userdir-pending"; ln -s /dev/full "$c/state/userdir-pending.tmp"
  else printf '11\n12 left\n13\n' > "$c/state/userdir-pending"; fi
  printf '11\n12\n' > "$c/onrecord"; cp "$c/state/userdir-pending" "$c/before"
  { printf "ROOT='%s'; STATE='%s/state'; LOG='%s/log'; uid=''\n" "$c" "$c" "$c"
    printf 'chmod() { local a; for a in "$@"; do [ -L "$a" ] && return 1; done; command chmod "$@"; }\n'
    [ "$3" = b ] && printf 'echo() { [ "$*" = "12 left" ] && return 0; command echo "$@"; }\n'
    [ "$3" = c ] && printf 'wc() { printf "2\\n"; return 1; }\n'
    [ "$3" = d ] && printf 'wc() { printf "2x\\n"; }\n'
    [ "$3" = e ] && printf 'wc() { printf "      2\\n"; }\n'
    printf 'userdir_has_record() { [ "$1" = 0 ] && return 0; grep -qx -- "$1" "$ROOT/onrecord"; }\n'
    printf 'reap_userdir_take() { :; }\n%s\nuserdir_recheck; echo "rc=$?" > "$ROOT/after"\n' "$UDR"
  } > "$c/udr.sh"
  [ "${sh##*/}" = bash ] && o=--posix
  "$sh" $o "$c/udr.sh" >/dev/null 2>&1
}
# kept <case> <label>: the list is a regular file (checked BEFORE any read: on unchecked code the /dev/full symlink is
# moved over it, and a read of it never ends), then a bounded read of it equals the original lines.
kept() { local c="$1" t="$2"
  if [ -f "$c/state/userdir-pending" ] && [ ! -L "$c/state/userdir-pending" ]; then
    ok "$t the list is still a regular file"
    head -c 4096 "$c/state/userdir-pending" > "$c/got"
    cmp -s "$c/before" "$c/got" && ok "$t the list holds its original lines byte for byte" || no "$t the list is '$(cat "$c/got")', want it unchanged"
  else
    no "$t the list is not a regular file (the temp was moved over it)"
  fi
}

for sh in "${SHELLS[@]}"; do
  # U1/U2 (NWP-20261123-26): userdir_recheck with an unwritable .tmp keeps the list; the control rewrites it.
  tag="[${sh##*/}]"
  C=$(mktemp -d -p "$W"); udr "$sh" "$C" yes
  [ -d "$C/state/userdir-pending.tmp" ] && ok "$tag U1 the plant is still a directory" || no "$tag U1 the plant is gone"
  chmod -R u+rwx "$C"
  [ "$(cat "$C/after" 2>/dev/null)" = rc=0 ] && ok "$tag U1 an unwritable .tmp: userdir_recheck returns 0 and the next line runs (bash as --posix)" \
    || no "$tag U1 an unwritable .tmp: after the call '$(cat "$C/after" 2>/dev/null)', want rc=0"
  cmp -s "$C/before" "$C/state/userdir-pending" && ok "$tag U1 the pending list is kept byte for byte, not emptied" \
    || no "$tag U1 the pending list is '$(cat "$C/state/userdir-pending" 2>/dev/null)', want it unchanged"
  C=$(mktemp -d -p "$W"); udr "$sh" "$C" no
  [ "$(cat "$C/after" 2>/dev/null)|$(cat "$C/state/userdir-pending" 2>/dev/null)" = "rc=0|11" ] && [ ! -e "$C/state/userdir-pending.tmp" ] \
    && ok "$tag U2 control, writable: the list is rewritten to 11 alone" \
    || no "$tag U2 control: after '$(cat "$C/after" 2>/dev/null)', list '$(cat "$C/state/userdir-pending" 2>/dev/null)'"
  # A/B (NWP-20261126-18): a temp that took none, or not all, of its lines never replaces the list.
  WANT='userdir recheck: the pending list could not be rewritten'
  if [ -c /dev/full ]; then
    C=$(mktemp -d -p "$W"); udr2 "$sh" "$C" a
    kept "$C" "$tag A a temp that takes no writes (/dev/full):"
    lg=$(cat "$C/log" 2>/dev/null)
    case "$lg" in *"$WANT (- of 2 lines) -- kept unchanged (NWP-20261126-18) "*) ok "$tag A the log line says (- of 2 lines)" ;;
      *) no "$tag A log: '$lg'" ;; esac
    [ ! -e "$C/state/userdir-pending.tmp" ] && [ ! -L "$C/state/userdir-pending.tmp" ] && ok "$tag A the temp is removed" || no "$tag A the temp is still there"
    [ "$(cat "$C/after" 2>/dev/null)" = rc=0 ] && ok "$tag A userdir_recheck returns 0" || no "$tag A after the call '$(cat "$C/after" 2>/dev/null)'"
    rm -f "$C/state/userdir-pending.tmp" "$C/state/userdir-pending"
  else
    printf '  SKIP  %s A: no /dev/full on this host\n' "$tag"
  fi
  C=$(mktemp -d -p "$W"); udr2 "$sh" "$C" b
  kept "$C" "$tag B a temp one line short:"
  lg=$(cat "$C/log" 2>/dev/null)
  case "$lg" in *"$WANT (1 of 2 lines) -- kept unchanged (NWP-20261126-18) "*) ok "$tag B the log line says (1 of 2 lines)" ;;
    *) no "$tag B log: '$lg'" ;; esac
  [ ! -e "$C/state/userdir-pending.tmp" ] && ok "$tag B the temp is removed" || no "$tag B the temp is still there"
  for k in c d; do
    K=$(printf '%s' "$k" | tr cd CD); what="the count reader exits 1 after it prints 2"; [ "$k" = d ] && what="the count reader prints 2x"
    C=$(mktemp -d -p "$W"); udr2 "$sh" "$C" "$k"
    kept "$C" "$tag $K $what:"
    lg=$(cat "$C/log" 2>/dev/null)
    case "$lg" in *"$WANT (- of 2 lines) -- kept unchanged (NWP-20261126-18) "*) ok "$tag $K the log line says (- of 2 lines)" ;;
      *) no "$tag $K log: '$lg'" ;; esac
    [ ! -e "$C/state/userdir-pending.tmp" ] && ok "$tag $K the temp is removed" || no "$tag $K the temp is still there"
  done
  C=$(mktemp -d -p "$W"); udr2 "$sh" "$C" e
  [ "$(cat "$C/after" 2>/dev/null)|$(cat "$C/state/userdir-pending" 2>/dev/null | tr '\n' ' ')" = "rc=0|11 12 left " ] && [ ! -e "$C/state/userdir-pending.tmp" ] \
    && [ ! -e "$C/log" ] && ok "$tag E control, a padded count: the list is rewritten to 11 and '12 left', no log line" \
    || no "$tag E control: after '$(cat "$C/after" 2>/dev/null)', list '$(cat "$C/state/userdir-pending" 2>/dev/null)', log '$(cat "$C/log" 2>/dev/null)'"
  for lane in rw ro; do
    tag="[${sh##*/} $lane]"
    C=$(mktemp -d -p "$W")
    {
      printf 'umask 022\nop=userdirrecheck; name=x; uid=0; LANE=%s; RES=%s/res\n' "$lane" "$C"
      printf 'userdir_recheck() { echo "called:$#" >> %s/calls; }\n' "$C"
      printf '%s\n' "$ARM"
      printf 'echo FELL-THROUGH > %s/res\n' "$C"
    } > "$C/arm.sh"
    "$sh" "$C/arm.sh" >/dev/null 2>&1; rc=$?
    [ "$rc" = 0 ] && ok "$tag exits 0" || no "$tag exit status $rc"
    [ "$(cat "$C/res" 2>/dev/null)" = OK ] && ok "$tag RES is OK" || no "$tag RES is '$(cat "$C/res" 2>/dev/null)'"
    mode=$(stat -c %a "$C/res" 2>/dev/null)
    [ "$mode" = 600 ] && ok "$tag RES is mode 600" || no "$tag RES mode is '$mode'"
    if [ "$lane" = rw ]; then
      [ "$(cat "$C/calls" 2>/dev/null)" = "called:0" ] && ok "$tag userdir_recheck called exactly once" \
        || no "$tag userdir_recheck calls: '$(cat "$C/calls" 2>/dev/null)'"
    else
      [ ! -e "$C/calls" ] && ok "$tag userdir_recheck not called" || no "$tag userdir_recheck called on the read-only lane"
    fi
  done
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite under each shell) =="
  # mutate <label> <file-producing command...>: one copy per mutant, the suite once per shell, each of which must fail
  mutate(){ local lbl="$1" m s; shift; m=$(mktemp -d -p "$W")
    if ! "$@" > "$m/m" 2>"$m/err"; then no "MUTATION BROKEN: $lbl: $(cat "$m/err")"; rm -rf "$m"; return; fi
    if cmp -s "$SUT" "$m/m"; then no "MUTATION INERT: $lbl"; rm -rf "$m"; return; fi
    for s in "${SHELLS[@]}"; do
      USERDIRRECHECK_SHELLS="$s" bash "$0" "$m/m" >/dev/null 2>&1
      if [ $? -eq 0 ]; then no "NOT CONVICTED under ${s##*/}: $lbl -- suite passes on broken code"; else ok "convicted under ${s##*/}: $lbl"; fi
    done
    rm -rf "$m"
  }
  RANGE='/^if \[ "\$op" = "userdirrecheck" \]; then$/,/^fi$/'
  # O4 moves the arm after the arg guard: the arm is written out once, then spliced in below the guard line
  o4(){ printf '%s\n' "$ARM" > "$W/o4.arm"
    awk -v h="$ARM_HEAD" -v armf="$W/o4.arm" -v g="$GUARD" '
      skip { if ($0 == "fi") skip = 0; next }
      $0 == h { skip = 1; next }
      { print }
      $0 == g { while ((getline l < armf) > 0) print l }' "$SUT"; }
  mutate "O1: the LANE guard removed" sed "$RANGE s/^  \[ \"\\\$LANE\" = rw \] && userdir_recheck\$/  userdir_recheck/" "$SUT"
  mutate "O2: the userdir_recheck call removed" sed "$RANGE s/^  \[ \"\\\$LANE\" = rw \] && userdir_recheck\$/  :/" "$SUT"
  mutate "O3: the chmod removed" sed "$RANGE s/^  chmod 600 \"\\\$RES\"; exit 0\$/  exit 0/" "$SUT"
  mutate "O4: the arm moved after the name/uid guard" o4
  mutate "U-m: userdir_recheck's .tmp write is bare" sed '/^userdir_recheck() {$/,/^}$/ s/^  ( : > "\$_f\.tmp" )$/  : > "$_f.tmp"/' "$SUT"
  U='/^userdir_recheck() {$/,/^}$/'
  mutate "U-c1: the whole check removed (mv always)" sed "$U s/^    if \[ \"\\\$_got\" = \"\\\$_n\" \]; then\$/    if :; then/" "$SUT"
  mutate "U-c2: only the count comparison removed" sed "$U s/^    if \[ \"\\\$_got\" = \"\\\$_n\" \]; then\$/    if [ \"\$_got\" != - ]; then/" "$SUT"
  mutate "U-c3: the count compared with a constant" sed "$U s/^    if \[ \"\\\$_got\" = \"\\\$_n\" \]; then\$/    if [ \"\$_got\" = 1 ]; then/" "$SUT"
  mutate "U-c5: the count reader's exit status ignored" sed "$U s/^      _got=\$(wc -l 2>\/dev\/null < \"\\\$_f\\.tmp\") || _got=-\$/      _got=\$(wc -l 2>\/dev\/null < \"\$_f.tmp\")/" "$SUT"
  mutate "U-c6: the number check removed" sed "$U s/; case \"\\\$_got\" in ''|\*\[!0-9\]\*) _got=- ;; esac\$//" "$SUT"
  mutate "U-c7: the padding strip removed" sed "$U s/^      _got=\\\${_got#\"\\\${_got%%\[! \]\*}\"}; /      /" "$SUT"
  mutate "U-c4: the mismatch arm removes the list" sed "$U s/^      rm -f \"\\\$_f\\.tmp\" 2>\/dev\/null\$/      rm -f \"\$_f\" \"\$_f.tmp\" 2>\/dev\/null/" "$SUT"
fi

echo
echo "shells: ${SHELLS[*]}; $PASS ok, $FAIL failed"
[ "$FAIL" = 0 ]
