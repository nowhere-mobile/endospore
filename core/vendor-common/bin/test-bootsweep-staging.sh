#!/usr/bin/env bash
# test-bootsweep-staging.sh [<nowhere_roamd.sh>] [--mutate] [--baseline] -- the boot sweep's `staging` category
# (NWP-20261107-01), run for real rather than grepped.
#
# A crash or a dead battery leaves a departed session's per-session staging under the daemon's dir: acct-stage (a copy
# of accounts_ce.db), acct-hold-<uid> / acct-deferred-<uid>, appcode-stage and its six lists (every kept app's APK and
# the app list), appcode-reuse (the previous periodic seal's stage, NWP-20261128-09), fetchapp (a fetched app), keystore-stage and keystore-in (Keystore bundles; keystore-in outlives every
# sign-out). Nothing swept them at boot. The category must:
#   - remove every listed entry when no session marker exists, no `out` awaits its reap and no user >= 10 has a
#     record, and report how many it held;
#   - touch NOTHING while a .roamsession marker exists (KEPT:session), while $KS_CREDS exists (KEPT:reap: an `out` ran
#     and its reap has not), while a users/<n> record of n >= 10 stands, any one file of the triple (KEPT:user), when
#     users/ yields no record of user 0 (UNREACHABLE: the positive control) or when the dir cannot be listed
#     (UNREACHABLE);
#   - check the marker FIRST: a live session has its user's record and may find the logoff creds of the sign-out
#     before it, and must still read KEPT:session (the backlog row's CLOSES WHEN), never KEPT:reap or KEPT:user;
#   - never follow or remove a symbolic link (/LINK:<l>), and report /LEFT:<k> for what survives the remove;
#   - touch nothing outside the fixed list (keystore-map, keystore-drop, the conf files, reap-ledger, otacache, spill);
#   - also remove the *.keys files of $KS_IMPORT (nowhere-import) and $KS_EXPORT (nowhere-export) behind the same
#     guards (NWP-20261114-23): files only, both dirs stay, any other name stays, and a link is never followed;
#   - append to `_swept` exactly once on every path, and never print an entry name, package or uid.
# The marker check is sound only while BOOT-SWEEP is not in main.go's concurrentSafeCmd (it then holds sessionMu, as
# ROAM-IN does); a source pin checks that.
#
# The helper (staging_boot), userdir_has_record and the category block (its header line up to the next `  # ---`
# header or the `  # Report what was actually removed` line) are extracted from nowhere_roamd.sh BY ANCHOR, and its
# KS_CREDS="$STATE/ks-logoff-creds" line is pinned; if an anchor moves, extraction fails loudly (exit 2). --baseline
# stands a no-op in for a missing helper or block, so the cases fail by BEHAVIOUR against a script that lacks the
# category. The paths are substituted by a temp tree and the cases run under every shell present among bash, sh,
# dash and mksh; each mutant must be convicted under each shell.
#
#   bash test-bootsweep-staging.sh            # the behaviour cases
#   bash test-bootsweep-staging.sh --mutate   # ... plus mutations that must each CONVICT the suite
# MAINGO=<main.go> overrides the daemon source the concurrentSafeCmd pin reads; ONLY_SHELL=<path> (internal) restricts
# the shell loop to one shell.
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

