#!/usr/bin/env bash
# test-signin-clear-java.sh [--mutate] -- the gate clears its sign-in fields at a screen-off (NWP-20261117-09).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md, 2026-10-29 ("three answers — the gate clears its sign-in fields
# when the screen turns off ..."): after a sign-in that could not reach the store, the gate kept the typed name and
# passphrase with no bound, so whoever picked up the phone next could tap Unlock. The rule is the screen-off, not the
# failure. SignInClear holds the pure rules (a usable name and passphrase, when a screen-off ends a key wait, the
# no-creds line) and is compiled here with its cases. The source check pins the ChooserActivity wiring the class
# cannot hold: screenOffRx calls clearSignInFields on ACTION_SCREEN_OFF only, it clears and re-masks all four fields,
# it ends an idle key wait as Cancel does, a key tap after the clear starts nothing and gives the form back, and a
# create reads its claim code at the tap.
#
# NWP-20261118-07 (docs/product-decisions.md 2026-10-30, "ten answers to harvest 48 ...", item 7) applies the same
# rule to the three screens the clear left out. The source check pins closeScreenOffSurfaces, called once by the
# receiver after clearSignInFields: it dismisses the kept "Couldn't load your data" offer (snapshotOffer) and runs its
# Cancel's statements; it empties every box of Reset passphrase or Add this phone (gateSubScreen), moves
# gateSubScreenGen and shows the sign-in screen. A reset or add already sent finishes, but its reply refills no name
# and touches no closed screen (the gen check). No log line of it prints a field or a name.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-signin-clear-java.sh            # the source check, then the cases
#   bash test-signin-clear-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SUT="$root/core/chooser/src/com/nowhere/chooser/SignInClear.java"
CASES="$root/core/chooser/tests/signin-clear/SignInClearCases.java"
ACT="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

command -v python3 >/dev/null 2>&1 || { echo "FAIL: the source check needs python3, and there is none" >&2; exit 2; }

# The source check, on a comment-stripped copy. Method bodies are cut out by string-aware brace matching; a failed
# extraction is a FAIL, never a pass.
PINS=$(mktemp -p "$W") || exit 2
cat >"$PINS" <<'PY'
import re, sys

src = open(sys.argv[1], encoding="utf-8").read()

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

def norm(t):
    return re.sub(r"\s+", " ", t).strip()

s = strip(src)
fails = []
def ok(cond, what):
    print(("  ok    " if cond else "  FAIL  ") + what)
    if not cond:
        fails.append(what)

CALL = re.compile(r"(?<![\w.])clearSignInFields\(\);")

# 1. declared once
ok(s.count("private void clearSignInFields()") == 1, "clearSignInFields is declared exactly once")

# 2. the receiver calls it once, after the SCREEN_ON branch returns and before the OTA thread
rb = block(s, "screenOffRx = new android.content.BroadcastReceiver()")
if rb is None:
    ok(False, "screenOffRx's receiver block is found")
else:
    rx = s[rb[0]:rb[1] + 1]
    on = block(rx, "if (Intent.ACTION_SCREEN_ON.equals(i.getAction()))")
    calls = [m.start() for m in CALL.finditer(rx)]
    if on is None:
        ok(False, "the receiver's ACTION_SCREEN_ON branch is found")
    else:
        th = rx.find("new Thread(", on[1])
        ok(rx[on[0]:on[1]].rstrip().endswith("return;"), "the ACTION_SCREEN_ON branch ends in return;")
        ok(len(calls) == 1 and on[1] < calls[0] and th > calls[0],
           "the receiver calls clearSignInFields() once, after the SCREEN_ON branch, before new Thread(")

# 3-5. the clear itself
cb = block(s, "private void clearSignInFields()")
if cb is None:
    ok(False, "clearSignInFields' body is found")
    body = ""
