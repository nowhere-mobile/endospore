#!/usr/bin/env bash
# test-calllog-late.sh [<nowhere_roamd.sh>] [--mutate] -- the sign-out's `calllog after #de` line (NWP-20261206-22).
#
# WHY THIS IS COMMITTED. The backlog row "An owner's own call that ends during the logoff seal is destroyed with the
# user" has no evidence of how often it happens. A logoff seal that lands now writes one roam.log line: `late=<n>`
# (calls that ended after the #de push read the call log, so in no seal) or `unread <class>`. This pins that line:
# only a logoff seal writes it, a missing or 0 stamp is never a count, the live db is never handed to the tool (a
# copy in $STATE is), a tool that fails or prints a non-integer is `unread query` and never `late=0`, the stage never
# outlives the check, and the out op stamps #de and calls the helper only on the branch that reaches the reap.
#
#   bash test-calllog-late.sh            # the cases, under every shell present, and the source pins
#   bash test-calllog-late.sh --mutate   # ... plus mutations that must each CONVICT the suite, under each shell
#
# Pure shell -- no device, no db. calllog_late runs WHOLE (lifted by name) with /data/ and the tool path pointed at a
# temp root; nowhere_db_fix is a stub that records its argv and what the stage held. Exit 2 when the extraction fails
# or no shell ran; --mutate counts a mutant as convicted only when the suite exits 1 on it.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
[ ! -e /system/bin/nowhere_db_fix ] || { echo "refusing to run: /system/bin/nowhere_db_fix exists on this host" >&2; exit 2; }
[ ! -e /data/user_de ] || { echo "refusing to run: /data/user_de exists on this host" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# --- extraction: the helper, whole, by name ------------------------------------------------------------------
FN=$(awk 'index($0, "calllog_late() {") == 1 {f=1} f{print} f&&/^\}$/{exit}' "$SUT")
case "$FN" in
  'calllog_late() {'*'calllog-ended-after'*'calllog after #de:'*'}') ;;
  *) echo "EXTRACTION FAILED: calllog_late -- not found by name, or its anchors moved, in $SUT" >&2; exit 2 ;;
esac
FN=$(printf '%s\n' "$FN" | sed 's#/system/bin/nowhere_db_fix#$T/bin/nowhere_db_fix#g; s#/data/#$T/data/#g')
[ -z "$(printf '%s\n' "$FN" | grep -v '^[[:space:]]*#' | grep -E '(^|[^T])/data/')" ] || { echo "EXTRACTION FAILED: a /data/ path escaped the rewrite" >&2; exit 2; }

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "${SUITE_SHELLS:-}" ] && SHELLS="$SUITE_SHELLS"
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
echo "shells:$SHELLS"

RE='^\[roamd\] calllog after #de: (late=[0-9]+|unread (no-stamp|no-db|no-tool|copy|query)) \(user [0-9]+\) '

# run <shell> <skind> <stamp> <db: db|dbwal|none> <tool: exec|noexec|none> <stub stdout> <stub exit> -> sets T.
# The stub appends its argv to $T/argv, lists the stage into $T/stage, prints <stub stdout> and a usage line on
# stderr, and exits <stub exit>. Every case then gets L9 (the line's shape) and L10 (no stage left).
run(){
  local sh="$1" sk="$2" st="$3" db="$4" tool="$5" out="$6" ex="$7" d
  T=$(mktemp -d -p "$W") || exit 2
  d="$T/data/user_de/10/com.android.providers.contacts/databases"
  mkdir -p "$T/state" "$T/bin" "$d"
  case "$db" in
    db) printf 'DB' > "$d/calllog.db" ;;
    dbwal) printf 'DB' > "$d/calllog.db"; printf 'WAL' > "$d/calllog.db-wal" ;;
  esac
  if [ "$tool" != none ]; then
    cat > "$T/bin/nowhere_db_fix" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$T/argv"
