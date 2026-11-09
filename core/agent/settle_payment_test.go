package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
)

// settle_payment_test.go (NWP-20261128-27): WHICH tokens a partly charged lease returns.
//
// settlePayment hands back the presented tokens the gateway did not charge. The gateway charges plain first,
// then blind (nowhere-cloud internal/gateway/gateway.go, handleLease's legacy loop and collectTokens), so the
// uncharged ones are the TAIL of (plain ++ blind). The only partial-charge test before this one,
// TestLeaseRestoresUnspentTokens, asserts the balance with plain tokens only: a settlePayment that returned the
// spent HEAD, or that settled blind before plain, kept every count right and passed it. Such a build burns
// unspent bearer credit and keeps spent nonces, and the next paid lease answers 409. These tests compare whole
// tokens, in order: a plain token's Denom and Nonce, a blind token's complete Msg ("denom|nonce|exp") and Sig.

// spBlindNonce is the nonce of a blind token: field 2 of its decoded "denom|nonce|exp" message.
func spBlindNonce(b BlindToken) string {
	raw, err := base64.StdEncoding.DecodeString(b.Msg)
	if err != nil {
		return ""
	}
	f := strings.Split(string(raw), "|")
	if len(f) != 3 {
		return ""
	}
	return f[1]
}

func spPlain(ns ...string) []Token {
	out := make([]Token, 0, len(ns))
	for _, n := range ns {
		out = append(out, Token{Denom: "1GBmo", Nonce: n})
	}
	return out
}

// spBlind builds blind tokens from deadBlind's message, each with its own signature, so a returned token whose
// denomination, expiry or signature changed fails the comparison as surely as a wrong nonce.
func spBlind(ns ...string) []BlindToken {
	out := make([]BlindToken, 0, len(ns))
	for _, n := range ns {
		b := deadBlind(n)
		b.Sig = "sig-" + n
		out = append(out, b)
	}
	return out
}

// spHolds reports whether the wallet holds exactly these plain and blind tokens, in order, compared field by field.
func spHolds(w *Wallet, plain []Token, blind []BlindToken) bool {
	return reflect.DeepEqual(append([]Token{}, w.Tokens...), append([]Token{}, plain...)) &&
		reflect.DeepEqual(append([]BlindToken{}, w.BlindTokens...), append([]BlindToken{}, blind...))
}

func spNonces(w *Wallet) (plain, blind []string) {
	plain, blind = []string{}, []string{}
	for _, t := range w.Tokens {
		plain = append(plain, t.Nonce)
	}
	for _, b := range w.BlindTokens {
		blind = append(blind, spBlindNonce(b))
	}
	return plain, blind
}

// spSettle runs settlePayment and turns a panic into a test error, so a broken clamp fails by name and does not
// abort the test binary. It reports whether settlePayment returned normally.
func spSettle(t *testing.T, w *Wallet, plain []Token, blind []BlindToken, spent int) (ok bool) {
	t.Helper()
	defer func() {
		if r := recover(); r != nil {
			t.Errorf("settlePayment(spent=%d) panicked: %v -- a lease answer the clamps exist for crashes the "+
				"daemon instead of settling", spent, r)
			ok = false
		}
	}()
	w.settlePayment(plain, blind, spent)
	return true
}

func TestSettlePayment_ReturnsTheUnspentTailPlainFirst(t *testing.T) {
	all := []string{"spP1", "spP2", "spP3", "spB1", "spB2"}
	for _, spent := range []int{-1, 0, 1, 2, 3, 4, 5, 9} {
		t.Run(fmt.Sprintf("spent=%d", spent), func(t *testing.T) {
			// Fresh slices per case: settlePayment must never see a slice another case also holds.
			w := &Wallet{Tokens: spPlain("spP0"), BlindTokens: spBlind("spB0")}
			if !spSettle(t, w, spPlain("spP1", "spP2", "spP3"), spBlind("spB1", "spB2"), spent) {
				return
			}
			k := spent
			if k < 0 {
				k = 0
			}
			if k > len(all) {
				k = len(all)
			}
			wantPlain, wantBlind := []string{"spP0"}, []string{"spB0"}
			for _, n := range all[k:] {
				if strings.HasPrefix(n, "spP") {
					wantPlain = append(wantPlain, n)
				} else {
					wantBlind = append(wantBlind, n)
				}
			}
			if !spHolds(w, spPlain(wantPlain...), spBlind(wantBlind...)) {
				gotPlain, gotBlind := spNonces(w)
				t.Errorf("presented plain [spP1 spP2 spP3] + blind [spB1 spB2], gateway spent %d: wallet holds "+
					"plain %v blind %v (tokens %+v %+v), want plain %v blind %v, each token unchanged -- the "+
					"gateway charges plain first, then blind, so only the unspent tail of (plain ++ blind) may come "+
					"back; anything else keeps a spent nonce (the next lease answers 409) or burns an unspent "+
					"token nobody can re-issue", spent, gotPlain, gotBlind, w.Tokens, w.BlindTokens, wantPlain,
					wantBlind)
			}
		})
	}
}

