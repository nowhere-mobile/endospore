package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// capStoreRelease answers POST /release with the request body as received (NWP-20261029-10): the status and the
// body to reply with. nil = 404, a gateway that predates the endpoint, so every test that never sets it is unchanged.
var capStoreRelease func(body []byte) (int, string)

// capStoreGetSeen, when non-nil, is called by mockCapStore for every /obj GET (any non-PUT) with its key, before
// the lookup (NWP-20261112-26): a cap-mode read is one /cap fetch plus one presigned GET of /obj?k=<key>, so this
// is where a test counts the store reads a path really makes.
var capStoreGetSeen func(k string)

// mockCapStore stands in for the gateway's /cap endpoint + the presigned object store it points at: GET
// /cap?ref=K returns a URL to /obj?k=K, and /obj serves (GET) / accepts (PUT) the bytes for that key. It
// mirrors the real flow (cap fetch -> presigned GET/PUT) so the device's cap-mode I/O is exercised without
// any store credentials. Returns the server + its backing object map (so tests can seed/inspect objects).
func mockCapStore(t *testing.T) (*httptest.Server, map[string][]byte, *sync.Mutex) {
	t.Helper()
	capStorePutHook = nil // never inherit a hook from another test
	capStoreLeasePresent = nil
	capStoreTokensPresented = 0
	capStorePutSeen, capStorePutStatus, capStoreLeaseSeen, capStoreCapHeaders, capStorePostCap = nil, nil, nil, nil, nil
	capStoreLeaseStatus, capStoreRelease, capStoreGetSeen = nil, nil, nil
	capStoreQuote, capStoreIgnoresExpire = nil, false
	t.Cleanup(func() {
		capStorePutHook, capStoreLeasePresent = nil, nil
		capStorePutSeen, capStorePutStatus, capStoreLeaseSeen, capStoreCapHeaders, capStorePostCap = nil, nil, nil, nil, nil
		capStoreLeaseStatus, capStoreRelease, capStoreGetSeen = nil, nil, nil
		capStoreQuote, capStoreIgnoresExpire = nil, false
		capBracketLeakCheck(t) // NWP-20261009-07: a leaked bracket fails this test instead of wedging the rest
	})
	objs := map[string][]byte{}
	var mu sync.Mutex
	mux := http.NewServeMux()
	mux.HandleFunc("/obj", func(w http.ResponseWriter, r *http.Request) {
		k := r.URL.Query().Get("k")
		switch r.Method {
		case http.MethodPut:
			b, _ := io.ReadAll(r.Body)
			// NWP-20261009-02: what the PUT carried, and a way to answer it like a store that binds caps.
			if capStorePutSeen != nil {
				capStorePutSeen(k, r.Header.Clone())
			}
			if capStorePutStatus != nil {
				if code, body := capStorePutStatus(k, r.Header); code != 0 {
					w.WriteHeader(code)
					_, _ = io.WriteString(w, body)
					return
				}
			}
			// NWP-20260915-14: the ONE place that sees what this store was actually asked to write, in
			// arrival order. capFlush publishes pointers in two passes now and the property under test is
			// an ORDER ("no pointer is retired before every other has been published"), which nothing else
			// in the harness can observe -- objs is a map and reports only the end state.
			if capStorePutHook != nil {
				if err := capStorePutHook(k, b); err != nil {
					w.WriteHeader(http.StatusInternalServerError)
					return
				}
			}
			mu.Lock()
			objs[k] = b
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
		default:
			if capStoreGetSeen != nil {
				capStoreGetSeen(k)
			}
			mu.Lock()
			b, ok := objs[k]
			mu.Unlock()
			if !ok {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			// ServeContent honors Range (206 + Content-Range) like a real S3/R2 object -> exercises capSize's
			// size-only ranged GET (#87); a plain full GET (capGet) still gets the whole body.
			http.ServeContent(w, r, "", time.Time{}, bytes.NewReader(b))
		}
	})
	mux.HandleFunc("/cap", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			// NWP-20261009-02: POST /cap, the bound write re-mint. Today's gateway has no such route and
			// answers 405, which is what the device's GET fallback is for -- so that is the default here, and
			// a test that wants the new gateway installs capStorePostCap.
			if capStorePostCap == nil {
				w.WriteHeader(http.StatusMethodNotAllowed)
				return
			}
			var req capBoundReq
			json.NewDecoder(r.Body).Decode(&req)
			if !priorShapeOK(req.Profile, req.Prior) { // NWP-20261009-02: the gateway's rule, always on
				w.WriteHeader(http.StatusBadRequest)
				_, _ = io.WriteString(w, `{"error":"bad prior"}`)
				return
			}
			code, resp := capStorePostCap(req, "http://"+r.Host+"/obj?k="+url.QueryEscape(req.Ref))
			w.WriteHeader(code)
			if code == http.StatusOK {
				json.NewEncoder(w).Encode(resp)
			}
			return
		}
		ref := r.URL.Query().Get("ref")
		json.NewEncoder(w).Encode(capResp{URL: "http://" + r.Host + "/obj?k=" + url.QueryEscape(ref)})
	})
	// Billing endpoints (so write tests can fund a wallet + batch-lease): quote, dev faucet, lease-with-caps.
	mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
		q := quoteInfo{Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 604800, EpochsPerLease: 4, CurrentEpoch: 42}
		if capStoreQuote != nil {
			capStoreQuote(w.Header(), &q) // NWP-20261010-02: the Date and epoch_seconds the export epoch is read from
		}
		json.NewEncoder(w).Encode(q)
	})
	mux.HandleFunc("POST /release", func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		if capStoreRelease == nil {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		code, body := capStoreRelease(b)
		w.WriteHeader(code)
		_, _ = io.WriteString(w, body)
	})
	var counter int
	mux.HandleFunc("POST /tokens", func(w http.ResponseWriter, r *http.Request) {
		var req tokensReq
		json.NewDecoder(r.Body).Decode(&req)
		out := tokensResp{}
		for i := 0; i < req.Count; i++ {
			counter++
			out.Tokens = append(out.Tokens, Token{Denom: "1GBmo", Nonce: "n" + strconv.Itoa(counter), Exp: 1 << 62, Sig: "sig"})
		}
		json.NewEncoder(w).Encode(out)
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		if capStoreLeaseSeen != nil {
			capStoreLeaseSeen(req) // NWP-20261009-02: the lease body as the gateway read it
		}
		// NWP-20261009-02: the gateway's `prior` rule, ALWAYS on, so a client that sends its own profile (or a
		// malformed or over-long list) fails every test that leases rather than passing against a lax fake.
		if !priorShapeOK(req.Profile, req.Prior) {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = io.WriteString(w, `{"error":"bad prior"}`)
			return
		}
		// NWP-20261010-02: the gateway's `expire` rule, ALWAYS on unless the test models an older gateway, so a key
		// and a proof that do not certify each other fail every test that sends one -- and every 200 below names the
		// entries in expire_applied, as the gateway's all-or-nothing write does.
		var applied []string
		if !capStoreIgnoresExpire && len(req.Expire) > 0 {
			if why := expireShapeRefusal(req); why != "" {
				w.WriteHeader(http.StatusBadRequest)
				_, _ = io.WriteString(w, `{"error":"`+why+`"}`)
				return
			}
			for ref := range req.Expire {
				applied = append(applied, ref)
			}
			sort.Strings(applied)
		}
		var total int64
		for _, sz := range req.Refs {
			total += sz
		}
		caps := map[string]string{}
		var capHdrs map[string]map[string]string
		for ref := range req.Refs {
			caps[ref] = "http://" + r.Host + "/obj?k=" + url.QueryEscape(ref) // write cap -> the same object store
			if capStoreCapHeaders != nil && req.BoundCaps {
				if h := capStoreCapHeaders(ref); len(h) > 0 { // NWP-20261009-02: a gateway that binds blob caps
					if capHdrs == nil {
						capHdrs = map[string]map[string]string{}
					}
					capHdrs[ref] = h
				}
			}
		}
		// NWP-20261009-02: a test's own verdict on this lease (a holder ledger, a scripted 402/409). 0 = the
		// default handling below; 200 = grant without the quota or token checks; anything else is the reply.
		if capStoreLeaseStatus != nil {
			if code, body := capStoreLeaseStatus(req); code == http.StatusOK {
				json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: 99, WriteCaps: caps, CapHeaders: capHdrs, Present: capStoreLeasePresent, ExpireApplied: applied})
				return
			} else if code != 0 {
				w.WriteHeader(code)
				_, _ = io.WriteString(w, body)
				return
			}
		}
		if req.Free { // free tier (#54): no tokens, metered against a per-profile quota (5 GiB here)
			if req.Profile == "" {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			if total > 5*giB { // over quota -> device must fall back to paid
				w.WriteHeader(http.StatusPaymentRequired)
				return
			}
			json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: 99, Spent: 0, WriteCaps: caps, CapHeaders: capHdrs, Present: capStoreLeasePresent, ExpireApplied: applied})
			return
		}
		// NWP-20260915-17: the one place a test can see that tokens were PRESENTED to the gateway. A
		// credential change must move money without spending any, and the harm of spending an
		// unattributable wallet is entirely server-side -- the nonces are burned for every profile at
		// once -- so nothing on disk reveals it.
		capStoreTokensPresented += len(req.Tokens)
		owed := int(math.Ceil(float64(total) / float64(giB)))
		if owed == 0 {
			owed = 1
		}
		if len(req.Tokens) < owed {
			w.WriteHeader(http.StatusPaymentRequired)
			return
		}
		json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: 46, Spent: owed, WriteCaps: caps, CapHeaders: capHdrs, Present: capStoreLeasePresent, ExpireApplied: applied})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, objs, &mu
}

