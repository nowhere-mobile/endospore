package com.nowhere.chooser;

import android.content.Context;

/**
 * NWP-20261012-05: A PERMISSION THE USER DECLINED STAYS DECLINED WITH THE PROFILE (docs/product-decisions.md,
 * 2026-10-12). It only ever withholds a grant, never adds one.
 *
 * The platform re-prompts for a permission that is not granted AND carries neither USER_SET nor USER_FIXED, and a fresh
 * user's not-granted permission carries neither. So capturePerms records a decline as `pkg flags:<word>:<perm>` in
 * files/nowhere-perms (the word is user-set, user-fixed or user-set,user-fixed), and roamd's grant_perms_for puts it
 * back at login and at an on-demand app's first materialise. This class is the chooser's half:
 *
 *   - declinedWord: the one definition of "declined", shared by the capture and the live snapshot below.
 *   - A ROLE ADD UNDOES A DECLINE. The SMS and dialer roles are overrideUserWhenGranting="true" (PermissionController
 *     roles.xml), and Permissions.grantSingleAsUser grants every role permission that was not granted and then CLEARS
 *     USER_SET and USER_FIXED -- so the role apply at sign-in (SmsRoleRoam.ensureHolder, which runs after roamd's
 *     grant pass) re-granted every permission the profile had declined for its SMS app, and wiped the record of the
 *     refusal so the next capture lost it too. ensureHolder therefore snapshots the target's LIVE declines before it
 *     adds the role and applies them again after (snapshot + apply), and the sign-in apply re-applies the profile's
 *     recorded declines to whoever holds the SMS and dialer roles once its role step has run (reapplyRoleHolders),
 *     which also catches RoleService's own default-role grant if it landed first.
 *   - apply sets the flags FIRST and revokes SECOND. A revoke does not touch the user flags, and once USER_FIXED or
 *     USER_SET is set a grant that does not override the user (override=false) stops at it.
 *
 * ⚠ WHAT STAYS RACY, AND HOW NARROWLY: RoleService's re-grant to a role's CURRENT holders (RoleControllerServiceImpl
 * onGrantDefaultRoles, run on PACKAGE_ADDED among others) uses override=false, so it stops at USER_SET / USER_FIXED --
 * which is why apply sets them first. Only a default or fallback holder ADDED to a role that has NO holder grants with
 * the role's overrideUserWhenGranting, true for SMS and dialer. If such an add lands after reapplyRoleHolders -- the
 * role left empty and refilled later in the session -- it re-grants and clears the flags, and nothing here sees it
 * until the capture. The capture keeps the decline on record for EVERY permission whose live state carries neither
 * user flag (NWP-20261102-10, Q059, docs/product-decisions.md 2026-10-20), so the re-grant lasts only the rest of that
 * session -- a window accepted in writing -- and the next sign-in declines it again. Nothing revokes in session. (This
 * supersedes the earlier "if the capture did not already record the grant": the capture no longer records it.)
 *
 * ⚠ THE ONE EXCEPTION: THE SMS APP KEEPS ITS SMS PERMISSIONS (NWP-20261012-08). Chester, 2026-10-12: "yes keep the
 * read_sms access"; and asked on 2026-10-13 which of the six permissions the SMS role grants it keeps: "All six". The
 * app holding the profile's SMS role keeps the six permissions the SMS role grants (the role's `sms` permission-set,
 * PermissionController roles.xml) even if the profile recorded them declined: SMS_ROLE_PERMS, exactly READ_SMS,
 * RECEIVE_SMS, RECEIVE_MMS, RECEIVE_WAP_PUSH, SEND_SMS and READ_CELL_BROADCASTS. Every other decline of that app --
 * contacts, location, notifications, camera, phone -- stays declined, and only the SMS ROLE holder is exempt: not the
 * dialer holder, not another app that requests READ_SMS. The rule, on every path:
 *   - CAPTURE STILL RECORDS THE DECLINE. The role grant clears USER_SET / USER_FIXED, so the app's live state reads
 *     "granted, never answered", and recording that would lose the refusal for good. So for one of the six with
 *     NEITHER user flag, whatever its grant state and whichever app it is, the capture carries a decline already on
 *     record forward. Since NWP-20261102-10 (Q059) that carry is not limited to the six: it covers every permission
 *     (carriedDecline / keptDecline), because a mid-session fill of an empty dialer or SMS role re-grants any of them.
 *     The user answering anything sets a flag and wins. The SMS app's six therefore come back the first login the app
 *     is no longer the SMS app; every other carried decline comes back at the next sign-in.
 *   - APPLY SKIPS IT ONLY FOR THE APP THAT HOLDS THE ROLE. roamd runs before the role step and cannot see the role, so
 *     at login and at a first materialise it leaves the six's declines of the sign-in's two possible holders -- the
 *     recorded app (nowhere-sms) and Messaging, its stand-in (smsCandidates; roamd mirrors it) -- entirely alone:
 *     no flags, no revoke. A role already held from user creation therefore keeps its grant (no add re-grants it,
 *     which is why the revoke cannot simply be undone afterwards: the chooser holds no GRANT_RUNTIME_PERMISSIONS, and
 *     the six are hard-restricted).
 *     The role add's snapshot and apply (SmsRoleRoam.ensureHolder) skip them (exceptSmsRole). After the sign-in role
 *     step, reapplyRoleHolders applies them to whichever candidate did NOT end up holding the role (onlySmsRole), and
 *     skips them only for the holder.
 *   - IN SESSION, an app that is not the holder gets the six's declines too, at three points: every onMaterialised
 *     call (an install or update) that does not end with that app holding the role, and the stand-in after a takeover
 *     moves the role off it (onMaterialised, retryRefused). In session a decline touches only what the user has NOT
 *     answered (unanswered: not granted, no USER_SET / USER_FIXED): it never revokes a grant (a revoke kills the app
 *     on GrapheneOS, and the grant may be the user's own mid-session answer) and never hardens a mid-session "Don't
 *     allow" into the login-time USER_FIXED. It is not limited to smsCandidates (declineSmsRoleIfNotHolder says why).
 *     A grant that stands is recorded by the capture as above and declined at the next sign-in. A holder the user
 *     picks in session is granted by Android.
 *
 * Applying needs REVOKE_RUNTIME_PERMISSIONS (updatePermissionFlags accepts GRANT_ or REVOKE_; revokeRuntimePermission
 * needs REVOKE_); reading needs GET_RUNTIME_PERMISSIONS. Both are signature-level and come from the platform cert
 * (AndroidManifest.xml). Every failure is counted and logged with its reason, never swallowed.
 */
