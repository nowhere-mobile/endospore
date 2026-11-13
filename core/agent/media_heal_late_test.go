package main

// NWP-20261202-17: the vault heal of unkept apps runs after landing (media_heal_late.go). These tests pin the
// restore's split (unkept apps' vault entries stay deferred, kept apps and #de still heal), mediad's landing
// (bytes, mode, mtime, owner, tombstone after the rename), what keeps a stub, and the seal's carry while the
// late heal is still outstanding.

import (
	"bytes"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// hlCountFetches counts the chunks the restore heal fetches (healFetchChunk), for the test's lifetime.
func hlCountFetches(t *testing.T) *int64 {
	t.Helper()
	var n int64
	old := healFetchChunk
	healFetchChunk = func(base string, key []byte, version int, h string) ([]byte, error) {
		atomic.AddInt64(&n, 1)
		return old(base, key, version, h)
	}
	t.Cleanup(func() { healFetchChunk = old })
	return &n
}

// hlHead seals files into the vault the way an older handset did (every one deferred) and returns the head.
func hlHead(t *testing.T, base, name, pass string, files map[string][]byte, mode os.FileMode, mt time.Time) chunkManifest {
	t.Helper()
	preGateSeal(t)
	src := t.TempDir()
	os.MkdirAll(filepath.Join(src, "app.other"), 0o755)
	os.WriteFile(filepath.Join(src, "app.other/note.txt"), []byte("essential"), 0o644)
	for rel, data := range files {
		p := filepath.Join(src, filepath.FromSlash(rel))
		os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.WriteFile(p, data, mode); err != nil {
			t.Fatal(err)
		}
		os.Chmod(p, mode)
		os.Chtimes(p, mt, mt)
	}
	pushProfile(base, name, pass, src)
	m := headManifest(t, base, resolveDK(base, name, pass, nil), name, pass)
	for rel := range files {
		if len(m.Deferred[rel].Chunks) == 0 {
			t.Fatalf("fixture: the pre-gate seal did not defer %s", rel)
		}
	}
	return m
}

func hlWriteKeep(t *testing.T, root, body string) {
	t.Helper()
	p := filepath.Join(root, chooserPkg, "files", "nowhere-appkeep")
	os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestHealAfterLandingRestoreFetchesNothing(t *testing.T) {
	state := healTestEnv(t)
	base := newHTTPStore(t)
	name, pass := "hal-restore", "hal-restore horse battery staple"
	createVault(base, name, pass)
	a, b := "app.maps/files/maps/a.mwm", "app.maps/files/maps/b.mwm"
	here, held := "app.maps/files/maps/here.mwm", "app.maps/files/maps/held.mwm"
	kept := "app.kept/files/k.bin"
	files := map[string][]byte{}
	for i, rel := range []string{a, b, here, held, kept} {
		files[rel] = bytes.Repeat([]byte{byte('A' + i)}, 9000+i)
	}
	m := hlHead(t, base, name, pass, files, 0o644, time.Unix(1700000000, 0))
	dk := resolveDK(base, name, pass, nil)
	fetches := hlCountFetches(t)

	// newDest: the phone after cdcRestore -- one deferred file already there, one in the on-demand hold.
	newDest := func(keep string) string {
		dest := t.TempDir()
		os.MkdirAll(filepath.Join(dest, "app.maps/files/maps"), 0o755)
		os.WriteFile(filepath.Join(dest, here), []byte("the phone's own copy"), 0o644)
		hold := filepath.Join(dest, filepath.FromSlash(odHoldRelFor(held)))
		os.MkdirAll(filepath.Dir(hold), 0o755)
		d := m.Deferred[held]
		os.WriteFile(hold, bytes.Repeat([]byte("h"), int(d.Size)), 0o644)
		mt := time.Unix(0, deferredMTimeNanos(d.MTime))
		os.Chtimes(hold, mt, mt)
		if keep != "" {
			hlWriteKeep(t, dest, keep)
		}
		return dest
	}
	sorted := func(rels []string) string {
		s := append([]string(nil), rels...)
		sort.Strings(s)
		return strings.Join(s, ",")
	}

	t.Setenv("NOWHERE_HEAL_AFTER_LANDING", "1")

	// No keep file: no app is kept, so the sign-in fetches nothing at all.
	atomic.StoreInt64(fetches, 0)
	r := restoreHeal(base, dk, m, newDest(""), name, pass, state)
	if n := atomic.LoadInt64(fetches); n != 0 || r.fetched != 0 {
		t.Errorf("flag on, no keep file: fetched %d file(s), %d chunk(s); the vault heal of unkept apps runs after landing", r.fetched, n)
	}
	if r.reasons["after landing"] != 3 {
		t.Errorf("flag on, no keep file: reasons %v, want 3 rels left \"after landing\"", r.reasons)
	}
	if got, want := sorted(r.handledRels), sorted([]string{here, held}); got != want {
		t.Errorf("flag on: handled %q, want %q (present and held only; a late rel is NOT handled)", got, want)
	}
	if h, ran := readHealList(state, name, pass); !ran || len(h) != 2 || h[a] || h[b] || h[kept] || !h[here] || !h[held] {
		t.Errorf("flag on: the heal list %v (ran %v) must hold the present and held rels only", h, ran)
	}

	// A kept app is parked by hold_ondemand before any install: its entries still heal in the sign-in.
	atomic.StoreInt64(fetches, 0)
	dest := newDest(hlKeepLine("app.kept", "installed") + hlKeepLine("app.other", "ondemand"))
	r = restoreHeal(base, dk, m, dest, name, pass, state)
	if r.fetched != 1 || r.reasons["after landing"] != 2 {
		t.Errorf("flag on, app.kept kept: %+v, want the kept app's file fetched and the 2 unkept ones left", r)
	}
	if n := atomic.LoadInt64(fetches); n != int64(len(m.Deferred[kept].Chunks)) {
		t.Errorf("flag on, app.kept kept: %d chunk(s) fetched, want only the kept file's %d", n, len(m.Deferred[kept].Chunks))
	}
	if got, _ := os.ReadFile(filepath.Join(dest, kept)); !bytes.Equal(got, files[kept]) {
		t.Error("flag on: the kept app's file was not healed in the sign-in")
	}
	if _, err := os.Lstat(filepath.Join(dest, a)); err == nil {
		t.Error("flag on: an unkept app's file was written in the sign-in")
	}

	// #de has no serve path: it heals in the sign-in whatever the flag says.
	atomic.StoreInt64(fetches, 0)
	r = restoreHeal(base, dk, m, newDest(""), name+"#de", pass, state)
	if r.fetched != 3 || r.reasons["after landing"] != 0 || atomic.LoadInt64(fetches) == 0 {
		t.Errorf("#de with the flag: %+v, want all 3 fetchable files fetched", r)
	}

	// A keep file that exists but cannot be read: heal everything, as before this build.
	dest = newDest("")
	os.MkdirAll(filepath.Join(dest, chooserPkg, "files", "nowhere-appkeep"), 0o755)
	r = restoreHeal(base, dk, m, dest, name, pass, state)
	if r.fetched != 3 || r.reasons["after landing"] != 0 {
		t.Errorf("unreadable keep file: %+v, want all 3 fetched", r)
	}

	// Flag off: today.
	t.Setenv("NOWHERE_HEAL_AFTER_LANDING", "")
	r = restoreHeal(base, dk, m, newDest(""), name, pass, state)
	if r.fetched != 3 || r.reasons["after landing"] != 0 {
		t.Errorf("flag off: %+v, want all 3 fetched", r)
	}
}

func hlKeepLine(pkg, mode string) string { return pkg + "\t" + mode + "\n" }

// The CLOSES-WHEN test: a seal while the late heal is outstanding keeps every unhealed entry with its chunks
// (the carry is armed for the vault), and the one entry mediad landed seals essential. None is dropped.
func TestSealDuringOutstandingLateHealCarriesEveryUnhealedEntry(t *testing.T) {
	state := healTestEnv(t)
	t.Setenv("NOWHERE_HEAL_AFTER_LANDING", "1")
	t.Setenv("NOWHERE_HEAL_RESERVE", "0")
	base := newHTTPStore(t)
	name, pass := "hal-seal", "hal-seal horse battery staple"
	createVault(base, name, pass)
	rels := []string{"app.maps/files/maps/a.mwm", "app.maps/files/maps/b.mwm", "app.maps/files/maps/c.mwm"}
	files := map[string][]byte{}
	for i, rel := range rels {
		files[rel] = bytes.Repeat([]byte("LATE-"+string(rune('A'+i))+"-"), 3000)
	}
	m := hlHead(t, base, name, pass, files, 0o644, time.Unix(1700000000, 0))
	dk := resolveDK(base, name, pass, nil)
	sealScopeDefers = scopeDefersMedia // this build from here on

	// The session: the essential tree is on the phone, the three deferred files are stubs (not on disk).
	src := t.TempDir()
	os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755)
	os.MkdirAll(filepath.Join(src, "app.other"), 0o755)
	os.WriteFile(filepath.Join(src, "app.other/note.txt"), []byte("essential"), 0o644)
	if r := restoreHeal(base, dk, m, src, name, pass, state); r.fetched != 0 || r.reasons["after landing"] != 3 {
		t.Fatalf("restore: %+v, want all 3 left for after landing", r)
	}

	// mediad: lands a, cannot land b or c yet.
	m.Deferred = mediadHealFilter(name, pass, state, m.Deferred)
	srv := newMediaServer(base, dk, m, filepath.Join(src, filepath.FromSlash(mediaCacheRel)))
	old := healLateRename
	healLateRename = func(tmp, dst string) error {
		if filepath.Base(dst) == "a.mwm" {
			return renameNoReplace(tmp, dst)
		}
		return &os.LinkError{Op: "rename", Old: tmp, New: dst, Err: syscall.EIO}
	}
	t.Cleanup(func() { healLateRename = old })
	res := srv.healLate(name, src, map[string]string{"app.maps/files/maps": filepath.Join(src, "app.maps/files/maps")})
	if res.landed != 1 || res.left != 2 || res.reasons["rename"] != 2 {
		t.Fatalf("healLate: %+v, want a landed and b, c left (rename)", res)
	}

	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0") // the carry must not depend on the process-wide switch
	time.Sleep(5 * time.Millisecond)
	os.WriteFile(filepath.Join(src, "app.other/note.txt"), []byte("essential, a real second seal"), 0o644)
	pushProfile(base, name, pass, src)

	m2 := headManifest(t, base, dk, name, pass)
	for _, rel := range rels[1:] {
		got, ok := m2.Deferred[rel]
		if !ok {
			t.Errorf("%s: an entry the late heal had not landed was DROPPED by the seal", rel)
			continue
		}
		if strings.Join(got.Chunks, ",") != strings.Join(m.Deferred[rel].Chunks, ",") {
			t.Errorf("%s: carried with other chunks than the old head's", rel)
		}
	}
	if _, ok := m2.Deferred[rels[0]]; ok {
		t.Errorf("%s: landed and tombstoned, but still deferred", rels[0])
	}
	if !manifestCarries(t, base, dk, m2, rels[0], files[rels[0]]) {
		t.Errorf("%s: landed by mediad, but not in the essential tar", rels[0])
	}
}

// hlServer is one mediad scope over a one-file pre-gate head: the package dir and its real dir (the .under the
// overlay would bind) under userDir, and the CE cache dir where the tombstones go.
type hlServer struct {
	srv                     *mediaServer
	rel, userDir, under, dc string
	data                    []byte
	d                       deferredFile
}

func hlSetup(t *testing.T, name string) hlServer {
	t.Helper()
	healTestEnv(t)
	t.Setenv("NOWHERE_HEAL_RESERVE", "0")
	base := newHTTPStore(t)
	pass := name + " horse battery staple"
	createVault(base, name, pass)
	rel := "app.maps/files/maps/one.mwm"
	data := bytes.Repeat([]byte("LAND-ME-LATE-"), 4000)
	m := hlHead(t, base, name, pass, map[string][]byte{rel: data}, 0o640, time.Unix(1700000000, 0))
	userDir := t.TempDir()
	under := filepath.Join(userDir, "app.maps/files/maps")
	os.MkdirAll(under, 0o755)
	dc := filepath.Join(userDir, filepath.FromSlash(mediaCacheRel))
	return hlServer{newMediaServer(base, resolveDK(base, name, pass, nil), m, dc), rel, userDir, under, dc, data, m.Deferred[rel]}
}

func (h hlServer) run(scope string) healLateResult {
	return h.srv.healLate(scope, h.userDir, map[string]string{"app.maps/files/maps": h.under})
}

// hlNoTemp fails when a .nwseed-* temp is left in dir.
func hlNoTemp(t *testing.T, dir string) {
	t.Helper()
	ents, _ := os.ReadDir(dir)
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), ".nwseed-") {
			t.Errorf("a temp was left behind: %s", e.Name())
		}
	}
}

