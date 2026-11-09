#!/usr/bin/env bash
# test-appcode-restore-block.sh [<nowhere_roamd.sh>] [--mutate] -- the sign-in's #apps restore into the gate's
# files/.appcode (NWP-20261129-42; backlog §H 'The sign-in's #apps restore into the gate's files/.appcode, whose failure
# arm is the only remover of a manifest-less set, ran under no test').
#
# WHY THIS IS COMMITTED. The in op restores the profile's #apps scope as root into USER 0's chooser files: cleartext APKs
# of every kept installed-mode app and a manifest.tsv naming every kept app and its mode. ChooserActivity's
# installRoamedAppCode returns BEFORE its try/finally when manifest.tsv is absent, so for a restore that wrote APKs but
# no manifest, the block's failure arm is the only remover until the boot sweep's appcode0 category or the next sign-in,
# and user 0's CE storage is effectively always unlocked. A regression that drops the failure arm's rm, the pre-restore
# rm or the manifest test leaves a profile's app list and APK bytes on durable storage after the session; one that drops
# the chown leaves the gate unable to read or delete its own staging. Each is silent on a device. Other suites reach this
# block only to get past it (test-signin-keystore-staging.sh), so nothing ran its branches.
#
# This suite runs the REAL block, extracted from its first line to the first `      fi` after the failure arm's rm, with
# /data/ re-rooted into a case dir, in a child of each shell found among bash, sh, dash and mksh (the device's
# /system/bin/sh). $AGENT is a script, so its real exit status reaches the block's && chain; the other helpers are
# shell functions. What the agent's restore does is the agent's own tests' job.
#
#   A1  a stale .appcode/old.app/base.apk is gone and the agent sees an empty .appcode. A1 runs inside A2, A3, A4, A6 and
#       A7. It cannot run in A5: a file under a CHOOSER0 that is missing does not exist.
#   A2  the agent writes an APK and exits 1: no .appcode, no chown, no restorecon
#   A3  the agent writes an APK, exits 0, writes no manifest.tsv: no .appcode, no chown, no restorecon
#   A4  the agent writes the APK and manifest.tsv and exits 0: .appcode stays, chowned to CHOOSER0's owner and relabelled
#   A5  CHOOSER0 is missing: no agent call, no .appcode
#   A6  mkdir is refused: no agent call, no .appcode
#   A7  the agent exits 5 (store unreachable) after a partial tree that holds manifest.tsv: as A2. The manifest is what
#       makes this case pin the exit status. The sign-in still lands with no app code; whether it should is a separate
#       question with the maintainer, so this pins today's fate only.
#
# The mutants edit the EXTRACTED block, not a copy of roamd, because M2 removes an extraction anchor: on a copy it would
# only ever reach EXTRACTION FAILED. --mutate also proves the refusals: an anchor missing or doubled, a /data path the
# re-root did not reach, and a missing stub each exit 2, so a broken harness can never read as a conviction.
#
#   bash test-appcode-restore-block.sh            # the cases, under every shell found
#   bash test-appcode-restore-block.sh --mutate   # ... plus mutants that must each CONVICT under every shell found
#
# Pure logic -- no device. Exit 0 all pass, 1 a check failed, 2 the harness could not run (never a pass).
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; -*) echo "usage: $0 [<nowhere_roamd.sh>] [--mutate]" >&2; exit 2 ;; *) SUT="$a" ;; esac; done
SELF="$0"
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT   # every case root, block and mutant copy is made inside it

SHELLS=""; for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

ANCHOR_FIRST='      CHOOSER0="/data/user/0/com.nowhere.chooser/files"'
ANCHOR_RM='        rm -rf "$APPCODE"'
ANCHOR_END='      fi'
FILES='data/user/0/com.nowhere.chooser/files'
SUCCESS='[roamd] IN "zqprofile" #apps code restored → user0 chooser '