final class PermDeclines {
    private PermDeclines() {}

    // ---- PURE (java.lang/java.util only): lifted and run by core/chooser/tests/perm-declines/run.sh ----

    /** The flag word for a declined permission, or null when neither flag is set (never answered). */
    static String flagWord(boolean userSet, boolean userFixed) {
        if (userSet) return userFixed ? "user-set,user-fixed" : "user-set";
        return userFixed ? "user-fixed" : null;
    }

    /** A flag word as bits (1 = user-set, 2 = user-fixed), or 0 when roamd's allowlist would refuse it. */
    static int wordBits(String w) {
        if ("user-set".equals(w)) return 1;
        if ("user-fixed".equals(w)) return 2;
        if ("user-set,user-fixed".equals(w)) return 3;
        return 0;
    }

    /** roamd's name check: non-empty, starts with a letter, only [A-Za-z0-9._] -- nothing pm could read as an option. */
    static boolean plainName(String s) {
        if (s == null || s.isEmpty()) return false;
        char c0 = s.charAt(0);
        if (!((c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z'))) return false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            boolean ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_';
            if (!ok) return false;
        }
        return true;
    }

    /** The declines of pkg in nowhere-perms text, as {perm, word}: exactly the lines roamd's declined pass honours.
     *  Same split as its `read -r gpkg gperm` (the first field, then the rest with surrounding blanks trimmed), same
     *  allowlist, INTERNET refused (its channel is `deny:`), and an unterminated last line ignored as `read` does. */
    static java.util.List<String[]> parse(String text, String pkg) {
        java.util.List<String[]> out = new java.util.ArrayList<>();
        if (text == null || pkg == null) return out;
        int end = text.lastIndexOf('\n');
        if (end < 0) return out;
        for (String ln : text.substring(0, end).split("\n", -1)) {
            String t = ln.replaceAll("^[ \t]+|[ \t]+$", "");
            String[] f = t.split("[ \t]+", 2);
            if (f.length != 2 || !f[0].equals(pkg) || !f[1].startsWith("flags:")) continue;
            String rest = f[1].substring("flags:".length());
            int c = rest.indexOf(':');
            if (c < 0) continue;
            String word = rest.substring(0, c), perm = rest.substring(c + 1);
            if (wordBits(word) == 0 || !plainName(perm) || !plainName(pkg)
                    || "android.permission.INTERNET".equals(perm)) continue;
            out.add(new String[] { perm, word });
        }
        return out;
    }

    /** A carried-forward line of an app that was MATERIALISED this session and is a placeholder again: its `flags:`
     *  line with any user-fixed SOFTENED to user-set, or null for any other line (its grants are not carried). Its live
     *  state was the authority this session and the capture could not read it, so the decline is kept but not fixed:
     *  with USER_FIXED the app could not ask again at all and only Settings could undo a decline the user may have
     *  reversed while it was materialised; with USER_SET the platform does not prompt by itself, but the app still can. */
    static String softenedDecline(String line, String pkg) {
        if (line == null || pkg == null) return null;
        String prefix = pkg + " flags:";
        if (!line.startsWith(prefix)) return null;
        String rest = line.substring(prefix.length());
        int c = rest.indexOf(':');
        if (c < 0 || wordBits(rest.substring(0, c)) == 0) return null;
        return prefix + "user-set" + rest.substring(c);
    }

    /** NWP-20261012-08: the six permissions the SMS role grants, which its holder keeps over a recorded decline (class
     *  comment; Chester 2026-10-13: "All six"). roamd's grant_perms_for carries the same six names; keep the two lists
     *  equal (test-grant-declined-flags.sh P1). */
    static final String[] SMS_ROLE_PERMS = {
        "android.permission.READ_SMS", "android.permission.RECEIVE_SMS", "android.permission.RECEIVE_MMS",
        "android.permission.RECEIVE_WAP_PUSH", "android.permission.SEND_SMS", "android.permission.READ_CELL_BROADCASTS",
    };

    static boolean smsRolePerm(String perm) {
        for (String p : SMS_ROLE_PERMS) if (p.equals(perm)) return true;
        return false;
    }

    /** The declines without the SMS-role permissions: what is applied to the app that holds the SMS role. */
    static java.util.List<String[]> exceptSmsRole(java.util.List<String[]> declines) {
        java.util.List<String[]> out = new java.util.ArrayList<>();
        if (declines != null) for (String[] d : declines) if (!smsRolePerm(d[0])) out.add(d);
        return out;
    }

    /** Only the SMS-role permissions of the declines: what roamd left alone for a candidate that did not get the role. */
    static java.util.List<String[]> onlySmsRole(java.util.List<String[]> declines) {
        java.util.List<String[]> out = new java.util.ArrayList<>();
        if (declines != null) for (String[] d : declines) if (smsRolePerm(d[0])) out.add(d);
        return out;
    }

    /** The apps that can hold the SMS role once the sign-in apply has run, so the apps roamd exempts: Messaging (the
     *  default and the stand-in) and the recorded app (SmsRoleRoam.parseSmsRecord's answer; null = no record), unless
     *  that is the chooser. roamd's grant_perms_for derives the same two from the same file. */
    static java.util.List<String> smsCandidates(String recorded, String self, String messaging) {
        java.util.List<String> out = new java.util.ArrayList<>();
        out.add(messaging);
        if (recorded != null && !recorded.equals(self) && !recorded.equals(messaging)) out.add(recorded);
        return out;
    }

    /** The word of pkg's `flags:` line for perm among lines (one file line each, no newline), or null. */
    static String oldDeclineWord(java.util.List<String> lines, String pkg, String perm) {
        if (lines == null || pkg == null || perm == null) return null;
        String prefix = pkg + " flags:", suffix = ":" + perm;
        for (String ln : lines) {
            if (ln == null || !ln.startsWith(prefix) || !ln.endsWith(suffix)) continue;
            int end = ln.length() - suffix.length();
            if (end < prefix.length()) continue;
            String w = ln.substring(prefix.length(), end);
            if (wordBits(w) != 0) return w;
        }
        return null;
    }

    /** What a capture writes for ANY permission the login-time file recorded declined as oldWord (Q059, NWP-20261102-10):
     *  that decline again while the live state carries NEITHER user flag (a role grant cleared them, or roamd left it to
     *  the role), else null and the capture records the live state. A flag means the user answered, so the live state
     *  wins; perm is not consulted -- every permission is treated alike. Only ever withholds; nothing revokes. */
    static String keptDecline(String perm, boolean userSet, boolean userFixed, String oldWord) {
        if (userSet || userFixed || wordBits(oldWord) == 0) return null;
        return oldWord;
    }

    // ---- END PURE ----

    /** A failure tally: how many reads or writes threw, and the first reason. */
    static final class Fails {
        int n;
        Throwable first;
        void add(Throwable t) { n++; if (first == null) first = t; }
    }

    /** The decline word for one requested permission that is NOT granted, or null when it is not a declined dangerous
     *  permission. Not dangerous, defined by nothing on this device, never answered, or AUTO_REVOKED (hibernation took
     *  it: that is not the user declining) -> null. Any other failure is counted in fails, never swallowed. */
    static String declinedWord(android.content.pm.PackageManager pm, String pkg, String perm,
                               android.os.UserHandle user, Fails fails) {
        try {
            if (pm.getPermissionInfo(perm, 0).getProtection()
                    != android.content.pm.PermissionInfo.PROTECTION_DANGEROUS) return null;
        } catch (android.content.pm.PackageManager.NameNotFoundException undefined) {
            return null; // requested but defined by nothing on this device: nothing to decline
        } catch (Throwable t) {
            fails.add(t);
            return null;
        }
        int pflags;
        try {
            pflags = pm.getPermissionFlags(perm, pkg, user);
        } catch (Throwable t) {
            // Without GET_RUNTIME_PERMISSIONS this throws SecurityException for every permission.
            fails.add(t);
            return null;
        }
        if ((pflags & android.content.pm.PackageManager.FLAG_PERMISSION_AUTO_REVOKED) != 0) return null;
        return flagWord((pflags & android.content.pm.PackageManager.FLAG_PERMISSION_USER_SET) != 0,
                (pflags & android.content.pm.PackageManager.FLAG_PERMISSION_USER_FIXED) != 0);
    }

    /** pkg's LIVE declines in user uh, as {perm, word}. Empty when it has none or cannot be read (logged). */
    static java.util.List<String[]> snapshot(Context uc, android.os.UserHandle uh, String pkg) {
        java.util.List<String[]> out = new java.util.ArrayList<>();
        Fails fails = new Fails();
        try {
            android.content.pm.PackageManager pm = uc.getPackageManager();
            android.content.pm.PackageInfo pi = pm.getPackageInfo(pkg, android.content.pm.PackageManager.GET_PERMISSIONS);
            if (pi.requestedPermissions != null) {
                for (int i = 0; i < pi.requestedPermissions.length; i++) {
                    String perm = pi.requestedPermissions[i];
                    if ((pi.requestedPermissionsFlags[i]
                            & android.content.pm.PackageInfo.REQUESTED_PERMISSION_GRANTED) != 0) continue;
                    if ("android.permission.INTERNET".equals(perm)) continue;
                    String w = declinedWord(pm, pkg, perm, uh, fails);
                    if (w != null) out.add(new String[] { perm, w });
                }
            }
        } catch (Throwable t) {
            fails.add(t);
        }
        if (fails.n > 0)
            android.util.Log.w("NowhereChooser", "declines snapshot " + pkg + ": " + fails.n + " read(s) FAILED -- a role"
                    + " add can re-grant what those cover (NWP-20261012-05)", fails.first);
        return out;
    }

    /** pkg's declines as recorded in this user's files/nowhere-perms (the login-time file). */
    static java.util.List<String[]> fromFile(Context ctx, String pkg) {
        try {
            byte[] b = java.nio.file.Files.readAllBytes(
                    java.nio.file.Paths.get(ctx.getFilesDir().getPath(), "nowhere-perms"));
            return parse(new String(b, java.nio.charset.StandardCharsets.UTF_8), pkg);
        } catch (java.nio.file.NoSuchFileException none) {
            return new java.util.ArrayList<>();
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "declines read nowhere-perms FAILED for " + pkg + " (NWP-20261012-05)", t);
            return new java.util.ArrayList<>();
        }
    }

    /** Put pkg's declines back in user uh: the flags FIRST, then the revoke. Returns how many were applied. A refused
     *  revoke (a fixed permission) still leaves the flags, which only ever suppress a prompt. */
    static int apply(Context uc, android.os.UserHandle uh, String pkg, java.util.List<String[]> declines, String why) {
        if (declines == null || declines.isEmpty() || pkg == null || !plainName(pkg)) return 0;
        android.content.pm.PackageManager pm = uc.getPackageManager();
        int ok = 0;
        Fails flagFails = new Fails(), revokeFails = new Fails();
        for (String[] d : declines) {
            int bits = wordBits(d[1]);
            if (bits == 0 || !plainName(d[0])) continue;
            int mask = ((bits & 1) != 0 ? android.content.pm.PackageManager.FLAG_PERMISSION_USER_SET : 0)
                    | ((bits & 2) != 0 ? android.content.pm.PackageManager.FLAG_PERMISSION_USER_FIXED : 0);
            try {
                pm.updatePermissionFlags(d[0], pkg, mask, mask, uh);
            } catch (Throwable t) {
                flagFails.add(t);
                continue;
            }
            ok++;
            try {
                pm.revokeRuntimePermission(pkg, d[0], uh);
            } catch (Throwable t) {
                revokeFails.add(t);
            }
        }
        android.util.Log.i("NowhereChooser", "declines re-applied after " + why + ": " + pkg + " user "
                + uh.getIdentifier() + " -> " + ok + " kept, " + flagFails.n + " flag write(s) failed, "
                + revokeFails.n + " revoke(s) refused (NWP-20261012-05)");
        if (flagFails.n > 0)
            android.util.Log.w("NowhereChooser", "declines " + pkg + ": " + flagFails.n + " flag write(s) FAILED -- those"
                    + " permissions may be asked again (is REVOKE_RUNTIME_PERMISSIONS granted?)", flagFails.first);
        if (revokeFails.n > 0)
            android.util.Log.w("NowhereChooser", "declines " + pkg + ": " + revokeFails.n + " revoke(s) refused", revokeFails.first);
        return ok;
    }

    /** NWP-20261012-08, widened to every permission by NWP-20261102-10 (Q059): the decline a capture keeps for perm of
     *  pkg (keptDecline), reading the live user flags. oldLines are pkg's lines of the login-time file. A permission
     *  that is not dangerous, or that nothing on this device defines, is never carried (the capture records neither).
     *  A read that fails is counted and keeps the old decline: the carry only ever withholds. A caller whose own read
     *  of the same flags already failed (and was counted) uses oldDeclineWord instead, so one failure is counted once. */
    static String carriedDecline(android.content.pm.PackageManager pm, String pkg, String perm, android.os.UserHandle user,
                                 java.util.List<String> oldLines, Fails fails) {
        String old = oldDeclineWord(oldLines, pkg, perm);
        if (old == null) return null;
        try {
            if (pm.getPermissionInfo(perm, 0).getProtection()
                    != android.content.pm.PermissionInfo.PROTECTION_DANGEROUS) return null;
        } catch (android.content.pm.PackageManager.NameNotFoundException undefined) {
            return null;
        } catch (Throwable t) {
            fails.add(t);
            return old;
        }
        int f;
        try {
            f = pm.getPermissionFlags(perm, pkg, user);
        } catch (Throwable t) {
            fails.add(t);
            return old;
        }
        return keptDecline(perm, (f & android.content.pm.PackageManager.FLAG_PERMISSION_USER_SET) != 0,
                (f & android.content.pm.PackageManager.FLAG_PERMISSION_USER_FIXED) != 0, old);
    }

    /** The package this user's nowhere-sms records (SmsRoleRoam.parseSmsRecord), or null for none or unreadable. */
    static String recordedSmsApp(Context ctx) {
        try {
            java.io.File f = new java.io.File(ctx.getFilesDir(), SmsRoleRoam.RECORD);
            if (!f.isFile() || f.length() > 4096) return null;
            return SmsRoleRoam.parseSmsRecord(new String(java.nio.file.Files.readAllBytes(f.toPath()),
                    java.nio.charset.StandardCharsets.UTF_8));
        } catch (Throwable t) {
            return null;
        }
    }

    /** NWP-20261012-08: an SMS candidate roamd left alone that did not end up holding the SMS role gets its recorded
     *  SMS-role declines now. Only an INSTALLED app (a placeholder has nothing to decline), never the chooser, never the
     *  holder. smsHolders null: read them here, and decline nothing if they cannot be read (the app may hold the role).
     *  At the sign-in step (inSession false) only an smsCandidates app, the two roamd spared, and it revokes as roamd's
     *  pass would. inSession (every other caller): ANY app with a recorded decline of the six, but only what it has not
     *  answered (unanswered) -- not granted and carrying no user flag -- so it never revokes a grant and never hardens a
     *  mid-session answer. The candidate gate is dropped in session on purpose: the app roamd spared at login is the
     *  login-time record, and nothing in the chooser still holds that once the user switches the SMS app (capture
     *  rewrites nowhere-sms and moves the marker's target to the new app), so gating on today's record or the marker
     *  would miss the app that lost the role. An app roamd did decline at login already carries the flags, so
     *  unanswered leaves it alone; widening the set changes nothing for it. */
    static void declineSmsRoleIfNotHolder(Context ctx, String pkg, java.util.List<String> smsHolders, boolean inSession,
                                          String why) {
        if (pkg == null || pkg.equals(ctx.getPackageName())) return;
        if (smsHolders == null) {
            try {
                smsHolders = ctx.getSystemService(android.app.role.RoleManager.class)
                        .getRoleHolders(android.app.role.RoleManager.ROLE_SMS);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "declines: SMS role holders unreadable after " + why
                        + " -- " + pkg + " keeps its SMS permissions this session (NWP-20261012-08)", t);
                return;
            }
            if (smsHolders == null) return;
        }
        if (smsHolders.contains(pkg)) return;
        if (!inSession && !smsCandidates(recordedSmsApp(ctx), ctx.getPackageName(), SmsRoleRoam.MESSAGING).contains(pkg)) return;
        if (!"installed".equals(SmsRoleRoam.presence(ctx, pkg))) return;
        java.util.List<String[]> d = onlySmsRole(fromFile(ctx, pkg));
        if (inSession) d = unanswered(ctx, pkg, d);
        if (!d.isEmpty()) apply(ctx, android.os.Process.myUserHandle(), pkg, d, why + " (not the SMS app)");
    }

