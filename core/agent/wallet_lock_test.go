package main

import (
	"bufio"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"go/ast"
	"math"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// NWP-20261010-04: the wallet file has one writer at a time, across processes (wallet_lock.go). The races below
// are forced, not hoped for: the fake gateway holds the flush INSIDE its wallet window (in its /lease handler)
// until the other writer has either written (no lock: the race happens) or reported that it found the wallet
// lock held (walletLockTrace "wait": the lock is there). Nothing sleeps to synchronise, so the outcome does not
// depend on scheduling either way. The 10 s timer is only a backstop, and a test that hits it fails.

// walletLockWaits installs walletLockTrace and returns a channel closed the first time a lockWallet finds the
// lock held by someone else.
func walletLockWaits(t *testing.T) <-chan struct{} {
	t.Helper()
	ch := make(chan struct{})
	waits := closer(ch)
	walletLockTrace = func(event string) {
		if event == "wait" {
			waits()
		}
	}
	t.Cleanup(func() { walletLockTrace = nil })
	return ch
}

// walletLockHeld probes the wallet lock from a descriptor of its own: true when someone holds it.
func walletLockHeld(t *testing.T, wpath string) bool {
	t.Helper()
	f, err := os.OpenFile(wpath+".lock", os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	err = unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB)
	if err == nil {
		_ = unix.Flock(int(f.Fd()), unix.LOCK_UN)
		return false
	}
	if errors.Is(err, unix.EWOULDBLOCK) {
		return true
	}
	t.Fatalf("probing the wallet lock: %v", err)
	return false
}

// TestWalletLockHelperProcess is not a test: it is the OTHER PROCESS for TestWalletLockExcludesAnotherProcess,
// re-executed from the test binary. It takes the lock, says so on stdout, and holds it until stdin closes.
func TestWalletLockHelperProcess(t *testing.T) {
	p := os.Getenv("NOWHERE_WALLET_LOCK_HELPER")
	if p == "" {
		return
	}
	unlock := lockWallet(p)
	fmt.Println("locked")
	_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
	unlock()
}

// The seal worker is a separate process paying from the same file, so the lock must exclude ACROSS processes: a
// lockWallet here does not return until the other process has let go.
func TestWalletLockExcludesAnotherProcess(t *testing.T) {
	p := filepath.Join(t.TempDir(), "wallet.json")
	cmd := exec.Command(os.Args[0], "-test.run=^TestWalletLockHelperProcess$", "-test.count=1")
	cmd.Env = append(os.Environ(), "NOWHERE_WALLET_LOCK_HELPER="+p)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Wait()
	defer stdin.Close()
	locked := make(chan bool, 1)
	go func() {
		sc := bufio.NewScanner(stdout)
		for sc.Scan() {
			if sc.Text() == "locked" {
				locked <- true
				for sc.Scan() { // drain, so the child never blocks writing PASS
				}
				return
			}
		}
		locked <- false
	}()
	if !<-locked {
		t.Fatal("the helper process never reported holding the lock")
	}
	if !walletLockHeld(t, p) {
		t.Fatal("the helper process says it holds the wallet lock, but a probe from this process got it")
	}

	waits := walletLockWaits(t)
	var released atomic.Bool
	got := make(chan bool, 1)
	go func() {
		unlock := lockWallet(p)
		got <- released.Load()
		unlock()
	}()
	select {
	case <-waits:
	case <-time.After(10 * time.Second):
		t.Fatal("lockWallet never found the other process's lock held")
	}
	released.Store(true)
	stdin.Write([]byte("release\n"))
	stdin.Close()
	select {
	case afterRelease := <-got:
		if !afterRelease {
			t.Fatal("lockWallet returned while the other process still held the lock")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("lockWallet did not return after the other process released the lock")
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("helper process: %v", err)
	}
}

// Two lockWallet calls in ONE process exclude each other too: each opens its own descriptor, and the daemon's
// goroutines (payRent, a claim, an export's flush) rely on that.
func TestWalletLockExcludesWithinAProcess(t *testing.T) {
	p := filepath.Join(t.TempDir(), "wallet.json")
	waits := walletLockWaits(t)
	first := lockWallet(p)
	var released atomic.Bool
	got := make(chan bool, 1)
	go func() {
		unlock := lockWallet(p)
		got <- released.Load()
		unlock()
	}()
	select {
	case <-waits:
	case <-time.After(10 * time.Second):
		first()
		t.Fatal("the second lockWallet never found the first one's lock held")
	}
	released.Store(true)
	first()
	select {
	case afterRelease := <-got:
		if !afterRelease {
			t.Fatal("the second lockWallet returned while the first still held the lock")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the second lockWallet did not return after the first released")
	}
}

// The release is idempotent: an early release plus a deferred one must not release a lock someone ELSE has
// taken in between.
func TestWalletUnlockIsIdempotent(t *testing.T) {
	p := filepath.Join(t.TempDir(), "wallet.json")
	first := lockWallet(p)
	if !walletLockHeld(t, p) {
		t.Fatal("control: the probe cannot see a held wallet lock, so the assertions below prove nothing")
	}
	first()
	if walletLockHeld(t, p) {
		t.Fatal("the wallet lock is still held after its release")
	}
	second := lockWallet(p)
	defer second()
	first() // the deferred second call of the first holder
	if !walletLockHeld(t, p) {
		t.Fatal("a repeated release dropped a lock another holder had taken since")
	}
}

// FAIL OPEN: a lock that cannot be opened must not wedge the caller, and a lock that is never released is
// waited for at most walletLockWait. Either way the caller proceeds unlocked, as it did before the lock.
func TestWalletLockFailsOpen(t *testing.T) {
	t.Run("unopenable lock file", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "no-such-dir", "wallet.json")
		start := time.Now()
		unlock := lockWallet(p)
		if d := time.Since(start); d > 2*time.Second {
			t.Fatalf("lockWallet took %s on an unopenable lock file; it must give up at once", d)
		}
		unlock()
		unlock()
	})
	t.Run("held past the deadline", func(t *testing.T) {
		old := walletLockWait
		walletLockWait = 300 * time.Millisecond
		t.Cleanup(func() { walletLockWait = old })
		p := filepath.Join(t.TempDir(), "wallet.json")
		holder := lockWallet(p)
		defer holder()
		start := time.Now()
		unlock := lockWallet(p)
		d := time.Since(start)
		if d < walletLockWait {
			t.Fatalf("lockWallet returned after %s, before walletLockWait (%s), while the lock was held", d, walletLockWait)
		}
		if d > walletLockWait+5*time.Second {
			t.Fatalf("lockWallet took %s against a %s deadline", d, walletLockWait)
		}
		unlock()
		if !walletLockHeld(t, p) {
			t.Fatal("the timed-out caller's no-op release dropped the holder's lock")
		}
	})
	// lockWalletWithin says which of the two it was: capFlush gives the wallet up on BUSY and proceeds on
	// UNAVAILABLE, so the two must not be confused.
	t.Run("lockWalletWithin names the outcome", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "wallet.json")
		if u, st := lockWalletWithin(filepath.Join(t.TempDir(), "no-such-dir", "wallet.json"), time.Second); st != walletLockUnavailable {
			t.Errorf("an unopenable lock file reported state %d, want walletLockUnavailable", st)
		} else {
			u()
		}
		holder, st := lockWalletWithin(p, time.Second)
		if st != walletLocked {
			t.Fatalf("a free lock reported state %d, want walletLocked", st)
		}
		defer holder()
		u, st := lockWalletWithin(p, 200*time.Millisecond)
		u()
		if st != walletLockBusy {
			t.Errorf("a held lock reported state %d after the wait, want walletLockBusy", st)
		}
	})
}

// walletRaceEnv is a cap-mode device (no store creds) on the fake gateway with an empty state dir. The wallet
// does not exist yet: a flush or vault creation run before the test funds it must not create it.
func walletRaceEnv(t *testing.T) string {
	t.Helper()
	srv, objs, mu := mockCapStore(t)
	walletStoreObjs = func(key string) bool {
		mu.Lock()
		defer mu.Unlock()
		_, ok := objs[key]
		return ok
	}
	t.Cleanup(func() { walletStoreObjs = nil })
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	capReadCache = map[string]capEntry{}
	blobCache = nil
	freeRenewedThrough = map[string]int64{}
	noWalletRenewed = map[string]*Wallet{}
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	return wpath
}

// fundWallet writes a wallet holding n faucet tokens from the fake gateway (unique nonces) and returns them.
func fundWallet(t *testing.T, wpath string, n int) []Token {
	t.Helper()
	var toks []Token
	if n > 0 {
		var err error
		if toks, err = newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault).buyFaucet(n); err != nil {
			t.Fatal(err)
		}
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	return toks
}

// throwawayFlush is a bracket with no session: capFlush's legacy paid arm, which spends from the wallet.
func throwawayFlush(body string) {
	n := capBegin()
	defer capEndBracket(n)
	postBlob("s3", []byte(body))
	capFlush(n)
}

