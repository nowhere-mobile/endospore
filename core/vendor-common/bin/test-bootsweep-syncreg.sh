#!/usr/bin/env bash
# test-bootsweep-syncreg.sh [<nowhere_roamd.sh>] [--mutate] -- the boot sweep's report-only `syncreg` block
# (NWP-20261204-23), run for real rather than grepped.
#
# docs/backlog.md "`/data/system/sync/accounts.xml` has no verified remover and no recorded exemption": nobody has read
# whether a departed user's account sync records leave that device-global file. The block answers it at every boot, in
# one `bootsweep syncreg:` line in roam.log. It must:
#   - count the authority and listenForTickles entries by tag, whatever the line layout, and how many belong to user
#     ids other than 0 with no /data/system/users/<id>.xml (stale_*); an authority with no user attribute is user 0;
#   - decode binary XML (`ABX`) with abx2xml into a pipe (both arguments, the out /proc/self/fd/1), report notool when
#     abx2xml is missing and decodefail when the stream holds no <accounts root, each with six `-`, never 0;
#   - read `unreachable` when /data/system/sync does not list, never `absent`;
#   - put no account, type or authority string in the log, in a variable left set, or in a file anywhere;
#   - leave the `bootsweep result:` line byte for byte, and leave no `_sr_` variable or function set.
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR (its header line up to the next `  # ---` header, the Report
# comment or the result echo), never copied and never by line count. /data/ is substituted by a temp root. `date`,
# `timeout`, `ls` and `abx2xml` are POSIX function stubs inside the runner: abx2xml copies a text sidecar fixture to its
# SECOND argument (the block passes /proc/self/fd/1) or fails, per case, and the runner's PATH is a directory of links
# to the plain tools the block needs, so no real abx2xml is reachable. Each case writes the block, its stubs and its
# variables into a runner file and runs it under each shell found, parsed by that shell first; every line is tagged
# `[<sh>]`, and a mutant convicts only when its re-run under each shell exits 1 with a `FAIL  [<sh>]` line of its own
# (an exit 2 is a broken mutant, never a conviction). bash, dash and mksh always run under their own names; sh is
# skipped only when it is the same binary as one of them; ONLY_SHELL=<name> (internal, the mutant re-run) runs exactly
# that shell with no dedup, and exits 2 when it is not available. Every temp lives under one root, removed on exit.
#
#   bash test-bootsweep-syncreg.sh            # the behaviour cases
#   bash test-bootsweep-syncreg.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for every temp; nothing outlives the suite.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# bash, dash and mksh run under their own names; sh only when it is not the same binary as one of them.
SHELLS=()
if [ -n "${ONLY_SHELL:-}" ]; then
  case "$ONLY_SHELL" in bash|sh|dash|mksh) ;; *) echo "FAIL  ONLY_SHELL=$ONLY_SHELL is not an available shell"; exit 2 ;; esac
  command -v "$ONLY_SHELL" >/dev/null 2>&1 || { echo "FAIL  ONLY_SHELL=$ONLY_SHELL is not an available shell"; exit 2; }
  SHELLS=("$ONLY_SHELL")
else
  for s in bash dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS+=("$s"); done
  if p=$(command -v sh 2>/dev/null); then
    r=$(readlink -f "$p"); dup=""
    for s in "${SHELLS[@]}"; do [ "$(readlink -f "$(command -v "$s")")" = "$r" ] && { dup=$s; break; }; done
    if [ -n "$dup" ]; then echo "skip shell sh: same binary as $dup"; else SHELLS+=(sh); fi
  fi
fi
[ "${#SHELLS[@]}" -gt 0 ] || { echo "FAIL  no shell found"; exit 2; }

PASS=0; FAIL=0; SH=all; SHP=""
ok(){ PASS=$((PASS+1)); printf '  ok    [%s] %s\n' "$SH" "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  [%s] %s\n' "$SH" "$1"; }

# --- extraction -----------------------------------------------------------------------------------------
HDR='  # --- fix 19: syncreg (NWP-20261204-23) ---'
RESULT_ECHO='  echo "[roamd] bootsweep result:$_swept $(date)" >> "$LOG"'
BLOCK=$(awk -v h="$HDR" '
  $0 == h { on = 1; print; next }
  on && (index($0, "  # ---") == 1 || index($0, "  # Report what was actually removed") == 1 \
         || index($0, "  echo \"[roamd] bootsweep result:") == 1 || index($0, "  echo \"OK\"") == 1) { exit }
  on { print }' "$SUT")
case "$BLOCK" in *'bootsweep syncreg:'*) ;;
  *) echo "EXTRACTION FAILED: the syncreg block" >&2; exit 2 ;; esac
