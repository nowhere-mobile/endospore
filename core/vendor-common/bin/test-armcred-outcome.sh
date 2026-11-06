#!/usr/bin/env bash
# test-armcred-outcome.sh [<nowhere_roamd.sh>] [--mutate] [--shell <sh>] -- roamd's `armcred` op (NWP-20261014-25,
# verdict NWP-20261031-05), run for real under every shell the runner has (bash, sh, dash, mksh).
#
# armcred ran both `cmd lock_settings` rungs `>/dev/null 2>/dev/null || true` and answered OK whether or not the
# credential was set, so ARM-PIN could answer PINSET for a session whose keyguard credential was wrong or absent. The op must:
#   - log WHICH rung set the credential (or that neither did, or that no credential was given) and the verdict;
#   - pick set-pin for an all-numeric credential and set-password for any non-digit;
#   - say ARMED when a rung set it, or when neither did but `lock_settings verify --old <pass>` accepts it (it already
#     IS this credential); say NOTARMED otherwise, and for no credential at all;
#   - write that verdict (`armed` | `notarmed`) into the done-marker and reply `OK ARMED` | `OK NOTARMED`;
#   - reject a non-numeric uid, a leading zero and a uid under 10 (user 0 is the gate) with ERR-UID, no cmd call and no
#     marker (NWP-20261116-17);
#   - NEVER print the passphrase (or the old one) to the log.
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR (`if [ "$op" = "armcred" ]; then` to its column-0 `fi`;
# the block also holds an indented fi), never copied; if the anchors move, extraction fails loudly.
#
#   bash test-armcred-outcome.sh            # the behaviour cases, under every shell found
#   bash test-armcred-outcome.sh --mutate   # ... plus mutations that must each CONVICT the suite under each shell
# `sh test-armcred-outcome.sh` re-execs under bash for the harness; the op block itself runs under each shell.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail

MUTATE=no; SUT=""; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in --mutate) MUTATE=yes ;; --shell) shift; ONLY="${1:-}" ;; *) SUT="$1" ;; esac
  shift
done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

if [ -n "$ONLY" ]; then SHELLS="$ONLY"; else
  SHELLS=""; for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
fi

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

BLOCK=$(awk '
  $0 == "if [ \"$op\" = \"armcred\" ]; then" { on = 1 }
  on { print }
  on && $0 == "fi" { exit }' "$SUT")
case "$BLOCK" in *'ERR-UID'*'lock_settings'*'.armcred.'*) ;; *) echo "EXTRACTION FAILED: the armcred op" >&2; exit 2 ;; esac

# run <shell> <rung1-rc> <rung2-rc> <verify-rc> <pass> <uid> -> sets T (temp dir with log/res/argv/state)
run(){
  local shx="$1"
  T=$(mktemp -d -p "$W"); mkdir -p "$T/state"
  {
    printf 'CALLS=%s; R1=%s; R2=%s; R3=%s\n' "'$T/argv'" "$2" "$3" "$4"
    printf 'STATE=%s; LOG=%s; RES=%s; op=armcred; uid=%s; pass=%s; sesec=OLDSECRET9x\n' \
      "'$T/state'" "'$T/log'" "'$T/res'" "'$6'" "'$5'"
    printf ': > "$LOG"; : > "$CALLS"\n'
    printf '%s\n' 'cmd(){ printf "%s\n" "$*" >> "$CALLS"
           case " $* " in *" verify "*) return "$R3" ;; *" --old "*) return "$R2" ;; *) return "$R1" ;; esac; }'
    printf '%s\n' "$BLOCK"
  } > "$T/driver"
  "$shx" "$T/driver" >/dev/null 2>&1
}
logline(){ grep "armcred user" "$T/log" | head -1; }
leak(){ grep -q -e "$1" -e OLDSECRET9x "$T/log"; }   # file, not a pipe: pipefail-safe
calls(){ wc -l < "$T/argv" | tr -d ' '; }
verified(){ grep -q ' verify ' "$T/argv"; }
check(){  # check <label> <want-log-substring> <armed|notarmed> <pass>
  local l v want m
  l=$(logline)
  case "$l" in *"$2"*) ok "$1: logs '$2'" ;; *) no "$1: logged '$l', want '$2'" ;; esac
  case "$l" in *"-> $3 "*) ok "$1: logs the verdict $3" ;; *) no "$1: log '$l' lacks '-> $3'" ;; esac
  if leak "$4"; then no "$1: the passphrase reached the log"; else ok "$1: no passphrase in the log"; fi
  m=$(cat "$T/state/.armcred.17" 2>/dev/null)
  [ "$m" = "$3" ] && ok "$1: marker says $3" || no "$1: marker '$m', want '$3'"
  if [ -f "$T/state/.armcred.17" ] && [ "$(wc -l < "$T/state/.armcred.17" | tr -d ' ')" = 1 ]; then ok "$1: marker is one line"; else no "$1: marker not one line"; fi
  if [ "$3" = armed ]; then want="OK ARMED"; else want="OK NOTARMED"; fi
  v=$(cat "$T/res" 2>/dev/null)
  [ "$v" = "$want" ] && ok "$1: replies $want" || no "$1: reply '$v', want '$want'"
}

