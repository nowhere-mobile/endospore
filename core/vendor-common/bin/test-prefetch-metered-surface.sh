#!/usr/bin/env bash
# test-prefetch-metered-surface.sh [<nowhere_roamd.sh>] [--mutate] -- roamd surfaces the profile's "download over
# mobile data" opt-in into the state dir at sign-in, keyed by the session uid (NWP-20261005-08).
#
# WHY THIS IS COMMITTED. The daemon answered GET-PREFETCH-METERED by reading the roamed user's own file in place,
# /data/user/<uid>/com.nowhere.chooser/files/nowhere-prefetch-metered. vold creates /data/user/<uid> at that user's
# MLS level and the daemon's `nowhere` domain does not dominate it, so every read was refused: on frankel 0.5.41 an
# avc every 30 s (the gate's poll), and the opt-in read as "off" on every enforcing build. The daemon now reads only
# $STATE/prefetch-metered.out, so this surface step is the ONLY way a profile's opt-in reaches it at sign-in. It is
# silent when it regresses -- prefetch just stays Wi-Fi-only -- so this suite pins it.
#
# The block is extracted BY ANCHOR and run against temp dirs; its place in the roam-in is pinned beside the other
# per-profile surfaces (a suite guarding a shell script pins the block, not a spelling).
#
# Each case writes the identity probe, the variables and the block into a run file and executes that file in a CHILD
# of each shell found among bash, sh, dash and mksh (the device's /system/bin/sh). Each run file records the identity
# of the shell that ran it and the suite asserts it is the shell the case launched; a run file that recorded none is a
# HARNESS error (exit 2), never a FAIL. The placement pins (W1, W2) are text checks and run once, tagged [text]. A
# mutant of the block is convicted only when every shell found has its own failing line; a mutant that leaves the block
# as it is and moves it is convicted by the text pins.
#
#   bash test-prefetch-metered-surface.sh            # the cases
#   bash test-prefetch-metered-surface.sh --mutate   # ... plus mutations that must each CONVICT the suite
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

ANCHOR='      # NWP-20261005-08: surface the #129 "download over mobile data" opt-in the same way.'
PREFS='        && cp "$USERDIR/com.nowhere.chooser/files/nowhere-prefs" "$STATE/prefs.out" 2>> "$LOG"'

extract() { awk -v a="$ANCHOR" 'index($0,a)==1{on=1} on{print} on&&/^      fi$/{exit}' "$1"; }

