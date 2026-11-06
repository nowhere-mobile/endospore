#!/usr/bin/env bash
# test-mandated-patches.sh [<build-device.sh>] [--mutate] -- the GOS_MANDATED_PATCHES list and the source-patch
# loop of build-device.sh (NWP-20261019-03).
#
# A framework patch that no build script applies ships in no image unless someone remembered, and every producer
# logs success (#210/#112, keystore-roam.sh). This suite pins that systemui-no-restart-doze.sh is on the list, that
# every listed name exists, and that the loop runs each once and FAILS the build when one fails or is missing.
#
# The block (`^GOS_MANDATED_PATCHES=` through the loop's `^done$`) is lifted from build-device.sh by anchor, never
# copied: moved anchors fail loudly.
#   bash test-mandated-patches.sh            # the cases
#   bash test-mandated-patches.sh --mutate   # ... plus 4 mutants that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE="$(cd "$(dirname "$0")" && pwd)"
REALREPO="$(cd "$HERE/../../.." && pwd)"
SUT="${SUT:-$HERE/build-device.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT   # every case dir, stub REPO, excerpt and mutant copy

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf "  ok    %s\n" "$1"; }
no(){ FAIL=$((FAIL+1)); printf "  FAIL  %s\n" "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2] want [$3]"; }

extract(){ sed -n '/^GOS_MANDATED_PATCHES=/,/^done$/p' "$1"; }
names(){ sed -n 's/^GOS_MANDATED_PATCHES="\(.*\)"$/\1/p' "$1"; }

# stub_repo <dir> <names...> -- a REPO whose every patch appends "<name> <arg>" to $LOG
stub_repo(){
  local r=$1; shift; local n d
  mkdir -p "$r/editions/diaspore/build/patches" "$r/editions/endospore/build/patches" "$r/editions/endospore/devices/lynx/patches"
  for n in "$@"; do
    printf '#!/bin/bash\necho "%s $*" >> "$LOG"\n' "$n" > "$r/editions/diaspore/build/patches/$n"
  done
  for d in editions/endospore/build/patches/glob-a.sh editions/endospore/devices/lynx/patches/glob-b.sh; do
    printf '#!/bin/bash\necho "%s $*" >> "$LOG"\n' "$(basename "$d")" > "$r/$d"
  done
}

# run <block-file> <repo> -> RC, OUT (combined output), LOG (stub log)
run(){
  local blk=$1 repo=$2 T
  T=$(mktemp -d -p "$W"); LOG="$T/log"; : > "$LOG"; TREE="$T/tree"; mkdir -p "$TREE"
  # The excerpt ends at the loop's `done`, before build-device.sh's own `rm -f /tmp/bd-patch.$$`. The trap also
  # removes what build-device.sh leaks itself: a `[ -e ]` miss after a patch has run exits before that rm. A check
  # that build-device.sh no longer leaks must look inside run.sh, before this trap. The path is pinned after extract.
  { echo "trap 'rm -f /tmp/bd-patch.\$\$' EXIT"
    echo 'fail(){ echo "FAILED: $1"; exit 1; }'
    echo "REPO='$repo'; DEV=lynx; TREE='$TREE'"
    cat "$blk"; } > "$T/run.sh"
  OUT=$(LOG="$LOG" bash "$T/run.sh" 2>&1); RC=$?
}
count(){ local c; c=$(grep -c -x -- "$1" "$LOG"); echo "$c"; }

t1(){ # <block-file>
  local blk=$1 list n missing=""
  list=$(names "$blk")
  [ -n "$list" ] || { no "T1: the list is empty or unparseable"; return; }
  for n in $list; do [ -f "$REALREPO/editions/diaspore/build/patches/$n" ] || missing="$missing $n"; done
  is "T1: every listed name exists in editions/diaspore/build/patches" "$missing" ""
  case " $list " in *" systemui-no-restart-doze.sh "*) ok "T1: systemui-no-restart-doze.sh is mandated" ;;
    *) no "T1: systemui-no-restart-doze.sh is NOT on the list" ;; esac
}

t2(){ # <block-file>
  local blk=$1 list n bad="" R
  list=$(names "$blk"); R=$(mktemp -d -p "$W"); LOG=/dev/null
  stub_repo "$R" $list
  run "$blk" "$R"
  is "T2: clean run exits 0" "$RC" 0
  for n in $list; do [ "$(count "$n $TREE")" = 1 ] || bad="$bad $n"; done
  is "T2: every listed stub ran exactly once with TREE as its only argument" "$bad" ""
  is "T2: endospore glob stub ran" "$(count "glob-a.sh $TREE")" 1
  is "T2: device glob stub ran" "$(count "glob-b.sh $TREE")" 1
}

