#!/usr/bin/env bash
# test-in-refused-noop.sh [<nowhere_roamd.sh>] [--mutate] -- a REFUSED roam-in is a pure no-op on the live session,
# and a COMMITTING one resets what belongs to the login (NWP-20260822-09, NWP-20260823-11).
#
# WHY THIS IS COMMITTED. The `in)` arm of nowhere_roamd.sh resets four per-login entries of $STATE --
# restore-receipts (#72), media.restore-ok, .btlogoff, .had_account -- and swaps the .fido2hmac stash and the
# .fido2slots spec. All of it belongs in the COMMIT arm (`fido2_needed = 0 || fresh_hmac set`), whose complement is
# the NEEDKEY refusal. Above that test, a straggler NEEDKEY seconds after a successful 2FA sign-in deletes the LIVE
# session's #72 receipts (every later scope seal is then refused), a leftover .btlogoff makes the next periodic
# seal wipe a live user's Bluetooth bonds and seal the emptied pairings over the profile, and a leftover
# .had_account turns the #743 guard into a permanent false alarm for later profiles. Nothing else executes this:
# test-btlogoff-logoff-only.sh covers the `out` arm, test-had-account-marker.sh the marker's arming rule, and
# test-userdir-orphan.sh drives the `in` arm but asserts only the SSAID seed. So this suite plants every entry,
# drives the REAL extracted arm, and asserts WHICH ENTRIES SURVIVED and in what ORDER. Since NWP-20261020-01 the
# commit arm parks those six entries in $STATE/.in-park (first discarding a park a killed run left, C7), a sign-in
# whose restore then fails puts each one back as it was (C3-C6), and when the park cannot be made the arm deletes
# them as before that slice and puts nothing back (NP1-NP5). Since NWP-20261117-16 the media daemon stop belongs to a
# landed sign-in alone: a refusal or a failed CE restore makes no stop_mediad call (N1, U1, U2, C3-C5), a landed one
# makes exactly one, after its CE restore and before its reply (C1, C2), and S1-S4 convict the other positions.
# Since NWP-20261124-05 the stop is the first line of the landing branch, after the scope verdict; its anchor is the
# line it precedes there (L_AP). test-in-scope-net-blank.sh covers a scope restore that cannot reach the store.
# Since NWP-20261129-17 a landed sign-in keeps its park (C1, C2): the daemon drops or restores it once it knows whether
# the OK became a session (core/agent/in_park.go, in_park_test.go, test-in-park.sh).
#
# Since NWP-20261113-24 each case writes the extracted arm, its variables and the stubs into a runner file in the
# case root and executes that file in a CHILD of each shell found among bash, sh, dash and mksh (the device's
# /system/bin/sh), tagging every line `[<sh>]`. Before that the arm ran in a bash subshell only, under a `print`
# function that shadowed mksh's builtin, so a comparison mksh evaluates differently could reach the resets on the
# device alone. The `print` shim is defined only where the shell has no `print` of its own. Each runner records the
# identity of the shell that ran it: a runner that recorded none is a HARNESS error (exit 2), and so is one that
# launched and then hit an undefined name or a parse error; one that recorded the wrong shell fails that shell's line.
# A mutant is convicted only when it fails under EVERY shell found.
#
#   bash test-in-refused-noop.sh              # the cases
#   bash test-in-refused-noop.sh --mutate     # ... plus mutants of roamd that must each CONVICT
#
# Pure logic -- no device. The arm is EXTRACTED by anchor, never copied, and re-rooted to a temp tree; the agent
# and every helper it calls are stubs that do only what a case says.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT   # every case root and mutant copy is made inside it

HEX=aabbccddeeff00112233445566778899

