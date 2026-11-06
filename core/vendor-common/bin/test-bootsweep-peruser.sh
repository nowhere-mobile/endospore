#!/usr/bin/env bash
# test-bootsweep-peruser.sh [<nowhere_roamd.sh>] [--mutate] -- the boot sweep's `adservices` and `jobs`
# categories (fix 4, NWP-20261026-10), run for real rather than grepped.
#
# Both categories delete the per-user state of a user that "no live user names". They must:
#   - decide a user is gone from the whole record triple (users/<n>.xml, .backup, .reservecopy), never <n>.xml
#     alone: a ResilientAtomicFile rewrite leaves only .backup for an instant, and a sign-in can race the sweep;
#   - run only once user 0's record is visible, else both read UNREACHABLE and nothing is removed;
#   - check the record again straight before each removal;
#   - read UNREACHABLE for a directory that exists but cannot be listed (never =0), ABSENT only from a listing of
#     /data/system that holds no such name;
#   - report a removal that failed as <n>/LEFT:<m>, never as removed;
#   - append each category to `_swept` exactly once on every path, and name no file anywhere.
#
# userdir_has_record and the block are extracted from nowhere_roamd.sh BY ANCHOR; if the anchors move, extraction
# fails loudly (exit 2). /data/system is substituted by a temp tree and the cases run under every shell present
# among bash, sh, dash and mksh.
#
#   bash test-bootsweep-peruser.sh            # the behaviour cases
#   bash test-bootsweep-peruser.sh --mutate   # ... plus mutations that must each CONVICT the suite, per shell
# SUITE_SHELL=<shell> restricts the cases to one shell (--mutate uses it).
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE=$(dirname "$0")
SUT="${SUT:-$HERE/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

SHELLS=()
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  SHELLS+=("$p")
done
[ -n "${SUITE_SHELL:-}" ] && SHELLS=("$SUITE_SHELL")

# --- extraction -----------------------------------------------------------------------------------------
HDR="  # --- fix 4: orphan per-user state under /data/system that no live user names -------------------------"
FN=$(awk '/^userdir_has_record\(\) \{$/ { on = 1 } on { print } on && /^}$/ { exit }' "$SUT")
case "$FN" in *'userdir_has_record'*'.xml.backup'*) ;;
  *) echo "EXTRACTION FAILED: userdir_has_record" >&2; exit 2 ;; esac
BLOCK=$(awk -v h="$HDR" '
  $0 == h { on = 1; print; next }
  on && index($0, "  # ---") == 1 { exit }
  on { print }' "$SUT")
case "$BLOCK" in *'adservices='*'jobs='*) ;;
  *) echo "EXTRACTION FAILED: the adservices and jobs categories" >&2; exit 2 ;; esac
printf '%s\n' "$BLOCK" > "$W/block.sh"
bash -n "$W/block.sh" 2>/dev/null || { echo "EXTRACTION FAILED: the block does not parse" >&2; exit 2; }
POS=$(awk -v h="$HDR" '
  /^if \[ "\$op" = "bootsweep" \]; then$/ { op = NR }
  $0 == h { blk = NR }
  /echo "\[roamd\] bootsweep result:\$_swept/ { res = NR }
  END { print (op && blk > op && res > blk) ? "in" : "out" }' "$SUT")

# --- harness --------------------------------------------------------------------------------------------
# /data/system -> $R/system; `[ -d ` -> _tdir, ls and rm -> stubs, so a denial or a failed remove can be simulated
# per path (root ignores mode bits). RACE_UID=<n>: the first time the record test says "no record" for n, a
# users/<n>.xml.backup appears -- a sign-in landing between the select and the remove. The stubs are POSIX.
RUNBLK=$(printf '%s\n' "$BLOCK" | sed -e 's@/data/system@$R/system@g' -e 's@\[ -d @_tdir @g')
{
  cat <<'STUBS'
_tdir(){ case " ${DENY_D:-} " in *" $1 "*) return 1 ;; esac; [ -d "$1" ]; }
ls(){ local last; for last; do :; done
  case " ${DENY_LS:-} " in *" $last "*) return 1 ;; esac
  case " ${EMPTY_LS:-} " in *" $last "*) return 0 ;; esac
  command ls "$@"; }
