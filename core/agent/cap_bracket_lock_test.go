package main

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// NWP-20261009-07: one cap bracket at a time per process. A bracket is process state (capCur, capSession,
// capBuffering), and the login daemon opens brackets from goroutines under different locks -- an export under
// sessionMu, a re-key batch under the worker lane, payRent's wallet seal under none. Before capBracketMu a
// second capBegin replaced the first bracket's state: one capFlush flushed the other's buffer, and the other
// found nothing to flush and returned as though it had written.
//
// The overlap is forced, not hoped for: bracket A buffers and then waits INSIDE its bracket until bracket B
// either reports that it found A's bracket open (capBracketTrace "wait": the lock is there) or is running its
// own fn (the lock is not). Nothing sleeps, so the outcome does not depend on scheduling either way.

// A stale-check reading armed with no bracket open is a bug a test must see (production logs and ignores it).
func init() { capExpectStrict = true }

// capLockEnv is a cap-mode device (no store creds) on the fake gateway, with a wallet that is this profile's
// and holds no credit, so every flush rides the free lease. It fails the test if a bracket is left open.
func capLockEnv(t *testing.T) (map[string][]byte, *sync.Mutex) {
	t.Helper()
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	capReadCache = map[string]capEntry{}
	blobCache = nil // another test may have written the same content; postBlob would then skip it
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	capBracketTrace = nil
	t.Cleanup(func() { capBracketTrace = nil }) // mockCapStore's own clean-up checks for a leaked bracket
	return objs, mu
}

// capBracketLeakCheck fails t if a cap bracket is still open, then RESETS the bracket state, so the rest of the
// package fails on its own merits instead of hanging on capBracketMu: a bracket a test leaks -- a t.Fatal
// between capBegin and capFlush, say -- would otherwise wedge every later test. The leaked bracket's number is
// retired with it, so its owner, if it is still running, can neither flush nor release anything.
func capBracketLeakCheck(t *testing.T) {
	if capBracketMu.TryLock() {
		capBracketMu.Unlock()
		return
	}
	capWriteMu.Lock()
	open := capBracketOpen
	st := capCur
	capCur, capBuffering, capSession = nil, false, capSessionT{}
	for ref := range capBracketExpects {
		disarmExpect(ref)
	}
	capBracketExpects = map[string]string{}
	capBracketOpen, capBracketWrapped = 0, false
	capWriteMu.Unlock()
	if st != nil {
		st.spill.Close()
		os.Remove(st.spillPath)
	}
	capBracketMu.Unlock()
	t.Errorf("the test ended with cap bracket %d still open -- reset, so later tests can run; every later "+
		"bracket in a real process would have waited on it forever (NWP-20261009-07)", open)
}

// bracketWaits installs capBracketTrace and returns a channel closed the first time a capBegin finds another
// bracket open, i.e. is about to wait for it.
func bracketWaits() <-chan struct{} {
	ch := make(chan struct{})
	waits := closer(ch)
	capBracketTrace = func(event string) {
		if event == "wait" {
			waits()
		}
	}
	return ch
}

// runAll runs each fn in its own goroutine, waits for every one, and returns the panics they raised.
func runAll(fns ...func()) (panics []any) {
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, fn := range fns {
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() {
				if r := recover(); r != nil {
					mu.Lock()
					panics = append(panics, r)
					mu.Unlock()
				}
			}()
			fn()
		}()
	}
	wg.Wait()
	return panics
}

// closer closes ch once, however many times it is called.
func closer(ch chan struct{}) func() {
	var once sync.Once
	return func() { once.Do(func() { close(ch) }) }
}

// lockedWrite is one bracket's worth of writes, the shape of an export: a blob and the pointer naming it.
type lockedWrite struct {
	name, pass, ref, body string
	h                     string // the blob's hash, set when the bracket buffers it
}

func (w *lockedWrite) buffer() {
	w.h = postBlob("s3", []byte(w.body))
	putRef("s3", w.ref, w.h)
}

func (w *lockedWrite) dk() []byte { return deriveKey(w.name, w.pass) }

// missing says what of w the store lacks: "" when both its blob and its pointer are there.
func (w *lockedWrite) missing(objs map[string][]byte, mu *sync.Mutex) string {
	mu.Lock()
	defer mu.Unlock()
	if w.h == "" {
		return "its bracket never buffered it"
	}
	if string(objs["blob/"+w.h]) != w.body {
		return "its blob is not in the store"
	}
	if got := strings.TrimSpace(string(objs["ref/"+w.ref])); got != w.h {
		return "its pointer is not in the store (it holds " + strconv.Quote(got) + ")"
	}
	return ""
}

// published reports whether the store holds w's pointer at all.
func (w *lockedWrite) published(objs map[string][]byte, mu *sync.Mutex) bool {
	mu.Lock()
	defer mu.Unlock()
	_, ok := objs["ref/"+w.ref]
	return ok
}

// overlap runs bracket A (capWrite, buffering a) and, while A is open, bracket B through open, which must call
// its argument from inside its own bracket. It reports whether B found A's bracket open, and any panic.
func overlap(a *lockedWrite, open func(inside func())) (waited bool, panics []any) {
	aIn, bIn, bDone := make(chan struct{}), make(chan struct{}), make(chan struct{})
	enterA := closer(aIn)
	bWaits := bracketWaits()
	panics = runAll(
		func() {
			defer enterA() // A died before signalling: B must not wait for it forever
			capWrite(a.name, a.pass, a.dk(), func() {
				a.buffer()
				enterA()
				select {
				case <-bWaits: // the lock: B cannot open until A ends, so A ends now
				case <-bIn: // no lock: B is open on top of A -- let it run to its end before A flushes
					<-bDone
				case <-bDone: // B ended without opening (it failed): nothing to wait for
				}
			})
		},
		func() {
			defer close(bDone)
			<-aIn
			open(closer(bIn))
		},
	)
	select {
	case <-bWaits:
		waited = true
	default:
	}
	return waited, panics
}

// THE BUG: an export and a background re-key batch, two capWrite brackets, overlap. Both sets of writes must
// land. Without the lock B's capBegin discards A's buffer, B's flush lands B, and A's flush finds nothing and
// returns -- both brackets succeed, and A's export was never written.
func TestCapBracketsOverlappingBothLand(t *testing.T) {
	objs, mu := capLockEnv(t)
	a := &lockedWrite{name: "lockexa", pass: "pass of the export", ref: "lock-export-a", body: "the export bundle"}
	b := &lockedWrite{name: "lockrkb", pass: "pass of the re-key", ref: "lock-rekey-b", body: "a re-key batch"}
	waited, panics := overlap(a, func(inside func()) {
		capWrite(b.name, b.pass, b.dk(), func() {
			b.buffer()
			inside()
		})
	})
	if len(panics) > 0 {
		t.Fatalf("a bracket panicked: %v", panics)
	}
	if why := a.missing(objs, mu); why != "" {
		t.Errorf("bracket A returned as though it had written, but %s: a second bracket opened on top of it "+
			"and discarded its buffer (NWP-20261009-07)", why)
	}
	if why := b.missing(objs, mu); why != "" {
		t.Errorf("bracket B: %s", why)
	}
	if !waited {
		t.Error("bracket B never found A's bracket open: the overlap this test exists to force did not happen")
	}
}

// The same overlap with payRent's shape for B: a bare capBegin ... capFlush (sealWalletDurable), not capWrite.
func TestCapBracketsOverlappingBareBracketBothLand(t *testing.T) {
	objs, mu := capLockEnv(t)
	a := &lockedWrite{name: "lockexc", pass: "pass of the export", ref: "lock-export-c", body: "another export"}
	b := &lockedWrite{name: "lockwld", pass: "pass of the wallet", ref: "lock-wallet-d", body: "a durable seal"}
	waited, panics := overlap(a, func(inside func()) {
		n := capBegin()
		defer capEndBracket(n)
		capSetSession(b.name, b.pass, b.dk())
		b.buffer()
		inside()
		capFlush(n)
	})
	if len(panics) > 0 {
		t.Fatalf("a bracket panicked: %v", panics)
	}
	if why := a.missing(objs, mu); why != "" {
		t.Errorf("bracket A returned as though it had written, but %s (NWP-20261009-07)", why)
	}
	if why := b.missing(objs, mu); why != "" {
		t.Errorf("bracket B: %s", why)
	}
	if !waited {
		t.Error("bracket B never found A's bracket open: the overlap this test exists to force did not happen")
	}
}

