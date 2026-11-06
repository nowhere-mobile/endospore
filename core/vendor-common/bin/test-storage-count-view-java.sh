#!/usr/bin/env bash
# test-storage-count-view-java.sh [--mutate] -- NWP-20261120-09: "What's using space" shows the session's kept storage
# count with its age and replaces it when the fresh count lands (h48 #6, docs/product-decisions.md, DECIDED
# 2026-10-30). Before this, ProfileActivity.showStorageBreakdown sent only GET-STORAGE-BREAKDOWN and showed nothing
# until a whole new walk answered, so on a full phone the screen read "Calculating…" for minutes on every open, though
# the session already held a count (core/agent/storage_count.go).
#
# Runs core/chooser/tests/storage-count-view: the chooser's pure StorageCountView (the CACHED header parse, the age
# line, the next-step rule), compiled against its cases ALONE and EXECUTED. Then source pins on ProfileActivity.java,
# comment lines stripped:
#   P1 showStorageBreakdown sends STORAGE-COUNT-START exactly once
#   P2 the poll (showKeptStorageCount) reads only GET-STORAGE-BREAKDOWN-CACHED, sleeps between reads, checks
#      root.getParent() and never sends STORAGE-COUNT-START or GET-STORAGE-BREAKDOWN
#   P3 getStorageBreakdownCached reads the CACHED verb through daemonLenReply with a literal
#   P4 the worker falls back to getStorageBreakdown() (the LEGACY branch) only after the poll declines
#   P5 the screen decides through StorageCountView (parse, next, ageLine)
#   P6 the success render hides the unreadable-path warning when this count has none (it can now run twice)
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies of StorageCountView.java and ProfileActivity.java, each of which
# must FAIL a named case or pin. A mutant that does not apply (INERT) or does not compile (BROKEN) is a failure.
#
# PROFILE_ACTIVITY=<file> and STORAGE_COUNT_VIEW=<file> point the suite at other copies (to show it fails on a tree
# without this change).
#
#   bash test-storage-count-view-java.sh            # the cases and pins
#   bash test-storage-count-view-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-storage-count-view-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
# ONE temp root: every class dir and mutant tree lives under it, and the EXIT trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -J-Djava.io.tmpdir="$W" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
PA=${PROFILE_ACTIVITY:-$ROOT/$CH/ProfileActivity.java}
VIEW=${STORAGE_COUNT_VIEW:-$ROOT/$CH/StorageCountView.java}
# The cases compile from <root>/$CH; a tree of its own under $W holds the view under test.
VROOT=$(mktemp -d -p "$W")
mkdir -p "$VROOT/$CH"
[ -f "$VIEW" ] && cp "$VIEW" "$VROOT/$CH/StorageCountView.java"
mkdir -p "$VROOT/core/chooser/tests"
cp -r "$ROOT/core/chooser/tests/storage-count-view" "$VROOT/core/chooser/tests/"

run() { # run <root>: compile and execute the cases
  JAVAC=$JAVAC JAVA=$JAVA bash "$1/core/chooser/tests/storage-count-view/run.sh" "$1" "$(mktemp -d -p "$W")"
}

# body <file> <method>: the method's lines, from its signature to the first line that closes it at class depth.
body() { awk -v n="$2" '$0 ~ "^    private [^=]*[ ]" n "\\(" {f=1} f{print} f&&/^    }$/{exit}' "$1"; }
# nocomment: drop comment lines and trailing " // ..." comments, so a pin never matches prose.
nocomment() { sed -E -e '/^[[:space:]]*(\/\/|\*|\/\*)/d' -e 's/[[:space:]]+\/\/[[:space:]].*$//'; }
count() { local n; n=$(grep -o -F -- "$1" <<<"$2" | wc -l); echo $((n)); }

