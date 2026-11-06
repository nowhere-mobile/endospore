package main

// NWP-20260908-02: THE OWNER OF A FILE MUST NOT DECIDE ITS CONTENT ADDRESS.
//
// tar.FileInfoHeader fills Uid/Gid/Uname/Gname from the local stat, and roamd chowns the #media essential
// tier to `uid*100000+appid` at every login (nowhere_roamd.sh, reown_ext_appdata). The roamed user id is new
// on every login and differs between handsets, so the same file -- byte-identical on disk, same mtime, same
// mode -- sealed to DIFFERENT chunks depending on which phone and which session tarred it.
//
// That broke two things at once. docs/multi-device.md promises "dedup across lineages is automatic:
// identical bytes -> identical chunks -> billed once", which was false for everything under
// Android/data|obb; and it made a shared #media head unconvergeable in principle, because two handsets could
// not agree on the CHUNKS however well the rest of the machinery worked.
//
// Nothing ever read the fields back: untarFrom restores mode and mtime and never chowns, and roamd
// re-establishes ownership afterwards from THIS device's ids -- the only correct source, since the sealing
// device's are meaningless here.

import (
	"archive/tar"
	"bytes"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// ownedAs presents a real file as though a different user owned it -- the same file seen from two handsets.
type ownedAs struct {
	os.FileInfo
	uid, gid uint32
}

func (o ownedAs) Sys() any {
	st := *(o.FileInfo.Sys().(*syscall.Stat_t))
	st.Uid, st.Gid = o.uid, o.gid
	return &st
}

// tarOneEntry runs the real seal writer over one file and returns the bytes it would chunk.
func tarOneEntry(t *testing.T, p string, fi os.FileInfo, rel string) []byte {
	t.Helper()
	var b bytes.Buffer
	tw := tar.NewWriter(&b)
	if err := writeTarEntry(tw, p, fi, rel); err != nil {
		t.Fatalf("writeTarEntry: %v", err)
	}
	if err := tw.Flush(); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func ownedFixture(t *testing.T) (path string, fi os.FileInfo) {
	t.Helper()
	d := t.TempDir()
	p := filepath.Join(d, "photo.jpg")
	if err := os.WriteFile(p, []byte("identical bytes on both handsets"), 0o644); err != nil {
		t.Fatal(err)
	}
	mt := time.Unix(1750000000, 0)
	if err := os.Chtimes(p, mt, mt); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	return p, info
}

// THE PROPERTY. Two handsets, two roamed user ids, one file -> one set of bytes to chunk.
func TestTarEntryIsIdenticalAcrossHandsets(t *testing.T) {
	p, fi := ownedFixture(t)
	rel := "Android/data/app.pkg/files/photo.jpg" // the tree roamd re-owns per user

	// user 10 and user 11: appId 176, so uid = user*100000+176.
	a := tarOneEntry(t, p, ownedAs{fi, 10*100000 + 176, 10*100000 + 176}, rel)
	b := tarOneEntry(t, p, ownedAs{fi, 11*100000 + 176, 11*100000 + 176}, rel)

	if !bytes.Equal(a, b) {
		n := 0
		for i := range a {
			if i < len(b) && a[i] != b[i] {
				n++
			}
		}
		t.Fatalf("the same file tars differently for two users: %d byte(s) differ. Every such file gets a "+
			"different content address on each handset, so it is re-uploaded, re-billed, and the two can "+
			"never converge on a shared #media head.", n)
	}
}

// AND ACROSS SESSIONS ON ONE HANDSET -- the amnesiac model mints a new user on every login, so this is the
// case that costs an upload even with a single phone.
func TestTarEntryIsIdenticalAcrossLoginsOnOneHandset(t *testing.T) {
	p, fi := ownedFixture(t)
	rel := "Android/data/app.pkg/files/photo.jpg"
	first := tarOneEntry(t, p, ownedAs{fi, 12*100000 + 176, 12*100000 + 176}, rel)
	second := tarOneEntry(t, p, ownedAs{fi, 13*100000 + 176, 13*100000 + 176}, rel)
	if !bytes.Equal(first, second) {
		t.Fatal("the same file tars differently after a re-login -- every external app-data file re-chunks " +
			"and re-uploads on every login")
	}
}

// A uid above 2097151 does not fit a ustar octal field, so Go escalates the entry to PAX: a DIFFERENT header
// shape for the same file, decided by how many times someone logged in. User 21 reaches that. Normalising
// removes the switch entirely, and this pins it -- the failure would otherwise look like an unrelated
// format change months from now.
func TestTarEntrySurvivesAUidTooLargeForUstar(t *testing.T) {
	p, fi := ownedFixture(t)
	rel := "Android/data/app.pkg/files/photo.jpg"
	small := tarOneEntry(t, p, ownedAs{fi, 1023, 1023}, rel)
	huge := tarOneEntry(t, p, ownedAs{fi, 21*100000 + 176, 21*100000 + 176}, rel) // 2_100_176 > 2097151
	if !bytes.Equal(small, huge) {
		t.Fatalf("a uid that overflows ustar changes the entry (%d vs %d bytes) -- the header FORMAT now "+
			"depends on the login count", len(small), len(huge))
	}
}

// THE FIELDS ARE ACTUALLY GONE, not merely equal by luck. Read the entry back and check the header.
func TestTarEntryCarriesNoOwnership(t *testing.T) {
	p, fi := ownedFixture(t)
	b := tarOneEntry(t, p, ownedAs{fi, 10*100000 + 176, 999}, "DCIM/photo.jpg")
	h, err := tar.NewReader(bytes.NewReader(b)).Next()
	if err != nil {
		t.Fatalf("the emitted entry does not parse as tar: %v", err)
	}
	if h.Uid != 0 || h.Gid != 0 || h.Uname != "" || h.Gname != "" {
		t.Errorf("ownership survived into the header: uid=%d gid=%d uname=%q gname=%q", h.Uid, h.Gid, h.Uname, h.Gname)
	}
	// What a restore DOES use must be untouched.
	if h.Name != "DCIM/photo.jpg" {
		t.Errorf("name changed: %q", h.Name)
	}
	if h.Size != fi.Size() {
		t.Errorf("size changed: %d want %d", h.Size, fi.Size())
	}
	if h.Mode&0o777 != 0o644 {
		t.Errorf("mode changed: %o want 644", h.Mode&0o777)
	}
	if h.ModTime.Unix() != fi.ModTime().Unix() {
		t.Errorf("mtime changed: %d want %d -- NWP-20260829-01 depends on this surviving",
			h.ModTime.Unix(), fi.ModTime().Unix())
	}
}

// THE CHANGE MUST NOT BE INERT. The scan cache keys on (mtime,size,mode) and would otherwise hand back
// chunks sealed under the OLD header shape for every unchanged file -- forever, since nothing about the file
// changes. A version on the entry makes it miss exactly once.
func TestScanCacheRefusesChunksFromAnOlderTarFormat(t *testing.T) {
	t.Setenv("NOWHERE_BLOBCACHE", t.TempDir())
	sc := newFileScanCache([]byte("0123456789abcdef0123456789abcdef"))

	// get() also requires every chunk to be known-present in the store, so record them: the assertion under
	// test is about the FORMAT stamp, and a blob-presence miss would make it pass for the wrong reason.
	for _, h := range []string{"h1", "h2"} {
		blobCacheAdd(h)
	}
	sc.put("DCIM/a.jpg", 100, 200, 0o644, []string{"h1", "h2"})
	if got := sc.get("DCIM/a.jpg", 100, 200, 0o644); len(got) != 2 {
		t.Fatalf("a freshly written entry did not come back (%v) -- the cache is not working at all and the "+
			"assertion below would be vacuous", got)
	}

	// An entry written by an older agent: same stat, no format stamp.
	sc.mu.Lock()
	e := sc.m["DCIM/a.jpg"]
	e.Fmt = 0
	sc.m["DCIM/a.jpg"] = e
	sc.mu.Unlock()

	if got := sc.get("DCIM/a.jpg", 100, 200, 0o644); got != nil {
		t.Fatalf("the cache served chunks sealed under a previous tar format (%v). Every unchanged file "+
			"would keep its old-shape chunks forever, so the normalisation would reach nothing that "+
			"mattered.", got)
	}
}
