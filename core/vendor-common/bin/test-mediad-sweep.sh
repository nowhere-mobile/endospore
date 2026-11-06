#!/usr/bin/env bash
# test-mediad-sweep.sh [<nowhere_mediad.sh>] [--mutate] -- mediad's sweep-only mode and its start-time stale
# sweep are EXECUTED (NWP-20261022-16).
#
# WHY THIS IS COMMITTED. On Endospore, roamd's stop_mediad no longer unmounts (its confined domain lacks
# CAP_SYS_ADMIN): it removes mediad.req, drops $STATE/mediad.sweep, kicks mediad and reads /proc/mounts back. The
# SWEEP-ONLY MODE at the top of nowhere_mediad.sh is therefore how a sign-out detaches the on-demand media FUSE
# overlays and their .under binds, and a surviving mount is an amnesia failure (removeUser cannot delete through a
# mountpoint; a seal walk hangs on a dead-daemon mount). Three rules are load-bearing and were executed by no test:
#   - the sweep runs BEFORE the conf sourcing and the req read ("the marker means clean up, never serve"), so it
#     works with no credentials and with no req -- stop_mediad removes the req FIRST;
#   - each entry is classified by RE-READING /proc/mounts after a failed `umount -l` (one underlying mount appears
#     at several paths, so a sibling's failure is "already gone", not SWEEP-FAILED -- NWP-20260828-09); since
#     NWP-20261119-05 a failed entry is queued and ONE re-read after the loop classifies the whole queue;
#   - the marker, the list file and the pending files are removed on every path;
#   - a table that could not be READ (a failed read, or an empty one) is never reported as a clean sweep: the top
#     read logs SWEEP-UNREADABLE and the re-read after a failed umount counts the mount as "unverified", not
#     "already gone" (NWP-20261026-24; roamd's stop_mediad applies the same rule to its own read).
# The start path's stale sweep detaches ONLY this user's leftovers and decodes each path with unesc_mount
# (NWP-20260828-06: the escaped "\040" of a WhatsApp folder named a file that did not exist).
#
# NWP-20261109-02: every line that names a mount path prints it through qn as ONE quoted token (SWEEP-FAILED,
# stale overlay/bind detached, and their DETACH-FAILED lines), and umount's own stderr (`umount: <path>: <errno>`)
# no longer goes to the log: a failure line carries only the errno word, or `error`. mediad.log keeps a tail across
# every reap and log_scrub redacts quoted tokens only, so a bare folder name of a departed profile outlived the scrub
# and rode a later session's issue report (Q001 (e), docs/product-decisions.md). Q1-Q4 run the shipped LOG_SCRUB_SED
# (taken from nowhere_roamd.sh by name) over the log and demand that no part of the path survives.
#
# HOW. The pieces are extracted BY ANCHOR (EXTRACTION FAILED, exit 2, when an anchor moved or a block does not
# parse under `sh -n`), /proc/mounts is rewritten to a fixture file, and umount and date are PATH stubs. The stub
# umount succeeds unless the decoded path is listed in a fail file, and on success drops every fixture line that
# shares the detached line's DEVICE field -- so each fixture gives one underlying mount its own device field (m1,
# m2, ...) and one mount listed at three paths shares one (the script never reads that field; on a phone every
# overlay reads nowhere_media). Each block runs in a subshell, so its `exit 0` ends only that run, under every POSIX
# shell found (bash, and sh/dash/mksh where they are not bash). Cases 5 and 5b run the WHOLE script with every
# absolute path rewritten into the scratch root.
#
# A case may put its own `cat` (case_cat) or a umount that wrecks the fixture into the run, to make ONE read fail.
# A table is made unreadable by REPLACING the fixture file with a directory, never by chmod: a root runner ignores
# the mode bits.
#
# NWP-20261115-05: B1-B3 run the sweep against a table over 128 KiB under the device's printf limit (a printf
# stub in run_block: one argument over 131072 bytes fails with E2BIG, as /system/bin/printf does). P1/P2 must convict.
#
# NWP-20261119-05 (h49 #3): the sweep's work is linear in the mount count. The list holds every fuse.nowheremedia
# line before the .under binds, a failed umount reads nothing, and one re-read after the loop classifies the queue
# with two grep -f calls. W1 counts the table reads (case_cat's counter) for 60 folders: exactly two. W2 pins the
# order, W3 a pending entry that stays mounted, W4/W4b an unreadable final re-read, W5 a sweep with no failure (one
# read), W6 a re-read with no field 2, W7 (RF-001) many mounts that stay mounted beside many that detach: the traced
# commands after the loop (set -x, tracework) do not grow with the already-gone entries and grow by the same step for
# each further still-mounted one. The date stub prints 1000 for the first `date +%s` of a run and 1007 after, so
# every summary ends ` in 7s DATE`. Mutants M1-M7 (and M5b, the unreadable path) must convict.
#
# NWP-20261122-18: the start path's stale sweep reads the table ONCE (`_smt`) and keeps the status. SU1 dir (the
# table is a directory), SU1 status (case_cat prints the table and exits 1) and SU2 empty (a read that exits 0 and
# prints nothing) each log exactly one STALE-SWEEP-UNREADABLE line, call no umount, log no stale line and run to the
# end of the block. SU3 checks the source: the extracted block, comment lines dropped, names /proc/mounts once (the
# cat). C6 also demands no STALE-SWEEP-UNREADABLE line on a readable table. Mutants SM1-SM4 must convict.
#
# NWP-20261125-13: a sweep list the sweep cannot write is never a clean sweep. These cases run bash as --posix.
# U1: $SWEPT is a directory: one SWEEP-UNWRITABLE line, no summary, no umount, the marker and the other lists gone.
# U2: $PEND is a symlink to /dev/full (the full-tmpfs shape: the truncation succeeds, every write fails with ENOSPC
# and `[ -s ]` is false): two failed umounts count unverified, never nowhere. No other list may point at /dev/full:
# the block READS those, and a read of /dev/full never ends. U3: $STILL is a directory and the one failed umount stays
# listed: unverified, never gone and never dropped. U3b: as U3, but the umount stub removes the directory at the
# failure (AFTERFAIL=stillgone), so the later grep writes $STILL. Under dash a redirection error is status 2, which
# main already reads as an error, so U3 alone cannot convict U-M3 under dash; U3b does, under every shell. U4/U5:
# $PEND or $MNTSET is a directory: every pending entry unverified (today's result, pinned). Every planted directory
# holds one entry, because an empty btrfs directory has size 0 and `[ -s ]` would be false. EVERY plant case calls
# case_chmod, a no-op chmod on PATH: chmod follows U2's link, so a root runner would change /dev/full itself; and the
# block's `chmod 600` takes the search bit off a planted directory, so a non-root runner could not remove its entry
# (U3b's stub and the EXIT trap would both fail). c4x checks that the kept plant still has its search bit. Mutants
# U-M1..U-M4 must convict under every shell.
#
# This suite pins SHIPPED behaviour: its cases pass on main, except U1, U2, U3 (bash and mksh) and U3b, which fail on
# the code before NWP-20261125-13 by design. U4 and U5 pass there: they pin unchanged behaviour. What must fail is
# every mutant.
#
#   bash test-mediad-sweep.sh            # the cases
#   bash test-mediad-sweep.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_mediad.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# Shells: bash, plus sh/dash/mksh where they are a different interpreter (deduped by realpath).
SHELLS=""; SEEN=" "
for cand in bash sh dash mksh; do
  p=$(command -v "$cand" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$SEEN" in *" $r "*) continue ;; esac
  SEEN="$SEEN$r "; SHELLS="$SHELLS $p"
done
[ -n "$SHELLS" ] || { echo "no POSIX shell found" >&2; exit 2; }

# ---- extraction by anchor -------------------------------------------------------------------------------------
UNESC=$(awk 'index($0,"unesc_mount() {")==1{on=1} on{print} on&&$0=="}"{exit}' "$SUT")
QN=$(awk 'index($0,"qn() {")==1{on=1} on{print} on&&$0=="}"{exit}' "$SUT")
UERR=$(awk 'index($0,"umount_err() {")==1{on=1} on{print} on&&$0=="}"{exit}' "$SUT")
SWEEPBLK=$(awk '$0=="if [ -f \"$SWEEP\" ]; then"{on=1} on{print} on&&$0=="fi"{exit}' "$SUT")
STALEBLK=$(awk 'index($0,"_smt=$(cat /proc/mounts")==1{on=1} on{print} on&&$0=="unset _smt _smtrc"{exit}' "$SUT")

extract_fail() { echo "EXTRACTION FAILED: $1 in $SUT" >&2; exit 2; }
needs() { # needs <name> <text> <marker>...
  local what="$1" text="$2" mk; shift 2
  [ -n "$text" ] || extract_fail "$what (empty)"
  for mk in "$@"; do
    case "$text" in *"$mk"*) ;; *) extract_fail "$what (no '$mk')" ;; esac
  done
  printf '%s\n%s\n%s\n%s\n' "$UNESC" "$QN" "$UERR" "$text" | sh -n 2>/dev/null || extract_fail "$what (does not parse)"
}
[ -n "$UNESC" ] || extract_fail "unesc_mount"
case "$UNESC" in *sed*) ;; *) extract_fail "unesc_mount (no sed)" ;; esac
printf '%s\n' "$UNESC" | sh -n 2>/dev/null || extract_fail "unesc_mount (does not parse)"
[ -n "$QN" ] || extract_fail "qn"
case "$QN" in *sed*) ;; *) extract_fail "qn (no sed)" ;; esac
case "$SWEEPBLK$STALEBLK" in *umount_err*) [ -n "$UERR" ] || extract_fail "umount_err" ;; esac
needs "the sweep block" "$SWEEPBLK" 'mediad.sweep.list' 'sweep done:'
needs "the stale sweep" "$STALEBLK" 'stale overlay detached' 'stale bind detached' 'STALE-SWEEP-UNREADABLE'
case "$STALEBLK" in *"unset _smt _smtrc") ;; *) extract_fail "the stale sweep (no end)" ;; esac

# LOG_SCRUB_SED by name from roamd (beside this file, not $SUT: a mutant copy lives in $W), and a positive control.
ROAMD="$(dirname "$0")/nowhere_roamd.sh"
eval "$(grep -m1 '^LOG_SCRUB_SED=' "$ROAMD")"
[ -n "${LOG_SCRUB_SED:-}" ] || { echo "EXTRACTION FAILED: LOG_SCRUB_SED in $ROAMD" >&2; exit 2; }
[ "$(printf '%s\n' 'x "a b"' | sed -E "$LOG_SCRUB_SED")" = 'x "<name>"' ] \
  || { echo "EXTRACTION FAILED: LOG_SCRUB_SED does not redact a quoted token" >&2; exit 2; }