// A panic inside a bracket's fn must end the bracket. It used to leak only a spill file; now an open bracket
// holds capBracketMu, and every later bracket in the daemon would wait on it for the rest of the boot.
func TestCapBracketPanicInsideFnReleasesTheLock(t *testing.T) {
	objs, mu := capLockEnv(t)
	dead := &lockedWrite{name: "lockpna", pass: "pass that panics", ref: "lock-panicked", body: "never published"}
	if !didPanic(func() {
		capWrite(dead.name, dead.pass, dead.dk(), func() {
			dead.buffer()
			panic("a store error mid-bracket")
		})
	}) {
		t.Fatal("the bracket's panic did not propagate")
	}
	if !capBracketMu.TryLock() {
		t.Fatal("a panic inside capWrite's fn left capBracketMu held: every later bracket would wait forever")
	}
	capBracketMu.Unlock()
	next := &lockedWrite{name: "lockpnb", pass: "pass after the panic", ref: "lock-after-panic", body: "the next one"}
	capWrite(next.name, next.pass, next.dk(), next.buffer)
	if why := next.missing(objs, mu); why != "" {
		t.Errorf("the bracket after a panicked one: %s", why)
	}
	if dead.published(objs, mu) {
		t.Error("the panicked bracket's pointer was published")
	}
}

// sealWalletDurable opens a bare bracket and recovers its own panics into an error, and that recover never
// ended the bracket. A key that cannot seal panics between its capBegin and its capFlush.
func TestSealWalletDurablePanicReleasesTheLock(t *testing.T) {
	capLockEnv(t)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	if _, err := sealWalletDurable("s3", "lockwdp", "pass of the wallet", []byte("not a key"), wpath); err == nil {
		t.Fatal("a wallet seal under a key that cannot seal reported success")
	}
	if !capBracketMu.TryLock() {
		t.Fatal("sealWalletDurable's recovered panic left capBracketMu held: every later bracket would wait forever")
	}
	capBracketMu.Unlock()
}

// The capAbort a capWrite fn calls before it returns (rotateVault, recoverVault, sessionUntie, add-device)
// drops what it buffered but keeps the bracket until capWrite ends: a waiting bracket must not open while fn
// is still running, and capWrite's own closing calls must end ITS bracket only, never the one that opens next.
func TestCapBracketInnerAbortHoldsTheBracketUntilCapWriteEnds(t *testing.T) {
	objs, mu := capLockEnv(t)
	a := &lockedWrite{name: "lockaba", pass: "pass that aborts", ref: "lock-aborted", body: "dropped by capAbort"}
	b := &lockedWrite{name: "lockabb", pass: "pass that waits", ref: "lock-after-abort", body: "the waiting bracket"}
	aborted, bIn, bDone := make(chan struct{}), make(chan struct{}), make(chan struct{})
	abort := closer(aborted)
	bWaits := bracketWaits()
	var bOpenedEarly bool
	panics := runAll(
		func() {
			defer abort()
			capWrite(a.name, a.pass, a.dk(), func() {
				a.buffer()
				capAbort()
				abort()
				select {
				case <-bWaits: // still held: B waits for capWrite to end
				case <-bIn:
					bOpenedEarly = true // capAbort released the bracket while fn was still running
				case <-bDone:
				}
			})
		},
		func() {
			defer close(bDone)
			<-aborted
			capWrite(b.name, b.pass, b.dk(), func() {
				close(bIn)
				b.buffer()
			})
		},
	)
	if len(panics) > 0 {
		t.Fatalf("a bracket panicked: %v", panics)
	}
	if bOpenedEarly {
		t.Error("capAbort inside capWrite's fn released the bracket while fn was still running")
	}
	if why := b.missing(objs, mu); why != "" {
		t.Errorf("the bracket that waited for an aborted one: %s -- capWrite's closing calls ended the "+
			"wrong bracket", why)
	}
	if a.published(objs, mu) {
		t.Error("the aborted bracket's pointer was published")
	}
}

// capWrite's deferred clean-up runs AFTER its capFlush has released the bracket, and a bracket waiting for it
// can open in between. The clean-up must end ITS bracket only: the `defer capAbort()` it used to be acted on
// whichever bracket was open, so it would drop the next one's buffer. Forced here: A's release waits until B
// is inside its own bracket, and B buffers only once A's capWrite, defers and all, has returned.
func TestCapWriteCleanupNeverEndsTheNextBracket(t *testing.T) {
	objs, mu := capLockEnv(t)
	a := &lockedWrite{name: "lockcla", pass: "pass that ends first", ref: "lock-ends-first", body: "the first one"}
	b := &lockedWrite{name: "lockclb", pass: "pass that opens next", ref: "lock-opens-next", body: "the next one"}
	aIn, aDone, bIn := make(chan struct{}), make(chan struct{}), make(chan struct{})
	enterA, endA, enterB := closer(aIn), closer(aDone), closer(bIn)
	var first sync.Once
	capBracketTrace = func(event string) {
		if event == "end" {
			first.Do(func() { <-bIn }) // A's release: A's capWrite goes no further until B is open
		}
	}
	panics := runAll(
		func() {
			defer endA()
			defer enterA()
			capWrite(a.name, a.pass, a.dk(), func() {
				a.buffer()
				enterA()
			})
		},
		func() {
			defer enterB() // B died before opening: A must not wait for it forever
			<-aIn
			capWrite(b.name, b.pass, b.dk(), func() {
				enterB()
				<-aDone
				b.buffer()
			})
		},
	)
	if len(panics) > 0 {
		t.Fatalf("a bracket panicked (a clean-up that ends the wrong bracket makes the next one's writes "+
			"unbracketed): %v", panics)
	}
	if why := a.missing(objs, mu); why != "" {
		t.Errorf("bracket A: %s", why)
	}
	if why := b.missing(objs, mu); why != "" {
		t.Errorf("bracket B, opened while A's capWrite was still returning: %s -- A's clean-up ended B's "+
			"bracket", why)
	}
}

// capWriteAttr clears the refusal flags its caller reads, and must clear them only once its bracket holds the
// lock. Cleared before waiting, a refusal made by the bracket it waited for lands after the clear and fn starts
// on it: rotateVault reads the flags inside fn to decide whether to retire the old credential.
func TestCapWriteClearsTheRefusalFlagsOnlyOnceItHoldsTheBracket(t *testing.T) {
	objs, mu := capLockEnv(t)
	fenceTestEnv(t)
	t.Cleanup(clearStaleHit)
	a := &lockedWrite{name: "lockfna", pass: "pass that is refused", ref: strings.Repeat("f1", 32), body: "refused at the flush"}
	const bName, bPass = "lockfnb", "pass that is not refused"
	aIn, bIn, bDone := make(chan struct{}), make(chan struct{}), make(chan struct{})
	enterA := closer(aIn)
	bWaits := bracketWaits()
	var bSawRefusal bool
	panics := runAll(
		func() {
			defer enterA()
			capWrite(a.name, a.pass, a.dk(), func() {
				a.buffer()
				armSealFence([]string{a.ref}) // a Delete between the buffer and the flush: the flush refuses it
				enterA()
				select {
				case <-bWaits:
				case <-bIn:
				case <-bDone:
				}
			})
		},
		func() {
			defer close(bDone)
			<-aIn
			capWrite(bName, bPass, deriveKey(bName, bPass), func() {
				close(bIn)
				bSawRefusal = sealFenceHit || sealStaleHit
			})
		},
	)
	if len(panics) > 0 {
		t.Fatalf("a bracket panicked: %v", panics)
	}
	// Read from the store, not from sealFenceHit: B's bracket has cleared the flag since A's flush set it.
	if a.published(objs, mu) || a.h == "" {
		t.Fatal("bracket A's flush was not refused, so this test checks nothing")
	}
	if bSawRefusal {
		t.Error("bracket B's fn started on bracket A's refusal: capWriteAttr cleared the flags before it held " +
			"the bracket")
	}
}

