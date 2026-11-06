#!/usr/bin/env bash
# test-seal-progress-java.sh [--mutate] [ProfileActivity.java main.go] -- NWP-20261108-23: the Profile screen's
# seal-progress and partial-save readers (partialOf, partialMessage, partialWhat, sealPhase, sealBytes, sealScope,
# sealScopeLabel, sealScopeIndex, fmtBytes, sealPct) turn the agent's "SEALING <phase> <done> <total>[ <scope>]" frames
# and "DONE PARTIAL:<list>" into the sign-out screen, the Back up now line and the five-segment bar: the screen whose job
# is saying whether it is safe to power off. Eight of them ran under no test (fmtBytes was already run on every boundary
# by core/chooser/test-plan-gate-fmt.sh, and sealScopeLabel was run, through refusalScopeLabel, by tests/end-unsaved).
# This lifts the ten out of ProfileActivity.java into one class (the awk of tests/end-unsaved/run.sh), compiles it with
# core/chooser/tests/seal-progress/SealProgressCases ALONE, and runs it. Two cross-side checks pin the agent's half in
# core/agent/main.go:
#   (a) every `return "X"` of progScopeOf gets a sealScopeLabel other than "your data", and the five logoff legs (vault,
#       de, media, sys, apps) map to the bar's segments 0-4 under `static final int SEGS = 5;`;
#   (b) writeProg still frames "%s %d %d" with the scope appended LAST, and composeSealStatus still prefixes "SEALING ".
# A new scope token or a reordered frame fails by name.
#
# It needs a JDK, and it FAILS when there is none (never a skip). javac/java come from PATH, then the build VM's JDK.
# --mutate re-runs the suite against broken copies (S1-S11, X1), each of which must FAIL; a mutant that does not apply
# (INERT) or does not build (BROKEN) counts as a failure, never a pass.
#
#   bash test-seal-progress-java.sh                            # the cases and pins
#   bash test-seal-progress-java.sh --mutate                   # ... plus the mutants
#   bash test-seal-progress-java.sh <ProfileActivity.java> <main.go>   # against other copies
set -uo pipefail
MUTATE=no; args=()
for a in "$@"; do
  case "$a" in
    --mutate) MUTATE=yes ;;
    -*) echo "usage: $0 [--mutate] [ProfileActivity.java main.go]" >&2; exit 2 ;;
    *) args+=("$a") ;;
  esac
