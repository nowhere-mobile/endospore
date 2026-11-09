#!/usr/bin/env bash
# test-mediasync-handoff.sh [--mutate] -- NWP-20261129-48: the seal's media-sync hand-off in roamd's out op, RUN.
#
# WHY THIS IS COMMITTED. After the #media push, the hand-off rewrites each landed path from /data/media/<uid>/ to
# /storage/emulated/<uid>/ into the roamed chooser's files/nowhere-mediascan.list, gives that file the files dir's
# owner, mode 600 and its label, counts its lines, sends MediaScanReceiver one broadcast and removes the state list.
# MediaScanReceiver.readList keeps only paths under the external-storage directory (test-mediascan-list.sh), so the
# rewrite is what lets another handset's new media reach MediaStore in the session, and nothing else triggers a scan
# mid-session (NWP-20260908-18). A regression here is silent on a device: the Gallery never learns the files.
# test-roamd-seal-stop.sh only counts am calls around a stop.
#
# The hand-off block and the out arm are extracted from nowhere_roamd.sh BY ANCHOR, never copied (an anchor that is
# missing or appears twice stops the suite with EXTRACTION FAILED, exit 2). Each case runs the block in a CHILD
# shell (bash, sh, and dash and mksh where present) with STATE and USERDIR in a temp root, uid=11 and real sed and
# wc. stat prints a scripted owner for the files dir; chown, chmod and restorecon record their argv (chmod also
# applies the mode); am records its argv, copies the chooser's list and its mode, and deletes the list, as the
# receiver does.
#
# A mutant changes the extracted text and this process runs the same cases on it. It does not re-extract from a
# mutated roamd, because M7 changes the block's first anchor. A mutant is CONVICTED under a shell only when the case
# it names fails there and the child reached the end of the block, so a mutant that only breaks the shell's parse
# is not a conviction.
#
#   bash test-mediasync-handoff.sh            # H1-H8 under every shell found
#   bash test-mediasync-handoff.sh --mutate   # ... plus M1-M8, each of which must be convicted under EACH shell
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
ROAMD="${ROAMD:-$HERE/nowhere_roamd.sh}"
[ -f "$ROAMD" ] || { echo "EXTRACTION FAILED: no such file: $ROAMD" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# --- extraction ------------------------------------------------------------------------------------------
FIRST='    if [ "$stopped" = 0 ] && [ -s "$STATE/mediasync.list" ]; then'
LAST='      unset _msdst _msown _msn'
PREPUSH='    rm -f "$STATE/mediasync.list" 2>> "$LOG"'
for anchor in "$FIRST" "$LAST"; do
  n=$(grep -cxF -- "$anchor" "$ROAMD")
  [ "$n" = 1 ] || { echo "EXTRACTION FAILED: [$anchor] appears $n times in $ROAMD, want 1" >&2; exit 2; }
done
# From the first anchor to the first line exactly `    fi` after the unset line.
FIRST="$FIRST" LAST="$LAST" awk '
  $0 == ENVIRON["FIRST"] {f=1}
  f {print}
  f && $0 == ENVIRON["LAST"] {u=1; next}
  u && $0 == "    fi" {exit}
' "$ROAMD" > "$W/block"
[ "$(tail -n 1 "$W/block")" = "    fi" ] && grep -qxF -- "$LAST" "$W/block" \
  || { echo "EXTRACTION FAILED: the hand-off block does not close with a line exactly [    fi] after [$LAST]" >&2; exit 2; }
# The whole out arm: from `  out)` through the first `    ;;` after it (the rule test-roamd-seal-stop.sh uses).
awk '$0 == "  out)" {f=1} f{print} f&&$0=="    ;;"{exit}' "$ROAMD" > "$W/arm"
[ "$(tail -n 1 "$W/arm")" = "    ;;" ] || { echo "EXTRACTION FAILED: the out arm has no end" >&2; exit 2; }
n=$(grep -cF -- '_push media' "$W/arm")
[ "$n" = 1 ] || { echo "EXTRACTION FAILED: [_push media] appears $n times in the out arm, want 1" >&2; exit 2; }

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
echo "shells:$SHELLS"

# H8's pin runs in a child of each shell too. A line number is checked for digits before -lt: mksh evaluates a
# non-number there as 0, silently.
cat > "$W/pin.sh" <<'EOF'
arm=$1; rmline=$2
n=$(grep -cxF -- "$rmline" "$arm")
[ "$n" = 1 ] || { echo "the pre-push rm appears $n times in the out arm, want 1"; exit 1; }
r=$(grep -nxF -- "$rmline" "$arm" | sed 's/:.*//')
p=$(grep -nF -- '_push media' "$arm" | sed 's/:.*//')
case "$r$p" in ''|*[!0-9]*) echo "no line numbers: rm [$r], push [$p]"; exit 1 ;; esac
[ -n "$r" ] && [ -n "$p" ] || { echo "no line numbers: rm [$r], push [$p]"; exit 1; }
[ "$r" -lt "$p" ] || { echo "the pre-push rm is on arm line $r, the push on line $p"; exit 1; }
EOF

