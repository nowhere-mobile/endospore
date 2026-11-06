package main

import (
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261107-07: a verified profile delete releases the vault's blobs on per-blob proofs (Q119, bounded
// 2026-10-21). test-delete-release.sh re-runs this file against copies of delete_release.go and main.go with each
// guard broken in turn.

// delRelGateway answers POST /release, recording each request's release map; status gives every reply's code.
func delRelGateway(t *testing.T, status int) (string, *[]map[string]string) {
	t.Helper()
	var mu sync.Mutex
	var bodies []map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.Method != "POST" || r.URL.Path != "/release" {
			http.Error(w, "no", http.StatusNotFound)
			return
		}
		raw, _ := io.ReadAll(r.Body)
		var in struct {
			Release map[string]string `json:"release"`
		}
		if json.Unmarshal(raw, &in) != nil || in.Release == nil {
			http.Error(w, "bad", http.StatusBadRequest)
			return
		}
		bodies = append(bodies, in.Release)
		if status != http.StatusOK {
			http.Error(w, `{"error":"nope"}`, status)
			return
		}
		out := []string{}
		for k := range in.Release {
			out = append(out, k)
		}
		sort.Strings(out)
		json.NewEncoder(w).Encode(map[string]any{"released": out})
	}))
	t.Cleanup(srv.Close)
	return srv.URL, &bodies
}

// delRelEnv points the process at a cap-mode gateway with a worker blob cache directory and returns the directory.
func delRelEnv(t *testing.T, gw string) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("GATEWAY_URL", gw)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("S3_ENDPOINT", "")
	t.Setenv("S3_BUCKET", "")
	t.Setenv("NOWHERE_MULTIDEVICE", "")
	t.Setenv("NOWHERE_BLOBCACHE", dir)
	blobCacheMu.Lock()
	saved := blobCache
	blobCache = nil
	blobCacheMu.Unlock()
	t.Cleanup(func() { blobCacheMu.Lock(); blobCache = saved; blobCacheMu.Unlock() })
	return dir
}

type delRelFixture struct {
	base string
	dk   []byte
	v    *vault
	set  []string
}

// delRelVault stores a live manifest and two kept versions, one chunk shared between two of them, plus a History
// entry with no manifest.
func delRelVault(t *testing.T, tag string, key byte) delRelFixture {
	t.Helper()
	base := newHTTPStore(t)
	dk := snapRelDK(key)
	c := func(s string) string { return snapRelHex("delrel-" + tag + "-" + s) }
	m0 := snapRelManifest(t, base, dk, []string{c("live"), c("shared")}, []string{c("dlive")})
	m1 := snapRelManifest(t, base, dk, []string{c("h1"), c("shared")}, []string{c("dh1")})
	m2 := snapRelManifest(t, base, dk, []string{c("h2")}, nil)
	v := &vault{Manifest: m0, History: []headSnap{{Version: 3, Manifest: m1}, {Version: 2}, {Version: 1, Manifest: m2}}}
	want := snapRelBlobs(m0, m1, m2, c("live"), c("shared"), c("dlive"), c("h1"), c("dh1"), c("h2"))
	return delRelFixture{base, dk, v, want}
}

func TestDeleteReleaseSetIsEveryVersionsBlobs(t *testing.T) {
	f := delRelVault(t, "r1", 41)
	got, err := deleteReleaseSet(f.base, f.dk, f.v)
	if err != nil {
		t.Fatal(err)
	}
	if g := snapRelKeys(got); !reflect.DeepEqual(g, f.set) {
		t.Errorf("release set\n got %v\nwant %v", g, f.set)
	}
}

