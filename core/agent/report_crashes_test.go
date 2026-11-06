package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"
)

// NWP-20261128-17 (Q121): an in-session issue report carries this session's app crashes and crash_access; a gate
// report carries neither. Every test drives the real handleReportIssue (preview) or trimIssueReport, has its own
// profile name, state dir and dest, and restores the one seam it replaces. The tests use the contract's numbers
// (5 records, 4096 bytes, 600 lines) as literals, so they compile and fail by name on a tree without the merge.

// rcConn is a net.Conn that reads nothing and records every write.
type rcConn struct {
	r   *strings.Reader
	out bytes.Buffer
}

func (c *rcConn) Read(b []byte) (int, error)       { return c.r.Read(b) }
func (c *rcConn) Write(b []byte) (int, error)      { return c.out.Write(b) }
func (c *rcConn) Close() error                     { return nil }
func (c *rcConn) LocalAddr() net.Addr              { return nil }
func (c *rcConn) RemoteAddr() net.Addr             { return nil }
func (c *rcConn) SetDeadline(time.Time) error      { return nil }
func (c *rcConn) SetReadDeadline(time.Time) error  { return nil }
func (c *rcConn) SetWriteDeadline(time.Time) error { return nil }

// rcSetup gives a test its own state dir, log dir and dest, and a live session under name for uid when name is not
// "". The uiderrors worker answers "" at once. It returns dest.
func rcSetup(t *testing.T, name, uid string) string {
	t.Helper()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_DIR", t.TempDir())
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("NOWHERE_GATEWAY_DEFAULT", "")
	dest := t.TempDir()
	if name != "" {
		if err := markRoamSession(dest, name, "pw-"+name, uid, ""); err != nil {
			t.Fatal(err)
		}
	}
	prev := uiderrorsWorker
	t.Cleanup(func() { uiderrorsWorker = prev })
	uiderrorsWorker = func(dest, name, uid string) string { return "" }
	return dest
}

// rcPreview runs one preview request through handleReportIssue and parses the report it answers.
func rcPreview(t *testing.T, dest, reqJSON string) issueReport {
	t.Helper()
	c := &rcConn{r: strings.NewReader("")}
	handleReportIssue(c, dest, reqJSON)
	var rep issueReport
	if err := json.Unmarshal(c.out.Bytes(), &rep); err != nil {
		t.Fatalf("preview is not a report: %v\n%s", err, c.out.String())
	}
	return rep
}

