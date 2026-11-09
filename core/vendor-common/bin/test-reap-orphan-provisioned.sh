#!/usr/bin/env bash
# test-reap-orphan-provisioned.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's cross-profile reap at roam-in,
# reap_orphan_provisioned, and the #647 guard that keeps it off another profile's apps (NWP-20261011-07).
#
# WHY THIS IS COMMITTED. reap_orphan_provisioned runs at every roam-in, on every `installer=com.nowhere.chooser`
# package outside this profile's keep-set, and its reap with no other user is `pm uninstall` with no --user --
# USER_ALL. A FRESH profile's keep-set is
# empty by construction (no manifest, no nowhere-apps.list, no nowhere-appkeep), and `pm list packages -a -i` also
# lists packages that are installed only for ANOTHER user. On lynx, 2026-08-11 (DIA-20260811-07), a fresh profile's
# sign-in therefore uninstalled another profile's Play Store and YouTube device-wide, with nothing left to restore
# them from. The #647 guard (skip a package installed only for users that are neither 0 nor the roaming user) is the
# one thing between that keep-set and the next profile's apps -- and nothing could FAIL when it regressed: on a
# device "the guard held" and "there was nothing to reap" look the same (docs/backlog.md #98 / #99). This suite runs
# the real function against stubbed pm/dumpsys and asserts the exact uninstall set and the log line of every branch:
# the three keep-set sources, the whole-line keep match, the malformed-name skip, the /data/app codePath gate, the
# user-0 / roaming-user / no-user arms of the reap verdict, the guard, and the installer filter. Since NWP-20261129-11
# (decided 2026-11-05, h59 #12) it also pins the mixed case: a package installed for user 0 or the roaming user AND
# for another user is uninstalled --user 0 and --user <ruid> only, so that the other user's copy and data stay.
#
# The function is extracted from nowhere_roamd.sh BY ANCHOR, never copied, and the extraction is asserted (exit 2 if
# it is empty or truncated), so a stale copy cannot keep passing after the real code moves. pm, dumpsys and timeout
# are stubbed as shell functions that RECORD to a temp dir; everything else it calls (cut, grep, sed, head, date)
# runs for real. roamd's shebang is /system/bin/sh, so every case runs in its own process under bash, sh, and
# dash/mksh when the host has them.
#
# ⚠ NO `cmd | grep -q` ANYWHERE IN THIS FILE: under pipefail an early-exiting grep -q makes the writer die of SIGPIPE
# (141) and the pipeline FAIL although grep matched (test-sync-vpn-roam.sh). Match against a here-string instead.
#
#   bash test-reap-orphan-provisioned.sh            # the cases
#   bash test-reap-orphan-provisioned.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

has() {  # has <fixed text> <haystack> -- no pipe, so no SIGPIPE under pipefail
  grep -qF -- "$1" <<<"$2"
}

# --- extraction: fail CLOSED. An empty or truncated function would make every "nothing uninstalled" case pass. ----
# Only its SHAPE is asserted here; what its branches do is the cases' job, so a roamd copy with the guard deleted
# reports FAIL e, not an extraction error.
TMP=$(mktemp -d); trap 'command rm -rf "$TMP"' EXIT
FN="$TMP/fn.sh"
sed -n '/^reap_orphan_provisioned() {$/,/^}$/p' "$SUT" > "$FN"
FNTEXT=$(cat "$FN")
if [ -z "$FNTEXT" ] || [ "$(head -1 "$FN")" != 'reap_orphan_provisioned() {' ] || [ "$(tail -1 "$FN")" != '}' ] \
   || ! has 'pm list packages -a -i' "$FNTEXT" || ! has 'pm uninstall' "$FNTEXT"; then
  echo "EXTRACTION FAILED -- reap_orphan_provisioned moved or changed shape in $SUT" >&2
  exit 2
fi

