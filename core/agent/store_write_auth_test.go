package main

// NWP-20261009-02: the client half of docs/store-write-authorization.md -- what the device sends so that the
// store itself can refuse a write that does not belong to it, and what it does with the answers.
//
// The gateway now signs `x-amz-checksum-sha256` and `If-None-Match: *` into a blob's write cap and returns
// them beside the URL; the device has to send exactly those headers and no Content-MD5 (R2 answers 400
// InvalidRequest to the pair, measured 2026-10-08), read a 412 on a blob as "already there", fail a 400
// BadDigest without retrying, and re-mint a 403'd bound cap through POST /cap as the profile that holds the
// lease. A credential change names the key it moves off as `prior`, and records it so later leases keep
// naming it until payRent's full-footprint lease has re-tagged every row. Every test here drives the real
// client code against a fake gateway/store and asserts what went on the wire.

import (
	"crypto/md5"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// Hooks mockCapStore (cap_test.go) consults, all reset for every store it builds.
var (
	capStorePutSeen     func(key string, hdr http.Header)                        // every PUT's headers, as received
	capStorePutStatus   func(key string, hdr http.Header) (int, string)          // non-zero: answer the PUT with this status + body
	capStoreLeaseSeen   func(req leaseReq)                                       // every /lease body, as decoded
	capStoreCapHeaders  func(ref string) map[string]string                       // cap_headers to return for a ref on a bound_caps lease
	capStorePostCap     func(req capBoundReq, objURL string) (int, capBoundResp) // POST /cap; nil = 405, today's gateway
	capStoreLeaseStatus func(req leaseReq) (int, string)                         // a test's verdict: 0 default, 200 grant, else the reply
)

// priorShapeOK is the gateway's `prior` rule (docs/store-write-authorization.md §4): at most 8 keys, each 64
// hex, none equal to the profile the request is made as. mockCapStore applies it to every /lease and POST /cap.
func priorShapeOK(profile string, prior []string) bool {
	if len(prior) > billRetagMax {
		return false
	}
	for _, k := range prior {
		if !isContentHash(k) || k == profile {
			return false
		}
	}
	return true
}

// holderLedger is the strict gateway's ownership rule in miniature: a tag per leased key. A REF row changes hands
// only to itself, from untagged, or to a request naming its tag in `prior` -- anything else refuses the WHOLE lease
// 403 before a single row moves (R2). A BLOB row held by another profile is extended, never refused, and re-tagged
// only with a matching prior (R2b). POST /cap answers only the holder, or a request naming the holder as prior.
type holderLedger struct {
	mu     sync.Mutex
	tags   map[string]string
	retags int // rows that changed hands from one profile to another
}

func installHolderLedger() *holderLedger {
	l := &holderLedger{tags: map[string]string{}}
	capStoreLeaseStatus = l.lease
	capStorePostCap = l.postCap
	return l
}

func (l *holderLedger) may(tag, profile string, prior []string) bool {
	return tag == "" || tag == profile || containsString(prior, tag)
}

func (l *holderLedger) lease(req leaseReq) (int, string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for ref := range req.Refs {
		if !strings.HasPrefix(ref, "blob/") && !l.may(l.tags[ref], req.Profile, req.Prior) {
			return http.StatusForbidden, `{"error":"held by another profile"}`
		}
	}
	for ref := range req.Refs {
		tag := l.tags[ref]
		if l.may(tag, req.Profile, req.Prior) {
			if tag != "" && tag != req.Profile {
				l.retags++
			}
			l.tags[ref] = req.Profile
		}
	}
	return 0, ""
}

func (l *holderLedger) postCap(req capBoundReq, objURL string) (int, capBoundResp) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.may(l.tags[req.Ref], req.Profile, req.Prior) {
		return http.StatusForbidden, capBoundResp{}
	}
	return http.StatusOK, capBoundResp{URL: objURL}
}

func (l *holderLedger) tag(ref string) string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.tags[ref]
}

func (l *holderLedger) retagCount() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.retags
}

// ledgerFixture is capFixture with a holder ledger installed.
func ledgerFixture(t *testing.T) *holderLedger {
	t.Helper()
	capFixture(t)
	return installHolderLedger()
}

// capFixture is cap mode against mockCapStore with an empty wallet (the free arm) and a private NOWHERE_STATE.
func capFixture(t *testing.T) {
	t.Helper()
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	t.Setenv("NOWHERE_STATE", t.TempDir())
	blobCache = nil
	freeRenewedThrough = map[string]int64{}
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
}

// sealBare seals the bare profile in cap mode and reports whether it failed (a refused lease panics capFlush).
func sealBare(t *testing.T, name, pass, payload string) (failed bool) {
	t.Helper()
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte(payload), 0o600); err != nil {
		t.Fatal(err)
	}
	return didPanic(func() { pushProfile("s3", name, pass, d) })
}

const sigMismatchBody = `<?xml version="1.0" encoding="UTF-8"?><Error><Code>SignatureDoesNotMatch</Code></Error>`
const badDigestBody = `<?xml version="1.0" encoding="UTF-8"?><Error><Code>BadDigest</Code><Message>The Content-SHA256 you specified did not match what we received.</Message></Error>`

// boundHeadersFor is what the gateway signs into a blob cap: the key's hash, base64 of the raw bytes, and the
// create-only condition (docs/store-write-authorization.md R1).
func boundHeadersFor(t *testing.T, key string) map[string]string {
	t.Helper()
	raw, err := hex.DecodeString(strings.TrimPrefix(key, "blob/"))
	if err != nil || len(raw) != 32 {
		t.Fatalf("not a blob key: %q", key)
	}
	return map[string]string{"x-amz-checksum-sha256": base64.StdEncoding.EncodeToString(raw), "If-None-Match": "*"}
}

// headerStore serves PUTs, records each request's headers in arrival order, and answers via status.
func headerStore(t *testing.T, status func(n int, r *http.Request) (int, string)) (*httptest.Server, *[]http.Header) {
	t.Helper()
	var mu sync.Mutex
	var seen []http.Header
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		seen = append(seen, r.Header.Clone())
		n := len(seen)
		mu.Unlock()
		if code, b := status(n, r); code != 0 {
			w.WriteHeader(code)
			_, _ = io.WriteString(w, b)
			return
		}
		sum := md5.Sum(body)
		w.Header().Set("ETag", `"`+hex.EncodeToString(sum[:])+`"`)
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	return srv, &seen
}

func hasAmzHeader(h http.Header) bool {
	for k := range h {
		if strings.HasPrefix(strings.ToLower(k), "x-amz-") {
			return true
		}
	}
	return false
}

// (a) A bound cap: the PUT carries exactly the signed headers and NO Content-MD5.
func TestCapPut_BoundCapSendsTheSignedHeadersAndNoContentMD5(t *testing.T) {
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	body := []byte("a chunk that hashes to its key")
	key := "blob/" + hexSHA256(body)
	hdrs := boundHeadersFor(t, key)
	srv, seen := headerStore(t, func(int, *http.Request) (int, string) { return 0, "" })

	capPut(key, srv.URL+"/o", hdrs, body, nil)

	if len(*seen) != 1 {
		t.Fatalf("%d PUT(s), want 1", len(*seen))
	}
	got := (*seen)[0]
	for k, v := range hdrs {
		if got.Get(k) != v {
			t.Errorf("header %s = %q, want %q -- it is signed into the URL, so anything else is a 403 from the store", k, got.Get(k), v)
		}
	}
	if got.Get("Content-MD5") != "" {
		t.Error("a bound PUT carried Content-MD5 beside the signed checksum: R2 answers 400 InvalidRequest to the pair (measured 2026-10-08)")
	}
}

// (b) No headers from the gateway (a pointer, or an older gateway): today's request, byte for byte --
// Content-MD5 and nothing of the new shape.
func TestCapPut_PlainCapStillSendsContentMD5AndNothingElse(t *testing.T) {
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	body := []byte("pointer bytes")
	srv, seen := headerStore(t, func(int, *http.Request) (int, string) { return 0, "" })

	capPut("ref/abc", srv.URL+"/o", nil, body, nil)

	if len(*seen) != 1 {
		t.Fatalf("%d PUT(s), want 1", len(*seen))
	}
	got := (*seen)[0]
	sum := md5.Sum(body)
	if got.Get("Content-MD5") != base64.StdEncoding.EncodeToString(sum[:]) {
		t.Errorf("Content-MD5 = %q, want the body's md5 -- a plain cap must be sent exactly as before this slice", got.Get("Content-MD5"))
	}
	if hasAmzHeader(got) || got.Get("If-None-Match") != "" {
		t.Errorf("a plain cap PUT carried a binding header: %v -- an unsigned x-amz-* header is itself a 403 on R2", got)
	}
}

