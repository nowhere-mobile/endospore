package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261107-12 (Q037, dn-1104 #2, docs/backlog.md §B, "A reap whose user record never goes, or cannot be seen, now
// KEEPS that user's /data/system/users/<uid>"): while a reap is queued the login daemon sends roamd's credless
// `userdirrecheck` op every 5 minutes. The runtime cases drive the tick against a worker fake that RECORDS each
// request's op; the pins read main.go. None may run in parallel (workerState is package state).

// userdirRecheckDrive sets the tick's flag, resets the abandoned-op state so the RW lane is not in its "(daemon start)"
// state, and starts a recording RW worker over a fresh dest.
func userdirRecheckDrive(t *testing.T, enabled bool) (string, *recordingRWWorker) {
	t.Helper()
	dest := t.TempDir()
	resetAbandoned(t, nil)
	userdirRecheckEnabled = enabled
	t.Cleanup(func() { userdirRecheckEnabled = false })
	rec := startRecordingRWWorker(t, dest, nil)
	return dest, rec
}

func userdirRecheckOps(rec *recordingRWWorker) []string {
	rec.mu.Lock()
	defer rec.mu.Unlock()
	return append([]string(nil), rec.ops...)
}

func TestUserdirRecheck_ATickWithAQueuedUidSendsOneOp(t *testing.T) {
	dest, rec := userdirRecheckDrive(t, true)
	if err := os.WriteFile(filepath.Join(dest, "userdir-pending"), []byte("12\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if !userdirRecheckTick(dest) {
		t.Fatal("a tick with a queued uid reported that it sent nothing")
	}
	if ops := userdirRecheckOps(rec); len(ops) != 1 || ops[0] != "userdirrecheck" {
		t.Errorf("ops sent = %v, want exactly [userdirrecheck]", ops)
	}
}

func TestUserdirRecheck_NothingQueuedSendsNothing(t *testing.T) {
	queued := "12\n"
	empty := ""
	cases := []struct {
		name    string
		enabled bool
		file    *string
	}{
		{"absent", true, nil},
		{"empty", true, &empty},
		{"flag off", false, &queued},
	}
	for _, c := range cases {
		dest, rec := userdirRecheckDrive(t, c.enabled)
		if c.file != nil {
			if err := os.WriteFile(filepath.Join(dest, "userdir-pending"), []byte(*c.file), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		if userdirRecheckTick(dest) {
			t.Errorf("%s: the tick reported a send", c.name)
		}
		if ops := userdirRecheckOps(rec); len(ops) != 0 {
			t.Errorf("%s: ops sent = %v, want none", c.name, ops)
		}
	}
}

func TestUserdirRecheck_IntervalAndWaitCap(t *testing.T) {
	if userdirRecheckEvery != 5*time.Minute {
		t.Errorf("userdirRecheckEvery = %v, want 5m (Q037, dn-1104 #2)", userdirRecheckEvery)
	}
	if got := workerWaitCap("userdirrecheck"); got != 30*time.Second {
		t.Errorf("workerWaitCap(userdirrecheck) = %v, want 30s", got)
	}
}

func TestUserdirRecheck_DaemonStartsTheLoopOnce(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	const start = `goSafeLoop("userdir-recheck loop", func() { userdirRecheckLoop(dest) })`
	if n := strings.Count(src, start); n != 1 {
		t.Fatalf("main.go holds %d starts of the userdir re-check loop, want exactly 1", n)
	}
	from := strings.Index(src, "func loginDaemon(")
	if from < 0 {
		t.Fatal("func loginDaemon( not found in main.go")
	}
	end := strings.Index(src[from+1:], "\nfunc ")
	if at := strings.Index(src, start); at < from || (end >= 0 && at > from+1+end) {
		t.Errorf("the loop start is not inside loginDaemon")
	}
}

func TestUserdirRecheck_RidesTheRWLane(t *testing.T) {
	if laneFor("userdirrecheck").svc != laneRW.svc {
		t.Errorf("userdirrecheck rides lane %q, want the read-write lane %q", laneFor("userdirrecheck").svc, laneRW.svc)
	}
}

// R6: the loop itself. The sleep seam records each wait and how many ops were sent before it, and ends the loop's
// goroutine at its 2nd wait: one full sleep-then-tick turn. A raw go is allowed here: TestEveryGoroutineGoesThroughGoSafe
// scans only non-test files.
func TestUserdirRecheck_TheLoopSleepsThenTicks(t *testing.T) {
	dest, rec := userdirRecheckDrive(t, true)
	if err := os.WriteFile(filepath.Join(dest, "userdir-pending"), []byte("12\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var durs []time.Duration
	var opsAt []int
	old := userdirRecheckSleep
	t.Cleanup(func() { userdirRecheckSleep = old })
	userdirRecheckSleep = func(d time.Duration) {
		n := len(userdirRecheckOps(rec))
		mu.Lock()
		durs = append(durs, d)
		opsAt = append(opsAt, n)
		calls := len(durs)
		mu.Unlock()
		if calls >= 2 {
			runtime.Goexit()
		}
	}
	done := make(chan struct{})
	go func() { defer close(done); userdirRecheckLoop(dest) }()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("userdirRecheckLoop did not reach its 2nd sleep within 10 s")
	}
	mu.Lock()
	defer mu.Unlock()
	if len(durs) != 2 || durs[0] != userdirRecheckEvery || durs[1] != userdirRecheckEvery {
		t.Errorf("the loop slept %v, want [%v %v]", durs, userdirRecheckEvery, userdirRecheckEvery)
	}
	if len(opsAt) == 0 || opsAt[0] != 0 {
		t.Errorf("ops sent before the first sleep = %v, want 0 (the loop sleeps first)", opsAt)
	}
	if ops := userdirRecheckOps(rec); len(ops) != 1 || ops[0] != "userdirrecheck" {
		t.Errorf("ops sent = %v, want exactly [userdirrecheck]", ops)
	}
}
