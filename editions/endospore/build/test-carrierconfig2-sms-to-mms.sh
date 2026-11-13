#!/usr/bin/env bash
# test-carrierconfig2-sms-to-mms.sh [--mutate] -- NWP-20261130-15.
#
# WHY THIS IS COMMITTED. patches/carrierconfig2-sms-to-mms.sh edits GrapheneOS's CarrierConfig2 so the bundle that
# CarrierServiceImpl.onLoadConfig returns carries smsToMmsTextThreshold 7 and smsToMmsTextLengthThreshold 1071 for
# every carrier that does not set them. build-device.sh applies it to every Endospore build through its patches glob,
# and off the device only this suite reads what it inserts. Its failures are silent: an anchor that stops matching
# leaves long texts as one multipart SMS that times out, and a helper that overrides a carrier's own value or drops a
# key builds and boots without a sign.
# The fixture is the real CarrierServiceImpl.java, copied verbatim from GrapheneOS branch 17
# (packages/apps/CarrierConfig2/src/app/grapheneos/carrierconfig2/CarrierServiceImpl.java, read 2026-11-07). The
# expected helper block is written out below, by hand, independently of the script. The suite pins:
#   (A1) pristine -> exit 0; (A2) the file equals the pristine one plus exactly the expected helper and the wrapped
#        return (nothing else changed); (A3) stdout names the patched file and both keys with 7 and 1071; (A4) both
#        key constants and both values once each; (A5) the PATCH_VERSION stamp once;
#   (B1) a re-run -> exit 0, `already patched`; (B2) byte-identical;
#   (C1) an OLDER copy (PATCH_VERSION 1) -> exit 3; (C2) stderr holds the revert command; (C3) byte-identical;
#   (D1) the loader return drifted -> exit 2; (D2) the return twice -> exit 2; (D3) the class line drifted -> exit 2;
#   (D4) the only return lies in ANOTHER method -> exit 2; each byte-identical; (D5) the file missing -> exit 1;
#   (E1-E6) the inserted helper, lifted from the patched file and run under javac against stubs: an empty bundle gets
#        7 and 1071; a carrier's explicit -1, 0 and a wrong-typed value are kept, never filled; a carrier's own 5 / 800
#        are kept; each key is judged on its own (one key absent, the other an explicit -1 or 0); a null bundle becomes one with 7 and 1071; other keys survive and the log literal is written;
#   (F1) patch-markers.tsv's need literal is in the patched file and its control literal is in the stock fixture.
# Synthetic trees only: that the anchors still match the real GrapheneOS file is the build host's to check (the
# register in docs/framework-patches.md says how). The patch runs on the build host under bash, never on the device,
# so no case runs under dash or mksh. CI runs this suite and its --mutate run. Needs python3, javac and java.
#
#   bash test-carrierconfig2-sms-to-mms.sh            # the cases
#   bash test-carrierconfig2-sms-to-mms.sh --mutate   # ... plus mutants of the script that must each CONVICT the named case
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
for c in python3 javac java; do command -v "$c" >/dev/null || { echo "$c not found: this suite needs it" >&2; exit 2; }; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SCRIPT0="$REPO/editions/endospore/build/patches/carrierconfig2-sms-to-mms.sh"
TSV="$REPO/editions/endospore/build/patch-markers.tsv"
CC2_REL=packages/apps/CarrierConfig2
SRC_REL=src/app/grapheneos/carrierconfig2/CarrierServiceImpl.java
F_REL="$CC2_REL/$SRC_REL"
STAMP='nowhere-cc2-sms-to-mms PATCH_VERSION 2 (NWP-20261130-15)'

# --- fixtures, written once ---------------------------------------------------------------------------------------
FIX=$(mktemp -d -p "$W") || exit 2
# The real file, verbatim from GrapheneOS branch 17.
cat > "$FIX/pristine" <<'JAVA'
package app.grapheneos.carrierconfig2;

