#!/usr/bin/env bash
# test-reap-husk-rmdir.sh [<nowhere_roamd.sh>] [--mutate] [--baseline] -- the reap's guarded rmdir of an EMPTY
# /data/system/users/<uid> (NWP-20261119-26, Q038 in docs/product-decisions.md).
#
# WHY THIS IS COMMITTED. reap_userdir_take counts an empty users/<uid> as gone and never removes it, because a
# creation in progress looks the same. A husk left in place turns the NWP-20261003-01 framework patch's refusal
# off for that id (it refuses only the re-creation of a MISSING directory), so a later framework writer fills it
# in cleartext. Q038: the reap removes the husk with rmdir at the end of its loop, but only while
# system_server's start count is known and unchanged since the reap's start (ids are not reused within one
# system_server lifetime). Every guard decides by a negative result, which is the shape that fails silently, so
# this suite plants real trees, drives the REAL extracted cleanstorage op under every shell found, and asserts
# what survived, what was called, and the one log line.
#
#   bash test-reap-husk-rmdir.sh                        # the cases + static pins
#   bash test-reap-husk-rmdir.sh --mutate               # ... plus mutants that must each be CONVICTED
#   bash test-reap-husk-rmdir.sh --baseline <old roamd> # R1 must FAIL on the code before this change
#
# Pure logic -- no device. The op and the functions it needs are EXTRACTED from nowhere_roamd.sh by anchor,
# never copied, and re-rooted to a temp tree. sleep is a scripted clock; getprop returns a scripted sequence;
# rm and rmdir are stubbed only to do what a case says they do.
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

# build_body <roamd.sh> <out>: the re-rooted functions + op as one POSIX file, or exit 2 with EXTRACTION FAILED.
build_body() {
  local f="$1" out="$2" fn t funcs="" op n
  for fn in extra_user_paths userdir_has_record userdir_census userdir_census_fold reap_userdir_settle reap_userdir_take; do
    t=$(fn_of "$f" "$fn")
    [ -n "$t" ] || { echo "EXTRACTION FAILED: function $fn not found in $f" >&2; return 2; }
    funcs="$funcs$t"$'\n'
  done
  op=$(op_of "$f" cleanstorage)
  case "$op" in *'_reapleft'*'reap-ledger'*) ;; *) echo "EXTRACTION FAILED: cleanstorage op in $f" >&2; return 2 ;; esac
  if [ "$BASE" = no ]; then
    case "$op" in *'sys.system_server.start_count'*) ;; *) echo "EXTRACTION FAILED: the start_count read in the cleanstorage op of $f" >&2; return 2 ;; esac
  fi
  t=$(reroot "$funcs$op")
  n=$(nleft "$t")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: $n absolute /data path(s) left in live code" >&2; return 2; }
  printf '%s\n' "$t" > "$out"
}

