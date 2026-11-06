package com.nowhere.chooser;

import android.content.Context;

/**
 * NWP-20261010-13 (Chester, 2026-10-11): THE SMS APP A USER CHOOSES ROAMS WITH THE PROFILE. His words: "if the user
 * changes the sms apps default to whatsapp for example, that should get be used for that profile ever after (even
 * after roam)". This supersedes the 2026-10-10 rule that every sign-in hands the SMS role back to Messaging.
 *
 * THE RECORD is a sibling file in the chooser's CE files dir, nowhere-sms (`app=<pkg>`), the same pattern as
 * nowhere-nav / nowhere-aod / nowhere-vpn, so it seals into the vault with them. Never a nowhere-prefs key:
 * ProfileActivity setPref() rewrites that file whole and eats any key it does not know (the #159 incident). No record
 * means Messaging, the default. A holder that is the chooser is never a choice; Messaging is recorded only as a switch
 * BACK from another app (a profile that never chose anything keeps no record).
 *
 * WHO OWNS IT: the chooser IN THE ROAMED USER, for capture and for apply. It is the side that sees the role: it holds
 * MANAGE_ROLE_HOLDERS and OBSERVE_ROLE_HOLDERS and reads RoleManager in its own user. roamd would have to capture
 * `cmd role get-role-holders` output, which needs a `role_service` find grant no Nowhere domain has, and Diaspore's
 * su:s0 cannot capture cmd output at all (DIA-56). The gate (user 0) sees the role but cannot read the roamed user's
 * CE files. And it captures IN TIME: it writes the record the moment the holder changes (MessagingSuppressor's role
 * listener, plus a check at every listener connect), so every seal -- a logoff's, or the periodic one a cold lock
 * relies on -- carries the current choice; roamd needs no change. The residual is the one every capture on the
 * periodic path has: a change inside the last sync interval before a cold lock that is never resumed.
 *
 * APPLY at sign-in (applyAtSignIn, kicked by the gate's cede through CredentialService, after the `in` op restored the
 * CE dir and provisionRoamedApps ran): the recorded app if it is installed; otherwise Messaging stands in and the record
 * is KEPT -- the app takes the role back when it materialises, is installed again, or the install heal sees it
 * (onMaterialised, from markOdRestored and AppInstallReceiver).
 *
 * ⚠ THE RECORD CHANGES ONLY ON THE USER'S OWN, OBSERVED ACTION: a capture that sees a different holder while this
 * session's marker says "applied" -- a switch to Messaging included, while the recorded app is installed. NOTHING
 * INFERRED EVER CLEARS IT: not the app's absence (a best-effort #apps restore or a placeholder raise that failed, an app
 * installed from a store while new apps are not kept, an uninstall), not a switch-Off, not a read that failed. So an
 * uninstalled app's choice persists, and the app takes the role back if it is ever installed again -- the profile's
 * choice, "ever after". PackageManager is read fail-closed (presence): only NameNotFoundException means absent; any
 * other failure means "do nothing".
 *
 * ⚠ NEVER CAPTURE BEFORE THIS SESSION'S APPLY. Until the apply ran, the holder is a fresh user's, and capturing it would
 * overwrite the profile's choice with Messaging. Two locks keep a marker from an earlier session out. roamd's `in` op
 * REMOVES nowhere-sms-applied at every roam-in (the primary defence). And the marker names its session by the user's
 * SERIAL NUMBER (UserManager.getSerialNumberForUser: kept across a cold lock and its resume) -- but serials are a
 * per-DEVICE counter, so a marker sealed on another handset CAN carry the serial this one just minted; the serial is
 * the second lock, never the only one. The apply writes the marker whatever its outcome: "applied" when the intended
 * holder took the role, "deferred" when the recorded app is not installed, "fallback" when it was REFUSED (installed,
 * but it would not take the role -- the #131 fresh-user window -- or not even Messaging did), so a later choice the
 * user makes is still captured. An unreadable record is unknown too (recordUnknown): Messaging stands in and no marker
 * is written, so nothing is captured that session and the record is kept (NWP-20261123-23).
 *
 * While Messaging stands in (deferred or fallback), it is never captured, so the record survives the session; a
 * different app the user picks meanwhile is a new choice and is captured. A deferred app takes the role when it next
 * materialises or is installed (onMaterialised). A refused one is retried by the gate's delayed repair
 * (ChooserActivity.repairSmsRoleLater kicks retryRefused). An app the idle reclaim RE-ARCHIVES mid-session
 * (ReArchiveReceiver), or one that is uninstalled, loses the role -- the role controller falls back to its default,
 * Messaging -- and neither is a choice: the capture keeps the record and moves the marker to deferred (standInState).
 *
 * ⚠ THREE CASES ARE READ AS THE STAND-IN, BY DESIGN. (1) Choosing Messaging while the recorded app is archived or absent
 * looks exactly like the role controller's fallback to Messaging -- the holder is the same and nothing records why --
 * so it keeps the record, and the app takes the role back when it returns. (2) A switch from the recorded app to
 * Messaging made while the role listener is not running (its process died) and followed by a re-archive or removal of
 * that app before the next connect-time capture is read the same way. (3) During a "fallback" session (the recorded app
 * refused the role at sign-in), the user ACCEPTING Messaging is not observable: Messaging is already the holder. The
 * retry (retryRefused) runs at EVERY gate repair while the state stays fallback -- the sign-in's, the watcher's after a
 * gate restart, the DISALLOW_SMS lift's on a SIM-ownership change -- so it can move the role to the recorded app later
 * in the session. Any other switch to Messaging is recorded.
 */
