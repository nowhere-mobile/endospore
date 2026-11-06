package main

import (
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261115-06: capFlush's lease leg writes a "sizes" progress line before each /lease request of a flush that
// needs more than one batch, so runWorkerHeld's stall rule (a CHANGE in roam.progress within roamStallBudget) sees
// the gateway leg. A flush that fits one batch writes nothing new. test-capflush-lease-progress.sh --mutate breaks
// each of those in turn.
//
// NWP-20261117-10: while a /lease request is in flight, the lease leg re-writes its line every leaseBeat, scaled so
// the line CHANGES and the fraction does not. The slow cases below shrink leaseBeat; every case that asserts NO beat
// runs at the default leaseBeat, so no scheduler stall on a one-CPU lane can make one.

// leaseProgFixture points NOWHERE_PROGRESS at a fresh file and restores the progress phase and scope after the
// test. It returns a reader for the file's line ("" when absent).
func leaseProgFixture(t *testing.T) func() string {
	t.Helper()
	file := filepath.Join(t.TempDir(), "roam.progress")
	t.Setenv("NOWHERE_PROGRESS", file)
	wasPhase, _ := progPhase.Load().(string)
	wasScope, _ := progScope.Load().(string)
	t.Cleanup(func() {
		setProgPhase(wasPhase)
		setProgScope(wasScope)
	})
	return func() string {
		b, err := os.ReadFile(file)
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(b))
	}
}

// leaseProgRecorder records the progress line read at the start of each /lease request (the handler runs on the
// server goroutine while capFlush waits for its reply).
type leaseProgRecorder struct {
	mu    sync.Mutex
	lines []string
	read  func() string
}

func (r *leaseProgRecorder) rec() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lines = append(r.lines, r.read())
}

func (r *leaseProgRecorder) got() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.lines...)
}

func leaseProgPhase(line string) string {
	if f := strings.Fields(line); len(f) > 0 {
		return f[0]
	}
	return ""
}

// leaseProgEachDiffers fails the test when a line equals the line read at the request before it.
func leaseProgEachDiffers(t *testing.T, lines []string) {
	t.Helper()
	for i := 1; i < len(lines); i++ {
		if lines[i] == lines[i-1] {
			t.Errorf("request %d read %q, the same line as request %d: the stall watchdog sees no change (all: %q)", i, lines[i], i-1, lines)
		}
	}
}

// L1: three free batches, each answered 200. Each request reads a new "sizes" line, the first is not the flush's
// `save 0 <total>`, and the phase is "save" again once the flush ends.
func TestCapFlushLeaseProgress_EachFreeBatchWritesALine(t *testing.T) {
	read := leaseProgFixture(t)
	r := &leaseProgRecorder{read: read}
	g := newBatchGateway(t)
	g.free = func(int, leaseReq) (int, string) { r.rec(); return http.StatusOK, "" }
	freeFixture(t, g, 3)
	if rec := batchSeal(t, "cflpfreethree", "three free lease batches", 5, nil, nil); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	lines := r.got()
	if len(lines) != 3 {
		t.Fatalf("%d free /lease requests for 8 refs at leaseBatchRefs=3, want 3 (lines %q)", len(lines), lines)
	}
	for i, l := range lines {
		if leaseProgPhase(l) != "sizes" {
			t.Errorf("free request %d read %q, want a \"sizes\" line written before it", i, l)
		}
	}
	if strings.HasPrefix(lines[0], "save 0 ") {
		t.Errorf("free request 0 read %q, the flush's own opening line: nothing was written before the request", lines[0])
	}
	leaseProgEachDiffers(t, lines)
	if end := read(); leaseProgPhase(end) != "save" {
		t.Errorf("after the flush the line is %q, want phase \"save\": the lease leg did not restore the phase", end)
	}
}