// spentBy is the nonces mockCapStore's paid /lease charges for req: the first `owed` presented, owed being one
// token per started GiB (minimum one), exactly as the handler computes it.
func spentBy(req leaseReq) []string {
	var total int64
	for _, sz := range req.Refs {
		total += sz
	}
	owed := int(math.Ceil(float64(total) / float64(giB)))
	if owed == 0 {
		owed = 1
	}
	if owed > len(req.Tokens) {
		owed = len(req.Tokens)
	}
	var out []string
	for _, tk := range req.Tokens[:owed] {
		out = append(out, tk.Nonce)
	}
	return out
}

// walletNonces is every token nonce in the saved wallet.
func walletNonces(t *testing.T, wpath string) (*Wallet, map[string]bool) {
	t.Helper()
	w, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]bool{}
	for _, tk := range w.Tokens {
		out[tk.Nonce] = true
	}
	return w, out
}

// THE ROW'S CLOSING TEST: payRent and a seal's flush spend from the same wallet at once, and BOTH spends are in
// the saved wallet. Before the lock, each loaded the same file, presented the same first token, and whichever
// saved second erased the other's spend: one token gone from the gateway, still in the wallet, presented twice.
func TestPayRentAndAFlushBothSpendsLand(t *testing.T) {
	wpath := walletRaceEnv(t)
	const name, pass = "alice", "rent and a seal at the same time"
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), []byte("the profile's data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", name, pass, src)
	const initial = 10
	fundWallet(t, wpath, initial)

	var mu sync.Mutex
	var flushSpent, rentSpent []string
	how := ""
	flushIn, rentLeased := make(chan struct{}), make(chan struct{})
	enterFlush, rentArrived := closer(flushIn), closer(rentLeased)
	lockWaits := walletLockWaits(t)
	capStoreLeaseSeen = func(req leaseReq) {
		if len(req.Tokens) == 0 {
			return // a free lease (the profile's own seals, payRent's durable wallet seal): spends nothing
		}
		sp := spentBy(req)
		if req.Profile == "" { // the throwaway flush's paid lease: hold it inside its wallet window
			mu.Lock()
			flushSpent = append(flushSpent, sp...)
			mu.Unlock()
			enterFlush()
			var h string
			select {
			case <-rentLeased:
				h = "payRent leased inside the flush's wallet window"
			case <-lockWaits:
				h = "payRent waited for the wallet lock"
			case <-time.After(10 * time.Second):
			}
			mu.Lock()
			how = h
			mu.Unlock()
			return
		}
		mu.Lock()
		rentSpent = append(rentSpent, sp...)
		mu.Unlock()
		rentArrived()
	}
	panics := runAll(
		func() {
			defer enterFlush() // a flush that died before its lease must not leave payRent waiting forever
			throwawayFlush("a seal's chunk, paid for by the session wallet")
		},
		func() {
			<-flushIn
			if _, paid, err := payRent(newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault), "s3", name, pass, wpath, nil); err != nil || !paid {
				panic(fmt.Sprintf("payRent: paid=%v err=%v", paid, err))
			}
		},
	)
	// Errorf, not Fatalf: unlocked, the two saves can also collide on saveWallet's shared .tmp name and fail
	// one writer outright, and the wallet it leaves is still worth asserting on.
	if len(panics) != 0 {
		t.Errorf("panics: %v", panics)
	}
	mu.Lock()
	defer mu.Unlock()
	if how == "" {
		t.Fatal("the race was never reached: payRent neither leased nor waited for the wallet lock while the flush was in its window")
	}
	t.Logf("interleaving: %s", how)
	if len(flushSpent) != 1 || len(rentSpent) != 1 {
		t.Fatalf("want one token spent by each lease, got flush=%v rent=%v", flushSpent, rentSpent)
	}
	if flushSpent[0] == rentSpent[0] {
		t.Errorf("both leases spent nonce %s: payRent presented a token the flush had already spent", flushSpent[0])
	}
	w, held := walletNonces(t, wpath)
	if got, want := w.balance(), initial-2; got != want {
		t.Errorf("saved wallet holds %d token(s), want %d -- one of the two spends was erased by the other's save", got, want)
	}
	for _, n := range append(append([]string(nil), flushSpent...), rentSpent...) {
		if held[n] {
			t.Errorf("the saved wallet still holds %s, which the gateway charged: a resurrected nonce", n)
		}
	}
}

// A claim landing while a flush is in its wallet window: the claimed tokens are bearer instruments the gateway
// cannot re-issue, and before the lock the flush's save dropped them. Driven through drainClaim against a fake
// blind issuer, so it is the device's real claim path.
func TestAClaimDuringAFlushIsKept(t *testing.T) {
	wpath := walletRaceEnv(t)
	const initial, claimed = 3, 4
	fundWallet(t, wpath, initial)
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	issuer := blindGateway(t, priv, "CLAIM-DURING-FLUSH", claimed)
	defer issuer.Close()

	var mu sync.Mutex
	var flushSpent []string
	how := ""
	flushIn, drained := make(chan struct{}), make(chan struct{})
	enterFlush, drainDone := closer(flushIn), closer(drained)
	lockWaits := walletLockWaits(t)
	capStoreLeaseSeen = func(req leaseReq) {
		if req.Profile != "" || len(req.Tokens) == 0 {
			return
		}
		mu.Lock()
		flushSpent = append(flushSpent, spentBy(req)...)
		mu.Unlock()
		enterFlush()
		var h string
		select {
		case <-drained:
			h = "the claim minted and saved inside the flush's wallet window"
		case <-lockWaits:
			h = "the claim waited for the wallet lock"
		case <-time.After(10 * time.Second):
		}
		mu.Lock()
		how = h
		mu.Unlock()
	}
	var n int
	var drainErr error
	panics := runAll(
		func() {
			defer enterFlush()
			throwawayFlush("a seal's chunk while a claim lands")
		},
		func() {
			defer drainDone()
			<-flushIn
			n, drainErr = drainClaim(newGatewayClient(issuer.URL, gwDefault), wpath, "CLAIM-DURING-FLUSH", false)
		},
	)
	if len(panics) != 0 {
		t.Fatalf("panics: %v", panics)
	}
	if drainErr != nil || n != claimed {
		t.Fatalf("drainClaim: n=%d err=%v, want %d", n, drainErr, claimed)
	}
	mu.Lock()
	defer mu.Unlock()
	if how == "" {
		t.Fatal("the race was never reached: the claim neither saved nor waited for the wallet lock while the flush was in its window")
	}
	t.Logf("interleaving: %s", how)
	w, held := walletNonces(t, wpath)
	if len(w.BlindTokens) != claimed {
		t.Errorf("the saved wallet holds %d of the %d claimed token(s) -- the flush's save dropped the rest", len(w.BlindTokens), claimed)
	}
	if len(flushSpent) != 1 {
		t.Fatalf("want the flush to spend one token, got %v", flushSpent)
	}
	if held[flushSpent[0]] {
		t.Errorf("the saved wallet still holds %s, which the flush's lease spent", flushSpent[0])
	}
	if got, want := w.balance(), initial-1+claimed; got != want {
		t.Errorf("saved wallet holds %d token(s), want %d", got, want)
	}
}

// A claim waits for a busy wallet BEFORE it mints, so a daemon killed during the wait loses
// nothing. Minted-but-unsaved tokens are bearer instruments the gateway cannot re-issue.
func TestAClaimMintsNothingWhileTheWalletIsBusy(t *testing.T) {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	issuer := blindGateway(t, priv, "CLAIM-BUSY", 4)
	defer issuer.Close()
	var mints atomic.Int32
	inner := issuer.Config.Handler
	counting := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/issue" {
			mints.Add(1)
		}
		inner.ServeHTTP(w, r)
	}))
	defer counting.Close()
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}

	waits := walletLockWaits(t)
	holder := lockWallet(wpath)
	type result struct {
		n   int
		err error
	}
	got := make(chan result, 1)
	go func() {
		n, err := drainClaim(newGatewayClient(counting.URL, gwDefault), wpath, "CLAIM-BUSY", false)
		got <- result{n, err}
	}()
	select {
	case <-waits:
	case <-time.After(10 * time.Second):
		holder()
		t.Fatal("drainClaim never waited for the held wallet lock")
	}
	if m := mints.Load(); m != 0 {
		t.Errorf("drainClaim minted %d batch(es) while the wallet lock was held elsewhere -- those tokens existed only "+
			"in memory for the whole wait", m)
	}
	holder()
	r := <-got
	if r.err != nil || r.n != 4 {
		t.Fatalf("drainClaim: n=%d err=%v, want 4", r.n, r.err)
	}
	if w, _ := loadWallet(wpath); len(w.BlindTokens) != 4 {
		t.Fatalf("wallet holds %d claimed token(s), want 4", len(w.BlindTokens))
	}
}

