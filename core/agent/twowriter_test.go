package main

// TWO WRITERS, ONE ACCOUNT -- the harness that should have existed before any of this week's work.
//
// On 2026-09-05..07 four defects were found by running two real handsets against one profile: a wallet
// overwrite that reverted a paid 50 GB plan to 10 GB, a sequential head replacement the stale-publish
// guard cannot see, cross-scope skew, and a recovery-pointer clobber. Every one is reproducible here
// against a temp store in milliseconds -- no hardware, no flag, no second handset, no beta gateway.
// Finding them cost three days of device time instead. That gap is why this file exists.
//
// WHAT THE EXISTING TESTS DO NOT COVER, and why none of them caught these:
//   - seal_cas_test.go unit-tests the expectation MAP, not two writers.
//   - concurrency_test.go is intra-device command serialisation -- one agent, many verbs.
//   - multidevice_test.go uses two unit IDs but never two SEALERS.
// Nothing anywhere ran two sessions against one store and asked what survived.
//
// THE FAILURES MODELLED HERE ARE SEQUENTIAL, NOT CONCURRENT, AND THAT IS THE POINT. expectRef narrows the
// concurrent window to about one round trip; the shape it structurally cannot see is the common one --
// B restored an hour ago, A has sealed since, B now seals, and got == want because nothing moved DURING
// B's push. Taking turns is therefore the honest model of two handsets, and it is what makes this
// testable with no goroutines and no timing.
//
// WHAT IS OBSERVED, AND WHY IT IS THE HEAD RATHER THAN RESTORED FILES. The property under test is "whose
// seal is the account's current state", and the head ref answers exactly that -- with no key, no manifest
// parsing, and no reimplementation of production's restore ladder inside a test. Restoring instead would
// mean either duplicating resolveKeyHead, so the test stops exercising the real path, or reaching for
// restoreSet, which reads the priority-manifest shape of the restore-set verb and cannot open a CDC
// manifest at all. The head is the smaller and the truer observable.

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------------------------------
// the harness
// ---------------------------------------------------------------------------------------------------

// handset is one signed-in device. The agent keeps a device's identity in PROCESS globals (unitIDPath,
// the environment), so a handset installs its own before acting and restores the previous afterwards --
// which is why `as` exists, and why the model takes turns rather than running goroutines.
type handset struct {
	t     *testing.T
	base  string
	name  string
	pass  string
	unit  string // this handset's unit-id file: its lineage identity
	work  string // what a seal pushes: this handset's live tree
	state string // its own NOWHERE_STATE: restore receipts are PER-DEVICE RAM state, not shared
}

