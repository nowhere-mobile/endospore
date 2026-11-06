package main

// NWP-20261122-16: a /issue 200 whose signatures the device cannot use (refused by Finalize, one short, or not base64)
// lands no token, so it must record no plan either. drainClaim recorded the purchase from that 200 with no token
// appended, and a wallet that already held credit then bought the plan with it at the next paid lease. Every test
// has its own claim code and its own wallet in a t.TempDir().

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strconv"
	"sync"
	"testing"

	"nowhereagent/blindrsa"
)

type cbsMode int

const (
	cbsBadKey cbsMode = iota // signatures made with a different key than /issue/pubkey serves
	cbsShort                 // one signature fewer than asked
	cbsNotB64                // one signature that is not base64
	cbsGood                  // signed with the served key: the control
)

func (m cbsMode) String() string {
	return [...]string{"bad key", "one short", "not base64", "good"}[m]
}

var (
	cbsKeysOnce         sync.Once
	cbsServed, cbsOther *rsa.PrivateKey
	cbsKeysErr          error
)

// cbsKeys returns the served key and the other key, generated once for the package's run.
func cbsKeys(t *testing.T) (served, other *rsa.PrivateKey) {
	t.Helper()
	cbsKeysOnce.Do(func() {
		if cbsServed, cbsKeysErr = rsa.GenerateKey(rand.Reader, 2048); cbsKeysErr != nil {
			return
		}
		cbsOther, cbsKeysErr = rsa.GenerateKey(rand.Reader, 2048)
	})
	if cbsKeysErr != nil {
		t.Fatal(cbsKeysErr)
	}
	return cbsServed, cbsOther
}

// cbsGateway serves one key at /issue/pubkey and answers /issue with 200, Periods 3, GB 10 and the mode's body, from a
// finite count: a batch above what is left gets 402. The count bounds the bad modes too, so a mutant that lets their
// tokens land ends its drain and fails on the wallet instead of claiming forever.
func cbsGateway(t *testing.T, mode cbsMode, count int) *gatewayClient {
	t.Helper()
	served, other := cbsKeys(t)
	var mu sync.Mutex
	mux := http.NewServeMux()
	mux.HandleFunc("/issue/pubkey", func(w http.ResponseWriter, _ *http.Request) {
		der, _ := x509.MarshalPKIXPublicKey(&served.PublicKey)
		p := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
		json.NewEncoder(w).Encode(map[string]string{"pubkey_pem": p, "denom": "1GBmo"})
	})
	mux.HandleFunc("/issue", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Claim   string   `json:"claim"`
			Blinded []string `json:"blinded"`
		}
		json.NewDecoder(r.Body).Decode(&req)
		mu.Lock()
		if len(req.Blinded) == 0 || len(req.Blinded) > count {
			mu.Unlock()
			w.WriteHeader(http.StatusPaymentRequired)
			return
		}
		count -= len(req.Blinded)
		mu.Unlock()
		sigs := make([]string, len(req.Blinded))
		for i, b := range req.Blinded {
			raw, _ := base64.StdEncoding.DecodeString(b)
			var s []byte
			switch mode {
			case cbsBadKey:
				// Raw RSA with the other key, reduced mod its modulus: BlindSign(other, ...) would refuse a value at
				// or above that modulus about half the time, and this mode must always answer 200.
				z := new(big.Int).Mod(new(big.Int).SetBytes(raw), other.N)
				s = new(big.Int).Exp(z, other.D, other.N).FillBytes(make([]byte, (other.N.BitLen()+7)/8))
			default:
				var err error
				if s, err = blindrsa.BlindSign(served, raw); err != nil {
					w.WriteHeader(http.StatusBadRequest)
					return
				}
			}
			sigs[i] = base64.StdEncoding.EncodeToString(s)
		}
		switch mode {
		case cbsShort:
			sigs = sigs[:len(sigs)-1]
		case cbsNotB64:
			sigs[len(sigs)-1] = "!!not-base64!!"
		}
		json.NewEncoder(w).Encode(issueResp{BlindSigs: sigs, Periods: 3, GB: 10})
	})
	mux.HandleFunc("/quote", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"gb_per_token": 1, "current_epoch": 100, "free_gb": 1})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return newGatewayClient(srv.URL, gwDefault)
}

