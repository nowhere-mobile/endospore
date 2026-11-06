#!/usr/bin/env bash
# test-logscrub-failclosed.sh [<nowhere_roamd.sh>] [--mutate] -- a log that log_scrub cannot scrub is EMPTIED, not kept
# with its profile names, and one line after the loop says which logs (NWP-20261120-17).
#
# WHY. log_scrub writes each log's scrubbed copy to $STATE/.logscrub and used to write it back only when that copy had
# content. When the copy could not be written (the redirection failed, or the 256 MiB state tmpfs was full, so sed
# wrote nothing), the guard skipped and the log kept every quoted name it held, with no log line. The reap runs
# log_scrub LAST so that the departed name leaves the logs: `IN "<name>"`, `OUT "<name>"` and the daemon's %q lines
# then stayed on /data, which survives power-off -- the cleartext roster #39 removed (DIA-20260807-12). The scrub
# program holds no delete command, so for a non-empty log an empty copy is always a failure, never a result.
#
# NWP-20261123-26: and a log that cannot be emptied either is REMOVED, and named on its own `could not scrub or
# empty ... -- removed` line, never on the `emptied` one. The truncation used to be unchecked, so such a log kept every
# name under a line that said it was emptied. C6 and C7 plant it root-proof: `set -C` (POSIX noclobber) makes `: >` on
# an existing regular file fail for any user, and C7's `rm` function refuses login.log, which must then be named on a
# `could NOT remove` line. Both run under every shell, bash as --posix, so the bare-form mutant m9 is convicted there.
#
#   bash test-logscrub-failclosed.sh             # the cases, under every shell installed (bash, sh, dash, mksh)
#   bash test-logscrub-failclosed.sh --mutate    # ... plus mutants that must each CONVICT the suite under every shell
#
# log_scrub and the definitions it reads are EXTRACTED from nowhere_roamd.sh by anchor, never copied, and run re-rooted.
# Pure logic: no device, no store.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/nowhere_roamd.sh"; MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2; trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT   # every case root, the sed stubs and --mutate's copy of roamd

PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
SCRUB_DEFS="NOWHERE_LOGS LOG_KEEP_BYTES LOG_SCRUB_SED LOG_SCRUB_SED_PREV LOG_SCRUB_PROBE LOG_SCRUB_PROBE_OUT
LOG_SCRUB_DNS_SED LOG_SCRUB_DNS_PROBE LOG_SCRUB_DNS_PROBE_OUT"
defs_of() {
  local v out="" n
  for v in $SCRUB_DEFS; do
    n=$(grep -c "^$v=" "$1")
    [ "$n" = 1 ] || { echo "EXTRACTION FAILED: $v= is defined $n times in $1, want 1" >&2; return 1; }
    out="$out$(grep "^$v=" "$1")"$'\n'
  done
  printf '%s' "$out"
}

# The sed stubs. The self-check probes call `sed -E <prog>` (stdin, 2 arguments); the per-log call is
# `sed -E <prog> <file>` (3 arguments). C4's writes nothing for a file and exits 1; C5's writes the real scrubbed text
# and then exits 1.
REAL_SED=$(command -v sed) || { echo "no sed on PATH" >&2; exit 2; }
STUB4=$(mktemp -d -p "$W"); STUB5=$(mktemp -d -p "$W")
printf '#!/bin/sh\nif [ $# -ge 3 ]; then exit 1; fi\nexec "%s" "$@"\n' "$REAL_SED" > "$STUB4/sed"
printf '#!/bin/sh\nif [ $# -ge 3 ]; then "%s" "$@"; exit 1; fi\nexec "%s" "$@"\n' "$REAL_SED" "$REAL_SED" > "$STUB5/sed"
chmod +x "$STUB4/sed" "$STUB5/sed"

