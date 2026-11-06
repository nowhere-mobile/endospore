package com.nowhere.chooser;

import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.IBinder;

/**
 * L1 (lock-model.md): set the SESSION keyguard credential on the roamed (ephemeral) user.
 *
 * resetPasswordWithToken IGNORES a cross-user context -- invoked from user 0 it locks user 0 (the gate),
 * not the session (verified on the FP3 2026-06-23: createContextAsUser(uid) still set user 0's credential).
 * So the user-0 gate starts THIS service via startServiceAsUser(uid); it runs in the roamed user's OWN
 * process, where the chooser is the profile owner of that user. Here it enrolls a reset-password token
 * (which activates immediately with NO on-screen confirm -- the fresh ephemeral user has no prior
 * credential) and sets the credential, then stops. The passphrase rides in the Intent extra
 * (binder / in-memory) -- never on disk, never in any argv.
 */
public class CredentialService extends Service {
    /**
     * #151, NWP-20260913-05: keep the gate’s next-alarm stash fresh from inside the roamed session.
     *
     * ⚠ THE RELAY HAD TWO CALLERS AND BOTH WERE THINGS THE USER TAPS: ProfileActivity’s Log off and its
     * "Lock" button. The lock that actually happens to people -- the idle one -- is driven headlessly from
     * IdleLogoffReceiver in USER 0, which sends COLD-LOCK-IDLE straight to the daemon and relays nothing. So
     * the gate was never told there was an alarm, scheduled none, and #151’s whole ring-with-Snooze/Dismiss
     * path sat idle. Device-observed on lynx 2026-09-13 (agent 2026091209) across a real cold lock: session
     * stopped, GATE_ALARM scheduled = 0, GateAlarmActivity running = 0 -- and when the alarm came due the
     * ROAMED user’s own deskclock rang instead (audio uid 1510160 = user 15), with its UI stuck in that user
     * behind the gate’s LockTask foreground. It rings and there is nothing to tap.
     *
     * ⚠ IT CANNOT BE FIXED AT THE LOCK. captureNextAlarm reads the ROAMED user’s AlarmManager, and
     * IdleLogoffReceiver must stay headless in user 0 -- its own header records why: launching cross-user into
     * a locked, screen-off user is DEFERRED by Android until unlock, so an attacker who never unlocks would
     * never trigger it. The value has to be PUSHED OUT of the session before it stops.
     * *(⚠ SUPERSEDED IN PART by NWP-20261004-01: it CAN be done at the lock, just not from user 0. The daemon's
     * teardown has roamd START THIS SERVICE in the session -- a service start into a running user, not a
     * cross-user activity launch -- and waits for the relay before the stop. See the "alarm" branch below.)*
     *
     * So push it on the tick that already runs as this user: the post-seal claims kick, roughly every
     * syncIntervalDefault. At most one interval stale, which costs nothing -- the gate only schedules a time
     * still in the future. *(⚠ Not "at most one interval stale" for an OFFLINE session: the claims kick fires
     * only after a vault push, so offline it never fires at all. That is why the lock-time relay exists.)*
     *
     * ⚠ A READ FAILURE RETURNS WITHOUT SENDING. "0" is the daemon’s CLEAR, so relaying it because
     * getSystemService hiccuped would silently delete a good alarm -- the same shape as the null-manager bugs
     * that have bitten this app four times.
     */
    /** This user’s id. Reflection because {@code UserHandle.myUserId()} is @hide -- the same resolver
     *  {@link GosState} uses, rather than leaning on {@code UserHandle.hashCode()} happening to equal it. */
    static int myUserId() {   // package-private since NWP-20261011-04: ProfileActivity's logoff relay names the user too
        try {
            return (Integer) android.os.UserHandle.class.getMethod("myUserId").invoke(null);
        } catch (Throwable t) {
            return -1;   // -1 never matches a real user, so the daemon stores no pair rather than a wrong one
        }
    }

