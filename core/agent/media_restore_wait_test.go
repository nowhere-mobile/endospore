package main

// NWP-20261207-11: the lander's parked state (Q106 S6b half 1, docs/media-after-gate.md §6 and §10 O3):
// TestMediaRestoreWait, the cases test-media-restore-wait.sh runs and mutates. A pass PARKS when it ends with rels
// pending, landed none, and had at least one transient fetch error; mediad then publishes RESTORE-WAITING.

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

// mrwEvents records each onPark answer and each sleep, in order, on an mlRun.
func mrwEvents(r *mlRun) *[]string {
	var ev []string
	sleep := r.in.sleep
	r.in.onPark = func(p bool) { ev = append(ev, fmt.Sprintf("park:%v", p)) }
	r.in.sleep = func(d time.Duration) bool {
		ev = append(ev, "sleep")
		return sleep(d)
	}
	return &ev
}

// Parks: every fetch fails transiently, so each pass parks, and onPark comes before its sleep.
func TestMediaRestoreWaitParks(t *testing.T) {
	r := mlNew(t, []string{"DCIM/offline.jpg"}, nil)
	r.in.ref = "mrwparks"
	r.maxWait = 3
	r.hook = func(string) ([]byte, error, bool) { return nil, errors.New("dial tcp: connection refused"), true }
	ev := mrwEvents(r)
	if c := r.land(); c.pending != 1 || c.landed != 0 {
		t.Fatalf("counts: %+v", c)
	}
	want := []string{"park:true", "sleep", "park:true", "sleep", "park:true", "sleep"}
	if !slices.Equal(*ev, want) {
		t.Fatalf("events %v, want %v", *ev, want)
	}

	// One transient rel beside a corrupt one still parks: the transient error is the network.
	r = mlNew(t, []string{"DCIM/offline.jpg", "DCIM/bad.jpg"}, nil)
	r.in.ref = "mrwparksmixed"
	r.maxWait = 1
	r.hook = func(rel string) ([]byte, error, bool) {
		if rel == "DCIM/bad.jpg" {
			return nil, errors.New("fetch span [1,2): corrupt chunk in store: blob/c1"), true
		}
		return nil, errors.New("dial tcp: i/o timeout"), true
	}
	ev = mrwEvents(r)
	r.land()
	if !slices.Equal(*ev, []string{"park:true", "sleep"}) {
		t.Fatalf("mixed: events %v", *ev)
	}
}

// mrwTwoRels is a head of a newer DCIM rel (ordered first) and an older one.
func mrwTwoRels(t *testing.T, ref string) (*mlRun, string, string) {
	a, b := "DCIM/new.jpg", "DCIM/old.jpg"
	r := mlNew(t, []string{a, b}, map[string]int64{a: 3000, b: 1000})
	r.in.ref = ref
	if o := landerOrder(r.m, []string{a, b}); !slices.Equal(o, []string{a, b}) {
		t.Fatalf("the fixture order is %v", o)
	}
	return r, a, b
}

// Clears: pass 1 is transient only (parked), pass 2 lands one file (not parked); a bgLander drops RESTORE-WAITING at
// that landing.
func TestMediaRestoreWaitClears(t *testing.T) {
	r, a, _ := mrwTwoRels(t, "mrwclears")
	r.maxWait = 2
	r.hook = func(rel string) ([]byte, error, bool) {
		if rel == a && len(r.sleeps) >= 1 {
			return nil, nil, false
		}
		return nil, errors.New("connection refused"), true
	}
	ev := mrwEvents(r)
	r.land()
	if want := []string{"park:true", "sleep", "park:false", "sleep"}; !slices.Equal(*ev, want) {
		t.Fatalf("events %v, want %v", *ev, want)
	}

	s, state := mbrProg(t)
	l := newBgLander(state, r.in.dest, nil, r.m, s)
	l.onStart([]string{"DCIM/new.jpg", "DCIM/old.jpg"})
	l.onPark(true)
	total := r.m.Ess["DCIM/new.jpg"].Size + r.m.Ess["DCIM/old.jpg"].Size
	if got, want := mbrReadProg(t, s), fmt.Sprintf("RESTORING 0 %d 2\nRESTORE-WAITING\n", total); got != want {
		t.Fatalf("parked: %q, want %q", got, want)
	}
	mbrLand(l, "DCIM/new.jpg")
	want := fmt.Sprintf("RESTORING %d %d 1\n", r.m.Ess["DCIM/new.jpg"].Size, total)
	if got := mbrReadProg(t, s); got != want {
		t.Fatalf("a landing must end the wait: %q, want %q", got, want)
	}
}

