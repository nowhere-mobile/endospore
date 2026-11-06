#!/usr/bin/env bash
# test-acct-place.sh [<nowhere_roamd.sh>] [--mutate] -- acct_restore / acct_reload, the account-placement path.
#
# WHY THIS IS COMMITTED. acct_restore stages the sealed accounts dbs in a hold; acct_reload places them while AMS's
# connection is detached, then reloads. It is the path behind #732 and #743, and every ordering in it is a way to
# lose an account: a stale -wal left beside a copied db replays the OLD journal over the restored account; a reload
# before the copy re-reads the empty db; a hold never removed re-places an old account at a LATER grant; a failed
# restore that leaves its hold behind does the same. Until now only stubs touched it. Here the functions are lifted
# out of roamd by name, the three /data roots are rewritten to a temp root, and `cmd`, cp and rm are traced in ORDER
# (cp and rm as PATH wrappers that log and then exec the real tool, so "copy" has a place in the sequence).
#
# NWP-20261118-09: acct_reload checks that every CE file the hold carries landed at its own size. A short copy left a
# torn db or -wal whose row count could read a confirmed zero and disarm the #743 guard. The run prelude's `cp` cuts
# the placed CE db (CUT=db) or -wal (CUT=wal) after the real copy. P1 and P2: no accounts_ce.db* is left, the log has
# `copied short`. P3: a whole CE+DE copy is placed as before. Each runs under every shell found.
#
#   bash test-acct-place.sh            # the cases
#   bash test-acct-place.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# No device, no db: the dbs are byte strings. $AGENT, cmd, chown, restorecon and `print` (mksh's `print -r --`)
# are stubbed; /system/bin/nowhere_db_fix is absent.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# Every shell found runs the NWP-20261104-05 mark-void cases (the device's /system/bin/sh is mksh); de-duplicated by
# the file they resolve to. The older cases run under bash.
SHELLS=()
seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$p")
done

# --- extraction: the functions, by name --------------------------------------------------------------------
FUNCS=""
for fn in pw qn acct_mark_file acct_mark_hashes acct_restore acct_reload; do
  body=$(sed -n "/^$fn() {\$/,/^}\$/p" "$SUT")
  case "$body" in
    "$fn() {"*) FUNCS="$FUNCS$body"$'\n' ;;
    *) echo "EXTRACTION FAILED -- $fn not found in $SUT" >&2; exit 2 ;;
  esac
done
REWRITTEN=$(printf '%s\n' "$FUNCS" \
  | sed -e 's#/data/nowhere/#$T/nowhere/#g' -e 's#/data/system_ce/#$T/system_ce/#g' -e 's#/data/system_de/#$T/system_de/#g')
changed=$(diff <(printf '%s\n' "$FUNCS") <(printf '%s\n' "$REWRITTEN") | grep -c '^>')
WANT=${ACCT_WANT:-13}   # a mutant that deletes path-bearing lines passes its own count
[ "$changed" = "$WANT" ] || { echo "EXTRACTION FAILED -- path rewrite changed $changed lines, want $WANT ($SUT)" >&2; exit 2; }
[ ! -e /system/bin/nowhere_db_fix ] || { echo "refusing to run: /system/bin/nowhere_db_fix exists on this host" >&2; exit 2; }

