#!/usr/bin/env bash
# test-tel-dedup.sh [<chooser src dir>] [--mutate] -- a resent text is found in Messages, not shown twice
# (NWP-20261006-07).
#
# WHY THIS IS COMMITTED. Since NWP-20261006-05 a delivered row keeps its sealed copy until the chooser acknowledges
# inserting it, and an unacknowledged copy is delivered again at the profile's next sign-in. A text inserted whose
# acknowledgement was lost therefore comes back. Calls were always safe (the call log reads back), but the chooser
# could not read its own Messages (READ_SMS was ceded to the default SMS app), so the text showed twice. The fix is
# three small pieces, any of which a later edit can drop without breaking a build: the READ_SMS grant at the start of
# a delivery run, the SMS existence check before the insert, and the MMS message id that names a delivery (an MMS
# date is in seconds, too coarse to find one message). The chooser has no unit-test harness, so these are
# source-level checks: the new methods are PINNED BYTE FOR BYTE, comments included, and the call sites are checked
# by line and order.
#
# NWP-20261112-21: a lookup that did not complete is UNKNOWN, never "absent". exists() and mmsExists() answered false
# for a null cursor and for any throw, so a query that failed while the providers churn at sign-in read as "no such
# row": a call inserted on pass 1 was inserted again on pass 2, and a text redelivered after a lost acknowledgement was
# inserted again when its first lookup threw. They now answer TRUE, FALSE or null; rowStep() maps null to RETRY, so
# deliver()/deliverMms() insert nothing on it, and a call is acknowledged only on a completed lookup that found it.
# The post-insert read-back goes through readBack(), which counts an unknown answer like every other lookup site and
# accepts only TRUE. rowStep and readBack are lifted and RUN under javac, so this suite needs a JDK and FAILS (exit 2) without one -- a suite that
# skips would read green on a runner that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
#   bash test-tel-dedup.sh            # the invariants
#   bash test-tel-dedup.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# Exit: 0 pass, 1 a check failed, 2 setup (no file, no JDK, no perl).
set -uo pipefail

