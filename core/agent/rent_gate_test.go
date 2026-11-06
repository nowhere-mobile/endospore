package main

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
)

// The rent gate (NWP-20261026-12): maybePayRent and the two unsaved exits exclude each other.

// rgReset puts the gate back; every test registers it.
func rgReset() {
	rentMu.Lock()
	rentInFlight, rentExitHold = 0, false
	rentMu.Unlock()
}

func TestRentGate_ExitHoldStopsANewSpend(t *testing.T) {
	t.Cleanup(rgReset)
	if !holdRentForExit() {
		t.Fatal("holdRentForExit refused on an idle gate")
	}
	if beginRent() {
		t.Error("a spend began while an unsaved exit held the gate")
	}
	releaseRent()
	if !beginRent() {
		t.Error("a spend was refused after the hold was released")
	}
	endRent()
}

func TestRentGate_ASpendInFlightRefusesTheExit(t *testing.T) {
	t.Cleanup(rgReset)
	if !beginRent() {
		t.Fatal("beginRent refused on an idle gate")
	}
	if holdRentForExit() {
		t.Error("an unsaved exit took the gate while a spend was running")
	}
	endRent()
	if !holdRentForExit() {
		t.Error("the exit was refused after the spend ended")
	}
}

func TestRentGate_RestartPendingStopsASpend(t *testing.T) {
	t.Cleanup(rgReset)
	setRestartState("PENDING", "rentgate-pending", "10")
	t.Cleanup(resetRestartState)
	if beginRent() {
		t.Error("a spend began while a restart was pending")
	}
	if rentInFlight != 0 {
		t.Errorf("rentInFlight = %d after a refused spend, want 0", rentInFlight)
	}
}

// rgExitBusy drives one unsaved exit (reply) through the gate: held by a spend it answers BUSY rent without a wallet
// save; once the spend ends it reaches the wallet step, and a BUSY slot refusal under the slot still releases the
// hold.
func rgExitBusy(t *testing.T, f *euFixture, reply func() string) {
	t.Helper()
	t.Cleanup(rgReset)
	if !beginRent() {
		t.Fatal("beginRent refused on an idle gate")
	}
	if got := reply(); got != "BUSY rent" {
		t.Errorf("got %q while a rent payment runs, want BUSY rent", got)
	}
	if f.wallets != 0 {
		t.Errorf("the wallet was saved %d time(s) while a rent payment ran", f.wallets)
	}
	f.untouched("rent payment running")
	endRent()
	laneRW.slot <- struct{}{} // a seal holds the slot: refused AFTER the wallet step
	got := reply()
	<-laneRW.slot
	if got != "BUSY slot" {
		t.Errorf("got %q with the slot held, want BUSY slot", got)
	}
	if f.wallets != 1 {
		t.Errorf("the wallet was saved %d time(s) once the payment ended, want 1", f.wallets)
	}
	if !beginRent() {
		t.Error("a refused exit left the gate held")
	}
	endRent()
}

func TestRestartUnsaved_BusyWhileRentIsPaid(t *testing.T) {
	f := euSetupAs(t, t.TempDir(), "rentgate-restart", "pw")
	logoffSweepFailed(f.name, euUID)
	logoffSweepFailed(f.name, euUID)
	close(f.watch) // a mutant that lets the restart through must reach its reply, not wait on the watchdog
	rgExitBusy(t, f, func() string {
		return ropReply(t, func(c net.Conn) { handleRestartUnsaved(c, f.dest) })
	})
}

func TestEndUnsaved_BusyWhileRentIsPaid(t *testing.T) {
	f := euSetupAs(t, t.TempDir(), "rentgate-end", "pw")
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	rgExitBusy(t, f, f.end)
}

// rgGateway counts the requests a spend would make.
func rgGateway(t *testing.T) *atomic.Int32 {
	t.Helper()
	var n atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n.Add(1)
		http.Error(w, "no", http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)
	t.Setenv("GATEWAY_URL", srv.URL)
	return &n
}

// rgSession is a state dir whose session marker names (marked, "pw") and whose wallet holds one token.
func rgSession(t *testing.T, marked string) string {
	t.Helper()
	dest := t.TempDir()
	t.Setenv("NOWHERE_STATE", dest)
	if err := markRoamSession(dest, marked, "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	w := &Wallet{Tokens: []Token{{Denom: "1", Nonce: "rg-n1", Exp: 1 << 40, Sig: "x"}}}
	if err := saveWallet(walletPathFor(dest), w); err != nil {
		t.Fatal(err)
	}
	return dest
}

// rgStderr returns what fn wrote to os.Stderr.
func rgStderr(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stderr
	os.Stderr = w
	t.Cleanup(func() { os.Stderr = old })
	fn()
	w.Close()
	os.Stderr = old
	b, _ := io.ReadAll(r)
	return string(b)
}

func TestMaybePayRent_SkipsWhileAnExitHolds(t *testing.T) {
	t.Cleanup(rgReset)
	n := rgGateway(t)
	dest := rgSession(t, "rentgate-hold")
	call := func() string {
		return rgStderr(t, func() { maybePayRent(dest, "rentgate-hold", "pw", walletGeneration(walletPathFor(dest))) })
	}
	if !holdRentForExit() {
		t.Fatal("holdRentForExit refused on an idle gate")
	}
	log := call()
	if got := n.Load(); got != 0 {
		t.Errorf("%d gateway request(s) while an unsaved exit held the gate", got)
	}
	if !strings.Contains(log, "skipped -- an unsaved sign-out or restart") {
		t.Errorf("no skip line in %q", log)
	}
	releaseRent()
	// The same call reaches the gateway once the hold is gone: the skip above was the gate, not the fixture.
	log = call()
	if n.Load() == 0 {
		t.Errorf("no gateway request after the hold was released (stderr %q)", log)
	}
	if rentInFlight != 0 {
		t.Errorf("rentInFlight = %d after the call returned, want 0", rentInFlight)
	}
}

func TestMaybePayRent_SkipsAnEndedSession(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(t *testing.T) string
	}{
		{"the marker names another profile", func(t *testing.T) string { return rgSession(t, "rentgate-other") }},
		{"the session is marked local", func(t *testing.T) string {
			dest := rgSession(t, "rentgate-ended")
			markLocalSession(dest)
			return dest
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Cleanup(rgReset)
			n := rgGateway(t)
			dest := tc.setup(t)
			log := rgStderr(t, func() { maybePayRent(dest, "rentgate-ended", "pw", walletGeneration(walletPathFor(dest))) })
			if got := n.Load(); got != 0 {
				t.Errorf("%d gateway request(s) for an ended session", got)
			}
			if !strings.Contains(log, "session ended or was marked local") {
				t.Errorf("no skip line in %q", log)
			}
		})
	}
}
