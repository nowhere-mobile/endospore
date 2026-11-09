#!/usr/bin/env bash
# test-media-insert-call.sh [<nowhere_roamd.sh>] [--mutate] -- the sign-in writes the Gallery's rows for media not yet
# downloaded (NWP-20261130-02; backlog §B 'On the DEFAULT tier the Gallery is empty: MediaStore never learns a deferred
# file exists').
#
# WHY THIS IS COMMITTED. The mount scan runs before the #media restore, so roamd's insert_deferred_media must run after
# it, once, on the list the agent left in $STATE/media.rows, and the list must be gone on every path. This suite runs the
# REAL helper (extracted by anchor, the binary re-rooted to a stub) under every shell found, and pins its place in the
# REAL `in` arm. What the binary does to the database is test-nowhere-db-fix.sh's job.
#
#   bash test-media-insert-call.sh              # the cases
#   bash test-media-insert-call.sh --mutate     # ... plus mutants of roamd that must each CONVICT under every shell
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
if [ -n "${MIC_SHELLS:-}" ]; then SHELLS="$MIC_SHELLS"
else for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done; fi

arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
fn_of() { awk -v a="$2() {" '$0 == a {f=1} f{print} f&&/^}$/{exit}' "$1"; }
codeonly() { grep -vE '^[[:space:]]*#' ; }
# line_nos <code> <fixed line prefix>: the numbers of the lines that are the prefix alone or the prefix, a space and more
line_nos() { printf '%s\n' "$1" | awk -v a="$2" '$0 == a || index($0, a " ") == 1 {print NR}'; }

F_CALL='          insert_deferred_media "$uid" "$USERDIR" "$DEDIR"'
F_TAIL='          restore_media_tail "$MEDIADIR"'
F_RM='        rm -f "$STATE/media.rows"'
F_BLOCK='        if [ "$_mdrc" = 0 ]; then'
F_FI='        fi'
F_RCE='      remap_media_db "$uid" "$USERDIR"'
F_RDE='        remap_media_db "$uid" "$DEDIR"'
F_RES='        [ -d "$MEDIADIR" ] && { NOWHERE_PHASE=media "$AGENT" restore s3 "${name}#media"'
A_PK='com.android.providers.media.module/databases/external.db'
G_PK='com.google.android.providers.media.module/databases/external.db'
OK_LINE='[roamd] media-insert user 11: 5 row(s) for media not yet downloaded, 2 already listed, 1 skipped, generation 42 (NWP-20261130-02)'

suite() {  # suite <roamd.sh> <quiet|""> -> 0 all ok, 1 a check failed, 2 the harness could not extract
  local f="$1" quiet="${2:-}" p=0 x=0 FN IN CODE sh out call tail rm block res rce rde fi1
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); say "  FAIL  $l"; fi
  }

  FN=$(fn_of "$f" insert_deferred_media)
  [ -n "$FN" ] || { echo "EXTRACTION FAILED: insert_deferred_media in $f" >&2; return 2; }
  IN=$(arm_of "$f" in)
  [ -n "$IN" ] || { echo "EXTRACTION FAILED: the in arm in $f" >&2; return 2; }
  CODE=$(printf '%s\n' "$IN" | codeonly)

  # helper <shell> <where: ca cg da dg, comma-joined, or -> <list: full|empty|absent> <stub: rc|missing> [<stdout>] [<side: 1>]:
  # runs the real helper for user 11 in a fresh root; prints `ret=<rc>`, the caller's variables, the recorded calls in
  # order (the stub's, chown's, restorecon's), then the log.
  helper() {
    local root ce de w d
    root=$(mktemp -d -p "$W")
    ce="$root/data/user/11"; de="$root/data/user_de/11"
    mkdir -p "$root/bin" "$root/state" "$ce" "$de"
    for w in $(printf '%s' "$2" | tr ',' ' '); do
      case "$w" in
        ca) d="$ce/$A_PK" ;; cg) d="$ce/$G_PK" ;; da) d="$de/$A_PK" ;; dg) d="$de/$G_PK" ;; *) continue ;;
      esac
      mkdir -p "$(dirname "$d")"; : > "$d"
      if [ "${6:-}" = 1 ]; then : > "$d-wal"; : > "$d-journal"; fi
    done
    case "$3" in
      full) printf '1\0002\000pictures\000Pictures/PLANTEDNAME.jpg\000' > "$root/state/media.rows" ;;
      empty) : > "$root/state/media.rows" ;;
    esac
    printf '%s\n' "$FN" | sed "s#/system/bin/nowhere_db_fix#$root/bin/nowhere_db_fix#g" > "$root/fn.sh"
    if [ "$4" != missing ]; then
      cat > "$root/bin/nowhere_db_fix" <<STUB
