#!/usr/bin/env bash
# test-grant-session-repeat.sh [<nowhere_roamd.sh>] [--mutate] -- grant_perms_for's grant phase runs once per package
# per session (NWP-20261025-10).
#
# WHY THIS IS COMMITTED. AppInstallReceiver.heal sends RESTORE-ODDATA on EVERY PACKAGE_ADDED, EXTRA_REPLACING included, so
# every app update in a session ran odrestore and a package-filtered grant pass with the LOGIN-time nowhere-perms. A
# permission the user revoked mid-session came back with nothing on screen, and the sign-out's capture then recorded it
# as granted: the revoke was lost for good. The same held for the INTERNET default (a user's Network-off toggle on an
# app with no captured line) and for an app materialised mid-session and updated later. The fix records, per session,
# the packages whose grant phase landed ($STATE/.granted.<uid>) and skips the phase for a package-filtered call that is
# not a first install (DECLINES 1 and not yet in .declined.<uid>, the declines pass's own test). Each way that breaks is
# silent on the device:
#   - the skip test gone, or matching a prefix (com.foo skipping com.foobar);
#   - the record never written, or written for a package whose `pm grant` failed (a placeholder pm refuses), which
#     would then never get its first real grants;
#   - a first install skipped because the package is already recorded;
#   - the INTERNET default outside the skip, or its success not recorded;
#   - roam-in not clearing the record (a new session can reuse a uid).
#
#   bash test-grant-session-repeat.sh            # the behaviour cases
#   bash test-grant-session-repeat.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS="bash sh"
for s in mksh dash; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

UIDV=15
PFREL="data/user/$UIDV/com.nowhere.chooser/files/nowhere-perms"
CAM=android.permission.CAMERA
INET=android.permission.INTERNET
SAW=appop:android:system_alert_window
SKIP="] GRANT (%s) -> skipped: granted this session, not a first install"

# POSIX sh. A pm grant / revoke of a package named in $D/notinstalled fails, as pm does for a package with no manifest.
STUBS='
pm() {
  case "$1 $2" in
    "list packages") cat "$D/pkgs" ;;
    "grant --user")  echo "grant $4 $5"  >> "$D/calls"; ! grep -qxF -- "$4" "$D/notinstalled" 2>/dev/null ;;
    "revoke --user") echo "revoke $4 $5" >> "$D/calls"; ! grep -qxF -- "$4" "$D/notinstalled" 2>/dev/null ;;
    "set-permission-flags --user") shift 3; echo "flags $*" >> "$D/calls" ;;
    *) echo "pm $*" >> "$D/unexpected"; return 1 ;;
  esac
}
cmd() { echo "cmd $*" >> "$D/calls"; return 0; }
'