# extract_block <roamd.sh> <out file> -> the re-rooted block; exit 2 when it cannot be read or re-rooted exactly.
extract_block() {
  local f="$1" out="$2" a c raw live
  for a in "$ANCHOR_FIRST" "$ANCHOR_RM"; do
    c=$(grep -cxF -- "$a" "$f")
    [ "$c" = 1 ] || { echo "EXTRACTION FAILED: '$a' appears $c times as a whole line in $f (want 1)" >&2; exit 2; }
  done
  raw=$(awk -v first="$ANCHOR_FIRST" -v rm_line="$ANCHOR_RM" -v end="$ANCHOR_END" '
    $0 == first { on = 1 }
    on { print }
    on && $0 == rm_line { seen = 1 }
    on && seen && $0 == end { exit }' "$f")
  [ "$(printf '%s\n' "$raw" | tail -n 1)" = "$ANCHOR_END" ] || { echo "EXTRACTION FAILED: no '$ANCHOR_END' after the failure arm's rm in $f" >&2; exit 2; }
  # Only the forms the block uses are rewritten, so the check below can still find any other /data path.
  printf '%s\n' "$raw" | sed -E 's#([" ])/data/#\1$ROOT/data/#g' > "$out"
  c=$(grep -cxF -- '      CHOOSER0="$ROOT/'"$FILES"'"' "$out")
  [ "$c" = 1 ] || { echo "RE-ROOT INCOMPLETE: the first line was not rewritten in $f" >&2; exit 2; }
  # The block runs a real rm -rf: this check comes before any child starts.
  live=$(sed -E -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' -e 's#\$ROOT/data/##g' "$out")
  c=$(printf '%s\n' "$live" | grep -cE '(^|[^[:alnum:]_}/.-])/data([/"'"'"'[:space:]]|$)')
  [ "$c" = 0 ] || { echo "RE-ROOT INCOMPLETE: $c live line(s) of the block still hold an absolute /data path in $f" >&2; exit 2; }
}

# run_case <shell> <block file> <agent mode> <mkdir: real|refuse> <chooser: yes|no> -> sets ROOT_DIR, or HARNESS_ERR when
# the child did not run the block to its end. That is a harness failure, never a FAIL a mutant could be convicted by.
run_case() {
  local sh="$1" block="$2" mode="$3" md="$4" chooser="$5" root rc
  HARNESS_ERR=""
  root=$(mktemp -d -p "$W") || { HARNESS_ERR="no case dir"; return; }
  ROOT_DIR="$root"
  if [ "$chooser" = yes ]; then
    mkdir -p "$root/$FILES/.appcode/old.app"
    : > "$root/$FILES/.appcode/old.app/base.apk"
  fi
  : > "$root/log"
  printf '%s\n' "$mode" > "$root/agent.mode"
  cat > "$root/agent" <<'AGENT'
#!/bin/sh
d=$(dirname "$0")
for a in "$@"; do printf '%s|' "$a"; done >> "$d/agent.argv"
echo >> "$d/agent.argv"
ls -A "$5" > "$d/agent.saw"
apk() { mkdir -p "$5/x.app" && : > "$5/x.app/base.apk"; }
case "$(cat "$d/agent.mode")" in
  ok)         apk "$@"; : > "$5/manifest.tsv"; exit 0 ;;
  nomanifest) apk "$@"; exit 0 ;;
  fail1)      apk "$@"; exit 1 ;;
  fail5)      apk "$@"; : > "$5/manifest.tsv"; exit 5 ;;
