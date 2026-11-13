#!/usr/bin/env bash
# test-media-remap-call.sh [<nowhere_roamd.sh>] [--mutate] -- the sign-in repoints the roamed MediaStore index at the
# new user (NWP-20261124-01; backlog §B 'A photo taken in one session is "inaccessible" after a log off and sign-in').
#
# WHY THIS IS COMMITTED. The CE and #de seals carry MediaProvider's external.db with the absolute
# /storage/emulated/<sealing user>/ path of every file. After a sign-in as a new user id the rows name the old user:
# the camera's photo is "inaccessible" and the mount-time scan adds a second row, so every folder shows twice.
# roamd's remap_media_db runs `nowhere_db_fix media-remap` on each MediaProvider external.db the CE and #de restores
# brought back. This suite runs the REAL helper (extracted by anchor, the binary re-rooted to a stub) and the REAL
# CE and #de tails of the `in` arm under every shell found, and pins the order: both calls run before remap_per_pkg
# and restorecon, which re-own and relabel any -wal/-shm the rewrite creates as root. What the binary does to the
# database is test-nowhere-db-fix.sh's job. NWP-20261129-01: the binary prints `<remapped> <dropped> <reowned>
# <generation>`, the last `-` when it took no generation; the OK line carries all four (C1, C2, C9).
#
#   bash test-media-remap-call.sh              # the cases
#   bash test-media-remap-call.sh --mutate     # ... plus mutants of roamd that must each CONVICT under every shell
#
# Pure logic -- no device. Exit 0 all pass, 1 a check failed, 2 the harness could not extract (never a pass).
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; -*) echo "usage: $0 [<nowhere_roamd.sh>] [--mutate]" >&2; exit 2 ;; *) SUT="$a" ;; esac; done
SELF="$0"
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# The helper's binary path is re-rooted below; a host that has the real path would make a mis-rooted run look fine.
[ -e /system/bin/nowhere_db_fix ] && { echo "refusing: /system/bin/nowhere_db_fix exists on this host" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT   # every case root and mutant copy is made inside it

SHELLS=""
if [ -n "${MRC_SHELLS:-}" ]; then SHELLS="$MRC_SHELLS"
else for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done; fi

arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
fn_of() { awk -v a="$2() {" '$0 == a {f=1} f{print} f&&/^}$/{exit}' "$1"; }
codeonly() { grep -vE '^[[:space:]]*#' ; }
# seg_of <code> <var>: from `      <var>=skip` through the first `      fi` after it (the #de capture and its tail)
seg_of() { printf '%s\n' "$1" | awk -v a="      $2=skip" '$0 == a {f=1} f{print} f&&/^      fi$/{exit}'; }
# ce_of <code>: from the relabel_launcher line through the CE restorecon line
ce_of() { printf '%s\n' "$1" | awk -v a="$L_RL" '$0 == a {f=1} f{print} f&&index($0, "restorecon -R \"$USERDIR\""){exit}'; }

L_RL='      relabel_launcher "$uid" "$USERDIR"   # rewrite home-layout serial so the launcher keeps it (see above)'
# The two calls and the remap_per_pkg lines after them, as fixed line prefixes (a call may carry a trailing comment)
F_CE='      remap_media_db "$uid" "$USERDIR"'
F_DE='        remap_media_db "$uid" "$DEDIR"'
F_PCE='      _tt=$(_ms); remap_per_pkg "$USERDIR";'
F_PDE='        _tt=$(_ms); remap_per_pkg "$DEDIR";'
# calls <code> <prefix>: how many lines are the prefix alone or the prefix, a space and more
calls() { printf '%s\n' "$1" | awk -v a="$2" '$0 == a || index($0, a " ") == 1 {c++} END {print c + 0}'; }
# before <code> <prefix A> <prefix B> [<exact line before A>]: 1 when some A line is directly followed by a B line
# (and, given the 4th argument, directly preceded by that line)
before() {
  printf '%s\n' "$1" | awk -v a="$2" -v b="$3" -v z="${4-}" '
    pa && index($0, b) == 1 { c = 1 }
    { pa = (($0 == a || index($0, a " ") == 1) && (z == "" || prev == z)); prev = $0 } END { print c + 0 }'
}
A_PK='com.android.providers.media.module/databases/external.db'
G_PK='com.google.android.providers.media.module/databases/external.db'

suite() {  # suite <roamd.sh> <quiet|""> -> 0 all ok, 1 a check failed, 2 the harness could not extract
  local f="$1" quiet="${2:-}" p=0 x=0 FN IN CODE SCE SDE n sh out
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); say "  FAIL  $l"; fi
  }

  FN=$(fn_of "$f" remap_media_db)
  [ -n "$FN" ] || { echo "EXTRACTION FAILED: remap_media_db in $f" >&2; return 2; }
  IN=$(arm_of "$f" in)
  [ -n "$IN" ] || { echo "EXTRACTION FAILED: the in arm in $f" >&2; return 2; }
  CODE=$(printf '%s\n' "$IN" | codeonly)
  SCE=$(ce_of "$CODE"); SDE=$(seg_of "$CODE" _derc)
  [ -n "$SCE" ] || { echo "EXTRACTION FAILED: the CE tail (relabel_launcher ... restorecon) in the in arm" >&2; return 2; }
  [ -n "$SDE" ] || { echo "EXTRACTION FAILED: the #de capture segment (_derc=skip ... fi) in the in arm" >&2; return 2; }
  printf '%s\n' "$SCE" > "$W/seg-ce.sh"
  printf '%s\n' "$SDE" > "$W/seg-de.sh"

  # helper <shell> <present: a|g|ag|-> <stub: rc|missing> [<stub stdout>]: runs the real helper for user 11 in a
  # fresh root; prints `ret=<rc>`, then the stub's calls, then the log, then the caller's db/out after the call.
  helper() {
    local root dir
    root=$(mktemp -d -p "$W")
    dir="$root/data/user/11"
    case "$2" in *a*) mkdir -p "$dir/com.android.providers.media.module/databases"; : > "$dir/$A_PK" ;; esac
    case "$2" in *g*) mkdir -p "$dir/com.google.android.providers.media.module/databases"; : > "$dir/$G_PK" ;; esac
    mkdir -p "$root/bin"
    printf '%s\n' "$FN" | sed "s#/system/bin/nowhere_db_fix#$root/bin/nowhere_db_fix#g" > "$root/fn.sh"
    if [ "$3" != missing ]; then
      cat > "$root/bin/nowhere_db_fix" <<STUB