// TestCapSizeRanged (#87): in cap mode, blobSize must size a blob via a 1-byte ranged GET (Content-Range),
// NOT by downloading the whole chunk. Assert capSize + blobSize return the true size against a Range-capable
// mock store.
func TestCapSizeRanged(t *testing.T) {
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	if !capMode() {
		t.Fatal("expected cap mode")
	}
	data := bytes.Repeat([]byte("blobdata "), 5000) // 40000 bytes
	mu.Lock()
	objs["blob/deadbeef"] = data
	mu.Unlock()
	if got := capSize("blob/deadbeef"); got != int64(len(data)) {
		t.Fatalf("capSize = %d, want %d", got, len(data))
	}
	if got := blobSize("s3", "deadbeef"); got != int64(len(data)) {
		t.Fatalf("blobSize(cap) = %d, want %d", got, len(data))
	}
	if capSize("blob/missing") != -1 {
		t.Fatal("capSize of a missing blob should be -1 (absent -> blobSize falls back)")
	}
}

// TestCapModeWrites (DIA-20260627, P3): in cap mode a bracketed batch of postBlob/putRef buffers, and a
// single capFlush batch-leases (spends one token) + PUTs every object via its write cap -- no store creds.
func TestCapModeWrites(t *testing.T) {
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	capReadCache = map[string]capEntry{}

	gw := newGatewayClient(srv.URL, gwDefault)
	toks, err := gw.buyFaucet(10)
	if err != nil {
		t.Fatal(err)
	}
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}

	// a write outside a bracket must fail loudly (never a silent / unpaid write).
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("cap-mode write outside capBegin should fail")
			}
		}()
		postBlob("s3", []byte("unbracketed"))
	}()

	// bracketed batch: two blobs + a pointer, one flush.
	bn := capBegin()
	h1 := postBlob("s3", []byte("chunk one"))
	h2 := postBlob("s3", bytes.Repeat([]byte("two "), 500))
	putRef("s3", "alice", h1)
	capFlush(bn)

	mu.Lock()
	defer mu.Unlock()
	if !bytes.Equal(objs["blob/"+h1], []byte("chunk one")) || objs["blob/"+h2] == nil {
		t.Fatal("blobs were not written via caps")
	}
	if strings.TrimSpace(string(objs["ref/alice"])) != h1 {
		t.Fatalf("pointer not written via cap: %q", objs["ref/alice"])
	}
	if after, _ := loadWallet(wpath); after.balance() != 9 {
		t.Fatalf("expected one token spent on the batch lease, balance=%d", after.balance())
	}
}