esac
exit 9
AGENT
  chmod +x "$root/agent"
  {
    printf '%s\n' "$PRINT_SHIM"
    printf 'set -u\n'
    printf 'ROOT=%s; MKDIR_MODE=%s\n' "$(sq "$root")" "$(sq "$md")"
    cat <<'STUB'
name=zqprofile; pass=zqpass; uid=11
LOG="$ROOT/log"; AGENT="$ROOT/agent"
stat() { for _a in "$@"; do :; done; if [ "$_a" = "$ROOT/data/user/0/com.nowhere.chooser/files" ]; then echo 10077; else echo 0; fi; }
chown() { printf '%s\n' "$*" >> "$ROOT/chown.argv"; }
restorecon() { printf '%s\n' "$*" >> "$ROOT/restorecon.argv"; }
mkdir() { printf '%s\n' "$*" >> "$ROOT/mkdir.argv"; [ "$MKDIR_MODE" = real ] || return 1; command mkdir "$@"; }
_ms() { echo 0; }
_tlog() { :; }
qn() { printf '"%s"' "$1"; }
pw() { printf 'pw-%s' "$1"; }
STUB
    cat "$block"
    printf ': > "$ROOT/reached"\n'
  } > "$root/case.sh"
  "$sh" "$root/case.sh" > "$root/child.out" 2>&1 </dev/null; rc=$?
  if [ "$rc" != 0 ]; then HARNESS_ERR="the child exited $rc: $(head -n 3 "$root/child.out")"
  elif [ ! -e "$root/reached" ]; then HARNESS_ERR="the child did not reach the end of the block"
  elif [ "$(grep -cE 'not found|syntax error|bad substitution|unbound variable|parameter not set' "$root/child.out")" != 0 ]; then
    HARNESS_ERR="a stub or a variable is missing: $(head -n 3 "$root/child.out")"
  fi
}

n_lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# cases <block file> <shell> -> prints one line per check; returns 0 all ok, 1 a check failed, 2 the harness could not run
cases() {
  local block="$1" sh="$2" p=0 x=0 R AC c
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); printf '  ok    %s\n' "$l"; else x=$((x+1)); printf '  FAIL  %s\n' "$l"; fi
  }
  # go <case> <agent mode> <mkdir> <chooser>: one case run; sets R and AC. A harness failure ends the suite with exit 2.
  go() {
    run_case "$sh" "$block" "$2" "$3" "$4"
    if [ -n "$HARNESS_ERR" ]; then echo "HARNESS ERROR $1 [$sh]: $HARNESS_ERR" >&2; return 2; fi
    R="$ROOT_DIR"; AC="$R/$FILES/.appcode"
  }
  no_success() { [ "$(grep -cF -- '#apps code restored' "$R/log")" = 0 ]; }
  # stale_gone <case> [saw]: A1 inside this case; with `saw`, the agent ran and saw an empty .appcode.
  stale_gone() {
    chk "A1 [$sh] ($1) the stale .appcode/old.app/base.apk is gone" [ ! -e "$AC/old.app/base.apk" ]
    [ "${2:-}" = saw ] && chk "A1 [$sh] ($1) the agent saw an empty .appcode (saw '$(tr '\n' ' ' < "$R/agent.saw" 2>/dev/null)')" \
      eval '[ -f "$R/agent.saw" ] && [ ! -s "$R/agent.saw" ]'
    return 0
  }
  agent_ran_once() {
    chk "$1 [$sh] one agent call, restore of the #apps scope into .appcode (got '$(cat "$R/agent.argv" 2>/dev/null)')" \
      [ "$(cat "$R/agent.argv" 2>/dev/null)" = "restore|s3|zqprofile#apps|pw-zqpass|$AC|" ]
  }
  # nothing_left <case>: the fate every failed restore shares.
  nothing_left() {
    chk "$1 [$sh] no .appcode remains" [ ! -e "$AC" ]
    chk "$1 [$sh] no chown (got '$(cat "$R/chown.argv" 2>/dev/null)')" [ ! -e "$R/chown.argv" ]
    chk "$1 [$sh] no restorecon (got '$(cat "$R/restorecon.argv" 2>/dev/null)')" [ ! -e "$R/restorecon.argv" ]
    chk "$1 [$sh] no success line" no_success
  }

  go A2 fail1 real yes || return 2
  stale_gone A2 saw; agent_ran_once A2; nothing_left A2

  go A3 nomanifest real yes || return 2
  stale_gone A3 saw; agent_ran_once A3; nothing_left A3

  go A4 ok real yes || return 2
  stale_gone A4 saw; agent_ran_once A4
  chk "A4 [$sh] .appcode remains with the APK and manifest.tsv" eval '[ -f "$AC/x.app/base.apk" ] && [ -f "$AC/manifest.tsv" ]'
  chk "A4 [$sh] chown -R to the owner stat printed for CHOOSER0, on .appcode (got '$(cat "$R/chown.argv" 2>/dev/null)')" \
    [ "$(cat "$R/chown.argv" 2>/dev/null)" = "-R 10077:10077 $AC" ]
  chk "A4 [$sh] restorecon -R -D on .appcode (got '$(cat "$R/restorecon.argv" 2>/dev/null)')" \
    [ "$(cat "$R/restorecon.argv" 2>/dev/null)" = "-R -D $AC" ]
  c=$(grep -cF -- "$SUCCESS" "$R/log")
  chk "A4 [$sh] one '#apps code restored' line in \$LOG (got $c)" [ "$c" = 1 ]

  go A5 ok real no || return 2
  chk "A5 [$sh] CHOOSER0 missing: no agent call" [ "$(n_lines "$R/agent.argv")" = 0 ]
  chk "A5 [$sh] CHOOSER0 stays missing" [ ! -e "$R/$FILES" ]
  nothing_left A5

  go A6 ok refuse yes || return 2
  stale_gone A6
  chk "A6 [$sh] the refused mkdir is the one for .appcode (got '$(cat "$R/mkdir.argv" 2>/dev/null)')" \
    [ "$(cat "$R/mkdir.argv" 2>/dev/null)" = "-p $AC" ]
  chk "A6 [$sh] mkdir refused: no agent call" [ "$(n_lines "$R/agent.argv")" = 0 ]
  nothing_left A6

  go A7 fail5 real yes || return 2
  stale_gone A7 saw; agent_ran_once A7; nothing_left A7

  printf '  -- [%s] %d passed, %d failed\n' "$sh" "$p" "$x"
  [ "$x" = 0 ]
}

