package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261123-22: the WRITE side of the next-login skip notice (backlog row "`pushProfile`'s tombstone skips
// report "Saved" and the next login tells nobody (#119)", h53 #2). T0 proves the inference the decision rests on:
// the vault a sign-in restored survives a passphrase change made on another phone.

// skipNoticeStore is a plain HTTP test store, newHTTPStore's verbs, with its maps exposed for a snapshot and a
// fault switch for one ref's GET.
type skipNoticeStore struct {
	base  string
	mu    sync.Mutex
	blobs map[string][]byte
	refs  map[string]string
	fail  map[string]bool // ref -> GET answers 500
}

func newSkipNoticeStore(t *testing.T) *skipNoticeStore {
	t.Helper()
	s := &skipNoticeStore{blobs: map[string][]byte{}, refs: map[string]string{}, fail: map[string]bool{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		switch {
		case r.Method == "POST" && r.URL.Path == "/blob":
			body, _ := io.ReadAll(r.Body)
			h := sha256.Sum256(body)
			key := hex.EncodeToString(h[:])
			s.blobs[key] = body
			io.WriteString(w, key)
		case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/blob/"):
			if b, ok := s.blobs[strings.TrimPrefix(r.URL.Path, "/blob/")]; ok {
				w.Write(b)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/ref/"):
			body, _ := io.ReadAll(r.Body)
			s.refs[strings.TrimPrefix(r.URL.Path, "/ref/")] = string(body)
		case r.Method == "DELETE" && strings.HasPrefix(r.URL.Path, "/ref/"):
			delete(s.refs, strings.TrimPrefix(r.URL.Path, "/ref/"))
		case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/ref/"):
			k := strings.TrimPrefix(r.URL.Path, "/ref/")
			if s.fail[k] {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			if v, ok := s.refs[k]; ok {
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
	s.base = srv.URL
	return s
}

// snapshot copies the ref map and the blob key set.
func (s *skipNoticeStore) snapshot() (map[string]string, map[string]bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	refs := map[string]string{}
	for k, v := range s.refs {
		refs[k] = v
	}
	blobs := map[string]bool{}
	for k := range s.blobs {
		blobs[k] = true
	}
	return refs, blobs
}

func (s *skipNoticeStore) failGet(ref string, on bool) {
	s.mu.Lock()
	s.fail[ref] = on
	s.mu.Unlock()
}

func (s *skipNoticeStore) ref(k string) (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, ok := s.refs[k]
	return v, ok
}

func (s *skipNoticeStore) dropRef(k string) {
	s.mu.Lock()
	delete(s.refs, k)
	s.mu.Unlock()
}

// skipNoticeWant computes the notice address INSIDE the test, never through skipNoticeRef, so a mutant of that
// function cannot move both sides.
func skipNoticeWant(dk []byte) string {
	mac := hmac.New(sha256.New, dk)
	mac.Write([]byte("nowhere-skip-notice-v1"))
	return hex.EncodeToString(mac.Sum(nil))
}

// skipNoticePhone switches this process to one phone: its own state dir (receipts, seal fence, head-blob cache).
func skipNoticePhone(t *testing.T, dir string) {
	t.Helper()
	t.Setenv("NOWHERE_STATE", dir)
}

func TestSkipNoticeOldVaultSurvivesRotation(t *testing.T) {
	s := newSkipNoticeStore(t)
	base := s.base
	name, oldp, newp := "skn-t0", "skn t0 old passphrase", "skn t0 new passphrase"
	skipNoticePhone(t, t.TempDir())
	createVault(base, name, oldp)
	h0 := getRef(base, headKey(base, name, oldp))
	v0, isV := parseVault(getHeadBlob(base, h0))
	if !isV {
		t.Fatal("setup: the head is not a vault")
	}
	dk0 := openVaultDK(v0, name, oldp)
	if dk0 == nil {
		t.Fatal("setup: the old passphrase does not open the vault")
	}

	if _, err := rotateVault(base, name, oldp, newp, nil, false); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}

	if v, ok := s.ref(profileRefV2(name, oldp)); !ok || strings.TrimSpace(v) != "" {
		t.Fatalf("the old passphrase's bare head is not a tombstone after the rotation: present=%v value=%q", ok, v)
	}
	if _, blobs := s.snapshot(); !blobs[h0] {
		t.Fatal("the rotation removed the old vault blob: the decided fallback (a pointer the changing phone leaves) is needed first")
	}
	vOld, isV := parseVault(getHeadBlob(base, h0))
	if !isV {
		t.Fatal("the old vault blob no longer parses after the rotation")
	}
	if dk := openVaultDK(vOld, name, oldp); !bytes.Equal(dk, dk0) {
		t.Fatal("the old vault blob no longer opens the DK under the old passphrase")
	}
	hNew := getRef(base, headKey(base, name, newp))
	vNew, isV := parseVault(getHeadBlob(base, hNew))
	if !isV {
		t.Fatal("the new head is not a vault")
	}
	if dk := openVaultDK(vNew, name, newp); !bytes.Equal(dk, dk0) {
		t.Fatal("the new passphrase does not open the same DK")
	}
}

// skipNoticeFix is one profile on a test store, phone A (which acts) and phone B (which signed in with the old
// passphrase and skips). B holds the bare receipt for the vault it restored, and a scope receipt naming something
// else, so a mutant that opens the DK from the scope's receipt opens nothing.
type skipNoticeFix struct {
	s                *skipNoticeStore
	base             string
	name, oldp, newp string
	dirA, dirB       string
	h0               string
	dk0              []byte
	src              string
	unitID           string
}

const skipNoticeLabel = "Test Phone 7"

var skipNoticeClock = time.Unix(1_800_000_037, 0)

func newSkipNoticeFix(t *testing.T, name string) *skipNoticeFix {
	t.Helper()
	f := &skipNoticeFix{s: newSkipNoticeStore(t), name: name, oldp: name + " old passphrase", newp: name + " new passphrase",
		dirA: t.TempDir(), dirB: t.TempDir(), src: t.TempDir()}
	f.base = f.s.base
	pinDir := t.TempDir()
	lp := filepath.Join(pinDir, "device-label")
	if err := os.WriteFile(lp, []byte(skipNoticeLabel+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	f.unitID = "0123456789abcdef0123456789abcdef"
	up := filepath.Join(pinDir, "unit-id")
	if err := os.WriteFile(up, []byte(f.unitID+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	oldLP, oldModel, oldUP, oldNow := deviceLabelPath, deviceModelFn, unitIDPath, skipNoticeNow
	deviceLabelPath, unitIDPath = lp, up
	deviceModelFn = func() string { return "Model Seed" }
	skipNoticeNow = func() time.Time { return skipNoticeClock }
	t.Cleanup(func() { deviceLabelPath, deviceModelFn, unitIDPath, skipNoticeNow = oldLP, oldModel, oldUP, oldNow })
	if err := os.WriteFile(filepath.Join(f.src, "note.txt"), []byte("unsaved work"), 0o600); err != nil {
		t.Fatal(err)
	}

	skipNoticePhone(t, f.dirA)
	createVault(f.base, name, f.oldp)
	f.h0 = getRef(f.base, headKey(f.base, name, f.oldp))
	v, isV := parseVault(getHeadBlob(f.base, f.h0))
	if !isV {
		t.Fatal("setup: the head is not a vault")
	}
	if f.dk0 = openVaultDK(v, name, f.oldp); f.dk0 == nil {
		t.Fatal("setup: the vault does not open")
	}
	f.phoneB(t)
	writeRestoreReceipt(profileRefV2(name, f.oldp), f.h0)
	other := sha256.Sum256([]byte("a scope manifest head, not the vault"))
	writeRestoreReceipt(profileRefV2(name+"#de", f.oldp), hex.EncodeToString(other[:]))
	return f
}

func (f *skipNoticeFix) phoneA(t *testing.T) { skipNoticePhone(t, f.dirA) }
func (f *skipNoticeFix) phoneB(t *testing.T) { skipNoticePhone(t, f.dirB) }

// rotate changes the passphrase on phone A, then hands the process back to phone B.
func (f *skipNoticeFix) rotate(t *testing.T) {
	t.Helper()
	f.phoneA(t)
	if _, err := rotateVault(f.base, f.name, f.oldp, f.newp, nil, false); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	f.phoneB(t)
}

// push runs one seal on phone B and fails the test if it reports a refusal.
func (f *skipNoticeFix) push(t *testing.T, profile string) string {
	t.Helper()
	out := captureStdout(t, func() { pushProfile(f.base, profile, f.oldp, f.src) })
	if sealRefused {
		t.Fatalf("push %q: the skip was reported as a refusal\n%s", profile, out)
	}
	return out
}

// checkNotice asserts the notice at want opens under dk0 and the new passphrase's DK, and holds exactly the label
// and the minute -- no unit id and no long hex run.
func (f *skipNoticeFix) checkNotice(t *testing.T, want string) {
	t.Helper()
	val, ok := f.s.ref(want)
	if !ok {
		t.Fatalf("no skip notice at hex(HMAC(dk, %q))", "nowhere-skip-notice-v1")
	}
	pt, ok := unwrap(f.dk0, val)
	if !ok {
		t.Fatal("the notice does not open under the profile DK")
	}
	hNew := getRef(f.base, headKey(f.base, f.name, f.newp))
	vNew, isV := parseVault(getHeadBlob(f.base, hNew))
	if !isV {
		t.Fatal("the new head is not a vault")
	}
	dkNew := openVaultDK(vNew, f.name, f.newp)
	if pt2, ok := unwrap(dkNew, val); !ok || !bytes.Equal(pt2, pt) {
		t.Fatal("the notice does not open under the NEW passphrase's DK")
	}
	var m map[string]any
	if err := json.Unmarshal(pt, &m); err != nil {
		t.Fatalf("the notice is not JSON: %v", err)
	}
	if len(m) != 2 || m["phone"] != skipNoticeLabel || m["time"] != float64(skipNoticeClock.Unix()/60*60) {
		t.Fatalf("the notice must hold exactly {phone %q, time %d}; got %v", skipNoticeLabel, skipNoticeClock.Unix()/60*60, m)
	}
	if strings.Contains(string(pt), f.unitID) || regexp.MustCompile(`[0-9a-fA-F]{16,}`).Match(pt) {
		t.Fatalf("the notice carries a unit id or a long hex run: %s", pt)
	}
	if strings.Contains(string(pt), f.name) {
		t.Fatalf("the notice names the profile: %s", pt)
	}
}

func TestSkipNoticeWrittenAfterRotation(t *testing.T) {
	f := newSkipNoticeFix(t, "skn-t1")
	want := skipNoticeWant(f.dk0)
	f.rotate(t)

	out := f.push(t, f.name+"#de") // the scope exit
	if !strings.Contains(out, "bare head is a TOMBSTONE") {
		t.Fatalf("the scope push did not take the scope tombstone exit:\n%s", out)
	}
	f.checkNotice(t, want)

	f.s.dropRef(want)
	out = f.push(t, f.name) // the bare exit
	if !strings.Contains(out, "tombstoned -> skip") {
		t.Fatalf("the bare push did not take the bare tombstone exit:\n%s", out)
	}
	f.checkNotice(t, want)
}

func TestSkipNoticeNotWrittenAfterDelete(t *testing.T) {
	f := newSkipNoticeFix(t, "skn-t2")
	want := skipNoticeWant(f.dk0)
	f.phoneA(t)
	if got := deleteProfile(f.base, f.name, f.oldp); got != "deleted" {
		t.Fatalf("deleteProfile: %q", got)
	}
	f.phoneB(t)
	refs0, blobs0 := f.s.snapshot()
	for _, p := range []string{f.name + "#de", f.name} {
		out := f.push(t, p)
		if !strings.Contains(out, "push: skip notice not written (deleted)") {
			t.Fatalf("push %q: want the deleted outcome line:\n%s", p, out)
		}
	}
	refs1, blobs1 := f.s.snapshot()
	if _, ok := refs1[want]; ok {
		t.Fatal("a skip after a delete wrote the notice")
	}
	if !reflect.DeepEqual(refs0, refs1) || !reflect.DeepEqual(blobs0, blobs1) {
		t.Fatal("a skip after a delete wrote a new object under the deleted profile")
	}
}

func TestSkipNoticeFailedRecoveryReadWritesNothing(t *testing.T) {
	f := newSkipNoticeFix(t, "skn-t3")
	want := skipNoticeWant(f.dk0)
	v, _ := parseVault(getHeadBlob(f.base, f.h0))
	f.rotate(t)
	f.s.failGet(v.RecoveryRef, true)
	refs0, blobs0 := f.s.snapshot()
	out := f.push(t, f.name)
	if !strings.Contains(out, "push: skip notice not written (could not read)") {
		t.Fatalf("want the could-not-read outcome line:\n%s", out)
	}
	refs1, blobs1 := f.s.snapshot()
	if !reflect.DeepEqual(refs0, refs1) || !reflect.DeepEqual(blobs0, blobs1) {
		t.Fatal("a skip whose recovery read failed stored something")
	}
	f.s.failGet(v.RecoveryRef, false)
	f.push(t, f.name)
	f.checkNotice(t, want)
}

func TestSkipNoticeWrittenWhenVaultNamesNoRecovery(t *testing.T) {
	f := newSkipNoticeFix(t, "skn-t4")
	want := skipNoticeWant(f.dk0)
	v, _ := parseVault(getHeadBlob(f.base, f.h0))
	v.RecoveryRef = ""
	signVault(v, f.dk0)
	h1 := postBlob(f.base, serializeVault(v))
	writeRestoreReceipt(profileRefV2(f.name, f.oldp), h1)
	putRef(f.base, profileRefV2(f.name, f.oldp), "") // the bare head is a tombstone
	out := f.push(t, f.name)
	if !strings.Contains(out, "push: skip notice written") {
		t.Fatalf("want the written outcome line:\n%s", out)
	}
	if _, ok := f.s.ref(want); !ok {
		t.Fatal("a vault naming no recovery entry point did not get the notice")
	}
}

func TestSkipNoticeSkipStaysASkip(t *testing.T) {
	f := newSkipNoticeFix(t, "skn-t5")
	want := skipNoticeWant(f.dk0)
	f.rotate(t)
	refs0, blobs0 := f.s.snapshot()
	scopeOut := f.push(t, f.name+"#de")
	bareOut := f.push(t, f.name)
	if !strings.Contains(scopeOut, "bare head is a TOMBSTONE") || !strings.Contains(scopeOut, "push: skip notice written") {
		t.Fatalf("scope exit: want its tombstone line and the written line:\n%s", scopeOut)
	}
	if !strings.Contains(bareOut, "tombstoned -> skip") || !strings.Contains(bareOut, "push: skip notice written") {
		t.Fatalf("bare exit: want its tombstone line and the written line:\n%s", bareOut)
	}
	if sealRefused || strings.Contains(scopeOut+bareOut, "REFUSED") {
		t.Fatal("a skip became a refusal")
	}
	refs1, blobs1 := f.s.snapshot()
	if !reflect.DeepEqual(blobs0, blobs1) {
		t.Fatal("a skip stored a blob")
	}
	if v, ok := refs1[profileRefV2(f.name, f.oldp)]; !ok || strings.TrimSpace(v) != "" {
		t.Fatal("the old passphrase's bare head is no longer a tombstone")
	}
	if _, ok := refs1[profileRefV2(f.name+"#de", f.oldp)]; ok {
		t.Fatal("the scope skip created a scope ref")
	}
	for k, v := range refs1 {
		if k == want {
			continue
		}
		if old, ok := refs0[k]; !ok || old != v {
			t.Fatalf("a skip stored a ref other than the notice: %s", k[:12])
		}
	}
	if len(refs1) != len(refs0)+1 {
		t.Fatalf("want exactly one new ref (the notice); got %d -> %d", len(refs0), len(refs1))
	}
}

// skipNoticeGateway is a managed-mode gateway with its object map exposed: free reads, a free-first lease arm that
// records every request, and switches that make /quote or /lease fail.
type skipNoticeGateway struct {
	srv       *httptest.Server
	mu        sync.Mutex
	objs      map[string][]byte
	leases    []leaseReq
	puts      []string
	quoteCode int
	leaseCode int
}

func newSkipNoticeGateway(t *testing.T) *skipNoticeGateway {
	t.Helper()
	g := &skipNoticeGateway{objs: map[string][]byte{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/obj", func(w http.ResponseWriter, r *http.Request) {
		k := r.URL.Query().Get("k")
		g.mu.Lock()
		defer g.mu.Unlock()
		if r.Method == http.MethodPut {
			b, _ := io.ReadAll(r.Body)
			g.objs[k] = b
			g.puts = append(g.puts, k)
			return
		}
		b, ok := g.objs[k]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Write(b)
	})
	mux.HandleFunc("/cap", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(capResp{URL: "http://" + r.Host + "/obj?k=" + url.QueryEscape(r.URL.Query().Get("ref"))})
	})
	mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
		g.mu.Lock()
		code := g.quoteCode
		g.mu.Unlock()
		if code != 0 {
			w.WriteHeader(code)
			return
		}
		json.NewEncoder(w).Encode(quoteInfo{Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 604800, EpochsPerLease: 4, CurrentEpoch: 42, FreeGB: 1})
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		g.mu.Lock()
		g.leases = append(g.leases, req)
		code := g.leaseCode
		g.mu.Unlock()
		if code != 0 {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(code)
			io.WriteString(w, `{"error":"refused"}`)
			return
		}
		out := leaseInfo{ThroughEpoch: 99, WriteCaps: map[string]string{}}
		for ref := range req.Refs {
			out.WriteCaps[ref] = "http://" + r.Host + "/obj?k=" + url.QueryEscape(ref)
		}
		json.NewEncoder(w).Encode(out)
	})
	g.srv = httptest.NewServer(mux)
	t.Cleanup(g.srv.Close)
	return g
}

func (g *skipNoticeGateway) reset() {
	g.mu.Lock()
	g.leases, g.puts = nil, nil
	g.mu.Unlock()
}

func (g *skipNoticeGateway) has(k string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	_, ok := g.objs[k]
	return ok
}

func (g *skipNoticeGateway) drop(k string) {
	g.mu.Lock()
	delete(g.objs, k)
	g.mu.Unlock()
}

func TestSkipNoticeCapModeNoSpendNoEscape(t *testing.T) {
	f := newSkipNoticeFix(t, "skn-t6")
	want := skipNoticeWant(f.dk0)
	f.rotate(t)

	// Move the store into a managed-mode gateway, and run phone B against it.
	g := newSkipNoticeGateway(t)
	refs, _ := f.s.snapshot()
	f.s.mu.Lock()
	for k, v := range refs {
		g.objs["ref/"+k] = []byte(v)
	}
	for k, b := range f.s.blobs {
		g.objs["blob/"+k] = append([]byte(nil), b...)
	}
	f.s.mu.Unlock()
	t.Setenv("GATEWAY_URL", g.srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	t.Cleanup(func() { capReadCache = map[string]capEntry{} })
	t.Cleanup(func() { capBracketLeakCheck(t) })
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{Tokens: []Token{{Denom: "1GBmo", Nonce: "skn1", Exp: 1 << 62, Sig: "sig"},
		{Denom: "1GBmo", Nonce: "skn2", Exp: 1 << 62, Sig: "sig"}}}); err != nil {
		t.Fatal(err)
	}
	wallet0, err := os.ReadFile(wpath)
	if err != nil {
		t.Fatal(err)
	}
	holder := profileRefV2(f.name, f.oldp)
	walletHead := "ref/" + profileRefV2(f.name+"#wallet", f.oldp)
	push := func(profile string) string {
		t.Helper()
		out := captureStdout(t, func() { pushProfile("s3", profile, f.oldp, f.src) }) // not under recover: a panic fails the test
		if sealRefused {
			t.Fatalf("push %q: the skip was reported as a refusal\n%s", profile, out)
		}
		if w, _ := os.ReadFile(wpath); !bytes.Equal(w, wallet0) {
			t.Fatalf("push %q: the notice changed the wallet", profile)
		}
		return out
	}

	// (a) the gateway answers: the notice rides the free arm under the skipping phone's identity, spends nothing.
	for _, p := range []string{f.name, f.name + "#de"} {
		g.drop("ref/" + want)
		g.reset()
		out := push(p)
		if !strings.Contains(out, "push: skip notice written") || !g.has("ref/"+want) {
			t.Fatalf("push %q: the notice was not stored in cap mode:\n%s", p, out)
		}
		g.mu.Lock()
		leases, puts := append([]leaseReq(nil), g.leases...), append([]string(nil), g.puts...)
		g.mu.Unlock()
		if len(leases) == 0 {
			t.Fatalf("push %q: no lease", p)
		}
		for _, l := range leases {
			if l.Profile != holder || len(l.Tokens)+len(l.BlindTokens) != 0 {
				t.Fatalf("push %q: the notice lease is not a token-free lease under the skipping phone's profile: profile=%v tokens=%d",
					p, l.Profile == holder, len(l.Tokens)+len(l.BlindTokens))
			}
		}
		for _, k := range puts {
			if k == walletHead {
				t.Fatalf("push %q: the notice flush published a #wallet head", p)
			}
		}
	}

	// (b) /quote fails, (c) /lease is refused: no panic, no refusal, no notice, the wallet untouched.
	for _, c := range []struct{ quote, lease int }{{http.StatusServiceUnavailable, 0}, {0, http.StatusForbidden}} {
		g.drop("ref/" + want)
		g.mu.Lock()
		g.quoteCode, g.leaseCode = c.quote, c.lease
		g.mu.Unlock()
		out := push(f.name)
		if g.has("ref/" + want) {
			t.Fatalf("quote=%d lease=%d: the notice landed anyway", c.quote, c.lease)
		}
		if !strings.Contains(out, "push: skip notice not written (could not store)") {
			t.Fatalf("quote=%d lease=%d: want the could-not-store line:\n%s", c.quote, c.lease, out)
		}
		capBracketLeakCheck(t)
	}
}
