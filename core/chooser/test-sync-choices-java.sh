#!/usr/bin/env bash
# test-sync-choices-java.sh [--mutate] -- the gate's "Back up my data" choices, run under javac (NWP-20261202-25).
#
# WHY THIS IS COMMITTED. DECIDED 2026-11-10 (docs/product-decisions.md, "the periodic save runs every 15 minutes by
# default, and its choices become 2, 5, 10, 15 and 30 minutes"). The gate's picker offered 30 seconds to 10 minutes
# with 2 minutes the default, although a save takes 3-10 minutes. SyncChoices.java holds the choices and is pure Java,
# so core/chooser/tests/sync-choices/run.sh compiles it (with ReplyCopy, whose prettyInterval the labels must match)
# and runs SyncChoicesCases. The PINS below check that the picker and Profile's fallback cadence read SyncChoices, and
# that the held-app messages say "about an hour" (claimTTL 60 minutes, DECIDED 2026-11-10).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK; the
# version is printed first so the log proves which compiler ran.
#
#   bash test-sync-choices-java.sh            # the cases and the pins
#   bash test-sync-choices-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
# One temp root: every mutant dir, and run.sh's own, is made inside it and goes with it on exit.
W=$(mktemp -d) || exit 2
export TMPDIR="$W"
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
DIR="$here/src/com/nowhere/chooser"
SC="$DIR/SyncChoices.java"
RCS="$DIR/ReplyCopy.java"
CH="$DIR/ChooserActivity.java"
PA="$DIR/ProfileActivity.java"
AC="$DIR/AppClaim.java"
HE="$DIR/HeldElsewhereCopy.java"
RUN="$here/tests/sync-choices/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: the pins need python3, and there is none" >&2; exit 2; }
for f in "$RCS" "$CH" "$PA" "$AC" "$HE" "$RUN"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }; done

# P1: showSyncIntervalPicker reads its choices from SyncChoices.
pin_picker() {
  local out
  out=$(python3 -I - "$1" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"private void showSyncIntervalPicker\(Runnable onChanged\) \{.*?\n    \}\n", src, re.S)
if not m:
    print("showSyncIntervalPicker not found"); sys.exit(1)
body = m.group(0)
for want in ("final int[] secs = SyncChoices.SECS;", "final String[] labels = SyncChoices.LABELS;"):
    if want not in body:
        print("the picker does not hold: " + want); sys.exit(1)
PY
) || { echo "  PIN   P1 $out" >&2; return 1; }
}

# P2: Profile's fallback cadence is SyncChoices.DEFAULT_SECS, twice, and never 120.
pin_fallback() {
  local out
  out=$(python3 -I - "$1" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
if re.search(r"syncSec = 120\b", src):
    print("ProfileActivity still falls back to syncSec = 120"); sys.exit(1)
n = len(re.findall(r"syncSec = SyncChoices\.DEFAULT_SECS;", src))
if n != 2:
    print("ProfileActivity holds syncSec = SyncChoices.DEFAULT_SECS %d times, not 2" % n); sys.exit(1)
PY
) || { echo "  PIN   P2 $out" >&2; return 1; }
}

# P3: a held-app message says "about an hour" (across string joins) and no "fifteen minutes".
pin_hour() {
  local out
  out=$(python3 -I - "$1" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
t = re.sub(r'"\s*\+\s*"|"\)\s*\.append\("', "", src)
if "about an hour after that device is switched off" not in t:
    print(sys.argv[1].rsplit("/", 1)[-1] + " does not say about an hour after that device is switched off"); sys.exit(1)
if "fifteen minutes" in src:
    print(sys.argv[1].rsplit("/", 1)[-1] + " still says fifteen minutes"); sys.exit(1)
PY
) || { echo "  PIN   P3 $out" >&2; return 1; }
}

# suite <SyncChoices> <ChooserActivity> <ProfileActivity> <AppClaim> <HeldElsewhereCopy>
#   -> 0 pass, 1 a case or a pin failed, 3 compile.
suite() {
  local sc="$1" ch="$2" pa="$3" ac="$4" he="$5" r
  pin_picker "$ch" || return 1
  pin_fallback "$pa" || return 1
  pin_hour "$ac" || return 1
  pin_hour "$he" || return 1
  [ -f "$sc" ] || { echo "  FAIL  SyncChoices.java does not exist" >&2; return 3; }
  bash "$RUN" "$sc" "$RCS"; r=$?
  return "$r"
}

echo "== $SC"
suite "$SC" "$CH" "$PA" "$AC" "$HE" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not apply or compile proves nothing)"
# mut <label> <which: sc|ch|pa|ac|he> <perl-expr> <the failure line that must convict it>
mut() {
  local d src m rc out scf chf paf acf hef
  d=$(mktemp -d -p "$W")
  scf="$SC"; chf="$CH"; paf="$PA"; acf="$AC"; hef="$HE"
  case "$2" in sc) src="$SC" ;; ch) src="$CH" ;; pa) src="$PA" ;; ac) src="$AC" ;; he) src="$HE" ;; esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in sc) scf="$m" ;; ch) chf="$m" ;; pa) paf="$m" ;; ac) acf="$m" ;; he) hef="$m" ;; esac
  out=$(suite "$scf" "$chf" "$paf" "$acf" "$hef" 2>&1); rc=$?
  rm -rf "$d"
  # Only a failing CASE ("--- FAIL <want>") or a failing PIN ("PIN   <want>") convicts; a compile error is broken.
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) case "$out" in
         *"$4"*) echo "  convicted $1 (by $4)"; return 0 ;;
         *) echo "  WRONG     $1 -- failed, but not on $4:"; printf '%s\n' "$out" | sed 's/^/      /'; return 1 ;;
       esac ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 SECS gets 30 back in first place"       sc 's/SECS = \{120, /SECS = {30, 120, /' "--- FAIL C1" || fails=$((fails+1))
mut "M2 (default) moved to the 2-minute label"  sc 's/"Every 2 minutes"/"Every 2 minutes (default)"/; s/"Every 15 minutes \(default\)"/"Every 15 minutes"/' "--- FAIL C3 the marked label" || fails=$((fails+1))
mut "M3 DEFAULT_SECS = 120"                     sc 's/DEFAULT_SECS = 900;/DEFAULT_SECS = 120;/' "--- FAIL C3 DEFAULT_SECS is 900" || fails=$((fails+1))
mut "M4 the picker keeps its old inline array"  ch 's/final int\[\] secs = SyncChoices\.SECS;/final int[] secs = {30, 60, 120, 300, 600};/' "PIN   P1" || fails=$((fails+1))
mut "M5 a Profile fallback back to 120"         pa 's/if \(syncSec <= 0\) syncSec = SyncChoices\.DEFAULT_SECS;/if (syncSec <= 0) syncSec = 120;/' "PIN   P2" || fails=$((fails+1))
mut "M6 AppClaim's message back to fifteen minutes" ac 's/or about an hour "/or about fifteen minutes "/' "PIN   P3" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
