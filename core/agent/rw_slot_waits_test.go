package main

import (
	"fmt"
	"regexp"
	"strings"
	"testing"
	"time"
)

// NWP-20261208-11: rw_slot_waits.go, the RW-lane slot waits by waiting op and holder, and the long holds by op, that
// every issue report carries. test-rw-slot-waits.sh runs these and, with --mutate, convicts a broken copy of each part.

const rwswEmpty = "n=0 ge5s=0 max_ms=0 waits=- held=-"

func resetRwSlotWaits(t *testing.T) {
	t.Helper()
	rwSlotWaits.reset()
	t.Cleanup(rwSlotWaits.reset)
}

func TestRwSlotWaitsFloor(t *testing.T) {
	resetRwSlotWaits(t)
	if got := rwSlotWaits.value(); got != rwswEmpty {
		t.Fatalf("a fresh aggregate = %q, want %q", got, rwswEmpty)
	}
	rwSlotWaits.wait("vpnup", "materializeapp", 4999)
	if got, want := rwSlotWaits.value(), "n=1 ge5s=0 max_ms=4999 waits=- held=-"; got != want {
		t.Errorf("after a 4999ms wait = %q, want %q: under the floor it counts in n only", got, want)
	}
	rwSlotWaits.wait("vpnup", "materializeapp", 5000)
	if got, want := rwSlotWaits.value(), "n=2 ge5s=1 max_ms=5000 waits=vpnup/materializeapp:1:5000 held=-"; got != want {
		t.Errorf("after a 5000ms wait = %q, want %q: a wait AT the floor counts", got, want)
	}
	rwSlotWaits.wait("vpnup", "x", -3)
	if got, want := rwSlotWaits.value(), "n=3 ge5s=1 max_ms=5000 waits=vpnup/materializeapp:1:5000 held=-"; got != want {
		t.Errorf("after a negative wait = %q, want %q: it counts in n as 0 and never lowers max", got, want)
	}
}

func TestRwSlotWaitsHolderNone(t *testing.T) {
	resetRwSlotWaits(t)
	rwSlotWaits.wait("in", "", 6000)
	if got, want := rwSlotWaits.value(), "n=1 ge5s=1 max_ms=6000 waits=in/none:1:6000 held=-"; got != want {
		t.Errorf("a wait with no holder = %q, want %q", got, want)
	}
}

