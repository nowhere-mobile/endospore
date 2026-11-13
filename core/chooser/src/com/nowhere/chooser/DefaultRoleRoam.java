package com.nowhere.chooser;

import android.content.Context;

/**
 * NWP-20261202-05: THE DEFAULT APPS A USER CHOOSES ROAM WITH THE PROFILE -- the browser, phone, assistant, caller ID,
 * call redirection, wallet and notes roles (DefaultRoles.ROLES, those RoleManager.isRoleAvailable reports on this
 * image), by SmsRoleRoam's rules with a bundled holder standing in where SMS has Messaging. The rules, the record and
 * the marker are DefaultRoles'; this class only reads and writes Android state.
 *
 * Same owner and timing as SmsRoleRoam: the chooser in the roamed user. applyAtSignIn runs on CredentialService's
 * "smsrole" thread after SmsRoleRoam.applyAtSignIn (which grants the notification listener the capture rides on);
 * capture runs from MessagingSuppressor's role listener and at every listener connect; onMaterialised runs from
 * UnarchiveService.markOdRestored and AppInstallReceiver's ADDED arm. Unlike SMS, no record means the holder is left
 * alone, and a refused sign-in add is not retried this session: the next sign-in, or the app's next landing, tries
 * again.
 *
 * ⚠ NO LOG LINE NAMES AN APP OR A PROFILE: role words (DefaultRoles.roleWord), counts, user ids and outcomes only, and
 * no Throwable is passed to a log call (its message can name a package). core/chooser/tests/default-roles pins it.
 */
final class DefaultRoleRoam {
    private static final Object LOCK = new Object();

    private DefaultRoleRoam() {}

    /** The kind (DefaultRoles.kindOf) of pkg, fail-closed: "unknown" for a null pkg or any failure. */
    static String holderKind(Context ctx, String pkg) {
        if (pkg == null || pkg.isEmpty()) return DefaultRoles.kindOf(false, 0);
        try {
            return DefaultRoles.kindOf(true, ctx.getPackageManager().getApplicationInfo(pkg, 0).flags);
        } catch (Throwable t) {
            return DefaultRoles.kindOf(false, 0);
        }
    }

    /** {holder, kind}: holder "" for nobody, null when the holders could not be read. */
    static String[] holderOf(Context ctx, String role) {
        try {
            java.util.List<String> h = ctx.getSystemService(android.app.role.RoleManager.class).getRoleHolders(role);
            String holder = h == null || h.isEmpty() ? "" : h.get(0);
            return new String[]{holder, holderKind(ctx, holder)};
        } catch (Throwable t) {
            return new String[]{null, DefaultRoles.kindOf(false, 0)};
        }
    }

