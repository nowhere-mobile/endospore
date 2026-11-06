package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// DIA-20260811-10. These lock the ONE invariant the whole change exists for: a reader must never be able to
// confuse "we found nothing" with "we could not look". The old code did `if len(den) > 0 { logs["avc"] = ... }`,
// so a device that could not read logcat OR dmesg produced a report byte-identical to a device with a clean
// policy -- and that is not hypothetical, it is what all six tickets ever filed actually looked like. A unit
// test is the right guard because the failure is invisible on-device by construction: the section's absence is
// exactly what you cannot see.

func joined(t *testing.T, lines []string) string {
	t.Helper()
	return strings.Join(lines, "\n")
}

func TestAvcSectionSaysWhenNoSourceCouldBeRead(t *testing.T) {
	srcs := []diagSource{
		{name: "logcat", err: "exit status 1"},
		{name: "dmesg", err: "permission denied"},
	}
	got := avcSection(nil, srcs, nil)
	if len(got) == 0 {
		t.Fatal("section is EMPTY -- an unreadable source must never render as an absent/quiet section")
	}
	s := joined(t, got)
	if !strings.Contains(s, "NO source could be read") {
		t.Errorf("must state that no source was readable; got:\n%s", s)
	}
	if !strings.Contains(s, "does NOT mean the device is denial-free") {
		t.Errorf("must warn against reading emptiness as a clean policy; got:\n%s", s)
	}
	for _, want := range []string{"logcat", "dmesg", "exit status 1", "permission denied"} {
		if !strings.Contains(s, want) {
			t.Errorf("must name the failing source and why (%q missing); got:\n%s", want, s)
		}
	}
}

func TestAvcSectionDistinguishesCleanFromUnreadable(t *testing.T) {
	clean := joined(t, avcSection(nil, []diagSource{{name: "logcat"}, {name: "dmesg"}}, nil))
	if !strings.Contains(clean, "no denials in the captured window") {
		t.Errorf("readable-but-empty must say so explicitly; got:\n%s", clean)
	}
	if strings.Contains(clean, "NO source could be read") {
		t.Errorf("a readable source must not be reported as unreadable; got:\n%s", clean)
	}
	broken := joined(t, avcSection(nil, []diagSource{{name: "logcat", err: "denied"}, {name: "dmesg", err: "denied"}}, nil))
	if clean == broken {
		t.Fatal("clean and unreadable render IDENTICALLY -- this is the exact bug DIA-20260811-10 fixes")
	}
}

func TestAvcSectionKeepsDenialsAndFlagsPartialReads(t *testing.T) {
	den := []string{"avc: denied { read } for comm=\"nowhere_agent\""}
	// One source up, one down: the denials are real but the picture may be incomplete, and that must be said.
	got := joined(t, avcSection(den, []diagSource{{name: "logcat"}, {name: "dmesg", err: "denied"}}, nil))
	if !strings.Contains(got, "avc: denied { read }") {
		t.Errorf("denial lines must survive; got:\n%s", got)
	}
	if !strings.Contains(got, "partial") {
		t.Errorf("a partial read must be flagged as partial; got:\n%s", got)
	}
}

func TestAvcSectionIsNeverEmpty(t *testing.T) {
	// Whatever combination arrives, the section must carry SOMETHING -- an empty slice would reintroduce the
	// silent-omission failure one layer up, where buildIssueReport writes it into the report map.
	cases := []struct {
		name string
		den  []string
		srcs []diagSource
	}{
		{"no denials, all readable", nil, []diagSource{{name: "logcat"}}},
		{"no denials, all broken", nil, []diagSource{{name: "logcat", err: "x"}}},
		{"denials, all readable", []string{"avc: denied"}, []diagSource{{name: "logcat"}}},
		{"denials, partial", []string{"avc: denied"}, []diagSource{{name: "logcat"}, {name: "dmesg", err: "x"}}},
	}
	for _, c := range cases {
		if got := avcSection(c.den, c.srcs, nil); len(got) == 0 {
			t.Errorf("%s: section is empty", c.name)
		}
	}
}