MUTATE=no; BASELINE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; --baseline) BASELINE=yes ;; *) SUT="$a" ;; esac; done
HERE=$(dirname "$0")
SUT="${SUT:-$HERE/nowhere_roamd.sh}"
MAINGO="${MAINGO:-$HERE/../../agent/main.go}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
[ -f "$MAINGO" ] || { echo "no such file: $MAINGO" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

SHELLS=()
seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$p")
done
if [ -n "${ONLY_SHELL:-}" ]; then SHELLS=("$ONLY_SHELL"); fi

# --- extraction -----------------------------------------------------------------------------------------
HDR="  # --- fix 17: staging (NWP-20261107-01) ---"
FN=$(awk '/^staging_boot\(\) \{$/ { on = 1 } on { print } on && /^}$/ { exit }' "$SUT")
BLOCK=$(awk -v h="$HDR" '
  $0 == h { on = 1; print; next }
  on && (index($0, "  # ---") == 1 || index($0, "  # Report what was actually removed") == 1) { exit }
  on { print }' "$SUT")
fn_ok=no; blk_ok=no
case "$FN" in *'STAGING_BOOT=KEPT:session'*'STAGING_BOOT=UNREACHABLE'*) fn_ok=yes ;; esac
case "$BLOCK" in *'staging_boot'*'staging=$STAGING_BOOT'*) blk_ok=yes ;; esac
if [ "$BASELINE" = yes ]; then
  [ "$fn_ok" = yes ] || FN='staging_boot() { :; }'
  [ "$blk_ok" = yes ] || BLOCK=""
else
  [ "$fn_ok" = yes ] || { echo "EXTRACTION FAILED: staging_boot" >&2; exit 2; }
  [ "$blk_ok" = yes ] || { echo "EXTRACTION FAILED: the staging category" >&2; exit 2; }
fi
printf '%s\n' "$FN" > "$W/fn.sh"; printf '%s\n' "$BLOCK" > "$W/block.sh"
bash -n "$W/fn.sh" 2>/dev/null || { echo "EXTRACTION FAILED: staging_boot does not parse" >&2; exit 2; }
bash -n "$W/block.sh" 2>/dev/null || { echo "EXTRACTION FAILED: the staging block does not parse" >&2; exit 2; }
UDHR=$(awk '/^userdir_has_record\(\) \{$/ { on = 1 } on { print } on && /^}$/ { exit }' "$SUT")
case "$UDHR" in *'userdir_has_record'*'.xml.backup'*'.xml.reservecopy'*) ;;
  *) echo "EXTRACTION FAILED: userdir_has_record" >&2; exit 2 ;; esac
# The harness sets KS_CREDS to its own path; that is only the path roamd uses while this line stands.
grep -qxF 'KS_CREDS="$STATE/ks-logoff-creds"' "$SUT" || { echo "EXTRACTION FAILED: KS_CREDS=\"\$STATE/ks-logoff-creds\"" >&2; exit 2; }
POS=$(awk -v h="$HDR" '
  /^if \[ "\$op" = "bootsweep" \]; then$/ { op = NR }
  index($0, "  # --- fix 16: keystore-drop") == 1 { f16 = NR }
  $0 == h { blk = NR }
  /echo "\[roamd\] bootsweep result:\$_swept/ { res = NR }
  END { print (op && f16 > op && blk > f16 && res > blk) ? "in" : "out" }' "$SUT")

# --- harness --------------------------------------------------------------------------------------------
# /data/nowhere -> $R/nw, $STATE -> $R/state, /data/system/users -> $R/users, $KS_CREDS -> $R/state/ks-logoff-creds,
# $KS_IMPORT -> $R/ks/nowhere-import, $KS_EXPORT -> $R/ks/nowhere-export.
# ls and rm are stubs, so a denied listing or a failed remove can be simulated (root ignores mode bits, so chmod proves
# nothing on a CI runner). The stubs are POSIX: dash and mksh run them.
{
  cat <<'STUBS'
ls(){ for last; do :; done
  case " ${DENY_LS:-} " in *" $last "*) return 1 ;; esac
  command ls "$@"; }
rm(){ [ "${RMFAIL:-}" = 1 ] && return 1; command rm "$@"; }
LOG="$R/log"; _swept=""; KS_CREDS="$R/state/ks-logoff-creds"
KS_IMPORT="$R/ks/nowhere-import"; KS_EXPORT="$R/ks/nowhere-export"
STUBS
  { printf '%s\n' "$UDHR"; printf '%s\n' "$FN"; printf '%s\n' "$BLOCK"; } |
    sed -e 's@/data/nowhere@$R/nw@g' -e 's@/data/system/users@$R/users@g' -e 's@\$STATE@$R/state@g'
  printf "printf '%%s' \"\$_swept\"\n"
} > "$W/driver.sh"

