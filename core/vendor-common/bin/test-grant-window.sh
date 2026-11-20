#!/usr/bin/env bash
# test-grant-window.sh [<nowhere_roamd.sh>] [--ref <roamd.sh>] [--mutate] -- grant_perms_for's rolling window of 6
# (NWP-20261210-09).
#
# WHY THIS IS COMMITTED. A nearly empty profile takes about 85 s from submit to home (docs/backlog.md, section B, "A
# nearly empty profile takes about 85 s from submit to home; target under 60 s"); cause (5) is `TIMING grant-135
# 5784ms for 136 permissions`. `pm grant` takes ONE package and ONE permission, so the calls cannot be merged. Before
# this slice the per-line calls and the declines ran in BATCHES of 6 (each batch waited for its slowest call) and the
# INTERNET default ran one `pm grant` at a time. Now every call goes through one rolling FIFO window of 6 (gwin_add).
# This suite proves the change keeps the same calls, counts, record and ordering barriers, and that the window rolls.
#
#   G1 the multiset of (verb, package, permission) calls equals the reference's on a mixed fixture (grant, appop,
#      deny, flags and foreground lines, ten third-party packages with no line), and so does the GRANT line, apart
#      from its date. The reference is origin/main's grant_perms_for (`git show`), or --ref <file>; with neither,
#      only the committed expected set below is compared.
#   G2 never more than 6 calls in flight; the INTERNET default reaches more than 1 in flight.
#   G3 rolling, not batched: the SIXTH call sleeps 2 s, the others 0.1 s; at least 5 other calls start and end
#      inside it (the batch barrier gives 0).
#   G4 a failing default grant is not counted in `+ N INTERNET default(s)` and is not in .granted.<uid>; a failing
#      per-line grant is not in `-> N perms`; the GRANT line equals the reference's.
#   G5 every successful default's package is in .granted.<uid> while every default call is slow.
#   G6 the first flags call starts after the last grant, deny revoke, appops and default call ended.
#   G7 the sign-in call logs TIMING grant-lines, grant-list3, grant-internet and grant-declines once each (a sign-in
#      with no nowhere-perms file too); a PKGFILTER call logs none of them.
#   G2 (the default's >1 in flight), G3 and G7 FAIL against origin/main's roamd (pass it as the first argument).
#
# The function (and gwin_add, when present) is EXTRACTED by anchor, never copied; its nowhere-perms path is re-rooted
# under a scratch dir as test-grant-internet-default.sh does. `pm` and `cmd` are shell-function stubs: each call
# appends `S <verb> <pkg> <args>`, sleeps for its package's entry in a delay table, and appends `E ...` to one calls
# file (O_APPEND, so the file order is the event order). A `<verb> <pkg> <perm>` line in a fail file fails that call.
# Every case runs under bash and sh, plus dash and mksh where installed.
#
#   bash test-grant-window.sh            # the cases
#   bash test-grant-window.sh --mutate   # ... plus mutants that must each be CONVICTED under every shell
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

MUTATE=no; SUT=""; REF=""; _want_ref=no
for a in "$@"; do
  if [ "$_want_ref" = yes ]; then REF="$a"; _want_ref=no; continue; fi
  case "$a" in --mutate) MUTATE=yes ;; --ref) _want_ref=yes ;; *) SUT="$a" ;; esac
done
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="${SUT:-$HERE/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
if [ -z "$REF" ]; then
  REF="$W/ref-roamd.sh"
  git -C "$HERE" show origin/main:core/vendor-common/bin/nowhere_roamd.sh > "$REF" 2>/dev/null || REF=""
  [ -n "$REF" ] && [ -s "$REF" ] || REF=""
fi
[ -z "$REF" ] || [ -f "$REF" ] || { echo "no such reference: $REF" >&2; exit 2; }

SHELLS="bash sh"
for s in dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

UIDV=15
PFREL="data/user/$UIDV/com.nowhere.chooser/files/nowhere-perms"
INET=android.permission.INTERNET

