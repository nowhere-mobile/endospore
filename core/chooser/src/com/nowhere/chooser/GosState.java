package com.nowhere.chooser;

import android.content.Context;
import android.util.Log;

import java.io.File;

/**
 * NWP-20260821-17 — roam GrapheneOS per-app hardening state (`GosPackageState`) across the amnesiac login.
 *
 * WHAT THIS CARRIES. "Exploit protection compatibility mode" and the other per-app hardening switches from
 * Settings > Apps > &lt;app&gt;. They are per-(package,user) state, and every Nowhere login mints a BRAND-NEW
 * Android user, so without this every one of them is silently back to default on every login. Banking apps
 * are the canonical need and compat mode is GrapheneOS's own recommendation for running them; the direction
 * is settled in docs/product-decisions.md. Full design of record: docs/gos-package-state-roam.md.
 *
 * WHY IT IS ALL REFLECTION. `android.content.pm.GosPackageState` exists only on GrapheneOS, and the chooser
 * is ONE Soong module (`NowhereChooser`, srcs `chooser/src/**`) built from the SAME sources for both editions.
 * A direct reference would break the Diaspore/LineageOS build outright. Reflection makes this file compile
 * everywhere and no-op cleanly where the class is absent — the same reason ChooserActivity reflects
 * `com.android.internal.telephony.SmsApplication`.
 *
 * WHY IT NEEDS A FRAMEWORK PATCH. There is NO shell read of this state: `edit-gos-package-state` is the only
 * `pm` entry point and every verb it has is a WRITE (device-proven on lynx: `cmd package
 * get-gos-package-state` -> "Unknown command", rc=255). The only read is the binder API, gated by a hardcoded
 * appId table with no signature / device-owner / platform-cert door. `editions/endospore/build/patches/
 * gos-chooser-grant.sh` adds this package to that table, SAME-USER ONLY — capture and apply both run inside
 * the roamed user, so no cross-user permission is asked for or needed.
 *
 * ⚠⚠ THE DESTRUCTIVE FAILURE THIS CLASS IS BUILT AROUND. A denied read is INDISTINGUISHABLE from "no state":
 * `GosPackageStatePmHooks.getFiltered` returns `NONE` in both cases. So on a build where the patch is MISSING,
 * a naive capture would read nothing for every package, write an empty file, and DESTROY the user's sealed
 * settings on the first logoff — silently, and permanently. The guard is the APPLY RECEIPT: a sealed row may
 * only be dropped when this session positively demonstrated it can talk to the API. See {@link #capture}.
 */
final class GosState {

    private GosState() {}

    /** The sealed carry file (chooser CE dir -> seals with the vault and restores on the next login). */
    private static final String FILE = "nowhere-gosstate";
    /** The per-session apply receipt. Roamd deletes it at roam-in, beside its four siblings. */
    private static final String RECEIPT = "nowhere-gos-applied";

    private static final String CLS = "android.content.pm.GosPackageState";

    /** Lowest and highest bit indices in MASK — the write loop's bounds. */
    private static final int BIT_LO = 1, BIT_HI = 24;

    // ---- reflection plumbing -------------------------------------------------------------------------

    private static Class<?> cls() {
        try {
            return Class.forName(CLS);
        } catch (Throwable t) {
            return null; // Diaspore / LineageOS: the class does not exist. Not an error.
        }
    }

    /** True on an edition that has GosPackageState at all. Says NOTHING about whether we hold the grant. */
    static boolean present() { return cls() != null; }

    /** The masked flag word for pkg in this user, or -1 if it could not be read at all. */
    private static long readMasked(String pkg, int userId) {
        try {
            Class<?> c = cls();
            if (c == null) return -1L;
            Object ps = c.getMethod("get", String.class, int.class).invoke(null, pkg, userId);
            if (ps == null) return -1L;
            long flags = c.getField("flagStorage1").getLong(ps);
            return flags & MASK;
        } catch (Throwable t) {
            return -1L;
        }
    }

