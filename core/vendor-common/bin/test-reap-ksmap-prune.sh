#!/usr/bin/env bash
# test-reap-ksmap-prune.sh [<nowhere_roamd.sh>] [--mutate] -- the reap's keystore-map prune keeps the map when its
# filter fails (NWP-20261126-13).
#
# WHY THIS IS COMMITTED. The cleanstorage op pruned the reaped uid's rows from keystore-map, the keep-list and the
# census with `grep -v ... > "$STATE/.ksprune"` followed by an unconditional `cat "$STATE/.ksprune" > file`. grep's
# status was thrown away. When $STATE was full (keystore_push stages the #keys bundles there just before), the temp
# could not be created, and `cat` of the missing temp still truncated the file. An emptied map cost a parked
# session its ns->pkg rows, so its own reap sealed none of its Keystore dumps. The block now renames
# keystore-map.reap over the map, and rewrites the census and the keep-list in place, each only when grep returned
# 0 or 1 AND its temp exists. Otherwise the file is unchanged and one FAILED line names the uid.
#
# The block between `# KS-PRUNE-BEGIN (NWP-20261126-13)` and `# KS-PRUNE-END` is extracted from roamd (never
# copied) and run under every shell found (bash as `bash --posix`, sh, dash, mksh; de-duplicated by the file they
# resolve to).
#   C1   a normal prune of uid 10: only uid 10's rows go (uid 11's and uid 101's stay, in order), all three files.
#   C2   $STATE under a regular file: the census and keep-list are unchanged and their FAILED lines are logged; the
#        map (its temp is beside it) is still pruned.
#   C2b  a failing mv: the map is unchanged, its FAILED line is logged, no keystore-map.reap is left.
#   C3   a grep that prints one line and returns 2: all three files are unchanged.
#   C4   every row is uid 10's: the map and the census exist and are empty.
#   C5   the census keeps its inode, the map's changes; no temp is left; a planted keystore-map.reap is removed and
#        never becomes the map.
#   C6   no log names a package or an ns of the fixture.
#   Mutants M1-M7 (--mutate) must each be CONVICTED under every shell they run under.
#
#   bash test-reap-ksmap-prune.sh              # the cases
#   bash test-reap-ksmap-prune.sh --mutate     # ... plus mutants of roamd that must each CONVICT
#
# Pure logic -- no device. Exit 0 all pass, 1 a check failed, 2 the harness could not extract (never a pass).
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT   # every case root and mutant copy is made inside it

# Every shell found, de-duplicated by the file it resolves to (sh is often bash or dash).
SHELLS=""
seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || { echo "[$s] not installed: its lines run on the CI host"; continue; }
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS="$SHELLS $s"
done
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }

invoke() {  # invoke <shell> <args...>: bash runs as `bash --posix`
  local sh="$1"; shift
  case "$sh" in bash) bash --posix "$@" ;; *) "$sh" "$@" ;; esac
}

BEGIN_LINE='  # KS-PRUNE-BEGIN (NWP-20261126-13)'
END_LINE='  # KS-PRUNE-END'
block_of() {  # block_of <roamd.sh>: the lines from BEGIN to END, both included; empty when either is missing
  awk -v b="$BEGIN_LINE" -v e="$END_LINE" '$0 == b {f=1} f{print} f && $0 == e {done=1; exit} END{if (!done) exit 1}' "$1"
}

MAP0='1000057 com.ex.alpha
1100061 com.ex.beta
1000072 com.ex.gamma
10100083 com.ex.delta
1100094 com.ex.eps'
MAP1='1100061 com.ex.beta
10100083 com.ex.delta
1100094 com.ex.eps'
CEN0='1000057
1100061
1000072
10100083
1100094'
CEN1='1100061
10100083
1100094'
MAPALL='1000057 com.ex.alpha
1000072 com.ex.gamma'
CENALL='1000057
1000072'
PKGS="com.ex.alpha com.ex.beta com.ex.gamma com.ex.delta com.ex.eps"
NSS="1000057 1100061 1000072 10100083 1100094"
FAIL_MAP='[roamd] reap: keystore-map prune FAILED for user 10 -- the map is unchanged (NWP-20261126-13)'
FAIL_CEN='[roamd] reap: census prune FAILED for user 10 -- the census is unchanged (NWP-20261126-13)'
FAIL_KEEP='[roamd] reap: keep-list prune FAILED for user 10 -- the keep-list is unchanged (NWP-20261126-13)'
GREP2='grep() { eval "_g=\${$#}"; IFS= read -r _l < "$_g"; printf '"'"'%s\n'"'"' "$_l"; return 2; }'

