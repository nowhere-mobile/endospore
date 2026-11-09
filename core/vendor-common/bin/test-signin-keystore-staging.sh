#!/usr/bin/env bash
# test-signin-keystore-staging.sh [<nowhere_roamd.sh>] [--mutate] -- a LANDED sign-in starts with no other session's
# Keystore staging, and a sign-in that does not land touches nothing (NWP-20261108-01).
#
# WHY THIS IS COMMITTED. keystore-in (restored #keys bundles, named <pkg>.keys) was cleared only by keystore_restore,
# which the `in)` arm called only after a successful #apps restore. A profile with no #apps head (every new profile)
# therefore inherited the previous session's keystore-in; keystore_register_all, at every `out`, then promoted those
# bundles into the new user's apps and the first sign-out sealed them into the new profile's #keys. The arm also ran a
# keystore_push "retry" that could only name a DEPARTED identity's unfinished-reap dump, and a top-level clear of the
# import dir that ran for a refused sign-in too. ks_signin_reset, called once after the CE restore landed, replaces
# all three. This suite drives the REAL extracted `in)` arm and the REAL ks_signin_reset under every shell found,
# with the agent and every other helper stubbed, and asserts WHICH planted files survived.
#
# NWP-20261108-06 (K1-K4, N1-N4): keystore_restore, the only restore of <name>#keys, ran only inside the #apps-success
# branch, so a profile that keeps no apps never restored its #keys head and every sign-out after its first had its
# #keys push refused for want of a receipt. It now runs once on every landed sign-in, after ks_signin_reset, with an
# #apps manifest or without one; on a refused or failed sign-in it never runs.
#
# NWP-20261112-01 (S5, S7, S8, S1b; U1-U5): keystore-in was ONE flat dir, cleared whole by every landed sign-in and
# by keystore_restore, so a sign-in that landed and then failed over a cold-locked user 10 replaced user 10's
# unopened-app bundles with the arriving profile's. Bundles now live at keystore-in/<uid>/ (ks_in_dir): the REAL
# keystore_restore writes only its own user's dir, and ks_signin_reset removes only that dir, flat files of the older
# layout and the dirs of users with no record (userdir_has_record), keeping a parked user's. S1b calls ks_signin_reset
# directly, because in the arm the real restore clears keystore-in/11 as well.
#
# NWP-20261114-10 (S9-S11, S9b; P1-P4): ks_signin_reset removed every nowhere-import/<ns>.keys, so a landing over a
# cold-locked user 10 deleted the bundles keystore_register had moved there for user 10's unopened apps. It now keeps a
# file whose owner (<ns> less its last five digits) is another user with a record, and removes this uid's, a departed
# user's, a malformed name and a symbolic link. S9 plants users/11.xml too, so keeping this uid's own import (P3) fails.
#
#   bash test-signin-keystore-staging.sh              # the cases
#   bash test-signin-keystore-staging.sh --mutate     # ... plus mutants of roamd that must each CONVICT under every shell
#
# Pure logic -- no device. Exit 0 all pass, 1 a check failed, 2 the harness could not extract (never a pass).
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT   # every case root and mutant copy is made inside it

SHELLS=""
if [ -n "${SEED_SHELLS:-}" ]; then SHELLS="$SEED_SHELLS"
else for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done; fi
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }

fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
reroot() { printf '%s\n' "$1" | sed -E 's#([" ])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

PLANTED_MAP='1110001 com.ex.a
1110002 com.ex.b
1010003 com.ex.c'

suite() {  # suite <roamd.sh> [quiet] [shells] -> 0 all ok, 1 a check failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" shells="${3:-$SHELLS}" p=0 x=0 QN IN RI KR KSD KID UDR KRS n sh R HARN="" fa fn u I
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); say "  FAIL  $l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  absent() { [ ! -e "$1" ]; }
  has_line() { grep -qxF -- "$2" "$1" 2>/dev/null; }
  no_line() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
  nlines() { grep -cxF -- "$2" "$1" 2>/dev/null || true; }
  calline() { grep -nxF -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }

  QN=$(fn_of "$f" qn)
  IN=$(arm_of "$f" in)
  KR=$(fn_of "$f" ks_signin_reset)   # absent on a roamd without the fix: NOT an extraction failure, the cases then fail
  KSD=$(grep -E '^KS_(MAP|EXPORT|IMPORT|IN)=' "$f" | sed -E 's#=/data/#=$ROOT/data/#')
  [ -n "$QN" ] || { echo "EXTRACTION FAILED: function qn not found in $f" >&2; return 2; }
  # NWP-20261112-01: the real keystore_restore and the two helpers it and ks_signin_reset call
  KID=$(fn_of "$f" ks_in_dir); UDR=$(fn_of "$f" userdir_has_record); KRS=$(fn_of "$f" keystore_restore)
  for fn in KID UDR KRS; do
    eval "[ -n \"\$$fn\" ]" || { echo "EXTRACTION FAILED: ks_in_dir, userdir_has_record or keystore_restore not found in $f" >&2; return 2; }
  done
  KID=$(reroot "$KID"); UDR=$(reroot "$UDR"); KRS=$(reroot "$KRS")
  n=$(nleft "$KID$UDR$KRS")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: ks_in_dir, userdir_has_record or keystore_restore keeps $n absolute /data path(s)" >&2; return 2; }
  case "$IN" in *'echo "NEEDKEY" > "$RES"'*'echo "BLANK" > "$RES"'*'headblobs'*) ;; *) echo "EXTRACTION FAILED: the in arm in $f" >&2; return 2 ;; esac
  [ "$(printf '%s\n' "$KSD" | grep -c .)" = 4 ] || { echo "EXTRACTION FAILED: the four KS_ definitions in $f" >&2; return 2; }
  RI=$(reroot "$IN")
  n=$(nleft "$RI")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: the in arm keeps $n absolute /data path(s) in live code" >&2; return 2; }
  printf '%s\n' "$QN" > "$W/qn.sh"
  printf '%s\n' "$KR" > "$W/kr.sh"
  printf '%s\n' "$KSD" > "$W/ksd.sh"
  printf '%s\n' "$KID" > "$W/ksdir.sh"
  printf '%s\n' "$UDR" > "$W/udr.sh"
  printf '%s\n' "$KRS" > "$W/krs.sh"
  printf 'case "$op" in\n%s\nesac\n' "$RI" > "$W/arm.sh"

  harness_check() {
    local e
    e=$(grep -m1 -E 'command not found|not found|unbound variable|syntax error|bad substitution' "$1/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$e]"
  }
  # the stub preamble every case script sources, after its ROOT/uid/SIM_* line
  cat > "$W/pre.sh" <<'EOF'
op=in; name=zqprofile; pass=pw; keymode=""; srcunit=""; sesec=""
[ "$SIM_MODE" = needkey ] && keymode=nfcfirst
LOG="$ROOT/roam.log"; RES="$ROOT/res"; STATE="$ROOT/state"; USERDIR="$ROOT/data/user/$uid"; AGENT=agent_sim
agent_sim() {
  case "$1" in
    fido2-is-enrolled)
      case "$SIM_MODE" in
        probe5) return 5 ;;
        probe2) return 2 ;;
        needkey) return 0 ;;
        *) return 1 ;;
      esac ;;
    fido2-hmac) printf '%s\n' aabbccddeeff00112233445566778899; printf '%s' P > "$5/.fido2slots.pre" ;;
    restore)
      echo "restore $3" >> "$ROOT/calls"
      case "$SIM_MODE" in
        blank) return 1 ;;
        blanknet) return 5 ;;
      esac
      case "$3" in *'#apps') [ -n "$SIM_APPCODE" ] && : > "$5/manifest.tsv" ;; esac
      case "$3" in *'#keys') echo r > "$5/com.ex.r.keys" ;; esac
      return 0 ;;
    *) return 1 ;;
  esac
}
pw() { printf '%s\n' "$ROOT/sim/pw"; }
_ms() { echo 0; }
sleep() { return 0; }
for t in stop_mediad usb_host relabel_launcher remap_media_db insert_deferred_media remap_per_pkg _tlog _ssum acct_restore remap_tree reown_ext_appdata \
         hold_ondemand od_parked_report reap_stale_ondemand reap_orphan_provisioned restorecon \
         uiderrors_floor_take uiderrors_floor_commit tz_surface; do
  eval "$t() { :; }"
done
in_scope_tokens() { printf '+de +media'; }   # NWP-20261113-15: the IN line's scope tokens
bt_reset() { BT_RESTORED=0; return 0; }
print() {
  local nl=1
  while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done
  if [ "$nl" = 1 ]; then printf '%s\n' "$*"; else printf '%s' "$*"; fi
}
timeout() { shift 3; "$@"; }
keystore_push() { echo keystore_push >> "$ROOT/calls"; }
if [ -n "$GREPFAIL" ]; then
  grep() { case "$*" in *-vE*keystore-map*) printf partial; return 2 ;; esac; command grep "$@"; }