import android.annotation.Nullable;
import android.content.Context;
import android.os.PersistableBundle;
import android.service.carrier.CarrierIdentifier;
import android.service.carrier.CarrierService;
import android.util.Log;

import app.grapheneos.carrierconfig2.loader.CSettingsDir;
import app.grapheneos.carrierconfig2.loader.CarrierConfigLoader;
import app.grapheneos.carrierconfig2.loader.CarrierIdentifierExt;

public class CarrierServiceImpl extends CarrierService {
    static final String TAG = CarrierServiceImpl.class.getSimpleName();

    @Nullable
    @Override
    public PersistableBundle onLoadConfig(int subId, @Nullable CarrierIdentifier carrierId) {
        Log.d(TAG, "subId " + subId + "; carrierId " + carrierId);

        var csd = CSettingsDir.getDefault();
        if (csd == null) {
            Log.e(TAG, "missing CSettingsDir");
            return null;
        }

        Context ctx = getApplicationContext();

        CarrierIdentifierExt carrierIdExt = null;
        if (carrierId != null) {
            carrierIdExt = new CarrierIdentifierExt(carrierId, Utils.getIccid(ctx, subId));
        }

        return new CarrierConfigLoader(ctx, csd).load(carrierIdExt);
    }

    @Override
    public PersistableBundle onLoadConfig(CarrierIdentifier id) {
        // this method is deprecated and should never be called by the OS
        throw new IllegalStateException(String.valueOf(id));
    }
}
JAVA
# The helper the patch must insert after the class line, written out independently of the script.
cat > "$FIX/helper" <<'JAVA'

    // nowhere-cc2-sms-to-mms PATCH_VERSION 2 (NWP-20261130-15): no CarrierSettings entry turns a long text into an
    // MMS, and the platform default of both thresholds is -1 (never convert), so AOSP Messaging sent a 19-part text as
    // one multipart SMS that timed out before the radio (lynx 2026110402, 2026-11-06). Fill each threshold that the
    // bundle does not hold; every value a carrier supplies is kept, an explicit 0 or -1 (never convert) included.
    private static final int NOWHERE_SMS_TO_MMS_PARTS = 7;
    // 7 parts x 153 GSM-7 characters per concatenated part.
    private static final int NOWHERE_SMS_TO_MMS_LENGTH = 1071;

    private static PersistableBundle nowhereSmsToMms(@Nullable PersistableBundle b) {
        if (b == null) {
            b = new PersistableBundle();
        }
        boolean parts = nowhereFillUnset(b,
                android.telephony.CarrierConfigManager.KEY_MMS_SMS_TO_MMS_TEXT_THRESHOLD_INT,
                NOWHERE_SMS_TO_MMS_PARTS);
        boolean length = nowhereFillUnset(b,
                android.telephony.CarrierConfigManager.KEY_MMS_SMS_TO_MMS_TEXT_LENGTH_THRESHOLD_INT,
                NOWHERE_SMS_TO_MMS_LENGTH);
        Log.i(TAG, "nowhere: sms-to-mms thresholds (NWP-20261130-15): parts "
                + (parts ? "set " : "carrier ")
                + b.getInt(android.telephony.CarrierConfigManager.KEY_MMS_SMS_TO_MMS_TEXT_THRESHOLD_INT)
                + ", length " + (length ? "set " : "carrier ")
                + b.getInt(android.telephony.CarrierConfigManager.KEY_MMS_SMS_TO_MMS_TEXT_LENGTH_THRESHOLD_INT));
        return b;
    }

    private static boolean nowhereFillUnset(PersistableBundle b, String key, int value) {
        if (b.containsKey(key)) {
            return false;
        }
        b.putInt(key, value);
        return true;
    }
JAVA
python3 -I - "$FIX" "$STAMP" <<'PY' || exit 2
import sys
fix, stamp = sys.argv[1], sys.argv[2]
def fail(msg):
    print("FIXTURE FAILED: " + msg, file=sys.stderr); sys.exit(2)