// (c) 412 on a blob is success (create-only key exists: content-addressed, the bytes are there); 412 on a
// pointer is a failure, and a deterministic one -- no retries.
func TestCapPut_412IsSuccessOnABlobAndFailureOnAPointer(t *testing.T) {
	fastRetries(t)
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	body := []byte("already stored")
	key := "blob/" + hexSHA256(body)
	srv, seen := headerStore(t, func(int, *http.Request) (int, string) {
		return http.StatusPreconditionFailed, `<Error><Code>PreconditionFailed</Code></Error>`
	})

	if failed := didPanic(func() { capPut(key, srv.URL+"/o", boundHeadersFor(t, key), body, nil) }); failed {
		t.Fatal("a 412 on a BLOB failed the write. The cap is create-only and the key exists, so the store holds " +
			"exactly these bytes; failing here is five retries and a dead seal for a blob that is already there.")
	}
	if len(*seen) != 1 {
		t.Errorf("a 412 on a blob was retried: %d PUT(s), want 1", len(*seen))
	}

	*seen = nil
	if failed := didPanic(func() { capPut("ref/head", srv.URL+"/o", nil, []byte("h"), nil) }); !failed {
		t.Fatal("a 412 on a POINTER was reported as success. No pointer cap is create-only -- heads are overwritten " +
			"by every seal -- so a 412 there means the head was NOT written.")
	}
	if len(*seen) != 1 {
		t.Errorf("a 412 on a pointer was retried %d time(s); the store's answer is deterministic", len(*seen))
	}
}

// (d) 400 BadDigest: the bytes do not hash to the key the cap was signed for. Loud, once, no re-mint.
func TestCapPut_BadDigestFailsLoudWithoutRetryOrReMint(t *testing.T) {
	fastRetries(t)
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	body := []byte("bytes that do not match")
	key := "blob/" + hexSHA256([]byte("something else"))
	srv, seen := headerStore(t, func(int, *http.Request) (int, string) { return http.StatusBadRequest, badDigestBody })
	var mints int32

	failed := didPanic(func() {
		capPut(key, srv.URL+"/o", boundHeadersFor(t, key), body, func() (string, map[string]string, error) {
			atomic.AddInt32(&mints, 1)
			return srv.URL + "/o2", boundHeadersFor(t, key), nil
		})
	})
	if !failed {
		t.Fatal("a 400 BadDigest was reported as success")
	}
	if len(*seen) != 1 {
		t.Errorf("BadDigest was retried: %d PUT(s), want 1 -- the body is wrong for the key, and resending it reproduces the refusal", len(*seen))
	}
	if atomic.LoadInt32(&mints) != 0 {
		t.Errorf("BadDigest triggered %d re-mint(s); a fresh cap for the same key refuses the same bytes", mints)
	}
}

// (d) ...but a BadDigest our own bytes do not explain is the WIRE's, and keeps #116's retry: on a plain cap it
// is the store rejecting our Content-MD5, and on a bound cap whose bytes DO hash to the signed checksum the
// store received different bytes than we sent. Both are transient; failing the seal on the first would turn
// one corrupted packet into a lost sync cycle.
func TestCapPut_BadDigestFromTheWireIsStillRetried(t *testing.T) {
	fastRetries(t)
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	body := []byte("bytes that DO hash to their key")
	key := "blob/" + hexSHA256(body)
	for _, tc := range []struct {
		name string
		hdrs map[string]string
	}{{"bound, bytes match the checksum", boundHeadersFor(t, key)}, {"plain cap (Content-MD5)", nil}} {
		srv, seen := headerStore(t, func(n int, _ *http.Request) (int, string) {
			if n == 1 {
				return http.StatusBadRequest, badDigestBody // one corrupted transfer
			}
			return 0, ""
		})
		if failed := didPanic(func() { capPut(key, srv.URL+"/o", tc.hdrs, body, nil) }); failed {
			t.Errorf("%s: a BadDigest from a corrupted transfer failed the write instead of retrying it", tc.name)
		}
		if len(*seen) != 2 {
			t.Errorf("%s: %d PUT(s), want 2 (the corrupted one, then the retry)", tc.name, len(*seen))
		}
	}
}

// (e) A 403 with headers present is an expired or mis-minted cap, never a Content-MD5 problem: re-mint once,
// resend with the FRESH cap's headers, and leave the process-wide MD5 latch alone.
func TestCapPut_403WithHeadersReMintsWithFreshHeadersAndNeverLatches(t *testing.T) {
	fastRetries(t)
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	body := []byte("slow upload, cap expired")
	key := "blob/" + hexSHA256(body)
	stale := boundHeadersFor(t, key)
	fresh := map[string]string{"x-amz-checksum-sha256": stale["x-amz-checksum-sha256"], "If-None-Match": "*", "x-amz-meta-remint": "2"}
	srv, seen := headerStore(t, func(n int, r *http.Request) (int, string) {
		if r.URL.Path == "/stale" {
			return http.StatusForbidden, sigMismatchBody
		}
		return 0, ""
	})
	var mints int32

	if failed := didPanic(func() {
		capPut(key, srv.URL+"/stale", stale, body, func() (string, map[string]string, error) {
			atomic.AddInt32(&mints, 1)
			return srv.URL + "/fresh", fresh, nil
		})
	}); failed {
		t.Fatal("a 403 SignatureDoesNotMatch on a BOUND cap failed the write instead of re-minting it")
	}
	if capPutNoMD5.Load() {
		t.Fatal("the Content-MD5 latch fired on a 403 for a PUT that sent no Content-MD5. That latch is for a presigner " +
			"that signs Content-MD5; firing it here strips the header from every plain cap for the rest of the process.")
	}
	if n := atomic.LoadInt32(&mints); n != 1 {
		t.Fatalf("re-minted %d time(s), want 1", n)
	}
	if len(*seen) != 2 {
		t.Fatalf("%d PUT(s), want 2 (the stale cap, then the fresh one)", len(*seen))
	}
	if (*seen)[0].Get("Content-MD5") != "" || (*seen)[1].Get("Content-MD5") != "" {
		t.Error("a bound PUT carried Content-MD5")
	}
	if got := (*seen)[1].Get("x-amz-meta-remint"); got != "2" {
		t.Errorf("the resend after the re-mint carried the OLD headers (x-amz-meta-remint=%q, want \"2\"): the old ones were "+
			"signed into the old URL, and a header the fresh URL did not sign is itself a 403", got)
	}
}