pins() { # pins <ProfileActivity.java>: prints "PIN <id> <what>" for each failure; returns 1 on any
  local f=$1 bad=0 sb kp gc sa rr w ws wl
  sb=$(body "$f" showStorageBreakdown | nocomment)
  kp=$(body "$f" showKeptStorageCount | nocomment)
  gc=$(body "$f" getStorageBreakdownCached | nocomment)
  sa=$(body "$f" showStorageAge | nocomment)
  rr=$(body "$f" renderStorageReply | nocomment)
  if [ "$(count '"STORAGE-COUNT-START\n"' "$sb")" -ne 1 ]; then
    echo "PIN P1 showStorageBreakdown must send STORAGE-COUNT-START exactly once"; bad=1
  fi
  if [ -z "$kp" ] || [ "$(count 'STORAGE-COUNT-START' "$kp")" -ne 0 ] || [ "$(count 'getStorageBreakdown()' "$kp")" -ne 0 ] \
     || [ "$(count 'GET-STORAGE-BREAKDOWN' "$kp")" -ne 0 ] || [ "$(count 'sendDaemon' "$kp")" -ne 0 ] \
     || [ "$(count 'getStorageBreakdownCached()' "$kp")" -lt 1 ] || [ "$(count 'Thread.sleep(STORAGE_POLL_MS)' "$kp")" -lt 1 ]; then
    echo "PIN P2 the poll must read only GET-STORAGE-BREAKDOWN-CACHED, sleep between reads, and send nothing"; bad=1
  fi
  wl=$(grep -E '^[[:space:]]*while[[:space:]]*\(' <<<"$kp")
  if [ "$(count 'while (v.root.getParent() != null)' "$wl")" -ne 1 ] || [ "$(grep -c . <<<"$wl")" -ne 1 ]; then
    echo "PIN P2 the poll loop must run only while v.root.getParent() != null"; bad=1
  fi
  if [ "$(count 'daemonLenReply("GET-STORAGE-BREAKDOWN-CACHED\n", STORAGE_CACHED_CAP_MS)' "$gc")" -ne 1 ]; then
    echo "PIN P3 getStorageBreakdownCached must read GET-STORAGE-BREAKDOWN-CACHED through daemonLenReply"; bad=1
  fi
  # The breakdown worker: the third thread of showStorageBreakdown, from the StorageScreen it builds.
  w=$(awk '/new StorageScreen\(/{f=1} f{print} f&&/^        }\)\.start\(\);$/{exit}' <<<"$sb")
  ws=$(tr '\n' ' ' <<<"$w")
  if [ "$(count 'getStorageBreakdown()' "$w")" -ne 1 ] \
     || ! [[ $ws =~ sendDaemon\(\"STORAGE-COUNT-START\\n\"\)\;[[:space:]]*if\ \(showKeptStorageCount\(v\)\)\ return\;[[:space:]]*final\ String\[\]\ reply\ =\ getStorageBreakdown\(\)\; ]]; then
    echo "PIN P4 the worker must start the count, poll, and only then fall back to getStorageBreakdown()"; bad=1
  fi
  if [ "$(count 'StorageCountView.ageLine(' "$sa")" -ne 1 ] || [ "$(count 'StorageCountView.parse(' "$kp")" -ne 1 ] \
     || [ "$(count 'StorageCountView.next(' "$kp")" -lt 1 ]; then
    echo "PIN P5 the screen must decide through StorageCountView.parse/next/ageLine"; bad=1
  fi
  # P6: in the success branch, the line after the VISIBLE call is "} else {" and the next one hides blindLine.
  if [ "$(count 'v.blindLine.setVisibility(android.view.View.GONE);' "$rr")" -ne 1 ] \
     || ! awk '
          /if \(si\.blind > 0\) \{/ {b=1; next}
          b==1 && /v\.blindLine\.setVisibility\(android\.view\.View\.VISIBLE\);/ {b=2; next}
          b==2 { if ($0 ~ /^[[:space:]]*\} else \{$/) {b=3; next} else exit 1 }
          b==3 { if ($0 ~ /^[[:space:]]*v\.blindLine\.setVisibility\(android\.view\.View\.GONE\);$/) {ok=1} exit }
          END {exit ok ? 0 : 1}' <<<"$rr"; then
    echo "PIN P6 the success branch does not hide blindLine when si.blind == 0"; bad=1
  fi
  return $bad
}

suite() { # suite <view root> <ProfileActivity.java>: the cases, then the pins
  local out rc
  out=$(run "$1" 2>&1); rc=$?
  echo "$out"
  [ -f "$2" ] || { echo "PIN P0 no ProfileActivity at $2"; return 1; }
  pins "$2" || rc=1
  return $rc
}

suite "$VROOT" "$PA" || { echo "FAILED"; exit 1; }
echo "all cases and pins passed"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <view|pa> <perl-expr> <case label or PIN id the mutant must fail>
  local d f src out rc pa
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  mkdir -p "$d/core/chooser/tests"
  cp -r "$VROOT/core/chooser/tests/storage-count-view" "$d/core/chooser/tests/"
  cp "$VROOT/$CH/StorageCountView.java" "$d/$CH/StorageCountView.java"
  cp "$PA" "$d/ProfileActivity.java"
  pa="$d/ProfileActivity.java"
  if [ "$2" = view ]; then f="$d/$CH/StorageCountView.java"; src="$VROOT/$CH/StorageCountView.java"
  else f=$pa; src=$PA; fi
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$src" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  out=$(suite "$d" "$pa" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if grep -qF -- "error:" <<<"$out"; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "$4" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not '$4' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
mut "M1 ageLine drops ' · counting again…' while running" view \
  's/return running \? s \+ " · counting again…" : s;/return s;/' \
  "FAIL age 720 running (the decision's example)" || fails=$((fails+1))
mut "M2 minutes rounded up" view 's/\(d \/ 60\)/((d + 59) \/ 60)/' \
  "FAIL age 719:" || fails=$((fails+1))
mut "M3 next() renders an OK not newer than shown" view \
  's/c\.countedAtSec > shownCountedAtSec/c.countedAtSec >= shownCountedAtSec/' \
  "FAIL next OK not newer idle is DONE" || fails=$((fails+1))
mut "M4 next() reads PENDING idle none as FAILED" view \
  's/^[ \t]*if \(c\.kind == PENDING && "none"\.equals\(c\.lastErr\)\) return LEGACY;[^\n]*\n//m' \
  "FAIL next PENDING idle none is LEGACY" || fails=$((fails+1))
mut "M5 next() reads PENDING idle none as WAIT" view \
  's/("none"\.equals\(c\.lastErr\)\)) return LEGACY;/$1 return WAIT;/' \
  "FAIL next PENDING idle none is LEGACY" || fails=$((fails+1))
mut "M6 next() reads UNKNOWN as NO_SESSION" view \
  's/(c\.kind == UNKNOWN\)) return LEGACY;/$1 return NO_SESSION;/' \
  "FAIL next UNKNOWN is LEGACY" || fails=$((fails+1))
mut "M7 the poll sends STORAGE-COUNT-START" pa \
  's/(\n([ \t]*)final String\[\] r = getStorageBreakdownCached\(\);)/\n$2sendDaemon("STORAGE-COUNT-START\x5cn");$1/' \
  "PIN P2" || fails=$((fails+1))
mut "M8 the root.getParent() check removed from the poll" pa \
  's/while \(v\.root\.getParent\(\) != null\) \{/while (true) {/' \
  "PIN P2" || fails=$((fails+1))
mut "M9 the success render keeps a stale unreadable-path warning" pa \
  's/^[ \t]*v\.blindLine\.setVisibility\(android\.view\.View\.GONE\);\n//m' \
  "PIN P6" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
