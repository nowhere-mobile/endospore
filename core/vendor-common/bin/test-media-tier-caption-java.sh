#!/usr/bin/env bash
# test-media-tier-caption-java.sh [--mutate] -- NWP-20261105-10: each Offline media row captions its tier control
# "Maps & files" (docs/product-decisions.md, 2026-10-20, Q074). The words Essential / Auto / On-demand stay; the caption
# says the control sets the app's maps & files, not the app's own keep mode. Runs core/chooser/tests/media-tier-caption
# (MediaTierCopy compiled and EXECUTED) and source pins on ProfileActivity: P1 mediaAppRow adds a caption TextView holding
# MediaTierCopy.CAPTION to `col` before the control, P2 segmentedTier reads MediaTierCopy.labels(), P3 segmentedTier
# holds no string literal, P4 the control's content description is the caption.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies, each of which must FAIL: a mutant that does not apply (INERT) or
# does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-media-tier-caption-java.sh            # the cases and pins
#   bash test-media-tier-caption-java.sh --mutate   # ... plus the mutants
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
  echo "test-media-tier-caption-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -J-Djava.io.tmpdir="$W" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
MC="$ROOT/core/chooser/src/com/nowhere/chooser/MediaTierCopy.java"
PA="$ROOT/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
[ -f "$MC" ] || { echo "FAIL: $MC does not exist"; exit 1; }
[ -f "$PA" ] || { echo "FAIL: $PA does not exist"; exit 1; }

# body <file> <signature>: the member from its signature line to its closing brace at the same indent.
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on = 1; match($0, /^ */); ind = RLENGTH }
    on { print; if ($0 ~ "^ {" ind "}\\}") exit }
  ' "$1"
}

# check <MediaTierCopy.java> <ProfileActivity.java>: the cases, then pins P1-P4. rc 1 = convicted, 2 = no such member.
check() {
  local mc=$1 pa=$2 b t rc
  JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/media-tier-caption/run.sh" "$mc"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  b=$(body "$pa" 'private View mediaAppRow(')
  [ -n "$b" ] || { echo "FAIL: no mediaAppRow"; return 2; }
  t=$(body "$pa" 'private View segmentedTier(')
  [ -n "$t" ] || { echo "FAIL: no segmentedTier"; return 2; }
  # (P1) a TextView whose text is the caption is added to col before the control
  if ! B=$b perl -0e 'exit(($ENV{B} =~ /(\w+)\.setText\(MediaTierCopy\.CAPTION\);.*?\bcol\.addView\(\1,.*?col\.addView\(seg, slp\)/s) ? 0 : 1)'; then
    echo "FAIL P1: mediaAppRow does not add a MediaTierCopy.CAPTION TextView to col before the control"; return 1
  fi
  # (P4) TalkBack reads the same words
  [[ "$b" == *'seg.setContentDescription(MediaTierCopy.CAPTION);'* ]] || { echo "FAIL P4: the control's content description is not the caption"; return 1; }
  # (P2) the words come from MediaTierCopy
  [[ "$t" == *'segmented(MediaTierCopy.labels(),'* ]] || { echo "FAIL P2: segmentedTier does not call segmented(MediaTierCopy.labels(),"; return 1; }
  # (P3) no literal word array left behind
  [[ "$t" != *'"'* ]] || { echo "FAIL P3: segmentedTier holds a string literal"; return 1; }
  echo "  ok   pins P1 P2 P3 P4"
}
check "$MC" "$PA" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <mc|pa> <perl-expr>
  local d f mc pa out rc
  d=$(mktemp -d -p "$W"); mc=$MC; pa=$PA
  if [ "$2" = mc ]; then f="$d/MediaTierCopy.java"; cp "$MC" "$f"; else f="$d/ProfileActivity.java"; cp "$PA" "$f"; fi
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if [ "$2" = mc ]; then if cmp -s "$MC" "$f"; then echo "  INERT     $1"; return 1; fi; mc=$f
  else if cmp -s "$PA" "$f"; then echo "  INERT     $1"; return 1; fi; pa=$f; fi
  out=$(check "$mc" "$pa" 2>&1); rc=$?
  if [ "$rc" -ne 1 ]; then
    if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; else echo "  BROKEN    $1 (rc=$rc)"; fi
    return 1
  fi
  echo "  convicted $1"
}
fails=0
mut "M1 the caption reads Maps and files" mc 's/"Maps & files"/"Maps and files"/' || fails=$((fails+1))
mut "M2 the caption's addView removed" pa 's/\n[ \t]*col\.addView\(cap, clp\);//' || fails=$((fails+1))
mut "M3 the caption added after the control" pa 's/(\n[ \t]*col\.addView\(cap, clp\);)(.*?\n[ \t]*col\.addView\(seg, slp\);)/$2$1/s' || fails=$((fails+1))
mut "M4 On-demand renamed Streamed" mc 's/"On-demand"/"Streamed"/' || fails=$((fails+1))
mut "M5 segmentedTier back to a literal array" pa 's/segmented\(MediaTierCopy\.labels\(\), selected, onSelect\)/segmented(new String[]{"Essential", "Auto", "On-demand"}, selected, onSelect)/' || fails=$((fails+1))
mut "M6 labels() returns the field itself" mc 's/return LABELS\.clone\(\);/return LABELS;/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
