package main

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// NWP-20261129-36: GET-COLDLOCK logs what it answered around a cold lock, so a report can tell "asked during the wait
// and never again" from "never asked" from "asked after the commit". Logging only: every reply here is compared byte
// for byte with what the verb answered before this slice.

const (
	gcltNoneLine  = "answered NONE while"
	gcltOfferLine = "offered user "
	gcltName      = "gcltprofile"
)

// gcltSetup returns a temp dest with no marker, with every global a test here changes restored on cleanup and the
// trace cleared. The users dir is absent, so the gone-user rule does not apply on any host.
func gcltSetup(t *testing.T) string {
	t.Helper()
	tr := &getColdLockTrace
	coldLockMu.Lock()
	running, uid, starts := coldLockRunning, coldLockUID, coldLockStarts
	coldLockMu.Unlock()
	waitSince := coldLockWaitSince.Load()
	waitFor, _ := coldLockWaitFor.Load().(string)
	holder, _ := rwHolderOp.Load().(string)
	usersDir := androidUsersDir
	tr.mu.Lock()
	trStarts, trNoneUID, trNones, trOffers, trFirstMs := tr.starts, tr.noneUID, tr.nones, tr.offers, tr.firstMs
	tr.starts, tr.noneUID, tr.nones, tr.offers, tr.firstMs = 0, "", 0, 0, 0
	tr.mu.Unlock()
	t.Cleanup(func() {
		coldLockMu.Lock()
		coldLockRunning, coldLockUID, coldLockStarts = running, uid, starts
		coldLockMu.Unlock()
		coldLockWaitSince.Store(waitSince)
		coldLockWaitFor.Store(waitFor)
		setRWHolder(holder)
		androidUsersDir = usersDir
		tr.mu.Lock()
		tr.starts, tr.noneUID, tr.nones, tr.offers, tr.firstMs = trStarts, trNoneUID, trNones, trOffers, trFirstMs
		tr.mu.Unlock()
	})
	androidUsersDir = filepath.Join(t.TempDir(), "absent")
	coldLockWaitSince.Store(0)
	coldLockWaitFor.Store("")
	setRWHolder("")
	return t.TempDir()
}

// gcltLock puts a teardown for uid in flight as handleColdLock does: a new coldLockStarts value, not queued.
func gcltLock(uid string) {
	coldLockMu.Lock()
	coldLockRunning, coldLockUID = true, uid
	coldLockStarts++
	coldLockMu.Unlock()
	coldLockWaitSince.Store(0)
	setRWHolder("")
}

// gcltEndLock ends the running teardown as coldLockNext does. coldLockStarts keeps its value.
func gcltEndLock() {
	coldLockMu.Lock()
	coldLockRunning, coldLockUID = false, ""
	coldLockMu.Unlock()
}

func gcltMarker(t *testing.T, dest, uid string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dest, ".coldlock"), []byte(gcltMarkerText(uid)), 0o600); err != nil {
		t.Fatal(err)
	}
}

// gcltAsk calls handleGetColdLock over net.Pipe and returns the whole reply. The handler has returned by then.
func gcltAsk(t *testing.T, dest string) string {
	t.Helper()
	client, server := net.Pipe()
	defer client.Close()
	go func() {
		defer server.Close()
		handleGetColdLock(server, dest)
	}()
	b, err := io.ReadAll(client)
	if err != nil {
		t.Errorf("reading the GET-COLDLOCK reply: %v", err) // not Fatalf: gcltAskConcurrent calls this off the test goroutine
	}
	return string(b)
}

// gcltAskPaused starts a GET-COLDLOCK and leaves it paused in its marker read, its lock state already read. The marker
// is a FIFO: the handler's open of it comes after that read, and the write end's open returns only once the handler
// has opened it. The FIFO then leaves dest, so other calls find no marker. The returned func hands the paused read
// contents and returns the paused call's reply, the handler having returned.
func gcltAskPaused(t *testing.T, dest string) func(contents string) string {
	t.Helper()
	marker := filepath.Join(dest, ".coldlock")
	if err := syscall.Mkfifo(marker, 0o600); err != nil {
		t.Fatal(err)
	}
	client, server := net.Pipe()
	reply := make(chan string, 1)
	go func() {
		defer server.Close()
		handleGetColdLock(server, dest)
	}()
	go func() {
		defer client.Close()
		b, _ := io.ReadAll(client)
		reply <- string(b)
	}()
	w, err := os.OpenFile(marker, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { w.Close() }) // a test that stops early still lets the paused call end
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	return func(contents string) string {
		t.Helper()
		if _, err := w.WriteString(contents); err != nil {
			t.Fatal(err)
		}
		if err := w.Close(); err != nil {
			t.Fatal(err)
		}
		return <-reply
	}
}