func TestDeleteReleaseSetReleasesNothingWhenAVersionIsUnreadable(t *testing.T) {
	f := delRelVault(t, "r2", 43)
	missing := snapRelHex("delrel-r2-missing")
	live := f.v.Manifest
	hist := f.v.History
	cases := map[string]*vault{
		"middle": {Manifest: live, History: []headSnap{hist[0], {Version: 9, Manifest: missing}, hist[2]}},
		"last":   {Manifest: live, History: []headSnap{hist[0], hist[2], {Version: 9, Manifest: missing}}},
		"live":   {Manifest: missing, History: hist},
	}
	for name, v := range cases {
		got, err := deleteReleaseSet(f.base, f.dk, v)
		if got != nil || err == nil {
			t.Errorf("%s: got %v, %v; want nil and an error", name, snapRelKeys(got), err)
		}
	}
}

// delRelAckOnlyStore is newHTTPStore with one thing changed: a PUT to a ref skip names is acknowledged and not
// written, as a store that refuses a write without saying so.
func delRelAckOnlyStore(t *testing.T, skip func(ref string) bool) string {
	t.Helper()
	var mu sync.Mutex
	blobs := map[string][]byte{}
	refs := map[string]string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch {
		case r.Method == "POST" && r.URL.Path == "/blob":
			body, _ := io.ReadAll(r.Body)
			key := snapRelHex(string(body))
			blobs[key] = body
			io.WriteString(w, key)
		case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/blob/"):
			if b, ok := blobs[strings.TrimPrefix(r.URL.Path, "/blob/")]; ok {
				w.Write(b)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/ref/"):
			ref := strings.TrimPrefix(r.URL.Path, "/ref/")
			body, _ := io.ReadAll(r.Body)
			if !skip(ref) {
				refs[ref] = string(body)
			}
		case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/ref/"):
			if v, ok := refs[strings.TrimPrefix(r.URL.Path, "/ref/")]; ok {
				io.WriteString(w, v)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	t.Cleanup(func() { capBracketLeakCheck(t) })
	return srv.URL
}

type delRelCall struct {
	dkSet bool
	v     *vault
}

func TestDeleteReleaseCalledOnlyOnAVerifiedDelete(t *testing.T) {
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")
	var calls []delRelCall
	saved := releaseDeletedProfileFn
	releaseDeletedProfileFn = func(base string, dk []byte, v *vault, _ []deletedScopeHead) {
		calls = append(calls, delRelCall{dk != nil, v})
	}
	t.Cleanup(func() { releaseDeletedProfileFn = saved })

	base := newHTTPStore(t)
	name, pass := "delrel-r3", "delrel r3 passphrase"
	createVault(base, name, pass)
	before, ok := parseVault(getBlob(base, getRef(base, headKey(base, name, pass))))
	if !ok {
		t.Fatal("setup: no vault head")
	}
	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("delete = %q, want deleted", got)
	}
	if len(calls) != 1 || !calls[0].dkSet || calls[0].v == nil || calls[0].v.Manifest != before.Manifest {
		t.Fatalf("after a verified delete the release saw %+v, want one call with the vault's own manifest", calls)
	}
	if got := deleteProfile(base, name, pass); got != "gone" {
		t.Fatalf("second delete = %q, want gone", got)
	}
	if len(calls) != 1 {
		t.Errorf("a delete answering gone released: %d calls", len(calls))
	}

	other := "delrel-r3-other"
	createVault(base, other, pass)
	if got := deleteProfile(base, other, "wrong passphrase"); got != "notfound" {
		t.Fatalf("wrong passphrase = %q, want notfound", got)
	}
	if len(calls) != 1 {
		t.Errorf("a delete answering notfound released: %d calls", len(calls))
	}

	// A store that acknowledges the purge of a scope ref and keeps it: unverified, nothing released.
	var armed atomic.Bool
	n3, p3 := "delrel-r3-unverified", "delrel r3 unverified pass"
	stuck := profileRefV2(n3+"#de", p3)
	ub := delRelAckOnlyStore(t, func(ref string) bool { return armed.Load() && ref == stuck })
	createVault(ub, n3, p3)
	putRef(ub, stuck, "head-de")
	armed.Store(true)
	if got := deleteProfile(ub, n3, p3); got != "unverified" {
		t.Fatalf("stuck scope ref = %q, want unverified", got)
	}
	if len(calls) != 1 {
		t.Errorf("an unverified delete released: %d calls", len(calls))
	}
}

func TestDeleteReleaseSendsExactlyTheSetsProofs(t *testing.T) {
	f := delRelVault(t, "r4", 42)
	gw, bodies := delRelGateway(t, http.StatusOK)
	dir := delRelEnv(t, gw)
	other1, other2 := snapRelHex("delrel-r4-other-1"), snapRelHex("delrel-r4-other-2")
	lines := []string{other1}
	for _, k := range f.set {
		lines = append(lines, strings.TrimPrefix(k, "blob/"))
	}
	lines = append(lines, other2)
	cache := workerBlobCachePath()
	if filepath.Dir(cache) != dir {
		t.Fatalf("worker cache %q is not under %q", cache, dir)
	}
	if err := os.WriteFile(cache, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	out := snapRelStderr(t, func() { releaseDeletedProfile(f.base, f.dk, f.v, nil) })
	if len(*bodies) != 1 {
		t.Fatalf("%d release requests, want 1", len(*bodies))
	}
	req := (*bodies)[0]
	var keys []string
	for k, p := range req {
		keys = append(keys, k)
		if want := hex.EncodeToString(blobReleaseProof(f.dk, k)); p != want {
			t.Errorf("proof for a released key is not the key's own proof")
		}
	}
	sort.Strings(keys)
	if !reflect.DeepEqual(keys, f.set) {
		t.Errorf("request keys\n got %v\nwant %v", keys, f.set)
	}
	raw, _ := os.ReadFile(cache)
	if got, want := string(raw), other1+"\n"+other2+"\n"; got != want {
		t.Errorf("cache file after the release\n got %q\nwant %q", got, want)
	}
	if !strings.Contains(out, "released for the next collection") {
		t.Errorf("no release line in %q", out)
	}
}

func TestDeleteReleaseSkipsWithoutAGatewayOrWithMultiDevice(t *testing.T) {
	f := delRelVault(t, "r5", 44)
	gw, bodies := delRelGateway(t, http.StatusOK)
	delRelEnv(t, gw)

	t.Setenv("S3_ACCESS_KEY", "direct-mode-test-value")
	out := snapRelStderr(t, func() { releaseDeletedProfile(f.base, f.dk, f.v, nil) })
	if len(*bodies) != 0 || !strings.Contains(out, "nothing released early -- this store has no gateway") {
		t.Errorf("direct mode: %d requests, output %q", len(*bodies), out)
	}
	t.Setenv("S3_ACCESS_KEY", "")

	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	releaseDeletedProfile(f.base, f.dk, f.v, nil)
	if len(*bodies) != 0 {
		t.Errorf("multi-device sent %d requests", len(*bodies))
	}
	t.Setenv("NOWHERE_MULTIDEVICE", "")

	releaseDeletedProfile(f.base, nil, f.v, nil)
	releaseDeletedProfile(f.base, f.dk, nil, nil)
	releaseDeletedProfile(f.base, f.dk, &vault{}, nil)
	if len(*bodies) != 0 {
		t.Errorf("a nil key, a nil vault or an empty vault sent %d requests", len(*bodies))
	}
}

func TestDeleteReleaseLogsNoSecret(t *testing.T) {
	f := delRelVault(t, "r6", 45)
	name, pass := "delrel-r6-profile-name", "delrel r6 passphrase"
	secrets := []string{name, pass}
	for _, k := range f.set {
		secrets = append(secrets, k, strings.TrimPrefix(k, "blob/"),
			hex.EncodeToString(blobReleaseProof(f.dk, k)), blobReleaseCommit(f.dk, k))
	}
	check := func(label, out string) {
		t.Helper()
		if !strings.Contains(out, "[agent] delete:") {
			t.Errorf("%s: no delete line in %q", label, out)
		}
		for _, s := range secrets {
			if strings.Contains(out, s) {
				t.Errorf("%s: the output carries a secret: %q", label, s)
			}
		}
	}
	for label, status := range map[string]int{"ok": 200, "500": 500, "404": 404} {
		gw, _ := delRelGateway(t, status)
		delRelEnv(t, gw)
		check(label, snapRelStderr(t, func() { releaseDeletedProfile(f.base, f.dk, f.v, nil) }))
	}
	gw, _ := delRelGateway(t, 200)
	delRelEnv(t, gw)
	missing := &vault{Manifest: snapRelHex("delrel-r6-missing")}
	check("unreadable", snapRelStderr(t, func() { releaseDeletedProfile(f.base, f.dk, missing, nil) }))

	// The real function inside a real delete, so the profile name is in scope of the caller.
	base := newHTTPStore(t)
	createVault(base, name, pass)
	out := snapRelStderr(t, func() {
		if got := deleteProfile(base, name, pass); got != "deleted" {
			t.Errorf("delete = %q, want deleted", got)
		}
	})
	check("deleteProfile", out)
}

// A gateway that holds POST /release open costs the delete at most deleteReleaseWait: releaseDeletedProfile returns
// with one keyless line and deleteProfile still answers "deleted". Waited on inline, each call would sit out the
// client's own deadline, leaseBudget(n), over 30 s. The handler is held until a cleanup that runs before srv.Close
// (cleanups run last-registered first), so the abandoned releases end with the test.
func TestDeleteReleaseWaitIsBounded(t *testing.T) {
	unblock := make(chan struct{})
	arrived := make(chan struct{}, 8)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" && r.URL.Path == "/release" {
			select {
			case arrived <- struct{}{}:
			default:
			}
			<-unblock
		}
		http.Error(w, "no", http.StatusNotFound)
	}))
	t.Cleanup(srv.Close)
	t.Cleanup(func() { close(unblock) })
	delRelEnv(t, srv.URL)
	savedWait := deleteReleaseWait
	deleteReleaseWait = 200 * time.Millisecond
	t.Cleanup(func() { deleteReleaseWait = savedWait })
	f := delRelVault(t, "r7", 46)
	reached := func(what string) {
		t.Helper()
		select {
		case <-arrived:
		case <-time.After(5 * time.Second):
			t.Fatalf("%s: the release never reached the gateway", what)
		}
	}
	const line = "[agent] delete: the gateway is still taking the release -- not waiting\n"

	start := time.Now()
	out := snapRelStderr(t, func() { releaseDeletedProfile(f.base, f.dk, f.v, nil) })
	if d := time.Since(start); d > 5*time.Second {
		t.Fatalf("releaseDeletedProfile waited %v on a gateway that does not answer", d)
	}
	reached("releaseDeletedProfile")
	if out != line {
		t.Errorf("output %q, want only the not-waiting line", out)
	}

	// The delete's release is pointed at the fixture's vault, so the not-waiting path runs on a set this test
	// controls: the real function, called by the real delete.
	savedFn := releaseDeletedProfileFn
	releaseDeletedProfileFn = func(string, []byte, *vault, []deletedScopeHead) { releaseDeletedProfile(f.base, f.dk, f.v, nil) }
	t.Cleanup(func() { releaseDeletedProfileFn = savedFn })
	base := newHTTPStore(t)
	name, pass := "delrel-r7", "delrel r7 passphrase"
	createVault(base, name, pass)
	var got string
	start = time.Now()
	out = snapRelStderr(t, func() { got = deleteProfile(base, name, pass) })
	if d := time.Since(start); d > 20*time.Second {
		t.Errorf("deleteProfile took %v with the release held", d)
	}
	if got != "deleted" {
		t.Errorf("delete = %q, want deleted", got)
	}
	reached("deleteProfile")
	if !strings.Contains(out, line) {
		t.Errorf("no not-waiting line from the delete in %q", out)
	}
}

