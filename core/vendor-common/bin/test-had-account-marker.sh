#!/usr/bin/env bash
# test-had-account-marker.sh [<nowhere_roamd.sh>] [--mutate] -- the #743 marker's arming rule.
#
# WHY THIS IS COMMITTED. The #743 logoff guard refuses to seal a row-empty accounts db over a head that
# holds a real account -- the right call: a wrong refusal costs one repeated sign-in, a wrong acceptance
# costs the account permanently. It fires only on a TRANSITION, and .had_account is what says the profile
# "arrived WITH an account". That marker was written on FILE PLACEMENT, and AMS creates accounts_ce.db at
# unlock -- so a profile that never held an account still placed a valid, row-empty db, still got marked,
# and then had #sys refused on EVERY logoff forever. Device-observed on lynx 2026-09-03 (throwaway
# odcamp1, no Google account ever): `accounts placed ce=yes`, then `REFUSED -- ZERO account rows but this
# profile arrived WITH an account` and `PARTIAL: sys=refused`, repeating.
#
# The guard's own comment already promised the behaviour this restores -- "A profile that never had one
# still seals its row-empty db exactly as before" -- so what is pinned here is that the marker can actually
# TELL the two cases apart, and that UNKNOWN still marks (guard armed). That asymmetry is the whole design.
#
# NWP-20261104-05 (#743, dn-1025 #2): the same block also writes the ARRIVAL RECORD -- the row count and one mark
# hash per Google account -- to the user's CE dir. Pinned here, under every shell found: the hashes equal ones the
# suite computes on the host, the file is mode 600 and never under $STATE, every outcome but a confirmed positive
# count removes a stale record, `.had_account` is untouched, and the log carries counts only (no name, no hash).
#
# NWP-20261118-09: acct_reload sets pcs=yes (and pce=no) when the CE copy lands short. That is a doubt, so the block
# must ARM .had_account and remove any arrival record, under every shell found; with pcs unset or no, pce=no still
# clears the marker as before.
#
# NWP-20261121-14: the three `( : > "$STATE/.had_account" )` writes (the unknown-count, positive-count and short-copy
# arms) are subshells so a target that cannot be written cannot end roamd under mksh. Pinned here, under every shell
# found (bash as `bash --posix`): with .had_account planted as a DIRECTORY, each arm runs past its write, and its next
# statements and log line follow.
#
# NWP-20261123-19: acct_seal reads the marker with `-e`, so the directory left there keeps the #743 guard ARMED: pinned
# here by running acct_seal itself on a row-empty capture, which it refuses as it does with a real marker. A marker that
# cannot be created at all (a dangling symlink into a directory that does not exist: `-e` is false and the write fails,
# even as root) cannot arm the guard, so each of the three arms logs `could NOT write .had_account -- the #743 guard is
# DISARMED this session` instead of its armed or marking line. Both pinned under every shell found (bash as --posix).
#
#   bash test-had-account-marker.sh            # the truth table
#   bash test-had-account-marker.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# Pure logic -- no device, no db. The row-count tool is stubbed, which is the point: every branch runs.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# Every shell found runs the arrival-record cases (the device's /system/bin/sh is mksh; dash and bash differ from it
# in what `print`, `local` and `[ x -lt N ]` do), de-duplicated by the file they resolve to.
SHELLS=()
seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$p")
done

# --- extraction: the marker block, by anchor -------------------------------------------------------------
BLOCK=$(sed -n '/^  # NWP-20260903-14: PLACEMENT IS NOT POSSESSION/,/^  fi$/p' "$SUT")
case "$BLOCK" in
  *'_prows'*'.had_account'*) ;;
  *) echo "EXTRACTION FAILED -- anchors moved in $SUT" >&2; exit 2 ;;
esac
# The helpers the block calls, lifted by name (never copied) so they cannot drift from the script.
LIFT=""
for fn in qn acct_mark_hashes; do
  body=$(sed -n "/^$fn() {\$/,/^}\$/p" "$SUT")
  [ -n "$body" ] || { echo "EXTRACTION FAILED -- $fn() not found in $SUT" >&2; exit 2; }
  LIFT="$LIFT$body"$'\n'
