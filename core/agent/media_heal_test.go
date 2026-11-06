package main

// NWP-20260923-02: the vault and #de stop deferring; what their heads still carry deferred is fetched at sign-in
// (media_heal.go). These tests pin the gate, the heal's per-file rules, and the two readers of its list.

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// preGateSeal makes the seal walk behave like a handset on an older build, whose vault and #de still defer.
// That is how a head carrying deferred entries is produced for the heal to handle.
func preGateSeal(t *testing.T) {
	t.Helper()
	old := sealScopeDefers
	sealScopeDefers = func(string) bool { return true }
	t.Cleanup(func() { sealScopeDefers = old })
}

func healTestEnv(t *testing.T) string {
	t.Helper()
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
	// One state dir for the whole test: the push's restore receipt lives there, and the heal list must sit
	// beside it, as on the phone. A second dir mid-test makes the next seal refuse for want of a receipt.
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	return state
}

func TestScopeDefersMedia(t *testing.T) {
	for _, c := range []struct {
		scope string
		want  bool
	}{
		{"p", false}, {"p#de", false},
		{"p#media", true}, {"p#apps", true}, {"p#sys", true}, {"p#keys", true},
	} {
		if got := scopeDefersMedia(c.scope); got != c.want {
			t.Errorf("scopeDefersMedia(%q) = %v, want %v", c.scope, got, c.want)
		}
	}
	for _, scope := range []string{"p#media", "p#apps"} {
		if got := healListFile(scope, "pw"); got != "" {
			t.Errorf("healListFile(%q) = %q; a scope that still defers has no heal list", scope, got)
		}
	}
	// Keyed by the profile: the state dir is shared by every sign-in of the boot, and the list is what lets a
	// seal drop a deferred entry, so another profile's -- or the other scope's -- must never be read.
	names := map[string]string{}
	for _, c := range [][2]string{{"p", "pw"}, {"p#de", "pw"}, {"q", "pw"}, {"p", "other"}} {
		f := healListFile(c[0], c[1])
		if f == "" || strings.Contains(f, c[0]) || strings.Contains(f, c[1]) {
			t.Errorf("healListFile(%q) = %q: empty, or it names the profile or the passphrase", c[0], f)
		}
		if prev, dup := names[f]; dup {
			t.Errorf("%v and %s share the list %q", c, prev, f)
		}
		names[f] = c[0] + "/" + c[1]
	}
}

// The gate itself, through the real push: a large app-private file seals essential in the vault and #de, and
// #media still defers. A test that only called scopeDefersMedia would pass with the walk ungated.
func TestVaultAndDeSealDeferNothing(t *testing.T) {
	healTestEnv(t)
	base := newHTTPStore(t)
	name, pass := "gate", "gate horse battery staple"
	createVault(base, name, pass)
	big := bytes.Repeat([]byte("GATE-BYTES--"), 4000)

	for _, scope := range []string{name, name + "#de"} {
		src := t.TempDir()
		rel := "app.maps/files/maps/region.mwm"
		os.MkdirAll(filepath.Join(src, filepath.Dir(rel)), 0o755)
		os.WriteFile(filepath.Join(src, rel), big, 0o644)
		pushProfile(base, scope, pass, src)
		if m := headManifestOf(t, base, scope, pass); len(m.Deferred) != 0 {
			t.Errorf("%s: deferred %d file(s); the vault and #de must defer nothing", scope, len(m.Deferred))
		}
	}
	src := t.TempDir()
	rel := "Download/movie.mp4"
	os.MkdirAll(filepath.Join(src, "Download"), 0o755)
	os.WriteFile(filepath.Join(src, rel), big, 0o644)
	pushProfile(base, name+"#media", pass, src)
	if m := headManifestOf(t, base, name+"#media", pass); len(m.Deferred[rel].Chunks) == 0 {
		t.Errorf("#media no longer defers %s -- the gate must reach the vault and #de only", rel)
	}
}

