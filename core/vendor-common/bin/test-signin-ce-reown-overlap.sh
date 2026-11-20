#!/usr/bin/env bash
# test-signin-ce-reown-overlap.sh [<nowhere_roamd.sh>] [--mutate] -- the sign-in's CE reown and relabel run as ONE
# background job beside the #de restore, and the sign-in waits for it at ONE barrier before acct_restore, the first later
# step that writes $USERDIR (NWP-20261210-04; backlog §B 'A nearly empty profile takes about 85 s from submit to home;
# target under 60 s', cause (3): `TIMING reown-ce 3803ms, reown-de 3925ms`, lynx 2026111604).
#
# WHY THIS IS COMMITTED. The `in)` arm ran relabel_launcher, the CE remap_per_pkg, the CE restorecon -R, the #de
# restore and its tail, acct_restore and the MMS remap one after the other. The #de restore and its tail write only
# /data/user_de/<uid>, so the CE pass now runs beside them. Two things must hold, and no device run shows either cheaply:
# the job really overlaps the #de restore, and nothing that writes $USERDIR, and no verdict, runs before the job ends.
# acct_restore removes the chooser's account marks under /data/user/<uid> (acct_mark_file), so the barrier precedes it.
# This suite runs the REAL extracted arm, with the REAL _ms, _tlog, _ssum and qn, under every shell found among bash,
# sh, dash and mksh (the device's /system/bin/sh). Every other helper is a stub; the stubs write marker files:
#   the agent's #de restore writes de-start, waits (bounded) until the CE stub has decided, then writes de-end;
#   remap_per_pkg "$USERDIR" writes ce-reown-start, polls (0.1 s, at most 5 s) for de-start, records `overlap` when
#   the #de restore is running then and `no-overlap` otherwise, then writes ce-reown-end;
#   restorecon -R "$USERDIR" sleeps 0.3 s and writes ce-relabel-end;
#   relabel_launcher, acct_restore, nowhere_db_fix (the MMS remap) and the $RES write record whether the CE marks exist.
#   O1 vault 0, #de 0: `overlap` recorded (the CE reown ran while the #de restore ran)
#   O2 the MMS remap (TELDB present) runs only after ce-relabel-end, and its log line follows the barrier's
#      TIMING reown-ce-wait line
#   O3 #de exit 5 (BLANK NET): RES is written only after ce-relabel-end; the same for a #sys exit 5
#   O4 the vault restore fails: no background job, nothing waited, RES is BLANK as before
#   O5 the log holds exactly one each of TIMING reown-ce, restorecon-ce and reown-ce-wait; the summary holds two
#      `phase=reown` lines (the CE wait and the #de tail; no media dir, so no #media tail)
#   O6 relabel_launcher runs before ce-reown-start
#   O7 acct_restore runs only after ce-relabel-end (it removes the account marks under $USERDIR)
# #media, #apps and keystore_fetch are NOT pinned to the barrier: they never write $USERDIR.
#
#   bash test-signin-ce-reown-overlap.sh              # the cases
#   bash test-signin-ce-reown-overlap.sh --mutate     # ... plus mutants of roamd that must each CONVICT under every shell
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
line_fn_of() { grep -m1 -E "^$2\(\) \{ .*\}$" "$1"; }   # a one-line function (_ms, _tlog)
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
reroot() { printf '%s\n' "$1" | sed -E -e 's#([" ])/data/#\1$ROOT/data/#g' -e 's#/system/bin/nowhere_db_fix#$ROOT/system/bin/nowhere_db_fix#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> <shell> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" SH="$2" quiet="${3:-}" p=0 x=0 QN IST KID MS TL SS IN RI R n PF NOID=0 WRONGSH=0 HARN="" HARNN=0 HARN1=""
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    [$SH] $l"
    else x=$((x+1)); say "  FAIL  [$SH] $l"; [ -z "$quiet" ] || printf 'FAILED [%s] %s\n' "$SH" "$l"; fi
  }
  holds() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }
  absent() { [ ! -e "$1" ]; }
  # count <file> <ERE>: how many lines of the file match (0 for a missing file). Read into a variable, never `| grep -q`.
  count() { local c; c=$(grep -cE -- "$2" "$1" 2>/dev/null); printf '%s' "${c:-0}"; }
  eqv() { [ "$1" = "$2" ]; }

  QN=$(fn_of "$f" qn)
  IST=$(fn_of "$f" in_scope_tokens)
  KID=$(fn_of "$f" ks_in_dir)
  SS=$(fn_of "$f" _ssum)
  MS=$(line_fn_of "$f" _ms)
  TL=$(line_fn_of "$f" _tlog)
  IN=$(arm_of "$f" in)
  for n in QN IST KID SS MS TL; do
    eval "[ -n \"\$$n\" ]" || { echo "EXTRACTION FAILED: helper $n not found in $f" >&2; return 2; }
  done
  case "$IN" in *'echo "NEEDKEY" > "$RES"'*'"${name}#de"'*'acct_restore "$uid"'*'nowhere_db_fix mms-remap'*'echo "OK $uid" > "$RES"'*) ;;
    *) echo "EXTRACTION FAILED: the in arm in $f" >&2; return 2 ;; esac
  RI=$(reroot "$IN")
  n=$(printf '%s\n' "$RI" | grep -o '\$ROOT/data/' | grep -c .)
  [ "$n" -ge 5 ] || { echo "RE-ROOT FAILED: the in arm has $n rewritten paths, want >= 5" >&2; return 2; }
  n=$(nleft "$RI")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: the in arm keeps $n absolute /data path(s) in live code" >&2; return 2; }
  n=$(printf '%s\n' "$RI" | grep -c '\$ROOT/system/bin/nowhere_db_fix mms-remap')
  [ "$n" = 1 ] || { echo "RE-ROOT FAILED: the MMS remap's nowhere_db_fix ($n rewritten, want 1)" >&2; return 2; }

  harness_check() {
    local e
    e=$(grep -m1 -E 'not found|unbound variable|parameter not set|syntax error|Syntax error|bad substitution|Bad substitution' "$1/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || { HARN="$HARN [$e]"; HARNN=$((HARNN+1)); [ -n "$HARN1" ] || HARN1="$e"; }
  }
  idcheck() {
    if [ ! -s "$1/sim/shell.id" ]; then NOID=1
    elif ! idok "$SH" "$1/sim/shell.id"; then WRONGSH=1; fi
  }
  # mkrunner <file> <root> <vault rc> <#de rc> <#sys rc>: identity probe, print shim, the case's values, the stubs, the
  # real helpers and the REAL arm. POSIX only: it runs under every shell found. No `set -u`: a mutant that drops the `&`
  # leaves $! unset, and that must reach the assertions, not abort the runner.
  mkrunner() {
    {
      printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$2/sim/shell.id")"
      printf '%s\n' "$PRINT_SHIM"
      printf 'ROOT=%s; uid=11; op=in; name=prof; pass=pw; keymode=""; srcunit=""; sesec=""; VAULT_RC=%s; DE_RC=%s; SYS_RC=%s\n' \
        "$(sq "$2")" "$(sq "$3")" "$(sq "$4")" "$(sq "$5")"
      cat <<'STUB'
LOG="$ROOT/roam.log"; RES="$ROOT/res"; STATE="$ROOT/state"; USERDIR="$ROOT/data/user/$uid"; AGENT=agent_sim
KS_IN="$ROOT/data/nowhere/keystore-in"
M="$ROOT/m"
rec() { printf '%s\n' "$*" >> "$ROOT/sim/calls"; }
# mark <name>: did the CE job's marks exist at this moment? "<name> <reown-start|-> <relabel-end|->"
mark() {
  local a=- b=-
  [ -e "$M/ce-reown-start" ] && a=reown-start
  [ -e "$M/ce-relabel-end" ] && b=relabel-end
  printf '%s %s %s\n' "$1" "$a" "$b" >> "$M/order"
}
# waitfor <seconds*10> <file>...: poll every 0.1 s until one of the files exists; 0 when one did
waitfor() {
  local n="$1" g; shift
  while [ "$n" -gt 0 ]; do
    for g in "$@"; do [ -e "$g" ] && return 0; done
    command sleep 0.1; n=$((n-1))
  done
  return 1
}
agent_sim() {
  case "$1" in
    fido2-is-enrolled) return 1 ;;
    restore)
      rec "agent restore $3"
      case "$3" in
        prof) return "$VAULT_RC" ;;
        'prof#de')
          : > "$M/de-start"
          waitfor 50 "$M/overlap" "$M/no-overlap" "$M/ce-reown-end"
          : > "$M/de-end"
          return "$DE_RC" ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}