# runblk <shell> <root> [VAR=val ...] -> prints the resulting _swept
runblk(){ local sh="$1" r="$2"; shift 2
  env "$@" R="$r" "$sh" "$W/driver.sh" 2>>"$r/stderr"; }
once(){ [ "$(printf '%s\n' "$1" | grep -o 'staging=' | wc -l)" -eq 1 ]; }
# mktree: user 0's record and directory, the list files, and users/13 -- a directory with no record, which keeps nothing.
mktree(){ local t; t=$(mktemp -d -p "$W"); mkdir -p "$t/nw" "$t/state" "$t/outside" "$t/users/0" "$t/users/13"
  : > "$t/users/0.xml"; : > "$t/users/userlist.xml"; : > "$t/users/user.list"; echo s > "$t/users/13/settings_secure.xml"
  echo secret > "$t/outside/sentinel"; : > "$t/stderr"; echo "$t"; }
LISTED="acct-stage acct-hold-12 acct-deferred-12 appcode-stage appcode-reuse appcode-defer appcode-dropfilter appcode-dropoff appcode-playstack appcode-playfilter appcode-dropgone appcode-dormant fetchapp keystore-stage keystore-in"
mkall(){   # mkall <root>: every listed entry (15), then the entries that must never be touched
  local n="$1/nw" f
  mkdir -p "$n/acct-stage/ce" "$n/appcode-stage/com.example.bank" "$n/appcode-reuse/com.example.bank" "$n/keystore-stage" "$n/keystore-in" "$n/acct-hold-12/ce" \
    "$n/fetchapp/com.example.x" "$n/otacache" "$n/spill" "$n/appcode-dormant/com.example.bank/_meta"
  echo db > "$n/acct-stage/ce/accounts_ce.db"; echo db > "$n/acct-hold-12/ce/accounts_ce.db"
  echo apk > "$n/appcode-stage/com.example.bank/base.apk"; echo m > "$n/appcode-stage/manifest.tsv"
  echo apk > "$n/appcode-reuse/com.example.bank/base.apk"; echo 12 > "$n/appcode-reuse/.uid"
  echo m > "$n/appcode-dormant/com.example.bank/_meta/meta"; echo m > "$n/appcode-dormant/manifest.tsv"
  echo k > "$n/keystore-stage/com.example.bank.keys"; echo k > "$n/keystore-in/com.example.chat.keys"
  : > "$n/acct-deferred-12"; echo part > "$n/fetchapp/com.example.x/base.apk.part"
  for f in appcode-defer appcode-dropfilter appcode-dropoff appcode-playstack appcode-playfilter appcode-dropgone; do
    echo com.example.bank > "$n/$f"; done
  echo conf > "$n/nowhere.conf"; echo b > "$n/bindings.conf"; echo "10123 com.example.bank" > "$n/keystore-map"
  echo drop > "$n/keystore-drop"; echo l > "$n/reap-ledger"; echo x > "$n/otacache/x"; echo x > "$n/spill/x"
}
# mkks <root>: one staged import bundle and one unsealed dump in the two keystore staging dirs
mkks(){ mkdir -p "$1/ks/nowhere-import" "$1/ks/nowhere-export"
  echo imp > "$1/ks/nowhere-import/1010001.keys"; echo exp > "$1/ks/nowhere-export/1010002.keys"; }
