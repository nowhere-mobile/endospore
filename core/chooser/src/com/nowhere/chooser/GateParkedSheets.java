package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * NWP-20261206-07: the gate's sheets over a session that is still on the phone (docs/backlog.md, "Popups are plain
 * dialogs: the choice pickers and the confirmations move to one bottom-sheet design", design A, slice 3). Three
 * confirmations: Create refused over a locked session (ChooserActivity.showCreateOverColdLock), Create refused over an
 * open session (showCreateOverLiveSession) and Install over a parked session (confirmInstallOverParked).
 *
 * The words are today's, which are decided: the cold-lock refusal is Q123 (docs/product-decisions.md, 2026-10-20) and
 * the open-session refusal is h46 #5 (2026-10-28). ChooserActivity owns them; this class only splits them into a
 * context sentence and "what happens" lines. The only name a sheet shows is the parked session's, which "Welcome back"
 * already shows anyone holding the phone, and nothing here depends on what was typed.
 *
 * Button order is the contract with the callers' actions arrays: slot 0 is the green button, slot 1 the other.
 *
 * Pure java.util so core/vendor-common/bin/test-gate-parked-sheets-java.sh compiles it off the build host.
 */
final class GateParkedSheets {
    private GateParkedSheets() {}

    static final String RESUME_IT = "Resume it";
    static final String RESTART = "Restart";
    static final String INSTALL = "Install";

    // DRAFT (NWP-20261206-07): mockup for Chester
    static final String CREATE_LIVE_TITLE = "A session is still open";
    static final String CREATE_LIVE_TONE = "WARNING";
    static final String INSTALL_TONE = "WARNING";

    /** The cold-lock refusal: the title verbatim, the text's first paragraph as the context and the other paragraphs as
     *  lines, in order. Resume it is offered only when the reply named the parked session; else one Got it. */
    static PopupSheet.Confirm coldLock(String title, String text, boolean named) {
        String[] parts = text.split("\n\n", -1);
        List<PopupSheet.Line> lines = new ArrayList<>();
        for (int i = 1; i < parts.length; i++) lines.add(new PopupSheet.Line(parts[i], null));
        List<PopupSheet.Button> buttons = named
                ? Arrays.asList(new PopupSheet.Button(RESUME_IT, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.OUTLINED))
                : Arrays.asList(new PopupSheet.Button(PopupSheet.GOT_IT, PopupSheet.Style.GREEN_FILLED));
        return new PopupSheet.Confirm(PopupSheet.Tone.ROUTINE, title, parts[0], lines, buttons);
    }

    /** The ERR-LIVE refusal: its first sentence is the context, the other sentences are the lines. A restart ends the
     *  open session, so Restart is the risky choice. */
    static PopupSheet.Confirm createLive(String text) {
        String[] s = text.split("(?<=\\.) ");
        List<PopupSheet.Line> lines = new ArrayList<>();
        for (int i = 1; i < s.length; i++) lines.add(new PopupSheet.Line(s[i], null));
        return new PopupSheet.Confirm(PopupSheet.Tone.valueOf(CREATE_LIVE_TONE), CREATE_LIVE_TITLE, s[0], lines,
                Arrays.asList(new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(RESTART, PopupSheet.Style.RED_OUTLINED)));
    }

    /** Install over a parked session. The caller builds the context and the lines, so nothing here parses a name. */
    static PopupSheet.Confirm installOverParked(String title, String context, String[] lines) {
        List<PopupSheet.Line> l = new ArrayList<>();
        for (String t : lines) l.add(new PopupSheet.Line(t, null));
        return new PopupSheet.Confirm(PopupSheet.Tone.valueOf(INSTALL_TONE), title, context, l,
                Arrays.asList(new PopupSheet.Button(PopupSheet.NOT_NOW, PopupSheet.Style.GREEN_FILLED),
                        new PopupSheet.Button(INSTALL, PopupSheet.Style.RED_OUTLINED)));
    }
}
