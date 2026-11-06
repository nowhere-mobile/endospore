// NWP-20261012-04: the cases for the chooser's "what does this Auto app need" decision, run against Lifted (run.sh).
// Chester, 2026-10-12: "installed an app from Appstore, when to your apps and clicked on install - its reinstalling it".
import java.util.*;

public final class PendingCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static String act(int a) {
        if (a == Lifted.AUTO_WHOLE) return "WHOLE";
        if (a == Lifted.AUTO_INSTALL) return "INSTALL";
        if (a == Lifted.AUTO_RESTORE_ONLY) return "RESTORE_ONLY";
        if (a == Lifted.AUTO_GROUP_DEP) return "GROUP_DEP";
        return "?" + a;
    }

    /** One app's state, as the three reads pendingAutoApps makes would see it. */
    static final class App {
        final boolean code, restored, placeholder;
        App(boolean code, boolean restored, boolean placeholder) {
            this.code = code; this.restored = restored; this.placeholder = placeholder;
        }
    }

    public static void main(String[] a) {
        // ---- the four constants are distinct, or every comparison below is meaningless ----
        Set<Integer> ids = new HashSet<>(Arrays.asList(Lifted.AUTO_WHOLE, Lifted.AUTO_INSTALL,
                Lifted.AUTO_RESTORE_ONLY, Lifted.AUTO_GROUP_DEP));
        check("the four actions are distinct", ids.size() == 4, ids);

        // ---- autoAction, every combination, against a table written out independently ----
        for (int m = 0; m < 8; m++) {
            boolean code = (m & 4) != 0, rest = (m & 2) != 0, ph = (m & 1) != 0;
            String want;
            if (code && rest) want = "WHOLE";            // installed and restored: nothing to do
            else if (code) want = "RESTORE_ONLY";        // installed, restore unconfirmed: NEVER fetch or reinstall
            else if (ph) want = "INSTALL";               // an archived placeholder is still pending
            else want = "GROUP_DEP";                     // no code, no placeholder: rides its entry point
            String got = act(Lifted.autoAction(code, rest, ph));
            check("autoAction(code=" + code + ", restored=" + rest + ", placeholder=" + ph + ") = " + want,
                    want.equals(got), got);
        }

        // ---- splitAuto: what the "Install pending apps now" row counts and what the sweep does ----
        // The two "code, no marker" apps are the same state to PackageManager and the markers; who installed them
        // (the App store, or our own materialise whose restore did not land) must not change the answer.
        Map<String, App> s = new LinkedHashMap<>();
        s.put("app.store", new App(true, false, false));          // the bug: App store install, restore unanswered
        s.put("app.store.healed", new App(true, true, false));    // the install-heal answered OK: whole
        s.put("app.ours", new App(true, false, false));           // our materialise, restore unanswered (frankel WhatsApp)
        s.put("app.placeholder", new App(false, false, true));    // an archived placeholder at login: pending
        s.put("app.rearchived", new App(false, true, true));      // re-archived (#206), marker left over: pending
        s.put("app.groupdep", new App(false, false, false));      // launcher-less group member
        s.put("app.placeholder2", new App(false, false, true));

        List<String> retry = new ArrayList<>(), deps = new ArrayList<>();
        List<String> work = Lifted.splitAuto(s.keySet(),
                p -> s.get(p).code, p -> s.get(p).restored, p -> s.get(p).placeholder, retry, deps);

        check("a store-installed app without the marker is NOT pending (not counted, not reinstalled)",
                !work.contains("app.store"), work);
        check("a store-installed app without the marker gets a restore-only retry", retry.contains("app.store"), retry);
        check("a store-installed app whose heal answered OK is neither pending nor retried",
                !work.contains("app.store.healed") && !retry.contains("app.store.healed"), work + " / " + retry);
        check("our own materialised app without the marker is NOT re-downloaded or reinstalled",
                !work.contains("app.ours"), work);
        check("our own materialised app without the marker keeps its restore retry", retry.contains("app.ours"), retry);
        check("an archived placeholder is still pending", work.contains("app.placeholder"), work);
        check("a re-archived placeholder is pending even with the marker left over", work.contains("app.rearchived"), work);
        check("a group dep rides its entry point, never alone", deps.equals(Collections.singletonList("app.groupdep"))
                && !work.contains("app.groupdep") && !retry.contains("app.groupdep"), deps);
        check("the pending list is exactly the placeholders, in keep-set order",
                work.equals(Arrays.asList("app.placeholder", "app.rearchived", "app.placeholder2")), work);
        check("the restore-only list is exactly the installed, unrestored apps, in order",
                retry.equals(Arrays.asList("app.store", "app.ours")), retry);

        System.out.println(runs + " checks, " + fails + " failed");
        if (fails > 0) System.exit(1);
    }
}
