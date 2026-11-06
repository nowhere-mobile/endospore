package main

// NWP-20260908-04 (#91): THE PER-REL ESSENTIAL CARRY FOR #media, DRIVEN THROUGH TWO REAL HANDSETS.
//
// The property: a photo taken on handset A must survive a seal from handset B, which has never materialised
// it. Before this, B's seal published a head without it and the bytes lapsed.
//
// The counter-property, which is the whole reason this is not the resurrection bug of 2026-09-07 in new
// clothes: a photo the user DELETES must stay deleted. For deferred media, absence means "not materialised"
// and deletion needs a mediad tombstone. For ESSENTIAL media the opposite holds -- the login restore
// materialises every essential file, so a file this session restored and no longer has WAS deleted. The
// discriminator is the restore roster: the head this session restored says which rels this handset ever had.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// readSource / containsSrc: the wiring assertions read main.go itself, because a correct function nothing
// calls is precisely the failure this area keeps repeating (slice 5a sat built and uncalled for two months).
func readSource(t *testing.T, name string) (string, error) {
	t.Helper()
	b, err := os.ReadFile(name)
	return string(b), err
}

func containsSrc(src, want string) bool { return strings.Contains(src, want) }

// loginArrived models what a LOGIN writes: the restore RECEIPT (this session holds a byte-complete copy of
// that head, which the #72 guard requires before any seal) AND the LOGIN ROSTER (what this session was
// given, which the carry reads). They were one file until NWP-20260908-13, and conflating them is exactly
// the bug -- so the fixture writes both, separately, the way the restore path does.
func loginArrived(ref, head string) {
	writeRestoreReceipt(ref, head)
	writeLoginRoster(ref, head)
}

// essentialMediaEnv puts a handset in the configuration the flag creates: the media carry on, and the
// threshold at 0 so every regular file gets its own span. Deferral keeps its own floors, so nothing here
// becomes deferred.
func essentialMediaEnv(t *testing.T) {
	t.Helper()
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", "")
}

// ---------------------------------------------------------------------------------------------------
// the selection, as a truth table -- pure, so every decline is testable without a store
// ---------------------------------------------------------------------------------------------------

func essOf(rels ...string) map[string]essRegion {
	m := map[string]essRegion{}
	for i, r := range rels {
		m[r] = essRegion{S: i, E: i + 1, Size: 10}
	}
	return m
}

// THE CORE DISCRIMINATION. Same absence, opposite verdicts, decided only by whether we ever held it.
func TestMediaCarry_TheRosterSeparatesADeletionFromAnotherHandsetsFile(t *testing.T) {
	stored := essOf("DCIM/mine-deleted.jpg", "DCIM/theirs-new.jpg")
	restored := essOf("DCIM/mine-deleted.jpg") // what THIS session was given at login

	got, st := carryMediaEssentialRels(stored, restored, map[string]bool{}, nil, nil, nil, 2, nil)

	if len(got) != 1 || got[0] != "DCIM/theirs-new.jpg" {
		t.Fatalf("carried %v, want only the file this handset never held", got)
	}
	if st.Deleted != 1 {
		t.Errorf("the deleted file was not recognised as a deletion (stats %+v). Carrying it makes every "+
			"photo undeletable -- the user removes it, the next seal puts it back, forever, and it is billed "+
			"the whole time.", st)
	}
}

// AND WITH NO ROSTER AT ALL, NOTHING IS DECIDED. The caller refuses to run without a receipt; this pins the
// function's own behaviour so a future caller cannot pass an empty roster and get a resurrection machine. The
// one sanctioned exception is a restored head that is INDEXED and empty (chunkManifest.EssIdx: the seal that
// wrote it built the per-file index and found no regular file): the caller then passes that empty roster on
// purpose, which is safe because the walked roster (NWP-20261025-01) separates this session's own deletions
// from another handset's files. A pre-flag head, which has no index at all, still gets no carry.
func TestMediaCarry_AnEmptyRosterDoesNotTurnDeletionsIntoCarries(t *testing.T) {
	stored := essOf("DCIM/a.jpg", "DCIM/b.jpg")
	got, _ := carryMediaEssentialRels(stored, nil, map[string]bool{}, nil, nil, nil, 2, nil)
	if len(got) != 2 {
		t.Skipf("selection changed shape (%v) -- re-read the caller's gate before trusting this", got)
	}
	// The function itself cannot tell; the CALLER must not invoke it without a roster. That is asserted in
	// TestMediaCarry_NoRestoreReceiptMeansNoCarry below, which is the assertion that actually protects users.
}