rm(){ if [ "${RMFAIL:-}" = 1 ]; then echo "rm: $2: Permission denied" >&2; return 1; fi
  if [ "${RMFAIL:-}" = gone ]; then command rm "$@"; echo "rm: $2: error after the remove" >&2; return 1; fi
  command rm "$@"; }
LOG="$R/log"; _swept=""
STUBS
  printf '%s\n' "$FN" | sed -e 's@/data/system@$R/system@g' -e 's@^userdir_has_record() {$@_real_udhr() {@'
  cat <<'RACE'
userdir_has_record(){ _real_udhr "$1" && return 0
  if [ "$1" = "${RACE_UID:-}" ] && [ ! -e "$R/race.done" ]; then
    : > "$R/race.done"; : > "$R/system/users/$1.xml.backup"; fi
  return 1; }
RACE
  printf '%s\n' "$RUNBLK"
  printf "printf '%%s' \"\$_swept\"\n"
} > "$W/driver.sh"

# runblk <shell> <root> [VAR=val ...] -> prints the resulting _swept
runblk(){ local sh="$1" r="$2"; shift 2
  env "$@" R="$r" "$sh" "$W/driver.sh" 2>>"$r/stderr"; }
cnt(){ [ "$(printf '%s\n' "$1" | grep -o "$2=" | wc -l)" -eq 1 ]; }
once(){ cnt "$1" adservices && cnt "$1" jobs; }
# mktree <root>: user 0's record, adservices dirs (each holding a file), job files of several users
mktree(){ local t d f; t=$(mktemp -d -p "$W"); mkdir -p "$t/system/users" "$t/system/job"
  : > "$t/system/users/0.xml"
  for d in 0 10 11 12 foo 011; do mkdir -p "$t/system/adservices/$d"; echo keep > "$t/system/adservices/$d/f"; done
  for f in 10188 910188 1010188 1110005 1210005 x; do : > "$t/system/job/jobs_$f.xml"; done
  echo "$t"; }
snap(){ ( cd "$1" && find system -print 2>/dev/null | sort && find system -type f -exec cksum {} + 2>/dev/null | sort ); }
leaks(){ local t="$1" s="$2"   # any file name in _swept, the log or stderr?
  printf '%s\n' "$s" | grep -Eq 'jobs_|\.xml|adservices/|Permission denied|/system' && return 0
  cat "$t/log" "$t/stderr" 2>/dev/null | grep -Eq 'jobs_|\.xml|adservices/|Permission denied' && return 0
  return 1; }

echo "== position =="
[ "$POS" = in ] && ok "the block sits inside the bootsweep op, before its result line" \
  || no "the block is not between the bootsweep op and its result line"

for sh in "${SHELLS[@]}"; do
tag="[$(basename "$sh")]"

echo "== $tag a live user mid-rewrite keeps its state =="
T=$(mktree); : > "$T/system/users/10.xml.backup"; : > "$T/system/users/11.xml"; : > "$T/system/users/12.xml"
S=$(runblk "$sh" "$T")
[ -d "$T/system/adservices/10" ] && [ -f "$T/system/adservices/10/f" ] && ok "$tag user 10 (only .xml.backup) keeps adservices/10" || no "$tag adservices/10 was removed"
[ -f "$T/system/job/jobs_1010188.xml" ] && ok "$tag user 10 (only .xml.backup) keeps jobs_1010188.xml" || no "$tag jobs_1010188.xml was removed"
[ "$S" = " adservices=0 jobs=0" ] && ok "$tag nothing counted as removed ('$S')" || no "$tag reported '$S'"
once "$S" && ok "$tag adservices= and jobs= each appear exactly once" || no "$tag _swept has '$S'"
T=$(mktree); : > "$T/system/users/10.xml.reservecopy"; : > "$T/system/users/11.xml"; : > "$T/system/users/12.xml"
S=$(runblk "$sh" "$T")
[ -d "$T/system/adservices/10" ] && [ -f "$T/system/job/jobs_1010188.xml" ] && ok "$tag user 10 (only .xml.reservecopy) keeps both" || no "$tag a reservecopy-only user lost state"
once "$S" && ok "$tag adservices= and jobs= each appear exactly once" || no "$tag _swept has '$S'"

