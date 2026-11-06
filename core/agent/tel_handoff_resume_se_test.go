package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// NWP-20261027-01: telHandoffResume runs in the login daemon, whose environment never carries NOWHERE_SE_SECRET, so a
// tied profile (no `pass` slot) opened nothing and staged nothing, silently. The cold-lock marker's secret is now
// passed in. test-resume-handoff-se.sh re-runs these against broken copies of main.go.

const thsePass = "correct horse battery staple"

// thseStore is rbInboxStore with the literal "s3" base the hand-off reads pointed at that store (as thSetup does).
func thseStore(t *testing.T, name string, hardened bool) (ref string, se []byte) {
	t.Helper()
	base, ref, se := rbInboxStore(t, name, thsePass, hardened)
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	pinReadCapStore(t, base, 0)
	return ref, se
}

func TestTelHandoffResume_ATiedProfileIsHandedItsItems(t *testing.T) {
	const name = "thseTied"
	_, se := thseStore(t, name, true)
	t.Setenv("NOWHERE_SE_SECRET", "") // the daemon's environment
	telHandoffResume(name, thsePass, rbInboxUID, se)
	if rows := rbInboxRows(t); len(rows) != 1 {
		t.Fatalf("a tied profile's resume must stage its one sealed item, got %d rows: %q", len(rows), rows)
	}
}

func TestTelHandoffResume_WithoutTheSecretItSaysItSkipped(t *testing.T) {
	const name = "thseNoSecret"
	ref, _ := thseStore(t, name, true)
	t.Setenv("NOWHERE_SE_SECRET", "")
	out := captureStderr(t, func() { telHandoffResume(name, thsePass, rbInboxUID, nil) })
	if rows := rbInboxRows(t); len(rows) != 0 {
		t.Fatalf("nothing may be staged without the secret, got %q", rows)
	}
	want := `resume "` + name + `" -> telephony hand-off skipped: the vault did not open with this session's credential`
	if !strings.Contains(out, want) {
		t.Fatalf("no skipped line; stderr:\n%s", out)
	}
	if regexp.MustCompile(`[0-9a-f]{64}`).MatchString(out) || strings.Contains(out, ref) {
		t.Fatalf("the skipped line leaks a ref:\n%s", out)
	}
}

func TestTelHandoffResume_APassOnlyProfileStillStages(t *testing.T) {
	const name = "thsePassOnly"
	thseStore(t, name, false)
	telHandoffResume(name, thsePass, rbInboxUID, nil)
	if rows := rbInboxRows(t); len(rows) != 1 {
		t.Fatalf("a pass-only profile must stage its sealed item, got %q", rows)
	}
}

func TestHandleResumePassesTheMarkersSecret(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	var calls []string
	for _, l := range stripComments(funcBody(t, string(b), "handleResume")) {
		if strings.Contains(l, "telHandoffResume(") {
			calls = append(calls, strings.TrimSpace(l))
		}
	}
	if len(calls) != 1 || calls[0] != "telHandoffResume(name, pass, uid, seFromHex(se))" {
		t.Fatalf("handleResume must call telHandoffResume exactly once with the marker's secret, got %q", calls)
	}
}
