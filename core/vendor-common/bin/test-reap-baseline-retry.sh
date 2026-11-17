#!/usr/bin/env bash
# test-reap-baseline-retry.sh [<nowhere_roamd.sh>] [--mutate] [--baseline] -- roamd's gate-baseline retry:
# base_retry_add, base_retry_run, the cleanstorage block that queues a uid, the top-level hook and the bootsweep call
# (NWP-20261203-02, the §B row "Sign-out can restart the phone's system server ...").
#
# WHY. On lynx 2026111001 (device proof S4/S5) system_server died at the sign-out reap. roamd's reap ran while the
# framework was down: loc_release, md_release and hs_release logged `baseline NOT RESTORED` and `ERR-HS noreply`, kept
# their owner records, and nothing ran those releases for that uid again. Now the reap queues the uid
# ($STATE/base-pending), and the next read-write-lane op and the boot sweep run the five releases again, once
# sys.boot_completed is 1 and `service check settings` reports the service found, never for a uid whose user has a
# record again, at most three times.
#
# The functions are EXTRACTED from nowhere_roamd.sh by their `<fn>() {` anchor to their closing `}`, re-rooted to a
# temp tree, and run under every shell the runner has (bash, sh, dash, mksh; BASERETRY_SHELLS=<paths> restricts the
# list). The cleanstorage block (the lines between the reap's hs_release line and its stop_mediad line), the top-level
# hook (the line after the reap_retry_run hook) and the bootsweep head (from `_swept=""` to fix 4) are taken from the
# file BY ANCHOR and executed as written. A moved anchor exits 2. The five releases, getprop and `service` are stubs:
# each release appends `<name> <uid> <why>` to $ROOT/calls and sets its verdict from $ROOT/v.<name> (absent: the
# success value). userdir_has_record is the real one, re-rooted: a user is on record when $ROOT/data/system/users/<n>.xml
# exists.
#
# --baseline lets the run continue when a new anchor is missing (origin/main's file): no-op stand-ins take the place of
# the new code, so every new behavioural assertion fails by behaviour, not by exit 2.
#
#   bash test-reap-baseline-retry.sh               # the checks
#   bash test-reap-baseline-retry.sh --mutate      # ... plus mutants that must each CONVICT the suite under each shell
set -uo pipefail

MUTATE=no; BASE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; --baseline) BASE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
missing(){ if [ "$BASE" = yes ]; then echo "  (baseline: $1 -- a no-op stands in)"; else echo "EXTRACTION FAILED: $1 in $SUT" >&2; exit 2; fi; }

SHELLS=()
if [ -n "${BASERETRY_SHELLS:-}" ]; then
  read -r -a SHELLS <<< "$BASERETRY_SHELLS"
else
  seen=" "
  for s in bash sh dash mksh; do
    p=$(command -v "$s" 2>/dev/null) || continue
    r="$(readlink -f "$p"):$s"   # sh stays apart from bash: bash run as sh is its POSIX mode
    case "$seen" in *" $r "*) continue ;; esac
    seen="$seen$r "; SHELLS+=("$p")
  done
fi

# --- extraction --------------------------------------------------------------------------------------------------
fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
reroot() { printf '%s\n' "$1" | sed -E 's#([" ])/data/#\1$ROOT/data/#g'; }

FUNCS=$(fn_of "$SUT" userdir_has_record)
[ -n "$FUNCS" ] || { echo "EXTRACTION FAILED: function userdir_has_record not found in $SUT" >&2; exit 2; }
FUNCS="$FUNCS"$'\n'
t=$(grep -m1 '^loc_why() { .*; }$' "$SUT")   # a one-line function
[ -n "$t" ] || { echo "EXTRACTION FAILED: function loc_why not found in $SUT" >&2; exit 2; }
FUNCS="$FUNCS$t"$'\n'
for fn in base_retry_add base_retry_run; do
  t=$(fn_of "$SUT" "$fn")
  if [ -z "$t" ]; then
    missing "function $fn"
    case "$fn" in base_retry_add) t='base_retry_add() { :; }' ;; *) t='base_retry_run() { BASE_CLEARED=; BASE_LEFT=; }' ;; esac
  fi
  FUNCS="$FUNCS$t"$'\n'