// THE VERDICT IS THE BRACKET'S OWN. A bracket refused at publish, and a second one waiting for the lock that
// clears the refusal flags as it opens: the first caller must still learn of its refusal. Read from the
// globals after the bracket, it learned nothing -- a refused rotation reported success and skipped handing
// its lease back. Forced: A's release waits until B is inside its bracket, i.e. has cleared the flags.
func TestCapVerdictSurvivesTheNextBracketOpening(t *testing.T) {
	objs, mu := capLockEnv(t)
	fenceTestEnv(t)
	t.Cleanup(clearStaleHit)
	a := &lockedWrite{name: "lockvda", pass: "pass that is refused", ref: strings.Repeat("f2", 32), body: "refused at the flush"}
	const bName, bPass = "lockvdb", "pass that opens next"
	aIn, bIn := make(chan struct{}), make(chan struct{})
	enterA, enterB := closer(aIn), closer(bIn)
	var first sync.Once
	capBracketTrace = func(event string) {
		if event == "end" {
			first.Do(func() { <-bIn }) // A's release: A's capWrite goes no further until B has opened
		}
	}
	var av capVerdict
	var bSawRefusal bool
	panics := runAll(
		func() {
			defer enterA()
			av = capWrite(a.name, a.pass, a.dk(), func() {
				a.buffer()
				armSealFence([]string{a.ref}) // a Delete between the buffer and the flush: the flush refuses it
				enterA()
			})
		},
		func() {
			defer enterB() // B died before opening: A must not wait for it forever
			<-aIn
			capWrite(bName, bPass, deriveKey(bName, bPass), func() {
				bSawRefusal = sealFenceHit || sealStaleHit // B has cleared them: the window is open
				enterB()
			})
		},
	)
	if len(panics) > 0 {
		t.Fatalf("a bracket panicked: %v", panics)
	}
	if a.published(objs, mu) || a.h == "" {
		t.Fatal("precondition: bracket A's flush was not refused, so this test checks nothing")
	}
	if bSawRefusal {
		t.Fatal("precondition: bracket B opened on A's refusal flags uncleared, so the window was never open")
	}
	if !av.FenceHit || !av.Refused() {
		t.Errorf("bracket A was refused at publish but its verdict says %+v: the bracket that opened next "+
			"cleared the refusal before A's caller saw it (NWP-20261009-07)", av)
	}
}

// The same window on a self-hosted store, where capWrite buffers nothing and putRef refuses at once: the
// direct-mode arm holds the bracket lock around fn and snapshots before letting go, for the same reason.
func TestCapVerdictSurvivesTheNextBracketOpeningDirectMode(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("GATEWAY_URL", "") // direct mode: no capBegin, no buffer
	fenceTestEnv(t)
	t.Cleanup(clearStaleHit)
	capBracketTrace = nil
	t.Cleanup(func() { capBracketTrace = nil })
	ref := strings.Repeat("f3", 32) // 64-hex: the fence refuses any other shape (fenceRefOK)
	aIn, bIn := make(chan struct{}), make(chan struct{})
	enterA, enterB := closer(aIn), closer(bIn)
	bWaits := bracketWaits()
	var first sync.Once
	waitsHook := capBracketTrace
	capBracketTrace = func(event string) {
		waitsHook(event)
		if event == "end" {
			first.Do(func() { <-bIn }) // A's release: A's capWrite goes no further until B has opened
		}
	}
	var av capVerdict
	var bSawRefusal bool
	panics := runAll(
		func() {
			defer enterA()
			av = capWrite("lockdra", "pass that is refused", deriveKey("lockdra", "pass that is refused"), func() {
				armSealFence([]string{ref})
				putRef(base, ref, "a head that must not land") // refused at once: the fence
				enterA()
				select {
				case <-bWaits: // the lock: B waits for A's capWrite to end
				case <-bIn: // no lock: B is open, and has cleared the flags, while A is still inside
				}
			})
		},
		func() {
			defer enterB()
			<-aIn
			capWrite("lockdrb", "pass that opens next", deriveKey("lockdrb", "pass that opens next"), func() {
				bSawRefusal = sealFenceHit || sealStaleHit
				enterB()
			})
		},
	)
	if len(panics) > 0 {
		t.Fatalf("a bracket panicked: %v", panics)
	}
	if got := getRef(base, ref); got != "" {
		t.Fatalf("precondition: the fenced head was published (%q), so this test checks nothing", got)
	}
	if bSawRefusal {
		t.Fatal("precondition: bracket B opened on A's refusal flags uncleared, so the window was never open")
	}
	if !av.FenceHit {
		t.Errorf("bracket A was refused at publish but its verdict says %+v (NWP-20261009-07)", av)
	}
}

// The one daemon path that wrote to the store outside any bracket in cap mode: the legacy LOGOFF verb's
// pushSet. With another goroutine's bracket open, its blobs and this profile's head were buffered into THAT
// bracket and published by its flush. The verb no longer pushes in cap mode.
func TestLegacyLogoffNeverWritesIntoAnotherBracket(t *testing.T) {
	objs, mu := capLockEnv(t)
	const name, pass = "lockleg", "a legacy session"
	dest := t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, ".session"), []byte(name+"\n"+pass+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dest, "files"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, "files", "note"), []byte("session data"), 0o600); err != nil {
		t.Fatal(err)
	}
	b := &lockedWrite{name: "lockexp", pass: "pass of the export", ref: "lock-export-open", body: "an open export"}
	inB, release := make(chan struct{}), make(chan struct{})
	enterB := closer(inB)
	var reply []byte
	panics := runAll(
		func() {
			defer enterB()
			capWrite(b.name, b.pass, b.dk(), func() {
				b.buffer()
				enterB()
				<-release // held open while the LOGOFF runs
			})
		},
		func() {
			defer close(release)
			<-inB
			c1, c2 := net.Pipe()
			go func() {
				defer c1.Close()
				handleLogoff(c1, dest)
			}()
			reply, _ = io.ReadAll(c2)
		},
	)
	if len(panics) > 0 {
		t.Fatalf("a bracket panicked: %v", panics)
	}
	if strings.TrimSpace(string(reply)) != "OK" {
		t.Fatalf("LOGOFF answered %q", reply)
	}
	if why := b.missing(objs, mu); why != "" {
		t.Errorf("the open bracket: %s", why)
	}
	mu.Lock()
	defer mu.Unlock()
	for _, ref := range []string{profileRefV2(name, pass), profileRefLegacy(name, pass)} {
		if _, ok := objs["ref/"+ref]; ok {
			t.Errorf("the legacy LOGOFF's head was published by another goroutine's bracket (ref %s)", short(ref))
		}
	}
}

// The verdict globals and who may touch them by name. Everyone else reads a capVerdict.
var (
	verdictGlobals = map[string]bool{"sealFenceHit": true, "sealStaleHit": true, "capRetireBegun": true,
		"capLeaseLanded": true, "capExpireApplied": true, "capLeaseRefused": true} // the last two: NWP-20261010-02
	verdictGlobalOwners = map[string]string{
		"capOpen":               "resets them as a bracket opens",
		"capFlush":              "sets them, inside the bracket",
		"capVerdictNow":         "the snapshot a bracket's own end takes",
		"capWriteTo":            "resets them once its bracket holds the lock",
		"noteSealFenceRefusal":  "sets sealFenceHit",
		"noteStalePublish":      "sets sealStaleHit",
		"noteOpRefused":         "sets sealStaleHit, for a session operation",
		"clearStaleHit":         "resets sealStaleHit, for capWriteTo",
		"clearSealExpectations": "resets sealStaleHit, for pushProfile",
		"pushProfile":           "the bracket of the `push` process, which runs no other",
		"main":                  "the `push` verb reads the refusal of its process's one bracket",
	}
	// A func literal passed to one of these runs inside the bracket, holding capBracketMu.
	verdictBracketFns = map[string]bool{"capWrite": true, "capWriteNoLogin": true, "capWriteAttr": true,
		"capWriteTo": true}
)

// agentSource parses the package's non-test files.
func agentSource(t *testing.T) (*token.FileSet, []*ast.File) {
	t.Helper()
	fset := token.NewFileSet()
	names, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	var files []*ast.File
	for _, f := range names {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, af)
	}
	return fset, files
}

// bracketFnArgs returns the func literals passed to a capWrite-family call under n: they run inside the bracket.
func bracketFnArgs(n ast.Node) []*ast.FuncLit {
	var out []*ast.FuncLit
	ast.Inspect(n, func(n ast.Node) bool {
		if call, ok := n.(*ast.CallExpr); ok {
			if id, ok := call.Fun.(*ast.Ident); ok && verdictBracketFns[id.Name] {
				for _, arg := range call.Args {
					if fl, ok := arg.(*ast.FuncLit); ok {
						out = append(out, fl)
					}
				}
			}
		}
		return true
	})
	return out
}

func within(n ast.Node, outer ast.Node) bool { return n.Pos() >= outer.Pos() && n.End() <= outer.End() }

