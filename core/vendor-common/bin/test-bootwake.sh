#!/usr/bin/env bash
# test-bootwake.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's sign-in boot wake, the `bootwake` op (NWP-20261114-01).
#
# WHY THIS IS COMMITTED. At sign-in every restored app is still in Android's stopped state, so an app that asked to
# start at boot (a car key, a VPN, a clock's alarms) does nothing until it is opened. The decision
# (docs/product-decisions.md, 2026-10-24) sends LOCKED_BOOT_COMPLETED and BOOT_COMPLETED to every session package that
# declares a receiver for them, once its restore has landed. Each half fails SILENTLY: an op that sends nothing, sends
# to the wrong set, skips the unstop or sends before the data landed leaves no error anywhere.
#
# roamd's cutoff functions, bootwake_list and the bootwake arm are extracted BY ANCHOR and run against a fake device:
# one file per package holding its stopped flag, the two receiver queries as fixtures, `pm`, `am` and `timeout`
# stubbed over them, every call recorded in order. The arm's /data paths are re-rooted under the case's root. Every
# case runs under each shell found (bash, dash, mksh, and sh when it is not one of them).
#
#   bash test-bootwake.sh            # the cases
#   bash test-bootwake.sh --mutate   # ... plus mutations that must each CONVICT the suite under every shell
#
# NWP-20261128-37 (the B cases, N mutants): the log line also says how pm's receiver listing parsed.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for every temp; nothing outlives the suite.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# bash, dash and mksh run under their own names; sh only when it is not the same binary as one of them.
SHELLS=()
if [ -n "${ONLY_SHELL:-}" ]; then
  case "$ONLY_SHELL" in bash|sh|dash|mksh) ;; *) echo "FAIL  ONLY_SHELL=$ONLY_SHELL is not an available shell"; exit 2 ;; esac
  command -v "$ONLY_SHELL" >/dev/null 2>&1 || { echo "FAIL  ONLY_SHELL=$ONLY_SHELL is not an available shell"; exit 2; }
  SHELLS=("$ONLY_SHELL")
else
  for s in bash dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS+=("$s"); done
  if p=$(command -v sh 2>/dev/null); then
    r=$(readlink -f "$p"); dup=""
    for s in "${SHELLS[@]}"; do [ "$(readlink -f "$(command -v "$s")")" = "$r" ] && { dup=$s; break; }; done
    if [ -n "$dup" ]; then echo "skip shell sh: same binary as $dup"; else SHELLS+=(sh); fi
  fi
fi
[ "${#SHELLS[@]}" -gt 0 ] || { echo "FAIL  no shell found"; exit 2; }

