#!/usr/bin/env bash
# test-reap-retry.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's reap retry: reap_retry_add, reap_retry_run and their
# three call lines (NWP-20261114-15, decision #67, dn-1111 #5).
#
# WHY. A reap whose rm of /data/misc_de/<uid> (or another FBE tree, or an extra_user_paths entry) failed once answered
# ERR-REAP-RESIDUE, wrote one reap-ledger row, and nothing looked at the path again: the departed session's directory
# stayed until the next boot, which may be days away. Decision #67: the next three read-write-lane ops retry it, path
# for path, never users/<uid> (userdir_recheck's), and the ledger gets ONE row when it clears (class=retried) or when it
# gives up (class=gaveup). The issue report's per-class counts are the only escalation.
#
# The four functions are EXTRACTED from nowhere_roamd.sh by their `<fn>() {` anchor to their closing `}` (exit 2 if one
# is absent), re-rooted to a temp tree, and run under every shell the runner has (bash, sh, dash, mksh;
# REAPRETRY_SHELLS=<paths> restricts the list). An unremovable path is made by an `rm` shell function that refuses an
# argument naming, or holding, the marker directory nwp-refuse-rm -- never by chmod, since CI may run as root. The
# cleanstorage add line and the top-level call line are taken from the file BY POSITION and executed as written.
#
# NWP-20261123-26: R1 meets reap_retry_run's `( : > "$_f.tmp" )` with a target that cannot be written:
# $STATE/reap-pending.tmp is a DIRECTORY with one entry (a redirection onto a directory fails for any user, root
# included). Every append to it fails too (echo is not a special builtin), and the final `mv -f` cannot move a directory
# over the list: the list is KEPT byte for byte and the function returns 0. That branch is safe (the list is not lost,
# the op does not end), so no code changed: R1 pins it, under every shell, bash as --posix, and mutant M10 (the write
# made bare: the function ends there) is convicted. roamd runs `chmod 600` on the plant, which takes its x bit, so R1
# restores it before it reads the case dir, and the EXIT trap does so too.
#
# NWP-20261126-18: a temp that was CREATED but took none, or not all, of its lines replaced the list. A and B queue
# `11 0` and `12 0` (on record, kept) and `13 0` (clears). A plants reap-pending.tmp as a symlink to /dev/full: the
# truncation succeeds and every append fails (ENOSPC), for any user. B defines an echo function that drops the kept
# line `12 0`, so the temp is one line short. In both the list must stay a regular file with its original bytes, the
# temp must go, and roam.log gets `(- of 2 lines)` or `(1 of 2 lines)`. The list is read only after `[ ! -L ]` and
# only with `head -c 4096`: unchecked code moves the symlink over it, and a read of /dev/full never ends. A chmod
# function refuses a symlink, so unchecked code cannot chmod /dev/full as root. Without /dev/full, A prints SKIP.
# Mutants M11..M14 remove the check, drop only the count comparison, compare with a constant, or remove the list.
# C and D (review RF-001) replace the count reader with a wc function: C prints the right count and exits 1, D prints
# `2x`. Both must keep the list and log `(- of 2 lines)`. E prints a padded `      2` and is the control: the list is
# rewritten. Mutants M15..M17 ignore the reader's exit status, drop the number check, or drop the padding strip.
#
#   bash test-reap-retry.sh               # the checks
#   bash test-reap-retry.sh --mutate      # ... plus mutants that must each CONVICT the suite under each shell
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
if [ -n "${REAPRETRY_SHELLS:-}" ]; then
  read -r -a SHELLS <<< "$REAPRETRY_SHELLS"
else
  seen=" "
  for s in bash sh dash mksh; do
    p=$(command -v "$s" 2>/dev/null) || continue
    r="$(readlink -f "$p"):$s"   # sh stays apart from bash: bash run as sh is its POSIX mode
    case "$seen" in *" $r "*) continue ;; esac
    seen="$seen$r "; SHELLS+=("$p")
  done
fi

