package com.nowhere.chooser;

/**
 * NWP-20261117-29: the chooser's switches take the palette's colours in light mode. Without a tint a Switch takes the
 * dark Theme.Nowhere's knob and track, and on the light page an off switch all but vanished (docs/backlog.md section
 * C). WCAG 2.1 1.4.11 asks 3:1 of the parts that show a control's state. The platform's track drawable keeps its own
 * transparency, so the knob carries the 3:1: GateSwitchCases checks the LIGHT knobs through GatePalette, and
 * core/vendor-common/bin/test-gate-switch-java.sh pins this class by source, because it uses android.*.
 *
 * A dark palette leaves the switch exactly as the theme draws it. In ProfileActivity GatePalette.active() stays DARK
 * until Profile draws light (docs/product-decisions.md, 2026-10-29), so its calls change nothing until then.
 */
final class GateSwitch {
    private GateSwitch() {}

    // The order matters: a ColorStateList takes the first state set that matches.
    private static final int[][] STATES = {
        {-android.R.attr.state_enabled},
        {android.R.attr.state_checked},
        {},
    };

    /**
     * Tints the knob and the track of sw from p: disabled, then checked, then off. Returns sw, so a call wraps a
     * construction in place; sw is untouched when sw or p is null or p is dark.
     */
    static android.widget.Switch style(android.widget.Switch sw, GatePalette p) {
        if (sw == null || p == null || !p.lightBars) return sw;
        sw.setThumbTintList(new android.content.res.ColorStateList(STATES,
                new int[] {p.fieldLn, p.switchThumbOn, p.switchThumbOff}));
        sw.setTrackTintList(new android.content.res.ColorStateList(STATES,
                new int[] {p.fieldLn, p.switchTrackOn, p.switchTrackOff}));
        return sw;
    }
}