// (f) POST /cap on a gateway without it (404 or 405) falls back to GET /cap?op=write -- today's plain re-mint;
// a 200 returns the headers and never touches the GET; a 403 is a verdict and is NOT retried unauthenticated.
func TestWriteCapBound_FallsBackToTheGetOnlyForAGatewayWithoutPostCap(t *testing.T) {
	var postCode int32
	var gets int32
	var lastPost capBoundReq
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && r.URL.Path == "/cap" {
			json.NewDecoder(r.Body).Decode(&lastPost)
			code := int(atomic.LoadInt32(&postCode))
			w.WriteHeader(code)
			if code == http.StatusOK {
				json.NewEncoder(w).Encode(capBoundResp{URL: "http://store/bound", Headers: map[string]string{"If-None-Match": "*"}})
			}
			return
		}
		if r.Method == http.MethodGet && r.URL.Path == "/cap" && r.URL.Query().Get("op") == "write" {
			atomic.AddInt32(&gets, 1)
			json.NewEncoder(w).Encode(capResp{URL: "http://store/plain?ref=" + r.URL.Query().Get("ref")})
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()
	g := newGatewayClient(srv.URL, gwDefault)
	prior := []string{strings.Repeat("ab", 32)}

	// 405 is what every fielded gateway answers a POST to its `GET /cap` route: the one fallback.
	atomic.StoreInt32(&postCode, http.StatusMethodNotAllowed)
	atomic.StoreInt32(&gets, 0)
	u0, h0, err0 := g.writeCapBound("ref/x", "prof", prior)
	if err0 != nil || u0 != "http://store/plain?ref=ref/x" || h0 != nil { // the fake echoes the decoded ref
		t.Errorf("POST /cap -> 405: url=%q hdrs=%v err=%v, want the plain GET cap and nil headers", u0, h0, err0)
	}
	if atomic.LoadInt32(&gets) != 1 {
		t.Errorf("POST /cap -> 405: GET /cap?op=write called %d time(s), want 1", gets)
	}
	// ...and a 404 is NOT: a later gateway may use it for a refusal, which must never become a profile-less GET.
	atomic.StoreInt32(&postCode, http.StatusNotFound)
	atomic.StoreInt32(&gets, 0)
	if _, _, err := g.writeCapBound("ref/x", "prof", prior); err == nil {
		t.Error("POST /cap -> 404 returned a cap")
	}
	if atomic.LoadInt32(&gets) != 0 {
		t.Error("a 404 on POST /cap fell back to the profile-less GET")
	}

	atomic.StoreInt32(&postCode, http.StatusOK)
	atomic.StoreInt32(&gets, 0)
	u, h, err := g.writeCapBound("blob/y", "prof", prior)
	if err != nil || u != "http://store/bound" || h["If-None-Match"] != "*" {
		t.Errorf("POST /cap -> 200: url=%q hdrs=%v err=%v, want the bound cap and its headers", u, h, err)
	}
	if atomic.LoadInt32(&gets) != 0 {
		t.Error("a successful POST /cap was followed by the plain GET")
	}
	if !lastPost.Bound || lastPost.Ref != "blob/y" || lastPost.Profile != "prof" || len(lastPost.Prior) != 1 || lastPost.Prior[0] != prior[0] {
		t.Errorf("POST /cap body = %+v, want {ref blob/y, profile prof, prior, bound:true}", lastPost)
	}

	atomic.StoreInt32(&postCode, http.StatusForbidden)
	atomic.StoreInt32(&gets, 0)
	if _, _, err := g.writeCapBound("ref/z", "prof", nil); err == nil {
		t.Error("POST /cap -> 403 (held by another profile) returned a cap")
	}
	if atomic.LoadInt32(&gets) != 0 {
		t.Error("an ownership refusal on POST /cap was retried through the profile-less GET -- that turns a 403 into a second, unauthenticated attempt")
	}
}

// (g) bound_caps:true is on the wire from every lease flavour, and prior only when given. Drives the real
// builders and decodes the raw JSON, so a struct literal in a test cannot pass for the field (the mutation
// that caught TestEveryLeaseFlavourOptsIntoSkipPresent's first version).
func TestEveryLeaseFlavourAsksForBoundCaps(t *testing.T) {
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
	prior := []string{strings.Repeat("cd", 32)}
	if _, _, err := gw.lease(nil, nil, refs); err != nil {
		t.Fatalf("lease: %v", err)
	}
	if _, _, err := gw.leaseEntitled("p", nil, nil, refs, 1, 0, "", nil); err != nil {
		t.Fatalf("leaseEntitled: %v", err)
	}
	if _, _, err := gw.leaseFree("p", refs, prior); err != nil {
		t.Fatalf("leaseFree: %v", err)
	}
	names := []string{"lease", "leaseEntitled", "leaseFree"}
	if len(bodies) != len(names) {
		t.Fatalf("got %d requests, want %d", len(bodies), len(names))
	}
	for i, b := range bodies {
		if b["bound_caps"] != true {
			t.Errorf("%s() must send bound_caps:true on the wire, got %v -- without it the gateway mints a cap that binds nothing", names[i], b["bound_caps"])
		}
	}
	if _, has := bodies[1]["prior"]; has {
		t.Errorf("leaseEntitled with no prior still sent one: %v", bodies[1]["prior"])
	}
	if p, _ := bodies[2]["prior"].([]any); len(p) != 1 || p[0] != prior[0] {
		t.Errorf("leaseFree sent prior=%v, want %v", bodies[2]["prior"], prior)
	}
}

// (a, integration) A lease that returns cap_headers for a blob: that blob's PUT carries them and no Content-MD5,
// while the pointer -- for which the gateway signs nothing -- is PUT exactly as today.
func TestCapFlush_PutsCarryTheLeasesCapHeadersPerKey(t *testing.T) {
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	blobCache = nil
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	capStoreCapHeaders = func(ref string) map[string]string {
		if !strings.HasPrefix(ref, "blob/") {
			return nil
		}
		return boundHeadersFor(t, ref)
	}
	var mu2 sync.Mutex
	puts := map[string]http.Header{}
	capStorePutSeen = func(key string, hdr http.Header) { mu2.Lock(); puts[key] = hdr; mu2.Unlock() }

	name, pass := "boundflush", "a passphrase for the bound flush"
	dk := deriveKey(name, pass)
	bn := capBegin()
	capSetSession(name, pass, dk)
	data := []byte("bound blob bytes for the flush")
	h := postBlob("s3", data)
	putRef("s3", profileRefV2(name, pass), h)
	capFlush(bn)

	mu.Lock()
	landed := string(objs["blob/"+h]) == string(data) && objs["ref/"+profileRefV2(name, pass)] != nil
	mu.Unlock()
	if !landed {
		t.Fatal("the flush did not land both objects")
	}
	mu2.Lock()
	defer mu2.Unlock()
	bh, want := puts["blob/"+h], boundHeadersFor(t, "blob/"+h)
	if bh == nil {
		t.Fatal("no PUT seen for the blob")
	}
	for k, v := range want {
		if bh.Get(k) != v {
			t.Errorf("blob PUT header %s = %q, want %q (the lease's cap_headers for this key)", k, bh.Get(k), v)
		}
	}
	if bh.Get("Content-MD5") != "" {
		t.Error("the bound blob PUT carried Content-MD5")
	}
	rh := puts["ref/"+profileRefV2(name, pass)]
	if rh == nil {
		t.Fatal("no PUT seen for the pointer")
	}
	if rh.Get("Content-MD5") == "" || hasAmzHeader(rh) || rh.Get("If-None-Match") != "" {
		t.Errorf("the pointer PUT changed shape: %v -- the gateway signs nothing into a pointer cap, so it must be sent as before", rh)
	}
}

// (e, integration) A 403 on a bound blob PUT inside a flush re-mints through POST /cap carrying bound:true and
// the flush's own profile, resends with the fresh headers, and never fires the MD5 latch.
func TestCapFlush_ReMintsThroughPostCapAsTheFlushProfile(t *testing.T) {
	fastRetries(t)
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	blobCache = nil
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	capStoreCapHeaders = func(ref string) map[string]string {
		if !strings.HasPrefix(ref, "blob/") {
			return nil
		}
		return boundHeadersFor(t, ref)
	}
	var mu2 sync.Mutex
	refused := map[string]bool{}
	capStorePutStatus = func(key string, hdr http.Header) (int, string) {
		mu2.Lock()
		defer mu2.Unlock()
		if strings.HasPrefix(key, "blob/") && hdr.Get("x-amz-meta-remint") == "" && !refused[key] {
			refused[key] = true // the lease-time cap has expired: refuse it once
			return http.StatusForbidden, sigMismatchBody
		}
		return 0, ""
	}
	var posts []capBoundReq
	capStorePostCap = func(req capBoundReq, objURL string) (int, capBoundResp) {
		mu2.Lock()
		posts = append(posts, req)
		mu2.Unlock()
		h := boundHeadersFor(t, req.Ref)
		h["x-amz-meta-remint"] = "1"
		return http.StatusOK, capBoundResp{URL: objURL, Headers: h}
	}

	name, pass := "remintflush", "a passphrase for the re-mint flush"
	dk := deriveKey(name, pass)
	bn := capBegin()
	capSetSession(name, pass, dk)
	data := []byte("blob whose first cap is refused")
	h := postBlob("s3", data)
	putRef("s3", profileRefV2(name, pass), h)
	capFlush(bn)

	mu.Lock()
	landed := string(objs["blob/"+h]) == string(data)
	mu.Unlock()
	if !landed {
		t.Fatal("the blob did not land after the re-mint")
	}
	if capPutNoMD5.Load() {
		t.Fatal("the MD5 latch fired on a bound cap's 403")
	}
	mu2.Lock()
	defer mu2.Unlock()
	// One re-mint per REFUSED key, no more: the flush also carries the folded wallet blob, which the store
	// refuses once too.
	if len(posts) != len(refused) {
		t.Fatalf("POST /cap called %d time(s) for %d refused key(s), want exactly one re-mint per refused key", len(posts), len(refused))
	}
	sawData := false
	for _, p := range posts {
		if !p.Bound || !refused[p.Ref] || p.Profile != profileRefV2(name, pass) {
			t.Errorf("POST /cap body = %+v, want bound:true for a refused blob under this flush's profile", p)
		}
		sawData = sawData || p.Ref == "blob/"+h
	}
	if !sawData {
		t.Error("the refused data blob was never re-minted through POST /cap")
	}
}

// (h) A rotation leases under the NEW profile and names the OLD one as prior -- the rows it rewrites are
// tagged with the old key -- and writes the old key into the index as !bill-retag.
func TestARotationNamesTheOldBillingKeyAsPriorAndRecordsIt(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	t.Setenv("NOWHERE_STATE", t.TempDir())
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var leases []leaseReq
	capStoreLeaseSeen = func(req leaseReq) { mu.Lock(); leases = append(leases, req); mu.Unlock() }

	const name, oldpass, newpass = "priorrot", "old horse battery staple", "new maple stone cloud lantern"
	if createVault("s3", name, oldpass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	oldKey, newKey := profileRefV2(name, oldpass), profileRefV2(name, newpass)
	mu.Lock()
	leases = nil
	mu.Unlock()
	if _, err := rotateVault("s3", name, oldpass, newpass, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(leases) == 0 {
		t.Fatal("the rotation sent no lease")
	}
	for i, l := range leases {
		if l.Profile != newKey {
			t.Errorf("lease %d metered under %s, want the NEW profile", i, short(l.Profile))
		}
		if len(l.Prior) != 1 || l.Prior[0] != oldKey {
			t.Errorf("lease %d prior = %v, want exactly the OLD billing key. The recovery ref and the tombstones it writes "+
				"are rows tagged with the old key; without prior the gateway refuses the whole lease 403.", i, shortAll(l.Prior))
		}
	}
	dk, _, ok := resolveKey("s3", name, newpass)
	if !ok {
		t.Fatal("the rotated vault does not resolve")
	}
	v, isV := openVaultHead("s3", name, newpass)
	if !isV {
		t.Fatal("no vault at the new credential")
	}
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("the rotated vault carries no scope index")
	}
	if got := billRetagOf(idx); len(got) != 1 || got[0] != oldKey {
		t.Errorf("!bill-retag = %v after the rotation, want [old key]: the chunks this bracket never re-published stay "+
			"tagged with it until a lease that names them carries it", shortAll(got))
	}
}

// (h) A recovery names the !bill record as prior -- the one place the old key survives the lost passphrase --
// and, when the record is present, retires the superseded scope head.
func TestARecoveryNamesTheRecordedBillingKeyAsPrior(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	t.Setenv("NOWHERE_STATE", t.TempDir())
	blobCache = nil
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	const name, p1, p2 = "priorrec", "old horse battery staple", "new maple stone cloud lantern"
	mnemonic := createVault("s3", name, p1)
	if mnemonic == "" {
		t.Fatal("createVault returned no recovery code")
	}
	oldDe := sealBareAndDe(t, name, p1)
	var mu sync.Mutex
	var leases []leaseReq
	capStoreLeaseSeen = func(req leaseReq) { mu.Lock(); leases = append(leases, req); mu.Unlock() }

	if ok := daemonVaultOp(func() error { return recoverVault("s3", name, mnemonic, p2) }); !ok {
		t.Fatal("recovery answered BLANK for a correct phrase")
	}
	mu.Lock()
	defer mu.Unlock()
	oldKey := profileRefV2(name, p1)
	if len(leases) == 0 {
		t.Fatal("the recovery sent no lease")
	}
	for i, l := range leases {
		if len(l.Prior) != 1 || l.Prior[0] != oldKey {
			t.Errorf("lease %d prior = %v, want the billing key the index recorded under the old credential", i, shortAll(l.Prior))
		}
	}
	if getRef("s3", oldDe) != "" {
		t.Error("with the billing key recorded, the superseded #de head should have been retired")
	}
}

// (h) Without a !bill record (an index older than NWP-20260917-04) a recovery cannot name the key the old rows
// are tagged with, so it sends no prior -- and it STILL retires the superseded scope refs. Skipping them bought
// nothing on a strict gateway (the recovery ref's own row refuses the lease first) and regressed an older one,
// where the tombstones land exactly as before this slice.
func TestARecoveryWithoutABillingRecordStillRetiresSupersededRefs(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	t.Setenv("NOWHERE_STATE", t.TempDir())
	blobCache = nil
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	const name, p1, p2 = "nobillrec", "old horse battery staple", "new maple stone cloud lantern"
	mnemonic := createVault("s3", name, p1)
	if mnemonic == "" {
		t.Fatal("createVault returned no recovery code")
	}
	oldDe := sealBareAndDe(t, name, p1)
	// Strip the record AFTER the seals: a bare seal backfills it (TestABareSealBackfillsTheBillingRecord).
	dk, _, ok := resolveKey("s3", name, p1)
	if !ok {
		t.Fatal("the vault does not resolve")
	}
	v, isV := openVaultHead("s3", name, p1)
	if !isV {
		t.Fatal("no vault")
	}
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("no scope index to strip")
	}
	delete(idx, scopeBillKey)
	v.Scopes = sealScopeIndex(dk, idx)
	signVault(v, dk)
	// Both pointers, as a bare seal writes them: recoverVault reaches the vault through the RECOVERY ref.
	var vh string
	capWrite(name, p1, dk, func() {
		vh = postBlob("s3", serializeVault(v))
		putHead("s3", name, p1, vh)
		putRef("s3", v.RecoveryRef, vh)
	})
	if v.RecoveryRef == "" || getRef("s3", v.RecoveryRef) != vh {
		t.Fatal("fixture bug: the recovery ref does not name the stripped vault")
	}
	if v2, _ := openVaultHead("s3", name, p1); v2 == nil || func() bool { i, _ := openScopeIndex(dk, v2.Scopes); return billKeyOf(i) != "" }() {
		t.Fatal("fixture bug: the billing record was not stripped")
	}
	var mu sync.Mutex
	var leases []leaseReq
	capStoreLeaseSeen = func(req leaseReq) { mu.Lock(); leases = append(leases, req); mu.Unlock() }

	var recovered bool
	logged := captureStderr(t, func() {
		recovered = daemonVaultOp(func() error { return recoverVault("s3", name, mnemonic, p2) })
	})
	if !recovered {
		t.Fatal("recovery answered BLANK for a correct phrase")
	}
	if getRef("s3", oldDe) != "" {
		t.Error("the superseded #de head still resolves after a recovery whose index names no billing key -- it is " +
			"readable by the old passphrase, the credential a recovery exists to replace")
	}
	if !strings.Contains(logged, "retired 1 superseded scope ref(s)") {
		t.Errorf("the recovery did not report the retirement; stderr was:\n%s", logged)
	}
	if strings.Contains(logged, oldDe) {
		t.Error("the log line named a superseded ref -- that is the old credential's store key")
	}
	mu.Lock()
	defer mu.Unlock()
	for i, l := range leases {
		if len(l.Prior) != 0 {
			t.Errorf("lease %d carried prior=%v although the index names no billing key", i, shortAll(l.Prior))
		}
	}
	if _, _, ok := resolveKey("s3", name, p2); !ok {
		t.Fatal("the new passphrase does not open the recovered vault")
	}
}

// (i) The record rides the next bare seal and payRent as prior, payRent's full-footprint 200 clears it, and a
// seal's lease does not.
func TestTheRetagRecordRidesLaterLeasesUntilPayRentSettlesIt(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	t.Setenv("NOWHERE_STATE", t.TempDir())
	blobCache = nil
	freeRenewedThrough = map[string]int64{}
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	const name, p1, p2 = "retagride", "old horse battery staple", "new maple stone cloud lantern"
	if createVault("s3", name, p1) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if _, err := rotateVault("s3", name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	oldKey := profileRefV2(name, p1)
	var mu sync.Mutex
	var leases []leaseReq
	capStoreLeaseSeen = func(req leaseReq) { mu.Lock(); leases = append(leases, req); mu.Unlock() }

	// A later bare seal.
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", name, p2, d)
	mu.Lock()
	n := len(leases)
	if n == 0 {
		mu.Unlock()
		t.Fatal("the seal sent no lease")
	}
	for i, l := range leases {
		if len(l.Prior) != 1 || l.Prior[0] != oldKey {
			t.Errorf("seal lease %d prior = %v, want the recorded old key", i, shortAll(l.Prior))
		}
	}
	mu.Unlock()
	if got := retagOf(t, name, p2); len(got) != 1 {
		t.Fatalf("a SEAL's lease cleared the record (now %v): only a full-footprint lease may, because only it names every row", shortAll(got))
	}

	// payRent: the full footprint, with prior; a 200 settles the record.
	if _, paid, err := payRent(newGatewayClient(srv.URL, gwDefault), "s3", name, p2, wpath, nil); err != nil || !paid {
		t.Fatalf("payRent: paid=%v err=%v", paid, err)
	}
	mu.Lock()
	rent := leases[n:]
	mu.Unlock()
	if len(rent) == 0 {
		t.Fatal("payRent sent no lease")
	}
	if l := rent[0]; len(l.Prior) != 1 || l.Prior[0] != oldKey {
		t.Errorf("payRent's lease prior = %v, want the recorded old key -- this is the one lease that names every row", shortAll(l.Prior))
	}
	if got := retagOf(t, name, p2); len(got) != 0 {
		t.Errorf("!bill-retag = %v after payRent's full-footprint 200, want it cleared", shortAll(got))
	}
}

// (i) payRent's PAID arm (a wallet with credit, so leaseRefs and an entitled lease) sends the record and settles
// it too -- the free-arm test above cannot see this arm. Direct store, so the only gateway call is the lease.
func TestPayRentsPaidArmSendsAndSettlesTheRetagRecord(t *testing.T) {
	const name, p1, p2 = "retagpaid", "old horse battery staple", "new maple stone cloud lantern"
	base, wpath, gw, mu, leases := paidRentFixture(t, name, p1, p2, http.StatusOK)
	oldKey := profileRefV2(name, p1)

	if _, paid, err := payRent(gw, base, name, p2, wpath, nil); err != nil || !paid {
		t.Fatalf("payRent: paid=%v err=%v", paid, err)
	}
	mu.Lock()
	if len(*leases) != 1 || (*leases)[0].Free {
		mu.Unlock()
		t.Fatalf("want exactly one ENTITLED lease, got %d -- the fixture did not reach the paid arm", len(*leases))
	}
	if l := (*leases)[0]; len(l.Prior) != 1 || l.Prior[0] != oldKey {
		t.Errorf("the paid arm's lease prior = %v, want the recorded old key", shortAll(l.Prior))
	}
	mu.Unlock()
	if got := retagOfAt(t, base, name, p2); len(got) != 0 {
		t.Errorf("!bill-retag = %v after the paid arm's full-footprint 200, want it cleared", shortAll(got))
	}
}

// paidRentFixture: a direct store holding a profile rotated p1 -> p2 (so its record names p1's key), a wallet with
// credit (so payRent takes the PAID arm), and a gateway whose /lease answers leaseCode. Returns what payRent needs
// and the lease bodies the gateway saw.
func paidRentFixture(t *testing.T, name, p1, p2 string, leaseCode int) (string, string, *gatewayClient, *sync.Mutex, *[]leaseReq) {
	t.Helper()
	t.Setenv("GATEWAY_URL", "") // direct store: capMode() false
	base := newHTTPStore(t)
	mu := &sync.Mutex{}
	leases := &[]leaseReq{}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(quoteInfo{Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 86400, EpochsPerLease: 30,
			PriceCents: 200, CurrentEpoch: 42, FreeGB: 1})
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		mu.Lock()
		*leases = append(*leases, req)
		mu.Unlock()
		if leaseCode != http.StatusOK {
			w.WriteHeader(leaseCode)
			_, _ = io.WriteString(w, `{"error":"store unavailable"}`)
			return
		}
		json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: 99, DeadlineEpoch: 129})
	})
	gsrv := httptest.NewServer(mux)
	t.Cleanup(gsrv.Close)
	if createVault(base, name, p1) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	if got := retagOfAt(t, base, name, p2); len(got) != 1 || got[0] != profileRefV2(name, p1) {
		t.Fatalf("fixture: !bill-retag = %v after the rotation, want [old key]", shortAll(got))
	}
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(wpath, &Wallet{Tokens: []Token{{Denom: "1GBmo", Nonce: "n1", Exp: 1 << 62, Sig: "s"}}}); err != nil {
		t.Fatal(err)
	}
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	freeRenewedThrough = map[string]int64{}
	return base, wpath, newGatewayClient(gsrv.URL, gwDefault), mu, leases
}

