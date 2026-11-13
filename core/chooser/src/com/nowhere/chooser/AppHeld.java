package com.nowhere.chooser;

import android.app.usage.UsageStats;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.SystemClock;
import android.util.Log;

import java.io.File;

/**
 * NWP-20260912-06 — say what THIS handset is holding, so the seal has something to publish.
 *
 * The other half of the per-app claim record. {@link AppClaim} can hold an app shut because another handset
 * claims it; {@code core/agent/app_claim.go} publishes and expires those claims. Between them sat a gap that
 * made the whole feature inert in the field: <b>nothing ever wrote the held list</b>, so no handset ever
 * claimed an app by itself and every claim demonstrated on hardware had to be planted by hand
 * ({@code NWP-20260911-02}, {@code NWP-20260912-03}). This class closes it.
 *
 * <h3>What "held" means — the definition, decided 2026-09-12 ({@code NWP-20260912-05})</h3>
 *
 * <blockquote>An app is held by this handset if you have opened it here since you signed in or last released
 * it — and it stops being held when you sign out, release it, uninstall it, or this handset goes an hour
 * without sealing (an hour since 2026-11-10; fifteen minutes when decided).</blockquote>
 *
 * One sentence, implementable and honest to a user, and every clause maps to something below: "opened it
 * here" is the usage query; "since you signed in" is the stamp; "or last released it" is the floor; "sign
 * out" and "release" are both {@link #clear}; "uninstall" is an exclusion; and the hour is
 * {@code claimTTL} on the agent side, which needs nothing here — a handset that stops sealing stops
 * refreshing, and its claims lapse by arithmetic.
 *
 * <h3>⚠ WHY IT IS STICKY, AND WHY THAT IS THE SAFE DIRECTION</h3>
 *
 * A package that appears once is kept until the session ends or the user releases it — the set is a UNION,
 * not a snapshot. That is deliberate and it follows from the 2026-09-10 decision that the first device wins
 * and the loser's changes are DISCARDED: a claim that is MISSING costs data, and a claim that is SPURIOUS
 * costs a lockout. So every uncertainty here resolves toward holding, and the cost of that is bought back by
 * Release rather than by a tuned timeout. It is also why {@link #refresh} leaves the file alone on any
 * failure instead of writing a shorter one — the exact inverse of {@code captureAppDrops}, which deletes a
 * partial write because ITS list deletes data, where this one only locks another handset out.
 *
 * <h3>The file, and who reads it</h3>
 *
 * {@code files/nowhere-appheld.list} in THIS user's chooser dir — running as the roamed user that is exactly
 * the path roamd hands the agent as {@code NOWHERE_HELD_LIST} ({@code nowhere_roamd.sh}), so there is no path
 * to build, no cross-user call, and no sepolicy work. Format, which {@code fileHeldList} already accepts
 * unchanged (it skips any line that is empty, starts with {@code #}, or contains a path separator):
 *
 * <pre>
 * # what this handset is holding -- NWP-20260912-06
 * #stamp 13
 * #floor 74212993
 * com.omgodse.notally
 * org.videolan.vlc
 * </pre>
 *
 * ⚠ It is ALWAYS written and never deleted. A comment-only file is the only on-device evidence the producer
 * ran at all; an absent one and an empty one mean the same thing downstream ("hold nothing"), so deleting it
 * would throw away the one signal that separates "nothing is held" from "this never executed".
 *
 * <h3>The stamp and the floor</h3>
 *
 * The stamp is the Android user serial, and the reasoning is {@code StoreInstaller.seenStamp}'s, verbatim in
 * consequence: every login mints a new user, so a fresh serial IS a fresh session, and a file restored from
 * another handset's seal was written under a different one and reads as foreign.
 *
 * ⚠ BUT THE STAMP PROTECTS THIS CLASS AND THE SCREEN, NOT THE WIRE, AND IT MUST NOT BE MISTAKEN FOR THE
 * PRIMARY DEFENCE. The agent's {@code fileHeldList} skips every line beginning with {@code #} -- including
 * the stamp -- and publishes every package line it finds, so a foreign file that reached a seal before this
 * class rewrote it would be published as THIS unit's claims: we would claim, in our own name, the apps the
 * other handset is actually using. What actually closes that is roamd deleting this file at roam-in
 * ({@code nowhere_roamd.sh}, NWP-20260912-06). The stamp is the second lock, and it earns its place by
 * keeping a stale file out of the UNION below rather than off the wire. ⚠ Deliberately NOT a
 * wall-clock boot epoch, which MOVES when NTP corrects the clock and would silently invalidate the file
 * seconds after boot.
 *
 * The floor is on the MONOTONIC clock ({@link SystemClock#elapsedRealtime}) for the same reason, converted to
 * wall time only at the moment of comparison. A release must not be undone by a clock correction.
 */
