#!/usr/bin/env bash
# test-doze-candidate-java.sh [--mutate] -- NWP-20261114-26 (Q052, docs/product-decisions.md 2026-10-20): a bundled
# (FLAG_SYSTEM) app's battery-Unrestricted choice is a profile's own, like a user-installed app's. Compiled and
# EXECUTED (core/chooser/tests/doze-candidate/run.sh says how).
#
# WHY THIS IS COMMITTED. DozeAppsMirror.candidate is the one predicate behind capture (recordOf), the user-0 sweep
# (sweepDeparted) and the login reset (dropForeign). It used to exclude FLAG_SYSTEM, so a bundled app's choice was
# recorded by no profile and removed by nothing: it stayed on the device-wide allow-list for every later profile.
# Now candidate delegates to choiceEligible, which keeps out only what the image itself exempts (the curated push set
# ChooserActivity.PUSH_DOZE_PKGS, and gmscompat) and system or shared uids. Every piece is silent when wrong.
#
# Two halves: the cases (choiceEligible, against the lifted PUSH_DOZE_PKGS) run under javac, and source pins check
# that candidate has no FLAG_SYSTEM test and delegates to choiceEligible with PUSH_DOZE_PKGS, and that recordOf,
# sweepDeparted and dropForeign still call candidate, once each.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against deliberately broken copies, each of which must fail a CASE or a PIN.
#
#   bash test-doze-candidate-java.sh            # the cases and the pins
#   bash test-doze-candidate-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
RUN="$CH/tests/doze-candidate/run.sh"
DM="$CH/src/com/nowhere/chooser/DozeAppsMirror.java"
ACT="$CH/src/com/nowhere/chooser/ChooserActivity.java"
PROF="$CH/src/com/nowhere/chooser/ProfileActivity.java"
for f in "$RUN" "$DM" "$ACT" "$PROF"; do [ -f "$f" ] || { echo "test-doze-candidate-java: no such file: $f" >&2; exit 2; }; done
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-doze-candidate-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
export JAVAC JAVA
# One root: every temp of this suite lives inside $W (run.sh makes and removes its own inside it).
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# method_of <file> <signature prefix>: the method's lines with // comments dropped (no pinned line holds a // inside
# a literal), from the signature line to the brace that closes it
method_of(){
  awk -v sig="$2" '
    !on && index($0, sig) == 1 { on=1; depth=0 }
    on { l=$0; sub(/\/\/.*$/, "", l); print l; n=gsub(/\{/,"{",l); c=gsub(/\}/,"}",l); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}
SIG_CAND="    static boolean candidate(ApplicationInfo ai, java.util.Set<Integer> allow) {"
SIG_REC="    static java.util.TreeSet<String> recordOf("
SIG_SWEEP="    static void sweepDeparted(Context app, int departed) {"
SIG_DROP="    static int dropForeign(Context ctx, PowerExemptionManager pem, java.util.Set<String> own) {"
DELEGATE='return ai != null && choiceEligible(ai.packageName, UserHandle.getAppId(ai.uid), allow.contains(UserHandle.getAppId(ai.uid)), java.util.Arrays.asList(ChooserActivity.PUSH_DOZE_PKGS));'
# calls_in <method text>: how many times it calls candidate( (a word boundary, so choiceEligible's name is not counted)
calls_in(){ grep -oE '(^|[^A-Za-z0-9_.])candidate\(' <<<"$1" | grep -c . || true; }
# pins <file>: prints one "ok|no <label>" per pin
pins(){
  local cand joined m sig n all
  cand=$(method_of "$1" "$SIG_CAND")
  if [ "$(grep -c . <<<"$cand")" -ge 3 ]; then echo "ok control: candidate is found by its signature"; else echo "no control: candidate is not found by its signature"; fi
  if grep -qF FLAG_SYSTEM <<<"$cand"; then echo "no candidate still tests FLAG_SYSTEM"; else echo "ok candidate has no FLAG_SYSTEM test"; fi
  joined=$(tr -s ' \n' ' ' <<<"$cand")
  if grep -qF -- "$DELEGATE" <<<"$joined"; then echo "ok candidate delegates to choiceEligible with PUSH_DOZE_PKGS"; else echo "no candidate does not delegate to choiceEligible with PUSH_DOZE_PKGS"; fi
  for m in recordOf sweepDeparted dropForeign; do
    case "$m" in recordOf) sig=$SIG_REC ;; sweepDeparted) sig=$SIG_SWEEP ;; *) sig=$SIG_DROP ;; esac
    n=$(calls_in "$(method_of "$1" "$sig")")
    if [ "$n" = 1 ]; then echo "ok $m calls candidate exactly once"; else echo "no $m calls candidate $n times, not once"; fi
  done
  all=$(awk '{ l=$0; sub(/\/\/.*$/, "", l); print l }' "$1" | grep -oF 'candidate(ai, allow)' | grep -c . || true)
  if [ "$all" = 3 ]; then echo "ok the file calls candidate(ai, allow) exactly 3 times"; else echo "no the file calls candidate(ai, allow) $all times, not 3"; fi
}
run_pins(){ # run_pins <file>: ok/no lines to the counters; returns 1 if any pin failed
  local line bad=0
  while IFS= read -r line; do
    case "$line" in ok\ *) ok "${line#ok }" ;; *) no "${line#no }"; bad=1 ;; esac
  done < <(pins "$1")
  return $bad
}

