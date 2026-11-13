package main

import (
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"testing"
)

// h60 #17 (decided 2026-11-06; NWP-20261201-23): a create's staged claim publishes nothing while the stored copy
// cannot be read, and the profile's next successful bare-vault save retries it. Each test names what it pins;
// test-staged-claim-retry.sh --mutate convicts each guard.

// stagedRetrySetup is walletFailSetup with a staged claim of 2 blind tokens, whose generation carries its restore proof
// (createAndReply's proveNoStoredWallet writes it for a real create).
func stagedRetrySetup(t *testing.T) (f *walletFailFixture, staged string, before map[string]bool) {
	t.Helper()
	f = walletFailSetup(t)
	staged = createStagingPath(walletFailName, walletFailPass)
	if err := appendTokens(staged, newBlindTokens()); err != nil {
		t.Fatal(err)
	}
	markWalletRestoreLanded(staged, walletGeneration(staged))
	return f, staged, storedNonces(t)
}

func assertStagedStays(t *testing.T, staged, what string) {
	t.Helper()
	if w, err := loadWallet(staged); err != nil || w.balance() != 2 {
		t.Fatalf("%s: the staged claim did not stay (%v, %v)", what, w, err)
	}
}

func assertStagedGone(t *testing.T, staged, what string) {
	t.Helper()
	if _, err := os.Stat(staged); !os.IsNotExist(err) {
		t.Fatalf("%s: the staged file is still there (%v)", what, err)
	}
}

// R1: over an unreadable stored copy the create publishes nothing and keeps the file. On the old code the fail-soft
// read gave nil and the staged 2 replaced the stored 10.
func TestStagedClaimRetry_AnUnreadableStoredCopyPublishesNothing(t *testing.T) {
	f, staged, before := stagedRetrySetup(t)
	restore := f.walletFailWalletReads(t, http.StatusInternalServerError)
	var published bool
	out := captureStderr(t, func() { published = finishStagedClaim(walletFailName, walletFailPass, staged, false) })
	restore()
	if published {
		t.Fatalf("finishStagedClaim reported a publish over an unreadable stored copy; stderr:\n%s", out)
	}
	f.assertKeepsEvery(t, before, f.stored, "a create over an unreadable stored copy")
	assertStagedStays(t, staged, "a create over an unreadable stored copy")
	if !strings.Contains(out, "[logind] create: the stored wallet could not be read") {
		t.Errorf("the create did not log its refusal; stderr:\n%s", out)
	}
	if strings.Contains(out, walletFailName) {
		t.Errorf("the refusal names the profile; stderr:\n%s", out)
	}
}

// R2: the next save that can read the stored copy publishes the staged tokens merged against it, and removes the file.
func TestStagedClaimRetry_TheNextSavePublishesItMerged(t *testing.T) {
	f, staged, before := stagedRetrySetup(t)
	restore := f.walletFailWalletReads(t, http.StatusInternalServerError)
	captureStderr(t, func() { finishStagedClaim(walletFailName, walletFailPass, staged, false) })
	restore()
	var published bool
	out := captureStderr(t, func() { published = retryStagedClaimAfterSave(walletFailName, walletFailPass) })
	if !published {
		t.Fatalf("the retry did not publish with the store readable; stderr:\n%s", out)
	}
	f.assertKeepsEvery(t, before, f.stored+2, "the retried publish")
	assertStagedGone(t, staged, "the retried publish")
	if !strings.Contains(out, "[agent] save: a create's staged claim was published by this save") {
		t.Errorf("the retry did not log its outcome; stderr:\n%s", out)
	}
	if strings.Contains(out, walletFailName) {
		t.Errorf("the retry's outcome names the profile; stderr:\n%s", out)
	}
}

// R2b: the wallet published is merged before the publish, so a failed second (fail-soft) read inside
// sealWalletValueDurable cannot send the staged set alone.
func TestStagedClaimRetry_ThePublishIsMergedBeforeTheSecondRead(t *testing.T) {
	f, staged, before := stagedRetrySetup(t)
	stored := readBackStored(t)
	old := readStoredWalletForPublish
	t.Cleanup(func() { readStoredWalletForPublish = old })
	readStoredWalletForPublish = func(base, name, pass string, dk []byte) (*Wallet, []byte, error) {
		return stored, nil, nil
	}
	restore := f.walletFailWalletReads(t, http.StatusInternalServerError)
	var published bool
	out := captureStderr(t, func() { published = finishStagedClaim(walletFailName, walletFailPass, staged, false) })
	restore()
	if !published {
		t.Fatalf("finishStagedClaim did not publish; stderr:\n%s", out)
	}
	f.assertKeepsEvery(t, before, f.stored+2, "a publish whose second read failed")
	assertStagedGone(t, staged, "a publish whose second read failed")
}

