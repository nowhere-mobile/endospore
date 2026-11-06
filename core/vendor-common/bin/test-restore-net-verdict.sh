#!/usr/bin/env bash
# test-restore-net-verdict.sh [--mutate] -- NWP-20261006-21: a store that cannot be reached is not a damaged
# save, and it is not "up to date".
#
# WHY THIS IS COMMITTED. Two scripts read the agent's new exit 5 (exitStoreUnreachable), and both readings
# fail silently in the direction that hurts:
#   * roamd's sign-in verdict. A vault restore that failed in transport must answer "BLANK NET", or the gate
#     offers "Restore last good version" for a network error -- and taking it rolls the profile back to an
#     older save, for good (NWP-20260910-06). The status is read as `$?` at the top of the elif's else
#     branch, which is correct only while nothing runs before it.
#   * otad's update check. The agent's recovered panic also exits 1, which otad read as "up to date"; a phone
#     that could not reach the store said it was current.
#
# The blocks are extracted from the scripts BY ANCHOR, never copied: if an anchor moves the extraction is
# empty and the suite stops, rather than passing against its own stale copy. Nothing in them is rewritten.
#
#   bash test-restore-net-verdict.sh            # the behaviour cases, under bash and under sh
#   bash test-restore-net-verdict.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# Pure logic: no build, no device. roamd and otad run under mksh on the phone; both readings use only POSIX
# `$?` and `[ ]`, and the cases run under every POSIX shell the host has (bash, sh, and mksh/dash if present).
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
HERE=$(dirname "$0")
ROAMD="$HERE/nowhere_roamd.sh"
OTAD="$HERE/nowhere_otad.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# --- extraction ------------------------------------------------------------------------------------------
# roamd: from the `_rrc=$?` read to the inner `fi` that closes the verdict, inclusive.
ROAMD_BLOCK=$(awk '/^      _rrc=\$\?$/{f=1} f{print} f&&/^      fi$/{exit}' "$ROAMD")
# otad: the three verdict lines for rc 5 and rc 1, in order.
OTAD_BLOCK=$(grep -E '^if \[ "\$rc" = (5|1) \]' "$OTAD")
case "$ROAMD_BLOCK" in *'_rrc=$?'*'BLANK NET'*'      fi') ;; *) echo "EXTRACTION FAILED: roamd block -- anchors moved" >&2; exit 2 ;; esac
# NWP-20261008-09: the verdict lines print the profile name through roamd's qn, with mksh's `print -r --`. qn is
# extracted like the block; print is shimmed only where the shell has none (bash, sh, dash -- mksh has the builtin).
ROAMD_QN=$(awk '$0 == "qn() {" {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
case "$ROAMD_QN" in 'qn() {'*'}') ;; *) echo "EXTRACTION FAILED: roamd qn -- anchors moved" >&2; exit 2 ;; esac
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
[ "$(printf '%s\n' "$OTAD_BLOCK" | grep -c .)" = 3 ] || { echo "EXTRACTION FAILED: otad block -- want 3 lines" >&2; exit 2; }

SHELLS="bash sh"
for s in mksh dash; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

# --- harness ---------------------------------------------------------------------------------------------
# roamd: the block runs as the else of `if <no key needed>; then ...; elif <restore>; then ...; else`, which is
# its real position -- the restore is simulated by `(exit RC)`, the last command before the else.
roamd_verdict(){             # roamd_verdict <shell> <block> <restore rc>
  local T; T=$(mktemp -d)
  printf '%s\n%s\nRES=%s/res; LOG=%s/log; name=p\nif false; then :\nelif (exit %s); then echo "OK 10" > "$RES"\nelse\n%s\nfi\ncat "$RES"\n' \
    "$PRINT_SHIM" "$ROAMD_QN" "$T" "$T" "$3" "$2" > "$T/run.sh"
  "$1" "$T/run.sh" 2>&1
  rm -rf "$T"
}
# otad: the block runs with rc/out set as ota-check left them; set_res records the verdict. A case that falls
# through every line prints FALLTHROUGH (otad would go on to stage the update).
otad_verdict(){              # otad_verdict <shell> <block> <rc> <ota-check stdout>
  local T; T=$(mktemp -d)
  printf '%s\n' "$4" > "$T/out"
  printf 'LOG=%s/log\nset_res(){ echo "$1"; }\nrc=%s\nout=$(cat %s/out)\nver=$(echo "$out" | grep -oE "[0-9]+\\.[0-9]+(\\.[0-9]+)?" | tail -1)\n%s\necho FALLTHROUGH\n' \
    "$T" "$3" "$T" "$2" > "$T/run.sh"
  "$1" "$T/run.sh" 2>&1
  rm -rf "$T"
}

