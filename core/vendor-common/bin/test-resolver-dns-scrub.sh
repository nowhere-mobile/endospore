#!/usr/bin/env bash
# test-resolver-dns-scrub.sh [<nowhere_roamd.sh>] [--mutate] -- log_scrub must take the resolver's LEGACY
# `dns=[...]` address list out of the logs, and must do it without risking the name scrub (NWP-20261011-36).
#
# WHY THIS IS COMMITTED. The agent's change-only `[resolver] egress iface=... dns=[...]` line printed every network's
# own resolver addresses into /data/nowhere/login.log, which is on plain /data, survives the boot-wipe and ships in
# issue reports; its 1 MB tail was a de-duplicated travel history. egressLine now prints resolvers=[...] with those
# addresses as placeholders, but every fielded device still holds the old lines, and only log_scrub takes them out.
# Its dns program is a SEPARATE program from the name rules (whose parity with report_issue.go is fuzz-tested and
# which test-log-name-scrub.sh owns), with its own self-check -- and a broken dns program must never cost the name
# scrub, because an empty sed output skips the whole rewrite through log_scrub's [ -s ] guard.
#
# So: plant legacy lines (a v6 entry in the middle and at the end of the list, and one written before src= existed),
# a line as egressLine writes it today and a named line; run the REAL log_scrub FUNCTION twice; assert every planted
# address is GONE BY VALUE, the second pass changes nothing, the new-form line comes out exactly as the name program
# alone leaves it, and the name is redacted. Then force a broken dns program and assert the names are still scrubbed
# and the failure is logged.
#
#   bash test-resolver-dns-scrub.sh             # the end-to-end scrub
#   bash test-resolver-dns-scrub.sh --mutate    # ... plus mutations that must each CONVICT the suite
#
# Pure logic -- no device, no store. log_scrub and its definitions are EXTRACTED from nowhere_roamd.sh, never copied,
# under bash with a `print` shim (mksh's builtin on the device). The device's sed is toybox; the self-check is what
# holds the program there, and the CLOSES-WHEN device step in docs/backlog.md is what proves it.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

# The planted network resolvers: documentation-range v6 and v4 hosts whose digit runs occur nowhere else in the plants.
PLANT_HOSTS='198.51.100.17 198.51.100.29 2001:db8:4e1::5a 2001:db8:7c2::9b'
LEGACY=('[resolver] egress iface="wlan0" dns=[198.51.100.17:53 [2001:db8:4e1::5a]:53 198.51.100.29:53] src=discovered dot=off'
  '[resolver] egress iface="wlan0" dns=[198.51.100.29:53 [2001:db8:7c2::9b]:53] src=kept (discovery empty, cache still valid) dot=dns.mullvad.net'
  '[resolver] egress iface="wlan0" dns=[198.51.100.17:53 [2001:db8:4e1::5a]:53]')
LEGACY_OUT=('[resolver] egress iface="<name>" dns=[<redacted>] src=discovered dot=off'
  '[resolver] egress iface="<name>" dns=[<redacted>] src=kept (discovery empty, cache still valid) dot=dns.mullvad.net'
  '[resolver] egress iface="<name>" dns=[<redacted>]')
NEWFORM='[resolver] egress iface="wlan0" resolvers=[<net4>:53 <net6>:53 1.1.1.1:53 [2606:4700:4700::1111]:53] src=discovered dot=off'
NAMED='[roamd] OUT zqplant (user 11) +de +media'
# a confinement control: the same text on a line that is NOT the resolver's egress line is not the dns program's
OTHER='[roamd] note dns=[kept] src=kept'

fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
DEFS="NOWHERE_LOGS LOG_KEEP_BYTES LOG_SCRUB_SED LOG_SCRUB_SED_PREV LOG_SCRUB_PROBE LOG_SCRUB_PROBE_OUT LOG_SCRUB_DNS_SED LOG_SCRUB_DNS_PROBE LOG_SCRUB_DNS_PROBE_OUT"
defs_of() {
  local v out="" n
  for v in $DEFS; do
    n=$(grep -c "^$v=" "$1")
    [ "$n" = 1 ] || { echo "EXTRACTION FAILED: $v= is defined $n times in $1, want 1" >&2; return 1; }
    out="$out$(grep "^$v=" "$1")"$'\n'
  done
  printf '%s' "$out"
}

# run_scrub <root> <defs> <log_scrub, re-rooted> <dns program override or empty>: the real function, in a subshell.
run_scrub() {
  ( ROOT="$1"; STATE="$1/state"; LOG="$1/data/nowhere/roam.log"
    eval "$PRINT_SHIM"; eval "$2"
    [ -n "$4" ] && LOG_SCRUB_DNS_SED="$4"
    eval "$3"
    log_scrub ) </dev/null >/dev/null 2>&1
}

