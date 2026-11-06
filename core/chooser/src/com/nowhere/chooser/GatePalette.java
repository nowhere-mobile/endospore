package com.nowhere.chooser;

/**
 * NWP-20261115-15: the gate's one palette, with a dark set and a light set (docs/product-decisions.md, 2026-10-26: the
 * gate is dark on every phone until light is chosen, in Owner settings or at the gate's sun/moon (2026-10-29); it never
 * follows the OS setting, and the boot frames stay black). Pure java.lang, so the cases compile it as-is
 * (core/chooser/tests/gate-palette).
 *
 * DARK is today's look, unchanged, value for value; it has no contrast floor. LIGHT takes the storefront's light
 * palette, and every LIGHT text role meets WCAG AA (4.5:1) on its background, pinned by GatePaletteCases. The trailing
 * comment on each role names the storefront light role its light value takes; help and callTimer are this slice's own.
 *
 * The chosen look is the string under KEY in the gate's "nowhere_gate" prefs: only exactly LIGHT_VALUE reads LIGHT.
 * ChooserActivity.applyGateLook() reads it once per gate start and calls use(). StatusLine reads active() each time a
 * line is set. ProfileActivity runs in the signed-in user's process, which cannot read these prefs:
 * ChooserActivity.mirrorGateLook() copies the choice to the Global setting GLOBAL_KEY at each gate start, and
 * ProfileActivity reads it from there and calls use(), so its StatusLine lines follow the look too (NWP-20261117-21).
 * NOWHERE-1223 reads lightBars for the system-bar icons
 * and draws the incoming-call and gate-alarm screens from the call roles.
 */
final class GatePalette {
    static final String KEY = "gate_look";
    static final String LIGHT_VALUE = "light";
    static final String DARK_VALUE = "dark";
    /** The Global setting a signed-in user's process reads the look from (NWP-20261117-21). */
    static final String GLOBAL_KEY = "nowhere.gate_look";

    final int bg, ink, muted, tagline, fieldBg, fieldLn, hint, fieldTx, accent, onAccent, footer;
    final int title, help, danger, error, dotOff;
    final int panel, panelLn, warn, outline, qrDark, qrLight;
    final int callBg, callLabel, callInk, callTimer, decline, answer, neutralBtn, onBtn;
    final int switchThumbOn, switchThumbOff, switchTrackOn, switchTrackOff;
    /** Dark icons on the system bars: the light set only. */
    final boolean lightBars;
    final int scanBg, scanInk, scanShadow;

    private GatePalette(boolean light) {
        // role       = light ?    LIGHT   :    DARK       // the storefront light role
        bg         = light ? 0xFFF6F8FA : 0xFF0B0F14;   // --bg
        ink        = light ? 0xFF16202A : 0xFFEAF1EE;   // --strong
        muted      = light ? 0xFF5A6878 : 0xFF69788A;   // --note
        tagline    = light ? 0xFF1C2530 : 0xFFDCE4EC;   // --bright
        fieldBg    = light ? 0xFFFFFFFF : 0xFF121922;   // --field
        fieldLn    = light ? 0xFFCDD6E0 : 0xFF232E39;   // --field-line
        hint       = light ? 0xFF57606A : 0xFF8595A4;   // --muted
        fieldTx    = light ? 0xFF1F2328 : 0xFFE6EDF3;   // --text
        accent     = light ? 0xFF087658 : 0xFF4FD6AC;   // --teal
        onAccent   = light ? 0xFFFFFFFF : 0xFF05281F;   // white on --teal
        footer     = light ? 0xFF5C6570 : 0xFF505D69;   // --dim
        title      = light ? 0xFF0D1117 : 0xFFFFFFFF;   // --heading (the wordmark)
        help       = light ? 0xFF0B6E7D : 0xFF5FC4D4;   // this slice's own (the help glyph)
        danger     = light ? 0xFFB3401B : 0xFFE05B5B;   // --warn
        error      = light ? 0xFFB3401B : 0xFFE06C6C;   // --warn (dark: StatusLine.ERROR)
        dotOff     = light ? 0xFFD0D7DE : 0xFF2B3444;   // --line
        // The Profile screen (NWP-20261117-21).
        panel      = light ? 0xFFEEF1F5 : 0xFF121821;   // this slice's own (a note panel, a segmented track)
        panelLn    = light ? 0xFFD0D7DE : 0xFF232C36;   // --line (the track's edge)
        warn       = light ? 0xFF8A5A00 : 0xFFE0A34F;   // this slice's own (amber: a plan or space warning)
        outline    = light ? 0x33000000 : 0x33FFFFFF;   // a chip's 20 % outline
        qrDark     = 0xFF000000;                        // a QR code is black on white in both sets
        qrLight    = 0xFFFFFFFF;
        // The incoming-call and gate-alarm screens (NOWHERE-1223).
        callBg     = light ? 0xFFF6F8FA : 0xFF101418;   // --bg
        callLabel  = light ? 0xFF57606A : 0xFF9AA3AD;   // --muted
        callInk    = light ? 0xFF1F2328 : 0xFFFFFFFF;   // --text
        callTimer  = light ? 0xFF1A7F37 : 0xFF6FCF97;   // this slice's own
        // The call buttons are the same in both sets.
        decline    = 0xFFE0503A;
        answer     = 0xFF2FA84F;
        neutralBtn = 0xFF3A4048;
        onBtn      = 0xFFFFFFFF;
        // The gate's switches (NWP-20261117-29). WCAG 2.1 1.4.11 asks 3:1 of the parts that show a control's state.
        // The platform's track drawable keeps its own transparency, so the knob carries the 3:1: each LIGHT knob meets
        // it on bg and on fieldBg, pinned by GateSwitchCases. GateSwitch.style leaves a dark palette's switch to the
        // theme, so the DARK values are never drawn.
        switchThumbOn  = light ? 0xFF087658 : 0xFF4FD6AC;   // --teal
        switchThumbOff = light ? 0xFF6E7781 : 0xFF8595A4;   // this slice's own
        switchTrackOn  = light ? 0xFF087658 : 0xFF4FD6AC;   // --teal
        switchTrackOff = light ? 0xFF6E7781 : 0xFF8595A4;   // this slice's own
        lightBars  = light;
        // The QR scan screen: a camera viewfinder keeps its dark surround in both looks, as the call buttons keep one
        // colour (an inference, not stated by Chester). The same in both sets.
        scanBg     = 0xFF0B0F14;
        scanInk    = 0xFFFFFFFF;
        scanShadow = 0xCC000000;
    }

    static final GatePalette DARK = new GatePalette(false);
    static final GatePalette LIGHT = new GatePalette(true);

    // Declared after DARK, so it starts as DARK and never as null.
    private static volatile GatePalette active = DARK;

    /** LIGHT only for exactly "light": no trim, no case folding. Anything else, null included, is DARK. */
    static GatePalette forLook(String stored) {
        return LIGHT_VALUE.equals(stored) ? LIGHT : DARK;
    }

    /** The stored value for a choice: forLook(valueFor(b)) is LIGHT exactly when b. */
    static String valueFor(boolean light) {
        return light ? LIGHT_VALUE : DARK_VALUE;
    }

    /** The colour with its alpha byte replaced by the low byte of alpha. */
    static int withAlpha(int color, int alpha) {
        return (color & 0x00FFFFFF) | ((alpha & 0xFF) << 24);
    }

    /** The palette of this process: DARK until use() sets another. */
    static GatePalette active() {
        return active;
    }

    /** Sets the palette of this process; null is DARK. */
    static void use(GatePalette p) {
        active = p == null ? DARK : p;
    }
}
