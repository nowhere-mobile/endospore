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

        // NWP-20261207-07: app.groupdep is a real group dep -- a placeholder entry point lists it, so `rides` names it.
        Set<String> rides = new HashSet<>(Collections.singleton("app.groupdep"));
        List<String> retry = new ArrayList<>(), deps = new ArrayList<>(), alone = new ArrayList<>();
        List<String> work = Lifted.splitAuto(s.keySet(),
                p -> s.get(p).code, p -> s.get(p).restored, p -> s.get(p).placeholder, rides::contains,
                retry, deps, alone);

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
        check("no app here is installed alone: the only no-placeholder app rides", alone.isEmpty(), alone);

        // ---- riders: the no-code apps an entry point of the deferred keep-set will carry (NWP-20261207-07) ----
        // Chester, NW-3b37, 2026-11-04: "Switched [the app] to auto, don't see it's getting downloaded".
        Map<String, App> e = new LinkedHashMap<>();
        Map<String, List<String>> edeps = new HashMap<>();
        e.put("E1", new App(false, false, true));  edeps.put("E1", Arrays.asList("d1"));       // placeholder: carries
        e.put("E2", new App(true, true, false));   edeps.put("E2", Arrays.asList("d2"));       // has code: never materialised again
        e.put("E3", new App(false, false, false)); edeps.put("E3", Arrays.asList("d3"));       // no placeholder: never materialised
        e.put("G", new App(false, false, true));   edeps.put("G", Arrays.asList("G", "d4"));   // a group: lists itself too
        Set<String> carried = Lifted.riders(e.keySet(), p -> e.get(p).code, p -> e.get(p).placeholder,
                p -> edeps.get(p));
        check("riders: a placeholder entry point without code carries its deps", carried.contains("d1"), carried);
        check("riders: an entry point with code carries nothing", !carried.contains("d2"), carried);
        check("riders: an entry point without a placeholder carries nothing", !carried.contains("d3"), carried);
        check("riders: a self-dep is dropped", !carried.contains("G") && carried.contains("d4"), carried);
        check("riders: exactly the deps of the placeholder entry points without code",
                carried.equals(new HashSet<>(Arrays.asList("d1", "d4"))), carried);

        // ---- splitAuto: an orphan (no code, no placeholder, nothing to ride) is installed alone ----
        Map<String, App> o = new LinkedHashMap<>();
        o.put("orphan", new App(false, false, false)); // switched to Auto, placeholder gone, no entry point lists it
        o.put("d1", new App(false, false, false));     // a real group dep: E1 above carries it
        o.put("ph1", new App(false, false, true));     // an archived placeholder
        List<String> oRetry = new ArrayList<>(), oDeps = new ArrayList<>(), oAlone = new ArrayList<>();
        List<String> oWork = Lifted.splitAuto(o.keySet(),
                p -> o.get(p).code, p -> o.get(p).restored, p -> o.get(p).placeholder, carried::contains,
                oRetry, oDeps, oAlone);
        check("an orphan is in the install list", oWork.contains("orphan"), oWork);
        check("a real group dep still rides, never alone",
                oDeps.equals(Collections.singletonList("d1")) && !oWork.contains("d1"), oWork + " / " + oDeps);
        check("alone names only the orphan", oAlone.equals(Collections.singletonList("orphan")), oAlone);
        check("the install list keeps input order", oWork.equals(Arrays.asList("orphan", "ph1")), oWork);
        check("the 'Install pending apps now' count includes the orphan", oWork.size() == 2, oWork.size());
        check("an orphan is never a restore-only retry", oRetry.isEmpty(), oRetry);

        System.out.println(runs + " checks, " + fails + " failed");
        if (fails > 0) System.exit(1);
    }
}