func hlTombstoned(h hlServer) bool {
	b, _ := os.ReadFile(filepath.Join(h.dc, ".deleted"))
	return h.srv.isDeleted(h.rel) || strings.Contains(string(b), h.rel)
}

func TestHealLateLandsOwnsAndTombstones(t *testing.T) {
	h := hlSetup(t, "hal-lands")
	oldChown, oldOwner := materializeChown, materializeOwnerOf
	t.Cleanup(func() { materializeChown, materializeOwnerOf = oldChown, oldOwner })
	var ownerOf, chowned string
	var cu, cg int
	materializeOwnerOf = func(p string) (int, int, bool) { ownerOf = p; return 10123, 10124, true }
	materializeChown = func(p string, uid, gid int) error { chowned, cu, cg = p, uid, gid; return nil }

	res := h.run("hal-lands")
	if res.landed != 1 || res.left != 0 || res.bytes != h.d.Size {
		t.Fatalf("result %+v, want one file landed", res)
	}
	dst := filepath.Join(h.under, "one.mwm")
	got, err := os.ReadFile(dst)
	if err != nil || !bytes.Equal(got, h.data) {
		t.Fatalf("landed bytes differ (%v)", err)
	}
	fi, _ := os.Stat(dst)
	if fi.Mode().Perm() != 0o640 {
		t.Errorf("mode %v, want the recorded 0640", fi.Mode().Perm())
	}
	if fi.ModTime().UnixNano() != deferredMTimeNanos(h.d.MTime) {
		t.Errorf("mtime %v, want the recorded one", fi.ModTime())
	}
	if ownerOf != filepath.Join(h.userDir, "app.maps") {
		t.Errorf("owner read from %q, want the package dir", ownerOf)
	}
	if !strings.HasPrefix(filepath.Base(chowned), ".nwseed-") || cu != 10123 || cg != 10124 {
		t.Errorf("chown %q to %d:%d, want the temp to the package dir's 10123:10124", chowned, cu, cg)
	}
	b, _ := os.ReadFile(filepath.Join(h.dc, ".deleted"))
	if !h.srv.isDeleted(h.rel) || string(b) != h.rel+"\n" {
		t.Errorf("the landed file's stub was not tombstoned (.deleted %q)", b)
	}
	hlNoTemp(t, h.under)
}

