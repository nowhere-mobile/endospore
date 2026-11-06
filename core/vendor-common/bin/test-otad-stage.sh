#!/usr/bin/env bash
# test-otad-stage.sh [<nowhere_otad.sh>] [--mutate] -- execute nowhere_otad.sh's CHECK-TO-STAGE LEG off-device
# (NWP-20261019-23).
#
# WHY THIS IS COMMITTED. Steps 1-2 of nowhere_otad.sh decide every non-apply outcome of an OTA: the ota-check
# verdict (124 -> ERR-CHECK, 5 and a bare 1 -> ERR-CHECK, 1 with the UPTODATE line -> UPTODATE, 3 with ota-check's
# own `no published OS version` line -> NONE, any other non-zero -> ERR-CHECK since NWP-20261123-25 (3 without that
# line, an unrecovered panic's 2, a missing or non-executable agent's 127/126, a kill's 137), 0 -> STAGING), the clear of the previous payload FILES, the 1800 s CDC restore with
# NOWHERE_PROGRESS/NOWHERE_PHASE set, ERR-RESTORE, restorecon, and ERR-PAYLOAD. Since NWP-20261120-11 ERR-RESTORE and
# ERR-PAYLOAD also remove the two payload FILES the failed restore left in the staging dir, and keep the dir. test-restore-net-verdict.sh runs
# only the rc 5 / rc 1 / rc 0 reading and test-otad-apply.sh the apply leg after it; the rest ran in no test,
# including the one line whose regression cannot be recovered on a device: the staging dir /data/ota_package must
# NEVER be removed or re-created (its comment: "NEVER rm/mkdir it (FBE policy); clear FILES only"). A cleanup that
# says `rm -rf "$PKG"` leaves a directory that lost its FBE policy, update_engine cannot stage into it, and no later
# update applies without a factory reset.
#
# The leg is extracted from nowhere_otad.sh BY ANCHOR, never copied: from the line `out=$(timeout 120 ...` to the
# line before `set_res "APPLYING`, plus the set_res definition. A moved anchor is rc 2 (EXTRACTION FAILED).
#
# NO TRANSFORM OF THE TEXT. The extract holds no absolute path (asserted: no /data/ or /system/ literal), so it runs
# verbatim. The harness assigns RES, PROG, LOG, PKG, AGENT, OSREF and OSPASS inside a temp dir, as the lines above
# the range do. timeout, restorecon and the agent are EXECUTABLES in a temp bin dir prepended to PATH, as on the
# device (toybox timeout / restorecon are external commands), so the env prefix on the restore call reaches the
# agent as an environment, not as shell variables.
#
#   bash test-otad-stage.sh             # the cases, under each of bash, sh, dash, mksh found on PATH
#   bash test-otad-stage.sh --mutate    # ... plus 17 mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; OTAD=""
for a in "$@"; do
  case "$a" in --mutate) MUTATE=yes ;; *) OTAD="$a" ;; esac
done
OTAD="${OTAD:-$(dirname "$0")/nowhere_otad.sh}"
[ -f "$OTAD" ] || { echo "no such script: $OTAD" >&2; exit 2; }
SELF="$0"
# Every temp of the run lives inside W.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2] want [$3]"; }

# --- extraction ------------------------------------------------------------------------------------------
LEG=$(sed -n '/^out=\$(timeout 120 "\$AGENT" ota-check s3/,/^set_res "APPLYING/p' "$OTAD" | sed '$d')
SETRES=$(grep '^set_res()' "$OTAD")
case "$LEG" in
  *'ota-check s3'*'timeout 1800 "$AGENT" restore'*'restorecon -R "$PKG"'*'ERR-PAYLOAD'*) ;;
  *) echo "EXTRACTION FAILED: check-to-stage anchors moved" >&2; exit 2 ;;
