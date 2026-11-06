// NWP-20261112-07: PermsCaptureRule.keepCarried, and NWP-20261123-11: PermsCaptureRule.oldLinesByPkg, compiled with
// the real source and EXECUTED. run.sh prepends the package line so these reach the package-private class.
public final class Cases {
    private static int failed = 0;

    private static void expect(String name, boolean want, boolean got) {
        if (want == got) System.out.println("  ok   " + name);
        else { System.out.println("  FAIL " + name + " (want " + want + ", got " + got + ")"); failed++; }
    }

    private static void expectMap(String name, java.util.Map<String, java.util.List<String>> want,
            java.util.Map<String, java.util.ArrayList<String>> got) {
        boolean same = want == null ? got == null : got != null && want.equals(got);
        if (same) System.out.println("  ok   " + name);
        else { System.out.println("  FAIL " + name + " (want " + want + ", got " + got + ")"); failed++; }
    }

    private static java.util.Map<String, java.util.List<String>> map(String... kv) {
        java.util.HashMap<String, java.util.List<String>> m = new java.util.HashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put(kv[i], java.util.Arrays.asList(kv[i + 1].split("\n")));
        return m;
    }

    public static void main(String[] a) {
        System.out.println("== keepCarried: a mid-session capture holds an unrestored deferred app");
        expect("mid-session, ondemand, not restored -> held", true, PermsCaptureRule.keepCarried(true, "ondemand", false));
        expect("mid-session, auto, not restored -> held", true, PermsCaptureRule.keepCarried(true, "auto", false));
        System.out.println("== keepCarried: everything else is captured live");
        expect("sign-out, ondemand, not restored -> live", false, PermsCaptureRule.keepCarried(false, "ondemand", false));
        expect("sign-out, auto, not restored -> live", false, PermsCaptureRule.keepCarried(false, "auto", false));
        expect("mid-session, ondemand, restored -> live", false, PermsCaptureRule.keepCarried(true, "ondemand", true));
        expect("mid-session, auto, restored -> live", false, PermsCaptureRule.keepCarried(true, "auto", true));
        expect("mid-session, installed, not restored -> live", false, PermsCaptureRule.keepCarried(true, "installed", false));
        expect("mid-session, not in the keep-set (null) -> live", false, PermsCaptureRule.keepCarried(true, null, false));
        System.out.println("== oldLinesByPkg: an unreadable record is unknown, never empty");
        expectMap("oldLinesByPkg(null) -> null (unknown)", null, PermsCaptureRule.oldLinesByPkg(null));
        expectMap("oldLinesByPkg(\"\") -> empty", map(), PermsCaptureRule.oldLinesByPkg(""));
        System.out.println("== oldLinesByPkg: the record grouped by package");
        expectMap("oldLinesByPkg grouped, order kept", map("a", "a x\na y", "b", "b z"),
                PermsCaptureRule.oldLinesByPkg("a x\na y\nb z\n"));
        expectMap("oldLinesByPkg skips \" lead\" and \"nospace\"", map("c", "c w"),
                PermsCaptureRule.oldLinesByPkg(" lead\nnospace\nc w\n"));
        expectMap("oldLinesByPkg reads CRLF as the file read did", map("a", "a x", "b", "b y"),
                PermsCaptureRule.oldLinesByPkg("a x\r\nb y"));
        if (failed > 0) { System.out.println("FAILED: " + failed + " case(s)"); System.exit(1); }
        System.out.println("all PermsCaptureRule cases pass");
    }
}