def rd(n): return open(fix + "/" + n, encoding="utf-8", newline="").read()
def put(n, t): open(fix + "/" + n, "w", encoding="utf-8", newline="").write(t)
pristine, helper = rd("pristine"), rd("helper")
A = "public class CarrierServiceImpl extends CarrierService {\n"
B = "        return new CarrierConfigLoader(ctx, csd).load(carrierIdExt);\n"
WR = "        return nowhereSmsToMms(new CarrierConfigLoader(ctx, csd).load(carrierIdExt));\n"
THROW = "        throw new IllegalStateException(String.valueOf(id));\n"
if pristine.count(A) != 1 or pristine.count(B) != 1 or pristine.count(THROW) != 1:
    fail("the fixture does not hold each anchor once")
if "nowhere" in pristine or "NWP-" in pristine: fail("the fixture is not pristine")
if helper.count(stamp) != 1: fail("the expected helper does not carry the stamp once")
expected = pristine.replace(A, A + helper, 1).replace(B, WR, 1)
put("expected", expected)
put("older", expected.replace(stamp, stamp.replace("PATCH_VERSION 2", "PATCH_VERSION 1"), 1))
put("drift_b", pristine.replace(B, B.replace("load(carrierIdExt)", "load(carrierIdExt, ctx)"), 1))
put("dup_b", pristine.replace(THROW, B + THROW, 1))
put("drift_a", pristine.replace(A, A.replace("extends CarrierService {", "extends CarrierService implements Foo {"), 1))
put("outside", pristine.replace(B, "        return null;\n", 1).replace(THROW, B + THROW, 1))
for n in ("older", "drift_b", "dup_b", "drift_a", "outside"):
    if rd(n) in (pristine, expected): fail("variant %s equals a base fixture" % n)
PY

# Stubs for the javac cases: only what the helper calls, with the real key strings of AOSP CarrierConfigManager.
STUB=$(mktemp -d -p "$W") || exit 2
mkdir -p "$STUB/android/os" "$STUB/android/util" "$STUB/android/annotation" "$STUB/android/telephony"
cat > "$STUB/android/os/PersistableBundle.java" <<'JAVA'
package android.os;

public class PersistableBundle {
    private final java.util.HashMap<String, Object> m = new java.util.HashMap<>();
    public int getInt(String k) { return getInt(k, 0); }
    // As the real BaseBundle: a missing key or a value of another type returns the default.
    public int getInt(String k, int d) { Object o = m.get(k); return o instanceof Integer ? (Integer) o : d; }
    public Object get(String k) { return m.get(k); }
    public void putInt(String k, int v) { m.put(k, v); }
    public void putString(String k, String v) { m.put(k, v); }
    public String getString(String k) { Object o = m.get(k); return o instanceof String ? (String) o : null; }
    public boolean containsKey(String k) { return m.containsKey(k); }
}
JAVA
cat > "$STUB/android/util/Log.java" <<'JAVA'
package android.util;

public final class Log {
    public static final java.util.List<String> LINES = new java.util.ArrayList<>();
    public static int i(String tag, String msg) { LINES.add(tag + ": " + msg); return 0; }
}
JAVA
cat > "$STUB/android/annotation/Nullable.java" <<'JAVA'
package android.annotation;

public @interface Nullable {}
JAVA
cat > "$STUB/android/telephony/CarrierConfigManager.java" <<'JAVA'
package android.telephony;

public class CarrierConfigManager {
    public static final String KEY_MMS_SMS_TO_MMS_TEXT_THRESHOLD_INT = "smsToMmsTextThreshold";
    public static final String KEY_MMS_SMS_TO_MMS_TEXT_LENGTH_THRESHOLD_INT = "smsToMmsTextLengthThreshold";
}
JAVA
# The cases' main; the lifted helper is pasted where HELPER stands.
cat > "$STUB/T.head" <<'JAVA'
import android.annotation.Nullable;
import android.os.PersistableBundle;
import android.util.Log;