SHELLS=""; for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
IDPROBE='_id="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; [ -n "$_id" ] || _id=posix; _pr=none; command -v print >/dev/null 2>&1 && _pr=builtin'
REF_SH=""; command -v sh >/dev/null 2>&1 && REF_SH=$(sh -c "$IDPROBE; printf '%s|%s\n' \"\$_id\" \"\$_pr\"")
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
sq(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# runsh <shell> <runner> <stderr file>: ONE line, the anchor of the runner-ignores-its-shell probe below
runsh(){ "$1" "$2" >/dev/null 2>>"$3"; }
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

fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
reroot() { printf '%s\n' "$1" | sed -E 's#([" ])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> <shell> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" SH="$2" quiet="${3:-}" p=0 x=0 QN IN RI R n v NPMSG PF NOID=0 WRONGSH=0 HARN HARNN HARN1
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    [$SH] $l"; else x=$((x+1)); say "  FAIL  [$SH] $l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  absent() { [ ! -e "$1" ]; }
  holds() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }
  has_log() { grep -qF -- "$2" "$1" 2>/dev/null; }

  QN=$(fn_of "$f" qn)
  IN=$(arm_of "$f" in)
  [ -n "$QN" ] || { echo "EXTRACTION FAILED: function qn not found in $f" >&2; return 2; }
  case "$IN" in *'echo "NEEDKEY" > "$RES"'*'echo "BLANK" > "$RES"'*'headblobs'*) ;; *) echo "EXTRACTION FAILED: the in arm in $f" >&2; return 2 ;; esac
  case "$IN" in *'$STATE/restore-receipts"'*) ;; *) echo "EXTRACTION FAILED: the restore-receipts reset in $f" >&2; return 2 ;; esac
  RI=$(reroot "$IN")
  n=$(printf '%s\n' "$RI" | grep -o '\$ROOT/data/' | grep -c .)
  [ "$n" -ge 5 ] || { echo "RE-ROOT FAILED: the in arm has $n rewritten paths, want >= 5" >&2; return 2; }
  n=$(nleft "$RI")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: the in arm keeps $n absolute /data path(s) in live code" >&2; return 2; }

  HARN=""; HARNN=0; HARN1=""
  # every shell's wording: a missing command is bash `command not found`, dash `<n>: x: not found`, mksh
  # `x: inaccessible or not found`; an unset name under set -u is bash `unbound variable`, dash and mksh
  # `parameter not set`
  harness_check() {
    local e
    e=$(grep -m1 -E 'not found|unbound variable|parameter not set|syntax error|Syntax error|bad substitution|Bad substitution' "$1/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || { HARN="$HARN [$e]"; HARNN=$((HARNN+1)); [ -n "$HARN1" ] || HARN1="$e"; }
  }
  # idcheck <root>: the runner that recorded no identity never launched (a HARNESS error, never a FAIL a mutant
  # could be convicted by); one that recorded another shell's identity fails this shell's identity line
  idcheck() {
    if [ ! -s "$1/sim/shell.id" ]; then NOID=1
    elif ! idok "$SH" "$1/sim/shell.id"; then WRONGSH=1; fi
  }
  # mkrunner <file> <root> <mode>: the runner the shell under test executes -- its identity probe, the print shim,
  # the case's assignments (every value single-quoted), the stubs, qn and the REAL arm. POSIX only: it runs under
  # every shell found.
  mkrunner() {
    local km=""
    [ "$3" != needkey ] || km=nfcfirst
    {
      printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$2/sim/shell.id")"
      printf '%s\n' "$PRINT_SHIM"
      printf 'set -u\n'
      printf 'ROOT=%s; uid=11; SIM_MODE=%s; op=in; name=prof; pass=pw; keymode=%s; srcunit=""; sesec=""\n' \
        "$(sq "$2")" "$(sq "$3")" "$(sq "$km")"
      printf 'HEX=%s; NOPARK=%s; KEEPPARK=%s\n' "$(sq "$HEX")" "$(sq "${NOPARK:-}")" "$(sq "${KEEPPARK:-}")"
      cat <<'STUB'
LOG="$ROOT/roam.log"; RES="$ROOT/res"; STATE="$ROOT/state"; USERDIR="$ROOT/data/user/$uid"; AGENT=agent_sim
agent_sim() {
  case "$1" in
    fido2-is-enrolled)
      case "$SIM_MODE" in
        probe5) return 5 ;;
        probe2) return 2 ;;
        needkey|twofa|twofablank) return 0 ;;
        *) return 1 ;;
      esac ;;
    fido2-hmac) printf '%s\n' "$HEX"; printf '%s' P > "$5/.fido2slots.pre" ;;
    restore)
      if [ ! -e "$ROOT/sim/first" ]; then
        { [ -e "$STATE/restore-receipts" ] && echo receipts; [ -e "$STATE/media.restore-ok" ] && echo mediaok; true; } > "$ROOT/sim/first"
        [ -s "$ROOT/sim/first" ] || echo none > "$ROOT/sim/first"
      fi
      case "$SIM_MODE" in
        blank|twofablank) mkdir -p "$STATE/restore-receipts"; echo x > "$STATE/restore-receipts/roster.x"; return 1 ;;
        blanknet) mkdir -p "$STATE/restore-receipts"; echo x > "$STATE/restore-receipts/roster.x"; return 5 ;;
      esac
      return 0 ;;
    *) return 1 ;;
  esac
}
pw() { printf '%s\n' "$ROOT/sim/pw"; }
_ms() { echo 0; }
od_fetch_data() { return 0; }; od_listed() { return 1; }; od_block_app() { return 0; }; od_unblock_app() { :; }; od_pending_clear() { :; }; od_block_installed() { :; }; od_shipped_prep() { return 0; }; od_park_var() { :; }; od_unf_path() { echo "$STATE/odfetch.$1/unfetched.$2"; }   # NWP-20261130-03
_sum0=0; _sumt=0   # set above the `in` arm in the script (NWP-20261130-08); this harness runs the arm alone under set -u
sleep() { return 0; }
for t in usb_host relabel_launcher remap_media_db insert_deferred_media remap_per_pkg _tlog _ssum acct_restore remap_tree reown_ext_appdata \
         keystore_push keystore_restore ks_signin_reset hold_ondemand od_parked_report reap_stale_ondemand reap_orphan_provisioned restorecon \
         uiderrors_floor_take uiderrors_floor_commit tz_surface sroam_surface; do
  eval "$t() { :; }"
done
in_scope_tokens() { printf '+de +media'; }   # NWP-20261113-15: the IN line's scope tokens
# NWP-20261117-16: each call records whether the CE restore ran (sim/first) and whether the reply was written ($RES)
stop_mediad() {
  if [ -e "$ROOT/sim/first" ]; then _smr=restored; else _smr=unrestored; fi
  if [ -s "$RES" ]; then _smp=replied; else _smp=unreplied; fi
  printf '%s %s\n' "$_smr" "$_smp" >> "$ROOT/sim/stopmd"
}
if [ -n "$NOPARK" ]; then
  mkdir() { case "$*" in *in-park*) printf '%s\n' "mkdir: $*: No space left on device" >&2; return 1 ;; esac; command mkdir "$@"; }