# prep_fn <roamd.sh> <out> -- extract grant_perms_for and point its nowhere-perms under $TROOT. 0 ok, 2 harness error.
prep_fn() {
  local sut="$1" out="$2" raw
  raw=$(mktemp -p "$W") || return 2
  sed -n '/^grant_perms_for() {$/,/^}$/p' "$sut" > "$raw"
  if [ ! -s "$raw" ] || [ "$(head -1 "$raw")" != 'grant_perms_for() {' ] || [ "$(tail -1 "$raw")" != '}' ]; then
    echo "EXTRACTION FAILED: grant_perms_for() { ... } not found in $sut" >&2; return 2
  fi
  sed 's#PF="/data/user/#PF="$TROOT/data/user/#' "$raw" > "$out"
  if [ "$(grep -c 'PF="\$TROOT/data/user/' "$out")" != 1 ] || [ "$(grep -c '/data/user/' "$out")" != 1 ]; then
    echo "REWRITE FAILED: want exactly one PF=\"/data/user/ assignment in grant_perms_for of $sut" >&2; return 2
  fi
  if ! bash -n "$out" || ! sh -n "$out"; then
    echo "EXTRACTION FAILED: grant_perms_for does not parse ($sut)" >&2; return 2
  fi
  return 0
}

# run <fn> <shell> <content> <notinstalled> <pkg>... -- the CALLS lines run in one fresh $STATE, as on the device.
# Sets D. <notinstalled> is the content of $D/notinstalled.
run() {
  local fn="$1" sh="$2" content="$3" nin="$4" pf
  shift 4
  D=$(mktemp -d -p "$W"); pf="$D/root/$PFREL"
  mkdir -p "$D/state" "${pf%/*}"
  printf '%s' "$content" > "$pf"
  printf '%s' "$nin" > "$D/notinstalled"
  printf 'package:%s\n' "$@" > "$D/pkgs"
  {
    printf 'D=%s\nTROOT=%s\nSTATE=%s\nLOG=%s\n' "$D" "$D/root" "$D/state" "$D/log"
    printf '%s\n' "$STUBS"
    cat "$fn"
    printf '%s\n' "$CALLS"
  } > "$D/run.sh"
  "$sh" "$D/run.sh" >/dev/null 2>&1
  touch "$D/calls" "$D/log" "$D/unexpected"
}

has()   { grep -qxF -- "$1" "$D/calls" || why="$why missing '$1';"; }
hasnt() { ! grep -qxF -- "$1" "$D/calls" || why="$why unexpected '$1';"; }
count() { [ "$(grep -cxF -- "$2" "$D/calls")" = "$1" ] || why="$why want $1 x '$2', got $(grep -cxF -- "$2" "$D/calls");"; }
# nothing for <pkg> was granted, re-allowed or revoked after the first <n> calls
none_after() { local n="$1" pk="$2" tail; tail=$(sed "1,${n}d" "$D/calls" | grep -F -- " $pk " ); [ -z "$tail" ] || why="$why $pk touched again: $(echo "$tail" | tr '\n' ';')"; }
recorded() {  # recorded <expected sorted pkgs, space separated>
  local got; got=$(sort "$D/state/.granted.$UIDV" 2>/dev/null | tr '\n' ' ')
  [ "$got" = "$1" ] || why="$why .granted is '$got', want '$1';"
}
skipped() { local want="$1" pk="$2" got; got=$(grep -cF -- "$(printf "$SKIP" "$pk")" "$D/log"); [ "$got" = "$want" ] || why="$why want $want skip line(s) for $pk, got $got;"; }
clean()   { [ -s "$D/unexpected" ] && why="$why unmodelled: $(tr '\n' ';' < "$D/unexpected");"; [ ! -e "$D/state/.grantok" ] || why="$why .grantok left behind;"; command rm -rf "$D"; }

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" fn p=0 x=0 sh rc NL why base loc nxt
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  verdict() { if [ -z "$why" ]; then ok "$1 [$sh]"; else no "$1 [$sh] --$why"; fi; }
  fn=$(mktemp -p "$W") || return 2
  prep_fn "$f" "$fn"; rc=$?
  [ "$rc" = 0 ] || return 2
  NL=$'\n'
  local signin="grant_perms_for $UIDV" PERMS
  # com.a: a grant + an appop; com.b: a grant (not installed); com.c: appop only (not in the package list, so the
  # INTERNET default never touches it); com.d: an explicit INTERNET deny
  PERMS="com.a $CAM${NL}com.a $SAW${NL}com.b $CAM${NL}com.c $SAW${NL}com.d deny:$INET${NL}com.a $INET$NL"

  # G7: the roam-in block, pinned as a block
  sh=script; why=""
  loc=$(grep -nxF '      rm -f "$STATE/.declined.$uid" 2>>"$LOG"' "$f" | cut -d: -f1)
  case "$loc" in ""|*"$NL"*) why="$why the roam-in .declined rm is not exactly one line;";; *)
    nxt=$(sed -n "$((loc + 1))p" "$f")
    case "$nxt" in '      rm -f "$STATE/.granted.$uid" 2>>"$LOG"'*) ;; *) why="$why the line after it is '$nxt', not the .granted rm;";; esac;;
  esac
  verdict "G7 roam-in clears the granted record on the line after the declined one"

  for sh in $SHELLS; do
    why=""; CALLS="$signin" run "$fn" "$sh" "$PERMS" "com.b${NL}" com.a com.b com.d
    has "grant com.a $CAM"; has "grant com.b $CAM"; has "revoke com.d $INET"
    recorded "com.a com.d "; clean
    verdict "G1 sign-in grants every line and records exactly the packages whose pm call landed"

    why=""; CALLS="$signin" run "$fn" "$sh" "$PERMS" "com.b${NL}" com.a com.b com.d
    base=$(grep -c . "$D/calls"); clean
    CALLS="$signin${NL}grant_perms_for $UIDV com.a 0${NL}grant_perms_for $UIDV com.d 0" run "$fn" "$sh" "$PERMS" "com.b${NL}" com.a com.b com.d
    [ "$(grep -c . "$D/calls")" = "$base" ] || why="$why the update heals issued $(( $(grep -c . "$D/calls") - base )) more call(s) than the sign-in alone;"
    count 1 "grant com.a $CAM"; count 1 "revoke com.d $INET"; count 1 "grant com.a $INET"
    count 1 "cmd appops set --user $UIDV com.a android:system_alert_window allow"
    skipped 1 com.a; skipped 1 com.d
    clean
    verdict "G2 an update heal (DECLINES 0) of a recorded package grants, re-allows and revokes nothing"

    why=""; CALLS="$signin${NL}grant_perms_for $UIDV com.a 1" run "$fn" "$sh" "$PERMS" "com.b${NL}" com.a com.b com.d
    count 2 "grant com.a $CAM"; count 2 "cmd appops set --user $UIDV com.a android:system_alert_window allow"
    skipped 0 com.a; recorded "com.a com.a com.d "
    [ "$(grep -cxF com.a "$D/state/.declined.$UIDV")" = 1 ] || why="$why .declined does not hold com.a once;"
    clean
    verdict "G3 a first install (DECLINES 1, not in .declined) grants even though the package is recorded"

    why=""; CALLS="$signin${NL}grant_perms_for $UIDV com.a 1${NL}grant_perms_for $UIDV com.a 1" run "$fn" "$sh" "$PERMS" "com.b${NL}" com.a com.b com.d
    count 2 "grant com.a $CAM"; count 2 "grant com.a $INET"; skipped 1 com.a
    clean
    verdict "G4 the same package's next DECLINES 1 call (now in .declined) grants nothing"

    why=""; CALLS="grant_perms_for $UIDV com.e 0${NL}grant_perms_for $UIDV com.e 0" run "$fn" "$sh" "com.e $CAM$NL" "" com.e
    count 1 "grant com.e $CAM"; skipped 1 com.e; recorded "com.e "
    clean
    verdict "G5 a package in neither record is granted and recorded; its second call grants nothing"

    why=""; CALLS="$signin${NL}: > \"\$D/notinstalled\"${NL}grant_perms_for $UIDV com.b 0${NL}grant_perms_for $UIDV com.b 0" run "$fn" "$sh" "$PERMS" "com.b${NL}" com.a com.b com.d
    count 2 "grant com.b $CAM"; skipped 1 com.b; recorded "com.a com.b com.d "
    clean
    verdict "G5b a placeholder pm refused at sign-in gets its grants when the real APK arrives"

    why=""; CALLS="$signin${NL}: > \"\$D/notinstalled\"${NL}grant_perms_for $UIDV com.foo 0" run "$fn" "$sh" "com.foobar $CAM${NL}com.foo $CAM$NL" "com.foo$NL" com.foobar
    count 2 "grant com.foo $CAM"; count 1 "grant com.foobar $CAM"; skipped 0 com.foo; skipped 0 com.foobar
    clean
    verdict "G6 a recorded com.foobar does not make com.foo skip"

    why=""; CALLS="$signin${NL}grant_perms_for $UIDV com.g 0${NL}grant_perms_for $UIDV com.g 0" run "$fn" "$sh" "com.a $CAM$NL" "" com.a com.g
    count 1 "grant com.g $INET"; recorded "com.a com.g "; skipped 2 com.g
    clean
    verdict "G8 a package with no line gets the INTERNET default at sign-in, records it, and is not re-granted by an update"
  done
  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "grant_perms_for once per session: $SUT"
