#!/usr/bin/env bash
# test-bootsweep-siblings.sh [<nowhere_roamd.sh>] [--mutate] -- the boot sweep's report-only `siblings` block
# (NWP-20261129-44), run for real rather than grepped.
#
# Four sibling Wi-Fi/network stores sit outside every user and nothing sweeps them (docs/wifi-retention-spec.md §4.8).
# Stage 3's sweep waits on one check (HW3): can roamd's domain see them? The block answers it at every boot, in one
# `bootsweep siblings:` line in roam.log. It must:
#   - give each store its SELinux label and whether its parent is writable (`<label>/w<0|1>`);
#   - read `absent` only when the parent lists and the entry is not there, by a fixed-string whole-line match;
#   - read `unreachable` when the parent cannot be listed, never `absent`;
#   - open no store: neither content nor a directory entry reaches the log;
#   - leave the `bootsweep result:` line byte for byte, and leave no variable or function set.
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR (its header line up to the next `  # ---` header, the Report
# comment or the result echo), never copied and never by line count. Extraction asks only for the header and the
# helper, so a lost line is convicted by the cases that assert it rather than by an extraction exit. /data/ is
# substituted by a temp root. `ls` is a stub because toybox prints the context first and GNU differs, so the stub is
# the format. `[ -w ` is a stub because root ignores mode bits. Each case writes the block, its stubs and its variables
# into a runner file and runs it under each shell found, parsed by that shell first; every line is tagged `[<sh>]`, and
# a mutant convicts only when its re-run under each shell exits 1 with a `FAIL  [<sh>]` line of its own (an exit 2 is a
# broken mutant, never a conviction). bash, dash and mksh always run under their own names; sh is skipped only when it
# is the same binary as one of them; ONLY_SHELL=<name> (internal, the mutant re-run) runs exactly that shell with no
# dedup, and exits 2 when it is not available. Every temp lives under one root, removed on exit.
#
#   bash test-bootsweep-siblings.sh            # the behaviour cases
#   bash test-bootsweep-siblings.sh --mutate   # ... plus mutations that must each CONVICT the suite
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
HDR='  # --- fix 18: siblings (NWP-20261129-44) ---'
RESULT_ECHO='  echo "[roamd] bootsweep result:$_swept $(date)" >> "$LOG"'
BLOCK=$(awk -v h="$HDR" '
  $0 == h { on = 1; print; next }
  on && (index($0, "  # ---") == 1 || index($0, "  # Report what was actually removed") == 1 \
         || index($0, "  echo \"[roamd] bootsweep result:") == 1 || index($0, "  echo \"OK\"") == 1) { exit }
  on { print }' "$SUT")
case "$BLOCK" in *'_sb_state()'*) ;;
  *) echo "EXTRACTION FAILED: the siblings block" >&2; exit 2 ;; esac
