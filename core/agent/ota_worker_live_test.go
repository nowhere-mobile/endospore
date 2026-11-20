package main

// NWP-20261206-12: the backlog row "The Update card shows Install update again while an update is installing, and
// lets it be tapped again". An empty init.svc.nowhere_otad read (a property the domain may not read) is UNKNOWN,
// not a dead worker; OTA-APPLY answers BUSY while otad runs; an absent ota.res reads DOWNLOADING while otad runs;
// and every issue report carries the daemon's own ota_install / ota_res_age_s / ota_otad_svc.
// test-ota-worker-live.sh mutates the code these pin and requires a `--- FAIL` for each mutant.

import (
	"bufio"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// owlSvc stubs the init.svc.nowhere_otad read for one test and restores it after.
func owlSvc(t *testing.T, s string, err error) {
	t.Helper()
	prev := otadSvcState
	t.Cleanup(func() { otadSvcState = prev })
	otadSvcState = func() (string, error) { return s, err }
}

// owlWrite writes dest/name with body and sets its mtime age ago.
func owlWrite(t *testing.T, dest, name, body string, age time.Duration) {
	t.Helper()
	p := filepath.Join(dest, name)
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	at := time.Now().Add(-age)
	if err := os.Chtimes(p, at, at); err != nil {
		t.Fatal(err)
	}
}

func TestOtaWorkerLiveEmptyReadFresh(t *testing.T) {
	owlSvc(t, "", nil)
	// (a) ota.res aged 5 min (past the 20 s grace), ota.prog fresh.
	a := t.TempDir()
	owlWrite(t, a, "ota.res", "APPLYING 0.6.0\n", 5*time.Minute)
	owlWrite(t, a, "ota.prog", "osapply 10 100\n", 0)
	if got := otaResState(a); got != "APPLYING 0.6.0" {
		t.Errorf("(a) empty svc read, ota.res 5 min, ota.prog fresh: otaResState = %q, want %q", got, "APPLYING 0.6.0")
	}
	// (b) ota.res aged 1 min, no ota.prog.
	b := t.TempDir()
	owlWrite(t, b, "ota.res", "APPLYING 0.6.0\n", time.Minute)
	if got := otaResState(b); got != "APPLYING 0.6.0" {
		t.Errorf("(b) empty svc read, ota.res 1 min, no ota.prog: otaResState = %q, want %q", got, "APPLYING 0.6.0")
	}
	// (c) ota.res aged 11 min (outside otaLiveWindow), ota.prog fresh: only ota.prog keeps it live.
	c := t.TempDir()
	owlWrite(t, c, "ota.res", "APPLYING 0.6.0\n", 11*time.Minute)
	owlWrite(t, c, "ota.prog", "osapply 20 100\n", 0)
	if got := otaResState(c); got != "APPLYING 0.6.0" {
		t.Errorf("(c) empty svc read, ota.res 11 min, ota.prog fresh: otaResState = %q, want %q", got, "APPLYING 0.6.0")
	}
}

func TestOtaWorkerLiveEmptyReadStale(t *testing.T) {
	owlSvc(t, "", nil)
	d := t.TempDir()
	owlWrite(t, d, "ota.res", "APPLYING 0.6.0\n", 11*time.Minute)
	owlWrite(t, d, "ota.prog", "osapply 20 100\n", 11*time.Minute)
	if got := otaResState(d); got != "FAILED ERR-STALE" {
		t.Errorf("empty svc read, ota.res and ota.prog 11 min old: otaResState = %q, want %q (#23)", got, "FAILED ERR-STALE")
	}
}

func TestOtaWorkerDeadStopped(t *testing.T) {
	d := t.TempDir()
	owlWrite(t, d, "ota.res", "APPLYING 0.6.0\n", 5*time.Minute)
	owlWrite(t, d, "ota.prog", "osapply 20 100\n", 0)
	owlSvc(t, "stopped", nil)
	if got := otaResState(d); got != "FAILED ERR-STALE" {
		t.Errorf("stopped leg: svc stopped, ota.prog fresh: otaResState = %q, want %q", got, "FAILED ERR-STALE")
	}
	owlSvc(t, "running", nil)
	if got := otaResState(d); got != "APPLYING 0.6.0" {
		t.Errorf("running leg: svc running: otaResState = %q, want %q", got, "APPLYING 0.6.0")
	}
}

func TestOtaResStateAbsentWhileOtadRuns(t *testing.T) {
	d := t.TempDir()
	owlSvc(t, "running", nil)
	if got := otaResState(d); got != "DOWNLOADING" {
		t.Errorf("running leg: no ota.res, svc running: otaResState = %q, want %q", got, "DOWNLOADING")
	}
	owlSvc(t, "stopped", nil)
	if got := otaResState(d); got != "" {
		t.Errorf("stopped leg: no ota.res, svc stopped: otaResState = %q, want \"\"", got)
	}
	owlWrite(t, d, "ota.res", "UPTODATE 0.6.0\n", time.Minute)
	owlSvc(t, "running", nil)
	if got := otaResState(d); got != "" {
		t.Errorf("UPTODATE leg: ota.res UPTODATE, svc running: otaResState = %q, want \"\"", got)
	}
}

// owlApply runs handleOtaApply over a net.Pipe and returns its one-line reply.
func owlApply(t *testing.T, dest string) string {
	t.Helper()
	srv, cli := net.Pipe()
	defer cli.Close()
	go func() {
		defer srv.Close()
		handleOtaApply(srv, dest)
	}()
	cli.SetDeadline(time.Now().Add(10 * time.Second))
	line, err := bufio.NewReader(cli).ReadString('\n')
	if err != nil {
		t.Fatalf("OTA-APPLY reply: %v", err)
	}
	return strings.TrimSpace(line)
}

func TestOtaApplyBusyWhileOtadRuns(t *testing.T) {
	d := t.TempDir()
	res := filepath.Join(d, "ota.res")
	owlWrite(t, d, "ota.res", "ERR-APPLY\n", 5*time.Minute)
	before, err := os.Stat(res)
	if err != nil {
		t.Fatal(err)
	}
	owlSvc(t, "running", nil)
	if got := owlApply(t, d); got != "BUSY" {
		t.Errorf("running leg: OTA-APPLY reply = %q, want BUSY", got)
	}
	if b, _ := os.ReadFile(res); string(b) != "ERR-APPLY\n" {
		t.Errorf("running leg: ota.res re-seeded to %q", b)
	}
	if fi, err := os.Stat(res); err != nil || !fi.ModTime().Equal(before.ModTime()) {
		t.Errorf("running leg: ota.res mtime changed (err %v)", err)
	}
	if _, err := os.Stat(filepath.Join(d, "ota.req")); err == nil {
		t.Error("running leg: OTA-APPLY wrote ota.req while otad runs")
	}
	// stopped: the old path (the host has no setprop; its exec error is ignored).
	owlSvc(t, "stopped", nil)
	if got := owlApply(t, d); got != "OK" {
		t.Errorf("stopped leg: OTA-APPLY reply = %q, want OK", got)
	}
	if b, _ := os.ReadFile(res); string(b) != "STAGING\n" {
		t.Errorf("stopped leg: ota.res = %q, want STAGING", b)
	}
	if _, err := os.Stat(filepath.Join(d, "ota.req")); err != nil {
		t.Errorf("stopped leg: no ota.req: %v", err)
	}
}

func TestOtaInstallMarker(t *testing.T) {
	// APPLYING, fresh ota.res, svc running.
	d := t.TempDir()
	owlWrite(t, d, "ota.res", "APPLYING 0.6.0\n", 0)
	owlSvc(t, "running", nil)
	m := otaInstallMarker(d)
	if m["ota_install"] != "APPLYING_0.6.0" || m["ota_otad_svc"] != "running" {
		t.Errorf("APPLYING: marker = %v", m)
	}
	if n, err := strconv.Atoi(m["ota_res_age_s"]); err != nil || n < 0 || n > 5 {
		t.Errorf("APPLYING: ota_res_age_s = %q, want 0..5", m["ota_res_age_s"])
	}
	// Absent ota.res, svc stopped.
	e := t.TempDir()
	owlSvc(t, "stopped", nil)
	m = otaInstallMarker(e)
	if m["ota_install"] != "none" || m["ota_res_age_s"] != "-1" || m["ota_otad_svc"] != "stopped" {
		t.Errorf("absent: marker = %v, want none/-1/stopped", m)
	}
	// Every service class; the raw value never appears.
	for _, c := range []struct {
		s    string
		err  error
		want string
	}{
		{"running", nil, "running"},
		{"stopping", nil, "stopping"},
		{"restarting", nil, "restarting"},
		{"stopped", nil, "stopped"},
		{"", nil, "empty"},
		{"", errors.New("no getprop"), "error"},
		{"weird", nil, "other"},
	} {
		owlSvc(t, c.s, c.err)
		m := otaInstallMarker(e)
		if m["ota_otad_svc"] != c.want {
			t.Errorf("svc (%q, %v): ota_otad_svc = %q, want %q", c.s, c.err, m["ota_otad_svc"], c.want)
		}
		for k, v := range m {
			if strings.Contains(v, "weird") {
				t.Errorf("svc %q: %s carries the raw read %q", c.s, k, v)
			}
		}
	}
	// A gate preview: the daemon's keys win over chooser-sent ones of the same name.
	prevWorker := uiderrorsWorker
	t.Cleanup(func() { uiderrorsWorker = prevWorker })
	uiderrorsWorker = func(string, string, string) string { return "" }
	owlSvc(t, "running", nil)
	c := &dsConn{r: strings.NewReader("")}
	handleReportIssue(c, d, `{"preview":true,"gate":true,"status":{"ota_install":"FAKE_VALUE","ota_otad_svc":"FAKE_SVC"}}`)
	var rep struct {
		Status map[string]string `json:"status"`
	}
	if err := json.Unmarshal(c.out.Bytes(), &rep); err != nil {
		t.Fatalf("preview reply: %v: %s", err, c.out.String())
	}
	if rep.Status["ota_install"] != "APPLYING_0.6.0" || rep.Status["ota_otad_svc"] != "running" {
		t.Errorf("preview: ota_install = %q, ota_otad_svc = %q; want the daemon's APPLYING_0.6.0 and running",
			rep.Status["ota_install"], rep.Status["ota_otad_svc"])
	}
	if _, ok := rep.Status["ota_res_age_s"]; !ok {
		t.Error("preview: no ota_res_age_s")
	}
}