// NWP-20261117-13: the scope heads go too, each under the key its own seal leased with, read before the purge.

// delRelScopeHead seals a CDC manifest naming chunks under key, publishes it as the v2 head of name+suf and returns
// the manifest's hash.
func delRelScopeHead(t *testing.T, base, name, pass, suf string, key []byte, chunks []string) string {
	t.Helper()
	m := snapRelManifest(t, base, key, chunks, nil)
	putRef(base, profileRefV2(name+suf, pass), m)
	return m
}

// delRelScopeVault publishes a scope vault signed under key, its live manifest m and one History entry hist, as the
// v2 head of name+suf, and returns the head blob's hash.
func delRelScopeVault(t *testing.T, base, name, pass, suf string, key []byte, m, hist string) string {
	t.Helper()
	sv := buildScopeVault(key, name+suf, pass, m)
	sv.History = []headSnap{{Version: 1, Manifest: hist}}
	signVault(sv, key)
	h := postBlob(base, serializeVault(sv))
	putRef(base, profileRefV2(name+suf, pass), h)
	return h
}

// delRelProfile creates a real vault with a #de head under its derived key and a #wallet head sealed under the DK.
// It returns the DK, the #de set and the wallet blob's hash.
func delRelProfile(t *testing.T, base, name, pass string) ([]byte, []string, string) {
	t.Helper()
	createVault(base, name, pass)
	v, ok := parseVault(getBlob(base, getRef(base, headKey(base, name, pass))))
	if !ok {
		t.Fatal("setup: no vault head")
	}
	dk := openVaultDK(v, name, pass)
	if dk == nil {
		t.Fatal("setup: the vault does not open")
	}
	c1, c2 := snapRelHex(name+"-de-1"), snapRelHex(name+"-de-2")
	de := delRelScopeHead(t, base, name, pass, "#de", deriveKey(name+"#de", pass), []string{c1, c2})
	w := postBlob(base, seal(dk, []byte("delrel wallet of "+name)))
	putRef(base, profileRefV2(name+"#wallet", pass), w)
	return dk, snapRelBlobs(de, c1, c2), w
}

