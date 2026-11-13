package com.nowhere.chooser;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Deque;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** The behaviour of the launch barrier (NWP-20261130-03, 2b), with the platform and the daemon faked. */
public class OdDataBarrierCases {
    static int failed = 0;

    static void chk(String name, boolean ok, Object got) {
        if (ok) System.out.println("  ok    " + name);
        else { System.out.println("  FAIL  " + name + " (got " + got + ")"); failed++; }
    }

    static class Fake implements OdDataBarrier.Seam {
        final Deque<String> answers = new ArrayDeque<>();
        String lastAnswer = "NO";
        boolean suspended, lastFailedDialog, suspendOk = true, unsuspendOk = true, claimed;
        int asks, suspends, unsuspends, confirms;
        boolean confirmedAfterSuspend;
        final Set<String> marks = new HashSet<>();
        final List<String> log = new ArrayList<>();
        Fake(String... a) { answers.addAll(Arrays.asList(a)); }
        public String ask(String p) { asks++; if (!answers.isEmpty()) lastAnswer = answers.poll(); return lastAnswer; }
        public boolean suspend(String p, boolean f) { suspends++; lastFailedDialog = f; if (!suspendOk) return false; suspended = true; return true; }
        public boolean unsuspend(String p) { unsuspends++; if (!unsuspendOk) return false; suspended = false; return true; }
        public void mark(String p) { marks.add(p); confirmedAfterSuspend = false; }
        public void confirm(String p) { confirms++; confirmedAfterSuspend = suspended; }
        public void unmark(String p) { marks.remove(p); }
        public boolean marked(String p) { return marks.contains(p); }
        public boolean claimedElsewhere(String p) { return claimed; }
        public void log(String l) { log.add(l); }
        int logged(String part) { int n = 0; for (String l : log) if (l.contains(part)) n++; return n; }
    }

    static final String P = "org.example.parked";

    public static void main(String[] a) {
        c1(); c2(); c3(); c4(); c5(); c6(); c7(); c8(); c9(); c10(); c11(); c12(); c13(); w1(); w2(); w3(); w4(); w5();
        System.out.println(failed == 0 ? "== all barrier cases passed" : "== " + failed + " barrier case(s) failed");
        System.exit(failed == 0 ? 0 : 1);
    }

    // An unfetched package added from outside is suspended at its package-added event, and marked as ours.
    static void c1() {
        Fake f = new Fake("YES", "YES");
        boolean held = OdDataBarrier.onAdded(f, P);
        chk("C1 listed: held", held, held);
        chk("C1 listed: suspended", f.suspended, f.suspended);
        chk("C1 listed: marked", f.marks.contains(P), f.marks);
        chk("C1 listed: the restoring dialog", !f.lastFailedDialog, f.lastFailedDialog);
        chk("C1 listed: confirmed after the suspension", f.confirms == 1 && f.confirmedAfterSuspend, f.confirms);
    }

    // A package not on the list is untouched.
    static void c2() {
        Fake f = new Fake("NO");
        boolean held = OdDataBarrier.onAdded(f, "org.example.other");
        chk("C2 unlisted: not held", !held, held);
        chk("C2 unlisted: no suspend call", f.suspends == 0, f.suspends);
        chk("C2 unlisted: no mark", f.marks.isEmpty(), f.marks);
    }

    // The fetch lands: an OK reply and a confirmed NO lift the hold, and only then.
    static void c3() {
        Fake f = new Fake("YES", "YES", "NO");
        OdDataBarrier.onAdded(f, P);
        chk("C3 before the reply: still suspended", f.suspended, f.suspended);
        chk("C3 before the reply: no unsuspend", f.unsuspends == 0, f.unsuspends);
        OdDataBarrier.afterReply(f, P, "OK " + P);
        chk("C3 landed: unsuspended", !f.suspended, f.suspended);
        chk("C3 landed: mark removed", f.marks.isEmpty(), f.marks);
    }

    // OK is not proof by itself: while the daemon still says the data is out, the app stays closed.
    static void c4() {
        Fake f = new Fake("YES", "YES", "YES");
        OdDataBarrier.onAdded(f, P);
        OdDataBarrier.afterReply(f, P, "OK NOSRC");
        chk("C4 OK but still out: suspended", f.suspended, f.suspended);
        chk("C4 OK but still out: no unsuspend", f.unsuspends == 0, f.unsuspends);
        chk("C4 OK but still out: mark kept", f.marks.contains(P), f.marks);
    }

    // A failed fetch keeps the app suspended, the dialog says so, and it is logged once however often it is retried.
    static void c5() {
        Fake f = new Fake("YES", "YES");
        OdDataBarrier.onAdded(f, P + ".f");
        OdDataBarrier.afterReply(f, P + ".f", "ERR-NOTREADY");
        OdDataBarrier.afterReply(f, P + ".f", "ERR-NOTREADY");
        chk("C5 failed fetch: suspended", f.suspended, f.suspended);
        chk("C5 failed fetch: no unsuspend", f.unsuspends == 0, f.unsuspends);
        chk("C5 failed fetch: the failed dialog", f.lastFailedDialog, f.lastFailedDialog);
        chk("C5 failed fetch: logged once", f.logged("did not arrive") == 1, f.log);
        chk("C5 failed fetch: mark kept", f.marks.contains(P + ".f"), f.marks);
    }

