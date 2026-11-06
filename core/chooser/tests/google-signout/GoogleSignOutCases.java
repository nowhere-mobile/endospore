package com.nowhere.chooser;

/**
 * Cases for GoogleSignOut (NWP-20261107-11). Arguments, computed by the suite from outside the class under test:
 * <ascii-hash> <roamd-ascii-hash> <utf8-hash> <roamd-utf8-hash>, for the names ASCII_NAME and UTF8_NAME below.
 */
public final class GoogleSignOutCases {
    static final String ASCII_NAME = "test.account@example.com";
    static final String UTF8_NAME = "tést.accöunt@example.com";
    static int fails = 0;

    static void eq(String what, Object want, Object got) {
        if (java.util.Objects.equals(want, got)) return;
        System.out.println("  FAIL " + what + ": want [" + want + "] got [" + got + "]");
        fails++;
    }


    /** In-memory marks file with injectable failures and a pause inside read() to force interleavings. */
    static final class Mem implements GoogleSignOut.Store {
        String content = null; // null = absent
        boolean failRead, failWrite, failDelete;
        long readPauseMs = 0;
        public synchronized String read() throws java.io.IOException {
            if (failRead) throw new java.io.IOException("read");
            String c = content == null ? "" : content;
            if (readPauseMs > 0) {
                try { wait(readPauseMs); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            }
            return c;
        }
        public synchronized void write(String c) throws java.io.IOException {
            if (failWrite) throw new java.io.IOException("write");
            content = c;
        }
        public synchronized void delete() throws java.io.IOException {
            if (failDelete) throw new java.io.IOException("delete");
            content = null;
        }
    }

    static java.util.Set<String> set(String... hs) { return new java.util.HashSet<>(java.util.Arrays.asList(hs)); }

