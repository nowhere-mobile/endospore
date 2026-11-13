#!/usr/bin/env bash
# test-reap-stale-ondemand.sh [<nowhere_roamd.sh>] [--mutate] -- reap_stale_ondemand's filter, on the host (NWP-20261014-45).
#
# WHY THIS IS COMMITTED. reap_stale_ondemand reads the keep-set manifest's package and mode columns and runs
# `pm uninstall <pkg>` -- with no --user, so USER_ALL, unless another user has the package -- on every
# ondemand|auto row at EVERY sign-in. Its safety argument is the mode filter: an `installed` row is a kept, fully installed app that the restore brought
# back whole, and if one ever slips through, that app is uninstalled for every user on the handset. On a device the
# filter and "there was nothing to reap" look the same, so nothing ran it. This suite does, under every shell present (bash, sh, dash and mksh):
#   - only ondemand and auto rows reach pm; installed, empty and unknown modes (including a wrong-case spelling and a
#     line with no tab at all) never do;
#   - a name that is empty, holds a `/` or holds a space is skipped, whatever its mode;
#   - a missing manifest makes no pm call and returns 0; blank lines are skipped;
#   - every pm uninstall runs inside a batch bounded by `timeout -k 5 120`, so a pm stall at login cannot wedge the
#     roam-in (NWP-20261130-06: the bound was `timeout -k 5 30` per call);
#   - a pm failure is logged with its rc and the loop CONTINUES with the next row;
#   - NWP-20261125-01 (h55 #4): the reap CHECKS hold_ondemand's park. hold_ondemand runs first, in the same shell, on a
#     tree under the case dir. A package whose canonical CE, DE, Android/data or Android/obb entry is still there makes
#     no pm call and logs a SKIPPED line naming that volume: after a failed merge, a failed mv, a name pkgname_ok
#     refuses and an absent keep-set, while a parked package in the same manifest IS reaped. An empty or non-numeric
#     uid makes no pm call at all. $STATE/od-unparked.<uid> lists exactly the skipped names, mode 600, and each call
#     rewrites it (empty when nothing is skipped, also with no manifest).
#   - NWP-20261129-13: the same list is also written beside the manifest as <manifest dir>/od-unparked, the copy the gate's
#     chooser reads: exactly the skipped names, mode 600, chowned to the dir's owner and restorecon'd before the rename,
#     no temp left. A manifest whose dir is absent writes no copy. A failed write logs one WARN naming no package and
#     changes nothing else; a failed restorecon alone keeps the copy.
#   - NWP-20261201-17 (h60 #6): the suite pins the argv of both arms (C1-C8). A package another user's listing names, or
#     every package when a listing fails or is empty, runs `pm uninstall --user 0 <pkg>` and `pm uninstall --user <uid>
#     <pkg>`, each inside the bounded batch, never USER_ALL. A package no other user has runs `pm uninstall <pkg>`. Other
#     users are those with a record file that are neither 0 nor the uid. The listing is read once, only when a row reaches
#     removal. The new log lines hold counts only.
#   - NWP-20261130-06: the reap's removals run in batches of 16, each ONE external `sh` process under `timeout -k 5 120`
#     (od_reap_batch). The pm stub is also installed on PATH as an executable, and the batch process runs it, so B1 sees
#     the real process boundary: every uninstall of a reap of 5 comes from one process, not the reap's own shell, and
#     one batch line is the only timeout call. A failure inside a batch is counted and the rest are removed (B2).
#     Installed and other non-ondemand rows (B3) and unparked packages (B4) stay out of the batch. Each reap logs
#     `<n> removed, <n> failed` and `reap-stale-ondemand: <n> package(s) in <ms> ms` (B1-B5). B6 runs the REAL timeout
#     with a 2 s bound over a pm that stalls: the entries the batch did not reach count as failed, and one WARN says how
#     many. B7: 17 entries are two batches, in list order.
#
# reap_stale_ondemand, od_reap_batch, od_reap_batch_run, od_other_users, userdir_has_record, hold_ondemand, pkgname_ok and the ODHOLD= line are extracted from nowhere_roamd.sh BY ANCHOR,
# never copied, so a stale copy cannot keep passing after the real code moves. Every `"/data/` path in the extracted
# text is re-rooted to the case dir with sed. pm, timeout, restorecon, chown, _ms and `stat -c %u` are stubbed (a non-root
# runner cannot chown, and its own file already carries its uid, so "owned by the dir's owner" is the recorded chown);
# cut, cp, mv, chmod, date, the other stat formats and the file reads are real.
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
# timeout records its own argv, strips `-k <grace>` and the duration, then runs the rest. For a batch (`... sh -c <script>
# ...`) it records only `-k 5 120 sh -c`. With $T/realtimeout it runs the rest under the REAL timeout, `-k 1` and the
# duration that file holds (NWP-20261130-06).
# restorecon and chown record their argv; each fails when its marker is in the case dir. `stat -c %u` answers the fixture
# owner 10057, or fails on $T/statfail.
# hold_ondemand's two listings name none of this suite's packages and stay out of both records (NWP-20261129-27).
# `pm list packages [-a] --user <n>` records its argv in $T/pmlist, not $T/pm, and stays out of $T/timeout. It fails on
# $T/listfail.<n>. It prints $T/pkgs.<n>, or with -a every package of the case's manifest (NWP-20261201-17).
# NWP-20261130-06: the same pm is also $W/bin/pm, an executable that sets PM_VIA=exe and runs these stubs, and the batch
# process finds it on PATH. An uninstall records `<PM_VIA or fn> <PPID>` in $T/pmpid: run by a batch, PPID is the batch
# process. An uninstall of a package listed in $T/pmhang sleeps 30 s first. _ms answers 250 more than its last answer,
# so a reap's timing line reads 250 ms.
STUBS=$(cat <<'EOS'
restorecon(){ printf '%s\n' "$*" >> "$T/restorecon"; [ ! -e "$T/rconfail" ]; }
chown(){ printf '%s\n' "$*" >> "$T/chown"; [ ! -e "$T/chownfail" ]; }
stat(){
  if [ "${1:-}" = -c ] && [ "${2:-}" = %u ]; then
    [ -e "$T/statfail" ] && return 1
    echo 10057
  else command stat "$@"; fi
}
pm(){
  local _u
  case "$*" in "list packages -s -u") echo package:android; return 0 ;; "list packages -3 -u") return 0 ;; esac
  case "$*" in
    "list packages --user "*|"list packages -a --user "*)
      printf '%s\n' "$*" >> "$T/pmlist"
      for _u; do :; done
      [ -e "$T/listfail.$_u" ] && return 1
      if [ "$3" = -a ]; then cut -f1 "$T/man" | sed 's/^/package:/'; else cat "$T/pkgs.$_u" 2>/dev/null; fi
      return 0 ;;
  esac
  printf '%s\n' "$*" >> "$T/pm"
  printf '%s %s\n' "${PM_VIA:-fn}" "$PPID" >> "$T/pmpid"
  for _u; do :; done
  grep -qxF -- "$_u" "$T/pmhang" 2>/dev/null && sleep 30
  [ "${2:-}" ] && grep -qxF -- "$2" "$T/pmfail" 2>/dev/null && return 1
  [ "${2:-}" = --user ] && grep -qxF -- "${4:-}" "$T/pmfail" 2>/dev/null && return 1
  return 0
}
_ms(){
  local c
  c=$(cat "$T/clock" 2>/dev/null) || c=0
  c=$((c + 250))
  echo "$c" > "$T/clock"
  echo "$c"
}
timeout(){
  case "$*" in
    *"pm list packages "*) ;;
    *) if [ "${5:-}" = -c ]; then printf '%s\n' "$1 $2 $3 $4 $5" >> "$T/timeout"; else printf '%s\n' "$*" >> "$T/timeout"; fi ;;
  esac
  while [ "${1:-}" = -k ]; do shift 2; done
  shift
  if [ -e "$T/realtimeout" ]; then command timeout -k 1 "$(cat "$T/realtimeout")" "$@"; return; fi
  "$@"
}
EOS
)
mkdir -p "$W/bin"
printf '#!/bin/sh\nPM_VIA=exe\n%s\npm "$@"\n' "$STUBS" > "$W/bin/pm"
chmod 755 "$W/bin/pm"