# pins <roamd.sh> -> 0 iff the block sits in its place: text checks, run ONCE (not per shell), tagged [text]
pins() {
  local f="$1" p=0 x=0
  ok(){ p=$((p+1)); printf '  ok    [text] %s\n' "$1"; }
  no(){ x=$((x+1)); printf '  FAIL  [text] %s\n' "$1"; }

  # --- the place, pinned: inside the roam-in, right after the other per-profile surface (prefs.out) ---
  awk -v p="$PREFS" -v a="$ANCHOR" 'prev==p && index($0,a)==1{ok=1} {prev=$0} END{exit ok?0:1}' "$f" \
    && ok "W1 the block follows the prefs.out surface in the roam-in" || no "W1 the block is not right after the prefs.out surface"
  [ "$(grep -cF "$ANCHOR" "$f")" = 1 ] && ok "W2 exactly one surface block" || no "W2 surface block count $(grep -cF "$ANCHOR" "$f")"

  printf '  -- [text] %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

suite() {  # suite <roamd.sh> <shell> -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" s="$2" p=0 x=0 blkf
  ok(){ p=$((p+1)); printf '  ok    [%s] %s\n' "$s" "$1"; }
  no(){ x=$((x+1)); printf '  FAIL  [%s] %s\n' "$s" "$1"; }

  blkf=$(mktemp -p "$W") || return 2
  extract "$f" > "$blkf"
  case "$(cat "$blkf")" in *'prefetch-metered.out'*) ;; *) no "EXTRACTION FAILED -- the surface block moved in $f"; rm -f "$blkf"; return 1 ;; esac
  "$s" -n "$blkf" 2>/dev/null && ok "P1 the block parses under $s -n" || no "P1 the block does not parse under $s -n"
  : > "$W/notrun"; : > "$W/harness"

  # run <file-body|ABSENT> [stale-out] -> the state file's contents after the block runs as session uid 10, in a
  # child of $s that executes a run file holding the identity probe, the variables and the block
  run() {
    local d out
    d=$(mktemp -d -p "$W") || exit 2; mkdir -p "$d/u/com.nowhere.chooser/files" "$d/s"
    [ "$1" = ABSENT ] || printf '%s' "$1" > "$d/u/com.nowhere.chooser/files/nowhere-prefetch-metered"
    [ -z "${2:-}" ] || printf '%s\n' "$2" > "$d/s/prefetch-metered.out"
    {
      printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$d/shell.id")"
      printf '%s\n' "$PRINT_SHIM"
      printf 'USERDIR=%s; STATE=%s; uid=10; LOG=/dev/null\n' "$(sq "$d/u")" "$(sq "$d/s")"
      cat "$blkf"
      printf '%s\n' 'cat "$STATE/prefetch-metered.out" 2>&1'
    } > "$d/run.sh"
    out=$("$s" "$d/run.sh" 2>/dev/null)
    notrun "$s" "$d" || out="${out}NOTRUN"
    rm -rf "$d"
    printf '%s' "$out"
  }

  [ "$(run 1)" = "10 1" ] && ok "S1 an opted-in profile surfaces as '<uid> 1'" || no "S1 got [$(run 1)]"
  [ "$(run "$(printf '1\n')")" = "10 1" ] && ok "S2 a trailing newline is still the opt-in" || no "S2 got [$(run "$(printf '1\n')")]"
  [ "$(run ABSENT)" = "10 0" ] && ok "S3 no file is the Wi-Fi-only default, written as '<uid> 0'" || no "S3 got [$(run ABSENT)]"
  [ "$(run 0)" = "10 0" ] && ok "S4 '0' is Wi-Fi-only" || no "S4 got [$(run 0)]"
  [ "$(run ABSENT '9 1')" = "10 0" ] && ok "S5 an earlier session's opt-in is OVERWRITTEN, not inherited" \
    || no "S5 a previous session's value survived: [$(run ABSENT '9 1')]"
  [ "$(run ' 1')" = "10 0" ] && ok "S6 a blank-padded ' 1' is not the opt-in (a string compare, no trim)" || no "S6 got [$(run ' 1')]"

  rm -f "$blkf"
  if [ -s "$W/harness" ]; then echo "HARNESS ERROR: a run file left no identity: $s did not launch it" >&2; return 2; fi
  # run executes inside $( ), so a case that did not run under $s says so through $W/notrun
  if grep -qx "$s" "$W/notrun"; then no "identity: a case did not run under $s"; else ok "identity: every case ran under $s"; fi
  printf '  -- [%s] %d ok, %d failed\n' "$s" "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "== $SUT"
echo "shells:$SHELLS"
echo "sh identity: $REF_SH"
FAILED=""; HARNESS=""
pins "$SUT" || FAILED=1
for s in $SHELLS; do
  suite "$SUT" "$s"
  case $? in 0) ;; 1) FAILED=1 ;; *) HARNESS=1 ;; esac