suite() {  # suite <roamd.sh> [quiet] [shells] -> 0 all ok, 1 a check failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" shells="${3:-$SHELLS}" p=0 x=0 sh tag R B log i0 i1 m0 m1 w
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  ok() { p=$((p + 1)); say "  ok    $1"; }
  bad() { x=$((x + 1)); say "  FAIL  $1"; }
  same() {  # same <label> <file> <want text>
    local wf
    wf=$(mktemp -p "$W") || { bad "$1 (mktemp)"; return; }
    printf '%s\n' "$3" > "$wf"
    if [ -f "$2" ] && cmp -s "$2" "$wf"; then ok "$1"; else bad "$1 (got '$(cat "$2" 2>/dev/null)')"; fi
    rm -f "$wf"
  }
  haslog() {  # haslog <label> <log> <line prefix> yes|no
    local got
    got=$(cat "$2" 2>/dev/null)
    case "$got" in *"$3"*) [ "$4" = yes ] && ok "$1" || bad "$1 (logged)" ;;
    *) [ "$4" = no ] && ok "$1" || bad "$1 (not logged)" ;; esac
  }
  noleak() {  # noleak <label> <log>: the log names no package and no ns of the fixture
    local got t hit=""
    got=$(cat "$2" 2>/dev/null)
    for t in $PKGS $NSS; do case "$got" in *"$t"*) hit="$hit $t" ;; esac; done
    [ -z "$hit" ] && ok "$1" || bad "$1 (names:$hit)"
  }
  notemp() {  # notemp <label> <root>
    [ ! -e "$2/nowhere/keystore-map.reap" ] && ok "$1" || bad "$1 (keystore-map.reap left)"
  }

  B=$(block_of "$f") || { echo "EXTRACTION FAILED: the KS-PRUNE-BEGIN/END anchors are not both in $f" >&2; return 2; }
  [ -n "$B" ] || { echo "EXTRACTION FAILED: empty block in $f" >&2; return 2; }

  # mk: a fresh case root with the fixture; prints its path.
  mk() {  # mk <map> <census/keep text>
    local R
    R=$(mktemp -d -p "$W") || return 1
    mkdir -p "$R/state" "$R/nowhere" "$R/misc"
    : > "$R/log"
    printf '%s\n' "$1" > "$R/nowhere/keystore-map"
    printf '%s\n' "$2" > "$R/misc/nowhere-ns-keys"
    printf '%s\n' "$2" > "$R/misc/nowhere-keep-uids"
    printf '%s\n' "$R"
  }
  # run <shell> <root> [<STATE>] [<prelude>]: the block runs in <shell>, every path inside <root>.
  run() {
    local sh="$1" R="$2" st="${3:-$2/state}" pre="${4:-}"
    {
      printf "uid=10\nSTATE='%s'\nLOG='%s'\n" "$st" "$R/log"
      printf "KS_MAP='%s'\nKS_KEEP='%s'\nKS_CENSUS='%s'\n" "$R/nowhere/keystore-map" "$R/misc/nowhere-keep-uids" "$R/misc/nowhere-ns-keys"
      printf '%s\n' "$pre"
      printf '%s\n' "$B"
    } > "$R/run.sh"
    (cd "$R" && invoke "$sh" run.sh) >/dev/null 2>&1
  }

  for sh in $shells; do
    tag="[$sh]"
    invoke "$sh" -n <<<"$B" 2>/dev/null || { echo "EXTRACTION FAILED: the block does not parse under $sh" >&2; return 2; }

    say "$tag C1 a normal prune of uid 10"
    R=$(mk "$MAP0" "$CEN0") || return 2
    run "$sh" "$R"
    same "$tag C1 map keeps uid 11 and uid 101 rows, in order" "$R/nowhere/keystore-map" "$MAP1"
    same "$tag C1 census pruned" "$R/misc/nowhere-ns-keys" "$CEN1"
    same "$tag C1 keep-list pruned" "$R/misc/nowhere-keep-uids" "$CEN1"
    [ ! -s "$R/log" ] && ok "$tag C1 nothing logged" || bad "$tag C1 nothing logged ($(cat "$R/log"))"
    notemp "$tag C1 no keystore-map.reap left" "$R"
    noleak "$tag C6 C1's log names no package or ns" "$R/log"

    say "$tag C2 \$STATE under a regular file"
    R=$(mk "$MAP0" "$CEN0") || return 2
    : > "$R/afile"
    run "$sh" "$R" "$R/afile/state"
    same "$tag C2 census unchanged" "$R/misc/nowhere-ns-keys" "$CEN0"
    same "$tag C2 keep-list unchanged" "$R/misc/nowhere-keep-uids" "$CEN0"
    haslog "$tag C2 census FAILED line" "$R/log" "$FAIL_CEN" yes
    haslog "$tag C2 keep-list FAILED line" "$R/log" "$FAIL_KEEP" yes
    same "$tag C2 map still pruned (its temp is beside it)" "$R/nowhere/keystore-map" "$MAP1"
    haslog "$tag C2 no map FAILED line" "$R/log" "$FAIL_MAP" no
    noleak "$tag C6 C2's log names no package or ns" "$R/log"

    say "$tag C2b a failing mv"
    R=$(mk "$MAP0" "$CEN0") || return 2
    run "$sh" "$R" "" 'mv() { return 1; }'
    same "$tag C2b map unchanged" "$R/nowhere/keystore-map" "$MAP0"
    haslog "$tag C2b map FAILED line" "$R/log" "$FAIL_MAP" yes
    notemp "$tag C2b no keystore-map.reap left" "$R"
    noleak "$tag C6 C2b's log names no package or ns" "$R/log"

    say "$tag C3 a grep that fails mid-read (status 2)"
    R=$(mk "$MAP0" "$CEN0") || return 2
    run "$sh" "$R" "" "$GREP2"
    same "$tag C3 map unchanged" "$R/nowhere/keystore-map" "$MAP0"
    same "$tag C3 census unchanged" "$R/misc/nowhere-ns-keys" "$CEN0"
    same "$tag C3 keep-list unchanged" "$R/misc/nowhere-keep-uids" "$CEN0"
    haslog "$tag C3 map FAILED line" "$R/log" "$FAIL_MAP" yes
    haslog "$tag C3 census FAILED line" "$R/log" "$FAIL_CEN" yes
    haslog "$tag C3 keep-list FAILED line" "$R/log" "$FAIL_KEEP" yes
    notemp "$tag C3 no keystore-map.reap left" "$R"
    noleak "$tag C6 C3's log names no package or ns" "$R/log"

    say "$tag C4 every row is uid 10's"
    R=$(mk "$MAPALL" "$CENALL") || return 2
    run "$sh" "$R"
    { [ -f "$R/nowhere/keystore-map" ] && [ ! -s "$R/nowhere/keystore-map" ]; } && ok "$tag C4 map exists and is empty" || bad "$tag C4 map exists and is empty"
    { [ -f "$R/misc/nowhere-ns-keys" ] && [ ! -s "$R/misc/nowhere-ns-keys" ]; } && ok "$tag C4 census exists and is empty" || bad "$tag C4 census exists and is empty"
    [ ! -s "$R/log" ] && ok "$tag C4 nothing logged" || bad "$tag C4 nothing logged ($(cat "$R/log"))"

    say "$tag C5 inodes, temps, a planted leftover"
    R=$(mk "$MAP0" "$CEN0") || return 2
    i0=$(stat -c %i "$R/misc/nowhere-ns-keys"); m0=$(stat -c %i "$R/nowhere/keystore-map")
    run "$sh" "$R"
    i1=$(stat -c %i "$R/misc/nowhere-ns-keys" 2>/dev/null); m1=$(stat -c %i "$R/nowhere/keystore-map" 2>/dev/null)
    [ "$i0" = "$i1" ] && ok "$tag C5 census keeps its inode" || bad "$tag C5 census keeps its inode ($i0 -> $i1)"
    [ -n "$m1" ] && [ "$m0" != "$m1" ] && ok "$tag C5 map is renamed over (new inode)" || bad "$tag C5 map is renamed over ($m0 -> $m1)"
    notemp "$tag C5 no keystore-map.reap left" "$R"
    R=$(mk "$MAP0" "$CEN0") || return 2
    printf '9900001 com.ex.planted\n' > "$R/nowhere/keystore-map.reap"
    run "$sh" "$R"
    notemp "$tag C5 the planted keystore-map.reap is removed" "$R"
    same "$tag C5 the planted leftover never becomes the map" "$R/nowhere/keystore-map" "$MAP1"
  done
  w=$(printf '%s' "$shells" | tr -s ' ')
  say "$p passed, $x failed (shells:$w)"
  [ "$x" -eq 0 ] && return 0 || return 1
}

