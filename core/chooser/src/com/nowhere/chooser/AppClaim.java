package com.nowhere.chooser;

import android.content.Context;
import android.content.pm.PackageManager;
import android.content.pm.SuspendDialogInfo;
import android.util.Log;

import java.io.File;

/**
 * NWP-20260910-24 — refuse to open an app another handset is holding, and say so in our own words.
 *
 * THE PRODUCT RULE THIS SERVES. `docs/product-decisions.md` (2026-09-08, DECIDED): one profile across devices,
 * and concurrency arbitrated PER APP rather than per account — an app in use on one device is NOT LAUNCHABLE
 * on another. This class is the ENFORCEMENT half of that, and only that: it holds and releases. It decides
 * nothing about WHO holds an app, which is the claim record and does not exist yet.
 *
 * ⚠ NOT CALLED "lease". `lease` already means the gateway ref-lease in `core/agent` — `leaseReq`/`leaseInfo`,
 * the capBegin/capFlush payment bracket, the `/lease` endpoint in nowhere-cloud's endpoint contract. That word
 * has money attached, and an app-concurrency mechanism sharing it would collide in every grep, log line and
 * test name. A HOLD is placed and released; a CLAIM says who holds it.
 *
 * HOW IT WORKS, and it is entirely the framework's own mechanism. A suspended package has its launch
 * INTERCEPTED — `ActivityStartInterceptor.interceptSuspendedPackageIfNeeded()` replaces the start intent with
 * `com.android.internal.app.SuspendedAppActivity`, a modal built from the {@link SuspendDialogInfo} we pass.
 * Device-proven in a live roamed session on lynx 2026091001 (`NWP-20260910-21`): the control launch resumed
 * the app, the suspended launch resumed `SuspendedAppActivity`, and suspension was per-user (user 0 untouched).
 *
 * ⚠⚠ DevicePolicyManager IS THE WRONG DOOR, AND THE TRAP IS SILENT. `interceptSuspendedPackageIfNeeded`
 * branches on WHO suspended: when the suspending package is the PLATFORM it takes
 * `interceptSuspendedByAdminPackage()`, which shows a stock admin dialog carrying NONE of our text — the call
 * still succeeds, the app is still blocked, and the user is told nothing useful. `DevicePolicyManager`
 * suspends as the platform. We must go through {@link PackageManager} so the suspending package is
 * `com.nowhere.chooser` and our own dialog is what renders.
 *
 * WHY A PLAIN CALL AND NOT REFLECTION. `NowhereChooser` is built `platform_apis: true` with
 * `certificate: "platform"`, so it compiles against the full platform classpath and already calls @hide
 * symbols directly (`LocalePicker.updateLocale`, `installExistingPackageAsUser`, `AppOpsManager.setUidMode`).
 * Reflection in this app answers "the symbol may be ABSENT in one edition's tree" — which is why
 * {@link GosState} reflects, since `GosPackageState` does not exist on LineageOS. These APIs are AOSP and
 * present in both trees.
 *
 * HOW THE CROSS-USER TARGETING WORKS, since it is not obvious from the signature.
 * `ApplicationPackageManager.setPackagesSuspended` forwards to
 * `setPackagesSuspendedAsUser(..., suspendingPackage = mContext.getOpPackageName(),
 * suspendingUserId = UserHandle.myUserId(), targetUserId = getUserId())`. So the suspending identity comes
 * from the PROCESS (us, in user 0) and the target comes from the CONTEXT. A context-as-user PackageManager
 * therefore expresses both at once: suspend AS the chooser, IN the roamed user.
 *
 * ⚠⚠ THE FAILURE THIS CLASS IS BUILT AROUND: A HOLD THAT DID NOT HAPPEN MUST NEVER READ AS ONE.
 * The API does not throw when it declines a package — it RETURNS the ones it could not suspend, and the
 * platform deliberately refuses critical packages ("e.g. the default dialer and launcher"). The chooser is the
 * device owner and deliberately creates those role holders inside the roamed user, so refusals are expected
 * here rather than exotic. A boolean-returning wrapper would discard exactly the information that says the
 * mechanism did nothing, so every call returns a {@link Result} naming what was held, what was refused, and
 * whether the mechanism was reachable at all. A missing permission (manifest edit shipped without the
 * `versionCode` bump, so PM skipped the re-scan) surfaces as {@link Result#NOT_PERMITTED}, never as success.
 */
