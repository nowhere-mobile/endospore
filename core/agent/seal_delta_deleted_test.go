package main

import (
	"net"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"
)

// NWP-20261126-06 (h56 #6, option 2): the deletion half of case (3) of "Your data's save copy says the wrong thing
// in four cases". The walk is stat-only, so a file that is gone was counted nowhere: a 169 MB deletion read "No new
// changes since the last save." A listed file (the #media head's Deferred and Ess rels, the vault and #de scan
// caches) that the walk does not meet and a stat confirms absent now counts as deleted.

const sddMiB2 = 2 << 20

// sddWalk runs the walk with a since far in the future, so rule B is quiet.
func sddWalk(roots, unders map[string]string, idx map[string]sealDeltaIdxEnt, listed map[string]int64) sealDeltaWalkOut {
	return sealDeltaWalk(roots, unders, idx, listed, time.Now().Add(time.Hour).Unix())
}

func sddWantDeleted(t *testing.T, out sealDeltaWalkOut, bytes, files int64) {
	t.Helper()
	if out.DeletedBytes != bytes || out.DeletedFiles != files {
		t.Errorf("deleted = %d bytes / %d files, want %d/%d", out.DeletedBytes, out.DeletedFiles, bytes, files)
	}
}

// (a) a #media Ess-listed file that is gone counts with its listed size.
func TestSealDeltaDeletedMediaEssListedCounts(t *testing.T) {
	root := t.TempDir()
	writeAged(t, filepath.Join(root, "DCIM", "kept.jpg"), 100, time.Now().Add(-time.Hour))
	listed := map[string]int64{
		sealDeltaIdxKey("media", "DCIM/a.jpg"):    4096,
		sealDeltaIdxKey("media", "DCIM/kept.jpg"): 100,
	}
	sddWantDeleted(t, sddWalk(map[string]string{"media": root}, nil, nil, listed), 4096, 1)
}

// (a2) the production input: every #media head-Deferred rel is in BOTH sealdelta.idx and sealdelta.listed. A stub
// the overlay shows does not count; a Deferred rel outside every live overlay never counts (a stub and a deleted
// file look the same there); a Deferred rel under a live overlay that a stat confirms gone counts.
func TestSealDeltaDeletedMediaDeferredUnderOverlay(t *testing.T) {
	root := t.TempDir()
	backing := t.TempDir() // the .under: empty, the stubs were never downloaded
	overlaid := filepath.Join(root, "Movies")
	writeAged(t, filepath.Join(overlaid, "stub.mkv"), 9000, time.Now().Add(-time.Hour)) // what the overlay shows
	keys := map[string]int64{"Movies/stub.mkv": 9000, "Movies/gone.mkv": 7000, "Music/outside.flac": 3000}
	idx := map[string]sealDeltaIdxEnt{}
	listed := map[string]int64{}
	for rel, size := range keys {
		idx[sealDeltaIdxKey("media", rel)] = sealDeltaIdxEnt{size: size, mtime: 1}
		listed[sealDeltaIdxKey("media", rel)] = size
	}
	out := sddWalk(map[string]string{"media": root}, map[string]string{overlaid: backing}, idx, listed)
	sddWantDeleted(t, out, 7000, 1)
}

// (b) a vault scan-cache file of 2 MiB that is gone counts.
func TestSealDeltaDeletedVaultScanCacheCounts(t *testing.T) {
	root := t.TempDir()
	listed := map[string]int64{sealDeltaIdxKey("vault", "app.x/big.db"): sddMiB2}
	sddWantDeleted(t, sddWalk(map[string]string{"vault": root}, nil, nil, listed), sddMiB2, 1)
}

// (c) a small file is in no list, so its deletion is not counted.
func TestSealDeltaDeletedSmallUnlistedNotCounted(t *testing.T) {
	root := t.TempDir()
	writeAged(t, filepath.Join(root, "app.x", "small.xml"), 100, time.Now().Add(-time.Hour))
	sddWantDeleted(t, sddWalk(map[string]string{"vault": root}, nil, nil, map[string]int64{}), 0, 0)
}

// (e) a listed file on disk is not counted, nor is a listed rel that is now a directory.
func TestSealDeltaDeletedPresentNotCounted(t *testing.T) {
	root := t.TempDir()
	writeAged(t, filepath.Join(root, "app.x", "big.db"), 10, time.Now().Add(-time.Hour))
	if err := os.MkdirAll(filepath.Join(root, "app.x", "nowadir"), 0o755); err != nil {
		t.Fatal(err)
	}
	listed := map[string]int64{
		sealDeltaIdxKey("vault", "app.x/big.db"):  sddMiB2,
		sealDeltaIdxKey("vault", "app.x/nowadir"): sddMiB2,
	}
	sddWantDeleted(t, sddWalk(map[string]string{"vault": root}, nil, nil, listed), 0, 0)
}

