#!/usr/bin/env bash
# test-fido2-adopt-op.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's `fido2adopt` op (NWP-20261111-04, Q016), run for real.
#
# The op is the stranded phone's "Use your security key": a key enrolled on ANOTHER handset dropped the head's pass
# slot, so this live session can no longer seal until it adopts that key. The agent's `fido2-adopt` prints the hmac
# only when the asserted key opens a fido2 slot of the current head, and stages the slot spec as .fido2slots.pre only
# then. The properties pinned here are silent when broken:
#   - success writes the hmac to the 0600 stash with `print -rn --`, never printf: printf is an EXTERNAL binary on
#     Android, so the hmac -- the second vault factor -- would land in /proc/<pid>/cmdline (#106).
#   - success promotes .fido2slots.pre over .fido2slots, so a later cold lock's marker carries the adopted key's spec.
#   - a FAILED adopt leaves .fido2hmac and .fido2slots byte-identical: a wrong touch must not cost the session the
#     stash it had (the cold re-assert purges; this op must not). Only a .pre this attempt did not prove is removed.
#   - usb_host off runs on both outcomes; an empty name or passphrase answers ERR-ARGS before the agent or USB runs.
#   - the hmac reaches neither an argv nor the log; the passphrase reaches the agent only as `@file:`.
#
# pw(), qn() and the op block are extracted from nowhere_roamd.sh BY ANCHOR, never copied; if an anchor moves,
# extraction fails loudly (exit 2). usb_host is STUBBED (it records on/off); test-fido2-enroll-op.sh runs the real one.
# printf is stubbed as a function that records its argv, standing in for the external binary; the print shim (for a
# shell with no print of its own) uses `command printf`, so only a printf the op itself calls is recorded.
#
# Each case writes its block, variables and stubs into a run file and executes it in a CHILD of each shell found among
# bash, sh, dash and mksh (the device's /system/bin/sh). Each run file records the identity of the shell that ran it,
# and the suite asserts it is the shell the case launched. A mutant is convicted only when it fails under EVERY shell.
#
#   bash test-fido2-adopt-op.sh            # the behaviour cases
#   bash test-fido2-adopt-op.sh --mutate   # ... plus mutations that must each CONVICT the suite
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
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
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then command printf "%s\n" "$*"; else command printf "%s" "$*"; fi; }'
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

fn(){  # fn <file> <name>: a column-0 function, from its opener to its closing column-0 }
  awk -v o="$2() {" '$0 == o { on = 1 } on { print } on && $0 == "}" { exit }' "$1"
}
extract() {  # extract <roamd.sh> <op>
  sed -n "/^if \\[ \"\\\$op\" = \"$2\" \\]; then\$/,/^fi\$/p" "$1"
}

HMAC=a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90
OLDHMAC=0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0
OLDSPEC='b2xkY3JlZA==:b2xkc2FsdA==:0'
NEWSPEC='bmV3Y3JlZA==:bmV3c2FsdA==:0'
STALEPRE='c3RhbGVjcmVk:c3RhbGVzYWx0:0'
SECRET='p@ss\w0rd -n Zq9'

