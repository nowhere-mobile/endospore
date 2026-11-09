#!/usr/bin/env bash
# test-reap-loop-polls.sh [<nowhere_roamd.sh>] [--mutate] [--baseline] -- the cleanstorage roam.log line logs the
# quiet-tail loop's polls and its final cap (NWP-20261128-39, Q039 in docs/product-decisions.md).
#
# WHY THIS IS COMMITTED. Q039 decides whether the reap's longer hold on the RW lane is accepted or shortened, and
# it decided to measure first, from reports. The reap waits in two places: the userdir settle (its polls are the
# `polls:` of the line's userdir= field) and the quiet-tail loop after it. Before this slice the loop's polls were
# not logged, so a report could not split the wait. The line now carries ` loop=<n> cap=<n>` right after the
# userdir field: loop= is the number of 0.25 s sleeps the loop ran, cap= its final cap. This suite drives the REAL
# extracted cleanstorage op under every shell found with a counting sleep, and checks that loop= is exactly the
# loop's sleeps, that cap= is the cap the loop ended on, and that the userdir field and the ledger row are as before.
#
#   bash test-reap-loop-polls.sh                        # the cases + static pins
#   bash test-reap-loop-polls.sh --mutate               # ... plus mutants that must each be CONVICTED
#   bash test-reap-loop-polls.sh <old roamd> --baseline # L1 must FAIL on the code before this change
#
# Pure logic -- no device. The op and the functions it needs are EXTRACTED from nowhere_roamd.sh by anchor,
# never copied, and re-rooted to a temp tree. sleep is a counting clock that can run a scripted event at a tick;
# rm is stubbed only to refuse what a case says it refuses.
set -uo pipefail

MUTATE=no; BASE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; --baseline) BASE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for everything this suite makes; the EXIT trap is the only one.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=""
for s in bash dash mksh sh; do
  if command -v "$s" >/dev/null 2>&1; then SHELLS="$SHELLS $s"; else echo "skip $s: not found"; fi
done
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }

# --- extraction ---------------------------------------------------------------------------------------------
fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
op_of() { sed -n "/^if \\[ \"\\\$op\" = \"$2\" \\]; then\$/,/^fi\$/p" "$1"; }
reroot() { printf '%s\n' "$1" | sed -E 's#([" ])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

# build_body <roamd.sh> <out>: the re-rooted functions + op as one POSIX file, or return 2 with EXTRACTION FAILED.
# It holds NO check of the echo text: every mutant below edits that text and must still extract. The text is
# pinned once, against the script under test, in static_pins.
build_body() {
  local f="$1" out="$2" fn t funcs="" op n
  for fn in extra_user_paths userdir_has_record userdir_census userdir_census_fold reap_userdir_settle reap_userdir_take; do
    t=$(fn_of "$f" "$fn")
    [ -n "$t" ] || { echo "EXTRACTION FAILED: function $fn not found in $f" >&2; return 2; }
    funcs="$funcs$t"$'\n'
  done
  op=$(op_of "$f" cleanstorage)
  case "$op" in *'_reapleft'*'reap-ledger'*) ;; *) echo "EXTRACTION FAILED: cleanstorage op in $f" >&2; return 2 ;; esac
  t=$(reroot "$funcs$op")
  n=$(nleft "$t")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: $n absolute /data path(s) left in live code" >&2; return 2; }
  printf '%s\n' "$t" > "$out"
}

