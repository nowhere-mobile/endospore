package com.nowhere.chooser;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.SuspendDialogInfo;
import android.os.UserHandle;
import android.util.Log;

import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/** NWP-20261130-03: the Android side of {@link OdDataBarrier}. It runs in the session user's chooser process, so the
 *  suspending package is com.nowhere.chooser and the target is this user, as AppClaim's applier. It suspends through
 *  PackageManager and not DevicePolicyManager: a platform suspension shows the stock admin dialog, and this dialog
 *  must say why the app is closed (see AppClaim's header). Marks are files, so a restarted process knows what it holds. */
final class OdDataBarrierHost implements OdDataBarrier.Seam {
    private static final String TAG = "NowhereChooser";
    private static final String MARK_DIR = "nowhere-odbarrier"; // od_chooser_holds in nowhere_roamd.sh reads it

    private final Context ctx;

    private OdDataBarrierHost(Context ctx) { this.ctx = ctx; }

    private static boolean sessionUser() {
        return UserHandle.myUserId() != 0; // the gate holds no session apps
    }

    private static boolean launchable(Context ctx, String pkg) {
        try {
            if (ProfileActivity.isBundledSystem(ctx.getPackageManager(), pkg)) return false;
        } catch (Throwable t) {
            return false; // gone already
        }
        return UnarchiveService.hasInstalledCode(ctx, pkg);
    }

    /** The package-added event, before decide and the install-heal. Runs on the receiver's worker. */
    static void onPackageAdded(Context ctx, String pkg) {
        try {
            if (!sessionUser() || !launchable(ctx, pkg)) return;
            OdDataBarrier.onAdded(new OdDataBarrierHost(ctx), pkg);
        } catch (Throwable t) {
            Log.w(TAG, "od-barrier " + pkg, t);
        }
    }

    /** The same event relayed from user 0 (OdDataAddedReceiver): this process may have been dead when the install landed,
     *  so no install-heal follows. The hold comes first, then the restore. */
    static void onRelayedAdd(Context ctx, String pkg) {
        try {
            if (!sessionUser() || !launchable(ctx, pkg)) return;
            OdDataBarrier.onRelayed(new OdDataBarrierHost(ctx), pkg, p -> retry(ctx, p));
        } catch (Throwable t) {
            Log.w(TAG, "od-barrier relayed " + pkg, t);
        }
    }

    /** One RESTORE-ODDATA reply for pkg (UnarchiveService.markOdRestored, the install-heal, the Try again button). */
    static void afterReply(Context ctx, String pkg, String reply) {
        try {
            if (!sessionUser()) return;
            OdDataBarrier.afterReply(new OdDataBarrierHost(ctx), pkg, reply);
        } catch (Throwable t) {
            Log.w(TAG, "od-barrier " + pkg, t);
        }
    }

    /** The packages of a hold this barrier may not lift: AppClaim must not unsuspend an app whose data is out. */
    static List<String> withoutHeld(Context ctx, List<String> pkgs) {
        List<String> out = new ArrayList<>();
        OdDataBarrierHost h = new OdDataBarrierHost(ctx);
        for (String p : pkgs) if (!h.marked(p)) out.add(p);
        return out;
    }

    private static final Set<String> RETRYING = ConcurrentHashMap.newKeySet();

    /** One more RESTORE-ODDATA for a held package, on its own thread: the RW lane can be held for minutes. A second tap
     *  while one is in flight adds nothing. Sends only for a package this barrier holds. */
    static void retry(Context ctx, String pkg) {
        if (!sessionUser() || pkg == null || !new OdDataBarrierHost(ctx).marked(pkg) || !RETRYING.add(pkg)) return;
        new Thread(() -> {
            try {
                String r = "";
                try {
                    r = DaemonSocket.roundTrip("RESTORE-ODDATA\n" + pkg + "\n", 130000).trim();
                } catch (Throwable t) {
                    Log.w(TAG, "od-barrier retry " + pkg, t);
                }
                if (r.startsWith("OK")) UnarchiveService.markOdRestored(ctx, pkg);
                else afterReply(ctx, pkg, r);
                Log.i(TAG, "od-barrier retry: " + pkg + " -> " + (r.isEmpty() ? "no reply" : r) + " (NWP-20261130-03)");
            } finally {
                RETRYING.remove(pkg);
            }
        }, "nowhere-od-barrier-retry").start();
    }