// TestCapModeCreateVault (DIA-20260627, P3 integration): createVault brackets its writes internally, so in
// cap mode a brand-new vault is written entirely via caps (no store creds) for one batch payment, and the
// head pointer reads back via a free cap. (Exercises the bracket + the read+write round-trip end to end.)
func TestCapModeCreateVault(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(10)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}

	name, pass := "capnew", "brand new managed pass"
	createVault("s3", name, pass) // brackets internally -> writes the vault via caps + spends

	if getRef("s3", profileRefV2(name, pass)) == "" {
		t.Fatal("createVault in cap mode did not publish the head pointer via a cap")
	}
	// #133 capacity model: a brand-new (tiny) vault sits inside the free quota, so even a funded wallet
	// spends NOTHING on create -- tokens buy capacity beyond the free tier, not write events.
	if after, _ := loadWallet(wpath); after.balance() != 10 {
		t.Fatalf("createVault under the free quota must spend nothing, balance=%d", after.balance())
	}
}

// TestCapModeReads (DIA-20260627, P1): with GATEWAY_URL set and no S3 creds, getBlob/getRef route through
// free read caps -- the device reads with NO store credentials, and a missing ref reads as absent (blind).
func TestCapModeReads(t *testing.T) {
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	capReadCache = map[string]capEntry{}

	if !capMode() {
		t.Fatal("capMode should be true with GATEWAY_URL set and no S3 creds")
	}

	data := bytes.Repeat([]byte("cap blob "), 1000)
	mu.Lock()
	objs["blob/abc123"] = data
	objs["ref/alice"] = []byte("headhash999\n")
	mu.Unlock()

	if got := getBlob("s3", "abc123"); !bytes.Equal(got, data) {
		t.Fatalf("getBlob via cap: %d bytes, want %d", len(got), len(data))
	}
	if got := getRef("s3", "alice"); got != "headhash999" {
		t.Fatalf("getRef via cap = %q, want headhash999", got)
	}
	// a wrong/unknown ref must read as absent -> blind login.
	if got := getRef("s3", "nobody"); got != "" {
		t.Fatalf("missing ref should read empty, got %q", got)
	}
}