#!/bin/sh
echo "\$*" >> "$root/calls"
printf '%s\n' "${4:-2 1 3 42}"
echo "stub-stderr-word" >&2
exit $3
STUB
      chmod +x "$root/bin/nowhere_db_fix"
    fi
    : > "$root/calls"; : > "$root/log"
    "$1" -c '. "$1"; LOG="$2"; db=keep; out=keep; remap_media_db 11 "$3"; echo "ret=$?"; echo "caller db=$db out=$out"' \
      _ "$root/fn.sh" "$root/log" "$dir" > "$root/run" 2>&1
    sed "s#$root#ROOT#g" "$root/run" "$root/calls" "$root/log"
  }

  # tail <shell> <ce|de> <agent rc>: runs the arm's real CE tail or #de segment with stubs that record their names
  tailrun() {
    local root
    root=$(mktemp -d -p "$W")
    mkdir -p "$root/user/11" "$root/user_de/11"
    cat > "$root/case.sh" <<CASE
ROOT="$root"; LOG="\$ROOT/log"; uid=11; name=prof; pass=pw; AGENT=agent_sim; SIM_RC=$3
USERDIR="\$ROOT/user/11"; DEDIR="\$ROOT/user_de/11"
: > "\$ROOT/calls"
pw() { printf '%s\n' x; }
agent_sim() { echo "agent" >> "\$ROOT/calls"; return "\$SIM_RC"; }
_ms() { echo 0; }
_tlog() { :; }
_ssum() { :; }
relabel_launcher() { echo "relabel_launcher" >> "\$ROOT/calls"; }
remap_media_db() { echo "remap_media_db \$1 \${2#\$ROOT/}" >> "\$ROOT/calls"; }
remap_per_pkg() { echo "remap_per_pkg \${1#\$ROOT/}" >> "\$ROOT/calls"; }
restorecon() { echo "restorecon" >> "\$ROOT/calls"; }
od_park_var() { :; }   # NWP-20261130-03
. "$W/seg-$2.sh"
tr '\n' '|' < "\$ROOT/calls"
CASE
    "$1" "$root/case.sh" 2>&1
  }

  for sh in $SHELLS; do
    say "== $sh"
    out=$(helper "$sh" ag 0)
    chk "C1 [$sh] both packages: two calls, com.android first, each 'media-remap <db> 11'" \
      [ "$(printf '%s\n' "$out" | grep -c '^media-remap ')" = 2 ]
    chk "C1 [$sh] the com.android call" [ "$(printf '%s\n' "$out" | sed -n '/^media-remap /{p;q;}')" = "media-remap ROOT/data/user/11/$A_PK 11" ]
    chk "C1 [$sh] the com.google call" [ "$(printf '%s\n' "$out" | grep '^media-remap ' | sed -n 2p)" = "media-remap ROOT/data/user/11/$G_PK 11" ]
    chk "C1 [$sh] two 'repointed' lines with the stub's counts" \
      [ "$(printf '%s\n' "$out" | grep -cxF '[roamd] media-remap user 11: 2 row(s) repointed, 1 stale duplicate(s) dropped, 3 row(s) given user 11, generation 42 (NWP-20261129-01)')" = 2 ]
    chk "C1 [$sh] returns 0" [ "$(printf '%s\n' "$out" | grep -c '^ret=0$')" = 1 ]
    chk "C1 [$sh] the helper's variables are local (the caller's db and out survive)" \
      [ "$(printf '%s\n' "$out" | grep -c '^caller db=keep out=keep$')" = 1 ]
    out=$(helper "$sh" g 0 "7 0 3 42")
    chk "C2 [$sh] only com.google: one call, on its path" \
      [ "$(printf '%s\n' "$out" | grep '^media-remap ' | tr '\n' '|')" = "media-remap ROOT/data/user/11/$G_PK 11|" ]
    chk "C2 [$sh] its line carries the binary's counts" \
      [ "$(printf '%s\n' "$out" | grep -cxF '[roamd] media-remap user 11: 7 row(s) repointed, 0 stale duplicate(s) dropped, 3 row(s) given user 11, generation 42 (NWP-20261129-01)')" = 1 ]
    out=$(helper "$sh" a 0)
    chk "C2 [$sh] only com.android: one call, on its path" \
      [ "$(printf '%s\n' "$out" | grep '^media-remap ' | tr '\n' '|')" = "media-remap ROOT/data/user/11/$A_PK 11|" ]
    out=$(helper "$sh" - 0)
    chk "C3 [$sh] no database: no call, no log line, returns 0" \
      [ "$(printf '%s\n' "$out" | grep -c -e '^media-remap ' -e 'roamd')|$(printf '%s\n' "$out" | grep -c '^ret=0$')" = "0|1" ]
    out=$(helper "$sh" a 6)
    chk "C4 [$sh] binary rc 6: the FAILED line" \
      [ "$(printf '%s\n' "$out" | grep -cxF '[roamd] media-remap user 11: FAILED rc=6 -- left as restored (NWP-20261124-01)')" = 1 ]
    chk "C4 [$sh] binary rc 6: no 'repointed' line, returns 0" \
      [ "$(printf '%s\n' "$out" | grep -c 'repointed')|$(printf '%s\n' "$out" | grep -c '^ret=0$')" = "0|1" ]
    out=$(helper "$sh" a missing)
    chk "C5 [$sh] binary missing: the SKIPPED line" \
      [ "$(printf '%s\n' "$out" | grep -cxF '[roamd] media-remap SKIPPED: ROOT/bin/nowhere_db_fix missing on this build (user 11) (NWP-20261124-01)')" = 1 ]
    chk "C5 [$sh] binary missing: returns 0" [ "$(printf '%s\n' "$out" | grep -c '^ret=0$')" = 1 ]
    out=$(helper "$sh" a 0 "PLANTED-STDOUT")
    chk "C6 [$sh] the binary's stderr goes to the log" [ "$(printf '%s\n' "$out" | grep -cx 'stub-stderr-word')" = 1 ]
    chk "C6 [$sh] the binary's stdout is parsed, not logged as its own line" [ "$(printf '%s\n' "$out" | grep -cx 'PLANTED-STDOUT')" = 0 ]
    out=$(helper "$sh" a 0 "2 1 3 -")
    chk "C9 [$sh] a binary that took no generation: 'generation unchanged'" \
      [ "$(printf '%s\n' "$out" | grep -cxF '[roamd] media-remap user 11: 2 row(s) repointed, 1 stale duplicate(s) dropped, 3 row(s) given user 11, generation unchanged (NWP-20261129-01)')" = 1 ]
    out=$(tailrun "$sh" ce 0)
    chk "C7 [$sh] CE tail: relabel_launcher, remap_media_db on the CE dir, remap_per_pkg, restorecon (got '$out')" \
      [ "$out" = "relabel_launcher|remap_media_db 11 user/11|remap_per_pkg user/11|restorecon|" ]
    out=$(tailrun "$sh" de 0)
    chk "C8 [$sh] #de restore exit 0: remap_media_db on the DE dir before remap_per_pkg and restorecon (got '$out')" \
      [ "$out" = "agent|remap_media_db 11 user_de/11|remap_per_pkg user_de/11|restorecon|" ]
    out=$(tailrun "$sh" de 5)
    chk "C8 [$sh] #de restore exit 5: no remap_media_db (got '$out')" [ "$out" = "agent|" ]
  done

  # source pins over the arm, comments dropped
  chk "P1 the in arm calls remap_media_db on \$USERDIR exactly once" [ "$(calls "$CODE" "$F_CE")" = 1 ]
  chk "P2 the in arm calls remap_media_db on \$DEDIR exactly once" [ "$(calls "$CODE" "$F_DE")" = 1 ]
  chk "P3 the CE call sits directly after relabel_launcher and directly before remap_per_pkg \"\$USERDIR\"" \
    [ "$(before "$CODE" "$F_CE" "$F_PCE" "$L_RL")" = 1 ]
  chk "P4 the DE call sits directly before remap_per_pkg \"\$DEDIR\"" [ "$(before "$CODE" "$F_DE" "$F_PDE")" = 1 ]
  n=$(printf '%s\n' "$FN" | grep -cE '^  local db out rc nrem ndrop mrest nown ngen$')
  chk "P5 the helper declares every variable local" [ "$n" = 1 ]
  n=$(printf '%s\n' "$FN" | grep -cF -e "\"\$2/$A_PK\"" -e "\"\$2/$G_PK\"")
  chk "P6 the helper names both MediaProvider packages" [ "$n" = 2 ]

  [ -z "$quiet" ] && printf '%s: passed %d, failed %d\n' "$f" "$p" "$x"
  [ "$x" = 0 ]
}

