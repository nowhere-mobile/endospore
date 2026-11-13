package com.nowhere.chooser;

/**
 * NWP-20261202-21: the link that opens the GrapheneOS App Store at Play Store's entry, and the rule that picks what
 * the Google Play row opens. docs/product-decisions.md, 2026-11-10 (item 1: the row's tap landed on the store's main
 * list, "so the slice finds a way to open the Play entry for the prompt and the row alike") and 2026-11-01 (h50 #7
 * A1: the row opens the App Store's Play page). Pure java.lang, so test-gos-store-link-java.sh compiles it as-is.
 *
 * The link is Android's standard store detail link: ACTION_SHOW_APP_INFO with EXTRA_PACKAGE_NAME, sent only to the
 * store (setPackage). The store handles it (github.com/GrapheneOS/AppStore, tag 37, commit 4315c325):
 * app/src/main/AndroidManifest.xml:42-44 puts a SHOW_APP_INFO filter on .ui.MainActivity, and
 * app/src/main/java/app/grapheneos/apps/ui/MainActivity.kt:73-79 (onCreate) reads EXTRA_PACKAGE_NAME and opens that
 * package's details screen. The filter has no DEFAULT category, so startActivity cannot resolve the package-only
 * link: the caller resolves it with flags 0 and starts the resolved activity, as AOSP Settings' AppStoreUtil does.
 *
 * STORE_LIST exists only for a store build where the link does not resolve. It is today's shipped behaviour (the
 * store's launch intent), not a new choice. The 2026-11-10 decision does not settle it, so it is raised with Chester:
 * keep the list there, or show only the toast.
 *
 * The caller logs one of the three fixed lines below and nothing else: no package or profile name.
 */
final class GosStoreLink {

    static final String STORE_PKG = "app.grapheneos.apps";              // = ProfileActivity.GOS_STORE_PKG; the suite pins both
    static final String ACTION = "android.intent.action.SHOW_APP_INFO"; // = Intent.ACTION_SHOW_APP_INFO
    static final String EXTRA = "android.intent.extra.PACKAGE_NAME";    // = Intent.EXTRA_PACKAGE_NAME
    static final String ENTRY_PKG = PlayChoice.VENDING;                 // Play Store's entry in the store

    /** What the row opens: the store at Play Store's entry, the store's list, or nothing (the toast). */
    enum Route { PLAY_ENTRY, STORE_LIST, NONE }

    static final String LOG_ENTRY = "gos store: opened at the Play entry";
    static final String LOG_LIST = "gos store: no Play entry link, opened the store's list";
    static final String LOG_NONE = "gos store: not opened";

    private GosStoreLink() {}

    /** The entry when the link resolves to a store activity; else the store's list when it has a launch intent;
     *  else nothing. */
    static Route route(boolean entryResolves, boolean launchIntentPresent) {
        if (entryResolves) return Route.PLAY_ENTRY;
        return launchIntentPresent ? Route.STORE_LIST : Route.NONE;
    }
}
