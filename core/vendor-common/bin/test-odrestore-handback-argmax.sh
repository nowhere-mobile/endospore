#!/usr/bin/env bash
# test-odrestore-handback-argmax.sh [<nowhere_roamd.sh>] [--mutate] -- odrestore's counted hand-back walks run in
# BOUNDED batches, check their status, and a failed one keeps the hold (NWP-20261209-04).
#
# WHY THIS IS COMMITTED. Backlog row "odrestore's counted hand-back fails with 'Argument list too long' on a large
# hold, answers OK, drops the hold, and leaves the app's data root-owned at bare s0". On lynx 2026111604 (2026-11-17,
# device-proof round S16, R28) a 30,914-entry hold went through reown_restored's and relabel_restored's
# `find ... -exec sh -c '...' {} +` walks. Toybox find built ONE batch the kernel refused (E2BIG), logged
# `find: exec sh: Argument list too long` and carried on; nothing read its status, so roamd logged `reowned`,
# `relabelled` and `restored+reowned`, answered OK and deleted the hold, and 28,425 entries stayed root:root at bare
# s0. The app crashed at launch with EACCES. Every walk is now od_walk's: `find -print0 | xargs -0 -r -n 256 sh -c`.
#
# This suite EXECUTES the real extracted od_walk, mi_path, reown_restored, relabel_restored, od_relabel,
# reown_ext_appdata, od_label_done, od_label_watched, od_extdata_watched, cutoff_prog and the real odrestore arm,
# under every shell found (the device's is mksh). PATH stubs `chown`, `chcon` and `restorecon` record every path they
# get (NUL-terminated) and exit 0, or 1 on the path named in $REC/fail.<tool> (or under $REC/failunder.<tool>);
# `stat -c %C` answers the app context. A `mktemp` shim fails on demand (FOREGROUND below). xargs is the host's. A
# `find` shim first on PATH runs the host's find, drops `! -context X` (the host's find has no SELinux), and turns a
# trailing `-exec CMD... {} +` into ONE exec of the whole list, as toybox did on lynx: the kernel refuses it with E2BIG.
# Every other form passes through. When toybox is on PATH (or NWP_TEST_TOYBOX names one), every case runs again per
# shell with toybox's find (behind the same shim) and toybox's xargs, labelled [<shell>+toybox].
#   BIG    THE BIG HOLD, built once per run and reused by every shell and mutant: 40,000 entries in 200 dirs, each path
#          over 200 bytes, so the list is several times one ARG_MAX. Each walk (reown_restored, relabel_restored counted
#          and uncounted, od_relabel on /data/media, reown_ext_appdata's data and obb chowns, od_extdata_watched's -D
#          relabel) touches EVERY entry exactly once (the recorded paths, sorted, equal find's listing), returns 0 and
#          logs its success line.
#   CNT    StallCount: each counted walk's count file holds more than one line, each <= 256, summing to the entries
#          walked; od_label_watched with OD_GROW_EVERY=1 writes at least one `cutoff od` line.
#   NAMES  a name holding a space and one holding a newline are each ONE argument.
#   ARM    the REAL odrestore arm: a healthy CE hand-back answers OK and removes the hold; a chown or a chcon that
#          fails on one path, a tool that cannot be executed, and a find error each keep the hold, answer
#          ERR-NOTREADY, log the WARN line and no `reowned restored`, `relabelled` or `restored+reowned`; a failed
#          Android/data walk after the loop answers ERR-NOTREADY with no hold (not OK NOSRC); an overlay mounted under
#          Android/data, or under an external hold, is pruned, so a healthy restore answers OK.
#   FOREGROUND  the same arm when od_label_watched cannot make its count file (an Android/obb hold): the uncounted
#          external restorecon walk is still bounded and pruned, so a healthy one answers OK and removes the hold, and a
#          failed restorecon or no status file keeps the hold and answers ERR-NOTREADY.
#
#   bash test-odrestore-handback-argmax.sh              # the cases, under every shell found
#   bash test-odrestore-handback-argmax.sh --mutate     # ... plus mutants that must each CONVICT under each shell
#
# Pure logic -- no device. The functions are EXTRACTED by anchor and re-rooted to a temp tree.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every tree, driver, stub and mutant copy is made inside W, so a run that passes, fails or convicts leaves nothing.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=(); seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$s")
done
[ "${#SHELLS[@]}" -gt 0 ] || { echo "no shell found" >&2; exit 2; }
echo "shells: ${SHELLS[*]}"
REALFIND=$(command -v find) || { echo "no find" >&2; exit 2; }
REALMKTEMP=$(command -v mktemp) || { echo "no mktemp" >&2; exit 2; }
# THE TOYBOX LEG: when toybox is on PATH (or NWP_TEST_TOYBOX names a toybox binary), every case runs a second time per
# shell with TOYBOX's find and xargs (labels [<shell>+toybox]), so od_walk's `find -print0 | xargs -0 -r -n 256` is
# checked against the tools the handsets run. The host leg always runs: the mutants are convicted on its labels.
TOYBOX="${NWP_TEST_TOYBOX:-$(command -v toybox 2>/dev/null)}"
if [ -n "$TOYBOX" ]; then
  [ -x "$TOYBOX" ] || { echo "toybox: $TOYBOX is not executable" >&2; exit 2; }
  echo "toybox leg: $TOYBOX ($("$TOYBOX" --version 2>/dev/null | head -1)): its find and xargs"