func TestPrevBootSectionSaysWhenNothingWasCollected(t *testing.T) {
	got := joined(t, prevBootSection(nil, []diagSource{{name: "pstore", err: "no such file or directory"}}, nil))
	if !strings.Contains(got, "prev_boot: nothing collected") {
		t.Errorf("must state that nothing was collected; got:\n%s", got)
	}
	if !strings.Contains(got, "does NOT mean the last boot was clean") {
		t.Errorf("must warn against reading emptiness as a clean boot; got:\n%s", got)
	}
}

func TestAnrSectionStaysQuietWhenThereIsGenuinelyNothing(t *testing.T) {
	// Deliberately asymmetric with avc/prev_boot: an absent ANR dir is the NORMAL healthy state, so a standing
	// "no traces" line in every report would be noise. An unreadable dir is still reported.
	if got := anrSection(nil, []diagSource{{name: "anr", err: "no traces present"}}, nil); len(got) != 0 {
		t.Errorf("no traces present should render nothing; got:\n%s", joined(t, got))
	}
	got := joined(t, anrSection(nil, []diagSource{{name: "anr", err: "permission denied"}}, nil))
	if !strings.Contains(got, "unreadable") || !strings.Contains(got, "permission denied") {
		t.Errorf("an unreadable ANR dir must be reported; got:\n%s", got)
	}
}

func TestEverySectionIsReachableByTheDeleteStep(t *testing.T) {
	// A log key missing from trimIssueReport's `order` is never DELETED: the halving step shrinks it to 40
	// lines and then gives up, so the key silently becomes the most privileged content in the report and can
	// hold it over the ceiling forever (trimIssueReport returns with !trimmed and the gateway 413s).
	//
	// Halving alone cannot expose that, because it stops as soon as the report fits -- which is why the first
	// cut of this test passed vacuously on the old keys and asserted the wrong property. Force the delete path
	// instead: ONE section, already at the 40-line halving floor, still far over the ceiling. Now the only way
	// under is deletion, so a key absent from `order` fails here and nowhere else.
	const lineLen = 8000
	for _, k := range []string{"login.log", "roam.log", "mediad.log", "provision.log", "avc", "prev_boot", "anr", "uiderrors"} {
		lines := make([]string, 40)
		for i := range lines {
			lines[i] = strings.Repeat("x", lineLen)
		}
		rep := issueReport{Kind: "issue-report", Logs: map[string][]string{k: lines}}
		if n := 40 * lineLen; n <= maxIssueReportBytes {
			t.Fatalf("test is vacuous: %d bytes is already under the %d ceiling", n, maxIssueReportBytes)
		}
		trimIssueReport(&rep)
		if _, still := rep.Logs[k]; still {
			t.Errorf("section %q was NOT deleted when deletion was the only way under the ceiling -- add it to trimIssueReport's order list", k)
		}
	}
}

func TestTrimBringsAMixedReportUnderTheCeiling(t *testing.T) {
	// The property that actually matters end to end: whatever combination of sections is present, the report
	// that leaves the device fits, so it can never bounce on size at the gateway.
	rep := issueReport{Kind: "issue-report", Logs: map[string][]string{}}
	big := make([]string, 400)
	for i := range big {
		big[i] = strings.Repeat("x", 400)
	}
	for _, k := range []string{"login.log", "roam.log", "mediad.log", "provision.log", "avc", "prev_boot", "anr", "uiderrors"} {
		rep.Logs[k] = append([]string(nil), big...)
	}
	trimIssueReport(&rep)
	b, err := json.Marshal(rep)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if len(b) > maxIssueReportBytes {
		t.Errorf("trimmed report is %d bytes, over the %d ceiling", len(b), maxIssueReportBytes)
	}
}
