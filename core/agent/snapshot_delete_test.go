package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261027-04: DELETE-SNAPSHOT removes one retained snapshot from a profile's History and reseals the vault.
// test-snapshot-delete.sh re-runs this file against copies of snapshot_delete.go with each guard broken in turn.

// snapDelSeals creates a profile and seals it n times with different contents, so it holds n-1 snapshots (the
// first seal has nothing to snapshot).
func snapDelSeals(t *testing.T, base, name, pass string, n int) {
	t.Helper()
	t.Setenv("NOWHERE_SNAP_AUTO_RECENT", "8")
	t.Setenv("NOWHERE_SNAP_AUTO", "8")
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	src := t.TempDir()
	for i := 0; i < n; i++ {
		body := bytes.Repeat([]byte(fmt.Sprintf("round %d of %s ", i, name)), 900)
		if err := os.WriteFile(filepath.Join(src, "f.txt"), body, 0o600); err != nil {
			t.Fatal(err)
		}
		pushProfile(base, name, pass, src)
	}
	if got := len(snapshotList(base, name, pass)); got < n-1 {
		t.Fatalf("fixture: %d snapshots after %d seals, want %d", got, n, n-1)
	}
}

// snapDelHead reads the profile's vault and the DK its passphrase slot opens.
func snapDelHead(t *testing.T, base, name, pass string) (*vault, []byte) {
	t.Helper()
	_, v, ok := readVaultHead(base, name, pass)
	if !ok || v == nil {
		t.Fatal("the profile has no vault head")
	}
	dk := unwrapDK(v, "pass", deriveKey(name, pass))
	if dk == nil {
		t.Fatal("the pass slot does not open the vault")
	}
	return v, dk
}

func snapDelHeadBlob(base, name, pass string) string {
	return getRef(base, headKey(base, name, pass))
}

func snapDelVersions(h []headSnap) []uint64 {
	var out []uint64
	for _, s := range h {
		out = append(out, s.Version)
	}
	return out
}

func TestDeleteSnapshotRemovesOnlyTheMiddleEntry(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "snapdel-a", "a middle one goes"
	snapDelSeals(t, base, name, pass, 4)
	before, dk := snapDelHead(t, base, name, pass)
	hist := append([]headSnap(nil), before.History...)
	if len(hist) < 3 {
		t.Fatalf("fixture: %d snapshots, want 3", len(hist))
	}
	if err := deleteSnapshotStore(base, name, pass, hist[1].Version, nil); err != nil {
		t.Fatalf("delete: %v", err)
	}
	after, _ := snapDelHead(t, base, name, pass)
	want := append([]headSnap{hist[0]}, hist[2:]...)
	if got := snapshotList(base, name, pass); !reflect.DeepEqual(got, want) {
		t.Errorf("history after the delete = %v, want %v (the others, in order, every field)", got, want)
	}
	if after.Version != before.Version || after.Manifest != before.Manifest || after.HeadKind != before.HeadKind || after.LastSeal != before.LastSeal {
		t.Errorf("the live head moved: version %d->%d manifest %s->%s -- a delete is not a new head version",
			before.Version, after.Version, short(before.Manifest), short(after.Manifest))
	}
	if !verifyVault(after, dk) {
		t.Error("the resealed vault does not verify")
	}
	if got := getRef(base, after.RecoveryRef); got != snapDelHeadBlob(base, name, pass) {
		t.Errorf("the recovery ref names %s, the head %s", short(got), short(snapDelHeadBlob(base, name, pass)))
	}
	for _, keep := range want {
		if _, err := rollbackHeadStore(base, name, pass, keep.Version, nil); err != nil {
			t.Errorf("rollback to the kept v%d after the delete: %v", keep.Version, err)
		}
	}
}

func TestDeleteSnapshotRefusesAnUnknownOrLiveVersion(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "snapdel-b", "nothing to delete here"
	snapDelSeals(t, base, name, pass, 3)
	v, dk := snapDelHead(t, base, name, pass)
	head := snapDelHeadBlob(base, name, pass)
	for what, ver := range map[string]uint64{"unknown": v.Version + 100, "live": v.Version} {
		if err := deleteSnapshotStore(base, name, pass, ver, nil); !errors.Is(err, errNoSnapshot) {
			t.Errorf("%s version %d: got %v, want errNoSnapshot", what, ver, err)
		}
		if got := snapDelHeadBlob(base, name, pass); got != head {
			t.Errorf("%s version: the head was republished (%s -> %s)", what, short(head), short(got))
		}
	}
	// A malformed head that lists its own version: the guard still refuses, and nothing is republished.
	v.History = append([]headSnap{{Version: v.Version, Manifest: v.Manifest}}, v.History...)
	signVault(v, dk)
	vh := postBlob(base, serializeVault(v))
	putHead(base, name, pass, vh)
	putRef(base, v.RecoveryRef, vh)
	if err := deleteSnapshotStore(base, name, pass, v.Version, nil); !errors.Is(err, errNoSnapshot) {
		t.Errorf("a head listing its own version: got %v, want errNoSnapshot", err)
	}
	if got := snapDelHeadBlob(base, name, pass); got != vh {
		t.Error("a head listing its own version was republished: the live version's entry was removed")
	}
}