# --- harness ---------------------------------------------------------------------------------------------
# run_case <shell> <block file> <stopped> <state list file> -> the case dir, which holds calls (the stubs' argv),
# am-list and am-mode (the chooser's list as the broadcast found it), log, state/, user/, and ran when the child
# reached the end of the block.
run_case(){
  local T
  T=$(mktemp -d -p "$W") || exit 2
  mkdir -p "$T/state" "$T/user/com.nowhere.chooser/files"
  cp "$4" "$T/state/mediasync.list"
  : > "$T/calls"; : > "$T/log"
  {
    printf "umask 022\n"
    printf "T='%s'; STATE=\$T/state; USERDIR=\$T/user; LOG=\$T/log; uid=11; stopped=%s\n" "$T" "$3"
    cat <<'EOF'
L="$USERDIR/com.nowhere.chooser/files/nowhere-mediascan.list"
stat(){
  [ "$*" = "-c %u:%g $USERDIR/com.nowhere.chooser/files" ] || return 1
  echo 10123:10123
}
chown(){ echo "chown $*" >> "$T/calls"; }
chmod(){ echo "chmod $*" >> "$T/calls"; command chmod "$@"; }
restorecon(){ echo "restorecon $*" >> "$T/calls"; }
am(){
  echo "am $*" >> "$T/calls"
  [ -f "$L" ] && cp "$L" "$T/am-list" && command stat -c %a "$L" > "$T/am-mode"
  rm -f "$L"
}
EOF
    cat "$2"
    printf ': > "$T/ran"\n'
  } > "$T/run.sh"
  "$1" "$T/run.sh" > "$T/out" 2> "$T/err"
  echo "$T"
}

# run_all <shell> <block file> <arm file>: H1-H8. Prints one ok or FAIL line per case; returns 1 when any fails.
run_all(){
  local s="$1" block="$2" arm="$3" rc=0 T L got want calls log why
  say(){ if [ "$1" = 0 ]; then printf '  ok    %s: %s\n' "$s" "$2"; else printf '  FAIL  %s: %s\n' "$s" "$2"; rc=1; fi; }
  reached(){ [ -e "$1/ran" ] && return 0; say 1 "$2: the child did not reach the end of the block: $(tr '\n' ' ' < "$1/err")"; return 1; }

  T=$(run_case "$s" "$block" 0 "$W/fixture")
  L="$T/user/com.nowhere.chooser/files/nowhere-mediascan.list"
  if reached "$T" "H1-H5"; then
    # H1: only a line START naming uid 11 is rewritten.
    if cmp -s "$T/am-list" "$W/expected"; then say 0 "H1: only a line start naming uid 11 is rewritten"
    else say 1 "H1: the chooser's list differs: [$(cat "$T/am-list" 2>/dev/null | tr '\n' ' ')]"; fi
    # H2: the owner, the mode and the label, all in place before the broadcast.
    got=$(cat "$T/am-mode" 2>/dev/null); calls=$(tr '\n' ';' < "$T/calls")
    if grep -qxF "chown 10123:10123 $L" "$T/calls" && grep -qxF "chmod 600 $L" "$T/calls" \
       && grep -qxF "restorecon $L" "$T/calls" && [ "$got" = 600 ] \
       && [ "$(tail -n 1 "$T/calls" | cut -d' ' -f1)" = am ]; then
      say 0 "H2: the list has the files dir's owner, mode 600 and restorecon before the broadcast"
    else say 1 "H2: mode at the broadcast [$got], calls: $calls"; fi
    # H3: exactly one broadcast, with exactly this argv.
    got=$(grep '^am ' "$T/calls")
    want='am broadcast --user 11 --include-stopped-packages -n com.nowhere.chooser/.MediaScanReceiver'
    if [ "$got" = "$want" ]; then say 0 "H3: exactly one am broadcast to MediaScanReceiver as user 11"
    else say 1 "H3: am calls: [$got]"; fi
    # H4: the count survives the receiver deleting the list.
    log=$(cat "$T/log")
    if [ -e "$L" ]; then say 1 "H4: am did not delete the chooser's list, so the count proves nothing"
    else
      case "$log" in
        *'[roamd] media-sync: 4 path(s) landed -> chooser scan (user 11) '*) say 0 "H4: the log counts 4 paths although am deleted the list" ;;
        *) say 1 "H4: the log says: [$log]" ;;
      esac
    fi
    # H5: the state list does not outlive the hand-off.
    if [ -e "$T/state/mediasync.list" ]; then say 1 "H5: \$STATE/mediasync.list survived the hand-off"
    else say 0 "H5: \$STATE/mediasync.list is gone afterwards"; fi
  fi

  # H6: a stopped seal hands nothing off. What a stop leaves in the state list is not pinned here.
  T=$(run_case "$s" "$block" 1 "$W/fixture")
  L="$T/user/com.nowhere.chooser/files/nowhere-mediascan.list"
  if reached "$T" "H6"; then
    got=$(grep '^am ' "$T/calls")
    if [ -e "$L" ] || [ -n "$got" ]; then say 1 "H6: stopped=1 wrote the chooser's list or ran am: [$got]"
    else say 0 "H6: stopped=1: no chooser list and no am"; fi
  fi

  # H7: a seal that landed nothing hands nothing off.
  T=$(run_case "$s" "$block" 0 "$W/empty")
  L="$T/user/com.nowhere.chooser/files/nowhere-mediascan.list"
  if reached "$T" "H7"; then
    got=$(grep '^am ' "$T/calls")
    if [ -e "$L" ] || [ -n "$got" ]; then say 1 "H7: an empty state list wrote the chooser's list or ran am: [$got]"
    else say 0 "H7: an empty state list: no chooser list and no am"; fi
  fi

  # H8: the out op clears the state list once, above the #media push. Otherwise a cycle that lands nothing re-scans
  # the previous cycle's paths on every seal.
  if why=$("$s" "$W/pin.sh" "$arm" "$PREPUSH" 2>&1); then say 0 "H8: the out op clears the state list once, before the _push media line"
  else say 1 "H8: $why"; fi

  return "$rc"
}

