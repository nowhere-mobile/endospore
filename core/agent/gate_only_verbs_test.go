package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261024-04, NWP-20261031-12: CLEAN-STORAGE, BOOT-SWEEP, BT-WIPE, ACK-REAP, CLEAR-COLDLOCK, CLAIM-COLDLOCK,
// GET-GATE-ALARM, OTA-APPLY, SET-OTA-AUTO, SET-OTA-TIME, SET-SYNC-INTERVAL SEED-SSAID, EVICT-RECHECK-SAVED, SIGNIN-SHOWN (NWP-20261106-07), SET-DEVICE-LABEL (NWP-20261114-24) and DROP-SSAID (NWP-20261115-01) answer only the user-0 gate and root (backlog: "A roamed session could reap any user's storage"). A roamed
// NWP-20261118-15 adds GRANT-PERMS, PREFETCH-ARM, PREFETCH-DISARM, REKEY-ARM, REKEY-DISARM, REKEY-WAIT-WIFI,
// REKEY-WAIT-NET and REKEY-WAIT-BATTERY: their one sender is user-0 gate code too.
// NWP-20261125-15 adds RERUN-REAP: only the gate re-runs a teardown after its own deadline.
// NWP-20261201-03 adds SAVE-NET-UNMETERED and SAVE-NET-METERED: only the gate's slow tick reports the network.
// session's chooser shares the gate's appId and SELinux domain, so the accept-time pin alone cannot tell the two apart.
// The seams (ownerPeerUID, the worker, the reap queue) are package-global, so nothing here is parallel.

var gateOnlyVerbs = []string{
	"CLEAN-STORAGE", "BOOT-SWEEP", "BT-WIPE", "ACK-REAP", "CLEAR-COLDLOCK", "CLAIM-COLDLOCK", "GET-GATE-ALARM", "OTA-APPLY",
	"SET-OTA-AUTO", "SET-OTA-TIME", "SET-SYNC-INTERVAL", "SEED-SSAID", "EVICT-RECHECK-SAVED",
	"SIGNIN-SHOWN", "SET-DEVICE-LABEL", "DROP-SSAID",
	"GRANT-PERMS", "PREFETCH-ARM", "PREFETCH-DISARM",
	"REKEY-ARM", "REKEY-DISARM", "REKEY-WAIT-WIFI", "REKEY-WAIT-NET", "REKEY-WAIT-BATTERY",
	"RERUN-REAP",
	"SAVE-NET-UNMETERED", "SAVE-NET-METERED",
}

// gateOnlyGrantTail reads the stubbed grant tail (seed-home, then bootwake) that the GRANT-PERMS fixture installed.
var gateOnlyGrantTail func() []bootWakeCall

// gateOnlyWG records every handler goroutine gateOnlyDrive starts, so a test can wait for them before it ends.
var gateOnlyWG sync.WaitGroup

// waitGateOnly waits up to 5 s for every handler gateOnlyDrive started.
func waitGateOnly(t *testing.T) {
	t.Helper()
	done := make(chan struct{})
	go func() { gateOnlyWG.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Errorf("a handler goroutine was still running 5 s after the test finished")
	}
}

// gateOnlyDrive sends the verb line, then rest in a second write, runs handleLogin(dest) in a goroutine and returns the
// reply and whether the second write was left unconsumed. net.Pipe is synchronous: a write blocks until read, so the
// handler closing its end with the write pending (n == 0) means it never read those lines. On a timeout it returns
// answered=false WITHOUT waiting for the handler.
func gateOnlyDrive(t *testing.T, dest, verb, rest string, bound time.Duration) (reply string, unread bool, answered bool) {
	t.Helper()
	cli, srv := net.Pipe()
	wrote := make(chan int, 1)
	go func() {
		cli.Write([]byte(verb + "\n"))
		n, _ := cli.Write([]byte(rest))
		wrote <- n
	}()
	got := make(chan string, 1)
	go func() { b, _ := io.ReadAll(cli); got <- string(b) }()
	gateOnlyWG.Add(1)
	go func() {
		defer gateOnlyWG.Done()
		handleLogin(srv, dest) // closes srv itself
		cli.Close()
	}()
	select {
	case s := <-got:
		return strings.TrimSpace(s), <-wrote == 0, true
	case <-time.After(bound):
		return "", false, false
	}
}

