package main

import (
	"os"
	"path/filepath"
	"testing"
)

// NWP-20260906-04. Two devices signed into one profile resolve byte-identical refs, and the seal is a
// read-modify-write with no re-check between the sample and the publish -- the same window #144's fence
// documents for DELETE, left open for the other writer. Each device replaced the other's whole scope every
// sync, both printed success, and for a SCOPE head (a bare manifest, no rollback history) the loss was
// unrecoverable.
//
// These pin the guard: a publish whose head moved under it is REFUSED, the stored copy is left intact, and
// the refusal is reported rather than counted as a seal.

// TestStalePublishRefusesAHeadThatMovedUnderTheSeal is the guard. Sample, let "the other device" advance the
// ref, then try to publish: the stored value must survive and the refusal must be recorded.
func TestStalePublishRefusesAHeadThatMovedUnderTheSeal(t *testing.T) {
	base := newHTTPStore(t)
	clearSealExpectations()
	defer clearSealExpectations()

	ref := "somescopehead"
	putRef(base, ref, "head-A") // what this seal reads
	expectRef(ref, getRef(base, ref))

	putRef(base, ref, "head-B") // the OTHER device seals while we walk and upload
	if got := getRef(base, ref); got != "head-B" {
		t.Fatalf("fixture: store holds %q, want head-B", got)
	}

	if !stalePublish(base, ref, "test") {
		t.Fatal("a head that moved from head-A to head-B was NOT detected -- this seal would overwrite the " +
			"other device's whole scope, and for a scope head there is no rollback snapshot to recover from")
	}
	if !sealStaleHit {
		t.Fatal("sealStaleHit not set: the refusal would not reach the exit code, so a refused seal would be " +
			"reported to the daemon as a successful one (#111)")
	}
}

// TestStalePublishAllowsAnUnmovedHead is the other half. The guard must not refuse the ordinary case, or
// every seal on every device stops.
func TestStalePublishAllowsAnUnmovedHead(t *testing.T) {
	base := newHTTPStore(t)
	clearSealExpectations()
	defer clearSealExpectations()

	ref := "steadyhead"
	putRef(base, ref, "head-A")
	expectRef(ref, getRef(base, ref))

	if stalePublish(base, ref, "test") {
		t.Fatal("an UNCHANGED head was reported stale -- this would refuse every ordinary seal")
	}
	if sealStaleHit {
		t.Fatal("sealStaleHit set for a head that never moved")
	}
}

// TestStalePublishIgnoresUnarmedRefs. Only the scope heads a seal actually READ are guarded. Recovery refs,
// anchors and tombstones publish through untouched -- guarding them would refuse writes this seal never
// made a reading of, which is a guess, not a check.
func TestStalePublishIgnoresUnarmedRefs(t *testing.T) {
	base := newHTTPStore(t)
	clearSealExpectations()
	defer clearSealExpectations()

	putRef(base, "unarmed", "whatever")
	if stalePublish(base, "unarmed", "test") {
		t.Fatal("an unarmed ref was reported stale; only refs this seal sampled may be judged")
	}
}

// TestStalePublishTreatsAReadFailureAsNotMoved. A transient store failure must not refuse the seal: on an
// amnesiac device a refused logoff costs the session, and silence is not evidence that anyone moved it.
func TestStalePublishTreatsAReadFailureAsNotMoved(t *testing.T) {
	clearSealExpectations()
	defer clearSealExpectations()

	// A base that cannot be reached at all -- getRef against it fails rather than answering.
	dead := "http://127.0.0.1:1"
	expectRef("someref", "head-A")
	if stalePublish(dead, "someref", "test") {
		t.Fatal("an unreachable store was treated as a MOVED head -- a network blip would refuse the logoff " +
			"seal, and on an amnesiac device that costs the session")
	}
	if sealStaleHit {
		t.Fatal("sealStaleHit set by a read failure")
	}
}

// TestPushRefusesWhenTheHeadMovedUnderIt drives the real seal path end to end on the direct (non-cap)
// backend: push a profile, move its head from underneath mid-seal, and require the stored head to survive.
func TestPushRefusesWhenTheHeadMovedUnderIt(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "stalepush", "correct horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("first"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)

	ref := headKey(base, name, pass)
	mine := getRef(base, ref)
	if mine == "" {
		t.Fatal("fixture: no head after the first push")
	}

	// Arm as though a seal had just sampled the head, then let the OTHER device publish.
	clearSealExpectations()
	defer clearSealExpectations()
	expectRef(ref, mine)
	putRef(base, ref, "other-device-head")

	// This is the publish the guard must refuse.
	putRef(base, ref, "my-stale-head")

	if got := getRef(base, ref); got != "other-device-head" {
		t.Fatalf("head is now %q -- the stale publish went through and discarded the other device's seal", got)
	}
	if !sealStaleHit {
		t.Fatal("the refusal was not recorded, so `push` would exit 0 and the daemon would call this a seal")
	}
}
