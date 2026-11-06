#!/usr/bin/env bash
# test-restore-tail-progress.sh [<nowhere_roamd.sh>] [--mutate] -- the post-#media tail of roamd's `in` op reports
# progress (NWP-20261017-05).
#
# WHY THIS IS COMMITTED. remap_tree, `restorecon -R -D` over the media tree, the ext-appdata re-own and the dir chmod
# wrote nothing to $NOWHERE_PROGRESS, so on a large profile the daemon's stall watchdog saw an unchanged file for most
# of the 15-minute `in` budget and reaped the sign-in. restore_media_tail now writes `finishing <i> <n>` before every
# step and before each Android/{data,obb}/<pkg> re-own (n = 3 + k).
#
# restore_media_tail and _restore_tail_prog are extracted from nowhere_roamd.sh BY NAME, never copied; the four steps,
# _tlog and _ms are stubs that record calls, and `mv` is wrapped so every value the progress file takes is captured.
#
# Each behaviour case writes the extracted functions, its variables and the stubs into a run file and executes that
# file in a CHILD of each shell found among bash, sh, dash and mksh (the device's /system/bin/sh), so the step count's
# arithmetic is evaluated the way each shell evaluates it (NWP-20261113-42). Each run file records the identity of the
# shell that ran it and the suite asserts it is the shell the case launched; a run file that records none is a HARNESS
# error (exit 2), never a FAIL. The call-site pin (T4) is text and runs once. A behaviour mutant is convicted only when
# every shell found has its own FAIL line.
#
#   bash test-restore-tail-progress.sh            # the behaviour cases
#   bash test-restore-tail-progress.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every temp of the run lives inside W.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=""; for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
IDPROBE='_id="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; [ -n "$_id" ] || _id=posix; _pr=none; command -v print >/dev/null 2>&1 && _pr=builtin'
REF_SH=""; command -v sh >/dev/null 2>&1 && REF_SH=$(sh -c "$IDPROBE; printf '%s|%s\n' \"\$_id\" \"\$_pr\"")
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
sq(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
runsh(){ "$1" "$2" >/dev/null 2>&1; }
# idok <shell> <id file> -> 0 iff the file holds at least one line and every line is that shell's identity
idok(){
  local s="$1" f="$2" l n=0
  [ -s "$f" ] || return 1
  while IFS= read -r l; do
    n=$((n+1))
    case "$s" in
      bash) case "$l" in bash:*'|none') ;; *) return 1 ;; esac ;;
      dash) [ "$l" = 'posix|none' ] || return 1 ;;
      mksh) case "$l" in 'ksh:|'*) return 1 ;; ksh:?*'|builtin') ;; *) return 1 ;; esac ;;
      sh)   [ "$l" = "$REF_SH" ] || return 1 ;;
      *)    return 1 ;;
    esac
  done < "$f"
  [ "$n" -gt 0 ]
}
# notrun <shell> <case dir>: a run file that recorded no identity never launched -- a HARNESS error (noted in
# $W/harness, which suite turns into exit 2), never a behavioural FAIL a mutant could be convicted by. One that recorded
# the WRONG shell is noted in $W/notrun for suite's per-shell FAIL line.
notrun() {
  [ -s "$2/shell.id" ] || { echo "$1" >> "$W/harness"; return 1; }
  idok "$1" "$2/shell.id" || { echo "$1" >> "$W/notrun"; return 1; }
}

extract() {
  sed -n '/^_restore_tail_prog() {$/,/^}$/p' "$1"
  sed -n '/^restore_media_tail() {$/,/^}$/p' "$1"
}