final class AppClaim {

    private AppClaim() {}

    /** Per-(target user) record of what THIS session actually holds. Lives in the GATE's own files dir. */
    private static final String RECEIPT = "nowhere-appclaim";

    private static final String TAG = "NowhereChooser";

    // ---- outcomes ------------------------------------------------------------------------------------

    /** The mechanism was reachable and at least one package changed state. */
    static final int APPLIED = 0;
    /** The call completed and the framework declined EVERY package. Not an error; not a hold either. */
    static final int ALL_REFUSED = 1;
    /** SecurityException: we do not hold SUSPEND_APPS. Almost always a missing versionCode bump. */
    static final int NOT_PERMITTED = 2;
    /** Anything else — a dead user, a null PackageManager, an unexpected throw. */
    static final int ERROR = 3;

    /**
     * The result of one hold/release pass. Deliberately not a boolean: "we asked" and "it happened" are
     * different facts, and the difference is exactly what a silent failure hides.
     */
    static final class Result {
        final int state;
        /** Packages the framework accepted. */
        final java.util.List<String> changed;
        /** Packages it declined, verbatim from the API's return value. */
        final java.util.List<String> refused;

        Result(int state, java.util.List<String> changed, java.util.List<String> refused) {
            this.state = state;
            this.changed = changed;
            this.refused = refused;
        }

        /** True only when every package asked for actually changed state. */
        boolean complete() {
            return state == APPLIED && refused.isEmpty();
        }

        @Override public String toString() {
            String s = state == APPLIED ? "applied"
                    : state == ALL_REFUSED ? "ALL-REFUSED"
                    : state == NOT_PERMITTED ? "NOT-PERMITTED" : "ERROR";
            return s + " changed=" + changed.size() + " refused=" + refused;
        }
    }

    // ---- the primitive -------------------------------------------------------------------------------

    /**
     * Hold {@code pkgs} in {@code userId}: they stop launching, and a tap renders {@code message}.
     *
     * @param where the human-readable place the app is in use, e.g. "your other device", or a device
     *              label such as "Pixel 8 Pro". Rendered verbatim, so the caller owns the wording;
     *              this class never invents a device name.
     */
    static Result hold(Context ctx, int userId, java.util.List<String> pkgs, String where) {
        // Strings are hardcoded here because this app has no strings.xml -- chooser/res carries drawables and
        // the device-admin policy XML only, and every other user-facing string in the chooser is a Java
        // literal. SuspendDialogInfo.Builder takes String overloads as well as @StringRes ones, which is also
        // what lets the place be substituted at all: `where` is runtime text, not a resource.
        // (setNeutralButtonText is available if a second action is ever wanted; one OK is enough for now.)
        SuspendDialogInfo dialog = new SuspendDialogInfo.Builder()
                // ⚠ "CLOSE IT THERE" WAS TRUE OF AN INTENTION AND FALSE OF THE MECHANISM, and it stopped
                // being defensible the moment NWP-20260912-06 defined what a hold IS: a package is held
                // from the moment it is opened until the holder SIGNS OUT, RELEASES it, uninstalls it, or
                // goes ~15 minutes without sealing. Closing the app on the other handset changes nothing,
                // so the old copy sent the user to do a thing, watch it fail, and do it again. Say the
                // things that DO work, and say them in the order the user can act on.
                .setTitle("Held by " + where)
                //
                // ⚠ "IS AWAY FOR ABOUT FIFTEEN MINUTES" WAS THE SAME DEFECT A SECOND TIME, and the comment
                // three lines above already said so: the claim lapses after ~15 minutes WITHOUT SEALING, not
                // without USE. A handset idle on a charger is away in every sense the reader means and seals
                // every 120 s forever, so its claims never lapse -- and we were telling a blocked user to wait
                // for a release that cannot arrive. `ProfileActivity.java:2884` caught this on the held-apps
                // screen and wrote the warning there; this surface never got the correction, so the string
                // drifted from the comment that introduces it. Switched off is the case that DOES lapse, and
                // it is what the reader can act on or wait for.
                .setMessage("You opened this app on " + where + ", so it is held there. It opens here once "
                        + "that device releases it, signs out, or uninstalls it — or about fifteen minutes "
                        + "after that device is switched off. Either way the change takes a few minutes to "
                        + "reach this device.")
                .build();
        Result r = set(ctx, userId, pkgs, true, dialog);
        if (r.state == APPLIED) writeReceipt(ctx, userId, r.changed);
        return r;
    }