# POSIX sh stubs. `_dl` reads the package's delay (default 0.02 s); `_fl` is true for a call the fail file names.
STUBS='
_dl() { while read -r _p _s; do [ "$_p" = "$1" ] && { echo "$_s"; return 0; }; done < "$D/delay"; echo 0.02; }
_fl() { grep -qxF -- "$1 $2 $3" "$D/fail" 2>/dev/null; }
_ev() {
  echo "S $1 $2 $3" >> "$D/calls"
  sleep "$(_dl "$2")"
  echo "E $1 $2 $3" >> "$D/calls"
  ! _fl "$1" "$2" "${3%% *}"
}
pm() {
  case "$1 $2" in
    "list packages") sed "s/^/package:/" "$D/pkgs"; return 0 ;;
    "grant --user")  _ev grant "$4" "$5" ;;
    "revoke --user") _ev revoke "$4" "$5" ;;
    "set-permission-flags --user") _ev flags "$4" "$5${6:+ $6}${7:+ $7}" ;;
    *) echo "pm $*" >> "$D/unexpected"; return 1 ;;
  esac
}
cmd() {
  case "$1 $2 $3" in
    "appops set --user") _ev appops "$5" "$6 $7" ;;
    *) echo "cmd $*" >> "$D/unexpected"; return 1 ;;
  esac
}
'