else:
    body = s[cb[0]:cb[1] + 1]
    for f in ("profileField", "passField", "confirmField", "gateCodeField"):
        ok(body.count(f + '.setText("")') == 1, "clearSignInFields clears " + f + " once")
    ok(body.count("setPassRevealed(false)") == 1, "clearSignInFields re-masks (setPassRevealed(false)) once")
    pk = re.search(r"boolean parked =([^;]*);", body)
    rt = re.search(r"boolean roundTrip =([^;]*);", body)
    pkt = norm(pk.group(1)) if pk else ""
    ok(pk is not None and all(t in pkt for t in ("awaitKeyMode", "usbKeyFallback != null", "nfcResumeUsbFallback != null")),
       "parked names awaitKeyMode, usbKeyFallback, nfcResumeUsbFallback")
    ok("resumeMode && awaitKeyCancel != null && awaitKeyCancel.getVisibility() == View.VISIBLE" in pkt,
       "parked holds the resume key park (resumeMode and a visible Cancel)")
    ok(rt is not None and "loginInProgress" in rt.group(1) and "resumeBusy" in rt.group(1),
       "roundTrip is loginInProgress or resumeBusy")
    eb = block(body, "if (SignInClear.endsKeyWait(parked, roundTrip))")
    if eb is None:
        ok(False, "the endsKeyWait(parked, roundTrip) block is found")
    else:
        e = norm(body[eb[0] + 1:eb[1]])
        ok(all(t in e for t in ("awaitKeyMode = false;", "usbKeyFallback = null;", "nfcLoginInFlight = false;",
                                "nfcResumeUsbFallback = null;")),
           "the key-wait end holds awaitKeyCancel's statements")
        ok(e.endswith("hideRestore();"), "the key-wait end ends in hideRestore();")
    logs = [body[m.start():body.find(";", m.start())] for m in re.finditer(r"\bLog\.", body)]
    ok(len(logs) >= 1 and not any("getText" in l for l in logs), "the clear's log line prints no field value")

# 6-7. gateNfcResult
ga = s.find("private NfcFido2.Result gateNfcResult()")
gz = s.find("private void disarmGateNfc()")
if ga < 0 or gz < ga:
    ok(False, "gateNfcResult is found before disarmGateNfc's declaration")
else:
    g = s[ga:gz]
    sn = g.find("String n = profileField.getText()")
    gb = block(g, "if (!SignInClear.usable(n, p))", max(sn, 0))
    dis = g.rfind("disarmGateNfc();")
    rl = g.find("roamLogin(n, p, false)")
    if sn < 0 or gb is None:
        ok(False, "gateNfcResult's login branch holds the guard if (!SignInClear.usable(n, p))")
    else:
        gt = g[gb[0]:gb[1] + 1]
        ok(all(t in gt for t in ("hideRestore();", "SignInClear.NEED_CREDS", "return;")),
           "the login guard holds hideRestore, NEED_CREDS and return")
        ok(gb[1] < dis and gb[1] < rl and rl > 0, "the login guard precedes disarmGateNfc() and roamLogin(n, p, false)")
    nb = block(g, '"no-creds".equals(detail)')
    if nb is None:
        ok(False, "gateNfcResult's no-creds arm is found")
    else:
        nc = g[nb[0]:nb[1] + 1]
        rm = block(nc, "if (resumeMode)")
        el = block(nc, "else", rm[1]) if rm else None
        if el is None or norm(nc[rm[1] + 1:el[0]]) != "else":
            ok(False, "the no-creds arm's fresh-gate else is found")
        else:
            et = norm(nc[el[0] + 1:el[1]])
            a = et.find("if (awaitKeyMode) hideRestore();")
            b = et.find("result.setText(SignInClear.NEED_CREDS);")
            ok(0 <= a < b, "the no-creds else gives a parked form back before NEED_CREDS")
            ok('"' not in et, "the no-creds else holds no string literal")

# 8. awaitKeyRetry
ab = block(s, "awaitKeyRetry.setOnClickListener(")
ok(ab is not None and "SignInClear.usable(" in s[ab[0]:ab[1]], "awaitKeyRetry's login branch calls SignInClear.usable")