// TestBracketVerdictGlobalsAreReadOnlyInsideABracket keeps the race closed: sealFenceHit, sealStaleHit,
// capRetireBegun and capLeaseLanded may be named only by their owners above, or inside a capWrite fn. A read
// anywhere else -- after a bracket, typically -- can see the next bracket's reset (NWP-20261009-07). Two
// places that look inside and are not: a `go` statement in a capWrite fn (its goroutine outlives the bracket),
// and a package-level `var f = func() {...}` (it belongs to no bracket at all).
func TestBracketVerdictGlobalsAreReadOnlyInsideABracket(t *testing.T) {
	fset, files := agentSource(t)
	var bad []string
	used := map[string]bool{}
	uses := 0
	for _, af := range files {
		for _, d := range af.Decls {
			if gd, ok := d.(*ast.GenDecl); ok { // package-level initializers: never inside a bracket
				ast.Inspect(gd, func(n ast.Node) bool {
					if vs, ok := n.(*ast.ValueSpec); ok {
						for _, val := range vs.Values {
							ast.Inspect(val, func(n ast.Node) bool {
								if id, ok := n.(*ast.Ident); ok && verdictGlobals[id.Name] {
									uses++
									bad = append(bad, fset.Position(id.Pos()).String()+": "+id.Name+
										" in a package-level initializer")
								}
								return true
							})
						}
						return false
					}
					return true
				})
				continue
			}
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Body == nil {
				continue
			}
			inside := bracketFnArgs(fd.Body)
			var goStmts []*ast.GoStmt
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				if g, ok := n.(*ast.GoStmt); ok {
					goStmts = append(goStmts, g)
				}
				return true
			})
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				id, ok := n.(*ast.Ident)
				if !ok || !verdictGlobals[id.Name] {
					return true
				}
				uses++
				if _, owner := verdictGlobalOwners[fd.Name.Name]; owner {
					used[fd.Name.Name] = true
					return true
				}
				for _, g := range goStmts {
					if within(id, g) {
						bad = append(bad, fset.Position(id.Pos()).String()+": "+id.Name+" in a goroutine of "+
							fd.Name.Name+", which outlives any bracket it starts in")
						return true
					}
				}
				for _, fl := range inside {
					if within(id, fl) {
						return true
					}
				}
				bad = append(bad, fset.Position(id.Pos()).String()+": "+id.Name+" in "+fd.Name.Name)
				return true
			})
		}
	}
	if uses == 0 {
		t.Fatal("no use of the verdict globals found at all -- this test is looking in the wrong place")
	}
	for name := range verdictGlobalOwners {
		if !used[name] {
			t.Errorf("%s is listed as an owner of the verdict globals but names none of them: drop it from the list", name)
		}
	}
	if len(bad) > 0 {
		t.Errorf("the verdict globals are read outside a bracket -- after a bracket they may already be the next "+
			"one's; read the bracket's capVerdict instead (NWP-20261009-07):\n  %s", strings.Join(bad, "\n  "))
	}
}

// otherBracketMark is what the other bracket in publishBehindAnotherBracket writes into the vault it publishes,
// in a field none of the publishers under test touch, so a test can see whether that vault's content survived.
const otherBracketMark = "the other bracket's mark"

// markedNewer is the other bracket's publish: the session vault ten versions on, marked, signed with dk.
func markedNewer(name, pass string, dk []byte) func(v *vault) {
	return func(v *vault) {
		v.Version += 10
		v.TelPub = otherBracketMark
		publishSessionVaultIn("s3", name, pass, v, dk) // bumps the version once more
	}
}

// publishBehindAnotherBracket runs publish -- a vault publisher, which reads the head and then opens its own
// bracket -- while another bracket for the same profile, a re-key batch's shape, is open: the publisher reads
// the head that bracket is about to replace, then waits for the lock while it publishes a newer vault, marked
// with otherBracketMark. Returns the version the other bracket published.
func publishBehindAnotherBracket(t *testing.T, name, pass string, dk []byte, publish func()) uint64 {
	t.Helper()
	return publishBehindWith(t, name, pass, dk, markedNewer(name, pass, dk), publish)
}

// publishBehindWith is publishBehindAnotherBracket with the other bracket's publish given: other edits and
// publishes the session vault it read inside its bracket.
func publishBehindWith(t *testing.T, name, pass string, dk []byte, other func(v *vault), publish func()) uint64 {
	t.Helper()
	rIn, pubDone := make(chan struct{}), make(chan struct{})
	enterR := closer(rIn)
	pubWaits := bracketWaits()
	var rVersion uint64
	panics := runAll(
		func() {
			defer enterR()
			capWrite(name, pass, dk, func() {
				v, err := readSessionVault("s3", name, pass)
				if err != nil {
					panic(err)
				}
				other(v)
				rVersion = v.Version
				enterR()
				select {
				case <-pubWaits: // the publisher has read the old head and waits for this bracket
				case <-pubDone: // it never reached its bracket
				}
			})
		},
		func() {
			defer close(pubDone)
			<-rIn
			publish()
		},
	)
	if len(panics) > 0 {
		t.Fatalf("a bracket panicked: %v", panics)
	}
	return rVersion
}

// headAndRecovery reads (name, pass)'s vault and reports the blob its head names and the blob its recovery ref
// names: a vault publish lands both, and a refused one must land neither.
func headAndRecovery(t *testing.T, name, pass string) (v *vault, head, recovery string) {
	t.Helper()
	hd, v, ok := readVaultHead("s3", name, pass)
	if !ok || v == nil {
		t.Fatal("the profile has no vault head")
	}
	if v.RecoveryRef == "" {
		t.Fatal("the vault names no recovery ref")
	}
	return v, hd.val, getRef("s3", v.RecoveryRef)
}

// landedOnTheOtherBracket checks a publisher that waited for the other bracket built on ITS vault: one version
// on, the other bracket's mark kept, and the recovery ref naming the same blob as the head.
func landedOnTheOtherBracket(t *testing.T, what, name, pass string, rv uint64) *vault {
	t.Helper()
	v, head, rec := headAndRecovery(t, name, pass)
	if v.Version != rv+1 || v.TelPub != otherBracketMark {
		t.Errorf("%s: the head reads version %d (marked: %v); want %d with the other bracket's mark -- it "+
			"published the vault it read before waiting, over the newer one", what, v.Version,
			v.TelPub == otherBracketMark, rv+1)
	}
	if rec != head {
		t.Errorf("%s: the recovery ref names %s while the head names %s", what, short(rec), short(head))
	}
	return v
}

// A verb that arrives while a re-key batch holds the lock waits for it and then edits THAT batch's head: it
// reads inside its bracket, where nothing in this process can publish under it (NWP-20261009-07). Before, it
// put the vault it had read back over the batch's; after the first fix, it refused -- and the user saw ERR.
func TestSetPINDuringAReKeyBatchLandsOnItsHead(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "lockpin", "a pin over a moved head"
	_, dk := sessionVaultForTest(t, name, pass)
	var err error
	rv := publishBehindAnotherBracket(t, name, pass, dk, func() {
		err = setStoredPIN("s3", name, pass, "482913", nil)
	})
	if err != nil {
		t.Fatalf("SET-PIN, arriving while another bracket held the lock: %v", err)
	}
	if v := landedOnTheOtherBracket(t, "SET-PIN", name, pass, rv); v.Pin == "" {
		t.Error("SET-PIN reported success but the head carries no PIN")
	}
}

// The same for a security key's enrol: the two-tap NFC ceremony is not thrown away, because the DK and the
// credential's id, salt and hmac are the same whichever head the slot lands on.
func TestSecurityKeyEnrolDuringAReKeyBatchLandsOnItsHead(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "lockkey", "a key over a moved head"
	_, dk := sessionVaultForTest(t, name, pass)
	cred := base64.StdEncoding.EncodeToString([]byte("a credential id"))
	salt := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	hm := hex.EncodeToString(bytes.Repeat([]byte{9}, fido2HMACLen))
	var err error
	rv := publishBehindAnotherBracket(t, name, pass, dk, func() {
		err = enrollFido2("s3", name, pass, cred, salt, hm, false, "nfc", nil)
	})
	if err != nil {
		t.Fatalf("the enrol, arriving while another bracket held the lock: %v", err)
	}
	v := landedOnTheOtherBracket(t, "enrol", name, pass, rv)
	slots := listFido2Slots(v)
	if len(slots) != 1 || slots[0].CredID != cred || unwrapDK(v, "pass", deriveKey(name, pass)) != nil {
		t.Errorf("after a first enrol the head has %d key slot(s) and a pass slot that opens it: %v", len(slots),
			unwrapDK(v, "pass", deriveKey(name, pass)) != nil)
	}
}

