#!/usr/bin/env bash
# test-remap-per-pkg.sh [<nowhere_roamd.sh>] [--mutate] -- remap_per_pkg and reown_restored, the root-run re-own
# of every package dir of a roamed user at EVERY sign-in (NWP-20261020-13).
#
# WHY THIS IS COMMITTED. remap_per_pkg runs for CE (`remap_per_pkg "$USERDIR"`) and DE (`remap_per_pkg "$DEDIR"`)
# and carries three rules its comments call load-bearing, which no suite executed (test-in-refused-noop.sh and
# test-userdir-orphan.sh stub it to `:`):
#   RULE 1  an app-owned package dir (owner >= 100000) has each child chowned -R to that owner;
#   RULE 2  a ROOT-owned (restore-created) package dir goes to reown_restored, which chowns it to
#           uid*100000+appId from packages.list -- NEVER to the dir's own owner (root), or the data stays 0:0 and
#           installd "recovers" it by deleting it (DIA-20260625-03);
#   RULE 3  every name is `local`: reown_restored's `name=` once clobbered the global profile name between the CE
#           and DE restores, and #de and #media silently stopped restoring.
# Two more rules close the backlog row "Play install fails first try: RESTORE writes Glide's cache as root, app
# EACCESes (#100)" (NWP-20261029-07); they were pinned as TODAY'S behaviour (R1b, R9) until then:
#   RULE 4  the CONTENTS of an app-owned package's cache/ and code_cache/ are chowned -R to that dir's own uid:gid
#           (the pair an app-made child carries), in ONE chown per non-empty dir; the dir itself is never chowned;
#           an empty dir gets no chown; a root-owned package's cache dir is left to reown_restored; a non-numeric
#           uid or gid is logged once and left (R1b, R10, R11, R12);
#   RULE 5  a dot-named child of an app-owned package dir is chowned to the package owner; `.` and `..` never (R9);
#   and the fork budget: exactly two `stat -c` in the function, whatever the package count, and no `| while` (R14).
#   RULE 6  reown_restored's packages.list lookup is EXACT on field 1 (NWP-20261111-11): the grep it replaced read the
#           name as a regex, so `^com.example.bank ` matched `com.examplexbank` listed earlier and the restored dir was
#           chowned to that app's uid (R15, R16).
#
#   bash test-remap-per-pkg.sh              # the cases, under every shell present (bash, sh, dash, mksh)
#   bash test-remap-per-pkg.sh --mutate     # ... plus mutants of roamd that must each CONVICT
#
# Pure logic -- no device, no root. Both functions are EXTRACTED by anchor, never copied, and re-rooted to a temp
# tree. Package dirs and their children are REAL temp dirs (so the globs and tests act on them); `stat` answers
# from a fake owner table and `chown` only logs its argv.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# The run's one temp root: every case tree and every mutant copy is made inside it, so a plain, a --mutate and a
# failing run all leave nothing.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
reroot() { printf '%s\n' "$1" | sed -E 's#([" ])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

SHELLS=""
for s in bash sh dash mksh; do p=$(command -v "$s" 2>/dev/null) && SHELLS="$SHELLS $s"; done

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" p=0 x=0 RO RR FNS n sh T SRC ns np na nb nl lg
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }

  RO=$(fn_of "$f" reown_restored)
  RR=$(fn_of "$f" remap_per_pkg)
  [ -n "$RO" ] || { echo "EXTRACTION FAILED: function reown_restored not found in $f" >&2; return 2; }
  [ -n "$RR" ] || { echo "EXTRACTION FAILED: function remap_per_pkg not found in $f" >&2; return 2; }
  case "$RO" in *'/data/system/packages.list'*'chown -R'*) ;; *) echo "EXTRACTION FAILED: reown_restored body in $f" >&2; return 2 ;; esac
  case "$RR" in *'reown_restored "$pkg"'*'chown -R'*) ;; *) echo "EXTRACTION FAILED: remap_per_pkg body in $f" >&2; return 2 ;; esac
  FNS=$(reroot "$RO"; reroot "$RR")
  n=$(printf '%s\n' "$FNS" | grep -o '\$ROOT/data/' | grep -c .)
  [ "$n" -ge 1 ] || { echo "RE-ROOT FAILED: $n rewritten paths, want >= 1" >&2; return 2; }
  n=$(nleft "$FNS")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: $n absolute /data path(s) in live code" >&2; return 2; }

  HARN=""
  # run_case <shell> <root> <call-snippet>: the REAL functions under <shell>, with stat/chown stubbed.
  run_case() {
    local s="$1" r="$2" drv="$2/driver.sh"
    {
      printf 'ROOT=%s; uid=11; LOG="$ROOT/roam.log"\n' "$r"
      cat <<'STUBS'
stat() {
  [ "$1" = -c ] || return 1
  case "$2" in '%u %n'|'%u %g %n') ;; *) return 1;; esac
  f="$2"; shift 2
  for p in "$@"; do
    [ -e "$p" ] || continue
    while read -r tp to tg; do
      if [ "$tp" = "$p" ]; then
        if [ "$f" = '%u %n' ]; then echo "$to $p"; else echo "$to $tg $p"; fi
        break
      fi
    done < "$ROOT/owners"
  done
}
chown() { echo "chown $*" >> "$ROOT/chown.log"; }
STUBS
      printf '%s\n' "$FNS"
      printf '%s\n' "$3"
    } > "$drv"
    : > "$r/chown.log"
    "$s" "$drv" > "$r/out" 2> "$r/err"
    local e pat='command not found|unbound variable|syntax error|bad substitution|not found'
    # The real functions never feed `[ -lt ]` a non-number, so in a plain run that complaint (dash: Illegal number,
    # bash: integer expression expected) is a harness fault; in a mutant run it is the mutant's own effect (M6).
    [ -n "$quiet" ] || pat="$pat|Illegal number|integer expression expected"
    e=$(grep -m1 -E "$pat" "$r/err" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$s: $e]"
  }
  # chk <label> <want-chown-log> <want-out> : compares the normalised chown log and the printed output
  ok() { p=$((p+1)); say "  ok    [$sh] $1"; }
  bad() { x=$((x+1)); say "  FAIL  [$sh] $1 -- $2"; [ -z "$quiet" ] || echo "FAILED [$sh] $1 -- $2"; }
  norm() { sed "s#$T#R#g" "$1"; }
  expect() {  # expect <label> <want-chown-log> <want-out>
    local got out
    got=$(norm "$T/chown.log"); out=$(norm "$T/out")
    if [ "$got" = "$2" ] && [ "$out" = "$3" ]; then ok "$1"
    else bad "$1" "chown log [$got] out [$out]; wanted [$2] [$3]; stderr [$(head -n 1 "$T/err" 2>/dev/null)]"; fi
  }
  fresh() { T=$(mktemp -d -p "$W"); mkdir -p "$T/data/user/11" "$T/data/system"; : > "$T/owners"; : > "$T/data/system/packages.list"; D="$T/data/user/11"; }
  own() { printf '%s %s %s\n' "$2" "$1" "${3:-$1}" >> "$T/owners"; }   # own <uid> <path> [<gid>]
  CALL='remap_per_pkg "$ROOT/data/user/11"; echo "rc=$?"'

  for sh in $SHELLS; do
    # R1 RULE: an app-owned dir's children are chowned to its owner, cache/code_cache aside
    fresh; mkdir -p "$D/com.app/"{files,databases,shared_prefs,cache,code_cache}; own 1110123 "$D/com.app"
    own 1110123 "$D/com.app/cache" 1120123; own 1110123 "$D/com.app/code_cache" 1120123   # EMPTY: no chown at all
    run_case "$sh" "$T" "$CALL"
    expect "R1 app-owned dir: files, databases, shared_prefs re-owned, nothing else" \
