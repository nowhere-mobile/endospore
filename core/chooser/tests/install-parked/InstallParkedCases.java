import java.nio.file.Files;
import java.nio.file.Paths;

// NWP-20261101-15: the cases for "an Install at the gate over a parked session asks first" (Q062). args[0] =
// ChooserActivity.java. The title, the text and the decision run against Lifted; the listener's wiring is checked as
// source.
public final class InstallParkedCases {
    static int fails = 0;

    static void check(String name, boolean ok, Object got) {
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static final String BASE = " locked on this phone. Installing restarts the phone, which ends that session: "
            + "anything it hasn't saved is lost.";
    static final String CREDIT = " That includes storage credit it hasn't saved.";

    public static void main(String[] a) throws Exception {
        String src = new String(Files.readAllBytes(Paths.get(a[0])), "UTF-8");
        check("title", "Install and restart?".equals(Lifted.installOverParkedTitle()), Lifted.installOverParkedTitle());
        String[] p = Lifted.parseColdLock("COLDLOCK 10 nokey nopin alice smith");
        check("text: named, no credit", ("alice smith's session is" + BASE).equals(Lifted.installOverParkedText(p, false)),
                Lifted.installOverParkedText(p, false));
        check("text: named, credit", ("alice smith's session is" + BASE + CREDIT).equals(Lifted.installOverParkedText(p, true)),
                Lifted.installOverParkedText(p, true));
        check("text: nameless, no credit", ("A session is" + BASE).equals(Lifted.installOverParkedText(null, false)),
                Lifted.installOverParkedText(null, false));
        check("text: nameless, credit", ("A session is" + BASE + CREDIT).equals(Lifted.installOverParkedText(null, true)),
                Lifted.installOverParkedText(null, true));
        check("ask: a parked session", Lifted.installAsksFirst("COLDLOCK 10 nokey nopin alice"), "false");
        check("ask: NONE installs at once", !Lifted.installAsksFirst("NONE"), "true");
        check("ask: an empty reply warns", Lifted.installAsksFirst(""), "false");
        check("ask: a null reply warns", Lifted.installAsksFirst(null), "false");
        check("credit: LOST", Lifted.parkedCreditLost("LOST"), "false");
        check("credit: NONE", !Lifted.parkedCreditLost("NONE"), "true");

        int at = src.indexOf("install.setOnClickListener(");
        int end = src.indexOf("TextView back = new TextView(this);", at);
        check("listener found", at > 0 && end > at, at + "/" + end);
        String l = src.substring(at, end);
        int cl = l.indexOf("GET-COLDLOCK");
        check("listener reads GET-COLDLOCK", cl >= 0, "absent");
        check("listener does not send OTA-APPLY itself (it runs in the start body)", !l.contains("OTA-APPLY"), "present");
        String pre = src.substring(Math.max(0, at - 1200), at);
        int body = pre.indexOf("final Runnable startInstall");
        check("start body is where OTA-APPLY is sent", body >= 0 && pre.indexOf("OTA-APPLY", body) > body, "absent");
        check("listener reads before it starts", cl >= 0 && l.indexOf("startInstall") > cl, "order");
        check("a parked answer asks before starting",
                l.contains("confirmInstallOverParked(parsed, lost, startInstall)"), "absent");
        check("the no-parked path starts at once",
                l.contains("if (!installAsksFirst(cl)) {\n                runOnUiThread(startInstall);"), "absent");
        check("unanswered read is held as empty", l.contains("String cl = \"\";"), "absent");
        check("credit read only for a named session", l.contains("if (parseColdLock(cl) != null) {"), "absent");
        System.out.println(fails == 0 ? "OK" : fails + " FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }
}