cases(){  # cases <shell>
  local sh="$1"
  echo "== [$sh] rung 1 sets a fresh credential =="
  run "$sh" 0 1 1 'hunter22x' 17; check "rung1" "set (no prior credential)" armed hunter22x
  [ "$(calls)" -eq 1 ] && ok "rung 2 not attempted" || no "rung 2 ran after rung 1 succeeded"
  if verified; then no "verify ran after a rung succeeded"; else ok "no verify call"; fi

  echo "== [$sh] rung 1 fails, rung 2 re-keys =="
  run "$sh" 1 0 1 'hunter22x' 17; check "rung2" "re-keyed from the old passphrase" armed hunter22x
  [ "$(calls)" -eq 2 ] && ok "both rungs attempted" || no "rung count wrong"
  if verified; then no "verify ran after rung 2 succeeded"; else ok "no verify call"; fi

  echo "== [$sh] both rungs fail, verify accepts: already this credential =="
  run "$sh" 1 1 0 'hunter22x' 17; check "verified" "neither rung set it (already this credential)" armed hunter22x
  if [ "$(calls)" -eq 3 ] && verified; then ok "verify asked once, after the rungs"; else no "verify not asked as the third call"; fi
  if grep -e ' verify ' -e '--old' "$T/argv" | tail -1 | grep -q -e '--old'; then ok "verify carries --old"; else no "verify has no --old"; fi

  echo "== [$sh] both rungs fail, verify refuses: not armed =="
  run "$sh" 1 1 1 'hunter22x' 17; check "refused" "neither rung set it" notarmed hunter22x

  echo "== [$sh] empty pass: not armed, no cmd call =="
  run "$sh" 0 0 0 '' 17; check "empty" "no credential given" notarmed "zzzz-never"
  [ ! -s "$T/argv" ] && ok "no cmd call" || no "cmd was called with no credential"

  echo "== [$sh] verb follows the credential's type =="
  run "$sh" 0 0 0 '482913' 17
  grep -q 'set-pin' "$T/argv" && ! grep -q 'set-password' "$T/argv" && ok "all-numeric -> set-pin" || no "numeric used '$(cat "$T/argv")'"
  check "numeric" "set (no prior credential)" armed 482913
  run "$sh" 0 0 0 '4829x3' 17
  grep -q 'set-password' "$T/argv" && ! grep -q 'set-pin' "$T/argv" && ok "non-digit -> set-password" || no "alnum used '$(cat "$T/argv")'"

  echo "== [$sh] a bad uid is refused and leaves no marker =="
  run "$sh" 0 0 0 'hunter22x' '17x'
  [ "$(cat "$T/res")" = ERR-UID ] && ok "ERR-UID" || no "reply '$(cat "$T/res")'"
  [ -z "$(command ls -A "$T/state")" ] && ok "no marker" || no "marker written for a bad uid"
  [ ! -s "$T/argv" ] && ok "no cmd call" || no "cmd ran for a bad uid"
  if leak hunter22x; then no "passphrase in the log"; else ok "no passphrase in the log"; fi

  # NWP-20261116-17: user 0 is the gate; a uid under 10 or with a leading zero is refused before any cmd call
  local a u
  for a in A2:0 A3:9 A4:0123; do
    u="${a#*:}"; a="${a%%:*}"
    echo "== [$sh] $a: uid '$u' is refused before any cmd call =="
    run "$sh" 0 0 0 'hunter22x' "$u"
    [ "$(cat "$T/res" 2>/dev/null)" = ERR-UID ] && ok "$a: uid '$u' -> ERR-UID" || no "$a: uid '$u' reply '$(cat "$T/res" 2>/dev/null)'"
    [ ! -s "$T/argv" ] && ok "$a: uid '$u' -> no cmd call" || no "$a: uid '$u' -> cmd ran: '$(tr '\n' ' ' < "$T/argv")'"
    [ -z "$(command ls -A "$T/state")" ] && ok "$a: uid '$u' -> no .armcred marker" || no "$a: uid '$u' -> marker written"
    [ "$(stat -c %a "$T/res" 2>/dev/null)" = 600 ] && ok "$a: RES mode 600" || no "$a: RES mode '$(stat -c %a "$T/res" 2>/dev/null)'"
    if leak hunter22x; then no "$a: passphrase in the log"; else ok "$a: no passphrase in the log"; fi
  done
}

