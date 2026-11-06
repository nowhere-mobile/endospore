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
 * #97 -- the reconnect notice's "Load my saved data" action. Runs IN THE ROAMED USER (the notification is
 * posted into that user's shade, so its action PendingIntent fires there); it sends one RELOGIN line to the
 * login daemon over the AF_UNIX socket -- the same roamed-user -> daemon path the idle cold-lock uses
 * (IdleLogoffReceiver). The daemon queues the session's creds in a one-shot RAM marker and runs the normal
 * no-seal local logoff (an offline session is LOCAL: the scratch user is destroyed, nothing is sealed over the
 * stored head); after the reap, the user-0 gate collects GET-RELOGIN and auto-runs the ONLINE login, restoring
 * the real profile. Not exported; only our own notification PendingIntent reaches it.
 *
 * Q068 (NWP-20261103-09): the daemon looks for a stored head under the session's name BEFORE it replies, so the tap
 * may keep the session (NOSTORED) or leave it untouched (ERR-STORE). The reply is classified by
 * {@link ReloginCopy#verdict}; the verdict word is logged and nothing else: no toast, no notification, so the session
 * is told no more than an online sign-in shows. KEPT is withdrawn by the gate's GET-OFFLINE watcher within one poll;
 * RETRY leaves the prompt for another tap.
 *
 * Bounded exactly like IdleLogoffReceiver: LocalSocket.connect has NO timeout, so a wedged daemon would hold
 * the broadcast to the 60s ANR and take down the persistent chooser process (#77) -- a watchdog closes the
 * socket and finishes the broadcast no matter what.
 */
public class ReloginReceiver extends BroadcastReceiver {
    private static final String SOCKET = "nowhere_login";
    // The daemon reads the store before it replies (Q068), so the read cap covers that check; the watchdog is the
    // outer bound over the #98 Wi-Fi capture (<=5s, own socket), the Doze capture, the connect and that read. Both
    // stay under the 60s background-broadcast limit (#77).
    private static final int CONNECT_CAP_MS = 40000;
    private static final int READ_CAP_MS = 30000;

    @Override
    public void onReceive(Context ctx, Intent intent) {
        try {
            android.util.Log.i("NowhereChooser", "relogin action tapped (the daemon checks for a stored profile first)");
            final PendingResult pr = goAsync();
            final LocalSocket s = new LocalSocket();
            final AtomicBoolean done = new AtomicBoolean(false);
            final Runnable finish = () -> { if (done.compareAndSet(false, true)) pr.finish(); };

            Thread worker = new Thread(() -> {
                String reply = null;
                try {
                    // #98: capture the session's Wi-Fi BEFORE queueing the logoff -- this receiver runs in the
                    // roamed user (profile owner), and the "Load my saved data" path never touches
                    // ProfileActivity, so without this the gate lands with no Wi-Fi and the auto-relogin parks
                    // on "Join Wi-Fi…" (Chester's build-262 repro). Bounded internally; best-effort.
                    WifiMirror.capture(ctx);
                    DozeAppsMirror.capture(ctx); // NWP-20261002-02: seal this profile's Doze-exempt apps (removes
                                                 // nothing, NWP-20261002-03), same BEFORE-the-logoff point as the
                                                 // Wi-Fi capture above. Kept: a promoted offline session can reach
                                                 // the daemon's SEALING logoff through RELOGIN.
                    s.connect(new LocalSocketAddress(SOCKET, LocalSocketAddress.Namespace.RESERVED));
                    s.setSoTimeout(READ_CAP_MS); // the daemon checks the store before it replies (Q068)
                    OutputStream os = s.getOutputStream();
                    os.write("RELOGIN\n".getBytes("UTF-8"));
                    os.flush();
                    BufferedReader br = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
                    reply = br.readLine();
                } catch (Throwable t) {
                    android.util.Log.w("NowhereChooser", "RELOGIN", t);
                } finally {
                    android.util.Log.i("NowhereChooser", "RELOGIN verdict=" + ReloginCopy.verdict(reply));
                    try { s.close(); } catch (Throwable ignore) {}
                    finish.run();
                }
            });
            worker.setDaemon(true);
            worker.start();

            Thread watchdog = new Thread(() -> {
                try { Thread.sleep(CONNECT_CAP_MS); } catch (InterruptedException ignore) {}
                if (!done.get()) {
                    android.util.Log.w("NowhereChooser", "RELOGIN: daemon unresponsive, abandoning");
                    try { s.close(); } catch (Throwable ignore) {}
                    finish.run();
                }
            });
            watchdog.setDaemon(true);
            watchdog.start();
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "relogin receiver", t);
        }
    }
}
