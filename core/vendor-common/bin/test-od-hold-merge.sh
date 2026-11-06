#!/usr/bin/env bash
# test-od-hold-merge.sh [<nowhere_roamd.sh>] [--mutate] -- what happens when a login finds BOTH a parked hold
# and a canonical per-app data dir (NWP-20260922-09).
#
# WHY THIS IS COMMITTED. hold_ondemand parks a kept app's restored data at login so installd cannot wipe it
# (#204). The branch that runs when a hold ALREADY exists used to be one line -- `if [ -d "$dst" ]` then
# `rm -rf "$src"` -- justified by a comment two screens up stating that in that situation the canonical is
# "an EMPTY installd skeleton" (~:259). It is a true statement about the case the branch was WRITTEN for, a
# dormant app. Nothing ever checked it, and `[ -d "$dst" ]` cannot tell that skeleton from a canonical full
# of the session's messages -- so once a hold stranded, every later login deleted the real data and handed
# the stale hold back. Chester, on losing WhatsApp history: "it worked fine for a roam, but then next roam it
# restored the backup data and dropped everything else."
#
# THE SHAPE TO KEEP IN MIND WHILE EDITING: the dormant case and the loss case are INDISTINGUISHABLE to the
# code that used to decide this, and the dormant case is the common one -- so a regression here passes every
# smoke test and only shows up as one user's missing messages, days later, with roam.log cheerfully logging
# "kept existing hold, dropped canonical" as if that were the plan. That is why this suite plants DISTINCT,
# READABLE BYTES on both sides and asserts WHICH ONES SURVIVED, rather than asserting that a directory exists.
#
#   bash test-od-hold-merge.sh            # the hold/canonical truth table + the odrestore reply
#   bash test-od-hold-merge.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# Pure logic -- hold_ondemand and the reply block are EXTRACTED from the real script by anchor and run against
# a real temp tree, so a stale copy here cannot keep passing after the code moves. No device, no store.
#
# NWP-20261112-31: and under every shell. hold_ondemand, pkgname_ok and the reply block ran only inside `bash -c`,
# while the device runs roamd under mksh. Each case now writes the extracted text and its values into a runner
# file in its case dir and runs it under each of bash, dash, mksh and sh found (an `sh` that is one of those
# binaries is skipped), after that shell parses it with `-n`; every case line is tagged `[<sh>]`, and a mutant
# convicts only when every shell has its own FAIL line (a `survive` control must survive under every shell). The
# odkept increment pins are textual, run by no shell: they run once, untagged, and their mutants convict on them.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for every temp; nothing outlives the suite. The runners carry it in single quotes.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
case "$W" in *\'*) echo "temp root has a quote: $W" >&2; exit 2 ;; esac

# The shells: bash, dash and mksh each under its own name, then sh unless it is one of those binaries.
SHELLS=""; seen=" "
for s in bash dash mksh sh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  if [ "$s" = sh ]; then
    case "$seen" in *" $r "*) continue ;; esac
  fi
  seen="$seen$r "; SHELLS="$SHELLS $s"
done
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }

PASS=0; FAIL=0; BROKEN=0; TAG=""; CUR_SH=""
ok(){ PASS=$((PASS+1)); printf '  ok    %s%s\n' "$TAG" "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s%s\n' "$TAG" "$1"; }

# --- extraction ---------------------------------------------------------------------------------------
# hold_ondemand, verbatim, plus the ODHOLD constant it depends on. Both by anchor: an extraction that
# silently yielded nothing would run an EMPTY function and report a clean pass for every case below, which
# is the exact fail-open this repo has been bitten by (a missing `sed -f` file, an empty extraction).
# So each step asserts it produced something, and the assertions are on the extracted text, not on a copy.
FN=$(awk '/^hold_ondemand\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SUT")
ODHOLD_LINE=$(grep -m1 '^ODHOLD=' "$SUT")
case "$FN" in
  *'nowhere-appkeep'*'$ODHOLD'*) ;;
  *) echo "EXTRACTION FAILED -- hold_ondemand moved or changed shape in $SUT" >&2; exit 2 ;;