    /** SIGN-IN, in the roamed user: give each available role its recorded app (DefaultRoles.signInPlan), then write
     *  this session's marker so captures may run. */
    static void applyAtSignIn(Context ctx) {
        synchronized (LOCK) {
            try {
                final String self = ctx.getPackageName();
                final android.os.UserHandle me = android.os.Process.myUserHandle();
                final String session = SmsRoleRoam.sessionId(ctx);
                final java.io.File rf = new java.io.File(ctx.getFilesDir(), DefaultRoles.RECORD);
                final String content = read(ctx, DefaultRoles.RECORD);
                if (DefaultRoles.recordUnknown(rf.isFile(), rf.length(), content) || session == null) {
                    android.util.Log.i("NowhereChooser", "NWP-20261202-05 default roles at sign-in: record or session"
                            + " unreadable -> nothing applied, no marker");
                    return;
                }
                java.util.Map<String, String> rec = DefaultRoles.parseRecord(content);
                android.app.role.RoleManager rm = ctx.getSystemService(android.app.role.RoleManager.class);
                java.util.Map<String, String[]> marker = new java.util.LinkedHashMap<>();
                int applied = 0, deferred = 0, refused = 0, none = 0;
                for (String role : DefaultRoles.ROLES) {
                    if (rm == null || !rm.isRoleAvailable(role)) continue;
                    String record = rec.get(role);
                    String presence = record == null ? "absent" : SmsRoleRoam.presence(ctx, record);
                    String[] plan = DefaultRoles.signInPlan(record, presence, self);
                    String state = plan[1];
                    if (plan[0] != null) {
                        String r = ensureHolder(ctx, me, role, plan[0], false, self, ctx.getMainExecutor());
                        if (!"held".equals(r)) state = "fallback"; // the record kept, no retry this session
                    }
                    marker.put(role, new String[]{state, plan[2]});
                    if (record == null) none++;
                    else if ("fallback".equals(state)) refused++;
                    else if ("deferred".equals(state)) deferred++;
                    else applied++;
                }
                write(ctx, DefaultRoles.MARKER, DefaultRoles.markerText(session, marker));
                android.util.Log.i("NowhereChooser", DefaultRoles.summary(applied, deferred, refused, none));
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "NWP-20261202-05 default roles at sign-in: "
                        + t.getClass().getSimpleName());
            }
        }
    }

    /** CAPTURE, in the roamed user: record the role's holder if it is a choice (DefaultRoles.captureStep). Nothing
     *  until this session's apply ran for the role, and nothing while the record cannot be read
     *  (DefaultRoles.recordForCapture): the rewrite would keep only this role's line. */
    static void capture(Context ctx, String role) {
        if (!DefaultRoles.isRole(role)) return;
        synchronized (LOCK) {
            try {
                final String self = ctx.getPackageName();
                final String session = SmsRoleRoam.sessionId(ctx);
                java.util.Map<String, String[]> marker = DefaultRoles.parseMarker(read(ctx, DefaultRoles.MARKER), session);
                String[] m = marker == null ? null : marker.get(role);
                String[] h = holderOf(ctx, role);
                final java.io.File rf = new java.io.File(ctx.getFilesDir(), DefaultRoles.RECORD);
                java.util.Map<String, String> rec = DefaultRoles.recordForCapture(rf.isFile(), rf.length(),
                        read(ctx, DefaultRoles.RECORD));
                if (rec == null) {
                    android.util.Log.w("NowhereChooser", "NWP-20261202-05 default role " + DefaultRoles.roleWord(role)
                            + ": record unreadable -> nothing captured, every role's record kept");
                    return;
                }
                String record = rec.get(role);
                String presence = record == null ? null : SmsRoleRoam.presence(ctx, record);
                String[] step = DefaultRoles.captureStep(m, record, h[0], h[1], self, presence);
                if (step == null) return;
                if ("defer".equals(step[0])) {
                    marker.put(role, new String[]{"deferred", step[1]});
                    write(ctx, DefaultRoles.MARKER, DefaultRoles.markerText(session, marker));
                    android.util.Log.i("NowhereChooser", "NWP-20261202-05 default role " + DefaultRoles.roleWord(role)
                            + ": the recorded app is not installed -> deferred, the record kept");
                    return;
                }
                rec.put(role, step[1]);
                if (!write(ctx, DefaultRoles.RECORD, DefaultRoles.recordText(rec))) return;
                marker.put(role, new String[]{"applied", step[1]});
                write(ctx, DefaultRoles.MARKER, DefaultRoles.markerText(session, marker));
                android.util.Log.i("NowhereChooser", "NWP-20261202-05 default role " + DefaultRoles.roleWord(role)
                        + " captured");
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "NWP-20261202-05 default role capture: "
                        + t.getClass().getSimpleName());
            }
        }
    }

    /** An app just landed (an On-demand materialise, an Auto install, a store install): every role this session
     *  deferred or fell back to it takes it back -- unless a user app holds the role (DefaultRoles.materialiseTarget). */
    static void onMaterialised(Context ctx, String pkg) {
        new Thread(() -> {
            synchronized (LOCK) {
                try {
                    final String self = ctx.getPackageName();
                    final String session = SmsRoleRoam.sessionId(ctx);
                    java.util.Map<String, String[]> marker = DefaultRoles.parseMarker(read(ctx, DefaultRoles.MARKER), session);
                    if (marker == null) return;
                    boolean changed = false;
                    for (String role : DefaultRoles.ROLES) {
                        String[] m = marker.get(role);
                        if (m == null || "applied".equals(m[0]) || !m[1].equals(pkg)) continue;
                        java.util.List<String> holders = null;
                        try {
                            holders = ctx.getSystemService(android.app.role.RoleManager.class).getRoleHolders(role);
                        } catch (Throwable ignore) { /* null: materialiseTarget leaves the role */ }
                        String kind = holderKind(ctx, holders == null || holders.isEmpty() ? null : holders.get(0));
                        if (DefaultRoles.materialiseTarget(m, pkg, holders, kind, self) == null) {
                            android.util.Log.i("NowhereChooser", "NWP-20261202-05 default role " + DefaultRoles.roleWord(role)
                                    + ": the recorded app landed, another app holds the role -> left");
                            continue;
                        }
                        String r = ensureHolder(ctx, android.os.Process.myUserHandle(), role, pkg, true, self,
                                ctx.getMainExecutor());
                        android.util.Log.i("NowhereChooser", "NWP-20261202-05 default role " + DefaultRoles.roleWord(role)
                                + ": the recorded app landed -> " + r);
                        if ("held".equals(r)) {
                            marker.put(role, new String[]{"applied", pkg});
                            changed = true;
                        }
                    }
                    if (changed) write(ctx, DefaultRoles.MARKER, DefaultRoles.markerText(session, marker));
                } catch (Throwable t) {
                    android.util.Log.w("NowhereChooser", "NWP-20261202-05 default roles on landing: "
                            + t.getClass().getSimpleName());
                }
            }
        }, "nowhere-roles-materialised").start();
    }

    /** SmsRoleRoam.ensureHolder's loop for one role: make want its holder in user uh, and know that it is. Each attempt
     *  reads the holders and the first holder's kind again; takeover=true applies DefaultRoles.takeoverStep (never over
     *  a user app), else DefaultRoles.signInStep. Returns "held", "left" or "failed". uc is a context in user uh; the
     *  callback runs on ex, so this must never run on the thread ex runs on. Bounded: 4 x (2 s + 0.3 s). The add
     *  can grant over the profile's declines: want's live declines are snapshotted before the first add and put back
     *  once it holds the role (PermDeclines, NWP-20261012-05). */
    static String ensureHolder(Context uc, android.os.UserHandle uh, String role, String want, boolean takeover,
                               String self, java.util.concurrent.Executor ex) {
        final int uid = uh.getIdentifier();
        final String word = DefaultRoles.roleWord(role);
        try {
            android.app.role.RoleManager rm = uc.getSystemService(android.app.role.RoleManager.class);
            if (rm == null || !rm.isRoleAvailable(role)) {
                android.util.Log.w("NowhereChooser", "NWP-20261202-05 role " + word + " unavailable in " + uid);
                return "failed";
            }
            java.util.List<String[]> declines = null;
            for (int attempt = 1; attempt <= 4; attempt++) {
                java.util.List<String> holders = null;
                try {
                    holders = rm.getRoleHoldersAsUser(role, uh);
                } catch (Throwable ignore) { /* getRoleHoldersAsUser may be restricted -> the step reads null */ }
                String step;
                if (takeover) {
                    String kind = holderKind(uc, holders == null || holders.isEmpty() ? null : holders.get(0));
                    step = DefaultRoles.takeoverStep(holders, kind, self, want);
                } else {
                    step = DefaultRoles.signInStep(holders, want);
                }
                if ("held".equals(step)) {
                    android.util.Log.i("NowhereChooser", "NWP-20261202-05 role " + word + " held in " + uid
                            + " (verified, attempt " + attempt + ")");
                    if (declines != null) PermDeclines.apply(uc, uh, want, declines, "default role add"); // a late add
                    return "held";
                }
                if ("leave".equals(step)) {
                    android.util.Log.i("NowhereChooser", "NWP-20261202-05 role " + word + " in " + uid + " left to its holder ("
                            + (holders == null ? "unreadable" : "another app") + ")");
                    return "left";
                }
                if (declines == null) declines = self.equals(want) ? new java.util.ArrayList<>()
                        : PermDeclines.snapshot(uc, uh, want);
                final boolean[] ok = { false };
                final java.util.concurrent.CountDownLatch done = new java.util.concurrent.CountDownLatch(1);
                rm.addRoleHolderAsUser(role, want, android.app.role.RoleManager.MANAGE_HOLDERS_FLAG_DONT_KILL_APP, uh,
                        ex, r -> { ok[0] = r; done.countDown(); });
                boolean returned = done.await(2, java.util.concurrent.TimeUnit.SECONDS);
                android.util.Log.i("NowhereChooser", "NWP-20261202-05 role " + word + " in " + uid + " attempt " + attempt
                        + ": ok=" + ok[0] + " returned=" + returned);
                if (ok[0]) {
                    PermDeclines.apply(uc, uh, want, declines, "default role add");
                    return "held";
                }
                try { Thread.sleep(300); } catch (InterruptedException ie) { return "failed"; } // let the role service settle
            }
            android.util.Log.w("NowhereChooser", "NWP-20261202-05 role " + word + " NOT held in " + uid + " after 4 attempts");
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "NWP-20261202-05 role " + word + " ensureHolder: "
                    + t.getClass().getSimpleName());
        }
        return "failed";
    }

    private static String read(Context ctx, String name) {
        java.io.File f = new java.io.File(ctx.getFilesDir(), name);
        if (!f.isFile() || f.length() > DefaultRoles.CAP) return null;
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
            android.util.Log.w("NowhereChooser", "NWP-20261202-05 write " + name + ": " + t.getClass().getSimpleName());
        }
        tmp.delete();
        return false;
    }
}
