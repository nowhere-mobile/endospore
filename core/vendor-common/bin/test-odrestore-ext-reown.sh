#!/usr/bin/env bash
# test-odrestore-ext-reown.sh [<nowhere_roamd.sh>] [--mutate] -- the `odrestore)` arm hands a materialised or
# Play-reinstalled app its EXTERNAL app-data back on EVERY path (NWP-20261020-15).
#
# WHY THIS IS COMMITTED. The last step of the arm is `reown_ext_appdata "$pkg"; restorecon -R -D
# /data/media/$uid/Android/data/$pkg`, commented "Independent of $odsrc". It is the only step that gives a
# tap-materialised app, or one Play reinstalled mid-session, its Android/data dir (blanket media_rw'd by remap_tree at
# sign-in, before the on-demand appId existed). A hold-less Play reinstall -- the install-heal's common case, reply
# OK NOSRC -- depends on it. Move it under the hold branch or drop -D and the app's own files are unreadable until
# the next sign-in (the Unity-class "not enough storage" EACCES, #492/#497) with no test failing: test-od-hold-merge.sh
# extracts only hold_ondemand and the reply block, test-od-relabel.sh od_relabel, test-install-heal.sh the receiver.
# So this suite EXECUTES the arm and asserts which helpers it called, with what argv, and in what order.
#
# Since NWP-20261022-05 it also pins the DECLINES argument the arm passes grant_perms_for (cases E6-E10): 1 for a
# first install this session -- a hold, or the package listed as a whole line of the chooser's
# nowhere-od-materialised -- and 0 otherwise.
#
# Since NWP-20261108-18 case E11 pins the accessibility re-apply: the arm calls `a11y_apply <uid> <pkg>` once, after
# grant_perms_for.
#
# Since NWP-20261111-22 cases E12-E13 pin the CE/DE hold check's appId lookup: it reads packages.list by exact package
# name, so a look-alike listed first (or alone) never decides whether the hold is handed back.
#
# Since NWP-20261112-12 case E14 pins the autofill re-apply: the arm calls `autofill_apply <uid> <pkg>` once, after
# `a11y_apply <uid> <pkg>` (E12-E13 were taken by NWP-20261111-22).
#
# Since NWP-20261122-03 cases E15-E17 pin the arm's one filtered pm read: an app with code (listed without -a) gets
# `keystore_register <pkg> <ns>`, the namespace from that read; an archived placeholder (listed only with -a) gets no
# grant_perms_for, a11y_apply, autofill_apply or keystore_register call, and the same reply and external re-own as
# before. `pm` answers `list packages -U` from sim/pm-U and `list packages -U -a` from sim/pm-Ua; mkroot plants the
# package's line in both, so E1-E14 read an app with code, as they did before the read existed.
#
# Since NWP-20261128-42 cases P1-P3 pin the package check: the arm calls pkgname_ok (extracted by name, beside the
# arm), so `..`, `.`, `a..b` and `1a.b` answer ERR-PKG before the hold probe, with no helper call, no `pm` call and no
# copy. P1 plants another app's external hold: with the old slash/space filter, `..` joined the chooser's own
# Android/data dir to /data/media/<uid>/Android in the recursive copy, and the arm force-stopped `..` first.
#
# Since NWP-20261112-33 the arm runs under EVERY shell found (bash, sh, dash, mksh -- an `sh` that is one of the
# others is skipped), not inside a bash `eval`: each case writes a runner file holding its variables, the ODHOLD=
# line, the recorder stubs and `case "$op" in <the arm> esac`, and runs it with `"$sh"`, after `"$sh" -n` has parsed
# it. The device runs odrestore under mksh, which evaluates a non-number in `[ "$odkept" -gt 0 ]` arithmetically (an
# unset identifier as 0, silently) where bash and dash error, so a mutant convicts only with a FAIL line under each
# shell's own tag; the last mutant leaves odkept non-numeric on the not-app-owned path.
#
#   bash test-odrestore-ext-reown.sh              # the cases, under each shell found
#   bash test-odrestore-ext-reown.sh --mutate     # ... plus mutants of roamd that must each CONVICT under each shell
#
# Pure logic -- no device. The arm is EXTRACTED by anchor, never copied, and re-rooted to a temp tree; every helper
# is a stub that records its argv; cp/rm/mkdir are real against the temp tree; `stat -c %u` answers a planted table.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every case root and mutant copy is made inside W, so a run that passes, fails or convicts leaves nothing behind.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# bash, dash and mksh each run under their own name whenever found; only an `sh` that is the same binary as one of
# them is skipped, so it can never stand in for (or suppress) a named shell.
SHELLS=(); named=" "
for s in bash dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  named="$named$(readlink -f "$p") "
done
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  if [ "$s" = sh ]; then
    case "$named" in *" $(readlink -f "$p") "*) continue ;; esac
  fi
  SHELLS+=("$s")
