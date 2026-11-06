#!/usr/bin/env bash
# test-stop-mediad-verify.sh [<nowhere_roamd.sh>] [--mutate] -- stop_mediad reads the mounts table it reports on
# (NWP-20261025-17).
#
# WHY THIS IS COMMITTED. stop_mediad counted media mounts with `grep ... /proc/mounts 2>/dev/null | wc -l`. A grep that
# cannot read the table (a sepolicy change that drops this domain's read) exits 2 with nothing on stdout, `wc -l`
# printed 0, the first attempt broke out of the retry loop and roam.log said "media mounts clear" over a table that was
# never read -- ahead of cleanstorage, a sign-in's reap and dropcaches, which read nothing back. Each attempt now reads
# the table once with its status kept; a failed or empty read is UNREAD: it takes the second attempt and the verdict
# is "ERR-MEDIA-SWEEP: mount table unreadable", never "media mounts clear". Silent when it regresses, so it is pinned.
#
# NWP-20261109-02: a mount that survives both attempts is listed as `still mounted:`, and the path is the session's folder
# tree. The line prints it through roamd's qn as one quoted token, so log_scrub (which redacts quoted tokens only and
# keeps a tail of roam.log across every reap) removes it whole instead of leaving a departed profile's folder names for a
# later session's issue report (Q001 (e), docs/product-decisions.md). qn is extracted by name; bash and dash have no
# `print` builtin, so the run loads the same shim test-log-name-scrub.sh does.
#
# NWP-20261113-03: an attempt waits for the sweep it kicked to END before it reads the table it judges. The marker wait
# was a fixed 50 ticks (5 s); a 96-mount sweep outlasted it, both attempts read a half-swept table, the sign-out was
# refused with ERR-MEDIA-SWEEP and mediad finished 4 s later with 0 FAILED. The wait is now 50 ticks plus 5 per media
# mount counted before the first kick, capped at 550 (55 s), and it stops early when the marker is gone or, after a
# 20-tick start grace, when init no longer reports the oneshot `running`. The stubs are STATEFUL inside the case dir:
# sleep counts ticks, a ctl.start begins a fake sweep (once: init ignores a start on a running service), getprop says
# `running` while it is live, and at tick T it removes the marker and drops the media lines from the fixture table.
#   S1 a 20 s clean sweep of 96 mounts       -> one attempt, media mounts clear, a `waited 20.0s` line (main refused it)
#   S2 a dead mediad (marker kept, stopped)  -> both attempts end on the grace, ERR with the surviving count
#   S3 three mounts, a 1 s sweep             -> clear, and no `waited` line
#   S4 5000 mounts, a sweep that never ends  -> at most 1200 ticks for the whole call (the cap), ERR with the count
# A safety valve in the sleep stub ends a run at 5000 ticks, so a mutant without the cap fails fast instead of looping.
# The printf stub carries the device's exec limit (mksh has no printf builtin; one argument over 128 KB is E2BIG), so S4
# also convicts a table piped through `printf '%s\n' "$_mt"`: its count read 0 and the verdict said "media mounts clear"
# over 5000 live mounts, which CI's mksh leg caught.
#
# NWP-20261123-26: the marker write `( : > "$STATE/mediad.sweep" )` with a target that cannot be written. S13 plants
# the marker as a DIRECTORY with one entry (a redirection onto a directory fails for any user, root included) and 96
# media mounts with a live sweep. The marker is then not a regular file, so the wait ends at tick 0, no sweep detaches
# anything, and both attempts read the table with its status kept: the verdict is `ERR-MEDIA-SWEEP: 96 media mount(s)
# survive 2 sweep attempt(s)`, never "media mounts clear", and the function returns (the line after it runs). That is
# the callers' own verified read (sweepmedia, coldsweep and the in arm read the table again), so no code changed: the
# case pins it, under every shell, bash as --posix, and S14 (the write made bare: the function ends there) convicts.
# roamd runs `chmod 600` on the plant, which takes its x bit, so S13 restores it before it reads the case dir, and the
# EXIT trap runs `chmod -R u+rwx` before its rm: a non-root rm cannot empty a directory without x.
#
# stop_mediad is extracted BY ANCHOR and run with setprop/getprop/sleep stubbed and /proc/mounts rewritten to a
# fixture file, a path that does not exist, or an empty file. Every case runs under each of bash, dash and mksh found
# (mksh reads a non-number in `[ x -lt N ]` as 0, silently, where bash and dash error).
#
#   bash test-stop-mediad-verify.sh            # the cases
#   bash test-stop-mediad-verify.sh --mutate   # ... plus mutations that must each CONVICT the suite, per shell
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for every temp; nothing outlives the suite.
W=$(mktemp -d) || exit 2
trap 'command chmod -R u+rwx "$W" 2>/dev/null; command rm -rf "$W"' EXIT

