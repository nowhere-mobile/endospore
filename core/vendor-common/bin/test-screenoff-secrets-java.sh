#!/usr/bin/env bash
# test-screenoff-secrets-java.sh [--mutate] -- a screen-off empties the owner-verify, SIM PIN and gate Wi-Fi password
# fields (NWP-20261201-15).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md, 2026-11-06 ("twenty answers to harvest 60 ...", #3): "a screen-off
# empties the owner-verify, SIM PIN and gate Wi-Fi password fields." It applies the reason of 2026-10-29 ("three
# answers — the gate clears its sign-in fields when the screen turns off ..."): the rule is the screen-off, not the
# failure. Before this slice the verify screen survived a screen-off with its field filled, so whoever woke the phone
# could tap Continue into Owner settings.
#
# The source check pins the ChooserActivity wiring: the three members, the assignment in each builder, the one call in
# screenOffRx after closeScreenOffSurfaces, no call from onPause (a task switch is not a screen-off), and a log line
# that prints no field. The javac stage cuts clearScreenOffSecrets out by brace matching and runs it with its cases.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-screenoff-secrets-java.sh            # the source check, then the cases
#   bash test-screenoff-secrets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
ACT="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
TESTS="$root/core/chooser/tests/screenoff-secrets"
CASES="$TESTS/ScreenOffSecretsCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

command -v python3 >/dev/null 2>&1 || { echo "FAIL: the source check needs python3, and there is none" >&2; exit 2; }

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

# check <file>: the source check, on a comment-stripped copy. extract <file> <out.java>: the harness around the method
# cut out by string-aware brace matching (exit 4 when it is not found). A failed extraction is a FAIL, never a pass.
PINS=$(mktemp -p "$W") || exit 2
cat >"$PINS" <<'PY'
import re, sys

def strip(s):
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if s.startswith("//", i):
            j = s.find("\n", i)
            i = n if j < 0 else j
        elif s.startswith("/*", i):
            j = s.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("\n" * s.count("\n", i, j))
            i = j
        elif c in "\"'":
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == "\\" else 1
            out.append(s[i:j + 1])
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)

def close(s, o):
    """index of the } that matches the { at o, skipping literals; -1 when unmatched"""
    d, i, n = 0, o, len(s)
    while i < n:
        c = s[i]
        if c in "\"'":
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == "\\" else 1
            i = j + 1
            continue
        if c == "{":
            d += 1
        elif c == "}":
            d -= 1
            if d == 0:
                return i
        i += 1
    return -1

def block(s, anchor, start=0):
    """(open, close) of the first { after anchor; None when the anchor or its block is missing"""
    a = s.find(anchor, start)
    if a < 0:
        return None
    o = s.find("{", a + len(anchor) - 1 if anchor.endswith("{") else a + len(anchor))
    if o < 0:
        return None
    c = close(s, o)
    return None if c < 0 else (o, c)

mode, path = sys.argv[1], sys.argv[2]
s = strip(open(path, encoding="utf-8").read())

DECL = "private void clearScreenOffSecrets()"
CLOSE = "private void closeScreenOffSurfaces()"
CALL = re.compile(r"(?<![\w.])clearScreenOffSecrets\(\);")
CALL2 = re.compile(r"(?<![\w.])closeScreenOffSurfaces\(\);")

declared = s.count(DECL) == 1
mb = block(s, DECL)
method = s[s.find(DECL):mb[1] + 1] if declared and mb else None

if mode == "extract":
    if method is None:
        sys.exit(4)
    with open(sys.argv[3], "w", encoding="utf-8") as f:
        f.write("package com.nowhere.chooser;\nimport android.widget.EditText;\n"
                "final class ScreenOffSecretsHarness {\n"
                "    EditText ownerVerifyField, simPinField, wifiPassField;\n"
                + method +
                "\n    void fire() { clearScreenOffSecrets(); }\n}\n")
    sys.exit(0)

fails = []
def ok(cond, what):
    print(("  ok    " if cond else "  FAIL  ") + what)
    if not cond:
        fails.append(what)