func TestHealLateKeepsStubOnFailure(t *testing.T) {
	cases := []struct {
		name, why string
		set       func(t *testing.T, h *hlServer)
	}{
		{"fetch", "fetch", func(t *testing.T, h *hlServer) {
			d := h.d
			d.Size++ // the store's bytes no longer match: fetchFile fails
			h.srv.deferred = map[string]deferredFile{h.rel: d}
		}},
		{"chown", "owner", func(t *testing.T, h *hlServer) {
			old := materializeChown
			materializeChown = func(string, int, int) error { return syscall.EPERM }
			t.Cleanup(func() { materializeChown = old })
		}},
		{"space", "space", func(t *testing.T, h *hlServer) {
			old := healFreeBytes
			need := 2*h.d.Size - 1
			healFreeBytes = func(string) (int64, error) { return need, nil }
			t.Cleanup(func() { healFreeBytes = old })
		}},
		{"no package dir", "no package dir", func(t *testing.T, h *hlServer) {
			h.under = t.TempDir()
			os.RemoveAll(filepath.Join(h.userDir, "app.maps"))
		}},
		{"kept", "parked", func(t *testing.T, h *hlServer) {
			hlWriteKeep(t, h.userDir, hlKeepLine("app.maps", "ondemand"))
		}},
		{"odhold", "parked", func(t *testing.T, h *hlServer) {
			os.MkdirAll(filepath.Join(h.userDir, chooserPkg, odHoldDirName, "app.maps"), 0o755)
		}},
		{"rename", "rename", func(t *testing.T, h *hlServer) {
			old := healLateRename
			healLateRename = func(tmp, dst string) error {
				return &os.LinkError{Op: "rename", Old: tmp, New: dst, Err: syscall.EIO}
			}
			t.Cleanup(func() { healLateRename = old })
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := hlSetup(t, "hal-keep-"+strings.ReplaceAll(c.name, " ", "-"))
			c.set(t, &h)
			res := h.run("hal-keep")
			if res.landed != 0 || res.left != 1 || res.reasons[c.why] != 1 {
				t.Errorf("result %+v, want the file left with reason %q", res, c.why)
			}
			if hlTombstoned(h) {
				t.Error("the stub was tombstoned though nothing landed")
			}
			if _, err := os.Lstat(filepath.Join(h.under, "one.mwm")); err == nil {
				t.Error("a file was landed")
			}
			hlNoTemp(t, h.under)
		})
	}
}

