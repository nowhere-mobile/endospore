#!/usr/bin/env bash
# test-od-copy-errors.sh [<nowhere_roamd.sh>] [--mutate] -- the on-demand hold and hand-back log a failed copy's
# error COUNT and errno text, never the app file names toybox cp/rm put in every error line (NWP-20261109-09).
#
# WHY THIS IS COMMITTED. hold_ondemand's two merges (CE/DE and external) and the odrestore arm's hand-back copy the
# app's private data with `cp -a`, and used to send cp's and rm's stderr straight to roam.log. toybox prints one line
# per failing FILE -- `cp: '<dir>/files/Logs/<name>': Permission denied`, 300 of them on a full volume -- and the
# scrub that runs across the reap and the boot redacts double-quoted tokens only, so those single-quoted file names
# outlived the session and reached an issue report filed in a later profile's session. Q001 (e), DECIDED 2026-10-20:
# the file name inside the app must not outlive the session; package names may. reap_userdir_take already drops rm's
# stderr for the same reason. Nothing else pinned it: test-od-hold-merge.sh stubs a failing cp that prints nothing.
#
# So this suite EXECUTES the real extracted hold_ondemand and odrestore arm, under every shell found (the device's
# is mksh), against a stub cp that fails the way toybox does -- two lines naming a file with a space in its name --
# and asserts what reached roam.log and what the trees still hold:
#   C1 CE/DE merge fails   C2 external merge fails   C3 odrestore hand-back fails   C4 a clean copy whose rm
#   leaves the source (all three sites)   C5 an error line with no usable errno text logs `last: error`
#   C6 a clean merge logs exactly today's lines and nothing new
#
#   bash test-od-copy-errors.sh              # the cases, under every shell found
#   bash test-od-copy-errors.sh --mutate     # ... plus mutants of roamd that must each CONVICT under each shell
#
# Pure logic -- no device. The functions are EXTRACTED by anchor and re-rooted to a temp tree; every helper is a stub.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every case root, driver and mutant copy is made inside W, so a run that passes, fails or convicts leaves nothing.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=(); seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$s")
done
[ "${#SHELLS[@]}" -gt 0 ] || { echo "no shell found" >&2; exit 2; }
echo "shells: ${SHELLS[*]}"

PKG=com.whatsapp
UID_=15
OD_UID=$UID_
OD_PKG=com.example.game
OD_APPID=10234
OD_OWNED=$((OD_UID * 100000 + OD_APPID))
SUF2='(2 error line(s), last: Permission denied)'