# --- the simulated device -----------------------------------------------------------------------------------
# Stubs, POSIX, sourced by the run script. State that crosses a $( ) lives in files under sim/.
#  sleep:  a scripted clock; sim/ev.<tick> is sourced when the clock reaches it.
#  getprop: the N-th read of sys.system_server.start_count prints line N of sim/ssc (nothing past its end) and
#          counts in sim/gpn; the 2nd read creates sim/loopdone. Any other property prints nothing.
#  rm:     refuses a path in sim/refuse (and anything under it), and one in sim/refuse-loop until sim/loopdone.
#  rmdir:  logs each call to sim/rmdir.calls; sim/rmdir-refuse = fail and do nothing; sim/rmdir-fill = a writer
#          fills the directory first (the real rmdir then fails).
cat > "$W/stubs.sh" <<'EOF'
_TICK=0
userdir_recheck() { :; }; reap_retry_run() { :; }; reap_retry_add() { :; }; userdir_pending_add() { :; }
loc_release() { :; }; md_release() { :; }; dt_release() { :; }; dr_release() { :; }; hs_release() { :; }
ks_reap_clear() { :; }; stop_mediad() { :; }; log_scrub() { :; }; bt_reset() { return 0; }
keystore_push() { KS_VERDICT=sealed; }
sleep() { _TICK=$((_TICK + 1)); echo "$_TICK" > "$ROOT/sim/ticks"; if [ -f "$ROOT/sim/ev.$_TICK" ]; then . "$ROOT/sim/ev.$_TICK"; fi; return 0; }
getprop() {
  if [ "$1" = sys.system_server.start_count ]; then
    _gn=$(cat "$ROOT/sim/gpn" 2>/dev/null || echo 0); _gn=$((_gn + 1)); echo "$_gn" > "$ROOT/sim/gpn"
    [ "$_gn" = 2 ] && : > "$ROOT/sim/loopdone"
    [ -f "$ROOT/sim/ssc" ] && sed -n "${_gn}p" "$ROOT/sim/ssc"
  fi
  return 0
}
_refused() {
  _rf=""
  for _rl in refuse refuse-loop; do
    [ -f "$ROOT/sim/$_rl" ] || continue
    [ "$_rl" = refuse-loop ] && [ -f "$ROOT/sim/loopdone" ] && continue
    while IFS= read -r _rr; do [ -n "$_rr" ] || continue; case "$1" in "$_rr"|"$_rr"/*) _rf=1 ;; esac; done < "$ROOT/sim/$_rl"
  done
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
rmdir() {
  for _ra in "$@"; do _rd="$_ra"; done
  echo "$_rd" >> "$ROOT/sim/rmdir.calls"
  [ -f "$ROOT/sim/rmdir-refuse" ] && return 1
  [ -f "$ROOT/sim/rmdir-fill" ] && : > "$_rd/settings_secure.xml"
  command rmdir "$@"
}
EOF

# mkroot: uid 11 removed; user 0's record present (the anchor sees it); an empty users/11; no FBE tree.
mkroot() {
  R=$(mktemp -d -p "$W")
  mkdir -p "$R/sim" "$R/state" "$R/data/nowhere" "$R/data/system/users/0" "$R/data/system/users/11"
  : > "$R/data/system/users/0.xml"
  U="$R/data/system/users/11"
}
ssc() { printf '%s\n' "$2" "$3" > "$1/sim/ssc"; }

# run <root> <shell> <body>: the op, as a script file, under <shell>. Its stderr must stay empty.
run() {
  local r="$1" sh="$2" body="$3"
  {
    printf 'ROOT=%s\n' "'$r'"
    printf '%s\n' 'uid=11; op=cleanstorage; name=""; pass=""; LANE=rw'
    printf '%s\n' 'LOG="$ROOT/roam.log"; RES="$ROOT/res"; STATE="$ROOT/state"; KS_DROP="$ROOT/keystore-drop"'
    printf '%s\n' 'KS_CREDS="$STATE/ks-creds"; KS_EXPORT="$ROOT/ks-export"; KS_MAP="$ROOT/ks-map"; KS_KEEP="$ROOT/ks-keep"; KS_CENSUS="$ROOT/ks-census"'
    printf '%s\n' 'DE_PARK_ROOT="$STATE/coldde"'
    printf '. %s\n' "'$W/stubs.sh'"
    printf '. %s\n' "'$body'"
  } > "$r/run.sh"
  "$sh" "$r/run.sh" >/dev/null 2>"$r/sim/stderr"
}

# --- the cases ----------------------------------------------------------------------------------------------
# Each case: case_<id> <shell> <body>; it prints one FAIL line per failed check and returns non-zero on any.
# Readers capture into variables (never `cmd | grep -q` under pipefail).
F=0
chk() { if "${@:2}"; then :; else echo "    FAIL $1"; F=1; fi; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
hasnt() { ! has "$1" "$2"; }
eqv() { [ "$1" = "$2" ]; }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
present() { [ -e "$1" ] || [ -L "$1" ]; }
rd() { cat "$1" 2>/dev/null || true; }
common() {  # common <root>: stderr clean, a RES written
  chk "stderr is empty: $(rd "$1/sim/stderr" | head -3)" eqv "$(rd "$1/sim/stderr")" ""
  chk "RES written" present "$1/res"
}
husk_line() { rd "$1/roam.log" | grep 'reap husk user 11' || true; }
clean_line() { rd "$1/roam.log" | grep 'cleanstorage user 11 class=' || true; }

case_R1() {  # empty husk, counts equal -> removed, class not husk
  mkroot; ssc "$R" 5 5; run "$R" "$1" "$2"; common "$R"
  chk "users/11 removed" absent "$U"
  chk "RES is OK" eqv "$(rd "$R/res")" OK
  chk "class=clean" has "$(clean_line "$R")" 'class=clean'
  chk "log: removed (count unchanged)" has "$(husk_line "$R")" 'reap husk user 11: removed (count unchanged)'
  chk "start_count read twice" eqv "$(rd "$R/sim/gpn")" 2
  chk "rmdir called on users/11 once" eqv "$(rd "$R/sim/rmdir.calls")" "$U"
  chk "the log line names no path" hasnt "$(husk_line "$R")" '/'
}
case_R2() {  # counts differ -> kept, husk
  mkroot; ssc "$R" 5 6; run "$R" "$1" "$2"; common "$R"
  chk "users/11 kept" present "$U"
  chk "RES is OK PARTIAL:reap=husk" eqv "$(rd "$R/res")" 'OK PARTIAL:reap=husk'
  chk "class=husk" has "$(clean_line "$R")" 'class=husk'
  chk "log: kept (count changed)" has "$(husk_line "$R")" 'kept (count changed)'
  chk "no rmdir" eqv "$(rd "$R/sim/rmdir.calls")" ""
}
case_R3() {  # count unknown (empty, non-numeric, second read empty) -> kept
  local a b
  for a in ":" "x5:5" "5:" ":5" "5a:5a"; do
    mkroot; ssc "$R" "${a%%:*}" "${a#*:}"; run "$R" "$1" "$2"; common "$R"
    chk "[$a] users/11 kept" present "$U"
    chk "[$a] class=husk" has "$(clean_line "$R")" 'class=husk'
    chk "[$a] log: kept (count unknown)" has "$(husk_line "$R")" 'kept (count unknown)'
    chk "[$a] no rmdir" eqv "$(rd "$R/sim/rmdir.calls")" ""
  done
}
case_R4() {  # a non-empty dir -> never touched by the rmdir step; the rm path as today
  # R4a: rm cannot clear it while the loop runs (the refusal lifts at the 2nd start-count read, which the real
  # code never makes for a non-empty dir -- so a block that skipped the emptiness test and used rm -rf would
  # delete the file).
  mkroot; ssc "$R" 5 5; : > "$U/settings_secure.xml"; echo "$U" > "$R/sim/refuse-loop"
  run "$R" "$1" "$2"; common "$R"
  chk "R4a: the file is still there" present "$U/settings_secure.xml"
  chk "R4a: no rmdir" eqv "$(rd "$R/sim/rmdir.calls")" ""
  chk "R4a: start_count read once" eqv "$(rd "$R/sim/gpn")" 1
  chk "R4a: class=residue" has "$(clean_line "$R")" 'class=residue'
  chk "R4a: log: kept (not empty)" has "$(husk_line "$R")" 'kept (not empty)'
  chk "R4a: the log line names no file" hasnt "$(husk_line "$R")" 'settings_'
  # R4b: rm can clear it -> gone by the rm path, no rmdir, no husk line.
  mkroot; ssc "$R" 5 5; : > "$U/settings_secure.xml"
  run "$R" "$1" "$2"; common "$R"
  chk "R4b: users/11 removed by rm" absent "$U"
  chk "R4b: no rmdir" eqv "$(rd "$R/sim/rmdir.calls")" ""
  chk "R4b: no husk line" eqv "$(husk_line "$R")" ""
  chk "R4b: class=clean" has "$(clean_line "$R")" 'class=clean'
}
case_R5() {  # a symbolic link rm cannot remove -> untouched by the rmdir step
  mkroot; ssc "$R" 5 5; rmdir "$U"; mkdir -p "$R/elsewhere"; ln -s "$R/elsewhere" "$U"; echo "$U" > "$R/sim/refuse"
  run "$R" "$1" "$2"; common "$R"
  chk "the link is still there" eqv "$(readlink "$U" 2>/dev/null)" "$R/elsewhere"
  chk "its target is still there" present "$R/elsewhere"
  chk "no rmdir" eqv "$(rd "$R/sim/rmdir.calls")" ""
  chk "log: kept (link)" has "$(husk_line "$R")" 'kept (link)'
}
case_R6() {  # a record present -> kept
  # R6a: the record lands after the settle (first loop tick), so the anchor is ok.
  mkroot; ssc "$R" 5 5; printf '%s\n' ': > "$ROOT/data/system/users/11.xml.backup"' > "$R/sim/ev.1"
  run "$R" "$1" "$2"; common "$R"
  chk "R6a: users/11 kept" present "$U"
  chk "R6a: no rmdir" eqv "$(rd "$R/sim/rmdir.calls")" ""
  chk "R6a: log: kept (record)" has "$(husk_line "$R")" 'kept (record)'
  # R6b: the record there from the start -> the anchor times out.
  mkroot; ssc "$R" 5 5; : > "$R/data/system/users/11.xml"
  run "$R" "$1" "$2"; common "$R"
  chk "R6b: users/11 kept" present "$U"
  chk "R6b: no rmdir" eqv "$(rd "$R/sim/rmdir.calls")" ""
  chk "R6b: log: kept (anchor timeout)" has "$(husk_line "$R")" 'kept (anchor timeout)'
}
case_R7() {  # rmdir refused -> husk reported
  mkroot; ssc "$R" 5 5; : > "$R/sim/rmdir-refuse"
  run "$R" "$1" "$2"; common "$R"
  chk "R7a: users/11 kept" present "$U"
  chk "R7a: RES is OK PARTIAL:reap=husk" eqv "$(rd "$R/res")" 'OK PARTIAL:reap=husk'
  chk "R7a: class=husk" has "$(clean_line "$R")" 'class=husk'
  chk "R7a: log: kept (rmdir refused)" has "$(husk_line "$R")" 'kept (rmdir refused)'
  # R7b: a writer fills it just before rmdir -> the real rmdir fails, the file stays.
  mkroot; ssc "$R" 5 5; : > "$R/sim/rmdir-fill"
  run "$R" "$1" "$2"; common "$R"
  chk "R7b: the file is still there" present "$U/settings_secure.xml"
  chk "R7b: log: kept (rmdir refused)" has "$(husk_line "$R")" 'kept (rmdir refused)'
}
case_R8() {  # blind anchor -> kept, no rmdir
  mkroot; ssc "$R" 5 5; command rm -f "$R/data/system/users/0.xml"
  run "$R" "$1" "$2"; common "$R"
  chk "users/11 kept" present "$U"
  chk "no rmdir" eqv "$(rd "$R/sim/rmdir.calls")" ""
  chk "log: kept (anchor blind)" has "$(husk_line "$R")" 'kept (anchor blind)'
}
case_R9() {  # users/11 absent -> no husk line, class clean
  mkroot; ssc "$R" 5 5; rmdir "$U"
  run "$R" "$1" "$2"; common "$R"
  chk "no husk line" eqv "$(husk_line "$R")" ""
  chk "class=clean" has "$(clean_line "$R")" 'class=clean'
  chk "no rmdir" eqv "$(rd "$R/sim/rmdir.calls")" ""
}
CASES="R1 R2 R3 R4 R5 R6 R7 R8 R9"

# run_cases <body> <cases> <quiet>: every case under every shell. Prints `FAILED <case> [<shell>]` per failure.
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
static_pins() {
  local f="$1" op ok=0 a b
  op=$(op_of "$f" cleanstorage)
  a=$(printf '%s\n' "$op" | grep -n '^  _ud_ssc0=$(getprop sys.system_server.start_count 2>/dev/null)' | head -1 | cut -d: -f1)
  b=$(printf '%s\n' "$op" | grep -n '^  userdir_recheck' | head -1 | cut -d: -f1)
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "  ok    pin: the first start-count read is before userdir_recheck"
  else echo "  FAIL  pin: the first start-count read is before userdir_recheck"; ok=1; fi
  a=$(printf '%s\n' "$op" | grep -n 'rmdir "$_ud_d"' | head -1 | cut -d: -f1)
  b=$(printf '%s\n' "$op" | grep -n '^  _reapclass=clean' | head -1 | cut -d: -f1)
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "  ok    pin: the rmdir is before the classification"
  else echo "  FAIL  pin: the rmdir is before the classification"; ok=1; fi
  if has "$op" '[ "$_ud_ssc0" != "$_ud_ssc1" ]' && hasnt "$op" '_ud_ssc0" -eq' && hasnt "$op" '_ud_ssc0" -ne'; then
    echo "  ok    pin: the counts are compared as strings (mksh reads a non-number as 0 in -eq)"
  else echo "  FAIL  pin: the counts are compared as strings"; ok=1; fi
  return $ok
}

# --- main ---------------------------------------------------------------------------------------------------
BODY="$W/body.sh"
build_body "$SUT" "$BODY" || exit 2

if [ "$BASE" = yes ]; then
  echo "== baseline: $SUT (R1 must FAIL here) =="
  run_cases "$BODY" R1
  if has "$RUN_FAILED" R1; then echo "baseline: R1 FAILS on the old code, as required"; exit 0; fi
  echo "baseline: R1 HOLDS on the old code -- it proves nothing"; exit 1
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
  # mutant <id> <convicting case> <edit>...: each edit is "<from>|<to>", applied in order.
  mutant() {
    local id="$1" by="$2" m src e sh_ convicted=1; shift 2
    m=$(mktemp -p "$W"); src="$SUT"
    for e in "$@"; do subst "$src" "$m.n" "${e%%|*}" "${e#*|}"; cat "$m.n" > "$m"; command rm -f "$m.n"; src="$m"; done
    if cmp -s "$SUT" "$m"; then echo "  FAIL  $id: the mutant did not apply"; rc=1; return; fi
    local mb; mb=$(mktemp -p "$W")
    if ! build_body "$m" "$mb" 2>/dev/null; then echo "  FAIL  $id: the mutant could not be extracted"; rc=1; return; fi
    run_cases "$mb" "$by" quiet
    for sh_ in $SHELLS; do
      if has "$RUN_FAILED" "$by[$sh_]"; then echo "  CONVICTED $id by $by [$sh_]"
      else echo "  SURVIVED  $id ($by passes under $sh_)"; convicted=0; fi
    done
    [ "$convicted" = 1 ] || rc=1
  }
  mutant M1-equality-removed R2 \
    'elif [ "$_ud_ssc0" != "$_ud_ssc1" ]; then _ud_hk="count changed"|'
  mutant M2-unknown-as-equal R3 \
    'if [ -z "$_ud_ssc0" ] || [ -z "$_ud_ssc1" ]; then _ud_hk="count unknown"|if false; then _ud_hk="count unknown"'
  mutant M3-emptiness-removed-rm-rf R4 \
    'elif ! _ud_l=$(ls -A "$_ud_d" 2>/dev/null) || [ -n "$_ud_l" ]; then _ud_hk="not empty"|' \
    'elif ! rmdir "$_ud_d" 2>/dev/null|elif ! rm -rf "$_ud_d" 2>/dev/null'
  mutant M4-record-removed R6 \
    'elif userdir_has_record "$uid"; then _ud_hk=record|'
  mutant M5-link-removed R5 \
    'elif [ -L "$_ud_d" ]; then _ud_hk=link|'
  mutant M6-anchor-removed R8 \
    'if [ "$_ud_anchor" != ok ]; then _ud_hk="anchor $_ud_anchor"|if false; then :'
  mutant M7-reapleft-filter-removed R1 \
    '_ud_x=""; for _p in $_reapleft; do [ "$_p" = "$_ud_d" ] || _ud_x="$_ud_x $_p"; done; _reapleft=$_ud_x|:'
fi

if [ "$rc" = 0 ]; then echo "PASS: test-reap-husk-rmdir.sh"; else echo "FAILED: test-reap-husk-rmdir.sh"; fi
exit $rc
