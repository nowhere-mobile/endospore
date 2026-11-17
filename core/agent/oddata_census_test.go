package main

// NWP-20261202-27 (h53 #1, harvest 63 item 7): each RESTORE-ODDATA request that reaches the worker writes one
// `restore-oddata` line to login.log with its form, its phase (signin = before the sign-in's GRANT-PERMS, session =
// after it), its reply counts and its wall time, so an issue report splits the restores by caller. The line names no
// package, no profile and no reply text, and the guards (ERR-PKG, NONE, OK LOCAL) write none.

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// odCensusFake replaces odRestoreWorker. It answers replies[pkg] (default "OK <pkg>"); each, when set, runs inside
// the op for the i-th call (from 1) before it answers.
func odCensusFake(t *testing.T, replies map[string]string, each func(i int, pkg string)) {
	t.Helper()
	bootWakeFakes(t)
	old := odRestoreWorker
	t.Cleanup(func() { odRestoreWorker = old })
	var mu sync.Mutex
	n := 0
	odRestoreWorker = func(dest, op, name, pass, uid, seSecret, kind, srcUnit, intent string, onProg func(string)) string {
		mu.Lock()
		n++
		i := n
		mu.Unlock()
		if each != nil {
			each(i, srcUnit)
		}
		if r, ok := replies[srcUnit]; ok {
			return r + "\n"
		}
		return "OK " + srcUnit + "\n"
	}
}

// odCensusRun serves payload and returns its reply lines and everything the handler wrote to stderr. The capture
// ends only after the handler has returned.
func odCensusRun(t *testing.T, dest, payload string) (lines []string, stderr string) {
	t.Helper()
	stderr = captureStderr(t, func() {
		ch, done := odListServe(dest, payload)
		lines = odListRead(t, ch)
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Fatalf("the handler did not return for %q", payload)
		}
	})
	return lines, stderr
}

// odCensusLines takes the census lines out of a stderr capture.
func odCensusLines(stderr string) []string {
	var got []string
	for _, l := range strings.Split(stderr, "\n") {
		if strings.Contains(l, "restore-oddata user ") {
			got = append(got, l)
		}
	}
	return got
}

var odCensusRe = regexp.MustCompile(`^\[logind\] restore-oddata user (\S+) (form=(?:one|list) n=\d+ phase=(?:signin|session) ran=\d+ ok=\d+ nosrc=\d+ notready=\d+ err=\d+ stopped=\d+) (\d+)ms \(NWP-20261202-27\)$`)

// odCensusOne requires exactly one well-formed census line and returns its uid, its counts (form= to stopped=) and
// its milliseconds.
func odCensusOne(t *testing.T, stderr string) (uid, counts string, ms int64) {
	t.Helper()
	ls := odCensusLines(stderr)
	if len(ls) != 1 {
		t.Fatalf("census lines: got %d %q want exactly 1; stderr %q", len(ls), ls, stderr)
	}
	m := odCensusRe.FindStringSubmatch(ls[0])
	if m == nil {
		t.Fatalf("census line %q does not match %s", ls[0], odCensusRe)
	}
	ms, err := strconv.ParseInt(m[3], 10, 64)
	if err != nil {
		t.Fatalf("census ms %q: %v", m[3], err)
	}
	return m[1], m[2], ms
}

func odCensusWant(t *testing.T, stderr, want string) {
	t.Helper()
	uid, counts, _ := odCensusOne(t, stderr)
	if uid != "11" || counts != want {
		t.Errorf("census: got user %s %q want user 11 %q", uid, counts, want)
	}
}

func TestOddataCensus_OneAtSignin(t *testing.T) {
	dest := t.TempDir()
	odListSession(t, dest, "odcensus-one")
	odCensusFake(t, nil, nil)
	lines, stderr := odCensusRun(t, dest, "org.fossify.math")
	odListEqual(t, "reply", lines, []string{"OK org.fossify.math"})
	odCensusWant(t, stderr, "form=one n=1 phase=signin ran=1 ok=1 nosrc=0 notready=0 err=0 stopped=0")
}

func TestOddataCensus_ListInSession(t *testing.T) {
	dest := t.TempDir()
	odListSession(t, dest, "odcensus-list")
	odCensusFake(t, map[string]string{
		"org.fossify.notes": "OK NOSRC",
		"org.fossify.clock": "ERR-NOTREADY",
		"org.fossify.music": "ERR-FOO",
	}, nil)
	bootWakeGate.arm("11") // after odCensusFake: bootWakeFakes clears the gate at entry and in its Cleanup
	t.Cleanup(bootWakeGate.clear)
	lines, stderr := odCensusRun(t, dest, "org.fossify.math org.fossify.notes org.fossify.clock org.fossify.music")
	odListEqual(t, "reply", lines, []string{
		"org.fossify.math OK org.fossify.math",
		"org.fossify.notes OK NOSRC",
		"org.fossify.clock ERR-NOTREADY",
		"org.fossify.music ERR-FOO",
		"END 4",
	})
	odCensusWant(t, stderr, "form=list n=4 phase=session ran=4 ok=1 nosrc=1 notready=1 err=1 stopped=0")
}