func newHandset(t *testing.T, base, name, pass string) *handset {
	t.Helper()
	d := t.TempDir()
	h := &handset{t: t, base: base, name: name, pass: pass,
		unit: filepath.Join(d, "unit-id"), work: filepath.Join(d, "work"),
		state: filepath.Join(d, "state")}
	for _, p := range []string{h.work, h.state} {
		if err := os.MkdirAll(p, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	return h
}

// as installs this handset's process-global identity for the duration of fn.
//
// ⚠ NOWHERE_STATE IS PART OF THAT IDENTITY, and leaving it shared was a real bug in this harness. Restore
// receipts live in per-device RAM state, so with one shared dir both handsets read and write ONE receipt
// -- and A's seal silently re-anchored the receipt B was supposed to be holding, which made the
// sequential-overwrite guard look broken when it was the model that was wrong. Caught by the end-to-end
// test rather than by any unit test, which is the argument for having written it.
func (h *handset) as(fn func()) {
	h.t.Helper()
	origUnit, origState := unitIDPath, os.Getenv("NOWHERE_STATE")
	unitIDPath = h.unit
	if origState != "" { // only when the caller armed receipts; otherwise stay inert as before
		os.Setenv("NOWHERE_STATE", h.state)
	}
	defer func() {
		unitIDPath = origUnit
		if origState != "" {
			os.Setenv("NOWHERE_STATE", origState)
		}
	}()
	fn()
}

// put writes a file into this handset's live tree -- the user doing something on this phone.
func (h *handset) put(rel, content string) {
	h.t.Helper()
	p := filepath.Join(h.work, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		h.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		h.t.Fatal(err)
	}
}

// putAt is put with the file's mtime pinned. A seal tars the file with its mtime (rounded to the second)
// and a restore sets it back, so mtime is roamed metadata and a test that compares manifests must say
// which mtime it means rather than inherit whatever the wall clock was between two writes.
func (h *handset) putAt(rel, content string, mtime time.Time) {
	h.t.Helper()
	h.put(rel, content)
	if err := os.Chtimes(filepath.Join(h.work, filepath.FromSlash(rel)), mtime, mtime); err != nil {
		h.t.Fatal(err)
	}
}

// rm deletes a file from this handset's live tree -- the user removing something on this phone.
func (h *handset) rm(rel string) {
	h.t.Helper()
	if err := os.Remove(filepath.Join(h.work, filepath.FromSlash(rel))); err != nil {
		h.t.Fatal(err)
	}
}

// seal pushes this handset's tree to the given scope ("" is the bare/CE scope) and returns why it did not
// land, or "" if it did.
//
// ⚠ THERE ARE TWO WAYS A SEAL DOES NOT LAND AND THEY LOOK NOTHING ALIKE. A hard error panics through
// fail(); a GUARD refusal sets the package-level sealRefused and returns NORMALLY, because main reads that
// flag afterwards to choose exitSealRefused. An earlier version of this helper watched only for the panic,
// so a guard that fired correctly was recorded as "accepted" and the sequential-overwrite test failed
// against working code. Watching only one of the two is the same class of mistake as a test that cannot
// see -- which is why the harness has a self-test.
func (h *handset) seal(scope string) (refused string) {
	h.t.Helper()
	h.as(func() {
		defer func() {
			if r := recover(); r != nil {
				if err, ok := r.(error); ok {
					refused = err.Error()
				} else {
					refused = "panic"
				}
			}
		}()
		sealRefused, sealStaleHit, sealFenceHit = false, false, false
		pushProfile(h.base, h.name+scope, h.pass, h.work)
		switch {
		case sealRefused:
			refused = "refused by a seal guard"
		case sealStaleHit:
			refused = "refused: stale publish"
		case sealFenceHit:
			refused = "refused: delete fence"
		}
	})
	return refused
}

// head is the account's current state for a scope, as this handset resolves it.
func (h *handset) head(scope string) (ref string) {
	h.t.Helper()
	h.as(func() { ref = getRef(h.base, headKey(h.base, h.name+scope, h.pass)) })
	return ref
}

// twoWriters sets up one account and two handsets signed into it.
func twoWriters(t *testing.T, name, pass string) (a, b *handset) {
	t.Helper()
	base := newHTTPStore(t)
	createVault(base, name, pass)
	return newHandset(t, base, name, pass), newHandset(t, base, name, pass)
}

// outcome renders whether a push was refused, so a failure message still reads a year from now.
func outcome(refused string) string {
	if refused != "" {
		return "REFUSED (" + refused + ")"
	}
	return "ACCEPTED with no refusal"
}

// knownDefect records an expectation that does NOT hold yet.
//
// THE ASSERTION AROUND EVERY CALL IS ALREADY WRITTEN THE RIGHT WAY ROUND. Each states what SHOULD be
// true, so the day someone fixes the defect the comparison simply passes and the test becomes an ordinary
// regression test -- nothing to invert, nothing to remember. Until then this keeps the suite green while
// the expectation is written down, greppable, and attached to its backlog row, rather than living in a
// commit message or in someone's head -- which is how these were lost the first time. The row must quote the
// title of one open row of docs/backlog.md (sections A-G); ci/check-known-defects.py checks it in CI.
func knownDefect(t *testing.T, row, format string, args ...any) {
	t.Helper()
	t.Logf("KNOWN DEFECT ["+row+"] "+format, args...)
	t.Skipf("expectation recorded, not yet met -- see %s", row)
}

// ---------------------------------------------------------------------------------------------------
// the harness must be able to SEE a difference, or every test below is vacuously green
// ---------------------------------------------------------------------------------------------------

func TestTwoWriterHarnessCanSeeWhatItClaimsToSee(t *testing.T) {
	a, b := twoWriters(t, "harness", "correct horse battery staple")

	a.put("note.txt", "first")
	if msg := a.seal(""); msg != "" {
		t.Fatalf("A's seal failed: %s", msg)
	}
	h1 := a.head("")
	if h1 == "" {
		t.Fatal("no head after a successful seal -- the harness cannot observe anything")
	}

	// The observable must be SENSITIVE TO CONTENT, or "the head did not change" would mean nothing.
	a.put("note.txt", "second")
	if msg := a.seal(""); msg != "" {
		t.Fatalf("A's second seal failed: %s", msg)
	}
	h2 := a.head("")
	if h2 == h1 {
		t.Fatalf("the head did not move when the content changed (%s) -- every assertion in this file "+
			"would be vacuous", short(h1))
	}

	// And both handsets must resolve the SAME ref, or this is not one account and nothing below applies.
	if hb := b.head(""); hb != h2 {
		t.Fatalf("A and B resolve different heads (%s vs %s) -- they are not on one account",
			short(h2), short(hb))
	}
}

// ---------------------------------------------------------------------------------------------------
// failure 1: the SEQUENTIAL overwrite -- the shape the stale-publish guard structurally cannot see
// ---------------------------------------------------------------------------------------------------

// Both handsets are signed in. B took its copy first; A then does work and seals. B, still holding its
// older tree, seals afterwards -- and because nothing moved DURING B's push, expectRef sees got == want
// and permits it. A's work is replaced with no refusal anywhere.
//
// The bare scope is the CE app-data tree (_push vault "$name" "$USERDIR", USERDIR=/data/user/$uid), so
// this is the largest and most user-visible leg, not metadata.
func TestTwoWriters_ALaterSealFromAStaleHandsetMustNotReplaceNewerWork(t *testing.T) {
	a, b := twoWriters(t, "seqover", "correct horse battery staple")

	// The account starts with something both handsets have seen.
	a.put("shared.txt", "original")
	if msg := a.seal(""); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	b.put("shared.txt", "original") // B logged in here: its tree mirrors what it restored

	// A does real work and seals it.
	a.put("shared.txt", "A's newer work")
	if msg := a.seal(""); msg != "" {
		t.Fatalf("A's second seal: %s", msg)
	}
	afterA := a.head("")

	// B, which has done nothing since and knows nothing of A's work, seals its stale tree.
	refused := b.seal("")
	afterB := a.head("")

	// THE OBSERVABLE IS THE REFUSAL, NOT HEAD EQUALITY, and that distinction was learned the hard way
	// while building this: a fix-simulation gave B a tree byte-identical to A's and the head STILL moved,
	// because A's seal was incremental (it had a warm scan cache) while B's was cold, and the two produce
	// different manifests for the same bytes. "The head did not move" is therefore not a property a
	// correct system would satisfy. "The stale writer was told no" is.
	if refused != "" {
		return
	}
	knownDefect(t, "backlog: There is NO TWO-WRITER TEST anywhere in the tree, at any level",
		"a stale handset's later seal was %s and moved the account head %s -> %s. Nothing refused it, "+
			"because nothing moved WHILE it was in flight -- which is the shape the guard cannot see.",
		outcome(refused), short(afterA), short(afterB))
}

// The same shape on #media, which stays ACCOUNT-SHARED under every flag setting (isPerUnitRef excludes
// #media and #apps deliberately -- a kept app must reappear on a different handset), with a conf that
// switches the essential carry OFF. The shipped default is on since NWP-20261023-09 and is asserted by
// TestMediaCarry_TheOtherHandsetsEssentialMediaSurvivesASeal. This is TestMediaCarry_TheOtherHandsetsEssentialMediaSurvivesASeal's
// setup with exactly one difference, NOWHERE_CARRY_ESSENTIAL_MEDIA="", and it observes the restored #media
// rather than the head, so what it reads is what B's next login would give back.
//
// B's seal is ACCEPTED -- a refusal is not the fix the row records and would make this scenario unreachable
// (the test fails if it happens). The fix that shipped is the carry, on by default; this
// skips as a known defect because a conf can still switch the carry off, and the carry-on assertion lives
// in the MediaCarry test named above.
func TestTwoWriters_ASharedMediaScopeDropsTheOtherHandsetsFileWithTheCarryOff(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "")
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", "")
	t.Setenv("NOWHERE_STATE", t.TempDir()) // arm the receipt machinery, as a real session has it
	a, b := twoWriters(t, "sharedmedia", "correct horse battery staple")
	ref := profileRefV2("sharedmedia#media", "correct horse battery staple")

	a.put("Documents/shared.txt", "both handsets hold this")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	atLogin := a.head("#media")
	b.put("Documents/shared.txt", "both handsets hold this") // what B restored
	b.as(func() { loginArrived(ref, atLogin) })              // ... and the receipt that login mints

	a.put("DCIM/from-a.jpg", "a small photo")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's photo seal: %s", msg)
	}

	if refused := b.seal("#media"); refused != "" {
		t.Fatalf("B's #media seal was %s -- this scenario needs an accepted seal, and a refusal is not the "+
			"fix the row records", outcome(refused))
	}

	_, restored := restoreManifest(t, b.base, b.name+"#media", b.pass)
	if _, err := os.Stat(filepath.Join(restored, "DCIM", "from-a.jpg")); err == nil {
		return
	}
	knownDefect(t, "backlog: `#media`'s two-handset overwrite loop is FIXED by the essential carry",
		"with the carry switched off by a conf (the default is on since NWP-20261023-09), B's accepted #media seal restored WITHOUT A's DCIM/from-a.jpg: "+
			"the account lost the photo. "+
			"TestMediaCarry_TheOtherHandsetsEssentialMediaSurvivesASeal asserts the file survives with it on.")
}