// cbsHeldWallet saves a wallet holding 40 plain Tokens with a 5 GB x 1 plan recorded.
func cbsHeldWallet(t *testing.T, path string) {
	t.Helper()
	w := &Wallet{PlanGB: 5, PlanPeriods: 1}
	for i := 0; i < 40; i++ {
		w.Tokens = append(w.Tokens, Token{Denom: "1GBmo", Nonce: "cbs-held-" + strconv.Itoa(i), Exp: 1900000000, Sig: "cbs"})
	}
	if err := saveWallet(path, w); err != nil {
		t.Fatal(err)
	}
}

// cbsSnapshot is what a claim that lands no token must leave as it was.
type cbsSnapshot struct {
	BlindTokens   int
	PlanGB        int
	PlanPeriods   int64
	PlanKeep      bool
	PlanQueue     []PlanSpec
	ActivateAfter int64
	Balance       int
}

func cbsLoad(t *testing.T, path string) *Wallet {
	t.Helper()
	w, err := loadWallet(path)
	if err != nil {
		t.Fatal(err)
	}
	return w
}

func cbsSnap(t *testing.T, path string) cbsSnapshot {
	t.Helper()
	w := cbsLoad(t, path)
	return cbsSnapshot{len(w.BlindTokens), w.PlanGB, w.PlanPeriods, w.PlanKeep, w.PlanQueue, w.ActivateAfter, w.balance()}
}

var cbsBadModes = []cbsMode{cbsBadKey, cbsShort, cbsNotB64}

var cbsWallets = []struct {
	label string
	setup func(*testing.T, string)
}{
	{"empty wallet", func(*testing.T, string) {}},
	{"wallet holding 40 tokens and a 5x1 plan", cbsHeldWallet},
}

// drainClaim over a 200 whose signatures do not land returns 0 and an error, and records no plan.
func TestClaimBadSignature_DrainRecordsNoPlan(t *testing.T) {
	for _, mode := range cbsBadModes {
		for i, wc := range cbsWallets {
			claim := "CBS-DRAIN-" + strconv.Itoa(int(mode)) + "-" + strconv.Itoa(i)
			t.Run(mode.String()+"/"+wc.label, func(t *testing.T) {
				g := cbsGateway(t, mode, 30)
				wpath := filepath.Join(t.TempDir(), "wallet.json")
				wc.setup(t, wpath)
				before := cbsSnap(t, wpath)
				n, err := drainClaim(g, wpath, claim, false)
				if n != 0 || err == nil {
					t.Fatalf("drainClaim = (%d, %v), want (0, an error)", n, err)
				}
				after := cbsSnap(t, wpath)
				if after.BlindTokens != 0 {
					t.Fatalf("the wallet holds %d blind tokens after a refused claim, want 0", after.BlindTokens)
				}
				if !reflect.DeepEqual(after, before) {
					t.Fatalf("a refused claim changed the wallet:\n before %+v\n after  %+v", before, after)
				}
			})
		}
	}
}

// claimTokens over a 200 signed with another key returns an error and leaves the wallet as it was.
func TestClaimBadSignature_ClaimTokens(t *testing.T) {
	for i, wc := range cbsWallets {
		claim := "CBS-CLAIM-" + strconv.Itoa(i)
		t.Run(wc.label, func(t *testing.T) {
			g := cbsGateway(t, cbsBadKey, 30)
			wpath := filepath.Join(t.TempDir(), "wallet.json")
			wc.setup(t, wpath)
			before := cbsLoad(t, wpath)
			n, err := claimTokens(g, wpath, claim, 3)
			if err == nil {
				t.Fatalf("claimTokens = (%d, nil), want an error", n)
			}
			if after := cbsLoad(t, wpath); !reflect.DeepEqual(after, before) {
				t.Fatalf("a refused claim changed the wallet:\n before %+v\n after  %+v", before, after)
			}
		})
	}
}

// The control: the good mode drains every token and records the plan, so the fixture is not vacuous.
func TestClaimBadSignature_GoodModeRecordsPlan(t *testing.T) {
	g := cbsGateway(t, cbsGood, 30)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	n, err := drainClaim(g, wpath, "CBS-GOOD", false)
	if n != 30 || err != nil {
		t.Fatalf("drainClaim = (%d, %v), want (30, nil)", n, err)
	}
	w := cbsLoad(t, wpath)
	if len(w.BlindTokens) != 30 || w.PlanGB != 10 || w.PlanPeriods != 3 {
		t.Fatalf("wallet holds %d blind tokens and plan %d x %d, want 30 and 10 x 3", len(w.BlindTokens), w.PlanGB, w.PlanPeriods)
	}
}