done
printf '%s\n' "$(reroot "$FUNCS")" > "$W/funcs.sh"

# The cleanstorage block: from the line after the reap's hs_release line to the line before its stop_mediad line.
HS_A='  hs_release "$uid" reap   #'
SM_A='  stop_mediad reap "$uid"   #'
n=$(awk -v h="$HS_A" -v s="$SM_A" '/^if \[ "\$op" = "cleanstorage" \]; then$/ {c=1} c && index($0, h) == 1 {a++} c && index($0, s) == 1 {b++} c && /^fi$/ {exit} END {print a + 0 "," b + 0}' "$SUT")
[ "$n" = 1,1 ] || { echo "EXTRACTION FAILED: the cleanstorage hs_release / stop_mediad anchors ($n) in $SUT" >&2; exit 2; }
BLK=$(awk -v h="$HS_A" -v s="$SM_A" '/^if \[ "\$op" = "cleanstorage" \]; then$/ {c=1} c && index($0, s) == 1 {exit} p {print} c && index($0, h) == 1 {p=1}' "$SUT")
case "$BLK" in *'base_retry_add "$uid"'*) ;; *) missing "the cleanstorage block's base_retry_add \"\$uid\""; BLK=: ;; esac
printf '%s\n' "$BLK" > "$W/blk.sh"

# The top-level hook: the line after the reap_retry_run hook.
RR_A='[ "$LANE" = rw ] && reap_retry_run'
[ "$(grep -cxF -e "$RR_A" "$SUT")" = 1 ] || { echo "EXTRACTION FAILED: the top-level reap_retry_run hook in $SUT" >&2; exit 2; }
HOOK=$(awk -v a="$RR_A" 'p {print; exit} $0 == a {p=1}' "$SUT")
case "$HOOK" in *base_retry_run*) ;; *) missing "the top-level base_retry_run hook"; HOOK=: ;; esac

# The bootsweep head: from `_swept=""` to the line before fix 4.
OPB=$(sed -n '/^if \[ "\$op" = "bootsweep" \]; then$/,/^fi$/p' "$SUT")
[ -n "$OPB" ] || { echo "EXTRACTION FAILED: the bootsweep op in $SUT" >&2; exit 2; }
HEAD=$(printf '%s\n' "$OPB" | awk 'NR == 2 && $0 != "  _swept=\"\"" {exit} NR >= 2 && /^  # --- fix 4:/ {f=1; exit} NR >= 2 {print} END {if (!f) print "NOFIX4"}')
case "$HEAD" in *NOFIX4*|'') echo "EXTRACTION FAILED: the bootsweep head (_swept=\"\" ... # --- fix 4) in $SUT" >&2; exit 2 ;; esac
case "$HEAD" in *base_retry_run*) ;; *) missing "the bootsweep base_retry_run call" ;; esac
printf '%s\n' "$HEAD" > "$W/head.sh"

# --- the harness -------------------------------------------------------------------------------------------------
# newcase: a fake root with user 0 on record and the tmpfs $STATE.
newcase() { local c; c=$(mktemp -d -p "$W") || return 1
  mkdir -p "$c/state" "$c/data/system/users"; : > "$c/data/system/users/0.xml"; printf '%s\n' "$c"; }
