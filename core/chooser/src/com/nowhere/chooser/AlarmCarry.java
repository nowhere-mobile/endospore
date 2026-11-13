package com.nowhere.chooser;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;

/** NWP-20261129-39: the evidence for the backlog row "A clock alarm set in a roamed session did not ring, and showed as
 *  missed when the clock was opened". Its path (3) is a fresh sign-in whose clock app never registered its alarms again,
 *  and only a `dumpsys alarm` on the device could show that. So a sign-out writes its next alarm's time here, the file
 *  seals with the chooser's files dir (as nowhere-apps.list does), and the first relay after the next sign-in compares it
 *  with the alarm that session has now. The result goes to login.log as tokens: never the time itself.
 *
 *  The file is reported once. Neither method throws: this is evidence, so it must never stop a sign-out or end the relay
 *  thread. Pure (java.io and java.lang only) so test-alarm-carry-java.sh can run it under javac. Both methods are
 *  synchronized because the post-seal and the cold-lock relays run on separate threads. */
final class AlarmCarry {
    static final String FILE = "nowhere-alarm-carry";
    private static final int MAX_BYTES = 32; // a long's decimal digits fit; a longer file is damage, not a time

    private AlarmCarry() {}

    /** A sign-out's next alarm: when > 0 writes its decimal milliseconds by temp and rename, otherwise deletes the file.
     *  A failed write removes its temp file. */
    static synchronized void record(File dir, long when) {
        File f = new File(dir, FILE);
        if (when <= 0L) {
            f.delete();
            return;
        }
        File tmp = new File(dir, FILE + ".tmp");
        boolean moved = false;
        try {
            try (FileOutputStream o = new FileOutputStream(tmp)) {
                o.write(Long.toString(when).getBytes("US-ASCII"));
            }
            moved = tmp.renameTo(f);
        } catch (IOException | RuntimeException e) {
            moved = false;
        } finally {
            if (!moved) tmp.delete();
        }
    }

    /** null when no sign-out left a file; otherwise reads it, deletes it and answers
     *  "sealed=<past|future|bad> now=<none|same|earlier|later>". sealed: bad for a file that does not hold a positive
     *  time, past when that time is <= nowMs, else future. now: the session's registered alarm against that time, none
     *  when registered <= 0. A bad file's time counts as 0, so its registered alarm reads later. */
    static synchronized String verdict(File dir, long nowMs, long registered) {
        File f = new File(dir, FILE);
        if (!f.exists()) return null;
        long sealed = read(f);
        f.delete();
        String was = sealed <= 0L ? "bad" : sealed <= nowMs ? "past" : "future";
        String now = registered <= 0L ? "none"
                : registered == sealed ? "same"
                : registered < sealed ? "earlier" : "later";
        return "sealed=" + was + " now=" + now;
    }

    /** The file's time, or 0 for a file that cannot be read or does not hold a number. */
    private static long read(File f) {
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] b = new byte[MAX_BYTES + 1];
            int n = 0;
            for (int r; n < b.length && (r = in.read(b, n, b.length - n)) > 0; ) n += r;
            if (n > MAX_BYTES) return 0L;
            long v = Long.parseLong(new String(b, 0, n, "US-ASCII"));
            return v > 0L ? v : 0L;
        } catch (IOException | RuntimeException e) {
            return 0L;
        }
    }
}
