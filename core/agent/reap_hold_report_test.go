package main

import (
	"strconv"
	"strings"
	"testing"
	"time"
)

// NWP-20261204-21 (Q039, docs/product-decisions.md 2026-10-20): every cleanstorage op's RW-lane hold, and the slot wait
// of a sign-in that queued behind one, reach every issue report as bucketed counts. These cases drive
// triggerRoamWorkerKind through the fake init of lost_start_recovery_test.go (lsrFakeInit), so none may run in parallel.

// resetReapHold zeroes both daemon-lifetime histograms for a test and again when it ends.
func resetReapHold(t *testing.T) {
	t.Helper()
	reapHold.reset()
	signinWaitBehindReap.reset()
	t.Cleanup(func() {
		reapHold.reset()
		signinWaitBehindReap.reset()
	})
}

// rhRun runs op through triggerRoamWorkerKind with a 10 s bound. uid "" keeps the `out` clobber guard out of the way.
func rhRun(t *testing.T, f *lsrInit, op, pass string) string {
	t.Helper()
	ch := make(chan string, 1)
	go func() { ch <- triggerRoamWorkerKind(f.dest, op, "p", pass, "", "", "", "", "", nil) }()
	select {
	case out := <-ch:
		return out
	case <-time.After(10 * time.Second):
		t.Fatalf("op %q did not return within 10s", op)
		return ""
	}
}

// rhMaxMs reads max_ms out of a histogram value.
func rhMaxMs(t *testing.T, v string) int64 {
	t.Helper()
	i := strings.LastIndex(v, " max_ms=")
	if i < 0 {
		t.Fatalf("no max_ms in %q", v)
	}
	n, err := strconv.ParseInt(v[i+len(" max_ms="):], 10, 64)
	if err != nil {
		t.Fatalf("max_ms in %q: %v", v, err)
	}
	return n
}

const rhEmpty = "n=0 lt1s=0 1to5s=0 5to20s=0 ge20s=0 max_ms=0"

func TestReapHoldBuckets(t *testing.T) {
	var h holdHistogram
	if got := h.value(); got != rhEmpty {
		t.Fatalf("empty histogram = %q, want %q", got, rhEmpty)
	}
	for _, ms := range []int64{0, 999, 1000, 4999, 5000, 19999, 20000, 31000} {
		h.add(ms)
	}
	if got, want := h.value(), "n=8 lt1s=2 1to5s=2 5to20s=2 ge20s=2 max_ms=31000"; got != want {
		t.Fatalf("histogram = %q, want %q (a value equal to a boundary goes UP)", got, want)
	}
	h.reset()
	if got := h.value(); got != rhEmpty {
		t.Fatalf("after reset = %q, want %q", got, rhEmpty)
	}
}

func TestReapHoldNegativeClamps(t *testing.T) {
	var h holdHistogram
	h.add(-5)
	if got, want := h.value(), "n=1 lt1s=1 1to5s=0 5to20s=0 ge20s=0 max_ms=0"; got != want {
		t.Fatalf("a negative hold = %q, want %q", got, want)
	}
}

// TestReapHoldRecordsEveryReap: a cleanstorage op's hold is recorded although it is far under the 2 s that the HELD
// log line needs.
func TestReapHoldRecordsEveryReap(t *testing.T) {
	rwLaneFree(t)
	resetReapHold(t)
	f := lsrFakeInit(t, laneRW, lsrStates("stopped"),
		[]lsrPlan{{kind: lsrAnswer, text: "OK", after: 5 * time.Millisecond}})
	if out := rhRun(t, f, "cleanstorage", ""); out != "OK" {
		t.Fatalf("control: cleanstorage answered %q, want the stand-in's OK", out)
	}
	got := reapHold.value()
	if !strings.HasPrefix(got, "n=1 lt1s=1 1to5s=0 5to20s=0 ge20s=0 ") || rhMaxMs(t, got) >= 1000 {
		t.Errorf("reapHold = %q after one short reap, want n=1 in lt1s with max_ms < 1000", got)
	}
	if got := signinWaitBehindReap.value(); got != rhEmpty {
		t.Errorf("signinWaitBehindReap = %q after a reap alone, want %q", got, rhEmpty)
	}
}