# The block must sit INSIDE the bootsweep op, after fix 17 and before the Report comment and the result line. Dead
# code outside the op would pass every case below.
POS=$(awk -v h="$HDR" '
  /^if \[ "\$op" = "bootsweep" \]; then$/ { op = NR }
  /^  _swept="\$_swept staging=\$STAGING_BOOT"$/ { st = NR }
  $0 == h { blk = NR }
  /^  # Report what was actually removed/ { rep = NR }
  /echo "\[roamd\] bootsweep result:\$_swept/ { res = NR }
  END { print (op && st > op && blk > st && rep > blk && res > rep) ? "in" : "out" }' "$SUT")
RESULT_PINS=$(grep -Fcx -e "$RESULT_ECHO" "$SUT")
BLOCK_NAMES_SWEPT=$(printf '%s\n' "$BLOCK" | grep -Fc -e '_swept=')

# --- harness --------------------------------------------------------------------------------------------
# /data/ -> $R/data/. `[ -w ` -> _tw, and ls -> a stub, so a denial can be simulated per path. The stubs are POSIX:
# they run inside the runner file under each shell. `_st_*` names never meet the block's. The stub's label names the
# entry, so two stores swapped on the line cannot pass.
RUNBLK=$(printf '%s\n' "$BLOCK" | sed -e 's@/data/@$R/data/@g' -e 's@\[ -w @_tw @g')
STUBS=$(cat <<'EOF'
_tw(){ case " ${UNW:-} " in *" $1 "*) return 1 ;; esac; return 0; }
date(){ echo DATE; }
ls(){
  for _st_last; do :; done
  case "$1" in
    -Zd)
      case " ${DENY_Z:-} " in *" $_st_last "*) return 1 ;; esac
      [ -e "$_st_last" ] || return 1
      echo "u:object_r:t_${_st_last##*/}:s0 $_st_last" ;;
    -1A)
      case " ${DENY_LS:-} " in *" $_st_last "*) return 1 ;; esac
      command ls -1A "$_st_last" ;;
    *) return 1 ;;
  esac
}
EOF
)
# runblk <root>: the LOG is <root>/log, stderr <root>/stderr. The block runs from <root>/run.sh under "$SHP", then the
# op's real result echo, then a record of what the block left set.
runblk(){
  local r="$1" f="$1/run.sh" n v
  {
    for n in R UNW DENY_LS DENY_Z; do
      if [ "$n" = R ]; then v=$r; else v=${!n:-}; fi
      case "$v" in *"'"*) echo "runblk: a quote in $n" >&2; return 2 ;; esac
      printf "%s='%s'\n" "$n" "$v"
    done
    printf '%s\n' 'LOG="$R/log"; _swept=" sentinel=1"' "$STUBS" "$RUNBLK" "$RESULT_ECHO"
    printf '%s\n' '_lo=$(set | grep -c "^_sb_"); echo "$_lo" > "$R/left-vars"' \
      'if command -v _sb_state >/dev/null 2>&1; then echo yes > "$R/left-fn"; else echo no > "$R/left-fn"; fi'
  } > "$f" || return 2
  "$SHP" "$f" 2>>"$r/stderr"
}
WD=data/misc/apexdata/com.android.wifi; TD=data/misc/apexdata/com.android.tethering
# mkstores <root>: every store, each holding an SSID and a passphrase string; /data/system also holds another file.
mkstores(){
  local p
  mkdir -p "$1/$WD" "$1/$TD/netstats" "$1/data/system"
  for p in "$WD/WifiConfigStoreSoftAp.xml" "$WD/WifiScoreCard.proto" "$WD/WifiHealthMonitor.proto" \
           "$WD/WifiNetworkSuggestionsStore.xml" "$TD/netstats/netstats.bin" data/system/netpolicy.xml; do
    printf '<SSID>SECRETSSID-NOT-FOR-LOG</SSID><PSK>SECRETPASS-NOT-FOR-LOG</PSK>\n' > "$1/$p"
  done
  : > "$1/data/system/UNRELATED-ENTRY"
}
# line <soft> <card> <health> <suggest> <netstats> <netpolicy> <wifidir>: the exact line a case wants.
line(){ printf '[roamd] bootsweep siblings: softap=%s scorecard=%s health=%s suggest=%s netstats=%s netpolicy=%s wifidir=%s DATE' "$@"; }
SOFT=u:object_r:t_WifiConfigStoreSoftAp.xml:s0; CARD=u:object_r:t_WifiScoreCard.proto:s0
HLTH=u:object_r:t_WifiHealthMonitor.proto:s0; SUGG=u:object_r:t_WifiNetworkSuggestionsStore.xml:s0
NETS=u:object_r:t_netstats:s0; NPOL=u:object_r:t_netpolicy.xml:s0; WDIR=u:object_r:t_com.android.wifi:s0
RESULT='[roamd] bootsweep result: sentinel=1 DATE'
# expect <root> <what> <line>: the whole log is exactly the wanted siblings line and the result line, so a case also
# proves one line per run, an unchanged result line, and that nothing else (a listing, a store's content) was logged.
expect(){
  local want got
  want=$(printf '%s\n%s' "$3" "$RESULT")
  got=$(cat "$1/log" 2>/dev/null)
  if [ "$got" = "$want" ]; then ok "$2"; else no "$2 -- log was: $got"; fi
}

