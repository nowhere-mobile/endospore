package main

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

// NWP-20261011-17 (docs/backlog.md, "An unreadable ESSENTIAL file keeps seen[rel] = true"). writeTarEntry skips a
// regular file it cannot open with no header and a nil error, so the essential arm of walkChunks recorded no
// range for it -- but seen[rel] stayed TRUE, and carryMediaEssentialRels then counted the file as walked and
// dropped its stored span from the new head. The deferred arm has cleared seen on a failed open since
// NWP-20260829-29; these pin the same answer on the essential side. On the code before this slice the first
// test fails on the seen assertion and the carry reports Walked == 1.
//
// The open is failed through the sealOpenFile seam, not chmod: chmod 000 does not stop root, which is what the
// CI runner is.

const unreadableRel = "DCIM/IMG_0001.jpg"

// walkOneEssential seals a src holding one regular file at or above the threshold, with the on-demand split off
// and no prior deferred records, so the file can only take the essential non-cached arm.
func walkOneEssential(t *testing.T) ([]scanRange, map[string]bool, []scanRange, int) {
	t.Helper()
	src := t.TempDir()
	iwrite(t, src, unreadableRel, bytes.Repeat([]byte("J"), 8*1024))
	next := 0
	emit := func([]byte) int { i := next; next++; return i }
	cached := func(string) int { return 0 }
	ranges, seen, deferred, _, blind, _, _, _ := walkChunks(src, newFileScanCache(make([]byte, 32)), 4096, true, false,
		nil, nil, nil, nil, 0, emit, cached, func(int64) {}, nil)
	return ranges, seen, deferred, blind
}

func rangesFor(ranges []scanRange, rel string) []scanRange {
	var out []scanRange
	for _, r := range ranges {
		if r.rel == rel {
			out = append(out, r)
		}
	}
	return out
}

func TestEssentialUnreadable_KeepsTheStoredSpan(t *testing.T) {
	sealOpenFile = func(p string) (*os.File, error) {
		if strings.HasSuffix(filepath.ToSlash(p), "/"+unreadableRel) {
			return nil, &os.PathError{Op: "open", Path: p, Err: syscall.EACCES}
		}
		return os.Open(p)
	}
	t.Cleanup(func() { sealOpenFile = os.Open })

	ranges, seen, deferred, blind := walkOneEssential(t)
	if v, ok := seen[unreadableRel]; !ok || v {
		t.Fatalf("seen[%q] = %v (present %v), want present and false: an unreadable essential file must not read as walked", unreadableRel, v, ok)
	}
	if got := rangesFor(ranges, unreadableRel); len(got) != 0 {
		t.Fatalf("recorded %d range(s) for an unreadable file, want none: %+v", len(got), got)
	}
	if len(deferred) != 0 {
		t.Fatalf("deferred = %+v, want none (od off, no prior record)", deferred)
	}
	if blind != 0 {
		t.Fatalf("blind = %d, want 0: one unreadable file whose stored copy is kept must not refuse the seal", blind)
	}

	got, st := carryMediaEssentialRels(essOf(unreadableRel), essOf("DCIM/other.jpg"), seen, nil, nil, nil, 1, nil)
	if len(got) != 1 || got[0] != unreadableRel {
		t.Fatalf("carried %v, want [%s]: the stored span must survive the unreadable seal", got, unreadableRel)
	}
	if st.Carried != 1 || st.Walked != 0 {
		t.Fatalf("stats Carried=%d Walked=%d, want 1/0", st.Carried, st.Walked)
	}
}

// The control: a file that opens is walked, records its range, and its stored span is NOT carried a second time.
func TestEssentialUnreadable_AReadableFileIsStillWalked(t *testing.T) {
	ranges, seen, deferred, blind := walkOneEssential(t)
	if !seen[unreadableRel] {
		t.Fatalf("seen[%q] = false, want true for a file that was read", unreadableRel)
	}
	got := rangesFor(ranges, unreadableRel)
	if len(got) != 1 || got[0].start < 0 || got[0].end <= got[0].start {
		t.Fatalf("ranges for %q = %+v, want exactly one non-empty range", unreadableRel, got)
	}
	if len(deferred) != 0 || blind != 0 {
		t.Fatalf("deferred=%+v blind=%d, want none/0", deferred, blind)
	}

	carried, st := carryMediaEssentialRels(essOf(unreadableRel), essOf("DCIM/other.jpg"), seen, nil, nil, nil, 1, nil)
	if len(carried) != 0 {
		t.Fatalf("carried %v, want none: a walked file's stale stored span must not be spliced over it", carried)
	}
	if st.Walked != 1 || st.Carried != 0 {
		t.Fatalf("stats Walked=%d Carried=%d, want 1/0", st.Walked, st.Carried)
	}
}

