package main

// NWP-20261123-04: a #media push whose walk finds what the last landed #media seal found, over the same head, ends
// after the walk (media_nochange.go). These tests drive pushProfile through the two-writer harness against a
// counting store; every test has its own profile name, state dir and blob-cache dir.

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
	"sync/atomic"
	"testing"
	"time"
)

// ncNoChangeMark is the fixed part of the no-change line.
const ncNoChangeMark = "(#media) no change since gen "

// ncStore counts what a push writes. The cap-mode store (mockCapStore, the device's managed mode) is the default:
// only there does a landed chunk enter the blob cache, so an unchanged file is not read again. newNCHTTPStore is the
// direct store, where putHead itself is the head PUT.
type ncStore struct {
	base       string
	refPuts    atomic.Int64 // pointer writes the store saw
	blobPuts   atomic.Int64 // blob writes the store saw
	leases     atomic.Int64 // cap mode: /lease calls
	failRefPut atomic.Bool  // every pointer write fails
}

func newNCStore(t *testing.T) *ncStore {
	t.Helper()
	capFixture(t)
	s := &ncStore{base: "s3"}
	capStorePutSeen = func(k string, _ http.Header) {
		switch {
		case strings.HasPrefix(k, "ref/"):
			s.refPuts.Add(1)
		case strings.HasPrefix(k, "blob/"):
			s.blobPuts.Add(1)
		}
	}
	capStorePutStatus = func(k string, _ http.Header) (int, string) {
		if strings.HasPrefix(k, "ref/") && s.failRefPut.Load() {
			return http.StatusInternalServerError, "ref writes fail in this test"
		}
		return 0, ""
	}
	capStoreLeaseSeen = func(leaseReq) { s.leases.Add(1) }
	return s
}

