#!/usr/bin/env bash
# test-fido2-enroll-op.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's `fido2-enroll` op and usb_host(), run for real.
#
# Until this, no suite executed either: test-log-name-scrub.sh only plants the op's log line and test-resume-verify.sh
# drives the fido2hmac op. The properties pinned here are silent when broken:
#   - usb_host off must run on BOTH outcomes. Moved into the success branch, a failed enrolment (key not touched,
#     wrong key) leaves the phone in forced USB host mode until reboot, supplying VBUS from its battery and refusing
#     to act as a USB device.
#   - the passphrase reaches the agent only as `@file:` (pw), never in argv, where /proc/<pid>/cmdline shows it.
#   - NOWHERE_FIDO2_HMAC is exported only when the stash exists: UNSET, not merely empty, otherwise a first enrolment
#     is handed a hmac of "".
#   - an empty name or passphrase answers ERR-ARGS before the agent or the USB role is touched.
#   - the profile name reaches the log only through qn's quoting, on the success AND the failure line.
#
# usb_host(), pw(), qn() and the op block are extracted from nowhere_roamd.sh BY ANCHOR, never copied; if an anchor
# moves, extraction fails loudly (exit 2). THE ONE TRANSFORM, stated because a test that quietly rewrites its subject
# is not testing it: the two absolute /sys paths of usb_host are re-rooted into a temp tree, and the suite asserts
# that the rewrite applied.
#
# The harness is bash (`sh test-fido2-enroll-op.sh` re-execs under bash); the SUBJECT is not. Each case writes the
# extracted functions, the op block (or a bare usb_host call), its variables and stubs into a run file and executes it
# in a CHILD of each shell found among bash, sh, dash and mksh (the device's /system/bin/sh). Each run file records the
# identity of the shell that ran it, and the suite asserts it is the shell the case launched. A mutant is convicted
# only when it fails under EVERY shell. Every temp of the run lives under one root, removed on exit.
#
#   bash test-fido2-enroll-op.sh            # the behaviour cases, under every shell found
#   bash test-fido2-enroll-op.sh --mutate   # ... plus mutations that must each CONVICT the suite under each shell
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

# runcase <shell> <layout> <call> [<name> <pass> <agent-rc> [stash]]  -> sets T (the case dir)
#   layout: ssusb = T/sys/ssusb + T/sys/typec, ssusb/mode starts "untouched"; typec = the same two dirs, only
#   typec/data_role starts "untouched" (no ssusb/mode, so usb_host takes its typec arm); typec-only = T/sys/typec alone
#   with data_role; none = an empty T/sys. call: op = the fido2-enroll block; on|off = a bare `usb_host <on|off>`.
#   T/argv, T/passfile, T/hmacset, T/hmacval, T/ran are what the stub agent saw; T/res and T/log are roamd's.
runcase(){
  local sh="$1" layout="$2" call="$3" nm="${4-}" pw_="${5-}" rc="${6-0}" stash="${7-}" r
  T=$(mktemp -d -p "$W") || exit 2; mkdir -p "$T/state" "$T/sys"
  case "$layout" in
    ssusb) mkdir -p "$T/sys/ssusb" "$T/sys/typec"; echo untouched > "$T/sys/ssusb/mode" ;;
    typec) mkdir -p "$T/sys/ssusb" "$T/sys/typec"; echo untouched > "$T/sys/typec/data_role" ;;
    typec-only) mkdir -p "$T/sys/typec"; echo untouched > "$T/sys/typec/data_role" ;;
  esac
  [ -n "$stash" ] && printf '%s\n' "$stash" > "$T/state/.fido2hmac"
  {
    printf '#!/bin/sh\nd=%s\n' "$(sq "$T")"
    cat <<'STUB'
: > "$d/ran"
for x in "$@"; do printf '%s\n' "$x"; done > "$d/argv"
case "$4" in @file:*) cat "${4#@file:}" > "$d/passfile" ;; esac
printf '%s' "${NOWHERE_FIDO2_HMAC+set}" > "$d/hmacset"
printf '%s' "${NOWHERE_FIDO2_HMAC-}" > "$d/hmacval"
STUB
    printf 'exit %s\n' "$rc"
  } > "$T/agent"
  chmod +x "$T/agent"
  # The run file holds the passphrase (pass=), so it lives OUTSIDE $T: the leak checks below scan $T.
  r=$(mktemp -p "$W") || exit 2
  {
    printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$T/shell.id")"
    printf '%s\n' "$PRINT_SHIM"
    printf 'unset NOWHERE_FIDO2_HMAC\n'
    printf 'SYSROOT=%s; LOG=%s; RES=%s; STATE=%s; AGENT=%s; LANE=rw; op=fido2-enroll; name=%s; pass=%s\n' \
      "$(sq "$T/sys")" "$(sq "$T/log")" "$(sq "$T/res")" "$(sq "$T/state")" "$(sq "$T/agent")" "$(sq "$nm")" "$(sq "$pw_")"
    cat <<'STUB'
: > "$LOG"
sleep() { :; }
STUB
    printf '%s\n%s\n%s\n' "$USB_R" "$PW" "$QN"
    case "$call" in op) printf '%s\n' "$BLOCK" ;; *) printf 'usb_host %s\n' "$call" ;; esac
  } > "$r"
  runsh "$sh" "$r"
  rm -f "$r"
}
role(){ cat "$T/sys/ssusb/mode" 2>/dev/null; }