// NWP-20261025-03: the same unreadable file, but one this session RESTORED (it is in the login roster), which is
// almost every file of a #media scope. The roster arm used to count it deleted-here and publish a head without
// it. End to end: seal, log in (both files in the roster), fail one open, seal again; the head must still name
// it and a restore of that head must write its original bytes.
func TestEssentialUnreadable_ARestoredFileKeepsItsSpanInTheNewHead(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const name, pass = "essunread", "correct horse battery staple"
	base := newHTTPStore(t)
	createVault(base, name, pass)
	h := newHandset(t, base, name, pass)
	ref := profileRefV2(name+"#media", pass)

	const keepRel, lostRel = "DCIM/keep.jpg", "DCIM/unread.jpg"
	h.put(keepRel, "a photo that reads fine")
	h.put(lostRel, "a photo the next seal cannot open")
	if msg := h.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	h.as(func() { loginArrived(ref, h.head("#media")) })

	sealOpenFile = func(p string) (*os.File, error) {
		if strings.HasSuffix(filepath.ToSlash(p), "/"+lostRel) {
			return nil, &os.PathError{Op: "open", Path: p, Err: syscall.EACCES}
		}
		return os.Open(p)
	}
	t.Cleanup(func() { sealOpenFile = os.Open })
	if msg := h.seal("#media"); msg != "" {
		t.Fatalf("second seal: %s", msg)
	}

	m, dst := restoreManifest(t, base, name+"#media", pass)
	for _, rel := range []string{keepRel, lostRel} {
		if _, ok := m.Ess[rel]; !ok {
			t.Fatalf("the new head dropped %s (Ess %v): a restored file one seal could not open was counted deleted", rel, keysOfEss(m.Ess))
		}
	}
	got, err := os.ReadFile(filepath.Join(dst, filepath.FromSlash(lostRel)))
	if err != nil || string(got) != "a photo the next seal cannot open" {
		t.Fatalf("restored %s = %q (err %v), want its original bytes", lostRel, got, err)
	}
}

// NWP-20261026-01: the same race, but the file is GONE rather than unreadable. The walk stats a restored photo, the
// user deletes it, the open fails ENOENT: the carry keeps its span (the walk visited it, so it is "unread here"),
// and the post-seal sync used to write it straight back from the store because its target was absent. The head
// still keeps the span for that one cycle; the phone must not get the file back, and the next seal, which no longer
// walks it, counts it deleted-here.
func TestEssentialUnreadable_AFileDeletedMidSealIsNotWrittenBack(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const name, pass = "essvanish", "correct horse battery staple"
	base := newHTTPStore(t)
	createVault(base, name, pass)
	h := newHandset(t, base, name, pass)
	ref := profileRefV2(name+"#media", pass)

	const keepRel, lostRel = "DCIM/keep.jpg", "DCIM/vanished.jpg"
	h.put(keepRel, "a photo that reads fine")
	h.put(lostRel, "a photo deleted while the seal reads it")
	if msg := h.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	h.as(func() { loginArrived(ref, h.head("#media")) })

	hits := 0
	sealOpenFile = func(p string) (*os.File, error) {
		if strings.HasSuffix(filepath.ToSlash(p), "/"+lostRel) {
			hits++
			_ = os.Remove(p)
			return nil, &os.PathError{Op: "open", Path: p, Err: syscall.ENOENT}
		}
		return os.Open(p)
	}
	t.Cleanup(func() { sealOpenFile = os.Open })
	if msg := h.seal("#media"); msg != "" {
		t.Fatalf("second seal: %s", msg)
	}
	if hits == 0 {
		t.Fatalf("the seam never fired for %s: the test proves nothing", lostRel)
	}
	if _, err := os.Lstat(filepath.Join(h.work, filepath.FromSlash(lostRel))); !os.IsNotExist(err) {
		t.Fatalf("%s exists after the seal (err %v): the post-seal sync wrote a file the user deleted back from the store", lostRel, err)
	}
	m, _ := restoreManifest(t, base, name+"#media", pass)
	if _, ok := m.Ess[lostRel]; !ok {
		t.Fatalf("the new head dropped %s (Ess %v): its span is kept for the one cycle", lostRel, keysOfEss(m.Ess))
	}

	sealOpenFile = os.Open
	if msg := h.seal("#media"); msg != "" {
		t.Fatalf("third seal: %s", msg)
	}
	m, _ = restoreManifest(t, base, name+"#media", pass)
	if _, ok := m.Ess[lostRel]; ok {
		t.Fatalf("the head still names %s a cycle later (Ess %v): it should have fallen to the roster arm", lostRel, keysOfEss(m.Ess))
	}
	if _, ok := m.Ess[keepRel]; !ok {
		t.Fatalf("the head dropped %s (Ess %v)", keepRel, keysOfEss(m.Ess))
	}
}

func TestCarriedToLand(t *testing.T) {
	seen := map[string]bool{"a/read": true, "a/unread": false}
	in := []string{"z/new1", "a/read", "a/unread", "b/new2"}
	if got := carriedToLand(in, seen); !reflect.DeepEqual(got, []string{"z/new1", "b/new2"}) {
		t.Fatalf("carriedToLand = %v, want only the never-visited rels in input order", got)
	}
	if got := carriedToLand(in, nil); !reflect.DeepEqual(got, in) {
		t.Fatalf("nil seen: carriedToLand = %v, want every rel", got)
	}
}