PASS=0; FAIL=0; SH=all; SHP=""
ok(){ PASS=$((PASS+1)); printf '  ok    [%s] %s\n' "$SH" "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  [%s] %s\n' "$SH" "$1"; }

# --- extraction -----------------------------------------------------------------------------------------
# The cutoff functions run from CUTOFF_BUDGET= to the closing brace of cutoff_run; bootwake_list is its own function;
# an op arm runs from its label to the first line that is exactly "    ;;".
F=$(awk '/^CUTOFF_BUDGET=/{on=1} on{print} on&&/^cutoff_run\(\) \{/{last=1} last&&/^}$/{exit}' "$SUT")
L=$(awk '/^bootwake_list\(\) \{/{on=1} on{print} on&&/^}$/{exit}' "$SUT")
A=$(awk -v l="  bootwake)" '$0==l{on=1} on{print} on&&/^    ;;$/{exit}' "$SUT")
ODH=$(grep -m1 -E '^ODHOLD=' "$SUT")
case "$F" in *'cutoff_run()'*) ;; *) echo "EXTRACTION FAILED: the cutoff functions in $SUT" >&2; exit 2 ;; esac
case "$A" in *'cutoff_run boot'*) ;; *) echo "EXTRACTION FAILED: the bootwake arm in $SUT" >&2; exit 2 ;; esac
case "$L" in *'query-receivers'*) ;; *) echo "EXTRACTION FAILED: bootwake_list in $SUT" >&2; exit 2 ;; esac
[ -n "$ODH" ] || { echo "EXTRACTION FAILED: ODHOLD= not found in $SUT" >&2; exit 2; }
# roamd's reap scrub (as test-stop-mediad-verify.sh reads it): B8 passes the bootwake line through it.
SCRUB=$(grep -m1 '^LOG_SCRUB_SED=' "$SUT")
[ -n "$SCRUB" ] || { echo "EXTRACTION FAILED: LOG_SCRUB_SED in $SUT" >&2; exit 2; }
eval "$SCRUB"
reroot() { printf '%s\n' "$1" | sed -E 's#([" |])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }
RA=$(reroot "$A")
n=$(printf '%s\n' "$RA" | grep -o '\$ROOT/data/' | grep -c .)
[ "$n" -ge 4 ] || { echo "RE-ROOT FAILED: the bootwake arm has $n rewritten paths, want >= 4" >&2; exit 2; }
n=$(nleft "$RA")
[ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: the bootwake arm keeps $n absolute /data path(s) in live code" >&2; exit 2; }

# --- the fake device ------------------------------------------------------------------------------------
# POSIX stubs, run inside each case's run file under each shell. `_st_*` names never meet roamd's.
#   pm list packages --user U -U --show-stopped        -> one line per $ROOT/pk/<name>; nothing if $ROOT/listfail
#   pm query-receivers --user U ... -a <ACTION>        -> $ROOT/rcv.LOCKED or $ROOT/rcv.BOOT
#   pm unstop --user U <pkg>                           -> sets $ROOT/pk/<pkg> to false
#   am broadcast --user U -p <pkg> ... -a <ACTION>     -> recorded; the scratch files' modes snapshotted
STUBS=$(cat <<'EOF'
timeout(){ shift 3; echo "via-timeout $1 $2" >> "$ROOT/tcalls"; "$@"; }
pm(){
  case "$1" in
    list)
      echo "list user=$4" >> "$ROOT/calls"
      [ -e "$ROOT/listfail" ] && return 0
      for _st_q in "$ROOT"/pk/*; do printf 'package:%s stopped=%s uid:%s\n' "${_st_q##*/}" "$(cat "$_st_q")" 1010123; done ;;
    query-receivers)
      _st_u=""; _st_a=""; _st_c=no; _st_i=no; shift
      while [ $# -gt 0 ]; do
        case "$1" in --user) _st_u=$2; shift ;; -a) _st_a=$2; shift ;; --components) _st_c=yes ;; --include-stopped-packages) _st_i=yes ;; esac
        shift
      done
      echo "query user=$_st_u $_st_a components=$_st_c stopped=$_st_i" >> "$ROOT/calls"
      case "$_st_a" in
        android.intent.action.LOCKED_BOOT_COMPLETED) cat "$ROOT/rcv.LOCKED" ;;
        android.intent.action.BOOT_COMPLETED) cat "$ROOT/rcv.BOOT" ;;
      esac ;;
    unstop)
      echo "unstop $4 user=$3" >> "$ROOT/calls"
      [ -e "$ROOT/pk/$4" ] && echo false > "$ROOT/pk/$4" ;;
    *) echo "unexpected pm $*" >> "$ROOT/calls" ;;
  esac
  return 0
}
am(){
  case "$1" in
    broadcast)
      _st_u=""; _st_p=""; _st_r=""; _st_a=""; _st_i=no; shift
      while [ $# -gt 0 ]; do
        case "$1" in --user) _st_u=$2; shift ;; -p) _st_p=$2; shift ;; --allow-fgs-start-reason) _st_r=$2; shift ;; -a) _st_a=$2; shift ;; --include-stopped-packages) _st_i=yes ;; esac
        shift
      done
      echo "broadcast $_st_p $_st_r $_st_a user=$_st_u stopped=$_st_i" >> "$ROOT/calls"
      for _st_f in "$STATE"/.cutoff.10.bootwake*; do [ -e "$_st_f" ] && stat -c %a "$_st_f" >> "$ROOT/modes"; done ;;
    *) echo "unexpected am $*" >> "$ROOT/calls" ;;
  esac
  return 0
}
EOF
)
BODY=$(printf '%s\n' "$ODH" "$F" "$L" 'umask 022' 'case "$op" in' "$RA" 'esac')

