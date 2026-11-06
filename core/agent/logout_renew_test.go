package main

import (
	"bytes"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261112-14 (Q088's device half): a landed sign-out renews the whole footprint before its wallet publish,
// unless the footprint was already renewed in this epoch. Every store probe runs on renewBatchSetup's fixture, whose
// gateway quotes epoch 42; each test has its own profile name.

// signOutWallet rewrites the fixture's wallet with a term and a renewal epoch, keeping its tokens, and re-proves it.
func signOutWallet(t *testing.T, f *renewBatchFixture, paidThrough, renewed int64) {
	t.Helper()
	w, err := loadWallet(f.wpath)
	if err != nil {
		t.Fatal(err)
	}
	w.PaidThrough, w.RenewedEpoch = paidThrough, renewed
	if err := saveWallet(f.wpath, w); err != nil {
		t.Fatal(err)
	}
	provenWallet(t, f.wpath)
}

// noWalletRenewedReset empties the no-file stand-ins for the test and restores them after.
func noWalletRenewedReset(t *testing.T) {
	t.Helper()
	noWalletRenewedMu.Lock()
	old := noWalletRenewed
	noWalletRenewed = map[string]*Wallet{}
	noWalletRenewedMu.Unlock()
	t.Cleanup(func() {
		noWalletRenewedMu.Lock()
		noWalletRenewed = old
		noWalletRenewedMu.Unlock()
	})
}

func fileBytes(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// S1: a footprint renewed three epochs ago, inside a live term, is not due on the periodic rule -- and that is the
// customer who keeps working for weeks. The sign-out leases the whole of it and stamps this epoch.
func TestSignOutRenewal_RenewsAFootprintRenewedEarlierThisTerm(t *testing.T) {
	f := renewBatchSetup(t, "sorenew1", 2)
	signOutWallet(t, f, 92, 39)
	w, _ := loadWallet(f.wpath)
	if renewalDue(w, 42) {
		t.Fatal("control: the fixture wallet is due on the periodic rule; this test would prove nothing")
	}
	want := renewBatchFootprint(t, f)
	if _, paid, err := payRentGenSignOut(f.gw, f.base, f.name, f.p2, f.wpath, nil, walletGeneration(f.wpath)); err != nil || !paid {
		t.Fatalf("payRentGenSignOut: paid=%v err=%v, want the whole footprint renewed", paid, err)
	}
	reqs := f.sent()
	if len(reqs) == 0 {
		t.Fatal("no /lease request: the sign-out did not renew a footprint renewed three epochs ago")
	}
	if got := renewBatchUnion(t, reqs); !reflect.DeepEqual(got, want) {
		t.Fatalf("the sign-out leased %d refs, want the whole footprint (%d refs)", len(got), len(want))
	}
	if w, _ := loadWallet(f.wpath); w.RenewedEpoch != 42 {
		t.Fatalf("RenewedEpoch %d after the sign-out renewal, want 42", w.RenewedEpoch)
	}
}

// S2: renewed in this epoch already -> nothing to gain (Q088 stamps days), so no /lease at all; with no wallet file
// the stand-in's renewal epoch decides the same way, both ways.
func TestSignOutRenewal_SkipsAFootprintRenewedThisEpoch(t *testing.T) {
	f := renewBatchSetup(t, "sorenew2", 2)
	noWalletRenewedReset(t)
	signOutWallet(t, f, 92, 42)
	before := fileBytes(t, f.wpath)
	if _, paid, err := payRentGenSignOut(f.gw, f.base, f.name, f.p2, f.wpath, nil, walletGeneration(f.wpath)); err != nil || paid {
		t.Fatalf("payRentGenSignOut: paid=%v err=%v, want a skip", paid, err)
	}
	if n := len(f.sent()); n != 0 {
		t.Fatalf("%d /lease requests for a footprint renewed this epoch, want 0", n)
	}
	if !bytes.Equal(fileBytes(t, f.wpath), before) {
		t.Fatal("the skipped sign-out renewal rewrote the wallet")
	}

	// The no-file arm.
	if err := os.Remove(f.wpath); err != nil {
		t.Fatal(err)
	}
	key := profileRefV2(f.name, f.p2)
	noWalletRenewedMu.Lock()
	noWalletRenewed[key] = &Wallet{RenewedEpoch: 42, PaidThrough: 99}
	noWalletRenewedMu.Unlock()
	if _, paid, err := payRentGenSignOut(f.gw, f.base, f.name, f.p2, f.wpath, nil, walletGeneration(f.wpath)); err != nil || paid {
		t.Fatalf("no file, renewed this epoch: paid=%v err=%v, want a skip", paid, err)
	}
	if n := len(f.sent()); n != 0 {
		t.Fatalf("no file, renewed this epoch: %d /lease requests, want 0", n)
	}
	noWalletRenewedMu.Lock()
	noWalletRenewed[key] = &Wallet{RenewedEpoch: 41, PaidThrough: 99}
	noWalletRenewedMu.Unlock()
	if noWalletRenewalDue(key, 42) {
		t.Fatal("control: the stand-in is due on the periodic rule; the arm below would prove nothing")
	}
	if _, paid, err := payRentGenSignOut(f.gw, f.base, f.name, f.p2, f.wpath, nil, walletGeneration(f.wpath)); err != nil || !paid {
		t.Fatalf("no file, renewed last epoch: paid=%v err=%v, want a renewal", paid, err)
	}
	if n := len(f.sent()); n == 0 {
		t.Fatal("no file, renewed last epoch: no /lease request, want the footprint renewed")
	}
}

// S3: no managed-store gateway on the device -> no request, no log line, no wallet write.
func TestSignOutRenewal_NoGatewayNoRequest(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)
	t.Setenv("GATEWAY_URL", "")
	dest := t.TempDir()
	wp := walletPathFor(dest)
	if err := saveWallet(wp, &Wallet{PaidThrough: 92, RenewedEpoch: 39,
		Tokens: []Token{{Denom: "1GBmo", Nonce: "sorenew3-0", Exp: 1 << 62, Sig: "s"}}}); err != nil {
		t.Fatal(err)
	}
	before := fileBytes(t, wp)
	out := captureStderr(t, func() {
		renewAtSignOut(dest, "sorenew3", "pale amber kettle orchard", nil, walletGeneration(wp), "21")
	})
	if strings.Contains(out, "signout-renewal") {
		t.Fatalf("a device with no gateway logged a sign-out renewal:\n%s", out)
	}
	if n := hits.Load(); n != 0 {
		t.Fatalf("%d gateway requests with GATEWAY_URL empty, want 0", n)
	}
	if !bytes.Equal(fileBytes(t, wp), before) {
		t.Fatal("a device with no gateway rewrote the wallet at sign-out")
	}
}

// S4: a sign-in took the wallet between the sign-out's read and the renewal -> payRentGenRule's own generation check
// refuses: nothing spent, the file and the departed profile's #wallet head untouched.
func TestSignOutRenewal_AMovedGenerationSpendsAndSavesNothing(t *testing.T) {
	f := renewBatchSetup(t, "sorenew4", 2)
	signOutWallet(t, f, 92, 39)
	gen := walletGeneration(f.wpath)
	if err := bumpWalletGeneration(f.wpath); err != nil {
		t.Fatal(err)
	}
	before := fileBytes(t, f.wpath)
	whk := walletHeadKey(f.base, f.name, f.p2)
	head := getRef(f.base, whk)
	_, paid, err := payRentGenSignOut(f.gw, f.base, f.name, f.p2, f.wpath, nil, gen)
	if err == nil && paid {
		t.Fatal("payRentGenSignOut renewed from a generation that had moved, want a refusal")
	}
	for i, r := range f.sent() {
		if len(r.Tokens) != 0 || len(r.BlindTokens) != 0 {
			t.Fatalf("request %d spent %d token(s) from another profile's wallet", i, len(r.Tokens)+len(r.BlindTokens))
		}
	}
	if !bytes.Equal(fileBytes(t, f.wpath), before) {
		t.Fatal("the refused sign-out renewal rewrote the wallet that changed hands")
	}
	if got := getRef(f.base, whk); got != head {
		t.Fatal("the refused sign-out renewal moved the departed profile's #wallet head")
	}
}

// S5: the periodic path keeps today's rule: renewed three epochs ago inside a live term sends nothing.
func TestSignOutRenewal_ThePeriodicRuleIsUnchanged(t *testing.T) {
	f := renewBatchSetup(t, "sorenew5", 2)
	signOutWallet(t, f, 92, 39)
	if _, paid, err := payRentGen(f.gw, f.base, f.name, f.p2, f.wpath, nil, walletGeneration(f.wpath)); err != nil || paid {
		t.Fatalf("payRentGen: paid=%v err=%v, want the periodic rule's skip", paid, err)
	}
	if n := len(f.sent()); n != 0 {
		t.Fatalf("payRentGen sent %d /lease requests for a footprint renewed three epochs ago, want 0", n)
	}
	for _, c := range []struct {
		why               string
		w                 Wallet
		periodic, signOut bool
	}{
		{"renewed 3 epochs ago, term live", Wallet{PaidThrough: 92, RenewedEpoch: 39}, false, true},
		{"renewed this epoch, term live", Wallet{PaidThrough: 92, RenewedEpoch: 42}, false, false},
		{"rent due", Wallet{PaidThrough: 42, RenewedEpoch: 42}, true, true},
		{"footprint stale", Wallet{PaidThrough: 92, RenewedEpoch: 42 - renewEveryEpochs}, true, true},
	} {
		w := c.w
		if got := renewalDue(&w, 42); got != c.periodic {
			t.Errorf("%s: renewalDue = %v, want %v", c.why, got, c.periodic)
		}
		if got := dueBy(renewPeriodic, &w, 42); got != c.periodic {
			t.Errorf("%s: the periodic rule = %v, want %v", c.why, got, c.periodic)
		}
		if got := dueBy(renewSignOut, &w, 42); got != c.signOut {
			t.Errorf("%s: the sign-out rule = %v, want %v", c.why, got, c.signOut)
		}
	}
	noWalletRenewedReset(t)
	key := profileRefV2("sorenew5", "x")
	noWalletRenewedMu.Lock()
	noWalletRenewed[key] = &Wallet{RenewedEpoch: 39, PaidThrough: 92}
	noWalletRenewedMu.Unlock()
	if noWalletDueBy(renewPeriodic, key, 42) {
		t.Error("no file, renewed 3 epochs ago, term live: the periodic rule is due, want not")
	}
	if !noWalletDueBy(renewSignOut, key, 42) {
		t.Error("no file, renewed 3 epochs ago, term live: the sign-out rule is not due, want due")
	}
}

// S7: the free-tier latch map is only touched under freeRenewedMu (the sign-out renewal runs beside a periodic one,
// and a concurrent map access is a fatal throw no recover() catches).
func TestSignOutRenewal_TheFreeLatchIsOnlyTouchedUnderItsLock(t *testing.T) {
	bb, err := os.ReadFile("billing.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(bb)
	inHelpers := 0
	for _, fn := range []string{"freeRenewedEpoch", "latchFreeRenewed"} {
		body := strings.Join(funcBody(t, src, fn), "\n")
		if !strings.Contains(body, "freeRenewedMu.Lock()") {
			t.Errorf("%s does not take freeRenewedMu", fn)
		}
		inHelpers += strings.Count(body, "freeRenewedThrough[")
	}
	if all := strings.Count(src, "freeRenewedThrough["); all != inHelpers || all != 2 {
		t.Errorf("billing.go indexes freeRenewedThrough %d time(s), %d inside its two locked helpers; want exactly 2, "+
			"both inside", all, inHelpers)
	}
	body := strings.Join(stripComments(funcBody(t, src, "payRentGenRule")), "\n")
	for _, want := range []string{"freeRenewedEpoch(meterKey)", "latchFreeRenewed(meterKey, q.CurrentEpoch)"} {
		if !strings.Contains(body, want) {
			t.Errorf("payRentGenRule does not call %s", want)
		}
	}
}

// S6: handleLogout's landed arm runs the renewal once, BEFORE the wallet step, with the generation read at the top;
// a failed seal runs neither.
func signOutRenewalWiring(t *testing.T, uid, out string) (steps []string, renews []logoutCall, dest, wantGen string) {
	t.Helper()
	dest = cutoffSession(t, uid)
	if err := bumpWalletGeneration(walletPathFor(dest)); err != nil {
		t.Fatal(err)
	}
	wantGen = walletGeneration(walletPathFor(dest))
	var mu sync.Mutex
	oldR, oldW := logoutRenewStep, logoutWalletStep
	logoutRenewStep = func(d, name, pass string, se []byte, gen, u string) {
		mu.Lock()
		steps = append(steps, "renew")
		renews = append(renews, logoutCall{dest: d, name: name, uid: u, gen: gen})
		mu.Unlock()
	}
	logoutWalletStep = func(d, name, pass string, se []byte, gen, u string) (bool, error) {
		mu.Lock()
		steps = append(steps, "wallet")
		mu.Unlock()
		return false, nil
	}
	t.Cleanup(func() { logoutRenewStep, logoutWalletStep = oldR, oldW })
	cutoffWorker(t, dest, map[string]string{"cutoff": "OK 0", "sweepmedia": "OK", "out": out, "cutoffwake": "WAKE OK 0"}, nil)
	if got := ropReply(t, func(c net.Conn) { handleLogout(c, dest) }); got != "OK" {
		t.Fatalf("LOGOUT replied %q", got)
	}
	if out == "OK" {
		deadline := time.Now().Add(15 * time.Second)
		for {
			mu.Lock()
			n := len(steps)
			mu.Unlock()
			if n >= 2 {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("the sign-out steps did not both run after a landed sign-out (ran: %v)", steps)
			}
			time.Sleep(20 * time.Millisecond)
		}
		ackReapAction("SWITCH", uid)
		ackReapAction("REAP", uid)
	} else {
		logoffDone(t, uid, 20*time.Second)
	}
	time.Sleep(300 * time.Millisecond) // room for a call that must NOT come
	mu.Lock()
	defer mu.Unlock()
	return append([]string(nil), steps...), append([]logoutCall(nil), renews...), dest, wantGen
}

func TestSignOutRenewal_RunsBeforeTheWalletStepOnceOnALandedSignOut(t *testing.T) {
	steps, renews, dest, gen := signOutRenewalWiring(t, "57", "OK")
	if !reflect.DeepEqual(steps, []string{"renew", "wallet"}) {
		t.Fatalf("the landed arm ran %v, want [renew wallet]: the renewal once, before the wallet publish", steps)
	}
	if c := renews[0]; c.dest != dest || c.uid != "57" || c.name != "alice" || c.gen != gen {
		t.Errorf("the renewal got %+v, want dest %s uid 57 name alice gen %q", c, filepath.Base(dest), gen)
	}
}

func TestSignOutRenewal_NeverRunsWhenTheSealFailed(t *testing.T) {
	steps, _, _, _ := signOutRenewalWiring(t, "58", "ERR-PUSH 1")
	if len(steps) != 0 {
		t.Fatalf("a failed seal ran %v -- that session stays signed in and renews on its own schedule", steps)
	}
}