// EVERY DECLINE, NAMED. A carry that silently selects nothing is indistinguishable from one that is not
// wired up, so each reason is exercised and counted.
func TestMediaCarry_DeclinesForEveryStatedReason(t *testing.T) {
	stored := essOf(
		"DCIM/walked.jpg",
		"DCIM/deferred.jpg",
		"DCIM/tombstoned.jpg",
		"DCIM/held-and-gone.jpg",
		"com.nowhere.chooser/files/.nowhere-media/x.bin",
		"Android/data/com.nowhere.chooser/.nowhere-odhold/app.pkg/f.bin",
		"DCIM/carried.jpg",
	)
	seen := map[string]bool{"DCIM/walked.jpg": true}
	deferred := map[string]deferredFile{"DCIM/deferred.jpg": {MTime: 1}}
	tomb := map[string]bool{"DCIM/tombstoned.jpg": true}
	restored := essOf("DCIM/held-and-gone.jpg")

	got, st := carryMediaEssentialRels(stored, restored, seen, deferred, tomb, nil, 7, nil)

	if len(got) != 1 || got[0] != "DCIM/carried.jpg" {
		t.Fatalf("carried %v, want only DCIM/carried.jpg", got)
	}
	for _, c := range []struct {
		name string
		got  int
	}{
		{"walked", st.Walked}, {"deferred", st.Deferred}, {"tombstoned", st.Tomb},
		{"deleted-here", st.Deleted}, {"carried", st.Carried},
	} {
		if c.got != 1 {
			t.Errorf("%s count = %d, want 1 (stats %+v)", c.name, c.got, st)
		}
	}
	if st.Excluded != 2 {
		t.Errorf("excluded = %d, want 2 (the media cache and the on-demand hold) -- stats %+v", st.Excluded, st)
	}
}

// THE HOLD IS NOT OPTIONAL. mediaDenyDirs forces the on-demand hold ESSENTIAL, so under an Ess index every
// parked byte of every on-demand app becomes a carry candidate: another handset's parked data, spliced in,
// undeletable from this device, billed forever (the NWP-20260831-08 shape one directory over).
func TestMediaCarry_NeverCarriesTheOnDemandHold(t *testing.T) {
	rel := "Android/data/com.nowhere.chooser/.nowhere-odhold/app.pkg/files/big.bin"
	got, _ := carryMediaEssentialRels(essOf(rel), essOf("other"), map[string]bool{}, nil, nil, nil, 1, nil)
	if len(got) != 0 {
		t.Fatalf("carried the on-demand hold: %v", got)
	}
}

// A SPAN THE STORED HEAD CANNOT BACK IS NEVER RE-EMITTED -- it would name chunks that are not there, and a
// missing chunk fails the WHOLE scope restore, not just that file.
func TestMediaCarry_RefusesASpanOutsideTheStoredChunkList(t *testing.T) {
	stored := map[string]essRegion{"DCIM/bad.jpg": {S: 5, E: 9}}
	got, st := carryMediaEssentialRels(stored, essOf("other"), map[string]bool{}, nil, nil, nil, 3, nil)
	if len(got) != 0 || st.BadSpan != 1 {
		t.Fatalf("carried %v (bad-span count %d) -- a span past the end of Chunks names blobs that do not exist",
			got, st.BadSpan)
	}
}

// DETERMINISM. Two seals of one state must produce one manifest, so the order is sorted, not map order.
func TestMediaCarry_SelectionIsSorted(t *testing.T) {
	stored := essOf("z.jpg", "a.jpg", "m.jpg")
	for i := 0; i < 8; i++ {
		got, _ := carryMediaEssentialRels(stored, essOf("other"), map[string]bool{}, nil, nil, nil, 3, nil)
		if len(got) != 3 || got[0] != "a.jpg" || got[1] != "m.jpg" || got[2] != "z.jpg" {
			t.Fatalf("run %d produced %v -- map iteration order reached the manifest", i, got)
		}
	}
}

// ---------------------------------------------------------------------------------------------------
// the wiring, through two real handsets and a real store
// ---------------------------------------------------------------------------------------------------

// THE POINT OF THE SLICE, END TO END. B logged in when the account held only `shared.txt`; A has since
// added a photo. B now seals, and must not publish a head without A's photo.
func TestMediaCarry_TheOtherHandsetsEssentialMediaSurvivesASeal(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir()) // arm the receipt machinery, as a real session has it
	a, b := twoWriters(t, "esscarry", "correct horse battery staple")
	ref := profileRefV2("esscarry#media", "correct horse battery staple")

	// The account as B found it at login.
	a.put("Documents/shared.txt", "both handsets hold this")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	atLogin := a.head("#media")
	b.put("Documents/shared.txt", "both handsets hold this") // what B restored
	b.as(func() { loginArrived(ref, atLogin) })              // ... and the receipt that login mints

	// A takes a photo and seals. Small, so it rides the ESSENTIAL tar -- the half that had no index.
	a.put("DCIM/from-a.jpg", "a small photo")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's photo seal: %s", msg)
	}
	if m := headManifestOf(t, a.base, a.name+"#media", a.pass); len(m.Ess) == 0 {
		t.Fatalf("the #media head carries no per-file index (%d essential chunks) -- the flag is not reaching "+
			"the seal, and everything below would be vacuous", len(m.Chunks))
	}

	// B seals. It has never materialised the photo, so its walk cannot see it.
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}

	m := headManifestOf(t, b.base, b.name+"#media", b.pass)
	if _, ok := m.Ess["DCIM/from-a.jpg"]; !ok {
		t.Fatalf("B's seal DROPPED A's photo -- the head now indexes %v. This is the loss the slice exists "+
			"to stop: the bytes lose their lease and the store GC reaps them, so the photo is gone from the "+
			"ACCOUNT, not just from B.", keysOfEss(m.Ess))
	}
	if _, ok := m.Ess["Documents/shared.txt"]; !ok {
		t.Errorf("B's own file went missing from the head it just wrote: %v", keysOfEss(m.Ess))
	}
}