# run <sh> <case> <own uid> <body>: the body over the extracted functions and the stubs; stdout to out, stderr to err.
run() { local sh="$1" c="$2" own="$3" body="$4"
  { printf "set -u; umask 022; ROOT='%s'; STATE=\"\$ROOT/state\"; LOG=\"\$ROOT/roam.log\"; uid='%s'\n" "$c" "$own"
    cat <<'EOS'
rel_stub() {   # rel_stub <name> <uid> <why> <default verdict>
  echo "$1 $2 $3" >> "$ROOT/calls"
  if [ -f "$ROOT/v.$1" ]; then RV=$(cat "$ROOT/v.$1"); else RV="$4"; fi
}
loc_release() { rel_stub loc "$1" "$2" "OK BASELINE"; LOC_VERDICT="$RV"; }
md_release() { rel_stub md "$1" "$2" "OK BASELINE mobile_data=1"; MD_VERDICT="$RV"; }
dt_release() { rel_stub dt "$1" "$2" "OK RESTORED 1"; DT_VERDICT="$RV"; }
dr_release() { rel_stub dr "$1" "$2" "BASELINE"; DR_VERDICT="$RV"; }
hs_release() { rel_stub hs "$1" "$2" "OK RELEASED"; HS_VERDICT="$RV"; }
getprop() { [ "$1" = sys.boot_completed ] && [ -f "$ROOT/bc" ] && cat "$ROOT/bc"; return 0; }
service() { if [ -f "$ROOT/svc" ]; then cat "$ROOT/svc"; else echo "Service settings: found"; fi; }
EOS
    printf '. %s/funcs.sh\n%s\n' "$W" "$body"
  } > "$c/run.sh"
  "$sh" ${RUN_OPT:-} "$c/run.sh" >> "$c/out" 2>> "$c/err"
}
# harn <case>: the run hit no undefined command, unbound variable or parse error.
harn() { local e; e=$(grep -m1 -iE 'command not found|: (inaccessible or )?not found|unbound variable|parameter not set|syntax error|bad substitution' "$1/err" 2>/dev/null); [ -z "$e" ]; }
lines() { if [ -f "$1" ]; then grep -c '' "$1"; else echo 0; fi; }
list() { cat "$1/state/base-pending" 2>/dev/null; }
calls() { cat "$1/calls" 2>/dev/null; }
logof() { cat "$1/roam.log" 2>/dev/null; }
# up <case>: the framework is back (boot completed; the settings service answers by default).
up() { echo 1 > "$1/bc"; }
REAP='loc_release "$uid" reap; md_release "$uid" reap; dt_release "$uid" reap; dr_release "$uid" reap; hs_release "$uid" reap
. "'"$W"'/blk.sh"'
RUNB='base_retry_run retry; echo "BASE_CLEARED=$BASE_CLEARED BASE_LEFT=$BASE_LEFT" > "$ROOT/counts"'
FIVE_11='loc 11 retry
md 11 retry
dt 11 retry
dr 11 retry
hs 11 retry'