echo "== $tag a user with no record triple loses its state; the rest is never touched =="
T=$(mktree); : > "$T/system/users/10.xml"; : > "$T/system/users/12.xml"
S=$(runblk "$sh" "$T")
[ ! -e "$T/system/adservices/11" ] && ok "$tag user 11 loses adservices/11" || no "$tag adservices/11 survived"
[ ! -e "$T/system/job/jobs_1110005.xml" ] && ok "$tag user 11 loses jobs_1110005.xml" || no "$tag jobs_1110005.xml survived"
[ "$S" = " adservices=1 jobs=1" ] && ok "$tag reports adservices=1 jobs=1" || no "$tag reported '$S'"
[ -d "$T/system/adservices/10" ] && [ -d "$T/system/adservices/12" ] && [ -f "$T/system/job/jobs_1010188.xml" ] && ok "$tag live users 10 and 12 keep theirs" || no "$tag a live user lost state"
[ -d "$T/system/adservices/0" ] && [ -f "$T/system/job/jobs_10188.xml" ] && [ -f "$T/system/job/jobs_910188.xml" ] && ok "$tag user 0 and user 9 state are never touched" || no "$tag user 0 or 9 state was removed"
[ -d "$T/system/adservices/foo" ] && [ -d "$T/system/adservices/011" ] && [ -f "$T/system/job/jobs_x.xml" ] && ok "$tag non-numeric and leading-zero names are never touched" || no "$tag an odd name was removed"
once "$S" && ok "$tag adservices= and jobs= each appear exactly once" || no "$tag _swept has '$S'"

echo "== $tag the positive control: user 0's record must be visible =="
T=$(mktree); rm "$T/system/users/0.xml"; : > "$T/system/users/0.xml.backup"
S=$(runblk "$sh" "$T")
[ ! -e "$T/system/adservices/11" ] && [ ! -e "$T/system/job/jobs_1110005.xml" ] && ok "$tag user 0 mid-rewrite (.backup only) still lets the sweep run" || no "$tag the sweep did not run with user 0's .backup visible"
T=$(mktree); rm "$T/system/users/0.xml"; B=$(snap "$T"); S=$(runblk "$sh" "$T"); A=$(snap "$T")
[ "$S" = " adservices=UNREACHABLE jobs=UNREACHABLE" ] && ok "$tag no record for user 0: both UNREACHABLE" || no "$tag reported '$S'"
[ "$A" = "$B" ] && ok "$tag and nothing was removed" || no "$tag the tree changed with user 0's record unseen"
once "$S" && ok "$tag adservices= and jobs= each appear exactly once" || no "$tag _swept has '$S'"

echo "== $tag a directory that cannot be listed is UNREACHABLE, never 0 =="
T=$(mktree); B=$(snap "$T"); S=$(runblk "$sh" "$T" DENY_LS="$T/system/job"); A=$(snap "$T")
case "$S" in *" jobs=UNREACHABLE") ok "$tag an unlistable job dir reads jobs=UNREACHABLE" ;; *) no "$tag reported '$S'" ;; esac
[ -f "$T/system/job/jobs_1110005.xml" ] && ok "$tag and no job file was removed" || no "$tag a job file was removed blind"
case "$S" in " adservices=3 "*) ok "$tag adservices is unaffected" ;; *) no "$tag adservices reported '$S'" ;; esac
once "$S" && ok "$tag adservices= and jobs= each appear exactly once" || no "$tag _swept has '$S'"
T=$(mktree); S=$(runblk "$sh" "$T" DENY_LS="$T/system/adservices")
case "$S" in " adservices=UNREACHABLE "*) ok "$tag an unlistable adservices dir reads adservices=UNREACHABLE" ;; *) no "$tag reported '$S'" ;; esac
[ -d "$T/system/adservices/11" ] && ok "$tag and nothing was removed" || no "$tag adservices/11 was removed blind"
T=$(mktree); S=$(runblk "$sh" "$T" DENY_D="$T/system/job $T/system/adservices")
[ "$S" = " adservices=UNREACHABLE jobs=UNREACHABLE" ] && ok "$tag a denied [ -d ] on existing dirs is UNREACHABLE, not ABSENT" || no "$tag reported '$S'"
once "$S" && ok "$tag adservices= and jobs= each appear exactly once" || no "$tag _swept has '$S'"