printf '%s\n' /data/media/11/DCIM/a.jpg /data/media/12/x/data/media/11/y /data/media/12/Pictures/b.jpg \
  /storage/emulated/11/c.jpg > "$W/fixture"
printf '%s\n' /storage/emulated/11/DCIM/a.jpg /data/media/12/x/data/media/11/y /data/media/12/Pictures/b.jpg \
  /storage/emulated/11/c.jpg > "$W/expected"
: > "$W/empty"

# --- the cases on main's block ---------------------------------------------------------------------------
for s in $SHELLS; do
  echo "== $s =="
  out=$(run_all "$s" "$W/block" "$W/arm"); rc=$?
  printf '%s\n' "$out"
  PASS=$((PASS+$(printf '%s\n' "$out" | grep -c '^  ok ')))
  FAIL=$((FAIL+$(printf '%s\n' "$out" | grep -c '^  FAIL ')))
  [ "$rc" = 0 ] || { echo "$PASS passed, $FAIL failed (the cases must pass on the unchanged block before a mutant means anything)"; exit 1; }
done

# --- the mutants -----------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo "mutations (each must be convicted by its named case under EACH shell):"
  # mut <label> <block|arm> <case that must fail> <python re pattern> <replacement>: exactly one substitution in the
  # named text, or the mutant fails as NOT APPLIED.
  mut(){
    local label="$1" target="$2" want="$3" m s out rc block="$W/block" arm="$W/arm"
    m=$(mktemp -p "$W") || exit 2
    if ! python3 - "$W/$target" "$m" "$4" "$5" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
out, n = re.subn(sys.argv[3], sys.argv[4], src, flags=re.M)
open(sys.argv[2], "w").write(out)
sys.exit(0 if n == 1 and out != src else 1)
PY
    then no "MUTANT DID NOT APPLY: $label"; return; fi
    case "$target" in block) block="$m" ;; arm) arm="$m" ;; esac
    for s in $SHELLS; do
      out=$(run_all "$s" "$block" "$arm"); rc=$?
      case "$out" in
        *'the child did not reach the end'*) no "NOT CONVICTED under $s (the child did not finish): $label"; printf '%s\n' "$out" | grep FAIL | sed 's/^/      /' ;;
        *"FAIL  $s: $want:"*) [ "$rc" = 1 ] && ok "convicted under $s by $want: $label" || no "NOT CONVICTED under $s (rc $rc): $label" ;;
        *) no "SURVIVED under $s (want $want to fail, rc $rc): $label"; printf '%s\n' "$out" | grep FAIL | sed 's/^/      /' ;;
      esac
    done
  }
  mut 'M1 the sed loses its ^ anchor' block H1 '\|\^/data/media/\$uid/\|' '|/data/media/$uid/|'
  mut 'M2 the sed pattern loses the uid' block H1 '\|\^/data/media/\$uid/\|' '|^/data/media/[0-9]*/|'
  mut 'M3 the chown removed' block H2 '^ *\[ -n "\$_msown" \] && chown [^\n]*\n' ''
  mut 'M4 the chmod removed' block H2 '^ *chmod 600 [^\n]*\n' ''
  mut 'M5 the count moved after the broadcast' block H4 '^( *_msn=[^\n]*\n)( *am broadcast [^\n]*\n[^\n]*\n)' '\2\1'
  mut 'M6 the post-hand-off rm removed' block H5 '^      rm -f "\$STATE/mediasync\.list" 2>> "\$LOG"\n' ''
  mut 'M7 the stopped test removed' block H6 '\[ "\$stopped" = 0 \] && ' ''
  mut 'M8 the pre-push rm moved after _push media' arm H8 '^(    rm -f "\$STATE/mediasync\.list" 2>> "\$LOG"\n)(    \[ -d "/data/media/\$uid" \] +&& _push media (?:[^\n]*\\\n)+[^\n]*\n)' '\2\1'
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
