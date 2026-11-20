#!/usr/bin/env bash
# test-bootsweep-sysinventory.sh [<nowhere_roamd.sh>] [--mutate] -- the boot sweep's report-only `sysinventory` block
# (NWP-20261204-24), run for real rather than grepped.
#
# ci/check-durable-state.py fences the /data/system paths the tree names in code against the fourth table of
# docs/threat-model.md section 2. The framework stores our source never names (device_policies.xml, overlays.xml and
# their class) only a phone can enumerate, so the block prints, at every boot, one `bootsweep sysinventory:` line in
# roam.log naming each top-level /data/system entry the table does not list. It must:
#   - count a name of the table as listed, and print every other valid name (at most 40, the rest counted as more);
#   - mask, counted and never printed, a name that is empty, over 64 bytes, all digits, holds a character outside
#     A-Za-z0-9_.- or holds two or more dots (package-shaped), and walk the listing one line per entry;
#   - read `unreachable` when the directory does not list, never a count;
#   - leave the `bootsweep result:` line byte for byte, and leave no `_si_` variable set;
#   - (K) keep its list _si_known equal, as a set, to the table's first column (DOC=<path> overrides the doc).
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR (its header line up to the next `  # ---` header, the Report
# comment or the result echo), never copied and never by line count. /data/ is substituted by a temp root. `ls` is a
# stub that fails for a path in DENY_LS and otherwise runs the real ls with the block's own flags. Each case writes the
# block, its stubs and its variables into a runner file and runs it, from the case's root, under each shell found,
# parsed by that shell first; every line is tagged `[<sh>]`, and a mutant convicts only when its re-run under each
# shell exits 1 with a `FAIL  [<sh>]` line of its own (an exit 2 is a broken mutant, never a conviction). bash, dash and
# mksh always run under their own names; sh is skipped only when it is the same binary as one of them;
# ONLY_SHELL=<name> (internal, the mutant re-run) runs exactly that shell with no dedup, and exits 2 when it is not
# available. Every temp lives under one root, removed on exit.
#
#   bash test-bootsweep-sysinventory.sh            # the behaviour cases
#   bash test-bootsweep-sysinventory.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
DOC="${DOC:-$(dirname "$0")/../../../docs/threat-model.md}"
[ -f "$DOC" ] || { echo "no such doc: $DOC" >&2; exit 2; }

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
HDR='  # --- fix 17b: sysinventory (NWP-20261204-24) ---'
RESULT_ECHO='  echo "[roamd] bootsweep result:$_swept $(date)" >> "$LOG"'
BLOCK=$(awk -v h="$HDR" '
  $0 == h { on = 1; print; next }
  on && (index($0, "  # ---") == 1 || index($0, "  # Report what was actually removed") == 1 \
         || index($0, "  echo \"[roamd] bootsweep result:") == 1 || index($0, "  echo \"OK\"") == 1) { exit }
  on { print }' "$SUT")
case "$BLOCK" in *'_si_known="'*'bootsweep sysinventory:'*) ;;
  *) echo "EXTRACTION FAILED: the sysinventory block" >&2; exit 2 ;; esac
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

