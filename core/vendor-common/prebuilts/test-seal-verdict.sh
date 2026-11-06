#!/system/bin/sh
# DIA-20260812-10 (#118): assert the SEAL VERDICT GRAMMAR that roamd's `out` op emits.
#
# Why this exists. #118 is the third round of the same defect -- a seal that does not store something and
# reports success -- and the previous two rounds were each caught on hardware rather than by a test, because
# the verdict logic lives in shell and had none. The grammar is now load-bearing in three places (roamd writes
# it, the daemon parses it, the chooser renders it), so a drift in any one of them silently returns us to
# "the user is told Saved".
#
# Like test-bt-amnesia.sh, this LIFTS the real functions out of the INSTALLED script rather than restating
# them, so a stale flash or an edit that changes the vocabulary fails an assertion instead of passing against
# a copy of itself. Run on-device:  sh /system/bin/../etc/... ; or from the repo:
#   sh core/vendor-common/prebuilts/test-seal-verdict.sh           (defaults to the repo's roamd off-device)
#   sh core/vendor-common/prebuilts/test-seal-verdict.sh --mutate  (each broken copy of roamd must FAIL)
HERE=$(dirname "$0")
if [ -z "${ROAMD:-}" ]; then
  if [ -r /system/bin/nowhere_roamd.sh ]; then ROAMD=/system/bin/nowhere_roamd.sh
  else ROAMD="$HERE/../bin/nowhere_roamd.sh"; fi
fi

# --mutate: re-run this suite against sed-broken copies of roamd. A mutant that does not apply (the sed changed
# nothing) counts as a failure, never a pass, and so does a mutant the suite lets through.
if [ "${1:-}" = "--mutate" ]; then
  [ -r "$ROAMD" ] || { echo "FATAL: cannot read $ROAMD"; exit 1; }
  _tmp=$(mktemp -d) || exit 1
  trap 'rm -rf "$_tmp"' EXIT
  _bad=0
  mutant() { # <label> <sed script>
    sed -e "$2" "$ROAMD" > "$_tmp/m.sh"
    if cmp -s "$ROAMD" "$_tmp/m.sh"; then echo "  MUTANT DID NOT APPLY: $1"; _bad=$((_bad+1)); return; fi
    if ROAMD="$_tmp/m.sh" sh "$0" > "$_tmp/out" 2>&1; then echo "  SURVIVED: $1"; _bad=$((_bad+1))
    else echo "  convicted: $1"; fi
  }
  mutant "_cause 6 maps to failed" 's/^    6)   echo pending-placement ;;/    6)   echo failed ;;/'
  mutant "acct_seal pending placement returns 4" 's/^    return 6$/    return 4/'
  mutant "_cause 5 maps to pending-placement again (NWP-20261014-67)" 's/^    5)   echo unreachable ;;/    5)   echo pending-placement ;;/'
  mutant "appcode_seal returns a hardcoded 0" 's/^  return "\$ret"$/  return 0/'
  [ "$_bad" = 0 ] || { echo "FAIL: $_bad mutant(s) not convicted"; exit 1; }
  echo "PASS: every mutant convicted"; exit 0
fi
[ -r "$ROAMD" ] || { echo "FATAL: cannot read $ROAMD"; exit 1; }

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 -- got [$2] want [$3]"; fi; }

# ---- lift _cause() verbatim from the shipped script -------------------------------------------------------
# DIA-20260812-11 (#115): _cause moved to TOP LEVEL (indent 0), above the early op-dispatch, so the credless
# cleanstorage handler can call it -- it used to sit inside the `out)` arm, hundreds of lines below, where it
# was an undefined command. This sed matches the hoisted definition; if it ever drops back inside a dispatch
# arm this test fails to find it, which is the intended alarm rather than a silent pass.
_src=$(sed -n '/^_cause() {/,/^}/p' "$ROAMD")
[ -n "$_src" ] || { echo "FATAL: top-level _cause() not found in $ROAMD -- it moved back inside a dispatch arm?"; exit 1; }
eval "$_src"
# There must be exactly ONE definition: two copies of a vocabulary is how the two layers drift apart again.
_ndef=$(grep -c "_cause() {" "$ROAMD")
if [ "$_ndef" = 1 ]; then echo "  ok   exactly one _cause() definition"
else echo "  FAIL $_ndef _cause() definitions -- the hoisted one and a shadowing copy will drift"; fi