for sh in "${SHELLS[@]}"; do
  tag="[${sh##*/}]"

  # C1 a reap with one failed area queues the uid and says which area; two failed areas are named in order
  C=$(newcase); echo "ERR-HS noreply" > "$C/v.hs"
  run "$sh" "$C" 11 "$REAP"
  lg=$(logof "$C")
  [ "$(list "$C")" = "11 0" ] && ok "$tag C1 a reap whose hotspot release failed queues '11 0'" || no "$tag C1 list '$(list "$C")'"
  [[ "$lg" == *"reap user 11: gate baseline not restored (hs) -- queued for retry"* ]] && ok "$tag C1 roam.log names the area (hs)" || no "$tag C1 log '$lg'"
  harn "$C" && ok "$tag C1 clean stderr" || no "$tag C1 stderr: $(cat "$C/err")"
  C=$(newcase); echo "ERR-LOC ?,?" > "$C/v.loc"; echo "ERR-DR" > "$C/v.dr"
  run "$sh" "$C" 12 "$REAP"
  lg=$(logof "$C")
  [ "$(list "$C")" = "12 0" ] && [[ "$lg" == *"reap user 12: gate baseline not restored (loc dr) -- queued for retry"* ]] \
    && ok "$tag C1 two failed areas: queued, roam.log names (loc dr)" || no "$tag C1 two areas: list '$(list "$C")' log '$lg'"

  # C2 an all-OK reap queues nothing and logs nothing
  C=$(newcase)
  run "$sh" "$C" 11 "$REAP"
  [ ! -e "$C/state/base-pending" ] && [ ! -s "$C/roam.log" ] && ok "$tag C2 an all-OK reap queues nothing" || no "$tag C2 list '$(list "$C")' log '$(logof "$C")'"

  # C3 a reap where another session owns every setting (KEPT) queues nothing
  C=$(newcase); echo "OK KEPT" > "$C/v.loc"; echo "OK KEPT" > "$C/v.md"; echo "OK KEPT" > "$C/v.dt"; echo KEPT > "$C/v.dr"; echo "OK KEPT" > "$C/v.hs"
  run "$sh" "$C" 11 "$REAP"
  [ ! -e "$C/state/base-pending" ] && ok "$tag C3 a reap with KEPT on every area queues nothing" || no "$tag C3 list '$(list "$C")'"

  # C4 the add's rules: digits only, no leading 0, uid >= 10, no duplicate, newest 32
  C=$(newcase)
  run "$sh" "$C" "" 'base_retry_add 5; base_retry_add 010; base_retry_add 1a; base_retry_add ""'
  [ ! -e "$C/state/base-pending" ] && ok "$tag C4 uids 5, 010, 1a and empty are not queued" || no "$tag C4 bad uids: list '$(list "$C")'"
  run "$sh" "$C" "" 'base_retry_add 11; base_retry_add 11'
  [ "$(list "$C")" = "11 0" ] && ok "$tag C4 uid 11 added twice is listed once" || no "$tag C4 dedup: list '$(list "$C")'"
  C=$(newcase)
  run "$sh" "$C" "" 'i=10; while [ "$i" -le 42 ]; do base_retry_add "$i"; i=$((i + 1)); done'
  [ "$(lines "$C/state/base-pending")" = 32 ] && [ "$(head -n 1 "$C/state/base-pending" 2>/dev/null)" = "11 0" ] && [ "$(tail -n 1 "$C/state/base-pending" 2>/dev/null)" = "42 0" ] \
    && ok "$tag C4 33 adds keep the newest 32" || no "$tag C4 cap: $(lines "$C/state/base-pending") lines"

  # G1 sys.boot_completed unset: the list is unchanged and no release is called
  C=$(newcase); echo "11 0" > "$C/state/base-pending"; cp "$C/state/base-pending" "$C/before"
  run "$sh" "$C" "" "$RUNB"
  cmp -s "$C/before" "$C/state/base-pending" && [ ! -e "$C/calls" ] && ok "$tag G1 boot not completed: list unchanged, no release" || no "$tag G1 list '$(list "$C")' calls '$(calls "$C")'"
  [ "$(cat "$C/counts" 2>/dev/null)" = "BASE_CLEARED=0 BASE_LEFT=1" ] && ok "$tag G1 a closed gate reports 0/1" || no "$tag G1 counts '$(cat "$C/counts" 2>/dev/null)'"

  # G2 the settings service not found (its negative contains "found"), or no answer at all: unchanged, no release
  C=$(newcase); up "$C"; echo "11 0" > "$C/state/base-pending"; cp "$C/state/base-pending" "$C/before"; echo "Service settings: not found" > "$C/svc"
  run "$sh" "$C" "" "$RUNB"
  cmp -s "$C/before" "$C/state/base-pending" && [ ! -e "$C/calls" ] && ok "$tag G2 settings service not found: list unchanged, no release" || no "$tag G2 list '$(list "$C")' calls '$(calls "$C")'"
  C=$(newcase); up "$C"; echo "11 0" > "$C/state/base-pending"; cp "$C/state/base-pending" "$C/before"; : > "$C/svc"
  run "$sh" "$C" "" "$RUNB"
  cmp -s "$C/before" "$C/state/base-pending" && [ ! -e "$C/calls" ] && ok "$tag G2 no answer from service: list unchanged, no release" || no "$tag G2b list '$(list "$C")' calls '$(calls "$C")'"

  # G3 user 0's record unseen: unchanged, no release
  C=$(newcase); up "$C"; rm -f "$C/data/system/users/0.xml"; echo "11 0" > "$C/state/base-pending"; cp "$C/state/base-pending" "$C/before"
  run "$sh" "$C" "" "$RUNB"
  cmp -s "$C/before" "$C/state/base-pending" && [ ! -e "$C/calls" ] && ok "$tag G3 user 0 unseen: list unchanged, no release" || no "$tag G3 list '$(list "$C")' calls '$(calls "$C")'"

  # G4 no list: returns 0, both counts 0
  C=$(newcase); up "$C"
  run "$sh" "$C" "" "$RUNB"' ; echo "rc=$?" >> "$ROOT/counts"'
  [ "$(cat "$C/counts" 2>/dev/null)" = "BASE_CLEARED=0 BASE_LEFT=0
rc=0" ] && [ ! -e "$C/calls" ] && ok "$tag G4 no list: rc 0, counts 0/0, no release" || no "$tag G4 counts '$(cat "$C/counts" 2>/dev/null)'"
  harn "$C" && ok "$tag G4 clean stderr" || no "$tag G4 stderr: $(cat "$C/err")"

  # R1 the framework is back, all five releases succeed: called with uid 11 and why=retry, the uid dropped
  C=$(newcase); up "$C"; echo "11 0" > "$C/state/base-pending"
  run "$sh" "$C" "" "$RUNB"
  lg=$(logof "$C")
  [ "$(calls "$C")" = "$FIVE_11" ] && ok "$tag R1 the five releases run for 11 with why=retry, in the reap's order" || no "$tag R1 calls '$(calls "$C")'"
  [ ! -e "$C/state/base-pending" ] && [ ! -e "$C/state/base-pending.tmp" ] && ok "$tag R1 a restored uid is dropped (list gone)" || no "$tag R1 list '$(list "$C")'"
  [ "$(lines "$C/roam.log")" = 1 ] && [[ "$lg" == "[roamd] baseline retry user 11 (retry): restored tries=1 "* ]] && ok "$tag R1 roam.log: restored tries=1" || no "$tag R1 log '$lg'"
  [ "$(cat "$C/counts" 2>/dev/null)" = "BASE_CLEARED=1 BASE_LEFT=0" ] && ok "$tag R1 counts 1/0" || no "$tag R1 counts '$(cat "$C/counts" 2>/dev/null)'"
  harn "$C" && ok "$tag R1 clean stderr" || no "$tag R1 stderr: $(cat "$C/err")"

  # R2 mobile data still fails: kept at k+1
  C=$(newcase); up "$C"; echo "11 0" > "$C/state/base-pending"; echo "ERR-MD mobile_data=?" > "$C/v.md"
  run "$sh" "$C" "" "$RUNB"
  lg=$(logof "$C")
  [ "$(list "$C")" = "11 1" ] && ok "$tag R2 a failed retry keeps '11 1'" || no "$tag R2 list '$(list "$C")'"
  [[ "$lg" == *"baseline retry user 11 (retry): still not restored (md) tries=1 of 3"* ]] && ok "$tag R2 roam.log: still not restored (md) tries=1 of 3" || no "$tag R2 log '$lg'"
  [ "$(cat "$C/counts" 2>/dev/null)" = "BASE_CLEARED=0 BASE_LEFT=1" ] && ok "$tag R2 counts 0/1" || no "$tag R2 counts '$(cat "$C/counts" 2>/dev/null)'"

  # R3 the third failure (hotspot no reply) drops the uid with GAVE UP
  C=$(newcase); up "$C"; echo "11 2" > "$C/state/base-pending"; echo "ERR-HS noreply" > "$C/v.hs"
  run "$sh" "$C" "" "$RUNB"
  lg=$(logof "$C")
  [ ! -e "$C/state/base-pending" ] && ok "$tag R3 the third failure drops the uid" || no "$tag R3 list '$(list "$C")'"
  [[ "$lg" == *"baseline retry user 11 (retry): GAVE UP (hs) tries=3"* ]] && ok "$tag R3 roam.log: GAVE UP (hs) tries=3" || no "$tag R3 log '$lg'"

  # R4 the op's own uid is skipped, count unchanged, no release
  C=$(newcase); up "$C"; echo "11 1" > "$C/state/base-pending"
  run "$sh" "$C" 11 "$RUNB"
  [ "$(list "$C")" = "11 1" ] && [ ! -e "$C/calls" ] && ok "$tag R4 the op's own uid: skipped, '11 1' kept, no release" || no "$tag R4 list '$(list "$C")' calls '$(calls "$C")'"

  # R5 a uid whose user is on record again (a new session on a reused id) is skipped, count unchanged, no release
  C=$(newcase); up "$C"; echo "12 1" > "$C/state/base-pending"; : > "$C/data/system/users/12.xml.backup"
  run "$sh" "$C" "" "$RUNB"
  [ "$(list "$C")" = "12 1" ] && [ ! -e "$C/calls" ] && ok "$tag R5 a uid on record: skipped, '12 1' kept, no release" || no "$tag R5 list '$(list "$C")' calls '$(calls "$C")'"

  # R6 why=boot reaches every release
  C=$(newcase); up "$C"; echo "13 0" > "$C/state/base-pending"
  run "$sh" "$C" "" 'base_retry_run boot'
  [ "$(calls "$C")" = 'loc 13 boot
md 13 boot
dt 13 boot
dr 13 boot
hs 13 boot' ] && [[ "$(logof "$C")" == *"baseline retry user 13 (boot): restored tries=1"* ]] && ok "$tag R6 why=boot reaches all five releases and the log" || no "$tag R6 calls '$(calls "$C")' log '$(logof "$C")'"

  # R7 (test-reap-retry.sh's R1 shape): an unwritable .tmp (a directory with one entry): the list is kept byte for
  # byte and the function returns 0, under bash as --posix too.
  C=$(newcase); up "$C"; printf '12 0\n' > "$C/state/base-pending"; cp "$C/state/base-pending" "$C/before"; : > "$C/data/system/users/12.xml"
  mkdir "$C/state/base-pending.tmp"; : > "$C/state/base-pending.tmp/entry"
  o=; [ "${sh##*/}" = bash ] && o=--posix
  RUN_OPT=$o run "$sh" "$C" "" 'base_retry_run retry; echo "rc=$?" > "$ROOT/after"'
  chmod -R u+rwx "$C"
  [ "$(cat "$C/after" 2>/dev/null)" = rc=0 ] && ok "$tag R7 an unwritable .tmp: base_retry_run returns 0 and the next line runs" || no "$tag R7 after '$(cat "$C/after" 2>/dev/null)'"
  cmp -s "$C/before" "$C/state/base-pending" && ok "$tag R7 the pending list is kept byte for byte" || no "$tag R7 list '$(list "$C")'"
  [[ "$(logof "$C")" == *"baseline retry: the pending list could not be rewritten (- of 1 lines) -- kept unchanged"* ]] && ok "$tag R7 roam.log: could not be rewritten (- of 1 lines)" || no "$tag R7 log '$(logof "$C")'"

  # R8 a .tmp that takes no line (a symlink to /dev/full): the list stays a regular file with its bytes
  if [ -c /dev/full ] && [ -w /dev/full ]; then
    C=$(newcase); up "$C"; printf '12 0\n' > "$C/state/base-pending"; cp "$C/state/base-pending" "$C/before"; : > "$C/data/system/users/12.xml"
    ln -s /dev/full "$C/state/base-pending.tmp"
    run "$sh" "$C" "" 'chmod() { local a; for a in "$@"; do [ -L "$a" ] && return 1; done; command chmod "$@"; }; base_retry_run retry'
    if [ -f "$C/state/base-pending" ] && [ ! -L "$C/state/base-pending" ] && [ "$(head -c 4096 "$C/state/base-pending")" = "12 0" ]; then
      ok "$tag R8 a .tmp that takes no line never replaces the list"
    else
      no "$tag R8 the list was replaced (symlink: $([ -L "$C/state/base-pending" ] && echo yes || echo no))"
    fi
  else
    echo "  SKIP  $tag R8 (no writable /dev/full)"
  fi

  # R9 a listed uid below 10 is never released
  C=$(newcase); up "$C"; printf '5 0\n' > "$C/state/base-pending"
  run "$sh" "$C" "" "$RUNB"
  [ ! -e "$C/calls" ] && ok "$tag R9 a listed uid 5 is never released" || no "$tag R9 calls '$(calls "$C")'"

  # P1 the top-level hook, as written in the file: the read-write lane only
  for e in ro: cred: rw:1; do
    C=$(newcase)
    run "$sh" "$C" "" "base_retry_run() { echo \"\$1\" >> \"\$ROOT/calls\"; }; LANE=${e%%:*}
$HOOK"
    [ "$(lines "$C/calls")" = "$( [ -n "${e#*:}" ] && echo 1 || echo 0 )" ] && ok "$tag P1 hook LANE=${e%%:*}: $(lines "$C/calls") call(s)" || no "$tag P1 hook LANE=${e%%:*}: $(lines "$C/calls") call(s)"
  done
  [ "$(calls "$C")" = retry ] && ok "$tag P1 the hook passes why=retry" || no "$tag P1 hook why '$(calls "$C")'"

  # P3 the bootsweep head, as written: it runs base_retry_run boot and reports <cleared>/<left>
  C=$(newcase)
  run "$sh" "$C" "" 'base_retry_run() { echo "$1" >> "$ROOT/calls"; BASE_CLEARED=2; BASE_LEFT=1; }
. "'"$W"'/head.sh"
printf "%s" "$_swept" > "$ROOT/swept"'
  [ "$(calls "$C")" = boot ] && [ "$(cat "$C/swept" 2>/dev/null)" = " baseretry=2/1" ] && ok "$tag P3 the bootsweep head runs base_retry_run boot and appends baseretry=2/1" \
    || no "$tag P3 calls '$(calls "$C")' _swept '$(cat "$C/swept" 2>/dev/null)'"
done

# P2 the hook sits after reap_retry_run's and before userdir_recheck's, both guarded
t=$(awk -v a="$RR_A" 'p == 2 {print; exit} p == 1 {p=2} $0 == a {p=1}' "$SUT")
case "$HOOK" in '[ "$LANE" = rw ] && base_retry_run retry'|'[ "$LANE" = rw ] && base_retry_run retry '*) h=ok ;; *) h=no ;; esac
[ "$h" = ok ] && [ "$t" = '[ "$LANE" = rw ] && userdir_recheck' ] && ok "P2 the guarded hook is the line after reap_retry_run's and before userdir_recheck's" || no "P2 after reap_retry_run: '$HOOK'; next: '$t'"
# P3 in the bootsweep op, base_retry_run boot comes before loc_boot
a=$(printf '%s\n' "$OPB" | grep -nxF '  base_retry_run boot' | head -n 1 | cut -d: -f1)
b=$(printf '%s\n' "$OPB" | grep -nxF '  loc_boot' | head -n 1 | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && ok "P3 bootsweep calls base_retry_run boot (line $a) before loc_boot (line $b)" || no "P3 base_retry_run boot at '${a:-none}', loc_boot at '${b:-none}'"
# P4 the call counts: two runs (hook, bootsweep), one add (cleanstorage); none in the userdirrecheck op
n=$(grep -v '^[[:space:]]*#' "$SUT" | grep -cE '(^|[;&|{] *|^ *)base_retry_run( |$)')
m=$(grep -v '^[[:space:]]*#' "$SUT" | grep -c 'base_retry_add "\$uid"')
[ "$n" = 2 ] && [ "$m" = 1 ] && ok "P4 base_retry_run is called twice and base_retry_add once" || no "P4 $n base_retry_run call(s), $m base_retry_add call(s)"
t=$(sed -n '/^if \[ "\$op" = "userdirrecheck" \]; then$/,/^fi$/p' "$SUT" | grep -c base_retry)
[ "$t" = 0 ] && ok "P4 the userdirrecheck op does not call it" || no "P4 the userdirrecheck op names base_retry $t time(s)"

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite under each shell) =="
  # mutate <label> <assertion> <cmd ...>: the mutant must make the child exit 1 (an assertion failed, never 2: an
  # extraction failure proves nothing) and print the NAMED assertion's FAIL line, under each shell. <assertion> is the
  # assertion id; one checked inside the per-shell loop is prefixed '@ ', which stands for that shell's tag.
  mutate(){ local lbl="$1" want="$2" m s out rc pat; shift 2; m=$(mktemp -d -p "$W")
    if ! "$@" > "$m/m" 2>"$m/err"; then no "MUTATION BROKEN: $lbl: $(cat "$m/err")"; rm -rf "$m"; return; fi
    if cmp -s "$SUT" "$m/m"; then no "MUTATION INERT: $lbl"; rm -rf "$m"; return; fi
    for s in "${SHELLS[@]}"; do
      out=$(BASERETRY_SHELLS="$s" bash "$0" "$m/m" 2>&1); rc=$?
      case "$want" in "@ "*) pat="  FAIL  [${s##*/}] ${want#@ } " ;; *) pat="  FAIL  $want " ;; esac
      if [ "$rc" -eq 0 ]; then no "NOT CONVICTED under ${s##*/}: $lbl -- suite passes on broken code"
      elif [ "$rc" -ne 1 ]; then no "NOT CONVICTED under ${s##*/}: $lbl -- the suite exited $rc, not by an assertion: $(printf '%s\n' "$out" | grep -m1 'EXTRACTION FAILED')"
      elif [[ "$out" != *"$pat"* ]]; then no "NOT CONVICTED under ${s##*/}: $lbl -- '${pat#  FAIL  }' did not fail"
      else ok "convicted under ${s##*/} by ${pat#  FAIL  }-- $lbl"; fi
    done
    rm -rf "$m"
  }
  H='/^base_retry_run() {$/,/^}$/'
  A='/^base_retry_add() {$/,/^}$/'
  mutate "M1: the boot_completed gate dropped" "@ G1" sed "$H s/^  \[ \"\$(getprop sys.boot_completed 2>\/dev\/null)\" = 1 \] || return 0\$/  :/" "$SUT"
  mutate "M2: the service-check gate dropped" "@ G2" sed "$H s/^  case \"\$_sv\" in \*\": found\"\*) ;; \*) return 0 ;; esac\$/  :/" "$SUT"
  mutate "M2b: the service match weakened to *found*" "@ G2" sed "$H s/\*\": found\"\*)/*found*)/" "$SUT"
  mutate "M3: ERR-HS treated as success" "@ R3" sed "$H { /case \"\$HS_VERDICT\" in ERR-\*)/d; }" "$SUT"
  mutate "M4: the add's uid >= 10 guard dropped" "@ C4" sed "$A { /^  \[ \"\$1\" -ge 10 \] || return 0\$/d; }" "$SUT"
  mutate "M4b: the run's uid >= 10 guard dropped" "@ R9" sed "$H { /^    \[ \"\$_u\" -ge 10 \] || continue\$/d; }" "$SUT"
  mutate "M5: the RW-lane guard on the hook dropped" "@ P1" sed 's/^\[ "\$LANE" = rw \] && base_retry_run retry$/base_retry_run retry/' "$SUT"
  mutate "M6: never dropped after 3 tries" "@ R3" sed "$H s/\"\$_t\" -lt 3/\"\$_t\" -lt 4/" "$SUT"
  mutate "M7: the op's own uid retried" "@ R4" sed "$H s/if \[ \"\$_u\" = \"\${uid:-}\" \] || /if /" "$SUT"
  mutate "M8: the on-record skip dropped" "@ R5" sed "$H s/ || userdir_has_record \"\$_u\"; then/; then/" "$SUT"
  # M9 and M12 keep the call's text on the line (behind ':'), so the extraction anchors hold and the behaviour fails.
  mutate "M9: cleanstorage queues nothing" "@ C1" sed 's/^    base_retry_add "\$uid"$/    : base_retry_add "$uid"/' "$SUT"
  mutate "M10: the rewrite check removed (mv always)" "@ R8" sed "$H s/^    if \[ \"\\\$_got\" = \"\\\$_n\" \]; then\$/    if :; then/" "$SUT"
  mutate "M11: the .tmp write is bare" "@ R7" sed "$H s/^  ( : > \"\\\$_f\\.tmp\" )\$/  : > \"\$_f.tmp\"/" "$SUT"
  mutate "M12: bootsweep no longer retries" "@ P3" sed 's/^  base_retry_run boot$/  : base_retry_run boot/' "$SUT"
fi

echo
echo "shells: ${SHELLS[*]}; $PASS ok, $FAIL failed"
[ "$FAIL" = 0 ]