# edit <id> <source> <dest>: one exact edit, which must match once, or exit non-zero. Bytes: roamd is not ours to decode.
edit() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
m, src, dst = sys.argv[1:]
s = open(src, 'rb').read()
FIRST = b'      CHOOSER0="/data/user/0/com.nowhere.chooser/files"\n'
FAIL_RM = b'        rm -rf "$APPCODE"\n'
CALL = b'&& NOWHERE_PHASE=appcode "$AGENT" restore s3 "${name}#apps" "$(pw "$pass")" "$APPCODE" >> "$LOG" 2>&1 \\\n'
APPCODE_LINE = b'      APPCODE="$CHOOSER0/.appcode"\n'
R = {
  # Mutants of the block.
  'M1': (b'\n      rm -rf "$APPCODE"\n', b'\n'),
  'M2': (b'\n' + FAIL_RM, b'\n'),
  'M3': (b' \\\n         && [ -f "$APPCODE/manifest.tsv" ]; then', b'; then'),
  'M4': (b'stat -c %u "$CHOOSER0"', b'stat -c %u "$APPCODE"'),
  'M5': (b'\n        restorecon -R -D "$APPCODE" 2>>"$LOG"\n', b'\n'),
  'M6': (b'if [ -d "$CHOOSER0" ] && mkdir', b'if mkdir'),
  'M7': (CALL, CALL[:-3].replace(b'&& NOWHERE', b'&& { NOWHERE') + b'; :; } \\\n'),
  # Edits of a copy of roamd, which the suite must refuse.
  'X1': (b'\n' + FIRST, b'\n'),
  'X2': (b'\n' + FAIL_RM, b'\n'),
  'X3': (b'\n' + FIRST, b'\n' + FIRST + FIRST),
  'X4': (b'\n' + FAIL_RM, b'\n' + FAIL_RM + FAIL_RM),
  'X5': (b'\n' + APPCODE_LINE, b'\n' + APPCODE_LINE + b'      X=/data/leak\n'),
}
a, b = R[m]
if s.count(a) != 1:
    sys.exit('%s matched %d times (want 1)' % (m, s.count(a)))
open(dst, 'wb').write(s.replace(a, b, 1))
PY
}

