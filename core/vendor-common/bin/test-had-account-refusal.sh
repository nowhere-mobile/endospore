#!/usr/bin/env bash
# test-had-account-refusal.sh [<nowhere_roamd.sh>] [--mutate] -- the SEAL side of #743: acct_seal's account guard.
#
# WHY THIS IS COMMITTED. test-had-account-marker.sh pins when .had_account is WRITTEN. This pins what
# acct_seal does with it: a confirmed ZERO account rows on a marked profile returns 4 and removes the stage
# (the head is kept) -- UNLESS the drop was deliberate (NWP-20261104-06, dn-1025 #2): every account that arrived
# (the arrival record, nowhere-acct-arrival) carries a mark in the chooser's marks file, written BEFORE the
# account was removed. Then the drop seals, the log says so, and a sealed drop clears its mark and brings the
# arrival record down to what the head now holds. A positive count seals; an UNREADABLE count fails open; no
# marker, or no tool, never refuses. A wrong acceptance destroys a profile's accounts for good (every vanished
# account must be marked, never just one), a wrong refusal costs one repeated sign-out. The guard reads the marker
# with -e (NWP-20261123-19), so a directory left at .had_account keeps it armed, as a regular file does.
#
#   bash test-had-account-refusal.sh            # the truth table, under every shell present
#   bash test-had-account-refusal.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# Pure shell -- no device, no db. acct_seal, acct_mark_file and acct_mark_hashes run WHOLE (lifted by name, as
# test-roamd-cause-vocab.sh does) with /data/ pointed at a temp root; nowhere_db_fix, `timeout` and $AGENT are
# stubs, `print` (a ksh builtin) and `qn` are shimmed. Exit 2 when an extraction fails or no shell ran; --mutate
# counts a mutant as convicted only when the suite exits 1 on it, so a mutant that breaks an anchor never passes.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
[ ! -e /system/bin/nowhere_db_fix ] || { echo "refusing to run: /system/bin/nowhere_db_fix exists on this host" >&2; exit 2; }
[ ! -e /data/nowhere ] || { echo "refusing to run: /data/nowhere exists on this host" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# --- extraction: the three functions, whole, by name ----------------------------------------------------
FUNCS=""
for fn in acct_seal acct_mark_file acct_mark_hashes; do
  body=$(awk -v h="$fn() {" '$0 == h {f=1} f{print} f&&/^\}$/{exit}' "$SUT")
  case "$body" in "$fn() {"*'}') FUNCS="$FUNCS$body
" ;; *) echo "EXTRACTION FAILED: $fn -- not found by name in $SUT" >&2; exit 2 ;; esac
done
FUNCS=$(printf '%s\n' "$FUNCS" | sed 's#/system/bin/nowhere_db_fix#$T/bin/nowhere_db_fix#g; s#/data/#$T/data/#g')
[ -z "$(printf '%s\n' "$FUNCS" | grep -v '^[[:space:]]*#' | grep -E '(^|[^T])/data/')" ] || { echo "EXTRACTION FAILED: a /data/ path escaped the rewrite" >&2; exit 2; }
case "$FUNCS" in
  *'accounts-count'*'return 4'*) ;;
  *) echo "EXTRACTION FAILED -- anchors moved in $SUT" >&2; exit 2 ;;
