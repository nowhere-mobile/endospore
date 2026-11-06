package main

// NWP-20261128-03: the #media seal under an after-gate split (Q106 slice S3, docs/media-after-gate.md §5 and §8).
//
// Handset a seals the head a sign-in restores. Handset b is that sign-in: S2's real writer (mediaRestorePlan) writes
// the marker before the receipt and the roster, b's tree holds only what the pre-gate pass gave it plus what the
// lander placed, and the landed roster is written straight to its file (S4a writes it on a device). Every test seals
// b and reads the head back.

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const magPass = "correct horse battery staple"

// magBg are the four Q106 rels of the fixture head. Documents/pre.txt is outside Q106's list, so it stays pre-gate.
var magBg = []string{"DCIM/bg1.jpg", "DCIM/bg2.jpg", "Pictures/gone.jpg", "Pictures/kept.jpg"}

type magFix struct {
	a, b     *handset
	profile  string // name + "#media"
	ref      string // the roster's key
	atLogin  string // the head b signed in to
	old      chunkManifest
	landedDK []byte
}

// magFixture seals a's head and prepares b's tree with the pre-gate file only. It does not sign b in: each test
// calls signIn with the marker it wants.
func magFixture(t *testing.T, name string) *magFix {
	t.Helper()
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_MEDIA_AFTER_GATE", "1")
	t.Setenv("NOWHERE_SEAL_FULL", "")
	t.Setenv("NOWHERE_SEAL_FORCE", "")
	f := &magFix{profile: name + "#media"}
	f.a, f.b = twoWriters(t, name, magPass)
	f.ref = profileRefV2(f.profile, magPass)
	f.a.put("Documents/pre.txt", "a document: pre-gate")
	for i, rel := range magBg {
		f.a.putAt(rel, fmt.Sprintf("photo %d %s", i, strings.Repeat("x", 40*(i+1))), time.Unix(1700000000+int64(i)*60, 0))
	}
	if msg := f.a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	f.atLogin = f.a.head("#media")
	f.old = headManifestOf(t, f.a.base, f.profile, magPass)
	if bg, _ := bgSplit(f.old); !slices.Equal(bg, magBg) {
		t.Fatalf("the fixture head does not split as the tests need: bg=%v, want %v", bg, magBg)
	}
	f.landedDK = resolveDK(f.b.base, f.profile, magPass, nil)
	f.b.put("Documents/pre.txt", "a document: pre-gate")
	return f
}

// signIn is b's sign-in: the real S2 plan (it writes the marker when the flag is on), then the receipt and roster.
func (f *magFix) signIn(t *testing.T, plan bool) {
	t.Helper()
	f.b.as(func() {
		if plan {
			captureStdout(t, func() { mediaRestorePlan(f.profile, magPass, f.atLogin, f.old) })
			if _, err := os.Stat(aftergateFile(f.ref)); err != nil {
				t.Fatalf("mediaRestorePlan wrote no marker: %v", err)
			}
		}
		loginArrived(f.ref, f.atLogin)
	})
}

// land records rels in b's landed roster, as the lander does after each rename.
func (f *magFix) land(t *testing.T, rels ...string) {
	t.Helper()
	f.b.as(func() {
		var lines []string
		for _, rel := range rels {
			lines = append(lines, walkedDigest(f.landedDK, rel))
		}
		if err := publishReceiptFile(landedRosterFile(f.ref), []byte(strings.Join(lines, "\n")+"\n")); err != nil {
			t.Fatal(err)
		}
	})
}

// sealB seals b and returns the refusal ("" when it landed), the reason the seal named, and what it printed.
func (f *magFix) sealB(t *testing.T) (refused, why, out string) {
	t.Helper()
	out = captureStdout(t, func() { refused = f.b.seal("#media") })
	return refused, sealRefusedWhy, out
}

func (f *magFix) newHead(t *testing.T) chunkManifest {
	t.Helper()
	return headManifestOf(t, f.b.base, f.profile, magPass)
}

func (f *magFix) inWork(rel string) bool {
	_, err := os.Stat(filepath.Join(f.b.work, filepath.FromSlash(rel)))
	return err == nil
}