esac
[ -n "$ODHOLD_LINE" ] || { echo "EXTRACTION FAILED -- no ODHOLD= line in $SUT" >&2; exit 2; }
# NWP-20261014-20: hold_ondemand calls pkgname_ok on every keep-set name; without it every row would be skipped.
PKGOK=$(awk '/^pkgname_ok\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SUT")
case "$PKGOK" in
  *'return 1'*'return 0'*) ;;
  *) echo "EXTRACTION FAILED -- pkgname_ok moved or changed shape in $SUT" >&2; exit 2 ;;
esac

# The function hardcodes /data/... . Re-root it so this can run anywhere. ASSERT the rewrite applied: a
# rewrite that matched nothing would leave the function pointing at a real /data that does not exist here,
# every [ -d ] would be false, every case would "pass" having done nothing at all.
FN_ROOTED=$(printf '%s\n' "$FN" | sed 's#"/data/#"$ROOT/data/#g')
NREW=$(printf '%s\n' "$FN_ROOTED" | grep -c '"\$ROOT/data/')
[ "${NREW:-0}" -ge 3 ] || { echo "RE-ROOT FAILED -- $NREW rewritten, want >=3 (the CE/DE, external and appkeep paths)" >&2; exit 2; }
# ...and COMPLETE, not merely non-zero: one absolute path left behind would silently point at a real /data
# that is not there, so its `[ -d ]` is false, its loop body never runs, and the scenario passes having
# tested nothing. Comments are stripped first -- several of them quote /data paths as evidence.
NLEFT=$(printf '%s\n' "$FN_ROOTED" | sed 's/#.*$//' | grep -c '"/data/')
[ "${NLEFT:-0}" = 0 ] || { echo "RE-ROOT INCOMPLETE -- $NLEFT absolute /data path(s) survive in live code" >&2; exit 2; }
# The odrestore reply block (its cases are below, with the reply harness).
REPLY=$(awk '/^    if \[ "\$odsrc" = 0 \]; then$/{f=1} f{print} f&&/^    fi$/{exit}' "$SUT")
case "$REPLY" in
  *'OK NOSRC'*'OK $pkg'*) ;;
  *) echo "EXTRACTION FAILED -- the odrestore reply block moved in $SUT" >&2; exit 2 ;;
esac

# --- the harness --------------------------------------------------------------------------------------
# One scenario = one temp tree. plant <path> <bytes> writes a file; read_back prints it or "-" if gone.
# The extracted text runs from a runner file under the shell of the pass ("$CUR_SH"), as roamd would run it.
hold_runner(){                     # hold_runner <file> <root> <uid> [failcp]
  {
    printf 'set -u\n'
    printf "ROOT='%s'; LOG=\"\$ROOT/roam.log\"\n" "$2"
    printf 'restorecon(){ :; }\n'                # not on a dev host; the function only uses it to relabel
    [ "${4:-}" = failcp ] && printf 'cp(){ return 1; }\n'
    printf '%s\n' "$ODHOLD_LINE" "$PKGOK" "$FN_ROOTED"
    printf "hold_ondemand '%s'\n" "$3"
  } > "$1"
}
run_hold(){                        # run_hold <sh> <root> <uid> [failcp]  -- exercise the REAL extracted function
  hold_runner "$2/run.sh" "$2" "$3" "${4:-}"
  "$1" "$2/run.sh"
}
plant(){ mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }
val(){ [ -f "$1" ] && cat "$1" || echo -; }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got '$2', want '$3'"; }

reply_runner(){                    # reply_runner <file> <dir> <odsrc> <odn> <odkept>
  {
    printf 'set -u\n'
    printf "odsrc='%s'; odn='%s'; odkept='%s'; pkg=com.whatsapp; RES='%s/res'; LOG='%s/log'\n" "$3" "$4" "$5" "$2" "$2"
    printf '%s\n' "$REPLY"
  } > "$1"
}
reply(){                           # reply <sh> <odsrc> <odn> [odkept] -> the token written to $RES
  local sh="$1" d; d=$(mktemp -d -p "$W")
  reply_runner "$d/run.sh" "$d" "$2" "$3" "${4:-0}"
  "$sh" "$d/run.sh"
  cat "$d/res"; rm -rf "$d"
}
starts_ok(){ case "$1" in OK*) echo yes;; *) echo no;; esac; }

