package com.nowhere.chooser;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;

/** NWP-20261208-32: the REAL UpdateNoticeTap (and the real LandingLine) against the stubs. Each failed check prints
 *  "--- FAIL U<n> <reason>"; the JVM exits 1 if any failed. */
public final class UpdateNoticeTapCases {
    private static int failed;

    private static void check(String id, boolean ok, String why) {
        if (ok) System.out.println("ok " + id + " " + why);
        else { System.out.println("--- FAIL " + id + " " + why); failed++; }
    }

    public static void main(String[] a) {
        final String pkg = "com.nowhere.chooser";

        // U1: Profile, in the given context's package.
        Context c1 = new Context(10, pkg);
        Intent i1 = UpdateNoticeTap.intent(c1);
        check("U1", "com.nowhere.chooser.ProfileActivity".equals(i1.cls), "the intent targets ProfileActivity (cls=" + i1.cls + ")");
        check("U1", pkg.equals(i1.pkg), "the intent is in the context's package (pkg=" + i1.pkg + ")");

        // U2: the extra asks for the Update card.
        check("U2", "update".equals(UpdateNoticeTap.OPEN_UPDATE), "OPEN_UPDATE is \"update\"");
        check("U2", UpdateNoticeTap.OPEN_UPDATE.equals(i1.getStringExtra(LandingLine.EXTRA_OPEN)),
                "EXTRA_OPEN is OPEN_UPDATE (got " + i1.getStringExtra(LandingLine.EXTRA_OPEN) + ")");

        // U3: a new task, and a Profile already on top gets onNewIntent.
        check("U3", (i1.getFlags() & Intent.FLAG_ACTIVITY_NEW_TASK) != 0, "FLAG_ACTIVITY_NEW_TASK set");
        check("U3", (i1.getFlags() & Intent.FLAG_ACTIVITY_SINGLE_TOP) != 0, "FLAG_ACTIVITY_SINGLE_TOP set");

        // U4: one getActivity, on the SAME context object (the session user's), request REQUEST, immutable.
        PendingIntent.reset();
        Context uc = new Context(10, pkg);
        PendingIntent pi = UpdateNoticeTap.pending(uc);
        check("U4", pi != null, "pending() returns the PendingIntent");
        check("U4", PendingIntent.calls.size() == 1, "getActivity called exactly once (" + PendingIntent.calls.size() + ")");
        if (PendingIntent.calls.size() == 1) {
            PendingIntent.Call call = PendingIntent.calls.get(0);
            check("U4", call.context == uc, "getActivity is made on the context pending() was given (identity)");
            check("U4", call.request == UpdateNoticeTap.REQUEST && call.request == 0x0D23,
                    "request is REQUEST == NOTIF_UPDATE_ID 0x0D23 (got " + call.request + ")");
            check("U4", (call.flags & PendingIntent.FLAG_IMMUTABLE) != 0, "FLAG_IMMUTABLE set");
            check("U4", (call.flags & PendingIntent.FLAG_UPDATE_CURRENT) != 0, "FLAG_UPDATE_CURRENT set");
            check("U4", call.intent != null && "com.nowhere.chooser.ProfileActivity".equals(call.intent.cls)
                    && UpdateNoticeTap.OPEN_UPDATE.equals(call.intent.getStringExtra(LandingLine.EXTRA_OPEN)),
                    "the PendingIntent wraps intent(uc)");
        }

        // U5: the whole decision table.
        boolean[] tf = {false, true};
        for (boolean probed : tf) {
            for (boolean avail : tf) {
                UpdateNoticeTap.Act want = !probed ? UpdateNoticeTap.Act.WAIT
                        : avail ? UpdateNoticeTap.Act.SCROLL : UpdateNoticeTap.Act.DROP;
                UpdateNoticeTap.Act got = UpdateNoticeTap.act(UpdateNoticeTap.OPEN_UPDATE, probed, avail);
                check("U5", got == want, "act(OPEN_UPDATE, probed=" + probed + ", avail=" + avail + ") = " + got + ", want " + want);
                // PlayFinishPrompt.OPEN_PLAY is "play-entry"; PlayFinishPrompt is not compiled here.
                for (String other : new String[] {null, LandingLine.OPEN_YOUR_APPS, "play-entry"}) {
                    UpdateNoticeTap.Act g = UpdateNoticeTap.act(other, probed, avail);
                    check("U5", g == UpdateNoticeTap.Act.NONE,
                            "act(" + other + ", probed=" + probed + ", avail=" + avail + ") = " + g + ", want NONE");
                }
            }
        }

        System.exit(failed == 0 ? 0 : 1);
    }
}