// S1: the capture reads exactly the scope heads that exist, with each scope's derived key.
func TestDeleteReleaseCapturesTheScopeHeads(t *testing.T) {
	t.Setenv("NOWHERE_MULTIDEVICE", "")
	base := newHTTPStore(t)
	name, pass := "delrel-s1", "delrel s1 passphrase"
	_, deSet, w := delRelProfile(t, base, name, pass)
	heads := deleteScopeHeads(base, name, pass)
	got := map[string]deletedScopeHead{}
	for _, h := range heads {
		got[h.suf] = h
	}
	if len(heads) != 2 || len(got) != 2 {
		t.Fatalf("captured %d head(s), want #de and #wallet only", len(heads))
	}
	de, ok := got["#de"]
	if !ok || ("blob/"+de.head != deSet[0] && "blob/"+de.head != deSet[1] && "blob/"+de.head != deSet[2]) {
		t.Errorf("#de not captured with its manifest")
	}
	if !reflect.DeepEqual(de.derived, deriveKey(name+"#de", pass)) {
		t.Errorf("#de captured without its derived key")
	}
	if wh, ok := got["#wallet"]; !ok || wh.head != w {
		t.Errorf("#wallet not captured with its blob")
	}
	if _, ok := got["#media"]; ok {
		t.Errorf("a never-sealed scope was captured")
	}
}