# run_case <shell> <block-file> <k_data> <k_obb> <progress: set|unset> -> events, one per line:
#   "P <value>" for each progress write, "S <step>" for each step stub, in order; then "NOTRUN" when the run file did
#   not run under <shell>
run_case() {
  local sh="$1" blk="$2" kd="$3" ko="$4" prog="$5" d i np=""
  d=$(mktemp -d -p "$W") || exit 2
  mkdir -p "$d/m/Android/data" "$d/m/Android/obb"
  for ((i=1; i<=kd; i++)); do mkdir "$d/m/Android/data/pkg.d$i"; done
  for ((i=1; i<=ko; i++)); do mkdir "$d/m/Android/obb/pkg.o$i"; done
  : > "$d/ev"
  [ "$prog" = set ] && np="$d/roam.progress"
  {
    printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$d/shell.id")"
    printf '%s\n' "$PRINT_SHIM"
    printf 'd=%s; LOG=%s; NOWHERE_PROGRESS=%s\n' "$(sq "$d")" "$(sq "$d/log")" "$(sq "$np")"
    cat <<'STUB'
mv() { [ "$1" = -f ] && shift; echo "P $(cat "$1")" >> "$d/ev"; command mv -f "$1" "$2"; }
remap_tree() { echo "S remap" >> "$d/ev"; }
restorecon() { echo "S restorecon" >> "$d/ev"; }
reown_ext_appdata() { echo "S reown $1" >> "$d/ev"; }
find() { echo "S chmod" >> "$d/ev"; }
_tlog() { :; }
_ms() { echo 0; }
STUB
    cat "$blk"
    printf 'restore_media_tail "$d/m"\n'
  } > "$d/run.sh"
  runsh "$sh" "$d/run.sh"
  cat "$d/ev"
  notrun "$sh" "$d" || echo NOTRUN
  rm -rf "$d"
}