done
[ -z "$HARNESS" ] || { echo "HARNESS ERROR"; exit 2; }
[ -z "$FAILED" ] || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED: a mutant of the block under every shell found, a moved block by the text pins)"
mut() { # mut <label> <sed-expr>
  local m o r s conv="" alive="" err=""
  m=$(mktemp -p "$W") || exit 2
  sed -e "$2" "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -f "$m"; return 1; fi
  if [ "$(extract "$m")" = "$(extract "$SUT")" ]; then
    # the block itself is untouched, so the mutant moved it: a text property, judged once by the pins
    o=$(pins "$m" 2>&1); r=$?; rm -f "$m"
    case "$r:$o" in 1:*'FAIL  [text]'*) echo "  convicted $1 -- by the text pins"; return 0 ;; esac
    echo "  SURVIVED  $1 -- the text pins passed"; return 1
  fi
  for s in $SHELLS; do
    o=$(suite "$m" "$s" 2>&1); r=$?
    case "$r" in
      2) err="$err $s" ;;
      1) case "$o" in *"FAIL  [$s]"*) conv="$conv $s" ;; *) alive="$alive $s" ;; esac ;;
      *) alive="$alive $s" ;;
    esac
  done
  rm -f "$m"
  if [ -n "$err" ]; then echo "  HARNESS   $1 -- harness error (not a conviction) under:$err"; return 1; fi
  if [ -n "$alive" ]; then echo "  SURVIVED  $1 -- under:$alive"; return 1; fi
  echo "  convicted $1 -- under:$conv"; return 0
}
# the runner ignores its shell and always runs bash: the identity check must convict it under every non-bash shell
mutate_runner() {
  local s o r cp want="" label="the runner always runs bash"
  cp=$(mktemp -p "$W") || exit 2
  sed 's|^    out=\$("\$s" "\$d/run.sh" 2>/dev/null)$|    out=$(bash "$d/run.sh" 2>/dev/null)|' "$0" > "$cp"
  if cmp -s "$0" "$cp"; then echo "  INERT     $label -- the mutation changed nothing"; rm -f "$cp"; return 1; fi
  for s in $SHELLS; do
    case "$s" in
      bash) ;;
      sh) case "$REF_SH" in bash:*) ;; *) want="$want $s" ;; esac ;;
      *) want="$want $s" ;;
    esac
  done
  [ -n "$want" ] || { echo "  n/a       $label -- no non-bash shell on this host (CI has dash and mksh)"; rm -f "$cp"; return 0; }
  o=$(bash "$cp" "$SUT" 2>&1); r=$?; rm -f "$cp"
  runner_verdict "$label" "$r" "$o" "$want"
}
# runner_verdict <label> <child rc> <child output> <shells>: a conviction needs the child's behavioural failure (rc 1,
# no HARNESS ERROR) AND a FAIL line of its own for each shell named; a harness error or any other rc never convicts
runner_verdict() {
  local s bad=""
  [ "$2" = 1 ] || { echo "  HARNESS   $1 -- the child ended rc $2 (not a conviction)"; return 1; }
  case "$3" in *'HARNESS ERROR'*) echo "  HARNESS   $1 -- the child reported a harness error (not a conviction)"; return 1 ;; esac
  for s in $4; do case "$3" in *"FAIL  [$s]"*) ;; *) bad="$bad $s" ;; esac; done
  if [ -n "$bad" ]; then echo "  SURVIVED  $1 -- under:$bad"; return 1; fi
  echo "  convicted $1 -- under:$4"; return 0
}
# runner_verdict must refuse a child that FAILs every shell and then reports a harness error, and must still convict
# a plain behavioural failure: fed fixed output, so the check needs no non-bash shell
probe_verdict() {
  local f="FAIL  [dash] S1 got [NOTRUN]
FAIL  [mksh] S1 got [NOTRUN]" o
  o=$(runner_verdict p 2 "$f
HARNESS ERROR" " dash mksh") && { echo "  CONVICTED a harness error -- rc 2, FAIL lines under dash mksh"; return 1; }
  o=$(runner_verdict p 1 "$f
HARNESS ERROR" " dash mksh") && { echo "  CONVICTED a harness error -- rc 1 with HARNESS ERROR"; return 1; }
  o=$(runner_verdict p 0 "$f" " dash mksh") && { echo "  CONVICTED a passing child -- rc 0"; return 1; }
  o=$(runner_verdict p 1 "$f" " dash mksh") || { echo "  REFUSED a behavioural failure -- rc 1 under dash mksh: $o"; return 1; }
  o=$(runner_verdict p 1 "FAIL  [dash] S1 got [NOTRUN]" " dash mksh") && { echo "  CONVICTED without a mksh FAIL line"; return 1; }
  echo "  ok        runner_verdict -- a harness error never convicts the runner mutant"; return 0
}
# a child that never launches must end the suite with exit 2 and HARNESS ERROR -- not exit 1 with FAIL lines, which a
# mutation run would count as a conviction
probe() {  # probe <label> <sed program over this suite>
  local cp o r
  cp=$(mktemp -p "$W") || exit 2
  sed "$2" "$0" > "$cp"
  if cmp -s "$0" "$cp"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -f "$cp"; return 1; fi
  o=$(bash "$cp" "$SUT" 2>&1); r=$?; rm -f "$cp"
  case "$r:$o" in 2:*'HARNESS ERROR'*) echo "  ok        $1 -- harness error, not a conviction"; return 0 ;; esac
  echo "  NOT RAISED $1 -- no harness error (rc $r)"; return 1
}
fails=0
mut "M1 surface the bare value, unkeyed"       's|echo "\$uid 1" > "\$STATE/prefetch-metered.out"|echo "1" > "$STATE/prefetch-metered.out"|' || fails=$((fails+1))
mut "M2 opt-in surfaces as off"                's|echo "\$uid 1" > "\$STATE/prefetch-metered.out"|echo "$uid 0" > "$STATE/prefetch-metered.out"|' || fails=$((fails+1))
mut "M3 no else: a stale value survives"       's|echo "\$uid 0" > "\$STATE/prefetch-metered.out"|:|' || fails=$((fails+1))
mut "M4 anything non-empty counts as opt-in"   's|2>/dev/null)" = "1" \]|2>/dev/null)" != "" ]|' || fails=$((fails+1))
mut "M5 the block moves away from the prefs surface" "/^      # NWP-20261005-08: surface the #129/i\\      :" || fails=$((fails+1))
probe "the child never launches" 's|^    out=\$("\$s" "\$d/run.sh" 2>/dev/null)$|    out=$(true)|' || fails=$((fails+1))
probe_verdict || fails=$((fails+1))
mutate_runner || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