mutate_to() {  # mutate_to <mutant> <out file> -- one textual replace of $SUT, written to <out file>
  python3 - "$1" "$SUT" "$2" <<'PY'
import sys
m, src, dst = sys.argv[1:]
s = open(src).read()
ce = '      remap_media_db "$uid" "$USERDIR"'
de = '        remap_media_db "$uid" "$DEDIR"'
def line_with(prefix):
    for l in s.split('\n'):
        if l.startswith(prefix):
            return l + '\n'
    sys.exit('no line starting %r' % prefix)
cel, del_ = line_with(ce), line_with(de)
pce = line_with('      _tt=$(_ms); remap_per_pkg "$USERDIR";')
pde = line_with('        _tt=$(_ms); remap_per_pkg "$DEDIR";')
R = {
  'N1': (cel + pce, pce + cel),
  'N2': (del_ + pde, pde + del_),
  'N3': (' \\\n            "$2/com.google.android.providers.media.module/databases/external.db"; do', '; do'),
  'N4': ('FAILED rc=$rc -- left as restored (NWP-20261124-01)" >> "$LOG"',
         'FAILED rc=$rc -- left as restored (NWP-20261124-01)" >> "$LOG"; return 1'),
  'N5': ('  local db out rc nrem ndrop mrest nown ngen\n', '  :\n'),
  'N6': ('if [ "$ngen" = "-" ]; then', 'if false; then'),
}
a, b = R[m]
if s.count(a) != 1:
    sys.exit('mutant %s did not apply' % m)
open(dst, 'w').write(s.replace(a, b, 1))
PY
}

run_mutants() {
  local m c sh rc bad=0 desc
  for m in N1 N2 N3 N4 N5 N6; do
    case "$m" in
      N1) desc="the CE call moved after remap_per_pkg" ;;
      N2) desc="the DE call moved after remap_per_pkg" ;;
      N3) desc="the com.google path dropped" ;;
      N4) desc="a failure returns 1" ;;
      N5) desc="the helper's variables are not local" ;;
      N6) desc="'-' is not read as unchanged" ;;
    esac
    c=$(mktemp -p "$W")
    if ! mutate_to "$m" "$c" || cmp -s "$c" "$SUT"; then echo "  FAIL  $m did not apply: $desc"; bad=1; rm -f "$c"; continue; fi
    for sh in $SHELLS; do
      MRC_SHELLS="$sh" bash "$SELF" "$c" >/dev/null 2>&1; rc=$?
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