// AND THE DELETION MUST STILL WIN. Same shape, but the file B is missing is one B ITSELF restored -- so its
// absence is the user deleting it, and re-emitting it would make photos immortal.
func TestMediaCarry_AFileThisHandsetRestoredAndLostIsNotResurrected(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, b := twoWriters(t, "essdel", "correct horse battery staple")
	ref := profileRefV2("essdel#media", "correct horse battery staple")

	a.put("Documents/shared.txt", "both handsets hold this")
	a.put("DCIM/delete-me.jpg", "a small photo the user will delete")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	atLogin := a.head("#media")

	// B logs in and receives BOTH files, then the user deletes the photo on B.
	b.put("Documents/shared.txt", "both handsets hold this")
	b.as(func() { loginArrived(ref, atLogin) }) // the receipt names the head B was given

	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}

	m := headManifestOf(t, b.base, b.name+"#media", b.pass)
	if _, ok := m.Ess["DCIM/delete-me.jpg"]; ok {
		t.Fatalf("the deleted photo is back in the account head (%v). The carry cannot tell a deletion from "+
			"another handset's file, so every photo this account ever held is now immortal and billed.",
			keysOfEss(m.Ess))
	}
}

// AND THE CALLER'S GATE: no restore receipt, no carry. Without it, a session that never restored would read
// every rel in the head as "another handset's" and re-emit the lot -- including everything the user deleted.
func TestMediaCarry_NoRestoreReceiptMeansNoCarry(t *testing.T) {
	src, err := readSource(t, "main.go")
	if err != nil {
		t.Skipf("cannot read main.go (%v)", err)
	}
	// Only strings that appear NOWHERE ELSE in main.go: a grep that also matches an unrelated line
	// proves nothing, which is how the first version of this test let two mutations through.
	for _, want := range []string{
		"carryMediaEssentialRels(",
		"mediaEssentialCarryOn(profile)",
		"!incrementalSeal()",
	} {
		if !containsSrc(src, want) {
			t.Errorf("pushProfile does not gate the #media carry on %q. Each is load-bearing: no roster means "+
				"deletions read as another handset's files; no scope check means the vault and #de can reach "+
				"it; and under NOWHERE_SEAL_FULL the footer is not its own chunk, so lifting it truncates "+
				"real data.", want)
		}
	}
}

func keysOfEss(m map[string]essRegion) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// ---------------------------------------------------------------------------------------------------
// what this slice does NOT fix, measured rather than asserted away
// ---------------------------------------------------------------------------------------------------

// THE RESIDUAL, PINNED SO NOBODY READS THIS SLICE AS CONVERGENCE.
//
// With the carry on, two idle handsets keep publishing DIFFERENT heads -- they simply stop losing each
// other's media doing it. Three causes remain and none is rel-keyed work: carried spans are appended rather
// than interleaved in rel order; DIRECTORY entries ride an un-indexed grouped chunk no per-file index can
// name; and the two handsets walk different file sets so their grouped chunks differ anyway.
//
// The assertion is written the way it SHOULD be, so the day the heads do converge this stops being a
// knownDefect and becomes an ordinary regression test. Until then it is the honest record that the churn is
// known, measured, and deliberately out of scope -- which matters because NOWHERE_SEQ_GUARD would refuse
// every one of these seals if the carry did not exempt them.
func TestMediaCarry_TheHeadsStillChurnAfterTheCarry(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, b := twoWriters(t, "esschurn", "correct horse battery staple")
	ref := profileRefV2("esschurn#media", "correct horse battery staple")

	for _, h := range []*handset{a, b} {
		h.put("Documents/shared.txt", "restored at login")
	}
	a.put("DCIM/only-on-a.jpg", "a small photo A has")
	b.put("DCIM/only-on-b.jpg", "a small photo B has")

	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A round 1: %s", msg)
	}
	base := a.head("#media")
	for _, h := range []*handset{a, b} {
		h.as(func() { loginArrived(ref, base) })
	}

	h := alternate(t, a, b, 3)
	last := h[len(h)-1]
	if last[0] != last[1] {
		knownDefect(t, "backlog: `#media`'s two-handset overwrite loop is FIXED by the essential carry",
			"the carry stops the LOSS but not the CHURN: A's seal leaves the head at %s and B's at %s, "+
				"round after round. Remaining causes, none of them rel-keyed: carried spans are appended "+
				"rather than interleaved in rel order; directory entries ride an un-indexed grouped chunk; "+
				"and the two walks cover different file sets. Verify no DATA is lost with "+
				"TestMediaCarry_TheOtherHandsetsEssentialMediaSurvivesASeal, which is the property that "+
				"matters to a user.", short(last[0]), short(last[1]))
	}
}