pw() { printf '%s\n' "$ROOT/sim/pw"; }
pwv() { [ -z "$1" ] || pw "$1"; }
od_fetch_data() { return 0; }; od_listed() { return 1; }; od_block_app() { return 0; }; od_unblock_app() { :; }; od_pending_clear() { :; }; od_block_installed() { :; }; od_shipped_prep() { return 0; }; od_park_var() { :; }; od_unf_path() { echo "$STATE/odfetch.$1/unfetched.$2"; }
_se_v=""; _fh_v=""
remap_per_pkg() {
  if [ "$1" = "$USERDIR" ]; then
    : > "$M/ce-reown-start"
    if waitfor 50 "$M/de-start" && [ ! -e "$M/de-end" ]; then : > "$M/overlap"; else : > "$M/no-overlap"; fi
    : > "$M/ce-reown-end"
  else
    rec "remap_per_pkg other"
  fi
}
restorecon() {
  local l; for l in "$@"; do :; done
  if [ "$l" = "$USERDIR" ]; then command sleep 0.3; : > "$M/ce-relabel-end"; else rec "restorecon other"; fi
}
relabel_launcher() { mark relabel_launcher; }
acct_restore() { mark acct_restore; return "$SYS_RC"; }
# the $RES write: each reply records the CE marks at the moment it is written
echo() {
  case "$*" in "OK $uid"|BLANK|"BLANK NET"|NEEDKEY) mark "res" ;; esac
  command echo "$@"
}
for t in usb_host remap_media_db insert_deferred_media rescan_media remap_tree reown_ext_appdata keystore_push uiderrors_floor_take \
         restore_media_tail ks_signin_reset keystore_restore tz_surface sroam_surface hold_ondemand od_parked_report \
         reap_stale_ondemand reap_orphan_provisioned uiderrors_floor_commit stop_mediad keystore_fetch; do
  eval "$t() { :; }"