// gateOnlyFixture plants what one verb acts on in a fresh fake-init dest and returns the fake, the request lines that
// follow the verb, and a check that nothing the verb acts on has changed. A verb with no request line gets one stray
// line, so that "left unread" still means something.
func gateOnlyFixture(t *testing.T, verb string, plan []abPlan) (f *abInit, rest string, check func(t *testing.T, label string)) {
	t.Helper()
	f = abFakeInit(t, plan)
	resetAbandoned(t, nil)
	dest := f.dest
	write := func(name, body string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dest, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	sameBytes := func(t *testing.T, label, name, want string) {
		t.Helper()
		if b, err := os.ReadFile(filepath.Join(dest, name)); err != nil || string(b) != want {
			t.Errorf("%s: %s is %q (%v), want %q", label, name, b, err, want)
		}
	}
	noWorker := func(t *testing.T, label string) {
		t.Helper()
		if n := len(f.snapshot()); n != 0 {
			t.Errorf("%s: %d worker start(s), want none", label, n)
		}
	}
	const marker = "alice\n15\n\n\n\n\n\n"
	stash := nfcHmacStash(true)
	switch verb {
	case "CLEAN-STORAGE":
		dir := useTempIngest(t)
		useTempUsersDir(t)
		plant(t, dir, "telingest.15")
		return f, "15\n", func(t *testing.T, label string) {
			t.Helper()
			if _, err := os.Stat(filepath.Join(dir, "telingest.15")); err != nil {
				t.Errorf("%s: the mailbox of uid 15 is gone: %v", label, err)
			}
			noWorker(t, label)
		}
	case "BOOT-SWEEP", "BT-WIPE":
		return f, "x\n", noWorker
	case "ACK-REAP":
		ropReapReset(t)
		pendingReapMu.Lock()
		pendingSwitchUID = "15"
		pendingReapMu.Unlock()
		t.Cleanup(func() {
			pendingReapMu.Lock()
			pendingLockUID = ""
			pendingReapMu.Unlock()
		})
		return f, "SWITCH\n15\n", func(t *testing.T, label string) {
			t.Helper()
			if got := nextReapAction(); got != "SWITCH 15" {
				t.Errorf("%s: the reap queue reads %q, want SWITCH 15", label, got)
			}
		}
	case "SAVE-NET-UNMETERED", "SAVE-NET-METERED":
		// The opposite of what the verb reports, at a fixed time: a refused verb changes neither. A verb with no request
		// line gets one stray line.
		was := verb == "SAVE-NET-METERED"
		at := time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)
		saveModeState(t)
		pendingReapMu.Lock()
		saveNetUnmetered, saveNetAt = was, at
		pendingReapMu.Unlock()
		return f, "x\n", func(t *testing.T, label string) {
			t.Helper()
			pendingReapMu.Lock()
			got, gotAt := saveNetUnmetered, saveNetAt
			pendingReapMu.Unlock()
			if got != was || !gotAt.Equal(at) {
				t.Errorf("%s: the network state is %v at %v, want %v at %v", label, got, gotAt, was, at)
			}
		}
	case "RERUN-REAP":
		// User 15 exists, and no session or cold lock holds it: the gate would get OK, and the REAP queued.
		ropReapReset(t)
		t.Cleanup(func() {
			pendingReapMu.Lock()
			pendingLockUID = ""
			pendingReapMu.Unlock()
		})
		users := useTempUsersDir(t)
		if err := os.Mkdir(filepath.Join(users, "15"), 0o700); err != nil {
			t.Fatal(err)
		}
		return f, "15\n", func(t *testing.T, label string) {
			t.Helper()
			if got := nextReapAction(); got != "NONE" {
				t.Errorf("%s: the reap queue reads %q, want NONE", label, got)
			}
			noWorker(t, label)
		}
	case "CLEAR-COLDLOCK", "CLAIM-COLDLOCK":
		write(".coldlock", marker)
		write(stash, "h\n")
		rest = "x\n"
		if verb == "CLAIM-COLDLOCK" {
			markLocalSession(dest)
			rest = "15\n"
		}
		return f, rest, func(t *testing.T, label string) {
			t.Helper()
			sameBytes(t, label, ".coldlock", marker)
			sameBytes(t, label, stash, "h\n")
			if verb == "CLAIM-COLDLOCK" && !isLocalSession(dest) {
				t.Errorf("%s: .localsession is gone", label)
			}
		}
	case "GET-GATE-ALARM":
		write("gate-alarm", "1760000000000\n")
		return f, "x\n", func(t *testing.T, label string) {
			t.Helper()
			sameBytes(t, label, "gate-alarm", "1760000000000\n")
		}
	case "OTA-APPLY":
		write("ota.res", "AVAIL 0.5.99\n")
		return f, "x\n", func(t *testing.T, label string) {
			t.Helper()
			if _, err := os.Stat(filepath.Join(dest, "ota.req")); err == nil {
				t.Errorf("%s: ota.req was written", label)
			}
			sameBytes(t, label, "ota.res", "AVAIL 0.5.99\n")
		}
	case "SET-OTA-AUTO", "SET-OTA-TIME":
		auto, otime, _ := useTempDeviceFlags(t)
		path, req := auto, "1\n"
		if verb == "SET-OTA-TIME" {
			path, req = otime, "07:30\n"
		}
		return f, req, func(t *testing.T, label string) {
			t.Helper()
			if _, err := os.Stat(path); err == nil {
				t.Errorf("%s: %s was written", label, filepath.Base(path))
			}
		}
	case "SET-SYNC-INTERVAL":
		p := useTempSyncInterval(t)
		return f, "300\n", func(t *testing.T, label string) {
			t.Helper()
			if _, err := os.Stat(p); err == nil {
				t.Errorf("%s: sync-interval was written", label)
			}
		}
	case "SEED-SSAID":
		return f, "katname\nkatpass\n10\n", noWorker
	case "DROP-SSAID":
		return f, "17\n", noWorker
	case "EVICT-RECHECK-SAVED":
		write(".coldlock", marker)
		return f, "16\n", func(t *testing.T, label string) {
			t.Helper()
			sameBytes(t, label, ".coldlock", marker)
			noWorker(t, label)
		}
	case "SIGNIN-SHOWN":
		return f, "slow\n", func(t *testing.T, label string) {
			t.Helper()
			if _, err := os.Stat(filepath.Join(dest, signinFailFile)); err == nil {
				t.Errorf("%s: a failure record was written", label)
			}
		}
	case "SET-DEVICE-LABEL":
		p := useTempDeviceLabel(t)
		return f, "Roamed name\n", func(t *testing.T, label string) {
			t.Helper()
			if _, err := os.Stat(p); err == nil {
				t.Errorf("%s: device-label was written", label)
			}
		}
	case "GRANT-PERMS":
		// The tail is stubbed as grantPermsRequest stubs it: seed-home and bootwake are fakes, the tie finish waits 0 s,
		// and .localsession keeps kickMediad and the tie finish out of the worker. The handler's goSafe jobs (finish-tie,
		// seed-home) are joined before the stubs and tieFinishDelay are restored: cleanups run last-in first-out.
		gateOnlyGrantTail = bootWakeFakes(t)
		old := tieFinishDelay
		tieFinishDelay = 0
		t.Cleanup(func() { tieFinishDelay = old })
		tr := trackGoSafe(t)
		t.Cleanup(func() { tr.wait(t, 5*time.Second) })
		markLocalSession(dest)
		return f, "15\n", func(t *testing.T, label string) {
			t.Helper()
			noWorker(t, label)
			if bootWakeGate.armed("15") {
				t.Errorf("%s: the boot-broadcast gate is armed for uid 15", label)
			}
			if n := len(gateOnlyGrantTail()); n != 0 {
				t.Errorf("%s: the grant tail ran %d op(s), want none", label, n)
			}
		}
	case "PREFETCH-ARM":
		return f, "x\n", func(t *testing.T, label string) {
			t.Helper()
			if _, err := os.Stat(filepath.Join(dest, prefetchArmedFile)); err == nil {
				t.Errorf("%s: %s was written", label, prefetchArmedFile)
			}
		}
	case "PREFETCH-DISARM":
		write(prefetchArmedFile, "1")
		return f, "x\n", func(t *testing.T, label string) {
			t.Helper()
			sameBytes(t, label, prefetchArmedFile, "1")
		}
	case "REKEY-ARM", "REKEY-DISARM", "REKEY-WAIT-WIFI", "REKEY-WAIT-NET", "REKEY-WAIT-BATTERY":
		// Every REKEY-* handler removes both files first, so a refused verb is one that left both as planted.
		write(rekeyArmedFile, "old\n")
		write(rekeyWaitFile, "old wifi\n")
		return f, "x\n", func(t *testing.T, label string) {
			t.Helper()
			sameBytes(t, label, rekeyArmedFile, "old\n")
			sameBytes(t, label, rekeyWaitFile, "old wifi\n")
		}
	}
	t.Fatalf("no fixture for %s", verb)
	return nil, "", nil
}