func TestHealLateNeverReplacesARealFile(t *testing.T) {
	h := hlSetup(t, "hal-real")
	dst := filepath.Join(h.under, "one.mwm")
	os.WriteFile(dst, []byte("the app wrote this first"), 0o600)
	res := h.run("hal-real")
	if got, _ := os.ReadFile(dst); string(got) != "the app wrote this first" {
		t.Fatalf("the late heal replaced a real file (now %d bytes)", len(got))
	}
	if res.landed != 0 || res.left != 0 || res.reasons["exists"] != 1 || !hlTombstoned(h) {
		t.Errorf("result %+v (tombstoned %v), want the real file kept and the stub tombstoned", res, hlTombstoned(h))
	}
	hlNoTemp(t, h.under)
}

func TestHealLateVaultOnly(t *testing.T) {
	h := hlSetup(t, "hal-media")
	res := h.run("hal-media#media")
	if res.landed != 0 || len(res.reasons) != 0 || hlTombstoned(h) {
		t.Errorf("#media: %+v; the late heal must leave a scope that still defers alone", res)
	}
	if _, err := os.Lstat(filepath.Join(h.under, "one.mwm")); err == nil {
		t.Error("#media: a file was landed")
	}
	if ents, _ := os.ReadDir(h.dc); len(ents) != 0 {
		t.Errorf("#media: %d cache entr(ies) written; nothing may be fetched", len(ents))
	}
}