// TestCapModeReadRetriesBlip (#70): a transient failure on the gateway /cap fetch OR the presigned GET (the
// "software caused connection abort" that used to dump a mid-restore login back to the gate) is RETRIED, so a
// single blip costs a retry instead of the whole restore. A persistently-absent key is still a definitive miss
// (blind login), never spun on. Blips are simulated by hijacking + closing the connection (a real transport
// error, like a Wi-Fi drop), not a clean 5xx.
func TestCapModeReadRetriesBlip(t *testing.T) {
	old := s3RetryBase
	s3RetryBase = time.Millisecond // shrink the backoff so the test is fast
	defer func() { s3RetryBase = old }()

	objs := map[string][]byte{"blob/x": bytes.Repeat([]byte("y"), 4096)}
	var mu sync.Mutex
	var capHits, objHits int
	drop := func(w http.ResponseWriter) {
		hj, ok := w.(http.Hijacker)
		if !ok {
			return
		}
		c, _, err := hj.Hijack()
		if err == nil {
			c.Close() // slam the connection -> the client's http.Get returns a transport error
		}
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/cap", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		capHits++
		n := capHits
		mu.Unlock()
		if n == 1 { // the very first cap fetch blips
			drop(w)
			return
		}
		ref := r.URL.Query().Get("ref")
		json.NewEncoder(w).Encode(capResp{URL: "http://" + r.Host + "/obj?k=" + url.QueryEscape(ref)})
	})
	mux.HandleFunc("/obj", func(w http.ResponseWriter, r *http.Request) {
		k := r.URL.Query().Get("k")
		mu.Lock()
		b, ok := objs[k]
		objHits++
		n := objHits
		mu.Unlock()
		if !ok {
			w.WriteHeader(http.StatusNotFound) // persistently absent -> a real miss, never a blip
			return
		}
		if n <= 2 { // the first two object GETs blip mid-flight
			drop(w)
			return
		}
		w.Write(b)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	capReadCache = map[string]capEntry{}

	// 1 cap blip + 2 object blips, then success -> getBlob must still return the bytes (restore survives).
	if got := getBlob("s3", "x"); !bytes.Equal(got, objs["blob/x"]) {
		t.Fatalf("getBlob after transient blips: %d bytes, want %d", len(got), len(objs["blob/x"]))
	}
	// a genuinely-absent ref still reads empty (blind login), not a loud failure from the retry loop.
	if got := getRef("s3", "ghost"); got != "" {
		t.Fatalf("absent ref should read empty after retries, got %q", got)
	}
}

// TestCapModeRotate (DIA-20260704-35d): change-passphrase (rotateVault) is a STORE WRITE, so in managed
// (cap) mode it MUST ride a capBegin/capFlush bracket. It had none -> a cap-mode change-passphrase hit an
// unbracketed postBlob and failed, and the gate showed a FALSE "wrong passphrase" (on-device, real cap-mode
// profile). This walks createVault -> rotate -> the new pass opens, the old doesn't, all in cap mode.
func TestCapModeRotate(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	t.Setenv("NOWHERE_STATE", t.TempDir()) // anchor/receipt local state
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}

	const name, oldpass, newpass = "caprot", "old horse battery staple", "new maple stone cloud lantern"
	if createVault("s3", name, oldpass) == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	if _, _, ok := resolveKey("s3", name, oldpass); !ok {
		t.Fatal("pre-rotate: the old passphrase should open the vault")
	}
	if _, err := rotateVault("s3", name, oldpass, newpass, nil, true); err != nil { // the bug: no cap bracket -> this failed
		t.Fatalf("cap-mode rotateVault: %v", err)
	}
	if _, _, ok := resolveKey("s3", name, newpass); !ok {
		t.Fatal("post-rotate: the NEW passphrase should open the vault")
	}
	if _, _, ok := resolveKey("s3", name, oldpass); ok {
		t.Fatal("post-rotate: the OLD passphrase must NOT open the vault")
	}
}