snap(){ ( cd "$1" && find nw state users ks -print 2>/dev/null | sort && find nw state users ks -type f -exec cksum {} + 2>/dev/null | sort ); }
keepers(){ ( cd "$1/nw" && find nowhere.conf bindings.conf keystore-map keystore-drop reap-ledger otacache spill -type f -exec cksum {} + | sort ); }
anylisted(){ local e; for e in $LISTED; do [ -e "$1/nw/$e" ] || [ -L "$1/nw/$e" ] && return 0; done; return 1; }
leak(){   # leak <root> <token>: an entry name, package or uid in the token, the log or stderr
  local pat='com\.example|acct-|appcode-|fetchapp|keystore-|hold-12|deferred-12|base\.apk|nowhere-import|nowhere-export|\.keys|101000[0-9]'
  if grep -Eq "$pat" "$1/log" "$1/stderr" 2>/dev/null; then return 0; fi
  case "$2" in *com.example*|*acct-*|*appcode-*|*fetchapp*|*keystore-*|*hold-12*|*deferred-12*|*apk*|*nowhere-import*|*nowhere-export*|*.keys*|*101000*) return 0 ;; esac
  return 1
}
noleak(){ if leak "$1" "$2"; then no "$3 an entry name, package or uid was printed"; else ok "$3 no entry name in the result, the log or stderr"; fi; }
# kept <label> <want> <plant command>: every entry planted, then the plant, run under $sh; the whole tree (nw, state,
# users, ks) must be byte for byte as it was.
kept(){ local label="$1" want="$2" plant="$3"
  T=$(mktree); mkall "$T"; eval "$plant"; B=$(snap "$T"); S=$(runblk "$sh" "$T"); A=$(snap "$T")
  [ "$S" = " staging=$want" ] && ok "$tag $label reports staging=$want" || no "$tag $label reported '$S', want ' staging=$want'"
  [ "$A" = "$B" ] && ok "$tag $label: the whole tree is unchanged" || no "$tag $label: the tree changed"
  once "$S" && ok "$tag $label: appears exactly once in _swept" || no "$tag $label: _swept has '$S'"
  noleak "$T" "$S" "$tag $label:"; }

echo "== position =="
[ "$POS" = in ] && ok "the category sits inside the bootsweep op, after fix 16 and before its result line" \
  || no "the category is not between fix 16 and the bootsweep result line"

echo "== source pins =="
MFN=$(awk '/^func concurrentSafeCmd/ { on = 1 } on { print } on && /^}/ { exit }' "$MAINGO")
case "$MFN" in *'func concurrentSafeCmd'*) ;; *) echo "EXTRACTION FAILED: concurrentSafeCmd in $MAINGO" >&2; exit 2 ;; esac
case "$MFN" in *'"BOOT-SWEEP"'*) no "BOOT-SWEEP is in concurrentSafeCmd: it would not hold sessionMu, so the marker check is unsound" ;;
  *) ok "concurrentSafeCmd does not list BOOT-SWEEP (the marker check holds under sessionMu)" ;; esac

for sh in "${SHELLS[@]}"; do
tag="[${sh##*/}]"
echo "== $tag no marker: every listed entry goes, nothing else =="
T=$(mktree); mkall "$T"; KB=$(keepers "$T"); S=$(runblk "$sh" "$T"); KA=$(keepers "$T")
[ "$S" = " staging=15" ] && ok "$tag reports staging=15" || no "$tag reported '$S', want ' staging=15'"
if anylisted "$T"; then no "$tag a listed entry survived"; else ok "$tag every listed entry is gone"; fi
[ "$KA" = "$KB" ] && [ -n "$KB" ] && ok "$tag nowhere.conf, bindings.conf, keystore-map, keystore-drop, reap-ledger, otacache, spill are byte for byte as they were" \
  || no "$tag an entry outside the list changed"
once "$S" && ok "$tag appears exactly once in _swept" || no "$tag _swept has '$S'"
noleak "$T" "$S" "$tag"

