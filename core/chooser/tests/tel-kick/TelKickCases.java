package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

// NWP-20261019-04: the cases for the failed-logoff delivery re-kick (TelKick) and its call site in
// ProfileActivity.doLogoffImpl's `if (sealFailed) {` block. args: ProfileActivity.java.
public final class TelKickCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    public static void main(String[] a) throws Exception {
        // A kick that always throws is attempted 8 times, 7 sleeps of 2000 between them.
        int[] runsSeen = {0};
        List<Long> sleeps = new ArrayList<>();
        int n = -1;
        try {
            n = TelKick.repeat(() -> { runsSeen[0]++; throw new IllegalStateException("start refused"); }, 8, 2000, sleeps::add);
        } catch (Throwable t) {
            check("a throwing kick does not escape repeat", false, t);
        }
        check("a throwing kick is attempted 8 times", n == 8 && runsSeen[0] == 8, n + "/" + runsSeen[0]);
        check("7 sleeps of 2000 between 8 kicks", sleeps.size() == 7 && sleeps.stream().allMatch(s -> s == 2000L), sleeps);

        runsSeen[0] = 0;
        sleeps.clear();
        n = TelKick.repeat(() -> runsSeen[0]++, 8, 2000, sleeps::add);
        check("a succeeding kick is attempted 8 times", n == 8 && runsSeen[0] == 8, n + "/" + runsSeen[0]);
        check("a succeeding kick also sleeps 7 times", sleeps.size() == 7, sleeps);

        // An interrupted sleeper ends the loop with no further kick.
        runsSeen[0] = 0;
        int[] slept = {0};
        n = TelKick.repeat(() -> runsSeen[0]++, 8, 2000, ms -> {
            if (++slept[0] == 3) throw new InterruptedException();
        });
        check("an interrupted sleeper stops the loop after 3 kicks", n == 3 && runsSeen[0] == 3, n + "/" + runsSeen[0]);

        // The call site.
        String src = new String(Files.readAllBytes(Paths.get(a[0])), StandardCharsets.UTF_8);
        int block = src.indexOf("if (sealFailed) {");
        check("the sealFailed block exists", block >= 0, block);
        int call = src.indexOf("TelKick.repeat(", block);
        int ui = src.indexOf("runOnUiThread(", block);
        check("the block calls TelKick.repeat before its runOnUiThread", call > block && ui > call, call + "/" + ui);
        if (call > block && ui > call) {
            int thread = src.lastIndexOf("new Thread(", call);
            check("TelKick.repeat runs inside a new Thread of the block", thread > block, thread);
            String stmt = src.substring(call, ui);
            check("the kick carries putExtra(\"telingest\", true)", stmt.contains("putExtra(\"telingest\", true)"), stmt);
            check("the kick is 8 times, 2000 ms apart", stmt.contains("8, 2000"), stmt);
            check("the thread is named", stmt.contains("\"nowhere-logoff-telkick\""), stmt);
        }

        System.out.println(runs + " checks, " + fails + " failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