SHELLS=""
for s in bash dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }

# The function runs from its `stop_mediad() {` line to the first column-0 `}` after it.
extract() { awk 'index($0,"stop_mediad() {")==1{on=1} on{print} on&&/^}$/{exit}' "$1"; }

# The same shim as test-log-name-scrub.sh's PRINT_SHIM: bash and dash have no `print`; mksh (the device's sh) does.
PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

# suite <script> <quiet|""> <shell>
suite() {
  local f="$1" quiet="${2:-}" sh="$3" p=0 x=0 fn QN SCRUB L S want R
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$sh" "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$sh" "$1"; }

  fn=$(extract "$f")
  case "$fn" in *'ctl.start nowhere_mediad'*'media mounts clear'*) ;; *) no "EXTRACTION FAILED -- stop_mediad moved in $f"; return 2 ;; esac
  "$sh" -n <<<"$fn" 2>/dev/null || { no "THE FUNCTION DOES NOT PARSE under $sh in $f"; return 2; }

  QN=$(awk 'index($0,"qn() {")==1{on=1} on{print} on&&$0=="}"{exit}' "$f")
  case "$QN" in *sed*) ;; *) no "EXTRACTION FAILED -- qn in $f"; return 2 ;; esac
  SCRUB=$(grep -m1 '^LOG_SCRUB_SED=' "$f")
  [ -n "$SCRUB" ] || { no "EXTRACTION FAILED -- LOG_SCRUB_SED in $f"; return 2; }
  eval "$SCRUB"

  # _prep <dir> <sweep-ticks> <alive> <mode> [lines...]: the fixture table and run.sh in <dir>.
  # sweep-ticks: "" no fake sweep (the marker is never removed), N the sweep ends N ticks after its start, never it
  # never ends. alive: yes getprop says running while the fake sweep is live, no it always says stopped.
  # mode: lines (the lines are the table), --missing (a path that does not exist), --empty (an empty file),
  # --media N (N fuse.nowheremedia lines plus one non-media line, so the swept table is not empty, which is UNREAD).
  _prep() {
    local d="$1" st="$2" al="$3" mode="$4" body; shift 4
    case "$mode" in
      --missing) : ;;
      --empty)   : > "$d/mounts" ;;
      --media)   awk -v n="$1" 'BEGIN{for(k=1;k<=n;k++) printf "nowheremedia /data/user/10/app%d/files fuse.nowheremedia rw 0 0\n", k; print "/dev/block/dm-48 /data ext4 rw 0 0"}' > "$d/mounts" ;;
      *)         printf '%s\n' "$mode" "$@" > "$d/mounts" ;;
    esac
    body=$(printf '%s\n' "$fn" | sed "s#/proc/mounts#$d/mounts#g")
    {
      printf 'STATE=%s LOG=%s/log D=%s SWEEP_T=%s ALIVE=%s\n' "$d" "$d" "$d" "$st" "$al"
      cat <<'STUBS'
__tk=0; __st=0
# The device's mksh has no printf builtin: printf goes through exec(2), and one argument over MAX_ARG_STRLEN (128 KB)
# fails with E2BIG. bash and dash run a builtin that has no limit, so every shell gets the device's limit here.
printf(){
  local __pa
  for __pa in "$@"; do
    if [ "${#__pa}" -gt 131072 ]; then echo "printf: Argument list too long" >&2; return 126; fi
  done
  command printf "$@"
}
setprop(){
  case "$1 $2" in
    "ctl.start nowhere_mediad")
      echo x >> "$D/starts"
      if [ -n "$SWEEP_T" ] && [ ! -e "$D/live" ]; then : > "$D/live"; __st=$__tk; fi ;;
  esac
}
getprop(){ if [ "$ALIVE" = yes ] && [ -e "$D/live" ]; then echo running; else echo stopped; fi; }
sleep(){
  __tk=$((__tk+1))
  if [ "$__tk" -ge 5000 ]; then echo "$__tk" > "$D/ticks"; exit 3; fi
  if [ -e "$D/live" ] && [ "$SWEEP_T" != never ] && [ $((__tk - __st)) -ge "$SWEEP_T" ]; then
    rm -f "$STATE/mediad.sweep" "$D/live"
    grep -v -e ' fuse.nowheremedia ' -e '/.nowhere-media' "$D/mounts" > "$D/mounts.new"
    mv -f "$D/mounts.new" "$D/mounts"
  fi
}
STUBS
      printf '%s\n' 'command -v print >/dev/null 2>&1 || eval "$PSHIM"'
      printf '%s\n' "$QN"
      printf '%s\nstop_mediad\necho "$__tk" > "$D/ticks"\n' "$body"
    } > "$d/run.sh"
    PSHIM="$PRINT_SHIM" "$sh" ${SH_OPT:-} "$d/run.sh" >/dev/null 2>&1
  }

  # _runlog <mode> [lines...] -> the roam.log text the run wrote
  _runlog() {
    local d; d=$(mktemp -d -p "$W" runlog.XXXXXX)
    _prep "$d" "" no "$@"
    cat "$d/log" 2>/dev/null
    command rm -rf "$d"
  }

  # _runx <sweep-ticks> <alive> <mode> [lines...]
  #   -> "<ctl.start count>|<log verdict>|<marker KEPT or GONE>|<sleep ticks>|<waited line: the line, or none>|<ERR lines>"
  _runx() {
    local d v c m t w e
    d=$(mktemp -d -p "$W" run.XXXXXX)
    _prep "$d" "$@"
    c=0; [ -f "$d/starts" ] && c=$(wc -l < "$d/starts" | tr -d ' ')
    v=none
    if   grep -F "media mounts clear" "$d/log" >/dev/null 2>&1; then v=clear
    elif grep -F "ERR-MEDIA-SWEEP: mount table unreadable after 2 sweep attempt(s)" "$d/log" >/dev/null 2>&1; then v=unreadable
    else
      v=$(sed -n 's/^\[roamd\] ERR-MEDIA-SWEEP: \([0-9][0-9]*\) media mount(s) survive 2 sweep attempt(s) .*/survive\1/p' "$d/log" 2>/dev/null)
      v=${v:-none}
    fi
    m=GONE; [ -e "$d/mediad.sweep" ] && m=KEPT
    t=$(cat "$d/ticks" 2>/dev/null); t=${t:-none}
    w=$(sed -n 's/^\[roamd\] media sweep attempt \([0-9]\) waited \([0-9.]*s for [0-9]* mount(s)\) .*/\1 \2/p' "$d/log" 2>/dev/null | tr '\n' ';')
    w=${w:-none}
    e=$(grep -c "ERR-MEDIA-SWEEP" "$d/log" 2>/dev/null); e=${e:-0}
    printf '%s|%s|%s|%s|%s|%s\n' "$c" "$v" "$m" "$t" "$w" "$e"
    command rm -rf "$d"
  }
  # _run <mode> [lines...] -> "<ctl.start count>|<log verdict>|<marker KEPT or GONE>", no fake sweep, mediad stopped
  _run() { _runx "" no "$@" | cut -d'|' -f1-3; }
  # _ticks <field 4 of a _runx line> <max>: true when the call slept at most <max> ticks (a non-number is false)
  _ticks() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -le "$2" ]; }

  [ "$(_run '/dev/block/dm-48 /data ext4 rw 0 0')" = "1|clear|GONE" ] \
    && ok "a readable table, no media mount: one attempt, media mounts clear" || no "a clean table was not one attempt + clear"
  [ "$(_run 'nowheremedia /data/user/10/com.x/files fuse.nowheremedia rw 0 0')" = "2|survive1|GONE" ] \
    && ok "one fuse.nowheremedia line: two attempts, 1 media mount(s) survive" || no "a left overlay was not two attempts + survive"
  [ "$(_run --missing)" = "2|unreadable|GONE" ] \
    && ok "an unreadable table: two attempts, unreadable ERR, not clear" || no "an unread table was not two attempts + unreadable"
  [ "$(_run --empty)" = "2|unreadable|GONE" ] \
    && ok "an empty table: two attempts, unreadable ERR, not clear" || no "an empty table was not two attempts + unreadable"
  # A mount that survives both attempts: the path is one quoted token, and the scrub removes it whole.
  L=$(_runlog 'nowheremedia /data/user/10/com.whatsapp/files/WhatsApp\040Images fuse.nowheremedia rw 0 0')
  want='[roamd]   still mounted: "/data/user/10/com.whatsapp/files/WhatsApp\\040Images"'
  S=$(printf '%s\n' "$L" | sed -E "$LOG_SCRUB_SED")
  if [ "$(printf '%s\n' "$L" | grep -cxF "$want")" = 1 ]; then ok "a surviving mount is listed as one quoted path"
  else no "the still-mounted line is not the qn-quoted path"; fi
  case "$S" in *WhatsApp*|*/data/user/10*) no "the scrubbed log still holds the surviving mount's path" ;; *) ok "the scrubbed log holds none of the surviving mount's path" ;; esac
  # NWP-20261113-03: the wait follows the sweep it kicked, under a bound that grows with the mount count.
  R=$(_runx 200 yes --media 96)
  case "$R" in
    "1|clear|GONE|"*"|1 20.0s for 96 mount(s);|0") ok "S1 a 20 s clean sweep of 96 mounts: one attempt waits it out, media mounts clear, no ERR" ;;
    *) no "S1 a 20 s clean sweep of 96 mounts was not one attempt + clear + a waited line ($R)" ;;
  esac
  R=$(_runx "" no --media 96)
  case "$R" in
    "2|survive96|GONE|"*) _ticks "$(printf '%s' "$R" | cut -d'|' -f4)" 130 \
      && ok "S2 a dead mediad: both attempts end on the start grace (<= 130 ticks), 96 media mount(s) survive" \
      || no "S2 a dead mediad was waited out past the start grace ($R)" ;;
    *) no "S2 a dead mediad was not two attempts + 96 survive ($R)" ;;
  esac
  R=$(_runx 10 yes 'nowheremedia /data/user/10/a/files fuse.nowheremedia rw 0 0' 'nowheremedia /data/user/10/b/files fuse.nowheremedia rw 0 0' \
        'nowheremedia /data/user/10/c/files fuse.nowheremedia rw 0 0' '/dev/block/dm-48 /data ext4 rw 0 0')
  case "$R" in
    "1|clear|GONE|10|none|0") ok "S3 three mounts, a 1 s sweep: one attempt, media mounts clear, no waited line" ;;
    *) no "S3 a quick sweep of three mounts changed its verdict or logged a wait ($R)" ;;
  esac
  R=$(_runx never yes --media 5000)
  case "$R" in
    "2|survive5000|GONE|"*) _ticks "$(printf '%s' "$R" | cut -d'|' -f4)" 1200 \
      && ok "S4 5000 mounts and a sweep that never ends: the whole call sleeps <= 1200 ticks, 5000 media mount(s) survive" \
      || no "S4 the whole call slept past the 1200-tick cap ($R)" ;;
    *) no "S4 a sweep that never ends was not two attempts + 5000 survive ($R)" ;;
  esac
  # S13 (NWP-20261123-26): the marker cannot be written (a directory with one entry), 96 mounts, a live sweep.
  local d13 c13 v13 k13 t13 o13=
  d13=$(mktemp -d -p "$W" s13.XXXXXX); mkdir "$d13/mediad.sweep"; : > "$d13/mediad.sweep/entry"
  [ "$sh" = bash ] && o13=--posix
  SH_OPT=$o13 _prep "$d13" 200 yes --media 96
  k13=no; [ -d "$d13/mediad.sweep" ] && k13=dir
  command chmod -R u+rwx "$d13"
  c13=0; [ -f "$d13/starts" ] && c13=$(wc -l < "$d13/starts" | tr -d ' ')
  v13=$(grep -c -F 'media mounts clear' "$d13/log" 2>/dev/null)
  v13="${v13:-0}/$(grep -c -F '[roamd] ERR-MEDIA-SWEEP: 96 media mount(s) survive 2 sweep attempt(s) ' "$d13/log" 2>/dev/null)"
  t13=$(cat "$d13/ticks" 2>/dev/null); case "$t13" in ''|*[!0-9]*) t13=none ;; *) t13=ran ;; esac
  R="$c13|$v13|$k13|$t13"
  [ "$R" = "2|0/1|dir|ran" ] \
    && ok "S13 an unwritable marker: two kicks, both reads judged, 96 media mount(s) survive, the call returns (bash as --posix)" \
    || no "S13 an unwritable marker: got '$R', want '2|0/1|dir|ran' (kicks|clear/survive96 lines|plant|after the call)"
  command rm -rf "$d13"
  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "== $SUT (shells:$SHELLS)"