done
bt_reset() { BT_RESTORED=0; return 0; }
sleep() { return 0; }   # the arm's own waits; the stubs above call `command sleep`
STUB
      printf '%s\n' "$MS" "$TL" "$SS" "$QN" "$IST" "$KID"
      printf '_sum0=$(_ms); _sumt=$_sum0\n'
      printf 'case "$op" in\n%s\nesac\n' "$RI"
      # every assertion reads marks taken at the moment of each step, so this trailing wait hides nothing: it only
      # keeps a mutant's still-running job from writing into a case root after the runner exits
      printf 'wait\n'
    } > "$1"
  }
  # mkroot <teldb 0|1>: the case root, the per-user CE and DE dirs, no media dir, and (1) the MMS database
  mkroot() {
    R=$(mktemp -d -p "$W")
    mkdir -p "$R/sim" "$R/m" "$R/state" "$R/data/nowhere" "$R/data/user/11/com.nowhere.chooser/files" \
      "$R/data/user/0/com.nowhere.chooser/files" "$R/data/user_de/11" "$R/data/system/users/11" "$R/system/bin"
    : > "$R/sim/calls"
    if [ "$1" = 1 ]; then
      mkdir -p "$R/data/user/11/com.android.providers.telephony/databases"
      : > "$R/data/user/11/com.android.providers.telephony/databases/mmssms.db"
    fi
    # nowhere_db_fix: the MMS remap records the CE marks at its moment
    printf '#!/bin/sh\nM=%s\na=-; b=-\n[ -e "$M/ce-reown-start" ] && a=reown-start\n[ -e "$M/ce-relabel-end" ] && b=relabel-end\nprintf "%%s %%s %%s\\n" "mms-$1" "$a" "$b" >> "$M/order"\nexit 0\n' \
      "$(sq "$R/m")" > "$R/system/bin/nowhere_db_fix"
    chmod +x "$R/system/bin/nowhere_db_fix"
    return 0
  }
  run_in() {  # run_in <vault rc> <#de rc> <#sys rc>
    mkrunner "$R/sim/run.sh" "$R" "$1" "$2" "$3"
    "$SH" "$R/sim/run.sh" >/dev/null 2>>"$R/sim/stderr"
    harness_check "$R"
    idcheck "$R"
  }
  # the line of m/order for <name>
  ord() { grep -m1 "^$1 " "$R/m/order" 2>/dev/null; }

  PF=$(mktemp -p "$W") || return 2
  mkrunner "$PF" "$W" 0 0 0
  if ! "$SH" -n "$PF" 2>/dev/null; then
    command rm -f "$PF"
    chk "THE ARM DOES NOT PARSE under $SH" false
    say "  -- [$SH] $p passed, $x failed"
    return 1
  fi
  command rm -f "$PF"

  say "== O1 O2 O5 O6 O7: vault 0, #de 0, #sys 0, MMS db present -> lands, the CE job overlapped the #de restore =="
  mkroot 1; run_in 0 0 0
  chk "O1 the CE reown ran while the #de restore ran (overlap recorded)" eval '[ -e "$R/m/overlap" ] && absent "$R/m/no-overlap"'
  chk "O2 the MMS remap ran, after ce-relabel-end" eqv "$(ord mms-mms-remap)" "mms-mms-remap reown-start relabel-end"
  chk "O2 the MMS remap's log line follows the barrier's TIMING reown-ce-wait line" eval \
    '_w=$(grep -n "^\[roamd\] TIMING reown-ce-wait " "$R/roam.log" | head -n 1 | cut -d: -f1); _r=$(grep -n "^\[roamd\] remapped MMS part._data -> user 11 " "$R/roam.log" | head -n 1 | cut -d: -f1); [ -n "$_w" ] && [ -n "$_r" ] && [ "$_w" -lt "$_r" ]'
  chk "O5 exactly one TIMING reown-ce line" eqv "$(count "$R/roam.log" '^\[roamd\] TIMING reown-ce [0-9-]+ms ')" 1
  chk "O5 exactly one TIMING restorecon-ce line" eqv "$(count "$R/roam.log" '^\[roamd\] TIMING restorecon-ce [0-9-]+ms ')" 1
  chk "O5 exactly one TIMING reown-ce-wait line" eqv "$(count "$R/roam.log" '^\[roamd\] TIMING reown-ce-wait [0-9-]+ms ')" 1
  chk "O5 the summary holds two phase=reown lines (the CE wait and the #de tail)" \
    eqv "$(count "$R/state/signin-summary.11" '^v=1 phase=reown ms=[0-9]+$')" 2
  chk "O6 relabel_launcher ran before ce-reown-start" eqv "$(ord relabel_launcher)" "relabel_launcher - -"
  chk "O7 acct_restore ran after ce-relabel-end" eqv "$(ord acct_restore)" "acct_restore reown-start relabel-end"
  chk "the reply is OK 11, written after ce-relabel-end" eval 'holds "$R/res" "OK 11" && [ "$(ord res)" = "res reown-start relabel-end" ]'
  command rm -rf "$R"

  say ""
  say "== O3: #de exit 5 -> BLANK NET, written only after ce-relabel-end =="
  mkroot 1; run_in 0 5 0
  chk "O3 #de 5: the reply is BLANK NET" holds "$R/res" "BLANK NET"
  chk "O3 #de 5: RES written after ce-relabel-end" eqv "$(ord res)" "res reown-start relabel-end"
  chk "O3 #de 5: no acct_restore, no MMS remap" eval '[ -z "$(ord acct_restore)" ] && [ -z "$(ord mms-mms-remap)" ]'
  chk "O3 #de 5: one TIMING reown-ce-wait line" eqv "$(count "$R/roam.log" '^\[roamd\] TIMING reown-ce-wait [0-9-]+ms ')" 1
  command rm -rf "$R"

  say ""
  say "== O3: #sys exit 5 -> BLANK NET, written only after ce-relabel-end =="
  mkroot 1; run_in 0 0 5
  chk "O3 #sys 5: the reply is BLANK NET" holds "$R/res" "BLANK NET"
  chk "O3 #sys 5: RES written after ce-relabel-end" eqv "$(ord res)" "res reown-start relabel-end"
  chk "O3 #sys 5: no MMS remap" eval '[ -z "$(ord mms-mms-remap)" ]'
  command rm -rf "$R"

  say ""
  say "== O4: the vault restore fails -> no CE job, nothing waited, BLANK as before =="
  mkroot 1; run_in 1 0 0
  chk "O4 the reply is BLANK" holds "$R/res" "BLANK"
  chk "O4 no CE job ran" eval 'absent "$R/m/ce-reown-start" && absent "$R/m/ce-relabel-end"'
  chk "O4 no TIMING reown-ce, restorecon-ce or reown-ce-wait line" \
    eqv "$(count "$R/roam.log" '^\[roamd\] TIMING (reown-ce|restorecon-ce|reown-ce-wait) ')" 0
  chk "O4 no #de restore, no launcher relabel" eval '[ "$(count "$R/sim/calls" "^agent restore prof#de$")" = 0 ] && [ -z "$(ord relabel_launcher)" ]'
  command rm -rf "$R"

  say ""
  chk "the harness ran clean (no undefined function or parse error)" eqv "$HARN" ""
  if [ "$NOID" = 1 ]; then echo "HARNESS ERROR: a runner left no identity: $SH did not launch it" >&2; return 2; fi
  if [ -n "$HARN" ]; then echo "HARNESS ERROR: a runner under $SH failed at run time, in $HARNN case(s); the first: $HARN1" >&2; return 2; fi
  chk "identity: every case ran under $SH" eqv "$WRONGSH" 0
  say ""
  say "  -- [$SH] $p passed, $x failed"
  [ "$x" = 0 ]
}