done
[ "${#SHELLS[@]}" -gt 0 ] || { echo "no shell found" >&2; exit 2; }
echo "shells: ${SHELLS[*]}"
# bash and dash have no `print`; mksh's own is kept. The arm prints nothing today; the shim keeps a runner honest if
# it ever does.
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then command printf "%s\n" "$*"; else command printf "%s" "$*"; fi; }'

PKG=com.example.game
UID_=11
APPID=10234
OWNED=$((UID_ * 100000 + APPID))
# A look-alike that the regex "^$PKG " matches ('.' matches 'x'), for E12-E13.
LA=com.examplexgame
LA_APPID=10999
LA_OWNED=$((UID_ * 100000 + LA_APPID))

arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
reroot() { printf '%s\n' "$1" | sed -E 's#([" |])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> <sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" sh="$2" quiet="${3:-}" p=0 x=0 ARM RA n R ODH PKGOK d
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  # a FAIL line prints even when quiet: it is the mutant runner's evidence, per shell
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    [$sh] $l"; else x=$((x+1)); printf '  FAIL  [%s] %s\n' "$sh" "$l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  has() { grep -qxF -- "$2" "$1"; }
  lineno() { grep -nxF -- "$2" "$1" | head -1 | cut -d: -f1; }
  before() {  # before <calls> <a> <b>: both present, a first
    local a b; a=$(lineno "$1" "$2"); b=$(lineno "$1" "$3")
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
  }

  ARM=$(arm_of "$f" odrestore)
  ODH=$(grep -m1 -E '^ODHOLD=' "$f")
  case "$ARM" in *'echo "ERR-PKG" > "$RES"'*'echo "OK NOSRC" > "$RES"'*'echo "ERR-NOTREADY" > "$RES"'*) ;; *) echo "EXTRACTION FAILED: the odrestore arm in $f" >&2; return 2 ;; esac
  [ -n "$ODH" ] || { echo "EXTRACTION FAILED: ODHOLD= not found in $f" >&2; return 2; }
  PKGOK=$(awk -v a='pkgname_ok() {' '$0 == a {f=1} f{print} f&&/^}$/{exit}' "$f")
  case "$PKGOK" in *'return 1'*'return 0'*) ;; *) echo "EXTRACTION FAILED: pkgname_ok in $f" >&2; return 2 ;; esac
  RA=$(reroot "$ARM")
  n=$(printf '%s\n' "$RA" | grep -o '\$ROOT/data/' | grep -c .)
  [ "$n" -ge 8 ] || { echo "RE-ROOT FAILED: the odrestore arm has $n rewritten paths, want >= 8" >&2; return 2; }
  n=$(nleft "$RA")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: the odrestore arm keeps $n absolute /data path(s) in live code" >&2; return 2; }

  # runner <root> <pkg>: write <root>/run.sh, the REAL odrestore arm with every helper a recorder, for "$sh" to run.
  # No `set -u`: roamd runs without it, and under it mksh would stop on the unset identifier a non-numeric mutant
  # leaves in `[ "$odkept" -gt 0 ]` instead of reading it as 0, as the device does.
  runner() {
    local t
    { printf '%s\n' "$PRINT_SHIM"
      printf "%s='%s'\n" ROOT "$1" uid "$UID_" PKG "$PKG" op odrestore srcunit "$2" LOG "$1/roam.log" RES "$1/res" \
        ACCT_AUTH_PKG com.example.authenticator STATE "$1/state" C "$1/sim/calls"
      printf '%s\n' 'USERDIR="$ROOT/data/user/$uid"' "$ODH" "$PKGOK"
      for t in am pidof pkg_live_pids reown_restored od_relabel grant_perms_for keystore_register reown_ext_appdata restorecon \
               wait_acct_authenticator acct_reload sync_apply a11y_apply autofill_apply; do
        printf '%s() { echo "%s $*" >> "$C"; }\n' "$t" "$t"
      done
      printf '%s\n' 'vpn_preconsent_off() { :; }'
      cat <<'STUBS'
# the hold's state at the instant of the external re-own: the order assertion for case 4
reown_ext_appdata() {
  echo "reown_ext_appdata $*" >> "$C"
  [ -d "$ROOT/data/media/$uid/Android/data/com.nowhere.chooser/$ODHOLD/$PKG" ] && echo held > "$ROOT/sim/ext-at-reown" || echo gone > "$ROOT/sim/ext-at-reown"
}
cutoff_prog() { :; }
od_fetch_data() { return 0; }; od_listed() { return 1; }; od_block_app() { return 0; }; od_unblock_app() { :; }; od_pending_clear() { :; }; od_block_installed() { :; }; od_shipped_prep() { return 0; }; od_park_var() { :; }; od_unf_path() { echo "$STATE/odfetch.$1/unfetched.$2"; }   # NWP-20261130-03
od_watched() { shift; "$@" 2>&1; }
pm() {
  echo "pm $*" >> "$ROOT/sim/pm-calls"
  case "$*" in
    "list packages -U -a "*) cat "$ROOT/sim/pm-Ua" 2>/dev/null ;;
    "list packages -U "*) cat "$ROOT/sim/pm-U" 2>/dev/null ;;
  esac
  return 0
}
stat() { awk -v p="$3" '$1 == p {print $2; f=1} END{exit !f}' "$ROOT/sim/owners"; }
STUBS
      printf 'case "$op" in\n%s\nesac\n' "$RA"
    } > "$1/run.sh"
  }
  # the shell under test parses the runner every case runs before any case runs it
  d=$(mktemp -d -p "$W") || return 2
  mkdir -p "$d/sim"; runner "$d" "$PKG"
  "$sh" -n "$d/run.sh" 2>/dev/null || { echo "PARSE FAILED: the odrestore runner under $sh" >&2; return 2; }

  HARN=""
  harness_check() {
    local e
    e=$(grep -m1 -iE 'command not found|unbound variable|syntax error|bad substitution|not found' "$1/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$sh: $e]"
  }
  # run_od <sh> <root> <pkg>: the runner under the shell named
  run_od() {
    runner "$2" "$3"
    "$1" "$2/run.sh" >/dev/null 2>>"$2/sim/stderr"
    harness_check "$2"
  }
  mkroot() {
    R=$(mktemp -d -p "$W") || exit 2
    mkdir -p "$R/sim" "$R/state" "$R/data/system" "$R/data/nowhere" "$R/data/user/$UID_" "$R/data/user_de/$UID_" \
             "$R/data/media/$UID_/Android/data" "$R/data/media/$UID_/Android/obb"
    : > "$R/sim/calls"; : > "$R/sim/owners"
    echo "package:$PKG uid:$OWNED" > "$R/sim/pm-U"; echo "package:$PKG uid:$OWNED" > "$R/sim/pm-Ua"
    echo "$PKG $APPID 0 /data/user/0/$PKG default:targetSdkVersion=34 none 0 1 1234" > "$R/data/system/packages.list"
  }
  plant_hold() {  # plant_hold <root> <volume> : a hold with one file under the chooser pkg dir
    mkdir -p "$1/data/$2/com.nowhere.chooser/.nowhere-odhold/$PKG"
    echo payload > "$1/data/$2/com.nowhere.chooser/.nowhere-odhold/$PKG/f.txt"
  }
  A="reown_ext_appdata $PKG"

  say "== [$sh] E1: no hold on any volume -> OK NOSRC, external re-own still runs =="
  mkroot; D="$R/data/media/$UID_/Android/data/$PKG"
  run_od "$sh" "$R" "$PKG"
  chk "E1 the reply is OK NOSRC" eqv "$(cat "$R/res" 2>/dev/null)" "OK NOSRC"
  chk "E1 reown_ext_appdata <pkg> ran" has "$R/sim/calls" "$A"
  chk "E1 restorecon -R -D <ext data dir> ran" has "$R/sim/calls" "restorecon -R -D $D"
  chk "E1 re-own before relabel" before "$R/sim/calls" "$A" "restorecon -R -D $D"
  chk "E1 no force-stop without a hold" eqv "$(grep -c '^am ' "$R/sim/calls")" 0

  say "== [$sh] E2: a CE hold onto an app-owned dest -> OK <pkg>, data copied =="
  mkroot; D="$R/data/media/$UID_/Android/data/$PKG"
  plant_hold "$R" "user/$UID_"; mkdir -p "$R/data/user/$UID_/$PKG"
  echo "$R/data/user/$UID_/$PKG $OWNED" > "$R/sim/owners"
  run_od "$sh" "$R" "$PKG"
  chk "E2 the reply is OK $PKG" eqv "$(cat "$R/res" 2>/dev/null)" "OK $PKG"
  chk "E2 the held file landed in the dest" eqv "$(cat "$R/data/user/$UID_/$PKG/f.txt" 2>/dev/null)" payload
  chk "E2 the hold was consumed" eqv "$([ -d "$R/data/user/$UID_/com.nowhere.chooser/.nowhere-odhold/$PKG" ] && echo kept || echo gone)" gone
  chk "E2 reown_ext_appdata <pkg> ran" has "$R/sim/calls" "$A"
  chk "E2 restorecon -R -D <ext data dir> ran" has "$R/sim/calls" "restorecon -R -D $D"
  chk "E2 re-own before relabel" before "$R/sim/calls" "$A" "restorecon -R -D $D"

  say "== [$sh] E3: a CE hold onto a dest that is not app-owned -> ERR-NOTREADY, hold kept, re-own still runs =="
  mkroot; D="$R/data/media/$UID_/Android/data/$PKG"
  plant_hold "$R" "user/$UID_"; mkdir -p "$R/data/user/$UID_/$PKG"
  echo "$R/data/user/$UID_/$PKG 0" > "$R/sim/owners"
  run_od "$sh" "$R" "$PKG"
  chk "E3 the reply is ERR-NOTREADY" eqv "$(cat "$R/res" 2>/dev/null)" ERR-NOTREADY
  chk "E3 the hold is kept" eqv "$(cat "$R/data/user/$UID_/com.nowhere.chooser/.nowhere-odhold/$PKG/f.txt" 2>/dev/null)" payload
  chk "E3 nothing copied into the dest" eqv "$([ -e "$R/data/user/$UID_/$PKG/f.txt" ] && echo copied || echo empty)" empty
  chk "E3 reown_ext_appdata <pkg> ran" has "$R/sim/calls" "$A"
  chk "E3 restorecon -R -D <ext data dir> ran" has "$R/sim/calls" "restorecon -R -D $D"

  say "== [$sh] E4: a hold on Android/data only -> handed back BEFORE the external re-own =="
  mkroot; D="$R/data/media/$UID_/Android/data/$PKG"
  plant_hold "$R" "media/$UID_/Android/data"
  run_od "$sh" "$R" "$PKG"
  chk "E4 the reply is OK $PKG" eqv "$(cat "$R/res" 2>/dev/null)" "OK $PKG"
  chk "E4 the held file landed in the external dest" eqv "$(cat "$D/f.txt" 2>/dev/null)" payload
  chk "E4 the external hold was already handed back when the re-own ran" eqv "$(cat "$R/sim/ext-at-reown" 2>/dev/null)" gone
  chk "E4 od_relabel of the hand-back precedes the re-own" before "$R/sim/calls" "od_relabel $R/data/media/$UID_/Android/data $D" "$A"
  chk "E4 re-own precedes the relabel" before "$R/sim/calls" "$A" "restorecon -R -D $D"
  chk "E4 reown_ext_appdata <pkg> ran" has "$R/sim/calls" "$A"

  say "== [$sh] E5: a bad package -> ERR-PKG and neither call =="
  mkroot
  run_od "$sh" "$R" "a/b"
  chk "E5 the reply is ERR-PKG" eqv "$(cat "$R/res" 2>/dev/null)" ERR-PKG
  chk "E5 no helper ran" eqv "$(grep -c . "$R/sim/calls")" 0

  OTHER="$UID_/Android/data/com.nowhere.chooser/.nowhere-odhold/com.example.other"
  plant_other() {  # plant_other <root>: another app's external hold, the copy source a `..` package reaches
    mkdir -p "$1/data/media/$OTHER"; echo other > "$1/data/media/$OTHER/f.txt"
  }
  bad_pkg() {  # bad_pkg <case> <pkg>: ERR-PKG before the hold probe, no helper or pm call, the other hold untouched
    mkroot; plant_other "$R"
    run_od "$sh" "$R" "$2"
    chk "$1 '$2': the reply is ERR-PKG" eqv "$(cat "$R/res" 2>/dev/null)" ERR-PKG
    chk "$1 '$2': no helper ran (no am, no pkg_live_pids)" eqv "$(grep -c . "$R/sim/calls")" 0
    chk "$1 '$2': no pm call" eqv "$([ -e "$R/sim/pm-calls" ] && echo called || echo none)" none
    chk "$1 '$2': nothing copied into Android/" eqv "$([ -e "$R/data/media/$UID_/Android/.nowhere-odhold" ] && echo copied || echo none)" none
    chk "$1 '$2': the other app's hold is untouched" eqv "$(cat "$R/data/media/$OTHER/f.txt" 2>/dev/null)" other
  }

  say "== [$sh] P1: package '..' with another app's external hold planted -> ERR-PKG, no copy, no call =="
  bad_pkg P1 ..

  say "== [$sh] P2: packages '.', 'a..b', '1a.b' -> ERR-PKG, no call =="
  bad_pkg P2 .
  bad_pkg P2 a..b
  bad_pkg P2 1a.b

  say "== [$sh] P3: a well-formed package with another app's external hold planted -> the arm runs as before =="
  mkroot; plant_other "$R"
  run_od "$sh" "$R" "$PKG"
  chk "P3 the reply is OK NOSRC" eqv "$(cat "$R/res" 2>/dev/null)" "OK NOSRC"
  chk "P3 reown_ext_appdata <pkg> ran" has "$R/sim/calls" "$A"
  chk "P3 the other app's hold is untouched" eqv "$(cat "$R/data/media/$OTHER/f.txt" 2>/dev/null)" other

  MARK="data/user/$UID_/com.nowhere.chooser/files/nowhere-od-materialised"
  GP="grant_perms_for $UID_ $PKG"
  plant_marker() {  # plant_marker <root> <line>... : the session's materialised record, one package per line
    local r="$1"; shift
    mkdir -p "$r/data/user/$UID_/com.nowhere.chooser/files"; printf '%s\n' "$@" > "$r/$MARK"
  }

  say "== [$sh] E6: no hold, the session's materialised record lists the package -> DECLINES 1, reply still OK NOSRC =="
  mkroot; plant_marker "$R" "$PKG"
  run_od "$sh" "$R" "$PKG"
  chk "E6 grant_perms_for <uid> <pkg> 1" has "$R/sim/calls" "$GP 1"
  chk "E6 that is the only grant_perms_for call" eqv "$(grep -c '^grant_perms_for ' "$R/sim/calls")" 1
  chk "E6 the reply is OK NOSRC" eqv "$(cat "$R/res" 2>/dev/null)" "OK NOSRC"

  say "== [$sh] E7: no hold, no record file -> DECLINES 0 =="
  mkroot
  run_od "$sh" "$R" "$PKG"
  chk "E7 grant_perms_for <uid> <pkg> 0" has "$R/sim/calls" "$GP 0"
  chk "E7 the reply is OK NOSRC" eqv "$(cat "$R/res" 2>/dev/null)" "OK NOSRC"

  say "== [$sh] E8: no hold, the record lists only look-alike packages -> DECLINES 0 (whole-line match) =="
  mkroot; plant_marker "$R" "${PKG}2" "x$PKG" "$PKG.extra"
  run_od "$sh" "$R" "$PKG"
  chk "E8 grant_perms_for <uid> <pkg> 0" has "$R/sim/calls" "$GP 0"

  say "== [$sh] E9: a hold and no record -> DECLINES 1 (unchanged) =="
  mkroot
  plant_hold "$R" "user/$UID_"; mkdir -p "$R/data/user/$UID_/$PKG"
  echo "$R/data/user/$UID_/$PKG $OWNED" > "$R/sim/owners"
  run_od "$sh" "$R" "$PKG"
  chk "E9 grant_perms_for <uid> <pkg> 1" has "$R/sim/calls" "$GP 1"
  chk "E9 the reply is OK $PKG" eqv "$(cat "$R/res" 2>/dev/null)" "OK $PKG"

  say "== [$sh] E10: the record path is a directory -> DECLINES 0 and the arm still replies =="
  mkroot; mkdir -p "$R/$MARK"
  run_od "$sh" "$R" "$PKG"
  chk "E10 grant_perms_for <uid> <pkg> 0" has "$R/sim/calls" "$GP 0"
  chk "E10 the reply is OK NOSRC" eqv "$(cat "$R/res" 2>/dev/null)" "OK NOSRC"

  say "== [$sh] E11: the arm puts the app's carried accessibility entries back once, after grant_perms_for =="
  mkroot
  run_od "$sh" "$R" "$PKG"
  chk "E11 a11y_apply <uid> <pkg> ran" has "$R/sim/calls" "a11y_apply $UID_ $PKG"
  chk "E11 that is the only a11y_apply call" eqv "$(grep -c '^a11y_apply ' "$R/sim/calls")" 1
  chk "E11 grant_perms_for precedes it" before "$R/sim/calls" "$GP 0" "a11y_apply $UID_ $PKG"

  la_line() { echo "$LA $LA_APPID 0 /data/user/0/$LA default:targetSdkVersion=34 none 0 1 1234"; }

  say "== [$sh] E12: a look-alike is listed BEFORE the package, the dest is owned by the package's uid -> hold consumed =="
  mkroot
  { la_line; echo "$PKG $APPID 0 /data/user/0/$PKG default:targetSdkVersion=34 none 0 1 1234"; } > "$R/data/system/packages.list"
  plant_hold "$R" "user/$UID_"; mkdir -p "$R/data/user/$UID_/$PKG"
  echo "$R/data/user/$UID_/$PKG $OWNED" > "$R/sim/owners"
  run_od "$sh" "$R" "$PKG"
  chk "E12 the reply is OK $PKG" eqv "$(cat "$R/res" 2>/dev/null)" "OK $PKG"
  chk "E12 the held file landed in the dest" eqv "$(cat "$R/data/user/$UID_/$PKG/f.txt" 2>/dev/null)" payload
  chk "E12 the hold was consumed" eqv "$([ -d "$R/data/user/$UID_/com.nowhere.chooser/.nowhere-odhold/$PKG" ] && echo kept || echo gone)" gone

  say "== [$sh] E13: only the look-alike is listed, the dest is owned by ITS uid -> ERR-NOTREADY, hold kept =="
  mkroot
  la_line > "$R/data/system/packages.list"
  plant_hold "$R" "user/$UID_"; mkdir -p "$R/data/user/$UID_/$PKG"
  echo "$R/data/user/$UID_/$PKG $LA_OWNED" > "$R/sim/owners"
  run_od "$sh" "$R" "$PKG"
  chk "E13 the reply is ERR-NOTREADY" eqv "$(cat "$R/res" 2>/dev/null)" ERR-NOTREADY
  chk "E13 the hold is kept" eqv "$(cat "$R/data/user/$UID_/com.nowhere.chooser/.nowhere-odhold/$PKG/f.txt" 2>/dev/null)" payload
  chk "E13 nothing copied into the dest" eqv "$([ -e "$R/data/user/$UID_/$PKG/f.txt" ] && echo copied || echo empty)" empty
  n=$(grep -F 'dest NOT app-owned' "$R/roam.log" 2>/dev/null | grep -cF 'want unresolved')
  chk "E13 roam.log says the dest is not app-owned, want unresolved" eqv "$n" 1

  say "== [$sh] E14: the arm puts the app's carried autofill service back once, after a11y_apply =="
  mkroot
  run_od "$sh" "$R" "$PKG"
  chk "E14 autofill_apply <uid> <pkg> ran" has "$R/sim/calls" "autofill_apply $UID_ $PKG"
  chk "E14 that is the only autofill_apply call" eqv "$(grep -c '^autofill_apply ' "$R/sim/calls")" 1
  chk "E14 a11y_apply precedes it" before "$R/sim/calls" "a11y_apply $UID_ $PKG" "autofill_apply $UID_ $PKG"

  say "== [$sh] E15: an app with code -> keystore_register gets the namespace pm listed =="
  mkroot
  run_od "$sh" "$R" "$PKG"
  chk "E15 keystore_register <pkg> <ns> ran" has "$R/sim/calls" "keystore_register $PKG $OWNED"
  chk "E15 that is the only keystore_register call" eqv "$(grep -c '^keystore_register ' "$R/sim/calls")" 1

  NOCODE="[roamd] odrestore $PKG -> no code for user $UID_ yet: grant, a11y, autofill and Keystore steps left to its install (NWP-20261122-03)"
  steps_n() { grep -cE '^(grant_perms_for|a11y_apply|autofill_apply|keystore_register) ' "$1/sim/calls"; }

  say "== [$sh] E16: an archived placeholder, a CE hold onto a root-owned dest -> no grant steps, ERR-NOTREADY as E3 =="
  mkroot; : > "$R/sim/pm-U"; : > "$R/data/system/packages.list"; D="$R/data/media/$UID_/Android/data/$PKG"
  plant_hold "$R" "user/$UID_"; mkdir -p "$R/data/user/$UID_/$PKG"
  echo "$R/data/user/$UID_/$PKG 0" > "$R/sim/owners"
  run_od "$sh" "$R" "$PKG"
  chk "E16 no grant_perms_for, a11y_apply, autofill_apply or keystore_register call" eqv "$(steps_n "$R")" 0
  chk "E16 the reply is ERR-NOTREADY" eqv "$(cat "$R/res" 2>/dev/null)" ERR-NOTREADY
  chk "E16 the hold is kept" eqv "$(cat "$R/data/user/$UID_/com.nowhere.chooser/.nowhere-odhold/$PKG/f.txt" 2>/dev/null)" payload
  chk "E16 reown_ext_appdata <pkg> ran" has "$R/sim/calls" "$A"
  chk "E16 restorecon -R -D <ext data dir> ran" has "$R/sim/calls" "restorecon -R -D $D"
  chk "E16 roam.log has the one 'no code' line" eqv "$(grep -cF -- "$NOCODE" "$R/roam.log" 2>/dev/null)" 1

  say "== [$sh] E17: an archived placeholder, no hold -> no grant steps, OK NOSRC as E1 =="
  mkroot; : > "$R/sim/pm-U"; : > "$R/data/system/packages.list"
  run_od "$sh" "$R" "$PKG"
  chk "E17 no grant_perms_for, a11y_apply, autofill_apply or keystore_register call" eqv "$(steps_n "$R")" 0
  chk "E17 the reply is OK NOSRC" eqv "$(cat "$R/res" 2>/dev/null)" "OK NOSRC"
  chk "E17 reown_ext_appdata <pkg> ran" has "$R/sim/calls" "$A"

  [ -z "$HARN" ] || { echo "HARNESS ERROR:$HARN" >&2; return 2; }
  say "[$sh] $p passed, $x failed"
  [ "$x" = 0 ]
}

