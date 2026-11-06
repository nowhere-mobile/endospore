#!/usr/bin/env bash
# test-relabel-launcher.sh [<nowhere_roamd.sh>] [--mutate] -- relabel_launcher keeps the roamed home layout
# (NWP-20261128-44; backlog §H 'relabel_launcher, which keeps the roamed home layout, ran under no test').
#
# WHY THIS IS COMMITTED. Launcher3 keys every home and dock item to the user's serial (favorites.profileId). A new
# user gets a new serial at each sign-in, and a stale serial makes Launcher3 drop the whole layout. The in arm calls
# roamd's relabel_launcher right after the CE restore lands: it reads this user's serial from `dumpsys user` and runs
# `nowhere_db_fix launcher-relabel <db> <serial>`, then `launcher-widgets <db>` (#93). Every suite that reaches the
# in arm stubs it, so nothing ran its body, and a regression in any branch is silent on a device: the layout is
# just gone. The `:` after the uid in `UserInfo{$1:` is what keeps user 10 from reading user 100's serial (ids are
# not reused within a boot, so a long-running phone reaches three digits).
#
# This suite runs the REAL function (extracted by name, the binary re-rooted to a stub, `dumpsys` a shell-function
# stub that prints a scripted `dumpsys user` text) under every shell found. What the binary does to the database is
# test-nowhere-db-fix.sh's job.
#
#   bash test-relabel-launcher.sh              # the cases
#   bash test-relabel-launcher.sh --mutate     # ... plus mutants of roamd that must each CONVICT under every shell
#
# Pure logic -- no device. Exit 0 all pass, 1 a check failed, 2 the harness could not extract (never a pass).
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; -*) echo "usage: $0 [<nowhere_roamd.sh>] [--mutate]" >&2; exit 2 ;; *) SUT="$a" ;; esac; done
SELF="$0"
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# The function's binary path is re-rooted below; a host that has the real path would make a mis-rooted run look fine.
[ -e /system/bin/nowhere_db_fix ] && { echo "refusing: /system/bin/nowhere_db_fix exists on this host" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT   # every case root and mutant copy is made inside it

SHELLS=""
if [ -n "${RL_SHELLS:-}" ]; then SHELLS="$RL_SHELLS"
else for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done; fi

fn_of() { awk -v a="$2() {" '$0 == a {f=1} f{print} f&&/^}$/{exit}' "$1"; }

DB='ROOT/user/10/com.android.launcher3/databases/launcher.db'
# The owner, then user 100 BEFORE user 10 (an unanchored grep for user 10 meets 100 first), and a second serialNo on
# user 10's own line (`head -1` keeps the first).
D_TWO='  UserInfo{0:Owner:c13} serialNo=0 isPrimary=true
  UserInfo{100:Nowhere:410} serialNo=77 isPrimary=false
  UserInfo{10:Nowhere:410} serialNo=42 isPrimary=false creationTime=+1m serialNo=99'
# No line for user 10.
D_NONE='  UserInfo{0:Owner:c13} serialNo=0 isPrimary=true
  UserInfo{100:Nowhere:410} serialNo=77 isPrimary=false'

suite() {  # suite <roamd.sh> <quiet|""> -> 0 all ok, 1 a check failed, 2 the harness could not extract
  local f="$1" quiet="${2:-}" p=0 x=0 FN sh out
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); say "  FAIL  $l"; fi
  }
  # cnt <out> <prefix> <rest>: how many lines of <out> are exactly "<prefix> <rest>"
  cnt() { printf '%s\n' "$1" | grep -cxF "$2 $3"; }
  # lines <out> <prefix>: the <prefix> lines of <out>, joined with |
  lines() { printf '%s\n' "$1" | grep "^$2 " | tr '\n' '|'; }

  FN=$(fn_of "$f" relabel_launcher)
  [ -n "$FN" ] || { echo "EXTRACTION FAILED: relabel_launcher in $f" >&2; return 2; }
  [ "$(printf '%s\n' "$FN" | tail -n 1)" = "}" ] || { echo "EXTRACTION FAILED: relabel_launcher in $f is truncated" >&2; return 2; }
  [ "$(printf '%s\n' "$FN" | grep -c 'dumpsys user')" = 1 ] || { echo "EXTRACTION FAILED: relabel_launcher in $f is truncated (no dumpsys user line)" >&2; return 2; }
  [ "$(printf '%s\n' "$FN" | grep -c '/system/bin/nowhere_db_fix')" -gt 0 ] || { echo "REWRITE FAILED: no /system/bin/nowhere_db_fix in relabel_launcher" >&2; return 2; }

  # run_case <shell> <dump text> <db: yes|no> <tool: yes|no> <relabel rc> <widget rc>: runs the real function for
  # user 10 in a fresh root; prints the run's output, then `CALL <argv>` per tool call, `DUMPSYS <argv>` per dumpsys
  # call and `LOG <line>` per log line, with the root replaced by ROOT.
  run_case() {
    local root
    root=$(mktemp -d -p "$W")
    mkdir -p "$root/bin" "$root/user/10/com.android.launcher3/databases"
    [ "$3" = yes ] && : > "$root/user/10/com.android.launcher3/databases/launcher.db"
    printf '%s\n' "$2" > "$root/dump"
    printf '%s\n' "$FN" | sed "s#/system/bin/nowhere_db_fix#$root/bin/nowhere_db_fix#g" > "$root/fn.sh"
    if [ "$(grep -c '/system/bin/' "$root/fn.sh")" != 0 ]; then
      echo "REWRITE FAILED: a /system/bin/ path escaped the rewrite"; return
    fi
    if [ "$4" = yes ]; then
      cat > "$root/bin/nowhere_db_fix" <<STUB
#!/bin/sh
echo "\$*" >> "$root/calls"
case "\$1" in launcher-relabel) exit $5 ;; launcher-widgets) exit $6 ;; esac
exit 9
STUB
      chmod +x "$root/bin/nowhere_db_fix"
    fi
    : > "$root/calls"; : > "$root/log"; : > "$root/dumpsys.calls"
    cat > "$root/case.sh" <<CASE
