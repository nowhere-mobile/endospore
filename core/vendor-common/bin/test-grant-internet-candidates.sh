#!/usr/bin/env bash
# test-grant-internet-candidates.sh [<nowhere_roamd.sh>] [--mutate] -- the candidates of the §B row "A roamed app can
# come back with GrapheneOS's Network permission off, so on a working network it reports "No Internet Connection""
# (NWP-20261102-25), run against the REAL grant_perms_for, and the fix for candidate (2) (NWP-20261123-08).
#
# WHY THIS IS COMMITTED. On frankel 0.5.51 one roamed app had no Network permission on a working network, and the
# logs did not show which path dropped it. The row names three candidates:
#   (1) a captured `deny:android.permission.INTERNET` line for the app, honoured at every sign-in;
#   (2) a sign-in grant that pm accepts on the archived placeholder is recorded in $STATE/.granted.<uid>, and the
#       app's real install by another installer (no hold, no materialised record: DECLINES 0) then skips its grant
#       phase, the INTERNET default included;
#   (3) an install path whose package-filtered grant call never comes.
# Two pm answers decide them, and the code cannot settle either. They are switches here:
#   A = `pm grant` on an archived placeholder succeeds (ok) or fails (fail);
#   B = `pm list packages --user <u> -3` lists an archived placeholder (listed) or not (unlisted; then only -a does).
# Fixture premise: an install over a placeholder arrives with INTERNET not granted (a grant pm took on the placeholder
# does not carry across the unarchive). Whether pm keeps it is a handset question; the suite does not switch it.
# Candidate (1)'s placeholder form is not a case: ProfileActivity.capturePerms writes a deny line only for a package
# getPackageInfo(pkg, GET_PERMISSIONS) returns, and that call throws for an archived package (NWP-20260903-23).
#
# The fix: grant_perms_for reads the third-party list once per call and records only the granted packages that list
# holds. The R cases pin it: a failed list records nothing, even after partial output; the skip path runs no pm; one
# list read per call; a real app is still recorded and its update skips; and the match is whole-line.
#
# The N cases (NWP-20261201-19): a profile with no capture yet has no nowhere-perms, and an install in that session is
# a form of (1) and (3). The package-filtered call used to return before the INTERNET default, and the sign-out then
# captured the unset Network as a deny line. Now that call runs the default; a sign-in call with no file still does not.
#
#   bash test-grant-internet-candidates.sh            # the table and the cases
#   bash test-grant-internet-candidates.sh --mutate   # ... plus mutations that must each CONVICT under every shell
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

ALLSHELLS="bash sh"
for s in mksh dash; do command -v "$s" >/dev/null 2>&1 && ALLSHELLS="$ALLSHELLS $s"; done

UIDV=15
PFREL="data/user/$UIDV/com.nowhere.chooser/files/nowhere-perms"
CAM=android.permission.CAMERA
INET=android.permission.INTERNET
SKIP="] GRANT (%s) -> skipped: granted this session, not a first install"