// preGateHead seals one large file into the vault the way an older handset did, and returns its manifest.
func preGateHead(t *testing.T, base, name, pass, rel string, data []byte, mode os.FileMode, mt time.Time) chunkManifest {
	t.Helper()
	preGateSeal(t)
	src := t.TempDir()
	os.MkdirAll(filepath.Join(src, filepath.Dir(rel)), 0o755)
	os.MkdirAll(filepath.Join(src, "app.other"), 0o755)
	os.WriteFile(filepath.Join(src, "app.other/note.txt"), []byte("essential"), 0o644)
	if err := os.WriteFile(filepath.Join(src, rel), data, mode); err != nil {
		t.Fatal(err)
	}
	os.Chmod(filepath.Join(src, rel), mode)
	os.Chtimes(filepath.Join(src, rel), mt, mt)
	pushProfile(base, name, pass, src)
	m := headManifest(t, base, resolveDK(base, name, pass, nil), name, pass)
	if len(m.Deferred[rel].Chunks) == 0 {
		t.Fatal("fixture: the pre-gate seal did not defer the file")
	}
	return m
}

func TestHealWritesDeferredFileWithItsModeAndTime(t *testing.T) {
	healTestEnv(t)
	base := newHTTPStore(t)
	name, pass := "heal", "heal horse battery staple"
	createVault(base, name, pass)
	rel := "app.maps/files/maps/region.mwm"
	data := bytes.Repeat([]byte("HEAL-ME-PLEASE--"), 5000)
	mt := time.Unix(1700000000, 0)
	m := preGateHead(t, base, name, pass, rel, data, 0o640, mt)

	dest := t.TempDir()
	r := healDeferred(base, resolveDK(base, name, pass, nil), m, dest)
	if r.fetched != 1 || r.unfetched != 0 || len(r.handledRels) != 1 || r.handledRels[0] != rel {
		t.Fatalf("result %+v, want one fetched and handled", r)
	}
	target := filepath.Join(dest, rel)
	got, err := os.ReadFile(target)
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("healed bytes differ (%d vs %d, %v)", len(got), len(data), err)
	}
	fi, _ := os.Stat(target)
	if fi.Mode().Perm() != 0o640 {
		t.Errorf("mode %v, want the recorded 0640", fi.Mode().Perm())
	}
	if !fi.ModTime().Equal(mt) {
		t.Errorf("mtime %v, want the recorded %v (a moved mtime re-uploads the whole file)", fi.ModTime(), mt)
	}
	if left, _ := filepath.Glob(filepath.Join(filepath.Dir(target), ".*.nowhere-heal")); len(left) != 0 {
		t.Errorf("temporary file left behind: %v", left)
	}
}