final class AppHeld {

    private AppHeld() {}

    /** What this handset holds. Read by the agent at seal time via {@code NOWHERE_HELD_LIST}. */
    private static final String FILE = "nowhere-appheld.list";

    private static final String TAG = "NowhereChooser";

    /** The usage window to ask about. Matches {@code ReArchiveReceiver}'s, and for the same reason: it is the
     *  widest question the API answers cheaply, and the floor — not this — is what bounds the answer. */
    private static final long USAGE_WINDOW_MS = 7L * 24 * 60 * 60 * 1000L;

    /** Serialises the read-modify-write against itself; the seal reads the file as root and never writes it. */
    private static final Object LOCK = new Object();

    // ---- the producer -------------------------------------------------------------------------------

    /**
     * Recompute what this handset holds and write it for the next seal to publish. Never throws.
     *
     * Called on the tick that already exists — roamd kicks {@link CredentialService} after EVERY out op, so
     * this runs on the 120s periodic seal and on all four event seals, and the producer's cadence is the
     * seal's own cadence by construction. It cannot drift out of step with its only reader.
     */
    static void refresh(Context ctx) {
        synchronized (LOCK) {
            try {
                ReArchiveReceiver.grantUsageStats(ctx);

                Held prev = read(ctx);
                if (prev == null) {
                    Log.w(TAG, "appheld: list unreadable -- keeping the previous file (NWP-20261111-19)");
                    return;
                }
                java.util.LinkedHashSet<String> held = new java.util.LinkedHashSet<>(prev.pkgs);
                int before = held.size();

                long nowWall = System.currentTimeMillis();
                // TWO FLOORS, AND THE EFFECTIVE ONE IS THE LATER. "since you signed in" is the USER CREATION
                // time -- a login mints a brand-new Android user, so that instant IS the sign-in, and it
                // survives a cold-lock resume, which reuses the user and is deliberately the same session.
                //
                // ⚠⚠ THIS WAS ANCHORED AT THE FIRST REFRESH FOR ONE ITERATION AND IT WAS WRONG ON A DEVICE
                // WITHIN MINUTES. Measured on lynx 2026-09-12: the user signed in, opened Notally at
                // 10:17:06, and the login seed anchored the floor at 10:17:12 -- so the app they had just
                // opened was six seconds too early and was never held. Anything opened between sign-in and
                // the producer's first run fell into that hole, which in practice is the app the user
                // reached for first. The floor has to come from the SESSION, not from whenever we happened
                // to look.
                //
                // ⚠ And it must not be left at 0 either, which is what it was before: the predicate then
                // collapses to `getLastTimeUsed() >= 0`, true of EVERY row in the 7-day window. That was
                // harmless only because a fresh user's usage store starts empty -- luck, not design, since a
                // resume reuses the user and ids are RECYCLED.
                long sessionFloorWall = 0L;
                try {
                    android.os.UserManager um =
                            (android.os.UserManager) ctx.getSystemService(Context.USER_SERVICE);
                    if (um != null) {
                        sessionFloorWall = um.getUserCreationTime(android.os.Process.myUserHandle());
                    }
                } catch (Throwable ignore) {
                    // Fall back to 0 -- the pre-existing behaviour, and safe for the fresh-user case.
                }
                // Release floors stay on the MONOTONIC clock and are converted only here, so a release
                // cannot be undone by an NTP correction. The session floor needs no conversion: user
                // creation and usage timestamps are both wall clock, so they move together.
                final long nowElapsed = SystemClock.elapsedRealtime();
                final long sessionFloor = sessionFloorWall;
                final java.util.Map<String, Long> rel = prev.released;

                android.app.usage.UsageStatsManager usm =
                        ctx.getSystemService(android.app.usage.UsageStatsManager.class);
                if (usm == null) {
                    // ⚠ A NULL MANAGER IS NOT "NO USAGE", AND LAUNDERING IT INTO AN EMPTY MAP COST A DAY.
                    // It means ServiceManager could not find usagestats_service -- which for this app is a
                    // SEPOLICY gap, not a permission one (nowhere_chooser is its own domain and app_domain()
                    // grants no service_manager find). Left silent, it is indistinguishable from "the user
                    // opened nothing", which is exactly how it hid: the permission and the appop both read
                    // as granted, so every other check said the call should work.
                    Log.w(TAG, "appheld: NO UsageStatsManager -- usagestats_service is not findable from "
                            + "this domain, so nothing can ever be held. This is sepolicy, not permissions.");
                    return;
                }
                java.util.Map<String, UsageStats> stats =
                        usm.queryAndAggregateUsageStats(nowWall - USAGE_WINDOW_MS, nowWall);
                int passedFloor = 0;
                for (java.util.Map.Entry<String, UsageStats> e : stats.entrySet()) {
                    UsageStats s = e.getValue();
                    if (s == null) continue;
                    // A package is held if it has been used since the LATER of sign-in and its OWN
                    // release. Per package, so releasing one app cannot free the others -- which the
                    // single global floor did, silently.
                    long floorWall = floorWall(sessionFloor, rel.get(e.getKey()), nowWall, nowElapsed);
                    if (s.getLastTimeUsed() >= floorWall) {
                        held.add(e.getKey());
                        passedFloor++;
                    }
                }

                int candidates = held.size();
                java.util.Set<String> drop = excluded(ctx, held);
                held.removeAll(drop);

                // ⚠ WITHOUT THIS LINE THE PRODUCER IS UNDEBUGGABLE, and two device rounds proved it: both
                // ended at "0 held" with no way to tell whether the usage query returned nothing or an
                // exclusion ate everything, and the difference is a platform problem versus a bug of ours.
                // COUNTS ONLY -- never package names. logcat and roam.log sit outside every wipe path, and a
                // list of what the user actually runs, written there, is the #39 identity-roster shape.
                // ⚠ COUNT WHAT WAS ACTUALLY REMOVED, not the size of the drop SET. `drop` carries self and
                // home unconditionally, and neither was ever a candidate, so subtracting its size printed an
                // impossible number -- the first successful run read "excluded=2 -> held=1" beside "2 held".
                // A diagnostic that prints something impossible is one nobody trusts the next time.
                Log.i(TAG, "appheld: usage rows=" + stats.size() + " past floor=" + passedFloor
                        + " candidates=" + candidates + " removed=" + (candidates - held.size())
                        + " -> held=" + held.size());

                java.util.List<String> out = new java.util.ArrayList<>(held);
                java.util.Collections.sort(out);
                write(ctx, out, rel);
                Log.i(TAG, "appheld: " + out.size() + " held (+" + Math.max(0, out.size() - before)
                        + " new) sign-in floor +" + Math.max(0L, (nowWall - sessionFloor) / 1000L) + "s"
                        + " released=" + rel.size());
            } catch (Throwable t) {
                // ⚠ LEAVE THE EXISTING FILE IN PLACE. Over-claiming locks the other handset out of an app;
                // under-claiming lets both edit it and the 2026-09-10 discard rule throws one side away.
                Log.w(TAG, "appheld: refresh failed -- keeping the previous list", t);
            }
        }
    }