func TestGateOnlyCmd_IsTheGateOnlyVerbs(t *testing.T) {
	for _, v := range gateOnlyVerbs {
		if !gateOnlyCmd(v) {
			t.Errorf("%s is a gate-only verb", v)
		}
	}
	for _, v := range []string{"POLL-REAP", "DROP-CACHES", "EVICT-RECHECK", "COLD-LOCK-ABORT", "GET-COLDLOCK", "SET-GATE-ALARM",
		"SILENCE-GATE-ALARM", "OTA-APPLY-AFTER-LOGOFF", "OTA-AFTER-LOGOFF", "OTA-STATUS",
		"GET-OTA-AUTO", "GET-OTA-TIME", "GET-SYNC-INTERVAL", "GATE-TIMING", "", "clean-storage", "CLEAN-STORAGE "} {
		if gateOnlyCmd(v) {
			t.Errorf("%q is not a gate-only verb", v)
		}
	}
}

// TestGateOnlyVerbs_RefuseARoamedPeer: each verb answers exactly DENIED to a roamed peer and to a failed peer read,
// leaves its request unread, and changes nothing.
func TestGateOnlyVerbs_RefuseARoamedPeer(t *testing.T) {
	for _, verb := range gateOnlyVerbs {
		for _, peer := range []int{gateRoamedA, gateRoamedB, -1} {
			verb, peer := verb, peer
			t.Run(fmt.Sprintf("%s/%d", verb, peer), func(t *testing.T) {
				gatePeer(t, peer)
				f, rest, check := gateOnlyFixture(t, verb, nil)
				defer waitGateOnly(t)
				reply, unread, answered := gateOnlyDrive(t, f.dest, verb, rest, 5*time.Second)
				if !answered {
					t.Fatalf("%s from peer %d: no reply within 5 s", verb, peer)
				}
				if reply != "DENIED" {
					t.Errorf("%s from peer %d replied %q, want DENIED", verb, peer, reply)
				}
				if !unread {
					t.Errorf("%s from peer %d: the request line was read", verb, peer)
				}
				check(t, verb)
			})
		}
	}
}

