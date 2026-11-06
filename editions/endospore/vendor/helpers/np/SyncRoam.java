package np;

import android.system.Os;
import java.io.BufferedReader;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.lang.reflect.Array;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.concurrent.TimeUnit;

// NWP-20261010-15: carry a profile's ACCOUNT SYNC switches across a sign-out (docs/product-decisions.md, 2026-10-10,
// "account sync settings roam with the profile, captured as the user left them"). Every sign-in mints a new Android
// user, and SyncStorageEngine keeps sync state in the device-global /data/system/sync/accounts.xml, which no Nowhere
// scope carries -- so a restored account came back with every authority switched off and Gmail said "Account sync is
// off" at every sign-in. roamd runs this at each seal (`capture`) and after the account restore (`apply`).
//
// ⚠⚠ THE BINDER CALLS MUST BE MADE AS THE SYSTEM UID, NOT AS ROOT. ContentService.get/setSyncAutomaticallyAsUser
// begin with `if (!hasAccountAccess(true, account, callingUid)) return` (false / no-op), and
// AccountManagerService.hasAccountAccess(account, null, uid) answers false for any uid with no package, because
// getPackageNameForUid() is null -- which is uid 0, while change 201794303 is enabled for it by default (no packages,
// so PlatformCompat returns the default). As root every per-account switch reads 0 and every write is dropped, with no
// error anywhere; only the master switch works. The system uid has packages and passes both checks:
// permissionIsGranted() grants appId SYSTEM_UID outright, and the authority check only asks whether a sync-adapter
// package for the authority is visible to the caller, which package visibility never filters for a core uid.
// So `main`, started as root by roamd, drops to SYSTEM_UID and RELAUNCHES itself: the binder driver keeps the
// credentials of whoever OPENED /dev/binder, and app_process opened it, as root, before main() ran -- a setuid in
// this process would change nothing the framework sees. The relaunched process opens its own binder as system.
//
// Run through app_process (editions/endospore/vendor/helpers/README.md):
//   capture <userId>   stdin: the previous capture + this session's pend lines
//                      stdout: the new capture, then the pend lines still pending, then `stat landed=N unstuck=M`
//                      when a pend line was tried -- or one `ERR ...` line
//   apply   <userId>   stdin: capture and/or pend lines                         stdout: `OK|ERR <counts>`, then pend lines,
//                      then `fix` / `fixmaster` lines for what did not land
//   retry   <userId>   stdin: a failed apply's fix lines, or the whole capture   stdout: as apply (see retry())
//   A fix line is `fix <carried> <live just after the failure: 0|1|-> <type> <authority> <name>`; `fixmaster` the same.
//
// THE CAPTURE, one record per line, fields percent-escaped so none holds a space (enc/dec):
//   nowhere-sync 1
//   master <0|1>
//   sync <0|1> <accountType> <authority> <accountName>     (sorted, so an unchanged state seals to the same bytes)
//   end <number of sync lines>
// A `pend` line has the shape of a `sync` line: a switch this session could not apply yet (see apply()).
//
// ⚠ ACCOUNT NAMES ARE IN THE CAPTURE AND THE PEND LINES AND MUST NEVER LEAVE THEM. Everything else this prints is a
// count, a fixed token, or `ERR <exception class>` -- never an exception MESSAGE, because Account.toString() puts the
// name in every message that mentions an account (the #39 roster lesson).
public final class SyncRoam {
    static final String HEADER = "nowhere-sync 1";
    static final int SYSTEM_UID = 1000; // android.os.Process.SYSTEM_UID
    // Strictly shorter than roamd's `timeout` (SYNC_TIMEOUT, 20 s): this process must give up, kill its child and
    // answer first, or roamd kills THIS process and the child runs on, orphaned.
    static final long RELAUNCH_TIMEOUT_S = 12;

    // A refusal whose message is a fixed token of ours, so it is safe to print.
    static final class Refusal extends Exception {
        Refusal(String token) {
            super(token);
        }
    }

    // The calls this needs, so the decisions below run under a plain JVM against a fake (the helpers-java suite).
    interface Sync {
        List<String[]> accounts() throws Exception; // {name, type}: the accounts VISIBLE this session