    /**
     * Let go of everything this handset holds, and set a floor so what is already open is not re-claimed on
     * the next refresh.
     *
     * ONE code path for both releases the decision names — the Release action, and the release at sign-out —
     * so the two cannot drift apart. Without the floor, Release would be undone within a seal cycle: the
     * usage query would see the same app "used recently" and add it straight back.
     */
    static void releaseAll(Context ctx) {
        release(ctx, null);
    }

    /**
     * Let go of ONE package, or of everything when {@code only} is null.
     *
     * Records a per-PACKAGE release floor so the next refresh does not simply re-add what was just
     * released -- the usage row is still there and still above the session floor. Per package, because a
     * single global floor could not express "release this one" and, worse, silently released every other
     * app opened this session as a side effect. Chester caught that from the UI: "i was thinking it will
     * at app level not generic?".
     *
     * The app keeps working HERE. A release only stops us claiming it, and the other handset may then
     * take it -- which is what the confirm dialog says out loud.
     */
    static void release(Context ctx, String only) {
        synchronized (LOCK) {
            try {
                Held prev = read(ctx);
                if (prev == null) {
                    Log.w(TAG, "appheld: list unreadable -- keeping the previous file (NWP-20261111-19)");
                    return;
                }
                Held next = releaseOf(prev, only, SystemClock.elapsedRealtime());
                int freed = prev.pkgs.size() - next.pkgs.size();
                write(ctx, next.pkgs, next.released);
                Log.i(TAG, "appheld: released " + freed + " package(s)"
                        + (only == null ? " (all)" : " (one)") + ", " + next.pkgs.size() + " still held");
            } catch (Throwable t) {
                Log.w(TAG, "appheld: release failed", t);
            }
        }
    }