// The !bill-retag clear (the reviewer's case: an index read before a re-key's switch, republished after it,
// drops the key the switch recorded) now clears on the switch's head.
func TestBillRetagClearDuringAReKeyBatchLandsOnItsHead(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "lockrtg", "a retag over a moved head"
	v, dk := sessionVaultForTest(t, name, pass)
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("the new vault has no scope index")
	}
	old := profileRefV2(name, "the passphrase before")
	v.Scopes = sealScopeIndex(dk, billRetagPush(idx, old, profileRefV2(name, pass)))
	if err := publishSessionVault("s3", name, pass, v, dk); err != nil {
		t.Fatal(err)
	}
	var cleared bool
	rv := publishBehindAnotherBracket(t, name, pass, dk, func() {
		cleared = dropBillRetag("s3", name, pass, dk, []string{old})
	})
	if !cleared {
		t.Fatal("the re-tag clear, arriving while another bracket held the lock, did not clear")
	}
	// The clear republishes the head and the recovery ref and keeps its version, as it always has: so the other
	// bracket's version and mark, and no record.
	got, err := readSessionVault("s3", name, pass)
	if err != nil {
		t.Fatal(err)
	}
	if got.Version != rv || got.TelPub != otherBracketMark {
		t.Errorf("the head reads version %d (marked: %v); want the other bracket's %d with its mark -- the clear "+
			"published the index it read before waiting, over the newer one", got.Version,
			got.TelPub == otherBracketMark, rv)
	}
	if gidx, _ := openScopeIndex(dk, got.Scopes); len(billRetagOf(gidx)) != 0 {
		t.Errorf("the record still holds %v", shortAll(billRetagOf(gidx)))
	}
}

// A rotation reads before its bracket (its slot re-wraps are Argon2 work that has no place under the lock), so
// it is refused by the head it read having moved -- and retries on the new one. It must end on the other
// bracket's vault, not on the one it read first.
func TestRotationDuringAReKeyBatchRetriesOntoItsHead(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, p1, p2 = "lockrot", "the passphrase before", "the passphrase after"
	_, dk := sessionVaultForTest(t, name, p1)
	var err error
	rv := publishBehindAnotherBracket(t, name, p1, dk, func() {
		_, err = rotateVault("s3", name, p1, p2, nil, true)
	})
	if err != nil {
		t.Fatalf("the rotation, arriving while another bracket held the lock: %v", err)
	}
	landedOnTheOtherBracket(t, "rotation", name, p2, rv)
}

// The re-key's switch is a publisher that reads before its bracket and keeps doing so: a step is retried by the
// next tick anyway. One that waited for another bracket must refuse WHOLE -- not publish the recovery ref, the
// account keyslots or the switched scope head beside a refused vault head, which is what a check made only at
// the flush would let through.
func TestReKeySwitchRefusesWholeWhenTheHeadMovedWhileItWaited(t *testing.T) {
	_, name, pass := tiedWithMedia(t)
	t.Cleanup(func() { capBracketTrace = nil; clearStaleHit() })
	for i := 0; ; i++ { // batches until everything is mapped: the next step is the switch
		if i > 50 {
			t.Fatal("never mapped every chunk")
		}
		st, err := largeScopeRekeyStep("s3", name, pass, seA, "#media")
		if err != nil {
			t.Fatal(err)
		}
		if st.Batched && st.Done == st.Total {
			break
		}
	}
	mref, _ := headWriteRef(name+"#media", pass)
	mediaBefore := getRef("s3", mref)
	var serr error
	rv := publishBehindAnotherBracket(t, name, pass, rekeyDK(t, name, pass), func() {
		_, serr = largeScopeRekeyStep("s3", name, pass, seA, "#media")
	})
	if serr == nil || !strings.Contains(serr.Error(), "refused at publish") {
		t.Fatalf("the switch that waited for another bracket = %v, want refused at publish", serr)
	}
	v, head, rec := headAndRecovery(t, name, pass)
	if v.Version != rv || v.TelPub != otherBracketMark {
		t.Errorf("the head reads version %d (marked: %v); want the other bracket's %d", v.Version,
			v.TelPub == otherBracketMark, rv)
	}
	if rec != head {
		t.Errorf("the refused switch still published the recovery ref (%s, head %s)", short(rec), short(head))
	}
	if got := getRef("s3", mref); got != mediaBefore {
		t.Error("the refused switch still switched the scope head")
	}
}

// sessionVaultForTest creates a cap-mode profile and returns its vault and DK.
func sessionVaultForTest(t *testing.T, name, pass string) (*vault, []byte) {
	t.Helper()
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	v, err := readSessionVault("s3", name, pass)
	if err != nil {
		t.Fatal(err)
	}
	dk := unwrapDK(v, "pass", deriveKey(name, pass))
	if dk == nil {
		t.Fatal("the pass slot does not open the new vault")
	}
	return v, dk
}

// A bracket's stale-check readings end with it. The re-key disarmed its own only after capWrite returned, so the
// bracket that opened next was judged against a reading of a head the re-key had itself just moved, and refused.
// Forced: A's release waits until B has flushed.
func TestABracketsReadingsEndWithIt(t *testing.T) {
	objs, mu := capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const ref = "lock-expect"
	capWrite("lockexpa", "the first writer", deriveKey("lockexpa", "the first writer"), func() {
		putRef("s3", ref, "v0")
	})
	aIn, bDone := make(chan struct{}), make(chan struct{})
	enterA, endB := closer(aIn), closer(bDone)
	bWaits := make(chan struct{})
	waits := closer(bWaits)
	var endsMu sync.Mutex
	ends := 0
	capBracketTrace = func(event string) {
		switch event {
		case "wait":
			waits()
		case "end":
			endsMu.Lock()
			ends++
			firstEnd := ends == 1
			endsMu.Unlock()
			if firstEnd { // A's release: A goes no further until B has flushed (not a sync.Once: B ends too)
				<-bDone
			}
		}
	}
	var bv capVerdict
	panics := runAll(
		func() {
			defer enterA()
			capWrite("lockexpa", "the first writer", deriveKey("lockexpa", "the first writer"), func() {
				capExpect("test writer", ref, "v0") // A read v0 and moves it to v1
				putRef("s3", ref, "v1")
				enterA()
				select {
				case <-bWaits:
				case <-bDone:
				}
			})
		},
		func() {
			defer endB()
			<-aIn
			bv = capWrite("lockexpb", "the next writer", deriveKey("lockexpb", "the next writer"), func() {
				putRef("s3", ref, "v2") // B read nothing and expects nothing
			})
		},
	)
	if len(panics) > 0 {
		t.Fatalf("a bracket panicked: %v", panics)
	}
	mu.Lock()
	got := strings.TrimSpace(string(objs["ref/"+ref]))
	mu.Unlock()
	if bv.Refused() || got != "v2" {
		t.Errorf("the bracket after A was refused (%+v, ref holds %q): it was judged against A's reading of a "+
			"head A itself had moved -- A's readings outlived A's bracket (NWP-20261009-07)", bv, got)
	}
}

// A flush names its bracket, and a flush for any other -- one already ended -- touches nothing: not the open
// bracket's buffer, not its lock. It used to act on whichever bracket was open.
func TestAStrayFlushClosesNoOtherBracket(t *testing.T) {
	objs, mu := capLockEnv(t)
	a := &lockedWrite{name: "lockstra", pass: "the first bracket", ref: "lock-stray-a", body: "the first one"}
	b := &lockedWrite{name: "lockstrb", pass: "the open bracket", ref: "lock-stray-b", body: "the open one"}
	na := capBegin()
	capSetSession(a.name, a.pass, a.dk())
	a.buffer()
	capFlush(na)
	nb := capBegin()
	capSetSession(b.name, b.pass, b.dk())
	b.buffer()
	capFlush(na) // stray: bracket na has ended
	if capBracketMu.TryLock() {
		capBracketMu.Unlock()
		t.Fatal("a flush of an ended bracket released the open one")
	}
	if b.published(objs, mu) {
		t.Error("a flush of an ended bracket flushed the open one's buffer")
	}
	capFlush(nb)
	if why := b.missing(objs, mu); why != "" {
		t.Errorf("the open bracket, flushed by its owner: %s", why)
	}
	if why := a.missing(objs, mu); why != "" {
		t.Errorf("the first bracket: %s", why)
	}
}