        List<String[]> adapters() throws Exception; // {accountType, authority}: the registered sync adapters

        boolean hasAdapter(String authority) throws Exception; // a sync-adapter package for it is installed now

        boolean master() throws Exception;

        void setMaster(boolean on) throws Exception;

        boolean get(String name, String type, String authority) throws Exception;

        void set(String name, String type, String authority, boolean on) throws Exception;
    }

    // How a dropped process starts its replacement. A seam so the suite can run the relaunch in-process.
    interface Relaunch {
        int run(String[] a) throws Exception;
    }

    static Relaunch relaunch = SyncRoam::relaunchAsSystem;

    // How a ProcessBuilder becomes a process. A seam so the suite can run the child as a fresh "process" of its own.
    interface Starter {
        Process start(ProcessBuilder pb) throws Exception;
    }

    static Starter starter = ProcessBuilder::start;

    public static void main(String[] a) {
        int rc;
        PrintStream out = System.out;
        try {
            out = new PrintStream(new FileOutputStream(FileDescriptor.out), true, "UTF-8");
            rc = entry(a, System.in, out);
        } catch (Throwable t) {
            out.println(errLine(t));
            rc = 1;
        }
        out.flush();
        System.exit(rc);
    }

    // Root drops to the system uid and relaunches (see the header); anything else does the work.
    static int entry(String[] a, InputStream in, PrintStream out) throws Exception {
        if (Os.getuid() == 0) {
            Os.setgid(SYSTEM_UID);
            Os.setuid(SYSTEM_UID);
            if (Os.getuid() != SYSTEM_UID) {
                throw new Refusal("drop-failed");
            }
            return relaunch.run(a);
        }
        return run(a, in, out, null);
    }

    // The replacement inherits stdin, stdout and stderr, so it reads the input this process never touched and prints
    // straight to roamd. CLASSPATH rides the inherited environment.
    static int relaunchAsSystem(String[] a) throws Exception {
        List<String> cmd = new ArrayList<>(Arrays.asList("/system/bin/app_process", "/system/bin", SyncRoam.class.getName()));
        cmd.addAll(Arrays.asList(a));
        Process p = starter.start(new ProcessBuilder(cmd).inheritIO());
        if (!p.waitFor(RELAUNCH_TIMEOUT_S, TimeUnit.SECONDS)) {
            p.destroyForcibly();
            throw new Refusal("timeout");
        }
        return p.exitValue();
    }

    // sync == null -> the real binder services for the user named in the arguments.
    static int run(String[] a, InputStream in, PrintStream out, Sync sync) throws Exception {
        if (a.length != 2 || !("capture".equals(a[0]) || "apply".equals(a[0]) || "retry".equals(a[0]))) {
            throw new Refusal("usage");
        }
        final int userId;
        try {
            userId = Integer.parseInt(a[1]);
        } catch (NumberFormatException e) {
            throw new Refusal("usage");
        }
        if (userId < 0) {
            throw new Refusal("usage");
        }
        Parsed in0 = parse(readAll(in));
        Sync s = sync != null ? sync : new BinderSync(userId);
        if ("capture".equals(a[0])) {
            // Built whole before anything is printed: a failure part-way prints ONE `ERR` line, never half a capture.
            out.print(capture(s, in0));
            return 0;
        }
        Applied r = "apply".equals(a[0]) ? apply(s, in0) : retry(s, in0);
        StringBuilder b = new StringBuilder(r.line).append('\n');
        for (Row p : r.pending) {
            b.append("pend ").append(p.on ? '1' : '0').append(' ').append(p.key()).append('\n');
        }
        for (Row p : r.fixes) {
            b.append("fix ").append(p.on ? '1' : '0').append(' ').append(p.was).append(' ').append(p.key()).append('\n');
        }
        if (r.fixMaster != null) {
            b.append("fixmaster ").append(r.fixMaster ? '1' : '0').append(' ').append(r.fixMasterWas).append('\n');
        }
        out.print(b);
        return r.line.startsWith("OK ") ? 0 : 1;
    }