    /**
     * What this handset is holding right now, for the UI to render and for the user to release.
     *
     * Reads the file rather than recomputing, deliberately: the file is what the SEAL will publish, so a
     * screen built from it shows what the other handset will actually be told. Recomputing here could
     * differ from the last write and would make the Release button act on a set the user never saw.
     *
     * An unreadable file answers an empty list, with {@link #hasRun} false: the screen's "nothing recorded yet",
     * never "nothing held" (NWP-20261111-19).
     */
    static java.util.List<String> heldNow(Context ctx) {
        synchronized (LOCK) {
            Held h = read(ctx);
            return h == null ? new java.util.ArrayList<String>() : h.pkgs;
        }
    }

    /**
     * Has the producer written anything for THIS session yet?
     *
     * Exists so the UI can tell "nothing is held" from "nothing has been recorded yet", which otherwise
     * render identically as an empty list. That ambiguity is not hypothetical: it is precisely what let
     * NWP-20260911-01 ship inert for a day, with every layer reporting success over a file nobody could
     * read. A screen that cannot distinguish them would reproduce the same blindness for the user.
     *
     * An unreadable file is "not yet" (NWP-20261111-19): the producer has nothing it can show for this session.
     */
    static boolean hasRun(Context ctx) {
        synchronized (LOCK) {
            Held h = read(ctx);
            return h != null && h.stampMatched;
        }
    }

    /**
     * Empty the list for a SIGN-OUT, leaving the floor where it is.
     *
     * ⚠⚠ A SIGN-OUT THAT DOES NOT HAPPEN MUST NOT LEAVE THE SESSION RELEASED, and using {@link #clear}
     * here did exactly that. The logoff seal can be REFUSED -- a shrink guard, a stale base, an unreadable
     * path -- and logind then deliberately keeps the session signed in rather than reap what it could not
     * save. That is not hypothetical: it happened on lynx on 2026-09-12 and is why the user asked why they
     * could not log off. With {@code clear()} the user would be left signed in, still using their apps,
     * having silently told the other handset it may take all of them -- and the floor would have moved, so
     * the next refresh could not even put them back.
     *
     * So: empty the list, do NOT move the floor. If the sign-out fails, one {@link #refresh} rebuilds the
     * true set from usage, because the session floor is the SIGN-IN and everything opened this session is
     * still above it.
     */
    static void releaseForSignOut(Context ctx) {
        synchronized (LOCK) {
            try {
                Held prev = read(ctx);
                if (prev == null) {
                    Log.w(TAG, "appheld: list unreadable -- keeping the previous file (NWP-20261111-19)");
                    return;
                }
                Held next = signOutOf(prev);
                write(ctx, next.pkgs, next.released);
                Log.i(TAG, "appheld: released " + prev.pkgs.size() + " package(s) for sign-out"
                        + " (floor unchanged, so a refused sign-out can rebuild)");
            } catch (Throwable t) {
                Log.w(TAG, "appheld: sign-out release failed", t);
            }
        }
    }

