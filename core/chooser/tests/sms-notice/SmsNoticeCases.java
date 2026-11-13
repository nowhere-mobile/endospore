// NWP-20261010-13: the cases for the chooser's pure SMS-notice and SMS-role decisions, run against Lifted (run.sh builds
// it from the real sources), and the pinned wiring around them. Arguments: the chooser's AndroidManifest.xml (component
// and permission checks; the chooser's res/ is read beside it), its source dir (com/nowhere/chooser) and the pins dir
// (pins/<Class>.<name>.txt).
import java.util.*;

public final class SmsNoticeCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static String show(String[] a) { return a == null ? "null" : Arrays.toString(a); }

    static final String MSG = "com.android.messaging", SELF = "com.nowhere.chooser";
    static final long OLD = 10 * 60_000L; // a notice ten minutes old: past any grace

    public static void main(String[] args) throws Exception {
        long t = 1728561234567L;

        // ---- noticeTag / noticeRow: the tag is the whole record, and only a tag noticeTag wrote names a row ----
        check("tag: sms shape", ("sms:" + t).equals(Lifted.noticeTag("sms", t)), Lifted.noticeTag("sms", t));
        check("tag: mms shape", ("mms:" + t).equals(Lifted.noticeTag("mms", t)), Lifted.noticeTag("mms", t));
        String[] r = Lifted.noticeRow(Lifted.noticeTag("sms", t));
        check("row: sms round trip", r != null && r.length == 2 && "sms".equals(r[0]) && Long.toString(t).equals(r[1]), show(r));
        r = Lifted.noticeRow(Lifted.noticeTag("mms", t));
        check("row: mms round trip", r != null && "mms".equals(r[0]) && Long.toString(t).equals(r[1]), show(r));
        check("row: 1 ms", Lifted.noticeRow("sms:1") != null, show(Lifted.noticeRow("sms:1")));
        String[] foreign = {
            null, "", "sms", "sms:", ":5", ":", "sms:abc", "sms:12:3", "sms:007", "sms:+7", "sms:-7", "sms:0",
            "SMS:5", "Sms:5", " sms:5", "sms:5 ", "sms: 5", "sms:5\n", "sms:1.5", "sms:1e3", "sms:0x10",
            "sms:99999999999999999999", "sms:9223372036854775808",
            "nowhere_mms", "nowhere_missed_call", "nowhere_telephony2", "nowhere_telephony_loss",
            "call:5", "mmsx:5", "xsms:5", "sms::5", "mms:", "mms:-1",
        };
        for (String f : foreign) {
            check("row: foreign tag names no row: " + (f == null ? "null" : "\"" + f.replace("\n", "\\n") + "\""),
                    Lifted.noticeRow(f) == null, show(Lifted.noticeRow(f)));
        }
        for (long w : new long[]{1L, 999L, 1000L, t, t + 1, 4102444800000L, Long.MAX_VALUE}) {
            for (String k : new String[]{"sms", "mms"}) {
                String[] rr = Lifted.noticeRow(Lifted.noticeTag(k, w));
                check("row: round trip " + k + " " + w, rr != null && k.equals(rr[0]) && Long.parseLong(rr[1]) == w, show(rr));
            }
        }

        // ---- rowQuery: an SMS by its arrival-ms date, an MMS by the stamped message id (never its seconds date) ----
        String[] q = Lifted.rowQuery(new String[]{"sms", Long.toString(t)});
        check("query: sms", Arrays.equals(q, new String[]{"content://sms", "date=?", Long.toString(t)}), show(q));
        q = Lifted.rowQuery(new String[]{"mms", Long.toString(t)});
        check("query: mms by m_id", Arrays.equals(q, new String[]{"content://mms", "m_id=?", "nowhere:" + t}), show(q));
        check("query: mms id is exactly what deliverMms stamps (mmsKey)", Lifted.mmsKey(t).equals(q[2]), show(q));

        // ---- rowState: a read-back that could not see is BLIND, never "gone" ----
        check("state: no permission/op is blind, even with an empty answer", Lifted.rowState(false, true, false, 0) == Lifted.ROW_BLIND, "");
        check("state: no permission/op is blind, even with a row", Lifted.rowState(false, true, true, 1) == Lifted.ROW_BLIND, "");
        check("state: no cursor / a throw is blind", Lifted.rowState(true, false, false, 0) == Lifted.ROW_BLIND, "");
        check("state: answered, no row -> gone", Lifted.rowState(true, true, false, 0) == Lifted.ROW_GONE, "");
        check("state: a row, unread", Lifted.rowState(true, true, true, 0) == 0, "");
        check("state: a row, read", Lifted.rowState(true, true, true, 1) > 0, "");
        check("state: a row, read flag 2", Lifted.rowState(true, true, true, 2) > 0, "");
        check("state: a row with a negative read column is unread, never blind or gone", Lifted.rowState(true, true, true, -2) == 0, "");
        check("state: the two sentinels differ and are not read values",
                Lifted.ROW_BLIND != Lifted.ROW_GONE && Lifted.ROW_BLIND < 0 && Lifted.ROW_GONE < 0, "");

        // ---- noticeAction ----
        check("action: read clears", Lifted.noticeAction(1, 0) == Lifted.NOTICE_CLEAR, "");
        check("action: read clears however young", Lifted.noticeAction(1, -5) == Lifted.NOTICE_CLEAR, "");
        check("action: unread polls", Lifted.noticeAction(0, OLD) == Lifted.NOTICE_POLL, "");
        check("action: gone and old clears (a deleted conversation)", Lifted.noticeAction(Lifted.ROW_GONE, OLD) == Lifted.NOTICE_CLEAR, "");
        check("action: gone at exactly the grace clears", Lifted.noticeAction(Lifted.ROW_GONE, Lifted.GONE_GRACE_MS) == Lifted.NOTICE_CLEAR, "");
        check("action: gone and young polls (the row may still be committing)",
                Lifted.noticeAction(Lifted.ROW_GONE, Lifted.GONE_GRACE_MS - 1) == Lifted.NOTICE_POLL, "");
        check("action: gone at age 0 polls", Lifted.noticeAction(Lifted.ROW_GONE, 0) == Lifted.NOTICE_POLL, "");
        check("action: blind keeps and does not poll", Lifted.noticeAction(Lifted.ROW_BLIND, OLD) == Lifted.NOTICE_KEEP, "");
        check("action: blind and young keeps", Lifted.noticeAction(Lifted.ROW_BLIND, 0) == Lifted.NOTICE_KEEP, "");
        check("action: grace outlasts the login delivery (20 s + 15 s + 45 s)", Lifted.GONE_GRACE_MS > 80_000L, Lifted.GONE_GRACE_MS);
        check("action: the three outcomes differ",
                Lifted.NOTICE_CLEAR != Lifted.NOTICE_POLL && Lifted.NOTICE_POLL != Lifted.NOTICE_KEEP && Lifted.NOTICE_CLEAR != Lifted.NOTICE_KEEP, "");

        // ---- noticeActions: every message notice decided once, nothing else looked up ----
        Map<String, Integer> st = new HashMap<>();
        st.put("content://sms|1", 1);                   // read
        st.put("content://sms|2", 0);                   // unread
        st.put("content://mms|nowhere:3", 1);           // read MMS
        st.put("content://sms|4", Lifted.ROW_GONE);     // deleted
        st.put("content://sms|5", Lifted.ROW_GONE);     // "deleted", but young
        st.put("content://sms|6", Lifted.ROW_BLIND);    // could not see
        st.put("content://mms|nowhere:7", 0);
        List<String> asked = new ArrayList<>();
        java.util.function.ToIntFunction<String[]> stateOf = qq -> {
            asked.add(qq[0] + "|" + qq[2]);
            Integer v = st.get(qq[0] + "|" + qq[2]);
            return v == null ? Lifted.ROW_BLIND : v;
        };
        java.util.function.ToLongFunction<String> age = tag -> "sms:5".equals(tag) ? 1_000L : OLD;
        List<String> tags = Arrays.asList("sms:1", "sms:2", "mms:3", "nowhere_missed_call", "sms:4", "sms:5", "sms:6",
                "mms:7", "nowhere_mms", null, "sms:007", "sms:1");
        Map<String, Integer> act = Lifted.noticeActions(tags, age, stateOf);
        check("actions: only message tags, in order, each once",
                new ArrayList<>(act.keySet()).equals(Arrays.asList("sms:1", "sms:2", "mms:3", "sms:4", "sms:5", "sms:6", "mms:7")), act);
        check("actions: read SMS cleared", act.get("sms:1") == Lifted.NOTICE_CLEAR, act);
        check("actions: read MMS cleared", act.get("mms:3") == Lifted.NOTICE_CLEAR, act);
        check("actions: unread kept and polled", act.get("sms:2") == Lifted.NOTICE_POLL && act.get("mms:7") == Lifted.NOTICE_POLL, act);
        check("actions: deleted conversation cleared", act.get("sms:4") == Lifted.NOTICE_CLEAR, act);
        check("actions: young gone row polled", act.get("sms:5") == Lifted.NOTICE_POLL, act);
        check("actions: blind kept, not polled", act.get("sms:6") == Lifted.NOTICE_KEEP, act);
        check("actions: each row looked up once, and no foreign tag at all", asked.size() == 7, asked);
        check("actions: the non-canonical sms:007 is never looked up as row 7", !asked.contains("content://sms|7"), asked);
        check("actions: null tags", Lifted.noticeActions(null, age, stateOf).isEmpty(), "");
        check("actions: no tags", Lifted.noticeActions(Collections.emptyList(), age, stateOf).isEmpty(), "");
        Map<String, Integer> blind = Lifted.noticeActions(Arrays.asList("sms:1", "sms:2", "mms:3", "sms:4"), age, qq -> Lifted.ROW_BLIND);
        boolean anyClearOrPoll = false;
        for (int v : blind.values()) if (v != Lifted.NOTICE_KEEP) anyClearOrPoll = true;
        check("actions: a blind read-back (no READ_SMS) clears nothing and polls nothing", !anyClearOrPoll && blind.size() == 4, blind);

        // The two failures of the old read-watch, as cases: it had state and a clock. This has neither, so two texts are
        // independent, and a read hours later clears exactly as one seconds later.
        Map<String, Integer> live = new HashMap<>();
        java.util.function.ToIntFunction<String[]> liveOf = qq -> live.getOrDefault(qq[2], Lifted.ROW_GONE);
        java.util.function.ToLongFunction<String> hours = tag -> 4 * 3_600_000L;
        List<String> both = Arrays.asList(Lifted.noticeTag("sms", 1000L), Lifted.noticeTag("sms", 61_000L));
        live.put("1000", 0); live.put("61000", 0);
        act = Lifted.noticeActions(both, hours, liveOf);
        check("two texts: nothing read, nothing cleared", !act.containsValue(Lifted.NOTICE_CLEAR), act);
        live.put("1000", 1);
        act = Lifted.noticeActions(both, hours, liveOf);
        check("two texts: the first read clears only the first",
                act.get("sms:1000") == Lifted.NOTICE_CLEAR && act.get("sms:61000") == Lifted.NOTICE_POLL, act);
        live.put("61000", 1);
        act = Lifted.noticeActions(Arrays.asList("sms:61000"), hours, liveOf);
        check("two texts: the second, read four hours later, still clears", act.get("sms:61000") == Lifted.NOTICE_CLEAR, act);

        // ---- the re-sweep: bounded, backed off, and never for a blind notice ----
        check("resweep: nothing pollable -> stop", Lifted.resweepDelay(0, 0) < 0, Lifted.resweepDelay(0, 0));
        check("resweep: negative -> stop", Lifted.resweepDelay(-1, 0) < 0, Lifted.resweepDelay(-1, 0));
        check("resweep: first after an event is 15 s", Lifted.resweepDelay(1, 0) == 15_000L, Lifted.resweepDelay(1, 0));
        long total = 0; int rounds = 0, idle = 0;
        boolean grew = true; long prev = 0;
        while (true) {                              // a notice that is never read and never notifies: idle re-sweeps
            long d = Lifted.resweepDelay(3, idle);
            if (d < 0) break;
            if (d <= prev) grew = false;
            prev = d; total += d; rounds++;
            idle = Lifted.nextIdleResweeps(false, 0, idle);
            if (rounds > 1000) break;
        }
        check("resweep: an unread notice that never changes stops polling", rounds <= 10, rounds);
        check("resweep: ...after at most ~20 minutes", total <= 20 * 60_000L, total);
        check("resweep: ...backing off, each wait longer than the last", grew && rounds >= 2, rounds);
        check("resweep: an event restarts it", Lifted.nextIdleResweeps(true, 0, 6) == 0, Lifted.nextIdleResweeps(true, 0, 6));
        check("resweep: a clear restarts it", Lifted.nextIdleResweeps(false, 1, 6) == 0, Lifted.nextIdleResweeps(false, 1, 6));
        check("resweep: an idle re-sweep counts", Lifted.nextIdleResweeps(false, 0, 2) == 3, Lifted.nextIdleResweeps(false, 0, 2));
        check("resweep: restarted after the cap, it polls again", Lifted.resweepDelay(1, Lifted.nextIdleResweeps(true, 0, 99)) == 15_000L, "");

        // ---- sweepDelay: debounced, but throttled ----
        check("debounce: a first event waits 0.5 s", Lifted.sweepDelay(10_000L, 10_000L) == 500L, Lifted.sweepDelay(10_000L, 10_000L));
        check("debounce: 1.8 s into a burst it waits only to the 2 s cap", Lifted.sweepDelay(11_800L, 10_000L) == 200L, Lifted.sweepDelay(11_800L, 10_000L));
        check("debounce: past the cap it runs now", Lifted.sweepDelay(13_000L, 10_000L) == 0L, Lifted.sweepDelay(13_000L, 10_000L));
        long ran = -1;                               // an event every 100 ms from 10 s, for a minute
        for (long now = 10_000L; now < 70_000L; now += 100L) {
            long d = Lifted.sweepDelay(now, 10_000L);
            if (d < 100L) { ran = now + d; break; }  // the sweep fires before the next event can push it out
        }
        check("debounce: continuous churn cannot hold the sweep off past 2 s", ran >= 0 && ran <= 12_000L, ran);

        // ---- messageTapPackage: the role holder, never the chooser; Messaging when the holder is unknown ----
        check("tap pkg: Messaging holds the role", MSG.equals(Lifted.messageTapPackage(MSG, SELF, MSG)), "");
        check("tap pkg: another holder is honoured (an in-session change)",
                "com.whatsapp".equals(Lifted.messageTapPackage("com.whatsapp", SELF, MSG)), "");
        check("tap pkg: no holder -> Messaging", MSG.equals(Lifted.messageTapPackage(null, SELF, MSG)), "");
        check("tap pkg: empty holder -> Messaging", MSG.equals(Lifted.messageTapPackage("", SELF, MSG)), "");
        check("tap pkg: the chooser holds it (cede did not land) -> Messaging", MSG.equals(Lifted.messageTapPackage(SELF, SELF, MSG)), "");
        check("tap pkg: no holder, no Messaging -> unpinned", Lifted.messageTapPackage(null, SELF, null) == null, "");
        check("tap pkg: chooser holder, no Messaging -> unpinned, never the chooser",
                Lifted.messageTapPackage(SELF, SELF, null) == null, "");
        check("tap pkg: a fallback that is the chooser is refused", Lifted.messageTapPackage(null, SELF, SELF) == null, "");

        // ---- messageTapAction ----
        check("tap action: pinned and VIEW resolves -> view", "view".equals(Lifted.messageTapAction(true, true, true)), "");
        check("tap action: pinned, VIEW does not resolve -> sendto", "sendto".equals(Lifted.messageTapAction(true, true, false)), "");
        check("tap action: unpinned -> view (as before)", "view".equals(Lifted.messageTapAction(true, false, false)), "");
        for (boolean p : new boolean[]{true, false}) for (boolean v : new boolean[]{true, false}) {
            check("tap action: no sender -> launch (" + p + "," + v + ")", "launch".equals(Lifted.messageTapAction(false, p, v)), "");
        }

        // ---- the profile's SMS app (Chester, 2026-10-11): recorded, applied at sign-in, never captured too early ----
        String WA = "com.whatsapp.sms", GONE_APP = "org.gone.sms";
        check("pkg: a package name", Lifted.isPackageName(WA), "");
        for (String bad : new String[]{null, "", "nodots", ".a.b", "a.b.", "a..b", "a.b;rm", "a.b c", "a/b.c", "a.b\nc"}) {
            check("pkg: not a package name: " + bad, !Lifted.isPackageName(bad), "");
        }
        check("record: app=", WA.equals(Lifted.parseSmsRecord("app=" + WA + "\n")), Lifted.parseSmsRecord("app=" + WA + "\n"));
        check("record: none", Lifted.parseSmsRecord(null) == null, "");
        check("record: empty", Lifted.parseSmsRecord("") == null, "");
        check("record: malformed is no record", Lifted.parseSmsRecord("app=a;rm -rf\n") == null, "");
        // NWP-20261123-23: a record that exists within read()'s cap but cannot be read is UNKNOWN, never "no record"
        check("unknown: an absent record is not unknown", !Lifted.recordUnknown(false, 0, null), "");
        check("unknown: a record that exists and cannot be read is unknown", Lifted.recordUnknown(true, 20, null), "");
        check("unknown: a readable record is not unknown", !Lifted.recordUnknown(true, 20, "app=x.y\n"), "");
        check("unknown: an oversized record is not unknown (malformed: no record)", !Lifted.recordUnknown(true, 5000, null), "");
        check("unknown: an empty record is not unknown", !Lifted.recordUnknown(true, 0, ""), "");
        check("unknown: at exactly read()'s 4096-byte cap, unreadable is unknown", Lifted.recordUnknown(true, 4096, null), "");
        check("record: no app line", Lifted.parseSmsRecord("pkg=" + WA + "\n") == null, "");
        String mk = Lifted.markerText("42", "applied", WA, WA);
        String[] pm = Lifted.parseMarker(mk, "42");
        check("marker: round trip", pm != null && "applied".equals(pm[0]) && WA.equals(pm[1]) && WA.equals(pm[2]), show(pm));
        check("marker: another session's (sealed and restored) never matches", Lifted.parseMarker(mk, "43") == null, "");
        check("marker: unknown session (serial unreadable) never matches", Lifted.parseMarker(mk, null) == null, "");
        // round-3 review F5: a session that is a PREFIX of another is a different session (a startsWith compare is wrong)
        check("marker: session 10 does not match 105", Lifted.parseMarker(Lifted.markerText("10", "applied", WA, WA), "105") == null, "");
        check("marker: session 105 does not match 10", Lifted.parseMarker(Lifted.markerText("105", "applied", WA, WA), "10") == null, "");
        check("marker: session 10 does not match 1", Lifted.parseMarker(Lifted.markerText("10", "applied", WA, WA), "1") == null, "");
        check("marker: none", Lifted.parseMarker(null, "42") == null, "");
        check("marker: a bad state", Lifted.parseMarker(Lifted.markerText("42", "maybe", WA, WA), "42") == null, "");
        check("marker: a bad package", Lifted.parseMarker(Lifted.markerText("42", "applied", "x;y", WA), "42") == null, "");
        for (String mst : new String[]{"applied", "deferred", "fallback"}) {
            check("marker: state " + mst, Lifted.parseMarker(Lifted.markerText("42", mst, MSG, WA), "42") != null, "");
        }
        // sign-in (presence: installed / archived / absent / unknown). The record is never changed by the sign-in.
        String[] pl = Lifted.smsSignInPlan(null, "absent", MSG, SELF);
        check("plan: no record -> Messaging, applied", Arrays.equals(pl, new String[]{MSG, "applied", MSG}), show(pl));
        pl = Lifted.smsSignInPlan(MSG, "installed", MSG, SELF);
        check("plan: record Messaging -> Messaging, applied", Arrays.equals(pl, new String[]{MSG, "applied", MSG}), show(pl));
        pl = Lifted.smsSignInPlan(SELF, "installed", MSG, SELF);
        check("plan: a record naming the chooser is no choice", Arrays.equals(pl, new String[]{MSG, "applied", MSG}), show(pl));
        pl = Lifted.smsSignInPlan(WA, "installed", MSG, SELF);
        check("plan: the recorded app, installed -> it, applied", Arrays.equals(pl, new String[]{WA, "applied", WA}), show(pl));
        pl = Lifted.smsSignInPlan(WA, "archived", MSG, SELF);
        check("plan: on-demand, not materialised -> Messaging for now, deferred to it", Arrays.equals(pl, new String[]{MSG, "deferred", WA}), show(pl));
        // absence is never a choice: a failed #apps restore, a failed placeholder raise, a never-kept app, an uninstall,
        // a switch-Off -- the choice is kept and deferred to the app, "ever after"
        pl = Lifted.smsSignInPlan(GONE_APP, "absent", MSG, SELF);
        check("plan: absent (failed restore, never kept, uninstalled, Off) -> deferred, the record kept",
                Arrays.equals(pl, new String[]{MSG, "deferred", GONE_APP}), show(pl));
        // PackageManager failed -- fail closed: try the recorded app (refused -> fallback, the record kept)
        pl = Lifted.smsSignInPlan(WA, "unknown", MSG, SELF);
        check("plan: PackageManager failed -> try the recorded app", Arrays.equals(pl, new String[]{WA, "applied", WA}), show(pl));
        // capture
        check("capture: a new choice", WA.equals(Lifted.smsCaptureValue(null, "applied", MSG, WA, MSG, SELF)), "");
        check("capture: a switch back to Messaging is recorded", MSG.equals(Lifted.smsCaptureValue(WA, "applied", WA, MSG, MSG, SELF)), "");
        check("capture: Messaging with no record writes nothing", Lifted.smsCaptureValue(null, "applied", MSG, MSG, MSG, SELF) == null, "");
        check("capture: unchanged writes nothing", Lifted.smsCaptureValue(WA, "applied", WA, WA, MSG, SELF) == null, "");
        check("capture: the chooser is never a choice", Lifted.smsCaptureValue(WA, "applied", WA, SELF, MSG, SELF) == null, "");
        check("capture: an empty holder is never a choice", Lifted.smsCaptureValue(WA, "applied", WA, "", MSG, SELF) == null, "");
        check("capture: an unreadable holder is never a choice", Lifted.smsCaptureValue(WA, "applied", WA, null, MSG, SELF) == null, "");
        check("capture: deferred -- the stand-in Messaging never overwrites the record",
                Lifted.smsCaptureValue(WA, "deferred", MSG, MSG, MSG, SELF) == null, "");
        check("capture: fallback -- the stand-in Messaging never overwrites the record of a gone app",
                Lifted.smsCaptureValue(GONE_APP, "fallback", MSG, MSG, MSG, SELF) == null, "");
        check("capture: deferred -- another app picked meanwhile IS a new choice",
                "org.other.sms".equals(Lifted.smsCaptureValue(WA, "deferred", MSG, "org.other.sms", MSG, SELF)), "");
        check("capture: fallback -- another app picked meanwhile IS a new choice",
                "org.other.sms".equals(Lifted.smsCaptureValue(GONE_APP, "fallback", MSG, "org.other.sms", MSG, SELF)), "");
        // the materialise hook
        check("materialise: the stand-in still holds it -> take over", Lifted.takeOverFromStandIn(Arrays.asList(MSG), MSG, SELF), "");
        check("materialise: nobody holds it -> take over", Lifted.takeOverFromStandIn(Collections.emptyList(), MSG, SELF), "");
        check("materialise: the chooser holds it -> take over", Lifted.takeOverFromStandIn(Arrays.asList(SELF), MSG, SELF), "");
        check("materialise: the user chose another app meanwhile -> leave it", !Lifted.takeOverFromStandIn(Arrays.asList("org.other.sms"), MSG, SELF), "");
        check("materialise: unreadable -> leave it", !Lifted.takeOverFromStandIn(null, MSG, SELF), "");
        // a re-archive, an uninstall, or any absence of the recorded app is not a choice of Messaging
        check("stand-in: recorded app re-archived, Messaging took over -> deferred", "deferred".equals(Lifted.standInState(WA, MSG, MSG, SELF, "archived")), "");
        check("stand-in: recorded app re-archived, role empty -> deferred", "deferred".equals(Lifted.standInState(WA, "", MSG, SELF, "archived")), "");
        check("stand-in: recorded app absent (uninstalled, Off, restore failed) -> deferred, the record kept", "deferred".equals(Lifted.standInState(WA, MSG, MSG, SELF, "absent")), "");
        check("stand-in: PackageManager failed -> none (change nothing)", "none".equals(Lifted.standInState(WA, MSG, MSG, SELF, "unknown")), "");
        check("stand-in: recorded app installed -> a real switch back, no stand-in", Lifted.standInState(WA, MSG, MSG, SELF, "installed") == null, "");
        check("stand-in: another app took the role -> a choice, no stand-in", Lifted.standInState(WA, "org.other.sms", MSG, SELF, "archived") == null, "");
        check("stand-in: unreadable holder changes nothing", Lifted.standInState(WA, null, MSG, SELF, "archived") == null, "");
        check("stand-in: no record", Lifted.standInState(null, MSG, MSG, SELF, "absent") == null, "");
        check("stand-in: a Messaging record", Lifted.standInState(MSG, MSG, MSG, SELF, "absent") == null, "");
        // the ONLY way the record changes: an observed pick while applied -- Messaging included, the app installed
        check("observed: a switch to Messaging with the recorded app installed is recorded",
                Lifted.standInState(WA, MSG, MSG, SELF, "installed") == null
                && MSG.equals(Lifted.smsCaptureValue(WA, "applied", WA, MSG, MSG, SELF)), "");
        // ...end to end: chosen and applied, idle-archived, then materialised again
        String rec = WA; String[] mkr = {"applied", WA, WA};
        String st1 = Lifted.standInState(rec, MSG, MSG, SELF, "archived");   // the archive: Messaging holds it now
        check("archive cycle: the archive moves the marker to deferred", "deferred".equals(st1), st1);
        mkr = new String[]{st1, MSG, rec};
        check("archive cycle: the stand-in Messaging is not captured over the record",
                Lifted.smsCaptureValue(rec, mkr[0], mkr[1], MSG, MSG, SELF) == null, "");
        check("archive cycle: the next materialise takes the role back",
                WA.equals(Lifted.materialiseTarget(mkr, WA, Arrays.asList(MSG), SELF)), "");
        check("archive cycle: but not over an app the user picked meanwhile",
                Lifted.materialiseTarget(mkr, WA, Arrays.asList("org.other.sms"), SELF) == null, "");
        // ...uninstalled, then installed again years on: the choice persists and the app takes the role back
        pl = Lifted.smsSignInPlan(WA, "absent", MSG, SELF);
        check("uninstall: the next sign-in keeps the record and defers to it", Arrays.equals(pl, new String[]{MSG, "deferred", WA}), show(pl));
        check("uninstall: installed again -> it takes the role (install heal)",
                WA.equals(Lifted.materialiseTarget(new String[]{pl[1], pl[0], pl[2]}, WA, Arrays.asList(MSG), SELF)), "");
        // ...a failed #apps restore at sign-in: kept, and back at the next sign-in
        check("restore failed: the stand-in is not captured over the record", Lifted.smsCaptureValue(WA, "deferred", MSG, MSG, MSG, SELF) == null, "");
        check("restore failed: the next sign-in, with the app restored, gives it the role",
                WA.equals(Lifted.smsSignInPlan(WA, "installed", MSG, SELF)[0]), "");
        // onMaterialised's guard, every branch, on behaviour
        String[] mDef = {"deferred", MSG, WA}, mFb = {"fallback", MSG, WA}, mApp = {"applied", WA, WA};
        check("materialise: no marker (apply not run, or another session's) -> nothing", Lifted.materialiseTarget(null, WA, Arrays.asList(MSG), SELF) == null, "");
        check("materialise: marker applied -> nothing, even with the role empty", Lifted.materialiseTarget(mApp, WA, Collections.emptyList(), SELF) == null, "");
        check("materialise: another app materialised -> nothing", Lifted.materialiseTarget(mDef, "org.other.app", Arrays.asList(MSG), SELF) == null, "");
        check("materialise: the awaited app, stand-in holds it -> it", WA.equals(Lifted.materialiseTarget(mDef, WA, Arrays.asList(MSG), SELF)), "");
        check("materialise: fallback too -> it", WA.equals(Lifted.materialiseTarget(mFb, WA, Arrays.asList(MSG), SELF)), "");
        check("materialise: nobody holds it -> it", WA.equals(Lifted.materialiseTarget(mDef, WA, Collections.emptyList(), SELF)), "");
        check("materialise: the user picked another app -> nothing", Lifted.materialiseTarget(mDef, WA, Arrays.asList("org.other.sms"), SELF) == null, "");
        check("materialise: holders unreadable -> nothing", Lifted.materialiseTarget(mDef, WA, null, SELF) == null, "");
        // round-7 review F2: a takeover re-checks the stand-in on EVERY attempt -- a pick between attempts is kept
        check("takeover: want already holds it -> held", "held".equals(Lifted.takeoverStep(Arrays.asList(WA), SELF, WA, MSG)), "");
        check("takeover: the stand-in holds it -> assign", "assign".equals(Lifted.takeoverStep(Arrays.asList(MSG), SELF, WA, MSG)), "");
        check("takeover: nobody holds it -> assign", "assign".equals(Lifted.takeoverStep(Collections.emptyList(), SELF, WA, MSG)), "");
        check("takeover: the chooser holds it -> assign", "assign".equals(Lifted.takeoverStep(Arrays.asList(SELF), SELF, WA, MSG)), "");
        check("takeover: the user picked another app between attempts -> leave",
                "leave".equals(Lifted.takeoverStep(Arrays.asList("org.other.sms"), SELF, WA, MSG)), "");
        check("takeover: holders unreadable -> leave", "leave".equals(Lifted.takeoverStep(null, SELF, WA, MSG)), "");
        check("takeover: unlike the sign-in mode, which would assign over that pick",
                "assign".equals(Lifted.smsRoleStep(Arrays.asList("org.other.sms"), true, SELF, WA)), "");
        // round-6 review F3: a refused sign-in apply is retried by the gate's delayed repair
        check("retry: fallback, recorded app installed, stand-in holds it -> retry it", WA.equals(Lifted.retryRefusedTarget(mFb, "installed", Arrays.asList(MSG), MSG)), "");
        check("retry: not fallback (deferred) -> no", Lifted.retryRefusedTarget(mDef, "installed", Arrays.asList(MSG), MSG) == null, "");
        check("retry: not fallback (applied) -> no", Lifted.retryRefusedTarget(mApp, "installed", Arrays.asList(MSG), MSG) == null, "");
        check("retry: no marker -> no", Lifted.retryRefusedTarget(null, "installed", Arrays.asList(MSG), MSG) == null, "");
        check("retry: recorded app not installed -> no", Lifted.retryRefusedTarget(mFb, "absent", Arrays.asList(MSG), MSG) == null, "");
        check("retry: PackageManager failed -> no", Lifted.retryRefusedTarget(mFb, "unknown", Arrays.asList(MSG), MSG) == null, "");
        check("retry: the user picked another app -> no", Lifted.retryRefusedTarget(mFb, "installed", Arrays.asList("org.other.sms"), MSG) == null, "");
        check("retry: holders unreadable -> no", Lifted.retryRefusedTarget(mFb, "installed", null, MSG) == null, "");
        check("retry: a fallback whose target is Messaging (nothing was refused but Messaging) -> no",
                Lifted.retryRefusedTarget(new String[]{"fallback", MSG, MSG}, "installed", Arrays.asList(MSG), MSG) == null, "");
        // round-3 review F3: a repair belongs to the session it was scheduled for
        check("repair: same user, same serial -> runs", Lifted.repairStillValid(17L, 17L), "");
        check("repair: the session ended, a new user (new serial) -> skipped", !Lifted.repairStillValid(17L, 18L), "");
        check("repair: the user is gone (-1) -> skipped", !Lifted.repairStillValid(17L, -1L), "");
        check("repair: unreadable at schedule time -> skipped", !Lifted.repairStillValid(-1L, -1L), "");
        // the gate's repair waits out the sign-in apply's worst case: two ensureHolder runs of 4 x (2 s + 0.3 s)
        check("repair: delayed past the sign-in apply", Lifted.SMS_REPAIR_DELAY_MS > 2 * 4 * 2_300L, Lifted.SMS_REPAIR_DELAY_MS);

        // ---- the SMS role step: sign-in gives it to want; any other time only repairs a role nobody holds ----
        check("role: held", Lifted.roleHeldBy(Arrays.asList(MSG), MSG), "");
        check("role: null list is not held", !Lifted.roleHeldBy(null, MSG), "");
        check("role: the chooser holding it is not Messaging", !Lifted.roleHeldBy(Arrays.asList(SELF), MSG), "");
        List<String> none = Collections.emptyList(), msg = Arrays.asList(MSG), self = Arrays.asList(SELF),
                other = Arrays.asList("com.whatsapp"), otherAndSelf = Arrays.asList("com.whatsapp", SELF);
        for (boolean s : new boolean[]{true, false}) {
            check("step: Messaging holds it -> held (signIn=" + s + ")", "held".equals(Lifted.smsRoleStep(msg, s, SELF, MSG)), "");
            check("step: nobody holds it -> assign (signIn=" + s + ")", "assign".equals(Lifted.smsRoleStep(none, s, SELF, MSG)), "");
            check("step: the chooser holds it -> assign (signIn=" + s + ")", "assign".equals(Lifted.smsRoleStep(self, s, SELF, MSG)), "");
        }
        check("step: the sign-in apply gives the role to want, whoever holds it", "assign".equals(Lifted.smsRoleStep(other, true, SELF, MSG)), "");
        check("step: sign-in assigns through an unreadable list", "assign".equals(Lifted.smsRoleStep(null, true, SELF, MSG)), "");
        check("step: the repair NEVER replaces an app the profile chose", "leave".equals(Lifted.smsRoleStep(other, false, SELF, MSG)), "");
        check("step: mid-session leaves an unreadable list alone", "leave".equals(Lifted.smsRoleStep(null, false, SELF, MSG)), "");
        check("step: mid-session, the chooser among the holders -> assign", "assign".equals(Lifted.smsRoleStep(otherAndSelf, false, SELF, MSG)), "");

        // ---- substituteAppName: "Messages" on a message notice, "Phone" on a call (NWP-20261123-24) ----
        check("name: sms", "Messages".equals(Lifted.substituteAppName("sms")), Lifted.substituteAppName("sms"));
        check("name: mms", "Messages".equals(Lifted.substituteAppName("mms")), Lifted.substituteAppName("mms"));
        check("name: call is Phone", "Phone".equals(Lifted.substituteAppName("call")), Lifted.substituteAppName("call"));
        check("name: another kind is Messages (rcs)", "Messages".equals(Lifted.substituteAppName("rcs")), Lifted.substituteAppName("rcs"));
        check("name: another kind is Messages (null)", "Messages".equals(Lifted.substituteAppName(null)), Lifted.substituteAppName(null));

        // ---- roamedSmsComponents ----
        List<String> comps = Arrays.asList(Lifted.roamedSmsComponents());
        check("components: no duplicates", new HashSet<>(comps).size() == comps.size(), comps);
        for (String keep : new String[]{".CredentialService", ".MessagingSuppressor", ".MmsDownloadedReceiver",
                ".ChooserActivity", ".AdminReceiver"}) {
            check("components: never disables " + keep + " (a roamed user needs it)", !comps.contains(keep), comps);
        }

        // ---- senderTitle / lookUpSender: a session's message notice names its sender (NWP-20261201-29) ----
        final String NUM = "+15550100";
        check("title: a saved contact shows the name", "Alice".equals(Lifted.senderTitle(NUM, "Alice")), Lifted.senderTitle(NUM, "Alice"));
        check("title: the name is trimmed", "Alice".equals(Lifted.senderTitle(NUM, " Alice ")), Lifted.senderTitle(NUM, " Alice "));
        check("title: a blank name falls back to the number", NUM.equals(Lifted.senderTitle(NUM, "  ")), Lifted.senderTitle(NUM, "  "));
        check("title: no name falls back to the number", NUM.equals(Lifted.senderTitle(NUM, null)), Lifted.senderTitle(NUM, null));
        check("title: an empty number and no name", "New message".equals(Lifted.senderTitle("", null)), Lifted.senderTitle("", null));
        check("title: no number and no name", "New message".equals(Lifted.senderTitle(null, null)), Lifted.senderTitle(null, null));
        check("lookup: a number in a roamed user", Lifted.lookUpSender(NUM, 10), "");
        check("lookup: never in user 0 (the gate)", !Lifted.lookUpSender(NUM, 0), "");
        check("lookup: not for an empty number", !Lifted.lookUpSender("", 10), "");
        check("lookup: not for a blank number", !Lifted.lookUpSender("  ", 10), "");
        check("lookup: not for no number", !Lifted.lookUpSender(null, 10), "");

        manifestChecks(args[0], comps);
        drawableChecks(args[0]);
        messageDrawableChecks(args[0]);
        pinChecks(args[1], args[2]);
        unknownRecordChecks(args[1]);

        System.out.println(runs + " checks, " + fails + " failed");
        if (fails > 0) System.exit(1);
    }

    // The components whose intent filters make the chooser a default-SMS-app candidate, read from the manifest, must be
    // exactly the ones disabled in a roamed user; and the substitute-name permission must be requested.
    static void manifestChecks(String path, List<String> comps) throws Exception {
        final String A = "http://schemas.android.com/apk/res/android";
        javax.xml.parsers.DocumentBuilderFactory f = javax.xml.parsers.DocumentBuilderFactory.newInstance();
        f.setNamespaceAware(true);
        org.w3c.dom.Document d = f.newDocumentBuilder().parse(new java.io.File(path));
        Set<String> smsSchemes = new HashSet<>(Arrays.asList("sms", "smsto", "mms", "mmsto"));
        Set<String> found = new TreeSet<>();
        for (String tag : new String[]{"activity", "receiver", "service", "activity-alias"}) {
            org.w3c.dom.NodeList nl = d.getElementsByTagName(tag);
            for (int i = 0; i < nl.getLength(); i++) {
                org.w3c.dom.Element e = (org.w3c.dom.Element) nl.item(i);
                String name = e.getAttributeNS(A, "name");
                if (name.startsWith("com.nowhere.chooser.")) name = name.substring("com.nowhere.chooser".length());
                org.w3c.dom.NodeList filters = e.getElementsByTagName("intent-filter");
                for (int j = 0; j < filters.getLength(); j++) {
                    org.w3c.dom.Element fl = (org.w3c.dom.Element) filters.item(j);
                    Set<String> actions = new HashSet<>(), schemes = new HashSet<>();
                    org.w3c.dom.NodeList an = fl.getElementsByTagName("action");
                    for (int k = 0; k < an.getLength(); k++) actions.add(((org.w3c.dom.Element) an.item(k)).getAttributeNS(A, "name"));
                    org.w3c.dom.NodeList dn = fl.getElementsByTagName("data");
                    for (int k = 0; k < dn.getLength(); k++) schemes.add(((org.w3c.dom.Element) dn.item(k)).getAttributeNS(A, "scheme"));
                    boolean smsData = !Collections.disjoint(schemes, smsSchemes);
                    if (actions.contains("android.provider.Telephony.SMS_DELIVER")
                            || actions.contains("android.provider.Telephony.WAP_PUSH_DELIVER")
                            || (actions.contains("android.intent.action.SENDTO") && smsData)
                            || (actions.contains("android.intent.action.VIEW") && smsData)
                            || (actions.contains("android.intent.action.RESPOND_VIA_MESSAGE") && smsData)) {
                        found.add(name);
                    }
                }
            }
        }
        check("manifest: found the chooser's SMS components at all", !found.isEmpty(), found);
        check("manifest: SMS-handling components == roamedSmsComponents", found.equals(new TreeSet<>(comps)),
                "manifest " + found + " vs list " + new TreeSet<>(comps));
        boolean perm = false;
        org.w3c.dom.NodeList up = d.getElementsByTagName("uses-permission");
        for (int i = 0; i < up.getLength(); i++) {
            if ("android.permission.SUBSTITUTE_NOTIFICATION_APP_NAME".equals(((org.w3c.dom.Element) up.item(i)).getAttributeNS(A, "name"))) perm = true;
        }
        check("manifest: requests SUBSTITUTE_NOTIFICATION_APP_NAME (else the framework strips the name)", perm, "");
        boolean observe = false;
        for (int i = 0; i < up.getLength(); i++) {
            if ("android.permission.OBSERVE_ROLE_HOLDERS".equals(((org.w3c.dom.Element) up.item(i)).getAttributeNS(A, "name"))) observe = true;
        }
        check("manifest: requests OBSERVE_ROLE_HOLDERS (else the SMS-app capture never hears a change)", observe, "");
    }

    // NWP-20261123-24: the call notices' small icon, res/drawable/ic_notif_call.xml beside the manifest. A small icon is
    // flattened to one tinted alpha mask, so it must be a vector of one white path on a transparent field.
    static void drawableChecks(String manifestPath) throws Exception {
        final String A = "http://schemas.android.com/apk/res/android";
        java.io.File f = new java.io.File(new java.io.File(manifestPath).getAbsoluteFile().getParentFile(), "res/drawable/ic_notif_call.xml");
        check("drawable: ic_notif_call.xml exists", f.isFile(), f);
        if (!f.isFile()) return;
        javax.xml.parsers.DocumentBuilderFactory df = javax.xml.parsers.DocumentBuilderFactory.newInstance();
        df.setNamespaceAware(true);
        org.w3c.dom.Document d;
        try {
            d = df.newDocumentBuilder().parse(f);
        } catch (Exception e) {
            check("drawable: ic_notif_call.xml parses", false, e);
            return;
        }
        org.w3c.dom.Element root = d.getDocumentElement();
        check("drawable: ic_notif_call is a <vector>", "vector".equals(root.getLocalName()), root.getLocalName());
        org.w3c.dom.NodeList paths = d.getElementsByTagName("path");
        check("drawable: ic_notif_call has exactly one path", paths.getLength() == 1, paths.getLength());
        if (paths.getLength() < 1) return;
        String fill = ((org.w3c.dom.Element) paths.item(0)).getAttributeNS(A, "fillColor");
        check("drawable: ic_notif_call is white (#FFFFFFFF)", "#FFFFFFFF".equals(fill), fill);
    }

    // NWP-20261201-29: a message notice's small icon is the envelope. It has two paths, and a small icon is flattened to
    // its alpha, so every path must be opaque white.
    static void messageDrawableChecks(String manifestPath) throws Exception {
        final String A = "http://schemas.android.com/apk/res/android";
        java.io.File f = new java.io.File(new java.io.File(manifestPath).getAbsoluteFile().getParentFile(), "res/drawable/ic_notif_message.xml");
        check("drawable: ic_notif_message.xml exists", f.isFile(), f);
        if (!f.isFile()) return;
        javax.xml.parsers.DocumentBuilderFactory df = javax.xml.parsers.DocumentBuilderFactory.newInstance();
        df.setNamespaceAware(true);
        org.w3c.dom.Document d;
        try {
            d = df.newDocumentBuilder().parse(f);
        } catch (Exception e) {
            check("drawable: ic_notif_message.xml parses", false, e);
            return;
        }
        org.w3c.dom.Element root = d.getDocumentElement();
        check("drawable: ic_notif_message is a <vector>", "vector".equals(root.getLocalName()), root.getLocalName());
        org.w3c.dom.NodeList paths = d.getElementsByTagName("path");
        check("drawable: ic_notif_message has a path", paths.getLength() >= 1, paths.getLength());
        for (int i = 0; i < paths.getLength(); i++) {
            String fill = ((org.w3c.dom.Element) paths.item(i)).getAttributeNS(A, "fillColor");
            check("drawable: ic_notif_message path " + i + " is white (#FFFFFFFF)", "#FFFFFFFF".equals(fill), fill);
        }
    }

    // The wiring, pinned byte for byte: every pins/<Class>.<name>.txt must occur EXACTLY ONCE in <Class>.java. None of
    // it can run without Android, and each way it breaks silently changes the text: a role step called with the wrong
    // signIn, a repair with no delay, a null cursor or a throw read as "gone", a read-back that ignores the op, a notice
    // without its public version or its name, the MMS tag reverted, a listener that never starts its clear or its
    // capture, a regrant dropped, a capture or a marker written at the wrong time.
    static void pinChecks(String srcDir, String pinsDir) throws Exception {
        java.io.File[] pins = new java.io.File(pinsDir).listFiles((d, n) -> n.endsWith(".txt"));
        check("pins: found", pins != null && pins.length >= 30, pins == null ? "none" : pins.length);
        if (pins == null) return;
        Arrays.sort(pins);
        for (java.io.File f : pins) {
            String n = f.getName();
            String cls = n.substring(0, n.indexOf('.'));
            String name = n.substring(n.indexOf('.') + 1, n.length() - 4);
            String src = new String(java.nio.file.Files.readAllBytes(new java.io.File(srcDir, cls + ".java").toPath()),
                    java.nio.charset.StandardCharsets.UTF_8);
            String pin = new String(java.nio.file.Files.readAllBytes(f.toPath()), java.nio.charset.StandardCharsets.UTF_8);
            if (pin.endsWith("\n")) pin = pin.substring(0, pin.length() - 1);
            pinned(cls + "." + name, src, pin);
        }
    }

    // NWP-20261123-23: in applyAtSignIn (comments and literals blanked), the branch recordUnknown guards gives Messaging
    // the role and writes neither a marker nor the record, and it is the if of an if/else that ends the lock: the
    // marker write sits in the else, so the unreadable-record path leaves the lock without reaching it.
    static void unknownRecordChecks(String srcDir) throws Exception {
        String raw = new String(java.nio.file.Files.readAllBytes(new java.io.File(srcDir, "SmsRoleRoam.java").toPath()),
                java.nio.charset.StandardCharsets.UTF_8);
        String src = blank(raw);
        final String U = "source: applyAtSignIn: ";
        int a = src.indexOf("static void applyAtSignIn(");
        int bo = a < 0 ? -1 : src.indexOf('{', a), bc = close(src, bo);
        if (bc < 0) { check(U + "found 'static void applyAtSignIn(' and its body", false, "missing"); return; }
        String body = src.substring(bo, bc + 1);
        int l = body.indexOf("synchronized (LOCK) {");
        int lo = l < 0 ? -1 : body.indexOf('{', l), lc = close(body, lo);
        if (lc < 0) { check(U + "found 'synchronized (LOCK) {' and its block", false, "missing"); return; }
        String lock = body.substring(lo, lc + 1);
        int g = lock.indexOf("if (recordUnknown(");
        int first = body.indexOf("recordUnknown(");
        boolean once = g >= 0 && first >= 0 && body.indexOf("recordUnknown(", first + 1) < 0;
        check(U + "guards on 'if (recordUnknown(' inside the lock, once", once, g < 0 ? "missing" : "found more than once");
        if (g < 0) return;
        int co = lock.indexOf('(', g), cc = close(lock, co);
        int ro = cc < 0 ? -1 : lock.indexOf('{', cc), rc = close(lock, ro);
        if (rc < 0 || !lock.substring(cc + 1, ro).trim().isEmpty()) {
            check(U + "the recordUnknown guard has a braced branch", false, "missing '{' after the condition");
            return;
        }
        String branch = lock.substring(ro, rc + 1);
        check(U + "the unreadable-record branch writes no marker", !branch.contains("write(ctx, MARKER"), branch);
        check(U + "the unreadable-record branch writes no record", !branch.contains("write(ctx, RECORD"), branch);
        int eh = branch.indexOf("ensureHolder(ctx, me, MESSAGING, true"),
                gr = branch.indexOf("ChooserActivity.grantMessagingRestrictedRead(ctx)");
        check(U + "the unreadable-record branch gives Messaging the role, then the #150 grant", eh >= 0 && gr > eh, branch);
        String rest = lock.substring(rc + 1);
        int eo = rest.indexOf('{'), ec = close(rest, eo);
        boolean ifElse = eo >= 0 && rest.substring(0, eo).trim().equals("else") && ec >= 0
                && rest.substring(eo, ec + 1).contains("write(ctx, MARKER")
                && rest.substring(ec + 1, rest.length() - 1).trim().isEmpty();
        check(U + "the unreadable-record branch leaves the lock before the marker write (if/else)", ifElse, rest);
    }

    // src with every comment and the contents of every string and char literal replaced by spaces (newlines and quotes
    // kept), so a brace or a call named in a comment or a log line is never read as code. The length does not change.
    static String blank(String s) {
        StringBuilder b = new StringBuilder(s);
        int i = 0, n = s.length();
        while (i < n) {
            char c = s.charAt(i);
            if (c == '/' && i + 1 < n && s.charAt(i + 1) == '/') {
                while (i < n && s.charAt(i) != '\n') b.setCharAt(i++, ' ');
            } else if (c == '/' && i + 1 < n && s.charAt(i + 1) == '*') {
                int e = s.indexOf("*/", i + 2);
                e = e < 0 ? n : e + 2;
                for (; i < e; i++) if (s.charAt(i) != '\n') b.setCharAt(i, ' ');
            } else if (c == '"' || c == '\'') {
                i++;
                while (i < n && s.charAt(i) != c && s.charAt(i) != '\n') {
                    if (s.charAt(i) == '\\' && i + 1 < n) b.setCharAt(i++, ' ');
                    b.setCharAt(i++, ' ');
                }
                i++;
            } else {
                i++;
            }
        }
        return b.toString();
    }

    // The index of the brace or parenthesis closing the one at open (in blanked text), or -1.
    static int close(String s, int open) {
        if (open < 0 || open >= s.length()) return -1;
        char o = s.charAt(open), c = o == '{' ? '}' : o == '(' ? ')' : 0;
        if (c == 0) return -1;
        int depth = 0;
        for (int i = open; i < s.length(); i++) {
            if (s.charAt(i) == o) depth++;
            else if (s.charAt(i) == c && --depth == 0) return i;
        }
        return -1;
    }

    static void pinned(String name, String src, String pin) {
        int at = src.indexOf(pin);
        if (at >= 0 && src.indexOf(pin, at + 1) < 0) {
            check("pinned: " + name, true, "");
            return;
        }
        if (at >= 0) {
            check("pinned: " + name, false, "occurs more than once");
            return;
        }
        String[] want = pin.split("\n", -1);
        int sig = src.indexOf(want[0]);
        if (sig < 0) {
            check("pinned: " + name, false, "its first line is gone: " + want[0].trim());
            return;
        }
        String[] got = src.substring(sig).split("\n", -1);
        for (int i = 0; i < want.length; i++) {
            String g = i < got.length ? got[i] : "<end of file>";
            if (!want[i].equals(g)) {
                check("pinned: " + name, false, "line " + (i + 1) + " differs\n     want: " + want[i] + "\n     have: " + g);
                return;
            }
        }
        check("pinned: " + name, false, "no line differs, yet the text does not match");
    }
}