"chown -R 1110123:1110123 R/data/user/11/com.app/databases
chown -R 1110123:1110123 R/data/user/11/com.app/files
chown -R 1110123:1110123 R/data/user/11/com.app/shared_prefs" "rc=0"
    # R1b RULE 4 (#100 row, MECHANISM (3)): the contents of cache/code_cache go to the dir's own uid:gid, never the dir
    fresh; mkdir -p "$D/com.app/"{files,cache/image_manager_disk_cache,code_cache/startup_agents}
    : > "$D/com.app/cache/journal"; : > "$D/com.app/code_cache/x.prof"
    own 1110123 "$D/com.app"; own 1110123 "$D/com.app/cache" 1120123; own 1110123 "$D/com.app/code_cache" 1120123
    run_case "$sh" "$T" "$CALL"
    expect "R1b cache/code_cache contents re-owned to the dir's uid:gid, one chown each" \
"chown -R 1110123:1110123 R/data/user/11/com.app/files
chown -R 1110123:1120123 R/data/user/11/com.app/cache/image_manager_disk_cache R/data/user/11/com.app/cache/journal
chown -R 1110123:1120123 R/data/user/11/com.app/code_cache/startup_agents R/data/user/11/com.app/code_cache/x.prof" "rc=0"
    n=$(grep -cE '(^chown -R [^ ]+ |[ ])[^ ]*/com\.app/(cache|code_cache)( |$)' "$T/chown.log")
    if [ "$n" = 0 ]; then ok "R1b no chown names the cache or code_cache dir itself"; else bad "R1b no chown names the cache or code_cache dir itself" "$n line(s): $(cat "$T/chown.log")"; fi

    # R2: root-owned dir -> reown_restored -> uid*100000+appId
    fresh; mkdir -p "$D/com.play/files"; own 0 "$D/com.play"
    printf 'com.play.other 10999 0 /data/user/0/com.play.other default 3003\ncom.play 10456 0 /data/user/0/com.play default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" "$CALL"
    expect "R2 root-owned dir: one chown -R to 11*100000+10456" "chown -R 1110456:1110456 R/data/user/11/com.play" "rc=0"
    if grep -qxF '[roamd] reowned restored com.play -> 1110456 (user 11)' "$T/roam.log"; then ok "R2 log line"; else bad "R2 log line" "$(cat "$T/roam.log")"; fi

    # R3: root-owned, not in packages.list
    fresh; mkdir -p "$D/com.gone/files"; own 0 "$D/com.gone"
    printf 'com.other 10456 0 /x default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" "$CALL"
    expect "R3 root-owned dir missing from packages.list: no chown, rc 0" "" "rc=0"

    # R4: a FILE named like a listed package, root-owned: only [ -d ] stops it
    fresh; : > "$D/com.listed"; own 0 "$D/com.listed"
    printf 'com.listed 10456 0 /x default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" "$CALL"
    expect "R4 regular file under DIR: no chown" "" "rc=0"

    # R5: empty DIR
    fresh
    run_case "$sh" "$T" "$CALL"
    expect "R5 empty DIR: rc 0, no chown" "" "rc=0"

    # R6: app-owned dir with no children: never a literal *
    fresh; mkdir -p "$D/com.app"; own 1110123 "$D/com.app"
    run_case "$sh" "$T" 'remap_per_pkg "$ROOT/data/user/11"'   # rc not pinned: the last `[ -e ] &&` leaves 1 today
    expect "R6 childless app-owned dir: no chown (no literal *)" "" ""

    # R7: non-numeric owner. The package IS in packages.list: without the guard, mksh (the device's shell) reads
    # `[ abc -lt 100000 ]` as 0 < 100000, takes the root-owned branch and re-owns the dir to the app uid, where bash
    # and dash fail the test and chown its children to abc:abc. The listing makes both wrong paths visible (M6).
    fresh; mkdir -p "$D/com.app/files"; own abc "$D/com.app"
    printf 'com.app 10456 0 /x default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" "$CALL"
    expect "R7 non-numeric owner: no chown" "" "rc=0"

    # R8 LOCALS: both branches run; no caller variable of those names changes
    fresh; mkdir -p "$D/com.app/files" "$D/com.app/cache" "$D/com.play/files"; : > "$D/com.app/cache/a"
    own 1110123 "$D/com.app"; own 1110123 "$D/com.app/cache" 1120123; own 0 "$D/com.play"
    printf 'com.play 10456 0 /x default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" 'name=profile-x pkg=P own=O sub=S listing=L pkgdir=D appid=A target=T clisting=CL cu=CU cg=CG cdir=CD cpkg=CP csub=CS