# run_mutants <block file>: each CONVICTED only when the cases return 1 with a FAIL line for each named case, under each
# shell. Anything else, a harness error included, fails the run.
run_mutants() {
  local block="$1" bad=0 entry m named desc c sh rc out k n miss
  for entry in \
    "M1|A1|the pre-restore rm removed" \
    "M2|A2 A3|the failure arm's rm removed" \
    "M3|A3|the manifest.tsv test removed" \
    "M4|A4|the chown's owner read from .appcode, not CHOOSER0" \
    "M5|A4|the restorecon removed" \
    "M6|A5|the CHOOSER0 test removed" \
    "M7|A7|the agent's exit status ignored"; do
    IFS='|' read -r m named desc <<< "$entry"
    c=$(mktemp -p "$W") || return 1
    if ! edit "$m" "$block" "$c"; then echo "  FAIL  $m did not apply: $desc"; bad=1; continue; fi
    for sh in $SHELLS; do
      out=$(cases "$c" "$sh" 2>&1); rc=$?
      miss=""
      for k in $named; do
        n=$(printf '%s\n' "$out" | grep -c "^  FAIL  $k \[$sh\]")
        [ "$n" -gt 0 ] || miss="$miss $k"
      done
      if [ "$rc" = 1 ] && [ -z "$miss" ]; then echo "  ok    $m CONVICTED under $sh ($named): $desc"
      else echo "  FAIL  $m rc=$rc under $sh (want 1), no FAIL line for:${miss:- (none missing)}: $desc"; bad=1; fi
    done
  done
  return $bad
}

# refused <label> <message> <script> <roamd>: that run must exit 2 and print <message>, before any case can pass or fail.
refused() {
  local out rc
  out=$(TMPDIR="$W" bash "$3" "$4" 2>&1); rc=$?
  case "$rc:$out" in
    2:*"$2"*) echo "  ok    $1: exit 2, $2"; return 0 ;;
    *) echo "  FAIL  $1: rc=$rc, want exit 2 and '$2'"; return 1 ;;
  esac
}

run_refusals() {
  local bad=0 entry x msg desc c
  for entry in \
    "X1|EXTRACTION FAILED|the first anchor is missing" \
    "X2|EXTRACTION FAILED|the failure arm's rm is missing" \
    "X3|EXTRACTION FAILED|the first anchor appears twice" \
    "X4|EXTRACTION FAILED|the failure arm's rm appears twice" \
    "X5|RE-ROOT INCOMPLETE|a live /data path the rewrite does not reach"; do
    IFS='|' read -r x msg desc <<< "$entry"
    c=$(mktemp -p "$W") || return 1
    if ! edit "$x" "$SUT" "$c"; then echo "  FAIL  $x did not apply: $desc"; bad=1; continue; fi
    refused "$x $desc" "$msg" "$SELF" "$c" || bad=1
  done
  c=$(mktemp -p "$W") || return 1
  sed '/^_ms() /d' "$SELF" > "$c"
  if cmp -s "$SELF" "$c"; then echo "  FAIL  X6 did not apply: a missing stub"; bad=1
  else refused "X6 a missing stub" "HARNESS ERROR" "$c" "$SUT" || bad=1; fi
  return $bad
}

BLOCK=$(mktemp -p "$W") || exit 2
extract_block "$SUT" "$BLOCK"
echo "the #apps restore block: $SUT"
echo "shells:$SHELLS"
FAILED=0
for s in $SHELLS; do
  cases "$BLOCK" "$s"; rc=$?
  case "$rc" in 0) ;; 1) FAILED=1 ;; *) exit 2 ;; esac
done
[ "$FAILED" = 0 ] || exit 1
if [ "$MUTATE" = yes ]; then
  command -v python3 >/dev/null 2>&1 || { echo "FAIL: no python3 on this host -- the mutants did NOT run" >&2; exit 2; }
  echo "-- mutants (each must be CONVICTED under every shell found) --"
  BAD=0
  run_mutants "$BLOCK" || BAD=1
  echo "-- refusals (each must exit 2, so a broken harness never reads as a conviction) --"
  run_refusals || BAD=1
  [ "$BAD" = 0 ] || { echo "SOME MUTANTS SURVIVED OR FAILED"; exit 1; }
  echo "all mutants convicted"
fi
exit 0