// keyCredForTest is a security key's enrol values: a credential id, its salt and its hmac.
func keyCredForTest(id string) (cred, salt, hm string) {
	return base64.StdEncoding.EncodeToString([]byte(id)),
		base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32)),
		hex.EncodeToString(bytes.Repeat([]byte{9}, fido2HMACLen))
}

// enrolKeyForTest enrols one security key and leaves its hmac where the DK ladder looks for it.
func enrolKeyForTest(t *testing.T, name, pass string) string {
	t.Helper()
	cred, salt, hm := keyCredForTest("the key to remove")
	if err := enrollFido2("s3", name, pass, cred, salt, hm, false, "nfc", nil); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_FIDO2_HMAC", hm)
	return cred
}

// snapshotLive is the live manifest withSnapshot moves the vault to; the snapshot keeps the one it had.
var snapshotLive = strings.Repeat("ab", 32)

// withSnapshot gives the profile's vault one rollback snapshot -- the manifest it has -- and a new live one.
func withSnapshot(t *testing.T, name, pass string, dk []byte) (snapManifest string) {
	t.Helper()
	v, err := readSessionVault("s3", name, pass)
	if err != nil {
		t.Fatal(err)
	}
	snapManifest = v.Manifest
	pushSnapshot(v, snapshotLive, v.HeadKind)
	v.Manifest = snapshotLive
	if err := publishSessionVault("s3", name, pass, v, dk); err != nil {
		t.Fatal(err)
	}
	return snapManifest
}

// moveHeadAtFlush makes the store move (name, pass)'s head as the flush starts uploading -- after the
// operation's in-bracket read, before its pointer pass -- as a publish from another device would.
func moveHeadAtFlush(objs map[string][]byte, mu *sync.Mutex, name, pass string) {
	wref, _ := headWriteRef(name, pass)
	var once sync.Once
	capStorePutHook = func(key string, _ []byte) error {
		if strings.HasPrefix(key, "blob/") {
			once.Do(func() {
				mu.Lock()
				objs["ref/"+wref] = []byte(strings.Repeat("cd", 32))
				mu.Unlock()
			})
		}
		return nil
	}
}

// A refusal at the flush -- the head moved after the in-bracket read, which only another process or device can do
// -- is a failure the verb reports. SET-PIN and rollback answered OK whatever the store did.
func TestVaultEditsReportARefusalAtTheFlush(t *testing.T) {
	type edit func(name, pass string, dk []byte) error
	cases := []struct {
		what  string
		setup func(t *testing.T, name, pass string, dk []byte)
		run   edit
	}{
		{"PIN change", nil, func(n, p string, _ []byte) error { return setStoredPIN("s3", n, p, "482913", nil) }},
		{"key enrol", nil, func(n, p string, _ []byte) error {
			c, s, h := keyCredForTest("a new key")
			return enrollFido2("s3", n, p, c, s, h, false, "nfc", nil)
		}},
		{"key removal", func(t *testing.T, n, p string, _ []byte) { enrolKeyForTest(t, n, p) }, func(n, p string, _ []byte) error {
			c, _, _ := keyCredForTest("the key to remove")
			_, err := removeFido2Key("s3", n, p, c, nil)
			return err
		}},
		{"rollback", func(t *testing.T, n, p string, dk []byte) { withSnapshot(t, n, p, dk) }, func(n, p string, _ []byte) error {
			_, err := rollbackHead("s3", n, p, 0, nil)
			return err
		}},
	}
	for i, c := range cases {
		t.Run(c.what, func(t *testing.T) {
			objs, mu := capLockEnv(t)
			t.Cleanup(clearStaleHit)
			name, pass := fmt.Sprintf("lockflush%d", i), "a head moved at the flush"
			_, dk := sessionVaultForTest(t, name, pass)
			if c.setup != nil {
				c.setup(t, name, pass, dk)
			}
			moveHeadAtFlush(objs, mu, name, pass)
			if err := c.run(name, pass, dk); err == nil {
				t.Errorf("the %s answered success over a head the store refused at the flush", c.what)
			}
		})
	}
}

// A head swapped between the read before the bracket and the one inside it, for one this DK does not sign or for
// an unsigned one, is not edited: a delete and re-create in between gives the first, and a signed head turning
// unsigned is a swap, not an old vault. A rollback trusts a snapshot list only under a valid signature.
func TestVaultEditsRefuseASwappedHead(t *testing.T) {
	unsigned := func(name, pass string) func(v *vault) {
		return func(v *vault) {
			v.Version += 10
			v.TelPub = otherBracketMark
			v.Sig = ""
			vh := postBlob("s3", serializeVault(v))
			putHead("s3", name, pass, vh)
			putRef("s3", v.RecoveryRef, vh)
		}
	}
	foreign := func(name, pass string) func(v *vault) {
		return func(v *vault) {
			v.Version += 10
			v.TelPub = otherBracketMark
			signVault(v, randBytes(32)) // a vault another DK signs: the profile deleted and created again
			vh := postBlob("s3", serializeVault(v))
			putHead("s3", name, pass, vh)
			putRef("s3", v.RecoveryRef, vh)
		}
	}
	cases := []struct {
		what  string
		other func(name, pass string) func(v *vault)
		snap  bool
		run   func(name, pass string) error
	}{
		{"PIN change over an unsigned head", unsigned, false, func(n, p string) error { return setStoredPIN("s3", n, p, "482913", nil) }},
		{"rollback over an unsigned head", unsigned, true, func(n, p string) error { _, err := rollbackHead("s3", n, p, 0, nil); return err }},
		{"PIN change over a head another DK signs", foreign, false, func(n, p string) error { return setStoredPIN("s3", n, p, "482913", nil) }},
	}
	for i, c := range cases {
		t.Run(c.what, func(t *testing.T) {
			capLockEnv(t)
			t.Cleanup(clearStaleHit)
			name, pass := fmt.Sprintf("lockswap%d", i), "a head swapped while it waited"
			_, dk := sessionVaultForTest(t, name, pass)
			if c.snap {
				withSnapshot(t, name, pass, dk)
			}
			var err error
			publishBehindWith(t, name, pass, dk, c.other(name, pass), func() { err = c.run(name, pass) })
			if err == nil {
				t.Errorf("the %s was accepted", c.what)
			}
			if v, _, _ := headAndRecovery(t, name, pass); v.TelPub != otherBracketMark {
				t.Error("the swapped head was overwritten")
			}
		})
	}
}

// A rotation retries a head that moved while it waited -- and gives up, with an error, after rotateHeadAttempts.
// The head is moved before every attempt up to the limit and left alone after it, so a rotation that kept trying
// would succeed on the next one.
func TestRotationGivesUpAfterItsAttempts(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, p1, p2 = "lockrotx", "the passphrase before", "the passphrase after"
	_, dk := sessionVaultForTest(t, name, p1)
	attempts := 0
	rotateAfterRead = func() {
		attempts++
		if attempts > rotateHeadAttempts {
			return
		}
		capWrite(name, p1, dk, func() {
			v, err := readSessionVault("s3", name, p1)
			if err != nil {
				panic(err)
			}
			markedNewer(name, p1, dk)(v)
		})
	}
	t.Cleanup(func() { rotateAfterRead = nil })
	_, err := rotateVault("s3", name, p1, p2, nil, true)
	if !errors.Is(err, errRotateHeadMoved) || attempts != rotateHeadAttempts {
		t.Fatalf("a rotation whose head moved before every attempt: %v after %d attempt(s); want errRotateHeadMoved "+
			"after %d", err, attempts, rotateHeadAttempts)
	}
	if _, err := readSessionVault("s3", name, p2); err == nil {
		t.Error("the new passphrase opens a head after a rotation that gave up")
	}
}

// The other vault editors that run behind a re-key batch: a key removal, a rollback and the plan carry clear each
// land on the batch's head.
func TestKeyRemovalDuringAReKeyBatchLandsOnItsHead(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "lockrmv", "a removal over a moved head"
	_, dk := sessionVaultForTest(t, name, pass)
	cred := enrolKeyForTest(t, name, pass)
	var still bool
	var err error
	rv := publishBehindAnotherBracket(t, name, pass, dk, func() {
		still, err = removeFido2Key("s3", name, pass, cred, nil)
	})
	if err != nil || still {
		t.Fatalf("the removal, arriving while another bracket held the lock: still=%v err=%v", still, err)
	}
	v := landedOnTheOtherBracket(t, "removal", name, pass, rv)
	if len(listFido2Slots(v)) != 0 || unwrapDK(v, "pass", deriveKey(name, pass)) == nil {
		t.Error("after the last key's removal the head still has a key slot, or no pass slot")
	}
}