echo "reap_orphan_provisioned: $SUT"
SHELLS=""
for s in bash sh dash mksh; do
  if command -v "$s" >/dev/null 2>&1; then SHELLS="$SHELLS $s"
  elif [ "$s" = bash ]; then echo "bash is required" >&2; exit 2
  else echo "$s: absent on this host (skipped)"
  fi
done
SHELLS="${SHELLS# }"

# --- the stubs, POSIX only (they run under dash) ----------------------------------------------------------------
# pm: `list packages -a -i` answers $D/pmlist; `uninstall <pkg>` and `uninstall --user <n> <pkg>` append exactly that
# line to $D/calls (roamd sends pm's stdout to /dev/null, so the record goes to a file) and read their stdin to the
# end, as a call with no </dev/null would eat the rest of the function's package list. dumpsys: `package <pkg>` answers $D/dumpsys/<pkg> with
# `/` mapped to `_`; absent -> nothing. timeout: drops `-k 5 30`. Any other argv is recorded in $D/unexpected.
STUBS=$(cat <<'EOS'
pm() {
  if [ "$*" = "list packages -a -i" ]; then cat "$D/pmlist"
  elif [ "$1" = uninstall ] && [ $# = 2 ]; then cat >/dev/null; echo "uninstall $2" >> "$D/calls"
  elif [ "$1" = uninstall ] && [ "$2" = --user ] && [ $# = 4 ]; then cat >/dev/null; echo "uninstall --user $3 $4" >> "$D/calls"
  else echo "pm $*" >> "$D/unexpected"; return 1
  fi
}
dumpsys() {
  if [ "$1" = package ] && [ $# = 2 ]; then cat "$D/dumpsys/$(printf '%s' "$2" | tr / _)" 2>/dev/null; return 0; fi
  echo "dumpsys $*" >> "$D/unexpected"; return 1
}
timeout() {
  if [ "$1 $2 $3" = "-k 5 30" ]; then shift 3; "$@"; else echo "timeout $*" >> "$D/unexpected"; return 1; fi
}
EOS
)

# --- fixture builders (bash side; $D is the current case's dir) --------------------------------------------------
KEEPDIR=user/com.nowhere.chooser/files
fx_pm() { printf 'package:%s  installer=%s\n' "$1" "$2" >> "$D/pmlist"; }   # <pkg> <installer>
fx_dump() {  # <pkg> <codePath> [N:true|N:false ...]
  local p="$1" cp="$2" f u; shift 2
  f="$D/dumpsys/${p//\//_}"
  { printf 'Packages:\n  Package [%s] (1a2b3c):\n    userId=10123\n    codePath=%s\n    resourcePath=%s\n' "$p" "$cp" "$cp"
    for u in "$@"; do
      printf '    User %s: ceDataInode=1 installed=%s hidden=false suspended=false distractionFlags=0 stopped=false\n' "${u%%:*}" "${u#*:}"
    done; } > "$f"
}
fx_manifest() { printf '%s\tv1\tabc123\n' "$1" >> "$D/manifest.tsv"; }
fx_apps_list() { printf '%s\n' "$1" >> "$D/$KEEPDIR/nowhere-apps.list"; }
fx_appkeep() { printf '%s\t1\t2026-10-11\n' "$1" >> "$D/$KEEPDIR/nowhere-appkeep"; }
dapp() { printf '/data/app/~~x/%s-y' "$1"; }
# reapable <pkg> [users...] -- a chooser-installed /data/app package; with no user args, installed for user 0.
reapable() { local p="$1"; shift; fx_pm "$p" com.nowhere.chooser; fx_dump "$p" "$(dapp "$p")" "${@:-0:true}"; }

RUID=11
CTRL=com.example.leak   # a user-0 leftover every case carries, so "nothing uninstalled" can never pass vacuously

# run <shell> <fn-file>: run the function once in a fresh process. Sets OUTRC, CALLS, LOGTXT, UNEXP.
run() {
  local sh="$1" fn="$2"
  { printf 'D=%s\nLOG=$D/log\nUSERDIR=$D/user\n' "'$D'"
    printf '%s\n' "$STUBS"
    cat "$fn"
    printf 'reap_orphan_provisioned "$D/manifest.tsv" %s\n' "$RUID"
  } > "$D/run.sh"
  "$sh" "$D/run.sh" > "$D/out" 2>&1; OUTRC=$?
  CALLS=$(cat "$D/calls" 2>/dev/null); LOGTXT=$(cat "$D/log" 2>/dev/null); UNEXP=$(cat "$D/unexpected" 2>/dev/null)
}

# suite <fn-file> [quiet] -> 0 iff every case behaved under every shell. Own counters, never touches globals.
suite() {
  local fn="$1" quiet="${2:-}" p=0 x=0 sh c lbl ctrl D OUTRC CALLS LOGTXT UNEXP gl
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }

  # Android's grep and sed (toybox) have none of GNU's BRE extensions -- `\|`, `\+`, `\?` -- and a GNU runner
  # accepts them, so no case can see it. Lint the extracted code instead (comments excluded).
  gl=$(grep -E '(grep|sed) ' "$fn"); gl=$(grep -v '^ *#' <<<"$gl")
  if grep -qF -e '\|' -e '\+' -e '\?' <<<"$gl"; then no "a grep or sed uses a GNU-only BRE escape"
  else ok "no grep or sed uses a GNU-only BRE escape"; fi

  # expect <want-calls> -- the exact uninstall set, the shell's exit, and no unexpected stub call
  expect() {
    if [ "$OUTRC" = 0 ] && [ -z "$UNEXP" ] && [ "$CALLS" = "$1" ]; then return 0; fi
    no "$lbl: calls=[${CALLS//$'\n'/; }] want [${1//$'\n'/; }] rc=$OUTRC unexpected=[$UNEXP] out=[$(tr '\n' ' ' < "$D/out")]"
    return 1
  }
  # logs <fixed text> / nolog <pkg> -- a log line is (or no log line about <pkg> is) present
  logs() { has "$1" "$LOGTXT" && return 0; no "$lbl: log lacks [$1]; log=[${LOGTXT//$'\n'/ | }]"; return 1; }
  nolog() { has " $1 " "$LOGTXT" || return 0; no "$lbl: log names $1 although it must be left alone; log=[${LOGTXT//$'\n'/ | }]"; return 1; }
  # the control's uninstall line, last in every case's pmlist
  ctrl="uninstall $CTRL"

  for sh in $SHELLS; do
    for c in a b c d e f g h i j k l m n o; do
      D=$(mktemp -d -p "$TMP"); mkdir -p "$D/dumpsys" "$D/$KEEPDIR"
      case "$c" in
        a) lbl="a [$sh] a package in the keep-installed manifest is kept"
           reapable com.example.kept; fx_manifest com.example.kept; fx_manifest com.example.other ;;
        b) lbl="b [$sh] a package only in nowhere-apps.list is kept"
           reapable com.example.vpn; fx_apps_list com.example.other; fx_apps_list com.example.vpn ;;
        c) lbl="c [$sh] a package only in nowhere-appkeep (field 1 of a tab-separated line) is kept"
           reapable com.example.appkeep; fx_appkeep com.example.appkeep ;;
        d) lbl="d [$sh] a codePath under /product is never targeted"
           fx_pm com.example.bundled com.nowhere.chooser
           fx_dump com.example.bundled /product/app/Bundled 0:true ;;
        e) lbl="e [$sh] DIA-20260811-07: a FRESH profile (empty keep-set) leaves another profile's apps alone"
           reapable com.google.android.youtube 0:false 12:true
           reapable com.android.vending 12:true ;;
        f) lbl="f [$sh] a user-0 install is a leak and is reaped"
           reapable com.example.user0 0:true 12:false ;;
        g) lbl="g [$sh] an install for the roaming user outside its keep-set is reaped"
           reapable com.example.mine 0:false 11:true ;;
        h) lbl="h [$sh] a dangling record (installed for nobody) is reaped"
           fx_pm com.example.dangling com.nowhere.chooser; fx_dump com.example.dangling "$(dapp com.example.dangling)" ;;
        i) lbl="i [$sh] h59 #12: installed for user 0 AND another profile: only user 0's copy goes"
           reapable com.example.both 0:true 12:true ;;
        j) lbl="j [$sh] a package another installer put there is never touched"
           fx_pm com.example.store null; fx_dump com.example.store "$(dapp com.example.store)" 0:true ;;
        k) lbl="k [$sh] the keep-set match is whole-line: com.foo.bar kept does not keep com.foo"
           reapable com.foo; reapable com.foo.bar; fx_apps_list com.foo.bar ;;
        l) lbl="l [$sh] a malformed package name is never passed to pm"
           reapable com.example/evil ;;
        m) lbl="m [$sh] h59 #12: installed for the roaming user AND another profile: only the roaming user's copy goes"
           reapable com.example.mine2 11:true 12:true ;;
        n) lbl="n [$sh] h59 #12: user 0, the roaming user AND another profile: two per-user calls, user 0 first"
           reapable com.example.all 0:true 11:true 12:true ;;
        o) lbl="o [$sh] h59 #12: two other profiles: both kept, named on one log line"
           reapable com.example.two 0:true 12:true 13:true ;;
      esac
      reapable "$CTRL"
      run "$sh" "$fn"
      case "$c" in
        a) expect "$ctrl" && nolog com.example.kept && ok "$lbl" ;;
        b) expect "$ctrl" && nolog com.example.vpn && ok "$lbl" ;;
        c) expect "$ctrl" && nolog com.example.appkeep && ok "$lbl" ;;
        d) expect "$ctrl" && nolog com.example.bundled && ok "$lbl" ;;
        e) expect "$ctrl" \
             && logs "reap-orphan-provisioned SKIP com.google.android.youtube -- installed for user(s) 12, none of them user 0 or $RUID" \
             && logs "reap-orphan-provisioned SKIP com.android.vending -- installed for user(s) 12, none of them user 0 or $RUID" \
             && ok "$lbl" ;;
        f) expect "uninstall com.example.user0"$'\n'"$ctrl" \
             && logs "reap-orphan-provisioned com.example.user0 (rc=0) installed=[0]" && ok "$lbl" ;;
        g) expect "uninstall com.example.mine"$'\n'"$ctrl" \
             && logs "reap-orphan-provisioned com.example.mine (rc=0) installed=[$RUID]" && ok "$lbl" ;;
        h) expect "uninstall com.example.dangling"$'\n'"$ctrl" \
             && logs "reap-orphan-provisioned com.example.dangling (rc=0) installed=[none]" && ok "$lbl" ;;
        i) expect "uninstall --user 0 com.example.both"$'\n'"$ctrl" \
             && logs "reap-orphan-provisioned com.example.both --user 0 (rc=0) kept for user(s) 12 " && ok "$lbl" ;;
        j) expect "$ctrl" && nolog com.example.store && ok "$lbl" ;;
        k) expect "uninstall com.foo"$'\n'"$ctrl" \
             && logs "reap-orphan-provisioned com.foo (rc=0)" && nolog com.foo.bar && ok "$lbl" ;;
        l) expect "$ctrl" && nolog com.example/evil && ok "$lbl" ;;
        m) expect "uninstall --user $RUID com.example.mine2"$'\n'"$ctrl" \
             && logs "reap-orphan-provisioned com.example.mine2 --user $RUID (rc=0) kept for user(s) 12 " && ok "$lbl" ;;
        n) expect "uninstall --user 0 com.example.all"$'\n'"uninstall --user $RUID com.example.all"$'\n'"$ctrl" \
             && logs "reap-orphan-provisioned com.example.all --user 0 (rc=0) kept for user(s) 12 " \
             && logs "reap-orphan-provisioned com.example.all --user $RUID (rc=0) kept for user(s) 12 " && ok "$lbl" ;;
        o) expect "uninstall --user 0 com.example.two"$'\n'"$ctrl" \
             && logs "reap-orphan-provisioned com.example.two --user 0 (rc=0) kept for user(s) 12 13 " && ok "$lbl" ;;
      esac
      command rm -rf "$D"
    done
  done
  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "shells: $SHELLS (sh -> $(readlink -f "$(command -v sh)"))"