# The session of the cases. Declaring (7): android, com.car.key, com.clock, com.dup, com.nowhere.chooser, com.vpn.tail,
# com.held. Candidates (4): com.car.key, com.clock, com.dup, com.vpn.tail -- the chooser and the framework are fixed
# keeps and com.held's data is parked. Of those, stopped (3): com.car.key, com.clock, com.dup. com.plain declares neither.
DECL=7; CAND=4; UNST=3
NAMES="com.nowhere.chooser android com.car.key com.vpn.tail com.clock com.dup com.plain com.held"
session() {
  local d n
  d=$(mktemp -d -p "$W"); mkdir -p "$d/pk" "$d/state" "$d/data/user/10" "$d/data/user_de/10" "$d/data/media/10/Android/data" \
    "$d/data/media/10/Android/obb"
  ( : > "$d/calls" ); ( : > "$d/tcalls" ); ( : > "$d/log" )
  for n in com.nowhere.chooser=false android=false com.car.key=true com.vpn.tail=false com.clock=true com.dup=true \
           com.plain=true com.held=true; do
    printf '%s\n' "${n#*=}" > "$d/pk/${n%%=*}"
  done
  # Lenient parse: a header, indents (blanks and a tab), a line with a blank in it, and a name that is not a plain one.
  printf '%s\n' 'Receivers:' '  android/com.android.server.BootReceiver' '  com.car.key/.LockedBootReceiver' \
    '    com.clock/com.clock.AlarmInit' '  com.dup/.A' '  com.dup/.B' '  -evil/.R' 'Receiver #0: com.plain/.X' > "$d/rcv.LOCKED"
  printf '%s\n' '  com.nowhere.chooser/.BootReceiver' '  com.car.key/.BootReceiver' '  com.vpn.tail/com.tailscale.ipn.StartVPNReceiver' \
    '  com.dup/.A' '  com.held/.Boot' '	com.dup/.C' > "$d/rcv.BOOT"
  mkdir -p "$d/data/user_de/10/com.nowhere.chooser/.nowhere-odhold/com.held"
  printf '%s\n' "$d"
}
# run <root> [srcunit] [budget]: the arm over the device, from <root>/run.sh under "$SHP". RES lands in <root>/res.
run() {
  local d="$1" s="${2:-}" b="${3:-45}"
  case "$s$b" in *"'"*) echo "run: a quote in the arguments" >&2; return 2 ;; esac
  {
    printf "ROOT='%s'; uid=10; STATE=\"\$ROOT/state\"; RES=\"\$ROOT/res\"; LOG=\"\$ROOT/log\"; srcunit='%s'; op=bootwake\n" "$d" "$s"
    printf "NOWHERE_CUTOFF_BUDGET='%s'; NOWHERE_CUTOFF_PAR=8; ACCT_AUTH_PKG=com.google.android.gms\n" "$b"
    printf '%s\n' "$STUBS" "$BODY"
  } > "$d/run.sh" || return 2
  "$SHP" "$d/run.sh" >/dev/null 2>>"$d/stderr"
}
res() { cat "$1/res" 2>/dev/null; }
has() { local c; c=$(grep -cxF -- "$2" "$1/calls"); [ "$c" -ge 1 ]; }
cnt() { grep -cxF -- "$2" "$1/calls"; }
lineno() { grep -nxF -- "$2" "$1/calls" | head -1 | cut -d: -f1; }
names() {   # names <root> <pkg>: how many unstop/broadcast calls name <pkg>
  awk -v p="$2" '($1=="unstop"||$1=="broadcast")&&$2==p{n++} END{print n+0}' "$1/calls"
}
sends() { awk '$1=="unstop"||$1=="broadcast"{n++} END{print n+0}' "$1/calls"; }
LB="android.intent.action.LOCKED_BOOT_COMPLETED"; BB="android.intent.action.BOOT_COMPLETED"
lk() { printf 'broadcast %s 202 %s user=10 stopped=yes' "$1" "$LB"; }
bt() { printf 'broadcast %s 200 %s user=10 stopped=yes' "$1" "$BB"; }
# NWP-20261128-37: the bootwake log line of a case, and the parse counts it must end with.
bwline() { grep -m1 '^\[roamd\] bootwake user 10: ' "$1/log"; }
pl() { printf 'pm listed %s component line(s), %s no-receivers line(s), %s other line(s) (NWP-20261128-37)' "$1" "$2" "$3"; }
# fixtures <root> <LOCKED file> <BOOT file>: both receiver listings from files of the case (an empty file: no output).
fixtures() { cp "$2" "$1/rcv.LOCKED" && cp "$3" "$1/rcv.BOOT"; }
noform() { [ ! -e "$1/state/.cutoff.10.bootwake.form" ]; }
herr() { local e; e=$(grep -m1 -E 'not found|unbound variable|syntax error|bad substitution' "$1/stderr" 2>/dev/null); printf '%s' "$e"; }