// sessionFlush is a profile's own bracket (the free/entitled arms, and the wallet fold).
func sessionFlush(name, pass, body string) {
	n := capBegin()
	defer capEndBracket(n)
	capSetSession(name, pass, deriveKey(name, pass))
	postBlob("s3", []byte(body))
	capFlush(n)
}

// A flush that panics inside its wallet window releases the lock: a held one would make every later wallet
// writer in the process wait out walletLockWait and then run unlocked.
func TestAFlushThatPanicsInItsWalletWindowReleasesTheLock(t *testing.T) {
	for _, tc := range []struct {
		name    string
		tokens  int
		status  int    // the fake gateway's answer to every lease; 0 = its default
		body    string // ...and the body it answers with
		session bool   // a profile's bracket (the entitled arm) rather than a throwaway's
		panic   string // what the panic must say, so each case is known to die where it claims to
	}{
		{"lease answers 500 (fail)", 3, http.StatusInternalServerError, "", false, "cap-flush lease: HTTP 500"},
		{"lease answers 402 (fail)", 3, http.StatusPaymentRequired, "", false, "cap-flush lease: HTTP 402"},
		{"no credit to pay with (errInsufficientCredit)", 0, 0, "", false, errInsufficientCredit.Error()},
		{"entitled lease answers 402 (creditRefused)", 0, http.StatusPaymentRequired, `{"error":"no plan covers this"}`, true, "gateway said: no plan covers this"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			wpath := walletRaceEnv(t)
			fundWallet(t, wpath, tc.tokens)
			if tc.status != 0 {
				capStoreLeaseStatus = func(leaseReq) (int, string) { return tc.status, tc.body }
			}
			panics := runAll(func() {
				if tc.session {
					sessionFlush("alice", "a refused profile seal", "a chunk whose entitled lease is refused")
				} else {
					throwawayFlush("a chunk whose lease is refused")
				}
			})
			if len(panics) != 1 || !strings.Contains(fmt.Sprint(panics[0]), tc.panic) {
				t.Fatalf("want the flush to panic inside its wallet window with %q, got %d panic(s): %v", tc.panic, len(panics), panics)
			}
			if _, err := os.Stat(wpath + ".lock"); err != nil {
				t.Fatalf("the flush never took the wallet lock (%v), so this test proves nothing", err)
			}
			if walletLockHeld(t, wpath) {
				t.Fatalf("the wallet lock is still held after the flush panicked (%v)", panics[0])
			}
		})
	}
}

// In the seal WORKER, capFlush's wait for the wallet lock is progress-silent, and the
// daemon's watchdog reports ERR-TIMEOUT after roamStallBudget without a change in roam.progress. So the wait is
// capFlushWalletWait however long the holder keeps the lock (walletLockWait is set to an hour here to prove it
// is not the one used), and a wallet still busy after it is given up for the flush: nothing is spent, folded or
// saved, and the data still lands. TestSealGatewayLegFitsTheStallBudget holds the production value to the budget.
func TestAFlushFacingABusyWalletGivesItUpWithinItsBound(t *testing.T) {
	wpath := walletRaceEnv(t)
	oldWait, oldFlush := walletLockWait, capFlushWalletWait
	walletLockWait, capFlushWalletWait = time.Hour, 300*time.Millisecond
	t.Cleanup(func() { walletLockWait, capFlushWalletWait = oldWait, oldFlush })
	// A funded purchase waiting to start: a flush that owned this wallet would present every token.
	toks, err := newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault).buyFaucet(3)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks, PlanGB: 1, PlanPeriods: 1}); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(wpath)
	const name, pass = "alice", "a seal behind a busy wallet"
	var presented atomic.Int32
	capStoreLeaseSeen = func(req leaseReq) { presented.Add(int32(len(req.Tokens) + len(req.BlindTokens))) }

	holder := lockWallet(wpath) // payRent mid-lease, say -- for as long as it likes
	done := make(chan []any, 1)
	start := time.Now()
	go func() { done <- runAll(func() { sessionFlush(name, pass, "data that must land anyway") }) }()
	var panics []any
	select {
	case panics = <-done:
	case <-time.After(10 * time.Second):
		holder()
		<-done
		t.Fatal("the flush waited on the busy wallet past 10 s -- in the seal worker that silence is a false ERR-TIMEOUT")
	}
	holder()
	if len(panics) != 0 {
		t.Fatalf("the flush panicked behind a busy wallet: %v", panics)
	}
	t.Logf("the flush finished %s after it started", time.Since(start).Round(time.Millisecond))
	if p := presented.Load(); p != 0 {
		t.Errorf("the flush presented %d token(s) from a wallet it could not lock", p)
	}
	if after, _ := os.ReadFile(wpath); string(after) != string(before) {
		t.Error("the flush wrote a wallet it could not lock")
	}
	wref, _ := headWriteRef(name+"#wallet", pass)
	if walletStoreHas(t, "ref/"+wref) {
		t.Error("the flush published a wallet head from a wallet it could not lock")
	}
	if !walletStoreHas(t, "blob/"+hashHex([]byte("data that must land anyway"))) {
		t.Error("the flush's data did not land -- giving up the wallet must not give up the seal")
	}
}

// walletStoreObjs is the fake store's object map for the current test (set by walletRaceEnv).
var walletStoreObjs func(key string) bool

func walletStoreHas(t *testing.T, key string) bool {
	t.Helper()
	if walletStoreObjs == nil {
		t.Fatal("walletRaceEnv did not record the fake store")
	}
	return walletStoreObjs(key)
}

func hashHex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// The #wallet head is PUT last, after the wallet lock was released, so another writer may act in between -- and
// payRent, which the lock schedules into exactly this phase, is the usual one. putWalletHead decides by the
// generation and the file (see its comment), and each rule has a case here, the control first: with nothing in
// between, the head is published. The case that matters most for money is the THIRD: a holder that takes the
// lock and lets go without writing -- a lease that failed, a drain that minted nothing -- must not cost the head,
// because nobody else will publish it, and the next login would restore the pre-purchase wallet.
func TestAFlushLeavesItsWalletHeadToALaterWriter(t *testing.T) {
	spendOne := func(t *testing.T, wpath string) {
		w, err := loadWallet(wpath)
		if err != nil {
			t.Fatal(err)
		}
		w.Tokens = w.Tokens[1:]
		if err := saveWallet(wpath, w); err != nil {
			t.Fatal(err)
		}
	}
	for _, tc := range []struct {
		name string
		// act runs at the fold-blob PUT, the last step before the pointers. It returns what to run once the
		// flush has finished: a holder that keeps the lock through the head check lets go there.
		act           func(t *testing.T, wpath string) (after func())
		wantPublished bool
	}{
		{"nothing in between", nil, true},
		{"a writer saves and lets go", func(t *testing.T, wpath string) func() {
			unlock := lockWallet(wpath)
			spendOne(t, wpath)
			unlock()
			return nil
		}, false},
		{"a holder keeps the lock and writes nothing", func(t *testing.T, wpath string) func() {
			return lockWallet(wpath)
		}, true},
		{"a holder saves and keeps the lock", func(t *testing.T, wpath string) func() {
			unlock := lockWallet(wpath)
			spendOne(t, wpath)
			return unlock
		}, false},
		{"the session ends (a sign-in removes the wallet)", func(t *testing.T, wpath string) func() {
			removeWallet(wpath)
			return nil
		}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			wpath := walletRaceEnv(t)
			fundWallet(t, wpath, 2)
			const name, pass, body = "alice", "a head that must not go back", "the session's data"
			dataKey := "blob/" + hashHex([]byte(body))
			var after func()
			capStorePutHook = func(k string, _ []byte) error {
				if strings.HasPrefix(k, "blob/") && k != dataKey && tc.act != nil { // the fold blob, before the pointers
					a := tc.act
					tc.act = nil
					after = a(t, wpath)
				}
				return nil
			}
			if panics := runAll(func() { sessionFlush(name, pass, body) }); len(panics) != 0 {
				t.Fatalf("panics: %v", panics)
			}
			if after != nil {
				after()
			}
			wref, _ := headWriteRef(name+"#wallet", pass)
			if got := walletStoreHas(t, "ref/"+wref); got != tc.wantPublished {
				t.Errorf("wallet head published = %v, want %v", got, tc.wantPublished)
			}
		})
	}
}

