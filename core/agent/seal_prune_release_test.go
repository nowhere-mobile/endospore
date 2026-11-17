package main

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"math/rand"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261204-06: a bare-vault seal releases the chunks of the snapshots its retention dropped.
// test-seal-prune-release.sh re-runs this file against copies of seal_prune_release.go (and main.go) with each guard
// broken in turn.

// sprel is one cap-mode profile: the mock store, the /release bodies it took, and the seal source dir.
type sprel struct {
	snapRel        // objs, mu, base, name, pass, dk, reqs, status, cache; sent() decodes reqs
	src     string // the seal source dir
	big     int    // the size of each unchanged file
	round   int
}

// sprelSetup is snapRelSetup without its seals: cap mode, a funded wallet, its own blob cache dir, the retention of
// snapDelSeals (8 automatic snapshots), and every POST /release recorded and answered with the keys it named.
func sprelSetup(t *testing.T, name, pass string, big int) *sprel {
	t.Helper()
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	freeRenewedThrough = map[string]int64{}
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	t.Setenv("NOWHERE_STATE", dir)
	t.Setenv("NOWHERE_BLOBCACHE", dir)
	t.Setenv("NOWHERE_MULTIDEVICE", "")
	t.Setenv("NOWHERE_SNAP_AUTO_RECENT", "8")
	t.Setenv("NOWHERE_SNAP_AUTO", "8")
	blobCache = nil
	t.Cleanup(func() { blobCache = nil })
	capStoreLeaseStatus = func(leaseReq) (int, string) { return 200, "" }
	r := &sprel{snapRel: snapRel{objs: objs, mu: mu, base: "s3", name: name, pass: pass, status: 200, cache: blobCachePath()},
		src: t.TempDir(), big: big}
	capStoreRelease = func(b []byte) (int, string) {
		r.mu.Lock()
		r.reqs = append(r.reqs, b)
		r.mu.Unlock()
		return r.status, `{"released":[]}`
	}
	if createVault(r.base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	return r
}

// sprelRandom is n fixed-seed random bytes: incompressible, so a file of 3x cdcMax owns whole chunks of its own.
func sprelRandom(seed int64, n int) []byte {
	b := make([]byte, n)
	rand.New(rand.NewSource(seed)).Read(b)
	return b
}

// seal writes this round's files and seals: churn.txt is new each round, stay.bin is the same in every round, and
// gone.bin is the same while withGone and absent after.
func (r *sprel) seal(t *testing.T, withGone bool) string {
	t.Helper()
	body := bytes.Repeat([]byte(fmt.Sprintf("round %d of %s ", r.round, r.name)), 900)
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
	return captureStdout(t, func() { pushProfile(r.base, r.name, r.pass, r.src) })
}

// prune makes the next seal keep two automatic snapshots, so the four seals before it leave entries to drop.
func sprelPrune(t *testing.T) {
	t.Setenv("NOWHERE_SNAP_AUTO", "2")
	t.Setenv("NOWHERE_SNAP_AUTO_RECENT", "2")
	t.Setenv("NOWHERE_SNAP_AUTO_HOURLY", "0")
}

func (r *sprel) releases() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.reqs)
}

// blobsOf is the union of manifestBlobsStrict over ms.
func (r *sprel) blobsOf(t *testing.T, ms ...string) map[string]bool {
	t.Helper()
	out := map[string]bool{}
	for _, m := range ms {
		if err := manifestBlobsStrict(r.base, r.dk, m, out); err != nil {
			t.Fatalf("fixture: manifest %s: %v", short(m), err)
		}
	}
	return out
}

func histManifests(h []headSnap) []string {
	var out []string
	for _, s := range h {
		out = append(out, s.Manifest)
	}
	return out
}

// the four seals before the pruning one, each kept under a retention of 8.
func (r *sprel) fourSeals(t *testing.T) {
	t.Helper()
	for i := 0; i < 4; i++ {
		r.seal(t, true)
	}
	v, dk := snapDelHead(t, r.base, r.name, r.pass)
	r.dk = dk
	if len(v.History) < 4 {
		t.Fatalf("fixture: %d snapshots after four seals, want 4", len(v.History))
	}
}

func (r *sprel) relGenRecorded(t *testing.T) uint64 {
	t.Helper()
	g, ok := relGenSeen(r.cache, relGenHeadKey(r.base, r.name, r.pass))
	if !ok {
		t.Fatal("no release generation recorded for the head")
	}
	return g
}