// stagedRetryCountRequests sends the store through a proxy that counts every request, until the returned restore.
func stagedRetryCountRequests(t *testing.T, f *walletFailFixture) (count *atomic.Int64, restore func()) {
	t.Helper()
	target, _ := url.Parse(f.srv.URL)
	proxy := httputil.NewSingleHostReverseProxy(target)
	count = &atomic.Int64{}
	px := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count.Add(1)
		proxy.ServeHTTP(w, r)
	}))
	prev := os.Getenv("GATEWAY_URL")
	t.Setenv("GATEWAY_URL", px.URL)
	capReadCache = map[string]capEntry{}
	return count, func() { px.Close(); t.Setenv("GATEWAY_URL", prev); capReadCache = map[string]capEntry{} }
}

// R3: only the bare vault's save retries, and a scoped save or a profile with nothing staged touches no store.
func TestStagedClaimRetry_OnlyABareVaultSaveRetries(t *testing.T) {
	f := walletFailSetup(t)
	scoped := walletFailName + "#apps"
	stagedScoped := createStagingPath(scoped, walletFailPass)
	if err := appendTokens(stagedScoped, newBlindTokens()); err != nil {
		t.Fatal(err)
	}
	markWalletRestoreLanded(stagedScoped, walletGeneration(stagedScoped))
	count, restore := stagedRetryCountRequests(t, f)
	defer restore()
	if retryStagedClaimAfterSave(scoped, walletFailPass) {
		t.Error("a scoped save reported a publish")
	}
	if n := count.Load(); n != 0 {
		t.Errorf("a scoped save made %d store request(s), want none", n)
	}
	assertStagedStays(t, stagedScoped, "a scoped save")
	if retryStagedClaimAfterSave(walletFailName, walletFailPass) {
		t.Error("a bare save with nothing staged reported a publish")
	}
	if n := count.Load(); n != 0 {
		t.Errorf("a bare save with nothing staged made %d store request(s), want none", n)
	}
}

// R4: a retry refuses while the staged seen-set is unusable, because by then the stored head may hold the session's own
// credit and a publish with no union would drop it. The create-time publish on the same set goes ahead, as it always has.
func TestStagedClaimRetry_AnUnusableSeenSetRefusesTheRetryOnly(t *testing.T) {
	f, staged, before := stagedRetrySetup(t)
	if err := poisonSeen(staged, walletGeneration(staged)); err != nil {
		t.Fatal(err)
	}
	var published bool
	out := captureStderr(t, func() { published = retryStagedClaimAfterSave(walletFailName, walletFailPass) })
	if published {
		t.Fatalf("the retry published with no usable seen-set; stderr:\n%s", out)
	}
	f.assertKeepsEvery(t, before, f.stored, "a retry with no usable seen-set")
	assertStagedStays(t, staged, "a retry with no usable seen-set")
	if !strings.Contains(out, "[agent] save: the staged claim's seen-set cannot be read") {
		t.Errorf("the retry did not log its refusal; stderr:\n%s", out)
	}
	if !finishStagedClaim(walletFailName, walletFailPass, staged, false) {
		t.Fatal("the create-time publish refused on an unusable seen-set")
	}
	assertStagedGone(t, staged, "the create-time publish")
}

// R5: only a seal that landed retries: the push case's refusal exit comes before the call.
func TestStagedClaimRetry_PushRetriesAfterTheRefusalExit(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	order := func(fn string, first, then string) {
		t.Helper()
		body := strings.Join(stripComments(funcBody(t, string(src), fn)), "\n")
		i, j := strings.Index(body, first), strings.Index(body, then)
		if i < 0 || j < 0 || i > j {
			t.Errorf("%s: %q (at %d) must come before %q (at %d)", fn, first, i, then, j)
		}
	}
	order("main", "os.Exit(exitSealRefused)", "retryStagedClaimAfterSave(os.Args[3], os.Args[4])")
}

// R6: a store failure panics (fail), and main turns a panic into a failed exit. The retry runs after a seal that landed,
// so the panic stays inside it and the file stays.
func TestStagedClaimRetry_AStoreFailureStaysInsideTheRetry(t *testing.T) {
	_, staged, _ := stagedRetrySetup(t)
	back := walletFailBreak(t)
	defer back()
	var published bool
	out := captureStderr(t, func() { published = retryStagedClaimAfterSave(walletFailName, walletFailPass) })
	if published {
		t.Fatalf("the retry reported a publish against a dead store; stderr:\n%s", out)
	}
	assertStagedStays(t, staged, "a retry against a dead store")
	if !strings.Contains(out, "[agent] save: a create's staged claim is still staged") {
		t.Errorf("the retry did not log its outcome; stderr:\n%s", out)
	}
}
