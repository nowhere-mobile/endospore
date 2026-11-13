package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261202-36, backlog row 'An automatic save shows only "Saving automatically now…": no stage, no progress and no
// start time, although the save produces the same progress frames that Back up now shows': SEAL-DELTA sends the live
// run's own announce time (runStart) and its current progress frame (runProg), both only while a run is announced.
// Every assertion reads the handler's JSON. Each test signs in its own local profile, so SEAL-DELTA reads no store.

// sdrunSetup starts the test's local session, clears the seal state and restores the three seal stamps afterwards.
func sdrunSetup(t *testing.T, profile string) string {
	t.Helper()
	dest := sdlsEnv(t, profile)
	resetSealState(t)
	pendingReapMu.Lock()
	runAt := sealRunAt
	busy := deleteInFlight || rotateInFlight
	pendingReapMu.Unlock()
	started, periodic := lastSealStartedAt.Load(), periodicSealStartedAt.Load()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		sealRunAt = runAt
		pendingReapMu.Unlock()
		lastSealStartedAt.Store(started)
		periodicSealStartedAt.Store(periodic)
	})
	if busy {
		t.Fatal("deleteInFlight or rotateInFlight is set: announcePeriodicSeal would refuse")
	}
	return dest
}

// sdrunSetRunAt sets the live run's announce time.
func sdrunSetRunAt(at time.Time) {
	pendingReapMu.Lock()
	sealRunAt = at
	pendingReapMu.Unlock()
}

// sdrunReply asks SEAL-DELTA and returns its JSON body as a map.
func sdrunReply(t *testing.T, dest string) map[string]any {
	t.Helper()
	reply := ropReply(t, func(c net.Conn) { handleSealDelta(c, dest) })
	nl := strings.IndexByte(reply, '\n')
	if nl < 0 || !strings.HasPrefix(reply, "OK ") {
		t.Fatalf("SEAL-DELTA reply %q", reply)
	}
	body := reply[nl+1:]
	if want := fmt.Sprintf("OK %d", len(body)); reply[:nl] != want {
		t.Fatalf("frame %q for a %d-byte body", reply[:nl], len(body))
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(body), &m); err != nil {
		t.Fatal(err)
	}
	if m["session"] != "local" {
		t.Fatalf("session = %v, want local (no store read)", m["session"])
	}
	return m
}

// sdrunAbsent fails the test for each key present in the reply.
func sdrunAbsent(t *testing.T, m map[string]any, keys ...string) {
	t.Helper()
	for _, k := range keys {
		if v, ok := m[k]; ok {
			t.Errorf("reply carries %q = %v, want the key absent", k, v)
		}
	}
}

// runStart is the live run's own announce, not lastStart: the announce stamped lastSealStartedAt with now.
func TestSealDeltaRunStartIsTheLiveAnnounce(t *testing.T) {
	dest := sdrunSetup(t, "sdrun-announce")
	if !announcePeriodicSeal() {
		t.Fatal("announcePeriodicSeal refused")
	}
	sdrunSetRunAt(time.Unix(1700000000, 0))
	m := sdrunReply(t, dest)
	if m["run"] != "periodic" {
		t.Errorf("run = %v, want periodic", m["run"])
	}
	if m["runStart"] != float64(1700000000) {
		t.Errorf("runStart = %v, want 1700000000 (the announce time)", m["runStart"])
	}
}

// runProg is SEAL-STATUS's first line less "SEALING ", and absent when the frame is empty.
func TestSealDeltaRunProgIsTheLiveFrame(t *testing.T) {
	dest := sdrunSetup(t, "sdrun-prog")
	setSealRun("periodic")
	prog := filepath.Join(dest, "roam.progress")
	if err := os.WriteFile(prog, []byte("save 5 10 media\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if m := sdrunReply(t, dest); m["runProg"] != "save 5 10 media" {
		t.Errorf("runProg = %v, want \"save 5 10 media\"", m["runProg"])
	}
	if err := os.Remove(prog); err != nil {
		t.Fatal(err)
	}
	sdrunAbsent(t, sdrunReply(t, dest), "runProg")
}

// A sign-out announced over a running periodic save: run and runStart both describe the sign-out.
func TestSealDeltaRunStartFollowsALogoffOverAPeriodic(t *testing.T) {
	dest := sdrunSetup(t, "sdrun-logoff")
	if !announcePeriodicSeal() {
		t.Fatal("announcePeriodicSeal refused")
	}
	sdrunSetRunAt(time.Unix(1700000000, 0))
	setSealRun("logoff")
	b := time.Unix(1700000600, 0)
	sdrunSetRunAt(b)
	m := sdrunReply(t, dest)
	if m["run"] != "logoff" {
		t.Errorf("run = %v, want logoff", m["run"])
	}
	if m["runStart"] != float64(b.Unix()) {
		t.Errorf("runStart = %v, want %d (the sign-out's announce)", m["runStart"], b.Unix())
	}
}

// With no announced run, run, runStart and runProg are absent, even with a stale announce time, a progress file and
// a live progress channel (sealInFlight, which composeSealStatus answers SEALING for).
func TestSealDeltaNoRunOmitsRunFields(t *testing.T) {
	dest := sdrunSetup(t, "sdrun-norun")
	clearSealRun()
	if err := os.WriteFile(filepath.Join(dest, "roam.progress"), []byte("save 5 10 media\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	sdrunSetRunAt(time.Unix(1700000000, 0))
	m := sdrunReply(t, dest)
	sdrunAbsent(t, m, "run", "runStart", "runProg")
	// TestSealDeltaReplyShape's always-sent keys. Its "run" and "storedApps" are omitempty and absent by design here:
	// no run is announced, and a local session reads no store.
	for _, k := range []string{"v", "session", "verdict", "lastStart", "lastOK", "deferrals", "storedMeasured"} {
		if _, ok := m[k]; !ok {
			t.Errorf("reply missing %q", k)
		}
	}
	pendingReapMu.Lock()
	sealInFlight = true
	pendingReapMu.Unlock()
	sdrunAbsent(t, sdrunReply(t, dest), "run", "runStart", "runProg")
}