# --- harness ----------------------------------------------------------------------------------------------
# run <mode> <lay> <preseed> <body>. mode: ok|fail -- what the stub agent exits with. lay: shell run by the stub
# agent with $hold set (what the restore "downloads"). preseed: shell run before the call ($T is the temp root).
# body: the call under test. Leaves $TT (root), $TT/out (stdout+stderr), $TT/trace (ordered cmd/cp/rm), $TT/log.
TT=""
RSH=bash   # the shell that runs the lifted functions; the mark-void cases loop it over every shell found
run(){
  local T; T=$(mktemp -d -p "$W"); TT=$T
  mkdir -p "$T/nowhere" "$T/state" "$T/system_ce/10" "$T/system_de/10" "$T/wrap"
  local t
  for t in cp rm; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/trace"\nexec %s "$@"\n' "$t" "$T" "$(command -v $t)" > "$T/wrap/$t"
    chmod +x "$T/wrap/$t"
  done
  : > "$T/trace"
  {
    echo "T='$T'; STATE=\"\$T/state\"; LANE=rw; LOG=\"\$T/log\"; : > \"\$LOG\"; name=probe; pass=x; uid=10"
    # uid=10 above: `local uid=$1 hold=...-$uid` reads the OUTER uid under bash (mksh assigns left to right).
    echo 'PATH="$T/wrap:$PATH"; AGENT=agent_stub; ACCT_MARK_ROOT="$T/user"'
    echo 'agent_stub(){ local hold="$5"; '"${2:-:}"'; '"$([ "$1" = fail ] && echo return 1 || echo return 0)"'; }'
    echo 'cmd(){ echo "cmd $*" >> "$T/trace"; }; chown(){ :; }; restorecon(){ :; }'
    # NWP-20261118-09: cp runs the traced wrapper, then cuts the placed CE db (CUT=db) or -wal (CUT=wal) to 3 bytes.
    echo 'cp(){ local _cpl _cpr; command cp "$@"; _cpr=$?; for _cpl in "$@"; do :; done; case "${CUT:-}:$_cpl" in "db:$T/system_ce/10/") printf NEW > "$T/system_ce/10/accounts_ce.db" ;; "wal:$T/system_ce/10/") printf NEW > "$T/system_ce/10/accounts_ce.db-wal" ;; esac; return $_cpr; }'
    # mksh's print: -r raw, -n no newline, then `--`.
    # mksh keeps its real builtin.
    echo 'case "${KSH_VERSION:-}" in *MIRBSD*) ;; *) print(){ local nl=1; case "$1" in -*n*) nl=0 ;; esac; shift; [ "$1" = -- ] && shift; if [ $nl = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; } ;; esac'
    printf '%s\n' "$REWRITTEN"
    echo "${3:-:}"
    echo "$4"
  } > "$T/run.sh"
  "$RSH" "$T/run.sh" > "$T/out" 2>&1
}
done_(){ rm -rf "$TT"; }   # frees early; $W removes whatever is left
out(){ cat "$TT/out"; }
log(){ cat "$TT/log"; }
# line number of the first trace entry matching a regex, 0 if none
pos(){ grep -nE "$1" "$TT/trace" | head -1 | cut -d: -f1; }
cnt(){ grep -cE "$1" "$TT/trace"; }

CE='mkdir -p "$hold/ce"; printf NEWCE > "$hold/ce/accounts_ce.db"; printf NEWCEWAL > "$hold/ce/accounts_ce.db-wal"'
DE='mkdir -p "$hold/de"; printf NEWDE > "$hold/de/accounts_de.db"; printf NEWDEWAL > "$hold/de/accounts_de.db-wal"'
STALE='printf OLDCE > "$T/system_ce/10/accounts_ce.db"; printf STALECEWAL > "$T/system_ce/10/accounts_ce.db-wal"; printf STALECESHM > "$T/system_ce/10/accounts_ce.db-shm"
printf OLDDE > "$T/system_de/10/accounts_de.db"; printf STALEDEWAL > "$T/system_de/10/accounts_de.db-wal"; printf STALEDESHM > "$T/system_de/10/accounts_de.db-shm"'
HOLD='$T/nowhere/acct-hold-10'
# a hold laid directly (acct_reload tests do not go through the agent)
mkhold(){ echo 'hold='"$HOLD"'; '"$1"; }

echo "== acct_restore =="
run fail "$CE" "" 'acct_restore 10; echo "rc=$?"; [ -e '"$HOLD"' ] && echo hold=left || echo hold=gone'
case "$(out)" in *rc=0*hold=gone*) ok "an agent failure removes the hold and returns 0" ;; *) no "an agent failure removes the hold and returns 0 -- $(out)" ;; esac; done_