done
# mksh has the real `print`; every other shell gets a shim that supports -r, -n and --.
PRINT_SHIM='case "${KSH_VERSION:-}" in *MIRBSD*) ;; *) print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; } ;; esac'

# --- harness ---------------------------------------------------------------------------------------------
# Run the block with a stubbed tool, in the shell $SH. The stub answers per verb: accounts-count prints $T/count,
# accounts-google prints $T/google and exits $T/grc. `count` is a number it echoes, "junk", or "missing" to remove
# the tool entirely (the pre-#743 device, and any build without nowhere_db_fix).
# setup <pce> <count> [preexisting-marker] [google-output] [google-rc] [stale-arrival]  -> sets T and runs the block
SH=bash
PCS=no   # NWP-20261118-09: the short-copy flag setup writes beside pce; only the short-copy cases set it to yes
PLANT=   # NWP-20261121-14: dir plants .had_account as a directory (with one entry), a target that cannot be written;
         # NWP-20261123-19: dangling plants it as a symlink into a directory that does not exist (nothing can be created)
POSIX=   # NWP-20261121-14: yes runs bash as `bash --posix`, where a bare `: >` that fails ends the shell
setup(){
  local pce="$1" tool="$2" pre="${3:-}" goo="${4-}" grc="${5:-0}" stale="${6:-}" body
  T=$(mktemp -d -p "$W")
  mkdir -p "$T/state" "$T/bin" "$T/data/system_ce/9"
  : > "$T/data/system_ce/9/accounts_ce.db"
  [ -n "$pre" ] && : > "$T/state/.had_account"
  [ "$PLANT" = dir ] && { mkdir -p "$T/state/.had_account"; : > "$T/state/.had_account/x"; }
  [ "$PLANT" = dangling ] && ln -s "$T/nonexistent/x" "$T/state/.had_account"
  [ -n "$stale" ] && echo stale > "$T/data/system_ce/9/nowhere-acct-arrival"
  printf '%s\n' "$tool" > "$T/count"
  if [ -n "$goo" ]; then printf '%b' "$goo" > "$T/google"; else printf '%s\n' "$tool" > "$T/google"; fi
  printf '%s\n' "$grc" > "$T/grc"
  if [ "$tool" != missing ]; then
    printf '#!/usr/bin/env bash\ncase "$1" in\n accounts-count) cat "%s/count" ;;\n accounts-google) cat "%s/google"; exit "$(cat "%s/grc")" ;;\n *) exit 2 ;;\nesac\n' "$T" "$T" "$T" > "$T/bin/nowhere_db_fix"
    chmod +x "$T/bin/nowhere_db_fix"
  fi
  # Only the absolute tool path and the CE root are rewritten; the logic under test is untouched.
  body=$(printf '%s\n' "$BLOCK" \
        | sed "s#/system/bin/nowhere_db_fix#$T/bin/nowhere_db_fix#g" \
        | sed "s#/data/system_ce/#$T/data/system_ce/#g")
  {
    echo "$PRINT_SHIM"
    printf '%s\n' "$LIFT"
    echo "STATE='$T/state'; LOG='$T/log'; uid=9; name=probe; pce='$pce'; pcs='$PCS'"
    echo "$body"
    echo "echo REACHED > '$T/reached'"
  } > "$T/run.sh"
  if [ "$POSIX" = yes ] && [ "${SH##*/}" = bash ]; then "$SH" --posix "$T/run.sh" >/dev/null 2>&1
  else "$SH" "$T/run.sh" >/dev/null 2>&1; fi
}
run(){   # run <pce> <tool> [preexisting-marker]  -> "present" | "absent"
  setup "$1" "$2" "${3:-}"
  if [ -f "$T/state/.had_account" ]; then echo present; else echo absent; fi
}
is(){ local got; got=$(run "$2" "$3" "${4:-}")
      [ "$got" = "$1" ] && ok "$5" || no "$5 -- marker $got, want $1"; }

echo "== the fix: a placed but ROW-EMPTY db must not claim an account =="
is absent  yes 0   ""    "count 0 -> marker NOT written (an account-less profile can seal #sys)"
is absent  yes 0   pre   "count 0 -> a STALE marker is cleared (the profile has no account now)"

echo "== a real account still arms the guard =="
is present yes 1   ""    "count 1 -> marker written"
is present yes 7   ""    "count 7 -> marker written"