LOG="$root/log"
dumpsys() { echo "dumpsys \$*" >> "$root/dumpsys.calls"; cat "$root/dump"; }
. "$root/fn.sh"
relabel_launcher 10 "$root/user/10"
echo "ret=\$?"
CASE
    "$1" "$root/case.sh" > "$root/run" 2>&1
    { cat "$root/run"; sed 's/^/CALL /' "$root/calls"; sed 's/^/DUMPSYS /' "$root/dumpsys.calls"
      sed 's/^/LOG /' "$root/log"; } | sed "s#$root#ROOT#g"
  }

  for sh in $SHELLS; do
    say "== $sh"
    out=$(run_case "$sh" "$D_TWO" yes yes 0 0)
    case "$out" in *"REWRITE FAILED"*) echo "$out" >&2; return 2 ;; esac
    chk "L1 [$sh] user 10's own serial: 'launcher-relabel <db> 42', then 'launcher-widgets <db>' (got '$(lines "$out" CALL)')" \
      [ "$(lines "$out" CALL)" = "CALL launcher-relabel $DB 42|CALL launcher-widgets $DB|" ]
    chk "L1 [$sh] no call carries user 100's serial 77 or the second serial 99" \
      [ "$(printf '%s\n' "$out" | grep '^CALL ' | grep -cE '77|99')" = 0 ]
    chk "L1 [$sh] the relabeled line" [ "$(cnt "$out" LOG '[roamd] relabeled launcher favorites -> serial 42 (user 10)')" = 1 ]
    chk "L1 [$sh] the widget mark line" [ "$(cnt "$out" LOG '[roamd] marked roamed widgets for launcher re-bind (user 10)')" = 1 ]
    chk "L1 [$sh] one 'dumpsys user' call" [ "$(lines "$out" DUMPSYS)" = "DUMPSYS dumpsys user|" ]

    out=$(run_case "$sh" "$D_TWO" no yes 0 0)
    chk "L2 [$sh] no launcher.db: no dumpsys, no tool call, no log line (got '$(lines "$out" '[A-Z]*')')" \
      [ "$(printf '%s\n' "$out" | grep -cE '^(CALL|DUMPSYS|LOG) ')" = 0 ]

    out=$(run_case "$sh" "$D_NONE" yes yes 0 0)
    chk "L3 [$sh] no line for user 10: only the no-serial line (got '$(lines "$out" LOG)')" \
      [ "$(lines "$out" LOG)" = "LOG [roamd] launcher relabel: no serial for user 10|" ]
    chk "L3 [$sh] no line for user 10: no tool call, no widget mark (got '$(lines "$out" CALL)')" \
      [ "$(printf '%s\n' "$out" | grep -c '^CALL ')" = 0 ]

    out=$(run_case "$sh" "$D_TWO" yes no 0 0)
    chk "L4 [$sh] tool missing: the SKIPPED line" \
      [ "$(cnt "$out" LOG '[roamd] launcher relabel SKIPPED: ROOT/bin/nowhere_db_fix missing on this build (user 10)')" = 1 ]
    chk "L4 [$sh] tool missing: the widget restore-mark FAILED line" \
      [ "$(cnt "$out" LOG '[roamd] widget restore-mark FAILED (user 10)')" = 1 ]
    chk "L4 [$sh] tool missing: no relabeled and no relabel FAILED line (got '$(lines "$out" LOG)')" \
      [ "$(printf '%s\n' "$out" | grep -c -e '^LOG \[roamd\] relabeled ' -e '^LOG \[roamd\] launcher relabel FAILED')" = 0 ]

    out=$(run_case "$sh" "$D_TWO" yes yes 1 0)
    chk "L5 [$sh] relabel exits 1: the relabel FAILED line" [ "$(cnt "$out" LOG '[roamd] launcher relabel FAILED (user 10)')" = 1 ]
    chk "L5 [$sh] relabel exits 1: the widget call still runs (got '$(lines "$out" CALL)')" \
      [ "$(lines "$out" CALL)" = "CALL launcher-relabel $DB 42|CALL launcher-widgets $DB|" ]
    chk "L5 [$sh] relabel exits 1: the widget mark line" [ "$(cnt "$out" LOG '[roamd] marked roamed widgets for launcher re-bind (user 10)')" = 1 ]
    chk "L5 [$sh] relabel exits 1: no relabeled line" [ "$(printf '%s\n' "$out" | grep -c '^LOG \[roamd\] relabeled ')" = 0 ]
  done

  [ -z "$quiet" ] && printf '%s: passed %d, failed %d\n' "$f" "$p" "$x"
  [ "$x" = 0 ]
}