cases() {
  local d u a b k bad s line

  echo "== [$SH] the session, all packages =="
  d=$(session); ( : > "$d/state/.cutoff.10" ); echo com.plain > "$d/state/.cutoff.10.bootwake.u"; run "$d"
  [ -z "$(herr "$d")" ] || no "harness: $(herr "$d")"
  u=$(lineno "$d" "unstop com.car.key user=10"); a=$(lineno "$d" "$(lk com.car.key)"); b=$(lineno "$d" "$(bt com.car.key)")
  { [ -n "$u" ] && [ -n "$a" ] && [ -n "$b" ] && [ "$u" -lt "$a" ] && [ "$a" -lt "$b" ]; } \
    && ok "(a) a stopped declaring package: pm unstop, then LOCKED_BOOT_COMPLETED (202), then BOOT_COMPLETED (200), each -p with --include-stopped-packages" \
    || no "(a) com.car.key: unstop at [$u], LOCKED at [$a], BOOT at [$b]"
  [ "$(names "$d" com.plain)" = 0 ] && ok "(b) a package that declares neither gets no call" || no "(b) com.plain got $(names "$d" com.plain) call(s)"
  { has "$d" "$(lk com.vpn.tail)" && has "$d" "$(bt com.vpn.tail)" && [ "$(cnt "$d" "unstop com.vpn.tail user=10")" = 0 ]; } \
    && ok "(c) a declaring package that reads stopped=false gets both broadcasts and no unstop" \
    || no "(c) com.vpn.tail: $(names "$d" com.vpn.tail) call(s), unstops $(cnt "$d" "unstop com.vpn.tail user=10")"
  { has "$d" "$(lk com.clock)" && has "$d" "$(bt com.clock)"; } \
    && ok "(d) a package that declares only LOCKED_BOOT_COMPLETED is sent both" || no "(d) com.clock was not sent both broadcasts"
  { [ "$(cnt "$d" "$(lk com.dup)")" = 1 ] && [ "$(cnt "$d" "$(bt com.dup)")" = 1 ] && [ "$(cnt "$d" "unstop com.dup user=10")" = 1 ]; } \
    && ok "(e) a package listed more than once across the two queries is sent once" \
    || no "(e) com.dup: $(names "$d" com.dup) call(s)"
  bad=""; for k in com.nowhere.chooser android; do [ "$(names "$d" "$k")" = 0 ] || bad="$bad $k"; done
  [ -z "$bad" ] && ok "(k) the chooser and the framework, both declaring, are sent nothing" || no "(k) sent to a fixed keep:$bad"
  [ "$(names "$d" com.held)" = 0 ] && ok "(l) a declaring package with parked data (user_de hold) gets nothing" \
    || no "(l) com.held got $(names "$d" com.held) call(s)"
  line=$(grep -c '^\[roamd\] bootwake user 10: ' "$d/log")
  s="boot broadcasts sent to $CAND of $CAND package(s) ($UNST unstopped first, 1 skipped with parked data, $DECL declare a boot receiver) (NWP-20261114-01)"
  bad=""; for k in $NAMES -evil; do case "$(cat "$d/log")" in *"$k"*) bad="$bad $k" ;; esac; done
  { [ "$line" = 1 ] && grep -qF "$s" "$d/log" && [ -z "$bad" ]; } \
    && ok "(j) one log line, counts only: $s" || no "(j) log lines=$line, names:$bad, log [$(cat "$d/log")]"
  s=$(ls -A "$d/state" | grep '^\.cutoff\.10\.bootwake' | tr '\n' ' ')
  { [ -z "$s" ] && [ -e "$d/state/.cutoff.10" ]; } && ok "(m) no .cutoff.10.bootwake* file is left, and cutoffwake's record is untouched" \
    || no "(m) state holds [$(ls -A "$d/state" | tr '\n' ' ')]"
  [ "$(res "$d")" = "BOOTWAKE $CAND $DECL" ] && ok "(n) the answer: BOOTWAKE $CAND $DECL" || no "(n) the answer was [$(res "$d")]"
  { [ "$(stat -c %a "$d/res")" = 600 ] && [ -s "$d/modes" ] && [ -z "$(grep -vx 600 "$d/modes")" ]; } \
    && ok "(n) the answer and the scratch files are 0600 (umask 077)" \
    || no "(n) res mode $(stat -c %a "$d/res"), scratch modes [$(tr '\n' ' ' < "$d/modes" 2>/dev/null)]"
  { [ "$(grep -c '^query user=10 android.intent.action.\(LOCKED_\)\{0,1\}BOOT_COMPLETED components=yes stopped=yes$' "$d/calls")" = 2 ] \
    && [ "$(grep -c '^via-timeout pm query-receivers$' "$d/tcalls")" = 2 ] && [ "$(sends "$d")" = $((UNST + 2 * CAND)) ]; } \
    && ok "(n) two bounded receiver queries for user 10; $UNST unstops and $((2 * CAND)) broadcasts in all" \
    || no "(n) queries/sends: $(grep -c '^query' "$d/calls") / $(sends "$d")"
  { ! grep -q 'unexpected\|user=[^1]\|user=1[^0]' "$d/calls"; } && ok "(n) no unexpected call, every call names user 10" \
    || no "(n) $(grep 'unexpected\|user=[^1]\|user=1[^0]' "$d/calls" | head -2 | tr '\n' ' ')"

  echo "== [$SH] a spent budget =="
  d=$(session); run "$d" "" 0
  { [ "$(sends "$d")" = 0 ] && [ "$(res "$d")" = "BOOTWAKE 0 $DECL" ]; } \
    && ok "(f) NOWHERE_CUTOFF_BUDGET=0 starts no unstop and no broadcast: BOOTWAKE 0 $DECL" \
    || no "(f) $(sends "$d") call(s), answer [$(res "$d")]"

  echo "== [$SH] one package (srcunit) =="
  d=$(session); run "$d" com.car.key
  bad=$(awk '($1=="unstop"||$1=="broadcast")&&$2!="com.car.key"{print $2}' "$d/calls" | sort -u | tr '\n' ' ')
  { [ -z "$bad" ] && [ "$(sends "$d")" = 3 ] && [ "$(res "$d")" = "BOOTWAKE 1 $DECL" ]; } \
    && ok "(g) srcunit=com.car.key touches only that package: BOOTWAKE 1 $DECL" \
    || no "(g) srcunit=com.car.key sent to [$bad], $(sends "$d") call(s), answer [$(res "$d")]"
  s="one package: boot broadcasts sent to 1 of 1 (1 unstopped first, 0 skipped with parked data, $DECL declare a boot receiver)"
  bad=""; for k in $NAMES; do case "$(cat "$d/log")" in *"$k"*) bad="$bad $k" ;; esac; done
  { grep -qF "$s" "$d/log" && [ -z "$bad" ]; } && ok "(j) the one-package log line holds counts and no name" \
    || no "(j) one-package log [$(cat "$d/log")]"
  for k in com.plain android; do
    d=$(session); run "$d" "$k"
    { [ "$(sends "$d")" = 0 ] && [ "$(res "$d")" = "BOOTWAKE 0 $DECL" ]; } \
      && ok "(g) srcunit=$k is not a candidate: BOOTWAKE 0 $DECL, nothing sent" \
      || no "(g) srcunit=$k: $(sends "$d") call(s), answer [$(res "$d")]"
  done
  d=$(session); run "$d" com.held
  { [ "$(sends "$d")" = 0 ] && [ "$(res "$d")" = "BOOTWAKE 0 $DECL" ] && grep -qF "1 skipped with parked data" "$d/log"; } \
    && ok "(l) srcunit=com.held with parked data: nothing sent, BOOTWAKE 0 $DECL, 1 skipped with parked data" \
    || no "(l) srcunit=com.held: $(sends "$d") call(s), answer [$(res "$d")], log [$(cat "$d/log")]"
  s=$(ls -A "$d/state" | grep '^\.cutoff\.10\.bootwake' | tr '\n' ' ')
  [ -z "$s" ] && ok "(m) the one-package mode leaves no scratch file" || no "(m) left [$s]"

  echo "== [$SH] the refusals =="
  d=$(session); ( : > "$d/listfail" ); run "$d"
  { [ "$(res "$d")" = ERR-LIST ] && [ "$(sends "$d")" = 0 ] && ! grep -q '^query' "$d/calls"; } \
    && ok "(h) no package line: ERR-LIST, no query, no unstop, no broadcast" \
    || no "(h) answer [$(res "$d")], calls [$(tr '\n' ' ' < "$d/calls")]"
  for k in -evil a/b; do
    d=$(session); run "$d" "$k"
    { [ "$(res "$d")" = ERR-PKG ] && [ ! -s "$d/calls" ]; } && ok "(i) srcunit=$k: ERR-PKG, no call at all" \
      || no "(i) srcunit=$k: answer [$(res "$d")], calls [$(tr '\n' ' ' < "$d/calls")]"
  done

  # NWP-20261128-37: the line says how pm's receiver listing parsed, so a report tells no declared receiver from an
  # unknown output form and from an empty capture. Counts only, and the reap scrub leaves the line as it is.
  echo "== [$SH] how the receiver listing parsed (NWP-20261128-37) =="
  local fx BL S e
  fx=$(mktemp -d -p "$W")
  printf '%s\n' 'No receivers found' > "$fx/none"
  ( : > "$fx/empty" )
  printf '%s\n' 'Receiver #0:' '  priority=0 preferredOrder=0 match=0x108000' '  ActivityInfo:' \
    '    name=com.car.key.LockedBootReceiver' '    packageName=com.car.key' > "$fx/odd.L"
  printf '%s\n' 'Receiver #0:' '  priority=0 preferredOrder=0 match=0x108000' '  ActivityInfo:' \
    '    name=com.vpn.tail.StartVPNReceiver' '    packageName=com.vpn.tail' > "$fx/odd.B"

  d=$(session); run "$d"; BL=$(bwline "$d")
  # 5 + 6 component lines (com.dup 3 times, com.car.key twice: before the dedup), 3 other (the header, -evil, the
  # line with a blank); the answer still counts 7 declaring packages.
  case "$BL" in *"(NWP-20261114-01); $(pl 11 0 3) "*) e=yes ;; *) e=no ;; esac
  { [ "$e" = yes ] && [ "$(res "$d")" = "BOOTWAKE $CAND $DECL" ]; } \
    && ok "(B1) component lines counted before the dedup: $(pl 11 0 3), BOOTWAKE $CAND $DECL" \
    || no "(B1) line [$BL], answer [$(res "$d")]"
  noform "$d" && ok "(B6) B1 leaves no .form file" || no "(B6) B1 left $(ls -Ad "$d/state/.cutoff.10.bootwake.form")"
  S=$(printf '%s\n' "$BL" | sed -E "$LOG_SCRUB_SED")
  case "$BL" in *"(NWP-20261128-37)"*) e=yes ;; *) e=no ;; esac
  { [ "$e" = yes ] && [ "$S" = "$BL" ]; } && ok "(B8) the reap scrub leaves B1's line byte-identical" \
    || no "(B8) B1 line [$BL] scrubbed to [$S]"

  d=$(session); fixtures "$d" "$fx/none" "$fx/none"; run "$d"; BL=$(bwline "$d")
  case "$BL" in *"(NWP-20261114-01); $(pl 0 2 0) "*) e=yes ;; *) e=no ;; esac
  { [ "$e" = yes ] && [ "$(res "$d")" = "BOOTWAKE 0 0" ] && [ "$(sends "$d")" = 0 ]; } \
    && ok "(B2) No receivers found twice: $(pl 0 2 0), BOOTWAKE 0 0, nothing sent" \
    || no "(B2) line [$BL], answer [$(res "$d")], $(sends "$d") call(s)"
  noform "$d" && ok "(B6) B2 leaves no .form file" || no "(B6) B2 left a .form file"
  S=$(printf '%s\n' "$BL" | sed -E "$LOG_SCRUB_SED")
  case "$BL" in *"(NWP-20261128-37)"*) e=yes ;; *) e=no ;; esac
  { [ "$e" = yes ] && [ "$S" = "$BL" ]; } && ok "(B8) the reap scrub leaves B2's line byte-identical" \
    || no "(B8) B2 line [$BL] scrubbed to [$S]"

  d=$(session); fixtures "$d" "$fx/odd.L" "$fx/odd.B"; run "$d"; BL=$(bwline "$d")
  case "$BL" in *"(NWP-20261114-01); $(pl 0 0 10) "*) e=yes ;; *) e=no ;; esac
  { [ "$e" = yes ] && [ "$(res "$d")" = "BOOTWAKE 0 0" ] && [ "$(sends "$d")" = 0 ]; } \
    && ok "(B3) an unknown listing form: $(pl 0 0 10), nothing sent" \
    || no "(B3) line [$BL], answer [$(res "$d")], $(sends "$d") call(s)"
  bad=""; for k in $NAMES -evil LockedBootReceiver StartVPNReceiver; do case "$(cat "$d/log")" in *"$k"*) bad="$bad $k" ;; esac; done
  [ -z "$bad" ] && ok "(B5) B3's log names no package or component" || no "(B5) B3's log names:$bad"
  noform "$d" && ok "(B6) B3 leaves no .form file" || no "(B6) B3 left a .form file"

  d=$(session); fixtures "$d" "$fx/empty" "$fx/empty"; run "$d"; BL=$(bwline "$d")
  case "$BL" in *"(NWP-20261114-01); $(pl 0 0 0) "*) e=yes ;; *) e=no ;; esac
  { [ "$e" = yes ] && [ "$(res "$d")" = "BOOTWAKE 0 0" ]; } \
    && ok "(B7) pm printed nothing: $(pl 0 0 0), BOOTWAKE 0 0" || no "(B7) line [$BL], answer [$(res "$d")]"
  noform "$d" && ok "(B6) B7 leaves no .form file" || no "(B6) B7 left a .form file"

  d=$(session); run "$d" com.car.key
  noform "$d" && ok "(B6) the one-package mode leaves no .form file" || no "(B6) the one-package mode left a .form file"

  # B4: the form path is a directory; the op answers and sends as without it, and the line shows ? counts.
  d=$(session); mkdir "$d/state/.cutoff.10.bootwake.form"; run "$d"; BL=$(bwline "$d")
  case "$BL" in *"(NWP-20261114-01); $(pl '?' '?' '?') "*) e=yes ;; *) e=no ;; esac
  { [ "$e" = yes ] && [ "$(res "$d")" = "BOOTWAKE $CAND $DECL" ] && [ "$(sends "$d")" = $((UNST + 2 * CAND)) ] \
    && [ -z "$(herr "$d")" ]; } \
    && ok "(B4) an unwritable form file: BOOTWAKE $CAND $DECL, $((UNST + 2 * CAND)) sends, $(pl '?' '?' '?')" \
    || no "(B4) line [$BL], answer [$(res "$d")], $(sends "$d") call(s), stderr [$(herr "$d")]"
  s=$(ls -A "$d/state" | grep '^\.cutoff\.10\.bootwake' | tr '\n' ' ')
  { [ "$s" = ".cutoff.10.bootwake.form " ] && [ -d "$d/state/.cutoff.10.bootwake.form" ] \
    && [ -z "$(ls -A "$d/state/.cutoff.10.bootwake.form")" ]; } \
    && ok "(B6) B4 leaves only the planted directory, empty" || no "(B6) B4 state [$s]"
  bad=""; for k in $NAMES -evil; do case "$BL" in *"$k"*) bad="$bad $k" ;; esac; done
  [ -z "$bad" ] && ok "(B5) B4's line names no package" || no "(B5) B4's line names:$bad"
}

