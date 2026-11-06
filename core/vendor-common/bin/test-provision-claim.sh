#!/usr/bin/env bash
# test-provision-claim.sh [<nowhere_provision.sh>] [--mutate] -- the device-owner claim and the provisioned
# marker in nowhere_provision.sh (NWP-20261017-18).
#
# WHY THIS IS COMMITTED. This script decides, once per boot until it succeeds, whether the chooser becomes the
# DEVICE OWNER -- the thing every Lock Task, blind-login and kiosk property rests on. test-provision-frp-window.sh
# executes only the FRP-WINDOW block; nothing executed the rest, and every way the rest breaks is silent:
# a marker written without an owner means provisioning never re-runs and the device stays without a device owner
# for good with nothing in the log but 'done'; a foreign owner (a pre-rename com.diaspore.chooser) retried 60
# times burns the budget on a transaction that cannot succeed; owner_ok loosened to any 'package=' reads a
# foreign record as ours; foreign_owner consulted before owner_ok refuses our own record (it matches it too);
# foreign_owner reading only text XML (`package=`) misses every Android 12+ record, which is ABX (NWP-20261127-12).
#
# HOW. The WHOLE script runs in a child of EACH shell found on PATH (bash, sh, dash, mksh): the script is
# `#!/system/bin/sh`, which is mksh on the device, and mksh reads a non-number in `[ "$n" -lt 60 ]` as 0 where bash
# and dash error. Every case runs once per shell, labelled `[<shell>]`. Transform: every absolute `/data/` in the text is rewritten to
# `<scratch>/` (so /data/nowhere -> <scratch>/nowhere, /data/system -> <scratch>/system), which is the only
# change made to the script. getprop, pm, am, dpm, settings, locksettings, device_config, setprop, restorecon and
# sleep are shell-function stubs that append their argv to <scratch>/calls. getprop answers ro.build.type=user and
# ro.debuggable (per case) and records anything else as unexpected. `dpm set-device-owner` is the only stub with
# an effect: on its Nth call (per case; never = 0) it writes a device_owner_2.xml naming com.nowhere.chooser.
# The FRP-window background loop is waited for (an EXIT trap runs `wait`); it breaks at its first owner_ok when a
# record names us, and otherwise runs its 100 sleepless passes.
#
# WHICH SHELL RAN IT. stderr is discarded, so an error message proves nothing. Every prelude appends the running
# shell's identity (ksh:$KSH_VERSION, bash:$BASH_VERSION, or posix when both are empty) to <case>/shell, and the `I`
# check requires it to match the shell the suite launched: mksh a KSH_VERSION, bash a BASH_VERSION, dash `posix`,
# sh whatever `sh` is on this host (recorded once). Children start under `env -u KSH_VERSION -u BASH_VERSION` so
# an exported value cannot fake an identity.
#
# ABX FIXTURES (NWP-20261127-12). Since Android 12 system_server writes device_owner_2.xml as Android Binary XML.
# The abx-ours, abx-foreign and abx-nodo records are built here with printf octal escapes in the layout of AOSP's
# BinaryXmlSerializer as OwnersData drives it (the same builder as test-acct-authenticator-wait.sh). They follow
# the AOSP source; they were NOT taken from a device. The harness asserts that the two device-owner fixtures hold
# no `=` byte (the property the fix rests on) and do hold their package bytes; text-nodo and abx-nodo hold no
# device owner (a system-update-policy only), so the claim must run on them.
#
#   bash test-provision-claim.sh            # the behaviour cases, under every shell found
#   bash test-provision-claim.sh --mutate   # ... plus eight script mutations and two harness mutations; each must FAIL under EVERY shell found
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SELF="$0"
SUT="${SUT:-$(dirname "$0")/nowhere_provision.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
echo "shells:$SHELLS"
SH_ID=$(env -u KSH_VERSION -u BASH_VERSION sh -c '_i="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; echo "${_i:-posix}"')

# id_matches <shell> <recorded identity>
id_matches() {
  case "$1" in
    bash) case "$2" in bash:?*) return 0 ;; esac ;;
    mksh) case "$2" in ksh:?*) return 0 ;; esac ;;
    dash) [ "$2" = posix ] && return 0 ;;
    sh) [ "$2" = "$SH_ID" ] && return 0 ;;
  esac
  return 1
}

