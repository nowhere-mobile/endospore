package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

// NWP-20261113-12 (Q036, docs/product-decisions.md, 2026-10-20). Backlog row "The restore path re-reads the SAME ref
// object up to six times per invocation". THE RULE: within ONE restore invocation the bare head is read from the store
// once -- profileDeleted's live read is handed to scopeOwnerLocked and to the vault head lookup through a
// per-invocation, hits-only refProbeMemo -- and no value crosses a process or outlives the invocation.
//
// Baseline (lynx 2026102201, 2026-10-23, S3): the vault restore logged reads=2x/1keys and each of #de, #sys, #media,
// #apps, #keys reads=5x/3keys (three reads of the bare ref, the vault blob, the scope's own ref). These tests count the
// same reads two ways: per key on a plain HTTP store (refProbe there is a GET probe followed by a getRef, so one read of
// a ref is one probe+value PAIR, two GETs), and with the device's own traceDistinct counter in cap mode.
//
// Every test sets NOWHERE_STATE: without it headBlobCacheDir() is "" and the head-blob cache is inert, so every blob
// count would be vacuous (login_head_reads_test.go).

// bhrStore is countingStore's shape counting GETs PER KEY and keeping their arrival order, so a test can pin exactly
// which refs a restore read and in what sequence.
type bhrStore struct {
	base string
	mu   sync.Mutex
	gets []string // "ref/<r>" / "blob/<h>", in arrival order
}

func newBHRStore(t *testing.T) *bhrStore {
	t.Helper()
	s := &bhrStore{}
	blobs := map[string][]byte{}
	refs := map[string]string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		p := strings.TrimPrefix(r.URL.Path, "/")
		switch {
		case r.Method == "POST" && p == "blob":
			body, _ := io.ReadAll(r.Body)
			h := sha256.Sum256(body)
			key := hex.EncodeToString(h[:])
			blobs[key] = body
			io.WriteString(w, key)
		case r.Method == "PUT" && strings.HasPrefix(p, "ref/"):
			body, _ := io.ReadAll(r.Body)
			refs[strings.TrimPrefix(p, "ref/")] = string(body) // "" is a delete tombstone: it EXISTS, empty
		case r.Method == "GET" && strings.HasPrefix(p, "blob/"):
			s.gets = append(s.gets, p)
			if b, ok := blobs[strings.TrimPrefix(p, "blob/")]; ok {
				w.Write(b)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		case r.Method == "GET" && strings.HasPrefix(p, "ref/"):
			s.gets = append(s.gets, p)
			if v, ok := refs[strings.TrimPrefix(p, "ref/")]; ok {
				io.WriteString(w, v)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	s.base = srv.URL
	return s
}

func (s *bhrStore) reset() {
	s.mu.Lock()
	s.gets = nil
	s.mu.Unlock()
}

func (s *bhrStore) seq() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.gets...)
}

func (s *bhrStore) reads(key string) int {
	n := 0
	for _, k := range s.seq() {
		if k == key {
			n++
		}
	}
	return n
}

// bhrPlainEnv makes the store a plain HTTP one (not cap mode) with a live head-blob cache.
func bhrPlainEnv(t *testing.T) *bhrStore {
	t.Helper()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_MULTIDEVICE", "")
	t.Setenv("NOWHERE_UNIT_SRC", "")
	t.Setenv("NOWHERE_SE_SECRET", "")
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	return newBHRStore(t)
}

// bhrRestoreHead is the restore case's guard+resolve sequence (main.go `case "restore":` up to traceDistinctEnd), with
// ONE memo for the invocation as the case makes it. TestBareHeadReads_RestoreCaseUsesOneMemo pins that the case
// itself makes these calls, in this order, with one memo.
func bhrRestoreHead(base, profile, pass string) (deleted, locked bool, head string, ok bool) {
	memo := refProbeMemo{}
	if profileDeletedWith(base, profile, pass, memo) {
		return true, false, "", false
	}
	if l, u := scopeOwnerLockedWith(base, profile, pass, memo); l || u {
		return false, true, "", false
	}
	_, _, head, ok = resolveKeyHeadForLoginWith(base, profile, pass, memo)
	return false, false, head, ok
}

// T0: the restore case itself makes one memo and hands it to all three calls, in the order the tests reproduce. The
// counting tests below exercise bhrRestoreHead; this is what ties them to the production case.
func TestBareHeadReads_RestoreCaseUsesOneMemo(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "\tcase \"restore\":")
	if i < 0 {
		t.Fatal("no restore case in main.go")
	}
	j := strings.Index(src[i:], "traceDistinctEnd()")
	if j < 0 {
		t.Fatal("the restore case does not close its traceDistinct window")
	}
	c := src[i : i+j]
	if n := strings.Count(c, "memo := refProbeMemo{}"); n != 1 {
		t.Errorf("the restore case makes %d memo(s) before traceDistinctEnd, want exactly 1", n)
	}
	last := -1
	for _, call := range []string{
		"profileDeletedWith(base, profile, pass, memo)",
		"scopeOwnerLockedWith(base, profile, pass, memo)",
		"resolveKeyHeadForLoginWith(base, profile, pass, memo)",
	} {
		k := strings.Index(c, call)
		if k < 0 {
			t.Errorf("the restore case does not call %s", call)
			continue
		}
		if k < last {
			t.Errorf("%s is out of order: the guards come before the resolve", call)
		}
		last = k
	}
	for _, old := range []string{"profileDeleted(base, profile, pass)", "scopeOwnerLocked(base, profile, pass)",
		"resolveKeyHeadForLogin(base, profile, pass)"} {
		if strings.Contains(c, old) {
			t.Errorf("the restore case still calls the memo-less %s", old)
		}
	}
	// Never a package global: no production file other than main.go's restore case makes a memo.
	files, _ := filepath.Glob("*.go")
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		fb, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		n := strings.Count(string(fb), "refProbeMemo{}")
		if f == "main.go" {
			n -= strings.Count(c, "refProbeMemo{}")
		}
		if n != 0 {
			t.Errorf("%s makes %d refProbeMemo outside the restore case: the memo is per invocation, never shared", f, n)
		}
	}
}