mutate_to() {  # mutate_to <mutant> <out file> -- one textual replace inside relabel_launcher of $SUT
  python3 - "$1" "$SUT" "$2" <<'PY'
import sys
m, src, dst = sys.argv[1:]
s = open(src).read()
start = s.find('\nrelabel_launcher() {\n')
if start < 0 or s.count('\nrelabel_launcher() {\n') != 1:
    sys.exit('relabel_launcher not found once')
end = s.index('\n}\n', start) + 3
fn = s[start:end]
skip = ('  if [ ! -x /system/bin/nowhere_db_fix ]; then\n'
        '    echo "[roamd] launcher relabel SKIPPED: /system/bin/nowhere_db_fix missing on this build (user $1)" >> "$LOG"\n'
        '  elif /system/bin/nowhere_db_fix launcher-relabel')
wid = '  if [ -x /system/bin/nowhere_db_fix ] && /system/bin/nowhere_db_fix launcher-widgets'
R = {
  'M1': ('grep "UserInfo{$1:"', 'grep "UserInfo{$1"'),
  'M2': ("grep -oE 'serialNo=[0-9]+' | head -1 |", "grep -oE 'serialNo=[0-9]+' | tail -1 |"),
  'M3': (skip, '  if /system/bin/nowhere_db_fix launcher-relabel'),
  'M4': ('no serial for user $1" >> "$LOG"; return; }', 'no serial for user $1" >> "$LOG"; }'),
}
if m == 'M5':
    if fn.count(wid) != 1:
        sys.exit('mutant M5 did not apply')
    i = fn.index(wid)
    j = fn.index('\n  fi\n', i) + len('\n  fi\n')
    new = fn[:i] + '  :\n' + fn[j:]
else:
    a, b = R[m]
    if fn.count(a) != 1:
        sys.exit('mutant %s did not apply' % m)
    new = fn.replace(a, b, 1)
open(dst, 'w').write(s[:start] + new + s[end:])
PY
}

run_mutants() {
  local m c sh rc bad=0 desc
  for m in M1 M2 M3 M4 M5; do
    case "$m" in
      M1) desc="the ':' dropped from UserInfo{\$1: (user 10 reads user 100's serial)" ;;
      M2) desc="head -1 replaced by tail -1 (the last serialNo on the line)" ;;
      M3) desc="the missing-tool guard removed" ;;
      M4) desc="the no-serial return removed (a tool call with an empty serial)" ;;
      M5) desc="the widget call removed" ;;
    esac
    c=$(mktemp -p "$W")
    if ! mutate_to "$m" "$c" || cmp -s "$c" "$SUT"; then echo "  FAIL  $m did not apply: $desc"; bad=1; rm -f "$c"; continue; fi
    for sh in $SHELLS; do
      RL_SHELLS="$sh" bash "$SELF" "$c" >/dev/null 2>&1; rc=$?
      if [ "$rc" = 1 ]; then echo "  ok    $m CONVICTED under $sh: $desc"
      else echo "  FAIL  $m rc=$rc under $sh (want 1): $desc"; bad=1; fi
    done
    rm -f "$c"
  done
  return $bad
}

[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: no python3 on this host -- the suite did NOT run" >&2; exit 2; }
suite "$SUT" ""; rc=$?
[ "$rc" = 0 ] || exit "$rc"
if [ "$MUTATE" = yes ]; then
  run_mutants || exit 1
  echo "all mutants convicted"
fi
exit 0
