package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Predicate;

/**
 * NWP-20261205-12 (DECIDED UNBUILT 2026-11-06; the backlog row "Tapping an app that is not on the phone in Your apps
 * does not fetch it" is the record): in Your apps, a tap on the icon of a kept app with no code asks first and then
 * fetches it. Chester: "lets follow the same style as play setup", so the question is dn-1023 #5's
 * {@link PlayFetchAskActivity}, with the size and h49 #9's {@link PlayFetchAsk#WHERE}. Which rows ask is no new rule:
 * nApps' Download rule, StoreService.mayMaterializeOwn (NWP-20261119-19).
 *
 * Pure: no android.* import, so test-yourapps-fetch-java.sh compiles it with its cases under javac. The tap is
 * ProfileActivity.yourAppsTap.
 *
 * ⚠ {@link #UNKNOWN_APP} and {@link #ICON_DESC} are DRAFT words, NOT final copy: the PR shows them to Chester.
 */
final class YourAppsFetch {
    private YourAppsFetch() {}

    /** DRAFT. The body for an app with no Play-stack dep when the size could not be read. */
    static final String UNKNOWN_APP = "The download size could not be read. " + PlayFetchAsk.WHERE + " Download now?";

    /** DRAFT. The icon's content description is ICON_DESC + the row's label. */
    static final String ICON_DESC = "Download ";

    /** What the tap fetches, and what APP-FETCH-SIZE sizes: the deps with no code, in order, then pkg. A null deps
     *  reads as empty. */
    static List<String> sizeSet(String pkg, List<String> deps, Predicate<String> hasCode) {
        List<String> out = new ArrayList<>();
        if (deps != null) for (String d : deps) if (d != null && !hasCode.test(d)) out.add(d);
        out.add(pkg);
        return out;
    }

    /** The question's body. A known size uses the Play setup's words; bytes <= 0 means the size is unknown, and then
     *  only an app that needs the Play stack says so. */
    static String message(long bytes, boolean playStack) {
        if (bytes > 0) return PlayFetchAsk.message(bytes);
        return playStack ? PlayFetchAsk.UNKNOWN : UNKNOWN_APP;
    }
}