    /** Release {@code pkgs} in {@code userId}. Safe to call for packages that were never held. */
    static Result release(Context ctx, int userId, java.util.List<String> pkgs) {
        // NWP-20261130-03: both holds suspend as com.nowhere.chooser, so this call would also lift the data barrier. An app
        // the barrier holds keeps its receipt line, and the next applier pass releases it once its data is back.
        Result r = set(ctx, userId, OdDataBarrierHost.withoutHeld(ctx, pkgs), false, null);
        if (r.state == APPLIED) clearReceipt(ctx, userId, r.changed);
        return r;
    }

    /**
     * Release everything this session recorded holding in {@code userId} — the logoff path, and the repair
     * path for a session that ended without one. ERROR, releasing nothing, when the receipt cannot be read.
     */
    static Result releaseAll(Context ctx, int userId) {
        java.util.List<String> held = readReceipt(ctx, userId);
        if (held == null) {
            // Not "nothing held": an unreadable receipt says nothing about what this session holds.
            Log.w(TAG, "appclaim releaseAll user=" + userId + ": the receipt is present but could not be read -- "
                    + "releasing nothing (NWP-20261111-16)");
            return new Result(ERROR, java.util.Collections.<String>emptyList(),
                    java.util.Collections.<String>emptyList());
        }
        if (held.isEmpty()) {
            return new Result(APPLIED, java.util.Collections.<String>emptyList(),
                    java.util.Collections.<String>emptyList());
        }
        return release(ctx, userId, held);
    }

    /** Does this session's receipt hold {@code pkg}? NWP-20261130-03: an unreadable receipt counts as held, so the data
     *  barrier never lifts a hold it cannot prove is its own alone. */
    static boolean claimHeld(Context ctx, int userId, String pkg) {
        java.util.List<String> held = readReceipt(ctx, userId);
        return held == null || held.contains(pkg);
    }

    /** Is {@code pkg} suspended in {@code userId} right now? Read from the framework, not from the receipt. */
    static boolean heldNow(Context ctx, int userId, String pkg) {
        try {
            return userContext(ctx, userId).getPackageManager().isPackageSuspended(pkg);
        } catch (Throwable t) {
            return false; // absent, uninstalled for that user, or unreadable: not a hold we can rely on
        }
    }

    private static Context userContext(Context ctx, int userId) {
        return ctx.createContextAsUser(android.os.UserHandle.of(userId), 0);
    }