ls "$T/state/calllog-late" > "$T/stage" 2>&1
printf '%s\n' '$out'
echo 'usage: nowhere_db_fix <cmd> ...' >&2
exit $ex
STUB
    [ "$tool" = exec ] && chmod 0755 "$T/bin/nowhere_db_fix"
    [ "$tool" = noexec ] && chmod 0644 "$T/bin/nowhere_db_fix"
  fi
  {
    printf "T='%s'; STATE=\$T/state; LOG=\$T/log; skind='%s'\n" "$T" "$sk"
    printf '%s\n' "$FN"
    printf "calllog_late 10 '%s'\n" "$st"
  } > "$T/run.sh"
  : > "$T/log"
  "$sh" "$T/run.sh" > "$T/out" 2>&1
  LINES=$(grep -F 'calllog after #de:' "$T/log")
  local bad=""
  if [ -n "$LINES" ]; then bad=$(printf '%s\n' "$LINES" | grep -vE "$RE"); fi
  [ -z "$bad" ] && ok "L9 [$sh] every line has the closed shape" || no "L9 [$sh] a line outside the closed vocabulary: [$bad]"
  [ ! -e "$T/state/calllog-late" ] && ok "L10 [$sh] no stage left" || no "L10 [$sh] the stage $T/state/calllog-late outlived the check"
}
# one_line <label> <want text> : exactly one line, and it holds <want text> followed by " (user 10) ".
one_line(){
  local n
  n=$(printf '%s' "$LINES" | grep -c .)
  case "$LINES" in
    *"calllog after #de: $2 (user 10) "*) [ "$n" = 1 ] && ok "$1 one line: $2" || no "$1 want one line [$2], got $n: [$LINES]" ;;
    *) no "$1 want [$2], got [$LINES]" ;;
  esac
}
no_stub(){ [ ! -e "$T/argv" ] && ok "$1 the tool never ran" || no "$1 the tool ran: [$(cat "$T/argv")]"; }

for s in $SHELLS; do
  echo "== $s =="
  for k in logoff logoff-pinned; do
    L=L1; [ "$k" = logoff-pinned ] && L=L2
    run "$s" "$k" 123456 dbwal exec 2 0
    one_line "$L [$s] $k" "late=2"
    a=$(cat "$T/argv" 2>/dev/null)
    [ "$a" = "calllog-ended-after $T/state/calllog-late/calllog.db 123456" ] && ok "$L [$s] argv names the staged copy and the stamp" || no "$L [$s] argv [$a]"
    g=$(tr '\n' ' ' < "$T/stage" 2>/dev/null)
    [ "$g" = "calllog.db calllog.db-wal " ] && ok "$L [$s] the stage held the db and its -wal" || no "$L [$s] the stage held [$g]"
  done
  for k in "" manual periodic; do
    run "$s" "$k" 123456 dbwal exec 2 0
    [ -z "$LINES" ] && ok "L3 [$s] skind [$k]: no line" || no "L3 [$s] skind [$k] wrote [$LINES]"
    no_stub "L3 [$s] skind [$k]:"
  done
  run "$s" logoff 123456 none exec 2 0
  one_line "L4 [$s] no db:" "unread no-db"; no_stub "L4 [$s]"
  run "$s" logoff 123456 dbwal exec -1 6
  one_line "L5 [$s] tool exit 6 printing -1:" "unread query"
  run "$s" logoff 123456 dbwal exec 2x 0
  one_line "L5 [$s] tool printing 2x:" "unread query"
  for st in "" 0 12a; do
    run "$s" logoff "$st" dbwal exec 2 0
    one_line "L6 [$s] stamp [$st]:" "unread no-stamp"; no_stub "L6 [$s] stamp [$st]:"
  done
  run "$s" logoff 123456 dbwal noexec 2 0
  one_line "L7 [$s] tool not executable:" "unread no-tool"
  run "$s" logoff 123456 dbwal none 2 0
  one_line "L7 [$s] no tool:" "unread no-tool"
  run "$s" logoff 123456 db exec 2 0
  one_line "L8 [$s] db without -wal:" "late=2"
  [ -e "$T/argv" ] && ok "L8 [$s] the tool ran" || no "L8 [$s] the tool never ran"
  g=$(tr '\n' ' ' < "$T/stage" 2>/dev/null)
  [ "$g" = "calllog.db " ] && ok "L8 [$s] the stage held only the db" || no "L8 [$s] the stage held [$g]"
  run "$s" logoff 123456 dbwal exec 0 2
  one_line "L11 [$s] tool without the subcommand (usage, exit 2, prints 0):" "unread query"
  if [ "$(id -u)" != 0 ]; then
    run "$s" logoff 123456 dbwal exec 2 0   # set up, then re-run with a read-only $STATE
    : > "$T/log"; rm -f "$T/argv"; chmod 0555 "$T/state"
    "$s" "$T/run.sh" > "$T/out" 2>&1
    chmod 0755 "$T/state"
    LINES=$(grep -F 'calllog after #de:' "$T/log")
    one_line "L12 [$s] the stage cannot be made:" "unread copy"; no_stub "L12 [$s]"
  else
    echo "  skip  L12 [$s]: running as root, which ignores a read-only \$STATE"
  fi
done

