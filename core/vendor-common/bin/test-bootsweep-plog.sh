#!/usr/bin/env bash
# test-bootsweep-plog.sh [<nowhere_roamd.sh>] [--mutate] -- the boot sweep's copy of its result into provision.log
# (NWP-20261201-36, h60 #11), run for real rather than grepped.
#
# A report filed at the gate reads provision.log, gate.log and ota.log, never roam.log, so the boot sweep copies its
# per-category tokens into provision.log. Gate scope is blind-login scope, so the copy must:
#   - keep a category key of [a-z0-9_] and a value of [0-9A-Za-z:/] (counts, the fixed class words, KEPT:user<n>);
#   - turn FAILED(...) into FAILED and failed(...) into failed, and drop every word of a detail that holds spaces;
#   - turn any other value into OTHER, and drop a token with no "=" or with any other key;
#   - never expand a "*" or a "?" against the working directory, and leave the shell's noglob flag as it found it;
#   - leave the roam.log line as it was, and leave the op's answer alone when provision.log cannot be opened.
#
# bootsweep_plog_line and the op's tail (the roam.log result echo through `echo "OK" > "$RES"`) are extracted from
# nowhere_roamd.sh BY ANCHOR; if an anchor moves, extraction fails loudly (exit 2). /data is rerooted to a temp tree and
# the cases run under every shell present among bash, sh, dash and mksh; each mutant must be convicted under each shell,
# by the case the mutant names.
#
#   bash test-bootsweep-plog.sh            # the behaviour cases
#   bash test-bootsweep-plog.sh --mutate   # ... plus mutations that must each CONVICT the suite
# ONLY_SHELL=<path> (internal) restricts the shell loop to one shell.
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE=$(dirname "$0")
SUT="${SUT:-$HERE/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

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
ANCHOR_ROAM='  echo "[roamd] bootsweep result:$_swept $(date)" >> "$LOG"'
ANCHOR_OK='  echo "OK" > "$RES"'
FN=$(awk '/^bootsweep_plog_line\(\) \{$/ { on = 1 } on { print } on && /^}$/ { exit }' "$SUT")
case "$FN" in *'BS_PLOG'*) ;; *) echo "EXTRACTION FAILED: bootsweep_plog_line" >&2; exit 2 ;; esac
OP=$(sed -n '/^if \[ "\$op" = "bootsweep" \]; then$/,/^fi$/p' "$SUT")
[ -n "$OP" ] || { echo "EXTRACTION FAILED: the bootsweep op" >&2; exit 2; }
N_ROAM=$(printf '%s\n' "$OP" | grep -cxF -e "$ANCHOR_ROAM")
N_OK=$(printf '%s\n' "$OP" | grep -cxF -e "$ANCHOR_OK")
[ "$N_ROAM" = 1 ] || { echo "EXTRACTION FAILED: the roam.log result echo occurs $N_ROAM time(s) in the op" >&2; exit 2; }
[ "$N_OK" = 1 ] || { echo "EXTRACTION FAILED: the OK echo occurs $N_OK time(s) in the op" >&2; exit 2; }
TAIL=$(printf '%s\n' "$OP" | awk -v a="$ANCHOR_ROAM" -v b="$ANCHOR_OK" '$0 == a { on = 1 } on { print } on && $0 == b { exit }')
case "$TAIL" in *"$ANCHOR_OK") ;; *) echo "EXTRACTION FAILED: the OK echo is not after the roam.log result echo" >&2; exit 2 ;; esac
printf '%s\n' "$FN" > "$W/fn.sh"; printf '%s\n' "$TAIL" > "$W/tail.sh"
bash -n "$W/fn.sh" 2>/dev/null || { echo "EXTRACTION FAILED: bootsweep_plog_line does not parse" >&2; exit 2; }
bash -n "$W/tail.sh" 2>/dev/null || { echo "EXTRACTION FAILED: the op's tail does not parse" >&2; exit 2; }

