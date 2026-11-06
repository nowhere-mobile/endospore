// NWP-20261011-63: the cases for DaemonSocket's one-line-reply tripwire helpers, run against Lifted (run.sh).
//
// The readers are built the way roundTrip and ProfileActivity.sendDaemon build theirs -- a BufferedReader over an
// InputStreamReader over a byte stream -- NOT over a StringReader: StringReader.ready() is always true, so a reply of
// exactly "OK\n" would read as "more buffered" there and never on the socket.
import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.InputStreamReader;
import java.io.PipedInputStream;
import java.io.PipedOutputStream;
import java.nio.charset.StandardCharsets;

public final class Cases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static BufferedReader reply(String s) {
        return new BufferedReader(new InputStreamReader(
                new ByteArrayInputStream(s.getBytes(StandardCharsets.UTF_8)), StandardCharsets.UTF_8));
    }

    public static void main(String[] a) throws Exception {
        // ---- verbOf: the only part of a request that may be logged ----
        String tel = "TEL-OWNER\nname\npass\n";
        check("verbOf TEL-OWNER", "TEL-OWNER".equals(Lifted.verbOf(tel)), Lifted.verbOf(tel));
        check("verbOf never carries a later line (the passphrase)", !Lifted.verbOf(tel).contains("pass")
                && !Lifted.verbOf(tel).contains("name"), Lifted.verbOf(tel));
        check("verbOf trims", "GET-BINDINGS".equals(Lifted.verbOf("  GET-BINDINGS \n")), Lifted.verbOf("  GET-BINDINGS \n"));
        check("verbOf a bare verb", "PING".equals(Lifted.verbOf("PING")), Lifted.verbOf("PING"));
        check("verbOf null is ?", "?".equals(Lifted.verbOf(null)), Lifted.verbOf(null));

        // ---- moreBuffered: after one readLine, is more of the reply already waiting? ----
        BufferedReader two = reply("OK\nrow\n");
        String first = two.readLine();
        check("multi-line reply: first line", "OK".equals(first), first);
        check("multi-line reply: more is buffered", Lifted.moreBuffered(two), false);
        String next = two.readLine();
        check("moreBuffered reads nothing: the next line is still there", "row".equals(next), next);

        BufferedReader one = reply("OK\n");
        one.readLine();
        check("one-line reply: nothing more", !Lifted.moreBuffered(one), true);

        BufferedReader unterminated = reply("OK");
        unterminated.readLine();
        check("unterminated one-line reply: nothing more", !Lifted.moreBuffered(unterminated), true);

        BufferedReader closed = reply("OK\nrow\n");
        closed.readLine();
        closed.close();
        check("a closed reader is false, not a throw", !Lifted.moreBuffered(closed), true);

        // The stated limit (DaemonSocket.moreBuffered): a later line that arrives AFTER the first read is not seen.
        // This pins the check as best-effort; if it ever starts seeing late lines, it has started blocking. The pipe's
        // writer is still open, so a blocking moreBuffered would wait forever: it runs on a thread with a cap, and
        // a call that does not return in time fails the case instead of hanging the suite.
        PipedOutputStream w = new PipedOutputStream();
        final BufferedReader late = new BufferedReader(new InputStreamReader(new PipedInputStream(w),
                StandardCharsets.UTF_8));
        w.write("OK\n".getBytes(StandardCharsets.UTF_8));
        w.flush();
        late.readLine();
        Boolean early = capped(late);
        check("a line not yet written is not seen, and the check does not block", Boolean.FALSE.equals(early), early);
        if (early != null) { // a blocked call still holds the reader; only a returned one leaves the pipe usable
            w.write("row\n".getBytes(StandardCharsets.UTF_8));
            w.flush();
            Boolean now = capped(late);
            check("... and is seen once it is buffered", Boolean.TRUE.equals(now), now);
        }

        System.out.println(runs + " checks, " + fails + " failed");
        System.exit(fails > 0 ? 1 : 0); // exit, not return: a blocked capped() thread must not keep the VM alive
    }

    /** moreBuffered(br) on a daemon thread; null when it has not returned within 2s (it blocked). */
    static Boolean capped(final BufferedReader br) throws InterruptedException {
        final Boolean[] out = new Boolean[1];
        Thread t = new Thread(() -> out[0] = Lifted.moreBuffered(br));
        t.setDaemon(true);
        t.start();
        t.join(2000);
        return t.isAlive() ? null : out[0];
    }
}