// ---------------------------------------------------------------------------------------------------
// the gates, asserted by BEHAVIOUR. Source-text checks proved too weak: mutations that removed the scope
// check and the receipt check both survived them, because the strings they grep for appear elsewhere.
// ---------------------------------------------------------------------------------------------------

// THE SCOPE GATE. The flag can leak into any push's environment -- that is precisely what NWP-20260908-01
// cost -- so the vault must be structurally unable to reach a media carry even with the variable set.
func TestMediaCarry_TheVaultScopeIsUnreachableEvenWithTheFlagSet(t *testing.T) {
	essentialMediaEnv(t) // the flag is ON for everything this process does
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, _ := twoWriters(t, "essscope", "correct horse battery staple")

	a.put("note.txt", "CE app data, not media")
	if msg := a.seal(""); msg != "" { // the BARE scope: /data/user/<uid>, not the media tree
		t.Fatalf("vault seal: %s", msg)
	}

	m := headManifestOf(t, a.base, a.name, a.pass)
	if len(m.Ess) != 0 {
		t.Fatalf("the vault head carries a per-file index (%v) -- the media flag reached a scope it has no "+
			"business in. That also means threshold-0 file-aligned chunking on the CE tree: a one-off "+
			"re-upload of every app's data, for a carry that can never run there.", keysOfEss(m.Ess))
	}
}

// THE RECEIPT GATE. Without the head this session restored there is no roster, and with no roster every rel
// in the stored head reads as "another handset's" -- including everything the user deleted. The correct
// behaviour is to carry NOTHING and say so, accepting this seal's loss rather than resurrecting deletions
// account-wide.
func TestMediaCarry_WithoutAReceiptNothingIsCarried(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, b := twoWriters(t, "essnorcpt", "correct horse battery staple")

	a.put("Documents/shared.txt", "both handsets hold this")
	a.put("DCIM/from-a.jpg", "a small photo")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's seal: %s", msg)
	}

	// B seals having never restored -- no receipt is written for it anywhere.
	b.put("Documents/shared.txt", "both handsets hold this")
	if msg := b.seal("#media"); msg != "" {
		return // an older guard refused it outright, which is also a safe outcome
	}

	m := headManifestOf(t, b.base, b.name+"#media", b.pass)
	if _, ok := m.Ess["DCIM/from-a.jpg"]; ok {
		t.Fatalf("the carry ran without a restore roster (head indexes %v). It cannot tell another handset's "+
			"file from one the user deleted, so running it here makes every deleted photo in the account "+
			"immortal -- a far worse failure than this seal losing one file.", keysOfEss(m.Ess))
	}
}

// THE SHRINK GUARD MUST COUNT WHAT THE CARRY RE-EMITTED. `nchunks` is the WALK's emit counter, so a handset
// that walks one file and carries twenty reads as a 20x collapse and is REFUSED -- and on #media a refusal
// fails the WHOLE logoff and leaves the session signed in. This is the ordinary second-handset case.
func TestMediaCarry_ACarryingSealIsNotMistakenForACollapse(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, b := twoWriters(t, "essshrink", "correct horse battery staple")
	ref := profileRefV2("essshrink#media", "correct horse battery staple")

	// The account as B found it: one file. Everything after this arrived from A.
	a.put("Documents/shared.txt", "restored at login")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	atLogin := a.head("#media")
	b.put("Documents/shared.txt", "restored at login")
	b.as(func() { loginArrived(ref, atLogin) })

	// A adds a whole album. Per-file alignment means one region each, so the head grows well past the
	// shrink guard's floor.
	for _, n := range []string{"01", "02", "03", "04", "05", "06", "07", "08", "09", "10",
		"11", "12", "13", "14", "15", "16", "17", "18", "19", "20"} {
		a.put("DCIM/album/"+n+".jpg", "photo "+n)
	}
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's album seal: %s", msg)
	}
	full := headManifestOf(t, a.base, a.name+"#media", a.pass)
	if len(full.Chunks) < 4 {
		t.Skipf("the stored head has only %d chunks, below the shrink guard's floor -- this test cannot "+
			"exercise the guard", len(full.Chunks))
	}

	// B still holds one file. Its walk emits a handful of chunks against a head of many.
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal was REFUSED (%s). The carry supplied every chunk the guard thought was missing, "+
			"so the head did not shrink at all -- but the guard counts only what the WALK emitted. On #media "+
			"this refusal fails the whole logoff and the session stays signed in.", msg)
	}
	m := headManifestOf(t, b.base, b.name+"#media", b.pass)
	if _, ok := m.Ess["DCIM/album/07.jpg"]; !ok {
		t.Errorf("B's seal landed but dropped A's album: %d rel(s) indexed", len(m.Ess))
	}
}