OURS='<?xml version="1.0"?><device-owner package="com.nowhere.chooser" name="" component="com.nowhere.chooser/.AdminReceiver" />'
FOREIGN='<?xml version="1.0"?><device-owner package="com.diaspore.chooser" name="" component="com.diaspore.chooser/.AdminReceiver" />'

# ---- ABX fixtures (written straight to files by this bash, never through $( ), so the NUL bytes survive) ----
abx_str() {  # writeUTF / a new writeInternedUTF body: 2-byte big-endian length, then the bytes
  local n=${#1}
  printf "\\$(printf %03o $((n / 256)))\\$(printf %03o $((n % 256)))%s" "$1"
}
abx_owner() {  # abx_owner <out> <pkg> -> <root><device-owner package=<pkg> component=<pkg>/.AdminReceiver/></root>
  local out="$1" pkg="$2"
  { printf 'ABX\000\020'                                            # magic, START_DOCUMENT
    printf '\062\377\377'; abx_str root                             # START_TAG root (new interned, index 0)
    printf '\062\377\377'; abx_str device-owner                     # START_TAG device-owner (index 1)
    printf '\057\377\377'; abx_str package; abx_str "$pkg"          # string attribute package (index 2)
    printf '\057\377\377'; abx_str component; abx_str "$pkg/.AdminReceiver"   # string attribute component (index 3)
    printf '\063\000\001\063\000\000\021'; } > "$out"               # END_TAG device-owner, END_TAG root, END_DOCUMENT
}
abx_nodo() {  # abx_nodo <out> -> <root><system-update-policy policy_type=1/></root>: no device owner
  local out="$1"
  { printf 'ABX\000\020'
    printf '\062\377\377'; abx_str root                             # START_TAG root (index 0)
    printf '\062\377\377'; abx_str system-update-policy             # START_TAG system-update-policy (index 1)
    printf '\157\377\377'; abx_str policy_type; printf '\000\000\000\001'   # int attribute policy_type (index 2) = 1
    printf '\063\000\001\063\000\000\021'; } > "$out"
}
FX=$(mktemp -d -p "$W") || exit 2
abx_owner "$FX/abx-ours" com.nowhere.chooser
abx_owner "$FX/abx-foreign" com.diaspore.chooser
abx_nodo "$FX/abx-nodo"
printf '%s\n' '<?xml version="1.0"?><root><system-update-policy policy_type="1" /></root>' > "$FX/text-nodo"
printf 'ABX\000' > "$FX/magic"
fxchk() {  # fxchk <label> <condition-result-0/1>: a failed fixture check is a HARNESS error (exit 2)
  if [ "$2" = 0 ]; then printf '  ok    fixture: %s\n' "$1"; else echo "  HARNESS ERROR fixture: $1" >&2; exit 2; fi
}
fxhas() { local n; n=$(LC_ALL=C grep -a -c -F -e "$1" "$2" 2>/dev/null); [ "${n:-0}" != 0 ]; }
fxchk "abx-ours, abx-foreign, abx-nodo start with the magic ABX\\0" \
  "$(for k in abx-ours abx-foreign abx-nodo; do head -c4 "$FX/$k" | cmp -s - "$FX/magic" || { echo 1; exit; }; done; echo 0)"
fxchk "abx-ours and abx-foreign hold no '=' byte" \
  "$(! fxhas '=' "$FX/abx-ours" && ! fxhas '=' "$FX/abx-foreign" && echo 0 || echo 1)"
fxchk "abx-ours holds com.nowhere.chooser; abx-foreign holds com.diaspore.chooser and not com.nowhere.chooser" \
  "$(fxhas com.nowhere.chooser "$FX/abx-ours" && fxhas com.diaspore.chooser "$FX/abx-foreign" && ! fxhas com.nowhere.chooser "$FX/abx-foreign" && echo 0 || echo 1)"
fxchk "abx-ours and abx-foreign hold device-owner; text-nodo and abx-nodo do not" \
  "$(fxhas device-owner "$FX/abx-ours" && fxhas device-owner "$FX/abx-foreign" && ! fxhas device-owner "$FX/text-nodo" && ! fxhas device-owner "$FX/abx-nodo" && echo 0 || echo 1)"

# run_case <shell> <script> <dir> <debuggable> <marker:0|1> <record:none|ours|foreign|abx-ours|abx-foreign|text-nodo|abx-nodo> <dpm_ok_at>  -> sets RC
run_case() {
  local sh="$1" sut="$2" d="$3" dbg="$4" marker="$5" record="$6" at="$7"
  mkdir -p "$d/system" "$d/nowhere"
  : > "$d/calls"
  [ "$marker" = 1 ] && : > "$d/nowhere/.provisioned"
  case "$record" in
    ours) printf '%s\n' "$OURS" > "$d/system/device_owner_2.xml" ;;
    foreign) printf '%s\n' "$FOREIGN" > "$d/system/device_owner_2.xml" ;;
    abx-ours|abx-foreign|text-nodo|abx-nodo) cp "$FX/$record" "$d/system/device_owner_2.xml" ;;
  esac
  sed "s#/data/#$d/#g" "$sut" > "$d/script.sh"
  cat > "$d/prelude.sh" <<PRE