fi
if [ -n "$KEEPPARK" ]; then
  rm() { case "$*" in *"$STATE/.in-park") return 1 ;; esac; command rm "$@"; }
fi
bt_reset() { BT_RESTORED=0; return 0; }
STUB
      printf '%s\n' "$QN"
      printf 'case "$op" in\n%s\nesac\n' "$RI"
    } > "$1"
  }
  # run_in <root> <ok|blank|blanknet|probe5|probe2|needkey|twofa|twofablank>: the REAL roam-in arm. ok =
  # passphrase-only profile, restore lands; blank = the CE restore FAILS (rc 1); blanknet = it fails rc 5; probe5 /
  # probe2 = fido2-is-enrolled itself exits 5 / 2; needkey = a 2FA profile signing in with no key
  # (NFC-first); twofa = a 2FA profile whose key is asserted fresh; twofablank = twofa, then the restore fails. A
  # failing restore first writes restore-receipts/roster.x, as writeLoginRoster does. The first `restore` records which of the two
  # restore-written entries it found already present (sim/first). NOPARK=1 makes every mkdir of the park fail, as
  # when the tmpfs is out of inodes (ENOSPC), not bytes (a mkdir there costs an inode and no data pages, so a $STATE
  # full by bytes still gets its park), or on a kernel ENOMEM; KEEPPARK=1 makes rm unable to remove the park itself
  # (a stale park rm cannot clear). Pass either as a prefix (`NOPARK=1 run_in ...`), so it ends with the call. The
  # runner is written into the case root and run by $SH, the shell this suite call runs under.
  run_in() {
    mkrunner "$1/sim/run.sh" "$1" "$2"
    runsh "$SH" "$1/sim/run.sh" "$1/sim/stderr"
    harness_check "$1"
    idcheck "$1"
  }
  mkroot() {  # mkroot [bare]: bare plants none of the per-login entries
    R=$(mktemp -d -p "$W")
    mkdir -p "$R/sim" "$R/state" "$R/data/nowhere" "$R/data/user/11"
    [ "${1:-}" != bare ] || return 0
    mkdir -p "$R/state/restore-receipts"
    echo r > "$R/state/restore-receipts/f"
    echo m > "$R/state/media.restore-ok"
    echo b > "$R/state/.btlogoff"
    echo h > "$R/state/.had_account"
    printf A > "$R/state/.fido2hmac"
    printf S > "$R/state/.fido2slots"
    printf P > "$R/state/.fido2slots.pre"
  }
  # the three reset-only entries plus the receipts dir and media marker: the "four" of the task, as paths
  four_gone() { absent "$1/restore-receipts" && absent "$1/media.restore-ok" && absent "$1/.btlogoff" && absent "$1/.had_account"; }
  # the six per-login entries, each holding what mkroot planted (receipts: exactly f, no roster.x, no nesting)
  six_held() {
    holds "$1/restore-receipts/f" r && holds "$1/media.restore-ok" m && holds "$1/.btlogoff" b &&
      holds "$1/.had_account" h && holds "$1/.fido2hmac" A && holds "$1/.fido2slots" S &&
      [ "$(ls -A "$1/restore-receipts")" = f ]
  }
  six_absent() {
    local e
    for e in restore-receipts media.restore-ok .btlogoff .had_account .fido2hmac .fido2slots; do [ ! -e "$1/$e" ] || return 1; done
  }
  nopark() { absent "$1/.in-park"; }
  # U/probe cases: nothing in $STATE moved, the planted .fido2hmac.pre is gone, the agent never restored
  untouched_six() { six_held "$1" && holds "$1/.fido2slots.pre" P; }
  # NP cases: the log lacks a line; restore-receipts holds exactly what the failed attempt wrote
  nolog() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
  only_roster() { [ "$(ls -A "$1/restore-receipts" 2>/dev/null)" = roster.x ]; }
  NPMSG="could not make the park -- per-login state deleted, not parked"

  # the runner must parse under $SH before any case runs it
  PF=$(mktemp -p "$W") || return 2
  mkrunner "$PF" "$W" ok
  if ! "$SH" -n "$PF" 2>/dev/null; then
    command rm -f "$PF"
    chk "THE ARM DOES NOT PARSE under $SH" false
    say "  -- [$SH] $p passed, $x failed"
    return 1
  fi
  command rm -f "$PF"

  say "== N1: a REFUSED (NEEDKEY) login changes nothing on the live session =="
  mkroot; S="$R/state"
  run_in "$R" needkey
  chk "N1 the reply is NEEDKEY" eqv "$(cat "$R/res" 2>/dev/null)" NEEDKEY
  chk "N1 restore-receipts/f untouched" holds "$S/restore-receipts/f" r
  chk "N1 media.restore-ok untouched" holds "$S/media.restore-ok" m
  chk "N1 .btlogoff untouched" holds "$S/.btlogoff" b
  chk "N1 .had_account untouched" holds "$S/.had_account" h
  chk "N1 .fido2hmac untouched (value A)" holds "$S/.fido2hmac" A
  chk "N1 .fido2slots untouched (value S)" holds "$S/.fido2slots" S
  chk "N1 .fido2slots.pre untouched (value P)" holds "$S/.fido2slots.pre" P
  chk "N1 the agent never restored" absent "$R/sim/first"
  chk "N1 the media daemon was never stopped" absent "$R/sim/stopmd"
  command rm -rf "$R"

  say ""
  say "== C1: a committing passphrase-only login resets the session's entries =="
  mkroot; S="$R/state"
  run_in "$R" ok
  chk "C1 the four per-login entries are gone" four_gone "$S"
  chk "C1 .fido2hmac is gone (cleared, not inherited)" absent "$S/.fido2hmac"
  chk "C1 .fido2slots is gone" absent "$S/.fido2slots"
  chk "C1 .fido2slots.pre is gone" absent "$S/.fido2slots.pre"
  chk "C1 the park still holds the session's six entries (the daemon's to drop)" six_held "$S/.in-park"
  chk "C1 ORDER: the first restore saw neither restore-receipts nor media.restore-ok" eqv "$(cat "$R/sim/first" 2>/dev/null)" none
  chk "C1 the media daemon was stopped once, after the CE restore and before the reply" holds "$R/sim/stopmd" "restored unreplied"
  command rm -rf "$R"

  say ""
  say "== C2: a committing 2FA login with a fresh assertion =="
  mkroot; S="$R/state"
  run_in "$R" twofa
  chk "C2 the four per-login entries are gone" four_gone "$S"
  chk "C2 .fido2hmac holds the fresh assertion" holds "$S/.fido2hmac" "$HEX"
  chk "C2 .fido2slots holds the promoted spec (P)" holds "$S/.fido2slots" P
  chk "C2 .fido2slots.pre was consumed by the promotion" absent "$S/.fido2slots.pre"
  chk "C2 the park still holds the session's six entries (the daemon's to drop)" six_held "$S/.in-park"
  chk "C2 ORDER: the first restore saw neither restore-receipts nor media.restore-ok" eqv "$(cat "$R/sim/first" 2>/dev/null)" none
  chk "C2 the media daemon was stopped once, after the CE restore and before the reply" holds "$R/sim/stopmd" "restored unreplied"
  command rm -rf "$R"

  say ""
  say "== C3: a login whose CE restore fails (BLANK) puts the per-login state back =="
  mkroot; S="$R/state"
  run_in "$R" blank
  chk "C3 the reply is BLANK" eqv "$(cat "$R/res" 2>/dev/null)" BLANK
  chk "C3 the six parked entries hold their planted values (receipts: exactly f)" six_held "$S"
  chk "C3 no park is left" nopark "$S"
  chk "C3 the put-back is logged with 6 entries" has_log "$R/roam.log" "did not land -- per-login state put back (6 entries)"
  chk "C3 .fido2slots.pre (attempt-scoped) was consumed as today" absent "$S/.fido2slots.pre"
  chk "C3 ORDER: the first restore saw neither restore-receipts nor media.restore-ok" eqv "$(cat "$R/sim/first" 2>/dev/null)" none
  chk "C3 the media daemon was never stopped" absent "$R/sim/stopmd"
  command rm -rf "$R"

  say ""
  say "== C4: the same with a restore that cannot reach the store (BLANK NET) =="
  mkroot; S="$R/state"
  run_in "$R" blanknet
  chk "C4 the reply is BLANK NET" eqv "$(cat "$R/res" 2>/dev/null)" "BLANK NET"
  chk "C4 the six parked entries hold their planted values (receipts: exactly f)" six_held "$S"
  chk "C4 no park is left" nopark "$S"
  chk "C4 .fido2slots.pre was consumed as today" absent "$S/.fido2slots.pre"
  chk "C4 the media daemon was never stopped" absent "$R/sim/stopmd"
  command rm -rf "$R"

  say ""
  say "== C5: a 2FA login asserted fresh whose restore then fails =="
  mkroot; S="$R/state"
  run_in "$R" twofablank
  chk "C5 the reply is BLANK" eqv "$(cat "$R/res" 2>/dev/null)" BLANK
  chk "C5 .fido2hmac holds A (not the fresh assertion)" holds "$S/.fido2hmac" A
  chk "C5 .fido2slots holds S (not the promoted P)" holds "$S/.fido2slots" S
  chk "C5 the six parked entries hold their planted values" six_held "$S"
  chk "C5 no park is left" nopark "$S"
  chk "C5 .fido2slots.pre was consumed" absent "$S/.fido2slots.pre"
  chk "C5 the media daemon was never stopped" absent "$R/sim/stopmd"
  command rm -rf "$R"

  say ""
  say "== C6: a failed restore on a root with none of the six leaves none of them =="
  mkroot bare; S="$R/state"
  run_in "$R" blank
  chk "C6 the reply is BLANK" eqv "$(cat "$R/res" 2>/dev/null)" BLANK
  chk "C6 none of the six exists" six_absent "$S"
  chk "C6 no park is left" nopark "$S"
  chk "C6 the put-back is logged with 0 entries" has_log "$R/roam.log" "did not land -- per-login state put back (0 entries)"
  command rm -rf "$R"

  say ""
  say "== C7: a park left by a killed run, which rm can clear, is discarded and this sign-in parks as on a clean root =="
  # The commit's rm is what clears it: without that rm the plain mkdir fails on it, and this sign-in and every later
  # one of the boot take the no-park delete (NP1-NP5) instead of parking.
  mkroot; S="$R/state"; mkdir -p "$S/.in-park/restore-receipts"; echo z > "$S/.in-park/restore-receipts/z"; printf Z > "$S/.in-park/.btlogoff"
  run_in "$R" blank
  chk "C7 the reply is BLANK" eqv "$(cat "$R/res" 2>/dev/null)" BLANK
  chk "C7 the six were parked and put back, holding their planted values (receipts: exactly f, none of the stale park)" six_held "$S"
  chk "C7 no park is left (the stale one discarded)" nopark "$S"
  chk "C7 the put-back is logged with 6 entries" has_log "$R/roam.log" "did not land -- per-login state put back (6 entries)"
  chk "C7 the no-park delete never ran" nolog "$R/roam.log" "$NPMSG"
  chk "C7 ORDER: the first restore saw neither restore-receipts nor media.restore-ok" eqv "$(cat "$R/sim/first" 2>/dev/null)" none
  command rm -rf "$R"

  say ""
  say "== U1: a key check that cannot reach the store refuses before the commit arm =="
  mkroot; S="$R/state"; printf N > "$S/.fido2hmac.pre"
  run_in "$R" probe5
  chk "U1 the reply is BLANK NET" eqv "$(cat "$R/res" 2>/dev/null)" "BLANK NET"
  chk "U1 the agent never restored" absent "$R/sim/first"
  chk "U1 every planted entry holds its value" untouched_six "$S"
  chk "U1 the planted .fido2hmac.pre is gone" absent "$S/.fido2hmac.pre"
  chk "U1 the media daemon was never stopped" absent "$R/sim/stopmd"
  chk "U1 no park is left" nopark "$S"
  command rm -rf "$R"

  say ""
  say "== U2: a key check that cannot read the store answers BLANK =="
  mkroot; S="$R/state"; printf N > "$S/.fido2hmac.pre"
  run_in "$R" probe2
  chk "U2 the reply is BLANK" eqv "$(cat "$R/res" 2>/dev/null)" BLANK
  chk "U2 the agent never restored" absent "$R/sim/first"
  chk "U2 every planted entry holds its value" untouched_six "$S"
  chk "U2 the planted .fido2hmac.pre is gone" absent "$S/.fido2hmac.pre"
  chk "U2 the media daemon was never stopped" absent "$R/sim/stopmd"
  chk "U2 no park is left" nopark "$S"
  command rm -rf "$R"

  say ""
  say "== N2: a refused (NEEDKEY) login leaves a stale park alone and restores nothing =="
  mkroot; S="$R/state"; mkdir -p "$S/.in-park"; printf Z > "$S/.in-park/.btlogoff"
  run_in "$R" needkey
  chk "N2 the reply is NEEDKEY" eqv "$(cat "$R/res" 2>/dev/null)" NEEDKEY
  chk "N2 the stale park is as it was" holds "$S/.in-park/.btlogoff" Z
  chk "N2 .btlogoff still holds the live value (nothing restored)" holds "$S/.btlogoff" b
  chk "N2 every planted entry holds its value" untouched_six "$S"
  command rm -rf "$R"

  say ""
  say "== NP1: a committing passphrase-only login that cannot make the park deletes the entries, as before =="
  mkroot; S="$R/state"
  NOPARK=1 run_in "$R" ok
  chk "NP1 the reply is OK 11" eqv "$(cat "$R/res" 2>/dev/null)" "OK 11"
  chk "NP1 the four per-login entries are gone" four_gone "$S"
  chk "NP1 .fido2hmac is gone (cleared, not inherited)" absent "$S/.fido2hmac"
  chk "NP1 .fido2slots is gone" absent "$S/.fido2slots"
  chk "NP1 .fido2slots.pre is gone" absent "$S/.fido2slots.pre"
  chk "NP1 no park path exists (restore-receipts was not renamed to it)" nopark "$S"
  chk "NP1 ORDER: the first restore saw neither restore-receipts nor media.restore-ok" eqv "$(cat "$R/sim/first" 2>/dev/null)" none
  chk "NP1 the missing park is logged" has_log "$R/roam.log" "$NPMSG"
  command rm -rf "$R"

  say ""
  say "== NP2: a committing 2FA login that cannot make the park keeps its fresh assertion and spec =="
  mkroot; S="$R/state"
  NOPARK=1 run_in "$R" twofa
  chk "NP2 the four per-login entries are gone" four_gone "$S"
  chk "NP2 .fido2hmac holds the fresh assertion" holds "$S/.fido2hmac" "$HEX"
  chk "NP2 .fido2slots holds the promoted spec (P)" holds "$S/.fido2slots" P
  chk "NP2 no park path exists" nopark "$S"
  command rm -rf "$R"

  say ""
  say "== NP3: a login that cannot make the park and whose restore fails is the pre-park delete, with no put-back =="
  mkroot; S="$R/state"
  NOPARK=1 run_in "$R" blank
  chk "NP3 the reply is BLANK" eqv "$(cat "$R/res" 2>/dev/null)" BLANK
  chk "NP3 media.restore-ok, .btlogoff, .had_account were deleted" eval 'absent "$S/media.restore-ok" && absent "$S/.btlogoff" && absent "$S/.had_account"'
  chk "NP3 .fido2hmac and .fido2slots were deleted" eval 'absent "$S/.fido2hmac" && absent "$S/.fido2slots"'
  chk "NP3 restore-receipts holds only the attempt's roster.x (the live f deleted, as before)" only_roster "$S"
  chk "NP3 no park path exists" nopark "$S"
  chk "NP3 no put-back is logged" nolog "$R/roam.log" "did not land"
  chk "NP3 the missing park is logged" has_log "$R/roam.log" "$NPMSG"
  command rm -rf "$R"

  say ""
  say "== NP4: a stale park rm cannot clear is never reused, and its entries are never put back =="
  mkroot; S="$R/state"; mkdir -p "$S/.in-park/restore-receipts"; echo z > "$S/.in-park/restore-receipts/z"; printf Z > "$S/.in-park/.btlogoff"
  KEEPPARK=1 run_in "$R" blank
  chk "NP4 the reply is BLANK" eqv "$(cat "$R/res" 2>/dev/null)" BLANK
  chk "NP4 the stale receipts were not put back" absent "$S/restore-receipts/z"
  chk "NP4 restore-receipts holds only the attempt's roster.x" only_roster "$S"
  chk "NP4 .btlogoff holds neither the live b nor the stale Z" absent "$S/.btlogoff"
  chk "NP4 ORDER: the first restore saw neither restore-receipts nor media.restore-ok" eqv "$(cat "$R/sim/first" 2>/dev/null)" none
  chk "NP4 no put-back is logged" nolog "$R/roam.log" "did not land"
  chk "NP4 the missing park is logged" has_log "$R/roam.log" "$NPMSG"
  command rm -rf "$R"

  say ""
  say "== NP5: with no restore-receipts to move, no file is still in \$STATE when the first restore runs =="
  # Nothing here can be renamed to the park path, so a move into a missing park fails for every name and leaves it.
  mkroot; S="$R/state"; command rm -rf "$S/restore-receipts"
  NOPARK=1 run_in "$R" ok
  chk "NP5 the reply is OK 11" eqv "$(cat "$R/res" 2>/dev/null)" "OK 11"
  chk "NP5 ORDER: the first restore saw no media.restore-ok" eqv "$(cat "$R/sim/first" 2>/dev/null)" none
  chk "NP5 media.restore-ok, .btlogoff, .had_account were deleted" eval 'absent "$S/media.restore-ok" && absent "$S/.btlogoff" && absent "$S/.had_account"'
  chk "NP5 .fido2hmac and .fido2slots were deleted" eval 'absent "$S/.fido2hmac" && absent "$S/.fido2slots"'
  chk "NP5 no park path exists" nopark "$S"
  chk "NP5 the missing park is logged" has_log "$R/roam.log" "$NPMSG"
  command rm -rf "$R"

  say ""
  chk "the harness ran clean (no undefined function, unbound variable or parse error)" eqv "$HARN" ""
  if [ "$NOID" = 1 ]; then echo "HARNESS ERROR: a runner left no identity: $SH did not launch it" >&2; return 2; fi
  # a runner that launched and then hit an undefined name or a parse error is a HARNESS error too, ahead of any
  # case's FAIL: what it ran is not the arm the cases describe, so its FAIL lines can convict no mutant
  if [ -n "$HARN" ]; then echo "HARNESS ERROR: a runner under $SH failed at run time, in $HARNN case(s); the first: $HARN1" >&2; return 2; fi
  chk "identity: every case ran under $SH" eqv "$WRONGSH" 0
  say ""
  say "  -- [$SH] $p passed, $x failed"
  [ "$x" = 0 ]
}