    static void lifecycle() throws Exception {
        String h1 = "a".repeat(64), h2 = "b".repeat(64);
        Mem m = new Mem(), j = new Mem();
        eq("mark on absent", true, GoogleSignOut.mark(m, j, h1));
        eq("mark content", h1 + "\n", m.content);
        eq("mark journals first", h1 + "\n", j.content);
        m.failWrite = true;
        eq("mark write failure reported", false, GoogleSignOut.mark(m, j, h2));
        eq("mark write failure leaves the file", h1 + "\n", m.content);
        m.failWrite = false; m.failRead = true;
        eq("mark read failure reported", false, GoogleSignOut.mark(m, j, h2));
        eq("mark read failure leaves the file", h1 + "\n", m.content);
        m = new Mem(); j = new Mem(); j.failWrite = true;
        eq("journal failure writes no mark", false, GoogleSignOut.mark(m, j, h1));
        eq("journal failure: no mark", null, m.content);

        // rollback: precise, then the fail-closed fallbacks; the journal entry ends with it
        m = new Mem(); j = new Mem(); m.content = h1 + "\n" + h2 + "\n"; j.content = h1 + "\n";
        eq("unmark ok", true, GoogleSignOut.unmark(m, j, h1));
        eq("unmark keeps the other mark", h2 + "\n", m.content);
        eq("unmark settles the journal", null, j.content);
        m.content = h2 + "\n"; j.content = h2 + "\n";
        eq("unmark of the last deletes the file", true, GoogleSignOut.unmark(m, j, h2));
        eq("unmark of the last: file gone", null, m.content);
        m = new Mem(); m.content = h1 + "\n" + h2 + "\n"; m.failWrite = true;
        eq("unmark write failure falls back", true, GoogleSignOut.unmark(m, new Mem(), h1));
        eq("unmark write failure: no mark survives", null, m.content);
        m = new Mem(); m.content = h1 + "\n" + h2 + "\n"; m.failRead = true;
        eq("unmark read failure falls back", true, GoogleSignOut.unmark(m, new Mem(), h1));
        eq("unmark read failure: no mark survives", null, m.content);

        // RF-001: the rollback cannot land. The journal keeps the entry on disk, so a sweep in a NEW process (a fresh
        // Mem pair over the same contents, no static memory) withdraws the mark even though the account vanished.
        m = new Mem(); j = new Mem(); m.content = h1 + "\n"; j.content = h1 + "\n"; m.failRead = true; m.failDelete = true;
        eq("rf1: rollback cannot land", false, GoogleSignOut.unmark(m, j, h1));
        eq("rf1: the journal entry stays", h1 + "\n", j.content);
        eq("rf1: sweep while storage fails", false, GoogleSignOut.sweep(m, j, () -> set(h1)));
        eq("rf1: the mark is still on disk", h1 + "\n", m.content);
        m.failRead = false; m.failDelete = false;
        final String disk = m.content, jdisk = j.content;
        Mem m2 = new Mem(), j2 = new Mem(); m2.content = disk; j2.content = jdisk; // the next process
        eq("rf1: fresh-process sweep, account gone", true, GoogleSignOut.sweep(m2, j2, () -> set()));
        eq("rf1: the stale mark is gone", null, m2.content);
        eq("rf1: the journal is settled", null, j2.content);

        // a sign-out that completed: no journal entry, account gone -> the mark is left for roamd
        m = new Mem(); j = new Mem();
        eq("done: claim", true, GoogleSignOut.claim(h1));
        eq("done: mark", true, GoogleSignOut.mark(m, j, h1));
        eq("done: settle", true, GoogleSignOut.settle(j, h1));
        GoogleSignOut.release(h1);
        eq("done: journal empty", null, j.content);
        eq("done: sweep with the account gone", true, GoogleSignOut.sweep(m, j, () -> set()));
        eq("done: the mark survives", h1 + "\n", m.content);
        // ... but one whose journal could not be cleared is withdrawn (the safe direction)
        j.content = h1 + "\n";
        eq("unsettled: sweep", true, GoogleSignOut.sweep(m, j, () -> set()));
        eq("unsettled: the mark is withdrawn", null, m.content);

        // a chooser that died mid-removal: claim gone, journal open, account still present
        m = new Mem(); j = new Mem(); m.content = h1 + "\n"; j.content = h1 + "\n";
        eq("died: sweep", true, GoogleSignOut.sweep(m, j, () -> set(h1)));
        eq("died: no mark", null, m.content);

        // an unreadable journal withdraws every mark that is not in flight
        m = new Mem(); j = new Mem(); m.content = h1 + "\n"; j.failRead = true;
        eq("journal lost: reported", false, GoogleSignOut.sweep(m, j, () -> set()));
        eq("journal lost: marks withdrawn", null, m.content);

        // a sign-out still in flight is never swept, and another account's mark is left alone
        m = new Mem(); j = new Mem(); m.content = h1 + "\n" + h2 + "\n"; j.content = h1 + "\n";
        eq("sweep: claim", true, GoogleSignOut.claim(h1));
        eq("sweep: claimed account skipped", true, GoogleSignOut.sweep(m, j, () -> set(h1, h2)));
        eq("sweep: only the unclaimed present account's mark goes", h1 + "\n", m.content);
        eq("sweep: the in-flight journal entry stays", h1 + "\n", j.content);
        GoogleSignOut.release(h1);
        m = new Mem(); m.content = h1 + "\n" + h2 + "\n"; m.failWrite = true;
        eq("sweep write failure falls back", true, GoogleSignOut.sweep(m, new Mem(), () -> set(h1)));
        eq("sweep write failure: no mark survives", null, m.content);
        m = new Mem();
        eq("sweep on an absent file", true, GoogleSignOut.sweep(m, new Mem(), () -> set(h1)));
        eq("sweep on an absent file creates nothing", null, m.content);

        // claim: one sign-out per account until released
        eq("claim", true, GoogleSignOut.claim(h1));
        eq("claim again refused", false, GoogleSignOut.claim(h1));
        eq("claim another account", true, GoogleSignOut.claim(h2));
        GoogleSignOut.release(h1); GoogleSignOut.release(h2);
        eq("claim after release", true, GoogleSignOut.claim(h1));
        GoogleSignOut.release(h1);

        // interleaving: two marks racing through a slow read both land
        m = new Mem(); m.readPauseMs = 150;
        final Mem mm = m;
        Thread t1 = new Thread(() -> GoogleSignOut.mark(mm, new Mem(), h1));
        Thread t2 = new Thread(() -> GoogleSignOut.mark(mm, new Mem(), h2));
        t1.start(); Thread.sleep(40); t2.start(); t1.join(); t2.join();
        eq("racing marks both land", h1 + "\n" + h2 + "\n", m.content);

        // interleaving: a rollback racing a mark neither loses the mark nor brings the rolled-back one back
        m = new Mem(); m.content = h1 + "\n"; m.readPauseMs = 150;
        final Mem rm = m;
        Thread u1 = new Thread(() -> GoogleSignOut.unmark(rm, new Mem(), h1));
        Thread u2 = new Thread(() -> GoogleSignOut.mark(rm, new Mem(), h2));
        u1.start(); Thread.sleep(40); u2.start(); u1.join(); u2.join();
        eq("racing rollback and mark", h2 + "\n", m.content);
    }