// mustRefuse asserts the aftergate-no-carry refusal and that neither handset sees a new head.
func (f *magFix) mustRefuse(t *testing.T) {
	t.Helper()
	refused, why, out := f.sealB(t)
	if refused == "" || why != "aftergate-no-carry" {
		t.Fatalf("seal: %s, why=%q, want REFUSED with aftergate-no-carry\n%s", outcome(refused), why, out)
	}
	if !strings.Contains(out, "SEAL REFUSED -- the #media restore was split after the gate") ||
		!strings.Contains(out, "(NWP-20261128-03)") {
		t.Errorf("no NWP-20261128-03 refusal line:\n%s", out)
	}
	if hb, ha := f.b.head("#media"), f.a.head("#media"); hb != f.atLogin || ha != f.atLogin {
		t.Errorf("the stored head moved: b sees %s, a sees %s, want %s", short(hb), short(ha), short(f.atLogin))
	}
}

func mustSeal(t *testing.T, f *magFix) chunkManifest {
	t.Helper()
	refused, why, out := f.sealB(t)
	if refused != "" {
		t.Fatalf("seal: %s (why=%q)\n%s", outcome(refused), why, out)
	}
	return f.newHead(t)
}

// T1: an unlanded background rel is carried byte for byte and left to the lander.
func TestMediaAfterGateSeal_UnlandedRelIsCarriedBySpan(t *testing.T) {
	f := magFixture(t, "magseal1")
	f.signIn(t, true)
	m := mustSeal(t, f)
	for _, rel := range []string{"DCIM/bg1.jpg", "DCIM/bg2.jpg"} {
		o, ok := f.old.Ess[rel]
		r, ok2 := m.Ess[rel]
		if !ok || !ok2 {
			t.Fatalf("%s: in the old head %v, in the new head %v -- an unlanded background file was dropped as a deletion", rel, ok, ok2)
		}
		if !slices.Equal(m.Chunks[r.S:r.E], f.old.Chunks[o.S:o.E]) {
			t.Errorf("%s: the new span is not the stored span's chunks", rel)
		}
		if r.Size != o.Size || r.Mode != o.Mode || r.MT != o.MT {
			t.Errorf("%s: region %+v, want size/mode/mtime of %+v", rel, r, o)
		}
		if f.inWork(rel) {
			t.Errorf("%s: the post-seal sync wrote an unlanded background file onto the phone -- the lander owns it", rel)
		}
	}
}

// T2: a landed rel the user deleted is dropped.
func TestMediaAfterGateSeal_LandedThenDeletedIsDropped(t *testing.T) {
	f := magFixture(t, "magseal2")
	f.signIn(t, true)
	f.land(t, "Pictures/gone.jpg")
	m := mustSeal(t, f)
	if _, ok := m.Ess["Pictures/gone.jpg"]; ok {
		t.Error("a background file that landed and was deleted came back: the deletion was not honoured")
	}
	if _, ok := m.Ess["DCIM/bg1.jpg"]; !ok {
		t.Error("an unlanded background file was dropped")
	}
}

// T3: a landed rel that is present is walked, not carried.
func TestMediaAfterGateSeal_LandedPresentIsWalked(t *testing.T) {
	f := magFixture(t, "magseal3")
	f.signIn(t, true)
	mt := time.Unix(1710000000, 0)
	f.b.putAt("Pictures/kept.jpg", "the landed photo, edited on b", mt)
	f.land(t, "Pictures/kept.jpg")
	m := mustSeal(t, f)
	r, ok := m.Ess["Pictures/kept.jpg"]
	if !ok {
		t.Fatal("a landed file on the phone is missing from the head")
	}
	if r.MT != mt.UnixNano() || r.Size != int64(len("the landed photo, edited on b")) {
		t.Errorf("Pictures/kept.jpg region %+v: want b's walked file (mtime %d), not a's carried span", r, mt.UnixNano())
	}
}

// magToday asserts today's behaviour: every rel b does not hold is dropped by the roster arm.
func magToday(t *testing.T, f *magFix) {
	t.Helper()
	refused, why, out := f.sealB(t)
	if refused != "" || why != "" {
		t.Fatalf("seal: %s, why=%q, want today's publish\n%s", outcome(refused), why, out)
	}
	m := f.newHead(t)
	var got []string
	for rel := range m.Ess {
		got = append(got, rel)
	}
	slices.Sort(got)
	if want := []string{"Documents/pre.txt"}; !slices.Equal(got, want) {
		t.Errorf("new head Ess = %v, want %v (no split: an absent restored file is a deletion, as today)", got, want)
	}
	if strings.Contains(out, "after-gate split") {
		t.Errorf("the seal took the split path:\n%s", out)
	}
}