echo "== $tag nothing present =="
T=$(mktree); S=$(runblk "$sh" "$T")
[ "$S" = " staging=none" ] && ok "$tag reports staging=none" || no "$tag reported '$S'"
once "$S" && ok "$tag appears exactly once in _swept" || no "$tag _swept has '$S'"
noleak "$T" "$S" "$tag"

echo "== $tag a live session's staging is untouched =="
T=$(mktree); mkall "$T"; echo 1234 > "$T/state/.roamsession"; B=$(snap "$T"); S=$(runblk "$sh" "$T"); A=$(snap "$T")
[ "$S" = " staging=KEPT:session" ] && ok "$tag reports staging=KEPT:session" || no "$tag reported '$S'"
[ "$A" = "$B" ] && ok "$tag every entry is byte for byte as it was" || no "$tag the tree changed under a live session"
once "$S" && ok "$tag appears exactly once in _swept" || no "$tag _swept has '$S'"
noleak "$T" "$S" "$tag"

echo "== $tag a symbolic link is never followed =="
T=$(mktree); ln -s "$T/outside" "$T/nw/fetchapp"; S=$(runblk "$sh" "$T")
[ "$S" = " staging=0/LINK:1" ] && ok "$tag reports staging=0/LINK:1" || no "$tag reported '$S'"
[ -f "$T/outside/sentinel" ] && ok "$tag the link target's content survives" || no "$tag the target was emptied through the link"
[ -L "$T/nw/fetchapp" ] && ok "$tag the link itself is left" || no "$tag the link was removed"
[ "$(wc -l < "$T/log" 2>/dev/null)" = 1 ] && ok "$tag exactly one log line" || no "$tag the log has not exactly one line"
once "$S" && ok "$tag appears exactly once in _swept" || no "$tag _swept has '$S'"
noleak "$T" "$S" "$tag"

echo "== $tag what stays is reported as LEFT =="
T=$(mktree); mkall "$T"; S=$(runblk "$sh" "$T" RMFAIL=1)
[ "$S" = " staging=0/LEFT:15" ] && ok "$tag a failing rm reports staging=0/LEFT:15" || no "$tag reported '$S'"
if anylisted "$T"; then ok "$tag the entries are still there"; else no "$tag the entries went anyway"; fi
once "$S" && ok "$tag appears exactly once in _swept" || no "$tag _swept has '$S'"
noleak "$T" "$S" "$tag"

echo "== $tag an unlistable dir is UNREACHABLE, never none =="
T=$(mktree); mkall "$T"; B=$(snap "$T"); S=$(runblk "$sh" "$T" DENY_LS="$T/nw"); A=$(snap "$T")
[ "$S" = " staging=UNREACHABLE" ] && ok "$tag reports staging=UNREACHABLE" || no "$tag reported '$S'"
[ "$A" = "$B" ] && ok "$tag nothing was removed blind" || no "$tag the tree changed"
once "$S" && ok "$tag appears exactly once in _swept" || no "$tag _swept has '$S'"
noleak "$T" "$S" "$tag"

echo "== $tag a sign-out between its out and its reap, a user with a record, no user 0 record =="
kept "logoff creds present" KEPT:reap 'echo creds > "$T/state/ks-logoff-creds"'
kept "users/12.xml" KEPT:user ': > "$T/users/12.xml"'
kept "users/12.xml.backup alone" KEPT:user ': > "$T/users/12.xml.backup"'
kept "users/12.xml.reservecopy alone" KEPT:user ': > "$T/users/12.xml.reservecopy"'
kept "no users/0.xml" UNREACHABLE 'rm -f "$T/users/0.xml"'

echo "== $tag a live session as a device has it: the marker check comes first =="
kept "a live session with its user's record" KEPT:session 'echo 1234 > "$T/state/.roamsession"; : > "$T/users/12.xml"'
kept "a live session with its user's record and the logoff creds" KEPT:session \
  'echo 1234 > "$T/state/.roamsession"; : > "$T/users/12.xml"; echo creds > "$T/state/ks-logoff-creds"'

