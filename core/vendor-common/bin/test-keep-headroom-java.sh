#!/usr/bin/env bash
# test-keep-headroom-java.sh [--mutate] -- turning on Keep counts the app's own size (Q025 [BA], NWP-20261104-07).
#
# WHY THIS IS COMMITTED. setAppMode asked only overPlan() (GET-ENTITLEMENT, true only when used > covered), so a profile
# just under its plan could keep a large app. KeepHeadroom.java is the pure codec of the daemon's KEEP-HEADROOM verb, run
# under javac by tests/keep-headroom/run.sh; the PINS below read ProfileActivity.java (comments stripped) as data: the ask
# is overPlan(pkg, mode), every branch without a verdict returns overPlan(), and appMode(pkg) is read before measuring.
# The chooser cannot be compiled off the build host, so the overload is pinned by source.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS.
#
#   bash test-keep-headroom-java.sh            # the cases and the pins
#   bash test-keep-headroom-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
KH="$DIR/KeepHeadroom.java"
PA="$DIR/ProfileActivity.java"
RUN="$root/core/chooser/tests/keep-headroom/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl" >&2; exit 2; }
export JAVAC JAVA TMPDIR="$W"
"$JAVAC" -J-Djava.io.tmpdir="$W" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$PA" ] && [ -f "$RUN" ] || { echo "FAIL: missing $PA or $RUN" >&2; exit 2; }

# strip <in> <out>: drop // and /* */ comments outside string and char literals.
strip() {
  perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : ""}gse' "$1" > "$2"
}

# pin <file> <label> <perl-regex>
pin() {
  perl -0ne "exit(/$3/s ? 0 : 1)" "$1" || { echo "  PIN   $2" >&2; return 1; }
}

# suite <KeepHeadroom.java> <ProfileActivity.java> -> 0 pass, 1 a case or a pin failed, 3 compile.
suite() {
  local kh="$1" pa="$2" s body
  [ -f "$kh" ] || { echo "  PIN   KeepHeadroom.java does not exist" >&2; return 1; }
  s=$(mktemp -p "$W") || return 1
  strip "$pa" "$s"
  # CONTROL: must match, or the stripper or the anchors see nothing.
  pin "$s" "control: setAppModeLocked no longer holds the synchronized (StoreInstaller.APPKEEP_LOCK) line" \
    'setAppModeLocked\(String pkg, String mode, Boolean overPlanNow\) \{.*?synchronized \(StoreInstaller\.APPKEEP_LOCK\)' || return 1
  pin "$s" "setAppMode does not ask overPlanNow = overPlan(pkg, mode);" \
    'private java\.util\.Set<String> setAppMode\(String pkg, String mode\) \{(?:(?!private ).)*?overPlanNow = overPlan\(pkg, mode\);' || return 1
  if perl -0ne 'exit(/private java\.util\.Set<String> setAppMode\(String pkg, String mode\) \{(?:(?!private ).)*?overPlan\(\)/s ? 0 : 1)' "$s"; then
    echo "  PIN   setAppMode still asks the bare overPlan()" >&2; return 1
  fi
  pin "$s" "the overload private boolean overPlan(String pkg, String mode) is missing" \
    'private boolean overPlan\(String pkg, String mode\) \{' || return 1
  body=$(mktemp -p "$W") || return 1
  perl -0ne 'print $1 if /private boolean overPlan\(String pkg, String mode\) \{(.*?)\n    \}\n/s' "$s" > "$body"
  [ -s "$body" ] || { echo "  PIN   cannot cut the overload body" >&2; return 1; }
  # every return is `return overPlan();` or the verdict itself, and the four no-verdict branches fall back.
  if grep -o 'return [^;]*;' "$body" | grep -vx 'return overPlan();\|return v;' >/dev/null; then
    echo "  PIN   the overload returns something other than overPlan() or the verdict" >&2; return 1
  fi
  [ "$(grep -c 'return overPlan();' "$body")" -ge 5 ] || { echo "  PIN   a no-verdict branch of the overload does not return overPlan()" >&2; return 1; }
  pin "$body" "the null-verdict branch does not return overPlan()" \
    'Boolean v = KeepHeadroom\.verdict\(r\.text\);\s*if \(v == null\) \{(?:(?!\}).)*?return overPlan\(\);\s*\}\s*return v;' || return 1
  pin "$body" "the failed-reply branch does not return overPlan()" \
    'if \(r\.failed\(\)\) \{(?:(?!\}).)*?return overPlan\(\);\s*\}' || return 1
  pin "$body" "the unmeasurable-size branch does not return overPlan()" \
    'if \(req == null\) \{(?:(?!\}).)*?return overPlan\(\);\s*\}' || return 1
  pin "$body" "the non-keep-mode branch does not log its reason and return overPlan()" \
    'if \(mode == null \|\| mode\.isEmpty\(\) \|\| "off"\.equals\(mode\)\) \{\s*android\.util\.Log\.w\("NowhereChooser", "keep headroom: not a keep add[^"]*"\);\s*return overPlan\(\);\s*\}' || return 1
  pin "$body" "the already-kept branch does not log its reason and return overPlan()" \
    'if \(appMode\(pkg\) != null\) \{\s*android\.util\.Log\.w\("NowhereChooser", "keep headroom: already kept[^"]*"\);\s*return overPlan\(\);\s*\}' || return 1
  pin "$body" "appMode(pkg) is not read before the size is measured and the daemon asked" \
    'if \(appMode\(pkg\) != null\) \{.*?keepApkBytes\(pkg\).*?sendDaemonReply\(' || return 1
  pin "$body" "the ask is not sendDaemonReply(\"KEEP-HEADROOM\\n\" + req + \"\\n\") with req from KeepHeadroom.request" \
    'String req = KeepHeadroom\.request\(pkg, keepApkBytes\(pkg\)\);.*?sendDaemonReply\("KEEP-HEADROOM\\n" \+ req \+ "\\n"\)' || return 1
  bash "$RUN" "$kh"
}

