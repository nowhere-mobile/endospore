import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

/** NWP-20261013-41: the gate banner names each line's notices under that line's label, counted by events. */
public class TelBannerCases {
    static int pass = 0, fail = 0;
    static void eq(String what, String want, String got) {
        if (Objects.equals(want, got)) { pass++; System.out.println("  ok    " + what); }
        else { fail++; System.out.println("  FAIL  " + what + "\n        want: " + want + "\n        got:  " + got); }
    }
    static void yes(String what, boolean b) { eq(what, "true", String.valueOf(b)); }
    // {label, kind, count, lost, singleText}
    static String[] n(String label, String kind, int count) { return new String[]{label, kind, "" + count, "false", "rich " + label}; }
    static String[] loss(String label, String kind) { return new String[]{label, kind, "1", "true", "rich loss"}; }
    static String sum(String[]... ns) { return Lifted.summarize(new ArrayList<>(Arrays.asList(ns))); }
    static String read(String f) throws Exception { return new String(Files.readAllBytes(Paths.get(f)), StandardCharsets.UTF_8); }

    public static void main(String[] a) throws Exception {
        String P = "✉   ";
        System.out.println("== the summary ==");
        eq("nothing pending shows nothing", null, sum());
        eq("one notice for one event keeps its rich text", P + "rich Sim1", sum(n("Sim1", "message", 1)));
        eq("one line, a call and a message (Chester's first case)", P + "Sim1 — Missed call · New message",
                sum(n("Sim1", "call", 1), n("Sim1", "message", 1)));
        eq("two lines (Chester's second case)", P + "Sim1 — New message · an unassigned SIM — Missed call · New message",
                sum(n("Sim1", "message", 1), n("an unassigned SIM", "call", 1), n("an unassigned SIM", "message", 1)));
        eq("two texts on Sim1 and one on the unassigned line", P + "Sim1 — 2 new messages · an unassigned SIM — New message",
                sum(n("Sim1", "message", 2), n("an unassigned SIM", "message", 1)));
        eq("one notice standing for two texts names its line and the count", P + "Sim1 — 2 new messages", sum(n("Sim1", "message", 2)));
        eq("one notice standing for three missed calls", P + "Sim1 — 3 missed calls", sum(n("Sim1", "call", 3)));
        eq("lines keep first-seen order, not label order", P + "b — New message · a — New message",
                sum(n("b", "message", 1), n("a", "message", 1)));
        eq("a line's notices group even when other lines sit between them", P + "Sim1 — Missed call · New message · Sim2 — New message",
                sum(n("Sim1", "call", 1), n("Sim2", "message", 1), n("Sim1", "message", 1)));
        eq("an empty label groups without a name", P + "Missed call · New message", sum(n("", "call", 1), n("", "message", 1)));
        eq("an unnamed line beside a named one", P + "New message · Sim1 — New message", sum(n("", "message", 1), n("Sim1", "message", 1)));
        eq("a loss notice is counted and keeps its wording", P + "Sim1 — New message · 1 may not have been saved",
                sum(n("Sim1", "message", 1), loss("Sim1", "message")));
        eq("a lone loss notice shows its own text", P + "rich loss", sum(loss("", "call")));
        eq("two loss notices are counted", P + "2 may not have been saved", sum(loss("", "call"), loss("", "message")));
        eq("a count on a call and a message add per kind", P + "Sim1 — 2 missed calls · 4 new messages",
                sum(n("Sim1", "call", 2), n("Sim1", "message", 4)));

        System.out.println("== the wiring ==");
        String ca = read(a[0]), sd = read(a[1]);
        yes("the receiver reads the active notice's count", sd.contains("old.getNotification().extras") && sd.contains("ox.getInt(\"nowhere_count\", 1)) + 1"));
        yes("the receiver stores the running count on the notice", sd.contains("nx.putInt(\"nowhere_count\", count);"));
        yes("the receiver names a second arrival '2 new messages' keeping the '  -  <label>' suffix",
                sd.contains("title = count + (isCall") && sd.contains("\" new messages\"") && sd.contains("title + \"  -  \" + line"));
        yes("the receiver looks the old notice up by the id it posts under", sd.contains("old.getId() != nid") && sd.contains("nm.notify(TEL_CHANNEL, nid, b.build());"));
        yes("the banner reads each notice's count and its line", ca.contains("ex.getInt(\"nowhere_count\", 1)") && ca.contains("notices.add(new String[]{noticeLabel(sbn),"));
        yes("telNoticeSummary hands telNotices' entries to summarize", ca.contains("return n == null ? null : summarize(n);"));
        System.out.println("passed " + pass + ", failed " + fail);
        System.exit(fail == 0 ? 0 : 1);
    }
}
