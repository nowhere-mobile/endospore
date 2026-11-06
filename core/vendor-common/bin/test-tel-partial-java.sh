#!/usr/bin/env bash
# test-tel-partial-java.sh [--mutate] -- NWP-20261110-12 (Q029, docs/product-decisions.md 2026-10-20): a co-owned SIM
# whose seal reaches only some of its owners. The daemon answers "OK ... PARTIAL" (NWP-20261110-11); the gate then posts
# the hedged "may not have been saved" loss notice INSTEAD OF the line's normal one, under the same arrival id, only once
# the arrival's 60 s seal deadline has passed -- so a partial failure and a total failure look the same in text and in
# timing, and no notice shows that the line has more than one owner. Posting both is ruled out.
#
# Two halves. The pure helpers that decide it -- SmsDeliverReceiver.holdMs (how long the notice waits) and .partialLoss
# (whether it is posted, under the failure branch's Private rule) -- are lifted by name with TelArrival.Reply and
# EXECUTED under plain javac (core/chooser/tests/tel-partial). The order of settle's partial branch and the one deadline
# the two seal callers share are SOURCE CHECKS on the real methods, read without their comments, since settle itself
# needs Android to run. core/chooser/test-tel-seal.sh pins those methods byte for byte.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner that
# never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21. --mutate re-runs it against broken copies
# of SmsDeliverReceiver.java (never the source), each of which must fail a case or a source check.
#
#   bash test-tel-partial-java.sh            # the cases and the source checks
#   bash test-tel-partial-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SRC="$ROOT/core/chooser/src/com/nowhere/chooser"
RUN="$ROOT/core/chooser/tests/tel-partial/run.sh"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-tel-partial-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
export JAVAC JAVA

# the one root every run's sources, classes and mutant copies live under
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match reads its input to the end: `grep -c ... >/dev/null`, never `grep -q`.

# body <file> <signature fragment>: from the signature to the first line that is exactly four spaces and } -- or a
# marker that fails every check when the signature does not occur exactly once (test-tel-seal.sh's body()).
body(){ [ "$(grep -cF -- "$2" "$1")" = 1 ] || { echo "<signature not exactly once: $2>"; return; }; awk -v sig="$2" -v end="    }" 'index($0, sig) { on = 1 } on { print } on && $0 == end { exit }' "$1"; }
# code <text>: the text without its comments (test-tel-seal.sh's code()) -- // to the end of a line and /* */ across
# lines, but not inside a string or char literal -- and without the lines that leave blank.
code(){ printf '%s\n' "$1" | awk '
{ out = ""; n = length($0); i = 1; str = 0; chr = 0
  while (i <= n) {
    c = substr($0, i, 1); d = substr($0, i, 2)
    if (blk) { if (d == "*/") { blk = 0; i += 2 } else i++; continue }
    if (str || chr) {
      out = out c
      if (c == "\\") { out = out substr($0, i + 1, 1); i += 2; continue }
      if ((str && c == "\"") || (chr && c == "\047")) { str = 0; chr = 0 }
      i++; continue
    }
    if (d == "/*") { blk = 1; i += 2; continue }
    if (d == "//") break
    if (c == "\"") str = 1; else if (c == "\047") chr = 1
    out = out c; i++
  }
  if (out ~ /[^[:space:]]/) print out
}'; }
# has <code> <fixed string> / count <code> <fixed string> / line <code> <fixed string> (1-based, first match, or 0) --
# on text code() has already stripped.
has(){ printf '%s\n' "$1" | grep -cF -- "$2" >/dev/null; }
count(){ printf '%s\n' "$1" | grep -cF -- "$2"; }
line(){ local n; n=$(printf '%s\n' "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1); echo "${n:-0}"; }

RUNN=0
# suite <source dir> -- the cases, then the source checks, on that dir's SmsDeliverReceiver.java and TelArrival.java.
# Returns 0 when everything passed, 1 when a case or a check failed, 2 when the cases could not run (no compile, a
# member not lifted): a mutant that only breaks the build is not a conviction.
suite(){
  local d="$1" rc st s m br l1 l2 b t
  RUNN=$((RUNN+1))
  echo "== the cases (holdMs, partialLoss, TelArrival.Reply lifted and executed) =="
  bash "$RUN" "$d" "$W/run$RUNN"; rc=$?
  case "$rc" in
    0) ok "every case passes" ;;
    1) no "a case failed" ;;
    *) no "the cases did not run (run.sh exit $rc: 2 cannot run or EXTRACTION FAILED, 3 no compile)" ;;
  esac
  st=$(code "$(body "$d/SmsDeliverReceiver.java" 'static int settle(Context ctx, TelArrival.Reply r, String kind, int callType, String iccid, String from,')")
  s=$(code "$(body "$d/SmsDeliverReceiver.java" 'static int sealAndNotify(Context ctx, String kind, int subId, String iccid, String from, long when, String body,')")
  m=$(code "$(body "$d/SmsDeliverReceiver.java" 'static int sealMmsAndNotify(Context ctx, int subId, String from, long when, String subject,')")
  # settle's partial branch: from its test to the first line that closes it at the method body's own indent
  br=$(printf '%s\n' "$st" | awk 'index($0, "if (r.partial) {") { on = 1 } on { print } on && /^        }[[:space:]]*$/ { exit }')

  echo "== settle's partial branch (source, comments removed) =="
  l1=$(line "$st" 'if (r.partial) {'); l2=$(line "$st" 'if (r.liveUid >= 0) {')
  if [ "$l1" -gt 0 ] && [ "$l2" -gt 0 ] && [ "$l1" -lt "$l2" ]; then ok "S1 the partial branch comes before the full OK's live-or-labelled path"
  else no "S1 no partial branch ahead of 'if (r.liveUid >= 0) {' -- a partial seal shows the line's normal notice at once"; fi
  l1=$(line "$br" 'try { Thread.sleep(holdMs(r.deadline, TelArrival.stamp())); }'); l2=$(line "$br" 'if (partialLoss(r, TelArrival.knownPrivate(iccid))) postLossNotice(ctx, kind, callType, aid);')
  if [ "$l1" -gt 0 ] && [ "$l2" -gt 0 ] && [ "$l1" -lt "$l2" ] && has "$br" 'return SEAL_SEALED;'; then ok "S2 the branch waits out holdMs to the deadline, then posts the loss notice under the Private rule, and answers SEALED"
  else no "S2 the branch posts its loss notice before the deadline, without the Private rule, or answers other than SEALED -- a partial failure would be told from a total one by its timing"; fi
  if [ -n "$br" ] && ! has "$br" 'postMessageNotice' && ! has "$br" 'gateNotice'; then ok "S3 the branch never posts the line's normal notice, and does not depend on gateNotice"
  else no "S3 the branch posts the line's normal notice too (both notices are ruled out), or hangs the loss notice on gateNotice"; fi
  b=0
  for t in "$s|TelArrival.untilAnswered(req, 5000, deadline, safe(iccid));|settle(ctx, r, kind, callType, safe(iccid), from, gateNotice, aid);" \
           "$m|TelArrival.untilAnswered(req, 10_000, deadline, iccid);|settle(ctx, r, \"mms\", 0, iccid, from, true, aid);"; do
    local x="${t%%|*}" rest="${t#*|}"; local ua="${rest%%|*}" se="${rest#*|}" ld lu lr ls
    ld=$(line "$x" 'final long deadline = TelArrival.stamp() + TelArrival.SEAL_DEADLINE_MS;'); lu=$(line "$x" "$ua")
    lr=$(line "$x" 'if (r != null) r.deadline = deadline;'); ls=$(line "$x" "$se")
    { [ "$(count "$x" 'final long deadline = ')" = 1 ] && [ "$(count "$x" 'r.deadline = deadline;')" = 1 ] \
      && [ "$ld" -gt 0 ] && [ "$ld" -lt "$lu" ] && [ "$lu" -lt "$lr" ] && [ "$lr" -lt "$ls" ]; } || b=1
  done
  if [ "$b" = 0 ]; then ok "S4 sealAndNotify and sealMmsAndNotify each pass one local deadline to untilAnswered and to r.deadline, before settle"
  else no "S4 a seal caller computes its deadline twice, or never hands it to the reply -- the hold would not end with the retries"; fi
  case "$rc" in 0|1) ;; *) return 2 ;; esac
  [ "$FAIL" = 0 ] && return 0 || return 1
}