# --- extraction --------------------------------------------------------------------------------------------------
fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
reroot() { printf '%s\n' "$1" | sed -E 's#([" ])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

FUNCS=""
for fn in reap_retry_add reap_retry_run userdir_has_record extra_user_paths; do
  t=$(fn_of "$SUT" "$fn")
  [ -n "$t" ] || { echo "EXTRACTION FAILED: function $fn not found in $SUT" >&2; exit 2; }
  FUNCS="$FUNCS$t"$'\n'
done
RF=$(reroot "$FUNCS")
n=$(nleft "$RF")
[ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: the functions keep $n absolute /data path(s) in live code" >&2; exit 2; }
printf '%s\n' "$RF" > "$W/funcs.sh"

ADD_AFTER='  [ -n "$_reapres" ] && _reapclass=residue'
ADDL=$(awk -v a="$ADD_AFTER" 'p {print; exit} $0 == a {p=1}' "$SUT")
case "$ADDL" in *reap_retry_add*) ;; *) ADDL=: ;; esac
RADDL=$(reroot "$ADDL")
TOPL=$(awk '$0 == "[ \"$LANE\" = rw ] && userdir_recheck" {print prev; exit} {prev=$0}' "$SUT")
case "$TOPL" in '#'*|'') TOPL=: ;; *reap_retry_run*) ;; *) TOPL=: ;; esac

# --- the harness -------------------------------------------------------------------------------------------------
# newcase: a fake root with user 0 on record, the tmpfs $STATE and /data/nowhere.
newcase() { local c; c=$(mktemp -d -p "$W") || return 1
  mkdir -p "$c/state" "$c/data/nowhere" "$c/data/system/users"; : > "$c/data/system/users/0.xml"; printf '%s\n' "$c"; }
plant() { mkdir -p "$(dirname "$1")"; printf 'x' > "$1"; }
# run <sh> <case> <own uid> <body>: the body over the re-rooted functions, umask 022, stdout to out, stderr to err.
run() { local sh="$1" c="$2" own="$3" body="$4"
  { printf "set -u; umask 022; ROOT='%s'; STATE=\"\$ROOT/state\"; LOG=\"\$ROOT/roam.log\"; uid='%s'\n" "$c" "$own"
    cat <<'EOS'
rm() {
  local a
  for a in "$@"; do
    case "$a" in -*) continue ;; *nwp-refuse-rm*) return 1 ;; esac
    [ -e "$a/nwp-refuse-rm" ] && return 1
  done
  command rm "$@"
}
EOS
    printf '. %s/funcs.sh\n%s\n' "$W" "$body"
  } > "$c/run.sh"
  "$sh" ${RUN_OPT:-} "$c/run.sh" >> "$c/out" 2>> "$c/err"
}
# harn <case>: the run hit no undefined command, unbound variable or parse error.
harn() { local e; e=$(grep -m1 -iE 'command not found|: (inaccessible or )?not found|unbound variable|parameter not set|syntax error|bad substitution' "$1/err" 2>/dev/null); [ -z "$e" ]; }
lines() { if [ -f "$1" ]; then grep -c '' "$1"; else echo 0; fi; }
list() { cat "$1/state/reap-pending" 2>/dev/null; }
ledger() { cat "$1/data/nowhere/reap-ledger" 2>/dev/null; }
mode() { stat -c %a "$1" 2>/dev/null; }