// T4: no marker is today's behaviour.
func TestMediaAfterGateSeal_NoMarkerIsToday(t *testing.T) {
	f := magFixture(t, "magseal4")
	f.signIn(t, false)
	f.land(t, magBg...)
	magToday(t, f)
}

// T5: a marker naming an older head is today's behaviour.
func TestMediaAfterGateSeal_OlderHeadMarkerIsToday(t *testing.T) {
	f := magFixture(t, "magseal5")
	f.signIn(t, true)
	f.b.as(func() {
		if err := publishReceiptFile(aftergateFile(f.ref), []byte(strings.Repeat("ab", 32))); err != nil {
			t.Fatal(err)
		}
	})
	magToday(t, f)
}

// T6: a marker that exists and cannot be read is active.
func TestMediaAfterGateSeal_UnreadableMarkerIsActive(t *testing.T) {
	f := magFixture(t, "magseal6")
	f.signIn(t, false)
	f.b.as(func() {
		if err := os.MkdirAll(aftergateFile(f.ref), 0o700); err != nil {
			t.Fatal(err)
		}
	})
	m := mustSeal(t, f)
	for _, rel := range magBg {
		if _, ok := m.Ess[rel]; !ok {
			t.Errorf("%s dropped: an unreadable marker was read as absent", rel)
		}
	}

	t.Run("truth table", func(t *testing.T) {
		t.Setenv("NOWHERE_STATE", t.TempDir())
		ref, head := "r6", "h6"
		if aftergateActive(ref, head) {
			t.Error("absent marker: active")
		}
		if err := publishReceiptFile(aftergateFile(ref), []byte(head+"\n")); err != nil {
			t.Fatal(err)
		}
		if !aftergateActive(ref, head) {
			t.Error("marker names the roster head: not active")
		}
		if aftergateActive(ref, "other") {
			t.Error("marker names another head: active")
		}
		if aftergateActive(ref, "") {
			t.Error("roster head empty: active")
		}
		os.Remove(aftergateFile(ref))
		if err := os.MkdirAll(aftergateFile(ref), 0o700); err != nil {
			t.Fatal(err)
		}
		if !aftergateActive(ref, head) {
			t.Error("unreadable marker (a directory): not active")
		}
		t.Setenv("NOWHERE_STATE", "")
		if aftergateActive(ref, head) {
			t.Error("receipts off: active")
		}
	})
}

// T7: a split whose restored head cannot be read refuses the seal.
func TestMediaAfterGateSeal_UnreadableRestoredHeadRefuses(t *testing.T) {
	f := magFixture(t, "magseal7")
	bogus := strings.Repeat("cd", 32) // no such manifest in the store
	f.b.as(func() {
		writeRestoreReceipt(f.ref, f.atLogin)
		writeLoginRoster(f.ref, bogus)
		if err := publishReceiptFile(aftergateFile(f.ref), []byte(bogus)); err != nil {
			t.Fatal(err)
		}
	})
	f.mustRefuse(t)
}

// T8: a split under NOWHERE_SEAL_FULL refuses the seal.
func TestMediaAfterGateSeal_SealFullRefuses(t *testing.T) {
	f := magFixture(t, "magseal8")
	f.signIn(t, true)
	t.Setenv("NOWHERE_SEAL_FULL", "1")
	f.mustRefuse(t)
}

// T9: a split with the carry switched off refuses the seal.
func TestMediaAfterGateSeal_CarryOffRefuses(t *testing.T) {
	f := magFixture(t, "magseal9")
	f.signIn(t, true)
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "0")
	f.mustRefuse(t)
}

// magTempTree seals a fresh profile whose tree holds a lander temp and a seed temp beside real files, and returns
// the sealed head and its chunk stream's entries.
func magTempSeal(t *testing.T, name string, extra func(h *handset)) (chunkManifest, []bgSplitEntry, *handset) {
	t.Helper()
	a, _ := twoWriters(t, name, magPass)
	a.put("DCIM/real.jpg", strings.Repeat("r", 1000))
	a.put("DCIM/.nwsync-x", strings.Repeat("s", 1000))
	a.put("DCIM/.nwseed-y", strings.Repeat("e", 1000))
	if extra != nil {
		extra(a)
	}
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("seal: %s", msg)
	}
	m := headManifestOf(t, a.base, name+"#media", magPass)
	key := resolveDK(a.base, name+"#media", magPass, nil)
	return m, bgSplitTarOf(t, a.base, key, m.Version, m.Chunks), a
}

