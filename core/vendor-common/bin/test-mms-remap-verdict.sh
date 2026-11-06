#!/usr/bin/env bash
# NWP-20261124-27: the sign-in's MMS part-path remap (#148) logs what nowhere_db_fix returned.
#
# The `in` arm of nowhere_roamd.sh rewrites the restored mmssms.db's part._data paths to THIS user with
# `/system/bin/nowhere_db_fix mms-remap`. The call is best-effort and never fails the sign-in. It used to be
# followed by an unconditional "[roamd] remapped MMS part._data -> user N" line, so a locked or malformed db
# (rc 3 or 6) or a missing tool (rc 127) read as success in roam.log while every attachment rendered blank.
#
# This suite extracts the block BY ANCHOR from nowhere_roamd.sh (the `        TELDB=` line to the first line that
# is exactly `        fi`; the block sits inside the sign-in's `if [ -z "$_innet" ]`, NWP-20261124-05), rewrites the tool path and the /data/user/ prefix into a temp root, and runs it
# under every shell found (bash as `bash --posix`, sh, dash, mksh; deduplicated by resolved path):
#   C1 rc 0: the "remapped" line, byte for byte as before, and the tool's argv is `mms-remap <db> 10`;
#   C2 rc 3: a FAILED rc=3 line, no "remapped" line, and the block's own status is 0;
#   C3 no tool (rc 127): the NOT remapped / missing line, no "remapped" line;
#   C4 no mmssms.db: no tool call and no MMS line;
#   C5 rc 6 with stderr text: roamd's own line holds neither the db path nor the tool's text
#      (the tool's stderr still goes to the log, as before).
# --mutate re-runs the cases on broken copies of the block; each must be CONVICTED under every shell:
#   M1 the unconditional "remapped" line restored; M2 `|| true` restored before the status read;
#   M3 the FAILED line printed on rc 0; M4 the tool's stderr captured into roamd's line.
#
# Usage: bash test-mms-remap-verdict.sh [--mutate]     (SUT=<roamd copy> to run against another copy)
set -uo pipefail

MUTATE=no
[ "${1:-}" = --mutate ] && MUTATE=yes
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "FAIL: no $SUT"; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=()
seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$p")
done
[ "${#SHELLS[@]}" -gt 0 ] || { echo "FAIL: no shell found"; exit 2; }
echo "shells: ${SHELLS[*]}"

ANCHOR='        TELDB="/data/user/$uid/com.android.providers.telephony/databases/mmssms.db"'
BLOCK="$W/block.sh"
awk -v a="$ANCHOR" '$0 == a {f=1} f {print} f && $0 == "        fi" {exit}' "$SUT" > "$BLOCK"
if [ ! -s "$BLOCK" ] || ! grep -q 'mms-remap' "$BLOCK"; then
  echo "FAIL: could not extract the TELDB block from $SUT"; exit 2
fi
case "$(tail -n 1 "$BLOCK")" in
  "        fi") ;;
  *) echo "FAIL: the TELDB block has no closing fi in $SUT"; exit 2 ;;
esac

# count_fixed <file> <string>: how many lines of <file> hold <string> (fixed text, not a pattern).
count_fixed() {
  awk -v s="$2" 'index($0, s) {n++} END {print n + 0}' "$1"
}

# subst_once <in> <out> <from> <to>: replace the one occurrence of the fixed text <from>; non-zero if it is not
# exactly one line holding it once.
subst_once() {
  local n
  n=$(count_fixed "$1" "$3")
  [ "$n" = 1 ] || return 1
  awk -v f="$3" -v t="$4" '{
    i = index($0, f)
    if (i) { $0 = substr($0, 1, i - 1) t substr($0, i + length(f)) }
    print
  }' "$1" > "$2"
  [ "$(count_fixed "$2" "$3")" = 0 ]
}

# prep <block> <T> <out>: point the tool and the db prefix into the case's temp root <T>.
prep() {
  subst_once "$1" "$3.a" '/system/bin/nowhere_db_fix mms-remap' "$2/bin/nowhere_db_fix mms-remap" || return 1
  subst_once "$3.a" "$3" '"/data/user/' "\"$2/data/user/" || return 1
}

OK='[roamd] remapped MMS part._data -> user 10 DATE'
MISS='[roamd] MMS part._data NOT remapped -- /system/bin/nowhere_db_fix missing or not executable (rc=127, user 10; attachments of restored MMS may show blank) (NWP-20261124-27) DATE'
F3='[roamd] MMS part._data remap FAILED rc=3 (user 10; attachments of restored MMS may show blank) (NWP-20261124-27) DATE'
F6='[roamd] MMS part._data remap FAILED rc=6 (user 10; attachments of restored MMS may show blank) (NWP-20261124-27) DATE'
SUCCESS='remapped MMS part._data'
MARK='MARKER-STDERR-NWP-20261124-27'
DBREL='data/user/10/com.android.providers.telephony/databases/mmssms.db'