rc=0
for sh in "${SHELLS[@]}"; do suite "$SUT" "$sh"; r=$?; [ "$r" -gt "$rc" ] && rc=$r; done
[ "$MUTATE" = yes ] || exit "$rc"
[ "$rc" = 0 ] || exit "$rc"

# --- mutants ------------------------------------------------------------------------------------------------
# Each is a transform of roamd's text, by exact line; a mutant that changes nothing is a failure of the suite.
L_RE='    reown_ext_appdata "$pkg"; restorecon -R -D "/data/media/$uid/Android/data/$pkg" 2>>"$LOG"'
L_LOOP='    odn=0; odsrc=0; odkept=0'
L_PROBE='    [ "$_first" = 1 ] || { grep -qxF -- "$pkg" "$USERDIR/com.nowhere.chooser/files/nowhere-od-materialised" 2>/dev/null && _first=1; }'
L_FIRST='    _first="$_hold"'
L_APPID='            _odappid=$(NW_PKG="$pkg" awk '"'"'$1 == ENVIRON["NW_PKG"] { print $2; exit }'"'"' /data/system/packages.list 2>/dev/null)'
L_KEPT_OWN='              odkept=$((odkept+1))'
L_APPID_OLD='            _odappid=$(grep -m1 "^$pkg " /data/system/packages.list 2>/dev/null | cut -d" " -f2)'
L_A11Y='      a11y_apply "$uid" "$pkg"  # NWP-20261108-18: Q024 -- this app'"'"'s carried a11y entries, once per session (.a11ydone)'
L_GUARD='    pkgname_ok "$pkg" || { echo "[roamd] odrestore bad pkg $(date)" >> "$LOG"; echo "ERR-PKG" > "$RES"; chmod 600 "$RES"; exit 0; }'
L_GUARD_OLD='    case "$pkg" in ""|*/*|*" "*) echo "[roamd] odrestore bad pkg $(date)" >> "$LOG"; echo "ERR-PKG" > "$RES"; chmod 600 "$RES"; exit 0;; esac'
L_AF='      autofill_apply "$uid" "$pkg"  # NWP-20261112-12: Q078 -- this app'"'"'s carried autofill service, once per session (.autofilldone)'
for l in "$L_RE" "$L_LOOP" "$L_PROBE" "$L_FIRST" "$L_APPID" "$L_KEPT_OWN" "$L_A11Y" "$L_AF" "$L_GUARD" '  odrestore)'; do
  [ "$(grep -cxF -- "$l" "$SUT")" = 1 ] || { echo "EXTRACTION FAILED: anchor line not unique in $SUT: $l" >&2; exit 2; }