D="$d"; DEBUGGABLE="$dbg"; DPM_OK_AT="$at"; OURS='$OURS'
_nw_id="\${KSH_VERSION:+ksh:\$KSH_VERSION}\${BASH_VERSION:+bash:\$BASH_VERSION}"; echo "\${_nw_id:-posix}" >> "\$D/shell"
trap 'wait' EXIT
getprop() {
  case "\${1:-}" in
    ro.build.type) echo user ;;
    ro.debuggable) echo "\$DEBUGGABLE" ;;
    *) echo "getprop \$*" >> "\$D/unexpected"; echo "" ;;
  esac
}
rec() { echo "\$*" >> "\$D/calls"; }
pm() { rec "pm \$*"; return 0; }
am() { rec "am \$*"; return 0; }
locksettings() { rec "locksettings \$*"; }
device_config() { rec "device_config \$*"; }
setprop() { rec "setprop \$*"; }
restorecon() { rec "restorecon \$*"; }
sleep() { :; }
settings() {
  rec "settings \$*"
  case "\$1 \$2 \$3" in
    "get global dropbox_age_seconds") echo 7200 ;;
    "get global dropbox_max_files") echo 200 ;;
  esac
}
dpm() {
  rec "dpm \$*"
  if [ "\$1" = set-device-owner ]; then
    local c=0
    [ -f "\$D/dpmcalls" ] && c=\$(cat "\$D/dpmcalls")
    c=\$((c + 1)); echo "\$c" > "\$D/dpmcalls"
    [ "\$DPM_OK_AT" -gt 0 ] && [ "\$c" = "\$DPM_OK_AT" ] && printf '%s\n' "\$OURS" > "\$D/system/device_owner_2.xml"
  fi
  return 0
}
. "\$D/script.sh"
PRE
  env -u KSH_VERSION -u BASH_VERSION "$sh" "$d/prelude.sh" >/dev/null 2>&1
  RC=$?
}

count() { local n; n=$(grep -c -e "$1" "$2" 2>/dev/null); echo "${n:-0}"; }