for sh in "${SHELLS[@]}"; do
  tag="[${sh##*/}]"

  # C1 a residue uid clears on the first run
  C=$(newcase); echo "11 0" > "$C/state/reap-pending"; chmod 600 "$C/state/reap-pending"; plant "$C/data/misc_de/11/f"
  run "$sh" "$C" "" reap_retry_run
  l=$(ledger "$C")
  [ ! -e "$C/data/misc_de/11" ] && ok "$tag C1 the residue dir is removed" || no "$tag C1 misc_de/11 still there"
  [ "$(lines "$C/data/nowhere/reap-ledger")" = 1 ] && [[ "$l" =~ ^[0-9]+\ uid=11\ class=retried\ tries=1$ ]] && ok "$tag C1 one class=retried tries=1 row" || no "$tag C1 ledger: '$l'"
  [ ! -e "$C/state/reap-pending" ] && [ ! -e "$C/state/reap-pending.tmp" ] && ok "$tag C1 the list is gone" || no "$tag C1 list: '$(list "$C")'"
  lg=$(cat "$C/roam.log" 2>/dev/null)
  [ "$(lines "$C/roam.log")" = 1 ] && [[ "$lg" == *"reap retry user 11 cleared tries=1"* ]] && ok "$tag C1 one roam.log line" || no "$tag C1 log: '$lg'"
  harn "$C" && ok "$tag C1 clean stderr" || no "$tag C1 stderr: $(cat "$C/err")"

  # C2 an unremovable survivor: kept after runs 1 and 2 with no row, gives up on run 3 with one row
  C=$(newcase); echo "11 0" > "$C/state/reap-pending"; plant "$C/data/misc_de/11/nwp-refuse-rm/x"
  run "$sh" "$C" "" reap_retry_run
  [ "$(list "$C")" = "11 1" ] && [ ! -e "$C/data/nowhere/reap-ledger" ] && ok "$tag C2 run 1: kept as '11 1', no row" || no "$tag C2 run 1 list '$(list "$C")' ledger '$(ledger "$C")'"
  [ "$(mode "$C/state/reap-pending")" = 600 ] && ok "$tag C2 a kept list is mode 600" || no "$tag C2 list mode $(mode "$C/state/reap-pending")"
  run "$sh" "$C" "" reap_retry_run
  [ "$(list "$C")" = "11 2" ] && [ ! -e "$C/data/nowhere/reap-ledger" ] && ok "$tag C2 run 2: kept as '11 2', no row" || no "$tag C2 run 2 list '$(list "$C")' ledger '$(ledger "$C")'"
  run "$sh" "$C" "" reap_retry_run
  l=$(ledger "$C")
  [ ! -e "$C/state/reap-pending" ] && ok "$tag C2 run 3: the uid is dropped" || no "$tag C2 run 3 list '$(list "$C")'"
  [ "$(lines "$C/data/nowhere/reap-ledger")" = 1 ] && [[ "$l" =~ ^[0-9]+\ uid=11\ class=gaveup\ tries=3\ survives:\ $C/data/misc_de/11$ ]] \
    && ok "$tag C2 run 3: one class=gaveup tries=3 row naming the survivor" || no "$tag C2 ledger: '$l'"
  [ "$(mode "$C/data/nowhere/reap-ledger")" = 600 ] && ok "$tag C2 the ledger is mode 600" || no "$tag C2 ledger mode $(mode "$C/data/nowhere/reap-ledger")"
  lg=$(cat "$C/roam.log" 2>/dev/null)
  [ "$(lines "$C/roam.log")" = 3 ] && [[ "$lg" != *"/data/"* ]] && [[ "$lg" == *"GAVE UP tries=3"* ]] && ok "$tag C2 three roam.log lines, uid only" || no "$tag C2 log: '$lg'"
  [ -d "$C/data/misc_de/11" ] && ok "$tag C2 control: the survivor is still there" || no "$tag C2 control: misc_de/11 is gone"
  harn "$C" && ok "$tag C2 clean stderr" || no "$tag C2 stderr: $(cat "$C/err")"

  # C3 a survivor that clears on run 2
  C=$(newcase); echo "11 0" > "$C/state/reap-pending"; plant "$C/data/misc_de/11/nwp-refuse-rm/x"
  run "$sh" "$C" "" reap_retry_run
  command rm -rf "$C/data/misc_de/11/nwp-refuse-rm"
  run "$sh" "$C" "" reap_retry_run
  l=$(ledger "$C")
  [ "$(lines "$C/data/nowhere/reap-ledger")" = 1 ] && [[ "$l" =~ ^[0-9]+\ uid=11\ class=retried\ tries=2$ ]] && [ ! -e "$C/state/reap-pending" ] \
    && ok "$tag C3 a later clear: one class=retried tries=2 row" || no "$tag C3 ledger '$l' list '$(list "$C")'"

  # C4 a uid on record is skipped, its count unchanged (.backup alone counts as a record)
  C=$(newcase); echo "11 1" > "$C/state/reap-pending"; plant "$C/data/misc_de/11/f"; : > "$C/data/system/users/11.xml.backup"
  run "$sh" "$C" "" reap_retry_run
  [ -e "$C/data/misc_de/11/f" ] && [ "$(list "$C")" = "11 1" ] && [ ! -e "$C/data/nowhere/reap-ledger" ] \
    && ok "$tag C4 a uid on record is skipped, count unchanged" || no "$tag C4 dir $( [ -e "$C/data/misc_de/11/f" ] && echo kept || echo GONE ), list '$(list "$C")', ledger '$(ledger "$C")'"

  # C5 user 0's record unseen: nothing changes
  C=$(newcase); command rm -f "$C/data/system/users/0.xml"; printf '11 0\n12 2\n' > "$C/state/reap-pending"; cp "$C/state/reap-pending" "$C/before"
  plant "$C/data/misc_de/11/f"; plant "$C/data/user/12/f"
  run "$sh" "$C" "" reap_retry_run
  cmp -s "$C/before" "$C/state/reap-pending" && [ -e "$C/data/misc_de/11/f" ] && [ -e "$C/data/user/12/f" ] && [ ! -e "$C/data/nowhere/reap-ledger" ] \
    && [ ! -e "$C/roam.log" ] && [ ! -e "$C/state/reap-pending.tmp" ] && ok "$tag C5 user 0 unseen: list, dirs, ledger and log unchanged" || no "$tag C5 list '$(list "$C")' ledger '$(ledger "$C")'"

  # C6 the op's own uid is skipped
  C=$(newcase); echo "11 0" > "$C/state/reap-pending"; plant "$C/data/misc_de/11/f"
  run "$sh" "$C" 11 reap_retry_run
  [ -e "$C/data/misc_de/11/f" ] && [ "$(list "$C")" = "11 0" ] && [ ! -e "$C/data/nowhere/reap-ledger" ] \
    && ok "$tag C6 the op's own uid is skipped" || no "$tag C6 list '$(list "$C")' ledger '$(ledger "$C")'"

  # C7 an empty users/<uid> survives every run (it is userdir_recheck's)
  C=$(newcase); mkdir -p "$C/data/system/users/11"; good=1
  for i in 1 2 3; do
    echo "11 0" > "$C/state/reap-pending"; plant "$C/data/misc_de/11/f"
    run "$sh" "$C" "" reap_retry_run
    [ -d "$C/data/system/users/11" ] && [ ! -e "$C/data/misc_de/11" ] || good=0
  done
  [ "$good" = 1 ] && ok "$tag C7 users/11 survives three runs while misc_de/11 is removed" || no "$tag C7 users/11 $( [ -d "$C/data/system/users/11" ] && echo kept || echo REMOVED )"

  # C8 no list: no output, no ledger, no log
  C=$(newcase); plant "$C/data/misc_de/11/f"
  run "$sh" "$C" "" reap_retry_run
  [ ! -s "$C/out" ] && [ ! -s "$C/err" ] && [ ! -e "$C/data/nowhere/reap-ledger" ] && [ ! -e "$C/roam.log" ] && [ ! -e "$C/state/reap-pending" ] \
    && [ -e "$C/data/misc_de/11/f" ] && ok "$tag C8 no list: nothing written, nothing removed" || no "$tag C8 out '$(cat "$C/out")' err '$(cat "$C/err")'"

  # C9 add: digits only, >= 10, no leading zero, de-duplicated, newest 32 kept
  C=$(newcase)
  run "$sh" "$C" "" "reap_retry_add ''; reap_retry_add abc; reap_retry_add 9; reap_retry_add 012; reap_retry_add 1x; reap_retry_add -11"
  [ ! -e "$C/state/reap-pending" ] && ok "$tag C9 '', abc, 9, 012, 1x, -11 queue nothing" || no "$tag C9 list '$(list "$C")'"
  run "$sh" "$C" "" "reap_retry_add 11; reap_retry_add 11"
  [ "$(list "$C")" = "11 0" ] && ok "$tag C9 11 twice -> one '11 0' line" || no "$tag C9 list '$(list "$C")'"
  [ "$(mode "$C/state/reap-pending")" = 600 ] && [ ! -e "$C/state/reap-pending.tmp" ] && ok "$tag C10 the added list is mode 600, no .tmp left" || no "$tag C10 mode $(mode "$C/state/reap-pending")"
  echo "11 2" > "$C/state/reap-pending"
  run "$sh" "$C" "" "reap_retry_add 11"
  [ "$(list "$C")" = "11 2" ] && ok "$tag C9 a listed uid keeps its count" || no "$tag C9 list '$(list "$C")'"
  C=$(newcase)
  run "$sh" "$C" "" 'i=10; while [ "$i" -le 49 ]; do reap_retry_add "$i"; i=$((i + 1)); done'
  [ "$(lines "$C/state/reap-pending")" = 32 ] && [ "$(head -n1 "$C/state/reap-pending")" = "18 0" ] && [ "$(tail -n1 "$C/state/reap-pending")" = "49 0" ] \
    && ok "$tag C9 40 uids -> the newest 32 (18..49)" || no "$tag C9 $(lines "$C/state/reap-pending") lines, first '$(head -n1 "$C/state/reap-pending")'"
  harn "$C" && ok "$tag C9 clean stderr" || no "$tag C9 stderr: $(cat "$C/err")"

  # C11 an extra_user_paths survivor, resumed at count 2: the give-up row names it
  C=$(newcase); echo "11 2" > "$C/state/reap-pending"; plant "$C/data/backup/11/nwp-refuse-rm/x"; plant "$C/data/misc/user/11/f"
  run "$sh" "$C" "" reap_retry_run
  l=$(ledger "$C")
  [[ "$l" =~ ^[0-9]+\ uid=11\ class=gaveup\ tries=3\ survives:\ $C/data/backup/11$ ]] && [ ! -e "$C/data/misc/user/11" ] && [ ! -e "$C/state/reap-pending" ] \
    && ok "$tag C11 an extra path: removed, or named in the give-up row" || no "$tag C11 ledger '$l'"

  # C12 bad lines: a non-digit or < 10 uid is dropped, a bad count reads as 0; two uids judged apart
  C=$(newcase); printf 'abc 0\n5 0\n11 x\n12 1\n' > "$C/state/reap-pending"; plant "$C/data/misc_de/11/nwp-refuse-rm/x"; plant "$C/data/user_de/12/f"
  run "$sh" "$C" "" reap_retry_run
  l=$(ledger "$C")
  [ "$(list "$C")" = "11 1" ] && [[ "$l" =~ ^[0-9]+\ uid=12\ class=retried\ tries=2$ ]] && ok "$tag C12 bad lines dropped, '11 x' read as 0, 12 cleared" || no "$tag C12 list '$(list "$C")' ledger '$l'"
  harn "$C" && ok "$tag C12 clean stderr" || no "$tag C12 stderr: $(cat "$C/err")"

  # R1 (NWP-20261123-26): an unwritable .tmp (a directory with one entry): the list is kept and the function returns
  C=$(newcase); printf '11 0\n12 0\n' > "$C/state/reap-pending"; cp "$C/state/reap-pending" "$C/before"
  mkdir "$C/state/reap-pending.tmp"; : > "$C/state/reap-pending.tmp/entry"
  : > "$C/data/system/users/11.xml.backup"; plant "$C/data/misc_de/12/f"
  o=; [ "${sh##*/}" = bash ] && o=--posix
  RUN_OPT=$o run "$sh" "$C" "" 'reap_retry_run; echo "rc=$?" > "$ROOT/after"'
  [ -d "$C/state/reap-pending.tmp" ] && ok "$tag R1 the plant is still a directory" || no "$tag R1 the plant is gone"
  chmod -R u+rwx "$C"
  [ "$(cat "$C/after" 2>/dev/null)" = rc=0 ] && ok "$tag R1 an unwritable .tmp: reap_retry_run returns 0 and the next line runs (bash as --posix)" \
    || no "$tag R1 an unwritable .tmp: after the call '$(cat "$C/after" 2>/dev/null)', want rc=0"
  cmp -s "$C/before" "$C/state/reap-pending" && ok "$tag R1 the pending list is kept byte for byte, not emptied" \
    || no "$tag R1 the pending list is '$(list "$C")', want it unchanged"

  # A/B (NWP-20261126-18): a temp that took none, or not all, of its lines never replaces the list. 11 and 12 are on
  # record (kept), 13 clears. The chmod function refuses a symlink: code that chmods the temp unchecked would
  # otherwise chmod /dev/full as root. The list is read only after it is proven a regular file, and only bounded.
  WANT='reap retry: the pending list could not be rewritten'
  CHMODW='chmod() { local a; for a in "$@"; do [ -L "$a" ] && return 1; done; command chmod "$@"; }'
  o=; [ "${sh##*/}" = bash ] && o=--posix
  for k in a b c d; do
    if [ "$k" = a ] && [ ! -c /dev/full ]; then printf '  SKIP  %s A: no /dev/full on this host\n' "$tag"; continue; fi
    K=$(printf '%s' "$k" | tr abcd ABCD)
    C=$(newcase); printf '11 0\n12 0\n13 0\n' > "$C/state/reap-pending"; cp "$C/state/reap-pending" "$C/before"
    : > "$C/data/system/users/11.xml.backup"; : > "$C/data/system/users/12.xml.backup"; plant "$C/data/misc_de/13/f"
    if [ "$k" = a ]; then
      ln -s /dev/full "$C/state/reap-pending.tmp"; body="$CHMODW"; want="(- of 2 lines)"; what="a temp that takes no writes (/dev/full)"
    elif [ "$k" = b ]; then
      body="$CHMODW