cases(){
local T _v
echo "== [$SH] position and pins =="
[ "$POS" = in ] && ok "the block sits inside the op, after fix 17 and before the Report comment and the result line" \
  || no "the block is not between fix 17, the Report comment and the result line of the bootsweep op"
[ "$RESULT_PINS" = 1 ] && ok "the op's result echo is the pinned text, once" || no "the result echo changed ($RESULT_PINS matches)"
[ "$BLOCK_NAMES_SWEPT" = 0 ] && ok "the block does not assign _swept" || no "the block assigns _swept"

echo "== [$SH] every store present: label and w1 =="
T=$(mktemp -d -p "$W"); mkstores "$T"; runblk "$T"
expect "$T" "each field is its own label and /w1" \
  "$(line "$SOFT/w1" "$CARD/w1" "$HLTH/w1" "$SUGG/w1" "$NETS/w1" "$NPOL/w1" "$WDIR/w1")"
[ "$(grep -c 'bootsweep siblings:' "$T/log")" = 1 ] && ok "exactly one siblings line" || no "not exactly one siblings line"
[ "$(grep -Fxc -e "$RESULT" "$T/log")" = 1 ] && ok "the result line is unchanged" || no "the result line changed"
[ "$(cat "$T/left-vars" 2>/dev/null)" = 0 ] && ok "no _sb_ variable is left set" || no "an _sb_ variable is left set"
[ "$(cat "$T/left-fn" 2>/dev/null)" = no ] && ok "the helper is not left defined" || no "the helper is left defined"
echo "== [$SH] nothing of a store reaches the log or stderr =="
_v=$(cat "$T/log" "$T/stderr" 2>/dev/null)
case "$_v" in *SECRETSSID*) no "the SSID string reached the log" ;; *) ok "no SSID string in the log or stderr" ;; esac
case "$_v" in *SECRETPASS*) no "the passphrase string reached the log" ;; *) ok "no passphrase string in the log or stderr" ;; esac
case "$_v" in *UNRELATED-ENTRY*) no "a directory entry reached the log" ;; *) ok "no directory entry in the log or stderr" ;; esac
rm -rf "$T"

echo "== [$SH] an unwritable parent reads w0 on its own fields only =="
T=$(mktemp -d -p "$W"); mkstores "$T"; UNW="$T/$WD" runblk "$T"
expect "$T" "the wifi directory unwritable: the four stores read /w0" \
  "$(line "$SOFT/w0" "$CARD/w0" "$HLTH/w0" "$SUGG/w0" "$NETS/w1" "$NPOL/w1" "$WDIR/w1")"; rm -rf "$T"
T=$(mktemp -d -p "$W"); mkstores "$T"; UNW="$T/$TD" runblk "$T"
expect "$T" "the tethering directory unwritable: netstats reads /w0" \
  "$(line "$SOFT/w1" "$CARD/w1" "$HLTH/w1" "$SUGG/w1" "$NETS/w0" "$NPOL/w1" "$WDIR/w1")"; rm -rf "$T"
T=$(mktemp -d -p "$W"); mkstores "$T"; UNW="$T/data/system" runblk "$T"
expect "$T" "/data/system unwritable: netpolicy reads /w0" \
  "$(line "$SOFT/w1" "$CARD/w1" "$HLTH/w1" "$SUGG/w1" "$NETS/w1" "$NPOL/w0" "$WDIR/w1")"; rm -rf "$T"
T=$(mktemp -d -p "$W"); mkstores "$T"; UNW="$T/data/misc/apexdata" runblk "$T"
expect "$T" "apexdata unwritable: wifidir reads /w0" \
  "$(line "$SOFT/w1" "$CARD/w1" "$HLTH/w1" "$SUGG/w1" "$NETS/w1" "$NPOL/w1" "$WDIR/w0")"; rm -rf "$T"
T=$(mktemp -d -p "$W"); mkstores "$T"; UNW="$T/$WD/WifiScoreCard.proto $T/data/system/netpolicy.xml" runblk "$T"
expect "$T" "an unwritable ENTRY changes nothing: the test is on the parent" \
  "$(line "$SOFT/w1" "$CARD/w1" "$HLTH/w1" "$SUGG/w1" "$NETS/w1" "$NPOL/w1" "$WDIR/w1")"; rm -rf "$T"

