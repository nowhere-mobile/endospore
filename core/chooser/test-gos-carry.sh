#!/usr/bin/env bash
# test-gos-carry.sh [--mutate] -- GosState's apply-receipt rule and carry-forward decision, run under javac
# (NWP-20261017-15).
#
# WHY THIS IS COMMITTED. GosState carries GrapheneOS per-app hardening flags across a roam. A denied read returns NONE
# exactly like "no state", so its invariant is A SEALED ROW MAY ONLY BE DROPPED AGAINST A POSITIVE APPLY RECEIPT:
# without it an image missing gos-chooser-grant.sh would read nothing, write an empty file and destroy every setting on
# the first logoff. A regression in the receipt text, its parse, the live test or the per-package branch resets every
# roamed flag and still logs a success line. The rules are the Context-free statics between the "pure rules" markers in
# core/chooser/src/com/nowhere/chooser/GosState.java (MASK included); they are compiled as they stand with
# core/chooser/tests/gos-carry/GosCarryCases.java. `m NowhereChooser` is the compile check of the rest.
#
# NWP-20261111-05: the carry file is read strictly (GosState.readRows: absent is empty, present-but-unreadable throws;
# parseRows propagates a mid-read IOException), and apply/capture refuse an unreadable file: apply writes a receipt
# that is not live, capture returns before liveFor. Cases R1-R4 pin the read; checks() below pins the call sites and
# the refusals by source, and runs on $SRC AND on every mutant copy, so a mutant outside the lifted region is
# convicted by source. A mutant is convicted ONLY by a failed case (run.sh rc 1) or a failed check; a mutant that does
# not compile (rc 3) or loses the markers (rc 4) is BROKEN, which fails the suite. Every temp lives under one root, $W.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-gos-carry.sh            # the cases
#   bash test-gos-carry.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT; export W

here=$(cd "$(dirname "$0")" && pwd)
SRC="$here/src/com/nowhere/chooser/GosState.java"
RUN="$here/tests/gos-carry/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 1
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 1; }
for f in "$SRC" "$RUN" "$here/tests/gos-carry/GosCarryCases.java"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }; done

# checks <GosState.java> -> 0 when every call-site pin and source check holds. The call sites are pinned too: a correct
# rule called wrongly is the same bug. Runs on $SRC and on every mutant copy (NWP-20261111-05).
checks() {
  local f="$1" body bad=0 pin
  body=$(cat "$f")
  for pin in \
    'boolean live = liveFor(receipt.live, old);' \
    'Carried res = carry(old, receipt.applied, cand,' \
    'write(f, rowsText(out));' \
    'write(new File(ctx.getFilesDir(), RECEIPT), receiptText(want.isEmpty(), ok, landedPkgs));' \
    'return parseRows(r);' \
    'return parseReceipt(r);'; do
    [[ "$body" == *"$pin"* ]] || { echo "  PIN   gone from GosState.java: $pin" >&2; bad=1; }
  done
  # The refusals, on the source with comments stripped: the IOException catch around readRows in apply and capture.
  python3 - "$f" <<'PY' || bad=1
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
s = re.sub(r'//[^\n]*', '', s)
bad = 0
def fail(m):
    global bad
    bad = 1
    print("  SRC   " + m, file=sys.stderr)
def method(name, nxt):
    i = s.find(name)
    j = s.find(nxt, i + 1) if i >= 0 else -1
    return s[i:j] if j > i else ""
def catch_block(body):
    i = body.find("catch (java.io.IOException")
    if i < 0:
        return None, -1
    j = body.find("}", i)  # the catch bodies hold no nested braces
    return body[i:j], i
app = method("static void apply(Context ctx)", "static void capture(Context ctx)")
cap = method("static void capture(Context ctx)", "static final long MASK")
if not app: fail("apply(Context) not found")
if not cap: fail("capture(Context) not found")
if "readRows(" not in cap: fail("capture does not call readRows")
cb, ci = catch_block(cap)
if cb is None or "return;" not in cb: fail("capture's IOException catch does not return")
elif "liveFor(" not in cap or ci > cap.find("liveFor("): fail("capture's catch does not sit before liveFor(")
if "readRows(" not in app: fail("apply does not call readRows")
ab, _ = catch_block(app)
if ab is None or "receiptText(false" not in ab or "return;" not in ab:
    fail("apply's IOException catch does not write receiptText(false and return")
elif "writeMasked(" in ab: fail("apply's IOException catch calls writeMasked")
if re.search(r'catch \(Throwable ignore\) \{ return new java\.util\.LinkedHashMap', s):
    fail("a swallowing carry-file read is still present")
sys.exit(bad)
PY
  return $bad
}
checks "$SRC"; bad=$?