// T1: the bare vault restore reads ref/<profileRefV2(name)> as ONE probe+value pair. origin/main: 4 GETs (profileDeleted's
// pair, then resolveKeyHeadSE's headRef probe and its getRef); after: 2.
func TestBareHeadReads_VaultRestoreReadsTheBareRefOnce(t *testing.T) {
	st := bhrPlainEnv(t)
	const name, pass = "bhrvault", "correct horse battery staple"
	createVault(st.base, name, pass)
	st.reset()
	deleted, locked, head, ok := bhrRestoreHead(st.base, name, pass)
	if deleted || locked || !ok || head == "" {
		t.Fatalf("a created profile restored deleted=%v locked=%v ok=%v head=%q", deleted, locked, ok, head)
	}
	v2 := "ref/" + profileRefV2(name, pass)
	if n := st.reads(v2); n != 2 {
		t.Errorf("the vault restore made %d GETs of the bare head ref, want 2 (one probe+value pair; origin/main "+
			"makes 4): the head lookup must reuse profileDeleted's read (Q036). Sequence: %q", n, st.seq())
	}
	if n := st.reads("ref/" + profileRefLegacy(name, pass)); n != 0 {
		t.Errorf("the legacy ref was read %d time(s) although v2 resolved", n)
	}
}

// T2: a scope restore (name#de) reads the BARE ref once across profileDeletedWith + scopeOwnerLockedWith + its own
// resolve, and fetches the vault blob through headBlobGet. origin/main: 4 GETs of the bare ref (profileDeleted's pair,
// scopeOwnerLocked's headKey probe and its getRef) and 1 GET of the vault blob (getHeadBlob bypassed the cache the bare
// restore filled); after: 2 and 0.
func TestBareHeadReads_ScopeRestoreReadsTheBareRefOnce(t *testing.T) {
	st := bhrPlainEnv(t)
	const name, pass = "bhrscope", "correct horse battery staple"
	createVault(st.base, name, pass)
	seedLegacyProfile(t, st.base, name+"#de", pass)
	// roamd restores the bare vault first, which leaves the vault blob in the head-blob cache.
	_, _, vaultHead, ok := bhrRestoreHead(st.base, name, pass)
	if !ok || vaultHead == "" {
		t.Fatal("the bare restore did not resolve -- fixture bug")
	}
	st.reset()
	deleted, locked, head, ok := bhrRestoreHead(st.base, name+"#de", pass)
	if deleted || locked || !ok || head == "" {
		t.Fatalf("the #de scope restored deleted=%v locked=%v ok=%v head=%q", deleted, locked, ok, head)
	}
	if n := st.reads("ref/" + profileRefV2(name, pass)); n != 2 {
		t.Errorf("the #de restore made %d GETs of the BARE head ref, want 2 (one probe+value pair; origin/main makes "+
			"4): scopeOwnerLocked must reuse profileDeleted's read (Q036). Sequence: %q", n, st.seq())
	}
	if n := st.reads("blob/" + vaultHead); n != 0 {
		t.Errorf("the #de restore fetched the vault blob %d time(s) from the store, want 0: vaultHeadLocked must read "+
			"through headBlobGet, and the bare restore cached that blob", n)
	}
	if n := st.reads("ref/" + profileRefV2(name+"#de", pass)); n != 2 {
		t.Errorf("the scope's own head ref was read %d time(s), want one live probe+value pair (2)", n)
	}
}