    private static Result set(Context ctx, int userId, java.util.List<String> pkgs, boolean suspended,
                              SuspendDialogInfo dialog) {
        java.util.List<String> empty = java.util.Collections.<String>emptyList();
        if (pkgs == null || pkgs.isEmpty()) return new Result(APPLIED, empty, empty);
        String[] names = pkgs.toArray(new String[0]);
        try {
            PackageManager pm = userContext(ctx, userId).getPackageManager();
            if (pm == null) {
                Log.e(TAG, "appclaim: no PackageManager for user " + userId);
                return new Result(ERROR, empty, empty);
            }
            // The return value is the packages it could NOT change. Null means none were refused.
            String[] failed = pm.setPackagesSuspended(names, suspended, null, null, dialog);
            java.util.List<String> refused = failed == null
                    ? empty : java.util.Arrays.asList(failed);
            java.util.List<String> changed = new java.util.ArrayList<>();
            for (String p : pkgs) if (!refused.contains(p)) changed.add(p);

            Result r = changed.isEmpty() && !refused.isEmpty()
                    ? new Result(ALL_REFUSED, changed, refused)
                    : new Result(APPLIED, changed, refused);
            Log.i(TAG, "appclaim " + (suspended ? "hold" : "release") + " user=" + userId + ": " + r);
            if (r.state == ALL_REFUSED) {
                // Every package declined. Expected for the platform's critical set (dialer, launcher); a
                // surprise for an ordinary app, and the caller must not tell the user it is held.
                Log.e(TAG, "appclaim: the framework refused ALL " + refused.size()
                        + " package(s) in user " + userId + " -- nothing is held, and nothing is protected: "
                        + refused);
            }
            return r;
        } catch (SecurityException se) {
            // We are platform-signed and SUSPEND_APPS is signature-level, so this is almost always the
            // manifest change shipping without the versionCode bump: PM skipped the re-scan and never
            // granted it. Loud, because the alternative is believing an app is held when it is not.
            Log.e(TAG, "appclaim: SUSPEND_APPS NOT GRANTED -- was AndroidManifest's versionCode bumped with"
                    + " the permission? Nothing is held in user " + userId, se);
            return new Result(NOT_PERMITTED, empty, empty);
        } catch (Throwable t) {
            Log.e(TAG, "appclaim: " + (suspended ? "hold" : "release") + " failed for user " + userId, t);
            return new Result(ERROR, empty, empty);
        }
    }

    // ---- the applier: what the seal said, turned into holds ------------------------------------------
    //
    // The seal writes `nowhere-claims` into THIS user's chooser files dir on every cycle -- one
    // `<pkg>\t<unit>` line per package a LIVE claim assigns to another handset, and an EMPTY file when
    // nothing is held elsewhere. Empty is the instruction to RELEASE, which is why the seal writes it
    // rather than skipping the write.
    //
    // ⚠ THE DIFFERENCE IS COMPUTED AGAINST THE RECEIPT, NOT AGAINST THE FRAMEWORK. We release only what
    // THIS session recorded holding. Suspending is a device-wide verb and the user, or another part of the
    // OS, may have suspended something for reasons of their own; unsuspending everything not in the file
    // would quietly undo that. The receipt is the only record of what is ours to undo.
    //
    // ⚠ AND IT RUNS IN THE ROAMED USER. AppClaim's cross-user call targets a user by context, so it works
    // from either side -- but the receipt lives in the CALLER's files dir, so the applier and the releaser
    // must be the same side or the release finds nothing to release. Here both are the roamed user itself.

    /** One package a live claim assigns to another handset. */
    private static final String CLAIMS = "nowhere-claims";