# 9. the claim code is read at the tap
ra = s.find("private void roamLogin(final String name, final String pw, final boolean isCreate, final String keyMode)")
rz = s.find("private void offerSnapshotRecovery(")
if ra < 0 or rz < ra:
    ok(False, "roamLogin is found before offerSnapshotRecovery")
else:
    r = s[ra:rz]
    ok(r.count("gateCodeField.getText") == 1 and r.find("gateCodeField.getText") < r.find("new Thread("),
       "roamLogin reads gateCodeField once, before its new Thread(")
    ok("final String code = claimCode;" in r, "the create sends the claim code read at the tap")

# 10. no clear from a task switch
ok(len(CALL.findall(s)) == 1, "the file calls clearSignInFields() exactly once")
pb = block(s, "protected void onPause()")
ok(pb is not None and "clearSignInFields" not in s[pb[0]:pb[1]], "onPause never calls clearSignInFields")
ob = block(s, "protected void onResume()")
if ob is None or rb is None or not (ob[0] < rb[0] < ob[1]):
    ok(False, "onResume's body and the receiver inside it are found")
else:
    cut_end = rb[1] + 1
    if s[cut_end:cut_end + 1] == ";":
        cut_end += 1
    rest = s[ob[0]:s.find("screenOffRx = new android.content.BroadcastReceiver()")] + s[cut_end:ob[1]]
    ok("clearSignInFields" not in rest, "onResume never calls clearSignInFields outside the receiver")
    ok(len(CALL.findall(s[rb[0]:rb[1]])) == 1, "control: the receiver block holds the one call")

# 11-19. NWP-20261118-07: the three screens the clear leaves out
CLOSE = "private void closeScreenOffSurfaces()"
CALL2 = re.compile(r"(?<![\w.])closeScreenOffSurfaces\(\);")
ok(s.count(CLOSE) == 1, "closeScreenOffSurfaces is declared exactly once")
xb = block(s, CLOSE)
if cb is None or xb is None:
    ok(False, "closeScreenOffSurfaces follows clearSignInFields directly")
    xs = ""
else:
    ok(s[cb[1] + 1:s.find(CLOSE)].strip() == "", "closeScreenOffSurfaces follows clearSignInFields directly")
    xs = s[xb[0]:xb[1] + 1]
ok(len(CALL2.findall(s)) == 1, "the file calls closeScreenOffSurfaces() exactly once")
if rb is None or on is None:
    ok(False, "the receiver calls closeScreenOffSurfaces() after clearSignInFields(), before new Thread(")
else:
    c2 = [m.start() for m in CALL2.finditer(rx)]
    c1 = [m.start() for m in CALL.finditer(rx)]
    th = rx.find("new Thread(", on[1])
    ok(len(c2) == 1 and len(c1) == 1 and on[1] < c1[0] < c2[0] < th,
       "the receiver calls closeScreenOffSurfaces() once, after clearSignInFields(), before new Thread(")
ok(pb is not None and "closeScreenOffSurfaces" not in s[pb[0]:pb[1]], "onPause never calls closeScreenOffSurfaces")

# 13. the offer is kept, its buttons unchanged
ob2 = block(s, "private void offerSnapshotRecovery(")
if ob2 is None:
    ok(False, "offerSnapshotRecovery's body is found")
else:
    o = norm(s[ob2[0]:ob2[1] + 1])
    k = o.find("snapshotOffer = new android.app.AlertDialog.Builder(this)")
    ok(k >= 0 and o.find(".show();", k) > k, "offerSnapshotRecovery keeps the dialog .show() returns in snapshotOffer")
    ok(all(t in o for t in ('.setPositiveButton("Try again", (d, w) -> roamLogin(name, pw, false))',
                            '.setNeutralButton("Restore last good version", (d, w) -> doGateRollback(name, pw))',
                            '.setNegativeButton("Cancel", (d, w) -> { hideRestore(); if (result != null) result.setText(""); })')),
       "the offer's three buttons are unchanged")

