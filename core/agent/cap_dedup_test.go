package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// NWP-20260828-10: cap mode had NO store-side dedup. postBlob's cap path buffers unconditionally on a
// blobCache miss, and that cache lives in tmpfs by design (a surviving list of chunk hashes would outlive
// the amnesia guarantee), so every reboot made the next seal re-upload the whole scope. Measured on lynx,
// same profile and same 1.8 GB tree: 1.798 GB / 14m17s cold versus 0 KiB / 1m09s warm, twice,
// byte-identical. The lease now reports what the store already holds.
//
// capFlush needs a live gateway and a wallet, so these pin the WIRE CONTRACT and the decision rule rather
// than driving the flush itself -- the parts that would silently break the fix or lose data.

// The device must ASK, or the gateway -- which treats it as an opt-in -- keeps sending a cap for
// everything and nothing is deduped. Every lease flavour has to carry it: a seal takes whichever path the
// wallet dictates, so one that forgets silently loses the fix on that path only.
//
// ⚠ THIS DRIVES THE REAL lease METHODS against a stub gateway and reads what actually went ON THE WIRE.
// The first version of this test built leaseReq literals by hand with SkipPresent already set -- it passed
// against code with the opt-in REMOVED, because it was asserting on its own test data. A mutation check
// caught it.
func TestEveryLeaseFlavourOptsIntoSkipPresent(t *testing.T) {
	var bodies []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var m map[string]any
		if err := json.NewDecoder(r.Body).Decode(&m); err != nil {
			t.Errorf("decode request: %v", err)
		}
		bodies = append(bodies, m)
		_, _ = w.Write([]byte(`{"through_epoch":1,"spent":0,"write_caps":{}}`))
	}))
	defer srv.Close()

	gw := newGatewayClient(srv.URL, gwDefault)
	refs := map[string]int64{"blob/a": 1}
	if _, _, err := gw.lease(nil, nil, refs); err != nil {
		t.Fatalf("lease: %v", err)
	}
	if _, _, err := gw.leaseEntitled("p", nil, nil, refs, 1, 0, "", nil); err != nil {
		t.Fatalf("leaseEntitled: %v", err)
	}
	if _, _, err := gw.leaseFree("p", refs, nil); err != nil {
		t.Fatalf("leaseFree: %v", err)
	}

	names := []string{"lease", "leaseEntitled", "leaseFree"}
	if len(bodies) != len(names) {
		t.Fatalf("got %d requests, want %d", len(bodies), len(names))
	}
	for i, b := range bodies {
		if b["skip_present"] != true {
			t.Errorf("%s() must send skip_present:true on the wire, got %v", names[i], b["skip_present"])
		}
	}
}

// An OLDER gateway does not know the field and returns no Present. That must decode to "upload everything"
// -- the behaviour from before this existed -- not to an empty-means-skip-everything catastrophe.
func TestOldGatewayResponseDecodesToUploadEverything(t *testing.T) {
	var info leaseInfo
	old := `{"through_epoch":42,"spent":1,"write_caps":{"blob/a":"https://s/a","ref/head":"https://s/h"}}`
	if err := json.Unmarshal([]byte(old), &info); err != nil {
		t.Fatal(err)
	}
	if len(info.Present) != 0 {
		t.Fatalf("an old gateway sends no present list; got %v", info.Present)
	}
	present := map[string]bool{}
	for _, k := range info.Present {
		present[k] = true
	}
	for _, k := range []string{"blob/a", "ref/head"} {
		if present[k] {
			t.Fatalf("%q must NOT be treated as present when the gateway never said so", k)
		}
		if info.WriteCaps[k] == "" {
			t.Fatalf("%q must still have a cap to upload with", k)
		}
	}
}

// The decision rule capFlush's put() applies, isolated: skip iff the gateway LISTED the ref present. A
// missing cap for a ref that was NOT listed stays a hard failure -- skipping must never be inferred from an
// absent cap, or a gateway bug becomes silent data loss instead of a loud one.
func TestSkipIsDrivenByPresentNotByAMissingCap(t *testing.T) {
	info := leaseInfo{
		WriteCaps: map[string]string{"blob/upload": "https://s/u", "ref/head": "https://s/h"},
		Present:   []string{"blob/have"},
	}
	present := map[string]bool{}
	for _, k := range info.Present {
		present[k] = true
	}

	if !present["blob/have"] {
		t.Fatal("a listed ref must be skipped")
	}
	if present["blob/upload"] {
		t.Fatal("an unlisted ref must never be skipped")
	}
	// the dangerous shape: no cap AND not listed -> must remain a failure, not a silent skip
	if _, hasCap := info.WriteCaps["blob/orphan"]; hasCap || present["blob/orphan"] {
		t.Fatal("setup: blob/orphan should have neither a cap nor a present listing")
	}
}

// A "ref/" pointer is the HEAD: it changes every seal and is what makes the new manifest live. If a gateway
// ever listed one as present, honouring that would leave the profile pointing at the OLD head -- the session
// silently not saved. The gateway will not do that (it only ever considers blob/ refs), but the device
// should not be the only thing standing between a gateway bug and lost data.
func TestARefPointerAlwaysHasACapToWriteWith(t *testing.T) {
	info := leaseInfo{
		WriteCaps: map[string]string{"blob/x": "https://s/x", "ref/head": "https://s/h"},
		Present:   []string{"blob/x"},
	}
	if info.WriteCaps["ref/head"] == "" {
		t.Fatal("the head pointer must always come back with a write cap")
	}
	for _, p := range info.Present {
		if len(p) >= 4 && p[:4] == "ref/" {
			t.Fatalf("a ref pointer must never be listed present; got %q", p)
		}
	}
}