    /** The declines among d the user has NOT answered in this user now: not granted, and neither USER_SET nor
     *  USER_FIXED. A granted one is left (a revoke kills the app on GrapheneOS, and the grant may be the user's own);
     *  an answered one too, because apply only ADDS the recorded flag bits, so it would turn a mid-session "Don't allow"
     *  (USER_SET) into the login-time USER_FIXED and the app could never ask again. A check or flag read that fails
     *  drops that permission: in session nothing is changed on a guess. ⚠ Not atomic with apply: a grant the user makes
     *  in the milliseconds between this check and apply's revoke is revoked (and the app killed); accepted as
     *  negligible. */
    static java.util.List<String[]> unanswered(Context ctx, String pkg, java.util.List<String[]> d) {
        java.util.List<String[]> out = new java.util.ArrayList<>();
        android.content.pm.PackageManager pm = ctx.getPackageManager();
        final android.os.UserHandle me = android.os.Process.myUserHandle();
        final int answered = android.content.pm.PackageManager.FLAG_PERMISSION_USER_SET
                | android.content.pm.PackageManager.FLAG_PERMISSION_USER_FIXED;
        Fails fails = new Fails();
        for (String[] x : d) {
            try {
                if (pm.checkPermission(x[0], pkg) == android.content.pm.PackageManager.PERMISSION_GRANTED) continue;
                if ((pm.getPermissionFlags(x[0], pkg, me) & answered) != 0) continue;
                out.add(x);
            } catch (Throwable t) {
                fails.add(t);
            }
        }
        if (fails.n > 0)
            android.util.Log.w("NowhereChooser", "declines " + pkg + ": " + fails.n + " grant or flag read(s) FAILED --"
                    + " left alone this session (NWP-20261012-08)", fails.first);
        return out;
    }

