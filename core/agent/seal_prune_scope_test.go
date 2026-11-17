package main

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261207-03: a #de, #sys, #keys or #apps head that is a VAULT releases at its seal the chunks its retention
// dropped, and its release generation is checked at that scope's push and restore. test-seal-prune-scope.sh re-runs
// these tests against copies of seal_prune_release.go, release_gen.go and main.go with each guard broken in turn.
// Every test uses its OWN profile name and its own blob cache dir (sprelSetup or relGenEnv).

// sprscOn turns the scope release on for one test.
func sprscOn(t *testing.T) {
	t.Helper()
	old := scopeReleaseOn
	scopeReleaseOn = true
	t.Cleanup(func() { scopeReleaseOn = old })
}

// sprscSeal is (*sprel).seal for the scope head `scoped`: the same three files, sealed under the scope.
func sprscSeal(t *testing.T, r *sprel, scoped string, withGone bool) string {
	t.Helper()
	body := bytes.Repeat([]byte(fmt.Sprintf("round %d of %s ", r.round, scoped)), 900)
	r.round++
	if err := os.WriteFile(filepath.Join(r.src, "churn.txt"), body, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(r.src, "stay.bin"), sprelRandom(1, r.big), 0o600); err != nil {
		t.Fatal(err)
	}
	gone := filepath.Join(r.src, "gone.bin")
	if withGone {
		if err := os.WriteFile(gone, sprelRandom(2, r.big), 0o600); err != nil {
			t.Fatal(err)
		}
	} else if err := os.Remove(gone); err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return captureStdout(t, func() { pushProfile(r.base, scoped, r.pass, r.src) })
}

// sprscBlobs is the union of manifestBlobsStrict over ms under the scope key (r.dk is the bare DK).
func sprscBlobs(t *testing.T, r *sprel, key []byte, ms ...string) map[string]bool {
	t.Helper()
	out := map[string]bool{}
	for _, m := range ms {
		if err := manifestBlobsStrict(r.base, key, m, out); err != nil {
			t.Fatalf("fixture: manifest %s: %v", short(m), err)
		}
	}
	return out
}

// sprscVault seals one bare-shaped head for `scoped`, then publishes buildScopeVault over it in a cap bracket: the
// head a credential change or a tie leaves. It returns the scope key.
func sprscVault(t *testing.T, r *sprel, scoped string) []byte {
	t.Helper()
	sprscSeal(t, r, scoped, true)
	h1 := readHead(r.base, scoped, r.pass)
	if h1 == "" {
		t.Fatal("fixture: the bare-shaped seal published no head")
	}
	key := deriveKey(scoped, r.pass)
	n := capBegin()
	capSetSession(scoped, r.pass, key)
	publishRepointVault(r.base, scoped, r.pass, buildScopeVault(key, scoped, r.pass, h1))
	capFlush(n)
	if _, isV := parseVault(getHeadBlob(r.base, readHead(r.base, scoped, r.pass))); !isV {
		t.Fatal("fixture: the scope head is not a vault")
	}
	return key
}

// sprscPlainVault is sprscVault on a plain (non-cap) store, with the vault's release generation set to gen.
func sprscPlainVault(t *testing.T, base, scoped, pass string, gen uint64) string {
	t.Helper()
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "k.txt"), []byte("payload "+scoped), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, scoped, pass, src)
	h1 := readHead(base, scoped, pass)
	if h1 == "" {
		t.Fatal("fixture: the bare-shaped seal published no head")
	}
	key := deriveKey(scoped, pass)
	v := buildScopeVault(key, scoped, pass, h1)
	v.ReleaseGen = gen
	signVault(v, key)
	return publishRepointVault(base, scoped, pass, v)
}

func TestSealPruneScopeScope(t *testing.T) {
	for p, want := range map[string]bool{
		"a": true, "a#de": true, "a#sys": true, "a#keys": true, "a#apps": true,
		"a#media": false, "a#wallet": false, "a#dex": false, "a#": false, "a#de#x": false,
	} {
		if got := relGenScope(p); got != want {
			t.Errorf("relGenScope(%q) = %v, want %v", p, got, want)
		}
	}
}

