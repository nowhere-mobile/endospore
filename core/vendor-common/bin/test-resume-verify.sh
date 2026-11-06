#!/usr/bin/env bash
# test-resume-verify.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's cold-lock RESUME ops (NWP-20260924-01):
# `verify` and `resumeclear`, plus (NWP-20261017-03) the key re-assert op `fido2hmac`: it must use the cold-lock
# marker's slot spec ONLY and never fall back to `fido2-hmac s3 <name> <pass>`, which staged the typed -- and not yet
# proven -- entry in a .pw file and derived head refs from it for the store.
#
# WHY THIS IS COMMITTED. The verify op used `ls -d /data/user/<uid>/android` as its ground truth and threw away
# `cmd lock_settings verify`'s exit status. `ls` says the CE is decrypted NOW, not that the credential was right,
# and the CE stays readable in the window before eviction -- indefinitely under EVICT-INCOMPLETE -- so ANY
# credential passed, and the agent then made the wrong entry the session's seal passphrase. The op now accepts
# only when the keyguard says yes (rc 0), or when a CE that was COLD before the verify is readable after it. It
# never clears the credential: `resumeclear` does, and the agent runs it only after the resume has committed --
# cleared inside verify, a resume that then failed to commit stranded the owner on a credential-less user.
#
# Both blocks are extracted from nowhere_roamd.sh BY ANCHOR, never copied; if the anchors move, extraction fails
# loudly rather than a stale copy passing forever. `ls` and `cmd` are stubbed as shell functions over a simulated
# CE, keyguard and exit status; they answer only the paths and arguments roamd really uses, and record anything
# else, so a probe pointed at the wrong path or user fails the suite instead of passing it.
#
# Each case writes its block, variables and stubs into a run file and executes that file in a CHILD of each shell found
# among bash, sh, dash and mksh (the device's /system/bin/sh). The `print` shim is defined only where the shell has no
# `print` of its own, so mksh runs its builtin. Each run file records the identity of the shell that ran it and the
# suite asserts it is the shell the case launched. A mutant is convicted only when it fails under EVERY shell found.
#
# NWP-20261125-25: both ops run ahead of roamd's shared uid guard, so each carries the guard's rule itself: a uid is all
# digits, has no leading zero and is 10 or more. uid 0 is the gate, whose keyguard is held disabled, and `010` names no
# user. A refused uid answers ERR-UID before any `ls` or `cmd`. The `ls` and `cmd` stubs record every call (never the
# credential), and V10-V12b and C4-C6b assert that record is empty, not only the RES.
#
#   bash test-resume-verify.sh            # the behaviour cases
#   bash test-resume-verify.sh --mutate   # ... plus mutations that must each CONVICT the suite
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

extract() {  # extract <roamd.sh> <op>
  sed -n "/^if \\[ \"\\\$op\" = \"$2\" \\]; then\$/,/^fi\$/p" "$1"
}