# run_adopt <shell> <block-file> <mode: ok|fail> <name> <pass> <pre: full|nostash|stalepre>  -> sets D (the case dir)
#   D/state is roamd's $STATE: full = .fido2hmac (OLDHMAC, no newline) + .fido2slots (OLDSPEC); stalepre adds a
#   .fido2slots.pre (STALEPRE) an abandoned earlier attempt left; nostash = neither. The stub agent records its argv
#   (D/agent.argv), copies its @file: (D/passfile) and, in mode ok, stages NEWSPEC as .pre and prints HMAC the way the
#   CLI does (one line); in mode fail it prints nothing on stdout and exits 1. D/usb is usb_host's on/off sequence,
#   D/ext.argv every argv the op handed printf.
run_adopt() {
  local sh="$1" blk="$2" mode="$3" nm="$4" pw_="$5" pre="$6" r
  D=$(mktemp -d -p "$W") || exit 2; mkdir "$D/state"
  case "$pre" in
    full|stalepre)
      printf '%s' "$OLDHMAC" > "$D/state/.fido2hmac"; chmod 600 "$D/state/.fido2hmac"
      printf '%s\n' "$OLDSPEC" > "$D/state/.fido2slots"
      cp -p "$D/state/.fido2hmac" "$D/before.hmac"; cp -p "$D/state/.fido2slots" "$D/before.slots" ;;
  esac
  [ "$pre" = stalepre ] && printf '%s\n' "$STALEPRE" > "$D/state/.fido2slots.pre"
  printf '%s' "$mode" > "$D/mode"
  {
    printf '#!/bin/sh\nd=%s\n' "$(sq "$D")"
    cat <<'STUB'
: > "$d/ran"
for x in "$@"; do printf '%s\n' "$x"; done > "$d/agent.argv"
case "$4" in @file:*) cat "${4#@file:}" > "$d/passfile" ;; esac
if [ "$(cat "$d/mode")" = ok ]; then
STUB
    printf '  printf "%%s\\n" %s > "$5/.fido2slots.pre"\n  printf "%%s\\n" %s\n' "$(sq "$NEWSPEC")" "$(sq "$HMAC")"
    cat <<'STUB'
  exit 0
fi
echo "fido2-adopt: the key did not unlock this profile" >&2
exit 1
STUB
  } > "$D/agent"
  chmod +x "$D/agent"
  # The run file holds the passphrase (pass=), so it lives OUTSIDE $D: the leak checks below scan $D.
  r=$(mktemp -p "$W") || exit 2
  {
    printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$D/shell.id")"
    printf '%s\n' "$PRINT_SHIM"
    printf 'd=%s; RES=%s; LOG=%s; STATE=%s; AGENT=%s; LANE=rw; op=fido2adopt; name=%s; pass=%s\n' \
      "$(sq "$D")" "$(sq "$D/res")" "$(sq "$D/log")" "$(sq "$D/state")" "$(sq "$D/agent")" "$(sq "$nm")" "$(sq "$pw_")"
    cat <<'STUB'
: > "$LOG"
usb_host() { echo "$1" >> "$d/usb"; }
sleep() { :; }
printf() { for _a in "$@"; do command printf '%s\n' "$_a"; done >> "$d/ext.argv"; command printf "$@"; }
STUB
    printf '%s\n%s\n' "$PW" "$QN"
    cat "$blk"
  } > "$r"
  runsh "$sh" "$r"
  rm -f "$r"
}
fmode(){ stat -c %a "$1" 2>/dev/null || ls -l "$1" | awk '{ print $1 }'; }
nonl(){ [ -s "$1" ] && [ "$(tail -c 1 "$1" | od -An -c | tr -d ' ')" != '\n' ]; }