suite "$SUT"; rc=$?
[ "$rc" -eq 2 ] && exit 2
[ "$MUTATE" = yes ] || exit "$rc"
[ "$rc" -eq 0 ] || { echo "the cases fail on the real roamd; mutants not run" >&2; exit 1; }

# M7 needs a shell where a failed redirection of grep returns 1 (as bash does). The block's own construct is
# probed, not `: > missing`: `:` is a special builtin, so a failed redirection on it ENDS a POSIX shell
# (bash --posix, sh, dash, mksh) before `echo $?` runs. grep -v here would print the line and return 0, so a 1 can
# only come from the redirection under a regular file.
printf 'x\n' > "$W/probe.in"; : > "$W/probe.reg"
M7SHELLS=""
for sh in $SHELLS; do
  v=$(invoke "$sh" -c 'grep -v nomatch "$1" > "$2/x" 2>/dev/null; echo $?' sh "$W/probe.in" "$W/probe.reg" 2>/dev/null)
  if [ "$v" = 1 ]; then M7SHELLS="$M7SHELLS $sh"
  else echo "[$sh] M7 skipped: a failed redirection returns '${v:-nothing}' there, not 1, so the status check alone holds"; fi
done
case " $M7SHELLS " in *" bash "*) ;; *) echo "FAIL: M7 must run at least under bash (a failed redirection returned other than 1)"; exit 1 ;; esac