# A0-A2. the members and the declaration
ok(all(s.count("private EditText %s;" % n) == 1 for n in ("ownerVerifyField", "simPinField", "wifiPassField")),
   "the three members are declared once each")
ok(declared, "clearScreenOffSecrets is declared exactly once")
xb = block(s, CLOSE)
ok(declared and xb is not None and s[xb[1] + 1:s.find(DECL)].strip() == "",
   "clearScreenOffSecrets directly follows closeScreenOffSurfaces")

# A3-A5. the one call
A4 = "the receiver calls clearScreenOffSecrets() once, after closeScreenOffSurfaces(), before new Thread("
ok(len(CALL.findall(s)) == 1, "the file calls clearScreenOffSecrets() exactly once")
rb = block(s, "screenOffRx = new android.content.BroadcastReceiver()")
rx = s[rb[0]:rb[1] + 1] if rb else None
on = block(rx, "if (Intent.ACTION_SCREEN_ON.equals(i.getAction()))") if rx else None
if on is None:
    ok(False, A4)
else:
    calls = [m.start() for m in CALL.finditer(rx)]
    closes = [m.start() for m in CALL2.finditer(rx)]
    th = rx.find("new Thread(", on[1])
    ok(len(calls) == 1 and len(closes) == 1 and on[1] < closes[0] < calls[0] < th, A4)
pb = block(s, "protected void onPause()")
# gated on the declaration, so that this assertion fails on a tree without the method
ok(declared and pb is not None and "clearScreenOffSecrets" not in s[pb[0]:pb[1]],
   "onPause never calls clearScreenOffSecrets")

# A6. the assignment in each builder
for anchor, member, local, what in (
        ("private View buildOwnerVerifyScreen(final int dest)", "ownerVerifyField", "pf", "buildOwnerVerifyScreen"),
        ("private View buildSimPinScreen()", "simPinField", "pinF", "buildSimPinScreen"),
        ("private View buildWifiScreen()", "wifiPassField", "pwF", "buildWifiScreen")):
    bb = block(s, anchor)
    stmt = re.compile(r"(?<![\w.])%s = %s;" % (member, local))
    ok(bb is not None and len(stmt.findall(s[bb[0]:bb[1]])) == 1 and len(re.findall(r"\b%s = " % member, s)) == 1,
       "%s assigns %s = %s once" % (what, member, local))

# A7. the log line prints nothing typed
logs = [method[m.start():method.find(";", m.start())] for m in re.finditer(r"\bLog\.", method)] if method else []
ok(len(logs) == 1 and not any("getText" in l or "length()" in l or "+" in l for l in logs),
   "clearScreenOffSecrets has one Log call, with no getText, no length() and no + concatenation")

sys.exit(1 if fails else 0)
PY

# srccheck <ChooserActivity.java> -> 0 pass, 1 a property fails.
srccheck() {
  python3 "$PINS" check "$1"
}

# harness <ChooserActivity.java> -> 0 pass, 1 a case failed (the only code that convicts a J mutant), 3 the harness or
# the cases did not compile, 4 the method was not extracted.
harness() {
  local src="$1" d out rc
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  python3 "$PINS" extract "$src" "$d/src/com/nowhere/chooser/ScreenOffSecretsHarness.java"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  FAIL  every case: the body of clearScreenOffSecrets was not extracted"
    rm -rf "$d"
    return 4
  fi
  cp "$CASES" "$d/src/com/nowhere/chooser/ScreenOffSecretsCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java \
       "$TESTS/stubs/android/widget/EditText.java" "$TESTS/stubs/android/util/Log.java"; then
    rm -rf "$d"
    return 3
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.ScreenOffSecretsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# Both stages always run, so a tree without the change shows the failure of each.
stage_fails=0
echo "== source check: $ACT"
srccheck "$ACT" || stage_fails=$((stage_fails+1))
echo "== javac: clearScreenOffSecrets with its cases"
harness "$ACT" || stage_fails=$((stage_fails+1))
[ "$stage_fails" -eq 0 ] || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by the named assertion -- a mutant that does not apply proves nothing)"