# run_fido <shell> <block-file> <spec> <pinflag> <cold-stdout> [pass]   (the `fido2hmac` op, NWP-20261017-03)
#   spec     : line 7 of the cold-lock marker ("" = a marker with no slot spec)
#   pinflag  : line 5 of the marker (nopin|pin)
#   cold-out : what the stub agent prints for `fido2-hmac-cold` ("" = the key assertion yielded nothing)
# The stub agent answers fido2-hmac-cold and records EVERY call; `fido2-hmac` (the store path) prints a plausible hmac,
# so a fallback that survives shows up as a recorded call, not as a silent failure.
# Prints: "<RES>|<.fido2hmac contents>|<agent calls, ;-joined>|<1 if the pass leaked into a call, the log or the state dir>"
run_fido() {
  local sh="$1" blk="$2" spec="$3" pinf="$4" cold="$5" typed="${6:-SECRET-ENTRY}" d r
  d=$(mktemp -d -p "$W") || exit 2; mkdir "$d/state"
  printf 'alice\n10\n\nfido2\n%s\n0123wrap\n%s\n' "$pinf" "$spec" > "$d/state/.coldlock"
  printf '#!/bin/sh\necho "$1" >> "%s/calls"\necho "$*" >> "%s/calls.full"\ncase "$1" in\n  fido2-hmac-cold) printf "%%s\\n" "%s" ;;\n  fido2-hmac) echo STOREHMAC ;;\nesac\n' "$d" "$d" "$cold" > "$d/agent"
  chmod +x "$d/agent"
  : > "$d/calls"
  # The run file holds the typed entry (pass=), so it lives OUTSIDE $d: the leak check below scans all of $d.
  r=$(mktemp -p "$W") || exit 2
  {
    printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$d/shell.id")"
    printf '%s\n' "$PRINT_SHIM"
    printf 'd=%s; RES=%s; LOG=%s; STATE=%s; AGENT=%s; op=fido2hmac; name=alice; pass=%s\n' \
      "$(sq "$d")" "$(sq "$d/res")" "$(sq "$d/log")" "$(sq "$d/state")" "$(sq "$d/agent")" "$(sq "$typed")"
    cat <<'STUB'
usb_host() { :; }; sleep() { :; }
pw() { printf '%s' "$1" > "$d/state/.pw"; printf '%s' "$1"; }  # the stage the legacy fallback wrote
STUB
    cat "$blk"
  } > "$r"
  runsh "$sh" "$r"
  rm -f "$r"
  local leak=0
  grep -rqF -- "$typed" "$d" 2>/dev/null && leak=1
  notrun "$sh" "$d" || leak="${leak}NOTRUN"
  printf '%s|%s|%s|%s\n' "$(cat "$d/res" 2>/dev/null)" "$(cat "$d/state/.fido2hmac" 2>/dev/null)" \
    "$(tr '\n' ';' < "$d/calls" 2>/dev/null)" "$leak"
  rm -rf "$d"
}

# run_op <shell> <block-file> <op> <ce: cold|readable> <keyguard> <typed> <rc-mode> [uid] [repeat] [calls]
#   honest   : rc 0 iff typed == keyguard
#   lies-no  : verify's rc is 1 always (a build whose exit status never reports success)
#   lies-yes : verify's rc is 0 always (a build whose exit status never reports failure)
#   repeat   : run the op this many times against the SAME simulated device (a retry)
#   calls    : the word `calls` appends "|<number of ls and cmd calls the stubs recorded>" (NWP-20261125-25)
# Prints: "<RES of the last run>|<cleared 0/1>|<log>|<unexpected calls>[|<calls>]"
run_op() {
  local sh="$1" blk="$2" opv="$3" ce="$4" kg="$5" typed="$6" rcm="$7" uidv="${8:-10}" rep="${9:-1}" wantc="${10:-}" d i unexp nc=""
  d=$(mktemp -d -p "$W") || exit 2
  echo "$ce" > "$d/ce"; printf '%s' "$kg" > "$d/kg"
  {
    printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$d/shell.id")"
    printf '%s\n' "$PRINT_SHIM"
    printf 'd=%s; RES=%s; LOG=%s; op=%s; uid=%s; pass=%s; RCM=%s\n' \
      "$(sq "$d")" "$(sq "$d/res")" "$(sq "$d/log")" "$(sq "$opv")" "$(sq "$uidv")" "$(sq "$typed")" "$(sq "$rcm")"
    cat <<'STUB'
ls() {  # ls -d <path>
  echo "ls $2" >> "$d/calls"
  case "$2" in
    "/data/user/$uid/android") [ "$(cat "$d/ce")" = readable ] ;;
    "/data/user/$uid"|"/data/user_de/$uid"|"/data/user_de/$uid/"*) return 0 ;;
    *) echo "ls $*" >> "$d/unexpected"; return 1 ;;
  esac
}
cmd() {  # cmd lock_settings <verb> --old <cred> --user <uid>
  echo "cmd $1 $2 user=${6:-}" >> "$d/calls"   # never $4, the credential
  if [ "$1" != lock_settings ] || [ "${5:-}" != --user ] || [ "${6:-}" != "$uid" ]; then
    echo "cmd $*" >> "$d/unexpected"; return 1
  fi
  local verb="$2" cred="$4" kgv right=1
  kgv=$(cat "$d/kg")
  [ -n "$kgv" ] && [ "$cred" = "$kgv" ] && right=0
  case "$verb" in
    verify)
      [ "$right" = 0 ] && echo readable > "$d/ce"   # the right credential unlocks the CE
      case "$RCM" in honest) return "$right" ;; lies-no) return 1 ;; lies-yes) return 0 ;; esac ;;
    clear)
      if [ "$right" = 0 ]; then echo 1 > "$d/cleared"; : > "$d/kg"; return 0; fi
      return 1 ;;
  esac
  echo "cmd $*" >> "$d/unexpected"; return 1
}
STUB
    cat "$blk"
  } > "$d/run.sh"
  for i in $(seq "$rep"); do runsh "$sh" "$d/run.sh"; done
  unexp="$(cat "$d/unexpected" 2>/dev/null)"
  notrun "$sh" "$d" || unexp="${unexp}NOTRUN"
  [ "$wantc" = calls ] && { : >> "$d/calls"; nc="|$(wc -l < "$d/calls" | tr -d ' ')"; }
  printf '%s|%s|%s|%s%s\n' "$(cat "$d/res" 2>/dev/null)" "$([ -f "$d/cleared" ] && echo 1 || echo 0)" \
    "$(tail -1 "$d/log" 2>/dev/null)" "$unexp" "$nc"
  rm -rf "$d"
}

