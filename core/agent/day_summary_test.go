package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// NWP-20261124-12 (backlog: A beta profile has no way to send a diagnostic report on a schedule ...): while a session
// has opted in (DIAG-SUMMARY on, only on a phone enrolled with the beta gateway), the agent keeps a numbers-only
// summary of its sign-in, each periodic and manual save and each Auto sweep in $STATE/day-summary.<uid>, and an
// in-session report carries it whole as day_summary. Every test has its own state dir, dest, uid and profile name,
// drives the handlers through a recording conn (no goroutine) and restores every seam it replaces.

// dsConn is a net.Conn that reads a fixed request and records every write.
type dsConn struct {
	r   *strings.Reader
	out bytes.Buffer
}

func (c *dsConn) Read(b []byte) (int, error)       { return c.r.Read(b) }
func (c *dsConn) Write(b []byte) (int, error)      { return c.out.Write(b) }
func (c *dsConn) Close() error                     { return nil }
func (c *dsConn) LocalAddr() net.Addr              { return nil }
func (c *dsConn) RemoteAddr() net.Addr             { return nil }
func (c *dsConn) SetDeadline(time.Time) error      { return nil }
func (c *dsConn) SetReadDeadline(time.Time) error  { return nil }
func (c *dsConn) SetWriteDeadline(time.Time) error { return nil }

// dsSetup gives a test its own state dir and dest, a live session for uid under the profile name, a fixed clock,
// and the peer uid the verbs see. It returns dest.
func dsSetup(t *testing.T, name, uid string, peer int) string {
	t.Helper()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("NOWHERE_GATEWAY_DEFAULT", "")
	dest := t.TempDir()
	if uid != "" {
		if err := markRoamSession(dest, name, "pw-"+name, uid, ""); err != nil {
			t.Fatal(err)
		}
	}
	prevPeer, prevNow := ownerPeerUID, daySummaryNow
	t.Cleanup(func() { ownerPeerUID, daySummaryNow = prevPeer, prevNow })
	ownerPeerUID = func(net.Conn) int { return peer }
	daySummaryNow = func() time.Time { return time.Unix(1800000000, 0) }
	return dest
}

// dsVerb sends one verb through the real handleLogin and returns its reply.
func dsVerb(t *testing.T, dest, verb, arg string) string {
	t.Helper()
	c := &dsConn{r: strings.NewReader(verb + "\n" + arg + "\n")}
	handleLogin(c, dest)
	return c.out.String()
}

func dsExists(p string) bool { _, err := os.Stat(p); return err == nil }

func dsRead(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return string(b)
}

func dsMarkerOn(t *testing.T, uid string) {
	t.Helper()
	if err := os.WriteFile(daySummaryMarker(uid), nil, 0o600); err != nil {
		t.Fatal(err)
	}
}