# mutate <name> <python replacement program>: apply to a copy, refuse a no-op, convict under each shell.
fail=0
mutate() {
  local name="$1" prog="$2" shells="${3:-$SHELLS}" m sh rc
  m=$(mktemp -p "$W") || exit 2
  python3 -c "$prog" "$SUT" "$m" || { echo "MUTANT DID NOT APPLY: $name (edit failed)"; fail=1; rm -f "$m"; return; }
  if cmp -s "$SUT" "$m"; then echo "MUTANT DID NOT APPLY: $name"; fail=1; rm -f "$m"; return; fi
  for sh in $shells; do
    suite "$m" quiet "$sh" 2>/dev/null; rc=$?
    case "$rc" in
      1) echo "[$sh] CONVICTED  $name" ;;
      2) echo "[$sh] MUTANT DID NOT APPLY (block no longer extracts or parses): $name"; fail=1 ;;
      *) echo "[$sh] SURVIVED   $name"; fail=1 ;;
    esac
  done
  rm -f "$m"
}
PY_HEAD='import sys
s = open(sys.argv[1]).read()
def rep(old, new):
    global s
    if s.count(old) != 1: sys.exit("anchor count %d" % s.count(old))
    s = s.replace(old, new)
'
PY_TAIL='
open(sys.argv[2], "w").write(s)'

mutate "M1 the old unconditional cat restored for the map" "$PY_HEAD"'
rep("""    grep -vE "^${uid}[0-9]{5}( |$)" "$KS_MAP" > "$KS_MAP.reap" 2>/dev/null; _ksmr=$?
    case "$_ksmr" in 0|1) ;; *) _ksmr=fail ;; esac
    [ -f "$KS_MAP.reap" ] || _ksmr=fail
    if [ "$_ksmr" = fail ] || ! mv -f "$KS_MAP.reap" "$KS_MAP" 2>>"$LOG"; then
      echo "[roamd] reap: keystore-map prune FAILED for user $uid -- the map is unchanged (NWP-20261126-13) $(date)" >> "$LOG"
    fi
""", """    if grep -vE "^${uid}[0-9]{5}( |$)" "$KS_MAP" > "$STATE/.ksprune" 2>/dev/null; then :; fi
    cat "$STATE/.ksprune" > "$KS_MAP" 2>/dev/null
    rm -f "$STATE/.ksprune" 2>/dev/null
""")'"$PY_TAIL"
mutate "M2 the map's status check dropped" "$PY_HEAD"'
rep("""    case "$_ksmr" in 0|1) ;; *) _ksmr=fail ;; esac
""", "")'"$PY_TAIL"
mutate "M3 the census's status check dropped" "$PY_HEAD"'
rep("""    case "$_kspr" in 0|1) ;; *) _kspr=fail ;; esac
""", "")'"$PY_TAIL"
mutate "M4 the census renamed instead of rewritten in place" "$PY_HEAD"'
rep("""      cat "$STATE/.ksprune" > "$_ksf" 2>/dev/null
""", """      mv -f "$STATE/.ksprune" "$_ksf" 2>/dev/null
""")'"$PY_TAIL"
mutate "M5 the final rm -f of keystore-map.reap deleted" "$PY_HEAD"'
rep("""  fi
  rm -f "$KS_MAP.reap" 2>/dev/null
  for _ksf in "$KS_KEEP" "$KS_CENSUS"; do
""", """  fi
  for _ksf in "$KS_KEEP" "$KS_CENSUS"; do
""")'"$PY_TAIL"
mutate "M6 the pattern widened to ^\${uid}" "$PY_HEAD"'
b = s.index("  # KS-PRUNE-BEGIN (NWP-20261126-13)"); e = s.index("  # KS-PRUNE-END")
blk = s[b:e]
if blk.count("\"^${uid}[0-9]{5}( |$)\"") != 2: sys.exit("pattern count")
s = s[:b] + blk.replace("\"^${uid}[0-9]{5}( |$)\"", "\"^${uid}\"") + s[e:]'"$PY_TAIL"
mutate "M7 the census's temp-exists check dropped" "$PY_HEAD"'
rep("""    [ -f "$STATE/.ksprune" ] || _kspr=fail
""", "")'"$PY_TAIL" "$M7SHELLS"

[ "$fail" -eq 0 ] && { echo "every mutant CONVICTED"; exit 0; } || { echo "a mutant was not convicted"; exit 1; }