echo "the in arm's park and resets: $SUT"
echo "shells:$SHELLS"
echo "sh identity: $REF_SH"
rc=0
for s in $SHELLS; do
  suite "$SUT" "$s"; r=$?
  if [ "$r" = 2 ]; then rc=2; elif [ "$r" != 0 ] && [ "$rc" = 0 ]; then rc=1; fi
done
if [ "$MUTATE" = no ]; then exit "$rc"; fi
[ "$rc" = 0 ] || exit "$rc"

# --- mutants ------------------------------------------------------------------------------------------------
# Each is a transform of roamd's text, by exact line; a mutant that changes nothing is a failure of the suite.
L_PK='    PARK="$STATE/.in-park"; _parked=0'
L_RR='      [ -e "$STATE/restore-receipts" ] && mv "$STATE/restore-receipts" "$PARK/" 2>> "$LOG"'
L_RF='      for _pn in media.restore-ok .btlogoff .had_account; do [ -e "$STATE/$_pn" ] && mv "$STATE/$_pn" "$PARK/" 2>> "$LOG"; done'
L_SL='    [ -e "$STATE/.fido2slots" ] && mv "$STATE/.fido2slots" "$PARK/" 2>> "$LOG"'
L_IF='    if [ -z "$_probe" ] && { [ "$fido2_needed" = 0 ] || [ -n "$fresh_hmac" ]; }; then'
L_CE='    elif od_shipped_prep && NOWHERE_PARK_KEEP="$(od_park_var keep)" NOWHERE_PARK_SHIPPED="$(od_park_var shipped)" NOWHERE_UNFETCHED_LIST="$(od_park_var ce)" NOWHERE_PHASE=apps NOWHERE_CLAIMS_SEED="$STATE/claims.seed" "$AGENT" restore s3 "$name" "$(pw "$pass")" "$USERDIR" >> "$LOG" 2>&1; then'
L_PC='    case $? in'
L_HM='      [ -e "$STATE/.fido2hmac" ] && mv "$STATE/.fido2hmac" "$PARK/" 2>> "$LOG"'
# The line the OK arm no longer holds (NWP-20261129-17). Its anchor is L_OR; the mutant below puts it back there.
L_OK='      [ "$_parked" = 1 ] && rm -rf "$PARK" 2>> "$LOG"'
L_PF='    if [ "$_parked" = 1 ] && [ "$_inres" != OK ]; then'
L_PB='        rm -rf "$STATE/$_pn" 2>> "$LOG"'
L_PM='        if [ -e "$PARK/$_pn" ]; then mv "$PARK/$_pn" "$STATE/$_pn" 2>> "$LOG"; _pbn=$((_pbn + 1)); fi'
L_MK='      if mkdir "$PARK" 2>> "$LOG"; then'
L_P1='        _parked=1'
L_DL='        for _pn in restore-receipts media.restore-ok .btlogoff .had_account .fido2hmac .fido2slots; do rm -rf "$STATE/$_pn" 2>> "$LOG"; done'
# The commit's rm of a stale park. The put-back ends with a byte-identical line, so this one is never anchored alone:
# it is the line just before L_MK, and that pair must occur exactly once.
L_RP='      rm -rf "$PARK" 2>> "$LOG"'
L_FN='    fido2_needed=0; _probe=""'
# NWP-20261117-16: the media daemon stop, the line just before L_AP (checked below), and its neighbours. Since
# NWP-20261124-05 the stop heads the landing branch, so L_AP is that branch's next line (the app-list comment).
L_HU='    export NOWHERE_HEAL_UNTIL=$(( $(date +%s) + 2400 ))'
L_SM='      stop_mediad   # NWP-20261117-16: a predecessor'"'"'s media daemon goes only once this sign-in has landed'
L_AP='      # App provisioning: surface the roamed launchable-app list (the chooser sealed it into its own files'
L_OR='      echo "OK $uid" > "$RES"; _inres=OK'
for l in "$L_PK" "$L_RR" "$L_RF" "$L_SL" "$L_IF" "$L_CE" "$L_PC" "$L_HM" "$L_PF" "$L_PB" "$L_PM" "$L_MK" "$L_P1" "$L_DL" "$L_FN" "$L_HU" "$L_SM" "$L_AP" "$L_OR" '  in)'; do
  [ "$(grep -cxF -- "$l" "$SUT")" = 1 ] || { echo "EXTRACTION FAILED: anchor line not unique in $SUT: $l" >&2; exit 2; }
