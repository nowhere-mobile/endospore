#!/usr/bin/env bash
# test-pkg-live-pids.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's pkg_live_pids, executed (NWP-20261110-16).
#
# WHY THIS IS COMMITTED. silence-alarm and odrestore's hold path force-stop an app `--user "$uid"` and then ask whether
# it is still running. They used to ask `pidof "$pkg"`, which matches a process NAME, and an app's processes carry the
# same name in every Android user: a user-0 copy of the same clock app read as the session's app still running, so
# Dismiss at the cold-locked gate answered ERR-LIVE ("NOT silenced") when the session's clock had stopped. The check
# now goes through pkg_live_pids <pkg> <uid>, which keeps only the pids whose REAL uid / 100000 is <uid>, and fails
# closed (prints the pid) when the status cannot be read or has no numeric Uid line.
#
# The helper is extracted BY NAME (`pkg_live_pids() {` to the first `}` in column 0), its `/proc/` is rewritten to a
# fake root under this suite's temp dir, `pidof` is stubbed per case, and every case runs under bash, sh, dash and
# mksh where present (mksh is the device's /system/bin/sh). A case passes only on rc 0, the exact stdout AND an empty
# stderr: a quiet helper is part of the contract.
#
# Mutant -> convicting cases: M1 L2/L3; M2 L1; M3 L4; M4 L5/L9; M5 L8/L8b. L9 (the pid's dir exists, its status file
# does not) is M3's GUARD case, not a second flip: its dir exists, so deleting the -d test cannot change its output.
# What it pins, with no mutant applied, is the path L4 walks under M3 (a failed open: pid printed, stderr empty,
# rc 0); if that path ever broke on some shell, L9 fails the control run first.
#
#   bash test-pkg-live-pids.sh            # the cases
#   bash test-pkg-live-pids.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

SHELLS=""
for s in bash sh dash mksh; do
  if command -v "$s" >/dev/null 2>&1; then SHELLS="$SHELLS $s"; else echo "  skip  shell $s not installed"; fi
done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

ext() { sed -n '/^pkg_live_pids() {$/,/^}$/p' "$1"; }

# status <fakeproc> <pid> <real> <eff>: a /proc/<pid>/status shaped like the kernel's.
status() {
  mkdir -p "$1/$2"
  printf 'Name:\tclock\nUmask:\t0077\nState:\tS (sleeping)\nTgid:\t%s\nUid:\t%s\t%s\t%s\t%s\nGid:\t%s\t%s\t%s\t%s\n' \
    "$2" "$3" "$4" "$4" "$4" "$3" "$3" "$3" "$3" > "$1/$2/status"
}

suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 H sh w d out rc err
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  H=$(ext "$f")
  case "$H" in *'pidof "$1"'*'/proc/'*'/proc/'*) ;; *) no "EXTRACTION FAILED -- pkg_live_pids() missing or reshaped in $f"; return 2 ;; esac
  case "$H" in *'$(cat "/proc/'*'<<PLP_EOF'*) ;; *) no "EXTRACTION FAILED -- pkg_live_pids no longer reads the status through \$(cat ...) and a here-doc in $f"; return 2 ;; esac
  bash -n <<<"$H" 2>/dev/null || { no "EXTRACTION FAILED -- pkg_live_pids does not parse in $f"; return 2; }

  # one <shell> <tag> <ask user> <pidof output> <want stdout> <setup fn>: run the helper over a fresh fake /proc.
  one() {
    local sh="$1" tag="$2" ask="$3" po="$4" want="$5" setup="$6" d fp
    d=$(mktemp -d -p "$W"); fp="$d/proc"; mkdir -p "$fp"
    "$setup" "$fp"
    {
      sed "s#/proc/#$fp/#g" <<<"$H"
      echo 'pidof(){ [ -n "$PIDOF_OUT" ] && echo "$PIDOF_OUT"; return 0; }'
      echo 'pkg_live_pids com.example.clock "$ASK"'
    } > "$d/run.sh"
    case "$(cat "$d/run.sh")" in *' /proc/'*|*'"/proc/'*) no "[$sh] $tag: /proc/ not rewritten"; rm -rf "$d"; return ;; esac
    if ! "$sh" -n "$d/run.sh" 2>/dev/null; then no "[$sh] $tag: the extracted helper does not parse under $sh"; rm -rf "$d"; return; fi
    out=$(ASK="$ask" PIDOF_OUT="$po" TMPDIR="$W" "$sh" "$d/run.sh" 2>"$d/err" </dev/null); rc=$?
    err=$(cat "$d/err")
    if [ "$rc" = 0 ] && [ "$out" = "$want" ] && [ -z "$err" ]; then ok "[$sh] $tag"
    else no "[$sh] $tag (rc=$rc stdout='$out' want='$want' stderr='$err')"; fi
    rm -rf "$d"
  }
  s_l1(){ status "$1" 101 1010123 1010123; }
  s_l2(){ status "$1" 102 10045 10045; }
  s_l3(){ status "$1" 201 10045 10045; status "$1" 202 1010045 1010045; status "$1" 203 1110045 1110045; }
  s_none(){ :; }
  s_l5(){ mkdir -p "$1/401"; printf 'Name:\tclock\nState:\tS (sleeping)\n' > "$1/401/status"; }
  s_l6(){ status "$1" 501 1099001 1099001; }
  s_l8(){ status "$1" 601 10045 1010045; }
  s_l8b(){ status "$1" 601 1010045 10045; }
  s_l9(){ mkdir -p "$1/701"; }
  for sh in $SHELLS; do
    one "$sh" "L1 uid 1010123, asked for user 10 -> printed" 10 101 101 s_l1
    one "$sh" "L2 uid 10045 (user 0), asked for user 10 -> nothing" 10 102 "" s_l2
    one "$sh" "L3 pids of users 0, 10 and 11 -> only the user-10 pid" 10 "201 202 203" 202 s_l3
    one "$sh" "L4 /proc/<pid> absent (gone) -> nothing" 10 301 "" s_none
    one "$sh" "L5 status with no Uid line -> printed (fail closed)" 10 401 401 s_l5
    one "$sh" "L6 isolated uid 1099001, asked for user 10 -> printed" 10 501 501 s_l6
    one "$sh" "L7 pidof prints nothing -> nothing" 10 "" "" s_none
    one "$sh" "L8 real uid user 0, effective user 10 -> nothing (judged by the real uid)" 10 601 "" s_l8
    one "$sh" "L8b real uid user 10, effective user 0 -> printed (judged by the real uid)" 10 601 601 s_l8b
    one "$sh" "L9 status cannot be opened -> printed, quietly (fail closed)" 10 701 701 s_l9
  done
  [ -n "$quiet" ] || { echo "  info  shells: $SHELLS"; echo "$p passed, $x failed"; }
  [ "$x" = 0 ]
}

if [ "$MUTATE" = no ]; then suite "$SUT"; exit $?; fi

suite "$SUT" quiet || { echo "CONTROL FAILED -- the unmutated script does not pass"; suite "$SUT"; exit 1; }
echo "control: passes"
T=$(mktemp -d -p "$W")
bad=0
# mutate <name> <sed-expr>: the copy must DIFFER from the original, the suite must then FAIL (rc 1; an extraction or
# parse failure, rc 2, is NOT a conviction), and every shell found must print its own FAIL line.
mutate() {
  local n="$1" e="$2" m="$T/m.sh" rc res nb="" t
  sed -e "$e" "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then echo "  MUTANT DID NOT APPLY  $n"; bad=1; return; fi
  res=$(suite "$m"); rc=$?
  for t in $SHELLS; do
    case "$res" in *"  FAIL  [$t]"*) ;; *) nb="$nb $t" ;; esac
  done
  if [ "$rc" = 1 ] && [ -z "$nb" ]; then echo "  convicted  $n"; else echo "  NOT CONVICTED (rc=$rc, no FAIL line under:${nb:- none})  $n"; bad=1; fi
}
PL='/^pkg_live_pids() {$/,/^}$/'
mutate "M1 the user filter dropped (every pid printed)" "$PL"'s#\[ "\$((_r / 100000))" = "\$2" \] || continue#:#'
mutate "M2 % 100000 in place of / 100000" "$PL"'s#_r / 100000#_r % 100000#'
mutate "M3 an absent /proc dir counted live" "$PL"'s#\[ -d "/proc/\$_p" \] || continue#[ -d "/proc/$_p" ] || :#'
mutate "M4 an unreadable status counted gone" "$PL"'s#""|\*\[!0-9\]\*) _out="\$_out \$_p"; continue;;#""|*[!0-9]*) continue;;#'
mutate "M5 the effective uid field read instead of the real one" "$PL"'s#read -r _k _r _e _rest#read -r _k _e _r _rest#'
[ "$bad" = 0 ] && echo "all mutants convicted" || { echo "MUTATION RUN FAILED"; exit 1; }