func TestHealLeavesWhatItCannotFetch(t *testing.T) {
	healTestEnv(t)
	base := newHTTPStore(t)
	name, pass := "healfail", "healfail horse battery staple"
	createVault(base, name, pass)
	rel := "app.maps/files/maps/region.mwm"
	m := preGateHead(t, base, name, pass, rel, bytes.Repeat([]byte("NOPE"), 20000), 0o644, time.Unix(1700000000, 0))
	dk := resolveDK(base, name, pass, nil)

	t.Run("a chunk that will not fetch", func(t *testing.T) {
		old := healFetchChunk
		calls := 0
		healFetchChunk = func(base string, key []byte, v int, h string) ([]byte, error) {
			calls++
			if calls >= 1 { // every chunk: the file may be a single one
				return nil, errors.New("damaged chunk")
			}
			return old(base, key, v, h)
		}
		t.Cleanup(func() { healFetchChunk = old })
		dest := t.TempDir()
		r := healDeferred(base, dk, m, dest)
		if r.fetched != 0 || r.unfetched != 1 || r.reasons["fetch"] != 1 || len(r.handledRels) != 0 {
			t.Fatalf("result %+v, want one left deferred for fetch, none handled", r)
		}
		if _, err := os.Lstat(filepath.Join(dest, rel)); err == nil {
			t.Error("a partial file was left at the target -- the next seal would seal it over the stored copy")
		}
		if left, _ := filepath.Glob(filepath.Join(dest, filepath.Dir(rel), ".*.nowhere-heal")); len(left) != 0 {
			t.Errorf("temporary file left behind: %v", left)
		}
	})
	t.Run("a chunk that comes back short", func(t *testing.T) {
		old := healFetchChunk
		healFetchChunk = func(base string, key []byte, v int, h string) ([]byte, error) {
			b, err := old(base, key, v, h)
			if len(b) > 1 {
				b = b[:len(b)-1]
			}
			return b, err
		}
		t.Cleanup(func() { healFetchChunk = old })
		dest := t.TempDir()
		r := healDeferred(base, dk, m, dest)
		if r.reasons["fetch"] != 1 || r.fetched != 0 {
			t.Fatalf("result %+v, want a short reassembly refused", r)
		}
		if _, err := os.Lstat(filepath.Join(dest, rel)); err == nil {
			t.Error("a short copy reached the target -- the next seal would seal it over the stored bytes")
		}
	})
	t.Run("a chunk fetch that panics", func(t *testing.T) {
		old := healFetchChunk
		healFetchChunk = func(string, []byte, int, string) ([]byte, error) { panic("getChunk: store down") }
		t.Cleanup(func() { healFetchChunk = old })
		r := healDeferred(base, dk, m, t.TempDir())
		if r.reasons["fetch"] != 1 {
			t.Fatalf("result %+v, want the panic contained as one fetch failure", r)
		}
	})
	t.Run("past the deadline", func(t *testing.T) {
		t.Setenv("NOWHERE_HEAL_DEADLINE_S", "0")
		old := healFetchChunk
		fetched := 0
		healFetchChunk = func(base string, key []byte, v int, h string) ([]byte, error) {
			fetched++
			return old(base, key, v, h)
		}
		t.Cleanup(func() { healFetchChunk = old })
		r := healDeferred(base, dk, m, t.TempDir())
		if r.reasons["deadline"] != 1 || r.fetched != 0 {
			t.Fatalf("result %+v, want it left for the deadline", r)
		}
		if fetched != 0 {
			t.Errorf("%d chunk(s) fetched past the deadline; a file must not even start", fetched)
		}
	})
	t.Run("short of space", func(t *testing.T) {
		old := healFreeBytes
		healFreeBytes = func(string) (int64, error) { return 2 << 30, nil }
		t.Cleanup(func() { healFreeBytes = old })
		t.Setenv("NOWHERE_HEAL_RESERVE", "3221225472") // 3 GiB reserve > 2 GiB free
		r := healDeferred(base, dk, m, t.TempDir())
		if r.reasons["space"] != 1 || r.fetched != 0 {
			t.Fatalf("result %+v, want it left for space", r)
		}
	})
}

