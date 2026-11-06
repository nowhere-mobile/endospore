package main

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// NWP-20261117-14: profileFootprint is the one walk of a profile's store objects, and its second return,
// `measured`, is what payRent, the export index, GET-USAGE and the install gate refuse on. A head read that
// failed in transport already raised errStoreUnreachable; a MANIFEST read that failed in transport was
// recovered and dropped, so the walk answered measured=true with that manifest and its chunks missing. These
// tests cut the connection on one manifest read (faultyStore: a transport failure) and require the walk to
// raise errStoreUnreachable, the NWP-20260903-01 rule. The guard: a manifest that ARRIVES damaged is still
// skipped, so one broken snapshot does not fail every renewal.

// fpTransportUnreachable reports whether a recovered value is an error marked errStoreUnreachable.
func fpTransportUnreachable(r any) bool {
	err, ok := r.(error)
	return ok && errors.Is(err, errStoreUnreachable)
}

// fpTransportSeal creates a pass-only profile and seals one file into it. The content differs per call, so a
// second call adds a retained snapshot with its own manifest.
func fpTransportSeal(t *testing.T, base, name, pass string, content string, create bool) {
	t.Helper()
	if create {
		createVault(base, name, pass)
	}
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), bytes.Repeat([]byte(content), 2048), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
}

// fpTransportVault reads the bare vault the way the footprint does.
func fpTransportVault(t *testing.T, base, name, pass string) *vault {
	t.Helper()
	v, ok := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if !ok {
		t.Fatal("the bare head is not a vault")
	}
	if v.Manifest == "" {
		t.Fatal("the vault names no live manifest after a push")
	}
	return v
}

// T1: the bare vault's live manifest read fails in transport.
func TestFootprintTransport_LiveManifestCut(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "fptransport1", "horse battery staple correct"
	fpTransportSeal(t, base, name, pass, "one", true)
	v := fpTransportVault(t, base, name, pass)
	front := faultyStore(t, base, map[string]bool{v.Manifest: true}, nil)

	var measured bool
	r := panicOf(func() { _, measured = profileFootprint(front, name, pass, nil) })
	if !fpTransportUnreachable(r) {
		t.Fatalf("a live manifest read that failed in transport gave recover()=%v measured=%v -- want a panic "+
			"marked errStoreUnreachable, never a measured footprint without that manifest", r, measured)
	}
}

// T2: a retained snapshot's manifest read fails in transport.
func TestFootprintTransport_SnapshotManifestCut(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "fptransport2", "horse battery staple correct"
	fpTransportSeal(t, base, name, pass, "first", true)
	fpTransportSeal(t, base, name, pass, "second", false)
	v := fpTransportVault(t, base, name, pass)
	if len(v.History) == 0 || v.History[0].Manifest == "" || v.History[0].Manifest == v.Manifest {
		t.Fatalf("the second push left no distinct retained snapshot (history %d) -- the test proves nothing",
			len(v.History))
	}
	front := faultyStore(t, base, map[string]bool{v.History[0].Manifest: true}, nil)

	var measured bool
	r := panicOf(func() { _, measured = profileFootprint(front, name, pass, nil) })
	if !fpTransportUnreachable(r) {
		t.Fatalf("a snapshot manifest read that failed in transport gave recover()=%v measured=%v -- want "+
			"errStoreUnreachable", r, measured)
	}
}

// T3: the legacy arm. name#de's head is a bare CDC manifest with no Sizes, so addCDCChunks sizes each chunk with
// blobSize, which on a plain HTTP store is a full getBlob. The second chunk's read fails in transport.
func TestFootprintTransport_LegacyArmChunkCut(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "fptransport3", "horse battery staple correct"
	fpTransportSeal(t, base, name, pass, "three", true)
	c1 := postBlob(base, []byte("legacy chunk one of fptransport3"))
	c2 := postBlob(base, []byte("legacy chunk two of fptransport3"))
	js, err := json.Marshal(chunkManifest{Version: 1, Chunks: []string{c1, c2}})
	if err != nil {
		t.Fatal(err)
	}
	pt := append(append([]byte{}, cdcMagic...), js...)
	head := postBlob(base, seal(deriveKey(name+"#de", pass), pt))
	putRef(base, profileRefV2(name+"#de", pass), head)

	// Uncut, the legacy arm adds both chunks: otherwise the cut below would prove nothing.
	if refs, measured := profileFootprint(base, name, pass, nil); !measured || refs["blob/"+c1] == 0 || refs["blob/"+c2] == 0 {
		t.Fatalf("uncut: measured=%v, chunk sizes %d/%d -- the legacy arm did not read the #de chunks",
			measured, refs["blob/"+c1], refs["blob/"+c2])
	}
	front := faultyStore(t, base, map[string]bool{c2: true}, nil)
	var measured bool
	r := panicOf(func() { _, measured = profileFootprint(front, name, pass, nil) })
	if !fpTransportUnreachable(r) {
		t.Fatalf("a legacy-arm chunk read that failed in transport gave recover()=%v measured=%v -- want "+
			"errStoreUnreachable", r, measured)
	}
}