esac
QN=$(awk '$0 == "qn() {" {f=1} f{print} f&&/^\}$/{exit}' "$SUT")
case "$QN" in 'qn() {'*'}') ;; *) echo "EXTRACTION FAILED: qn -- anchors moved" >&2; exit 2 ;; esac
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then command printf "%s\n" "$*"; else command printf "%s" "$*"; fi; }'
# Every grep, sed, cut, cat, tr and printf the run executes is recorded with its argv, through _av: an exec'd argv is
# readable by `ps` (DIA-20260812-02), so the cases below assert that no mark hash reaches one. printf is on the list
# because it is /system/bin/printf on Android; bash and dash run it as a builtin, so only a wrapper sees it. print and
# echo are not recorded: mksh runs both as builtins and never execs them. _av and the print shim above write with
# `command printf`, so neither is recorded itself.
ARGV_SHIM='_av(){ command printf "%s\n" "$*" >> "$T/argv"; }; grep(){ _av "$@"; command grep "$@"; }; sed(){ _av "$@"; command sed "$@"; }; cut(){ _av "$@"; command cut "$@"; }; cat(){ _av "$@"; command cat "$@"; }; tr(){ _av "$@"; command tr "$@"; }; printf(){ _av "$@"; command printf "$@"; }'
# A short copy (NWP-20261118-03): cp runs for real, then cuts the staged CE file that $T/cut names to 4 bytes and
# exits 1, as a cp that hit ENOSPC part-way does. No $T/cut, no cut. The temp is inside $T, so inside $W. `command cat`
# keeps the cut out of the argv record ARGV_SHIM keeps.
CP_SHIM='cp(){ command cp "$@"; _cprc=$?; if [ -s "$T/cut" ]; then _cpf="$T/data/nowhere/acct-stage/ce/$(command cat "$T/cut")"; if [ -f "$_cpf" ]; then head -c 4 "$_cpf" > "$T/cut.tmp" && command cat "$T/cut.tmp" > "$_cpf"; _cprc=1; fi; fi; return "$_cprc"; }'

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "${SUITE_SHELLS:-}" ] && SHELLS="$SUITE_SHELLS"
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

# The mark hash, computed here and not by roamd. Planted names are reserved-domain, not real.
h(){ printf '%s' "nowhere-acct-mark-v1:$1" | sha256sum | cut -d' ' -f1; }
X=planted-x@example.invalid; Y=planted-y@example.invalid
HX=$(h "$X"); HY=$(h "$Y")
NL='
'

# setup <dir> : a fixture root. Files the case may set afterwards: count, google (stage db), arr, marks.
# mk <shell> <armed yes|no|dir> <tool: yes|no> <count> <google-output> <agent rc> <arrival|-> <marks|->
# The arrival and marks arguments are the files' exact text ("-" = no file).
CASE=0
mk(){
  T=$(mktemp -d -p "$W") || exit 2
  mkdir -p "$T/data/system_ce/7" "$T/data/system_de/7" "$T/data/nowhere" "$T/state" "$T/bin" "$T/user/7/com.nowhere.chooser/files"
  printf 'CE' > "$T/data/system_ce/7/accounts_ce.db"; printf 'DE' > "$T/data/system_de/7/accounts_de.db"
  [ "$2" = yes ] && : > "$T/state/.had_account"
  [ "$2" = dir ] && mkdir -p "$T/state/.had_account"
  if [ "$3" = yes ]; then
    printf '%s\n' "$4" > "$T/count"; printf '%s' "$5" > "$T/google"
    cat > "$T/bin/nowhere_db_fix" <<STUB
#!/usr/bin/env bash
case "\$1" in
  accounts-count) cat "$T/count" ;;
  accounts-google) cat "$T/google"; exit 0 ;;
  *) exit 2 ;;
esac
STUB
    chmod +x "$T/bin/nowhere_db_fix"
  fi
  printf '%s' "$6" > "$T/arc"
  [ "$7" = - ] || printf '%s' "$7" > "$T/data/system_ce/7/nowhere-acct-arrival"
  [ "$8" = - ] || printf '%s' "$8" > "$T/user/7/com.nowhere.chooser/files/nowhere-acct-marks"
}
MARKS_REL=user/7/com.nowhere.chooser/files/nowhere-acct-marks
ARR_REL=data/system_ce/7/nowhere-acct-arrival