# --- harness --------------------------------------------------------------------------------------------
# fn.drv: the real function on $S; prints BS_PLOG, then $- on the next line.
{ cat "$W/fn.sh"; cat <<'DRV'
bootsweep_plog_line "$S"
echo "$BS_PLOG"
echo "$-"
DRV
} > "$W/fn.drv"
# tail.drv: the real function, then the op's tail with /data rerooted to $R (literal, as test-userdir-orphan's reroot).
{ cat "$W/fn.sh"; echo 'LOG="$R/roam.log"; RES="$R/res"; _swept="$SWEPT"'
  sed -E 's#([" ])/data/#\1$R/data/#g' "$W/tail.sh"; } > "$W/tail.drv"

# runfn <shell> <dir> <string> -> sets OUT and FLAGS. A run under a dir holding files a glob would expand to.
runfn(){ local sh="$1" d="$2" s="$3" out
  out=$(cd "$d" && S="$s" "$sh" "$W/fn.drv" 2>&1)
  OUT=$(printf '%s\n' "$out" | sed -n 1p); FLAGS=$(printf '%s\n' "$out" | sed -n 2p); }
# runtail <shell> <root> <_swept>: the stderr goes to <root>/stderr.
runtail(){ R="$2" SWEPT="$3" "$1" "$W/tail.drv" 2>"$2/stderr"; }
same(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got '$2', want '$3'"; fi; }

F1_IN=' adservices=0 jobs=4 userdirs=2/LEFT:1 appop_db=UNREACHABLE fingerprint=ABSENT locglobals=FAILED(1) mobiledata=KEPT:user10 devtoggles=FAILED(airplane,nfc) dataroaming=baseline hotspot=failed(busy now) ksdrop=none staging=3/LEFT:1/LINK:1'
F1_OUT=' adservices=0 jobs=4 userdirs=2/LEFT:1 appop_db=UNREACHABLE fingerprint=ABSENT locglobals=FAILED mobiledata=KEPT:user10 devtoggles=FAILED dataroaming=baseline hotspot=failed ksdrop=none staging=3/LEFT:1/LINK:1'
EMPTY=$(mktemp -d -p "$W")
GLOB=$(mktemp -d -p "$W"); : > "$GLOB/jobs=leak1"; : > "$GLOB/q=xy"
PLINE='^\[bootsweep\] result:( [a-z0-9_]+=[0-9A-Za-z:/]+)+ \(NWP-20261201-36\) '

for sh in "${SHELLS[@]}"; do
tag="[${sh##*/}]"
echo "== $tag the copy holds keys and values of a fixed shape =="
runfn "$sh" "$EMPTY" "$F1_IN"; same "$tag F1 a full result keeps its counts and classes, without the details" "$OUT" "$F1_OUT"
runfn "$sh" "$EMPTY" ' a=FAILED(x y=z) b=1'; same "$tag F2 every word of a detail with spaces goes" "$OUT" ' a=FAILED b=1'
runfn "$sh" "$EMPTY" ' stray x= Bad-Key=1 q=a"b'; same "$tag F3 no =, a bad key and a bad value" "$OUT" ' x=OTHER q=OTHER'
runfn "$sh" "$GLOB" ' jobs=* q=x?'; same "$tag F4 a glob does not expand against the working directory" "$OUT" ' jobs=OTHER q=OTHER'
case "$FLAGS" in
  *f*) no "$tag F4 the noglob flag is still set after the call: '$FLAGS'" ;;
  *) ok "$tag F4 the noglob flag is off after the call" ;;
esac