echo "== UNKNOWN marks: only a CONFIRMED zero disarms =="
is present yes junk    "" "unreadable count -> marker written anyway (guard stays armed)"
is present yes -1      "" "tool reports -1 (no accounts table) -> marker written anyway"
is present yes missing "" "tool ABSENT -> marker written anyway (pre-#743 builds keep the old protection)"

echo "== no CE db placed at all is unchanged =="
is absent  no  1   ""    "pce=no -> marker cleared, whatever the tool would say"
is absent  no  1   pre   "pce=no -> a stale marker is cleared"

echo "== NWP-20261104-05: the arrival record (count + mark hashes) in the user's CE dir =="
# The reference hashes come from the HOST's printf + sha256sum, never from roamd's own helper.
href(){ printf 'nowhere-acct-mark-v1:%s' "$1" | sha256sum | cut -d' ' -f1; }
N1="alpha.planted@gmail.com"; N2="zeta.planted@gmail.com"
H1=$(href "$N1"); H2=$(href "$N2")
for SH in "${SHELLS[@]}"; do
  t="[$(basename "$SH")]"
  one_status() { # <label> <expected tail>: exactly one count-only arrival status line in the log (RF-001)
    local _n _l
    _n=$(grep -c '#sys arrival record:' "$T/log" 2>/dev/null)
    _l=$(grep '#sys arrival record:' "$T/log" 2>/dev/null)
    [ "$_n" = 1 ] && case "$_l" in *"arrival record: $2"*) true ;; *) false ;; esac && ok "$1: exactly one arrival status line ($2)" || no "$1: arrival status lines [$_n]: $_l"
  }
  arr() { echo "$T/data/system_ce/9/nowhere-acct-arrival"; }
  setup yes 3 "" "3\n$N1\n$N2\n" 0
  got=$(cat "$(arr)" 2>/dev/null)
  [ "$got" = "$(printf '3\n%s\n%s' "$H1" "$H2")" ] && ok "$t count 3: the arrival file holds the count and the host-computed hashes" || no "$t count 3: arrival file is [$got]"
  mode=$(stat -c %a "$(arr)" 2>/dev/null)
  [ "$mode" = 600 ] && ok "$t the arrival file is mode 600" || no "$t the arrival file mode is [$mode]"
  strays=$(find "$T/state" -name 'nowhere-acct-arrival*' 2>/dev/null)
  [ -z "$strays" ] && ok "$t no arrival file under the tmpfs state dir" || no "$t arrival file under \$STATE: $strays"
  [ -f "$T/state/.had_account" ] && ok "$t .had_account is still written" || no "$t .had_account missing"
  [ ! -s "$T/state/.had_account" ] && ok "$t .had_account is still an empty flag" || no "$t .had_account holds bytes"
  lg=$(cat "$T/log" 2>/dev/null)
  case "$lg" in *"#sys arrival record: 3 row(s), 2 Google"*) ok "$t the log line carries the counts" ;; *) no "$t arrival log line missing: [$lg]" ;; esac
  case "$lg" in *"the #743 guard is DISARMED"*) no "$t count 3: a written marker logged DISARMED" ;; *) ok "$t count 3: a written marker logs no DISARMED line" ;; esac
  leak=no
  [ -n "$lg" ] || leak=EMPTY
  case "$lg" in *"$N1"*|*"$N2"*|*"$H1"*|*"$H2"*) leak=yes ;; esac
  [ "$leak" = no ] && ok "$t the log holds no planted name and no hash" || no "$t log leak check: $leak"

  setup yes 2 "" "2\n?\n" 0
  got=$(cat "$(arr)" 2>/dev/null)
  [ "$got" = "$(printf '2\n?')" ] && ok "$t a name the tool would not print stays ? in the record" || no "$t ? record is [$got]"

  setup yes 4 "" "4\n" 0
  got=$(cat "$(arr)" 2>/dev/null)
  [ "$got" = 4 ] && ok "$t no Google row: the record is the count alone" || no "$t count-only record is [$got]"

  setup yes 3 "" "-1\n" 6 stale
  [ ! -e "$(arr)" ] && ok "$t accounts-google exits 6: no arrival file (a stale one is removed)" || no "$t arrival file survived a failing accounts-google"
  [ -f "$T/state/.had_account" ] && ok "$t accounts-google failing: .had_account is still written" || no "$t .had_account missing after accounts-google failed"
  case "$(cat "$T/log" 2>/dev/null)" in *"#sys arrival record: unavailable"*) ok "$t the failure is logged as unavailable" ;; *) no "$t unavailable log line missing" ;; esac

  setup yes 3 "" "junk\n$N1\n" 0
  [ ! -e "$(arr)" ] && ok "$t rc 0 but a non-numeric first line: no arrival file" || no "$t arrival file written from a junk count"

  setup yes missing "" "" 0 stale
  [ ! -e "$(arr)" ] && ok "$t the tool absent: no arrival file (a stale one is removed)" || no "$t arrival file survived an absent tool"
  one_status "$t the tool absent" unavailable
  [ -f "$T/state/.had_account" ] && ok "$t the tool absent: .had_account is still written" || no "$t .had_account missing with the tool absent"

  setup yes 0 "" "0\n" 0 stale
  [ ! -e "$(arr)" ] && ok "$t count 0: a stale arrival file is removed" || no "$t arrival file survived a confirmed zero"
  one_status "$t count 0" unavailable
  setup yes junk "" "junk\n" 0 stale
  [ ! -e "$(arr)" ] && ok "$t unreadable count: a stale arrival file is removed" || no "$t arrival file survived an unreadable count"
  one_status "$t unreadable count" unavailable
  case "$(cat "$T/log" 2>/dev/null)" in *"the #743 guard is DISARMED"*) no "$t unreadable count: a written marker logged DISARMED" ;; *"the guard stays armed"*) ok "$t unreadable count: the armed line, no DISARMED line" ;; *) no "$t unreadable count: the armed line is missing" ;; esac
  setup no 3 "" "3\n$N1\n" 0 stale
  [ ! -e "$(arr)" ] && ok "$t pce=no: a stale arrival file is removed" || no "$t arrival file survived pce=no"
  one_status "$t pce=no" unavailable