    // ---- exclusions, each with its reason ------------------------------------------------------------

    /**
     * Packages that must never be held, computed against the candidate set.
     *
     * Each of these would produce a WRONG hold rather than merely a useless one, which is why they are
     * subtracted rather than left to the agent.
     */
    private static java.util.Set<String> excluded(Context ctx, java.util.Set<String> candidates) {
        java.util.Set<String> drop = new java.util.HashSet<>();
        int nSelfHome = 0, nGone = 0, nUnsuspendable = 0, nElsewhere = 0;

        // (1) Ourselves. Holding the chooser would have the other handset suspend its own profile owner.
        drop.add(ctx.getPackageName());

        // (2) The home app. It is resumed constantly so it would be in EVERY held list, and the platform
        //     refuses to suspend a launcher (AppClaim's Result carries those refusals) -- so it would sit
        //     permanently in `refused` on the other handset and blunt the ALL_REFUSED alarm that exists to
        //     say "the mechanism did nothing".
        try {
            PackageManager pm = ctx.getPackageManager();
            ResolveInfo home = pm.resolveActivity(
                    new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME),
                    PackageManager.MATCH_DEFAULT_ONLY);
            // ⚠ With several HOME candidates and no role holder, resolveActivity returns the RESOLVER
            //   (package "android"), not a launcher -- so blindly trusting it drops the wrong name and
            //   leaves the real launcher claimable. A roamed user routinely has more than one candidate.
            if (home != null && home.activityInfo != null
                    && !"android".equals(home.activityInfo.packageName)) {
                drop.add(home.activityInfo.packageName);
            }
        } catch (Throwable ignore) {
        }

        nSelfHome = drop.size();
        PackageManager pm2 = ctx.getPackageManager();
        for (String pkg : candidates) {
            // (3) Gone from this session -- uninstalled, or an on-demand app re-archived back to a
            //     placeholder (getPackageInfo throws for an archived app, which is the behaviour we want).
            if (!StoreInstaller.isInstalled(ctx, pkg)) {
                drop.add(pkg);
                continue;
            }
            // (3b) A package the user cannot LAUNCH is not one they OPENED. The very first successful run
            //      of this producer claimed `app.grapheneos.setupwizard`, which had run during login --
            //      true of "the framework recorded usage", false of the sentence we promised the
            //      user, and
            //      it would have told the other handset that setupwizard was in use here. Usage stats
            //      record every package with a resumed component, not just the ones with an icon.
            try {
                if (pm2.getLaunchIntentForPackage(pkg) == null) drop.add(pkg);
            } catch (Throwable ignore) {
                // Cannot tell -> keep it. Over-claiming is the safe direction (see the class comment).
            }
        }
        nGone = drop.size() - nSelfHome;

        // (4) Anything the platform will REFUSE to suspend. AppClaim’s header says it plainly -- the
        //     platform "deliberately refuses critical packages (e.g. the default dialer and launcher)" --
        //     and a package we claim but the other handset CANNOT hold is the worst of both: we tell the
        //     user it is blocked over there while it stays perfectly launchable. Ask the platform instead
        //     of guessing at the role list, which differs per device and per edition. (2) above stays:
        //     it is cheap, it documents the intent, and it does not depend on this call succeeding.
        try {
            if (!candidates.isEmpty()) {
                String[] refuses = ctx.getPackageManager().getUnsuspendablePackages(
                        candidates.toArray(new String[0]));
                if (refuses != null) java.util.Collections.addAll(drop, refuses);
                nUnsuspendable = refuses == null ? 0 : refuses.length;
            }
        } catch (Throwable ignore) {
            // Older/edition-absent symbol, or the permission is missing: fall back to (1)+(2) only. Over-
            // claiming a package the other side refuses is a wrong MESSAGE, never a wrong hold.
        }