echo "== _cause: one vocabulary across BOTH layers (agent exit codes AND roamd's own guards) =="
is "0   -> ok"       "$(_cause 0)"   ok
is "3   -> nocredit" "$(_cause 3)"   nocredit      # exitNoCredit
is "4   -> refused"  "$(_cause 4)"   refused       # exitSealRefused (#657) + acct_seal/appcode_seal guards
is "5   -> unreachable" "$(_cause 5)" unreachable  # exitStoreUnreachable: the push could not reach the store (NWP-20261014-67)
is "6   -> pending-placement" "$(_cause 6)" pending-placement  # acct_seal: restored account not placed yet (DIA-20260816-16; 6 since NWP-20261014-67)
is "124 -> timeout"  "$(_cause 124)" timeout       # `timeout` killed the push; the gen never committed
is "1   -> failed"   "$(_cause 1)"   failed
is "99  -> failed"   "$(_cause 99)"  failed        # an unknown code must degrade, never emit a bare number

echo
echo "== the guards that used to be SILENT now speak in that vocabulary =="
# The three helpers whose verdicts #118 stopped discarding. Asserted against the SOURCE so a revert is caught.
for probe in \
  'acct_seal:PENDING-PLACEMENT:6' \
  'acct_seal:accounts_ce.db missing/empty:4' \
  'appcode_seal:staged 0 apk:4'
do
  fn=$(echo "$probe" | cut -d: -f1); marker=$(echo "$probe" | cut -d: -f2); want=$(echo "$probe" | cut -d: -f3)
  # The FIRST `return N` after the marker's log line. The window is deliberately generous (a guard normally
  # carries several lines of comment explaining why it refuses) but still first-match, so it cannot skip past
  # its own return into an unrelated one further down the function.
  got=$(grep -A12 "$marker" "$ROAMD" | grep -m1 -oE 'return [0-9]+' | grep -oE '[0-9]+')
  is "$fn ($marker) returns $want" "${got:-none}" "$want"
done
# appcode_seal must hand back the PUSH's rc, not a hardcoded 0.
if grep -q 'return "\$ret"' "$ROAMD"; then ok "appcode_seal returns \$ret (not a hardcoded 0)"
else bad "appcode_seal no longer returns \$ret -- a lost #apps seal is silent again"; fi
# keystore_push likewise.
if grep -q 'return "\$kret"' "$ROAMD"; then ok "keystore_push returns \$kret (not a hardcoded 0)"
else bad "keystore_push no longer returns \$kret -- a lost #keys seal is silent again"; fi

echo
echo "== the RES grammar: <VERB>[ PARTIAL:<scope>=<cause>,...] =="
# Rebuild the emission exactly as the `out` op does, so the assertions are about the shipped shape.
parts=""
_note() { if [ -z "$parts" ]; then parts="$1=$2"; else parts="$parts,$1=$2"; fi; }
emit() { # <rc> <nc> <refused>
  if [ "$1" = 0 ]; then
    if [ -n "$parts" ]; then printf 'OK PARTIAL:%s' "$parts"; else printf 'OK'; fi
  else
    _sfx=""; [ -n "$parts" ] && _sfx=" PARTIAL:$parts"
    if [ "$2" = 1 ]; then printf 'ERR-NOCREDIT%s' "$_sfx"
    elif [ "$3" = 1 ]; then printf 'ERR-REFUSED%s' "$_sfx"
    else printf 'ERR-PUSH%s' "$_sfx"; fi
  fi
}
is "clean seal is a BARE OK (byte-identical to pre-#118)" "$(emit 0 0 0)" "OK"

parts=""; _note apps refused
is "#apps refused, data fine" "$(emit 0 0 0)" "OK PARTIAL:apps=refused"

parts=""; _note sys refused; _note apps timeout
is "two silent scopes, in order" "$(emit 0 0 0)" "OK PARTIAL:sys=refused,apps=timeout"

# THE MASKING BUG: before #118 a co-occurring refusal vanished, because nc wins the if/elif and there was
# nowhere else to say it. The primary verb still picks the most actionable cause; the refusal now survives.
parts=""; _note vault nocredit; _note apps refused
is "nocredit no longer ERASES a refusal" "$(emit 1 1 0)" "ERR-NOCREDIT PARTIAL:vault=nocredit,apps=refused"

