#!/usr/bin/env bash
# test-reap-stale-ondemand.sh [<nowhere_roamd.sh>] [--mutate] -- reap_stale_ondemand's filter, on the host (NWP-20261014-45).
#
# WHY THIS IS COMMITTED. reap_stale_ondemand reads the keep-set manifest's package and mode columns and runs
# `timeout -k 5 30 pm uninstall <pkg>` -- with no --user, so USER_ALL -- on every ondemand|auto row at EVERY sign-in.
# Its safety argument is the mode filter: an `installed` row is a kept, fully installed app that the restore brought
# back whole, and if one ever slips through, that app is uninstalled for every user on the handset. On a device the
# filter and "there was nothing to reap" look the same, so nothing ran it. This suite does, under every shell present (bash, sh, dash and mksh):
#   - only ondemand and auto rows reach pm; installed, empty and unknown modes (including a wrong-case spelling and a
#     line with no tab at all) never do;
#   - a name that is empty, holds a `/` or holds a space is skipped, whatever its mode;
#   - a missing manifest makes no pm call and returns 0; blank lines are skipped;
#   - every pm call goes through `timeout -k 5 30`, so a pm stall at login cannot wedge the roam-in;
#   - a pm failure is logged with its rc and the loop CONTINUES with the next row;
#   - NWP-20261125-01 (h55 #4): the reap CHECKS hold_ondemand's park. hold_ondemand runs first, in the same shell, on a
#     tree under the case dir. A package whose canonical CE, DE, Android/data or Android/obb entry is still there makes
#     no pm call and logs a SKIPPED line naming that volume: after a failed merge, a failed mv, a name pkgname_ok
#     refuses and an absent keep-set, while a parked package in the same manifest IS reaped. An empty or non-numeric
#     uid makes no pm call at all. $STATE/od-unparked.<uid> lists exactly the skipped names, mode 600, and each call
#     rewrites it (empty when nothing is skipped, also with no manifest).
# It deliberately does not pin the exact `pm uninstall <pkg>` argv beyond "uninstall <pkg>": the open row about the
# USER_ALL reap removing a cold-locked user's apps (docs/backlog.md, "A fresh sign-in over a cold-locked session
# uninstalls apps ...") will change that argv, and its fix must not have to fight this suite.
#
# reap_stale_ondemand, hold_ondemand, pkgname_ok and the ODHOLD= line are extracted from nowhere_roamd.sh BY ANCHOR,
# never copied, so a stale copy cannot keep passing after the real code moves. Every `"/data/` path in the extracted
# text is re-rooted to the case dir with sed. pm, timeout and restorecon are stubbed; cut, cp, mv, date and the file
# reads are real.
#
# ⚠ NO `cmd | grep -q` ANYWHERE IN THIS FILE: under pipefail an early-exiting grep -q makes the writer die of SIGPIPE
# and the pipeline FAIL although grep matched. Match against a here-string or a file instead.
#
#   bash test-reap-stale-ondemand.sh            # the cases
#   bash test-reap-stale-ondemand.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

SHELLS=""
for s in bash sh dash mksh; do
  if command -v "$s" >/dev/null 2>&1; then SHELLS="$SHELLS $s"; else echo "  skip  shell $s not installed"; fi
done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

# pm records its argv, one call per line; it fails (rc 1) for a package listed in $T/pmfail.
# timeout records its own argv, strips `-k <grace>` and the duration, then runs the rest.
STUBS=$(cat <<'EOS'
restorecon(){ :; }
pm(){
  printf '%s\n' "$*" >> "$T/pm"
  [ "${2:-}" ] && grep -qxF -- "$2" "$T/pmfail" 2>/dev/null && return 1
  return 0
}
timeout(){
  printf '%s\n' "$*" >> "$T/timeout"
  while [ "${1:-}" = -k ]; do shift 2; done
  shift
  "$@"
}
EOS
)