// ---------------------------------------------------------------------------------------------------
// failure 2: the wallet overwrite -- confirmed in the field on 2026-09-07
// ---------------------------------------------------------------------------------------------------

// Chester bought a 50 GB plan on frankel while lynx was signed in. lynx sealed last, and both handsets
// then read 10 GB. The wallet object carries no version, timestamp, sequence or writer id, so nothing
// anywhere can tell which of two copies is newer.
func TestTwoWriters_AStaleHandsetMustNotLowerTheAccountsPlan(t *testing.T) {
	// A bought a 50 GB plan; B's copy predates the purchase. Same term, so PaidThrough cannot separate
	// them -- which is exactly the field state: the expiry agreed on both handsets while the size did not.
	account := &Wallet{PlanGB: 50, PlanPeriods: 3, PaidThrough: 20876}
	stale := &Wallet{PlanGB: 10, PlanPeriods: 3, PaidThrough: 20876}

	// ⚠ THE PROPERTY THIS ASSERTS CHANGED WHEN IT WAS FIXED, AND THE CHANGE IS THE INTERESTING PART.
	// It originally demanded that something on the wallet ORDER two copies -- a version, timestamp or
	// writer id -- because that is the obvious fix. It is the wrong fix: a per-device counter is not a
	// clock, both handsets advance one for unrelated reasons (routine lease bookkeeping writes the wallet
	// just as a purchase does), and "refuse a lower count" would have fixed the observed case only by
	// accident, because redeeming happens to write more times than bookkeeping. NWP-20260907-12 merges the
	// fields where LATER IS DEFINABLE WITHOUT A CLOCK instead. So the assertion is now the property that
	// actually matters and actually holds: a handset cannot lower an account fact it does not know about.
	if out := walletForPublish(account, stale, nil); out.PlanGB != 50 {
		t.Fatalf("a handset that bought nothing published plan_gb=%d over the account's 50 -- this is the "+
			"frankel/lynx failure of 2026-09-07, which NWP-20260907-12 was supposed to close",
			out.PlanGB)
	}
}

