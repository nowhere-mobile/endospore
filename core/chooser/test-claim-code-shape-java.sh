#!/usr/bin/env bash
# test-claim-code-shape-java.sh [--mutate] -- the gate refuses a claim code that is not 24 base64url characters at the
# create tap, before anything is sent (NWP-20261125-14).
#
# WHY THIS IS COMMITTED. Backlog row "P0: `CREATE-CODE` joins an identified purchase to `profileRefV2` seconds later
# from the same IP", h55 #1 (docs/product-decisions.md 2026-11-03): the gate and the agent refuse only a code that is
# not 24 base64url characters, with the same ERR-NOCODE text, before anything is created. The shape is
# nowhere-cloud cmd/storefront/checkout.go newClaimCode's: 18 random bytes as base64.RawURLEncoding (24 characters,
# [A-Za-z0-9_-], no padding). Before this slice the create tap sent any typed text as CREATE-CODE. The agent's copy
# of the rule (claimCodeWellFormed) is tested by core/agent/claim_code_shape_test.go.
#
# WHAT RUNS. ClaimCodeShape.java (pure java.lang) is compiled ALONE with javac and ClaimCodeShapeCases (below) runs
# over it. ChooserActivity needs Android and cannot be compiled here, so the create tap's check is PINNED in source:
# inside roamLogin, one ClaimCodeShape.wellFormed(claimCode) guard, after the offline-create refusal, before
# showRestoring(name) and before createStreaming("CREATE-CODE; its body is hideRestore, the ERR-NOCODE reply's exact
# words, and return.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-claim-code-shape-java.sh            # the cases and the pins
#   bash test-claim-code-shape-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser"
CCS="${CCS:-$SRC/ClaimCodeShape.java}"
CA="${CA:-$SRC/ChooserActivity.java}"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
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
"$JAVAC" -version >/dev/null 2>&1 || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CA" ] || { echo "FAIL: missing $CA" >&2; exit 2; }

# The one temp root: every class dir and every mutant live inside it, and the EXIT trap removes it on every path.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok    $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

# ⚠ Every match reads its input to the end (a here-string or a count, never `cmd | grep -q`).
# count <text> <fixed string>: how many lines of text hold the string.
count(){ local n; n=$(grep -cF -- "$2" <<<"$1"); echo "${n:-0}"; }
# lineno <text> <fixed string>: the first line of text holding the string, 0 when none.
lineno(){ local n; n=$(grep -nF -- "$2" <<<"$1" | head -n1 | cut -d: -f1); echo "${n:-0}"; }

echo "== ClaimCodeShape under javac =="
CASES='package com.nowhere.chooser;

public class ClaimCodeShapeCases {
    static int fails = 0;
    static void is(String code, boolean want, String why) {
        boolean got = ClaimCodeShape.wellFormed(code);
        boolean c = got == want;
        System.out.println((c ? "  ok    " : "  FAIL  ") + "wellFormed(" + (code == null ? "null" : "\"" + code + "\"")
                + ") = " + got + ", want " + want + " -- " + why);
        if (!c) fails++;
    }

    public static void main(String[] a) {
        is("q3Zr-8_kLmN0pQ1sT2uV3wXy", true, "a real 24-character code");
        is("ABCDEFGHIJKLMNOPQRSTUVWX", true, "upper case");
        is("YZabcdefghijklmnopqrstuv", true, "lower case");
        is("wxyz0123456789ABCDEFGHIJ", true, "digits");
        is("AAAAAAAAAAAAAAAAAAAAAAA-", true, "a dash");
        is("AAAAAAAAAAAAAAAAAAAAAAA_", true, "an underscore");
        is(null, false, "null");
        is("", false, "empty");
        is("PAID-CODE", false, "short");
        is("q3Zr-8_kLmN0pQ1sT2uV3wX", false, "23 characters");
        is("q3Zr-8_kLmN0pQ1sT2uV3wXyz", false, "25 characters");
        is("q3Zr-8_kLmN0pQ1sT2uV", false, "20 characters");
        is("q3Zr-8_kLmN0pQ1sT2uV3w", false, "22 characters");
        is("q3Zr-8_kLmN0pQ1sT2uV3wX+", false, "standard base64 +");
        is("q3Zr-8_kLmN0pQ1sT2uV3wX/", false, "standard base64 /");
        is("q3Zr-8_kLmN0pQ1sT2uV3wX=", false, "padding");
        is("q3Zr-8_kLmN0 Q1sT2uV3wXy", false, "a space inside");
        is("q3Zr-8_kLmN0pQ1sT2uV3wXé", false, "non-ASCII letter at 24 characters");
        is("q3Zr-8_kLmN0pQ1sT2uV3wX٣", false, "non-ASCII digit at 24 characters");
        is("q3Zr-8_kLmN0pQ1sT2uV3wé", false, "non-ASCII letter at 23 characters");
        if (fails > 0) System.exit(1);
    }
}'

