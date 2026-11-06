package main

// NWP-20261111-15 (found by the 2026-11-11 farm sweep of core/agent): the untie (untieScopeHeads) and the add-device
// (addScopeSESlots) arm each scope head's stale check at the value they READ before the edit, as the tie
// (prepareScopeRekey) does, so a publish that lands while the edit computes refuses the edit instead of being
// overwritten by a vault built from the older head.
//
// scopeStaleProxy models that publish: another process (the periodic seal, or the other phone) moves the #de head
// while the edit runs. It fires on the first GET of the #de head's blob, which comes after every read the edit arms
// from and before the old code's fresh re-read at the arm. NOWHERE_STATE is never set here: head_prefetch.go's
// head-blob cache would then serve that blob from disk and the hook would never see the GET. One profile name per
// test: the blob and content caches are keyed by a profile's DK.

import (
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"testing"
)

// scopeStaleProxy fronts store and, once, on the first GET of the #de head's blob, publishes X -- a real #de vault
// (the current one with another manifest, Version+1, signed with the scope key the first phone's chip unwraps) -- to
// the #de writeRef by a plain PUT to the store, the way another process would. fired says whether it did.
func scopeStaleProxy(t *testing.T, store, name, pass string) (proxy, x string, fired func() bool) {
	t.Helper()
	scoped := name + "#de"
	ov := scopeHeadVault(t, store, scoped, pass)
	writeRef, _ := headWriteRef(scoped, pass)
	head := getRef(store, writeRef)
	k := unwrapDK(ov, "se", kekSE(scoped, pass, tieSE1))
	if k == nil {
		t.Fatalf("%s: the first phone's chip does not open it", scoped)
	}
	nx := *ov
	nx.Manifest = postBlob(store, []byte("a manifest another process sealed (NWP-20261111-15)"))
	nx.Version, nx.Sig = ov.Version+1, ""
	signVault(&nx, k)
	x = postBlob(store, serializeVault(&nx))
	target, err := url.Parse(store)
	if err != nil {
		t.Fatal(err)
	}
	rp := httputil.NewSingleHostReverseProxy(target)
	var mu sync.Mutex
	done := false
	px := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		hit := !done && r.Method == http.MethodGet && r.URL.Path == "/blob/"+head
		if hit {
			done = true
		}
		mu.Unlock()
		if hit {
			req, err := http.NewRequest(http.MethodPut, store+"/ref/"+writeRef, strings.NewReader(x))
			if err != nil {
				t.Errorf("the hook's publish: %v", err)
			} else if resp, err := http.DefaultClient.Do(req); err != nil {
				t.Errorf("the hook's publish: %v", err)
			} else {
				resp.Body.Close()
			}
		}
		rp.ServeHTTP(w, r)
	}))
	t.Cleanup(px.Close)
	return px.URL, x, func() bool { mu.Lock(); defer mu.Unlock(); return done }
}

func TestScopeStaleUntieRefusesAPublishAfterItsRead(t *testing.T) {
	const name, pass = "untiestale", "horse battery staple correct"
	store, _ := newTiedFixture(t, name, pass)
	tieWithScopes(t, store, name, pass, tieSE1, true)
	_, dk, _ := sessionKeys(t, store, name, pass)
	proxy, x, fired := scopeStaleProxy(t, store, name, pass)

	var uerr error
	vd := capWrite(name, pass, dk, func() { uerr = untieScopeHeads(proxy, name, pass, tieSE1, []string{"#de"}) })
	if !fired() {
		t.Fatal("control: the proxy never published X, so nothing was tested")
	}
	if uerr != nil {
		t.Fatalf("untie: %v (a refusal is the bracket's verdict, not an error)", uerr)
	}
	if !vd.Refused() {
		t.Error("the untie published over a #de head that moved after it read it, and reported success")
	}
	writeRef, _ := headWriteRef(name+"#de", pass)
	if got := getRef(store, writeRef); got != x {
		t.Errorf("#de head is %s, want the X another process published, %s", short(got), short(x))
	}
}

func TestScopeStaleAddDeviceRefusesAPublishAfterItsRead(t *testing.T) {
	const name, pass = "addstale", "horse battery staple correct"
	store, mnemonic := newTiedFixture(t, name, pass)
	tieWithScopes(t, store, name, pass, tieSE1, true)
	proxy, x, fired := scopeStaleProxy(t, store, name, pass)

	err := enrollSEViaRecovery(proxy, name, mnemonic, pass, tieSE2)
	if !fired() {
		t.Fatal("control: the proxy never published X, so nothing was tested")
	}
	if err == nil {
		t.Error("add-device published over a #de head that moved after it read it, and reported success")
	}
	if !sealStaleHit {
		t.Error("sealStaleHit is not set: the refusal did not come from the flush check")
	}
	writeRef, _ := headWriteRef(name+"#de", pass)
	if got := getRef(store, writeRef); got != x {
		t.Errorf("#de head is %s, want the X another process published, %s", short(got), short(x))
	}
	for _, suf := range []string{"#keys", "#sys"} { // the other tied scopes: their pointers were not withheld
		v := scopeHeadVault(t, store, name+suf, pass)
		if unwrapDK(v, "se", kekSE(name+suf, pass, tieSE2)) == nil {
			t.Errorf("%s did not get the added phone's slot", suf)
		}
	}
}