// TestReapHoldIgnoresOtherOps: an op that is not cleanstorage records no reap hold.
func TestReapHoldIgnoresOtherOps(t *testing.T) {
	rwLaneFree(t)
	resetReapHold(t)
	f := lsrFakeInit(t, laneRW, lsrStates("stopped"),
		[]lsrPlan{{kind: lsrAnswer, text: "OK", after: 5 * time.Millisecond}})
	rhRun(t, f, "out", "")
	if got := reapHold.value(); got != rhEmpty {
		t.Errorf("reapHold = %q after an out op, want %q", got, rhEmpty)
	}
}

// rhSigninBehind runs an `in` op while holder holds the RW lane ("" = a free lane) and returns signinWaitBehindReap.
// The holder is cleared before the slot is released, in the order of the real release, so the in op's read can only
// have seen holder if it read BEFORE it queued.
func rhSigninBehind(t *testing.T, holder string) string {
	t.Helper()
	rwLaneFree(t)
	resetReapHold(t)
	prevWaiting := userOpWaiting.Load()
	userOpWaiting.Store(0)
	t.Cleanup(func() { userOpWaiting.Store(prevWaiting) })
	if holder != "" {
		laneRW.slot <- struct{}{}
		setRWHolder(holder)
	}
	f := lsrFakeInit(t, laneRW, lsrStates("stopped"),
		[]lsrPlan{{kind: lsrAnswer, text: "OK 10", after: 5 * time.Millisecond}})
	ch := make(chan string, 1)
	go func() { ch <- triggerRoamWorkerKind(f.dest, "in", "p", "pw", "", "", "", "", "", nil) }()
	if holder != "" {
		deadline := time.Now().Add(5 * time.Second)
		for userOpWaiting.Load() <= 0 {
			if time.Now().After(deadline) {
				setRWHolder("")
				<-laneRW.slot
				t.Fatal("the in op never queued (userOpWaiting stayed 0 for 5s)")
			}
			time.Sleep(time.Millisecond)
		}
		time.Sleep(20 * time.Millisecond) // a wait well above zero, with the in op parked on the send
		setRWHolder("")
		<-laneRW.slot
	}
	select {
	case out := <-ch:
		if out != "OK 10" {
			t.Fatalf("control: the in op answered %q, want the stand-in's OK 10", out)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the in op did not return within 10s")
	}
	if got := reapHold.value(); got != rhEmpty {
		t.Errorf("reapHold = %q, want %q: no cleanstorage ran through triggerRoamWorkerKind", got, rhEmpty)
	}
	return signinWaitBehindReap.value()
}

func TestReapHoldSigninBehindReap(t *testing.T) {
	got := rhSigninBehind(t, "cleanstorage")
	if !strings.HasPrefix(got, "n=1 lt1s=1 1to5s=0 5to20s=0 ge20s=0 ") || rhMaxMs(t, got) < 20 {
		t.Errorf("signinWaitBehindReap = %q for a sign-in that queued behind a reap for 20ms, want n=1 in lt1s with max_ms >= 20", got)
	}
}

func TestReapHoldSigninBehindOtherOp(t *testing.T) {
	if got := rhSigninBehind(t, "out"); got != rhEmpty {
		t.Errorf("signinWaitBehindReap = %q for a sign-in that queued behind an out op, want %q", got, rhEmpty)
	}
}

func TestReapHoldSigninOnFreeLane(t *testing.T) {
	if got := rhSigninBehind(t, ""); got != rhEmpty {
		t.Errorf("signinWaitBehindReap = %q for a sign-in on a free lane, want %q", got, rhEmpty)
	}
}

// TestIssueReportCarriesReapHold: both keys reach the report at BOTH scopes, exactly (so they skip statusValue).
func TestIssueReportCarriesReapHold(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	resetReapHold(t)
	reapHold.add(1500)
	signinWaitBehindReap.add(25000)
	want := map[string]string{
		"reap_lane_hold":          "n=1 lt1s=0 1to5s=1 5to20s=0 ge20s=0 max_ms=1500",
		"signin_wait_behind_reap": "n=1 lt1s=0 1to5s=0 5to20s=0 ge20s=1 max_ms=25000",
	}
	for _, c := range []struct {
		name  string
		scope bool
	}{{"", true}, {"x", false}} {
		rep := buildIssueReport(c.name, c.scope, "", nil, nil)
		for k, w := range want {
			if got, ok := rep.Status[k]; !ok || got != w {
				t.Errorf("deviceScope=%v: status %s = %q (present=%v), want %q", c.scope, k, got, ok, w)
			}
		}
	}
}
