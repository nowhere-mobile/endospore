import java.util.Arrays;
import java.util.List;

/** NWP-20261113-39: ReportPreviewFilter's sections, tags, filter and matches over a preview in the exact shape of
 *  report_issue.go's json.MarshalIndent(rep, "", "  "). run.sh prepends the package line. */
public class ReportPreviewFilterCases {
    static int fails = 0;

    static void eq(String name, Object want, Object got) {
        if (want == null ? got == null : want.equals(got)) {
            System.out.println("  ok   " + name);
        } else {
            System.out.println("  FAIL " + name + "\n    want: " + want + "\n    got:  " + got);
            fails++;
        }
    }

    // The preview's lines, as the daemon writes them (\" in the Java source is a backslash-quote in the preview).
    static final String KIND = "  \"kind\": \"issue-report\",\n";
    static final String CREATED = "  \"created_at\": \"2026-10-23T12:00:00Z\",\n";
    static final String NOTE = "  \"note\": \"sync stalls\",\n";
    static final String ST_H = "  \"status\": {\n";
    static final String ST_1 = "    \"android_sdk\": \"34\",\n";
    static final String ST_2 = "    \"device\": \"Pixel 7a\"\n";
    static final String GATE_H = "    \"gate.log\": [\n";
    static final String GATE_1 = "      \"[logind] roam-in \\\"odtest10\\\" -\\u003e user 12\",\n";
    static final String GATE_2 = "      \"[resolver] lookup api-beta.nowhere.mobile ok\",\n";
    static final String GATE_3 = "      \"avc: denied { read } for comm=x\"\n";
    static final String LOGIN_H = "    \"login.log\": [\n";
    static final String LOGIN_1 = "      \"[roamd] fido2 profile \\\"odtest35\\\" -\\u003e requesting the security key\",\n";
    static final String LOGIN_2 = "      \"[logind] periodic seal \\\"odtest35\\\" user 11 -\\u003e OK\"\n";

    static final String P = "{\n" + KIND + CREATED + NOTE + ST_H + ST_1 + ST_2 + "  },\n"
            + "  \"logs\": {\n" + GATE_H + GATE_1 + GATE_2 + GATE_3 + "    ],\n"
            + LOGIN_H + LOGIN_1 + LOGIN_2 + "    ]\n" + "  }\n" + "}\n";

    static String ints(int[] a) { return Arrays.toString(a); }

