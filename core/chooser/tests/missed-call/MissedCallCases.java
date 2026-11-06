import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import javax.xml.parsers.DocumentBuilderFactory;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;

/** NWP-20261012-07: user 0's answer to Telecom's missed-call broadcast, so Telecom never posts its own notification
 *  with the caller's number. Runs MissedCallReceiver.plan (lifted, executed), then checks the manifest entry that makes
 *  Telecom choose the broadcast, and the wiring that cannot run without Android.
 *  args: <AndroidManifest.xml> <chooser java dir> <pins dir>. Exits 1 on any failed case. */
public final class MissedCallCases {
    private static int fails = 0;

    private static void ok(boolean cond, String what) {
        if (cond) {
            System.out.println("  ok    " + what);
        } else {
            System.out.println("  FAIL  " + what);
            fails++;
        }
    }

    private static void lacks(String what, String body, String needle) {
        ok(!body.contains(needle), what + (body.contains(needle) ? ": has [" + needle + "]" : ""));
    }

    /** The body of the method whose signature contains sig, through its closing brace; "" when absent. */
    private static String body(String src, String sig) {
        int i = src.indexOf(sig);
        if (i < 0) return "";
        int depth = 0;
        for (int j = src.indexOf('{', i); j >= 0 && j < src.length(); j++) {
            char c = src.charAt(j);
            if (c == '{') depth++;
            if (c == '}' && --depth == 0) return src.substring(i, j + 1);
        }
        return "";
    }

    private static int count(String hay, String needle) {
        int n = 0;
        for (int i = hay.indexOf(needle); i >= 0; i = hay.indexOf(needle, i + needle.length())) n++;
        return n;
    }

    /** A pin file's text, less the one newline that ends the file. */
    private static String pin(String dir, String name) throws Exception {
        String p = read(dir + "/" + name);
        return p.endsWith("\n") ? p.substring(0, p.length() - 1) : p;
    }

    /** The whole method, from sig to its closing brace, must equal pins/<name>.txt. */
    private static void pinMethod(String what, String src, String sig, String dir, String name) throws Exception {
        String want = pin(dir, name + ".txt");
        String got = body(src, sig);
        if (got.equals(want)) {
            ok(true, what);
            return;
        }
        String[] g = got.split("\n", -1), w = want.split("\n", -1);
        int i = 0;
        while (i < g.length && i < w.length && g[i].equals(w[i])) i++;
        ok(false, what + ": differs from pins/" + name + ".txt at line " + (i + 1)
                + (i < g.length ? " [" + g[i] + "]" : " (source ends)"));
    }

    /** The fragment in pins/<name>.frag.txt must appear in src exactly once. */
    private static void pinFrag(String what, String src, String dir, String name) throws Exception {
        int n = count(src, pin(dir, name + ".frag.txt"));
        ok(n == 1, what + (n == 1 ? "" : ": pins/" + name + ".frag.txt found " + n + " time(s), want 1"));
    }

    private static String read(String p) throws Exception {
        return new String(Files.readAllBytes(Paths.get(p)), StandardCharsets.UTF_8);
    }

