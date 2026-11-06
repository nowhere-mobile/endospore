package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.function.Predicate;

/** NWP-20261122-06: the Google Play row in Profile › Apps (docs/product-decisions.md, 2026-11-01, "twenty-two answers
 *  to harvests 50, 51 and 52 ...", h50 #7: A1 with the not-installed row, B1 (i), B2). Pure java.util, so
 *  test-play-choice-java.sh compiles and runs it as-is.
 *
 *  The choice is the nowhere-config key play.wanted, so it roams with nowhere-config. It has THREE states:
 *    - absent: no choice made. The row shows On when Play Store is kept or installed, else Off; reconcile and the
 *      install receiver behave exactly as before this slice.
 *    - "1": on. A1: Play Store, Play services and GSF are kept On-demand whenever they are installed, whatever the
 *      GrapheneOS App Store's own default (apps.default.gos, Off unless changed) says.
 *    - "0": off. B1 (i): Off drops Play Store only. Play services and GSF leave through reconcilePlayStack once
 *      nothing needs them, and an app that needs Play keeps its mode and meets the PlayNeed refusal at its tap. That
 *      is how B1 (i) reads the decision's "an Off that drops the group". reconcilePlayStack does not put Play Store
 *      back while the flag is off. B2: the Google account leaves through "Sign out of Google", mark first.
 *
 *  ⚠ ABSENT IS NEVER OFF. Every profile made before this slice has no flag, and reading that as off would drop a
 *  working Play Store at the profile's next keep-set edit. Only the literal "0" is off. ProfileActivity.cfgStatic
 *  answers "off" for an absent key, and parse reads that as absent too.
 *
 *  Diaspore: no GrapheneOS App Store, so offered() is false and no row is drawn. The flag still roams in nowhere-config,
 *  so a profile that chose on or off on Endospore carries it to a Diaspore phone: effective() reads it as absent there,
 *  and reconcilePlayStack and the install receiver both read it through effective(), so neither acts on it. */
final class PlayChoice {
    private PlayChoice() {}

    static final String CFG_KEY = "play.wanted";

    enum State { ABSENT, ON, OFF }

    /** "1" is on, "0" is off; anything else (null, "", the "off" fallback of cfgStatic, junk) is absent. */
    static State parse(String raw) {
        if (raw == null) return State.ABSENT;
        String v = raw.trim();
        if ("1".equals(v)) return State.ON;
        if ("0".equals(v)) return State.OFF;
        return State.ABSENT;
    }

    /** The state the consumers act on: the stored one where the GrapheneOS App Store is installed (Endospore), absent
     *  everywhere else. Diaspore has no row to change the flag, so a roamed flag must not change anything there. */
    static State effective(State stored, boolean gosStorePresent) {
        return gosStorePresent ? stored : State.ABSENT;
    }

    /** The value written for a state. Absent is never written: there is no way back to "no choice made". */
    static String raw(State s) {
        if (s == State.ON) return "1";
        if (s == State.OFF) return "0";
        throw new IllegalArgumentException("absent is never written");
    }

    // ---- the drafted words (for Chester to correct, like the row's other words) ----
    static final String TITLE = "Google Play";
    static final String ON_TEXT = "On";
    static final String OFF_TEXT = "Off";
    /** The decided draft, verbatim (h50 #7, "the addition Chester accepted"). */
    static final String NOT_INSTALLED = "On · not installed yet — tap to install from the GrapheneOS App Store";
    static final String OFF_TITLE = "Turn Google Play off?";
    static final String OFF_MESSAGE = "Turning Google Play off removes Play Store from this profile at the next save. "
            + "Your Google account is signed out here, and apps that sign in with it will ask again.";
    static final String OFF_CONFIRM = "Turn off";
    static final String OFF_CANCEL = "Cancel";

