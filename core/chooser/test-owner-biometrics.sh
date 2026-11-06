#!/usr/bin/env bash
# test-owner-biometrics.sh [--mutate] -- the device owner turns biometrics off at user 0's keyguard, and Owner
# settings says that what is changed in System settings stays on the phone (NWP-20261114-12).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md, 2026-10-24, "biometrics cannot be enrolled under the device
# owner, and Owner settings say that what is changed there persists". User 0, the gate, is never wiped, so a
# fingerprint or face enrolled there through Owner settings > System settings persists across every sign-out and
# power-off, reaches the next renter, and never helps a session. The fix is one call in onCreate's device-owner
# branch plus one uses-policy in device_admin.xml, and each half is silent when the other is missing: without the
# policy DevicePolicyManagerService throws SecurityException and the chooser's catch swallows it (the force-lock
# precedent, 2026-07-05). This suite pins both halves and the row's copy.
#
#   (a) javac: OwnerKeyguard.withBiometricsOff ORs the mask into the flags already set; needsWrite is false only
#       when every mask bit is set. OwnerKeyguard.java imports no android class.
#   (b) source: inside the isDeviceOwnerApp branch of onCreate, one try/catch reads getKeyguardDisabledFeatures,
#       takes KEYGUARD_DISABLE_BIOMETRICS as the mask, and sets OwnerKeyguard.withBiometricsOff(cur, mask).
#   (c) device_admin.xml: <uses-policies> holds the disable-keyguard-features ELEMENT (comments are stripped by
#       the parser) beside force-lock and watch-login.
#   (d) the "System settings" row says what you change there stays on this phone.
#
# Inputs (a mutant replaces one): NWP_OB_CA (ChooserActivity.java), NWP_OB_OK (OwnerKeyguard.java),
# NWP_OB_XML (device_admin.xml). It FAILS when there is no javac, it never skips (exit 2).
#
#   bash test-owner-biometrics.sh            # the checks
#   bash test-owner-biometrics.sh --mutate   # ... plus mutants that must each CONVICT the suite (exit 1)
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SELF="$HERE/$(basename "$0")"
CA=${NWP_OB_CA:-$HERE/src/com/nowhere/chooser/ChooserActivity.java}
OK=${NWP_OB_OK:-$HERE/src/com/nowhere/chooser/OwnerKeyguard.java}
XML=${NWP_OB_XML:-$HERE/res/xml/device_admin.xml}
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