// TestCapModeFoldWallet (DIA-20260627, device fold): with a session set, capFlush re-seals the POST-spend
// wallet into the SAME lease as the data, so the wallet is written for free (rounds in) and roams reflecting
// the post-spend balance -- breaking the wallet self-reference without a free-write primitive.
func TestCapModeFoldWallet(t *testing.T) {
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(10)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}

	name, pass := "foldu", "fold the wallet free"
	dk := deriveKey(name, pass)
	bn := capBegin()
	capSetSession(name, pass, dk)
	h := postBlob("s3", bytes.Repeat([]byte("d"), 2000)) // some data
	putRef("s3", profileRefV2(name, pass), h)            // a head pointer
	capFlush(bn)

	mu.Lock()
	defer mu.Unlock()
	ptr := objs["ref/"+profileRefV2(name+"#wallet", pass)] // #80: the fold migrates the wallet to its v2 ref
	if ptr == nil {
		t.Fatal("wallet pointer was not folded into the seal flush")
	}
	wblob := objs["blob/"+strings.TrimSpace(string(ptr))]
	if wblob == nil {
		t.Fatal("wallet blob not written via the fold")
	}
	// #133 capacity model: the whole seal sits inside the free quota -> the free lease carries it and the
	// funded wallet is untouched (the old paid-first flow burned a token per seal here).
	if after, _ := loadWallet(wpath); after.balance() != 10 {
		t.Fatalf("seal under the free quota must spend nothing, balance=%d", after.balance())
	}
	// the roamed wallet decodes to the same (unspent) balance.
	var rw Wallet
	if err := json.Unmarshal(unseal(dk, wblob), &rw); err != nil {
		t.Fatalf("roamed wallet did not unseal: %v", err)
	}
	if rw.balance() != 10 {
		t.Fatalf("roamed wallet balance %d, want 10 (unspent)", rw.balance())
	}
}

// TestCapModeFreeTier (#54): a session with NO wallet credit seals via the FREE tier -- capFlush falls back
// to a token-less leaseFree (metered per profileRef), writes every object via the returned caps, spends
// nothing, and still folds the wallet so it roams. This is what lets a credential-less free user roam.
func TestCapModeFreeTier(t *testing.T) {
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	blobCache = nil // reset the cross-test "known present" set; another test wrote the same content
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, wpath) // NWP-20261013-20: a session whose restore landed
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil { // empty wallet -> a free user (no tokens at all)
		t.Fatal(err)
	}

	name, pass := "freeu", "no credit just the free tier"
	dk := deriveKey(name, pass)
	bn := capBegin()
	capSetSession(name, pass, dk)
	h := postBlob("s3", bytes.Repeat([]byte("d"), 2000)) // ~2 KB of data, well under the 5 GiB free quota
	putRef("s3", profileRefV2(name, pass), h)
	capFlush(bn) // no tokens -> free fallback -> writes via free caps

	mu.Lock()
	defer mu.Unlock()
	if objs["blob/"+h] == nil {
		t.Fatal("free-tier data blob was not written via a free cap")
	}
	if objs["ref/"+profileRefV2(name, pass)] == nil {
		t.Fatal("free-tier head pointer was not written")
	}
	if after, _ := loadWallet(wpath); after.balance() != 0 {
		t.Fatalf("free lease must spend nothing, balance=%d", after.balance())
	}
	if objs["ref/"+profileRefV2(name+"#wallet", pass)] == nil { // #80: folded at the wallet's v2 ref
		t.Fatal("wallet was not folded into the free lease (won't roam)")
	}
}