# run <shell> <root> <defs> <scrubfn> [path-prefix] [prelude]: the real function, re-rooted, in a fresh <shell>
# (bash as --posix). LOG is roam.log, as on the device, so the report line and an emptied roam.log meet as they do
# there. <prelude> runs just before log_scrub (C6/C7: `set -C` and a refusing rm).
run() {
  local sh="$1" root="$2" script o=
  script="$root/run.sh"
  { printf 'ROOT=%s; STATE=%s/state; LOG=%s/data/nowhere/roam.log\n' "$root" "$root" "$root"
    [ -z "${5:-}" ] || printf 'PATH=%s:$PATH\n' "$5"
    [ "$sh" = mksh ] || printf '%s\n' "$PRINT_SHIM"
    printf '%s\n%s\n%s\nlog_scrub\n' "$3" "$4" "${6:-}"; } > "$script"
  [ "$sh" = bash ] && o=--posix
  "$sh" $o "$script" </dev/null >/dev/null 2>&1
}
NOCLOBBER='set -C'
REFUSE_LOGIN_RM='set -C
rm() { for _ra in "$@"; do case "$_ra" in */data/nowhere/login.log) return 1 ;; esac; done; command rm "$@"; }'
CNE='log_scrub: could not scrub or empty'
CNR='log_scrub: could NOT remove'
EMP='emptied rather than kept'


NAME=alice
ROAM_IN='[roamd] IN "'$NAME'" -> user 10'
ROAM_NEUTRAL='[roamd] reap clean user 10'
LOGIN_L='[logind] login "'$NAME'": ok'
MEDIAD_L='[mediad] start "'$NAME'" -> user 10'
CNS='log_scrub: could not scrub'