remap_per_pkg "$ROOT/data/user/11"; echo "rc=$?"
echo "$name $pkg $own $sub $listing $pkgdir $appid $target $clisting $cu $cg $cdir $cpkg $csub"'
    expect "R8 locals: name pkg own sub listing pkgdir appid target clisting cu cg cdir cpkg csub unchanged after both branches" \
"chown -R 1110123:1110123 R/data/user/11/com.app/files
chown -R 1110456:1110456 R/data/user/11/com.play
chown -R 1110123:1120123 R/data/user/11/com.app/cache/a" "rc=0
profile-x P O S L D A T CL CU CG CD CP CS"

    # R9 RULE 5 (#100 row, second seam): dot-named children are re-owned; . and .. never
    fresh; mkdir -p "$D/com.app/files" "$D/com.app/.hidden" "$D/com.app/..x"; own 1110123 "$D/com.app"
    run_case "$sh" "$T" "$CALL"
    expect "R9 dot-named children (.hidden, ..x) re-owned to the package owner" \
"chown -R 1110123:1110123 R/data/user/11/com.app/files
chown -R 1110123:1110123 R/data/user/11/com.app/.hidden
chown -R 1110123:1110123 R/data/user/11/com.app/..x" "rc=0"
    n=$(grep -cE '/com\.app/\.\.?$' "$T/chown.log")
    if [ "$n" = 0 ]; then ok "R9 . and .. never chowned"; else bad "R9 . and .. never chowned" "$(cat "$T/chown.log")"; fi

    # R10: dot-named children inside cache/ are covered by the cache chown
    fresh; mkdir -p "$D/com.app/cache"; : > "$D/com.app/cache/a"; : > "$D/com.app/cache/.nomedia"; : > "$D/com.app/cache/..y"
    own 1110123 "$D/com.app"; own 1110123 "$D/com.app/cache" 1120123
    run_case "$sh" "$T" "$CALL"
    expect "R10 dot-named children inside cache/ covered by the cache chown" \
