#!/usr/bin/env bash
# test-otad-apply.sh [<nowhere_otad.sh>] [--mutate] -- execute nowhere_otad.sh's APPLY LEG off-device
# (NWP-20261017-14).
#
# WHY THIS IS COMMITTED. The leg's own comment says it: a failed apply must not read as success, "so the phone
# would reboot into an unwritten slot". The real exit status is carried out of
# `( timeout ... update_engine_client ... ; echo "$?" > "$RC" ) | while ...` through $RC, and a missing status
# file must read as FAILURE. Only rc 0 sets `OK <ver>`, records the reboot reason and runs `sync; reboot`.
# The progress parser (UPDATE_STATUS_<X> frames -> `<phase> <pct> 100`, `0.08` -> 8 not an octal error, suffix
# matched names, write only on change, non-frame lines kept verbatim) is silent when it breaks: the first
# 0.5.12 apply matched nothing. test-otad-wakelock.sh and test-restore-net-verdict.sh each run a different slice
# of this file; nothing ran this one, so a regression here was found by a real OTA, if at all.
#
# The leg is extracted from nowhere_otad.sh BY ANCHOR, never copied: from the line `UE_OPEN='onStatusUpdate('`
# through the last line of the file, plus the set_res and record_reboot_reason definitions. A moved anchor, or an
# extract missing `echo "$?" > "$RC"` or `sync; reboot`, is rc 2 (EXTRACTION FAILED).
#
# THE ONE TRANSFORM, stated because a test that quietly rewrites its subject is not testing it: the absolute
# paths (/data/nowhere/, /proc/sys/kernel/random/boot_id) are redirected into a scratch dir. Nothing else in the
# extracted text is altered. The commands the leg calls (update_engine_client, timeout, susp, sync, reboot,
# date, mv) are shell functions defined before it; STATE/RES/PROG/RC/LOG/LASTREBOOT/PKG/ver are assigned by the
# harness (those lines are outside the extracted range). `mv` additionally records every $PROG write.
#
#   bash test-otad-apply.sh             # the cases, under bash and (when on PATH) mksh, the device shell, in its
#                                       # default and its `-o posix` mode
#   bash test-otad-apply.sh --mutate    # ... plus 12 mutations that must each CONVICT the suite
#
# Not dash: `10#` is not POSIX and the production shell (/system/bin/sh) is mksh.
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
LEG=$(sed -n "/^UE_OPEN='onStatusUpdate('\$/,\$p" "$OTAD")
FUNCS=$(grep '^set_res()' "$OTAD"; sed -n '/^record_reboot_reason() {$/,/^}$/p' "$OTAD")
case "$LEG" in *'echo "$?" > "$RC"'*'sync; reboot'*) ;; *) echo "EXTRACTION FAILED: apply leg anchors moved" >&2; exit 2 ;; esac
case "$FUNCS" in set_res*record_reboot_reason*"mv -f"*) ;; *) echo "EXTRACTION FAILED: set_res/record_reboot_reason" >&2; exit 2 ;; esac

SHELLS=bash
# mksh-posix is mksh under `-o posix`, where a leading-zero literal is octal as it is in bash; in mksh's default mode
# it is decimal, so `$((08))` is 8 there and mutant 3 (dropping `10#`) changes nothing. The wrapper lets mutant 3 be
# convicted under a mksh, not only under bash (see its line below).
if command -v mksh >/dev/null 2>&1; then
  mkdir -p "$W/bin" && printf '#!/bin/sh\nexec mksh -o posix "$@"\n' > "$W/bin/mksh-posix" && chmod +x "$W/bin/mksh-posix" || exit 2
  PATH="$W/bin:$PATH"; SHELLS="bash mksh mksh-posix"
fi

FRAME_PFX='[INFO:update_engine_client_android.cc(94)] onStatusUpdate('
# frame <STATUS_NAME> <code> <fraction> -- the exact device shape
frame(){ printf '%sUPDATE_STATUS_%s (%s), %s)\n' "$FRAME_PFX" "$1" "$2" "$3"; }
bare(){ printf '%s%s (%s), %s)\n' "$FRAME_PFX" "$1" "$2" "$3"; }