# test-log-name-scrub.sh's PRINT_SHIM, with one difference: each printf is `command printf` (NWP-20261115-05). bash
# and dash have no `print`; mksh (the device's sh) does. The shim stands in for mksh's builtin print, which nothing
# exec's and which has no argument length limit, so it must not reach run_block's printf stub (the device's limit).
PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then command printf "%s\n" "$*"; else command printf "%s" "$*"; fi; }'

# ---- stubs ----------------------------------------------------------------------------------------------------
mkdir -p "$W/stubbin"
cat > "$W/stubbin/umount" <<'EOF'
#!/bin/sh
# Stub umount. Encodes the path into the /proc/mounts escapes with its OWN sed -- never the SUT's unesc_mount --
# ONCE per call and compares raw fields, so a fixture of hundreds of lines forks no sed per line (W1).
for P; do :; done
# What toybox prints when umount fails, per the case: `umount: <path>: <errno>`, or the variants umount_err guards.
fail_out() {
  case "${UMOUNT_ERR:-}" in
    nocolon) printf 'Invalid argument\n' >&2 ;;
    path) printf 'umount: %s\n' "$P" >&2 ;;
    long) printf 'umount: %s: %s\n' "$P" "$(printf 'x%.0s' $(seq 1 90))" >&2 ;;
    *) printf 'umount: %s: Invalid argument\n' "$P" >&2 ;;
  esac
}
printf '%s\n' "$P" >> "$CALLS"
if [ -e "$LISTF" ]; then stat -c %a "$LISTF" >> "$MODEF"; fi
if [ -e "$PENDF" ]; then stat -c %a "$PENDF" >> "$PMODEF"; fi
E=$(printf '%s' "$P" | sed -e 's/\\/\\134/g' -e 's/ /\\040/g' -e 's/	/\\011/g')
hit=""
while read -r dev mnt rest; do
  if [ "$mnt" = "$E" ]; then hit="$dev"; break; fi
done < "$FIXTURE"
[ -n "$hit" ] || { fail_out; exit 1; }
if grep -qxF "$P" "$FAILF" 2>/dev/null; then
  # AFTERFAIL: make the NEXT read of the table fail (dir), come back empty with a good status (empty), or come back
  # readable and non-empty with no second field (nofield).
  case "${AFTERFAIL:-}" in
    dir) rm -f "$FIXTURE"; mkdir "$FIXTURE" ;;
    empty) : > "$FIXTURE" ;;
    nofield) printf 'x\n' > "$FIXTURE" ;;
    # stillgone (NWP-20261125-13): remove the planted $STILL directory and record that it is gone.
    stillgone) rm -rf "$ROOT/state/mediad.sweep.still" && [ ! -e "$ROOT/state/mediad.sweep.still" ] && : > "$ROOT/stillgone.ok" ;;
  esac
  fail_out; exit 1
fi
awk -v dev="$hit" '$1 != dev' "$FIXTURE" > "$FIXTURE.new" && mv "$FIXTURE.new" "$FIXTURE"
exit 0
EOF
# Stub date: `date +%s` prints 1000 on its first call in a run and 1007 after (the counter is read with `read`, never
# with a cat: case_cat counts every cat); any other call prints DATE.
cat > "$W/stubbin/date" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "+%s" ]; then
  n=0; [ -f "$DATECNT" ] && read -r n < "$DATECNT"
  n=$((n + 1)); echo "$n" > "$DATECNT"
  if [ "$n" -eq 1 ]; then echo 1000; else echo 1007; fi
  exit 0
fi
echo DATE
EOF
chmod +x "$W/stubbin/umount" "$W/stubbin/date"

# ---- helpers --------------------------------------------------------------------------------------------------
FAILS=0; CD=""; CASEBIN=""; AFTERFAIL=""; CATFROM=""; CATALT=""; UMOUNT_ERR=""; XT=""; SHOPT=""
ok() { [ -n "${QUIET:-}" ] || printf '  ok    %s\n' "$1"; }
no() { FAILS=$((FAILS + 1)); printf '  FAIL  %s\n' "$1"; }

# new_case -> CD: a scratch case dir with state/, an empty mounts fixture and empty record files.
new_case() {
  CD=$(mktemp -d -p "$W")
  mkdir -p "$CD/state"
  : > "$CD/mounts"; : > "$CD/calls"; : > "$CD/fail"; : > "$CD/modes"; : > "$CD/pmodes"
  : > "$CD/state/mediad.sweep"
  CASEBIN=""; AFTERFAIL=""; CATFROM=""; CATALT=""; UMOUNT_ERR=""; XT=""; SHOPT=""
}

# case_cat <from-call> [<alt-file>]: put a `cat` of this case's own on PATH for this case only. It prints the
# fixture and exits 0 until its <from-call>th call; from then on it prints <alt-file> (default: the fixture) and
# exits 1. The counter lives in the case dir; the stub reads with `read`, never with a cat.
case_cat() {
  CASEBIN="$CD/bin"; CATFROM="$1"; CATALT="${2:-$CD/mounts}"
  mkdir -p "$CASEBIN"; echo 0 > "$CD/catcnt"
  cat > "$CASEBIN/cat" <<'EOF'
#!/bin/sh
n=0; read -r n < "$CATCNT"
n=$((n + 1)); echo "$n" > "$CATCNT"
src="$FIXTURE"; [ "$n" -ge "$CATFROM" ] && src="$CATALT"
while IFS= read -r l || [ -n "$l" ]; do printf '%s\n' "$l"; done < "$src"
[ "$n" -ge "$CATFROM" ] && exit 1
exit 0
EOF
  chmod +x "$CASEBIN/cat"
}

# case_chmod (NWP-20261125-13): put a no-op `chmod` on PATH for this case only. Every plant case calls it (see the
# header): the block's `chmod 600` must not follow U2's /dev/full link or take the search bit off a planted directory.
case_chmod() {
  CASEBIN="$CD/bin"; mkdir -p "$CASEBIN"
  printf '#!/bin/sh\nexit 0\n' > "$CASEBIN/chmod"; chmod +x "$CASEBIN/chmod"
}

# plant_dir <name>: replace $STATE/<name> with a directory that holds one entry, so `[ -s ]` is true on every
# filesystem (an empty btrfs directory has size 0).
plant_dir() { mkdir "$CD/state/$1"; : > "$CD/state/$1/entry"; }

# mixed <stuck> <gone>: a fresh case of <stuck> layers whose umount fails and that stay mounted (one path each, in
# the fail file) and <gone> layers at three paths that detach, so each leaves two pending entries already gone. The
# block runs traced (set -x, to $CD/xtrace).
mixed() {
  local k
  new_case; XT="$CD/xtrace"
  for k in $(seq 1 "$2"); do
    printf 'g%s /data/user/10/com.x/files/G%s fuse.nowheremedia rw 0 0\n' "$k" "$k"
    printf 'g%s /data_mirror/data_ce/null/10/com.x/files/G%s fuse.nowheremedia rw 0 0\n' "$k" "$k"
    printf 'g%s /mnt/pass_through/0/emulated/10/com.x/files/G%s fuse.nowheremedia rw 0 0\n' "$k" "$k"
  done > "$CD/mounts"
  for k in $(seq 1 "$1"); do
    printf 's%s /data/user/10/com.y/files/S%s fuse.nowheremedia rw 0 0\n' "$k" "$k" >> "$CD/mounts"
    printf '/data/user/10/com.y/files/S%s\n' "$k" >> "$CD/fail"
  done
  printf '%s\n' '/dev/fuse /storage/emulated fuse rw 0 0' >> "$CD/mounts"
}

# tracework: the traced commands the block ran after its loop -- from the `[ -s <pending> ]` test to the summary
# echo. Every shell's xtrace prints one line per simple command; a count of lines is deterministic, a time is not.
tracework() {
  local line on=0 n=0
  while IFS= read -r line; do
    case "$line" in *"-s "*"/mediad.sweep.pending"*) on=1 ;; esac
    case "$line" in *"sweep done:"*) [ "$on" = 1 ] && break ;; esac
    [ "$on" = 1 ] && n=$((n + 1))
  done < "$CD/xtrace"
  printf '%s' "$n"
}

# unreadable: replace the fixture with a directory.
unreadable() { rm -f "$CD/mounts"; mkdir "$CD/mounts"; }

# run_block <shell> <block-text>: run a block in a subshell of that shell against $CD. The block runs under the
# device's printf limit (NWP-20261115-05): the printf stub is test-stop-mediad-verify.sh's.
run_block() {
  local sh="$1" text txt
  text=$(printf '%s\n' "$2" | sed "s#/proc/mounts#$CD/mounts#g")
  txt='umask 022
STATE="$ROOT/state"; LOG="$ROOT/log"; SWEEP="$STATE/mediad.sweep"
USERDIR=/data/user/10; MEDIADIR=/data/media/10; uid=10
# The device mksh has no printf builtin: printf goes through exec(2), and one argument over MAX_ARG_STRLEN (128 KB)
# fails with E2BIG. bash and dash run a builtin that has no limit, so every shell gets the device limit here.
printf() {
  local __pa
  for __pa in "$@"; do
    if [ "${#__pa}" -gt 131072 ]; then echo "printf: Argument list too long" >&2; return 126; fi
  done
  command printf "$@"
}
command -v print >/dev/null 2>&1 || eval "$PSHIM"
eval "$UNESC"
eval "$QN"
eval "$UERR"
if [ -n "${XT:-}" ]; then exec 2>>"$XT"; set -x; fi
eval "$BLK"'
  env PATH="${CASEBIN:+$CASEBIN:}$W/stubbin:$PATH" XT="$XT" AFTERFAIL="$AFTERFAIL" UMOUNT_ERR="$UMOUNT_ERR" PSHIM="$PRINT_SHIM" QN="$QN" UERR="$UERR" CATFROM="$CATFROM" CATALT="$CATALT" \
      CATCNT="$CD/catcnt" FIXTURE="$CD/mounts" CALLS="$CD/calls" FAILF="$CD/fail" \
      LISTF="$CD/state/mediad.sweep.list" MODEF="$CD/modes" PENDF="$CD/state/mediad.sweep.pending" PMODEF="$CD/pmodes" \
      DATECNT="$CD/datecnt" ROOT="$CD" UNESC="$UNESC" BLK="$text" \
      timeout 60 "$sh" $SHOPT -c "$txt" >/dev/null 2>&1
}
# SHOPT is unquoted on purpose: empty, it must vanish. The NWP-20261125-13 cases set it to --posix under bash.