suite() {  # suite <shell> <script> -> 0 all ok, 1 a case failed, 2 harness error
  local sh="$1" f="$2" p=0 x=0 d log calls mark idbad="" first="" herr=""
  ok() { p=$((p+1)); printf '  ok    [%s] %s\n' "$sh" "$1"; }
  no() { x=$((x+1)); printf '  FAIL  [%s] %s\n' "$sh" "$1"; }
  chk() {  # chk <label> <condition-result-0/1>
    if [ "$2" = 0 ]; then ok "$1"; else no "$1"; fi
  }
  mk() { d=$(mktemp -d -p "$W"); log="$d/nowhere/provision.log"; calls="$d/calls"; mark="$d/nowhere/.provisioned"; }
  has() { grep -q -e "$1" "$log" 2>/dev/null; }
  idchk() {  # idchk <case> -- the case's child must have recorded exactly one line, the launched shell's identity
    local rec n
    rec=$(cat "$d/shell" 2>/dev/null); n=$(grep -c '' "$d/shell" 2>/dev/null)
    # no record, or not exactly one, means the child never ran as launched: a HARNESS error (exit 2), which is
    # never a behavioural FAIL and so can never convict a mutant
    if [ "$n" != 1 ]; then herr="$herr $1=${n:-0}lines"; return; fi
    [ -n "$first" ] || first="$rec"
    id_matches "$sh" "$rec" || idbad="$idbad $1=${rec:-none}"
  }

  # a: marker present -> exit 0, nothing else
  mk; run_case "$sh" "$f" "$d" 0 1 none 0
  chk "a marker present -> exit 0 (rc=$RC) with no dpm/settings/am/pm call" \
    "$([ "$RC" = 0 ] && [ ! -s "$calls" ] && [ ! -e "$d/unexpected" ] && echo 0 || echo 1)"
  idchk a; rm -rf "$d"

  # b: no record, dpm succeeds on call 3
  mk; run_case "$sh" "$f" "$d" 0 0 none 3
  chk "b1 dpm succeeds on call 3 -> 'device-owner CONFIRMED after 2 attempts' (rc=$RC)" \
    "$([ "$RC" = 0 ] && has 'device-owner CONFIRMED after 2 attempts' && echo 0 || echo 1)"
  chk "b2 exactly 3 'dpm set-device-owner' calls, marker written, no NOT-set line" \
    "$([ "$(count '^dpm set-device-owner' "$calls")" = 3 ] && [ -f "$mark" ] && ! has 'NOT set' && has 'done; marker written' && echo 0 || echo 1)"
  idchk b; rm -rf "$d"

  # c: dpm never succeeds
  mk; run_case "$sh" "$f" "$d" 0 0 none 0
  chk "c1 dpm never succeeds -> exactly 60 'dpm set-device-owner' calls ($(count '^dpm set-device-owner' "$calls"))" \
    "$([ "$(count '^dpm set-device-owner' "$calls")" = 60 ] && echo 0 || echo 1)"
  chk "c2 'NOT set after 60 attempts', NO marker, 'marker NOT written' logged, no CONFIRMED" \
    "$(has 'device-owner NOT set after 60 attempts' && [ ! -e "$mark" ] && has 'marker NOT written' && ! has 'CONFIRMED' && echo 0 || echo 1)"
  idchk c; rm -rf "$d"

  # d: a foreign record
  mk; run_case "$sh" "$f" "$d" 0 0 foreign 0
  chk "d1 foreign record -> zero dpm set-device-owner calls (and no set-active-admin)" \
    "$([ "$(count '^dpm ' "$calls")" = 0 ] && echo 0 || echo 1)"
  chk "d2 the FOREIGN line is logged, NO marker, no 'NOT set' line, no CONFIRMED" \
    "$(has 'FOREIGN device-owner present' && [ ! -e "$mark" ] && ! has 'NOT set' && ! has 'CONFIRMED' && has 'marker NOT written' && echo 0 || echo 1)"
  idchk d; rm -rf "$d"

  # d-abx: a foreign record in ABX (NWP-20261127-12): the same checks as d
  mk; run_case "$sh" "$f" "$d" 0 0 abx-foreign 0
  chk "d-abx1 ABX foreign record -> zero dpm calls ($(count '^dpm ' "$calls"))" \
    "$([ "$(count '^dpm ' "$calls")" = 0 ] && echo 0 || echo 1)"
  chk "d-abx2 the FOREIGN line is logged, NO marker, no 'NOT set' line, no CONFIRMED" \
    "$(has 'FOREIGN device-owner present' && [ ! -e "$mark" ] && ! has 'NOT set' && ! has 'CONFIRMED' && has 'marker NOT written' && echo 0 || echo 1)"
  idchk d-abx; rm -rf "$d"

  # e: already owned by us
  mk; run_case "$sh" "$f" "$d" 0 0 ours 0
  chk "e1 already owned -> zero dpm calls, 'CONFIRMED after 0 attempts'" \
    "$([ "$(count '^dpm ' "$calls")" = 0 ] && has 'device-owner CONFIRMED after 0 attempts' && echo 0 || echo 1)"
  chk "e2 no FOREIGN line, marker written" \
    "$(! has 'FOREIGN' && [ -f "$mark" ] && echo 0 || echo 1)"
  idchk e; rm -rf "$d"

  # e-abx: already owned by us, the record in ABX: owner_ok's literal-package grep still wins
  mk; run_case "$sh" "$f" "$d" 0 0 abx-ours 0
  chk "e-abx1 ABX record of ours -> zero dpm calls, 'CONFIRMED after 0 attempts'" \
    "$([ "$(count '^dpm ' "$calls")" = 0 ] && has 'device-owner CONFIRMED after 0 attempts' && echo 0 || echo 1)"
  chk "e-abx2 no FOREIGN line, marker written" \
    "$(! has 'FOREIGN' && [ -f "$mark" ] && echo 0 || echo 1)"
  idchk e-abx; rm -rf "$d"

  # f: debuggable build
  mk; run_case "$sh" "$f" "$d" 1 0 ours 0
  chk "f1 ro.debuggable=1 -> 'settings put global adb_enabled 1' and the dev log line" \
    "$(grep -qx 'settings put global adb_enabled 1' "$calls" && has '(dev/debuggable) adb_enabled set' && echo 0 || echo 1)"
  chk "f2 ... with an owner the marker is written, and no 'adb_enabled 0' hold ran" \
    "$([ -f "$mark" ] && ! grep -qx 'settings put global adb_enabled 0' "$calls" && echo 0 || echo 1)"
  chk "f3 only ro.build.type and ro.debuggable were read" \
    "$([ ! -e "$d/unexpected" ] && echo 0 || echo 1)"
  idchk f; rm -rf "$d"

  # g / g-abx: a device_owner_2.xml that holds NO device owner (a system-update-policy only), dpm succeeds on call 3
  local g
  for g in g:text-nodo g-abx:abx-nodo; do
    mk; run_case "$sh" "$f" "$d" 0 0 "${g#*:}" 3
    chk "${g%%:*}1 no-device-owner record (${g#*:}) -> the claim runs: 3 'dpm set-device-owner' calls, 'CONFIRMED after 2 attempts'" \
      "$([ "$(count '^dpm set-device-owner' "$calls")" = 3 ] && has 'device-owner CONFIRMED after 2 attempts' && echo 0 || echo 1)"
    chk "${g%%:*}2 no FOREIGN line, marker written" \
      "$(! has 'FOREIGN' && [ -f "$mark" ] && echo 0 || echo 1)"
    idchk "${g%%:*}"; rm -rf "$d"
  done

  if [ -z "$idbad" ]; then ok "I every executed case (10) recorded the $sh identity ($first)"
  else no "I a case recorded another shell than $sh:$idbad"; fi

  printf '  -- [%s] %d ok, %d failed\n' "$sh" "$p" "$x"
  if [ -n "$herr" ]; then printf '  HARNESS ERROR [%s] no single identity record (child did not run):%s\n' "$sh" "$herr"; return 2; fi
  [ "$x" -eq 0 ] && return 0 || return 1
}