echo "the sign-in's CE reown beside the #de restore: $SUT"
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
L_JOB='      ( _cett=$(_ms); remap_per_pkg "$USERDIR"; _tlog reown-ce "$_cett"; _cett=$(_ms); restorecon -R "$USERDIR" 2>> "$LOG"; _tlog restorecon-ce "$_cett" ) &'
L_BAR='      if [ -n "$_cerp" ]; then _sumt=$(_ms); _tt=$(_ms); wait "$_cerp" 2>/dev/null; _tlog reown-ce-wait "$_tt"; _ssum reown "$_sumt"; _cerp=""; fi'
L_LAU='      relabel_launcher "$uid" "$USERDIR"   # rewrite home-layout serial so the launcher keeps it (see above)'
L_ACG='        acct_restore "$uid"; _acrc=$?   # #DIA-20260802-02: restore the AccountManager account rows (name#sys) BEFORE provisionRoamedApps installs the authenticator'
L_SYF='        if [ "$_acrc" = 5 ]; then _innet=sys; fi'
L_MMF='          unset _mmsrc'
L_CMT='      # NWP-20261210-04: the CE reown and relabel run as ONE background job, beside the #de restore and its tail below.'
for l in "$L_JOB" "$L_BAR" "$L_LAU" "$L_ACG" "$L_SYF" "$L_MMF" "$L_CMT"; do
  [ "$(grep -cxF -- "$l" "$SUT")" = 1 ] || { echo "EXTRACTION FAILED: anchor line not unique in $SUT: $l" >&2; exit 2; }