anchor_of() { awk -v a="$2" 'index($0, a) == 1 {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" p=0 x=0 FN FNR PKGOK ODH ARM ARMR n sh HARN=""
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); say "  FAIL  $l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  has() { grep -qxF -- "$2" "$1"; }                       # has <file> <whole line>
  hasnt() { ! grep -qF -- "$2" "$1"; }                    # hasnt <file> <substring>
  nosecret() { ! grep -qE 'secret|/files/Logs' "$1"; }    # no file name, no path inside the app, in <file>
  nlines() { grep -cF -- "$2" "$1"; }                     # nlines <file> <substring>

  FN=$(anchor_of "$f" 'hold_ondemand() {')
  ODH=$(grep -m1 -E '^ODHOLD=' "$f")
  PKGOK=$(anchor_of "$f" 'pkgname_ok() {')
  ARM=$(arm_of "$f" odrestore)
  case "$FN" in *'nowhere-appkeep'*'$ODHOLD'*) ;; *) echo "EXTRACTION FAILED: hold_ondemand in $f" >&2; return 2 ;; esac
  [ -n "$ODH" ] || { echo "EXTRACTION FAILED: ODHOLD= not found in $f" >&2; return 2; }
  case "$PKGOK" in *'return 1'*'return 0'*) ;; *) echo "EXTRACTION FAILED: pkgname_ok in $f" >&2; return 2 ;; esac
  case "$ARM" in *'echo "ERR-PKG" > "$RES"'*'echo "OK NOSRC" > "$RES"'*'echo "ERR-NOTREADY" > "$RES"'*) ;; *) echo "EXTRACTION FAILED: the odrestore arm in $f" >&2; return 2 ;; esac
  FNR=$(printf '%s\n' "$FN" | sed 's#"/data/#"$ROOT/data/#g')
  n=$(printf '%s\n' "$FNR" | grep -c '"\$ROOT/data/')
  [ "$n" -ge 3 ] || { echo "RE-ROOT FAILED: hold_ondemand has $n rewritten paths, want >= 3" >&2; return 2; }
  n=$(nleft "$FNR")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: hold_ondemand keeps $n absolute /data path(s) in live code" >&2; return 2; }
  ARMR=$(printf '%s\n' "$ARM" | sed -E 's#([" |])/data/#\1$ROOT/data/#g')
  n=$(printf '%s\n' "$ARMR" | grep -o '\$ROOT/data/' | grep -c .)
  [ "$n" -ge 8 ] || { echo "RE-ROOT FAILED: the odrestore arm has $n rewritten paths, want >= 8" >&2; return 2; }
  n=$(nleft "$ARMR")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: the odrestore arm keeps $n absolute /data path(s) in live code" >&2; return 2; }
  eval "$ODH"

  mkroot() {
    R=$(mktemp -d -p "$W") || exit 2
    mkdir -p "$R/sim" "$R/state" "$R/data/system" "$R/data/nowhere" "$R/data/user/$UID_" "$R/data/user_de/$UID_" \
             "$R/data/media/$UID_/Android/data" "$R/data/media/$UID_/Android/obb" "$R/data/user/$OD_UID"
    : > "$R/sim/owners"
    echo "$OD_PKG $OD_APPID 0 /data/user/0/$OD_PKG default:targetSdkVersion=34 none 0 1 1234" > "$R/data/system/packages.list"
    mkdir -p "$R/data/user/$UID_/com.nowhere.chooser/files"
    printf '%s\tondemand\n' "$PKG" > "$R/data/user/$UID_/com.nowhere.chooser/files/nowhere-appkeep"
  }
  # modes: cp = ok|fail|fail-nocolon|fail-path|fail-long|fail-quote  rm = ok|leave
  setmodes() { printf '%s\n' "$1" > "$R/sim/cp"; printf '%s\n' "$2" > "$R/sim/rm"; }
  # driver <root> <kind>: stubs + the extracted text, written to a FILE so the shell under test parses it
  driver() {
    local d="$1/driver.sh"
    {
      printf "ROOT='%s'\nLOG='%s'\nRES='%s'\nuid=%s\n" "$1" "$1/roam.log" "$1/res" "$UID_"
      printf "USERDIR='%s'\nop=odrestore\nsrcunit=%s\nSTATE='%s'\nACCT_AUTH_PKG=com.example.authenticator\n" \
             "$1/data/user/$OD_UID" "$OD_PKG" "$1/state"
      cat <<'EOF'
date() { echo DATE; }
restorecon() { :; }
am() { return 0; }
pidof() { :; }
pkg_live_pids() { :; }
reown_restored() { :; }
od_relabel() { :; }
cutoff_prog() { :; }
od_watched() { shift; "$@" 2>&1; }
grant_perms_for() { :; }
keystore_register() { :; }
# pm: an app with code -- `list packages -U ... <pkg>` lists the package's own line (the arm's NWP-20261122-03 read)
# ... and hold_ondemand's two listings name none of this suite's packages (NWP-20261129-27).
pm() { case "$*" in "list packages -U "*) echo "package:$srcunit uid:1110234" ;; "list packages -s -u") echo package:android ;; esac; return 0; }
timeout() { while [ "${1:-}" = -k ]; do shift 2; done; shift; "$@"; }
reown_ext_appdata() { :; }
wait_acct_authenticator() { :; }
acct_reload() { :; }
sync_apply() { :; }
a11y_apply() { :; }
autofill_apply() { :; }
stat() { awk -v p="$3" '$1 == p {print $2; f=1} END{exit !f}' "$ROOT/sim/owners"; }
cp() {
  _m=$(cat "$ROOT/sim/cp" 2>/dev/null)
  _d=${3%/}
  case "$_m" in
    fail)
      echo "cp: '$_d/files/Logs/secret name.log': Permission denied" >&2
      echo "cp: '$_d/files/Logs/secret other.log': Permission denied" >&2
      return 1 ;;
    fail-nocolon) echo "cp failed on secret name" >&2; return 1 ;;
    fail-path) echo "cp: Permission denied: $_d/files/Logs/secret name.log" >&2; return 1 ;;
    fail-long) echo "cp: '$_d/f': aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >&2; return 1 ;;
    fail-quote) echo "cp: '$_d/files/a: secret'" >&2; return 1 ;;
    *) command cp "$@" ;;
  esac
}
rm() {
  _m=$(cat "$ROOT/sim/rm" 2>/dev/null)
  case "$_m" in
    leave) echo "rm: '$2/files/Logs/secret name.log': Permission denied" >&2; return 1 ;;
    *) command rm "$@" ;;
  esac
}
EOF
      printf '%s\n' "$ODH"
      if [ "$2" = hold ]; then
        printf '%s\n%s\nhold_ondemand "$uid"\n' "$PKGOK" "$FNR"
      else
        printf '%s\ncase "$op" in\n%s\nesac\n' "$PKGOK" "$ARMR"
      fi
    } > "$d"
  }
  run() {  # run <sh> <root> <hold|od>
    driver "$2" "$3"
    "$1" "$2/driver.sh" >/dev/null 2>"$2/sim/stderr"
    local e
    e=$(grep -m1 -E 'command not found|unbound variable|syntax error|bad substitution|not found' "$2/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$1: $e]"
  }
  val() { [ -f "$1" ] && cat "$1" || echo -; }
  CEH="data/user/$UID_/com.nowhere.chooser/.nowhere-odhold/$PKG"
  XH="data/media/$UID_/Android/data/com.nowhere.chooser/.nowhere-odhold/$PKG"
  plant() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }
  # the three lines a clean merge logs today, and the suffix-bearing / new ones, built once
  W_CE="[roamd] WARN on-demand $PKG (ROOT/data/user/$UID_) merge into existing hold FAILED -- canonical LEFT IN PLACE, nothing dropped (NWP-20260922-09) DATE"
  W_XT="[roamd] WARN on-demand $PKG (ROOT/data/media/$UID_/Android/data) ext merge FAILED -- canonical LEFT IN PLACE, nothing dropped (NWP-20260922-09) DATE"
  W_OD="[roamd] WARN odrestore $OD_PKG (ROOT/data/user/$OD_UID) cp FAILED -- hold KEPT, NOT counted as restored (NWP-20260922-09) DATE"
  RM_CE="[roamd] WARN on-demand $PKG (ROOT/data/user/$UID_) could not remove all of the canonical after the merge -- the rest is left in place (NWP-20261109-09) DATE"
  RM_XT="[roamd] WARN on-demand $PKG (ROOT/data/media/$UID_/Android/data) could not remove all of the canonical after the merge -- the rest is left in place (NWP-20261109-09) DATE"
  RM_OD="[roamd] WARN odrestore $OD_PKG (ROOT/data/user/$OD_UID) could not remove all of the hold after the merge -- the rest is left in place (NWP-20261109-09) DATE"
  M_CE="[roamd] on-demand $PKG (ROOT/data/user/$UID_) merged canonical into existing hold, newest wins (NWP-20260922-09) DATE"
  M_XT="[roamd] on-demand $PKG (ROOT/data/media/$UID_/Android/data) merged canonical into existing ext hold, newest wins (NWP-20260922-09) DATE"
  M_OD="[roamd] odrestore $OD_PKG (ROOT/data/user/$OD_UID) restored+reowned DATE"
  F_OD="[roamd] odrestore $OD_PKG -> force-stopped pre-restore, rc=0 (gap process; hold exists) DATE"
  K_OD="[roamd] odrestore $OD_PKG -> hold(s) kept on 1 volume(s) -- ERR-NOTREADY so the next sweep or tap retries the restore (NWP-20260922-09, NWP-20261013-22) DATE"
  exp() { printf '%s' "${1//ROOT/$R}"; }                 # exp <line with ROOT> -> the line for this case's root

  for sh in "${SHELLS[@]}"; do
    L="[$sh]"
    say "== $sh C1: the CE/DE merge fails -> count and errno only, nothing dropped =="
    mkroot; setmodes fail ok
    plant "$R/$CEH/databases/msgstore.db" OLD; plant "$R/data/user/$UID_/$PKG/databases/msgstore.db" NEW
    run "$sh" "$R" hold
    chk "$L C1 the FAILED line ends with the suffix" has "$R/roam.log" "$(exp "$W_CE") $SUF2"
    chk "$L C1 no file name or in-app path in roam.log" nosecret "$R/roam.log"
    chk "$L C1 canonical untouched" eqv "$(val "$R/data/user/$UID_/$PKG/databases/msgstore.db")" NEW
    chk "$L C1 hold untouched" eqv "$(val "$R/$CEH/databases/msgstore.db")" OLD

    say "== $sh C2: the external merge fails -> the same =="
    mkroot; setmodes fail ok
    plant "$R/$XH/files/a.bin" OLD; plant "$R/data/media/$UID_/Android/data/$PKG/files/a.bin" NEW
    run "$sh" "$R" hold
    chk "$L C2 the ext FAILED line ends with the suffix" has "$R/roam.log" "$(exp "$W_XT") $SUF2"
    chk "$L C2 no file name or in-app path in roam.log" nosecret "$R/roam.log"
    chk "$L C2 canonical untouched" eqv "$(val "$R/data/media/$UID_/Android/data/$PKG/files/a.bin")" NEW
    chk "$L C2 hold untouched" eqv "$(val "$R/$XH/files/a.bin")" OLD

    say "== $sh C3: the odrestore hand-back fails -> the cp-FAILED line carries the suffix =="
    mkroot; setmodes fail ok
    H="$R/data/user/$OD_UID/com.nowhere.chooser/.nowhere-odhold/$OD_PKG"
    plant "$H/f.txt" payload; mkdir -p "$R/data/user/$OD_UID/$OD_PKG"
    echo "$R/data/user/$OD_UID/$OD_PKG $OD_OWNED" > "$R/sim/owners"
    run "$sh" "$R" od
    chk "$L C3 the cp FAILED line ends with the suffix" has "$R/roam.log" "$(exp "$W_OD") $SUF2"
    chk "$L C3 no file name or in-app path in roam.log" nosecret "$R/roam.log"
    chk "$L C3 the reply is ERR-NOTREADY" eqv "$(cat "$R/res" 2>/dev/null)" ERR-NOTREADY
    chk "$L C3 the hold is kept" eqv "$(val "$H/f.txt")" payload

    say "== $sh C4: a clean copy whose rm leaves the source -> the could-not-remove line, no path =="
    mkroot; setmodes ok leave
    plant "$R/$CEH/databases/msgstore.db" OLD; plant "$R/data/user/$UID_/$PKG/databases/msgstore.db" NEW
    run "$sh" "$R" hold
    chk "$L C4 CE/DE: the could-not-remove line, once" eqv "$(grep -cxF -- "$(exp "$RM_CE")" "$R/roam.log")" 1
    chk "$L C4 CE/DE: no file name or in-app path" nosecret "$R/roam.log"
    chk "$L C4 CE/DE: the merged line is still logged" has "$R/roam.log" "$(exp "$M_CE")"
    chk "$L C4 CE/DE: the merge landed in the hold" eqv "$(val "$R/$CEH/databases/msgstore.db")" NEW
    mkroot; setmodes ok leave
    plant "$R/$XH/files/a.bin" OLD; plant "$R/data/media/$UID_/Android/data/$PKG/files/a.bin" NEW
    run "$sh" "$R" hold
    chk "$L C4 ext: the could-not-remove line, once" eqv "$(grep -cxF -- "$(exp "$RM_XT")" "$R/roam.log")" 1
    chk "$L C4 ext: no file name or in-app path" nosecret "$R/roam.log"
    chk "$L C4 ext: the merged line is still logged" has "$R/roam.log" "$(exp "$M_XT")"
    mkroot; setmodes ok leave
    H="$R/data/user/$OD_UID/com.nowhere.chooser/.nowhere-odhold/$OD_PKG"
    plant "$H/f.txt" payload; mkdir -p "$R/data/user/$OD_UID/$OD_PKG"
    echo "$R/data/user/$OD_UID/$OD_PKG $OD_OWNED" > "$R/sim/owners"
    run "$sh" "$R" od
    chk "$L C4 odrestore: the could-not-remove line, once" eqv "$(grep -cxF -- "$(exp "$RM_OD")" "$R/roam.log")" 1
    chk "$L C4 odrestore: no file name or in-app path" nosecret "$R/roam.log"
    chk "$L C4 odrestore: restored+reowned is still logged" has "$R/roam.log" "$(exp "$M_OD")"
    chk "$L C4 odrestore: the reply is OK $OD_PKG" eqv "$(cat "$R/res" 2>/dev/null)" "OK $OD_PKG"
    chk "$L C4 odrestore: the data landed" eqv "$(val "$R/data/user/$OD_UID/$OD_PKG/f.txt")" payload

    say "== $sh C5: an error line with no usable errno text -> last: error =="
    for mode in fail-nocolon fail-path fail-long fail-quote; do
      mkroot; setmodes "$mode" ok
      plant "$R/$CEH/databases/msgstore.db" OLD; plant "$R/data/user/$UID_/$PKG/databases/msgstore.db" NEW
      run "$sh" "$R" hold
      chk "$L C5 $mode: last: error" has "$R/roam.log" "$(exp "$W_CE") (1 error line(s), last: error)"
      chk "$L C5 $mode: no file name or in-app path" nosecret "$R/roam.log"
    done

    say "== $sh C6: a clean merge -> today's lines byte for byte, nothing new =="
    mkroot; setmodes ok ok
    plant "$R/$CEH/databases/msgstore.db" OLD; plant "$R/data/user/$UID_/$PKG/databases/msgstore.db" NEW
    plant "$R/$XH/files/a.bin" OLD; plant "$R/data/media/$UID_/Android/data/$PKG/files/a.bin" NEW
    run "$sh" "$R" hold
    chk "$L C6 hold_ondemand: exactly the two merged lines" eqv "$(cat "$R/roam.log")" "$(exp "$M_CE")