// T3: a deleted profile still refuses, and an absent name or a wrong passphrase makes the SAME store requests in the
// SAME order as on origin/main (the memo records hits only, so every miss reads live again: blind login, and Q036 (b)
// -- a missing scope keeps its extra read).
func TestBareHeadReads_DeletedAndAbsentUnchanged(t *testing.T) {
	t.Run("deleted", func(t *testing.T) {
		st := bhrPlainEnv(t)
		const name, pass = "bhrdeleted", "correct horse battery staple"
		createVault(st.base, name, pass)
		putRef(st.base, profileRefV2(name, pass), "") // the delete tombstone: the ref EXISTS, empty
		for _, p := range []string{name, name + "#de", name + "#keys"} {
			deleted, locked, _, ok := bhrRestoreHead(st.base, p, pass)
			if !deleted || locked || ok {
				t.Errorf("%q of a tombstoned profile: deleted=%v locked=%v ok=%v, want deleted", p, deleted, locked, ok)
			}
			if !profileDeleted(st.base, p, pass) {
				t.Errorf("profileDeleted(%q) no longer reads the tombstone", p)
			}
		}
	})
	// Each of these is origin/main's exact sequence (measured against it): profileDeleted's v2 and legacy probes, then
	// the scope guard's ladder and getRef (scopes only), then the resolve's ladder and getRef of the name itself.
	absentSeq := func(name, pass string) []string {
		bv2, blg := "ref/"+profileRefV2(name, pass), "ref/"+profileRefLegacy(name, pass)
		return []string{bv2, blg, bv2, blg, bv2}
	}
	t.Run("absent bare name", func(t *testing.T) {
		st := bhrPlainEnv(t)
		const name, pass = "bhrabsent", "correct horse battery staple"
		deleted, locked, head, ok := bhrRestoreHead(st.base, name, pass)
		if deleted || locked || ok || head != "" {
			t.Errorf("absent name: deleted=%v locked=%v ok=%v head=%q, want a plain miss", deleted, locked, ok, head)
		}
		if got, want := st.seq(), absentSeq(name, pass); !reflect.DeepEqual(got, want) {
			t.Errorf("absent name requested\n  %q\nwant origin/main's\n  %q\n-- a recorded absence would skip the repeats", got, want)
		}
	})
	t.Run("absent scope", func(t *testing.T) {
		st := bhrPlainEnv(t)
		const name, pass = "bhrabsentscope", "correct horse battery staple"
		deleted, locked, head, ok := bhrRestoreHead(st.base, name+"#de", pass)
		if deleted || locked || ok || head != "" {
			t.Errorf("absent scope: deleted=%v locked=%v ok=%v head=%q, want a plain miss", deleted, locked, ok, head)
		}
		// profileDeleted's bare v2+legacy probes, the scope guard's bare ladder, then the scope's own. The guard's
		// ladder reads strictly, and a strict read carries the value, so no getRef follows it (NWP-20261124-07: one
		// GET fewer than origin/main's [bv2 blg bv2 blg bv2 dv2 dlg dv2]).
		bv2, blg := "ref/"+profileRefV2(name, pass), "ref/"+profileRefLegacy(name, pass)
		dv2, dlg := "ref/"+profileRefV2(name+"#de", pass), "ref/"+profileRefLegacy(name+"#de", pass)
		want := []string{bv2, blg, bv2, blg, dv2, dlg, dv2}
		if got := st.seq(); !reflect.DeepEqual(got, want) {
			t.Errorf("absent scope requested\n  %q\nwant origin/main's\n  %q", got, want)
		}
	})
	t.Run("wrong passphrase", func(t *testing.T) {
		st := bhrPlainEnv(t)
		const name, pass, wrong = "bhrwrongpass", "correct horse battery staple", "staple battery horse correct"
		createVault(st.base, name, pass)
		st.reset()
		deleted, locked, head, ok := bhrRestoreHead(st.base, name, wrong)
		if deleted || locked || ok || head != "" {
			t.Errorf("wrong passphrase: deleted=%v locked=%v ok=%v head=%q, want a plain miss", deleted, locked, ok, head)
		}
		if got, want := st.seq(), absentSeq(name, wrong); !reflect.DeepEqual(got, want) {
			t.Errorf("wrong passphrase requested\n  %q\nwant\n  %q -- the same shape as an unknown name", got, want)
		}
	})
}