// gcltAskConcurrent makes n GET-COLDLOCK calls at one time, requires the reply of each, and returns what they logged.
func gcltAskConcurrent(t *testing.T, dest string, n int, want string) string {
	t.Helper()
	return captureStderr(t, func() {
		var wg sync.WaitGroup
		for i := 0; i < n; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if got := gcltAsk(t, dest); got != want {
					t.Errorf("a concurrent call replied %q, want %q", got, want)
				}
			}()
		}
		wg.Wait()
	})
}

// gcltMarkerText is what gcltMarker writes for uid.
func gcltMarkerText(uid string) string {
	return gcltName + "\n" + uid + "\n\nnokey\nnopin\nWRAP\n\n"
}

// gcltAskFor calls GET-COLDLOCK n times, requires the reply each time, and returns what they logged.
func gcltAskFor(t *testing.T, dest string, n int, want string) string {
	t.Helper()
	return captureStderr(t, func() {
		for i := 0; i < n; i++ {
			if got := gcltAsk(t, dest); got != want {
				t.Errorf("call %d of %d replied %q, want %q", i+1, n, got, want)
			}
		}
	})
}

// gcltLines returns the lines of log that hold marker.
func gcltLines(log, marker string) []string {
	var out []string
	for _, ln := range strings.Split(log, "\n") {
		if strings.Contains(ln, marker) {
			out = append(out, ln)
		}
	}
	return out
}

// (a) then (e), in one test because (e)'s count is (a)'s.
func TestGetColdLockTrace_NoneOnceThenFirstThreeOffers(t *testing.T) {
	dest := gcltSetup(t)
	gcltLock("12")
	log := gcltAskFor(t, dest, 2, "NONE\n")
	nones := gcltLines(log, gcltNoneLine)
	if len(nones) != 1 {
		t.Errorf("two NONE answers for one lock logged %d NONE lines, want 1:\n%s", len(nones), log)
	} else if !strings.Contains(nones[0], "the cold lock of user 12 ") || !strings.Contains(nones[0], "(LOCKING)") {
		t.Errorf("the NONE line does not name user 12 and LOCKING: %q", nones[0])
	}

	gcltMarker(t, dest, "12")
	log = gcltAskFor(t, dest, 4, "COLDLOCK 12 nokey nopin "+gcltName+"\n")
	offers := gcltLines(log, gcltOfferLine)
	if len(offers) != 3 {
		t.Fatalf("four COLDLOCK answers logged %d offered lines, want 3:\n%s", len(offers), log)
	}
	if strings.Contains(log, gcltName) {
		t.Errorf("the log carries the profile name:\n%s", log)
	}
	if strings.Contains(log, gcltNoneLine) {
		t.Errorf("a COLDLOCK answer logged the NONE line:\n%s", log)
	}
	for i, ln := range offers {
		for _, want := range []string{
			"offered user 12 for resume",
			"answer " + string(rune('1'+i)) + " of the first 3",
			"2 NONE answer(s)",
		} {
			if !strings.Contains(ln, want) {
				t.Errorf("offered line %d lacks %q: %q", i+1, want, ln)
			}
		}
	}
	if !strings.Contains(offers[0], "(+0s after answer 1;") {
		t.Errorf("answer 1 does not carry +0s: %q", offers[0])
	}
	seconds := regexp.MustCompile(`\(\+\d+s after answer 1;`)
	for _, ln := range offers[1:] {
		if !seconds.MatchString(ln) {
			t.Errorf("a later answer carries no number of seconds: %q", ln)
		}
	}
}

// (b) A teardown queued behind a seal says what it waits for.
func TestGetColdLockTrace_NoneLineCarriesTheWait(t *testing.T) {
	dest := gcltSetup(t)
	gcltLock("12")
	coldLockWaitSince.Store(time.Now().UnixMilli() - 31_000)
	setRWHolder("out")
	log := gcltAskFor(t, dest, 1, "NONE\n")
	nones := gcltLines(log, gcltNoneLine)
	if len(nones) != 1 || !strings.Contains(nones[0], "(WAITING out ") {
		t.Fatalf("want one NONE line carrying WAITING out:\n%s", log)
	}
}