done
# A mutant convicts only with rc 1 AND a FAIL line under each shell's own tag; rc 0 is NOT CONVICTED, rc 1 without
# such a line UNPROVEN, any other rc (extraction, parse, harness) BROKEN -- every one a failure of the suite.
mut() {
  local name="$1" prog="$2" t out r sh ev
  t=$(mktemp -p "$W")
  awk -v RE="$L_RE" -v LOOP="$L_LOOP" -v PROBE="$L_PROBE" -v FIRST="$L_FIRST" -v APPID_L="$L_APPID" -v APPID_OLD="$L_APPID_OLD" \
      -v KEPT_OWN="$L_KEPT_OWN" -v A11Y="$L_A11Y" -v AF="$L_AF" -v GUARD="$L_GUARD" -v GUARD_OLD="$L_GUARD_OLD" "$prog" "$SUT" > "$t"
  if cmp -s "$t" "$SUT"; then echo "  FAIL  mutant did not apply: $name"; MFAIL=1; command rm -f "$t"; return; fi
  for sh in "${SHELLS[@]}"; do
    out=$(suite "$t" "$sh" quiet 2>&1); r=$?
    ev=$(printf '%s\n' "$out" | grep -F "  FAIL  [$sh] ")
    if [ "$r" = 0 ]; then echo "  FAIL  NOT CONVICTED [$sh]: $name"; MFAIL=1
    elif [ "$r" != 1 ]; then echo "  FAIL  BROKEN (rc=$r) [$sh]: $name"; printf '%s\n' "$out" | sed 's/^/          /'; MFAIL=1
    elif [ -z "$ev" ]; then echo "  FAIL  UNPROVEN [$sh]: $name"; MFAIL=1
    else echo "  ok    CONVICTED [$sh]: $name"; printf '%s\n' "$ev" | sed 's/^/          /'
    fi
  done
  command rm -f "$t"
}
MFAIL=0
echo "== mutants =="
mut "the re-own line deleted" \
  '$0==RE{next} {print}'