# 14. the snapshot branch
sb = block(xs, "if (snapshotOffer != null && snapshotOffer.isShowing())")
if sb is None:
    ok(False, "closeScreenOffSurfaces tests snapshotOffer.isShowing()")
else:
    t = norm(xs[sb[0]:sb[1] + 1])
    seq = ["snapshotOffer.dismiss();", "hideRestore();", 'if (result != null) result.setText("");', "snapshotOffer = null;"]
    pos = [t.find(x) for x in seq]
    ok(all(x >= 0 for x in pos) and pos == sorted(pos),
       "the snapshot branch dismisses, then runs Cancel's hideRestore and result clear, then drops the offer")

# 15. the sub-screen branch
m = re.search(r"if \(([^{]*gateSubScreen != null[^{]*gateSubScreen\.isAttachedToWindow\(\)[^{]*)\)\s*\{", xs)
gb2 = block(xs, m.group(0)) if m else None
if gb2 is None:
    ok(False, "closeScreenOffSurfaces tests gateSubScreen != null and isAttachedToWindow()")
else:
    t = norm(xs[gb2[0]:gb2[1] + 1])
    clr = t.find('((EditText) v).setText("");')
    ok("instanceof EditText" in t and clr >= 0, "the sub-screen branch empties every EditText under it")
    ok("instanceof android.view.ViewGroup" in t and "getChildAt(" in t, "the sub-screen branch walks the ViewGroup children")
    g = t.find("gateSubScreenGen++;")
    sv = t.find("setContentView(gateView);")
    nl = t.find("gateSubScreen = null;")
    ok(0 <= clr < g and 0 <= clr < sv and sv >= 0 and nl > sv,
       "the sub-screen branch clears, moves gateSubScreenGen, shows gateView, drops gateSubScreen")

# 16. the log lines print nothing typed
logs2 = [xs[mm.start():xs.find(";", mm.start())] for mm in re.finditer(r"\bLog\.", xs)]
ok(len(logs2) == 2 and not any("+" in l or "getText" in l for l in logs2),
   "closeScreenOffSurfaces logs two constant lines that print no field and no name")

# 17. the two links record the screen
for link, b in (("forgotLink", "buildRecoverScreen"), ("addPhoneLink", "buildAddPhoneScreen")):
    lb = block(s, link + ".setOnClickListener(")
    t = norm(s[lb[0]:lb[1] + 1]) if lb else ""
    a1 = t.find("gateSubScreen = " + b + "();")
    a2 = t.find("setContentView(gateSubScreen);")
    ok(0 <= a1 < a2, link + "'s click sets gateSubScreen = " + b + "() before setContentView(gateSubScreen)")

# 18. the builders: the gen check on a reply
for b, nfail in (("private View buildRecoverScreen()", 1), ("private View buildAddPhoneScreen()", 2)):
    bb = block(s, b)
    if bb is None:
        ok(False, b + "'s body is found")
        continue
    t = norm(s[bb[0] + 1:bb[1]])
    ok(t.startswith("final int gen = gateSubScreenGen;"), b + " reads gen = gateSubScreenGen first")
    ok(t.count("profileField.setText(nm)") == 1, b + " refills the name once")
    ib = block(t, "if (gen == gateSubScreenGen)")
    it = t[ib[0]:ib[1] + 1] if ib else ""
    ok("profileField.setText(nm)" in it and "setContentView(gateView);" in it and "passField" not in it,
       b + "'s success refills the name and shows gateView only when gen == gateSubScreenGen")
    ok(ib is not None and 'passField.setText("")' in t[ib[1]:] and "result.setText(" in t[ib[1]:],
       b + "'s success still clears passField and shows its result line")
    ok(t.count("if (gen != gateSubScreenGen) return;") == nfail, b + "'s failure touches no view of a closed screen")
    ok("cancel.setOnClickListener(v -> { gateSubScreen = null; setContentView(gateView); });" in t,
       b + "'s Cancel drops gateSubScreen")