echo "shells: $SHELLS"
suite "$SUT"; rc=$?
[ "$rc" = 2 ] && exit 2
[ "$rc" = 0 ] || FAILED=1

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT):"
  mutate() {  # <label> <sed program>
    local label="$1" prog="$2" mf r
    mf=$(mktemp -p "$W") || { MFAIL=1; return; }
    if ! sed "$prog" "$SUT" > "$mf"; then printf '  ERR   %-64s sed program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    suite "$mf" quiet >/dev/null 2>&1; r=$?
    case "$r" in
      0) printf '  XX    %-64s SURVIVED\n' "$label"; MFAIL=1 ;;
      1) printf '  ok    %-64s convicted\n' "$label" ;;
      *) printf '  ERR   %-64s harness error (rc=%s), not a conviction\n' "$label" "$r"; MFAIL=1 ;;
    esac
    command rm -f "$mf"
  }
  mutate 'M1 the skip test is removed' \
    's/^  if \[ -n "\$pkgfilter" \] \&\& \[ "\$_gfirst" != 1 \] \&\& grep -qxF -- "\$pkgfilter" "\$_grec" 2>\/dev\/null; then$/  if false; then/'
  mutate 'M2 the record is never written' \
    '/^grant_perms_for() {$/,/^}$/s/^    done >> "\$_grec" 2>\/dev\/null$/    done >\/dev\/null/'
  mutate 'M3 the skip test matches a prefix (grep -qF)' \
    's/grep -qxF -- "\$pkgfilter" "\$_grec"/grep -qF -- "$pkgfilter" "$_grec"/'
  mutate 'M4 the first-install override is removed' \
    's/\[ -n "\$pkgfilter" \] \&\& \[ "\$_gfirst" != 1 \] \&\& grep/[ -n "$pkgfilter" ] \&\& grep/'
  mutate 'M5 the INTERNET default is not covered by the skip' \
    's/^  \[ "\$_gskip" = 1 \] || for dpkg in/  for dpkg in/; s/^  if \[ "\$_gskip" != 1 \]; then$/  if true; then/'
  mutate 'M6 roam-in no longer clears the record' \
    '/^      rm -f "\$STATE\/.granted.\$uid" 2>>"\$LOG"/d'
  mutate 'M7 the record is written whether or not pm grant succeeded' \
    's/>\/dev\/null 2>&1 \&\& { echo x >> "\$_gn"; echo "\$gpkg" >> "\$_gok"; }$/>\/dev\/null 2>\&1; echo "$gpkg" >> "$_gok"/'
  mutate "M8 the INTERNET default's success is not recorded" \
    's/{ dflt=\$((dflt+1)); echo "\$dpkg" >> "\$_gok"; }/dflt=$((dflt+1))/'
  [ -z "${MFAIL:-}" ] || FAILED=1
fi
[ -z "${FAILED:-}" ] || exit 1
exit 0
