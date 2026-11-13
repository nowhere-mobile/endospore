#!/usr/bin/env bash
# test-media-after-gate-roamd.sh [--mutate] -- NWP-20261202-18: S5 of docs/media-after-gate.md, roamd and mediad.
#
# WHY THIS IS COMMITTED. NOWHERE_MEDIA_AFTER_GATE turns on user media restored after the gate (Q106). Two processes
# read it: the `restore` roamd runs (mediaRestorePlan, S2) and mediad's background lander (startBgLander, S4b). A
# conf flag that a daemon does not export is inert, and a daemon that exports it ON by default ships the feature
# before S7's lynx run. So each daemon exports it exactly once, "0" unless the conf sets it (X1, X2). The in op also
# logs the pre-gate #media restore's wall time, `TIMING restore-media`, which is the number S7 compares: the line
# sits right after the restore and before restore_media_tail, which overwrites _tt (T1-T3), and a user with no media
# dir logs nothing (B1-B3).
#
# The export lines, the in arm and its #media segment are extracted from the daemons BY ANCHOR, never copied (a
# missing anchor stops the suite with EXTRACTION FAILED, exit 2). Each case runs in a CHILD of each shell (bash, sh,
# and dash and mksh where present). A mutant changes a copy of a daemon and this process runs the same cases on it;
# it is CONVICTED under a shell only when every case it names fails there.
#
#   bash test-media-after-gate-roamd.sh            # X1, X2, T1-T3, B1-B3 under every shell found
#   bash test-media-after-gate-roamd.sh --mutate   # ... plus N1-N4, each of which must be convicted under EACH shell
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
ROAMD="${ROAMD:-$HERE/nowhere_roamd.sh}"
MEDIAD="${MEDIAD:-$HERE/nowhere_mediad.sh}"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

RESTORE='        [ -d "$MEDIADIR" ] && { NOWHERE_PHASE=media "$AGENT" restore s3 "${name}#media"'
SKIP='        _mdrc=skip'
BLOCK='        if [ "$_mdrc" = 0 ]; then'

# --- extraction ------------------------------------------------------------------------------------------
# extract <roamd> <mediad> <dir>: writes dir/roamd.exp and dir/mediad.exp (each daemon's export lines of the flag),
# dir/arm (the in arm, comment lines dropped) and dir/seg (from _mdrc=skip to the first line exactly `        fi`).
# Prints why and returns 1 when an anchor is missing.
extract(){
  local r="$1" m="$2" d="$3" n
  [ -f "$r" ] || { echo "no such file: $r"; return 1; }
  [ -f "$m" ] || { echo "no such file: $m"; return 1; }
  grep '^export NOWHERE_MEDIA_AFTER_GATE=' "$r" > "$d/roamd.exp"
  grep '^export NOWHERE_MEDIA_AFTER_GATE=' "$m" > "$d/mediad.exp"
  awk '$0 == "  in)" {f=1} f && $0 !~ /^ *#/ {print} f && $0 == "    ;;" {exit}' "$r" > "$d/arm"
  [ "$(tail -n 1 "$d/arm")" = "    ;;" ] || { echo "the in arm (  in) ... first     ;;) is missing"; return 1; }
  n=$(grep -cF -- "$RESTORE" "$d/arm")
  [ "$n" = 1 ] || { echo "the #media restore line appears $n times in the in arm, want 1"; return 1; }
  RESTORE="$RESTORE" BLOCK="$BLOCK" awk 'index($0, ENVIRON["RESTORE"]) == 1 {f=1} f && $0 == ENVIRON["BLOCK"] {g=1} END {exit !g}' "$d/arm" \
    || { echo "[$BLOCK] does not follow the #media restore line"; return 1; }
  SKIP="$SKIP" awk '$0 == ENVIRON["SKIP"] {f=1} f {print} f && $0 == "        fi" {exit}' "$d/arm" > "$d/seg"
  [ "$(tail -n 1 "$d/seg")" = "        fi" ] || { echo "the #media segment ($SKIP ... fi) is missing"; return 1; }
}