logtext() { cat "$CD/log" 2>/dev/null; }
scrubbed() { sed -E "$LOG_SCRUB_SED" "$CD/log" 2>/dev/null; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# mounts <line>...: write the fixture (printf '%s\n' keeps \040 literal).
mounts() { printf '%s\n' "$@" > "$CD/mounts"; }

# bigpad: append three non-media lines of about 48000 bytes each, each with its own device field, so the table is
# over MAX_ARG_STRLEN (131072). A fixture under 140000 bytes proves nothing, so the suite stops there (exit 2).
bigpad() {
  local k pad sz
  pad=$(awk 'BEGIN { s = "x"; while (length(s) < 48000) s = s s; print substr(s, 1, 48000) }')
  for k in 1 2 3; do
    printf 'pad%s /mnt/pad%s tmpfs rw,%s 0 0\n' "$k" "$k" "$pad" >> "$CD/mounts"
  done
  sz=$(wc -c < "$CD/mounts")
  [ "$sz" -gt 140000 ] || { echo "FIXTURE FAILED: the padded table is $sz bytes, not over 140000" >&2; exit 2; }
}

# c4 <label> <shell>: the marker, the list and the pending files (NWP-20261119-05) are gone after the run.
c4() {
  local f left=""
  for f in mediad.sweep mediad.sweep.list mediad.sweep.pending mediad.sweep.pending.why mediad.sweep.mounted \
           mediad.sweep.still; do
    [ ! -e "$CD/state/$f" ] || left="$left $f"
  done
  if [ -z "$left" ]; then ok "C4 $1: marker, list and pending files removed ($2)"
  else no "C4 $1: survived:$left ($2)"; fi
}

# c4x <label> <shell> <kept>: c4, except that the planted <kept> may stay (`rm -f` cannot remove a directory). The
# kept plant must still have its search bit: a case that forgot case_chmod fails here, on a root runner too.
c4x() {
  local f left=""
  for f in mediad.sweep mediad.sweep.list mediad.sweep.pending mediad.sweep.pending.why mediad.sweep.mounted \
           mediad.sweep.still; do
    [ "$f" = "$3" ] && continue
    [ ! -e "$CD/state/$f" ] || left="$left $f"
  done
  if [ -z "$left" ]; then ok "C4 $1: marker, list and pending files removed ($2)"
  else no "C4 $1: survived:$left ($2)"; fi
  if [ -e "$CD/state/$3" ] && [ ! -x "$CD/state/$3" ]; then no "C4 $1: planted $3 lost its search bit ($2)"; fi
}

# readcount: how many times this case's counting cat (case_cat) ran.
readcount() { local n=; read -r n < "$CD/catcnt" 2>/dev/null; printf '%s' "${n:-0}"; }

# q3 <case> <label>: after a failed umount the whole log holds no unquoted /data/ (quoted tokens stripped first).
q3() {
  local rest
  rest=$(sed -E 's/"([^"\\]|\\.)*"//g' "$CD/log" 2>/dev/null)
  case "$rest" in
    */data/*) no "$1 an unquoted /data/ is in mediad.log ($2)" ;;
    *) ok "$1 no unquoted /data/ in mediad.log ($2)" ;;
  esac
}

# stage_script <shell> <R>: the whole script with every absolute path rewritten into R, and the print shim on line 2
# for a shell without a print builtin, as test-mediad-serve.sh's stage does; mksh keeps its own print.
stage_script() {
  local sh="$1" R="$2" shim=""
  mkdir -p "$R/run" "$R/stub" "$R/proc" "$R/data/nowhere/state" "$R/system/etc/nowhere"
  case "$("$sh" -c 'command -v print' 2>/dev/null)" in print) ;; *) shim="eval '$PRINT_SHIM'" ;; esac
  sed -e 's@/system/etc/nowhere/nowhere.conf@__R__/system/etc/nowhere/nowhere.conf@g' \
      -e 's@/system/bin/nowhere_agent@__R__/stub/nowhere_agent@g' \
      -e 's@/proc/mounts@__R__/proc/mounts@g' \
      -e 's@/data/@__R__/data/@g' \
      -e "s@__R__@$R@g" "$SUT" \
    | SHIM="$shim" awk 'NR==1 && ENVIRON["SHIM"] != "" {print; print ENVIRON["SHIM"]; next} {print}' > "$R/run/mediad.sh"
  printf '#!/bin/sh\n: > "%s/canary.agent"\n' "$R" > "$R/stub/nowhere_agent"
  chmod +x "$R/stub/nowhere_agent"
  printf ': > "%s/canary.conf"\n' "$R" > "$R/system/etc/nowhere/nowhere.conf"
  cp "$R/system/etc/nowhere/nowhere.conf" "$R/data/nowhere/nowhere.conf"
  printf '%s\n' 'm1 /data/user/10/com.x/files/DCIM fuse.nowheremedia rw 0 0' > "$R/proc/mounts"
  : > "$R/calls"; : > "$R/modes"
  : > "$R/data/nowhere/state/mediad.sweep"
}

run_script() { # run_script <shell> <R>
  ( cd "$2" && env -i PATH="$W/stubbin:/usr/bin:/bin" FIXTURE="$2/proc/mounts" CALLS="$2/calls" FAILF=/dev/null \
      LISTF="$2/data/nowhere/state/mediad.sweep.list" MODEF="$2/modes" \
      PENDF="$2/data/nowhere/state/mediad.sweep.pending" PMODEF="$2/pmodes" DATECNT="$2/datecnt" \
      timeout 60 "$1" "$2/run/mediad.sh" ) >/dev/null 2>&1
}

suite() {
  local sh label L R modes line bad want got rc S e n su
  echo "shells:$SHELLS"
  for sh in $SHELLS; do
    label=$(basename "$sh")

    # C1: one mount listed at three paths -> one detach, two already gone.
    new_case
    mounts 'm1 /data/user/10/com.x/files/DCIM fuse.nowheremedia rw 0 0' \
           'm1 /data_mirror/data_ce/null/10/com.x/files/DCIM fuse.nowheremedia rw 0 0' \
           'm1 /mnt/pass_through/0/emulated/10/com.x/files/DCIM fuse.nowheremedia rw 0 0' \
           '/dev/fuse /storage/emulated fuse rw 0 0'
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    if has "$L" 'sweep done: 1 detached, 2 already gone, 0 FAILED, 0 unverified'; then ok "C1 one mount at three paths: 1 detached, 2 already gone ($label)"
    else no "C1 summary is not '1 detached, 2 already gone, 0 FAILED, 0 unverified': $L ($label)"; fi
    if has "$L" 'SWEEP-FAILED'; then no "C1 a sibling path was called SWEEP-FAILED ($label)"; else ok "C1 no SWEEP-FAILED ($label)"; fi
    if [ "$(grep -c . "$CD/calls")" = 3 ]; then ok "C1 all three paths were tried ($label)"; else no "C1 umount call count is not 3 ($label)"; fi
    modes=$(cat "$CD/modes"); bad=""
    while read -r line; do [ "$line" = 600 ] || bad=x; done < "$CD/modes"
    if [ -n "$modes" ] && [ -z "$bad" ]; then ok "C4 the list file was 0600 while it existed ($label)"
    else no "C4 the list file mode was not 0600: '$modes' ($label)"; fi
    modes=$(cat "$CD/pmodes"); bad=""
    while read -r line; do [ "$line" = 600 ] || bad=x; done < "$CD/pmodes"
    if [ -n "$modes" ] && [ -z "$bad" ]; then ok "C4 the pending file was 0600 while it existed ($label)"
    else no "C4 the pending file mode was not 0600: '$modes' ($label)"; fi
    c4 C1 "$label"

    # C2: a umount that fails while its line stays -> SWEEP-FAILED once, 1 FAILED.
    new_case
    mounts 'm1 /data/user/10/com.y/files/Movies fuse.nowheremedia rw 0 0'
    printf '%s\n' '/data/user/10/com.y/files/Movies' > "$CD/fail"
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    want='[mediad] SWEEP-FAILED (still mounted): "/data/user/10/com.y/files/Movies" (Invalid argument)'
    got=$(grep -cxF "$want" "$CD/log")
    if [ "$got" = 1 ]; then ok "C2 SWEEP-FAILED named once ($label)"; else no "C2 SWEEP-FAILED lines: $got: $(printf %s "$L" | tr '\n' ' ') ($label)"; fi
    if has "$L" 'sweep done: 0 detached, 0 already gone, 1 FAILED, 0 unverified'; then ok "C2 summary 1 FAILED ($label)"
    else no "C2 summary is not '0 detached, 0 already gone, 1 FAILED, 0 unverified': $L ($label)"; fi
    c4 C2 "$label"

    # C3: a WhatsApp folder (\040) -> umount gets the decoded path, never the escaped one.
    new_case
    mounts 'm1 /data/media/10/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp\040Images fuse.nowheremedia rw 0 0' \
           'm2 /data/user/10/com.nowhere.chooser/files/.nowhere-media-ext/.under/WhatsApp\040Images ext4 rw 0 0'
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    if grep -qxF '/data/media/10/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images' "$CD/calls" \
       && grep -qxF '/data/user/10/com.nowhere.chooser/files/.nowhere-media-ext/.under/WhatsApp Images' "$CD/calls"; then
      ok "C3 umount got the decoded WhatsApp Images paths ($label)"
    else no "C3 the decoded paths were not unmounted: $(cat "$CD/calls") ($label)"; fi
    if grep -qF '\040' "$CD/calls"; then no "C3 umount was handed the escaped path ($label)"; else ok "C3 never the escaped path ($label)"; fi
    if has "$L" 'sweep done: 2 detached, 0 already gone, 0 FAILED, 0 unverified'; then ok "C3 summary 2 detached ($label)"
    else no "C3 summary is not '2 detached, 0 already gone, 0 FAILED, 0 unverified': $L ($label)"; fi
    c4 C3 "$label"

    # B1 (NWP-20261115-05): three media mounts in a table over 128 KiB, under the device's printf limit -> all three
    # detached. The list read used to pass the table to grep as one printf argument: E2BIG, an empty list, 0 detached.
    new_case
    mounts 'm1 /data/user/10/com.x/files/A fuse.nowheremedia rw 0 0' \
           'm2 /data/user/10/com.x/files/B fuse.nowheremedia rw 0 0' \
           'm3 /data/user/10/com.x/files/C fuse.nowheremedia rw 0 0'
    bigpad
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    if [ "$(grep -c . "$CD/calls")" = 3 ]; then ok "B1 three umount calls ($label)"; else no "B1 umount call count is not 3 ($label)"; fi
    if has "$L" 'sweep done: 3 detached, 0 already gone, 0 FAILED, 0 unverified'; then ok "B1 summary 3 detached ($label)"
    else no "B1 summary is not '3 detached, 0 already gone, 0 FAILED, 0 unverified' ($label)"; fi
    n=$(grep -c ' fuse.nowheremedia ' "$CD/mounts")
    if [ "$n" = 0 ]; then ok "B1 no media line left in the table ($label)"; else no "B1 $n media line(s) left in the table ($label)"; fi
    c4 B1 "$label"

    # B2: a still-mounted overlay in a table over 128 KiB -> SWEEP-FAILED names it once. The re-read used to read
    # E2BIG as "not listed" and count the stuck mount as already gone.
    new_case
    mounts 'm1 /data/user/10/com.x/files/A fuse.nowheremedia rw 0 0'
    bigpad
    printf '%s\n' '/data/user/10/com.x/files/A' > "$CD/fail"
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    want='[mediad] SWEEP-FAILED (still mounted): "/data/user/10/com.x/files/A" (Invalid argument)'
    if [ "$(grep -cxF "$want" "$CD/log")" = 1 ] && [ "$(grep -c 'SWEEP-FAILED' "$CD/log")" = 1 ]; then ok "B2 SWEEP-FAILED names the quoted path once ($label)"
    else no "B2 not exactly one SWEEP-FAILED line naming the quoted path ($label)"; fi
    if has "$L" 'sweep done: 0 detached, 0 already gone, 1 FAILED, 0 unverified'; then ok "B2 summary 1 FAILED ($label)"
    else no "B2 summary is not '0 detached, 0 already gone, 1 FAILED, 0 unverified' ($label)"; fi
    c4 B2 "$label"

    # B3: C1's one mount at three paths, in a table over 128 KiB -> 1 detached, 2 already gone. This fails on the old
    # code too (its list read got nothing: 0 detached); it pins the sibling rule under a big table, not a control.
    new_case
    mounts 'm1 /data/user/10/com.x/files/DCIM fuse.nowheremedia rw 0 0' \
           'm1 /data_mirror/data_ce/null/10/com.x/files/DCIM fuse.nowheremedia rw 0 0' \
           'm1 /mnt/pass_through/0/emulated/10/com.x/files/DCIM fuse.nowheremedia rw 0 0'
    bigpad
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    if has "$L" 'sweep done: 1 detached, 2 already gone, 0 FAILED, 0 unverified'; then ok "B3 summary 1 detached, 2 already gone ($label)"
    else no "B3 summary is not '1 detached, 2 already gone, 0 FAILED, 0 unverified' ($label)"; fi
    if has "$L" 'SWEEP-FAILED'; then no "B3 a sibling path was called SWEEP-FAILED ($label)"; else ok "B3 no SWEEP-FAILED ($label)"; fi
    c4 B3 "$label"

    # W1 (NWP-20261119-05, h49 #3): 60 folders, each one layer at three paths (one device field) plus its own .under
    # bind (a second device). The sweep reads the table exactly twice: once at the top, once after the loop. The old
    # loop re-read it for each of the 120 sibling failures (121 reads).
    new_case; case_cat 100000
    for n in $(seq 1 60); do
      printf 'm%s /data/user/10/com.x/files/F%s fuse.nowheremedia rw 0 0\n' "$n" "$n"
      printf 'm%s /data_mirror/data_ce/null/10/com.x/files/F%s fuse.nowheremedia rw 0 0\n' "$n" "$n"
      printf 'm%s /mnt/pass_through/0/emulated/10/com.x/files/F%s fuse.nowheremedia rw 0 0\n' "$n" "$n"
      printf 'b%s /data/user/10/com.nowhere.chooser/files/.nowhere-media/.under/F%s ext4 rw 0 0\n' "$n" "$n"
    done > "$CD/mounts"
    printf '%s\n' '/dev/fuse /storage/emulated fuse rw 0 0' >> "$CD/mounts"
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    got=$(readcount)
    if [ "$got" = 2 ]; then ok "W1 60 folders: the table was read twice ($label)"
    else no "W1 60 folders: the table was read $got times, not 2 ($label)"; fi
    if [ "$(grep -cxF '[mediad] sweep done: 120 detached, 120 already gone, 0 FAILED, 0 unverified in 7s DATE' "$CD/log")" = 1 ]; then
      ok "W1 summary 120 detached, 120 already gone, in 7s ($label)"
    else no "W1 summary is not '120 detached, 120 already gone, 0 FAILED, 0 unverified in 7s DATE' ($label)"; fi
    if has "$L" 'SWEEP-FAILED'; then no "W1 a sibling path was called SWEEP-FAILED ($label)"; else ok "W1 no SWEEP-FAILED ($label)"; fi
    if [ "$(grep -c . "$CD/calls")" = 240 ]; then ok "W1 every one of the 240 entries was tried once ($label)"
    else no "W1 umount call count is not 240 ($label)"; fi
    c4 W1 "$label"

    # W2: every .under bind is listed BEFORE its layer in the table; the sweep still detaches every layer first.
    new_case
    for n in 1 2 3; do
      printf 'b%s /data/user/10/com.nowhere.chooser/files/.nowhere-media/.under/F%s ext4 rw 0 0\n' "$n" "$n"
      printf 'm%s /data/user/10/com.x/files/F%s fuse.nowheremedia rw 0 0\n' "$n" "$n"
      printf 'm%s /data_mirror/data_ce/null/10/com.x/files/F%s fuse.nowheremedia rw 0 0\n' "$n" "$n"
      printf 'm%s /mnt/pass_through/0/emulated/10/com.x/files/F%s fuse.nowheremedia rw 0 0\n' "$n" "$n"
    done > "$CD/mounts"
    printf '%s\n' '/dev/fuse /storage/emulated fuse rw 0 0' >> "$CD/mounts"
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    e=$(grep -vn '/\.under/' "$CD/calls" | sed -n '$s/:.*//p')
    n=$(grep -n '/\.under/' "$CD/calls" | sed -n '1s/:.*//p')
    if [ -n "$e" ] && [ -n "$n" ] && [ "$e" -lt "$n" ]; then ok "W2 every layer path was tried before the first .under bind ($label)"
    else no "W2 a .under bind was tried before a layer path (last layer call ${e:-none}, first bind call ${n:-none}) ($label)"; fi
    if has "$L" 'sweep done: 6 detached, 6 already gone, 0 FAILED, 0 unverified'; then ok "W2 summary 6 detached, 6 already gone ($label)"
    else no "W2 summary is not '6 detached, 6 already gone, 0 FAILED, 0 unverified': $L ($label)"; fi
    c4 W2 "$label"

    # W3: a failed umount that stays mounted, beside one layer at three paths: SWEEP-FAILED once, its siblings gone,
    # and still ONE re-read.
    new_case; case_cat 100000
    mounts 'm1 /data/user/10/com.y/files/Movies fuse.nowheremedia rw 0 0' \
           'm2 /data/user/10/com.x/files/DCIM fuse.nowheremedia rw 0 0' \
           'm2 /data_mirror/data_ce/null/10/com.x/files/DCIM fuse.nowheremedia rw 0 0' \
           'm2 /mnt/pass_through/0/emulated/10/com.x/files/DCIM fuse.nowheremedia rw 0 0'
    printf '%s\n' '/data/user/10/com.y/files/Movies' > "$CD/fail"
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    want='[mediad] SWEEP-FAILED (still mounted): "/data/user/10/com.y/files/Movies" (Invalid argument)'
    if [ "$(grep -cxF "$want" "$CD/log")" = 1 ] && [ "$(grep -c 'SWEEP-FAILED' "$CD/log")" = 1 ]; then ok "W3 the stuck mount is SWEEP-FAILED once ($label)"
    else no "W3 not exactly one SWEEP-FAILED line naming the stuck mount ($label)"; fi
    if has "$L" 'sweep done: 1 detached, 2 already gone, 1 FAILED, 0 unverified'; then ok "W3 summary 1 detached, 2 already gone, 1 FAILED ($label)"
    else no "W3 summary is not '1 detached, 2 already gone, 1 FAILED, 0 unverified' ($label)"; fi
    got=$(readcount)
    if [ "$got" = 2 ]; then ok "W3 the table was read twice ($label)"; else no "W3 the table was read $got times, not 2 ($label)"; fi
    c4 W3 "$label"

    # W4/W4b: the final re-read is unreadable (a directory) or empty: every pending entry is unverified, never gone.
    for e in dir empty; do
      new_case
      mounts 'm2 /data/user/10/com.x/files/DCIM fuse.nowheremedia rw 0 0' \
             'm2 /data_mirror/data_ce/null/10/com.x/files/DCIM fuse.nowheremedia rw 0 0' \
             'm2 /mnt/pass_through/0/emulated/10/com.x/files/DCIM fuse.nowheremedia rw 0 0' \
             'm1 /data/user/10/com.y/files/Movies fuse.nowheremedia rw 0 0'
      printf '%s\n' '/data/user/10/com.y/files/Movies' > "$CD/fail"; AFTERFAIL="$e"
      run_block "$sh" "$SWEEPBLK"; L=$(logtext)
      n=W4; [ "$e" = dir ] || n=W4b
      if has "$L" 'sweep done: 1 detached, 0 already gone, 0 FAILED, 3 unverified'; then ok "$n final re-read $e: 3 unverified ($label)"
      else no "$n summary is not '1 detached, 0 already gone, 0 FAILED, 3 unverified' ($label)"; fi
      if has "$L" 'SWEEP-FAILED'; then no "$n a path was named SWEEP-FAILED ($label)"; else ok "$n no SWEEP-FAILED ($label)"; fi
      c4 "$n" "$label"
    done

    # W5: no umount fails: the table is read once, and the summary carries the time.
    new_case; case_cat 100000
    mounts 'm1 /data/user/10/com.x/files/A fuse.nowheremedia rw 0 0' \
           'm2 /data/user/10/com.x/files/B fuse.nowheremedia rw 0 0' \
           'b1 /data/user/10/com.nowhere.chooser/files/.nowhere-media/.under/A ext4 rw 0 0'
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    got=$(readcount)
    if [ "$got" = 1 ]; then ok "W5 no failure: the table was read once ($label)"; else no "W5 the table was read $got times, not 1 ($label)"; fi
    if [ "$(grep -cxF '[mediad] sweep done: 3 detached, 0 already gone, 0 FAILED, 0 unverified in 7s DATE' "$CD/log")" = 1 ]; then
      ok "W5 summary 3 detached in 7s ($label)"
    else no "W5 summary is not '3 detached, 0 already gone, 0 FAILED, 0 unverified in 7s DATE' ($label)"; fi
    c4 W5 "$label"

    # W7 (RF-001): the REPORTING is linear too. Many layers fail and stay mounted while others detach and leave
    # their sibling entries pending. The first cut walked every pending entry and searched the whole still-mounted
    # list for it: P x S work. Now the work after the loop must not grow with the already-gone entries at all, and
    # must grow by the same amount for each further still-mounted mount (traced commands, tracework).
    mixed 40 120
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    if has "$L" 'sweep done: 120 detached, 240 already gone, 40 FAILED, 0 unverified'; then
      ok "W7 40 stuck, 120 detached: 240 already gone, 40 FAILED ($label)"
    else no "W7 summary is not '120 detached, 240 already gone, 40 FAILED, 0 unverified' ($label)"; fi
    got=0
    for n in $(seq 1 40); do
      want="[mediad] SWEEP-FAILED (still mounted): \"/data/user/10/com.y/files/S$n\" (Invalid argument)"
      [ "$(grep -cxF "$want" "$CD/log")" = 1 ] && got=$((got + 1))
    done
    if [ "$got" = 40 ] && [ "$(grep -c 'SWEEP-FAILED' "$CD/log")" = 40 ]; then ok "W7 each stuck mount is SWEEP-FAILED once, quoted ($label)"
    else no "W7 not exactly one quoted SWEEP-FAILED line for each of the 40 stuck mounts ($label)"; fi
    c4 W7 "$label"
    mixed 10 5; run_block "$sh" "$SWEEPBLK"; S=$(tracework)
    mixed 10 50; run_block "$sh" "$SWEEPBLK"; e=$(tracework)
    if [ "$S" -gt 0 ] && [ "$S" = "$e" ]; then ok "W7 the reporting work does not grow with 90 more already-gone entries ($label)"
    else no "W7 the reporting work grew with the already-gone entries: $S then $e traced commands ($label)"; fi
    mixed 20 5; run_block "$sh" "$SWEEPBLK"; n=$(tracework)
    mixed 30 5; run_block "$sh" "$SWEEPBLK"; got=$(tracework)
    if [ "$n" -gt "$S" ] && [ $((n - S)) = $((got - n)) ]; then ok "W7 each further still-mounted mount adds the same reporting work ($label)"
    else no "W7 the reporting work is not linear in the still-mounted count: $S, $n, $got traced commands ($label)"; fi

    # W6: the final re-read is readable and non-empty but has no second field: nothing proven, 1 unverified.
    new_case
    mounts 'm1 /data/user/10/com.y/files/Movies fuse.nowheremedia rw 0 0'
    printf '%s\n' '/data/user/10/com.y/files/Movies' > "$CD/fail"; AFTERFAIL=nofield
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    if has "$L" 'sweep done: 0 detached, 0 already gone, 0 FAILED, 1 unverified'; then ok "W6 no field 2: 1 unverified ($label)"
    else no "W6 summary is not '0 detached, 0 already gone, 0 FAILED, 1 unverified' ($label)"; fi
    c4 W6 "$label"

    # C7: a completely EMPTY table is UNREADABLE (roamd's rule: no Linux system has an empty mounts table).
    # It used to be "all zero" -- NWP-20261026-24 changed that expectation deliberately.
    new_case
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    if has "$L" 'SWEEP-UNREADABLE' && ! has "$L" 'sweep done:'; then ok "C7 empty table: SWEEP-UNREADABLE, no summary ($label)"
    else no "C7 an empty table was not called unreadable: $L ($label)"; fi
    c4 C7 "$label"

    # C7b: a table with only non-media lines is READABLE: all zero.
    new_case
    mounts '/dev/fuse /storage/emulated fuse rw 0 0' 'tmpfs /dev tmpfs rw 0 0'
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    if has "$L" 'sweep done: 0 detached, 0 already gone, 0 FAILED, 0 unverified' && ! has "$L" 'SWEEP-UNREADABLE'; then ok "C7b non-media table: all zero ($label)"
    else no "C7b summary is not all zero: $L ($label)"; fi
    c4 C7b "$label"

    # CA: the table cannot be read and prints nothing (the fixture is a directory).
    new_case
    mounts 'm1 /data/user/10/com.x/files/DCIM fuse.nowheremedia rw 0 0'; unreadable
    run_block "$sh" "$SWEEPBLK"; rc=$?; L=$(logtext)
    if has "$L" 'SWEEP-UNREADABLE' && ! has "$L" 'sweep done:'; then ok "CA unreadable table: SWEEP-UNREADABLE, no summary ($label)"
    else no "CA the log is wrong: $L ($label)"; fi
    if [ ! -s "$CD/calls" ]; then ok "CA no umount was called ($label)"; else no "CA umount was called: $(cat "$CD/calls") ($label)"; fi
    if [ "$rc" = 0 ]; then ok "CA exit 0 ($label)"; else no "CA the exit was $rc ($label)"; fi
    c4 CA "$label"

    # CA2: a read that failed AFTER printing a media line is just as unreadable.
    new_case
    mounts 'm1 /data/user/10/com.x/files/DCIM fuse.nowheremedia rw 0 0'; case_cat 1
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    if has "$L" 'SWEEP-UNREADABLE' && ! has "$L" 'sweep done:'; then ok "CA2 failed read with output: SWEEP-UNREADABLE ($label)"
    else no "CA2 the log is wrong: $L ($label)"; fi
    if [ ! -s "$CD/calls" ]; then ok "CA2 no umount was called ($label)"; else no "CA2 umount was called: $(cat "$CD/calls") ($label)"; fi
    c4 CA2 "$label"

    # CC: a failed umount whose re-read fails without output (the fixture became a directory): unverified.
    new_case
    mounts 'm1 /data/user/10/com.y/files/Movies fuse.nowheremedia rw 0 0'
    printf '%s\n' '/data/user/10/com.y/files/Movies' > "$CD/fail"; AFTERFAIL=dir
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    if has "$L" 'sweep done: 0 detached, 0 already gone, 0 FAILED, 1 unverified'; then ok "CC failed re-read, no output: 1 unverified ($label)"
    else no "CC summary is not '1 unverified': $L ($label)"; fi
    if has "$L" 'SWEEP-FAILED'; then no "CC a path was named SWEEP-FAILED ($label)"; else ok "CC no path logged ($label)"; fi
    c4 CC "$label"

    # CC2: a failed umount whose re-read exits 1 but prints a table WITHOUT the mount: unverified, not gone.
    new_case
    mounts 'm1 /data/user/10/com.y/files/Movies fuse.nowheremedia rw 0 0'
    printf '%s\n' '/data/user/10/com.y/files/Movies' > "$CD/fail"
    printf '%s\n' '/dev/fuse /storage/emulated fuse rw 0 0' > "$CD/after"; case_cat 2 "$CD/after"
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    if has "$L" 'sweep done: 0 detached, 0 already gone, 0 FAILED, 1 unverified'; then ok "CC2 failed re-read with output: 1 unverified ($label)"
    else no "CC2 summary is not '1 unverified': $L ($label)"; fi
    c4 CC2 "$label"

    # CC3: a failed umount whose re-read EXITS 0 BUT PRINTS NOTHING (the fixture was emptied): unverified.
    # (CC's directory fails the read's status AND prints nothing, so it cannot tell the empty check from the
    # status check; this case and CC2 each isolate one.)
    new_case
    mounts 'm1 /data/user/10/com.y/files/Movies fuse.nowheremedia rw 0 0'
    printf '%s\n' '/data/user/10/com.y/files/Movies' > "$CD/fail"; AFTERFAIL=empty
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    if has "$L" 'sweep done: 0 detached, 0 already gone, 0 FAILED, 1 unverified'; then ok "CC3 empty re-read, good status: 1 unverified ($label)"
    else no "CC3 summary is not '1 unverified': $L ($label)"; fi
    c4 CC3 "$label"

    # U1-U5 (NWP-20261125-13): a sweep list the sweep cannot write. bash runs as --posix.
    # U1: the sweep list is a directory: SWEEP-UNWRITABLE, nothing detached, the marker and the other lists removed.
    new_case; [ "$label" = bash ] && SHOPT=--posix
    mounts 'm1 /data/user/10/com.x/files/DCIM fuse.nowheremedia rw 0 0'
    plant_dir mediad.sweep.list; case_chmod
    run_block "$sh" "$SWEEPBLK"; rc=$?; L=$(logtext)
    if [ "$(grep -c 'SWEEP-UNWRITABLE: the sweep list could not be written -- nothing detached' "$CD/log" 2>/dev/null)" = 1 ]; then
      ok "U1 one SWEEP-UNWRITABLE line ($label)"
    else no "U1 not one SWEEP-UNWRITABLE line ($label)"; fi
    if has "$L" 'sweep done:'; then no "U1 an unwritable sweep list logged a summary ($label)"; else ok "U1 no summary ($label)"; fi
    if [ ! -s "$CD/calls" ]; then ok "U1 no umount was called ($label)"; else no "U1 umount was called ($label)"; fi
    if [ "$rc" = 0 ]; then ok "U1 exit 0 ($label)"; else no "U1 the exit was $rc ($label)"; fi
    c4x U1 "$label" mediad.sweep.list

    # U2: the queue exists but every write to it fails (a symlink to /dev/full). Two umounts fail, one detaches.
    new_case; [ "$label" = bash ] && SHOPT=--posix
    mounts 'm1 /data/user/10/com.x/files/A fuse.nowheremedia rw 0 0' \
           'm2 /data/user/10/com.y/files/B fuse.nowheremedia rw 0 0' \
           'm3 /data/user/10/com.y/files/C fuse.nowheremedia rw 0 0'
    printf '%s\n' '/data/user/10/com.y/files/B' '/data/user/10/com.y/files/C' > "$CD/fail"
    ln -s /dev/full "$CD/state/mediad.sweep.pending"; case_chmod
    run_block "$sh" "$SWEEPBLK"; L=$(logtext)
    if has "$L" 'sweep done: 1 detached, 0 already gone, 0 FAILED, 2 unverified'; then ok "U2 a queue that cannot be written: 2 unverified ($label)"
    else no "U2 summary is not '1 detached, 0 already gone, 0 FAILED, 2 unverified' ($label)"; fi
    if has "$L" 'SWEEP-FAILED'; then no "U2 a path was named SWEEP-FAILED ($label)"; else ok "U2 no SWEEP-FAILED ($label)"; fi
    if [ -c /dev/full ]; then ok "U2 /dev/full is still a character device ($label)"; else no "U2 /dev/full was changed ($label)"; fi
    c4 U2 "$label"

    # U3: the still-mounted list is a directory, and the one failed umount stays listed: unverified, never dropped.
    # U3b: the same, but the umount stub removes the directory at the failure, so the later grep writes the list.
    for e in U3 U3b; do
      new_case; [ "$label" = bash ] && SHOPT=--posix
      mounts 'm1 /data/user/10/com.y/files/Movies fuse.nowheremedia rw 0 0'
      printf '%s\n' '/data/user/10/com.y/files/Movies' > "$CD/fail"
      plant_dir mediad.sweep.still; case_chmod
      [ "$e" = U3b ] && AFTERFAIL=stillgone
      run_block "$sh" "$SWEEPBLK"; L=$(logtext)
      if has "$L" 'sweep done: 0 detached, 0 already gone, 0 FAILED, 1 unverified'; then ok "$e an unwritable still-mounted list: 1 unverified ($label)"
      else no "$e summary is not '0 detached, 0 already gone, 0 FAILED, 1 unverified' ($label)"; fi
      if has "$L" 'SWEEP-FAILED'; then no "$e a path was named SWEEP-FAILED ($label)"; else ok "$e no SWEEP-FAILED ($label)"; fi
      if [ "$e" = U3b ]; then
        if [ -e "$CD/stillgone.ok" ]; then ok "U3b the stub removed the still-mounted directory ($label)"
        else no "U3b the still-mounted directory survived the failing umount ($label)"; fi
        c4 U3b "$label"
      else
        c4x U3 "$label" mediad.sweep.still
      fi
    done

    # U4/U5: the queue or the re-read's mount set is a directory: every pending entry unverified (today's result).
    for e in 'U4 mediad.sweep.pending' 'U5 mediad.sweep.mounted'; do
      new_case; [ "$label" = bash ] && SHOPT=--posix
      mounts 'm1 /data/user/10/com.y/files/Movies fuse.nowheremedia rw 0 0'
      printf '%s\n' '/data/user/10/com.y/files/Movies' > "$CD/fail"
      plant_dir "${e#* }"; case_chmod
      run_block "$sh" "$SWEEPBLK"; L=$(logtext)
      if has "$L" 'sweep done: 0 detached, 0 already gone, 0 FAILED, 1 unverified'; then ok "${e% *} an unwritable ${e#* }: 1 unverified ($label)"
      else no "${e% *} summary is not '0 detached, 0 already gone, 0 FAILED, 1 unverified' ($label)"; fi
      if has "$L" 'SWEEP-FAILED'; then no "${e% *} a path was named SWEEP-FAILED ($label)"; else ok "${e% *} no SWEEP-FAILED ($label)"; fi
      c4x "${e% *}" "$label" "${e#* }"
    done

    # C6: the start path detaches ONLY user 10's leftovers.
    new_case
    mounts 'm1 /data/user/10/com.x/files/DCIM fuse.nowheremedia rw 0 0' \
           'm2 /data/media/10/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp\040Images fuse.nowheremedia rw 0 0' \
           'm3 /data/user/10/com.nowhere.chooser/files/.nowhere-media/.under/DCIM ext4 rw 0 0' \
           'm4 /data/user/10==deleted==/com.nowhere.chooser/files/.nowhere-media/.under/DCIM ext4 rw 0 0' \
           'm5 /data/user/11/com.x/files/DCIM fuse.nowheremedia rw 0 0' \
           'm6 /data/user/11/com.nowhere.chooser/files/.nowhere-media/.under/DCIM ext4 rw 0 0' \
           'm7 /data/user/110/com.x/files/DCIM fuse.nowheremedia rw 0 0' \
           'm8 /data/user/110/com.nowhere.chooser/files/.nowhere-media/.under/DCIM ext4 rw 0 0' \
           '/dev/fuse /storage/emulated fuse rw 0 0'
    run_block "$sh" "$STALEBLK"; L=$(logtext)
    want=$(printf '%s\n' '/data/media/10/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images' \
             '/data/user/10/com.nowhere.chooser/files/.nowhere-media/.under/DCIM' \
             '/data/user/10/com.x/files/DCIM' \
             '/data/user/10==deleted==/com.nowhere.chooser/files/.nowhere-media/.under/DCIM' | sort)
    got=$(sort "$CD/calls")
    if [ "$got" = "$want" ]; then ok "C6 exactly user 10's four mounts were detached ($label)"
    else no "C6 detached set differs: $got ($label)"; fi
    if [ "$(grep -c '^m[5678] ' "$CD/mounts")" = 4 ] && grep -q '^/dev/fuse ' "$CD/mounts"; then ok "C6 user 11, user 110 and /storage/emulated left mounted ($label)"
    else no "C6 another user's mount was detached ($label)"; fi
    if [ "$(grep -c 'stale overlay detached' "$CD/log")" = 2 ] && [ "$(grep -c 'stale bind detached' "$CD/log")" = 2 ] \
       && ! has "$L" 'DETACH-FAILED'; then ok "C6 two overlays and two binds logged ($label)"
    else no "C6 the stale log is wrong: $L ($label)"; fi
    if [ "$(grep -c 'stale overlay detached: "/data/' "$CD/log")" = 2 ] && [ "$(grep -c 'stale bind detached: "/data/' "$CD/log")" = 2 ]; then
      ok "C6 each stale line holds a quoted path ($label)"
    else no "C6 a stale line holds a bare path ($label)"; fi
    if has "$L" 'STALE-SWEEP-UNREADABLE'; then no "C6 STALE-SWEEP-UNREADABLE on a readable table ($label)"
    else ok "C6 no STALE-SWEEP-UNREADABLE on a readable table ($label)"; fi

    # SU1/SU2 (NWP-20261122-18): a stale-sweep read that failed or printed nothing logs STALE-SWEEP-UNREADABLE once,
    # detaches nothing, logs no stale line and runs to its end (a marker after the block). Each table holds a user-10
    # overlay and a user-10 .under bind, so a sweep that read it would detach both.
    for su in 'SU1 dir' 'SU1 status' 'SU2 empty'; do
      new_case
      case "$su" in
        'SU1 dir') mounts 'm1 /data/user/10/com.x/files/DCIM fuse.nowheremedia rw 0 0' \
                          'm2 /data/user/10/com.nowhere.chooser/files/.nowhere-media/.under/DCIM ext4 rw 0 0'
                   unreadable ;;
        'SU1 status') mounts 'm1 /data/user/10/com.x/files/DCIM fuse.nowheremedia rw 0 0' \
                             'm2 /data/user/10/com.nowhere.chooser/files/.nowhere-media/.under/DCIM ext4 rw 0 0'
                      case_cat 1 ;;
        'SU2 empty') ;;
      esac
      run_block "$sh" "$STALEBLK
