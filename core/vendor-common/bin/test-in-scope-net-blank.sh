#!/usr/bin/env bash
# test-in-scope-net-blank.sh [<nowhere_roamd.sh>] [--mutate] -- a sign-in whose #de, #media or #apps restore cannot
# reach the store (exit 5) does not land: it ends as BLANK NET before every landing step (NWP-20261124-05; backlog §A
# ⚠ A TRANSIENT DIAL FAILURE OFFERS THE USER A DESTRUCTIVE ROLLBACK; NWP-20261201-16 for #apps, backlog §B 'A sign-in
# whose `#apps` restore cannot reach the store lands with no kept app installed').
#
# WHY THIS IS COMMITTED. The `in)` arm ran the #de and #media restores best-effort after the vault landed, and
# answered `OK <uid>` whatever their status. On lynx 2026102201 Wi-Fi was cut during the #media chunk download:
# roam.log read `ERR: fetch chunk 80 ... network is unreachable` and then `IN "<profile>" -> user 18 (+de +media)`.
# A session landed with its #media missing, and a later seal can publish over the stored copy. Decided 2026-11-02
# (docs/product-decisions.md, "twenty-four answers to the open-decisions list ...", #4, option A): such a sign-in
# stops as BLANK NET, which the daemon (handleRoamIn) and the gate already render as "Couldn't reach your storage"
# with a retry only. The media daemon stop (NWP-20261117-16) belongs to a landed sign-in alone, so it now follows
# that verdict. The #apps restore follows the same rule ("twenty answers to harvest 60 ...", 2026-11-06, #5), so it
# runs before the verdict too. This suite runs the REAL extracted arm, with the REAL qn and in_scope_tokens, under every shell found
# among bash, sh, dash and mksh (the device's /system/bin/sh). The agent is stubbed per store ref and every helper
# the arm calls is a recording stub:
#   A  vault 0, #de 5           -> BLANK NET naming de; no #sys, no stop, no landing step; park put back
#   B  vault 0, #de 0, #media 5 -> BLANK NET naming media; no stop, no landing step, no claims seed, no account hold
#   C  #media 1 (damage)        -> lands as today: OK 11, `+de !media(rc=1)`, one stop, before the reply
#   D  all three 0              -> OK 11, `+de +media`, one stop; the #apps set stays for the gate
#   E  no per-user dirs (skip)  -> OK 11, `-de -media`, one stop
#   F  vault, #de, #media 0, #apps 5 -> BLANK NET naming apps; the #apps restore ran once; no stop, no landing
#                                  step, no .appcode left
#   G  #apps 1 (damage)         -> lands as today: OK 11, `+de +media`, one stop, no .appcode left
#
# NWP-20261207-06 (docs/product-decisions.md, "eight answers to harvest 62 ...", 2026-11-09, #6): the #sys restore
# (acct_restore) and the #keys restore follow the same rule. The #keys store request moved out of the landing into
# keystore_fetch, which runs before the verdict and stages into keystore-in/<uid>.pre; keystore_restore promotes it at
# the landing. Here acct_restore and keystore_fetch are stubs that return the case's status; ks_in_dir is the REAL one:
#   H  #sys 5                   -> BLANK NET naming sys; no landing step
#   I  #keys 5                  -> BLANK NET naming keys; keystore_fetch ran once; no keystore_restore, no .pre
#   J  #keys 1 (damage)         -> lands: OK 11, `+de +media`; keystore_fetch before the media stop, keystore_restore
#                                  after ks_signin_reset
#   K  #sys 1 (damage)          -> lands: OK 11, `+de +media`
#
# NWP-20261210-03: once the vault restore lands, the #media, #apps code and #keys restores run as background lanes beside
# the #de and #sys restores, and the arm joins them before the verdict. So a #de, #sys or #media exit 5 no longer stops
# the later scopes: A, B, F, H and I now check that every lane ran, and the verdict still names the FIRST scope with exit 5
# in the decided order de, sys, media, apps, keys. Every BLANK NET case also leaves no .appcode and no lane dir.
# test-in-scope-lanes.sh runs the lanes' order, download share and progress relay.
#
#   bash test-in-scope-net-blank.sh              # the cases
#   bash test-in-scope-net-blank.sh --mutate     # ... plus mutants of roamd that must each CONVICT under every shell
#
# Pure logic -- no device. The arm is EXTRACTED by anchor, never copied, and re-rooted to a temp tree. Each case
# writes a runner file in its root and runs it in a CHILD of the shell under test; the runner records that shell's
# identity, and a runner that recorded none, or hit an undefined name or a parse error, is a HARNESS error.
# Exit 0 all pass, 1 a check failed, 2 the harness could not extract or run (never a pass).
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT   # every case root and mutant copy is made inside it

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

fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
APPCODE_REL=data/user/0/com.nowhere.chooser/files/.appcode
reroot() { printf '%s\n' "$1" | sed -E 's#([" ])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> <shell> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" SH="$2" quiet="${3:-}" p=0 x=0 QN IST KID IN RI R S n PF NOID=0 WRONGSH=0 HARN="" HARNN=0 HARN1=""
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    [$SH] $l"; else x=$((x+1)); say "  FAIL  [$SH] $l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  absent() { [ ! -e "$1" ]; }
  holds() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }
  # has_log / nolog <file> <fixed text>: the text is (not) in the file. Read into a variable, never `| grep -q`.
  has_log() { local c; c=$(cat "$1" 2>/dev/null); case "$c" in *"$2"*) return 0 ;; esac; return 1; }
  nolog() { ! has_log "$1" "$2"; }
  # ncalls <root> <exact line>: how many times sim/calls holds that line
  ncalls() { local c; c=$(grep -cxF -- "$2" "$1/sim/calls" 2>/dev/null); printf '%s' "${c:-0}"; }
  called() { [ "$(ncalls "$1" "$2")" != 0 ]; }
  ncalled() { [ "$(ncalls "$1" "$2")" = 0 ]; }

  QN=$(fn_of "$f" qn)
  IST=$(fn_of "$f" in_scope_tokens)
  KID=$(fn_of "$f" ks_in_dir)   # NWP-20261207-06: the verdict's keystore-in/<uid>.pre removal reads it
  IN=$(arm_of "$f" in)
  [ -n "$QN" ] || { echo "EXTRACTION FAILED: function qn not found in $f" >&2; return 2; }
  [ -n "$IST" ] || { echo "EXTRACTION FAILED: function in_scope_tokens not found in $f" >&2; return 2; }
  [ -n "$KID" ] || { echo "EXTRACTION FAILED: function ks_in_dir not found in $f" >&2; return 2; }
  case "$IN" in *'echo "NEEDKEY" > "$RES"'*'"${name}#media"'*'"${name}#de"'*'echo "OK $uid" > "$RES"'*'headblobs'*) ;;
    *) echo "EXTRACTION FAILED: the in arm in $f" >&2; return 2 ;; esac
  RI=$(reroot "$IN")
  n=$(printf '%s\n' "$RI" | grep -o '\$ROOT/data/' | grep -c .)
  [ "$n" -ge 5 ] || { echo "RE-ROOT FAILED: the in arm has $n rewritten paths, want >= 5" >&2; return 2; }
  n=$(nleft "$RI")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: the in arm keeps $n absolute /data path(s) in live code" >&2; return 2; }

  # every shell's wording: bash `command not found` / `unbound variable`, dash `not found` / `parameter not set`,
  # mksh `inaccessible or not found` / `parameter not set`
  harness_check() {
    local e
    e=$(grep -m1 -E 'not found|unbound variable|parameter not set|syntax error|Syntax error|bad substitution|Bad substitution' "$1/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || { HARN="$HARN [$e]"; HARNN=$((HARNN+1)); [ -n "$HARN1" ] || HARN1="$e"; }
  }
  idcheck() {
    if [ ! -s "$1/sim/shell.id" ]; then NOID=1
    elif ! idok "$SH" "$1/sim/shell.id"; then WRONGSH=1; fi
  }
  # mkrunner <file> <root> <#de rc> <#media rc> <#apps rc> <#sys rc> <#keys rc>: identity probe, print shim, the case's
  # values, the stubs, qn, in_scope_tokens, ks_in_dir and the REAL arm. POSIX only: it runs under every shell found.
  mkrunner() {
    {
      printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$2/sim/shell.id")"
      printf '%s\n' "$PRINT_SHIM"
      printf 'set -u\n'
      printf 'ROOT=%s; uid=11; op=in; name=prof; pass=pw; keymode=""; srcunit=""; sesec=""; DE_RC=%s; MD_RC=%s; APPS_RC=%s; SYS_RC=%s; KEYS_RC=%s\n' \
        "$(sq "$2")" "$(sq "$3")" "$(sq "$4")" "$(sq "$5")" "$(sq "$6")" "$(sq "$7")"
      cat <<'STUB'
LOG="$ROOT/roam.log"; RES="$ROOT/res"; STATE="$ROOT/state"; USERDIR="$ROOT/data/user/$uid"; AGENT=agent_sim
KS_IN="$ROOT/data/nowhere/keystore-in"
rec() { printf '%s\n' "$*" >> "$ROOT/sim/calls"; }
# the agent, by store ref ($3): the vault stages a claim seed, as NOWHERE_CLAIMS_SEED makes the real one do; #apps
# writes a tree with its manifest whatever its status, so only the status can tell a failed restore
agent_sim() {
  case "$1" in
    fido2-is-enrolled) return 1 ;;
    restore)
      rec "agent restore $3"
      case "$3" in
        prof) : > "$ROOT/sim/first"; printf 'org.example.held\n' > "$STATE/claims.seed"; return 0 ;;
        'prof#de') return "$DE_RC" ;;
        'prof#media') return "$MD_RC" ;;
        'prof#apps') mkdir -p "$5/x.app"; : > "$5/x.app/base.apk"; : > "$5/manifest.tsv"; return "$APPS_RC" ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}