func TestDeleteSnapshotSharingTheLiveManifestKeepsItLeased(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "snapdel-c", "shared with the live head"
	snapDelSeals(t, base, name, pass, 3)
	hist := snapshotList(base, name, pass)
	if _, err := rollbackHeadStore(base, name, pass, hist[len(hist)-1].Version, nil); err != nil {
		t.Fatalf("fixture rollback: %v", err)
	}
	live, _ := snapDelHead(t, base, name, pass)
	var shared *headSnap
	for i := range live.History {
		if live.History[i].Manifest == live.Manifest {
			shared = &live.History[i]
		}
	}
	if shared == nil {
		t.Fatal("fixture: no entry shares the live manifest after a rollback")
	}
	ver := shared.Version
	want := mustFootprint(t, base, name, pass, nil)
	if _, ok := want["blob/"+live.Manifest]; !ok || len(want) < 2 {
		t.Fatalf("fixture: the footprint holds %d blobs and not the live manifest", len(want))
	}
	oldHead := "blob/" + snapDelHeadBlob(base, name, pass) // the republish replaces the head blob itself
	if err := deleteSnapshotStore(base, name, pass, ver, nil); err != nil {
		t.Fatalf("delete: %v", err)
	}
	for _, s := range snapshotList(base, name, pass) {
		if s.Version == ver {
			t.Errorf("v%d is still listed", ver)
		}
	}
	after, _ := snapDelHead(t, base, name, pass)
	if after.Manifest != live.Manifest {
		t.Error("the live manifest changed")
	}
	refs := mustFootprint(t, base, name, pass, nil)
	for k := range want {
		if _, ok := refs[k]; !ok && k != oldHead {
			t.Errorf("the footprint lost %s after deleting the entry that shared the live manifest", short(k))
		}
	}
}

func TestDeleteSnapshotStopsLeasingItsOwnManifest(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "snapdel-d", "its own manifest goes"
	snapDelSeals(t, base, name, pass, 4)
	live, _ := snapDelHead(t, base, name, pass)
	target := live.History[1]
	for _, s := range live.History {
		if s.Version != target.Version && s.Manifest == target.Manifest || live.Manifest == target.Manifest {
			t.Fatal("fixture: the target's manifest is shared")
		}
	}
	key := "blob/" + target.Manifest
	if _, ok := mustFootprint(t, base, name, pass, nil)[key]; !ok {
		t.Fatalf("fixture: the footprint does not lease the snapshot's manifest %s", short(key))
	}
	if err := deleteSnapshotStore(base, name, pass, target.Version, nil); err != nil {
		t.Fatalf("delete: %v", err)
	}
	refs := mustFootprint(t, base, name, pass, nil)
	if _, ok := refs[key]; ok {
		t.Errorf("the footprint still leases the deleted snapshot's manifest %s", short(key))
	}
	if _, ok := refs["blob/"+live.Manifest]; !ok {
		t.Error("the footprint lost the live manifest")
	}
}

func TestDeleteSnapshotOnAHardenedVaultNeedsItsSecret(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "snapdel-e", "a hardened one"
	snapDelSeals(t, base, name, pass, 3)
	se := []byte("this-handsets-strongbox-secret")
	if err := enrollSE(base, name, pass, se); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}
	ver := snapshotList(base, name, pass)[0].Version
	err := deleteSnapshotStore(base, name, pass, ver, nil)
	if err == nil || errors.Is(err, errNoSnapshot) {
		t.Fatalf("without the secret: got %v, want a plain error", err)
	}
	if strings.Contains(strings.ToLower(err.Error()), "passphrase") {
		t.Errorf("a hardened vault without its secret accuses the passphrase: %v", err)
	}
	if err := deleteSnapshotStore(base, name, pass, ver, se); err != nil {
		t.Fatalf("with the secret: %v", err)
	}
	for _, s := range snapshotList(base, name, pass) {
		if s.Version == ver {
			t.Errorf("v%d is still listed", ver)
		}
	}
}

// snapDelFixture is a live roam session with deleteSnapshot stubbed.
type snapDelFixture struct {
	dest   string
	called int
	gotVer uint64
	gotNm  string
	gotPw  string
	ret    func() error
}