public class T {
    static final String TAG = "CarrierServiceImpl";
JAVA
cat > "$STUB/T.tail" <<'JAVA'

    static final String P = "smsToMmsTextThreshold", L = "smsToMmsTextLengthThreshold";

    static void check(String id, boolean ok, String what) {
        System.out.println((ok ? "ok " : "FAIL ") + id + " " + what);
    }

    interface Case { void run(); }

    static void guard(String id, Case c) {
        try { c.run(); } catch (Throwable t) { check(id, false, "threw " + t); }
    }

    static boolean is(PersistableBundle b, int p, int l) {
        return b != null && b.getInt(P, -99) == p && b.getInt(L, -99) == l;
    }

    public static void main(String[] a) {
        guard("E1", () -> check("E1", is(nowhereSmsToMms(new PersistableBundle()), 7, 1071), "empty bundle -> 7 and 1071"));
        guard("E2", () -> {
            PersistableBundle b = new PersistableBundle(); b.putInt(P, -1); b.putInt(L, -1);
            check("E2", is(nowhereSmsToMms(b), -1, -1), "a carrier's explicit -1 and -1 are kept");
            b = new PersistableBundle(); b.putInt(P, 0); b.putInt(L, 0);
            check("E2", is(nowhereSmsToMms(b), 0, 0), "a carrier's explicit 0 and 0 are kept");
            b = new PersistableBundle(); b.putString(P, "5"); b.putString(L, "800");
            PersistableBundle r = nowhereSmsToMms(b);
            check("E2", "5".equals(r.get(P)) && "800".equals(r.get(L)), "a carrier's values of another type are kept");
        });
        guard("E3", () -> {
            PersistableBundle b = new PersistableBundle(); b.putInt(P, 5); b.putInt(L, 800);
            check("E3", is(nowhereSmsToMms(b), 5, 800), "a carrier's own 5 and 800 are kept");
        });
        guard("E4", () -> {
            PersistableBundle b = new PersistableBundle(); b.putInt(P, 4);
            check("E4", is(nowhereSmsToMms(b), 4, 1071), "parts 4 only -> parts 4 kept, length 1071");
            b = new PersistableBundle(); b.putInt(L, 600);
            check("E4", is(nowhereSmsToMms(b), 7, 600), "length 600 only -> parts 7, length 600 kept");
            b = new PersistableBundle(); b.putInt(P, -1);
            check("E4", is(nowhereSmsToMms(b), -1, 1071), "parts -1 only -> parts -1 kept, length 1071");
            b = new PersistableBundle(); b.putInt(L, 0);
            check("E4", is(nowhereSmsToMms(b), 7, 0), "length 0 only -> parts 7, length 0 kept");
        });
        guard("E5", () -> check("E5", is(nowhereSmsToMms(null), 7, 1071), "null -> a bundle with 7 and 1071"));
        guard("E6", () -> {
            Log.LINES.clear();
            PersistableBundle b = new PersistableBundle(); b.putInt("other_int", 3); b.putString("other_str", "x");
            PersistableBundle r = nowhereSmsToMms(b);
            check("E6", r.getInt("other_int", -1) == 3 && "x".equals(r.getString("other_str")),
                    "other keys survive unchanged");
            check("E6", Log.LINES.size() == 1 && Log.LINES.get(0).startsWith(
                    "CarrierServiceImpl: nowhere: sms-to-mms thresholds (NWP-20261130-15): parts set 7, length set 1071"),
                    "one log line with the literal and the values");
        });
    }
}
JAVA
javac -J-Djava.io.tmpdir="$W" -d "$STUB/classes" \
  "$STUB/android/os/PersistableBundle.java" "$STUB/android/util/Log.java" \
  "$STUB/android/annotation/Nullable.java" "$STUB/android/telephony/CarrierConfigManager.java" \
  || { echo "the stubs do not compile" >&2; exit 2; }