    /**
     * Read what the seal published and make this user match it: hold what another handset claims, release
     * what it no longer does. Returns the combined outcome for logging; never throws.
     * Serialized: the sign-in kick and a seal's kick each run a read-hold-receipt cycle, and two interleaved
     * cycles would diff against a stale receipt.
     */
    static synchronized Result applyFromFile(Context ctx, int userId) {
        java.util.LinkedHashMap<String, String> want = readClaims(ctx);
        if (want == null) {
            // AN UNREADABLE RECORD IS NOT AN EMPTY ONE. Below, a package missing from `want` is RELEASED --
            // that is how a release propagates -- so treating a failed read as an empty record would drop
            // every hold this session took, on the strength of nothing. Change nothing instead, and say so.
            Log.w(TAG, "appclaim apply user=" + userId + ": the claim record is present but could not be "
                    + "read -- holding what we hold and changing nothing (NWP-20260911-02)");
            return new Result(ERROR, java.util.Collections.<String>emptyList(),
                    java.util.Collections.<String>emptyList());
        }
        java.util.List<String> have = readReceipt(ctx, userId);
        if (have == null) {
            // AN UNREADABLE RECEIPT IS NOT AN EMPTY ONE either: diffing against an empty `have` releases nothing
            // this session holds, and hold() would then rewrite the receipt without the earlier holds.
            Log.w(TAG, "appclaim apply user=" + userId + ": the receipt is present but could not be read -- "
                    + "changing nothing (NWP-20261111-16)");
            return new Result(ERROR, java.util.Collections.<String>emptyList(),
                    java.util.Collections.<String>emptyList());
        }

        java.util.List<java.util.List<String>> d = diff(want, have);
        java.util.List<String> toHold = d.get(0);
        java.util.List<String> toRelease = d.get(1);

        if (toHold.isEmpty() && toRelease.isEmpty()) {
            return new Result(APPLIED, java.util.Collections.<String>emptyList(),
                    java.util.Collections.<String>emptyList());
        }
        Log.i(TAG, "appclaim apply user=" + userId + ": +" + toHold.size() + " -" + toRelease.size()
                + " (claimed elsewhere: " + want.size() + ")");

        Result rel = toRelease.isEmpty() ? null : release(ctx, userId, toRelease);
        // NWP-20260912-01 DECIDED the rule: name the holding device when its label DIFFERS from this one's,
        // and otherwise say "your other device" -- so the message degrades on AMBIGUITY rather than on how
        // many units the account has. Two handsets of the same model render the SAME label, and naming it
        // would point at the device in the user's hand.
        //
        // The comparison runs in the AGENT, not here (h54 #1, decided 2026-11-02, NWP-20261125-06): the seal
        // reads each holder's label from the sealed claim record, compares it with this phone's deviceLabel(),
        // and writes the name as the third column only when the two differ. This class never reads a label:
        // a line with no third column says HeldElsewhereCopy.WHERE. One hold() per name, so each dialog names
        // its own holder. The sign-in seed writes two columns (moderator ruling 2026-11-03), and a package
        // already in the receipt is never re-held, so a package keeps the dialog it was held with until it is
        // released: an app held at sign-in says "your other device" all session.
        //
        // "device", never "phone": the same OS is meant to run on a tablet.
        java.util.List<Result> holds = new java.util.ArrayList<>();
        if (!toHold.isEmpty()) {
            java.util.LinkedHashMap<String, String> names = readClaimNames(ctx);
            for (java.util.Map.Entry<String, java.util.List<String>> g
                    : holdGroups(toHold, names, HeldElsewhereCopy.WHERE).entrySet()) {
                holds.add(hold(ctx, userId, g.getValue(), g.getKey()));
            }
        }

        for (Result h : holds) if (h.state != APPLIED) return h;
        if (rel != null && rel.state != APPLIED) return rel;
        java.util.List<String> changed = new java.util.ArrayList<>();
        for (Result h : holds) changed.addAll(h.changed);
        if (rel != null) changed.addAll(rel.changed);
        java.util.List<String> refused = new java.util.ArrayList<>();
        for (Result h : holds) refused.addAll(h.refused);
        if (rel != null) refused.addAll(rel.refused);
        return new Result(APPLIED, changed, refused);
    }

    /**
     * Every package a LIVE claim assigns to some OTHER handset, for a caller that must not ask for one of
     * them. ONE parser serves the enforcer and the producer, so they can never disagree about what the seal
     * said. Empty when the record is absent, empty, or unreadable. ⚠ The CALLER uses this as a DROP set, so
     * empty means "exclude nothing" and therefore "ask for everything else" -- the safe direction here,
     * because a package we ask for that another handset already holds is REFUSED by claimsToPublish rule 2
     * rather than taken. An earlier version of this comment claimed the opposite ("ask for nothing extra"),
     * which would have been the right rule for a HOLD set and is the wrong one for a drop set.
     */
    static java.util.Set<String> claimedElsewhere(Context ctx) {
        java.util.LinkedHashMap<String, String> m = readClaims(ctx);
        return m == null ? java.util.Collections.<String>emptySet()
                : new java.util.LinkedHashSet<>(m.keySet());
    }

    // For a screen: null when the record is present but unreadable, empty when absent or nothing is held.
    // claimedElsewhere deliberately collapses that distinction, and a screen must not.
    static java.util.LinkedHashMap<String, String> claimsForScreen(Context ctx) {
        return readClaims(ctx);
    }