"chown -R 1110123:1120123 R/data/user/11/com.app/cache/a R/data/user/11/com.app/cache/.nomedia R/data/user/11/com.app/cache/..y" "rc=0"

    # R11: a non-numeric uid or gid in the cache listing: left alone, logged once per dir, rc 0
    fresh; mkdir -p "$D/com.a/cache" "$D/com.b/code_cache"; : > "$D/com.a/cache/a"; : > "$D/com.b/code_cache/b"
    own 1110123 "$D/com.a"; own abc "$D/com.a/cache" 1120123
    own 1110124 "$D/com.b"; own 1110124 "$D/com.b/code_cache" xyz
    printf 'com.a 10456 0 /x default 3003\ncom.b 10457 0 /x default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" "$CALL"
    expect "R11 non-numeric cache uid/gid: no chown, rc 0" "" "rc=0"
    na=$(grep -cxF '[roamd] remap: cache dir of com.a unreadable -- left as is (NWP-20261029-07)' "$T/roam.log")
    nb=$(grep -cxF '[roamd] remap: cache dir of com.b unreadable -- left as is (NWP-20261029-07)' "$T/roam.log")
    nl=$(grep -c . "$T/roam.log")
    if [ "$na" = 1 ] && [ "$nb" = 1 ] && [ "$nl" = 2 ]; then ok "R11 each unreadable cache dir logged once"; else bad "R11 each unreadable cache dir logged once" "log count a[$na] b[$nb] total[$nl] chown [$(cat "$T/chown.log")]"; fi

    # R12: a root-owned package goes to reown_restored; its 0-owned cache dir gets no extra chown
    fresh; mkdir -p "$D/com.play/cache"; : > "$D/com.play/cache/a"; own 0 "$D/com.play"; own 0 "$D/com.play/cache"
    printf 'com.play 10456 0 /data/user/0/com.play default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" "$CALL"
    expect "R12 root-owned package: reown_restored only, its 0-owned cache dir gets no extra chown" "chown -R 1110456:1110456 R/data/user/11/com.play" "rc=0"

    # R13: a cache that is a regular file is never chowned or walked
    fresh; mkdir -p "$D/com.app"; : > "$D/com.app/cache"; own 1110123 "$D/com.app"; own 1110123 "$D/com.app/cache" 1120123
    run_case "$sh" "$T" "$CALL"
    expect "R13 cache that is a regular file: no chown" "" "rc=0"

    # R14 SOURCE: exactly two stat forks whatever the package count, and no pipeline into a loop
    SRC=$(printf '%s\n' "$RR" | sed -E 's/(^|[[:space:]])#.*$//')
    ns=$(printf '%s\n' "$SRC" | grep -o 'stat -c' | grep -c .)
    np=$(printf '%s\n' "$SRC" | grep -cE '\|[[:space:]]*while')
    if [ "$ns" = 2 ] && [ "$np" = 0 ]; then ok "R14 remap_per_pkg has exactly two stat -c and no | while"; else bad "R14 remap_per_pkg has exactly two stat -c and no | while" "stat -c [$ns] pipelines [$np]"; fi

    # R15 RULE 6: a look-alike listed FIRST (com.examplexbank: the old regex's dot matched its x) must not take the
    # restored dir -- the chown goes to com.example.bank's own appId
    fresh; mkdir -p "$D/com.example.bank/files"; own 0 "$D/com.example.bank"
    printf 'com.examplexbank 10999 0 /data/user/0/com.examplexbank default 3003\ncom.example.bank 10456 0 /data/user/0/com.example.bank default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" "$CALL"
    expect "R15 look-alike com.examplexbank listed before com.example.bank: chown to 11*100000+10456" "chown -R 1110456:1110456 R/data/user/11/com.example.bank" "rc=0"

    # R16 RULE 6: only the look-alike is listed -> unresolved: no chown, no log line, rc 0
    fresh; mkdir -p "$D/com.example.bank/files"; own 0 "$D/com.example.bank"
    printf 'com.examplexbank 10999 0 /data/user/0/com.examplexbank default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" "$CALL"
    expect "R16 only the look-alike listed: no chown, rc 0" "" "rc=0"
    # roam.log may not exist here: nothing on this path writes $LOG (reown_restored returns before its echo, and
    # there is no cache dir for the cache pass to log), so a missing file reads as empty -- grep -c would print no
    # count at all on it, not 0.
    lg=$(grep 'reowned restored' "$T/roam.log" 2>/dev/null)
    if [ -z "$lg" ]; then ok "R16 no reowned line logged"; else bad "R16 no reowned line logged" "$lg"; fi
  done
  [ -z "$HARN" ] || { echo "HARNESS ERROR:$HARN" >&2; return 2; }
  say "passed $p, failed $x (shells:$SHELLS)"
  [ "$x" = 0 ]
}