    // A delayed or busy RESTORE-ODDATA does not leave it launchable, and does not say the fetch failed.
    static void c6() {
        for (String r : new String[] {"ERR-WORKER-BUSY", "", "ERR-TIMEOUT", null}) {
            Fake f = new Fake("YES", "YES");
            OdDataBarrier.onAdded(f, P + ".busy");
            OdDataBarrier.afterReply(f, P + ".busy", r);
            String n = "C6 reply [" + r + "]";
            chk(n + ": suspended", f.suspended, f.suspended);
            chk(n + ": no unsuspend", f.unsuspends == 0, f.unsuspends);
            chk(n + ": the restoring dialog stands", !f.lastFailedDialog, f.lastFailedDialog);
        }
    }

    // No answer from the daemon and an unreadable list count as data out: an unknown state never leaves an app launchable.
    static void c7() {
        for (String r : new String[] {"", "UNKNOWN", "ERR-PKG", null}) {
            Fake f = new Fake(r == null ? "" : r, r == null ? "" : r);
            if (r == null) { f.answers.clear(); f.lastAnswer = null; }
            boolean held = OdDataBarrier.onAdded(f, P);
            chk("C7 answer [" + r + "]: held", held && f.suspended, held);
        }
    }

    // The restore landed between the question and the suspension: nothing else would lift this hold.
    static void c8() {
        Fake f = new Fake("YES", "NO");
        boolean held = OdDataBarrier.onAdded(f, P);
        chk("C8 race: not held", !held, held);
        chk("C8 race: suspension lifted", !f.suspended && f.unsuspends == 1, f.unsuspends);
        chk("C8 race: mark removed", f.marks.isEmpty(), f.marks);
    }

    // A refused suspension is not recorded as a hold and is logged.
    static void c9() {
        Fake f = new Fake("YES");
        f.suspendOk = false;
        boolean held = OdDataBarrier.onAdded(f, P);
        chk("C9 refused: not held", !held, held);
        chk("C9 refused: no mark", f.marks.isEmpty(), f.marks);
        chk("C9 refused: logged", f.logged("could not suspend") == 1, f.log);
        chk("C9 refused: not confirmed", f.confirms == 0, f.confirms);
    }

    // Another handset's claim also needs the app suspended: the barrier ends without lifting it.
    static void c10() {
        Fake f = new Fake("YES", "YES", "NO");
        f.claimed = true;
        OdDataBarrier.onAdded(f, P);
        OdDataBarrier.afterReply(f, P, "OK");
        chk("C10 claimed: no unsuspend", f.unsuspends == 0, f.unsuspends);
        chk("C10 claimed: stays suspended", f.suspended, f.suspended);
        chk("C10 claimed: mark removed", f.marks.isEmpty(), f.marks);
    }

    // A release the framework refuses keeps the mark, so a later reply or reconcile can try again.
    static void c11() {
        Fake f = new Fake("YES", "YES", "NO");
        OdDataBarrier.onAdded(f, P);
        f.unsuspendOk = false;
        OdDataBarrier.afterReply(f, P, "OK");
        chk("C11 refused release: mark kept", f.marks.contains(P), f.marks);
        f.unsuspendOk = true;
        OdDataBarrier.afterReply(f, P, "OK");
        chk("C11 retried release: unsuspended", !f.suspended && f.marks.isEmpty(), f.marks);
    }

    // A reply for a package this barrier does not hold does nothing, not even a question.
    static void c12() {
        Fake f = new Fake();
        OdDataBarrier.afterReply(f, "org.example.plain", "OK");
        chk("C12 not held: no question", f.asks == 0, f.asks);
        chk("C12 not held: no unsuspend", f.unsuspends == 0, f.unsuspends);
    }

    // A process start reconciles the marks with what is installed, and holds what the dead process never saw.
    static void c13() {
        Fake f = new Fake("NO", "YES", "YES", "YES", "NO");
        f.marks.addAll(Arrays.asList("a.done", "b.out", "c.gone"));
        List<String> retried = new ArrayList<>();
        // installed is walked in this order after the marks: d.missed answers YES twice (the add and its re-check), e.plain NO
        OdDataBarrier.reconcile(f, new ArrayList<>(Arrays.asList("a.done", "b.out", "c.gone")),
                Arrays.asList("a.done", "b.out", "d.missed", "e.plain"), retried::add);
        chk("C13 data came back: mark removed", !f.marks.contains("a.done"), f.marks);
        chk("C13 data still out: mark kept", f.marks.contains("b.out"), f.marks);
        chk("C13 the two holds confirmed", f.confirms == 2, f.confirms);
        chk("C13 not installed: mark removed", !f.marks.contains("c.gone"), f.marks);
        chk("C13 data still out and the missed install: retried", retried.equals(Arrays.asList("b.out", "d.missed")), retried);
        chk("C13 the install the dead process missed: held", f.marks.contains("d.missed"), f.marks);
        chk("C13 an app not listed: untouched", !f.marks.contains("e.plain"), f.marks);
    }