func magNoTemps(t *testing.T, m chunkManifest, entries []bgSplitEntry, want ...string) {
	t.Helper()
	for rel := range m.Ess {
		if isMediaTempName(filepath.Base(rel)) {
			t.Errorf("a media temp is in the head's Ess: %s", rel)
		}
	}
	for rel := range m.Deferred {
		if isMediaTempName(filepath.Base(rel)) {
			t.Errorf("a media temp is in the head's Deferred: %s", rel)
		}
	}
	names := map[string]bool{}
	for _, e := range entries {
		names[e.name] = true
		if isMediaTempName(filepath.Base(e.name)) {
			t.Errorf("a media temp is in the sealed tar stream: %s", e.name)
		}
	}
	for _, w := range want {
		if !names[w] {
			t.Errorf("the sealed tar stream lacks %s (entries %d): the test would be vacuous", w, len(entries))
		}
	}
}

// T10: a .nwsync-/.nwseed- temp is never sealed, in all three walks. No marker anywhere.
func TestMediaAfterGateSeal_TempsAreNeverSealed(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", "")
	t.Setenv("NOWHERE_MEDIA_AFTER_GATE", "")

	t.Run("walkChunks", func(t *testing.T) {
		m, entries, _ := magTempSeal(t, "magseal10a", nil)
		magNoTemps(t, m, entries, "DCIM/real.jpg")
		if _, ok := m.Ess["DCIM/real.jpg"]; !ok {
			t.Error("the real file is not indexed: the test would be vacuous")
		}
	})

	t.Run("walkChunks under an overlay", func(t *testing.T) {
		hidden := t.TempDir()
		for n, body := range map[string]string{".nwsync-z": strings.Repeat("z", 1000), "real2.jpg": "a landed photo"} {
			if err := os.WriteFile(filepath.Join(hidden, n), []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		prev := mediaUndersFn
		t.Cleanup(func() { mediaUndersFn = prev })
		var work string
		mediaUndersFn = func(s string) (map[string]string, error) {
			if s == work {
				return map[string]string{filepath.Join(work, "Pictures"): hidden}, nil
			}
			return nil, nil
		}
		m, entries, _ := magTempSeal(t, "magseal10b", func(h *handset) {
			work = h.work
			h.put("Pictures/stub", "")
		})
		magNoTemps(t, m, entries, "Pictures/real2.jpg")
	})

	t.Run("tarDirTo", func(t *testing.T) {
		t.Setenv("NOWHERE_SEAL_FULL", "1")
		m, entries, _ := magTempSeal(t, "magseal10c", nil)
		magNoTemps(t, m, entries, "DCIM/real.jpg")
	})

	t.Run("progress pre-walk", func(t *testing.T) {
		t.Setenv("NOWHERE_SEAL_FULL", "1")
		var total *atomic.Int64
		sealProgTotalHook = func(tot *atomic.Int64) { total = tot }
		t.Cleanup(func() { sealProgTotalHook = nil })
		_, _, a := magTempSeal(t, "magseal10d", nil)
		if total == nil {
			t.Fatal("the seal never handed its progress total")
		}
		if got, want := total.Load(), int64(1000); got != want {
			t.Errorf("the progress total is %d, want %d: the pre-walk priced a media temp (tree %s)", got, want, filepath.Base(a.work))
		}
	})

	t.Run("names", func(t *testing.T) {
		for _, n := range []string{".nwsync-1", ".nwseed-1"} {
			if !isMediaTempName(n) {
				t.Errorf("isMediaTempName(%q) = false", n)
			}
		}
		for _, n := range []string{"nwsync-1", "a.nwsync-1", ".nwsyncx", ".nwseed", "IMG.jpg"} {
			if isMediaTempName(n) {
				t.Errorf("isMediaTempName(%q) = true", n)
			}
		}
		for f, pat := range map[string]string{"media_span.go": `".nwsync-*"`, "mediafs.go": `".nwseed-*"`} {
			b, err := os.ReadFile(f)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(string(b), pat) {
				t.Errorf("%s no longer creates its temp as %s: isMediaTempName must follow it", f, pat)
			}
		}
	})
}

// T11: the shrink guard passes a seal that carried most of the background set.
func TestMediaAfterGateSeal_ShrinkGuardPassesAMostlyCarriedSeal(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_MEDIA_AFTER_GATE", "1")
	t.Setenv("NOWHERE_SEAL_FULL", "")
	t.Setenv("NOWHERE_SEAL_FORCE", "")
	f := &magFix{profile: "magseal11#media"}
	f.a, f.b = twoWriters(t, "magseal11", magPass)
	f.ref = profileRefV2(f.profile, magPass)
	var album []string
	body := func(i int) string { return fmt.Sprintf("album photo %02d %s", i, strings.Repeat("p", 200+i)) }
	f.a.put("Documents/pre.txt", "a document: pre-gate")
	for i := 0; i < 20; i++ {
		rel := fmt.Sprintf("DCIM/album/%02d.jpg", i)
		album = append(album, rel)
		f.a.put(rel, body(i))
	}
	if msg := f.a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	f.atLogin = f.a.head("#media")
	f.old = headManifestOf(t, f.a.base, f.profile, magPass)
	f.landedDK = resolveDK(f.b.base, f.profile, magPass, nil)
	f.b.put("Documents/pre.txt", "a document: pre-gate")
	for i, rel := range album[:2] {
		f.b.put(rel, body(i)) // the two the lander placed
	}
	f.signIn(t, true)
	f.land(t, album[:2]...)
	m := mustSeal(t, f)
	for _, rel := range album {
		if _, ok := m.Ess[rel]; !ok {
			t.Errorf("%s missing from the new head", rel)
		}
	}
}

// T12: a marker with no roster (the roster write failed after the split) refuses the seal.
func TestMediaAfterGateSeal_MarkerWithoutRosterRefuses(t *testing.T) {
	for _, tc := range []struct {
		name string
		dir  bool
	}{{"magseal12", false}, {"magseal12d", true}} {
		t.Run(tc.name, func(t *testing.T) {
			f := magFixture(t, tc.name)
			f.b.as(func() {
				captureStdout(t, func() { mediaRestorePlan(f.profile, magPass, f.atLogin, f.old) })
				if tc.dir {
					os.Remove(aftergateFile(f.ref))
					if err := os.MkdirAll(aftergateFile(f.ref), 0o700); err != nil {
						t.Fatal(err)
					}
				}
				writeRestoreReceipt(f.ref, f.atLogin)
				if loginRosterHead(f.ref) != "" {
					t.Fatal("the fixture has a roster")
				}
				if _, err := os.Lstat(aftergateFile(f.ref)); err != nil {
					t.Fatalf("the fixture has no marker: %v", err)
				}
			})
			f.mustRefuse(t)
		})
	}

	t.Run("truth table", func(t *testing.T) {
		t.Setenv("NOWHERE_STATE", t.TempDir())
		ref := "r12"
		if aftergateMarkerPresent(ref) {
			t.Error("absent marker: present")
		}
		if err := publishReceiptFile(aftergateFile(ref), []byte("h")); err != nil {
			t.Fatal(err)
		}
		if !aftergateMarkerPresent(ref) {
			t.Error("marker file: not present")
		}
		os.Remove(aftergateFile(ref))
		if err := os.MkdirAll(aftergateFile(ref), 0o700); err != nil {
			t.Fatal(err)
		}
		if !aftergateMarkerPresent(ref) {
			t.Error("marker directory: not present")
		}
		t.Setenv("NOWHERE_STATE", "")
		if aftergateMarkerPresent(ref) {
			t.Error("receipts off: present")
		}
	})
}

// T13 (RF-001): a file the lander places after the walk passed its directory, and records in the landed roster
// before the carry runs, is kept. The seal reads the landed roster before the walk, so the file is unlanded in its
// snapshot and the carry keeps its span. Read after the walk, the file would count as landed but unwalked: a deletion.
func TestMediaAfterGateSeal_LandingDuringTheWalkIsKept(t *testing.T) {
	f := magFixture(t, "magseal13")
	f.signIn(t, true)
	const rel = "DCIM/bg1.jpg"
	ran := false
	sealAfterWalkHook = func() {
		ran = true
		f.b.putAt(rel, fmt.Sprintf("photo 0 %s", strings.Repeat("x", 40)), time.Unix(1700000000, 0))
		f.land(t, rel)
	}
	t.Cleanup(func() { sealAfterWalkHook = nil })
	m := mustSeal(t, f)
	if !ran {
		t.Fatal("the seal never reached the after-walk seam")
	}
	o := f.old.Ess[rel]
	r, ok := m.Ess[rel]
	if !ok {
		t.Fatalf("%s landed during the walk and is missing from the new head: the seal dropped it as a deletion", rel)
	}
	if !slices.Equal(m.Chunks[r.S:r.E], f.old.Chunks[o.S:o.E]) {
		t.Errorf("%s: the new span is not the stored span's chunks", rel)
	}
}