done
SH=bash

echo "== NWP-20261118-09: a short CE copy (pcs=yes, pce=no) keeps the guard armed, in every shell =="
PCS=yes
for SH in "${SHELLS[@]}"; do
  t="[$(basename "$SH")]"
  setup no 0 "" "" 0 stale
  [ -f "$T/state/.had_account" ] && ok "$t short copy, no marker before: .had_account is written" || no "$t short copy, no marker before: .had_account is absent"
  [ ! -e "$(arr)" ] && ok "$t short copy: a stale arrival file is removed" || no "$t short copy: the arrival file survived"
  case "$(cat "$T/log" 2>/dev/null)" in *"#sys short CE copy -- marking .had_account"*) ok "$t short copy: the log has the short-copy line" ;; *) no "$t short copy: the short-copy log line is missing" ;; esac
  case "$(cat "$T/log" 2>/dev/null)" in *"the #743 guard is DISARMED"*) no "$t short copy: a written marker logged DISARMED" ;; *) ok "$t short copy: a written marker logs no DISARMED line" ;; esac
  one_status "$t short copy" unavailable
  setup no 1 pre
  [ -f "$T/state/.had_account" ] && ok "$t short copy, marker before: .had_account is kept" || no "$t short copy, marker before: .had_account was cleared"
  setup no missing
  [ -f "$T/state/.had_account" ] && ok "$t short copy, the tool absent: .had_account is written" || no "$t short copy, the tool absent: .had_account is absent"
done
PCS=no; SH=bash

