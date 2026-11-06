package main

import "testing"

// NWP-20261126-02: a beta profile's scheduled diagnostic report carries the chooser's tester tag and report kind as
// caller status keys. buildIssueReportWith scrubs every caller value through statusValue; this pins that the scrub
// keeps a DiagReports.newTag-shaped tag ("t-" + 10 of [a-z2-7]) and both report_kind values unchanged, so the reports
// of one tester still link together at support.
func TestReportIssueTesterTag(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	for _, c := range []struct{ tag, kind string }{
		{"t-k3m7qa2zpx", "scheduled"},
		{"t-a2345672z7", "by_hand"}, // a long digit run inside the body, as newTag can draw
		{"t-zzzzzzzzzz", "scheduled"},
	} {
		rep := buildIssueReport("tagprobe1535", false, "", map[string]string{"tester_tag": c.tag, "report_kind": c.kind}, nil)
		if got := rep.Status["tester_tag"]; got != c.tag {
			t.Errorf("tester_tag %q came out as %q", c.tag, got)
		}
		if got := rep.Status["report_kind"]; got != c.kind {
			t.Errorf("report_kind %q came out as %q", c.kind, got)
		}
	}
}
