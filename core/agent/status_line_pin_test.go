package main

import (
	"regexp"
	"strings"
	"testing"
)

// NWP-20261007-13 (Chester, lynx 2026100701): a busy line gets "some kind of busy sign", and busy and error lines get
// colours of their own: option 1, the spinner and the accent teal for busy, soft red for an error, on every inline
// status line and every loading line. StatusLine.java is the one implementation. These pin it, and fail any new
// in-progress line set through a plain setText, which would come back grey and still, beside an error in the same grey.

// plainBusyAllowed are the in-progress literals that stay plain setText, by design. Each is a state with a busy sign
// of its own, or not a status line at all.
var plainBusyAllowed = map[string]string{
	// The gate's sign-in and sign-out flow: a full-screen state or the gate's own result line beside its progress bar.
	`result.setText("Signing out…")`:                                 "the gate's sign-out hold, compared by its text",
	`result.setText("Getting ready…")`:                               "sign-in, beside the restore progress bar",
	`result.setText("You're offline — signing in locally…")`:         "sign-in, beside the restore progress bar",
	`result.setText("Finishing up…")`:                                "sign-in, beside the restore progress bar",
	`result.setText("Connecting to Wi-Fi to load your saved data…")`: "the relogin wait, a locked form",
	`done.setText("Creating your space…")`:                           "the create transition screen",
	`tv.setText("Restoring an earlier version…")`:                    "a full-screen state",
	`tv.setText("Signing off…")`:                                     "a full-screen state",
	`tv.setText("Ending session…")`:                                  "a full-screen state (NWP-20261010-10, END-UNSAVED)",
	`tv.setText("Restarting…")`:                                      "a full-screen state (NWP-20261010-10, RESTART-UNSAVED)",
	`tv.setText("Locking…")`:                                         "a full-screen state",
	// Backup and export: the line sits over their own progress bar.
	`st.setText("Backing up…")`: "over the backup progress bar",
	`st.setText("Exporting…")`:  "over the export progress bar",
	// Button labels and a value placeholder: not status lines.
	`clear.setText("Clearing…")`:                                 "a disabled button's label",
	`del.setText("Deleting…")`:                                   "a disabled button's label",
	`unlock.setText("Unlocking…")`:                               "a button's label",
	`enroll.setText("Touch the key when it blinks…")`:            "a button's label",
	`nfcBtn.setText("Tap 1 of 2 — hold your key to the phone…")`: "a button's label",
	`nfcBtn.setText("Step 2 of 2 — keep holding the key…")`:      "a button's label",
	`save.setText("Saving…")`:                                    "a button's label",
	`swCurrent.setText("Current version:  …")`:                   "a value placeholder, filled by the version",
}

func TestBusyLinesUseStatusLine(t *testing.T) {
	re := regexp.MustCompile(`\b[A-Za-z]+\.setText\("[^"]*…"\)`)
	seen := map[string]bool{}
	for _, f := range []string{"ChooserActivity.java", "ProfileActivity.java"} {
		for _, m := range re.FindAllString(chooserCode(t, f), -1) {
			seen[m] = true
			if _, ok := plainBusyAllowed[m]; !ok {
				t.Errorf("%s: %s is an in-progress line set plainly -- use StatusLine.busy, or name why not in plainBusyAllowed", f, m)
			}
		}
	}
	for m := range plainBusyAllowed {
		if !seen[m] {
			t.Errorf("plainBusyAllowed names %s, which is no longer in the chooser: drop it", m)
		}
	}
}

func TestStatusLineLook(t *testing.T) {
	sl := chooserCode(t, "StatusLine.java")
	for _, want := range []string{
		"static final int BUSY  = 0xFF4FD6AC;",
		"static final int ERROR = 0xFFE06C6C;",
		// The colour rides the text, so the next plain setText shows in the line's own colour.
		"sb.setSpan(new ForegroundColorSpan(GatePalette.active().accent), 1, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);",
		"sb.setSpan(new ForegroundColorSpan(GatePalette.active().error), 0, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);",
		// The spinner stops by itself once its text is replaced.
		"if (!(t instanceof Spanned) || ((Spanned) t).getSpanStart(this) < 0) return;",
	} {
		if !strings.Contains(sl, want) {
			t.Errorf("StatusLine lacks %q", want)
		}
	}
	if strings.Contains(sl, ".setTextColor(") {
		t.Error("StatusLine sets a view's text colour: a later plain setText on that line would inherit busy or error")
	}
	// NWP-20261115-15: the gate's ACCENT comes from GatePalette.DARK, whose accent is StatusLine.BUSY.
	// NWP-20261117-21: Profile's ACCENT too: its busy lines now take the device's look, as StatusLine's class comment
	// says of active().
	for _, c := range []struct{ file, want string }{
		{"ProfileActivity.java", "private static int ACCENT    = GatePalette.DARK.accent;"},
		{"ChooserActivity.java", "private static int ACCENT    = GatePalette.DARK.accent;"},
		{"GatePalette.java", "0xFF4FD6AC"},
	} {
		if !strings.Contains(chooserCode(t, c.file), c.want) {
			t.Errorf("%s lacks %q: busy lines and the screen's accent would drift apart", c.file, c.want)
		}
	}
	prof, gate := chooserCode(t, "ProfileActivity.java"), chooserCode(t, "ChooserActivity.java")
	for _, c := range []struct{ src, want string }{
		{prof, `StatusLine.busy(lt, "Loading your security keys…");`}, // a loading line carries its own spinner
		{prof, `StatusLine.busy(msg, "changing…");`},
		// NWP-20261119-23: the Tie screen's wrong-passphrase line moved to TieCopy.failText; it still shows as an error.
		{prof, `StatusLine.error(msg, TieCopy.failText(r));`},
		{chooserCode(t, "TieCopy.java"), `if ("ERR-PASS".equals(r)) return "that isn't this profile's passphrase";`},
		{prof, `StatusLine.busy(status, "Loading…");`},
		{gate, `StatusLine.busy(msg, "adding this phone…");`},
		{gate, `else StatusLine.busy(msg, "Checking for updates…");`},
		{gate, `StatusLine.error(msg, "Update failed — "`},
	} {
		if !strings.Contains(c.src, c.want) {
			t.Errorf("the chooser lacks %q", c.want)
		}
	}
}