func dsPlant(t *testing.T, uid, body string) {
	t.Helper()
	if err := os.WriteFile(daySummaryPath(uid), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

const dsBeta = "https://api-beta.nowhere.mobile"

func TestDaySummaryShapesRoundTrip(t *testing.T) {
	dsSetup(t, "dstest01", "41", 41*100000+10123)
	dsMarkerOn(t, "41")
	lines := []string{
		"v=1 t=1800000000 ev=signin ms=1200+-+3400+56+7",
		"v=1 t=1800000000 ev=save ms=8123 rc=partial",
		"v=1 t=1800000000 ev=save ms=8123 rc=ok kib=2069",
		"v=1 t=1800000000 ev=sweep apps=12 ok=11 fail=1 ms=90000",
	}
	for _, l := range lines {
		daySummaryAppend("41", l)
	}
	if got, want := dsRead(t, daySummaryPath("41")), strings.Join(lines, "\n")+"\n"; got != want {
		t.Fatalf("file %q, want %q", got, want)
	}
	if fi, err := os.Stat(daySummaryPath("41")); err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("file mode: %v %v", fi, err)
	}
	got := daySummaryStatus(daySummaryPath("41"))
	if len(got) != 1 || got["day_summary"] != strings.Join(lines, ";") {
		t.Fatalf("status %v, want day_summary=%q", got, strings.Join(lines, ";"))
	}
	if dsExists(daySummaryPath("41") + ".tmp") {
		t.Error("the temp file was left behind")
	}
}

func TestDaySummaryUnreadableShapes(t *testing.T) {
	dsSetup(t, "dstest02", "", 0)
	good := "v=1 t=1800000000 ev=save ms=10 rc=ok\n"
	for label, bad := range map[string]string{
		"letter path":  "v=1 t=1 ev=save ms=/data/x rc=ok",
		"package name": "v=1 t=1 ev=sweep apps=com.example.app ok=1 fail=0 ms=1",
		"extra field":  "v=1 t=1 ev=save ms=1 rc=ok x=1",
		"unknown rc":   "v=1 t=1 ev=save ms=1 rc=maybe",
		"version 2":    "v=2 t=1 ev=save ms=1 rc=ok",
		"name in ms":   "v=1 t=1 ev=signin ms=1+2+alice+4+5",
		"blank line":   "",
	} {
		p := filepath.Join(loginStateDir(), "day-summary.unread")
		if err := os.WriteFile(p, []byte(good+bad+"\n"+good), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := daySummaryStatus(p); len(got) != 1 || got["day_summary"] != "unreadable" {
			t.Errorf("%s: %v, want day_summary=unreadable alone", label, got)
		}
	}
	big := filepath.Join(loginStateDir(), "day-summary.big")
	var b strings.Builder
	for b.Len() <= daySummaryMaxBytes {
		b.WriteString(good)
	}
	if err := os.WriteFile(big, []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := daySummaryStatus(big); got["day_summary"] != "unreadable" {
		t.Errorf("a file over 16 KiB: %v, want unreadable", got)
	}
	if got := daySummaryStatus(filepath.Join(loginStateDir(), "day-summary.none")); len(got) != 0 {
		t.Errorf("a missing file: %v, want no key", got)
	}
}

func TestDaySummaryPrune24h(t *testing.T) {
	dsSetup(t, "dstest03", "43", 43*100000+10123)
	dsMarkerOn(t, "43")
	now := int64(1800000000)
	old := fmt.Sprintf("v=1 t=%d ev=save ms=1 rc=ok", now-25*3600)
	recent := fmt.Sprintf("v=1 t=%d ev=save ms=2 rc=ok", now-23*3600)
	dsPlant(t, "43", old+"\n"+recent+"\n")
	add := fmt.Sprintf("v=1 t=%d ev=save ms=3 rc=busy", now)
	daySummaryAppend("43", add)
	if got, want := dsRead(t, daySummaryPath("43")), recent+"\n"+add+"\n"; got != want {
		t.Fatalf("after the prune %q, want %q", got, want)
	}
}

func TestDaySummaryPrune16KiB(t *testing.T) {
	dsSetup(t, "dstest04", "44", 44*100000+10123)
	dsMarkerOn(t, "44")
	var lines []string
	size := 0
	for i := 0; ; i++ {
		l := fmt.Sprintf("v=1 t=1800000000 ev=save ms=%d rc=ok kib=%d", 100000+i, 100000+i)
		if size+len(l)+1 > daySummaryMaxBytes {
			break
		}
		lines = append(lines, l)
		size += len(l) + 1
	}
	dsPlant(t, "44", strings.Join(lines, "\n")+"\n")
	// Longer than any planted line, so the planted file plus it is over the cap.
	add := "v=1 t=1800000000 ev=save ms=999999999999 rc=ok kib=999999999999999"
	daySummaryAppend("44", add)
	got := dsRead(t, daySummaryPath("44"))
	if len(got) > daySummaryMaxBytes {
		t.Fatalf("file is %d bytes, want at most %d", len(got), daySummaryMaxBytes)
	}
	if strings.Contains(got, lines[0]+"\n") {
		t.Error("the oldest line survived the size prune")
	}
	if !strings.HasSuffix(got, add+"\n") || !strings.Contains(got, lines[len(lines)-1]+"\n") {
		t.Error("the newest lines are not kept")
	}
	if daySummaryStatus(daySummaryPath("44"))["day_summary"] == "unreadable" {
		t.Error("the writer's own pruned file reads as unreadable")
	}
}

// NWP-20261202-09 (backlog: The diagnostic day summary's 16 KiB lets periodic saves push the sign-in and the Auto
// sweep out of it): a day of periodic saves fills the file, and the sign-in and the sweep are still in it.
func TestDaySummaryKeepsSigninAndSweepUnderSaves(t *testing.T) {
	dsSetup(t, "dstest25", "67", 67*100000+10123)
	dsMarkerOn(t, "67")
	now := int64(1800000000)
	signin := fmt.Sprintf("v=1 t=%d ev=signin ms=1200+300+10+5000+1", now-20*3600)
	sweep := fmt.Sprintf("v=1 t=%d ev=sweep apps=12 ok=11 fail=1 ms=90000", now-19*3600)
	daySummaryAppend("67", signin)
	daySummaryAppend("67", sweep)
	var saves []string
	for i := 0; i < 400; i++ {
		l := fmt.Sprintf("v=1 t=%d ev=save ms=%d rc=ok kib=%d", now-18*3600+int64(i)*150, 10000+i*37, 100+i)
		saves = append(saves, l)
		daySummaryAppend("67", l)
	}
	got := dsRead(t, daySummaryPath("67"))
	if len(got) > daySummaryMaxBytes {
		t.Fatalf("file is %d bytes, want at most %d", len(got), daySummaryMaxBytes)
	}
	si, wi := strings.Index(got, signin+"\n"), strings.Index(got, sweep+"\n")
	if si < 0 {
		t.Error("the signin line was dropped")
	}
	if wi < 0 {
		t.Error("the sweep line was dropped")
	}
	if fi := strings.Index(got, " ev=save "); si >= 0 && wi >= 0 && !(si < wi && wi < fi) {
		t.Errorf("file order: signin at %d, sweep at %d, first save at %d; want signin < sweep < saves", si, wi, fi)
	}
	if strings.Contains(got, saves[0]+"\n") {
		t.Error("the first save survived the size prune")
	}
	if !strings.HasSuffix(got, saves[len(saves)-1]+"\n") {
		t.Error("the last save is not the file's last line")
	}
	st := daySummaryStatus(daySummaryPath("67"))["day_summary"]
	if st == "unreadable" || !strings.Contains(st, signin) || !strings.Contains(st, sweep) {
		t.Errorf("day_summary (%d bytes) is unreadable or lacks the signin or the sweep", len(st))
	}
}

// NWP-20261202-09: every non-save line has its own 4 KiB budget, oldest first, so a session's own DIAG-EVENT calls
// cannot fill the file; saves then never push the surviving sweeps out.
func TestDaySummaryKeptBudget(t *testing.T) {
	dsSetup(t, "dstest26", "68", 68*100000+10123)
	dsMarkerOn(t, "68")
	now := int64(1800000000)
	keptBytes := func(body string) int {
		n := 0
		for _, l := range strings.Split(strings.TrimSuffix(body, "\n"), "\n") {
			if l != "" && !daySummarySaveRe.MatchString(l) {
				n += len(l) + 1
			}
		}
		return n
	}
	signin := fmt.Sprintf("v=1 t=%d ev=signin ms=1200+300+10+5000+1", now-20*3600)
	dsPlant(t, "68", signin+"\n")
	var sweeps []string
	for i := 0; i < 200; i++ {
		l := fmt.Sprintf("v=1 t=%d ev=sweep apps=12 ok=11 fail=1 ms=%d", now-19*3600+int64(i)*60, 100000+i)
		sweeps = append(sweeps, l)
		daySummaryAppend("68", l)
	}
	got := dsRead(t, daySummaryPath("68"))
	if k := keptBytes(got); k > daySummaryKeptMaxBytes || k <= daySummaryKeptMaxBytes-200 {
		t.Fatalf("non-save lines total %d bytes, want at most %d and more than %d", k, daySummaryKeptMaxBytes,
			daySummaryKeptMaxBytes-200)
	}
	if strings.Contains(got, signin+"\n") {
		t.Error("the signin line (the oldest kept line) survived the kept budget")
	}
	if strings.Contains(got, sweeps[0]+"\n") {
		t.Error("the oldest sweep survived the kept budget")
	}
	if !strings.HasSuffix(got, sweeps[len(sweeps)-1]+"\n") {
		t.Fatal("the newest sweep is not the file's last line")
	}
	k := len(sweeps) - 1
	for k > 0 && strings.Contains(got, sweeps[k-1]+"\n") {
		k--
	}
	if want := strings.Join(sweeps[k:], "\n") + "\n"; got != want {
		t.Fatalf("the survivors are not the newest sweeps in order: file %q, want %q", got, want)
	}
	kept := sweeps[k:]
	var last string
	for i := 0; i < 300; i++ {
		last = fmt.Sprintf("v=1 t=%d ev=save ms=%d rc=ok kib=%d", now-10*3600+int64(i)*60, 10000+i, 100+i)
		daySummaryAppend("68", last)
	}
	got = dsRead(t, daySummaryPath("68"))
	for _, l := range kept {
		if !strings.Contains(got, l+"\n") {
			t.Errorf("a surviving sweep was pushed out by saves: %q", l)
		}
	}
	if len(got) > daySummaryMaxBytes {
		t.Fatalf("file is %d bytes, want at most %d", len(got), daySummaryMaxBytes)
	}
	if !strings.HasSuffix(got, last+"\n") {
		t.Error("the last save is not the file's last line")
	}
	if daySummaryStatus(daySummaryPath("68"))["day_summary"] == "unreadable" {
		t.Error("the writer's own pruned file reads as unreadable")
	}
}

func TestDaySummaryCallerCheck(t *testing.T) {
	for label, peer := range map[string]int{
		"user 0 (the gate)":    10123,
		"root":                 0,
		"system":               1000,
		"another user":         46*100000 + 10123,
		"a failed peer read":   -1,
		"a user whose id ends": 450*100000 + 10123,
	} {
		t.Run(label, func(t *testing.T) {
			t.Setenv("GATEWAY_URL", dsBeta)
			dest := dsSetup(t, "dstest05", "45", peer)
			t.Setenv("GATEWAY_URL", dsBeta)
			for _, v := range [][2]string{{"DIAG-SUMMARY", "status"}, {"DIAG-SUMMARY", "on"}, {"DIAG-EVENT", "sweep 1 1 0 5"}} {
				if got := dsVerb(t, dest, v[0], v[1]); got != "DENIED\n" {
					t.Errorf("%s %s from %s: %q, want DENIED", v[0], v[1], label, got)
				}
			}
			if dsExists(daySummaryMarker("45")) || dsExists(daySummaryPath("45")) {
				t.Errorf("%s: a refused caller left a file", label)
			}
		})
	}
	t.Run("the session user", func(t *testing.T) {
		dest := dsSetup(t, "dstest05b", "45", 45*100000+10123)
		if got := dsVerb(t, dest, "DIAG-SUMMARY", "status"); got != "OFFERED 0 ON 0\n" {
			t.Errorf("status from the session user: %q", got)
		}
	})
	t.Run("no session", func(t *testing.T) {
		dest := dsSetup(t, "dstest05c", "", 45*100000+10123)
		if got := dsVerb(t, dest, "DIAG-SUMMARY", "status"); got != "DENIED\n" {
			t.Errorf("status with no session: %q, want DENIED", got)
		}
	})
}

func TestDaySummaryOnNotBeta(t *testing.T) {
	dest := dsSetup(t, "dstest06", "46", 46*100000+10123)
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("NOWHERE_GATEWAY_DEFAULT", dsBeta)
	if got := dsVerb(t, dest, "DIAG-SUMMARY", "on"); got != "ERR-NOT-BETA\n" {
		t.Errorf("on with only the baked default: %q, want ERR-NOT-BETA", got)
	}
	if dsExists(daySummaryMarker("46")) || dsExists(daySummaryPath("46")) {
		t.Error("a refused on left a file")
	}
	if got := dsVerb(t, dest, "DIAG-SUMMARY", "status"); got != "OFFERED 0 ON 0\n" {
		t.Errorf("status: %q, want OFFERED 0 ON 0", got)
	}
}

func TestDaySummaryOnProd(t *testing.T) {
	dest := dsSetup(t, "dstest07", "47", 47*100000+10123)
	t.Setenv("NOWHERE_GATEWAY_DEFAULT", dsBeta)
	for _, g := range []string{
		"https://api.nowhere.mobile",
		"https://api-beta.nowhere.mobile.evil.example",
		"https://evil.example/api-beta.nowhere.mobile",
		"https://api-beta.nowhere.mobile:8443",
		"http://api-beta.nowhere.mobile",
		"https://minio.home.example:9000",
	} {
		t.Setenv("GATEWAY_URL", g)
		if got := dsVerb(t, dest, "DIAG-SUMMARY", "on"); got != "ERR-NOT-BETA\n" {
			t.Errorf("on with GATEWAY_URL=%s: %q, want ERR-NOT-BETA", g, got)
		}
		if dsExists(daySummaryMarker("47")) {
			t.Errorf("GATEWAY_URL=%s: the marker was created", g)
		}
	}
}

func TestDaySummaryOnBeta(t *testing.T) {
	dest := dsSetup(t, "dstest08", "48", 48*100000+10123)
	t.Setenv("GATEWAY_URL", dsBeta)
	sig := filepath.Join(loginStateDir(), signinSummaryPrefix+"48")
	if err := os.WriteFile(sig, []byte("v=1 scope=vault ms=1500 chunks=3 cached=1 fetched=2 heal_ms=0 store_reads=3 cap_calls=1\n"+
		"v=1 scope=media ms=2500 chunks=3 cached=1 fetched=2 heal_ms=0 store_reads=3 cap_calls=1 indexed=0\n"+
		"v=1 scope=sys ms=40 chunks=1 cached=1 fetched=0 heal_ms=0 store_reads=1 cap_calls=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := dsVerb(t, dest, "DIAG-SUMMARY", "on"); got != "OK\n" {
		t.Fatalf("on with the beta GATEWAY_URL: %q, want OK", got)
	}
	if !dsExists(daySummaryMarker("48")) {
		t.Fatal("no marker after on")
	}
	if got, want := dsRead(t, daySummaryPath("48")), "v=1 t=1800000000 ev=signin ms=1500+-+2500+-+40\n"; got != want {
		t.Errorf("the seeded file %q, want %q", got, want)
	}
	// A second on keeps the file it has.
	daySummaryAppend("48", "v=1 t=1800000000 ev=save ms=5 rc=ok")
	if got := dsVerb(t, dest, "DIAG-SUMMARY", "on"); got != "OK\n" {
		t.Fatalf("second on: %q", got)
	}
	if got := dsRead(t, daySummaryPath("48")); strings.Count(got, "\n") != 2 {
		t.Errorf("a second on re-seeded the file: %q", got)
	}
	if got := dsVerb(t, dest, "DIAG-SUMMARY", "status"); got != "OFFERED 1 ON 1\n" {
		t.Errorf("status: %q, want OFFERED 1 ON 1", got)
	}
	if got := dsVerb(t, dest, "DIAG-SUMMARY", "maybe"); got != "ERR-ARGS\n" {
		t.Errorf("an unknown argument: %q, want ERR-ARGS", got)
	}
}

func TestDaySummaryOff(t *testing.T) {
	dest := dsSetup(t, "dstest09", "49", 49*100000+10123)
	t.Setenv("GATEWAY_URL", dsBeta)
	if got := dsVerb(t, dest, "DIAG-SUMMARY", "on"); got != "OK\n" {
		t.Fatalf("on: %q", got)
	}
	if got := dsVerb(t, dest, "DIAG-SUMMARY", "off"); got != "OK\n" {
		t.Fatalf("off: %q", got)
	}
	if dsExists(daySummaryMarker("49")) || dsExists(daySummaryPath("49")) {
		t.Error("off left the marker or the file")
	}
}

func TestDaySummaryEventJunkRefused(t *testing.T) {
	dest := dsSetup(t, "dstest10", "50", 50*100000+10123)
	dsMarkerOn(t, "50")
	for _, a := range []string{"sweep 1 2 3", "sweep 1 2 3 4 5", "sweep a 2 3 4", "sweep 1 2 3 -4", "stop 1 2 3 4",
		"", "sweep 1 2 3 4 ", " sweep 1 2 3 4", "sweep 1  2 3 4", "sweep 1 2 3 com.example.app", "sweep 1 2 3 1234567890123"} {
		if got := dsVerb(t, dest, "DIAG-EVENT", a); got != "ERR-ARGS\n" {
			t.Errorf("DIAG-EVENT %q: %q, want ERR-ARGS", a, got)
		}
	}
	if dsExists(daySummaryPath("50")) {
		t.Fatalf("a refused event wrote %q", dsRead(t, daySummaryPath("50")))
	}
	if got := dsVerb(t, dest, "DIAG-EVENT", "sweep 5 4 1 900"); got != "OK\n" {
		t.Fatalf("a good event: %q", got)
	}
	if got, want := dsRead(t, daySummaryPath("50")), "v=1 t=1800000000 ev=sweep apps=5 ok=4 fail=1 ms=900\n"; got != want {
		t.Errorf("the sweep line %q, want %q", got, want)
	}
	// Without the marker, a good event answers OK and writes nothing.
	dest2 := dsSetup(t, "dstest10b", "51", 51*100000+10123)
	if got := dsVerb(t, dest2, "DIAG-EVENT", "sweep 5 4 1 900"); got != "OK\n" || dsExists(daySummaryPath("51")) {
		t.Errorf("an event with no marker: %q, file %v", got, dsExists(daySummaryPath("51")))
	}
}

func TestDaySummarySaveMarkerAbsent(t *testing.T) {
	dest := dsSetup(t, "dstest11", "52", 52*100000+10123)
	out := "OK 52"
	daySummaryRecordSave("out", "periodic", "52", dest, time.Now().Round(0), &out)
	daySummaryRecordSave("out", "manual", "52", dest, time.Now().Round(0), &out)
	if dsExists(daySummaryPath("52")) {
		t.Fatalf("a save with no marker wrote %q", dsRead(t, daySummaryPath("52")))
	}
}

func TestDaySummarySaveRC(t *testing.T) {
	dest := dsSetup(t, "dstest12", "53", 53*100000+10123)
	dsMarkerOn(t, "53")
	for out, want := range map[string]string{
		"OK 53":                         "ok",
		"OK":                            "ok",
		"OK 53 PARTIAL:de=refused":      "partial",
		"ERR-REFUSED":                   "refused",
		"ERR-REFUSED PARTIAL:media=err": "refused",
		"ERR-TIMEOUT":                   "timeout",
		workerBusy:                      "busy",
		"ERR-LANE":                      "err",
		"SKIP-SUPERSEDED":               "err",
		"ERR-NOCREDIT":                  "err",
		"OKAY":                          "err",
		"":                              "err",
	} {
		if got := daySummarySaveRC(out); got != want {
			t.Errorf("rc(%q) = %q, want %q", out, got, want)
		}
	}
	saveRe := regexp.MustCompile(`^v=1 t=1800000000 ev=save ms=[0-9]+ rc=refused kib=-$`)
	for _, c := range []struct{ op, intent string }{{"in", "periodic"}, {"out", ""}, {"out", "logout"}, {"sealdelta", "manual"}} {
		out := "ERR-REFUSED"
		daySummaryRecordSave(c.op, c.intent, "53", dest, time.Now().Round(0), &out)
		if dsExists(daySummaryPath("53")) {
			t.Fatalf("op=%s intent=%q wrote a save line", c.op, c.intent)
		}
	}
	for _, intent := range []string{"periodic", "manual"} {
		out := "ERR-REFUSED"
		_ = os.Remove(daySummaryPath("53"))
		daySummaryRecordSave("out", intent, "53", dest, time.Now().Round(0).Add(-1500*time.Millisecond), &out)
		got := strings.TrimSuffix(dsRead(t, daySummaryPath("53")), "\n")
		if !saveRe.MatchString(got) {
			t.Errorf("intent %s: %q, want a refused save line", intent, got)
		}
		var ms int
		fmt.Sscanf(strings.SplitN(got, "ms=", 2)[1], "%d", &ms)
		if ms < 1500 {
			t.Errorf("intent %s: ms=%d, want at least the op's 1500 ms", intent, ms)
		}
	}
}

func TestDaySummaryBusyReturnIsRecorded(t *testing.T) {
	dest := dsSetup(t, "dstest13", "54", 54*100000+10123)
	dsMarkerOn(t, "54")
	resetAbandoned(t, map[string]string{laneRW.svc: "in"})
	prevState := workerState
	pendingReapMu.Lock()
	prevKind := sealRunKind
	sealRunKind = "periodic"
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		workerState = prevState
		pendingReapMu.Lock()
		sealRunKind = prevKind
		pendingReapMu.Unlock()
	})
	workerState = func(string) string { return "running" }
	if got := triggerRoamWorkerKind(dest, "out", "dstest13", "", "54", "", "", "", "periodic", nil); got != workerBusy {
		t.Fatalf("triggerRoamWorkerKind = %q, want %q", got, workerBusy)
	}
	got := dsRead(t, daySummaryPath("54"))
	if !regexp.MustCompile(`(?m)^v=1 t=1800000000 ev=save ms=[0-9]+ rc=busy kib=-\n\z`).MatchString(got) {
		t.Fatalf("after a busy periodic out the file is %q, want one rc=busy save line", got)
	}
	// The same busy return for a session that has not opted in writes nothing.
	_ = os.Remove(daySummaryMarker("54"))
	_ = os.Remove(daySummaryPath("54"))
	if r := triggerRoamWorkerKind(dest, "out", "dstest13", "", "54", "", "", "", "periodic", nil); r != workerBusy {
		t.Fatalf("second call = %q", r)
	}
	if dsExists(daySummaryPath("54")) {
		t.Error("a busy out with the marker absent wrote a line")
	}
}

func TestDaySummaryGateScopeReport(t *testing.T) {
	dsSetup(t, "dstest14", "55", 55*100000+10123)
	line := "v=1 t=1800000000 ev=save ms=7 rc=ok"
	dsPlant(t, "55", line+"\n")
	s := map[string]string{"day_summary": "caller", "day_x": "y", "other": "x"}
	mergeDaySummary(s, "55", true)
	if _, ok := s["day_summary"]; ok || s["day_x"] != "" || s["other"] != "x" || len(s) != 1 {
		t.Errorf("a gate-scope merge: %v, want every day_* key gone and no summary read", s)
	}
	s = map[string]string{"day_summary": "caller", "day_x": "y", "other": "x"}
	mergeDaySummary(s, "55", false)
	if s["day_summary"] != line || s["day_x"] != "" || s["other"] != "x" || len(s) != 2 {
		t.Errorf("a session merge: %v, want day_summary=%q and the caller's day_* keys gone", s, line)
	}
	for _, u := range []string{"", "1a", "../55", "56"} {
		s = map[string]string{"day_summary": "caller"}
		mergeDaySummary(s, u, false)
		if len(s) != 0 {
			t.Errorf("uid %q read a summary: %v", u, s)
		}
	}
	mergeDaySummary(nil, "55", false) // no panic
}

// RF-001: a gate preview through the real handleReportIssue drops caller-sent day_* keys and reads no summary,
// even with a live session whose file is planted.
func TestDaySummaryGatePreviewDropsCallerKeys(t *testing.T) {
	dest := dsSetup(t, "dstest17", "59", 59*100000+10123)
	dsPlant(t, "59", "v=1 t=1800000000 ev=save ms=9 rc=ok\n")
	prevWorker := uiderrorsWorker
	t.Cleanup(func() { uiderrorsWorker = prevWorker })
	uiderrorsWorker = func(string, string, string) string { return "" }
	for _, req := range []string{
		`{"preview":true,"gate":true,"status":{"day_summary":"12345","day_extra":"67890","keepme":"k"}}`,
		`{"preview":true,"status":{"day_summary":"12345","day_extra":"67890","keepme":"k"}}`,
	} {
		c := &dsConn{r: strings.NewReader("")}
		handleReportIssue(c, dest, req)
		out := c.out.String()
		gate := strings.Contains(req, `"gate":true`)
		if strings.Contains(out, "12345") || strings.Contains(out, "67890") || strings.Contains(out, "day_extra") {
			t.Errorf("%s: a caller-sent day_* value survived: %s", req, out)
		}
		if !strings.Contains(out, `"keepme": "k"`) {
			t.Errorf("%s: the preview lost a non-day key: %s", req, out)
		}
		if has := strings.Contains(out, "day_summary"); has == gate {
			t.Errorf("%s: day_summary present=%v, want %v: %s", req, has, !gate, out)
		}
	}
}

func TestDaySummaryForget(t *testing.T) {
	dsSetup(t, "dstest15", "57", 57*100000+10123)
	dsMarkerOn(t, "57")
	daySummaryAppend("57", "v=1 t=1800000000 ev=save ms=1 rc=ok")
	dsMarkerOn(t, "58")
	daySummaryAppend("58", "v=1 t=1800000000 ev=save ms=2 rc=ok")
	daySummaryForget("57")
	if dsExists(daySummaryMarker("57")) || dsExists(daySummaryPath("57")) {
		t.Fatal("forget left a file")
	}
	daySummaryAppend("57", "v=1 t=1800000000 ev=save ms=3 rc=ok")
	if dsExists(daySummaryPath("57")) {
		t.Error("an append after forget wrote a file")
	}
	if !dsExists(daySummaryMarker("58")) || !dsExists(daySummaryPath("58")) {
		t.Error("forget of 57 removed 58's files")
	}
}

func TestDaySummaryBetaHostMatchesRings(t *testing.T) {
	for file, key := range map[string]string{"beta.conf": "GATEWAY_URL", "beta-setup.conf": "NOWHERE_GATEWAY_DEFAULT"} {
		b, err := os.ReadFile(filepath.Join("..", "vendor-common", "etc", "rings", file))
		if err != nil {
			t.Fatal(err)
		}
		var host string
		sc := bufio.NewScanner(bytes.NewReader(b))
		for sc.Scan() {
			l := strings.TrimSpace(sc.Text())
			if v, ok := strings.CutPrefix(l, key+"="); ok {
				u, err := url.Parse(strings.Trim(v, `"'`))
				if err != nil {
					t.Fatalf("%s %s: %v", file, key, err)
				}
				host = u.Host
			}
		}
		if host != daySummaryBetaHost {
			t.Errorf("%s %s host %q, want daySummaryBetaHost %q", file, key, host, daySummaryBetaHost)
		}
	}
}

func TestDaySummarySourcePins(t *testing.T) {
	mainSrc, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	rep, err := os.ReadFile("report_issue.go")
	if err != nil {
		t.Fatal(err)
	}
	m := string(mainSrc)
	if !regexp.MustCompile(`func triggerRoamWorkerKind\([^\n]*\) \(res string\) \{\n\tdefer daySummaryRecordSave\(op, intent, uid, dest, time\.Now\(\)\.Round\(0\), &res\)`).MatchString(m) {
		t.Error("triggerRoamWorkerKind's first statement is not the deferred day-summary writer over its named result")
	}
	if !regexp.MustCompile(`mergeSigninSummary\(rep\.Status, uid, deviceScope\)[^\n]*\n\tmergeDaySummary\(rep\.Status, uid, deviceScope\)`).Match(rep) {
		t.Error("handleReportIssue does not call mergeDaySummary right after mergeSigninSummary")
	}
	i := strings.Index(m, "\nfunc handleLogout(")
	j := strings.Index(m[i+1:], "\nfunc ")
	if i < 0 || j < 0 || !regexp.MustCompile(`(?s)the session ends HERE, where the seal landed.*\n\t+forgetUiderrorsFloor\(dest\)\n.*switch\+reap queued\\n", name, uid\)\n\t+\}\n\t+daySummaryForget\(uid\)`).MatchString(m[i:i+1+j]) {
		t.Error("handleLogout does not forget the day summary at the completed sign-out (after the landed seal's log line)")
	}
	for _, d := range []string{"if name == \"DIAG-SUMMARY\" {\n\t\thandleDiagSummary(conn, r, dest)", "if name == \"DIAG-EVENT\" {\n\t\thandleDiagEvent(conn, r, dest)"} {
		if !strings.Contains(m, d) {
			t.Errorf("handleLogin has no dispatch %q", d)
		}
	}
}

// NWP-20261128-29: the save line's kib is this run's upload KiB from <dest>/seal-split, or "-".

const dsSplitBody = "vault=1200ms/2048KiB,de=300ms/16KiB,media=10ms/0KiB,apps=stage 5ms+push 7ms/4KiB,sys=1ms/1KiB"

// dsSplit writes <dest>/seal-split with the given body and mtime (always set: the kernel's coarse clock can stamp a
// fresh write before a t0 taken just ahead of it).
func dsSplit(t *testing.T, dest, body string, mtime time.Time) {
	t.Helper()
	p := filepath.Join(dest, sealSplitFile)
	if err := os.WriteFile(p, []byte(body+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(p, mtime, mtime); err != nil {
		t.Fatal(err)
	}
}

// dsSave records one periodic save of reply out and returns the summary file.
func dsSave(t *testing.T, dest, uid, out string, t0 time.Time) string {
	t.Helper()
	_ = os.Remove(daySummaryPath(uid))
	daySummaryRecordSave("out", "periodic", uid, dest, t0, &out)
	return dsRead(t, daySummaryPath(uid))
}

func TestDaySummarySaveKiBSum(t *testing.T) {
	dest := dsSetup(t, "dstest18", "60", 60*100000+10123)
	dsMarkerOn(t, "60")
	t0 := time.Now().Round(0)
	dsSplit(t, dest, dsSplitBody, t0.Add(time.Second))
	got := dsSave(t, dest, "60", "OK", t0)
	if !regexp.MustCompile(`^v=1 t=1800000000 ev=save ms=[0-9]+ rc=ok kib=2069\n$`).MatchString(got) {
		t.Fatalf("a fresh split after OK: %q, want one rc=ok kib=2069 save line", got)
	}
}

func TestDaySummarySaveKiBUnknown(t *testing.T) {
	dest := dsSetup(t, "dstest19", "61", 61*100000+10123)
	dsMarkerOn(t, "61")
	t0 := time.Now().Round(0)
	dsSplit(t, dest, strings.Replace(dsSplitBody, "de=300ms/16KiB", "de=300ms/?KiB", 1), t0.Add(time.Second))
	if got := dsSave(t, dest, "61", "OK", t0); !strings.HasSuffix(got, " rc=ok kib=-\n") {
		t.Fatalf("a split with a ?KiB entry: %q, want kib=-", got)
	}
}

func TestDaySummarySaveKiBNoSplit(t *testing.T) {
	dest := dsSetup(t, "dstest20", "62", 62*100000+10123)
	dsMarkerOn(t, "62")
	if got := dsSave(t, dest, "62", "OK", time.Now().Round(0)); !strings.HasSuffix(got, " rc=ok kib=-\n") {
		t.Fatalf("no split file: %q, want kib=-", got)
	}
}

func TestDaySummarySaveKiBNotAVerdict(t *testing.T) {
	dest := dsSetup(t, "dstest21", "63", 63*100000+10123)
	dsMarkerOn(t, "63")
	t0 := time.Now().Round(0)
	dsSplit(t, dest, dsSplitBody, t0.Add(time.Second))
	for out, rc := range map[string]string{"ERR-TIMEOUT": "timeout", workerBusy: "busy", "SKIP-SUPERSEDED": "err"} {
		if got := dsSave(t, dest, "63", out, t0); !strings.HasSuffix(got, " rc="+rc+" kib=-\n") {
			t.Errorf("reply %q with a split present: %q, want rc=%s kib=-", out, got, rc)
		}
	}
	// A verdict roamd's out arm wrote does read it (ERR-NOCREDIT maps to rc=err).
	if got := dsSave(t, dest, "63", "ERR-NOCREDIT", t0); !strings.HasSuffix(got, " rc=err kib=2069\n") {
		t.Errorf("ERR-NOCREDIT with a fresh split: %q, want rc=err kib=2069", got)
	}
}

func TestDaySummarySaveKiBStale(t *testing.T) {
	dest := dsSetup(t, "dstest22", "64", 64*100000+10123)
	dsMarkerOn(t, "64")
	t0 := time.Now().Round(0)
	dsSplit(t, dest, dsSplitBody, t0.Add(-time.Hour))
	if got := dsSave(t, dest, "64", "OK", t0); !strings.HasSuffix(got, " rc=ok kib=-\n") {
		t.Fatalf("a split older than the op: %q, want kib=-", got)
	}
}

func TestDaySummarySaveKiBShapes(t *testing.T) {
	dsSetup(t, "dstest23", "", 0)
	for _, l := range []string{
		"v=1 t=1 ev=save ms=1 rc=ok kib=2069",
		"v=1 t=1 ev=save ms=1 rc=busy kib=-",
		"v=1 t=1 ev=save ms=1 rc=ok kib=999999999999999",
		"v=1 t=1 ev=save ms=1 rc=ok",
	} {
		if _, ok := daySummaryLineT(l); !ok {
			t.Errorf("%q does not read", l)
		}
	}
	for _, l := range []string{
		"v=1 t=1 ev=save ms=1 rc=ok kib=12x",
		"v=1 t=1 ev=save ms=1 rc=ok kib=",
		"v=1 t=1 ev=save ms=1 rc=ok kib=1 x=1",
		"v=1 t=1 ev=save ms=1 rc=ok kib=-1",
		"v=1 t=1 ev=save ms=1 rc=ok kib=1000000000000000",
		"v=1 t=1 ev=save ms=1 rc=ok x=1",
	} {
		if _, ok := daySummaryLineT(l); ok {
			t.Errorf("%q reads", l)
		}
		p := filepath.Join(loginStateDir(), "day-summary.kib")
		if err := os.WriteFile(p, []byte("v=1 t=1 ev=save ms=1 rc=ok kib=1\n"+l+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := daySummaryStatus(p); len(got) != 1 || got["day_summary"] != "unreadable" {
			t.Errorf("%q: %v, want day_summary=unreadable alone", l, got)
		}
	}
	if _, ok := sealSplitKiB(""); ok {
		t.Error("an empty split sums")
	}
	if n, ok := sealSplitKiB(dsSplitBody); !ok || n != 2069 {
		t.Errorf("sealSplitKiB = %d %v, want 2069", n, ok)
	}
	if _, ok := sealSplitKiB("vault=1ms/999999999999999KiB,de=1ms/1KiB"); ok {
		t.Error("a sum over 15 digits sums")
	}
}

func TestDaySummarySaveKiBNotTaken(t *testing.T) {
	dest := dsSetup(t, "dstest24", "66", 66*100000+10123)
	dsMarkerOn(t, "66")
	t0 := time.Now().Round(0)
	dsSplit(t, dest, dsSplitBody, t0.Add(time.Second))
	if got := dsSave(t, dest, "66", "OK", t0); !strings.HasSuffix(got, " kib=2069\n") {
		t.Fatalf("the record: %q, want kib=2069", got)
	}
	if got := dsRead(t, filepath.Join(dest, sealSplitFile)); got != dsSplitBody+"\n" {
		t.Fatalf("after the record the split file is %q, want it untouched (syncLoop's take removes it)", got)
	}
}

// NWP-20261202-11: every REPORT-ISSUE the agent sends at session scope adds a report line (the caller's report_kind
// and the reply's class, no ticket) after its reply, so the NEXT report shows whether a scheduled report reached the
// agent and how the gateway answered.

// dsReportGateway starts a fake gateway that answers POST /support with status and body, and records every POSTed
// report. It sets GATEWAY_URL to it (after dsSetup, which clears it) and stubs the two RO-lane workers.
func dsReportGateway(t *testing.T, status int, body string) *[]issueReport {
	t.Helper()
	var got []issueReport
	gw := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		var rep issueReport
		if err := json.Unmarshal(b, &rep); err != nil {
			t.Errorf("gateway: bad report body: %v", err)
		}
		got = append(got, rep)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(gw.Close)
	t.Setenv("GATEWAY_URL", gw.URL)
	dsReportWorkers(t)
	return &got
}

// dsReportWorkers gives the test its own NOWHERE_DIR and stubs the RO-lane workers (each would wait up to 15 s).
func dsReportWorkers(t *testing.T) {
	t.Helper()
	t.Setenv("NOWHERE_DIR", t.TempDir())
	prevU, prevG := uiderrorsWorker, gmsStateWorker
	t.Cleanup(func() { uiderrorsWorker, gmsStateWorker = prevU, prevG })
	uiderrorsWorker = func(string, string, string) string { return "" }
	gmsStateWorker = func(string, string, string) string { return "" }
}

// dsReport drives the real handleReportIssue with one request line and returns its reply.
func dsReport(dest, req string) string {
	c := &dsConn{r: strings.NewReader("")}
	handleReportIssue(c, dest, req)
	return c.out.String()
}

func TestDaySummaryReportShapeRoundTrip(t *testing.T) {
	dsSetup(t, "dstest31", "81", 81*100000+10123)
	dsMarkerOn(t, "81")
	lines := []string{
		"v=1 t=1800000000 ev=report kind=scheduled rc=ok",
		"v=1 t=1800000000 ev=report kind=by_hand rc=net",
		"v=1 t=1800000000 ev=report kind=none rc=nogw",
		"v=1 t=1800000000 ev=report kind=scheduled rc=toobig",
		"v=1 t=1800000000 ev=report kind=scheduled rc=disabled",
		"v=1 t=1800000000 ev=report kind=by_hand rc=http",
	}
	dsPlant(t, "81", lines[0]+"\n")
	if got := daySummaryStatus(daySummaryPath("81")); got["day_summary"] != lines[0] {
		t.Fatalf("a file of one report line: %v, want day_summary=%q (not unreadable)", got, lines[0])
	}
	for _, l := range lines[1:] {
		daySummaryAppend("81", l)
	}
	if got, want := dsRead(t, daySummaryPath("81")), strings.Join(lines, "\n")+"\n"; got != want {
		t.Fatalf("the prune dropped a report line: file %q, want %q", got, want)
	}
	if got := daySummaryStatus(daySummaryPath("81")); len(got) != 1 || got["day_summary"] != strings.Join(lines, ";") {
		t.Fatalf("status %v, want day_summary=%q", got, strings.Join(lines, ";"))
	}
	for _, bad := range []string{
		"v=1 t=1 ev=report kind=other rc=ok",
		"v=1 t=1 ev=report kind=scheduled rc=ok ticket=NW-1",
		"v=1 t=1 ev=report kind=scheduled rc=okNW-0123456789ab",
	} {
		dsPlant(t, "81", bad+"\n")
		if got := daySummaryStatus(daySummaryPath("81")); got["day_summary"] != "unreadable" {
			t.Errorf("%q read as %v, want unreadable", bad, got)
		}
	}
}

func TestDaySummaryReportKind(t *testing.T) {
	for in, want := range map[string]string{
		"scheduled": "scheduled", "by_hand": "by_hand", "junk": "none", "Scheduled": "none", "": "none", "by_hand ": "none",
	} {
		if got := daySummaryReportKind(in); got != want {
			t.Errorf("daySummaryReportKind(%q) = %q, want %q", in, got, want)
		}
	}
	if got := daySummaryReportKind(map[string]string(nil)["report_kind"]); got != "none" {
		t.Errorf("an absent report_kind = %q, want none", got)
	}
}

func TestDaySummaryReportRC(t *testing.T) {
	word := regexp.MustCompile(`^(ok|net|nogw|toobig|disabled|http)$`)
	for in, want := range map[string]string{
		"OK NW-0123456789ab": "ok", "OK 12345678": "ok", "OK ": "ok", "OK": "ok",
		"ERR-NET": "net", "ERR-NOGW": "nogw", "ERR-TOOBIG": "toobig", "ERR-DISABLED": "disabled",
		"ERR 503": "http", "ERR 500": "http", "ERR 401": "http",
	} {
		got := daySummaryReportRC(in)
		if got != want {
			t.Errorf("daySummaryReportRC(%q) = %q, want %q", in, got, want)
		}
		if !word.MatchString(got) {
			t.Errorf("daySummaryReportRC(%q) = %q, not a word the report shape accepts", in, got)
		}
		if strings.ContainsAny(got, "0123456789") {
			t.Errorf("daySummaryReportRC(%q) = %q kept a digit of the ticket or code", in, got)
		}
	}
}

func TestDaySummaryReportRecordDeviceScope(t *testing.T) {
	dsSetup(t, "dstest32", "82", 82*100000+10123)
	dsMarkerOn(t, "82")
	daySummaryRecordReport("82", true, "scheduled", "ok")
	if dsExists(daySummaryPath("82")) {
		t.Fatal("a device-scope record wrote a line")
	}
	daySummaryRecordReport("82", false, "scheduled", "ok")
	if got, want := dsRead(t, daySummaryPath("82")), "v=1 t=1800000000 ev=report kind=scheduled rc=ok\n"; got != want {
		t.Errorf("a session record: file %q, want %q", got, want)
	}
}

func TestDaySummaryReportSendOK(t *testing.T) {
	dest := dsSetup(t, "dstest33", "83", 83*100000+10123)
	dsMarkerOn(t, "83")
	dsReportGateway(t, http.StatusOK, `{"ticket":"NW-0123456789ab"}`)
	if got := dsReport(dest, `{"note":"t","status":{"report_kind":"scheduled"}}`); got != "OK NW-0123456789ab\n" {
		t.Fatalf("reply %q, want OK NW-0123456789ab", got)
	}
	f := dsRead(t, daySummaryPath("83"))
	if f != "v=1 t=1800000000 ev=report kind=scheduled rc=ok\n" {
		t.Errorf("file %q, want one ev=report kind=scheduled rc=ok line", f)
	}
	if strings.Contains(f, "NW-") || strings.Contains(f, "0123456789ab") {
		t.Errorf("the file holds the ticket: %q", f)
	}
}

func TestDaySummaryReportSend503(t *testing.T) {
	dest := dsSetup(t, "dstest34", "84", 84*100000+10123)
	dsMarkerOn(t, "84")
	dsReportGateway(t, http.StatusServiceUnavailable, `{"error":"support intake full"}`)
	if got := dsReport(dest, `{"note":"t","status":{"report_kind":"by_hand"}}`); got != "ERR 503\n" {
		t.Fatalf("reply %q, want ERR 503", got)
	}
	if got, want := dsRead(t, daySummaryPath("84")), "v=1 t=1800000000 ev=report kind=by_hand rc=http\n"; got != want {
		t.Errorf("file %q, want %q", got, want)
	}
}

func TestDaySummaryReportNoGateway(t *testing.T) {
	dest := dsSetup(t, "dstest35", "85", 85*100000+10123)
	dsMarkerOn(t, "85")
	dsReportWorkers(t)
	if got := dsReport(dest, `{"note":"t"}`); got != "ERR-NOGW\n" {
		t.Fatalf("reply %q, want ERR-NOGW", got)
	}
	if got, want := dsRead(t, daySummaryPath("85")), "v=1 t=1800000000 ev=report kind=none rc=nogw\n"; got != want {
		t.Errorf("file %q, want %q", got, want)
	}
}

func TestDaySummaryReportPreviewWritesNothing(t *testing.T) {
	dest := dsSetup(t, "dstest36", "86", 86*100000+10123)
	dsMarkerOn(t, "86")
	posts := dsReportGateway(t, http.StatusOK, `{"ticket":"NW-0123456789ab"}`)
	if got := dsReport(dest, `{"preview":true,"status":{"report_kind":"scheduled"}}`); !strings.HasPrefix(got, "{") {
		t.Fatalf("preview reply %q, want the report JSON", got)
	}
	if dsExists(daySummaryPath("86")) {
		t.Errorf("a preview wrote a line: %q", dsRead(t, daySummaryPath("86")))
	}
	if len(*posts) != 0 {
		t.Errorf("a preview reached the gateway %d time(s)", len(*posts))
	}
	// The control: the same session's send does write, so the absence above is the preview's.
	dsReport(dest, `{"status":{"report_kind":"scheduled"}}`)
	if got, want := dsRead(t, daySummaryPath("86")), "v=1 t=1800000000 ev=report kind=scheduled rc=ok\n"; got != want {
		t.Errorf("after a preview and a send: file %q, want the send's line alone %q", got, want)
	}
}

func TestDaySummaryReportGateWritesNothing(t *testing.T) {
	dest := dsSetup(t, "dstest37", "87", 87*100000+10123)
	dsMarkerOn(t, "87")
	dsReportGateway(t, http.StatusOK, `{"ticket":"NW-0123456789ab"}`)
	if got := dsReport(dest, `{"gate":true,"status":{"report_kind":"scheduled"}}`); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("gate reply %q, want OK <ticket>", got)
	}
	if dsExists(daySummaryPath("87")) {
		t.Errorf("a gate report with a live session wrote a line: %q", dsRead(t, daySummaryPath("87")))
	}
	// The control: the same request without gate does write, so the absence above is the gate's.
	dsReport(dest, `{"status":{"report_kind":"scheduled"}}`)
	if got, want := dsRead(t, daySummaryPath("87")), "v=1 t=1800000000 ev=report kind=scheduled rc=ok\n"; got != want {
		t.Errorf("after a gate report and a session report: file %q, want the session report's line alone %q", got, want)
	}
}

func TestDaySummaryReportNoMarkerWritesNothing(t *testing.T) {
	dest := dsSetup(t, "dstest38", "88", 88*100000+10123)
	dsReportGateway(t, http.StatusOK, `{"ticket":"NW-0123456789ab"}`)
	if got := dsReport(dest, `{"note":"t","status":{"report_kind":"scheduled"}}`); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("reply %q, want OK <ticket>", got)
	}
	if dsExists(daySummaryPath("88")) {
		t.Errorf("a session that has not opted in wrote a line: %q", dsRead(t, daySummaryPath("88")))
	}
	// The control: once the marker exists the same request writes, so the absence above is the marker's.
	dsMarkerOn(t, "88")
	dsReport(dest, `{"note":"t","status":{"report_kind":"scheduled"}}`)
	if got, want := dsRead(t, daySummaryPath("88")), "v=1 t=1800000000 ev=report kind=scheduled rc=ok\n"; got != want {
		t.Errorf("after opting in: file %q, want %q", got, want)
	}
}

func TestDaySummaryReportShowsInNextReport(t *testing.T) {
	dest := dsSetup(t, "dstest39", "89", 89*100000+10123)
	dsMarkerOn(t, "89")
	posts := dsReportGateway(t, http.StatusOK, `{"ticket":"NW-0123456789ab"}`)
	if got := dsReport(dest, `{"note":"t","status":{"report_kind":"scheduled"}}`); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("first reply %q, want OK <ticket>", got)
	}
	if got := dsReport(dest, `{"note":"t","status":{"report_kind":"by_hand"}}`); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("second reply %q, want OK <ticket>", got)
	}
	if len(*posts) != 2 {
		t.Fatalf("the gateway got %d report(s), want 2", len(*posts))
	}
	line := "v=1 t=1800000000 ev=report kind=scheduled rc=ok"
	if ds := (*posts)[0].Status["day_summary"]; strings.Contains(ds, "ev=report") {
		t.Errorf("the first report carries its own report line: %q", ds)
	}
	if ds := (*posts)[1].Status["day_summary"]; ds != line {
		t.Errorf("the second report's day_summary %q, want %q (the first report's line)", ds, line)
	}
}