func TestSealPruneReleaseDropped(t *testing.T) {
	h := func(ms ...string) []headSnap {
		var out []headSnap
		for i, m := range ms {
			out = append(out, headSnap{Version: uint64(10 - i), Manifest: m})
		}
		return out
	}
	cases := []struct {
		what    string
		oldHead string
		oldHist []headSnap
		newHead string
		newHist []headSnap
		want    []string
	}{
		{"none dropped", "c", h("b", "a"), "d", h("c", "b", "a"), nil},
		{"one pruned", "c", h("b", "a"), "d", h("c", "b"), []string{"a"}},
		{"the outgoing head kept in newHist", "c", nil, "d", h("c"), nil},
		{"the outgoing head pruned with the oldest", "c", h("b", "a"), "d", h("b"), []string{"a", "c"}},
		{"a dropped manifest equal to a kept one", "c", h("b", "a", "b"), "d", h("c", "b"), []string{"a"}},
		{"a dropped manifest equal to the new head", "c", h("d", "a"), "d", h("c"), []string{"a"}},
		{"deduplicated and sorted", "z", h("y", "x", "y", "x"), "d", nil, []string{"x", "y", "z"}},
		{"empty manifests skipped", "", h("", "a"), "d", nil, []string{"a"}},
	}
	for _, c := range cases {
		got := sealPruneDropped(c.oldHead, c.oldHist, c.newHead, c.newHist)
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: dropped %q, want %q", c.what, got, c.want)
		}
	}
}

func TestSealPruneReleaseEligible(t *testing.T) {
	t.Setenv("GATEWAY_URL", "http://127.0.0.1:1")
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_MULTIDEVICE", "")
	if !sealPruneReleaseEligible("sprel-elig") {
		t.Error("a bare profile in cap mode is not eligible")
	}
	if sealPruneReleaseEligible("sprel-elig#de") {
		t.Error("a scope head is eligible while scopeReleaseOn is off")
	}
	// NWP-20261207-03: with the scope release on, a #de vault is eligible and #media is not (a later slice).
	old := scopeReleaseOn
	scopeReleaseOn = true
	t.Cleanup(func() { scopeReleaseOn = old })
	if !sealPruneReleaseEligible("sprel-elig#de") {
		t.Error("a #de scope is not eligible with scopeReleaseOn")
	}
	if sealPruneReleaseEligible("sprel-elig#media") {
		t.Error("a #media scope is eligible: its export pin and kept-manifest bound are a later slice")
	}
	scopeReleaseOn = old
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	if sealPruneReleaseEligible("sprel-elig") {
		t.Error("eligible under NOWHERE_MULTIDEVICE=1: other devices' kept snapshots are not read")
	}
	t.Setenv("NOWHERE_MULTIDEVICE", "")
	t.Setenv("S3_ACCESS_KEY", "a-test-access-key")
	if sealPruneReleaseEligible("sprel-elig") {
		t.Error("eligible with S3 keys: only the gateway has POST /release")
	}
}

func TestSealPruneReleaseGate(t *testing.T) {
	for _, landed := range []bool{false, true} {
		for _, refused := range []bool{false, true} {
			for _, stopped := range []bool{false, true} {
				want := landed && !refused && !stopped
				if got := sealPruneReleaseGate(landed, refused, stopped); got != want {
					t.Errorf("gate(landed=%v, refused=%v, stopped=%v) = %v, want %v", landed, refused, stopped, got, want)
				}
			}
		}
	}
}

func TestSealPruneReleaseFrees(t *testing.T) {
	r := sprelSetup(t, "sprel-frees", "the pruned chunks go", 3*cdcMax)
	r.fourSeals(t)
	before, _ := snapDelHead(t, r.base, r.name, r.pass)
	sprelPrune(t)
	cacheBefore, _ := os.ReadFile(r.cache) // the cache as the pruning seal finds it
	logs := r.seal(t, false)
	if sealRefused {
		t.Fatalf("fixture: the pruning seal was refused: %s", logs)
	}
	after, _ := snapDelHead(t, r.base, r.name, r.pass)
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
	want := r.blobsOf(t, dropped...)
	head := r.blobsOf(t, after.Manifest)
	hist := r.blobsOf(t, histManifests(after.History)...)
	shared := 0 // dropped AND kept History, not the new head: only the History half of the keep set protects these
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
		} else if p != hex.EncodeToString(blobReleaseProof(r.dk, k)) {
			t.Errorf("%s: the preimage is not blobReleaseProof(dk, key)", short(k))
		}
	}
	for k := range got {
		if !want[k] {
			t.Errorf("%s was released, but a kept version or the new head names it", short(k))
		}
	}
	if after.ReleaseGen != before.ReleaseGen+1 {
		t.Errorf("head generation %d -> %d, want +1", before.ReleaseGen, after.ReleaseGen)
	}
	cacheAfter, _ := os.ReadFile(r.cache)
	for k := range got {
		if strings.Contains(string(cacheAfter), strings.TrimPrefix(k, "blob/")) {
			t.Errorf("the cache still names the released %s", short(k))
		}
	}
	if g := r.relGenRecorded(t); g != after.ReleaseGen {
		t.Errorf("recorded generation %d, the head carries %d", g, after.ReleaseGen)
	}
	if !strings.Contains(logs, "unshared object(s) released for the next collection") {
		t.Errorf("no released line:\n%s", logs)
	}
}