// delRelS2 is S2's fixture: a vault whose index wraps a random #apps key, and six scopes -- #de under its derived
// key, #wallet under the DK, #apps a scope vault only the index key opens, #sys a scope vault whose History names a
// missing manifest, #keys a blob no key opens, #media never sealed.
type delRelS2 struct {
	f       delRelFixture
	heads   []deletedScopeHead
	want    map[string][]byte // every key the request must carry, with the key its proof is under
	refused []string          // keys that must not be in the request
}

func delRelS2Setup(t *testing.T, tag string, kb byte) delRelS2 {
	t.Helper()
	f := delRelVault(t, tag, kb)
	n, p := "delrel-"+tag, "delrel "+tag+" passphrase"
	c := func(s string) string { return snapRelHex("delrel-" + tag + "-" + s) }
	kApps := snapRelDK(kb + 100)
	f.v.Scopes = sealScopeIndex(f.dk, map[string]scopeRec{"#apps": {Wrapped: wrap(kekScopes(f.dk), kApps)}})
	want := map[string][]byte{}
	for _, k := range f.set {
		want[k] = f.dk
	}
	kDe := deriveKey(n+"#de", p)
	de := delRelScopeHead(t, f.base, n, p, "#de", kDe, []string{c("de1"), c("de2")})
	for _, k := range snapRelBlobs(de, c("de1"), c("de2")) {
		want[k] = kDe
	}
	w := postBlob(f.base, seal(f.dk, []byte("delrel wallet "+tag)))
	putRef(f.base, profileRefV2(n+"#wallet", p), w)
	want["blob/"+w] = f.dk
	mA := snapRelManifest(t, f.base, kApps, []string{c("a1"), c("a2")}, nil)
	mAH := snapRelManifest(t, f.base, kApps, []string{c("ah")}, nil)
	hA := delRelScopeVault(t, f.base, n, p, "#apps", kApps, mA, mAH)
	for _, k := range snapRelBlobs(mA, mAH, c("a1"), c("a2"), c("ah")) {
		want[k] = kApps
	}
	kSys := deriveKey(n+"#sys", p)
	mS := snapRelManifest(t, f.base, kSys, []string{c("s1")}, nil)
	hS := delRelScopeVault(t, f.base, n, p, "#sys", kSys, mS, c("sys-missing"))
	kk := postBlob(f.base, seal(snapRelDK(kb+101), []byte("delrel keys "+tag)))
	putRef(f.base, profileRefV2(n+"#keys", p), kk)
	refused := snapRelBlobs(hA, hS, mS, c("s1"), kk)
	heads := deleteScopeHeads(f.base, n, p)
	if len(heads) != 5 {
		t.Fatalf("setup: captured %d head(s), want 5", len(heads))
	}
	return delRelS2{f, heads, want, refused}
}