echo "== $tag the op's tail =="
T=$(mktemp -d -p "$W"); mkdir -p "$T/data/nowhere"
runtail "$sh" "$T" "$F1_IN"
P="$T/data/nowhere/provision.log"
L=$(wc -l 2>/dev/null < "$P"); L=${L:-0}; L=$((L + 0))
same "$tag O1 provision.log has one line" "$L" 1
SHAPE=$(grep -cE "$PLINE" "$P" 2>/dev/null); SHAPE=${SHAPE:-0}
same "$tag O1 the provision.log line has the fixed shape" "$SHAPE" 1
QUOTES=$(grep -c '"' "$P" 2>/dev/null); QUOTES=${QUOTES:-0}
same "$tag O1 the provision.log line has no quote" "$QUOTES" 0
PAREN=$(sed 's/(NWP-20261201-36)//' "$P" 2>/dev/null | grep -c '(')
same "$tag O1 the only parenthesis is the work id's" "${PAREN:-0}" 0
RKEEP=$(grep -cF 'locglobals=FAILED(1)' "$T/roam.log" 2>/dev/null); RKEEP=${RKEEP:-0}
same "$tag O1 the roam.log line still carries the detail" "$RKEEP" 1
same "$tag O1 the op still answers OK" "$(cat "$T/res" 2>/dev/null)" OK

T=$(mktemp -d -p "$W")
runtail "$sh" "$T" "$F1_IN"
same "$tag O2 provision.log cannot be opened: the op still answers OK" "$(cat "$T/res" 2>/dev/null)" OK
same "$tag O2 provision.log cannot be opened: nothing on stderr" "$(cat "$T/stderr" 2>/dev/null)" ""
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite, by its named case, under each shell) =="
  # mutate <label> <case> <sed args...>: a run that fails for another reason (a parse error, EXTRACTION FAILED) is no
  # conviction.
  mutate(){ local m label="$1" want="$2" s rc out; shift 2
    m=$(mktemp -d -p "$W")
    if ! sed "$@" "$SUT" > "$m/m" 2>"$m/err"; then no "MUTATION BROKEN (sed): $label: $(cat "$m/err")"; rm -rf "$m"; return; fi
    if cmp -s "$SUT" "$m/m"; then no "MUTATION INERT: $label"; rm -rf "$m"; return; fi
    for s in "${SHELLS[@]}"; do
      out=$(ONLY_SHELL="$s" bash "$0" "$m/m" 2>&1); rc=$?
      if [ "$rc" -eq 0 ]; then no "NOT CONVICTED: $label [${s##*/}] -- suite passes on broken code"; continue; fi
      case "$out" in
        *"  FAIL  [${s##*/}] $want "*) ok "convicted by $want: $label [${s##*/}]" ;;
        *) no "NOT CONVICTED BY $want: $label [${s##*/}] (exit $rc)" ;;
      esac
    done
    rm -rf "$m"
  }
  mutate "M1: the provision.log echo is removed" O1 -e '/^  echo "\[bootsweep\] result:/d'
  mutate "M2: the FAILED arm keeps the value" F1 -e 's@^      "FAILED("\*) _v=FAILED ;;$@      "FAILED("*) ;;@'
  mutate "M3: rule a is removed" F2 -e '\%^    if \[ -n "\$_open" \]; then case %d'
  mutate "M4: the OTHER arm keeps the value" F3 -e 's@^      ""|\*\[!0-9A-Za-z:/\]\*) _v=OTHER ;;$@      ""|*[!0-9A-Za-z:/]*) ;;@'
  mutate "M5: the key check is removed" F3 -e '\%^    case "\$_k" in ""|\*\[!a-z0-9_\]\*) continue ;; esac$%d'
  mutate "M6: set +f is removed" F4 -e '/^bootsweep_plog_line() {$/,/^}$/{/^  set +f$/d;}'
  mutate "M7: the echo is written to \$LOG" O1 -e 's@ 2>/dev/null >> /data/nowhere/provision\.log$@ 2>/dev/null >> "$LOG"@'
  mutate "M8: the copy is taken before the last category" O1 \
    -e '/^  bootsweep_plog_line "\$_swept"$/d' \
    -e 's@^  echo "\[roamd\] bootsweep result:\$_swept \$(date)" >> "\$LOG"$@  _swept=""; bootsweep_plog_line "$_swept"\n&@'
  mutate "M9: set -f is removed" F4 -e '/^bootsweep_plog_line() {$/,/^}$/{/^  set -f$/d;}'
fi

echo
echo "shells: ${SHELLS[*]}"
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