final class SmsRoleRoam {
    static final String MESSAGING = "com.android.messaging";
    static final String RECORD = "nowhere-sms";
    static final String MARKER = "nowhere-sms-applied";
    // The gate's own repair (ChooserActivity.repairSmsRoleLater) waits this long, so it cannot race the sign-in apply:
    // the apply's worst case is two ensureHolder runs of 4 x (2 s + 0.3 s).
    static final long SMS_REPAIR_DELAY_MS = 60_000L;
    private static final Object LOCK = new Object();

    private SmsRoleRoam() {}

    /** A plausible Android package name: dotted, letters, digits, underscores, at most 255. */
    static boolean isPackageName(String s) {
        if (s == null || s.isEmpty() || s.length() > 255 || s.indexOf('.') < 0) return false;
        if (s.startsWith(".") || s.endsWith(".") || s.contains("..")) return false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (!(c == '.' || c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) return false;
        }
        return true;
    }

    /** The package the record names, or null for no record or a malformed one (read as no record: Messaging). */
    static String parseSmsRecord(String content) {
        if (content == null) return null;
        for (String l : content.split("\n")) {
            if (l.startsWith("app=")) {
                String p = l.substring(4).trim();
                return isPackageName(p) ? p : null;
            }
        }
        return null;
    }

    /** NWP-20261123-23: the record file exists, is within read()'s 4096-byte cap, and still could not be read (EIO, a
     *  wrong owner after the restore). That is UNKNOWN, never "no record". An absent file, or an oversized one
     *  (malformed, read as no record), is not unknown: those keep today's behaviour. */
    static boolean recordUnknown(boolean isFile, long length, String content) {
        return isFile && length <= 4096 && content == null;
    }

    /** The session marker's text. */
    static String markerText(String session, String state, String applied, String target) {
        return "session=" + session + "\nstate=" + state + "\napplied=" + applied + "\ntarget=" + target + "\n";
    }

    /** The marker as {state, applied, target} when it belongs to THIS session and is well formed, else null -- and
     *  null means "this session's apply has not run": nothing is captured. */
    static String[] parseMarker(String content, String session) {
        if (content == null || session == null || session.isEmpty()) return null;
        String s = null, st = null, ap = null, tg = null;
        for (String l : content.split("\n")) {
            if (l.startsWith("session=")) s = l.substring(8);
            else if (l.startsWith("state=")) st = l.substring(6);
            else if (l.startsWith("applied=")) ap = l.substring(8);
            else if (l.startsWith("target=")) tg = l.substring(7);
        }
        if (!session.equals(s)) return null;
        if (!"applied".equals(st) && !"deferred".equals(st) && !"fallback".equals(st)) return null;
        if (!isPackageName(ap) || !isPackageName(tg)) return null;
        return new String[]{st, ap, tg};
    }