// S2: each scope's blobs carry the proof under the key its seal leased with; a head no key opens and one whose set
// cannot be read whole are left out and counted, and the rest still go.
func TestDeleteReleaseScopeKeys(t *testing.T) {
	s := delRelS2Setup(t, "s2", 51)
	gw, bodies := delRelGateway(t, http.StatusOK)
	delRelEnv(t, gw)
	out := snapRelStderr(t, func() { releaseDeletedProfile(s.f.base, s.f.dk, s.f.v, s.heads) })
	if len(*bodies) != 1 {
		t.Fatalf("%d release requests, want 1; output %q", len(*bodies), out)
	}
	req := (*bodies)[0]
	for k, key := range s.want {
		p, ok := req[k]
		if !ok {
			t.Errorf("the request lacks a blob it must release")
			continue
		}
		if p != hex.EncodeToString(blobReleaseProof(key, k)) {
			t.Errorf("a blob's proof is not under the key its seal leased with")
		}
	}
	for _, k := range s.refused {
		if _, ok := req[k]; ok {
			t.Errorf("the request names a blob that must keep its lease schedule")
		}
	}
	if len(req) != len(s.want) {
		t.Errorf("the request carries %d key(s), want %d", len(req), len(s.want))
	}
	for _, line := range []string{"2 scope head(s) left on their lease schedule", "3 scope head(s) sent with it"} {
		if !strings.Contains(out, line) {
			t.Errorf("no %q in %q", line, out)
		}
	}
}