        // (5) Anything ANOTHER handset already holds. claimsToPublish would refuse our request anyway (first
        //     device wins), and that refusal reaches only roam.log -- so re-asking every cycle buys a log
        //     line and nothing else.
        int beforeElsewhere = drop.size();
        try {
            drop.addAll(AppClaim.claimedElsewhere(ctx));
        } catch (Throwable ignore) {
        }
        nElsewhere = drop.size() - beforeElsewhere;

        // Which rule took them. Counts only, same reason as the caller's line.
        if (!drop.isEmpty()) {
            Log.i(TAG, "appheld exclusions: self/home=" + nSelfHome + " gone=" + nGone
                    + " unsuspendable=" + nUnsuspendable + " heldElsewhere=" + nElsewhere);
        }

        return drop;
    }

    // ---- the file -----------------------------------------------------------------------------------

    // ---- the rules, Context-free (BEGIN pure rules) -------------------------------------------------
    // core/chooser/test-app-held.sh compiles THIS region alone under javac (NWP-20261015-28): it may name nothing
    // but java.util and java.io types (readText takes a java.io.File, NWP-20261111-19). Everything the file format and the floors decide lives here; the Context code calls it.

    /** One parsed held list. */
    static final class Held {
        final java.util.List<String> pkgs;
        /** package -> the MONOTONIC instant it was released here. Empty when nothing has been released. */
        final java.util.Map<String, Long> released;
        final boolean stampMatched;

        Held(java.util.List<String> pkgs, java.util.Map<String, Long> released, boolean stampMatched) {
            this.pkgs = pkgs;
            this.released = released;
            this.stampMatched = stampMatched;
        }
    }

    /**
     * Parse the file's text. A file stamped for a DIFFERENT session (no line equal to {@code wantStamp}) is
     * EMPTY rather than unioned -- {@code StoreInstaller.snapshotAppSeen}'s rule, and for the same reason: a
     * blind union would let a file restored from another handset authorise holds this session never took.
     */
    static Held parseHeld(String text, String wantStamp) {
        java.util.List<String> pkgs = new java.util.ArrayList<>();
        java.util.Map<String, Long> released = new java.util.HashMap<>();
        boolean matched = false;
        for (String ln : text.split("\n")) {
            ln = ln.trim();
            if (ln.isEmpty()) continue;
            if (ln.equals(wantStamp)) { matched = true; continue; }
            if (ln.startsWith("#rel ")) {
                // "#rel <pkg> <elapsedRealtime>" -- when THIS package was released here.
                String[] bits = ln.substring(5).trim().split("[ ]+");
                if (bits.length == 2) {
                    try { released.put(bits[0], Long.parseLong(bits[1])); }
                    catch (Throwable ignore) { /* a malformed floor is no floor, never a wrong one */ }
                }
                continue;
            }
            if (ln.startsWith("#")) continue;
            if (ln.indexOf('/') < 0 && ln.indexOf('\\') < 0) pkgs.add(ln);
        }
        if (!matched) {
            return new Held(new java.util.ArrayList<String>(), new java.util.HashMap<String, Long>(), false);
        }
        return new Held(pkgs, released, true);
    }

    /**
     * The file's text. Every line that is not a package starts with {@code #}: {@code fileHeldList} on the agent
     * side skips those and publishes the rest, so a stamp or floor line without it would be sealed as a package.
     */
    static String renderHeld(String stamp, java.util.List<String> pkgs, java.util.Map<String, Long> released) {
        StringBuilder sb = new StringBuilder();
        sb.append("# what this handset is holding -- written by the chooser, read by the seal (NWP-20260912-06)\n");
        sb.append(stamp).append('\n');
        // Per-PACKAGE release floors. A single global floor could not express "release this one", and
        // worse, moving it released everything else opened this session as a side effect.
        java.util.List<String> relKeys = new java.util.ArrayList<>(released.keySet());
        java.util.Collections.sort(relKeys);
        for (String k : relKeys) {
            sb.append("#rel ").append(k).append(' ').append(released.get(k)).append('\n');
        }
        for (String p : pkgs) sb.append(p).append('\n');
        return sb.toString();
    }

    /**
     * The wall-clock instant a package must have been used at or after to be held: the LATER of sign-in and its
     * OWN release. The release is monotonic and converted only here, so an NTP correction cannot undo it.
     */
    static long floorWall(long sessionFloorWall, Long releasedElapsed, long nowWall, long nowElapsed) {
        return releasedElapsed == null ? sessionFloorWall
                : Math.max(sessionFloorWall, nowWall - (nowElapsed - releasedElapsed));
    }

    /** Release ONE package, or everything when {@code only} is null, recording each floor at {@code nowElapsed}. */
    static Held releaseOf(Held prev, String only, long nowElapsed) {
        java.util.Map<String, Long> rel = new java.util.HashMap<>(prev.released);
        java.util.List<String> keep = new java.util.ArrayList<>();
        for (String pkg : prev.pkgs) {
            if (only == null || only.equals(pkg)) {
                rel.put(pkg, nowElapsed);
            } else {
                keep.add(pkg);
            }
        }
        return new Held(keep, rel, prev.stampMatched);
    }

    /** The sign-out release: the list empties and the floors stay EXACTLY as they were (see releaseForSignOut). */
    static Held signOutOf(Held prev) {
        return new Held(new java.util.ArrayList<String>(), prev.released, prev.stampMatched);
    }

    /**
     * The list file's text: "" when it is ABSENT (the first refresh of a session), the whole text with one '\n'
     * after each line when it is readable, and NULL when it exists but cannot be opened or read whole (EIO, a wrong
     * owner after a restore, a directory at its path). Null is never "nothing": see read(Context).
     */
    static String readText(java.io.File f) {
        if (!f.exists()) return "";
        StringBuilder text = new StringBuilder();
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f))) {
            String ln;
            while ((ln = r.readLine()) != null) text.append(ln).append('\n');
        } catch (Throwable t) {
            return null; // exists but unreadable: the release floors live only in this file
        }
        return text.toString();
    }

    // ---- (END pure rules) -----------------------------------------------------------------------------

    private static File file(Context ctx) {
        return new File(ctx.getFilesDir(), FILE);
    }

    /**
     * Read the previous list; a file stamped for a different session is empty ({@link #parseHeld}), an absent
     * file is empty, and a file that exists but cannot be read is NULL ({@link #readText}).
     *
     * ⚠ AN UNREADABLE FILE IS NOT AN ABSENT ONE (NWP-20261111-19), the rule {@code AppClaim.readClaimsFile}
     * already keeps. The LIST could be re-derived from usage stats on the next tick, but the {@code #rel}
     * RELEASE FLOORS cannot: they exist only in this file. Read as empty, every writer wrote the list back
     * without them, and the next refresh re-added a released app whose usage row is still above the sign-in
     * floor, so the seal published it and the other handset suspended an app this phone was not using. So on
     * null every writer keeps the previous file, the rule {@link #refresh}'s catch states for its own failures.
     */
    private static Held read(Context ctx) {
        String text = readText(file(ctx));
        return text == null ? null : parseHeld(text, stamp(ctx));
    }

    private static void write(Context ctx, java.util.List<String> pkgs,
            java.util.Map<String, Long> released) throws java.io.IOException {
        StoreInstaller.writeAtomic(file(ctx), renderHeld(stamp(ctx), pkgs, released));
    }

    /** The Android user serial, and nothing else — see the class comment. */
    private static String stamp(Context ctx) {
        long serial = -1L;
        try {
            android.os.UserManager um = (android.os.UserManager) ctx.getSystemService(Context.USER_SERVICE);
            serial = um.getSerialNumberForUser(android.os.Process.myUserHandle());
        } catch (Throwable ignore) {
        }
        return "#stamp " + serial;
    }
}