suite() {  # suite <roamd.sh> <shell> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" s="$2" quiet="${3:-}" p=0 x=0 USB want pair rc verb line rest NM TOK SECRET chk
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$s" "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$s" "$1"; }
  eq() { [ "$1" = "$2" ] && ok "$3" || no "$3 (got '$1', want '$2')"; }
  USB=$(fn "$f" usb_host); PW=$(fn "$f" pw); QN=$(fn "$f" qn)
  BLOCK=$(awk '
    $0 == "if [ \"$op\" = \"fido2-enroll\" ]; then" { on = 1 }
    on { print }
    on && $0 == "fi" { exit }' "$f")
  case "$USB" in *'no ssusb/typec role-switch found'*) ;; *) echo "EXTRACTION FAILED: usb_host in $f" >&2; return 2 ;; esac
  case "$PW" in *'@file:'*) ;; *) echo "EXTRACTION FAILED: pw in $f" >&2; return 2 ;; esac
  case "$QN" in *'sed '*) ;; *) echo "EXTRACTION FAILED: qn in $f" >&2; return 2 ;; esac
  case "$BLOCK" in *'fido2-enroll s3'*'ERR-ENROLL'*) ;; *) echo "EXTRACTION FAILED: the fido2-enroll op in $f" >&2; return 2 ;; esac

  # The one transform: /sys -> $SYSROOT.
  USB_R=$(printf '%s\n' "$USB" | sed 's#/sys/devices/platform/soc/7000000.ssusb/mode#$SYSROOT/ssusb/mode#; s#/sys/class/typec/port0/data_role#$SYSROOT/typec/data_role#')
  case "$USB_R" in *'/sys/'*) echo "TRANSFORM FAILED: a /sys path survived" >&2; return 2 ;; esac
  [ "$(printf "%s\n" "$USB_R" | grep -o SYSROOT | wc -l)" -eq 2 ] || { echo "TRANSFORM FAILED: expected both paths re-rooted" >&2; return 2; }

  chk=$(mktemp -p "$W") || return 2
  printf '%s\n%s\n%s\n%s\n' "$USB_R" "$PW" "$QN" "$BLOCK" > "$chk"
  if ! bash -n "$chk" || ! "$s" -n "$chk"; then
    echo "EXTRACTION FAILED: usb_host, pw, qn or the fido2-enroll op does not parse under $s in $f" >&2; rm -f "$chk"; return 2
  fi
  rm -f "$chk"
  : > "$W/notrun"; : > "$W/harness"

  [ -n "$quiet" ] || echo "== [$s] usb_host =="
  for want in "on:host" "off:peripheral"; do
    runcase "$s" ssusb "${want%%:*}"
    eq "$(role)" "${want#*:}" "U1 ssusb: usb_host ${want%%:*} writes ${want#*:}"; notrun "$s" "$T"; rm -rf "$T"
  done
  for want in "on:host" "off:device"; do
    runcase "$s" typec-only "${want%%:*}"
    eq "$(cat "$T/sys/typec/data_role")" "${want#*:}" "U2 typec only: usb_host ${want%%:*} writes ${want#*:}"; notrun "$s" "$T"; rm -rf "$T"
  done
  runcase "$s" none on
  grep -qF 'no ssusb/typec role-switch found' "$T/log" && ok "U3 neither: logs that no role-switch was found" || no "U3 no log line"
  [ -z "$(find "$T/sys" -type f)" ] && ok "U3 neither: nothing written" || no "U3 a file was created"; notrun "$s" "$T"; rm -rf "$T"

  [ -n "$quiet" ] || echo "== [$s] enrol succeeds =="
  SECRET='p@ss\w0rd -n Zq9'
  runcase "$s" ssusb op alice "$SECRET" 0
  eq "$(cat "$T/res")" OK "F1 RES is OK"
  eq "$(role)" peripheral "F1 host mode is switched back off"
  eq "$(sed -n 1p "$T/argv")|$(sed -n 2p "$T/argv")|$(sed -n 3p "$T/argv")|$(wc -l < "$T/argv")" "fido2-enroll|s3|alice|4" "F1 argv is fido2-enroll s3 <name> <4th>"
  case "$(sed -n 4p "$T/argv")" in @file:*) ok "F1 \$4 is an @file: reference" ;; *) no "F1 \$4 is '$(sed -n 4p "$T/argv")'" ;; esac
  eq "$(cat "$T/passfile" 2>/dev/null)" "$SECRET" "F1 the file held the passphrase"
  grep -qF -- "$SECRET" "$T/argv" && no "F1 the passphrase is in argv" || ok "F1 the passphrase is in no argument"
  grep -qF -- "$SECRET" "$T/log" && no "F5 the passphrase reached the log" || ok "F5 no passphrase in the log (success)"
  notrun "$s" "$T"; rm -rf "$T"

  [ -n "$quiet" ] || echo "== [$s] enrol fails =="
  runcase "$s" ssusb op alice "$SECRET" 1
  eq "$(cat "$T/res")" ERR-ENROLL "F2 RES is ERR-ENROLL"
  eq "$(role)" peripheral "F2 host mode is switched back off after a failure"
  notrun "$s" "$T"; rm -rf "$T"
  # F2b: the same failure on a phone whose only role switch is typec (the Pixel's data_role)
  runcase "$s" typec op alice "$SECRET" 1
  eq "$(cat "$T/res")" ERR-ENROLL "F2b typec: RES is ERR-ENROLL"
  eq "$(cat "$T/sys/typec/data_role")" device "F2b typec: host mode is switched back off after a failure"
  notrun "$s" "$T"; rm -rf "$T"

  [ -n "$quiet" ] || echo "== [$s] missing arguments =="
  for pair in ":$SECRET" "alice:" ":"; do
    runcase "$s" ssusb op "${pair%%:*}" "${pair#*:}" 0
    eq "$(cat "$T/res")" ERR-ARGS "F3 name='${pair%%:*}' pass-empty=$([ -z "${pair#*:}" ] && echo yes || echo no): ERR-ARGS"
    [ ! -e "$T/ran" ] && ok "F3 the agent never ran" || no "F3 the agent ran"
    eq "$(role)" untouched "F3 usb_host never ran"
    notrun "$s" "$T"; rm -rf "$T"
  done

  [ -n "$quiet" ] || echo "== [$s] the hmac stash =="
  runcase "$s" ssusb op alice "$SECRET" 0 "stash-hmac-77"
  eq "$(cat "$T/hmacset")|$(cat "$T/hmacval")" "set|stash-hmac-77" "F4 stash present: the agent sees it SET and equal"; notrun "$s" "$T"; rm -rf "$T"
  runcase "$s" ssusb op alice "$SECRET" 0
  eq "$(cat "$T/hmacset")" "" "F4 no stash: NOWHERE_FIDO2_HMAC is NOT SET (empty is not enough)"; notrun "$s" "$T"; rm -rf "$T"

  [ -n "$quiet" ] || echo "== [$s] the name in the log =="
  NM='a b"c'; TOK='"a b\"c"'
  for rc in 0 1; do
    runcase "$s" ssusb op "$NM" "$SECRET" "$rc"
    verb=OK; [ "$rc" = 1 ] && verb=FAILED
    line=$(grep -F "fido2-enroll $verb for" "$T/log" | head -1)
    case "$line" in *"fido2-enroll $verb for $TOK "*) ok "F5 $verb line carries the name as one escaped quoted token" ;; *) no "F5 $verb line is '$line'" ;; esac
    rest=$(cat "$T/log"); rest=${rest//"$TOK"/}
    case "$rest" in *'a b'*|*'c"'*) no "F5 $verb: the name appears outside qn's quoting" ;; *) ok "F5 $verb: the name appears only inside qn's quoting" ;; esac
    grep -qF -- "$SECRET" "$T/log" && no "F5 $verb: the passphrase reached the log" || ok "F5 $verb: no passphrase in the log"
    notrun "$s" "$T"; rm -rf "$T"
  done

  if [ -s "$W/harness" ]; then echo "HARNESS ERROR: a run file left no identity: $s did not launch it" >&2; return 2; fi
  if grep -qx "$s" "$W/notrun"; then no "identity: a case did not run under $s"; else ok "identity: every case ran under $s"; fi
  [ -n "$quiet" ] || printf '  -- [%s] %d ok, %d failed\n' "$s" "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "roamd fido2-enroll op and usb_host: $SUT"
