package main

import "testing"

// NWP-20260829-27. mediad now POLLS the pin file, because the chooser's PIN-MATERIALIZE signal is inert
// while the daemon is running: init ignores ctl.start for a service that is already up, and mediad is up for
// the whole session. The poll re-runs materializePins only when the set CHANGED, so the change detector has
// to be stable -- and loadPins returns a MAP, whose iteration order Go deliberately randomises.
//
// Without sort.Strings the fingerprint varies run to run, every poll looks like a change, and mediad re-walks
// the whole deferred set every 20 seconds forever.
func TestPinsFingerprintIsStableAcrossMapOrder(t *testing.T) {
	pins := map[string]bool{}
	for _, a := range []string{
		"com.whatsapp", "app.organicmaps", "com.example.a", "com.example.b", "com.example.c",
		"com.example.d", "com.example.e", "com.example.f", "com.example.g", "com.example.h",
	} {
		pins[a] = true
	}

	want := pinsFingerprint(pins)
	if want == "" {
		t.Fatal("a non-empty pin set must not fingerprint empty -- the poll treats empty as 'nothing pinned'")
	}
	// Go randomises map iteration per range. Over this many passes an unsorted join diverges with
	// overwhelming probability, so a stable result here is real evidence of ordering, not luck.
	for i := 0; i < 200; i++ {
		if got := pinsFingerprint(pins); got != want {
			t.Fatalf("fingerprint is order-dependent: pass %d gave %q, want %q", i, got, want)
		}
	}

	// Distinct sets must be distinguishable, else an unpin would not be seen as a change.
	if pinsFingerprint(map[string]bool{"a": true}) == pinsFingerprint(map[string]bool{"b": true}) {
		t.Error("different pin sets share a fingerprint -- a change would be invisible to the poll")
	}
	// Subset vs superset: removing one app must register.
	full := map[string]bool{"a": true, "b": true}
	part := map[string]bool{"a": true}
	if pinsFingerprint(full) == pinsFingerprint(part) {
		t.Error("removing an app did not change the fingerprint -- an unpin would never park the fetch")
	}
	// Empty is the sentinel the poll uses for "nothing pinned"; it must stay empty.
	if pinsFingerprint(map[string]bool{}) != "" {
		t.Error("an empty pin set must fingerprint empty")
	}
}