# verdict <label> <expected assertion> <rc> <output>: rc 1 with the expected line printed as FAIL convicts.
verdict() {
  case "$3" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not run (rc=$3)"; return 1 ;;
  esac
  case "$4" in
    *"  FAIL  $2"*) echo "  convicted $1 -- by: $2"; return 0 ;;
  esac
  echo "  WRONG-ASSERTION $1 -- expected: $2"
  return 1
}
# smut <label> <expected assertion> <perl-expr> -- a mutant convicted by the source check
smut() {
  local d c out rc
  d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$ACT" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$ACT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(srccheck "$c" 2>&1); rc=$?
  rm -rf "$d"
  verdict "$1" "$2" "$rc" "$out"
}
# jmut <label> <expected assertion> <perl-expr> -- a mutant convicted by a compiled case
jmut() {
  local d c out rc
  d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$ACT" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$ACT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(harness "$c" 2>&1); rc=$?
  rm -rf "$d"
  verdict "$1" "$2" "$rc" "$out"
}
A4="the receiver calls clearScreenOffSecrets() once, after closeScreenOffSurfaces(), before new Thread("
fails=0
smut "S1 the receiver's call removed" "$A4" 's/\n[ \t]*clearScreenOffSecrets\(\);[^\n]*//' || fails=$((fails+1))
smut "S2 the call moved into the SCREEN_ON branch" "$A4" 's/(if \(sLiveGate == ChooserActivity\.this\) nudgeGateKeyboard\(\);\n)([\s\S]*?)\n[ \t]*clearScreenOffSecrets\(\);[^\n]*/$1                        clearScreenOffSecrets();\n$2/' || fails=$((fails+1))
smut "S3 a call added in onPause" "onPause never calls clearScreenOffSecrets" 's/(protected void onPause\(\) \{\n)/$1        clearScreenOffSecrets();\n/' || fails=$((fails+1))
smut "S4 buildOwnerVerifyScreen's assignment removed" "buildOwnerVerifyScreen assigns ownerVerifyField = pf once" 's/\n[ \t]*ownerVerifyField = pf;[^\n]*//' || fails=$((fails+1))
smut "S5 buildSimPinScreen's assignment removed" "buildSimPinScreen assigns simPinField = pinF once" 's/\n[ \t]*simPinField = pinF;[^\n]*//' || fails=$((fails+1))
smut "S6 buildWifiScreen's assignment removed" "buildWifiScreen assigns wifiPassField = pwF once" 's/\n[ \t]*wifiPassField = pwF;[^\n]*//' || fails=$((fails+1))
jmut "J1 the owner-verify field's clear removed" "owner-verify filled alone is emptied" 's/\n[ \t]*if \(ownerVerifyField != null\) ownerVerifyField\.setText\(""\);//' || fails=$((fails+1))
jmut "J2 the SIM PIN field's clear removed" "SIM PIN filled alone is emptied" 's/\n[ \t]*if \(simPinField != null\) simPinField\.setText\(""\);//' || fails=$((fails+1))
jmut "J3 the Wi-Fi password field's clear removed" "Wi-Fi password filled alone is emptied" 's/\n[ \t]*if \(wifiPassField != null\) wifiPassField\.setText\(""\);//' || fails=$((fails+1))
jmut "J4 the held check removed (it logs always)" "all null runs and writes no line" 's/if \(held\) (android\.util\.Log\.i\("NowhereChooser", "screen off: owner-verify)/$1/' || fails=$((fails+1))
# J5 is a source mutant by design: the line runs after the fields are emptied, so getText() returns "" and the
# byte-for-byte case passes. The leak is in the text of the statement, which the Log-call assertion reads.
smut "J5 the log line prints a field's getText()" "clearScreenOffSecrets has one Log call, with no getText, no length() and no + concatenation" 's/("screen off: owner-verify, SIM PIN or Wi-Fi password field cleared \(NWP-20261201-15\)")/$1 + ownerVerifyField.getText()/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