# suite <roamd> <shell> [quiet] -> 0 all good, 1 a check failed, 2 the harness could not run.
suite() {
  local f="$1" sh="$2" quiet="${3:-}" p=0 x=0 tmp defs scrubfn n R d line
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$sh" "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$sh" "$1"; }
  chk(){ if "$@"; then ok "$CASE"; else no "$CASE"; fi; }

  defs=$(defs_of "$f") || return 2
  (eval "$defs"; [ -n "$LOG_SCRUB_SED" ] && [ -n "$NOWHERE_LOGS" ] && [ -n "$LOG_KEEP_BYTES" ]) ||
    { echo "EXTRACTION FAILED: the definitions did not evaluate" >&2; return 2; }
  scrubfn=$(fn_of "$f" log_scrub)
  [ -n "$scrubfn" ] || { echo "EXTRACTION FAILED: log_scrub not found" >&2; return 2; }
  n=$(grep -c '/data/nowhere/' <<<"$scrubfn")
  [ "$n" = 1 ] || { echo "EXTRACTION FAILED: log_scrub names /data/nowhere/ $n times, want 1" >&2; return 2; }
  scrubfn=${scrubfn//\/data\/nowhere\//\$ROOT\/data\/nowhere\/}
  # No other absolute path: /dev/null aside, a path the re-rooting did not reach would touch the host.
  n=$(printf '%s\n' "$scrubfn" | grep -v '^[[:space:]]*#' | sed 's#/dev/null##g' | grep -cE '(^|[[:space:]"'"'"'=(<>|;])/[A-Za-z]')
  [ "$n" = 0 ] || { echo "EXTRACTION FAILED: log_scrub holds $n other absolute path(s)" >&2; return 2; }

  tmp=$(mktemp -d -p "$W")
  # newroot <n>: a fresh root with the data dir and the state dir; echoes it
  newroot() { mkdir -p "$tmp/$1/data/nowhere" "$tmp/$1/state"; printf '%s' "$tmp/$1"; }
  lg() { printf '%s/data/nowhere/%s.log' "$1" "$2"; }
  # hits <root> <text>: lines holding <text> across every log of <root>
  hits() { cat "$(lg "$1" login)" "$(lg "$1" roam)" "$(lg "$1" mediad)" 2>/dev/null | grep -cF -- "$2"; }
  plant() {
    printf '%s\n%s\n' "$ROAM_IN" "$ROAM_NEUTRAL" > "$(lg "$1" roam)"
    printf '%s\n' "$LOGIN_L" > "$(lg "$1" login)"
    printf '%s\n' "$MEDIAD_L" > "$(lg "$1" mediad)"
  }
  # cnsline <root>: roam.log's could-not-scrub lines, newline-joined
  cnsline() { grep -F -- "$CNS" "$(lg "$1" roam)" 2>/dev/null; }

  # C1: the scratch cannot be written -- a DIRECTORY at its path fails the redirection whatever the user.
  R=$(newroot c1); plant "$R"; mkdir "$R/state/.logscrub"
  run "$sh" "$R" "$defs" "$scrubfn" || true
  [ -d "$R/state/.logscrub" ] || { echo "HARNESS: C1's scratch is no longer a directory" >&2; rm -rf "$tmp"; return 2; }
  CASE="C1 unwritable scratch: no log keeps a byte of the name"; chk test "$(hits "$R" "$NAME")" = 0
  line=$(cnsline "$R")
  CASE="C1 one could-not-scrub line, naming login, roam and mediad"
  chk test "$(printf '%s\n' "$line" | grep -c .)|$(case "$line" in *login.log*roam.log*mediad.log*) echo y ;; esac)" = "1|y"
  CASE="C1 the line names logs, never the profile"; chk test "$(printf '%s\n' "$line" | grep -c "$NAME")" = 0
  CASE="C1 login.log and mediad.log are emptied in place"
  chk test "$(wc -c < "$(lg "$R" login)")|$(wc -c < "$(lg "$R" mediad)")" = "0|0"

  # C2: control, writable scratch: scrubbed and kept, no could-not-scrub line.
  R=$(newroot c2); plant "$R"
  run "$sh" "$R" "$defs" "$scrubfn" || true
  CASE="C2 writable scratch: the name is gone"; chk test "$(hits "$R" "$NAME")" = 0
  CASE="C2 every log is kept, scrubbed"
  chk test "$(grep -cF '"<name>"' "$(lg "$R" roam)")|$(grep -cF '"<name>"' "$(lg "$R" login)")|$(grep -cF '<name>' "$(lg "$R" mediad)")" = "1|1|1"
  CASE="C2 the neutral line survives"; chk test "$(grep -cxF -- "$ROAM_NEUTRAL" "$(lg "$R" roam)")" = 1
  CASE="C2 no could-not-scrub line"; chk test "$(hits "$R" "$CNS")" = 0

  # C3a: an empty login.log beside a planted roam.log, unwritable scratch.
  R=$(newroot c3a); printf '%s\n' "$ROAM_IN" > "$(lg "$R" roam)"; : > "$(lg "$R" login)"; mkdir "$R/state/.logscrub"
  run "$sh" "$R" "$defs" "$scrubfn" || true
  line=$(cnsline "$R")
  CASE="C3 an empty log stays empty"; chk test "$(wc -c < "$(lg "$R" login)")" = 0
  CASE="C3 the line names roam.log and not the empty login.log"
  chk test "$(printf '%s\n' "$line" | grep -c .)|$(case "$line" in *login.log*) echo n ;; *roam.log*) echo y ;; esac)" = "1|y"
  # C3b: only empty logs: nothing to name, no line at all.
  R=$(newroot c3b); : > "$(lg "$R" roam)"; : > "$(lg "$R" login)"; mkdir "$R/state/.logscrub"
  run "$sh" "$R" "$defs" "$scrubfn" || true
  CASE="C3 only empty logs: they stay empty and no line is written"
  chk test "$(wc -c < "$(lg "$R" roam)")|$(wc -c < "$(lg "$R" login)")" = "0|0"

  # C4: sed fails on the file and writes nothing (the probes still pass, so the fallback does not run).
  R=$(newroot c4); plant "$R"
  run "$sh" "$R" "$defs" "$scrubfn" "$STUB4" || true
  line=$(cnsline "$R")
  CASE="C4 sed writes nothing: no log keeps the name"; chk test "$(hits "$R" "$NAME")" = 0
  CASE="C4 one could-not-scrub line, naming login, roam and mediad"
  chk test "$(printf '%s\n' "$line" | grep -c .)|$(case "$line" in *login.log*roam.log*mediad.log*) echo y ;; esac)" = "1|y"
  CASE="C4 the probes passed: no self-check warning"; chk test "$(hits "$R" 'self-check')" = 0

  # C5: sed writes the scrubbed text and exits 1: the text is kept, as before.
  R=$(newroot c5); plant "$R"
  run "$sh" "$R" "$defs" "$scrubfn" "$STUB5" || true
  CASE="C5 sed exits 1 after writing: the name is gone"; chk test "$(hits "$R" "$NAME")" = 0
  CASE="C5 the scrubbed text is kept"
  chk test "$(grep -cF '"<name>"' "$(lg "$R" roam)")|$(grep -cF '"<name>"' "$(lg "$R" login)")|$(grep -cxF -- "$ROAM_NEUTRAL" "$(lg "$R" roam)")" = "1|1|1"
  CASE="C5 no could-not-scrub line"; chk test "$(hits "$R" "$CNS")" = 0

  # C6 (NWP-20261123-26): no scrub copy AND `: >` refused (set -C): every log is removed and named on the removed line.
  R=$(newroot c6); plant "$R"; mkdir "$R/state/.logscrub"
  run "$sh" "$R" "$defs" "$scrubfn" "" "$NOCLOBBER" || true
  CASE="C6 cannot scrub or empty: login.log and mediad.log are removed (bash as --posix)"
  chk test "$([ -e "$(lg "$R" login)" ] && echo login)$([ -e "$(lg "$R" mediad)" ] && echo mediad)" = ""
  CASE="C6 roam.log holds only log_scrub's own lines"
  chk test "$(grep -c . "$(lg "$R" roam)" 2>/dev/null)|$(grep -vc '^\[roamd\] log_scrub: ' "$(lg "$R" roam)" 2>/dev/null)" = "1|0"
  CASE="C6 no log keeps a byte of the name"; chk test "$(hits "$R" "$NAME")" = 0
  line=$(grep -F -- "$CNE" "$(lg "$R" roam)" 2>/dev/null)
  CASE="C6 one removed line, naming login, roam and mediad"
  chk test "$(printf '%s\n' "$line" | grep -c .)|$(case "$line" in *login.log*roam.log*mediad.log*" -- removed (NWP-20261123-26) "*) echo y ;; esac)" = "1|y"
  CASE="C6 no emptied line"; chk test "$(hits "$R" "$EMP")" = 0
  CASE="C6 no could-NOT-remove line"; chk test "$(hits "$R" "$CNR")" = 0

  # C7: C6 plus an rm that refuses login.log: login.log is named on a could-NOT-remove line, the others removed.
  R=$(newroot c7); plant "$R"; mkdir "$R/state/.logscrub"
  run "$sh" "$R" "$defs" "$scrubfn" "" "$REFUSE_LOGIN_RM" || true
  CASE="C7 rm refused: login.log is still there (bash as --posix)"; chk test -f "$(lg "$R" login)"
  line=$(grep -F -- "$CNR" "$(lg "$R" roam)" 2>/dev/null)
  CASE="C7 one could-NOT-remove line, naming login.log alone"
  chk test "$(printf '%s\n' "$line" | grep -c .)|$(case "$line" in *roam.log*|*mediad.log*) echo n ;; *"could NOT remove login.log -- "*) echo y ;; esac)" = "1|y"
  CASE="C7 that line names the log, never the profile"; chk test "$(printf '%s\n' "$line" | grep -c "$NAME")" = 0
  line=$(grep -F -- "$CNE" "$(lg "$R" roam)" 2>/dev/null)
  CASE="C7 the removed line names roam.log and mediad.log, not login.log"
  chk test "$(printf '%s\n' "$line" | grep -c .)|$(case "$line" in *login.log*) echo n ;; *roam.log*mediad.log*" -- removed "*) echo y ;; esac)" = "1|y"
  CASE="C7 roam.log and mediad.log are removed"
  chk test "$([ -e "$(lg "$R" mediad)" ] && echo mediad)$(grep -vc '^\[roamd\] log_scrub: ' "$(lg "$R" roam)" 2>/dev/null)" = "0"
  CASE="C7 no emptied line"; chk test "$(hits "$R" "$EMP")" = 0

  rm -rf "$tmp"
  [ -n "$quiet" ] || echo "  -- [$sh] $p ok, $x failed"
  [ "$x" = 0 ]
}

SHELLS=bash
for s in sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
FAILED=0
echo "log scrub fail-closed: $SUT (shells: $SHELLS)"
for s in $SHELLS; do
  suite "$SUT" "$s"; rc=$?
  [ "$rc" = 0 ] || { [ "$rc" = 2 ] && echo "HARNESS ERROR (rc=2) [$s]: not a verdict"; FAILED=1; }
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT under every shell):"
  mtmp=$(mktemp -d -p "$W"); MN=0; MOK=0
  mutate() {
    local label="$1" src m rc s
    shift
    src=$(cat "$SUT")
    # one or more <needle> <replacement> pairs, applied in order; each needle must occur exactly once
    while [ $# -ge 2 ]; do
      m=${src/"$1"/}
      if [ "$m" = "$src" ]; then MN=$((MN + 1)); printf '  SKIP  %-58s needle not found -- a NO-OP\n' "$label"; return; fi
      if [ "${m/"$1"/}" != "$m" ]; then MN=$((MN + 1)); printf '  SKIP  %-58s needle occurs more than once\n' "$label"; return; fi
      src=${src/"$1"/"$2"}
      shift 2
    done
    printf '%s\n' "$src" > "$mtmp/roamd.sh"
    for s in $SHELLS; do
      MN=$((MN + 1))
      suite "$mtmp/roamd.sh" "$s" quiet >/dev/null 2>&1; rc=$?
      case "$rc" in
        1) printf '  ok    %-58s [%s] convicted\n' "$label" "$s"; MOK=$((MOK + 1)) ;;
        0) printf '  XX    %-58s [%s] SURVIVED\n' "$label" "$s" ;;
        *) printf '  ERR   %-58s [%s] harness error (rc=%s), no verdict\n' "$label" "$s" "$rc" ;;
      esac
    done
  }
  NL=$'\n'
  REPORT='  if [ -n "$_e" ]; then
    print -r -- "[roamd] log_scrub: could not scrub$_e -- emptied rather than kept with their names (NWP-20261120-17) $(date)" >> "$LOG"
  fi'
  REPORT_LINE='    print -r -- "[roamd] log_scrub: could not scrub$_e -- emptied rather than kept with their names (NWP-20261120-17) $(date)" >> "$LOG"'
  FALLBACK='      if ( : > "$_f" ) 2>/dev/null && [ ! -s "$_f" ]; then
        _e="$_e $_l.log"
      else
        rm -f "$_f" 2>/dev/null
        if [ -e "$_f" ] || [ -L "$_f" ]; then _k="$_k $_l.log"; else _r="$_r $_l.log"; fi
      fi'
  mutate 'm1 the fail-closed truncation is removed' "$FALLBACK" '      _e="$_e $_l.log"'
  mutate 'm2 the after-loop line is removed' "$REPORT_LINE" '    :'
  mutate 'm3 the input guard -s becomes -f' '    elif [ -s "$_f" ]; then' '    elif [ -f "$_f" ]; then'
  mutate 'm4 the copy-with-content path is emptied too' '      } > "$_f" 2>/dev/null' '      } > "$_f" 2>/dev/null; ( : > "$_f" ) 2>/dev/null'
  mutate 'm5 the line is written inside the loop' "$NL$REPORT" '' '        _e="$_e $_l.log"' '        _e="$_e $_l.log"'"$NL$REPORT_LINE"
  mutate 'm6 the fallback rm is dropped' '        rm -f "$_f" 2>/dev/null' '        :'
  mutate 'm7 the removed log is named on the emptied line' 'else _r="$_r $_l.log"; fi' 'else _e="$_e $_l.log"; fi'
  mutate 'm8 the could-NOT-remove line is dropped' \
    '    print -r -- "[roamd] log_scrub: could NOT remove$_k -- could not scrub or empty it either, so it keeps its names (NWP-20261123-26) $(date)" >> "$LOG"' '    :'
  mutate 'm9 the fallback truncation is bare' '      if ( : > "$_f" ) 2>/dev/null && [ ! -s "$_f" ]; then' '      if : > "$_f" 2>/dev/null && [ ! -s "$_f" ]; then'
  if [ "$MOK" = "$MN" ]; then echo "ALL $MN MUTATIONS BEHAVED"
  else echo "PROBLEM: a mutation did not behave ($MOK of $MN convicted)"; FAILED=1; fi
fi

exit "$FAILED"