done
[ "$(grep -cxF -- "$L_OK" "$SUT")" = 0 ] || { echo "EXTRACTION FAILED: the OK arm's park removal is back in $SUT" >&2; exit 2; }
[ "$(awk -v RP="$L_RP" -v MK="$L_MK" 'p == RP && $0 == MK {c++} {p = $0} END {print c + 0}' "$SUT")" = 1 ] ||
  { echo "EXTRACTION FAILED: the line before the park's mkdir is not, exactly once, the rm: $L_RP" >&2; exit 2; }
[ "$(awk -v SM="$L_SM" -v AP="$L_AP" 'p == SM && $0 == AP {c++} {p = $0} END {print c + 0}' "$SUT")" = 1 ] ||
  { echo "EXTRACTION FAILED: the media daemon stop is not, exactly once, the line before: $L_AP" >&2; exit 2; }
# mut <name> <awk-program>: awk gets the anchors as variables. Convicted only by a failing line under EACH shell
# found; a harness error (rc 2) under any shell is a failure, never a conviction.
mut() {
  local name="$1" prog="$2" t s r
  t=$(mktemp -p "$W")
  awk -v PK="$L_PK" -v RR="$L_RR" -v RF="$L_RF" -v SL="$L_SL" -v IF="$L_IF" -v CE="$L_CE" -v PC="$L_PC" -v HM="$L_HM" \
      -v OK="$L_OK" -v PF="$L_PF" -v PB="$L_PB" -v PM="$L_PM" -v MK="$L_MK" -v P1="$L_P1" -v DL="$L_DL" -v RP="$L_RP" \
      -v FN="$L_FN" -v HU="$L_HU" -v SM="$L_SM" -v AP="$L_AP" -v OR="$L_OR" "$prog" "$SUT" > "$t"
  if cmp -s "$t" "$SUT"; then echo "  FAIL  mutant did not apply: $name"; MFAIL=1; command rm -f "$t"; return; fi
  for s in $SHELLS; do
    suite "$t" "$s" quiet >/dev/null 2>&1; r=$?
    if [ "$r" = 1 ]; then echo "  ok    CONVICTED [$s]: $name"
    else echo "  FAIL  NOT CONVICTED [$s] (rc=$r): $name"; MFAIL=1; fi
  done
  command rm -f "$t"
}
MFAIL=0
echo "== mutants (each must CONVICT under every shell found) =="
mut "both resets moved to the top of in) (before the park exists)" \
  '$0==RR||$0==RF{next} {print} $0==PK{print RR; print RF}'