func newNCHTTPStore(t *testing.T) *ncStore {
	t.Helper()
	s := &ncStore{}
	var mu sync.Mutex
	blobs := map[string][]byte{}
	refs := map[string]string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/ref/") && s.failRefPut.Load() {
			// The connection drops: the agent's PUT returns an error and fail() panics, as a lost link does.
			if hj, ok := w.(http.Hijacker); ok {
				if c, _, err := hj.Hijack(); err == nil {
					c.Close()
					return
				}
			}
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		switch {
		case r.Method == "POST" && r.URL.Path == "/blob":
			s.blobPuts.Add(1)
			body, _ := io.ReadAll(r.Body)
			h := sha256.Sum256(body)
			key := hex.EncodeToString(h[:])
			blobs[key] = body
			io.WriteString(w, key)
		case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/blob/"):
			if b, ok := blobs[strings.TrimPrefix(r.URL.Path, "/blob/")]; ok {
				w.Write(b)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/ref/"):
			s.refPuts.Add(1)
			body, _ := io.ReadAll(r.Body)
			refs[strings.TrimPrefix(r.URL.Path, "/ref/")] = string(body)
		case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/ref/"):
			if v, ok := refs[strings.TrimPrefix(r.URL.Path, "/ref/")]; ok {
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

// ncDevice is one handset with its own blob-cache dir (the state tmpfs the record lives in).
type ncDevice struct {
	*handset
	bc string
}

// ncEnv arms receipts and the media carry, and turns off the periodic full re-hash.
func ncEnv(t *testing.T) {
	t.Helper()
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_BLOBCACHE", t.TempDir())
	t.Setenv("NOWHERE_SEAL_FULL_EVERY", "0")
	t.Setenv("NOWHERE_SEAL_FORCE", "")
	t.Setenv("NOWHERE_MEDIA_SYNC_OUT", "")
}

func ncNewDevice(t *testing.T, s *ncStore, name, pass string) *ncDevice {
	t.Helper()
	return &ncDevice{handset: newHandset(t, s.base, name, pass), bc: t.TempDir()}
}

// push seals this device's #media tree with its own blob-cache dir and returns stdout and the refusal ("" = landed).
func (d *ncDevice) push(t *testing.T) (out, refused string) {
	t.Helper()
	prev := os.Getenv("NOWHERE_BLOBCACHE")
	os.Setenv("NOWHERE_BLOBCACHE", d.bc)
	defer os.Setenv("NOWHERE_BLOBCACHE", prev)
	out = captureStdout(t, func() { refused = d.seal("#media") })
	return out, refused
}

// login writes the receipt and roster a sign-in at head writes.
func (d *ncDevice) login(head string) {
	ref := profileRefV2(d.name+"#media", d.pass)
	d.as(func() { loginArrived(ref, head) })
}

// receipt is this device's session receipt head.
func (d *ncDevice) receipt() (h string) {
	ref := profileRefV2(d.name+"#media", d.pass)
	d.as(func() { h = restoreReceiptHead(ref) })
	return h
}

// recordPath is this device's no-change record for the profile.
func (d *ncDevice) recordPath() string {
	return filepath.Join(d.bc, "mnochange."+contentCacheTagFor(deriveKey(d.name+"#media", d.pass)))
}

var ncMtime = time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)

// fixture writes a #media tree: small documents in a few dirs, and two photos of 1 MiB and more.
func (d *ncDevice) fixture(t *testing.T) {
	t.Helper()
	for dir := 0; dir < 4; dir++ {
		for f := 0; f < 40; f++ {
			d.putAt(fmt.Sprintf("Documents/d%d/n%03d.txt", dir, f), strings.Repeat(fmt.Sprintf("dir %d note %d. ", dir, f), 20+f%9), ncMtime.Add(time.Duration(dir*100+f)*time.Second))
		}
	}
	for i := 0; i < 2; i++ {
		big := strings.Repeat(fmt.Sprintf("photo %d bytes ", i), (1<<20)/14+64)
		d.putAt(fmt.Sprintf("DCIM/Camera/IMG_%04d.jpg", i), big, ncMtime.Add(time.Duration(i)*time.Hour))
	}
}

// ncSetup builds one cap-mode store, one vault and one device that has sealed its fixture once and signed in at
// that head.
func ncSetup(t *testing.T, name string) (*ncStore, *ncDevice, string) {
	t.Helper()
	ncEnv(t)
	return ncSetupOn(t, newNCStore(t), name)
}

func ncSetupOn(t *testing.T, s *ncStore, name string) (*ncStore, *ncDevice, string) {
	t.Helper()
	pass := "nochange pass " + name
	createVault(s.base, name, pass)
	a := ncNewDevice(t, s, name, pass)
	a.fixture(t)
	if _, msg := a.push(t); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	h1 := a.head("#media")
	if h1 == "" {
		t.Fatal("setup seal published no head")
	}
	a.login(h1)
	return s, a, h1
}

// N1: an unchanged tree. The second push prints the no-change line and writes nothing: no ref PUT, no blob, the
// same stored head and the same receipt.
func TestMediaNoChange_UnchangedTreeEndsAfterTheWalk(t *testing.T) {
	s, a, h1 := ncSetup(t, "mncN1")
	refs0, blobs0, leases0 := s.refPuts.Load(), s.blobPuts.Load(), s.leases.Load()
	rc0 := a.receipt()
	out, msg := a.push(t)
	if msg != "" {
		t.Fatalf("second push: %s\n%s", msg, out)
	}
	if !strings.Contains(out, ncNoChangeMark) {
		t.Fatalf("an unchanged #media tree took the full path: no no-change line.\n%s", out)
	}
	if want := fmt.Sprintf("(#media) no change since gen %s -- walk ", short(h1)); !strings.Contains(out, want) {
		t.Errorf("the no-change line does not name the kept head %s:\n%s", short(h1), out)
	}
	if strings.Contains(out, "-> ") && strings.Contains(out, " chunks (") {
		t.Errorf("a no-change push also printed a seal summary:\n%s", out)
	}
	if n := s.refPuts.Load() - refs0; n != 0 {
		t.Errorf("a no-change push wrote %d ref(s)", n)
	}
	if n := s.blobPuts.Load() - blobs0; n != 0 {
		t.Errorf("a no-change push uploaded %d blob(s)", n)
	}
	if n := s.leases.Load() - leases0; n != 0 {
		t.Errorf("a no-change push took %d lease(s)", n)
	}
	if got := a.head("#media"); got != h1 {
		t.Errorf("the stored head moved: %s -> %s", short(h1), short(got))
	}
	if got := a.receipt(); got != rc0 {
		t.Errorf("the receipt changed: %q -> %q", rc0, got)
	}
	if _, err := os.Stat(a.recordPath()); err != nil {
		t.Errorf("the record is gone after a no-change push: %v", err)
	}
}

// N2: one file's mtime moves and nothing else. The walk digest differs, so the push takes the full path; the push
// after it, over the tree that full path recorded, ends after the walk again. The move is sub-second: the tar header
// holds whole seconds, so the bytes and chunks stay the same and only the digest can see it.
func TestMediaNoChange_MtimeOnlyTakesTheFullPath(t *testing.T) {
	_, a, _ := ncSetup(t, "mncN2")
	p := filepath.Join(a.work, "Documents", "d1", "n007.txt")
	mt := ncMtime.Add(107*time.Second + 500*time.Microsecond) // n007 of d1 is at +107 s
	if fi, err := os.Stat(p); err != nil || !fi.ModTime().Equal(ncMtime.Add(107*time.Second)) {
		t.Fatalf("fixture: %v %v", fi.ModTime(), err)
	}
	if err := os.Chtimes(p, mt, mt); err != nil {
		t.Fatal(err)
	}
	out, msg := a.push(t)
	if msg != "" {
		t.Fatalf("push: %s\n%s", msg, out)
	}
	if strings.Contains(out, ncNoChangeMark) {
		t.Fatalf("a changed mtime ended after the walk:\n%s", out)
	}
	if !strings.Contains(out, " chunks (") {
		t.Errorf("no full-path seal summary:\n%s", out)
	}
	out, msg = a.push(t)
	if msg != "" {
		t.Fatalf("third push: %s\n%s", msg, out)
	}
	if !strings.Contains(out, ncNoChangeMark) {
		t.Errorf("the full path did not record its walk: the next unchanged push took the full path again.\n%s", out)
	}
}

// N3: another writer moves the stored head between two pushes. This device's receipt and record still name the old
// head, and its tree is unchanged, so only the stored-head check can decline.
func TestMediaNoChange_AnotherWriterMovedTheHead(t *testing.T) {
	s, a, h1 := ncSetup(t, "mncN3")
	b := ncNewDevice(t, s, a.name, a.pass)
	b.fixture(t)
	b.put("Documents/from-b.txt", "written on the other handset")
	b.login(h1)
	if out, msg := b.push(t); msg != "" {
		t.Fatalf("the other writer's seal: %s\n%s", msg, out)
	}
	if h2 := a.head("#media"); h2 == h1 {
		t.Fatal("the other writer did not move the head -- this fixture proves nothing")
	}
	if got := a.receipt(); got != h1 {
		t.Fatalf("this device's receipt moved to %q -- the receipt check alone would decline", got)
	}
	out, _ := a.push(t)
	if strings.Contains(out, ncNoChangeMark) {
		t.Fatalf("a push over a head another writer moved ended after the walk:\n%s", out)
	}
}

// N4: a tombstones file names a rel. A delete through mediad is not a walked change, so the push takes the full path.
func TestMediaNoChange_ATombstoneTakesTheFullPath(t *testing.T) {
	_, a, _ := ncSetup(t, "mncN4")
	tomb := filepath.Join(t.TempDir(), ".deleted")
	if err := os.WriteFile(tomb, []byte("DCIM/Camera/IMG_9999.jpg\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", tomb)
	out, _ := a.push(t)
	if strings.Contains(out, ncNoChangeMark) {
		t.Fatalf("a push with a tombstone ended after the walk:\n%s", out)
	}
}

// ncTombstoneCase points NOWHERE_MEDIA_TOMBSTONES at path and returns the next push's output.
func ncTombstoneCase(t *testing.T, a *ncDevice, path string) string {
	t.Helper()
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", path)
	if _, err := os.Stat(a.recordPath()); err != nil {
		t.Fatalf("setup: the landed seal wrote no record (%v) -- this fixture proves nothing", err)
	}
	out, _ := a.push(t)
	return out
}

// N4b: a tombstones file that holds only blank lines is not empty. The early end reads no content, so it is a doubt,
// and the push takes the full path.
func TestMediaNoChange_ABlankLinesTombstoneFileTakesTheFullPath(t *testing.T) {
	_, a, _ := ncSetup(t, "mncN4b")
	tomb := filepath.Join(t.TempDir(), ".deleted")
	if err := os.WriteFile(tomb, []byte("\n  \n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if out := ncTombstoneCase(t, a, tomb); strings.Contains(out, ncNoChangeMark) {
		t.Fatalf("a non-empty tombstones file of blank lines allowed the early end:\n%s", out)
	}
}

// N4c: a tombstones path the push cannot inspect as a file (here a directory, which os.ReadFile fails on) is a
// doubt, and the push takes the full path.
func TestMediaNoChange_AnUninspectableTombstonePathTakesTheFullPath(t *testing.T) {
	_, a, _ := ncSetup(t, "mncN4c")
	if out := ncTombstoneCase(t, a, t.TempDir()); strings.Contains(out, ncNoChangeMark) {
		t.Fatalf("a tombstones path that is a directory allowed the early end:\n%s", out)
	}
}

// N4d: an empty tombstones file, or none at the named path, names nothing: the push still ends after the walk.
func TestMediaNoChange_AnEmptyOrMissingTombstoneFileIsNoChange(t *testing.T) {
	_, a, _ := ncSetup(t, "mncN4d")
	tomb := filepath.Join(t.TempDir(), ".deleted")
	if out := ncTombstoneCase(t, a, tomb); !strings.Contains(out, ncNoChangeMark) {
		t.Fatalf("a missing tombstones file blocked the early end:\n%s", out)
	}
	if err := os.WriteFile(tomb, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if out := ncTombstoneCase(t, a, tomb); !strings.Contains(out, ncNoChangeMark) {
		t.Fatalf("an empty tombstones file blocked the early end:\n%s", out)
	}
}

// N5: the periodic full re-hash (NOWHERE_SEAL_FULL_EVERY=2) makes the second push a forced full, which never ends early.
func TestMediaNoChange_ForcedFullTakesTheFullPath(t *testing.T) {
	ncEnv(t)
	t.Setenv("NOWHERE_SEAL_FULL_EVERY", "2")
	s := newNCStore(t)
	name, pass := "mncN5", "nochange pass mncN5"
	createVault(s.base, name, pass)
	a := ncNewDevice(t, s, name, pass)
	a.fixture(t)
	if _, msg := a.push(t); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	a.login(a.head("#media"))
	if _, err := os.Stat(a.recordPath()); err != nil {
		t.Fatalf("setup: the first seal wrote no record (%v) -- this fixture proves nothing", err)
	}
	out, _ := a.push(t)
	if strings.Contains(out, ncNoChangeMark) {
		t.Fatalf("a forced full seal ended after the walk:\n%s", out)
	}
}

// N6: a seal whose post-publish materialise could not land a carried rel leaves no record, so the next push takes
// the full path and the materialise retries. The rel is app-external data of an app this handset does not hold,
// which never lands here.
func TestMediaNoChange_AMissedMaterialiseLeavesNoRecord(t *testing.T) {
	s, a, h1 := ncSetup(t, "mncN6")
	b := ncNewDevice(t, s, a.name, a.pass)
	b.fixture(t)
	b.login(h1)
	if out, msg := b.push(t); msg != "" {
		t.Fatalf("B's first seal: %s\n%s", msg, out)
	}
	if _, err := os.Stat(b.recordPath()); err != nil {
		t.Fatalf("setup: B's landed seal wrote no record (%v) -- this fixture proves nothing", err)
	}
	a.put("Android/data/com.example.ncapp/files/n6.bin", "an app file only A holds")
	if out, msg := a.push(t); msg != "" {
		t.Fatalf("A's seal: %s\n%s", msg, out)
	}
	out, msg := b.push(t)
	if msg != "" {
		t.Fatalf("B's carry seal: %s\n%s", msg, out)
	}
	if _, err := os.Lstat(filepath.Join(b.work, "Android", "data", "com.example.ncapp", "files", "n6.bin")); err == nil {
		t.Fatal("the app file landed on B -- this fixture proves nothing")
	}
	if _, err := os.Stat(b.recordPath()); err == nil {
		t.Fatalf("a seal whose materialise missed a rel left a record:\n%s", out)
	}
	out, _ = b.push(t)
	if strings.Contains(out, ncNoChangeMark) {
		t.Fatalf("the push after a missed materialise ended after the walk:\n%s", out)
	}
}

// M4 guard, direct store: putHead is the head PUT there, and a seal whose head PUT fails leaves no record.
func TestMediaNoChange_NoRecordAfterAFailedHeadPut(t *testing.T) {
	ncEnv(t)
	s, a, _ := ncSetupOn(t, newNCHTTPStore(t), "mncM4")
	if _, err := os.Stat(a.recordPath()); err != nil {
		t.Fatalf("setup: the landed seal wrote no record (%v) -- this fixture proves nothing", err)
	}
	a.putAt("Documents/d0/n000.txt", "changed so the push takes the full path", ncMtime.Add(72*time.Hour))
	s.failRefPut.Store(true)
	out, msg := a.push(t)
	s.failRefPut.Store(false)
	if msg == "" {
		t.Fatalf("the push landed although every ref PUT failed -- this fixture proves nothing\n%s", out)
	}
	if _, err := os.Stat(a.recordPath()); err == nil {
		t.Fatalf("a push whose head PUT failed left a record (%s)", msg)
	}
}

// M4 guard, cap mode: the head lands at the deferred capFlush, after pushProfile's last line. A flush whose head PUT
// fails leaves the stored head at the old value and NO record, and the next push over the same tree takes the full
// path.
func TestMediaNoChange_AFailedFlushLeavesNoRecord(t *testing.T) {
	s, a, h1 := ncSetup(t, "mncFlush")
	if _, err := os.Stat(a.recordPath()); err != nil {
		t.Fatalf("setup: the landed seal wrote no record (%v) -- this fixture proves nothing", err)
	}
	a.putAt("Documents/d0/n000.txt", "changed so the push takes the full path", ncMtime.Add(72*time.Hour))
	s.failRefPut.Store(true)
	out, msg := a.push(t)
	s.failRefPut.Store(false)
	if msg == "" {
		t.Fatalf("the push landed although every ref PUT failed -- this fixture proves nothing\n%s", out)
	}
	if got := a.head("#media"); got != h1 {
		t.Fatalf("the stored head moved to %s although its PUT failed -- this fixture proves nothing", short(got))
	}
	if b, err := os.ReadFile(a.recordPath()); err == nil {
		t.Fatalf("a push whose flush failed left a record %q (%s)", strings.TrimSpace(string(b)), msg)
	}
	out, _ = a.push(t)
	if strings.Contains(out, ncNoChangeMark) {
		t.Fatalf("the push after a failed flush ended after the walk -- the change was never stored:\n%s", out)
	}
}

// The record names no profile and no rel: one head and one digest.
func TestMediaNoChange_RecordHoldsOnlyHeadAndDigest(t *testing.T) {
	_, a, h1 := ncSetup(t, "mncRec")
	b, err := os.ReadFile(a.recordPath())
	if err != nil {
		t.Fatal(err)
	}
	f := strings.Fields(string(b))
	if len(f) != 2 || f[0] != h1 || len(f[1]) != 64 {
		t.Fatalf("record %q: want `<head> <64 hex>`", string(b))
	}
	if strings.Contains(string(b), a.name) || strings.Contains(string(b), "Documents") || strings.Contains(string(b), "DCIM") {
		t.Fatalf("the record names a profile or a rel: %q", string(b))
	}
}

// ncDigest walks src as the seal does and returns the walk digest.
func ncDigest(t *testing.T, src string, pins map[string]bool) string {
	t.Helper()
	n := 0
	emit := func([]byte) int { n++; return n - 1 }
	cached := func(string) int { n++; return n - 1 }
	_, _, _, _, _, _, st, _ := walkChunks(src, nil, 1<<20, false, false, nil, nil, pins, nil, 0, emit, cached, func(int64) {}, nil)
	return st.digest
}

// The digest is stable for one tree and moves with an mtime alone, a mode alone, or a pin.
func TestMediaNoChange_DigestFields(t *testing.T) {
	t.Setenv("NOWHERE_DEFER_LIST", "")
	t.Setenv("NOWHERE_DROP_LIST", "")
	src := t.TempDir()
	for i := 0; i < 5; i++ {
		iwrite(t, src, fmt.Sprintf("a/f%d.txt", i), []byte(strings.Repeat("x", 100+i)))
	}
	p := filepath.Join(src, "a", "f2.txt")
	for _, q := range []string{p, filepath.Join(src, "a"), src} {
		if err := os.Chtimes(q, ncMtime, ncMtime); err != nil {
			t.Fatal(err)
		}
	}
	d0 := ncDigest(t, src, nil)
	if d0 == "" || ncDigest(t, src, nil) != d0 {
		t.Fatal("two walks of one tree gave different digests")
	}
	mt := ncMtime.Add(time.Nanosecond * 1000)
	if err := os.Chtimes(p, mt, mt); err != nil {
		t.Fatal(err)
	}
	d1 := ncDigest(t, src, nil)
	if d1 == d0 {
		t.Error("an mtime change alone did not move the digest")
	}
	if err := os.Chmod(p, 0o640); err != nil {
		t.Fatal(err)
	}
	d2 := ncDigest(t, src, nil)
	if d2 == d1 {
		t.Error("a mode change alone did not move the digest")
	}
	if ncDigest(t, src, map[string]bool{"com.example.pin": true}) == d2 {
		t.Error("a pin did not move the digest")
	}
}

// RF-003: a re-keyed #media scope (a credential change or a recovery) has a vault head, and its seal publishes the
// vault hash, not the manifest. The record must hold that committed head, so the next unchanged push ends after the
// walk instead of minting another vault.
func TestMediaNoChange_AVaultScopeRecordsTheVaultHead(t *testing.T) {
	s, a, h1 := ncSetup(t, "mncVault")
	scoped := a.name + "#media"
	var vh0 string
	a.as(func() {
		n := capBegin()
		capSetSession(scoped, a.pass, deriveKey(scoped, a.pass))
		vh0 = publishRepointVault(s.base, scoped, a.pass, buildScopeVault(deriveKey(scoped, a.pass), scoped, a.pass, h1))
		capFlush(n)
	})
	a.login(vh0)
	if out, msg := a.push(t); msg != "" {
		t.Fatalf("the first push over the vault head: %s\n%s", msg, out)
	}
	vh1 := a.head("#media")
	if _, isV := parseVault(getHeadBlob(s.base, vh1)); !isV {
		t.Fatalf("the seal over a vault head published %s, not a vault -- this fixture proves nothing", short(vh1))
	}
	rh, _, ok := readMediaNoChangeAt(a)
	if !ok {
		t.Fatal("the vault seal left no record")
	}
	if rh != vh1 {
		t.Fatalf("the record holds %s, want the committed vault head %s", short(rh), short(vh1))
	}
	if rc := a.receipt(); rc != vh1 {
		t.Fatalf("the receipt holds %s, want the committed vault head %s", short(rc), short(vh1))
	}
	refs0, blobs0, leases0 := s.refPuts.Load(), s.blobPuts.Load(), s.leases.Load()
	out, msg := a.push(t)
	if msg != "" {
		t.Fatalf("the second push: %s\n%s", msg, out)
	}
	if !strings.Contains(out, ncNoChangeMark+short(vh1)) {
		t.Fatalf("an unchanged tree under a vault head took the full path:\n%s", out)
	}
	if n := s.refPuts.Load() - refs0; n != 0 {
		t.Errorf("a no-change push wrote %d ref(s)", n)
	}
	if n := s.blobPuts.Load() - blobs0; n != 0 {
		t.Errorf("a no-change push uploaded %d blob(s)", n)
	}
	if n := s.leases.Load() - leases0; n != 0 {
		t.Errorf("a no-change push took %d lease(s)", n)
	}
	if got := a.head("#media"); got != vh1 {
		t.Errorf("the stored head moved: %s -> %s", short(vh1), short(got))
	}
}

// readMediaNoChangeAt reads device d's record from its own blob-cache dir.
func readMediaNoChangeAt(d *ncDevice) (head, digest string, ok bool) {
	prev := os.Getenv("NOWHERE_BLOBCACHE")
	os.Setenv("NOWHERE_BLOBCACHE", d.bc)
	defer os.Setenv("NOWHERE_BLOBCACHE", prev)
	return readMediaNoChange(contentCacheTagFor(deriveKey(d.name+"#media", d.pass)))
}
