package com.nowhere.chooser;

/**
 * The colour roles of the gate's Help combo screen (NWP-20261130-11), each one a GatePalette field, so the screen and its
 * pictures follow the gate's look. test-gate-help-combo-java.sh pins the mapping and the contrast floors in both sets.
 * Not muted: dark muted on panel is 3.95:1. Not warn: amber means a warning on the Profile screens. Pure: java.lang only.
 */
final class GateHelpArt {
    private GateHelpArt() {}

    static final class Roles {
        final int cardFill, cardEdge, accent, ink, body, onAccent, screen, dotOff;

        private Roles(GatePalette p) {
            cardFill = p.panel;
            cardEdge = p.panelLn;
            accent = p.accent;
            ink = p.ink;
            body = p.hint;
            onAccent = p.onAccent;
            screen = p.bg;
            dotOff = p.dotOff;
        }
    }

    static Roles of(GatePalette p) {
        return new Roles(p);
    }
}