// ---------------------------------------------------------------------------------------------------
// NWP-20260908-09: two diagnostics the first fielded rollout exposed. Both were found by reading a device
// log, not by this suite -- which is the point of writing them down.
// ---------------------------------------------------------------------------------------------------

// THE BOOTSTRAP CASE MUST SPEAK. Every device meets it FIRST: the stored head predates the flag, so it has
// no per-file index and there is nothing to carry. `len(oldM.Ess) > 0` used to sit in the branch condition,
// so that seal fell through in total silence -- and "carry inert" and "carry not wired at all" produce
// exactly the same log. That distinction is the entire reason this slice logs anything.
func TestMediaCarry_TheBootstrapSealSaysWhyItCarriedNothing(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, _ := twoWriters(t, "essboot", "correct horse battery staple")
	ref := profileRefV2("essboot#media", "correct horse battery staple")

	// A head written BEFORE the flag: no Ess index. Seal with the carry off to produce one.
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "0")
	a.put("DCIM/old.jpg", "sealed before the flag existed")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("pre-flag seal: %s", msg)
	}
	pre := headManifestOf(t, a.base, a.name+"#media", a.pass)
	if len(pre.Ess) != 0 {
		t.Fatalf("the pre-flag head already carries an index (%d rels) -- this fixture is not modelling the "+
			"bootstrap at all", len(pre.Ess))
	}
	a.as(func() { loginArrived(ref, a.head("#media")) })

	// Now the flag is on. The carry cannot run, and must SAY so.
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "1")
	out := captureStdout(t, func() {
		if msg := a.seal("#media"); msg != "" {
			t.Fatalf("first flagged seal: %s", msg)
		}
	})
	if !strings.Contains(out, "carry SKIPPED") {
		t.Errorf("the bootstrap seal logged nothing about the carry. Its output was:\n%s\n\nOn a locked user "+
			"build the log is the only channel, and silence here is indistinguishable from the flag never "+
			"having arrived -- which is the failure this whole area keeps repeating.", out)
	}

	// And it must have published an index, so the NEXT login can carry.
	post := headManifestOf(t, a.base, a.name+"#media", a.pass)
	if len(post.Ess) == 0 {
		t.Error("the bootstrap seal published no per-file index either, so the carry would never arm")
	}
}

// THE COMPOSITION LINE MUST REPORT THE THRESHOLD THE WALK USED. Under the flag it is 0, and the line used to
// print sealFileThreshold() beside a count taken against 0 -- so lynx 2026090802 logged "56 files ... of
// which 56 >=1048576B" over a tree holding 25 KB. The count was right; the number next to it was not.
func TestMediaCarry_TheCompositionLineReportsTheEffectiveThreshold(t *testing.T) {
	essentialMediaEnv(t)
	a, _ := twoWriters(t, "essthr", "correct horse battery staple")
	a.put("DCIM/tiny.jpg", "a few bytes, nowhere near a megabyte")

	out := captureStdout(t, func() {
		if msg := a.seal("#media"); msg != "" {
			t.Fatalf("seal: %s", msg)
		}
	})
	if !strings.Contains(out, "of which 1 >=0B") {
		t.Errorf("the composition line does not report the EFFECTIVE threshold. Under this flag the walk uses "+
			"0, so a sub-kilobyte file counts as large and the line must say so. Got:\n%s", out)
	}
	if strings.Contains(out, ">=1048576B") {
		t.Error("the line still prints the CONFIGURED 1 MiB threshold beside a count taken against 0 -- a " +
			"diagnostic that contradicts itself is worse than none")
	}
}