suite() {  # suite <roamd.sh> <shell> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" s="$2" quiet="${3:-}" blk p=0 x=0 pair nm pw_ line rest NM TOK verb mode
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$s" "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$s" "$1"; }
  eq() { [ "$1" = "$2" ] && ok "$3" || no "$3 (got '$1', want '$2')"; }
  PW=$(fn "$f" pw); QN=$(fn "$f" qn)
  case "$PW" in *'@file:'*) ;; *) echo "EXTRACTION FAILED: pw in $f" >&2; return 2 ;; esac
  case "$QN" in *'sed '*) ;; *) echo "EXTRACTION FAILED: qn in $f" >&2; return 2 ;; esac
  blk=$(mktemp -p "$W") || return 2
  extract "$f" fido2adopt > "$blk"
  case "$(cat "$blk")" in *'fido2-adopt s3'*'.fido2hmac'*) ;;
    *) echo "EXTRACTION FAILED: the fido2adopt op in $f" >&2; rm -f "$blk"; return 2 ;; esac
  if ! bash -n "$blk" || ! "$s" -n "$blk"; then
    echo "EXTRACTION FAILED: the fido2adopt op does not parse under $s in $f" >&2; rm -f "$blk"; return 2
  fi
  : > "$W/notrun"; : > "$W/harness"

  # O1: the key opens a slot of the current head -> adopted
  run_adopt "$s" "$blk" ok alice "$SECRET" full
  eq "$(cat "$D/res" 2>/dev/null)" OK "O1 RES is OK"
  eq "$(cat "$D/state/.fido2hmac" 2>/dev/null)" "$HMAC" "O1 .fido2hmac holds the asserted hmac"
  nonl "$D/state/.fido2hmac" && ok "O1 .fido2hmac has no trailing newline (byte-identical to what loadFido2HmacEnv reads)" \
    || no "O1 .fido2hmac is empty or ends in a newline"
  eq "$(fmode "$D/state/.fido2hmac")" 600 "O1 .fido2hmac is mode 600"
  eq "$(cat "$D/state/.fido2slots" 2>/dev/null)" "$NEWSPEC" "O1 .fido2slots is replaced by the staged .pre"
  [ ! -e "$D/state/.fido2slots.pre" ] && ok "O1 no .fido2slots.pre is left" || no "O1 a .fido2slots.pre is left"
  eq "$(tr '\n' ' ' < "$D/usb" 2>/dev/null)" "on off " "O1 usb_host on, then off"
  eq "$(sed -n 1p "$D/agent.argv")|$(sed -n 2p "$D/agent.argv")|$(sed -n 3p "$D/agent.argv")|$(sed -n 5p "$D/agent.argv")|$(wc -l < "$D/agent.argv" | tr -d ' ')" \
    "fido2-adopt|s3|alice|$D/state|5" "O1 argv is fido2-adopt s3 <name> <pass> <statedir>"
  case "$(sed -n 4p "$D/agent.argv")" in @file:*) ok "O1 the passphrase argument is an @file: reference" ;;
    *) no "O1 the passphrase argument is '$(sed -n 4p "$D/agent.argv")'" ;; esac
  eq "$(cat "$D/passfile" 2>/dev/null)" "$SECRET" "O1 the @file: held the passphrase"
  # O4: the hmac reaches no argv and not the log; the passphrase not the log either
  grep -qF -- "$HMAC" "$D/agent.argv" && no "O4 the hmac is in the agent's argv" || ok "O4 the hmac is in no agent argument"
  grep -qF -- "$HMAC" "$D/log" && no "O4 the hmac reached the log" || ok "O4 the hmac is not in the log"
  grep -qF -- "$HMAC" "$D/ext.argv" 2>/dev/null && no "O4 the hmac was handed to printf, an external binary on the device (#106)" \
    || ok "O4 the hmac was never handed to printf (an external binary on the device)"
  grep -qF -- "$SECRET" "$D/agent.argv" "$D/log" && no "O4 the passphrase reached an argv or the log" \
    || ok "O4 the passphrase is in neither an argv nor the log"
  notrun "$s" "$D"; rm -rf "$D"

  # O2: the key opens nothing -> the session keeps exactly what it had
  run_adopt "$s" "$blk" fail alice "$SECRET" stalepre
  eq "$(cat "$D/res" 2>/dev/null)" ERR-NOKEY "O2 RES is ERR-NOKEY"
  cmp -s "$D/before.hmac" "$D/state/.fido2hmac" && ok "O2 .fido2hmac is byte-identical to before" \
    || no "O2 a failed adopt changed or removed .fido2hmac (the session lost its stash)"
  cmp -s "$D/before.slots" "$D/state/.fido2slots" && ok "O2 .fido2slots is byte-identical to before" \
    || no "O2 a failed adopt changed or removed .fido2slots"
  [ ! -e "$D/state/.fido2slots.pre" ] && ok "O2 the stale .fido2slots.pre is removed" || no "O2 a .fido2slots.pre is left"
  eq "$(tr '\n' ' ' < "$D/usb" 2>/dev/null)" "on off " "O2 usb_host on, then off after a failure"
  grep -qF 'fido2adopt FAILED for' "$D/log" && ok "O2 the failure is logged" || no "O2 no FAILED line in the log"
  notrun "$s" "$D"; rm -rf "$D"
  run_adopt "$s" "$blk" fail alice "$SECRET" nostash
  eq "$(cat "$D/res" 2>/dev/null)" ERR-NOKEY "O2b no prior stash: RES is ERR-NOKEY"
  [ ! -e "$D/state/.fido2hmac" ] && [ ! -e "$D/state/.fido2slots" ] && ok "O2b no prior stash: a failure creates none" \
    || no "O2b a failure created a stash"
  notrun "$s" "$D"; rm -rf "$D"

  # O3: no name or no passphrase -> ERR-ARGS, nothing run
  for pair in ":$SECRET" "alice:"; do
    nm="${pair%%:*}"; pw_="${pair#*:}"
    run_adopt "$s" "$blk" ok "$nm" "$pw_" full
    eq "$(cat "$D/res" 2>/dev/null)" ERR-ARGS "O3 name='$nm' pass-empty=$([ -z "$pw_" ] && echo yes || echo no): ERR-ARGS"
    [ ! -e "$D/ran" ] && ok "O3 the agent never ran" || no "O3 the agent ran"
    [ ! -e "$D/usb" ] && ok "O3 usb_host never ran" || no "O3 usb_host ran"
    cmp -s "$D/before.hmac" "$D/state/.fido2hmac" && ok "O3 .fido2hmac untouched" || no "O3 .fido2hmac changed"
    notrun "$s" "$D"; rm -rf "$D"
  done

  # O5: the name reaches the log only through qn's quoting, on both outcomes
  NM='a b"c'; TOK='"a b\"c"'
  for mode in ok fail; do
    run_adopt "$s" "$blk" "$mode" "$NM" "$SECRET" full
    verb=OK; [ "$mode" = fail ] && verb=FAILED
    line=$(grep -F "fido2adopt $verb for" "$D/log" | head -1)
    case "$line" in *"fido2adopt $verb for $TOK"*) ok "O5 $verb line carries the name as one escaped quoted token" ;;
      *) no "O5 $verb line is '$line'" ;; esac
    rest=$(cat "$D/log"); rest=${rest//"$TOK"/}
    case "$rest" in *'a b'*|*'c"'*) no "O5 $verb: the name appears outside qn's quoting" ;;
      *) ok "O5 $verb: the name appears only inside qn's quoting" ;; esac
    notrun "$s" "$D"; rm -rf "$D"
  done

  rm -f "$blk"
  if [ -s "$W/harness" ]; then echo "HARNESS ERROR: a run file left no identity: $s did not launch it" >&2; return 2; fi
  if grep -qx "$s" "$W/notrun"; then no "identity: a case did not run under $s"; else ok "identity: every case ran under $s"; fi
  [ -n "$quiet" ] || printf '  -- [%s] %d ok, %d failed\n' "$s" "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "roamd fido2adopt op: $SUT"