echo "== $tag absent only from a listing of /data/system =="
T=$(mktree); rm -rf "$T/system/adservices" "$T/system/job"; mkdir "$T/system/adservices.bak" "$T/system/jobx"
S=$(runblk "$sh" "$T")
[ "$S" = " adservices=ABSENT jobs=ABSENT" ] && ok "$tag listable /data/system without them: ABSENT (siblings do not count)" || no "$tag reported '$S'"
once "$S" && ok "$tag adservices= and jobs= each appear exactly once" || no "$tag _swept has '$S'"
T=$(mktree); rm -rf "$T/system/adservices" "$T/system/job"; S=$(runblk "$sh" "$T" EMPTY_LS="$T/system")
[ "$S" = " adservices=ABSENT jobs=ABSENT" ] && ok "$tag /data/system lists successfully and empty: ABSENT, not UNREACHABLE" || no "$tag reported '$S'"
T=$(mktree); rm -rf "$T/system/adservices" "$T/system/job"; S=$(runblk "$sh" "$T" DENY_LS="$T/system")
[ "$S" = " adservices=UNREACHABLE jobs=UNREACHABLE" ] && ok "$tag /data/system unlistable: UNREACHABLE, not ABSENT" || no "$tag reported '$S'"
T=$(mktree); S=$(runblk "$sh" "$T" DENY_D="$T/system/job")
case "$S" in *" jobs=UNREACHABLE") ok "$tag a denied [ -d ] on an existing job dir (the listing names it): UNREACHABLE" ;; *) no "$tag reported '$S'" ;; esac

echo "== $tag a removal that fails is LEFT =="
T=$(mktree); : > "$T/system/users/10.xml"; S=$(runblk "$sh" "$T" RMFAIL=1)
[ "$S" = " adservices=0/LEFT:2 jobs=0/LEFT:2" ] && ok "$tag failing rm: adservices=0/LEFT:2 jobs=0/LEFT:2" || no "$tag reported '$S'"
[ -f "$T/system/adservices/11/f" ] && [ -f "$T/system/job/jobs_1110005.xml" ] && ok "$tag the state is intact" || no "$tag the state changed"
once "$S" && ok "$tag adservices= and jobs= each appear exactly once" || no "$tag _swept has '$S'"
leaks "$T" "$S" && no "$tag a file name reached _swept, the log or stderr" || ok "$tag no file name in _swept, the log or stderr"

T=$(mktree); : > "$T/system/users/10.xml"; S=$(runblk "$sh" "$T" RMFAIL=gone)
[ "$S" = " adservices=0/LEFT:2 jobs=0/LEFT:2" ] && ok "$tag rm removes the target but returns nonzero: LEFT, not removed" || no "$tag reported '$S'"
once "$S" && ok "$tag adservices= and jobs= each appear exactly once" || no "$tag _swept has '$S'"
leaks "$T" "$S" && no "$tag a file name reached _swept, the log or stderr" || ok "$tag no file name in _swept, the log or stderr"

echo "== $tag a sign-in landing between the select and the remove =="
T=$(mktree); : > "$T/system/users/10.xml"; : > "$T/system/users/11.xml"; S=$(runblk "$sh" "$T" RACE_UID=12)
[ -d "$T/system/adservices/12" ] && [ -f "$T/system/job/jobs_1210005.xml" ] && ok "$tag user 12 (record appeared before the rm) keeps its state" || no "$tag a user whose record appeared was removed"
[ "$S" = " adservices=0 jobs=0" ] && ok "$tag and is not counted ('$S')" || no "$tag reported '$S'"

T=$(mktree); : > "$T/system/users/10.xml"; : > "$T/system/users/11.xml"; rm -rf "$T/system/adservices/12"; S=$(runblk "$sh" "$T" RACE_UID=12)
[ -f "$T/system/job/jobs_1210005.xml" ] && [ "$S" = " adservices=0 jobs=0" ] && ok "$tag the same race on a job file: kept, not counted" || no "$tag a racing sign-in lost its job file ('$S')"