echo() { [ \"\$*\" = \"12 0\" ] && return 0; command echo \"\$@\"; }"; want="(1 of 2 lines)"; what="a temp one line short"
    elif [ "$k" = c ]; then
      body="$CHMODW
wc() { printf '2\\n'; return 1; }"; want="(- of 2 lines)"; what="the count reader exits 1 after it prints 2"
    else
      body="$CHMODW
wc() { printf '2x\\n'; }"; want="(- of 2 lines)"; what="the count reader prints 2x"
    fi
    RUN_OPT=$o run "$sh" "$C" "" "$body
reap_retry_run; echo \"rc=\$?\" > \"\$ROOT/after\""
    if [ -f "$C/state/reap-pending" ] && [ ! -L "$C/state/reap-pending" ]; then
      ok "$tag $K $what: the list is still a regular file"
      head -c 4096 "$C/state/reap-pending" > "$C/got"
      cmp -s "$C/before" "$C/got" && ok "$tag $K the list holds its original lines byte for byte" || no "$tag $K the list is '$(cat "$C/got")', want it unchanged"
    else
      no "$tag $K $what: the list is not a regular file (the temp was moved over it)"
    fi
    lg=$(cat "$C/roam.log" 2>/dev/null)
    case "$lg" in *"$WANT $want -- kept unchanged (NWP-20261126-18) "*) ok "$tag $K the log line says $want" ;; *) no "$tag $K log: '$lg'" ;; esac
    [ ! -e "$C/state/reap-pending.tmp" ] && [ ! -L "$C/state/reap-pending.tmp" ] && ok "$tag $K the temp is removed" || no "$tag $K the temp is still there"
    [ "$(cat "$C/after" 2>/dev/null)" = rc=0 ] && ok "$tag $K reap_retry_run returns 0" || no "$tag $K after the call '$(cat "$C/after" 2>/dev/null)'"
    harn "$C" && ok "$tag $K clean stderr" || no "$tag $K stderr: $(cat "$C/err")"
    command rm -f "$C/state/reap-pending.tmp" "$C/state/reap-pending"
  done
  # E (review RF-001), the control: a padded count, as BSD wc prints it, is a number, so the list is rewritten.
  C=$(newcase); printf '11 0\n12 0\n13 0\n' > "$C/state/reap-pending"
  : > "$C/data/system/users/11.xml.backup"; : > "$C/data/system/users/12.xml.backup"; plant "$C/data/misc_de/13/f"
  RUN_OPT=$o run "$sh" "$C" "" "wc() { printf '      2\\n'; }
