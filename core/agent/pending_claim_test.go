package main

// NWP-20261125-05 (decided 2026-11-02, h53 #6): the claim code of a deferred drain waits in the profile's wallet,
// sealed with it; any later session on any phone drains it, and the drain clears the entry in the same publish that
// adds the tokens -- only once the gateway proves the code empty. Phones are state dirs (a wallet file and a seen-set
// each) against one fake store; the claims are drained against pcGateway. Every test has its own profile name.

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"nowhereagent/blindrsa"
)

// pcGateway blind-signs per-code claims (all-or-nothing per batch, 402 for an unknown or short code, as the real
// gateway does) and counts the tokens it issued per code. failAfter > 0 answers 500 to every /issue once that many
// have succeeded; healthy() lifts it.
type pcGateway struct {
	srv       *httptest.Server
	mu        sync.Mutex
	left      map[string]int
	issued    map[string]int
	okIssues  int
	failAfter int
	failAll   bool
}

func newPCGateway(t *testing.T, funded map[string]int) *pcGateway {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	g := &pcGateway{left: map[string]int{}, issued: map[string]int{}}
	for c, n := range funded {
		g.left[c] = n
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/issue/pubkey", func(w http.ResponseWriter, _ *http.Request) {
		der, _ := x509.MarshalPKIXPublicKey(&priv.PublicKey)
		p := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
		json.NewEncoder(w).Encode(map[string]string{"pubkey_pem": p, "denom": "1GBmo"})
	})
	mux.HandleFunc("/issue", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Claim   string   `json:"claim"`
			Blinded []string `json:"blinded"`
		}
		json.NewDecoder(r.Body).Decode(&req)
		g.mu.Lock()
		if g.failAll || (g.failAfter > 0 && g.okIssues >= g.failAfter) {
			g.mu.Unlock()
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		n, ok := g.left[req.Claim]
		if !ok || len(req.Blinded) == 0 || len(req.Blinded) > n {
			g.mu.Unlock()
			w.WriteHeader(http.StatusPaymentRequired)
			return
		}
		g.left[req.Claim] = n - len(req.Blinded)
		g.issued[req.Claim] += len(req.Blinded)
		g.okIssues++
		g.mu.Unlock()
		sigs := make([]string, len(req.Blinded))
		for i, b := range req.Blinded {
			raw, _ := base64.StdEncoding.DecodeString(b)
			s, err := blindrsa.BlindSign(priv, raw)
			if err != nil {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			sigs[i] = base64.StdEncoding.EncodeToString(s)
		}
		json.NewEncoder(w).Encode(issueResp{BlindSigs: sigs})
	})
	g.srv = httptest.NewServer(mux)
	t.Cleanup(g.srv.Close)
	return g
}

func (g *pcGateway) client() *gatewayClient { return newGatewayClient(g.srv.URL, gwDefault) }

func (g *pcGateway) issuedFor(code string) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.issued[code]
}

func (g *pcGateway) healthy() {
	g.mu.Lock()
	g.failAfter, g.failAll = 0, false
	g.mu.Unlock()
}

// pcPhones is one profile on a fake store, phone A's wallet (walletRaceEnv) holding codes and published.
type pcPhones struct {
	name, pass string
	dk         []byte
	wa         string
}

func pcSetup(t *testing.T, name string, codes ...string) *pcPhones {
	t.Helper()
	p := &pcPhones{name: name, pass: "the passphrase of " + name}
	p.wa = walletRaceEnv(t)
	standUpProfile(t, p.name, p.pass)
	p.dk = resolveDK("s3", p.name, p.pass, nil)
	if p.dk == nil {
		t.Fatal("the profile does not resolve")
	}
	if err := saveWallet(p.wa, &Wallet{PendingClaims: codes}); err != nil {
		t.Fatal(err)
	}
	p.publish(t, p.wa)
	return p
}

func (p *pcPhones) publish(t *testing.T, wpath string) {
	t.Helper()
	t.Setenv("NOWHERE_WALLET", wpath)
	if _, err := sealWalletDurable("s3", p.name, p.pass, p.dk, wpath); err != nil {
		t.Fatalf("publish: %v", err)
	}
}

// restore is another phone signing in: a fresh state dir whose wallet is the stored one.
func (p *pcPhones) restore(t *testing.T) string {
	t.Helper()
	wb := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wb)
	if err := pullWalletStrict("s3", p.name, p.pass, p.dk, wb); err != nil {
		t.Fatalf("restore: %v", err)
	}
	return wb
}