// L2: free batch 0 answers 200, free batch 1 answers 402, then the entitled arm leases the flush in 3 batches.
// Each of the 5 requests reads a line that differs from the one before it.
func TestCapFlushLeaseProgress_AFree402ThenEntitledBatchesEachWriteALine(t *testing.T) {
	read := leaseProgFixture(t)
	r := &leaseProgRecorder{read: read}
	g := newBatchGateway(t)
	g.free = func(i int, _ leaseReq) (int, string) {
		r.rec()
		if i == 1 {
			return http.StatusPaymentRequired, `{"error":"over the free allowance"}`
		}
		return http.StatusOK, ""
	}
	g.reply = func(int, leaseReq) (int, string) { r.rec(); return 0, "" }
	freeFixture(t, g, 3)
	if rec := batchSeal(t, "cflpfree402", "the second free batch is over", 5, nil, nil); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	lines := r.got()
	if len(lines) != 5 {
		t.Fatalf("%d /lease requests, want 5 (2 free, 3 entitled) (lines %q)", len(lines), lines)
	}
	for i, l := range lines {
		if leaseProgPhase(l) != "sizes" {
			t.Errorf("request %d read %q, want a \"sizes\" line written before it", i, l)
		}
	}
	leaseProgEachDiffers(t, lines)
	if end := read(); leaseProgPhase(end) != "save" {
		t.Errorf("after the flush the line is %q, want phase \"save\"", end)
	}
}

// L3: a flush that fits one batch (the default leaseBatchRefs) writes no "sizes" line: it writes what it wrote
// before the lease leg reported progress.
func TestCapFlushLeaseProgress_AOneBatchFlushWritesNoSizesLine(t *testing.T) {
	read := leaseProgFixture(t)
	r := &leaseProgRecorder{read: read}
	g := newBatchGateway(t)
	g.free = func(int, leaseReq) (int, string) { r.rec(); return http.StatusOK, "" }
	freeFixture(t, g, 0)
	if rec := batchSeal(t, "cflponebatch", "one free lease batch", 5, nil, nil); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	lines := r.got()
	if len(lines) != 1 {
		t.Fatalf("%d free /lease requests at the default leaseBatchRefs, want 1 (lines %q)", len(lines), lines)
	}
	for i, l := range append(lines, read()) {
		if leaseProgPhase(l) == "sizes" {
			t.Errorf("line %d is %q: a one-batch flush wrote a \"sizes\" line", i, l)
		}
	}
}

// leaseProgGuard bounds every wait of the heartbeat cases. A missing heartbeat fails a case by running into it,
// never by a tight upper bound on wall time.
const leaseProgGuard = 5 * time.Second

// withLeaseBeat shrinks leaseBeat for one test and restores it after.
func withLeaseBeat(t *testing.T, d time.Duration) {
	t.Helper()
	was := leaseBeat
	leaseBeat = d
	t.Cleanup(func() { leaseBeat = was })
}

// leaseProgFrac parses a progress line's done and total fields.
func leaseProgFrac(line string) (d, tot int, ok bool) {
	f := strings.Fields(line)
	if len(f) < 3 {
		return 0, 0, false
	}
	d, e1 := strconv.Atoi(f[1])
	tot, e2 := strconv.Atoi(f[2])
	return d, tot, e1 == nil && e2 == nil && tot > 0
}

// leaseProgSameFrac reports whether two lines carry the same done/total fraction.
func leaseProgSameFrac(a, b string) bool {
	da, ta, okA := leaseProgFrac(a)
	db, tb, okB := leaseProgFrac(b)
	return okA && okB && da*tb == db*ta
}