MUTATE=no; SRC=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
SRC="${SRC:-$(dirname "$0")/src/com/nowhere/chooser}"
TI="$SRC/TelIngest.java"
[ -f "$TI" ] || { echo "no such file: $TI" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-tel-dedup: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-tel-dedup: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# body <file> <signature fragment>: the method's lines, from its signature to the first line closing it at the class's
# method indent ("    }"), or the signature line alone for a one-line method -- or a marker that fails every pin
# when the signature does not occur exactly once.
body(){
  [ "$(grep -cF -- "$2" "$1")" = 1 ] || { echo "<signature not exactly once: $2>"; return; }
  awk -v sig="$2" 'index($0, sig) { on = 1; print; if ($0 ~ /}$/) exit; next } on { print } on && /^    }$/ { exit }' "$1"
}
pin(){ if [ "$2" = "$3" ]; then ok "$1 is the pinned block"; else no "$1 differs from the pinned block"; fi; }
# line <file> <exact text>: the line number of the one line that is exactly this text (leading spaces kept), or 0.
line(){ local n; n=$(grep -nxF -- "$2" "$1" | cut -d: -f1); [ "$(printf '%s\n' "$n" | grep -c .)" = 1 ] && echo "$n" || echo 0; }
# bline <text> <exact line>: the same, inside a block of text (a method's body) rather than a file.
bline(){ local n; n=$(printf '%s\n' "$1" | grep -nxF -- "$2" | cut -d: -f1); [ "$(printf '%s\n' "$n" | grep -c .)" = 1 ] && echo "$n" || echo 0; }
# bpre <text> <line prefix>: the line number of the one line in the block that starts with this text, or 0.
bpre(){ local n; n=$(printf '%s\n' "$1" | awk -v p="$2" 'index($0, p) == 1 { print NR }'); [ "$(printf '%s\n' "$n" | grep -c .)" = 1 ] && echo "$n" || echo 0; }
# inorder <what> <n1> <n2> ...: ok when every number is > 0 and each is less than the next.
inorder(){
  local what=$1 prev=0 k; shift
  for k in "$@"; do
    if [ "$k" -le 0 ] || [ "$k" -le "$prev" ]; then no "$what (lines: $*)"; return; fi
    prev=$k
  done
  ok "$what"
}

echo "== the pinned blocks (byte for byte, comments included) =="
pin "ensureSmsRead" "$(body "$TI" 'private static void ensureSmsRead(Context ctx)')" "$(cat <<'PIN'
    private static void ensureSmsRead(Context ctx) {
        try {
            android.app.admin.DevicePolicyManager dpm = ctx.getSystemService(android.app.admin.DevicePolicyManager.class);
            if (dpm != null) {
                dpm.setPermissionGrantState(new android.content.ComponentName(ctx, AdminReceiver.class),
                        ctx.getPackageName(), android.Manifest.permission.READ_SMS,
                        android.app.admin.DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED);
            }
        } catch (Throwable t) { android.util.Log.w("NowhereChooser", "telingest grant READ_SMS", t); }
        try {
            android.app.AppOpsManager ao = ctx.getSystemService(android.app.AppOpsManager.class);
            if (ao != null) {
                ao.setMode(android.app.AppOpsManager.strOpToOp(android.app.AppOpsManager.OPSTR_READ_SMS),
                        android.os.Process.myUid(), ctx.getPackageName(), android.app.AppOpsManager.MODE_ALLOWED);
            }
        } catch (Throwable t) { android.util.Log.w("NowhereChooser", "telingest ensure READ_SMS op", t); }
    }
PIN
)"
pin "mmsKey" "$(body "$TI" 'private static String mmsKey(long when)')" "$(cat <<'PIN'
    private static String mmsKey(long when) { return "nowhere:" + when; }
PIN
)"
pin "mmsExists" "$(body "$TI" 'private static Boolean mmsExists(Context ctx, long when)')" "$(cat <<'PIN'
    private static Boolean mmsExists(Context ctx, long when) {
        try (Cursor c = ctx.getContentResolver().query(Uri.parse("content://mms"), new String[]{"_id"},
                "m_id=?", new String[]{mmsKey(when)}, null)) {
            if (c == null) return null;
            return c.moveToFirst();
        } catch (Throwable t) {
            return null;
        }
    }
PIN
)"
pin "exists" "$(body "$TI" 'private static Boolean exists(Context ctx, Uri uri, long when)')" "$(cat <<'PIN'
    private static Boolean exists(Context ctx, Uri uri, long when) {
        try (Cursor c = ctx.getContentResolver().query(uri, new String[]{"_id"},
                "date=?", new String[]{Long.toString(when)}, null)) {
            if (c == null) return null;
            return c.moveToFirst();
        } catch (Throwable t) {
            return null;
        }
    }
PIN
)"
pin "rowStep" "$(body "$TI" 'static int rowStep(Boolean present)')" "$(cat <<'PIN'
    static int rowStep(Boolean present) {
        if (Boolean.TRUE.equals(present)) return DONE;
        if (Boolean.FALSE.equals(present)) return INSERT;
        return RETRY;
    }
PIN
)"
for c in 'DONE = 0;' 'INSERT = 1;' 'RETRY = 2;'; do
  if [ "$(grep -c "^    static final int $c" "$TI")" = 1 ]; then ok "the constant $c is declared once"
  else no "the constant $c is not declared exactly once"; fi
done

echo "== the call sites, in order =="
GRANT=$(line "$TI" '        ensureSmsRead(ctx);      // NWP-20261006-07: so a resent text is found in Messages, not inserted twice.')
PASSES=$(line "$TI" '        for (int pass = 0; pass < passes; pass++) {')
if [ "$GRANT" -gt 0 ] && [ "$PASSES" -gt 0 ] && [ "$GRANT" -lt "$PASSES" ]; then
  ok "a delivery run grants the read before its first pass (line $GRANT < $PASSES)"