run_cases(){  # <ClaimCodeShape.java>: compile it ALONE with the cases and run them; prints the case lines.
  local d out rc
  d=$(mktemp -d -p "$W") || exit 2
  mkdir -p "$d/src/com/nowhere/chooser" "$d/classes" || exit 2
  cp -- "$1" "$d/src/com/nowhere/chooser/ClaimCodeShape.java" || exit 2
  printf '%s\n' "$CASES" > "$d/src/com/nowhere/chooser/ClaimCodeShapeCases.java" || exit 2
  out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/classes" "$d/src/com/nowhere/chooser/ClaimCodeShape.java" \
        "$d/src/com/nowhere/chooser/ClaimCodeShapeCases.java" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$out"; echo "  FAIL  cases: ClaimCodeShape.java does not compile alone"; return 1; fi
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/classes" com.nowhere.chooser.ClaimCodeShapeCases
}

if [ -f "$CCS" ]; then
  co=$(run_cases "$CCS")
  printf '%s\n' "$co"
  PASS=$((PASS + $(count "$co" '  ok    ')))
  FAIL=$((FAIL + $(count "$co" '  FAIL  ')))
else
  no "cases: no ClaimCodeShape.java at $CCS"
fi
if [ -f "$CCS" ] && [ "$(count "$(cat -- "$CCS")" 'import ')" -eq 0 ]; then
  ok "P0 ClaimCodeShape imports nothing (java.lang only)"
else
  no "P0 ClaimCodeShape is missing or imports something"
fi