func TestOddataCensus_PhaseReadOnce(t *testing.T) {
	dest := t.TempDir()
	odListSession(t, dest, "odcensus-once")
	// GRANT-PERMS lands while op 1 runs: the request started before it, so it stays signin.
	odCensusFake(t, nil, func(i int, pkg string) {
		if i == 1 {
			bootWakeGate.arm("11")
		}
	})
	_, stderr := odCensusRun(t, dest, "org.fossify.math org.fossify.notes")
	odCensusWant(t, stderr, "form=list n=2 phase=signin ran=2 ok=2 nosrc=0 notready=0 err=0 stopped=0")
}

func TestOddataCensus_CancelStops(t *testing.T) {
	dest := t.TempDir()
	odListSession(t, dest, "odcensus-cancel")
	odCensusFake(t, nil, func(i int, pkg string) {
		if i == 1 {
			if err := os.WriteFile(filepath.Join(dest, odCancelFile), nil, 0o600); err != nil {
				t.Error(err)
			}
		}
	})
	lines, stderr := odCensusRun(t, dest, "org.fossify.math org.fossify.notes org.fossify.clock")
	odListEqual(t, "reply", lines, []string{
		"org.fossify.math OK org.fossify.math",
		"org.fossify.notes STOPPED",
		"org.fossify.clock STOPPED",
		"END 1",
	})
	odCensusWant(t, stderr, "form=list n=3 phase=signin ran=1 ok=1 nosrc=0 notready=0 err=0 stopped=2")
}

func TestOddataCensus_GuardsWriteNone(t *testing.T) {
	odCensusFake(t, nil, nil)
	none := t.TempDir() // no session
	local := t.TempDir()
	odListSession(t, local, "odcensus-guards")
	markLocalSession(local)
	for _, c := range []struct{ what, dest, payload, want string }{
		{"one bad name", none, "../x", "ERR-PKG"},
		{"a list with a duplicate", none, "org.fossify.math org.fossify.math", "ERR-PKG"},
		{"one name, no session", none, "org.fossify.math", "NONE"},
		{"a list, no session", none, "org.fossify.math org.fossify.notes", "NONE"},
		{"one name, a local session", local, "org.fossify.math", "OK LOCAL"},
		{"a list, a local session", local, "org.fossify.math org.fossify.notes", "OK LOCAL"},
	} {
		lines, stderr := odCensusRun(t, c.dest, c.payload)
		odListEqual(t, c.what, lines, []string{c.want})
		if ls := odCensusLines(stderr); len(ls) != 0 {
			t.Errorf("%s (%s): a guard wrote census lines %q", c.what, c.want, ls)
		}
	}
	// The control: a request that reaches the worker writes exactly one line.
	dest := t.TempDir()
	odListSession(t, dest, "odcensus-guards")
	_, stderr := odCensusRun(t, dest, "org.fossify.math")
	odCensusOne(t, stderr)
}

func TestOddataCensus_NoNames(t *testing.T) {
	const profile = "odcensus-nonames"
	pkgs := []string{"org.plantone.alpha", "org.planttwo.bravo", "org.plantthree.charlie"}
	for _, payload := range []string{pkgs[0], strings.Join(pkgs, " ")} {
		dest := t.TempDir()
		odListSession(t, dest, profile)
		odCensusFake(t, map[string]string{pkgs[2]: "ERR-NOTREADY " + pkgs[2]}, nil)
		_, stderr := odCensusRun(t, dest, payload)
		odCensusOne(t, stderr)
		line := odCensusLines(stderr)[0]
		for _, p := range append(append([]string(nil), pkgs...), profile, "plant") {
			if strings.Contains(line, p) {
				t.Errorf("payload %q: the census line %q names %q", payload, line, p)
			}
		}
	}
}

func TestOddataCensus_Duration(t *testing.T) {
	dest := t.TempDir()
	odListSession(t, dest, "odcensus-dur")
	odCensusFake(t, nil, func(i int, pkg string) { time.Sleep(30 * time.Millisecond) })
	_, stderr := odCensusRun(t, dest, "org.fossify.math org.fossify.notes")
	if _, _, ms := odCensusOne(t, stderr); ms < 60 {
		t.Errorf("census ms: got %d want >= 60 (two ops of 30 ms each)", ms)
	}
}