# parse_ok <sh> -- each runner kind must PARSE under that shell, or a syntax error would read as a verdict.
parse_ok(){
  local sh="$1" d k
  d=$(mktemp -d -p "$W")
  hold_runner "$d/hold.sh" "$d" 15
  hold_runner "$d/failcp.sh" "$d" 15 failcp
  reply_runner "$d/reply.sh" "$d" 1 1 0
  for k in hold failcp reply; do
    if ! "$sh" -n "$d/$k.sh" 2>/dev/null; then
      rm -rf "$d"
      no "THE $k BLOCK DOES NOT PARSE under $sh in $SUT"; BROKEN=1; return 1
    fi
  done
  rm -rf "$d"
}

# scenario: a keep-set with one ondemand row for com.whatsapp
new_tree(){
  T=$(mktemp -d -p "$W"); U=15
  CE="$T/data/user/$U"; EXT="$T/data/media/$U/Android/data"
  HOLD="$CE/com.nowhere.chooser/.nowhere-odhold/com.whatsapp"
  EHOLD="$EXT/com.nowhere.chooser/.nowhere-odhold/com.whatsapp"
  CANON="$CE/com.whatsapp"; ECANON="$EXT/com.whatsapp"
  mkdir -p "$CE/com.nowhere.chooser/files"
  printf 'com.whatsapp\tondemand\n' > "$CE/com.nowhere.chooser/files/nowhere-appkeep"
}

for sh in $SHELLS; do
TAG="[$sh] "; CUR_SH="$sh"
parse_ok "$sh" || continue

echo "== [$sh] THE REPORTED LOSS: a stranded hold must not eat the session's data =="
new_tree
plant "$HOLD/databases/msgstore.db" OLD           # the stale hold, from the failed hand-back
plant "$HOLD/shared_prefs/only-in-hold.xml" KEEPME
plant "$CANON/databases/msgstore.db" NEW          # this session's messages, in the canonical
plant "$CANON/files/new-since.bin" FRESH
run_hold "$CUR_SH" "$T" "$U"
eq "the newer msgstore wins -- the old one winning IS the bug Chester reported" \
   "$(val "$HOLD/databases/msgstore.db")" NEW
eq "a file only THIS session has survives the merge" "$(val "$HOLD/files/new-since.bin")" FRESH
eq "a file only the STALE HOLD has also survives -- the merge adds, it does not replace wholesale" \
   "$(val "$HOLD/shared_prefs/only-in-hold.xml")" KEEPME
eq "the canonical is consumed once the merge is clean" "$([ -d "$CANON" ] && echo present || echo gone)" gone
rm -rf "$T"

echo
echo "== [$sh] THE CASE THE BRANCH WAS WRITTEN FOR: a dormant app must behave exactly as before =="
new_tree
plant "$HOLD/databases/msgstore.db" REALDATA
mkdir -p "$CANON/cache" "$CANON/code_cache"       # the EMPTY installd skeleton, re-sealed beside the hold
run_hold "$CUR_SH" "$T" "$U"
eq "the dormant app's real data is untouched" "$(val "$HOLD/databases/msgstore.db")" REALDATA
eq "the empty skeleton is still dropped -- outcome unchanged for the common case" \
   "$([ -d "$CANON" ] && echo present || echo gone)" gone
rm -rf "$T"

echo
echo "== [$sh] no hold yet: the ordinary park is a rename, untouched by this slice =="
new_tree
plant "$CANON/databases/msgstore.db" NEW
run_hold "$CUR_SH" "$T" "$U"
eq "the canonical is parked into the hold" "$(val "$HOLD/databases/msgstore.db")" NEW
eq "and is gone from its canonical path" "$([ -d "$CANON" ] && echo present || echo gone)" gone
rm -rf "$T"

