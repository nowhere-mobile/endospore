package main

import (
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// NWP-20260917-24: the login-time plan-carry retry duplicated the head resolution the login had just done,
// and did it through the UNCACHED accessors.
//
// ⚠ THIS IS A LATENCY TEST, AND LATENCY IS A TRACKED BUDGET HERE (the 2026-08-20 campaign took login from
// ~100s to the ~40s class). NWP-20260917-07 documented rule 1 as costing "one map lookup"; reaching that
// lookup actually required resolving the head and unsealing the scope index first, SYNCHRONOUSLY, before
// handleRoamIn answers the chooser -- paid by EVERY profile on EVERY login, including one that has never
// changed its credential and has nothing to carry.
//
// Counting store round trips is the only honest way to assert this. A wall-clock assertion would be a
// measurement-window lie, and asserting on the code's shape would pass whether or not the cache was
// actually consulted. countingStore is the harness head_prefetch_test.go already uses for exactly this.

// TestTheLoginRetryDoesNotRefetchTheHead pins the cost of rule 1 -- the overwhelmingly common case.
func TestTheLoginRetryDoesNotRefetchTheHead(t *testing.T) {
	base, refReads, blobReads := countingStore(t)
	// ⚠ WITHOUT NOWHERE_STATE THE TEST IS VACUOUS. headBlobCacheDir() derives from it and returns "" when
	// unset, which makes the whole head-blob cache INERT -- every read would miss, the counts would be
	// identical before and after the fix, and this would pass against both.
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")

	const name, pass = "headreads", "correct horse battery staple"
	createVault(base, name, pass)

	// The login: resolveDK is what handleRoamIn calls immediately before the retry.
	dk := resolveDK(base, name, pass, nil)
	if dk == nil {
		t.Fatal("resolveDK returned nil -- fixture bug, the rest proves nothing")
	}

	blobBefore := *blobReads
	retryPlanCarry(base, name, pass, dk, filepath.Join(t.TempDir(), "wallet.json"))

	// The head blob must come from the cache resolveDK just populated. This is what fails against the old
	// code, where retryPlanCarry called getHeadBlob directly and went to the store: measured at 1 blob fetch
	// and 2 ref reads added to a login that had nothing to carry.
	if n := *blobReads - blobBefore; n != 0 {
		t.Errorf("the retry fetched %d head blob(s) from the store, want 0 -- the login resolved that exact "+
			"head moments earlier and headBlobGet caches it, so every one of these is a round trip added to "+
			"a login that had nothing to carry", n)
	}
	// ⚠ THE REF SAVING IS DELIBERATELY NOT ASSERTED HERE, and the reason is the whole point of writing this
	// down. The fused headRef only avoids the second read when the probe CARRIES the value, which happens in
	// cap mode; this harness is non-cap (GATEWAY_URL is empty above), so `have` is false, the fallback getRef
	// runs, and the count is 2 both before and after the change. An assertion on it would pass either way --
	// vacuous, exactly like a two-line marker that has no line 4. The cap-mode saving is real but belongs to
	// a cap fixture, and claiming it from this one would be measuring nothing and reporting a win: it is pinned
	// in TestPlanCarryRetry_CapModeReadsTheHeadRefOnceAndNoBlob below (NWP-20261112-26).
	_ = refReads
}

// TestPlanCarryRetry_CapModeReadsTheHeadRefOnceAndNoBlob is the cap-mode count the test above cannot make
// (NWP-20261112-26). On a managed device -- the whole fielded fleet -- every store read is a gateway /cap fetch
// plus a presigned GET, so the retry that runs before handleRoamIn answers the chooser must cost exactly the ONE
// fused head-ref probe (refProbe carries the value, haveVal=true, so openVaultHead skips getRef) and no head-blob
// read (resolveDK filled the head-blob cache moments earlier). Each GET is counted where the store sees it,
// mockCapStore's /obj, so a path that reads around the counter still shows up.
func TestPlanCarryRetry_CapModeReadsTheHeadRefOnceAndNoBlob(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	capReadCache = map[string]capEntry{}
	// Without NOWHERE_STATE the head-blob cache is inert (headBlobCacheDir returns ""), and the blob count
	// would measure a cache that cannot hit.
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_MULTIDEVICE", "") // the ladder is the one v2 probe
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}

	const name, pass = "capcarryreads", "correct horse battery staple"
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault (cap mode) returned no recovery code -- fixture bug, the rest proves nothing")
	}
	dk := resolveDK("s3", name, pass, nil)
	if dk == nil {
		t.Fatal("resolveDK returned nil -- fixture bug, the rest proves nothing")
	}

	var mu sync.Mutex
	var refKeys []string
	blobReads := 0
	capStoreGetSeen = func(k string) {
		mu.Lock()
		defer mu.Unlock()
		switch {
		case strings.HasPrefix(k, "ref/"):
			refKeys = append(refKeys, k)
		case strings.HasPrefix(k, "blob/"):
			blobReads++
		}
	}
	counts := func() ([]string, int) {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), refKeys...), blobReads
	}

	retryPlanCarry("s3", name, pass, dk, wpath)

	headKey := "ref/" + profileRefV2(name, pass)
	refs, blobs := counts()
	if len(refs) != 1 || refs[0] != headKey {
		t.Errorf("the retry read refs %q, want exactly [%q] -- the one fused probe. A second read of the head "+
			"ref means openVaultHead called getRef although refProbe had carried the value (or refProbe stopped "+
			"carrying it in cap mode): a gateway round trip added to every managed login", refs, headKey)
	}
	if blobs != 0 {
		t.Errorf("the retry fetched %d head blob(s) from the store, want 0 -- resolveDK resolved that exact head "+
			"moments earlier and must have left it in the head-blob cache, and openVaultHead must read through "+
			"headBlobGet", blobs)
	}

	// CONTROL: the hook really sees ref reads. Two direct reads of the head ref count two, so the == 1 above
	// cannot be passed by a counter that never fires.
	mu.Lock()
	refKeys, blobReads = nil, 0
	mu.Unlock()
	for i := 0; i < 2; i++ {
		if getRef("s3", profileRefV2(name, pass)) == "" {
			t.Fatal("CONTROL: the head ref read back empty -- fixture bug")
		}
	}
	if refs, _ := counts(); len(refs) != 2 {
		t.Errorf("CONTROL: two direct getRef calls of the head ref counted %d ref read(s) %q, want 2 -- the "+
			"store-side counter is not seeing cap-mode reads, so the assertions above prove nothing", len(refs), refs)
	}
}