t3(){ # <block-file>
  local blk=$1 list first second R
  list=$(names "$blk"); first=${list%% *}; second=$(echo "$list" | awk '{print $2}')
  R=$(mktemp -d -p "$W"); LOG=/dev/null; stub_repo "$R" $list
  printf '#!/bin/bash\necho "%s $*" >> "$LOG"\nexit 1\n' "$first" > "$R/editions/diaspore/build/patches/$first"
  run "$blk" "$R"
  is "T3: a failing stub fails the run" "$([ "$RC" -ne 0 ] && echo yes || echo no)" yes
  case "$OUT" in *"source patch failed: $first"*) ok "T3: names the failed patch" ;; *) no "T3: no 'source patch failed: $first' in [$OUT]" ;; esac
  is "T3: no later stub ran" "$(count "$second $TREE")" 0
}

t4(){ # <block-file>
  local blk=$1 list last R
  list=$(names "$blk"); last=${list##* }
  R=$(mktemp -d -p "$W"); LOG=/dev/null; stub_repo "$R" $list
  rm -f "$R/editions/diaspore/build/patches/$last"
  run "$blk" "$R"
  is "T4: a missing file fails the run" "$([ "$RC" -ne 0 ] && echo yes || echo no)" yes
  case "$OUT" in *"patch not found"*) ok "T4: says 'patch not found'" ;; *) no "T4: no 'patch not found' in [$OUT]" ;; esac
}

# cases <block-file> <only: all, T1, T2, T3 or T4>
cases(){
  local blk=$1 only=${2:-all}
  [ -s "$blk" ] || { echo "EXTRACTION FAILED -- anchors moved in $SUT" >&2; exit 2; }
  { [ "$only" = all ] || [ "$only" = T1 ]; } && t1 "$blk"
  { [ "$only" = all ] || [ "$only" = T2 ]; } && t2 "$blk"
  { [ "$only" = all ] || [ "$only" = T3 ]; } && t3 "$blk"
  { [ "$only" = all ] || [ "$only" = T4 ]; } && t4 "$blk"
  return 0
}

BLK=$(mktemp -p "$W"); extract "$SUT" > "$BLK"
if ! grep -q '^GOS_MANDATED_PATCHES=' "$BLK" || ! grep -q '^done$' "$BLK"; then
  echo "EXTRACTION FAILED -- anchors moved in $SUT" >&2; exit 2
fi
# run()'s trap removes the patch log by name, so a moved log would leak again with nothing to say so.
grep -qF '/tmp/bd-patch.$$' "$BLK" || { echo "HARNESS STALE -- $SUT no longer writes /tmp/bd-patch.\$\$; re-path or drop run()'s trap" >&2; exit 2; }
cases "$BLK"

# ---- mutants --------------------------------------------------------------------------------------------------
# mutant: <name>@@<case>@@<python-expression-on-s>
if [ "$MUTATE" = yes ]; then
  echo "== mutants =="
  MUTANTS=(
    "systemui dropped from the list@@T1@@s.replace(' systemui-no-restart-doze.sh\"','\"',1)"
    "failure arm replaced by || true@@T3@@re.sub(r'\\|\\| \\{ echo FAILED;.*?\\}\\n','|| true\\n',s,count=1,flags=re.S)"
    "the [ -e ] guard removed@@T4@@re.sub(r'  \\[ -e \"\\\$p\" \\] \\|\\| fail[^\\n]*\\n','',s,count=1)"
    "the for-n line removed@@T2@@re.sub(r'for n in \\\$GOS_MANDATED_PATCHES;[^\\n]*\\n','',s,count=1)"
  )
  MUTFAIL=0
  for m in "${MUTANTS[@]}"; do
    mname=${m%%@@*}; mcase=${m#*@@}; mcase=${mcase%%@@*}; mexpr=${m#*@@*@@}
    for kind in control mutant; do
      MS=$(mktemp -p "$W"); cp "$SUT" "$MS"
      if [ "$kind" = mutant ]; then
        python3 - "$MS" "$mexpr" <<'PY'
import re, sys
p, expr = sys.argv[1], sys.argv[2]
s = open(p).read()
t = eval(expr)
if t == s:
    sys.exit(3)
open(p, "w").write(t)
PY
        if [ $? -ne 0 ]; then no "mutant [$mname] did not apply"; MUTFAIL=1; continue; fi
      fi
      MB=$(mktemp -p "$W"); extract "$MS" > "$MB"
      P0=$FAIL; cases "$MB" "$mcase" > /dev/null
      D=$((FAIL-P0)); FAIL=$P0
      if [ "$kind" = control ]; then
        if [ "$D" -eq 0 ]; then ok "control for [$mname] passes"; else no "control for [$mname] FAILED ($D)"; MUTFAIL=1; fi
      else
        if [ "$D" -gt 0 ]; then ok "mutant [$mname] CONVICTED by $mcase"; else no "mutant [$mname] SURVIVED $mcase"; MUTFAIL=1; fi
      fi
    done
  done
fi

echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