    /** Does the row read On? Absent follows what the profile holds (Play Store kept or installed); only an explicit
     *  choice overrides it. Keep membership counts ONLY here, for the absent state. */
    static boolean shownOn(State s, boolean vendingKept, boolean vendingInstalled) {
        if (s == State.ON) return true;
        if (s == State.OFF) return false;
        return vendingInstalled || vendingKept;
    }

    /** The row's subtitle. Once the row reads On, only the installation state picks "On" or the not-installed text:
     *  a Play Store that is kept but not on this phone still has to be installed, so the row says so. "Installed" is
     *  PackageManager's answer for this user, an archived On-demand placeholder included (ProfileActivity.playRow). */
    static String rowText(State s, boolean vendingKept, boolean vendingInstalled) {
        if (!shownOn(s, vendingKept, vendingInstalled)) return OFF_TEXT;
        return vendingInstalled ? ON_TEXT : NOT_INSTALLED;
    }

    enum Tap { TURN_ON, OPEN_STORE, CONFIRM_OFF }

    /** What a tap on the row does: Off turns Play on; On but not installed opens the App Store; On asks before Off.
     *  It reads the same inputs as rowText, so the words and the tap cannot disagree. */
    static Tap tap(State s, boolean vendingKept, boolean vendingInstalled) {
        if (!shownOn(s, vendingKept, vendingInstalled)) return Tap.TURN_ON;
        return vendingInstalled ? Tap.CONFIRM_OFF : Tap.OPEN_STORE;
    }

    // The literals equal ProfileActivity's VENDING_PKG / GMS_PKG / GSF_PKG and MODE_ONDEMAND; the suite pins both.
    static final String VENDING = "com.android.vending";
    static final String GMS = "com.google.android.gms";
    static final String GSF = "com.google.android.gsf";
    static final String ONDEMAND = "ondemand";

    static boolean isStackMember(String pkg) {
        return VENDING.equals(pkg) || GMS.equals(pkg) || GSF.equals(pkg);
    }

    /** What "on" marks On-demand at the moment the user turns Play on (A1): each of Play Store, Play services and GSF
     *  that is installed, Play Store first, whatever mode it is kept at now. Play Store goes first so that it is the
     *  user's keep (nowhere-playdeps) before the services are marked: reconcilePlayStack owns their mode, and a kept
     *  Play Store is what demands them. */
    static List<String> onMarks(Predicate<String> installed) {
        List<String> out = new ArrayList<>();
        for (String p : new String[] {VENDING, GMS, GSF}) {
            if (installed.test(p)) out.add(p);
        }
        return out;
    }

    /** The keep-mode for a newly installed app. With Play on, a Play stack member is kept On-demand whatever its
     *  installer's default says (A1); every other case keeps defaultMode. */
    static String keepModeOnInstall(State s, String pkg, String defaultMode) {
        if (s == State.ON && isStackMember(pkg)) return ONDEMAND;
        return defaultMode;
    }

    /** With Play on, a Play Store install is the user's own keep: it goes in nowhere-playdeps, so reconcile keeps it
     *  (and Play services with it) while no other app needs Play, instead of dropping it at the next keep-set edit. */
    static boolean userKeepsOnInstall(State s, String pkg) {
        return s == State.ON && VENDING.equals(pkg);
    }

    private static final Set<String> OFF_DROPS = Collections.singleton(VENDING);

    /** What Off drops from the keep-set: Play Store alone (B1 (i)). */
    static Set<String> offDrops() {
        return OFF_DROPS;
    }

    /** Off only: reconcilePlayStack never puts Play Store back. Absent and on leave reconcile as it was. */
    static boolean blocksVendingReadd(State s) {
        return s == State.OFF;
    }

    /** The row is drawn where the GrapheneOS App Store is installed (Endospore), in a stored profile that is online:
     *  a throwaway is never sealed, and an offline session cannot sign the Google account out. */
    static boolean offered(boolean gosStorePresent, String sessionType, boolean offline) {
        return gosStorePresent && !offline && "STORED".equals(sessionType);
    }
}