# The block must sit INSIDE the bootsweep op, after fix 18 and before the Report comment and the result line. Dead
# code outside the op would pass every case below.
POS=$(awk -v h="$HDR" '
  /^if \[ "\$op" = "bootsweep" \]; then$/ { op = NR }
  /^  unset -f _sb_state$/ { sb = NR }
  $0 == h { blk = NR }
  /^  # Report what was actually removed/ { rep = NR }
  /echo "\[roamd\] bootsweep result:\$_swept/ { res = NR }
  END { print (op && sb > op && blk > sb && rep > blk && res > rep) ? "in" : "out" }' "$SUT")
RESULT_PINS=$(grep -Fcx -e "$RESULT_ECHO" "$SUT")
BLOCK_NAMES_SWEPT=$(printf '%s\n' "$BLOCK" | grep -Fc -e '_swept=')
BLOCK_TIMEOUT=$(printf '%s\n' "$BLOCK" | grep -Fc -e 'timeout -k 2 10 abx2xml "$_sr_f" /proc/self/fd/1 </dev/null 2>/dev/null')

# --- harness --------------------------------------------------------------------------------------------
# The runner's PATH: links to the plain tools only, so no real abx2xml (or anything else) can be reached. Each link is
# the tool's FILE (`type -P`), never what `command -v` names: bash names its printf builtin, so the link was never made,
# and mksh, which has no printf builtin, read every planted file as absent. A tool with no file stops the suite.
mkdir -p "$W/bin"
for t in ls head tr sed sort grep cat tee printf mkdir rm; do
  tp=$(type -P "$t") && case "$tp" in /*) ln -s "$tp" "$W/bin/$t" ;; *) false ;; esac \
    || { echo "HARNESS FAILED: no file for $t" >&2; exit 2; }
done
RUNBLK=$(printf '%s\n' "$BLOCK" | sed -e 's@/data/@$R/data/@g')
STUBS=$(cat <<'EOF'
date(){ case "${1:-}" in +%s) echo 100 ;; *) echo DATE ;; esac; }
timeout(){ shift 3; "$@"; }
ls(){
  for _st_last; do :; done
  case " ${DENY_LS:-} " in *" $_st_last "*) return 1 ;; esac
  command ls "$@"
}
case "$ABX" in
  ok) abx2xml(){ cat "$R/../sidecar.xml" > "$2"; } ;;
  fail) abx2xml(){ return 1; } ;;
esac
EOF
)
# runblk <case dir>: the root is <case dir>/root, the LOG <case dir>/log, stderr <case dir>/stderr; every record of
# the run lives beside the root, never in it. The block runs from <case dir>/run.sh under "$SHP", then the op's real
# result echo, then a record of what the block left set.
runblk(){
  local c="$1" f="$1/run.sh" n v
  {
    printf "PATH='%s'\n" "$W/bin"
    for n in R ABX DENY_LS; do
      if [ "$n" = R ]; then v=$c/root; else v=${!n:-}; fi
      case "$v" in *"'"*) echo "runblk: a quote in $n" >&2; return 2 ;; esac
      printf "%s='%s'\n" "$n" "$v"
    done
    printf '%s\n' 'LOG="$R/../log"; STATE="$R/state"; _swept=" sentinel=1"' "$STUBS" \
      'if command -v abx2xml >/dev/null 2>&1; then echo yes > "$R/../abx-seen"; else echo no > "$R/../abx-seen"; fi' \
      "$RUNBLK" "$RESULT_ECHO"
    printf '%s\n' '_lo=$(set | grep -c "^_sr_"); echo "$_lo" > "$R/../left"' \
      '_lo=$(set | grep -c "syncreg-sentinel"); echo "$_lo" > "$R/../set-sentinel"' \
      'echo "$_swept" > "$R/../swept"'
  } > "$f" || return 2
  "$SHP" "$f" 2>>"$c/stderr"
}
SENT='syncreg-sentinel@example.invalid'
# mkroot <case dir> <kind>: users 0 and 10 have a record, 12 and 13 none. text and abx plant accounts.xml (abx: the
# magic and junk, the text as a sidecar beside the root); nofile leaves the sync dir empty but for a sidecar name;
# nodir has no sync dir; dirfile makes accounts.xml a directory; empty is a zero-byte accounts.xml. The fixture mixes
# one tag per line, several tags on a line and a tag split across lines, and carries the sentinel in every account=,
# type= and authority=.
mkroot(){
  local s="$1/root/data/system"
  mkdir -p "$1/root/state" "$s/users" "$s/sync"
  : > "$s/users/0.xml"; : > "$s/users/10.xml"; : > "$s/users/userlist.xml"
  cat > "$1/sidecar.xml" <<EOF
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<accounts version="3" nextAuthorityId="6" offsetInSeconds="1234" listen-for-tickles="true">
<listenForTickles user="0" enabled="true" />
<listenForTickles user="10" enabled="false" /><listenForTickles user="12" enabled="true" />
<authority id="0" account="$SENT" user="0" type="$SENT" authority="$SENT" enabled="true" syncable="true">
<periodicSync period="86400" flex="3456" />
</authority>
<authority id="1" account="$SENT" user="10" type="$SENT" authority="$SENT" enabled="true" /><authority id="2" account="$SENT" user="12" type="$SENT" authority="$SENT" enabled="false" />
<authority id="3" account="$SENT"
  user="12" type="$SENT" authority="$SENT" />
<authority id="4" account="$SENT" user="13" type="$SENT" authority="$SENT" syncable="false" />
<authority id="5" account="$SENT" type="$SENT" authority="$SENT" enabled="true" />
</accounts>
EOF
  case "$2" in
    text) cp "$1/sidecar.xml" "$s/sync/accounts.xml" ;;
    abx) printf 'ABX\000\001\002%s\003authority\004' "$SENT" > "$s/sync/accounts.xml" ;;
    nofile) : > "$s/sync/accounts.xml.bak"; : > "$s/sync/accountsXxml" ;;
    nodir) rm -rf "$s/sync" ;;
    dirfile) mkdir "$s/sync/accounts.xml" ;;
    empty) : > "$s/sync/accounts.xml" ;;
  esac
}
# The fixture's counts: 6 authorities (one with no user attribute, so user 0), 3 listenForTickles, users 0 10 12 13,
# stale 12 (two authorities, one tickles) and 13 (one authority). User 12's second authority has its user attribute on
# the line after its tag.
COUNTS='auth=6 tickles=3 users=4 stale_users=2 stale_auth=3 stale_tickles=1'
DASHES='auth=- tickles=- users=- stale_users=- stale_auth=- stale_tickles=-'
line(){ printf '[roamd] bootsweep syncreg: file=%s %s secs=0 DATE' "$1" "$2"; }
RESULT='[roamd] bootsweep result: sentinel=1 DATE'
GRAMMAR='\[roamd\] bootsweep syncreg: file=(unreachable|absent|unreadable|notool|decodefail|abx|text) auth=([0-9]+|-) tickles=([0-9]+|-) users=([0-9]+|-) stale_users=([0-9]+|-) stale_auth=([0-9]+|-) stale_tickles=([0-9]+|-) secs=[0-9]+ DATE'
# listing <case dir>: every path under the root, sorted, with each file's checksum: the planted state.
listing(){ (cd "$1/root" && find . -print | LC_ALL=C sort | while IFS= read -r p; do
  if [ -f "$p" ]; then printf '%s %s\n' "$p" "$(cksum < "$p")"; else printf '%s\n' "$p"; fi; done); }
# check <case dir> <what> <line>: the whole log is exactly the wanted syncreg line and the result line (one syncreg
# line, an unchanged result line, nothing else logged); the line matches the full-line grammar; the sentinel is in no
# log, stderr or variable; _swept is unchanged and nothing _sr_ is left set.
check(){
  local want got n
  want=$(printf '%s\n%s' "$3" "$RESULT")
  got=$(cat "$1/log" 2>/dev/null)
  if [ "$got" = "$want" ]; then ok "$2"; else no "$2 -- log was: $got"; fi
  n=$(grep -Ecx -e "$GRAMMAR" "$1/log" 2>/dev/null)
  [ "$n" = 1 ] && ok "$2: one line matches the token grammar" || no "$2: $n lines match the token grammar"
  got=$(cat "$1/log" "$1/stderr" 2>/dev/null)
  case "$got" in *"$SENT"*) no "$2: the sentinel reached the log or stderr" ;; *) ok "$2: no sentinel in the log or stderr" ;; esac
  [ "$(cat "$1/set-sentinel" 2>/dev/null)" = 0 ] && ok "$2: no sentinel in \`set\` after the block" \
    || no "$2: the sentinel is in \`set\` after the block"
  [ "$(cat "$1/swept" 2>/dev/null)" = " sentinel=1" ] && ok "$2: _swept unchanged" || no "$2: _swept changed"
  [ "$(cat "$1/left" 2>/dev/null)" = 0 ] && ok "$2: no _sr_ variable or function left set" \
    || no "$2: an _sr_ variable or function is left set"
}
# run <kind> <what> <line> [planted]: one case; with `planted`, the root holds exactly what was planted, after as before.
run(){
  local c before after
  c=$(mktemp -d -p "$W"); mkroot "$c" "$1"
  before=$(listing "$c"); runblk "$c"; after=$(listing "$c")
  check "$c" "$2" "$3"
  if [ "${4:-}" = planted ]; then
    [ "$before" = "$after" ] && ok "$2: the root holds exactly the planted files" \
      || no "$2: the root changed -- $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | tr '\n' ' ')"
  fi
  rm -rf "$c"
}

cases(){
echo "== [$SH] position and pins =="
[ "$POS" = in ] && ok "the block sits inside the op, after fix 18 and before the Report comment and the result line" \
  || no "the block is not between fix 18, the Report comment and the result line of the bootsweep op"
[ "$RESULT_PINS" = 1 ] && ok "the op's result echo is the pinned text, once" || no "the result echo changed ($RESULT_PINS matches)"
[ "$BLOCK_NAMES_SWEPT" = 0 ] && ok "the block does not assign _swept" || no "the block assigns _swept"
[ "$BLOCK_TIMEOUT" = 1 ] && ok "abx2xml runs bounded, both arguments, stderr dropped" || no "the abx2xml call is not the pinned one"

echo "== [$SH] (a) a text file: exact counts =="
ABX=none run text "(a) text" "$(line text "$COUNTS")" planted
echo "== [$SH] (b) binary XML decoded through abx2xml: the same counts =="
ABX=ok run abx "(b) abx" "$(line abx "$COUNTS")" planted
echo "== [$SH] (c) binary XML and no abx2xml: notool =="
c=$(mktemp -d -p "$W"); mkroot "$c" abx; ABX=none runblk "$c"
[ "$(cat "$c/abx-seen" 2>/dev/null)" = no ] && ok "(c) the runner reaches no abx2xml" \
  || { no "(c) the runner reaches an abx2xml: the case proves nothing"; }
rm -rf "$c"
ABX=none run abx "(c) notool" "$(line notool "$DASHES")"
echo "== [$SH] (d) abx2xml fails: decodefail =="
ABX=fail run abx "(d) decodefail" "$(line decodefail "$DASHES")" planted
ABX=none run empty "(d) an empty file holds no root: decodefail" "$(line decodefail "$DASHES")"
echo "== [$SH] (e) the sync dir does not list: unreachable, never absent =="
c=$(mktemp -d -p "$W"); mkroot "$c" text; ABX=ok DENY_LS="$c/root/data/system/sync" runblk "$c"
check "$c" "(e) the sync dir denied" "$(line unreachable "$DASHES")"; rm -rf "$c"
ABX=ok run nodir "(e) no sync dir" "$(line unreachable "$DASHES")"
echo "== [$SH] (f) the dir lists and holds no accounts.xml: absent =="
ABX=ok run nofile "(f) absent (a sidecar and a name that differs at the dot do not count)" "$(line absent "$DASHES")"
echo "== [$SH] the file cannot be read: unreadable =="
ABX=ok run dirfile "accounts.xml a directory: unreadable" "$(line unreadable "$DASHES")"
}

# Parse first, then every case, under each shell.
printf '%s\n' "$STUBS" "$RUNBLK" > "$W/parse.sh"
for SH in "${SHELLS[@]}"; do
  SHP=$(command -v "$SH")
  "$SHP" -n "$W/parse.sh" 2>/dev/null || { no "THE BLOCK DOES NOT PARSE under $SH"; exit 2; }
  cases
done
SH=all

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite) =="
  M=$(mktemp -d -p "$W")
  # A mutant convicts only when its re-run under EACH shell exits 1 with a FAIL line tagged for that shell.
  mutate(){
    local SH=all s out rc ev
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $1"; return; fi
    for s in "${SHELLS[@]}"; do
      SH=$s
      out=$(ONLY_SHELL="$s" TMPDIR="$W" bash "$0" "$M/m.sh" 2>&1); rc=$?
      ev=$(printf '%s\n' "$out" | grep -F "  FAIL  [$s] " || true)
      if [ "$rc" = 0 ]; then no "NOT CONVICTED: $1 -- suite passes on broken code"
      elif [ "$rc" != 1 ]; then no "MUTANT BROKEN: $1 (rc=$rc)"
      elif [ -z "$ev" ]; then no "UNPROVEN: $1 -- rc 1 with no FAIL line under $s"
      else ok "convicted: $1"; printf '%s\n' "$ev" | head -3 | sed 's/^/        /'; fi
    done
  }
  ECHO='/^  echo "\[roamd\] bootsweep syncreg:/'
  # S1 -> (a)/(b) counts: stale_users and its entries count the users WITH a record.
  mutate "S1 the stale test inverted" 's@\[ ! -e "/data/system/users/$_sr_u.xml" \]@[ -e "/data/system/users/$_sr_u.xml" ]@'
  # S2 -> (b) reads decodefail, not abx: the binary file goes to the reducer raw.
  mutate "S2 the ABX branch skipped (the binary file read raw)" \
    's@(abx) timeout -k 2 10 abx2xml "$_sr_f" /proc/self/fd/1 </dev/null 2>/dev/null ;;@(abx) cat "$_sr_f" 2>/dev/null ;;@'
  # S3 -> (a)/(b)/(d) the root holds exactly the planted files.
  mutate "S3 the decoded stream written to \$STATE/.syncreg.x before counting" \
    's@^        esac | tr @        esac | tee "$STATE/.syncreg.x" | tr @'
  # S4 -> (a) the log line, the token grammar and the sentinel check.
  mutate "S4 the line echoes an authority value" \
    "${ECHO}i\\  _sr_F=\"\$_sr_F \$(sed -n 's/.* authority=\"\\\\([^\"]*\\\\)\".*/\\\\1/p' \"\$_sr_f\" 2>/dev/null | head -1)\""
  # S5 -> (e) both cases read absent.
  mutate "S5 an unlistable dir reads absent" 's@then _sr_F=unreachable$@then _sr_F=absent@'
  # S6 -> (c) reads abx with six zeros.
  mutate "S6 notool reads abx with zeros" \
    "${ECHO}i\\  [ \"\$_sr_F\" = notool ] \\&\\& { _sr_F=abx; _sr_a=0; _sr_t=0; _sr_n=0; _sr_su=0; _sr_sa=0; _sr_st=0; }"
  # S7 -> (d) reads abx with six zeros.
  mutate "S7 decodefail reads abx with zeros" \
    "${ECHO}i\\  [ \"\$_sr_F\" = decodefail ] \\&\\& { _sr_F=abx; _sr_a=0; _sr_t=0; _sr_n=0; _sr_su=0; _sr_sa=0; _sr_st=0; }"
  # S8 -> (a)/(b) counts: the user-less authority lands on a recordless id.
  mutate "S8 a user-less authority counted as stale" 's@!s/\.\*/A 0/p@!s/.*/A 99/p@'
  # S9 -> the _swept pin and every case's "_swept unchanged".
  mutate "S9 the block appends to _swept" "${ECHO}a\\  _swept=\"\$_swept syncreg=\$_sr_F\""
  # S10 -> every case's "no _sr_ variable or function left set".
  mutate "S10 the final unset removed" '/^  unset _sr_t0 /d'
  # Extra -> the position pin.
  mutate "the block moved after the result line" \
    '/^  # --- fix 19: syncreg (NWP-20261204-23) ---$/,/^  # Report what was actually removed/{/^  # Report what was actually removed/!{H;d}}; /^  echo "\[roamd\] bootsweep result:/G'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