#!/bin/sh
echo "tool \$*" >> "$root/calls"
printf '%s\n' "${5:-5 2 1 42}"
echo "stub-stderr-word" >&2
exit $4
STUB
      chmod +x "$root/bin/nowhere_db_fix"
    fi
    : > "$root/calls"; : > "$root/log"
    cat > "$root/run.sh" <<RUN
. "$root/fn.sh"
LOG="$root/log"; STATE="$root/state"; db=keep; out=keep; sf=keep
stat() { echo "1023:1023"; }
chown() { echo "chown \$*" >> "$root/calls"; }
restorecon() { echo "restorecon \$*" >> "$root/calls"; }
insert_deferred_media 11 "$ce" "$de"; echo "ret=\$?"; echo "caller db=\$db out=\$out sf=\$sf"
RUN
    "$1" "$root/run.sh" > "$root/run" 2>&1
    sed "s#$root#ROOT#g" "$root/run" "$root/calls" "$root/log"
  }
  has() { [ "$(printf '%s\n' "$1" | grep -cxF -- "$2")" = "${3:-1}" ]; }

  for sh in $SHELLS; do
    say "== $sh"
    out=$(helper "$sh" ca full 0)
    chk "C1 [$sh] the OK line carries the tool's four fields" has "$out" "$OK_LINE"
    chk "C1 [$sh] returns 0" has "$out" "ret=0"
    chk "C1 [$sh] the helper's variables are local" has "$out" "caller db=keep out=keep sf=keep"
    out=$(helper "$sh" ca full 0 "0 7 1 -")
    chk "C2 [$sh] a tool that took no generation: 'generation unchanged'" has "$out" \
      '[roamd] media-insert user 11: 0 row(s) for media not yet downloaded, 7 already listed, 1 skipped, generation unchanged (NWP-20261130-02)'
    out=$(helper "$sh" ca full 6)
    chk "C3 [$sh] a tool failure: the FAILED line with its rc" has "$out" '[roamd] media-insert user 11: FAILED rc=6 -- left as restored (NWP-20261130-02)'
    chk "C3 [$sh] a tool failure: returns 0" has "$out" "ret=0"
    chk "C3 [$sh] a tool failure: no counts line" [ "$(printf '%s\n' "$out" | grep -c 'not yet downloaded')" = 0 ]
    out=$(helper "$sh" ca full missing)
    chk "C4 [$sh] a missing tool: the SKIPPED line" has "$out" '[roamd] media-insert SKIPPED: ROOT/bin/nowhere_db_fix missing on this build (user 11) (NWP-20261130-02)'
    chk "C4 [$sh] a missing tool: returns 0" has "$out" "ret=0"
    out=$(helper "$sh" ca absent 0)
    chk "C5 [$sh] an absent list: 'no media waiting'" has "$out" '[roamd] media-insert user 11: no media waiting (NWP-20261130-02)'
    chk "C5 [$sh] an absent list: the tool does not run" [ "$(printf '%s\n' "$out" | grep -c '^tool ')" = 0 ]
    out=$(helper "$sh" ca empty 0)
    chk "C5 [$sh] an empty list: 'no media waiting'" has "$out" '[roamd] media-insert user 11: no media waiting (NWP-20261130-02)'
    chk "C5 [$sh] an empty list: the tool does not run" [ "$(printf '%s\n' "$out" | grep -c '^tool ')" = 0 ]
    out=$(helper "$sh" - full 0)
    chk "C6 [$sh] no database: the line, no call" has "$out" '[roamd] media-insert user 11: no MediaProvider database yet -- rows not written (NWP-20261130-02)'
    chk "C6 [$sh] no database: the tool does not run, returns 0" [ "$(printf '%s\n' "$out" | grep -c '^tool ')|$(printf '%s\n' "$out" | grep -c '^ret=0$')" = "0|1" ]
    out=$(helper "$sh" ca,cg,da,dg full 0)
    chk "C7 [$sh] all four candidates: one call each, '<db> <uid> <list>', in order" \
      [ "$(printf '%s\n' "$out" | grep '^tool ' | tr '\n' '@')" = "tool media-insert ROOT/data/user/11/$A_PK 11 ROOT/state/media.rows@tool media-insert ROOT/data/user/11/$G_PK 11 ROOT/state/media.rows@tool media-insert ROOT/data/user_de/11/$A_PK 11 ROOT/state/media.rows@tool media-insert ROOT/data/user_de/11/$G_PK 11 ROOT/state/media.rows@" ]
    chk "C7 [$sh] all four candidates: four OK lines" has "$out" "$OK_LINE" 4
    out=$(helper "$sh" ca full 0 "5 2 1 42" 1)
    chk "C8 [$sh] side files that exist: chown to the db's owner and restorecon, after the tool, in order" \
      [ "$(printf '%s\n' "$out" | grep -E '^(tool|chown|restorecon) ' | sed 's#ROOT/data/user/11/##g' | tr '\n' '@')" = "tool media-insert $A_PK 11 ROOT/state/media.rows@chown 1023:1023 $A_PK-wal@restorecon $A_PK-wal@chown 1023:1023 $A_PK-journal@restorecon $A_PK-journal@" ]
    out=$(helper "$sh" ca full 6 "" 1)
    chk "C8 [$sh] a failed run fixes the side files too" [ "$(printf '%s\n' "$out" | grep -c '^restorecon ')" = 2 ]
    out=$(helper "$sh" ca full 0)
    chk "C8 [$sh] no side file: no chown, no restorecon" [ "$(printf '%s\n' "$out" | grep -cE '^(chown|restorecon) ')" = 0 ]
    chk "C9 [$sh] the tool's stderr goes to the log" has "$out" "stub-stderr-word"
    chk "C9 [$sh] a name in the list never reaches the log or the calls" [ "$(printf '%s\n' "$out" | grep -c 'PLANTEDNAME')" = 0 ]
  done

  # source pins over the arm, comments dropped
  call=$(line_nos "$CODE" "$F_CALL"); tail=$(line_nos "$CODE" "$F_TAIL"); rm=$(line_nos "$CODE" "$F_RM")
  block=$(line_nos "$CODE" "$F_BLOCK" | tail -1); res=$(line_nos "$CODE" "$F_RES"); rce=$(line_nos "$CODE" "$F_RCE"); rde=$(line_nos "$CODE" "$F_RDE")
  chk "P2 the in arm calls insert_deferred_media exactly once" [ "$(printf '%s\n' "$CODE" | grep -c 'insert_deferred_media')" = 1 ]
  chk "P2 restore_media_tail and the rm -f each appear once" [ "$(printf '%s\n' "$tail" | wc -l)|$(printf '%s\n' "$rm" | wc -l)" = "1|1" ]
  # round 53: main's sign-in summary times the tail alone, so its `_ssum reown` line may sit between (NWP-20261130-08)
  ssum1=$(printf '%s\n' "$CODE" | sed -n "$((${tail:-0}+1))p")
  chk "P1 the call directly follows restore_media_tail, or the _ssum reown line right after it" \
    [ "${call:-none}" = "$((${tail:-0}+1))" -o \( "${call:-none}" = "$((${tail:-0}+2))" -a "$ssum1" = '          _ssum reown "$_sumt"' \) ]
  sumt1=$(printf '%s\n' "$CODE" | sed -n "$((${block:-0}+1))p")
  chk "P2 the call sits inside the _mdrc = 0 block (the tail opens it, or follows main's _sumt line that does)" \
    [ "${block:-0}" = "$((${tail:-0}-1))" -o \( "${block:-0}" = "$((${tail:-0}-2))" -a "$sumt1" = '          _sumt=$(_ms)' \) ]
  chk "P3 the #media restore comes earlier in the arm" [ "${res:-999999}" -lt "${call:-0}" ]
  chk "P3 the CE remap_media_db call comes earlier in the arm" [ "${rce:-999999}" -lt "${call:-0}" ]
  chk "P3 the #de remap_media_db call comes earlier in the arm" [ "${rde:-999999}" -lt "${call:-0}" ]
  fi1=$(printf '%s\n' "$CODE" | sed -n "$((${call:-1}+1))p")
  chk "P4 the block's fi directly follows the call" [ "$fi1" = "$F_FI" ]
  chk "P4 the rm -f directly follows that fi, so it runs on every path" [ "${rm:-0}" = "$((${call:-0}+2))" ]

  [ -z "$quiet" ] && printf '%s: passed %d, failed %d\n' "$f" "$p" "$x"
  [ "$x" = 0 ]
}