run ok 'mkdir -p "$hold/ce"; printf x > "$hold/ce/other"' "" 'acct_restore 10; echo "rc=$?"; [ -e '"$HOLD"' ] && echo hold=left || echo hold=gone'
case "$(out)" in *rc=0*hold=gone*) ok "a hold with no db is removed" ;; *) no "a hold with no db is removed -- $(out)" ;; esac; done_

run ok "$CE; $DE" "" 'acct_restore 10; echo "rc=$?"; ls '"$HOLD"'/ce '"$HOLD"'/de | tr "\n" " "'
case "$(out)" in *rc=0*accounts_ce.db*accounts_de.db*) ok "a CE+DE hold is kept with both halves" ;; *) no "a CE+DE hold is kept with both halves -- $(out)" ;; esac
case "$(log)" in *"has NO CE half"*) no "a CE+DE hold logs no missing-CE warning" ;; *) ok "a CE+DE hold logs no missing-CE warning" ;; esac
case "$(log)" in *"staged (hold) ce=yes de=yes"*) ok "a CE+DE hold logs ce=yes de=yes" ;; *) no "a CE+DE hold logs ce=yes de=yes -- $(log)" ;; esac; done_

run ok "$DE" "" 'acct_restore 10; echo "rc=$?"'
case "$(log)" in *"hold has NO CE half"*"ce=NO de=yes"*) ok "a DE-only hold logs the no-CE warning" ;; *) no "a DE-only hold logs the no-CE warning -- $(log)" ;; esac; done_

echo "== acct_reload =="
run ok "" "" 'acct_reload 10; echo "rc=$?"'
[ "$(cnt .)" = 0 ] && ok "no hold dir -> no cmd, cp or rm call" || no "no hold dir -> no cmd, cp or rm call -- $(cat $TT/trace)"
case "$(out)" in *rc=0*) ok "no hold dir -> returns 0" ;; *) no "no hold dir -> returns 0 -- $(out)" ;; esac; done_

run ok "" "$STALE" "$(mkhold "$CE; $DE"; echo 'hold='"$HOLD"; echo 'acct_reload 10; echo "rc=$?"; [ -e "$hold" ] && echo hold=left || echo hold=gone')"
O=$(out)
case "$O" in *rc=0*hold=gone*) ok "a CE+DE reload returns 0 and removes the hold" ;; *) no "a CE+DE reload returns 0 and removes the hold -- $O" ;; esac
[ "$(cat $TT/system_ce/10/accounts_ce.db)" = NEWCE ] && ok "CE db placed" || no "CE db placed"
[ "$(cat $TT/system_de/10/accounts_de.db)" = NEWDE ] && ok "DE db placed" || no "DE db placed"
for half in ce:accounts_ce de:accounts_de; do
  d=${half%%:*}; f=${half##*:}
  [ ! -e "$TT/system_$d/10/$f.db-shm" ] && ok "$d: the target's stale -shm is gone (the hold carried none)" || no "$d: the target's stale -shm is gone -- still there"
  w=$(cat "$TT/system_$d/10/$f.db-wal" 2>/dev/null)
  case "$d:$w" in ce:NEWCEWAL|de:NEWDEWAL) ok "$d: the target's -wal is the hold's, not the stale one" ;; *) no "$d: the target's -wal is the hold's -- got '$w'" ;; esac
  p_rm=$(pos "^rm -f .*system_$d/10/$f.db-wal"); p_cp=$(pos "^cp .*/$d/$f.db")
  { [ -n "$p_rm" ] && [ -n "$p_cp" ] && [ "$p_rm" -lt "$p_cp" ] && [ "$p_rm" != 0 ]; } && ok "$d: the stale -wal/-shm rm runs before the copy" || no "$d: the stale rm runs before the copy (rm@$p_rm cp@$p_cp)"
done
p_det=$(pos "^cmd account detach-user 10"); p_cp=$(pos "^cp "); p_rel=$(pos "^cmd account reload-user 10"); p_hold=$(pos "^rm -rf .*acct-hold-10")
{ [ "$p_det" != 0 ] && [ "$p_cp" != 0 ] && [ "$p_rel" != 0 ] && [ "$p_hold" != 0 ] \
  && [ "$p_det" -lt "$p_cp" ] && [ "$p_cp" -lt "$p_rel" ] && [ "$p_rel" -lt "$p_hold" ]; } \
  && ok "order: detach-user < copy < reload-user < hold removed" \
  || no "order: detach-user < copy < reload-user < hold removed (detach@$p_det cp@$p_cp reload@$p_rel holdrm@$p_hold)"