suite() {  # suite <roamd.sh> <shell> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" s="$2" quiet="${3:-}" v c fh p=0 x=0 out vc
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$s" "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$s" "$1"; }
  v=$(mktemp -p "$W") && c=$(mktemp -p "$W") && fh=$(mktemp -p "$W") || return 2
  extract "$f" verify > "$v"; extract "$f" resumeclear > "$c"; extract "$f" fido2hmac > "$fh"
  if ! grep -q 'lock_settings verify' "$v" || ! grep -q 'lock_settings clear' "$c"; then
    echo "EXTRACTION FAILED: verify/resumeclear block missing in $f" >&2; rm -f "$v" "$c" "$fh"; return 2
  fi
  if ! grep -q 'fido2-hmac-cold' "$fh" || ! bash -n "$fh"; then
    echo "EXTRACTION FAILED: fido2hmac block missing or unparsable in $f" >&2; rm -f "$v" "$c" "$fh"; return 2
  fi
  if ! bash -n "$v" || ! bash -n "$c"; then
    echo "EXTRACTION FAILED: a block does not parse in $f" >&2; rm -f "$v" "$c" "$fh"; return 2
  fi
  if ! "$s" -n "$v" || ! "$s" -n "$c" || ! "$s" -n "$fh"; then
    echo "EXTRACTION FAILED: a block does not parse under $s in $f" >&2; rm -f "$v" "$c" "$fh"; return 2
  fi
  : > "$W/notrun"; : > "$W/harness"

  out=$(run_op "$s" "$v" verify cold PW PW honest)
  case "$out" in OK\|0\|*\|) ok "V1 cold CE + right credential -> OK, and verify does NOT clear" ;; *) no "V1 got '$out'" ;; esac
  out=$(run_op "$s" "$v" verify cold PW WRONG honest)
  case "$out" in FAIL\|0\|*\|) ok "V2 cold CE + wrong credential -> FAIL" ;; *) no "V2 got '$out'" ;; esac
  # THE DEFECT: on a CE that is already readable, `ls` alone passed ANY credential.
  out=$(run_op "$s" "$v" verify readable PW WRONG honest)
  case "$out" in FAIL\|0\|*\|) ok "V3 READABLE CE + wrong credential -> FAIL (ls is not proof)" ;;
    *) no "V3 a READABLE CE accepted a WRONG credential: got '$out' -- the agent would make it the seal passphrase" ;; esac
  out=$(run_op "$s" "$v" verify readable PW PW honest)
  case "$out" in OK\|0\|*\|) ok "V4 readable CE + right credential -> OK on the keyguard's rc (EVICT-INCOMPLETE owner)" ;;
    *) no "V4 the owner's right credential on a readable CE was refused: got '$out'" ;; esac
  out=$(run_op "$s" "$v" verify cold PW PW lies-no)
  case "$out" in OK\|0\|*\|) ok "V5 cold CE + right credential, rc never reports success -> OK on the cold->readable transition" ;;
    *) no "V5 the cold->readable transition was not accepted: got '$out'" ;; esac
  out=$(run_op "$s" "$v" verify readable PW WRONG lies-yes)
  case "$out" in OK\|*) ok "V6 rc 0 is trusted as the keyguard's answer (the agent's decoy tripwire guards this direction)" ;;
    *) no "V6 rc 0 was not trusted: got '$out'" ;; esac
  out=$(run_op "$s" "$v" verify readable SECRET-KG SECRET-TYPED honest)
  case "$out" in FAIL*'rc='*'pre='*'post='*) ok "V7 the FAIL line carries rc/pre/post" ;; *) no "V7 FAIL line: '$out'" ;; esac
  case "$out" in *SECRET-TYPED*) no "V7 the FAIL line carries the credential" ;; *) ok "V7 the FAIL line never carries the credential" ;; esac
  out=$(run_op "$s" "$v" verify cold SECRET-KG SECRET-KG honest)
  case "$out" in OK*'rc='*'pre='*'post='*) ok "V7b the OK line carries rc/pre/post" ;; *) no "V7b OK line: '$out'" ;; esac
  case "$out" in *SECRET-KG*) no "V7b the OK line carries the credential" ;; *) ok "V7b the OK line never carries the credential" ;; esac
  out=$(run_op "$s" "$v" verify cold PW PW honest "1x")
  case "$out" in ERR-UID\|*) ok "V8 a non-numeric uid -> ERR-UID" ;; *) no "V8 bad uid: got '$out'" ;; esac
  # The stranding shape: a verify that succeeded but whose resume never committed must leave the owner able to
  # retry. Verify never clears, so the second verify still meets the credential and passes.
  out=$(run_op "$s" "$v" verify cold PW PW honest 10 2)
  case "$out" in OK\|0\|*\|) ok "V9 a retry after an accepted verify still passes (verify leaves the credential in place)" ;;
    *) no "V9 a retry after an accepted verify was refused: got '$out' -- the owner is stranded" ;; esac
  # NWP-20261125-25: uid 0 is the gate and 1-9 are never a session; a leading zero names no user. Each is refused
  # before any probe or keyguard call, with the RIGHT credential, so a missing guard reaches cmd and answers OK.
  # 0100 reads the same in octal and decimal against the floor, so only the leading-zero arm refuses it.
  for vc in "V10 0" "V11 9" "V12 010" "V12b 0100"; do
    out=$(run_op "$s" "$v" verify cold PW PW honest "${vc#* }" 1 calls)
    case "$out" in 'ERR-UID|0|||0') ok "${vc% *} verify uid '${vc#* }' -> ERR-UID, and no ls or cmd call" ;;
      *) no "${vc% *} verify uid '${vc#* }' got '$out' (want ERR-UID|0|||0: no call to ls or cmd lock_settings)" ;; esac
  done

  out=$(run_op "$s" "$c" resumeclear readable SECRET-CLR SECRET-CLR honest)
  case "$out" in OK\|1\|*'rc='*\|) ok "C1 resumeclear with the right credential -> OK, cleared" ;; *) no "C1 got '$out'" ;; esac
  case "$out" in *SECRET-CLR*) no "C1 the clear line carries the credential" ;; *) ok "C1 the clear line never carries the credential" ;; esac
  out=$(run_op "$s" "$c" resumeclear readable PW WRONG honest)
  case "$out" in FAIL\|0\|*\|) ok "C2 resumeclear with a wrong credential -> FAIL, nothing cleared" ;; *) no "C2 got '$out'" ;; esac
  out=$(run_op "$s" "$c" resumeclear readable PW PW honest "1x")
  case "$out" in ERR-UID\|*) ok "C3 a non-numeric uid -> ERR-UID" ;; *) no "C3 got '$out'" ;; esac
  for vc in "C4 0" "C5 9" "C6 010" "C6b 0100"; do
    out=$(run_op "$s" "$c" resumeclear readable PW PW honest "${vc#* }" 1 calls)
    case "$out" in 'ERR-UID|0|||0') ok "${vc% *} resumeclear uid '${vc#* }' -> ERR-UID, and no cmd call" ;;
      *) no "${vc% *} resumeclear uid '${vc#* }' got '$out' (want ERR-UID|0|||0: no call to cmd lock_settings)" ;; esac
  done

  # NWP-20261017-03: the key re-assert uses the marker only. The legacy `fido2-hmac s3 <name> <pass>` fallback ran for a
  # nopin marker whose marker assert gave nothing; it staged the typed entry and sent head refs derived from it.
  out=$(run_fido "$s" "$fh" "Y3JlZA==:c2FsdA==:0" nopin HMACHEX)
  case "$out" in OK\|HMACHEX\|fido2-hmac-cold\;\|0) ok "F1 a marker spec asserts from the marker and stashes the hmac" ;; *) no "F1 got '$out'" ;; esac
  out=$(run_fido "$s" "$fh" "Y3JlZA==:c2FsdA==:0" nopin "")
  case "$out" in ERR-NOKEY\|\|fido2-hmac-cold\;\|0) ok "F2 a marker assert that yields nothing is NOKEY -- and never falls back to the store path" ;;
    *) no "F2 a failed marker assert on a nopin marker got '$out' (a fido2-hmac call is the legacy store fallback)" ;; esac
  out=$(run_fido "$s" "$fh" "" nopin "")
  case "$out" in ERR-NOKEY\|\|\|0) ok "F3 a marker with no spec is NOKEY and the agent is not called at all" ;;
    *) no "F3 an empty spec got '$out'" ;; esac
  out=$(run_fido "$s" "$fh" "no-colon-here" nopin HMACHEX)
  case "$out" in ERR-NOKEY\|\|\|0) ok "F4 a spec that is not credId:salt shaped is no spec" ;; *) no "F4 got '$out'" ;; esac
  out=$(run_fido "$s" "$fh" "Y3JlZA==:c2FsdA==:0" pin "")
  case "$out" in ERR-NOKEY\|\|fido2-hmac-cold\;\|0) ok "F5 a PIN marker behaves the same: marker only" ;; *) no "F5 got '$out'" ;; esac
  out=$(run_fido "$s" "$fh" "Y3JlZA==:c2FsdA==:0" nopin HMACHEX marker-only)
  case "$out" in OK\|*) ok "F6 the fixed placeholder handleResume sends is accepted" ;; *) no "F6 got '$out'" ;; esac

  rm -f "$v" "$c" "$fh"
  if [ -s "$W/harness" ]; then echo "HARNESS ERROR: a run file left no identity: $s did not launch it" >&2; return 2; fi
  # run_op and run_fido run inside $( ), so a case that did not run under $s says so through $W/notrun
  if grep -qx "$s" "$W/notrun"; then no "identity: a case did not run under $s"; else ok "identity: every case ran under $s"; fi
  [ -n "$quiet" ] || printf '  -- [%s] %d ok, %d failed\n' "$s" "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "resume verify + clear ops: $SUT"