# prep_fn <roamd.sh> <out>: _ms, _tlog, gwin_add (when present) and grant_perms_for, re-rooted. 0 ok, 2 harness error.
prep_fn() {
  local sut="$1" out="$2" raw
  raw=$(mktemp -p "$W")
  sed -n '/^grant_perms_for() {$/,/^}$/p' "$sut" > "$raw"
  if [ ! -s "$raw" ] || [ "$(head -1 "$raw")" != 'grant_perms_for() {' ] || [ "$(tail -1 "$raw")" != '}' ]; then
    echo "EXTRACTION FAILED: grant_perms_for() { ... } not found in $sut" >&2; return 2
  fi
  { grep '^_ms() { ' "$sut"; grep '^_tlog() { ' "$sut"
    sed -n '/^gwin_add() {$/,/^}$/p' "$sut"
    sed 's#PF="/data/user/#PF="$TROOT/data/user/#' "$raw"; } > "$out"
  if [ "$(grep -c '^_ms() { ' "$out")" != 1 ] || [ "$(grep -c '^_tlog() { ' "$out")" != 1 ]; then
    echo "EXTRACTION FAILED: _ms or _tlog not found once in $sut" >&2; return 2
  fi
  if [ "$(grep -c 'PF="\$TROOT/data/user/' "$out")" != 1 ] || [ "$(grep -c '/data/user/' "$out")" != 1 ]; then
    echo "REWRITE FAILED: want exactly one PF=\"/data/user/ assignment in grant_perms_for of $sut" >&2; return 2
  fi
  bash -n "$out" || { echo "EXTRACTION FAILED: the extract does not parse ($sut)" >&2; return 2; }
  return 0
}

# newcase: a fresh case dir; prints it. Fixture files: perms (nowhere-perms; "-" = no file), pkgs (the -3 list),
# delay (<pkg> <secs>), fail (<verb> <pkg> <perm>).
newcase() {
  local d
  d=$(mktemp -d -p "$W") || return 2
  mkdir -p "$d/state" "$d/${PFREL%/*}"
  : > "$d/calls"; : > "$d/pkgs"; : > "$d/delay"; : > "$d/fail"; : > "$d/log"
  echo "$d"
}

# run_fn <fn> <shell> <dir> <args...>: run grant_perms_for <args> once. Shell errors go to <dir>/err.
run_fn() {
  local fn="$1" sh="$2" d="$3" r
  shift 3
  r="$d/run.sh"
  { printf "D='%s'\nTROOT='%s'\nSTATE='%s'\nLOG='%s'\n" "$d" "$d" "$d/state" "$d/log"
    printf '%s\n' "$STUBS"
    cat "$fn"
    printf 'grant_perms_for'; printf ' %s' "$@"; printf '\n'; } > "$r"
  "$sh" "$r" > "$d/out" 2> "$d/err"
}

# Helpers over a case dir.
slines() { sed -n 's/^S //p' "$1/calls" | sort; }                                   # the call multiset
gline() { sed -n 's/^\(\[roamd\] GRANT.*(user [0-9]*)\) .*$/\1/p' "$1/log"; }         # the GRANT line, no date
maxin() {  # maxin <dir> [<awk regex on the call>]: the most calls in flight at once
  awk -v re="${2:-.}" '{ c=$0; sub(/^[SE] /, "", c) } c ~ re && $1=="S" { n++; if (n>m) m=n } c ~ re && $1=="E" { n-- } END { print m+0 }' "$1/calls"
}
tcount() { local c; c=$(grep -c "\[roamd\] TIMING $2 [0-9-]*ms " "$1/log" 2>/dev/null); echo "${c:-0}"; }

PASS=0; FAILN=0
ok() { PASS=$((PASS + 1)); [ "$QUIET" = yes ] || echo "  ok    $1 [$SH]"; }
no() { FAILN=$((FAILN + 1)); echo "  FAIL  $1 [$SH]"; }
harness() { local d="$1"
  if [ -s "$d/err" ] || [ -s "$d/unexpected" ] 2>/dev/null; then
    echo "  HARNESS ERROR [$SH]: $(cat "$d/err" "$d/unexpected" 2>/dev/null | head -3)"; HARN=1
  fi
}

# The G1 fixture. Expected calls (frozen from origin/main's function at 63edcd368, the base of NWP-20261210-09).
g1_fixture() {
  local d="$1" i
  cat > "$d/$PFREL" <<EOF
com.a android.permission.CAMERA
com.a android.permission.READ_CONTACTS
com.b appop:android:system_alert_window
com.b deny:$INET
com.c flags:user-set:android.permission.POST_NOTIFICATIONS
com.c flags:user-set,user-fixed:android.permission.READ_CALENDAR
com.c flags:user-fixed:android.permission.ACCESS_FINE_LOCATION
com.d android.permission.ACCESS_FINE_LOCATION
com.d $INET
com.e android.permission.RECORD_AUDIO
EOF
  printf '%s\n' com.a com.b com.c com.d > "$d/pkgs"
  for i in 01 02 03 04 05 06 07 08 09 10; do echo "p$i" >> "$d/pkgs"; done
}
G1_WANT='appops com.a CAMERA foreground
appops com.b android:system_alert_window allow
appops com.d FINE_LOCATION foreground
appops com.e RECORD_AUDIO foreground
flags com.c android.permission.ACCESS_FINE_LOCATION user-fixed
flags com.c android.permission.POST_NOTIFICATIONS user-set
flags com.c android.permission.READ_CALENDAR user-set user-fixed
grant com.a android.permission.CAMERA
grant com.a android.permission.INTERNET
grant com.a android.permission.READ_CONTACTS
grant com.c android.permission.INTERNET
grant com.d android.permission.ACCESS_FINE_LOCATION
grant com.d android.permission.INTERNET
grant com.e android.permission.RECORD_AUDIO
grant p01 android.permission.INTERNET
grant p02 android.permission.INTERNET
grant p03 android.permission.INTERNET
grant p04 android.permission.INTERNET
grant p05 android.permission.INTERNET
grant p06 android.permission.INTERNET
grant p07 android.permission.INTERNET
grant p08 android.permission.INTERNET
grant p09 android.permission.INTERNET
grant p10 android.permission.INTERNET
revoke com.b android.permission.INTERNET
revoke com.c android.permission.ACCESS_FINE_LOCATION
revoke com.c android.permission.POST_NOTIFICATIONS
revoke com.c android.permission.READ_CALENDAR'
G1_GRANT="[roamd] GRANT -> 7 perms + 12 INTERNET default(s) + 3 declined kept (0 refused, 0 grant(s) withheld, declines on) + 0 left to the SMS role (user $UIDV)"

# suite <sut> <shell> [<only case ids, space separated>]: every case under one shell. Exit 1 on any FAIL, 2 harness.
suite() {
  local sut="$1" sh="$2" only=" ${3:-G1 G2 G3 G4 G5 G6 G7} " fn rf d r e got i lastx firstf inside s6 e6
  SH="$sh"; PASS=0; FAILN=0; HARN=0
  fn=$(mktemp -p "$W"); prep_fn "$sut" "$fn" || return 2
  rf=""
  if [ -n "$REF" ]; then rf=$(mktemp -p "$W"); prep_fn "$REF" "$rf" || return 2; fi

  case "$only" in *" G1 "*)
    d=$(newcase) || return 2; g1_fixture "$d"; run_fn "$fn" "$sh" "$d" "$UIDV"; harness "$d"
    got=$(slines "$d")
    if [ "$got" = "$G1_WANT" ]; then ok "G1 the call multiset equals the expected set"; else no "G1 the call multiset differs from the expected set: $(diff <(echo "$G1_WANT") <(echo "$got") | tr '\n' ' ')"; fi
    if [ "$(gline "$d")" = "$G1_GRANT" ]; then ok "G1 the GRANT line is the expected one"; else no "G1 the GRANT line is '$(gline "$d")'"; fi
    if [ -n "$rf" ]; then
      r=$(newcase) || return 2; g1_fixture "$r"; run_fn "$rf" "$sh" "$r" "$UIDV"
      if [ "$got" = "$(slines "$r")" ]; then ok "G1 the call multiset equals the reference's"; else no "G1 the call multiset differs from the reference's"; fi
      if [ "$(gline "$d")" = "$(gline "$r")" ]; then ok "G1 the GRANT line equals the reference's"; else no "G1 the GRANT line differs from the reference's: '$(gline "$r")'"; fi
      if [ "$(sort -u "$d/state/.granted.$UIDV")" = "$(sort -u "$r/state/.granted.$UIDV")" ]; then ok "G1 .granted.<uid> equals the reference's"; else no "G1 .granted.<uid> differs from the reference's"; fi
    else
      [ "$QUIET" = yes ] || echo "  note  G1 no reference roamd (no origin/main, no --ref): compared with the committed set only [$sh]"
    fi
  ;; esac

  case "$only" in *" G2 "*)
    d=$(newcase) || return 2
    for i in 01 02 03 04 05 06 07 08 09 10 11 12; do echo "q$i android.permission.READ_CONTACTS" >> "$d/$PFREL"; echo "q$i 0.1" >> "$d/delay"; done
    for i in 01 02 03 04 05 06 07 08 09 10; do echo "p$i" >> "$d/pkgs"; echo "p$i 0.1" >> "$d/delay"; done
    run_fn "$fn" "$sh" "$d" "$UIDV"; harness "$d"
    e=$(maxin "$d")
    if [ "$e" -le 6 ] && [ "$e" -ge 2 ]; then ok "G2 at most 6 calls in flight ($e)"; else no "G2 $e calls in flight at once, the cap is 6"; fi
    e=$(maxin "$d" '^grant p[0-9]+ ')
    if [ "$e" -gt 1 ]; then ok "G2 the INTERNET default runs more than 1 call at once ($e)"; else no "G2 the INTERNET default ran $e call at a time"; fi
    got=$(grep -c '^S grant p' "$d/calls"); [ "$got" = 10 ] || no "G2 $got default grants, want 10"
  ;; esac

  case "$only" in *" G3 "*)
    d=$(newcase) || return 2
    for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do
      echo "q$i android.permission.READ_CONTACTS" >> "$d/$PFREL"
      if [ "$i" = 06 ]; then echo "q$i 2" >> "$d/delay"; else echo "q$i 0.1" >> "$d/delay"; fi
    done
    run_fn "$fn" "$sh" "$d" "$UIDV"; harness "$d"
    s6=$(grep -n '^S grant q06 ' "$d/calls" | cut -d: -f1); e6=$(grep -n '^E grant q06 ' "$d/calls" | cut -d: -f1)
    inside=$(awk -v a="${s6:-0}" -v b="${e6:-0}" 'NR>a && NR<b && $1=="S" { s[$2" "$3]=1 } NR>a && NR<b && $1=="E" && s[$2" "$3] { n++ } END { print n+0 }' "$d/calls")
    if [ -n "$s6" ] && [ -n "$e6" ] && [ "$inside" -ge 5 ]; then ok "G3 $inside other calls start and end inside the slow sixth call"
    else no "G3 $inside other calls start and end inside the slow sixth call, want at least 5 (a batch barrier)"; fi
  ;; esac

  case "$only" in *" G4 "*)
    d=$(newcase) || return 2; g1_fixture "$d"
    printf '%s\n' "grant p03 $INET" "grant com.a android.permission.READ_CONTACTS" > "$d/fail"
    run_fn "$fn" "$sh" "$d" "$UIDV"; harness "$d"
    case "$(gline "$d")" in *"-> 6 perms + 11 INTERNET default(s) + "*) ok "G4 the failing calls are not counted (6 perms, 11 defaults)" ;;
      *) no "G4 the GRANT line counts a failing call: '$(gline "$d")'" ;; esac
    if grep -qxF p03 "$d/state/.granted.$UIDV" 2>/dev/null; then no "G4 the failing default's package is in .granted.<uid>"; else ok "G4 the failing default's package is not in .granted.<uid>"; fi
    if [ -n "$rf" ]; then
      r=$(newcase) || return 2; g1_fixture "$r"; cp "$d/fail" "$r/fail"; run_fn "$rf" "$sh" "$r" "$UIDV"
      if [ "$(gline "$d")" = "$(gline "$r")" ]; then ok "G4 the GRANT line equals the reference's"; else no "G4 the GRANT line differs from the reference's: '$(gline "$r")'"; fi
    fi
  ;; esac

  case "$only" in *" G5 "*)
    d=$(newcase) || return 2; : > "$d/$PFREL"
    for i in 01 02 03 04 05 06 07 08 09; do echo "p$i" >> "$d/pkgs"; echo "p$i 0.4" >> "$d/delay"; done
    run_fn "$fn" "$sh" "$d" "$UIDV"; harness "$d"
    got=$(sort "$d/state/.granted.$UIDV" 2>/dev/null | tr '\n' ' ')
    if [ "$got" = "p01 p02 p03 p04 p05 p06 p07 p08 p09 " ]; then ok "G5 every slow default's package is in .granted.<uid>"
    else no "G5 .granted.<uid> is '$got', want p01..p09"; fi
  ;; esac

  case "$only" in *" G6 "*)
    d=$(newcase) || return 2
    for i in 01 02 03 04 05 06 07; do echo "q$i android.permission.CAMERA" >> "$d/$PFREL"; echo "q$i 0.3" >> "$d/delay"; done
    printf '%s\n' "q01 appop:android:write_settings" "q02 deny:$INET" \
      "f01 flags:user-set:android.permission.READ_CONTACTS" "f02 flags:user-fixed:android.permission.CAMERA" >> "$d/$PFREL"
    for i in 01 02 03 04 05 06 07 08; do echo "p$i" >> "$d/pkgs"; echo "p$i 0.4" >> "$d/delay"; done
    run_fn "$fn" "$sh" "$d" "$UIDV"; harness "$d"
    lastx=$(grep -n -E "^E (grant |appops |revoke [^ ]+ $INET$)" "$d/calls" | tail -1 | cut -d: -f1)
    firstf=$(grep -n '^S flags ' "$d/calls" | head -1 | cut -d: -f1)
    if [ -n "$lastx" ] && [ -n "$firstf" ] && [ "$firstf" -gt "$lastx" ]; then ok "G6 the first flags call starts after every grant, deny revoke, appops and default ended"
    else no "G6 a flags call started (line ${firstf:-none}) before every grant ended (line ${lastx:-none})"; fi
  ;; esac

  case "$only" in *" G7 "*)
    d=$(newcase) || return 2; g1_fixture "$d"; run_fn "$fn" "$sh" "$d" "$UIDV"; harness "$d"
    got=""; for i in grant-lines grant-list3 grant-internet grant-declines; do got="$got $i=$(tcount "$d" "$i")"; done
    if [ "$got" = " grant-lines=1 grant-list3=1 grant-internet=1 grant-declines=1" ]; then ok "G7 the sign-in call logs each phase once"; else no "G7 the sign-in call logs$got"; fi
    d=$(newcase) || return 2; rm -f "$d/$PFREL"; run_fn "$fn" "$sh" "$d" "$UIDV"; harness "$d"
    got=""; for i in grant-lines grant-list3 grant-internet grant-declines; do got="$got $i=$(tcount "$d" "$i")"; done
    if [ "$got" = " grant-lines=1 grant-list3=1 grant-internet=1 grant-declines=1" ]; then ok "G7 a sign-in with no nowhere-perms logs each phase once"; else no "G7 a sign-in with no nowhere-perms logs$got"; fi
    d=$(newcase) || return 2; g1_fixture "$d"; run_fn "$fn" "$sh" "$d" "$UIDV" com.a 1; harness "$d"
    e=$(grep -c '\[roamd\] TIMING grant-' "$d/log"); e=${e:-0}
    if [ "$e" = 0 ]; then ok "G7 a PKGFILTER call logs no phase timing"; else no "G7 a PKGFILTER call logged $e phase timing line(s)"; fi
    if grep -q '^S grant com.a ' "$d/calls"; then :; else no "G7 the PKGFILTER call granted nothing (harness)"; fi
  ;; esac

  [ "$QUIET" = yes ] || echo "  -- [$sh] $PASS ok, $FAILN failed"
  [ "$HARN" = 0 ] || return 2
  [ "$FAILN" = 0 ] || return 1
  return 0
}