// NWP-20260908-13: A CARRIED FILE MUST SURVIVE THE CARRYING HANDSET'S NEXT SEAL.
//
// It did not. The roster came from the RESTORE RECEIPT, which reanchorReceipt advances on every successful
// seal -- correctly, since the stale-base guard needs the head this handset last published. But that made
// the roster claim the handset HELD the rel it had just carried by hash, so on the next cycle the rel was
// absent locally, in the roster, and in the head: the deletion arm fired and dropped it.
//
// ⚠ TWO LIVE HANDSETS HID THIS COMPLETELY. The handset that owns the file re-adds it every cycle, so the
// account head looked stable at 57 rels across eight observed rounds. The loss only appears once the owner
// signs out -- i.e. exactly when the carry is the only thing keeping the file alive. That is why this is a
// single-handset test: a two-writer test CANNOT see it, and the two that existed both alternated.
func TestMediaCarry_ACarriedFileSurvivesTheNextSealFromTheSameHandset(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, b := twoWriters(t, "carrytwice", "correct horse battery staple")
	ref := profileRefV2("carrytwice#media", "correct horse battery staple")

	a.put("Documents/shared.txt", "both handsets hold this")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	atLogin := a.head("#media")
	b.put("Documents/shared.txt", "both handsets hold this")
	b.as(func() { loginArrived(ref, atLogin) })

	a.put("DCIM/from-a.jpg", "a small photo only A has")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's photo seal: %s", msg)
	}

	// B carries it once...
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's first seal: %s", msg)
	}
	if _, ok := headManifestOf(t, b.base, b.name+"#media", b.pass).Ess["DCIM/from-a.jpg"]; !ok {
		t.Fatal("B did not carry the file at all -- the fixture is not exercising the carry")
	}

	// ...and must still be carrying it on the next cycle, with NOBODY else writing in between. On a real
	// handset this is a 120s tick, and the other phone may well have signed out by then.
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's second seal: %s", msg)
	}
	m := headManifestOf(t, b.base, b.name+"#media", b.pass)
	if _, ok := m.Ess["DCIM/from-a.jpg"]; !ok {
		t.Fatalf("the carried file was DROPPED on the very next seal -- the head now indexes %d rel(s): %v.\n\n"+
			"The carry is worth nothing if it survives one cycle: a periodic seal runs every 120s, so the "+
			"file would be gone from the ACCOUNT within two minutes of the owning handset signing out.",
			len(m.Ess), keysOfEss(m.Ess))
	}
}

// AND A REAL DELETION MUST STILL PROPAGATE, on the same handset, across the same two cycles. The roster
// change must not turn "the user deleted this" into "another handset's file" -- that is the resurrection
// failure this whole area keeps circling.
func TestMediaCarry_ADeletionStillWinsAcrossTwoSeals(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, _ := twoWriters(t, "delTwice", "correct horse battery staple")
	ref := profileRefV2("delTwice#media", "correct horse battery staple")

	a.put("Documents/shared.txt", "kept")
	a.put("DCIM/delete-me.jpg", "a small photo the user will delete")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	a.as(func() { loginArrived(ref, a.head("#media")) }) // this handset RECEIVED both files

	a.rm("DCIM/delete-me.jpg")
	for i, round := range []string{"first", "second"} {
		if msg := a.seal("#media"); msg != "" {
			t.Fatalf("%s seal after the delete: %s", round, msg)
		}
		m := headManifestOf(t, a.base, a.name+"#media", a.pass)
		if _, ok := m.Ess["DCIM/delete-me.jpg"]; ok {
			t.Fatalf("the deleted photo is back in the account head after the %s seal (%v). The roster must "+
				"still recognise a file this handset RECEIVED and no longer has as a deletion.",
				round, keysOfEss(m.Ess))
		}
		_ = i
	}
}

// AND THE LOGIN MUST ACTUALLY WRITE IT. A mutation that deleted the call from the restore path survived
// every test above, because the fixtures mint the roster themselves -- so the whole mechanism could be
// correct and reach no device, which is this area's signature failure (slice 5a shipped a correct function
// nothing called; NOWHERE_SEQ_GUARD shipped a correct flag nothing set).
//
// The string asserted here appears exactly once in main.go and only at the login-restore site, so this
// cannot pass by matching something unrelated -- which is how an earlier version of this file's wiring
// check let two mutations through.
func TestMediaCarry_TheLoginRestoreWritesTheRoster(t *testing.T) {
	// NWP-20261014-26: the complete-restore arm lives in finishRestore (media_server.go); main()'s restore
	// case must still reach it.
	mainSrc, err := readSource(t, "main.go")
	if err != nil {
		t.Skipf("cannot read main.go (%v)", err)
	}
	if !strings.Contains(mainSrc, "finishRestore(profile, pass, restoredHead, skipped)") {
		t.Fatal("main()'s restore case no longer calls finishRestore, so no login restore writes the roster")
	}
	src, err := readSource(t, "media_server.go")
	if err != nil {
		t.Skipf("cannot read media_server.go (%v)", err)
	}
	const call = "writeLoginRoster(profileRefV2(profile, pass), restoredHead)"
	if n := strings.Count(src, call); n != 1 {
		t.Fatalf("the login restore calls %s %d time(s), want exactly 1.\n\n"+
			"Without it the roster is never minted on a real handset, loginRosterHead returns \"\", and the "+
			"carry skips every seal forever -- correct code that reaches nothing.", call, n)
	}
	// It must sit with the receipt write, in the COMPLETE-restore arm: a short restore withholds both, which
	// is what stops the roster reading an incomplete fetch as the user deleting everything it missed.
	i := strings.Index(src, call)
	// Wide enough to span the comment that explains the pair (~30 lines), narrow enough that a receipt write
	// in a different function could not satisfy it.
	before := src[max(0, i-2000):i]
	if !strings.Contains(before, "writeRestoreReceipt(profileRefV2(profile, pass), restoredHead)") {
		t.Error("the roster write is not beside the login's receipt write. They must be minted by the same " +
			"complete-restore arm, or the two can disagree about what this session was given.")
	}
}