// TestCapModeFreeOverQuota (#54): when the free quota is exceeded AND there's no credit, capFlush surfaces
// errInsufficientCredit (mapped to NOCREDIT by the handlers) rather than writing a half-paid seal.
func TestCapModeFreeOverQuota(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/cap", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(capResp{URL: "http://" + r.Host + "/obj?k=" + url.QueryEscape(r.URL.Query().Get("ref"))})
	})
	mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(quoteInfo{Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 604800, EpochsPerLease: 4, CurrentEpoch: 42})
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		w.WriteHeader(http.StatusPaymentRequired) // free over-quota AND no tokens -> 402 either way
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	blobCache = nil
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}

	name, pass := "overu", "free quota blown"
	bn := capBegin()
	capSetSession(name, pass, deriveKey(name, pass))
	postBlob("s3", []byte("data over the free quota"))
	putRef("s3", profileRefV2(name, pass), "deadbeef")
	var got any
	func() {
		defer func() { got = recover() }()
		capFlush(bn)
	}()
	// errors.Is, not ==: since NWP-20260904-09 a 402 with a body panics errInsufficientCredit WRAPPED with the
	// gateway's reason (creditRefused); this mock sends no body, so the bare sentinel comes back, but the
	// contract the handlers rely on is the errors.Is one.
	if e, _ := got.(error); !errors.Is(e, errInsufficientCredit) {
		t.Fatalf("over-quota free flush should panic errInsufficientCredit, got %v", got)
	}
}

// TestStoreConfiguredCapMode (DIA-20260627, P4): a managed device (GATEWAY_URL set, no S3 creds) is a fully
// configured, login-able store -- the gateway IS the store -- even though it holds no S3 credentials.
func TestStoreConfiguredCapMode(t *testing.T) {
	t.Setenv("S3_ENDPOINT", "")
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("GATEWAY_URL", "https://api.nowhere.mobile")
	if !capMode() {
		t.Fatal("capMode should be true (gateway set, no creds)")
	}
	if !storeConfigured() {
		t.Fatal("storeConfigured should be true in cap mode")
	}
	// neither a gateway nor creds -> not configured (gate -> Settings).
	t.Setenv("GATEWAY_URL", "")
	if storeConfigured() {
		t.Fatal("storeConfigured should be false with no gateway and no creds")
	}
}

// TestCapFlushAtomicHead (#45): a FAILED blob PUT must abort the flush BEFORE the head pointer is written, so
// a partial / crashed seal can NEVER clobber a good head (the a/a1234 data-loss bug). Pointers are PUT last.
func TestCapFlushAtomicHead(t *testing.T) {
	objs := map[string][]byte{}
	var mu sync.Mutex
	var failKey string
	mux := http.NewServeMux()
	mux.HandleFunc("/obj", func(w http.ResponseWriter, r *http.Request) {
		k := r.URL.Query().Get("k")
		if r.Method == http.MethodPut {
			mu.Lock()
			fk := failKey
			mu.Unlock()
			if k == fk {
				w.WriteHeader(http.StatusInternalServerError) // simulate a mid-flush write failure / crash
				return
			}
			b, _ := io.ReadAll(r.Body)
			mu.Lock()
			objs[k] = b
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	})
	mux.HandleFunc("/cap", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(capResp{URL: "http://" + r.Host + "/obj?k=" + url.QueryEscape(r.URL.Query().Get("ref"))})
	})
	mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(quoteInfo{Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 604800, EpochsPerLease: 4, CurrentEpoch: 42})
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		caps := map[string]string{}
		for ref := range req.Refs {
			caps[ref] = "http://" + r.Host + "/obj?k=" + url.QueryEscape(ref)
		}
		json.NewEncoder(w).Encode(leaseInfo{ThroughEpoch: 46, Spent: 1, WriteCaps: caps})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	var toks []Token
	for i := 0; i < 10; i++ {
		toks = append(toks, Token{Denom: "1GBmo", Nonce: "n" + strconv.Itoa(i), Exp: 1 << 62, Sig: "s"})
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}

	bn := capBegin()
	postBlob("s3", []byte("good blob"))
	h2 := postBlob("s3", []byte("doomed blob"))
	putRef("s3", "head", h2) // the head pointer -- must NOT be written when a blob PUT fails
	mu.Lock()
	failKey = "blob/" + h2
	mu.Unlock()
	func() {
		defer func() { _ = recover() }() // the failing blob PUT calls fail() -> panic; expected
		capFlush(bn)
	}()

	mu.Lock()
	defer mu.Unlock()
	if _, ok := objs["ref/head"]; ok {
		t.Fatal("head pointer was written despite a failed blob PUT -- a partial seal could clobber a good head")
	}
}
