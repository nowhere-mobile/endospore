package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

// NWP-20261202-41 (backlog: "The diagnostic day summary records no outcome of the always-on VPN apply ..."): each
// always-on VPN apply adds one codes-only `ev=vpn at= rc= s= lock=` line to day-summary.<uid> -- the sign-in's vpnup
// (retryVpnup) and the deferred apply at a save or an install (roamd's .vpndiag.<uid>, taken after the out and
// bootwake ops). No line names the app, a tunnel, a profile or a path.

// dsvLines returns the summary's ev=vpn lines.
func dsvLines(t *testing.T, uid string) []string {
	t.Helper()
	var out []string
	for _, l := range strings.Split(dsRead(t, daySummaryPath(uid)), "\n") {
		if strings.Contains(l, " ev=vpn ") {
			out = append(out, l)
		}
	}
	return out
}

// dsvRecord writes roamd's VPN apply record for uid.
func dsvRecord(t *testing.T, uid, body string) {
	t.Helper()
	if err := os.WriteFile(daySummaryVpnRecord(uid), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

// dsvClock makes daySummaryNow return *at; dsSetup's cleanup restores it.
func dsvClock(at *time.Time) { daySummaryNow = func() time.Time { return *at } }

func dsvForgetInstant(t *testing.T, uid string) {
	t.Cleanup(func() {
		daySummaryMu.Lock()
		delete(daySummaryVpnSignin, uid)
		daySummaryMu.Unlock()
	})
}

func TestDaySummaryVpnShapeRoundTrips(t *testing.T) {
	dsSetup(t, "dsvtest01", "", 0)
	dsMarkerOn(t, "61")
	lines := []string{
		"v=1 t=1800000000 ev=vpn at=signin rc=applied s=3 lock=1",
		"v=1 t=1800000000 ev=vpn at=signin rc=none s=0 lock=-",
		"v=1 t=1800000000 ev=vpn at=seal rc=notready s=- lock=0",
		"v=1 t=1800000000 ev=vpn at=install rc=gaveup s=999999999 lock=1",
		"v=1 t=1800000000 ev=vpn at=seal rc=dropped s=120 lock=-",
		"v=1 t=1800000000 ev=vpn at=signin rc=nohelper s=1 lock=0",
		"v=1 t=1800000000 ev=vpn at=signin rc=deferred s=1 lock=1",
		"v=1 t=1800000000 ev=vpn at=signin rc=other s=1 lock=-",
	}
	for _, l := range lines {
		daySummaryAppend("61", l)
	}
	if got, want := dsRead(t, daySummaryPath("61")), strings.Join(lines, "\n")+"\n"; got != want {
		t.Fatalf("file %q, want %q", got, want)
	}
	got := daySummaryStatus(daySummaryPath("61"))
	if len(got) != 1 || got["day_summary"] != strings.Join(lines, ";") {
		t.Fatalf("status %v, want day_summary=%q", got, strings.Join(lines, ";"))
	}
}

func TestDaySummaryVpnRejectsOtherTokens(t *testing.T) {
	dsSetup(t, "dsvtest02", "", 0)
	good := "v=1 t=1800000000 ev=save ms=10 rc=ok\n"
	for label, bad := range map[string]string{
		"package as rc":  "v=1 t=1 ev=vpn at=signin rc=com.example.vpn s=1 lock=1",
		"unknown rc":     "v=1 t=1 ev=vpn at=signin rc=maybe s=1 lock=1",
		"unknown at":     "v=1 t=1 ev=vpn at=boot rc=applied s=1 lock=1",
		"lock 2":         "v=1 t=1 ev=vpn at=seal rc=applied s=1 lock=2",
		"extra field":    "v=1 t=1 ev=vpn at=seal rc=applied s=1 lock=1 app=com.example.vpn",
		"letters in s":   "v=1 t=1 ev=vpn at=seal rc=applied s=x lock=1",
		"ten-digit s":    "v=1 t=1 ev=vpn at=seal rc=applied s=1234567890 lock=1",
		"no lock":        "v=1 t=1 ev=vpn at=seal rc=applied s=1",
		"tunnel as at":   "v=1 t=1 ev=vpn at=secret-tunnel rc=applied s=1 lock=1",
		"path as rc":     "v=1 t=1 ev=vpn at=seal rc=/data/x s=1 lock=1",
		"empty rc value": "v=1 t=1 ev=vpn at=seal rc= s=1 lock=1",
	} {
		dsPlant(t, "62", good+bad+"\n")
		if got := daySummaryStatus(daySummaryPath("62")); got["day_summary"] != "unreadable" {
			t.Errorf("%s: status %v, want unreadable", label, got)
		}
	}
}

func TestDaySummaryVpnRetryWritesOneSigninLine(t *testing.T) {
	cases := []struct {
		name    string
		replies []string
		rc      string
	}{
		{"applied after a retry", []string{"NOTREADY", "OK APPLIED"}, "applied"},
		{"nothing to apply", []string{"OK NONE"}, "none"},
		{"no helper", []string{"OK NOHELPER"}, "nohelper"},
		{"an on-demand VPN app", []string{"OK DEFERRED"}, "deferred"},
		{"an older roamd's bare OK", []string{"OK"}, "other"},
		{"a give-up", []string{"NOTREADY"}, "gaveup"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dest := dsSetup(t, "Dsv Secret Profile", "63", 0)
			dsvForgetInstant(t, "63")
			dsMarkerOn(t, "63")
			withVpnupSeams(t, tc.replies)
			out := captureStderr(t, func() { retryVpnup(dest, "Dsv Secret Profile", "pass", "63") })
			got := dsvLines(t, "63")
			want := "v=1 t=1800000000 ev=vpn at=signin rc=" + tc.rc + " s=0 lock=-"
			if len(got) != 1 || got[0] != want {
				t.Fatalf("vpn lines %q, want exactly [%q]", got, want)
			}
			if s := daySummaryStatus(daySummaryPath("63")); s["day_summary"] != want {
				t.Fatalf("status %v, want day_summary=%q", s, want)
			}
			all := dsRead(t, daySummaryPath("63")) + out
			if strings.Contains(all, "Secret") || strings.Contains(all, "Dsv") {
				t.Fatalf("the summary or the log carries the profile name: %q", all)
			}
		})
	}
}

func TestDaySummaryVpnRetryPrefersRoamdRecord(t *testing.T) {
	dest := dsSetup(t, "dsvtest04", "64", 0)
	dsvForgetInstant(t, "64")
	dsMarkerOn(t, "64")
	withVpnupSeams(t, nil)
	vpnupWorker = func(dest, name, pass, uid string) string {
		dsvRecord(t, uid, "at=signin rc=applied lock=1\n")
		return "OK APPLIED"
	}
	captureStderr(t, func() { retryVpnup(dest, "dsvtest04", "pass", "64") })
	got := dsvLines(t, "64")
	if want := "v=1 t=1800000000 ev=vpn at=signin rc=applied s=0 lock=1"; len(got) != 1 || got[0] != want {
		t.Fatalf("vpn lines %q, want exactly [%q]", got, want)
	}
	if dsExists(daySummaryVpnRecord("64")) {
		t.Error("the record was not removed")
	}
}

func TestDaySummaryVpnSessionGoneWritesNothing(t *testing.T) {
	dest := dsSetup(t, "dsvtest05", "", 0) // no .roamsession: the session is gone
	dsvForgetInstant(t, "65")
	dsMarkerOn(t, "65")
	calls := withVpnupSeams(t, []string{"OK APPLIED"})
	out := captureStderr(t, func() { retryVpnup(dest, "dsvtest05", "pass", "65") })
	if *calls != 0 || !strings.Contains(out, "no longer this session's") {
		t.Fatalf("the worker ran %d times, log %q: want a stop before any try", *calls, out)
	}
	if got := dsvLines(t, "65"); len(got) != 0 {
		t.Fatalf("vpn lines %q, want none", got)
	}
}

func TestDaySummaryVpnSealAndInstall(t *testing.T) {
	dsSetup(t, "dsvtest06", "", 0)
	dsvForgetInstant(t, "66")
	dsMarkerOn(t, "66")
	now := time.Unix(1800000000, 0)
	dsvClock(&now)
	daySummaryVpnStart("66")
	now = now.Add(42*time.Second + 900*time.Millisecond)
	dsvRecord(t, "66", "at=seal rc=notready lock=1\nat=install rc=applied lock=1\n")
	daySummaryVpnAfterOp("out", "66")
	want := []string{
		"v=1 t=1800000042 ev=vpn at=seal rc=notready s=42 lock=1",
		"v=1 t=1800000042 ev=vpn at=install rc=applied s=42 lock=1",
	}
	if got := dsvLines(t, "66"); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("vpn lines %q, want %q", got, want)
	}
	if dsExists(daySummaryVpnRecord("66")) {
		t.Fatal("the take did not remove the record")
	}
	daySummaryVpnAfterOp("bootwake", "66")
	if got := dsvLines(t, "66"); len(got) != 2 {
		t.Fatalf("a second take appended: %q", got)
	}

	daySummaryForget("66")
	dsMarkerOn(t, "66")
	dsvRecord(t, "66", "at=seal rc=applied lock=0\n")
	daySummaryVpnAfterOp("out", "66")
	if got, w := dsvLines(t, "66"), "v=1 t=1800000042 ev=vpn at=seal rc=applied s=- lock=0"; len(got) != 1 || got[0] != w {
		t.Fatalf("after the forget, vpn lines %q, want [%q]", got, w)
	}
}