# Parse first, then every case, under each shell.
printf '%s\n' "ROOT=/x; STATE=/x; RES=/x; LOG=/x; uid=10; srcunit=; op=x" "$STUBS" "$BODY" > "$W/parse.sh"
for SH in "${SHELLS[@]}"; do
  SHP=$(command -v "$SH")
  "$SHP" -n "$W/parse.sh" 2>/dev/null || { no "THE BLOCKS DO NOT PARSE under $SH"; exit 2; }
  cases
done
SH=all

if [ "$MUTATE" = yes ]; then
  command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
  echo
  echo "== mutations (each must CONVICT the suite under every shell) =="
  M=$(mktemp -d -p "$W")
  # mutate <label> <old> <new>: replace the literal <old>, which must occur EXACTLY once in the script (so no mutant
  # reaches cutoffwake or another arm), by <new>. A mutant convicts only when its re-run under EACH shell exits 1 with
  # a FAIL line tagged for that shell.
  mutate(){
    local s out rc ev
    if ! MO="$2" MN="$3" perl -0pe 'BEGIN { $o = $ENV{MO}; $n = $ENV{MN} } $c = () = /\Q$o\E/g;
        die "matches $c times\n" unless $c == 1; s/\Q$o\E/$n/' "$SUT" > "$M/m.sh" 2>"$M/err"; then
      no "MUTATION BROKEN: $1: $(cat "$M/err")"; return
    fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $1"; return; fi
    for s in "${SHELLS[@]}"; do
      SH=$s
      out=$(ONLY_SHELL="$s" TMPDIR="$W" bash "$0" "$M/m.sh" 2>&1); rc=$?
      ev=$(printf '%s\n' "$out" | grep -F "  FAIL  [$s] " || true)
      if [ "$rc" = 0 ]; then no "NOT CONVICTED: $1 -- the suite passes on broken code"
      elif [ "$rc" != 1 ]; then no "MUTANT BROKEN: $1 (rc=$rc): $(printf '%s\n' "$out" | tail -1)"
      elif [ -z "$ev" ]; then no "UNPROVEN: $1 -- rc 1 with no FAIL line under $s"
      else ok "convicted: $1"; printf '%s\n' "$ev" | sed 's/^/        /'; fi
    done
    SH=all
  }
  UN='          cutoff_run unstop "$uid" "$_bf.u" "$(( $(date +%s) + CUTOFF_BUDGET ))"; _bun=${CUTOFF_RAN:-0}