: > \"\$ROOT/reached\""
      if [ "$(grep -c 'STALE-SWEEP-UNREADABLE' "$CD/log" 2>/dev/null)" = 1 ]; then ok "$su: one STALE-SWEEP-UNREADABLE line ($label)"
      else no "$su: not one STALE-SWEEP-UNREADABLE line ($label)"; fi
      if [ -s "$CD/calls" ]; then no "$su: umount was called ($label)"; else ok "$su: no umount call ($label)"; fi
      if grep -q -e 'stale overlay detached' -e 'stale bind detached' "$CD/log" 2>/dev/null; then no "$su: a stale line was logged ($label)"
      else ok "$su: no stale line logged ($label)"; fi
      if [ -e "$CD/reached" ]; then ok "$su: the block ran to its end ($label)"; else no "$su: the block did not run to its end ($label)"; fi
    done

    # SU3 (NWP-20261122-18): the stale sweep reads /proc/mounts once, through its kept-status cat; neither loop
    # reads the table again on its own.
    n=$(printf '%s\n' "$STALEBLK" | grep -v '^[[:space:]]*#' | grep -o '/proc/mounts' | wc -l)
    if [ "$((n))" -eq 1 ]; then ok "SU3 the stale sweep names /proc/mounts once ($label)"
    else no "SU3 the stale sweep names /proc/mounts $((n)) times ($label)"; fi

    # Q1: a failed detach that stays mounted, in a folder the user named with spaces and quotes.
    new_case
    mounts 'm1 /data/media/10/Pictures/Trip\040"A"\040one fuse.nowheremedia rw 0 0'
    printf '%s\n' '/data/media/10/Pictures/Trip "A" one' > "$CD/fail"
    run_block "$sh" "$SWEEPBLK"
    want='[mediad] SWEEP-FAILED (still mounted): "/data/media/10/Pictures/Trip \"A\" one" (Invalid argument)'
    if [ "$(grep -cxF "$want" "$CD/log")" = 1 ]; then ok "Q1 the SWEEP-FAILED line holds the quoted path and the errno word ($label)"
    else no "Q1 the SWEEP-FAILED line is not the quoted path + errno ($label)"; fi
    if grep -qxF '[mediad] sweep done: 0 detached, 0 already gone, 1 FAILED, 0 unverified in 7s DATE' "$CD/log"; then ok "Q1 summary 1 FAILED ($label)"
    else no "Q1 summary is not '0 detached, 0 already gone, 1 FAILED, 0 unverified' ($label)"; fi
    S=$(scrubbed)
    case "$S" in *Trip*|*/data/media/10/Pictures*) no "Q1 the scrubbed log still holds the folder ($label)" ;; *) ok "Q1 the scrubbed log holds none of the folder ($label)" ;; esac
    q3 Q1 "$label"

    # Q2: the start path: a detached overlay, a failed overlay and a failed bind each log a quoted path.
    new_case
    mounts 'm1 /data/user/10/com.x/files/DCIM\040Old fuse.nowheremedia rw 0 0' \
           'm2 /data/media/10/DCIM/Trip\040Overlay fuse.nowheremedia rw 0 0' \
           'm3 /data/user/10/com.nowhere.chooser/files/.nowhere-media/.under/Bind\040Folder ext4 rw 0 0'
    printf '%s\n' '/data/media/10/DCIM/Trip Overlay' '/data/user/10/com.nowhere.chooser/files/.nowhere-media/.under/Bind Folder' > "$CD/fail"
    run_block "$sh" "$STALEBLK"
    for want in '[mediad] stale overlay detached: "/data/user/10/com.x/files/DCIM Old"' \
                '[mediad] STALE-OVERLAY-DETACH-FAILED: "/data/media/10/DCIM/Trip Overlay" (Invalid argument)' \
                '[mediad] STALE-BIND-DETACH-FAILED: "/data/user/10/com.nowhere.chooser/files/.nowhere-media/.under/Bind Folder" (Invalid argument)'; do
      if [ "$(grep -cxF "$want" "$CD/log")" = 1 ]; then ok "Q2 logged once: ${want%%\"*} ($label)"
      else no "Q2 not logged exactly once: ${want%%\"*} ($label)"; fi
    done
    S=$(scrubbed)
    case "$S" in *"DCIM Old"*|*"Trip Overlay"*|*"Bind Folder"*|*DCIM*|*Trip*|*Bind*) no "Q2 the scrubbed log still holds a folder ($label)" ;; *) ok "Q2 the scrubbed log holds none of the folders ($label)" ;; esac
    q3 Q2 "$label"

    # Q4: an umount error with no ": ", one that is only a path, and one past 80 bytes all read `error`.
    for e in nocolon path long; do
      new_case
      mounts 'm1 /data/user/10/com.y/files/Movies fuse.nowheremedia rw 0 0'
      printf '%s\n' '/data/user/10/com.y/files/Movies' > "$CD/fail"; UMOUNT_ERR="$e"
      run_block "$sh" "$SWEEPBLK"
      want='[mediad] SWEEP-FAILED (still mounted): "/data/user/10/com.y/files/Movies" (error)'
      if [ "$(grep -cxF "$want" "$CD/log")" = 1 ]; then ok "Q4 $e: the line ends (error) ($label)"
      else no "Q4 $e: the line does not end (error) ($label)"; fi
      q3 "Q4 $e" "$label"
    done

    # C5: the WHOLE script, marker AND a req -> only the sweep runs.
    R=$(mktemp -d -p "$W"); stage_script "$sh" "$R"
    printf 'x\nx\n10\n\n' > "$R/data/nowhere/state/mediad.req"; cp "$R/data/nowhere/state/mediad.req" "$R/req.orig"
    run_script "$sh" "$R"; L=$(cat "$R/data/nowhere/mediad.log" 2>/dev/null)
    if cmp -s "$R/req.orig" "$R/data/nowhere/state/mediad.req"; then ok "C5 the req is untouched ($label)"; else no "C5 the req was consumed ($label)"; fi
    if [ -e "$R/canary.conf" ]; then no "C5 a conf was sourced before the sweep ($label)"; else ok "C5 no conf sourced ($label)"; fi
    if [ -e "$R/canary.agent" ]; then no "C5 the agent was exec'd ($label)"; else ok "C5 the agent was never exec'd ($label)"; fi
    if [ -e "$R/data/nowhere/state/mediad.sweep" ]; then no "C5 the marker survived ($label)"; else ok "C5 marker gone ($label)"; fi
    if has "$L" 'sweep done: 1 detached' && ! has "$L" '[mediad] start'; then ok "C5 only the sweep ran ($label)"
    else no "C5 the log is wrong: $L ($label)"; fi

    # C5b: marker and NO req -- the real sign-out shape (stop_mediad removed the req first).
    R=$(mktemp -d -p "$W"); stage_script "$sh" "$R"
    run_script "$sh" "$R"; L=$(cat "$R/data/nowhere/mediad.log" 2>/dev/null)
    if has "$L" 'sweep done:'; then ok "C5b sweep ran with no req ($label)"; else no "C5b no sweep summary: $L ($label)"; fi
    if [ -e "$R/data/nowhere/state/mediad.sweep" ]; then no "C5b the marker survived ($label)"; else ok "C5b marker gone ($label)"; fi
    if has "$L" '[mediad] no req'; then no "C5b the script reached the req read ($label)"; else ok "C5b never reached 'no req' ($label)"; fi
    if [ -e "$R/canary.conf" ] || [ -e "$R/canary.agent" ]; then no "C5b a conf or the agent ran ($label)"; else ok "C5b no conf, no agent ($label)"; fi
  done
}