    public static void main(String[] args) {
        eq("the sample holds an escaped quote", true, P.contains("\\\"odtest35\\\""));

        eq("sections: status, then the logs in order", Arrays.asList("status", "gate.log", "login.log"),
                ReportPreviewFilter.sections(P));
        eq("tags: distinct, first-seen order, the untagged line adds none",
                Arrays.asList("[logind]", "[resolver]", "[roamd]"), ReportPreviewFilter.tags(P));

        eq("filter(all, all) is the preview", P, ReportPreviewFilter.filter(P, null, null));
        eq("filter(login.log) is its header and its lines, byte for byte", LOGIN_H + LOGIN_1 + LOGIN_2,
                ReportPreviewFilter.filter(P, "login.log", null));
        eq("filter(gate.log) is its header and its three lines", GATE_H + GATE_1 + GATE_2 + GATE_3,
                ReportPreviewFilter.filter(P, "gate.log", null));
        eq("filter(status) is the status header and its entries", ST_H + ST_1 + ST_2,
                ReportPreviewFilter.filter(P, "status", null));
        eq("filter(tag [logind]) keeps those lines under their own headers", GATE_H + GATE_1 + LOGIN_H + LOGIN_2,
                ReportPreviewFilter.filter(P, null, "[logind]"));
        eq("filter(tag [resolver]) drops the headers of logs it keeps nothing of", GATE_H + GATE_2,
                ReportPreviewFilter.filter(P, null, "[resolver]"));
        eq("filter(login.log, [logind]) applies both", LOGIN_H + LOGIN_2,
                ReportPreviewFilter.filter(P, "login.log", "[logind]"));
        eq("filter(gate.log, [roamd]) keeps nothing", "", ReportPreviewFilter.filter(P, "gate.log", "[roamd]"));
        eq("filter(status, [logind]) keeps nothing: status entries carry no tag", "",
                ReportPreviewFilter.filter(P, "status", "[logind]"));
        eq("filter(an unknown section) keeps nothing", "", ReportPreviewFilter.filter(P, "ota.log", null));

        int[] want = new int[3];
        for (int i = 0, from = 0; i < 3; i++) { want[i] = P.indexOf("odtest", from); from = want[i] + 1; }
        eq("the oracle finds exactly three", -1, P.indexOf("odtest", want[2] + 1));
        eq("matches(odtest): three offsets", ints(want), ints(ReportPreviewFilter.matches(P, "odtest")));
        eq("matches(ODTEST): case-insensitive", ints(want), ints(ReportPreviewFilter.matches(P, "ODTEST")));
        eq("matches(oDtEsT35): case-insensitive", ints(new int[] {want[1], want[2]}),
                ints(ReportPreviewFilter.matches(P, "oDtEsT35")));
        eq("matches(aaa, aa): not overlapping", "[0]", ints(ReportPreviewFilter.matches("aaa", "aa")));
        eq("matches(empty query): none", 0, ReportPreviewFilter.matches(P, "").length);
        eq("matches(null query): none", 0, ReportPreviewFilter.matches(P, null).length);
        eq("matches(absent text): none", 0, ReportPreviewFilter.matches(P, "no such text").length);
        String g = ReportPreviewFilter.filter(P, "gate.log", null);
        eq("matches over the filtered text", ints(new int[] {g.indexOf("odtest")}),
                ints(ReportPreviewFilter.matches(g, "OdTeSt")));

        String[] bad = {
            "kind=issue-report\nlogs: gate.log\n",
            "{\n" + KIND + ST_H + ST_1 + ST_2 + "  }\n}\n",                                   // no "logs"
            "{\n" + KIND + "  \"logs\": {\n" + GATE_H + GATE_1 + "  }\n}\n",                     // unclosed log
            "{\n" + KIND + "  \"logs\": {\n" + GATE_H + "     \"[x] five spaces\"\n    ]\n  }\n}\n", // bad indent
            "",
        };
        for (int i = 0; i < bad.length; i++) {
            eq("unparseable " + i + ": filter returns it unchanged", bad[i],
                    ReportPreviewFilter.filter(bad[i], "gate.log", "[logind]"));
            eq("unparseable " + i + ": no sections", 0, ReportPreviewFilter.sections(bad[i]).size());
            eq("unparseable " + i + ": no tags", 0, ReportPreviewFilter.tags(bad[i]).size());
        }
        eq("null preview: filter returns null", null, ReportPreviewFilter.filter(null, "gate.log", null));
        eq("null preview: no sections", 0, ReportPreviewFilter.sections(null).size());

        String E = "{\n" + KIND + CREATED + "  \"status\": {},\n" + "  \"logs\": {}\n}\n";
        eq("empty status and logs: sections is [status]", Arrays.asList("status"), ReportPreviewFilter.sections(E));
        eq("empty status and logs: no tags", 0, ReportPreviewFilter.tags(E).size());
        eq("empty status and logs: filter(status) keeps nothing", "", ReportPreviewFilter.filter(E, "status", null));
        String N = "{\n" + KIND + "  \"status\": null,\n" + "  \"logs\": null\n}\n";
        eq("null status and logs parse", Arrays.asList("status"), ReportPreviewFilter.sections(N));

        String O = "{\n" + KIND + ST_H + ST_2 + "  },\n" + "  \"logs\": {\n" + GATE_H + GATE_3 + "    ],\n"
                + "    \"ota.log\": [],\n" + "    \"prev_boot\": null,\n" + LOGIN_H + LOGIN_2 + "    ]\n  }\n}\n";
        List<String> os = ReportPreviewFilter.sections(O);
        eq("an empty log and a null log are listed", Arrays.asList("status", "gate.log", "ota.log", "prev_boot", "login.log"), os);
        eq("filter(the empty log) keeps nothing", "", ReportPreviewFilter.filter(O, "ota.log", null));
        eq("filter(the log after it) still works", LOGIN_H + LOGIN_2, ReportPreviewFilter.filter(O, "login.log", null));
        eq("tags of a preview with an empty log", Arrays.asList("[logind]"), ReportPreviewFilter.tags(O));

        if (fails > 0) {
            System.out.println(fails + " case(s) FAILED");
            System.exit(1);
        }
        System.out.println("all cases passed");
    }
}