# POSIX sh. $D/real: packages with code. $D/ph: archived placeholders. $D/A, $D/B: the two switches. $D/granted is a
# log of `+ <pkg> <perm>` / `- <pkg> <perm>`; the last line for a pair is its state. Appends only, so the concurrent
# grant subshells cannot lose a line. Every pm list call adds a `list` line to $D/calls.
STUBS='
pm_ok() { grep -qxF -- "$1" "$D/real" 2>/dev/null && return 0; grep -qxF -- "$1" "$D/ph" 2>/dev/null && [ "$(cat "$D/A")" = ok ]; }
pm() {
  case "$1 $2" in
    "list packages")
      echo "list $*" >> "$D/calls"
      [ -e "$D/listfail" ] && return 1
      [ -e "$D/listpartial" ] && { echo "package:$(head -1 "$D/real")"; return 1; }
      [ -e "$D/late" ] && cp "$D/late" "$PFPATH"
      sed "s/^/package:/" "$D/real"
      case " $* " in *" -a "*) sed "s/^/package:/" "$D/ph" ;; *) [ "$(cat "$D/B")" = listed ] && sed "s/^/package:/" "$D/ph" ;; esac
      return 0 ;;
    "grant --user")  echo "grant $4 $5"  >> "$D/calls"; pm_ok "$4" || return 1; echo "+ $4 $5" >> "$D/granted" ;;
    "revoke --user") echo "revoke $4 $5" >> "$D/calls"; pm_ok "$4" || return 1; echo "- $4 $5" >> "$D/granted" ;;
    "set-permission-flags --user") shift 3; echo "flags $*" >> "$D/calls" ;;
    *) echo "pm $*" >> "$D/unexpected"; return 1 ;;
  esac
}
cmd() { echo "cmd $*" >> "$D/calls"; return 0; }
# The real APK arrives over the placeholder; by the fixture premise its INTERNET is not granted.
install_app() {
  grep -vxF -- "$1" "$D/ph" > "$D/ph.new"; mv "$D/ph.new" "$D/ph"
  echo "$1" >> "$D/real"
  echo "- $1 android.permission.INTERNET" >> "$D/granted"
}
step() { echo "-- $1" >> "$D/calls"; }
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

# run <fn> <shell> <A> <B> <perms> <real> <ph> -- the CALLS lines run in one fresh $STATE, as on the device. Sets D.
# <real> and <ph> are newline-terminated package lists. <perms> NOFILE leaves nowhere-perms absent; its directory exists.
run() {
  local fn="$1" sh="$2" va="$3" vb="$4" content="$5" real="$6" ph="$7" pf
  D=$(mktemp -d -p "$W"); pf="$D/root/$PFREL"
  mkdir -p "$D/state" "${pf%/*}"
  [ "$content" = NOFILE ] || printf '%s' "$content" > "$pf"
  printf '%s' "$real" > "$D/real"
  printf '%s' "$ph" > "$D/ph"
  echo "$va" > "$D/A"; echo "$vb" > "$D/B"
  : > "$D/granted"
  {
    printf 'D=%s\nTROOT=%s\nSTATE=%s\nLOG=%s\nPFPATH=%s\n' "$D" "$D/root" "$D/state" "$D/log" "$pf"
    printf '%s\n' "$STUBS"
    cat "$fn"
    printf '%s\n' "$CALLS"
  } > "$D/run.sh"
  "$sh" "$D/run.sh" >/dev/null 2>&1
  touch "$D/calls" "$D/log" "$D/unexpected"
}

# inet <pkg> -> "granted" or "NOT granted": the last +/- line for the pair.
inet() {
  local last; last=$(grep -F -- " $1 $INET" "$D/granted" | grep -xE -- "[+-] $1 $INET" | tail -1)
  case "$last" in "+ "*) echo granted ;; *) echo "NOT granted" ;; esac
}
count() { local got; got=$(grep -cxF -- "$2" "$D/calls"); [ "$got" = "$1" ] || why="$why want $1 x '$2', got $got;"; }
recorded() {  # recorded <expected sorted pkgs, space separated>
  local got; got=$(sort "$D/state/.granted.$UIDV" 2>/dev/null | tr '\n' ' ')
  [ "$got" = "$1" ] || why="$why .granted is '$got', want '$1';"
}
skipped() { local want="$1" pk="$2" got; got=$(grep -cF -- "$(printf "$SKIP" "$pk")" "$D/log"); [ "$got" = "$want" ] || why="$why want $want skip line(s) for $pk, got $got;"; }
# lists_per_step <want...> -- the number of `list` lines in each step, in order ("-- " lines open a step).
lists_per_step() {
  local got; got=$(awk '/^-- /{if(s)printf "%d ", n; s=1; n=0; next} /^list /{n++} END{if(s)printf "%d ", n}' "$D/calls")
  got="${got% }"
  [ "$got" = "$*" ] || why="$why pm list per call is '$got', want '$*';"
}
logged() { local got; got=$(grep -cF -- "$1" "$D/log"); [ "$got" = 1 ] || why="$why want one log line '$1', got $got;"; }
quiet_after() { local got; got=$(sed -n "/^-- $1\$/,\$p" "$D/calls" | sed 1d); [ -z "$got" ] || why="$why the $1 call ran: $(printf '%s' "$got" | tr '\n' ';');"; }
no_flags() { local got; got=$(grep -c '^flags ' "$D/calls"); [ "$got" = 0 ] || why="$why want no set-permission-flags, got $got;"; }
declined_once() { local got; got=$(grep -cxF -- "$1" "$D/state/.declined.$UIDV" 2>/dev/null); [ "$got" = 1 ] || why="$why want $1 once in .declined, got '$got';"; }
clean() { [ -s "$D/unexpected" ] && why="$why unmodelled: $(tr '\n' ';' < "$D/unexpected");"; [ ! -e "$D/state/.grantok" ] || why="$why .grantok left behind;"; command rm -rf "$D"; }