func snapDelSetup(t *testing.T) *snapDelFixture {
	t.Helper()
	f := &snapDelFixture{dest: t.TempDir(), ret: func() error { return nil }}
	t.Setenv("NOWHERE_STATE", f.dest)
	if err := markRoamSession(f.dest, "snapdel-h", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	ropReapReset(t)
	reset := func() {
		pendingReapMu.Lock()
		sealInFlight, sealRunKind = false, ""
		pendingReapMu.Unlock()
	}
	reset()
	old := deleteSnapshot
	deleteSnapshot = func(base, name, pass string, version uint64, se []byte) error {
		f.called++
		f.gotNm, f.gotPw, f.gotVer = name, pass, version
		return f.ret()
	}
	t.Cleanup(func() { deleteSnapshot = old; reset() })
	return f
}

// run drives the handler in the test goroutine, so a panic it fails to answer is a test failure, not a dead binary.
func (f *snapDelFixture) run(t *testing.T, ver string) string {
	t.Helper()
	a, b := net.Pipe()
	done := make(chan string)
	go func() {
		raw, _ := io.ReadAll(b)
		done <- strings.TrimSpace(string(raw))
	}()
	func() {
		defer func() {
			if r := recover(); r != nil {
				t.Errorf("handleDeleteSnapshot panicked: %v -- the chooser gets no reply", r)
			}
		}()
		handleDeleteSnapshot(a, f.dest, ver)
	}()
	a.Close()
	return <-done
}

func TestDeleteSnapshotHandlerReplies(t *testing.T) {
	want := func(t *testing.T, f *snapDelFixture, ver, reply string, calls int) {
		t.Helper()
		if got := f.run(t, ver); got != reply {
			t.Errorf("version %q: got %q, want %q", ver, got, reply)
		}
		if f.called != calls {
			t.Errorf("version %q: the store function ran %d times, want %d", ver, f.called, calls)
		}
		if strings.Contains(strings.ToLower(reply), "pass") {
			t.Errorf("reply %q is credential-shaped", reply)
		}
	}
	t.Run("no session", func(t *testing.T) {
		f := snapDelSetup(t)
		os.Remove(filepath.Join(f.dest, ".roamsession"))
		want(t, f, "3", "NONE", 0)
	})
	t.Run("local session", func(t *testing.T) {
		f := snapDelSetup(t)
		markLocalSession(f.dest)
		want(t, f, "3", "LOCAL", 0)
	})
	t.Run("bad version", func(t *testing.T) {
		f := snapDelSetup(t)
		for _, v := range []string{"", "0", "x", "-1"} {
			want(t, f, v, "ERR-ARG", 0)
		}
	})
	t.Run("a seal is announced", func(t *testing.T) {
		for name, set := range map[string]func(){
			"sealInFlight": func() { sealInFlight = true },
			"periodic run": func() { sealRunKind = "periodic" },
		} {
			f := snapDelSetup(t)
			pendingReapMu.Lock()
			set()
			pendingReapMu.Unlock()
			if got := f.run(t, "3"); got != "BUSY" || f.called != 0 {
				t.Errorf("%s: got %q (store function ran %d times), want BUSY and no call", name, got, f.called)
			}
			if n, _, _ := readRoamSession(f.dest); n != "snapdel-h" {
				t.Errorf("%s: BUSY dropped .roamsession", name)
			}
		}
	})
	t.Run("a teardown is queued", func(t *testing.T) {
		f := snapDelSetup(t)
		pendingReapMu.Lock()
		pendingReapUID = "10"
		pendingReapMu.Unlock()
		want(t, f, "3", "BUSY", 0)
	})
	t.Run("stale list", func(t *testing.T) {
		f := snapDelSetup(t)
		f.ret = func() error { return errNoSnapshot }
		want(t, f, "3", "NOSNAP", 1)
		f.ret = func() error { return fmt.Errorf("x: %w", errNoSnapshot) }
		want(t, f, "3", "NOSNAP", 2)
	})
	t.Run("store fault", func(t *testing.T) {
		f := snapDelSetup(t)
		f.ret = func() error { return errors.New("snapshot delete refused at publish") }
		want(t, f, "3", "ERR", 1)
	})
	t.Run("panicking store read", func(t *testing.T) {
		f := snapDelSetup(t)
		f.ret = func() error { panic(storeReadErr{errors.New("dial tcp: no route")}) }
		want(t, f, "3", "ERR", 1)
	})
	t.Run("success", func(t *testing.T) {
		f := snapDelSetup(t)
		want(t, f, "3", "OK", 1)
		if f.gotVer != 3 || f.gotNm != "snapdel-h" || f.gotPw != "pw" {
			t.Errorf("the store function got (%q, %q, v%d), want the session's name and passphrase and v3", f.gotNm, f.gotPw, f.gotVer)
		}
		if n, _, _ := readRoamSession(f.dest); n != "snapdel-h" {
			t.Error("a delete dropped .roamsession: the session must carry on")
		}
		pendingReapMu.Lock()
		sw, rp := pendingSwitchUID, pendingReapUID
		pendingReapMu.Unlock()
		if sw != "" || rp != "" {
			t.Errorf("a delete queued a teardown (%q, %q)", sw, rp)
		}
	})
}

func TestDeleteSnapshotIsDispatchedAfterRollback(t *testing.T) {
	raw, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(raw)
	rb := strings.Index(src, `if name == "ROLLBACK" {`)
	arm := strings.Index(src, `if name == "DELETE-SNAPSHOT" {`)
	gate := strings.Index(src, `if name == "ROLLBACK-GATE" {`)
	if rb < 0 || arm < 0 || gate < 0 || !(rb < arm && arm < gate) {
		t.Fatalf("dispatch order: ROLLBACK at %d, DELETE-SNAPSHOT at %d, ROLLBACK-GATE at %d; want the arm directly after ROLLBACK", rb, arm, gate)
	}
	body := strings.Join(stripComments(strings.Split(src[arm:gate], "\n")), "\n")
	for _, need := range []string{`r.ReadString('\n')`, `120 * time.Second`, `handleDeleteSnapshot(conn, dest,`} {
		if !strings.Contains(body, need) {
			t.Errorf("the DELETE-SNAPSHOT arm lacks %s", need)
		}
	}
	if !rekeyHoldingVerb("DELETE-SNAPSHOT") || concurrentSafeCmd("DELETE-SNAPSHOT") {
		t.Errorf("DELETE-SNAPSHOT holds the re-key off %v, waits for sessionMu %v -- it must do both",
			rekeyHoldingVerb("DELETE-SNAPSHOT"), !concurrentSafeCmd("DELETE-SNAPSHOT"))
	}
}

// A delete that arrives while a re-key batch holds the lock edits THAT batch's head: the entry is found again
// inside the bracket, because the batch prepended one and the index read before is no longer the entry's.
func TestDeleteSnapshotBehindAReKeyBatchEditsItsHead(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	t.Setenv("NOWHERE_SNAP_AUTO_RECENT", "8") // the batch's new entry must not prune the target
	t.Setenv("NOWHERE_SNAP_AUTO", "8")
	const name, pass = "snapdel-lock", "a delete over a moved head"
	_, dk := sessionVaultForTest(t, name, pass)
	withSnapshot(t, name, pass, dk)
	v, err := readSessionVault("s3", name, pass)
	if err != nil {
		t.Fatal(err)
	}
	pushSnapshot(v, strings.Repeat("ef", 32), v.HeadKind)
	v.Manifest = strings.Repeat("ef", 32)
	if err := publishSessionVault("s3", name, pass, v, dk); err != nil {
		t.Fatal(err)
	}
	pre, _ := readSessionVault("s3", name, pass)
	if len(pre.History) != 2 {
		t.Fatalf("fixture: %d snapshots, want 2", len(pre.History))
	}
	target := pre.History[1].Version // the oldest
	batch := func(v *vault) {
		pushSnapshot(v, strings.Repeat("12", 32), v.HeadKind)
		v.Manifest = strings.Repeat("12", 32)
		v.TelPub = otherBracketMark
		publishSessionVaultIn("s3", name, pass, v, dk)
	}
	var derr error
	rv := publishBehindWith(t, name, pass, dk, batch, func() { derr = deleteSnapshotStore("s3", name, pass, target, nil) })
	if derr != nil {
		t.Fatalf("the delete, arriving while another bracket held the lock: %v", derr)
	}
	got, head, rec := headAndRecovery(t, name, pass)
	if got.Version != rv || got.TelPub != otherBracketMark {
		t.Errorf("the head reads version %d (marked: %v); want %d with the batch's mark -- the delete put the vault it read before waiting over the batch's",
			got.Version, got.TelPub == otherBracketMark, rv)
	}
	if rec != head {
		t.Errorf("the recovery ref names %s while the head names %s", short(rec), short(head))
	}
	have := map[uint64]bool{}
	for _, s := range got.History {
		have[s.Version] = true
	}
	if have[target] {
		t.Errorf("v%d is still listed", target)
	}
	if len(got.History) != 2 || !have[pre.History[0].Version] {
		t.Errorf("history after = %v; want the two kept versions (the batch's new one and v%d)", snapDelVersions(got.History), pre.History[0].Version)
	}
}

// A refusal at the flush is an error, never an OK.
func TestDeleteSnapshotReportsARefusalAtTheFlush(t *testing.T) {
	objs, mu := capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "snapdel-flush", "a head moved at the flush"
	_, dk := sessionVaultForTest(t, name, pass)
	withSnapshot(t, name, pass, dk)
	v, _ := readSessionVault("s3", name, pass)
	moveHeadAtFlush(objs, mu, name, pass)
	t.Cleanup(func() { capStorePutHook = nil })
	err := deleteSnapshotStore("s3", name, pass, v.History[0].Version, nil)
	if err == nil || errors.Is(err, errNoSnapshot) {
		t.Errorf("a delete over a head the store refused at the flush answered %v, want a refusal error", err)
	}
}

// ---- NWP-20261029-10: the release of a deleted snapshot's unshared blobs ----

// snapRel is a cap-mode profile with several snapshots, a gateway that grants every lease, and a /release
// route that records each body it is sent.
type snapRel struct {
	base, name, pass string
	dk               []byte
	objs             map[string][]byte
	mu               *sync.Mutex
	cache            string // the blob cache file the workers (and so the eviction) use
	reqs             [][]byte
	status           int // what /release answers (200 unless a test changes it)
	atRequest        func([]byte)
}

func snapRelSetup(t *testing.T, name, pass string, seals int) *snapRel {
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
	blobCache = nil
	t.Cleanup(func() { blobCache = nil })
	capStoreLeaseStatus = func(leaseReq) (int, string) { return 200, "" }
	r := &snapRel{objs: objs, mu: mu, base: "s3", name: name, pass: pass, status: 200, cache: blobCachePath()}
	capStoreRelease = func(b []byte) (int, string) {
		r.reqs = append(r.reqs, b)
		if r.atRequest != nil {
			r.atRequest(b)
		}
		return r.status, `{"released":[]}`
	}
	snapDelSeals(t, r.base, name, pass, seals)
	v, dk := snapDelHead(t, r.base, name, pass)
	r.dk = dk
	// The oldest entry is the vault's creation state, a whole-tar blob, not a CDC manifest, that names only itself
	// (NWP-20261113-14): take it out first, with the release stubbed, so the tests below see CDC versions only (three
	// or more).
	old := releaseDeletedSnapshotFn
	releaseDeletedSnapshotFn = func(string, string, string, []byte, headSnap, *vault, string) {}
	err := deleteSnapshotStore(r.base, name, pass, v.History[len(v.History)-1].Version, nil)
	releaseDeletedSnapshotFn = old
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	return r
}

// stderr runs fn and returns what it wrote to os.Stderr.
func snapRelStderr(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stderr
	rd, wr, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stderr = wr
	done := make(chan string)
	go func() { b, _ := io.ReadAll(rd); done <- string(b) }()
	func() {
		defer func() { os.Stderr = old; wr.Close() }()
		fn()
	}()
	return <-done
}

// want is the set the delete of entry e must release, computed from the head as it is before the delete.
func (r *snapRel) want(t *testing.T, e headSnap) map[string]bool {
	t.Helper()
	v, _ := snapDelHead(t, r.base, r.name, r.pass)
	kept := *v
	kept.History = nil
	for _, h := range v.History {
		if h.Version != e.Version {
			kept.History = append(kept.History, h)
		}
	}
	set, err := snapshotReleaseSet(r.base, r.dk, e, &kept)
	if err != nil || len(set) == 0 {
		t.Fatalf("fixture: release set %d, err %v", len(set), err)
	}
	if !set["blob/"+e.Manifest] {
		t.Fatalf("fixture: the set lacks the entry's manifest")
	}
	return set
}

// sent decodes every /release body into key -> preimage hex.
func (r *snapRel) sent(t *testing.T) map[string]string {
	t.Helper()
	out := map[string]string{}
	for _, b := range r.reqs {
		var body struct {
			Release map[string]string `json:"release"`
		}
		if err := json.Unmarshal(b, &body); err != nil {
			t.Fatalf("a /release body does not decode: %v", err)
		}
		for k, v := range body.Release {
			out[k] = v
		}
	}
	return out
}

// publishWithout publishes the head as a landed delete of e leaves it (the generation bumped, no release made) and
// returns that vault and the head value, so a test can call releaseDeletedSnapshot on its own.
func (r *snapRel) publishWithout(t *testing.T, e headSnap) (*vault, string) {
	t.Helper()
	cur, _ := snapDelHead(t, r.base, r.name, r.pass)
	kept := *cur
	kept.History = nil
	for _, h := range cur.History {
		if h.Version != e.Version {
			kept.History = append(kept.History, h)
		}
	}
	kept.ReleaseGen++
	signVault(&kept, r.dk)
	return &kept, r.put(&kept)
}

func (r *snapRel) put(v *vault) string {
	var h string
	capWrite(r.name, r.pass, r.dk, func() {
		h = postBlob(r.base, serializeVault(v))
		putHead(r.base, r.name, r.pass, h)
	})
	return h
}

func TestSnapshotDeleteReleasesTheMiddleVersionsUnsharedBlobs(t *testing.T) {
	r := snapRelSetup(t, "snaprel-a", "release the middle", 5)
	before, _ := snapDelHead(t, r.base, r.name, r.pass)
	mid := before.History[1]
	want := r.want(t, mid)
	if err := deleteSnapshotStore(r.base, r.name, r.pass, mid.Version, nil); err != nil {
		t.Fatalf("delete: %v", err)
	}
	got := r.sent(t)
	if len(got) != len(want) {
		t.Errorf("released %d keys, want %d", len(got), len(want))
	}
	for k := range want {
		if p, ok := got[k]; !ok {
			t.Errorf("%s was not released", short(k))
		} else if p != hex.EncodeToString(blobReleaseProof(r.dk, k)) {
			t.Errorf("%s: the preimage is not blobReleaseProof(dk, key)", short(k))
		}
	}
	after, _ := snapDelHead(t, r.base, r.name, r.pass)
	if after.ReleaseGen != before.ReleaseGen+1 || after.Version != before.Version {
		t.Errorf("head generation %d->%d, version %d->%d; want generation+1 and the same version",
			before.ReleaseGen, after.ReleaseGen, before.Version, after.Version)
	}
	// The reply of the handler is unchanged by a release: the verb returns nil above, and a release that fails
	// does not change it either (cases below).
}

func TestSnapshotDeleteReleasesNothingWhenThePublishWasRefused(t *testing.T) {
	r := snapRelSetup(t, "snaprel-b", "refused at the flush", 5)
	t.Cleanup(clearStaleHit)
	v, _ := readSessionVault("s3", r.name, r.pass)
	moveHeadAtFlush(r.objs, r.mu, r.name, r.pass)
	t.Cleanup(func() { capStorePutHook = nil })
	calls := 0
	old := releaseDeletedSnapshotFn
	releaseDeletedSnapshotFn = func(string, string, string, []byte, headSnap, *vault, string) { calls++ }
	t.Cleanup(func() { releaseDeletedSnapshotFn = old })
	err := deleteSnapshotStore("s3", r.name, r.pass, v.History[0].Version, nil)
	if err == nil {
		t.Fatal("fixture: the publish was not refused")
	}
	if calls != 0 {
		t.Errorf("the release was called %d time(s) after a refused publish", calls)
	}
	if len(r.reqs) != 0 {
		t.Errorf("a refused publish was followed by %d /release request(s)", len(r.reqs))
	}
}

func TestSnapshotDeleteReleasesNothingWhenAKeptManifestIsUnreadable(t *testing.T) {
	r := snapRelSetup(t, "snaprel-c", "a kept one is gone", 5)
	before, _ := snapDelHead(t, r.base, r.name, r.pass)
	kept := before.History[0]
	r.mu.Lock()
	delete(r.objs, "blob/"+kept.Manifest)
	r.mu.Unlock()
	logs := snapRelStderr(t, func() {
		if err := deleteSnapshotStore(r.base, r.name, r.pass, before.History[1].Version, nil); err != nil {
			t.Errorf("delete: %v -- an unreadable kept version must not change the verb's result", err)
		}
	})
	if len(r.reqs) != 0 {
		t.Errorf("%d /release request(s) with a kept manifest unreadable", len(r.reqs))
	}
	if !strings.Contains(logs, "a kept version could not be read") {
		t.Errorf("the log does not say why nothing was released: %q", logs)
	}
}

func TestSnapshotDeleteOfAnEntrySharingTheLiveManifestReleasesNothing(t *testing.T) {
	r := snapRelSetup(t, "snaprel-d", "shared with the live head", 5)
	hist := snapshotList(r.base, r.name, r.pass)
	if _, err := rollbackHeadStore(r.base, r.name, r.pass, hist[len(hist)-1].Version, nil); err != nil {
		t.Fatalf("fixture rollback: %v", err)
	}
	live, _ := snapDelHead(t, r.base, r.name, r.pass)
	ver := uint64(0)
	for _, h := range live.History {
		if h.Manifest == live.Manifest {
			ver = h.Version
		}
	}
	if ver == 0 {
		t.Fatal("fixture: no entry shares the live manifest")
	}
	if err := deleteSnapshotStore(r.base, r.name, r.pass, ver, nil); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if len(r.reqs) != 0 {
		t.Errorf("%d /release request(s) for an entry the live head also names", len(r.reqs))
	}
}

func TestSnapshotDeleteEvictsTheCacheBeforeTheRequest(t *testing.T) {
	r := snapRelSetup(t, "snaprel-e", "evict first", 5)
	before, _ := snapDelHead(t, r.base, r.name, r.pass)
	mid := before.History[1]
	want := r.want(t, mid)
	b, err := os.ReadFile(r.cache)
	if err != nil {
		t.Fatalf("fixture: no blob cache file: %v", err)
	}
	for k := range want {
		if !strings.Contains(string(b), strings.TrimPrefix(k, "blob/")) {
			t.Fatalf("fixture: the cache does not hold %s before the delete", short(k))
		}
	}
	var atReq string
	r.atRequest = func([]byte) {
		c, _ := os.ReadFile(r.cache)
		atReq = string(c)
	}
	logs := snapRelStderr(t, func() {
		if err := deleteSnapshotStore(r.base, r.name, r.pass, mid.Version, nil); err != nil {
			t.Fatalf("delete: %v", err)
		}
	})
	if len(r.reqs) == 0 {
		t.Fatal("no /release request")
	}
	for k := range want {
		if strings.Contains(atReq, strings.TrimPrefix(k, "blob/")) {
			t.Errorf("%s was still in the cache file when the request went out", short(k))
		}
	}
	if g, ok := relGenSeen(r.cache, relGenHeadKey(r.base, r.name, r.pass)); !ok || g != before.ReleaseGen+1 {
		t.Errorf("recorded generation %d (%v), want %d", g, ok, before.ReleaseGen+1)
	}
	if !strings.Contains(logs, "unshared object(s) released for the next collection") {
		t.Errorf("no summary line: %q", logs)
	}
	if strings.Contains(logs, "blob/") || strings.Contains(logs, hex.EncodeToString(blobReleaseProof(r.dk, "blob/"+mid.Manifest))) {
		t.Error("the log holds a key or a proof")
	}
}

func TestSnapshotDeleteRecordsNoGenerationWhenTheEvictionFails(t *testing.T) {
	r := snapRelSetup(t, "snaprel-f", "evict fails", 5)
	before, _ := snapDelHead(t, r.base, r.name, r.pass)
	// A cache file that cannot be read: the eviction fails, while the generation file beside it stays writable.
	if err := os.Chmod(r.cache, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(r.cache, 0o600) })
	if f, err := os.Open(r.cache); err == nil {
		f.Close()
		t.Skip("the cache file stays readable (running as root)")
	}
	if err := deleteSnapshotStore(r.base, r.name, r.pass, before.History[1].Version, nil); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if g, ok := relGenSeen(r.cache, relGenHeadKey(r.base, r.name, r.pass)); ok && g == before.ReleaseGen+1 {
		t.Error("the new generation was recorded although the eviction failed")
	}
	if len(r.reqs) == 0 {
		t.Error("a failed eviction stopped the request")
	}
}

