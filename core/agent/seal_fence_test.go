package main

// Tests for the publish fence (#144). Each of the first three FAILS on the pre-fence code, and they fail in
// the way the bug actually presents -- a profile the user was told was deleted coming back -- rather than by
// asserting that some internal flag was set.

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// storeHooks fire OUTSIDE the store's mutex, so a hook may itself talk to the same store -- which is what
// lets a test delete a profile from inside a push, landing the delete in the exact window the fence exists
// to close. Deterministic: no goroutines, no sleeps, the interleave is where the hook says it is.
type storeHooks struct {
	onBlobPost func() // after a blob POST is served
	onRefPut   func(ref string)
}

func newHookStore(t *testing.T, h *storeHooks) string {
	t.Helper()
	var mu sync.Mutex
	blobs := map[string][]byte{}
	refs := map[string]string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var after func()
		mu.Lock()
		switch {
		case r.Method == "POST" && r.URL.Path == "/blob":
			body, _ := io.ReadAll(r.Body)
			sum := sha256.Sum256(body)
			key := hex.EncodeToString(sum[:])
			blobs[key] = body
			io.WriteString(w, key)
			if h != nil && h.onBlobPost != nil {
				after = h.onBlobPost
			}
		case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/blob/"):
			if b, ok := blobs[strings.TrimPrefix(r.URL.Path, "/blob/")]; ok {
				w.Write(b)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/ref/"):
			body, _ := io.ReadAll(r.Body)
			ref := strings.TrimPrefix(r.URL.Path, "/ref/")
			refs[ref] = string(body)
			if h != nil && h.onRefPut != nil {
				after = func() { h.onRefPut(ref) }
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
		mu.Unlock()
		if after != nil {
			after() // outside the lock: the hook may re-enter this store
		}
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

// fenceTestEnv turns the fence ON (it is inert without NOWHERE_STATE) and clears the per-push globals, which
// are process-wide and would otherwise leak between tests in the same binary.
func fenceTestEnv(t *testing.T) {
	t.Helper()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	reset := func() {
		pushFenceSeq, pushFenceSampled = 0, false
		sealFenceHit, sealRefused = false, false
	}
	reset()
	t.Cleanup(reset)
}

func seedDir(t *testing.T, n int) string {
	t.Helper()
	d := t.TempDir()
	for i := 0; i < n; i++ {
		body := strings.Repeat("x", 4096+i*17)
		if err := os.WriteFile(filepath.Join(d, fmt.Sprintf("f%d.dat", i)), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return d
}

// THE P0. A seal already in flight publishes its pointers minutes after it sampled the head. deleteProfile
// tombstones every ref and VERIFIES them empty -- and the seal then overwrites the bare head AND the recovery
// ref, so profileDeleted() goes false and the restore gate (#19/#139), the heal-at-refusal (#687) and
// createVault's purge (#142) are all disabled by that one write.
//
// NOWHERE_SEAL_FORCE=1 is set deliberately: it is the operator override for the shrink/keystone guards, and
// this pins that it does NOT override the fence. "Force this seal" must never mean "resurrect a deleted
// profile" -- the fence is the user's deletion, not a heuristic.
func TestSealCannotResurrectDeletedProfileMidPush(t *testing.T) {
	fenceTestEnv(t)
	t.Setenv("NOWHERE_SEAL_FORCE", "1")

	name, pass := "alice", "correct horse battery"
	var base string
	var armed, fired bool
	base = newHookStore(t, &storeHooks{onBlobPost: func() {
		if !armed || fired {
			return
		}
		fired = true
		if got := deleteProfile(base, name, pass); got != "deleted" {
			t.Errorf("mid-push delete: got %q want deleted", got)
		}
	}})

	createVault(base, name, pass)
	head := getRef(base, headKey(base, name, pass))
	v, isV := parseVault(getBlob(base, head))
	if !isV || v.RecoveryRef == "" {
		t.Fatal("setup: expected a vault head with a recovery ref")
	}
	recRef := v.RecoveryRef

	armed = true // from here, the first blob the push writes triggers the delete
	pushProfile(base, name, pass, seedDir(t, 3))
	if !fired {
		t.Fatal("setup: the mid-push delete never fired -- the push wrote no blobs")
	}

	bare := profileRefV2(name, pass)
	if got := getRef(base, bare); got != "" {
		t.Fatalf("RESURRECTED: bare head resolves to %q after a verified delete", got)
	}
	if !refExists(base, bare) {
		t.Fatal("the tombstone itself was destroyed -- delete must leave an empty object that EXISTS")
	}
	if got := getRef(base, recRef); got != "" {
		t.Fatalf("RESURRECTED: the 12-word recovery ref resolves to %q after the delete killed it", got)
	}
	if !profileDeleted(base, name, pass) {
		t.Fatal("profileDeleted() is false -> the restore gate, the #687 heal and #142's purge are ALL disabled")
	}
	if !sealFenceHit && !sealRefused {
		t.Fatal("the seal published nothing but reported success -- a refusal must never read as success (#111)")
	}
}

// P0 (b): pushProfile's tombstone guard is gated on `!strings.Contains(profile, "#")`, so every SCOPE re-created
// its ref from an empty head. Nothing about a delete stops roamd walking on to the next scope.
func TestScopeSealCannotRepublishAfterDelete(t *testing.T) {
	fenceTestEnv(t)
	t.Setenv("NOWHERE_SEAL_FORCE", "1")

	name, pass := "alice", "correct horse battery"
	base := newHookStore(t, nil)
	createVault(base, name, pass)

	for _, scope := range []string{"#de", "#media", "#sys", "#apps"} {
		pushProfile(base, name+scope, pass, seedDir(t, 2))
		if getRef(base, profileRefV2(name+scope, pass)) == "" {
			t.Fatalf("setup: %s should have sealed before the delete", scope)
		}
	}
	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("delete: got %q want deleted", got)
	}
	for _, scope := range []string{"#de", "#media", "#sys", "#apps"} {
		pushProfile(base, name+scope, pass, seedDir(t, 2))
		if got := getRef(base, profileRefV2(name+scope, pass)); got != "" {
			t.Fatalf("RESURRECTED %s: resolves to %q after the profile was deleted", scope, got)
		}
	}
}

// P0 (c): the delete's OWN teardown re-seals #keys (cleanUserStorage -> CLEAN-STORAGE -> keystore_push), and
// SKIP-REAPING is `op == "out"`-only so nothing stops it. The scope may never have been sealed at all, in
// which case deleteProfile's refExists check never tombstoned it -- the push CREATES it from nothing, which
// is why an entry-time busy check could not have helped even in principle.
func TestKeysScopeCannotBeCreatedByTeardownAfterDelete(t *testing.T) {
	fenceTestEnv(t)
	t.Setenv("NOWHERE_SEAL_FORCE", "1")

	name, pass := "alice", "correct horse battery"
	base := newHookStore(t, nil)
	createVault(base, name, pass)

	keysRef := profileRefV2(name+"#keys", pass)
	if refExists(base, keysRef) {
		t.Fatal("setup: #keys must NOT exist -- the point is that the teardown creates it from nothing")
	}
	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("delete: got %q want deleted", got)
	}
	pushProfile(base, name+"#keys", pass, seedDir(t, 1)) // the reap's keystore_push
	if refExists(base, keysRef) {
		t.Fatal("the teardown CREATED a #keys ref for a profile that was just deleted")
	}
}

// The whole safety argument is an ORDERING claim: the fence must be armed before the first tombstone, or it
// leaves exactly the window it exists to close. Assert the ordering against the store's own traffic rather
// than against the source.
func TestDeleteArmsFenceBeforeFirstTombstone(t *testing.T) {
	fenceTestEnv(t)

	name, pass := "alice", "correct horse battery"
	var base string
	var deleting, checked bool
	base = newHookStore(t, &storeHooks{onRefPut: func(ref string) {
		if !deleting || checked {
			return
		}
		checked = true // the FIRST ref write of the delete
		if !sealFenceBlocks(profileRefV2(name, pass)) {
			t.Error("the first tombstone landed while the fence was still UNARMED -- the race window is open")
		}
	}})
	createVault(base, name, pass)
	deleting = true
	deleteProfile(base, name, pass)
	if !checked {
		t.Fatal("setup: the delete wrote no refs, so the ordering was never observed")
	}
}

// F1, the recreate guard. createVault LIFTS the fence so a re-created name can publish -- and the lift bumps
// the same sequence an arm does, so a push that sampled the earlier value still refuses. Without this, an
// in-flight seal of the OLD profile lands on the NEW head at the same ref: #142 again, with the new DK
// destroyed and no tombstone left to heal from.
func TestInFlightSealRefusesEvenAfterRecreate(t *testing.T) {
	fenceTestEnv(t)

	name, pass := "alice", "correct horse battery"
	base := newHookStore(t, nil)
	createVault(base, name, pass)

	// TWO PROCESSES, and the test has to model that. The seal runs in the `push` CLI (a separate process);
	// the delete and the re-create run in the DAEMON, where pushFenceSeq/pushFenceSampled are never set.
	// Holding "a push is in flight" across the daemon's own writes is not a stricter test, it is a WRONG one:
	// it makes createVault's putHead refuse and the profile is created headless. That asymmetry is deliberate
	// (see seal_fence.go) -- the sequence check belongs to a long-running publish, not to one-shot writes.
	staleSeq := sealFenceSeq() // the in-flight push sampled this, then went off to walk and upload

	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("delete: got %q want deleted", got)
	}
	createVault(base, name, pass) // user recreates the name; the lift clears the markers and bumps the seq
	if sealFenceBlocks(profileRefV2(name, pass)) {
		t.Fatal("createVault did not lift the fence -- the new profile could never publish its own head")
	}
	newHead := getRef(base, profileRefV2(name, pass))
	if newHead == "" {
		t.Fatal("the recreated profile has no head")
	}
	// The stale push process now reaches its publish step. The marker is GONE (the lift cleared it), so the
	// sequence is the only thing standing between the old profile's vault and the new head at the same ref.
	pushFenceSeq, pushFenceSampled = staleSeq, true
	putRef(base, profileRefV2(name, pass), "stale-head-from-the-deleted-profile")
	if got := getRef(base, profileRefV2(name, pass)); got != newHead {
		t.Fatalf("a pre-delete push overwrote the RECREATED head: got %q want %q", got, newHead)
	}
	if !sealFenceHit {
		t.Fatal("the stale publish was dropped without being recorded as a refusal")
	}
}

// A wrong passphrase must remain a strict no-op -- including for the fence. Fencing on a failed delete
// attempt would let anyone poison creation for the rest of the boot by guessing a name.
func TestWrongPassDeleteFencesNothing(t *testing.T) {
	fenceTestEnv(t)

	name, pass := "alice", "correct horse battery"
	base := newHookStore(t, nil)
	createVault(base, name, pass)

	if got := deleteProfile(base, name, "WRONG PASSPHRASE"); got != "notfound" {
		t.Fatalf("wrong-pass delete: got %q want notfound", got)
	}
	if sealFenceBlocks(profileRefV2(name, pass)) || sealFenceBlocks(profileRefV2(name+"#de", pass)) {
		t.Fatal("a wrong-passphrase delete armed the fence -- creation and sealing are now poisoned for the boot")
	}
	if entries, err := os.ReadDir(sealFenceDir()); err == nil && len(entries) > 0 {
		t.Fatalf("wrong-pass delete left %d fence marker(s)", len(entries))
	}
	pushProfile(base, name, pass, seedDir(t, 2)) // the real owner can still seal
	if getRef(base, profileRefV2(name, pass)) == "" {
		t.Fatal("the legitimate owner's seal was refused after someone else guessed wrong")
	}
}

// The fence must not block the DELETE itself. delRef routes through putRef with an empty value on this store,
// so a re-delete of an already-fenced profile has to still reach the store and report "gone", not "unverified".
func TestFenceExemptsTombstones(t *testing.T) {
	fenceTestEnv(t)

	name, pass := "alice", "correct horse battery"
	base := newHookStore(t, nil)
	createVault(base, name, pass)

	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("first delete: got %q want deleted", got)
	}
	if got := deleteProfile(base, name, pass); got != "gone" {
		t.Fatalf("re-delete of a fenced profile: got %q want gone (the fence blocked its own tombstones)", got)
	}
}

func TestSealFenceInertWithoutState(t *testing.T) {
	t.Setenv("NOWHERE_STATE", "")
	pushFenceSeq, pushFenceSampled = 0, false
	t.Cleanup(func() { pushFenceSeq, pushFenceSampled = 0, false })

	if sealFenceDir() != "" {
		t.Fatal("the fence must be disabled off-device (host CLI / tests without a state dir)")
	}
	ref := strings.Repeat("de", 32)
	if !armSealFence([]string{ref}) {
		t.Fatal("arming should report success (as a no-op) when the fence is disabled")
	}
	if sealFenceBlocks(ref) || sealFencePublishBlocked("ref/"+ref) {
		t.Fatal("the fence blocked a publish while disabled -- every off-device seal would refuse")
	}
	if sealFenceSeq() != 0 {
		t.Fatal("a disabled fence must report sequence 0")
	}
}

// "I could not tell" and "not fenced" must never render the same. An unreadable fence is treated as fencing:
// refusing a seal is recoverable, publishing over a deleted profile is not.
func TestSealFenceFailsClosedWhenUnreadable(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	// Make the fence DIR a regular file, so stat of anything under it fails with ENOTDIR rather than ENOENT.
	if err := os.WriteFile(filepath.Join(st, "seal-fence"), []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	if !sealFenceBlocks(strings.Repeat("de", 32)) {
		t.Fatal("an unreadable fence read as NOT fenced -- that is the conflation this whole class of bug lives in")
	}
}

// #144 (docs/backlog.md §H, NWP-20261011-09). A vault's recovery_ref is plaintext of a blob the STORE served, and
// deleteProfile arms it; filepath.Join cleans "..", so before fenceRefOK a recovery_ref of "../../nowhere.conf"
// wrote "1\n" over /data/nowhere/nowhere.conf (de-enrollment) on arm and removed it on lift. NOWHERE_STATE is
// laid out as <tmp>/a/b/state so the traversal lands on a file this test planted. Without the gate in arm the
// body check fails; without it in lift the presence check fails; without it in blocks the stat sees the file.
func TestSealFenceRefusesARefThatIsNotAContentHash(t *testing.T) {
	fenceTestEnv(t)
	tmp := t.TempDir()
	state := filepath.Join(tmp, "a", "b", "state")
	t.Setenv("NOWHERE_STATE", state)
	target := filepath.Join(tmp, "a", "b", "nowhere.conf")
	const evil = "../../nowhere.conf"
	if filepath.Join(sealFenceDir(), evil) != target {
		t.Fatalf("precondition: the traversal resolves to %q, not the planted file", filepath.Join(sealFenceDir(), evil))
	}
	const body = "GATEWAY_URL=https://example.invalid\n"
	if err := os.MkdirAll(state, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	planted := func(what string) {
		t.Helper()
		b, err := os.ReadFile(target)
		if err != nil {
			t.Fatalf("%s: the file outside the fence dir is gone: %v", what, err)
		}
		if string(b) != body {
			t.Fatalf("%s: the file outside the fence dir was overwritten with %q", what, b)
		}
	}

	armed := armSealFence([]string{evil})
	planted("arm wrote through the traversal")
	if armed {
		t.Fatal("arm reported success for a ref that is not a content hash")
	}
	if m := fenceMarkers(t); len(m) != 0 {
		t.Fatalf("arm created markers for a refused ref: %v", m)
	}
	liftSealFence([]string{evil})
	planted("lift removed the file outside the fence dir")
	if sealFenceBlocks(evil) {
		t.Fatal("blocks stat-ed outside the fence dir: the planted file read as a fence marker")
	}

	// Positive control: a real ref still arms, blocks in both key forms, and lifts.
	good := strings.Repeat("de", 32)
	if !armSealFence([]string{good}) {
		t.Fatal("a 64-hex ref failed to arm -- the gate is tighter than isContentHash")
	}
	if !sealFenceBlocks(good) || !sealFencePublishBlocked("ref/"+good) {
		t.Fatal("an armed 64-hex ref does not block")
	}

	// Every other shape: a path separator, an absolute path, uppercase hex, one short, one long.
	for _, bad := range []string{"sub/" + good, "/" + good, strings.ToUpper(good), good[:63], good + "0"} {
		if armSealFence([]string{bad}) {
			t.Fatalf("arm accepted %q", bad)
		}
		if sealFenceBlocks(bad) {
			t.Fatalf("blocks reported %q as fenced", bad)
		}
		if m := fenceMarkers(t); len(m) != 1 || m[0] != good {
			t.Fatalf("after refusing %q the fence holds %v, want only the control", bad, m)
		}
	}
	// A mixed batch arms the conforming ref and still reports the refusal.
	other := strings.Repeat("ab", 32)
	if armSealFence([]string{other, evil}) {
		t.Fatal("a batch with a refused ref reported success")
	}
	if !sealFenceBlocks(other) {
		t.Fatal("a refused ref in the batch stopped the conforming one from arming")
	}
	planted("a mixed batch wrote through the traversal")

	liftSealFence([]string{good, other})
	if sealFenceBlocks(good) || sealFenceBlocks(other) {
		t.Fatal("the control did not lift")
	}
	planted("the final lift")
}

// THE PRODUCTION PATH. Every other test here drives the direct-write (HTTP) store, where putRef publishes
// immediately -- but the fleet runs MANAGED (cap) mode, where putRef only BUFFERS and capFlush does the
// actual PUT minutes later. That makes capFlush's check the only one that can catch a seal already in
// flight, and it is precisely the case where putRef's check ran long before the delete existed. Without
// this test the production half of the fix would be proven by inspection alone.
func TestCapFlushRefusesFencedPointerButKeepsBlobs(t *testing.T) {
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	capReadCache = map[string]capEntry{}
	fenceTestEnv(t)

	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(10)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}

	// Both 64-hex: the fence refuses any other shape (fenceRefOK), so a short literal would arm nothing.
	fencedRef, otherRef := strings.Repeat("fe", 32), strings.Repeat("0e", 32)

	bn := capBegin()
	h := postBlob("s3", []byte("a chunk the in-flight seal already uploaded"))
	putRef("s3", fencedRef, h) // buffered while NOTHING is fenced -- exactly as in the race
	putRef("s3", otherRef, h)
	armSealFence([]string{fencedRef}) // the user taps Delete between the buffer and the flush
	capFlush(bn)

	mu.Lock()
	defer mu.Unlock()
	if objs["blob/"+h] == nil {
		t.Fatal("the blob was dropped -- content-addressed chunks are unreferenced and inert, and must still land")
	}
	if v := strings.TrimSpace(string(objs["ref/"+fencedRef])); v != "" {
		t.Fatalf("RESURRECTED via capFlush: the fenced pointer was published as %q", v)
	}
	if v := strings.TrimSpace(string(objs["ref/"+otherRef])); v != h {
		t.Fatalf("an unrelated pointer in the same batch was dropped: %q", v)
	}
	if !sealFenceHit {
		t.Fatal("the refusal was not recorded, so the push verb would exit 0 and roamd would report success (#111)")
	}
}

// capFlush checks its batch keys, which carry the "ref/" store-key prefix; putRef checks the bare ref. One
// helper serves both, and a prefix slip would silently disable the capFlush half -- the only half that
// catches an already-in-flight seal.
func TestSealFencePublishBlockedAcceptsBothKeyForms(t *testing.T) {
	fenceTestEnv(t)
	ref := strings.Repeat("de", 32)
	armSealFence([]string{ref})

	if !sealFencePublishBlocked(ref) {
		t.Fatal("bare ref form not blocked (the putRef path)")
	}
	if !sealFencePublishBlocked("ref/" + ref) {
		t.Fatal("store-key form not blocked (the capFlush path -- the one that catches an in-flight seal)")
	}
	if sealFencePublishBlocked("ref/" + strings.Repeat("ca", 32)) {
		t.Fatal("an unrelated ref was blocked")
	}
}

// fenceMarkers is every armed ref, .seq excluded. The count is the point: the lift is only correct if it
// clears the arm set ENTIRELY, and "the bare head is publishable again" cannot see a stranded scope or
// recovery marker -- which is exactly how NWP-20260921-06 shipped.
func fenceMarkers(t *testing.T) []string {
	t.Helper()
	ents, err := os.ReadDir(sealFenceDir())
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		if e.Name() != sealFenceSeqName {
			out = append(out, e.Name())
		}
	}
	return out
}

// storePutRef writes a ref straight to the store, bypassing putRef and therefore this device's publish
// fence -- what an OFF-DEVICE writer (the storefront restore page, running in a browser) does.
func storePutRef(t *testing.T, base, ref, val string) {
	t.Helper()
	req, err := http.NewRequest("PUT", base+"/ref/"+ref, strings.NewReader(val))
	if err != nil {
		t.Fatal(err)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("off-device ref PUT: status %d", res.StatusCode)
	}
}

// NWP-20260921-06, from lynx 2026-09-21: Chester deleted a profile on the handset, restored it from an
// export folder in the browser, logged in -- and COULD NOT LOG OFF for the rest of the boot. Every seal
// uploaded its chunks and was then refused at the pointer:
//
//	push: PUBLISH REFUSED for ref e16658bd191d -- this profile was DELETED while the seal was in flight
//
// The login lift HAD run and said so. It cleared 14 of the 15 markers the delete armed; the 15th was the
// RECOVERY REF, which sealFenceRefKeys excludes by its own doc, and which pushProfile re-PUTs on every
// vault seal. See loginLiftRefs for why NWP-20260910-18 could not have caught it (it re-created the name,
// minting FRESH entropy and so a different recovery ref; only a restore reproduces the fenced one).
//
// The assertion that generalises is the marker COUNT, not "the profile can seal again": any future member
// of the arm set that the lift forgets strands the same way, and a check aimed at the bare head is blind to
// every one of them.
func TestLoginLiftClearsEveryMarkerTheDeleteArmed(t *testing.T) {
	fenceTestEnv(t)

	name, pass := "alice", "correct horse battery"
	base := newHookStore(t, nil)
	createVault(base, name, pass)

	// What the export folder holds: the head POINTER, and the vault blob behind it. deleteProfile tombstones
	// refs and leaves blobs for store GC, so the blob is still there to be pointed at again -- which is why
	// a restore works at all, and why its recovery ref is byte-identical to the fenced one.
	head := getRef(base, profileRefV2(name, pass))
	if head == "" {
		t.Fatal("setup: the new profile has no head")
	}
	v, isV := parseVault(getHeadBlob(base, head))
	if !isV || v.RecoveryRef == "" {
		t.Fatal("setup: the vault must carry a recovery ref, or this test cannot see the bug it is for")
	}
	recRef := v.RecoveryRef

	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("delete: got %q want deleted", got)
	}
	armed := fenceMarkers(t)
	if len(armed) < 2 {
		t.Fatalf("setup: the delete armed %d marker(s) -- too few for the lift to be able to miss one", len(armed))
	}
	if !sealFenceBlocks(recRef) {
		t.Fatal("setup: the delete did not fence the RECOVERY ref, so the asymmetry under test does not exist")
	}

	// T4: the browser restore PUTs the head pointer back at the same ref, with the same bytes behind it.
	//
	// ⚠ NOT via putRef, and the reason is the bug's whole shape: putRef consults this device's fence, so the
	// restore would be REFUSED here. The restore runs in the BROWSER -- another machine, with no fence of its
	// own -- so the write the handset cannot make is exactly the one the storefront makes. Going through
	// putRef would silently turn this into a test of a profile that was never restored.
	storePutRef(t, base, profileRefV2(name, pass), head)

	// The login that follows. This is the only caller that may lift.
	if _, _, _, ok := resolveKeyHeadForLogin(base, name, pass); !ok {
		t.Fatal("the restored profile did not resolve at login")
	}
	if left := fenceMarkers(t); len(left) > 0 {
		t.Fatalf("the login lift left %d of %d marker(s) armed: %v\n"+
			"Every one of those refuses any publish that touches it for the REST OF THE BOOT. If %s is "+
			"among them it is the recovery ref, which pushProfile re-PUTs on every vault seal -- so the "+
			"user can log in and never log off.", len(left), len(armed), left, recRef)
	}

	// And the user-visible half: the seal that was refused now lands.
	pushProfile(base, name, pass, seedDir(t, 2))
	if sealFenceHit {
		t.Fatal("the seal was STILL refused after the lift -- this is Chester's wedge, unfixed")
	}
}

// recreateOffDevice models the name being minted somewhere with no fence of its own -- the storefront
// import page, which builds the vault in the BROWSER and PUTs it straight to the store. Running
// createVault under a different NOWHERE_STATE is how NWP-20260910-20 modelled it: from the fence's point
// of view "another state dir" and "no fence dir at all" are the same thing, and the vault it produces is
// real, with FRESH entropy and therefore a different recovery ref.
func recreateOffDevice(t *testing.T, base, name, pass string) {
	t.Helper()
	saved, had := os.LookupEnv("NOWHERE_STATE")
	if err := os.Setenv("NOWHERE_STATE", t.TempDir()); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if had {
			os.Setenv("NOWHERE_STATE", saved)
		} else {
			os.Unsetenv("NOWHERE_STATE")
		}
	}()
	createVault(base, name, pass)
}

