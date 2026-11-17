package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** NWP-20261204-15: the Security screen's two picker models. Each failure line names its case. */
final class SecuritySheetsCases {
    private static int failed;
    private static final List<PopupSheet.Picker> BUILT = new ArrayList<>();

    /** The six labels, written out, so a changed WipeChoice.LABELS fails here too. */
    private static final List<String> WIPE_NAMES = Arrays.asList("Right away, once saved", "After 1 hour",
            "After 6 hours", "After 12 hours", "After 1 day", "Only on power-off");

    private static void check(String name, boolean ok) {
        if (ok) return;
        failed++;
        System.out.println("  FAIL  " + name);
    }

    private static PopupSheet.Picker keep(PopupSheet.Picker m) {
        BUILT.add(m);
        return m;
    }

    /** The options' names, in order. */
    private static List<String> names(PopupSheet.Picker m) {
        List<String> out = new ArrayList<>();
        for (PopupSheet.Option o : m.options) out.add(o.name);
        return out;
    }

    /** The index of each current option, in order. */
    private static List<Integer> currents(PopupSheet.Picker m) {
        List<Integer> out = new ArrayList<>();
        for (int i = 0; i < m.options.size(); i++) if (m.options.get(i).current) out.add(i);
        return out;
    }

    private static boolean plain(PopupSheet.Picker m) {
        for (PopupSheet.Option o : m.options) if (!o.chips.isEmpty() || o.description != null) return false;
        return true;
    }

    public static void main(String[] args) {
        int n = WipeChoice.LABELS.length;
        check("C1 WipeChoice.LABELS is the six labels", Arrays.asList(WipeChoice.LABELS).equals(WIPE_NAMES));
        for (int k = 0; k < n; k++) {
            PopupSheet.Picker m = keep(SecuritySheets.wipe(k));
            check("C1 wipe(" + k + ") has " + n + " options", m.options.size() == n);
            check("C1 wipe(" + k + ") names the labels", names(m).equals(WIPE_NAMES));
            check("C1 wipe(" + k + ") has no chips and no description", plain(m));
            check("C1 wipe(" + k + ") marks only " + k + " current", currents(m).equals(Arrays.asList(k)));
        }

        for (int k : new int[] { -1, n }) {
            PopupSheet.Picker m = keep(SecuritySheets.wipe(k));
            check("C2 wipe(" + k + ") has " + n + " options", m.options.size() == n);
            check("C2 wipe(" + k + ") marks none", currents(m).isEmpty());
        }

        List<String> vpnLabels = Arrays.asList("Off", "A", "B");
        PopupSheet.Picker v = keep(SecuritySheets.vpn(vpnLabels, 2));
        check("C3 vpn names Off, A, B", names(v).equals(vpnLabels));
        check("C3 vpn has no chips and no description", plain(v));
        check("C3 vpn(2) marks only B", currents(v).equals(Arrays.asList(2)));
        check("C3 vpn(0) marks only Off", currents(keep(SecuritySheets.vpn(vpnLabels, 0))).equals(Arrays.asList(0)));

        check("C4 vpn(-1) marks none", currents(keep(SecuritySheets.vpn(vpnLabels, -1))).isEmpty());
        check("C4 vpn(3) marks none", currents(keep(SecuritySheets.vpn(vpnLabels, 3))).isEmpty());

        check("C5 the wipe title", "Erase a locked session after".equals(SecuritySheets.wipe(0).title));
        check("C5 the vpn title", "Always-on VPN".equals(SecuritySheets.vpn(vpnLabels, 0).title));

        for (int i = 0; i < BUILT.size(); i++) {
            List<String> bad = PopupSheet.violations(BUILT.get(i));
            check("C6 model " + i + " (" + BUILT.get(i).title + ") has no violations " + bad, bad.isEmpty());
        }

        if (failed == 0) System.out.println("  ok  C1-C6");
        System.exit(failed == 0 ? 0 : 1);
    }
}