echo "== [$SH] a missing entry under a listable parent reads absent =="
T=$(mktemp -d -p "$W"); mkstores "$T"; rm -f "$T/$WD/WifiConfigStoreSoftAp.xml"; runblk "$T"
expect "$T" "softap absent" "$(line absent "$CARD/w1" "$HLTH/w1" "$SUGG/w1" "$NETS/w1" "$NPOL/w1" "$WDIR/w1")"; rm -rf "$T"
T=$(mktemp -d -p "$W"); mkstores "$T"; rm -f "$T/$WD/WifiScoreCard.proto"; runblk "$T"
expect "$T" "scorecard absent" "$(line "$SOFT/w1" absent "$HLTH/w1" "$SUGG/w1" "$NETS/w1" "$NPOL/w1" "$WDIR/w1")"; rm -rf "$T"
T=$(mktemp -d -p "$W"); mkstores "$T"; rm -f "$T/$WD/WifiHealthMonitor.proto"; runblk "$T"
expect "$T" "health absent" "$(line "$SOFT/w1" "$CARD/w1" absent "$SUGG/w1" "$NETS/w1" "$NPOL/w1" "$WDIR/w1")"; rm -rf "$T"
T=$(mktemp -d -p "$W"); mkstores "$T"; rm -f "$T/$WD/WifiNetworkSuggestionsStore.xml"; runblk "$T"
expect "$T" "suggest absent" "$(line "$SOFT/w1" "$CARD/w1" "$HLTH/w1" absent "$NETS/w1" "$NPOL/w1" "$WDIR/w1")"; rm -rf "$T"
T=$(mktemp -d -p "$W"); mkstores "$T"; rm -rf "$T/$TD/netstats"; runblk "$T"
expect "$T" "netstats absent" "$(line "$SOFT/w1" "$CARD/w1" "$HLTH/w1" "$SUGG/w1" absent "$NPOL/w1" "$WDIR/w1")"; rm -rf "$T"
T=$(mktemp -d -p "$W"); mkstores "$T"; rm -f "$T/data/system/netpolicy.xml"; runblk "$T"
expect "$T" "netpolicy absent" "$(line "$SOFT/w1" "$CARD/w1" "$HLTH/w1" "$SUGG/w1" "$NETS/w1" absent "$WDIR/w1")"; rm -rf "$T"

echo "== [$SH] the match is fixed-string and whole-line =="
T=$(mktemp -d -p "$W"); mkstores "$T"; rm -f "$T/data/system/netpolicy.xml"
: > "$T/data/system/netpolicy.xml.bak"; : > "$T/data/system/netpolicyXxml"; runblk "$T"
expect "$T" "a sidecar and a name that differs at the dot still read absent" \
  "$(line "$SOFT/w1" "$CARD/w1" "$HLTH/w1" "$SUGG/w1" "$NETS/w1" absent "$WDIR/w1")"; rm -rf "$T"

echo "== [$SH] an unlistable parent reads unreachable, never absent =="
T=$(mktemp -d -p "$W"); mkstores "$T"; DENY_LS="$T/$WD" runblk "$T"
expect "$T" "the wifi directory denied: the four stores unreachable, wifidir keeps its label" \
  "$(line unreachable unreachable unreachable unreachable "$NETS/w1" "$NPOL/w1" "$WDIR/w1")"; rm -rf "$T"
T=$(mktemp -d -p "$W"); mkstores "$T"; DENY_LS="$T/$TD" runblk "$T"
expect "$T" "the tethering directory denied: netstats unreachable" \
  "$(line "$SOFT/w1" "$CARD/w1" "$HLTH/w1" "$SUGG/w1" unreachable "$NPOL/w1" "$WDIR/w1")"; rm -rf "$T"
T=$(mktemp -d -p "$W"); mkstores "$T"; DENY_LS="$T/data/system" runblk "$T"
expect "$T" "/data/system denied: netpolicy unreachable" \
  "$(line "$SOFT/w1" "$CARD/w1" "$HLTH/w1" "$SUGG/w1" "$NETS/w1" unreachable "$WDIR/w1")"; rm -rf "$T"
T=$(mktemp -d -p "$W"); mkstores "$T"; DENY_LS="$T/data/misc/apexdata" runblk "$T"
expect "$T" "apexdata denied: wifidir unreachable" \
  "$(line "$SOFT/w1" "$CARD/w1" "$HLTH/w1" "$SUGG/w1" "$NETS/w1" "$NPOL/w1" unreachable)"; rm -rf "$T"