echo "== NWP-20261121-14: a .had_account that cannot be written (a directory) does not end the op, in every shell (bash as --posix) =="
PLANT=dir; POSIX=yes
for SH in "${SHELLS[@]}"; do
  t="[$(basename "$SH")]"
  reached() { [ "$(cat "$T/reached" 2>/dev/null)" = REACHED ] && ok "$t $1: the block runs past the marker write" || no "$t $1: the block ended at the marker write (no REACHED)"; }
  notfile() { [ -d "$T/state/.had_account" ] && [ ! -f "$T/state/.had_account" ] && ok "$t $1: .had_account is still the planted directory (acct_seal's -e readers see it as armed)" || no "$t $1: .had_account is a regular file or gone"; }
  nodis() { case "$(cat "$T/log" 2>/dev/null)" in *"the #743 guard is DISARMED"*) no "$t $1: an entry exists at .had_account, but the log says DISARMED" ;; *) ok "$t $1: an entry exists at .had_account, no DISARMED line" ;; esac; }
  PCS=no
  setup yes junk "" "" 0 stale
  reached "unknown count"
  notfile "unknown count"
  nodis "unknown count"
  [ ! -e "$(arr)" ] && ok "$t unknown count: the next statement removes a stale arrival file" || no "$t unknown count: the arrival file survived"
  case "$(cat "$T/log" 2>/dev/null)" in *"marking .had_account anyway; the guard stays armed"*) ok "$t unknown count: the arm's log line follows" ;; *) no "$t unknown count: the arm's log line is missing" ;; esac
  setup yes 3 "" "3\n$N1\n$N2\n" 0
  reached "count 3"
  notfile "count 3"
  nodis "count 3"
  got=$(cat "$(arr)" 2>/dev/null)
  [ "$got" = "$(printf '3\n%s\n%s' "$H1" "$H2")" ] && ok "$t count 3: the next statements still write the arrival record" || no "$t count 3: arrival file is [$got]"
  case "$(cat "$T/log" 2>/dev/null)" in *"#sys arrival record: 3 row(s), 2 Google"*) ok "$t count 3: the arrival log line follows" ;; *) no "$t count 3: the arrival log line is missing" ;; esac
  PCS=yes
  setup no 0 "" "" 0 stale
  reached "short copy"
  notfile "short copy"
  nodis "short copy"
  [ ! -e "$(arr)" ] && ok "$t short copy: the next statement removes a stale arrival file" || no "$t short copy: the arrival file survived"
  case "$(cat "$T/log" 2>/dev/null)" in *"#sys short CE copy -- marking .had_account"*) ok "$t short copy: the arm's log line follows" ;; *) no "$t short copy: the arm's log line is missing" ;; esac
done
PLANT=; POSIX=; PCS=no; SH=bash

echo "== NWP-20261123-19: a .had_account that cannot be created logs DISARMED, in every shell (bash as --posix) =="
DISL='#sys could NOT write .had_account -- the #743 guard is DISARMED this session (NWP-20261123-19)'
PLANT=dangling; POSIX=yes
for SH in "${SHELLS[@]}"; do
  t="[$(basename "$SH")]"
  # disarmed <label> <armed text the arm must NOT log, or ""> : the checks every arm shares
  disarmed() {
    local lg n
    lg=$(cat "$T/log" 2>/dev/null)
    [ "$(cat "$T/reached" 2>/dev/null)" = REACHED ] && ok "$t $1: the block runs past the marker write" || no "$t $1: the block ended at the marker write (no REACHED)"
    [ ! -e "$T/state/.had_account" ] && ok "$t $1: nothing was created at .had_account" || no "$t $1: an entry exists at .had_account"
    n=$(grep -cF -- "$DISL" "$T/log" 2>/dev/null)
    [ "$n" = 1 ] && ok "$t $1: exactly one DISARMED line" || no "$t $1: DISARMED lines [$n]"
    if [ -n "$2" ]; then
      case "$lg" in *"$2"*) no "$t $1: the arm still logs '$2'" ;; *) ok "$t $1: the arm does not log '$2'" ;; esac
    fi
  }
  PCS=no
  setup yes junk "" "" 0 stale
  disarmed "unknown count" "the guard stays armed"
  [ ! -e "$(arr)" ] && ok "$t unknown count: a stale arrival file is still removed" || no "$t unknown count: the arrival file survived"
  one_status "$t unknown count (dangling)" unavailable
  setup yes 3 "" "3\n$N1\n$N2\n" 0
  disarmed "count 3" ""
  got=$(cat "$(arr)" 2>/dev/null)
  [ "$got" = "$(printf '3\n%s\n%s' "$H1" "$H2")" ] && ok "$t count 3: the arrival record is still written" || no "$t count 3: arrival file is [$got]"
  one_status "$t count 3 (dangling)" "3 row(s), 2 Google"
  PCS=yes
  setup no 0 "" "" 0 stale
  disarmed "short copy" "marking .had_account so"
  [ ! -e "$(arr)" ] && ok "$t short copy: a stale arrival file is still removed" || no "$t short copy: the arrival file survived"
  one_status "$t short copy (dangling)" unavailable