func (p *pcPhones) stored(t *testing.T) *Wallet {
	t.Helper()
	sw := storedWallet(t, p.name, p.pass)
	if sw == nil {
		t.Fatal("no stored wallet")
	}
	return sw
}

func pcLoad(t *testing.T, wpath string) *Wallet {
	t.Helper()
	w, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	return w
}

func pcHolds(w *Wallet, code string) bool {
	for _, c := range w.PendingClaims {
		if c == code {
			return true
		}
	}
	return false
}

func pcShortWait(t *testing.T) {
	t.Helper()
	old := walletSignInWait
	walletSignInWait = 200 * time.Millisecond
	t.Cleanup(func() { walletSignInWait = old })
}

// T1: phone A powers off before the drain; phone B signs in, drains the code, and B's publish holds the tokens and no
// pending code.
func TestPendingClaim_PowerOffThenAnotherPhoneDrainsIt(t *testing.T) {
	const code = "pcT1AAAAAAAAAAAAAAAAAAAA"
	p := pcSetup(t, "pc-t1-poweroff", code)
	if sw := p.stored(t); !pcHolds(sw, code) {
		t.Fatalf("precondition: the published wallet does not carry the pending code (%d codes)", len(sw.PendingClaims))
	}
	wb := p.restore(t)
	if !pcHolds(pcLoad(t, wb), code) {
		t.Fatal("phone B's restored wallet lost the pending code")
	}
	gw := newPCGateway(t, map[string]int{code: 10})
	drained, err := drainPendingClaims(gw.client(), wb)
	if err != nil || drained != 10 {
		t.Fatalf("drainPendingClaims = (%d, %v), want (10, nil)", drained, err)
	}
	bw := pcLoad(t, wb)
	if len(bw.BlindTokens) != 10 || len(bw.PendingClaims) != 0 {
		t.Fatalf("phone B's wallet: %d tokens, %d pending codes; want 10 and 0", len(bw.BlindTokens), len(bw.PendingClaims))
	}
	p.publish(t, wb)
	sw := p.stored(t)
	if len(sw.BlindTokens) != 10 || len(sw.PendingClaims) != 0 {
		t.Fatalf("the published wallet: %d tokens, %d pending codes; want 10 and 0", len(sw.BlindTokens), len(sw.PendingClaims))
	}
}

// T2: both phones restored the code; A drains it, then B's drain gets the proving 402, adds nothing and clears its
// entry. The gateway issued the code's tokens once.
func TestPendingClaim_TwoPhonesDrainItOnce(t *testing.T) {
	const code = "pcT2AAAAAAAAAAAAAAAAAAAA"
	p := pcSetup(t, "pc-t2-twophones", code)
	wa := p.restore(t)
	wb := p.restore(t)
	gw := newPCGateway(t, map[string]int{code: 10})
	if n, err := drainPendingClaims(gw.client(), wa); err != nil || n != 10 {
		t.Fatalf("phone A: drainPendingClaims = (%d, %v), want (10, nil)", n, err)
	}
	if pcHolds(pcLoad(t, wa), code) {
		t.Fatal("phone A kept the code it drained")
	}
	n, err := drainPendingClaims(gw.client(), wb)
	if err != nil || n != 0 {
		t.Fatalf("phone B: drainPendingClaims = (%d, %v), want (0, nil)", n, err)
	}
	if bw := pcLoad(t, wb); pcHolds(bw, code) || bw.balance() != 0 {
		t.Fatalf("phone B: holds the code %v, balance %d; want neither", pcHolds(bw, code), bw.balance())
	}
	if got := gw.issuedFor(code); got != 10 {
		t.Fatalf("the gateway issued %d tokens for the code, want 10 (once)", got)
	}
}