echo
echo "== [$sh] the EXTERNAL volumes carry the most bytes and had the identical ratchet =="
new_tree
plant "$EHOLD/files/stale.bin" OLD
plant "$ECANON/files/stale.bin" NEW
plant "$ECANON/files/essential.bin" FRESH
run_hold "$CUR_SH" "$T" "$U"
eq "external: the newer copy wins" "$(val "$EHOLD/files/stale.bin")" NEW
eq "external: this session's essential media survives (#497 -- Android/data IS the essential tier)" \
   "$(val "$EHOLD/files/essential.bin")" FRESH
rm -rf "$T"

echo
echo "== [$sh] a FAILED merge must drop nothing (the rule odrestore states: a failure stays recoverable) =="
new_tree
plant "$HOLD/databases/msgstore.db" OLD
plant "$CANON/databases/msgstore.db" NEW
run_hold "$CUR_SH" "$T" "$U" failcp  # the copy fails -- a full volume, a label refusal, anything
eq "the canonical is LEFT IN PLACE when the merge fails" "$(val "$CANON/databases/msgstore.db")" NEW
eq "and the hold is left alone too -- nothing is destroyed on a failure" \
   "$(val "$HOLD/databases/msgstore.db")" OLD
rm -rf "$T"

# --- the odrestore reply ---------------------------------------------------------------------------------
# The other half of the same defect: `odsrc` records only that a hold EXISTED, so a run where every volume
# deliberately KEPT its hold still answered "OK <pkg>". Both Java callers mark on ANY reply starting with OK,
# so that false OK suppressed the retry that would have un-stranded the hold. Asserted against the exact
# predicate the Java side uses -- startsWith("OK") -- not against the token text.
echo
echo "== [$sh] the odrestore reply must be able to say NOT READY =="

eq "no hold at all -> OK NOSRC (a plain new install; the install-heal relies on this)" \
   "$(reply "$CUR_SH" 0 0)" "OK NOSRC"
eq "every volume handed back, none kept -> OK <pkg>" "$(reply "$CUR_SH" 1 2 0)" "OK com.whatsapp"
eq "CE kept while an external volume restored -> ERR-NOTREADY, not a masked OK (NWP-20261013-22)" \
   "$(reply "$CUR_SH" 1 1 1)" ERR-NOTREADY
eq "an external volume kept alone -> ERR-NOTREADY" "$(reply "$CUR_SH" 1 1 1)" ERR-NOTREADY
eq "a hold existed but NONE restored -> the reply must NOT read as OK to the Java side" \
   "$(starts_ok "$(reply "$CUR_SH" 1 0 1)")" no
eq "...and the confirmed case must still read as OK, or every restore would retry forever" \
   "$(starts_ok "$(reply "$CUR_SH" 1 2 0)")" yes
done
TAG=""; CUR_SH=""