fi
EOF
  libs() { printf '. "%s"\n' "$W/pre.sh" "$W/ksd.sh" "$W/qn.sh" "$W/ksdir.sh" "$W/udr.sh" "$W/kr.sh" "$W/krs.sh"; }
  # run_case <root> <shell> <ok|blank|blanknet|probe5|probe2|needkey> [appcode] [grepfail]: the REAL arm in <shell>
  run_case() {
    local ROOT="$1" s="$2" mode="$3" appcode="" gf="" a
    shift 3; for a in "$@"; do case "$a" in appcode) appcode=1 ;; grepfail) gf=1 ;; esac; done
    {
      printf "ROOT='%s'; uid=11; SIM_MODE='%s'; SIM_APPCODE='%s'; GREPFAIL='%s'\n" "$ROOT" "$mode" "$appcode" "$gf"
      libs
      printf '. "%s"\n' "$W/arm.sh"
    } > "$ROOT/case.sh"
    "$s" "$ROOT/case.sh" >/dev/null 2>>"$ROOT/sim/stderr"
    harness_check "$ROOT"
  }
  # run_fn <root> <shell> <uid> <command>: one roamd function called directly, uid as given, the same stubs
  run_fn() {
    local ROOT="$1" s="$2"
    {
      printf "ROOT='%s'; uid='%s'; SIM_MODE=ok; SIM_APPCODE=''; GREPFAIL=''\n" "$ROOT" "$3"
      libs
      printf '%s\n' "$4"
    } > "$ROOT/fn.sh"
    "$s" "$ROOT/fn.sh" >/dev/null 2>>"$ROOT/sim/stderr"
    harness_check "$ROOT"
  }
  mkroot() {  # mkroot [nomap|emptymap]: plants one session's leftover staging
    R=$(mktemp -d -p "$W")
    mkdir -p "$R/sim" "$R/state" "$R/data/nowhere/keystore-in" "$R/data/misc/keystore/nowhere-import" \
             "$R/data/misc/keystore/nowhere-export" "$R/data/user/11" "$R/data/nowhere/keystore-in/11" "$R/data/system/users"
    echo a > "$R/data/nowhere/keystore-in/11/com.ex.a.keys"   # a recycled uid's leftover (NWP-20261112-01)
    echo i > "$R/data/misc/keystore/nowhere-import/1110009.keys"
    echo e2 > "$R/data/misc/keystore/nowhere-export/1110002.keys"
    echo e3 > "$R/data/misc/keystore/nowhere-export/1010003.keys"
    case "${1:-}" in
      nomap) ;;
      emptymap) : > "$R/data/nowhere/keystore-map" ;;
      *) printf '%s\n' "$PLANTED_MAP" > "$R/data/nowhere/keystore-map" ;;
    esac
  }
  # one line per planted file: its path and checksum, so a refused sign-in is proven byte for byte
  snap() { ( cd "$1/data" && find . -type f | LC_ALL=C sort | while read -r q; do printf '%s %s\n' "$q" "$(cksum < "$q")"; done ); }
  only_restored() {
    [ "$(find "$1/data/nowhere/keystore-in" "$1/data/misc/keystore/nowhere-import" "$1/data/misc/keystore/nowhere-export" -name '*.keys' 2>/dev/null)" = "$1/data/nowhere/keystore-in/11/com.ex.r.keys" ]
  }
  held() { [ "$(cat "$1" 2>/dev/null)" = "$2" ]; }
  # one-line code pins on the extracted arm, comments stripped
  armcode() { printf '%s\n' "$IN" | grep -vE '^[[:space:]]*#'; }
  lineno() { printf '%s\n' "$IN" | grep -nF -- "$1" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1; }

  for sh in $shells; do
    say "== [$sh] S1: a landed sign-in leaves no other session's staging =="
    mkroot; R1="$R"
    run_case "$R" "$sh" ok
    chk "S1 [$sh] the reply is OK 11" held "$R/res" "OK 11"
    chk "S1 [$sh] the only .keys under keystore-in, import or export is the one keystore_restore staged (NWP-20261108-06)" only_restored "$R"
    chk "S1 [$sh] keystore-in holds this user's dir only" eqv "$(ls -A "$R/data/nowhere/keystore-in" 2>/dev/null)" 11
    chk "S1 [$sh] and that dir holds that one bundle only" eqv "$(ls -A "$R/data/nowhere/keystore-in/11" 2>/dev/null)" com.ex.r.keys
    chk "S1 [$sh] keystore-map is exactly this uid's complement" held "$R/data/nowhere/keystore-map" "1010003 com.ex.c"
    chk "S1 [$sh] no .kssignin temp is left in the state dir" eqv "$(ls -A "$R/state" | grep -c '^\.kssignin')" 0

    say "== [$sh] S4: the log line carries counts only =="
    chk "S4 [$sh] exactly one reset line" eqv "$(grep -cF 'keystore staging reset for user 11:' "$R/roam.log" 2>/dev/null)" 1
    chk "S4 [$sh] the line is the eight counts" has_line "$R/roam.log" "[roamd] IN keystore staging reset for user 11: 1 bundle(s) left by an earlier session, 0 flat bundle(s) of an older build, 0 departed session dir(s), 0 parked session dir(s) kept, 1 import(s), 0 parked import(s) kept, 2 unsealed dump(s), 2 map row(s) of an earlier user 11 (NWP-20261108-01, NWP-20261112-01)"
    chk "S4 [$sh] it names no package, namespace or profile" eqv "$(grep 'keystore staging reset' "$R/roam.log" 2>/dev/null | grep -cE 'com\.ex|11100|zqprofile')" 0
    chk "K1 [$sh] no chooser dir: keystore_restore called exactly once" eqv "$(nlines "$R/calls" 'restore zqprofile#keys')" 1
    command rm -rf "$R1"

    say "== [$sh] K1: a landed sign-in whose #apps restore leaves no manifest still restores #keys =="
    mkroot; mkdir -p "$R/data/user/0/com.nowhere.chooser/files"
    run_case "$R" "$sh" ok
    chk "K1 [$sh] the #apps restore ran" has_line "$R/calls" 'restore zqprofile#apps'
    chk "K1 [$sh] no manifest: keystore_restore called exactly once" eqv "$(nlines "$R/calls" 'restore zqprofile#keys')" 1
    chk "K1 [$sh] its bundle survived the arm (it ran after ks_signin_reset)" held "$R/data/nowhere/keystore-in/11/com.ex.r.keys" r
    chk "K1 [$sh] the earlier session's bundle did not" absent "$R/data/nowhere/keystore-in/11/com.ex.a.keys"
    command rm -rf "$R"

    say "== [$sh] S2: no keystore_push; keystore_restore runs after the reset =="
    mkroot; mkdir -p "$R/data/user/0/com.nowhere.chooser/files"
    run_case "$R" "$sh" ok appcode
    chk "S2 [$sh] keystore_restore was called" has_line "$R/calls" 'restore zqprofile#keys'
    chk "S2 [$sh] keystore_push was never called" no_line "$R/calls" keystore_push
    chk "S2 [$sh] the bundle keystore_restore staged survived the arm" held "$R/data/nowhere/keystore-in/11/com.ex.r.keys" r
    chk "S2 [$sh] the earlier session's bundle did not" absent "$R/data/nowhere/keystore-in/11/com.ex.a.keys"
    chk "K2 [$sh] with a manifest: keystore_restore called exactly once" eqv "$(nlines "$R/calls" 'restore zqprofile#keys')" 1
    a=$(calline "$R/calls" 'restore zqprofile#apps'); b=$(calline "$R/calls" 'restore zqprofile#keys')
    chk "K2 [$sh] it follows the #apps restore in the calls file" eval '[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]'
    command rm -rf "$R"

    say "== [$sh] S3: a refused or failed sign-in touches nothing =="
    for fa in needkey blank blanknet probe5 probe2; do
      mkroot; : > "$R/data/system/users/10.xml"; echo k10 > "$R/data/misc/keystore/nowhere-import/1010004.keys"
      before=$(snap "$R")
      run_case "$R" "$sh" "$fa" appcode
      chk "S3 [$sh] $fa: every planted file is byte for byte as it was" eqv "$(snap "$R")" "$before"
      chk "S11 [$sh] $fa: user 10's staged import is untouched" held "$R/data/misc/keystore/nowhere-import/1010004.keys" k10
      chk "K3 [$sh] $fa: keystore_restore was never called" no_line "$R/calls" 'restore zqprofile#keys'
      chk "S3 [$sh] $fa: keystore_push was never called" no_line "$R/calls" keystore_push
      command rm -rf "$R"
    done

    say "== [$sh] S1b: ks_signin_reset removes this uid's own keystore-in dir (NWP-20261112-01) =="
    mkroot; run_fn "$R" "$sh" 11 'ks_signin_reset 11'
    chk "S1b [$sh] keystore-in/11 is gone" absent "$R/data/nowhere/keystore-in/11"
    command rm -rf "$R"

    say "== [$sh] S5: a sign-in that lands keeps a parked user's restored bundles (NWP-20261112-01) =="
    mkroot; mkdir -p "$R/data/nowhere/keystore-in/10"; echo p > "$R/data/nowhere/keystore-in/10/com.ex.p.keys"
    cp "$R/data/nowhere/keystore-in/10/com.ex.p.keys" "$R/sim/p.before"; : > "$R/data/system/users/10.xml"
    run_case "$R" "$sh" ok
    chk "S5 [$sh] the reply is OK 11" held "$R/res" "OK 11"
    chk "S5 [$sh] user 10's bundle is byte for byte as it was" cmp -s "$R/data/nowhere/keystore-in/10/com.ex.p.keys" "$R/sim/p.before"
    chk "S5 [$sh] the arriving profile's bundle is in keystore-in/11" held "$R/data/nowhere/keystore-in/11/com.ex.r.keys" r
    chk "S5 [$sh] no flat bundle is in keystore-in" eqv "$(find "$R/data/nowhere/keystore-in" -maxdepth 1 -type f -name '*.keys' 2>/dev/null)" ""
    chk "S5 [$sh] the log counts one parked session dir kept" eqv "$(grep -cF ', 1 parked session dir(s) kept,' "$R/roam.log" 2>/dev/null)" 1
    command rm -rf "$R"

    say "== [$sh] S7: a departed user's dir and an older build's flat bundle go; a parked user's stays (NWP-20261112-01) =="
    mkroot; mkdir -p "$R/data/nowhere/keystore-in/10" "$R/data/nowhere/keystore-in/12"
    echo p > "$R/data/nowhere/keystore-in/10/com.ex.p.keys"; : > "$R/data/system/users/10.xml"
    echo q > "$R/data/nowhere/keystore-in/12/com.ex.q.keys"; echo o > "$R/data/nowhere/keystore-in/com.ex.old.keys"
    run_case "$R" "$sh" ok
    chk "S7 [$sh] keystore-in/12 (no record for user 12) is gone" absent "$R/data/nowhere/keystore-in/12"
    chk "S7 [$sh] the flat bundle of the older layout is gone" absent "$R/data/nowhere/keystore-in/com.ex.old.keys"
    chk "S7 [$sh] keystore-in/10 (user 10 has a record) is kept" held "$R/data/nowhere/keystore-in/10/com.ex.p.keys" p
    chk "S7 [$sh] the log counts 1 flat, 1 departed, 1 parked" eqv "$(grep -cF ': 1 bundle(s) left by an earlier session, 1 flat bundle(s) of an older build, 1 departed session dir(s), 1 parked session dir(s) kept,' "$R/roam.log" 2>/dev/null)" 1
    command rm -rf "$R"

    say "== [$sh] S9: a sign-in that lands keeps a parked user's staged imports (NWP-20261114-10) =="
    mkroot; I="$R/data/misc/keystore/nowhere-import"
    : > "$R/data/system/users/10.xml"; : > "$R/data/system/users/11.xml"   # user 10 is parked; 11 is the landing user
    echo k10 > "$I/1010004.keys"; cp "$I/1010004.keys" "$R/sim/k10.before"
    echo k12 > "$I/1210005.keys"; echo x > "$I/x.keys"   # 1110009.keys (this uid) comes from mkroot
    run_case "$R" "$sh" ok
    chk "S9 [$sh] the reply is OK 11" held "$R/res" "OK 11"
    chk "S9 [$sh] user 10's import is byte for byte as it was" cmp -s "$I/1010004.keys" "$R/sim/k10.before"
    chk "S9 [$sh] this uid's import is gone" absent "$I/1110009.keys"
    chk "S9 [$sh] the import of user 12 (no record) is gone" absent "$I/1210005.keys"
    chk "S9 [$sh] the malformed name is gone" absent "$I/x.keys"
    chk "S9 [$sh] the log counts 3 removed, 1 parked import kept" eqv "$(grep -cF ', 3 import(s), 1 parked import(s) kept,' "$R/roam.log" 2>/dev/null)" 1
    chk "S9 [$sh] the reset line names no namespace" eqv "$(grep 'keystore staging reset' "$R/roam.log" 2>/dev/null | grep -cE '1010004|com\.ex|zqprofile')" 0
    command rm -rf "$R"

    say "== [$sh] S9b: a symbolic link in the import dir is removed, never followed (NWP-20261114-10) =="
    mkroot; I="$R/data/misc/keystore/nowhere-import"
    : > "$R/data/system/users/10.xml"; echo t > "$R/sim/target"; ln -s "$R/sim/target" "$I/1010006.keys"
    run_case "$R" "$sh" ok
    chk "S9b [$sh] the link is gone" eval '[ ! -e "$I/1010006.keys" ] && [ ! -L "$I/1010006.keys" ]'
    chk "S9b [$sh] its target is untouched" held "$R/sim/target" t
    chk "S9b [$sh] the log counts 2 removed, 0 parked import kept" eqv "$(grep -cF ', 2 import(s), 0 parked import(s) kept,' "$R/roam.log" 2>/dev/null)" 1
    command rm -rf "$R"

    say "== [$sh] S10: an import whose owner has no record is removed (NWP-20261114-10) =="
    mkroot; I="$R/data/misc/keystore/nowhere-import"
    : > "$R/data/system/users/0.xml"; echo k10 > "$I/1010004.keys"   # only user 0's record, as a control
    run_case "$R" "$sh" ok
    chk "S10 [$sh] user 10's import is gone" absent "$I/1010004.keys"
    chk "S10 [$sh] the log counts 2 removed, 0 parked import kept" eqv "$(grep -cF ', 2 import(s), 0 parked import(s) kept,' "$R/roam.log" 2>/dev/null)" 1
    command rm -rf "$R"

    say "== [$sh] S8: with no numeric uid keystore_restore writes nothing under keystore-in (NWP-20261112-01) =="
    for u in '' 1x; do
      mkroot; command rm -rf "$R/data/nowhere/keystore-in/11"
      mkdir -p "$R/data/nowhere/keystore-in/10"; echo p > "$R/data/nowhere/keystore-in/10/com.ex.p.keys"
      run_fn "$R" "$sh" "$u" keystore_restore
      chk "S8 [$sh] uid '$u': keystore-in holds only user 10's bundle" eqv "$(cd "$R/data/nowhere/keystore-in" && find . -print | LC_ALL=C sort | tr '\n' ' ')" ". ./10 ./10/com.ex.p.keys "
      chk "S8 [$sh] uid '$u': no #keys restore was asked of the agent" no_line "$R/calls" 'restore zqprofile#keys'
      chk "S8 [$sh] uid '$u': one skipped line" eqv "$(grep -cF 'IN keystore restore skipped: no user id in scope, 0 bundle(s) staged' "$R/roam.log" 2>/dev/null)" 1
      command rm -rf "$R"
    done

    say "== [$sh] S12: the map is only ever rewritten from a whole prune =="
    mkroot nomap; run_case "$R" "$sh" ok
    chk "S12 [$sh] an absent map is not created" absent "$R/data/nowhere/keystore-map"
    command rm -rf "$R"
    mkroot emptymap; run_case "$R" "$sh" ok
    chk "S12 [$sh] an empty map stays empty" eqv "$(wc -c < "$R/data/nowhere/keystore-map" | tr -d ' ')" 0
    command rm -rf "$R"
    mkroot; printf '%s\n' "$PLANTED_MAP" > "$W/map.before"
    run_case "$R" "$sh" ok grepfail
    chk "S12 [$sh] a prune that fails (grep status 2) leaves the map byte for byte" cmp -s "$R/data/nowhere/keystore-map" "$W/map.before"
    chk "S12 [$sh] and leaves no temp behind" eqv "$(ls -A "$R/state" | grep -c '^\.kssignin')" 0
    command rm -rf "$R"

    say "== [$sh] S6: source pins on the arm =="
    n=$(armcode | grep -cF 'ks_signin_reset "$uid"')
    chk "S6 [$sh] exactly one ks_signin_reset \"\$uid\" in the arm" eqv "$n" 1
    a=$(lineno 'NOWHERE_PHASE=apps NOWHERE_CLAIMS_SEED'); b=$(lineno 'ks_signin_reset "$uid"'); c=$(lineno 'CHOOSER0="')
    chk "S6 [$sh] it follows the CE restore and precedes CHOOSER0=" eval '[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]'
    chk "S6 [$sh] the arm calls no keystore_push" eqv "$(armcode | grep -c 'keystore_push')" 0
    chk "S6 [$sh] no top-level KS_IMPORT clear on every in" eqv "$(grep -cF '[ "$op" = "in" ] && rm -f "$KS_IMPORT"' "$f")" 0

    say "== [$sh] K4: source pins on the keystore_restore call =="
    chk "K4 [$sh] exactly one keystore_restore call in the arm" eqv "$(armcode | grep -cxE '[[:space:]]*keystore_restore([[:space:]].*)?')" 1
    e=$(lineno '_tlog appcode-agent "$_tt"   # the blank/failed arm')
    a=""; [ -n "$e" ] && a=$(printf '%s\n' "$IN" | awk -v s="$e" 'NR > s && /^      fi$/ {print NR; exit}')
    b=$(printf '%s\n' "$IN" | grep -nE '^[[:space:]]*keystore_restore([[:space:]]|$)' | head -1 | cut -d: -f1)
    c=$(printf '%s\n' "$IN" | grep -nF '# Roamed prefs' | head -1 | cut -d: -f1)
    chk "K4 [$sh] it follows the #apps block's fi and precedes # Roamed prefs" eval '[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]'
  done

  chk "the harness ran clean (no undefined function, unbound variable or parse error)" eqv "$HARN" ""
  say ""
  say "$p passed, $x failed"
  [ "$x" = 0 ]
}