# run_case <shell> <ue exit code> <kill yes|no> -- client output is read from stdin; leaves $T set.
run_case(){
  T=$(mktemp -d -p "$W") || exit 2; mkdir -p "$T/state" "$T/pkg"
  cat > "$T/ue.script"
  echo 'HEADER=1' > "$T/pkg/payload_properties.txt"; echo PAYLOAD > "$T/pkg/payload.bin"
  {
    cat <<STUBS
T='$T'
STATE="\$T/state"; RES="\$STATE/ota.res"; PROG="\$STATE/ota.prog"; RC="\$STATE/ota.rc"
LOG="\$T/ota.log"; LASTREBOOT="\$T/last-reboot"; PKG="\$T/pkg"; ver=9.9.9
CALLS="\$T/calls"; WRITES="\$T/writes"; : > "\$CALLS"; : > "\$WRITES"; : > "\$LOG"
echo boot-1234 > "\$T/boot_id"
update_engine_client() {
  [ "\$1" = --reset_status ] && return 0
  while IFS= read -r l; do printf '%s\n' "\$l"; done < "\$T/ue.script"
  if [ "$3" = yes ]; then sh -c 'kill -9 \$PPID'; sleep 2; fi
  return $2
}
timeout() { shift; "\$@"; }
susp() { echo 5; }
sync() { :; }
reboot() { echo REBOOT >> "\$CALLS"; if [ -e "\$PKG/payload.bin" ]; then echo present > "\$T/at-reboot"; else echo absent > "\$T/at-reboot"; fi; }
date() { if [ "\$1" = +%s ]; then echo 1000; else echo FIXED-DATE; fi; }
mv() { case "\$*" in *ota.prog.tmp*) cat "\$PROG.tmp" >> "\$WRITES" ;; esac; command mv "\$@"; }
STUBS
    printf '%s\n%s\n' "$FUNCS" "$LEG" | sed "s#/data/nowhere/#$T/#g; s#/proc/sys/kernel/random/boot_id#$T/boot_id#g"
  } > "$T/run.sh"
  "$1" "$T/run.sh" > "$T/out" 2>&1
}

calls(){ grep -c REBOOT "$T/calls" 2>/dev/null; }
res(){ cat "$T/state/ota.res" 2>/dev/null; }
pkgfiles(){ for f in payload.bin payload_properties.txt; do [ -e "$T/pkg/$f" ] && printf '%s ' "$f"; done; echo; }
kept(){ is "$1: both payload files kept" "$(pkgfiles)" "payload.bin payload_properties.txt "; is "$1: no removal line" "$(grep -c 'applied payload removed' "$T/ota.log")" 0; }

