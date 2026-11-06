package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261118-02 (h48 #10, docs/product-decisions.md): a scope head the store REFUSES to read -- a 403, even on a
// fresh cap -- is a failed read, never "scope not sealed yet". The footprint resolved each scope head through the
// non-strict probe, which reads a 403 as absence, so the walk answered measured=true with that scope missing: Storage
// rendered a short size, payRent renewed the rest while the refused scope's chunks aged out, and an export index
// left it out. These tests refuse one sibling scope's head (#de) and require the walk to raise errStoreUnreachable,
// as NWP-20261117-14 already does for a transport failure, on cap mode and on plain HTTP. GET-USAGE's line, payRent
// and the export index fail closed; installHeadroom still fails open. The guards: a scope with no head at all, and
// a profile that never sealed #keys, stay measured.

const fpRefusedPass = "horse battery staple correct"

// fpRefusedSealDir writes one small file into a new temp dir for a push.
func fpRefusedSealDir(t *testing.T, body string) string {
	t.Helper()
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return d
}

// fpRefusedCap is a cap-mode mock store holding a created profile with its bare vault sealed and, when withDE, its
// #de scope sealed too. It returns the store's URL.
func fpRefusedCap(t *testing.T, name string, withDE bool) string {
	t.Helper()
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	contentCacheMu.Lock()
	contentCache = nil
	contentCacheMu.Unlock()
	old := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = old; capReadCache = map[string]capEntry{} })
	t.Setenv("NOWHERE_STATE", t.TempDir())
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	if createVault("s3", name, fpRefusedPass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	pushProfile("s3", name, fpRefusedPass, fpRefusedSealDir(t, "bare data of "+name))
	pushFenceSeq, pushFenceSampled = 0, false // see sealDEInSession
	if withDE {
		pushProfile("s3", name+"#de", fpRefusedPass, fpRefusedSealDir(t, "app data of "+name))
		pushFenceSeq, pushFenceSampled = 0, false
	}
	return srv.URL
}

