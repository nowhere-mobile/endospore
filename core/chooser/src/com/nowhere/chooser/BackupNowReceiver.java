package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * "Back up now" action on the mid-session back-online prompt (DIA-20260713, gap: mid-session Wi-Fi loss).
 * Fires in the ROAMED user (the notification is posted into that user's shade). Sends one BACKUP line to the
 * login daemon, which seals the LIVE session to the store IN PLACE -- no reap, no reboot, session preserved.
 *
 * Deliberately NOT ReloginReceiver: RELOGIN discards the live session and reloads the last sealed head, which
 * for an online-then-dropped session would DESTROY the very unsynced changes this action is meant to save.
 * handleBackup replies OK at once and seals in a background goroutine; we swap the prompt to a "Saving…" state
 * for feedback, and the user-0 backup-health watcher clears it once a seal announced after the reconnect has landed
 * (GET-SEAL-LANDED, BackNowCycle; NWP-20261117-27), not when GET-SYNC-STATUS reads OK. A BUSY reply that names a running
 * save means the tap joined it, so the "Saving…" state stays too (NWP-20261201-09). The notice's tap carries the reconnect
 * stamp, sent as an AFTER line in the BACKUP request, so the daemon can queue one more save when the running one predates
 * the reconnect.
 */
public class BackupNowReceiver extends BroadcastReceiver {
    public static final String EXTRA_RECONNECT_AT = "nowhere.backnow.reconnect_at";
    private static final String SOCKET = "nowhere_login";
    private static final int CONNECT_CAP_MS = 8000;
    private static final int READ_CAP_MS = 5000;

    /** Gives the tap its outcome on the notification. Only the caller that wins the same flag finish() uses decides, so
     *  a tap is decided once: the worker with the daemon's reply, or the watchdog with null when nothing answered. */
    private static void decide(Context ctx, String reply, long reconnectAt) {
        try {
            int a = BackupNowReply.action(reply);
            android.util.Log.i("NowhereChooser", "back-up-now reply -> "
                    + (a == BackupNowReply.SAVING ? "SAVING" : a == BackupNowReply.CLEAR ? "CLEAR" : "PROMPT"));
            if (a == BackupNowReply.CLEAR) ChooserActivity.clearBackNowNotice(ctx);
            else if (a == BackupNowReply.PROMPT) ChooserActivity.postBackNowRefused(ctx, BackupNowReply.body(reply), reconnectAt);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "back-up-now decide", t);
        }
    }

    @Override
    public void onReceive(Context ctx, Intent intent) {
        try {
            android.util.Log.i("NowhereChooser", "back-up-now tapped (seal live session in place)");
            final int uid = android.os.UserHandle.myUserId();
            ChooserActivity.postSavingNotice(ctx, uid); // immediate feedback; watcher clears it on seal OK
            final long reconnectAt = intent.getLongExtra(EXTRA_RECONNECT_AT, 0);
            final PendingResult pr = goAsync();
            final LocalSocket s = new LocalSocket();
            final AtomicBoolean done = new AtomicBoolean(false);
            final java.util.function.Consumer<String> finish = r -> {
                if (done.compareAndSet(false, true)) { decide(ctx, r, reconnectAt); pr.finish(); }
            };

            final String[] got = new String[1];
            Thread worker = new Thread(() -> {
                try {
                    s.connect(new LocalSocketAddress(SOCKET, LocalSocketAddress.Namespace.RESERVED));
                    s.setSoTimeout(READ_CAP_MS); // the daemon replies OK at once; the seal runs in the background
                    OutputStream os = s.getOutputStream();
                    os.write(("BACKUP\n" + (reconnectAt > 0 ? "AFTER " + reconnectAt + "\n" : "")).getBytes("UTF-8"));
                    os.flush();
                    BufferedReader br = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
                    String reply = br.readLine();
                    android.util.Log.i("NowhereChooser", "BACKUP reply=" + reply);
                    got[0] = reply;
                } catch (Throwable t) {
                    android.util.Log.w("NowhereChooser", "BACKUP", t);
                } finally {
                    try { s.close(); } catch (Throwable ignore) {}
                    finish.accept(got[0]);
                }
            });
            worker.setDaemon(true);
            worker.start();

            Thread watchdog = new Thread(() -> {
                try { Thread.sleep(CONNECT_CAP_MS); } catch (InterruptedException ignore) {}
                if (!done.get()) {
                    android.util.Log.w("NowhereChooser", "BACKUP: daemon unresponsive, abandoning");
                    try { s.close(); } catch (Throwable ignore) {}
                    finish.accept(null);
                }
            });
            watchdog.setDaemon(true);
            watchdog.start();
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "BackupNowReceiver", t);
        }
    }
}