// S2b: in cap mode on S3 the capture costs one ref read for a v2 head and two for a scope that has none.
func TestDeleteReleaseCaptureReadCount(t *testing.T) {
	srv, objs, omu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_MULTIDEVICE", "")
	capReadCache = map[string]capEntry{}
	n, p := "delrel-count", "delrel count passphrase"
	deHead := snapRelHex("delrel-count-de")
	omu.Lock()
	objs["ref/"+profileRefV2(n+"#de", p)] = []byte(deHead)
	omu.Unlock()
	var mu sync.Mutex
	reads := 0
	capStoreGetSeen = func(k string) {
		mu.Lock()
		defer mu.Unlock()
		if strings.HasPrefix(k, "ref/") {
			reads++
		}
	}
	count := func() int { mu.Lock(); defer mu.Unlock(); r := reads; reads = 0; return r }
	getRef("s3", profileRefV2(n+"#de", p))
	getRef("s3", profileRefV2(n+"#de", p))
	if got := count(); got != 2 {
		t.Fatalf("control: two direct ref reads counted %d", got)
	}
	heads := deleteScopeHeads("s3", n, p)
	if len(heads) != 1 || heads[0].suf != "#de" || heads[0].head != deHead {
		t.Errorf("captured %d head(s), want #de alone", len(heads))
	}
	if got := count(); got != 11 {
		t.Errorf("the capture made %d ref read(s), want 11 (1 for the v2 head, 2 for each of five absent scopes)", got)
	}
}

// S3: one request carries exactly the vault's set plus the scopes' sets, each with its own proof, and the cache
// file loses exactly those lines.
func TestDeleteReleaseOneRequestForVaultAndScopes(t *testing.T) {
	gw, bodies := delRelGateway(t, http.StatusOK)
	dir := delRelEnv(t, gw)
	base := newHTTPStore(t)
	name, pass := "delrel-s3", "delrel s3 passphrase"
	dk, deSet, w := delRelProfile(t, base, name, pass)
	v, ok := parseVault(getBlob(base, getRef(base, headKey(base, name, pass))))
	if !ok {
		t.Fatal("setup: no vault head")
	}
	vset, err := deleteReleaseSet(base, dk, v)
	if err != nil || len(vset) == 0 {
		t.Fatalf("setup: vault set %v, %v", vset, err)
	}
	heads := deleteScopeHeads(base, name, pass)
	want := map[string][]byte{"blob/" + w: dk}
	for k := range vset {
		want[k] = dk
	}
	kDe := deriveKey(name+"#de", pass)
	for _, k := range deSet {
		want[k] = kDe
	}
	other1, other2 := snapRelHex("delrel-s3-other-1"), snapRelHex("delrel-s3-other-2")
	lines := []string{other1}
	for k := range want {
		lines = append(lines, strings.TrimPrefix(k, "blob/"))
	}
	lines = append(lines, other2)
	cache := workerBlobCachePath()
	if filepath.Dir(cache) != dir {
		t.Fatalf("worker cache %q is not under %q", cache, dir)
	}
	if err := os.WriteFile(cache, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	snapRelStderr(t, func() { releaseDeletedProfile(base, dk, v, heads) })
	if len(*bodies) != 1 {
		t.Fatalf("%d release requests, want 1", len(*bodies))
	}
	req := (*bodies)[0]
	var keys, wantKeys []string
	for k, p := range req {
		keys = append(keys, k)
		if key, ok := want[k]; !ok || p != hex.EncodeToString(blobReleaseProof(key, k)) {
			t.Errorf("a released key's proof is not under the key its seal leased with")
		}
	}
	for k := range want {
		wantKeys = append(wantKeys, k)
	}
	sort.Strings(keys)
	sort.Strings(wantKeys)
	if !reflect.DeepEqual(keys, wantKeys) {
		t.Errorf("request keys\n got %v\nwant %v", keys, wantKeys)
	}
	raw, _ := os.ReadFile(cache)
	if got, want := string(raw), other1+"\n"+other2+"\n"; got != want {
		t.Errorf("cache file after the release\n got %q\nwant %q", got, want)
	}
}

// S4: deleteProfile hands the release the heads it read before the purge, and only on "deleted".
func TestDeleteReleaseHandsOverTheHeadsReadBeforeThePurge(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "delrel-s4", "delrel s4 passphrase"
	_, deSet, w := delRelProfile(t, base, name, pass)
	other := "delrel-s4-other"
	createVault(base, other, pass)
	n3, p3 := "delrel-s4-unverified", "delrel s4 unverified pass"
	var armed atomic.Bool
	stuck := profileRefV2(n3+"#de", p3)
	ub := delRelAckOnlyStore(t, func(ref string) bool { return armed.Load() && ref == stuck })
	createVault(ub, n3, p3)
	putRef(ub, stuck, snapRelHex("delrel-s4-stuck"))
	gw, _ := delRelGateway(t, http.StatusOK)
	delRelEnv(t, gw)

	var calls [][]deletedScopeHead
	saved := releaseDeletedProfileFn
	releaseDeletedProfileFn = func(_ string, _ []byte, _ *vault, heads []deletedScopeHead) {
		calls = append(calls, append([]deletedScopeHead(nil), heads...))
	}
	t.Cleanup(func() { releaseDeletedProfileFn = saved })

	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("delete = %q, want deleted", got)
	}
	if len(calls) != 1 {
		t.Fatalf("%d release call(s), want 1", len(calls))
	}
	got := map[string]string{}
	for _, h := range calls[0] {
		got[h.suf] = h.head
	}
	deHead := ""
	for _, k := range deSet {
		if got["#de"] == strings.TrimPrefix(k, "blob/") {
			deHead = got["#de"]
		}
	}
	if len(got) != 2 || deHead == "" || got["#wallet"] != w {
		t.Errorf("the release was handed %d head(s), want #de and #wallet as they were before the purge", len(calls[0]))
	}
	if got := deleteProfile(base, name, pass); got != "gone" {
		t.Fatalf("second delete = %q, want gone", got)
	}
	if got := deleteProfile(base, other, "wrong passphrase"); got != "notfound" {
		t.Fatalf("wrong passphrase = %q, want notfound", got)
	}
	armed.Store(true)
	if got := deleteProfile(ub, n3, p3); got != "unverified" {
		t.Fatalf("stuck scope ref = %q, want unverified", got)
	}
	if len(calls) != 1 {
		t.Errorf("gone, notfound or unverified called the release: %d calls", len(calls))
	}
}