pw() { printf '%s\n' "$ROOT/sim/pw"; }
pwv() { [ -z "$1" ] || pw "$1"; }
_ms() { echo 0; }
od_fetch_data() { return 0; }; od_listed() { return 1; }; od_block_app() { return 0; }; od_unblock_app() { :; }; od_pending_clear() { :; }; od_block_installed() { :; }; od_shipped_prep() { return 0; }; od_park_var() { :; }; od_unf_path() { echo "$STATE/odfetch.$1/unfetched.$2"; }   # NWP-20261130-03
_sum0=0; _sumt=0   # set above the `in` arm in the script (NWP-20261130-08); this harness runs the arm alone under set -u
_se_v=""; _fh_v=""   # set at the top level in the script (NWP-20261205-18); the same reason
sleep() { return 0; }
for t in usb_host rescan_media remap_per_pkg _tlog _ssum remap_tree reown_ext_appdata keystore_push restorecon uiderrors_floor_take; do
  eval "$t() { :; }"
done
for t in relabel_launcher restore_media_tail ks_signin_reset keystore_restore tz_surface sroam_surface hold_ondemand \
         od_parked_report reap_stale_ondemand reap_orphan_provisioned uiderrors_floor_commit; do
  eval "$t() { rec $t; }"
done
# acct_restore stages the profile's account rows in acct-hold-<uid>, as the real one does, and returns the case's #sys
# status; on 5 it stages no hold, as the real one removes it (NWP-20261207-06)
acct_restore() {
  rec acct_restore
  [ "$SYS_RC" = 5 ] && return 5
  mkdir -p "$ROOT/data/nowhere/acct-hold-$1"; echo rows > "$ROOT/data/nowhere/acct-hold-$1/accounts_ce.db"
  return "$SYS_RC"
}
# keystore_fetch stages a bundle in keystore-in/11.pre and returns the case's #keys status. It leaves the dir on 5 too,
# so only the verdict's removal can clear it (NWP-20261207-06)
keystore_fetch() {
  rec keystore_fetch
  mkdir -p "$ROOT/data/nowhere/keystore-in/11.pre"; : > "$ROOT/data/nowhere/keystore-in/11.pre/x.keys"
  return "$KEYS_RC"
}
bt_reset() { rec bt_reset; BT_RESTORED=0; return 0; }
# each stop records whether the CE restore ran (sim/first) and whether the reply was written ($RES)
stop_mediad() {
  if [ -e "$ROOT/sim/first" ]; then _smr=restored; else _smr=unrestored; fi
  if [ -s "$RES" ]; then _smp=replied; else _smp=unreplied; fi
  rec "stop_mediad $_smr $_smp"
}
STUB
      printf '%s\n' "$QN"
      printf '%s\n' "$IST"
      printf '%s\n' "$KID"
      printf 'case "$op" in\n%s\nesac\n' "$RI"
    } > "$1"
  }
  # mkroot <dirs 0|1>: the case root; the six per-login entries of a live session planted in $STATE, the user's
  # chooser files dir, user 0's chooser files dir (the #apps target), an SSAID seed SEED-SSAID staged, and (dirs=1)
  # the per-user DE and media dirs
  mkroot() {
    R=$(mktemp -d -p "$W"); S="$R/state"
    mkdir -p "$R/sim" "$S/restore-receipts" "$R/data/nowhere" "$R/data/user/11/com.nowhere.chooser/files" \
      "$R/data/user/0/com.nowhere.chooser/files" "$R/data/system/users/11"
    : > "$R/sim/calls"
    echo r > "$S/restore-receipts/f"; echo m > "$S/media.restore-ok"; echo b > "$S/.btlogoff"
    echo h > "$S/.had_account"; printf A > "$S/.fido2hmac"; printf X > "$S/.fido2slots"
    echo seed > "$R/data/system/users/11/nowhere-ssaid-seed"
    [ "$1" = 1 ] && mkdir -p "$R/data/user_de/11" "$R/data/media/11"
    return 0
  }
  run_in() {  # run_in <#de rc> <#media rc> [<#apps rc> [<#sys rc> [<#keys rc>]]], each default 0
    mkrunner "$R/sim/run.sh" "$R" "$1" "$2" "${3:-0}" "${4:-0}" "${5:-0}"
    "$SH" "$R/sim/run.sh" >/dev/null 2>>"$R/sim/stderr"
    harness_check "$R"
    idcheck "$R"
  }
  # the live session's entries are back as planted (the park put-back ran)
  put_back() {
    holds "$1/restore-receipts/f" r && holds "$1/media.restore-ok" m && holds "$1/.btlogoff" b &&
      holds "$1/.had_account" h && [ "$(ls -A "$1/restore-receipts")" = f ] && [ ! -e "$1/.in-park" ]
  }
  # blank_common <case>: what every BLANK NET case shares
  blank_common() {
    chk "$1 the reply is exactly BLANK NET" holds "$R/res" "BLANK NET"
    chk "$1 the media daemon was never stopped" eqv "$(grep -c '^stop_mediad' "$R/sim/calls")" 0
    chk "$1 no ks_signin_reset" ncalled "$R" ks_signin_reset
    chk "$1 no bt_reset" ncalled "$R" bt_reset
    chk "$1 no keystore_restore, no hold_ondemand" eval 'ncalled "$R" keystore_restore && ncalled "$R" hold_ondemand'
    chk "$1 no uiderrors_floor_commit" ncalled "$R" uiderrors_floor_commit
    chk "$1 no landed IN line" nolog "$R/roam.log" '-> user 11'
    chk "$1 no apps.out surfaced" absent "$S/apps.out"
    chk "$1 the claim seed is gone and never installed" eval 'absent "$S/claims.seed" && absent "$R/data/user/11/com.nowhere.chooser/files/nowhere-claims"'
    chk "$1 the claim seed install never ran" nolog "$R/roam.log" 'claims seed:'
    chk "$1 the live session's per-login state is put back" put_back "$S"
    chk "$1 the put-back is logged" has_log "$R/roam.log" 'did not land -- per-login state put back (6 entries)'
    chk "$1 the SSAID seed is removed" absent "$R/data/system/users/11/nowhere-ssaid-seed"
    chk "$1 no account hold is left" absent "$R/data/nowhere/acct-hold-11"
    chk "$1 no keystore-in/11.pre left" absent "$R/data/nowhere/keystore-in/11.pre"
    chk "$1 no .appcode left" absent "$R/$APPCODE_REL"
    chk "$1 no lane dir left (NWP-20261210-03)" eval '[ -z "$(ls -A "$S" | grep "^in-lanes")" ]'
  }
  # lanes_ran <case>: the #media, #apps and #keys lanes each ran once, whatever the foreground did (NWP-20261210-03)
  lanes_ran() {
    chk "$1 the #media, #apps and #keys lanes each ran once" eval '[ "$(ncalls "$R" "agent restore prof#media")" = 1 ] && [ "$(ncalls "$R" "agent restore prof#apps")" = 1 ] && [ "$(ncalls "$R" keystore_fetch)" = 1 ]'
  }
  # landed_common <case> <scope tokens>: what every landed case shares
  landed_common() {
    chk "$1 the reply is OK 11" holds "$R/res" "OK 11"
    chk "$1 the IN line names ($2)" has_log "$R/roam.log" "IN \"prof\" -> user 11 ($2)"
    chk "$1 no BLANK NET line" nolog "$R/roam.log" 'BLANK NET'
    chk "$1 exactly one media daemon stop, after the CE restore and before the reply" \
      eqv "$(grep '^stop_mediad' "$R/sim/calls")" "stop_mediad restored unreplied"
    chk "$1 the landing ran (ks_signin_reset, bt_reset, uiderrors_floor_commit)" \
      eval 'called "$R" ks_signin_reset && called "$R" bt_reset && called "$R" uiderrors_floor_commit'
    chk "$1 the claim seed is installed" holds "$R/data/user/11/com.nowhere.chooser/files/nowhere-claims" org.example.held
    chk "$1 no put-back (the sign-in landed)" nolog "$R/roam.log" 'did not land'
    chk "$1 the SSAID seed stays for the framework" holds "$R/data/system/users/11/nowhere-ssaid-seed" seed
  }

  # the runner must parse under $SH before any case runs it
  PF=$(mktemp -p "$W") || return 2
  mkrunner "$PF" "$W" 0 0 0 0 0
  if ! "$SH" -n "$PF" 2>/dev/null; then
    command rm -f "$PF"
    chk "THE ARM DOES NOT PARSE under $SH" false
    say "  -- [$SH] $p passed, $x failed"
    return 1
  fi
  command rm -f "$PF"

  say "== A: vault 0, #de 5 -> BLANK NET (de); the foreground skips #sys, the lanes are joined =="
  mkroot 1; run_in 5 0
  blank_common A
  chk "A the BLANK NET line names de" has_log "$R/roam.log" 'IN "prof" BLANK NET (the de restore could not reach the store)'
  chk "A the #de restore ran" called "$R" "agent restore prof#de"
  chk "A no acct_restore (no #sys fetch)" ncalled "$R" acct_restore
  lanes_ran A
  command rm -rf "$R"

  say ""
  say "== B: vault 0, #de 0, #media 5 -> BLANK NET (media) before every landing step =="
  mkroot 1; run_in 0 5
  blank_common B
  chk "B the BLANK NET line names media" has_log "$R/roam.log" 'IN "prof" BLANK NET (the media restore could not reach the store)'
  chk "B acct_restore and the #media restore ran" eval 'called "$R" acct_restore && called "$R" "agent restore prof#media"'
  chk "B no restore_media_tail (the tail runs on 0 only)" ncalled "$R" restore_media_tail
  lanes_ran B
  command rm -rf "$R"

  say ""
  say "== C: #media 1 (damage, a missing chunk) still lands and is named =="
  mkroot 1; run_in 0 1
  landed_common C '+de !media(rc=1)'
  command rm -rf "$R"

  say ""
  say "== D: all three scope restores 0 -> lands =="
  mkroot 1; run_in 0 0
  landed_common D '+de +media'
  chk "D restore_media_tail ran" called "$R" restore_media_tail
  chk "D the #apps set stays for the gate" eval '[ -f "$R/$APPCODE_REL/manifest.tsv" ]'
  command rm -rf "$R"

  say ""
  say "== E: no per-user DE or media dir (skip) -> lands as today =="
  mkroot 0; run_in 5 5
  landed_common E '-de -media'
  chk "E neither scope restore ran" eval 'ncalled "$R" "agent restore prof#de" && ncalled "$R" "agent restore prof#media"'
  command rm -rf "$R"

  say ""
  say "== F: #apps 5 -> BLANK NET (apps) before every landing step =="
  mkroot 1; run_in 0 0 5
  blank_common F
  chk "F the BLANK NET line names apps" has_log "$R/roam.log" 'IN "prof" BLANK NET (the apps restore could not reach the store)'
  lanes_ran F
  chk "F the BLANK NET reply leaves no .appcode" eval 'holds "$R/res" "BLANK NET" && absent "$R/$APPCODE_REL"'
  command rm -rf "$R"

  say ""
  say "== G: #apps 1 (damage, a missing chunk) still lands with no app code =="
  mkroot 1; run_in 0 0 1
  landed_common G '+de +media'
  chk "G the #apps restore ran before the landing's media stop, and left no .appcode" eval '_ga=$(grep -nxF "agent restore prof#apps" "$R/sim/calls" | head -n 1 | cut -d: -f1); _gs=$(grep -n "^stop_mediad" "$R/sim/calls" | head -n 1 | cut -d: -f1); [ -n "$_ga" ] && [ -n "$_gs" ] && [ "$_ga" -lt "$_gs" ] &&  absent "$R/$APPCODE_REL"'
  command rm -rf "$R"

  say ""
  say "== H: #sys 5 -> BLANK NET (sys); the lanes are joined (NWP-20261207-06, NWP-20261210-03) =="
  mkroot 1; run_in 0 0 0 5 0
  blank_common H
  chk "H the BLANK NET line names sys" has_log "$R/roam.log" 'IN "prof" BLANK NET (the sys restore could not reach the store)'
  chk "H acct_restore ran" called "$R" acct_restore
  lanes_ran H
  command rm -rf "$R"

  say ""
  say "== I: #keys 5 -> BLANK NET (keys) before every landing step (NWP-20261207-06) =="
  mkroot 1; run_in 0 0 0 0 5
  blank_common I
  chk "I the BLANK NET line names keys" has_log "$R/roam.log" 'IN "prof" BLANK NET (the keys restore could not reach the store)'
  lanes_ran I
  command rm -rf "$R"

  say ""
  say "== J: #keys 1 (damage) still lands; the fetch runs before the landing, the promotion after the reset =="
  mkroot 1; run_in 0 0 0 0 1
  landed_common J '+de +media'
  chk "J keystore_fetch ran once, before the landing's media stop" eval '_jf=$(grep -nxF keystore_fetch "$R/sim/calls" | head -n 1 | cut -d: -f1); _js=$(grep -n "^stop_mediad" "$R/sim/calls" | head -n 1 | cut -d: -f1); [ "$(ncalls "$R" keystore_fetch)" = 1 ] && [ -n "$_jf" ] && [ -n "$_js" ] && [ "$_jf" -lt "$_js" ]'
  chk "J keystore_restore ran after ks_signin_reset" eval '_jr=$(grep -nxF ks_signin_reset "$R/sim/calls" | head -n 1 | cut -d: -f1); _jk=$(grep -nxF keystore_restore "$R/sim/calls" | head -n 1 | cut -d: -f1); [ -n "$_jr" ] && [ -n "$_jk" ] && [ "$_jr" -lt "$_jk" ]'
  command rm -rf "$R"

  say ""
  say "== K: #sys 1 (damage) still lands =="
  mkroot 1; run_in 0 0 0 1 0
  landed_common K '+de +media'
  chk "K the #media and #apps restores and keystore_fetch ran" \
    eval 'called "$R" "agent restore prof#media" && called "$R" "agent restore prof#apps" && called "$R" keystore_fetch'
  command rm -rf "$R"

  say ""
  chk "the harness ran clean (no undefined function, unbound variable or parse error)" eqv "$HARN" ""
  if [ "$NOID" = 1 ]; then echo "HARNESS ERROR: a runner left no identity: $SH did not launch it" >&2; return 2; fi
  if [ -n "$HARN" ]; then echo "HARNESS ERROR: a runner under $SH failed at run time, in $HARNN case(s); the first: $HARN1" >&2; return 2; fi
  chk "identity: every case ran under $SH" eqv "$WRONGSH" 0
  say ""
  say "  -- [$SH] $p passed, $x failed"
  [ "$x" = 0 ]
}