suite() {  # suite <roamd.sh> <shell> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" s="$2" quiet="${3:-}" b p=0 x=0 out want
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$s" "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$s" "$1"; }
  b=$(mktemp -p "$W") || return 2
  extract "$f" > "$b"
  if ! grep -q '^restore_media_tail() {$' "$b" || ! grep -q '^_restore_tail_prog() {$' "$b" || ! bash -n "$b"; then
    echo "EXTRACTION FAILED: restore_media_tail / _restore_tail_prog missing or unparsable in $f" >&2; rm -f "$b"; return 2
  fi
  if ! "$s" -n "$b"; then
    echo "EXTRACTION FAILED: restore_media_tail / _restore_tail_prog do not parse under $s in $f" >&2; rm -f "$b"; return 2
  fi
  : > "$W/notrun"; : > "$W/harness"

  out=$(run_case "$s" "$b" 3 1 set)
  want=$(printf '%s\n' 'P finishing 1 7' 'S remap' 'P finishing 2 7' 'S restorecon' 'P finishing 3 7' 'S reown pkg.d1' \
    'P finishing 4 7' 'S reown pkg.d2' 'P finishing 5 7' 'S reown pkg.d3' 'P finishing 6 7' 'S reown pkg.o1' \
    'P finishing 7 7' 'S chmod')
  [ "$out" = "$want" ] && ok "T1 3 data + 1 obb: finishing 1..7 of 7, each before its step, steps in order" \
    || no "T1 got: $(echo "$out" | tr '\n' ';')"

  out=$(run_case "$s" "$b" 0 0 set)
  want=$(printf '%s\n' 'P finishing 1 3' 'S remap' 'P finishing 2 3' 'S restorecon' 'P finishing 3 3' 'S chmod')
  [ "$out" = "$want" ] && ok "T2 no Android dirs: exactly finishing 1 3, 2 3, 3 3" || no "T2 got: $(echo "$out" | tr '\n' ';')"

  out=$(run_case "$s" "$b" 3 1 unset)
  want=$(printf '%s\n' 'S remap' 'S restorecon' 'S reown pkg.d1' 'S reown pkg.d2' 'S reown pkg.d3' 'S reown pkg.o1' 'S chmod')
  [ "$out" = "$want" ] && ok "T3 NOWHERE_PROGRESS unset: nothing written, steps still run" || no "T3 got: $(echo "$out" | tr '\n' ';')"

  rm -f "$b"
  if [ -s "$W/harness" ]; then echo "HARNESS ERROR: a run file left no identity: $s did not launch it" >&2; return 2; fi
  # run_case runs inside $( ), so a case that did not run under $s says so through $W/notrun
  if grep -qx "$s" "$W/notrun"; then no "identity: a case did not run under $s"; else ok "identity: every case ran under $s"; fi
  [ -n "$quiet" ] || printf '  -- [%s] %s passed, %s failed\n' "$s" "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

textpins() {  # textpins <roamd.sh> [quiet] -> 0 all ok, 1 a pin failed; shell-independent, run once
  local f="$1" quiet="${2:-}" p=0 x=0
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [text] %s\n' "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [text] %s\n' "$1"; }
  if [ "$(grep -c '^ *restore_media_tail "\$MEDIADIR"$' "$f")" = 1 ]; then ok "T4 the in op calls restore_media_tail once"
  else no "T4 the in op does not call restore_media_tail exactly once"; fi
  [ -n "$quiet" ] || printf '  -- [text] %s passed, %s failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "restore tail progress: $SUT"
echo "shells:$SHELLS"
echo "sh identity: $REF_SH"
rc=0
textpins "$SUT" || rc=1
for s in $SHELLS; do
  suite "$SUT" "$s"; r=$?
  [ "$r" -gt "$rc" ] && rc=$r
done
[ "$rc" -eq 0 ] || exit "$rc"
[ "$MUTATE" = yes ] || exit 0

echo "-- mutations (each must fail the suite, under every shell found) --"
bad=0
mtmp=$(mktemp -d -p "$W") || exit 2
mutant() {  # mutant <beh|text> <name> <python-snippet operating on string s>
  local kind="$1" name="$2" m out r s alive="" err=""
  m=$(mktemp -p "$mtmp") || exit 2
  python3 - "$SUT" "$m" "$3" <<'PY'
import sys
s=open(sys.argv[1]).read(); o=s
exec(sys.argv[3])
if s==o: sys.exit(3)
open(sys.argv[2],'w').write(s)
PY
  if [ $? -ne 0 ]; then echo "  MUTANT $name did not apply"; bad=1; rm -f "$m"; return; fi
  if [ "$kind" = text ]; then
    textpins "$m" quiet; r=$?
    if [ "$r" -eq 1 ]; then echo "  convicted [text]  $name"; else echo "  NOT CONVICTED ($r) [text]  $name"; bad=1; fi
    rm -f "$m"; return
  fi
  # a behaviour mutant convicts under a shell only with rc 1 AND that shell's own FAIL line
  for s in $SHELLS; do
    out=$(suite "$m" "$s" 2>&1); r=$?
    case "$r" in
      1) case "$out" in *"FAIL  [$s]"*) ;; *) alive="$alive $s" ;; esac ;;
      0) alive="$alive $s" ;;
      *) err="$err $s" ;;
    esac
  done
  if [ -n "$alive" ]; then echo "  NOT CONVICTED under:$alive  $name"; bad=1
  elif [ -n "$err" ]; then echo "  harness error (not a conviction) under:$err  $name"; bad=1
  else echo "  convicted under every shell  $name"; fi
  rm -f "$m"
}
mutant beh "restorecon progress call removed" 's=s.replace("  _restore_tail_prog 2 \"$_rt_n\"\n","",1)'
mutant beh "remap_tree progress call removed" 's=s.replace("  _restore_tail_prog 1 \"$_rt_n\"\n","",1)'
mutant beh "chmod progress call removed" 's=s.replace("  _restore_tail_prog \"$_rt_n\" \"$_rt_n\"\n","",1)'
mutant beh "per-package progress call removed" 's=s.replace("_rt_i=$((_rt_i+1)); _restore_tail_prog \"$_rt_i\" \"$_rt_n\"","_rt_i=$((_rt_i+1))",1)'
mutant beh "n does not count obb" 's=s.replace("for _ed in \"$_md\"/Android/data/* \"$_md\"/Android/obb/*; do\n    [ -d \"$_ed\" ] && _rt_n","for _ed in \"$_md\"/Android/data/*; do\n    [ -d \"$_ed\" ] && _rt_n",1)'
mutant text "restore_media_tail call removed from the in op" 's=s.replace("        restore_media_tail \"$MEDIADIR\"\n","",1)'
# NWP-20261113-42: a step count that is not a number. mksh reads an unset name as 0 in arithmetic where dash aborts,
# so the conviction must come from each shell's own line (T2 does no arithmetic and writes the value verbatim).
mutant beh "_rt_n is not a number" 's=s.replace("  _rt_n=3\n","  _rt_n=x3\n",1)'