    /** SET-GATE-ALARM's body line: "<when>	<uid>	<pkg>", or the time alone when there is no alarm or no complete
     *  owner. Extra FIELDS, not extra lines, so the daemon still does one read and an older daemon simply sees a longer
     *  first field rather than blocking for input that never comes. Shared by both relays since NWP-20261011-04: the
     *  logoff's cutoff keeps the package named here, so the clock app that owns the alarm is never force-stopped. */
    static String alarmRelayLine(long when, int userId, String pkg) {
        String line = String.valueOf(when);
        if (when != 0L && pkg != null && !pkg.isEmpty() && userId >= 0) {
            line = line + "\t" + userId + "\t" + pkg;
        }
        return line;
    }

    /** True when one of at most {@code tries} sends is answered "OK". The daemon answers ERR when it cannot store the
     *  alarm and DaemonSocket.roundTrip returns "" on any connect or read failure; for an offline session the cold
     *  lock's relay is the only one, so a refused or unanswered send is retried and, failing that, reported. */
    static boolean relayLanded(java.util.function.Supplier<String> send, int tries) {
        for (int i = 0; i < tries; i++) {
            String r = send.get();
            if (r != null && r.startsWith("OK")) return true;
        }
        return false;
    }

    private static void relayNextAlarm(Context ctx, String trigger) {
        long when;
        String pkg = null;
        try {
            android.app.AlarmManager am =
                    (android.app.AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
            if (am == null) {
                android.util.Log.w("NowhereChooser", "#151 relay: NO AlarmManager -- gate stash left alone");
                return;
            }
            android.app.AlarmManager.AlarmClockInfo ac = am.getNextAlarmClock();
            when = ac == null ? 0L : ac.getTriggerTime();
            // NWP-20260913-05b: also say WHO set it. Both clocks can ring at the same instant -- the gate’s
            // alarm is a copy of this time, and a roamed session whose stop did not fully complete still
            // rings its own -- and a button in user 0 cannot silence an app in this user. The show-intent’s
            // creator IS the clock app that set the alarm, so the gate stops exactly that and nothing else.
            if (ac != null && ac.getShowIntent() != null) {
                pkg = ac.getShowIntent().getCreatorPackage();
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "#151 relay: could not read the next alarm", t);
            return;
        }
        String line = alarmRelayLine(when, myUserId(), pkg);
        boolean landed = relayLanded(() -> DaemonSocket.roundTrip("SET-GATE-ALARM\n" + line + "\n", 8000), 2);
        if (landed) {
            android.util.Log.i("NowhereChooser", "#151 relayed next alarm " + when + " src=" + pkg + " to the gate (" + trigger + ")");
        } else {
            android.util.Log.w("NowhereChooser", "#151 relay: the gate did not take the next alarm (" + trigger + ") -- it keeps its last copy");
        }
    }

    @Override public IBinder onBind(Intent i) { return null; }

    // In-flight work units. stopSelf(startId) is NOT enough to protect a long-running older start: it only
    // ignores a STALE id -- a LATER start's stopSelf(latestId) stops the service even while an earlier
    // start's worker thread is still running (the review catch: the first-screen-off credential start would
    // have stopped the service ~mid-ingest, dropping the roamed chooser to LMK-killable cached priority for
    // the rest of the ingest's ~80s window). So: refcount the work; only stop when the LAST unit finishes.
    // Both units are idempotent, so the rare recreate-after-stop race is harmless.
    private static final java.util.concurrent.atomic.AtomicInteger ACTIVE =
            new java.util.concurrent.atomic.AtomicInteger();

    private void finishUnit() {
        if (ACTIVE.decrementAndGet() <= 0) stopSelf();
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        ACTIVE.incrementAndGet();
        // #135 delivery v2: a "telingest" start (fired by the gate right after the login switch) pulls this
        // user's decrypted telephony rows from the daemon and inserts them into OUR OWN providers with a
        // verify-first retry (see TelIngest -- the su:s0 worker could never verify, per DIA-56). It rides in
        // THIS service, not a new one, because a NEW manifest component does not register over a
        // pinned-fingerprint reflash without a data wipe (the B4 lesson, 2026-07-11); CredentialService is
        // already registered and already started AS the roamed user.
        // NWP-20260821-17: replay the sealed GrapheneOS per-app hardening flags into THIS user. Rides here
        // for exactly the reason telingest does -- a NEW manifest component does not register over a
        // pinned-fingerprint reflash without a data wipe (the B4 lesson, 2026-07-11) -- and because this
        // service is already started AS the roamed user, which is what makes the whole architecture
        // same-user and therefore free of any cross-user permission.
        // NWP-20260911-01: a "claims" start applies the per-app concurrency record the seal just wrote
        // -- hold the apps another handset is using, release the ones it has finished with. Rides HERE
        // for the same B4 reason as every branch below: a NEW manifest component does not register over
        // a pinned-fingerprint reflash without a data wipe, and this service already runs AS the roamed
        // user, which is the side whose receipt records what we hold.
        // NWP-20261029-11: a "claimsLogin" start applies the claim map the sign-in seeded, once, right after
        // provisionRoamedApps. Only the apply: the held-list refresh and the alarm relay are seal-cycle work.
        if (intent != null && intent.getBooleanExtra("claimsLogin", false)) {
            new Thread(() -> {
                try {
                    AppClaim.Result r = AppClaim.applyFromFile(this, android.os.UserHandle.myUserId());
                    android.util.Log.i("NowhereChooser", "claims-login apply -> " + r.state);
                } catch (Throwable t) {
                    android.util.Log.w("NowhereChooser", "claims-login apply", t);
                } finally { finishUnit(); }
            }, "nowhere-claims-login").start();
            return START_NOT_STICKY;
        }
        if (intent != null && intent.getBooleanExtra("claims", false)) {
            new Thread(() -> {
                try {
                    AppClaim.applyFromFile(this, android.os.UserHandle.myUserId());
                    // NWP-20260912-06: then say what WE hold, for the NEXT seal to publish. AFTER the apply,
                    // never before, so this cycle’s claim record is what AppHeld reads to avoid asking for a
                    // package another handset already holds.
                    //
                    // ⚠ THE PUBLISHED LIST IS ALWAYS ONE CYCLE OLD, BY CONSTRUCTION, and an earlier version of
                    // this comment denied it ("the producer’s tick IS the seal’s tick"). roamd reads the held
                    // list BEFORE the pushes and kicks this service AFTER them, so what a seal publishes is
                    // what the producer computed at the end of the previous cycle. That is the feature’s
                    // latency and the product decision already accepts it; what it is not is an invariant.
                    //
                    // ⚠ And the kick itself is gated on $CLAIMSOUT existing, which only the BARE-VAULT push
                    // creates -- so a cycle whose vault push is skipped or refused does not refresh at all.
                    // The login seed in UnarchiveService is what keeps a session from starting blind.
                    AppHeld.refresh(this);
                    // NWP-20260913-05 (#151): and relay this session’s next alarm to the gate while we still
                    // can. See relayNextAlarm below for why it has to happen HERE and not at the lock.
                    relayNextAlarm(this, "post-seal");
                    // NWP-20261120-12: a cold lock stops this user and drops its alarms, so the idle-reclaim
                    // sweep re-arms here after a resume. While a sweep is pending this changes nothing.
                    ReArchiveReceiver.keepArmed(this);
                } finally { finishUnit(); }
            }, "nowhere-claims").start();
            return START_NOT_STICKY;
        }
        // NWP-20261004-01 (#151): an "alarm" start is the cold lock asking for this session's next alarm just
        // before it stops the user. The post-seal relay above fires only when the vault push happened, so an
        // OFFLINE session never relayed the alarm it set -- and since the Endospore overlay stopped the framework
        // restarting a stopped user around its alarms, the gate's copy is the only ring there is. The daemon's
        // teardown waits for the SET-GATE-ALARM this sends. Same B4 reason as every branch here for riding THIS
        // service rather than a new one.
        if (intent != null && intent.getBooleanExtra("alarm", false)) {
            new Thread(() -> {
                try { relayNextAlarm(this, "cold lock"); } finally { finishUnit(); }
            }, "nowhere-alarm-relay").start();
            return START_NOT_STICKY;
        }
        // NWP-20261126-10: a "relayprefs" start is the user-0 gate, restarted during this session, asking for this
        // session's lock prefs again: its idle watcher and lock values died with its process (RestartRearm). Same B4
        // reason as every branch here for riding THIS service rather than a new one.
        if (intent != null && intent.getBooleanExtra("relayprefs", false)) {
            new Thread(() -> {
                try { RestartRearm.sendFromSession(this); } finally { finishUnit(); }
            }, "nowhere-relayprefs").start();
            return START_NOT_STICKY;
        }
        if (intent != null && intent.getBooleanExtra("gosstate", false)) {
            new Thread(() -> {
                try { GosState.apply(this); } finally { finishUnit(); }
            }, "nowhere-gosstate").start();
            return START_NOT_STICKY;
        }
        // NWP-20260827-18 (web-import slice II): an "ingest" start turns a web-created profile's staged
        // Documents/Imported/*.vcf|*.ics into live contacts/calendar rows, insert-with-verify in OUR OWN
        // providers (the TelIngest posture -- the su:s0 worker cannot verify, DIA-56). Rides in THIS
        // service for the same B4 reason as the branches above: a NEW manifest component does not register
        // over a pinned-fingerprint reflash without a data wipe, and this service is already started AS
        // the roamed user.
        if (intent != null && intent.getBooleanExtra("ingest", false)) {
            new Thread(() -> {
                try { Ingest.run(this); } finally { finishUnit(); }
            }, "nowhere-ingest").start();
            return START_NOT_STICKY;
        }
        // NWP-20261010-13: an "smsrole" start (fired by the gate's cede at sign-in) gives this user's SMS role to the
        // profile's own SMS app, which only this user's chooser can read from its CE dir (SmsRoleRoam.applyAtSignIn).
        if (intent != null && intent.getBooleanExtra("smsrole", false)) {
            new Thread(() -> {
                try { SmsRoleRoam.applyAtSignIn(this); } finally { finishUnit(); }
            }, "nowhere-smsrole").start();
            return START_NOT_STICKY;
        }
        // NWP-20261010-13: an "smsretry" start (the gate's delayed repair) retries a sign-in apply the profile's SMS app
        // refused (SmsRoleRoam.retryRefused).
        if (intent != null && intent.getBooleanExtra("smsretry", false)) {
            new Thread(() -> {
                try { SmsRoleRoam.retryRefused(this); } finally { finishUnit(); }
            }, "nowhere-smsretry").start();
            return START_NOT_STICKY;
        }
        if (intent != null && intent.getBooleanExtra("telingest", false)) {
            final boolean live = intent.getBooleanExtra("live", false); // #149: live delivery skips the roam-in settle
            new Thread(() -> {
                try { TelIngest.run(this, live); } finally { finishUnit(); }
            }, "nowhere-telingest").start();
            return START_NOT_STICKY;
        }
        try {
            if (intent != null) {
                String pw = intent.getStringExtra("pw");
                if (pw != null && !pw.isEmpty()) setCredential(pw);
            }
        } finally {
            finishUnit();
        }
        return START_NOT_STICKY;
    }

    private void setCredential(String pw) {
        try {
            android.app.admin.DevicePolicyManager dpm =
                    (android.app.admin.DevicePolicyManager) getSystemService(Context.DEVICE_POLICY_SERVICE);
            android.content.ComponentName admin = new android.content.ComponentName(this, AdminReceiver.class);
            byte[] token = new byte[32];
            new java.security.SecureRandom().nextBytes(token);
            boolean tokenSet = dpm.setResetPasswordToken(admin, token);
            boolean active = tokenSet && dpm.isResetPasswordTokenActive(admin);
            boolean pwSet = false;
            if (active) {
                // flags=0: set the credential but DON'T force an immediate lock. RESET_PASSWORD_REQUIRE_ENTRY
                // slam-locks the session the instant we set it, so the user (who just typed the passphrase at
                // the gate to log in) is dumped onto a lockscreen and must type it AGAIN before reaching home.
                // With no flag the session stays unlocked after login; the secure keyguard still challenges on
                // the next screen-off. (DIA-20260623-10)
                pwSet = dpm.resetPasswordWithToken(admin, pw, token, 0);
            }
            android.util.Log.i("NowhereChooser", "L1 CredentialService user="
                    + android.os.Process.myUserHandle() + " tokenSet=" + tokenSet
                    + " active=" + active + " pwSet=" + pwSet);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "CredentialService.setCredential", t);
        }
    }
}