mut ".btlogoff dropped from the park" \
  '$0==RF{sub(/ \.btlogoff/,"")} {print}'
mut ".had_account dropped from the park" \
  '$0==RF{sub(/ \.had_account/,"")} {print}'
mut "media.restore-ok dropped from the park" \
  '$0==RF{sub(/ media\.restore-ok/,"")} {print}'
mut "the restore-receipts reset moved below the CE restore" \
  '$0==RR{next} {print} $0==CE{print RR}'
mut ".fido2slots removal moved above the commit if" \
  '$0==SL{next} $0==IF{print SL} {print}'
mut "the key check collapsed back to && fido2_needed=1 (5 and 2 read as not enrolled)" \
  '$0==PC{print "    case $(( $? == 0 ? 0 : 1 )) in"; next} {print}'
mut "the put-back is removed" \
  '$0==PM{next} {print}'
mut "the OK arm removes the park again" \
  '{print} $0==OR{print OK}'
mut "the park flag is ignored, so any park is restored" \
  '$0==PF{print "    if [ \"$_inres\" != OK ]; then"; next} {print}'
mut ".fido2hmac is left out of the park" \
  '$0==HM{print "      rm -f \"$STATE/.fido2hmac\""; next} {print}'
mut "the put-back moves parked entries back without first removing what the attempt left" \
  '$0==PB{next} {print}'