// (c) A new coldLockStarts value is a new lock, so it gets a NONE line of its own.
func TestGetColdLockTrace_NewLockLogsNoneAgain(t *testing.T) {
	dest := gcltSetup(t)
	gcltLock("12")
	if n := len(gcltLines(gcltAskFor(t, dest, 2, "NONE\n"), gcltNoneLine)); n != 1 {
		t.Fatalf("the first lock logged %d NONE lines, want 1", n)
	}
	gcltLock("12")
	if n := len(gcltLines(gcltAskFor(t, dest, 2, "NONE\n"), gcltNoneLine)); n != 1 {
		t.Fatalf("the second lock logged %d NONE lines, want 1", n)
	}
}

// (d) With no teardown running, a NONE says nothing: it is the answer at almost every reveal.
func TestGetColdLockTrace_NoTeardownNoLine(t *testing.T) {
	dest := gcltSetup(t)
	coldLockMu.Lock()
	coldLockRunning, coldLockUID = false, ""
	coldLockStarts++
	coldLockMu.Unlock()
	if log := gcltAskFor(t, dest, 2, "NONE\n"); strings.Contains(log, "GET-COLDLOCK:") {
		t.Fatalf("a NONE with no teardown running logged:\n%s", log)
	}
}

// (f) A lock that answered no NONE still logs its offers, and a new lock starts its answers and its NONE count again.
func TestGetColdLockTrace_OfferWithNoNoneCountsZero(t *testing.T) {
	dest := gcltSetup(t)
	gcltLock("12")
	gcltAskFor(t, dest, 1, "NONE\n")
	gcltMarker(t, dest, "12")
	want := "COLDLOCK 12 nokey nopin " + gcltName + "\n"
	gcltAskFor(t, dest, 3, want)
	if err := os.Remove(filepath.Join(dest, ".coldlock")); err != nil {
		t.Fatal(err)
	}
	gcltEndLock()

	gcltLock("12")
	gcltMarker(t, dest, "12")
	log := gcltAskFor(t, dest, 1, want)
	offers := gcltLines(log, gcltOfferLine)
	if len(offers) != 1 {
		t.Fatalf("a lock that answered no NONE logged %d offered lines, want 1:\n%s", len(offers), log)
	}
	for _, want := range []string{"answer 1 of the first 3", "(+0s after answer 1;", "; 0 NONE answer(s)"} {
		if !strings.Contains(offers[0], want) {
			t.Errorf("the offered line lacks %q: %q", want, offers[0])
		}
	}
}

// The NONE count is the lock's only when that lock named the uid the marker names.
func TestGetColdLockTrace_OfferForAnotherUserCountsZero(t *testing.T) {
	dest := gcltSetup(t)
	gcltLock("12")
	gcltAskFor(t, dest, 2, "NONE\n")
	gcltMarker(t, dest, "13")
	log := gcltAskFor(t, dest, 1, "COLDLOCK 13 nokey nopin "+gcltName+"\n")
	offers := gcltLines(log, gcltOfferLine)
	if len(offers) != 1 || !strings.Contains(offers[0], "; 0 NONE answer(s)") {
		t.Fatalf("a marker for another user must count 0 NONE answers:\n%s", log)
	}
}

// coldLockStarts 0, no lock since the daemon started, counts as a lock of its own: a marker a restart found is offered.
func TestGetColdLockTrace_NoLockSinceTheDaemonStarted(t *testing.T) {
	dest := gcltSetup(t)
	coldLockMu.Lock()
	coldLockRunning, coldLockUID, coldLockStarts = false, "", 0
	coldLockMu.Unlock()
	gcltMarker(t, dest, "12")
	log := gcltAskFor(t, dest, 4, "COLDLOCK 12 nokey nopin "+gcltName+"\n")
	if n := len(gcltLines(log, gcltOfferLine)); n != 3 {
		t.Fatalf("logged %d offered lines with no lock since the daemon started, want 3:\n%s", n, log)
	}
}