'
  BO='          cutoff_run boot "$uid" "$_bf" "$(( $(date +%s) + CUTOFF_BUDGET ))"; _bsent=${CUTOFF_RAN:-0}
'
  mutate "the unstop pass is dropped" "$UN" ''
  mutate "the boot pass runs before the unstop pass" "$UN$BO" "$BO$UN"
  mutate "stopped=false packages are skipped (a stopped-only filter)" \
    'cutoff_run boot "$uid" "$_bf" ' 'cutoff_run boot "$uid" "$_bf.u" '
  mutate "the receiver filter is dropped" '_blist=$(bootwake_list "$uid" "$_bf.form")' \
    "_blist=\$(printf '%s\\n' \"\$_call\" | sed -n 's/^package:\\([^ ]*\\) .*/\\1/p')"
  mutate "the hold check is dropped" '[ -d "$_bv/com.nowhere.chooser/$ODHOLD/$_p" ] && { _bh=1; break; }' ':'
  mutate "the fixed-keep exclusion is dropped" 'case "$_bfixed" in *" $_p "*) continue ;; esac' ':'
  mutate "srcunit is ignored" 'if [ -n "$srcunit" ] && [ "$_p" != "$srcunit" ]; then continue; fi' ':'
  mutate "the unstop deadline is a far one" \
    'cutoff_run unstop "$uid" "$_bf.u" "$(( $(date +%s) + CUTOFF_BUDGET ))"' 'cutoff_run unstop "$uid" "$_bf.u" 9999999999'
  mutate "the boot deadline is a far one" \
    'cutoff_run boot "$uid" "$_bf" "$(( $(date +%s) + CUTOFF_BUDGET ))"' 'cutoff_run boot "$uid" "$_bf" 9999999999'
  mutate "the log names a package" '          rm -f "$_bf" "$_bf.u" "$_bf.form"   # the scratch goes at the end too' \
    '          cat "$_bf" >> "$LOG"; rm -f "$_bf" "$_bf.u" "$_bf.form"   # the scratch goes at the end too'
  mutate "the scratch file is left" '          rm -f "$_bf" "$_bf.u" "$_bf.form"   # the scratch goes at the end too
