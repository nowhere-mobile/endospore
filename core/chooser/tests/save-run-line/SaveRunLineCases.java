// SaveRunLineCases -- NWP-20261202-37: executes Your data's running-save headline (saveRunHead and startedAgo, which
// test-save-run-line-java.sh lifts from ProfileActivity.java into SaveRunLifted with the five frame readers they call)
// against made-up SEAL-STATUS frames. C11 runs the lifted SEAL-STATUS readers (SealStatusLifted: sealStatus(),
// sealStatus(String[]), sealReasonOf and the sealStatusReason field) against the scripted daemon below, in the overlap
// RF-001 found: the sign-out loop gets FAILED NOCREDIT, Your data's poll reads SEAL-STATUS before the loop copies the
// reason, and the reason must still be there. Prints `ok   <name>` or `FAIL <name>: got ... want ...`; exits 1 on any
// failure.
public final class SaveRunLineCases {
    private static final long NOW = 1700000000L;
    private static int cases = 0, fails = 0;

    private static void eq(String name, String got, String want) {
        cases++;
        if (got == null ? want == null : got.equals(want)) { System.out.println("ok   " + name); return; }
        fails++;
        System.out.println("FAIL " + name + ": got " + (got == null ? "null" : "\"" + got + "\"")
                + " want " + (want == null ? "null" : "\"" + want + "\""));
    }

    private static String head(String run, String prog, long start) {
        return SaveRunLifted.saveRunHead(run, prog, start, NOW);
    }

    // C11: the sign-out loop's FAILED reply and its REASON survive a poll read between the reply and the loop's copy.
    private static void overlap() {
        SealStatusLifted pa = new SealStatusLifted();
        DaemonSocket.replies.add("FAILED NOCREDIT\nREASON Your credit ran out.\n");
        String st = pa.sealStatus();                                 // the sign-out loop's read
        DaemonSocket.replies.add("SEALING save 12582912 41943040 vault\n");
        String polled = pa.sealStatus(new String[1]); // the poll's read, before the loop copies
        DaemonSocket.replies.add(null);                              // and one whose connect times out
        String lost = pa.sealStatus(new String[1]);
        eq("C11 sign-out reply", st, "FAILED NOCREDIT");
        eq("C11 poll reply", polled, "SEALING save 12582912 41943040 vault");
        eq("C11 timed-out poll reply", lost, null);
        eq("C11 sign-out reason after two poll reads", pa.sealStatusReason, "Your credit ran out.");
        String[] r = new String[1];
        DaemonSocket.replies.add("FAILED NOCREDIT\nREASON Your credit ran out.\n");
        pa.sealStatus(r);
        eq("C11 poll reader returns its own reason", r[0], "Your credit ran out.");
    }

    public static void main(String[] args) {
        eq("C1 no run", head("", "save 12582912 41943040 vault", NOW - 180), null);
        eq("C2 periodic, no frame, no start", head("periodic", "", 0), "Saving automatically now…");
        eq("C3 periodic, bytes, started 3 min ago", head("periodic", "save 12582912 41943040 vault", NOW - 180),
                "Saving automatically — your files…  12 MB of 40 MB\nStarted 3 min ago.");
        eq("C4 periodic, sizes phase shows no bytes", head("periodic", "sizes 3 9 media", NOW - 180),
                "Saving automatically — your photos & media…\nStarted 3 min ago.");
        eq("C5 periodic, zero total is no usable frame", head("periodic", "save 0 0 vault", NOW - 180),
                "Saving automatically now…\nStarted 3 min ago.");
        eq("C6 manual, bytes", head("manual", "save 12582912 41943040 apps", NOW - 180),
                "Backing up your apps…  12 MB of 40 MB\nStarted 3 min ago.");
        eq("C7 started 75 s ago", head("periodic", "", NOW - 75), "Saving automatically now…\nStarted just now.");
        eq("C8 started 2 h ago", head("periodic", "", NOW - 7200), "Saving automatically now…\nStarted 2 hours ago.");
        eq("C9 old 4-field frame", head("periodic", "save 5 10", 0), "Saving automatically — your data…  1 KB of 1 KB");
        eq("C10 logoff is automatic", head("logoff", "save 12582912 41943040 vault", 0),
                "Saving automatically — your files…  12 MB of 40 MB");
        overlap();
        System.out.println(cases + " cases, " + fails + " failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}

// The daemon socket, scripted: each connect() takes the next reply; a null reply is a connect that timed out.
final class DaemonSocket {
    static final java.util.LinkedList<String> replies = new java.util.LinkedList<>();

    static LocalSocket connect() {
        String r = replies.isEmpty() ? null : replies.poll();
        return r == null ? null : new LocalSocket(r);
    }
}

final class LocalSocket {
    private final java.io.ByteArrayInputStream in;
    private final java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();

    LocalSocket(String reply) { in = new java.io.ByteArrayInputStream(reply.getBytes(java.nio.charset.StandardCharsets.UTF_8)); }
    void setSoTimeout(int ms) { }
    java.io.OutputStream getOutputStream() { return out; }
    java.io.InputStream getInputStream() { return in; }
    void close() { }
}