    /**
     * Write the masked word absolutely — every bit in MASK is set to its value in `flags`, so a bit the user
     * CLEARED is genuinely cleared rather than left behind. Returns true only when the framework confirmed it.
     *
     * ⚠ `kill` must be true whenever anything non-default lands: these flags are read at PROCESS SPAWN, so an
     * app already running keeps the old ones until it restarts. GrapheneOS's own Settings UI always kills for
     * the same reason.
     */
    private static boolean writeMasked(String pkg, int userId, long flags, boolean kill) {
        try {
            Class<?> c = cls();
            if (c == null) return false;
            Object ed = c.getMethod("edit", String.class, int.class).invoke(null, pkg, userId);
            java.lang.reflect.Method setFlag = ed.getClass().getMethod("setFlagState", int.class, boolean.class);
            for (int b = BIT_LO; b <= BIT_HI; b++) {
                if ((MASK & (1L << b)) == 0) continue; // never emit a retired/ungranted index -- atomic abort
                setFlag.invoke(ed, b, (flags & (1L << b)) != 0);
            }
            if (kill) ed.getClass().getMethod("setKillUidAfterApply", boolean.class).invoke(ed, true);
            Object ok = ed.getClass().getMethod("apply").invoke(ed);
            return Boolean.TRUE.equals(ok);
        } catch (Throwable t) {
            Log.w("NowhereChooser", "gos write " + pkg, t);
            return false;
        }
    }

    private static int myUserId() {
        try {
            return (Integer) android.os.UserHandle.class.getMethod("myUserId").invoke(null);
        } catch (Throwable t) {
            return 0;
        }
    }

    // ---- apply (login) -------------------------------------------------------------------------------

    /**
     * Replay the sealed state into this (roamed) user. Called from CredentialService, which the gate starts
     * AS the roamed user right after the login switch lands — so this runs same-user, which is the whole
     * reason no cross-user permission is needed.
     *
     * ⚠ MUST run after the roam-in reap. `pm uninstall --user N` DESTROYS this state (device-proven), and
     * roam-in reaps with `pm uninstall` USER_ALL before raising placeholders — applying earlier would simply
     * be wiped.
     *
     * ⚠ It does NOT need to wait for each package to be installed. Device-proven: state written for a package
     * NOT installed for that user persists (`inst="false"`) and SURVIVES the later install. That is why this
     * is one bulk pass rather than a per-package hook chained off every install shape. The prior research
     * asserted the opposite and built its whole design on it; it was wrong.
     *
     * Writes the receipt that {@link #capture} keys on. An unreadable sealed file replays nothing and writes a
     * receipt that is not live (NWP-20261111-05).
     */
    static void apply(Context ctx) {
        if (!present()) return; // Diaspore: nothing to do, and not an error
        int userId = myUserId();
        java.util.LinkedHashMap<String, Long> want;
        try {
            want = readRows(new File(ctx.getFilesDir(), FILE));
        } catch (java.io.IOException e) {
            // NWP-20261111-05: the sealed file exists but cannot be read. That is NOT an empty set: writing
            // `#live empty` here would let capture() drop every sealed row at logoff. Replay nothing and write
            // a receipt that is NOT live ("" -- no #live line), so this session can never be treated as live.
            Log.w("NowhereChooser", "gos apply: carry file unreadable -- nothing replayed, receipt written NOT live"
                    + " (NWP-20261111-05)");
            write(new File(ctx.getFilesDir(), RECEIPT), receiptText(false, 0, java.util.Collections.<String>emptyList()));
            return;
        }
        java.util.ArrayList<String> landedPkgs = new java.util.ArrayList<>();
        int ok = 0, failed = 0;
        for (java.util.Map.Entry<String, Long> e : want.entrySet()) {
            long f = e.getValue() & MASK;
            boolean landed = writeMasked(e.getKey(), userId, f, f != 0L);
            if (landed) { ok++; landedPkgs.add(e.getKey()); }
            else failed++;
        }
        // The receipt records what we PROVED we can write. An empty sealed set still counts as a live
        // mechanism (there was simply nothing to replay), which is what lets a brand-new profile capture the
        // first setting the user ever makes. See capture().
        write(new File(ctx.getFilesDir(), RECEIPT), receiptText(want.isEmpty(), ok, landedPkgs));
        Log.i("NowhereChooser", "gos apply user=" + userId + ": " + ok + " applied, " + failed
                + " failed, " + want.size() + " sealed");
        if (failed > 0 && ok == 0 && !want.isEmpty()) {
            // Every single write failed. Either the framework patch is missing from this image or the grant
            // was tightened upstream. Loud, because the consequence is that NOTHING roams -- and because
            // capture() will now deliberately refuse to touch the sealed file, which is the safe direction
            // but also means this state persists silently until someone reads this line.
            Log.e("NowhereChooser", "gos apply: ALL " + failed + " writes failed -- is "
                    + "gos-chooser-grant.sh applied to this image? Sealed state will be carried forward untouched.");
        }
    }