// bhrCapEnv is tieFixture's cap-mode store (mockCapStore, a funded wallet) with this test's own profile name.
func bhrCapEnv(t *testing.T, name, pass string) {
	t.Helper()
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	capReadCache = map[string]capEntry{}
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_MULTIDEVICE", "")
	t.Setenv("NOWHERE_UNIT_SRC", "")
	t.Setenv("NOWHERE_SE_SECRET", "")
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault (cap mode) returned no recovery code -- fixture bug")
	}
}

// bhrTraced runs one restore invocation inside a traceDistinct window, as the restore case does, and returns its
// reads=NxM pair and the per-key counts.
func bhrTraced(profile, pass string) (deleted, locked, ok bool, total, distinct int, perKey map[string]int) {
	traceDistinctBegin()
	deleted, locked, _, ok = bhrRestoreHead("s3", profile, pass)
	traceDistinctMu.Lock()
	perKey = map[string]int{}
	for k, n := range traceDistinct {
		perKey[k] = n
	}
	traceDistinctMu.Unlock()
	total, distinct = traceDistinctEnd()
	return
}

// T4: cap mode, the device's own counter. With the head blobs prefetched (as the login daemon does before roamd's
// restores), origin/main reproduces the 2026-10-23 S3 baseline exactly -- vault reads=2x/1keys, #de reads=5x/3keys --
// and after this change the vault is 1x/1keys and #de 2x/2keys (the bare ref once, the scope's own ref once).
func TestBareHeadReads_CapModeMatchesTheDeviceBaseline(t *testing.T) {
	const name, pass = "bhrcap", "correct horse battery staple"
	bhrCapEnv(t, name, pass)
	mj, _ := json.Marshal(Manifest{})
	bn := capBegin()
	putRef("s3", profileRefV2(name+"#de", pass), postBlob("s3", seal(deriveKey(name+"#de", pass), mj)))
	capFlush(bn)
	prefetchHeadBlobs("s3", name, pass)

	bare := "ref/" + profileRefV2(name, pass)
	deleted, locked, ok, total, distinct, perKey := bhrTraced(name, pass)
	if deleted || locked || !ok {
		t.Fatalf("cap vault restore: deleted=%v locked=%v ok=%v", deleted, locked, ok)
	}
	if total != 1 || distinct != 1 || perKey[bare] != 1 {
		t.Errorf("cap vault restore: reads=%dx/%dkeys %v, want reads=1x/1keys (the S3 baseline was 2x/1keys)", total, distinct, perKey)
	}
	deleted, locked, ok, total, distinct, perKey = bhrTraced(name+"#de", pass)
	if deleted || locked || !ok {
		t.Fatalf("cap #de restore: deleted=%v locked=%v ok=%v", deleted, locked, ok)
	}
	if perKey[bare] != 1 {
		t.Errorf("cap #de restore read the bare ref %d time(s), want 1 (the S3 baseline was 3): %v", perKey[bare], perKey)
	}
	if total != 2 || distinct != 2 {
		t.Errorf("cap #de restore: reads=%dx/%dkeys %v, want reads=2x/2keys (the S3 baseline was 5x/3keys)", total, distinct, perKey)
	}
}