echo "== $SUT"
suite
if [ "$FAILS" -gt 0 ]; then echo "FAILED: $FAILS check(s)"; exit 1; fi
if [ "$MUTATE" != yes ]; then echo "PASS: mediad sweep cases"; exit 0; fi

# ---- mutants --------------------------------------------------------------------------------------------------
echo "== mutations (each must be CONVICTED)"
MFAILS=0
# mutate <label> <expected-case-label>... -- <sed-program | python>: the copy is $MUT, built by the caller.
convict() { # convict <label> <copy> <expected>...
  local label="$1" copy="$2" out rc e miss=""; shift 2
  if cmp -s "$SUT" "$copy"; then echo "  INERT     $label -- the mutation changed nothing"; MFAILS=$((MFAILS + 1)); return; fi
  out=$(TMPDIR="$W" bash "$0" "$copy" 2>&1); rc=$?
  if [ "$rc" -eq 2 ]; then echo "  BROKEN    $label -- the mutant no longer extracts or parses"; MFAILS=$((MFAILS + 1)); return; fi
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $label"; MFAILS=$((MFAILS + 1)); return; fi
  for e in "$@"; do
    case "$out" in *"FAIL  $e "*) ;; *) miss="$miss $e" ;; esac
  done
  if [ -n "$miss" ]; then echo "  UNCONVICTED $label -- it failed, but not on:$miss"; MFAILS=$((MFAILS + 1)); return; fi
  echo "  convicted $label"
}
sedmut() { # sedmut <label> <sed-program> <expected>...
  local label="$1" prog="$2" copy; shift 2
  copy=$(mktemp -p "$W")
  sed -e "$prog" "$SUT" > "$copy"
  convict "$label" "$copy" "$@"
}