# run_case <shell> <block> <mode> <db yes|no>: sets T (the case root), MMS (roamd's MMS lines) and BRC (the
# block's own status). Returns non-zero when the block could not be prepared.
T=; MMS=; BRC=
run_case() {
  local sh=$1 blk=$2 mode=$3 db=$4 out
  T=$(mktemp -d -p "$W") || return 1
  mkdir -p "$T/bin" "$T/data/user/10/com.android.providers.telephony/databases"
  [ "$db" = yes ] && : > "$T/$DBREL"
  case "$mode" in
    ok)  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\nexit 0\n' "$T" > "$T/bin/nowhere_db_fix" ;;
    rc3) printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\nexit 3\n' "$T" > "$T/bin/nowhere_db_fix" ;;
    rc6err) printf '#!/bin/sh\necho "nowhere_db_fix: $2 %s" >&2\nexit 6\n' "$MARK" > "$T/bin/nowhere_db_fix" ;;
    missing) ;;
  esac
  [ -f "$T/bin/nowhere_db_fix" ] && chmod +x "$T/bin/nowhere_db_fix"
  prep "$blk" "$T" "$T/block" || return 1
  {
    printf 'LOG="%s/log"; uid=10\n' "$T"
    printf 'date() { echo DATE; }\n'
    cat "$T/block"
    printf 'echo "blockrc=$?"\n'
  } > "$T/run.sh"
  : > "$T/log"
  if [ "${sh##*/}" = bash ]; then out=$("$sh" --posix "$T/run.sh" 2>/dev/null)
  else out=$("$sh" "$T/run.sh" 2>/dev/null); fi
  BRC=${out##*blockrc=}
  MMS=$(grep '^\[roamd\] .*MMS' "$T/log" || true)
  return 0
}

# cases <shell> <block> <label>: runs C1-C5; prints a line per check when label is real; returns the
# number of failed checks (a block that cannot be prepared counts as a failure).
cases() {
  local sh=$1 blk=$2 label=$3 fails=0 argv log
  chk() {
    if [ "$1" = 0 ]; then [ "$label" = real ] && echo "PASS: $2 [$sh]"
    else fails=$((fails + 1)); [ "$label" = real ] && echo "FAIL: $2 [$sh]"; fi
    return 0
  }
  t() { if "$@"; then echo 0; else echo 1; fi; }

  if run_case "$sh" "$blk" ok yes; then
    argv=$(cat "$T/argv" 2>/dev/null || true)
    chk "$(t [ "$MMS" = "$OK" ])" "C1 rc 0 logs exactly the remapped line"
    chk "$(t [ "$argv" = "$(printf 'mms-remap\n%s\n10' "$T/$DBREL")" ])" "C1 the tool is called as mms-remap <db> 10"
    chk "$(t [ "$BRC" = 0 ])" "C1 the block's status is 0"
  else chk 1 "C1 block prepared"; fi

  if run_case "$sh" "$blk" rc3 yes; then
    chk "$(t [ "$MMS" = "$F3" ])" "C2 rc 3 logs the FAILED rc=3 line"
    case "$MMS" in *"$SUCCESS"*) chk 1 "C2 rc 3 does not log remapped" ;; *) chk 0 "C2 rc 3 does not log remapped" ;; esac
    chk "$(t [ "$BRC" = 0 ])" "C2 the block's status is 0 after rc 3"
  else chk 1 "C2 block prepared"; fi

  if run_case "$sh" "$blk" missing yes; then
    chk "$(t [ "$MMS" = "$MISS" ])" "C3 a missing tool logs the NOT remapped line"
    case "$MMS" in *"$SUCCESS"*) chk 1 "C3 a missing tool does not log remapped" ;; *) chk 0 "C3 a missing tool does not log remapped" ;; esac
    chk "$(t [ "$BRC" = 0 ])" "C3 the block's status is 0 with no tool"
  else chk 1 "C3 block prepared"; fi

  if run_case "$sh" "$blk" ok no; then
    chk "$(t [ ! -e "$T/argv" ])" "C4 no mmssms.db: the tool is not called"
    chk "$(t [ -z "$MMS" ])" "C4 no mmssms.db: no MMS line"
    chk "$(t [ "$BRC" = 0 ])" "C4 the block's status is 0 with no db"
  else chk 1 "C4 block prepared"; fi

  if run_case "$sh" "$blk" rc6err yes; then
    chk "$(t [ "$MMS" = "$F6" ])" "C5 rc 6 logs the FAILED rc=6 line"
    case "$MMS" in *mmssms.db*|*"$T"*) chk 1 "C5 roamd's line holds no db path" ;; *) chk 0 "C5 roamd's line holds no db path" ;; esac
    case "$MMS" in *"$MARK"*) chk 1 "C5 roamd's line holds no tool stderr" ;; *) chk 0 "C5 roamd's line holds no tool stderr" ;; esac
    log=$(cat "$T/log")
    case "$log" in *"$MARK"*) chk 0 "C5 the tool's stderr still goes to the log" ;; *) chk 1 "C5 the tool's stderr still goes to the log" ;; esac
  else chk 1 "C5 block prepared"; fi

  return "$fails"
}