// (7) A renewal that does NOT answer 200 settles nothing: the record stays, on both arms, so the next renewal sends
// it again. Clearing it on a refusal would strand every row still tagged with the old key.
func TestARefusedRenewalKeepsTheRetagRecord(t *testing.T) {
	t.Run("paid arm", func(t *testing.T) {
		const name, p1, p2 = "retagpaidno", "old horse battery staple", "new maple stone cloud lantern"
		base, wpath, gw, _, leases := paidRentFixture(t, name, p1, p2, http.StatusServiceUnavailable)
		if _, paid, err := payRent(gw, base, name, p2, wpath, nil); err == nil || paid {
			t.Fatalf("payRent against a 503 lease: paid=%v err=%v, want an error", paid, err)
		}
		if len(*leases) != 1 {
			t.Fatalf("precondition: %d lease(s) sent, want the one the gateway refused", len(*leases))
		}
		if got := retagOfAt(t, base, name, p2); len(got) != 1 {
			t.Errorf("!bill-retag = %v after a REFUSED paid renewal, want it kept", shortAll(got))
		}
	})
	t.Run("free arm", func(t *testing.T) {
		capFixture(t)
		const name, p1, p2 = "retagfreeno", "old horse battery staple", "new maple stone cloud lantern"
		if createVault("s3", name, p1) == "" {
			t.Fatal("createVault returned no recovery code")
		}
		if _, err := rotateVault("s3", name, p1, p2, nil, true); err != nil {
			t.Fatalf("rotateVault: %v", err)
		}
		refused := 0
		capStoreLeaseStatus = func(req leaseReq) (int, string) {
			if req.Free {
				refused++
				return http.StatusForbidden, `{"error":"free tier disabled"}`
			}
			return 0, ""
		}
		if _, paid, err := payRent(newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault), "s3", name, p2, os.Getenv("NOWHERE_WALLET"), nil); err == nil || paid {
			t.Fatalf("payRent against a refused free lease: paid=%v err=%v, want an error", paid, err)
		}
		if refused != 1 {
			t.Fatalf("precondition: %d free lease(s) refused, want 1", refused)
		}
		if got := retagOf(t, name, p2); len(got) != 1 {
			t.Errorf("!bill-retag = %v after a REFUSED free renewal, want it kept", shortAll(got))
		}
	})
}