func TestHealSkipsWhatIsAlreadyThere(t *testing.T) {
	healTestEnv(t)
	base := newHTTPStore(t)
	name, pass := "healthere", "healthere horse battery staple"
	createVault(base, name, pass)
	rel := "app.maps/files/maps/region.mwm"
	m := preGateHead(t, base, name, pass, rel, bytes.Repeat([]byte("THERE"), 20000), 0o644, time.Unix(1700000000, 0))
	dk := resolveDK(base, name, pass, nil)

	dest := t.TempDir()
	os.MkdirAll(filepath.Join(dest, filepath.Dir(rel)), 0o755)
	os.WriteFile(filepath.Join(dest, rel), []byte("the phone's own copy"), 0o644)
	r := healDeferred(base, dk, m, dest)
	if r.present != 1 || r.fetched != 0 || len(r.handledRels) != 1 {
		t.Fatalf("result %+v, want present and handled", r)
	}
	if b, _ := os.ReadFile(filepath.Join(dest, rel)); string(b) != "the phone's own copy" {
		t.Error("the heal overwrote a file that was already on the phone")
	}

	dest = t.TempDir()
	// The hold holds the deferred file's own bytes (size and recorded mtime match, as the heal stamps them).
	hold := filepath.Join(dest, filepath.FromSlash(odHoldRelFor(rel)))
	os.MkdirAll(filepath.Dir(hold), 0o755)
	d := m.Deferred[rel]
	os.WriteFile(hold, bytes.Repeat([]byte("p"), int(d.Size)), 0o644)
	mt := time.Unix(0, deferredMTimeNanos(d.MTime))
	os.Chtimes(hold, mt, mt)
	r = healDeferred(base, dk, m, dest)
	if r.held != 1 || r.fetched != 0 || len(r.handledRels) != 1 {
		t.Fatalf("result %+v, want held and handled", r)
	}
	if _, err := os.Lstat(filepath.Join(dest, rel)); err == nil {
		t.Error("the heal fetched a file the on-demand hold already holds")
	}

	// A hold copy that is NOT this file's bytes is an older one (a stranded pre-NWP-20260922-09 hold, or a
	// rollback to one). It must not count as held: the newer deferred copy is fetched into the canonical path
	// for hold_ondemand's newest-wins merge, and the stale hold is left alone.
	for name, stale := range map[string]func(){
		"another size": func() { os.WriteFile(hold, []byte("an older, shorter copy"), 0o644); os.Chtimes(hold, mt, mt) },
		"another mtime": func() {
			os.WriteFile(hold, bytes.Repeat([]byte("p"), int(d.Size)), 0o644)
			os.Chtimes(hold, mt.Add(-time.Hour), mt.Add(-time.Hour))
		},
	} {
		os.Remove(filepath.Join(dest, rel))
		stale()
		before, _ := os.ReadFile(hold)
		r = healDeferred(base, dk, m, dest)
		if r.held != 0 || r.fetched != 1 {
			t.Errorf("%s: result %+v, want the newer copy fetched, not counted held", name, r)
		}
		if after, _ := os.ReadFile(hold); !bytes.Equal(before, after) {
			t.Errorf("%s: the heal changed the hold; hold_ondemand's merge is what decides between them", name)
		}
	}
}

func TestHealRefusesUnsafePathsAndLinks(t *testing.T) {
	healTestEnv(t)
	base := newHTTPStore(t)
	name, pass := "healsafe", "healsafe horse battery staple"
	createVault(base, name, pass)
	rel := "app.maps/files/maps/region.mwm"
	m := preGateHead(t, base, name, pass, rel, bytes.Repeat([]byte("SAFE"), 20000), 0o644, time.Unix(1700000000, 0))
	dk := resolveDK(base, name, pass, nil)

	outside := t.TempDir()
	dest := t.TempDir()
	esc := m
	esc.Deferred = map[string]deferredFile{"../escape.bin": m.Deferred[rel]}
	if r := healDeferred(base, dk, esc, dest); r.reasons["unsafe path"] != 1 {
		t.Errorf("an escaping rel was not refused: %+v", r)
	}

	// A link squatting on the path must never carry a root write out of the restore root.
	os.MkdirAll(filepath.Join(dest, "app.maps"), 0o755)
	if err := os.Symlink(outside, filepath.Join(dest, "app.maps/files")); err != nil {
		t.Skip("symlinks unavailable:", err)
	}
	r := healDeferred(base, dk, m, dest)
	if r.fetched != 0 || r.reasons["fetch"] != 1 {
		t.Errorf("result %+v, want the write refused", r)
	}
	if ents, _ := os.ReadDir(outside); len(ents) != 0 {
		t.Errorf("the heal wrote through a link into %s", outside)
	}
}