// RF-001: a seal that walks the dir BEFORE the late heal's rename and reads the tombstones AFTER it. The walk did
// not see the file, so the carry must keep its deferred entry (the landed bytes, in that one form); the next seal
// walks the real file and seals it essential.
func TestSealRacingLateHealKeepsTheLandedFile(t *testing.T) {
	state := healTestEnv(t)
	t.Setenv("NOWHERE_HEAL_AFTER_LANDING", "1")
	t.Setenv("NOWHERE_HEAL_RESERVE", "0")
	base := newHTTPStore(t)
	name, pass := "hal-race", "hal-race horse battery staple"
	createVault(base, name, pass)
	rel := "app.maps/files/maps/race.mwm"
	data := bytes.Repeat([]byte("RACE-THE-SEAL-"), 3000)
	m := hlHead(t, base, name, pass, map[string][]byte{rel: data}, 0o644, time.Unix(1700000000, 0))
	dk := resolveDK(base, name, pass, nil)
	sealScopeDefers = scopeDefersMedia

	src := t.TempDir()
	os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755)
	os.MkdirAll(filepath.Join(src, "app.other"), 0o755)
	os.WriteFile(filepath.Join(src, "app.other/note.txt"), []byte("essential"), 0o644)
	if r := restoreHeal(base, dk, m, src, name, pass, state); r.reasons["after landing"] != 1 {
		t.Fatalf("restore: %+v, want the file left for after landing", r)
	}
	m.Deferred = mediadHealFilter(name, pass, state, m.Deferred)
	srv := newMediaServer(base, dk, m, filepath.Join(src, filepath.FromSlash(mediaCacheRel)))

	ran := false
	sealAfterWalkHook = func() {
		ran = true
		res := srv.healLate(name, src, map[string]string{"app.maps/files/maps": filepath.Join(src, "app.maps/files/maps")})
		if res.landed != 1 {
			t.Errorf("healLate inside the seal: %+v, want the file landed", res)
		}
	}
	t.Cleanup(func() { sealAfterWalkHook = nil })
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	time.Sleep(5 * time.Millisecond)
	os.WriteFile(filepath.Join(src, "app.other/note.txt"), []byte("essential, a real second seal"), 0o644)
	pushProfile(base, name, pass, src)
	if !ran {
		t.Fatal("the seal never reached the after-walk seam")
	}
	m2 := headManifest(t, base, dk, name, pass)
	got, deferred := m2.Deferred[rel]
	if !deferred && !manifestCarries(t, base, dk, m2, rel, data) {
		t.Fatalf("%s: landed while the seal ran, and the new head holds it neither deferred nor essential", rel)
	}
	if deferred && strings.Join(got.Chunks, ",") != strings.Join(m.Deferred[rel].Chunks, ",") {
		t.Errorf("%s: carried with other chunks than the old head's", rel)
	}

	// The next seal walks the landed file: essential, and the deferred entry goes.
	sealAfterWalkHook = nil
	time.Sleep(5 * time.Millisecond)
	os.WriteFile(filepath.Join(src, "app.other/note.txt"), []byte("essential, a third seal"), 0o644)
	pushProfile(base, name, pass, src)
	m3 := headManifest(t, base, dk, name, pass)
	if _, ok := m3.Deferred[rel]; ok {
		t.Errorf("%s: still deferred after a seal that walked the landed file", rel)
	}
	if !manifestCarries(t, base, dk, m3, rel, data) {
		t.Errorf("%s: the seal after the race did not seal the landed file essential", rel)
	}
}