// T3: a session that cleared code P publishes over a stored copy still holding P: P stays out. A stored code Q this
// session never held is carried. The seen-set holds the codes' hashes, never a code.
func TestPendingClaim_AClearedCodeIsNeverResurrected(t *testing.T) {
	const cp, cq = "pcT3PPPPPPPPPPPPPPPPPPPP", "pcT3QQQQQQQQQQQQQQQQQQQQ"
	p := pcSetup(t, "pc-t3-resurrect", cp)
	wb := p.restore(t) // phone B holds P too, and adds Q
	if err := saveWallet(wb, &Wallet{PendingClaims: []string{cp, cq}}); err != nil {
		t.Fatal(err)
	}
	p.publish(t, wb)
	if sw := p.stored(t); !pcHolds(sw, cp) || !pcHolds(sw, cq) {
		t.Fatal("precondition: the stored wallet does not hold both codes")
	}
	// Phone A clears P (its drain got the proving 402) and publishes.
	gw := newPCGateway(t, nil)
	if n, err := drainPendingClaims(gw.client(), p.wa); err != nil || n != 0 {
		t.Fatalf("phone A: drainPendingClaims = (%d, %v), want (0, nil)", n, err)
	}
	if pcHolds(pcLoad(t, p.wa), cp) {
		t.Fatal("precondition: phone A did not clear P")
	}
	p.publish(t, p.wa)
	sw := p.stored(t)
	if pcHolds(sw, cp) {
		t.Error("phone A's publish brought back P, which it held and cleared")
	}
	if !pcHolds(sw, cq) {
		t.Error("phone A's publish dropped Q, which it never held")
	}
	raw, err := os.ReadFile(p.wa + ".seen")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), cp) {
		t.Error("the seen-set file holds the pending code itself")
	}
	if !strings.Contains(string(raw), pendingClaimSeenKey(cp)) {
		t.Error("the seen-set file has no key for the code phone A held")
	}
}

// T4: a gateway error before any token, a busy wallet during the drain, a busy wallet at the clear and an unavailable
// wallet lock at the clear all keep the entry.
func TestPendingClaim_KeptOnFailure(t *testing.T) {
	pcShortWait(t)
	t.Run("gateway error", func(t *testing.T) {
		const code = "pcT4aAAAAAAAAAAAAAAAAAAA"
		p := pcSetup(t, "pc-t4-error", code)
		gw := newPCGateway(t, map[string]int{code: 10})
		gw.failAll = true
		n, err := drainPendingClaims(gw.client(), p.wa)
		if err == nil || n != 0 {
			t.Fatalf("drainPendingClaims = (%d, %v), want (0, an error)", n, err)
		}
		if !pcHolds(pcLoad(t, p.wa), code) {
			t.Fatal("a gateway error cleared the pending code")
		}
	})
	t.Run("busy during the drain", func(t *testing.T) {
		const code = "pcT4bAAAAAAAAAAAAAAAAAAA"
		p := pcSetup(t, "pc-t4-busydrain", code)
		gw := newPCGateway(t, map[string]int{code: 10})
		unlock, st := lockWalletWithin(p.wa, time.Minute)
		if st == walletLockBusy {
			t.Fatal("precondition: could not take the wallet lock")
		}
		n, err := drainPendingClaims(gw.client(), p.wa)
		unlock()
		if !errors.Is(err, errWalletBusy) || n != 0 {
			t.Fatalf("drainPendingClaims = (%d, %v), want (0, errWalletBusy)", n, err)
		}
		if !pcHolds(pcLoad(t, p.wa), code) {
			t.Fatal("a busy wallet cleared the pending code")
		}
	})
	t.Run("busy at the clear", func(t *testing.T) {
		const code = "pcT4cAAAAAAAAAAAAAAAAAAA"
		p := pcSetup(t, "pc-t4-busyclear", code)
		gw := newPCGateway(t, nil) // the code is empty: the drain proves it
		var unlock func()
		pendingClaimBeforeClear = func() { unlock, _ = lockWalletWithin(p.wa, time.Minute) }
		t.Cleanup(func() { pendingClaimBeforeClear = nil })
		_, err := drainPendingClaims(gw.client(), p.wa)
		if unlock != nil {
			unlock()
		}
		if !errors.Is(err, errWalletBusy) {
			t.Fatalf("drainPendingClaims error = %v, want errWalletBusy", err)
		}
		if !pcHolds(pcLoad(t, p.wa), code) {
			t.Fatal("a busy lock at the clear still cleared the pending code")
		}
	})
	t.Run("unavailable lock at the clear", func(t *testing.T) {
		const code = "pcT4dAAAAAAAAAAAAAAAAAAA"
		p := pcSetup(t, "pc-t4-nolock", code)
		gw := newPCGateway(t, nil) // the code is empty: the drain proves it
		// A directory where the lock file goes: lockWalletWithin cannot open it and reports walletLockUnavailable.
		pendingClaimBeforeClear = func() {
			lp := p.wa + ".lock"
			if err := os.Remove(lp); err != nil && !os.IsNotExist(err) {
				t.Errorf("remove the lock file: %v", err)
			}
			if err := os.Mkdir(lp, 0o700); err != nil {
				t.Errorf("make the lock path a directory: %v", err)
			}
		}
		t.Cleanup(func() { pendingClaimBeforeClear = nil })
		_, err := drainPendingClaims(gw.client(), p.wa)
		if !errors.Is(err, errPendingClaimLockUnavailable) {
			t.Fatalf("drainPendingClaims error = %v, want errPendingClaimLockUnavailable", err)
		}
		if !pcHolds(pcLoad(t, p.wa), code) {
			t.Fatal("an unavailable lock at the clear still cleared the pending code (an unlocked save)")
		}
	})
}