// A SCOPE flush can buy -- #media is often where an over-free customer's plan gets bought, while the vault flush
// holds it inside the jitter -- and when it does it must publish the post-spend wallet at the PROFILE's head
// itself, folded under the PROFILE's key: nothing else will, and every earlier wallet head now defers to the
// file it saved. A scope flush that buys nothing must not write the wallet at all.
func TestAScopeFlushPublishesWhatItBuys(t *testing.T) {
	const name, pass = "alice", "a scope that buys the plan"
	t.Run("buys", func(t *testing.T) {
		wpath := walletRaceEnv(t)
		if createVault("s3", name, pass) == "" {
			t.Fatal("createVault returned no recovery code")
		}
		toks, err := newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault).buyFaucet(3)
		if err != nil {
			t.Fatal(err)
		}
		if err := saveWallet(wpath, &Wallet{Tokens: toks, PlanGB: 1, PlanPeriods: 1}); err != nil {
			t.Fatal(err)
		}
		var presented []string
		capStoreLeaseSeen = func(req leaseReq) {
			for _, tk := range req.Tokens {
				presented = append(presented, tk.Nonce)
			}
		}
		dk := resolveDK("s3", name, pass, nil)
		if dk == nil {
			t.Fatal("cannot resolve the profile key")
		}
		if panics := runAll(func() {
			n := capBegin()
			defer capEndBracket(n)
			capSetSession(name+"#media", pass, deriveKey(name+"#media", pass))
			postBlob("s3", []byte("a photo"))
			capFlush(n)
		}); len(panics) != 0 {
			t.Fatalf("panics: %v", panics)
		}
		if len(presented) == 0 {
			t.Fatal("control: the scope flush presented no tokens -- the purchase this test is about never happened")
		}
		stored := readStoredWallet("s3", name, pass, dk)
		if stored == nil {
			t.Fatal("the scope flush bought and published no wallet at the profile's head")
		}
		for _, tk := range stored.Tokens {
			if tk.Nonce == presented[0] {
				t.Errorf("the published wallet still holds %s, which the scope flush spent", tk.Nonce)
			}
		}
		local, _ := loadWallet(wpath)
		if local.balance() != stored.balance() {
			t.Errorf("the published wallet holds %d token(s), the saved one %d", stored.balance(), local.balance())
		}
	})
	t.Run("buys nothing", func(t *testing.T) {
		wpath := walletRaceEnv(t)
		fundWallet(t, wpath, 0) // no credit: nothing to buy with
		// Over the free allowance, under a live grant: the flush learns FreeFullEpoch -- bookkeeping it used to SAVE.
		capStoreLeaseStatus = func(r leaseReq) (int, string) {
			if r.Free {
				return http.StatusPaymentRequired, ""
			}
			return http.StatusOK, ""
		}
		before, _ := os.ReadFile(wpath)
		if panics := runAll(func() {
			n := capBegin()
			defer capEndBracket(n)
			capSetSession(name+"#media", pass, deriveKey(name+"#media", pass))
			postBlob("s3", []byte("a photo under the free allowance"))
			capFlush(n)
		}); len(panics) != 0 {
			t.Fatalf("panics: %v", panics)
		}
		if after, _ := os.ReadFile(wpath); string(after) != string(before) {
			t.Error("a scope flush that bought nothing wrote the wallet -- a save no publish of its own will follow")
		}
	})
}

// THE SIGN-IN INTERLEAVING (NWP-20261010-04): A's payRent is mid-lease, holding the wallet lock, when B signs in.
// The sign-in must finish within its bound, B's wallet file must be B's, and A's head must carry A's spend --
// published by value under A's key, never saved into B's file.
func TestPayRentAcrossASignIn(t *testing.T) {
	wpath := walletRaceEnv(t)
	old := walletSignInWait
	walletSignInWait = 300 * time.Millisecond
	t.Cleanup(func() { walletSignInWait = old })
	const nameA, passA, nameB, passB = "alice", "the departing profile", "bob", "the arriving profile"
	for _, p := range [][2]string{{nameA, passA}, {nameB, passB}} {
		if createVault("s3", p[0], p[1]) == "" {
			t.Fatalf("createVault(%s) returned no recovery code", p[0])
		}
	}
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), []byte("alice's data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", nameA, passA, src)
	dkA, dkB := resolveDK("s3", nameA, passA, nil), resolveDK("s3", nameB, passB, nil)
	if dkA == nil || dkB == nil {
		t.Fatal("cannot resolve the profile keys")
	}
	// B's wallet is in the store, as a sign-in finds it.
	bToks := fundWallet(t, wpath, 2)
	if _, err := sealWalletDurable("s3", nameB, passB, dkB, wpath); err != nil {
		t.Fatalf("seeding B's stored wallet: %v", err)
	}
	// A's session wallet: dev-faucet credit, so payRent buys (and spends) at its lease.
	aToks := fundWallet(t, wpath, 5)
	gen := walletGeneration(wpath)

	leaseIn, signedIn := make(chan struct{}), make(chan struct{})
	enterLease, signInDone := closer(leaseIn), closer(signedIn)
	meterA := profileRefV2(nameA, passA)
	var mu sync.Mutex
	var aSpent []string
	capStoreLeaseSeen = func(req leaseReq) {
		if req.Profile != meterA || len(req.Tokens) == 0 {
			return
		}
		mu.Lock()
		aSpent = append(aSpent, spentBy(req)...)
		mu.Unlock()
		enterLease()
		select { // A's lease is held until B's sign-in has replaced the wallet
		case <-signedIn:
		case <-time.After(10 * time.Second):
		}
	}
	var signIn time.Duration
	var restoreErr, rentErr error
	var paid bool
	panics := runAll(
		func() {
			defer enterLease()
			_, paid, rentErr = payRentGen(newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault), "s3", nameA, passA, wpath, nil, gen)
		},
		func() {
			defer signInDone()
			<-leaseIn
			start := time.Now()
			removeWallet(wpath) // what handleRoamIn does, in this order
			restoreErr = pullWalletStrict("s3", nameB, passB, dkB, wpath)
			signIn = time.Since(start)
		},
	)
	if len(panics) != 0 || restoreErr != nil {
		t.Fatalf("panics: %v, restore: %v", panics, restoreErr)
	}
	if rentErr != nil || !paid {
		t.Fatalf("payRent: paid=%v err=%v", paid, rentErr)
	}
	if bound := 2*walletSignInWait + 2*time.Second; signIn > bound {
		t.Errorf("the sign-in's wallet steps took %s against a %s bound", signIn, bound)
	}
	b, _ := loadWallet(wpath)
	if len(b.Tokens) != len(bToks) || (len(b.Tokens) > 0 && b.Tokens[0].Nonce != bToks[0].Nonce) {
		t.Fatalf("the wallet file is not B's after B signed in: %d token(s), want B's %d", len(b.Tokens), len(bToks))
	}
	mu.Lock()
	defer mu.Unlock()
	if len(aSpent) == 0 {
		t.Fatal("control: A's payRent spent nothing, so this test proves nothing")
	}
	stored := readStoredWallet("s3", nameA, passA, dkA)
	if stored == nil {
		t.Fatal("A's spend was published nowhere: A's head holds no wallet")
	}
	held := map[string]bool{}
	for _, tk := range stored.Tokens {
		held[tk.Nonce] = true
	}
	for _, n := range aSpent {
		if held[n] {
			t.Errorf("A's head still holds %s, which A's lease spent -- the next login resurrects it", n)
		}
	}
	if got, want := stored.balance(), len(aToks)-len(aSpent); got != want {
		t.Errorf("A's head holds %d token(s), want %d (A's wallet less what A spent)", got, want)
	}
}

// A claim waits walletSignInWait for a busy wallet and then refuses BEFORE it mints: a person is waiting on
// CLAIM, and CREATE-CODE shows the one-time recovery code only after the drain. The code keeps everything, so the
// retry, once the wallet is free, drains all of it.
func TestAClaimRefusesBeforeMintingWhenTheWalletStaysBusy(t *testing.T) {
	old := walletSignInWait
	walletSignInWait = 300 * time.Millisecond
	t.Cleanup(func() { walletSignInWait = old })
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	issuer := blindGateway(t, priv, "CLAIM-REFUSED", 3)
	defer issuer.Close()
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	g := newGatewayClient(issuer.URL, gwDefault)
	holder := lockWallet(wpath)
	n, err := drainClaim(g, wpath, "CLAIM-REFUSED", false)
	holder()
	if !errors.Is(err, errWalletBusy) || n != 0 {
		t.Fatalf("drainClaim against a wallet busy past walletSignInWait: n=%d err=%v, want 0 and errWalletBusy", n, err)
	}
	if n, err := drainClaim(g, wpath, "CLAIM-REFUSED", false); err != nil || n != 3 {
		t.Fatalf("the retry drained n=%d err=%v, want all 3 -- the refusal must not have spent the code", n, err)
	}
}

