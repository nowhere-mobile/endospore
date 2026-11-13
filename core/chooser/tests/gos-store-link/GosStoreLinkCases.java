package com.nowhere.chooser;

/**
 * NWP-20261202-21: GosStoreLink under javac, compiled as-is with PlayChoice. Run by
 * core/vendor-common/bin/test-gos-store-link-java.sh, which also pins the wiring these cases cannot see.
 *
 *   C1  the link's parts equal the Android literals (Intent.ACTION_SHOW_APP_INFO, Intent.EXTRA_PACKAGE_NAME), the
 *       store is app.grapheneos.apps and the entry is com.android.vending (= PlayChoice.VENDING); the three log lines
 *       are the decided text and name no package.
 *   C2  route(true, *) is PLAY_ENTRY: a link that resolves always wins.
 *   C3  route(false, true) is STORE_LIST.
 *   C4  route(false, false) is NONE.
 */
public final class GosStoreLinkCases {
    private static int runs, fails;

    private static void check(String name, boolean ok, String why) {
        runs++;
        if (ok) System.out.println("  PASS " + name);
        else { fails++; System.out.println("  FAIL " + name + ": " + why); }
    }

    public static void main(String[] a) {
        check("C1 ACTION is Intent.ACTION_SHOW_APP_INFO", "android.intent.action.SHOW_APP_INFO".equals(GosStoreLink.ACTION),
                "ACTION=" + GosStoreLink.ACTION);
        check("C1 EXTRA is Intent.EXTRA_PACKAGE_NAME", "android.intent.extra.PACKAGE_NAME".equals(GosStoreLink.EXTRA),
                "EXTRA=" + GosStoreLink.EXTRA);
        check("C1 STORE_PKG is the GrapheneOS App Store", "app.grapheneos.apps".equals(GosStoreLink.STORE_PKG),
                "STORE_PKG=" + GosStoreLink.STORE_PKG);
        check("C1 ENTRY_PKG is Play Store", "com.android.vending".equals(GosStoreLink.ENTRY_PKG),
                "ENTRY_PKG=" + GosStoreLink.ENTRY_PKG);
        check("C1 ENTRY_PKG is PlayChoice.VENDING", PlayChoice.VENDING.equals(GosStoreLink.ENTRY_PKG),
                "ENTRY_PKG=" + GosStoreLink.ENTRY_PKG);
        check("C1 LOG_ENTRY is the decided line", "gos store: opened at the Play entry".equals(GosStoreLink.LOG_ENTRY),
                "LOG_ENTRY=" + GosStoreLink.LOG_ENTRY);
        check("C1 LOG_LIST is the decided line",
                "gos store: no Play entry link, opened the store's list".equals(GosStoreLink.LOG_LIST),
                "LOG_LIST=" + GosStoreLink.LOG_LIST);
        check("C1 LOG_NONE is the decided line", "gos store: not opened".equals(GosStoreLink.LOG_NONE),
                "LOG_NONE=" + GosStoreLink.LOG_NONE);
        for (String l : new String[] {GosStoreLink.LOG_ENTRY, GosStoreLink.LOG_LIST, GosStoreLink.LOG_NONE}) {
            check("C1 the log line names no package: " + l, !l.contains("com.") && !l.contains("app.grapheneos"), l);
        }

        check("C2 route(true, true) is PLAY_ENTRY", GosStoreLink.route(true, true) == GosStoreLink.Route.PLAY_ENTRY,
                "route=" + GosStoreLink.route(true, true));
        check("C2 route(true, false) is PLAY_ENTRY", GosStoreLink.route(true, false) == GosStoreLink.Route.PLAY_ENTRY,
                "route=" + GosStoreLink.route(true, false));
        check("C3 route(false, true) is STORE_LIST", GosStoreLink.route(false, true) == GosStoreLink.Route.STORE_LIST,
                "route=" + GosStoreLink.route(false, true));
        check("C4 route(false, false) is NONE", GosStoreLink.route(false, false) == GosStoreLink.Route.NONE,
                "route=" + GosStoreLink.route(false, false));

        System.out.println("  " + (runs - fails) + "/" + runs + " cases passed");
        if (fails > 0) System.exit(1);
    }
}