// T4b and T6: a gateway that funds part of the code and then errors keeps the entry with the landed tokens; a later
// run against a healthy gateway drains the rest and then clears it.
func TestPendingClaim_APartialDrainKeepsTheCodeAndFinishesLater(t *testing.T) {
	const code = "pcT6AAAAAAAAAAAAAAAAAAAA"
	p := pcSetup(t, "pc-t6-partial", code)
	gw := newPCGateway(t, map[string]int{code: 10})
	gw.failAfter = 2 // batches 1 and 2 land (3 tokens), then 500
	n, _ := drainPendingClaims(gw.client(), p.wa)
	w := pcLoad(t, p.wa)
	if n != 3 || len(w.BlindTokens) != 3 {
		t.Fatalf("partial drain: drained %d, wallet holds %d; want 3 and 3", n, len(w.BlindTokens))
	}
	if !pcHolds(w, code) {
		t.Fatal("a partial drain cleared the pending code: the 7 tokens left on it are lost")
	}
	gw.healthy()
	n, err := drainPendingClaims(gw.client(), p.wa)
	if err != nil || n != 7 {
		t.Fatalf("second run: drainPendingClaims = (%d, %v), want (7, nil)", n, err)
	}
	w = pcLoad(t, p.wa)
	if len(w.BlindTokens) != 10 || pcHolds(w, code) {
		t.Fatalf("after the second run: %d tokens, code held %v; want 10 and no code", len(w.BlindTokens), pcHolds(w, code))
	}
	if got := gw.issuedFor(code); got != 10 {
		t.Fatalf("the gateway issued %d tokens for the code, want 10", got)
	}
}

// T5: mergeLateRestore keeps both sides' codes, deduplicated; an older wallet JSON without the field loads with none.
func TestPendingClaim_MergeLateRestoreKeepsBothSides(t *testing.T) {
	const a, b, c = "pcT5AAAAAAAAAAAAAAAAAAAA", "pcT5BBBBBBBBBBBBBBBBBBBB", "pcT5CCCCCCCCCCCCCCCCCCCC"
	got := mergeLateRestore(&Wallet{PendingClaims: []string{a, b}}, &Wallet{PendingClaims: []string{b, c}})
	if strings.Join(got.PendingClaims, ",") != strings.Join([]string{a, b, c}, ",") {
		t.Errorf("mergeLateRestore codes = %d entries, want exactly A, B, C in order", len(got.PendingClaims))
	}
	if only := mergeLateRestore(&Wallet{PendingClaims: []string{a}}, nil); len(only.PendingClaims) != 1 || only.PendingClaims[0] != a {
		t.Errorf("mergeLateRestore(stored, nil) kept %d codes, want stored's one", len(only.PendingClaims))
	}
	if loc := mergeLateRestore(nil, &Wallet{PendingClaims: []string{c}}); len(loc.PendingClaims) != 1 || loc.PendingClaims[0] != c {
		t.Errorf("mergeLateRestore(nil, local) kept %d codes, want local's one", len(loc.PendingClaims))
	}
	old := filepath.Join(t.TempDir(), "wallet.json")
	if err := os.WriteFile(old, []byte(`{"tokens":[],"paid_through":5}`), 0o600); err != nil {
		t.Fatal(err)
	}
	w, err := loadWallet(old)
	if err != nil || len(w.PendingClaims) != 0 || w.PaidThrough != 5 {
		t.Fatalf("an older wallet: err %v, %d codes, paid_through %d; want nil, 0, 5", err, len(w.PendingClaims), w.PaidThrough)
	}
}