if [ "$MUTATE" = no ]; then suite "$SUT"; exit $?; fi

suite "$SUT"; rc=$?
[ "$rc" = 0 ] || exit "$rc"

# --- mutants ------------------------------------------------------------------------------------------------
# Each is a transform of roamd's text, by exact line; a mutant that changes nothing is a failure of the suite, and
# only a run in which a case FAILS (rc 1) convicts -- a harness error (rc 2) is not a conviction.
L_CACHE='      case "${sub##*/}" in cache|code_cache) continue;; esac'
L_IF='    if [ "$own" -lt 100000 ]; then'
L_LOC1='  local pkg own sub listing clisting cu cg cdir cpkg csub'
L_LOC2='  local pkgdir="$1" name appid target'
L_DIR='    [ -d "$pkg" ] || continue'
L_NUM='    case "$own" in '"''"'|*[!0-9]*) continue;; esac'
L_TGT='  target=$((uid * 100000 + appid))'
L_AWK='  appid=$(NW_PKG="$name" awk '"'"'$1 == ENVIRON["NW_PKG"] { print $2; exit }'"'"' /data/system/packages.list 2>/dev/null)'
L_OLDGREP='  appid=$(grep -m1 "^$name " /data/system/packages.list 2>/dev/null | cut -d'"' '"' -f2)'
L_E='      [ -e "$sub" ] || continue'
L_FOR='    for sub in "$pkg"/* "$pkg"/.[!.]* "$pkg"/..?*; do'
L_CLIST="  clisting=\$(stat -c '%u %g %n' \"\$1\"/*/cache \"\$1\"/*/code_cache 2>/dev/null)"
L_CLT='    if [ "$cu" -lt 100000 ]; then continue; fi'
L_CNUM='    case "$cu:$cg" in :*|*:|*:*:*|*[!0-9:]*) echo "[roamd] remap: cache dir of $cpkg unreadable -- left as is (NWP-20261029-07)" >> "$LOG"; continue;; esac'
L_CFOR='    for csub in "$cdir"/* "$cdir"/.[!.]* "$cdir"/..?*; do'
L_CE='      if [ -e "$csub" ]; then set -- "$@" "$csub"; fi'
L_CCH='    if [ "$#" -gt 0 ]; then chown -R "$cu:$cg" "$@" 2>> "$LOG"; fi'
for l in "$L_CACHE" "$L_IF" "$L_LOC1" "$L_LOC2" "$L_DIR" "$L_NUM" "$L_E" "$L_FOR" "$L_CLIST" "$L_CLT" "$L_CNUM" "$L_CFOR" "$L_CE" "$L_CCH" "$L_AWK"; do
  [ "$(grep -cxF -- "$l" "$SUT")" = 1 ] || { echo "EXTRACTION FAILED: anchor line not unique in $SUT: $l" >&2; exit 2; }