func TestSealPruneScopeOffByDefault(t *testing.T) {
	if scopeReleaseOn {
		t.Fatal("scopeReleaseOn is true at package init: the scope release must ship off")
	}
	t.Setenv("GATEWAY_URL", "http://127.0.0.1:1")
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_MULTIDEVICE", "")
	if sealPruneReleaseEligible("sprsc-off#de") {
		t.Error("a #de scope is eligible while scopeReleaseOn is off")
	}
	if !sealPruneReleaseEligible("sprsc-off") {
		t.Error("the bare vault is not eligible in cap mode")
	}
}

func TestSealPruneScopeVaultFrees(t *testing.T) {
	r := sprelSetup(t, "sprsc-frees", "the pruned scope chunks go", 3*cdcMax)
	sprscOn(t)
	scoped := r.name + "#de"
	sprscVault(t, r, scoped)
	for i := 0; i < 4; i++ {
		sprscSeal(t, r, scoped, true)
	}
	before, key := snapDelHead(t, r.base, scoped, r.pass)
	bareKey := relGenHeadKey(r.base, r.name, r.pass)
	if err := relGenRecord(r.cache, bareKey, 7); err != nil {
		t.Fatal(err)
	}
	sprelPrune(t)
	cacheBefore, _ := os.ReadFile(r.cache)
	logs := sprscSeal(t, r, scoped, false)
	if sealRefused {
		t.Fatalf("fixture: the pruning seal was refused: %s", logs)
	}
	after, _ := snapDelHead(t, r.base, scoped, r.pass)
	kept := map[string]bool{after.Manifest: true}
	for _, s := range after.History {
		kept[s.Manifest] = true
	}
	var dropped []string
	for _, m := range append([]string{before.Manifest}, histManifests(before.History)...) {
		if !kept[m] {
			dropped = append(dropped, m)
		}
	}
	want := sprscBlobs(t, r, key, dropped...)
	head := sprscBlobs(t, r, key, after.Manifest)
	hist := sprscBlobs(t, r, key, histManifests(after.History)...)
	shared := 0
	for k := range want {
		if hist[k] && !head[k] {
			shared++
		}
	}
	for k := range head {
		delete(want, k)
	}
	for k := range hist {
		delete(want, k)
	}
	if len(dropped) == 0 || len(want) == 0 {
		t.Fatalf("fixture: %d dropped, %d to release", len(dropped), len(want))
	}
	if shared == 0 {
		t.Fatal("fixture: no chunk is shared by a dropped and a kept snapshot alone")
	}
	cachedWant := false
	for k := range want {
		if strings.Contains(string(cacheBefore), strings.TrimPrefix(k, "blob/")) {
			cachedWant = true
		}
	}
	if !cachedWant {
		t.Fatal("fixture: the cache named no key of the release set before the pruning seal")
	}

	got := r.sent(t)
	if len(got) != len(want) {
		t.Errorf("released %d keys, want %d\n%s", len(got), len(want), logs)
	}
	for k := range want {
		if p, ok := got[k]; !ok {
			t.Errorf("%s was not released", short(k))
		} else if p != hex.EncodeToString(blobReleaseProof(key, k)) {
			t.Errorf("%s: the preimage is not blobReleaseProof(scope key, key)", short(k))
		}
	}
	for k := range got {
		if !want[k] {
			t.Errorf("%s was released, but a kept version or the new head names it", short(k))
		}
	}
	if after.ReleaseGen != before.ReleaseGen+1 {
		t.Errorf("scope head generation %d -> %d, want +1", before.ReleaseGen, after.ReleaseGen)
	}
	if g, ok := relGenSeen(r.cache, relGenHeadKey(r.base, scoped, r.pass)); !ok || g != after.ReleaseGen {
		t.Errorf("recorded scope generation (%d, %v), the head carries %d", g, ok, after.ReleaseGen)
	}
	if g, ok := relGenSeen(r.cache, bareKey); !ok || g != 7 {
		t.Errorf("the bare head's record changed to (%d, %v), want (7, true)", g, ok)
	}
	cacheAfter, _ := os.ReadFile(r.cache)
	for k := range got {
		if strings.Contains(string(cacheAfter), strings.TrimPrefix(k, "blob/")) {
			t.Errorf("the cache still names the released %s", short(k))
		}
	}
}

