#!/usr/bin/env bash
# test-logoff-cutoff.sh [<nowhere_roamd.sh>] [--mutate] -- the logoff cutoff and its wake (NWP-20261011-04).
#
# WHY THIS IS COMMITTED. A sign-out now force-stops the session's apps before its seal (docs/product-decisions.md,
# 2026-10-10), and every exit that keeps the session takes them out of the stopped state again. Both halves fail
# SILENTLY: a keep-set entry dropped resets the user's keyboard, accessibility services or wallpaper, kills Bluetooth
# mid-logoff or cancels the alarm the gate was to ring, with no error anywhere; and a wake that does nothing leaves a
# kept session deaf to push until each app is opened by hand.
#
# roamd's cutoff functions, its `cutoff` and `cutoffwake` arms and its cleanstorage block are extracted BY ANCHOR and
# run against a fake device: one file per package holding its stopped flag (and, optionally, its uid), with `pm`,
# `am`, `settings` and `timeout` stubbed over it and the wallpaper record a binary-XML-shaped file. Only bash/toybox-safe
# constructs are exercised; the production shell is mksh.
#
# NWP-20261121-14: C30 runs the cutoffwake arm under every shell found (bash as `bash --posix`) with the order file
# planted as a DIRECTORY, a target that cannot be written. The arm's `( : > "$_cf.ord" )` must not end the op: both
# cutoff_run passes still run (handed the order path, from which they read no package), and the WAKE reply is written.
#
# NWP-20261125-21: the record survives a failed write and a partial wake. C31 (every shell) plants the union's scratch
# as a directory and C32 makes the union short (a `sort` that drops a line): the cutoff answers ERR-RECORD, stops
# nothing and leaves the earlier record byte for byte. C33 (every shell) leaves 2 of 5 recorded packages stopped: the
# record then holds exactly those two, 0600, and the next wake answers WAKE OK 2 and deletes it. C34 (every shell): an
# unverified wake keeps the record whole. C35: WAKE OK still deletes it. C36 (every shell, RF-001): a leftover write
# that is cut short and fails, followed by an awake recorded package, keeps the old record byte for byte.
#
#   bash test-logoff-cutoff.sh            # the cases
#   bash test-logoff-cutoff.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# NWP-20261121-14: the suite's temp root. It is TW, not W: inside suite() W is the cutoffwake arm's text.
TW=$(mktemp -d) || exit 2; trap 'rm -rf "$TW"' EXIT
# C30 runs under every shell found (the device's /system/bin/sh is mksh), de-duplicated by the file they resolve to.
SHELLS=()
seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$p")
done

# The functions run from CUTOFF_BUDGET= to the closing brace of cutoff_run.
fns() { awk '/^CUTOFF_BUDGET=/{on=1} on{print} on&&/^cutoff_run\(\) \{/{last=1} last&&/^}$/{exit}' "$1"; }
# An op arm runs from its label to the first line that is exactly "    ;;".
arm() { awk -v l="  $2)" 'index($0,l)==1&&length($0)==length(l){on=1} on{print} on&&/^    ;;$/{exit}' "$1"; }
clean() { awk '/^if \[ "\$op" = "cleanstorage" \]; then$/{on=1} on{print} on&&/^fi$/{exit}' "$1"; }

suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 F A W C
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }

  F=$(fns "$f"); A=$(arm "$f" cutoff); W=$(arm "$f" cutoffwake); C=$(clean "$f")
  case "$F" in *'cutoff_run()'*) ;; *) no "EXTRACTION FAILED -- the cutoff functions moved in $f"; return 2 ;; esac
  case "$A" in *'cutoff_run stop "$uid"'*) ;; *) no "EXTRACTION FAILED -- the cutoff arm moved in $f"; return 2 ;; esac
  case "$W" in *'cutoff_run unstop'*) ;; *) no "EXTRACTION FAILED -- the cutoffwake arm moved in $f"; return 2 ;; esac
  case "$C" in *'cleanstorage'*) ;; *) no "EXTRACTION FAILED -- the cleanstorage block moved in $f"; return 2 ;; esac
  # The blocks must still PARSE, or the suite would fail them for their syntax and call that a conviction.
  bash -n <<<"$F" 2>/dev/null && bash -n <<<"case x in
$A
esac" 2>/dev/null && bash -n <<<"case x in
$W
esac" 2>/dev/null && bash -n <<<"$C" 2>/dev/null || { no "THE BLOCKS DO NOT PARSE in $f"; return 2; }

  # dev <name=flag[:uid] ...>: a fresh fake device. A package with no uid gets one of its own. Prints its directory.
  dev() {
    local d kv n v u=20000; d=$(mktemp -d -p "$TW"); mkdir -p "$d/pk" "$d/uid" "$d/state" "$d/sys/10"; : > "$d/calls"
    for kv in "$@"; do
      n=${kv%%=*}; v=${kv#*=}; u=$((u + 1))
      printf '%s\n' "${v%%:*}" > "$d/pk/$n"
      case "$v" in *:*) printf '%s\n' "${v#*:}" > "$d/uid/$n" ;; *) printf '%s\n' "$u" > "$d/uid/$n" ;; esac
    done
    printf '%s\n' "$d"
  }
  # run <device> <op> [budget] [alarm owner] [parallelism]: run the op's arm over the device. RES lands in <device>/res.
  run() {
    local d="$1" blk
    case "$2" in cutoff) blk="$A" ;; *) blk="$W" ;; esac
    ( set +u +o pipefail
      umask 022   # the device's default: the arm must make its own files private
      uid=10 STATE="$d/state" RES="$d/res" LOG="$d/log" ACCT_AUTH_PKG=com.google.android.gms srcunit="${4:-}"
      export NOWHERE_CUTOFF_PAR="${5:-8}" NOWHERE_CUTOFF_BUDGET="${3:-45}" NOWHERE_CUTOFF_SYSUSERS="$d/sys" NOWHERE_PROGRESS="$d/prog"
      _ms(){ echo 0; }
      # F4 (round 4): every fake checks its --user argument; anything but the session's user is recorded.
      wu(){ [ "$1" = 10 ] || echo "$2 user=$1" >> "$d/wronguser"; }
      mkdir -p "$d/cwd"; cd "$d/cwd" || exit 1   # F9: a "*" in a setting must not expand against this directory
      timeout(){ shift 3; echo "via-timeout $1 $5" >> "$d/calls"; "$@"; }
      pm(){
        case "$1 $2" in
          "list packages")
            wu "$4" list
            [ -e "$d/listfail" ] && return 0
            local q; for q in "$d"/pk/*; do
              printf 'package:%s stopped=%s uid:%s\n' "${q##*/}" "$(cat "$q")" "$(cat "$d/uid/${q##*/}")"; done ;;
          "unstop --user")
            wu "$3" unstop
            echo "unstop $4" >> "$d/calls"
            grep -qxF -- "$4" "$d/stubborn" 2>/dev/null || { [ -e "$d/pk/$4" ] && echo false > "$d/pk/$4"; } ;;
        esac
      }
      am(){
        case "$1" in
          force-stop)
            wu "$3" force-stop
            echo "stop $4" >> "$d/calls"
            [ -e "$STATE/.cutoff.10.new" ] && stat -c %a "$STATE/.cutoff.10.new" >> "$d/newmode"
            # X2: every package the cutoff stops must already be in the record a killed worker leaves the wake.
            grep -qxF -- "$4" "$STATE/.cutoff.10" 2>/dev/null || echo "$4" >> "$d/unrecorded"
            # X1: a "slow" package takes effect late, so a verification that does not wait for its stop sees it running.
            grep -qxF -- "$4" "$d/slow" 2>/dev/null && sleep 0.4
            grep -qxF -- "$4" "$d/stubborn" 2>/dev/null || { [ -e "$d/pk/$4" ] && echo true > "$d/pk/$4"; }
            local a b; while read -r a b; do [ "$a" = "$4" ] && echo false > "$d/pk/$b"; done < "$d/peer" 2>/dev/null ;;
          broadcast) shift; wu "$2" broadcast; echo "broadcast $*" >> "$d/calls" ;;
        esac
      }
      settings(){ wu "$3" settings; echo "settings $5" >> "$d/calls"; cat "$d/set.$5" 2>/dev/null   # get --user <uid> secure <key>
        [ -s "$d/slowset" ] && sleep "$(cat "$d/slowset")"; return 0; }   # C24a: a slow settings provider
      # C32: a short union -- the record's sort drops its first line.
      sort(){ if [ -e "$d/shortsort" ]; then command sort "$@" | sed 1d; else command sort "$@"; fi; }
      eval "$F"
      op="$2"
      eval "case \"\$op\" in