# one root for everything this suite makes
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "FAIL: no python3 (check (c) parses the XML)" >&2; exit 2; }
[ -f "$CA" ] && [ -f "$XML" ] || { echo "FAIL: missing $CA or $XML" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# Every match reads its input to the end: here-strings or captured variables, never `cmd | grep -q` under pipefail.

echo "== (a) OwnerKeyguard: OR the mask in, write only when a bit is missing =="
if [ ! -f "$OK" ]; then
  no "OwnerKeyguard.java is missing ($OK)"
else
  OKSRC=$(cat "$OK")
  if grep -qE '^[[:space:]]*import[[:space:]]+android' <<<"$OKSRC"; then
    no "OwnerKeyguard.java imports an android class -- it must stay pure for this javac check"
  else
    ok "OwnerKeyguard.java imports no android class"
  fi
  SRCD=$(mktemp -d -p "$W"); OUTD=$(mktemp -d -p "$W")
  mkdir -p "$SRCD/com/nowhere/chooser"
  cp "$OK" "$SRCD/com/nowhere/chooser/OwnerKeyguard.java"
  cat >"$SRCD/com/nowhere/chooser/OwnerKeyguardDriver.java" <<'EOF'
package com.nowhere.chooser;

public final class OwnerKeyguardDriver {
    static int bad = 0;
    static void check(boolean c, String what) {
        if (c) System.out.println("  ok    " + what); else { System.out.println("  FAIL  " + what); bad++; }
    }
    public static void main(String[] a) {
        final int BIO = 0x1A0; // KEYGUARD_DISABLE_FINGERPRINT 0x20 | FACE 0x80 | IRIS 0x100
        check(OwnerKeyguard.withBiometricsOff(0x2, BIO) == 0x1A2, "withBiometricsOff(0x2, 0x1A0) == 0x1A2 (keeps the flag already set)");
        check(OwnerKeyguard.withBiometricsOff(0, BIO) == 0x1A0, "withBiometricsOff(0, 0x1A0) == 0x1A0");
        int once = OwnerKeyguard.withBiometricsOff(0x2, BIO);
        check(OwnerKeyguard.withBiometricsOff(once, BIO) == once, "withBiometricsOff is idempotent");
        check(!OwnerKeyguard.needsWrite(0x1A2, BIO), "needsWrite(0x1A2, 0x1A0) is false (every mask bit set)");
        check(!OwnerKeyguard.needsWrite(0x1A0, BIO), "needsWrite(0x1A0, 0x1A0) is false");
        check(OwnerKeyguard.needsWrite(0x22, BIO), "needsWrite(0x22, 0x1A0) is true (only FINGERPRINT set)");
        check(OwnerKeyguard.needsWrite(0, BIO), "needsWrite(0, 0x1A0) is true");
        System.exit(bad == 0 ? 0 : 1);
    }
}
EOF
  if ! JOUT=$("$JAVAC" -J-Djava.io.tmpdir="$W" -d "$OUTD" "$SRCD/com/nowhere/chooser/OwnerKeyguard.java" \
        "$SRCD/com/nowhere/chooser/OwnerKeyguardDriver.java" 2>&1); then
    printf '%s\n' "$JOUT"
    no "OwnerKeyguard.java does not compile with the driver"
  else
    DOUT=$("$JAVA" -Djava.io.tmpdir="$W" -cp "$OUTD" com.nowhere.chooser.OwnerKeyguardDriver 2>&1); drc=$?
    printf '%s\n' "$DOUT"
    PASS=$((PASS + $(grep -c '^  ok ' <<<"$DOUT")))
    FAIL=$((FAIL + $(grep -c '^  FAIL ' <<<"$DOUT")))
    [ "$drc" = 0 ] || [ "$(grep -c '^  FAIL ' <<<"$DOUT")" != 0 ] || no "the driver exited $drc with no FAIL line"
  fi
fi

echo "== (b) onCreate's device-owner branch sets KEYGUARD_DISABLE_BIOMETRICS, in a try/catch =="
ANCHOR='if (dpm != null && dpm.isDeviceOwnerApp(getPackageName())) {'
CODE=$(sed 's|//.*$||' "$CA")
NANCH=$(grep -cF "$ANCHOR" <<<"$CODE")
if [ "$NANCH" = 1 ]; then
  ok "the device-owner branch anchor occurs once"
else
  no "the device-owner branch anchor occurs $NANCH time(s), not once"
fi
# The branch: from the anchor to the first following line that is exactly 12 spaces and a closing brace.
BRANCH=$(awk -v a="$ANCHOR" 'index($0, a) { on = 1 } on { print } on && /^            }$/ { exit }' <<<"$CODE")
# Inside the branch: the set call, the nearest `try {` before it, the nearest catch after it, and the three
# other lines between them.
TRYOK=$(awk '
  { L[NR] = $0 }
  END {
    s = 0
    for (i = 1; i <= NR; i++) if (index(L[i], "dpm.setKeyguardDisabledFeatures(admin, OwnerKeyguard.withBiometricsOff(cur, mask));")) { s = i; break }
    if (!s) { print "no set call"; exit }
    t = 0; for (i = s - 1; i >= 1; i--) if (L[i] ~ /^[[:space:]]*try \{[[:space:]]*$/) { t = i; break }
    c = 0; for (i = s + 1; i <= NR; i++) if (L[i] ~ /^[[:space:]]*\} catch \(Throwable t\) \{/) { c = i; break }
    if (!t || !c) { print "no enclosing try/catch"; exit }
    r = 0; m = 0; g = 0
    for (i = t + 1; i < c; i++) {
      if (index(L[i], "int cur = dpm.getKeyguardDisabledFeatures(admin);")) r = i
      if (index(L[i], "int mask = android.app.admin.DevicePolicyManager.KEYGUARD_DISABLE_BIOMETRICS;")) m = i
      if (index(L[i], "if (OwnerKeyguard.needsWrite(cur, mask)) {")) g = i
    }
    if (!r) { print "no getKeyguardDisabledFeatures read"; exit }
    if (!m) { print "no KEYGUARD_DISABLE_BIOMETRICS mask"; exit }
    if (!g) { print "no needsWrite guard"; exit }
    if (!(r < m && m < g && g < s)) { print "out of order"; exit }
    print "OK"
  }' <<<"$BRANCH")
if [ "$TRYOK" = OK ]; then
  ok "the branch reads the flags, masks KEYGUARD_DISABLE_BIOMETRICS, guards on needsWrite and sets withBiometricsOff, in one try/catch"
else
  no "the device-owner branch does not set the biometrics flags in a try/catch ($TRYOK)"
fi
NSET=$(grep -c 'setKeyguardDisabledFeatures(' <<<"$CODE")
if [ "$NSET" = 1 ]; then
  ok "ChooserActivity.java calls setKeyguardDisabledFeatures exactly once"
else
  no "ChooserActivity.java calls setKeyguardDisabledFeatures $NSET time(s), not once"
fi

echo "== (c) device_admin.xml declares disable-keyguard-features =="
XOUT=$(python3 -I - "$XML" <<'EOF' 2>&1
import sys, xml.etree.ElementTree as E
path = sys.argv[1]
root = E.parse(path).getroot()  # the default parser drops comments, so a commented-out element is not seen
pol = root.find("uses-policies")
kids = [] if pol is None else [k.tag for k in pol]
for want in ("disable-keyguard-features", "force-lock", "watch-login"):
    print(("ok " if want in kids else "missing ") + want)
text = open(path, encoding="utf-8").read()
print("stale-head" if "needs no explicit policies" in text else "head-ok")
EOF
)
for want in disable-keyguard-features force-lock watch-login; do
  if grep -qxF "ok $want" <<<"$XOUT"; then
    ok "<uses-policies> holds the <$want /> element"
  else
    no "<uses-policies> has no <$want /> element ($(head -1 <<<"$XOUT"))"
  fi
done
if grep -qxF head-ok <<<"$XOUT"; then
  ok 'the head comment no longer says a device owner needs no explicit policies'
else
  no 'the head comment still says a device owner needs no explicit policies'
fi

echo "== (d) the System settings row says what you change there stays on this phone =="
NEW_SUB='"USB debugging, eSIM and more. What you change here stays on this phone, for every profile and after every sign-out.",'
OLD_SUB='"USB debugging, eSIM, and other system settings"'
NNEW=$(grep -cF "$NEW_SUB" <<<"$CODE")
ROWNEXT=$(awk 'index($0, "settingsRow(\"System settings\",") { getline n; print n; exit }' <<<"$CODE")
if [ "$NNEW" = 1 ] && grep -qF "$NEW_SUB" <<<"$ROWNEXT"; then
  ok 'the "System settings" row subtitle says the change stays on this phone'
else
  no 'the "System settings" row does not carry the "stays on this phone" subtitle'
fi
if [ "$(grep -cF "$OLD_SUB" <<<"$CODE")" = 0 ]; then
  ok "the old subtitle is gone"
else
  no "the old subtitle is still there"
fi

echo "== $PASS ok, $FAIL failed =="
[ "$FAIL" = 0 ] || exit 1
[ "$MUTATE" = yes ] || exit 0

echo "== --mutate: each mutant must CONVICT (exit 1) =="
MBAD=0
# mutant <name> <env var> <file> <perl expression>
mutant() {
  local name="$1" var="$2" src="$3" expr="$4" d copy rc out
  d=$(mktemp -d -p "$W"); copy="$d/$(basename "$src")"
  perl -0pe "$expr" "$src" >"$copy" || { echo "  BROKEN     $name (perl failed)"; MBAD=$((MBAD+1)); return; }
  if cmp -s "$src" "$copy"; then echo "  INERT      $name (the edit did not apply)"; MBAD=$((MBAD+1)); return; fi
  out=$(env "$var=$copy" bash "$SELF" 2>&1); rc=$?
  if [ "$rc" = 1 ]; then
    echo "  CONVICTED  $name"
  else
    echo "  SURVIVED   $name (exit $rc)"; printf '%s\n' "$out" | tail -5; MBAD=$((MBAD+1))
  fi
}
mutant "M1 withBiometricsOff returns the mask alone" NWP_OB_OK "$OK" \
  's/return current \| biometricsMask;/return biometricsMask;/'
mutant "M2 needsWrite always false" NWP_OB_OK "$OK" \
  's/return \(current & biometricsMask\) != biometricsMask;/return false;/'
mutant "M3 the call moved outside the isDeviceOwnerApp branch" NWP_OB_CA "$CA" \
  's/(\n[ ]+\/\/ NWP-20261114-12 \(docs.*?"NWP-20261114-12 keyguard biometrics off \(DO\)", t\);\n[ ]+\}\n)(            \}\n        \} catch \(Throwable t\) \{\n            android\.util\.Log\.w\("NowhereChooser", "clearAffiliationIds", t\);\n        \}\n)/\n$2$1/s'
mutant "M4 FINGERPRINT in place of BIOMETRICS" NWP_OB_CA "$CA" \
  's/DevicePolicyManager\.KEYGUARD_DISABLE_BIOMETRICS;/DevicePolicyManager.KEYGUARD_DISABLE_FINGERPRINT;/'
mutant "M5 the disable-keyguard-features element removed" NWP_OB_XML "$XML" \
  's/^[ ]*<disable-keyguard-features \/>\n//m'
mutant "M6 the element left only inside a comment" NWP_OB_XML "$XML" \
  's/<disable-keyguard-features \/>/<!-- <disable-keyguard-features \/> -->/'
mutant "M7 the subtitle sentence removed" NWP_OB_CA "$CA" \
  's/"USB debugging, eSIM and more\. What you change here stays on this phone, for every profile and after every sign-out\."/"USB debugging, eSIM and more."/'
if [ "$MBAD" = 0 ]; then echo "== every mutant CONVICTED =="; exit 0; fi
echo "== $MBAD mutant(s) not convicted =="; exit 1