// (f) a listed file under a dir the walk could not read is not known gone.
func TestSealDeltaDeletedUnderBlindDirNotCounted(t *testing.T) {
	// An overlay whose backing dir does not exist: ReadDir fails whatever the uid.
	root := t.TempDir()
	overlaid := filepath.Join(root, "Movies")
	if err := os.MkdirAll(overlaid, 0o755); err != nil {
		t.Fatal(err)
	}
	listed := map[string]int64{sealDeltaIdxKey("media", "Movies/x.mkv"): sddMiB2}
	out := sddWalk(map[string]string{"media": root}, map[string]string{overlaid: filepath.Join(root, "no-such-under")}, nil, listed)
	sddWantDeleted(t, out, 0, 0)
	if out.Blind < 1 {
		t.Errorf("blind = %d, want at least 1", out.Blind)
	}

	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Log("the chmod-000 case needs a non-root uid on a unix")
		return
	}
	vroot := t.TempDir()
	locked := filepath.Join(vroot, "app.c", "locked")
	if err := os.MkdirAll(locked, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(locked, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(locked, 0o755) })
	vout := sddWalk(map[string]string{"vault": vroot}, nil, nil, map[string]int64{sealDeltaIdxKey("vault", "app.c/locked/x.bin"): sddMiB2})
	sddWantDeleted(t, vout, 0, 0)
	if vout.Blind < 1 {
		t.Errorf("blind = %d, want at least 1", vout.Blind)
	}
}

// One key in both maps, under a live overlay, gone from both paths: both loops reach it, it counts once.
func TestSealDeltaDeletedCountedOnce(t *testing.T) {
	root := t.TempDir()
	overlaid := filepath.Join(root, "Movies")
	if err := os.MkdirAll(overlaid, 0o755); err != nil {
		t.Fatal(err)
	}
	k := sealDeltaIdxKey("media", "Movies/gone.mkv")
	out := sddWalk(map[string]string{"media": root}, map[string]string{overlaid: t.TempDir()},
		map[string]sealDeltaIdxEnt{k: {size: 5000, mtime: 1}}, map[string]int64{k: 5000})
	sddWantDeleted(t, out, 5000, 1)
}

// (g) the fields that predate the deletion pass keep their values with a listed map.
func TestSealDeltaDeletedOldFieldsUnchanged(t *testing.T) {
	root := t.TempDir()
	since := time.Now().Add(-10 * time.Minute)
	old := since.Add(-time.Hour)
	fresh := since.Add(time.Minute)
	writeAged(t, filepath.Join(root, "app.a", "old.bin"), 100, old)
	writeAged(t, filepath.Join(root, "app.a", "new.bin"), 200, fresh)
	writeAged(t, filepath.Join(root, "app.b", "same.map"), 300, old)
	writeAged(t, filepath.Join(root, "app.b", "grown.map"), 400, old)
	writeAged(t, filepath.Join(root, ".nowhere-media", "cache.bin"), 500, fresh)
	idx := map[string]sealDeltaIdxEnt{
		sealDeltaIdxKey("vault", "app.b/same.map"):  {size: 300, mtime: old.Unix()},
		sealDeltaIdxKey("vault", "app.b/grown.map"): {size: 999, mtime: old.Unix()},
		sealDeltaIdxKey("vault", "app.b/gone.map"):  {size: 50, mtime: old.Unix()},
	}
	listed := map[string]int64{
		sealDeltaIdxKey("vault", "app.a/new.bin"):    200,
		sealDeltaIdxKey("vault", "app.a/gone.bin"):   sddMiB2,
		sealDeltaIdxKey(sealDeltaNoCacheScope, "de"): 0,
	}
	roots := map[string]string{"vault": root}
	a := sealDeltaWalk(roots, nil, idx, nil, since.Unix())
	b := sealDeltaWalk(roots, nil, idx, listed, since.Unix())
	if b.DeletedFiles != 1 || b.DeletedBytes != sddMiB2 {
		t.Errorf("deleted = %d bytes / %d files, want %d/1", b.DeletedBytes, b.DeletedFiles, sddMiB2)
	}
	b.DeletedBytes, b.DeletedFiles, b.DeletedUnknown = a.DeletedBytes, a.DeletedFiles, a.DeletedUnknown
	if !reflect.DeepEqual(a, b) {
		t.Errorf("pre-change fields moved: without listed %+v, with listed %+v", a, b)
	}
	if a.ChangedBytes != 200 || a.DeferredBytes != 400 || a.Blind != 0 {
		t.Errorf("baseline walk = %+v, want changed 200, deferred 400, blind 0", a)
	}
}