done
# mut <name> <want CONVICTED|SURVIVED> <ERE of the convicting assertion's label> <awk-program>: convicted only when the
# named assertion FAILS under EACH shell found; a harness error (rc 2) under any shell is a failure, never a conviction
mut() {
  local name="$1" want="$2" re="$3" prog="$4" t s r out
  t=$(mktemp -p "$W")
  awk -v JOB="$L_JOB" -v BAR="$L_BAR" -v LAU="$L_LAU" -v ACG="$L_ACG" -v SYF="$L_SYF" -v MMF="$L_MMF" -v CMT="$L_CMT" \
    "$prog" "$SUT" > "$t"
  if cmp -s "$t" "$SUT"; then echo "  FAIL  mutant did not apply: $name"; MFAIL=1; command rm -f "$t"; return; fi
  for s in $SHELLS; do
    out=$(suite "$t" "$s" quiet 2>&1); r=$?
    if [ "$want" = CONVICTED ] && [ "$r" = 1 ] && grep -qE -- "^FAILED \[$s\] $re" <<< "$out"; then echo "  ok    CONVICTED [$s]: $name"
    elif [ "$want" = SURVIVED ] && [ "$r" = 0 ]; then echo "  ok    SURVIVED (control) [$s]: $name"
    else echo "  FAIL  [$s] rc=$r, want $want: $name"; MFAIL=1; fi
  done
  command rm -f "$t"
}
MFAIL=0
echo "== mutants (each must CONVICT under every shell found; the control must SURVIVE) =="
mut "M1 the & dropped: the CE job runs in the foreground (O1 convicts: no-overlap)" CONVICTED 'O1 ' \
  '$0==JOB{sub(/ \) &$/, " )"); print; next} {print}'