# harness-error probe: a child that never launches must end the suite with exit 2 and HARNESS ERROR -- not exit 1
# with FAIL lines, which a mutation run would count as a conviction
probe() {  # probe <label> <sed program over this suite>
  local cp="$mtmp/suite-probe.sh" r
  sed "$2" "$0" > "$cp"
  if cmp -s "$0" "$cp"; then echo "  SKIP (mutation was a NO-OP)  $1"; bad=1; return; fi
  bash "$cp" "$SUT" > "$mtmp/probe.out" 2>&1; r=$?
  if [ "$r" -eq 2 ] && grep -q 'HARNESS ERROR' "$mtmp/probe.out"; then echo "  harness error, not a conviction  $1"
  else echo "  HARNESS ERROR NOT RAISED (rc $r)  $1"; bad=1; fi
}
# runner_verdict <suite copy> <shell>...: run the copy; it convicts only when it exits 1 (exit 2 is a HARNESS error, never
# a conviction) and printed its own FAIL line for each shell named. Prints the shells that missed; returns 0 on conviction.
runner_verdict() {
  local cp="$1" s r miss=""; shift
  bash "$cp" "$SUT" > "$mtmp/runner.out" 2>&1; r=$?
  [ "$r" -eq 1 ] || miss=" (rc $r, not 1)"
  grep -q 'HARNESS ERROR' "$mtmp/runner.out" && miss="$miss (HARNESS ERROR)"
  for s in "$@"; do grep -q "FAIL  \[$s\]" "$mtmp/runner.out" || miss="$miss $s"; done
  printf '%s' "$miss"; [ -z "$miss" ]
}
# the runner ignores its shell argument and always runs bash: the identity check must convict it under every non-bash shell
mutate_runner() {
  local s miss="" want="" cp="$mtmp/suite-runner.sh"
  sed 's/^runsh(){ "\$1" "\$2"/runsh(){ bash "$2"/' "$0" > "$cp"
  if cmp -s "$0" "$cp"; then echo "  SKIP (mutation was a NO-OP)  the runner always runs bash"; bad=1; return; fi
  for s in $SHELLS; do
    case "$s" in
      bash) ;;
      sh) case "$REF_SH" in bash:*) ;; *) want="$want $s" ;; esac ;;
      *) want="$want $s" ;;
    esac
  done
  [ -n "$want" ] || { echo "  n/a (no non-bash shell on this host; CI has dash and mksh)  the runner always runs bash"; return; }
  # shellcheck disable=SC2086
  if miss=$(runner_verdict "$cp" $want); then echo "  convicted under:$want  the runner always runs bash"
  else echo "  NOT CONVICTED under:$miss  the runner always runs bash"; bad=1; fi
}
# the verdict itself: a child that never launches prints a FAIL line per shell and exits 2; runner_verdict must refuse it
verdict_refuses_harness_error() {
  local cp="$mtmp/suite-nolaunch.sh" miss
  sed 's/^runsh(){ .*$/runsh(){ return 127; }/' "$0" > "$cp"
  if cmp -s "$0" "$cp"; then echo "  SKIP (mutation was a NO-OP)  runner_verdict refuses a harness error"; bad=1; return; fi
  # shellcheck disable=SC2086
  if miss=$(runner_verdict "$cp" $SHELLS); then echo "  HARNESS ERROR COUNTED AS A CONVICTION  runner_verdict refuses a harness error"; bad=1
  else echo "  refused:$miss  runner_verdict refuses a harness error"; fi
}
probe 'the child never launches' 's/^runsh(){ .*$/runsh(){ return 127; }/'
verdict_refuses_harness_error
mutate_runner
[ "$bad" = 0 ] && echo "ALL MUTATIONS BEHAVED" || echo "PROBLEM: a mutation did not behave"
exit "$bad"