# NWP-20261119-05: the re-read's verdict is the two grep -f calls; dropping it makes every pending entry FAILED.
sedmut 'the re-read dropped (every failed umount is FAILED)' \
  '/^if \[ -f "\$SWEEP" \]; then$/,/^fi$/{s/_gone=\$(grep -cvxF -f "\$MNTSET" "\$PEND")/_gone=0/;s/grep -F -f "\$MNTSET" "\$PENDWHY" > "\$STILL"/cp "$PENDWHY" "$STILL"/;}' C1
sedmut 'the escaped path unmounted in the sweep' \
  '/^if \[ -f "\$SWEEP" \]; then$/,/^fi$/s/if _ue=\$(umount -l "\$m" 2>&1); then/if _ue=$(umount -l "$mnt" 2>\&1); then/' C3
# The top read's and the re-read's checks are one line each, with their own variables, so each mutant touches one.
sedmut 'S1 the top read status ignored (empty check kept)' \
  's/if \[ "\$_mtrc" -ne 0 \] || \[ -z "\$_mt" \]; then/if [ -z "$_mt" ]; then/' CA2
sedmut 'S2 an empty table treated as readable' \
  's/if \[ "\$_mtrc" -ne 0 \] || \[ -z "\$_mt" \]; then/if [ "$_mtrc" -ne 0 ]; then/' C7