QUIET=no; RC=0
for sh in $SHELLS; do
  suite "$SUT" "$sh"; r=$?
  [ "$r" = 0 ] || RC=$r
done
if [ "$RC" != 0 ]; then echo "test-grant-window: FAILED (rc $RC)"; exit "$RC"; fi
[ "$MUTATE" = yes ] || { echo "test-grant-window: all cases passed"; exit 0; }

# --- mutants -------------------------------------------------------------------------------------------------------
# mutant <name> <case id> <sed program>: the mutant must change the file and be CONVICTED (rc 1 and a FAIL line for
# the case) under every shell. The control mutant (case id "-") must SURVIVE the whole suite under every shell.
MFAIL=0
mutant() {
  local name="$1" cid="$2" prog="$3" t out r sh
  t=$(mktemp -p "$W")
  sed -e "$prog" "$SUT" > "$t"
  if cmp -s "$t" "$SUT"; then echo "  FAIL  mutant did not apply: $name"; MFAIL=1; return; fi
  for sh in $SHELLS; do
    if [ "$cid" = - ]; then
      out=$(QUIET=yes suite "$t" "$sh" 2>&1); r=$?
      if [ "$r" = 0 ]; then echo "  ok    control mutant survives: $name [$sh]"
      else echo "  FAIL  control mutant was convicted (rc $r): $name [$sh]"; printf '%s\n' "$out" | head -5; MFAIL=1; fi
      continue
    fi
    out=$(QUIET=yes suite "$t" "$sh" "$cid" 2>&1); r=$?
    case "$r:$out" in
      1:*"FAIL  $cid "*"[$sh]"*) echo "  ok    CONVICTED by $cid: $name [$sh]" ;;
      0:*) echo "  FAIL  NOT CONVICTED by $cid: $name [$sh]"; MFAIL=1 ;;
      *) echo "  FAIL  BROKEN (rc $r) for $cid: $name [$sh]"; printf '%s\n' "$out" | head -5; MFAIL=1 ;;
    esac
  done
}
QUIET=yes
mutant "the window cap 6 -> 60" G2 \
  '/^gwin_add() {$/,/^}$/s/while \[ "\$#" -ge 6 \]/while [ "$#" -ge 60 ]/'