func TestSettlePayment_ABlindOnlyAndAPlainOnlyPresentation(t *testing.T) {
	w := &Wallet{}
	if spSettle(t, w, nil, spBlind("spQ1", "spQ2", "spQ3"), 1) {
		if !spHolds(w, nil, spBlind("spQ2", "spQ3")) {
			t.Errorf("blind only [spQ1 spQ2 spQ3], spent 1: wallet holds plain %+v blind %+v, want plain [] "+
				"blind [spQ2 spQ3], each token unchanged -- the charged blind token is the first one",
				w.Tokens, w.BlindTokens)
		}
	}

	w = &Wallet{}
	if spSettle(t, w, spPlain("spR1", "spR2", "spR3"), nil, 2) {
		if !spHolds(w, spPlain("spR3"), nil) {
			t.Errorf("plain only [spR1 spR2 spR3], spent 2: wallet holds plain %+v blind %+v, want plain [spR3] "+
				"blind [], each token unchanged -- the charged plain tokens are the first two", w.Tokens,
				w.BlindTokens)
		}
	}
}

// TestLeaseRefs_ADeltaLeaseReturnsExactlyTheUnchargedTokens drives the profile-less legacy arm of leaseRefs
// against a fake gateway that charges the way the real one does (plain first, then blind) and refuses with 409
// any nonce it has already charged.
func TestLeaseRefs_ADeltaLeaseReturnsExactlyTheUnchargedTokens(t *testing.T) {
	const charge = 2
	type presented struct{ plain, blind []string }
	var (
		mu      sync.Mutex
		seen    []presented
		charged = map[string]bool{}
	)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(quoteInfo{Denom: "1GBmo", GBPerToken: 1, CurrentEpoch: 42})
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		p := presented{plain: []string{}, blind: []string{}}
		for _, tk := range req.Tokens {
			p.plain = append(p.plain, tk.Nonce)
		}
		for _, bt := range req.BlindTokens {
			p.blind = append(p.blind, spBlindNonce(bt))
		}
		mu.Lock()
		defer mu.Unlock()
		seen = append(seen, p)
		for _, n := range append(append([]string{}, p.plain...), p.blind...) {
			if charged[n] {
				w.WriteHeader(http.StatusConflict)
				return
			}
		}
		n := 0
		for _, nonce := range append(append([]string{}, p.plain...), p.blind...) { // plain, then blind
			if n == charge {
				break
			}
			charged[nonce] = true
			n++
		}
		json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: 46, Spent: n, WriteCaps: map[string]string{}})
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	path := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(path, &Wallet{Tokens: spPlain("spL1", "spL2", "spL3", "spL4"), BlindTokens: spBlind("spLB1")}); err != nil {
		t.Fatal(err)
	}
	g := newGatewayClient(srv.URL, gwDefault)
	// 4 GiB -> the device offers 4: choosePayment takes the blind spLB1 first, then plain spL1..spL3. The gateway
	// charges plain first, so spL1 and spL2 are gone and spL3 and spLB1 come back.
	if _, _, err := leaseRefs(g, path, "", map[string]int64{"spDeltaRef": 4 * giB}, nil); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	got := append([]presented(nil), seen...)
	mu.Unlock()
	if len(got) != 1 || !reflect.DeepEqual(got[0].plain, []string{"spL1", "spL2", "spL3"}) ||
		!reflect.DeepEqual(got[0].blind, []string{"spLB1"}) {
		t.Fatalf("control: the fake gateway saw %+v, want one lease presenting plain [spL1 spL2 spL3] and blind "+
			"[spLB1] -- the test's own setup is wrong, not settlePayment", got)
	}

	after, err := loadWallet(path)
	if err != nil {
		t.Fatal(err)
	}
	sort.Slice(after.Tokens, func(i, j int) bool { return after.Tokens[i].Nonce < after.Tokens[j].Nonce })
	if !spHolds(after, spPlain("spL3", "spL4"), spBlind("spLB1")) {
		gotPlain, gotBlind := spNonces(after)
		t.Errorf("after a lease the gateway charged 2 of 4 (spL1 spL2): wallet holds plain %v blind %v, want plain "+
			"[spL3 spL4] blind [spLB1] -- a spent spL1/spL2 kept makes the next lease answer 409, and a missing "+
			"spL3/spLB1 is unspent credit burned", gotPlain, gotBlind)
	}

	// The proof that matters to a customer: the next paid lease goes through. The fake answers 409 to any
	// charged nonce presented again, as the real gateway does.
	if _, _, err := leaseRefs(g, path, "", map[string]int64{"spDeltaRef2": 2 * giB}, nil); err != nil {
		t.Errorf("second lease of 2 GiB after the delta lease: %v -- the wallet re-presented a nonce the gateway "+
			"had already charged", err)
	}
}