# --- the simulated device -----------------------------------------------------------------------------------
# Stubs, POSIX, sourced by the run script. State that crosses a $( ) lives in files under sim/.
#  sleep:   the counting clock; sim/ticks holds the count, and sim/ev.<tick> is sourced when the clock reaches it.
#  getprop: sys.system_server.start_count prints the same number on every read (the husk rmdir's guard holds).
#  rm:      refuses a path in sim/refuse (and anything under it).
cat > "$W/stubs.sh" <<'EOF'
_TICK=0
userdir_recheck() { :; }; reap_retry_run() { :; }; reap_retry_add() { :; }; userdir_pending_add() { :; }
loc_release() { :; }; md_release() { :; }; dt_release() { :; }; dr_release() { :; }; hs_release() { :; }
ks_reap_clear() { :; }; stop_mediad() { :; }; log_scrub() { :; }; bt_reset() { return 0; }
keystore_push() { KS_VERDICT=sealed; }
sleep() { _TICK=$((_TICK + 1)); echo "$_TICK" > "$ROOT/sim/ticks"; if [ -f "$ROOT/sim/ev.$_TICK" ]; then . "$ROOT/sim/ev.$_TICK"; fi; return 0; }
getprop() { [ "$1" = sys.system_server.start_count ] && echo 5; return 0; }
_refused() {
  _rf=""
  if [ -f "$ROOT/sim/refuse" ]; then
    while IFS= read -r _rr; do [ -n "$_rr" ] || continue; case "$1" in "$_rr"|"$_rr"/*) _rf=1 ;; esac; done < "$ROOT/sim/refuse"
  fi
  [ -n "$_rf" ]
}
rm() {
  _rc=0
  for _ra in "$@"; do
    case "$_ra" in -*) continue ;; esac
    if _refused "$_ra"; then _rc=1; else command rm -rf -- "$_ra" || _rc=1; fi
  done
  return $_rc
}
EOF

# mkroot: uid 11 removed; user 0's record present (the anchor sees it at once, so the settle ends at polls:0);
# no users/11 and no FBE tree. A case plants what it needs.
mkroot() {
  R=$(mktemp -d -p "$W")
  mkdir -p "$R/sim" "$R/state" "$R/data/nowhere" "$R/data/system/users/0"
  : > "$R/data/system/users/0.xml"
  U="$R/data/system/users/11"
}
plant() { mkdir -p "$U"; : > "$U/settings_system.xml"; }

# run <root> <shell> <body>: the op, as a script file, under <shell>. Its stderr must stay empty. name is a
# sentinel (no real profile), so "the line carries no name" means something.
run() {
  local r="$1" sh="$2" body="$3"
  {
    printf 'ROOT=%s\n' "'$r'"
    printf '%s\n' 'uid=11; op=cleanstorage; name="SENTINELPROFILE"; pass=""; LANE=rw'
    printf '%s\n' 'LOG="$ROOT/roam.log"; RES="$ROOT/res"; STATE="$ROOT/state"; KS_DROP="$ROOT/keystore-drop"'
    printf '%s\n' 'KS_CREDS="$STATE/ks-creds"; KS_EXPORT="$ROOT/ks-export"; KS_MAP="$ROOT/ks-map"; KS_KEEP="$ROOT/ks-keep"; KS_CENSUS="$ROOT/ks-census"'
    printf '%s\n' 'DE_PARK_ROOT="$STATE/coldde"'
    printf '. %s\n' "'$W/stubs.sh'"
    printf '. %s\n' "'$body'"
  } > "$r/run.sh"
  "$sh" "$r/run.sh" >/dev/null 2>"$r/sim/stderr"
}

# --- the cases ----------------------------------------------------------------------------------------------
# Each case: case_<id> <shell> <body>; it prints one FAIL line per failed check and sets F=1 on any.
# Readers capture into variables (never `cmd | grep -q` under pipefail).
F=0
chk() { if "${@:2}"; then :; else echo "    FAIL $1"; F=1; fi; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
hasnt() { ! has "$1" "$2"; }
eqv() { [ "$1" = "$2" ]; }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
rd() { cat "$1" 2>/dev/null || true; }
cline() { rd "$1/roam.log" | grep '^\[roamd\] cleanstorage user 11 ' || true; }
ledger() { rd "$1/data/nowhere/reap-ledger"; }
# field <line> <key>: the digits after " <key>=" (empty when the field is not there).
field() { printf '%s\n' "$1" | sed -n "s/.* $2=\\([0-9][0-9]*\\) .*/\\1/p"; }
ticks() { local t; t=$(rd "$1/sim/ticks"); echo "${t:-0}"; }

# checks <root> <userdir field> <loop> <cap> <ledger expected: yes|no>: what every case asserts.
checks() {
  local r="$1" udf="$2" lp="$3" cp="$4" led="$5" l lv cv pv tk lg
  l=$(cline "$r"); lv=$(field "$l" loop); cv=$(field "$l" cap); tk=$(ticks "$r")
  pv=$(printf '%s\n' "$l" | sed -n 's/.* userdir=anchor:[a-z]*,polls:\([0-9][0-9]*\),.*/\1/p')
  chk "stderr is empty: $(rd "$r/sim/stderr" | head -3)" eqv "$(rd "$r/sim/stderr")" ""
  chk "one cleanstorage line: [$l]" eqv "$(printf '%s\n' "$l" | grep -c .)" 1
  chk "the userdir field is unchanged and followed by a space: [$l]" has "$l" " userdir=$udf loop="
  chk "the fields are in order, keys= userdir= loop= cap= <date>: [$l]" \
    eqv "$(printf '%s\n' "$l" | sed -nE 's/^\[roamd\] cleanstorage user 11 class=[a-z]+ keys=[a-z]+ userdir=[^ ]+ loop=[0-9]+ cap=[0-9]+ [^ ].*$/ok/p')" ok
  chk "loop=$lp: [$l]" eqv "$lv" "$lp"
  chk "cap=$cp: [$l]" eqv "$cv" "$cp"
  # The settle's polls and the loop's are the op's only sleeps, so polls + loop is the clock's count.
  chk "polls ($pv) + loop ($lv) is the counted sleeps ($tk)" eqv "$(( ${pv:-999} + ${lv:-999} ))" "$tk"
  chk "the line carries no name" hasnt "$l" SENTINELPROFILE
  chk "the line carries no path" hasnt "$l" /
  chk "the line carries no quote" hasnt "$l" '"'
  lg=$(ledger "$r")
  if [ "$led" = yes ]; then
    chk "a ledger row with the same userdir field: [$lg]" has "$lg" " userdir=$udf census:"
    chk "the ledger row has no loop= or cap=: [$lg]" eqv "$(printf '%s\n' "$lg" | grep -cE ' (loop|cap)=')" 0
  else
    chk "no ledger row: [$lg]" eqv "$lg" ""
  fi
}

case_L1() {  # nothing in users/11: the first look ends the loop, no sleep
  mkroot; run "$R" "$1" "$2"
  checks "$R" "anchor:ok,polls:0,after:0" 0 12 no
}
case_L2() {  # a removal at the anchor: the cap rises to 0+13 and the loop runs the 12-poll quiet tail
  mkroot; plant; run "$R" "$1" "$2"
  checks "$R" "anchor:ok,polls:0,after:0,atanchor" 12 13 yes
  chk "users/11 removed" absent "$U"
}
# L3a: a re-creation the rm refuses for good. The removal at the anchor sets cap 13. At tick 5 a writer puts
# users/11 back and the rm refuses it; on the 6th look (_reapi=5) it is counted (after:1) and left, so the cap
# rises once, to 5+13 = 18, and never again (took does not grow). The loop cannot end early with the directory
# left, so it runs out the cap: 18 sleeps.
case_L3a() {
  mkroot; plant
  printf '%s\n' 'mkdir -p "$ROOT/data/system/users/11"; : > "$ROOT/data/system/users/11/settings_ssaid.xml"' \
    'echo "$ROOT/data/system/users/11" > "$ROOT/sim/refuse"' > "$R/sim/ev.5"
  run "$R" "$1" "$2"
  checks "$R" "anchor:ok,polls:0,after:1,atanchor,left" 18 18 yes
}
# L3b: a refused re-creation that the retry clears. The tail from the anchor removal (cap 13) is on its last
# poll when, at tick 12, a writer puts users/11 back and the rm refuses it: the 13th look (_reapi=12) counts it
# (after:1), leaves it and raises the cap once, to 12+13 = 25. At tick 13 the refusal lifts; the 14th look
# (_reapi=13) clears it, which restarts the quiet count (took is past seen). Twelve quiet looks later, on the
# 26th look (_reapi=25), the loop breaks: 25 sleeps, below the cap of 25+1 = 26 that clearing set.
case_L3b() {
  mkroot; plant
  printf '%s\n' 'mkdir -p "$ROOT/data/system/users/11"; : > "$ROOT/data/system/users/11/settings_ssaid.xml"' \
    'echo "$ROOT/data/system/users/11" > "$ROOT/sim/refuse"' > "$R/sim/ev.12"
  printf '%s\n' 'command rm -f "$ROOT/sim/refuse"' > "$R/sim/ev.13"
  run "$R" "$1" "$2"
  checks "$R" "anchor:ok,polls:0,after:1,atanchor" 25 26 yes
  chk "users/11 removed" absent "$U"
}
CASES="L1 L2 L3a L3b"

# run_cases <body> <cases> <quiet>: every case under every shell. Records `<case>[<shell>]` per failure.
run_cases() {
  local body="$1" cases="$2" quiet="${3:-}" c sh out failed=""
  for sh in $SHELLS; do
    for c in $cases; do
      F=0; "case_$c" "$sh" "$body" > "$W/case.out"; out=$(cat "$W/case.out")
      if [ "$F" = 0 ]; then [ -n "$quiet" ] || echo "  ok    $c [$sh]"
      else failed="$failed $c[$sh]"; [ -n "$quiet" ] || { echo "  FAIL  $c [$sh]"; printf '%s\n' "$out"; }
      fi
    done
  done
  RUN_FAILED="$failed"
}

# --- static pins --------------------------------------------------------------------------------------------
# Against the script under test only, never a mutant. A moved or renamed echo is a FAILURE here, not a pass.
static_pins() {
  local f="$1" op ok=0 ln prev
  op=$(op_of "$f" cleanstorage)
  ln=$(printf '%s\n' "$op" | grep -n '^  echo "\[roamd\] cleanstorage user \$uid class=' | cut -d: -f1)
  if [ "$(printf '%s\n' "$ln" | grep -c .)" = 1 ] \
     && has "$(printf '%s\n' "$op" | sed -n "${ln}p")" ' userdir=$_udf loop=$_reapi cap=$_reapcap $(date)" >> "$LOG"'; then
    echo "  ok    pin: the roam.log echo carries userdir=\$_udf loop=\$_reapi cap=\$_reapcap"
  else echo "  FAIL  pin: the roam.log echo carries userdir=\$_udf loop=\$_reapi cap=\$_reapcap"; ok=1; fi
  prev=""; [ -n "$ln" ] && [ "$ln" -gt 1 ] 2>/dev/null && prev=$(printf '%s\n' "$op" | sed -n "$((ln - 1))p")
  if has "$prev" '#' && has "$prev" '(polls + loop) x 0.25 s'; then echo "  ok    pin: the comment above it states (polls + loop) x 0.25 s"
  else echo "  FAIL  pin: the comment above it states (polls + loop) x 0.25 s"; ok=1; fi
  prev=$(printf '%s\n' "$op" | grep 'reap-ledger 2>/dev/null' | grep 'uid=\$uid class=' || true)
  if has "$prev" ' userdir=$_udf census:$_udc"' && hasnt "$prev" 'loop=' && hasnt "$prev" 'cap='; then
    echo "  ok    pin: the reap-ledger row is unchanged (userdir=\$_udf census:, no loop= or cap=)"
  else echo "  FAIL  pin: the reap-ledger row is unchanged"; ok=1; fi
  return $ok
}

# --- main ---------------------------------------------------------------------------------------------------
BODY="$W/body.sh"
build_body "$SUT" "$BODY" || exit 2

if [ "$BASE" = yes ]; then
  echo "== baseline: $SUT (L1 must FAIL here) =="
  run_cases "$BODY" L1
  if has "$RUN_FAILED" L1; then echo "baseline: L1 FAILS on the old code, as required"; exit 0; fi
  echo "baseline: L1 HOLDS on the old code -- it proves nothing"; exit 1
fi

echo "== cases: $SUT =="
rc=0
run_cases "$BODY" "$CASES"
[ -z "$RUN_FAILED" ] || rc=1
static_pins "$SUT" || rc=1

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ]; then
  echo "== mutants (each must be CONVICTED under every shell) =="
  # subst <in> <out> <from> <to>: replace a fixed string on every line holding it; <to> "" deletes the line.
  subst() {
    awk -v a="$3" -v b="$4" '{ i = index($0, a); if (i) { if (b == "") next; $0 = substr($0, 1, i - 1) b substr($0, i + length(a)) } print }' "$1" > "$2"
  }
  # mutant <id> <convicting case> <edit>...: each edit is "<from>|<to>", applied in order; each must apply.
  mutant() {
    local id="$1" by="$2" m src e sh_ mb convicted=1; shift 2
    m=$(mktemp -p "$W"); src="$SUT"
    for e in "$@"; do
      subst "$src" "$m.n" "${e%%|*}" "${e#*|}"
      if cmp -s "$src" "$m.n"; then echo "  FAIL  $id: an edit did not apply: ${e%%|*}"; command rm -f "$m.n"; rc=1; return; fi
      cat "$m.n" > "$m"; command rm -f "$m.n"; src="$m"
    done
    mb=$(mktemp -p "$W")
    if ! build_body "$m" "$mb" 2>/dev/null; then echo "  FAIL  $id: the mutant could not be extracted"; rc=1; return; fi
    run_cases "$mb" "$by" quiet
    for sh_ in $SHELLS; do
      if has "$RUN_FAILED" "$by[$sh_]"; then echo "  CONVICTED $id by $by [$sh_]"
      else echo "  SURVIVED  $id ($by passes under $sh_)"; convicted=0; fi
    done
    [ "$convicted" = 1 ] || rc=1
  }
  mutant M1-loop-prints-the-cap L1 \
    'loop=$_reapi cap=|loop=$_reapcap cap='
  mutant M2-loop-prints-a-copy-taken-before-the-loop L2 \
    '_reapleft=""; _reapi=0; _reapcap=12;|_reapleft=""; _reapi=0; _reapi0=$_reapi; _reapcap=12;' \
    'loop=$_reapi cap=|loop=$_reapi0 cap='
  mutant M3-the-field-is-dropped L1 \
    ' userdir=$_udf loop=$_reapi cap=$_reapcap $(date)| userdir=$_udf $(date)'
  mutant M4-cap-prints-the-base L2 \
    'cap=$_reapcap $(date)|cap=12 $(date)'
fi

if [ "$rc" = 0 ]; then echo "PASS: test-reap-loop-polls.sh"; else echo "FAILED: test-reap-loop-polls.sh"; fi
exit $rc