$(exp "$M_XT")"
    chk "$L C6 hold_ondemand: both canonicals consumed" eqv "$([ -e "$R/data/user/$UID_/$PKG" ] || [ -e "$R/data/media/$UID_/Android/data/$PKG" ] && echo left || echo gone)" gone
    mkroot; setmodes ok ok
    H="$R/data/user/$OD_UID/com.nowhere.chooser/.nowhere-odhold/$OD_PKG"
    plant "$H/f.txt" payload; mkdir -p "$R/data/user/$OD_UID/$OD_PKG"
    echo "$R/data/user/$OD_UID/$OD_PKG $OD_OWNED" > "$R/sim/owners"
    run "$sh" "$R" od
    chk "$L C6 odrestore: exactly today's two lines" eqv "$(cat "$R/roam.log")" "$(exp "$F_OD")
$(exp "$M_OD")"
    chk "$L C6 odrestore: the reply is OK $OD_PKG" eqv "$(cat "$R/res" 2>/dev/null)" "OK $OD_PKG"
    chk "$L C6 odrestore: the hold is consumed" eqv "$([ -e "$H" ] && echo kept || echo gone)" gone
  done

  [ -z "$HARN" ] || { echo "HARNESS ERROR:$HARN" >&2; return 2; }
  say "$p passed, $x failed"
  [ "$x" = 0 ]
}