// fpRefusedCapProxy points the cap-mode store at a reverse proxy over srvURL that answers 403 to every GET of the
// object key "ref/<ref>", on every cap, and passes everything else through.
func fpRefusedCapProxy(t *testing.T, srvURL, ref string) {
	t.Helper()
	target, err := url.Parse(srvURL)
	if err != nil {
		t.Fatal(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	px := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/obj" && r.URL.Query().Get("k") == "ref/"+ref {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(px.Close)
	t.Setenv("GATEWAY_URL", px.URL)
	capReadCache = map[string]capEntry{}
}

// fpRefusedHTTPFront is a front for a plain HTTP store that answers 403 with an empty body to every request for
// /ref/<ref> and passes everything else through.
func fpRefusedHTTPFront(t *testing.T, inner, ref string) string {
	t.Helper()
	target, err := url.Parse(inner)
	if err != nil {
		t.Fatal(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	px := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/ref/"+ref {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(px.Close)
	return px.URL
}

// fpRefusedDERef is the #de scope's v2 head ref, the one the tests refuse.
func fpRefusedDERef(name string) string { return profileRefV2(name+"#de", fpRefusedPass) }

// fpRefusedRequireDE checks the uncut walk is measured and holds the #de head ref, else the cut proves nothing.
func fpRefusedRequireDE(t *testing.T, base, name string) {
	t.Helper()
	refs, measured := profileFootprint(base, name, fpRefusedPass, nil)
	if _, ok := refs["ref/"+fpRefusedDERef(name)]; !measured || !ok {
		t.Fatalf("uncut: measured=%v, #de head ref present=%v -- the fixture did not seal #de", measured, ok)
	}
}

// fpRefusedRequirePanic runs profileFootprint against base and requires a panic marked errStoreUnreachable.
func fpRefusedRequirePanic(t *testing.T, base, name, what string) {
	t.Helper()
	var refs map[string]int64
	var measured bool
	r := panicOf(func() { refs, measured = profileFootprint(base, name, fpRefusedPass, nil) })
	if !fpTransportUnreachable(r) {
		_, hasDE := refs["ref/"+fpRefusedDERef(name)]
		t.Fatalf("%s: a refused #de head gave recover()=%v measured=%v (#de head ref present=%v) -- want a panic "+
			"marked errStoreUnreachable, never a measured footprint without that scope", what, r, measured, hasDE)
	}
}

// 1: cap mode, the #de head GET is answered 403 on every cap.
func TestFootprintRefused_CapHeadPanics(t *testing.T) {
	const name = "fprefused1"
	srvURL := fpRefusedCap(t, name, true)
	fpRefusedRequireDE(t, "s3", name)
	fpRefusedCapProxy(t, srvURL, fpRefusedDERef(name))
	fpRefusedRequirePanic(t, "s3", name, "cap mode")
}

// 2: GET-USAGE's line. entitlementLine has no recover, so the refusal reaches it as a panic marked
// errStoreUnreachable (the daemon's handler turns that into a failed request); it must never answer OK.
func TestFootprintRefused_EntitlementLine(t *testing.T) {
	const name = "fprefused2"
	srvURL := fpRefusedCap(t, name, true)
	g := newRentGateway(t)
	fpRefusedCapProxy(t, srvURL, fpRefusedDERef(name))

	var line string
	r := panicOf(func() {
		line = entitlementLine(newGatewayClient(g.srv.URL, gwDefault), "s3", name, fpRefusedPass, os.Getenv("NOWHERE_WALLET"), nil)
	})
	if strings.HasPrefix(line, "OK") {
		t.Fatalf("entitlementLine answered %q with the #de head refused -- a short size rendered as fact", line)
	}
	if !fpTransportUnreachable(r) {
		t.Fatalf("entitlementLine with the #de head refused gave recover()=%v line=%q -- want a panic marked "+
			"errStoreUnreachable", r, line)
	}
}

// 3: payRent leases nothing, reports no success, and does not latch the free renewal for the epoch.
func TestFootprintRefused_PayRentRenewsNothing(t *testing.T) {
	const name = "fprefused3"
	srvURL := fpRefusedCap(t, name, true)
	g := newRentGateway(t)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	freeRenewedThrough = map[string]int64{}
	t.Cleanup(func() { freeRenewedThrough = map[string]int64{} })
	fpRefusedCapProxy(t, srvURL, fpRefusedDERef(name))

	var err error
	r := panicOf(func() {
		_, _, err = payRent(newGatewayClient(g.srv.URL, gwDefault), "s3", name, fpRefusedPass, wpath, nil)
	})
	if r == nil && err == nil {
		t.Error("payRent reported success with the #de head refused")
	}
	if len(g.leased) != 0 {
		t.Errorf("payRent presented %d lease(s) without the #de scope", len(g.leased))
	}
	if got := freeRenewedEpoch(profileRefV2(name, fpRefusedPass)); got == 42 {
		t.Error("payRent latched the free renewal for the epoch on a short footprint")
	}
}

// 4: the export index yields no manifest: a panic marked errStoreUnreachable or an error, never a manifest.
func TestFootprintRefused_ExportRefuses(t *testing.T) {
	const name = "fprefused4"
	srvURL := fpRefusedCap(t, name, true)
	fpRefusedCapProxy(t, srvURL, fpRefusedDERef(name))

	var m *ExportManifest
	var err error
	r := panicOf(func() { m, err = buildExportManifest("s3", name, fpRefusedPass, nil, nil) })
	if m != nil {
		t.Fatalf("buildExportManifest built a manifest of %d blob(s) and %d ref(s) with the #de head refused",
			len(m.Blobs), len(m.Refs))
	}
	if !fpTransportUnreachable(r) && err == nil {
		t.Fatalf("buildExportManifest with the #de head refused gave recover()=%v err=nil -- want "+
			"errStoreUnreachable or an error", r)
	}
}

// 5: installHeadroom still fails open, as its comment documents for a footprint error.
func TestFootprintRefused_InstallHeadroomFailsOpen(t *testing.T) {
	const name = "fprefused5"
	srvURL := fpRefusedCap(t, name, true)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /entitlement", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(entitlementInfo{FreeBytes: 1 << 20, EntitledBytes: 1 << 20, CurrentEpoch: 42})
	})
	gw := httptest.NewServer(mux)
	defer gw.Close()
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	saveWallet(wpath, &Wallet{})
	fpRefusedCapProxy(t, srvURL, fpRefusedDERef(name))

	var fits bool
	r := panicOf(func() {
		fits, _, _, _ = installHeadroom(newGatewayClient(gw.URL, gwDefault), "s3", name, fpRefusedPass, wpath, 8<<30, nil)
	})
	if r != nil {
		t.Fatalf("installHeadroom panicked (%v) with the #de head refused -- it must fail open", r)
	}
	if !fits {
		t.Fatal("installHeadroom answered fits=false from a footprint it could not read -- it must fail open " +
			"and let the lease decide")
	}
}

// 6: plain HTTP, the #de head is answered 403. getRefBytesStrict fails with a plain error there, so this is the
// case that needs the footprint to mark the refusal errStoreUnreachable itself.
func TestFootprintRefused_PlainHTTPHeadPanics(t *testing.T) {
	const name = "fprefused6"
	base := newHTTPStore(t)
	createVault(base, name, fpRefusedPass)
	pushProfile(base, name, fpRefusedPass, fpRefusedSealDir(t, "bare data of "+name))
	pushProfile(base, name+"#de", fpRefusedPass, fpRefusedSealDir(t, "app data of "+name))
	fpRefusedRequireDE(t, base, name)
	front := fpRefusedHTTPFront(t, base, fpRefusedDERef(name))
	fpRefusedRequirePanic(t, front, name, "plain HTTP")
}

// 7 (guard): a profile that sealed only its bare vault -- no #de head and no #keys head on any rung -- is still
// measured and holds neither scope's head ref, on cap mode and on plain HTTP.
func TestFootprintRefused_NoHeadStaysMeasured(t *testing.T) {
	check := func(t *testing.T, base, name string) {
		t.Helper()
		var refs map[string]int64
		var measured bool
		if r := panicOf(func() { refs, measured = profileFootprint(base, name, fpRefusedPass, nil) }); r != nil {
			t.Fatalf("a profile with no #de or #keys head panicked the footprint: %v", r)
		}
		if !measured || len(refs) == 0 {
			t.Fatalf("a profile with no #de or #keys head: measured=%v, %d ref(s) -- want measured with the bare "+
				"vault", measured, len(refs))
		}
		for _, sc := range []string{"#de", "#keys"} {
			if _, ok := refs["ref/"+profileRefV2(name+sc, fpRefusedPass)]; ok {
				t.Errorf("the footprint holds a %s head ref for a scope that was never sealed", sc)
			}
		}
	}
	t.Run("cap", func(t *testing.T) {
		const name = "fprefused7a"
		fpRefusedCap(t, name, false)
		check(t, "s3", name)
	})
	t.Run("http", func(t *testing.T) {
		const name = "fprefused7b"
		base := newHTTPStore(t)
		createVault(base, name, fpRefusedPass)
		pushProfile(base, name, fpRefusedPass, fpRefusedSealDir(t, "bare data of "+name))
		check(t, base, name)
	})
}