func TestSealPruneScopeMediaNotYet(t *testing.T) {
	r := sprelSetup(t, "sprsc-media", "the media scope keeps its chunks", 3*cdcMax)
	sprscOn(t)
	scoped := r.name + "#media"
	sprscVault(t, r, scoped)
	for i := 0; i < 4; i++ {
		sprscSeal(t, r, scoped, true)
	}
	before, _ := snapDelHead(t, r.base, scoped, r.pass)
	sprelPrune(t)
	logs := sprscSeal(t, r, scoped, false)
	after, _ := snapDelHead(t, r.base, scoped, r.pass)
	if len(after.History) >= len(before.History)+1 {
		t.Fatalf("fixture: the pruning seal dropped nothing (%d -> %d snapshots)\n%s", len(before.History), len(after.History), logs)
	}
	if n := r.releases(); n != 0 {
		t.Errorf("%d /release request(s) for a #media seal: #media is a later slice\n%s", n, logs)
	}
	if after.ReleaseGen != before.ReleaseGen {
		t.Errorf("#media head generation %d -> %d", before.ReleaseGen, after.ReleaseGen)
	}
}

func TestSealPruneScopeBareShapedNothing(t *testing.T) {
	r := sprelSetup(t, "sprsc-bare", "a bare-shaped scope keeps its chunks", 4096)
	sprscOn(t)
	scoped := r.name + "#sys"
	if err := relGenRecord(r.cache, relGenHeadKey(r.base, r.name, r.pass), 2); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(relGenPath(r.cache))
	for i := 0; i < 4; i++ {
		sprscSeal(t, r, scoped, true)
	}
	sprelPrune(t)
	logs := sprscSeal(t, r, scoped, false)
	if n := r.releases(); n != 0 {
		t.Errorf("%d /release request(s) for a bare-shaped scope head\n%s", n, logs)
	}
	if _, isV := parseVault(getHeadBlob(r.base, readHead(r.base, scoped, r.pass))); isV {
		t.Error("the bare-shaped scope head became a vault")
	}
	if after, _ := os.ReadFile(relGenPath(r.cache)); string(after) != string(before) {
		t.Errorf("a bare-shaped scope seal rewrote the relgen file:\n%s\n--\n%s", before, after)
	}
}

func TestSealPruneScopePushDistrust(t *testing.T) {
	base := newHTTPStore(t)
	p := relGenEnv(t)
	const name, pass = "sprsc-push", "scope push release generation horse staple"
	createVault(base, name, pass)
	scoped := name + "#keys"
	sprscPlainVault(t, base, scoped, pass, 3)
	hk := relGenHeadKey(base, scoped, pass)
	push := func() string {
		t.Helper()
		src := t.TempDir()
		if err := os.WriteFile(filepath.Join(src, "k.txt"), []byte("next payload "+scoped), 0o600); err != nil {
			t.Fatal(err)
		}
		var out string
		if didPanic(func() { out = captureStdout(t, func() { pushProfile(base, scoped, pass, src) }) }) || sealRefused {
			t.Fatalf("the scope seal failed:\n%s", out)
		}
		return out
	}

	// (a) no record: a generation of 3 drops the cache and is recorded.
	blobCacheAdd("sprscpushK")
	push()
	if blobCacheKnown("sprscpushK") {
		t.Error("a scope vault seal at generation 3 with no record kept the chunk cache")
	}
	if g, ok := relGenSeen(p, hk); !ok || g != 3 {
		t.Errorf("record after the scope seal = (%d, %v), want (3, true)", g, ok)
	}

	// (b) the record matches: the cache is kept.
	blobCache = nil
	blobCacheAdd("sprscpushK2")
	push()
	if !blobCacheKnown("sprscpushK2") {
		t.Error("a scope vault seal at the recorded generation dropped the chunk cache")
	}
}