    // The safe-to-print form of any failure: a fixed token for our own refusals, else only the class name.
    static String errLine(Throwable t) {
        Throwable c = t;
        while (c instanceof InvocationTargetException && c.getCause() != null) {
            c = c.getCause();
        }
        if (c instanceof Refusal) {
            return "ERR " + c.getMessage();
        }
        return "ERR " + c.getClass().getSimpleName();
    }

    static final class Row {
        final boolean on;
        final String type, authority, name;
        // On a `fix` row only: the live value just after the apply failed to land `on` -- "0", "1", or "-" when it
        // could not be read. The retry writes `on` only while the switch still reads this (see retry()).
        String was = "-";

        Row(boolean on, String type, String authority, String name) {
            this.on = on;
            this.type = type;
            this.authority = authority;
            this.name = name;
        }

        String key() {
            return enc(type) + " " + enc(authority) + " " + enc(name);
        }

        String acct() {
            return type + "\n" + name;
        }
    }

    static final class Parsed {
        Boolean master; // null: no master line
        final List<Row> rows = new ArrayList<>(); // sync lines
        final List<Row> pending = new ArrayList<>(); // pend lines
        final List<Row> fixes = new ArrayList<>(); // fix lines: what a failed apply did not land
        Boolean fixMaster; // fixmaster line: the master value a failed apply did not land
        String fixMasterWas = "-"; // ... and the live master just after that failure
    }

    static final class Applied {
        final String line;
        final List<Row> pending;
        final List<Row> fixes = new ArrayList<>();
        Boolean fixMaster;
        String fixMasterWas = "-";

        Applied(String line, List<Row> pending) {
            this.line = line;
            this.pending = pending;
        }
    }

    static Set<String> visible(Sync s) throws Exception {
        Set<String> have = new HashSet<>();
        for (String[] ac : s.accounts()) {
            have.add(ac[1] + "\n" + ac[0]);
        }
        return have;
    }

    // ---- the capture --------------------------------------------------------------------------------------

