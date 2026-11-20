package main

import (
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261202-43: an in-session issue report carries the always-on VPN's live state as vpn_state, read through
// roamd's read-only vpnstate op, and a sent report appends it to the day summary as a codes-only ev=vpnstate line.
// test-vpnstate-report.sh runs these and convicts each mutant by the test that names it. test-vpnstate-op.sh runs
// the roamd half.

// So that no other handleReportIssue test takes a real lane for vpnstateWait.
func init() { vpnstateWorker = func(dest, name, uid string) string { return "" } }

// vsReport runs one report through the real handleReportIssue with the vpnstate worker replaced, and returns the
// reply and whether the worker was asked. The other two workers answer nothing at once.
func vsReport(t *testing.T, dest, req string, worker func(dest, name, uid string) string) (string, bool) {
	t.Helper()
	prevU, prevG, prevV := uiderrorsWorker, gmsStateWorker, vpnstateWorker
	t.Cleanup(func() { uiderrorsWorker, gmsStateWorker, vpnstateWorker = prevU, prevG, prevV })
	uiderrorsWorker = func(string, string, string) string { return "" }
	gmsStateWorker = func(string, string, string) string { return "" }
	var called atomic.Bool
	vpnstateWorker = func(d, n, u string) string { called.Store(true); return worker(d, n, u) }
	c := &dsConn{r: strings.NewReader("")}
	handleReportIssue(c, dest, req)
	return c.out.String(), called.Load()
}

func vsReply(r string) func(string, string, string) string {
	return func(string, string, string) string { return r }
}

func TestVpnStateReportSessionScopeKey(t *testing.T) {
	dest := dsSetup(t, "vstest01", "70", 70*100000+10123)
	var gotName, gotUID string
	out, called := vsReport(t, dest, `{"preview":true}`, func(_, n, u string) string {
		gotName, gotUID = n, u
		return "VPNSTATE app=1 lock=1 pend=0 net=0 refused=none\n"
	})
	if !called || gotName != "vstest01" || gotUID != "70" {
		t.Fatalf("the worker was asked=%v with name=%q uid=%q, want this session's (vstest01, 70)", called, gotName, gotUID)
	}
	if !strings.Contains(out, `"vpn_state": "app=1 lock=1 pend=0 net=0"`) {
		t.Errorf("a session-scope preview lacks the worker's vpn_state: %s", out)
	}
	if !strings.Contains(out, `"vpn_refused": "none"`) {
		t.Errorf("a session-scope preview with refused=none lacks vpn_refused none: %s", out)
	}
}

func TestVpnStateReportGateScopeAbsent(t *testing.T) {
	dest := dsSetup(t, "vstest02", "71", 71*100000+10123)
	out, called := vsReport(t, dest, `{"preview":true,"gate":true}`, vsReply("VPNSTATE app=1 lock=1 pend=1 net=1 refused=none"))
	if called {
		t.Error("a gate report asked the vpnstate worker")
	}
	if strings.Contains(out, "vpn_state") || strings.Contains(out, "vpn_refused") {
		t.Errorf("a gate report carries vpn_state or vpn_refused: %s", out)
	}
	// No session marker at all: device scope too.
	dest = dsSetup(t, "vstest03", "", 72*100000+10123)
	out, called = vsReport(t, dest, `{"preview":true}`, vsReply("VPNSTATE app=1 lock=1 pend=1 net=1 refused=none"))
	if called || strings.Contains(out, "vpn_state") || strings.Contains(out, "vpn_refused") {
		t.Errorf("a report with no session asked=%v or carries vpn_state or vpn_refused: %s", called, out)
	}
}

func TestVpnStateReportCallerKeyRemoved(t *testing.T) {
	dest := dsSetup(t, "vstest04", "73", 73*100000+10123)
	status := `"status":{"vpn_state":"app=1 lock=1 pend=1 net=1","keepme":"k"}`
	out, _ := vsReport(t, dest, `{"preview":true,"gate":true,`+status+`}`, vsReply("VPNSTATE app=1 lock=1 pend=1 net=1 refused=none"))
	if strings.Contains(out, "vpn_state") || strings.Contains(out, "net=1") {
		t.Errorf("gate scope: a caller-sent vpn_state survived: %s", out)
	}
	if !strings.Contains(out, `"keepme": "k"`) {
		t.Errorf("gate scope: the report lost a non-VPN key: %s", out)
	}
	out, _ = vsReport(t, dest, `{"preview":true,`+status+`}`, vsReply("VPNSTATE app=0 lock=0 pend=0 net=- refused=none\n"))
	if !strings.Contains(out, `"vpn_state": "app=0 lock=0 pend=0 net=-"`) || strings.Contains(out, "net=1") {
		t.Errorf("session scope: vpn_state is not the worker's own value: %s", out)
	}
	if !strings.Contains(out, `"keepme": "k"`) {
		t.Errorf("session scope: the report lost a non-VPN key: %s", out)
	}
}

func TestVpnStateReportJunkIsUnavailable(t *testing.T) {
	dest := dsSetup(t, "vstest05", "74", 74*100000+10123)
	for _, r := range []string{
		"",
		"ERR-LANE",
		"ERR-TIMEOUT the worker did not answer within 10s",
		"VPNSTATE app=1 lock=1 pend=1",
		"VPNSTATE app=2 lock=0 pend=0 net=0 refused=none",
		"VPNSTATE app=1 lock=1 pend=0 net=1 refused=none pkg=org.example.vpnfixture",
		"VPNSTATE app=org.example.vpnfixture lock=1 pend=0 net=1 refused=none",
		"VPNSTATE app=1 lock=1 pend=0 net=1 refused=none\norg.example.vpnfixture",
		" VPNSTATE app=1 lock=1 pend=0 net=1 refused=none",
		"VPNSTATE app=1 lock=1 pend=0 net=1 refused=none ",
	} {
		out, _ := vsReport(t, dest, `{"preview":true}`, vsReply(r))
		if !strings.Contains(out, `"vpn_state": "unavailable"`) || !strings.Contains(out, `"vpn_refused": "unavailable"`) {
			t.Errorf("reply %q: vpn_state or vpn_refused is not unavailable: %s", r, out)
		}
		if strings.Contains(out, "vpnfixture") {
			t.Errorf("reply %q: the package reached the report", r)
		}
	}
}

func TestVpnStateReportTimeoutIsUnavailable(t *testing.T) {
	dest := dsSetup(t, "vstest06", "75", 75*100000+10123)
	prevWait := vpnstateWait
	vpnstateWait = 5 * time.Millisecond
	release := make(chan struct{})
	t.Cleanup(func() { close(release); vpnstateWait = prevWait })
	out, _ := vsReport(t, dest, `{"preview":true}`, func(string, string, string) string {
		<-release
		return "VPNSTATE app=1 lock=1 pend=1 net=1 refused=none"
	})
	if !strings.Contains(out, `"vpn_state": "unavailable"`) || !strings.Contains(out, `"vpn_refused": "unavailable"`) {
		t.Errorf("a worker that never answers did not give unavailable: %s", out)
	}
}

func TestVpnStateReportPreviewAppendsNothing(t *testing.T) {
	dest := dsSetup(t, "vstest07", "76", 76*100000+10123)
	dsMarkerOn(t, "76")
	out, _ := vsReport(t, dest, `{"preview":true}`, vsReply("VPNSTATE app=1 lock=0 pend=0 net=1 refused=none\n"))
	if strings.Contains(dsRead(t, daySummaryPath("76")), "ev=vpnstate") {
		t.Errorf("a preview appended a vpnstate line: %q", dsRead(t, daySummaryPath("76")))
	}
	if strings.Contains(out, "ev=vpnstate") {
		t.Errorf("a preview's day_summary carries a vpnstate line: %s", out)
	}
}

func TestVpnStateReportSentAppendsOne(t *testing.T) {
	dest := dsSetup(t, "vstest08", "77", 77*100000+10123)
	dsMarkerOn(t, "77")
	out, _ := vsReport(t, dest, `{"note":"n"}`, vsReply("VPNSTATE app=1 lock=0 pend=0 net=1 refused=none\n"))
	if out != "ERR-NOGW\n" {
		t.Fatalf("the sent report replied %q, want ERR-NOGW (no gateway in a test)", out)
	}
	// NWP-20261202-11 records every sent session report as a report line after its reply (here ERR-NOGW): it
	// follows the vpnstate line, which is appended before the report is sent.
	want := "v=1 t=1800000000 ev=vpnstate app=1 lock=0 pend=0 net=1\nv=1 t=1800000000 ev=report kind=none rc=nogw\n"
	if got := dsRead(t, daySummaryPath("77")); got != want {
		t.Errorf("a sent report's day summary = %q, want exactly %q", got, want)
	}
	// An unavailable state appends nothing.
	if err := os.Remove(daySummaryPath("77")); err != nil {
		t.Fatal(err)
	}
	vsReport(t, dest, `{"note":"n"}`, vsReply("ERR-LANE"))
	if got := dsRead(t, daySummaryPath("77")); strings.Contains(got, "ev=vpnstate") {
		t.Errorf("an unavailable state appended a line: %q", got)
	}
	// Without the opt-in marker nothing is written (the unavailable report above still left its report line).
	if err := os.Remove(daySummaryPath("77")); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(daySummaryMarker("77")); err != nil {
		t.Fatal(err)
	}
	vsReport(t, dest, `{"note":"n"}`, vsReply("VPNSTATE app=1 lock=0 pend=0 net=1 refused=none"))
	if dsExists(daySummaryPath("77")) {
		t.Error("a session that has not opted in got a day summary")
	}
}

func TestVpnStateReportShapeRoundTrips(t *testing.T) {
	dsSetup(t, "vstest09", "78", 78*100000+10123)
	l := daySummaryVpnStateLine(time.Unix(1800000000, 0), "app=1 lock=- pend=0 net=-")
	if l != "v=1 t=1800000000 ev=vpnstate app=1 lock=- pend=0 net=-" {
		t.Fatalf("daySummaryVpnStateLine = %q", l)
	}
	if tt, ok := daySummaryLineT(l); !ok || tt != 1800000000 {
		t.Errorf("daySummaryLineT(%q) = %d, %v; want 1800000000, true", l, tt, ok)
	}
	p := daySummaryPath("78")
	body := "v=1 t=1800000000 ev=save ms=9 rc=ok\n" + l + "\n"
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := daySummaryStatus(p)["day_summary"]; got != "v=1 t=1800000000 ev=save ms=9 rc=ok;"+l {
		t.Errorf("daySummaryStatus read %q", got)
	}
	for _, bad := range []string{
		"v=1 t=1800000000 ev=vpnstate app=1 lock=0 pend=0 net=x",
		"v=1 t=1800000000 ev=vpnstate app=1 lock=0 pend=0 net=1 extra=1",
		"v=1 t=1800000000 ev=vpnstate app=org.example.vpnfixture lock=0 pend=0 net=1",
		"v=1 t=1800000000 ev=vpnstate app=1 lock=0 net=1",
	} {
		if err := os.WriteFile(p, []byte(l+"\n"+bad+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := daySummaryStatus(p)["day_summary"]; got != "unreadable" {
			t.Errorf("a loosened line %q read as %q, want unreadable", bad, got)
		}
	}
}

func TestVpnStateReportLane(t *testing.T) {
	if got := laneFor("vpnstate"); got.svc != laneRO.svc {
		t.Errorf("vpnstate rides %q, want the read-only lane", got.svc)
	}
	if got := workerWaitCap("vpnstate"); got != 10*time.Second {
		t.Errorf("workerWaitCap(vpnstate) = %s, want 10s", got)
	}
}

func TestVpnStateReportWorkerSendsNoPass(t *testing.T) {
	b, err := os.ReadFile("report_issue.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "var vpnstateWorker = func(dest, name, uid string) string {\n\treturn triggerRoamWorker(dest, \"vpnstate\", name, \"\", uid, \"\", nil)\n}") {
		t.Error("vpnstateWorker is not the passphrase-free RO request triggerRoamWorker(dest, \"vpnstate\", name, \"\", uid, \"\", nil)")
	}
}

// NWP-20261208-10: the reply's fifth field, the last always-on apply Android refused this session, as vpn_refused.

func TestVpnStateReportRefusedValid(t *testing.T) {
	dest := dsSetup(t, "vstest10", "79", 79*100000+10123)
	dsMarkerOn(t, "79")
	out, _ := vsReport(t, dest, `{"preview":true}`,
		vsReply("VPNSTATE app=1 lock=0 pend=0 net=1 refused=n2.inst1.hid0.en1.stop1.svc1.tsdk1.usrunlocked.lock0\n"))
	if !strings.Contains(out, `"vpn_state": "app=1 lock=0 pend=0 net=1"`) {
		t.Errorf("vpn_state is not the four codes: %s", out)
	}
	if !strings.Contains(out, `"vpn_refused": "n=2 inst=1 hid=0 en=1 stop=1 svc=1 tsdk=1 usr=unlocked lock=0"`) {
		t.Errorf("vpn_refused is not rebuilt from the token: %s", out)
	}
	out, _ = vsReport(t, dest, `{"preview":true}`,
		vsReply("VPNSTATE app=1 lock=1 pend=1 net=- refused=n999.inst-.hid-.en-.stop-.svc-.tsdk-.usr-.lock1"))
	if !strings.Contains(out, `"vpn_refused": "n=999 inst=- hid=- en=- stop=- svc=- tsdk=- usr=- lock=1"`) {
		t.Errorf("a token of dashes is not rebuilt: %s", out)
	}
	out, _ = vsReport(t, dest, `{"preview":true}`, vsReply("VPNSTATE app=1 lock=0 pend=0 net=1 refused=-"))
	if !strings.Contains(out, `"vpn_refused": "unreadable"`) || !strings.Contains(out, `"vpn_state": "app=1 lock=0 pend=0 net=1"`) {
		t.Errorf("refused=- is not vpn_refused unreadable beside a valid vpn_state: %s", out)
	}
	// The day-summary line stays the four codes.
	if err := os.Remove(daySummaryPath("79")); err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	vsReport(t, dest, `{"note":"n"}`,
		vsReply("VPNSTATE app=1 lock=0 pend=0 net=1 refused=n2.inst1.hid0.en1.stop1.svc1.tsdk1.usrunlocked.lock0"))
	want := "v=1 t=1800000000 ev=vpnstate app=1 lock=0 pend=0 net=1\n"
	if got := dsRead(t, daySummaryPath("79")); !strings.HasPrefix(got, want) {
		t.Errorf("the day summary = %q, want it to start %q", got, want)
	}
}

func TestVpnStateReportRefusedJunk(t *testing.T) {
	dest := dsSetup(t, "vstest11", "80", 80*100000+10123)
	for _, r := range []string{
		"VPNSTATE app=1 lock=0 pend=0 net=1",
		"VPNSTATE app=1 lock=0 pend=0 net=1 refused=",
		"VPNSTATE app=1 lock=0 pend=0 net=1 refused=n2.inst1.hid0.en1.stop1.svc1.tsdk1.usrorg.example.vpnfixture.lock0",
		"VPNSTATE app=1 lock=0 pend=0 net=1 refused=org.example.vpnfixture",
		"VPNSTATE app=1 lock=0 pend=0 net=1 refused=n2.inst1.hid0.en1.stop1.svc1.tsdk1.usrbogus.lock0",
		"VPNSTATE app=1 lock=0 pend=0 net=1 refused=n0.inst1.hid0.en1.stop1.svc1.tsdk1.usrunlocked.lock0",
		"VPNSTATE app=1 lock=0 pend=0 net=1 refused=n1000.inst1.hid0.en1.stop1.svc1.tsdk1.usrunlocked.lock0",
		"VPNSTATE app=1 lock=0 pend=0 net=1 refused=n01.inst1.hid0.en1.stop1.svc1.tsdk1.usrunlocked.lock0",
		"VPNSTATE app=1 lock=0 pend=0 net=1 refused=n2.inst1.hid0.en1.stop1.svc1.tsdk1.usrunlocked.lock0.x1",
		"VPNSTATE app=1 lock=0 pend=0 net=1 refused=n2.inst1.hid0.en1.stop1.svc1.tsdk1.usrunlocked.lock0 x=1",
		"VPNSTATE app=1 lock=0 pend=0 net=1 refused=n2.inst2.hid0.en1.stop1.svc1.tsdk1.usrunlocked.lock0",
		"VPNSTATE app=1 lock=0 pend=0 net=1 refused=n2.inst1.hid0.en1.stop1.svc1.tsdk1.usrunlocked.lock-",
	} {
		out, _ := vsReport(t, dest, `{"preview":true}`, vsReply(r))
		if !strings.Contains(out, `"vpn_state": "unavailable"`) || !strings.Contains(out, `"vpn_refused": "unavailable"`) {
			t.Errorf("reply %q: vpn_state and vpn_refused are not both unavailable: %s", r, out)
		}
		if strings.Contains(out, "vpnfixture") || strings.Contains(out, "bogus") {
			t.Errorf("reply %q: a word of the reply reached the report", r)
		}
	}
}

func TestVpnStateReportRefusedCallerKeyRemoved(t *testing.T) {
	dest := dsSetup(t, "vstest12", "81", 81*100000+10123)
	status := `"status":{"vpn_refused":"n=7 sent-by-caller","keepme":"k"}`
	out, called := vsReport(t, dest, `{"preview":true,"gate":true,`+status+`}`, vsReply("VPNSTATE app=1 lock=1 pend=1 net=1 refused=none"))
	if called || strings.Contains(out, "vpn_refused") || strings.Contains(out, "sent-by-caller") {
		t.Errorf("gate scope: asked=%v, or a caller-sent vpn_refused survived: %s", called, out)
	}
	if !strings.Contains(out, `"keepme": "k"`) {
		t.Errorf("gate scope: the report lost a non-VPN key: %s", out)
	}
	out, _ = vsReport(t, dest, `{"preview":true,`+status+`}`, vsReply("VPNSTATE app=0 lock=0 pend=0 net=- refused=none"))
	if !strings.Contains(out, `"vpn_refused": "none"`) || strings.Contains(out, "sent-by-caller") {
		t.Errorf("session scope: vpn_refused is not the worker's own value: %s", out)
	}
}