// A #nocache scope is reported as unknown, never as zero deletions.
func TestSealDeltaDeletedNoCacheScopesReported(t *testing.T) {
	listed := map[string]int64{
		sealDeltaIdxKey(sealDeltaNoCacheScope, "vault"): 0,
		sealDeltaIdxKey(sealDeltaNoCacheScope, "de"):    0,
	}
	out := sddWalk(map[string]string{"vault": t.TempDir(), "de": t.TempDir()}, nil, nil, listed)
	sddWantDeleted(t, out, 0, 0)
	if !reflect.DeepEqual(out.DeletedUnknown, []string{"de", "vault"}) {
		t.Errorf("deletedUnknown = %q, want [de vault]", out.DeletedUnknown)
	}
}

func TestSealDeltaListedFileRoundTrip(t *testing.T) {
	p := sealDeltaListedPath(t.TempDir())
	listed := map[string]map[string]int64{"media": {"DCIM/a b.jpg": 4096}, "vault": {"app.x/big.db": sddMiB2}}
	if err := writeSealDeltaListed(p, listed, []string{"de"}); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Errorf("mode %v, want 0600", fi.Mode().Perm())
	}
	if _, err := os.Stat(p + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("the temp file was left behind: %v", err)
	}
	f, err := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString("vault\tbad\tnotanumber\nonefield\n")
	f.Close()
	want := map[string]int64{
		sealDeltaIdxKey("media", "DCIM/a b.jpg"):     4096,
		sealDeltaIdxKey("vault", "app.x/big.db"):     sddMiB2,
		sealDeltaIdxKey(sealDeltaNoCacheScope, "de"): 0,
	}
	if got := readSealDeltaListed(p); !reflect.DeepEqual(got, want) {
		t.Errorf("read back %q, want %q", got, want)
	}
}

// ---- the daemon's writer, through handleSealDeltaWalk and a fake head ----

// sddVaultSession seals a bare vault holding one 2 MiB file with the worker's NOWHERE_BLOBCACHE=dest, so the
// seal writes scancache.<tag> into dest, then empties NOWHERE_BLOBCACHE as the daemon's environment has it.
func sddVaultSession(t *testing.T, name string) (dest string) {
	t.Helper()
	sdbGlobals(t)
	dest = sdbSession(t, name)
	pass := "a passphrase for " + name
	if createVault(sealDeltaBase, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "app.x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "app.x", "big.db"), prBytes(sddMiB2), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_BLOBCACHE", dest)
	sealRefused = false
	pushProfile(sealDeltaBase, name, pass, src)
	pushFenceSeq, pushFenceSampled = 0, false // see rotateFixture
	if sealRefused {
		t.Fatal("the vault seal was refused")
	}
	t.Setenv("NOWHERE_BLOBCACHE", "")
	return dest
}

// sddRunWalk drives the handler with a fake worker and returns sealdelta.listed's lines.
func sddRunWalk(t *testing.T, dest string) []string {
	t.Helper()
	stop := sdbWorker(t, dest, `{"v":1}`)
	got := ropReply(t, func(c net.Conn) { handleSealDeltaWalk(c, dest) })
	stop()
	if !strings.HasPrefix(got, "OK ") {
		t.Fatalf("reply %q, want an OK frame", got)
	}
	b, err := os.ReadFile(sealDeltaListedPath(dest))
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimRight(string(b), "\n"), "\n")
}

func sddHas(lines []string, want string) bool {
	for _, l := range lines {
		if l == want {
			return true
		}
	}
	return false
}

func sddHasPrefix(lines []string, pre string) bool {
	for _, l := range lines {
		if strings.HasPrefix(l, pre) {
			return true
		}
	}
	return false
}