    // ---- capture (logoff) ----------------------------------------------------------------------------

    /**
     * Snapshot this user's state back into the sealed file. Called from ProfileActivity.doLogoff beside
     * capturePerms, which this deliberately mirrors.
     *
     * ⚠⚠ THE INVARIANT: A SEALED ROW MAY ONLY BE DROPPED AGAINST A POSITIVE APPLY RECEIPT.
     *
     * A denied read returns `NONE`, exactly like "this package has no state". So without this rule, an image
     * missing the framework patch would read nothing for everything, write an empty file, and destroy every
     * setting the user had — silently and permanently, on the first logoff. With it, the worst case of a
     * missing patch is that nothing roams and the sealed state survives untouched.
     *
     * The receipt makes the distinction the read cannot: it lists packages whose write this session was
     * CONFIRMED by the framework. For those, a live read of 0 genuinely means "the user cleared it". For
     * everything else, the previous row is carried forward unchanged — the same shape as capturePerms' #204
     * carry-forward for never-materialised on-demand apps.
     *
     * An UNREADABLE sealed file is neither an empty one nor a receipt: capture returns before reading anything
     * live, and the file is left exactly as restored (NWP-20261111-05).
     */
    static void capture(Context ctx) {
        if (!present()) return;
        try {
            int userId = myUserId();
            File f = new File(ctx.getFilesDir(), FILE);
            java.util.LinkedHashMap<String, Long> old;
            try {
                old = readRows(f);
            } catch (java.io.IOException e) {
                // NWP-20261111-05: an unreadable sealed file is neither empty nor a receipt. liveFor() would call an
                // empty map "a fresh profile" and the write below would replace the file with the live reads only.
                Log.w("NowhereChooser", "gos capture: carry file unreadable -- nothing captured, the sealed rows are"
                        + " left as they are (NWP-20261111-05)");
                return;
            }
            Receipt receipt = readReceipt(ctx);
            boolean live = liveFor(receipt.live, old);

            if (!live) {
                Log.w("NowhereChooser", "gos capture: mechanism NOT confirmed this session -- carrying "
                        + old.size() + " sealed row(s) forward untouched (nothing read, nothing dropped)");
                return; // leave the file exactly as restored
            }

            // Candidates: everything the user can see and toggle (the same launcher enumeration capturePerms
            // uses), UNION everything already sealed -- so a package that is only a dormant placeholder this
            // session is still considered rather than silently dropped.
            java.util.LinkedHashSet<String> cand = new java.util.LinkedHashSet<>();
            try {
                android.content.Intent launch = new android.content.Intent(android.content.Intent.ACTION_MAIN)
                        .addCategory(android.content.Intent.CATEGORY_LAUNCHER);
                for (android.content.pm.ResolveInfo ri : ctx.getPackageManager().queryIntentActivities(launch, 0)) {
                    String p = ri.activityInfo.packageName;
                    if (p != null && !p.isEmpty() && !ctx.getPackageName().equals(p)) cand.add(p);
                }
            } catch (Throwable t) { Log.w("NowhereChooser", "gos capture enumerate", t); }
            cand.addAll(old.keySet());

            final int uid = userId;
            Carried res = carry(old, receipt.applied, cand, new java.util.function.ToLongFunction<String>() {
                @Override public long applyAsLong(String pkg) { return readMasked(pkg, uid); }
            });
            java.util.LinkedHashMap<String, Long> out = res.out;
            int carried = res.carried;
            write(f, rowsText(out));
            Log.i("NowhereChooser", "gos capture user=" + userId + ": " + out.size()
                    + " row(s) sealed (" + carried + " carried forward, " + old.size() + " restored)");
        } catch (Throwable t) {
            Log.w("NowhereChooser", "gos capture", t); // never block logoff
        }
    }

    // ---- (BEGIN pure rules) test-gos-carry.sh ----
    // Context-free: no android.* types, so core/chooser/test-gos-carry.sh compiles this region as it stands
    // under plain javac (NWP-20261017-15). The Android plumbing around it stays outside the markers.