done
# L_TGT also occurs elsewhere in roamd: it is mutated in reown_restored only (the first occurrence, asserted here).
[ "$(fn_of "$SUT" reown_restored | grep -cxF -- "$L_TGT")" = 1 ] || { echo "EXTRACTION FAILED: target line not in reown_restored in $SUT" >&2; exit 2; }
[ "$(grep -nxF -- "$L_TGT" "$SUT" | head -1 | cut -d: -f1)" = "$(( $(grep -nx 'reown_restored() {' "$SUT" | cut -d: -f1) + $(fn_of "$SUT" reown_restored | grep -nxF -- "$L_TGT" | cut -d: -f1) - 1 ))" ] || { echo "EXTRACTION FAILED: first target line is not reown_restored's in $SUT" >&2; exit 2; }
# mut <name> <anchor> <replacement>: replace the anchor line (empty replacement drops it)
mut() {  # mut <name> <anchor> <replacement> [<regex the failure detail must match>]
  local name="$1" t out r s
  t=$(mktemp -p "$W")
  awk -v A="$2" -v B="$3" '$0==A && !done { done=1; if (B != "") print B; next } {print}' "$SUT" > "$t"
  if cmp -s "$t" "$SUT"; then echo "  FAIL  mutant did not apply: $name"; MFAIL=1; command rm -f "$t"; return; fi
  out=$(suite "$t" quiet 2>&1); r=$?
  command rm -f "$t"
  # A conviction is a case that FAILED its assertion for the mutant's reason, not any nonzero exit: when a regex is
  # given, the failure detail must show it (so a shell that merely aborted on the mutant's runtime error is no proof).
  # The regex is checked PER SHELL (the failure lines carry the shell tag), so one shell's conviction cannot vouch
  # for another's: a shell that dies on the mutant (dash: `Illegal number`) must say so on its own R7 line.
  local conv=1
  if [ -n "${4:-}" ]; then
    # A here-string, NEVER `printf ... | grep -q`: under pipefail, grep -q exits at its first match, printf's next
    # write hits the closed pipe, and the pipeline fails -- a conviction reported as a miss (M16 on CI, 2026-10-25).
    for s in $SHELLS; do grep -qE -- "FAILED \[$s\] $4" <<< "$out" || conv=0; done
  fi
  if [ "$r" = 1 ] && [ "$conv" = 1 ]; then echo "  ok    CONVICTED: $name"
  else echo "  FAIL  NOT CONVICTED (rc=$r): $name"; MFAIL=1; fi
}
MFAIL=0
echo "== mutants =="
mut "M1 cache/code_cache prune dropped (R1b)" "$L_CACHE" "" 'R1b '
mut "M2 root-owned branch never taken (R2)" "$L_IF" '    if false; then'
mut "M3 remap_per_pkg locals dropped (R8)" "$L_LOC1" ""
mut "M4 reown_restored locals dropped (R8)" "$L_LOC2" ""
mut "M5 the [ -d ] guard dropped (R4)" "$L_DIR" ""
mut "M6 the numeric owner guard dropped (R7)" "$L_NUM" "" 'R7 .*(chown log \[chown -R (abc:abc|1110456:1110456) |stderr \[.*(Illegal number|integer expression expected))'
mut "M7 target is the bare appId (R2)" "$L_TGT" '  target=$((appid))'
mut "M8 the [ -e ] guard on package children dropped (R6)" "$L_E" "" 'R6 '
mut "M9 the dot globs dropped from the child loop (R9)" "$L_FOR" '    for sub in "$pkg"/*; do' 'R9 '
mut "M10 the cache pass removed (R1b)" "$L_CLIST" '  clisting=' 'R1b '
mut "M11 cache children chowned cu:cu (R1b)" "$L_CCH" '    if [ "$#" -gt 0 ]; then chown -R "$cu:$cu" "$@" 2>> "$LOG"; fi' 'R1b '
mut "M12 the cache dir itself chowned (R1b)" "$L_CCH" '    if [ "$#" -gt 0 ]; then chown -R "$cu:$cg" "$cdir" 2>> "$LOG"; fi' 'R1b '
mut "M13 the -lt 100000 cache guard dropped (R12)" "$L_CLT" "" 'R12 '
mut "M14 the numeric guard on cu/cg dropped (R11)" "$L_CNUM" "" 'R11 '
mut "M15 the dot globs dropped from the cache children test (R10)" "$L_CFOR" '    for csub in "$cdir"/*; do' 'R10 '
mut "M16 the [ -e ] test on cache children dropped (R1)" "$L_CE" '      set -- "$@" "$csub"' 'R1 '
mut "M17 cdir dropped from the cache pass locals (R8)" "$L_LOC1" '  local pkg own sub listing clisting cu cg cpkg csub' 'R8 '
mut "M18 the exact awk lookup reverted to the old grep regex (R15)" "$L_AWK" "$L_OLDGREP" 'R15 '
[ "$MFAIL" = 0 ] || exit 1
echo "all mutants convicted"