mutate_to() {  # mutate_to <mutant> <out file> -- one textual replace of $SUT, written to <out file>
  python3 - "$1" "$SUT" "$2" <<'PY'
import sys
m, src, dst = sys.argv[1:]
s = open(src).read()
def line_with(prefix):
    for l in s.split('\n'):
        if l.startswith(prefix):
            return l + '\n'
    sys.exit('no line starting %r' % prefix)
call = line_with('          insert_deferred_media "$uid" "$USERDIR" "$DEDIR"')
rm = line_with('        rm -f "$STATE/media.rows"')
res = line_with('        [ -d "$MEDIADIR" ] && { NOWHERE_PHASE=media "$AGENT" restore s3 "${name}#media"')
R = {
  'N1': ('row(s) for media not yet downloaded, $np', 'row(s) for media waiting, $np'),
  'N2': ('if [ "$ng" = "-" ]; then ng="generation unchanged"; else', 'if false; then :; else'),
  'N3': ('FAILED rc=$rc -- left as restored (NWP-20261130-02)" >> "$LOG"\n', 'FAILED rc=$rc -- left as restored (NWP-20261130-02)" >> "$LOG"; return 1\n'),
  'N4': ('if [ ! -s "$list" ]; then', 'if [ ! -e "$list" ]; then'),
  'N5': ('''            "$3/com.android.providers.media.module/databases/external.db" \\\n            "$3/com.google.android.providers.media.module/databases/external.db"; do''', '''            ; do'''),
  'N6': ('      restorecon "$sf" 2>> "$LOG"\n', ''),
  'N7': ('*) chown "$own" "$sf" 2>> "$LOG" ;;', '*) : ;;'),
  'N9': (call, ''),
  'N10': (call + '        fi\n' + rm, call + rm + '        fi\n'),
  'N11': ('out=$(/system/bin/nowhere_db_fix media-insert "$db" "$1" "$list" </dev/null 2>> "$LOG"); rc=$?',
          'out=$(/system/bin/nowhere_db_fix media-insert "$db" "$1" "$list" </dev/null 2>> "$LOG"); rc=$?; echo "$(cat "$list")" >> "$LOG"'),
  'N12': ('local db out rc ni np ns ng mrest own sf found=no list="$STATE/media.rows"', 'found=no; list="$STATE/media.rows"'),
}
if m == 'N8':
    if s.count(call) != 1 or s.count(res) != 1:
        sys.exit('mutant N8 did not apply')
    open(dst, 'w').write(s.replace(call, '', 1).replace(res, call + res, 1))
    sys.exit(0)
a, b = R[m]
if s.count(a) != 1:
    sys.exit('mutant %s did not apply' % m)
open(dst, 'w').write(s.replace(a, b, 1))
PY
}