echo "== $tag nothing names a file =="
T=$(mktree); : > "$T/system/users/10.xml"; S=$(runblk "$sh" "$T")
leaks "$T" "$S" && no "$tag a file name reached _swept, the log or stderr" || ok "$tag no file name in _swept, the log or stderr"
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite under each shell) =="
  # mutate <label> <sed>: the sed runs on a copy of the block's half; it must change the file (else INERT)
  mutate(){ local m s out rc; m=$(mktemp -d -p "$W")
    if ! sed "$2" "$SUT" > "$m/m" 2>"$m/err"; then no "MUTATION BROKEN (sed): $1: $(cat "$m/err")"; rm -rf "$m"; return; fi
    if cmp -s "$SUT" "$m/m"; then no "MUTATION INERT: $1"; rm -rf "$m"; return; fi
    for s in "${SHELLS[@]}"; do
      out=$(SUITE_SHELL="$s" bash "$0" "$m/m" 2>&1); rc=$?
      if [ "$rc" -eq 2 ]; then no "MUTATION DID NOT APPLY ($(basename "$s")): $1"
      elif [ "$rc" -eq 1 ] && case "$out" in *"  FAIL  "*|"  FAIL  "*) true ;; *) false ;; esac; then ok "convicted ($(basename "$s")): $1"
      else no "NOT CONVICTED ($(basename "$s")): $1 -- suite passes on broken code"; fi
    done
    rm -rf "$m"
  }
  AD='/^  # adservices: /,/_swept="\$_swept adservices=/'
  JB='/^  # JobScheduler files/,/_swept="\$_swept jobs=/'
  mutate "M1: adservices decides from <n>.xml alone" "$AD"'s@userdir_has_record "\$_u"@[ -f "/data/system/users/$_u.xml" ]@'
  mutate "M2: jobs decides from <n>.xml alone" "$JB"'s@userdir_has_record "\$_u"@[ -f "/data/system/users/$_u.xml" ]@'
  mutate "M3: the positive control is removed" 's@^  _u0=""; userdir_has_record 0 && _u0=1$@  _u0=1@'
  mutate "M4: adservices' re-check before the rm is removed" "$AD"'{/^      for _u in \$_c; do$/{n;d;}}'
  mutate "M5: jobs' re-check before the rm is removed" "$JB"'{/^      for _b in \$_c; do$/{n;n;d;}}'
  mutate "M6: adservices' unlistable dir reads 0" "$AD"'s@^    else _r=UNREACHABLE; fi$@    else _r=0; fi@'
  mutate "M7: jobs' unlistable dir reads 0" "$JB"'s@^    else _r=UNREACHABLE; fi$@    else _r=0; fi@'
  mutate "M8: adservices counts a failed rm as removed" "$AD"'s@then _nl=\$((_nl + 1))$@then _n=$((_n + 1))@'
  mutate "M9: jobs counts a failed rm as removed" "$JB"'s@then _nl=\$((_nl + 1))$@then _n=$((_n + 1))@'
  mutate "M15: adservices ignores rm's exit status" "$AD"'s@\[ "\$_rc" -ne 0 \] || @@'
  mutate "M16: jobs ignores rm's exit status" "$JB"'s@\[ "\$_rc" -ne 0 \] || @@'
  mutate "M10: a failing [ -d ] reads ABSENT without listing /data/system" "$AD"'s@^  elif _sl=.*$@  elif true; then _r=ABSENT@'
  mutate "M11: rm's stderr goes to the log" "$AD"'s@rm -rf "/data/system/adservices/\$_u" 2> /dev/null@rm -rf "/data/system/adservices/$_u" 2>> "$LOG"@'
  mutate "M12: jobs reports twice" 's@^  _swept="\$_swept jobs=\$_r"$@  _swept="$_swept jobs=$_r jobs=$_r"@'
  mutate "M13: the block is no longer inside the bootsweep op" 's@^if \[ "\$op" = "bootsweep" \]; then$@if [ "$op" = "bootsweepX" ]; then@'
  mutate "M14: an empty listing of /data/system reads UNREACHABLE (adservices)" "$AD"'s@^  elif _sl=\$(ls -A /data/system 2> /dev/null); then$@  elif _sl=$(ls -A /data/system 2> /dev/null) \&\& [ -n "$_sl" ]; then@'
fi

echo
echo "shells: ${SHELLS[*]}"
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