' ''
  # NWP-20261128-37: the parse counts. N1's line holds a real tab, as roamd's does.
  TB=$(printf '\t')
  N1O='      case "$_l" in *" "*|*"'"$TB"'"*) _no=$((_no + 1)); continue ;; ?*/?*) ;; *) _no=$((_no + 1)); continue ;; esac'
  N1N='      case "$_l" in *" "*|*"'"$TB"'"*) _np=$((_np + 1)); continue ;; ?*/?*) ;; *) _np=$((_np + 1)); continue ;; esac'
  mutate "N1 other lines are counted as parsed" "$N1O" "$N1N"
  mutate "N2 the No receivers found lines are counted as other" '_nn=$((_nn + 1))' '_no=$((_no + 1))'
  N3A='      _np=$((_np + 1))
'
  N3B='      case "$_o" in *" $_p "*) continue ;; esac
'
  mutate "N3 parsed is counted after the dedup" "$N3A$N3B" "$N3B$N3A"
  mutate "N4 the form scratch is not removed" 'rm -f "$_bf" "$_bf.u" "$_bf.form"   # the scratch goes at the end too' \
    'rm -f "$_bf" "$_bf.u"   # the scratch goes at the end too'
  mutate "N5 the counts are dropped from the line" \
    '; pm listed $_bfp component line(s), $_bfn no-receivers line(s), $_bfo other line(s)' ''
  mutate "N6 the no-receivers words are written quoted" '$_bfn no-receivers line(s)' '$_bfn \"No receivers found\" line(s)'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