    /** What sign-in does with the record, as {the package to give the role, the state, the target}. presence is the
     *  recorded app's (presence(): installed / archived / absent / unknown). The record itself is never changed here.
     *  - no record, or one naming the chooser or Messaging: Messaging, applied.
     *  - installed, or UNKNOWN (PackageManager failed -- fail closed, try the app): that app, applied. If it refuses
     *    the role, applyAtSignIn falls back to Messaging with the record kept ("fallback").
     *  - archived or absent: Messaging for now, deferred to the app. */
    static String[] smsSignInPlan(String record, String presence, String messaging, String self) {
        if (record == null || record.equals(self) || record.equals(messaging)) return new String[]{messaging, "applied", messaging};
        if ("installed".equals(presence) || "unknown".equals(presence)) return new String[]{record, "applied", record};
        return new String[]{messaging, "deferred", record};
    }

    /** What a capture writes into the record, or null for nothing. state/applied come from this session's marker
     *  (parseMarker); holder is the SMS role's holder now ("" or null when none or unreadable).
     *  - an unreadable or empty holder, or the chooser: nothing -- neither is a choice.
     *  - deferred/fallback (waiting, or refused) and the holder is still the stand-in Messaging: nothing.
     *  - the holder the record already names: nothing.
     *  - Messaging with no record: nothing -- the default needs no record.
     *  - anything else, Messaging included as a switch back: that holder. */
    static String smsCaptureValue(String record, String state, String applied, String holder, String messaging,
                                  String self) {
        if (!isPackageName(holder) || holder.equals(self)) return null;
        if (("deferred".equals(state) || "fallback".equals(state)) && holder.equals(applied)) return null;
        if (holder.equals(record)) return null;
        if (holder.equals(messaging) && record == null) return null;
        return holder;
    }

    /** NWP-20261010-13: what a capture does when the role went to Messaging (or to nobody) while the recorded app is
     *  not installed -- null to go on to smsCaptureValue:
     *  - "none": PackageManager could not say (presence "unknown") -- do NOTHING, neither capture nor move the marker.
     *  - "deferred": archived (the idle reclaim) or absent (an uninstall, a failed restore) -- not an observed choice.
     *    The record is kept, the marker moves to deferred, and the app takes the role back when it returns.
     *  presence describes the recorded app; an unreadable holder (null) changes nothing. */
    static String standInState(String record, String holder, String messaging, String self, String presence) {
        if (record == null || record.equals(messaging) || record.equals(self) || "installed".equals(presence)) return null;
        if (!messaging.equals(holder) && !"".equals(holder)) return null;
        if (!"archived".equals(presence) && !"absent".equals(presence)) return "none";
        return "deferred";
    }

    /** NWP-20261010-13: the app onMaterialised gives the role to, or null for none. Only the recorded app this
     *  session is waiting for: a marker of THIS session (m, from parseMarker) that is not "applied", whose target is
     *  pkg, and only while the stand-in still holds the role (takeOverFromStandIn) -- never over the user's own pick. */
    static String materialiseTarget(String[] m, String pkg, java.util.List<String> holders, String self) {
        if (m == null || "applied".equals(m[0]) || !m[2].equals(pkg)) return null;
        return takeOverFromStandIn(holders, m[1], self) ? pkg : null;
    }

    /** NWP-20261010-13 (round-6 review F3): the app retryRefused gives the role to, or null. The sign-in apply can be
     *  REFUSED by an installed recorded app in the fresh-user window (#131: the same addRoleHolderAsUser returned
     *  ok=false for HOME), which left the session on Messaging. The gate's delayed repair retries it: only for a
     *  "fallback" marker of this session, a recorded app that is installed now, and the stand-in Messaging still the
     *  holder (any other holder is the user's pick). */
    static String retryRefusedTarget(String[] m, String presence, java.util.List<String> holders, String messaging) {
        if (m == null || !"fallback".equals(m[0]) || m[2].equals(messaging) || !"installed".equals(presence)) return null;
        return roleHeldBy(holders, messaging) ? m[2] : null;
    }