sedmut 'S3 the re-read status ignored (empty check kept)' \
  's/if \[ "\$_rrrc" -ne 0 \] || \[ -z "\$_rr" \]; then/if [ -z "$_rr" ]; then/' CC2
sedmut 'S4 the marker rm skipped on the unreadable path' '/^    rm -f "\$SWEEP"$/d' C4
# NWP-20261119-05: an empty re-read also gives an empty $MNTSET, which the empty-pattern guard counts unverified, so
# the empty check alone is now an EQUIVALENT mutant. S5 removes both: the empty check and the guard.
sedmut 'S5 the re-read empty check removed (status kept)' \
  's/if \[ "\$_rrrc" -ne 0 \] || \[ -z "\$_rr" \]; then/if [ "$_rrrc" -ne 0 ]; then/;s/if \[ -s "\$MNTSET" \]; then/if true; then/' CC3
sedmut 'the marker rm removed' '/^  rm -f "\$SWEEP"$/d' C4
sedmut "the stale sweep's per-user filter widened" \
  's#"\$USERDIR"/\*|"\$MEDIADIR"/\*)#/data/user/*|"$MEDIADIR"/*)#' C6

# failed_on <output> <case> <shell>: true when ONE line of <output> is `  FAIL  <case> ... (<shell>)` -- the case
# and the shell tag on the same line, the tag at its end. A case pattern's `*` runs across newlines, so matching the
# whole output let a bash FAIL followed by an mksh `ok` line pass for mksh.
failed_on() {
  local line
  while IFS= read -r line; do
    case "$line" in "  FAIL  $2 "*"($3)") return 0 ;; esac
  done <<EOF
$1
EOF
  return 1
}
# The scoring itself is checked: a FAIL under one shell must not convict another that passed, whichever comes first.
_mixed='  FAIL  Q1 quoted path (bash)
  ok    Q1 quoted path (mksh)'
if ! failed_on "$_mixed" 'Q1 quoted' bash || failed_on "$_mixed" 'Q1 quoted' mksh; then
  echo "  BROKEN    failed_on lets one shell's FAIL convict another"; MFAILS=$((MFAILS + 1))
fi
_mixed='  ok    Q1 quoted path (bash)
  FAIL  Q1 quoted path (mksh)'
if failed_on "$_mixed" 'Q1 quoted' bash || ! failed_on "$_mixed" 'Q1 quoted' mksh; then
  echo "  BROKEN    failed_on lets one shell's FAIL convict another"; MFAILS=$((MFAILS + 1))
fi

# convict_each <label> <copy> <case>...: like convict, but EVERY shell found must fail EVERY named case on its own
# line (`  FAIL  <case> ... (<shell>)`): mksh reads a non-number in `[ x -lt N ]` as 0 where bash and dash error, so
# a mutant convicted under one shell says nothing about another. The new cases' FAIL lines hold no log text.
convict_each() {
  local label="$1" copy="$2" out rc e sh l miss=""; shift 2
  if cmp -s "$SUT" "$copy"; then echo "  INERT     $label -- the mutation changed nothing"; MFAILS=$((MFAILS + 1)); return; fi
  out=$(TMPDIR="$W" bash "$0" "$copy" 2>&1); rc=$?
  if [ "$rc" -eq 2 ]; then echo "  BROKEN    $label -- the mutant no longer extracts or parses"; MFAILS=$((MFAILS + 1)); return; fi
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $label"; MFAILS=$((MFAILS + 1)); return; fi
  for sh in $SHELLS; do
    l=$(basename "$sh")
    for e in "$@"; do
      failed_on "$out" "$e" "$l" || miss="$miss $e/$l"
    done
  done
  if [ -n "$miss" ]; then echo "  UNCONVICTED $label -- it failed, but not on:$miss"; MFAILS=$((MFAILS + 1)); return; fi
  echo "  convicted $label (every shell)"
}
sedmut_each() { # sedmut_each <label> <sed-program> <case>...
  local label="$1" prog="$2" copy; shift 2
  copy=$(mktemp -p "$W")
  sed -e "$prog" "$SUT" > "$copy"
  convict_each "$label" "$copy" "$@"
}

