#!/usr/bin/env bash
# test-tz-seed-java.sh [--mutate] -- the sign-in's automatic time-zone seed, run under javac (NWP-20261102-07).
#
# WHY THIS IS COMMITTED. Q148 (docs/product-decisions.md, 2026-10-20) stopped every sign-in with no time zone set from
# telling a third party the phone's public IP: the AUTOMATIC seed is the profile's own last zone (`lasttz=` in
# GET-PREFS) when the platform knows it, else the baked default, and auto-detection stays ON after it (a seed, never an
# override: DIA-58). TzSeed holds the choice (pure, java.lang/java.util only) and is compiled here with its cases; a
# source check pins the wiring (applyRoamedPrefs seeds through TzSeed and then re-enables auto-detection, the zone is
# never logged) and that no chooser or agent source asks the IP time-zone service again.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-tz-seed-java.sh            # the cases and the source check
#   bash test-tz-seed-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="${TZ_SEED_SRC:-$SRC/TzSeed.java}"
CHOOSER="$SRC/ChooserActivity.java"
AGENT="$root/core/agent"
CASES="$root/core/chooser/tests/tz-seed/TzSeedCases.java"
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
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# suite <TzSeed.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  TzSeed.java does not exist (the seed choice is not lifted)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/TzSeed.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/TzSeedCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.TzSeedCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# source_check <ChooserActivity.java> <chooser-src-dir> <agent-dir> -> 0 when the wiring holds, 1 otherwise.
source_check() {
  local chooser="$1" csrc="$2" agent="$3" hits body n pick_n on_n bad=0
  hits=$(grep -rn -e 'RESOLVE-IP-TZ' -e 'ipinfo' "$csrc" || true)
  [ -z "$hits" ] || { echo "  FAIL  the chooser still names the IP time-zone lookup:" >&2; echo "$hits" >&2; bad=1; }
  hits=$(find "$agent" -name '*.go' ! -name '*_test.go' -exec grep -Hn -e 'RESOLVE-IP-TZ' -e 'ipinfo' {} + || true)
  [ -z "$hits" ] || { echo "  FAIL  the agent still names the IP time-zone lookup:" >&2; echo "$hits" >&2; bad=1; }

  body=$(awk '/private void applyRoamedPrefs\(\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$chooser")
  if [ -z "$body" ]; then echo "  FAIL  applyRoamedPrefs not found in $chooser" >&2; return 1; fi
  n=$(printf '%s\n' "$body" | grep -cF 'TzSeed.pick(lastTz, "America/New_York", this::isKnownZone)')
  [ "$n" -eq 1 ] || { echo "  FAIL  applyRoamedPrefs seeds through TzSeed.pick $n times, want 1" >&2; bad=1; }
  pick_n=$(printf '%s\n' "$body" | awk '/TzSeed\.pick\(lastTz, "America\/New_York", this::isKnownZone\)/ { print NR; exit }')
  on_n=$(printf '%s\n' "$body" | awk -v p="${pick_n:-0}" 'p > 0 && NR > p && /dpm\.setAutoTimeZoneEnabled\(admin, true\);/ { print NR; exit }')
  case "$pick_n" in ''|*[!0-9]*) pick_n="" ;; esac
  case "$on_n" in ''|*[!0-9]*) on_n="" ;; esac
  if [ -z "$pick_n" ] || [ -z "$on_n" ]; then
    echo "  FAIL  auto-detection is not turned back on after the seed is applied" >&2; bad=1
  fi
  n=$(printf '%s\n' "$body" | grep -cF 'l.startsWith("lasttz=")')
  [ "$n" -ge 1 ] || { echo "  FAIL  applyRoamedPrefs does not parse lasttz=" >&2; bad=1; }
  hits=$(printf '%s\n' "$body" | grep -E 'Log\.[a-z]\(.*(lastTz|seed)\b' || true)
  [ -z "$hits" ] || { echo "  FAIL  a log line carries the zone:" >&2; echo "$hits" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | grep -cF 'TextUtils.join("|", lines)')
  [ "$n" -eq 0 ] || { echo "  FAIL  the raw GET-PREFS dump (lasttz= included) is logged" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
source_check "$CHOOSER" "$SRC" "$AGENT" || { echo "FAILED (source)"; exit 1; }
echo "source: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates TzSeed.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/TzSeed.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutsrc() { # mutsrc <label> <perl-expr>   (mutates ChooserActivity.java; the source check must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$CHOOSER" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$CHOOSER" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  source_check "$c" "$d" "$AGENT" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "Z1 pick ignores the last zone" 's/return lastTz;/return baked;/' || fails=$((fails+1))
mut "Z2 pick skips the known check" 's/ && known\.test\(lastTz\)//' || fails=$((fails+1))
mutsrc "Z3 auto-detection left off after seeding" 's/dpm\.setAutoTimeZoneEnabled\(admin, true\);//' || fails=$((fails+1))
mutsrc "Z4 the IP lookup send restored" 's/(String source = )/sendDaemonLines("RESOLVE-IP-TZ\\n");\n                $1/' || fails=$((fails+1))
mutsrc "Z5 the zone logged" 's/\(seeded " \+ source/(seeded " + seed/' || fails=$((fails+1))
mut "Z6 the null guard dropped" 's/lastTz != null && !lastTz\.isEmpty\(\) && //' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