    // Every switch the framework can answer for is READ LIVE: each visible account, for each registered adapter of
    // its type, and each previous row whose account is visible and whose authority has an adapter package now.
    //
    // ⚠ EVERY OTHER ROW IS CARRIED UNCHANGED, NEVER RE-READ. The framework answers false for a switch it will not
    // let the caller see, so reading one would turn the profile's choice into an explicit 0:
    //   - an authority with no adapter package this session (an on-demand Gmail not yet tapped; an app between its
    //     install and RegisteredServicesCache registering it) -- ContentService.hasAuthorityAccess is false;
    //   - an account not visible this session (its authenticator app is absent, so AccountManagerService lists no
    //     account of that type) -- including when NO account is visible, which is not evidence of anything.
    // The price: a row for an account removed for good is carried forever. It is inert -- apply never sets a switch for
    // an account it cannot see -- and the alternative loses a real choice whenever an authenticator is missing.
    //
    // A `pend` line -- a switch this session's apply could not set -- is ONLY EVER A 1, and it is landed here the first
    // time the framework can take it (its account visible, an adapter package present), ON ONE CONDITION: the live
    // switch is still 0. A new authority row starts disabled, so a 1 found there is the user's own newer choice (they
    // opened the app and tapped "Turn on" before this seal) and is kept, never overwritten; a 0 there is taken to be the
    // untouched default, and the carried 1 is written. Once landed, the capture records what the framework reads back.
    // A carried 1 whose write does not stick stays pending -- recorded as the carried 1, offered again at the next
    // capture -- and is counted on the `stat` line, so roamd can log it.
    //
    // ⚠ THE TRADE-OFF, stated: a carried 0 is never pending (apply drops it). If the app is absent at sign-in and, once
    // installed, switches its own sync on at first run, that 1 is what the capture records and the profile's explicit 0
    // is lost. Carrying the 0 instead would overwrite the user's newer "Turn on" -- the Gmail symptom this whole carry
    // exists to cure -- and nothing on the device tells an app's own write from the user's. Likewise a carried 1 lands
    // over a user who turned the switch on and back off between the app's install and this seal.
    //
    // One the framework still cannot take is carried unchanged and printed again, as a pend line after the capture.
    static String capture(Sync s, Parsed in) throws Exception {
        Set<String> have = visible(s);
        TreeMap<String, Row> rows = new TreeMap<>();
        List<Row> still = new ArrayList<>();
        int landed = 0, unstuck = 0;
        for (Row p : in.pending) {
            if (!p.on) {
                continue; // never landed, never carried: the record's own row (if any) governs
            }
            if (s.hasAdapter(p.authority) && have.contains(p.acct())) {
                if (s.get(p.name, p.type, p.authority)) {
                    rows.put(p.key(), p); // the user turned it on already; nothing to land
                    continue;
                }
                s.set(p.name, p.type, p.authority, true);
                if (s.get(p.name, p.type, p.authority)) {
                    landed++;
                    rows.put(p.key(), p);
                    continue;
                }
                unstuck++;
            }
            rows.put(p.key(), p);
            still.add(p);
        }
        List<String[]> adapters = s.adapters();
        for (String[] ac : s.accounts()) {
            for (String[] ad : adapters) {
                Row r = new Row(false, ac[1], ad[1], ac[0]);
                if (!ad[0].equals(ac[1]) || rows.containsKey(r.key())) {
                    continue;
                }
                rows.put(r.key(), new Row(s.get(ac[0], ac[1], ad[1]), ac[1], ad[1], ac[0]));
            }
        }
        for (Row p : in.rows) {
            if (rows.containsKey(p.key())) {
                continue;
            }
            if (have.contains(p.acct()) && s.hasAdapter(p.authority)) {
                rows.put(p.key(), new Row(s.get(p.name, p.type, p.authority), p.type, p.authority, p.name));
            } else {
                rows.put(p.key(), p);
            }
        }
        StringBuilder b = new StringBuilder();
        b.append(HEADER).append('\n');
        b.append("master ").append(s.master() ? '1' : '0').append('\n');
        for (Map.Entry<String, Row> e : rows.entrySet()) {
            b.append("sync ").append(e.getValue().on ? '1' : '0').append(' ').append(e.getKey()).append('\n');
        }
        b.append("end ").append(rows.size()).append('\n');
        for (Row p : still) {
            b.append("pend ").append(p.on ? '1' : '0').append(' ').append(p.key()).append('\n');
        }
        if (landed + unstuck > 0) {
            b.append("stat landed=").append(landed).append(" unstuck=").append(unstuck).append('\n');
        }
        return b.toString();
    }

    // ---- the apply ----------------------------------------------------------------------------------------

    // Rows first, master last (when there is a master line), so turning master on schedules syncs against the
    // restored switches. A 1 the framework cannot take NOW -- its account not visible, or no adapter package for its
    // authority -- is not a failure: it is returned PENDING (printed as a `pend` line), roamd keeps it, and the capture
    // lands it when it can (capture() says when, and why a 0 is never pending). Setting it now would be a
    // silent no-op, read back as a mismatch, and fail the whole session's sign-in apply over an app nobody opened.
    // Every switch that IS set is READ BACK; any mismatch makes the answer ERR, so roamd does not let this session's
    // capture overwrite the profile's record with a half-restored state. A switch that did not land -- read back wrong,
    // or its call threw -- is handed back as a `fix` line, with the live value read just after the failure (and master
    // as `fixmaster` likewise), so the retry touches ONLY those, and only while nobody has changed them since.
    static Applied apply(Sync s, Parsed p) throws Exception {
        Set<String> have = visible(s);
        List<Row> all = new ArrayList<>(p.rows);
        all.addAll(p.pending);
        List<Row> pending = new ArrayList<>(), fixes = new ArrayList<>();
        int applied = 0, mismatch = 0;
        for (Row r : all) {
            if (!have.contains(r.acct()) || !s.hasAdapter(r.authority)) {
                if (r.on) {
                    pending.add(r); // a carried 0 is not: see capture()
                }
                continue;
            }
            applied++;
            try {
                s.set(r.name, r.type, r.authority, r.on);
                if (s.get(r.name, r.type, r.authority) == r.on) {
                    continue;
                }
            } catch (Exception e) {
                // counted and handed back below; never printed (its message may name the account)
            }
            mismatch++;
            r.was = liveOf(s, r);
            fixes.add(r);
        }
        Boolean fixMaster = null;
        String fixMasterWas = "-";
        if (p.master != null) {
            boolean ok = false;
            try {
                s.setMaster(p.master);
                ok = s.master() == p.master;
            } catch (Exception e) {
                ok = false;
            }
            if (!ok) {
                mismatch++;
                fixMaster = p.master;
                fixMasterWas = masterOf(s);
            }
        }
        String counts = "master=" + (p.master == null ? "-" : p.master ? "1" : "0") + " rows=" + all.size()
                + " applied=" + applied + " pending=" + pending.size() + " mismatch=" + mismatch;
        Applied r = new Applied((mismatch == 0 ? "OK " : "ERR ") + counts, pending);
        r.fixes.addAll(fixes);
        r.fixMaster = fixMaster;
        r.fixMasterWas = fixMasterWas;
        return r;
    }

