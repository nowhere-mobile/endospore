package main

// NWP-20260908-11: THE SHRINK GUARD COMPARED CHUNK COUNTS ACROSS DIFFERENT CHUNKINGS.
//
// A head written with per-file alignment (the essential-index flags force threshold 0) holds ONE REGION PER
// FILE. The same tree sealed without that flag groups its small files through a single cdcSplit. So a
// flagless handset re-sealing a file-aligned head produces ~5x fewer chunks over IDENTICAL DATA -- and the
// guard read that as a partial restore and refused.
//
// On #media a refusal is not cheap: roamd maps agent exit 4 to ERR-REFUSED for the WHOLE logoff and the
// session stays signed in. That is what forced the rollout rule "update both handsets before signing into
// both" -- a sequencing constraint a user cannot be expected to follow.
//
// The fix is to compare FILE COUNTS when the alignments disagree. Bytes were the obvious answer and are
// measurably wrong: per-file alignment writes a 512-byte tar header plus padding for EVERY file, so 20 files
// of ~48 B seal to 960 B grouped and to 22 chunks aligned -- the overhead dominates the payload, and a byte
// ratio convicts identical data just as readily as a chunk ratio does. How many FILES there are does not
// move with the chunking, and it is exactly what this guard is for: a partial restore loses files.

import (
	"strings"
	"testing"
)

// alignedFixture seals a tree WITH per-file alignment, leaving a file-aligned head, then returns the handset
// positioned to seal again however the caller configures it.
func alignedFixture(t *testing.T, name string) *handset {
	t.Helper()
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())

	a, _ := twoWriters(t, name, "correct horse battery staple")
	// Enough small files that grouping collapses them well past the guard's 5x ratio.
	for _, n := range []string{"01", "02", "03", "04", "05", "06", "07", "08", "09", "10",
		"11", "12", "13", "14", "15", "16", "17", "18", "19", "20"} {
		a.put("DCIM/album/"+n+".jpg", "photo "+n+" -- small, so it rides the essential set")
	}
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("aligned setup seal: %s", msg)
	}
	m := headManifestOf(t, a.base, a.name+"#media", a.pass)
	if len(m.Ess) == 0 {
		t.Fatalf("the setup seal produced no per-file index -- this fixture is not file-aligned and the test "+
			"would prove nothing (%d chunks)", len(m.Chunks))
	}
	if len(m.Chunks) < 4 {
		t.Skipf("only %d chunks; below the shrink guard's floor, so the guard cannot fire either way",
			len(m.Chunks))
	}
	return a
}

// THE WEDGE. Same handset, same files, same bytes -- only the flag changes. It must not be refused.
func TestShrinkGuard_AFlaglessReSealOfAFileAlignedHeadIsNotACollapse(t *testing.T) {
	a := alignedFixture(t, "alignwedge")
	before := headManifestOf(t, a.base, a.name+"#media", a.pass)

	// The other handset is on an older build: no flag, so its walk groups the small files.
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "0")
	out := captureStdout(t, func() {
		if msg := a.seal("#media"); msg != "" {
			t.Fatalf("a flagless re-seal of a file-aligned head was REFUSED (%s).\n\n"+
				"Nothing was lost -- same files, same bytes -- only the CHUNKING differs, because the stored "+
				"head has one region per file and this walk groups them. On #media a refusal fails the whole "+
				"logoff and leaves the session signed in, which is why this had to become a sequencing rule "+
				"instead of just working.", msg)
		}
	})

	after := headManifestOf(t, a.base, a.name+"#media", a.pass)
	if len(after.Chunks)*5 >= len(before.Chunks) {
		t.Skipf("the re-seal did not actually collapse the chunk count (%d -> %d), so the guard was never "+
			"near firing and this test is not exercising it", len(before.Chunks), len(after.Chunks))
	}
	if !strings.Contains(out, "shrink check used FILE COUNTS") {
		t.Errorf("the seal landed but said nothing about WHY a %dx chunk collapse was allowed. That is the "+
			"shape of a guard quietly not firing, which is indistinguishable from a guard that is broken.\n%s",
			len(before.Chunks)/max(1, len(after.Chunks)), out)
	}
}

// AND THE GUARD MUST STILL CATCH REAL LOSS ACROSS THAT SAME BOUNDARY. Weakening it into "any alignment
// change is fine" would be worse than the bug: a partial restore is exactly when the head is file-aligned
// and the seal is short.
func TestShrinkGuard_RealLossIsStillRefusedWhenTheAlignmentDiffers(t *testing.T) {
	a := alignedFixture(t, "alignloss")

	// Now genuinely lose almost everything AND drop the flag -- the partial-restore shape.
	for _, n := range []string{"01", "02", "03", "04", "05", "06", "07", "08", "09", "10",
		"11", "12", "13", "14", "15", "16", "17", "18", "19"} {
		a.rm("DCIM/album/" + n + ".jpg")
	}
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "0")

	if msg := a.seal("#media"); msg == "" {
		m := headManifestOf(t, a.base, a.name+"#media", a.pass)
		t.Fatalf("a seal that lost 19 of 20 files was ACCEPTED across an alignment change (head now %d "+
			"chunks). Switching comparison must not become 'anything goes when the chunking differs' -- a "+
			"partial restore loses FILES, which is precisely what the file-count test is there to see.",
			len(m.Chunks))
	}
}

