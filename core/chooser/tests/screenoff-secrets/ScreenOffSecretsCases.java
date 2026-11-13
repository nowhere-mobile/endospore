package com.nowhere.chooser;

import android.util.Log;
import android.widget.EditText;

/** NWP-20261201-15: the cases for clearScreenOffSecrets. test-screenoff-secrets-java.sh cuts the method out of
 *  ChooserActivity and generates ScreenOffSecretsHarness around it. The expected line is held here as a literal, so
 *  a changed line in the source fails the byte-for-byte case. */
public final class ScreenOffSecretsCases {
    private static final String LINE =
            "NowhereChooser: screen off: owner-verify, SIM PIN or Wi-Fi password field cleared (NWP-20261201-15)";
    private static final int OWNER = 0, SIM = 1, WIFI = 2;
    private static int fails = 0;

    private interface Check { boolean run(); }

    private static void check(String name, Check c) {
        Log.INFO.clear();
        boolean pass;
        try { pass = c.run(); } catch (Throwable t) { pass = false; }
        System.out.println((pass ? "  ok    " : "  FAIL  ") + name);
        if (!pass) fails++;
    }

    private static EditText filled() {
        EditText e = new EditText();
        e.setText("typed-secret");
        return e;
    }

    private static EditText get(ScreenOffSecretsHarness h, int which) {
        return which == OWNER ? h.ownerVerifyField : which == SIM ? h.simPinField : h.wifiPassField;
    }

    /** One field filled, and the other two null or present and empty. */
    private static ScreenOffSecretsHarness alone(int which, boolean othersEmpty) {
        ScreenOffSecretsHarness h = new ScreenOffSecretsHarness();
        if (othersEmpty) {
            h.ownerVerifyField = new EditText();
            h.simPinField = new EditText();
            h.wifiPassField = new EditText();
        }
        if (which == OWNER) h.ownerVerifyField = filled();
        else if (which == SIM) h.simPinField = filled();
        else h.wifiPassField = filled();
        return h;
    }

    private static ScreenOffSecretsHarness allThree() {
        ScreenOffSecretsHarness h = new ScreenOffSecretsHarness();
        h.ownerVerifyField = filled();
        h.simPinField = filled();
        h.wifiPassField = filled();
        return h;
    }

    private static boolean emptiedAlone(int which, boolean othersEmpty) {
        ScreenOffSecretsHarness h = alone(which, othersEmpty);
        h.fire();
        return get(h, which).length() == 0;
    }

    private static boolean oneLineEach(boolean othersEmpty) {
        for (int which : new int[] {OWNER, SIM, WIFI}) {
            Log.INFO.clear();
            alone(which, othersEmpty).fire();
            if (Log.INFO.size() != 1) return false;
        }
        return true;
    }

    public static void main(String[] args) {
        for (boolean othersEmpty : new boolean[] {false, true}) {
            check("owner-verify filled alone is emptied", () -> emptiedAlone(OWNER, othersEmpty));
            check("SIM PIN filled alone is emptied", () -> emptiedAlone(SIM, othersEmpty));
            check("Wi-Fi password filled alone is emptied", () -> emptiedAlone(WIFI, othersEmpty));
            check("a field filled alone writes one line", () -> oneLineEach(othersEmpty));
        }
        check("all three filled are all emptied", () -> {
            ScreenOffSecretsHarness h = allThree();
            h.fire();
            return h.ownerVerifyField.length() == 0 && h.simPinField.length() == 0 && h.wifiPassField.length() == 0;
        });
        check("all three filled write one line", () -> {
            allThree().fire();
            return Log.INFO.size() == 1;
        });
        check("all null runs and writes no line", () -> {
            new ScreenOffSecretsHarness().fire();
            return Log.INFO.isEmpty();
        });
        check("all empty writes no line", () -> {
            ScreenOffSecretsHarness h = new ScreenOffSecretsHarness();
            h.ownerVerifyField = new EditText();
            h.simPinField = new EditText();
            h.wifiPassField = new EditText();
            h.fire();
            return Log.INFO.isEmpty();
        });
        check("the line equals the constant byte for byte", () -> {
            allThree().fire();
            return Log.INFO.size() == 1 && LINE.equals(Log.INFO.get(0));
        });
        if (fails > 0) System.exit(1);
    }
}