cases(){                     # cases <label> <roamd block> <otad block> -> number of failed cases
  local bad=0 s got
  for s in $SHELLS; do
    got=$(roamd_verdict "$s" "$2" 5);  [ "$got" = "BLANK NET" ] || { bad=$((bad+1)); [ "$1" = real ] && echo "  FAIL  $s roamd: restore exit 5 -> [$got], want BLANK NET"; }
    got=$(roamd_verdict "$s" "$2" 1);  [ "$got" = "BLANK" ]     || { bad=$((bad+1)); [ "$1" = real ] && echo "  FAIL  $s roamd: restore exit 1 -> [$got], want BLANK"; }
    got=$(roamd_verdict "$s" "$2" 0);  [ "$got" = "OK 10" ]     || { bad=$((bad+1)); [ "$1" = real ] && echo "  FAIL  $s roamd: restore exit 0 -> [$got], want the OK branch"; }
    got=$(otad_verdict "$s" "$3" 5 "");                              [ "$got" = "ERR-CHECK" ]      || { bad=$((bad+1)); [ "$1" = real ] && echo "  FAIL  $s otad: rc 5 -> [$got], want ERR-CHECK"; }
    got=$(otad_verdict "$s" "$3" 1 "ERR: cap GET ref/x: dial tcp");  [ "$got" = "ERR-CHECK" ]      || { bad=$((bad+1)); [ "$1" = real ] && echo "  FAIL  $s otad: rc 1 without UPTODATE -> [$got], want ERR-CHECK"; }
    got=$(otad_verdict "$s" "$3" 1 "ota-check: UPTODATE (latest 0.5.43)"); [ "$got" = "UPTODATE 0.5.43" ] || { bad=$((bad+1)); [ "$1" = real ] && echo "  FAIL  $s otad: rc 1 with UPTODATE -> [$got], want UPTODATE 0.5.43"; }
    got=$(otad_verdict "$s" "$3" 0 "ota-check: UPDATE -> 0.5.44");  [ "$got" = "FALLTHROUGH" ]    || { bad=$((bad+1)); [ "$1" = real ] && echo "  FAIL  $s otad: rc 0 -> [$got], want to fall through to staging"; }
  done
  echo "$bad"
}

echo "shells: $SHELLS"
out=$(cases real "$ROAMD_BLOCK" "$OTAD_BLOCK")
printf '%s
' "$out" | grep -v '^[0-9]*$' || true
n=$(printf '%s
' "$out" | tail -1)
[ "$n" = 0 ] && ok "every verdict, every shell" || no "$n case(s) failed"

if [ "$MUTATE" = yes ]; then
  echo "mutations (each must be convicted):"
  mut(){                     # mut <label> <roamd block> <otad block>
    local k; k=$(cases mut "$2" "$3" | tail -1)
    [ "$k" -gt 0 ] && ok "convicted: $1 ($k case(s))" || no "NOT CONVICTED: $1"
  }
  # Something runs before the status is read, so $? is no longer the restore's.
  mut "a command before the _rrc read" "$(printf '%s\n' "$ROAMD_BLOCK" | sed 's/^      _rrc=\$?$/      : ; _rrc=$?/')" "$OTAD_BLOCK"
  # The 5 is not told apart: every failure is BLANK again.
  mut "roamd ignores exit 5" "$(printf '%s\n' "$ROAMD_BLOCK" | sed 's/"\$_rrc" = 5/"$_rrc" = 99/')" "$OTAD_BLOCK"
  # otad loses its rc-5 line: the transport failure falls to "no published version".
  mut "otad drops the rc 5 line" "$ROAMD_BLOCK" "$(printf '%s\n' "$OTAD_BLOCK" | grep -v '= 5 \]')"
  # otad trusts a bare 1 again: a panic reads as up to date.
  mut "otad trusts a bare exit 1" "$ROAMD_BLOCK" "$(printf '%s\n' "$OTAD_BLOCK" | grep -v 'no verdict')"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
