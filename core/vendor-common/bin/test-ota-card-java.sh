#!/usr/bin/env bash
# test-ota-card-java.sh [--mutate] -- the Software update card around a tap on Install update, run under javac
# (NWP-20261206-19).
#
# WHY THIS IS COMMITTED. A tap on Install update dropped OTA-APPLY's answer and rendered the next OTA-STATUS at once.
# In the first seconds of an apply that read can be a cached AVAIL, an empty reply or FAILED ERR-STALE, and each one
# re-offered Install update while otad was applying; a second tap during the cold-lock read could also start a second
# request (backlog: "The Update card shows Install update again while an update is installing, and lets it be tapped
# again"). When Install shows, which OTA-APPLY replies started an install, and how long the card keeps "Starting
# update…" live in core/chooser/src/com/nowhere/chooser/OtaCard.java. core/chooser/tests/ota-card/run.sh compiles that
# file as it stands, with OtaCardCases.
#
# THE CALL SITES ARE PINNED (a correct helper called wrongly is the same bug): the Install listener disables the button
# before its thread and re-enables it before the parked-session confirm; startInstall keeps OTA-APPLY's reply and asks
# OtaCard.holdStarting before doCheck; renderOtaStatus shows and enables Install through OtaCard.installShown.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (the missing-gofmt rc-127 false green, nowhere-phone/worklog.md).
# javac comes from PATH, else from the build host's JDK below; the CI runner is the build VM, which has it.
#
#   bash test-ota-card-java.sh            # the cases + the pins
#   bash test-ota-card-java.sh --mutate   # ... plus broken copies that must each FAIL their named case
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

# One root for every temp this suite makes (mut's copies, run.sh's build dir): nothing is left in $TMPDIR.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
SRC="$DIR/OtaCard.java"
CHO="$DIR/ChooserActivity.java"
RUN="$root/core/chooser/tests/ota-card/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 1
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 1; }
for f in "$SRC" "$CHO" "$RUN"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }; done

# run <OtaCard> <ChooserActivity> -> 0 pass; 1 a case or a pin failed; 3 the class or the cases did not compile.
run() { bash "$RUN" "$1" "$2"; }

echo "== $SRC (+ pins in $(basename "$CHO"))"
run "$SRC" "$CHO" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its named case; a mutant that does not apply or compile proves nothing)"
# mut <label> <which: O|C> <perl-expr> <case the mutant must fail>
mut() {
  local d t m o="$SRC" c="$CHO" out rc
  d=$(mktemp -d -p "$W")
  case "$2" in O) t="$SRC" ;; C) t="$CHO" ;; *) echo "  ERROR     $1 -- unknown file $2"; return 1 ;; esac
  m="$d/$(basename "$t")"
  if ! perl -0pe "$3" "$t" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; return 1; fi
  if cmp -s "$t" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  case "$2" in O) o="$m" ;; C) c="$m" ;; esac
  out=$(run "$o" "$c" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the case '$4' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
mut "C1 HOLD_MS is 0" O 's/static final long HOLD_MS = 60000;/static final long HOLD_MS = 0;/' \
  "hold: OK over AVAIL at 0" || fails=$((fails+1))
mut "C2 the ERR-STALE arm removed" O 's/return "FAILED ERR-STALE"\.equals\(s\);/return false;/' \
  "hold: OK over FAILED ERR-STALE" || fails=$((fails+1))
mut "C3 any FAILED holds" O 's/return "FAILED ERR-STALE"\.equals\(s\);/return s.startsWith("FAILED");/' \
  "hold: FAILED ERR-APPLY ends it" || fails=$((fails+1))
mut "C4 applyStarted accepts any reply" O 's/if \(reply == null\) return false;/if (true) return true;/' \
  "applyStarted: empty" || fails=$((fails+1))
mut "C5 installShown also true for DOWNLOADING" O 's/return "AVAIL"\.equals\(head\) \|\| "FAILED"\.equals\(head\);/return "AVAIL".equals(head) || "FAILED".equals(head) || "DOWNLOADING".equals(head);/' \
  "installShown: DOWNLOADING" || fails=$((fails+1))
mut "C6 the listener does not disable Install" C 's/(install\.setOnClickListener\(v -> \{\n)            install\.setEnabled\(false\);\n/$1/' \
  "pin: the listener disables Install before its thread" || fails=$((fails+1))
mut "C7 startInstall calls doCheck without the hold loop" C 's/                for \(;;\) \{\n                    String\[\] rp = otaStatusAndProg\(\);\n.*?\n                \}\n(                doCheck\.run\(\);)/$1/s' \
  "pin: startInstall holds before doCheck" || fails=$((fails+1))
mut "C8 renderOtaStatus back to the inline AVAIL/FAILED test" C 's/install\.setVisibility\(OtaCard\.installShown\(head\) \?/install.setVisibility("AVAIL".equals(head) || "FAILED".equals(head) ?/' \
  "pin: renderOtaStatus asks OtaCard.installShown" || fails=$((fails+1))
mut "C9 a shown Install stays disabled" C 's/\n        if \(OtaCard\.installShown\(head\)\) install\.setEnabled\(true\);[^\n]*//' \
  "pin: a shown Install is enabled" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