echo "== $tag B1 no marker: the *.keys files of both keystore staging dirs go, the dirs stay =="
T=$(mktree); mkall "$T"; mkks "$T"; KB=$(keepers "$T"); S=$(runblk "$sh" "$T"); KA=$(keepers "$T")
[ "$S" = " staging=17" ] && ok "$tag B1 reports staging=17 (15 listed + 2 .keys)" || no "$tag B1 reported '$S', want ' staging=17'"
if [ -e "$T/ks/nowhere-import/1010001.keys" ] || [ -L "$T/ks/nowhere-import/1010001.keys" ]; then
  no "$tag B1 nowhere-import/1010001.keys survived"; else ok "$tag B1 nowhere-import/1010001.keys is gone"; fi
if [ -e "$T/ks/nowhere-export/1010002.keys" ] || [ -L "$T/ks/nowhere-export/1010002.keys" ]; then
  no "$tag B1 nowhere-export/1010002.keys survived"; else ok "$tag B1 nowhere-export/1010002.keys is gone"; fi
[ -d "$T/ks/nowhere-import" ] && [ -d "$T/ks/nowhere-export" ] && ok "$tag B1 both dirs still exist" || no "$tag B1 a keystore staging dir was removed"
[ "$KA" = "$KB" ] && [ -n "$KB" ] && ok "$tag B1 the entries outside the list are byte for byte as they were" || no "$tag B1 an entry outside the list changed"
once "$S" && ok "$tag B1 appears exactly once in _swept" || no "$tag B1 _swept has '$S'"
noleak "$T" "$S" "$tag B1"

echo "== $tag B2-B5 every guard holds the *.keys files =="
kskept(){ local label="$1"
  [ "$(cat "$T/ks/nowhere-import/1010001.keys" 2>/dev/null)" = imp ] && [ "$(cat "$T/ks/nowhere-export/1010002.keys" 2>/dev/null)" = exp ] \
    && ok "$tag $label: both .keys files are intact" || no "$tag $label: a .keys file changed or went"; }
kept "B2 a .roamsession marker" KEPT:session 'mkks "$T"; echo 1234 > "$T/state/.roamsession"'; kskept "B2"
kept "B3 logoff creds present" KEPT:reap 'mkks "$T"; echo creds > "$T/state/ks-logoff-creds"'; kskept "B3"
kept "B4 users/10.xml" KEPT:user 'mkks "$T"; : > "$T/users/10.xml"'; kskept "B4 users/10.xml"
kept "B4 users/10.xml.backup alone" KEPT:user 'mkks "$T"; : > "$T/users/10.xml.backup"'; kskept "B4 users/10.xml.backup"
kept "B4 users/10.xml.reservecopy alone" KEPT:user 'mkks "$T"; : > "$T/users/10.xml.reservecopy"'; kskept "B4 users/10.xml.reservecopy"
kept "B5 no users/0.xml" UNREACHABLE 'mkks "$T"; rm -f "$T/users/0.xml"'; kskept "B5"

echo "== $tag B6 a symbolic link named *.keys is never followed =="
T=$(mktree); mkdir -p "$T/ks/nowhere-import"; ln -s "$T/outside/sentinel" "$T/ks/nowhere-import/1010003.keys"; S=$(runblk "$sh" "$T")
[ "$S" = " staging=0/LINK:1" ] && ok "$tag B6 reports staging=0/LINK:1" || no "$tag B6 reported '$S', want ' staging=0/LINK:1'"
[ "$(cat "$T/outside/sentinel" 2>/dev/null)" = secret ] && ok "$tag B6 the link target survives" || no "$tag B6 the link target was removed or changed"
[ -L "$T/ks/nowhere-import/1010003.keys" ] && ok "$tag B6 the link itself is left" || no "$tag B6 the link was removed"
[ "$(wc -l 2>/dev/null < "$T/log")" = 1 ] && ok "$tag B6 exactly one log line" || no "$tag B6 the log has not exactly one line"
once "$S" && ok "$tag B6 appears exactly once in _swept" || no "$tag B6 _swept has '$S'"
noleak "$T" "$S" "$tag B6"