func TestRollbackDuringAReKeyBatchLandsOnItsHead(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "lockrbk", "a rollback over a moved head"
	_, dk := sessionVaultForTest(t, name, pass)
	snap := withSnapshot(t, name, pass, dk)
	var err error
	rv := publishBehindAnotherBracket(t, name, pass, dk, func() { _, err = rollbackHead("s3", name, pass, 0, nil) })
	if err != nil {
		t.Fatalf("the rollback, arriving while another bracket held the lock: %v", err)
	}
	if v := landedOnTheOtherBracket(t, "rollback", name, pass, rv); v.Manifest != snap {
		t.Error("the rollback did not move the live manifest to the snapshot's")
	}
}

func TestPlanCarryClearDuringAReKeyBatchLandsOnItsHead(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "lockprv", "a carry clear over a moved head"
	v, dk := sessionVaultForTest(t, name, pass)
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("the new vault has no scope index")
	}
	idx[scopeBillPrevKey] = scopeRec{Ref: billRefPrefix + profileRefV2(name, "the passphrase before")}
	v.Scopes = sealScopeIndex(dk, idx)
	if err := publishSessionVault("s3", name, pass, v, dk); err != nil {
		t.Fatal(err)
	}
	var cleared bool
	rv := publishBehindAnotherBracket(t, name, pass, dk, func() { cleared = dropBillPrev("s3", name, pass, dk) })
	if !cleared {
		t.Fatal("the carry clear, arriving while another bracket held the lock, did not clear")
	}
	got, err := readSessionVault("s3", name, pass) // the clear republishes head and recovery ref and keeps its version
	if err != nil {
		t.Fatal(err)
	}
	gidx, _ := openScopeIndex(dk, got.Scopes)
	if got.Version != rv || got.TelPub != otherBracketMark || billPrevOf(gidx) != "" {
		t.Errorf("the head reads version %d (marked: %v, record %q); want the other bracket's %d, marked, no record",
			got.Version, got.TelPub == otherBracketMark, short(billPrevOf(gidx)), rv)
	}
}

// An enrol of a credential the head already carries adds no second slot for it.
func TestKeyEnrolOfAnEnrolledKeyAddsNoSlot(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "lockdup", "the same key twice"
	sessionVaultForTest(t, name, pass)
	cred := enrolKeyForTest(t, name, pass)
	_, salt, hm := keyCredForTest("the key to remove")
	if err := enrollFido2("s3", name, pass, cred, salt, hm, false, "nfc", nil); err != nil {
		t.Fatalf("enrolling an enrolled key again: %v", err)
	}
	v, err := readSessionVault("s3", name, pass)
	if err != nil {
		t.Fatal(err)
	}
	if n := len(listFido2Slots(v)); n != 1 {
		t.Errorf("the head carries %d slots for one key", n)
	}
}

// A removal of a key another device removed while this one waited meets the user's intent: it succeeds, and says
// whether any key is left. A credential the vault never had is still an error.
func TestKeyRemovalOfAKeyRemovedMeanwhileSucceeds(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "lockgone", "a key removed elsewhere"
	_, dk := sessionVaultForTest(t, name, pass)
	cred := enrolKeyForTest(t, name, pass)
	if _, err := removeFido2Key("s3", name, pass, base64.StdEncoding.EncodeToString([]byte("never enrolled")), nil); err == nil {
		t.Error("removing a credential the vault never had succeeded")
	}
	removedElsewhere := func(v *vault) {
		kept := []keyslot{{Kind: "pass", Wrapped: wrap(deriveKey(name, pass), dk)}}
		for _, s := range v.Slots {
			if s.Kind != "fido2" {
				kept = append(kept, s)
			}
		}
		v.Slots = kept
		v.TelPub = otherBracketMark
		publishSessionVaultIn("s3", name, pass, v, dk)
	}
	var still bool
	var err error
	publishBehindWith(t, name, pass, dk, removedElsewhere, func() { still, err = removeFido2Key("s3", name, pass, cred, nil) })
	if err != nil || still {
		t.Errorf("removing a key another device had just removed: still=%v err=%v; want success, none left", still, err)
	}
}

// A session verb pending in the daemon holds the background re-key off: rekeyOnce starts no batch, so the verb
// waits for at most one batch that was already open (NWP-20261009-07).
func TestRekeyOnceStandsDownWhileASessionVerbIsPending(t *testing.T) {
	for _, verb := range []string{"ROTATE", "SET-PIN", "REMOVE-FIDO2-KEY", "FIDO2-NFC-ENROLL-FINISH", "ROLLBACK",
		"DELETE-SNAPSHOT", "EXPORT", "EXPORT-MEDIA", "DELETE"} { // DELETE: NWP-20261010-02, its export purge is a bracket
		if !rekeyHoldingVerb(verb) || concurrentSafeCmd(verb) {
			t.Errorf("%s: holds the re-key off %v, waits for sessionMu %v -- it must do both, or the dispatch never "+
				"counts it", verb, rekeyHoldingVerb(verb), !concurrentSafeCmd(verb))
		}
	}
	dest, name, pass := tiedWithMedia(t)
	if err := os.WriteFile(filepath.Join(dest, rekeyArmedFile), []byte("12\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	sessionVerbsInFlight.Add(1)
	rekeyOnce(dest)
	sessionVerbsInFlight.Add(-1)
	if rec := rekeyIndex(t, name, pass)["#media"]; rec.Progress != "" {
		t.Fatal("a re-key batch started while a session verb was pending")
	}
	rekeyOnce(dest)
	if rec := rekeyIndex(t, name, pass)["#media"]; rec.Progress == "" {
		t.Fatal("precondition: no batch ran once nothing was pending")
	}
}

// A stale-check reading armed with no bracket open would be registered into whichever bracket opened next, and
// judge its publishes. Tests make that a panic; nothing may be armed or registered.
func TestCapExpectOutsideABracketIsRefused(t *testing.T) {
	capLockEnv(t)
	if !didPanic(func() { capExpect("test writer", "lock-outside", "v0") }) {
		t.Error("capExpect with no bracket open was accepted")
	}
	capWriteMu.Lock()
	n := len(capBracketExpects)
	capWriteMu.Unlock()
	sealExpectMu.Lock()
	_, armed := sealExpect["ref/lock-outside"]
	sealExpectMu.Unlock()
	if n != 0 || armed {
		t.Errorf("a reading armed with no bracket open was kept (registered %d, armed %v)", n, armed)
	}
}

// What takes capBracketMu, and the functions that implement a bracket rather than run inside one.
var (
	bracketPrimitives = map[string]bool{"capBegin": true, "capBeginAs": true, "capOpen": true, "capBracketLock": true}
	bracketImpls      = map[string]bool{"capBegin": true, "capBeginAs": true, "capOpen": true, "capBracketLock": true,
		"capWriteTo": true, "capWriteAttr": true, "capWrite": true, "capWriteNoLogin": true}
	// Run while a bracket is held: a closer, the flush, and the hand-back a credential change makes after one.
	bracketHeldFns = []string{"capFlush", "capEnd", "capEndBracket", "capAbort", "capBracketRelease",
		"compensateCredentialLease"}
)

// TestNoBracketOpensInsideABracket: capBracketMu is not reentrant, so a bracket opened by the goroutine that
// holds one waits forever -- and every later bracket in the daemon waits behind it, for the rest of the boot
// (NWP-20261009-07). Nothing reachable, by name and transitively within the package, from a capWrite fn, a bare
// capBegin..capFlush region, or the functions that run while a bracket is held may take the lock. A goroutine
// started there counts too: a bracket that waits for it (capFlush's uploads do) is the same wedge.
func TestNoBracketOpensInsideABracket(t *testing.T) {
	fset, files := agentSource(t)
	calls := map[string]map[string]bool{} // function or method name -> the names it calls, by name
	bodies := map[string][]*ast.BlockStmt{}
	callees := func(n ast.Node) map[string]bool {
		out := map[string]bool{}
		ast.Inspect(n, func(n ast.Node) bool {
			if c, ok := n.(*ast.CallExpr); ok {
				switch f := c.Fun.(type) {
				case *ast.Ident:
					out[f.Name] = true
				case *ast.SelectorExpr:
					out[f.Sel.Name] = true
				}
				for _, arg := range c.Args { // a function passed by name runs where it is passed
					if id, ok := arg.(*ast.Ident); ok {
						out[id.Name] = true
					}
				}
			}
			return true
		})
		return out
	}
	for _, af := range files {
		for _, d := range af.Decls {
			if fd, ok := d.(*ast.FuncDecl); ok && fd.Body != nil {
				name := fd.Name.Name
				bodies[name] = append(bodies[name], fd.Body)
				if calls[name] == nil {
					calls[name] = map[string]bool{}
				}
				for c := range callees(fd.Body) {
					calls[name][c] = true
				}
			}
		}
	}
	// The openers: a primitive, or anything that calls one, to a fixed point.
	opener := map[string]bool{}
	for p := range bracketPrimitives {
		opener[p] = true
	}
	for changed := true; changed; {
		changed = false
		for name, cs := range calls {
			if opener[name] {
				continue
			}
			for c := range cs {
				if opener[c] {
					opener[name], changed = true, true
					break
				}
			}
		}
	}
	chain := func(from string) string { // the shortest call chain from an opener to a primitive, for the message
		prev := map[string]string{from: ""}
		for q := []string{from}; len(q) > 0; q = q[1:] {
			n := q[0]
			if bracketPrimitives[n] {
				var p []string
				for x := n; x != ""; x = prev[x] {
					p = append([]string{x}, p...)
				}
				return strings.Join(p, " -> ")
			}
			for c := range calls[n] {
				if _, ok := prev[c]; !ok && opener[c] {
					prev[c] = n
					q = append(q, c)
				}
			}
		}
		return from
	}
	var bad []string
	check := func(where string, names map[string]bool) {
		for c := range names {
			if opener[c] {
				bad = append(bad, where+": "+chain(c))
			}
		}
	}
	regions := 0
	for _, af := range files {
		for _, d := range af.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Body == nil || bracketImpls[fd.Name.Name] {
				continue
			}
			for _, fl := range bracketFnArgs(fd.Body) {
				regions++
				check(fset.Position(fl.Pos()).String()+" (a capWrite fn in "+fd.Name.Name+")", callees(fl.Body))
			}
			// A bare bracket: everything after the first capBegin in the body runs inside it.
			var begin token.Pos
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				if c, ok := n.(*ast.CallExpr); ok && begin == token.NoPos {
					if id, ok := c.Fun.(*ast.Ident); ok && (id.Name == "capBegin" || id.Name == "capBeginAs") {
						begin = c.End()
					}
				}
				return true
			})
			if begin != token.NoPos {
				regions++
				after := map[string]bool{}
				ast.Inspect(fd.Body, func(n ast.Node) bool {
					if c, ok := n.(*ast.CallExpr); ok && c.Pos() > begin {
						for k := range callees(c) {
							after[k] = true
						}
					}
					return true
				})
				check(fset.Position(begin).String()+" (the bare bracket in "+fd.Name.Name+")", after)
			}
		}
	}
	for _, name := range bracketHeldFns {
		if len(bodies[name]) == 0 {
			t.Errorf("%s is listed as running inside a bracket but no such function exists: this test is stale", name)
		}
		for _, b := range bodies[name] {
			regions++
			check(name, callees(b))
		}
	}
	if regions < 20 {
		t.Fatalf("only %d bracket regions found -- this test is looking in the wrong place", regions)
	}
	if len(bad) > 0 {
		sort.Strings(bad)
		t.Errorf("a bracket can be opened from inside a bracket -- capBracketMu is not reentrant, so that is a "+
			"permanent wedge (NWP-20261009-07):\n  %s", strings.Join(bad, "\n  "))
	}
}