func TestSealPruneReleaseNothingWhenNothingDropped(t *testing.T) {
	r := sprelSetup(t, "sprel-none", "nothing drops", 4096)
	r.fourSeals(t)
	before, _ := snapDelHead(t, r.base, r.name, r.pass)
	r.seal(t, true)
	after, _ := snapDelHead(t, r.base, r.name, r.pass)
	if len(after.History) != len(before.History)+1 {
		t.Fatalf("fixture: the fifth seal kept %d snapshots, want %d", len(after.History), len(before.History)+1)
	}
	if n := r.releases(); n != 0 {
		t.Errorf("%d /release request(s) for a seal that dropped nothing", n)
	}
	if after.ReleaseGen != before.ReleaseGen {
		t.Errorf("head generation %d -> %d for a seal that dropped nothing", before.ReleaseGen, after.ReleaseGen)
	}
}

func TestSealPruneReleaseUnreadable(t *testing.T) {
	r := sprelSetup(t, "sprel-unread", "a kept one is gone", 4096)
	r.fourSeals(t)
	before, _ := snapDelHead(t, r.base, r.name, r.pass)
	// History[0] is the outgoing head's predecessor, which the pruning seal keeps (two recent) and never reads.
	r.mu.Lock()
	delete(r.objs, "blob/"+before.History[0].Manifest)
	r.mu.Unlock()
	sprelPrune(t)
	logs := r.seal(t, true)
	if sealRefused {
		t.Fatalf("the seal was refused: %s", logs)
	}
	after, _ := snapDelHead(t, r.base, r.name, r.pass)
	if after.ReleaseGen != before.ReleaseGen+1 {
		t.Fatalf("fixture: head generation %d -> %d, want +1 (nothing dropped?)", before.ReleaseGen, after.ReleaseGen)
	}
	if n := r.releases(); n != 0 {
		t.Errorf("%d /release request(s) with a kept version unreadable", n)
	}
	if !strings.Contains(logs, "nothing released early -- a kept version could not be read") {
		t.Errorf("no reason line:\n%s", logs)
	}
	if g := r.relGenRecorded(t); g != after.ReleaseGen {
		t.Errorf("recorded generation %d, the head carries %d: the next seal drops the whole cache", g, after.ReleaseGen)
	}
}

func TestSealPruneReleaseSlowStore(t *testing.T) {
	tr := trackGoSafe(t)
	r := sprelSetup(t, "sprel-slow", "the store is slow", 4096)
	r.fourSeals(t)
	before, _ := snapDelHead(t, r.base, r.name, r.pass)
	saved := sealPruneSetWait
	sealPruneSetWait = 50 * time.Millisecond
	t.Cleanup(func() { sealPruneSetWait = saved })
	wref, _ := headWriteRef(r.name, r.pass)
	var landed atomic.Bool
	unblock := make(chan struct{})
	var once sync.Once
	release := func() { once.Do(func() { close(unblock) }) }
	t.Cleanup(release)
	capStorePutHook = func(k string, _ []byte) error {
		if k == "ref/"+wref {
			landed.Store(true)
		}
		return nil
	}
	capStoreGetSeen = func(string) {
		if landed.Load() {
			select {
			case <-unblock:
			case <-time.After(time.Second):
			}
		}
	}
	sprelPrune(t)
	logs := r.seal(t, true)
	release()
	// The set job outlives the step: wait for it, so it reads no store after this test.
	deadline := time.Now().Add(20 * time.Second)
	for {
		tr.mu.Lock()
		n := tr.live["seal-prune-set"]
		tr.mu.Unlock()
		if n == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the set job is still running")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if sealRefused {
		t.Fatalf("the seal was refused: %s", logs)
	}
	after, _ := snapDelHead(t, r.base, r.name, r.pass)
	if after.ReleaseGen != before.ReleaseGen+1 {
		t.Fatalf("fixture: head generation %d -> %d, want +1", before.ReleaseGen, after.ReleaseGen)
	}
	if n := r.releases(); n != 0 {
		t.Errorf("%d /release request(s) from a set that was not ready in time", n)
	}
	if !strings.Contains(logs, "nothing released early -- the kept versions were not read in time") {
		t.Errorf("no reason line:\n%s", logs)
	}
	if g := r.relGenRecorded(t); g != after.ReleaseGen {
		t.Errorf("recorded generation %d, the head carries %d", g, after.ReleaseGen)
	}
}