// RF-001, the other side: a landed file the app then deleted (a real unlink, no new tombstone) is not carried.
func TestSealDropsALateHealLandedFileTheAppDeleted(t *testing.T) {
	src := t.TempDir()
	rel := "app.maps/files/maps/gone.mwm"
	landed := map[string]bool{rel: true}
	if lateLandedUnwalked(src, rel, landed, map[string]bool{}) {
		t.Error("a landed file that is not on disk must not be carried")
	}
	os.MkdirAll(filepath.Join(src, "app.maps/files/maps"), 0o755)
	os.WriteFile(filepath.Join(src, filepath.FromSlash(rel)), []byte("x"), 0o644)
	if !lateLandedUnwalked(src, rel, landed, map[string]bool{}) {
		t.Error("a landed file on disk the walk did not see must be carried")
	}
	if lateLandedUnwalked(src, rel, landed, map[string]bool{rel: true}) {
		t.Error("a landed file the walk saw is sealed essential, never carried")
	}
	if lateLandedUnwalked(src, rel, map[string]bool{}, map[string]bool{}) {
		t.Error("a tombstoned rel the late heal did not land (an app unlink) must not be carried")
	}
}

// RF-002: the app unlinks the stub while the late heal makes its copy. The heal must not land the file.
func TestHealLateNeverUndoesAnUnlink(t *testing.T) {
	h := hlSetup(t, "hal-unlink")
	oldChown := materializeChown
	t.Cleanup(func() { materializeChown = oldChown })
	materializeChown = func(string, int, int) error {
		if err := h.srv.markDeleted(h.rel); err != nil { // what mediaRoot.Unlink does for a live stub
			t.Fatal(err)
		}
		return nil
	}
	res := h.run("hal-unlink")
	if res.landed != 0 || res.reasons["deleted"] != 1 {
		t.Errorf("result %+v, want the file left with reason \"deleted\"", res)
	}
	if _, err := os.Lstat(filepath.Join(h.under, "one.mwm")); err == nil {
		t.Error("the late heal landed a file the app had unlinked")
	}
	if !hlTombstoned(h) {
		t.Error("the app's tombstone was taken back")
	}
	hlNoTemp(t, h.under)
}

// RF-002: the tombstone check, the rename and the tombstone run under landMu, the lock mediaRoot.Unlink takes for
// a stub, so an unlink lands either before the heal looks or after the file is real (and unlinks that).
func TestHealLateLandsUnderTheUnlinkLock(t *testing.T) {
	h := hlSetup(t, "hal-lock")
	old := healLateRename
	t.Cleanup(func() { healLateRename = old })
	held := false
	healLateRename = func(tmp, dst string) error {
		if h.srv.landMu.TryLock() {
			h.srv.landMu.Unlock()
		} else {
			held = true
		}
		return renameNoReplace(tmp, dst)
	}
	if res := h.run("hal-lock"); res.landed != 1 {
		t.Fatalf("result %+v, want the file landed", res)
	}
	if !held {
		t.Error("the rename ran without landMu: an Unlink could tombstone the stub between the check and the rename")
	}
	if !h.srv.landMu.TryLock() {
		t.Fatal("landMu is still held after the pass")
	}
	h.srv.landMu.Unlock()
	if b, _ := os.ReadFile(filepath.Join(h.dc, lateLandedName)); string(b) != h.rel+"\n" {
		t.Errorf(".landed %q, want the landed rel", b)
	}

	src, err := os.ReadFile("mediafs.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	i := strings.Index(body, "func (r *mediaRoot) Unlink(")
	if i < 0 {
		t.Fatal("mediaRoot.Unlink not found")
	}
	body = body[i:]
	if j := strings.Index(body, "\n}\n"); j > 0 {
		body = body[:j]
	}
	lk, chk := strings.Index(body, "r.srv.landMu.Lock()"), strings.Index(body, "r.srv.isDeleted(")
	if lk < 0 || chk < 0 || lk > chk {
		t.Error("mediaRoot.Unlink must take r.srv.landMu before its tombstone check")
	}
}