suite "$FN"; rc=$?
[ "$rc" = 0 ] || FAILED=1

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations of the extracted function (each must CONVICT):"
  mutate() {  # <label> <sed program>
    local label="$1" prog="$2" mf="$TMP/mutant.sh" r s
    if ! sed "$prog" "$FN" > "$mf"; then printf '  ERR   %-62s sed program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$FN" "$mf"; then printf '  SKIP  %-62s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    for s in $SHELLS; do
      "$s" -n "$mf" 2>/dev/null || { printf '  ERR   %-62s mutant does not parse under %s\n' "$label" "$s"; MFAIL=1; return; }
    done
    for s in $SHELLS; do
      ( SHELLS="$s"; suite "$mf" quiet >/dev/null 2>&1 ); r=$?
      case "$r" in
        0) printf '  XX    %-62s SURVIVED under %s\n' "$label" "$s"; MFAIL=1 ;;
        1) printf '  ok    %-62s CONVICTED under %s\n' "$label" "$s" ;;
        *) printf '  ERR   %-62s harness error under %s (rc=%s), not a conviction\n' "$label" "$s" "$r"; MFAIL=1 ;;
      esac
    done
  }
  # m1 deletes the four-line #647 guard (if / echo SKIP / continue / fi): the first `    fi` after its `if` is its own.
  mutate 'm1 the #647 guard is gone (DIA-20260811-07 again)'      '/^    if \[ "\$reap" != 1 \]; then$/,/^    fi$/d'
  mutate 'm2 a user-0 install no longer counts as a leak'          's/\[ "\$u" = 0 \]/[ "$u" = 99 ]/'
  mutate 'm3 the keep-set is ignored'                              '/grep -qxF "\$p" && continue/d'
  mutate 'm4 every codePath is reap-eligible'                      's@case "\$cp" in /data/app/\*) ;;@case "$cp" in *) ;;@'
  mutate 'm5 the keep-set match is a substring match'              's/grep -qxF/grep -qF/'
  mutate 'm6 malformed package names reach pm'                     's@case "\$p" in ""|\*/\*|\*" "\*) continue;; esac@case "$p" in "") continue;; esac@'
  mutate 'm7 the mixed case is back to USER_ALL'                   's/^    if \[ -n "\$_others" \]; then$/    if false; then/'
  mutate 'm8 the --user 0 call is dropped'                         '/pm uninstall --user 0 /d'
  mutate 'm9 the --user "$ruid" call is dropped'                   '/pm uninstall --user "\$ruid" /d'
  mutate 'm10 _others counts user 0 too (f becomes per-user)'      's/^      if \[ "\$u" = 0 \]; then _in0=1$/      if [ "$u" = 0 ]; then _in0=1; _others="${_others:+$_others }$u"/'
  mutate 'm11 the two per-user calls swap order'                   '/^      if \[ "\$_in0" = 1 \]; then$/,/^      fi$/{H;d;};/^      if \[ "\$_inr" = 1 \]; then$/,/^      fi$/{/^      fi$/{G;s/\n\n/\n/;};}'
  mutate 'm12 the --user 0 call loses its stdin redirect'          '/pm uninstall --user 0 /s@ </dev/null@@'
  mutate 'm13 the --user "$ruid" call loses its stdin redirect'    '/pm uninstall --user "\$ruid" /s@ </dev/null@@'
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; FAILED=1; }
fi

exit "${FAILED:-0}"