else
  no "the READ_SMS grant is missing or runs after the passes start (grant $GRANT, passes $PASSES) -- the check below reads blind"
fi
# deliver(): the SMS dedup short-circuit, then the lookup through rowStep, DONE returns, anything but INSERT returns
# false without inserting (NWP-20261112-21), and only then the insert.
DB=$(body "$TI" 'private static boolean deliver(')
SSHORT=$(bline "$DB" '            if (!isCall && insertedThisRun.contains(when)) return true; // SMS dedup')
SCHK=$(bline "$DB" '            int step = rowStep(exists(ctx, uri, when));')
SDONE=$(bline "$DB" '            if (step == DONE) return true; // present: fresh dedup, or confirmed-persisted on a re-verify pass')
SUNK=$(bline "$DB" '            if (step != INSERT) { unknown[0]++; return false; } // NWP-20261112-21: unknown -- insert nothing, ask again later')
SINS=$(bline "$DB" '            Uri ins = ctx.getContentResolver().insert(uri, v);')
inorder "an SMS or call is looked up through rowStep and inserted only on INSERT (dedup $SSHORT < lookup $SCHK < DONE $SDONE < not-INSERT $SUNK < insert $SINS) -- a resent text or a re-checked call is inserted twice otherwise" \
  "$SSHORT" "$SCHK" "$SDONE" "$SUNK" "$SINS"
if [ "$(bline "$DB" '            boolean ok = ins != null || readBack(exists(ctx, uri, when), unknown); // read back only on a null result')" -gt "$SINS" ] && [ "$SINS" -gt 0 ]; then
  ok "after the insert, only a lookup that found the row stands in for a null insert result, and an unknown one counts"
else
  no "the post-insert fallback is not 'ins != null || readBack(exists(...), unknown)' after the insert"
fi
# deliverMms(): the same, through mmsExists.
MB=$(body "$TI" 'private static boolean deliverMms(')
MCHK=$(bline "$MB" '            int step = rowStep(mmsExists(ctx, when));')
MDONE=$(bline "$MB" '            if (step == DONE) return true;')
MUNK=$(bline "$MB" '            if (step != INSERT) { unknown[0]++; return false; } // NWP-20261112-21: unknown -- insert nothing, ask again later')
MINS=$(bline "$MB" '            Uri mmsUri = ctx.getContentResolver().insert(Uri.parse("content://mms"), pdu);')
inorder "an MMS is looked up through rowStep and inserted only on INSERT (lookup $MCHK < DONE $MDONE < not-INSERT $MUNK < insert $MINS) -- a resent MMS shows twice otherwise" \
  "$MCHK" "$MDONE" "$MUNK" "$MINS"
MSTAMP=$(line "$TI" '            pdu.put("m_id", mmsKey(when)); // NWP-20261006-07: names this delivery, so a redelivery finds it (mmsExists)')
MINS=$(line "$TI" '            Uri mmsUri = ctx.getContentResolver().insert(Uri.parse("content://mms"), pdu);')
if [ "$MSTAMP" -gt 0 ] && [ "$MINS" -gt 0 ] && [ "$MSTAMP" -lt "$MINS" ]; then
  ok "every MMS is stamped with its message id before the insert (line $MSTAMP < $MINS)"
else
  no "the MMS message id is not stamped before the insert (stamp $MSTAMP, insert $MINS) -- mmsExists can never find it"
fi
if [ "$(grep -c 'ensureSmsRead(ctx);' "$TI")" = 1 ]; then
  ok "the read grant has exactly one caller"
else
  no "the read grant is called $(grep -c 'ensureSmsRead(ctx);' "$TI") times, want once (the run's start)"