done
PLANT=; POSIX=; PCS=no; SH=bash

echo "== NWP-20261123-19: acct_seal reads a directory at .had_account as ARMED, in every shell =="
# acct_seal, acct_mark_file and acct_mark_hashes run whole (lifted by name, as test-had-account-refusal.sh does), with
# /data/ pointed at a temp root and nowhere_db_fix, `timeout` and $AGENT stubbed.
if [ -e /system/bin/nowhere_db_fix ] || [ -e /data/nowhere ]; then
  no "refusing to run the acct_seal cases: /system/bin/nowhere_db_fix or /data/nowhere exists on this host"
else
SFUNCS=""
for fn in acct_seal acct_mark_file acct_mark_hashes; do
  body=$(awk -v h="$fn() {" '$0 == h {f=1} f{print} f&&/^\}$/{exit}' "$SUT")
  case "$body" in "$fn() {"*'}') SFUNCS="$SFUNCS$body"$'\n' ;; *) echo "EXTRACTION FAILED: $fn -- not found by name in $SUT" >&2; exit 2 ;; esac
done
SFUNCS=$(printf '%s\n' "$SFUNCS" | sed 's#/system/bin/nowhere_db_fix#$T/bin/nowhere_db_fix#g; s#/data/#$T/data/#g')
QN=$(sed -n '/^qn() {$/,/^}$/p' "$SUT")
# sealcase <marker: dir|file|none> <count> <google-output> <arrival|-> : runs acct_seal 7 in a fresh $T, sets RC
sealcase() {
  T=$(mktemp -d -p "$W")
  mkdir -p "$T/data/system_ce/7" "$T/data/system_de/7" "$T/data/nowhere" "$T/state" "$T/bin" "$T/user/7/com.nowhere.chooser/files"
  printf 'CE' > "$T/data/system_ce/7/accounts_ce.db"; printf 'DE' > "$T/data/system_de/7/accounts_de.db"
  case "$1" in dir) mkdir -p "$T/state/.had_account" ;; file) : > "$T/state/.had_account" ;; esac
  printf '%s\n' "$2" > "$T/count"; printf '%b' "$3" > "$T/google"
  printf '#!/usr/bin/env bash\ncase "$1" in\n accounts-count) cat "%s/count" ;;\n accounts-google) cat "%s/google" ;;\n *) exit 2 ;;\nesac\n' "$T" "$T" > "$T/bin/nowhere_db_fix"
  chmod +x "$T/bin/nowhere_db_fix"
  [ "$4" = - ] || printf '%b' "$4" > "$T/data/system_ce/7/nowhere-acct-arrival"
  {
    echo "$PRINT_SHIM"
    printf '%s\n' "$QN"
    printf 'T=%s; STATE=$T/state; LOG=$T/log; ACCT_MARK_ROOT=$T/user; name=probe; pass=x\n' "$T"
    printf 'pw(){ echo x; }; timeout(){ shift 3; "$@"; }\n'
    printf 'agent_stub(){ echo "$*" >> "$T/calls"; return 0; }; AGENT=agent_stub\n'
    printf '%s\n' "$SFUNCS"
    printf 'acct_seal 7; echo "$?" > "$T/res"\n'
  } > "$T/seal.sh"
  : > "$T/calls"
  "$SH" "$T/seal.sh" >/dev/null 2>&1
  RC=$(cat "$T/res" 2>/dev/null)
}
NA="planted.seal@example.invalid"; HA=$(href "$NA")
for SH in "${SHELLS[@]}"; do
  t="[$(basename "$SH")]"
  for mk in dir file; do
    sealcase "$mk" 0 "0\n" -
    lg=$(cat "$T/log" 2>/dev/null); nc=$(grep -c . "$T/calls")
    [ "$RC" = 4 ] && [ "$nc" = 0 ] && ok "$t marker a $mk, row-empty capture: refused (rc 4, no push)" || no "$t marker a $mk, row-empty capture: rc [$RC], push calls $nc (want 4, 0)"
    case "$lg" in *"ZERO account rows"*"#743"*) ok "$t marker a $mk: the #743 refusal is logged" ;; *) no "$t marker a $mk: no #743 refusal in the log" ;; esac
  done
  sealcase none 0 "0\n" -
  [ "$RC" = 0 ] && ok "$t no marker, row-empty capture: seals (rc 0)" || no "$t no marker, row-empty capture: rc [$RC] want 0"
  sealcase dir 1 "1\n$NA\n" "2\nHX\nHY\n"
  got=$(cat "$T/data/system_ce/7/nowhere-acct-arrival" 2>/dev/null)
  [ "$RC" = 0 ] && [ "$got" = "$(printf '1\n%s' "$HA")" ] && ok "$t marker a directory, count 1: seals and the arrival record follows the head" || no "$t marker a directory, count 1: rc [$RC], arrival record [$got]"