// leaseProgHold polls the progress line every 2 ms and collects each line that differs from the last one
// collected, in order, until want accepts them or the guard passes. It runs on the gateway's handler goroutine and
// holds the /lease reply while it polls; on the guard it reports the failure and returns, so the reply still goes.
func leaseProgHold(t *testing.T, read func() string, want func(seen []string) bool) []string {
	var seen []string
	deadline := time.Now().Add(leaseProgGuard)
	for {
		if l := read(); len(seen) == 0 || l != seen[len(seen)-1] {
			seen = append(seen, l)
		}
		if want(seen) {
			return seen
		}
		if time.Now().After(deadline) {
			t.Errorf("a /lease request held for %v read only %q: no heartbeat line came", leaseProgGuard, seen)
			return seen
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// H-a: three free batches, each held until the progress file has shown 3 distinct lines. Every line a request sees
// is "sizes" at the fraction of the line written at its start, and the flush completes.
func TestCapFlushLeaseProgress_AMultiBatchRequestInFlightBeats(t *testing.T) {
	read := leaseProgFixture(t)
	withLeaseBeat(t, 20*time.Millisecond)
	var mu sync.Mutex
	var held [][]string
	g := newBatchGateway(t)
	g.free = func(int, leaseReq) (int, string) {
		seen := leaseProgHold(t, read, func(s []string) bool { return len(s) >= 3 })
		mu.Lock()
		held = append(held, seen)
		mu.Unlock()
		return http.StatusOK, ""
	}
	freeFixture(t, g, 3)
	if rec := batchSeal(t, "cflpbeatmulti", "three slow free lease batches", 5, nil, nil); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(held) != 3 {
		t.Fatalf("%d free /lease requests for 8 refs at leaseBatchRefs=3, want 3 (lines %q)", len(held), held)
	}
	for i, seen := range held {
		if len(seen) != 3 {
			t.Errorf("free request %d saw %d distinct lines, want 3: %q", i, len(seen), seen)
			continue
		}
		for _, l := range seen {
			if leaseProgPhase(l) != "sizes" {
				t.Errorf("free request %d read %q while in flight, want a \"sizes\" line (all: %q)", i, l, seen)
			}
			if !leaseProgSameFrac(l, seen[0]) {
				t.Errorf("free request %d read %q, a fraction other than its start line %q: the beat moved the bar", i, l, seen[0])
			}
		}
	}
	if end := read(); leaseProgPhase(end) != "save" {
		t.Errorf("after the flush the line is %q, want phase \"save\": a beat did not restore the phase", end)
	}
}

// H-b: a flush that fits one batch (leaseProg OFF), its one request held until 3 distinct lines. The beats read
// "sizes m m" with m = 2, 3, ... rising; a slow poller may miss a beat, so no exact m is required.
func TestCapFlushLeaseProgress_AOneBatchSlowRequestBeats(t *testing.T) {
	read := leaseProgFixture(t)
	withLeaseBeat(t, 20*time.Millisecond)
	var mu sync.Mutex
	var held [][]string
	g := newBatchGateway(t)
	g.free = func(int, leaseReq) (int, string) {
		seen := leaseProgHold(t, read, func(s []string) bool { return len(s) >= 3 })
		mu.Lock()
		held = append(held, seen)
		mu.Unlock()
		return http.StatusOK, ""
	}
	freeFixture(t, g, 0)
	if rec := batchSeal(t, "cflpbeatone", "one slow free lease batch", 5, nil, nil); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(held) != 1 {
		t.Fatalf("%d free /lease requests at the default leaseBatchRefs, want 1 (lines %q)", len(held), held)
	}
	seen, last, beats := held[0], 1, 0
	for _, l := range seen {
		if l == "" || strings.HasPrefix(l, "save 0 ") {
			continue // the flush's opening line, read before the first beat
		}
		f := strings.Fields(l)
		d, tot, ok := leaseProgFrac(l)
		if f[0] != "sizes" || !ok || d != tot || d <= last {
			t.Errorf("the request read %q while in flight, want \"sizes m m\" with m above %d (all: %q)", l, last, seen)
			continue
		}
		last, beats = d, beats+1
	}
	if beats < 2 {
		t.Errorf("the request saw %d heartbeat lines, want at least 2 (all: %q)", beats, seen)
	}
	if end := read(); leaseProgPhase(end) != "save" {
		t.Errorf("after the flush the line is %q, want phase \"save\"", end)
	}
}

// H-c: no beat follows the reply. The tick source is replaced by unbuffered channels the test steps by hand, at the
// default leaseBeat: one tick inside the request makes "sizes 2 2"; after capFlush returns, a tick offered for 1 s
// to each heartbeat must find no taker, and every tick source must have been stopped.
func TestCapFlushLeaseProgress_NoBeatAfterTheReply(t *testing.T) {
	read := leaseProgFixture(t)
	var mu sync.Mutex
	var ticks []chan time.Time
	stops := 0
	was := leaseBeatTicker
	leaseBeatTicker = func(time.Duration) (<-chan time.Time, func()) {
		c := make(chan time.Time)
		mu.Lock()
		ticks = append(ticks, c)
		mu.Unlock()
		return c, func() { mu.Lock(); stops++; mu.Unlock() }
	}
	t.Cleanup(func() { leaseBeatTicker = was })
	g := newBatchGateway(t)
	g.free = func(int, leaseReq) (int, string) {
		var c chan time.Time
		for deadline := time.Now().Add(leaseProgGuard); c == nil && time.Now().Before(deadline); time.Sleep(2 * time.Millisecond) {
			mu.Lock()
			if len(ticks) > 0 {
				c = ticks[0]
			}
			mu.Unlock()
		}
		if c == nil {
			t.Errorf("no heartbeat tick source was made for a /lease request in flight")
			return http.StatusOK, ""
		}
		select {
		case c <- time.Now():
		case <-time.After(leaseProgGuard):
			t.Errorf("the heartbeat took no tick while its /lease request was in flight")
			return http.StatusOK, ""
		}
		leaseProgHold(t, read, func(s []string) bool {
			f := strings.Fields(s[len(s)-1])
			return len(f) >= 3 && f[0] == "sizes" && f[1] == "2" && f[2] == "2"
		})
		return http.StatusOK, ""
	}
	freeFixture(t, g, 0)
	if rec := batchSeal(t, "cflpbeatafter", "no beat after the reply", 5, nil, nil); rec != nil {
		t.Fatalf("the flush failed: %v", rec)
	}
	l0 := read()
	mu.Lock()
	cs := append([]chan time.Time(nil), ticks...)
	mu.Unlock()
	if len(cs) == 0 {
		t.Fatalf("no heartbeat ran for the flush's /lease request")
	}
	for i, c := range cs {
		select {
		case c <- time.Now():
			t.Errorf("heartbeat %d took a tick after capFlush returned: it outlived its request", i)
		case <-time.After(time.Second):
		}
	}
	if l := read(); l != l0 {
		t.Errorf("the line changed from %q to %q after capFlush returned: a beat followed the reply", l0, l)
	}
	mu.Lock()
	defer mu.Unlock()
	if stops != len(cs) {
		t.Errorf("%d of %d heartbeat tick sources were stopped", stops, len(cs))
	}
}

// H-d: every /lease request with a line before it runs inside lprog.during, the entitled ones included (the cases
// above go through the free arm only). After each lprog.before() line, an lprog.during(func() { line comes before
// the first line that calls the lease.
func TestCapFlushLeaseProgress_EveryLeaseRequestRunsInDuring(t *testing.T) {
	body := funcBody(t, agentSources(t)["main.go"], "capFlush")
	befores, durings := 0, 0
	for i, l := range body {
		switch strings.TrimSpace(l) {
		case "lprog.during(func() {":
			durings++
		case "lprog.before()":
			befores++
			wrapped := false
			call := -1
			for j := i + 1; j < len(body); j++ {
				s := strings.TrimSpace(body[j])
				if strings.Contains(s, "gw.leaseFreeExpire(") || strings.Contains(s, "gw.leaseEntitledExpire(") {
					call = j
					break
				}
				if s == "lprog.during(func() {" {
					wrapped = true
				}
			}
			switch {
			case call < 0:
				t.Errorf("capFlush line %d: no /lease call follows its lprog.before()", i)
			case !wrapped:
				t.Errorf("capFlush line %d: the /lease call at line %d runs outside lprog.during, so it has no heartbeat: %q",
					i, call, strings.TrimSpace(body[call]))
			}
		}
	}
	if befores != 5 || durings != 5 {
		t.Errorf("capFlush has %d lprog.before() and %d lprog.during(func() { lines, want 5 and 5", befores, durings)
	}
}