out=$(bash "$RUN" "$SRC" 2>&1); rc=$?
printf '%s\n' "$out"
[ $rc -eq 0 ] && [ $bad -eq 0 ] || { echo "FAILED (cases rc=$rc, pins/source checks bad=$bad)"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo
echo "== mutants: each must be convicted =="
TMP=$(mktemp -d -p "$W") || exit 2
miss=0
# mutant <label> <python3 replace: old> <new>: apply to a copy of GosState.java; a case (run.sh rc 1) or a pin/source
# check must then FAIL. Any other run.sh code (3 no compile, 4 markers gone) is a BROKEN mutant: a failure, never a
# conviction.
mutant() {
  local label="$1" old="$2" new="$3" m="$TMP/GosState.java" o rc crc
  if ! OLD="$old" NEW="$new" python3 - "$SRC" "$m" <<'PY'
import os, sys
s = open(sys.argv[1]).read()
if s.count(os.environ["OLD"]) != 1:
    sys.exit(1)
open(sys.argv[2], "w").write(s.replace(os.environ["OLD"], os.environ["NEW"]))
PY
  then echo "  FAIL  mutant did not apply: $label"; miss=1; return; fi
  o=$(bash "$RUN" "$m" 2>&1); rc=$?
  checks "$m" >/dev/null 2>&1; crc=$?
  case $rc in
    0) if [ $crc -ne 0 ]; then echo "  ok    convicted (source check): $label"
       else echo "  FAIL  mutant SURVIVED: $label"; miss=1; fi ;;
    1) echo "  ok    convicted: $label" ;;
    *) echo "  FAIL  mutant BROKEN (run.sh rc=$rc, not a conviction): $label"; printf '%s\n' "$o" | tail -5; miss=1 ;;
  esac
}
mutant "the applied branch no longer carries an unreadable row" \
  'if (f1 < 0L && old.containsKey(pkg)) { out.put(pkg, old.get(pkg)); carried++; }' \
  'if (false) { carried++; }'
mutant "the not-applied branch drops on read 0" \
  'else if (old.containsKey(pkg)) { out.put(pkg, old.get(pkg)); carried++; }' \
  'else if (f1 < 0L && old.containsKey(pkg)) { out.put(pkg, old.get(pkg)); carried++; }'
mutant "liveFor is live when the receipt is missing" \
  'return old.isEmpty() || receiptLive;' \
  'return true;'
mutant "an empty receipt is written live when the set is non-empty" \
  '(ok > 0 ? "#live\n" : "")' \
  '"#live\n"'
mutant "parseRows stops applying MASK" \
  'Long.parseLong(t[1].trim(), 16) & MASK' \
  'Long.parseLong(t[1].trim(), 16)'
mutant "parseReceipt treats any # line as live" \
  'raw.startsWith("#live")' \
  'raw.startsWith("#")'
mutant "M1 readRows returns empty when the path exists but cannot be opened" \
  '            return parseRows(r);
        }
    }' \
  '            return parseRows(r);
        } catch (java.io.IOException e) { return new java.util.LinkedHashMap<>(); }
    }'
mutant "M2 parseRows swallows a mid-read IOException again" \
  '        String ln;
        while ((ln = r.readLine()) != null) {
            ln = ln.trim();
            if (ln.isEmpty() || ln.startsWith("#")) continue;
            String[] t = ln.split("\t", -1);
            if (t.length < 2 || t[0].isEmpty()) continue;
            try { m.put(t[0], Long.parseLong(t[1].trim(), 16) & MASK); } catch (Throwable ignore) {}
        }
        return m;' \
  '        try {
            String ln;
            while ((ln = r.readLine()) != null) {
                ln = ln.trim();
                if (ln.isEmpty() || ln.startsWith("#")) continue;
                String[] t = ln.split("\t", -1);
                if (t.length < 2 || t[0].isEmpty()) continue;
                try { m.put(t[0], Long.parseLong(t[1].trim(), 16) & MASK); } catch (Throwable ignore) {}
            }
        } catch (java.io.IOException ignore) {}
        return m;'
mutant "M3 capture's catch falls through to liveFor" \
  ' left as they are (NWP-20261111-05)");
                return;' \
  ' left as they are (NWP-20261111-05)");
                old = new java.util.LinkedHashMap<>();'
mutant "M4 apply's catch writes a live receipt" \
  'receiptText(false, 0, java.util.Collections.<String>emptyList())' \
  'receiptText(true, 0, java.util.Collections.<String>emptyList())'
[ $miss -eq 0 ] || { echo "FAILED: a mutant survived or was broken"; exit 1; }
echo PASS