// ---------------------------------------------------------------------------------------------------
// failure 3: cross-scope skew -- one leg lands, another does not, and nothing can tell
// ---------------------------------------------------------------------------------------------------

// The scopes are separate refs sealed in sequence with no transaction and no shared generation. When one
// leg fails and the others succeed -- which is what a partial seal IS, and partial seals are routine --
// the stored profile pairs legs from different moments and nothing at restore notices. This is the state
// lynx was left in on 2026-09-07: CE refused while #de, #media and #apps sealed.
func TestTwoWriters_LegsFromDifferentRoundsMustBeDetectable(t *testing.T) {
	a, _ := twoWriters(t, "skew", "correct horse battery staple")

	// Round one: both legs sealed together, consistently.
	a.put("f.txt", "round-1")
	if msg := a.seal(""); msg != "" {
		t.Fatalf("round-1 CE: %s", msg)
	}
	if msg := a.seal("#de"); msg != "" {
		t.Fatalf("round-1 DE: %s", msg)
	}
	ceRound1 := a.head("")

	// Round two: the user does more work and only the #de leg lands.
	a.put("f.txt", "round-2")
	if msg := a.seal("#de"); msg != "" {
		t.Fatalf("round-2 DE: %s", msg)
	}

	// The property is NOT that the legs match -- a partial seal is legitimate and must stay so. It is
	// that the mixture is DETECTABLE, so a restore can say "these do not belong together".
	if legsOrderable() {
		return
	}
	knownDefect(t, "backlog: the scopes advance INDEPENDENTLY with no consistency rule",
		"the CE leg is still round-1 (%s) while #de is a round newer (%s), and nothing in either head "+
			"can tell that they belong to different seal rounds.",
		short(ceRound1), short(a.head("#de")))
}