// ⚠⚠ THE LIFT REMOVES ITS OWN TRIGGER, so a trigger that reads only the bare pair fires AT MOST ONCE per
// name per boot -- and anything still armed after that first lift is stranded for good. Found by an
// adversarial pass on the first cut of NWP-20260921-06, which widened the SET the lift covers and left
// the trigger reading the same two refs it always had. `deleteScopeSuffixes[0]` is "", so those two refs
// are the first two entries of the lift set: the lift is guaranteed to consume them.
//
// This is the sibling of TestLoginLiftClearsEveryMarkerTheDeleteArmed and the two are not redundant.
// That one proves the lift covers the whole arm set WHEN IT RUNS. This one proves it still runs the
// second time it is needed, which is a different failure and the one the first fix could not see: with
// the widened set but the old trigger, the marker below survives and the wedge comes straight back.
func TestLoginLiftStillFiresAfterAnEarlierLiftConsumedTheTrigger(t *testing.T) {
	fenceTestEnv(t)

	name, pass := "alice", "correct horse battery"
	base := newHookStore(t, nil)
	createVault(base, name, pass)

	origHead := getRef(base, profileRefV2(name, pass))
	v, isV := parseVault(getHeadBlob(base, origHead))
	if !isV || v.RecoveryRef == "" {
		t.Fatal("setup: the vault must carry a recovery ref")
	}
	origRec := v.RecoveryRef

	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("delete: got %q want deleted", got)
	}
	if !sealFenceBlocks(origRec) {
		t.Fatal("setup: the delete did not fence the original recovery ref")
	}

	// (2) The name is re-created off this device: FRESH entropy, so a different recovery ref.
	recreateOffDevice(t, base, name, pass)
	newHead := getRef(base, profileRefV2(name, pass))
	if newHead == "" || newHead == origHead {
		t.Fatalf("setup: the re-create did not produce a NEW head (got %q, orig %q)", newHead, origHead)
	}
	if nv, ok := parseVault(getHeadBlob(base, newHead)); !ok || nv.RecoveryRef == origRec {
		t.Fatal("setup: the re-created vault must carry a DIFFERENT recovery ref, or this test is the other one")
	}

	// (3) A login against the RE-CREATED head. The lift fires, clears the bare pair, and removes a
	// recovery ref that was never armed. This is the step that consumes the trigger.
	if _, _, _, ok := resolveKeyHeadForLogin(base, name, pass); !ok {
		t.Fatal("the re-created profile did not resolve at login")
	}
	if !sealFenceBlocks(origRec) {
		t.Skip("the first lift already cleared the ORIGINAL recovery ref, so this test cannot stage its " +
			"own precondition -- the mechanism it guards has changed shape and it needs rewriting, not deleting")
	}

	// (4) The ORIGINAL vault bytes come back -- the same recovery ref the delete armed. Written straight
	// to the store: the storefront would refuse this particular route (its destination holds a different
	// head), but a self-hosted store has no preflight, and seal_fence.go's header names exactly that case
	// as the one where this client-side fence is the only half there is.
	storePutRef(t, base, profileRefV2(name, pass), origHead)

	// (5) The login that MUST still be able to lift.
	if _, _, _, ok := resolveKeyHeadForLogin(base, name, pass); !ok {
		t.Fatal("the restored original did not resolve at login")
	}
	if sealFenceBlocks(origRec) {
		t.Fatal("the original recovery ref is STILL armed after a second login: the first lift consumed " +
			"the trigger, so nothing can ever reach this marker again. pushProfile re-PUTs the recovery " +
			"ref on every vault seal, so this profile can log in and never log off -- the exact wedge " +
			"NWP-20260921-06 was written to close, reached by a second route.")
	}
	if left := fenceMarkers(t); len(left) > 0 {
		t.Fatalf("the second login left %d marker(s) armed: %v", len(left), left)
	}

	pushProfile(base, name, pass, seedDir(t, 2))
	if sealFenceHit {
		t.Fatal("the seal was still refused after the second lift")
	}
}