suite "$SRC"; base=$?

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ] && [ "$base" = 0 ]; then
  echo
  echo "== mutations (each MUST be convicted by a case or a source check) =="
  MUTN=0
  mutate(){ # mutate <label> <sed script applied to a copy of SmsDeliverReceiver.java>
    local d r out
    MUTN=$((MUTN+1)); d="$W/mut$MUTN"; mkdir -p "$d" || { no "MUTATION BROKEN (no dir): $1"; return; }
    cp "$SRC/SmsDeliverReceiver.java" "$SRC/TelArrival.java" "$d/" || { no "MUTATION BROKEN (copy): $1"; return; }
    if ! sed -i "$2" "$d/SmsDeliverReceiver.java" 2>"$d/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$d/SmsDeliverReceiver.java" "$SRC/SmsDeliverReceiver.java"; then no "MUTATION INERT: $1"; return; fi
    # a sub-shell, so the mutant's own tallies stay out of this run's
    out=$(PASS=0 FAIL=0; suite "$d" >/dev/null 2>&1; echo $?); r=$out
    case "$r" in
      1) ok "convicted: $1" ;;
      0) no "NOT CONVICTED: $1 -- suite passes on broken code" ;;
      *) no "MUTATION BROKEN (the cases did not run or compile, not a conviction): $1" ;;
    esac
  }
  mutate "M1 the partial branch removed" \
    '/^        if (r.partial) {/,/^        }$/d'
  mutate "M2 postLossNotice before the sleep" \
    '/try { Thread.sleep(holdMs(r.deadline, TelArrival.stamp()));/{h;d}; /if (partialLoss(r, TelArrival.knownPrivate(iccid))) postLossNotice(ctx, kind, callType, aid);/G'
  mutate "M3 postMessageNotice added to the branch" \
    '/^        if (r.partial) {/,/^        }$/{/return SEAL_SEALED;/i\            postMessageNotice(ctx, r.label, kind, callType, null);
}'
  mutate "M4 holdMs returns deadline, not deadline - now" \
    's/return deadline <= 0 ? 0 : Math.max(0, deadline - now);/return deadline <= 0 ? 0 : deadline;/'
  mutate "M5 partialLoss ignores knownPrivate" \
    '/static boolean partialLoss(/,/^    }$/s/ \&\& !knownPrivate//'
  mutate "M6 sealAndNotify leaves r.deadline unset" \
    '/static int sealAndNotify(/,/^    }$/{/if (r != null) r.deadline = deadline;/d}'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