case "$(log)" in *"placed ce=yes de=yes + reloaded"*) ok "logs ce=yes de=yes" ;; *) no "logs ce=yes de=yes -- $(log)" ;; esac
case "$(log)" in *"WARNING: no CE db placed"*) no "a CE+DE reload logs no no-CE warning" ;; *) ok "a CE+DE reload logs no no-CE warning" ;; esac; done_

# A hold with a db but NO -wal at all: the target's stale -wal and -shm must still go, and none may reappear.
run ok "" "$STALE" "$(mkhold 'mkdir -p "$hold/ce"; printf NEWCE > "$hold/ce/accounts_ce.db"'; echo 'acct_reload 10')"
{ [ ! -e "$TT/system_ce/10/accounts_ce.db-wal" ] && [ ! -e "$TT/system_ce/10/accounts_ce.db-shm" ]; } \
  && ok "a hold with no -wal: the target's stale -wal and -shm are gone" || no "a hold with no -wal: the target's stale -wal and -shm are gone"
[ "$(cat $TT/system_ce/10/accounts_ce.db)" = NEWCE ] && ok "a hold with no -wal: the db is still placed" || no "a hold with no -wal: the db is still placed"
case "$(log)" in *"placed ce=yes de=no + reloaded"*) ok "a CE-only reload logs de=no" ;; *) no "a CE-only reload logs de=no -- $(log)" ;; esac; done_

# DE-only hold: the warning, and the CE target is untouched.
run ok "" "$STALE" "$(mkhold "$DE"; echo 'acct_reload 10')"
case "$(log)" in *"WARNING: no CE db placed for user 10"*) ok "a DE-only reload logs the no-CE warning" ;; *) no "a DE-only reload logs the no-CE warning -- $(log)" ;; esac
[ "$(cat $TT/system_ce/10/accounts_ce.db)" = OLDCE ] && ok "a DE-only reload leaves the CE target alone" || no "a DE-only reload leaves the CE target alone"
[ "$(cnt '^cp .*/ce/')" = 0 ] && ok "a DE-only reload copies nothing for CE" || no "a DE-only reload copies nothing for CE"
[ "$(cnt '^cmd account reload-user')" = 1 ] && ok "a DE-only reload still reloads" || no "a DE-only reload still reloads"
[ ! -e "$TT/nowhere/acct-hold-10" ] && ok "a DE-only reload removes the hold" || no "a DE-only reload removes the hold"; done_