// wipeSessionState sweeps the state dir for handleCreate and the legacy login and logoff. It
// removes the wallet only under the wallet lock and NEVER removes the lock file itself.
func TestWipeSessionStateRemovesTheWalletUnderItsLock(t *testing.T) {
	dest := t.TempDir()
	wp := walletPathFor(dest)
	for _, f := range []string{wp, wp + ".tmp", filepath.Join(dest, "other.state")} {
		if err := os.WriteFile(f, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(dest, telStateSubdir), 0o700); err != nil {
		t.Fatal(err)
	}
	waits := walletLockWaits(t)
	holder := lockWallet(wp) // a flush mid-window
	done := make(chan struct{})
	go func() { defer close(done); wipeSessionState(dest) }()
	select {
	case <-waits:
	case <-time.After(10 * time.Second):
		holder()
		<-done
		t.Fatal("wipeSessionState never waited for the held wallet lock -- it removed the wallet under a live flush")
	}
	if _, err := os.Stat(wp); err != nil {
		t.Errorf("the wallet was removed while another writer held its lock: %v", err)
	}
	holder()
	<-done
	for _, gone := range []string{wp, wp + ".tmp", filepath.Join(dest, "other.state")} {
		if _, err := os.Stat(gone); err == nil {
			t.Errorf("%s survived the wipe", filepath.Base(gone))
		}
	}
	for _, kept := range []string{wp + ".lock", filepath.Join(dest, telStateSubdir)} {
		if _, err := os.Stat(kept); err != nil {
			t.Errorf("%s did not survive the wipe: %v", filepath.Base(kept), err)
		}
	}
}

// Every function that WRITES the wallet file -- saveWallet / saveOurWallet, or os.Remove / os.Rename /
// os.WriteFile on a wallet path -- also takes the wallet lock, so a writer added later cannot be added unlocked.
// Three widenings beyond the direct writers:
//   - recordPlan and appendTokens write under their CALLER's lock, so every caller of theirs must take it;
//   - a function that enumerates the state dir (os.ReadDir of dest / stateDirDefault / NOWHERE_STATE) and removes
//     what it finds is a wallet writer too, whatever it names;
//   - CLI verbs are functions of their own (walletBuyCLI), so main's single lock vouches for nothing.
//
// A function that locks for one write and writes again unlocked elsewhere is beyond this check; the wallet's
// writers are few enough to read.
func TestEveryWalletWriterTakesTheWalletLock(t *testing.T) {
	_, files := agentSource(t)
	exempt := map[string]bool{"saveWallet": true, "saveOurWallet": true, "lockWallet": true, "lockWalletWithin": true,
		// It writes wallet.json.gen, not the wallet, and on purpose BEFORE the lock: a removal bumps it first so a
		// holder still in its slow phase refuses to save (THE GENERATION). Its one caller, removeWallet, is checked.
		"bumpWalletGeneration": true}
	underCallerLock := map[string]bool{"recordPlan": true, "appendTokens": true, "putWalletBytes": true,
		// NWP-20261125-12: recordPlanMode holds recordPlan's body (recordPlan is now its wrapper); since NWP-20261128-24
		// its callers are recordPlan and tests, and drainClaimMode saves through recordClaimBatch.
		"recordPlanMode": true,
		// NWP-20261128-24: one claim batch's plan and tokens in one save; its caller, drainClaimMode, holds the lock.
		"recordClaimBatch": true,
		// NWP-20261013-20 (pass 5): a staged landing's proof and undo, run by writeRestoredWallet and the locked retry.
		"proveWalletLanding": true, "undoWalletLanding": true,
		// NWP-20261031-01: the seen-set beside the wallet, written by saveWallet and writeRestoredWallet under their lock.
		"noteWalletSeen": true, "poisonSeen": true, "poisonSeenOrFail": true}
	writers := map[string]bool{}
	sweepers := map[string]bool{}
	var unlocked []string
	for _, af := range files {
		for _, d := range af.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Body == nil || exempt[fd.Name.Name] {
				continue
			}
			writes, locks, readsState, removesEntry := false, false, false, false
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				switch fn := call.Fun.(type) {
				case *ast.Ident:
					switch {
					case fn.Name == "saveWallet" || fn.Name == "saveOurWallet" || underCallerLock[fn.Name]:
						writes = true
					case fn.Name == "lockWallet" || fn.Name == "lockWalletWithin" || fn.Name == "removeWallet":
						locks = true
					}
				case *ast.SelectorExpr:
					if x, ok := fn.X.(*ast.Ident); ok && x.Name == "os" {
						switch fn.Sel.Name {
						case "Remove", "RemoveAll", "Rename", "WriteFile":
							for _, a := range call.Args {
								if namesWalletPath(a) {
									writes = true
								}
								if namesDirEntry(a) {
									removesEntry = true
								}
							}
						case "ReadDir":
							if len(call.Args) == 1 && namesStateDir(call.Args[0]) {
								readsState = true
							}
						}
					}
				}
				return true
			})
			name := fd.Name.Name
			if readsState && removesEntry {
				sweepers[name] = true
				writes = true
			}
			if underCallerLock[name] {
				continue // checked at its callers, which the walk above counts as writers
			}
			if writes {
				writers[name] = true
				if !locks {
					unlocked = append(unlocked, name)
				}
			}
		}
	}
	// The control: the guard must find the writers that exist today, or it is not looking at anything.
	for _, w := range []string{"capFlush", "leaseRefsGen", "payRentGenRule", "claimTokens", "drainClaimMode", "writeRestoredWallet", "finishStagedClaim",
		"removeWallet", "walletBuyCLI", "wipeSessionStateWallet"} {
		if !writers[w] {
			t.Errorf("the guard did not see %s write the wallet -- it has stopped recognising wallet writes", w)
		}
	}
	if !sweepers["wipeSessionStateWallet"] {
		t.Error("the guard did not see wipeSessionState sweep the state dir -- the sweep rule has stopped matching")
	}
	sort.Strings(unlocked)
	if len(unlocked) > 0 {
		t.Errorf("these functions write the wallet file without lockWallet (NWP-20261010-04): %s", strings.Join(unlocked, ", "))
	}
}

// namesWalletPath reports whether e is built from the wallet's path: walletPathFor / capWalletPath, or the
// identifiers the package uses for it.
func namesWalletPath(e ast.Expr) bool {
	found := false
	ast.Inspect(e, func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.CallExpr:
			if id, ok := x.Fun.(*ast.Ident); ok && (id.Name == "walletPathFor" || id.Name == "capWalletPath") {
				found = true
			}
		case *ast.Ident:
			if x.Name == "walletPath" || x.Name == "wpath" {
				found = true
			}
		}
		return true
	})
	return found
}

// namesDirEntry reports whether e is built from a directory entry's name (`e.Name()` and the like).
func namesDirEntry(e ast.Expr) bool {
	found := false
	ast.Inspect(e, func(n ast.Node) bool {
		if c, ok := n.(*ast.CallExpr); ok && len(c.Args) == 0 {
			if s, ok := c.Fun.(*ast.SelectorExpr); ok && s.Sel.Name == "Name" {
				found = true
			}
		}
		return true
	})
	return found
}

// namesStateDir reports whether e is the session-state dir itself: `dest` (every daemon handler's name for it),
// stateDirDefault, or anything read from NOWHERE_STATE.
func namesStateDir(e ast.Expr) bool {
	found := false
	ast.Inspect(e, func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.Ident:
			if x.Name == "dest" || x.Name == "stateDirDefault" {
				found = true
			}
		case *ast.BasicLit:
			if strings.Contains(x.Value, "NOWHERE_STATE") {
				found = true
			}
		}
		return true
	})
	return found
}

// createCodeLiveGrant makes createCodeEnv's /entitlement answer a live grant.
var createCodeLiveGrant atomic.Bool

// createCodeEnv is walletRaceEnv for the gate: the state dir IS the wallet's dir (as on the device, where
// capWalletPath and walletPathFor(dest) are one file), and the gateway also redeems claim codes for claim, through
// the fake blind issuer.
func createCodeEnv(t *testing.T, claim string, count int) (dest, wpath string) {
	t.Helper()
	srv, objs, mu := mockCapStore(t)
	walletStoreObjs = func(key string) bool {
		mu.Lock()
		defer mu.Unlock()
		_, ok := objs[key]
		return ok
	}
	t.Cleanup(func() { walletStoreObjs = nil; createCodeLiveGrant.Store(false) })
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	issuer := blindGateway(t, priv, claim, count)
	t.Cleanup(issuer.Close)
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/entitlement" && createCodeLiveGrant.Load() {
			json.NewEncoder(w).Encode(entitlementInfo{FreeBytes: 1 << 30, EntitledBytes: 10 << 30, CurrentEpoch: 42})
			return
		}
		if strings.HasPrefix(r.URL.Path, "/issue") {
			issuer.Config.Handler.ServeHTTP(w, r)
			return
		}
		srv.Config.Handler.ServeHTTP(w, r)
	}))
	t.Cleanup(proxy.Close)
	t.Setenv("GATEWAY_URL", proxy.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	dest = t.TempDir()
	t.Setenv("NOWHERE_STATE", dest)
	t.Setenv("NOWHERE_ENROLL_STATE", filepath.Join(t.TempDir(), "enroll"))
	wpath = walletPathFor(dest)
	t.Setenv("NOWHERE_WALLET", wpath)
	capReadCache = map[string]capEntry{}
	blobCache = nil
	freeRenewedThrough = map[string]int64{}
	noWalletRenewed = map[string]*Wallet{}
	return dest, wpath
}