// The carry, both ways. With the process-wide switch off, a vault head's deferred entry that this session did
// not handle is still carried (the heal could not fetch it); one it did handle and that is now absent was
// deleted, and is not.
func TestVaultCarryKeepsUnhandledDropsHandled(t *testing.T) {
	state := healTestEnv(t)
	base := newHTTPStore(t)
	name, pass := "carry", "carry horse battery staple"
	createVault(base, name, pass)
	dk := resolveDK(base, name, pass, nil)

	preGateSeal(t)
	src := t.TempDir()
	keep, gone := "app.a/files/keep.bin", "app.b/files/gone.bin"
	for _, rel := range []string{keep, gone} {
		os.MkdirAll(filepath.Join(src, filepath.Dir(rel)), 0o755)
		os.WriteFile(filepath.Join(src, rel), bytes.Repeat([]byte(rel), 4000), 0o644)
	}
	os.WriteFile(filepath.Join(src, "app.a/note.txt"), []byte("v1"), 0o644)
	pushProfile(base, name, pass, src)
	if m := headManifest(t, base, dk, name, pass); len(m.Deferred) != 2 {
		t.Fatalf("fixture: %d deferred, want 2", len(m.Deferred))
	}
	sealScopeDefers = scopeDefersMedia // this build from here on

	// This session: neither file is on disk (one never fetched, one deleted after the heal fetched it).
	os.Remove(filepath.Join(src, keep))
	os.Remove(filepath.Join(src, gone))
	if err := writeHealList(state, name, pass, []string{gone}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0") // the carry must not depend on the process-wide switch
	time.Sleep(5 * time.Millisecond)
	os.WriteFile(filepath.Join(src, "app.a/note.txt"), []byte("v2 -- a real second seal"), 0o644)
	pushProfile(base, name, pass, src)

	m := headManifest(t, base, dk, name, pass)
	if _, ok := m.Deferred[keep]; !ok {
		t.Error("an entry the heal did not handle was DROPPED -- its bytes would be GC'd with nothing refusing")
	}
	if _, ok := m.Deferred[gone]; ok {
		t.Error("a handled entry that is now absent was carried -- a deletion would come back at the next sign-in")
	}
}

// A healed file is an ordinary file: the next seal of this build folds it into the essential tar.
func TestHealedFileSealsEssential(t *testing.T) {
	state := healTestEnv(t)
	base := newHTTPStore(t)
	name, pass := "fold", "fold horse battery staple"
	createVault(base, name, pass)
	rel := "app.maps/files/maps/region.mwm"
	data := bytes.Repeat([]byte("FOLD-ME-IN--"), 5000)
	m := preGateHead(t, base, name, pass, rel, data, 0o644, time.Unix(1700000000, 0))
	dk := resolveDK(base, name, pass, nil)
	sealScopeDefers = scopeDefersMedia

	dest := t.TempDir()
	os.MkdirAll(filepath.Join(dest, "app.other"), 0o755)
	os.WriteFile(filepath.Join(dest, "app.other/note.txt"), []byte("essential"), 0o644)
	r := healDeferred(base, dk, m, dest)
	writeHealList(state, name, pass, r.handledRels)
	pushProfile(base, name, pass, dest)

	m2 := headManifest(t, base, dk, name, pass)
	if len(m2.Deferred) != 0 {
		t.Fatalf("after the heal the vault still defers %d file(s)", len(m2.Deferred))
	}
	if !manifestCarries(t, base, dk, m2, rel, data) {
		t.Error("the healed file is not in the essential tar")
	}
}

// manifestCarries reports whether rel's bytes are in m's essential stream.
func manifestCarries(t *testing.T, base string, dk []byte, m chunkManifest, rel string, data []byte) bool {
	t.Helper()
	var all []byte
	for _, h := range m.Chunks {
		raw, err := unpackChunk(unseal(dk, getChunk(base, h)), m.Version)
		if err != nil {
			t.Fatal(err)
		}
		all = append(all, raw...)
	}
	return bytes.Contains(all, []byte(rel)) && bytes.Contains(all, data)
}

func TestHealListAndServeFilter(t *testing.T) {
	state := t.TempDir()
	if _, ran := readHealList(state, "p", "pw"); ran {
		t.Fatal("no list must read as: the heal did not run")
	}
	writeHealList(state, "p", "pw", nil)
	if h, ran := readHealList(state, "p", "pw"); !ran || len(h) != 0 {
		t.Fatalf("an empty list must read as: ran, handled nothing (got %v, %v)", h, ran)
	}
	writeHealList(state, "p", "pw", []string{"a/x", "b/y"})
	h, _ := readHealList(state, "p", "pw")
	if _, ran := readHealList(state, "p#de", "pw"); ran {
		t.Error("the vault's list leaked into #de")
	}
	if len(h) != 2 || !h["a/x"] || !h["b/y"] {
		t.Fatalf("round trip read %v", h)
	}
	if err := writeHealList(state, "p#media", "pw", []string{"z"}); err != nil {
		t.Fatal(err)
	}
	if ents, _ := os.ReadDir(state); len(ents) != 1 {
		t.Errorf("a #media scope wrote a heal list (%d files in the state dir); it still defers and must not", len(ents))
	}
	def := map[string]deferredFile{"a/x": {Size: 1}, "b/y": {Size: 1}, "c/z": {Size: 1}}
	if got := healServeFilter(def, h); len(got) != 1 || got["c/z"].Size != 1 {
		t.Errorf("serve filter kept %v, want only c/z", got)
	}
	if got := healServeFilter(def, nil); len(got) != 3 {
		t.Error("no list must serve everything")
	}
	clearHealList(state, "p", "pw")
	if _, ran := readHealList(state, "p", "pw"); ran {
		t.Error("clearHealList left the list")
	}
}

// The restore's heal step, per scope: the vault heals and publishes its list (empty included); a scope that
// still defers is left alone and writes nothing.
func TestRestoreHealPerScope(t *testing.T) {
	state := healTestEnv(t)
	base := newHTTPStore(t)
	name, pass := "rh", "rh horse battery staple"
	createVault(base, name, pass)
	rel := "app.maps/files/maps/region.mwm"
	data := bytes.Repeat([]byte("RESTORE-HEAL"), 5000)
	m := preGateHead(t, base, name, pass, rel, data, 0o644, time.Unix(1700000000, 0))
	dk := resolveDK(base, name, pass, nil)

	dest := t.TempDir()
	if r := restoreHeal(base, dk, m, dest, name, pass, state); r.fetched != 1 {
		t.Fatalf("vault: %+v, want the deferred file healed", r)
	}
	if h, ran := readHealList(state, name, pass); !ran || !h[rel] {
		t.Errorf("vault: the handled list is missing or lacks %s (%v, %v)", rel, h, ran)
	}

	dest = t.TempDir()
	if r := restoreHeal(base, dk, m, dest, name+"#media", pass, state); r.fetched != 0 {
		t.Errorf("#media: healed %d file(s); #media still defers and must be left alone", r.fetched)
	}
	if _, err := os.Lstat(filepath.Join(dest, rel)); err == nil {
		t.Error("#media: a deferred file was written")
	}

	clearHealList(state, name, pass)
	empty := m
	empty.Deferred = nil
	restoreHeal(base, dk, empty, t.TempDir(), name, pass, state)
	if h, ran := readHealList(state, name, pass); !ran || len(h) != 0 {
		t.Errorf("a head with nothing deferred must still publish an EMPTY list (got %v, %v)", h, ran)
	}
}

func TestMediadHealFilter(t *testing.T) {
	state := t.TempDir()
	def := map[string]deferredFile{"a/x": {Size: 1}, "c/z": {Size: 1}}
	if got := mediadHealFilter("p", "pw", state, def); len(got) != 2 {
		t.Errorf("no list: served %d, want all 2", len(got))
	}
	writeHealList(state, "p", "pw", []string{"a/x"})
	if got := mediadHealFilter("p", "pw", state, def); len(got) != 1 || got["c/z"].Size != 1 {
		t.Errorf("vault with a list: served %v, want only c/z", got)
	}
	if got := mediadHealFilter("p#media", "pw", state, def); len(got) != 2 {
		t.Errorf("#media read the vault's list: served %d, want all 2", len(got))
	}
}

// The deadline is checked per chunk, so one large file cannot carry the sign-in past the daemon's ceiling.
func TestHealStopsMidFileAtTheDeadline(t *testing.T) {
	healTestEnv(t)
	base := newHTTPStore(t)
	name, pass := "healmid", "healmid horse battery staple"
	createVault(base, name, pass)
	rel := "app.maps/files/maps/region.mwm"
	m := preGateHead(t, base, name, pass, rel, bytes.Repeat([]byte("SLOW"), 20000), 0o644, time.Unix(1700000000, 0))
	old := healFetchChunk
	healFetchChunk = func(base string, key []byte, v int, h string) ([]byte, error) {
		time.Sleep(1200 * time.Millisecond) // the file started before the deadline and a chunk lands after it
		return old(base, key, v, h)
	}
	t.Cleanup(func() { healFetchChunk = old })
	t.Setenv("NOWHERE_HEAL_DEADLINE_S", "1")
	dest := t.TempDir()
	r := healDeferred(base, resolveDK(base, name, pass, nil), m, dest)
	if r.reasons["deadline"] != 1 || r.fetched != 0 {
		t.Fatalf("result %+v, want the file stopped mid-way for the deadline", r)
	}
	if _, err := os.Lstat(filepath.Join(dest, rel)); err == nil {
		t.Error("a file stopped mid-way reached its target")
	}
}

// roamd's NOWHERE_HEAL_UNTIL is one absolute deadline for the whole sign-in; the relative test knob wins.
func TestHealUntil(t *testing.T) {
	now := time.Unix(1800000000, 0)
	t.Setenv("NOWHERE_HEAL_DEADLINE_S", "")
	t.Setenv("NOWHERE_HEAL_UNTIL", "")
	if got := healUntil(now); !got.Equal(now.Add(20 * time.Minute)) {
		t.Errorf("default %v, want 20 minutes", got.Sub(now))
	}
	t.Setenv("NOWHERE_HEAL_UNTIL", "1800000600")
	if got := healUntil(now); !got.Equal(time.Unix(1800000600, 0)) {
		t.Errorf("NOWHERE_HEAL_UNTIL ignored: %v", got)
	}
	t.Setenv("NOWHERE_HEAL_DEADLINE_S", "5")
	if got := healUntil(now); !got.Equal(now.Add(5 * time.Second)) {
		t.Errorf("NOWHERE_HEAL_DEADLINE_S ignored: %v", got)
	}
}

// A failure is logged without its path: os errors carry the full path, and an app's file names can carry an
// account name, while roam.log rides issue reports.
func TestHealErrTextHasNoPath(t *testing.T) {
	p := "/data/user/11/com.example/files/someone@example.com.db"
	for _, err := range []error{
		&os.PathError{Op: "open", Path: p, Err: os.ErrPermission},
		&os.LinkError{Op: "rename", Old: p, New: p + ".x", Err: os.ErrExist},
		errors.Join(errors.New("mkdir parent"), &os.PathError{Op: "mkdir", Path: p, Err: os.ErrPermission}),
	} {
		if s := healErrText(err); strings.Contains(s, "/data/") || strings.Contains(s, "@") {
			t.Errorf("healErrText(%v) = %q leaks the path", err, s)
		}
	}
}

// One profile's list is never read for another's: the seal's carry trusts it to drop entries.
func TestHealListIsPerProfile(t *testing.T) {
	state := t.TempDir()
	writeHealList(state, "p", "pw", []string{"app/files/x"})
	if _, ran := readHealList(state, "q", "pw"); ran {
		t.Error("profile q read profile p's heal list")
	}
	if _, ran := readHealList(state, "p", "another"); ran {
		t.Error("a different passphrase (another profile under the same name) read the list")
	}
	if h, ran := readHealList(state, "p", "pw"); !ran || !h["app/files/x"] {
		t.Error("the owner could not read its own list")
	}
}