echo "== the cases =="
bash "$RUN" "$DM" "$ACT" "$PROF"; rc=$?
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the suite did not pass (run.sh exit $rc: 1 a case, 2 cannot run, 3 no compile)"; fi
echo "== the candidate pins =="
run_pins "$DM"; prc=$?
# a comment line added inside candidate changes no pinned code
cp "$DM" "$W/probe.java"
sed -i "s|^$SIG_CAND\$|&\n        // probe: a comment inside candidate (FLAG_SYSTEM)|" "$W/probe.java"
if cmp -s "$W/probe.java" "$DM"; then no "probe copy is inert"; elif [ -z "$(pins "$W/probe.java" | grep '^no ' || true)" ]; then ok "a comment added inside candidate leaves the pins green"; else no "a comment inside candidate broke a pin"; fi

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ] && [ "$prc" = 0 ]; then
  echo
  echo "== mutations (each MUST be convicted by a case or a pin) =="
  mutate(){ # mutate <kind case|pin> <label> <sed script>
    local kind=$1 label=$2 script=$3 r
    rm -rf "$W/c"; mkdir -p "$W/c"
    cp "$DM" "$W/c/DozeAppsMirror.java"
    if ! sed -i "$script" "$W/c/DozeAppsMirror.java" 2>"$W/err"; then no "MUTATION BROKEN (sed): $label"; return; fi
    if cmp -s "$W/c/DozeAppsMirror.java" "$DM"; then no "MUTATION INERT: $label"; return; fi
    if [ "$kind" = case ]; then
      bash "$RUN" "$W/c/DozeAppsMirror.java" "$ACT" "$PROF" >/dev/null 2>&1; r=$?
      case "$r" in
        1) ok "convicted: $label" ;;
        0) no "NOT CONVICTED: $label -- suite passes on broken code" ;;
        *) no "MUTATION BROKEN (run.sh exit $r, not a case): $label" ;;
      esac
    else
      if [ -n "$(pins "$W/c/DozeAppsMirror.java" | grep '^no ' || true)" ]; then ok "convicted: $label"; else no "NOT CONVICTED: $label -- the pins pass on broken code"; fi
    fi
  }
  mutate pin  "candidate restores the FLAG_SYSTEM exclusion" "s|^$SIG_CAND\$|&\n        if (ai != null \&\& (ai.flags \& ApplicationInfo.FLAG_SYSTEM) != 0) return false;|"
  mutate case "choiceEligible drops the gmscompat exclusion" '/if (GMSCOMPAT_PKG.equals(pkg)) return false;/d'
  mutate case "choiceEligible drops the curated exclusion"   '/if (curated.contains(pkg)) return false;/d'
  mutate case "choiceEligible drops the appId floor"         '/if (appId < 10000) return false;/d'
  mutate case "choiceEligible returns true, not allowListed" 's/^        return allowListed;$/        return true;/'
  mutate pin  "candidate no longer delegates to choiceEligible" '/^        return ai != null && choiceEligible(/{N;s/.*/        return ai != null \&\& allow.contains(UserHandle.getAppId(ai.uid));/}'
  mutate pin  "candidate drops PUSH_DOZE_PKGS for an empty curated set" 's/java.util.Arrays.asList(ChooserActivity.PUSH_DOZE_PKGS))/java.util.Collections.<String>emptyList())/'
  mutate pin  "the sweep bypasses candidate"                  '/if (!candidate(ai, allow)) continue;/d'
  mutate pin  "the record listing bypasses candidate"         's/if (candidate(ai, allow)) out.add(ai.packageName);/out.add(ai.packageName);/'
  mutate pin  "dropForeign bypasses candidate"                's/if (candidate(ai, allow) \&\& !own.contains(ai.packageName))/if (!own.contains(ai.packageName))/'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