// T4: addRekeyProgress's progress record read fails in transport. Uncut, it leases the record and its chunk.
func TestFootprintTransport_RekeyProgressCut(t *testing.T) {
	base := newHTTPStore(t)
	dk := make([]byte, 32)
	k := make([]byte, 32)
	if _, err := rand.Read(dk); err != nil {
		t.Fatal(err)
	}
	if _, err := rand.Read(k); err != nil {
		t.Fatal(err)
	}
	const chunk, n = "c0ffee00fptransport4", int64(4321)
	js, err := json.Marshal(rekeyProgress{Chunks: map[string]rekeyedChunk{"old": {H: chunk, N: n}}})
	if err != nil {
		t.Fatal(err)
	}
	pb := postBlob(base, seal(k, js))
	sealed := sealScopeIndex(dk, map[string]scopeRec{"#media": {Next: wrap(kekScopes(dk), k), Progress: pb}})

	refs := map[string]int64{}
	if r := panicOf(func() { addRekeyProgress(base, dk, sealed, refs) }); r != nil {
		t.Fatalf("uncut: addRekeyProgress panicked: %v", r)
	}
	if refs["blob/"+pb] == 0 || refs["blob/"+chunk] != n {
		t.Fatalf("uncut: refs = %v -- want the progress record and its chunk (%d bytes)", refs, n)
	}

	front := faultyStore(t, base, map[string]bool{pb: true}, nil)
	r := panicOf(func() { addRekeyProgress(front, dk, sealed, map[string]int64{}) })
	if !fpTransportUnreachable(r) {
		t.Fatalf("a progress record read that failed in transport gave recover()=%v -- want errStoreUnreachable", r)
	}
}

// T5 (guard): a snapshot manifest that ARRIVES DAMAGED is skipped as before. The walk does not panic, stays
// measured, and still holds the live manifest and its chunks.
func TestFootprintTransport_DamagedSnapshotStaysSkipped(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "fptransport5", "horse battery staple correct"
	fpTransportSeal(t, base, name, pass, "first", true)
	fpTransportSeal(t, base, name, pass, "second", false)
	v := fpTransportVault(t, base, name, pass)
	if len(v.History) == 0 || v.History[0].Manifest == v.Manifest {
		t.Fatal("the second push left no distinct retained snapshot -- the test proves nothing")
	}
	dk, _, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatal("resolveKey failed after the push")
	}
	pt := unseal(dk, getBlob(base, v.Manifest))
	var live chunkManifest
	if !bytes.HasPrefix(pt, cdcMagic) || json.Unmarshal(pt[len(cdcMagic):], &live) != nil || len(live.Chunks) == 0 {
		t.Fatal("the live manifest does not parse as a CDC manifest with chunks")
	}
	front := faultyStore(t, base, nil, map[string]bool{v.History[0].Manifest: true})

	var refs map[string]int64
	var measured bool
	if r := panicOf(func() { refs, measured = profileFootprint(front, name, pass, nil) }); r != nil {
		t.Fatalf("a DAMAGED snapshot manifest panicked the footprint (%v) -- one broken snapshot must not fail "+
			"every renewal", r)
	}
	if !measured {
		t.Fatal("a damaged snapshot manifest made the footprint unmeasured")
	}
	if _, ok := refs["blob/"+v.Manifest]; !ok {
		t.Error("the live manifest blob is missing from the footprint")
	}
	for _, c := range live.Chunks {
		if _, ok := refs["blob/"+c]; !ok {
			t.Errorf("the live chunk %s is missing from the footprint", c)
		}
	}
}

// T6: payRent with the live manifest read failing in transport must not lease a short set, and must not latch
// the free renewal for the epoch.
func TestFootprintTransport_PayRentDoesNotRenewShort(t *testing.T) {
	g := newRentGateway(t)
	base := newHTTPStore(t)
	const name, pass = "fptransport6", "horse battery staple correct"
	fpTransportSeal(t, base, name, pass, "six", true)
	v := fpTransportVault(t, base, name, pass)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	freeRenewedThrough = map[string]int64{}
	t.Cleanup(func() { freeRenewedThrough = map[string]int64{} })
	front := faultyStore(t, base, map[string]bool{v.Manifest: true}, nil)

	var err error
	r := panicOf(func() { _, _, err = payRent(newGatewayClient(g.srv.URL, gwDefault), front, name, pass, wpath, nil) })
	if r == nil && err == nil {
		t.Error("payRent reported success with its live manifest unread")
	}
	if len(g.leased) != 0 {
		t.Errorf("payRent presented %d lease(s) without the live manifest and its chunks", len(g.leased))
	}
	if got := freeRenewedEpoch(profileRefV2(name, pass)); got == 42 {
		t.Error("payRent latched the free renewal for the epoch on a short footprint")
	}
}

// T7: installHeadroom fails open, as its comment documents for "a gateway or footprint error", when the
// footprint raises a transport failure: (a) on the live manifest read, (b) on the bare head blob read.
func TestFootprintTransport_InstallHeadroomFailsOpen(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /entitlement", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(entitlementInfo{FreeBytes: 1 << 20, EntitledBytes: 1 << 20, CurrentEpoch: 42})
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	g := newGatewayClient(srv.URL, gwDefault)

	for _, tc := range []struct{ label, name string }{{"live manifest", "fptransport7a"}, {"bare head blob", "fptransport7b"}} {
		base := newHTTPStore(t)
		const pass = "horse battery staple correct"
		fpTransportSeal(t, base, tc.name, pass, "seven", true)
		v := fpTransportVault(t, base, tc.name, pass)
		cut := v.Manifest
		if tc.label == "bare head blob" {
			cut = getRef(base, headKey(base, tc.name, pass))
		}
		front := faultyStore(t, base, map[string]bool{cut: true}, nil)
		wpath := filepath.Join(t.TempDir(), "wallet.json")
		saveWallet(wpath, &Wallet{})

		var fits bool
		if r := panicOf(func() { fits, _, _, _ = installHeadroom(g, front, tc.name, pass, wpath, 8<<30, nil) }); r != nil {
			t.Errorf("%s cut: installHeadroom panicked (%v) -- it must fail open", tc.label, r)
			continue
		}
		if !fits {
			t.Errorf("%s cut: installHeadroom answered fits=false from a footprint it could not read -- it must "+
				"fail open and let the lease decide", tc.label)
		}
	}
}