# extract_fn <script> -> the ODHOLD= line, pkgname_ok, hold_ondemand and reap_stale_ondemand, each found by its anchor,
# with every path that opens `"/data/` re-rooted to a literal `"$ROOT/data/` (anchored on the quote, so the
# `Android/data/` inside a path is left alone); on a missing piece, its name on stderr and failure.
extract_fn() {
  local out fn piece
  out=$(sed -n '/^ODHOLD=/p' "$1")
  case "$out" in ODHOLD=*) ;; *) echo ODHOLD >&2; return 1 ;; esac
  for fn in pkgname_ok hold_ondemand reap_stale_ondemand; do
    piece=$(sed -n "/^$fn() {\$/,/^}\$/p" "$1")
    case "$piece" in *"$fn() {"*) ;; *) echo "$fn" >&2; return 1 ;; esac
    out="$out
$piece"
  done
  printf '%s\n' "$out" | sed 's|"/data/|"$ROOT/data/|g'
}

# suite <script> [quiet] -> 0 iff every case behaved. Own counters, never touches globals.
suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 FN T sh moved
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }

  FN=$(extract_fn "$f" 2>"$W/moved") || { moved=$(cat "$W/moved"); [ -n "$quiet" ] || echo "EXTRACTION FAILED -- ${moved:-a piece} moved in $f" >&2; return 2; }

  # newcase -- a fresh case dir $T, with $T/state as $STATE and the tree under $T/data/.
  newcase() {
    T=$(mktemp -d -p "$W")
    mkdir -p "$T/state"
    : > "$T/pm"; : > "$T/timeout"; : > "$T/log"
  }
  # reap_in <shell> [hold] -- the extracted pieces + stubs in a fresh shell over the case dir; with `hold`, hold_ondemand 10
  # runs first, as the `in` op runs it. The reap gets $T/man and the uid ${UIDARG-10} (UIDARG= passes an empty uid).
  # STATEDIR overrides $STATE. Leaves rc in $RC, the pm argv lines in $T/pm, the timeout argv lines in $T/timeout and
  # the log in $T/log.
  reap_in() {
    local h=":"
    [ "${2:-}" = hold ] && h="hold_ondemand 10"
    [ -n "${PMFAIL:-}" ] && printf '%s\n' "$PMFAIL" > "$T/pmfail"
    "$1" -c "T='$T'; ROOT='$T'; LOG='$T/log'; STATE='${STATEDIR:-$T/state}'; $FN
$STUBS
$h
reap_stale_ondemand '$T/man' '${UIDARG-10}'; echo \$? > '$T/rc'" >"$T/stdout" 2>&1
    RC=$(cat "$T/rc" 2>/dev/null)
  }
  # run <shell> [<manifest text>|-] -- newcase, the manifest ("-" = no manifest file), then reap_in with no hold.
  run() {
    newcase
    [ "${2-}" = "-" ] || printf '%b' "${2-}" > "$T/man"
    reap_in "$1"
  }
  # keep <pkg> <mode> ... -- append rows to user 10's nowhere-appkeep. mk <path> -- a dir under $T/data holding a file.
  keep() {
    local d="$T/data/user/10/com.nowhere.chooser/files"
    mkdir -p "$d"
    while [ "$#" -ge 2 ]; do printf '%s\t%s\n' "$1" "$2" >> "$d/nowhere-appkeep"; shift 2; done
  }
  mk() { mkdir -p "$T/data/$1" && printf 'x\n' > "$T/data/$1/f"; }
  manifest() { local q; : > "$T/man"; for q in "$@"; do row "$q" ondemand >> "$T/man"; done; }
  skipped() { grep -qF "reap-stale-ondemand $1 SKIPPED -- its data is still in the canonical dir ($2)" "$T/log"; }
  list_is() {  # list_is <want text> -- $T/state/od-unparked.10 is exactly that text
    printf '%b' "$1" > "$T/want"
    [ -f "$T/state/od-unparked.10" ] && cmp -s "$T/want" "$T/state/od-unparked.10"
  }
  showlist() { { tr '\n' ';' < "$T/state/od-unparked.10"; } 2>/dev/null || echo '(no list)'; }
  # unparked <tag> <what> <pkg> <vol> -- the pkg made no pm call and logged its skip; com.parked (the control) WAS reaped
  unparked() {
    if [ "$RC" = 0 ] && ! pm_has "$3" && skipped "$3" "$4"; then ok "$1 $2: $3 makes no pm call and logs SKIPPED ($4)"
    else no "$1 $2: $3 not skipped as $4 (rc=$RC, pm: $(tr '\n' ';' < "$T/pm") log: $(tr '\n' ';' < "$T/log"))"; fi
    if pm_has com.parked; then ok "$1 $2: the parked control in the same manifest is reaped"
    else no "$1 $2: the parked control com.parked was not reaped (pm: $(tr '\n' ';' < "$T/pm"))"; fi
  }
  pm_calls() { grep -c . "$T/pm"; }
  pm_has() { grep -qxF -- "uninstall $1" "$T/pm"; }
  row() { printf '%s\t1\t2\t%s\n' "$1" "$2"; }   # package, mode -- columns 2 and 3 are not read

  for sh in $SHELLS; do
    local tg="[$sh]" m n u

    # 1. which modes reach pm
    run "$sh" "$(row com.od ondemand)\n$(row com.au auto)\n$(row com.in installed)\n$(row com.em '')\n$(row com.unk weird)\n$(row com.up ONDEMAND)\n$(row com.ke keep)\ncom.notab\n"
    if [ "$RC" = 0 ] && pm_has com.od && pm_has com.au; then ok "$tg ondemand and auto rows are uninstalled"
    else no "$tg ondemand/auto row not uninstalled (rc=$RC, pm: $(tr '\n' ';' < "$T/pm"))"; fi
    n=$(pm_calls)
    if [ "$n" = 2 ]; then ok "$tg exactly those two reach pm"
    else no "$tg $n pm calls, want 2 -- a row outside ondemand|auto reached pm: $(tr '\n' ';' < "$T/pm")"; fi
    for m in com.in com.em com.unk com.up com.ke com.notab; do
      if pm_has "$m"; then no "$tg $m reached pm -- a kept or unknown-mode app is uninstalled for every user"
      else ok "$tg $m never reaches pm"; fi
    done
    rm -rf "$T"

    # 2. names that must be skipped, even on an ondemand row
    run "$sh" "$(row a/b ondemand)\n$(row 'a b' ondemand)\n$(row '' ondemand)\n$(row ' ' auto)\n$(row com.ok ondemand)\n"
    n=$(pm_calls)
    if [ "$n" = 1 ] && pm_has com.ok; then ok "$tg names with / or a space, and empty names, are skipped"
    else no "$tg name guard: $n pm calls, want only com.ok: $(tr '\n' ';' < "$T/pm")"; fi
    rm -rf "$T"

    # 3. a missing manifest
    run "$sh" -
    if [ "$RC" = 0 ] && [ "$(pm_calls)" = 0 ]; then ok "$tg a missing manifest makes no pm call and returns 0"
    else no "$tg missing manifest: rc=$RC, $(pm_calls) pm calls"; fi
    rm -rf "$T"

    # 4. blank lines, and an empty file
    run "$sh" "\n\n$(row com.od ondemand)\n\n\n"
    if [ "$RC" = 0 ] && [ "$(pm_calls)" = 1 ] && pm_has com.od; then ok "$tg blank lines are skipped"
    else no "$tg blank lines: rc=$RC, pm: $(tr '\n' ';' < "$T/pm")"; fi
    rm -rf "$T"
    run "$sh" ""
    if [ "$RC" = 0 ] && [ "$(pm_calls)" = 0 ]; then ok "$tg an empty manifest makes no pm call"
    else no "$tg empty manifest: rc=$RC, $(pm_calls) pm calls"; fi
    rm -rf "$T"

    # 5. every call goes through timeout -k 5 30
    run "$sh" "$(row com.od ondemand)\n$(row com.au auto)\n"
    if [ "$(grep -c . "$T/timeout")" = 2 ] && [ "$(grep -cxF -- '-k 5 30 pm uninstall com.od' "$T/timeout")" = 1 ] \
       && [ "$(grep -cxF -- '-k 5 30 pm uninstall com.au' "$T/timeout")" = 1 ]; then
      ok "$tg each pm call goes through timeout -k 5 30"
    else no "$tg pm not bounded by timeout -k 5 30: $(tr '\n' ';' < "$T/timeout")"; fi
    rm -rf "$T"

    # 6. a pm failure logs and continues
    PMFAIL=com.first run "$sh" "$(row com.first ondemand)\n$(row com.second auto)\n"
    if [ "$RC" = 0 ] && pm_has com.first && pm_has com.second; then ok "$tg a pm failure does not stop the loop"
    else no "$tg pm failure aborted the loop (rc=$RC, pm: $(tr '\n' ';' < "$T/pm"))"; fi
    if grep -qF 'reap-stale-ondemand com.first (rc=1)' "$T/log" && grep -qF 'reap-stale-ondemand com.second (rc=0)' "$T/log"; then
      ok "$tg each row is logged with its rc"
    else no "$tg log lacks the per-row rc: $(tr '\n' ';' < "$T/log")"; fi
    rm -rf "$T"

    # 7. a skipped row BEFORE a valid one must not end the loop (guards the continue in both filters)
    run "$sh" "$(row com.in installed)\n$(row a/b ondemand)\n$(row com.od ondemand)\n"
    if pm_has com.od && [ "$(pm_calls)" = 1 ]; then ok "$tg a skipped row does not end the loop"
    else no "$tg a skipped row ended the loop: $(tr '\n' ';' < "$T/pm")"; fi
    rm -rf "$T"

    # --- NWP-20261125-01: the park is checked. hold_ondemand runs first; com.parked is a control that does park. ---
    # (a) a failed merge, Android/data only: the hold holds a FILE `x` where the canonical holds a DIRECTORY `x`
    newcase; keep com.mg ondemand com.parked ondemand; manifest com.mg com.parked
    mk user/10/com.parked
    mk media/10/Android/data/com.mg/x
    mkdir -p "$T/data/media/10/Android/data/com.nowhere.chooser/.nowhere-odhold/com.mg"
    printf 'old\n' > "$T/data/media/10/Android/data/com.nowhere.chooser/.nowhere-odhold/com.mg/x"
    reap_in "$sh" hold
    if grep -qF 'on-demand com.mg ' "$T/log" && grep -qF 'ext merge FAILED -- canonical LEFT IN PLACE' "$T/log"; then
      ok "$tg (a) setup: hold_ondemand's ext merge for com.mg failed"
    else no "$tg (a) setup: no failed ext merge for com.mg in the log: $(tr '\n' ';' < "$T/log")"; fi
    unparked "$tg" "(a) failed merge" com.mg data
    if list_is 'com.mg\n'; then ok "$tg (g) od-unparked.10 lists exactly the skipped package"
    else no "$tg (g) od-unparked.10 is not exactly com.mg: $(showlist)"; fi
    if [ "$(stat -c %a "$T/state/od-unparked.10" 2>/dev/null)" = 600 ]; then ok "$tg (g) od-unparked.10 is mode 600"
    else no "$tg (g) od-unparked.10 mode is $(stat -c %a "$T/state/od-unparked.10" 2>/dev/null || echo '(no list)'), want 600"; fi
    if [ ! -e "$T/state/od-unparked.10.tmp" ]; then ok "$tg (g) no temp file is left in \$STATE"
    else no "$tg (g) od-unparked.10.tmp left in \$STATE"; fi
    rm -rf "$T"

    # (b) a failed mv, CE only: the chooser's CE .nowhere-odhold is a regular file, so mkdir and mv fail
    newcase; keep com.mv ondemand com.parked ondemand; manifest com.mv com.parked
    mk user/10/com.mv
    mk user_de/10/com.parked
    printf 'not a dir\n' > "$T/data/user/10/com.nowhere.chooser/.nowhere-odhold"
    reap_in "$sh" hold
    unparked "$tg" "(b) failed mv" com.mv CE
    if [ -f "$T/data/user/10/com.mv/f" ]; then ok "$tg (b) com.mv's only copy is still in the canonical dir"
    else no "$tg (b) com.mv's data is gone"; fi
    rm -rf "$T"

    # (c) a refused name, DE only: `1a.b` passes the reap's filter and fails pkgname_ok, so hold_ondemand never parks it
    newcase; keep 1a.b ondemand com.parked ondemand; manifest 1a.b com.parked
    mk user_de/10/1a.b
    mk user/10/com.parked
    reap_in "$sh" hold
    unparked "$tg" "(c) refused name" 1a.b DE
    rm -rf "$T"

    # (d) an absent keep-set: hold_ondemand returns at once, so all four volumes stay; CE is named first. The control
    #     com.gone has no canonical data at all.
    newcase; manifest com.nk com.gone
    mk user/10/com.nk; mk user_de/10/com.nk; mk media/10/Android/data/com.nk; mk media/10/Android/obb/com.nk
    reap_in "$sh" hold
    if [ "$RC" = 0 ] && ! pm_has com.nk && skipped com.nk CE; then ok "$tg (d) absent keep-set: com.nk makes no pm call and logs SKIPPED (CE)"
    else no "$tg (d) absent keep-set: com.nk not skipped as CE (rc=$RC, pm: $(tr '\n' ';' < "$T/pm") log: $(tr '\n' ';' < "$T/log"))"; fi
    if pm_has com.gone; then ok "$tg (d) a package with nothing left in place is reaped"
    else no "$tg (d) com.gone was not reaped (pm: $(tr '\n' ';' < "$T/pm"))"; fi
    rm -rf "$T"

    # (e) data left only in Android/obb: CE parks, the obb merge fails as in (a)
    newcase; keep com.ob ondemand com.parked ondemand; manifest com.ob com.parked
    mk user/10/com.ob
    mk user/10/com.parked
    mk media/10/Android/obb/com.ob/x
    mkdir -p "$T/data/media/10/Android/obb/com.nowhere.chooser/.nowhere-odhold/com.ob"
    printf 'old\n' > "$T/data/media/10/Android/obb/com.nowhere.chooser/.nowhere-odhold/com.ob/x"
    reap_in "$sh" hold
    if [ -f "$T/data/user/10/com.nowhere.chooser/.nowhere-odhold/com.ob/f" ] && [ ! -e "$T/data/user/10/com.ob" ]; then
      ok "$tg (e) setup: com.ob's CE data parked"
    else no "$tg (e) setup: com.ob's CE data did not park"; fi
    unparked "$tg" "(e) obb only" com.ob obb
    rm -rf "$T"

    # (f) an empty and a non-numeric uid: no pm call at all, one log line, no list
    for u in "" x1; do
      newcase; manifest com.od com.au
      UIDARG="$u" reap_in "$sh"
      if [ "$RC" = 0 ] && [ "$(pm_calls)" = 0 ] && grep -qF 'reap-stale-ondemand: no valid uid -- reaping nothing (NWP-20261125-01)' "$T/log"; then
        ok "$tg (f) uid '$u' makes no pm call and logs why"
      else no "$tg (f) uid '$u': rc=$RC, $(pm_calls) pm calls, log: $(tr '\n' ';' < "$T/log")"; fi
      if [ -z "$(ls -A "$T/state")" ]; then ok "$tg (f) uid '$u' writes no list"
      else no "$tg (f) uid '$u' wrote into \$STATE: $(ls -A "$T/state" | tr '\n' ' ')"; fi
      rm -rf "$T"
    done

    # (g) the list: two skips in manifest order; empty when nothing is skipped; empty with no manifest; rewritten, never
    #     appended, by the next call
    newcase; manifest com.one com.ok com.two
    mk user/10/com.one; mk user_de/10/com.two
    reap_in "$sh"
    if list_is 'com.one\ncom.two\n' && pm_has com.ok; then ok "$tg (g) two skips are listed one per line, in manifest order"
    else no "$tg (g) two-skip list: $(showlist)"; fi
    rm -rf "$T/data/user/10/com.one" "$T/data/user_de/10/com.two"
    : > "$T/pm"
    reap_in "$sh"
    if list_is '' && pm_has com.one && pm_has com.two; then ok "$tg (g) a second call with nothing skipped rewrites the list empty"
    else no "$tg (g) second call: list $(showlist)"; fi
    rm -rf "$T"
    newcase; manifest com.ok
    printf 'stale.pkg\n' > "$T/state/od-unparked.10"
    reap_in "$sh"
    if list_is ''; then ok "$tg (g) nothing skipped: an earlier list is replaced by an empty one"
    else no "$tg (g) nothing skipped: list $(showlist)"; fi
    rm -rf "$T"
    run "$sh" -
    if list_is ''; then ok "$tg (g) no manifest: the list is written empty"
    else no "$tg (g) no manifest: list $(showlist)"; fi
    rm -rf "$T"

    # (h) a list that cannot be written: the skip still holds, the failure is logged, rc 0
    newcase; manifest com.one com.ok
    mk user/10/com.one
    STATEDIR="$T/nostate" reap_in "$sh"
    if [ "$RC" = 0 ] && ! pm_has com.one && pm_has com.ok && skipped com.one CE \
       && grep -qF 'WARN reap-stale-ondemand: could not write the unparked list for user 10' "$T/log"; then
      ok "$tg (h) a failed list write still skips, logs the failure and returns 0"
    else no "$tg (h) failed list write: rc=$RC, pm: $(tr '\n' ';' < "$T/pm") log: $(tr '\n' ';' < "$T/log")"; fi
    rm -rf "$T"
  done

  [ -n "$quiet" ] || printf '%s passed, %s failed\n' "$p" "$x"
  [ "$x" -eq 0 ]
}