// fenceCreateHeadAtFlush arms the delete fence on (name, pass)'s head as the flush starts uploading -- after
// createVault's lift and its in-bracket writes, before its pointer pass -- as a delete landing mid-create would.
func fenceCreateHeadAtFlush(name, pass string) {
	head := profileRefV2(name, pass)
	var once sync.Once
	capStorePutHook = func(key string, _ []byte) error {
		if strings.HasPrefix(key, "blob/") {
			once.Do(func() { armSealFence([]string{head}) })
		}
		return nil
	}
}

// NWP-20261011-52: a create whose head the store refused at publish is a failed create. It returned the 12 words
// anyway, and the gate showed a recovery code for a profile that did not exist.
func TestCreateVaultRefusedAtPublishReturnsNoRecoveryCode(t *testing.T) {
	objs, mu := capLockEnv(t)
	fenceTestEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "lockcreate", "a head fenced at the flush"
	fenceCreateHeadAtFlush(name, pass)
	var mnemonic string
	var got any
	func() {
		defer func() { got = recover() }()
		mnemonic = createVault("s3", name, pass)
	}()
	if e, _ := got.(error); !errors.Is(e, errCreateRefused) {
		t.Errorf("createVault over a refused head: panic %v, want errCreateRefused", got)
	}
	if mnemonic != "" {
		t.Error("createVault handed back a recovery code for a head the store refused")
	}
	mu.Lock()
	_, landed := objs["ref/"+profileRefV2(name, pass)]
	mu.Unlock()
	if landed {
		t.Fatal("precondition: the fenced head was published, so this test checks nothing")
	}
}

// The gate's CREATE says BLANK, as for any failed create, and never shows the 12 words.
func TestCreateReplyOverARefusedHeadIsBlank(t *testing.T) {
	capLockEnv(t)
	fenceTestEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "lockcreatereply", "a head fenced at the flush"
	fenceCreateHeadAtFlush(name, pass)
	dest := t.TempDir()
	c1, c2 := net.Pipe()
	go func() {
		defer c1.Close()
		createAndReply(c1, dest, name, pass)
	}()
	reply, _ := io.ReadAll(c2)
	if got := dropCreateProgress(strings.TrimSpace(string(reply))); got != "BLANK" {
		t.Errorf("CREATE over a refused head answered %q, want BLANK", got)
	}
}

// A create the store accepts still returns its 12 words, and the head it published opens -- through the cap
// bracket, and through the direct-mode bracket it now also rides.
func TestCreateVaultLandsInBothModes(t *testing.T) {
	check := func(t *testing.T, base, name, pass string) {
		t.Helper()
		mnemonic := createVault(base, name, pass)
		if n := len(strings.Fields(mnemonic)); n != 12 {
			t.Fatalf("createVault returned %d recovery words, want 12", n)
		}
		hd, v, ok := readVaultHead(base, name, pass)
		if !ok || v == nil {
			t.Fatal("the created profile has no vault head")
		}
		if resolveDK(base, name, pass, nil) == nil {
			t.Error("the created head does not open with its passphrase")
		}
		if rec := getRef(base, v.RecoveryRef); rec != hd.val {
			t.Errorf("the recovery ref names %s while the head names %s", short(rec), short(hd.val))
		}
	}
	t.Run("cap", func(t *testing.T) {
		capLockEnv(t)
		check(t, "s3", "lockcreatecap", "a create that lands")
	})
	t.Run("direct", func(t *testing.T) {
		base := newHTTPStore(t)
		t.Setenv("GATEWAY_URL", "")
		check(t, base, "lockcreatedirect", "a create that lands")
	})
}

// enrollUnitAtLogin is best-effort at login: a refused directory write is logged, without the profile's name,
// and never escapes as a panic that could un-gate the login.
func TestEnrollUnitAtLoginRefusedIsLoggedNotRaised(t *testing.T) {
	capLockEnv(t)
	fenceTestEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "lockenrol", "a directory write that is refused"
	orig := unitIDPath
	t.Cleanup(func() { unitIDPath = orig })
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")
	createVault("s3", name, pass)
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	armSealFence([]string{accountDirRef(name, pass)})
	var raised any
	logged := captureStderr(t, func() {
		defer func() { raised = recover() }()
		enrollUnitAtLogin("s3", name, pass, nil)
	})
	if raised != nil {
		t.Fatalf("enrollUnitAtLogin let a panic out: %v", raised)
	}
	dk := resolveDK("s3", name, pass, nil)
	if _, ok := loadAccountDir("s3", name, pass, dk); ok {
		t.Fatal("precondition: the fenced directory was published, so this test checks nothing")
	}
	if !strings.Contains(logged, "refused at publish") {
		t.Errorf("a refused directory write was not logged; stderr: %q", logged)
	}
	if strings.Contains(logged, name) {
		t.Errorf("the refusal line names the profile: %q", logged)
	}
}