func TestSealPruneReleaseRefused(t *testing.T) {
	r := sprelSetup(t, "sprel-refused", "the head moved", 4096)
	t.Cleanup(clearStaleHit)
	r.fourSeals(t)
	moveHeadAtFlush(r.objs, r.mu, r.name, r.pass)
	sprelPrune(t)
	logs := r.seal(t, true)
	if n := r.releases(); n != 0 {
		t.Errorf("%d /release request(s) from a seal whose head did not land\n%s", n, logs)
	}
	if strings.Contains(logs, "nothing released early") {
		t.Errorf("the release step ran for a seal whose head did not land:\n%s", logs)
	}
}

func TestSealPruneReleaseRecoveryRefLags(t *testing.T) {
	r := sprelSetup(t, "sprel-recov", "the recovery copy lags", 4096)
	r.fourSeals(t)
	before, _ := snapDelHead(t, r.base, r.name, r.pass)
	if before.RecoveryRef == "" {
		t.Fatal("fixture: the vault has no recovery ref")
	}
	prev := snapDelHeadBlob(r.base, r.name, r.pass)
	rkey := "ref/" + before.RecoveryRef
	var put, done atomic.Bool
	capStorePutHook = func(k string, _ []byte) error {
		if k == rkey {
			put.Store(true)
		}
		return nil
	}
	capStoreGetSeen = func(k string) {
		if k == rkey && put.Load() && done.CompareAndSwap(false, true) {
			r.mu.Lock()
			r.objs[k] = []byte(prev)
			r.mu.Unlock()
		}
	}
	sprelPrune(t)
	logs := r.seal(t, true)
	if !done.Load() {
		t.Fatalf("fixture: the recovery ref was never read back after it landed\n%s", logs)
	}
	if n := r.releases(); n != 0 {
		t.Errorf("%d /release request(s) while the recovery ref names the previous vault\n%s", n, logs)
	}
	if !strings.Contains(logs, "nothing released early -- the recovery copy does not name this seal") {
		t.Errorf("no reason line:\n%s", logs)
	}
}

func TestSealPruneReleaseOldGateway(t *testing.T) {
	r := sprelSetup(t, "sprel-oldgw", "no release route", 4096)
	r.fourSeals(t)
	capStoreRelease = nil // 404
	sprelPrune(t)
	logs := r.seal(t, true)
	if sealRefused {
		t.Fatalf("the seal was refused: %s", logs)
	}
	if !strings.Contains(logs, "nothing released early -- the gateway does not release early") {
		t.Errorf("no old-gateway line:\n%s", logs)
	}
}

// TestSealPruneReleaseSourceNeverFormatsASecret: every fmt/log call in seal_prune_release.go takes only string
// literals and the profile tag, reason and count idents -- never a key, a hash, a preimage, a commitment or a URL.
func TestSealPruneReleaseSourceNeverFormatsASecret(t *testing.T) {
	fs := token.NewFileSet()
	f, err := parser.ParseFile(fs, "seal_prune_release.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	ok := map[string]bool{"lp": true, "why": true, "status": true, "n": true, "m": true, "evicted": true}
	calls := 0
	ast.Inspect(f, func(n ast.Node) bool {
		ce, isCall := n.(*ast.CallExpr)
		if !isCall {
			return true
		}
		sel, isSel := ce.Fun.(*ast.SelectorExpr)
		if !isSel {
			return true
		}
		id, isID := sel.X.(*ast.Ident)
		if !isID || (id.Name != "fmt" && id.Name != "log") {
			return true
		}
		calls++
		for _, a := range ce.Args {
			switch x := a.(type) {
			case *ast.BasicLit:
			case *ast.Ident:
				if !ok[x.Name] {
					t.Errorf("%s: %s.%s formats %q", fs.Position(a.Pos()), id.Name, sel.Sel.Name, x.Name)
				}
			default:
				t.Errorf("%s: %s.%s takes a computed argument", fs.Position(a.Pos()), id.Name, sel.Sel.Name)
			}
		}
		return true
	})
	if calls == 0 {
		t.Error("found no fmt/log call: the pin is not looking at anything")
	}
}