    /**
     * The carry set: bits {1, 6..24} = exactly GrapheneOS's own `settingsReadWriteFlags`, which is where
     * ENABLE_EXPLOIT_PROTECTION_COMPAT_MODE (bit 24) lives, plus ALLOW_ACCESS_TO_OBB_DIRECTORY (1) and the
     * seven hardening tri-states (6..23).
     *
     * ⚠ CARRY THE MASKED WORD VERBATIM, NEVER BIT BY BIT. Each hardening switch is a PAIR — `X` and
     * `X_NON_DEFAULT` ("the user explicitly set this") — and the Settings UI is tri-state, so a `_NON_DEFAULT`
     * bit WITHOUT its value bit reads as *explicitly disabled by the user*. Splitting a pair would therefore
     * turn OFF a protection the user never turned off. Masking a contiguous word cannot split a pair.
     *
     * ⚠ DELIBERATELY EXCLUDED, and the exclusions are enforced by the GRANT, not just by this mask:
     *   bit 26 PLAY_INTEGRITY_API_USED_AT_LEAST_ONCE — derived usage bookkeeping, not a user setting. It is
     *     also the ONLY GosPackageState found in the wild on our own test device, so a blanket flag-word copy
     *     would have shipped this bug immediately.
     *   bits 0 / 5 STORAGE_SCOPES_ENABLED / CONTACT_SCOPES_ENABLED — meaningless without their blobs, and the
     *     blobs CANNOT roam (the storage blob embeds the source user id as a literal path; the contact blob is
     *     raw contacts-DB row ids, so replaying it points an app at DIFFERENT PEOPLE).
     * Because `filterRead` masks every read to the caller's granted flags and the patch grants only
     * `settingsReadWriteFlags`, the excluded bits are UNREADABLE here rather than merely filtered.
     *
     * ⚠ Bits 2, 3, 4 and 25 are RETIRED upstream ("do not reuse"). Never put a retired or unknown index in a
     * write: `parseFlag` throws, and the editor is ATOMIC — device-proven, `add-flag 24 add-flag 25` landed
     * NEITHER — so one bad bit silently loses the WHOLE package's state, compat mode included. This mask is
     * contiguous over 6..24 precisely so no retired index can creep into it.
     */
    static final long MASK = 0x1FFFFC2L;

    /** A parsed apply receipt: whether it carries a `#live` line, and the packages whose write was confirmed. */
    static final class Receipt {
        final boolean live;
        final java.util.Set<String> applied;
        Receipt(boolean live, java.util.Set<String> applied) { this.live = live; this.applied = applied; }
    }

    /** What capture() seals: the rows to write and how many were carried forward from the restored set. */
    static final class Carried {
        final java.util.LinkedHashMap<String, Long> out;
        final int carried;
        Carried(java.util.LinkedHashMap<String, Long> out, int carried) { this.out = out; this.carried = carried; }
    }