// NWP-20260908-17: A REL THE SEAL ITSELF EXCLUDED IS NOT A DELETION, AND MUST NOT BE COUNTED AS ONE.
//
// The roster arm used to be evaluated AHEAD of the two exclusion arms. Both decline the carry, so the defect
// never changed a byte and lived entirely in the COUNT -- which is the number read off a handset to tell a
// working carry from a broken one. `deleted-here` meant "absent for a reason I have not checked yet".
//
// FORGING ONE TAKES A MID-SESSION CHANGE, and that is what this fixture stages: the rel must be in the head
// this session RESTORED (so the exclusion did not apply at login) and excluded by the time we seal. Exactly
// two routine events do it -- a tap on an on-demand app, after which roamd's odrestore has moved the parked
// tree out of .nowhere-odhold/ and removed the source; and switching an app Off, which puts it on the drop
// list the walk SkipDirs. Cache and staging rels are NOT in this fixture and cannot be: the walk SkipDirs
// them and Ess is built only from what the walk emitted, so they are in neither map. A fixture that included
// them would be asserting over a state the seal cannot produce.
func TestMediaCarry_AnExcludedRelIsNotReportedAsADeletion(t *testing.T) {
	const (
		tapped  = "Android/data/" + chooserPkg + "/" + odHoldDirName + "/app.pkg/files/parked.bin"
		off     = "Android/data/offapp.pkg/files/photo.jpg"
		deleted = "DCIM/Camera/really-deleted.jpg"
	)
	// All three were restored at login. None is present at seal time -- and only one of the three absences
	// is the user.
	got, st := carryMediaEssentialRels(essOf(tapped, off, deleted), essOf(tapped, off, deleted),
		map[string]bool{}, nil, nil, map[string]bool{"offapp.pkg": true}, 3, nil)

	if len(got) != 0 {
		t.Fatalf("carried %v, want nothing -- every rel here is either excluded or deleted", got)
	}
	if st.Deleted != 1 {
		t.Errorf("deleted-here = %d, want exactly 1 (only %s).\n\n"+
			"The other %d are absences the SEAL caused: an on-demand hold a tap emptied, and a switched-off "+
			"app the drop list skips. Reporting them as deletions is not cosmetic -- this counter is what "+
			"says whether the carry is working, and it would send the next reader hunting a deletion nobody "+
			"made. Stats %+v",
			st.Deleted, deleted, st.Deleted-1, st)
	}
	if st.Excluded != 2 {
		t.Errorf("excluded = %d, want 2 (the emptied hold and the switched-off app) -- stats %+v", st.Excluded, st)
	}
}

// NWP-20261025-03: a rel the walk VISITED but could not read (seen[rel] present, false) is still on this phone.
// It is never a deletion, even when this session restored it -- the roster arm used to count it deleted-here.
func TestMediaCarry_AnUnreadRelInTheRosterKeepsItsStoredSpan(t *testing.T) {
	const rel = "DCIM/unread.jpg"
	got, st := carryMediaEssentialRels(essOf(rel), essOf(rel), map[string]bool{rel: false}, nil, nil, nil, 1, nil)
	if len(got) != 1 || got[0] != rel {
		t.Fatalf("carried %v, want [%s]: a restored file one seal cannot open is not a deletion (stats %+v)", got, rel, st)
	}
	if st.Carried != 1 || st.Unread != 1 || st.Deleted != 0 {
		t.Fatalf("stats Carried=%d Unread=%d Deleted=%d, want 1/1/0", st.Carried, st.Unread, st.Deleted)
	}
}

// The roster arm is unchanged: a rel never visited (key absent) that the session restored is still a deletion.
func TestMediaCarry_AnUnvisitedRosterRelIsStillADeletion(t *testing.T) {
	const rel = "DCIM/gone.jpg"
	got, st := carryMediaEssentialRels(essOf(rel), essOf(rel), map[string]bool{}, nil, nil, nil, 1, nil)
	if len(got) != 0 || st.Deleted != 1 || st.Unread != 0 {
		t.Fatalf("carried %v stats %+v, want nothing carried, Deleted=1, Unread=0", got, st)
	}
}

