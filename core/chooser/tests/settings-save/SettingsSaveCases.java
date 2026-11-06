package com.nowhere.chooser;

/** Cases for SettingsSaveCopy (NWP-20261124-23) and source checks on the real ProfileActivity.java: the five media
 *  and reclaim writers return whether their file now holds the choice, and their four controls act on the result.
 *  args: <ProfileActivity.java>. Exit 0 every case passed, 1 any case failed. */
public final class SettingsSaveCases {
    private static int bad = 0;

    private static void check(String name, Object got, Object want) {
        if (java.util.Objects.equals(want, got)) { System.out.println("PASS " + name); return; }
        System.out.println("FAIL " + name + ": got <" + got + "> want <" + want + ">");
        bad++;
    }
    private static void truth(String name, boolean ok, String why) {
        if (ok) { System.out.println("PASS " + name); return; }
        System.out.println("FAIL " + name + ": " + why);
        bad++;
    }

    public static void main(String[] args) throws Exception {
        copyCases();
        sourceChecks(new String(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(args[0])),
                java.nio.charset.StandardCharsets.UTF_8));
        System.exit(bad == 0 ? 0 : 1);
    }

    // ---- executed ------------------------------------------------------------------------------------------------

    private static void copyCases() {
        check("T1 tierSaved(true, true)", SettingsSaveCopy.tierSaved(true, true), true);
        check("T2 tierSaved(true, false): the tier file kept the old value", SettingsSaveCopy.tierSaved(true, false), false);
        check("T3 tierSaved(false, true): the pin file kept the old value", SettingsSaveCopy.tierSaved(false, true), false);
        check("T4 tierSaved(false, false)", SettingsSaveCopy.tierSaved(false, false), false);
        String w = SettingsSaveCopy.NOT_SAVED;
        truth("N1 NOT_SAVED says the change was not saved and claims none", w != null && w.contains("Couldn't save")
                && !w.contains("Saved") && !w.contains("saved."), "got <" + w + ">");
        truth("N2 NOT_SAVED does not say nothing changed (one tier file can have changed)",
                w != null && !w.toLowerCase(java.util.Locale.ROOT).contains("nothing changed"), "got <" + w + ">");
    }

    // ---- source checks -------------------------------------------------------------------------------------------

    /** The source with // and block comments dropped; string and char literals kept whole. */
    static String stripComments(String s) {
        StringBuilder o = new StringBuilder(s.length());
        int n = s.length(), i = 0;
        while (i < n) {
            char c = s.charAt(i);
            if (s.startsWith("//", i)) { while (i < n && s.charAt(i) != '\n') i++; continue; }
            if (s.startsWith("/*", i)) {
                int e = s.indexOf("*/", i + 2);
                i = e < 0 ? n : e + 2;
                o.append(' ');
                continue;
            }
            if (s.startsWith("\"\"\"", i)) {
                int e = s.indexOf("\"\"\"", i + 3);
                int end = e < 0 ? n : e + 3;
                o.append(s, i, end); i = end; continue;
            }
            if (c == '"' || c == '\'') {
                int j = i + 1;
                while (j < n && s.charAt(j) != c && s.charAt(j) != '\n') { if (s.charAt(j) == '\\') j++; j++; }
                int end = Math.min(n, j + 1);
                o.append(s, i, end); i = end; continue;
            }
            o.append(c); i++;
        }
        return o.toString();
    }

    /** The {...} block from the first '{' at or after `from` to the brace that closes it, braces in literals
     *  ignored; null when unbalanced. */
    static String braced(String code, int from) {
        int open = code.indexOf('{', from);
        if (from < 0 || open < 0) return null;
        int depth = 0, n = code.length();
        for (int i = open; i < n; i++) {
            char c = code.charAt(i);
            if (c == '"' || c == '\'') {
                int j = i + 1;
                while (j < n && code.charAt(j) != c) { if (code.charAt(j) == '\\') j++; j++; }
                i = j; continue;
            }
            if (c == '{') depth++;
            else if (c == '}' && --depth == 0) return code.substring(from, i + 1);
        }
        return null;
    }

    /** The method from its exact signature to the brace that closes it; null if absent, duplicated or unbalanced. */
    static String method(String code, String sig) {
        int at = code.indexOf(sig);
        if (at < 0 || code.indexOf(sig, at + 1) >= 0) return null;
        return braced(code, at);
    }

    static int count(String s, String what) {
        int k = 0;
        for (int i = s.indexOf(what); i >= 0; i = s.indexOf(what, i + 1)) k++;
        return k;
    }

    private static final java.util.regex.Pattern CATCH = java.util.regex.Pattern.compile("\\bcatch\\s*\\(");
    private static final java.util.regex.Pattern DELETE_THEN_CHECK = java.util.regex.Pattern.compile(
            "f\\.delete\\(\\);\\s*return\\s*!\\s*f\\.exists\\(\\)\\s*;");
    private static final java.util.regex.Pattern BARE_RETURN = java.util.regex.Pattern.compile("\\breturn\\s*;");

    /** S1: a writer returns true only after writeAtomic, false from every catch, and checks a removal. */
    private static void writer(String code, String name, String params) {
        String label = "S1 " + name;
        truth(label + ": no longer declared void", !code.contains("private void " + name + "(" + params + ") {"),
                "still `private void " + name + "`");
        String b = method(code, "private boolean " + name + "(" + params + ") {");
        if (b == null) { truth(label + ": declared `private boolean " + name + "(" + params + ")`", false,
                "signature absent, duplicated or unbalanced"); return; }
        truth(label + ": no bare `return;`", !BARE_RETURN.matcher(b).find(), "a `return;` in a boolean writer");
        int iWrite = b.indexOf("StoreInstaller.writeAtomic(");
        int iTrue = b.indexOf("return true;");
        truth(label + ": one StoreInstaller.writeAtomic(", count(b, "StoreInstaller.writeAtomic(") == 1,
                count(b, "StoreInstaller.writeAtomic(") + " calls");
        truth(label + ": exactly one `return true;`, after writeAtomic", count(b, "return true;") == 1 && iWrite >= 0
                && iTrue > iWrite, "return true x" + count(b, "return true;") + " @" + iTrue + ", writeAtomic @" + iWrite);
        java.util.regex.Matcher m = CATCH.matcher(b);
        int catches = 0;
        while (m.find()) {
            catches++;
            String cb = braced(b, m.start());
            truth(label + ": catch #" + catches + " returns false", cb != null && cb.contains("return false;")
                    && !cb.contains("return true"), "catch block <" + cb + ">");
        }
        truth(label + ": has a catch around the write", catches >= 1, "no catch");
        int deletes = count(b, "f.delete()");
        int checked = 0;
        java.util.regex.Matcher d = DELETE_THEN_CHECK.matcher(b);
        while (d.find()) checked++;
        truth(label + ": every f.delete() reports !f.exists()", deletes == checked,
                deletes + " f.delete() but " + checked + " followed by `return !f.exists();`");
    }

    /** The guard `if (!<call>) {...}` inside `scope`, exactly once; null when absent or repeated. */
    private static String guard(String scope, String call) {
        String g = "if (!" + call + ") {";
        int at = scope.indexOf(g);
        if (at < 0 || scope.indexOf(g, at + 1) >= 0) return null;
        return braced(scope, at);
    }

    private static void sourceChecks(String src) {
        String code = stripComments(src);
        writer(code, "writePrefetchMetered", "boolean on");
        writer(code, "writeBudgetBytes", "long bytes");
        writer(code, "setPinned", "String app, boolean on");
        writer(code, "setTierOverride", "String app, String tier");
        writer(code, "setReclaimIdleMs", "long ms");
        truth("S1 writeBudgetBytes, writePrefetchMetered and setTierOverride each still remove their file",
                java.util.Objects.toString(method(code, "private boolean writeBudgetBytes(long bytes) {"), "").contains("f.delete()")
                && java.util.Objects.toString(method(code, "private boolean writePrefetchMetered(boolean on) {"), "").contains("f.delete()")
                && java.util.Objects.toString(method(code, "private boolean setTierOverride(String app, String tier) {"), "").contains("f.delete()"),
                "a removal moved -- the !f.exists() check above would be vacuous");

        // S2: the writer and applyTier only write; the callers decide what to say and send.
        String wpm = java.util.Objects.toString(method(code, "private boolean writePrefetchMetered(boolean on) {"), "");
        truth("S2 writePrefetchMetered sends nothing and shows nothing", !wpm.isEmpty() && !wpm.contains("sendDaemon(")
                && !wpm.contains("Toast"), "the writer still tells the daemon or toasts");
        String at = method(code, "private boolean applyTier(String app, int idx) {");
        if (at == null) {
            truth("S2 applyTier declared `private boolean applyTier(String app, int idx)`", false, "absent or duplicated");
        } else {
            truth("S2 applyTier sends nothing and shows nothing", !at.contains("sendDaemon(") && !at.contains("Toast"),
                    "applyTier still toasts or tells mediad");
            int ip = at.indexOf("boolean pinOk = setPinned(");
            int it = at.indexOf("boolean tierOk = setTierOverride(");
            truth("S2 applyTier keeps both results, pin then tier", ip >= 0 && it > ip
                    && count(at, "setPinned(") == 1 && count(at, "setTierOverride(") == 1, "pin@" + ip + " tier@" + it);
            truth("S2 applyTier returns SettingsSaveCopy.tierSaved(pinOk, tierOk)",
                    at.contains("return SettingsSaveCopy.tierSaved(pinOk, tierOk);"), "a different verdict");
        }

        String om = method(code, "private void showOfflineMedia() {");
        if (om == null) { truth("S3 showOfflineMedia found", false, "absent or duplicated"); om = ""; }

        // S3: the mobile-data switch.
        truth("S3 the switch calls writePrefetchMetered once", count(om, "writePrefetchMetered(") == 1,
                count(om, "writePrefetchMetered(") + " calls");
        String gm = guard(om, "writePrefetchMetered(on)");
        int gmEnd = gm == null ? -1 : om.indexOf(gm) + gm.length();
        truth("S3 the switch branches on the write: `if (!writePrefetchMetered(on)) {`", gm != null, "no single guard");
        if (gm != null) {
            truth("S3 a failed switch save says NOT_SAVED, redraws and returns", gm.contains("SettingsSaveCopy.NOT_SAVED")
                    && gm.contains("showOfflineMedia(") && gm.trim().matches("(?s).*return;\\s*}$"), gm);
            truth("S3 a failed switch save sends nothing", !gm.contains("sendDaemon(") && !gm.contains("SET-PREFETCH-METERED"), gm);
            truth("S3 SET-PREFETCH-METERED only after the guard", om.indexOf("\"SET-PREFETCH-METERED") > gmEnd
                    && count(om, "\"SET-PREFETCH-METERED") == 1, "the send is not after the guard");
        }

        // S4: the budget field.
        truth("S4 the budget field calls writeBudgetBytes once", count(om, "writeBudgetBytes(") == 1,
                count(om, "writeBudgetBytes(") + " calls");
        String gb = guard(om, "writeBudgetBytes(b)");
        truth("S4 the budget field branches on the write: `if (!writeBudgetBytes(b)) {`", gb != null, "no single guard");
        if (gb != null) {
            int gbEnd = om.indexOf(gb) + gb.length();
            truth("S4 a failed budget save says NOT_SAVED, redraws and returns", gb.contains("SettingsSaveCopy.NOT_SAVED")
                    && gb.contains("showOfflineMedia(") && gb.trim().matches("(?s).*return;\\s*}$"), gb);
            truth("S4 a failed budget save sends nothing and keeps budget[0]", !gb.contains("sendDaemon(")
                    && !gb.contains("PIN-MATERIALIZE") && !gb.contains("budget[0] ="), gb);
            int ib = om.indexOf("budget[0] = b;");
            truth("S4 budget[0] = b and PIN-MATERIALIZE only after the guard", ib > gbEnd
                    && om.indexOf("PIN-MATERIALIZE", gbEnd) > ib, "budget[0]@" + ib + " guard end@" + gbEnd);
        }

        // S5: the per-app tier.
        String mr = method(code, "private View mediaAppRow(final String app, final long bytes, int tierIdx, final Runnable onToggle) {");
        if (mr == null) { truth("S5 mediaAppRow found", false, "absent or duplicated"); mr = ""; }
        truth("S5 mediaAppRow calls applyTier once", count(mr, "applyTier(") == 1, count(mr, "applyTier(") + " calls");
        String gt = guard(mr, "applyTier(app, idx)");
        truth("S5 the tier callback picks its toast from applyTier: `if (!applyTier(app, idx)) {`", gt != null, "no single guard");
        if (gt != null) {
            int gtEnd = mr.indexOf(gt) + gt.length();
            truth("S5 a failed tier save says NOT_SAVED, redraws and returns", gt.contains("SettingsSaveCopy.NOT_SAVED")
                    && gt.contains("showOfflineMedia(") && gt.trim().matches("(?s).*return;\\s*}$"), gt);
            truth("S5 a failed tier save sends nothing and claims nothing", !gt.contains("sendDaemon(")
                    && !gt.contains("\"Keeping ") && !gt.contains("will auto-download") && !gt.contains("will stream"), gt);
            truth("S5 the Keeping toast and PIN-MATERIALIZE only after the guard", mr.indexOf("\"Keeping ") > gtEnd
                    && mr.indexOf("PIN-MATERIALIZE") > gtEnd, "a claim or a send before the result is known");
        }

        // S6: Re-archive idle apps.
        String rd = method(code, "private void showReclaimDialog(final TextView chip, final long[] cur) {");
        if (rd == null) { truth("S6 showReclaimDialog found", false, "absent or duplicated"); rd = ""; }
        truth("S6 the reclaim action calls setReclaimIdleMs once", count(rd, "setReclaimIdleMs(") == 1,
                count(rd, "setReclaimIdleMs(") + " calls");
        String gr = guard(rd, "setReclaimIdleMs(opts[which])");
        truth("S6 the reclaim action branches on the write: `if (!setReclaimIdleMs(opts[which])) {`", gr != null, "no single guard");
        if (gr != null) {
            int igr = rd.indexOf(gr);
            truth("S6 a failed reclaim save says NOT_SAVED and returns", gr.contains("SettingsSaveCopy.NOT_SAVED")
                    && gr.trim().matches("(?s).*return;\\s*}$"), gr);
            truth("S6 a failed reclaim save keeps cur[0] and the chip", !gr.contains("cur[0] =")
                    && !gr.contains("paintReclaimChip("), gr);
            int ic = rd.indexOf("cur[0] = opts[which];");
            truth("S6 cur[0] is assigned only after the guard", ic > igr + gr.length() && count(rd, "cur[0] =") == 1,
                    "cur[0]@" + ic + " guard@" + igr);
        }

        // S7: no "Saved." claim before the write's result is known.
        String saved = "\"Saved. It takes effect from your next sign-in.\"";
        int is = code.indexOf(saved);
        truth("S7 the Saved toast appears once in ProfileActivity", count(code, saved) == 1, count(code, saved) + " times");
        truth("S7 the Saved toast is in showOfflineMedia, after the switch's guard", gm != null && om.contains(saved)
                && om.indexOf(saved) > gmEnd, "the toast is reachable before the write's result is known (@" + is + ")");
    }
}