echo "== NWP-20261118-09: a short CE copy leaves no torn file and arms the guard, in every shell =="
ce_left(){ local f l=""; for f in "$TT"/system_ce/10/accounts_ce.db*; do [ -e "$f" ] && l="$l ${f##*/}"; done; echo "$l"; }
for RSH in "${SHELLS[@]}"; do
  t="[$(basename "$RSH")]"
  for cut in db wal; do
    run ok "" "$STALE; CUT=$cut" "$(mkhold "$CE; $DE"; echo 'acct_reload 10')"
    L=$(log); left=$(ce_left)
    [ -z "$left" ] && ok "$t $cut cut: no accounts_ce.db* is left in the CE dir" || no "$t $cut cut: torn CE files left:$left"
    case "$L" in *"accounts_ce.db copied short for user 10"*) ok "$t $cut cut: the log has the copied-short line" ;; *) no "$t $cut cut: the copied-short line is missing -- $L" ;; esac
    case "$L" in *"placed ce=no de=yes + reloaded"*"WARNING: no CE db placed"*) ok "$t $cut cut: the GRANT line says ce=no and the no-CE WARNING fires" ;; *) no "$t $cut cut: ce=no / no-CE WARNING missing -- $L" ;; esac
    [ -f "$TT/state/.had_account" ] && ok "$t $cut cut: .had_account is present" || no "$t $cut cut: .had_account is absent"
    [ "$(cat "$TT/system_de/10/accounts_de.db" 2>/dev/null)" = NEWDE ] && ok "$t $cut cut: the DE db is still placed" || no "$t $cut cut: the DE db is not placed"
    [ "$(cnt '^cmd account reload-user 10')" = 1 ] && ok "$t $cut cut: reload-user ran once" || no "$t $cut cut: reload-user did not run once"
    [ ! -e "$TT/nowhere/acct-hold-10" ] && ok "$t $cut cut: the hold is gone" || no "$t $cut cut: the hold is left"; done_
  done
  run ok "" "$STALE" "$(mkhold "$CE; $DE"; echo 'acct_reload 10')"
  L=$(log)
  [ "$(cat "$TT/system_ce/10/accounts_ce.db" 2>/dev/null)" = NEWCE ] && ok "$t whole copy: the CE db is placed" || no "$t whole copy: the CE db is not placed"
  [ "$(cat "$TT/system_ce/10/accounts_ce.db-wal" 2>/dev/null)" = NEWCEWAL ] && ok "$t whole copy: the CE -wal is placed" || no "$t whole copy: the CE -wal is not placed"
  case "$L" in *"copied short"*) no "$t whole copy: a copied-short line was logged" ;; *) ok "$t whole copy: no copied-short line" ;; esac
  case "$L" in *"placed ce=yes de=yes + reloaded"*) ok "$t whole copy: logs ce=yes de=yes" ;; *) no "$t whole copy: ce=yes de=yes missing -- $L" ;; esac; done_
done
RSH=bash

echo "== NWP-20261104-05: acct_restore voids an earlier session's account marks, in every shell =="
MARKS='$T/user/10/com.nowhere.chooser/files/nowhere-acct-marks'
SEEDMARKS='mkdir -p "$T/user/10/com.nowhere.chooser/files"; printf "h1\nh2\n" > '"$MARKS"
VOID='#sys: voided 2 account mark(s) left from an earlier session (dn-1025 #2)'
for RSH in "${SHELLS[@]}"; do
  t="[$(basename "$RSH")]"
  run fail "$CE" "$SEEDMARKS" 'acct_restore 10; echo "rc=$?"'
  [ ! -e "$TT/user/10/com.nowhere.chooser/files/nowhere-acct-marks" ] && ok "$t the agent fails: the marks file is gone" || no "$t the agent fails: the marks file survived"
  case "$(log)" in *"$VOID"*) ok "$t the void line counts the 2 marks" ;; *) no "$t the void line is missing -- $(log)" ;; esac
  case "$(log)$(out)" in *h1*|*h2*) no "$t a mark hash reached the log or the output" ;; *) ok "$t no mark hash in the log" ;; esac; done_

  run ok "$DE" "$SEEDMARKS" 'acct_restore 10; echo "rc=$?"'
  [ ! -e "$TT/user/10/com.nowhere.chooser/files/nowhere-acct-marks" ] && ok "$t a hold with no CE half: the marks file is gone" || no "$t a hold with no CE half: the marks file survived"; done_

  run ok "$CE" "$SEEDMARKS" 'acct_restore 10'
  [ ! -e "$TT/user/10/com.nowhere.chooser/files/nowhere-acct-marks" ] && ok "$t a CE hold: the marks file is gone" || no "$t a CE hold: the marks file survived"; done_

  run ok "$CE" "" 'acct_restore 10'
  case "$(log)" in *voided*) no "$t no marks file: a void line was logged" ;; *) ok "$t no marks file: no void line" ;; esac; done_

  run ok '[ -e "'"$MARKS"'" ] && echo present > "$T/seen" || echo absent > "$T/seen"' "$SEEDMARKS" 'acct_restore 10'
  [ "$(cat "$TT/seen" 2>/dev/null)" = absent ] && ok "$t the void runs before the agent restore" || no "$t the marks file was still there when the agent restore ran"; done_

  run ok "" "" 'acct_mark_file 10; echo "rc=$?"; acct_mark_file 0; echo "rc0=$?"; acct_mark_file ""; echo "rcE=$?"; acct_mark_file 1x; echo "rcX=$?"'
  want=$(printf '%s/user/10/com.nowhere.chooser/files/nowhere-acct-marks\nrc=0\nrc0=1\nrcE=1\nrcX=1' "$TT")
  [ "$(out)" = "$want" ] && ok "$t acct_mark_file: user 10's path; nothing for user 0, empty or non-numeric" || no "$t acct_mark_file printed [$(out)]"; done_