TOTAL=0
echo "== NWP-20261124-27: the MMS remap logs the tool's exit status =="
for SH in "${SHELLS[@]}"; do
  cases "$SH" "$BLOCK" real; TOTAL=$((TOTAL + $?))
done

if [ "$MUTATE" = yes ]; then
  echo "== --mutate: each broken block must be convicted under every shell =="
  CALL='          /system/bin/nowhere_db_fix mms-remap "$TELDB" "$uid" </dev/null >/dev/null 2>> "$LOG"'
  OKECHO='            0) echo "[roamd] remapped MMS part._data -> user $uid $(date)" >> "$LOG" ;;'
  FAILTAIL='(user $uid; attachments of restored MMS may show blank) (NWP-20261124-27) $(date)" >> "$LOG" ;;'

  # mutant <name> <out>: writes the broken copy of $BLOCK; non-zero if the edit did not apply exactly once.
  mutant() {
    local n
    case "$1" in
      M1) n=$(awk -v c="$CALL" '$0 == c {n++} END {print n + 0}' "$BLOCK"); [ "$n" = 1 ] || return 1
          awk -v c="$CALL" '{print} $0 == c {print "          echo \"[roamd] remapped MMS part._data -> user $uid $(date)\" >> \"$LOG\""}' "$BLOCK" > "$2" ;;
      M2) n=$(awk -v c="$CALL" '$0 == c {n++} END {print n + 0}' "$BLOCK"); [ "$n" = 1 ] || return 1
          awk -v c="$CALL" '$0 == c {$0 = $0 " || true"} {print}' "$BLOCK" > "$2" ;;
      M3) n=$(awk -v c="$OKECHO" '$0 == c {n++} END {print n + 0}' "$BLOCK"); [ "$n" = 1 ] || return 1
          awk -v c="$OKECHO" '$0 == c {$0 = "            0) echo \"[roamd] MMS part._data remap FAILED rc=$_mmsrc (user $uid; attachments of restored MMS may show blank) (NWP-20261124-27) $(date)\" >> \"$LOG\" ;;"} {print}' "$BLOCK" > "$2" ;;
      M4) n=$(awk -v c="$CALL" '$0 == c {n++} END {print n + 0}' "$BLOCK"); [ "$n" = 1 ] || return 1
          n=$(awk -v f="$FAILTAIL" 'index($0, "remap FAILED") && index($0, f) {n++} END {print n + 0}' "$BLOCK"); [ "$n" = 1 ] || return 1
          awk -v c="$CALL" -v f="$FAILTAIL" '
            $0 == c { $0 = "          _mmserr=$(/system/bin/nowhere_db_fix mms-remap \"$TELDB\" \"$uid\" </dev/null 2>&1 >/dev/null)" }
            index($0, "remap FAILED") && (i = index($0, f)) { $0 = substr($0, 1, i - 1) "$_mmserr " substr($0, i) }
            { print }' "$BLOCK" > "$2" ;;
      *) return 1 ;;
    esac
    ! cmp -s "$BLOCK" "$2"
  }

  for M in M1 M2 M3 M4; do
    MB=$(mktemp -p "$W") || exit 2
    if ! mutant "$M" "$MB"; then
      echo "FAIL: mutant $M did not apply"; TOTAL=$((TOTAL + 1)); continue
    fi
    for SH in "${SHELLS[@]}"; do
      cases "$SH" "$MB" mutant; f=$?
      if [ "$f" -gt 0 ]; then echo "CONVICTED: $M [$SH] ($f check(s) failed)"
      else echo "FAIL: mutant $M SURVIVED [$SH]"; TOTAL=$((TOTAL + 1)); fi
    done
  done
fi

if [ "$TOTAL" -gt 0 ]; then echo "FAILED: $TOTAL"; exit 1; fi
echo "ALL PASS"
