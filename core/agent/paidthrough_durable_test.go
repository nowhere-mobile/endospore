package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// NWP-20260829-14. payRent recorded the term and then sealed it with sealWallet, which in CAP MODE returns
// immediately -- "the wallet rides the seal flush (capFlush fold)". But both of capFlush's doFold calls run
// BEFORE its own recordCoverage, so nothing payRent learns is ever folded. The term was written to a tmpfs
// wallet and died with it.
//
// Measured on lynx 2026-08-29: a seal recorded paid_through=20782 and the very next login restored 20694, so
// a paying customer kept seeing "expires today" however correctly the routing worked. The routing fix
// (NWP-20260829-12) was invisible for exactly this reason.
//
// It is not only the display: the same wallet carries the SPEND record, so losing the write loses evidence
// of tokens the gateway has already marked spent.
func TestPayRentPublishesTheWalletInCapMode(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(quoteInfo{
			Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 604800, EpochsPerLease: 4,
			PriceCents: 200, CurrentEpoch: 42, IssuerPubKey: "testpub",
		})
	})
	// A LIVE grant, so payRent takes the entitled path -- the one that records coverage.
	mux.HandleFunc("POST /entitlement", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(entitlementInfo{FreeBytes: 1 << 30, EntitledBytes: 10 << 30, CurrentEpoch: 42})
	})
	// NWP-20260915-26: plan_gb is what a REAL gateway sends beside this term. The entitlement above already
	// declares a live grant, and handleEntitledLease cannot answer one without also
	// naming it: PlanGB = max(ent.LiveGB(now), gbNeeded). Omitting it made this fixture describe a
	// gateway that holds a grant on one endpoint and denies it on the next, which is not a state the
	// server can be in. The test is unchanged in what it proves -- that the term reaches the STORE and
	// not just tmpfs -- and a term still has to be recorded for it to prove anything.
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: 99, PlanGB: 10})
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	base := newHTTPStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	if !capMode() {
		t.Fatal("test must run in cap mode -- that is the only mode where the bug exists")
	}

	name, pass := "durablerent", "wallet must survive the power-off"
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), make([]byte, 4096), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)

	wpath := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(wpath, &Wallet{PlanGB: 10, PlanPeriods: 3, PaidThrough: 42}); err != nil {
		t.Fatal(err)
	}
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed; payRent's copy is judged by its proof
	freeRenewedThrough = map[string]int64{}

	if _, _, err := payRent(newGatewayClient(srv.URL, gwDefault), base, name, pass, wpath, nil); err != nil {
		t.Fatalf("payRent: %v", err)
	}

	// The LOCAL wallet always got the term -- that half was never broken, and asserting only this is what
	// let the bug through on device.
	local, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	if local.PaidThrough != 99 {
		t.Fatalf("local wallet PaidThrough = %d, want 99", local.PaidThrough)
	}

	// THE ASSERTION THAT MATTERS: it must be PUBLISHED, so the next login restores it rather than an older,
	// lower value. In cap mode the old sealWallet wrote nothing at all, so this head never appeared.
	dk := resolveDK(base, name, pass, nil)
	if dk == nil {
		t.Fatal("cannot resolve the profile key")
	}
	h := getRef(base, walletHeadKey(base, name, pass))
	if h == "" {
		t.Fatal("no #wallet head was published -- the recorded term dies with tmpfs, which is the whole bug")
	}
	blob := getChunk(base, h)
	if len(blob) == 0 {
		t.Fatalf("#wallet head %s resolves to nothing", h)
	}
	plain := unseal(dk, blob)
	if len(plain) == 0 {
		t.Fatal("published wallet will not unseal with the profile key")
	}
	var published Wallet
	if err := json.Unmarshal(plain, &published); err != nil {
		t.Fatalf("published wallet is not a wallet: %v", err)
	}
	if published.PaidThrough != 99 {
		t.Fatalf("PUBLISHED wallet PaidThrough = %d, want 99 -- the next login would restore the stale term",
			published.PaidThrough)
	}
}