    /** RF-013: the platform as the user-0 watcher sees it. relay and sweep are all it can do: the session chooser process is
     *  absent, so nothing else hears the install. A relay starts that process, modelled by handing it a fresh Fake. */
    static class Plat implements OdDataBarrier.Watch.Platform {
        int current = 11;
        boolean unlocked = true;
        final Fake session;
        final List<String> retried = new ArrayList<>();
        boolean heldAtRetry;
        int relays, sweeps;
        Plat(Fake session) { this.session = session; }
        public int currentUser() { return current; }
        public boolean unlocked(int u) { return unlocked; }
        public void relay(int u, String p) {
            relays++;
            OdDataBarrier.onRelayed(session, p, q -> { retried.add(q); heldAtRetry = session.suspended && session.marks.contains(q); });
        }
        public void sweep(int u) { sweeps++; }
    }

    // RF-013: the session chooser process is absent when the install lands. The app is suspended with nobody opening the
    // chooser, and the restore is asked for only after the hold stands.
    static void w1() {
        Fake f = new Fake("YES", "YES");
        Plat p = new Plat(f);
        new OdDataBarrier.Watch().onAdded(p, 11, P, "com.nowhere.chooser");
        chk("W1 process absent: relayed once", p.relays == 1, p.relays);
        chk("W1 process absent: suspended", f.suspended, f.suspended);
        chk("W1 process absent: marked and confirmed", f.marks.contains(P) && f.confirms == 1, f.marks);
        chk("W1 process absent: the restore is asked for", p.retried.equals(Arrays.asList(P)), p.retried);
        chk("W1 process absent: the hold stands before the restore", p.heldAtRetry, p.heldAtRetry);
    }

    // A relayed app whose data is home is left alone, and no restore is asked for.
    static void w2() {
        Fake f = new Fake("NO");
        Plat p = new Plat(f);
        new OdDataBarrier.Watch().onAdded(p, 11, P, "com.nowhere.chooser");
        chk("W2 unlisted: relayed", p.relays == 1, p.relays);
        chk("W2 unlisted: no suspend call", f.suspends == 0, f.suspends);
        chk("W2 unlisted: no restore asked for", p.retried.isEmpty(), p.retried);
    }

    // The gate's own user, the chooser itself and an event with no package are not session installs.
    static void w3() {
        Plat p = new Plat(new Fake());
        OdDataBarrier.Watch w = new OdDataBarrier.Watch();
        p.current = 0; // the gate in front: the one state in which a user-0 event would otherwise pass as current
        w.onAdded(p, 0, P, "com.nowhere.chooser");
        chk("W3 user 0: no relay", p.relays == 0, p.relays);
        p.current = 11;
        w.onAdded(p, 11, "com.nowhere.chooser", "com.nowhere.chooser");
        chk("W3 the chooser itself: no relay", p.relays == 0, p.relays);
        w.onAdded(p, 11, null, "com.nowhere.chooser");
        w.onAdded(p, 11, "", "com.nowhere.chooser");
        chk("W3 no package: no relay", p.relays == 0, p.relays);
        w.onUserChange(p);
        chk("W3 nothing waited: no sweep", p.sweeps == 0, p.sweeps);
    }

    // An install before the switch waits: `in` is still writing the session's files. The switch sweeps once.
    static void w4() {
        Plat p = new Plat(new Fake());
        p.current = 0;
        OdDataBarrier.Watch w = new OdDataBarrier.Watch();
        w.onAdded(p, 11, P, "com.nowhere.chooser");
        chk("W4 not current: no relay", p.relays == 0, p.relays);
        w.onUserChange(p);
        chk("W4 still not current: no sweep", p.sweeps == 0, p.sweeps);
        p.current = 11;
        w.onUserChange(p);
        chk("W4 the switch: one sweep", p.sweeps == 1, p.sweeps);
        w.onUserChange(p);
        chk("W4 the next change: no second sweep", p.sweeps == 1, p.sweeps);
    }

    // A current session still locked waits for its unlock: a broadcast to a locked user reaches nothing.
    static void w5() {
        Plat p = new Plat(new Fake());
        p.unlocked = false;
        OdDataBarrier.Watch w = new OdDataBarrier.Watch();
        w.onAdded(p, 11, P, "com.nowhere.chooser");
        chk("W5 locked: no relay", p.relays == 0, p.relays);
        w.onUserChange(p);
        chk("W5 still locked: no sweep", p.sweeps == 0, p.sweeps);
        p.unlocked = true;
        w.onUserChange(p);
        chk("W5 the unlock: one sweep", p.sweeps == 1, p.sweeps);
    }
}