esac
case "$SETRES" in set_res*'mv "$RES.tmp" "$RES"'*) ;; *) echo "EXTRACTION FAILED: set_res" >&2; exit 2 ;; esac
case "$LEG" in */data/*|*/system/*) echo "EXTRACTION FAILED: the extract names an absolute path (the harness would have to transform it)" >&2; exit 2 ;; esac

SHELLS=bash
for s in sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

# run_case <shell> <ota-check rc> <ota-check stdout> <restore mode> <pkg yes|no> -- leaves $T set.
# restore modes: ok (both payload files), fail (exit 1), emptyprops, nobin, partial (a non-empty payload.bin, exit 1),
# killed (both files non-empty, exit 124 as timeout returns), none (writes nothing, exit 0).
run_case(){
  T=$(mktemp -d -p "$W") || exit 2; mkdir -p "$T/state" "$T/bin"
  PKGD="$T/ota_package"
  if [ "$5" = yes ]; then
    mkdir -p "$PKGD"; echo stale > "$PKGD/payload.bin"; echo keep > "$PKGD/unrelated.txt"
    INO_BEFORE=$(ls -id "$PKGD" | cut -d' ' -f1)
  else
    INO_BEFORE=absent
  fi
  echo "$2" > "$T/ck.rc"; printf '%s\n' "$3" > "$T/ck.out"; echo "$4" > "$T/rs.mode"
  : > "$T/timeouts"; : > "$T/restorecon.args"; : > "$T/restore.ran"
  cat > "$T/bin/timeout" <<STUB
#!/bin/sh
echo "\$1" >> '$T/timeouts'
shift
exec "\$@"
STUB
  cat > "$T/bin/restorecon" <<STUB
#!/bin/sh
echo "\$*" >> '$T/restorecon.args'
STUB
  cat > "$T/agent" <<STUB
#!/bin/sh
T='$T'
case "\$1" in
  ota-check) cat "\$T/ck.out"; exit "\$(cat "\$T/ck.rc")" ;;
  restore)
    echo "\$1 \$2 \$3 \$4" > "\$T/restore.ran"
    cat "\$RES" > "\$T/restore.res" 2>/dev/null || : > "\$T/restore.res"
    printf '%s' "\${NOWHERE_PHASE-UNSET}" > "\$T/restore.phase"
    printf '%s' "\${NOWHERE_PROGRESS-UNSET}" > "\$T/restore.progenv"
    if [ -e "\$5/payload.bin" ]; then echo present; else echo gone; fi > "\$T/restore.stale"
    [ -n "\${NOWHERE_PROGRESS-}" ] && echo 'osdownload 10 100' > "\$NOWHERE_PROGRESS"
    case "\$(cat "\$T/rs.mode")" in
      ok)         echo bin > "\$5/payload.bin"; echo HEADER=1 > "\$5/payload_properties.txt"; exit 0 ;;
      fail)       exit 1 ;;
      emptyprops) echo bin > "\$5/payload.bin"; : > "\$5/payload_properties.txt"; exit 0 ;;
      nobin)      echo HEADER=1 > "\$5/payload_properties.txt"; exit 0 ;;
      partial)    echo partbin > "\$5/payload.bin"; exit 1 ;;
      killed)     echo partbin > "\$5/payload.bin"; echo HEADER=1 > "\$5/payload_properties.txt"; exit 124 ;;
      *)          exit 0 ;;
    esac ;;
esac
exit 9
STUB
  chmod +x "$T/bin/timeout" "$T/bin/restorecon" "$T/agent"
  {
    cat <<VARS
PATH='$T/bin':\$PATH
STATE='$T/state'; RES="\$STATE/ota.res"; PROG="\$STATE/ota.prog"
LOG='$T/ota.log'; PKG='$PKGD'; AGENT='$T/agent'; OSREF=os-fp3; OSPASS=nowhere-os
export RES
VARS
    printf '%s\n' "$SETRES"
    printf '(\n%s\necho REACHED-APPLY\n)\n' "$LEG"
  } > "$T/run.sh"
  : > "$T/ota.log"
  "$1" "$T/run.sh" > "$T/out" 2>&1
}

res(){ cat "$T/state/ota.res" 2>/dev/null; }
reached(){ grep -q REACHED-APPLY "$T/out" && echo yes || echo no; }
restored(){ [ -s "$T/restore.ran" ] && echo yes || echo no; }
prog(){ [ -e "$T/state/ota.prog" ] && echo present || echo gone; }
files(){ printf '%s %s' "$([ -e "$PKGD/payload.bin" ] && echo bin || echo -)" "$([ -e "$PKGD/payload_properties.txt" ] && echo props || echo -)"; }
ino(){ if [ -d "$PKGD" ]; then ls -id "$PKGD" | cut -d' ' -f1; else echo absent; fi; }
logs(){ grep -c "$1" "$T/ota.log"; }
# every case: the staging dir is the same dir (or still absent) and an unrelated file in it survives
c9(){
  is "$1 PKG inode unchanged" "$(ino)" "$INO_BEFORE"
  [ "$INO_BEFORE" = absent ] || is "$1 unrelated file survives" "$(cat "$PKGD/unrelated.txt" 2>/dev/null)" keep
}

UP='ota-check: UPDATE -> 0.5.44'
NOPUB='ota-check: no published OS version'
for SH in $SHELLS; do
  echo "== $SH"
  # C1: update available, the restore delivers both files
  run_case "$SH" 0 "$UP" ok yes
  is "$SH C1 reaches the apply leg"       "$(reached)" yes
  is "$SH C1 RES was STAGING at restore"  "$(cat "$T/restore.res")" STAGING
  is "$SH C1 restore phase"               "$(cat "$T/restore.phase")" osdownload
  is "$SH C1 restore progress path"       "$(cat "$T/restore.progenv")" "$T/state/ota.prog"
  is "$SH C1 restore args"                "$(cat "$T/restore.ran")" "restore s3 os-fp3 nowhere-os"
  is "$SH C1 timeouts"                    "$(tr '\n' ' ' < "$T/timeouts")" "120 1800 "
  is "$SH C1 PROG gone afterwards"        "$(prog)" gone
  is "$SH C1 restorecon on PKG"           "$(cat "$T/restorecon.args")" "-R $PKGD"
  is "$SH C1 stale payload cleared first" "$(cat "$T/restore.stale")" gone
  c9 "$SH C1"
  # C2: timeout
  run_case "$SH" 124 "" ok yes
  is "$SH C2 RES"                         "$(res)" ERR-CHECK
  is "$SH C2 logs TIMED OUT"              "$(logs 'ota-check TIMED OUT')" 1
  is "$SH C2 no restore"                  "$(restored)" no
  is "$SH C2 no apply"                    "$(reached)" no
  c9 "$SH C2"
  # C3: NONE only when ota-check said so -- rc 3 with its own line (NWP-20261123-25)
  run_case "$SH" 3 "$NOPUB" ok yes
  is "$SH C3 RES"                         "$(res)" NONE
  is "$SH C3 logs no published version"   "$(logs 'no published version (rc=3)')" 1
  is "$SH C3 no restore"                  "$(restored)" no
  is "$SH C3 no apply"                    "$(reached)" no
  c9 "$SH C3"
  # C3b: rc 3 without the line is no answer
  run_case "$SH" 3 "" ok yes
  is "$SH C3b RES"                        "$(res)" ERR-CHECK
  is "$SH C3b logs ota-check FAILED"      "$(logs 'ota-check FAILED (rc=3)')" 1
  is "$SH C3b no NONE log line"           "$(logs 'no published version')" 0
  is "$SH C3b no restore"                 "$(restored)" no
  c9 "$SH C3b"
  # C4: an unrecovered panic (rc 2) is ERR-CHECK; C4b: the NONE line alone is not enough on another rc
  run_case "$SH" 2 "panic: runtime error" ok yes
  is "$SH C4 RES"                         "$(res)" ERR-CHECK
  is "$SH C4 logs ota-check FAILED"       "$(logs 'ota-check FAILED (rc=2)')" 1
  is "$SH C4 no restore"                  "$(restored)" no
  is "$SH C4 no apply"                    "$(reached)" no
  c9 "$SH C4"
  run_case "$SH" 2 "$NOPUB" ok yes
  is "$SH C4b RES"                        "$(res)" ERR-CHECK
  is "$SH C4b no restore"                 "$(restored)" no
  c9 "$SH C4b"
  # C13: an agent that is not executable (126) or not there (127), and a kill (137)
  for xrc in 126 127 137; do
    run_case "$SH" "$xrc" "" ok yes
    is "$SH C13 rc $xrc RES"                "$(res)" ERR-CHECK
    is "$SH C13 rc $xrc logs FAILED"        "$(logs "ota-check FAILED (rc=$xrc)")" 1
    is "$SH C13 rc $xrc no restore"         "$(restored)" no
    c9 "$SH C13 rc $xrc"
  done
  # C5: smoke -- the store was unreachable
  run_case "$SH" 5 "" ok yes
  is "$SH C5 RES"                         "$(res)" ERR-CHECK
  is "$SH C5 no restore"                  "$(restored)" no
  c9 "$SH C5"
  # C6: the restore fails after writing its progress frame
  run_case "$SH" 0 "$UP" fail yes
  is "$SH C6 RES"                         "$(res)" ERR-RESTORE
  is "$SH C6 PROG removed"                "$(prog)" gone
  is "$SH C6 no apply"                    "$(reached)" no
  is "$SH C6 stale payload cleared first" "$(cat "$T/restore.stale")" gone
  c9 "$SH C6"
  # C7: payload_properties.txt empty; C8: payload.bin missing
  run_case "$SH" 0 "$UP" emptyprops yes
  is "$SH C7 RES"                         "$(res)" ERR-PAYLOAD
  is "$SH C7 no apply"                    "$(reached)" no
  is "$SH C7 stale payload cleared first" "$(cat "$T/restore.stale")" gone
  is "$SH C7 payload files removed"       "$(files)" "- -"
  is "$SH C7 removal logged"              "$(logs 'after an incomplete download (NWP-20261120-11)')" 1
  c9 "$SH C7"
  run_case "$SH" 0 "$UP" nobin yes
  is "$SH C8 RES"                         "$(res)" ERR-PAYLOAD
  is "$SH C8 no apply"                    "$(reached)" no
  is "$SH C8 stale payload cleared first" "$(cat "$T/restore.stale")" gone
  is "$SH C8 payload files removed"       "$(files)" "- -"
  is "$SH C8 removal logged"              "$(logs 'after an incomplete download (NWP-20261120-11)')" 1
  c9 "$SH C8"
  # C11: the restore fails part way through; C12: timeout kills it (rc 124). Both leave partial files in PKG.
  run_case "$SH" 0 "$UP" partial yes
  is "$SH C11 RES"                        "$(res)" ERR-RESTORE
  is "$SH C11 no apply"                   "$(reached)" no
  is "$SH C11 payload files removed"      "$(files)" "- -"
  is "$SH C11 removal logged"             "$(logs 'after a failed download (NWP-20261120-11)')" 1
  c9 "$SH C11"
  run_case "$SH" 0 "$UP" killed yes
  is "$SH C12 RES"                        "$(res)" ERR-RESTORE
  is "$SH C12 PROG removed"               "$(prog)" gone
  is "$SH C12 no apply"                   "$(reached)" no
  is "$SH C12 payload files removed"      "$(files)" "- -"
  is "$SH C12 removal logged"             "$(logs 'after a failed download (NWP-20261120-11)')" 1
  c9 "$SH C12"
  # C10: the staging dir is absent -- the script must not create it
  run_case "$SH" 0 "$UP" none no
  c9 "$SH C10"
  case "$(res)" in ERR-RESTORE|ERR-PAYLOAD) ok "$SH C10 ends in an error verdict" ;; *) no "$SH C10 RES [$(res)]" ;; esac
  is "$SH C10 no apply"                   "$(reached)" no
done
echo "shells run: $SHELLS"

echo "behaviour: $PASS passed, $FAIL failed"
[ "$MUTATE" = no ] && { [ "$FAIL" = 0 ]; exit; }
[ "$FAIL" = 0 ] || { echo "control (unmutated) failed -- mutations are meaningless" >&2; exit 1; }

# --- mutations -------------------------------------------------------------------------------------------
M=0; BAD=0
mutate(){                      # mutate <label> <from> <to> [<from2> <to2>]
  local content new f rc out
  content=$(<"$OTAD"); new=${content/"$2"/"$3"}
  [ -z "${4:-}" ] || new=${new/"$4"/"$5"}
  if [ "$content" = "$new" ]; then echo "  HARNESS FAIL  mutant $1 did not change the text"; BAD=$((BAD+1)); return; fi
  f=$(mktemp -p "$W") || exit 2; printf '%s\n' "$new" > "$f"
  out=$(bash "$SELF" "$f" 2>&1); rc=$?
  rm -f "$f"
  M=$((M+1))
  if [ "$rc" = 1 ]; then echo "  convicted  $1"; else echo "  SURVIVED   $1 (rc=$rc)"; BAD=$((BAD+1)); fi
}
CLR='rm -f "$PKG/payload.bin" "$PKG/payload_properties.txt"'
mutate '1 files-only clear becomes rm -rf of the dir' "$CLR" 'rm -rf "$PKG"'
mutate '2 mkdir -p of the staging dir'                "$CLR" "$CLR"$'\n''mkdir -p "$PKG"'
mutate '3 rc 124 line dropped'                         'if [ "$rc" = 124 ]; then' 'if false; then'
mutate '4 ERR-RESTORE branch falls through'            'set_res "ERR-RESTORE"; exit 0' 'set_res "ERR-RESTORE"'
mutate '5 payload check removed'                       '[ -s "$PKG/payload.bin" ] && [ -s "$PKG/payload_properties.txt" ] || {' 'true || {'
mutate '6 PROG kept on restore failure'                'rm -f "$PROG"; set_res "ERR-RESTORE"' 'set_res "ERR-RESTORE"'
mutate '7 NOWHERE_PHASE dropped'                       'NOWHERE_PROGRESS="$PROG" NOWHERE_PHASE=osdownload' 'NOWHERE_PROGRESS="$PROG"'
mutate '8 STAGING set after the restore'               '; set_res "STAGING"' '' 'restorecon -R "$PKG"' $'set_res "STAGING"\nrestorecon -R "$PKG"'
# 9-12 (NWP-20261120-11): each needle holds its branch's own log text, so it matches only that branch's line.
RRM='rm -f "$PKG/payload.bin" "$PKG/payload_properties.txt"; echo "[otad] partial payload removed from $PKG after a failed download'
PRM='rm -f "$PKG/payload.bin" "$PKG/payload_properties.txt"; echo "[otad] partial payload removed from $PKG after an incomplete download'
PRML="$PRM"' (NWP-20261120-11) $(date)" >> "$LOG";'
mutate '9 ERR-RESTORE removal dropped'                 "$RRM" 'echo "[otad] partial payload removed from $PKG after a failed download'
mutate '10 ERR-PAYLOAD removal dropped'                "$PRM" 'echo "[otad] partial payload removed from $PKG after an incomplete download'
mutate '11 ERR-RESTORE removal widened to rm -rf PKG'  "$RRM" 'rm -rf "$PKG"; echo "[otad] partial payload removed from $PKG after a failed download'
mutate '12 ERR-PAYLOAD removal after its exit 0'       "$PRML"' set_res "ERR-PAYLOAD"; exit 0;' 'set_res "ERR-PAYLOAD"; exit 0; '"$PRML"
# 13-17 (NWP-20261123-25): NONE only for rc 3 with ota-check's own line, ERR-CHECK for every other non-zero status.
NONE_IF='if [ "$rc" = 3 ] && [ "${out#*ota-check: no published OS version}" != "$out" ]; then'
FAILB='if [ "$rc" != 0 ]; then echo "[otad] ota-check FAILED (rc=$rc) $(date)" >> "$LOG"; set_res "ERR-CHECK"; exit 0; fi'
OLDCATCH='if [ "$rc" != 0 ]; then echo "[otad] no published version (rc=$rc) $(date)" >> "$LOG"; set_res "NONE"; exit 0; fi'
mutate '13 catch-all restored to NONE'                 "$FAILB" "$OLDCATCH"
mutate '14 rc 3 line drops its stdout check'           "$NONE_IF" 'if [ "$rc" = 3 ]; then'
mutate '15 the unknown-status line answers NONE'       '(rc=$rc) $(date)" >> "$LOG"; set_res "ERR-CHECK"' '(rc=$rc) $(date)" >> "$LOG"; set_res "NONE"'
mutate '16 unknown-status line removed (falls to STAGING)' "$FAILB"$'\n' ''
mutate '17 rc 3 line drops its rc test'                 "$NONE_IF" 'if [ "${out#*ota-check: no published OS version}" != "$out" ]; then'
echo "mutations: $M run, $BAD not convicted"
[ "$BAD" = 0 ] && [ "$M" = 17 ]
