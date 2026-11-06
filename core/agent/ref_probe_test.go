package main

import (
	"sync/atomic"
	"testing"
)

// NWP-20260820-28. refProbe fuses the "does this ref exist" probe with the "what is its value" read, because
// in cap mode they are literally the same request. These tests pin the two things that made that safe to do:
//
//  1. the (exists, val) PAIR survives -- ("", true) is a delete TOMBSTONE and ("", false) is absent (#19/#139).
//     Collapsing those is a #139-class bug: a deleted profile would restore its scopes again, or a throwaway
//     would stop being indistinguishable from a deleted one.
//  2. the fusion is CAP-MODE ONLY. On the other backends refProbe must report haveVal=false so the caller
//     still does its own read -- there s3Exists is a best-effort STAT that falls through to false on a
//     persistent transient error while s3Get check-FAILS, and quietly fusing them would convert a flaky
//     network into a hard failure on the login path.

// storeReads snapshots the instrumented store-read counter (NWP-20260820-27).
func storeReads() int64 { return atomic.LoadInt64(&traceGetN) }

func TestRefProbeCapModeFusesReadAndPreservesTombstone(t *testing.T) {
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	capReadCache = map[string]capEntry{}
	if !capMode() {
		t.Fatal("expected cap mode")
	}

	mu.Lock()
	objs["ref/live"] = []byte("headhash999\n")
	objs["ref/tomb"] = []byte("") // delRef overwrites to empty -> exists, but empty == TOMBSTONE
	mu.Unlock()

	// a live ref: one read, and the value comes back with it.
	before := storeReads()
	ex, val, have := refProbe("s3", "live")
	if !ex || val != "headhash999" || !have {
		t.Fatalf("live ref: got (exists=%v, val=%q, haveVal=%v), want (true, headhash999, true)", ex, val, have)
	}
	if n := storeReads() - before; n != 1 {
		t.Fatalf("live ref cost %d store reads, want exactly 1 -- the whole point of the fusion", n)
	}

	// a TOMBSTONE: exists, value empty. This is the distinction #139 turns on.
	if ex, val, have = refProbe("s3", "tomb"); !ex || val != "" || !have {
		t.Fatalf("tombstone: got (exists=%v, val=%q, haveVal=%v), want (true, \"\", true)", ex, val, have)
	}

	// ABSENT: must be distinguishable from the tombstone above, or blind login breaks.
	if ex, val, have = refProbe("s3", "nobody"); ex || val != "" || !have {
		t.Fatalf("absent: got (exists=%v, val=%q, haveVal=%v), want (false, \"\", true)", ex, val, have)
	}
}

func TestRefProbeNonCapDoesNotFuse(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("GATEWAY_URL", "") // plain-HTTP backend -> not cap mode
	t.Setenv("S3_ACCESS_KEY", "")

	putRef(base, "live", "headhash999")

	// haveVal MUST be false here: the caller has to do its own read, exactly as before this change.
	ex, val, have := refProbe(base, "live")
	if !ex {
		t.Fatal("live ref should report exists on the plain-HTTP backend")
	}
	if have {
		t.Fatal("non-cap refProbe must NOT claim to have the value -- that would skip the caller's read")
	}
	if val != "" {
		t.Fatalf("non-cap refProbe returned a value %q; it must leave the read to the caller", val)
	}
	if got := getRef(base, "live"); got != "headhash999" {
		t.Fatalf("caller's own read = %q, want headhash999", got)
	}
	if ex, _, _ = refProbe(base, "nobody"); ex {
		t.Fatal("absent ref should report exists=false")
	}
}

// headKey is now a wrapper over headRef. If the two ever disagree, every existing headKey caller is reading a
// different head from the one the restore path resolves -- which is a silent wrong-data bug, not a crash.
func TestHeadKeyAgreesWithHeadRef(t *testing.T) {
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}

	const name, pass = "agree", "correct horse battery staple"

	// brand-new profile: nothing exists yet, so both must name the ref WRITES will land at.
	ref, val, have := headRef("s3", name, pass)
	if got := headKey("s3", name, pass); got != ref {
		t.Fatalf("brand-new: headKey=%q headRef=%q -- must agree", got, ref)
	}
	if val != "" {
		t.Fatalf("brand-new: headRef returned value %q, want empty", val)
	}
	_ = have

	// now publish a head at the v2 ref and re-check.
	mu.Lock()
	objs["ref/"+profileRefV2(name, pass)] = []byte("thehead\n")
	mu.Unlock()
	capReadCache = map[string]capEntry{}

	ref, val, have = headRef("s3", name, pass)
	if ref != profileRefV2(name, pass) {
		t.Fatalf("headRef picked %q, want the v2 ref", ref)
	}
	if !have || val != "thehead" {
		t.Fatalf("headRef gave (val=%q, haveVal=%v), want (thehead, true)", val, have)
	}
	if got := headKey("s3", name, pass); got != ref {
		t.Fatalf("published: headKey=%q headRef=%q -- must agree", got, ref)
	}
}
