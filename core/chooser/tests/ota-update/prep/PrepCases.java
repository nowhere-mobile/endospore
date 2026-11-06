package com.nowhere.chooser;

/** NWP-20261113-22: the gate's "Preparing the update…" line, driven through the REAL afterLogoffPreparing and
 *  afterLogoffPrepHandOff, lifted unchanged out of ChooserActivity.java into PrepGate by run.sh, over recording stubs
 *  of TextView and ProgressBar. What it pins is ownership: the line and the bar are set only on an idle gate, handed
 *  over at the first write by anyone else (determinate from then on, hidden unless a sign-in owns the bar), and a late
 *  clear never writes to a line or a bar that is not ours. */
public final class PrepCases {
    private static int pass, fail;

    private static void check(String name, boolean ok, Object got) {
        if (ok) { pass++; return; }
        fail++;
        System.out.println("FAIL " + name + " -- got " + got);
    }

    private static String state(PrepGate g) {
        return "text=\"" + g.result.getText() + "\" indeterminate=" + g.progressBar.indeterminate + " visibility="
                + g.progressBar.visibility + " textWrites=" + g.result.textWrites + " barWrites=" + g.progressBar.writes
                + " watchers=" + g.result.watchers();
    }

    private static boolean noWrites(PrepGate g) {
        return g.result.textWrites == 0 && g.progressBar.writes == 0;
    }

    private static boolean ours(PrepGate g) {
        return String.valueOf(g.result.getText()).endsWith(OtaUpdate.PREPARING) && g.progressBar.indeterminate
                && g.progressBar.visibility == android.view.View.VISIBLE;
    }

    private static final String[] GUARDS = {"loginInProgress", "sessionLive", "resumeMode"};

    private static void guard(PrepGate g, String which, boolean on) {
        switch (which) {
            case "loginInProgress": g.loginInProgress = on; break;
            case "sessionLive": g.sessionLive = on; break;
            default: g.resumeMode = on; break;
        }
    }

    public static void main(String[] a) {
        // an idle gate: on sets the line and an indeterminate bar, once; off gives both back
        PrepGate g = new PrepGate();
        g.on();
        check("idle: on shows the line and an indeterminate bar", ours(g) && g.result.watchers() == 1, state(g));
        g.counts();
        g.on();
        check("idle: a second on writes nothing", noWrites(g) && g.result.watchers() == 1, state(g));
        g.off();
        check("idle: off clears the line and hides a determinate bar", "".equals(String.valueOf(g.result.getText()))
                && !g.progressBar.indeterminate && g.progressBar.visibility == android.view.View.GONE
                && g.result.watchers() == 0, state(g));
        g.counts();
        g.off();
        check("idle: a second off writes nothing", noWrites(g), state(g));

        g = new PrepGate();
        g.off();
        check("off with nothing shown writes nothing", noWrites(g), state(g));

        for (String w : GUARDS) {
            // a gate that is not idle is never written
            g = new PrepGate();
            guard(g, w, true);
            g.on();
            check("guard " + w + ": on writes nothing", noWrites(g) && g.result.watchers() == 0, state(g));

            // the guard comes up while the line shows: a late off touches neither the line nor the bar
            g = new PrepGate();
            g.on();
            guard(g, w, true);
            g.counts();
            g.off();
            check("guard " + w + ": a late off writes nothing", noWrites(g) && ours(g), state(g));
            // ... and the owner's first write hands the bar over at once: determinate, and left visible for it
            g.progressBar.setProgress(0);
            g.progressBar.setVisibility(android.view.View.VISIBLE);
            g.result.setText("Logging in…");
            check("guard " + w + ": the owner's write hands the bar over, determinate and visible",
                    !g.progressBar.indeterminate && g.progressBar.visibility == android.view.View.VISIBLE
                    && g.result.watchers() == 0, state(g));
            g.counts();
            g.off();
            guard(g, w, false);
            g.off();
            check("guard " + w + ": after the hand-over, off writes nothing, guarded or idle", noWrites(g)
                    && "Logging in…".equals(String.valueOf(g.result.getText())), state(g));
        }

        // a sign-in's tap writes "Getting ready…" before loginInProgress is set: the bar goes back at once, hidden
        g = new PrepGate();
        g.on();
        g.result.setText("Getting ready…");
        check("tap: the first write hands the bar over at once, determinate and hidden", !g.progressBar.indeterminate
                && g.progressBar.visibility == android.view.View.GONE && g.result.watchers() == 0, state(g));
        g.loginInProgress = true; // then showRestoring: progress 0, visible, its line
        g.progressBar.setProgress(0);
        g.progressBar.setVisibility(android.view.View.VISIBLE);
        g.result.setText("Logging in…");
        check("tap: the sign-in's restore bar is determinate", !g.progressBar.indeterminate
                && g.progressBar.visibility == android.view.View.VISIBLE, state(g));
        g.counts();
        g.off();
        check("tap: a late off under the sign-in writes nothing", noWrites(g), state(g));
        g.loginInProgress = false;
        g.off();
        check("tap: a late off on the idle gate writes nothing", noWrites(g)
                && "Logging in…".equals(String.valueOf(g.result.getText())), state(g));

        // any other line replaces ours on an idle gate: the bar goes, and a late off leaves that line alone
        g = new PrepGate();
        g.on();
        g.result.setText("Connected to Wi-Fi.");
        check("message: the bar is handed back, hidden", !g.progressBar.indeterminate
                && g.progressBar.visibility == android.view.View.GONE && g.result.watchers() == 0, state(g));
        g.counts();
        g.off();
        check("message: a late off writes nothing", noWrites(g)
                && "Connected to Wi-Fi.".equals(String.valueOf(g.result.getText())), state(g));

        // the line is set again with the same text (a re-busy): still ours, still watched
        g = new PrepGate();
        g.on();
        StatusLine.busy(g.result, OtaUpdate.PREPARING);
        check("same text: still ours", ours(g) && g.result.watchers() == 1, state(g));

        System.out.println((fail == 0 ? "PASS " : "FAIL ") + pass + "/" + (pass + fail));
        if (fail != 0) System.exit(1);
    }
}