// NotNetwork: a pass whose only failures are a corrupt span and a link refusal does not park.
func TestMediaRestoreWaitNotNetwork(t *testing.T) {
	bad, linked := "DCIM/bad.jpg", "DCIM/linked/x.jpg"
	r := mlNew(t, []string{bad, linked}, nil)
	r.in.ref = "mrwnotnet"
	r.maxWait = 2
	if err := os.MkdirAll(filepath.Join(r.in.dest, "DCIM"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(t.TempDir(), filepath.Join(r.in.dest, "DCIM", "linked")); err != nil {
		t.Fatal(err)
	}
	r.hook = func(rel string) ([]byte, error, bool) {
		if rel == bad {
			return nil, errors.New("fetch span [0,1): corrupt chunk in store: blob/c0"), true
		}
		return nil, nil, false
	}
	ev := mrwEvents(r)
	c := r.land()
	if want := []string{"park:false", "sleep", "park:false", "sleep"}; !slices.Equal(*ev, want) {
		t.Fatalf("events %v, want %v", *ev, want)
	}
	if slices.Contains(r.fetched, linked) {
		t.Fatal("a rel behind a link was fetched")
	}
	mlWant(t, r.damaged, []string{bad}, "onDamaged")
	if c.pending != 1 || c.landed != 0 {
		t.Fatalf("counts: %+v", c)
	}
}

// Line: RESTORE-WAITING follows the unchanged RESTORING line, only while the lander waits and files are left.
func TestMediaRestoreWaitLine(t *testing.T) {
	s, _ := mbrProg(t)
	s.setRestoring(10, 100, 3)
	s.setRestoreWaiting(true)
	if got := mbrReadProg(t, s); got != "RESTORING 10 100 3\nRESTORE-WAITING\n" {
		t.Fatalf("waiting: %q", got)
	}
	s.setRestoreWaiting(false)
	if got := mbrReadProg(t, s); got != "RESTORING 10 100 3\n" {
		t.Fatalf("not waiting: %q", got)
	}

	s.setRestoreWaiting(true)
	s.progMu.Lock()
	s.dmg = map[string]string{"j": "bad.jpg"}
	s.progMu.Unlock()
	s.setRestoring(100, 100, 0)
	if got := mbrReadProg(t, s); got != "DAMAGED 1 bad.jpg\n" {
		t.Fatalf("left 0 must drop both lines: %q", got)
	}
	s.progMu.Lock()
	s.dmg = nil
	s.progMu.Unlock()
	s.setRestoreWaiting(true)
	if _, err := os.Stat(s.progPath); !os.IsNotExist(err) {
		t.Fatalf("waiting with nothing left must not keep the file: %v", err)
	}

	quiet := &mediaServer{}
	quiet.setRestoreWaiting(true) // progPath "": publishes nothing
	if quiet.restoring.waiting {
		t.Fatal("a server with no progress path must hold nothing")
	}
}

// BgLander: a wired lander shows RESTORE-WAITING while parked and loses it when a file lands; after Stop it says
// nothing more.
func TestMediaRestoreWaitBgLander(t *testing.T) {
	r, a, b := mrwTwoRels(t, "mrwbglander")
	s, state := mbrProg(t)
	l := newBgLander(state, r.in.dest, nil, r.m, s)
	in := l.wire(r.in)
	read := func() string { got, _ := os.ReadFile(s.progPath); return string(got) }
	var snaps []string
	n := 0
	in.sleep = func(time.Duration) bool {
		n++
		snaps = append(snaps, read())
		return n < 2
	}
	var afterLanding string
	in.fetch = func(_ string, _ []byte, _ chunkManifest, reg essRegion) ([]byte, error) {
		rel := r.rels[reg.S]
		if rel == a && n >= 1 {
			return mlFrag(t, rel, mlBody(rel), 0o640, time.Unix(1700000000, 0)), nil
		}
		if rel == b && n >= 1 {
			afterLanding = read()
		}
		return nil, errors.New("connection refused")
	}
	captureStdout(t, func() { landBackground(in, r.m) })
	l.finish()

	total := r.m.Ess[a].Size + r.m.Ess[b].Size
	if len(snaps) != 2 {
		t.Fatalf("sleeps: %d", len(snaps))
	}
	if want := fmt.Sprintf("RESTORING 0 %d 2\nRESTORE-WAITING\n", total); snaps[0] != want {
		t.Fatalf("parked: %q, want %q", snaps[0], want)
	}
	if want := fmt.Sprintf("RESTORING %d %d 1\n", r.m.Ess[a].Size, total); afterLanding != want || snaps[1] != want {
		t.Fatalf("after the landing: %q and %q, want %q", afterLanding, snaps[1], want)
	}
	if _, err := os.Stat(s.progPath); !os.IsNotExist(err) {
		t.Fatalf("the end of the run must remove the file: %v", err)
	}

	s2, state2 := mbrProg(t)
	l2 := newBgLander(state2, r.in.dest, nil, r.m, s2)
	l2.onStart([]string{a})
	l2.onPark(true)
	parked := mbrReadProg(t, s2)
	l2.Stop()
	if l2.parked {
		t.Fatal("Stop must clear the parked state")
	}
	l2.onPark(false)
	if got := mbrReadProg(t, s2); got != parked {
		t.Fatalf("after Stop the lander publishes nothing: %q, was %q", got, parked)
	}
}
