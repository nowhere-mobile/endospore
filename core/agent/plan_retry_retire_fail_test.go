package main

// NWP-20261020-10: pins residual (f) of the credential-change P0 -- a rotation that fails INSIDE its retire pass
// returns before the plan carry, and the carry must still be recoverable at the next sign-in.
//
// The argument is ordering. repointScopes writes !bill-prev into the NEW index inside the bracket, so the record is
// sealed into the head the publish pass lands; the retire pass runs after that head is published, and a failure
// there panics out of capFlush before the carry. The record is therefore already in the published head, and
// retryPlanCarry (called at every roam-in) re-sends /rebind for it. A tidy-up that moved the !bill-prev write after
// the commit check would strand a paid plan at the retired key with no log line; TestACredentialChangeRecordsThePreviousBillingKey
// would stay green under it, because that rotation succeeds.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// retireFailFront answers POST /rebind itself and forwards every other request to the cap-mode mock store, so the
// store writes of a cap-mode vault and a gateway-side carry share one GATEWAY_URL.
type retireFailFront struct {
	srv  *httptest.Server
	mu   sync.Mutex
	olds []string
	news []string
}

func newRetireFailFront(t *testing.T, upstream string) *retireFailFront {
	t.Helper()
	u, err := url.Parse(upstream)
	if err != nil || u.Host == "" {
		t.Fatalf("fixture: GATEWAY_URL %q is not the mock store", upstream)
	}
	f := &retireFailFront{}
	proxy := httputil.NewSingleHostReverseProxy(u)
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && r.URL.Path == "/rebind" {
			var req struct{ Old, New string }
			_ = json.NewDecoder(r.Body).Decode(&req)
			f.mu.Lock()
			f.olds = append(f.olds, req.Old)
			f.news = append(f.news, req.New)
			f.mu.Unlock()
			_ = json.NewEncoder(w).Encode(map[string]int{"moved": 1})
			return
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *retireFailFront) calls() ([]string, []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.olds...), append([]string(nil), f.news...)
}

func TestARotationThatFailsWhileRetiringLeavesThePlanCarryRetryable(t *testing.T) {
	fastRetries(t)
	ledgerFixture(t)
	const name, p1, p2 = "retirecarry", "old horse battery staple", "new maple stone cloud lantern"
	oldKey, newKey := profileRefV2(name, p1), profileRefV2(name, p2)
	if createVault("s3", name, p1) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	sealBareAndDe(t, name, p1) // a scope head, so the retire pass has something to fail on

	dk1, _, ok := resolveKey("s3", name, p1)
	if !ok {
		t.Fatal("precondition: the vault does not resolve under the old passphrase")
	}
	v1, isV := openVaultHead("s3", name, p1)
	if !isV || v1 == nil {
		t.Fatal("precondition: no vault at the old head")
	}
	idx1, ok := openScopeIndex(dk1, v1.Scopes)
	if !ok || billKeyOf(idx1) != oldKey {
		t.Fatalf("precondition: the p1 index must name %s as !bill, got %s", short(oldKey), short(billKeyOf(idx1)))
	}

	victim := ""
	capStorePutHook = func(key string, body []byte) error {
		if victim == "" && strings.HasPrefix(key, "ref/") && len(body) == 0 {
			victim = key // the first retirement
		}
		if key == victim {
			return errTestStoreRefused
		}
		return nil
	}
	panicked := didPanic(func() { _, _ = rotateVault("s3", name, p1, p2, nil, true) })
	capStorePutHook = nil
	if victim == "" || !panicked || !capRetireBegun {
		t.Fatalf("precondition: want a rotation that failed inside its retire pass (victim=%v panicked=%v retire=%v)",
			victim != "", panicked, capRetireBegun)
	}

	// The record survived: it was sealed into the head the publish pass landed, before the retire pass failed.
	dk, _, ok := resolveKey("s3", name, p2)
	if !ok {
		t.Fatal("the new passphrase does not resolve after the committed-then-failed rotation")
	}
	if got := billPrevOfHead(t, "s3", name, p2, dk); got != oldKey {
		t.Fatalf("!bill-prev in the published head = %s, want the retired key %s -- the carry is unrecoverable: "+
			"no later login can name the key the plan sits at", short(got), short(oldKey))
	}

	// The next sign-in: a front server answers /rebind, everything else reaches the mock store.
	front := newRetireFailFront(t, os.Getenv("GATEWAY_URL"))
	t.Setenv("GATEWAY_URL", front.srv.URL)
	// Rule 2 reads only the path it is given; NOWHERE_WALLET stays the free wallet so dropBillPrev's lease is free.
	wpath := filepath.Join(t.TempDir(), "paid-wallet.json")
	if err := saveWallet(wpath, &Wallet{PaidThrough: 1 << 40, PlanGB: 10}); err != nil {
		t.Fatal(err)
	}
	retryPlanCarry("s3", name, p2, dk, wpath)

	olds, news := front.calls()
	if len(olds) != 1 {
		t.Fatalf("the sign-in retry made %d /rebind call(s), want 1", len(olds))
	}
	if olds[0] != oldKey || news[0] != newKey {
		t.Errorf("retry sent {%s -> %s}, want {%s -> %s}", short(olds[0]), short(news[0]), short(oldKey), short(newKey))
	}
	if got := billPrevOfHead(t, "s3", name, p2, dk); got != "" {
		t.Errorf("!bill-prev survived a confirmed carry (%s): the retry would run at every sign-in", short(got))
	}
}