func TestSnapshotDeleteAnOlderGatewayLeavesTheLeaseSchedule(t *testing.T) {
	r := snapRelSetup(t, "snaprel-g", "no release route", 5)
	capStoreRelease = nil
	before, _ := snapDelHead(t, r.base, r.name, r.pass)
	logs := snapRelStderr(t, func() {
		if err := deleteSnapshotStore(r.base, r.name, r.pass, before.History[1].Version, nil); err != nil {
			t.Errorf("delete: %v -- a 404 must not change the verb's result", err)
		}
	})
	if !strings.Contains(logs, "the gateway does not release early") {
		t.Errorf("the log does not say the gateway does not release early: %q", logs)
	}
	for _, s := range snapshotList(r.base, r.name, r.pass) {
		if s.Version == before.History[1].Version {
			t.Error("the version is still listed")
		}
	}
}

func TestSnapshotDeleteReleasesNothingWithoutAGatewayOrUnderPerUnitHeads(t *testing.T) {
	t.Run("direct store", func(t *testing.T) {
		r := snapRelSetup(t, "snaprel-h", "direct", 5)
		before, _ := snapDelHead(t, r.base, r.name, r.pass)
		t.Setenv("S3_ACCESS_KEY", "direct-mode")
		if capMode() {
			t.Fatal("fixture: still cap mode")
		}
		// The verb itself would write through the direct store; the release step is what is under test.
		pub := *before
		pub.History = append([]headSnap{before.History[0]}, before.History[2:]...)
		logs := snapRelStderr(t, func() {
			releaseDeletedSnapshot(r.base, r.name, r.pass, r.dk, before.History[1], &pub, "x")
		})
		if len(r.reqs) != 0 || !strings.Contains(logs, "this store has no gateway") {
			t.Errorf("direct store: %d request(s), log %q", len(r.reqs), logs)
		}
	})
	t.Run("per-unit heads", func(t *testing.T) {
		r := snapRelSetup(t, "snaprel-i", "per unit", 5)
		before, _ := snapDelHead(t, r.base, r.name, r.pass)
		kept, vh := r.publishWithout(t, before.History[1]) // the head as a landed delete leaves it
		t.Setenv("NOWHERE_MULTIDEVICE", "1")
		if !multiDeviceEnabled() {
			t.Fatal("fixture: per-unit heads are not on")
		}
		logs := snapRelStderr(t, func() {
			releaseDeletedSnapshot(r.base, r.name, r.pass, r.dk, before.History[1], kept, vh)
		})
		if len(r.reqs) != 0 || !strings.Contains(logs, "per-unit heads of other devices are not read") {
			t.Errorf("per-unit heads: %d request(s), log %q", len(r.reqs), logs)
		}
	})
}