# extract_fn <script> -> the ODHOLD= line and each function of the list below, each found by its anchor,
# with every path that opens `"/data/` re-rooted to a literal `"$ROOT/data/` (anchored on the quote, so the
# `Android/data/` inside a path is left alone); on a missing piece, its name on stderr and failure.
extract_fn() {
  local out fn piece
  out=$(sed -n '/^ODHOLD=/p' "$1")
  case "$out" in ODHOLD=*) ;; *) echo ODHOLD >&2; return 1 ;; esac
  for fn in pkgname_ok hold_ondemand userdir_has_record od_other_users od_reap_batch od_reap_batch_run reap_stale_ondemand; do
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
    : > "$T/pm"; : > "$T/pmpid"; : > "$T/pmlist"; : > "$T/timeout"; : > "$T/log"; : > "$T/chown"; : > "$T/restorecon"
  }
  # reap_in <shell> [hold] -- the extracted pieces + stubs in a fresh shell over the case dir; with `hold`, hold_ondemand 10
  # runs first, as the `in` op runs it. The reap gets ${MANARG:-$T/man} and the uid ${UIDARG-10} (UIDARG= passes an empty uid).
  # STATEDIR overrides $STATE. Leaves rc in $RC, the pm argv lines in $T/pm, the timeout argv lines in $T/timeout and
  # the log in $T/log. $T/mainpid holds the pid of the reap's own shell. T is exported and $W/bin leads PATH, for the
  # pm executable a batch runs.
  reap_in() {
    local h=":"
    [ "${2:-}" = hold ] && h="hold_ondemand 10"
    [ -n "${PMFAIL:-}" ] && printf '%s\n' "$PMFAIL" > "$T/pmfail"
    "$1" -c "T='$T'; export T; PATH='$W/bin':\$PATH; ROOT='$T'; LOG='$T/log'; STATE='${STATEDIR:-$T/state}'; $FN
$STUBS
sh -c 'echo \$PPID' > '$T/mainpid'
$h
reap_stale_ondemand '${MANARG:-$T/man}' '${UIDARG-10}'; echo \$? > '$T/rc'" >"$T/stdout" 2>&1
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
  copy_is() {  # copy_is <want text> -- $T/od-unparked, the copy beside the manifest $T/man, is exactly that text
    printf '%b' "$1" > "$T/want"
    [ -f "$T/od-unparked" ] && cmp -s "$T/want" "$T/od-unparked"
  }
  showcopy() { { tr '\n' ';' < "$T/od-unparked"; } 2>/dev/null || echo '(no copy)'; }
  warned() { grep -cF 'beside the manifest' "$T/log"; }
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
  # rec <file> ... -- record files under $T/data/system/users. lists <n> <pkg> ... -- the packages user <n> lists.
  rec() { local q; mkdir -p "$T/data/system/users"; for q in "$@"; do : > "$T/data/system/users/$q"; done; }
  lists() { local n="$1" q; shift; : > "$T/pkgs.$n"; for q in "$@"; do printf 'package:%s\n' "$q" >> "$T/pkgs.$n"; done; }
  # pm_is <want text> -- $T/pm is exactly that text. pmlist_is <want text> -- the same for $T/pmlist.
  pm_is() { printf '%b' "$1" > "$T/want"; cmp -s "$T/want" "$T/pm"; }
  pmlist_is() { printf '%b' "$1" > "$T/want"; cmp -s "$T/want" "$T/pmlist"; }
  show() { tr '\n' ';' < "$T/$1"; }
  summaries() { grep -cF 'kept for another user' "$T/log"; }
  # NWP-20261130-06. pids -- the distinct lines of $T/pmpid. batches -- the batch lines in $T/timeout.
  # timed <n> -- the timing line of a reap of <n> package(s). counted <ok> <failed> -- the count line.
  pids() { sort -u "$T/pmpid"; }
  batches() { grep -cxF -- '-k 5 120 sh -c' "$T/timeout"; }
  timed() { grep -cxE "\[roamd\] reap-stale-ondemand: $1 package\(s\) in 250 ms \(NWP-20261130-06\) .*" "$T/log"; }
  counted() { grep -cF "reap-stale-ondemand: $1 removed, $2 failed (NWP-20261130-06)" "$T/log"; }
  warns() { grep -cF "WARN reap-stale-ondemand: could not read another user's packages -- no package removed for all users (h60 #6)" "$T/log"; }

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

    # 5. every call runs inside the batch's timeout -k 5 120 (NWP-20261130-06: was timeout -k 5 30 per call)
    run "$sh" "$(row com.od ondemand)\n$(row com.au auto)\n"
    if [ "$(grep -c . "$T/timeout")" = 1 ] && [ "$(batches)" = 1 ] && [ "$(grep -c '^exe ' "$T/pmpid")" = 2 ] \
       && [ "$(pids | grep -c .)" = 1 ]; then
      ok "$tg each pm call runs inside one batch under timeout -k 5 120"
    else no "$tg pm not bounded by the batch's timeout -k 5 120: $(tr '\n' ';' < "$T/timeout") pids: $(tr '\n' ';' < "$T/pmpid")"; fi
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
    if copy_is 'com.mg\n'; then ok "$tg (g) the copy beside the manifest lists exactly the skipped package"
    else no "$tg (g) the copy is not exactly com.mg: $(showcopy)"; fi
    if [ "$(stat -c %a "$T/od-unparked" 2>/dev/null)" = 600 ]; then ok "$tg (g) the copy is mode 600"
    else no "$tg (g) the copy's mode is $(stat -c %a "$T/od-unparked" 2>/dev/null || echo '(no copy)'), want 600"; fi
    if grep -qxF "10057:10057 $T/od-unparked.tmp" "$T/chown"; then ok "$tg (g) the copy is chowned to the owner of its dir before the rename"
    else no "$tg (g) no chown of the copy to 10057:10057: $(tr '\n' ';' < "$T/chown")"; fi
    if grep -qxF -- "-D $T/od-unparked.tmp" "$T/restorecon"; then ok "$tg (g) the copy is restorecon'd before the rename"
    else no "$tg (g) no restorecon of the copy: $(tr '\n' ';' < "$T/restorecon")"; fi
    if [ ! -e "$T/od-unparked.tmp" ]; then ok "$tg (g) no temp file is left beside the manifest"
    else no "$tg (g) od-unparked.tmp left beside the manifest"; fi
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
      if [ ! -e "$T/od-unparked" ]; then ok "$tg (f) uid '$u' writes no copy"
      else no "$tg (f) uid '$u' wrote a copy: $(showcopy)"; fi
      rm -rf "$T"
    done

    # (g) the list: two skips in manifest order; empty when nothing is skipped; empty with no manifest; rewritten, never
    #     appended, by the next call
    newcase; manifest com.one com.ok com.two
    mk user/10/com.one; mk user_de/10/com.two
    reap_in "$sh"
    if list_is 'com.one\ncom.two\n' && pm_has com.ok; then ok "$tg (g) two skips are listed one per line, in manifest order"
    else no "$tg (g) two-skip list: $(showlist)"; fi
    if copy_is 'com.one\ncom.two\n'; then ok "$tg (g) the copy holds the same two names"
    else no "$tg (g) two-skip copy: $(showcopy)"; fi
    rm -rf "$T/data/user/10/com.one" "$T/data/user_de/10/com.two"
    : > "$T/pm"
    reap_in "$sh"
    if list_is '' && pm_has com.one && pm_has com.two; then ok "$tg (g) a second call with nothing skipped rewrites the list empty"
    else no "$tg (g) second call: list $(showlist)"; fi
    if copy_is ''; then ok "$tg (g) a second call with nothing skipped rewrites the copy empty"
    else no "$tg (g) second call: copy $(showcopy)"; fi
    rm -rf "$T"
    newcase; manifest com.ok
    printf 'stale.pkg\n' > "$T/state/od-unparked.10"
    printf 'stale.pkg\n' > "$T/od-unparked"
    reap_in "$sh"
    if list_is ''; then ok "$tg (g) nothing skipped: an earlier list is replaced by an empty one"
    else no "$tg (g) nothing skipped: list $(showlist)"; fi
    if copy_is ''; then ok "$tg (g) nothing skipped: an earlier copy is replaced by an empty one"
    else no "$tg (g) nothing skipped: copy $(showcopy)"; fi
    rm -rf "$T"
    run "$sh" -
    if list_is ''; then ok "$tg (g) no manifest: the list is written empty"
    else no "$tg (g) no manifest: list $(showlist)"; fi
    if copy_is ''; then ok "$tg (g) no manifest, its dir there: the copy is written empty"
    else no "$tg (g) no manifest: copy $(showcopy)"; fi
    rm -rf "$T"

    # (h) a list that cannot be written: the skip still holds, the failure is logged, rc 0
    newcase; manifest com.one com.ok
    mk user/10/com.one
    STATEDIR="$T/nostate" reap_in "$sh"
    if [ "$RC" = 0 ] && ! pm_has com.one && pm_has com.ok && skipped com.one CE \
       && grep -qF 'WARN reap-stale-ondemand: could not write the unparked list for user 10' "$T/log"; then
      ok "$tg (h) a failed list write still skips, logs the failure and returns 0"
    else no "$tg (h) failed list write: rc=$RC, pm: $(tr '\n' ';' < "$T/pm") log: $(tr '\n' ';' < "$T/log")"; fi
    if copy_is 'com.one\n'; then ok "$tg (h) a failed \$STATE write still writes the copy"
    else no "$tg (h) failed \$STATE write: copy $(showcopy)"; fi
    rm -rf "$T"

    # (i) a manifest whose dir is absent: no copy, no WARN (nothing failed), and the $STATE list is still written. The
    #     WARN check convicts a write attempted there: that write fails and leaves no file either.
    newcase
    MANARG="$T/gone/manifest.tsv" reap_in "$sh"
    if [ "$RC" = 0 ] && [ ! -e "$T/gone" ] && [ "$(warned)" = 0 ]; then ok "$tg (i) a manifest whose dir is absent writes no copy and logs no WARN"
    else no "$tg (i) absent dir: rc=$RC, log: $(tr '\n' ';' < "$T/log")"; fi
    if [ ! -e "$T/od-unparked" ] && list_is ''; then ok "$tg (i) the \$STATE list is still written"
    else no "$tg (i) absent dir: list $(showlist), copy $(showcopy)"; fi
    rm -rf "$T"

    # (j) a copy that cannot be written (a failed stat, a failed chown): one WARN naming no package, no copy, no temp,
    #     and the skip, the $STATE list and the reap of the control are unchanged
    for m in statfail chownfail; do
      newcase; manifest com.one com.ok
      mk user/10/com.one
      : > "$T/$m"
      reap_in "$sh"
      if [ "$RC" = 0 ] && [ "$(warned)" = 1 ] && [ ! -e "$T/od-unparked" ] && [ ! -e "$T/od-unparked.tmp" ]; then
        ok "$tg (j) $m: one WARN, no copy, no temp, rc 0"
      else no "$tg (j) $m: rc=$RC, $(warned) WARN(s), copy $(showcopy), log: $(tr '\n' ';' < "$T/log")"; fi
      grep -F 'beside the manifest' "$T/log" > "$T/warn"
      if grep -qF com.one "$T/warn"; then no "$tg (j) $m: the WARN names a package: $(cat "$T/warn")"
      else ok "$tg (j) $m: the WARN names no package"; fi
      if ! pm_has com.one && pm_has com.ok && list_is 'com.one\n'; then ok "$tg (j) $m: the skip, the reap and the \$STATE list are unchanged"
      else no "$tg (j) $m: pm: $(tr '\n' ';' < "$T/pm") list: $(showlist)"; fi
      rm -rf "$T"
    done

    # (k) a failed restorecon keeps the copy, as the in op's own restorecon of this dir ignores its rc: the new file
    #     already inherits the dir's label, and a copy the chooser cannot read falls back to no copy at the read
    newcase; manifest com.one
    mk user/10/com.one
    : > "$T/rconfail"
    reap_in "$sh"
    if copy_is 'com.one\n' && [ "$(warned)" = 0 ] && [ ! -e "$T/od-unparked.tmp" ]; then ok "$tg (k) a failed restorecon keeps the copy"
    else no "$tg (k) failed restorecon: copy $(showcopy), $(warned) WARN(s)"; fi
    rm -rf "$T"

    # --- NWP-20261201-17 (h60 #6): USER_ALL only when no other user has the package. ---
    # C1. both arms in one manifest: user 11 has com.shared and not com.solo
    newcase; manifest com.shared com.solo; rec 10.xml 11.xml; lists 11 com.shared
    reap_in "$sh"
    if [ "$RC" = 0 ] && pm_is 'uninstall --user 0 com.shared\nuninstall --user 10 com.shared\nuninstall com.solo\n'; then
      ok "$tg C1 a package another user has goes per-user, a package nobody else has goes USER_ALL"
    else no "$tg C1 wrong argv (rc=$RC, pm: $(show pm))"; fi
    if pmlist_is 'list packages --user 11\n'; then ok "$tg C1 the other user's listing is read once"
    else no "$tg C1 pm list calls: $(show pmlist)"; fi
    if grep -qF 'reap-stale-ondemand: 1 package(s) kept for another user, removed for user 0 and user 10 only (2 ok, 0 failed) (h60 #6)' "$T/log" \
       && [ "$(summaries)" = 1 ] && [ "$(warns)" = 0 ]; then
      ok "$tg C1 one summary line with its counts, no WARN"
    else no "$tg C1 log: $(show log)"; fi
    rm -rf "$T"
    # C1. a failed per-user call is counted and the loop goes on
    newcase; manifest com.shared com.solo; rec 11.xml; lists 11 com.shared
    PMFAIL=com.shared reap_in "$sh"
    if [ "$RC" = 0 ] && pm_has com.solo && grep -qF '(0 ok, 2 failed)' "$T/log"; then ok "$tg C1 failed per-user calls are counted and the loop continues"
    else no "$tg C1 failed per-user calls: rc=$RC, pm: $(show pm) log: $(show log)"; fi
    rm -rf "$T"

    # C2. user 11 lists neither package (the -a mutant lists both)
    newcase; manifest com.shared com.solo; rec 11.xml; lists 11 com.other
    reap_in "$sh"
    if pm_is 'uninstall com.shared\nuninstall com.solo\n' && [ "$(summaries)" = 0 ]; then ok "$tg C2 a listing that names neither package leaves both USER_ALL"
    else no "$tg C2 pm: $(show pm) log: $(show log)"; fi
    rm -rf "$T"

    # C3. records only for 0 and the uid, whose listings name com.solo: there is no other user
    newcase; manifest com.shared com.solo; rec 0.xml 10.xml; lists 0 com.solo; lists 10 com.solo
    reap_in "$sh"
    if pm_is 'uninstall com.shared\nuninstall com.solo\n'; then ok "$tg C3 user 0 and the uid do not count as another user"
    else no "$tg C3 pm: $(show pm)"; fi
    if pmlist_is '' && [ "$(summaries)" = 0 ] && [ "$(warns)" = 0 ]; then ok "$tg C3 no other user: no listing call and nothing new logged"
    else no "$tg C3 pm list calls: $(show pmlist) log: $(show log)"; fi
    rm -rf "$T"

    # C4. a bare directory is not a user; 11.xml.backup alone is; two record files are one user
    newcase; manifest com.shared com.solo; mkdir -p "$T/data/system/users/11"; lists 11 com.shared
    reap_in "$sh"
    if pm_is 'uninstall com.shared\nuninstall com.solo\n' && pmlist_is ''; then ok "$tg C4 a bare 11/ directory with no record file is not a user"
    else no "$tg C4 bare directory: pm: $(show pm) pm list: $(show pmlist)"; fi
    rm -rf "$T"
    newcase; manifest com.shared com.solo; rec 11.xml.backup; lists 11 com.shared
    reap_in "$sh"
    if pm_is 'uninstall --user 0 com.shared\nuninstall --user 10 com.shared\nuninstall com.solo\n'; then ok "$tg C4 11.xml.backup alone is a user"
    else no "$tg C4 11.xml.backup alone: pm: $(show pm)"; fi
    rm -rf "$T"
    newcase; manifest com.shared; rec 11.xml 11.xml.backup 11.xml.reservecopy; lists 11 com.shared
    reap_in "$sh"
    if pmlist_is 'list packages --user 11\n'; then ok "$tg C4 three record files of one user are one listing"
    else no "$tg C4 pm list calls: $(show pmlist)"; fi
    rm -rf "$T"

    # C5. a listing that fails, then one that is empty: UNKNOWN, so nothing goes USER_ALL
    for m in fail empty; do
      newcase; manifest com.shared com.solo; rec 11.xml
      if [ "$m" = fail ]; then : > "$T/listfail.11"; else : > "$T/pkgs.11"; fi
      reap_in "$sh"
      if pm_is 'uninstall --user 0 com.shared\nuninstall --user 10 com.shared\nuninstall --user 0 com.solo\nuninstall --user 10 com.solo\n'; then
        ok "$tg C5 $m listing: every package goes per-user, none USER_ALL"
      else no "$tg C5 $m listing: pm: $(show pm)"; fi
      if [ "$(warns)" = 1 ]; then ok "$tg C5 $m listing: the WARN line is logged once"
      else no "$tg C5 $m listing: $(warns) WARN line(s), log: $(show log)"; fi
      rm -rf "$T"
    done

    # C6. both per-user calls are bounded (NWP-20261130-06: by the batch's timeout -k 5 120, not one timeout each)
    newcase; manifest com.shared; rec 11.xml; lists 11 com.shared
    reap_in "$sh"
    if [ "$(grep -c . "$T/timeout")" = 1 ] && [ "$(batches)" = 1 ] && [ "$(grep -c '^exe ' "$T/pmpid")" = 2 ] \
       && pm_is 'uninstall --user 0 com.shared\nuninstall --user 10 com.shared\n'; then
      ok "$tg C6 both per-user calls run inside one batch under timeout -k 5 120"
    else no "$tg C6 timeout calls: $(show timeout) pids: $(show pmpid)"; fi
    rm -rf "$T"

    # C7. a manifest with no row that reaches removal makes no listing call
    newcase; printf '%b' "$(row com.in installed)\n$(row com.un ondemand)\n" > "$T/man"; mk user/10/com.un; rec 11.xml; lists 11 com.un
    reap_in "$sh"
    if pmlist_is '' && [ "$(pm_calls)" = 0 ]; then ok "$tg C7 installed and unparked rows make no listing call"
    else no "$tg C7 pm list calls: $(show pmlist) pm: $(show pm)"; fi
    rm -rf "$T"
    newcase; manifest com.shared; mk user/10/com.shared; rec 11.xml; lists 11 com.shared
    reap_in "$sh"
    if pmlist_is '' && [ "$(pm_calls)" = 0 ]; then ok "$tg C7 an unparked com.shared makes no pm call"
    else no "$tg C7 unparked com.shared: pm list: $(show pmlist) pm: $(show pm)"; fi
    rm -rf "$T"

    # C8. the log names no package of arm (a) and no other user. The id is 117 because $(date) can hold 11. com.solo's
    #     own line is today's per-package line.
    for m in listed unknown; do
      newcase; manifest com.shared com.solo; rec 117.xml
      if [ "$m" = listed ]; then lists 117 com.shared; else : > "$T/listfail.117"; fi
      reap_in "$sh"
      grep -v 'reap-stale-ondemand com\.solo (rc=' "$T/log" > "$T/rest"
      if [ "$(summaries)" = 1 ] && [ -s "$T/rest" ]; then ok "$tg C8 $m: the summary line is there to read"
      else no "$tg C8 $m: no summary line: $(show log)"; fi
      if grep -qE 'com\.shared|com\.solo|117' "$T/rest"; then no "$tg C8 $m: a new line names a package or the other user: $(show rest)"
      else ok "$tg C8 $m: the new lines name no package and no other user"; fi
      rm -rf "$T"
    done

    # --- NWP-20261130-06: the removals run in batches, each one bounded process. ---
    # B1. five packages, three USER_ALL and two kept for user 11: one batch process makes all 7 calls, it is not the
    #     reap's own shell, and its timeout line is the only one; the argv and order are main's; one count and one timing line
    newcase; manifest com.a com.k1 com.b com.k2 com.c; rec 11.xml; lists 11 com.k1 com.k2
    reap_in "$sh"
    n=$(pids | grep -c .)
    if [ "$RC" = 0 ] && pm_is 'uninstall com.a\nuninstall --user 0 com.k1\nuninstall --user 10 com.k1\nuninstall com.b\nuninstall --user 0 com.k2\nuninstall --user 10 com.k2\nuninstall com.c\n' \
       && [ "$n" = 1 ] && [ "$(grep -c '^exe ' "$T/pmpid")" = 7 ] && ! grep -qxF -- "exe $(cat "$T/mainpid")" "$T/pmpid" \
       && [ "$(grep -c . "$T/timeout")" = 1 ] && [ "$(batches)" = 1 ]; then
      ok "$tg B1 one bounded batch process makes the same 7 calls in manifest order, outside the reap's own shell"
    else no "$tg B1 $n process(es) made the calls (rc=$RC, pm: $(show pm) pids: $(show pmpid), reap's shell: $(cat "$T/mainpid"), timeout: $(show timeout))"; fi
    if [ "$(counted 5 0)" = 1 ] && [ "$(timed 5)" = 1 ] && grep -qF '(4 ok, 0 failed) (h60 #6)' "$T/log"; then
      ok "$tg B1 one count line (5 removed, 0 failed), one timing line (5 packages, 250 ms), h60 #6's counts unchanged"
    else no "$tg B1 count or timing line: $(show log)"; fi
    rm -rf "$T"

    # B2. one failure inside a batch, USER_ALL then per-user: it is counted, its rc logged, and the rest are removed
    PMFAIL=com.b run "$sh" "$(row com.a ondemand)\n$(row com.b ondemand)\n$(row com.c auto)\n"
    if [ "$RC" = 0 ] && pm_is 'uninstall com.a\nuninstall com.b\nuninstall com.c\n' && [ "$(counted 2 1)" = 1 ] \
       && grep -qF 'reap-stale-ondemand com.b (rc=1)' "$T/log" && [ "$(pids | grep -c .)" = 1 ]; then
      ok "$tg B2 a USER_ALL failure in the batch is counted (2 removed, 1 failed) and the rest are removed"
    else no "$tg B2 USER_ALL failure: rc=$RC, pm: $(show pm) log: $(show log)"; fi
    rm -rf "$T"
    newcase; manifest com.a com.k1 com.c; rec 11.xml; lists 11 com.k1
    PMFAIL=com.k1 reap_in "$sh"
    if [ "$RC" = 0 ] && pm_has com.a && pm_has com.c && [ "$(counted 2 1)" = 1 ] && grep -qF '(0 ok, 2 failed) (h60 #6)' "$T/log"; then
      ok "$tg B2 a kept package's failure in the batch is counted once and the rest are removed"
    else no "$tg B2 kept failure: rc=$RC, pm: $(show pm) log: $(show log)"; fi
    rm -rf "$T"

    # B3. installed and essential rows stay out of the batch
    run "$sh" "$(row com.in installed)\n$(row com.od ondemand)\n$(row com.es essential)\n$(row com.au auto)\n"
    if pm_is 'uninstall com.od\nuninstall com.au\n' && [ "$(timed 2)" = 1 ]; then ok "$tg B3 installed and essential rows stay out of the batch of 2"
    else no "$tg B3 pm: $(show pm) log: $(show log)"; fi
    rm -rf "$T"

    # B4. an unparked package stays out of the batch; the parked one is removed
    newcase; manifest com.un com.parked; mk user/10/com.un
    reap_in "$sh"
    if pm_is 'uninstall com.parked\n' && skipped com.un CE && [ "$(timed 1)" = 1 ] && [ "$(counted 1 0)" = 1 ]; then
      ok "$tg B4 the unparked package is skipped and the batch holds only the parked one"
    else no "$tg B4 pm: $(show pm) log: $(show log)"; fi
    rm -rf "$T"

    # B5. nothing to remove: no pm call, no batch, the timing line still says 0 packages
    run "$sh" "$(row com.in installed)\n"
    if [ "$(pm_calls)" = 0 ] && [ "$(grep -c . "$T/timeout")" = 0 ] && [ "$(timed 0)" = 1 ] && [ "$(counted 0 0)" = 1 ]; then
      ok "$tg B5 nothing to remove: no pm call, no batch, 0 packages timed"
    else no "$tg B5 pm: $(show pm) timeout: $(show timeout) log: $(show log)"; fi
    rm -rf "$T"

    # B6. the REAL timeout, 2 s, over a pm that stalls on com.h: com.a is removed, com.h and the kept com.k are not
    #     reached in time and count as failed, one WARN gives the counts, and the reap returns within the bound. The
    #     other user is 117, as in C8, so the WARN check cannot match a date.
    newcase; manifest com.a com.h com.k; rec 117.xml; lists 117 com.k
    printf 'com.h\n' > "$T/pmhang"; echo 2 > "$T/realtimeout"
    n=$(date +%s)
    reap_in "$sh"
    n=$(( $(date +%s) - n ))
    if [ "$RC" = 0 ] && pm_is 'uninstall com.a\nuninstall com.h\n' && [ "$(counted 1 2)" = 1 ] && [ "$n" -lt 10 ] \
       && grep -qF 'reap-stale-ondemand com.a (rc=0)' "$T/log" && grep -qF '(0 ok, 2 failed) (h60 #6)' "$T/log" \
       && [ "$(grep -cF 'WARN reap-stale-ondemand: a batch ended after 1 of 3 package(s) (rc=124) -- the rest count as failed (NWP-20261130-06)' "$T/log")" = 1 ]; then
      ok "$tg B6 a stalled batch is stopped by its bound; the entries it did not reach count as failed, with one WARN"
    else no "$tg B6 stalled batch: rc=$RC, ${n}s, pm: $(show pm) log: $(show log)"; fi
    if grep -qE 'WARN reap-stale-ondemand: a batch.*(com\.|117)' "$T/log"; then no "$tg B6 the WARN names a package or a user: $(show log)"
    else ok "$tg B6 the WARN names no package and no user"; fi
    rm -rf "$T"

    # B7. 17 packages are two batches of 16 and 1, two processes, in list order
    newcase; : > "$T/want"
    for n in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17; do row "com.p$n" ondemand >> "$T/man"; printf 'uninstall com.p%s\n' "$n" >> "$T/want"; done
    reap_in "$sh"
    if [ "$RC" = 0 ] && cmp -s "$T/want" "$T/pm" && [ "$(batches)" = 2 ] && [ "$(pids | grep -c .)" = 2 ] \
       && [ "$(head -16 "$T/pmpid" | sort -u | grep -c .)" = 1 ] && [ "$(counted 17 0)" = 1 ] && [ "$(timed 17)" = 1 ]; then
      ok "$tg B7 17 packages are two batches of 16 and 1, in list order"
    else no "$tg B7 rc=$RC, pm: $(show pm) timeout: $(show timeout) pids: $(show pmpid)"; fi
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
    local name="$1" expr="$2" m="$MD/m.sh" res rc bad="" t want=""
    # a name that ends with "(C<n>)" names the case that must convict it
    case "$name" in *" (C"[0-9]")"|*" (B"[0-9]")") want=${name##*\(}; want="${want%\)} " ;; esac
    sed "$expr" "$SUT" > "$m"
    if cmp -s "$SUT" "$m"; then echo "  MUTANT DID NOT APPLY  $name"; MISSED=$((MISSED+1)); return; fi
    # not quiet: a conviction needs rc 1 and a FAIL line under every shell's own tag, mksh's included
    res=$(suite "$m" 2>&1); rc=$?
    for t in $SHELLS; do
      case "$res" in *"  FAIL  [$t] $want"*) ;; *) bad="$bad $t" ;; esac
    done
    if [ "$rc" = 0 ]; then echo "  SURVIVED  $name"; MISSED=$((MISSED+1))
    elif [ "$rc" = 1 ] && [ -z "$bad" ]; then echo "  convicted $name"
    else echo "  NOT CONVICTED (rc $rc, no FAIL line under:${bad:- none})  $name"; MISSED=$((MISSED+1)); fi
  }
  mutant "mode case gains installed"      's/case "\$rmode" in ondemand|auto) ;;/case "$rmode" in ondemand|auto|installed) ;;/'
  mutant "mode filter removed"            '/case "\$rmode" in ondemand|auto)/d'
  mutant "name guard removed"             '/case "\$rpkg" in ""|\*\/\*|\*" "\*) continue;; esac/d'
  mutant "timeout dropped"                's/_r=\$(timeout -k 5 120 sh -c/_r=$(sh -c/'
  mutant "mode filter continue -> break"  's/\(case "\$rmode" in ondemand|auto) ;; \*) \)continue/\1break/'
  mutant "name guard continue -> break"   's/\(case "\$rpkg" in ""|\*\/\*|\*" "\*) \)continue/\1break/'
  mutant "CE check removed"               '/&& _vol=CE$/d'
  mutant "DE check removed"               '/&& _vol=DE$/d'
  mutant "data check removed"             '/&& _vol=data$/d'
  mutant "obb check removed"              '/&& _vol=obb$/d'
  mutant "uid guard removed"              '/case "\$uid" in ""|\*\[!0-9\]\*)/d'
  mutant "skip list appended"             's|mv -f "\$_tmp" "\$_out"|cat "$_tmp" >> "$_out"|'
  mutant "skip continue dropped"          '/continue   # NWP-20261125-01: no pm call for unparked data/d'
  mutant "copy dropped"                   's/if \[ -d "\$_dir" \]; then/if false; then/'
  mutant "copy written with no chown"     's/ && chown "\$_own:\$_own" "\$_ctmp"//'
  mutant "copy written with no relabel"   's/ && { restorecon -D "\$_ctmp" || :; }//'
  mutant "failed relabel drops the copy"  's/ && { restorecon -D "\$_ctmp" || :; }/ \&\& restorecon -D "$_ctmp"/'
  mutant "copy written with no chmod"     's/ && chmod 600 "\$_ctmp"//'
  mutant "copy written when dir absent"   's/if \[ -d "\$_dir" \]; then/if :; then/'
  mutant "copy holds the parked control"  's/printf .%s. "\$_skipped" >> "\$_ctmp"/{ printf "%s" "$_skipped"; printf "com.parked\\n"; } >> "$_ctmp"/'
  # NWP-20261201-17: the name of each mutant ends with the case that convicts it.
  OD='/^od_other_users() {$/,/^}$/'
  mutant "classification removed, always USER_ALL (C1)" 's/if \[ "\$_kp" = 1 \]; then/if false; then/'
  mutant "userdir_has_record test dropped (C4)"         "$OD"'{/userdir_has_record "\$_i" || continue/d;}'
  mutant "uid not skipped (C3)"                         "$OD"'{/\[ "\$_i" = "\$1" \] && continue/d;}'
  mutant "0 not skipped (C3)"                           "$OD"'{/\[ "\$_i" -lt 10 \] && continue/d;}'
  mutant "an id printed once per record file (C4)"      "$OD"'{/case "\$_seen" in/d;}'
  mutant "UNKNOWN taken as nobody has it (C5)"          's/^      _kp=\$_unk$/      _kp=0/'
  mutant "empty listing not UNKNOWN (C5)"               's/ && \[ -n "\$_lst" \]; then/; then/'
  mutant "--user 0 call deleted (C1)"                   's/pm uninstall --user 0 "\$p" <\/dev\/null >\/dev\/null 2>&1; a=\$?/a=0/'
  mutant "--user uid call deleted (C1)"                 's/pm uninstall --user "\$u" "\$p" <\/dev\/null >\/dev\/null 2>&1; echo "K \$a \$?"/echo "K $a 0"/'
  mutant "batch bound loses its kill grace (C6)"        's/timeout -k 5 120 sh -c/timeout 120 sh -c/'
  mutant "listing taken with -a (C2)"                   's/pm list packages --user "\$_ou"/pm list packages -a --user "$_ou"/'
  mutant "listing read per row (C1)"                    '/^        _rd=1$/d'
  # NWP-20261130-06: the batch. Each name ends with the case that convicts it.
  mutant "one process per package restored (B1)"        's/if \[ "\$_n" = 16 \]; then/if [ "$_n" = 1 ]; then/'
  mutant "removal back in the reap's own shell (B1)"    's/_r=\$(timeout -k 5 120 sh -c /_r=$(timeout -k 5 120 eval /; s/^u=\$1; log=\$2$/u=$uid; log=$LOG/; s/^done. sh "\$uid" "\$LOG" 2>>/done'"'"' 2>>/'
  mutant "batch timeout dropped (B1)"                   's/_r=\$(timeout -k 5 120 sh -c/_r=$(sh -c/'
  mutant "timing line dropped (B1)"                     '/package(s) in \$(( \$(_ms) - _t0 )) ms/d'
  mutant "count line dropped (B1)"                      '/removed, \$_bad failed (NWP-20261130-06)/d'
  mutant "USER_ALL failure swallowed (B2)"              's/A) if \[ "\$_a" = 0 \]; then/A) if :; then/'
  mutant "kept failure swallowed (B2)"                  's/if \[ "\$_a" = 0 \] && \[ "\$_b" = 0 \]; then/if :; then/'
  mutant "batch stops at the first failure (B2)"        's/echo "\[roamd\] reap-stale-ondemand \$p (rc=\$a)" >> "\$log"; echo "A \$a" ;;/echo "[roamd] reap-stale-ondemand $p (rc=$a)" >> "$log"; echo "A $a"; [ "$a" = 0 ] || exit 0 ;;/'
  mutant "filter dropped (B3)"                          '/case "\$rmode" in ondemand|auto)/d'
  mutant "unparked check dropped (B4)"                  '/continue   # NWP-20261125-01: no pm call for unparked data/d'
  mutant "unreached entries not counted (B6)"           '/case "\$_e" in K:\*) echo "K - -" ;; \*) echo "A -" ;; esac/d'
  mutant "incomplete batch not warned (B6)"             '/WARN reap-stale-ondemand: a batch ended after/d'
  mutant "last partial batch dropped (B7)"              's/\[ "\$_n" = 0 \] || od_reap_batch_run/[ "$_n" = 0 ] || :/'
  mutant "batch of 16 never flushed (B7)"               's/\(od_reap_batch_run "\$uid" "\$_n" "\$_c"\); _c=""; _n=0; fi/:; fi/'
  [ "$MISSED" -eq 0 ] || { echo "RESULT: FAIL ($MISSED mutant(s) not convicted)"; exit 1; }
fi
echo "RESULT: PASS"
