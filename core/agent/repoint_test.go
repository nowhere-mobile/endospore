package main

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// readHead reads a head the way the agent does. headRef alone is NOT enough: it returns the VALUE only on
// cap backends, so on the test store its val is always "" -- the same trap that was in the first cut of
// repointScopeHead, and the reason these tests failed twice before the code was right.
func readHead(base, name, pass string) string {
	ref, val, have := headRef(base, name, pass)
	if have {
		return val
	}
	return getRef(base, ref)
}

// sealManifest writes a chunk manifest sealed for (name, pass) and returns its hash -- the same shape
// pushProfile's scope branch writes.
func sealManifest(t *testing.T, base, name, pass string, chunks []string) string {
	t.Helper()
	m := chunkManifest{Version: 1, Chunks: chunks}
	body, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return postBlob(base, seal(deriveKey(name, pass), append(append([]byte{}, cdcMagic...), body...)))
}

// The happy path: a scope head moves to a manifest this profile owns, and the OLD hash comes back so the
// operator can undo. Undo is the point of the verb -- a recovery tool that cannot be reversed is another
// way to lose the head.
func TestRepointScopeHeadRoundTrip(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "acct#media", "correct horse battery staple"

	good := sealManifest(t, base, name, pass, []string{"aa", "bb"})
	bad := sealManifest(t, base, name, pass, []string{"cc"})
	putHead(base, name, pass, bad) // the bad seal is live

	old, m, err := repointScopeHead(base, name, pass, good)
	if err != nil {
		t.Fatalf("repoint: %v", err)
	}
	if old != bad {
		t.Fatalf("returned old head %q, want the bad head %q", short(old), short(bad))
	}
	if len(m.Chunks) != 2 {
		t.Fatalf("reported %d chunks, want 2 -- the verb must describe what it moved TO", len(m.Chunks))
	}
	if cur := readHead(base, name, pass); cur != good {
		t.Fatalf("head is %q, want %q", short(cur), short(good))
	}
	// ...and the undo the CLI prints actually works.
	if _, _, err := repointScopeHead(base, name, pass, old); err != nil {
		t.Fatalf("undo: %v", err)
	}
	if cur := readHead(base, name, pass); cur != bad {
		t.Fatal("undo did not restore the previous head")
	}
}

// Each guard must fire for its OWN reason. A recovery tool that reports one generic failure teaches the
// operator nothing, and the wrong-passphrase case in particular must not read as "that hash is bad".
func TestRepointScopeHeadGuards(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "acct#media", "correct horse battery staple"
	good := sealManifest(t, base, name, pass, []string{"aa"})
	putHead(base, name, pass, good)

	// A vault head is NOT in scope: it has snapshots and a real rollback, and this verb must not bypass it.
	if _, _, err := repointScopeHead(base, "acct", pass, good); err != errRepointNotScope {
		t.Fatalf("bare name: got %v, want errRepointNotScope", err)
	}
	for _, bad := range []string{"", "deadbeef", strings.Repeat("g", 64), strings.Repeat("A", 64)} {
		if _, _, err := repointScopeHead(base, name, pass, bad); err != errRepointBadHash {
			t.Fatalf("hash %q: got %v, want errRepointBadHash", bad, err)
		}
	}
	// Well-formed hash, nothing behind it.
	if _, _, err := repointScopeHead(base, name, pass, strings.Repeat("ab", 32)); err != errRepointNoSuchRef {
		t.Fatalf("absent blob: got %v, want errRepointNoSuchRef", err)
	}
	// A blob that exists but is not sealed for this profile -- the case that makes validation an
	// AUTHORIZATION check. Sealed by a different passphrase, so its DK differs.
	foreign := sealManifest(t, base, name, "river maple stone cloud", []string{"zz"})
	if _, _, err := repointScopeHead(base, name, pass, foreign); err != errRepointForeign {
		t.Fatalf("foreign manifest: got %v, want errRepointForeign", err)
	}
	// Decrypts, but is not a manifest.
	notMan := postBlob(base, seal(deriveKey(name, pass), []byte("this is not a manifest")))
	if _, _, err := repointScopeHead(base, name, pass, notMan); err != errRepointNotMan {
		t.Fatalf("non-manifest: got %v, want errRepointNotMan", err)
	}
	// Idempotent.
	if _, _, err := repointScopeHead(base, name, pass, good); err != errRepointSame {
		t.Fatalf("same head: got %v, want errRepointSame", err)
	}
	// Every refusal above must have left the live head untouched.
	if cur := readHead(base, name, pass); cur != good {
		t.Fatalf("a refused repoint moved the head to %q", short(cur))
	}
}