// (i) A second credential change before any full-footprint lease keeps the FIRST change's key: rows can still
// carry it, and without it in the record nothing could ever name them again.
func TestASecondCredentialChangeKeepsTheOutstandingRetagKey(t *testing.T) {
	t.Setenv("GATEWAY_URL", "")
	base := newHTTPStore(t)
	const name, p1, p2, p3 = "retagtwice", "first horse battery staple", "second maple stone cloud", "third river lantern key"
	if createVault(base, name, p1) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotate 1: %v", err)
	}
	if _, err := rotateVault(base, name, p2, p3, nil, true); err != nil {
		t.Fatalf("rotate 2: %v", err)
	}
	got := retagOfAt(t, base, name, p3)
	k1, k2 := profileRefV2(name, p1), profileRefV2(name, p2)
	if len(got) != 2 || got[0] != k1 || got[1] != k2 {
		t.Errorf("!bill-retag = %v after two changes, want [first key, second key] oldest first -- repointScopes "+
			"builds a fresh index, and dropping the outstanding record strands every row still tagged with the first key", shortAll(got))
	}
}

// (i) The record is bounded: the newest eight keys, oldest dropped, no duplicates, nothing that is not a key.
func TestTheRetagRecordKeepsTheNewestEightKeys(t *testing.T) {
	idx := map[string]scopeRec{}
	keys := make([]string, 0, 9)
	cur := strings.Repeat("f", 64) // the profile's current key, never among the pushed ones here
	for i := 0; i < 9; i++ {
		k := strings.Repeat(string(rune('0'+i)), 64) // nine distinct 64-hex keys
		keys = append(keys, k)
		idx = billRetagPush(idx, k, cur)
	}
	got := billRetagOf(idx)
	if len(got) != 8 || got[0] != keys[1] || got[7] != keys[8] {
		t.Fatalf("after 9 pushes: %d keys, first %s, last %s; want 8 with the OLDEST dropped", len(got), short(got[0]), short(got[len(got)-1]))
	}
	idx = billRetagPush(idx, keys[1], cur) // a repeat moves to newest and adds nothing
	if got := billRetagOf(idx); len(got) != 8 || got[7] != keys[1] || got[0] != keys[2] {
		t.Errorf("a repeated push: %v", shortAll(got))
	}
	before := idx[scopeBillRetagKey]
	idx = billRetagPush(idx, "", cur)          // billKeyOf's "nothing recorded" answer
	idx = billRetagPush(idx, "not-a-key", cur) // never a shape the gateway accepts
	if idx[scopeBillRetagKey] != before {
		t.Error("an empty or malformed key changed the record")
	}
	if !strings.HasPrefix(idx[scopeBillRetagKey].Ref, billRefPrefix) {
		t.Error("the record is not p2:-prefixed, so an older walker would resolve it as a scope")
	}
	if !isScopeSuffix("#de") || isScopeSuffix(scopeBillRetagKey) {
		t.Error("isScopeSuffix does not exclude the re-tag record: every index walker would treat it as a scope")
	}
	damaged := map[string]scopeRec{scopeBillRetagKey: {Ref: billRefPrefix + keys[0] + ",garbage," + keys[1]}}
	if got := billRetagOf(damaged); len(got) != 2 {
		t.Errorf("a damaged entry was not dropped on read: %v", shortAll(got))
	}
}

// (j) A delete whose tombstone the gateway refuses reports "unverified" -- the existing verdict for a ref
// that still resolves -- instead of panicking out of the daemon's DELETE verb; and the re-mint it sends
// carries the profile being deleted.
func TestADeleteWhoseTombstoneIsRefusedReportsUnverified(t *testing.T) {
	fastRetries(t)
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	t.Setenv("NOWHERE_STATE", t.TempDir())
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	const name, pass = "refuseddel", "horse battery staple correct"
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	var mu sync.Mutex
	var posts []capBoundReq
	capStorePostCap = func(req capBoundReq, objURL string) (int, capBoundResp) {
		mu.Lock()
		posts = append(posts, req)
		mu.Unlock()
		return http.StatusForbidden, capBoundResp{} // held by another profile
	}

	var got string
	var failed bool
	logged := captureStderr(t, func() { failed = didPanic(func() { got = deleteProfile("s3", name, pass) }) })
	if failed {
		t.Fatal("deleteProfile PANICKED on a refused tombstone. The daemon's DELETE verb recovers that with the purge " +
			"half done and nothing said; the verify pass exists to report exactly this as \"unverified\".")
	}
	if got != "unverified" {
		t.Errorf("deleteProfile = %q, want \"unverified\": the refs still resolve", got)
	}
	// The recovery ref goes first, so a gateway refusing every write stops the delete there (fix 3).
	if !strings.Contains(logged, "recovery-code tombstone was refused") {
		t.Errorf("the refusal at the recovery ref was not logged; stderr was:\n%s", logged)
	}
	if strings.Contains(logged, profileRefV2(name, pass)[:12]) {
		t.Error("the delete log carries a prefix of the profile string -- the bare head's key; count, never name")
	}
	if _, _, ok := resolveKey("s3", name, pass); !ok {
		t.Error("the profile stopped resolving although every tombstone was refused")
	}
	mu.Lock()
	defer mu.Unlock()
	if len(posts) == 0 {
		t.Fatal("no POST /cap was sent")
	}
	for _, p := range posts {
		if p.Profile != profileRefV2(name, pass) || !p.Bound {
			t.Errorf("POST /cap carried profile %q (bound=%v), want the deleting profile's key and bound:true", short(p.Profile), p.Bound)
		}
	}

	// The store refusing the PUTs after the recovery ref's has landed: the same verdict, reached through the
	// scoped refs, and their refusals are logged as a COUNT, never by key.
	v, isV := openVaultHead("s3", name, pass)
	if !isV || v.RecoveryRef == "" {
		t.Fatal("fixture: no recovery ref")
	}
	rec := v.RecoveryRef
	capStorePostCap = nil // today's gateway: GET fallback mints
	capStorePutStatus = func(key string, hdr http.Header) (int, string) {
		if strings.HasPrefix(key, "ref/") && key != "ref/"+rec {
			return http.StatusForbidden, `<Error><Code>AccessDenied</Code></Error>`
		}
		return 0, ""
	}
	logged = captureStderr(t, func() { failed = didPanic(func() { got = deleteProfile("s3", name, pass) }) })
	if failed {
		t.Fatal("deleteProfile panicked on a store-refused tombstone")
	}
	if got != "unverified" {
		t.Errorf("deleteProfile = %q with the store refusing the scoped tombstones, want \"unverified\"", got)
	}
	if !strings.Contains(logged, "tombstone(s) were refused") {
		t.Errorf("the scoped refusals were not logged as a count; stderr was:\n%s", logged)
	}
	if strings.Contains(logged, profileRefV2(name, pass)[:12]) {
		t.Error("the delete log carries a prefix of the profile string")
	}
}