# suite <roamd> [quiet] -> 0 all good, 1 a check failed, 2 the harness could not run (never a verdict).
suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 tmp defs scrubfn n out runs leaked h r i got want nameonly
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }

  defs=$(defs_of "$f") || return 2
  scrubfn=$(fn_of "$f" log_scrub)
  [ -n "$scrubfn" ] || { echo "EXTRACTION FAILED: log_scrub not found" >&2; return 2; }
  n=$(grep -c '/data/nowhere/' <<<"$scrubfn")
  [ "$n" = 1 ] || { echo "EXTRACTION FAILED: log_scrub names /data/nowhere/ $n times, want 1" >&2; return 2; }
  scrubfn=${scrubfn//\/data\/nowhere\//\$ROOT\/data\/nowhere\/}
  ( eval "$defs"; for v in $DEFS; do [ -n "${!v+set}" ] || exit 1; done ) >/dev/null 2>&1 \
    || { echo "EXTRACTION FAILED: the extracted definitions of $DEFS do not evaluate (one spans lines?)" >&2; return 2; }
  tmp=$(mktemp -d)

  # The name program alone, as log_scrub runs it: what the new-form line must come out as.
  nameonly=$(eval "$defs"; printf '%s\n' "$NEWFORM" | sed -E "$LOG_SCRUB_SED" 2>/dev/null)
  if [ -n "$nameonly" ] && [ "$nameonly" != "$NEWFORM" ]; then ok "the name program runs (iface= is redacted on the new-form line)"
  else no "the name program does not run on this sed -- every result below is meaningless"; rm -rf "$tmp"; return 1; fi

  # --- the REAL log_scrub over login.log, then again over its own output --------------------------------------
  local R="$tmp/root"; mkdir -p "$R/data/nowhere" "$R/state"
  printf '%s\n' "${LEGACY[@]}" "$NEWFORM" "$NAMED" "$OTHER" > "$R/data/nowhere/login.log"
  run_scrub "$R" "$defs" "$scrubfn" ""
  out=$(cat "$R/data/nowhere/login.log")
  # by VALUE: every digit (and v6 hex) run of every planted host, token for token -- not a count of placeholders
  runs=$(tr ' .:' '\n\n\n' <<<"$PLANT_HOSTS" | grep -v '^$' | sort -u)
  leaked=""
  while IFS= read -r r; do
    grep -qxF -- "$r" <<<"$runs" && leaked="$leaked $r"
  done < <(grep -oE '[0-9A-Fa-f]+' <<<"$out" | sort -u)
  [ -z "$leaked" ] && ok "no run of any planted resolver address survives log_scrub" \
    || { no "these runs of planted resolver addresses survive log_scrub:$leaked"; [ -n "$quiet" ] || sed 's/^/          /' <<<"$out"; }
  for i in "${!LEGACY_OUT[@]}"; do
    want=${LEGACY_OUT[$i]}
    got=$(sed -n "$((i + 1))p" <<<"$out")
    [ "$got" = "$want" ] && ok "legacy line $((i + 1)) is redacted whole and keeps src=/dot=" \
      || no "legacy line $((i + 1)) came out as: $got"
  done
  got=$(sed -n "$((${#LEGACY[@]} + 1))p" <<<"$out")
  [ "$got" = "$nameonly" ] && ok "the new-form line comes out exactly as the name program alone leaves it" \
    || no "the dns program touched the new-form line: $got"
  got=$(sed -n "$((${#LEGACY[@]} + 2))p" <<<"$out")
  case "$got" in
    *zqplant*) no "the name scrub did not run: $got" ;;
    '[roamd] OUT <name> (user 11) +de +media') ok "the name redaction is unchanged" ;;
    *) no "the named line came out as: $got" ;;
  esac
  got=$(sed -n "$((${#LEGACY[@]} + 3))p" <<<"$out")
  [ "$got" = "$(eval "$defs"; printf '%s\n' "$OTHER" | sed -E "$LOG_SCRUB_SED")" ] \
    && ok "the dns program is confined to the resolver's egress line" || no "the dns program reached another line: $got"
  case "$out" in
    *'log_scrub:'*'self-check'*) no "log_scrub says a program FAILED its self-check on this sed" ;;
    *) ok "both self-checks passed on this sed" ;;
  esac
  cp "$R/data/nowhere/login.log" "$tmp/first.log"
  run_scrub "$R" "$defs" "$scrubfn" ""
  if cmp -s "$tmp/first.log" "$R/data/nowhere/login.log"; then ok "a second scrub changes nothing (a fixed point)"
  else no "a second scrub changes the log:"; [ -n "$quiet" ] || diff "$tmp/first.log" "$R/data/nowhere/login.log" | head -6 | sed 's/^/          /'; fi

  # --- a dns program this sed cannot compile must not cost the name scrub ------------------------------------
  local R2="$tmp/root2"; mkdir -p "$R2/data/nowhere" "$R2/state"
  printf '%s\n' "${LEGACY[0]}" "$NAMED" > "$R2/data/nowhere/login.log"
  run_scrub "$R2" "$defs" "$scrubfn" 's/(/x/'
  out=$(cat "$R2/data/nowhere/login.log"); got=$(cat "$R2/data/nowhere/roam.log" 2>/dev/null)
  case "$out" in
    *zqplant*) no "with a broken dns program the NAME scrub did not run -- the broken program emptied the output" ;;
    *'[roamd] OUT <name> (user 11) +de +media'*) ok "with a broken dns program the name scrub still runs" ;;
    # NWP-20261120-17: a log log_scrub cannot scrub is now emptied, not kept, so the plant's absence alone no longer
    # shows the name scrub ran: the named line must come out scrubbed AND kept.
    *) no "with a broken dns program the log was emptied, not scrubbed -- the broken program emptied the sed output" ;;
  esac
  case "$got" in
    *'log_scrub: the resolver-address program FAILED its self-check'*) ok "a broken dns program fails its self-check and says so" ;;
    *) no "a broken dns program was left out silently -- it must say so in roam.log" ;;
  esac

  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  rm -rf "$tmp"
  [ "$x" -eq 0 ]
}