done
SH=bash
fi

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$W")
  mutate(){
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$M/m.sh" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi
  }
  # The original defect, restored: mark whenever a file was placed.
  mutate "marks on placement again (the filed bug)" \
         's#^    \[ -x /system/bin/nowhere_db_fix \] && _prows=.*#    _prows=1#'
  # NOT MUTATED: deleting the explicit unknown case alone. It falls through to the catch-all, which also
  # marks -- identical behaviour, nothing to convict. That redundancy is deliberate: the explicit case
  # exists to LOG the unknown, and a silent fail-safe is how a #743-class bug hides. A mutation I cannot
  # convict is one I do not get to claim.
  #
  # The dangerous direction IS testable as "never marks at all": the guard then never arms, and a
  # row-empty capture can seal over a real account -- the loss #743 exists to prevent.
  mutate "the marker is never written (guard never arms; an account can be sealed over)" \
         's#: > "$STATE/.had_account"#rm -f "$STATE/.had_account"#'
  # An arrival-record mutant must fail the cases of EVERY shell found: a mksh-only or bash-only conviction would
  # leave the others unguarded. The child suite's output is captured (never `| grep -q` under pipefail).
  mutate_all(){
    local out sh t
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $1"; return; fi
    out=$(bash "$0" "$M/m.sh" 2>&1)
    for sh in "${SHELLS[@]}"; do
      t="[$(basename "$sh")]"
      case "$out" in
        *"  FAIL  $t "*) ok "convicted under $t: $1" ;;
        *) no "NOT CONVICTED under $t: $1" ;;
      esac
    done
  }
  mutate_all "the hash prefix changed" \
         's#print -rn -- "nowhere-acct-mark-v1:#print -rn -- "nowhere-acct-mark-v0:#'
  mutate_all "the failure arm writes a count-only record" \
         's#^            rm -f "\$_arr" 2>>"\$LOG"$#            print -r -- "$_prows" > "$_arr"#'
  mutate_all "the arrival file is written under the tmpfs state dir" \
         's#^  _arr="/data/system_ce/\$uid/nowhere-acct-arrival"$#  _arr="$STATE/nowhere-acct-arrival"#'
  mutate_all "an account name is echoed into the log" \
         '/^        _agl=\$(\[ -x \/system\/bin\/nowhere_db_fix \]/a\        print -r -- "$_agl" >> "$LOG"'
  mutate_all "the short-copy elif arm is deleted (a short copy clears .had_account)" \
         '/^  elif \[ "\$pcs" = yes \]; then$/,/^  else$/{/^  else$/!d}'
  mutate_all "the DE-only placement logs no arrival status" \
         '/^    rm -f "\$_arr" 2>>"\$LOG"$/{n;s#^    print -r -- .*#    :#;}'
  # NWP-20261121-14: one marker write inside acct_reload put back to the bare form, and nothing else. awk counts the
  # write's lines inside the function by indentation, and the mutant must change exactly one line.
  mutate_one(){
    local out sh t nd
    if ! awk -v want="$2" -v pick="$3" '
      /^acct_reload\(\) \{$/ { inf = 1 }
      inf && $0 == want { n++; if (n == pick) { sub(/\( : > "\$STATE\/\.had_account" \)/, ": > \"$STATE/.had_account\""); } }
      inf && /^}$/ { inf = 0 }
      { print }' "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (awk): $1"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $1"; return; fi
    nd=$(diff "$SUT" "$M/m.sh" | grep -c '^<')
    [ "$nd" = 1 ] || { no "MUTATION CHANGES $nd LINES: $1"; return; }
    out=$(bash "$0" "$M/m.sh" 2>&1)
    for sh in "${SHELLS[@]}"; do
      t="[$(basename "$sh")]"
      case "$out" in
        *"  FAIL  $t "*) ok "convicted under $t: $1" ;;
        *) no "NOT CONVICTED under $t: $1" ;;
      esac
    done
  }
  mutate_one "the unknown-count arm's marker write is bare again" '        ( : > "$STATE/.had_account" ) 2>>"$LOG"' 1
  mutate_one "the positive-count arm's marker write is bare again" '        ( : > "$STATE/.had_account" ) 2>>"$LOG"' 2
  mutate_one "the short-copy arm's marker write is bare again" '    ( : > "$STATE/.had_account" ) 2>>"$LOG"' 1

  # NWP-20261123-19: function-scoped mutants. The writer checks in acct_reload and the readers in acct_seal share their
  # text, so each mutant runs awk over the whole file, edits only inside the named function, and must change exactly
  # the number of diff lines it names (2 for a one-line replacement, 1 for one added line).
  # mutate_fn <desc> <diff-lines> <awk program>
  mutate_fn(){
    local out sh t nd
    if ! awk "$3" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (awk): $1"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $1"; return; fi
    nd=$(diff "$SUT" "$M/m.sh" | grep -c '^[<>]')
    [ "$nd" = "$2" ] || { no "MUTATION CHANGES $nd DIFF LINES (want $2): $1"; return; }
    out=$(bash "$0" "$M/m.sh" 2>&1)
    for sh in "${SHELLS[@]}"; do
      t="[$(basename "$sh")]"
      case "$out" in
        *"  FAIL  $t "*) ok "convicted under $t: $1" ;;
        *) no "NOT CONVICTED under $t: $1" ;;
      esac
    done
  }
  # reader <n>: the nth `[ -e "$STATE/.had_account" ]` reader in acct_seal back to -f
  reader='/^acct_seal\(\) \{$/ { f = 1 }
    f && /\[ -e "\$STATE\/\.had_account" \]/ { n++; if (n == N) sub(/\[ -e /, "[ -f ") }
    f && /^}$/ { f = 0 }
    { print }'
  mutate_fn "acct_seal's #743 guard reads the marker with -f again" 2 "BEGIN { N = 1 } $reader"
  mutate_fn "acct_seal's arrival-record reader reads the marker with -f again" 2 "BEGIN { N = 2 } $reader"
  # dropdis <n>: the nth DISARMED log in acct_reload becomes `:` (the else arm keeps a body, so the code still parses)
  dropdis='/^acct_reload\(\) \{$/ { f = 1 }
    f && /the #743 guard is DISARMED this session/ { n++; if (n == N) { match($0, /^ */); i = substr($0, 1, RLENGTH); $0 = i ":" } }
    f && /^}$/ { f = 0 }
    { print }'
  mutate_fn "the unknown-count arm logs no DISARMED line" 2 "BEGIN { N = 1 } $dropdis"
  mutate_fn "the positive-count arm logs no DISARMED line" 2 "BEGIN { N = 2 } $dropdis"
  mutate_fn "the short-copy arm logs no DISARMED line" 2 "BEGIN { N = 3 } $dropdis"
  # armed <key>: the arm's armed line is also logged before its `if [ -e ... ]`, so it is logged unconditionally
  armed='{ L[NR] = $0 }
    END { for (i = 1; i <= NR; i++) {
      if (L[i] == "acct_reload() {") f = 1
      if (f && i < NR && L[i] ~ /^ *if \[ -e "\$STATE\/\.had_account" \]; then$/ && index(L[i+1], K)) { x = L[i+1]; sub(/^  /, "", x); print x }
      print L[i]
      if (f && L[i] == "}") f = 0 } }'
  mutate_fn "the unknown-count arm logs 'the guard stays armed' unconditionally" 1 "BEGIN { K = \"the guard stays armed\" } $armed"
  mutate_fn "the short-copy arm logs its marking line unconditionally" 1 "BEGIN { K = \"marking .had_account so\" } $armed"
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
