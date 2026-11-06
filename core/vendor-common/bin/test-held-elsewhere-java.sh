#!/usr/bin/env bash
# test-held-elsewhere-java.sh [--mutate] -- NWP-20261120-15: Profile > Preferences > Apps this device is holding also
# lists, read-only, the apps the claim record says another device holds (docs/product-decisions.md, 2026-09-12).
# Runs core/chooser/tests/held-elsewhere (HeldElsewhereCopy's words, compiled and EXECUTED) and source checks that
# showHeldApps reads AppClaim.claimsForScreen BEFORE AppHeld.heldNow, says HeldElsewhereCopy.UNREADABLE for an
# unreadable record, draws the list through HeldElsewhereCopy.body, and that claimsForScreen keeps the null.
# NWP-20261128-23: one heading per holder -- HeldElsewhereCopy.heading/body(labels, holder) name the holder (H1-H3);
# showHeldApps reads AppClaim.namesForScreen before AppHeld.heldNow and groups with the tap dialog's
# AppClaim.holdGroups (s3, s5); namesForScreen returns readClaimNames as it is (s6).
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies, each of which must FAIL: a mutant that does not apply (INERT) or
# fails for another reason (BROKEN) counts as a failure, never a pass.
#
#   bash test-held-elsewhere-java.sh            # the cases
#   bash test-held-elsewhere-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-held-elsewhere-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
command -v perl >/dev/null 2>&1 || { echo "test-held-elsewhere-java: FAIL -- the source checks need perl, and there is none; this suite did NOT run" >&2; exit 2; }
SRCDIR="$ROOT/core/chooser/src/com/nowhere/chooser"
HC="$SRCDIR/HeldElsewhereCopy.java"
PA="$SRCDIR/ProfileActivity.java"
AC="$SRCDIR/AppClaim.java"

# strip <in> <out>: Java comments removed, string literals kept.
strip() {
  perl -0pe 's{("(?:\\.|[^"\\\n])*")|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : ""}gse' "$1" > "$2"
}

# body <file> <signature>: the method from its signature to its closing brace.
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# has <text> <perl regex>: 0 when the text matches.
has() { perl -0e 'exit(($ARGV[0] =~ /$ARGV[1]/s) ? 0 : 1)' -- "$1" "$2"; }