else
  echo "toybox: not on this host, so no toybox leg (the find shim reproduces its single-exec batch)"
fi

UID_=15
PKG=com.example.game
APPID=10234
OWNED=$((UID_ * 100000 + APPID))
CTX='u:object_r:app_data_file:s0:c15,c256,c512,c768'
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then command printf "%s\n" "$*"; else command printf "%s" "$*"; fi; }'

# ---------------------------------------------------------------------------------------------------------------------
# The shared tree: $BR/data/... holds the big hold (Android/data/<pkg>), a smaller obb dir, packages.list, and the
# PATH stubs in $BR/bin. Nothing writes into it after this block: every case writes only under its own case dir.
BR="$W/big"
EXTD="$BR/data/media/$UID_/Android/data/$PKG"
OBBD="$BR/data/media/$UID_/Android/obb/$PKG"
mkdir -p "$BR/bin" "$BR/data/system" "$EXTD" "$OBBD"
echo "$PKG $APPID 0 /data/user/0/$PKG default:targetSdkVersion=34 none 0 1 1234" > "$BR/data/system/packages.list"
LONG=$(printf 'x%.0s' $(seq 1 90))
t0=$(date +%s)
( cd "$EXTD" || exit 2
  i=0; while [ "$i" -lt 200 ]; do mkdir "d$i-$LONG"; i=$((i+1)); done
  # 199 files a dir: 200 + 200 * 199 = 40,000 entries below the root
  for d in d*; do printf "$d/f%s-$LONG$LONG\0" $(seq 1 199); done | xargs -0 touch ) || exit 2
( cd "$OBBD" || exit 2; i=0; while [ "$i" -lt 3 ]; do mkdir "o$i"; i=$((i+1)); done
  for d in o*; do printf "$d/g%s-$LONG\0" $(seq 1 200); done | xargs -0 touch ) || exit 2
NBIG=$("$REALFIND" "$EXTD" | grep -c .)
NOBB=$("$REALFIND" "$OBBD" | grep -c .)
BYTES=$("$REALFIND" "$EXTD" -print0 | wc -c)
MAXP=$("$REALFIND" "$EXTD" -type f | awk '{ if (length($0) > m) m = length($0) } END { print m }')
MINP=$("$REALFIND" "$EXTD" -type f | awk 'NR == 1 || length($0) < m { m = length($0) } END { print m }')
echo "big hold: $NBIG entries, $BYTES bytes of paths (ARG_MAX here $(getconf ARG_MAX)), file paths $MINP-$MAXP bytes, built in $(( $(date +%s) - t0 ))s"
[ "$NBIG" -ge 40000 ] && [ "$MINP" -ge 200 ] && [ "$BYTES" -gt $((3 * $(getconf ARG_MAX))) ] || { echo "the big hold is not big enough" >&2; exit 2; }

# chown / chcon / restorecon: drop the tool's own words (restorecon's -D or -R), record each path NUL-terminated in $REC/rec.<tool>, exit 1 on
# the path in $REC/fail.<tool> or on any path at or under the one in $REC/failunder.<tool>, else 0. $REC is the case
# dir.
for t in chown chcon restorecon; do
  case "$t" in chown|chcon) sk='shift 2' ;; restorecon) sk='case "${1:-}" in -D|-R) shift ;; esac' ;; esac
  cat > "$BR/bin/$t" <<EOF