NFAIL=0; OUT_ALL=""; RC=0; OUT=""; ERR=""; SCRIPT="$SCRIPT0"

# mktree <fixture|->: a new tree under $W holding a copy of the fixture as CarrierServiceImpl.java ('-' = absent).
mktree(){
  local t; t=$(mktemp -d -p "$W") || exit 2
  mkdir -p "$t/$(dirname "$F_REL")"
  [ "$1" = - ] || cp "$FIX/$1" "$t/$F_REL"
  printf '%s\n' "$t"
}
# runp <tree>: OUT is stdout, ERR stderr, RC the exit code.
runp(){
  local e; e=$(mktemp -p "$W") || exit 2
  OUT=$(bash "$SCRIPT" "$1" 2>"$e"); RC=$?
  ERR=$(cat "$e"); rm -f "$e"
}
snap(){ local s; s=$(mktemp -p "$W") || exit 2; cp "$1" "$s"; printf '%s\n' "$s"; }
check(){
  local c="$1" d="$2"; shift 2
  if "$@"; then OUT_ALL="$OUT_ALL  ok    ($c) $d"$'\n'; else OUT_ALL="$OUT_ALL  FAIL  ($c) $d"$'\n'; NFAIL=$((NFAIL + 1)); fi
}
rc_is(){ [ "$RC" = "$1" ]; }
has(){ [[ $OUT == *"$1"* ]]; }
err_has(){ [[ $ERR == *"$1"* ]]; }
same(){ cmp -s "$1" "$2"; }
count1(){ python3 -I -c 'import sys; sys.exit(0 if open(sys.argv[1], encoding="utf-8").read().count(sys.argv[2]) == 1 else 1)' "$1" "$2"; }
a3(){ has "patched $1" && has "smsToMmsTextThreshold 7" && has "smsToMmsTextLengthThreshold 1071"; }
tsv_in(){
  python3 -I - "$TSV" "$1" "$2" <<'PY'
import sys
tsv, kind, f = sys.argv[1:4]
rows = [l.rstrip("\n").split("\t") for l in open(tsv, encoding="utf-8") if l.strip() and not l.startswith("#")]
want = [r[3] for r in rows if len(r) == 4 and r[0] == "carrierconfig2-sms-to-mms.sh" and r[2] == kind]
s = open(f, encoding="utf-8").read()
sys.exit(0 if want and all(n in s for n in want) else 1)
PY
}
# java_cases <patched file>: lift the helper (the text between the class line and the TAG field), compile it into T
# beside the stubs and run it. Each output line `ok|FAIL <id> <what>` becomes one check.
java_cases(){
  local f="$1" d line id rest
  d=$(mktemp -d -p "$W") || exit 2
  if ! python3 -I - "$f" "$STUB/T.head" "$STUB/T.tail" "$d/T.java" <<'PY'
import sys
f, head, tail, out = sys.argv[1:5]
s = open(f, encoding="utf-8").read()
A = "public class CarrierServiceImpl extends CarrierService {\n"
E = "    static final String TAG = CarrierServiceImpl.class.getSimpleName();\n"
if s.count(A) != 1 or s.count(E) != 1 or s.index(A) > s.index(E): sys.exit(1)
helper = s[s.index(A) + len(A):s.index(E)]
open(out, "w", encoding="utf-8").write(open(head).read() + helper + open(tail).read())
PY
  then check E1 "the helper could not be lifted from the patched file" false; return; fi
  if ! javac -J-Djava.io.tmpdir="$W" -cp "$STUB/classes" -d "$d" "$d/T.java" >"$d/javac.out" 2>&1; then
    check E1 "the lifted helper compiles" false; return
  fi
  local res; res=$(java -Djava.io.tmpdir="$W" -cp "$STUB/classes:$d" T 2>&1)
  [ -n "$res" ] || { check E1 "the Java cases printed nothing" false; return; }
  while IFS= read -r line; do
    case "$line" in
      "ok "*) rest=${line#ok }; id=${rest%% *}; check "$id" "${rest#* }" true ;;
      "FAIL "*) rest=${line#FAIL }; id=${rest%% *}; check "$id" "${rest#* }" false ;;
      *) check E1 "unexpected Java output: $line" false ;;
    esac
  done <<< "$res"
}