    /**
     * NWP-20261111-05: the carry file, read strictly. An ABSENT file is an empty map -- a fresh profile, where
     * there is nothing to lose. A file that EXISTS but cannot be opened or read THROWS: it is neither an empty
     * file nor an apply receipt, and the callers must not act on it (AppClaim.readClaimsFile and
     * StoreInstaller.turnedOffLinesRaw ask the file the same way, because Java raises the SAME exception for
     * absent and for unopenable). A directory at the path is unopenable as root too.
     */
    static java.util.LinkedHashMap<String, Long> readRows(java.io.File f) throws java.io.IOException {
        if (!f.exists()) return new java.util.LinkedHashMap<>();
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f))) {
            return parseRows(r);
        }
    }

    /** `<pkg>\t<flags-hex>` per line, MASK applied. Unparseable LINES are skipped, never dropped silently in bulk;
     *  a read error PROPAGATES (NWP-20261111-05): a partial map would be indistinguishable from a complete one. */
    static java.util.LinkedHashMap<String, Long> parseRows(java.io.BufferedReader r) throws java.io.IOException {
        java.util.LinkedHashMap<String, Long> m = new java.util.LinkedHashMap<>();
        String ln;
        while ((ln = r.readLine()) != null) {
            ln = ln.trim();
            if (ln.isEmpty() || ln.startsWith("#")) continue;
            String[] t = ln.split("\t", -1);
            if (t.length < 2 || t[0].isEmpty()) continue;
            try { m.put(t[0], Long.parseLong(t[1].trim(), 16) & MASK); } catch (Throwable ignore) {}
        }
        return m;
    }

    /** The receipt: `live` when any line starts with `#live`; `applied` is every non-blank, non-`#` line. */
    static Receipt parseReceipt(java.io.BufferedReader r) {
        boolean live = false;
        java.util.LinkedHashSet<String> s = new java.util.LinkedHashSet<>();
        try {
            String raw;
            while ((raw = r.readLine()) != null) {
                if (raw.startsWith("#live")) live = true;
                String ln = raw.trim();
                if (!ln.isEmpty() && !ln.startsWith("#")) s.add(ln);
            }
        } catch (Throwable ignore) {}
        return new Receipt(live, s);
    }

    /**
     * Did this session prove it can actually write GosPackageState? True when apply confirmed at least one
     * write (the receipt says `#live`), or when there was nothing sealed to replay (a fresh profile, where there
     * is no state to lose and a live read is therefore safe by definition).
     */
    static boolean liveFor(boolean receiptLive, java.util.Map<String, Long> old) {
        return old.isEmpty() || receiptLive;
    }

    /**
     * The carry-forward decision. `read` returns the live masked word for a package, or -1 if unreadable.
     * A row is dropped ONLY for a package in `applied` whose live read is 0.
     */
    static Carried carry(java.util.Map<String, Long> old, java.util.Set<String> applied, Iterable<String> cand,
                         java.util.function.ToLongFunction<String> read) {
        java.util.LinkedHashMap<String, Long> out = new java.util.LinkedHashMap<>();
        int carried = 0;
        for (String pkg : cand) {
            if (applied.contains(pkg)) {
                long f1 = read.applyAsLong(pkg);
                if (f1 > 0L) out.put(pkg, f1);      // live and non-default
                // f1 == 0 -> the user cleared it this session; drop the row, which the receipt authorises.
                // f1 <  0 -> unreadable despite a confirmed write; fall through to carry-forward below.
                if (f1 < 0L && old.containsKey(pkg)) { out.put(pkg, old.get(pkg)); carried++; }
            } else {
                long f1 = read.applyAsLong(pkg);
                if (f1 > 0L) out.put(pkg, f1);      // a NEW setting made this session -- capture it
                else if (old.containsKey(pkg)) { out.put(pkg, old.get(pkg)); carried++; }
            }
        }
        return new Carried(out, carried);
    }

    /**
     * The receipt apply() writes. An empty sealed set still counts as a live mechanism (there was simply nothing
     * to replay); a non-empty one is live only when at least one write landed; every write failing writes no
     * `#live` line at all.
     */
    static String receiptText(boolean wantEmpty, int ok, java.util.List<String> landed) {
        StringBuilder receipt = new StringBuilder();
        for (String p : landed) receipt.append(p).append('\n');
        return (wantEmpty ? "#live empty\n" : (ok > 0 ? "#live\n" : "")) + receipt;
    }

    /** The sealed file body: `<pkg>\t<hex>` per row. */
    static String rowsText(java.util.Map<String, Long> out) {
        StringBuilder sb = new StringBuilder();
        for (java.util.Map.Entry<String, Long> e : out.entrySet())
            sb.append(e.getKey()).append('\t').append(Long.toHexString(e.getValue())).append('\n');
        return sb.toString();
    }

    // ---- (END pure rules) ----

    // ---- file plumbing -------------------------------------------------------------------------------

    /** Deliberately LENIENT, unlike readRows (NWP-20261111-05): an unreadable receipt reads as NOT live, and
     *  not-live is the safe direction -- capture then carries every sealed row forward untouched. */
    private static Receipt readReceipt(Context ctx) {
        try (java.io.BufferedReader r = new java.io.BufferedReader(
                new java.io.FileReader(new File(ctx.getFilesDir(), RECEIPT)))) {
            return parseReceipt(r);
        } catch (Throwable ignore) { return new Receipt(false, new java.util.LinkedHashSet<String>()); }
    }

    /** temp + rename through StoreInstaller.writeAtomic, so a crash mid-write can never leave a truncated carry file,
     *  and a failed write keeps the old file whole: the change is lost, never the file. */
    private static void write(File f, String content) {
        try { StoreInstaller.writeAtomic(f, content); }
        catch (Throwable t) { Log.w("NowhereChooser", "gos write " + f.getName(), t); }
    }
}