func TestRwSlotWaitsOpClass(t *testing.T) {
	resetRwSlotWaits(t)
	for _, c := range []struct{ in, want string }{
		{"", "none"},
		{"vpnup", "vpnup"},
		{"fido2adopt", "fido2adopt"},
		{"com.app", "other"},
		{"Vpn Up", "other"},
		{"fido2-enroll", "other"},
		{strings.Repeat("a", 21), "other"},
		{strings.Repeat("a", 20), strings.Repeat("a", 20)},
	} {
		if got := opClass(c.in); got != c.want {
			t.Errorf("opClass(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	rwSlotWaits.wait("com.app", "Vpn Up", 5000)
	if got, want := rwSlotWaits.value(), "n=1 ge5s=1 max_ms=5000 waits=other/other:1:5000 held=-"; got != want {
		t.Errorf("a wait by a non-op string = %q, want %q", got, want)
	}
}

func TestRwSlotWaitsCap(t *testing.T) {
	resetRwSlotWaits(t)
	for i := 0; i < 40; i++ {
		rwSlotWaits.wait(fmt.Sprintf("w%02d", i), "h", 5000)
		rwSlotWaits.hold(fmt.Sprintf("o%02d", i), 5000)
	}
	got := rwSlotWaits.value()
	if !strings.Contains(got, " waits=other/other:8:5000,") {
		t.Errorf("40 distinct pairs = %q, want the 8 past the 32-key cap under other/other:8:5000, first", got)
	}
	if !strings.Contains(got, " held=other:8:5000,") {
		t.Errorf("40 distinct holds = %q, want the 8 past the 32-key cap under other:8:5000, first", got)
	}
	rwSlotWaits.mu.Lock()
	np, nh := len(rwSlotWaits.pairs), len(rwSlotWaits.holds)
	rwSlotWaits.mu.Unlock()
	if np != 33 || nh != 33 {
		t.Errorf("keys kept: pairs=%d holds=%d, want 33 each (32 plus the overflow key)", np, nh)
	}
	// A key already kept still updates past the cap.
	rwSlotWaits.wait("w00", "h", 7000)
	if got := rwSlotWaits.value(); !strings.Contains(got, "w00/h:2:7000") {
		t.Errorf("a kept key past the cap = %q, want w00/h:2:7000", got)
	}
}

func TestRwSlotWaitsOrder(t *testing.T) {
	resetRwSlotWaits(t)
	// key -> count of 5000 ms waits, plus one at max (when max > 5000)
	add := func(w string, count int, max int64) {
		for i := 0; i < count-1; i++ {
			rwSlotWaits.wait(w, "h", 5000)
		}
		rwSlotWaits.wait(w, "h", max)
	}
	add("a", 1, 5000)
	add("b", 1, 6000)
	add("c", 2, 5000)
	add("d", 5, 5000)
	add("e", 3, 9000)
	add("f", 3, 8000)
	add("g", 3, 8000)
	add("h", 1, 5000)
	add("i", 1, 5000)
	add("j", 1, 5000)
	add("k", 1, 5000)
	add("l", 1, 5000)
	add("m", 1, 5000)
	add("n", 4, 5000)
	want := " waits=d/h:5:5000,n/h:4:5000,e/h:3:9000,f/h:3:8000,g/h:3:8000,c/h:2:5000,b/h:1:6000," +
		"a/h:1:5000,h/h:1:5000,i/h:1:5000,j/h:1:5000,k/h:1:5000 held=-"
	if got := rwSlotWaits.value(); !strings.HasSuffix(got, want) {
		t.Errorf("14 pairs = %q, want the 12 first by count desc, max desc, key:%s", got, want)
	}
}

func TestRwSlotHolds(t *testing.T) {
	resetRwSlotWaits(t)
	rwSlotWaits.hold("materializeapp", 137285)
	rwSlotWaits.hold("odrestore", 4999)
	rwSlotWaits.hold("Com.X", 9000)
	if got, want := rwSlotWaits.value(), "n=0 ge5s=0 max_ms=0 waits=- held=materializeapp:1:137285,other:1:9000"; got != want {
		t.Errorf("holds = %q, want %q: holds of 5 s or more by op, never in n, ge5s or max_ms", got, want)
	}
}

var rwswReportRE = regexp.MustCompile(`^n=\d+ ge5s=\d+ max_ms=\d+ ` +
	`waits=(-|[a-z0-9]{1,20}/[a-z0-9]{1,20}:\d+:\d+(,[a-z0-9]{1,20}/[a-z0-9]{1,20}:\d+:\d+)*) ` +
	`held=(-|[a-z0-9]{1,20}:\d+:\d+(,[a-z0-9]{1,20}:\d+:\d+)*)$`)

// TestRwSlotIssueReportKey: the key reaches the report at BOTH scopes, exactly (so it skips statusValue), and holds
// digits, fixed words and op codes only.
func TestRwSlotIssueReportKey(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	resetRwSlotWaits(t)
	rwSlotWaits.wait("vpnup", "materializeapp", 12000)
	rwSlotWaits.wait("com.app", "", 6000)
	rwSlotWaits.hold("materializeapp", 137000)
	want := rwSlotWaits.value()
	if !rwswReportRE.MatchString(want) {
		t.Fatalf("control: value() = %q does not match %s", want, rwswReportRE)
	}
	for _, c := range []struct {
		name  string
		scope bool
	}{{"", true}, {"x", false}} {
		rep := buildIssueReport(c.name, c.scope, "", nil, nil)
		if got, ok := rep.Status["rw_slot_waits"]; !ok || got != want {
			t.Errorf("deviceScope=%v: status rw_slot_waits = %q (present=%v), want %q", c.scope, got, ok, want)
		}
	}
}

// TestRwSlotQueuedBehindHolder: an `in` op queues behind materializeapp on the RW lane, through the real
// triggerRoamWorkerKind and a fake worker. The holder read sits before userOpWaiting rises, so the poll on it proves
// the read has happened; no step depends on the scheduler. Then an RO-lane op adds nothing.
func TestRwSlotQueuedBehindHolder(t *testing.T) {
	rwLaneFree(t)
	resetRwSlotWaits(t)
	prevFloor := rwSlotWaitFloor
	rwSlotWaitFloor = 20 * time.Millisecond
	t.Cleanup(func() { rwSlotWaitFloor = prevFloor })
	prevWaiting := userOpWaiting.Load()
	userOpWaiting.Store(0)
	t.Cleanup(func() { userOpWaiting.Store(prevWaiting) })
	if laneFor("in").svc != laneRW.svc || laneFor("storagebreakdown").svc != laneRO.svc || !userInitiatedOp("in") {
		t.Fatal("control: in must be a user-initiated RW-lane op and storagebreakdown an RO-lane op")
	}

	// Phase 1: an `in` queues behind materializeapp on the RW lane.
	laneRW.slot <- struct{}{}
	setRWHolder("materializeapp")
	f := lsrFakeInit(t, laneRW, lsrStates("stopped"),
		[]lsrPlan{{kind: lsrAnswer, text: "OK 10", after: 60 * time.Millisecond}}) // a hold of 60 ms or more, over the floor
	ch := make(chan string, 1)
	go func() { ch <- triggerRoamWorkerKind(f.dest, "in", "rwsw", "pw", "", "", "", "", "", nil) }()
	deadline := time.Now().Add(5 * time.Second)
	for userOpWaiting.Load() <= 0 { // rises AFTER the holder read, so this proves the read has happened
		if time.Now().After(deadline) {
			setRWHolder("")
			<-laneRW.slot
			t.Fatal("the in op never queued (userOpWaiting stayed 0 for 5s)")
		}
		time.Sleep(time.Millisecond)
	}
	time.Sleep(50 * time.Millisecond) // 2.5x the floor, with the in op parked on the send
	setRWHolder("")                   // the real release order: a read after the acquire sees ""
	<-laneRW.slot
	select {
	case out := <-ch:
		if out != "OK 10" {
			t.Fatalf("control: the in op answered %q, want the stand-in's OK 10", out)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the in op did not return within 10s")
	}
	got := rwSlotWaits.value()
	if !strings.HasPrefix(got, "n=1 ge5s=1 ") {
		t.Errorf("rwSlotWaits = %q, want n=1 ge5s=1: one RW wait of 50ms or more over a 20ms floor", got)
	}
	if !strings.Contains(got, " waits=in/materializeapp:1:") {
		t.Errorf("rwSlotWaits = %q, want waits=in/materializeapp:1: (the holder the in op met when it queued)", got)
	}
	if !strings.Contains(got, " held=in:1:") {
		t.Errorf("rwSlotWaits = %q, want held=in:1: (the in op's own hold of 60ms or more)", got)
	}

	// Phase 2: an RO-lane op adds nothing.
	f2 := lsrFakeInit(t, laneRO, lsrStates("stopped"),
		[]lsrPlan{{kind: lsrAnswer, text: "OK", after: 40 * time.Millisecond}})
	if out := triggerRoamWorkerKind(f2.dest, "storagebreakdown", "rwsw", "", "", "", "", "", "", nil); out != "OK" {
		t.Fatalf("control: storagebreakdown answered %q, want the stand-in's OK", out)
	}
	if after := rwSlotWaits.value(); after != got {
		t.Errorf("after an RO-lane op rwSlotWaits = %q, want it unchanged at %q", after, got)
	}
}