mut "the put-back touches only names the park holds" \
  '$0==PB{print "        [ -e \"$PARK/$_pn\" ] && rm -rf \"$STATE/$_pn\" 2>> \"$LOG\""; next} {print}'
mut "the park is made with mkdir -p, so a stale park rm could not clear is reused" \
  '$0==MK{sub(/mkdir "/,"mkdir -p \"")} {print}'
mut "the mkdir result is ignored (the park flag set whether or not the park exists)" \
  '$0==MK{print "      mkdir -p \"$PARK\" 2>> \"$LOG\"; if true; then"; next} {print}'
mut "the no-park delete is dropped" \
  '$0==DL{next} {print}'
mut "the park flag is set when the mkdir fails too" \
  '{print} $0==DL{print P1}'
mut "the no-park delete runs after the moves instead of before them" \
  '$0==DL{next} {print} $0==SL{d=DL; sub(/^ +/,"",d); print "    [ \"$_parked\" = 1 ] || " d}'
mut "the commit no longer discards a park a killed run left (its rm, the line before the mkdir, dropped)" \
  'h{if($0!=MK)print RP; h=0} $0==RP{h=1; next} {print} END{if(h)print RP}'
# mksh reads a non-number in `[ x -eq 0 ]` as 0, silently: the commit test must still not take x for 0
mut "the probe default is a non-number (fido2_needed=x), so the commit test never reads it as 0" \
  '$0==FN{sub(/fido2_needed=0/,"fido2_needed=x")} {print}'