echo "shells:$SHELLS"
echo "sh identity: $REF_SH"
for s in $SHELLS; do
  suite "$SUT" "$s"; rc=$?
  [ "$rc" = 0 ] || FAILED=1
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT under every shell found):"
  mtmp=$(mktemp -d -p "$W") || exit 2
  mutate() {  # <label> <sed program>
    local label="$1" prog="$2" mf="$mtmp/r.sh" r s alive="" err=""
    if ! sed -E "$prog" "$SUT" > "$mf"; then printf '  ERR   %-64s sed program failed\n' "$label"; MFAIL=1; return; fi
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
    else printf '  ok    %-64s convicted under every shell\n' "$label"; fi
  }
  mutate 'the pre-probe is dropped (a readable CE reads as a transition)' 's@^  _pre=0; ls -d .*$@  _pre=0@'
  mutate 'the rc clause is dropped'                                        's@\[ "\$_vrc" = 0 \] \|\| @@'
  mutate 'the transition clause is dropped'                                's@ \|\| \{ \[ "\$_pre" = 0 \] && \[ "\$_post" = 1 \]; \}@@'
  mutate 'the pre-fix op: ls alone decides'                                's@^  if \[ "\$_vrc" = 0 \] .*then$@  if ls -d "/data/user/$uid/android" >/dev/null 2>\&1; then@'
  mutate 'the FAIL line names the credential'                              's@(resume verify user \$uid FAIL) \(@\1 pass=$pass (@'
  mutate 'the OK line names the credential'                                's@(resume verify user \$uid OK) \(@\1 pass=$pass (@'
  mutate 'the OK line loses rc/pre/post'                                   's@(resume verify user \$uid OK) \(rc=\$_vrc pre=\$_pre post=\$_post\)@\1@'
  mutate 'verify clears the credential again'                              's@^(    echo "OK" > "\$RES"; echo "\[roamd\] resume verify user)@    cmd lock_settings clear --old "$pass" --user "$uid" </dev/null >/dev/null 2>/dev/null\n\1@'
  mutate 'the post-probe looks at a path readable in every CE state'       's@^  _post=0; ls -d "/data/user/\$uid/android"@  _post=0; ls -d "/data/user/$uid"@'
  mutate 'the pre-probe looks at a path readable in every CE state'        's@^  _pre=0; ls -d "/data/user/\$uid/android"@  _pre=0; ls -d "/data/user/$uid"@'
  mutate 'verify asks about the wrong user'                                's@(lock_settings verify --old "\$pass") --user "\$uid"@\1 --user 0@'
  mutate 'resumeclear reports OK whatever clear returned'                  's@if \[ "\$_crc" = 0 \]; then echo "OK" > "\$RES"; else echo "FAIL" > "\$RES"; fi@echo "OK" > "$RES"@'
  mutate 'the legacy store fallback is restored'                          's@^(    H="\$\("\$AGENT" fido2-hmac-cold .*)$@\1\n    [ -z "$H" ] \&\& H="$("$AGENT" fido2-hmac s3 "$name" "$(pw "$pass")" 2>> "$LOG")"@'
  mutate 'the spec gate is dropped (the agent is called with no spec)'    's@^  if \[ -n "\$SPEC" \]; then$@  if true; then@'
  mutate 'the op logs the typed entry'                                    's@(resume fido2 re-assert OK) \$\(date\)@\1 pass=$pass $(date)@'
  mutate 'resumeclear logs the credential'                                 's@(resume clear user \$uid) rc=@\1 pass=$pass rc=@'
  # NWP-20261125-25: each addressed to its own arm, so no other arm of roamd changes
  mutate "verify's floor removed"                                          '/^if \[ "\$op" = "verify" \]; then$/,/^fi$/{/^  \[ "\$uid" -ge 10 \] \|\| /d}'
  mutate "resumeclear's floor removed"                                     '/^if \[ "\$op" = "resumeclear" \]; then$/,/^fi$/{/^  \[ "\$uid" -ge 10 \] \|\| /d}'
  mutate "verify's leading-zero arm removed"                               '/^if \[ "\$op" = "verify" \]; then$/,/^fi$/s@\|0\?\*\) echo "ERR-UID"@) echo "ERR-UID"@'
  mutate 'the floor moved after the cmd call'                              '/^if \[ "\$op" = "verify" \]; then$/,/^fi$/{/^  \[ "\$uid" -ge 10 \] \|\| /d;s@^(  cmd lock_settings verify .*)$@\1\n  [ "$uid" -ge 10 ] || { echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0; }@}'
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
  # harness-error probes: a child that never launches must end the suite with exit 2 and HARNESS ERROR -- not exit 1
  # with FAIL lines, which a mutation run would count as a conviction
  probe() {  # probe <label> <sed program over this suite>
    local cp="$mtmp/suite-probe.sh" rc
    sed "$2" "$0" > "$cp"
    if cmp -s "$0" "$cp"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "$1"; MFAIL=1; return; fi
    bash "$cp" "$SUT" > "$mtmp/probe.out" 2>&1; rc=$?
    if [ "$rc" -eq 1 ] && grep -q 'HARNESS ERROR' "$mtmp/probe.out"; then printf '  ok    %-64s harness error, not a conviction\n' "$1"
    else printf '  XX    %-64s HARNESS ERROR NOT RAISED (rc %s)\n' "$1" "$rc"; MFAIL=1; fi
  }
  probe 'the child never launches' 's/^runsh(){ .*$/runsh(){ return 127; }/'
  mutate_runner
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; FAILED=1; }
fi

exit "${FAILED:-0}"