echo "== $KH"
suite "$KH" "$PA" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not apply or compile proves nothing)"
# mut <label> <which: kh|pa> <perl-expr>
mut() {
  local d src m khf paf rc
  d=$(mktemp -d -p "$W")
  khf="$KH"; paf="$PA"
  case "$2" in kh) src="$KH" ;; pa) src="$PA" ;; esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  case "$2" in kh) khf="$m" ;; pa) paf="$m" ;; esac
  suite "$khf" "$paf" >"$d/out" 2>&1; rc=$?
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 verdict maps ERR-OVERPLAN to FALSE"       kh 's/(startsWith\("ERR-OVERPLAN "\)\) return )Boolean\.TRUE/$1Boolean.FALSE/' || fails=$((fails+1))
mut "M2 a null verdict is read as fits"           pa 's/(Boolean v = KeepHeadroom\.verdict\(r\.text\);\n\s*)if \(v == null\) \{/$1if (v == null) { return false; }\n        if (false) {/' || fails=$((fails+1))
mut "M3 the already-kept check dropped"          pa 's/\n\s*if \(appMode\(pkg\) != null\) \{[^\n]*\n[^\n]*\n[^\n]*\n\s*\}//' || fails=$((fails+1))
mut "M6 the already-kept fallback logs nothing"  pa 's/\n[^\n]*keep headroom: already kept[^\n]*//' || fails=$((fails+1))
mut "M7 the non-keep fallback logs nothing"      pa 's/\n[^\n]*keep headroom: not a keep add[^\n]*//' || fails=$((fails+1))
mut "M4 setAppMode back to overPlan()"           pa 's/overPlanNow = overPlan\(pkg, mode\);/overPlanNow = overPlan();/' || fails=$((fails+1))
mut "M5 request accepts a negative size"         kh 's/ \|\| bytes < 0//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