    // For a screen: the holder's name per package (the claim record's third column). Never null: an absent or
    // unreadable record gives none, so each package says HeldElsewhereCopy.WHERE.
    static java.util.LinkedHashMap<String, String> namesForScreen(Context ctx) {
        return readClaimNames(ctx);
    }

    /**
     * `<pkg>\t<unit>` per line; `#` comments and malformed lines skipped, never guessed at.
     *
     * ⚠ RETURNS null WHEN THE FILE EXISTS BUT COULD NOT BE READ, and that distinction is the whole
     * point of this method. An EMPTY record is a real instruction -- "nothing is held elsewhere" -- and it
     * releases every hold. An UNREADABLE record says nothing at all. Collapsing the two is what kept
     * NWP-20260911-01 inert on every device it shipped to: the seal wrote this file as root:root 0600 into
     * our own files dir, every open threw EACCES, and the old `catch (Throwable ignore)` reported "hold
     * nothing" -- silently, on every cycle, while roamd logged the claims it had just handed us.
     *
     * Java raises the SAME exception for absent and for unopenable, so the file itself has to be asked.
     */
    private static java.util.LinkedHashMap<String, String> readClaims(Context ctx) {
        return readClaimsFile(new File(ctx.getFilesDir(), CLAIMS));
    }