// An EMPTY scope is a legitimate manifest, and the reason this verb does not reuse loadCDCManifest:
// that helper collapses a wrong key, a missing blob and an empty scope into the same empty struct.
func TestRepointScopeHeadAcceptsEmptyManifest(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "acct#apps", "correct horse battery staple"
	putHead(base, name, pass, sealManifest(t, base, name, pass, []string{"aa"}))

	empty := sealManifest(t, base, name, pass, nil)
	if _, m, err := repointScopeHead(base, name, pass, empty); err != nil {
		t.Fatalf("empty manifest refused: %v -- an empty scope is legal and must be repointable", err)
	} else if len(m.Chunks) != 0 {
		t.Fatalf("reported %d chunks for an empty manifest", len(m.Chunks))
	}
	// And loadCDCManifest genuinely cannot tell that case from a failure -- which is why we do not use it.
	if len(loadCDCManifest(base, deriveKey(name, pass), empty).Chunks) != 0 {
		t.Fatal("expected loadCDCManifest to report an empty manifest as empty")
	}
	if len(loadCDCManifest(base, deriveKey(name, "wrong pass"), empty).Chunks) != 0 {
		t.Fatal("expected loadCDCManifest to report a WRONG-KEY read as empty too -- the ambiguity this avoids")
	}
}

// sealRepointManifestKey is sealManifest with the key given: a re-keyed scope's manifests stay sealed under
// the ORIGINAL scope key, which no longer derives from the current passphrase.
func sealRepointManifestKey(t *testing.T, base string, key []byte, chunks []string) string {
	t.Helper()
	body, err := json.Marshal(chunkManifest{Version: 1, Chunks: chunks})
	if err != nil {
		t.Fatal(err)
	}
	return postBlob(base, seal(key, append(append([]byte{}, cdcMagic...), body...)))
}

// readRepointVault reads the scope head at (name, pass) and parses it as a vault; it fails the test when the
// head is not one.
func readRepointVault(t *testing.T, base, name, pass string) *vault {
	t.Helper()
	v, ok := parseVault(getBlob(base, readHead(base, name, pass)))
	if !ok {
		t.Fatalf("the head of %q is not a vault", name)
	}
	return v
}

// publishRepointVault posts v and points (name, pass)'s head at it -- what a rotation publishes. It returns
// the vault blob's hash.
func publishRepointVault(base, name, pass string, v *vault) string {
	vh := postBlob(base, serializeVault(v))
	putHead(base, name, pass, vh)
	return vh
}

// A scope a passphrase change re-pointed: its head is buildScopeVault's vault, whose pass slot wraps the
// ORIGINAL scope key under deriveKey(scoped, newpass). The verb must open the vault, validate under the key
// the slot holds, and publish a new vault -- not refuse every target as foreign, and not write it bare.
func TestRepointScopeHeadOnAReKeyedScope(t *testing.T) {
	base := newHTTPStore(t)
	const scoped, p1, p2 = "rkscope1#media", "first pass phrase words", "second pass phrase words"
	key := deriveKey(scoped, p1)
	m0 := sealRepointManifestKey(t, base, key, []string{"aa", "bb"})
	m1 := sealRepointManifestKey(t, base, key, []string{"cc"})
	publishRepointVault(base, scoped, p2, buildScopeVault(key, scoped, p2, m1))
	before := readRepointVault(t, base, scoped, p2)

	old, m, err := repointScopeHead(base, scoped, p2, m0)
	if err != nil {
		t.Fatalf("repoint of a re-keyed scope: %v", err)
	}
	if old != m1 {
		t.Fatalf("returned old %q, want the manifest the vault named %q -- the undo line must print a manifest", short(old), short(m1))
	}
	if len(m.Chunks) != 2 {
		t.Fatalf("reported %d chunks, want 2", len(m.Chunks))
	}
	k, _, _, ok := resolveKeyHead(base, scoped, p2)
	if !ok || !bytes.Equal(k, key) {
		t.Fatal("after the repoint the head no longer opens to the preserved scope key")
	}
	after := readRepointVault(t, base, scoped, p2)
	if after.Manifest != m0 {
		t.Fatalf("vault Manifest is %q, want %q", short(after.Manifest), short(m0))
	}
	if after.Version != before.Version+1 {
		t.Fatalf("vault Version is %d, want %d", after.Version, before.Version+1)
	}
	if !verifyVault(after, key) {
		t.Fatal("the new vault does not verify under the scope key")
	}
	if !reflect.DeepEqual(after.Slots, before.Slots) {
		t.Fatal("the repoint changed the vault's slots")
	}
	kept := false
	for _, h := range after.History {
		kept = kept || h.Manifest == m1
	}
	if !kept {
		t.Fatal("the replaced manifest is not in the vault's History")
	}
	// The undo the CLI prints restores the previous manifest.
	if _, _, err := repointScopeHead(base, scoped, p2, old); err != nil {
		t.Fatalf("undo: %v", err)
	}
	if v := readRepointVault(t, base, scoped, p2); v.Manifest != m1 {
		t.Fatalf("undo left Manifest %q, want %q", short(v.Manifest), short(m1))
	}
}