# The three increment sites live inside the volume loop, which cannot be extracted; pin each by anchor: the
# `odkept` increment must sit within 3 lines after its own log line.
echo
echo "== every hold-KEPT path counts into odkept =="
for anchor in 'dest NOT app-owned' 'cp FAILED -- hold KEPT' 'dest missing -- hold KEPT'; do
  n=$(grep -A3 -F "$anchor" "$SUT" | grep -c 'odkept=\$((odkept+1))')
  eq "odkept is incremented at the '$anchor' path" "$n" 1
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted, except the stated control) =="
  M=$(mktemp -d -p "$W")
  mutate(){                        # mutate <label> <sed-expr> <want: convict|survive|pin> [<pin site>]
    local want="${3:-convict}" site="${4:-}" rc out sh miss="" bad=""
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT (anchor never matched): $1"; return; fi
    out=$(bash "$0" "$M/m.sh" 2>&1); rc=$?
    # ⚠ rc 2 is the harness refusing to run (extraction moved), NOT a verdict. Counting it as a conviction is
    # how a suite congratulates itself for never having executed -- the same fail-open as a check whose tool
    # is missing. A conviction MUST be rc 1, an assertion that actually ran and failed.
    # NWP-20261112-31: and under EVERY shell -- each shell found needs its own FAIL line; a `survive` control
    # needs every shell's ok lines and no FAIL at all; a `pin` mutant changes text only the untagged odkept pin
    # reads, so it convicts on that pin's line.
    for sh in $SHELLS; do
      case "$out" in *"  FAIL  [$sh] "*) bad="$bad $sh" ;; esac
      case "$out" in *"  ok    [$sh] "*) ;; *) miss="$miss $sh" ;; esac
    done
    case "$rc:$want" in
      0:survive)
        case "$out" in
          *"  FAIL  "*) no "WRONGLY CONVICTED: $1 -- a FAIL line on rc 0" ;;
          *) if [ -n "$miss" ]; then no "INCONCLUSIVE: $1 -- no case ran under$miss"
             else ok "survived as intended: $1 [$SHELLS ]"; fi ;;
        esac ;;
      1:convict)
        miss=""
        for sh in $SHELLS; do case " $bad " in *" $sh "*) ;; *) miss="$miss $sh" ;; esac; done
        if [ -n "$miss" ]; then no "NOT CONVICTED under$miss: $1"
        else
          ok "convicted: $1 [$SHELLS ]"
          printf '%s\n' "$out" | grep -F "  FAIL  [" | sed 's/^/      /'
        fi ;;
      1:pin)
        case "$out" in
          *"  FAIL  odkept is incremented at the '$site' path"*) ok "convicted by its pin: $1" ;;
          *) no "NOT CONVICTED by the '$site' pin: $1" ;;
        esac ;;
      0:convict|0:pin) no "NOT CONVICTED: $1 -- suite passes on broken code" ;;
      1:survive) no "WRONGLY CONVICTED under$bad: $1 -- the suite is pinning prose, not behaviour" ;;
      *)         no "INCONCLUSIVE (rc=$rc): $1 -- the mutation broke the harness, so nothing was tested" ;;
    esac
  }
  # The bug itself, restored. Each site is addressed by the RANGE from its own unique comment down to the
  # shared `_ce=$(cp -a` line -- the three copy sites are textually identical, so an unaddressed pattern would
  # mutate all three at once and no single failure would tell you which one the suite actually covers.
  mutate "the CE/DE merge is a no-op, so the stale hold wins again -- the reported bug, exactly" \
         '/pre-existing hazard, but this script/,/_ce=\$(cp -a/s#if _ce=\$(cp -a "\$src"/\. "\$dst"/ 2>&1); then#if true; then#'
  mutate "the EXTERNAL merge is a no-op -- same ratchet on the volumes carrying the most bytes" \
         '/collapses essential media and trips/,/_ce=\$(cp -a/s#if _ce=\$(cp -a "\$src"/\. "\$dst"/ 2>&1); then#if true; then#'
  mutate "the merge direction is reversed -- the STALE hold overwrites the session's data" \
         '/pre-existing hazard, but this script/,/_ce=\$(cp -a/s#cp -a "\$src"/\. "\$dst"/#cp -a "$dst"/. "$src"/#'
  mutate "the merge stops being guarded, so a FAILED copy still deletes the canonical" \
         's#if _ce=\$(cp -a "\$src"/\. "\$dst"/ 2>&1); then#if _ce=$(cp -a "$src"/. "$dst"/ 2>\&1) || true; then#'
  mutate "the odrestore reply goes back to two outcomes, so a kept hold still reports OK" \
         's#^    elif \[ "\$odkept" -gt 0 \]; then$#    elif false; then#'
  mutate "the reply reverts to the single odn counter, so a CE failure beside an external success answers OK" \
         's#^    elif \[ "\$odkept" -gt 0 \]; then$#    elif [ "$odn" = 0 ]; then#'
  for site in 'dest NOT app-owned' 'cp FAILED -- hold KEPT' 'dest missing -- hold KEPT'; do
    mutate "the '$site' path stops counting into odkept" \
           "/$site/,+3s#odkept=\$((odkept+1))#:#" pin "$site"
  done
  # CONTROL. If this is convicted the suite is matching comment prose, which is how two assertions in this
  # tree passed while the code they pinned was commented out.
  mutate "CONTROL: a word in a comment changes (must SURVIVE)" \
         's#A DATA-LOSS RATCHET#a DATA LOSS RATCHET#' survive
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$BROKEN" = 0 ] || exit 2
[ "$FAIL" = 0 ]