# check <HeldElsewhereCopy.java> <ProfileActivity.java> <AppClaim.java>: the cases, then the source checks.
check() {
  local hc=$1 pa=$2 ac=$3 st sac b ab nb pre_claim pre_held pre_names want want2
  [ -f "$hc" ] || { echo "FAIL c0: no HeldElsewhereCopy.java"; return 1; }
  JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/held-elsewhere/run.sh" "$hc" || return 1
  st=$(mktemp -p "$W") || return 1
  sac=$(mktemp -p "$W") || return 1
  strip "$pa" "$st" || { echo "FAIL s1: could not strip $pa"; return 1; }
  strip "$ac" "$sac" || { echo "FAIL s4: could not strip $ac"; return 1; }
  b=$(body "$st" "private void showHeldApps()")
  [ -n "$b" ] || { echo "FAIL s1: showHeldApps was not found"; return 1; }
  # (s1) the claim record is read FIRST: heldNow can wait on AppHeld's lock past the join, and a claim read queued
  # behind it would read as UNREADABLE
  case "$b" in *'AppClaim.claimsForScreen(this)'*) ;; *) echo "FAIL s1: showHeldApps does not call AppClaim.claimsForScreen(this)"; return 1 ;; esac
  case "$b" in *'AppHeld.heldNow('*) ;; *) echo "FAIL s1: showHeldApps does not call AppHeld.heldNow"; return 1 ;; esac
  pre_claim=${b%%AppClaim.claimsForScreen(this)*}
  pre_held=${b%%AppHeld.heldNow(*}
  [ "${#pre_claim}" -lt "${#pre_held}" ] \
    || { echo "FAIL s1: showHeldApps does not call AppClaim.claimsForScreen before AppHeld.heldNow"; return 1; }
  # (s2) a null claims map (unreadable record) says UNREADABLE, never "nothing held elsewhere"
  has "$b" 'if \(\w+ == null\) \{[^}]*HeldElsewhereCopy\.UNREADABLE' \
    || { echo "FAIL s2: showHeldApps does not say HeldElsewhereCopy.UNREADABLE under a null test"; return 1; }
  # (s3) each holder's list is drawn through HeldElsewhereCopy, under a heading naming that holder (NWP-20261128-23:
  # the single HeldElsewhereCopy.HEADING over every package is gone)
  case "$b" in *'HeldElsewhereCopy.body('*) ;; *) echo "FAIL s3: showHeldApps does not draw the list with HeldElsewhereCopy.body"; return 1 ;; esac
  case "$b" in *'HeldElsewhereCopy.heading('*) ;; *) echo "FAIL s3: showHeldApps does not draw HeldElsewhereCopy.heading"; return 1 ;; esac
  case "$b" in *'HeldElsewhereCopy.HEADING'*) echo "FAIL s3: showHeldApps draws HeldElsewhereCopy.HEADING over every package"; return 1 ;; esac
  # (s5) the names are read with the claims, before heldNow (s1's rule), and grouped by the tap dialog's rule
  case "$b" in *'AppClaim.namesForScreen(this)'*) ;; *) echo "FAIL s5: showHeldApps does not call AppClaim.namesForScreen(this)"; return 1 ;; esac
  pre_names=${b%%AppClaim.namesForScreen(this)*}
  [ "${#pre_names}" -lt "${#pre_held}" ] \
    || { echo "FAIL s5: showHeldApps does not call AppClaim.namesForScreen before AppHeld.heldNow"; return 1; }
  has "$b" 'AppClaim\.holdGroups\(java\.util\.Arrays\.asList\(elsewhere\), \w+, HeldElsewhereCopy\.WHERE\)' \
    || { echo "FAIL s5: showHeldApps does not group with AppClaim.holdGroups(..., HeldElsewhereCopy.WHERE)"; return 1; }
  echo "  ok   source checks s1 s2 s3 s5"
  # (s4) claimsForScreen returns readClaims as it is: claimedElsewhere collapses null to empty, a screen must not
  ab=$(body "$sac" "static java.util.LinkedHashMap<String, String> claimsForScreen(Context ctx)")
  ab=$(perl -0pe 's/\s+/ /g; s/^ | $//g' <<<"$ab")
  want='static java.util.LinkedHashMap<String, String> claimsForScreen(Context ctx) { return readClaims(ctx); }'
  [ "$ab" = "$want" ] || { echo "FAIL s4: AppClaim.claimsForScreen does not return readClaims(ctx) (got: $ab)"; return 1; }
  # (s6) namesForScreen returns readClaimNames as it is: an empty map would name no holder on the screen
  nb=$(body "$sac" "static java.util.LinkedHashMap<String, String> namesForScreen(Context ctx)")
  nb=$(perl -0pe 's/\s+/ /g; s/^ | $//g' <<<"$nb")
  want2='static java.util.LinkedHashMap<String, String> namesForScreen(Context ctx) { return readClaimNames(ctx); }'
  [ "$nb" = "$want2" ] || { echo "FAIL s6: AppClaim.namesForScreen does not return readClaimNames(ctx) (got: $nb)"; return 1; }
  echo "  ok   source checks s4 s6"
}
check "$HC" "$PA" "$AC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply proves nothing)"
mut() { # mut <label> <hc|pa|ac> <perl-expr> <text the failure must contain>
  local d f hc pa ac src out rc
  d=$(mktemp -d -p "$W"); hc=$HC; pa=$PA; ac=$AC
  case "$2" in
    hc) src=$HC; f="$d/HeldElsewhereCopy.java"; hc=$f ;;
    pa) src=$PA; f="$d/ProfileActivity.java"; pa=$f ;;
    ac) src=$AC; f="$d/AppClaim.java"; ac=$f ;;
    *) echo "  ERROR     $1 -- unknown file $2"; return 1 ;;
  esac
  cp "$src" "$f"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$src" "$f"; then echo "  INERT     $1"; return 1; fi
  out=$(check "$hc" "$pa" "$ac" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  case "$out" in *"$4"*) ;; *) echo "  BROKEN    $1 -- it failed, but not with '$4' (rc=$rc)"; return 1 ;; esac
  echo "  convicted $1"
}
fails=0
mut "m1 body returns text for an empty list" hc 's/if \(labels == null \|\| labels\.isEmpty\(\)\) return null;/if (labels == null) return null;/' "FAIL c2" || fails=$((fails+1))
mut "m2 WHERE says your other phone" hc 's/WHERE = "your other device";/WHERE = "your other phone";/' "FAIL c5" || fails=$((fails+1))
mut "m3 body drops the last label" hc 's/i < labels\.size\(\);/i < labels.size() - 1;/' "FAIL c3" || fails=$((fails+1))
mut "m4 a null claims map reads as empty (the UNREADABLE branch removed)" pa 's/if \(elsewhere == null\) \{[^}]*\} else if \(elsewhere\.length > 0\)/if (elsewhere != null \&\& elsewhere.length > 0)/' "FAIL s2" || fails=$((fails+1))
mut "m5 claimsForScreen returns empty for an unreadable record" ac 's/return readClaims\(ctx\);/java.util.LinkedHashMap<String, String> m = readClaims(ctx);\n        return m == null ? new java.util.LinkedHashMap<String, String>() : m;/' "FAIL s4" || fails=$((fails+1))
mut "m6 the claims read moved after AppHeld.heldNow" pa 's/(\n[ \t]*try \{\s*java\.util\.LinkedHashMap<String, String> c = AppClaim\.claimsForScreen\(this\);.*?\n[ \t]*\}\n)([ \t]*held\.addAll\(AppHeld\.heldNow\(this\)\);\n)/\n$2$1/s' "FAIL s1" || fails=$((fails+1))
mut "m7 heading ignores the holder" hc 's/return "Held by " \+ where\(holder\);/return HEADING;/' "FAIL H1" || fails=$((fails+1))
mut "m8 body ignores the holder" hc 's/\.append\(where\(holder\)\)/.append(WHERE)/' "FAIL H2" || fails=$((fails+1))
mut "m9 showHeldApps draws HeldElsewhereCopy.HEADING again" pa 's/HeldElsewhereCopy\.heading\(g\.getKey\(\)\)/HeldElsewhereCopy.HEADING/' "FAIL s3" || fails=$((fails+1))
mut "m10 one group under WHERE instead of holdGroups" pa 's/AppClaim\.holdGroups\(java\.util\.Arrays\.asList\(elsewhere\), names, HeldElsewhereCopy\.WHERE\)/java.util.Collections.singletonMap(HeldElsewhereCopy.WHERE, java.util.Arrays.asList(elsewhere))/' "FAIL s5" || fails=$((fails+1))
mut "m11 namesForScreen returns an empty map" ac 's/return readClaimNames\(ctx\);/return new java.util.LinkedHashMap<String, String>();/' "FAIL s6" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