run_checks(){
  NFAIL=0; OUT_ALL=""
  local t F F1 v id fx
  # (A) pristine
  t=$(mktree pristine); F="$t/$F_REL"
  runp "$t"
  check A1 "pristine: exit 0" rc_is 0
  check A2 "the file is the pristine one plus exactly the expected helper and wrapped return" same "$F" "$FIX/expected"
  check A3 "stdout names the patched file and both keys with 7 and 1071" a3 "$F"
  check A4 "KEY_MMS_SMS_TO_MMS_TEXT_THRESHOLD_INT once" count1 "$F" "CarrierConfigManager.KEY_MMS_SMS_TO_MMS_TEXT_THRESHOLD_INT,"
  check A4 "KEY_MMS_SMS_TO_MMS_TEXT_LENGTH_THRESHOLD_INT once" count1 "$F" "CarrierConfigManager.KEY_MMS_SMS_TO_MMS_TEXT_LENGTH_THRESHOLD_INT,"
  check A4 "NOWHERE_SMS_TO_MMS_PARTS = 7; once" count1 "$F" "NOWHERE_SMS_TO_MMS_PARTS = 7;"
  check A4 "NOWHERE_SMS_TO_MMS_LENGTH = 1071; once" count1 "$F" "NOWHERE_SMS_TO_MMS_LENGTH = 1071;"
  check A5 "the PATCH_VERSION 2 stamp once" count1 "$F" "$STAMP"
  # (E) the helper under javac
  java_cases "$F"
  # (F) the marker table's literals
  check F1 "patch-markers.tsv's need literal is in the patched file" tsv_in need "$F"
  check F1 "patch-markers.tsv's control literal is in the stock file" tsv_in control "$FIX/pristine"
  # (B) re-run
  F1=$(snap "$F")
  runp "$t"
  check B1 "re-run: exit 0" rc_is 0
  check B1 "re-run says already patched" has "already patched"
  check B2 "re-run: byte-identical" same "$F" "$F1"
  # (C) an older copy of the patch
  t=$(mktree older); F="$t/$F_REL"
  runp "$t"
  check C1 "older copy: exit 3" rc_is 3
  check C2 "older copy: stderr holds the revert command" \
    err_has "git -C \"$t/$CC2_REL\" checkout -- $SRC_REL"
  check C3 "older copy: byte-identical" same "$F" "$FIX/older"
  # (D1-D4) anchor refusals
  for v in D1:drift_b D2:dup_b D3:drift_a D4:outside; do
    id=${v%%:*}; fx=${v#*:}
    t=$(mktree "$fx"); F="$t/$F_REL"
    runp "$t"
    check "$id" "$fx: exit 2" rc_is 2
    check "$id" "$fx: says aborting" err_has "aborting"
    check "$id" "$fx: byte-identical" same "$F" "$FIX/$fx"
  done
  # (D5) the file missing
  t=$(mktree -)
  runp "$t"
  check D5 "CarrierServiceImpl.java absent: exit 1" rc_is 1
  check D5 "CarrierServiceImpl.java absent: says MISSING" err_has MISSING
  check D5 "CarrierServiceImpl.java absent: nothing written" bash -c '[ ! -e "$1" ]' _ "$t/$F_REL"
}

python3 --version
SCRIPT="$SCRIPT0"; run_checks
printf '%s' "$OUT_ALL"
echo "== $(printf '%s' "$OUT_ALL" | grep -c '^  ok') passed, $NFAIL failed"
[ "$NFAIL" = 0 ] || exit 1
[ "$MUTATE" = yes ] || exit 0

LOST=0; NMUT=0
# mutant <id> <convicting case> <old> <new>
mutant(){
  local id="$1" case_="$2" old="$3" new="$4" m; m=$(mktemp -p "$W") || exit 2
  NMUT=$((NMUT + 1))
  if ! python3 -I - "$SCRIPT0" "$m" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src, encoding="utf-8", newline="").read()
if s.count(old) != 1 or old == new:
    sys.exit(1)
open(dst, "w", encoding="utf-8", newline="").write(s.replace(old, new, 1))
PY
  then echo "  FAIL  mutant did not apply: $id"; LOST=$((LOST + 1)); rm -f "$m"; return; fi
  cmp -s "$SCRIPT0" "$m" && { echo "  FAIL  mutant $id changed nothing"; LOST=$((LOST + 1)); rm -f "$m"; return; }
  SCRIPT="$m"; run_checks
  if [[ $OUT_ALL == *"  FAIL  ($case_)"* ]]; then echo "  ok    CONVICTED $id by ($case_)"
  else echo "  FAIL  NOT convicted: $id (expected a failure in ($case_))"; printf '%s' "$OUT_ALL"; LOST=$((LOST + 1)); fi
  rm -f "$m"
}
echo "== mutants"
mutant M1-drop-parts-key E1 'boolean parts = nowhereFillUnset(b,
                android.telephony.CarrierConfigManager.KEY_MMS_SMS_TO_MMS_TEXT_THRESHOLD_INT,
                NOWHERE_SMS_TO_MMS_PARTS);' 'boolean parts = true;'