// sealBareAndDe seals the bare profile and one real scope in cap mode and returns #de's head ref under pass.
func sealBareAndDe(t *testing.T, name, pass string) string {
	t.Helper()
	for _, suf := range []string{"", "#de"} {
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"+suf), 0o600); err != nil {
			t.Fatal(err)
		}
		pushProfile("s3", name+suf, pass, d)
	}
	ref, _ := headWriteRef(name+"#de", pass)
	if getRef("s3", ref) == "" {
		t.Fatal("fixture did not seal #de")
	}
	return ref
}

// retagOf reads the live vault's !bill-retag record under (name, pass) from the cap-mode store.
func retagOf(t *testing.T, name, pass string) []string {
	t.Helper()
	return retagOfAt(t, "s3", name, pass)
}

// retagOfAt is retagOf against any store base.
func retagOfAt(t *testing.T, base, name, pass string) []string {
	t.Helper()
	dk, _, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatal("the vault does not resolve")
	}
	v, isV := openVaultHead(base, name, pass)
	if !isV {
		t.Fatal("no vault")
	}
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("no scope index")
	}
	return billRetagOf(idx)
}

func hexSHA256(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func shortAll(keys []string) []string {
	out := make([]string, 0, len(keys))
	for _, k := range keys {
		out = append(out, short(k))
	}
	return out
}

// (1) `prior` never names the profile the request is made as, at the SEND: every sender that pairs the two drops
// it, with anything not 64 hex and any repeat. The gateway answers 400 `bad prior` to all three.
func TestPriorNeverNamesTheLeasesOwnProfileOnTheWire(t *testing.T) {
	me, other := strings.Repeat("a1", 32), strings.Repeat("b2", 32)
	var mu sync.Mutex
	var priors [][]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var m map[string]any
		json.NewDecoder(r.Body).Decode(&m)
		p, _ := m["prior"].([]any)
		mu.Lock()
		priors = append(priors, p)
		mu.Unlock()
		if r.URL.Path == "/cap" {
			_, _ = w.Write([]byte(`{"url":"http://store/x"}`))
			return
		}
		_, _ = w.Write([]byte(`{"through_epoch":1,"spent":0,"write_caps":{}}`))
	}))
	defer srv.Close()
	gw := newGatewayClient(srv.URL, gwDefault)
	refs := map[string]int64{"blob/a": 1}
	sent := []string{me, other, "not-a-key", other}
	if _, _, err := gw.leaseFree(me, refs, sent); err != nil {
		t.Fatal(err)
	}
	if _, _, err := gw.leaseEntitled(me, nil, nil, refs, 1, 0, "", sent); err != nil {
		t.Fatal(err)
	}
	if _, _, err := gw.writeCapBound("ref/x", me, sent); err != nil {
		t.Fatal(err)
	}
	names := []string{"leaseFree", "leaseEntitled", "writeCapBound"}
	if len(priors) != len(names) {
		t.Fatalf("got %d requests, want %d", len(priors), len(names))
	}
	for i, p := range priors {
		if len(p) != 1 || p[0] != other {
			t.Errorf("%s sent prior=%v, want exactly the one other key: the profile itself, a malformed entry and a "+
				"repeat must all be dropped before the gateway sees them", names[i], p)
		}
	}
	nine := make([]string, 0, 9)
	for i := 0; i < 9; i++ {
		nine = append(nine, strings.Repeat(string(rune('0'+i)), 64))
	}
	if got := cleanPrior(me, nine); len(got) != billRetagMax || got[0] != nine[1] || got[7] != nine[8] {
		t.Errorf("cleanPrior over 9 keys = %v, want the newest 8", shortAll(got))
	}
}

// (1) ...and at the WRITE: billRetagPush drops the profile's current key from the whole record, not only as the
// key being pushed, and removes the entry when nothing is left.
func TestBillRetagPushDropsTheCurrentKey(t *testing.T) {
	a, b, x := strings.Repeat("a", 64), strings.Repeat("b", 64), strings.Repeat("c", 64)
	idx := map[string]scopeRec{scopeBillRetagKey: billRetagRec([]string{a, x})}
	idx = billRetagPush(idx, b, a) // a change back to A, moving off B
	if got := billRetagOf(idx); len(got) != 2 || got[0] != x || got[1] != b {
		t.Errorf("record = %v, want [x, b]: the profile's own key a must be dropped", shortAll(got))
	}
	idx = billRetagPush(idx, a, a)
	if got := billRetagOf(idx); containsString(got, a) {
		t.Errorf("pushing the current key recorded it: %v", shortAll(got))
	}
	only := map[string]scopeRec{scopeBillRetagKey: billRetagRec([]string{a})}
	only = billRetagPush(only, "", a)
	if _, has := only[scopeBillRetagKey]; has {
		t.Error("a record left with no key was kept as an empty entry")
	}
}

// (1) ...and in the carry: repointScopes moves an outstanding record into the new index MINUS the key it is moving
// to -- it runs before any push, and a change back to an earlier passphrase finds that key outstanding.
func TestRepointScopesDropsTheNewKeyFromTheCarriedRecord(t *testing.T) {
	t.Setenv("GATEWAY_URL", "")
	base := newHTTPStore(t)
	const name, pass = "carrydrop", "a passphrase to come back to"
	cur, other := profileRefV2(name, pass), strings.Repeat("c3", 32)
	idx := map[string]scopeRec{scopeBillRetagKey: billRetagRec([]string{cur, other})}
	next, _, err := repointScopes(base, name, idx, pass, randBytes(32), "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := billRetagOf(next); len(got) != 1 || got[0] != other {
		t.Errorf("carried record = %v, want [other]: the key the profile moves TO may not be carried as its own prior", shortAll(got))
	}
}

// (1) The user-facing shape: A -> B -> A before any renewal. The profile must still seal and renew under A, against
// a gateway enforcing both the prior rule and the holder rule, and the renewal must settle the record.
func TestAChangeBackToAnEarlierPassphraseLeavesAWorkingProfile(t *testing.T) {
	led := ledgerFixture(t)
	const name, pa, pb = "backagain", "the first passphrase here", "a second passphrase here"
	if createVault("s3", name, pa) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if sealBare(t, name, pa, "one") {
		t.Fatal("fixture: the first seal was refused")
	}
	if _, err := rotateVault("s3", name, pa, pb, nil, true); err != nil {
		t.Fatalf("rotate A->B: %v", err)
	}
	if _, err := rotateVault("s3", name, pb, pa, nil, true); err != nil {
		t.Fatalf("rotate B->A: %v", err)
	}
	keyA, keyB := profileRefV2(name, pa), profileRefV2(name, pb)
	if got := retagOf(t, name, pa); len(got) != 1 || got[0] != keyB {
		t.Errorf("record after A->B->A = %v, want exactly [B]: naming A would be the profile's own key", shortAll(got))
	}
	if sealBare(t, name, pa, "two") {
		t.Fatal("a seal after A->B->A was refused -- every lease carrying the record names the profile itself (400 bad prior)")
	}
	if tag := led.tag("ref/" + keyA); tag != keyA {
		t.Errorf("the bare head's row is held by %s, want A", short(tag))
	}
	if _, paid, err := payRent(newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault), "s3", name, pa, os.Getenv("NOWHERE_WALLET"), nil); err != nil || !paid {
		t.Fatalf("payRent after A->B->A: paid=%v err=%v", paid, err)
	}
	if got := retagOf(t, name, pa); len(got) != 0 {
		t.Errorf("record after the renewal's 200 = %v, want it cleared", shortAll(got))
	}
}

// (1) A recovery back to the passphrase the profile already has moves nothing and must not send itself as prior.
func TestARecoveryToTheSamePassphraseSucceeds(t *testing.T) {
	ledgerFixture(t)
	const name, pass = "samerec", "the only passphrase there is"
	mnemonic := createVault("s3", name, pass)
	if mnemonic == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if sealBare(t, name, pass, "one") {
		t.Fatal("fixture: the first seal was refused")
	}
	if ok := daemonVaultOp(func() error { return recoverVault("s3", name, mnemonic, pass) }); !ok {
		t.Fatal("a recovery to the same passphrase answered BLANK for a correct phrase")
	}
	if got := retagOf(t, name, pass); containsString(got, profileRefV2(name, pass)) {
		t.Errorf("the recovery recorded the profile's own key: %v", shortAll(got))
	}
	if sealBare(t, name, pass, "two") {
		t.Fatal("a seal after a same-passphrase recovery was refused")
	}
}