reap_retry_run; echo \"rc=\$?\" > \"\$ROOT/after\""
  lg=$(cat "$C/roam.log" 2>/dev/null)
  [ "$(cat "$C/after" 2>/dev/null)|$(list "$C" | tr '\n' ' ')" = "rc=0|11 0 12 0 " ] && [ ! -e "$C/state/reap-pending.tmp" ] \
    && [[ "$lg" != *"$WANT"* ]] && ok "$tag E control, a padded count: the list is rewritten to '11 0' and '12 0', no mismatch line" \
    || no "$tag E control: after '$(cat "$C/after" 2>/dev/null)', list '$(list "$C")', log '$lg'"

  # E1 cleanstorage's add line, as written in the file
  for e in "residue| \$ROOT/data/system/users/11||" "residue| \$ROOT/data/misc_de/11||11 0" "husk||\$ROOT/data/vendor_de/11|11 0" \
           "residue| \$ROOT/data/system/users/11| \$ROOT/data/misc_de/11|11 0" "clean|||"; do
    IFS='|' read -r cl rs hk want <<< "$e"
    C=$(newcase)
    run "$sh" "$C" 11 "_reapclass=$cl; _reapres=\"$rs\"; _reaphusk=\"$hk\"; _p=\"\"
$RADDL"
    [ "$(list "$C")" = "$want" ] && ok "$tag E1 the add line: class=$cl res='$rs' husk='$hk' -> '$want'" || no "$tag E1 class=$cl res='$rs' husk='$hk': list '$(list "$C")', want '$want'"
  done

  # E2 the top-level line, as written in the file: the read-write lane only
  for e in ro: cred: rw:1; do
    C=$(newcase)
    run "$sh" "$C" 11 "LANE=${e%%:*}; reap_retry_run() { echo call >> \"\$ROOT/calls\"; }