done
[ "${#args[@]}" = 0 ] || [ "${#args[@]}" = 2 ] || { echo "usage: $0 [--mutate] [ProfileActivity.java main.go]" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
PA=${args[0]:-$ROOT/core/chooser/src/com/nowhere/chooser/ProfileActivity.java}
GO=${args[1]:-$ROOT/core/agent/main.go}
CASES=$ROOT/core/chooser/tests/seal-progress/SealProgressCases.java
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-seal-progress-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 1
fi
"$JAVAC" -J-Djava.io.tmpdir="$W" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
for f in "$PA" "$GO" "$CASES"; do [ -f "$f" ] || { echo "FAIL: $f does not exist"; exit 1; }; done
HELPERS="partialOf partialMessage partialWhat sealPhase sealBytes sealScope sealScopeLabel sealScopeIndex fmtBytes sealPct"

# lift <ProfileActivity.java>: the helpers, signature line to closing brace, as one class.
lift() {
  local src="$1" m
  echo "final class SealLifted {"
  for m in $HELPERS; do
    awk -v m="$m" '
      !on && index($0, "private static ") && index($0, " " m "(") { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$src" | sed 's/private static/static/'
  done
  echo "}"
}
# gobody <main.go> <signature>: a top-level Go func from its signature line to the closing brace in column 0.
gobody() { awk -v sig="$2" 'index($0, sig) == 1 { on = 1 } on { print } on && /^}/ { exit }' "$1"; }
# lineof <text> <fixed string>: the first line number holding the string ("" if none).
lineof() { printf '%s\n' "$1" | grep -nF -- "$2" | head -n 1 | cut -d: -f1; }

# suite <ProfileActivity.java> <main.go>: 0 pass, 1 a case or pin failed, 2 an extraction missed, 3 did not compile.
suite() {
  local pa="$1" go="$2" d m n segs scopes tok wbody cbody sprl addl asl out rc
  d=$(mktemp -d -p "$W") || return 2
  lift "$pa" > "$d/SealLifted.java"
  for m in $HELPERS; do
    grep -q " $m(" "$d/SealLifted.java" || { echo "  MISS  $m not extracted from ProfileActivity.java"; return 2; }
  done
  segs=$(grep -cF 'static final int SEGS = 5;' "$pa")
  [ "$segs" = 1 ] || { echo "  PIN   SealBar is no longer 'static final int SEGS = 5;' (found $segs)"; return 1; }

  # (a) the agent's scope tokens
  wbody=$(gobody "$go" 'func progScopeOf(')
  [ -n "$wbody" ] || { echo "  MISS  func progScopeOf( not found in main.go"; return 2; }
  scopes=$(printf '%s\n' "$wbody" | sed -n 's/.*return "\([^"]*\)".*/\1/p')
  for tok in $scopes; do
    case "$tok" in *[!a-z0-9_]*) echo "  PIN   progScopeOf returns \"$tok\", outside [a-z0-9_]: the readers' scope list cannot carry it"; return 1 ;; esac
  done
  n=$(printf '%s\n' "$scopes" | grep -c .)
  [ "$n" -ge 7 ] || { echo "  MISS  progScopeOf holds $n return literals, want at least 7 (the control)"; return 2; }
  for tok in vault de media sys apps; do
    case " $(echo $scopes) " in *" $tok "*) ;; *) echo "  PIN   progScopeOf no longer emits the logoff leg $tok"; return 1 ;; esac
  done

  # (b) the frame: writeProg "%s %d %d" + scope last; composeSealStatus "SEALING " prefix
  wbody=$(gobody "$go" 'func writeProg(')
  [ -n "$wbody" ] || { echo "  MISS  func writeProg( not found in main.go"; return 2; }
  n=$(printf '%s\n' "$wbody" | grep -cF 'fmt.Sprintf("%s %d %d", phase, done, total)')
  [ "$n" = 1 ] || { echo "  PIN   writeProg frame is no longer one fmt.Sprintf(\"%s %d %d\", phase, done, total) ($n)"; return 1; }
  sprl=$(lineof "$wbody" 'fmt.Sprintf("%s %d %d", phase, done, total)')
  n=$(printf '%s\n' "$wbody" | grep -cE '^[[:space:]]*line \+= ')
  [ "$n" = 1 ] || { echo "  PIN   writeProg appends to the frame $n times, want exactly the scope"; return 1; }
  addl=$(printf '%s\n' "$wbody" | grep -nE '^[[:space:]]*line \+= ' | head -n 1 | cut -d: -f1)
  asl=$(printf '%s\n' "$wbody" | sed -n "${addl}p")
  case "$asl" in *'line += " " + sc'*) ;; *) echo "  PIN   writeProg no longer appends the scope as line += \" \" + sc"; return 1 ;; esac
  [ "$addl" -gt "$sprl" ] || { echo "  PIN   writeProg appends the scope before the byte pair, not LAST"; return 1; }
  n=$(printf '%s\n' "$wbody" | sed -n "$((addl + 1)),\$p" | grep -cE '^[[:space:]]*line = ')
  [ "$n" = 0 ] || { echo "  PIN   writeProg reassigns the frame after the scope is appended"; return 1; }
  cbody=$(gobody "$go" 'func composeSealStatus(')
  [ -n "$cbody" ] || { echo "  MISS  func composeSealStatus( not found in main.go"; return 2; }
  [[ "$cbody" == *'"SEALING " + p'* ]] || { echo "  PIN   composeSealStatus no longer prefixes the line with \"SEALING \" + p"; return 1; }

  cp "$CASES" "$d/"
  out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$d/SealLifted.java" "$d/SealProgressCases.java" 2>&1) \
    || { echo "  BUILD javac failed"; printf '%s\n' "$out" | head -20; return 3; }
  # shellcheck disable=SC2086 # the scope tokens are a word list
  out=$("$JAVA" -Djava.io.tmpdir="$W" -cp "$d" SealProgressCases $scopes 2>&1); rc=$?
  printf '%s\n' "$out" | grep -v '^ok ' | sed 's/^/  /'
  return $((rc != 0))
}