suite() {  # suite <roamd.sh> <shells> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" shells="$2" quiet="${3:-}" fn p=0 x=0 sh rc NL why got want note va vb c
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  verdict() { if [ -z "$why" ]; then ok "$1 [$sh]"; else no "$1 [$sh] --$why"; fi; }
  row() { [ -n "$quiet" ] || printf '  %-4s A=%-4s B=%-8s INTERNET %-11s %s\n' "$1" "$va" "$vb" "$2" "$3" | sed 's/ *$//'; }
  fn=$(mktemp -p "$W") || return 2
  prep_fn "$f" "$fn"; rc=$?
  [ "$rc" = 0 ] || return 2
  NL=$'\n'
  local signin="step signin${NL}grant_perms_for $UIDV" X=com.x R=com.r Y=com.y
  local DENY="$X deny:$INET${NL}$X $CAM${NL}$R $CAM$NL" GRANTLINE="$X $CAM${NL}$R $CAM$NL" NOLINE="$R $CAM$NL"
  local INSTALL="install_app $X${NL}step install${NL}grant_perms_for $UIDV $X 0"

  for sh in $shells; do
    [ -n "$quiet" ] || printf '  [%s] the candidates (com.x is the app; "want" is the outcome this code must give)\n' "$sh"
    for va in ok fail; do
      for vb in unlisted listed; do
        # C1a: a captured deny line, the app installed at sign-in.
        why=""; CALLS="$signin" run "$fn" "$sh" "$va" "$vb" "$DENY" "$X$NL$R$NL" ""
        got=$(inet $X); row C1a "$got" "(a captured deny line: the user's Network-off, by design)"
        [ "$got" = "NOT granted" ] || why="$why INTERNET is $got;"; clean
        verdict "C1a A=$va B=$vb a deny line keeps Network off"

        # C1b: a captured deny line, the app a placeholder at sign-in, then its first install (a materialise).
        why=""; CALLS="$signin${NL}install_app $X${NL}step install${NL}grant_perms_for $UIDV $X 1" run "$fn" "$sh" "$va" "$vb" "$DENY" "$R$NL" "$X$NL"
        got=$(inet $X); row C1b "$got" "(the deny line, honoured at the first install)"
        [ "$got" = "NOT granted" ] || why="$why INTERNET is $got;"; clean
        verdict "C1b A=$va B=$vb a deny line keeps Network off at a first install"

        # C2: a captured CAMERA line for the app, a placeholder at sign-in; another installer installs it (DECLINES 0).
        want=granted; note=""
        [ "$va" = ok ] && [ "$vb" = listed ] && { want="NOT granted"; note="(the filter cannot tell: pm lists the placeholder with -3)"; }
        why=""; CALLS="$signin${NL}$INSTALL" run "$fn" "$sh" "$va" "$vb" "$GRANTLINE" "$R$NL" "$X$NL"
        got=$(inet $X); row C2 "$got" "$note"
        [ "$got" = "$want" ] || why="$why INTERNET is $got, want $want;"
        if [ "$want" = granted ]; then count 2 "grant $X $CAM"; skipped 0 $X; else skipped 1 $X; fi
        lists_per_step "1 $([ "$want" = granted ] && echo 1 || echo 0)"
        clean
        verdict "C2 A=$va B=$vb a sign-in grant on the placeholder"

        # C2b: as C2, but no captured line for the app: only the INTERNET default can reach it.
        want=granted; note=""
        [ "$va" = ok ] && [ "$vb" = listed ] && { want="NOT granted"; note="(the filter cannot tell: pm lists the placeholder with -3)"; }
        why=""; CALLS="$signin${NL}$INSTALL" run "$fn" "$sh" "$va" "$vb" "$NOLINE" "$R$NL" "$X$NL"
        got=$(inet $X); row C2b "$got" "$note"
        [ "$got" = "$want" ] || why="$why INTERNET is $got, want $want;"; clean
        verdict "C2b A=$va B=$vb the INTERNET default on the placeholder"

        # C3: as C2, but the install's package-filtered call never comes.
        why=""; CALLS="$signin${NL}install_app $X" run "$fn" "$sh" "$va" "$vb" "$GRANTLINE" "$R$NL" "$X$NL"
        got=$(inet $X); row C3 "$got" "(no call after the install: off until the next sign-in)"
        [ "$got" = "NOT granted" ] || why="$why INTERNET is $got;"; clean
        verdict "C3 A=$va B=$vb no grant call after the install"
      done
    done

    # R1: the list fails. Nothing is recorded, so the next call runs the grant phase again.
    why=""; CALLS="touch \"\$D/listfail\"${NL}$signin${NL}step update${NL}grant_perms_for $UIDV $R 0" run "$fn" "$sh" ok unlisted "$NOLINE" "$R$NL" ""
    [ -s "$D/state/.granted.$UIDV" ] && why="$why .granted holds '$(tr '\n' ' ' < "$D/state/.granted.$UIDV")';"
    count 2 "grant $R $CAM"; skipped 0 $R; clean
    verdict "R1 a failed list records nothing, and the next call grants again"

    # R1b: the list prints part of its output, then fails. The part is not the list: nothing is recorded.
    why=""; CALLS="touch \"\$D/listpartial\"${NL}$signin${NL}step update${NL}grant_perms_for $UIDV $R 0" run "$fn" "$sh" ok unlisted "$NOLINE" "$R$NL" ""
    [ -s "$D/state/.granted.$UIDV" ] && why="$why .granted holds '$(tr '\n' ' ' < "$D/state/.granted.$UIDV")';"
    count 2 "grant $R $CAM"; skipped 0 $R; clean
    verdict "R1b a list that fails after partial output records nothing"

    # R2 + R4: a real app is recorded at sign-in; its update heal skips and runs no pm at all.
    why=""; CALLS="$signin${NL}step update${NL}grant_perms_for $UIDV $R 0" run "$fn" "$sh" ok unlisted "$NOLINE" "$R$NL" ""
    recorded "$R "; skipped 1 $R; count 1 "grant $R $CAM"
    got=$(sed -n '/^-- update$/,$p' "$D/calls" | sed 1d)
    [ -z "$got" ] || why="$why the skipped call ran: $(printf '%s' "$got" | tr '\n' ';');"
    lists_per_step 1 0; clean
    verdict "R2 a recorded real app's update skips and runs no pm"

    # R3: one list read per call that runs the grant phase (sign-in, a first install, a filtered call).
    why=""; CALLS="$signin${NL}install_app $X${NL}step first${NL}grant_perms_for $UIDV $X 1${NL}step other${NL}grant_perms_for $UIDV com.y 0" run "$fn" "$sh" ok unlisted "$GRANTLINE" "$R$NL" "$X$NL"
    lists_per_step 1 1 1; clean
    verdict "R3 exactly one pm list per call"

    # R5: whole-line match -- a listed com.foobar does not record the placeholder com.foo.
    why=""; CALLS="$signin" run "$fn" "$sh" ok unlisted "com.foo $CAM${NL}com.foobar $CAM$NL" "com.foobar$NL" "com.foo$NL"
    count 1 "grant com.foo $CAM"; recorded "com.foobar "; clean
    verdict "R5 the record's list match is whole-line"

    # N1: no nowhere-perms, a first-session install reaches the INTERNET default, once, and is recorded.
    why=""; CALLS="$INSTALL" run "$fn" "$sh" ok unlisted NOFILE "$R$NL" "$X$NL"
    got=$(inet $X); [ "$got" = granted ] || why="$why INTERNET is $got;"
    count 1 "grant $X $INET"; recorded "$X "
    logged "] GRANT ($X) -> 0 perms (no file) + 1 INTERNET default(s) (user $UIDV)"; clean
    verdict "N1 no file: an install gets the INTERNET default and is recorded"

    # N2: its update's heal (DECLINES 0) reads the record and runs no pm.
    why=""; CALLS="$INSTALL${NL}step update${NL}grant_perms_for $UIDV $X 0" run "$fn" "$sh" ok unlisted NOFILE "$R$NL" "$X$NL"
    count 1 "grant $X $INET"; skipped 1 $X; quiet_after update; lists_per_step 1 0; clean
    verdict "N2 no file: an update's heal skips and runs no pm"

    # N2b: as N2 with DECLINES 1 twice: the .declined marker makes the second call an update, not a first install.
    why=""; CALLS="install_app $X${NL}step first${NL}grant_perms_for $UIDV $X 1${NL}step second${NL}grant_perms_for $UIDV $X 1" run "$fn" "$sh" ok unlisted NOFILE "$R$NL" "$X$NL"
    count 1 "grant $X $INET"; skipped 1 $X; quiet_after second; clean
    verdict "N2b no file: a second DECLINES 1 call is not a first install"

    # N3: the default stays limited to the package of the call.
    why=""; CALLS="$INSTALL" run "$fn" "$sh" ok unlisted NOFILE "$Y$NL" "$X$NL"
    count 1 "grant $X $INET"; count 0 "grant $Y $INET"; recorded "$X "; clean
    verdict "N3 no file: a filtered call grants nothing to another package"

    # N4: a sign-in call with no file is unchanged. It reads no list and grants nothing.
    why=""; CALLS="$signin" run "$fn" "$sh" ok unlisted NOFILE "$X$NL$R$NL" ""
    count 0 "grant $X $INET"; count 0 "grant $R $INET"; recorded ""; lists_per_step 0
    logged "] GRANT -> 0 perms (no file, user $UIDV)"; clean
    verdict "N4 no file: a sign-in call grants nothing"

    # N5: a first install's declines pass finds nothing to re-flag, and the marker is still written.
    why=""; CALLS="install_app $X${NL}step first${NL}grant_perms_for $UIDV $X 1" run "$fn" "$sh" ok unlisted NOFILE "$R$NL" "$X$NL"
    no_flags; declined_once $X; clean
    verdict "N5 no file, DECLINES 1: no flags call, and the package is marked once"

    # N5b: a file a capture writes during the call does not start the flags pass.
    why=""; CALLS="printf '%s\n' '$X flags:user-set:$CAM' > \"\$D/late\"${NL}install_app $X${NL}step first${NL}grant_perms_for $UIDV $X 1" run "$fn" "$sh" ok unlisted NOFILE "$R$NL" "$X$NL"
    no_flags; declined_once $X; clean
    verdict "N5b no file at the start of the call: a file that appears later starts no flags pass"

    # N6: the -3 list fails on the no-file path: the default has no list to run on, and nothing is recorded.
    why=""; CALLS="touch \"\$D/listfail\"${NL}$INSTALL" run "$fn" "$sh" ok unlisted NOFILE "$R$NL" "$X$NL"
    [ -s "$D/state/.granted.$UIDV" ] && why="$why .granted holds '$(tr '\n' ' ' < "$D/state/.granted.$UIDV")';"
    lists_per_step 1; logged "] GRANT ($X) -> 0 perms (no file) + 0 INTERNET default(s) (user $UIDV)"; clean
    verdict "N6 no file: a failed list records nothing"
  done
  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "grant_perms_for and the Network-permission candidates: $SUT"
echo "shells: $ALLSHELLS"
suite "$SUT" "$ALLSHELLS"; rc=$?
[ "$rc" = 2 ] && exit 2
[ "$rc" = 0 ] || FAILED=1

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT under every shell):"
  mutate() {  # <label> <sed program>
    local label="$1" prog="$2" mf r msh
    mf=$(mktemp -p "$W") || { MFAIL=1; return; }
    if ! sed "$prog" "$SUT" > "$mf"; then printf '  ERR   %-58s sed program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-58s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    for msh in $ALLSHELLS; do
      suite "$mf" "$msh" quiet >/dev/null 2>&1; r=$?
      case "$r" in
        0) printf '  XX    %-58s SURVIVED [%s]\n' "$label" "$msh"; MFAIL=1 ;;
        1) printf '  ok    %-58s convicted [%s]\n' "$label" "$msh" ;;
        *) printf '  ERR   %-58s harness error (rc=%s), not a conviction [%s]\n' "$label" "$r" "$msh"; MFAIL=1 ;;
      esac
    done
    command rm -f "$mf"
  }
  G='/^grant_perms_for() {$/,/^}$/'
  mutate 'M1 the list filter dropped (sort -u "$_gok" >> "$_grec")' \
    "$G"'{/^  if \[ -n "\$_g3" \]; then$/,/^  fi$/c\
  sort -u "$_gok" >> "$_grec" 2>/dev/null
}'
  mutate 'M2 the list read twice' \
    "$G"'s/^    _g3="\${NL}\${_g3}\${NL}"$/    _g3="${NL}$(pm list packages --user "$uid" -3 2>\/dev\/null | sed "s\/^package:\/\/")${NL}"/'
  mutate 'M3 an empty list records everything' \
    "$G"'{/^  if \[ -n "\$_g3" \]; then$/,/^  fi$/s/^  fi$/  else sort -u "$_gok" >> "$_grec" 2>\/dev\/null; fi/}'
  mutate 'M4 the list match is a prefix' \
    "$G"'s/^      case "\$_g3" in \*"\${NL}\${dpkg}\${NL}"\*)/      case "$_g3" in *"${NL}${dpkg}"*)/'
  mutate "M5 pm's exit status is hidden behind sed" \
    "$G"'s/^    _g3=\$(pm list packages --user "\$uid" -3 2>\/dev\/null) || _g3=""$/    _g3=$(pm list packages --user "$uid" -3 2>\/dev\/null | sed "s\/^package:\/\/")/'
  mutate 'M-N1 the early return restored for a filtered call (N1)' \
    "$G"'s/^    _gnofile=1$/    return 0/'
  mutate 'M-N2 the pkgfilter skip removed from the default loop (N3)' \
    "$G"'{/^    \[ -n "\$pkgfilter" \] && \[ "\$dpkg" != "\$pkgfilter" \] && continue$/d;}'
  mutate 'M-N3 the sign-in no-file path runs the default (N4)' \
    "$G"'{/^    \[ -n "\$pkgfilter" \] || { echo "\[roamd\] GRANT -> 0 perms (no file, user /d;}'
  mutate 'M-N4 the record skipped on the no-file path (N2)' \
    "$G"'s/^  if \[ -n "\$_g3" \]; then$/  if [ -n "$_g3" ] \&\& [ "$_gnofile" != 1 ]; then/'
  mutate 'M-N5 the .declined marker not written on the no-file path (N2b, N5)' \
    "$G"'s/^      _dok=1; echo "\$pkgfilter" >> "\$_dmark" 2>\/dev\/null /      _dok=1; [ "$_gnofile" = 1 ] || echo "$pkgfilter" >> "$_dmark" 2>\/dev\/null /'
  mutate 'M-N6 the flags pass not turned off on the no-file path (N5b)' \
    "$G"'{/^  \[ "\$_gnofile" = 1 \] \&\& _dok=0 /d;}'
  [ -z "${MFAIL:-}" ] || FAILED=1
fi
[ -z "${FAILED:-}" ] || exit 1
exit 0