    // The live value of a switch as "0"/"1", or "-" when it cannot be read.
    static String liveOf(Sync s, Row r) {
        try {
            return s.get(r.name, r.type, r.authority) ? "1" : "0";
        } catch (Exception e) {
            return "-";
        }
    }

    static String masterOf(Sync s) {
        try {
            return s.master() ? "1" : "0";
        } catch (Exception e) {
            return "-";
        }
    }

    // The retry of a sign-in apply that FAILED, at a later seal.
    //
    // WITH A HAND-BACK (the failed apply answered): it touches only the `fix` rows -- and master only if `fixmaster` is
    // among them -- and writes a row's carried value, 0 or 1, ONLY WHILE ITS LIVE VALUE STILL EQUALS THE ONE READ JUST
    // AFTER THE FAILURE. Equal is taken to mean nobody has touched it since, so it is the switch that did not land.
    // Different means the user (or the app) changed it: the row is dropped, and the capture records their value. Master
    // likewise. ⚠ Residual (ABA): a switch changed and changed back within one seal interval reads as untouched, so the
    // retry overwrites the user's final value with the carry -- the same limit the VPN carry states for set-then-clear.
    // A row (or master) that cannot be read NOW is handed back unchanged and counted as a mismatch, never dropped.
    //
    // THE CONSERVATIVE RULE -- write a 1 only over a live 0, never write a 0, never touch master -- applies wherever
    // there is no value-at-failure to compare against: a row whose value after the failure could not be read ("-"),
    // and the whole record when the failed apply handed nothing usable back (it timed out, crashed, answered
    // `ERR <Exception>`, or its hand-back was malformed -- roamd drops a malformed one). ⚠ Residual: there, a user who
    // turned a carried-1 switch OFF before the retry sees it turned back on, and since the next capture records that 1,
    // their off is lost from the record too, until they turn it off again.
    static Applied retry(Sync s, Parsed p) throws Exception {
        boolean handedBack = !p.fixes.isEmpty() || p.fixMaster != null;
        List<Row> rows = handedBack ? p.fixes : p.rows;
        Set<String> have = visible(s);
        List<Row> pending = new ArrayList<>(), fixes = new ArrayList<>();
        int applied = 0, mismatch = 0;
        for (Row r : rows) {
            boolean known = handedBack && !"-".equals(r.was);
            if (!known && !r.on) {
                continue; // conservative rule: never write a 0 we cannot prove still needs writing
            }
            if (!have.contains(r.acct()) || !s.hasAdapter(r.authority)) {
                if (r.on) {
                    pending.add(r);
                }
                continue;
            }
            String live = liveOf(s, r);
            if ("-".equals(live)) {
                // Unreadable NOW: nothing is known, nothing is written -- handed back exactly as it came, and the answer
                // is not OK, so roamd does not mark the session applied and let a capture overwrite the record.
                mismatch++;
                fixes.add(r);
                continue;
            }
            try {
                if (known ? !live.equals(r.was) : !"0".equals(live)) {
                    continue; // changed since the failure (or, conservatively, not a live 0): theirs, not ours
                }
                applied++;
                s.set(r.name, r.type, r.authority, r.on);
                if (s.get(r.name, r.type, r.authority) == r.on) {
                    continue;
                }
            } catch (Exception e) {
                // counted and handed back below
            }
            mismatch++;
            r.was = liveOf(s, r);
            fixes.add(r);
        }
        Boolean fixMaster = null;
        String fixMasterWas = "-";
        Boolean master = handedBack && p.fixMaster != null && !"-".equals(p.fixMasterWas) ? p.fixMaster : null;
        String liveMaster = master == null ? "-" : masterOf(s);
        if (master != null && "-".equals(liveMaster)) {
            mismatch++; // unreadable now: handed back unchanged, as for a row
            fixMaster = master;
            fixMasterWas = p.fixMasterWas;
        } else if (master != null && liveMaster.equals(p.fixMasterWas)) {
            boolean ok = false;
            try {
                s.setMaster(master);
                ok = s.master() == master;
            } catch (Exception e) {
                ok = false;
            }
            if (!ok) {
                mismatch++;
                fixMaster = master;
                fixMasterWas = masterOf(s);
            }
        }
        String counts = "master=" + (master == null ? "-" : master ? "1" : "0") + " rows=" + rows.size()
                + " applied=" + applied + " pending=" + pending.size() + " mismatch=" + mismatch;
        Applied r = new Applied((mismatch == 0 ? "OK " : "ERR ") + counts, pending);
        r.fixes.addAll(fixes);
        r.fixMaster = fixMaster;
        r.fixMasterWas = fixMasterWas;
        return r;
    }