// A plain CREATE folds nothing the last session left: with no staged claim, its flush runs walletNotOurs.
func TestCreateFoldsNoLeftoverWallet(t *testing.T) {
	const nameC, passC = "carol", "the arriving profile's passphrase"
	dest, wpath := createCodeEnv(t, "UNUSED", 1)
	fundWallet(t, wpath, 4) // a departed session's leftovers
	if reply := verb(func(c net.Conn) { handleCreate(c, dest, nameC, passC) }); !strings.HasPrefix(reply, "OK ") {
		t.Fatalf("CREATE replied %q", reply)
	}
	dkC := resolveDK("s3", nameC, passC, nil)
	if dkC == nil {
		t.Fatal("cannot resolve carol's key")
	}
	if c := readStoredWallet("s3", nameC, passC, dkC); c != nil && c.balance() > 0 {
		t.Errorf("carol's new head holds %d token(s) a departed session left in the file (NWP-20260915-20)", c.balance())
	}
}

// A capFlush whose wallet changes hands during its lease -- a sign-in that waited out walletSignInWait and replaced
// the file without the lock -- must not save its own wallet over the arriving profile's (saveOurWallet's check).
func TestAFlushDoesNotSaveAWalletThatChangedHands(t *testing.T) {
	wpath := walletRaceEnv(t)
	fundWallet(t, wpath, 2)
	arriving, _ := json.Marshal(&Wallet{Tokens: []Token{{Denom: "1GBmo", Nonce: "arriving-1", Exp: 1 << 62, Sig: "s"}}})
	var once sync.Once
	capStoreLeaseSeen = func(leaseReq) {
		once.Do(func() {
			// What removeWallet does first, then the restore, without the lock.
			bumpWalletGeneration(wpath)
			if err := os.WriteFile(wpath, arriving, 0o600); err != nil {
				t.Error(err)
			}
		})
	}
	if panics := runAll(func() { sessionFlush("alice", "a flush that outlives its session", "data") }); len(panics) != 0 {
		t.Fatalf("panics: %v", panics)
	}
	if got, _ := os.ReadFile(wpath); string(got) != string(arriving) {
		t.Errorf("the flush saved its wallet over the arriving profile's:\n got %s\nwant %s", got, arriving)
	}
}

// payRent's record section re-checks the generation: a sign-in can land between leaseRefsGen's save and the
// record, with no network call to hold it (payRentLeaseDone stands in for that instant). The record must not be
// saved into the arriving profile's file, and must not publish that file at the departed profile's head; the
// departed profile's head must carry its own spend.
func TestPayRentRecordsNothingIntoAWalletThatChangedHands(t *testing.T) {
	wpath := walletRaceEnv(t)
	const nameA, passA = "alice", "the departing profile's passphrase"
	if createVault("s3", nameA, passA) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), []byte("alice's data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", nameA, passA, src)
	aToks := fundWallet(t, wpath, 4)
	gen := walletGeneration(wpath)
	arriving, _ := json.Marshal(&Wallet{Tokens: []Token{{Denom: "1GBmo", Nonce: "arriving-1", Exp: 1 << 62, Sig: "s"}}})
	payRentLeaseDone = func() {
		removeWallet(wpath)
		if err := os.WriteFile(wpath, arriving, 0o600); err != nil {
			t.Error(err)
		}
	}
	t.Cleanup(func() { payRentLeaseDone = nil })
	var spent []string
	capStoreLeaseSeen = func(req leaseReq) {
		if req.Profile == profileRefV2(nameA, passA) && len(req.Tokens) > 0 {
			spent = append(spent, spentBy(req)...)
		}
	}
	if _, paid, err := payRentGen(newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault), "s3", nameA, passA, wpath, nil, gen); err != nil || !paid {
		t.Fatalf("payRent: paid=%v err=%v", paid, err)
	}
	if len(spent) != 1 {
		t.Fatalf("control: want alice's lease to spend one token, got %v", spent)
	}
	if got, _ := os.ReadFile(wpath); string(got) != string(arriving) {
		t.Errorf("payRent saved its record into the arriving profile's wallet:\n got %s\nwant %s", got, arriving)
	}
	dkA := resolveDK("s3", nameA, passA, nil)
	stored := readStoredWallet("s3", nameA, passA, dkA)
	if stored == nil {
		t.Fatal("alice's spend was published nowhere")
	}
	for _, tk := range stored.Tokens {
		if tk.Nonce == "arriving-1" {
			t.Error("alice's head holds the arriving profile's token -- payRent published the file it found")
		}
		if tk.Nonce == spent[0] {
			t.Errorf("alice's head still holds %s, which her lease spent", tk.Nonce)
		}
	}
	if got, want := stored.balance(), len(aToks)-1; got != want {
		t.Errorf("alice's head holds %d token(s), want %d", got, want)
	}
}

// syncLoop and handleBackup read the wallet generation BEFORE the session (maybePayRent says why: a sign-in writes
// the marker, then bumps). A SOURCE PIN, deliberately: observing the order behaviourally needs a seal worker and a
// sign-in timed between two adjacent reads, so the order itself is what is held here.
func TestRentCallersReadTheGenerationBeforeTheSession(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, fn := range []string{"syncLoop", "handleBackup"} {
		body := stripComments(funcBody(t, string(b), fn))
		at := -1
		for i, l := range body {
			if strings.TrimSpace(l) == "name, pass, uid := readRoamSession(dest)" {
				at = i
				break
			}
		}
		if at < 1 {
			t.Errorf("%s: the session read was not found -- this test is stale", fn)
			continue
		}
		if prev := strings.TrimSpace(body[at-1]); !strings.HasPrefix(prev, "wgen := walletGeneration(walletPathFor(dest))") {
			t.Errorf("%s reads the session without reading the wallet generation on the line before it (found %q): a "+
				"sign-in between the two could pair the departed name with the arriving generation", fn, prev)
		}
		if !strings.Contains(strings.Join(body, "\n"), "maybePayRent(dest, name, pass, wgen)") {
			t.Errorf("%s does not hand that generation to maybePayRent", fn)
		}
	}
}

// Only removeWallet may bump the generation. A bump anywhere else -- inside a live session -- would turn every
// in-flight writer of that session into a false "the wallet changed hands": nothing saved, and payRent publishing a
// stale value as the departed profile's last word.
func TestOnlyRemoveWalletBumpsTheGeneration(t *testing.T) {
	_, files := agentSource(t)
	var callers []string
	for _, af := range files {
		for _, d := range af.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Body == nil {
				continue
			}
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				if c, ok := n.(*ast.CallExpr); ok {
					if id, ok := c.Fun.(*ast.Ident); ok && id.Name == "bumpWalletGeneration" {
						callers = append(callers, fd.Name.Name)
					}
				}
				return true
			})
		}
	}
	// NWP-20261013-20: removeWallet bumps twice -- before the lock and again after it. NWP-20261017-02: and
	// dropWalletIfUnchanged once, under the lock, before it removes a published wallet. Nothing else bumps.
	if len(callers) != 3 || callers[0] != "removeWallet" || callers[1] != "removeWallet" || callers[2] != "dropWalletIfUnchanged" {
		t.Errorf("bumpWalletGeneration is called from %v, want exactly [removeWallet removeWallet dropWalletIfUnchanged]", callers)
	}
}

// CLAIM refused as busy says so: "ERR" is rendered by the chooser as a connection problem.
func TestABusyClaimSaysBusy(t *testing.T) {
	old := walletSignInWait
	walletSignInWait = 300 * time.Millisecond
	t.Cleanup(func() { walletSignInWait = old })
	dest, wpath := createCodeEnv(t, "CODE-BUSY", 2)
	if err := markRoamSession(dest, "alice", "a session that adds credit", "12", ""); err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	holder := lockWallet(wpath)
	defer holder()
	if got := verb(func(c net.Conn) { handleClaim(c, dest, "CODE-BUSY", false) }); got != "ERR-BUSY" {
		t.Errorf("CLAIM against a wallet busy past walletSignInWait replied %q, want ERR-BUSY", got)
	}
}

// standUpProfile creates (name, pass) with a little sealed data, so payRent has a footprint to renew.
func standUpProfile(t *testing.T, name, pass string) {
	t.Helper()
	if createVault("s3", name, pass) == "" {
		t.Fatalf("createVault(%s) returned no recovery code", name)
	}
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), []byte(name+"'s data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", name, pass, src)
}

// refuseLeasesOf answers every lease made as (name, pass) with status, and leaves the rest to the fake gateway:
// a create whose flush is refused, after its claim is drained.
func refuseLeasesOf(name, pass string, status int) {
	meter := profileRefV2(name, pass)
	capStoreLeaseStatus = func(r leaseReq) (int, string) {
		if r.Profile == meter {
			return status, ""
		}
		return 0, ""
	}
}