# The checks, run by each shell. $1 = the extraction dir, $2 = the shell itself (for X2's children).
cat > "$W/check.sh" <<'EOF'
d=$1; sh_=$2
say(){ if [ "$1" = 0 ]; then echo "ok $2"; else echo "FAIL $2"; fi; }
# X1: exactly one export of the flag in each daemon.
nr=$(grep -c . "$d/roamd.exp"); nm=$(grep -c . "$d/mediad.exp")
if [ "$nr" = 1 ] && [ "$nm" = 1 ]; then say 0 "X1: one export of the flag in roamd and one in mediad"
else say 1 "X1: exports: roamd $nr, mediad $nm, want 1 each"; fi
# X2: unset -> 0, empty -> 0, 1 -> 1, and exported (a child process sees it).
x2=0; why=""
for f in roamd mediad; do
  line=$(cat "$d/$f.exp")
  [ -n "$line" ] || { x2=1; why="$why $f:no-line"; continue; }
  a=$(env -i PATH="$PATH" "$sh_" -c "$line"'; printenv NOWHERE_MEDIA_AFTER_GATE')
  b=$(env -i PATH="$PATH" NOWHERE_MEDIA_AFTER_GATE= "$sh_" -c "$line"'; printenv NOWHERE_MEDIA_AFTER_GATE')
  c=$(env -i PATH="$PATH" NOWHERE_MEDIA_AFTER_GATE=1 "$sh_" -c "$line"'; printenv NOWHERE_MEDIA_AFTER_GATE')
  [ "$a/$b/$c" = 0/0/1 ] || { x2=1; why="$why $f:unset=[$a],empty=[$b],1=[$c]"; }
done
if [ "$x2" = 0 ]; then say 0 "X2: each export gives 0 unset, 0 empty, 1 for 1, and exports it"
else say 1 "X2:$why"; fi
# T1-T3: the lines around the #media restore in the in arm (comments dropped).
r=$(grep -nF -- '        [ -d "$MEDIADIR" ] && { NOWHERE_PHASE=media "$AGENT" restore s3 "${name}#media"' "$d/arm" | sed 's/:.*//')
case "$r" in ''|*[!0-9]*) r=0 ;; esac
before=$(sed -n "$((r-1))p" "$d/arm"); after=$(sed -n "$((r+1))p" "$d/arm"); next=$(sed -n "$((r+2))p" "$d/arm")
if [ "$before" = '        _tt=$(_ms)' ]; then say 0 "T1: _tt=\$(_ms) directly precedes the #media restore"
else say 1 "T1: the line before the restore is [$before]"; fi
if [ "$after" = '        [ "$_mdrc" = skip ] || _tlog restore-media "$_tt"' ]; then
  say 0 "T2: the guarded _tlog restore-media directly follows the #media restore"
else say 1 "T2: the line after the restore is [$after]"; fi
if [ "$next" = '        if [ "$_mdrc" = 0 ]; then' ]; then say 0 "T3: the _mdrc = 0 block follows the _tlog line"
else say 1 "T3: the line after that is [$next]"; fi
# B1-B3: the segment, run with stubs. restore_media_tail overwrites _tt, as the real one does.
runseg(){
  # runseg <media dir present: yes|no> <agent rc> -> prints the calls, one per line
  t=$(mktemp -d -p "$d") || exit 2
  [ "$1" = yes ] && mkdir "$t/media"
  {
    printf "MEDIADIR='%s/media'; LOG='%s/log'; CALLS='%s/calls'; RC=%s\n" "$t" "$t" "$t" "$2"
    cat <<'EOS'
uid=11; name=p; pass=x; USERDIR=/nonexistent; DEDIR=/nonexistent; AGENT=agentstub
: > "$CALLS"
_ms(){ echo 1000; }
_tlog(){ echo "tlog $1 $2" >> "$CALLS"; }
agentstub(){ echo "agent $1" >> "$CALLS"; return "$RC"; }
pw(){ echo pw; }
restore_media_tail(){ echo "tail" >> "$CALLS"; _tt=999; }
_ssum(){ :; }
insert_deferred_media(){ echo "idm" >> "$CALLS"; }
EOS
    cat "$d/seg"
    printf ': > "%s/ran"\n' "$t"
  } > "$t/run.sh"
  "$sh_" "$t/run.sh" > /dev/null 2>&1
  [ -e "$t/ran" ] || echo "NOT-REACHED"
  cat "$t/calls" 2>/dev/null
}
got=$(runseg no 0)
case "$got" in
  *NOT-REACHED*|*agent*) say 1 "B1: no media dir: [$(echo $got)]" ;;
  *tlog*) say 1 "B1: no media dir still logs TIMING: [$(echo $got)]" ;;
  *) say 0 "B1: no media dir: no restore and no TIMING line" ;;