$TOPL"
    [ "$(lines "$C/calls")" = "$( [ -n "${e#*:}" ] && echo 1 || echo 0 )" ] && ok "$tag E2 LANE=${e%%:*}: $(lines "$C/calls") call(s)" || no "$tag E2 LANE=${e%%:*}: $(lines "$C/calls") call(s)"
  done
done

# --- source pins -------------------------------------------------------------------------------------------------
ln_op=$(grep -n '^if \[ "\$op" = "cleanstorage" \]; then$' "$SUT" | head -1 | cut -d: -f1)
n=0
for fn in reap_retry_add reap_retry_run; do
  t=$(grep -n "^$fn() {\$" "$SUT" | head -1 | cut -d: -f1)
  [ -n "$t" ] && [ "$t" -lt "${ln_op:-0}" ] && n=$((n + 1))
done
[ "$n" = 2 ] && ok "P1 both helpers are defined above the cleanstorage dispatch" || no "P1 $n of 2 helpers above the dispatch"
case "$ADDL" in
  '  case "$_reapclass" in residue|husk) '*'[ "$_p" = "/data/system/users/$uid" ] || { reap_retry_add "$uid"; break; }'*) ok "P2 the line after _reapclass=residue queues the uid, users/<uid> excluded" ;;
  *) no "P2 the line after _reapclass=residue: '$ADDL'" ;;