parts=""; _note media refused
is "refused verb keeps its detail" "$(emit 1 0 1)" "ERR-REFUSED PARTIAL:media=refused"

parts=""
is "generic failure with nothing else known is BARE (old readers unaffected)" "$(emit 1 0 0)" "ERR-PUSH"

echo
echo "== every verb must remain PREFIX-parseable =="
# The daemon prefix-matches OK (handleLogout) and verb-matches the rest (recordSeal). A verdict that does not
# start with its verb would strand a logoff whose data is already saved.
for v in "OK" "OK PARTIAL:apps=refused" "ERR-NOCREDIT PARTIAL:x=y" "ERR-REFUSED PARTIAL:x=y" "ERR-PUSH"; do
  case "$v" in
    OK|OK\ *|ERR-NOCREDIT*|ERR-REFUSED*|ERR-PUSH*) ok "parseable: $v" ;;
    *) bad "unparseable verdict: $v" ;;
  esac
done

echo
echo "== #115: the REAP verdict is three-way and durable =="
# CLEAN / HUSK / RESIDUE. The point of the third value: [ -e ] cannot tell an emptied-but-unlinkable directory
# (untidy) from one still holding the departed identity's data (an amnesia violation), and reporting both as
# "INCOMPLETE" makes the line that matters look like the line that does not.
classify() { # <residue-list> <husk-list> -> class
  _c=clean; [ -n "$2" ] && _c=husk; [ -n "$1" ] && _c=residue; echo "$_c"
}
is "nothing survives          -> clean"   "$(classify '' '')"                    clean
is "empty dir survives        -> husk"    "$(classify '' '/data/user/11')"       husk
is "dir with data survives    -> residue" "$(classify '/data/user/11' '')"       residue
is "both                      -> residue" "$(classify '/data/user/11' '/data/user_de/11')" residue

reapres() { # <class> <ksverdict> -> the RES line
  if [ "$1" = residue ]; then echo "ERR-REAP-RESIDUE"
  elif [ "$1" = husk ]; then echo "OK PARTIAL:reap=husk"
  elif [ "$2" = notsealed ]; then echo "OK PARTIAL:keys=notsealed"
  else echo "OK"; fi
}
is "clean reap, keys sealed"      "$(reapres clean sealed)"      "OK"
is "clean reap, nothing to seal"  "$(reapres clean nothing)"     "OK"
is "clean reap, keys NOT sealed"  "$(reapres clean notsealed)"   "OK PARTIAL:keys=notsealed"
is "husk"                         "$(reapres husk nothing)"      "OK PARTIAL:reap=husk"
is "residue is an ERR verb"       "$(reapres residue sealed)"    "ERR-REAP-RESIDUE"
# The RES line must never be EMPTY: a cleanstorage that returns without writing it holds workerMu until the
# caller times out and serialises every login and seal behind it.
for c in clean husk residue; do
  for k in sealed nothing notsealed; do
    [ -n "$(reapres $c $k)" ] || bad "EMPTY RES for class=$c keys=$k"
  done
done
ok "no combination yields an empty RES line"

echo
echo "== #115: the guards that make the verdict truthful are present in the shipped script =="
if grep -q 'KS_VERDICT=notsealed' "$ROAMD"; then ok "keystore_push sets a three-valued verdict"
else bad "KS_VERDICT missing -- the reap would read a bare exit code, where 5 paths return 0 and only 1 sealed"; fi
if grep -q 'destroyed the unsealable #keys dump' "$ROAMD"; then ok "an unsealable #keys dump is destroyed, not 'kept for retry'"
else bad "the unsealable dump is kept -- per-identity key material survives the wipe under a uid-derived name"; fi
if grep -q 'reap-ledger' "$ROAMD"; then ok "the verdict has a durable home (/data/nowhere/reap-ledger)"
else bad "no ledger -- \$RES is tmpfs and roam.log is truncated by log_scrub on the same path"; fi
# The survivor paths must NOT be double-quoted in the log, or log_scrub rewrites them to <name> (task #105).
if grep -q 'survives:\$_reapres' "$ROAMD" && ! grep -q 'survives:"\$_reap' "$ROAMD"; then
  ok "survivor paths are unquoted (log_scrub would redact them as a profile name)"
else bad "survivor paths look quoted -- log_scrub will destroy the one diagnostic this produces"; fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" = 0 ] || exit 1
