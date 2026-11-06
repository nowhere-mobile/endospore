#!/usr/bin/env bash
# test-acct-authenticator-wait.sh [<nowhere_roamd.sh>] [--mutate] -- odrestore's wait for the com.google account
# authenticator ends only on the WHOLE type, never on a longer type that contains it (NWP-20261121-03).
#
# WHY THIS IS COMMITTED. When grant deferred the #sys account reload because GMS was on-demand, odrestore runs
# wait_acct_authenticator and then acct_reload. A reload before GMS's com.google authenticator is registered makes
# AccountManagerService's validateAccountsInternal PURGE the account. The wait used to match `grep -qa com.google`,
# a regex substring: Gmail registers com.google.android.gm.exchange, .legacyimap and .pop3, so with Gmail installed
# the first poll matched and the reload could run before GMS registered. acct_type_registered now matches the type
# as a whole attribute value: type="<type>" in text XML, or the 2-byte big-endian length then the bytes in ABX.
#
# The ABX fixtures follow the AOSP source layout (BinaryXmlSerializer, as RegisteredServicesCache writes
# <services><service uid=.. type=../></services>). They were NOT taken from a device.
#
# acct_type_registered and wait_acct_authenticator are extracted BY NAME and run under EACH of bash, sh, dash and
# mksh found on PATH (deduped by realpath), labelled [<shell>], as a script that shell runs. `sleep` is stubbed to
# record its calls, so the 30-poll miss takes no time. ACCT_USERS_ROOT and LOG point inside the suite's root.
#
#   bash test-acct-authenticator-wait.sh            # the cases
#   bash test-acct-authenticator-wait.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# Shells: bash, plus sh/dash/mksh where they are a different interpreter (deduped by realpath).
SHELLS=""; SEEN=" "
for cand in bash sh dash mksh; do
  p=$(command -v "$cand" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$SEEN" in *" $r "*) continue ;; esac
  SEEN="$SEEN$r "; SHELLS="$SHELLS $p"
done
[ -n "$SHELLS" ] || { echo "no POSIX shell found" >&2; exit 2; }

fn() { sed -n "/^$2() {\$/,/^}\$/p" "$1"; }

# ---- fixtures (written straight to files by this bash, never through $( ), so the NUL bytes survive) ----
abx_str() {  # writeUTF: 2-byte big-endian length, then the bytes
  local n=${#1}
  printf "\\$(printf %03o $((n / 256)))\\$(printf %03o $((n % 256)))%s" "$1"
}
abx_file() {  # abx_file <out> <type>... -> one <service uid=10123 type=<type>/> per type
  local out="$1" first=1 t; shift
  { printf 'ABX\000\020\062\377\377'; abx_str services             # magic, START_DOCUMENT, START_TAG services (new interned)
    for t in "$@"; do
      if [ "$first" = 1 ]; then
        printf '\062\377\377'; abx_str service                     # START_TAG service (new interned, index 1)
        printf '\157\377\377'; abx_str uid; printf '\000\000\047\213'   # int attribute uid (index 2) = 10123
        printf '\057\377\377'; abx_str type; first=0               # string attribute type (index 3)
      else
        printf '\062\000\001\157\000\002\000\000\047\213\057\000\003'   # the same names, by interned index
      fi
      abx_str "$t"; printf '\063\000\001'                          # the value, END_TAG service
    done
    printf '\063\000\000\021'; } > "$out"                          # END_TAG services, END_DOCUMENT
}
FX="$W/fx"; mkdir -p "$FX"
GM1=com.google.android.gm.exchange GM2=com.google.android.gm.legacyimap GM3=com.google.android.gm.pop3
LONG="com.google$(printf 'a%.0s' $(seq 290))"   # 300 bytes: the length needs the high byte (01 2c)
abx_file "$FX/gmail" "$GM1" "$GM2" "$GM3"
abx_file "$FX/both" "$GM1" "$GM2" "com.google" "$GM3"
abx_file "$FX/wild" comXgoogle
abx_file "$FX/long" com.example.filler "$LONG"
printf '<?xml version="1.0" encoding="utf-8" standalone="yes" ?>\n<services>\n<service uid="10123" type="com.google" />\n</services>\n' > "$FX/text"
printf '<?xml version="1.0" encoding="utf-8" standalone="yes" ?>\n<services>\n<service uid="10123" type="%s" />\n</services>\n' "$GM1" > "$FX/textgm"
: > "$FX/empty"
[ "${#LONG}" = 300 ] && [ "$(od -An -tx1 -j0 -N4 "$FX/gmail" | tr -d ' \n')" = 41425800 ] || { echo "fixture setup failed" >&2; exit 2; }

suite() {  # suite <roamd.sh> <quiet> <shell> -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" sh="$3" label p=0 x=0 code cf T out err n
  label=$(basename "$sh")
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$label" "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$label" "$1"; }
  code="$(fn "$f" acct_type_registered)
$(fn "$f" wait_acct_authenticator)"
  case "$code" in *'acct_type_registered() {'*'wait_acct_authenticator() {'*) ;; *) echo "EXTRACTION FAILED -- acct_type_registered / wait_acct_authenticator moved in $f" >&2; return 2 ;; esac
  cf=$(mktemp -p "$W"); printf '%s\n' "$code" > "$cf"
  "$sh" -n "$cf" || { echo "EXTRACTION FAILED -- the functions do not parse under $label" >&2; command rm -f "$cf"; return 2; }
  command rm -f "$cf"

  # reg <fixture> <type> -> stdout "rc=N"; stderr into $T/err
  reg() {
    T=$(mktemp -d -p "$W")
    { printf "LOG='%s/roam.log'\n" "$T"; printf '%s\n' "$code"; printf 'acct_type_registered "$1" "$2"; echo "rc=$?"\n'; } > "$T/run.sh"
    out=$("$sh" "$T/run.sh" "$1" "$2" 2> "$T/err"); err=$(cat "$T/err")
  }
  # wait_on <fixture or ""> -> out "rc=N", n = sleep calls, $T/roam.log the log; the file goes in for user 11
  wait_on() {
    T=$(mktemp -d -p "$W"); mkdir -p "$T/users/11/registered_services"
    [ -z "$1" ] || cp "$1" "$T/users/11/registered_services/android.accounts.AccountAuthenticator.xml"
    { printf "LOG='%s/roam.log' ACCT_USERS_ROOT='%s/users' T='%s'\n" "$T" "$T" "$T"
      printf 'sleep() { echo "sleep $*" >> "$T/sleeps"; }\n'; printf '%s\n' "$code"
      printf 'wait_acct_authenticator 11; echo "rc=$?"\n'; } > "$T/run.sh"
    out=$("$sh" "$T/run.sh" 2> "$T/err"); err=$(cat "$T/err")
    n=0; [ ! -f "$T/sleeps" ] || n=$(grep -c '^sleep 1$' "$T/sleeps")
  }
  logged() { grep -qF "$1" "$T/roam.log" 2>/dev/null; }

  # (a) Gmail's three types only: com.google is NOT registered
  reg "$FX/gmail" com.google
  [ "$out" = rc=1 ] && ok "A1 ABX with only Gmail's com.google.android.gm.* types: com.google is not registered" || no "A1 Gmail's types matched com.google ($out)"
  command rm -rf "$T"
  wait_on "$FX/gmail"
  if [ "$out" = rc=1 ] && [ "$n" = 30 ] && logged "[roamd] WARN acct authenticator com.google NOT seen for user 11 after 30s -- reloading anyway"; then
    ok "A2 the wait polls 30 times, logs NOT seen and returns 1"; else no "A2 the wait ended on Gmail's types ($out, $n sleeps)"; fi
  command rm -rf "$T"

  # (b) Gmail's three types AND com.google
  reg "$FX/both" com.google
  [ "$out" = rc=0 ] && ok "B1 ABX with com.google among Gmail's types: registered" || no "B1 com.google not found ($out)"
  command rm -rf "$T"
  wait_on "$FX/both"
  if [ "$out" = rc=0 ] && [ "$n" = 0 ] && logged "[roamd] acct authenticator com.google registered for user 11 (waited 0s)"; then
    ok "B2 the wait returns 0 with no sleep and logs waited 0s"; else no "B2 the wait missed a registered com.google ($out, $n sleeps)"; fi
  command rm -rf "$T"

  # (c) text XML
  reg "$FX/text" com.google
  [ "$out" = rc=0 ] && ok "C1 text XML type=\"com.google\": registered" || no "C1 text XML com.google not found ($out)"
  command rm -rf "$T"
  wait_on "$FX/text"
  [ "$out" = rc=0 ] && [ "$n" = 0 ] && ok "C2 the wait returns 0 at once on text XML" || no "C2 the wait missed text XML com.google ($out, $n sleeps)"
  command rm -rf "$T"
  reg "$FX/textgm" com.google
  [ "$out" = rc=1 ] && ok "C3 text XML with only type=\"$GM1\": not registered" || no "C3 Gmail's text type matched com.google ($out)"
  command rm -rf "$T"
  wait_on "$FX/textgm"
  [ "$out" = rc=1 ] && [ "$n" = 30 ] && ok "C4 the wait runs out on Gmail's text type" || no "C4 the wait ended on Gmail's text type ($out, $n sleeps)"
  command rm -rf "$T"

  # (d) the regex wildcard
  reg "$FX/wild" com.google
  [ "$out" = rc=1 ] && ok "D1 ABX comXgoogle: a dot is not a wildcard" || no "D1 comXgoogle matched com.google ($out)"
  command rm -rf "$T"
  wait_on "$FX/wild"
  [ "$out" = rc=1 ] && [ "$n" = 30 ] && ok "D2 the wait runs out on comXgoogle" || no "D2 the wait ended on comXgoogle ($out, $n sleeps)"
  command rm -rf "$T"

  # (e) missing, empty, empty type
  reg "$W/no-such-file" com.google
  [ "$out" = rc=1 ] && [ -z "$err" ] && ok "E1 a missing file: false, no error output" || no "E1 missing file ($out, stderr '$err')"
  command rm -rf "$T"
  reg "$FX/empty" com.google
  [ "$out" = rc=1 ] && [ -z "$err" ] && ok "E2 an empty file: false, no error output" || no "E2 empty file ($out, stderr '$err')"
  command rm -rf "$T"
  reg "$FX/both" ""
  [ "$out" = rc=1 ] && [ -z "$err" ] && ok "E3 an empty type: false" || no "E3 empty type ($out, stderr '$err')"
  command rm -rf "$T"
  wait_on ""
  if [ "$out" = rc=1 ] && [ "$n" = 30 ] && [ -z "$err" ] && logged "NOT seen for user 11 after 30s"; then
    ok "E4 no file: the wait runs out quietly"; else no "E4 no file ($out, $n sleeps, stderr '$err')"; fi
  command rm -rf "$T"

  # (f) a 300-byte type: the length prefix is 2 bytes, big-endian (01 2c)
  reg "$FX/long" "$LONG"
  [ "$out" = rc=0 ] && ok "F1 a 300-byte type is found in ABX (prefix 01 2c)" || no "F1 the 300-byte type was not found in ABX ($out)"
  command rm -rf "$T"

  # the root override keeps the device default
  grep -qxF 'ACCT_USERS_ROOT="${ACCT_USERS_ROOT:-/data/system/users}"           # overridable for test-acct-authenticator-wait.sh only, as DE_SYS_ROOT is' "$f" \
    && ok "R1 ACCT_USERS_ROOT defaults to /data/system/users" || no "R1 the ACCT_USERS_ROOT default changed"

  [ -n "$quiet" ] || printf '  -- %d ok, %d failed [%s]\n' "$p" "$x" "$label"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "== $SUT (shells:$SHELLS)"
rc=0
for sh in $SHELLS; do suite "$SUT" "" "$sh"; r=$?; [ "$r" = 0 ] || rc=$((r > rc ? r : rc)); done
[ "$rc" = 0 ] || { echo "FAILED"; exit "$rc"; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED)"
mut() { # mut <label> <sed-expr>; convicted under EACH shell's own line
  local m r sh bad=0
  m=$(mktemp -p "$W")
  sed -e "$2" "$SUT" > "$m" || { echo "  ERROR     $1 -- the sed program failed"; command rm -f "$m"; return 1; }
  [ -s "$m" ] || { echo "  ERROR     $1 -- the mutant is empty"; command rm -f "$m"; return 1; }
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; command rm -f "$m"; return 1; fi
  for sh in $SHELLS; do
    suite "$m" quiet "$sh" >/dev/null 2>&1; r=$?
    case "$r" in
      1) echo "  convicted $1 [${sh##*/}]" ;;
      0) echo "  SURVIVED  $1 [${sh##*/}]"; bad=1 ;;
      *) echo "  BROKEN    $1 [${sh##*/}] (rc=$r), not a conviction"; bad=1 ;;
    esac
  done
  command rm -f "$m"; return $bad
}
M1='/^acct_type_registered() {$/,/^}$/c\
acct_type_registered() {\
  local f="$1" type="$2"\
  grep -qa "$type" "$f" 2>/dev/null\
}'
fails=0
mut "m1 the old grep -qa substring as the whole helper" "$M1" || fails=$((fails+1))
mut "m2 the ABX length prefix dropped"                   "/^  want=\"\$(printf '%02x %02x' \$((len \/ 256)) \$((len % 256))) \$want\"\$/d" || fails=$((fails+1))
mut "m3 the text arm removed"                            '/^  grep -qF "type=\\"$type\\"" "$f" 2>\/dev\/null && return 0$/d' || fails=$((fails+1))
mut "m4 the length bytes swapped"                        's/\$((len \/ 256)) \$((len % 256))/$((len % 256)) $((len \/ 256))/' || fails=$((fails+1))
mut "m5 the wait calls the old grep"                     's/^    if acct_type_registered "$f" "$type"; then$/    if [ -f "$f" ] \&\& grep -qa "$type" "$f" 2>\/dev\/null; then/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