    /** NWP-20261010-13 (round-3 review F3): whether a delayed gate repair still belongs to the session it was scheduled
     *  for: the user's serial then and now. A logoff ends the user, and a later login mints a new one (a new serial,
     *  even when the user id is reused); a cold-lock resume keeps the user and its serial. -1 is "could not read". */
    static boolean repairStillValid(long scheduledSerial, long nowSerial) {
        return scheduledSerial >= 0 && scheduledSerial == nowSerial;
    }

    /** Whether the recorded app, now materialised, takes the role over from the stand-in: only while the stand-in
     *  (applied) still holds it, or nobody or the chooser does. A different app means the user chose meanwhile. */
    static boolean takeOverFromStandIn(java.util.List<String> holders, String applied, String self) {
        if (holders == null) return false;
        return holders.isEmpty() || holders.contains(applied) || holders.contains(self);
    }

    /** NWP-20261010-13: whether these role holders include pkg. A null list is "could not tell", read as not held. */
    static boolean roleHeldBy(java.util.List<String> holders, String pkg) {
        return holders != null && pkg != null && holders.contains(pkg);
    }

    /** NWP-20261010-13: one step of ensureHolder, from the SMS role's holders (null = could not read them): "held"
     *  (want holds it, done), "assign" (hand it to want) or "leave" (do not touch it).
     *  signIn=true is the SIGN-IN apply in the roamed user (applyAtSignIn, onMaterialised once it decided): it gives
     *  the role to want -- the profile's own choice, or Messaging -- whoever holds it, and assigns through an
     *  unreadable list.
     *  signIn=false is the gate's REPAIR (the watcher, the cede's delayed backstop, the DISALLOW_SMS lift): it only
     *  repairs a role nobody, or the chooser, holds; it LEAVES another app alone, because that is the user's choice
     *  (made this session, or carried from the last), and it leaves an unreadable list alone. A watcher restarted
     *  mid-session (a user-0 process restart resets its once-per-uid latch) or a foreground uid that alternates must
     *  never replace that choice. */
    static String smsRoleStep(java.util.List<String> holders, boolean signIn, String self, String want) {
        if (roleHeldBy(holders, want)) return "held";
        if (signIn) return "assign";
        if (holders == null) return "leave";
        return holders.isEmpty() || roleHeldBy(holders, self) ? "assign" : "leave";
    }

    /** NWP-20261010-13 (round-7 review F2): one step of a TAKEOVER (retryRefused, onMaterialised): hand the role to
     *  want only from the stand-in -- while the holder is want ("held"), the stand-in, nobody, or the chooser -- and
     *  "leave" it otherwise, including an unreadable list. Re-applied on EVERY attempt of ensureHolder, so a pick the
     *  user makes between attempts is never taken back (smsRoleStep's sign-in mode would assign over it). */
    static String takeoverStep(java.util.List<String> holders, String self, String want, String standIn) {
        if (roleHeldBy(holders, want)) return "held";
        if (holders == null) return "leave";
        return holders.isEmpty() || holders.contains(standIn) || roleHeldBy(holders, self) ? "assign" : "leave";
    }