echo "== [$SH] edges =="
T=$(mktemp -d -p "$W"); mkstores "$T"; rm -rf "$T/$WD"; runblk "$T"
expect "$T" "no wifi directory: wifidir absent, and its four stores unreachable (the two fields give the reason)" \
  "$(line unreachable unreachable unreachable unreachable "$NETS/w1" "$NPOL/w1" absent)"; rm -rf "$T"
T=$(mktemp -d -p "$W"); mkstores "$T"; rm -f "$T/$WD"/*; runblk "$T"
expect "$T" "an empty wifi directory that lists: its four stores absent" \
  "$(line absent absent absent absent "$NETS/w1" "$NPOL/w1" "$WDIR/w1")"; rm -rf "$T"
T=$(mktemp -d -p "$W"); mkstores "$T"; DENY_Z="$T/data/system/netpolicy.xml" runblk "$T"
expect "$T" "an entry that lists with no label reads ?/w1, one token, still present" \
  "$(line "$SOFT/w1" "$CARD/w1" "$HLTH/w1" "$SUGG/w1" "$NETS/w1" "?/w1" "$WDIR/w1")"; rm -rf "$T"
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
  mutate "unreachable reported as absent" 's@|| { echo unreachable; return 0; }@|| { echo absent; return 0; }@'
  mutate "absent reported as unreachable" 's@then echo absent; return 0; fi$@then echo unreachable; return 0; fi@'
  mutate "the label dropped" 's@echo "${_sb_z:-?}/w$_sb_w"@echo "/w$_sb_w"@'
  mutate "w always 1" 's@_sb_w=0; \[ -w "$1" \] && _sb_w=1@_sb_w=1@'
  mutate "w tested on the entry, not its parent" 's@\[ -w "$1" \] && _sb_w=1@[ -w "$1/$2" ] \&\& _sb_w=1@'
  mutate "a store's content echoed" '/^  echo "\[roamd\] bootsweep siblings:/i\  cat "$_sb_wd/WifiConfigStoreSoftAp.xml" >> "$LOG"'
  mutate "the listing logged" 's@^\(    \)_sb_c=$(printf@\1printf "%s\\n" "$_sb_l" >> "$LOG"; _sb_c=$(printf@'
  mutate "a store's content sent to stderr" '/^  echo "\[roamd\] bootsweep siblings:/i\  cat "$_sb_wd/WifiConfigStoreSoftAp.xml" >\&2'
  mutate "softap dropped from the line" 's@ softap=$_sb_soft@@'
  mutate "scorecard dropped from the line" 's@ scorecard=$_sb_card@@'
  mutate "health dropped from the line" 's@ health=$_sb_hlth@@'
  mutate "suggest dropped from the line" 's@ suggest=$_sb_sugg@@'
  mutate "netstats dropped from the line" 's@ netstats=$_sb_nets@@'
  mutate "netpolicy dropped from the line" 's@ netpolicy=$_sb_npol@@'
  mutate "wifidir dropped from the line" 's@ wifidir=$_sb_wdir@@'
  mutate "the line missing" '/^  echo "\[roamd\] bootsweep siblings:/d'
  mutate "the line printed twice" '/^  echo "\[roamd\] bootsweep siblings:/p'
  mutate "two stores swapped on the line" 's@softap=$_sb_soft scorecard=$_sb_card@softap=$_sb_card scorecard=$_sb_soft@'
  mutate "the block appends to _swept" '/^  echo "\[roamd\] bootsweep siblings:/a\  _swept="$_swept siblings=$_sb_soft"'
  mutate "a variable left set" 's@^  unset _sb_wd _sb_soft @  unset _sb_wd @'
  mutate "the helper left defined" '/^  unset -f _sb_state$/d'
  mutate "a name matched as a pattern, not fixed-string" 's@grep -Fcx -e "$2"@grep -cx -e "$2"@'
  mutate "a name matched as a substring, not whole-line" 's@grep -Fcx -e "$2"@grep -Fc -e "$2"@'
  mutate "the result echo changed" 's@^  echo "\[roamd\] bootsweep result:$_swept $(date)" >> "$LOG"$@  echo "[roamd] bootsweep result:$_swept siblings $(date)" >> "$LOG"@'
  mutate "the block moved after the result line" \
    '/^  # --- fix 18: siblings (NWP-20261129-44) ---$/,/^  # Report what was actually removed/{/^  # Report what was actually removed/!{H;d}}; /^  echo "\[roamd\] bootsweep result:/G'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