fi
# ackLanded(): a call is acknowledged only on a completed lookup that found it.
AB=$(body "$TI" 'private static void ackLanded(')
inorder "ackLanded acknowledges a call only on a lookup that found it -- an unknown answer would drop the only sealed copy" \
  "$(bline "$AB" '                    Boolean present = exists(ctx, android.provider.CallLog.Calls.CONTENT_URI, Long.parseLong(f[1]));')" \
  "$(bline "$AB" '                    if (present == null) unknown[0]++;')" \
  "$(bpre "$AB" '                    if (!Boolean.TRUE.equals(present)) continue;')" \
  "$(bpre "$AB" '            keys.append(f[0])')"
# run()'s final call-log check: only a lookup that found the call skips the re-stage.
RB=$(body "$TI" 'static void run(Context ctx, boolean live)')
inorder "the final call-log check skips the re-stage only on a lookup that found the call -- an unknown one re-stages" \
  "$(bline "$RB" '                    Boolean present = exists(ctx, android.provider.CallLog.Calls.CONTENT_URI, when);')" \
  "$(bline "$RB" '                    if (present == null) unknown[0]++;')" \
  "$(bpre "$RB" '                    if (Boolean.TRUE.equals(present)) continue; // persisted')" \
  "$(bline "$RB" '                    String line = restageLine(f, 6, MAX_TEL_RETRIES);')"
# The unknown count is logged once per run, after the final acknowledgement -- counts only.
LOG1='        if (unknown[0] > 0) android.util.Log.w("NowhereChooser", "telingest: " + unknown[0]'
LOG2='                + " row lookup(s) did not complete -- not inserted or acknowledged on that answer, asked again later");'
LN1=$(line "$TI" "$LOG1"); LN2=$(line "$TI" "$LOG2")
inorder "one log line per run counts the unknown lookups, after the final acknowledgement" \
  "$(line "$TI" '        ackLanded(ctx, reply, everOk, acked, true, unknown);')" "$LN1" "$LN2" \
  "$(line "$TI" '        DaemonSocket.roundTrip("ACK-TELINGEST\n", 5_000);')"
LEAK=$(printf '%s\n%s\n' "$LOG1" "$LOG2" | grep -cE 'when|from|f\[|body')
if [ "$LN1" -gt 0 ] && [ "$LN2" = $((LN1 + 1)) ] && [ "$LEAK" = 0 ]; then
  ok "the unknown-lookup log line prints a count only (no number, body or time)"
else
  no "the unknown-lookup log line is not the pinned count-only pair"
fi
if grep -qF 'Idempotent because exists() is reliable, so no dup risk.' "$TI"; then
  no "the CALL comment still claims exists() is reliable"
else
  ok "the CALL comment no longer claims exists() is reliable"
fi