    /** After the sign-in role step: re-apply the profile's recorded declines to whoever holds the SMS and dialer roles
     *  in this user -- the two roles that override the user when granting -- except, for the SMS holder, the SMS-role
     *  permissions it keeps (NWP-20261012-08); then decline those for the SMS candidate roamd left alone that did not
     *  get the role. Runs in the roamed user's chooser. */
    static void reapplyRoleHolders(Context ctx, String why) {
        final String self = ctx.getPackageName();
        final android.os.UserHandle me = android.os.Process.myUserHandle();
        java.util.LinkedHashSet<String> holders = new java.util.LinkedHashSet<>();
        java.util.List<String> sms = new java.util.ArrayList<>();
        try {
            android.app.role.RoleManager rm = ctx.getSystemService(android.app.role.RoleManager.class);
            for (String role : new String[] { android.app.role.RoleManager.ROLE_SMS, android.app.role.RoleManager.ROLE_DIALER }) {
                if (rm == null || !rm.isRoleAvailable(role)) continue;
                java.util.List<String> h = rm.getRoleHolders(role);
                if (h == null) continue;
                holders.addAll(h);
                if (android.app.role.RoleManager.ROLE_SMS.equals(role)) sms.addAll(h);
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "declines: role holders unreadable after " + why
                    + " -- a role grant may stand over a decline (NWP-20261012-05)", t);
            return;
        }
        for (String h : holders) {
            if (h == null || h.equals(self)) continue;
            java.util.List<String[]> d = fromFile(ctx, h);
            if (sms.contains(h)) d = exceptSmsRole(d); // NWP-20261012-08: the SMS app keeps its SMS permissions
            if (!d.isEmpty()) apply(ctx, me, h, d, why);
        }
        for (String c : smsCandidates(recordedSmsApp(ctx), self, SmsRoleRoam.MESSAGING)) {
            if (holders.contains(c)) continue; // a dialer holder had all its declines above
            declineSmsRoleIfNotHolder(ctx, c, sms, false, why); // the sign-in step: revokes, as roamd's pass would
        }
    }
}