    // ---- the format ---------------------------------------------------------------------------------------

    // Lenient on purpose: roamd validates a capture whole before an apply, and a line this does not understand is
    // simply not carried.
    static Parsed parse(String text) {
        Parsed p = new Parsed();
        for (String line : text.split("\n", -1)) {
            String[] f = line.split(" ", -1);
            if (f.length == 2 && "master".equals(f[0]) && ("0".equals(f[1]) || "1".equals(f[1]))) {
                p.master = "1".equals(f[1]);
            } else if (f.length == 3 && "fixmaster".equals(f[0]) && ("0".equals(f[1]) || "1".equals(f[1]))
                    && ("0".equals(f[2]) || "1".equals(f[2]) || "-".equals(f[2]))) {
                p.fixMaster = "1".equals(f[1]);
                p.fixMasterWas = f[2];
            } else if (f.length == 5 && ("sync".equals(f[0]) || "pend".equals(f[0]))
                    && ("0".equals(f[1]) || "1".equals(f[1])) && !f[2].isEmpty() && !f[3].isEmpty() && !f[4].isEmpty()) {
                Row r = new Row("1".equals(f[1]), dec(f[2]), dec(f[3]), dec(f[4]));
                ("sync".equals(f[0]) ? p.rows : p.pending).add(r);
            } else if (f.length == 6 && "fix".equals(f[0]) && ("0".equals(f[1]) || "1".equals(f[1]))
                    && ("0".equals(f[2]) || "1".equals(f[2]) || "-".equals(f[2]))
                    && !f[3].isEmpty() && !f[4].isEmpty() && !f[5].isEmpty()) {
                Row r = new Row("1".equals(f[1]), dec(f[3]), dec(f[4]), dec(f[5]));
                r.was = f[2];
                p.fixes.add(r);
            }
        }
        return p;
    }

