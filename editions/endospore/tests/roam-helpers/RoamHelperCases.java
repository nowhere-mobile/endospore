package np;

import android.accounts.Account;
import android.accounts.IAccountManager;
import android.content.IContentService;
import android.content.SyncAdapterType;
import android.net.IVpnManager;
import android.os.FakeBinder;
import android.os.ServiceManager;
import android.system.Os;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

// NWP-20261010-15: the cases for np.SyncRoam, np.VpnAlwaysOn and the chooser's VPN picker statics (Lifted, run.sh).
// The helpers are compiled UNCHANGED from the tree against the fakes in fakes/, so their reflection runs for real.
//
// THE FAKE FRAMEWORK REFUSES WHAT THE REAL ONE REFUSES, SILENTLY, the way ContentService does on GrapheneOS: a
// per-account get answers false and a set does nothing when the CALLER (the fake Os uid -- the uid that opened
// /dev/binder) has no package, i.e. root (hasAccountAccess), or when no sync-adapter package is installed for the
// authority (hasAuthorityAccess). An account whose authenticator is absent is not listed at all. Those are the two
// defects the first cut of the helper shipped with, and the cases below fail on both.
public final class RoamHelperCases {
    static int fails = 0, runs = 0;
    static final String NAME = "alice secret%@example.com"; // a space and a % -- both must be escaped

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    // ---- the device's sync state ----
    static final class World {
        final List<String[]> accts = new ArrayList<>(); // {name, type}: every account in the db
        final Set<String> authTypes = new HashSet<>(); // account types whose authenticator is installed
        final List<String[]> adapters = new ArrayList<>(); // {type, authority}: registered (their package installed)
        final Map<String, Boolean> rows = new HashMap<>();
        boolean master = true;

        boolean hasAdapter(String auth) {
            for (String[] a : adapters) if (a[1].equals(auth)) return true;
            return false;
        }

        List<String[]> visible() {
            List<String[]> l = new ArrayList<>();
            for (String[] a : accts) if (authTypes.contains(a[1])) l.add(a);
            return l;
        }
    }

    // The system caller's view, for the pure decisions (what the relaunched helper sees).
    static final class Sys implements SyncRoam.Sync {
        final World w;
        final List<String> calls = new ArrayList<>();
        boolean deaf = false; // a set that does not stick
        boolean deafMaster = false; // a master set that does not stick
        final java.util.Set<String> unreadAuth = new HashSet<>(); // authorities whose reads throw
        boolean unreadMaster = false; // a master read that throws
        final java.util.Set<String> deafAuth = new HashSet<>(); // authorities whose sets do not stick

        Sys(World w) { this.w = w; }

        public List<String[]> accounts() { return w.visible(); }

        public List<String[]> adapters() { return w.adapters; }

        public boolean hasAdapter(String a) { return w.hasAdapter(a); }

        public boolean master() { if (unreadMaster) throw new IllegalStateException("unreadable"); return w.master; }

        public void setMaster(boolean on) { calls.add("master=" + on); if (!deaf && !deafMaster) w.master = on; }

        public boolean get(String n, String t, String a) {
            if (unreadAuth.contains(a)) throw new IllegalStateException("unreadable");
            if (!w.hasAdapter(a)) return false; // hasAuthorityAccess, as for any caller
            Boolean b = w.rows.get(t + "|" + a + "|" + n);
            return b != null && b;
        }

        public void set(String n, String t, String a, boolean on) {
            calls.add("set " + a + "=" + on);
            if (!w.hasAdapter(a) || deaf || deafAuth.contains(a)) return;
            w.rows.put(t + "|" + a + "|" + n, on);
        }
    }

    // The same world behind fake binder services: the caller is whoever the fake Os says the process is.
    static final class Fake implements IContentService, IAccountManager {
        final World w;
        String lastOpPackage;
        RuntimeException throwOnGet;

        Fake(World w) { this.w = w; }

        // The caller is whoever OPENED binder in this process (ServiceManager.openedAs); root has no package, so
        // hasAccountAccess is false for it.
        static boolean callerHasPackage() {
            Integer c = ServiceManager.openedAs;
            return c != null && c != 0;
        }

        public Account[] getAccountsAsUser(String type, int userId, String op) {
            lastOpPackage = op;
            List<String[]> v = w.visible();
            Account[] a = new Account[v.size()];
            for (int i = 0; i < a.length; i++) a[i] = new Account(v.get(i)[0], v.get(i)[1]);
            return a;
        }

        public SyncAdapterType[] getSyncAdapterTypesAsUser(int userId) {
            SyncAdapterType[] s = new SyncAdapterType[w.adapters.size()];
            for (int i = 0; i < s.length; i++) s[i] = new SyncAdapterType(w.adapters.get(i)[1], w.adapters.get(i)[0]);
            return s;
        }

        public String[] getSyncAdapterPackagesForAuthorityAsUser(String auth, int userId) {
            return w.hasAdapter(auth) ? new String[] {"pkg." + auth} : new String[0];
        }

