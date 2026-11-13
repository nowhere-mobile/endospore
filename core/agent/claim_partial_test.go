package main

// NWP-20261201-21 (decided 2026-11-06, h60 #15): an Add-credits drain cut short before the gateway proved the code empty
// answers PARTIAL <n>[ UNSAVED] and keeps its code in the wallet's pending_claims, saved before the wallet publish that
// carries its tokens. A complete drain answers OK <n>[ UNSAVED] and touches no held code. Every test has its own profile
// name and code.

import (
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// cpSession is a live throwaway session against gw: a claim into it drains into the local wallet and publishes nothing.
func cpSession(t *testing.T, gw *pcGateway, name string) (dest, wpath string) {
	t.Helper()
	pcShortWait(t)
	dest = t.TempDir()
	t.Setenv("GATEWAY_URL", gw.srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", dest)
	wpath = walletPathFor(dest)
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := markRoamSession(dest, name, "the passphrase of "+name, "12", ""); err != nil {
		t.Fatal(err)
	}
	markLocalSession(dest)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	return dest, wpath
}

// cpStored is a live STORED session whose /issue goes to gw. standUp false leaves the profile without a key, so every
// wallet seal fails.
func cpStored(t *testing.T, gw *pcGateway, name string, standUp bool) (dest, wpath string) {
	t.Helper()
	pcShortWait(t)
	pass := "the passphrase of " + name
	dest, wpath = createCodeEnv(t, "cpUNUSEDCODE"+name, 1)
	cpFront(t, gw)
	if standUp {
		standUpProfile(t, name, pass)
	}
	if err := markRoamSession(dest, name, pass, "12", ""); err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	provenWallet(t, wpath)
	return dest, wpath
}

// cpFront puts a server in front of createCodeEnv's gateway that answers /issue from gw and leaves the store to it.
func cpFront(t *testing.T, gw *pcGateway) {
	t.Helper()
	store, err := url.Parse(os.Getenv("GATEWAY_URL"))
	if err != nil {
		t.Fatal(err)
	}
	rest := httputil.NewSingleHostReverseProxy(store)
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/issue") {
			gw.srv.Config.Handler.ServeHTTP(w, r)
			return
		}
		rest.ServeHTTP(w, r)
	}))
	t.Cleanup(front.Close)
	t.Setenv("GATEWAY_URL", front.URL)
}

// cpRefusedAfter is a gateway in front of gw that passes okIssues calls of /issue and then answers 200 with no
// signatures, which the drain's err arm receives.
func cpRefusedAfter(t *testing.T, gw *pcGateway, okIssues int) *gatewayClient {
	t.Helper()
	var mu sync.Mutex
	served := 0
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/issue" {
			mu.Lock()
			refuse := served >= okIssues
			served++
			mu.Unlock()
			if refuse {
				json.NewEncoder(w).Encode(issueResp{})
				return
			}
		}
		gw.srv.Config.Handler.ServeHTTP(w, r)
	}))
	t.Cleanup(front.Close)
	return newGatewayClient(front.URL, gwDefault)
}

func cpClaim(t *testing.T, dest, code string) string {
	t.Helper()
	return ropReply(t, func(c net.Conn) { handleClaim(c, dest, code, false) })
}

func cpCount(w *Wallet, code string) int {
	n := 0
	for _, c := range w.PendingClaims {
		if c == code {
			n++
		}
	}
	return n
}

// cpSeam sets a test seam and restores it when the test ends.
func cpSeam(t *testing.T, seam *func(), fn func()) {
	t.Helper()
	old := *seam
	*seam = fn
	t.Cleanup(func() { *seam = old })
}