// S5: the release's lines and a real delete's carry no profile name, suffix, blob key or proof.
func TestDeleteReleaseScopeLinesLogNoSecret(t *testing.T) {
	s := delRelS2Setup(t, "s5", 61)
	gw, bodies := delRelGateway(t, http.StatusOK)
	delRelEnv(t, gw)
	secrets := []string{"delrel-s5", "delrel s5 passphrase"}
	secrets = append(secrets, scopeIndexSuffixes...)
	add := func(k string, key []byte) {
		secrets = append(secrets, k, strings.TrimPrefix(k, "blob/"),
			hex.EncodeToString(blobReleaseProof(key, k)), blobReleaseCommit(key, k))
	}
	for k, key := range s.want {
		add(k, key)
	}
	for _, k := range s.refused {
		add(k, s.f.dk)
	}
	check := func(label, out string) {
		t.Helper()
		if !strings.Contains(out, "[agent] delete:") {
			t.Errorf("%s: no delete line in %q", label, out)
		}
		for _, sec := range secrets {
			if strings.Contains(out, sec) {
				t.Errorf("%s: the output carries a secret: %q", label, sec)
			}
		}
	}
	check("release", snapRelStderr(t, func() { releaseDeletedProfile(s.f.base, s.f.dk, s.f.v, s.heads) }))

	base := newHTTPStore(t)
	name, pass := "delrel-s5-profile-name", "delrel s5 real passphrase"
	dk, deSet, w := delRelProfile(t, base, name, pass)
	secrets = append(secrets, name, pass)
	kDe := deriveKey(name+"#de", pass)
	for _, k := range deSet {
		add(k, kDe)
	}
	add("blob/"+w, dk)
	n := len(*bodies)
	out := snapRelStderr(t, func() {
		if got := deleteProfile(base, name, pass); got != "deleted" {
			t.Errorf("delete = %q, want deleted", got)
		}
	})
	check("deleteProfile", out)
	if len(*bodies) != n+1 {
		t.Fatalf("the real delete sent %d request(s), want 1", len(*bodies)-n)
	}
	if _, ok := (*bodies)[n]["blob/"+w]; !ok {
		t.Errorf("the real delete did not send the wallet blob")
	}
}