mut "S1 the stop back at the top of in) (before the probe, the commit arm and every refusal)" \
  '$0==SM{next} {print} $0==HU{print "    stop_mediad"}'
mut "S2 the landed sign-in's stop is deleted" \
  '$0==SM{next} {print}'
mut "S3 the stop moved after the OK reply" \
  '$0==SM{next} {print} $0==OR{print SM}'
mut "S4 the stop moved into the commit arm (a failed CE restore still stops it)" \
  '$0==SM{next} {print} $0==IF{print SM}'

# --- harness probes: transforms of THIS suite ------------------------------------------------------------------
mtmp=$(mktemp -d -p "$W") || exit 2
# probe <label> <sed program> <message>: a runner that never launches, or launches and then hits an undefined
# helper, must end the suite with exit 2 and that HARNESS ERROR -- not exit 1 with FAIL lines, which a mutation run
# would count as a conviction
probe() {
  local cp="$mtmp/suite-probe.sh" rc
  sed "$2" "$0" > "$cp"
  if cmp -s "$0" "$cp"; then echo "  FAIL  probe did not apply: $1"; MFAIL=1; return; fi
  bash "$cp" "$SUT" > "$mtmp/probe.out" 2>&1; rc=$?
  if [ "$rc" = 2 ] && grep -qF "HARNESS ERROR: $3" "$mtmp/probe.out"; then echo "  ok    harness error, not a conviction: $1"
  else echo "  FAIL  HARNESS ERROR NOT RAISED (rc=$rc): $1"; MFAIL=1; fi
}
# mutate_runner: the runner ignores its shell argument and always runs bash; the identity check must convict it
# under every non-bash shell found (sh too, unless sh IS bash here)
mutate_runner() {
  local s bad="" want="" cp="$mtmp/suite-runner.sh" lbl="the runner always runs bash"
  sed 's/^runsh(){ "\$1" "\$2"/runsh(){ bash "$2"/' "$0" > "$cp"
  if cmp -s "$0" "$cp"; then echo "  FAIL  probe did not apply: $lbl"; MFAIL=1; return; fi
  for s in $SHELLS; do
    case "$s" in
      bash) ;;
      sh) case "$REF_SH" in bash:*) ;; *) want="$want $s" ;; esac ;;
      *) want="$want $s" ;;
    esac
  done
  [ -n "$want" ] || { echo "  n/a   $lbl: no non-bash shell on this host (CI has dash and mksh)"; return; }
  bash "$cp" "$SUT" > "$mtmp/runner.out" 2>&1
  for s in $want; do grep -q "FAIL  \[$s\]" "$mtmp/runner.out" || bad="$bad $s"; done
  if [ -z "$bad" ]; then echo "  ok    CONVICTED under:$want: $lbl"
  else echo "  FAIL  SURVIVED under:$bad: $lbl"; MFAIL=1; fi
}
probe 'the runner never launches' 's/^runsh(){ .*$/runsh(){ return 127; }/' 'a runner left no identity'
# the runner records its identity, then calls a helper no stub defines, ahead of the arm
probe 'the runner launches, then calls an undefined helper' \
  "s/^      printf 'set -u\\\\n'\$/      printf 'set -u; harness_probe_undefined\\\\n'/" 'a runner under'
mutate_runner
[ "$MFAIL" = 0 ] || exit 1
echo "all mutants convicted"