esac
t=$(awk '/^if \[ "\$op" = "cleanstorage" \]; then$/ {c=1} c && p {print; exit} c && /^  userdir_recheck   #/ {p=1}' "$SUT")
[ "$t" = '  reap_retry_run   # NWP-20261114-15 (#67)' ] && ok "P3 cleanstorage calls reap_retry_run on the line after its userdir_recheck" || no "P3 the line after cleanstorage's userdir_recheck: '$t'"
t=$(awk 'prev != "" && $0 == "case \"$op\" in" {print prev; exit} {prev=$0}' "$SUT")
[ "$TOPL" = '[ "$LANE" = rw ] && reap_retry_run' ] && [ "$t" = '[ "$LANE" = rw ] && userdir_recheck' ] \
  && ok "P4 the guarded top-level call is directly above [ \"\$LANE\" = rw ] && userdir_recheck, which is directly above case \"\$op\" in" || no "P4 above userdir_recheck: '$TOPL'; above case: '$t'"
n=$(grep -v '^[[:space:]]*#' "$SUT" | grep -cE '(^|[;&|{] *|^ *)reap_retry_run( |$)')
m=$(grep -v '^[[:space:]]*#' "$SUT" | grep -c 'reap_retry_add "\$uid"')
[ "$n" = 2 ] && [ "$m" = 1 ] && ok "P5 reap_retry_run is called twice and reap_retry_add once" || no "P5 $n reap_retry_run call(s), $m reap_retry_add call(s)"
t=$(sed -n '/^if \[ "\$op" = "userdirrecheck" \]; then$/,/^fi$/p' "$SUT" | grep -c reap_retry)
[ "$t" = 0 ] && ok "P5 the userdirrecheck op does not call it" || no "P5 the userdirrecheck op names reap_retry $t time(s)"

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite under each shell) =="
  mutate(){ local lbl="$1" m s; shift; m=$(mktemp -d -p "$W")
    if ! "$@" > "$m/m" 2>"$m/err"; then no "MUTATION BROKEN: $lbl: $(cat "$m/err")"; rm -rf "$m"; return; fi
    if cmp -s "$SUT" "$m/m"; then no "MUTATION INERT: $lbl"; rm -rf "$m"; return; fi
    for s in "${SHELLS[@]}"; do
      REAPRETRY_SHELLS="$s" bash "$0" "$m/m" >/dev/null 2>&1
      if [ $? -eq 0 ]; then no "NOT CONVICTED under ${s##*/}: $lbl -- suite passes on broken code"; else ok "convicted under ${s##*/}: $lbl"; fi
    done
    rm -rf "$m"
  }
  H='/^reap_retry_run() {$/,/^}$/'
  A='/^reap_retry_add() {$/,/^}$/'
  mutate "M1: the record guard removed" sed "$H s/ || userdir_has_record \"\$_u\"; then/; then/" "$SUT"
  mutate "M2: the user-0 guard removed" sed "$H s/^  userdir_has_record 0 || return 0$/  :/" "$SUT"
  mutate "M3: users/<uid> added to the rm list" sed "$H s/^\(    for _d in system_ce .* vendor_de\); do$/\1 system\/users; do/" "$SUT"
  mutate "M4: the cap 3 -> 4" sed "$H s/\"\$_t\" -lt 3/\"\$_t\" -lt 4/" "$SUT"
  mutate "M5: a row on every failed try" sed "$H s|^      echo \"\$_u \$_t\" >> \"\$_f.tmp\"; _n=\$((_n + 1))\$|&; echo \"\$(date +%s) uid=\$_u class=gaveup tries=\$_t\" >> /data/nowhere/reap-ledger|" "$SUT"
  mutate "M6: the own-uid skip removed" sed "$H s/if \[ \"\$_u\" = \"\${uid:-}\" \] || /if /" "$SUT"
  mutate "M7: the add's dedup removed" sed "$A { /grep -qE/d; }" "$SUT"
  mutate "M8: the users/<uid>-only exclusion removed" sed 's@\[ "\$_p" = "/data/system/users/\$uid" \] || { reap_retry_add@{ reap_retry_add@' "$SUT"
  mutate "M9: the LANE guard removed" sed 's/^\[ "\$LANE" = rw \] && reap_retry_run$/reap_retry_run/' "$SUT"
  mutate "M10: reap_retry_run's .tmp write is bare" sed "$H s/^  ( : > \"\\\$_f\\.tmp\" )\$/  : > \"\$_f.tmp\"/" "$SUT"
  mutate "M11: the whole check removed (mv always)" sed "$H s/^    if \[ \"\\\$_got\" = \"\\\$_n\" \]; then\$/    if :; then/" "$SUT"
  mutate "M12: only the count comparison removed" sed "$H s/^    if \[ \"\\\$_got\" = \"\\\$_n\" \]; then\$/    if [ \"\$_got\" != - ]; then/" "$SUT"
  mutate "M13: the count compared with a constant" sed "$H s/^    if \[ \"\\\$_got\" = \"\\\$_n\" \]; then\$/    if [ \"\$_got\" = 1 ]; then/" "$SUT"
  mutate "M15: the count reader's exit status ignored" sed "$H s/^      _got=\$(wc -l 2>\/dev\/null < \"\\\$_f\\.tmp\") || _got=-\$/      _got=\$(wc -l 2>\/dev\/null < \"\$_f.tmp\")/" "$SUT"
  mutate "M16: the number check removed" sed "$H s/; case \"\\\$_got\" in ''|\*\[!0-9\]\*) _got=- ;; esac\$//" "$SUT"
  mutate "M17: the padding strip removed" sed "$H s/^      _got=\\\${_got#\"\\\${_got%%\[! \]\*}\"}; /      /" "$SUT"
  mutate "M14: the mismatch arm removes the list" sed "$H s/^      rm -f \"\\\$_f\\.tmp\" 2>\/dev\/null\$/      rm -f \"\$_f\" \"\$_f.tmp\" 2>\/dev\/null/" "$SUT"
fi

echo
echo "shells: ${SHELLS[*]}; $PASS ok, $FAIL failed"
[ "$FAIL" = 0 ]