echo "resolver dns scrub: $SUT"
suite "$SUT"; rc=$?
[ "$rc" = 0 ] || { [ "$rc" = 2 ] && echo "HARNESS ERROR (rc=2): not a verdict"; FAILED=1; }

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT):"
  mtmp=$(mktemp -d); MN=0; MOK=0
  # mutate <label> <literal needle> <replacement>. Literal, not a regex; the needle must occur exactly once, or the
  # mutant is a NO-OP and says so -- never a pass.
  mutate() {
    local label="$1" needle="$2" repl="$3" src m rc
    MN=$((MN + 1))
    src=$(cat "$SUT")
    m=${src/"$needle"/}
    if [ "$m" = "$src" ]; then printf '  SKIP  %-60s needle not found -- a NO-OP\n' "$label"; return; fi
    if [ "${m/"$needle"/}" != "$m" ]; then printf '  SKIP  %-60s needle occurs more than once\n' "$label"; return; fi
    printf '%s\n' "${src/"$needle"/"$repl"}" > "$mtmp/roamd.sh"
    suite "$mtmp/roamd.sh" quiet >/dev/null 2>&1; rc=$?
    case "$rc" in
      1) printf '  ok    %-60s convicted\n' "$label"; MOK=$((MOK + 1)) ;;
      0) printf '  XX    %-60s SURVIVED\n' "$label" ;;
      *) printf '  ERR   %-60s harness error (rc=%s), no verdict\n' "$label" "$rc" ;;
    esac
  }
  mutate 'the dns program is dropped from the sed run' '      _p="$_p
$_d"' '      :'
  mutate 'the dns program fails to compile' 'dns=\[.*\]( src=|$)/ dns=[<redacted>]\1/' 'dns=\[.*\]( src=|$/ dns=[<redacted>]\1/'
  mutate 'the list stops at the first ] again ([^]]*)' "egress /s/ dns=\\[.*\\]( src=|\$)/" "egress /s/ dns=\\[[^]]*\\]( src=|\$)/"
  mutate '... and the probe loses its v6 entry, so the check passes' \
    "dns=\\[.*\\]( src=|\$)/ dns=[<redacted>]\\1/'"$'\n'"LOG_SCRUB_DNS_PROBE='[resolver] egress iface=\"<name>\" dns=[192.0.2.1:53 [2001:db8::1]:53 192.0.2.2:53]" \
    "dns=\\[[^]]*\\]( src=|\$)/ dns=[<redacted>]\\1/'"$'\n'"LOG_SCRUB_DNS_PROBE='[resolver] egress iface=\"<name>\" dns=[192.0.2.1:53 192.0.2.2:53]"
  mutate 'the list stops at src= only (no pre-src= lines)' 'dns=\[.*\]( src=|$)/' 'dns=\[.*\]( src=)/'
  mutate 'the dns program runs on every line, not the egress line' "LOG_SCRUB_DNS_SED='/^\\[resolver\\] egress /s/" "LOG_SCRUB_DNS_SED='s/"
  mutate 'the self-check is removed' '    if [ -n "$_d" ] && [ "$(print -r -- "$LOG_SCRUB_DNS_PROBE" | sed -E "$_d" 2>/dev/null)" = "$LOG_SCRUB_DNS_PROBE_OUT" ]; then' \
    '    if :; then'
  mutate 'a failed self-check is silent' '      print -r -- "[roamd] log_scrub: the resolver-address program FAILED its self-check -- scrubbing names only $(date)" >> "$LOG"' \
    '      :'
  mutate 'the dns program is piped as a second sed after the name scrub' \
    'sed -E "$_p" "$_f" 2>/dev/null >' 'sed -E "$_p" "$_f" 2>/dev/null | sed -E "$LOG_SCRUB_DNS_SED" 2>/dev/null >'
  rm -rf "$mtmp"
  echo
  if [ "$MOK" = "$MN" ]; then echo "ALL $MN MUTATIONS BEHAVED"
  else echo "PROBLEM: a mutation did not behave ($MOK of $MN convicted)"; FAILED=1; fi
fi

exit "${FAILED:-0}"