# seal <shell> : run acct_seal in the fixture $T -> prints rc; the case reads files after.
seal(){
  {
    printf '%s\n%s\n%s\n' "$PRINT_SHIM" "$ARGV_SHIM" "$QN"
    printf 'T=%s; STATE=$T/state; LOG=$T/log; ACCT_MARK_ROOT=$T/user; name=probe; pass=x\n' "$T"
    printf 'pw(){ echo x; }; timeout(){ shift 3; "$@"; }\n'
    printf 'agent_stub(){ echo "$*" >> "$T/calls"; return "$(cat "$T/arc")"; }; AGENT=agent_stub\n'
    printf '%s\n' "$CP_SHIM"
    printf '%s\n' "$FUNCS"
    printf 'acct_seal 7; echo "$?" > "$T/res"\n'
  } > "$T/run.sh"
  : > "$T/calls"
  "$1" "$T/run.sh" >/dev/null 2>&1
  cat "$T/res" 2>/dev/null
}
calls(){ grep -c . "$T/calls"; }
logs(){ tr '\n' ' ' < "$T/log" 2>/dev/null; }
lacks(){ case "$(logs)" in *"$1"*) return 1 ;; *) return 0 ;; esac; }
has(){ case "$(logs)" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
noargv(){ [ ! -e "$T/argv" ] || ! grep -qF -e "$HX" -e "$HY" "$T/argv"; }
# verdict <label> <shell> <problem...>
verdict(){ local l="$1" sh="$2"; shift 2; if [ $# -gt 0 ] && [ -n "$*" ]; then no "[$sh] $l -- $*"; else ok "[$sh] $l"; fi; }

# honour <label> <arrival> <marks> <google-after> : count 0, armed -> reaches the push
honour(){
  local label="$1" sh rc bad
  for sh in $SHELLS; do
    mk "$sh" yes yes 0 "$4" 0 "$2" "$3"; rc=$(seal "$sh"); bad=""
    [ "$rc" = 0 ] || bad="rc $rc want 0"
    [ "$(calls)" = 1 ] || bad="$bad; push calls $(calls) want 1"
    has "was signed out on purpose" || bad="$bad; log lacks the honour line"
    has "dn-1025 #2" || bad="$bad; log lacks dn-1025 #2"
    noargv || bad="$bad; a mark hash reached an exec'd argv"
    verdict "$label" "$sh" "$bad"
  done
}
# refuse <label> <case> <arrival> <marks> [<journal text>]
refuse(){
  local label="$1" sh rc bad
  for sh in $SHELLS; do
    mk "$sh" yes yes 0 "0" 0 "$3" "$4"
    [ -z "${5:-}" ] || printf '%s' "$5" > "$T/$MARKS_REL.pending"
    rc=$(seal "$sh"); bad=""
    [ "$rc" = 4 ] || bad="rc $rc want 4"
    [ "$(calls)" = 0 ] || bad="$bad; the push was reached"
    [ ! -d "$T/data/nowhere/acct-stage" ] || bad="$bad; stage left behind"
    has "ZERO account rows" || bad="$bad; log lacks ZERO account rows"
    has "#743" || bad="$bad; log lacks #743"
    has "case: $2" || bad="$bad; log lacks case: $2"
    noargv || bad="$bad; a mark hash reached an exec'd argv"
    verdict "$label" "$sh" "$bad"
  done
}
# plain <label> <armed> <tool> <count> <want-rc> <log-substring>
plain(){
  local label="$1" sh rc bad
  for sh in $SHELLS; do
    mk "$sh" "$2" "$3" "$4" "1
$X
" 0 "2
$HX
$HY
" "$HX
"; rc=$(seal "$sh"); bad=""
    [ "$rc" = "$5" ] || bad="rc $rc want $5"
    [ "$(calls)" = 1 ] || bad="$bad; push calls $(calls) want 1"
    [ -z "$6" ] || has "$6" || bad="$bad; log lacks '$6'"
    verdict "$label" "$sh" "$bad"
  done
}

echo "== a deliberate sign-out seals: every arriving account is marked =="
honour "T=1 marked"        "1
$HX
" "$HX
" "0
"
honour "T=2 both marked"   "2
$HX
$HY
" "$HX
$HY
" "0
"
echo "== any doubt refuses (rc 4, stage removed, the case named) =="
refuse "no marks file"                     "no mark"  "1
$HX
" -
refuse "empty marks file"                  "no mark"  "1
$HX
" ""
refuse "1 of 2 marked"                     "unmarked" "2
$HX
$HY
" "$HX
"
refuse "T=2 with one hash line"            "unmarked" "2
$HX
" "$HX
"
refuse "a ? line"                          "unmarked" "1
?
" "?
$HX
"
refuse "an open journal entry (a rollback that could not land)" "pending" "1
$HX
" "$HX
" "$HX
"
refuse "no arrival file"                   "no record" - "$HX
"
echo "== an emptied journal (nothing unsettled) does not block a marked drop =="
for sh in $SHELLS; do
  mk "$sh" yes yes 0 "0" 0 "1
$HX
" "$HX
"; : > "$T/$MARKS_REL.pending"; rc=$(seal "$sh"); bad=""
  [ "$rc" = 0 ] || bad="rc $rc want 0"
  [ "$(calls)" = 1 ] || bad="$bad; push calls $(calls) want 1"
  verdict "an empty journal seals a marked drop" "$sh" "$bad"
done
echo "== unchanged: positive count, unreadable count, no marker, no tool =="
plain "armed + count 1 seals"       yes yes 1  0 "row(s) staged"
plain "armed + count 7 seals"       yes yes 7  0 "row(s) staged"
plain "armed + count -1 fails open" yes yes -1 0 "row count unavailable"
plain "armed + junk fails open"     yes yes junk 0 "row count unavailable"
plain "armed + empty fails open"    yes yes "" 0 "row count unavailable"
plain "unarmed + count 0 seals"     no  yes 0  0 ""
plain "armed + tool absent seals"   yes no  0  0 ""

echo "== a CE copy cut short refuses; a whole copy seals (NWP-20261118-03) =="
# short <shell> <count> <cut: accounts_ce.db|accounts_ce.db-wal|-> <wal: yes|no> : an armed fixture whose CE db is
# 16 bytes (longer than the 4-byte cut), with a 16-byte -wal when asked.
short(){
  mk "$1" yes yes "$2" "" 0 - -
  printf '0123456789abcdef' > "$T/data/system_ce/7/accounts_ce.db"
  [ "$4" = yes ] && printf 'WAL-0123456789ab' > "$T/data/system_ce/7/accounts_ce.db-wal"
  [ "$3" = - ] || printf '%s' "$3" > "$T/cut"
}
# cut_refuses <label> <count> <file> : the staged <file> is cut short -> rc 4, stage removed, no push, the file named
cut_refuses(){
  local label="$1" sh rc bad
  for sh in $SHELLS; do
    short "$sh" "$2" "$3" yes; rc=$(seal "$sh"); bad=""
    [ "$rc" = 4 ] || bad="rc $rc want 4"
    [ "$(calls)" = 0 ] || bad="$bad; the push was reached"
    [ ! -d "$T/data/nowhere/acct-stage" ] || bad="$bad; stage left behind"
    has "$3 copied short (4B of 16B)" || bad="$bad; log lacks '$3 copied short (4B of 16B)'"
    lacks "row count unavailable" || bad="$bad; the fail-open arm ran on a short copy"
    verdict "$label" "$sh" "$bad"
  done
}
# whole_seals <label> <wal yes|no> : nothing cut -> seals as the positive case does
whole_seals(){
  local label="$1" sh rc bad
  for sh in $SHELLS; do
    short "$sh" 1 - "$2"; rc=$(seal "$sh"); bad=""
    [ "$rc" = 0 ] || bad="rc $rc want 0"
    [ "$(calls)" = 1 ] || bad="$bad; push calls $(calls) want 1"
    has "row(s) staged" || bad="$bad; log lacks 'row(s) staged'"
    lacks "copied short" || bad="$bad; a whole copy was called short"
    verdict "$label" "$sh" "$bad"
  done
}
# empty_refuses <label> <how: empty|absent> : the existing empty/absent refusal keeps its own line
empty_refuses(){
  local label="$1" sh rc bad
  for sh in $SHELLS; do
    mk "$sh" yes yes 1 "" 0 - -
    if [ "$2" = empty ]; then : > "$T/data/system_ce/7/accounts_ce.db"; else rm -f "$T/data/system_ce/7/accounts_ce.db"; fi
    rc=$(seal "$sh"); bad=""
    [ "$rc" = 4 ] || bad="rc $rc want 4"
    [ "$(calls)" = 0 ] || bad="$bad; the push was reached"
    [ ! -d "$T/data/nowhere/acct-stage" ] || bad="$bad; stage left behind"
    has "accounts_ce.db missing/empty in the stage" || bad="$bad; log lacks the empty-db refusal line"
    lacks "copied short" || bad="$bad; the short-copy guard took the empty case"
    verdict "$label" "$sh" "$bad"
  done
}
cut_refuses  "S1 the staged db is cut short, count unreadable: refused, not sealed" "" accounts_ce.db
cut_refuses  "S2 the db is whole, the staged -wal is cut short: refused" 1 accounts_ce.db-wal
whole_seals  "S3 a whole db and a whole -wal seal" yes
whole_seals  "S4 no -wal at the source seals" no
empty_refuses "E1 an empty CE db keeps the empty-db refusal" empty
empty_refuses "E2 an absent CE db keeps the empty-db refusal" absent

echo "== a directory at .had_account keeps the guard armed (NWP-20261123-19) =="
for sh in $SHELLS; do
  mk "$sh" dir yes 0 "0
" 0 - -
  rc=$(seal "$sh"); bad=""
  [ "$rc" = 4 ] || bad="rc $rc want 4"
  [ "$(calls)" = 0 ] || bad="$bad; the push was reached"
  [ ! -d "$T/data/nowhere/acct-stage" ] || bad="$bad; stage left behind"
  has "case: no record" || bad="$bad; log lacks case: no record"
  has "#743" || bad="$bad; log lacks #743"
  verdict "a directory marker refuses a row-empty capture" "$sh" "$bad"

  mk "$sh" dir yes 1 "1
$Y
" 0 "2
$HX
$HY
" "$HX
$HY
"
  rc=$(seal "$sh"); bad=""
  [ "$rc" = 0 ] || bad="rc $rc want 0"
  [ "$(cat "$T/$ARR_REL" 2>/dev/null)" = "1${NL}$HY" ] || bad="$bad; arrival file is not the staged set"
  [ -d "$T/state/.had_account" ] || bad="$bad; the directory marker is gone"
  verdict "a directory marker: a sealed count 1 brings the arrival record to the head" "$sh" "$bad"
done

echo "== after a sealed push (rc 0) =="
for sh in $SHELLS; do
  # a mark whose account left is removed, one still staged is kept; same inode; arrival == staged set
  mk "$sh" yes yes 1 "1
$Y
" 0 "2
$HX
$HY
" "$HX
$HY
"
  i1=$(ls -i "$T/$MARKS_REL" | cut -d' ' -f1); rc=$(seal "$sh"); i2=$(ls -i "$T/$MARKS_REL" 2>/dev/null | cut -d' ' -f1); bad=""
  [ "$rc" = 0 ] || bad="rc $rc"
  [ "$(cat "$T/$MARKS_REL" 2>/dev/null)" = "$HY" ] || bad="$bad; marks file is not exactly the still-staged hash"
  [ "$i1" = "$i2" ] || bad="$bad; marks file inode changed ($i1 -> $i2)"
  [ "$(cat "$T/$ARR_REL" 2>/dev/null)" = "1${NL}$HY" ] || bad="$bad; arrival file is not the staged set"
  [ -f "$T/state/.had_account" ] || bad="$bad; .had_account removed on a non-empty head"
  noargv || bad="$bad; a mark hash reached an exec'd argv"
  verdict "mark of the departed account cleared, the staged one kept, in place; arrival = staged" "$sh" "$bad"

  # a honoured zero-count drop removes marks, arrival and .had_account
  mk "$sh" yes yes 0 "0
" 0 "1
$HX
" "$HX
"
  rc=$(seal "$sh"); bad=""
  [ "$rc" = 0 ] || bad="rc $rc"
  [ ! -e "$T/$MARKS_REL" ] || bad="$bad; marks file left"
  [ ! -e "$T/$ARR_REL" ] || bad="$bad; arrival file left"
  [ ! -e "$T/state/.had_account" ] || bad="$bad; .had_account left"
  verdict "a zero-count drop removes the marks, the arrival record and .had_account" "$sh" "$bad"

  # an unarmed profile: nothing created
  mk "$sh" no yes 1 "1
$Y
" 0 - "$HX
"
  rc=$(seal "$sh"); bad=""
  [ "$rc" = 0 ] || bad="rc $rc"
  [ ! -e "$T/state/.had_account" ] || bad="$bad; .had_account was created"
  [ ! -e "$T/$ARR_REL" ] || bad="$bad; an arrival file was created"
  [ ! -e "$T/$MARKS_REL" ] || bad="$bad; an unrelated mark survived"
  verdict "an unarmed profile never gets .had_account or an arrival record" "$sh" "$bad"

  # a failed push changes nothing
  mk "$sh" yes yes 0 "0
" 1 "1
$HX
" "$HX
"
  cp "$T/$MARKS_REL" "$T/m.before"; cp "$T/$ARR_REL" "$T/a.before"; rc=$(seal "$sh"); bad=""
  [ "$rc" = 1 ] || bad="rc $rc want 1"
  cmp -s "$T/m.before" "$T/$MARKS_REL" || bad="$bad; marks file changed after rc != 0"
  cmp -s "$T/a.before" "$T/$ARR_REL" || bad="$bad; arrival file changed after rc != 0"
  [ -f "$T/state/.had_account" ] || bad="$bad; .had_account removed after rc != 0"
  verdict "rc != 0 leaves the marks, the arrival record and .had_account alone" "$sh" "$bad"

  # two sign-outs in sequence
  mk "$sh" yes yes 1 "1
$Y
" 0 "2
$HX
$HY
" "$HX
"
  rc=$(seal "$sh"); bad=""
  [ "$rc" = 0 ] || bad="seal 1 rc $rc"
  printf '%s\n' "$HY" >> "$T/$MARKS_REL"
  printf '%s' "0
" > "$T/google"; printf '0\n' > "$T/count"
  : > "$T/calls"; rc=$(seal "$sh")
  [ "$rc" = 0 ] || bad="$bad; seal 2 rc $rc"
  [ "$(calls)" = 1 ] || bad="$bad; seal 2 did not reach the push"
  has "was signed out on purpose" || bad="$bad; seal 2 not honoured"
  verdict "two sign-outs in sequence: X, then Y, both seal" "$sh" "$bad"

  # no planted name, no hash in the log
  bad=""
  mk "$sh" yes yes 0 "0
" 0 "1
$HX
" "$HX
"; seal "$sh" >/dev/null
  has "planted" && bad="a planted name is in the log"
  has "$HX" && bad="$bad; a hash is in the log"
  mk "$sh" yes yes 0 "0
" 0 "2
$HX
$HY
" "$HX
"; seal "$sh" >/dev/null
  has "planted" && bad="$bad; a planted name is in the refusal log"
  has "$HX" && bad="$bad; a hash is in the refusal log"
  verdict "the log names neither an account nor a hash" "$sh" "$bad"
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted, under EACH shell) =="
  M=$(mktemp -d -p "$W") || exit 2
  mutate(){
    local desc="$1" expr="$2" s rc
    if ! sed "$expr" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $desc"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $desc"; return; fi
    for s in $SHELLS; do
      SUITE_SHELLS="$s" bash "$0" "$M/m.sh" >/dev/null 2>&1; rc=$?
      case $rc in
        1) ok "convicted [$s]: $desc" ;;
        0) no "NOT CONVICTED [$s]: $desc -- suite passes on broken code" ;;
        *) no "NOT CONVICTED [$s] (rc $rc, extraction?): $desc" ;;
      esac
    done
  }
  mutate "the 0) arm is deleted (a rowless capture falls to the byte check and seals)" \
         '/^      0)$/,/^        ;;$/{/^      0)$/s/0)/9999999)/}'
  mutate "the unreadable arm refuses too (every unrelated schema change blocks all seals)" \
         "/^      ''|-1|\*\[!0-9\]\*)\$/,/^        ;;\$/{s/^        ;;\$/        return 4\n        ;;/}"
  mutate "the marker test is inverted (refuses account-less profiles, seals marked ones)" \
         '/^acct_seal() {$/,/^}$/s#^  if \[ -e "$STATE/.had_account" \] \&\& \[ -x /system/bin/nowhere_db_fix \]; then#  if [ ! -e "$STATE/.had_account" ] \&\& [ -x /system/bin/nowhere_db_fix ]; then#'
  mutate "the guard reads the marker with -f again (a directory at .had_account disarms it) (NWP-20261123-19)" \
         '/^acct_seal() {$/,/^}$/s#^  if \[ -e "$STATE/.had_account" \] \&\& \[ -x /system/bin/nowhere_db_fix \]; then#  if [ -f "$STATE/.had_account" ] \&\& [ -x /system/bin/nowhere_db_fix ]; then#'
  mutate "the arrival-record reader reads the marker with -f again (NWP-20261123-19)" \
         '/^acct_seal() {$/,/^}$/s/^    if \[ -e "\$STATE\/.had_account" \]; then$/    if [ -f "$STATE\/.had_account" ]; then/'
  mutate "the refusal leaves the stage behind" \
         '/case: \$_case/{n;d}'
  mutate "the refusal returns 0 (the caller seals as if it passed)" \
         '/case: \$_case/,/return 4/{s/return 4/return 0; return 4/}'
  mutate "honour when ANY arriving hash is marked" \
         '/case "\$_mks" in/s/\*) ;; \*) _case="unmarked" ;; esac ;;$/*) break ;; *) ;; esac ;;/'
  mutate "the guard hands the mark hash to grep (an argv ps can read)" \
         's/\*) case "\$_mks" in \*"\$_nl\$_h\$_nl"\*) ;; \*) _case="unmarked" ;; esac ;;$/*) grep -qxF -- "$_h" "$_mf" 2>\/dev\/null || _case="unmarked" ;;/'
  mutate "the guard hands the mark hash to printf (an argv ps can read on Android)" \
         's/\*) case "\$_mks" in \*"\$_nl\$_h\$_nl"\*) ;; \*) _case="unmarked" ;; esac ;;$/*) printf %s "$_h" | grep -qxF -f - "$_mf" 2>\/dev\/null || _case="unmarked" ;;/'
  mutate "the prune hands the mark hash to grep (an argv ps can read)" \
         's/if case "\$_sh" in \*"\$_nl\$_h\$_nl"\*) true ;; \*) false ;; esac; then$/if print -r -- "$_sh" | grep -qxF -- "$_h"; then/'
  mutate "the prune hands the staged hashes to printf (an argv ps can read on Android)" \
         's/^      _sh="\$_nl\$(print -r -- "\$_stg" | sed 1d)\$_nl"$/      _sh="$_nl$(printf "%s\\n" "$_stg" | sed 1d)$_nl"/'
  mutate "the T == hash-count check is dropped" \
         '/\[ "\$_hn" = "\$_t" \] || _case="unmarked"/d'
  mutate "the marks are cleared on rc != 0" \
         's/^  if \[ "\$r" = 0 \] \&\& \[ -n "\$_stg" \]; then$/  if [ -n "$_stg" ]; then/'
  mutate "the marks file is replaced by mv, not rewritten in place" \
         's#print -r -- "\$_keep" > "\$_mf" 2>>"\$LOG"#print -r -- "$_keep" > "$_mf.new" \&\& mv "$_mf.new" "$_mf"#'
  mutate "the arrival refresh is skipped" \
         's/elif ( umask 077; print -r -- "\$_stg" > "\$_arr" ) 2>>"\$LOG"; then/elif true; then/'
  mutate "an unarmed profile gets .had_account" \
         '/^acct_seal() {$/,/^}$/s/^    if \[ -e "\$STATE\/.had_account" \]; then$/    if : > "$STATE\/.had_account"; then/'
  mutate "the open journal is not consulted" \
         '/^          elif \[ -s "\$_mf.pending" \]; then$/s/-s/-e "\/nonexistent" -a -s/'
  mutate "a ? line is accepted" \
         "s/^                ''|'?') _case=\"unmarked\" ;;/                '') _case=\"unmarked\" ;;/"
  mutate "the short-copy check is deleted (a cut CE db seals) (NWP-20261118-03)" \
         '/^  for _wf in accounts_ce.db accounts_ce.db-wal; do$/,/^  done$/d'
  mutate "the -wal leg is removed (a cut -wal seals) (NWP-20261118-03)" \
         's/^  for _wf in accounts_ce.db accounts_ce.db-wal; do$/  for _wf in accounts_ce.db; do/'
  mutate "the size comparison is inverted (a whole copy refuses) (NWP-20261118-03)" \
         's/\[ "\$_wgot" != "\$_wsrc" \]/[ "$_wgot" = "$_wsrc" ]/'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