    /** The file half of {@link #readClaims}: null when present but unreadable, empty when absent. */
    static java.util.LinkedHashMap<String, String> readClaimsFile(File f) {
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f))) {
            return parseClaims(r);
        } catch (java.io.FileNotFoundException fnf) {
            // No file yet (no seal has run this session) is the common case and correctly means "hold nothing".
            // An unopenable file arrives here identically, so the existence check -- not the exception -- decides.
            if (f.exists()) {
                Log.w(TAG, "appclaim: the claim record exists but cannot be opened: " + fnf.getMessage());
                return null;
            }
        } catch (Throwable t) {
            // A torn or half-written record is equally not an instruction to release anything.
            Log.w(TAG, "appclaim: unreadable claim record", t);
            return null;
        }
        return new java.util.LinkedHashMap<>();
    }

    /**
     * The line rules of the claim record: one `<pkg>\t<unit>[\t<name>]` per line, anything else skipped. The value is
     * the unit only (the second column); the name is {@link #parseClaimNames}'s.
     */
    static java.util.LinkedHashMap<String, String> parseClaims(java.io.Reader in) throws java.io.IOException {
        java.util.LinkedHashMap<String, String> out = new java.util.LinkedHashMap<>();
        java.io.BufferedReader r = new java.io.BufferedReader(in);
        String ln;
        while ((ln = r.readLine()) != null) {
            ln = ln.trim();
            if (ln.isEmpty() || ln.startsWith("#")) continue;
            int tab = ln.indexOf('\t');
            if (tab <= 0) continue;
            String pkg = ln.substring(0, tab).trim();
            int tab2 = ln.indexOf('\t', tab + 1);
            String unit = (tab2 < 0 ? ln.substring(tab + 1) : ln.substring(tab + 1, tab2)).trim();
            if (!pkg.isEmpty() && pkg.indexOf('/') < 0) out.put(pkg, unit);
        }
        return out;
    }

    /**
     * The holder's name per package: the claim record's third column, which the seal writes only when the holder's
     * label differs from this phone's (h54 #1). Same skip rules as {@link #parseClaims}; a line whose third column is
     * absent, empty or holds a control character gives no entry, so its hold says HeldElsewhereCopy.WHERE.
     */
    static java.util.LinkedHashMap<String, String> parseClaimNames(java.io.Reader in) throws java.io.IOException {
        java.util.LinkedHashMap<String, String> out = new java.util.LinkedHashMap<>();
        java.io.BufferedReader r = new java.io.BufferedReader(in);
        String ln;
        while ((ln = r.readLine()) != null) {
            ln = ln.trim();
            if (ln.isEmpty() || ln.startsWith("#")) continue;
            int tab = ln.indexOf('\t');
            if (tab <= 0) continue;
            String pkg = ln.substring(0, tab).trim();
            if (pkg.isEmpty() || pkg.indexOf('/') >= 0) continue;
            out.remove(pkg); // a later line for the same package wins, as in parseClaims
            int tab2 = ln.indexOf('\t', tab + 1);
            if (tab2 < 0) continue;
            int tab3 = ln.indexOf('\t', tab2 + 1);
            String name = (tab3 < 0 ? ln.substring(tab2 + 1) : ln.substring(tab2 + 1, tab3)).trim();
            boolean control = false;
            for (int i = 0; i < name.length(); i++) control |= Character.isISOControl(name.charAt(i));
            if (!name.isEmpty() && !control) out.put(pkg, name);
        }
        return out;
    }

    /** The names in the claim record; absent or unreadable gives none, never an error (each hold then says WHERE). */
    private static java.util.LinkedHashMap<String, String> readClaimNames(Context ctx) {
        File f = new File(ctx.getFilesDir(), CLAIMS);
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f))) {
            return parseClaimNames(r);
        } catch (Throwable t) {
            return new java.util.LinkedHashMap<>();
        }
    }

    /** {@code toHold} grouped by where each package is held: its name, else {@code fallback}; first-seen order. */
    static java.util.LinkedHashMap<String, java.util.List<String>> holdGroups(java.util.List<String> toHold,
            java.util.Map<String, String> names, String fallback) {
        java.util.LinkedHashMap<String, java.util.List<String>> out = new java.util.LinkedHashMap<>();
        for (String pkg : toHold) {
            String n = names == null ? null : names.get(pkg);
            String where = n == null || n.isEmpty() ? fallback : n;
            java.util.List<String> g = out.get(where);
            if (g == null) {
                g = new java.util.ArrayList<>();
                out.put(where, g);
            }
            g.add(pkg);
        }
        return out;
    }

    /** What to hold (claimed, not yet ours) and what to release (ours, no longer claimed): {toHold, toRelease}. */
    static java.util.List<java.util.List<String>> diff(java.util.Map<String, String> want,
            java.util.List<String> have) {
        java.util.List<String> toHold = new java.util.ArrayList<>();
        for (String pkg : want.keySet()) if (!have.contains(pkg)) toHold.add(pkg);
        java.util.List<String> toRelease = new java.util.ArrayList<>();
        for (String pkg : have) if (!want.containsKey(pkg)) toRelease.add(pkg);
        java.util.List<java.util.List<String>> out = new java.util.ArrayList<>();
        out.add(toHold);
        out.add(toRelease);
        return out;
    }

    // ---- the receipt ---------------------------------------------------------------------------------
    //
    // Kept in the files dir of whichever user applies the record -- which since NWP-20260911-01 is the
    // ROAMED user, not user 0: roamd starts CredentialService with `--user <uid>` after every seal, so
    // getFilesDir() here is /data/user/<uid>/com.nowhere.chooser/files.
    //
    // ⚠ THIS PARAGRAPH USED TO SAY THE OPPOSITE -- "this code runs in user 0 ... nothing that could be
    // restored from another handset and forge a confirmation" -- and the safety argument in that sentence
    // was false as wired. The roamed user’s chooser dir SEALS AND ROAMS (`_push vault ... "$USERDIR"`), and
    // two handsets mint colliding low user ids, so a receipt restored from the OTHER handset can match on
    // "#user <id>" and make applyFromFile believe those packages are already held -- the hold then never
    // happens, silently, which is exactly the shape this class exists to refuse. What closes it is the same
    // thing that closes it for its sibling receipts: roamd deletes this file at roam-in
    // (`nowhere_roamd.sh`, NWP-20260911-02), so a restored one never survives into a new session.    //
    // It is scoped by TARGET USER instead. Every login mints a new roamed user id, so a receipt stamped for
    // user 11 is self-evidently meaningless to user 12 and reads as empty. That is what keeps a hold from one
    // session being "released" against a later one. ⚠ A cold-lock RESUME reuses the SAME user, deliberately,
    // so the receipt survives a resume — which is correct: the hold survives it too.

    private static File receiptFile(Context ctx) {
        return new File(ctx.getFilesDir(), RECEIPT);
    }

    /** The receipt for {@code userId}: empty when absent, null when present but unreadable (readReceiptFile). */
    private static java.util.List<String> readReceipt(Context ctx, int userId) {
        return readReceiptFile(receiptFile(ctx), userId);
    }

    /**
     * The file half of {@link #readReceipt}, read as strictly as {@link #readClaimsFile} and for the mirror-image
     * reason. ⚠ AN UNREADABLE RECEIPT IS NOT AN EMPTY ONE. An empty `have` releases nothing (applyFromFile's diff
     * finds nothing of ours to drop, so an app stays held after the other handset lets go), and the writers rebuild
     * the receipt from the read, so an empty read would also erase every earlier hold from it for good. Null tells
     * every caller to change nothing (NWP-20261111-16). Absent is the ordinary "nothing held yet" and stays empty;
     * as for the claim record, the existence check -- not the exception -- tells the two apart.
     */
    static java.util.List<String> readReceiptFile(File f, int userId) {
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f))) {
            return parseReceipt(r, userId);
        } catch (java.io.FileNotFoundException fnf) {
            if (f.exists()) {
                Log.w(TAG, "appclaim: the receipt exists but cannot be opened: " + fnf.getMessage());
                return null;
            }
        } catch (Throwable t) {
            Log.w(TAG, "appclaim: unreadable receipt", t);
            return null;
        }
        return new java.util.ArrayList<>();
    }

    /** The packages the receipt records for `userId`; a block stamped for any other user is not read. */
    static java.util.List<String> parseReceipt(String text, int userId) throws java.io.IOException {
        return parseReceipt(new java.io.StringReader(text), userId);
    }

    private static java.util.List<String> parseReceipt(java.io.Reader in, int userId) throws java.io.IOException {
        java.util.List<String> out = new java.util.ArrayList<>();
        String want = "#user " + userId;
        boolean matched = false;
        java.io.BufferedReader r = new java.io.BufferedReader(in);
        String ln;
        while ((ln = r.readLine()) != null) {
            ln = ln.trim();
            if (ln.isEmpty()) continue;
            if (ln.startsWith("#")) { matched = ln.equals(want); continue; }
            if (matched) out.add(ln);
        }
        return out;
    }

    private static void writeReceipt(Context ctx, int userId, java.util.List<String> add) {
        java.util.List<String> held = readReceipt(ctx, userId);
        if (held == null) {
            // Rewriting from a failed read would drop every earlier hold from the receipt; keep it whole.
            Log.w(TAG, "appclaim receipt (hold) user=" + userId + ": the receipt is present but could not be read"
                    + " -- not rewriting it; " + add.size() + " new hold(s) unrecorded (NWP-20261111-16)");
            return;
        }
        java.util.LinkedHashSet<String> all = new java.util.LinkedHashSet<>(held);
        all.addAll(add);
        writeReceipt(ctx, userId, all, "hold");
    }

    private static void clearReceipt(Context ctx, int userId, java.util.List<String> remove) {
        java.util.List<String> held = readReceipt(ctx, userId);
        if (held == null) {
            // Same as the hold side: a rewrite from a failed read would erase the holds still recorded.
            Log.w(TAG, "appclaim receipt (release) user=" + userId + ": the receipt is present but could not be read"
                    + " -- not rewriting it; " + remove.size() + " release(s) unrecorded (NWP-20261111-16)");
            return;
        }
        java.util.LinkedHashSet<String> all = new java.util.LinkedHashSet<>(held);
        all.removeAll(remove);
        writeReceipt(ctx, userId, all, "release");
    }

    private static void writeReceipt(Context ctx, int userId, java.util.Set<String> pkgs, String why) {
        StringBuilder sb = new StringBuilder("#user ").append(userId).append('\n');
        for (String p : pkgs) sb.append(p).append('\n');
        // temp + rename (writeAtomic's .tmp is nowhere-appclaim.tmp): a failed write keeps the old receipt whole
        try { StoreInstaller.writeAtomic(receiptFile(ctx), sb.toString()); }
        catch (Throwable t) { Log.w(TAG, "appclaim receipt (" + why + ")", t); }
    }
}