echo "shells:$SHELLS"
echo "sh identity: $REF_SH"
for s in $SHELLS; do
  suite "$SUT" "$s"; rc=$?
  [ "$rc" = 0 ] || FAILED=$(( rc > ${FAILED:-0} ? rc : ${FAILED:-0} ))
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite under every shell found) =="
  M=$(mktemp -d -p "$W") || exit 2
  R='/^if \[ "\$op" = "fido2-enroll" \]; then$/,/^fi$/'
  mutate(){  # <label> <sed program over the whole of roamd>
    local label="$1" prog="$2" mf="$M/m.sh" r s alive="" err=""
    if ! sed "$prog" "$SUT" > "$mf" 2>"$M/err"; then printf '  ERR   %-64s MUTATION BROKEN (sed)\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-64s MUTATION INERT\n' "$label"; MFAIL=1; return; fi
    for s in $SHELLS; do
      suite "$mf" "$s" quiet >/dev/null 2>&1; r=$?
      case "$r" in
        0) alive="$alive $s" ;;
        1) ;;
        *) err="$err $s" ;;
      esac
    done
    if [ -n "$alive" ]; then printf '  XX    %-64s NOT CONVICTED (suite passes on broken code) under:%s\n' "$label" "$alive"; MFAIL=1
    elif [ -n "$err" ]; then printf '  ERR   %-64s harness error (not a conviction) under:%s\n' "$label" "$err"; MFAIL=1
    else printf '  ok    %-64s convicted under every shell (%s )\n' "$label" "$SHELLS"; fi
  }
  mutate "usb_host off only on success (failure leaves host mode on)" \
    "$R { /^  usb_host off\$/d; s/; echo \"OK\" > \"\\\$RES\"\$/&; usb_host off/; }"
  mutate "passphrase passed in argv instead of by file" \
    "$R s/\"\\\$(pw \"\\\$pass\")\"/\"\\\$pass\"/"
  mutate "hmac stash guard dropped (variable set to empty)" \
    "$R s/\\[ -f \"\\\$STATE\\/.fido2hmac\" \\] && export/export/"
  mutate "ERR-ARGS guard removed" "$R { /ERR-ARGS/d; }"
  mutate "ssusb off value is host" '/^usb_host() {$/,/^}$/ s/echo peripheral > "\$m"/echo host > "$m"/'
  mutate "typec off value is host" '/^usb_host() {$/,/^}$/ s/echo device > "\$t"/echo host > "$t"/'
  mutate "bare name in the FAILED line" "$R { /FAILED for/ s/\\\$(qn \"\\\$name\")/\\\$name/; }"
  # the runner ignores its shell argument and always runs bash: the identity check must convict it under every non-bash shell
  mutate_runner() {
    local s bad="" want="" cp="$M/suite-runner.sh"
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
    bash "$cp" "$SUT" > "$M/runner.out" 2>&1
    for s in $want; do grep -q "FAIL  \[$s\]" "$M/runner.out" || bad="$bad $s"; done
    if [ -z "$bad" ]; then printf '  ok    %-64s convicted under:%s\n' "the runner always runs bash" "$want"
    else printf '  XX    %-64s SURVIVED under:%s\n' "the runner always runs bash" "$bad"; MFAIL=1; fi
  }
  # a child that never launches must end the suite with HARNESS ERROR (exit 2) -- never FAIL lines, which a mutation
  # run would count as a conviction
  probe() {  # probe <label> <sed program over this suite>
    local cp="$M/suite-probe.sh" rc
    sed "$2" "$0" > "$cp"
    if cmp -s "$0" "$cp"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "$1"; MFAIL=1; return; fi
    bash "$cp" "$SUT" > "$M/probe.out" 2>&1; rc=$?
    if [ "$rc" -eq 2 ] && grep -q 'HARNESS ERROR' "$M/probe.out"; then printf '  ok    %-64s harness error, not a conviction\n' "$1"
    else printf '  XX    %-64s HARNESS ERROR NOT RAISED (rc %s)\n' "$1" "$rc"; MFAIL=1; fi
  }
  probe 'the child never launches' 's/^runsh(){ .*$/runsh(){ return 127; }/'
  mutate_runner
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; FAILED=1; }
fi

exit "${FAILED:-0}"
