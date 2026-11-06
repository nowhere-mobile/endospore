package com.nowhere.chooser;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.os.IBinder;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * On-demand apps (#204): materialise-on-tap worker.
 *
 * {@link UnarchiveReceiver} (which handles ACTION_UNARCHIVE_PACKAGE in the roamed user) hands off to THIS
 * foreground service so the potentially-long fetch+install runs OUTSIDE the broadcast (a BroadcastReceiver that
 * blocked for a real download would ANR). The framework grants a temporary foreground-service-start allowlist on
 * the unarchive broadcast, so this hand-off is the sanctioned pattern.
 *
 * Runs in the ROAMED user (started from the roamed-user receiver): this Service's Context installs for THAT user,
 * the "nowhere_login" socket + reportUnarchivalStatus are user-scoped to it, and getFilesDir() is that user's
 * chooser files. It fetches the tapped package's DEFERRED APK bytes from name#apps (MATERIALIZE-APP -> su:s0
 * worker restore-app into .appcode/<pkg>), installs them over the placeholder (which COMPLETES the unarchival --
 * the OS observes ACTION_PACKAGE_ADDED), ALWAYS deletes the cleartext APK bytes afterward (amnesia), and reports
 * a failure via reportUnarchivalStatus so the OS dismisses its progress UI instead of hanging.
 *
 * Using the Service Context (not the receiver's ReceiverRestrictedContext) is deliberate: the install-status
 * BroadcastReceiver below MUST register on a non-restricted context or registerReceiver throws.
 */
public class UnarchiveService extends Service {
    static final String EXTRA_ID = "nowhere.unarchive.id";
    static final String EXTRA_PKG = "nowhere.unarchive.pkg";
    static final String EXTRA_SWEEP = "nowhere.unarchive.sweep"; // #130: auto-mode background-materialise sweep
    // NWP-20261117-40: sent at the end of sweepAuto, to this app only, with no extras. An open Your apps redraws on it.
    static final String ACTION_SWEEP_DONE = "com.nowhere.chooser.action.AUTO_SWEEP_DONE";
    // NWP-20261012-06: with EXTRA_SWEEP, the Keep-installed apps whose login restore the gate saw answer OK
    static final String EXTRA_WAKE = "nowhere.unarchive.wake";
    // NWP-20261112-11 (Q042): with EXTRA_SWEEP. BY_HAND: "Install pending apps now" -- the sweep runs on any network.
    static final String EXTRA_BY_HAND = "nowhere.unarchive.byhand";
    // NET_REKICK: the gate's re-kick when the network rule turns to yes mid-session -- only the sweep, nothing else.
    static final String EXTRA_NET_REKICK = "nowhere.unarchive.netrekick";

    /** #130: one materialise at a time, process-wide. The sweep and a user tap are separate start commands with
     *  separate worker threads, and racing two materialises of the same package (or two members of the same
     *  group) double-fetches and re-installs over a live app. The lock serializes at ITEM granularity -- a tap
     *  lands between sweep items -- and the already-materialised fast-path inside materializeAndInstall makes
     *  the loser of the race a cheap no-op instead of a re-download. */
    // NWP-20261005-13: FAIR, so "a tap lands between sweep items" is true. A plain monitor makes no ordering promise:
    // the sweep released it and re-took it straight away for its next app, so a tap could wait behind several sweep
    // items rather than one. A fair lock hands it to the longest waiter, and a releasing thread that asks again
    // queues behind it. Reentrant like the monitor it replaces.
    private static final java.util.concurrent.locks.ReentrantLock MAT_LOCK =
            new java.util.concurrent.locks.ReentrantLock(true);
    /** NWP-20261113-17: the SweepOutcome token of the exit that ended the last materializeAndInstall, so the Auto
     *  sweep can report where each app's call ended. Written and read under MAT_LOCK only: sweepAuto holds the lock
     *  across the call and the read, so a tap cannot overwrite it in between. */
    private static String matEnd = SweepOutcome.ERROR;
    /** NWP-20261118-05: the last materializeMember's MATERIALIZE-APP answered ERR-WORKER-BUSY, so the group's dep abort
     *  records BUSY, not FETCH_FAILED. Written and read under MAT_LOCK, like matEnd. */
    private static boolean depBusy;

    /** NWP-20260822-12: THE OUTSTANDING SET -- one queue, shared by every producer, that owns the notification.
     *
     *  Before this, each producer composed its own "(n of m)" from its OWN local loop and wrote them all to the
     *  one FG_ID notification and the one curTitle: the #130 auto sweep counted over the auto-keep set, a tap
     *  counted over its group's deps + entry point. MAT_LOCK serialized the WORK but nothing serialized the
     *  REPORTING, and neither side knew the other existed -- so the surface showed whichever sequence wrote
     *  last, with a denominator belonging to that sequence alone. Chester tapped AliExpress and was shown
     *  Notally, then "2 of 3" from a set Notally was never in (device-observed, 2026082105).
     *
     *  The three failures that fixes, only the first of which was reported:
     *    (a) a TAPPED app is invisible while it waits behind the other producer, so the tap reads as ignored --
     *        the one that makes a user tap twice, and the reason this is a queue rather than just a wider count;
     *    (b) the notification names an app the user never asked for;
     *    (c) "(n of m)" is not the number of apps coming, so "2 of 3" can be followed by a fourth.
     *
     *  Every producer ENQUEUES its whole set BEFORE doing any work, so the count is the union from the first
     *  frame and a queued app is named immediately. Q_DONE + Q_PENDING.size() is the honest total; the batch
     *  resets when the queue drains, so the next batch counts from 1 again rather than accumulating forever. */
    private static final Object Q_LOCK = new Object();
    private static final java.util.LinkedHashSet<String> Q_PENDING = new java.util.LinkedHashSet<>();
    private static int Q_DONE = 0;
    private static String Q_CURRENT = null;
    /** NWP-20261122-11 (h51 #1): the taps this process is serving now -- a tap worker's, or a remembered tap the sweep
     *  claimed. A tap in TapMemory's file but not here was queued by a chooser that has since restarted. */
    private static final java.util.Set<String> LIVE_TAPS =
            java.util.Collections.synchronizedSet(new java.util.HashSet<String>());
    /** NWP-20261126-07 (h50 #3): the apps whose fetched copy was older than their placeholder this session, so the
     *  sweep does not fetch them again. RAM only, in this session's chooser process; never written to disk. A process
     *  restart forgets it: the cost is one more download, refused again before the install. */
    static final java.util.Set<String> OLDER_COPY = java.util.concurrent.ConcurrentHashMap.newKeySet();

    /** #130 regression fix (DIA-20260813-12, device-proven on lynx 2026081212 within minutes of the flash): this
     *  is a MULTI-START service now -- a tap and the sweep are separate onStartCommand calls sharing ONE service
     *  instance and ONE foreground notification. Each worker used to call stopSelfSafely() when IT finished,
     *  which tore down the foreground state for EVERYONE: the sweep checked in 6s after Chester's Play Store
     *  tap, found nothing in auto mode, and its teardown removed the tap's download notification and dropped
     *  the service out of foreground while a 700MB group fetch was mid-flight ("i tapped play store but dont
     *  see any notifications" -- the download ran on, headless and killable). Refcount instead: every accepted
     *  start increments, every worker's finally decrements, and only the LAST worker out turns off the lights. */
    private static final java.util.concurrent.atomic.AtomicInteger ACTIVE = new java.util.concurrent.atomic.AtomicInteger(0);

    /** NWP-20261122-15 (h50 #5): true on the sweep thread of a switch-landing start, so sweepAuto may show the landing
     *  line. Set by that start only (never by a network re-kick); read and removed by sweepAuto. */
    private static final ThreadLocal<Boolean> LANDING = new ThreadLocal<>();

    /** NWP-20260901-32: hold the CPU up for the whole materialise.
     *
     *  ⚠ A FOREGROUND SERVICE DOES NOT KEEP THE CPU AWAKE. It stops the PROCESS being killed; it says nothing
     *  about device suspend. With the screen off and nothing else holding a wakelock, the phone deep-suspends
     *  and the fetch simply STOPS -- daemon, su:s0 worker and radio together. Nothing errors, nothing aborts,
     *  and the stall watchdog cannot fire because it is frozen too. On wake it resumes mid-stream.
     *
     *  That is exactly the reported symptom (Chester, frankel, 2026-09-01: "when the screen-off if something
     *  was materializing - it doesnt progresses forward", and decisively: "as soon as i wake up the phone it
     *  starts to move forward"). Resuming rather than failing is what rules out the two leads originally
     *  filed -- the stall watchdog and an FGS kill are both TERMINAL.
     *
     *  It also explains the two things that made it look mysterious: the INTERMITTENCE (whether the device
     *  actually suspends depends on what else holds a wakelock at the time) and WHY LYNX NEVER SHOWED IT
     *  (the dev device is usually adb-attached, and adb holds a wakelock).
     *
     *  Reference-counted to match ACTIVE exactly -- acquire per accepted start, release per finished worker,
     *  so a concurrent tap + sweep hold it once each and the last one out drops it. The timeout is a
     *  battery backstop above the daemon's own 20-minute fetch ceiling: a leaked lock costs one charge, and
     *  this runs on a phone whose owner may not notice for hours. */
    private static android.os.PowerManager.WakeLock sFetchWake;

    private void fetchWakeAcquire() {
        try {
            synchronized (UnarchiveService.class) {
                if (sFetchWake == null) {
                    android.os.PowerManager pm = getSystemService(android.os.PowerManager.class);
                    if (pm == null) return;
                    sFetchWake = pm.newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, "nowhere:appfetch");
                    sFetchWake.setReferenceCounted(true);
                }
                sFetchWake.acquire(25 * 60 * 1000L);
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "fetch wakelock acquire", t);
        }
    }

    private void fetchWakeRelease() {
        try {
            synchronized (UnarchiveService.class) {
                // isHeld guards the timeout race: an auto-released lock throws "under-locked" on release.
                if (sFetchWake != null && sFetchWake.isHeld()) sFetchWake.release();
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "fetch wakelock release", t);
        }
    }

    /** NWP-20261013-33: the status a failed materialise reports -- NO_CONNECTIVITY offline, else GENERIC_ERROR. */
    static int unarchivalErrorCode(boolean validatedNetwork) {
        return validatedNetwork ? PackageInstaller.UNARCHIVAL_GENERIC_ERROR
                                : PackageInstaller.UNARCHIVAL_ERROR_NO_CONNECTIVITY;
    }

    /** True when the active network is validated. A throw reads as online: the old GENERIC_ERROR behaviour. */
    static boolean hasValidatedNetwork(Context ctx) {
        try {
            android.net.ConnectivityManager cm = ctx.getSystemService(android.net.ConnectivityManager.class);
            android.net.Network n = cm.getActiveNetwork();
            android.net.NetworkCapabilities caps = n == null ? null : cm.getNetworkCapabilities(n);
            return caps != null && caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "hasValidatedNetwork", t);
            return true;
        }
    }

    private void workerDone() {
        fetchWakeRelease(); // NWP-20260901-32: paired with the acquire on the accepted start
        if (ACTIVE.decrementAndGet() <= 0) stopSelfSafely();
    }
    private static final String SOCKET = "nowhere_login";
    private static final String CHANNEL = "nowhere.appfetch";
    private static final int FG_ID = 0x0A2D; // stable FGS notification id
    // The daemon replies only AFTER the su:s0 worker fetches the APK set over the network + chowns it, so the
    // read cap must cover a real download, not a quick ACK.
    // DIA-20260803-03: this must NOT be the binding limit. The daemon already decides honestly when a fetch is
    // hung rather than merely slow -- it gives up only after 150s with NO progress, under a 20-minute ceiling --
    // and it always answers (ERR-TIMEOUT at worst), so whatever it concludes should reach us. A cap below its
    // ceiling just re-imposes the fixed deadline that broke big fetches: gms measured 200s on odtest4, right at
    // the old value. Sitting ABOVE the daemon's ceiling costs nothing in the failure cases -- a dead daemon
    // closes the socket (readLine returns immediately, not a timeout) -- and this runs on a worker thread behind
    // a progress notification, never on the UI thread.
    private static final int READ_CAP_MS = 1260000; // 21 min > the daemon's 20-min ceiling

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        final int unarchiveId = intent != null ? intent.getIntExtra(EXTRA_ID, -1) : -1;
        final String pkg = intent != null ? intent.getStringExtra(EXTRA_PKG) : null;
        final boolean sweep = intent != null && intent.getBooleanExtra(EXTRA_SWEEP, false);
        final boolean byHand = intent != null && intent.getBooleanExtra(EXTRA_BY_HAND, false);
        final boolean netRekick = intent != null && intent.getBooleanExtra(EXTRA_NET_REKICK, false);
        final String[] restoredOk = intent != null ? intent.getStringArrayExtra(EXTRA_WAKE) : null;
        startForegroundNotice(); // MUST be immediate (within the FGS start window), before any network work
        if (sweep) {
            // #130: the auto background-materialise sweep -- no tap, no unarchiveId, no card, no launch.
            ACTIVE.incrementAndGet();
            fetchWakeAcquire(); // NWP-20260901-32: paired with workerDone()
            Thread sw = new Thread(() -> {
                if (netRekick) {
                    // NWP-20261112-11 (Q042): the gate's re-kick once the network allows the sweep. Only the sweep:
                    // the presence snapshot, the held-list seed, the phantom reconcile and the restored wake belong to
                    // the switch-landing, and that start already ran them.
                    try { sweepAutoJoined(false); }
                    catch (Throwable t) { android.util.Log.w("NowhereChooser", "#130 auto sweep (re-kick)", t); }
                    finally { workerDone(); }
                    return;
                }
                LANDING.set(!byHand);
                // NWP-20260821-15: take the SESSION-PRESENCE SNAPSHOT first -- before the sweep materialises
                // anything, and regardless of whether there is anything to sweep. This kick is the one thing that
                // fires on EVERY login/resume switch-landing (kickAutoMaterialise, ~15s after the switch, after
                // login I/O and the PIN arm), and sweepAuto's own "nothing to materialise" early-return happens
                // INSIDE it -- so this is the only spot that reliably observes a settled session for every
                // profile, not just profiles that happen to keep auto-mode apps.
                //
                // Recording it BEFORE the sweep is deliberate: the snapshot must mean "the session had these",
                // not "the sweep raised these". By now provisioning has raised this login's archived
                // placeholders, so an on-demand app counts as present and can never be mistaken at logoff for one
                // the user removed. If a raise is still in flight the app is simply missing from the receipt,
                // which makes it ineligible for the prune -- costing a fix, never an app.
                try { StoreInstaller.snapshotAppSeen(this, ProfileActivity.keepSetPresentNow(this)); }
                catch (Throwable t) { android.util.Log.w("NowhereChooser", "appseen snapshot", t); }
                // NWP-20260912-06: seed the held list here, because this is the one thing that fires on EVERY
                // login/resume switch-landing. Without it a session starts with NO list at all, and the first
                // refresh waits on roamd’s post-seal kick -- which is itself gated on a bare-vault push having
                // written $CLAIMSOUT, so a session whose first vault push is refused would never seed.
                //
                // ⚠ It does NOT make the first seal publish this session’s apps, and an earlier version of
                // this comment claimed it did. roamd reads the held list before the pushes, so the earliest a
                // seal can publish what the seed recorded is the cycle AFTER it.
                try { AppHeld.refresh(this); }
                catch (Throwable t) { android.util.Log.w("NowhereChooser", "appheld seed", t); }
                // NWP-20260904-07: and, with the placeholders raised, reconcile keep lines whose app is gone
                // from PM AND has no code in the store. Own daemon thread: it may wait up to ~30 s for the
                // #apps head to be measured, and that must delay neither the sweep nor the service lifetime --
                // which is also why it gets the APPLICATION context: this service may well have stopped by then.
                try {
                    final android.content.Context app = getApplicationContext();
                    Thread rc = new Thread(() -> ProfileActivity.reconcilePhantomKeepLines(app), "nowhere-phantom-reconcile");
                    rc.setDaemon(true);
                    rc.start();
                } catch (Throwable t) { android.util.Log.w("NowhereChooser", "phantom reconcile start", t); }
                try { wakeRestored(restoredOk); }
                catch (Throwable t) { android.util.Log.w("NowhereChooser", "wake restored", t); }
                try { sweepAutoJoined(byHand); }
                catch (Throwable t) { android.util.Log.w("NowhereChooser", "#130 auto sweep", t); }
                finally { workerDone(); }
            });
            sw.setDaemon(true);
            sw.start();
            return START_NOT_STICKY;
        }
        // A degenerate start (no pkg, not a sweep) must only turn off the lights when NOBODY is working --
        // stopping unconditionally here has the same clobber shape the -12 refcount exists to prevent.
        if (pkg == null || pkg.isEmpty()) { if (ACTIVE.get() == 0) stopSelfSafely(); return START_NOT_STICKY; }
        ACTIVE.incrementAndGet();
        fetchWakeAcquire(); // NWP-20260901-32: paired with workerDone()
        Thread worker = new Thread(() -> {
            boolean ok = false;
            // NWP-20261122-11 (h51 #1): the tap is remembered in the session until its install ends, so a chooser
            // restart while it waits behind the sweep does not drop it. The tap itself always goes on.
            long s = -1;
            try { s = getSystemService(android.os.UserManager.class).getSerialNumberForUser(android.os.Process.myUserHandle()); }
            catch (Throwable t) { android.util.Log.w("NowhereChooser", "tap memory: no user serial", t); }
            final long tapSerial = s;
            final java.io.File tapFile = TapMemory.file(getFilesDir());
            final boolean mine = LIVE_TAPS.add(pkg);
            try {
                if (!TapMemory.add(tapFile, tapSerial, pkg)) android.util.Log.w("NowhereChooser", "tap memory add failed (NWP-20261122-11)");
                // NWP-20260822-12: enqueue BEFORE materializeAndInstall, i.e. before MAT_LOCK. This is the whole
                // point of the queue and it is easy to get wrong: enqueueing inside the lock would leave a tapped
                // app invisible for exactly as long as it waits behind the #130 sweep -- the interval where the
                // user sees another app's name, concludes the tap missed, and taps again. Its group's remaining
                // members join once materializeLocked resolves them, so the total GROWS from 1 as deps are
                // discovered; that is honest (work genuinely found later) and strictly better than a total that
                // omits the app the user actually asked for. Resolving deps here instead would double-filter
                // against state the sweep can change underneath us, and any dep the second filter dropped would
                // sit in the queue forever with nothing to retire it.
                qEnqueue(java.util.Collections.singletonList(pkg));
                ok = materializeAndInstall(pkg, false);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "unarchive " + pkg, t);
            } finally {
                // NWP-20261122-11: the install ended, whether it worked or failed: forget the tap.
                if (!TapMemory.remove(tapFile, tapSerial, pkg)) android.util.Log.w("NowhereChooser", "tap memory remove failed (NWP-20261122-11)");
                if (mine) LIVE_TAPS.remove(pkg);
                if (!ok && unarchiveId >= 0) {
                    try {
                        // NWP-20261013-33: with no validated network say so, and the platform renders its own
                        // "connect to the internet" dialog instead of a silent failure. Any non-OK status other than
                        // USER_ACTION_NEEDED also returns the icon to its archived state, so the next tap retries
                        // (as GENERIC_ERROR does; to be confirmed on the device).
                        getPackageManager().getPackageInstaller().reportUnarchivalStatus(
                                unarchiveId, unarchivalErrorCode(hasValidatedNetwork(this)), 0, null);
                    } catch (Throwable t) {
                        android.util.Log.w("NowhereChooser", "reportUnarchivalStatus", t);
                    }
                }
                // #204: drop the "Getting <app> ready…" screen. On success the real app has already launched OVER it
                // (materializeAndInstall -> launchApp); on failure nothing opens, so just clear it.
                MaterializingActivity.dismiss();
                workerDone(); // -12: only the LAST worker (tap or sweep) tears down the shared foreground state
            }
        });
        worker.setDaemon(true);
        worker.start();
        return START_NOT_STICKY;
    }

    private void startForegroundNotice() {
        try {
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm != null) {
                NotificationChannel ch = new NotificationChannel(
                        CHANNEL, "App downloads", NotificationManager.IMPORTANCE_LOW);
                ch.setDescription("Downloading an on-demand app you opened");
                nm.createNotificationChannel(ch);
            }
            // NWP-20260901-04: this is the THIRD writer of FG_ID, and it fires on EVERY onStartCommand -- so a
            // second tap during a live download re-posted the generic "Getting your app" / "Downloading…" over
            // a notification that was naming a real app with real byte figures, throwing both away. It must
            // still be immediate and unconditional (the FGS start window), so it re-states what is already on
            // screen rather than skipping: title, byte line and determinate bar when a batch is already running.
            String bPkg;
            synchronized (Q_LOCK) { bPkg = Q_CURRENT; }
            long[] bt = ACTIVE.get() > 0 ? bytesFor(bPkg) : null;
            CharSequence t = ACTIVE.get() > 0 ? curTitle : "Getting your app";
            Notification.Builder nb = new Notification.Builder(this, CHANNEL)
                    .setSmallIcon(android.R.drawable.stat_sys_download)
                    .setContentTitle(t)
                    .setOngoing(true)
                    .setShowWhen(false);
            if (bt != null) {
                String bytes = fmtB(bt[0]) + " of " + fmtB(bt[1]);
                nb.setContentText(bytes).setProgress(1000, (int) (bt[0] * 1000 / bt[1]), false);
                applyRoster(nb, t, bytes);
            } else {
                nb.setContentText(ACTIVE.get() > 0 ? null : "Downloading…")
                  .setProgress(0, 0, true); // indeterminate until materializeAndInstall knows the item count
                applyRoster(nb, t, null);
            }
            startForeground(FG_ID, nb.build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "startForeground unarchive", t);
        }
    }

    /** The current notification title -- "Downloading <app> (n of m)…" -- set at each member's start, reused by
     *  the byte-progress frames so the position framing survives while the bar moves. (#84, Chester's spec:
     *  "it should still say installing 0 out of 3 ... but the progress bar should show exactly where the
     *  install is for the 1st app".) */
    private volatile CharSequence curTitle = "Downloading…";

    /** NWP-20260901-04 (found reviewing the first cut of this slice): the LAST byte frame, KEYED TO THE PACKAGE
     *  IT DESCRIBES.
     *
     *  `nm.notify(FG_ID, …)` replaces the notification WHOLESALE -- there is no per-field merge -- so every
     *  writer must re-supply everything it wants kept. Fixing only `updateNoticeBytes` fixed one of THREE
     *  writers: `updateNotice` (the queue renderer) and `startForegroundNotice` both re-posted with no byte text
     *  and an indeterminate bar, blanking the very figures this slice exists to protect.
     *
     *  ⚠ THAT IS A NORMAL PATH, NOT A CORNER. Two `qEnqueue` call sites run deliberately OUTSIDE `MAT_LOCK`
     *  while another member is downloading (the tap worker and `sweepAuto`), so a second tap during a big fetch
     *  hits it every time. While bytes are flowing the blank lasts only until the next frame, but once the
     *  member reaches `updateNoticePhase("Installing")` NOTHING re-posts -- `installApks` has no progress stream
     *  -- so it lasts the whole dexopt window, "tens of seconds for a big app" by this file's own reckoning.
     *
     *  ⚠ KEYED, NOT MERELY CLEARED AT qStart. Between `qFinish(A)` and `qStart(B)` the renderer ALREADY names B
     *  (renderQueue's `Q_CURRENT == null` fallback picks the first pending), so a cache cleared only at qStart
     *  would print A's byte figures under B's name. That is worse than the bug being fixed: a blank line is
     *  visibly missing, whereas wrong numbers under the right name look entirely correct. */
    private volatile String bytesPkg = null;
    private volatile long bytesDone = 0, bytesTotal = 0;

    /** {done, total} iff the cached frame belongs to <pkg> and is renderable; null otherwise.
     *
     *  The re-read of bytesPkg at the end is the point of the method: reading pkg, then done/total, lets a frame
     *  for a DIFFERENT package land in between and hand back its numbers under this package's name. Re-checking
     *  turns that race into a skipped tick -- the next frame or queue mutation repaints a few hundred ms later,
     *  which nobody can see, and no reader is ever shown another app's bytes. */
    private long[] bytesFor(String pkg) {
        if (pkg == null) return null;
        String bp = bytesPkg;
        long d = bytesDone, t = bytesTotal;
        if (bp == null || !bp.equals(pkg) || bytesPkg != bp) return null;
        if (t <= 0 || d < 0 || d > t) return null;
        return new long[] { d, t };
    }

    /** NWP-20260901-04 (review): the phase verb, so a queue mutation cannot silently revert it.
     *
     *  `renderQueue` recomposes the title from scratch with a hardcoded "Downloading "/"Waiting for ", so an
     *  enqueue arriving during dexopt turned "Installing Ring (2 of 3)…" back into "Downloading Ring (2 of 4)…"
     *  -- mislabelling the exact beat that DIA-20260813-16's verb swap exists to name, with no self-heal until
     *  the next member boundary. Set by updateNoticePhase, cleared when a new member starts. */
    private volatile String curVerb = null;

    /** NWP-20260822-12: add a producer's whole set to the outstanding queue and render it at once. Called
     *  BEFORE any work, which is the whole point -- it is what makes a tapped app visible while it waits behind
     *  the sweep. Already-queued and already-done members are ignored (LinkedHashSet), so a tap for something
     *  the sweep is already carrying does not double-count it. */
    private void qEnqueue(java.util.List<String> pkgs) {
        if (pkgs == null || pkgs.isEmpty()) return;
        synchronized (Q_LOCK) { Q_PENDING.addAll(pkgs); }
        renderQueue();
    }

    /** This member is now actually running -- it becomes the named one. */
    private void qStart(String pkg) {
        // NWP-20260901-04: a new member owns the surface -- drop the previous one's byte frame and phase verb.
        // Clearing the KEY first is what makes the cache safe to read concurrently (see bytesFor).
        bytesPkg = null; bytesDone = 0; bytesTotal = 0; curVerb = null;
        synchronized (Q_LOCK) { Q_PENDING.add(pkg); Q_CURRENT = pkg; }
        renderQueue();
    }

    /** This member is finished (installed, already-whole, or failed -- all three leave the queue, or the
     *  denominator would stall at a number that never comes down). */
    private void qFinish(String pkg) {
        synchronized (Q_LOCK) {
            if (Q_PENDING.remove(pkg)) Q_DONE++;
            if (pkg != null && pkg.equals(Q_CURRENT)) Q_CURRENT = null;
            if (Q_PENDING.isEmpty()) Q_DONE = 0; // batch drained -> the next one counts from 1
        }
        renderQueue();
    }

    /** Abandon members that will never run -- the fail-fast abort drops the rest of a group. Without this the
     *  total keeps counting apps that are not coming, which is failure (c) in a different disguise. */
    private void qDrop(java.util.Collection<String> pkgs) {
        if (pkgs == null || pkgs.isEmpty()) return;
        synchronized (Q_LOCK) {
            for (String p : pkgs) Q_PENDING.remove(p);
            if (Q_PENDING.isEmpty()) Q_DONE = 0;
        }
        renderQueue();
    }

    /** Compose the title (and the expanded roster) from the QUEUE rather than from any one caller's loop.
     *  The collapsed line keeps the "(n of m)" position the byte frames reuse; the expanded view lists what is
     *  still coming BY NAME, which is the literal thing that was missing -- a user with two producers running
     *  could not see both. */
    private void renderQueue() {
        final String cur;
        final int pos, total;
        final java.util.List<String> rest = new ArrayList<>();
        synchronized (Q_LOCK) {
            total = Q_DONE + Q_PENDING.size();
            pos = Math.min(Q_DONE + 1, Math.max(total, 1));
            String c = Q_CURRENT;
            if (c == null) { for (String p : Q_PENDING) { c = p; break; } }
            cur = c;
            for (String p : Q_PENDING) if (!p.equals(cur)) rest.add(p);
        }
        if (cur == null) return; // nothing outstanding; the finishing worker tears the notice down
        // NWP-20260901-04: honour a phase verb already in effect ("Installing", "Setting up") instead of
        // recomposing the title back to "Downloading". Only the CURRENT member's verb applies -- qStart clears
        // it -- so a queue mutation can never carry a previous member's beat onto a new name.
        String cv = curVerb;
        String verb = cv != null ? cv + " " : (Q_CURRENT == null ? "Waiting for " : "Downloading ");
        curTitle = verb + friendlyName(cur) + (total > 1 ? " (" + pos + " of " + total + ")" : "") + "…";
        queueRoster = rest;
        updateNotice(curTitle, cur);
    }

    /** The names still outstanding behind the current one, for the expanded notification. */
    private volatile java.util.List<String> queueRoster = new ArrayList<>();

    /** "Also coming: Notally, AliExpress" -- empty when the current member is the only one left. */
    private CharSequence rosterText() {
        java.util.List<String> r = queueRoster;
        if (r == null || r.isEmpty()) return null;
        StringBuilder sb = new StringBuilder("Also coming: ");
        for (int i = 0; i < r.size(); i++) {
            if (i > 0) sb.append(", ");
            sb.append(friendlyName(r.get(i)));
        }
        return sb;
    }

    /** Update the FGS notification at a MEMBER BOUNDARY: the title carries the "(n of m)" position, the bar
     *  spins (indeterminate) -- honest for the stretch where the op is QUEUED behind the daemon's worker (can be
     *  minutes behind a seal round) and no bytes are moving yet. The moment the daemon's PROG stream delivers
     *  the first byte frame, updateNoticeBytes flips the bar determinate. Re-notifying FG_ID updates the same
     *  notification startForeground posted. Best-effort. */
    private void updateNotice(CharSequence title, String pkg) {
        curTitle = title;
        try {
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm == null) return;
            // NWP-20260901-04: CARRY the current member's byte frame if one exists. This method runs on every
            // queue mutation, NOT only at a member boundary -- two qEnqueue sites fire while a member is
            // downloading -- and a notify() replaces the notification wholesale, so without this a second tap
            // blanked the size and reset the bar. Null during the genuine boundaries (first frame not yet in,
            // or a phase beat that cleared it), which is where the indeterminate bar is the honest answer.
            long[] bt = bytesFor(pkg);
            String bytes = bt != null ? fmtB(bt[0]) + " of " + fmtB(bt[1]) : null;
            Notification.Builder b = new Notification.Builder(this, CHANNEL)
                    .setSmallIcon(android.R.drawable.stat_sys_download)
                    .setContentTitle(title).setOngoing(true).setShowWhen(false);
            if (bt != null) {
                b.setContentText(bytes).setProgress(1000, (int) (bt[0] * 1000 / bt[1]), false);
            } else {
                b.setProgress(0, 0, true);
            }
            applyRoster(b, title, bytes);
            nm.notify(FG_ID, b.build());
        } catch (Throwable ignore) {}
    }

    /** NWP-20260822-12: hang the outstanding roster off the EXPANDED view. The collapsed line is left alone --
     *  its contentText is where the byte figures live (#84) and they must not be displaced -- so this adds the
     *  "what else is coming" answer without taking away the "how far is this one" answer.
     *
     *  NWP-20260901-04: that reasoning was right about the COLLAPSED line and wrong about the EXPANDED one, and
     *  the expanded one is where a user watching a download actually looks. BigTextStyle's bigText REPLACES the
     *  text area of the expanded view -- it does not append to contentText -- so a roster-only bigText displaced
     *  the very byte figures the comment above set out to protect.
     *
     *  THE EVIDENCE FOR THAT PLATFORM CLAIM, since asserting it bare is exactly what the -12 comment did: this
     *  tree already depends on it in shipped, device-proven code. ChooserActivity.postMediaNotice builds
     *  `bigText(body + "\n\n" + advisory)` -- it DUPLICATES its body line into bigText rather than relying on
     *  contentText showing alongside, and its byte figures do survive expansion in the field.
     *
     *  Chester reported (2026-09-01) that with several apps materialising, only the LAST one showed a download
     *  size. This is the LEADING EXPLANATION for that, not a confirmed observation of it: the last member is the
     *  only one whose rosterText() returns null, so it is the only one that gets no style and falls back to
     *  contentText -- which fits exactly. It is not instrumented, and a second reading survives (that he was
     *  watching the COLLAPSED line, where the blanking fixed below is the cause instead). Both are addressed;
     *  the device step in the PR is what promotes either from explanation to fact.
     *
     *  Fix: bigText carries BOTH, current line first. `bodyLine` is the body text the CALLER is posting -- the
     *  byte figures during a download -- or null for the beats that deliberately post none.
     */
    private void applyRoster(Notification.Builder b, CharSequence title, CharSequence bodyLine) {
        CharSequence roster = rosterText();
        boolean hasBody = bodyLine != null && bodyLine.length() > 0;
        // Nothing to add: no roster, and the caller posted no body text. Leave the default style rather than
        // style an empty string -- there is nothing here for an expanded view to show either way.
        if (roster == null && !hasBody) return;
        CharSequence big = roster == null ? bodyLine
                : hasBody ? new StringBuilder(bodyLine).append('\n').append(roster)
                : roster;
        try {
            b.setStyle(new Notification.BigTextStyle().setBigContentTitle(title).bigText(big));
        } catch (Throwable ignore) {}
    }

    /** #84 (DIA-20260813-15): DURING a member -- a determinate bar + byte text from the daemon's streamed
     *  "PROG" frames (restoreAppCode's per-chunk writeProg, real bytes). The title keeps the member's
     *  "(n of m)" position; the bar and "12 MB of 402 MB" line are exactly where THIS app's download is. */
    private void updateNoticeBytes(String pkg, long doneB, long totalB) {
        if (totalB <= 0) return;
        // NWP-20260901-04: publish the frame for the OTHER writers to carry. The KEY is written LAST so a
        // concurrent reader that sees the new package also sees its numbers, never the previous package's.
        bytesDone = doneB; bytesTotal = totalB; bytesPkg = pkg;
        try {
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm == null) return;
            int max = (int) Math.min(Integer.MAX_VALUE, totalB / 1024); // KB units keep a 2GB APK inside int
            int cur = (int) Math.min((long) max, doneB / 1024);
            // NWP-20260901-04: the byte line goes to BOTH views -- contentText for the collapsed one, and
            // through applyRoster into bigText for the expanded one, where the roster used to displace it.
            String bytes = fmtB(doneB) + " of " + fmtB(totalB);
            CharSequence t = curTitle; // read the volatile ONCE: the two views must not name different positions
            Notification.Builder b = new Notification.Builder(this, CHANNEL)
                    .setSmallIcon(android.R.drawable.stat_sys_download)
                    .setContentTitle(t).setOngoing(true).setShowWhen(false)
                    .setContentText(bytes)
                    .setProgress(max, cur, false);
            applyRoster(b, t, bytes);
            nm.notify(FG_ID, b.build());
        } catch (Throwable ignore) {}
    }

    /** #84 follow-up (DIA-20260813-16): the post-download beats -- PackageInstaller session write, the PM
     *  commit (dexopt: tens of seconds for a big app), and the data restore -- have NO byte feed, but they are
     *  long, and the bar used to sit FULL under a "Downloading" title for all of them, which reads as stuck
     *  (Chester: "during installation, feels like its stuck"). There is no honest progress to show for a PM
     *  commit, so don't fake one: swap the title's leading verb ("Installing <app> (n of m)…", then
     *  "Setting up <app> (n of m)…") and spin. Naming the phase is the #113 principle with no numbers. */
    private void updateNoticePhase(String verb) {
        String t = String.valueOf(curTitle).replaceFirst("^\\S+", verb);
        curTitle = t;
        // NWP-20260901-04: RETIRE the byte frame as we leave the download, and remember the verb.
        //   * clearing the frame is what keeps a concurrent queue mutation from re-showing a FULL determinate
        //     bar under "Installing" -- the exact "feels like its stuck" reading DIA-20260813-16 removed;
        //   * remembering the verb is what keeps that mutation from recomposing the title back to "Downloading".
        // Both are the same failure in different clothes: renderQueue rebuilds the notification from scratch.
        bytesPkg = null; bytesDone = 0; bytesTotal = 0;
        curVerb = verb;
        try {
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm == null) return;
            Notification.Builder b = new Notification.Builder(this, CHANNEL)
                    .setSmallIcon(android.R.drawable.stat_sys_download)
                    .setContentTitle(t).setOngoing(true).setShowWhen(false)
                    .setProgress(0, 0, true);
            // No honest number exists for a PM commit, so no body line -- the beat is named in the title.
            applyRoster(b, t, null);
            nm.notify(FG_ID, b.build());
        } catch (Throwable ignore) {}
    }

    /** Bytes -> one-unit human figure (mirrors ProfileActivity.fmtBytes; duplicated to keep this service
     *  free-standing): 862 KB, 4.2 MB, 145 MB, 1.3 GB. */
    private static String fmtB(long b) {
        if (b < 0) b = 0;
        if (b < 1024 * 1024) return Math.max(1, b / 1024) + " KB";
        double mb = b / (1024.0 * 1024.0);
        if (Math.round(mb * 10) < 100) return String.format(java.util.Locale.US, "%.1f MB", mb);
        if (Math.round(mb) < 1024) return Math.round(mb) + " MB";
        return String.format(java.util.Locale.US, "%.1f GB", mb / 1024.0);
    }

    /** A human name for a materialising package for the progress UI: the installed / archived label if resolvable,
     *  else a friendly name for the known launcher-less Play providers, else the package name. */
    private CharSequence friendlyName(String pkg) {
        try {
            android.content.pm.ApplicationInfo ai = getPackageManager().getApplicationInfo(pkg, 0);
            CharSequence l = getPackageManager().getApplicationLabel(ai);
            if (l != null && l.length() > 0) return l;
        } catch (Throwable ignore) {}
        CharSequence al = archivedLabel(pkg);
        if (al != null && al.length() > 0) return al;
        if ("com.google.android.gms".equals(pkg)) return "Play Services";
        if ("com.google.android.gsf".equals(pkg)) return "Google Services Framework";
        return pkg;
    }

    private void stopSelfSafely() {
        // NWP-20260822-12: the queue is STATIC (it must outlive individual start commands so a tap and the sweep
        // share one count), so it has to be reset when the last worker leaves -- otherwise anything still pending
        // when the service dies mid-work, e.g. a group abandoned by a crash rather than the fail-fast abort,
        // inflates the NEXT batch's denominator for the rest of the session. Only reached via workerDone() with
        // the refcount at zero, so there is no live worker whose member this could drop.
        synchronized (Q_LOCK) { Q_PENDING.clear(); Q_DONE = 0; Q_CURRENT = null; }
        try { stopForeground(Service.STOP_FOREGROUND_REMOVE); } catch (Throwable ignore) {}
        try { stopSelf(); } catch (Throwable ignore) {}
    }

    /** True iff pkg is present IN THIS USER with real code, i.e. already usable as a dependency.
     *
     *  flags=0 is deliberate and load-bearing: it matches NEITHER an archived placeholder NOR another user's
     *  copy, so both throw NameNotFoundException and count as not-installed. That is device-proven in this
     *  tree -- ProfileActivity's keptFlags exists precisely because "resolving with flags=0 threw
     *  NameNotFoundException for an archived pkg", and ReArchiveReceiver depends on the same throw.
     *  DO NOT widen these flags to match the kept-apps screens: an archived record that resolved would read
     *  as installed, every dep would be skipped, and the entry point would open on a dead stack with no
     *  failed dep for fail-fast to catch. The sourceDir test is belt-and-braces for any future build where
     *  the lookup starts resolving. Any lookup failure counts as not-installed, so the caller fetches --
     *  the safe direction, since a redundant fetch costs time while a wrongly skipped dep costs the stack. */
    private boolean hasInstalledCode(String pkg) { return hasInstalledCode(this, pkg); }
    /** NWP-20261005-02: static so pendingAutoApps (and through it the "Install pending apps" row) applies the SAME
     *  test as the sweep -- the warning above about widening the flags binds both. */
    static boolean hasInstalledCode(android.content.Context ctx, String pkg) {
        try {
            android.content.pm.ApplicationInfo ai = ctx.getPackageManager().getApplicationInfo(pkg, 0);
            return ai != null && ai.sourceDir != null && !ai.sourceDir.isEmpty();
        } catch (Throwable t) {
            return false;
        }
    }

    /** NWP-20261005-14: the apps woken after a sweep restore. Messaging, by what the package declares rather than a
     *  name list alone: a launcher activity in CATEGORY_APP_MESSAGING (the category Android's "messaging app" picker
     *  uses), or a handler for SENDTO smsto:/sms: (how an app offers itself to message a number). The list covers the
     *  common chat apps that declare neither. Any lookup failure means "not messaging": the cost of a miss is the
     *  pre-slice behaviour (silent until opened), and the cost of a false hit is running an app's code unasked. */
    private static final java.util.Set<String> KNOWN_MESSAGING = new java.util.HashSet<>(java.util.Arrays.asList(
            "com.whatsapp", "com.whatsapp.w4b", "org.thoughtcrime.securesms", "org.telegram.messenger",
            "org.telegram.messenger.web", "org.thunderdog.challegram", "com.facebook.orca", "com.discord",
            "com.Slack", "im.vector.app", "ch.threema.app", "ch.threema.app.libre", "com.wire",
            "network.loki.messenger", "com.viber.voip", "jp.naver.line.android", "com.kakao.talk",
            "com.tencent.mm", "com.google.android.apps.messaging",
            "com.microsoft.teams", "chat.simplex.app", "im.molly.app", "eu.siacs.conversations", "com.skype.raider"));

    static boolean isMessagingApp(android.content.Context ctx, String pkg) {
        if (KNOWN_MESSAGING.contains(pkg)) return true;
        try {
            android.content.pm.PackageManager pm = ctx.getPackageManager();
            Intent cat = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_APP_MESSAGING).setPackage(pkg);
            if (!pm.queryIntentActivities(cat, 0).isEmpty()) return true;
            for (String scheme : new String[] {"smsto", "sms"}) {
                Intent to = new Intent(Intent.ACTION_SENDTO, android.net.Uri.parse(scheme + ":0")).setPackage(pkg);
                if (!pm.queryIntentActivities(to, 0).isEmpty()) return true;
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "isMessagingApp " + pkg, t);
        }
        return false;
    }

    /** NWP-20261005-14: take pkg out of the stopped state in THIS user, so push messages reach it before it is
     *  opened. IPackageManager.setPackageStoppedState is hidden; the chooser holds the permission it checks
     *  (CHANGE_COMPONENT_ENABLED_STATE, granted -- frankel 0.5.42) and reaches hidden APIs by reflection elsewhere
     *  (GosState). It starts nothing: the app runs only when something is delivered to it. Read back from the public
     *  ApplicationInfo.FLAG_STOPPED and logged either way, so a build where this silently fails says so. */
    static void unstop(android.content.Context ctx, String pkg) {
        try {
            Object ipm = Class.forName("android.app.ActivityThread").getMethod("getPackageManager").invoke(null);
            int userId = (Integer) android.os.UserHandle.class.getMethod("myUserId").invoke(null);
            ipm.getClass().getMethod("setPackageStoppedState", String.class, boolean.class, int.class)
                    .invoke(ipm, pkg, false, userId);
            boolean stopped = (ctx.getPackageManager().getApplicationInfo(pkg, 0).flags
                    & android.content.pm.ApplicationInfo.FLAG_STOPPED) != 0;
            android.util.Log.i("NowhereChooser", "#130 sweep " + pkg + ": woken for notifications -> stopped=" + stopped
                    + " (NWP-20261005-14, NWP-20261012-06)");
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "#130 sweep " + pkg + ": wake failed (NWP-20261005-14)", t);
        }
    }

    /** NWP-20261012-06: whether a restored pkg is taken out of the stopped state -- the user's "Wake for
     *  notifications" choice in Your apps when there is one (nowhere-appwake), else the messaging rule above.
     *  ⚠ KNOWN RESIDUAL (not a decision): for an ARCHIVED placeholder the messaging rule can only use
     *  KNOWN_MESSAGING -- a placeholder has no activities or intent filters for PackageManager to query. So a
     *  not-yet-downloaded messaging app outside that list shows its Your apps check UNCHECKED, yet the sweep still
     *  wakes it after the install, because by then the full rule applies; once it is installed the row's default
     *  shows checked. Until then the check and the outcome disagree for that app. A tap on the check is kept and
     *  ends the disagreement. */
    static boolean wakeOnRestore(android.content.Context ctx, String pkg) {
        return KeepOrder.wakeFor(StoreInstaller.wakeOverrides(ctx), pkg, () -> isMessagingApp(ctx, pkg));
    }

    /** NWP-20261012-06: the Keep-installed half of the wake. The gate installs those apps at login, in user 0's
     *  process, and cannot read this profile's nowhere-appwake (it is in THIS user's files dir) -- so it hands over
     *  the packages whose RESTORE-ODDATA it saw answer OK, and they are woken here, in the roamed user, on the same
     *  rule and only after the same confirmed restore as the sweep's. An app already running (not stopped) is left
     *  alone; one with no code here (uninstalled since) is skipped. Every package handed over is first recorded in
     *  nowhere-installed-restored, so a later tap on its Your apps check knows its data is back too. */
    private void wakeRestored(String[] pkgs) {
        if (pkgs == null) return;
        for (String pkg : pkgs) {
            if (pkg == null || pkg.isEmpty()) continue;
            markInstalledRestored(this, pkg);
            if (!hasInstalledCode(this, pkg)) continue;
            try {
                boolean stopped = (getPackageManager().getApplicationInfo(pkg, 0).flags
                        & android.content.pm.ApplicationInfo.FLAG_STOPPED) != 0;
                if (stopped && wakeOnRestore(this, pkg)) unstop(this, pkg);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "wake restored " + pkg, t);
            }
        }
    }

    /** NWP-20261012-06: the Keep-installed twin of nowhere-od-restored -- the gate's login RESTORE-ODDATA for pkg
     *  answered OK THIS session. A separate file, deliberately: markOdRestored also tells SmsRoleRoam the app has
     *  materialised, which a Keep-installed restore must not. Like nowhere-od-restored it lives in the CE dir, so it
     *  would ride the seal into the next session; roamd removes it at roam-in beside that marker. */
    static final String INSTALLED_RESTORED = "nowhere-installed-restored";

    static void markInstalledRestored(android.content.Context ctx, String pkg) {
        if (installedRestored(ctx, pkg)) return;
        try (java.io.FileWriter w = new java.io.FileWriter(new File(ctx.getFilesDir(), INSTALLED_RESTORED), true)) {
            w.write(pkg + "\n");
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "markInstalledRestored " + pkg, t);
        }
    }

    static boolean installedRestored(android.content.Context ctx, String pkg) {
        try (java.io.BufferedReader br = new java.io.BufferedReader(
                new java.io.FileReader(new File(ctx.getFilesDir(), INSTALLED_RESTORED)))) {
            String l;
            while ((l = br.readLine()) != null) if (pkg.equals(l.trim())) return true;
        } catch (Throwable ignore) {}
        return false;
    }

    /** Record that pkg's RESTORE-ODDATA came back OK -- its held CE/DE data really moved back, and roamd ran
     *  grant_perms_for + keystore_register and, for the account member, wait_acct_authenticator + acct_reload
     *  + the checkin kick. Deliberately NOT the same state as nowhere-od-materialised, which is written
     *  BEFORE the restore round-trip and therefore records only the INSTALL. roamd clears this at roam-in
     *  alongside that marker, so it can never ride the seal into a new session and skip a fresh restore. */
    private void markOdRestored(String pkg) { markOdRestored(this, pkg); }
    /** NWP-20260903-11: static so AppInstallReceiver (the install-heal) records the same fact in the same
     *  file -- two writers of one marker must share one implementation or they will drift. */
    static void markOdRestored(android.content.Context ctx, String pkg) {
        try (java.io.FileWriter w = new java.io.FileWriter(new File(ctx.getFilesDir(), "nowhere-od-restored"), true)) {
            w.write(pkg + "\n");
        } catch (Throwable ignore) {}
        // NWP-20261010-13: the profile's SMS app may have been waiting for exactly this app to materialise.
        SmsRoleRoam.onMaterialised(ctx, pkg);
    }

    private boolean odRestored(String pkg) { return odRestored(this, pkg); }
    static boolean odRestored(android.content.Context ctx, String pkg) {
        try (java.io.BufferedReader br = new java.io.BufferedReader(
                new java.io.FileReader(new File(ctx.getFilesDir(), "nowhere-od-restored")))) {
            String l;
            while ((l = br.readLine()) != null) if (pkg.equals(l.trim())) return true;
        } catch (Throwable ignore) {}
        return false;
    }

    /** #204: the app's label read from the STILL-ARCHIVED package (the read-side inverse of installArchivedPlaceholder,
     *  same as "Your apps"). Must be called BEFORE installApks -- once installed, getArchivedPackage no longer resolves.
     *  Returns null on a miss (showMaterializing then uses generic wording). */
    private CharSequence archivedLabel(String pkg) {
        try {
            android.content.pm.ArchivedPackageInfo ai = getPackageManager().getArchivedPackage(pkg);
            if (ai != null && ai.getLauncherActivities() != null && !ai.getLauncherActivities().isEmpty())
                return ai.getLauncherActivities().get(0).getLabel();
        } catch (Throwable ignore) {}
        return null;
    }

    /** #204 (DIA-20260726-08): float a "Getting <app> ready…" screen over the launcher for the POST-INSTALL beat
     *  (data/perms restore + launch), so the stretch before the app opens doesn't read as "the app didn't open".
     *  Called AFTER installApks -- i.e. after the framework's unarchive is complete and its progress ring on the icon
     *  has gone away -- so the card NEVER overlaps the ring (the ring covers download + install; the card covers only
     *  what follows). The label is captured pre-install (getArchivedPackage stops resolving once installed). The
     *  unarchive broadcast grants this FGS a temporary activity-start allowlist, so the startActivity is permitted. */
    private void showMaterializing(CharSequence label) {
        try {
            Intent li = new Intent(this, MaterializingActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION);
            if (label != null && label.length() > 0) li.putExtra(MaterializingActivity.EXTRA_LABEL, label);
            startActivity(li);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "showMaterializing", t);
        }
    }

    /** #130: the auto background-materialise sweep. Works through the AUTO keep-set serially with the same
     *  materialise flow the tap uses (deps ride along inside materializeAndInstall), quiet: no card, no launch,
     *  no unarchival report. Per-item non-fatal -- one failed download must not stop the rest (unlike the
     *  fail-fast INSIDE a single materialise, which protects an entry point from installing over a broken dep
     *  stack). A pkg with neither a placeholder nor code is a launcher-less group dep (gms/gsf) -- it
     *  materialises with its entry point, never alone. Anything the sweep fails to land stays a plain
     *  placeholder: the tap flow remains as the user-facing fallback. */
    /** The AUTO apps a sweep still has to materialise: in the auto keep-set, with an archived placeholder and no
     *  code. NWP-20261012-04: an app that already HAS code is never in it, whoever installed it -- if its restore
     *  is unconfirmed it gets a restore-only retry instead (autoAction). NWP-20261005-02: ONE implementation, shared
     *  by the sweep and by "Your apps"' "Install pending apps now" row, so the row's count can never disagree with
     *  what a tap on it would actually do. `log` is the sweep's: the row asks quietly. Does PackageManager work --
     *  off the UI thread. */
    static java.util.List<String> pendingAutoApps(android.content.Context ctx, boolean log) {
        return pendingAutoApps(ctx, log, null);
    }

    /** NWP-20261012-04: as above, and when `restoreOnly` is non-null it collects the AUTO_RESTORE_ONLY apps -- the
     *  ones the sweep retries RESTORE-ODDATA for without fetching or installing anything. They are never in the
     *  returned list, so they never count toward the "Install pending apps now" row. */
    static java.util.List<String> pendingAutoApps(android.content.Context ctx, boolean log,
                                                  java.util.List<String> restoreOnly) {
        java.util.List<String> retry = new ArrayList<>(), groupDeps = new ArrayList<>();
        java.util.List<String> work = splitAuto(ProfileActivity.autoKeepSet(ctx),
                pkg -> hasInstalledCode(ctx, pkg),
                pkg -> odRestored(ctx, pkg),
                pkg -> {
                    try { return ctx.getPackageManager().getArchivedPackage(pkg) != null; } catch (Throwable t) { return false; }
                },
                retry, groupDeps);
        if (log) {
            for (String pkg : retry) android.util.Log.i("NowhereChooser", "#130 sweep: " + pkg + " is installed and its"
                    + " restore is unconfirmed -- restore-only retry, never a reinstall (NWP-20261012-04)");
            for (String pkg : groupDeps) android.util.Log.i("NowhereChooser", "#130 sweep: " + pkg
                    + " has no placeholder -- group dep, rides its entry point");
        }
        if (restoreOnly != null) restoreOnly.addAll(retry);
        // NWP-20261012-06: keep-set order IS the install order -- the user drags it in Your apps ("Download first",
        // NWP-20261005-13, is retired and folded into it: StoreInstaller.foldAppFirst).
        return work;
    }

    /** NWP-20261012-04: pendingAutoApps' split, pure so it runs off a device (core/chooser/tests/install-pending).
     *  Returns the apps to fetch and install, in input order; AUTO_RESTORE_ONLY apps go to `restoreOnly` and
     *  launcher-less group deps to `groupDeps`; whole apps go nowhere. The restored marker is read only for an app
     *  with code, and the placeholder only for one without -- autoAction ignores the other. */
    static java.util.List<String> splitAuto(Iterable<String> pkgs,
            java.util.function.Predicate<String> code, java.util.function.Predicate<String> restored,
            java.util.function.Predicate<String> placeholder,
            java.util.List<String> restoreOnly, java.util.List<String> groupDeps) {
        java.util.List<String> work = new java.util.ArrayList<>();
        for (String pkg : pkgs) {
            final boolean c = code.test(pkg);
            final int a = autoAction(c, c && restored.test(pkg), !c && placeholder.test(pkg));
            if (a == AUTO_INSTALL) work.add(pkg);
            else if (a == AUTO_RESTORE_ONLY) restoreOnly.add(pkg);
            else if (a == AUTO_GROUP_DEP) groupDeps.add(pkg);
        }
        return work;
    }

    /** NWP-20261012-04 (Chester, 2026-10-12: "installed an app from Appstore, when to your apps and clicked on install
     *  - its reinstalling it"): what an AUTO app, a tapped app or a group dep needs. ONE pure decision, shared by
     *  pendingAutoApps, materializeAndInstall and pendingDeps, so the row's count, the sweep and a tap cannot disagree.
     *
     *  The case it exists for is "has code, but no nowhere-od-restored marker". The marker goes missing whenever a
     *  RESTORE-ODDATA did not answer OK: a seal held the worker past the agent's 120 s connection, the chooser was not
     *  running when the app was installed, roamd answered ERR-NOTREADY by design (NWP-20260922-09), or an install of
     *  ours outlived installApks' wait. Until this slice every such app read as pending, and every sweep or tap
     *  downloaded our SEALED copy -- possibly older -- and installed it over the live one, without bound.
     *
     *  NO APP THAT HAS CODE IS EVER FETCHED OR INSTALLED AGAIN, whoever installed it -- the App store, Play, Aurora, a
     *  sideload, or our own materialise. It gets a RESTORE-ODDATA retry and nothing more. A reinstall could not help a
     *  restore anyway: our own materialise writes nowhere-od-materialised only after installApks reports success, so
     *  "ours, restore unconfirmed" always means the code is already there, and re-downloading it only repeats the
     *  install. There is also no INCOMPLETE install to repair: installApks commits base + every split in ONE
     *  PackageInstaller session, which applies all of them or none, and hasInstalledCode's flags=0 lookup throws for an
     *  archived placeholder, so "has code" is never a stub. This is what NWP-20260923-01 requires before odrestore's
     *  reply may go per-volume: a restore retry that does not re-download or re-install the APK.
     *
     *  ⚠ A restore that keeps failing is retried once per sweep (each login, resume, or "Install pending apps now"
     *  tap) and once per queued tap, and the user is not told -- the same visibility as before this slice. */
    static final int AUTO_WHOLE = 0;        // installed and restored: nothing to do
    static final int AUTO_INSTALL = 1;      // an archived placeholder: fetch + install the sealed copy, then restore
    static final int AUTO_RESTORE_ONLY = 2; // installed, restore unconfirmed: RESTORE-ODDATA only, never fetch or install
    static final int AUTO_GROUP_DEP = 3;    // no placeholder and no code: materialises with its entry point, never alone

    static int autoAction(boolean hasCode, boolean restored, boolean placeholder) {
        if (hasCode) return restored ? AUTO_WHOLE : AUTO_RESTORE_ONLY;
        return placeholder ? AUTO_INSTALL : AUTO_GROUP_DEP;
    }

    /** NWP-20261012-04: the restore-only retry for an app that already has code. RESTORE-ODDATA is the same verb
     *  the install-heal sends (AppInstallReceiver.heal): it hands back any parked hold and always re-runs the
     *  package's grants, and its no-hold answer is a clean "OK NOSRC". The marker is written only on OK, exactly as
     *  every other writer does, so an unconfirmed retry is retried again by the next sweep -- and never by a
     *  reinstall. Nothing is fetched and nothing is installed here. Caller holds MAT_LOCK. */
    private boolean restoreOnlyLocked(String pkg) {
        String rr = daemon("RESTORE-ODDATA\n" + pkg + "\n");
        return restoreOnlyReplied(pkg, rr);
    }

    /** NWP-20261128-16: what one app's restore-only reply does -- the marker on OK, the messaging wake, the log line.
     *  The one-name request (restoreOnlyLocked) and the list (restoreOnlyListLocked) both end here, so a list and a
     *  single request do exactly the same thing per app. rr null is no reply: no marker, the next sweep retries. */
    private boolean restoreOnlyReplied(String pkg, String rr) {
        boolean ok = rr != null && rr.startsWith("OK");
        if (ok) markOdRestored(pkg);
        // NWP-20261005-14, exactly as the materialise path does: odrestore force-stops an app whose hold it hands
        // back, and a stopped app gets no broadcast -- FCM included -- until something starts it, so wake a
        // MESSAGING app once its restore is CONFIRMED. A tap launches the app as well, which unstops it anyway.
        if (ok && wakeOnRestore(this, pkg)) unstop(this, pkg);
        android.util.Log.i("NowhereChooser", "RESTORE-ODDATA(restore-only) " + pkg + " -> " + rr
                + (ok ? "" : rr != null && rr.startsWith("ERR-NOTREADY")
                        ? " -- a hold was kept because the app's data dir is not owned by its uid; retrying the restore"
                          + " cannot change that, only a reinstall's installd recovery could (residual, never reinstalled)"
                        : " -- unconfirmed, the next sweep retries the restore (never a reinstall)")
                + " (NWP-20261012-04)");
        return ok;
    }

    /** NWP-20261128-16 (h53 #1): the restore-only retry for 2..OdRestoreList.CHUNK apps in ONE RESTORE-ODDATA request,
     *  so the daemon does its shared reads once and restores each app fully, with its own reply line, before the next.
     *  Each app is marked only on its own OK line; a cut reply or STOPPED is null: no marker, the next sweep retries.
     *  130 s is the per-read cap (SO_TIMEOUT applies to each line), above the daemon's 120 s window per package.
     *  A tail that throws is logged and the next app's tail still runs. Caller holds MAT_LOCK. */
    private void restoreOnlyListLocked(java.util.List<String> keep) {
        java.util.Map<String, String> replies =
                OdRestoreList.parse(DaemonSocket.roundTripLines(OdRestoreList.request(keep), 130000), keep);
        for (String pkg : keep) {
            try {
                restoreOnlyReplied(pkg, replies.get(pkg));
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "#130 sweep restore-only " + pkg, t);
            }
        }
    }

    /** NWP-20261126-04 (NW-91ed3c80d0c7): the one way into sweepAuto. A start that finds a sweep running in this
     *  process joins it (SweepJoin) and returns at once; the running sweep then makes one more pass, which reads a fresh
     *  pendingAutoApps list, so each app is processed once and the daemon sees one AUTO-SWEEP lease at a time. The
     *  landing flag is read here first and carried by the join; each pass sets it again for sweepAuto's own read. The
     *  catch is inside the loop and exit() is in the finally: a pass that throws must still end the join or run its
     *  rerun, or every later start in this process joins a sweep that never runs. */
    private void sweepAutoJoined(boolean byHand) {
        boolean landing = Boolean.TRUE.equals(LANDING.get());
        LANDING.remove();
        int flags = (byHand ? SweepJoin.BY_HAND : 0) | (landing ? SweepJoin.LANDING : 0);
        if (!SweepJoin.enter(flags)) {
            android.util.Log.i("NowhereChooser", "#130 sweep: joined the running sweep -- it runs once more when it ends (NWP-20261126-04)");
            return;
        }
        while (true) {
            LANDING.set((flags & SweepJoin.LANDING) != 0);
            int next;
            try { sweepAuto((flags & SweepJoin.BY_HAND) != 0); }
            catch (Throwable t) { android.util.Log.w("NowhereChooser", "#130 auto sweep", t); }
            finally { next = SweepJoin.exit(); }
            if (next < 0) return;
            android.util.Log.i("NowhereChooser", "#130 sweep: a start joined this sweep -- one more pass over a fresh list (NWP-20261126-04)");
            flags = next;
        }
    }

    private void sweepAuto(boolean byHand) {
        // NWP-20261126-02: re-arm the beta diagnostic reports at each landing (the agent's marker died with the last session).
        try { DiagReportJob.arm(this); }
        catch (Throwable t) { android.util.Log.w("NowhereChooser", "diag reports arm (NWP-20261126-02)", t); }
        final long sweepT0 = android.os.SystemClock.elapsedRealtime(); // NWP-20261126-12: the day summary's ms
        // NWP-20261122-11 (h51 #1): the taps a restarted chooser lost go first, before any Auto app and before the
        // Wi-Fi rule (a tap is the user's own request); installed, not opened. The fair MAT_LOCK still keeps a live tap
        // from cutting into the app the sweep is on.
        long tapSerial = -1;
        try { tapSerial = getSystemService(android.os.UserManager.class).getSerialNumberForUser(android.os.Process.myUserHandle()); }
        catch (Throwable t) { android.util.Log.w("NowhereChooser", "#130 sweep: no user serial for the remembered taps", t); }
        java.io.File tapFile = TapMemory.file(getFilesDir());
        java.util.Set<String> live;
        synchronized (LIVE_TAPS) { live = new java.util.HashSet<>(LIVE_TAPS); }
        java.util.List<String> remembered = TapMemory.afterRestart(TapMemory.read(tapFile, tapSerial), live);
        if (!remembered.isEmpty()) {
            android.util.Log.i("NowhereChooser", "#130 sweep: " + remembered.size() + " remembered tap(s) first (h51 #1)");
        }
        boolean tapLaneBusy = false; // the lane stayed busy past SweepBusy.BOUND_MS: the rest wait for the next sweep
        for (int k = 0; k < remembered.size() && !tapLaneBusy && !SignOutGate.begun(); k++) {
            String pkg = remembered.get(k);
            if (!LIVE_TAPS.add(pkg)) continue; // a live tap or another sweep serves it
            // ERR-WORKER-BUSY ran nothing (SweepBusy, NWP-20261118-05), so a busy end keeps the line for a later sweep.
            // Busy until the first call ends: a sign-out before it also keeps the line (the sign-out's clear removes it).
            String tapEnd = SweepOutcome.BUSY;
            int tapTries = 0;
            long tapWaited = 0;
            try {
                qEnqueue(java.util.Collections.singletonList(pkg));
                while (!SignOutGate.begun()) {
                    // NWP-20261113-17's rule: MAT_LOCK is held across the call and the read of matEnd.
                    MAT_LOCK.lock();
                    try {
                        materializeAndInstall(pkg, true);
                        tapEnd = matEnd;
                    } catch (Throwable t) {
                        tapEnd = SweepOutcome.ERROR;
                        android.util.Log.w("NowhereChooser", "#130 sweep: a remembered tap threw", t);
                    } finally {
                        MAT_LOCK.unlock();
                    }
                    SweepBusy.Step tapStep = SweepBusy.step(tapEnd, tapTries, tapWaited);
                    if (tapStep == SweepBusy.Step.STOP) tapLaneBusy = true;
                    if (tapStep != SweepBusy.Step.RETRY) break;
                    long w = SweepBusy.waitMs(tapTries);
                    tapTries++;
                    tapWaited += w;
                    android.util.Log.i("NowhereChooser", "#130 sweep: a remembered tap waits for a busy worker lane, retry "
                            + tapTries + " in " + (w / 1000) + " s");
                    long left = w;
                    while (left > 0 && !SignOutGate.begun()) {
                        try { Thread.sleep(Math.min(left, 1000L)); }
                        catch (InterruptedException ie) { Thread.currentThread().interrupt(); break; }
                        left -= 1000L;
                    }
                }
            } finally {
                if (SweepOutcome.BUSY.equals(tapEnd)) {
                    qDrop(java.util.Collections.singletonList(pkg)); // nothing ran; a no-op when the busy arm dropped it
                } else if (!TapMemory.remove(tapFile, tapSerial, pkg)) {
                    android.util.Log.w("NowhereChooser", "tap memory remove failed (NWP-20261122-11)");
                }
                LIVE_TAPS.remove(pkg);
            }
        }
        if (tapLaneBusy) {
            // The remembered taps go before EVERY Auto app (h51 #1), so a lane that stayed busy on one stops the whole
            // sweep: the busy tap and the rest keep their lines, and the next sweep runs them first again.
            android.util.Log.i("NowhereChooser", "#130 sweep: worker lane busy on a remembered tap -- the sweep stops,"
                    + " the remembered taps and the Auto apps wait for the next sweep (h51 #1)");
            return;
        }
        StoreInstaller.foldAppFirst(this); // NWP-20261012-06: before the order is read; a no-op once folded
        java.util.List<String> retry = new ArrayList<>();
        java.util.List<String> work = pendingAutoApps(this, true, retry);
        int pending = work.size(); // NWP-20261126-07 (h50 #3): an app whose stored copy was older is not fetched again
        if (work.removeAll(OLDER_COPY)) android.util.Log.i("NowhereChooser", "#130 sweep: " + (pending - work.size())
                + " app(s) with an older stored copy not fetched again this session (h50 #3)");
        // NWP-20261112-11 (Q042): the Auto sweep follows the profile's "Download over mobile data" switch, the media
        // prefetch's rule: off, it downloads on Wi-Fi only; "Install pending apps now" (byHand) runs on any network.
        // Only the downloads wait; the restore-only retries download nothing and still run. The gate re-kicks this
        // sweep when the network turns (ChooserActivity's backup watcher, AutoSweepNet.rekick).
        if (!work.isEmpty() && !AutoSweepNet.mayFetch(byHand,
                AutoSweepNet.meteredAllowed(daemon("GET-PREFETCH-METERED\n")),
                ChooserActivity.onWifiCtx(this), ChooserActivity.hasInternetCtx(this))) {
            android.util.Log.i("NowhereChooser", "#130 sweep: " + work.size() + " app(s) wait for Wi-Fi (Q042)");
            work.clear();
        }
        // NWP-20261122-15 (h50 #5): the switch-landing sweep with apps to fetch shows ONE dismissible line, once per
        // sign-in, keyed on the user serial. After the network gate, so a sign-in with no network or one waiting for
        // Wi-Fi shows nothing; before the early return, so the flag is removed on every path. The stamp is written
        // FIRST: a missed line is safe, a repeated one is not. A failure is logged and never stops the sweep.
        // NWP-20261126-05: the line is the checklist card, given the work list in sweep order (EXTRA_PKGS) and its
        // sweep's id in LandingLine.Sweep (EXTRA_SWEEP), where each outcome and the end are recorded before they are
        // broadcast, so a card that starts late or is recreated still reads them. 0: no card for this sweep.
        boolean landing = Boolean.TRUE.equals(LANDING.get());
        LANDING.remove();
        long card = 0;
        try {
            File stamp = new File(getNoBackupFilesDir(), "landing-line-shown");
            String serial = landingSerial();
            if (LandingLine.show(landing, work.size(), readLandingStamp(stamp), serial)) {
                StoreInstaller.writeAtomic(stamp, serial);
                card = LandingLine.Sweep.begin(work.toArray(new String[0]));
                startActivity(new Intent(this, LandingNoticeActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        .putExtra(LandingNoticeActivity.EXTRA_COUNT, work.size())
                        .putExtra(LandingNoticeActivity.EXTRA_PKGS, work.toArray(new String[0]))
                        .putExtra(LandingNoticeActivity.EXTRA_SWEEP, card));
            }
        } catch (Throwable t) { android.util.Log.w("NowhereChooser", "landing line", t); }
        // NWP-20261012-04: BOTH lists. A profile whose only outstanding app is an installed one with an unconfirmed
        // restore (Chester's App store case) has an empty work list, and returning on that alone never retries it.
        if (work.isEmpty() && retry.isEmpty()) { android.util.Log.i("NowhereChooser", "#130 sweep: nothing to materialise"); return; }
        // NWP-20260822-12: the sweep's whole set joins the SHARED queue up front. It no longer composes a count
        // over work.size() -- that denominator was invisible to a concurrent tap and vice versa.
        qEnqueue(work);
        int done = 0, failed = 0;
        // NWP-20261005-01: hold the periodic seal back for the WHOLE sweep, not just one app. RESTORE-ODDATA closes
        // the per-app window, and a seal that starts in the install gap before the next app holds the worker for up
        // to 47 minutes (frankel, NW-47c7b5845145: 16 of 24 apps in seven hours). The daemon caps the hold and lets
        // the lease lapse on its own if this process dies; the END is in a finally so a throw cannot leave it
        // waiting out the lease. Bounded calls (30 s): this is bookkeeping, never worth stalling the sweep for.
        String began = DaemonSocket.roundTrip("AUTO-SWEEP\n1\n", 30000);
        android.util.Log.i("NowhereChooser", "#130 sweep: " + work.size() + " app(s), " + retry.size()
                + " restore-only; seal hold -> " + (began.isEmpty() ? "<no answer>" : began));
        try {
            // NWP-20261012-04: installed apps whose restore is unconfirmed get it retried and nothing more. They are
            // not queued: the queue counts downloads, and these download nothing. First, because they are only daemon
            // round trips, and the seal hold above keeps a periodic seal from taking the worker out from under them.
            // NWP-20261128-16 (h53 #1): one RESTORE-ODDATA request carries up to OdRestoreList.CHUNK apps, so the
            // daemon's shared reads are done once per chunk; a chunk left with one app keeps the one-name request.
            // Same lock as a materialise, released between chunks so a tap waits behind at most one chunk, and the
            // decision is re-read under it, so a tap that landed meanwhile wins.
            for (int c = 0; c < retry.size(); c += OdRestoreList.CHUNK) {
                if (SignOutGate.begun()) break; // NWP-20261109-06 (Q116): a sign-out stops the sweep; never queued
                java.util.List<String> chunk = retry.subList(c, Math.min(c + OdRestoreList.CHUNK, retry.size()));
                MAT_LOCK.lock();
                try {
                    java.util.List<String> keep = new ArrayList<>();
                    for (String pkg : chunk) {
                        if (autoAction(hasInstalledCode(pkg), odRestored(pkg), false)
                                == AUTO_RESTORE_ONLY) keep.add(pkg);
                    }
                    if (keep.size() == 1) restoreOnlyLocked(keep.get(0));
                    else if (keep.size() > 1) restoreOnlyListLocked(keep);
                } catch (Throwable t) {
                    android.util.Log.w("NowhereChooser", "#130 sweep restore-only " + chunk, t);
                } finally {
                    MAT_LOCK.unlock();
                }
            }
            // NWP-20261118-05: this app's retries of a busy worker lane and their total wait; appT0 is when it started.
            int busyTries = 0;
            long busyWaited = 0, appT0 = 0;
            for (int i = 0; i < work.size(); i++) {
                if (SignOutGate.begun()) {
                    // NWP-20261109-06 (Q116): a sign-out stops the sweep before its next MATERIALIZE-APP, which would
                    // hold the daemon's session lock for the whole download with LOGOUT waiting behind it. The apps
                    // not started leave the shared queue; one already downloading is the daemon-side cancel's.
                    qDrop(SignOutGate.rest(work, i));
                    // NWP-20261113-17: ONE `stopped` line, for the app the stop did not start -- not one per app left.
                    String stop = SweepOutcome.request(i + 1, work.size(), SweepOutcome.STOPPED, 0);
                    if (stop != null) DaemonSocket.roundTrip(stop, 5000);
                    android.util.Log.i("NowhereChooser", "#130 sweep: stopped for a sign-out -- " + (work.size() - i)
                            + " app(s) not started (Q116)");
                    break;
                }
                String pkg = work.get(i);
                boolean ok = false;
                String end; // assigned in the try and in the catch: a catch that sets nothing does not compile
                if (busyTries == 0) appT0 = android.os.SystemClock.elapsedRealtime(); // the ms cover its retries too
                // NWP-20261113-17: MAT_LOCK is reentrant. Held across the call and the read of matEnd, so a tap cannot
                // overwrite matEnd in between.
                MAT_LOCK.lock();
                try { ok = materializeAndInstall(pkg, true); end = matEnd; }
                catch (Throwable t) { end = SweepOutcome.ERROR; android.util.Log.w("NowhereChooser", "#130 sweep " + pkg, t); }
                finally { MAT_LOCK.unlock(); }
                // NWP-20261118-05: a busy worker lane ran nothing, so the app has not failed. RETRY waits with MAT_LOCK
                // released (a tap can run), ends the wait at once for a sign-out, and takes the SAME app again; the top
                // of the loop re-checks the sign-out first. STOP (the wait bound passed) reports it busy, below.
                SweepBusy.Step step = SweepBusy.step(end, busyTries, busyWaited);
                if (step == SweepBusy.Step.RETRY) {
                    long w = SweepBusy.waitMs(busyTries);
                    busyTries++;
                    busyWaited += w;
                    android.util.Log.i("NowhereChooser", "#130 sweep " + pkg + ": worker lane busy, retry " + busyTries
                            + " in " + (w / 1000) + " s");
                    for (long left = w; left > 0 && !SignOutGate.begun(); left -= 1000L) {
                        try { Thread.sleep(Math.min(left, 1000L)); }
                        catch (InterruptedException ie) { Thread.currentThread().interrupt(); break; }
                    }
                    i--;
                    continue;
                }
                if (ok) done++; else if (step == SweepBusy.Step.NEXT) failed++;
                android.util.Log.i("NowhereChooser", "#130 sweep " + pkg + " -> " + ok);
                // NWP-20261113-17: the outcome to login.log (AUTO-SWEEP-APP), by index and token only -- never the
                // package. Sent after the unlock, so a slow reply never holds a tap back.
                String req = SweepOutcome.request(i + 1, work.size(), end, android.os.SystemClock.elapsedRealtime() - appT0);
                if (req != null) DaemonSocket.roundTrip(req, 5000);
                // NWP-20261126-05: the landing card ticks this app off (a failed app stays "coming back"). The package
                // rides this package-local broadcast only, never the daemon's request above. Recorded first (RF-002).
                LandingLine.Sweep.outcome(card, pkg, ok);
                try {
                    sendBroadcast(new Intent(LandingNoticeActivity.ACTION_APP).setPackage(getPackageName())
                            .putExtra(LandingNoticeActivity.EXTRA_PKG, pkg).putExtra(LandingNoticeActivity.EXTRA_OK, ok));
                } catch (Throwable t) { android.util.Log.w("NowhereChooser", "#130 sweep: tell the landing card", t); }
                long busyFor = busyWaited;
                busyTries = 0;
                busyWaited = 0;
                if (step == SweepBusy.Step.STOP) {
                    // NWP-20261118-05: the lane stayed busy past SweepBusy.BOUND_MS. This app and the rest keep their
                    // placeholders for the next sweep (sign-in, resume, the network re-kick, "Install pending apps now").
                    qDrop(SignOutGate.rest(work, i + 1));
                    android.util.Log.i("NowhereChooser", "#130 sweep: worker lane busy for " + (busyFor / 1000) + " s -- "
                            + (work.size() - i) + " app(s) left for the next sweep");
                    break;
                }
            }
        } finally {
            DaemonSocket.roundTrip("AUTO-SWEEP\n0\n", 30000);
        }
        android.util.Log.i("NowhereChooser", "#130 sweep done: " + done + "/" + work.size() + " materialised"
                + (failed > 0 ? " (" + failed + " failed -- tap still works)" : ""));
        LandingLine.Sweep.end(card); // NWP-20261126-05: recorded before the broadcast, as each outcome is
        try { sendBroadcast(new Intent(ACTION_SWEEP_DONE).setPackage(getPackageName())); } // NWP-20261117-40
        catch (Throwable t) { android.util.Log.w("NowhereChooser", "#130 sweep done: tell Your apps", t); }
        // NWP-20261126-12: the sweep's counts to the session's day summary (DIAG-EVENT, NWP-20261124-12). Numbers only;
        // the daemon keeps the line only while the session has opted in. An empty work list (a restore-only sweep, or
        // one that waits for Wi-Fi) sends nothing. Bounded (5 s), after the seal hold ends, never under MAT_LOCK.
        if (!work.isEmpty()) {
            String ev = DiagSweepEvent.arg(work.size(), done, failed, android.os.SystemClock.elapsedRealtime() - sweepT0);
            if (ev != null) {
                try {
                    String r = DaemonSocket.roundTrip("DIAG-EVENT\n" + ev + "\n", 5000);
                    if (!"OK".equals(r)) android.util.Log.w("NowhereChooser", "#130 sweep: day summary event -> "
                            + (r.isEmpty() ? "<no answer>" : r.split(" ", 2)[0]));
                } catch (Throwable t) { android.util.Log.w("NowhereChooser", "#130 sweep: day summary event", t); }
            }
        }
        // NWP-20261128-20 (h50 #3): this sweep's older copies are the members of work in OLDER_COPY (the head took out
        // every earlier one). Those Play installed, with Play Store on the profile, get one line. Its own notice: the
        // FG_ID notice is removed with the service (an inference). The count only, never a name.
        java.util.List<String> olderMetas = new ArrayList<>();
        for (String p : work) {
            if (!OLDER_COPY.contains(p)) continue;
            String t = null;
            try {
                t = new String(java.nio.file.Files.readAllBytes(new File(new File(new File(getFilesDir(),
                        "nowhere-appmeta"), p), "meta").toPath()), java.nio.charset.StandardCharsets.UTF_8);
            } catch (Throwable ignore) {}
            olderMetas.add(t);
        }
        if (!olderMetas.isEmpty()) {
            boolean play = false;
            try {
                play = getPackageManager().getPackageInfo(OlderCopy.PLAY,
                        PackageManager.PackageInfoFlags.of(PackageManager.MATCH_ARCHIVED_PACKAGES)) != null;
            } catch (Throwable ignore) {}
            int needPlay = OlderCopy.playCount(olderMetas.toArray(new String[0]), play);
            String line = OlderCopy.endLine(needPlay);
            if (line != null) {
                try {
                    NotificationManager nm = getSystemService(NotificationManager.class);
                    if (nm != null) {
                        Intent open = new Intent(this, ProfileActivity.class)
                                .putExtra(LandingLine.EXTRA_OPEN, LandingLine.OPEN_YOUR_APPS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                        android.app.PendingIntent pi = android.app.PendingIntent.getActivity(this, OlderCopy.NOTICE_ID,
                                open, android.app.PendingIntent.FLAG_IMMUTABLE | android.app.PendingIntent.FLAG_UPDATE_CURRENT);
                        nm.notify(OlderCopy.NOTICE_ID, new Notification.Builder(this, CHANNEL)
                                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                                .setContentTitle(line).setContentIntent(pi).setAutoCancel(true).build());
                    }
                    android.util.Log.i("NowhereChooser", "#130 sweep: " + needPlay
                            + " app(s) with an older stored copy need Play Store -- told once (h50 #3)");
                } catch (Throwable t) { android.util.Log.w("NowhereChooser", "#130 sweep: the Play Store line", t); }
            }
        }
    }

    /** NWP-20261122-15: this sign-in's key for the landing line, the Android user's serial (new at every sign-in,
     *  unchanged across a cold-lock resume). A negative serial or a failed read is null, and null shows nothing. */
    private String landingSerial() {
        try {
            long s = ((android.os.UserManager) getSystemService(Context.USER_SERVICE))
                    .getSerialNumberForUser(android.os.Process.myUserHandle());
            return s < 0 ? null : Long.toString(s);
        } catch (Throwable t) { return null; }
    }

    /** NWP-20261122-15: the serial the landing line was last shown for, or null when there is no readable stamp. */
    private static String readLandingStamp(File f) {
        if (!f.isFile()) return null;
        try {
            return new String(java.nio.file.Files.readAllBytes(f.toPath()), java.nio.charset.StandardCharsets.UTF_8).trim();
        } catch (Throwable t) { return null; }
    }

    /** MATERIALIZE-APP over the login socket, then install the fetched APK set. Returns true on install success
     *  (the OS completes the unarchival by observing the package install). The materialised bytes are ALWAYS
     *  deleted afterward, even on a timed-out/failed reply (amnesia + reclaim). `quiet` (#130, the auto sweep)
     *  suppresses the user-facing beats -- the "Getting ready" card, the launch, the reclaim arm -- and the
     *  whole call is serialized item-wise against every other materialise (MAT_LOCK), with a fast-path so the
     *  loser of a tap-vs-sweep race no-ops instead of re-downloading. */
    private boolean materializeAndInstall(String pkg, boolean quiet) {
        MAT_LOCK.lock();
        try {
            matEnd = SweepOutcome.ERROR; // NWP-20261113-17: an exit that records nothing reads `error`
            // placeholder=true: every caller holds one (a tap's unarchive) or a sweep work item, which pendingAutoApps
            // admitted only with a placeholder or code. It is only read when there is no code.
            final boolean code = hasInstalledCode(pkg);
            final int action = autoAction(code, code && odRestored(pkg), true);
            if (action == AUTO_WHOLE) {
                if (!quiet) launchApp(pkg); // the tap's app is already whole (the sweep landed it) -> just open it
                noteSeen(pkg);
                qFinish(pkg); // NWP-20260822-12: already-whole still leaves the queue, or the total never drains
                matEnd = SweepOutcome.ALREADY;
                return true;
            }
            if (action == AUTO_RESTORE_ONLY) {
                // NWP-20261012-04: it has code -- installed after this item was queued (the App store, Play, a
                // sideload, an earlier install of ours that outlived its wait). Never fetch or install over it: retry
                // its restore, and open it if this was a tap.
                restoreOnlyLocked(pkg);
                if (!quiet) launchApp(pkg);
                noteSeen(pkg);
                qFinish(pkg);
                matEnd = SweepOutcome.RESTORE_ONLY;
                return true;
            }
            boolean ok = materializeLocked(pkg, quiet);
            if (ok) noteSeen(pkg);
            // Success, failure and the fail-fast abort all retire the entry point. qDrop has already removed it
            // on the abort path; qFinish on an absent member is a no-op, so the double call is safe.
            qFinish(pkg);
            return ok;
        } finally {
            MAT_LOCK.unlock();
        }
    }

    /** NWP-20260821-15: add pkg to the session-presence receipt after we have positively seen it whole.
     *
     *  Mostly redundant with the snapshot the sweep worker takes -- an archived placeholder already counts as
     *  present there -- but it closes the gap where a placeholder is raised, or a group dep pulled in, AFTER that
     *  snapshot: without this such an app is missing from the receipt, so uninstalling it would leave its keep
     *  line in place and the roam would bring it back. Only ever ADDS a package we watched become installed, so
     *  it can enable a prune only under exactly the condition the prune is for. */
    private void noteSeen(String pkg) {
        try { StoreInstaller.noteAppSeen(this, pkg); }
        catch (Throwable t) { android.util.Log.w("NowhereChooser", "noteAppSeen " + pkg, t); }
    }

    private boolean materializeLocked(String pkg, boolean quiet) {
        // group-materialize (DIA-20260802): if the tapped package has on-demand DEPS -- the launcher-less members of
        // its sandboxed-play group (Play Store -> Play Services / GSF) OR the gms provider for a Play-Services client
        // (YouTube -> Play Services, DIA-20260802-13) -- bring them back FIRST, fully installed + data-restored +
        // account-reloaded (each dep's RESTORE-ODDATA -> odrestore fires the #sys reload + checkin for gms) so the
        // entry point finds Services on first launch. appDeps resolves them from the roamed nowhere-appkeep /
        // nowhere-playdeps and is empty for a plain app, so this is a no-op there. The entry point's own materialise
        // below is unchanged. A per-item progress notification (updateNotice) shows "Downloading <app> (n of m)"
        // across the whole set, since the framework's own unarchive ring on the icon times out during the long fetch.
        java.util.List<String> deps = new ArrayList<>();
        // DIA-20260804: drop deps that are ALREADY materialised. appDeps resolves from the roamed nowhere-appkeep /
        // nowhere-playdeps FILES, which record what the user opted into -- not what is currently installed -- so a
        // second tap in the same session re-listed the whole stack. Observed on lynx: tap Ring (pulls gms + vending,
        // opens fine), then tap YouTube -> "downloading 3" and gms re-fetched from the store even though it was
        // installed and RUNNING. That is not just the wasted minutes on a several-hundred-MB app: installApks
        // re-installs over the live, signed-in gms, which restarts it and re-runs the whole gap-process/keystore
        // dance the carry works hard to get right. Skipping is safe precisely BECAUSE the file is the opt-in record
        // -- a dep that is present with code needs nothing done to it, and one that is missing or is still an
        // APK-less archived placeholder (sourceDir empty) is not usable and must still be fetched.
        // Skipping requires BOTH halves of a materialise, not just the install. materializeMember returns the
        // installApks result and only LOGS the RESTORE-ODDATA reply, and installApks' 120s commit latch can time
        // out while PMS finishes the install anyway -- so "has an APK" genuinely does not imply "its data came
        // back". Before this filter existed, a later tap re-ran the member and got another shot at the restore;
        // keying the skip on the install alone would remove that self-heal permanently. For gms that is
        // unrecoverable within the session: roamd's odrestore is the ONLY site that clears acct-deferred-<uid>
        // and runs wait_acct_authenticator + acct_reload + the checkin kick, so a gms installed-but-not-restored
        // would leave the Google account gone with no tap left to retry.
        // NWP-20261012-04: that self-heal is kept WITHOUT the re-download and reinstall, for every dep with code
        // (ours or anyone's): it gets RESTORE-ODDATA again here -- the same verb, so gms still gets its account
        // reload -- and is not fetched.
        // An unconfirmed restore does not fail the group -- the dep's code is live, so the stack is not broken.
        java.util.List<String> depRestoreOnly = new ArrayList<>();
        deps.addAll(pendingDeps(pkg, depRestoreOnly));
        for (String dep : depRestoreOnly) restoreOnlyLocked(dep);
        // dn-1023 #5 (DECIDED 2026-10-24, docs/product-decisions.md; NWP-20261114-14): a TAP that is about to fetch a
        // Play-stack member shows the size and asks first. `quiet` (the #130 Auto sweep) is never asked: an app set to
        // Auto is not. The size is an ESTIMATE: a tap may install the catalog's newer entry point instead of the sealed
        // copy (Q050, the tap update below), while the Play-stack deps are always the sealed copy, so the question
        // says "About". A failed or slow size read shows the size-unknown line instead. NO and TIMEOUT return before
        // qEnqueue(group) and fetch nothing -- the same path as an abandoned dep: the worker reports the unarchival
        // error, the placeholder stays, the icon returns, and the next tap asks again.
        if (PlayFetchAsk.needsAsk(quiet, deps,
                d -> ProfileActivity.isStackMember(this, d) || ProfileActivity.GMS_PKG.equals(d))) {
            java.util.List<String> sized = new ArrayList<>(deps);
            sized.add(pkg);
            long bytes = PlayFetchAsk.parseSize(DaemonSocket.roundTrip(
                    "APP-FETCH-SIZE\n" + String.join(" ", sized) + "\n", PlayFetchAsk.SIZE_READ_MS));
            PlayFetchAsk.Reply a = PlayFetchAskActivity.ask(this, pkg, bytes, PlayFetchAsk.WAIT_MS);
            if (a != PlayFetchAsk.Reply.YES) {
                android.util.Log.i("NowhereChooser", "materialise of " + pkg + " not started: the Play-stack "
                        + "download was not confirmed (" + a + ") -- leaving the placeholder for a retry");
                // NWP-20261113-17: never reached from the Auto sweep (`quiet` is never asked); recorded as ERROR, the
                // token for an exit the sweep cannot name, so every exit of this method still records one.
                matEnd = SweepOutcome.ERROR;
                return false;
            }
        }
        // NWP-20260822-12: enqueue the WHOLE group -- deps and entry point -- BEFORE fetching any of it. That is
        // what makes a tapped app visible while it waits behind the #130 sweep, and what makes the denominator
        // the union of everything outstanding instead of this one loop's length. The per-member position and the
        // byte bar are unchanged (#84); only who owns the count moved.
        java.util.List<String> group = new ArrayList<>(deps);
        group.add(pkg);
        qEnqueue(group);
        for (String dep : deps) {
            qStart(dep);
            boolean dok = materializeMember(dep);
            android.util.Log.i("NowhereChooser", "app dep " + dep + " -> " + dok);
            // DIA-20260803-03: FAIL FAST. Installing the entry point when a dependency did not land leaves the user
            // with a real, launchable app on a BROKEN stack -- for a Play-Services client that is the "Get Google
            // Play Services" / "device not compatible" dead end, and it is WORSE than not installing, because
            // completing the unarchive consumes the archived placeholder: the tap that would retry the deps is gone
            // and only another roam can recover it. Observed on odtest4: a false timeout on gms (fixed separately)
            // left Ring installed and unusable. Aborting instead keeps the placeholder, and the worker's
            // reportUnarchivalStatus(UNARCHIVAL_GENERIC_ERROR) resets the icon so the next tap retries the whole
            // group. That retry re-fetches the group from the store rather than resuming -- this path has NO local
            // chunk cache (roamd's materializeapp never exports NOWHERE_CHUNK_CACHE, rm -rf's .appcode/<pkg> first,
            // materializeDeferred writes O_TRUNC, and both materialise paths rmTree in their finally) -- so a retry
            // costs the full download again. Still the right trade: expensive-but-recoverable beats a cheap dead end.
            // KNOWN NARROW COST: usesPlayServices only tests for the gms.version marker, which any app linking a
            // Play/Firebase library carries, so a SOFT client that would have run degraded (analytics dead, app fine)
            // now also declines to install when a dep fetch fails. Accepted because that outcome is retryable while
            // the one it replaces is not, and because the false-timeout fix removes the dominant cause of dep
            // failure; if it bites in practice the fix is a bounded escape hatch (proceed + warn after N straight
            // failures for a non-stack-member client), NOT keying off isStackMember -- Ring, the app this exists
            // for, is itself a non-stack-member.
            if (!dok) {
                android.util.Log.w("NowhereChooser",
                        "abort materialise of " + pkg + ": dep " + dep + " failed -- leaving the placeholder for a retry");
                // NWP-20260822-12: this group is abandoned -- drop its whole remaining membership, or the total
                // keeps counting apps that are never coming, which is the same lie in a different disguise.
                qDrop(group);
                if (depBusy) { matEnd = SweepOutcome.BUSY; return false; } // NWP-20261118-05: the lane was busy, nothing ran
                matEnd = SweepOutcome.FETCH_FAILED; // NWP-20261113-17: a dependency did not land
                return false;
            }
            qFinish(dep);
        }
        qStart(pkg); // #84: the entry point is the last member -- its position now comes from the queue
        File dir = new File(new File(getFilesDir(), ".appcode"), pkg);
        try {
            final CharSequence label = archivedLabel(pkg); // capture now (still archived); any install clears it
            // Q050 (decided 2026-10-20, NWP-20261112-06): a TAP installs the catalog's newer version from the same
            // signer instead of the sealed copy; the Auto sweep (quiet) and the group deps keep the sealed copy.
            // TRUE = installed, FALSE = stop (the PM owns a PENDING commit; ERR-CANCELLED is a forward guard),
            // null = the sealed copy, as before.
            Boolean tu = quiet ? null : tapUpdateLocked(pkg);
            if (Boolean.FALSE.equals(tu)) { matEnd = SweepOutcome.INSTALL_FAILED; return false; }
            boolean ok;
            if (Boolean.TRUE.equals(tu)) {
                ok = true;
            } else {
                rmTree(dir); // a failed FETCH-APP's leftovers must never mix into the sealed set
                String reply = daemonMaterialize(pkg);
                android.util.Log.i("NowhereChooser", "MATERIALIZE-APP " + pkg + " -> " + reply);
                if (reply == null || !reply.startsWith("OK")) { // NONE | LOCAL | ERR-* | timeout
                    if (SweepBusy.isBusy(reply)) {
                        // NWP-20261118-05: the worker lane was busy, so nothing ran. Leave the queue uncounted:
                        // materializeAndInstall's qFinish would count the app done, and the sweep's retry re-queues it.
                        qDrop(group);
                        matEnd = SweepOutcome.BUSY;
                        return false;
                    }
                    matEnd = SweepOutcome.FETCH_FAILED;
                    return false;
                }
                List<File> apks = new ArrayList<>();
                File[] kids = dir.listFiles();
                if (kids != null) for (File k : kids) if (k.isFile() && k.getName().endsWith(".apk")) apks.add(k);
                if (apks.isEmpty()) {
                    android.util.Log.w("NowhereChooser", "no materialised apk for " + pkg);
                    matEnd = SweepOutcome.FETCH_FAILED;
                    return false;
                }
                // NWP-20261119-15 (Q055 and h49 #1, docs/product-decisions.md): on Endospore, a Play client with no Play
                // Store on this profile and none in its group keeps its placeholder. A tap asks first ("Install anyway"
                // installs); the Auto sweep never asks. The exit is the dep abort's: the worker resets the icon.
                // Diaspore has no gmscompat, so nothing here reads the APK or PM. A stack member never asks for itself.
                boolean endospore = false;
                if (!ProfileActivity.isStackMember(this, pkg) && !ProfileActivity.GMS_PKG.equals(pkg)
                        && !ProfileActivity.GSF_PKG.equals(pkg) && !ProfileActivity.VENDING_PKG.equals(pkg)) {
                    try { getPackageManager().getApplicationInfo("app.grapheneos.gmscompat", 0); endospore = true; }
                    catch (PackageManager.NameNotFoundException ignore) {}
                }
                boolean apkNeedsPlay = false, stackPresent = false;
                if (endospore) {
                    File base = new File(dir, "base.apk");
                    try {
                        android.content.pm.PackageInfo pi = getPackageManager().getPackageArchiveInfo(
                                base.getPath(), PackageManager.GET_META_DATA);
                        apkNeedsPlay = pi != null && pi.applicationInfo != null && pi.applicationInfo.metaData != null
                                && pi.applicationInfo.metaData.containsKey(PlayNeed.MARKER);
                    } catch (Throwable t) {
                        android.util.Log.w("NowhereChooser", "play marker of " + pkg + " not read, installing", t);
                    }
                    try { // installed or archived in this user; MATCH_ARCHIVED_PACKAGES is a long, so PackageInfoFlags
                        stackPresent = getPackageManager().getPackageInfo(ProfileActivity.VENDING_PKG,
                                PackageManager.PackageInfoFlags.of(PackageManager.MATCH_ARCHIVED_PACKAGES)) != null;
                    } catch (Throwable ignore) {}
                }
                PlayNeed.Verdict need = PlayNeed.decide(endospore, apkNeedsPlay, stackPresent,
                        deps.contains(ProfileActivity.VENDING_PKG), quiet);
                if (need != PlayNeed.Verdict.INSTALL) {
                    PlayFetchAsk.Reply a = need == PlayNeed.Verdict.ASK
                            ? PlayNeedAskActivity.ask(this, label, PlayNeed.WAIT_MS) : null;
                    if (a != PlayFetchAsk.Reply.YES) {
                        android.util.Log.i("NowhereChooser", "materialise of " + pkg + " held: no Play Store on this "
                                + "profile (" + (a == null ? "auto" : a) + ") -- leaving the placeholder");
                        rmTree(dir);
                        matEnd = SweepOutcome.NEEDS_PLAY;
                        return false;
                    }
                }
                // NWP-20261126-07 (h50 #3): the quiet path (the sweep, a remembered tap) reads the fetched copy's version
                // against the placeholder's before the install. An older copy cannot unarchive (PackageInstaller refuses
                // it), so it is not installed and the sweep does not fetch it again this session. An unreadable version
                // installs as before. A tap still tries the install.
                if (quiet) {
                    long fetchedVc = -1, placeholderVc = -1;
                    try {
                        android.content.pm.PackageInfo fi = getPackageManager().getPackageArchiveInfo(
                                new File(dir, "base.apk").getPath(), 0);
                        if (fi != null) fetchedVc = fi.getLongVersionCode();
                    } catch (Throwable ignore) {}
                    try { // the archived placeholder; MATCH_ARCHIVED_PACKAGES is a long, so PackageInfoFlags
                        android.content.pm.PackageInfo ai = getPackageManager().getPackageInfo(pkg,
                                PackageManager.PackageInfoFlags.of(PackageManager.MATCH_ARCHIVED_PACKAGES));
                        if (ai != null) placeholderVc = ai.getLongVersionCode();
                    } catch (Throwable ignore) {}
                    if (OlderCopy.older(fetchedVc, placeholderVc)) {
                        android.util.Log.i("NowhereChooser", "materialise of " + pkg + " skipped: stored copy "
                                + fetchedVc + " < placeholder " + placeholderVc
                                + " -- older stored copy -- not installed, not fetched again this session (h50 #3)");
                        OLDER_COPY.add(pkg);
                        rmTree(dir);
                        matEnd = SweepOutcome.OLDER_COPY;
                        return false;
                    }
                }
                updateNoticePhase("Installing"); // -16: the bytes are done; name the commit beat instead of sitting full
                ok = installApks(pkg, apks);
            }
            // NWP-20261113-17: the sealed copy (or a tap's catalog update) that installed is `installed`. A throw in the
            // restore beat below still ends the call as `error`, in the catch.
            matEnd = ok ? SweepOutcome.INSTALLED : SweepOutcome.INSTALL_FAILED;
            if (ok) {
                // #204: installApks completed the unarchive, so the framework's download/install progress ring on the
                // icon is now gone -- show "Getting <app> ready…" HERE to cover only the remaining data/perms-restore +
                // launch beat, so it never overlaps the ring. Dismissed in the worker finally once launchApp has opened
                // the real app over it. (#130: the quiet sweep shows nothing -- there was no tap to answer.)
                if (!quiet) showMaterializing(label);
                updateNoticePhase("Setting up"); // -16: the data-restore beat
                // #204: record that this on-demand app was MATERIALISED this session, so capturePerms trusts its LIVE
                // grants (honouring any in-session revoke) rather than carrying forward its pre-session grants if
                // #206 re-archives it before logoff. The marker lives in the roamed-user CE dir, which is SEALED +
                // RESTORED -- so it does NOT self-clear (the CE *content* rides the seal into the next ephemeral user).
                // roamd rm's it at roam-in (nowhere_roamd.sh `in`, after hold_ondemand) so it reflects ONLY this
                // session by logoff; without that reset a once-materialised app would be mis-classified forever and
                // lose its carry-forward grants on every dormant roam (DIA-20260726-08).
                try (java.io.FileWriter mw = new java.io.FileWriter(new File(getFilesDir(), "nowhere-od-materialised"), true)) {
                    mw.write(pkg + "\n");
                } catch (Throwable ignore) {}
                // #204: the REAL APK is now installed (pkg has a packages.list appId + an app-owned data dir), so
                // tell the daemon to move this app's held CE+DE data back into place and re-grant its runtime perms
                // BEFORE we open it -- at login it was an APK-less archived placeholder, so hold_ondemand parked its
                // restored data (else installd would have wiped it) and pm grant no-op'd on it. Best-effort: a non-OK
                // reply still opens the app; both sides log so a data/perm miss is diagnosable, and the daemon never
                // destroys the hold on a failed move (recoverable on the next login+tap).
                String rr = daemon("RESTORE-ODDATA\n" + pkg + "\n");
                android.util.Log.i("NowhereChooser", "RESTORE-ODDATA " + pkg + " -> " + rr);
                // Mark ONLY on a confirmed OK ("OK <pkg>" | "OK NOSRC"), so a later sweep or tap retries the
                // restore of anything whose restore did not land -- restore-only, never a reinstall
                // (NWP-20261012-04). Marked here too, not just in materializeMember: Play Store is a DEP of a YouTube
                // tap but the ENTRY POINT of its own tap, and it must be skippable either way.
                if (rr != null && rr.startsWith("OK")) markOdRestored(pkg);
                else android.util.Log.w("NowhereChooser", "RESTORE-ODDATA " + pkg + " unconfirmed -- the next sweep or tap retries the restore only");
                // NWP-20261005-14: wake a MESSAGING app the sweep restored. A fresh install is in Android's stopped
                // state, which blocks every broadcast to it -- FCM included -- until a component of it is started, so
                // a restored chat app stayed silent until the user happened to open it (frankel 0.5.42: Authenticator
                // and Amazon still stopped=true after the sweep). Chester, 2026-10-05: "wake messaging apps only".
                // Only after a CONFIRMED restore: woken before its data is back, an app could start fresh and register
                // itself anew. A tap needs none of this -- it launches the app, which unstops it.
                // NWP-20261012-06: which apps is the user's "Wake for notifications" check, defaulting to messaging.
                if (quiet && rr != null && rr.startsWith("OK") && wakeOnRestore(this, pkg)) unstop(this, pkg);
                if (!quiet) {
                    launchApp(pkg); // #205 UX: tap-once opens. The framework's own unarchive-complete auto-launch
                                    // does NOT fire for our custom materialise path, so open it ourselves.
                    // #206: now that an on-demand app is materialised, start the idle-reclaim sweep (runs in THIS
                    // roamed user). No-op re-arm if already scheduled; the chain self-cancels at the logoff
                    // user-stop. The #130 auto sweep never arms it: auto apps are not reclaim candidates
                    // (ondemandKeepSet is strictly on-demand), and a tap will arm it when it matters.
                    ReArchiveReceiver.arm(this, System.currentTimeMillis() + ReArchiveReceiver.CHECK_MS);
                }
            }
            return ok;
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "materialize " + pkg, t);
            matEnd = SweepOutcome.ERROR;
            return false;
        } finally {
            rmTree(dir); // ALWAYS: even a late worker's output must not linger as cleartext in the roamed CE dir
        }
    }

    /** Q050 (decided 2026-10-20, docs/product-decisions.md; NWP-20261112-06): the tap's update. Called under MAT_LOCK
     *  from a tap only (materializeLocked's `quiet ? null :`), never from the Auto sweep or a group dep. When the
     *  catalog pins a version NEWER than the archived package's from one of ITS signers, fetches it (FETCH-APP, the
     *  daemon pins the signer from the signed catalog) and installs it (StoreInstaller.installStaged, which re-pins
     *  the staged APK's signer). Returns
     *  - TRUE: the catalog's version is installed; the caller skips the sealed fetch and restores the parked data
     *    through its own RESTORE-ODDATA, as for the sealed copy;
     *  - null: take the sealed copy (no newer pin, another signer, an unreadable package, no daemon, nApps is
     *    installing the same package, or a failed fetch or install);
     *  - FALSE: stop. PENDING: the package manager owns the commit, and AppInstallReceiver.heal restores the data if
     *    it lands. ERR-CANCELLED is a FORWARD GUARD for a cancel-aware FETCH-APP; today's FETCH-APP never answers it.
     *  On an OK install it records the app's Play dependency, as installApks does on STATUS_SUCCESS (NWP-20260827-10:
     *  install is the only moment an on-demand app's manifest is readable); installStaged does not record it. */
    private Boolean tapUpdateLocked(String pkg) {
        long sealedVc;
        java.util.List<String> certs = new ArrayList<>();
        try {
            android.content.pm.PackageInfo pi = getPackageManager().getPackageInfo(pkg,
                    PackageManager.PackageInfoFlags.of(
                            PackageManager.MATCH_ARCHIVED_PACKAGES | PackageManager.GET_SIGNING_CERTIFICATES));
            if (pi == null || pi.signingInfo == null) return null;
            android.content.pm.Signature[] sigs = pi.signingInfo.getApkContentsSigners();
            if (sigs == null) return null;
            for (android.content.pm.Signature s : sigs) if (s != null) certs.add(TapUpdate.certHex(s.toByteArray()));
            sealedVc = pi.getLongVersionCode();
        } catch (Throwable t) {
            return null;
        }
        if (sealedVc <= 0) return null; // an unreadable version must never make every pin look newer
        TapUpdate.Pin pin = TapUpdate.parse(DaemonSocket.roundTrip("CATALOG-PIN\n" + pkg + "\n", 10000));
        if (!TapUpdate.takeCatalog(sealedVc, certs, pin)) return null;
        if (!StoreInstaller.IN_FLIGHT.add(pkg)) {
            android.util.Log.i("NowhereChooser", "tap-update " + pkg + " sealed=" + sealedVc + " catalog=" + pin.vc
                    + " -> SEALED (the store is installing it)");
            return null;
        }
        int out;
        try {
            String reply = daemon("FETCH-APP\n" + pkg + " " + pin.vc + "\n");
            String verdict = null;
            if (reply != null && reply.startsWith("OK ")) {
                updateNoticePhase("Installing");
                verdict = StoreInstaller.installStaged(this, pkg, StoreSignerPin.fromFetchReply(reply, pkg));
                StoreInstaller.dropManifestLine(this, pkg);
                if (StoreInstaller.OK.equals(verdict)) {
                    // NWP-20260827-10, as installApks on STATUS_SUCCESS: the only moment this on-demand app's (possibly
                    // newly Play-dependent) manifest is readable. installStaged does not record it, and neither does heal.
                    try { ProfileActivity.recordPlayDepAtInstall(this, pkg); } catch (Throwable ignore) {}
                }
            }
            out = TapUpdate.afterFetch(reply, verdict);
            android.util.Log.i("NowhereChooser", "tap-update " + pkg + " sealed=" + sealedVc + " catalog=" + pin.vc
                    + " fetch=" + reply + " install=" + verdict + " -> "
                    + (out == TapUpdate.INSTALLED ? "INSTALLED" : out == TapUpdate.STOP ? "STOP" : "SEALED"));
        } finally {
            StoreInstaller.IN_FLIGHT.remove(pkg);
        }
        if (out == TapUpdate.INSTALLED) return Boolean.TRUE;
        if (out == TapUpdate.STOP) return Boolean.FALSE;
        return null;
    }

    /** Materialise ONE launcher-less group DEP (Play Services / GSF) fully: fetch its deferred APK bytes, install them
     *  (a FRESH install -- a dep has no archived placeholder; the gmscompat framework exemption permits installing
     *  gms), record the materialised marker, then RESTORE-ODDATA (moves its held data back + reowns + keystore-register
     *  + grant, and on roamd's side fires the #sys account reload for the account-bearing member). NO card / launch /
     *  arm -- those belong to the group's entry point. Bytes are ALWAYS deleted. Returns true on install success. */
    /** NWP-20260822-12: the group's UNMET members -- appDeps minus anything already installed AND restored.
     *  Extracted so the queue and the executor cannot disagree about what is coming: enqueueing a set the loop
     *  would then filter differently is exactly how a denominator starts describing a set nobody can see. */
    private java.util.List<String> pendingDeps(String pkg, java.util.List<String> restoreOnly) {
        java.util.List<String> out = new ArrayList<>();
        for (String dep : ProfileActivity.appDeps(this, pkg)) {
            final boolean code = hasInstalledCode(dep);
            // A dep has no placeholder (it is launcher-less), so without code it is fetched: AUTO_GROUP_DEP here
            // means "fetch it with this entry point", which is what the group is for.
            final int action = autoAction(code, code && odRestored(dep), false);
            if (action == AUTO_WHOLE) {
                android.util.Log.i("NowhereChooser", "app dep " + dep + " -> already installed + restored, skipping");
                continue;
            }
            if (action == AUTO_RESTORE_ONLY) {
                // NWP-20261012-04: installed (by us or by anything else, e.g. Play Services from an app store) and
                // its restore unconfirmed. Its code is live and usable, so it is never re-fetched or re-installed
                // over -- only its restore is retried.
                android.util.Log.i("NowhereChooser", "app dep " + dep + " -> installed, restore unconfirmed: restore-only");
                restoreOnly.add(dep);
                continue;
            }
            out.add(dep);
        }
        return out;
    }

    private boolean materializeMember(String pkg) {
        File dir = new File(new File(getFilesDir(), ".appcode"), pkg);
        try {
            depBusy = false;
            String reply = daemonMaterialize(pkg); // #84: streams this dep's byte progress into the notification
            android.util.Log.i("NowhereChooser", "MATERIALIZE-APP(dep) " + pkg + " -> " + reply);
            depBusy = SweepBusy.isBusy(reply); // NWP-20261118-05: nothing ran; the group's abort records busy
            if (reply == null || !reply.startsWith("OK")) return false;
            List<File> apks = new ArrayList<>();
            File[] kids = dir.listFiles();
            if (kids != null) for (File k : kids) if (k.isFile() && k.getName().endsWith(".apk")) apks.add(k);
            if (apks.isEmpty()) { android.util.Log.w("NowhereChooser", "no materialised apk for dep " + pkg); return false; }
            updateNoticePhase("Installing"); // -16: name the commit beat
            boolean ok = installApks(pkg, apks);
            if (ok) {
                try (java.io.FileWriter mw = new java.io.FileWriter(new File(getFilesDir(), "nowhere-od-materialised"), true)) {
                    mw.write(pkg + "\n");
                } catch (Throwable ignore) {}
                updateNoticePhase("Setting up"); // -16: the data-restore beat
                String rr = daemon("RESTORE-ODDATA\n" + pkg + "\n");
                android.util.Log.i("NowhereChooser", "RESTORE-ODDATA(dep) " + pkg + " -> " + rr);
                if (rr != null && rr.startsWith("OK")) markOdRestored(pkg);
                else android.util.Log.w("NowhereChooser", "RESTORE-ODDATA(dep) " + pkg + " unconfirmed -- the next tap retries the restore only");
            }
            return ok;
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "materialize dep " + pkg, t);
            return false;
        } finally {
            rmTree(dir);
        }
    }

    /** #84 (DIA-20260813-15): materialise ONE package with STREAMED byte progress. The daemon's
     *  MATERIALIZE-APP-PROG verb writes "PROG <phase> <done> <total>[ <scope>]" lines -- real bytes from
     *  restoreAppCode's per-chunk writeProg -- before the single final reply; each frame drives the
     *  notification's determinate bar for the app in flight while the title keeps its "(n of m)" position.
     *  Per-line read cap stays READ_CAP_MS: the FIRST line can lag the whole workerMu queue wait, exactly like
     *  the old single reply. Falls back to the plain verb ONLY when the stream yielded no lines at all (an
     *  agent without the verb closed on us) -- agent and chooser pair-ship, so that path is belt-and-braces;
     *  a mid-stream failure returns null like any daemon() error, and the placeholder's own retry covers it. */
    private String daemonMaterialize(String pkg) {
        LocalSocket s = DaemonSocket.connect(); // NWP-20261005-25: bounded connect
        boolean sawAny = false;
        try {
            if (s == null) throw new java.io.IOException("daemon connect timed out");
            s.setSoTimeout(READ_CAP_MS);
            OutputStream os = s.getOutputStream();
            os.write(("MATERIALIZE-APP-PROG\n" + pkg + "\n").getBytes("UTF-8"));
            os.flush();
            BufferedReader br = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
            String line;
            while ((line = br.readLine()) != null) {
                sawAny = true;
                if (line.startsWith("PROG ")) {
                    String[] t = line.trim().split("\\s+");
                    if (t.length >= 4) {
                        try {
                            // NWP-20260901-04: the frame is tagged with ITS package, so the other two writers
                            // of FG_ID can carry it forward without ever attributing it to a different app.
                            updateNoticeBytes(pkg, Long.parseLong(t[2]), Long.parseLong(t[3]));
                        } catch (NumberFormatException ignore) {}
                    }
                    continue;
                }
                return line; // the single final reply ("OK <pkg>" | NONE | LOCAL | ERR-*)
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "daemonMaterialize " + pkg, t);
            return null;
        } finally {
            if (s != null) try { s.close(); } catch (Throwable ignore) {}
        }
        return sawAny ? null : daemon("MATERIALIZE-APP\n" + pkg + "\n");
    }

    /** One request/first-line-reply round-trip to the login daemon over the reserved LocalSocket. */
    private String daemon(String msg) {
        LocalSocket s = DaemonSocket.connect(); // NWP-20261005-25: bounded connect
        try {
            if (s == null) throw new java.io.IOException("daemon connect timed out");
            s.setSoTimeout(READ_CAP_MS);
            OutputStream os = s.getOutputStream();
            os.write(msg.getBytes("UTF-8"));
            os.flush();
            BufferedReader br = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
            return br.readLine();
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "daemon " + msg.split("\n", 2)[0], t);
            return null;
        } finally {
            if (s != null) try { s.close(); } catch (Throwable ignore) {}
        }
    }

    /** NWP-20261005-11: settle this installer's own leftover sessions for pkg before a new one is created.
     *  An UNCOMMITTED one (the process died mid-write) is abandoned: it can never finish and only holds its staged
     *  bytes. A COMMITTED one is still installing in the system, so it is waited on -- polled, with the same
     *  10-minute bound as our own commit (NWP-20260831-03) -- and when it is gone, whether pkg now has real code
     *  decides the answer. Returns TRUE if an earlier install finished and pkg is installed, FALSE if one ended
     *  without installing it, null if there was nothing to wait for. Never throws: on any doubt the caller's own
     *  install runs, and the worst case is the duplicate refusal it would have hit anyway. */
    private Boolean awaitInterruptedInstall(PackageInstaller pi, String pkg) {
        // NWP-20261127-13: the rule is InterruptedInstall.settle (run under javac); this body is its Android adapter.
        Boolean landed = InterruptedInstall.settle(new InterruptedInstall.Sessions() {
            @Override public List<InterruptedInstall.Mine> mine() {
                List<InterruptedInstall.Mine> out = new ArrayList<>();
                for (PackageInstaller.SessionInfo si : pi.getMySessions()) {
                    if (si == null) continue;
                    out.add(new InterruptedInstall.Mine(si.getSessionId(), si.isCommitted(), si.getAppPackageName()));
                }
                return out;
            }
            @Override public void abandon(int id) { pi.abandonSession(id); }
            @Override public boolean present(int id) { return pi.getSessionInfo(id) != null; }
            @Override public boolean installed() { return hasInstalledCode(pkg); }
            @Override public long nowMs() { return android.os.SystemClock.elapsedRealtime(); }
            @Override public void sleep(long ms) throws InterruptedException { Thread.sleep(ms); }
            @Override public void info(String m) { android.util.Log.i("NowhereChooser", m); }
            @Override public void warn(String m, Throwable t) {
                if (t == null) android.util.Log.w("NowhereChooser", m);
                else android.util.Log.w("NowhereChooser", m, t);
            }
        }, pkg, 600_000, 2_000);
        if (landed != null && landed) {
            // The earlier run died before it could record this; installApks' own success path would have.
            try { ProfileActivity.recordPlayDepAtInstall(this, pkg); } catch (Throwable ignore) {}
        }
        return landed;
    }

    /** Install pkg (base + every split) via a PackageInstaller session for THIS (roamed) user, replacing the
     *  archived placeholder. Blocks on the commit result (we run on a worker thread). Returns STATUS_SUCCESS.
     *  Registers the status receiver on the Service Context (a full Context) -- a BroadcastReceiver's own
     *  ReceiverRestrictedContext would throw ReceiverCallNotAllowedException here. */
    private boolean installApks(String pkg, List<File> apks) throws Exception {
        PackageInstaller pi = getPackageManager().getPackageInstaller();
        // NWP-20261005-11: an install a LOCK interrupted is still ours to finish. A cold lock stops this user and
        // kills this process, but a session it had already COMMITTED keeps running in the system (lynx 2026100501:
        // DoorDash still in dex2oat two minutes after the stop). Committing a second one is refused --
        // "Duplicate package <pkg> in pending install requests" -- and the resumed sweep counted the app failed and
        // never restored its held data. So wait for the earlier session first; if the app is installed when it
        // ends, that install is the one we wanted.
        Boolean earlier = awaitInterruptedInstall(pi, pkg);
        if (earlier != null && earlier) return true;
        PackageInstaller.SessionParams p =
                new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        try { p.setAppPackageName(pkg); } catch (Throwable ignore) {}
        try { p.setInstallReason(PackageManager.INSTALL_REASON_USER); } catch (Throwable ignore) {}
        StoreInstaller.pinInternalStorage(p); // deliberate -- see StoreInstaller.pinInternalStorage
        int sid = pi.createSession(p);
        PackageInstaller.Session s = pi.openSession(sid);
        try {
            for (File a : apks) {
                try (InputStream in = new FileInputStream(a);
                     OutputStream out = s.openWrite(a.getName(), 0, a.length())) {
                    byte[] buf = new byte[1 << 16];
                    int rd;
                    while ((rd = in.read(buf)) > 0) out.write(buf, 0, rd);
                    s.fsync(out);
                }
            }
            final CountDownLatch latch = new CountDownLatch(1);
            final int[] st = { PackageInstaller.STATUS_FAILURE };
            final String[] stMsg = { null };
            String action = getPackageName() + ".UNARCHIVE_INSTALL." + sid;
            BroadcastReceiver rcv = new BroadcastReceiver() {
                @Override public void onReceive(Context c, Intent i) {
                    st[0] = i.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE);
                    // NWP-20260831-03: the REASON was always in the broadcast and was never read -- a real
                    // failure logged only "status=1", indistinguishable from the false timeout below.
                    stMsg[0] = i.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE);
                    latch.countDown();
                }
            };
            // NWP-20260831-03: the codePath BEFORE commit. Every applied session mints a new random-suffix
            // codePath, so a change is proof the install landed even if our broadcast never arrives.
            String pathBefore = null;
            try {
                pathBefore = getPackageManager().getApplicationInfo(pkg, 0).sourceDir;
            } catch (Throwable notInstalled) { }
            registerReceiver(rcv, new IntentFilter(action), Context.RECEIVER_NOT_EXPORTED);
            try {
                android.app.PendingIntent pend = android.app.PendingIntent.getBroadcast(this, sid,
                        new Intent(action).setPackage(getPackageName()),
                        android.app.PendingIntent.FLAG_UPDATE_CURRENT | android.app.PendingIntent.FLAG_MUTABLE);
                s.commit(pend.getIntentSender());
                // NWP-20260831-03 / NWP-20261022-10: a timeout is not a verdict -- the wait-and-decide rule and its
                // evidence live once, in InstallWait; this site only maps its outcome onto st/stMsg.
                InstallWait.Outcome outcome = InstallWait.await(
                        ms -> latch.await(ms, TimeUnit.MILLISECONDS),
                        () -> { try { return pi.getSessionInfo(sid) != null; } catch (Throwable gone) { return false; } },
                        () -> { try { return getPackageManager().getApplicationInfo(pkg, 0).sourceDir; }
                                catch (Throwable notInstalled) { return null; } },
                        pathBefore,
                        android.os.SystemClock::elapsedRealtime,
                        () -> android.util.Log.i("NowhereChooser", "unarchive install " + pkg
                                + " still running (session alive) -- waiting on (NWP-20260831-03)"));
                if (outcome == InstallWait.Outcome.LANDED) st[0] = PackageInstaller.STATUS_SUCCESS;
                if (outcome != InstallWait.Outcome.BROADCAST) stMsg[0] = InstallWait.message(outcome);
            } finally {
                try { unregisterReceiver(rcv); } catch (Throwable ignore) {}
            }
            android.util.Log.i("NowhereChooser", "unarchive install " + pkg + " status=" + st[0]
                    + (stMsg[0] != null ? " (" + stMsg[0] + ")" : ""));
            if (st[0] == PackageInstaller.STATUS_SUCCESS) {
                // ⚠ NWP-20260827-10: RECORD THE PLAY DEPENDENCY HERE. For an ON-DEMAND app this is the ONLY
                // moment its manifest is ever readable -- its steady state is an archived placeholder with no
                // APK, so every other reader gets "cannot tell". NWP-20260827-09 gave setAppMode a durable
                // record to fall back on, but for most installs nothing creates that record: the store-install
                // recorder sits behind AppInstallReceiver.decide, which exits at a default-config Off bucket
                // before ever reaching it. This call is therefore the MAIN mechanical recorder, not a backfill.
                //
                // ⚠ WHAT THIS DOES AND DOES NOT DO -- the first cut of this comment overclaimed and the review
                // of this slice caught it, so the honest scope is spelled out:
                //   - It PREVENTS the next loss: once recorded, an Off/On while archived keeps the dependency
                //     (playDependent falls back to nowhere-playseen) and the stack is not dropped.
                //   - It does NOT rescue the CURRENT tap: materializeLocked snapshots this app's deps from
                //     nowhere-playdeps BEFORE this line runs, so a client whose record was already missing
                //     still materialises without its stack this time. Effective from the next reconcile on.
                //   - It CANNOT restore a stack that is already gone from the keep-set: nothing here re-runs
                //     reconcilePlayStack, and a dropped member has no bytes for applyStackMember to accept.
                //     That whole class is the open backlog row filed with this slice, not this line's job.
                //
                // Runs on this FGS thread, never main. Cheap and idempotent: notePlaySeen no-ops when the
                // answer is unchanged at this version, and the stack members themselves are filtered inside
                // recordPlayDepAtInstall -- load-bearing here, because this path fires for EVERY group dep,
                // vending included, and an unfiltered vending record would self-latch the stack on.
                try { ProfileActivity.recordPlayDepAtInstall(this, pkg); } catch (Throwable ignore) {}
            }
            return st[0] == PackageInstaller.STATUS_SUCCESS;
        } finally {
            try { s.close(); } catch (Throwable ignore) {}
        }
    }

    /** Open the just-installed app, so an on-demand tap is "tap once -> downloads -> opens" (like Play's archived
     *  apps). Safe because the unarchive broadcast granted this FGS a temporary background-activity-launch
     *  allowlist (120s) that comfortably covers the fetch+install. A null launch intent (no launcher activity) or
     *  a BAL denial just no-ops -- the app is still installed, so a manual tap opens it. */
    private void launchApp(String pkg) {
        try {
            Intent li = getPackageManager().getLaunchIntentForPackage(pkg);
            if (li == null) {
                android.util.Log.w("NowhereChooser", "no launch intent for " + pkg);
                return;
            }
            li.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(li);
            android.util.Log.i("NowhereChooser", "unarchive auto-launch " + pkg);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "auto-launch " + pkg, t);
        }
    }

    private void rmTree(File f) {
        try {
            if (f == null) return;
            File[] kids = f.listFiles();
            if (kids != null) for (File k : kids) rmTree(k);
            f.delete();
        } catch (Throwable ignore) {}
    }
}