echo "shells:$SHELLS"
echo "sh identity: $REF_SH"
for s in $SHELLS; do
  suite "$SUT" "$s"; rc=$?
  [ "$rc" = 0 ] || FAILED=$(( rc > ${FAILED:-0} ? rc : ${FAILED:-0} ))
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT under every shell found):"
  mtmp=$(mktemp -d -p "$W") || exit 2
  R='/^if \[ "\$op" = "fido2adopt" \]; then$/,/^fi$/'
  mutate() {  # <label> <sed program, applied inside the fido2adopt block>
    local label="$1" prog="$2" mf="$mtmp/r.sh" r s alive="" err=""
    if ! sed -E "$R { $prog }" "$SUT" > "$mf"; then printf '  ERR   %-64s sed program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    for s in $SHELLS; do
      suite "$mf" "$s" quiet >/dev/null 2>&1; r=$?
      case "$r" in
        0) alive="$alive $s" ;;
        1) ;;
        *) err="$err $s" ;;
      esac
    done
    if [ -n "$alive" ]; then printf '  XX    %-64s SURVIVED under:%s\n' "$label" "$alive"; MFAIL=1
    elif [ -n "$err" ]; then printf '  ERR   %-64s harness error (not a conviction) under:%s\n' "$label" "$err"; MFAIL=1
    else printf '  ok    %-64s convicted under every shell (%s )\n' "$label" "$SHELLS"; fi
  }
  mutate 'M1 printf writes the hmac (an external binary: argv)'          's@print -rn -- "\$H" >@printf '"'"'%s'"'"' "$H" >@'
  mutate 'M2 .fido2hmac is removed on failure'                            's@^(    rm -f "\$STATE/\.fido2slots\.pre")@\1 "$STATE/.fido2hmac"@'
  mutate 'M3 the .pre is not promoted'                                    '/mv "\$STATE\/\.fido2slots\.pre" "\$STATE\/\.fido2slots"/d'
  mutate 'M4 usb_host is left on'                                         '/^  usb_host off$/d'
  mutate 'M5 the stale .pre is left on failure'                           '/^    rm -f "\$STATE\/\.fido2slots\.pre"/d'
  mutate 'M6 the ERR-ARGS guard is removed'                               '/ERR-ARGS/d'
  mutate 'M7 bare name in the FAILED line'                                '/FAILED for/ s@\$\(qn "\$name"\)@$name@'
  mutate 'M8 the passphrase is passed in argv'                            's@"\$\(pw "\$pass"\)"@"$pass"@'
  # the runner ignores its shell argument and always runs bash: the identity check must convict it under every non-bash shell
  mutate_runner() {
    local s bad="" want="" cp="$mtmp/suite-runner.sh"
    sed 's/^runsh(){ "\$1" "\$2"/runsh(){ bash "$2"/' "$0" > "$cp"
    if cmp -s "$0" "$cp"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "the runner always runs bash"; MFAIL=1; return; fi
    for s in $SHELLS; do
      case "$s" in
        bash) ;;
        sh) case "$REF_SH" in bash:*) ;; *) want="$want $s" ;; esac ;;
        *) want="$want $s" ;;
      esac
    done
    [ -n "$want" ] || { printf '  n/a   %-64s no non-bash shell on this host (CI has dash and mksh)\n' "the runner always runs bash"; return; }
    bash "$cp" "$SUT" > "$mtmp/runner.out" 2>&1
    for s in $want; do grep -q "FAIL  \[$s\]" "$mtmp/runner.out" || bad="$bad $s"; done
    if [ -z "$bad" ]; then printf '  ok    %-64s convicted under:%s\n' "the runner always runs bash" "$want"
    else printf '  XX    %-64s SURVIVED under:%s\n' "the runner always runs bash" "$bad"; MFAIL=1; fi
  }
  # a child that never launches must end the suite with HARNESS ERROR (exit 2) -- never FAIL lines, which a mutation
  # run would count as a conviction
  probe() {  # probe <label> <sed program over this suite>
    local cp="$mtmp/suite-probe.sh" rc
    sed "$2" "$0" > "$cp"
    if cmp -s "$0" "$cp"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "$1"; MFAIL=1; return; fi
    bash "$cp" "$SUT" > "$mtmp/probe.out" 2>&1; rc=$?
    if [ "$rc" -eq 2 ] && grep -q 'HARNESS ERROR' "$mtmp/probe.out"; then printf '  ok    %-64s harness error, not a conviction\n' "$1"
    else printf '  XX    %-64s HARNESS ERROR NOT RAISED (rc %s)\n' "$1" "$rc"; MFAIL=1; fi
  }
  probe 'the child never launches' 's/^runsh(){ .*$/runsh(){ return 127; }/'
  mutate_runner
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; FAILED=1; }
fi

exit "${FAILED:-0}"