// armFenceAtTheLease arms the publish fence on fenced the moment a lease made as profile names prior -- i.e. after
// the strict gateway has re-tagged, before any PUT. Reports whether it fired. The fence is lifted at cleanup.
func armFenceAtTheLease(t *testing.T, profile, prior, fenced string) *bool {
	t.Helper()
	armed := new(bool)
	capStoreLeaseSeen = func(req leaseReq) {
		if !*armed && req.Profile == profile && containsString(req.Prior, prior) {
			*armed = armSealFence([]string{fenced}) && sealFenceBlocks(fenced)
		}
	}
	// ...and the process-wide fence sampling goes back to a fresh process's state. pushProfile samples the fence
	// SEQUENCE of this test's NOWHERE_STATE; left set, the next test (a fresh state dir, sequence 0) would see a
	// mismatch and have every publish refused as a delete.
	t.Cleanup(func() {
		liftSealFence([]string{fenced})
		sealFenceHit = false
		clearSealExpectations()
		pushFenceSeq, pushFenceSampled = 0, false
	})
	return armed
}

// (2) A rotation whose publish is refused AFTER its lease landed: the user stays on the old passphrase, so the rows
// that lease moved to the new key must come back, or the old passphrase can never seal again.
func TestARotationRefusedAfterItsLeaseHandsTheRowsBack(t *testing.T) {
	led := ledgerFixture(t)
	const name, p1, p2 = "comprot", "old horse battery staple", "new maple stone cloud lantern"
	if createVault("s3", name, p1) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if sealBare(t, name, p1, "one") {
		t.Fatal("fixture: the first seal was refused")
	}
	oldKey, newKey := profileRefV2(name, p1), profileRefV2(name, p2)
	armed := armFenceAtTheLease(t, newKey, oldKey, newKey)
	var rerr error
	panicked := didPanic(func() { _, rerr = rotateVault("s3", name, p1, p2, nil, true) })
	if !*armed {
		t.Fatal("precondition: no lease named the old key as prior, so nothing was re-tagged")
	}
	if !panicked && rerr == nil {
		t.Fatal("precondition: the rotation reported success although its publish was refused")
	}
	if led.retagCount() == 0 {
		t.Fatal("precondition: the rotation's lease re-tagged nothing")
	}
	liftSealFence([]string{newKey})
	sealFenceHit = false
	capStoreLeaseSeen = nil
	if sealBare(t, name, p1, "after") {
		t.Fatal("the OLD passphrase can no longer seal after a refused rotation: the rows its lease moved to the new " +
			"key were never handed back, so every lease it makes names rows another profile holds")
	}
	if tag := led.tag("ref/" + oldKey); tag != oldKey {
		t.Errorf("the old head's row is held by %s, want the old key", short(tag))
	}
}

// (2) ...and when a PUT fails instead: capFlush panics out of the rotation, and the compensation still runs.
func TestARotationWhosePutFailsAfterItsLeaseHandsTheRowsBack(t *testing.T) {
	fastRetries(t)
	ledgerFixture(t)
	const name, p1, p2 = "comprotput", "old horse battery staple", "new maple stone cloud lantern"
	if createVault("s3", name, p1) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if sealBare(t, name, p1, "one") {
		t.Fatal("fixture: the first seal was refused")
	}
	newKey := profileRefV2(name, p2)
	capStorePutHook = func(key string, _ []byte) error {
		if key == "ref/"+newKey {
			return errTestStoreRefused
		}
		return nil
	}
	panicked := didPanic(func() { _, _ = rotateVault("s3", name, p1, p2, nil, true) })
	capStorePutHook = nil
	if !panicked {
		t.Fatal("precondition: the failed PUT did not fail the rotation")
	}
	if sealBare(t, name, p1, "after") {
		t.Fatal("the OLD passphrase can no longer seal after a rotation whose PUT failed")
	}
}

// (2) The same for a recovery: a device still signed in with the old passphrase must keep sealing after a recovery
// that failed at publish.
func TestARecoveryRefusedAfterItsLeaseHandsTheRowsBack(t *testing.T) {
	ledgerFixture(t)
	const name, p1, p2 = "comprec", "old horse battery staple", "new maple stone cloud lantern"
	mnemonic := createVault("s3", name, p1)
	if mnemonic == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if sealBare(t, name, p1, "one") {
		t.Fatal("fixture: the first seal was refused")
	}
	oldKey, newKey := profileRefV2(name, p1), profileRefV2(name, p2)
	armed := armFenceAtTheLease(t, newKey, oldKey, newKey)
	if ok := daemonVaultOp(func() error { return recoverVault("s3", name, mnemonic, p2) }); ok {
		t.Fatal("precondition: the recovery reported success although its publish was refused")
	}
	if !*armed {
		t.Fatal("precondition: no lease named the old key as prior")
	}
	liftSealFence([]string{newKey})
	sealFenceHit = false
	capStoreLeaseSeen = nil
	if sealBare(t, name, p1, "after") {
		t.Fatal("the old passphrase can no longer seal after a refused recovery: the rows were never handed back")
	}
}

// (3) The recovery-code tombstone goes first, and if it is refused NOTHING ELSE is touched: going on would leave
// the 12 words opening a profile whose bare head is gone.
func TestADeleteStopsWhenTheRecoveryTombstoneIsRefused(t *testing.T) {
	capFixture(t)
	const name, pass = "delrecfirst", "horse battery staple correct"
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	v, isV := openVaultHead("s3", name, pass)
	if !isV || v.RecoveryRef == "" {
		t.Fatal("fixture: no recovery ref")
	}
	rec := v.RecoveryRef
	capStorePostCap = func(req capBoundReq, objURL string) (int, capBoundResp) {
		if req.Ref == "ref/"+rec {
			return http.StatusForbidden, capBoundResp{}
		}
		return http.StatusOK, capBoundResp{URL: objURL}
	}
	var mu sync.Mutex
	tombs := 0
	capStorePutSeen = func(key string, _ http.Header) {
		if strings.HasPrefix(key, "ref/") {
			mu.Lock()
			tombs++
			mu.Unlock()
		}
	}
	var got string
	if didPanic(func() { got = deleteProfile("s3", name, pass) }) {
		t.Fatal("deleteProfile panicked")
	}
	if got != "unverified" {
		t.Errorf("deleteProfile = %q with the recovery tombstone refused, want \"unverified\"", got)
	}
	if tombs != 0 {
		t.Errorf("%d tombstone(s) were written after the recovery-code tombstone was refused -- the bare head goes "+
			"while the 12 words still open the profile", tombs)
	}
	if _, _, ok := resolveKey("s3", name, pass); !ok {
		t.Error("the profile no longer resolves although the delete stopped at its first step")
	}
}

// (3) ...and the verify pass checks the recovery ref itself: a tombstone the store answered 2xx for without writing
// it must not end in "deleted" while the 12 words still open the profile.
func TestADeleteVerifiesTheRecoveryRefItself(t *testing.T) {
	capFixture(t)
	const name, pass = "delrecverify", "horse battery staple correct"
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	v, isV := openVaultHead("s3", name, pass)
	if !isV || v.RecoveryRef == "" {
		t.Fatal("fixture: no recovery ref")
	}
	rec := v.RecoveryRef
	capStorePutStatus = func(key string, _ http.Header) (int, string) {
		if key == "ref/"+rec {
			return http.StatusOK, "" // answered, never written
		}
		return 0, ""
	}
	got := deleteProfile("s3", name, pass)
	if getRef("s3", rec) == "" {
		t.Fatal("fixture: the recovery ref stopped resolving, so this proves nothing")
	}
	if got != "unverified" {
		t.Errorf("deleteProfile = %q while the recovery ref still resolves, want \"unverified\"", got)
	}
}

// (7) A bound cap re-minted as a PLAIN one (an older gateway behind the re-mint) is sent the plain way: the stale
// cap's signed headers belong to the stale URL, and a plain cap takes Content-MD5.
func TestCapPut_ABoundCapReMintedPlainSendsContentMD5(t *testing.T) {
	fastRetries(t)
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	body := []byte("bound first, plain after the re-mint")
	key := "blob/" + hexSHA256(body)
	srv, seen := headerStore(t, func(n int, r *http.Request) (int, string) {
		if r.URL.Path == "/stale" {
			return http.StatusForbidden, sigMismatchBody
		}
		return 0, ""
	})
	if didPanic(func() {
		capPut(key, srv.URL+"/stale", boundHeadersFor(t, key), body, func() (string, map[string]string, error) {
			return srv.URL + "/plain", nil, nil
		})
	}) {
		t.Fatal("the write failed after a re-mint to a plain cap")
	}
	if len(*seen) != 2 {
		t.Fatalf("%d PUT(s), want 2", len(*seen))
	}
	second := (*seen)[1]
	sum := md5.Sum(body)
	if second.Get("Content-MD5") != base64.StdEncoding.EncodeToString(sum[:]) {
		t.Error("the PUT through the plain re-minted cap carried no Content-MD5")
	}
	if hasAmzHeader(second) || second.Get("If-None-Match") != "" {
		t.Errorf("the PUT through the plain re-minted cap still carried the stale cap's signed headers: %v", second)
	}
}