    public static void main(String[] a) throws Exception {
        if (a.length != 4) { System.out.println("usage: four hashes"); System.exit(2); }
        eq("markHash ascii = sha256sum", a[0], GoogleSignOut.markHash(ASCII_NAME));
        eq("markHash ascii = roamd acct_mark_hashes", a[1], GoogleSignOut.markHash(ASCII_NAME));
        eq("markHash utf8 = sha256sum", a[2], GoogleSignOut.markHash(UTF8_NAME));
        eq("markHash utf8 = roamd acct_mark_hashes", a[3], GoogleSignOut.markHash(UTF8_NAME));

        String h1 = "a".repeat(64), h2 = "b".repeat(64), h3 = "0123456789abcdef".repeat(4);
        eq("withMark on empty", h1 + "\n", GoogleSignOut.withMark("", h1));
        eq("withMark on null", h1 + "\n", GoogleSignOut.withMark(null, h1));
        eq("withMark appends after existing", h1 + "\n" + h2 + "\n", GoogleSignOut.withMark(h1 + "\n", h2));
        eq("withMark does not duplicate", h1 + "\n" + h2 + "\n", GoogleSignOut.withMark(h1 + "\n" + h2 + "\n", h1));
        eq("withMark adds the missing newline", h1 + "\n" + h2 + "\n", GoogleSignOut.withMark(h1, h2));
        eq("withMark drops garbage lines",
                h1 + "\n" + h2 + "\n",
                GoogleSignOut.withMark("junk\n" + h1 + "\n\nABCDEF" + "A".repeat(58) + "\n" + h1.substring(1) + "\n", h2));
        eq("withMark drops an upper-case hash", h2 + "\n", GoogleSignOut.withMark("A".repeat(64) + "\n", h2));
        eq("withoutMark of the only hash", "", GoogleSignOut.withoutMark(h1 + "\n", h1));
        eq("withoutMark of one of two", h2 + "\n", GoogleSignOut.withoutMark(h1 + "\n" + h2 + "\n", h1));
        eq("withoutMark of an absent hash", h1 + "\n", GoogleSignOut.withoutMark(h1 + "\n", h3));
        eq("withoutMark on empty", "", GoogleSignOut.withoutMark("", h1));
        eq("withoutMark drops garbage", h2 + "\n", GoogleSignOut.withoutMark("x\n" + h1 + "\n" + h2 + "\n", h1));

        eq("offered STORED online", true, GoogleSignOut.offered("STORED", false));
        eq("offered LOCAL online", false, GoogleSignOut.offered("LOCAL", false));
        eq("offered STORED offline", false, GoogleSignOut.offered("STORED", true));
        eq("offered UNKNOWN", false, GoogleSignOut.offered("UNKNOWN", false));
        eq("offered null", false, GoogleSignOut.offered(null, false));

        eq("ACCOUNT_TYPE", "com.google", GoogleSignOut.ACCOUNT_TYPE);
        eq("ROW_LABEL", "Sign out of Google", GoogleSignOut.ROW_LABEL);
        eq("GROUP_LABEL", "Google accounts", GoogleSignOut.GROUP_LABEL);
        eq("groupSubtitle 1", "1 account", GoogleSignOut.groupSubtitle(1));
        eq("groupSubtitle 4", "4 accounts", GoogleSignOut.groupSubtitle(4));
        eq("CONFIRM", "Signing out here removes this account from your profile at the next save. "
                + "Signing out in Android Settings does not stick.", GoogleSignOut.CONFIRM);
        eq("MARK_PREFIX", "nowhere-acct-mark-v1:", GoogleSignOut.MARK_PREFIX);
        eq("MARK_FILE", "nowhere-acct-marks", GoogleSignOut.MARK_FILE);
        eq("JOURNAL_FILE", "nowhere-acct-marks.pending", GoogleSignOut.JOURNAL_FILE);
        eq("failLine", "Couldn't sign out of Google (not removed).", GoogleSignOut.failLine("not removed"));

        lifecycle();

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