echo "== $PA + $GO"
suite "$PA" "$GO"; rc=$?
[ "$rc" = 0 ] || { echo "FAILED (rc=$rc)"; [ "$rc" = 2 ] && exit 2; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl"; exit 1; }
FAILS=0
# mut <label> <pa|go> <anchor> <replacement>: the anchor is a fixed string that occurs once in the target.
mut() {
  local label="$1" which="$2" anchor="$3" repl="$4" src d m n out rc
  if [ "$which" = pa ]; then src="$PA"; else src="$GO"; fi
  n=$(grep -cF -- "$anchor" "$src")
  if [ "$n" != 1 ]; then echo "  ERROR     $label -- anchor occurs $n times, want 1"; FAILS=$((FAILS + 1)); return; fi
  d=$(mktemp -d -p "$W") || { FAILS=$((FAILS + 1)); return; }
  m="$d/$(basename "$src")"
  cp "$src" "$m"
  A="$anchor" B="$repl" perl -0pi -e 's/\Q$ENV{A}\E/$ENV{B}/' "$m" || { echo "  ERROR     $label -- perl failed"; FAILS=$((FAILS + 1)); return; }
  if cmp -s "$src" "$m"; then echo "  INERT     $label -- the mutation changed nothing"; FAILS=$((FAILS + 1)); return; fi
  if [ "$which" = pa ]; then out=$(suite "$m" "$GO"); else out=$(suite "$PA" "$m"); fi
  rc=$?
  case "$rc" in
    1) echo "  convicted $label" ;;
    0) echo "  SURVIVED  $label"; FAILS=$((FAILS + 1)) ;;
    *) echo "  BROKEN    $label (rc=$rc)"; printf '%s\n' "$out" | head -20; FAILS=$((FAILS + 1)) ;;
  esac
}
echo "== mutants"
mut "S1 sealBytes scans from the left" pa 'for (int i = p.length - 2; i >= 1; i--)' 'for (int i = 1; i < p.length - 1; i++)'
mut "S2 sealPct clamp to 100 removed" pa '(pct > 100 ? 100 : (int) pct)' '(int) pct'
mut "S3 sealScope needs 4 fields not 5" pa 'return p.length >= 5 ? p[p.length - 1] : "";' 'return p.length >= 4 ? p[p.length - 1] : "";'
mut "S4 sealScopeIndex maps apps to -1" pa 'case "apps":  return 4;' 'case "apps":  return -1;'
mut "S5 sealScopeLabel loses the sys arm" pa 'case "sys": case "account":    return' 'case "account":    return'
mut "S6 partialWhat drops keys=" pa 'keys = parts.contains("keys=")' 'keys = false'
mut "S7 fmtBytes < 100 becomes <= 100" pa 'Math.round(mb * 10) < 100' 'Math.round(mb * 10) <= 100'
mut "S8 progScopeOf returns a new notes token" go '	case strings.HasSuffix(profile, "#wallet"):' $'	case strings.HasSuffix(profile, "#notes"):\n		return "notes"\n	case strings.HasSuffix(profile, "#wallet"):'
mut "S9 writeProg frame reordered" go 'fmt.Sprintf("%s %d %d", phase, done, total)' 'fmt.Sprintf("%d %d %s", done, total, phase)'
mut "S10 composeSealStatus loses the SEALING prefix" go 'lines := []string{"SEALING " + p}' 'lines := []string{"SEAL " + p}'
mut "S11 progScopeOf returns a hyphenated notes-v2 token" go '	case strings.HasSuffix(profile, "#wallet"):' $'	case strings.HasSuffix(profile, "#notes-v2"):\n		return "notes-v2"\n	case strings.HasSuffix(profile, "#wallet"):'
# X1: a helper missing from ProfileActivity.java must exit 2 at the script boundary, not 1.
d=$(mktemp -d -p "$W") || exit 2
sed 's/ partialMessage(/ partialMessageGone(/' "$PA" > "$d/ProfileActivity.java"
cmp -s "$PA" "$d/ProfileActivity.java" && { echo "  INERT     X1 -- the rename changed nothing"; FAILS=$((FAILS + 1)); }
bash "$0" "$d/ProfileActivity.java" "$GO" >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then echo "  convicted X1 missing helper exits 2"; else echo "  BROKEN    X1 missing helper exited $rc, want 2"; FAILS=$((FAILS + 1)); fi
[ "$FAILS" = 0 ] || { echo "FAILED: $FAILS mutant(s) not convicted"; exit 1; }
echo "== all mutations convicted"