func cpNewWallet(t *testing.T) string {
	t.Helper()
	pcShortWait(t)
	wp := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(wp, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	return wp
}

// cpFailAfter sets gw's limit of good /issue calls.
func cpFailAfter(gw *pcGateway, n int) {
	gw.mu.Lock()
	gw.failAfter = n
	gw.mu.Unlock()
}

// T1: three tokens land and the gateway fails before the proving 402: PARTIAL, the tokens, and the code once.
func TestClaimPartial_T1_PartialKeepsTheCode(t *testing.T) {
	const code = "cpT1AAAAAAAAAAAAAAAAAAAA"
	gw := newPCGateway(t, map[string]int{code: 10})
	cpFailAfter(gw, 2)
	dest, wpath := cpSession(t, gw, "cp-t1-partial")
	var got string
	log := captureStderr(t, func() { got = cpClaim(t, dest, code) })
	if got != "PARTIAL 3" {
		t.Fatalf("CLAIM replied %q, want PARTIAL 3", got)
	}
	w := pcLoad(t, wpath)
	if len(w.BlindTokens) != 3 || cpCount(w, code) != 1 {
		t.Fatalf("the wallet holds %d tokens and the code %d time(s); want 3 and 1", len(w.BlindTokens), cpCount(w, code))
	}
	if !strings.Contains(log, "[logind] add-credits: +3 token(s), partial -- the code was kept\n") {
		t.Errorf("no 'was kept' line; stderr:\n%s", log)
	}
	if strings.Contains(log, code) {
		t.Error("the log holds the claim code")
	}
}

// T2: a complete drain answers OK and keeps nothing.
func TestClaimPartial_T2_CompleteAnswersOK(t *testing.T) {
	const code = "cpT2AAAAAAAAAAAAAAAAAAAA"
	gw := newPCGateway(t, map[string]int{code: 3})
	dest, wpath := cpSession(t, gw, "cp-t2-complete")
	if got := cpClaim(t, dest, code); got != "OK 3" {
		t.Fatalf("CLAIM replied %q, want OK 3", got)
	}
	if w := pcLoad(t, wpath); len(w.BlindTokens) != 3 || len(w.PendingClaims) != 0 {
		t.Fatalf("the wallet holds %d tokens and %d pending codes; want 3 and 0", len(w.BlindTokens), len(w.PendingClaims))
	}
}

// T3: the same partial redeemed twice holds the code once.
func TestClaimPartial_T3_RedeemedTwiceHoldsItOnce(t *testing.T) {
	const code = "cpT3AAAAAAAAAAAAAAAAAAAA"
	gw := newPCGateway(t, map[string]int{code: 10})
	cpFailAfter(gw, 2)
	dest, wpath := cpSession(t, gw, "cp-t3-twice")
	if got := cpClaim(t, dest, code); got != "PARTIAL 3" {
		t.Fatalf("first CLAIM replied %q, want PARTIAL 3", got)
	}
	cpFailAfter(gw, 4)
	if got := cpClaim(t, dest, code); got != "PARTIAL 3" {
		t.Fatalf("second CLAIM replied %q, want PARTIAL 3", got)
	}
	if n := cpCount(pcLoad(t, wpath), code); n != 1 {
		t.Fatalf("the wallet holds the code %d time(s), want 1", n)
	}
}

// T4: once the gateway is back, a later drain finishes the kept code and clears it.
func TestClaimPartial_T4_ALaterDrainFinishesAndClears(t *testing.T) {
	const code = "cpT4AAAAAAAAAAAAAAAAAAAA"
	gw := newPCGateway(t, map[string]int{code: 10})
	cpFailAfter(gw, 2)
	dest, wpath := cpSession(t, gw, "cp-t4-finish")
	if got := cpClaim(t, dest, code); got != "PARTIAL 3" {
		t.Fatalf("CLAIM replied %q, want PARTIAL 3", got)
	}
	gw.healthy()
	n, err := drainPendingClaims(gw.client(), wpath)
	if err != nil || n != 7 {
		t.Fatalf("drainPendingClaims = (%d, %v), want (7, nil)", n, err)
	}
	if w := pcLoad(t, wpath); len(w.BlindTokens) != 10 || cpCount(w, code) != 0 {
		t.Fatalf("the wallet holds %d tokens and the code %d time(s); want 10 and 0", len(w.BlindTokens), cpCount(w, code))
	}
}

// T5: a keep that meets a busy wallet saves nothing and still answers PARTIAL, and its one log line names a fixed outcome.
func TestClaimPartial_T5_BusyKeepStillAnswersPartial(t *testing.T) {
	const code = "cpT5AAAAAAAAAAAAAAAAAAAA"
	gw := newPCGateway(t, map[string]int{code: 10})
	cpFailAfter(gw, 2)
	dest, wpath := cpSession(t, gw, "cp-t5-busy")
	var holder func()
	cpSeam(t, &claimBeforeKeep, func() { holder = lockWallet(wpath) })
	var got string
	log := captureStderr(t, func() { got = cpClaim(t, dest, code) })
	if holder == nil {
		t.Fatal("the keep's seam did not run")
	}
	holder()
	if got != "PARTIAL 3" {
		t.Fatalf("CLAIM replied %q, want PARTIAL 3", got)
	}
	w := pcLoad(t, wpath)
	if len(w.BlindTokens) != 3 || cpCount(w, code) != 0 {
		t.Fatalf("the wallet holds %d tokens and the code %d time(s); want 3 and 0", len(w.BlindTokens), cpCount(w, code))
	}
	if !strings.Contains(log, "[logind] add-credits: +3 token(s), partial -- the code could not be kept (busy)\n") {
		t.Errorf("no 'could not be kept (busy)' line; stderr:\n%s", log)
	}
	if strings.Contains(log, code) {
		t.Error("the log holds the claim code")
	}
}

// T6: partial is true on the three arms that stop before the proving 402 with tokens landed, and false otherwise.
func TestClaimPartial_T6_DrainOutcome(t *testing.T) {
	check := func(t *testing.T, g *gatewayClient, wp, code string, wantN int, wantPartial bool) {
		t.Helper()
		n, partial, err := drainClaimOutcome(g, wp, code, "")
		if n != wantN || partial != wantPartial || err != nil {
			t.Fatalf("drainClaimOutcome = (%d, %v, %v), want (%d, %v, nil)", n, partial, err, wantN, wantPartial)
		}
	}
	t.Run("err_arm", func(t *testing.T) {
		const code = "cpT6ERRAAAAAAAAAAAAAAAAA"
		gw := newPCGateway(t, map[string]int{code: 10})
		check(t, cpRefusedAfter(t, gw, 1), cpNewWallet(t), code, 1, true)
	})
	t.Run("default_arm", func(t *testing.T) {
		const code = "cpT6DEFAAAAAAAAAAAAAAAAA"
		gw := newPCGateway(t, map[string]int{code: 10})
		cpFailAfter(gw, 2)
		check(t, gw.client(), cpNewWallet(t), code, 3, true)
	})
	t.Run("busy_arm", func(t *testing.T) {
		const code = "cpT6BUSYAAAAAAAAAAAAAAAA"
		gw := newPCGateway(t, map[string]int{code: 10})
		wp := cpNewWallet(t)
		var holder func()
		cpSeam(t, &claimBetweenBatches, func() {
			if holder == nil {
				holder = lockWallet(wp)
			}
		})
		defer func() {
			if holder != nil {
				holder()
			}
		}()
		check(t, gw.client(), wp, code, 1, true)
	})
	t.Run("final_402", func(t *testing.T) {
		const code = "cpT6DONEAAAAAAAAAAAAAAAA"
		gw := newPCGateway(t, map[string]int{code: 3})
		check(t, gw.client(), cpNewWallet(t), code, 3, false)
	})
	t.Run("unknown_code", func(t *testing.T) {
		gw := newPCGateway(t, map[string]int{})
		check(t, gw.client(), cpNewWallet(t), "cpT6UNKNOWNAAAAAAAAAAAAA", 0, false)
	})
	t.Run("first_batch_error_is_not_partial", func(t *testing.T) {
		const code = "cpT6FIRSTAAAAAAAAAAAAAAA"
		gw := newPCGateway(t, map[string]int{code: 10})
		gw.failAll = true
		n, partial, err := drainClaimOutcome(gw.client(), cpNewWallet(t), code, "")
		if n != 0 || partial || err == nil {
			t.Fatalf("drainClaimOutcome = (%d, %v, %v), want (0, false, an error)", n, partial, err)
		}
	})
	t.Run("first_batch_busy_is_not_partial", func(t *testing.T) {
		const code = "cpT6FBUSYAAAAAAAAAAAAAAA"
		gw := newPCGateway(t, map[string]int{code: 10})
		wp := cpNewWallet(t)
		holder := lockWallet(wp)
		defer holder()
		n, partial, err := drainClaimOutcome(gw.client(), wp, code, "")
		if n != 0 || partial || !errors.Is(err, errWalletBusy) {
			t.Fatalf("drainClaimOutcome = (%d, %v, %v), want (0, false, errWalletBusy)", n, partial, err)
		}
	})
}

// T7: the keep runs before the seal, so the one publish carries the tokens and the kept code.
func TestClaimPartial_T7_KeepRidesTheSeal(t *testing.T) {
	const code = "cpT7AAAAAAAAAAAAAAAAAAAA"
	const name = "cp-t7-seal"
	gw := newPCGateway(t, map[string]int{code: 10})
	cpFailAfter(gw, 2)
	dest, _ := cpStored(t, gw, name, true)
	if got := cpClaim(t, dest, code); got != "PARTIAL 3" {
		t.Fatalf("CLAIM replied %q, want PARTIAL 3", got)
	}
	sw := storedWallet(t, name, "the passphrase of "+name)
	if sw == nil {
		t.Fatal("no published wallet")
	}
	if len(sw.BlindTokens) != 3 || cpCount(sw, code) != 1 {
		t.Fatalf("the published wallet holds %d tokens and the code %d time(s); want 3 and 1", len(sw.BlindTokens), cpCount(sw, code))
	}
}

// T8: a seal that fails answers PARTIAL <n> UNSAVED, and the local wallet still holds the code.
func TestClaimPartial_T8_SealFailureAnswersPartialUnsaved(t *testing.T) {
	const code = "cpT8AAAAAAAAAAAAAAAAAAAA"
	gw := newPCGateway(t, map[string]int{code: 10})
	cpFailAfter(gw, 2)
	dest, wpath := cpStored(t, gw, "cp-t8-unsaved", false)
	old := claimSealSleep
	claimSealSleep = func(_ time.Duration) {}
	t.Cleanup(func() { claimSealSleep = old })
	if got := cpClaim(t, dest, code); got != "PARTIAL 3 UNSAVED" {
		t.Fatalf("CLAIM replied %q, want PARTIAL 3 UNSAVED", got)
	}
	if n := cpCount(pcLoad(t, wpath), code); n != 1 {
		t.Fatalf("the wallet holds the code %d time(s), want 1", n)
	}
}

// T9: a complete drain does not clear a held code: only drainPendingClaims clears, after its proving call.
func TestClaimPartial_T9_ACompleteDrainDoesNotClearAHeldCode(t *testing.T) {
	const code = "cpT9AAAAAAAAAAAAAAAAAAAA"
	gw := newPCGateway(t, map[string]int{code: 10})
	cpFailAfter(gw, 2)
	dest, wpath := cpSession(t, gw, "cp-t9-held")
	if got := cpClaim(t, dest, code); got != "PARTIAL 3" {
		t.Fatalf("first CLAIM replied %q, want PARTIAL 3", got)
	}
	gw.healthy()
	if got := cpClaim(t, dest, code); got != "OK 7" {
		t.Fatalf("second CLAIM replied %q, want OK 7", got)
	}
	if n := cpCount(pcLoad(t, wpath), code); n != 1 {
		t.Fatalf("the wallet holds the code %d time(s), want 1", n)
	}
}