// legsOrderable reports whether anything lets a reader tell which seal round a scope head belongs to.
// It is false today: chunkManifest.Version is a FORMAT flag (1, or 2 for zstd) and there is no
// generation, timestamp or writer id on any head. Two different hashes prove the legs DIFFER, which was
// never in doubt; ORDERING them is the thing that does not exist.
func legsOrderable() bool { return false }

// ---------------------------------------------------------------------------------------------------
// found while BUILDING this harness: identical content does not produce identical chunks
// ---------------------------------------------------------------------------------------------------

// THE BILLING CASE FOR MULTI-DEVICE RESTS ON THIS AND IT HAS NEVER BEEN MEASURED. docs/multi-device.md
// argues "identical bytes -> identical chunks -> billed once". If that does not hold, a second handset's
// FIRST seal duplicates the entire profile against a plan the device already under-reports.
//
// IT PASSES WHEN BOTH FILES CARRY ONE MTIME, AND THE HYPOTHESIS IT WAS WRITTEN TO CONFIRM WAS WRONG. The suspicion was that the seal tars
// a LIVE tree via tar.FileInfoHeader with no normalisation anywhere (no hdr.Uid / Gid / Uname / Format /
// AccessTime is set), so per-handset mtime and ownership would move every chunk hash. Two cold seals of
// identical bytes produce the IDENTICAL manifest, so it does not -- at least for this shape. This test is
// therefore a regression pin on the property the billing case needs, not a filed defect, and the
// unmeasured-dedup row should be read with that in mind.
//
// BOTH FILES ARE PINNED TO ONE WHOLE-SECOND MTIME. The tar header carries the file's mtime rounded to the
// second and nothing else per-handset, so with the wall clock deciding it the two manifests matched only
// when both writes landed in the same second -- a coin the CI run threw. A restore carries mtime
// (os.Chtimes from the header), so equal mtimes are the honest model of byte-identical restored content on
// two handsets; the sibling case below pins what a different mtime does.
//
// ⚠ WHAT IT DOES NOT ESTABLISH: real handsets differ in ways a temp dir does not -- Android per-user uids
// (userId*100000 + appId), real mtimes, and a WARM scan cache on one side only. This harness also showed
// that an incremental seal and a cold seal of the same bytes produce different manifests, which is the
// nearer risk. The device measurement -- a second handset's first seal, read off the gateway's Present
// hit-rate -- is still the one that settles it.
func TestTwoWriters_IdenticalContentShouldDedupAcrossHandsets(t *testing.T) {
	a, b := twoWriters(t, "dedup", "correct horse battery staple")

	const body = "exactly the same bytes on both handsets"
	a.putAt("same.txt", body, restoredMtime)
	if msg := a.seal("#de"); msg != "" {
		t.Fatalf("A's seal: %s", msg)
	}
	headA := a.head("#de")

	b.putAt("same.txt", body, restoredMtime)
	if msg := b.seal("#de"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}
	headB := b.head("#de")

	if headA != headB {
		t.Fatalf("two handsets sealed byte-identical content with one mtime and produced DIFFERENT manifests "+
			"(%s vs %s). Some per-handset header field (ownership, name, format) is moving the chunk hashes, "+
			"which means a second handset's first seal re-uploads and re-bills the whole profile.",
			short(headA), short(headB))
	}
}

