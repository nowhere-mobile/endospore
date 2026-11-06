package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261027-02 (docs/backlog.md §B, "A failed sign-in left the typed profile name in cleartext in login.log and
// roam.log until the next reap or boot"): the chooser removes a failed sign-in's user with dpm.removeUser, which never
// reaches cleanstorage's log_scrub, so handleRoamIn schedules roamd's `logscrub` op after a BLANK / BLANK NET reply.
// The runtime cases drive the real handleRoamIn over a pipe against a worker fake that RECORDS every request's op; the
// pins read main.go. None may run in parallel (workerState and the login window are package state).

// recordingRWWorker answers the RW lane like rwWorker, answers a logscrub with OK, and records each request's op.
type recordingRWWorker struct {
	mu  sync.Mutex
	ops []string
}

func (r *recordingRWWorker) seen(op string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, o := range r.ops {
		if o == op {
			return true
		}
	}
	return false
}

func startRecordingRWWorker(t *testing.T, dest string, answers map[string]string) *recordingRWWorker {
	t.Helper()
	rec := &recordingRWWorker{}
	done, finished := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(finished)
		for {
			if b, err := os.ReadFile(filepath.Join(dest, laneRW.req)); err == nil && strings.Count(string(b), "\n") >= 7 {
				os.Remove(filepath.Join(dest, laneRW.req))
				op := strings.SplitN(string(b), "\n", 2)[0]
				rec.mu.Lock()
				rec.ops = append(rec.ops, op)
				rec.mu.Unlock()
				ans, ok := answers[op]
				if !ok {
					ans = "OK"
				}
				os.WriteFile(filepath.Join(dest, laneRW.res), []byte(ans+"\n"), 0o600)
			}
			select {
			case <-done:
				return
			case <-time.After(10 * time.Millisecond):
			}
		}
	}()
	t.Cleanup(func() { close(done); <-finished })
	return rec
}

func waitForOp(rec *recordingRWWorker, op string, d time.Duration) bool {
	end := time.Now().Add(d)
	for time.Now().Before(end) {
		if rec.seen(op) {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return rec.seen(op)
}

func failedSigninDrive(t *testing.T, workerAnswer, name string) (string, *recordingRWWorker) {
	t.Helper()
	f := walletFailSetup(t)
	loginWindowState(t)
	resetAbandoned(t, nil)
	failedSigninScrubEnabled = true
	t.Cleanup(func() { failedSigninScrubEnabled = false })
	rec := startRecordingRWWorker(t, f.dest, map[string]string{"in": workerAnswer})
	// The scrub goroutine holds the package-global RW slot until the worker answers it: let it finish (this cleanup
	// runs before the worker's) or the next test's sign-in waits for a slot nobody will free.
	t.Cleanup(func() {
		for end := time.Now().Add(5 * time.Second); len(laneRW.slot) > 0 && time.Now().Before(end); {
			time.Sleep(10 * time.Millisecond)
		}
	})
	reply, _ := roamInBusyDrive(t, f, name, "a passphrase nobody has")
	return reply, rec
}

func TestFailedSigninScrub_BlankNetSchedulesTheLogScrub(t *testing.T) {
	reply, rec := failedSigninDrive(t, "BLANK NET", "zq-fss-net")
	if reply != "BLANK NET" {
		t.Errorf("the reply is %q, want BLANK NET", reply)
	}
	if !waitForOp(rec, "logscrub", 3*time.Second) {
		t.Errorf("no logscrub request reached the RW lane after a BLANK NET sign-in; ops seen: %v", rec.ops)
	}
}

func TestFailedSigninScrub_BlankSchedulesTheLogScrub(t *testing.T) {
	reply, rec := failedSigninDrive(t, "BLANK", "zq-fss-blank")
	if reply != "BLANK" {
		t.Errorf("the reply is %q, want BLANK", reply)
	}
	if !waitForOp(rec, "logscrub", 3*time.Second) {
		t.Errorf("no logscrub request reached the RW lane after a BLANK sign-in; ops seen: %v", rec.ops)
	}
}

func TestFailedSigninScrub_ATimedOutSignInIsNotScrubbed(t *testing.T) {
	reply, rec := failedSigninDrive(t, "ERR-TIMEOUT", "zq-fss-timeout")
	if reply != "ERR-TIMEOUT" {
		t.Errorf("the reply is %q, want ERR-TIMEOUT", reply)
	}
	if waitForOp(rec, "logscrub", time.Second) {
		t.Error("a logscrub request followed an ERR-TIMEOUT sign-in: an earlier op may still hold the lane")
	}
}

func TestFailedSigninScrub_LogscrubRidesTheRWLane(t *testing.T) {
	if got := laneFor("logscrub"); got.svc != laneRW.svc {
		t.Errorf("laneFor(logscrub).svc = %q, want the RW lane %q", got.svc, laneRW.svc)
	}
}

// roamInBranches returns handleRoamIn's source split at its reply chain: the success part, the BLANK NET branch, the
// busy / timeout branches and the final BLANK branch.
func roamInBranches(t *testing.T) (success, blankNet, other, blank string) {
	t.Helper()
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "func handleRoamIn(")
	if i < 0 {
		t.Fatal("handleRoamIn not found")
	}
	end := strings.Index(src[i:], "\n// handleRoamInOffline")
	if end < 0 {
		t.Fatal("handleRoamIn's end not found")
	}
	fn := src[i : i+end]
	nIdx := strings.Index(fn, `} else if strings.HasPrefix(out, "BLANK NET") {`)
	bIdx := strings.Index(fn, `} else if out == workerBusy {`)
	fIdx := strings.LastIndex(fn, "} else {\n\t\tfmt.Fprintf(os.Stderr, \"[logind] roam-in BLANK %q")
	if nIdx < 0 || bIdx < nIdx || fIdx < bIdx {
		t.Fatalf("handleRoamIn's reply chain moved (%d %d %d)", nIdx, bIdx, fIdx)
	}
	return fn[:nIdx], fn[nIdx:bIdx], fn[bIdx:fIdx], fn[fIdx:]
}

func TestFailedSigninScrub_SourcePins(t *testing.T) {
	success, blankNet, other, blank := roamInBranches(t)
	if strings.Contains(success, "scheduleFailedSigninScrub") {
		t.Error("the success branch schedules a logscrub: a signed-in name must not be scrubbed mid-session")
	}
	if strings.Contains(other, "scheduleFailedSigninScrub") {
		t.Error("the busy / ERR-TIMEOUT branches schedule a logscrub: an earlier op may still hold the lane")
	}
	for _, c := range []struct{ name, src string }{{"BLANK NET", blankNet}, {"BLANK", blank}} {
		reply := strings.Index(c.src, "fmt.Fprint(conn")
		call := strings.Index(c.src, "scheduleFailedSigninScrub(dest)")
		if call < 0 || strings.Count(c.src, "scheduleFailedSigninScrub") != 1 {
			t.Errorf("the %s branch does not schedule exactly one failed-sign-in scrub", c.name)
		} else if reply < 0 || call < reply {
			t.Errorf("the %s branch schedules the scrub BEFORE it writes the reply", c.name)
		}
	}
}