echo "== reap_stale_ondemand (shells:$SHELLS) =="
suite "$SUT"; RC=$?
[ "$RC" -eq 2 ] && exit 2
[ "$RC" -eq 0 ] || { echo "RESULT: FAIL"; exit 1; }

if [ "$MUTATE" = yes ]; then
  echo "== mutations: each must be CONVICTED =="
  MD=$(mktemp -d -p "$W")
  MISSED=0
  # mutant <name> <sed expr> -- apply to a copy of the script; a mutant that does not change the copy is a failure.
  mutant() {
    local name="$1" expr="$2" m="$MD/m.sh" res rc bad="" t
    sed "$expr" "$SUT" > "$m"
    if cmp -s "$SUT" "$m"; then echo "  MUTANT DID NOT APPLY  $name"; MISSED=$((MISSED+1)); return; fi
    # not quiet: a conviction needs rc 1 and a FAIL line under every shell's own tag, mksh's included
    res=$(suite "$m" 2>&1); rc=$?
    for t in $SHELLS; do
      case "$res" in *"  FAIL  [$t]"*) ;; *) bad="$bad $t" ;; esac
    done
    if [ "$rc" = 0 ]; then echo "  SURVIVED  $name"; MISSED=$((MISSED+1))
    elif [ "$rc" = 1 ] && [ -z "$bad" ]; then echo "  convicted $name"
    else echo "  NOT CONVICTED (rc $rc, no FAIL line under:${bad:- none})  $name"; MISSED=$((MISSED+1)); fi
  }
  mutant "mode case gains installed"      's/case "\$rmode" in ondemand|auto) ;;/case "$rmode" in ondemand|auto|installed) ;;/'
  mutant "mode filter removed"            '/case "\$rmode" in ondemand|auto)/d'
  mutant "name guard removed"             '/case "\$rpkg" in ""|\*\/\*|\*" "\*) continue;; esac/d'
  mutant "timeout dropped"                's/timeout -k 5 30 pm uninstall/pm uninstall/'
  mutant "mode filter continue -> break"  's/\(case "\$rmode" in ondemand|auto) ;; \*) \)continue/\1break/'
  mutant "name guard continue -> break"   's/\(case "\$rpkg" in ""|\*\/\*|\*" "\*) \)continue/\1break/'
  mutant "CE check removed"               '/&& _vol=CE$/d'
  mutant "DE check removed"               '/&& _vol=DE$/d'
  mutant "data check removed"             '/&& _vol=data$/d'
  mutant "obb check removed"              '/&& _vol=obb$/d'
  mutant "uid guard removed"              '/case "\$uid" in ""|\*\[!0-9\]\*)/d'
  mutant "skip list appended"             's|mv -f "\$_tmp" "\$_out"|cat "$_tmp" >> "$_out"|'
  mutant "skip continue dropped"          '/continue   # NWP-20261125-01: no pm call for unparked data/d'
  [ "$MISSED" -eq 0 ] || { echo "RESULT: FAIL ($MISSED mutant(s) not convicted)"; exit 1; }
fi
echo "RESULT: PASS"