// TestResolveDKUsesTheHeadBlobCache: resolveDK was the OUTLIER. resolveKeyHead already reads through
// headBlobGet; resolveDK went straight to getHeadBlob, so nothing on the login path populated the cache for
// the retry that follows it -- fixing the retry alone would have left it missing every single time.
func TestResolveDKUsesTheHeadBlobCache(t *testing.T) {
	base, _, blobReads := countingStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")

	const name, pass = "dkcache", "correct horse battery staple"
	createVault(base, name, pass)

	if dk := resolveDK(base, name, pass, nil); dk == nil {
		t.Fatal("first resolveDK returned nil -- fixture bug")
	}
	blobBefore := *blobReads
	if dk := resolveDK(base, name, pass, nil); dk == nil {
		t.Fatal("second resolveDK returned nil")
	}
	if n := *blobReads - blobBefore; n != 0 {
		t.Errorf("a second resolveDK fetched %d head blob(s), want 0 -- the first call must populate the "+
			"head-blob cache, which is what makes the login-path retry free", n)
	}
}

// TestResolveDKStillSeparatesNoHeadFromNotAVault guards the one thing this tidy-up could have broken.
//
// resolveDK has THREE outcomes where openVaultHead has two: no head at all returns nil, while a head that
// is not a vault falls through to deriveKey for a legacy profile. Collapsing them -- which is exactly what
// using the new helper here would have done -- hands a legacy DK to a profile that has no head.
func TestResolveDKStillSeparatesNoHeadFromNotAVault(t *testing.T) {
	base, _, _ := countingStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")

	if dk := resolveDK(base, "no-such-profile", "correct horse battery staple", nil); dk != nil {
		t.Error("resolveDK returned a key for a profile with NO head -- it must return nil there. The " +
			"legacy fallback is only correct when a head EXISTS and is not a vault")
	}
}
