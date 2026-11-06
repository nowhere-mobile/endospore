package com.nowhere.chooser;

import android.content.Context;
import android.content.Intent;
import android.util.Log;

import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * NWP-20260819-03: the install half of the store's "Get" — the piece the #747 split dropped.
 *
 * The daemon downloads + sha256-verifies against the SIGNED catalog/index and stages into THIS user's
 * chooser files/.appcode; this class commits the install (the chooser owns the privileged permission),
 * applies the keep line through the decided defaults, and cleans up. Found live on lynx 2026-08-19:
 * "NotePad added." while the APK sat parked in .appcode — StoreService forwarded FETCH-APP and returned,
 * and the install call lived only in the UI path the split killed.
 *
 * Reviewed adversarially before merge; the load-bearing rules, each from a confirmed finding:
 *  - The SIGNER PIN comes from the DAEMON's FETCH-APP OK reply (the entry it resolved from the signed
 *    source), never from the binder caller — a hostile caller stripped the gate by passing "".
 *    A present-but-malformed cert REFUSES (fail-closed), and so does no verdict at all (a null pin,
 *    which StoreSignerPin yields for any reply but "OK <pkg> <64 hex|->"). EVERY install is pinned: a
 *    daemon-declared "-" (the catalog omits the cert) refuses too, with NOSIGNER (decided 2026-10-20).
 *  - PackageInstaller session lifecycle: abandoned on every pre-commit failure; a post-commit latch
 *    timeout is "outcome unknown", so we re-check PackageManager rather than declare failure — the
 *    commit can land after 180 s, and calling that ERR-INSTALL left an installed app with no keep line.
 *  - ALL nowhere-appkeep writes serialize on {@link #APPKEEP_LOCK} and land via temp+rename —
 *    StoreService's binder threads made the file's read-modify-write concurrent for the first time,
 *    and a lost update silently drops an app from the roam.
 *  - The keep line is MODE_AUTO (the #130 store default) and gated on the #136 over-plan rule: adds
 *    are gated, removals never are. An over-plan Get still installs — for this session only — and the
 *    caller is told, so the storefront can say so instead of lying "Added".
 *  - The staged cleartext is deleted win or lose (amnesia), and the pkg's manifest.tsv line is dropped
 *    after a successful install. (The roamed manifest.tsv is read by NOTHING at login — user-0's restore
 *    manifest is rebuilt from the keep-set by the appcode seal at logoff — but a stale line misleads
 *    every future reader of the file, human or code.)
 */
final class StoreInstaller {
    private StoreInstaller() {}

    /** Every reader-modify-writer of files/nowhere-appkeep must hold this. ProfileActivity.writeAppModes
     *  synchronizes here too — StoreService's binder threads and the Profile UI are the same process. */
    static final Object APPKEEP_LOCK = new Object();

    /** In-flight installs by pkg: a double-tap (or a second binder client) short-circuits to BUSY instead
     *  of racing two PackageInstaller sessions whose finally-cleanups delete each other's staged bytes. */
    static final java.util.Set<String> IN_FLIGHT =
            java.util.concurrent.ConcurrentHashMap.newKeySet();

    static final String OK = "OK";
    static final String PENDING = "PENDING";
    static final String FAIL = "FAIL";
    /** The daemon said "-": the catalog entry names no signing cert, so there is nothing to pin against. */
    static final String NOSIGNER = "NOSIGNER";

    /** Install the APK set the daemon staged into files/.appcode/&lt;pkg&gt; for THIS user. Blocking — binder
     *  threads only, never main. signerHex is the DAEMON's resolved cert: "" == the daemon said "-",
     *  null == no daemon verdict; both refuse
     *  (NOSIGNER for "", FAIL for null). */
    static String installStaged(Context ctx, String pkg, String signerHex) {
        File dir = new File(new File(ctx.getFilesDir(), ".appcode"), pkg);
        int sid = -1;
        boolean committed = false;
        android.content.pm.PackageInstaller pi = ctx.getPackageManager().getPackageInstaller();
        try {
            java.util.List<File> apks = new java.util.ArrayList<>();
            File[] kids = dir.listFiles();
            if (kids != null) for (File k : kids) if (k.isFile() && k.getName().endsWith(".apk")) apks.add(k);
            if (apks.isEmpty()) return FAIL;
            if (signerHex == null) {
                Log.w("NowhereChooser", "StoreInstaller " + pkg + ": no daemon signer verdict -- refusing");
                return FAIL;
            }
            String wantSigner = signerHex.trim();
            if (wantSigner.isEmpty()) {
                Log.w("NowhereChooser", "StoreInstaller " + pkg + ": the catalog names no signing cert -- refusing an unpinned install (NWP-20261030-05)");
                return NOSIGNER;
            }
            if (wantSigner.length() != 64 || !stagedSignerMatches(ctx, apks.get(0), wantSigner)) {
                Log.w("NowhereChooser", "StoreInstaller " + pkg + ": signer malformed or does not match the catalog -- refusing");
                return FAIL;
            }
            android.content.pm.PackageInstaller.SessionParams p =
                    new android.content.pm.PackageInstaller.SessionParams(
                            android.content.pm.PackageInstaller.SessionParams.MODE_FULL_INSTALL);
            try { p.setAppPackageName(pkg); } catch (Throwable ignore) {}
            try { p.setInstallReason(android.content.pm.PackageManager.INSTALL_REASON_USER); } catch (Throwable ignore) {}
            try { p.setRequestUpdateOwnership(true); } catch (Throwable ignore) {}
            pinInternalStorage(p); // deliberate -- see the helper
            sid = pi.createSession(p);
            android.content.pm.PackageInstaller.Session ses = pi.openSession(sid);
            try {
                for (File a : apks) {
                    try (InputStream in = new FileInputStream(a);
                         OutputStream out = ses.openWrite(a.getName(), 0, a.length())) {
                        byte[] b = new byte[1 << 16]; int rd;
                        while ((rd = in.read(b)) > 0) out.write(b, 0, rd);
                        ses.fsync(out);
                    }
                }
                final java.util.concurrent.CountDownLatch latch = new java.util.concurrent.CountDownLatch(1);
                final int[] st = { android.content.pm.PackageInstaller.STATUS_FAILURE };
                String action = ctx.getPackageName() + ".STORE_INSTALL." + sid;
                android.content.BroadcastReceiver rcv = new android.content.BroadcastReceiver() {
                    @Override public void onReceive(Context c, Intent i) {
                        st[0] = i.getIntExtra(android.content.pm.PackageInstaller.EXTRA_STATUS,
                                android.content.pm.PackageInstaller.STATUS_FAILURE);
                        latch.countDown();
                    }
                };
                ctx.registerReceiver(rcv, new android.content.IntentFilter(action), Context.RECEIVER_NOT_EXPORTED);
                boolean replied;
                try {
                    android.app.PendingIntent pend = android.app.PendingIntent.getBroadcast(ctx, sid,
                            new Intent(action).setPackage(ctx.getPackageName()),
                            android.app.PendingIntent.FLAG_UPDATE_CURRENT | android.app.PendingIntent.FLAG_MUTABLE);
                    ses.commit(pend.getIntentSender());
                    committed = true; // past this point the session cannot be abandoned; the outcome is the PM's
                    replied = latch.await(180, java.util.concurrent.TimeUnit.SECONDS);
                } finally {
                    try { ctx.unregisterReceiver(rcv); } catch (Throwable ignore) {}
                }
                if (replied) {
                    return st[0] == android.content.pm.PackageInstaller.STATUS_SUCCESS ? OK : FAIL;
                }
                // Latch timeout AFTER commit: outcome unknown, not failure. The commit can still land -- and
                // declaring FAIL here left an installed app with no keep line (review finding). Re-check.
                return isInstalled(ctx, pkg) ? OK : PENDING;
            } finally {
                try { ses.close(); } catch (Throwable ignore) {}
            }
        } catch (Throwable t) {
            Log.w("NowhereChooser", "StoreInstaller " + pkg, t);
            if (sid >= 0 && !committed) {
                try { pi.abandonSession(sid); } catch (Throwable ignore) {}
            }
            return FAIL;
        } finally {
            rmTree(dir); // amnesia: no cleartext APK bytes linger in this user's chooser storage, win or lose
        }
    }

    // ---- NWP-20260821-15: the SESSION PRESENCE RECEIPT (files/nowhere-appseen) ----
    //
    // WHY IT EXISTS. Uninstalling a kept app outside "Your apps" (Settings > Apps, a launcher long-press)
    // removes it from the screen -- which is built from the daemon's live storage walk -- but NOT from the
    // roamed keep-set, so login provisioning brings it back. Chester: "if i uninstall an app which is part of
    // Your apps ... that app goes away from Your apps. but a roam would bring it back."
    //
    // WHY A RECEIPT AND NOT A PM QUERY. There is no point-in-time query that separates "the user uninstalled
    // it" from "on-demand, not yet materialised": an archived placeholder throws NameNotFoundException at
    // flags=0 just like a missing package, and at the WIDEST match (MATCH_ARCHIVED_PACKAGES |
    // MATCH_UNINSTALLED_PACKAGES | MATCH_ANY_USER) a Settings-uninstalled package is equally gone -- which is
    // exactly why the row vanished from "Your apps" in the first place. The only sound discriminator is a
    // TRANSITION observed inside one session: present when the session settled, absent at logoff.
    //
    // WHY ON DISK. A static field dies with the process, and force-stopping the chooser mid-session must not
    // silently disable the prune. The file lives in the chooser's CE dir, so roamd DELETES it at roam-in
    // (nowhere_roamd.sh, beside nowhere-od-materialised / nowhere-od-restored / nowhere-appdrop.list) --
    // mandatory, because CE content is RESTORED FROM THE SEAL even though the user id is new, so without that
    // rm a session whose snapshot never ran would inherit the PREVIOUS session's receipt and prune against it.
    //
    // THE STAMP is belt-and-braces behind that rm: the Android user serial. A receipt whose stamp does not
    // match the live session reads as EMPTY -- never as "everything was seen" -- so every failure mode
    // SUBTRACTS from the eligible set. There is no path by which a package the session did not positively
    // observe present can enter the receipt.
    private static final String SEEN_FILE = "nowhere-appseen";
    /** NWP-20260904-06: packages OBSERVED UNINSTALLED this session, from the PACKAGE_REMOVED broadcast.
     *
     *  The receipt above answers "was it here?", which only ever grows and cannot notice a departure. This
     *  answers "did it leave?", which is the question the logoff prune actually needs and could previously
     *  only INFER -- and could not infer at all for a keep line written by a door that recorded no sighting
     *  (a Play/Aurora/sideload heal, or the Your-apps mode toggle). Both files are stamped with the user
     *  serial and cleared by roamd at roam-in, so neither can leak a verdict across sessions. */
    private static final String GONE_FILE = "nowhere-appgone";

    /** Stamp identifying THIS session: the Android user serial, and nothing else.
     *
     *  Every login mints a BRAND-NEW Android user, so a fresh serial IS a fresh session, and a receipt carried
     *  in from another session's seal was written under a different one. A cold-lock RESUME keeps the same user
     *  and therefore the same stamp, which is correct -- a resume is the same session and its observations still
     *  stand.
     *
     *  NWP-20261120-18: a serial that cannot be read gives NO stamp (null), never {@code #stamp -1}. -1 names no
     *  session, so two sessions whose lookup failed (or a receipt written that way and restored from a seal) would
     *  match each other and union: the one failure that would ADD to the prune's eligible set. A null stamp writes
     *  no receipt and reads every receipt as empty. Same rule as {@code SmsRoleRoam.sessionId}.
     *
     *  ⚠ Deliberately NOT mixed with a wall-clock boot epoch (currentTimeMillis - elapsedRealtime), which was
     *  the first version. That quantity MOVES when NTP corrects the clock, which routinely happens seconds after
     *  a boot brings the network up -- so a stamp written at the snapshot would no longer match the one computed
     *  at logoff, the receipt would read as foreign, and the prune would silently never fire. It would have
     *  failed safe, and therefore failed INVISIBLY, on an ordinary phone doing an ordinary thing. The replay it
     *  was guarding (a serial reused after a userdata wipe, colliding with a restored receipt) is already
     *  covered by roamd's rm at roam-in, which is the primary defence; this is the second lock, not the first. */
    private static String seenStamp(Context ctx) {
        long serial = -1;
        try {
            android.os.UserManager um = (android.os.UserManager) ctx.getSystemService(Context.USER_SERVICE);
            serial = um.getSerialNumberForUser(android.os.Process.myUserHandle());
        } catch (Throwable ignore) {
        }
        return stampFor(serial);
    }

    /** The receipt stamp for a user serial, or null when the serial is negative (unreadable): see seenStamp. */
    static String stampFor(long serial) {
        return serial < 0 ? null : "#stamp " + serial;
    }

    /** Record that every keep-set package PM can currently see is PRESENT in this session. Called once the
     *  session has settled (UnarchiveService's auto sweep), which is after provisioning has raised the
     *  on-demand placeholders -- so a placeholder counts as present and can never be mistaken for a removal.
     *
     *  Unions only when the stamp matches; otherwise truncates and re-stamps. A blind truncate would let the
     *  resume path silently cancel a legitimate prune; a blind union would let a stale file authorise one. An
     *  unreadable user serial records nothing. */
    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {
        synchronized (APPKEEP_LOCK) {
            try {
                File f = new File(ctx.getFilesDir(), SEEN_FILE);
                String stamp = seenStamp(ctx);
                if (stamp == null) {
                    Log.w("NowhereChooser", "presence receipt: user serial unreadable -- not recorded");
                    return;
                }
                java.util.LinkedHashSet<String> all = new java.util.LinkedHashSet<>();
                if (stampMatches(f, stamp)) all.addAll(readSeenLines(f));
                all.addAll(presentPkgs);
                StringBuilder sb = new StringBuilder(stamp).append('\n');
                for (String q : all) sb.append(q).append('\n');
                writeAtomic(f, sb.toString());
            } catch (Throwable t) {
                Log.w("NowhereChooser", "snapshotAppSeen", t); // no receipt => no prune; failing is safe
            }
        }
    }

    /** Add one package to the receipt (a store install, or a materialise that landed). */
    static void noteAppSeen(Context ctx, String pkg) {
        java.util.LinkedHashSet<String> one = new java.util.LinkedHashSet<>();
        one.add(pkg);
        snapshotAppSeen(ctx, one);
    }

    /** Record that pkg was observed UNINSTALLED in this session. Same stamp discipline as the receipt: a
     *  foreign stamp truncates and re-stamps, so a verdict can never survive into another session, and an
     *  unreadable user serial records nothing. */
    static void noteAppGone(Context ctx, String pkg) {
        synchronized (APPKEEP_LOCK) {
            try {
                File f = new File(ctx.getFilesDir(), GONE_FILE);
                String stamp = seenStamp(ctx);
                if (stamp == null) {
                    Log.w("NowhereChooser", "presence receipt: user serial unreadable -- not recorded");
                    return;
                }
                java.util.LinkedHashSet<String> all = new java.util.LinkedHashSet<>();
                if (stampMatches(f, stamp)) all.addAll(readSeenLines(f));
                if (!all.add(pkg)) return;
                StringBuilder sb = new StringBuilder(stamp).append((char) 10);
                for (String q : all) sb.append(q).append((char) 10);
                writeAtomic(f, sb.toString());
                Log.i("NowhereChooser", "app gone this session: " + pkg + " (NWP-20260904-06)");
            } catch (Throwable t) {
                Log.w("NowhereChooser", "noteAppGone", t); // no record => no prune, which is the safe direction
            }
        }
    }

    /** The packages this session watched leave, or EMPTY if the file is missing/unstamped/foreign or the user
     *  serial is unreadable. */
    static java.util.Set<String> appGoneThisSession(Context ctx) {
        synchronized (APPKEEP_LOCK) {
            File f = new File(ctx.getFilesDir(), GONE_FILE);
            String stamp = seenStamp(ctx);
            if (stamp == null) return java.util.Collections.emptySet();
            if (!stampMatches(f, stamp)) return java.util.Collections.emptySet();
            return readSeenLines(f);
        }
    }

    /** NWP-20260904-07: static twin of ProfileActivity.removeKeepLines, for a caller that holds only a
     *  Context (the post-login sweep). Same contract: survivors are re-emitted BYTE FOR BYTE, tokens and
     *  all -- never round-tripped through the (lossy) mode parser -- and a removal is never plan-gated. */
    static void removeKeepLines(Context ctx, java.util.Set<String> drop) {
        if (drop == null || drop.isEmpty()) return;
        synchronized (APPKEEP_LOCK) {
            try {
                File f = new File(ctx.getFilesDir(), "nowhere-appkeep");
                if (!f.exists()) return;
                StringBuilder sb = new StringBuilder();
                try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f))) {
                    String ln;
                    while ((ln = r.readLine()) != null) {
                        if (ln.trim().isEmpty()) continue;
                        if (drop.contains(ln.split("\t", 2)[0].trim())) continue;
                        sb.append(ln).append((char) 10);
                    }
                }
                writeAtomic(f, sb.toString());
            } catch (Throwable t) {
                Log.w("NowhereChooser", "removeKeepLines", t);
            }
        }
    }

    /** NWP-20261012-06: put the keep-set in the order the user dragged "Your apps" into, which is the order the
     *  automatic install works through (UnarchiveService.pendingAutoApps reads it in file order). Every line is
     *  re-emitted VERBATIM -- mode and group: token untouched -- the named packages first, in `order`, then each line
     *  it does not name in its old order (KeepOrder.reorder). Re-read under the lock, so an edit that landed since the
     *  screen was built is kept, never lost. True when the file is in that order (or absent: nothing to order). */
    static boolean reorderKeepLines(Context ctx, java.util.List<String> order) {
        synchronized (APPKEEP_LOCK) {
            try {
                File f = new File(ctx.getFilesDir(), "nowhere-appkeep");
                if (!f.exists()) return true;
                String was = KeepOrder.readText(f);
                String now = KeepOrder.reorder(was, order);
                if (!now.equals(was)) writeAtomic(f, now);
                return true;
            } catch (Throwable t) {
                Log.w("NowhereChooser", "reorderKeepLines", t);
                return false;
            }
        }
    }

    /** NWP-20261012-06: "Download first" is retired (DECIDED 2026-10-12). The apps it marked move to the top of the
     *  keep order once, in the order they were marked, and then nowhere-appfirst is deleted. Idempotent: absent file,
     *  nothing to do; a crash between the reorder and the delete re-runs the same reorder, which changes nothing. The
     *  marks are deleted only after the reorder landed, so a failed write retries at the next call. */
    static void foldAppFirst(Context ctx) {
        synchronized (APPKEEP_LOCK) {
            File first = new File(ctx.getFilesDir(), "nowhere-appfirst");
            if (!first.exists()) return;
            java.util.List<String> marks;
            try { marks = KeepOrder.marks(KeepOrder.readText(first)); }
            catch (Throwable t) { Log.w("NowhereChooser", "foldAppFirst: read", t); return; }
            if (!reorderKeepLines(ctx, marks)) return;
            if (!first.delete() && first.exists()) { Log.w("NowhereChooser", "foldAppFirst: delete failed"); return; }
            Log.i("NowhereChooser", "Download first retired: " + marks.size() + " app(s) moved to the top of the keep order");
        }
    }

    /** NWP-20261012-06: the user's "Wake for notifications" choices (nowhere-appwake: overrides only). Empty when
     *  there are none or the file cannot be read -- every app then follows the messaging rule. */
    static java.util.Map<String, Boolean> wakeOverrides(Context ctx) {
        synchronized (WAKE_LOCK) {
            File f = new File(ctx.getFilesDir(), "nowhere-appwake");
            try { return f.exists() ? KeepOrder.parseWake(KeepOrder.readText(f)) : new java.util.LinkedHashMap<>(); }
            catch (Throwable t) { Log.w("NowhereChooser", "wakeOverrides", t); return new java.util.LinkedHashMap<>(); }
        }
    }

    /** NWP-20261012-06: record the user's choice for pkg. Kept even when it matches today's default: the default for
     *  an archived placeholder can differ from the installed app's (UnarchiveService.wakeOnRestore), and a choice the
     *  user made must not move when the default does. NWP-20261125-26: true only when nowhere-appwake now holds the
     *  choice (writeAtomic returned); false on any failure, and the file is then as it was. */
    static boolean setWakeOverride(Context ctx, String pkg, boolean on) {
        synchronized (WAKE_LOCK) {
            try {
                File f = new File(ctx.getFilesDir(), "nowhere-appwake");
                writeAtomic(f, KeepOrder.setWake(f.exists() ? KeepOrder.readText(f) : "", pkg, on));
                return true;
            } catch (Throwable t) {
                Log.w("NowhereChooser", "setWakeOverride", t);
                return false;
            }
        }
    }

    /** nowhere-appwake's own lock: a leaf, nothing is taken under it. */
    private static final Object WAKE_LOCK = new Object();

    /** NWP-20260904-07: static twin of ProfileActivity.recordTurnedOff. Appends pkg to nowhere-appoff.list
     *  so the drop capture stops carrying its data -- the SAME thing the logoff prune records for an app the
     *  user uninstalled, which is what a phantom line was. A later keep line retires the entry again
     *  (clearTurnedOff, NWP-20260926-01).
     *
     *  NWP-20261025-06: reads the file RAW and strictly (turnedOffLinesRaw), never through explicitlyTurnedOff --
     *  roamd's appcode_stage_play_dormant reads the raw file for the Play-stack lines that view filters out (DECIDED
     *  2026-09-26, NWP-20261024-07), so a rewrite from the filtered view deleted them; and a read error now writes
     *  nothing, where the swallowing view rewrote the file with only what it had read plus {@code pkg}. */
    static void recordTurnedOff(Context ctx, String pkg) {
        synchronized (APPKEEP_LOCK) {
            try {
                File f = new File(ctx.getFilesDir(), "nowhere-appoff.list");
                java.util.LinkedHashSet<String> s;
                try {
                    s = turnedOffLinesRaw(f);
                } catch (Throwable t) {
                    Log.w("NowhereChooser", "Off record unreadable -- nothing written (NWP-20261025-06)");
                    return;
                }
                if (!s.add(pkg)) return;
                StringBuilder sb = new StringBuilder();
                for (String p : s) sb.append(p).append((char) 10);
                writeAtomic(f, sb.toString());
            } catch (Throwable t) {
                Log.w("NowhereChooser", "recordTurnedOff", t);
            }
        }
    }

    /** NWP-20260926-01: the inverse of recordTurnedOff, for an app switched back On. Until this existed nothing
     *  ever removed a line from nowhere-appoff.list, so an Off the user had undone still steered two consumers:
     *  AppInstallReceiver.decide treats the package as switched Off before its returning-app reset, and roamd's
     *  code-side drop is appoff ∩ appdrop, so a later un-keep of any other kind became an account-wide code drop.
     *
     *  Retires ONLY packages whose keep line is on disk, re-read here under the lock: an Off record is never
     *  removed for an app that is not kept (the NWP-20260825-22 leak shape). Callers pass only what their own
     *  write just ADDED, never every kept package -- the logoff prune and the phantom reconcile record an Off
     *  and then remove the keep line, and a write that did not add the package cannot retire it in between.
     *  Never adds; a failure leaves the stale line, which is the state before this method existed.
     *
     *  NWP-20261025-06: reads the file raw and strictly for the same reason as recordTurnedOff -- roamd's
     *  appcode_stage_play_dormant reads the raw file (DECIDED 2026-09-26, NWP-20261024-07), and only the raw read holds
     *  a kept Play Store's line, which the filtered view never showed and so could never retire. */
    static void clearTurnedOff(Context ctx, java.util.Collection<String> pkgs) {
        clearUninstalled(ctx, pkgs); // NWP-20261023-10: a re-keep retires the uninstall line too, even when no Off line is left
        if (pkgs == null || pkgs.isEmpty()) return;
        synchronized (APPKEEP_LOCK) {
            try {
                java.util.Set<String> kept = ProfileActivity.keepSetAll(ctx);
                java.util.LinkedHashSet<String> s;
                try {
                    s = turnedOffLinesRaw(new File(ctx.getFilesDir(), "nowhere-appoff.list"));
                } catch (Throwable t) {
                    Log.w("NowhereChooser", "Off record unreadable -- nothing written (NWP-20261025-06)");
                    return;
                }
                java.util.List<String> retired = new java.util.ArrayList<>();
                for (String p : pkgs) if (kept.contains(p) && s.remove(p)) retired.add(p);
                if (retired.isEmpty()) return;
                StringBuilder sb = new StringBuilder();
                for (String p : s) sb.append(p).append((char) 10);
                writeAtomic(new File(ctx.getFilesDir(), "nowhere-appoff.list"), sb.toString());
                Log.i("NowhereChooser", "Off record retired for " + retired + " -- kept again (NWP-20260926-01)");
            } catch (Throwable t) {
                Log.w("NowhereChooser", "clearTurnedOff", t);
            }
        }
    }

    /** NWP-20261023-10: the UNINSTALL half of the split of nowhere-appoff.list (DECIDED 2026-09-26: an Off never mints
     *  the account tombstone, and the Off record "holds Offs and uninstalls alike, so it has to be split before the
     *  tombstone goes live"; DECIDED 2026-09-06: a deliberate uninstall deletes the app from the ACCOUNT). Appends the
     *  packages the user UNINSTALLED to files/nowhere-appgone.list. The Off record keeps every line it has, uninstalls
     *  included, so the data drop and the code drop are unchanged; this file says which of those lines are uninstalls.
     *
     *  Only the two uninstall writers call it (the logoff prune and the phantom-line reconcile), never an Off writer.
     *  The pruner passes its uninstalled set, not its drop set, which also holds apps that became bundled-system.
     *
     *  ⚠ NOT nowhere-appgone (GONE_FILE, the session receipt roamd deletes at every roam-in): that name differs from
     *  this one only by the suffix, and roamd's rm of it must never be widened to a glob. This file persists with the
     *  profile. Its consumer is roamd's appcode_seal; until that lands nothing reads it.
     *
     *  The record is read strictly: a read error writes nothing, where recordTurnedOff's swallowing read would rewrite
     *  the file with only the new package and drop the rest. One write per call, none when nothing was added; a
     *  failure is logged, never thrown, and leaves the file as it was. Logs counts only, never a package name. */
    static void recordUninstalled(Context ctx, java.util.Collection<String> pkgs) {
        if (pkgs == null || pkgs.isEmpty()) { return; }
        synchronized (APPKEEP_LOCK) {
            try {
                File f = new File(ctx.getFilesDir(), "nowhere-appgone.list");
                java.util.LinkedHashSet<String> s = uninstalledLines(f);
                int added = 0;
                for (String p : pkgs) {
                    if (p == null || p.trim().isEmpty()) continue;
                    if (s.add(p.trim())) added++;
                }
                if (added == 0) return;
                StringBuilder sb = new StringBuilder();
                for (String p : s) sb.append(p).append((char) 10);
                writeAtomic(f, sb.toString());
                Log.i("NowhereChooser", "uninstall record: " + added + " app(s) added (NWP-20261023-10)");
            } catch (Throwable t) {
                Log.w("NowhereChooser", "recordUninstalled", t);
            }
        }
    }

    /** NWP-20261023-10: the packages recorded as uninstalled, trimmed, blanks skipped. An absent or unreadable file
     *  reads empty. Lock-free like explicitlyTurnedOff: writers replace the file by rename, so a reader never sees a
     *  half file. */
    static java.util.LinkedHashSet<String> readUninstalled(Context ctx) {
        try {
            return uninstalledLines(new File(ctx.getFilesDir(), "nowhere-appgone.list"));
        } catch (Throwable t) {
            return new java.util.LinkedHashSet<>();
        }
    }

    /** NWP-20261023-10: the inverse of recordUninstalled, for an app kept again (clearTurnedOff calls it first).
     *  Retires ONLY packages whose keep line is on disk, re-read here under the lock -- the guard clearTurnedOff
     *  applies to the Off record. Never adds; writes only when something was retired; a failure leaves the file as
     *  it was, so the stale line stays, which is the safe direction. Logs a count only. */
    static void clearUninstalled(Context ctx, java.util.Collection<String> pkgs) {
        if (pkgs == null || pkgs.isEmpty()) { return; }
        synchronized (APPKEEP_LOCK) {
            try {
                java.util.Set<String> onDisk = ProfileActivity.keepSetAll(ctx);
                File f = new File(ctx.getFilesDir(), "nowhere-appgone.list");
                java.util.LinkedHashSet<String> s = uninstalledLines(f);
                int retired = 0;
                for (String p : pkgs) if (onDisk.contains(p) && s.remove(p)) retired++;
                if (retired == 0) return;
                StringBuilder sb = new StringBuilder();
                for (String p : s) sb.append(p).append((char) 10);
                writeAtomic(f, sb.toString());
                Log.i("NowhereChooser", "uninstall record: " + retired + " app(s) retired -- kept again (NWP-20261023-10)");
            } catch (Throwable t) {
                Log.w("NowhereChooser", "clearUninstalled", t);
            }
        }
    }

    /** NWP-20261025-06: nowhere-appoff.list as the file holds it -- every non-empty trimmed line in file order, the
     *  Play-stack lines included. An absent file is empty; any other failure throws, a path that exists but cannot be
     *  opened (a directory) too. */
    private static java.util.LinkedHashSet<String> turnedOffLinesRaw(File f) throws java.io.IOException {
        java.util.LinkedHashSet<String> out = new java.util.LinkedHashSet<>();
        if (!f.exists()) return out;
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f))) {
            String ln;
            while ((ln = r.readLine()) != null) {
                ln = ln.trim();
                if (!ln.isEmpty()) out.add(ln);
            }
        }
        return out;
    }

    /** The strict reader both writers share: an absent file is empty, any other read error throws. */
    private static java.util.LinkedHashSet<String> uninstalledLines(File f) throws java.io.IOException {
        java.util.LinkedHashSet<String> out = new java.util.LinkedHashSet<>();
        if (!f.exists()) return out;
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f))) {
            String ln;
            while ((ln = r.readLine()) != null) {
                ln = ln.trim();
                if (!ln.isEmpty()) out.add(ln);
            }
        }
        return out;
    }

    /** The packages positively observed present this session, or EMPTY if the receipt is missing, unstamped,
     *  or stamped for another session/boot, or if the user serial is unreadable. Empty means "prune nothing",
     *  which is the safe direction. */
    static java.util.Set<String> appSeenThisSession(Context ctx) {
        synchronized (APPKEEP_LOCK) {
            File f = new File(ctx.getFilesDir(), SEEN_FILE);
            String stamp = seenStamp(ctx);
            if (stamp == null) return java.util.Collections.emptySet();
            if (!stampMatches(f, stamp)) return java.util.Collections.emptySet();
            return readSeenLines(f);
        }
    }

    private static boolean stampMatches(File f, String want) {
        if (want == null || !f.exists()) return false;
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f))) {
            String first = r.readLine();
            return first != null && first.trim().equals(want);
        } catch (Throwable t) {
            return false;
        }
    }

    private static java.util.Set<String> readSeenLines(File f) {
        java.util.LinkedHashSet<String> out = new java.util.LinkedHashSet<>();
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f))) {
            String ln;
            while ((ln = r.readLine()) != null) {
                ln = ln.trim();
                if (!ln.isEmpty() && !ln.startsWith("#")) out.add(ln);
            }
        } catch (Throwable ignore) {
        }
        return out;
    }

    /** The #136-gated keep write, in the #130 store-default mode (AUTO). Adds are gated on over-plan,
     *  removals never are (this method only adds). Returns true when the keep line landed; false when the
     *  over-plan gate dropped it -- the app is installed FOR THIS SESSION ONLY and the caller must say so.
     *  A pkg already present in any mode is left exactly as the user set it (and counts as kept). */
    /** NWP-20260825-15: keepAuto with the mode supplied, so the Configuration screen decides it rather than
     *  this file hard-coding MODE_AUTO. Same locking, same #136 over-plan gate, same "the user's existing
     *  choice stands" rule -- only the mode written for a NEW line changes. */
    static boolean keepInMode(Context ctx, String pkg, boolean overPlan, String mode) {
        return keepAutoImpl(ctx, pkg, overPlan, mode);
    }

    static boolean keepAuto(Context ctx, String pkg, boolean overPlan) {
        // The nApps/F-Droid default, now configurable. Chester: "nApps is mainly just a curated version of
        // f-droid" -- so an F-Droid install is filed under the same default, not treated as a sideload.
        return keepAutoImpl(ctx, pkg, overPlan,
                ProfileActivity.cfgStatic(ctx, ProfileActivity.CFG_APPS_NAPPS));
    }

    /** NWP-20260826-03: pin every install to INTERNAL storage, and say that it is DELIBERATE.
     *
     *  ⚠ THIS LOOKS LIKE A BUG AND IS NOT. PackageInstallerSession yells on every install of an app that
     *  declares android:installLocation:
     *
     *      com.nowhere.chooser drops manifest attribute android:installLocation in base.apk for <pkg>
     *
     *  (a Slog.wtf under the AOSP comment "Yell loudly if installers drop attribute installLocation when apps
     *  explicitly set" -- it is NOT fatal; execution continues, and the VLC failure that surfaced this was
     *  INSTALL_FAILED_NO_MATCHING_ABIS, an unrelated cause). The obvious way to silence it is to propagate the
     *  APK's declared value into the session. DO NOT.
     *
     *  An app declaring preferExternal would then be free to land OUTSIDE the boundary this OS enforces
     *  everywhere else: amnesia is scoped to what the reap and the boot-wipe can remove, which is the Android
     *  USER, and #156 already had to block external media (DISALLOW_MOUNT_PHYSICAL_MEDIA, ChooserActivity:940)
     *  precisely because cleartext there survives power-off. Honouring an app's placement preference would
     *  re-open by accident what that restriction closes on purpose -- and it would do so silently, on whichever
     *  third-party app happened to ask.
     *
     *  So the wtf stays. It is the framework correctly reporting that we override the app, which we do, for a
     *  reason the framework cannot know. Setting it explicitly (rather than relying on SessionParams' default,
     *  which happens to be INTERNAL_ONLY) makes that a decision in the source instead of an accident that the
     *  next reader is tempted to "fix". */
    static void pinInternalStorage(android.content.pm.PackageInstaller.SessionParams p) {
        try {
            p.setInstallLocation(android.content.pm.PackageInfo.INSTALL_LOCATION_INTERNAL_ONLY);
        } catch (Throwable ignore) {
        }
    }

    /** NWP-20260825-20: does pkg already have a keep line? keepAutoImpl cannot answer this for its caller --
     *  it returns TRUE both when it wrote a line and when one was already there ("the user's existing choice
     *  stands"), which is right for its own contract and useless for reporting. AppInstallReceiver needs the
     *  difference: without it the catch-up sweep announced "applied to N undecided app(s)" for apps it had not
     *  touched, which is the same species of lie as the silence that hid the receiver never running at all. */
    static boolean keepSetHas(Context ctx, String pkg) {
        synchronized (APPKEEP_LOCK) {
            try (java.io.BufferedReader r = new java.io.BufferedReader(
                    new java.io.FileReader(new File(ctx.getFilesDir(), "nowhere-appkeep")))) {
                String ln;
                while ((ln = r.readLine()) != null) {
                    if (ln.split("\t", 2)[0].trim().equals(pkg)) return true;
                }
            } catch (Throwable ignore) {
            }
            return false;
        }
    }

    private static boolean keepAutoImpl(Context ctx, String pkg, boolean overPlan, String mode) {
        // ⚠ NWP-20260827-09: RECORD THE PLAY DEPENDENCY BEFORE THE OFF EARLY-RETURN, NOT AFTER.
        //
        // This is the ONE moment the APK is guaranteed on disk, and the fact "this app needs Play Services"
        // is worth knowing whether or not we go on to keep the app. Recording it after the return meant an
        // install whose bucket defaults to Off was never asked -- and Off is the default for Play, Aurora,
        // the GrapheneOS App Store and everything else, i.e. for most installs.
        //
        // Chester hit exactly that on 2026-08-27: YouTube arrived from the GrapheneOS App Store, whose bucket
        // was Off, so nothing recorded that it needs Play. He set it to on-demand by hand (the live read
        // worked, it was still installed), turned it Off, then On again -- by which point it was ARCHIVED, the
        // read threw, and it never returned to nowhere-playdeps. The Play stack was dropped and could not come
        // back. One line earlier and the record would have existed from the start.
        ProfileActivity.recordPlayDepAtInstall(ctx, pkg);
        if (ProfileActivity.APPDEF_OFF.equals(mode)) return true; // configured not to keep -- nothing to write
        synchronized (APPKEEP_LOCK) {
            boolean wrote = false; // NWP-20261105-03: the keep line is on disk -- only then may a throw answer kept
            try {
                File f = new File(ctx.getFilesDir(), "nowhere-appkeep");
                StringBuilder sb = new StringBuilder();
                boolean present = false;
                if (f.exists()) {
                    try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f))) {
                        String ln;
                        while ((ln = r.readLine()) != null) {
                            if (!ln.trim().isEmpty()) sb.append(ln).append('\n');
                            if (ln.split("\t", 2)[0].trim().equals(pkg)) present = true;
                        }
                    }
                }
                if (present) return true;       // the user's existing choice stands
                if (overPlan) return false;     // #136: an add while over plan is refused -- honestly
                sb.append(pkg).append('\t').append(mode).append('\n'); // #130 store default
                writeAtomic(f, sb.toString());
                wrote = true;
                clearTurnedOff(ctx, java.util.Collections.singleton(pkg)); // NWP-20260926-01: a store add is a re-keep
                // NWP-20260904-06: the other claim site. This runs at INSTALL, so the APK is on disk and the
                // sighting is unambiguously true -- see the long note in ProfileActivity.writeAppModes for why
                // a claim with no sighting makes the keep line un-prunable forever. Guarded because a binder
                // thread must not die over a receipt.
                try { noteAppSeen(ctx, pkg); } catch (Throwable ignore) {}
                // NWP-20260827-09: the -12 call that used to live here has moved to the TOP of this method,
                // above the Off early-return -- see the note there. Keeping a second copy would just re-read a
                // manifest we have already recorded.
                return true;
            } catch (Throwable t) {
                Log.w("NowhereChooser", "StoreInstaller keepAuto " + pkg, t);
                // NWP-20261105-03: answer what is on disk. A read or write that threw left no keep line, so this is
                // NOT kept, and nothing retries it: a store install's installer is the chooser, which
                // ProfileActivity.cfgKeyForInstaller files under CFG_APPS_NAPPS, and AppInstallReceiver.decide skips
                // that bucket on the broadcast and on the catch-up alike. So getApp must answer OK-UNSAVED, and
                // nApps' "won't come back" is accurate. Nothing is uninstalled; the app stays for this session. Only
                // keepInMode's callers (the other buckets) log "refused by keepInMode" and are retried at the next
                // catch-up. A throw after the write (clearTurnedOff) still answers kept. The fail-open that stays
                // is the over-plan gate's, in the caller -- a gate that throws must not cost the user their app.
                return wrote;
            }
        }
    }

    /** Drop pkg's line from .appcode/manifest.tsv after a successful install. Nothing reads the roamed
     *  user's manifest at login (user-0's restore manifest is rebuilt from the keep-set at logoff), but a
     *  stale "installed" line misleads every future reader of the file. */
    static void dropManifestLine(Context ctx, String pkg) {
        synchronized (APPKEEP_LOCK) {
            try {
                File man = new File(new File(ctx.getFilesDir(), ".appcode"), "manifest.tsv");
                if (!man.isFile()) return;
                StringBuilder sb = new StringBuilder();
                try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(man))) {
                    String ln;
                    while ((ln = r.readLine()) != null) {
                        if (ln.isEmpty() || ln.split("\t", 2)[0].equals(pkg)) continue;
                        sb.append(ln).append('\n');
                    }
                }
                writeAtomic(man, sb.toString());
            } catch (Throwable t) {
                Log.w("NowhereChooser", "StoreInstaller dropManifestLine " + pkg, t);
            }
        }
    }

    /** overPlan, ported from ProfileActivity: parse the GET-ENTITLEMENT line ("used=" / "covered=").
     *  Fail-open on anything unparseable -- a gate that throws must not cost the user their app. */
    static boolean overPlanLine(String entitlement) {
        try {
            if (entitlement == null || !entitlement.startsWith("OK")) return false;
            long used = -1, covered = -1;
            for (String tok : entitlement.trim().split("\\s+")) {
                int eq = tok.indexOf('=');
                if (eq < 0) continue;
                try {
                    long v = Long.parseLong(tok.substring(eq + 1));
                    if ("used".equals(tok.substring(0, eq))) used = v;
                    else if ("covered".equals(tok.substring(0, eq))) covered = v;
                } catch (NumberFormatException ignore) {}
            }
            return covered > 0 && used > covered;
        } catch (Throwable ignore) {
            return false;
        }
    }

    static boolean isInstalled(Context ctx, String pkg) {
        try { return ctx.getPackageManager().getPackageInfo(pkg, 0) != null; }
        catch (Throwable t) { return false; }
    }

    /** The file I/O writeAtomic does, as a seam so a javac suite can make each step fail (test-write-atomic-java.sh). */
    interface AtomicIo {
        java.io.Writer open(File f) throws java.io.IOException;
        boolean rename(File from, File to);
    }

    /** The real one: FileWriter (the platform charset, UTF-8 on Android, which every caller already wrote with) and
     *  renameTo. */
    static final AtomicIo FILE_IO = new AtomicIo() {
        @Override public java.io.Writer open(File f) throws java.io.IOException { return new java.io.FileWriter(f); }
        @Override public boolean rename(File from, File to) { return from.renameTo(to); }
    };

    /** temp + rename in the same dir, so no reader (or crash) ever sees a half-written file. */
    static void writeAtomic(File f, String content) throws java.io.IOException {
        writeAtomic(f, content, FILE_IO);
    }

    /** writeAtomic over a seam. It never opens {@code f}: the text goes to {@code <name>.tmp} and only a rename puts it
     *  there. On ANY failure (open, write, close, rename) the .tmp is deleted and the exception thrown, so {@code f} is
     *  exactly as it was. */
    static void writeAtomic(File f, String content, AtomicIo io) throws java.io.IOException {
        File tmp = new File(f.getParentFile(), f.getName() + ".tmp");
        // no fsync: a power loss ends the session, and the boot wipe removes its files anyway
        try {
            try (java.io.Writer w = io.open(tmp)) { w.write(content); }
            // no direct-write fallback on a failed rename: a direct write truncates f first, which is exactly the loss
            // the temp file prevents. The old file stays whole and the caller's catch logs it.
            if (!io.rename(tmp, f)) throw new java.io.IOException("rename " + tmp + " -> " + f + " failed");
        } catch (java.io.IOException | RuntimeException e) {
            //noinspection ResultOfMethodCallIgnored
            tmp.delete();
            throw e;
        }
    }

    private static boolean stagedSignerMatches(Context ctx, File apk, String wantHex) {
        try {
            android.content.pm.PackageInfo pi = ctx.getPackageManager().getPackageArchiveInfo(
                    apk.getAbsolutePath(), android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES);
            android.content.pm.SigningInfo si = pi != null ? pi.signingInfo : null;
            android.content.pm.Signature[] sigs = si != null ? si.getApkContentsSigners() : null;
            if (sigs == null || sigs.length == 0) return false;
            for (android.content.pm.Signature s : sigs) {
                if (sha256hex(s.toByteArray()).equalsIgnoreCase(wantHex)) return true;
            }
            return false;
        } catch (Throwable t) {
            Log.w("NowhereChooser", "StoreInstaller signer", t);
            return false;
        }
    }

    private static String sha256hex(byte[] b) {
        try {
            byte[] d = java.security.MessageDigest.getInstance("SHA-256").digest(b);
            char[] hx = "0123456789abcdef".toCharArray();
            StringBuilder sb = new StringBuilder(64);
            for (byte x : d) { sb.append(hx[(x >> 4) & 0xf]); sb.append(hx[x & 0xf]); }
            return sb.toString();
        } catch (Throwable t) {
            return "";
        }
    }

    private static void rmTree(File f) {
        if (f == null || !f.exists()) return;
        File[] kids = f.listFiles();
        if (kids != null) for (File k : kids) rmTree(k);
        //noinspection ResultOfMethodCallIgnored
        f.delete();
    }
}