for SH in $SHELLS; do
  echo "== $SH"
  # (a) success: four frames, rc 0
  run_case "$SH" 0 no < <({ frame DOWNLOADING 3 0.4530; frame VERIFYING 4 0.08; frame FINALIZING 5 1; frame UPDATED_NEED_REBOOT 6 0; })
  is "$SH a: RES"                 "$(res)" "OK 9.9.9"
  is "$SH a: reboot called once"  "$(calls)" 1
  case "$(cat "$T/last-reboot" 2>/dev/null)" in *"otad: OTA 9.9.9 applied"*boot-1234*|*boot-1234*"otad: OTA 9.9.9 applied"*) ok "$SH a: last-reboot holds the reason" ;; *) no "$SH a: last-reboot [$(cat "$T/last-reboot" 2>/dev/null)]" ;; esac
  is "$SH a: PROG removed"        "$([ -e "$T/state/ota.prog" ] && echo present || echo gone)" gone
  is "$SH a: PROG writes"         "$(tr '\n' '|' < "$T/writes")" "oswrite 45 100|osverify 8 100|osfinalize 100 100|osdone 100 100|"
  # NWP-20261109-10 P1/P2: rc 0 removes the payload files (not the dir) before the reboot
  is "$SH P1: payload files removed"   "$(pkgfiles)" ""
  is "$SH P1: PKG dir still exists"    "$([ -d "$T/pkg" ] && echo yes || echo no)" yes
  case "$(cat "$T/ota.log")" in *"[otad] applied payload removed from $T/pkg (NWP-20261109-10) FIXED-DATE"*) ok "$SH P1: removal line logged" ;; *) no "$SH P1: removal line missing" ;; esac
  is "$SH P2: payload gone when reboot ran" "$(cat "$T/at-reboot" 2>/dev/null)" absent
  # (b) client exits 1
  run_case "$SH" 1 no < <({ frame DOWNLOADING 3 0.4530; })
  is "$SH b: RES"                 "$(res)" ERR-APPLY
  is "$SH b: no reboot"           "$(calls)" 0
  is "$SH b: no last-reboot"      "$([ -e "$T/last-reboot" ] && echo present || echo none)" none
  kept "$SH P3 rc 1"
  # (f) client exits 2 -- only 0 reboots
  run_case "$SH" 2 no < <({ :; })
  is "$SH f: rc 2 RES"            "$(res)" ERR-APPLY
  is "$SH f: rc 2 no reboot"      "$(calls)" 0
  kept "$SH P3 rc 2"
  # (c) $RC never written: the client kills its own subshell
  run_case "$SH" 0 yes < <({ frame DOWNLOADING 3 0.4530; })
  is "$SH c: no status file -> RES" "$(res)" ERR-APPLY
  is "$SH c: no status file -> no reboot" "$(calls)" 0
  is "$SH c: no last-reboot"      "$([ -e "$T/last-reboot" ] && echo present || echo none)" none
  kept "$SH P3 no status file"
  # (d) non-frame line verbatim, IDLE writes nothing, identical frames write once
  run_case "$SH" 0 no < <({ echo '[ERROR:update_engine.cc(7)] something went wrong'; frame IDLE 0 0; frame DOWNLOADING 3 0.4530; frame DOWNLOADING 3 0.4530; })
  case "$(cat "$T/ota.log")" in *'[ERROR:update_engine.cc(7)] something went wrong'*) ok "$SH d: diagnostic line verbatim in log" ;; *) no "$SH d: diagnostic line missing from log" ;; esac
  is "$SH d: IDLE + duplicate -> one write" "$(tr '\n' '|' < "$T/writes")" "oswrite 45 100|"
  # (e) bare names still map (suffix match)
  run_case "$SH" 0 no < <({ bare DOWNLOADING 3 0.5000; bare VERIFYING 4 0.2; })
  is "$SH e: bare names"          "$(tr '\n' '|' < "$T/writes")" "oswrite 50 100|osverify 20 100|"
  # (g)-(i) NWP-20261121-11: a %g scientific-notation fraction is below 1 %, never 100 %
  run_case "$SH" 0 no < <({ frame DOWNLOADING 3 1.52588e-05; frame DOWNLOADING 3 0.4530; frame VERIFYING 4 1.0e-06; frame VERIFYING 4 0.2; })
  is "$SH g: scientific fraction -> 0" "$(tr '\n' '|' < "$T/writes")" "oswrite 0 100|oswrite 45 100|osverify 0 100|osverify 20 100|"
  is "$SH g: RES"                 "$(res)" "OK 9.9.9"
  run_case "$SH" 0 no < <({ frame FINALIZING 5 1.5E-05; })
  is "$SH h: capital E -> 0"      "$(tr '\n' '|' < "$T/writes")" "osfinalize 0 100|"
  # (i) a non-1 mantissa read 0 before the fix too; kept so a fix for `1.` alone is not taken for the rule
  run_case "$SH" 0 no < <({ frame DOWNLOADING 3 7.62939e-06; })
  is "$SH i: 7.62939e-06 -> 0"    "$(tr '\n' '|' < "$T/writes")" "oswrite 0 100|"
done
# P4 source pin: no line of the extracted leg removes or creates the PKG directory itself
P4=$(printf '%s\n' "$LEG" | grep -E '(rm +-[a-zA-Z]*[rR]|rmdir|mkdir)[^;|&]*"\$PKG/?"' || true)
is "P4: leg never rm -r/rmdir/mkdirs \"\$PKG\"" "$P4" ""

echo "shells run: $SHELLS$([ "$SHELLS" = bash ] && echo ' (mksh not on PATH)')"

