package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;

// NWP-20261201-05: the cases for the Profile screen's "Save automatically" choice (SaveMode) -- its option mapping, its
// default, its copy, the back-online prompt's text, and, read as data, the chooser's half of the daemon contract.
// args: ProfileActivity.java, ChooserActivity.java.
public final class SaveModeCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static String read(String p) throws Exception {
        return new String(Files.readAllBytes(Paths.get(p)), StandardCharsets.UTF_8);
    }

    /** The source with its comments dropped and its string literals kept, so prose can never satisfy a pin. */
    static String strip(String s) {
        StringBuilder b = new StringBuilder(s.length());
        int n = s.length(), i = 0;
        while (i < n) {
            char c = s.charAt(i);
            if (s.startsWith("//", i)) {
                while (i < n && s.charAt(i) != '\n') i++;
            } else if (s.startsWith("/*", i)) {
                int e = s.indexOf("*/", i + 2);
                i = e < 0 ? n : e + 2;
            } else if (c == '"' || c == '\'') {
                int st = i++;
                while (i < n && s.charAt(i) != c) i += s.charAt(i) == '\\' ? 2 : 1;
                i = Math.min(n, i + 1);
                b.append(s, st, i);
            } else {
                b.append(c);
                i++;
            }
        }
        return b.toString();
    }

    /** A method from its signature to the first line that closes a class member; "" when it is absent. */
    static String body(String src, String sig) {
        int st = src.indexOf(sig);
        if (st < 0) return "";
        int e = src.indexOf("\n    }\n", st);
        return e < 0 ? "" : src.substring(st, e);
    }

    static int count(String s, String sub) {
        int n = 0;
        for (int i = s.indexOf(sub); i >= 0; i = s.indexOf(sub, i + sub.length())) n++;
        return n;
    }

    public static void main(String[] a) throws Exception {
        // The options, in order, and the default.
        check("the contract file and values", SaveMode.FILE.equals("nowhere-save-mode")
                && String.join(",", SaveMode.VALUES).equals("always,wifi,off"), SaveMode.FILE + " " + String.join(",", SaveMode.VALUES));
        check("the default is always", SaveMode.DEFAULT.equals("always"), SaveMode.DEFAULT);

        // normalize: each choice is itself; anything else -- absent, unknown, damaged, a daemon's other reply -- is the default.
        for (String v : SaveMode.VALUES) check("normalize " + v, SaveMode.normalize(v).equals(v), SaveMode.normalize(v));
        check("normalize trims a padded value", SaveMode.normalize("  wifi\n").equals("wifi"), SaveMode.normalize("  wifi\n"));
        for (String bad : new String[] { null, "", "junk", "ALWAYS", "wifi off", "ERR", "BLANK" }) {
            check("normalize " + bad + " -> default", SaveMode.normalize(bad).equals("always"), SaveMode.normalize(bad));
        }

        // The copy, pinned: one name and one plain trade-off line per choice.
        String[][] copy = {
            { "always", "Always", "Saves your changes every few minutes on any connection" },
            { "wifi", "Only on Wi-Fi", "Saves on Wi-Fi or another unmetered network. On mobile data only a sign-out or Back up now saves" },
            { "off", "Off", "Saves only when you sign out or tap Back up now; if the phone crashes or powers off, changes since then are lost" },
        };
        for (String[] c : copy) {
            check("label " + c[0], SaveMode.label(c[0]).equals(c[1]), SaveMode.label(c[0]));
            check("tradeoff " + c[0], SaveMode.tradeoff(c[0]).equals(c[2]), SaveMode.tradeoff(c[0]));
            check("item " + c[0], SaveMode.item(c[0]).equals(c[1] + "\n" + c[2]), SaveMode.item(c[0]));
            check("tradeoff " + c[0] + " is one line", !SaveMode.tradeoff(c[0]).contains("\n"), SaveMode.tradeoff(c[0]));
            check("label and tradeoff " + c[0] + " hold no ampersand", !SaveMode.item(c[0]).contains("&"), SaveMode.item(c[0]));
        }
        check("an unknown value shows the default's copy", SaveMode.label("junk").equals("Always")
                && SaveMode.tradeoff("junk").equals(copy[0][2]), SaveMode.label("junk"));

        // h62 #1: in the held modes only a sign-out and Back up now save, and no text says that a lock does.
        String signOut = "(?s).*sign[- ]out.*";
        String wifiText = SaveMode.tradeoff("wifi"), offText = SaveMode.tradeoff("off");
        check("the off trade-off names the sign-out and Back up now",
                offText.matches(signOut) && offText.contains("Back up now"), offText);
        check("the wifi trade-off names the sign-out", wifiText.matches(signOut), wifiText);
        check("the wifi trade-off names Back up now", wifiText.contains("Back up now"), wifiText);
        boolean noLock = true;
        for (String v : SaveMode.VALUES) noLock &= !SaveMode.tradeoff(v).toLowerCase().contains("lock");
        check("no trade-off mentions a lock", noLock, wifiText + " / " + offText);

        // What the user is told after a choice.
        check("not saved", "Couldn't save this choice. Try again.".equals(SaveMode.afterSave(false, "OK")), SaveMode.afterSave(false, "OK"));
        check("applied now -> nothing", SaveMode.afterSave(true, "OK") == null, SaveMode.afterSave(true, "OK"));
        check("refused -> next sign-in", "Saved. It applies from your next sign-in.".equals(SaveMode.afterSave(true, "ERR")),
                SaveMode.afterSave(true, "ERR"));
        for (String none : new String[] { "", null, "BLANK", "BUSY" }) {
            check("no clear answer (" + none + ") -> maybe now",
                    "Saved. If it doesn't apply now, it will from your next sign-in.".equals(SaveMode.afterSave(true, none)),
                    SaveMode.afterSave(true, none));
        }

        // The back-online prompt.
        String today = "Your recent changes aren't saved to your store yet. Tap Back up now to save them.";
        String waits = "You're on mobile data. This profile saves on Wi-Fi only, so your recent changes will be saved when you're on Wi-Fi.";
        check("backNowBody wifi on a metered network waits for Wi-Fi", SaveMode.backNowBody("wifi", false).equals(waits)
                && SaveMode.WAITS_FOR_WIFI.equals(waits), SaveMode.backNowBody("wifi", false));
        check("backNowBody wifi on an unmetered network is today's text", SaveMode.backNowBody("wifi", true).equals(today),
                SaveMode.backNowBody("wifi", true));
        for (String m : new String[] { "always", "off" }) {
            for (boolean un : new boolean[] { true, false }) {
                check("backNowBody " + m + " unmetered=" + un + " is today's text", SaveMode.backNowBody(m, un).equals(today),
                        SaveMode.backNowBody(m, un));
            }
        }
        check("backNowBody of a padded wifi reply waits for Wi-Fi", SaveMode.backNowBody(" wifi\n", false).equals(waits),
                SaveMode.backNowBody(" wifi\n", false));
        check("backNowBody with no daemon answer is today's text", SaveMode.backNowBody("", false).equals(today),
                SaveMode.backNowBody("", false));

        // The source, read as data with comments stripped: the chooser's half of the contract.
        String profile = strip(read(a[0])), chooser = strip(read(a[1]));

        String w = body(profile, "private boolean writeSaveMode(String v) {");
        String atomic = "StoreInstaller.writeAtomic(new java.io.File(getFilesDir(), SaveMode.FILE), val)";
        String send = "sendDaemon(\"SET-SAVE-MODE\\n\" + val + \"\\n\" + android.os.UserHandle.myUserId() + \"\\n\")";
        check("writeSaveMode writes SaveMode.FILE through writeAtomic", count(w, atomic) == 1
                && w.indexOf(atomic) < w.indexOf("SET-SAVE-MODE"), w);
        check("writeSaveMode sends SET-SAVE-MODE with its user", count(w, send) == 1, w);
        check("writeSaveMode logs no value and no profile name", count(w, "Log.w(\"NowhereChooser\", \"writeSaveMode\", t);") == 1
                && count(w, "Log.") == 1, w);
        // Without the daemon half: a SET-SAVE-MODE refusal leaves the written file and is only afterSave's message.
        check("an ERR keeps the written file and shows no dialog", !w.contains(".delete(") && !w.contains("AlertDialog")
                && count(w, "SaveMode.afterSave(true, reply)") == 1 && count(w, "SaveMode.afterSave(") == 2, w);

        String dlg = body(profile, "private void showSaveModeDialog(final TextView chip, final TextView sub, final String[] cur) {");
        check("an unsaved choice keeps the old one",
                dlg.contains("if (!writeSaveMode(SaveMode.VALUES[which])) return;")
                && dlg.indexOf("writeSaveMode(") < dlg.indexOf("cur[0] = SaveMode.VALUES[which];"), dlg);
        check("the picker has no Cancel or OK button", !dlg.isEmpty() && !dlg.contains("\"Cancel\"") && !dlg.contains("\"OK\""), dlg);

        String row = body(profile, "private void showYourApps() {");
        int rowAt = row.indexOf("\"Save automatically\""), holdAt = row.indexOf("\"Backups while apps set up\"");
        check("the row sits above Backups while apps set up", rowAt >= 0 && holdAt > rowAt, rowAt + " " + holdAt);

        String[] p = chooser.split("private void startSyncStatusWatcher\\(\\) \\{", 2);
        String watcher = p.length < 2 ? "" : p[1].substring(0, Math.max(0, p[1].indexOf("\n    }\n")));
        // The exact line at the slow section's own depth is every slow tick: a latch would indent it or change it. It
        // assigns nothing, so the reply is dropped, and a daemon without the verb costs nothing but that reply.
        String net = "\n                if (unmeteredCtx(app)) pollDaemon(\"SAVE-NET-UNMETERED\\n\"); else pollDaemon(\"SAVE-NET-METERED\\n\");\n";
        int slow = watcher.indexOf("tick++ % SLOW_EVERY"), netAt = watcher.indexOf(net), prefetch = watcher.indexOf("\"PREFETCH-ARM");
        check("the watcher sends SAVE-NET on every slow tick", count(watcher, net) == 1 && slow >= 0 && slow < netAt && netAt < prefetch
                && count(watcher, "SAVE-NET-UNMETERED") == 1 && count(watcher, "SAVE-NET-METERED") == 1, slow + " " + netAt + " " + prefetch);

        String arm = "postBackNowNotice(app, uid, backNow.reconnectAt(), SaveMode.backNowBody(pollDaemon(\"GET-SAVE-MODE\\n\"), unmeteredCtx(app)));";
        check("the reconnect arm picks the prompt body", count(watcher, arm) == 1, watcher.length());

        String post = body(chooser, "private static void postBackNowNotice(Context app, int uid, long reconnectAt, String body) {");
        check("postBackNowNotice takes its body", !post.isEmpty() && post.contains(".setContentText(body)")
                && post.contains(".bigText(body)") && !post.contains("recent changes"), post);
        check("postBackNowNotice keeps its title and action", post.contains(".setContentTitle(\"Back online\")")
                && post.contains("\"Back up now\", pi"), post);
        check("the prompt text lives in SaveMode only", !chooser.contains("aren't saved to your store yet"), "");

        String un = body(chooser, "static boolean unmeteredCtx(Context ctx) {");
        check("unmeteredCtx tests NOT_METERED and not the Wi-Fi transport", un.contains("NET_CAPABILITY_NOT_METERED")
                && un.contains("NET_CAPABILITY_INTERNET") && !un.contains("TRANSPORT_WIFI") && !un.contains("onWifiCtx"), un);

        System.out.println(runs + " cases, " + fails + " failed");
        if (fails != 0) System.exit(1);
    }
}