$blk
esac"
    ) >/dev/null 2>&1
  }
  # runsh <shell> <device> [op]: the op's arm (cutoffwake unless op is cutoff) as a script of its own, run by <shell>
  # (bash as `bash --posix`, where a bare `: >` that fails ends the shell). The stubs are run()'s; cutoff_prog is
  # replaced so each pass leaves a line.
  runsh() {
    local sh="$1" d="$2" op="${3:-cutoffwake}"
    { printf "d='%s'\n" "$d"
      cat <<'STUBS'
set +u
umask 022
uid=10 STATE="$d/state" RES="$d/res" LOG="$d/log" ACCT_AUTH_PKG=com.google.android.gms srcunit=
NOWHERE_CUTOFF_PAR=8 NOWHERE_CUTOFF_BUDGET=45 NOWHERE_CUTOFF_SYSUSERS="$d/sys" NOWHERE_PROGRESS="$d/prog"
export NOWHERE_CUTOFF_PAR NOWHERE_CUTOFF_BUDGET NOWHERE_CUTOFF_SYSUSERS NOWHERE_PROGRESS
_ms(){ echo 0; }
wu(){ [ "$1" = 10 ] || echo "$2 user=$1" >> "$d/wronguser"; }
mkdir -p "$d/cwd"; cd "$d/cwd" || exit 1
timeout(){ shift 3; echo "via-timeout $1 $5" >> "$d/calls"; "$@"; }
pm(){
  case "$1 $2" in
    "list packages")
      wu "$4" list
      [ -e "$d/listfail" ] && return 0
      for q in "$d"/pk/*; do
        printf 'package:%s stopped=%s uid:%s\n' "${q##*/}" "$(cat "$q")" "$(cat "$d/uid/${q##*/}")"; done ;;
    "unstop --user")
      wu "$3" unstop
      echo "unstop $4" >> "$d/calls"
      grep -qxF -- "$4" "$d/stubborn" 2>/dev/null || { [ -e "$d/pk/$4" ] && echo false > "$d/pk/$4"; } ;;
  esac
}
am(){
  case "$1" in
    force-stop)
      wu "$3" force-stop
      echo "stop $4" >> "$d/calls"
      grep -qxF -- "$4" "$d/stubborn" 2>/dev/null || { [ -e "$d/pk/$4" ] && echo true > "$d/pk/$4"; } ;;
    broadcast) shift; wu "$2" broadcast; echo "broadcast $*" >> "$d/calls" ;;
  esac
}
settings(){ wu "$3" settings; echo "settings $5" >> "$d/calls"; cat "$d/set.$5" 2>/dev/null; return 0; }
# C36: a full filesystem under the leftover. While the wake writes .left, the echo of the package named in echofail
# writes only the first 8 bytes of its name, with no newline, and fails.
echo(){
  if [ -s "$d/echofail" ] && [ -e "$STATE/.cutoff.$uid.left" ] && [ "$*" = "$(cat "$d/echofail")" ]; then
    printf '%s' "$(cat "$d/echofail" | cut -c1-8)"; return 1
  fi
  printf '%s\n' "$*"
}
STUBS
      printf '%s\n' "$F"
      # After $F, so it replaces roamd's: the pass and the count each cutoff_run pass ran.
      printf '%s\n' 'cutoff_prog(){ echo "prog $1 ran=${CUTOFF_RAN:-}" >> "$d/progs"; }'
      case "$op" in
        cutoff) printf '%s\n' 'op=cutoff' 'case "$op" in' "$A" 'esac' ;;
        *) printf '%s\n' 'op=cutoffwake' 'case "$op" in' "$W" 'esac' ;;
      esac
    } > "$d/run.sh"
    case "${sh##*/}" in bash) "$sh" --posix "$d/run.sh" ;; *) "$sh" "$d/run.sh" ;; esac >/dev/null 2>&1
  }
  flag(){ cat "$1/pk/$2" 2>/dev/null; }
  rec(){ tr '\n' ' ' 2>/dev/null < "$1/state/.cutoff.10"; }
  res(){ cat "$1/res" 2>/dev/null; }
  # The session of the cases: every keep-set member live, plus the clock app (sharing its uid with a helper), a package
  # sharing the framework's uid, a package that is not a plain name, two live apps and one that was already stopped.
  session() {
    local d; d=$(dev com.nowhere.chooser=false android=false:1001000 com.android.systemui=false \
      com.android.bluetooth=false com.android.providers.media.module=false com.ime=false com.a11y=false \
      com.a11y2=false com.vpn=false com.lwp=false com.lwp2=false com.clock=false:1010500 \
      com.clockhelper=false:1010500 com.android.settings=false:1001000 -evil=false \
      com.sc=false com.btn=false com.btn2=false com.qs=false com.vr=false com.vi=false \
      com.msg=false com.google.android.gms=false com.idle=true)
    echo "com.ime/.LatinIME" > "$d/set.default_input_method"
    echo "com.a11y/.Reader:com.a11y2/.Other" > "$d/set.enabled_accessibility_services"
    echo "com.vpn" > "$d/set.always_on_vpn_app"
    echo "com.sc/.Magnifier" > "$d/set.accessibility_shortcut_target_service"
    echo "com.btn/.A:com.btn2/.B" > "$d/set.accessibility_button_targets"
    echo "com.qs/.Tile:*" > "$d/set.accessibility_qs_targets"
    mkdir -p "$d/cwd"; : > "$d/cwd/com.msg"   # F9: an unguarded "*" would expand to this name and keep a live app
    echo "com.vr/.Recognizer" > "$d/set.voice_recognition_service"
    echo "com.vi/.Interactor" > "$d/set.voice_interaction_service"
    echo com.msg > "$d/slow"
    # Binary XML: the system wallpaper's component with a length byte that is a printable letter ('H' = 72 bytes),
    # and the lock screen's after a non-printable one.
    printf 'ABX\000\001\002component\000Hcom.lwp/com.lwp.Live\000\003\000\034com.lwp2/.Lock\000' > "$d/sys/10/wallpaper_info.xml"
    printf '%s\n' "$d"
  }
  local d k bad

  d=$(session); run "$d" cutoff 45 com.clock
  [ "$(res "$d")" = "OK 2" ] && [ "$(flag "$d" com.msg)" = true ] && [ "$(flag "$d" com.google.android.gms)" = true ] \
    && ok "C1 every live app is stopped, Play services included: OK 2" || no "C1 the live apps were not all stopped (res=$(res "$d"))"
  bad=""; for k in com.nowhere.chooser android com.android.systemui com.android.bluetooth com.android.providers.media.module \
      com.ime com.a11y com.a11y2 com.vpn com.lwp com.lwp2 com.clock com.sc com.btn com.btn2 com.qs com.vr com.vi; do
    [ "$(flag "$d" "$k")" = false ] || bad="$bad $k"; grep -qx "stop $k" "$d/calls" && bad="$bad $k(called)"; done
  [ -z "$bad" ] && ok "C2 the keep-set is never stopped: chooser, framework, SystemUI, Bluetooth, MediaProvider, IME, both a11y services, every a11y shortcut target, voice recognition and interaction, VPN, both wallpapers, the alarm owner" \
    || no "C2 kept packages were stopped:$bad"
  bad=""; for k in com.clockhelper com.android.settings; do
    [ "$(flag "$d" "$k")" = false ] || bad="$bad $k"; done
  [ -z "$bad" ] && ok "C3 a package sharing a kept uid is kept with it (the alarm owner's, the framework's)" \
    || no "C3 shared-uid siblings were stopped:$bad"
  [ "$(rec "$d")" = "com.google.android.gms com.msg " ] && ! grep -qx "stop com.idle" "$d/calls" \
    && ok "C4 the record is exactly the live set; an already-stopped app is neither stopped nor recorded" \
    || no "C4 the record is [$(rec "$d")]"
  ! grep -q -- "-evil" "$d/calls" && ! grep -q -- "-evil" "$d/state/.cutoff.10" 2>/dev/null \
    && ok "C5 a name that is not a plain package name is neither stopped nor recorded" || no "C5 '-evil' reached am or the record"
  grep -q "com.msg" "$d/log" 2>/dev/null && no "C6 the log names a package -- a roster of the profile's apps (#39)" \
    || { grep -q "cutoff user 10: stopped 2 package(s), 0 still running" "$d/log" && grep -q "alarm owner kept=yes" "$d/log" \
         && ok "C6 the log carries counts, never names" || no "C6 no count line in the log"; }
  [ "$(stat -c %a "$d/state/.cutoff.10" 2>/dev/null)" = 600 ] && [ -s "$d/newmode" ] && [ -z "$(grep -vx 600 "$d/newmode")" ] \
    && ok "C7 the record and its scratch file are 0600 from the moment they exist" \
    || no "C7 record mode $(stat -c %a "$d/state/.cutoff.10" 2>/dev/null), scratch modes [$(tr '\n' ' ' < "$d/newmode" 2>/dev/null)]"
  [ "$(grep -c "^via-timeout settings" "$d/calls")" = 8 ] && [ "$(grep -c "^settings" "$d/calls")" = 8 ] \
    && ok "C8 every settings read is bounded" || no "C8 a settings read ran without its timeout"
  [ "$(flag "$d" com.msg)" = true ] && ok "C8b a '*' in a setting does not expand to the directory's names (F9)" \
    || no "C8b a glob in a setting kept com.msg"
  [ ! -s "$d/wronguser" ] && ok "C8c every am, pm and settings call names the session's user (F4)" \
    || no "C8c a call named another user: $(cat "$d/wronguser")"
  [ ! -s "$d/unrecorded" ] && ok "C8a every package is in the record BEFORE it is stopped (X2)" \
    || no "C8a stopped before it was recorded: $(tr '\n' ' ' < "$d/unrecorded")"
  grep -q "^cutoff " "$d/prog" 2>/dev/null && ok "C9 the cutoff writes progress (the daemon's stall clocks see it)" \
    || no "C9 no progress line"
  command rm -rf "$d"

  d=$(session); run "$d" cutoff 45 ""
  [ "$(flag "$d" com.clock)" = true ] && ok "C10 control: with no alarm owner passed, the clock app is stopped like any app" \
    || no "C10 the clock app was kept with no owner passed -- C2 proves nothing"
  command rm -rf "$d"

  d=$(session); run "$d" cutoff 45 "-x"
  grep -q "^stop -x$" "$d/calls" && no "C11 a malformed alarm owner reached am" || ok "C11 a malformed alarm owner is ignored"
  command rm -rf "$d"

  d=$(session); echo com.msg > "$d/stubborn"; run "$d" cutoff 45 com.clock
  [ "$(res "$d")" = "PARTIAL 2 1" ] && ok "C12 a package that will not stop is reported: PARTIAL 2 1" || no "C12 a stubborn package read as $(res "$d")"
  command rm -rf "$d"

  d=$(session); echo "com.msg com.idle" > "$d/peer"; run "$d" cutoff 45 com.clock
  [ "$(res "$d")" = "OK 2" ] && [ "$(flag "$d" com.idle)" = true ] && [ "$(rec "$d")" = "com.google.android.gms com.msg " ] \
    && ok "C13 an app a peer restarted mid-pass is caught by the second pass, and not recorded for the wake" \
    || no "C13 a peer restart survived the cutoff (res=$(res "$d") idle=$(flag "$d" com.idle) rec=[$(rec "$d")])"
  command rm -rf "$d"

  d=$(session); : > "$d/listfail"; run "$d" cutoff 45 com.clock
  [ "$(res "$d")" = "ERR-LIST" ] && ! grep -q "^stop " "$d/calls" && [ ! -e "$d/state/.cutoff.10" ] \
    && ok "C14 an unreadable package list stops nothing and says so: ERR-LIST" || no "C14 an unreadable list read as $(res "$d")"
  command rm -rf "$d"

  d=$(session); echo com.old > "$d/state/.cutoff.10"; run "$d" cutoff 45 com.clock
  [ "$(rec "$d")" = "com.google.android.gms com.msg com.old " ] && ok "C15 a record no wake consumed is kept: the union" \
    || no "C15 the earlier record was lost: [$(rec "$d")]"
  command rm -rf "$d"

  d=$(session); run "$d" cutoff 0 com.clock
  [ "$(res "$d")" = "PARTIAL 2 2" ] && ! grep -q "^stop " "$d/calls" && [ "$(rec "$d")" = "com.google.android.gms com.msg " ] \
    && ok "C16 a spent budget starts no more stops, and the record still lists what was live" || no "C16 the budget was not honoured (res=$(res "$d"))"
  command rm -rf "$d"

  d=$(dev com.nowhere.chooser=false com.msg=true com.google.android.gms=true com.idle=true -evil=true)
  printf 'com.google.android.gms\ncom.msg\n-evil\n' > "$d/state/.cutoff.10"; run "$d" cutoffwake
  [ "$(flag "$d" com.msg)" = false ] && [ "$(flag "$d" com.google.android.gms)" = false ] && [ "$(flag "$d" com.idle)" = true ] \
    && ok "C17 the wake un-stops exactly the record; an app stopped before stays stopped" \
    || no "C17 the wake (res=$(res "$d") msg=$(flag "$d" com.msg) gms=$(flag "$d" com.google.android.gms) idle=$(flag "$d" com.idle))"
  ! grep -q -- "-evil" "$d/calls" && ok "C18 the wake passes no malformed name to pm" || no "C18 '-evil' reached pm"
  [ ! -e "$d/state/.cutoff.10" ] && ok "C19 the wake consumes the record" || no "C19 the record survived its wake"
  grep -q "^broadcast .*--include-stopped-packages -a android.server.checkin.CHECKIN" "$d/calls" \
    && ok "C20 Play services in the record is started again (the checkin kick)" || no "C20 Play services was not kicked"
  grep -q "^cutoff " "$d/prog" 2>/dev/null && ok "C21 the wake writes progress" || no "C21 the wake wrote no progress"
  bad=""; for k in com.google.android.gms com.msg; do
    a=$(grep -n -x -F "broadcast --user 10 -p $k --include-stopped-packages --allow-fgs-start-reason 202 -a android.intent.action.LOCKED_BOOT_COMPLETED" "$d/calls" | head -1 | cut -d: -f1)
    b=$(grep -n -x -F "broadcast --user 10 -p $k --include-stopped-packages --allow-fgs-start-reason 200 -a android.intent.action.BOOT_COMPLETED" "$d/calls" | head -1 | cut -d: -f1)
    u=$(grep -n -x -F "unstop $k" "$d/calls" | head -1 | cut -d: -f1)
    { [ -n "$a" ] && [ -n "$b" ] && [ -n "$u" ] && [ "$u" -lt "$a" ] && [ "$a" -lt "$b" ]; } || bad="$bad $k"
  done
  [ -z "$bad" ] && ! grep -q -- "-p -evil" "$d/calls" && grep -q "boot re-arm sent to 2," "$d/log" \
    && ok "C21a each recorded package is re-armed after its unstop: LOCKED_BOOT_COMPLETED, then BOOT_COMPLETED, counted in the log" \
    || no "C21a the boot re-arm is missing, out of order or uncounted for:$bad"
  grep -q "^cutoff boot" "$d/prog" 2>/dev/null && ok "C21b the re-arm writes progress" || no "C21b the re-arm wrote no progress"
  grep -q "com.msg" "$d/log" && no "C21c the wake's log names a package" || ok "C21c the wake's log carries counts, never names"
  [ "$(res "$d")" = "WAKE OK 3" ] && ok "C21d the wake's answer names the op: WAKE OK 3" \
    || no "C21d the wake answered [$(res "$d")]"
  [ ! -s "$d/wronguser" ] && ok "C21e every wake call names the session's user (F4)" \
    || no "C21e a wake call named another user: $(cat "$d/wronguser")"
  command rm -rf "$d"

  d=$(dev com.msg=true); echo com.msg > "$d/state/.cutoff.10"; run "$d" cutoffwake
  [ "$(res "$d")" = "WAKE OK 1" ] && ! grep -q "CHECKIN" "$d/calls" \
    && ok "C22 no Play services in the record, no kick" || no "C22 a kick without Play services (res=$(res "$d"))"
  command rm -rf "$d"

  d=$(dev com.msg=true); echo com.msg > "$d/stubborn"; echo com.msg > "$d/state/.cutoff.10"; run "$d" cutoffwake
  [ "$(res "$d")" = "WAKE PARTIAL 1 1" ] && ok "C23 a package still stopped after the wake is reported: PARTIAL 1 1" \
    || no "C23 an unstop that did not land read as $(res "$d")"
  command rm -rf "$d"

  d=$(dev com.msg=true); echo com.msg > "$d/state/.cutoff.10"; run "$d" cutoffwake 0
  [ "$(res "$d")" = "WAKE PARTIAL 1 1" ] && ! grep -q "^unstop" "$d/calls" && ! grep -q "BOOT_COMPLETED" "$d/calls" \
    && ok "C24 a spent budget starts no more unstops and no re-arm" || no "C24 the wake ignored its budget (res=$(res "$d"))"
  command rm -rf "$d"

  # C24a (round 6): the wake's deadline starts AFTER its two settings reads. Each read here takes longer than the whole
  # budget; a deadline taken before them would be spent before the first unstop.
  d=$(dev com.msg=true); echo com.msg > "$d/state/.cutoff.10"; echo 1.5 > "$d/slowset"; run "$d" cutoffwake 2
  [ "$(res "$d")" = "WAKE OK 1" ] && grep -qx "unstop com.msg" "$d/calls" && [ "$(grep -c "^settings" "$d/calls")" = 2 ] \
    && ok "C24a slow settings reads do not spend the unstop pass's budget" \
    || no "C24a with slow settings reads the wake answered $(res "$d") (unstops: $(grep -c "^unstop" "$d/calls"))"
  command rm -rf "$d"

  d=$(dev com.msg=true); run "$d" cutoffwake
  [ "$(res "$d")" = "WAKE OK 0" ] && [ ! -s "$d/calls" ] && ok "C25 no record: OK 0, nothing touched (a repeated wake is a no-op)" \
    || no "C25 a wake with no record read as $(res "$d")"
  command rm -rf "$d"

  # F7: when the budget truncates, Play services, the calendar provider and the default SMS and dialer apps go first.
  d=$(dev com.aaa=true com.android.providers.calendar=true com.dialer=true com.google.android.gms=true com.sms=true com.zzz=true)
  printf 'com.aaa\ncom.android.providers.calendar\ncom.dialer\ncom.google.android.gms\ncom.sms\ncom.zzz\n' > "$d/state/.cutoff.10"
  echo com.sms > "$d/set.sms_default_application"; echo com.dialer > "$d/set.dialer_default_application"
  run "$d" cutoffwake 45 "" 1   # one at a time, so the order of the calls is the order of the sends
  got=$(grep "^unstop " "$d/calls" | sed 's/^unstop //' | tr '\n' ' ')
  [ "$got" = "com.google.android.gms com.android.providers.calendar com.sms com.dialer com.aaa com.zzz " ] \
    && ok "C27 the wake goes Play services, calendar provider, SMS, dialer, then the rest (F7)" || no "C27 the wake's order was [$got]"
  got=$(grep "LOCKED_BOOT_COMPLETED" "$d/calls" | sed 's/.* -p //; s/ .*//' | tr '\n' ' ')
  [ "$got" = "com.google.android.gms com.android.providers.calendar com.sms com.dialer com.aaa com.zzz " ] \
    && ok "C28 the re-arm keeps the same order" || no "C28 the re-arm's order was [$got]"
  [ "$(res "$d")" = "WAKE OK 6" ] && [ ! -e "$d/state/.cutoff.10.ord" ] && ok "C29 every recorded package woken once; the order file removed" \
    || no "C29 res=$(res "$d"), order file $(ls "$d/state" | tr '\n' ' ')"
  command rm -rf "$d"

  # C30 (NWP-20261121-14): an order file that cannot be written (a directory) does not end the wake, in every shell.
  local sh t lg
  for sh in "${SHELLS[@]}"; do
    t="[$(basename "$sh")]"
    d=$(mktemp -d -p "$TW"); mkdir -p "$d/pk" "$d/uid" "$d/state" "$d/sys/10"; : > "$d/calls"
    echo true > "$d/pk/com.google.android.gms"; echo 20001 > "$d/uid/com.google.android.gms"
    echo true > "$d/pk/com.msg"; echo 20002 > "$d/uid/com.msg"
    printf 'com.google.android.gms\ncom.msg\n' > "$d/state/.cutoff.10"
    mkdir "$d/state/.cutoff.10.ord"; : > "$d/state/.cutoff.10.ord/x"
    runsh "$sh" "$d"
    [ "$(res "$d")" = "WAKE PARTIAL 2 2" ] && ok "C30 $t an order file that cannot be written: the wake still answers, WAKE PARTIAL 2 2" \
      || no "C30 $t an order file that cannot be written: the wake answered [$(res "$d")]"
    [ "$(tr '\n' ' ' 2>/dev/null < "$d/progs")" = "prog unstop ran=0 prog boot ran=0 " ] \
      && ok "C30 $t both cutoff_run passes run, handed the order path, and read no package from it" \
      || no "C30 $t the cutoff_run passes were [$(tr '\n' ' ' 2>/dev/null < "$d/progs")]"
    ! grep -q "^unstop " "$d/calls" && ! grep -q "BOOT_COMPLETED" "$d/calls" \
      && ok "C30 $t no unstop and no boot re-arm is sent: the apps stay stopped" || no "C30 $t an unstop or a re-arm was sent"
    grep -q "^broadcast .*--include-stopped-packages -a android.server.checkin.CHECKIN" "$d/calls" \
      && ok "C30 $t the Play kick still runs" || no "C30 $t the Play kick did not run"
    lg=$(cat "$d/log" 2>/dev/null)
    case "$lg" in *"cutoffwake user 10: unstopped 2 package(s), 2 still stopped, boot re-arm sent to 0, play services kicked=yes"*)
      ok "C30 $t the arm's log line follows" ;; *) no "C30 $t the arm's log line is missing: [$lg]" ;; esac
    [ "$(rec "$d")" = "com.google.android.gms com.msg " ] && [ -d "$d/state/.cutoff.10.ord" ] \
      && ok "C30 $t the record keeps both packages still stopped; the planted directory is left" \
      || no "C30 $t record [$(rec "$d")], state is [$(ls -A "$d/state" | tr '\n' ' ')]"
    command rm -rf "$d"
  done

  # C31 (NWP-20261125-21): the union's scratch is a directory, so the union cannot be written. Every shell.
  local saved
  for sh in "${SHELLS[@]}"; do
    t="[$(basename "$sh")]"
    d=$(dev com.nowhere.chooser=false com.msg=false com.google.android.gms=false)
    printf 'com.old1\ncom.old2\ncom.old3\n' > "$d/state/.cutoff.10"; saved=$(mktemp -p "$TW"); cp "$d/state/.cutoff.10" "$saved"
    mkdir "$d/state/.cutoff.10.tmp"
    runsh "$sh" "$d" cutoff
    [ "$(res "$d")" = "ERR-RECORD" ] && ok "C31 $t a union that cannot be written answers ERR-RECORD" \
      || no "C31 $t a union that cannot be written answered [$(res "$d")]"
    ! grep -q "^stop " "$d/calls" && ok "C31 $t a refused record stops nothing" \
      || no "C31 $t a refused record still stopped [$(grep "^stop " "$d/calls" | tr '\n' ' ')]"
    cmp -s "$saved" "$d/state/.cutoff.10" && ok "C31 $t the earlier record is left byte for byte" \
      || no "C31 $t the earlier record became [$(rec "$d")]"
    lg=$(cat "$d/log" 2>/dev/null)
    case "$lg" in
      *com.*) no "C31 $t the refusal's log names a package (#39)" ;;
      *"cutoff user 10: record could not be written (2 live, 3 already recorded) -- NOTHING stopped"*)
        ok "C31 $t the refusal is logged with counts only" ;;
      *) no "C31 $t no refusal line in the log: [$lg]" ;;
    esac
    command rm -rf "$d" "$saved"
  done

  # C32 (NWP-20261125-21): the union is written short (one line dropped) and its pipeline still succeeds.
  d=$(session); printf 'com.old1\ncom.old2\ncom.old3\n' > "$d/state/.cutoff.10"; saved=$(mktemp -p "$TW")
  cp "$d/state/.cutoff.10" "$saved"; : > "$d/shortsort"; run "$d" cutoff 45 com.clock
  [ "$(res "$d")" = "ERR-RECORD" ] && ok "C32 a short union answers ERR-RECORD" || no "C32 a short union answered [$(res "$d")]"
  ! grep -q "^stop " "$d/calls" && ok "C32 a short union stops nothing" \
    || no "C32 a short union still stopped [$(grep "^stop " "$d/calls" | tr '\n' ' ')]"
  cmp -s "$saved" "$d/state/.cutoff.10" && [ ! -e "$d/state/.cutoff.10.tmp" ] \
    && ok "C32 a short union does not shrink the earlier record, and its scratch is removed" \
    || no "C32 the earlier record became [$(rec "$d")], state [$(ls -A "$d/state" | tr '\n' ' ')]"
  command rm -rf "$d" "$saved"

  # C33 (NWP-20261125-21): a wake leaves 2 of 5 recorded packages stopped. Every shell.
  for sh in "${SHELLS[@]}"; do
    t="[$(basename "$sh")]"
    d=$(dev com.a=true com.b=true com.c=true com.d=true com.e=true)
    printf 'com.a\ncom.b\ncom.c\ncom.d\ncom.e\n' > "$d/state/.cutoff.10"; printf 'com.b\ncom.e\n' > "$d/stubborn"
    runsh "$sh" "$d"
    [ "$(res "$d")" = "WAKE PARTIAL 5 2" ] && ok "C33 $t a wake that leaves two stopped answers WAKE PARTIAL 5 2" \
      || no "C33 $t the partial wake answered [$(res "$d")]"
    [ "$(rec "$d")" = "com.b com.e " ] && [ "$(stat -c %a "$d/state/.cutoff.10" 2>/dev/null)" = 600 ] \
      && [ ! -e "$d/state/.cutoff.10.left" ] \
      && ok "C33 $t the record keeps exactly the two still stopped, 0600, and no scratch" \
      || no "C33 $t record [$(rec "$d")] mode $(stat -c %a "$d/state/.cutoff.10" 2>/dev/null), state [$(ls -A "$d/state" | tr '\n' ' ')]"
    command rm -f "$d/stubborn"; : > "$d/res"; : > "$d/calls"
    runsh "$sh" "$d"
    [ "$(res "$d")" = "WAKE OK 2" ] && [ ! -e "$d/state/.cutoff.10" ] \
      && [ "$(grep "^unstop " "$d/calls" | sort | tr '\n' ' ')" = "unstop com.b unstop com.e " ] \
      && ok "C33 $t the next wake un-stops the two, answers WAKE OK 2 and deletes the record" \
      || no "C33 $t the next wake answered [$(res "$d")], record [$(rec "$d")]"
    command rm -rf "$d"
  done

  # C34 (NWP-20261125-21): the closing list cannot be read, so the wake is unverified. Every shell.
  for sh in "${SHELLS[@]}"; do
    t="[$(basename "$sh")]"
    d=$(dev com.a=true com.b=true com.c=true)
    printf 'com.a\ncom.b\ncom.c\n' > "$d/state/.cutoff.10"; saved=$(mktemp -p "$TW"); cp "$d/state/.cutoff.10" "$saved"
    : > "$d/listfail"
    runsh "$sh" "$d"
    [ "$(res "$d")" = "WAKE UNVERIFIED 3" ] && cmp -s "$saved" "$d/state/.cutoff.10" && [ ! -e "$d/state/.cutoff.10.ord" ] \
      && ok "C34 $t an unverified wake keeps the record whole" \
      || no "C34 $t the unverified wake answered [$(res "$d")], record [$(rec "$d")]"
    command rm -rf "$d" "$saved"
  done

  # C36 (NWP-20261125-21, RF-001): the leftover's write of a still-stopped package is cut short and fails, and a later
  # recorded package is awake. The failure must not be lost to that later entry: the old record stays byte for byte.
  for sh in "${SHELLS[@]}"; do
    t="[$(basename "$sh")]"
    d=$(dev com.messenger=true com.zawake=true)
    printf 'com.messenger\ncom.zawake\n' > "$d/state/.cutoff.10"; saved=$(mktemp -p "$TW"); cp "$d/state/.cutoff.10" "$saved"
    printf 'com.messenger\n' > "$d/stubborn"; printf 'com.messenger\n' > "$d/echofail"
    runsh "$sh" "$d"
    [ "$(res "$d")" = "WAKE PARTIAL 2 1" ] && cmp -s "$saved" "$d/state/.cutoff.10" && [ ! -e "$d/state/.cutoff.10.left" ] \
      && ok "C36 $t a leftover write that fails before an awake entry keeps the old record byte for byte" \
      || no "C36 $t the wake answered [$(res "$d")], record [$(rec "$d")], state [$(ls -A "$d/state" | tr '\n' ' ')]"
    command rm -rf "$d" "$saved"
  done

  # C35 (NWP-20261125-21): WAKE OK still deletes the record, and leaves no scratch.
  d=$(dev com.a=true com.b=true); printf 'com.a\ncom.b\n' > "$d/state/.cutoff.10"; run "$d" cutoffwake
  [ "$(res "$d")" = "WAKE OK 2" ] && [ -z "$(ls -A "$d/state")" ] && ok "C35 WAKE OK deletes the record and leaves no scratch" \
    || no "C35 the wake answered [$(res "$d")], state [$(ls -A "$d/state" | tr '\n' ' ')]"
  command rm -rf "$d"

  # cleanstorage, executed: everything but the record lines is stubbed out by running only those lines.
  d=$(dev); : > "$d/state/.cutoff.10"; : > "$d/state/.cutoff.10.new"; : > "$d/state/.cutoff.10.tmp"; : > "$d/state/.cutoff.11"
  ( uid=10 STATE="$d/state"; eval "$(printf '%s\n' "$C" | grep -F '.cutoff.')" ) >/dev/null 2>&1
  ls -A "$d/state" > "$d/left"
  if grep -q '^\.cutoff\.10' "$d/left"; then no "C26 the reap leaves the session's cutoff record or its scratch: $(tr '\n' ' ' < "$d/left")"
  elif grep -qx '.cutoff.11' "$d/left"; then ok "C26 the reap removes the session's record and scratch, and only its own"
  else no "C26 the reap removed another user's record"; fi
  command rm -rf "$d"

  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- by behaviour: a mutant that no longer extracts proves nothing)"