# NWP-20261109-02: the mount-path lines and the umount capture.
sedmut_each 'NWP-20261109-02 S1 SWEEP-FAILED prints the bare path' \
  's/SWEEP-FAILED (still mounted): \$(qn "\$m")/SWEEP-FAILED (still mounted): $m/' C2 Q1 'Q1 an unquoted'
sedmut_each 'NWP-20261109-02 S2 stale overlay detached prints the bare path' \
  's/stale overlay detached: \$(qn "\$m")/stale overlay detached: $m/' C6 Q2
sedmut_each 'NWP-20261109-02 S3 STALE-BIND-DETACH-FAILED prints the bare path' \
  's/STALE-BIND-DETACH-FAILED: \$(qn "\$m")/STALE-BIND-DETACH-FAILED: $m/' Q2
sedmut_each 'NWP-20261109-02 S4 the sweep umount appends its stderr to the log again' \
  '/^if \[ -f "\$SWEEP" \]; then$/,/^fi$/s/if _ue=\$(umount -l "\$m" 2>&1); then/if umount -l "$m" 2>> "$LOG"; then/' Q1 'Q1 an unquoted'
sedmut_each 'NWP-20261109-02 S5 <err> keeps the whole stderr line' \
  "s/^  printf '%s' \"\$e\"\$/  printf '%s' \"\$1\"/" Q1 'Q1 an unquoted'
# NWP-20261115-05: both reads of the table reach grep through the print builtin, never as a printf argument.
sedmut_each 'NWP-20261115-05 P1 the list read goes through printf again' \
  '/^if \[ -f "\$SWEEP" \]; then$/,/^fi$/s/^  print -r -- "\$_mt" |/  printf '"'"'%s\\n'"'"' "$_mt" |/' B1 B2 B3
sedmut_each 'NWP-20261115-05 P2 the re-read goes through printf again' \
  '/^if \[ -f "\$SWEEP" \]; then$/,/^fi$/s/print -r -- "\$_rr" |/printf '"'"'%s\\n'"'"' "$_rr" |/' B2 B3

# NWP-20261119-05 (h49 #3): pymut_each <label> <old> <new> <case>... -- an exact text edit that must match ONCE in
# the SUT (no match, or more than one, is BROKEN, never a pass), convicted under every shell.
pymut_each() {
  local label="$1" old="$2" new="$3" copy; shift 3
  copy=$(mktemp -p "$W")
  if python3 -I -c '
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
if t.count(old) != 1:
    sys.exit(1)
open(dst, "w").write(t.replace(old, new))
' "$SUT" "$copy" "$old" "$new"; then convict_each "$label" "$copy" "$@"
  else echo "  BROKEN    $label -- the text to mutate is not in the script exactly once"; MFAILS=$((MFAILS + 1)); fi
}
pymut_each 'M1 the per-failure table read restored inside the loop' \
'        n_pend=$((n_pend + 1))
' '        n_pend=$((n_pend + 1))
        _rx=$(cat /proc/mounts 2>>"$LOG")
' W1 W3
pymut_each 'M2 the list in table order' \
'  print -r -- "$_mt" | grep -e " fuse.nowheremedia " > "$SWEPT"
  print -r -- "$_mt" | grep -v -e " fuse.nowheremedia " | grep -e "/.nowhere-media[^/]*/.under/" >> "$SWEPT"
' '  print -r -- "$_mt" | grep -e " fuse.nowheremedia " -e "/.nowhere-media[^/]*/.under/" > "$SWEPT"
' W2
pymut_each 'M3 a still-mounted pending entry counted gone' \
'_gone=$(grep -cvxF -f "$MNTSET" "$PEND"); _grc=$?     # pending entries the kernel no longer lists
        grep -F -f "$MNTSET" "$PENDWHY" > "$STILL"; _src=$?' '_gone=$n_pend; _grc=$?
        : > "$STILL"; _src=$?' W3
pymut_each 'M4 an unreadable final re-read counted gone' \
'    if [ "$_rrrc" -ne 0 ] || [ -z "$_rr" ]; then
      n_unk=$((n_unk + n_pend))
' '    if [ "$_rrrc" -ne 0 ] || [ -z "$_rr" ]; then
      n_gone=$((n_gone + n_pend))
' W4 W4b
pymut_each 'M5 the pending file not removed on the end path' \
'
  rm -f "$PEND" "$PENDWHY" "$MNTSET" "$STILL"
' '
  rm -f "$PENDWHY" "$MNTSET" "$STILL"
' 'C4 W5:'
pymut_each 'M5b the pending file not removed on the unreadable path' \
'nothing detached $(date)" >> "$LOG"
    rm -f "$SWEPT"
    rm -f "$PEND" "$PENDWHY" "$MNTSET" "$STILL"
' 'nothing detached $(date)" >> "$LOG"
    rm -f "$SWEPT"
    rm -f "$PENDWHY" "$MNTSET" "$STILL"
' 'C4 CA:'
pymut_each 'M7 the reporting searches the whole still-mounted list for each pending entry (RF-001)' \
'        while read -r k w; do
          m=$(unesc_mount "$k")
          n_fail=$((n_fail + 1))
          print -r -- "[mediad] SWEEP-FAILED (still mounted): $(qn "$m") ($w)" >> "$LOG"
        done < "$STILL"
' '        _still=$(grep -F -f "$MNTSET" "$PENDWHY"); _nl="
"
        while read -r k w; do
          case "$_nl$_still$_nl" in
            *"$_nl $k $w$_nl"*)
              m=$(unesc_mount "$k")
              n_fail=$((n_fail + 1))
              print -r -- "[mediad] SWEEP-FAILED (still mounted): $(qn "$m") ($w)" >> "$LOG"
              ;;
          esac
        done < "$PENDWHY"
' 'W7 the reporting work grew'
pymut_each 'M6 the empty-pattern guard removed' \
'      if [ -s "$MNTSET" ]; then
' '      if true; then
' W6
# NWP-20261125-13: a sweep list the sweep cannot write is never a clean sweep.
pymut_each 'U-M1 the SWEPT status check dropped' \
'  if [ "$_swrc" -ne 0 ]; then
' '  if false; then
' U1
pymut_each 'U-M2 the mid-loop queue-write check dropped' \
'      if print -r -- " $mnt " >> "$PEND" && print -r -- " $mnt $(umount_err "$_ue")" >> "$PENDWHY"; then
        n_pend=$((n_pend + 1))
      else
        n_unk=$((n_unk + 1)); _qbad=1
      fi
' '      print -r -- " $mnt " >> "$PEND"
      print -r -- " $mnt $(umount_err "$_ue")" >> "$PENDWHY"
      n_pend=$((n_pend + 1))
' U2
pymut_each 'U-M3 the STILL status check dropped' \
'[ "$_src" -gt 1 ] || [ "$_strc" -ne 0 ]; then' '[ "$_src" -gt 1 ]; then' U3b
pymut_each 'U-M4 the SWEEP-UNWRITABLE arm keeps the marker' \
'nothing detached (NWP-20261125-13) $(date)" >> "$LOG"
    rm -f "$SWEPT"
    rm -f "$PEND" "$PENDWHY" "$MNTSET" "$STILL"
    rm -f "$SWEEP"
' 'nothing detached (NWP-20261125-13) $(date)" >> "$LOG"
    rm -f "$SWEPT"
    rm -f "$PEND" "$PENDWHY" "$MNTSET" "$STILL"
' 'C4 U1:'
# NWP-20261122-18: the start path's stale sweep and its one kept-status read.
pymut_each 'SM1 (task M1) the stale read status ignored' \
'_smt=$(cat /proc/mounts 2>>"$LOG"); _smtrc=$?
' '_smt=$(cat /proc/mounts 2>>"$LOG"); _smtrc=0
' 'SU1 status:'
pymut_each 'SM2 (task M2) the stale read empty check dropped' \
'if [ "$_smtrc" -ne 0 ] || [ -z "$_smt" ]; then
' 'if [ "$_smtrc" -ne 0 ]; then
' 'SU2 empty:'
pymut_each 'SM3 (task M3) the overlay loop reads /proc/mounts again' \
'  print -r -- "$_smt" | grep -e " fuse.nowheremedia " | while' \
'  grep " fuse.nowheremedia " /proc/mounts 2>/dev/null | while' SU3
pymut_each 'SM4 (task M4) STALE-SWEEP-UNREADABLE logged on a readable table' \
'if [ "$_smtrc" -ne 0 ] || [ -z "$_smt" ]; then
  echo "[mediad] STALE-SWEEP-UNREADABLE: the mount table could not be read -- no stale overlay or bind was checked $(date)" >> "$LOG"
else
' 'echo "[mediad] STALE-SWEEP-UNREADABLE: the mount table could not be read -- no stale overlay or bind was checked $(date)" >> "$LOG"
if [ "$_smtrc" -ne 0 ] || [ -z "$_smt" ]; then
  :
else
' 'C6 STALE-SWEEP-UNREADABLE'

copy=$(mktemp -p "$W")
if python3 -I - "$SUT" "$copy" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split("\n")
try:
    a = lines.index('if [ -f "$SWEEP" ]; then')
    b = a + 1 + lines[a + 1:].index("fi")
    c = next(i for i, l in enumerate(lines) if l.startswith('rm -f "$REQ"'))
except (ValueError, StopIteration):
    sys.exit(1)
if c < b:
    sys.exit(1)
blk = lines[a:b + 1]
out = lines[:a] + lines[b + 1:c + 1] + blk + lines[c + 1:]
open(dst, "w").write("\n".join(out))
PY
then convict 'the sweep moved below the req read' "$copy" C5 C5b
else echo "  BROKEN    the sweep moved below the req read -- an anchor is missing"; MFAILS=$((MFAILS + 1)); fi

if [ "$MFAILS" -gt 0 ]; then echo "FAILED: $MFAILS mutant(s) not convicted"; exit 1; fi
echo "PASS: all mutants convicted"