mut "M2 the barrier deleted (O3 convicts: the #de 5 reply before ce-relabel-end; O2 and O7 fail too)" CONVICTED 'O3 #de 5: RES written after' \
  '$0==BAR{next} {print}'
mut "M3 the barrier moved after the MMS remap (O2 convicts)" CONVICTED 'O2 the MMS remap ran, after' \
  '$0==BAR{next} {print} $0==MMF{getline; print; print BAR}'
mut "M4 the barrier inside the acct_restore [ -z \"\$_innet\" ] block (O3 convicts: #de 5 replies before ce-relabel-end)" CONVICTED 'O3 #de 5: RES written after' \
  '$0==BAR{next} $0==ACG{print "  " BAR} {print}'
mut "M5 relabel_launcher moved into the job after the remap (O6 convicts)" CONVICTED 'O6 ' \
  '$0==LAU{next} $0==JOB{sub(/_tlog reown-ce "\$_cett";/, "_tlog reown-ce \"$_cett\"; relabel_launcher \"$uid\" \"$USERDIR\";"); print; next} {print}'
mut "M6 the barrier moved after acct_restore, before the MMS remap (O7 convicts)" CONVICTED 'O7 ' \
  '$0==BAR{next} {print} $0==SYF{getline; print; print BAR}'
mut "M7 control: a comment's wording changed" SURVIVED '' \
  '$0==CMT{print "      # NWP-20261210-04: the CE reown and the relabel run as ONE job in the background."; next} {print}'
[ "$MFAIL" = 0 ] || exit 1
echo "all mutants convicted, the control survived"
