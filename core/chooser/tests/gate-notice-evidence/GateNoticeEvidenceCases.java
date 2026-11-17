import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** NWP-20261204-12: the evidence a gate issue report carries for the backlog row "After a sign-out the gate can show a
 *  missed call from inside the session, and a location icon". Runs GateNoticeEvidence's pure classifiers (lifted,
 *  executed: C1-C5), then pins the reads that cannot run without Android (P1-P8).
 *  args: <chooser java dir>. Exits 1 on any failed case or pin. */
public final class GateNoticeEvidenceCases {
    private static int fails = 0;

    static final String[] KEYS = {
        "gate_tel_notices", "gate_loss_notices", "gate_other_notices", "missed_call_receiver",
        "missed_call_broadcasts", "dialer_role", "location_grant", "location_on",
    };

    private static void ok(boolean cond, String what) {
        if (cond) {
            System.out.println("  ok    " + what);
        } else {
            System.out.println("  FAIL  " + what);
            fails++;
        }
    }

    private static void eq(String what, Object got, Object want) {
        boolean same = want instanceof int[] ? Arrays.equals((int[]) got, (int[]) want) : String.valueOf(want).equals(String.valueOf(got));
        String g = got instanceof int[] ? Arrays.toString((int[]) got) : String.valueOf(got);
        String w = want instanceof int[] ? Arrays.toString((int[]) want) : String.valueOf(want);
        ok(same, what + (same ? "" : ": got [" + g + "], want [" + w + "]"));
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

    private static String read(String p) throws Exception {
        return new String(Files.readAllBytes(Paths.get(p)), StandardCharsets.UTF_8);
    }

    /** The value of `static final String <name> = "...";` in src; null when absent. */
    private static String constant(String src, String name) {
        Matcher m = Pattern.compile("static final String " + name + " = \"([^\"]*)\";").matcher(src);
        return m.find() ? m.group(1) : null;
    }

    public static void main(String[] a) throws Exception {
        String dir = a[0];
        String sms = read(dir + "/SmsDeliverReceiver.java");
        String gne = read(dir + "/GateNoticeEvidence.java");
        String ca = read(dir + "/ChooserActivity.java");
        String mcr = read(dir + "/MissedCallReceiver.java");

        System.out.println("-- (a) the classifiers, executed");
        // The tags the gate's own posters use, read from the poster, so C1 also proves put() counts with them.
        String tel = constant(sms, "TEL_CHANNEL"), loss = constant(sms, "TEL_LOSS_TAG");
        ok(tel != null && loss != null && !tel.equals(loss), "C0 SmsDeliverReceiver names TEL_CHANNEL and TEL_LOSS_TAG, distinct");
        eq("C1 countTags {TEL, TEL, LOSS, x, null} -> {tel 2, loss 1, other 2}",
                Lifted.countTags(new String[]{tel, tel, loss, "x", null}, tel, loss), new int[]{2, 1, 2});
        eq("C1 countTags {} -> {0, 0, 0}", Lifted.countTags(new String[0], tel, loss), new int[]{0, 0, 0});
        eq("C2 grantName 0", Lifted.grantName(0), "default");
        eq("C2 grantName 1", Lifted.grantName(1), "policy_granted");
        eq("C2 grantName 2", Lifted.grantName(2), "policy_denied");
        eq("C2 grantName 7", Lifted.grantName(7), "unknown");
        eq("C3 receiverState -1", Lifted.receiverState(-1), "unreadable");
        eq("C3 receiverState 0", Lifted.receiverState(0), "absent");
        eq("C3 receiverState 3", Lifted.receiverState(3), "resolves");
        eq("C4 roleName (false, true)", Lifted.roleName(false, true), "unavailable");
        eq("C4 roleName (true, true)", Lifted.roleName(true, true), "held");
        eq("C4 roleName (true, false)", Lifted.roleName(true, false), "not_held");
        eq("C5 bucket -1", Lifted.bucket(-1), "0");
        eq("C5 bucket 0", Lifted.bucket(0), "0");
        eq("C5 bucket 1", Lifted.bucket(1), "1");
        eq("C5 bucket 2", Lifted.bucket(2), "2+");
        eq("C5 bucket 9", Lifted.bucket(9), "2+");

        System.out.println("-- (b) the reads, pinned in source");
        String gate = body(ca, "private String gateReportJson(");
        int ctx = gate.indexOf("st.put(\"context\", \"gate\");");
        int call = gate.indexOf("GateNoticeEvidence.put(this, st);");
        ok(ctx >= 0 && call > ctx, "P1 gateReportJson calls GateNoticeEvidence.put(this, st) after its context key");

        String put = body(gne, "static void put(");
        ok(!put.isEmpty(), "P2 GateNoticeEvidence holds static void put(");
        for (String k : KEYS) ok(put.contains("\"" + k + "\""), "P2 put() writes \"" + k + "\"");

        // Each key's first mention sits in its own try: the nearest try before it is a different one for every key.
        Set<Integer> tries = new HashSet<>();
        boolean own = true;
        for (String k : KEYS) {
            int at = put.indexOf("\"" + k + "\"");
            int t = at < 0 ? -1 : put.lastIndexOf("try {", at);
            if (t < 0 || !tries.add(t)) {
                own = false;
                System.out.println("        " + k + ": no try of its own");
            }
        }
        ok(own, "P3 every key is written inside its own try {");
        ok(count(put, "\"unreadable\"") >= KEYS.length, "P4 a failed read writes \"unreadable\" for each key (" + count(put, "\"unreadable\"") + " found)");

        for (String w : new String[]{"cancel", "notify", "setPermissionGrantState", "setLocationEnabled", "addRoleHolder", "Log."})
            ok(!put.contains(w), "P5 put() changes nothing: no [" + w + "]");
        for (String w : new String[]{"getNotification(", "extras", "EXTRA_"})
            ok(!put.contains(w), "P6 put() reads a notice's tag only: no [" + w + "]");

        String rcv = body(mcr, "public void onReceive(");
        int open = rcv.indexOf('{');
        String first = open < 0 ? "" : rcv.substring(open + 1).trim();
        ok(first.startsWith("RECEIVED.incrementAndGet();"), "P7 MissedCallReceiver.onReceive counts every broadcast first");
        ok(mcr.contains("static final java.util.concurrent.atomic.AtomicInteger RECEIVED = new java.util.concurrent.atomic.AtomicInteger();"),
                "P7 MissedCallReceiver declares RECEIVED");

        ok(put.contains("new android.content.Intent(MissedCallReceiver.ACTION).setPackage(ctx.getPackageName()), 0)"),
                "P8 put() makes Telecom's query: MissedCallReceiver.ACTION, this package");
        ok(put.contains("bucket(MissedCallReceiver.RECEIVED.get())"), "P8 put() reports the broadcasts bucketed");
        ok(put.contains("countTags(tags, SmsDeliverReceiver.TEL_CHANNEL, SmsDeliverReceiver.TEL_LOSS_TAG)"),
                "P8 put() counts with the posters' own tags");
        ok(put.contains("android.app.role.RoleManager.ROLE_DIALER"), "P8 put() reads the dialer role");
        ok(put.contains("android.Manifest.permission.ACCESS_FINE_LOCATION"), "P8 put() reads the fine-location grant");

        if (fails > 0) {
            System.out.println(fails + " FAILED");
            System.exit(1);
        }
        System.out.println("all passed");
    }
}