// (7) capFlush's 409 arm withdraws the purchase and re-leases; that retry must still carry the bracket's prior,
// or the rows a credential change rewrites are refused on the retry alone.
func TestCapFlush_The409RetryCarriesPrior(t *testing.T) {
	capFixture(t)
	var mu sync.Mutex
	var seen []leaseReq
	capStoreLeaseStatus = func(req leaseReq) (int, string) {
		mu.Lock()
		defer mu.Unlock()
		seen = append(seen, req)
		switch {
		case req.Free:
			return http.StatusPaymentRequired, `{"error":"free quota exceeded"}`
		case len(seen) == 2:
			return http.StatusConflict, `{"error":"token already spent"}`
		}
		return http.StatusOK, ""
	}
	const name, pass = "retry409", "horse battery staple correct"
	x := strings.Repeat("d4", 32)
	bn := capBegin()
	capSetSession(name, pass, deriveKey(name, pass))
	capSetSessionPrior([]string{x})
	h := postBlob("s3", []byte("a blob for the 409 path"))
	putRef("s3", profileRefV2(name, pass), h)
	if didPanic(func() { capFlush(bn) }) {
		t.Fatal("the flush failed")
	}
	mu.Lock()
	defer mu.Unlock()
	if len(seen) != 3 || seen[2].Free {
		t.Fatalf("%d lease(s), want free 402 -> entitled 409 -> entitled retry", len(seen))
	}
	for i, l := range seen {
		if len(l.Prior) != 1 || l.Prior[0] != x {
			t.Errorf("lease %d carried prior=%v, want the bracket's [x]", i, shortAll(l.Prior))
		}
	}
}

// (2) ...but NOT once the retire pass began: the change is committed whatever the error says -- the new head is
// published, the daemon keeps the new keyguard and moves the session to the new passphrase. Handing the rows back
// then would leave THAT credential unable to seal.
func TestARotationThatFailsWhileRetiringKeepsTheNewCredentialSealing(t *testing.T) {
	fastRetries(t)
	ledgerFixture(t)
	const name, p1, p2 = "compretire", "old horse battery staple", "new maple stone cloud lantern"
	if createVault("s3", name, p1) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	sealBareAndDe(t, name, p1) // a real scope: its re-pointed head is a row the rotation's lease moves to p2
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
	// Every lease from here on: a compensation would be one made AS the old key, naming the new key as prior.
	oldKey, newKey := profileRefV2(name, p1), profileRefV2(name, p2)
	var mu sync.Mutex
	var leases []leaseReq
	capStoreLeaseSeen = func(req leaseReq) { mu.Lock(); leases = append(leases, req); mu.Unlock() }
	panicked := didPanic(func() { _, _ = rotateVault("s3", name, p1, p2, nil, true) })
	capStorePutHook = nil
	capStoreLeaseSeen = nil
	if victim == "" || !panicked || !capRetireBegun {
		t.Fatalf("precondition: want a rotation that failed inside its retire pass (victim=%v panicked=%v retire=%v)",
			victim != "", panicked, capRetireBegun)
	}
	mu.Lock()
	if len(leases) == 0 || leases[0].Profile != newKey || !containsString(leases[0].Prior, oldKey) {
		mu.Unlock()
		t.Fatal("precondition: the rotation's own lease (as the new key, prior = old) was not seen")
	}
	for i, l := range leases[1:] {
		if l.Profile == oldKey && containsString(l.Prior, newKey) {
			t.Errorf("lease %d is a COMPENSATION (as the old key, prior = new) sent after the retire pass had begun: "+
				"the change was committed, and handing its rows back strands the credential the user now holds", i+1)
		}
	}
	mu.Unlock()
	// A SCOPE seal, deliberately: it carries no prior (only the bare seal sends the !bill-retag record), so a row
	// handed back to the old credential is refused here, where a bare seal would quietly re-take it.
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("after"), 0o600); err != nil {
		t.Fatal(err)
	}
	if didPanic(func() { pushProfile("s3", name+"#de", p2, d) }) {
		t.Fatal("the NEW passphrase cannot seal its #de scope after a rotation that committed and then failed while " +
			"retiring: the re-pointed head's row was handed back to the old credential")
	}
}

// readCapGateway serves both read routes: POST /caps answers capsCode (with a cap for every ref it is given unless
// omitRef), and GET /cap?op=read answers with a URL and is counted. dropCaps closes the /caps connection instead --
// a transport error. It records the /caps bodies and every query string the gateway saw.
type readCapGateway struct {
	srv      *httptest.Server
	mu       sync.Mutex
	gets     int
	bodies   []map[string]any
	queries  []string
	capsCode int
	omitRef  bool
	dropCaps bool
}

func newReadCapGateway(t *testing.T) *readCapGateway {
	t.Helper()
	g := &readCapGateway{capsCode: http.StatusOK}
	g.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		g.mu.Lock()
		g.queries = append(g.queries, r.URL.RawQuery)
		g.mu.Unlock()
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/caps":
			if g.dropCaps {
				if hj, ok := w.(http.Hijacker); ok {
					if c, _, err := hj.Hijack(); err == nil {
						c.Close()
					}
				}
				return
			}
			var m map[string]any
			json.NewDecoder(r.Body).Decode(&m)
			g.mu.Lock()
			g.bodies = append(g.bodies, m)
			g.mu.Unlock()
			if g.capsCode != http.StatusOK {
				w.WriteHeader(g.capsCode)
				return
			}
			caps := map[string]string{}
			if !g.omitRef {
				for _, ref := range m["refs"].([]any) {
					caps[ref.(string)] = "http://store/batch"
				}
			}
			json.NewEncoder(w).Encode(capsResp{Caps: caps, TTLSeconds: 900})
		case r.Method == http.MethodGet && r.URL.Path == "/cap" && r.URL.Query().Get("op") == "read":
			g.mu.Lock()
			g.gets++
			g.mu.Unlock()
			json.NewEncoder(w).Encode(capResp{URL: "http://store/single"})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(g.srv.Close)
	return g
}

// A head key is the holder authority since the store binds writes: readCap must carry it in a POST body, never in
// the gateway's URL, on any gateway that has the batch route.
func TestReadCapAsksPostCapsAndNeverTheGet(t *testing.T) {
	g := newReadCapGateway(t)
	head := "ref/" + strings.Repeat("e5", 32)
	u, err := newGatewayClient(g.srv.URL, gwDefault).readCap(head)
	if err != nil || u != "http://store/batch" {
		t.Fatalf("readCap = %q, %v; want the /caps cap", u, err)
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.gets != 0 {
		t.Errorf("readCap made %d GET /cap?op=read request(s) on a gateway that serves /caps -- the head key went "+
			"into a query string, where an access log keeps the profile's holder authority", g.gets)
	}
	if len(g.bodies) != 1 || g.bodies[0]["op"] != "read" {
		t.Fatalf("want one POST /caps {op: read}, got %v", g.bodies)
	}
	if refs, _ := g.bodies[0]["refs"].([]any); len(refs) != 1 || refs[0] != head {
		t.Errorf("POST /caps refs = %v, want exactly the one head key", g.bodies[0]["refs"])
	}
	for _, q := range g.queries {
		if strings.Contains(q, strings.Repeat("e5", 32)) {
			t.Errorf("the head key reached the gateway in a query string: %q", q)
		}
	}
}

// The GET is the fallback for a gateway with NO /caps route -- 404 or 405 -- and for nothing else.
func TestReadCapFallsBackOnlyWhenTheBatchRouteIsMissing(t *testing.T) {
	head := "ref/" + strings.Repeat("f6", 32)
	for _, tc := range []struct {
		name     string
		setup    func(g *readCapGateway)
		fallback bool
	}{
		{"404: no /caps route", func(g *readCapGateway) { g.capsCode = http.StatusNotFound }, true},
		{"405: no POST on /caps", func(g *readCapGateway) { g.capsCode = http.StatusMethodNotAllowed }, true},
		{"500: an unhealthy gateway", func(g *readCapGateway) { g.capsCode = http.StatusInternalServerError }, false},
		{"200 without the ref", func(g *readCapGateway) { g.omitRef = true }, false},
		{"transport error", func(g *readCapGateway) { g.dropCaps = true }, false},
	} {
		g := newReadCapGateway(t)
		tc.setup(g)
		u, err := newGatewayClient(g.srv.URL, gwDefault).readCap(head)
		g.mu.Lock()
		gets := g.gets
		g.mu.Unlock()
		if tc.fallback {
			if err != nil || u != "http://store/single" || gets != 1 {
				t.Errorf("%s: readCap = %q, %v after %d GET(s); want the single-ref GET's cap", tc.name, u, err, gets)
			}
			continue
		}
		if err == nil {
			t.Errorf("%s: readCap returned a cap (%q); want an error", tc.name, u)
		}
		if gets != 0 {
			t.Errorf("%s: readCap fell back to GET /cap?op=read -- a blip or a refusal must never put the head key "+
				"back into a URL", tc.name)
		}
	}
}