mutant "gwin_add replaced by the old batch barrier" G3 \
  '/^gwin_add() {$/,/^}$/{/^gwin_add() {$/!{/^}$/!d;};};/^gwin_add() {$/a\
  _gbgm=$((${_gbgm:-0} + 1)); [ "$_gbgm" -ge 6 ] \&\& { wait; _gbgm=0; }'
mutant "the INTERNET default back in the foreground" G2 \
  '/^    { pm grant --user "\$uid" "\$dpkg" android.permission.INTERNET /s/; } &$/; }/'
mutant "the drain before the record removed" G5 \
  's/^  wait; _gwq=""             # drain the window before the count and the record read it$/  :/'
mutant "every drain before the declines pass removed" G6 \
  's/^  wait; _gwq=""             # drain the window before the count.*$/  :/'
mutant "dflt counted whether pm succeeded" G4 \
  '/^    { pm grant --user "\$uid" "\$dpkg" android.permission.INTERNET /s/ 2>&1 && { echo x >> "\$_gdf";/ 2>\&1; _r=$?; echo x >> "$_gdf"; [ "$_r" = 0 ] \&\& {/'
mutant "the TIMING lines printed on a PKGFILTER call" G7 \
  's/^  \[ -n "\$pkgfilter" \] || _gtm=1$/  _gtm=1/'
mutant "control: a comment's wording" - \
  's/^# queued, waits the OLDEST and drops it\./# queued, waits the FIRST and drops it./'
[ "$MFAIL" = 0 ] || { echo "test-grant-window: a mutant was not convicted (or the control was)"; exit 1; }
echo "test-grant-window: all cases passed, all mutants convicted, the control survived"