    /** #148, NWP-20261010-13: make want the SMS role holder in user uh, and know that it is. One ROLE_SMS
     *  addRoleHolderAsUser used to be fired and only logged -- in the fresh-user window where the same call for HOME
     *  was proven to return ok=false (#131 v2). So, like ensureRoamedHomeRole: VERIFY the holders, assign if
     *  smsRoleStep says so, RETRY with a short settle. Returns "held" (want holds it), "left" (smsRoleStep left it to
     *  another holder) or "failed". uc is a context in user uh; the callback runs on ex, so this must never run on
     *  the thread ex runs on. Bounded: 4 x (2 s + 0.3 s), plus one 2 s re-read for a repair.
     *  A REPAIR (signIn=false) that finds the role empty reads the holders again 2 s later before it assigns: the
     *  role is exclusive, so an add of Messaging that lands just after the sign-in apply gave it to the profile's app
     *  would take it away again. standIn non-null makes it a TAKEOVER (takeoverStep, every attempt) instead of
     *  smsRoleStep's signIn/repair modes; the sign-in apply and the gate's repair pass null. */
    static String ensureHolder(Context uc, android.os.UserHandle uh, String want, boolean signIn, String self,
                               java.util.concurrent.Executor ex, String standIn) {
        final int uid = uh.getIdentifier();
        try {
            android.app.role.RoleManager rm = uc.getSystemService(android.app.role.RoleManager.class);
            if (rm == null || !rm.isRoleAvailable(android.app.role.RoleManager.ROLE_SMS)) {
                android.util.Log.w("NowhereChooser", "#148 SMS role unavailable in " + uid + " (signIn=" + signIn + ")");
                return "failed";
            }
            boolean confirmed = signIn;
            // NWP-20261012-05: the SMS role overrides the user when granting -- an add grants every role permission
            // `want` was not holding and CLEARS its USER_SET / USER_FIXED, undoing whatever the profile declined.
            // Snapshot `want`'s live declines before the first add, and put them back once it holds the role -- all but
            // the SMS permissions, which the SMS app keeps (NWP-20261012-08, PermDeclines.exceptSmsRole).
            java.util.List<String[]> declines = null;
            for (int attempt = 1; attempt <= 4; attempt++) {
                java.util.List<String> holders = null;
                try {
                    holders = rm.getRoleHoldersAsUser(android.app.role.RoleManager.ROLE_SMS, uh);
                } catch (Throwable ignore) { /* getRoleHoldersAsUser may be restricted -> smsRoleStep reads null */ }
                String step = standIn != null ? takeoverStep(holders, self, want, standIn) : smsRoleStep(holders, signIn, self, want);
                if ("held".equals(step)) {
                    android.util.Log.i("NowhereChooser", "#148 " + want + " is default SMS in " + uid + " (verified, attempt " + attempt + ")");
                    if (declines != null) PermDeclines.apply(uc, uh, want, declines, "sms role add"); // an earlier add landed late
                    return "held";
                }
                if ("leave".equals(step)) {
                    android.util.Log.i("NowhereChooser", "#148 SMS role in " + uid + " left to its holder ("
                            + (holders == null ? "unreadable" : "another app") + ")");
                    return "left";
                }
                if (!confirmed) { // a repair: look again before taking a role that may be changing hands
                    confirmed = true;
                    attempt--;
                    try { Thread.sleep(2000); } catch (InterruptedException ie) { return "failed"; }
                    continue;
                }
                if (declines == null) declines = self.equals(want) ? new java.util.ArrayList<>()
                        : PermDeclines.exceptSmsRole(PermDeclines.snapshot(uc, uh, want));
                final boolean[] ok = { false };
                final java.util.concurrent.CountDownLatch done = new java.util.concurrent.CountDownLatch(1);
                rm.addRoleHolderAsUser(android.app.role.RoleManager.ROLE_SMS, want,
                        android.app.role.RoleManager.MANAGE_HOLDERS_FLAG_DONT_KILL_APP, uh,
                        ex, r -> { ok[0] = r; done.countDown(); });
                boolean returned = done.await(2, java.util.concurrent.TimeUnit.SECONDS);
                android.util.Log.i("NowhereChooser", "#148 " + want + " default SMS in " + uid + " attempt " + attempt + ": ok=" + ok[0] + " returned=" + returned);
                if (ok[0]) {
                    PermDeclines.apply(uc, uh, want, declines, "sms role add");
                    return "held";
                }
                try { Thread.sleep(300); } catch (InterruptedException ie) { return "failed"; } // let the role service settle
            }
            android.util.Log.w("NowhereChooser", "#148 " + want + " is NOT default SMS in " + uid + " after 4 attempts");
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "#148 ensureHolder", t);
        }
        return "failed";
    }

    /** The session id the marker carries: this user's serial number, or null when it cannot be read (then no marker
     *  is written and nothing is captured -- the record is kept). A per-device counter: see the class comment. */
    static String sessionId(Context ctx) {
        try {
            long s = ctx.getSystemService(android.os.UserManager.class).getSerialNumberForUser(android.os.Process.myUserHandle());
            return s < 0 ? null : Long.toString(s);
        } catch (Throwable t) {
            return null;
        }
    }

    /** SIGN-IN, in the roamed user: give the SMS role to the profile's recorded app (smsSignInPlan), then write this
     *  session's marker so captures may run. Runs on CredentialService's worker thread ("smsrole" start). */
    static void applyAtSignIn(Context ctx) {
        // The capture lives in MessagingSuppressor: grant the listener every session, not only one with texts staged
        // (TelIngest.run grants it only when its mailbox has rows).
        TelIngest.ensureNotificationListener(ctx);
        boolean messaging;
        synchronized (LOCK) {
            final String self = ctx.getPackageName();
            final android.os.UserHandle me = android.os.Process.myUserHandle();
            final String session = sessionId(ctx);
            // NWP-20261123-23: a record that exists but cannot be read is UNKNOWN, not "no record". Messaging stands in
            // so texting works, and no marker is written, so nothing is captured this session and the record is kept.
            final java.io.File rf = new java.io.File(ctx.getFilesDir(), RECORD);
            final boolean isFile = rf.isFile();
            final long length = rf.length();
            final String content = read(ctx, RECORD);
            if (recordUnknown(isFile, length, content)) {
                ensureHolder(ctx, me, MESSAGING, true, self, ctx.getMainExecutor(), null);
                messaging = true;
                ChooserActivity.grantMessagingRestrictedRead(ctx); // #150: after the role settles
                android.util.Log.i("NowhereChooser", "NWP-20261010-13 sms role at sign-in: record unreadable -> Messaging"
                        + " stands in, no marker (NWP-20261123-23)");
            } else {
                final String record = parseSmsRecord(content);
                final String presence = record == null ? "absent" : presence(ctx, record);
                String[] plan = smsSignInPlan(record, presence, MESSAGING, self);
                String want = plan[0], state = plan[1], target = plan[2];
                String r = ensureHolder(ctx, me, want, true, self, ctx.getMainExecutor(), null);
                if (!"held".equals(r) && !MESSAGING.equals(want)) {
                    // The recorded app would not take the role (it no longer qualifies): Messaging, the record kept.
                    state = "fallback"; want = MESSAGING;
                    r = ensureHolder(ctx, me, want, true, self, ctx.getMainExecutor(), null);
                }
                messaging = MESSAGING.equals(want);
                if (messaging) ChooserActivity.grantMessagingRestrictedRead(ctx); // #150: after the role settles
                if (!"held".equals(r)) state = "fallback"; // nobody we meant holds it: the stand-in rule still keeps the record
                android.util.Log.i("NowhereChooser", "NWP-20261010-13 sms role at sign-in: record=" + (record == null ? "none" : record)
                        + " -> " + want + " (" + state + ", " + r + ")");
                if (session != null) write(ctx, MARKER, markerText(session, state, want, target));
            }
        }
        // #150: and again once the role machinery has settled -- a role-add can leave Messaging's restricted-read op at
        // "ignore", and the role controller can revert a grant made right after it (the gate's repair re-grants only at
        // +60 s, so without this an MMS can be unreadable in Messaging for a minute after sign-in).
        if (messaging) {
            try { Thread.sleep(4000); } catch (InterruptedException ie) { return; }
            ChooserActivity.grantMessagingRestrictedRead(ctx);
        }
        // NWP-20261012-05: the role step has run. Re-apply the profile's recorded declines to the SMS and dialer role
        // holders -- the role add above, or RoleService's own default-role grant if it landed first, can have granted
        // over them. What can still land after this is in PermDeclines' class comment.
        PermDeclines.reapplyRoleHolders(ctx, "sign-in role step");
    }

    /** CAPTURE, in the roamed user: record the SMS role's holder if it is a choice (smsCaptureValue). Called by
     *  MessagingSuppressor on every role change and at every listener connect. Nothing until this session's apply ran. */
    static void capture(Context ctx) {
        synchronized (LOCK) {
            final String self = ctx.getPackageName();
            final String session = sessionId(ctx);
            String[] m = parseMarker(read(ctx, MARKER), session);
            if (m == null) return;
            String holder = null;
            try {
                java.util.List<String> h = ctx.getSystemService(android.app.role.RoleManager.class)
                        .getRoleHolders(android.app.role.RoleManager.ROLE_SMS);
                holder = h == null || h.isEmpty() ? "" : h.get(0);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "NWP-20261010-13 sms role read", t);
            }
            String record = parseSmsRecord(read(ctx, RECORD));
            if (record != null && (MESSAGING.equals(holder) || "".equals(holder))) {
                String st = standInState(record, holder, MESSAGING, self, presence(ctx, record));
                if ("none".equals(st)) return; // PackageManager could not say: change nothing
                if (st != null) {
                    if (!st.equals(m[0]) || !record.equals(m[2])) {
                        write(ctx, MARKER, markerText(session, st, MESSAGING, record));
                        android.util.Log.i("NowhereChooser", "NWP-20261010-13 sms role: " + record + " is not installed -> "
                                + st + ", the record kept, Messaging stands in");
                    }
                    return;
                }
            }
            String v = smsCaptureValue(record, m[0], m[1], holder, MESSAGING, self);
            if (v == null) return;
            if (!write(ctx, RECORD, "app=" + v + "\n")) return;
            write(ctx, MARKER, markerText(session, "applied", v, v));
            android.util.Log.i("NowhereChooser", "NWP-20261010-13 sms role captured: " + v
                    + " (was " + (record == null ? "none" : record) + ")");
        }
    }

    /** An app just materialised (UnarchiveService.markOdRestored): if it is the recorded SMS app this session deferred
     *  or fell back from, give it the role now -- unless the user chose another app meanwhile (takeOverFromStandIn). */
    static void onMaterialised(Context ctx, String pkg) {
        new Thread(() -> {
            synchronized (LOCK) {
                try {
                    final String self = ctx.getPackageName();
                    final String session = sessionId(ctx);
                    String[] m = parseMarker(read(ctx, MARKER), session);
                    // NWP-20261012-08: on EVERY path that does not end with pkg holding the role, pkg gets its recorded
                    // declines of the six: in session, so only what the user has not answered (an update must not
                    // revoke a grant or harden a mid-session answer). The helper re-reads the holders and does nothing
                    // when they are unreadable or pkg is the holder.
                    if (m == null || "applied".equals(m[0]) || !m[2].equals(pkg)) { // not the app we wait for
                        PermDeclines.declineSmsRoleIfNotHolder(ctx, pkg, null, true, "sms role on materialise");
                        return;
                    }
                    java.util.List<String> holders = null;
                    try {
                        holders = ctx.getSystemService(android.app.role.RoleManager.class)
                                .getRoleHolders(android.app.role.RoleManager.ROLE_SMS);
                    } catch (Throwable ignore) {}
                    if (materialiseTarget(m, pkg, holders, self) == null) {
                        android.util.Log.i("NowhereChooser", "NWP-20261010-13 sms role: " + pkg
                                + " materialised, but another app holds the role -> left");
                        PermDeclines.declineSmsRoleIfNotHolder(ctx, pkg, holders, true, "sms role on materialise");
                        return;
                    }
                    String r = ensureHolder(ctx, android.os.Process.myUserHandle(), pkg, true, self, ctx.getMainExecutor(), m[1]);
                    android.util.Log.i("NowhereChooser", "NWP-20261010-13 sms role: " + pkg + " materialised -> " + r);
                    if ("held".equals(r)) {
                        write(ctx, MARKER, markerText(session, "applied", pkg, pkg));
                        // NWP-20261012-08: the stand-in that held the role until now was spared the six at login.
                        PermDeclines.declineSmsRoleIfNotHolder(ctx, m[1], null, true, "sms role taken over");
                    } else PermDeclines.declineSmsRoleIfNotHolder(ctx, pkg, null, true, "sms role on materialise");
                } catch (Throwable t) {
                    android.util.Log.w("NowhereChooser", "NWP-20261010-13 sms role on materialise", t);
                }
            }
        }, "nowhere-sms-materialised").start();
    }

    /** NWP-20261010-13 (round-6 review F3): the gate's delayed repair asks this user to retry a REFUSED sign-in apply
     *  (retryRefusedTarget). Repairs recur -- the sign-in's, the watcher's after a gate restart, the lift's on a
     *  SIM-ownership change -- and each retries while the state is still fallback (see the class comment, case 3).
     *  Runs on CredentialService's worker thread ("smsretry" start). */
    static void retryRefused(Context ctx) {
        synchronized (LOCK) {
            try {
                final String self = ctx.getPackageName();
                final String session = sessionId(ctx);
                String[] m = parseMarker(read(ctx, MARKER), session);
                if (m == null || !"fallback".equals(m[0])) return;
                java.util.List<String> holders = null;
                try {
                    holders = ctx.getSystemService(android.app.role.RoleManager.class)
                            .getRoleHolders(android.app.role.RoleManager.ROLE_SMS);
                } catch (Throwable ignore) {}
                String t = retryRefusedTarget(m, presence(ctx, m[2]), holders, MESSAGING);
                if (t == null) return;
                String r = ensureHolder(ctx, android.os.Process.myUserHandle(), t, true, self, ctx.getMainExecutor(), MESSAGING);
                android.util.Log.i("NowhereChooser", "NWP-20261010-13 sms role: refused " + t + " retried -> " + r);
                if ("held".equals(r)) {
                    write(ctx, MARKER, markerText(session, "applied", t, t));
                    // NWP-20261012-08: Messaging, the stand-in until now, was spared the six at login.
                    PermDeclines.declineSmsRoleIfNotHolder(ctx, MESSAGING, null, true, "sms role taken over");
                }
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "NWP-20261010-13 sms role retry", t);
            }
        }
    }

    /** NWP-20261010-13 (round-5 review F2): the recorded app's presence in this user, FAIL-CLOSED: "installed" (it has
     *  code), "archived" (an on-demand placeholder), "absent" (PackageManager positively says neither), or "unknown"
     *  for any failure that is not NameNotFoundException -- binder death, a stopped user -- which every caller reads
     *  as "do nothing". The house rule (ProfileActivity.pmKnows): a false negative here deletes the user's choice. */
    static String presence(Context ctx, String pkg) {
        final android.content.pm.PackageManager pm = ctx.getPackageManager();
        try {
            android.content.pm.ApplicationInfo ai = pm.getApplicationInfo(pkg, 0);
            if (ai != null && ai.sourceDir != null && !ai.sourceDir.isEmpty()) return "installed";
        } catch (android.content.pm.PackageManager.NameNotFoundException nf) {
            // not installed with code: the archive check decides
        } catch (Throwable t) {
            return "unknown";
        }
        try {
            return pm.getArchivedPackage(pkg) != null ? "archived" : "absent";
        } catch (Throwable t) {
            return "unknown";
        }
    }


    private static String read(Context ctx, String name) {
        java.io.File f = new java.io.File(ctx.getFilesDir(), name);
        if (!f.isFile() || f.length() > 4096) return null;
        try {
            return new String(java.nio.file.Files.readAllBytes(f.toPath()), java.nio.charset.StandardCharsets.UTF_8);
        } catch (Throwable t) {
            return null;
        }
    }

    /** Write name in the CE files dir through a temp file and a rename, so a seal never reads half a record. */
    private static boolean write(Context ctx, String name, String text) {
        java.io.File dir = ctx.getFilesDir(), tmp = new java.io.File(dir, name + ".tmp");
        try {
            java.nio.file.Files.write(tmp.toPath(), text.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            if (tmp.renameTo(new java.io.File(dir, name))) return true;
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "NWP-20261010-13 write " + name, t);
        }
        tmp.delete();
        return false;
    }
}