#!/bin/sh
$sk
[ -f "\$REC/slow" ] && sleep 0.02
printf '%s\0' "\$@" >> "\$REC/rec.$t"
if [ -f "\$REC/fail.$t" ]; then f=\$(cat "\$REC/fail.$t"); for p in "\$@"; do [ "\$p" = "\$f" ] && exit 1; done; fi
if [ -f "\$REC/failunder.$t" ]; then f=\$(cat "\$REC/failunder.$t"); for p in "\$@"; do case "\$p" in "\$f"|"\$f"/*) exit 1 ;; esac; done; fi
exit 0
EOF
done
cat > "$BR/bin/stat" <<EOF
#!/bin/sh
case "\$2" in %C) echo '$CTX' ;; %u) awk -v p="\$3" '\$1 == p {print \$2; f=1} END{exit !f}' "\$REC/owners" ;; *) exec $(command -v stat) "\$@" ;; esac
EOF
# find: the host's (or toybox's, in the toybox leg), with `! -context X` dropped; a trailing `-exec CMD... {} +` is ONE
# exec of the whole list (toybox on lynx); $REC/findfail makes a -print0 walk, and $REC/findfail.list a -print listing,
# print its output and then exit 1, as a find that hit an unreadable dir does.
# mktemp: the host's, except that $REC/mktempfail holding `all` fails every call and `first` fails only the first (the
# count file of od_label_watched or od_extdata_watched), so their foreground forms run.
mkshims() {  # mkshims <bindir> <find command, shell-quoted>
  local FC="$2"
  cat > "$1/find" <<EOF
#!/usr/bin/env bash
a=(); while [ \$# -gt 0 ]; do
  if [ "\$1" = '!' ] && [ "\${2:-}" = -context ]; then shift 3; continue; fi
  a+=("\$1"); shift
done
n=\${#a[@]}
if [ "\$n" -ge 3 ] && [ "\${a[n-1]}" = + ] && [ "\${a[n-2]}" = '{}' ]; then
  i=0; while [ "\${a[i]}" != -exec ]; do i=\$((i+1)); done
  mapfile -d '' L < <($FC "\${a[@]:0:i}" -print0)
  cmd=("\${a[@]:i+1:n-i-3}")
  "\${cmd[@]}" "\${L[@]}" || { echo "find: exec \${cmd[0]}: Argument list too long" >&2; exit 1; }
  exit 0
fi
$FC "\${a[@]}"; rc=\$?
case " \${a[*]} " in *" -print0 "*) ff="\$REC/findfail" ;; *) ff="\$REC/findfail.list" ;; esac
[ -f "\$ff" ] && { echo "find: injected error" >&2; exit 1; }
exit \$rc
EOF
  cat > "$1/mktemp" <<EOF
#!/bin/sh
if [ -f "\$REC/mktempfail" ]; then
  n=\$(cat "\$REC/mktempn" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "\$REC/mktempn"
  case "\$(cat "\$REC/mktempfail")" in all) exit 1 ;; first) [ "\$n" = 1 ] && exit 1 ;; esac
fi
exec '$REALMKTEMP' "\$@"
EOF
}
mkshims "$BR/bin" "'$REALFIND'"
if [ -n "$TOYBOX" ]; then
  mkdir -p "$BR/tbin"
  cp "$BR/bin/chown" "$BR/bin/chcon" "$BR/bin/restorecon" "$BR/bin/stat" "$BR/tbin/"
  mkshims "$BR/tbin" "'$TOYBOX' find"
  printf '#!/bin/sh\nexec %s xargs "$@"\n' "'$TOYBOX'" > "$BR/tbin/xargs"
fi
chmod +x "$BR/bin/"*
[ -z "$TOYBOX" ] || chmod +x "$BR/tbin/"*

anchor_of() { awk -v a="$2" 'index($0, a) == 1 {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
reroot() { printf '%s\n' "$1" | sed -E 's#([ "|(])/data/#\1$ROOT/data/#g; s#< /proc/self/mountinfo#< "$MI"#'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" p=0 x=0 FNS ARM ODH PKGOK fn body sh L C HARN="" want got k leg BIN LS
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); printf '  FAIL  %s\n' "$l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  has() { grep -qF -- "$2" "$1" 2>/dev/null; }
  hasnot() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
  isdir() { [ -d "$1" ]; }
  isnotdir() { [ ! -d "$1" ]; }

  FNS=""
  for fn in cutoff_prog mi_path od_walk reown_restored relabel_restored od_relabel od_label_done od_label_watched \
            od_extdata_watched reown_ext_appdata; do
    body=$(anchor_of "$f" "$fn() {")
    # od_walk is new in NWP-20261209-04: the base before it has none, and its cases run (and fail) there all the same
    [ -n "$body" ] || [ "$fn" = od_walk ] || { echo "EXTRACTION FAILED: $fn in $f" >&2; return 2; }
    FNS="$FNS$(reroot "$body")"$'\n'
  done
  [ "$(nleft "$FNS")" = 0 ] || { echo "RE-ROOT INCOMPLETE: a hand-back function holds an absolute /data path" >&2; return 2; }
  ARM=$(arm_of "$f" odrestore)
  case "$ARM" in *'od_label_watched "$vol" "$dst"'*'od_extdata_watched "$pkg"'*'echo "ERR-NOTREADY" > "$RES"'*) ;; *) echo "EXTRACTION FAILED: the odrestore arm in $f" >&2; return 2 ;; esac
  ARM=$(reroot "$ARM")
  [ "$(nleft "$ARM")" = 0 ] || { echo "RE-ROOT INCOMPLETE: the odrestore arm keeps an absolute /data path" >&2; return 2; }
  ODH=$(grep -m1 -E '^ODHOLD=' "$f")
  PKGOK=$(anchor_of "$f" 'pkgname_ok() {')
  [ -n "$ODH" ] && [ -n "$PKGOK" ] || { echo "EXTRACTION FAILED: ODHOLD= or pkgname_ok in $f" >&2; return 2; }

  # newcase: a case dir C with its own state, log, mountinfo fixture and records; the tree is $1 (default: the big one)
  newcase() {
    C=$(mktemp -d -p "$W") || exit 2
    mkdir -p "$C/state" "$C/bin"; : > "$C/mountinfo"; : > "$C/owners"
  }
  # driver <root> <body>: the stubs and the extracted text, written to a FILE for the shell under test
  driver() {
    {
      printf '%s\n' "$PRINT_SHIM"
      printf "ROOT='%s'\nREC='%s'\nLOG='%s'\nSTATE='%s'\nMI='%s'\nuid=%s\nNOWHERE_PROGRESS='%s'\nOD_GROW_EVERY=1\n" \
        "$1" "$C" "$C/log" "$C/state" "$C/mountinfo" "$UID_" "$C/prog"
      printf "PATH='%s':'%s':\"\$PATH\"\nexport PATH REC\n" "$C/bin" "$BIN"
      printf '%s\n' "$FNS"
      printf '%s\n' "$2"
    } > "$C/driver.sh"
  }
  run() {  # run <sh> <root> <body>
    local e
    driver "$2" "$3"
    "$1" "$C/driver.sh" >/dev/null 2>"$C/stderr"
    e=$(grep -m1 -E 'command not found|unbound variable|syntax error|bad substitution|: not found' "$C/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$1: $e]"
  }
  val() { [ -f "$1" ] && cat "$1" || echo -; }
  # same <tool> <dir> [<dir2>]: the recorded paths, sorted, equal find's listing of the dir(s)
  same() {
    local t="$1"; shift
    cmp -s <(sort -z "$C/rec.$t" 2>/dev/null) <("$REALFIND" "$@" -print0 | sort -z)
  }
  # counts <file> <entries>: more than one line, each a number <= 256, summing to <entries>
  counts() {
    [ -f "$1" ] || return 1
    awk -v want="$2" '!/^[0-9]+$/ || $1 > 256 || $1 < 1 { bad = 1 } { s += $1; n++ } END { exit !(bad == 0 && n > 1 && s == want) }' "$1"
  }
  RLOG="[roamd] reowned restored $PKG -> $OWNED (user $UID_)"
  RELOG="[roamd] relabelled $NBIG restored entr(ies) of $PKG to the app's context"
  CNT='OD_LABEL_COUNT="$STATE/cnt"; OD_LABEL_LOG="$LOG"; export OD_LABEL_COUNT OD_LABEL_LOG; : > "$OD_LABEL_COUNT"'
  RC='echo $? > "$REC/rc"'

  for leg in host ${TOYBOX:+toybox}; do
  case "$leg" in host) BIN="$BR/bin"; LS= ;; *) BIN="$BR/tbin"; LS=+toybox ;; esac
  for sh in "${SHELLS[@]}"; do
    L="[$sh$LS]"
    say "== $sh$LS BIG: every walk touches every entry of a $NBIG-entry hold exactly once =="
    newcase; run "$sh" "$BR" "$CNT; reown_restored '$EXTD'; $RC; cp \"\$OD_LABEL_COUNT\" \"\$REC/count\""
    chk "$L BigHoldReown reown_restored chowns every entry once" same chown "$EXTD"
    chk "$L BigHoldReown returns 0" eqv "$(val "$C/rc")" 0
    chk "$L BigHoldReown logs its success line" has "$C/log" "$RLOG"
    chk "$L StallCount reown: >1 count line, each <= 256, sum = entries" counts "$C/count" "$NBIG"

    newcase; run "$sh" "$BR" "$CNT; relabel_restored '$EXTD'; $RC; cp \"\$OD_LABEL_COUNT\" \"\$REC/count\""
    chk "$L BigHoldRelabel relabel_restored (counted) chcons every entry once" same chcon "$EXTD" -xdev
    chk "$L BigHoldRelabel (counted) returns 0" eqv "$(val "$C/rc")" 0
    chk "$L BigHoldRelabel (counted) logs its success line" has "$C/log" "$RELOG"
    chk "$L StallCount chcon: >1 count line, each <= 256, sum = entries" counts "$C/count" "$NBIG"

    newcase; run "$sh" "$BR" "unset OD_LABEL_COUNT; relabel_restored '$EXTD'; $RC"
    chk "$L BigHoldRelabel relabel_restored (uncounted) chcons every entry once" same chcon "$EXTD" -xdev
    chk "$L BigHoldRelabel (uncounted) returns 0" eqv "$(val "$C/rc")" 0
    chk "$L BigHoldRelabel (uncounted) logs its success line" has "$C/log" "$RELOG"

    newcase; run "$sh" "$BR" "$CNT; od_relabel '$BR/data/media/$UID_/Android/data' '$EXTD'; $RC; cp \"\$OD_LABEL_COUNT\" \"\$REC/count\""
    chk "$L BigHoldExt od_relabel on /data/media restorecons every entry once" same restorecon "$EXTD"
    chk "$L BigHoldExt od_relabel returns 0" eqv "$(val "$C/rc")" 0
    chk "$L StallCount restorecon: >1 count line, each <= 256, sum = entries" counts "$C/count" "$NBIG"

    newcase; run "$sh" "$BR" "$CNT; reown_ext_appdata '$PKG'; $RC; cp \"\$OD_LABEL_COUNT\" \"\$REC/count\""
    chk "$L BigHoldExt reown_ext_appdata chowns every data and obb entry once" same chown "$EXTD" "$OBBD"
    chk "$L BigHoldExt reown_ext_appdata returns 0" eqv "$(val "$C/rc")" 0
    chk "$L BigHoldExt reown_ext_appdata logs its success line" has "$C/log" "[roamd] reowned ext app-data $PKG -> $OWNED (user $UID_)"
    chk "$L StallCount ext chowns: >1 count line, each <= 256, sum = entries" counts "$C/count" "$((NBIG + NOBB))"

    newcase; : > "$C/slow"; run "$sh" "$BR" "od_extdata_watched '$PKG'; $RC"
    chk "$L BigHoldExt od_extdata_watched restorecon -D's every data entry once" same restorecon "$EXTD" -xdev
    chk "$L BigHoldExt od_extdata_watched returns 0" eqv "$(val "$C/rc")" 0
    chk "$L BigHoldExt od_extdata_watched logs reown_ext_appdata's success line" has "$C/log" "[roamd] reowned ext app-data $PKG"
    chk "$L StallCount od_extdata_watched (OD_GROW_EVERY=1) writes a cutoff od line" has "$C/prog" "cutoff od "

    newcase; : > "$C/slow"; run "$sh" "$BR" "od_label_watched '$BR/data/media/$UID_/Android/data' '$EXTD'; $RC"
    chk "$L StallCount od_label_watched (OD_GROW_EVERY=1) writes a cutoff od line" has "$C/prog" "cutoff od "
    chk "$L BigHoldReown od_label_watched's chown touched every entry once" same chown "$EXTD"
    chk "$L BigHoldReown od_label_watched returns 0 and logs the reown" eqv "$(val "$C/rc"):$(grep -cF "$RLOG" "$C/log")" 0:1
    chk "$L StallCount no count or status file is left in \$STATE" eqv "$(ls -A "$C/state")" ""

    say "== $sh$LS NAMES: a name with a space and one with a newline are each one argument =="
    newcase; k="$C/tree/$PKG"; mkdir -p "$k/a b" "$k/c
d"; : > "$k/a b/x y"; : > "$k/c
d/z"
    run "$sh" "$BR" "$CNT; reown_restored '$k'; $RC"
    chk "$L NAMES every odd name chowned once, whole" same chown "$k"
    chk "$L NAMES returns 0" eqv "$(val "$C/rc")" 0

    # ---- the REAL odrestore arm -----------------------------------------------------------------------------------
    armroot() {  # armroot: a per-case root with a CE hold of 600 files onto an app-owned dest
      local i
      AR="$C/r"; HOLD="$AR/data/user/$UID_/com.nowhere.chooser/.nowhere-odhold/$PKG"; DST="$AR/data/user/$UID_/$PKG"
      mkdir -p "$AR/data/system" "$AR/data/nowhere" "$AR/data/user_de/$UID_" "$AR/data/media/$UID_/Android/data" \
               "$AR/data/media/$UID_/Android/obb" "$HOLD/d1" "$HOLD/d2" "$DST"
      cp "$BR/data/system/packages.list" "$AR/data/system/"
      i=0; while [ "$i" -lt 300 ]; do : > "$HOLD/d1/f$i"; : > "$HOLD/d2/f$i"; i=$((i+1)); done
      echo "$DST $OWNED" > "$C/owners"
    }
    armrun() {  # armrun <sh>: the real odrestore arm for $PKG under the shell named
      local t body
      body="$(printf "%s='%s'\n" op odrestore srcunit "$PKG" RES "$C/res" ACCT_AUTH_PKG com.example.authenticator)"$'\n'
      body="$body$(printf '%s\n' 'USERDIR="$ROOT/data/user/$uid"' "$ODH" "$PKGOK")"$'\n'
      for t in am pidof pkg_live_pids grant_perms_for keystore_register wait_acct_authenticator acct_reload sync_apply \
               a11y_apply autofill_apply vpn_preconsent_off od_unblock_app od_pending_clear od_block_installed od_park_var; do
        body="$body$t() { :; }"$'\n'
      done
      body="$body"'od_fetch_data() { return 0; }; od_listed() { return 1; }; od_block_app() { return 0; }; od_shipped_prep() { return 0; }
od_unf_path() { echo "$STATE/odfetch.$1/unfetched.$2"; }
od_watched() { shift; "$@" 2>&1; }
pm() { return 0; }
case "$op" in
'"$ARM"'
esac'
      run "$1" "$AR" "$body"
    }
    ok_no_lies() {  # ok_no_lies <case>: the failure is told, and no success line is
      chk "$L $1 the reply is ERR-NOTREADY" eqv "$(val "$C/res")" ERR-NOTREADY
      chk "$L $1 no reowned restored line" hasnot "$C/log" "[roamd] reowned restored"
      chk "$L $1 no relabelled line" hasnot "$C/log" "[roamd] relabelled"
      chk "$L $1 no restored+reowned line" hasnot "$C/log" "restored+reowned"
    }
    say "== $sh$LS ARM: the real odrestore arm =="
    newcase; armroot; armrun "$sh"
    chk "$L ARM healthy: the reply is OK <pkg>" eqv "$(val "$C/res")" "OK $PKG"
    chk "$L ARM healthy: the hold is removed" isnotdir "$HOLD"
    chk "$L ARM healthy: restored+reowned logged" has "$C/log" "restored+reowned"
    chk "$L ARM healthy: every dest entry chowned" same chown "$DST"

    newcase; armroot; echo "$DST/d2/f7" > "$C/fail.chown"
    armrun "$sh"
    ok_no_lies "ForcedFailure chown"
    chk "$L ForcedFailure chown: the hold is still there" isdir "$HOLD"
    chk "$L ForcedFailure chown: the WARN line" has "$C/log" "WARN odrestore $PKG ($AR/data/user/$UID_) hand-back FAILED -- hold KEPT"

    newcase; armroot; echo "$DST/d1/f3" > "$C/fail.chcon"
    armrun "$sh"
    ok_no_lies "ForcedFailure chcon"
    chk "$L ForcedFailure chcon: the hold is still there" isdir "$HOLD"
    chk "$L ForcedFailure chcon: the WARN line" has "$C/log" "hand-back FAILED -- hold KEPT"

    # a chown the batch cannot execute: it answers 126, the status an exec failure (E2BIG included) gives the batch.
    # Not a missing interpreter: that execve fails ENOENT, and bash and dash treat ENOENT as "not here" and go on down
    # PATH to the recording stub, which answers 0 -- the case then tested nothing (found on the box, round 68).
    newcase; armroot; printf '#!/bin/sh\nexit 126\n' > "$C/bin/chown"; chmod 755 "$C/bin/chown"
    armrun "$sh"
    ok_no_lies "ForcedFailure exec"
    chk "$L ForcedFailure exec: a chown that cannot be executed keeps the hold" isdir "$HOLD"

    newcase; armroot; : > "$C/findfail"
    armrun "$sh"
    ok_no_lies "ForcedFailure find"
    chk "$L ForcedFailure find: a find error keeps the hold" isdir "$HOLD"

    newcase; armroot; : > "$C/findfail.list"
    armrun "$sh"
    ok_no_lies "ForcedFailure listing"
    chk "$L ForcedFailure listing: a failed relabel listing keeps the hold" isdir "$HOLD"

    newcase; armroot; rm -rf "$HOLD"; k="$AR/data/media/$UID_/Android/data/$PKG"; mkdir -p "$k/f"; : > "$k/f/a"; : > "$k/f/b"
    echo "$k/f/b" > "$C/fail.restorecon"
    armrun "$sh"
    chk "$L ForcedFailure extdata: the reply is ERR-NOTREADY, not OK NOSRC" eqv "$(val "$C/res")" ERR-NOTREADY
    chk "$L ForcedFailure extdata: the WARN line" has "$C/log" "WARN odrestore $PKG Android/data hand-back FAILED"
    newcase; armroot; rm -rf "$HOLD"; k="$AR/data/media/$UID_/Android/data/$PKG"; mkdir -p "$k/f"; : > "$k/f/a"
    armrun "$sh"
    chk "$L ARM healthy extdata, no hold: the reply is OK NOSRC" eqv "$(val "$C/res")" "OK NOSRC"

    # an overlay mounted under Android/data/<pkg>: its root and every file under it refuse a relabel (ENOTSUP)
    newcase; armroot; k="$AR/data/media/$UID_/Android/data/$PKG"; mkdir -p "$k/files/Content Download/x" "$k/other"
    : > "$k/files/Content Download/x/a"; : > "$k/other/b"
    printf '%s\n' "40 1 0:40 / ${k// /\\040}/files/Content\\040Download rw,relatime - fuse.nowheremedia nowheremedia rw" > "$C/mountinfo"
    echo "$k/files/Content Download" > "$C/failunder.restorecon"
    armrun "$sh"
    chk "$L HealthyOverlayExtdata: the reply is OK <pkg>" eqv "$(val "$C/res")" "OK $PKG"
    chk "$L HealthyOverlayExtdata: no restorecon reached the overlay" eqv "$(tr '\0' '\n' < "$C/rec.restorecon" | grep -c 'Content Download')" 0
    chk "$L HealthyOverlayExtdata: the paths beside it were relabelled" eqv "$(tr '\0' '\n' < "$C/rec.restorecon" | grep -c '/other/b$')" 1

    # an external hold handed back onto a dest whose deferred dir is an overlay (od_relabel's walk, no -xdev)
    newcase; armroot; rm -rf "$HOLD"; k="$AR/data/media/$UID_/Android/data/$PKG"; HOLD="$AR/data/media/$UID_/Android/data/com.nowhere.chooser/.nowhere-odhold/$PKG"
    mkdir -p "$k/files/ov/n" "$HOLD/keep"; : > "$k/files/ov/n/a"; : > "$HOLD/keep/c"
    printf '%s\n' "41 1 0:41 / $k/files/ov rw,relatime - fuse.nowheremedia nowheremedia rw" > "$C/mountinfo"
    echo "$k/files/ov" > "$C/failunder.restorecon"
    armrun "$sh"
    chk "$L HealthyOverlayMedia: the reply is OK <pkg>" eqv "$(val "$C/res")" "OK $PKG"
    chk "$L HealthyOverlayMedia: the external hold is removed" isnotdir "$HOLD"
    chk "$L HealthyOverlayMedia: no restorecon reached the overlay" eqv "$(tr '\0' '\n' < "$C/rec.restorecon" | grep -c '/files/ov')" 0

    # FOREGROUND (the count file cannot be made): od_label_watched's pair runs uncounted, and its external relabel is the
    # same bounded, pruned walk, so a failed one there still keeps the hold, and a healthy one still prunes the overlay.
    # The hold is an Android/obb one, with no Android/data dir for the app.
    fgroot() {
      armroot; rm -rf "$HOLD"; k="$AR/data/media/$UID_/Android/obb/$PKG"
      HOLD="$AR/data/media/$UID_/Android/obb/com.nowhere.chooser/.nowhere-odhold/$PKG"
      mkdir -p "$k/ov/n" "$HOLD/keep"; : > "$k/ov/n/a"; : > "$HOLD/keep/c"
      printf '%s\n' "42 1 0:42 / $k/ov rw,relatime - fuse.nowheremedia nowheremedia rw" > "$C/mountinfo"
      echo "$k/ov" > "$C/failunder.restorecon"
    }
    newcase; fgroot; echo first > "$C/mktempfail"
    armrun "$sh"
    chk "$L ForegroundExt healthy: the reply is OK <pkg>" eqv "$(val "$C/res")" "OK $PKG"
    chk "$L ForegroundExt healthy: the hold is removed" isnotdir "$HOLD"
    chk "$L ForegroundExt healthy: the overlay is pruned" eqv "$(tr '\0' '\n' < "$C/rec.restorecon" | grep -c '/ov')" 0
    chk "$L ForegroundExt healthy: the dest dir is relabelled" eqv "$(tr '\0' '\n' < "$C/rec.restorecon" | grep -cxF "$k")" 1
    chk "$L ForegroundExt healthy: restored+reowned logged" has "$C/log" "restored+reowned"

    newcase; fgroot; echo first > "$C/mktempfail"; echo "$k" > "$C/fail.restorecon"
    armrun "$sh"
    ok_no_lies "ForegroundExt restorecon"
    chk "$L ForegroundExt restorecon: the hold is still there" isdir "$HOLD"
    chk "$L ForegroundExt restorecon: the WARN line" has "$C/log" "hand-back FAILED -- hold KEPT"

    newcase; fgroot; echo all > "$C/mktempfail"; echo "$k" > "$C/fail.restorecon"
    armrun "$sh"
    ok_no_lies "ForegroundExt nostatus"
    chk "$L ForegroundExt nostatus: no status file keeps the hold" isdir "$HOLD"

  done
  done

  [ -z "$HARN" ] || { echo "HARNESS ERROR:$HARN" >&2; return 2; }
  say "$p passed, $x failed"
  [ "$x" = 0 ]
}

s0=$(date +%s)
suite "$SUT"; rc=$?
echo "plain run: $(( $(date +%s) - s0 ))s"
[ "$rc" = 2 ] && exit 2
[ "$MUTATE" = yes ] || exit "$rc"

echo
echo "== mutations (each MUST be convicted under EACH shell's own line) =="
# xform <fn> <from> <to>: inside function <fn> only, every line exactly <from> becomes <to> (the token DEL drops it).
# fn ARM is the odrestore arm, from its case label to its ;;.
xform() {
  # ENVIRON, not -v: -v processes escapes, and an anchor ending in a line-continuation backslash never matched under the
  # build box's gawk 5.2 (round 68), so the control and every mutant on such an anchor read as moved or inert.
  XF_FN="$1() {" XF_FR="$2" XF_TO="$3" awk '
    BEGIN { FN = ENVIRON["XF_FN"]; FR = ENVIRON["XF_FR"]; TO = ENVIRON["XF_TO"] }
    FN == "ARM() {" && $0 == "  odrestore)" { fn = 1 }
    $0 == FN { fn = 1 }
    fn && $0 == FR { hit = 1; if (TO != "DEL") print TO; next }
    { print }
    fn && ($0 == "}" || $0 == "    ;;") { fn = 0 }
    END { exit !hit }
  ' "$SUT"
}
MF=0
VD=$(mktemp -d -p "$W") || exit 2
# mutate runs each mutant in the background (the suite takes about a minute a shell); its verdict lands in $VD/<id>,
# and the verdicts are read once every mutant has finished.
mutate() { mutate_one "$@" > "$VD/$1" 2>&1 & }
mutate_one() {  # mutate_one <id> <label> <convicting assertion> <fn> <from> <to> [<from2> <to2>]
  local id="$1" label="$2" by="$3" m m2 out mrc s miss=""
  m=$(mktemp -p "$W") || exit 2
  if ! xform "$4" "$5" "$6" > "$m" 2>/dev/null; then echo "  FAIL  MUTATION INERT (anchor never matched): $id $label"; MF=$((MF+1)); return; fi
  if [ "$#" -ge 8 ]; then
    m2=$(mktemp -p "$W") || exit 2
    SUT="$m" xform2 "$4" "$7" "$8" "$m" > "$m2" || { echo "  FAIL  MUTATION INERT (2nd anchor never matched): $id $label"; MF=$((MF+1)); return; }
    m=$m2
  fi
  if cmp -s "$SUT" "$m"; then echo "  FAIL  MUTATION INERT (nothing changed): $id $label"; MF=$((MF+1)); return; fi
  out=$(suite "$m" quiet 2>&1); mrc=$?
  if [ "$mrc" = 2 ]; then echo "  FAIL  INCONCLUSIVE (the harness could not run): $id $label"; printf '%s\n' "$out" | sed 's/^/          /' | head -5; MF=$((MF+1)); return; fi
  if [ "$mrc" = 0 ]; then echo "  FAIL  NOT CONVICTED: $id $label"; MF=$((MF+1)); return; fi
  for s in "${SHELLS[@]}"; do
    case "$out" in *"FAIL  [$s] $by"*) ;; *) miss="$miss $s" ;; esac
  done
  if [ -n "$miss" ]; then echo "  FAIL  NOT CONVICTED by $by under:$miss: $id $label"; MF=$((MF+1)); else echo "  ok    convicted by $by: $id $label"; fi
}
xform2() {  # the same transform on an already mutated file ($4)
  local f="$4"
  # ENVIRON, not -v: -v processes escapes, and an anchor ending in a line-continuation backslash never matched under the
  # build box's gawk 5.2 (round 68), so the control and every mutant on such an anchor read as moved or inert.
  XF_FN="$1() {" XF_FR="$2" XF_TO="$3" awk '
    BEGIN { FN = ENVIRON["XF_FN"]; FR = ENVIRON["XF_FR"]; TO = ENVIRON["XF_TO"] }
    FN == "ARM() {" && $0 == "  odrestore)" { fn = 1 }
    $0 == FN { fn = 1 }
    fn && $0 == FR { hit = 1; if (TO != "DEL") print TO; next }
    { print }
    fn && ($0 == "}" || $0 == "    ;;") { fn = 0 }
    END { exit !hit }
  ' "$f"
}
L_FIND='  { find "$root" "$@" -print0 2>>"$LOG"; echo "$?" > "$st"; } \'
L_XARGS=$(grep -m1 -F -- '    | xargs -0 -r -n 256 sh -c ' "$SUT")
L_STATUS='  if [ "$rc" = 0 ] && [ "$fs" = 0 ]; then return 0; fi'
L_PAIR='      if [ "$r" != 2 ]; then od_relabel "$vol" "$dst"; r=$?; fi'
L_ARMCHK='          if [ "$?" = 2 ]; then'
L_PRUNE='  if [ "$pr" = prune ]; then'
L_FGREL='      od_walk prune 1 restorecon "$2" \'
[ -n "$L_XARGS" ] || { echo "  FAIL  the xargs line of od_walk was not found"; exit 1; }
BATCH=${L_XARGS#*sh -c \'}; BATCH=${BATCH%%\' od_walk *}
# The control: replacing a line with itself must reproduce roamd byte for byte.
c=$(mktemp -p "$W") || exit 2
if ! xform od_walk "$L_FIND" "$L_FIND" > "$c" || ! cmp -s "$SUT" "$c"; then
  echo "  FAIL  the transform does not reproduce $SUT (the anchors moved)"; MF=$((MF+1))
fi
mutate M1 "the bound removed: back to one find -exec sh -c ... {} +" "BigHoldReown reown_restored chowns" od_walk "$L_FIND" \
  "  find \"\$root\" \"\$@\" -exec sh -c '$BATCH' od_walk \"\$k\" \"\$a\" \"\$b\" \"\$c\" {} + 2>>\"\$LOG\"; echo \"\$?\" > \"\$st\"" \
  "$L_XARGS" "  true"
mutate M2 "the walk's status is not checked" "ForcedFailure chown the reply is ERR-NOTREADY" od_walk "$L_STATUS" '  return 0'
mutate M3 "the count echo dropped" "StallCount reown" od_walk "$L_XARGS" \
  "${L_XARGS/'[ -z "${OD_LABEL_COUNT:-}" ] || echo "$#" >> "$OD_LABEL_COUNT"; '/}"
mutate M4 "od_label_watched returns od_relabel's status only" "ForcedFailure chown the reply is ERR-NOTREADY" od_label_watched "$L_PAIR" \
  '      od_relabel "$vol" "$dst"; r=$?'
mutate M5 "the arm drops the hold despite a failed hand-back" "ForcedFailure chown: the hold is still there" ARM "$L_ARMCHK" '          if false; then'
mutate M6 "find's own error ignored" "ForcedFailure find the reply is ERR-NOTREADY" od_walk "$L_STATUS" '  if [ "$rc" = 0 ]; then return 0; fi'
mutate M7 "the external walks prune no mountpoint" "HealthyOverlayExtdata: the reply is OK" od_walk "$L_PRUNE" '  if false; then'
mutate M8 "the foreground external relabel is the plain restorecon -R again" "ForegroundExt restorecon the reply is ERR-NOTREADY" \
  od_relabel "$L_FGREL" '      [ -n "${OD_LABEL_COUNT:-}" ] || { restorecon -R "$2" 2>>"$LOG"; return $?; }; od_walk prune 1 restorecon "$2" \'

wait
for v in "$VD"/*; do cat "$v"; done
MF=$((MF + $(cat "$VD"/* | grep -c '^  FAIL ')))
echo
echo "mutants failed: $MF ($(( $(date +%s) - s0 ))s in all)"
[ "$rc" = 0 ] && [ "$MF" = 0 ]