mutant M2-drop-length-key E1 'boolean length = nowhereFillUnset(b,
                android.telephony.CarrierConfigManager.KEY_MMS_SMS_TO_MMS_TEXT_LENGTH_THRESHOLD_INT,
                NOWHERE_SMS_TO_MMS_LENGTH);' 'boolean length = true;'
mutant M3-wrong-parts-value A4 'NOWHERE_SMS_TO_MMS_PARTS = 7;' 'NOWHERE_SMS_TO_MMS_PARTS = 6;'
mutant M4-wrong-length-value A4 'NOWHERE_SMS_TO_MMS_LENGTH = 1071;' 'NOWHERE_SMS_TO_MMS_LENGTH = 1070;'
mutant M5-skip-the-version-guard C1 '    sys.exit(3)' '    sys.exit(0)'
mutant M6-no-revert-hint C2 "    print(REVERT, file=sys.stderr)
    print('Refusing" "    print('Refusing"
mutant M7-silent-no-op-on-missing-anchor D1 '    if s.count(a) != 1:
        die(2,' '    if s.count(a) != 1:
        sys.exit(0); die(2,'
mutant M8-no-method-check D4 'if not (start < s.index(ANCHOR_B) < end):' 'if False:'
mutant M9-override-a-carrier-value E3 'if (b.containsKey(key)) {' 'if (false) {'
mutant M13-override-an-explicit-disable E2 'if (b.containsKey(key)) {' 'if (b.getInt(key, -1) > 0) {'
mutant M10-no-null-handling E5 '        if (b == null) {
            b = new PersistableBundle();
        }
' ''
mutant M11-log-line-drops-the-file A3 "'%s patched %s: smsToMms" "'%s patched%.0s: smsToMms"
mutant M12-missing-target-exits-0 D5 'MISSING $F" >&2; exit 1; }' 'MISSING $F" >&2; exit 0; }'
[ "$LOST" = 0 ] || { echo "== $LOST of $NMUT mutant(s) not convicted"; exit 1; }
echo "== mutants: $NMUT/$NMUT convicted"