echo "behaviour: $PASS passed, $FAIL failed"
[ "$MUTATE" = no ] && { [ "$FAIL" = 0 ]; exit; }
[ "$FAIL" = 0 ] || { echo "control (unmutated) failed -- mutations are meaningless" >&2; exit 1; }

# --- mutations -------------------------------------------------------------------------------------------
M=0; BAD=0
mutate(){                      # mutate <label> <from> <to> [<shell where the mutant is equivalent>]
  local content new f rc out sh miss
  content=$(<"$OTAD"); new=${content/"$2"/"$3"}
  if [ "$content" = "$new" ]; then echo "  HARNESS FAIL  mutant $1 did not change the text"; BAD=$((BAD+1)); return; fi
  f=$(mktemp -p "$W") || exit 2; printf '%s\n' "$new" > "$f"
  out=$(bash "$SELF" "$f" 2>&1); rc=$?
  rm -f "$f"
  M=$((M+1))
  # One verdict PER SHELL: the recursive run shares one FAIL counter, so its exit status alone would call a
  # mutant convicted when only bash saw it and mksh (the device shell) let it through. Every shell the control
  # run used must show a FAIL line carrying its own label.
  miss=""
  for sh in $SHELLS; do
    if [ "$sh" = "${4:-}" ]; then echo "  equivalent $1 [$sh] -- not a behaviour change in this shell"; continue; fi
    case "$out" in *"  FAIL  $sh "*) echo "  convicted  $1 [$sh]" ;; *) echo "  SURVIVED   $1 [$sh]"; miss="$miss $sh" ;; esac
  done
  if [ "$rc" = 1 ] && [ -z "$miss" ]; then :; else echo "  NOT CONVICTED  $1 (rc=$rc${miss:+, surviving:$miss})"; BAD=$((BAD+1)); fi
}
mutate '1 missing status file reads as success' 'rc=${rc:-1}' 'rc=${rc:-0}'
mutate '2 pipeline status instead of $RC'       'rc=$(cat "$RC" 2>/dev/null); rc=${rc:-1}; rm -f "$RC"' 'rc=$?; rm -f "$RC"'
# 3 is equivalent under default-mode mksh only (a leading-zero literal is decimal there); bash and mksh-posix convict.
mutate '3 octal-unsafe percent'                  'pct=$((10#$d))' 'pct=$(($d))' mksh
mutate '4 prefix-less DOWNLOADING pattern'       '*DOWNLOADING)             ph=oswrite' 'DOWNLOADING)             ph=oswrite'
mutate '5 write-on-change guard removed'         '[ "$ph $pct" = "$last" ] && continue' ':'
mutate '6 reboot on any rc but 1'                'if [ "$rc" = 0 ]' 'if [ "$rc" != 1 ]'
mutate '7 diagnostic line no longer logged'      "*) printf '%s\\n' \"\$line\" >> \"\$LOG\"; continue ;;" '*) continue ;;'
NL=$'\n'
REML='  rm -f "$PKG/payload.bin" "$PKG/payload_properties.txt"; echo "[otad] applied payload removed from $PKG (NWP-20261109-10) $(date)" >> "$LOG"'
mutate 'N1 payload removal deleted'               "$REML${NL}  sync; reboot" '  sync; reboot'
mutate 'N2 removal moved after sync; reboot'      "$REML${NL}  sync; reboot" "  sync; reboot$NL$REML"
mutate 'N3 removal on every rc (failure branch too)' 'rm -f "$PROG"; set_res "ERR-APPLY"' "rm -f \"\$PROG\"; set_res \"ERR-APPLY\";$NL$REML"
mutate 'N4 rm -rf "$PKG" in its place'            '  rm -f "$PKG/payload.bin" "$PKG/payload_properties.txt"; echo "[otad] applied payload removed' '  rm -rf "$PKG"; echo "[otad] applied payload removed'
mutate '8 scientific-notation arm removed'       "    *[eE]*) pct=0 ;;$NL" ''
echo "mutations: $M run, $BAD not convicted"
[ "$BAD" = 0 ] && [ "$M" = 12 ]
