package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// NWP-20261006-09 (Chester, 2026-10-06): "the only way to tie is for user to pick that option knowing what they are
// doing with a way to revert back when they prefer". Nothing in the gate may tie a profile to the phone -- not CREATE,
// not RECOVER, not a sign-in offer -- and the profile's settings must offer both directions, confirmed by passphrase.
// Each of these is one line that a later edit could add back in good faith ("harden new profiles, like before"), so
// they are pinned from the chooser source, which has no Java test surface. Comments are stripped first: the removal
// is explained in comments that name the old verbs.
func chooserCode(t *testing.T, file string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "chooser", "src", "com", "nowhere", "chooser", file))
	if err != nil {
		t.Fatalf("%s must be readable from core/agent: %v", file, err)
	}
	var keep []string
	for _, l := range strings.Split(string(b), "\n") {
		s := strings.TrimSpace(l)
		if strings.HasPrefix(s, "//") || strings.HasPrefix(s, "*") || strings.HasPrefix(s, "/*") {
			continue
		}
		if i := strings.Index(l, " // "); i >= 0 {
			l = l[:i]
		}
		keep = append(keep, l)
	}
	return strings.Join(keep, "\n")
}

func TestNothingTiesAProfileWithoutItsUser(t *testing.T) {
	gate := chooserCode(t, "ChooserActivity.java")
	if !strings.Contains(gate, "\"ROAM-IN\\n\"") {
		t.Fatal("ChooserActivity no longer sends ROAM-IN (control: this test reads the wrong source)")
	}
	for _, banned := range []string{"\"ENROLL-SE\\n", "\"SE-STATE\\n", "\"SE-TIE\\n", "hardenToSE(", "offerSEBinding("} {
		if strings.Contains(gate, banned) {
			t.Errorf("the gate (ChooserActivity) contains %s -- a profile would be tied without its user choosing it", banned)
		}
	}
	// The gate still computes and sends the chip secret at sign-in: it is what SE-TIE in the session uses.
	if !regexp.MustCompile(`\+ "\\n" \+ seSecretHex\(name\) \+ "\\n" \+ src \+ "\\n"`).MatchString(gate) {
		t.Error("ROAM-IN no longer carries seSecretHex(name) -- SE-TIE would have no chip secret in the session")
	}
}

func TestSettingsOfferTieAndUntieConfirmedByPassphrase(t *testing.T) {
	prof := chooserCode(t, "ProfileActivity.java")
	if !strings.Contains(prof, `labels.add("Tie to this phone"); actions.add(() -> showPhoneTie());`) {
		t.Error("Security no longer offers \"Tie to this phone\"")
	}
	i := strings.Index(prof, "private void showPhoneTie() {")
	if i < 0 {
		t.Fatal("showPhoneTie is gone")
	}
	j := strings.Index(prof[i:], "\n    private void ")
	body := prof[i : i+j]
	for _, want := range []string{
		`sendDaemon("SE-STATUS\n")`,
		`verb = "SE-TIE";`,
		`verb = "SE-UNTIE";`,
		// NWP-20261112-02: a tie asks for the 12 words first, re-read at the click; an untie never asks.
		`if (TieCopy.maySend(verb, confirm.isChecked())) runTieVerb(verb, pass, msg, act, confirm);`,
		`TieCopy.maySend(`,
		`TieCopy.COST_RESET`,
		"A Fairphone can't open a tied profile at all.", // the costs are named before the user confirms
		"12-word recovery code once",
		"opened by guessing your passphrase",
		// NWP-20261007-12: what the tie covers now, what it still does not, and what tying costs.
		"your settings and the keys that keep apps signed in, so a copy of them can't be opened by ",
		// NWP-20261008-04: photos, files and installed apps follow in the background, and the screen shows how far.
		"guessing your passphrase. Your photos and files and your installed apps follow in the ",
		"is above 20% or charging. Until each is done, your passphrase alone still opens it.",
		"Tying saves your data again under the chip, once: app data and settings straight away, ",
		"showTieProgress(prog);",
		// A partly tied profile is said as such and offers both ways out.
		`} else if ("OK TIED PARTIAL".equals(st)) {`,
		`act.setText("Finish tying it to this phone");`,
		`alt = "SE-UNTIE";`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("showPhoneTie lacks %q", want)
		}
	}
	k := strings.Index(prof, "private void runTieVerb(")
	if k < 0 {
		t.Fatal("runTieVerb is gone")
	}
	l := strings.Index(prof[k:], "\n    private ")
	run := prof[k : k+l]
	for _, want := range []string{
		`if (p.isEmpty()) { StatusLine.error(msg, "enter your passphrase to confirm"); return; }`,
		`StatusLine.busy(msg, "SE-TIE".equals(verb)`,    // NWP-20261007-13: a tie that runs for minutes says it is working
		"for (Button b : buttons) b.setEnabled(false);", // Finish and Untie cannot both run
		// the passphrase rides the verb: the daemon compares it to the session's. The read outlasts the daemon's
		// deadline; test-tie-copy-java.sh pins the numbers.
		`DaemonSocket.roundTrip(verb + "\n" + p + "\n", TieCopy.READ_MS)`,
		`StatusLine.error(msg, TieCopy.failText(r));`, // ERR-NOCREDIT and the other refusals are worded by TieCopy
	} {
		if !strings.Contains(run, want) {
			t.Errorf("runTieVerb lacks %q", want)
		}
	}
}