echo "== the create tap's check, pinned in ChooserActivity.roamLogin =="
# roamLogin: from the four-argument signature to the next method the file declares after it.
rl=$(awk '/private void roamLogin\(final String name, final String pw, final boolean isCreate, final String keyMode\)/ { on = 1 }
          /private void offerSnapshotRecovery\(/ { on = 0 }
          on' "$CA")
GUARD='if (isCreate && !claimCode.isEmpty() && !ClaimCodeShape.wellFormed(claimCode)) {'
MSG='showMsg("that code wasn'"'"'t recognized — check it, or leave it blank to start free");'
g=$(lineno "$rl" "$GUARD")
off=$(lineno "$rl" 'if (offline && isCreate) {')
sr=$(lineno "$rl" 'showRestoring(name);')
cc=$(lineno "$rl" 'createStreaming("CREATE-CODE')
if [ -n "$rl" ] && [ "$(count "$rl" 'ClaimCodeShape.wellFormed(')" -eq 1 ] && [ "$(count "$rl" "$GUARD")" -eq 1 ]; then
  ok "P1 roamLogin calls ClaimCodeShape.wellFormed once, in the guard, on the claim code read at the tap"
else
  no "P1 roamLogin has no single '$GUARD'"
fi
if [ "$g" -gt 0 ] && [ "$off" -gt 0 ] && [ "$sr" -gt 0 ] && [ "$cc" -gt 0 ] \
   && [ "$off" -lt "$g" ] && [ "$g" -lt "$sr" ] && [ "$g" -lt "$cc" ]; then
  ok "P2 the guard comes after the offline-create refusal, before showRestoring(name) and before CREATE-CODE is sent"
else
  no "P2 the guard is out of order (offline $off, guard $g, showRestoring $sr, CREATE-CODE $cc)"
fi
gb=""
[ "$g" -gt 0 ] && gb=$(sed -n "$((g + 1)),$((g + 4))p" <<<"$rl" | sed 's/^ *//')
want=$(printf '%s\n' 'hideRestore();' "$MSG" 'return;' '}')
if [ -n "$gb" ] && [ "$gb" = "$want" ]; then
  ok "P3 the guard's body is hideRestore, the ERR-NOCODE reply's words, return"
else
  no "P3 the guard's body is not hideRestore / the ERR-NOCODE words / return: [$gb]"
fi
if [ "$(count "$rl" "$MSG")" -eq 2 ]; then
  ok "P4 the guard and the ERR-NOCODE reply branch show the same words"
else
  no "P4 the ERR-NOCODE words are not shown exactly twice in roamLogin ($(count "$rl" "$MSG"))"
fi

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
[ "$MUTATE" = yes ] || exit 0

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "pass" >/dev/null 2>&1; then PY=$c; break; fi
done
[ -n "$PY" ] || { echo "FAIL: --mutate needs python" >&2; exit 2; }

echo "== mutations (each MUST be convicted) =="
MPASS=0; MFAIL=0
# mutant <label> <CCS|CA> <python statements calling r(old, new)>: r needs EXACTLY one match, or the mutant failed to
# apply, which is a failure, never a pass.
mutant(){
  local label="$1" var="$2" py="$3" src out o rc
  src="${!var}"
  out=$(mktemp -p "$W" mut.XXXXXX.java) || exit 2
  "$PY" -c '
import sys
s = open(sys.argv[1], encoding="utf-8").read()
def r(old, new):
    global s
    if s.count(old) != 1: sys.exit(3)
    s = s.replace(old, new)
exec(sys.argv[3])
open(sys.argv[2], "w", encoding="utf-8").write(s)' "$src" "$out" "$py" || { MFAIL=$((MFAIL+1)); echo "  FAIL  MUTANT DID NOT APPLY: $label"; return; }
  if cmp -s "$src" "$out"; then MFAIL=$((MFAIL+1)); echo "  FAIL  MUTANT INERT: $label"; return; fi
  o=$(env "$var=$out" bash "$0" 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && grep -qE '^  FAIL  ' <<<"$o"; then
    MPASS=$((MPASS+1)); echo "  ok    convicted: $label -- $(grep -E '^  FAIL  ' <<<"$o" | head -n1 | sed 's/^  FAIL  //')"
  else
    MFAIL=$((MFAIL+1)); echo "  FAIL  NOT CONVICTED: $label (rc=$rc)"
  fi
}
mutant "M1 length 24 -> 22" CCS 'r("code.length() != 24", "code.length() != 22")'
mutant "M2 '-' dropped from the class" CCS 'r("|| c == \x27-\x27 || c == \x27_\x27;", "|| c == \x27_\x27;")'
mutant "M3 '_' dropped from the class" CCS 'r("|| c == \x27-\x27 || c == \x27_\x27;", "|| c == \x27-\x27;")'
mutant "M4 any length of 24 or less" CCS 'r("code.length() != 24", "code.length() > 24")'
mutant "M5 Character.isLetterOrDigit for the class" CCS 'r("boolean ok = (c >= \x27A\x27 && c <= \x27Z\x27) || (c >= \x27a\x27 && c <= \x27z\x27) || (c >= \x270\x27 && c <= \x279\x27)", "boolean ok = Character.isLetterOrDigit(c)")'
mutant "M6 the tap check removed" CA '
r("""            if (isCreate && !claimCode.isEmpty() && !ClaimCodeShape.wellFormed(claimCode)) {
                hideRestore();
                showMsg("that code wasn\x27t recognized — check it, or leave it blank to start free");
                return;
            }
""", "")'
mutant "M7 the tap check moved after showRestoring(name)" CA '
g = """            if (isCreate && !claimCode.isEmpty() && !ClaimCodeShape.wellFormed(claimCode)) {
                hideRestore();
                showMsg("that code wasn\x27t recognized — check it, or leave it blank to start free");
                return;
            }
"""
sr = "            showRestoring(name); // swap the gate to \"Logging in <name>…\" + the progress bar\n"
r(g, "")
r(sr, sr + g)'
mutant "M8 the tap check refuses an empty code too" CA 'r("if (isCreate && !claimCode.isEmpty() && !ClaimCodeShape.wellFormed(claimCode)) {", "if (isCreate && !ClaimCodeShape.wellFormed(claimCode)) {")'
mutant "M9 the tap check shows other words" CA '
r("""                hideRestore();
                showMsg("that code wasn\x27t recognized — check it, or leave it blank to start free");
                return;
            }
            showRestoring(name);""", """                hideRestore();
                showMsg("That code is not valid.");
                return;
            }
            showRestoring(name);""")'
echo "== mutants: $MPASS convicted, $MFAIL failed =="
[ "$MFAIL" -eq 0 ]