for s in $SHELLS; do cases "$s"; done

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite under each shell) =="
  M=$(mktemp -d -p "$W")
  # mutate <label> <sed> [<case>...]: with case labels, each named case must FAIL under the shell, not just any case
  mutate(){
    local label="$1" expr="$2" sh c miss
    shift 2
    if ! sed "$expr" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $label"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $label"; return; fi
    for sh in $SHELLS; do
      miss=""
      if bash "$0" "$M/m.sh" --shell "$sh" > "$M/out" 2>&1; then no "NOT CONVICTED under $sh: $label -- suite passes on broken code"; continue; fi
      for c in "$@"; do grep -qF "FAIL  $c:" "$M/out" || miss="$miss $c"; done
      if [ -z "$miss" ]; then ok "convicted under $sh${1:+ by $*}: $label"
      else no "NOT CONVICTED under $sh (no FAIL line from:$miss): $label"; fi
    done
  }
  mutate "fixed outcome logged" 's@armcred user \$uid: \$_arung -> @armcred user $uid: set (no prior credential) -> @'
  mutate "marker write dropped" 's@^  echo "\$_averdict" > "\$STATE/\.armcred.*$@  :@'
  mutate "passphrase logged" 's@-> \$_averdict \$(date)@-> $_averdict $pass $(date)@'
  mutate "set-pin/set-password swapped" 's@_ks=set-password ;;@_ks=XX ;;@;s@_ks=set-pin ;;@_ks=set-password ;;@;s@_ks=XX ;;@_ks=set-pin ;;@'
  mutate "verdict fixed to armed" 's@^  _averdict=notarmed$@  _averdict=armed@'
  mutate "verify step dropped" 's@if cmd lock_settings verify .*; then$@if false; then@'
  mutate "marker content fixed to armed" 's@echo "\$_averdict" > "\$STATE@echo armed > "$STATE@'
  mutate "verify rc ignored" 's@if cmd lock_settings verify \(.*\); then$@cmd lock_settings verify \1; if true; then@'
  mutate "reply fixed to OK ARMED" 's@echo "OK NOTARMED" > "\$RES"@echo "OK ARMED" > "$RES"@'
  mutate "G3 armcred floor deleted" '/armcred: uid under 10 refused/d' A2 A3
  mutate "G4 armcred leading-zero refusal deleted" '/armcred: bad uid/d' A4
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