// THE MATCHING-ALIGNMENT PATH IS UNTOUCHED, so the guard that has caught real events keeps its exact
// behaviour when both sides were chunked the same way.
func TestShrinkGuard_MatchingAlignmentStillUsesChunks(t *testing.T) {
	a := alignedFixture(t, "alignsame")
	for _, n := range []string{"01", "02", "03", "04", "05", "06", "07", "08", "09", "10",
		"11", "12", "13", "14", "15", "16", "17", "18", "19"} {
		a.rm("DCIM/album/" + n + ".jpg")
	}
	// flag left ON: both sides file-aligned, so the chunk ratio is meaningful again
	out := captureStdout(t, func() {
		if msg := a.seal("#media"); msg == "" {
			t.Fatal("a 20-to-1 collapse with matching alignment was ACCEPTED -- the original guard is gone")
		}
	})
	if strings.Contains(out, "shrink check used FILE COUNTS") {
		t.Error("the file-count path ran even though both heads were file-aligned; the chunk ratio is the " +
			"more sensitive test and must stay in charge when it is meaningful")
	}
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// WHY THE `sameAlignment` TERM IS LOAD-BEARING, AND NOT MERELY `len(oldM.Ess) > 0`.
//
// A mutation that ran the file-count test in BOTH directions survived every test above, because with matching
// alignment the two comparisons agree on a tree of small files -- one region per file, so chunks track files.
// They stop agreeing the moment a file is big enough to SPLIT: a head of a few large files holds many chunks
// per rel, so losing them is a large chunk collapse and only a small rel collapse. The chunk ratio is the
// more sensitive test there, and it must stay in charge whenever it is meaningful.
//
// Written because the mutation survived. A condition no mutation can convict is one a reader trusts for the
// wrong reason -- the same standard applied to the receipt check in NWP-20260908-04.
func TestShrinkGuard_MatchingAlignmentKeepsTheMoreSensitiveChunkTest(t *testing.T) {
	// The bare (CE) scope with the #apps flag: file-aligned, and NOT subject to the media deferral floors,
	// so a multi-megabyte file stays essential and splits into several chunks.
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "1")
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, _ := twoWriters(t, "alignsplit", "correct horse battery staple")

	// VARIED bytes, not a repeated string: CDC boundaries are content-defined, and identical content also
	// dedups, so a repetitive payload yields a handful of chunks and the fixture proves nothing. This is a
	// cheap deterministic spread -- enough entropy for real boundaries, no dependency on math/rand.
	// TEN large files, so the head holds ~40 chunks over 10 rels. The numbers are chosen so the two tests
	// DISAGREE below -- that disagreement is the entire point of the test.
	for _, n := range []string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j"} {
		b := make([]byte, 3<<20) // 3 MiB, comfortably several chunks at cdcMin 256 KiB
		seed := uint32(n[0]) * 2654435761
		for i := range b {
			seed = seed*1664525 + 1013904223
			b[i] = byte(seed >> 24)
		}
		a.put("app.pkg/files/"+n+".bin", string(b))
	}
	if msg := a.seal(""); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	m := headManifestOf(t, a.base, a.name, a.pass)
	if len(m.Ess) == 0 || len(m.Chunks) < len(m.Ess)*3 {
		t.Skipf("the fixture did not produce many chunks per rel (%d chunks over %d rels), so the two tests "+
			"would agree and this case cannot be distinguished", len(m.Chunks), len(m.Ess))
	}

	// Lose the large files; keep a handful of tiny ones. Few rels lost, MANY chunks lost.
	for _, n := range []string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j"} {
		a.rm("app.pkg/files/" + n + ".bin")
	}
	// Keep TWO tiny files. By CHUNKS that is a ~10x collapse and the guard must fire; by FILE COUNT it is
	// 2 walked against 10 indexed, which is 2*5 >= 10 and would NOT fire. Only one of the two tests sees it.
	for _, n := range []string{"1", "2"} {
		a.put("app.pkg/files/tiny"+n+".txt", "small")
	}

	if msg := a.seal(""); msg == "" {
		after := headManifestOf(t, a.base, a.name, a.pass)
		t.Fatalf("a seal that dropped %d chunks (%d -> %d) over %d rels was ACCEPTED. By FILE COUNT it looks "+
			"harmless (2 walked vs %d indexed), which is exactly why the chunk ratio must stay in charge when "+
			"both heads share an alignment -- it is the more sensitive of the two.",
			len(m.Chunks)-len(after.Chunks), len(m.Chunks), len(after.Chunks), len(m.Ess), len(m.Ess))
	}
}