func TestDaySummaryVpnAfterOpOnlyOutAndBootwake(t *testing.T) {
	dsSetup(t, "dsvtest07", "", 0)
	dsMarkerOn(t, "67")
	for _, op := range []string{"vpnup", "in", "grant", ""} {
		dsvRecord(t, "67", "at=seal rc=applied lock=1\n")
		daySummaryVpnAfterOp(op, "67")
		if got := dsvLines(t, "67"); len(got) != 0 || !dsExists(daySummaryVpnRecord("67")) {
			t.Fatalf("op %q: vpn lines %q, record kept %v: want no take", op, got, dsExists(daySummaryVpnRecord("67")))
		}
	}
	daySummaryVpnAfterOp("bootwake", "67")
	if got := dsvLines(t, "67"); len(got) != 1 || dsExists(daySummaryVpnRecord("67")) {
		t.Fatalf("bootwake: vpn lines %q, record kept %v", got, dsExists(daySummaryVpnRecord("67")))
	}
}

func TestDaySummaryVpnNoMarkerRemovesRecord(t *testing.T) {
	dsSetup(t, "dsvtest08", "", 0)
	dsvRecord(t, "68", "at=seal rc=applied lock=1\n")
	daySummaryTakeVpn("68", "gaveup")
	if dsExists(daySummaryPath("68")) {
		t.Errorf("a session that has not opted in got a summary: %q", dsRead(t, daySummaryPath("68")))
	}
	if dsExists(daySummaryVpnRecord("68")) {
		t.Error("the record was kept without the marker")
	}
}

