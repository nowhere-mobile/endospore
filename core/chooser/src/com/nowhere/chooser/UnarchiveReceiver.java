package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;

/**
 * On-demand apps (#204): materialise-on-tap entry point.
 *
 * When the user taps an ARCHIVED placeholder, the OS routes {@link Intent#ACTION_UNARCHIVE_PACKAGE} to the
 * installer of record (the chooser) IN THE USER THE APP IS ARCHIVED IN -- our roamed user
 * (PackageArchiver.unarchiveInternal -> sendOrderedBroadcastAsUser(userForUnarchival)). This receiver runs in
 * that roamed-user chooser instance.
 *
 * The actual fetch+install can take many seconds (a real network download), which must NOT happen inside a
 * BroadcastReceiver (it would trip the broadcast-dispatch ANR). Android grants a temporary
 * foreground-service-start allowlist ON the unarchive broadcast (PackageArchiver.createUnarchiveOptions), so the
 * sanctioned pattern is to hand off to a foreground {@link UnarchiveService} and return immediately. The service
 * runs in the same roamed user, so it installs for that user and reaches the user-scoped login socket +
 * reportUnarchivalStatus.
 *
 * The receiver is exported so the system (another uid) can deliver the broadcast, which also lets any app in the
 * session target it by component with any action. {@link UnarchiveGate} refuses everything but the system's
 * ACTION_UNARCHIVE_PACKAGE with a well-formed package name, silently to the sender: no start, no status report.
 */
public class UnarchiveReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        String pkg = intent.getStringExtra(PackageInstaller.EXTRA_UNARCHIVE_PACKAGE_NAME);
        if (!UnarchiveGate.accept(intent.getAction(), pkg)) {
            android.util.Log.w("NowhereChooser", "unarchive refused: not the system's unarchive request");
            return;
        }
        int unarchiveId = intent.getIntExtra(PackageInstaller.EXTRA_UNARCHIVE_ID, -1);
        android.util.Log.i("NowhereChooser", "unarchive tapped: " + pkg + " id=" + unarchiveId);
        try {
            // startForegroundService IS permitted from a receiver's (restricted) context; the broadcast's
            // temporary allowlist covers the FGS start. The service takes over the long fetch+install so this
            // broadcast finishes promptly.
            ctx.startForegroundService(new Intent(ctx, UnarchiveService.class)
                    .putExtra(UnarchiveService.EXTRA_ID, unarchiveId)
                    .putExtra(UnarchiveService.EXTRA_PKG, pkg));
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "start UnarchiveService " + pkg, t);
            // Couldn't even start the worker: tell the OS so it dismisses the progress UI instead of hanging.
            if (unarchiveId >= 0) {
                try {
                    ctx.getPackageManager().getPackageInstaller().reportUnarchivalStatus(
                            unarchiveId, UnarchiveService.unarchivalErrorCode(UnarchiveService.hasValidatedNetwork(ctx)),
                            0, null);
                } catch (Throwable ignore) {}
            }
        }
    }
}