// T3, cap mode: a vault tied to another phone's chip still reads as locked for its scopes through the memo, and opens
// on the phone it is tied to.
func TestBareHeadReads_TiedVaultStillLocked(t *testing.T) {
	const name, pass = "bhrtied", "correct horse battery staple"
	bhrCapEnv(t, name, pass)
	if err := sessionTie("s3", name, pass, seA); err != nil {
		t.Fatal(err)
	}
	if deleted, locked, _, ok := bhrRestoreHead("s3", name+"#media", pass); deleted || !locked || ok {
		t.Errorf("a scope of a profile tied elsewhere: deleted=%v locked=%v ok=%v, want locked", deleted, locked, ok)
	}
	t.Setenv("NOWHERE_SE_SECRET", hex.EncodeToString(seA))
	if _, locked, _, _ := bhrRestoreHead("s3", name+"#media", pass); locked {
		t.Error("on the phone it is tied to, its scope was refused")
	}
}

// T5: under NOWHERE_MULTIDEVICE=1 the head ladder probes this device's unit-head rung before v2. profileDeleted never
// probes that rung, so the memo must not answer it: it reads live, and this device's own head wins over the v2 head
// profileDeleted read.
func TestBareHeadReads_UnitHeadRungReadsLive(t *testing.T) {
	st := bhrPlainEnv(t)
	orig := unitIDPath
	t.Cleanup(func() { unitIDPath = orig })
	unitIDPath = filepath.Join(t.TempDir(), "unit-id")
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	const name, pass = "bhrunit", "correct horse battery staple"
	headA := seedLegacyProfile(t, st.base, name, pass)
	mj, _ := json.Marshal(Manifest{Items: []Item{{Name: "unit", Ref: "r", Size: 1}}})
	headB := postBlob(st.base, seal(deriveKey(name, pass), mj))
	uref := unitHeadRef(name, pass, deviceUnitID())
	putRef(st.base, uref, headB)
	st.reset()
	deleted, locked, head, ok := bhrRestoreHead(st.base, name, pass)
	if deleted || locked || !ok {
		t.Fatalf("multi-device restore: deleted=%v locked=%v ok=%v", deleted, locked, ok)
	}
	if head != headB {
		t.Errorf("multi-device restore resolved %q, want this device's unit head %q (not the v2 head %q profileDeleted "+
			"read): the memo answered a rung it never probed", head, headB, headA)
	}
	if n := st.reads("ref/" + uref); n < 1 {
		t.Errorf("the unit-head rung was read %d time(s), want a live read", n)
	}
	if n := st.reads("ref/" + profileRefV2(name, pass)); n != 2 {
		t.Errorf("the bare v2 ref was read %d time(s), want profileDeleted's one pair (2)", n)
	}
}