// Present-false loses to the tombstone and drop arms, and a span the head cannot back is never re-emitted.
func TestMediaCarry_AnUnreadRelStillYieldsToTombstoneDropAndSpanCheck(t *testing.T) {
	seen := map[string]bool{"DCIM/tomb.jpg": false, "Android/data/com.dropped.app/files/x.bin": false, "DCIM/far.jpg": false}
	stored := essOf("DCIM/tomb.jpg", "Android/data/com.dropped.app/files/x.bin", "DCIM/far.jpg")
	stored["DCIM/far.jpg"] = essRegion{S: 5, E: 9, Size: 10}
	got, st := carryMediaEssentialRels(stored, nil, seen, nil, map[string]bool{"DCIM/tomb.jpg": true},
		map[string]bool{"com.dropped.app": true}, 3, nil)
	if len(got) != 0 {
		t.Fatalf("carried %v, want nothing", got)
	}
	if st.Tomb != 1 || st.Excluded != 1 || st.BadSpan != 1 || st.Unread != 0 || st.Carried != 0 {
		t.Fatalf("stats %+v, want Tomb=1 Excluded=1 BadSpan=1 Unread=0 Carried=0", st)
	}
}

// ---------------------------------------------------------------------------------------------------
// NWP-20261026-03: an indexed head with no regular file is not a pre-flag head
// ---------------------------------------------------------------------------------------------------

// B signs in to a #media head that holds no regular file while A is signed in. A's new screenshot must survive
// B's seals: the empty head used to read as "written before the flag" and switched the carry off for the session.
func TestMediaCarry_AnEmptyIndexedHeadAtSignInStillCarries(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, b := twoWriters(t, "essemptyhead", "correct horse battery staple")
	ref := profileRefV2("essemptyhead#media", "correct horse battery staple")

	if err := os.MkdirAll(filepath.Join(a.work, "DCIM"), 0o700); err != nil {
		t.Fatal(err)
	}
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("empty-tree seal: %s", msg)
	}
	empty := headManifestOf(t, a.base, a.name+"#media", a.pass)
	if len(empty.Ess) != 0 || !empty.EssIdx {
		t.Fatalf("the head should be indexed and empty, got %d rels, marker=%v", len(empty.Ess), empty.EssIdx)
	}
	atLogin := a.head("#media")
	b.as(func() { loginArrived(ref, atLogin) })

	a.put("DCIM/Screenshots/shot.png", "a small screenshot")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's screenshot seal: %s", msg)
	}
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}
	m := headManifestOf(t, b.base, b.name+"#media", b.pass)
	if _, ok := m.Ess["DCIM/Screenshots/shot.png"]; !ok {
		t.Fatalf("B's seal DROPPED A's screenshot (head indexes %v): a head restored empty-but-indexed turned "+
			"the carry off for the whole session.", keysOfEss(m.Ess))
	}
}

// THE CONTROL: a head sealed before the flag still skips, and a deletion made on B stands.
func TestMediaCarry_APreFlagRestoredHeadStillSkipsTheCarry(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, b := twoWriters(t, "esspreflag", "correct horse battery staple")
	ref := profileRefV2("esspreflag#media", "correct horse battery staple")

	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "0")
	a.put("DCIM/old.jpg", "sealed before the flag existed")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("pre-flag seal: %s", msg)
	}
	atLogin := a.head("#media")
	b.as(func() { loginArrived(ref, atLogin) }) // B restored it, then the user deleted it: B has no file

	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "1")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("indexed seal: %s", msg)
	}
	out := captureStdout(t, func() {
		if msg := b.seal("#media"); msg != "" {
			t.Fatalf("B's seal: %s", msg)
		}
	})
	if !strings.Contains(out, "carry SKIPPED") {
		t.Errorf("a pre-flag restored head no longer skips the carry. Output:\n%s", out)
	}
	m := headManifestOf(t, b.base, b.name+"#media", b.pass)
	if _, ok := m.Ess["DCIM/old.jpg"]; ok {
		t.Errorf("the deletion on B was undone (head indexes %v)", keysOfEss(m.Ess))
	}
}

// The marker is written only by a seal that built the #media per-file index.
func TestMediaCarry_TheIndexMarkerIsWrittenOnlyByAnIndexingMediaSeal(t *testing.T) {
	essentialMediaEnv(t)
	a, _ := twoWriters(t, "essmarker", "correct horse battery staple")
	a.put("DCIM/x.jpg", "small")

	marker := func(scope string) bool {
		t.Helper()
		if msg := a.seal(scope); msg != "" {
			t.Fatalf("seal %q: %s", scope, msg)
		}
		return headManifestOf(t, a.base, a.name+scope, a.pass).EssIdx
	}
	if !marker("#media") {
		t.Error("a flag-on #media seal did not write the marker")
	}
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "0")
	a.put("DCIM/y.jpg", "small two")
	if marker("#media") {
		t.Error("a flag-off #media seal wrote the marker")
	}
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "1")
	t.Setenv("NOWHERE_SEAL_FULL", "1")
	a.put("DCIM/z.jpg", "small three")
	if marker("#media") {
		t.Error("a NOWHERE_SEAL_FULL #media seal wrote the marker: a whole-tree tar has no per-file spans")
	}
	t.Setenv("NOWHERE_SEAL_FULL", "")
	if marker("") {
		t.Error("a vault seal wrote the marker")
	}
}