echo "== $tag B7 a name other than *.keys in either dir is untouched =="
T=$(mktree); mkks "$T"; echo t > "$T/ks/nowhere-import/1010004.keys.tmp"; echo t > "$T/ks/nowhere-export/census.tmp"
CB=$(cd "$T/ks" && cksum nowhere-import/1010004.keys.tmp nowhere-export/census.tmp); S=$(runblk "$sh" "$T")
CA=$(cd "$T/ks" && cksum nowhere-import/1010004.keys.tmp nowhere-export/census.tmp 2>/dev/null)
[ "$S" = " staging=2" ] && ok "$tag B7 reports staging=2" || no "$tag B7 reported '$S', want ' staging=2'"
[ "$CA" = "$CB" ] && ok "$tag B7 both other files are byte for byte as they were" || no "$tag B7 a file other than *.keys changed or went"
[ -d "$T/ks/nowhere-import" ] && [ -d "$T/ks/nowhere-export" ] && ok "$tag B7 both dirs still exist" || no "$tag B7 a keystore staging dir was removed"
if [ -e "$T/ks/nowhere-import/1010001.keys" ] || [ -e "$T/ks/nowhere-export/1010002.keys" ]; then
  no "$tag B7 a .keys file survived"; else ok "$tag B7 both .keys files are gone"; fi