echo "a scope restore that cannot reach the store: $SUT"
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
L_MD='      elif [ "$_mdrc" = 5 ]; then _innet=media'
L_GD='      if [ -z "$_innet" ]; then'
L_BN='      echo "BLANK NET" > "$RES"'
L_VF='    if [ -n "$_innet" ]; then'
L_CE='    elif od_shipped_prep && NOWHERE_PARK_KEEP="$(od_park_var keep)" NOWHERE_PARK_SHIPPED="$(od_park_var shipped)" NOWHERE_UNFETCHED_LIST="$(od_park_var ce)" NOWHERE_PHASE=apps NOWHERE_CLAIMS_SEED="$STATE/claims.seed" NOWHERE_SE_SECRET="$(pwv "$_se_v")" NOWHERE_FIDO2_HMAC="$(pwv "$_fh_v")" "$AGENT" restore s3 "$name" "$(pw "$pass")" "$USERDIR" >> "$LOG" 2>&1; then'
L_SM='      stop_mediad   # NWP-20261117-16: a predecessor'"'"'s media daemon goes only once this sign-in has landed'
L_HO='      hold_ondemand "$uid"'
L_OR='      echo "OK $uid" > "$RES"; _inres=OK'
L_AP='      elif [ "$_aprc" = 5 ]; then _innet=apps'
# NWP-20261210-03: lane A's status read back at the join, and the BLANK NET arm's .appcode removal
L_AR='      if [ -f "$_inlanes/A" ]; then read -r _aprc < "$_inlanes/A" || _aprc=1; fi'
L_AB='      rm -rf "$APPCODE" "$_inlanes" 2>> "$LOG"'
# NWP-20261207-06; NWP-20261210-03: the verdict reads #sys and #keys at the join, and lane K runs keystore_fetch
L_SY='      elif [ "${_acrc:-}" = 5 ]; then _innet=sys'
L_KF='      elif [ "$_ksrc" = 5 ]; then _innet=keys'
L_KL='          keystore_fetch; _ksrc=$?'
L_PR='      if _kpd=$(ks_in_dir); then rm -rf "$_kpd.pre" 2>> "$LOG"; fi'
L_CALL='      ks_signin_reset "$uid"   # NWP-20261108-01: this landed sign-in drops every other session'"'"'s Keystore staging, before keystore_restore'
for l in "$L_MD" "$L_GD" "$L_BN" "$L_VF" "$L_CE" "$L_SM" "$L_HO" "$L_OR" "$L_AP" "$L_AR" "$L_AB" \
         "$L_SY" "$L_KF" "$L_KL" "$L_PR" "$L_CALL"; do
  [ "$(grep -cxF -- "$l" "$SUT")" = 1 ] || { echo "EXTRACTION FAILED: anchor line not unique in $SUT: $l" >&2; exit 2; }