        public boolean getMasterSyncAutomaticallyAsUser(int userId) { return w.master; }

        public void setMasterSyncAutomaticallyAsUser(boolean f, int userId) { w.master = f; }

        public boolean getSyncAutomaticallyAsUser(Account a, String p, int userId) {
            if (throwOnGet != null) throw throwOnGet;
            if (!callerHasPackage() || !w.hasAdapter(p)) return false;
            Boolean b = w.rows.get(a.type + "|" + p + "|" + a.name);
            return b != null && b;
        }

        public void setSyncAutomaticallyAsUser(Account a, String p, boolean s, int userId) {
            if (!callerHasPackage() || !w.hasAdapter(p)) return;
            w.rows.put(a.type + "|" + p + "|" + a.name, s);
        }
    }

    // ---- the relaunch, executed: a fake process launcher that runs the child as a FRESH process of its own ----
    // What the last relaunch did, for the cases to check.
    static List<String> lastCmd;
    static long lastBound = -1;
    static boolean childHangs, destroyed, unboundedWait;

    // A child "process": it inherits the parent's uid/gid (the fake Os), opens binder afresh (openedAs reset, fixed at
    // its first getService), and reads/writes the parent's streams ONLY if the builder inherited them -- otherwise its
    // stdin is empty and its stdout goes nowhere, exactly as with the real pipes nobody reads.
    static final class FakeChild extends Process {
        final ProcessBuilder pb;
        final ByteArrayInputStream in;
        final PrintStream out;
        int exit = -1;

        FakeChild(ProcessBuilder pb, ByteArrayInputStream in, PrintStream out) {
            this.pb = pb;
            this.in = in;
            this.out = out;
            lastCmd = new ArrayList<>(pb.command());
        }

        void runIt() {
            boolean inherit = pb.redirectInput() == ProcessBuilder.Redirect.INHERIT
                    && pb.redirectOutput() == ProcessBuilder.Redirect.INHERIT
                    && pb.redirectError() == ProcessBuilder.Redirect.INHERIT;
            java.io.InputStream cin = inherit ? in : new ByteArrayInputStream(new byte[0]);
            PrintStream cout = inherit ? out : new PrintStream(new ByteArrayOutputStream());
            List<String> c = pb.command();
            if (c.size() < 3 || !c.get(0).equals("/system/bin/app_process") || !c.get(1).equals("/system/bin")
                    || !c.get(2).equals("np.SyncRoam")) {
                exit = 127; // not something that would start this class
                return;
            }
            ServiceManager.openedAs = null; // a new process opens its own binder
            try {
                exit = SyncRoam.entry(c.subList(3, c.size()).toArray(new String[0]), cin, cout);
            } catch (Throwable t) {
                cout.println(SyncRoam.errLine(t));
                exit = 1;
            }
        }

        @Override
        public boolean waitFor(long t, java.util.concurrent.TimeUnit u) {
            lastBound = u.toSeconds(t);
            if (childHangs) return false;
            runIt();
            return true;
        }

        @Override
        public int waitFor() {
            unboundedWait = true; // a hung child would hang the parent, and roamd would kill it and orphan the child
            if (!childHangs) runIt();
            return exit;
        }

        @Override
        public int exitValue() { return exit; }

        @Override
        public void destroy() { destroyed = true; }

        @Override
        public java.io.OutputStream getOutputStream() { return new ByteArrayOutputStream(); }

        @Override
        public java.io.InputStream getInputStream() { return new ByteArrayInputStream(new byte[0]); }

        @Override
        public java.io.InputStream getErrorStream() { return new ByteArrayInputStream(new byte[0]); }
    }

    // As roamd runs it: app_process started as ROOT, which opened binder as root before main(); main's entry; the REAL
    // relaunchAsSystem, whose child the fake launcher runs.
    static String asRoamd(String mode, String stdin) throws Exception {
        ByteArrayOutputStream bo = new ByteArrayOutputStream();
        final PrintStream out = new PrintStream(bo, true, "UTF-8");
        final ByteArrayInputStream in = new ByteArrayInputStream(stdin.getBytes(StandardCharsets.UTF_8));
        Os.uid = 0;
        Os.gid = 0;
        ServiceManager.openedAs = 0;
        lastCmd = null;
        lastBound = -1;
        destroyed = false;
        unboundedWait = false;
        SyncRoam.relaunch = SyncRoam::relaunchAsSystem;
        SyncRoam.starter = pb -> new FakeChild(pb, in, out);
        int rc;
        try {
            rc = SyncRoam.entry(new String[] {mode, "10"}, in, out);
        } catch (Throwable t) {
            out.println(SyncRoam.errLine(t));
            rc = 1;
        }
        return rc + "|" + bo.toString("UTF-8");
    }