// A call that read lock A's state and answers NONE after lock B began changes nothing of B's: not its uid, which would
// zero B's count at the offer, and not its count, whichever uid A named.
func TestGetColdLockTrace_OlderLocksNoneLeavesTheNewerLockAlone(t *testing.T) {
	for _, olderUID := range []string{"12", "13"} {
		t.Run("older lock of user "+olderUID, func(t *testing.T) {
			dest := gcltSetup(t)
			gcltLock(olderUID)
			release := gcltAskPaused(t, dest)
			gcltEndLock()
			gcltLock("13")
			log := captureStderr(t, func() {
				if got := gcltAsk(t, dest); got != "NONE\n" {
					t.Errorf("the newer lock's call replied %q, want NONE", got)
				}
				if got := release(""); got != "NONE\n" {
					t.Errorf("the older lock's call replied %q, want NONE", got)
				}
			})
			nones := gcltLines(log, gcltNoneLine)
			if len(nones) != 1 || !strings.Contains(nones[0], "the cold lock of user 13 ") {
				t.Errorf("want one NONE line, naming user 13:\n%s", log)
			}
			gcltMarker(t, dest, "13")
			log = gcltAskFor(t, dest, 1, "COLDLOCK 13 nokey nopin "+gcltName+"\n")
			offers := gcltLines(log, gcltOfferLine)
			if len(offers) != 1 || !strings.Contains(offers[0], "; 1 NONE answer(s)") {
				t.Fatalf("the newer lock's offer must count its own one NONE:\n%s", log)
			}
		})
	}
}

// A call that read lock A's state and offers after lock B began replies as ever, and takes none of B's three lines.
func TestGetColdLockTrace_OlderLocksOfferLeavesTheNewerLockAlone(t *testing.T) {
	dest := gcltSetup(t)
	gcltLock("12")
	release := gcltAskPaused(t, dest)
	gcltEndLock()
	gcltLock("12")
	want := "COLDLOCK 12 nokey nopin " + gcltName + "\n"
	log := captureStderr(t, func() {
		if got := gcltAsk(t, dest); got != "NONE\n" {
			t.Errorf("the newer lock's call replied %q, want NONE", got)
		}
		if got := release(gcltMarkerText("12")); got != want {
			t.Errorf("the older lock's call replied %q, want %q", got, want)
		}
	})
	if offers := gcltLines(log, gcltOfferLine); len(offers) != 0 {
		t.Errorf("the older lock's call logged an offered line:\n%s", log)
	}
	gcltMarker(t, dest, "12")
	log = gcltAskFor(t, dest, 4, want)
	offers := gcltLines(log, gcltOfferLine)
	if len(offers) != 3 {
		t.Fatalf("the newer lock logged %d offered lines, want 3:\n%s", len(offers), log)
	}
	for i, ln := range offers {
		for _, want := range []string{"answer " + string(rune('1'+i)) + " of the first 3", "; 1 NONE answer(s)"} {
			if !strings.Contains(ln, want) {
				t.Errorf("offered line %d lacks %q: %q", i+1, want, ln)
			}
		}
	}
}

// GET-COLDLOCK runs concurrently with itself (concurrentSafeCmd): one NONE line, then three offered lines, each number
// once, each with the whole NONE count.
func TestGetColdLockTrace_ConcurrentCallsKeepTheCounts(t *testing.T) {
	const calls = 16
	dest := gcltSetup(t)
	gcltLock("12")
	log := gcltAskConcurrent(t, dest, calls, "NONE\n")
	if n := len(gcltLines(log, gcltNoneLine)); n != 1 {
		t.Errorf("%d concurrent NONE answers logged %d NONE lines, want 1:\n%s", calls, n, log)
	}
	gcltMarker(t, dest, "12")
	log = gcltAskConcurrent(t, dest, calls, "COLDLOCK 12 nokey nopin "+gcltName+"\n")
	offers := gcltLines(log, gcltOfferLine)
	if len(offers) != 3 {
		t.Fatalf("%d concurrent COLDLOCK answers logged %d offered lines, want 3:\n%s", calls, len(offers), log)
	}
	for _, want := range []string{"answer 1 of the first 3", "answer 2 of the first 3", "answer 3 of the first 3"} {
		if n := len(gcltLines(log, want)); n != 1 {
			t.Errorf("%q logged %d times, want 1:\n%s", want, n, log)
		}
	}
	if n := len(gcltLines(log, "; 16 NONE answer(s)")); n != 3 {
		t.Errorf("%d of 3 offered lines carry the 16 NONE answers:\n%s", n, log)
	}
}