rc=0
for sh in $SHELLS; do suite "$SUT" "" "$sh" || rc=1; done
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED under each shell's own line)"
mut() { # mut <label> <perl-expr>
  local m rc sh bad=0; m=$(mktemp -p "$W")
  if ! perl -0pe "$2" "$SUT" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; command rm -f "$m"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; command rm -f "$m"; return 1; fi
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; command rm -f "$m"; return 1; fi
  for sh in $SHELLS; do
    suite "$m" quiet "$sh"; rc=$?
    case "$rc" in
      1) echo "  convicted $1 [$sh]" ;;
      0) echo "  SURVIVED  $1 [$sh]"; bad=1 ;;
      *) echo "  BROKEN    $1 [$sh] -- the mutant no longer extracts or parses (rc=$rc)"; bad=1 ;;
    esac
  done
  command rm -f "$m"
  return $bad
}
fails=0
mut "S1 the old grep | wc -l count restored" 's/(stop_mediad\(\) \{\n(?:.*\n)*?    )_mt=\$\(cat [^\n]*\n    if [^\n]*then\n/$1_mt=""; _mtrc=0\n    if true; then\n/' || fails=$((fails+1))
mut "S2 UNREAD breaks the loop"             's/(could not read the mount table \$\(date\)" >> "\$LOG"\n)/$1      break\n/' || fails=$((fails+1))
mut "S3 an empty read counted as readable"  's/(stop_mediad\(\) \{\n(?:.*\n)*?    if \[ "\$_mtrc" -eq 0 \]) && \[ -n "\$_mt" \]; then/$1; then/' || fails=$((fails+1))
mut "S4 the unreadable verdict says clear"  's/(stop_mediad\(\) \{\n(?:.*\n)*?  )if \[ "\$_unread" -eq 1 \]; then/$1if false; then/' || fails=$((fails+1))
mut "S6 stop_mediad's survivor line bare" 's/print -r -- "\[roamd\]   still mounted: \$\(qn "\$mnt"\)"/echo "[roamd]   still mounted: \$mnt"/' || fails=$((fails+1))
# NWP-20261113-03: the wait follows the sweep, under a bound scaled by the count and capped inside the stall budget.
mut "S7 the marker wait not scaled by the count" 's/_bound=\$\(\(50 \+ 5 \* _n\)\)/_bound=50/' || fails=$((fails+1))
mut "S8 the stopped-oneshot early exit removed" 's/\n *\[ "\$i" -ge 20 \] && \[ "\$\(getprop init\.svc\.nowhere_mediad\)" != "running" \] && break//' || fails=$((fails+1))
mut "S9 the table read before the wait"         's/(stop_mediad\(\) \{\n(?:.*\n)*?    setprop ctl\.start nowhere_mediad\n)((?:.*\n)*?)(    _mt=\$\(cat \/proc\/mounts 2>>"\$LOG"\); _mtrc=\$\?\n)/$1$3$2/' || fails=$((fails+1))
mut "S10 the cap raised to 1200 ticks"          's/\[ "\$_bound" -gt 550 \] && _bound=550/[ "\$_bound" -gt 1200 ] && _bound=1200/' || fails=$((fails+1))
mut "S11 the cap removed"                       's/\n *\[ "\$_bound" -gt 550 \] && _bound=550//' || fails=$((fails+1))
mut "S12 the table piped through printf"        's/left=\$\(grep (-e [^<]*)<<EOF_MT \| wc -l\n\$_mt\nEOF_MT\n\)/left=\$(printf "%s\\n" "\$_mt" | grep $1| wc -l)/' || fails=$((fails+1))
mut "S14 the marker write is bare"              's/\( : > "\$STATE\/mediad\.sweep" \); chmod 600/: > "\$STATE\/mediad.sweep"; chmod 600/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