mut() { # mut <label> <perl-expr>
  local m rc; m=$(mktemp -p "$TW")
  if ! perl -0pe "$2" "$SUT" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; command rm -f "$m"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; command rm -f "$m"; return 1; fi
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; command rm -f "$m"; return 1; fi
  suite "$m" quiet; rc=$?
  command rm -f "$m"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant's blocks no longer extract or parse (rc=$rc)"; return 1 ;;
  esac
}
# mut_all <label> <case> <perl-expr>: as mut(), but the suite's output is read, and a FAIL line of <case> is required
# for EVERY shell.
mut_all() {
  local m out rc sh t
  m=$(mktemp -p "$TW")
  if ! perl -0pe "$3" "$SUT" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; command rm -f "$m"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; command rm -f "$m"; return 1; fi
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; command rm -f "$m"; return 1; fi
  out=$(suite "$m" 2>&1); rc=$?
  command rm -f "$m"
  [ "$rc" = 1 ] || { echo "  NOT CONVICTED $1 (rc=$rc)"; return 1; }
  rc=0
  for sh in "${SHELLS[@]}"; do
    t="[$(basename "$sh")]"
    case "$out" in
      *"  FAIL  $2 $t "*) echo "  convicted $1 under $t" ;;
      *) echo "  SURVIVED  $1 under $t"; rc=1 ;;
    esac
  done
  return "$rc"
}
fails=0
mut "M1 SystemUI not kept"                 's/ android com\.android\.systemui / android /' || fails=$((fails+1))
mut "M2 the chooser not kept"              's/_k=" com\.nowhere\.chooser /_k=" /' || fails=$((fails+1))
mut "M3 MediaProvider not kept"            's/ com\.android\.providers\.media\.module / /' || fails=$((fails+1))
mut "M4 Bluetooth not kept"                's/com.android.systemui com.android.bluetooth /com.android.systemui /' || fails=$((fails+1))
mut "M5 the alarm owner not kept"          's/  cutoff_pkgok "\$2" && _k="\$_k\$2 "\n//' || fails=$((fails+1))
mut "M6 the selected IME not kept"         's/for _s in default_input_method /for _s in /' || fails=$((fails+1))
mut "M7 only the first a11y service kept"  's/for _a in \$\(echo "\$_v" \| tr \x27:\x27 \x27 \x27\); do/for _a in \$(echo "\$_v" | tr \x27:\x27 \x27 \x27 | cut -d\x27 \x27 -f1); do/' || fails=$((fails+1))
mut "M8 the always-on VPN not kept"        's/(for _s in default_input_method) always_on_vpn_app /$1 /' || fails=$((fails+1))
mut "M8a the a11y shortcut target not kept" 's/(always_on_vpn_app enabled_accessibility_services) accessibility_shortcut_target_service /$1 /' || fails=$((fails+1))
mut "M8b the a11y button targets not kept" 's/(\n            )accessibility_button_targets /$1/' || fails=$((fails+1))
mut "M8c the a11y QS targets not kept"     's/(accessibility_button_targets) accessibility_qs_targets (voice_recognition_service)/$1 $2/' || fails=$((fails+1))
mut "M8d voice recognition not kept"       's/ voice_recognition_service / /' || fails=$((fails+1))
mut "M8e voice interaction not kept"       's/ voice_recognition_service voice_interaction_service; do/ voice_recognition_service; do/' || fails=$((fails+1))
mut "M9 the live wallpaper not kept"       's/(\$CUTOFF_SYSUSERS\/\$1\/)wallpaper_info\.xml/$1wallpaper_nope.xml/' || fails=$((fails+1))
mut "M10 the ABX length byte not peeled"   's/    _a=\$\{_a#\?\}; cutoff_pkgok "\$_a" && _k="\$_k\$_a "\n//' || fails=$((fails+1))
mut "M11 shared uids not kept"             's/(case "\$_u" in ""\|\*\[!0-9\]\*\) ;; \*\) )case "\$2" in \*" \$_u "\*\) continue ;; esac ;; esac/$1: ;; esac/' || fails=$((fails+1))
mut "M12 the filter's name check dropped"  's/(    \[ "\$_f" = "\$3" \] \|\| continue\n)    cutoff_pkgok "\$_p" \|\| continue\n/$1/' || fails=$((fails+1))
mut "M13 the run's name check dropped"     's/(  while IFS= read -r _p; do\n)    cutoff_pkgok "\$_p" \|\| continue\n(    \[ "\$\(date \+%s\)" -lt "\$4" \])/$1$2/' || fails=$((fails+1))
mut "M14 no second pass"                   's/if \[ -s "\$_cf\.new" \]; then cutoff_run stop/if false; then cutoff_run stop/' || fails=$((fails+1))
mut "M15 the record forgets an earlier one" 's/cat "\$_cf" "\$_cf\.new" 2>\/dev\/null \| sort -u/cat "\$_cf.new" 2>\/dev\/null | sort -u/' || fails=$((fails+1))
mut "M16 an unreadable list proceeds"      's/(_call=\$\(cutoff_list "\$uid"\)\n    case "\$_call" in\n      )\*"package:"\*\)/$1*)/' || fails=$((fails+1))
mut "M17 the cutoff always answers OK"     's/if \[ "\$\{_cleft:-0\}" -eq 0 \]; then/if true; then/' || fails=$((fails+1))
mut "M18 no deadline"                      's/\[ "\$\(date \+%s\)" -lt "\$4" \] \|\| break/:/' || fails=$((fails+1))
mut "M19 the wake un-stops nothing"        's/timeout -k 2 10 pm unstop --user "\$2" "\$_p"/: pm unstop --user "\$2" "\$_p"/' || fails=$((fails+1))
mut "M20 the wake keeps the record"        's/(      case "\$_wleft" in\n        )0\) rm -f "\$_cf" ;;\n/${1}0) : ;;\n/' || fails=$((fails+1))
mut "M21 the Play kick is unconditional"   's/if grep -qxF "\$ACCT_AUTH_PKG" "\$_cf"; then/if true; then/' || fails=$((fails+1))
mut "M22 the wake always answers OK"       's/if \[ "\$_wleft" -eq 0 \]; then/if true; then/' || fails=$((fails+1))
mut "M23 the reap keeps the record"        's/  rm -f "\$STATE\/\.cutoff\.\$uid" "\$STATE\/\.cutoff\.\$uid"\.\* 2>\/dev\/null   #/  : #/' || fails=$((fails+1))
mut "M24 the reap keeps the scratch"       's/  rm -f "\$STATE\/\.cutoff\.\$uid" "\$STATE\/\.cutoff\.\$uid"\.\* 2>\/dev\/null   #/  rm -f "\$STATE\/.cutoff.\$uid" 2>\/dev\/null   #/' || fails=$((fails+1))
mut "M25 the log names packages"           's/(echo "\[roamd\] cutoff user \$uid: stopped)/cat "\$_cf" >> "\$LOG"; $1/' || fails=$((fails+1))
mut "M26 the stopped-set filter inverted"  's/cutoff_filter "\$_ckeep" "\$_ckuid" false > "\$_cf\.new"\n        cat/cutoff_filter "\$_ckeep" "\$_ckuid" true > "\$_cf.new"\n        cat/' || fails=$((fails+1))
mut "M27 the record made 0644 (Y3)"        's/mv -f "\$_cf\.tmp" "\$_cf"; chmod 600 "\$_cf"/mv -f "\$_cf.tmp" "\$_cf"; chmod 644 "\$_cf"/' || fails=$((fails+1))
mut "M28 no umask in the cutoff"           's/(  cutoff\)\n(?:    #[^\n]*\n)*)    umask 077\n/$1/' || fails=$((fails+1))
mut "M29 a settings read unbounded"        's/_v=\$\(timeout -k 2 10 settings get --user "\$1" secure "\$_s"/_v=\$(settings get --user "\$1" secure "\$_s"/' || fails=$((fails+1))
mut "M30 no progress"                      's/(cutoff_prog\(\) \{\n)/$1  return 0\n/' || fails=$((fails+1))
mut "M31 the wake has no deadline"         's/cutoff_run unstop "\$uid" "\$_cf\.ord" "\$_wdl"/cutoff_run unstop "\$uid" "\$_cf.ord" 9999999999/' || fails=$((fails+1))
mut "M50 the wake deadline before its settings reads" 's/      # The deadline starts HERE[^\n]*\n      #[^\n]*\n      _wdl=[^\n]*\n//; s/(      _wsms=)/      _wdl=\$(( \$(date +%s) + CUTOFF_BUDGET ))\n$1/' || fails=$((fails+1))
mut "M32 no boot re-arm"                   's/      cutoff_run boot "\$uid" "\$_cf\.ord" [^\n]*\n//' || fails=$((fails+1))
mut "M33 BOOT_COMPLETED before LOCKED"     's/(--allow-fgs-start-reason 202 -a android\.intent\.action\.)LOCKED_BOOT_COMPLETED(.*\n.*--allow-fgs-start-reason 200 -a android\.intent\.action\.)BOOT_COMPLETED/$1BOOT_COMPLETED$2LOCKED_BOOT_COMPLETED/' || fails=$((fails+1))
mut "M34 X1: the final wait dropped"       's/(  done < "\$3"\n)  wait\n(  CUTOFF_RAN=)/$1$2/' || fails=$((fails+1))
mut "M35 X2: the record after the first stop" 's/(          mv -f "\$_cf\.tmp" "\$_cf"; chmod 600 "\$_cf" 2>\/dev\/null\n)((?:.*\n)*?          cutoff_run stop "\$uid" "\$_cf\.new" "\$_cdl"\n)/$2$1/' || fails=$((fails+1))
mut "M36 the wake's answer does not name it" 's/echo "WAKE OK \$_wn" > "\$RES"/echo "OK \$_wn" > "\$RES"/' || fails=$((fails+1))
mut "M37 the re-arm not counted"           's/      _wboot=\$\{CUTOFF_RAN:-0\}\n/      _wboot=0\n/' || fails=$((fails+1))
mut "M38 F4: force-stop sent to user 0"   's/am force-stop --user "\$2" "\$_p"/am force-stop --user 0 "\$_p"/' || fails=$((fails+1))
mut "M39 F4: unstop sent to user 0"       's/pm unstop --user "\$2" "\$_p"/pm unstop --user 0 "\$_p"/' || fails=$((fails+1))
mut "M40 F4: settings read for user 0"    's/settings get --user "\$1" secure "\$_s"/settings get --user 0 secure "\$_s"/' || fails=$((fails+1))
mut "M41 F4: the list read for user 0"    's/pm list packages --user "\$1" -U/pm list packages --user 0 -U/' || fails=$((fails+1))
mut "M42 F4: the re-arm sent to user 0"   's/am broadcast --user "\$2" -p "\$_p" --include-stopped-packages --allow-fgs-start-reason 200/am broadcast --user 0 -p "\$_p" --include-stopped-packages --allow-fgs-start-reason 200/' || fails=$((fails+1))
mut "M43 F1: no FGS allowance, LOCKED"    's/--allow-fgs-start-reason 202 //' || fails=$((fails+1))
mut "M44 F1: no FGS allowance, BOOT"      's/--allow-fgs-start-reason 200 //' || fails=$((fails+1))
mut "M45 F9: no set -f around the split"  's/    set -f\n(    for _a in \$\(echo "\$_v")/$1/' || fails=$((fails+1))
mut "M46 F7: the wake in record order"    's/cutoff_run unstop "\$uid" "\$_cf\.ord"/cutoff_run unstop "\$uid" "\$_cf"/' || fails=$((fails+1))
mut "M47 F7: no priority at all"          's/for _p in "\$ACCT_AUTH_PKG" com\.android\.providers\.calendar "\$_wsms" "\$_wdial"; do/for _p in ; do/' || fails=$((fails+1))
mut "M48 F7: the SMS app not first"       's/com\.android\.providers\.calendar "\$_wsms" "\$_wdial"; do/com.android.providers.calendar "\$_wdial"; do/' || fails=$((fails+1))
mut "M49 F7: the re-arm in record order"  's/cutoff_run boot "\$uid" "\$_cf\.ord"/cutoff_run boot "\$uid" "\$_cf"/' || fails=$((fails+1))
mut_all "M51 the order file's truncation bare again" C30 's/_wpri=" "; \( : > "\$_cf\.ord" \)/_wpri=" "; : > "\$_cf.ord"/' || fails=$((fails+1))
# NWP-20261125-21: the record survives a failed write and a partial wake.
mut_all "M52 the completeness check removed (rename whatever was written)" C31 's/_cok=no\n        if \[ "\$_crc" = 0 \]; then/_cok=yes\n        if false; then/' || fails=$((fails+1))
mut "M52a the completeness count ignored (a short union renamed)" 's/case "\$_cgs:\$_cmiss" in 0:0\|1:0\) ;; \*\) _cok=no ;; esac/:/' || fails=$((fails+1))
mut_all "M53 the stop runs after a refused record" C31 's/(        else\n          rm -f "\$_cf\.tmp" "\$_cf\.new" 2>\/dev\/null\n)/        else\n          cutoff_run stop "\$uid" "\$_cf.new" "\$_cdl"\n          rm -f "\$_cf.tmp" "\$_cf.new" 2>\/dev\/null\n/' || fails=$((fails+1))
mut_all "M54 the partial wake deletes the record" C33 's/        \*\)\n          # A loop of its own(?:.*\n)*?          fi ;;\n/        *) rm -f "\$_cf" ;;\n/' || fails=$((fails+1))
mut_all "M55 the partial wake keeps the whole record" C33 's/        \*\)\n          # A loop of its own(?:.*\n)*?          fi ;;\n/        *) : ;;\n/' || fails=$((fails+1))
mut_all "M57 a failed leftover write lost to a later entry" C36 's/\*" \$_p "\*\) echo "\$_p" \|\| exit 1 ;;/*" \$_p "*) echo "\$_p" ;;/' || fails=$((fails+1))
mut_all "M56 UNVERIFIED deletes the record" C34 's/        unknown\) : ;;\n/        unknown) rm -f "\$_cf" ;;\n/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