func TestDaySummaryVpnDropsBadRecordLines(t *testing.T) {
	dsSetup(t, "dsvtest09", "", 0)
	dsMarkerOn(t, "69")
	dsvRecord(t, "69", strings.Join([]string{
		"at=signin rc=com.example.vpn lock=1",
		"at=boot rc=applied lock=1",
		"at=seal rc=applied lock=1 app=com.example.vpn",
		"at=seal rc=applied lock=/data/user/69",
		"at=seal rc=applied lock=1",
	}, "\n")+"\n")
	daySummaryTakeVpn("69", "")
	got := dsvLines(t, "69")
	if len(got) != 1 || got[0] != "v=1 t=1800000000 ev=vpn at=seal rc=applied s=- lock=1" {
		t.Fatalf("vpn lines %q, want the one valid record line", got)
	}
	body := dsRead(t, daySummaryPath("69"))
	if strings.Contains(body, "example") || strings.Contains(body, "/data") || strings.Contains(body, "boot") {
		t.Fatalf("the summary copies record text: %q", body)
	}

	// Over 4 KiB: only the first 4 KiB is read; a valid line after it is never seen, and the record still goes.
	dsvRecord(t, "69", strings.Repeat("x", daySummaryVpnMaxBytes)+"\nat=install rc=gaveup lock=0\n")
	daySummaryTakeVpn("69", "")
	if got := dsvLines(t, "69"); len(got) != 1 || dsExists(daySummaryVpnRecord("69")) {
		t.Fatalf("an over-long record: vpn lines %q, record kept %v", got, dsExists(daySummaryVpnRecord("69")))
	}
}

func TestDaySummaryVpnForgetRemovesRecord(t *testing.T) {
	dsSetup(t, "dsvtest10", "", 0)
	dsMarkerOn(t, "70")
	daySummaryVpnStart("70")
	dsvRecord(t, "70", "at=seal rc=applied lock=1\n")
	daySummaryForget("70")
	if dsExists(daySummaryVpnRecord("70")) {
		t.Error("daySummaryForget left the record")
	}
	daySummaryMu.Lock()
	_, ok := daySummaryVpnSignin["70"]
	daySummaryMu.Unlock()
	if ok {
		t.Error("daySummaryForget left the sign-in instant")
	}
}

func TestDaySummaryVpnRCIsClosed(t *testing.T) {
	for in, want := range map[string]string{
		"OK APPLIED": "applied", "OK NONE": "none", "OK NOHELPER": "nohelper", "OK DEFERRED": "deferred",
		"OK": "other", "OK com.example.vpn": "other", "NOTREADY": "other", "OK APPLIED\nmore": "applied",
	} {
		if got := daySummaryVpnRC(in); got != want {
			t.Errorf("daySummaryVpnRC(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDaySummaryVpnSourcePins(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`func triggerRoamWorkerKind\([^\n]*\) \(res string\) \{\n\tdefer daySummaryRecordSave\([^\n]*\n\tdefer daySummaryVpnAfterOp\(op, uid\)`).Match(b) {
		t.Error("triggerRoamWorkerKind's second statement is not the deferred VPN take after the save writer")
	}
}