# 19. control
ok(s.count("gateSubScreenGen++") == 1, "control: gateSubScreenGen moves in one place")

sys.exit(1 if fails else 0)
PY

# srccheck <ChooserActivity.java> -> 0 pass, 1 a property fails.
srccheck() {
  python3 "$PINS" "$1"
}

echo "== $ACT"
srccheck "$ACT" || { echo "FAILED"; exit 1; }

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

# suite <SignInClear.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that convict a
# mutant), 3 the class or the cases did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  SignInClear.java does not exist (the change is not built)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/SignInClear.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/SignInClearCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.SignInClearCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <perl-expr> -- a mutant of SignInClear.java, convicted by the cases
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/SignInClear.java"
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
smut() { # smut <label> <perl-expr> -- a mutant of ChooserActivity.java, convicted by the source check
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$ACT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$ACT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  srccheck "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"; return 0
}
fails=0
smut "M1 the receiver's call removed" 's/\n[ \t]*clearSignInFields\(\);//' || fails=$((fails+1))
smut "M2 the call moved into the SCREEN_ON branch" 's/(if \(sLiveGate == ChooserActivity\.this\) nudgeGateKeyboard\(\);\n)([ \t]*return;\n[ \t]*\}\n(?:[ \t]*\/\/[^\n]*\n)*)[ \t]*clearSignInFields\(\);\n/$1                        clearSignInFields();\n$2/' || fails=$((fails+1))
smut "M3 passField's clear removed" 's/\n[ \t]*if \(passField != null\) passField\.setText\(""\);//' || fails=$((fails+1))
smut "M4 profileField's clear removed" 's/\n[ \t]*if \(profileField != null\) profileField\.setText\(""\);//' || fails=$((fails+1))
smut "M5 gateCodeField's clear removed" 's/\n[ \t]*if \(gateCodeField != null\) gateCodeField\.setText\(""\);//' || fails=$((fails+1))
mut "M6 endsKeyWait returns parked" 's/return parked && !roundTrip;/return parked;/' || fails=$((fails+1))
smut "M7 hideRestore dropped from the key-wait end" 's/(nfcResumeUsbFallback = null; \}\n)[ \t]*hideRestore\(\);\n([ \t]*\}\n[ \t]*boolean held)/$1$2/' || fails=$((fails+1))
smut "M8 gateNfcResult's login guard removed" 's/\n[ \t]*if \(!SignInClear\.usable\(n, p\)\) \{ hideRestore\(\); result\.setTextColor[^\n]*//' || fails=$((fails+1))
smut "M9 the login guard's hideRestore dropped" 's/(if \(!SignInClear\.usable\(n, p\)\) \{ )hideRestore\(\); (result\.)/$1$2/' || fails=$((fails+1))
smut "M10 the no-creds hideRestore removed" 's/\n[ \t]*if \(awaitKeyMode\) hideRestore\(\);//' || fails=$((fails+1))
mut "M11 usable() accepts an empty pass" 's/pass != null && !pass\.isEmpty\(\) && /pass != null && /' || fails=$((fails+1))
mut "M12 usable() does not trim the name" 's/name\.trim\(\)\.isEmpty\(\)/name.isEmpty()/' || fails=$((fails+1))
smut "M13 the log line prints profileField.getText()" 's/("screen off: sign-in fields cleared \(NWP-20261117-09\)")/$1 + " " + profileField.getText()/' || fails=$((fails+1))
smut "M14 the create reads gateCodeField in its worker again" 's/final String code = claimCode;/final String code = gateCodeField == null ? "" : gateCodeField.getText().toString().trim();/' || fails=$((fails+1))
smut "M15 the resume key park dropped from parked" 's/\n[ \t]*\|\| \(resumeMode && awaitKeyCancel != null && awaitKeyCancel\.getVisibility\(\) == View\.VISIBLE\)//' || fails=$((fails+1))
smut "M16 a second call in onResume, outside the receiver" 's/(checkForOta\(\);)/$1 clearSignInFields();/' || fails=$((fails+1))
smut "M17 a call in onPause" 's/(protected void onPause\(\) \{\n)/$1        clearSignInFields();\n/' || fails=$((fails+1))
# NWP-20261118-07
smut "N1 the receiver's closeScreenOffSurfaces() call removed" 's/\n[ \t]*closeScreenOffSurfaces\(\);[^\n]*//' || fails=$((fails+1))
smut "N2 the call moved into the SCREEN_ON branch" 's/(if \(sLiveGate == ChooserActivity\.this\) nudgeGateKeyboard\(\);\n)([\s\S]*?)\n[ \t]*closeScreenOffSurfaces\(\);[^\n]*/$1                        closeScreenOffSurfaces();\n$2/' || fails=$((fails+1))
smut "N3 dismiss() removed" 's/\n[ \t]*snapshotOffer\.dismiss\(\);//' || fails=$((fails+1))
smut "N4 hideRestore() removed from the snapshot branch" 's/(snapshotOffer\.dismiss\(\);\n(?:[ \t]*\/\/[^\n]*\n)*)[ \t]*hideRestore\(\);\n/$1/' || fails=$((fails+1))
smut "N5 the EditText clear removed" 's/\(\(EditText\) v\)\.setText\(""\);/{ }/' || fails=$((fails+1))
smut "N6 gateSubScreenGen++ removed" 's/\n[ \t]*gateSubScreenGen\+\+;//' || fails=$((fails+1))
smut "N7 setContentView(gateView) removed from the sub-screen branch" 's/(gateSubScreenGen\+\+;\n)[ \t]*setContentView\(gateView\);\n/$1/' || fails=$((fails+1))
smut "N8 the gen check removed from buildRecoverScreen's success branch" 's/(private View buildRecoverScreen\(\).*?)if \(gen == gateSubScreenGen\) \{/$1if (true) {/s' || fails=$((fails+1))
smut "N9 the gen check removed from buildAddPhoneScreen's success branch" 's/(private View buildAddPhoneScreen\(\).*?)if \(gen == gateSubScreenGen\) \{/$1if (true) {/s' || fails=$((fails+1))
smut "N10 offerSnapshotRecovery no longer keeps the dialog" 's/snapshotOffer = (new android\.app\.AlertDialog\.Builder\(this\))/$1/' || fails=$((fails+1))
smut "N11 Reset's failure touches the views again" 's/(private View buildRecoverScreen\(\).*?)\n[ \t]*if \(gen != gateSubScreenGen\) return;[^\n]*/$1/s' || fails=$((fails+1))
smut "N12 Reset's Cancel keeps gateSubScreen" 's/(private View buildRecoverScreen\(\).*?)gateSubScreen = null; (setContentView\(gateView\);)/$1$2/s' || fails=$((fails+1))
smut "N13 forgotLink's click no longer records the screen" 's/gateSubScreen = buildRecoverScreen\(\);[^\n]*\n[ \t]*setContentView\(gateSubScreen\);/setContentView(buildRecoverScreen());/' || fails=$((fails+1))
smut "N14 addPhoneLink's click no longer records the screen" 's/gateSubScreen = buildAddPhoneScreen\(\);[^\n]*\n[ \t]*setContentView\(gateSubScreen\);/setContentView(buildAddPhoneScreen());/' || fails=$((fails+1))
smut "N15 a log line prints the name field" 's/("screen off: closed the couldn.t-load offer \(NWP-20261118-07\)")/$1 + profileField.getText()/' || fails=$((fails+1))
smut "N16 a call in onPause" 's/(protected void onPause\(\) \{\n)/$1        closeScreenOffSurfaces();\n/' || fails=$((fails+1))
smut "N17 Add's no-chip reply touches the views again" 's/(private View buildAddPhoneScreen\(\).*?)\n[ \t]*if \(gen != gateSubScreenGen\) return;[^\n]*/$1/s' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