    // Percent-escape `%`, space and every control character, so a field never holds a space or a line break and
    // roamd can validate the file with grep. Anything else (an `@`, a non-ASCII letter) is kept as it is.
    static String enc(String s) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '%' || c <= ' ' || c == 0x7f) {
                b.append('%').append(Character.forDigit(c >> 4 & 0xf, 16)).append(Character.forDigit(c & 0xf, 16));
            } else {
                b.append(c);
            }
        }
        return b.toString();
    }

    static String dec(String s) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '%' && i + 2 < s.length()) {
                int hi = Character.digit(s.charAt(i + 1), 16), lo = Character.digit(s.charAt(i + 2), 16);
                if (hi >= 0 && lo >= 0) {
                    b.append((char) (hi << 4 | lo));
                    i += 2;
                    continue;
                }
            }
            b.append(c);
        }
        return b.toString();
    }

    static String readAll(InputStream in) throws Exception {
        StringBuilder b = new StringBuilder();
        BufferedReader r = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8));
        char[] buf = new char[4096];
        for (int n; (n = r.read(buf)) > 0; ) {
            b.append(buf, 0, n);
        }
        return b.toString();
    }

    // ---- the binder side, all by reflection: the jar is built against the private platform API, and the
    // helpers-java suite compiles this file against small fakes of exactly these names ---------------------

    static final class BinderSync implements Sync {
        final int userId;
        final Object content, accounts;
        final Class<?> accountClass;

        BinderSync(int userId) throws Exception {
            this.userId = userId;
            this.content = service("content", "android.content.IContentService", "no-content-service");
            this.accounts = service("account", "android.accounts.IAccountManager", "no-account-service");
            this.accountClass = Class.forName("android.accounts.Account");
        }

        static Object service(String name, String iface, String missing) throws Exception {
            Object b = Class.forName("android.os.ServiceManager").getMethod("getService", String.class)
                    .invoke(null, name);
            if (b == null) {
                throw new Refusal(missing); // a null service is what an SELinux find denial looks like from here
            }
            return Class.forName(iface + "$Stub").getMethod("asInterface", Class.forName("android.os.IBinder"))
                    .invoke(null, b);
        }

        Method cs(String name, Class<?>... params) throws Exception {
            return Class.forName("android.content.IContentService").getMethod(name, params);
        }

        Object account(String name, String type) throws Exception {
            return accountClass.getConstructor(String.class, String.class).newInstance(name, type);
        }

        @Override
        public List<String[]> accounts() throws Exception {
            // "android" as the calling package: the system uid's own, so AccountManagerService's app-op package check
            // passes and visibility resolves for the system, which sees every account whose authenticator is present.
            Object arr = Class.forName("android.accounts.IAccountManager")
                    .getMethod("getAccountsAsUser", String.class, int.class, String.class)
                    .invoke(accounts, null, userId, "android");
            List<String[]> l = new ArrayList<>();
            for (int i = 0; arr != null && i < Array.getLength(arr); i++) {
                Object ac = Array.get(arr, i);
                l.add(new String[] {(String) accountClass.getField("name").get(ac),
                        (String) accountClass.getField("type").get(ac)});
            }
            return l;
        }

        @Override
        public List<String[]> adapters() throws Exception {
            Object arr = cs("getSyncAdapterTypesAsUser", int.class).invoke(content, userId);
            List<String[]> l = new ArrayList<>();
            for (int i = 0; arr != null && i < Array.getLength(arr); i++) {
                Object t = Array.get(arr, i);
                Class<?> c = t.getClass();
                String type = (String) c.getField("accountType").get(t), auth = (String) c.getField("authority").get(t);
                if (type != null && auth != null && !auth.isEmpty()) {
                    l.add(new String[] {type, auth});
                }
            }
            return l;
        }

        // Exactly the predicate ContentService.hasAuthorityAccess applies: a sync-adapter package for the authority,
        // visible to the caller, in this user.
        @Override
        public boolean hasAdapter(String authority) throws Exception {
            Object arr = cs("getSyncAdapterPackagesForAuthorityAsUser", String.class, int.class)
                    .invoke(content, authority, userId);
            return arr != null && Array.getLength(arr) > 0;
        }

        @Override
        public boolean master() throws Exception {
            return (Boolean) cs("getMasterSyncAutomaticallyAsUser", int.class).invoke(content, userId);
        }

        @Override
        public void setMaster(boolean on) throws Exception {
            cs("setMasterSyncAutomaticallyAsUser", boolean.class, int.class).invoke(content, on, userId);
        }

        @Override
        public boolean get(String name, String type, String authority) throws Exception {
            return (Boolean) cs("getSyncAutomaticallyAsUser", accountClass, String.class, int.class)
                    .invoke(content, account(name, type), authority, userId);
        }

        @Override
        public void set(String name, String type, String authority, boolean on) throws Exception {
            cs("setSyncAutomaticallyAsUser", accountClass, String.class, boolean.class, int.class)
                    .invoke(content, account(name, type), authority, on, userId);
        }
    }
}