// storedWallet is (name, pass)'s published wallet, or nil.
func storedWallet(t *testing.T, name, pass string) *Wallet {
	t.Helper()
	dk := resolveDK("s3", name, pass, nil)
	if dk == nil {
		return nil
	}
	return readStoredWallet("s3", name, pass, dk)
}

const stName, stPass = "carol", "the arriving profile's passphrase"

// REVIEW PROBE A: a CREATE-CODE that creates nothing -- a mistyped code -- must leave wallet.json exactly as it
// was. At the gate that file can be a COLD-LOCKED session's, which resumes into it.
func TestAFailedCreateCodeTouchesNoWallet(t *testing.T) {
	dest, wpath := createCodeEnv(t, "REALCODEREALCODEREALCODE", 3)
	fundWallet(t, wpath, 4)
	before, _ := os.ReadFile(wpath)
	gen := walletGeneration(wpath)
	if got := verb(func(c net.Conn) { handleCreateCode(c, dest, stName, stPass, "MISTYPEDMISTYPEDMISTYPED") }); got != "ERR-NOCODE" {
		t.Fatalf("CREATE-CODE with a mistyped code replied %q, want ERR-NOCODE", got)
	}
	if after, err := os.ReadFile(wpath); err != nil || string(after) != string(before) {
		t.Errorf("a CREATE-CODE that created nothing changed wallet.json (err %v)", err)
	}
	if walletGeneration(wpath) != gen {
		t.Error("a CREATE-CODE that created nothing bumped the wallet generation -- every in-flight writer of the session now refuses to save")
	}
	if _, err := os.Stat(createStagingPath(stName, stPass)); err == nil {
		t.Error("a code that redeemed nothing left a staged claim")
	}
}

// Every refusal a create can give comes BEFORE the code is redeemed: a CREATE-CODE refused by the enrollment
// throttle redeems nothing, and the retry, once the throttle has passed, creates with the whole claim.
func TestACreateCodeRefusedByTheThrottleRedeemsNothing(t *testing.T) {
	dest, _ := createCodeEnv(t, "PAIDCODEPAIDCODEPAIDCODE", 3)
	t.Setenv("NOWHERE_ENROLL_MAX", "1")
	if ok, _ := enrollAllow(); !ok {
		t.Fatal("control: the bucket should start full")
	}
	if got := verb(func(c net.Conn) { handleCreateCode(c, dest, stName, stPass, "PAIDCODEPAIDCODEPAIDCODE") }); !strings.HasPrefix(got, "RATELIMIT") {
		t.Fatalf("CREATE-CODE against an empty enrollment bucket replied %q, want RATELIMIT", got)
	}
	if w, err := loadWallet(createStagingPath(stName, stPass)); err == nil && w.balance() > 0 {
		t.Errorf("a CREATE-CODE refused by the throttle redeemed the code: %d token(s) staged", w.balance())
	}
	t.Setenv("NOWHERE_ENROLL_MAX", "0") // the throttle has passed
	if got := verb(func(c net.Conn) { handleCreateCode(c, dest, stName, stPass, "PAIDCODEPAIDCODEPAIDCODE") }); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("the retry replied %q", got)
	}
	if c := storedWallet(t, stName, stPass); c == nil || len(c.BlindTokens) != 3 {
		t.Errorf("after the retry carol's head holds %v claimed token(s), want 3", c)
	}
}

// REVIEW PROBE B, for a refusal that comes AFTER the drain: the create's flush is refused, so nothing is created.
// The claim stays staged for this credential, and a retry -- CREATE-CODE with the same, now spent, code, or a
// plain CREATE -- creates with it. wallet.json is never touched, and a successful create removes the staging.
func TestACreateFailedAfterTheDrainKeepsTheClaimForTheRetry(t *testing.T) {
	for _, retry := range []string{"CREATE-CODE", "CREATE"} {
		t.Run(retry, func(t *testing.T) {
			dest, wpath := createCodeEnv(t, "PAIDCODEPAIDCODEPAIDCODE", 3)
			fundWallet(t, wpath, 2) // somebody else's
			before, _ := os.ReadFile(wpath)
			refuseLeasesOf(stName, stPass, http.StatusInternalServerError)
			r1 := verb(func(c net.Conn) { handleCreateCode(c, dest, stName, stPass, "PAIDCODEPAIDCODEPAIDCODE") })
			if strings.HasPrefix(r1, "OK") {
				t.Fatalf("control: the refused create replied %q", r1)
			}
			staged := createStagingPath(stName, stPass)
			if w, err := loadWallet(staged); err != nil || len(w.BlindTokens) != 3 {
				t.Fatalf("after the failed create (%q) the claim is not staged", r1)
			}
			if after, _ := os.ReadFile(wpath); string(after) != string(before) {
				t.Error("the failed create changed wallet.json, which is somebody else's")
			}
			capStoreLeaseStatus = nil
			var r2 string
			if retry == "CREATE-CODE" {
				r2 = verb(func(c net.Conn) { handleCreateCode(c, dest, stName, stPass, "PAIDCODEPAIDCODEPAIDCODE") })
			} else {
				r2 = verb(func(c net.Conn) { handleCreate(c, dest, stName, stPass) })
			}
			if !strings.HasPrefix(r2, "OK ") {
				t.Fatalf("the %s retry replied %q", retry, r2)
			}
			if c := storedWallet(t, stName, stPass); c == nil || len(c.BlindTokens) != 3 {
				t.Errorf("after the %s retry carol's head holds %v, want her 3 claimed tokens", retry, c)
			}
			if _, err := os.Stat(staged); err == nil {
				t.Error("the staged claim outlived the create that published it")
			}
		})
	}
}

// The staged claim belongs to the credential it was drained for. While it waits for the retry, another profile's
// payRent and flush pay from wallet.json and never see it; the retry folds only the claim.
func TestAStagedClaimIsInvisibleToOtherProfiles(t *testing.T) {
	const nameA, passA = "alice", "the departed profile's passphrase"
	dest, wpath := createCodeEnv(t, "PAIDCODEPAIDCODEPAIDCODE", 3)
	provenWallet(t, wpath) // NWP-20261013-20: alice's session restored its wallet; her payRent's copy is judged by that
	standUpProfile(t, nameA, passA)
	leftovers := fundWallet(t, wpath, 5)
	refuseLeasesOf(stName, stPass, http.StatusInternalServerError)
	if r := verb(func(c net.Conn) { handleCreateCode(c, dest, stName, stPass, "PAIDCODEPAIDCODEPAIDCODE") }); strings.HasPrefix(r, "OK") {
		t.Fatalf("control: the refused create replied %q", r)
	}
	capStoreLeaseStatus = nil
	meterA := profileRefV2(nameA, passA)
	var underA int
	capStoreLeaseSeen = func(req leaseReq) {
		if req.Profile == meterA {
			underA += len(req.BlindTokens)
		}
	}
	if _, _, err := payRentGen(newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault), "s3", nameA, passA, wpath, nil, walletGeneration(wpath)); err != nil {
		t.Fatalf("alice's payRent: %v", err)
	}
	if panics := runAll(func() { sessionFlush(nameA, passA, "alice's seal") }); len(panics) != 0 {
		t.Fatalf("alice's flush: %v", panics)
	}
	if underA != 0 {
		t.Errorf("%d staged claim token(s) were presented under alice's profile", underA)
	}
	if a := storedWallet(t, nameA, passA); a != nil && len(a.BlindTokens) > 0 {
		t.Errorf("alice's head holds %d staged claim token(s)", len(a.BlindTokens))
	}
	if r := verb(func(c net.Conn) { handleCreate(c, dest, stName, stPass) }); !strings.HasPrefix(r, "OK ") {
		t.Fatalf("the retry replied %q", r)
	}
	c := storedWallet(t, stName, stPass)
	if c == nil || len(c.BlindTokens) != 3 {
		t.Fatalf("carol's head holds %v, want her 3 claimed tokens", c)
	}
	mine := map[string]bool{}
	for _, tk := range leftovers {
		mine[tk.Nonce] = true
	}
	for _, tk := range c.Tokens {
		if mine[tk.Nonce] {
			t.Errorf("carol's head holds alice's leftover token %s (NWP-20260915-20)", tk.Nonce)
		}
	}
}