if [ "$MUTATE" = no ]; then suite "$SUT"; exit $?; fi

suite "$SUT"; rc=$?
[ "$rc" = 0 ] || exit "$rc"

# --- mutants ------------------------------------------------------------------------------------------------
# Each is a transform of roamd's text, by exact line; a mutant that changes nothing is a failure of the suite.
L_CALL='      ks_signin_reset "$uid"   # NWP-20261108-01: this landed sign-in drops every other session'"'"'s Keystore staging, before keystore_restore'
L_RF='      for _pn in media.restore-ok .btlogoff .had_account; do [ -e "$STATE/$_pn" ] && mv "$STATE/$_pn" "$PARK/" 2>> "$LOG"; done'
L_PRUNE='    grep -vE "^${_ksu}[0-9]{5}( |$)" "$KS_MAP" > "$_kst" 2>/dev/null; _ksr=$?'
L_EXP='  for _ksf in "$KS_EXPORT"/*.keys; do [ -e "$_ksf" ] || continue; rm -f "$_ksf" 2>>"$LOG" && _ksc=$((_ksc + 1)); done'
L_KR='      keystore_restore   # #210 p2: pull name#keys; keystore_register promotes each bundle at the tap'
L_RMIN='    rm -rf "$KS_IN/$_ksu" 2>>"$LOG"'
L_KRRM='  rm -rf "$_krd"; mkdir -p "$_krd" 2>>"$LOG" || return 0'
L_KEEP='    if userdir_has_record "$_ksn"; then _ksk=$((_ksk + 1)); continue; fi'
L_GONE='    rm -rf "$_ksf" 2>>"$LOG" && _ksg=$((_ksg + 1))'
L_FLAT='  for _ksf in "$KS_IN"/*.keys; do [ -e "$_ksf" ] || continue; rm -f "$_ksf" 2>>"$LOG" && _kse=$((_kse + 1)); done'
L_KID='  case "$_u" in '"''"'|*[!0-9]*) return 1 ;; esac'
L_AC='[ "$op" = "in" ] && rm -f "$STATE"/.armcred.* 2>/dev/null   # DIA-20260813-09: a new session must re-arm before ARM-PIN may claim PINSET'
L_WB='    if [ "$_ksr" = 0 ] || [ "$_ksr" = 1 ]; then mv -f "$_kst" "$KS_MAP" 2>>"$LOG" || { _ksd=0; echo "[roamd] IN keystore-map rewrite FAILED -- the map is unchanged (NWP-20261124-24)" >> "$LOG"; }; else _ksd=0; fi'
L_RIN='        print -r -- "[roamd] IN $(qn "$name") #apps code restored → user0 chooser $(date)" >> "$LOG"'
L_IOWN='      case "$_ksn" in '"''"'|*[!0-9]*) ;; ??????*) _kso=${_ksn%?????} ;; esac'
L_IKEEP='    if [ -n "$_kso" ] && [ "$_kso" != "$_ksu" ] && userdir_has_record "$_kso"; then _ksj=$((_ksj + 1)); continue; fi'
M_P2='      case "$_ksn" in '"''"'|*[!0-9]*) ;; ??????*) _kso=${_ksn%"${_ksn#?????}"} ;; esac'
M_P3='    if [ -n "$_kso" ] && userdir_has_record "$_kso"; then _ksj=$((_ksj + 1)); continue; fi'
M_P4='    if [ -n "$_kso" ] && [ "$_kso" != "$_ksu" ] && userdir_has_record "$_kso"; then continue; fi'
for l in "$L_CALL" "$L_RF" "$L_PRUNE" "$L_EXP" "$L_KR" "$L_RMIN" "$L_AC" "$L_WB" "$L_RIN" \
         "$L_KRRM" "$L_KEEP" "$L_GONE" "$L_FLAT" "$L_KID" "$L_IOWN" "$L_IKEEP"; do
  [ "$(grep -cxF -- "$l" "$SUT")" = 1 ] || { echo "EXTRACTION FAILED: anchor line not unique in $SUT: $l" >&2; exit 2; }