suite "$SUT"; rc=$?
[ "$rc" = 2 ] && exit 2
[ "$MUTATE" = yes ] || exit "$rc"

echo
echo "== mutations (each MUST be convicted under EACH shell's own line) =="
MF=0
mutate() {  # mutate <id> <label> <sed expr>
  local id="$1" label="$2" expr="$3" m out mrc nch s miss=""
  m=$(mktemp -p "$W") || exit 2
  if ! sed "$expr" "$SUT" > "$m" 2>/dev/null; then echo "  FAIL  MUTATION BROKEN (sed): $id $label"; MF=$((MF+1)); return; fi
  if cmp -s "$SUT" "$m"; then echo "  FAIL  MUTATION INERT (anchor never matched): $id $label"; MF=$((MF+1)); return; fi
  nch=$(diff "$SUT" "$m" | grep -c '^<')
  if [ "$nch" != 1 ]; then echo "  FAIL  MUTATION TOUCHES $nch lines, want 1: $id $label"; MF=$((MF+1)); return; fi
  out=$(suite "$m"); mrc=$?
  if [ "$mrc" = 2 ]; then echo "  FAIL  INCONCLUSIVE (the harness could not run): $id $label"; MF=$((MF+1)); rm -f "$m"; return; fi
  if [ "$mrc" = 0 ]; then echo "  FAIL  NOT CONVICTED: $id $label"; MF=$((MF+1)); rm -f "$m"; return; fi
  for s in "${SHELLS[@]}"; do
    case "$out" in *"FAIL  [$s] "*) ;; *) miss="$miss $s" ;; esac
  done
  if [ -n "$miss" ]; then echo "  FAIL  NOT CONVICTED under:$miss: $id $label"; MF=$((MF+1)); else echo "  ok    convicted: $id $label"; fi
  rm -f "$m"
}
CE_A='/pre-existing hazard, but this script/'
XT_A='/collapses essential media and trips/'
OD_A='/stays honest so the reply below can refuse/'
CPNEW='if _ce=\$(cp -a "\$src"/\. "\$dst"/ 2>&1); then'
CPOLD='if cp -a "$src"/. "$dst"/ 2>>"$LOG"; then'
# odrestore's plain copy runs only when od_served_copy did not take the volume (NWP-20261121-02), so its line differs.
CPNEW_OD='{ _ce=\$(od_watched "\$dst" cp -a "\$src"/\. "\$dst"/); _odsc=\$?; }'
CPOLD_OD='{ cp -a "$src"/. "$dst"/ 2>>"$LOG"; _odsc=$?; }'
RMNEW='rm -rf "\$src" 2>/dev/null'
RMOLD='rm -rf "$src" 2>>"$LOG"'
CPEND='/_ce=\$(cp -a/'
RMEND='/rm -rf "\$src" 2>\/dev\/null/'
mutate E1 "the CE/DE cp's stderr goes back to roam.log" "$CE_A,${CPEND}s#${CPNEW}#${CPOLD}#"
mutate E2 "the external cp's stderr goes back to roam.log" "$XT_A,${CPEND}s#${CPNEW}#${CPOLD}#"
mutate E3 "the odrestore cp's stderr goes back to roam.log" "$OD_A,${CPEND}s#${CPNEW_OD}#${CPOLD_OD}#"
mutate E4a "the CE/DE rm's stderr goes back to roam.log" "$CE_A,${RMEND}s#${RMNEW}#${RMOLD}#"
mutate E4b "the external rm's stderr goes back to roam.log" "$XT_A,${RMEND}s#${RMNEW}#${RMOLD}#"
mutate E4c "the odrestore rm's stderr goes back to roam.log" "$OD_A,${RMEND}s#${RMNEW}#${RMOLD}#"
for site in "a:$CE_A" "b:$XT_A" "c:$OD_A"; do
  mutate "E5${site%%:*}" "the errno text keeps the whole line (site ${site%%:*})" \
         "${site#*:},/_cl=\${_cl##/s|_cl=\${_cl##\*: }|_cl=\$_cl|"
done
for site in "a:$CE_A" "b:$XT_A" "c:$OD_A"; do
  mutate "E6${site%%:*}" "the could-not-remove check is dropped (site ${site%%:*})" \
         "${site#*:},/could not remove all of the/{/could not remove all of the/d;}"
done

echo
echo "mutants failed: $MF"
[ "$rc" = 0 ] && [ "$MF" = 0 ]