run_mutants() {
  local m c sh rc bad=0 desc
  for m in N1 N2 N3 N4 N5 N6 N7 N8 N9 N10 N11 N12; do
    case "$m" in
      N1) desc="the OK log text changed (C1)" ;;
      N2) desc="'-' printed as a number (C2)" ;;
      N3) desc="the failure path returns 1 (C3)" ;;
      N4) desc="the empty-list guard removed (C5)" ;;
      N5) desc="the DE directory dropped from the loop (C7)" ;;
      N6) desc="the restorecon of side files removed (C8)" ;;
      N7) desc="the chown of side files removed (C8)" ;;
      N8) desc="the call moved before the #media restore (P1, P3)" ;;
      N9) desc="the call removed (P2)" ;;
      N10) desc="the rm -f moved inside the block (P4)" ;;
      N11) desc="the list's names copied into the log (C9)" ;;
      N12) desc="the helper's variables are not local (C1)" ;;
    esac
    c=$(mktemp -p "$W")
    if ! mutate_to "$m" "$c" || cmp -s "$c" "$SUT"; then echo "  FAIL  $m did not apply: $desc"; bad=1; rm -f "$c"; continue; fi
    for sh in $SHELLS; do
      MIC_SHELLS="$sh" bash "$SELF" "$c" >/dev/null 2>&1; rc=$?
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
