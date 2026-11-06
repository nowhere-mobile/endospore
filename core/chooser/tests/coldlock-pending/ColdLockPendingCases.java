import java.util.*;

/** NWP-20261022-25: the lifted GET-COLDLOCK-PENDING reply parser, the reap guard and the reap helper. */
public class ColdLockPendingCases {
    static int failed = 0;

    static void check(String name, boolean ok) {
        if (ok) System.out.println("ok " + name);
        else { System.out.println("FAIL " + name); failed++; }
    }

    static void parse(String name, String reply, int want) {
        int got = Lifted.parsePendingColdLock(reply);
        check("parse " + name + " -> " + want + (got == want ? "" : " (got " + got + ")"), got == want);
    }

    static void due(int pending, int fresh, boolean unlocked, boolean want) {
        check("pendingReapDue(" + pending + ", " + fresh + ", " + unlocked + ") -> " + want,
                Lifted.pendingReapDue(pending, fresh, unlocked) == want);
    }

    static final android.content.Context CTX = new android.content.Context() {
        public Object getSystemService(String n) { return new android.app.admin.DevicePolicyManager(); }
    };

    static List<String> reap(String mode) {
        android.util.Log.EVENTS.clear();
        Lifted.daemon.clear();
        Lifted.cleaned.clear();
        android.app.admin.DevicePolicyManager.mode = mode;
        new Lifted().reapSupersededColdLock(CTX, 12, 15);
        return new ArrayList<>(android.util.Log.EVENTS);
    }

    public static void main(String[] a) {
        parse("PENDING 12", "PENDING 12", 12);
        parse("PENDING 12 with a newline", "PENDING 12\n", 12);
        parse("PENDING 0", "PENDING 0", -1);
        parse("PENDING -3", "PENDING -3", -1);
        parse("PENDING x", "PENDING x", -1);
        parse("PENDING with no uid", "PENDING ", -1);
        parse("NONE", "NONE", -1);
        parse("a COLDLOCK line", "COLDLOCK 12 nokey nopin a", -1);
        parse("null", null, -1);
        parse("empty", "", -1);

        due(12, 15, false, true);
        due(12, 15, true, false);
        due(12, 12, false, false);
        due(-1, 15, false, false);
        due(0, 15, false, false);

        List<String> ev = reap("true");
        check("reap, removal accepted: logs, cleans, then clears the marker",
                ev.equals(Arrays.asList("i:#123 reap superseded cold-lock user 12 (superseded by login 15)",
                        "clean:12", "daemon:CLEAR-COLDLOCK")));
        check("reap removed user 12", android.app.admin.DevicePolicyManager.removed == 12);
        ev = reap("false");
        check("reap, removal refused: no clean, a warning, still clears the marker",
                ev.size() == 3 && ev.get(0).startsWith("i:#123 reap superseded")
                        && ev.get(1).startsWith("w:#123 removeUser 12 refused") && ev.get(2).equals("daemon:CLEAR-COLDLOCK")
                        && Lifted.cleaned.isEmpty());
        ev = reap("throw");
        check("reap, removal throws: no clean, still clears the marker",
                Lifted.cleaned.isEmpty() && ev.get(ev.size() - 1).equals("daemon:CLEAR-COLDLOCK")
                        && ev.stream().anyMatch(s -> s.startsWith("w:reap superseded cold-lock")));

        System.exit(failed == 0 ? 0 : 1);
    }
}