func TestSealPruneScopeRestoreDistrust(t *testing.T) {
	base := newHTTPStore(t)
	p := relGenEnv(t)
	const name, pass = "sprsc-restore", "scope restore release generation horse staple"
	createVault(base, name, pass)
	scoped := name + "#keys"
	head := sprscPlainVault(t, base, scoped, pass, 3)
	hk := relGenHeadKey(base, scoped, pass)

	// (a) a scope vault at generation 3 over a record of 1: the cache is dropped and 3 recorded.
	if err := relGenRecord(p, hk, 1); err != nil {
		t.Fatal(err)
	}
	blobCache = nil
	blobCacheAdd("sprscrestoreK")
	captureStdout(t, func() { relGenAtScopeRestore(base, scoped, pass, head) })
	if relGenCacheLines(p)["sprscrestoreK"] || blobCacheKnown("sprscrestoreK") {
		t.Error("a scope vault restore kept a chunk cache filled under an older release generation")
	}
	if g, ok := relGenSeen(p, hk); !ok || g != 3 {
		t.Errorf("record after the scope restore = (%d, %v), want (3, true)", g, ok)
	}

	// (b) a bare-shaped #de head: neither the record nor the cache is touched.
	const name2 = "sprsc-restore-bare"
	createVault(base, name2, pass)
	de := name2 + "#de"
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "d.txt"), []byte("payload "+de), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, de, pass, src)
	deHead := readHead(base, de, pass)
	if _, isV := parseVault(getHeadBlob(base, deHead)); isV || deHead == "" {
		t.Fatal("fixture: the #de head is not bare-shaped")
	}
	if err := relGenRecord(p, relGenHeadKey(base, de, pass), 5); err != nil {
		t.Fatal(err)
	}
	blobCache = nil
	blobCacheAdd("sprscrestoreK2")
	before, _ := os.ReadFile(relGenPath(p))
	captureStdout(t, func() { relGenAtScopeRestore(base, de, pass, deHead) })
	if after, _ := os.ReadFile(relGenPath(p)); string(after) != string(before) {
		t.Errorf("a bare-shaped scope restore rewrote the relgen file:\n%s\n--\n%s", before, after)
	}
	if !relGenCacheLines(p)["sprscrestoreK2"] {
		t.Error("a bare-shaped scope restore dropped the blob cache")
	}

	// (c) the restore verb itself: a record of 1 under a generation-3 scope vault drops the cache before it seeds it.
	if err := relGenRecord(p, hk, 1); err != nil {
		t.Fatal(err)
	}
	blobCache = nil
	blobCacheAdd("sprscrestoreK3")
	out := relGenRestore(t, base, scoped, pass)
	lines := relGenCacheLines(p)
	if lines["sprscrestoreK3"] {
		t.Errorf("the restore verb kept a scope vault's chunk cache filled under an older release generation\n%s", out)
	}
	if len(lines) == 0 {
		t.Error("the restore verb seeded nothing into the dropped cache")
	}
	if g, ok := relGenSeen(p, hk); !ok || g != 3 {
		t.Errorf("record after the restore verb = (%d, %v), want (3, true)", g, ok)
	}

	// (d) the restore verb calls it before the manifest is unsealed (and so before cdcRestore seeds the cache).
	body := fileFuncBody(t, "main.go", "main")
	i := strings.Index(body, `case "restore":`)
	j := strings.Index(body, "relGenAtScopeRestore(base, profile, pass, restoredHead)")
	k := strings.Index(body, "pt := unseal(key, manifestBlob)")
	if i < 0 || j < i || k < j {
		t.Error("the restore verb does not call relGenAtScopeRestore(base, profile, pass, restoredHead) before it unseals the manifest")
	}
}
