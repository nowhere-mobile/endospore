package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261122-12 (Q026, docs/product-decisions.md, 2026-10-20): the SSAID userkey every app's ANDROID_ID
// derives from is recorded in the vault's key-sealed scope index (!ssaid) at the first bare seal, carried
// through every rotation and recovery, and seeded from there. These tests pin each writer, the carry, the
// reader, and the blind read for a blank. Every test has its own profile name, so the blob and content
// caches cannot make one test believe another's blobs exist.

// ssidxStore stands up a fresh store, resets the DK-keyed caches, and points SEED-SSAID's read at the store.
func ssidxStore(t *testing.T) string {
	t.Helper()
	base := newHTTPStore(t)
	blobCache = nil
	contentCache = nil
	was := seedSsaidStore
	seedSsaidStore = base
	t.Cleanup(func() { seedSsaidStore = was })
	return base
}

// ssidxCreate creates (name, pass) and returns its 12 words.
func ssidxCreate(t *testing.T, base, name, pass string) string {
	t.Helper()
	m := createVault(base, name, pass)
	if m == "" {
		t.Fatal("createVault returned no recovery code")
	}
	return m
}

// ssidxSeal makes one BARE seal of (name, pass).
func ssidxSeal(t *testing.T, base, name, pass string) {
	t.Helper()
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, d)
}

// ssidxIndex opens (name, pass)'s bare vault index.
func ssidxIndex(t *testing.T, base, name, pass string) map[string]scopeRec {
	t.Helper()
	dk, _, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatalf("%q does not resolve", name)
	}
	v, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV {
		t.Fatalf("%q: the head is not a vault", name)
	}
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatalf("%q: the vault carries no scope index", name)
	}
	return idx
}

func ssidxDerived(name, pass string) string { return ssaidUserKey(deriveKey(name, pass)) }

func TestSsaidRecordedAtFirstBareSeal(t *testing.T) {
	base := ssidxStore(t)
	const name, pass = "ssidxseal", "first passphrase one"
	ssidxCreate(t, base, name, pass)
	if got := ssaidOf(ssidxIndex(t, base, name, pass)); got != "" {
		t.Fatalf("createVault recorded an SSAID userkey (%d chars); the record belongs to the first seal", len(got))
	}
	ssidxSeal(t, base, name, pass)
	if got, want := ssaidOf(ssidxIndex(t, base, name, pass)), ssidxDerived(name, pass); got != want {
		t.Fatalf("after the first bare seal the index records %q, want the passphrase-derived userkey", got)
	}
}

func TestSsaidSurvivesRotation(t *testing.T) {
	base := ssidxStore(t)
	const name, p1, p2 = "ssidxrot", "first passphrase one", "second passphrase two"
	ssidxCreate(t, base, name, p1)
	ssidxSeal(t, base, name, p1)
	if _, err := rotateVault(base, name, p1, p2, nil, false); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	got := seedSsaidKey(name, p2)
	if got != ssidxDerived(name, p1) {
		t.Fatal("after a passphrase change SEED-SSAID does not seed the OLD userkey: every app's id changes")
	}
	if got == ssidxDerived(name, p2) {
		t.Fatal("control: the seeded key equals the new passphrase's derived key")
	}
}

func TestSsaidSurvivesTwoRotations(t *testing.T) {
	base := ssidxStore(t)
	const name, p1, p2, p3 = "ssidxrot2", "first passphrase one", "second passphrase two", "third passphrase three"
	ssidxCreate(t, base, name, p1)
	ssidxSeal(t, base, name, p1)
	if _, err := rotateVault(base, name, p1, p2, nil, false); err != nil {
		t.Fatalf("rotateVault p1->p2: %v", err)
	}
	if _, err := rotateVault(base, name, p2, p3, nil, false); err != nil {
		t.Fatalf("rotateVault p2->p3: %v", err)
	}
	if got := seedSsaidKey(name, p3); got != ssidxDerived(name, p1) {
		t.Fatalf("after two changes the seeded key is not the first passphrase's (p2's: %v, p3's: %v)",
			got == ssidxDerived(name, p2), got == ssidxDerived(name, p3))
	}
}

func TestSsaidRotationBeforeAnySealRecordsOldKey(t *testing.T) {
	base := ssidxStore(t)
	const name, p1, p2 = "ssidxrotfirst", "first passphrase one", "second passphrase two"
	ssidxCreate(t, base, name, p1)
	if _, err := rotateVault(base, name, p1, p2, nil, false); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	if got := seedSsaidKey(name, p2); got != ssidxDerived(name, p1) {
		t.Fatal("a change before any seal did not record the key of the passphrase it moved off")
	}
}

func TestSsaidSurvivesRecovery(t *testing.T) {
	base := ssidxStore(t)
	const name, p1, p2 = "ssidxrec", "first passphrase one", "recovered passphrase two"
	words := ssidxCreate(t, base, name, p1)
	ssidxSeal(t, base, name, p1)
	if err := recoverVault(base, name, words, p2); err != nil {
		t.Fatalf("recoverVault: %v", err)
	}
	got := seedSsaidKey(name, p2)
	if got != ssidxDerived(name, p1) {
		t.Fatal("after a 12-word recovery SEED-SSAID does not seed the recorded userkey")
	}
	if got == ssidxDerived(name, p2) {
		t.Fatal("control: the seeded key equals the new passphrase's derived key")
	}
}