echo "== no condition reads exists()/mmsExists() except through rowStep or Boolean.TRUE.equals (comments stripped) =="
CODE=$(perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$TI")
cnt(){ printf '%s\n' "$CODE" | grep -oE -- "$1" | grep -c .; }
BAD=$(cnt 'if \(!?(exists|mmsExists)\(')
if [ "$BAD" = 0 ]; then ok "no 'if (exists(', 'if (!exists(' or 'if (mmsExists(' form"
else no "$BAD condition(s) unbox exists()/mmsExists() directly -- a failed lookup reads as absent, or throws on null"; fi
E_ALL=$(cnt '\bexists\(ctx'); E_OK=$(cnt 'rowStep\(exists\(ctx|readBack\(exists\(ctx|Boolean present = exists\(ctx')
if [ "$E_ALL" = 4 ] && [ "$E_OK" = 4 ]; then ok "every exists(ctx, ...) call (4) goes through rowStep, readBack or a Boolean local"
else no "exists(ctx, ...) calls: $E_ALL, of them in an allowed form: $E_OK (want 4 and 4)"; fi
M_ALL=$(cnt '\bmmsExists\(ctx'); M_OK=$(cnt 'rowStep\(mmsExists\(ctx')
if [ "$M_ALL" = 1 ] && [ "$M_OK" = 1 ]; then ok "the one mmsExists(ctx, ...) call goes through rowStep"
else no "mmsExists(ctx, ...) calls: $M_ALL, through rowStep: $M_OK (want 1 and 1)"; fi
P_ALL=$(cnt '\bpresent\b'); P_OK=$(cnt 'Boolean present\b|\bpresent == null|Boolean\.(TRUE|FALSE)\.equals\(present\)')
if [ "$P_ALL" -gt 0 ] && [ "$P_ALL" = "$P_OK" ]; then ok "every use of a lookup's Boolean ($P_ALL) is a null test or Boolean.TRUE/FALSE.equals -- never unboxed"
else no "a lookup's Boolean is used outside a null test or Boolean.TRUE/FALSE.equals ($P_OK of $P_ALL uses allowed)"; fi

echo "== rowStep and readBack, run under javac =="
J=$(mktemp -d -p "$W")
RS=$(body "$TI" 'static int rowStep(Boolean present)')
RB2=$(body "$TI" 'static boolean readBack(Boolean present, int[] unknown)')
CONSTS=$(grep -m1 '^    static final int DONE = ' "$TI"; grep -m1 '^    static final int INSERT = ' "$TI"; grep -m1 '^    static final int RETRY = ' "$TI")
{
  echo 'final class RowStep {'
  printf '%s\n%s\n%s\n' "$CONSTS" "$RS" "$RB2"
  cat <<'JAVA'
    public static void main(String[] a) {
        int bad = 0;
        if (DONE == INSERT || INSERT == RETRY || DONE == RETRY) { System.out.println("constants not distinct"); bad++; }
        if (rowStep(Boolean.TRUE) != DONE) { System.out.println("TRUE is not DONE"); bad++; }
        if (rowStep(Boolean.FALSE) != INSERT) { System.out.println("FALSE is not INSERT"); bad++; }
        if (rowStep(null) != RETRY) { System.out.println("null is not RETRY"); bad++; }
        int[] u = new int[1];
        if (!readBack(Boolean.TRUE, u) || u[0] != 0) { System.out.println("readBack TRUE is not ok-uncounted"); bad++; }
        if (readBack(Boolean.FALSE, u) || u[0] != 0) { System.out.println("readBack FALSE is not not-ok-uncounted"); bad++; }
        if (readBack(null, u) || u[0] != 1) { System.out.println("readBack null is not not-ok-counted-once"); bad++; }
        System.exit(bad == 0 ? 0 : 1);
    }
}
JAVA
} > "$J/RowStep.java"
if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -nowarn -d "$J" "$J/RowStep.java" 2>"$J/javac.err"; then
  no "rowStep/readBack did not lift or compile: $(head -3 "$J/javac.err" | tr '\n' ' ')"
else
  OUT=$("$JAVA" -Djava.io.tmpdir="$W" -cp "$J" RowStep 2>&1); RC=$?
  if [ "$RC" = 0 ]; then ok "rowStep: TRUE -> DONE, FALSE -> INSERT, null -> RETRY; readBack: only TRUE ok, null counted once"
  else no "rowStep: $(printf '%s' "$OUT" | tr '\n' ';')"; fi
fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$W")
  mutate(){
    local rc
    mkdir -p "$M/src"
    if ! sed "$2" "$TI" > "$M/src/TelIngest.java" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$TI" "$M/src/TelIngest.java"; then no "MUTATION INERT: $1"; return; fi
    bash "$0" "$M/src" >/dev/null 2>&1; rc=$?
    case "$rc" in
      0) no "NOT CONVICTED: $1 -- suite passes on broken code" ;;
      1) ok "convicted: $1" ;;
      *) no "MUTATION BROKEN (suite exited $rc, not a failed check): $1" ;;
    esac
  }
  mutate "the read grant dropped from the run" \
         '/^        ensureSmsRead(ctx);      \/\/ NWP-20261006-07/d'
  mutate "the read grant moved after the passes" \
         '/^        ensureSmsRead(ctx);      \/\/ NWP-20261006-07/d; s|^        for (int pass = 0; pass < passes; pass++) {$|&\n        ensureSmsRead(ctx);      // NWP-20261006-07: so a resent text is found in Messages, not inserted twice.|'
  mutate "the grant asks for the wrong permission" \
         's/android.Manifest.permission.READ_SMS,/android.Manifest.permission.RECEIVE_SMS,/'
  mutate "the read app-op left ignored" \
         's/OPSTR_READ_SMS),/OPSTR_WRITE_SMS),/'
  mutate "the SMS existence check dropped" \
         '/^            int step = rowStep(exists(ctx, uri, when));$/d'
  mutate "the MMS existence check dropped" \
         '/^            int step = rowStep(mmsExists(ctx, when));$/d'
  mutate "the MMS message id no longer stamped" \
         '/^            pdu.put("m_id", mmsKey(when));/d'
  mutate "the MMS lookup by date instead of its id" \
         's/"m_id=?", new String\[\]{mmsKey(when)}/"date=?", new String[]{Long.toString(when \/ 1000L)}/'
  # NWP-20261112-21: a lookup that did not complete must never insert or acknowledge.
  mutate "M1 exists' catch answers FALSE again" \
         '/private static Boolean exists(/,/^    }$/ s/^            return null;$/            return false;/'
  mutate "M2 exists' null cursor answers FALSE" \
         '/private static Boolean exists(/,/^    }$/ s/if (c == null) return null;/if (c == null) return false;/'
  mutate "M3 rowStep maps null to INSERT" \
         '/static int rowStep(Boolean present)/,/^    }$/ s/^        return RETRY;$/        return INSERT;/'
  mutate "M4 deliverMms inserts on null" \
         '/private static boolean deliverMms(/,/^    }$/ { /if (step != INSERT) { unknown\[0\]++; return false; }/d; }'
  mutate "M5 the post-insert fallback accepts null as ok" \
         '/static boolean readBack(Boolean present, int\[\] unknown)/,/^    }$/ s/return Boolean.TRUE.equals(present);/return !Boolean.FALSE.equals(present);/'
  mutate "M6 ackLanded acknowledges a call on null" \
         's/if (!Boolean.TRUE.equals(present)) continue;/if (Boolean.FALSE.equals(present)) continue;/'
  mutate "M7 the final call-log check skips the re-stage on null" \
         's/if (Boolean.TRUE.equals(present)) continue; \/\/ persisted/if (!Boolean.FALSE.equals(present)) continue; \/\/ persisted/'
  mutate "M8 deliver inserts on null" \
         '/private static boolean deliver(/,/^    }$/ { /if (step != INSERT) { unknown\[0\]++; return false; }/d; }'
  mutate "M9 mmsExists' catch answers FALSE again" \
         '/private static Boolean mmsExists(/,/^    }$/ s/^            return null;$/            return false;/'
  mutate "M11 the post-insert read-back's unknown answer is not counted" \
         '/static boolean readBack(Boolean present, int\[\] unknown)/,/^    }$/ { /if (present == null) unknown\[0\]++;/d; }'
  mutate "M12 the post-insert fallback bypasses readBack (an unknown answer uncounted)" \
         's/boolean ok = ins != null || readBack(exists(ctx, uri, when), unknown);/boolean ok = ins != null || Boolean.TRUE.equals(exists(ctx, uri, when));/'
  mutate "M10 a call's existence unboxed in a condition" \
         's/int step = rowStep(exists(ctx, uri, when));/int step = rowStep(exists(ctx, uri, when)); if (exists(ctx, uri, when)) return true;/'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