// (b-h) P2 end to end: the tag the seal wrote is the tag the daemon computes, and a landed seal's cache is read.
func TestSealDeltaListedVaultCacheFromALandedSeal(t *testing.T) {
	dest := sddVaultSession(t, "sdd-bh")
	now := time.Now().Unix() - 60
	lastSealStartedAt.Store(now)
	lastLandedSealStartedAt.Store(now)
	lines := sddRunWalk(t, dest)
	if !sddHas(lines, "vault\tapp.x/big.db\t2097152") {
		t.Errorf("sealdelta.listed = %q, want the line vault\\tapp.x/big.db\\t2097152", lines)
	}
	if sddHas(lines, "#nocache\tvault") {
		t.Errorf("sealdelta.listed = %q: the landed seal's vault cache was not read", lines)
	}
	if !sddHas(lines, "#nocache\tde") {
		t.Errorf("sealdelta.listed = %q, want #nocache\\tde (no #de head)", lines)
	}
}

// (d) a seal was dispatched after the last landed one: its cache is not read.
func TestSealDeltaListedCacheOfAnUnlandedSealNotRead(t *testing.T) {
	dest := sddVaultSession(t, "sdd-d")
	now := time.Now().Unix() - 60
	lastLandedSealStartedAt.Store(now)
	lastSealStartedAt.Store(now + 5)
	lines := sddRunWalk(t, dest)
	if sddHasPrefix(lines, "vault\t") {
		t.Errorf("sealdelta.listed = %q: the cache of an unlanded seal was read", lines)
	}
	if !sddHas(lines, "#nocache\tvault") {
		t.Errorf("sealdelta.listed = %q, want #nocache\\tvault", lines)
	}
}

// (d2) a cache older than the landed seal came from an older seal: not read.
func TestSealDeltaListedOldCacheNotRead(t *testing.T) {
	dest := sddVaultSession(t, "sdd-d2")
	now := time.Now().Unix() - 60
	lastSealStartedAt.Store(now)
	lastLandedSealStartedAt.Store(now)
	matches, _ := filepath.Glob(filepath.Join(dest, "scancache.*"))
	if len(matches) == 0 {
		t.Fatal("the seal wrote no scancache into dest")
	}
	hourAgo := time.Unix(now, 0).Add(-time.Hour)
	for _, m := range matches {
		if err := os.Chtimes(m, hourAgo, hourAgo); err != nil {
			t.Fatal(err)
		}
	}
	lines := sddRunWalk(t, dest)
	if sddHasPrefix(lines, "vault\t") || !sddHas(lines, "#nocache\tvault") {
		t.Errorf("sealdelta.listed = %q, want no vault line and #nocache\\tvault", lines)
	}
}

// (a-h) a #media head with Ess and NO Deferred (the normal head under the essential-media carry) lists its Ess rel.
func TestSealDeltaListedMediaHeadEssAndDeferred(t *testing.T) {
	sdbGlobals(t)
	name := "sdd-ah"
	dest := sdbSession(t, name)
	pass := "a passphrase for " + name
	if createVault(sealDeltaBase, name, pass) == "" { // a scope head is created only beside a bare one
		t.Fatal("createVault returned no recovery code")
	}
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	essentialMediaEnv(t)
	d := t.TempDir()
	if err := os.MkdirAll(filepath.Join(d, "DCIM"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, "DCIM", "sdd-small.jpg"), prBytes(5000), 0o600); err != nil {
		t.Fatal(err)
	}
	sealRefused = false
	pushProfile(sealDeltaBase, name+"#media", pass, d)
	pushFenceSeq, pushFenceSampled = 0, false // see rotateFixture
	if sealRefused {
		t.Fatal("the #media seal was refused")
	}
	m := headManifestOf(t, sealDeltaBase, name+"#media", pass)
	if len(m.Deferred) != 0 || m.Ess["DCIM/sdd-small.jpg"].Size != 5000 {
		t.Fatalf("fixture: Deferred %d, Ess %+v; want no Deferred and one 5000-byte Ess rel", len(m.Deferred), m.Ess)
	}
	now := time.Now().Unix() - 60
	lastSealStartedAt.Store(now)
	lastLandedSealStartedAt.Store(now)
	lines := sddRunWalk(t, dest)
	if !sddHas(lines, "media\tDCIM/sdd-small.jpg\t5000") {
		t.Errorf("sealdelta.listed = %q, want the line media\\tDCIM/sdd-small.jpg\\t5000", lines)
	}
	idx, err := os.ReadFile(sealDeltaIdxPath(dest))
	if err != nil {
		t.Fatal(err)
	}
	if sddHasPrefix(strings.Split(string(idx), "\n"), "media\t") {
		t.Errorf("sealdelta.idx = %q, want no media line (the head has no Deferred)", idx)
	}
}