    /** At a process start and at the user-0 watcher's sweep: see OdDataBarrier.reconcile. */
    static void reconcile(Context ctx) {
        try {
            if (!sessionUser()) return;
            OdDataBarrierHost h = new OdDataBarrierHost(ctx);
            List<String> installed = new ArrayList<>();
            for (ApplicationInfo ai : ctx.getPackageManager().getInstalledApplications(0)) {
                if (ai.packageName == null || ai.packageName.equals(ctx.getPackageName())) continue;
                if (launchable(ctx, ai.packageName)) installed.add(ai.packageName);
            }
            OdDataBarrier.reconcile(h, h.marks(), installed, p -> retry(ctx, p));
        } catch (Throwable t) {
            Log.w(TAG, "od-barrier reconcile", t);
        }
    }

    private File markDir() { return new File(ctx.getFilesDir(), MARK_DIR); }
    private File markFile(String pkg) { return new File(markDir(), pkg); }

    private List<String> marks() {
        String[] n = markDir().list();
        return n == null ? new ArrayList<>() : new ArrayList<>(Arrays.asList(n));
    }

    @Override public String ask(String pkg) {
        try {
            return DaemonSocket.roundTrip("OD-DATA-PENDING\n" + pkg + "\n", 3000).trim();
        } catch (Throwable t) {
            Log.w(TAG, "od-barrier ask " + pkg, t);
            return "";
        }
    }

    @Override public boolean suspend(String pkg, boolean failed) {
        SuspendDialogInfo.Builder b = new SuspendDialogInfo.Builder().setNeutralButtonText("Try again");
        if (failed) {
            b.setTitle("Could not restore this app's data")
             .setMessage("Its data did not arrive, so the app stays closed. Your data is safe. Tap Try again.");
        } else {
            b.setTitle("Restoring this app's data")
             .setMessage("This app's data is still on its way. The app opens when its data is back.");
        }
        try {
            String[] refused = ctx.getPackageManager().setPackagesSuspended(new String[] {pkg}, true, null, null, b.build());
            return refused == null || refused.length == 0;
        } catch (Throwable t) {
            Log.w(TAG, "od-barrier suspend " + pkg, t);
            return false;
        }
    }

    @Override public boolean unsuspend(String pkg) {
        try {
            PackageManager pm = ctx.getPackageManager();
            if (!ProfileActivity.pmKnows(pm, pkg)) return true;
            String[] refused = pm.setPackagesSuspended(new String[] {pkg}, false, null, null, (SuspendDialogInfo) null);
            return refused == null || refused.length == 0;
        } catch (Throwable t) {
            Log.w(TAG, "od-barrier unsuspend " + pkg, t);
            return false;
        }
    }

    @Override public void mark(String pkg) {
        try {
            File d = markDir();
            if (!d.isDirectory() && !d.mkdirs()) throw new java.io.IOException("no mark dir");
            new java.io.FileOutputStream(markFile(pkg)).close();
        } catch (Throwable t) {
            Log.w(TAG, "od-barrier mark " + pkg, t);
        }
    }

    @Override public void confirm(String pkg) {
        try (java.io.FileOutputStream out = new java.io.FileOutputStream(markFile(pkg))) {
            out.write('1');
        } catch (Throwable t) {
            Log.w(TAG, "od-barrier confirm " + pkg, t); // an empty mark: roamd adds its own suspension as the backstop
        }
    }

    @Override public void unmark(String pkg) {
        markFile(pkg).delete();
    }

    @Override public boolean marked(String pkg) {
        return markFile(pkg).isFile();
    }

    @Override public boolean claimedElsewhere(String pkg) {
        return AppClaim.claimHeld(ctx, UserHandle.myUserId(), pkg);
    }

    @Override public void log(String line) {
        Log.i(TAG, line);
    }
}