func TestSsaidLaterSealDoesNotOverwrite(t *testing.T) {
	base := ssidxStore(t)
	const name, p1, p2 = "ssidxkeep", "first passphrase one", "second passphrase two"
	ssidxCreate(t, base, name, p1)
	ssidxSeal(t, base, name, p1)
	if _, err := rotateVault(base, name, p1, p2, nil, false); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	ssidxSeal(t, base, name, p2)
	got := ssaidOf(ssidxIndex(t, base, name, p2))
	if got != ssidxDerived(name, p1) {
		t.Fatalf("a seal under the new passphrase overwrote the record (new key: %v)", got == ssidxDerived(name, p2))
	}
}

// ssidxCountReads wraps seedSsaidRead with a call counter.
func ssidxCountReads(t *testing.T) *atomic.Int64 {
	t.Helper()
	var n atomic.Int64
	was := seedSsaidRead
	seedSsaidRead = func(base, nm, pw string) string {
		n.Add(1)
		return was(base, nm, pw)
	}
	t.Cleanup(func() { seedSsaidRead = was })
	return &n
}

// A blank pays the same read a real profile does. Counted at the read hook, not in store requests: the
// head-prefetch goroutine makes the request count depend on thread interleaving.
func TestSsaidBlankGetsDefaultAndStillReads(t *testing.T) {
	base := ssidxStore(t)
	const name, p1, p2 = "ssidxblank", "first passphrase one", "second passphrase two"
	ssidxCreate(t, base, name, p1)
	ssidxSeal(t, base, name, p1)
	if _, err := rotateVault(base, name, p1, p2, nil, false); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	n := ssidxCountReads(t)
	for _, c := range []struct{ what, nm, pw, want string }{
		{"a real profile", name, p2, ssidxDerived(name, p1)},
		{"an unknown name", "ssidxnobody", p2, ssidxDerived("ssidxnobody", p2)},
		{"a wrong passphrase", name, "not the passphrase", ssidxDerived(name, "not the passphrase")},
	} {
		before := n.Load()
		if got := seedSsaidKey(c.nm, c.pw); got != c.want {
			t.Errorf("%s: seeded the wrong key", c.what)
		}
		if d := n.Load() - before; d != 1 {
			t.Errorf("%s: the vault read ran %d times, want 1 -- a blank must pay the same read", c.what, d)
		}
	}
}

func TestSsaidUnreachableStoreGetsDefault(t *testing.T) {
	ssidxStore(t)
	const name, pass = "ssidxdown", "first passphrase one"
	want := ssidxDerived(name, pass)
	was, wasWin := seedSsaidRead, seedSsaidReadWindow
	t.Cleanup(func() { seedSsaidRead, seedSsaidReadWindow = was, wasWin })

	seedSsaidRead = func(string, string, string) string { return "" } // the store answered nothing
	if got := seedSsaidKey(name, pass); got != want {
		t.Error("a failed read did not seed the derived key")
	}
	seedSsaidRead = func(string, string, string) string { panic("store unreachable") }
	if got := seedSsaidKey(name, pass); got != want {
		t.Error("a read that panicked did not seed the derived key")
	}
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	seedSsaidReadWindow = 50 * time.Millisecond
	seedSsaidRead = func(string, string, string) string { <-release; return strings.Repeat("A", 64) }
	if got := seedSsaidKey(name, pass); got != want {
		t.Error("a read that outlived the window did not seed the derived key")
	}
}

// The record is a reserved key: the scope walkers skip it, so a profile carrying it still rotates and
// recovers, and every real scope lands at the final passphrase's ref.
func TestSsaidRecordDoesNotBreakRotateOrRecover(t *testing.T) {
	if isScopeSuffix(scopeSsaidKey) {
		t.Fatal("isScopeSuffix(!ssaid) is true: the scope walkers would treat the SSAID record as a scope")
	}
	base := ssidxStore(t)
	const name, p1, p2, p3 = "ssidxwalk", "first passphrase one", "second passphrase two", "third passphrase three"
	words := ssidxCreate(t, base, name, p1)
	ssidxSeal(t, base, name, p1)
	if ssaidOf(ssidxIndex(t, base, name, p1)) == "" {
		t.Fatal("precondition: the seal recorded no SSAID userkey")
	}
	if _, err := rotateVault(base, name, p1, p2, nil, false); err != nil {
		t.Fatalf("rotateVault with the record present: %v", err)
	}
	if err := recoverVault(base, name, words, p3); err != nil {
		t.Fatalf("recoverVault with the record present: %v", err)
	}
	idx := ssidxIndex(t, base, name, p3)
	for _, suf := range scopeIndexSuffixes {
		if want, _ := headWriteRef(name+suf, p3); idx[suf].Ref != want {
			t.Errorf("%s: the index names %q, want the final passphrase's ref", suf, idx[suf].Ref)
		}
	}
	if ssaidOf(idx) != ssidxDerived(name, p1) {
		t.Error("the record did not survive a rotation followed by a recovery")
	}
}

func TestSsaidOfRejectsMalformed(t *testing.T) {
	good := strings.Repeat("0123456789ABCDEF", 4)
	if got := ssaidOf(map[string]scopeRec{scopeSsaidKey: ssaidRec(good)}); got != good {
		t.Fatalf("a well-formed record reads back %q", got)
	}
	for what, ref := range map[string]string{
		"no p2: prefix": good,
		"lower-case":    billRefPrefix + strings.ToLower(good),
		"63 chars":      billRefPrefix + good[:63],
		"65 chars":      billRefPrefix + good + "A",
		"not hex":       billRefPrefix + good[:63] + "G",
	} {
		if got := ssaidOf(map[string]scopeRec{scopeSsaidKey: {Ref: ref}}); got != "" {
			t.Errorf("%s: ssaidOf = %q, want \"\"", what, got)
		}
	}
	if got := ssaidOf(map[string]scopeRec{}); got != "" {
		t.Errorf("a missing record reads back %q", got)
	}
}