done
export L_CALL L_RF L_PRUNE L_EXP L_KR L_RMIN L_AC L_WB L_RIN L_KRRM L_KEEP L_GONE L_FLAT L_KID L_IOWN L_IKEEP \
       M_P2 M_P3 M_P4
MFAIL=0
# mut <name> <awk-program>: awk reads the anchors from the environment
mut() {
  local name="$1" prog="$2" t out r s
  t=$(mktemp -p "$W")
  awk "$prog" "$SUT" > "$t"
  if cmp -s "$t" "$SUT"; then echo "  FAIL  mutant did not apply: $name"; MFAIL=1; command rm -f "$t"; return; fi
  for s in $SHELLS; do
    out=$(suite "$t" quiet "$s" 2>&1); r=$?
    if [ "$r" = 1 ]; then echo "  ok    CONVICTED [$s]: $name"
    else echo "  FAIL  NOT CONVICTED [$s] (rc=$r): $name"; MFAIL=1; fi
  done
  command rm -f "$t"
}
mut "M1 the call is removed" '$0 == ENVIRON["L_CALL"] {next} {print}'
mut "M2 the call runs above the CE restore, in the commit arm" '$0 == ENVIRON["L_CALL"] {next} {print} $0 == ENVIRON["L_RF"] {print ENVIRON["L_CALL"]}'
mut "M3 the prune drops every row" '$0 == ENVIRON["L_PRUNE"] {print "    : > \"$_kst\"; _ksr=0"; next} {print}'
mut "M4 the prune keeps this uid's rows" '$0 == ENVIRON["L_PRUNE"] {sub(/\^\$\{_ksu\}/, "^x${_ksu}")} {print}'
mut "M5 keystore-export is not cleared" '$0 == ENVIRON["L_EXP"] {next} {print}'
mut "M6 the keystore_push retry is restored" '$0 == ENVIRON["L_KR"] {print "      keystore_push"} {print}'
mut "M7 this uid's keystore-in dir is not cleared" '$0 == ENVIRON["L_RMIN"] {next} {print}'
mut "M8 the top-level import clear is restored" '$0 == ENVIRON["L_AC"] {print "[ \"$op\" = \"in\" ] && rm -f \"$KS_IMPORT\"/*.keys 2>/dev/null"} {print}'
mut "M9 the map is written back whatever grep said" '$0 == ENVIRON["L_WB"] {print "    mv -f \"$_kst\" \"$KS_MAP\" 2>>\"$LOG\""; next} {print}'
mut "N1 the keystore_restore call moved back inside the #apps branch" '$0 == ENVIRON["L_KR"] {next} {print} $0 == ENVIRON["L_RIN"] {print "        keystore_restore"}'
mut "N2 a second keystore_restore call added inside the #apps branch" '{print} $0 == ENVIRON["L_RIN"] {print "        keystore_restore"}'
mut "N3 the keystore_restore call moved above ks_signin_reset" '$0 == ENVIRON["L_KR"] {next} $0 == ENVIRON["L_CALL"] {print "      keystore_restore"} {print}'
mut "N4 the keystore_restore call removed" '$0 == ENVIRON["L_KR"] {next} {print}'
mut "U1 keystore_restore removes keystore-in whole" '$0 == ENVIRON["L_KRRM"] {print "  rm -rf \"$KS_IN\"; mkdir -p \"$_krd\" 2>>\"$LOG\" || return 0"; next} {print}'
mut "U2 ks_signin_reset removes every subdir" '$0 == ENVIRON["L_KEEP"] {next} {print}'
mut "U3 ks_signin_reset keeps a subdir without a record" '$0 == ENVIRON["L_GONE"] {next} {print}'
mut "U4 ks_signin_reset keeps flat bundles" '$0 == ENVIRON["L_FLAT"] {next} {print}'
mut "U5 ks_in_dir accepts an empty or non-numeric uid" '$0 == ENVIRON["L_KID"] {next} {print}'
mut "P1 the record check on imports dropped (every import removed)" '$0 == ENVIRON["L_IKEEP"] {next} {print}'
mut "P2 the owner is the first five digits" '$0 == ENVIRON["L_IOWN"] {print ENVIRON["M_P2"]; next} {print}'
mut "P3 this uid's own import kept" '$0 == ENVIRON["L_IKEEP"] {print ENVIRON["M_P3"]; next} {print}'
mut "P4 the kept count never incremented" '$0 == ENVIRON["L_IKEEP"] {print ENVIRON["M_P4"]; next} {print}'
[ "$MFAIL" = 0 ] || exit 1
echo "all mutants convicted"