// A live roamed session (a parked cold-locked one is refused by ERR-COLDLOCK) survives every create tried at the
// gate meanwhile: while its .roamsession stands each one answers ERR-LIVE (Q087, NWP-20261101-04) -- a mistyped
// CREATE-CODE (refused before its code is looked up), a CREATE, a CREATE under another name -- and its wallet file
// is unchanged; after it resumes, its payRent finds that wallet and its durable head keeps every token.
func TestAColdLockedSessionSurvivesCreatesAtTheGate(t *testing.T) {
	const nameA, passA = "alice", "the cold-locked profile's passphrase"
	dest, wpath := createCodeEnv(t, "REALCODEREALCODEREALCODE", 3)
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	standUpProfile(t, nameA, passA)
	fundWallet(t, wpath, 4)
	dkA := resolveDK("s3", nameA, passA, nil)
	if _, err := sealWalletDurable("s3", nameA, passA, dkA, wpath); err != nil {
		t.Fatal(err)
	}
	if err := markRoamSession(dest, nameA, passA, "12", ""); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(wpath)
	gen := walletGeneration(wpath)
	unchanged := func(after string) {
		t.Helper()
		if got, err := os.ReadFile(wpath); err != nil || string(got) != string(before) {
			t.Fatalf("after %s the session's wallet file changed (err %v)", after, err)
		}
		if walletGeneration(wpath) != gen {
			t.Fatalf("after %s the wallet generation moved", after)
		}
	}
	if r := verb(func(c net.Conn) { handleCreateCode(c, dest, stName, stPass, "MISTYPEDMISTYPEDMISTYPED") }); r != "ERR-LIVE" {
		t.Fatalf("mistyped CREATE-CODE over a live session replied %q, want ERR-LIVE", r)
	}
	unchanged("a mistyped CREATE-CODE")
	if r := verb(func(c net.Conn) { handleCreate(c, dest, stName, stPass) }); r != "ERR-LIVE" {
		t.Fatalf("CREATE over a live session replied %q, want ERR-LIVE", r)
	}
	unchanged("a refused CREATE")
	if r := verb(func(c net.Conn) { handleCreate(c, dest, "dave", "another arriving passphrase") }); r != "ERR-LIVE" {
		t.Fatalf("CREATE under another name over a live session replied %q, want ERR-LIVE", r)
	}
	unchanged("a refused CREATE under another name")
	// The session resumes and renews under a live grant: the gateway takes nothing for this lease.
	meterA := profileRefV2(nameA, passA)
	capStoreLeaseStatus = func(r leaseReq) (int, string) {
		if r.Profile == meterA && !r.Free {
			return http.StatusOK, ""
		}
		return 0, ""
	}
	if _, _, err := payRentGen(newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault), "s3", nameA, passA, wpath, nil, gen); err != nil {
		t.Fatalf("the resumed session's payRent: %v", err)
	}
	if w, _ := loadWallet(wpath); w.balance() != 4 {
		t.Errorf("the resumed session's wallet holds %d token(s), want 4", w.balance())
	}
	if a := storedWallet(t, nameA, passA); a == nil || a.balance() != 4 {
		t.Errorf("the resumed session's durable head holds %v, want its 4 tokens", a)
	}
}

// REVIEW PROBE C: a renewal with NO wallet file -- lost however it was -- must not publish the {} loadWallet stands
// in for it over the durable wallet: walletForPublish merges the plan facts, never the tokens.
func TestARenewalWithNoWalletFilePublishesNothing(t *testing.T) {
	const name, pass = "alice", "alice's long passphrase here"
	_, wpath := createCodeEnv(t, "UNUSED", 1)
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	standUpProfile(t, name, pass)
	fundWallet(t, wpath, 4)
	dk := resolveDK("s3", name, pass, nil)
	if _, err := sealWalletDurable("s3", name, pass, dk, wpath); err != nil {
		t.Fatal(err)
	}
	if sw := storedWallet(t, name, pass); sw == nil || sw.balance() != 4 {
		t.Fatal("control: the durable wallet should hold 4 tokens")
	}
	removeWallet(wpath)
	// A live grant: the free probe is over quota, and a token-less entitled lease is covered.
	capStoreLeaseStatus = func(r leaseReq) (int, string) {
		if r.Free {
			return http.StatusPaymentRequired, ""
		}
		return http.StatusOK, ""
	}
	createCodeLiveGrant.Store(true) // /entitlement answers a live grant, so payRent takes the paid arm
	var leased bool
	capStoreLeaseSeen = func(r leaseReq) {
		if !r.Free {
			leased = true
		}
	}
	if _, paid, err := payRentGen(newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault), "s3", name, pass, wpath, nil, walletGeneration(wpath)); err != nil {
		t.Logf("payRent: paid=%v err=%v", paid, err)
	}
	if !leased {
		t.Fatal("control: payRent made no entitled lease -- this test is not on the path it is about")
	}
	if sw := storedWallet(t, name, pass); sw == nil || sw.balance() != 4 {
		n := -1
		if sw != nil {
			n = sw.balance()
		}
		t.Errorf("the renewal published a wallet holding %d token(s) over the durable 4", n)
	}
	if _, err := os.Stat(wpath); err == nil {
		t.Error("the renewal created a wallet file out of nothing")
	}
}

// A live session with NO wallet file renews once, not on every payRent call: the renewal records nothing in a
// file, so noWalletRenewed stands in for one. A later epoch renews again -- the stand-in must never make the
// footprint renew later than a recorded wallet would.
func TestANoWalletFileRenewalHappensOncePerDueEpoch(t *testing.T) {
	const name, pass = "alice", "alice's long passphrase here"
	_, wpath := createCodeEnv(t, "UNUSED", 1)
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	standUpProfile(t, name, pass)
	createCodeLiveGrant.Store(true) // a live grant: payRent takes the paid arm with nothing to buy
	capStoreLeaseStatus = func(r leaseReq) (int, string) {
		if r.Free {
			return http.StatusPaymentRequired, ""
		}
		return http.StatusOK, ""
	}
	var entitled atomic.Int32
	capStoreLeaseSeen = func(r leaseReq) {
		if !r.Free {
			entitled.Add(1)
		}
	}
	if _, err := os.Stat(wpath); err == nil {
		t.Fatal("control: this session must have no wallet file")
	}
	gw := newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault)
	for i := 0; i < 2; i++ {
		if _, _, err := payRentGen(gw, "s3", name, pass, wpath, nil, walletGeneration(wpath)); err != nil {
			t.Fatalf("payRent #%d: %v", i+1, err)
		}
	}
	if n := entitled.Load(); n != 1 {
		t.Fatalf("two payRent calls in one epoch with no wallet file made %d whole-footprint lease(s), want 1", n)
	}
	capStoreQuote = func(_ http.Header, q *quoteInfo) { q.CurrentEpoch = 43 } // the next epoch
	if _, _, err := payRentGen(gw, "s3", name, pass, wpath, nil, walletGeneration(wpath)); err != nil {
		t.Fatalf("payRent in the next epoch: %v", err)
	}
	if n := entitled.Load(); n != 2 {
		t.Errorf("the next epoch made %d lease(s) in all, want 2 -- the stand-in must not hold the renewal back", n)
	}
}

// A successful create publishes its staged claim's POST-SETTLE wallet to the new head by value. The fold went up
// before the lease settled: here the create's purchase presents every staged token and the gateway charges one,
// so the fold holds none and the settled file holds the rest. Removing the staged file without that publish would
// leave the head at the fold -- the tokens handed back would then exist nowhere durable.
func TestACreatePublishesTheSettledStagedClaim(t *testing.T) {
	dest, _ := createCodeEnv(t, "UNUSED", 1)
	toks, err := newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault).buyFaucet(3)
	if err != nil {
		t.Fatal(err)
	}
	// What an earlier CREATE-CODE attempt staged for this credential (dev-faucet credit: the gateway counts it).
	if err := saveWallet(createStagingPath(stName, stPass), &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	capStoreLeaseStatus = func(r leaseReq) (int, string) {
		if r.Free {
			return http.StatusPaymentRequired, "" // over the free allowance: the create's flush buys
		}
		if len(r.Tokens) == 0 {
			return http.StatusOK, "" // after the purchase a grant covers a token-less lease (the by-value publish)
		}
		return 0, "" // the purchase itself: the fake gateway charges one token per started GiB
	}
	var presented, spent []string
	capStoreLeaseSeen = func(r leaseReq) {
		for _, tk := range r.Tokens {
			presented = append(presented, tk.Nonce)
		}
		if len(r.Tokens) > 0 {
			spent = append(spent, spentBy(r)...)
		}
	}
	if r := verb(func(c net.Conn) { handleCreate(c, dest, stName, stPass) }); !strings.HasPrefix(r, "OK ") {
		t.Fatalf("CREATE replied %q", r)
	}
	if len(presented) != len(toks) || len(spent) != 1 {
		t.Fatalf("control: want the create to present all %d staged tokens and be charged one, got %d presented, %v spent",
			len(toks), len(presented), spent)
	}
	c := storedWallet(t, stName, stPass)
	if c == nil {
		t.Fatal("the new profile's head holds no wallet")
	}
	if got, want := c.balance(), len(toks)-1; got != want {
		t.Errorf("the new head holds %d token(s), want %d -- the settled claim, not the pre-settle fold", got, want)
	}
	for _, tk := range c.Tokens {
		if tk.Nonce == spent[0] {
			t.Errorf("the new head holds %s, which the create's lease spent", tk.Nonce)
		}
	}
}