    public static void main(String[] a) throws Exception {
        final String act = "android.telecom.action.SHOW_MISSED_CALLS_NOTIFICATION";

        // --- the decision, executed ---
        ok(Lifted.ACTION.equals(act), "P1 the action is TelecomManager.ACTION_SHOW_MISSED_CALLS_NOTIFICATION");
        ok(Lifted.EXTRA_COUNT.equals("android.telecom.extra.NOTIFICATION_COUNT"),
                "P2 the count extra is TelecomManager.EXTRA_NOTIFICATION_COUNT");
        ok(Lifted.plan(act, 0, 1) == Lifted.SCRUB_RESET, "P3 one missed call in user 0: scrub and reset");
        ok(Lifted.plan(act, 0, 7) == Lifted.SCRUB_RESET, "P4 several missed calls in user 0: scrub and reset");
        ok(Lifted.plan(act, 0, -1) == Lifted.SCRUB_RESET, "P5 no count in user 0: scrub and reset (scrubbing is safe)");
        ok(Lifted.plan(act, 0, 0) == Lifted.DROP, "P6 a count of 0 (Telecom's dismiss, the echo of our cancel): drop");
        ok(Lifted.plan(act, 10, 1) == Lifted.DROP, "P7 a roamed user: never scrub that session's call log");
        ok(Lifted.plan(act, 10, -1) == Lifted.DROP, "P8 a roamed user with no count: drop");
        ok(Lifted.plan("android.intent.action.BOOT_COMPLETED", 0, 1) == Lifted.DROP, "P9 another action: drop");
        ok(Lifted.plan(null, 0, 1) == Lifted.DROP, "P10 no action: drop");
        ok(Lifted.DROP != Lifted.SCRUB_RESET, "P11 the two outcomes differ");

        // --- the manifest entry: Telecom posts its own notice unless user 0's dialer RESOLVES this receiver ---
        DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
        Document doc = f.newDocumentBuilder().parse(new File(a[0]));
        NodeList rs = doc.getElementsByTagName("receiver");
        Element mine = null;
        int filters = 0;
        for (int i = 0; i < rs.getLength(); i++) {
            Element r = (Element) rs.item(i);
            NodeList acts = r.getElementsByTagName("action");
            for (int k = 0; k < acts.getLength(); k++) {
                if (act.equals(((Element) acts.item(k)).getAttribute("android:name"))) {
                    filters++;
                    mine = r;
                }
            }
        }
        ok(filters == 1, "M1 exactly one receiver filters the action (found " + filters + ")");
        ok(mine != null && ".MissedCallReceiver".equals(mine.getAttribute("android:name")),
                "M2 that receiver is .MissedCallReceiver");
        ok(mine != null && "true".equals(mine.getAttribute("android:exported")),
                "M3 it is exported (Telecom's broadcast comes from the system)");
        ok(mine != null && !mine.hasAttribute("android:permission"),
                "M4 it demands no permission of its sender (the action is a protected broadcast)");
        ok(mine != null && (!mine.hasAttribute("android:enabled") || "true".equals(mine.getAttribute("android:enabled"))),
                "M5 it is enabled: the attribute absent or exactly \"true\" (never false, never a resource)");
        // Telecom resolves the receiver with an intent that carries the action and nothing else -- no data, no type, no
        // category. A <data> in the filter makes that query miss it, and Telecom then posts its own notice again.
        NodeList myFilters = mine == null ? null : mine.getElementsByTagName("intent-filter");
        ok(myFilters != null && myFilters.getLength() == 1, "M8 it has exactly one intent-filter");
        if (myFilters != null && myFilters.getLength() == 1) {
            Element fl = (Element) myFilters.item(0);
            int kids = 0;
            for (org.w3c.dom.Node n = fl.getFirstChild(); n != null; n = n.getNextSibling()) {
                if (n.getNodeType() == org.w3c.dom.Node.ELEMENT_NODE) kids++;
            }
            ok(fl.getElementsByTagName("action").getLength() == 1, "M9 the filter has exactly one <action>");
            ok(fl.getElementsByTagName("data").getLength() == 0, "M10 the filter has NO <data> (Telecom's intent has none)");
            ok(kids == 1, "M11 the filter holds nothing but that action (found " + kids + " elements)");
        }
        // A roamed user's chooser must not take that user's broadcast: the receiver is disabled there at sign-in.
        java.util.List<String> dial = java.util.Arrays.asList(Lifted.roamedDialerComponents());
        ok(dial.equals(java.util.Arrays.asList(".MissedCallReceiver")),
                "R1 roamedDialerComponents is exactly [.MissedCallReceiver] (got " + dial + ")");
        ok(mine != null && dial.contains(mine.getAttribute("android:name")),
                "R2 the receiver that filters the action is one disabled in a roamed user");
        ok(mine != null && mine.getParentNode() != null && "application".equals(mine.getParentNode().getNodeName()),
                "M6 it is declared in <application>");
        String man = read(a[0]);
        ok(man.contains("android:name=\"android.permission.READ_PHONE_STATE\""),
                "M7 the chooser requests READ_PHONE_STATE (Telecom's receiver permission)");

        // --- the wiring, which cannot run without Android: pinned byte for byte (pins/, edited by hand with the code) ---
        String rcv = read(a[1] + "/MissedCallReceiver.java");
        String ca = read(a[1] + "/ChooserActivity.java");
        String ics = read(a[1] + "/NowhereInCallService.java");
        String ts = read(a[1] + "/TelScrub.java");
        pinMethod("W1 MissedCallReceiver.onReceive", rcv, "public void onReceive(", a[2], "MissedCallReceiver.onReceive");
        String on = body(rcv, "public void onReceive(");
        ok(count(on, "pr.finish()") == 1 && count(rcv, "pr.finish()") == 1, "W2 pr.finish() is called once, in the finally");
        lacks("W9 it posts nothing", rcv, "notify(");
        lacks("W10 it builds no notification", rcv, "Notification.Builder");
        lacks("W11 it never reads the caller's number", rcv, "getStringExtra");
        lacks("W12 nor names the number extra", rcv, "NOTIFICATION_PHONE_NUMBER");
        ok(rcv.contains("public final class MissedCallReceiver extends BroadcastReceiver"),
                "W13 it is a BroadcastReceiver the manifest can name");
        pinMethod("T1 TelScrub.callLog deletes every user-0 call-log row", ts, "static void callLog(", a[2], "TelScrub.callLog");
        pinMethod("I1 cancelFrameworkMissedCall: 4 cancels, 400 ms apart", ics, "static void cancelFrameworkMissedCall(", a[2],
                "NowhereInCallService.cancelFrameworkMissedCall");
        pinFrag("I2 the #197 Recorder scrubs, then cancels Telecom's notice", ics, a[2], "NowhereInCallService.recorderCancel");
        pinFrag("G1 the gate-return thread scrubs, then cancels Telecom's notice", ca, a[2], "ChooserActivity.gateScrub");
        pinFrag("R3 every sign-in disables the dialer components in the new roamed user, beside the SMS cede", ca, a[2],
                "ChooserActivity.login.dialer");
        pinMethod("R4 disableRoamedDialerComponents: never user 0, DISABLED, every listed component", ca,
                "private void disableRoamedDialerComponents(", a[2], "ChooserActivity.disableRoamedDialerComponents");
        ok(count(ca, "disableRoamedDialerComponents(") == 2, "R5 disableRoamedDialerComponents has one caller, the sign-in");

        if (fails > 0) {
            System.out.println("  -- " + fails + " failed");
            System.exit(1);
        }
        System.out.println("  -- all passed");
    }
}