all_shells() {  # all_shells <script> -> 0 when every shell passes every case
  local sh r rc=0
  for sh in $SHELLS; do
    suite "$sh" "$1"; r=$?
    if [ "$r" = 2 ]; then rc=2; elif [ "$r" != 0 ] && [ "$rc" = 0 ]; then rc=1; fi
  done
  return $rc
}

echo "device-owner claim and marker: $SUT"
all_shells "$SUT"; rc=$?
[ "$rc" = 0 ] || FAILED=$rc

if [ "$MUTATE" = yes ]; then
  command -v perl >/dev/null || { echo "perl is required for --mutate" >&2; exit 2; }
  echo
  echo "mutations (each must FAIL under every shell found:$SHELLS):"
  MT=$(mktemp -d -p "$W")
  # judge <label> <outfile> <rc> <required shells...>: convicted only on rc 1 and a FAIL line under EACH shell
  judge() {
    local label="$1" out="$2" rc="$3" s bad=""; shift 3
    for s in "$@"; do grep -q -e "FAIL  \[$s\]" "$out" || bad="$bad $s"; done
    if [ "$rc" = 1 ] && [ -z "$bad" ]; then printf '  ok    %-66s convicted under:%s\n' "$label" " $*"
    elif [ "$rc" != 0 ] && [ "$rc" != 1 ]; then printf '  ERR   %-66s harness error (rc=%s), not a conviction\n' "$label" "$rc"; MFAIL=1
    else printf '  XX    %-66s NOT CONVICTED (rc %s, no FAIL line under:%s)\n' "$label" "$rc" "$bad"; MFAIL=1; fi
  }
  mutate() {  # <label> <perl program>
    local label="$1" prog="$2" mf="$MT/p.sh" r
    if ! perl -0pe "$prog" "$SUT" > "$mf"; then printf '  ERR   %-66s perl program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-66s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    bash "$SELF" "$mf" > "$MT/out" 2>&1; r=$?
    judge "$label" "$MT/out" "$r" $SHELLS
  }
  mutate 'the marker early-exit is gone'                  's@^\[ -f "\$MARK" \] && exit 0\n@@m'
  mutate 'the marker is written without an owner'         's@^if owner_ok; then\n  touch "\$MARK"@if true; then\n  touch "\$MARK"@m'
  mutate 'the foreign-owner arm is gone'                  's@^elif foreign_owner; then$@elif false; then@m'
  mutate 'owner_ok accepts any package='                  's@grep -q "com\.nowhere\.chooser"@grep -q '"'"'package='"'"'@'
  mutate 'the claim loop cap is 1'                        's@-lt 60 \]@-lt 1 ]@'
  mutate 'foreign_owner greps the text package= again'   's@grep -q -a '"'"'device-owner'"'"'@grep -q '"'"'package='"'"'@'
  mutate 'foreign_owner matches any non-empty file'       's@\[ -f "\$f" \] && grep -q -a '"'"'device-owner'"'"' "\$f" 2>/dev/null && return 0@[ -s "\$f" ] && return 0@'
  mutate 'foreign_owner is consulted before owner_ok'     's@^if owner_ok; then\n  : # already owned by us\nelif foreign_owner; then\n(.*?\n)else\n@if foreign_owner; then\n$1elif owner_ok; then\n  : # already owned by us\nelse\n@ms'
  # harness mutant: run_case ignores its shell and always runs bash; the identity check must convict it under
  # every shell whose identity is not bash's
  label='run_case ignores its shell argument and always runs bash'
  req=""
  for s in $SHELLS; do
    case "$s" in bash) ;; sh) case "$SH_ID" in bash:*) ;; *) req="$req sh" ;; esac ;; *) req="$req $s" ;; esac
  done
  if [ "$(grep -c '^  env -u KSH_VERSION -u BASH_VERSION "\$sh" ' "$SELF")" != 1 ]; then
    printf '  ERR   %-66s launch line not found exactly once\n' "$label"; MFAIL=1
  else
    sed 's@^\(  env -u KSH_VERSION -u BASH_VERSION \)"\$sh" @\1bash @' "$SELF" > "$MT/suite.sh"
    if cmp -s "$SELF" "$MT/suite.sh"; then printf '  SKIP  %-66s mutation was a NO-OP\n' "$label"; MFAIL=1
    elif [ -z "$req" ]; then
      printf '  n/a   %-66s no non-bash shell on this host (sh is %s); CI has mksh and dash\n' "$label" "$SH_ID"
    else
      bash "$MT/suite.sh" "$SUT" > "$MT/out" 2>&1; r=$?
      judge "$label" "$MT/out" "$r" $req
    fi
  fi
  # fault injection: every child launch fails. That is a HARNESS error: the suite must exit 2 (never 0, never the
  # 1 that convicts a mutant), so a launch failure during a mutant run can never be credited as a conviction.
  label='run_case child launches fail (fault injection) -> harness error, exit 2'
  sed 's@^\(  env -u KSH_VERSION -u BASH_VERSION \)"\$sh" @\1false @' "$SELF" > "$MT/fault.sh"
  if cmp -s "$SELF" "$MT/fault.sh"; then printf '  SKIP  %-66s mutation was a NO-OP\n' "$label"; MFAIL=1
  else
    bash "$MT/fault.sh" "$SUT" > "$MT/out" 2>&1; r=$?
    if [ "$r" = 2 ] && grep -q 'HARNESS ERROR' "$MT/out"; then printf '  ok    %-66s exit 2, not a conviction\n' "$label"
    else printf '  XX    %-66s rc=%s, want 2 with a HARNESS ERROR line\n' "$label" "$r"; MFAIL=1; fi
  fi
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS CONVICTED" || { echo "PROBLEM: a mutation survived"; FAILED=${FAILED:-1}; [ "$FAILED" = 2 ] || FAILED=1; }
fi

exit "${FAILED:-0}"