esac
got=$(runseg yes 0)
n=$(printf '%s\n' "$got" | grep -c '^tlog restore-media ')
first=$(printf '%s\n' "$got" | grep -n '^tlog restore-media 1000$' | sed 's/:.*//')
tl=$(printf '%s\n' "$got" | grep -n '^tail$' | sed 's/:.*//')
case "$first$tl" in ''|*[!0-9]*) first=0; tl=0 ;; esac
if [ "$n" = 1 ] && [ "$first" -gt 0 ] && [ "$tl" -gt "$first" ]; then
  say 0 "B2: restore rc 0: one TIMING restore-media with the restore's own _tt, before restore_media_tail"
else say 1 "B2: calls: [$(echo $got)]"; fi
got=$(runseg yes 5)
n=$(printf '%s\n' "$got" | grep -c '^tlog restore-media 1000$')
case "$got" in
  *NOT-REACHED*) say 1 "B3: the segment did not finish: [$(echo $got)]" ;;
  *) if [ "$n" = 1 ]; then say 0 "B3: restore rc 5: one TIMING restore-media (a failed restore's time is real cost)"
     else say 1 "B3: calls: [$(echo $got)]"; fi ;;
esac
EOF

D0=$(mktemp -d -p "$W") || exit 2
why=$(extract "$ROAMD" "$MEDIAD" "$D0") || { echo "EXTRACTION FAILED: $why" >&2; exit 2; }

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
echo "shells:$SHELLS"

# run_all <shell> <extraction dir>: prints `ok <case>` / `FAIL <case>` lines prefixed with the shell.
run_all(){ "$1" "$W/check.sh" "$2" "$1" 2>&1 | sed "s/^ok /  ok    $1: /; s/^FAIL /  FAIL  $1: /"; }

for s in $SHELLS; do
  echo "== $s =="
  out=$(run_all "$s" "$D0")
  printf '%s\n' "$out"
  PASS=$((PASS+$(printf '%s\n' "$out" | grep -c '^  ok ')))
  FAIL=$((FAIL+$(printf '%s\n' "$out" | grep -c '^  FAIL ')))
done
[ "$FAIL" = 0 ] || { echo "$PASS passed, $FAIL failed (the cases must pass on the unchanged daemons before a mutant means anything)"; exit 1; }

# --- the mutants -----------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo "mutations (each must be convicted by every case it names under EACH shell):"
  # mut <label> <roamd|mediad> <cases, space-separated> <python re pattern> <replacement>: exactly one substitution
  # in a copy of the named daemon, or the mutant fails as NOT APPLIED.
  mut(){
    local label="$1" target="$2" want="$3" r="$ROAMD" m="$MEDIAD" c d s out miss src cs
    c=$(mktemp -p "$W") || exit 2
    case "$target" in roamd) src="$ROAMD"; r="$c" ;; mediad) src="$MEDIAD"; m="$c" ;; esac
    if ! python3 - "$src" "$c" "$4" "$5" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
out, n = re.subn(sys.argv[3], sys.argv[4], src, flags=re.M)
open(sys.argv[2], "w").write(out)
sys.exit(0 if n == 1 and out != src else 1)
PY
    then no "MUTANT DID NOT APPLY: $label"; return; fi
    d=$(mktemp -d -p "$W") || exit 2
    if ! out=$(extract "$r" "$m" "$d"); then no "MUTANT BROKE THE EXTRACTION ($out): $label"; return; fi
    for s in $SHELLS; do
      out=$(run_all "$s" "$d"); miss=""
      for cs in $want; do
        case "$out" in *"FAIL  $s: $cs:"*) ;; *) miss="$miss $cs" ;; esac
      done
      if [ -z "$miss" ]; then ok "convicted under $s by $want: $label"
      else no "SURVIVED under $s (want$miss to fail): $label"; printf '%s\n' "$out" | grep FAIL | sed 's/^/      /'; fi
    done
  }
  mut 'N1 mediad export removed' mediad X1 '^export NOWHERE_MEDIA_AFTER_GATE=[^\n]*\n' ''
  mut "N2 roamd's default 1" roamd X2 '^(export NOWHERE_MEDIA_AFTER_GATE="\$\{NOWHERE_MEDIA_AFTER_GATE:-)0\}"' '\g<1>1}"'
  mut 'N3 the skip guard dropped' roamd 'T2 B1' '^( *)\[ "\$_mdrc" = skip \] \|\| (_tlog restore-media)' '\1\2'
  mut 'N4 the _tlog moved after restore_media_tail' roamd 'T2 B2' '^( *\[ "\$_mdrc" = skip \] \|\| _tlog restore-media "\$_tt"\n)((?:[^\n]*\n)*?)( *restore_media_tail "\$MEDIADIR"\n)' '\2\3\1'
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