mut "the re-own line guarded by odsrc = 1" \
  '$0==RE{print "    [ \"$odsrc\" = 1 ] && { reown_ext_appdata \"$pkg\"; restorecon -R -D \"/data/media/$uid/Android/data/$pkg\" 2>>\"$LOG\"; }"; next} {print}'
mut "restorecon -R -D reduced to -R" \
  '$0==RE{sub(/-R -D /,"-R ")} {print}'
mut "the re-own line moved above the volume loop" \
  '$0==RE{next} {print} $0==LOOP{print RE}'
mut "the materialised-record probe removed (E6)" \
  '$0==PROBE{next} {print}'
mut "-x dropped from the probe, substring match (E8)" \
  '$0==PROBE{sub(/-qxF/,"-qF")} {print}'
mut "the probe reads nowhere-od-restored instead (E6)" \
  '$0==PROBE{sub(/nowhere-od-materialised/,"nowhere-od-restored")} {print}'
mut "_first set to 1 unconditionally (E7)" \
  '$0==FIRST{print "    _first=1"; next} {print}'
mut "the exact appId lookup reverted to the old grep regex (E12)" \
  '$0==APPID_L{print APPID_OLD; next} {print}'
mut "the autofill call deleted (E14)" \
  '$0==AF{next} {print}'
mut "the autofill call moved above a11y_apply (E14)" \
  '$0==AF{next} $0==A11Y{print AF} {print}'
mut "the not-app-owned path leaves odkept non-numeric (E3, E13)" \
  '$0==KEPT_OWN{print "              odkept=kept"; next} {print}'
mut "the old slash/space filter restored (P1)" \
  '$0==GUARD{print GUARD_OLD; next} {print}'
mut "the package check moved after the force-stop (P1)" \
  '$0==GUARD{next} $0==LOOP{print GUARD} {print}'
[ "$MFAIL" = 0 ] || exit 1
echo "all mutants convicted"