// TestGateOnlyVerbs_RefusalDoesNotWaitOnSessionMu: with sessionMu held (a login or a materialise), a roamed peer still
// gets its DENIED at once, so the refusal sits before the lock. The test never runs a synchronous drive under the lock.
func TestGateOnlyVerbs_RefusalDoesNotWaitOnSessionMu(t *testing.T) {
	gatePeer(t, gateRoamedA)
	dests := map[string]string{}
	rests := map[string]string{}
	for _, verb := range gateOnlyVerbs {
		f, rest, _ := gateOnlyFixture(t, verb, nil)
		dests[verb], rests[verb] = f.dest, rest
	}
	t.Cleanup(func() { waitGateOnly(t) })
	sessionMu.Lock()
	released := false
	release := func() {
		if !released {
			released = true
			sessionMu.Unlock()
		}
	}
	t.Cleanup(release)
	for _, verb := range gateOnlyVerbs {
		reply, _, answered := gateOnlyDrive(t, dests[verb], verb, rests[verb], 2*time.Second)
		if !answered || reply != "DENIED" {
			t.Errorf("%s from a roamed peer, with sessionMu held: answered=%v reply=%q, want DENIED at once", verb, answered, reply)
		}
	}
	release()
	waitGateOnly(t)
}

// TestGateOnlyVerbs_GateAndRootReachTheHandler: the user-0 gate and root get each verb's own answer.
func TestGateOnlyVerbs_GateAndRootReachTheHandler(t *testing.T) {
	for _, peer := range []int{10123, 0} {
		for _, verb := range gateOnlyVerbs {
			peer, verb := peer, verb
			t.Run(fmt.Sprintf("%s/%d", verb, peer), func(t *testing.T) {
				gatePeer(t, peer)
				var plan []abPlan
				switch verb {
				case "CLEAN-STORAGE", "BOOT-SWEEP", "BT-WIPE", "GRANT-PERMS":
					plan = []abPlan{{lane: laneRW, text: "OK"}}
				}
				f, rest, _ := gateOnlyFixture(t, verb, plan)
				defer waitGateOnly(t)
				want := "OK"
				switch verb {
				case "GET-GATE-ALARM":
					want = "1760000000000"
				case "SEED-SSAID":
					// Empty name and user: the handler is reached and answers before any prefetch, derive or worker op.
					rest, want = "\n\n\n", "ERR-ARGS"
				case "DROP-SSAID":
					// An empty uid: the handler is reached and answers before any worker op.
					rest, want = "\n", "ERR-UID"
				case "EVICT-RECHECK-SAVED":
					want = "OK GONE" // the fixture's marker is user 15's, the request names 16
				}
				reply, _, answered := gateOnlyDrive(t, f.dest, verb, rest, 10*time.Second)
				if !answered {
					t.Fatalf("%s from peer %d: no reply within 10 s", verb, peer)
				}
				if reply != want {
					t.Errorf("%s from peer %d replied %q, want %q", verb, peer, reply, want)
				}
				switch verb {
				case "SAVE-NET-UNMETERED", "SAVE-NET-METERED":
					pendingReapMu.Lock()
					got, at := saveNetUnmetered, saveNetAt
					pendingReapMu.Unlock()
					if got != (verb == "SAVE-NET-UNMETERED") || time.Since(at) > time.Minute {
						t.Errorf("%s: the network state is %v at %v", verb, got, at)
					}
				case "SIGNIN-SHOWN":
					if b, err := os.ReadFile(filepath.Join(f.dest, signinFailFile)); err != nil || !strings.HasPrefix(string(b), "slow\t") {
						t.Errorf("the failure record reads %q (%v), want one starting slow", b, err)
					}
				case "GET-GATE-ALARM":
					if _, err := os.Stat(filepath.Join(f.dest, "gate-alarm")); err == nil {
						t.Error("the alarm stash was not consumed")
					}
				case "CLEAR-COLDLOCK":
					if _, err := os.Stat(filepath.Join(f.dest, ".coldlock")); err == nil {
						t.Error("the cold-lock marker was not cleared")
					}
				case "ACK-REAP":
					if got := nextReapAction(); got != "NONE" {
						t.Errorf("the reap queue reads %q, want NONE", got)
					}
				case "RERUN-REAP":
					if got := nextReapAction(); got != "REAP 15" {
						t.Errorf("the reap queue reads %q, want REAP 15", got)
					}
					if n := len(f.snapshot()); n != 0 {
						t.Errorf("RERUN-REAP started %d worker op(s), want none", n)
					}
				case "CLEAN-STORAGE", "BOOT-SWEEP", "BT-WIPE":
					op := map[string]string{"CLEAN-STORAGE": "cleanstorage", "BOOT-SWEEP": "bootsweep", "BT-WIPE": "btwipe"}[verb]
					starts := f.snapshot()
					if len(starts) == 0 {
						t.Fatalf("%s started no worker", verb)
					}
					if last := starts[len(starts)-1]; last.svc != "nowhere_roamd" || last.reqOp != op {
						t.Errorf("%s: the last worker start is %+v, want nowhere_roamd running %s", verb, last, op)
					}
				case "SET-OTA-AUTO", "SET-OTA-TIME", "SET-SYNC-INTERVAL":
					path, val := map[string]string{"SET-OTA-AUTO": otaAutoPath, "SET-OTA-TIME": otaTimePath,
						"SET-SYNC-INTERVAL": syncIntervalPath}[verb], map[string]string{"SET-OTA-AUTO": "1",
						"SET-OTA-TIME": "07:30", "SET-SYNC-INTERVAL": "300"}[verb]
					if b, err := os.ReadFile(path); err != nil || strings.TrimSpace(string(b)) != val {
						t.Errorf("%s: the file holds %q (%v), want %q", verb, b, err, val)
					}
				case "SET-DEVICE-LABEL":
					if b, err := os.ReadFile(deviceLabelPath); err != nil || string(b) != "Roamed name\n" {
						t.Errorf("device-label holds %q (%v), want \"Roamed name\\n\"", b, err)
					}
				case "OTA-APPLY":
					if b, err := os.ReadFile(filepath.Join(f.dest, "ota.req")); err != nil || string(b) != "apply\n" {
						t.Errorf("ota.req is %q (%v), want \"apply\\n\"", b, err)
					}
				case "GRANT-PERMS":
					starts := f.snapshot()
					if len(starts) == 0 {
						t.Fatal("GRANT-PERMS started no worker")
					}
					if last := starts[len(starts)-1]; last.svc != "nowhere_roamd" || last.reqOp != "grant" {
						t.Errorf("GRANT-PERMS: the last worker start is %+v, want nowhere_roamd running grant", last)
					}
					if !bootWakeGate.armed("15") {
						t.Error("GRANT-PERMS did not arm the boot-broadcast gate for uid 15")
					}
					// Wait for the stubbed tail (seed-home, then bootwake), so no goroutine outlives the stubs.
					deadline := time.Now().Add(5 * time.Second)
					for len(gateOnlyGrantTail()) < 2 {
						if time.Now().After(deadline) {
							t.Fatalf("the grant tail did not run: %v", gateOnlyGrantTail())
						}
						time.Sleep(10 * time.Millisecond)
					}
				case "PREFETCH-ARM":
					if b, err := os.ReadFile(filepath.Join(f.dest, prefetchArmedFile)); err != nil || string(b) != "1" {
						t.Errorf("%s holds %q (%v), want \"1\"", prefetchArmedFile, b, err)
					}
				case "PREFETCH-DISARM":
					if _, err := os.Stat(filepath.Join(f.dest, prefetchArmedFile)); err == nil {
						t.Errorf("%s is still there", prefetchArmedFile)
					}
				case "REKEY-ARM", "REKEY-DISARM", "REKEY-WAIT-WIFI", "REKEY-WAIT-NET", "REKEY-WAIT-BATTERY":
					// No session is seated, so the flag names the empty uid.
					wantArmed, wantWait := "", ""
					switch verb {
					case "REKEY-ARM":
						wantArmed = "\n"
					case "REKEY-WAIT-WIFI", "REKEY-WAIT-NET", "REKEY-WAIT-BATTERY":
						wantWait = " " + strings.ToLower(strings.TrimPrefix(verb, "REKEY-WAIT-")) + "\n"
					}
					for file, want := range map[string]string{rekeyArmedFile: wantArmed, rekeyWaitFile: wantWait} {
						b, err := os.ReadFile(filepath.Join(f.dest, file))
						if want == "" && err == nil {
							t.Errorf("%s: %s is still there (%q)", verb, file, b)
						}
						if want != "" && (err != nil || string(b) != want) {
							t.Errorf("%s: %s holds %q (%v), want %q", verb, file, b, err, want)
						}
					}
				}
			})
		}
	}
}