noleak "$T" "$S" "$tag B7"
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite, under each shell) =="
  # mutate <label> <roamd|main> <sed args...>
  mutate(){ local m label="$1" kind="$2" src s rc; shift 2
    m=$(mktemp -d -p "$W")
    case "$kind" in roamd) src="$SUT" ;; *) src="$MAINGO" ;; esac
    if ! sed "$@" "$src" > "$m/m" 2>"$m/err"; then no "MUTATION BROKEN (sed): $label: $(cat "$m/err")"; rm -rf "$m"; return; fi
    if cmp -s "$src" "$m/m"; then no "MUTATION INERT: $label"; rm -rf "$m"; return; fi
    for s in "${SHELLS[@]}"; do
      if [ "$kind" = roamd ]; then ONLY_SHELL="$s" bash "$0" "$m/m" >/dev/null 2>&1; rc=$?
      else ONLY_SHELL="$s" MAINGO="$m/m" bash "$0" "$SUT" >/dev/null 2>&1; rc=$?; fi
      if [ "$rc" -eq 0 ]; then no "NOT CONVICTED: $label [${s##*/}] -- suite passes on broken code"; else ok "convicted: $label [${s##*/}]"; fi
    done
    rm -rf "$m"
  }
  mutate "M1: the marker check is removed" roamd -e 's@^  if \[ -s "\$STATE/.roamsession" \]; then STAGING_BOOT=KEPT:session; return 0; fi$@  :@'
  mutate "M2: the link check is removed" roamd -e 's@^    if \[ -L "\$_e" \]; then _lk=\$((_lk + 1)); continue; fi$@    :@'
  mutate "M3: keystore-in is dropped from the list" roamd -e 's@^            /data/nowhere/keystore-stage \\$@            /data/nowhere/keystore-stage; do@' -e '\%^            /data/nowhere/keystore-in; do$%d'
  mutate "M4: acct-stage is dropped from the list" roamd -e 's@^  for _e in /data/nowhere/acct-stage \\$@  for _e in \\@'
  mutate "M14: appcode-reuse is dropped from the list (NWP-20261128-09)" roamd -e '\%^            /data/nowhere/appcode-reuse \\$%d'
  mutate "M5: keystore-map joins the list" roamd -e 's@^            /data/nowhere/keystore-in; do$@            /data/nowhere/keystore-in /data/nowhere/keystore-map; do@'
  mutate "M6: the LEFT check is removed" roamd -e 's@^    if \[ -e "\$_e" \]; then _left=\$((_left + 1)); else _rm=\$((_rm + 1)); fi$@    _rm=$((_rm + 1))@'
  mutate "M7: the category line is deleted from the op" roamd -e '/^  staging_boot$/d'
  mutate "M8: BOOT-SWEEP joins concurrentSafeCmd" main -e 's@^\tcase "POLL-REAP", "ACK-REAP",$@\tcase "POLL-REAP", "ACK-REAP", "BOOT-SWEEP",@'
  mutate "M9: the logoff-creds check is removed" roamd -e 's@^  if \[ -e "\$KS_CREDS" \]; then STAGING_BOOT=KEPT:reap; return 0; fi$@  :@'
  mutate "M10: the user-record check is removed" roamd -e 's@^    if userdir_has_record "\$_i"; then STAGING_BOOT=KEPT:user; return 0; fi$@    :@'
  mutate "M11: the positive control is removed" roamd -e 's@^  if \[ -z "\$_s0" \]; then STAGING_BOOT=UNREACHABLE; return 0; fi$@  :@'
  mutate "M12: the marker check moves after the creds and user-record checks" roamd \
    -e '\%^  if \[ -s "\$STATE/\.roamsession" \]; then STAGING_BOOT=KEPT:session; return 0; fi$%d' \
    -e 's@^  if \[ -z "\$_s0" \]; then STAGING_BOOT=UNREACHABLE; return 0; fi$@  if [ -s "$STATE/.roamsession" ]; then STAGING_BOOT=KEPT:session; return 0; fi\n&@'
  mutate "M13: the marker check moves after the creds check" roamd \
    -e '\%^  if \[ -s "\$STATE/\.roamsession" \]; then STAGING_BOOT=KEPT:session; return 0; fi$%d' \
    -e 's@^  if \[ -e "\$KS_CREDS" \]; then STAGING_BOOT=KEPT:reap; return 0; fi$@&\n  if [ -s "$STATE/.roamsession" ]; then STAGING_BOOT=KEPT:session; return 0; fi@'
  # K1-K4 (NWP-20261114-23): the *.keys loop over $KS_IMPORT and $KS_EXPORT.
  KDEL='/^  for _d in "\$KS_IMPORT" "\$KS_EXPORT"; do$/,/^  done$/d'
  KLOOP='  for _d in "$KS_IMPORT" "$KS_EXPORT"; do\n    [ -n "$_d" ] || continue\n    for _k in "$_d"/*.keys; do\n      [ -e "$_k" ] || [ -L "$_k" ] || continue\n      _n=$((_n + 1))\n      if [ -L "$_k" ]; then _lk=$((_lk + 1)); continue; fi\n      rm -f "$_k" 2>/dev/null\n      if [ -e "$_k" ]; then _left=$((_left + 1)); else _rm=$((_rm + 1)); fi\n    done\n  done'
  mutate "K1: the *.keys loop is deleted" roamd -e "$KDEL"
  mutate "K2: the *.keys loop runs before the user-record check" roamd -e "$KDEL" \
    -e "/^staging_boot() {\$/,/^}\$/s@^  for _p in /data/system/users/\*; do\$@$KLOOP\n&@"
  mutate "K3: the keystore staging dir is removed, not its files" roamd \
    -e 's@^      rm -f "\$_k" 2>/dev/null$@      rm -rf "$_d" 2>/dev/null@'
  mutate "K4: the *.keys link check is removed" roamd \
    -e 's@^      if \[ -L "\$_k" \]; then _lk=\$((_lk + 1)); continue; fi$@      :@'
fi

echo
echo "shells: ${SHELLS[*]}"
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