    static World world() {
        World w = new World();
        w.accts.add(new String[] {NAME, "com.google"});
        w.accts.add(new String[] {"bob", "org.dav"});
        w.authTypes.add("com.google");
        w.authTypes.add("org.dav");
        w.adapters.add(new String[] {"com.google", "gmail-ls"});
        w.adapters.add(new String[] {"com.google", "com.android.calendar"});
        w.adapters.add(new String[] {"org.dav", "contacts"});
        w.rows.put("com.google|gmail-ls|" + NAME, true);
        w.rows.put("org.dav|contacts|bob", true);
        return w;
    }

    static final String E = SyncRoam.enc(NAME);
    static final String WANT = "nowhere-sync 1\nmaster 1\n"
            + "sync 0 com.google com.android.calendar " + E + "\n"
            + "sync 1 com.google gmail-ls " + E + "\n"
            + "sync 1 org.dav contacts bob\nend 3\n";

    static SyncRoam.Parsed in(String text) { return SyncRoam.parse(text); }

    public static void main(String[] a) throws Exception {
        // ---- enc/dec ----
        for (String s : new String[] {NAME, "tab\there", "nl\nx\r", "100%", "ü@ñ", ""}) {
            check("enc has no space/control: " + s, !SyncRoam.enc(s).matches("(?s).*[\\x00-\\x20\\x7f].*"), SyncRoam.enc(s));
            check("dec(enc) round-trips: " + s, SyncRoam.dec(SyncRoam.enc(s)).equals(s), SyncRoam.dec(SyncRoam.enc(s)));
        }
        check("dec leaves a stray % alone", SyncRoam.dec("50%").equals("50%") && SyncRoam.dec("%zz").equals("%zz"), SyncRoam.dec("%zz"));

        // ---- H1: as roamd starts it (root), through the binder fakes ----
        World bw = world();
        Fake f = new Fake(bw);
        ServiceManager.SERVICES.put("content", new FakeBinder(f));
        ServiceManager.SERVICES.put("account", new FakeBinder(f));
        String c = asRoamd("capture", "");
        check("H1 capture as roamd starts it: the real switches, not the zeros a root caller is given", c.equals("0|" + WANT), c);
        check("H1: the work ran as the SYSTEM uid", Os.getuid() == SyncRoam.SYSTEM_UID && Os.gid == SyncRoam.SYSTEM_UID, Os.getuid());
        // F1: the relaunch itself -- what it starts, how it waits, what it passes on.
        check("relaunch: app_process, its parent dir, this class, then the arguments unchanged",
                List.of("/system/bin/app_process", "/system/bin", "np.SyncRoam", "capture", "10").equals(lastCmd), lastCmd);
        check("relaunch: the child is waited for with a bound, never unbounded", lastBound == SyncRoam.RELAUNCH_TIMEOUT_S && !unboundedWait,
                lastBound + " unbounded=" + unboundedWait);
        int roamdTimeout = a.length > 1 ? Integer.parseInt(a[1]) : 20;
        check("relaunch: its bound is strictly inside roamd's own timeout, so roamd never orphans the child",
                SyncRoam.RELAUNCH_TIMEOUT_S < roamdTimeout, SyncRoam.RELAUNCH_TIMEOUT_S + " vs " + roamdTimeout);
        Os.silentSetuid = true;
        String still0 = asRoamd("capture", "");
        Os.silentSetuid = false;
        check("relaunch: a setuid that silently changed nothing is refused -- never relaunched as root",
                still0.equals("1|ERR drop-failed\n") && lastCmd == null, still0 + " launched=" + lastCmd);
        childHangs = true;
        String hung = asRoamd("capture", "");
        childHangs = false;
        check("relaunch: a child that never answers is killed and the answer is ERR timeout", hung.equals("1|ERR timeout\n") && destroyed,
                hung + " destroyed=" + destroyed);
        check("accounts asked for as package \"android\"", "android".equals(f.lastOpPackage), f.lastOpPackage);
        bw.rows.clear();
        bw.master = false;
        String ap = asRoamd("apply", WANT);
        check("H1 apply as roamd starts it: OK", ap.equals("0|OK master=1 rows=3 applied=3 pending=0 mismatch=0\n"), ap);
        check("H1 apply: the switches really landed", bw.master && Boolean.TRUE.equals(bw.rows.get("com.google|gmail-ls|" + NAME))
                && Boolean.FALSE.equals(bw.rows.get("com.google|com.android.calendar|" + NAME)), bw.rows);

        // ---- capture, the system view ----
        World w = world();
        String cap = SyncRoam.capture(new Sys(w), in(""));
        check("capture: framed, sorted, per account type", cap.equals(WANT), cap);
        check("capture: stable bytes for an unchanged state", SyncRoam.capture(new Sys(w), in(cap)).equals(cap), "");

        // H2: an on-demand Gmail not installed this session -> no adapter package -> carried UNCHANGED, never re-read.
        World w2 = world();
        w2.adapters.remove(0);
        String cap2 = SyncRoam.capture(new Sys(w2), in(cap));
        check("H2 capture: an authority with no adapter package keeps the profile's 1", cap2.contains("sync 1 com.google gmail-ls " + E), cap2);
        // M1: an account whose authenticator is absent is invisible -> its rows carried unchanged.
        // As in a real session: apply skipped it (invisible), so the framework holds no row for it -- a re-read is 0.
        World w3 = world();
        w3.authTypes.remove("org.dav");
        w3.rows.remove("org.dav|contacts|bob");
        String cap3 = SyncRoam.capture(new Sys(w3), in(cap));
        check("M1 capture: an invisible account's switch is carried", cap3.contains("sync 1 org.dav contacts bob") && cap3.endsWith("end 3\n"), cap3);
        World w4 = world();
        w4.authTypes.clear();
        w4.master = false;
        check("capture: NO visible account carries every row unchanged",
                SyncRoam.capture(new Sys(w4), in(cap)).equals(cap.replace("master 1", "master 0")), "");
        // A visible account with an adapter is re-read live, so an in-session change is recorded.
        World w6 = world();
        w6.rows.put("com.google|gmail-ls|" + NAME, false);
        check("capture: a live change is recorded", SyncRoam.capture(new Sys(w6), in(cap)).contains("sync 0 com.google gmail-ls " + E), "");
        // A pend line the framework still cannot take: carried as it is, never re-read, and handed back after the capture.
        String pendG = "pend 1 com.google gmail-ls " + E + "\n";
        World w7 = world();
        w7.adapters.remove(0);
        w7.rows.put("com.google|gmail-ls|" + NAME, false);
        String cap7 = SyncRoam.capture(new Sys(w7), in(cap + pendG));
        check("capture: an unplaceable pend line is carried and handed back after `end`",
                cap7.contains("sync 1 com.google gmail-ls " + E) && cap7.endsWith("end 3\n" + pendG), cap7);
        // A placeable pend 1 over an untouched default 0: LANDED, recorded, no longer pending, and counted.
        World w5 = world();
        w5.rows.put("com.google|gmail-ls|" + NAME, false);
        String cap5 = SyncRoam.capture(new Sys(w5), in(cap + pendG));
        check("capture: a placeable pend 1 over the default 0 is landed, recorded, and no longer pending",
                cap5.contains("sync 1 com.google gmail-ls " + E) && !cap5.contains("pend ") && cap5.endsWith("stat landed=1 unstuck=0\n")
                        && Boolean.TRUE.equals(w5.rows.get("com.google|gmail-ls|" + NAME)), cap5);
        // A carried 1 whose write does not stick: KEPT pending for the next capture, recorded as the carried 1, counted.
        World w8 = world();
        w8.rows.put("com.google|gmail-ls|" + NAME, false);
        Sys deaf8 = new Sys(w8);
        deaf8.deaf = true;
        String cap8 = SyncRoam.capture(deaf8, in(cap + pendG));
        check("capture: a carried 1 that did not stick stays pending, recorded as 1, counted unstuck",
                cap8.contains("sync 1 com.google gmail-ls " + E) && cap8.endsWith(pendG + "stat landed=0 unstuck=1\n"), cap8);
        // H (round 3): the adapter is present but the ACCOUNT is not visible -> nothing is written, the line is kept.
        World w9 = world();
        w9.authTypes.remove("com.google");
        w9.rows.put("com.google|gmail-ls|" + NAME, false);
        Sys s9 = new Sys(w9);
        String cap9 = SyncRoam.capture(s9, in(cap + pendG));
        check("capture: a pend line for an invisible account is not written, only carried",
                !s9.calls.contains("set gmail-ls=true") && cap9.contains(pendG.trim()) && !cap9.contains("stat "), cap9 + s9.calls);

        // THE CLOBBER (the round-3 review's repro, modelled on its Clobber.java): the record holds gmail OFF; Gmail is
        // on-demand, so at sign-in it cannot be applied; the user opens Gmail and taps "Turn on"; the next capture must
        // record that 1 -- not write the old 0 back over it.
        World c1 = world();
        c1.rows.clear();
        c1.adapters.remove(0); // gmail-ls absent at sign-in
        String recOff = "nowhere-sync 1\nmaster 1\nsync 0 com.google com.android.calendar " + E + "\nsync 0 com.google gmail-ls " + E
                + "\nsync 1 org.dav contacts bob\nend 3\n";
        SyncRoam.Applied ca = SyncRoam.apply(new Sys(c1), in(recOff));
        check("clobber: a carried 0 that cannot be applied is NOT pending", ca.pending.isEmpty() && ca.line.contains(" pending=0 "), ca.line);
        c1.adapters.add(new String[] {"com.google", "gmail-ls"});  // the user opens Gmail; its adapter registers
        c1.rows.put("com.google|gmail-ls|" + NAME, true);         // ... and taps "Turn on"
        StringBuilder pl = new StringBuilder();
        for (SyncRoam.Row p : ca.pending) pl.append("pend ").append(p.on ? '1' : '0').append(' ').append(p.key()).append('\n');
        String cc = SyncRoam.capture(new Sys(c1), in(recOff + pl + "pend 0 com.google gmail-ls " + E + "\n"));
        check("clobber: the user's newer Turn on is recorded and stays on, even with a stray pend 0",
                cc.contains("sync 1 com.google gmail-ls " + E) && Boolean.TRUE.equals(c1.rows.get("com.google|gmail-ls|" + NAME)), cc);
        // ... and a carried 1 never fights the user either: if they turned it on already there is nothing to write.
        World c2 = world();
        c2.rows.put("com.google|gmail-ls|" + NAME, true);
        Sys sc2 = new Sys(c2);
        String cc2 = SyncRoam.capture(sc2, in(cap + pendG));
        check("capture: a pend 1 over a live 1 writes nothing and is no longer pending",
                !sc2.calls.contains("set gmail-ls=true") && cc2.contains("sync 1 com.google gmail-ls " + E) && !cc2.contains("pend ")
                        && !cc2.contains("stat "), cc2); // nothing landed, nothing unstuck: no counts line at all

        // ---- the retry of a FAILED apply: what did not land, only while nobody has changed it since ----
        String recR = "nowhere-sync 1\nmaster 1\nsync 0 com.google com.android.calendar " + E + "\nsync 1 com.google gmail-ls " + E
                + "\nsync 1 org.dav contacts bob\nend 3\n";
        World r1 = world();
        r1.rows.put("com.google|com.android.calendar|" + NAME, true);  // the carried 0 fails to turn it off
        r1.rows.remove("com.google|gmail-ls|" + NAME);                 // the carried 1 fails to land
        r1.master = false;
        Sys sr = new Sys(r1);
        sr.deafAuth.add("com.android.calendar");
        sr.deafAuth.add("gmail-ls");
        sr.deafMaster = true;                                          // ... and master fails too
        SyncRoam.Applied fa = SyncRoam.apply(sr, in(recR));
        StringBuilder hb = new StringBuilder();
        for (SyncRoam.Row x : fa.fixes) hb.append("fix ").append(x.on ? '1' : '0').append(' ').append(x.was).append(' ').append(x.key()).append('\n');
        hb.append("fixmaster ").append(fa.fixMaster ? '1' : '0').append(' ').append(fa.fixMasterWas).append('\n');
        check("failed apply: ERR; the two switches and master that did not land are handed back WITH their live value",
                fa.line.startsWith("ERR ") && fa.fixes.size() == 2 && Boolean.TRUE.equals(fa.fixMaster) && "0".equals(fa.fixMasterWas)
                        && hb.toString().contains("fix 0 1 com.google com.android.calendar") && hb.toString().contains("fix 1 0 com.google gmail-ls"), hb);
        // Nobody touches anything; the framework accepts writes now: the retry lands all three -- the 0 too (F1).
        Sys sr2 = new Sys(r1);
        SyncRoam.Applied ra = SyncRoam.retry(sr2, in(hb.toString()));
        check("retry, untouched since: the carried 0 is written (a failed OFF is not left ON)",
                ra.line.startsWith("OK ") && Boolean.FALSE.equals(r1.rows.get("com.google|com.android.calendar|" + NAME)), ra.line + r1.rows);
        check("retry, untouched since: the carried 1 lands, and master too", Boolean.TRUE.equals(r1.rows.get("com.google|gmail-ls|" + NAME))
                && r1.master, r1.rows + " master=" + r1.master);
        check("retry: a switch that DID land is not touched", !sr2.calls.contains("set contacts=true") && !sr2.calls.contains("set contacts=false"), sr2.calls);
        // Changed since the failure: the user turned gmail on and master on themselves -> nothing written, their values stand.
        World r4 = world();
        r4.rows.put("com.google|gmail-ls|" + NAME, true);
        r4.master = true;
        Sys sr4 = new Sys(r4);
        SyncRoam.Applied rd4 = SyncRoam.retry(sr4, in("fix 1 0 com.google gmail-ls " + E + "\nfixmaster 1 0\n"));
        check("retry, changed since: a row whose live value moved is left alone and dropped",
                !sr4.calls.contains("set gmail-ls=true") && !sr4.calls.contains("master=true") && rd4.fixes.isEmpty() && rd4.line.startsWith("OK "), sr4.calls + rd4.line);
        r4.master = false; // changed again: master now differs from the value after the failure (1)
        Sys sr5 = new Sys(r4);
        SyncRoam.retry(sr5, in("fixmaster 1 1\n"));
        check("retry, changed since: master is left alone too", !sr5.calls.contains("master=true") && !r4.master, sr5.calls);
        // A value-after-failure that could not be read: the conservative rule (no 0, a 1 only over a live 0).
        World r6 = world();
        r6.rows.put("com.google|com.android.calendar|" + NAME, true);
        r6.rows.put("com.google|gmail-ls|" + NAME, false);
        Sys sr6 = new Sys(r6);
        SyncRoam.retry(sr6, in("fix 0 - com.google com.android.calendar " + E + "\nfix 1 - com.google gmail-ls " + E + "\n"));
        check("retry, unknown value after failure: a 0 is never written, a 1 lands over a live 0",
                Boolean.TRUE.equals(r6.rows.get("com.google|com.android.calendar|" + NAME)) && Boolean.TRUE.equals(r6.rows.get("com.google|gmail-ls|" + NAME)), r6.rows);
        // No hand-back (the apply never answered): the whole record, conservatively -- never a 0, never master.
        World rw2 = world();
        rw2.rows.clear();
        rw2.rows.put("com.google|com.android.calendar|" + NAME, true);   // the user turned it on after the failure
        rw2.master = false;
        Sys srw2 = new Sys(rw2);
        SyncRoam.Applied rb = SyncRoam.retry(srw2, in(recR));
        check("retry from the whole record: the 1s land; the user's calendar on and master off stand",
                rb.line.startsWith("OK ") && Boolean.TRUE.equals(rw2.rows.get("com.google|gmail-ls|" + NAME)) && !rw2.master
                        && !srw2.calls.contains("master=true") && Boolean.TRUE.equals(rw2.rows.get("com.google|com.android.calendar|" + NAME)),
                rb.line + rw2.rows + srw2.calls);
        // An unreadable live value during the retry: handed back unchanged and NOT OK, never dropped (round 9).
        World r9 = world();
        r9.rows.remove("com.google|gmail-ls|" + NAME);
        Sys s9u = new Sys(r9);
        s9u.unreadAuth.add("gmail-ls");
        s9u.unreadMaster = true;
        SyncRoam.Applied ru = SyncRoam.retry(s9u, in("fix 1 0 com.google gmail-ls " + E + "\nfixmaster 1 0\n"));
        check("retry, unreadable now: the row and master are handed back unchanged and the answer is not OK",
                ru.line.startsWith("ERR ") && ru.fixes.size() == 1 && "0".equals(ru.fixes.get(0).was)
                        && Boolean.TRUE.equals(ru.fixMaster) && "0".equals(ru.fixMasterWas)
                        && !s9u.calls.contains("set gmail-ls=true") && !s9u.calls.contains("master=true"), ru.line + s9u.calls);

        // A switch the retry still cannot land is handed back again, with its new live value.
        World r3 = world();
        r3.rows.remove("com.google|gmail-ls|" + NAME);
        Sys sr3 = new Sys(r3);
        sr3.deafAuth.add("gmail-ls");
        SyncRoam.Applied rc = SyncRoam.retry(sr3, in("fix 1 0 com.google gmail-ls " + E + "\n"));
        check("retry: a switch that still does not stick is handed back", rc.line.startsWith("ERR ") && rc.fixes.size() == 1
                && "0".equals(rc.fixes.get(0).was), rc.line);

        // The run-level wiring: `retry` is its own mode, printed like apply.
        bw.rows.clear();
        String rr = asRoamd("retry", "fix 1 0 com.google gmail-ls " + E + "\n");
        check("run retry: the retry mode, not the apply, runs and answers counts",
                rr.equals("0|OK master=- rows=1 applied=1 pending=0 mismatch=0\n") && Boolean.TRUE.equals(bw.rows.get("com.google|gmail-ls|" + NAME)), rr);

        // ---- apply ----
        World f1 = world();
        f1.rows.clear();
        f1.master = false;
        f1.adapters.remove(0);          // gmail-ls: no package this session
        f1.authTypes.remove("org.dav"); // bob: authenticator absent
        Sys s1 = new Sys(f1);
        SyncRoam.Applied r = SyncRoam.apply(s1, in(cap));
        check("H2 apply: what cannot land is PENDING, not a mismatch -- the sign-in apply is OK",
                r.line.equals("OK master=1 rows=3 applied=1 pending=2 mismatch=0"), r.line);
        check("H2 apply: the pending rows are the gmail and the invisible-account ones", r.pending.size() == 2
                && r.pending.get(0).authority.equals("gmail-ls") && r.pending.get(1).name.equals("bob"), r.pending.size());
        check("apply: master is set LAST", s1.calls.get(s1.calls.size() - 1).equals("master=true"), s1.calls);
        check("apply: an explicit off is written, not skipped", s1.calls.contains("set com.android.calendar=false"), s1.calls);
        check("apply: never carries a name in its answer", !r.line.contains("alice") && !r.line.contains("bob"), r.line);
        // The pending retry: once the app is back, the pend line lands; a pend-only input touches no master.
        f1.adapters.add(new String[] {"com.google", "gmail-ls"});
        SyncRoam.Applied r2 = SyncRoam.apply(new Sys(f1), in("pend 1 com.google gmail-ls " + E + "\n"));
        check("pending retry: lands once the adapter is back, master untouched",
                r2.line.equals("OK master=- rows=1 applied=1 pending=0 mismatch=0") && Boolean.TRUE.equals(f1.rows.get("com.google|gmail-ls|" + NAME)), r2.line);

        World f2 = world();
        Sys deaf = new Sys(f2);
        deaf.deaf = true;
        f2.rows.clear();
        String rd = SyncRoam.apply(deaf, in(cap)).line;
        check("apply: a switch that did not move is a mismatch -> ERR", rd.startsWith("ERR ") && rd.contains("mismatch="), rd);

        // ---- the printed apply answer: counts, then the pend lines ----
        World f3 = world();
        f3.adapters.remove(0);
        Fake g = new Fake(f3);
        ServiceManager.SERVICES.put("content", new FakeBinder(g));
        ServiceManager.SERVICES.put("account", new FakeBinder(g));
        String ap3 = asRoamd("apply", WANT);
        check("apply prints the answer, then one pend line per pending switch",
                ap3.equals("0|OK master=1 rows=3 applied=2 pending=1 mismatch=0\npend 1 com.google gmail-ls " + E + "\n"), ap3);

        // ---- errors never carry a name ----
        g.throwOnGet = new SecurityException("no access to " + new Account(NAME, "com.google"));
        f3.adapters.add(new String[] {"com.google", "gmail-ls"});
        String e = asRoamd("capture", "");
        check("a throw prints ERR <class> only -- never the message with the name", e.equals("1|ERR SecurityException\n"), e);
        g.throwOnGet = null;
        check("bad usage refused by token", asRoamd("bogus", "").equals("1|ERR usage\n"), asRoamd("bogus", ""));
        ServiceManager.SERVICES.remove("content");
        check("a null service (the SELinux find denial) is named", asRoamd("capture", "").equals("1|ERR no-content-service\n"),
                asRoamd("capture", ""));

        // ---- np.VpnAlwaysOn ----
        final List<String> vcalls = new ArrayList<>();
        ServiceManager.SERVICES.put("vpn_management", new FakeBinder(new IVpnManager() {
            public void setVpnPackageAuthorization(String pkg, int u, int t) { vcalls.add("auth " + pkg + " " + u + " " + t); }

            public boolean setAlwaysOnVpnPackage(int u, String pkg, boolean l, List<String> al) {
                vcalls.add("aon " + u + " " + pkg + " " + l + " " + al);
                return true;
            }
        }));
        String d = VpnAlwaysOn.run(new String[] {"10", "com.x", "defer"});
        check("vpn defer: the consent with TYPE_VPN_SERVICE (1), nothing else", vcalls.equals(List.of("auth com.x 10 1")), vcalls);
        check("vpn defer: says what it did", d.equals("setVpnPackageAuthorization(user=10, pkg=com.x, type=1) -> done"), d);
        vcalls.clear();
        String o = VpnAlwaysOn.run(new String[] {"10", "com.x", "0"});
        check("vpn 0: always-on without the block", vcalls.equals(List.of("aon 10 com.x false null")) && o.endsWith("-> true"), vcalls + " " + o);
        vcalls.clear();
        VpnAlwaysOn.run(new String[] {"10", "com.x", "1"});
        check("vpn 1: always-on with the block (the old mode, unchanged)", vcalls.equals(List.of("aon 10 com.x true null")), vcalls);
        check("vpn defer without a package is refused", VpnAlwaysOn.run(new String[] {"10", "", "defer"}).startsWith("ERR"), "");
        ServiceManager.SERVICES.remove("vpn_management");
        check("vpn: a null service is named", VpnAlwaysOn.run(new String[] {"10", "com.x", "0"}).equals("ERR: no vpn_management service"), "");

        // ---- the chooser's picker statics (Lifted from ProfileActivity) ----
        String[] cur = Lifted.vpnCurrentFrom("app=com.p\nlockdown=0\n", true, "com.x", "1", null, "com.r", "1");
        check("picker: a pending pick is what is shown", cur[0].equals("com.p") && cur[1].equals("0"), String.join(",", cur));
        cur = Lifted.vpnCurrentFrom("app=com.p\nlockdown=9\n", true, "com.x", "0", "com.x", "com.r", "1");
        check("picker: a malformed pick falls to the live setting; a pending block counts as on", cur[0].equals("com.x") && cur[1].equals("1"), String.join(",", cur));
        cur = Lifted.vpnCurrentFrom(null, true, "com.x", "0", null, "com.r", "1");
        check("picker: live block off is shown off (not the old pref's 1)", cur[0].equals("com.x") && cur[1].equals("0"), String.join(",", cur));
        cur = Lifted.vpnCurrentFrom(null, true, null, null, null, "com.r", "1");
        check("picker: live none is none", cur[0].isEmpty() && cur[1].equals("0"), String.join(",", cur));
        cur = Lifted.vpnCurrentFrom(null, false, null, null, null, "com.r", "");
        check("picker: unreadable live -> the old pref, block on by default", cur[0].equals("com.r") && cur[1].equals("1"), String.join(",", cur));
        cur = Lifted.vpnCurrentFrom("app=com.x;rm\nlockdown=1\n", true, "com.l", "0", null, "com.r", "1");
        check("picker: a pick whose app has a bad character falls to the live setting", java.util.Arrays.equals(cur, new String[] {"com.l", "0"}), String.join(",", cur));
        cur = Lifted.vpnCurrentFrom("lockdown=1\n", true, "com.l", "1", null, "com.r", "0");
        check("picker: a pick with no app= line falls to the live setting", java.util.Arrays.equals(cur, new String[] {"com.l", "1"}), String.join(",", cur));
        cur = Lifted.vpnCurrentFrom("app=\nlockdown=1\n", true, "com.x", "1", null, "com.r", "1");
        check("picker: an Off pick that carries lockdown=1 is none, block 0", java.util.Arrays.equals(cur, new String[] {"", "0"}), String.join(",", cur));
        cur = Lifted.vpnCurrentFrom(null, true, "null", "1", null, "com.r", "1");
        check("picker: live app \"null\" is none", java.util.Arrays.equals(cur, new String[] {"", "0"}), String.join(",", cur));
        cur = Lifted.vpnCurrentFrom(null, true, "com.x", "1", null, "com.r", "0");
        check("picker: live lockdown 1 on its own is on", java.util.Arrays.equals(cur, new String[] {"com.x", "1"}), String.join(",", cur));
        cur = Lifted.vpnCurrentFrom(null, true, "com.x", "0", "com.other", "com.r", "1");
        check("picker: a pending block naming another app is off", java.util.Arrays.equals(cur, new String[] {"com.x", "0"}), String.join(",", cur));
        cur = Lifted.vpnCurrentFrom(null, false, null, null, null, "com.r", "0");
        check("picker: prefs vpnlockdown=0 is off", java.util.Arrays.equals(cur, new String[] {"com.r", "0"}), String.join(",", cur));
        cur = Lifted.vpnCurrentFrom(null, false, null, null, null, null, null);
        check("picker: nothing anywhere is none, block 0", java.util.Arrays.equals(cur, new String[] {"", "0"}), String.join(",", cur));
        check("lockdown: Off carries no block", Lifted.vpnPickLockdown(new String[] {"com.x", "1"}, "").equals("0"), "");
        check("lockdown: a new app keeps the current block OFF", Lifted.vpnPickLockdown(new String[] {"com.x", "0"}, "com.y").equals("0"), "");
        check("lockdown: a new app keeps the current block ON", Lifted.vpnPickLockdown(new String[] {"com.x", "1"}, "com.y").equals("1"), "");
        check("lockdown: no VPN yet -> on (armed at first connect)", Lifted.vpnPickLockdown(new String[] {"", "0"}, "com.y").equals("1"), "");
        check("pick text: the shape vpn_choice reads", Lifted.vpnPickText("com.y", "1").equals("app=com.y\nlockdown=1\n"), "");
        check("pick text: Off is app= lockdown=0", Lifted.vpnPickText("", "1").equals("app=\nlockdown=0\n"), "");
        check("toast: says when the block is on", Lifted.vpnPickToast("WG", "com.y", "1").contains("blocks connections without VPN"), "");
        check("toast: says when it is off", Lifted.vpnPickToast("WG", "com.y", "0").contains("allowed"), "");
        check("pkg ok: rejects shell metacharacters", !Lifted.vpnPkgOk("com.x;rm") && Lifted.vpnPkgOk("com.x_y.Z9") && Lifted.vpnPkgOk(""), "");
        check("L8: with the helper the picker works", Lifted.vpnUnsupportedText(true) == null, Lifted.vpnUnsupportedText(true));
        String un = Lifted.vpnUnsupportedText(false);
        check("L8: without it (Diaspore) it says so, never \"applies next sign-in\"", un != null && !un.contains("applies next sign-in"), un);

        // For run.sh's cross-language pin: the pick texts roamd's vpn_choice must parse.
        if (a.length > 0) {
            java.nio.file.Files.write(java.nio.file.Paths.get(a[0], "pick-on"), Lifted.vpnPickText("com.y", "1").getBytes(StandardCharsets.UTF_8));
            java.nio.file.Files.write(java.nio.file.Paths.get(a[0], "pick-off"), Lifted.vpnPickText("", "1").getBytes(StandardCharsets.UTF_8));
            java.nio.file.Files.write(java.nio.file.Paths.get(a[0], "pick-noblock"), Lifted.vpnPickText("com.z", "0").getBytes(StandardCharsets.UTF_8));
        }

        System.out.println(fails == 0 ? "all " + runs + " cases passed" : fails + " of " + runs + " cases FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }
}