// rcRequest builds a preview request with the given crash_access and crashes (nil: no crashes key).
func rcRequest(t *testing.T, gate bool, access string, crashes []string) string {
	t.Helper()
	m := map[string]any{"preview": true, "crash_access": access}
	if gate {
		m["gate"] = true
	}
	if crashes != nil {
		m["crashes"] = crashes
	}
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func rcCrash(tag string, age int, pkg, stack string) string {
	return fmt.Sprintf("%s age_s=%d\nProcess: %s\nUID: 1010123\n\n%s\n\tat %s.A.b(A.java:1)", tag, age, pkg, stack, pkg)
}

// lineIndex is the index of the first line holding sub, or -1.
func lineIndex(lines []string, sub string) int {
	for i, l := range lines {
		if strings.Contains(l, sub) {
			return i
		}
	}
	return -1
}

// R1: session scope carries crash_access, crash_n and the section, oldest crash first.
func TestReportCrashesSessionCarries(t *testing.T) {
	dest := rcSetup(t, "rctestA1", "10")
	newest := rcCrash("data_app_crash", 3, "com.example.one", "java.lang.RuntimeException: boom-new")
	older := rcCrash("data_app_crash", 90, "com.example.one", "java.lang.RuntimeException: boom-old")
	rep := rcPreview(t, dest, rcRequest(t, false, "ok", []string{newest, older}))
	if got := rep.Status["crash_access"]; got != "ok" {
		t.Errorf("crash_access = %q, want ok", got)
	}
	if got := rep.Status["crash_n"]; got != "2" {
		t.Errorf("crash_n = %q, want 2", got)
	}
	sec, ok := rep.Logs["crashes"]
	if !ok {
		t.Fatalf("no crashes section; logs: %v", rep.Logs)
	}
	iOld, iNew := lineIndex(sec, "boom-old"), lineIndex(sec, "boom-new")
	if iOld < 0 || iNew < 0 {
		t.Fatalf("the section lacks a crash: %q", sec)
	}
	if iOld > iNew {
		t.Errorf("the older crash (line %d) comes after the newer one (line %d): the section must be oldest first", iOld, iNew)
	}
}

// R2: the profile name inside a stack is redacted; the line stays.
func TestReportCrashesNameRedacted(t *testing.T) {
	dest := rcSetup(t, "rctestB2", "11")
	c := rcCrash("data_app_crash", 4, "com.example.two", "java.lang.IllegalStateException: no account for rctestB2 (RCTESTB2)")
	rep := rcPreview(t, dest, rcRequest(t, false, "ok", []string{c}))
	sec, ok := rep.Logs["crashes"]
	if !ok {
		t.Fatalf("no crashes section; logs: %v", rep.Logs)
	}
	if strings.Contains(strings.ToLower(strings.Join(sec, "\n")), "rctestb2") {
		t.Errorf("the profile name reached the crashes section: %q", sec)
	}
	if lineIndex(sec, "IllegalStateException") < 0 {
		t.Errorf("the stack line was dropped, not redacted: %q", sec)
	}
}

// R3: a gate report (gate:true, or no session) carries neither key nor the section. Case (a) is the control.
func TestReportCrashesGateCarriesNothing(t *testing.T) {
	crashes := []string{rcCrash("data_app_crash", 5, "com.example.three", "java.lang.RuntimeException: boom-gate")}
	dest := rcSetup(t, "rctestC3", "12")
	ctl := rcPreview(t, dest, rcRequest(t, false, "ok", crashes))
	if _, ok := ctl.Status["crash_access"]; !ok {
		t.Errorf("control: an in-session report lacks crash_access")
	}
	if _, ok := ctl.Status["crash_n"]; !ok {
		t.Errorf("control: an in-session report lacks crash_n")
	}
	if _, ok := ctl.Logs["crashes"]; !ok {
		t.Errorf("control: an in-session report lacks the crashes section")
	}
	check := func(label string, rep issueReport) {
		if v, ok := rep.Status["crash_access"]; ok {
			t.Errorf("%s: a gate report carries crash_access=%q", label, v)
		}
		if v, ok := rep.Status["crash_n"]; ok {
			t.Errorf("%s: a gate report carries crash_n=%q", label, v)
		}
		if _, ok := rep.Logs["crashes"]; ok {
			t.Errorf("%s: a gate report carries the crashes section", label)
		}
		b, _ := json.Marshal(rep)
		if bytes.Contains(b, []byte("boom-gate")) {
			t.Errorf("%s: a crash text reached a gate report", label)
		}
	}
	check("gate:true", rcPreview(t, dest, rcRequest(t, true, "ok", crashes)))
	check("no session", rcPreview(t, rcSetup(t, "", ""), rcRequest(t, false, "ok", crashes)))
}

// R4: only ok, denied and error reach the report; crash_n is 0 and no section when no crashes come.
func TestReportCrashesAccessValue(t *testing.T) {
	dest := rcSetup(t, "rctestD4", "13")
	for _, v := range []string{"maybe", "", "OK", "ok "} {
		rep := rcPreview(t, dest, rcRequest(t, false, v, nil))
		if got, ok := rep.Status["crash_access"]; ok {
			t.Errorf("crash_access %q reached the report as %q", v, got)
		}
	}
	for _, v := range []string{"denied", "error"} {
		rep := rcPreview(t, dest, rcRequest(t, false, v, nil))
		if got := rep.Status["crash_access"]; got != v {
			t.Errorf("crash_access = %q, want %q", got, v)
		}
		if got := rep.Status["crash_n"]; got != "0" {
			t.Errorf("crash_access %q: crash_n = %q, want 0", v, got)
		}
		if _, ok := rep.Logs["crashes"]; ok {
			t.Errorf("crash_access %q with no crashes: a crashes section exists", v)
		}
	}
}

// R5: an oversized crashes section is deleted by trimIssueReport, so it must be in issueTrimOrder (before anr).
func TestReportCrashesTrimmable(t *testing.T) {
	lines := make([]string, 20) // <= 40 lines: the halving step cannot apply, only deletion can
	for i := range lines {
		lines[i] = strings.Repeat("x", 12000)
	}
	rep := issueReport{Kind: "issue-report", Status: map[string]string{}, Logs: map[string][]string{"crashes": lines}}
	trimIssueReport(&rep)
	if b, _ := json.Marshal(rep); len(b) > maxIssueReportBytes {
		t.Errorf("trim left %d bytes, ceiling is %d", len(b), maxIssueReportBytes)
	}
	if _, ok := rep.Logs["crashes"]; ok {
		t.Errorf("trimIssueReport did not delete an oversized crashes section")
	}
	iC, iA := -1, -1
	for i, k := range issueTrimOrder {
		switch k {
		case "crashes":
			iC = i
		case "anr":
			iA = i
		}
	}
	if iC < 0 || iA < 0 || iC > iA {
		t.Errorf("issueTrimOrder must hold crashes before anr: %q", issueTrimOrder)
	}
}

// R6: the 600-line cap keeps the newest lines; at most five records; each cut to 4096 bytes.
func TestReportCrashesCaps(t *testing.T) {
	dest := rcSetup(t, "rctestE5", "14")

	// (a) The line cap. Each record is below 4096 bytes, so only the line cap can cut it.
	var big []string
	for n := 1; n <= 5; n++ { // c1 is the newest, sent first as the chooser sends it
		c := fmt.Sprintf("data_app_crash age_s=%d\nProcess: com.example.c%d\n%s\tat end-c%d", n, n, strings.Repeat("\tat a\n", 650), n)
		if len(c) >= 4096 {
			t.Fatalf("fixture c%d is %d bytes: the byte cut would do the line cap's work", n, len(c))
		}
		big = append(big, c)
	}
	rep := rcPreview(t, dest, rcRequest(t, false, "ok", big))
	if got := rep.Status["crash_n"]; got != "5" {
		t.Errorf("crash_n = %q, want 5", got)
	}
	sec := rep.Logs["crashes"]
	if len(sec) != 600 {
		t.Errorf("the section holds %d lines, want exactly 600", len(sec))
	}
	if len(sec) > 0 && sec[len(sec)-1] != "\tat end-c1" {
		t.Errorf("the last line is %q, want the newest crash's last line", sec[len(sec)-1])
	}
	if lineIndex(sec, "com.example.c5") >= 0 || lineIndex(sec, "end-c5") >= 0 {
		t.Errorf("the oldest crash survived the line cap")
	}

	// (b) The count and byte cuts.
	var many []string
	for n := 1; n <= 7; n++ {
		c := fmt.Sprintf("data_app_crash age_s=%d\nProcess: com.example.k\n\njava.lang.RuntimeException: boom-%d", n, n)
		if n == 1 {
			c += "\n" + strings.Repeat("y", 6000-len(c)-len("\ntailword")) + "\ntailword"
		}
		many = append(many, c)
	}
	rep = rcPreview(t, dest, rcRequest(t, false, "ok", many))
	if got := rep.Status["crash_n"]; got != "5" {
		t.Errorf("seven crashes: crash_n = %q, want 5", got)
	}
	sec = rep.Logs["crashes"]
	if lineIndex(sec, "boom-1") < 0 {
		t.Fatalf("the newest crash is missing: %q", sec)
	}
	if lineIndex(sec, "boom-6") >= 0 || lineIndex(sec, "boom-7") >= 0 {
		t.Errorf("a sixth or seventh crash reached the section")
	}
	if lineIndex(sec, "tailword") >= 0 {
		t.Errorf("a record was not cut to 4096 bytes")
	}
}