done
# mut <name> <awk-program>: convicted only by a failing line under EACH shell found; a harness error (rc 2) under any
# shell is a failure, never a conviction
mut() {
  local name="$1" prog="$2" t s r
  t=$(mktemp -p "$W")
  awk -v MD="$L_MD" -v GD="$L_GD" -v BN="$L_BN" -v VF="$L_VF" -v CE="$L_CE" -v SM="$L_SM" -v HO="$L_HO" -v OR="$L_OR" \
    -v AP="$L_AP" -v AR="$L_AR" -v AB="$L_AB" -v SY="$L_SY" -v KF="$L_KF" -v KL="$L_KL" -v PR="$L_PR" -v CALL="$L_CALL" \
    "$prog" "$SUT" > "$t"
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
mut "M1 the #media rc-5 check removed (the sign-in lands)" \
  '$0==MD{next} {print}'
mut "M2 any non-zero #media status treated as 5" \
  '$0==MD{print "      elif [ \"$_mdrc\" != 0 ] && [ \"$_mdrc\" != skip ]; then _innet=media"; next} {print}'
mut "M3 the #sys chain still runs after a #de 5 (A convicts: acct_restore called)" \
  '$0==GD{print "      if true; then"; next} {print}'
mut "M4 _inres=OK set on the blank path (the park put-back is skipped)" \
  '$0==BN{print $0 "; _inres=OK"; next} {print}'
mut "M5 BLANK written instead of BLANK NET (the gate would offer the rollback)" \
  '$0==BN{print "      echo \"BLANK\" > \"$RES\""; next} {print}'
mut "M6 stop_mediad back at the head of the vault-OK branch" \
  '$0==SM{next} {print} $0==CE{print SM}'
mut "M7 the verdict placed after bt_reset" \
  '$0==VF{print "    if false; then"; next} $0==HO{print "      if [ -n \"$_innet\" ]; then echo \"BLANK NET\" > \"$RES\"; else"} {print} $0==OR{print "      fi"}'
mut "M8 the #apps rc-5 check removed (the sign-in lands; F convicts)" \
  '$0==AP{next} {print}'
mut "M9 any non-zero #apps status treated as 5 (G convicts)" \
  '$0==AP{print "      elif [ \"$_aprc\" != 0 ] && [ \"$_aprc\" != skip ]; then _innet=apps"; next} {print}'
mut "M10 lane A's status never read back at the join (F convicts: the sign-in lands)" \
  '$0==AR{next} {print}'
mut "M11 the BLANK NET arm's .appcode removal dropped (A convicts: lane A's set is left)" \
  '$0==AB{print "      rm -rf \"$_inlanes\" 2>> \"$LOG\""; next} {print}'
mut "M12 the #sys rc-5 check removed (H convicts: the sign-in lands)" \
  '$0==SY{next} {print}'
mut "M13 any non-zero #sys status treated as 5 (K convicts)" \
  '$0==SY{print "      elif [ -n \"${_acrc:-}\" ] && [ \"$_acrc\" != 0 ]; then _innet=sys"; next} {print}'
mut "M14 the #keys rc-5 check removed (I convicts: the sign-in lands)" \
  '$0==KF{next} {print}'
mut "M15 any non-zero #keys status treated as 5 (J convicts)" \
  '$0==KF{print "      elif [ \"$_ksrc\" != 0 ]; then _innet=keys"; next} {print}'
mut "M16 keystore_fetch moved out of lane K to after ks_signin_reset in the landing (I convicts: the sign-in lands)" \
  '$0==KL{print "          _ksrc=0"; next} {print} $0==CALL{print "      keystore_fetch"}'
mut "M17 the verdict's keystore-in/<uid>.pre removal dropped (I convicts: .pre left)" \
  '$0==PR{next} {print}'
# M18 (the MMS/#media guard removed) is retired: since NWP-20261210-03 #media runs as a lane whatever #sys returns, and
# the MMS remap's own skip after a #de or #sys exit 5 is test-mms-remap-verdict.sh's.
[ "$MFAIL" = 0 ] || exit 1
echo "all mutants convicted"