# K: roamd's list and the fourth table's first column (backticks and one trailing / dropped), each sorted unique.
CODE_KNOWN=$(printf '%s\n' "$BLOCK" | sed -n 's/^  _si_known="\(.*\)"$/\1/p' | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u)
DOC_KNOWN=$(awk '
  index($0, "| Path under `/data/system/` that the tree names") == 1 { on = 1; next }
  on == 1 && /^\|---/ { on = 2; next }
  on == 2 && !/^\|/ { exit }
  on == 2 { split($0, c, "|"); n = c[2]; gsub(/[` ]/, "", n); sub(/\/$/, "", n); if (n != "") print n }' "$DOC" | LC_ALL=C sort -u)
[ -n "$DOC_KNOWN" ] || { echo "EXTRACTION FAILED: the fourth table of $DOC" >&2; exit 2; }
DOC_N=$(printf '%s\n' "$DOC_KNOWN" | grep -c .)

# --- harness --------------------------------------------------------------------------------------------
# /data/ -> $R/data/. The stubs are POSIX: they run inside the runner file under each shell. `_st_*` names never meet
# the block's.
RUNBLK=$(printf '%s\n' "$BLOCK" | sed -e 's@/data/@$R/data/@g')
STUBS=$(cat <<'EOF'
date(){ echo DATE; }
ls(){
  for _st_last; do :; done
  case " ${DENY_LS:-} " in *" $_st_last "*) return 1 ;; esac
  command ls "$@"
}
EOF
)
# runblk <root>: the LOG is <root>/log, stderr <root>/stderr. The block runs from <root>/run.sh under "$SHP" with
# <root> as its working directory (so a name that ran as a command would create <root>/x), then the op's real result
# echo, then a record of what the block left set.
runblk(){
  local r="$1" f="$1/run.sh" n v
  {
    for n in R DENY_LS; do
      if [ "$n" = R ]; then v=$r; else v=${!n:-}; fi
      case "$v" in *"'"*) echo "runblk: a quote in $n" >&2; return 2 ;; esac
      printf "%s='%s'\n" "$n" "$v"
    done
    printf '%s\n' 'LOG="$R/log"; _swept=" sentinel=1"' "$STUBS" "$RUNBLK" "$RESULT_ECHO"
    printf '%s\n' '_lo=$(set | grep -c "^_si_"); echo "$_lo" > "$R/left-vars"'
  } > "$f" || return 2
  (cd "$r" && "$SHP" "$f" 2>>"$r/stderr")
}
# mksys <root> [<name>...]: /data/system holding every name of the doc's table, then each extra name.
mksys(){
  local r="$1" n
  shift
  mkdir -p "$r/data/system"
  for n in $DOC_KNOWN; do : > "$r/data/system/$n"; done
  for n in "$@"; do : > "$r/data/system/$n"; done
}
RESULT='[roamd] bootsweep result: sentinel=1 DATE'
# expect <root> <what> <line>: the whole log is exactly the wanted line and the result line, so a case also proves one
# line per run, an unchanged result line, and that nothing else was logged.
expect(){
  local want got
  want=$(printf '%s\n%s' "$3" "$RESULT")
  got=$(cat "$1/log" 2>/dev/null)
  if [ "$got" = "$want" ]; then ok "$2"; else no "$2 -- log was: $got"; fi
}
inv(){ printf '[roamd] bootsweep sysinventory: entries=%s listed=%s unlisted=%s masked=%s more=%s names=%s DATE' "$@"; }

cases(){
local T _v _w _i _n
echo "== [$SH] position and pins =="
[ "$POS" = in ] && ok "the block sits inside the op, after fix 17 and before the Report comment and the result line" \
  || no "the block is not between fix 17, the Report comment and the result line of the bootsweep op"
[ "$RESULT_PINS" = 1 ] && ok "the op's result echo is the pinned text, once" || no "the result echo changed ($RESULT_PINS matches)"
[ "$BLOCK_NAMES_SWEPT" = 0 ] && ok "the block does not assign _swept" || no "the block assigns _swept"

echo "== [$SH] (f) K: _si_known equals the fourth table's first column =="
if [ "$CODE_KNOWN" = "$DOC_KNOWN" ]; then ok "(f) K: roamd's list and the table hold the same $DOC_N names"
else no "(f) K: roamd's list and the table differ -- roamd: $(echo $CODE_KNOWN) / table: $(echo $DOC_KNOWN)"; fi

echo "== [$SH] (a) every known name plus three framework stores the table lacks =="
T=$(mktemp -d -p "$W"); mksys "$T" netpolicy.xml overlays.xml device_policies.xml; runblk "$T"
expect "$T" "(a) the known names listed, the three named in C order" \
  "$(inv $((DOC_N + 3)) "$DOC_N" 3 0 0 device_policies.xml,netpolicy.xml,overlays.xml)"
[ "$(cat "$T/left-vars" 2>/dev/null)" = 0 ] && ok "(e) no _si_ variable is left set" || no "(e) an _si_ variable is left set"
[ "$(grep -Fxc -e "$RESULT" "$T/log")" = 1 ] && ok "(e) the result line is byte for byte as without the block" \
  || no "(e) the result line changed"
rm -rf "$T"

echo "== [$SH] (b) numeric, package-shaped, spaced and command-shaped names are masked =="
T=$(mktemp -d -p "$W"); mksys "$T" com.example.app 12345 'spacedleft spacedright' '$(touch x)'; runblk "$T"
expect "$T" "(b) four names masked, none printed" "$(inv $((DOC_N + 4)) "$DOC_N" 0 4 0 -)"
_v=$(cat "$T/log" "$T/stderr" 2>/dev/null)
for _w in example 12345 spacedleft spacedright touch; do
  case "$_v" in *"$_w"*) no "(b) '$_w' reached the log or stderr" ;; *) ok "(b) no '$_w' in the log or stderr" ;; esac
done
[ -e "$T/x" ] && no "(b) a name ran as a command (x was created)" || ok "(b) no name ran as a command"
rm -rf "$T"

echo "== [$SH] (b2) a control character and an over-long name are masked =="
T=$(mktemp -d -p "$W"); mksys "$T" "$(printf 'nlleft\nnlright')" "$(printf 'tableft\ttabright')" "$(printf 'L%.0s' $(seq 65))"
: > "$T/data/system/$(printf 'M%.0s' $(seq 64))"; runblk "$T"
expect "$T" "(b2) a newline, a tab and 65 bytes masked; 64 bytes printed" \
  "$(inv $((DOC_N + 4)) "$DOC_N" 1 3 0 "$(printf 'M%.0s' $(seq 64))")"
case "$(cat "$T/log")" in *nlleft*|*nlright*|*tableft*|*LLLL*) no "(b2) a masked name reached the log" ;;
  *) ok "(b2) no masked name in the log" ;; esac
rm -rf "$T"

echo "== [$SH] (c) 45 unknown names: 40 printed, 5 counted as more =="
T=$(mktemp -d -p "$W"); mkdir -p "$T/data/system"; _n=""
for _i in $(seq -w 0 44); do : > "$T/data/system/zz$_i"; done
for _i in $(seq -w 0 39); do _n="$_n${_n:+,}zz$_i"; done
runblk "$T"
expect "$T" "(c) the first 40 in C order, more=5" "$(inv 45 0 45 0 5 "$_n")"; rm -rf "$T"

echo "== [$SH] (d) a directory that does not list reads unreachable =="
T=$(mktemp -d -p "$W"); mksys "$T" overlays.xml; DENY_LS="$T/data/system" runblk "$T"
expect "$T" "(d) the unreachable line, no count" '[roamd] bootsweep sysinventory: unreachable DATE'
case "$(cat "$T/log")" in *entries=*) no "(d) unreachable printed a count" ;; *) ok "(d) no entries= when unreachable" ;; esac
[ "$(cat "$T/left-vars" 2>/dev/null)" = 0 ] && ok "(e) no _si_ variable is left set when unreachable" \
  || no "(e) an _si_ variable is left set when unreachable"
rm -rf "$T"
T=$(mktemp -d -p "$W"); runblk "$T"
expect "$T" "(d) a missing directory reads unreachable" '[roamd] bootsweep sysinventory: unreachable DATE'; rm -rf "$T"

echo "== [$SH] (d2) an empty directory reads all zeros =="
T=$(mktemp -d -p "$W"); mkdir -p "$T/data/system"; runblk "$T"
expect "$T" "(d2) entries=0 and names=-" "$(inv 0 0 0 0 0 -)"; rm -rf "$T"
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
  # convict <label> <sut> <doc>: the re-run under EACH shell exits 1 with a FAIL line tagged for that shell.
  convict(){
    local SH=all s out rc ev
    for s in "${SHELLS[@]}"; do
      SH=$s
      out=$(ONLY_SHELL="$s" TMPDIR="$W" DOC="$3" bash "$0" "$2" 2>&1); rc=$?
      ev=$(printf '%s\n' "$out" | grep -F "  FAIL  [$s] " || true)
      if [ "$rc" = 0 ]; then no "NOT CONVICTED: $1 -- suite passes on broken code"
      elif [ "$rc" != 1 ]; then no "MUTANT BROKEN: $1 (rc=$rc)"
      elif [ -z "$ev" ]; then no "UNPROVEN: $1 -- rc 1 with no FAIL line under $s"
      else ok "convicted: $1"; printf '%s\n' "$ev" | head -3 | sed 's/^/        /'; fi
    done
  }
  # mutate <label> <sed on roamd>
  mutate(){
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $1"; return; fi
    convict "$1" "$M/m.sh" "$DOC"
  }
  # mutate_doc <label> <sed on the doc>: the real roamd against an edited copy of the doc.
  mutate_doc(){
    if ! sed "$2" "$DOC" > "$M/doc.md" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$DOC" "$M/doc.md"; then no "MUTATION INERT: $1"; return; fi
    convict "$1" "$SUT" "$M/doc.md"
  }
  mutate "the known match removed (a)" 's@case " $_si_known " in \*" $_si_e "\*)@case " $_si_known " in *" NOMATCH "*)@'
  mutate "the two-dot mask removed (b)" '/^        case "$_si_e" in \*\.\*\.\*) _si_b=1 ;; esac$/d'
  mutate "the loop split on default IFS (b)" 's@while IFS= read -r _si_e; do@for _si_e in $_si_l; do@'
  mutate "the digit mask removed (b)" '/^        case "$_si_e" in \*\[!0-9\]\*) ;; \*) _si_b=1 ;; esac$/d'
  mutate "the character mask removed (b)" '/^        case "$_si_e" in \*\[!A-Za-z0-9_.-\]\*) _si_b=1 ;; esac$/d'
  mutate "names printed unfiltered (b)" 's@if \[ "$_si_b" = 1 \]; then@if false; then@'
  mutate "ls -q dropped (b2)" 's@LC_ALL=C ls -1Aq "/data/system"@LC_ALL=C ls -1A "/data/system"@'
  mutate "the length mask removed (b2)" 's@ || \[ "${#_si_e}" -gt 64 \]@@'
  mutate "the 40 cap removed (c)" 's@if \[ "$_si_c" -lt 40 \]@if [ "$_si_c" -lt 1000 ]@'
  mutate "unreachable reading entries=0 (d)" \
    's@echo "\[roamd\] bootsweep sysinventory: unreachable $(date)"@echo "[roamd] bootsweep sysinventory: entries=0 listed=0 unlisted=0 masked=0 more=0 names=- $(date)"@'
  mutate "the empty-listing guard removed (d2)" 's@^    if \[ -n "$_si_l" \]; then$@    if true; then@'
  mutate "the unset removed (e)" '/^  unset _si_known _si_l /d'
  mutate "the block appends to _swept (pins)" '/^  unset _si_known _si_l /i\  _swept="$_swept sysinventory=1"'
  mutate "the result echo changed (e)" \
    's@^  echo "\[roamd\] bootsweep result:$_swept $(date)" >> "$LOG"$@  echo "[roamd] bootsweep result:$_swept sysinventory $(date)" >> "$LOG"@'
  mutate "the line missing (a)" '/^    echo "\[roamd\] bootsweep sysinventory: entries=/d'
  mutate "dropbox dropped from _si_known (f)" '/^  _si_known="/s@ dropbox@@'
  mutate_doc "a table row deleted from the doc (f)" '/^| `dropbox` | /d'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