# --- source pins (comments stripped) -----------------------------------------------------------------------
echo "== source pins =="
PUSHDE='    [ -d "/data/user_de/$uid" ] && _push de    "${name}#de"    "/data/user_de/$uid"'
STAMP='    _de_end=""; [ -d "/data/user_de/$uid" ] && [ "$stopped" = 0 ] && _de_end=$(_ms)'
CALL='      calllog_late "$uid" "$_de_end"'
CODE=$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]*#[[:space:]]NWP-[0-9-]*:.*$//' "$SUT")
nxt=$(printf '%s\n' "$CODE" | awk -v p="$PUSHDE" 'f{print; exit} $0 == p {f=1}')
[ "$nxt" = "$STAMP" ] && ok "P1 the _de_end stamp directly follows the #de push and holds the stopped guard" || no "P1 the line after the #de push is [$nxt]"
inb=$(printf '%s\n' "$CODE" | awk -v c="$CALL" '
  $0 == "  out)" {arm=1}
  arm && $0 == "    elif [ \"$rc\" = 0 ]; then" {b=1; next}
  b && $0 == "      if [ -n \"$parts\" ]; then" {exit}
  b && $0 == c {n++}
  END {print n+0}')
all=$(printf '%s\n' "$CODE" | grep -cxF -- "$CALL")
[ "$inb" = 1 ] && [ "$all" = 1 ] && ok "P2 calllog_late is called once, in the rc=0 branch before the OK verdict" || no "P2 the call is in the rc=0 branch $inb time(s), in the file $all time(s)"

echo "== $PASS passed, $FAIL failed =="
[ "$PASS" -gt 0 ] || { echo "nothing ran" >&2; exit 2; }
[ "$FAIL" = 0 ] || exit 1

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted, under EACH shell) =="
  PASS=0; FAIL=0
  M=$(mktemp -d -p "$W") || exit 2
  mutate(){
    local desc="$1" expr="$2" s rc
    if ! sed "$expr" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $desc"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $desc"; return; fi
    for s in $SHELLS; do
      SUITE_SHELLS="$s" bash "$0" "$M/m.sh" >/dev/null 2>&1; rc=$?
      case $rc in
        1) ok "CONVICTED [$s]: $desc" ;;
        0) no "SURVIVED [$s]: $desc -- suite passes on broken code" ;;
        *) no "NOT CONVICTED [$s] (rc $rc, extraction?): $desc" ;;
      esac
    done
  }
  mutate "M1 the skind gate is removed (L3)" \
         '/^calllog_late() {/,/^}$/{/^  case "\${skind:-}" in logoff|logoff-pinned) ;; \*) return 0 ;; esac$/d}'
  mutate "M2 the digit check on the tool output is removed (L5)" \
         '/^calllog_late() {/,/^}$/s/then case "\$_n" in .*; esac; fi$/then _v="late=$_n"; fi/'
  mutate "M3 the stage is not removed (L10)" \
         '/^calllog_late() {/,/^}$/{/rm -rf "\$_st"   # the stage never outlives the check$/d}'
  mutate "M4 the -wal is not copied (L1)" \
         '/^calllog_late() {/,/^}$/s/ \&\& { \[ ! -e "\$_db-wal" \] || cp "\$_db-wal" "\$_st\/" 2>>"\$LOG"; }; then$/; then/'
  mutate "M5 the stamp check is removed (L6)" \
         "/^calllog_late() {/,/^}\$/s/^    ''|0|\*\[!0-9\]\*) _v=\"unread no-stamp\" ;;\$/    _never_) _v=\"unread no-stamp\" ;;/"
  mutate "M6 a 0 stamp is accepted (L6, stamp 0)" \
         "/^calllog_late() {/,/^}\$/s/^    ''|0|\*\[!0-9\]\*) _v=/    ''|*[!0-9]*) _v=/"
  mutate "M7 the call moves into the failure branch (P2)" \
         '/^      calllog_late "\$uid" "\$_de_end"$/d; /^      # Name the cause. ERR-NOCREDIT/i\      calllog_late "$uid" "$_de_end"'
  mutate "M8 the stopped guard is dropped from the stamp line (P1)" \
         's/ \&\& \[ "\$stopped" = 0 \] \&\& _de_end=\$(_ms)/ \&\& _de_end=$(_ms)/'
  mutate "M9 the tool's exit status is not tested (L11: a usage exit prints late=0)" \
         '/^calllog_late() {/,/^}$/s/if \[ "\$_rc" = 0 \]; then case/if true; then case/'
  echo "== mutations: $PASS convicted, $FAIL not =="
  [ "$FAIL" = 0 ] || exit 1
fi
exit 0