func TestSnapshotDeleteReadsTheHeadBackBeforeReleasing(t *testing.T) {
	r := snapRelSetup(t, "snaprel-j", "read back", 5)
	before, _ := snapDelHead(t, r.base, r.name, r.pass)
	mid := before.History[1]
	kept, vh := r.publishWithout(t, mid)

	// Another handset's seal overwrites the head with a vault that still lists the deleted version.
	other := *before
	other.Version++
	signVault(&other, r.dk)
	r.put(&other)
	logs := snapRelStderr(t, func() { releaseDeletedSnapshot(r.base, r.name, r.pass, r.dk, mid, kept, vh) })
	if len(r.reqs) != 0 || !strings.Contains(logs, "the head changed after the delete landed") {
		t.Errorf("an overwritten head: %d request(s), log %q", len(r.reqs), logs)
	}

	r.put(kept) // the head as the delete published it
	releaseDeletedSnapshot(r.base, r.name, r.pass, r.dk, mid, kept, vh)
	if len(r.reqs) == 0 {
		t.Error("the head unchanged: no /release request")
	}
}

// NWP-20261116-21: a gateway that does not answer POST /release holds the verb (and sessionMu) at most
// snapshotReleaseWait; everything before the request still happened.
func TestSnapshotDeleteReleaseWaitIsBounded(t *testing.T) {
	r := snapRelSetup(t, "snaprel-k", "release wait bounded", 5)
	unblock := make(chan struct{})
	arrived := make(chan struct{}, 1)
	var handlerDone atomic.Bool
	r.atRequest = func([]byte) {
		select {
		case arrived <- struct{}{}:
		default:
		}
		<-unblock
		handlerDone.Store(true)
	}
	// Registered after snapRelSetup's server cleanup, so it runs first and the server's Close does not wait on a
	// handler that is still blocked.
	t.Cleanup(func() { close(unblock) })
	saved := snapshotReleaseWait
	snapshotReleaseWait = 200 * time.Millisecond
	t.Cleanup(func() { snapshotReleaseWait = saved })

	before, _ := snapDelHead(t, r.base, r.name, r.pass)
	mid := before.History[1]
	want := r.want(t, mid)
	kept, vh := r.publishWithout(t, mid) // a head the delete really published, so the read-back passes
	if b, err := os.ReadFile(r.cache); err != nil {
		t.Fatalf("fixture: no blob cache file: %v", err)
	} else {
		for k := range want {
			if !strings.Contains(string(b), strings.TrimPrefix(k, "blob/")) {
				t.Fatalf("fixture: the cache does not hold %s before the release", short(k))
			}
		}
	}

	ret := make(chan string, 1)
	go func() {
		ret <- snapRelStderr(t, func() { releaseDeletedSnapshot(r.base, r.name, r.pass, r.dk, mid, kept, vh) })
	}()
	// Both 20 s waits are hang guards, never a bound on how fast the code must be. They stay below the inline
	// client's own ~30 s budget, so on code that waits inline the guard, not the client, ends the wait.
	select {
	case <-arrived:
	case <-time.After(20 * time.Second):
		t.Fatal("the release never reached the gateway")
	}
	var logs string
	select {
	case logs = <-ret:
	case <-time.After(20 * time.Second):
		t.Fatal("releaseDeletedSnapshot is still waiting on a gateway that does not answer")
	}
	if handlerDone.Load() {
		t.Fatal("fixture: the /release handler returned before the cleanup unblocked it")
	}
	if n := strings.Count(logs, "the gateway is still taking the release -- not waiting"); n != 1 {
		t.Errorf("%d not-waiting line(s), want 1: %q", n, logs)
	}
	if strings.Contains(logs, "released for the next collection") {
		t.Errorf("a summary line for a release that never answered: %q", logs)
	}
	if strings.Contains(logs, "blob/") || strings.Contains(logs, hex.EncodeToString(blobReleaseProof(r.dk, "blob/"+mid.Manifest))) {
		t.Error("the log holds a key or a proof")
	}
	c, err := os.ReadFile(r.cache)
	if err != nil {
		t.Fatalf("no blob cache file: %v", err)
	}
	for k := range want {
		if strings.Contains(string(c), strings.TrimPrefix(k, "blob/")) {
			t.Errorf("%s is still in the cache file", short(k))
		}
	}
	if g, ok := relGenSeen(r.cache, relGenHeadKey(r.base, r.name, r.pass)); !ok || g != kept.ReleaseGen {
		t.Errorf("recorded generation %d (%v), want %d", g, ok, kept.ReleaseGen)
	}
}
