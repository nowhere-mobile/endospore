import android.os.SystemClock;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

/** NWP-20261022-11: TelArrival's side of the v2 SEAL-TEL wire, run against core/agent/testdata/tel-wire-v2.txt. The
 *  class under test is the real TelArrival lifted by name (run.sh); the daemon's Go test reads the same fixture.
 *  Exit 0 every case passed, 1 a case failed, 2 the fixture does not read. */
public final class TelWireCases {
    private static int failures, checks;

    private static void check(String what, boolean ok, String detail) {
        checks++;
        if (ok) { System.out.println("ok " + what); return; }
        failures++;
        System.out.println("FAIL " + what + ": " + detail);
    }

    private static void eq(String what, Object want, Object got) {
        check(what, want.equals(got), "want <" + show(want) + "> got <" + show(got) + ">");
    }

    private static String show(Object o) {
        return String.valueOf(o).replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t");
    }

    private static String unescape(String s, int lineNo) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c != '\\') { b.append(c); continue; }
            if (++i >= s.length()) bad(lineNo, "a trailing backslash");
            switch (s.charAt(i)) {
                case '\\': b.append('\\'); break;
                case 'n': b.append('\n'); break;
                case 't': b.append('\t'); break;
                default: bad(lineNo, "the escape \\" + s.charAt(i));
            }
        }
        return b.toString();
    }

    private static void bad(int lineNo, String why) {
        System.out.println("tel-wire fixture line " + lineNo + ": " + why);
        System.exit(2);
    }

    public static void main(String[] args) throws IOException {
        List<String[]> reqs = new ArrayList<>(), reps = new ArrayList<>();
        List<String> lines = Files.readAllLines(Paths.get(args[0]), StandardCharsets.UTF_8);
        for (int n = 0; n < lines.size(); n++) {
            String line = lines.get(n);
            if (line.isEmpty() || line.startsWith("#")) continue;
            String[] raw = line.split("\t", -1);
            String[] f = new String[raw.length];
            for (int i = 0; i < raw.length; i++) f[i] = unescape(raw[i], n + 1);
            if (f[0].equals("REQ-TEL") && f.length == 13) reqs.add(f);
            else if (f[0].equals("REPLY") && f.length == 10) reps.add(f);
            else bad(n + 1, f.length + " fields of a " + f[0] + " record do not parse");
        }
        if (reqs.isEmpty() || reps.isEmpty()) bad(0, "needs both REQ-TEL and REPLY cases, got " + reqs.size() + " and " + reps.size());

        for (String[] c : reqs) request(c);
        for (String[] c : reps) reply(c);
        ids();
        mmsPreference();
        retryResendsTheSameRequest(reqs.get(0));
        deadlineBound();

        System.out.println(checks + " checks, " + failures + " failed");
        System.exit(failures == 0 ? 0 : 1);
    }

    // REQ-TEL: type, case, aid, kind, sub, iccid, from, when, mono, body, callType, durSec, request
    private static String built(String[] c) {
        return TelArrival.telRequest(c[2], Long.parseLong(c[8]), c[3], Integer.parseInt(c[4]), c[5], c[6],
                Long.parseLong(c[7]), c[9], Integer.parseInt(c[10]), Integer.parseInt(c[11]));
    }

    private static void request(String[] c) {
        String name = c[1];
        eq(name + ": telRequest is the fixture's bytes", c[12], built(c));
        int sub = Integer.parseInt(c[4]);
        long when = Long.parseLong(c[7]);
        String id = c[3].equals("sms") ? TelArrival.smsId(sub, when, c[6], c[9]) : TelArrival.callId(sub, when);
        eq(name + ": the arrival id is the fixture's", c[2], id);
        check(name + ": the arrival id is 64 lower-case hex", id.matches("[0-9a-f]{64}"), id);
    }

    // REPLY: type, case, line, kind, vis, label, sealed, liveUid, stripped, partial
    private static void reply(String[] c) {
        TelArrival.Reply r = TelArrival.parse(c[2]);
        String name = c[1];
        eq(name + ": kind", c[3], r.kind);
        eq(name + ": vis", c[4], r.vis);
        eq(name + ": label", c[5], r.label);
        eq(name + ": liveUid", Integer.parseInt(c[7]), r.liveUid);
        eq(name + ": stripped", c[8].equals("1"), r.stripped);
        eq(name + ": partial", c[9].equals("1"), r.partial);
    }

    private static void ids() {
        String s = TelArrival.smsId(1, 5L, "+1", "hi");
        eq("smsId is stable", s, TelArrival.smsId(1, 5L, "+1", "hi"));
        check("smsId differs by sub", !s.equals(TelArrival.smsId(2, 5L, "+1", "hi")), "same id");
        check("smsId differs by when", !s.equals(TelArrival.smsId(1, 6L, "+1", "hi")), "same id");
        check("smsId differs by from", !s.equals(TelArrival.smsId(1, 5L, "+2", "hi")), "same id");
        check("smsId differs by body", !s.equals(TelArrival.smsId(1, 5L, "+1", "ho")), "same id");
        String c = TelArrival.callId(1, 5L);
        check("callId is 64 lower-case hex", c.matches("[0-9a-f]{64}"), c);
        eq("callId is stable", c, TelArrival.callId(1, 5L));
        check("callId differs by sub", !c.equals(TelArrival.callId(2, 5L)), "same id");
        check("callId differs by time", !c.equals(TelArrival.callId(1, 6L)), "same id");
        String m = TelArrival.mmsId(1, "T", "L", 5L);
        check("mmsId is 64 lower-case hex", m.matches("[0-9a-f]{64}"), m);
        eq("mmsId is stable", m, TelArrival.mmsId(1, "T", "L", 5L));
        check("mmsId differs by sub", !m.equals(TelArrival.mmsId(2, "T", "L", 5L)), "same id");
        check("smsId, callId and mmsId do not collide", !s.equals(c) && !s.equals(m) && !c.equals(m), "a collision");
    }

    private static void mmsPreference() {
        eq("mmsId: a transaction id outranks the location and the time",
                TelArrival.mmsId(1, "T", "L1", 1L), TelArrival.mmsId(1, "T", "L2", 2L));
        check("mmsId: the transaction id matters",
                !TelArrival.mmsId(1, "T", "L1", 1L).equals(TelArrival.mmsId(1, "U", "L1", 1L)), "same id");
        check("mmsId: a transaction id is not the same as none",
                !TelArrival.mmsId(1, "T", "L1", 1L).equals(TelArrival.mmsId(1, "", "L1", 1L)), "same id");
        eq("mmsId: no transaction id uses the location, not the time",
                TelArrival.mmsId(1, "", "L1", 1L), TelArrival.mmsId(1, null, "L1", 2L));
        check("mmsId: the location matters without a transaction id",
                !TelArrival.mmsId(1, "", "L1", 1L).equals(TelArrival.mmsId(1, "", "L2", 1L)), "same id");
        eq("mmsId: with neither it uses the time", TelArrival.mmsId(1, null, null, 7L), TelArrival.mmsId(1, "", "", 7L));
        check("mmsId: the time matters with neither",
                !TelArrival.mmsId(1, "", "", 7L).equals(TelArrival.mmsId(1, "", "", 8L)), "same id");
    }

    // The chooser half of "a repeated arrival id": every attempt at one arrival sends the same bytes.
    private static void retryResendsTheSameRequest(String[] c) {
        String req = built(c);
        DaemonSocket.reset(0L, null, "ERR busy", "OK open TA== 1");
        TelArrival.Reply r = TelArrival.untilAnswered(req, 5000, TelArrival.stamp() + 60_000L, c[5]);
        check("retry: the OK is returned", r != null && "OK".equals(r.kind), String.valueOf(r == null ? null : r.kind));
        eq("retry: three attempts", 3, DaemonSocket.sent.size());
        boolean same = true;
        for (String s : DaemonSocket.sent) same &= s.equals(req);
        check("retry: every attempt sends the identical request", same, String.valueOf(DaemonSocket.sent.size()));
    }

    // 10 s per round trip against a deadline 15 s ahead: attempt 0 ends at +10 s and waits 1 s, attempt 1 ends at +20 s
    // and its wait runs past the deadline, so the second ERR is returned.
    private static void deadlineBound() {
        DaemonSocket.reset(10_000L, "ERR nobody open", "ERR nobody number", "ERR nobody private", "ERR nobody open");
        TelArrival.Reply r = TelArrival.untilAnswered("SEAL-TEL\nv2\nx\n", 5000, TelArrival.stamp() + 15_000L, "89440000000000000044");
        int n = DaemonSocket.sent.size();
        check("deadline: stops within three attempts", n >= 1 && n <= 3, "sent " + n);
        check("deadline: returns the last ERR", r != null && "ERR".equals(r.kind) && n >= 1
                && r.vis.equals(new String[] {"open", "number", "private", "open"}[n - 1]), r == null ? "null" : r.kind + " " + r.vis);
    }
}