done
RSH=bash

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$W")
  mutate(){
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $1"; return; fi
    local o; o=$(ACCT_WANT="${3:-13}" bash "$0" "$M/m.sh" 2>&1); local rc=$?
    if [ "$rc" = 0 ]; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    elif [ "$rc" = 2 ]; then no "MUTATION BROKE EXTRACTION: $1 -- $o"
    else ok "convicted: $1 (case: $(printf '%s\n' "$o" | grep -m1 FAIL | sed 's/^ *FAIL  //'))"; fi
  }
  mutate "the stale -wal/-shm rm is dropped (CE and DE)" \
         '/^    rm -f "\/data\/system_\(ce\|de\)\/\$uid\/accounts_\(ce\|de\)\.db-wal"/d' 11
  mutate "reload-user runs before the copy (the detach-user line becomes a reload-user)" \
         's#^  cmd account detach-user "\$uid"#  cmd account reload-user "$uid"#'
  mutate "the final hold rm is dropped" \
         's#^  rm -rf "\$hold"$#  :#'
  mutate "the agent-failure cleanup is dropped" \
         's#|| { rm -rf "\$hold"; return 0; }#|| { return 0; }#'
  # NWP-20261118-09: a whole-copy mutant must fail the cases of EVERY shell found. Third argument: ACCT_WANT.
  mutate_all(){
    local o sh t
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $1"; return; fi
    o=$(ACCT_WANT="${3:-13}" bash "$0" "$M/m.sh" 2>&1)
    case "$o" in *"EXTRACTION FAILED"*) no "MUTATION BROKE EXTRACTION: $1"; return ;; esac
    for sh in "${SHELLS[@]}"; do
      t="[$(basename "$sh")]"
      case "$o" in *"  FAIL  $t "*) ok "convicted under $t: $1" ;; *) no "NOT CONVICTED under $t: $1" ;; esac
    done
  }
  mutate_all "the whole-copy check is deleted (P1 leaves the torn db)" \
         '/^    for _acf in "\$hold"\/ce\/accounts_ce\.db\*; do$/,/^    done$/d' 11
  mutate_all "the rm -f of the torn files is deleted (P1 leaves the torn db)" \
         '/^      rm -f "\/data\/system_ce\/\$uid\/"accounts_ce\.db\* 2>>"\$LOG"$/d' 12
  mutate_all "the -wal leg is removed (P2 leaves the torn -wal)" \
         's#^    for _acf in "\$hold"/ce/accounts_ce\.db\*; do$#    for _acf in "$hold"/ce/accounts_ce.db; do#'
  mutate_all "the size comparison is inverted (P3 removes a whole db)" \
         's#\[ "\$_acs" = "\$(stat#[ "$_acs" != "$(stat#'
  # The void moved after the agent restore: it must fail the failing-agent case under EVERY shell found.
  sed '/^  if mf=\$(acct_mark_file "\$uid")/,/^  fi$/{H;d};/NOWHERE_PHASE=accounts "\$AGENT" restore s3/G' "$SUT" > "$M/m.sh"
  if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: the void moved after the agent restore"
  else
    o=$(bash "$0" "$M/m.sh" 2>&1)
    for sh in "${SHELLS[@]}"; do
      t="[$(basename "$sh")]"
      case "$o" in
        *"  FAIL  $t the agent fails: the marks file survived"*) ok "convicted under $t: the void moved after the agent restore" ;;
        *) no "NOT CONVICTED under $t: the void moved after the agent restore" ;;
      esac
    done
  fi
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