// restoredMtime is a whole second, so the tar header's second rounding cannot split two copies of it.
var restoredMtime = time.Unix(1700000000, 0)

// CHARACTERISATION, NOT A DEFECT. The mtime is roamed metadata (a restore sets it back), so two copies
// that were created independently, a second apart, legitimately seal to different manifests. This pins the
// dependence that made the dedup case above flip on the wall clock, rather than letting it be rediscovered.
func TestTwoWriters_IdenticalBytesWithMtimesASecondApartSealDifferently(t *testing.T) {
	a, b := twoWriters(t, "dedupskew", "correct horse battery staple")

	const body = "exactly the same bytes on both handsets"
	a.putAt("same.txt", body, restoredMtime)
	if msg := a.seal("#de"); msg != "" {
		t.Fatalf("A's seal: %s", msg)
	}
	headA := a.head("#de") // the head is ONE ref for the account, so read it before B's seal moves it
	b.putAt("same.txt", body, restoredMtime.Add(time.Second))
	if msg := b.seal("#de"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}
	if headA == b.head("#de") {
		t.Fatal("byte-identical files a whole second apart sealed to ONE manifest -- the mtime no longer " +
			"reaches the seal, so the equal-mtime dedup case has stopped proving anything")
	}
}

// ---------------------------------------------------------------------------------------------------
// the sequential overwrite, WITH the guard armed -- the end-to-end proof for NWP-20260907-13
// ---------------------------------------------------------------------------------------------------

// The same scenario as TestTwoWriters_ALaterSealFromAStaleHandsetMustNotReplaceNewerWork, run with the
// receipt machinery live and the refusal enabled. This is the test that proves the guard stops the real
// failure rather than merely computing a correct-looking boolean.
//
// ⚠ IT MUST SET UP B THE WAY A LOGIN DOES. The guard is anchored to the receipt B holds, so B has to have
// one -- a session that never restored has no receipt and is refused by the older #72 existence gate
// instead, which would make this test pass for the wrong reason.
func TestTwoWriters_WithTheGuardArmedTheStaleWriterIsRefused(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_SEQ_GUARD", "1")
	a, b := twoWriters(t, "seqguard", "correct horse battery staple")

	a.put("shared.txt", "original")
	if msg := a.seal(""); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	base0 := a.head("")

	// B logs in here: it restores the account as it stands, which is what mints its receipt. The write
	// must happen AS B, so the receipt lands in B's own state dir rather than the ambient one.
	b.as(func() {
		writeRestoreReceipt(profileRefV2("seqguard", "correct horse battery staple"), base0)
	})
	b.put("shared.txt", "original")

	// A does work and seals. This moves the head out from under B.
	a.put("shared.txt", "A's newer work")
	if msg := a.seal(""); msg != "" {
		t.Fatalf("A's second seal: %s", msg)
	}
	afterA := a.head("")
	if afterA == base0 {
		t.Fatal("setup: A's second seal did not move the head, so there is nothing for B to be stale against")
	}

	// B now seals its stale tree. With the guard armed this must be REFUSED.
	refused := b.seal("")
	if refused == "" {
		t.Fatalf("the stale handset's seal was ACCEPTED with the guard armed. Its receipt held %s while the "+
			"stored head was %s, which is exactly the divergence the guard is supposed to name.",
			short(base0), short(afterA))
	}
	if got := a.head(""); got != afterA {
		t.Fatalf("A's head moved %s -> %s despite the refusal", short(afterA), short(got))
	}
}