// Each refusal on a vault head fires for its own reason and leaves the head byte for byte.
func TestRepointScopeHeadVaultGuards(t *testing.T) {
	base := newHTTPStore(t)
	const scoped, p1, p2, p3 = "rkscope2#media", "first pass phrase words", "second pass phrase words", "third pass phrase words"
	key := deriveKey(scoped, p1)
	m0 := sealRepointManifestKey(t, base, key, []string{"aa"})
	m1 := sealRepointManifestKey(t, base, key, []string{"bb"})
	raw := publishRepointVault(base, scoped, p2, buildScopeVault(key, scoped, p2, m1))
	unchanged := func(what, want string) {
		t.Helper()
		if cur := readHead(base, scoped, p2); cur != want {
			t.Fatalf("%s: the refused repoint moved the head to %q", what, short(cur))
		}
	}

	// Sealed under the KEK, not the scope key: not this profile's data.
	kekMan := sealRepointManifestKey(t, base, deriveKey(scoped, p2), []string{"cc"})
	if _, _, err := repointScopeHead(base, scoped, p2, kekMan); err != errRepointForeign {
		t.Fatalf("KEK-sealed manifest: got %v, want errRepointForeign", err)
	}
	unchanged("KEK-sealed manifest", raw)
	// The manifest the vault names now.
	if _, _, err := repointScopeHead(base, scoped, p2, m1); err != errRepointSame {
		t.Fatalf("same manifest: got %v, want errRepointSame", err)
	}
	unchanged("same manifest", raw)
	// A wrong passphrase reads a different ref, finds no head, and takes the bare path.
	if _, _, err := repointScopeHead(base, scoped, "not the pass phrase", m0); err != errRepointForeign {
		t.Fatalf("wrong passphrase: got %v, want errRepointForeign", err)
	}
	unchanged("wrong passphrase", raw)

	// A signed vault whose Sig was altered.
	tv := *readRepointVault(t, base, scoped, p2)
	signVault(&tv, deriveKey(scoped, p3)) // a valid signature under the wrong key
	tampered := publishRepointVault(base, scoped, p2, &tv)
	if _, _, err := repointScopeHead(base, scoped, p2, m0); err != errRepointLocked {
		t.Fatalf("altered Sig: got %v, want errRepointLocked", err)
	}
	unchanged("altered Sig", tampered)

	// A vault at p2's ref whose only slot is wrapped under another passphrase: the ref resolves, no slot opens.
	locked := publishRepointVault(base, scoped, p2, buildScopeVault(key, scoped, p3, m1))
	if _, _, err := repointScopeHead(base, scoped, p2, m0); err != errRepointLocked {
		t.Fatalf("no slot opens: got %v, want errRepointLocked", err)
	}
	unchanged("no slot opens", locked)
}

// Only a KNOWN scope suffix is a scope: a bare profile may be literally named "x#b", and #wallet's head is a
// wallet blob sealed under the profile DK, never a manifest.
func TestRepointScopeHeadRefusesNonScopes(t *testing.T) {
	base := newHTTPStore(t)
	const pass = "correct horse battery staple"
	for _, name := range []string{"rkscope3#b", "rkscope3#wallet"} {
		head := sealManifest(t, base, name, pass, []string{"aa"})
		putHead(base, name, pass, head)
		target := sealManifest(t, base, name, pass, []string{"bb"})
		if _, _, err := repointScopeHead(base, name, pass, target); err != errRepointNotScope {
			t.Fatalf("%q: got %v, want errRepointNotScope", name, err)
		}
		if cur := readHead(base, name, pass); cur != head {
			t.Fatalf("%q: the refused repoint moved the head", name)
		}
	}
}
