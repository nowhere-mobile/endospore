package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// #116 (NWP-20260903-20): a corrupt head blob must REFUSE, not demote.
//
// parseVault answers "are these bytes a vault", which is false BOTH for a genuine pre-vault legacy head and
// for a vault whose bytes came back damaged -- and every call site treated those as the same answer. So a
// corrupt fetch made pushProfile fall through to deriveKey(profile, pass) and then commit a BARE LEGACY
// HEAD over the vault: a FIDO2/secure-element profile demoted to passphrase-only, its keyslots, recovery
// ref and snapshot chain discarded, and no error anywhere. The seal reported OK.
//
// The discriminator is the CONTENT HASH: every head is a postBlob() return, so a head IS the sha256 of the
// bytes it names. A legacy head still hashes correctly, so nothing that works today is refused.

// --- the security property ------------------------------------------------------------------------------

// THE MONEY TEST: with the head blob corrupt, a re-seal must fail and LEAVE THE VAULT STANDING. Before this
// change the same run completed "successfully" and replaced the vault with a bare manifest hash.
func TestCorruptHeadRefusesSealAndLeavesTheVaultIntact(t *testing.T) {
	cs := newCorruptibleStore(t)
	name, pass := "vaultie", "correct horse battery staple"
	createVault(cs.url, name, pass)

	head := getRef(cs.url, headKey(cs.url, name, pass))
	if head == "" {
		t.Fatal("setup: the profile must resolve after createVault")
	}
	if v, isV := parseVault(getHeadBlob(cs.url, head)); !isV || v.RecoveryRef == "" {
		t.Fatal("setup: expected a vault head carrying a recovery ref")
	}

	cs.setCorrupt(head) // bit-rot / torn PUT on the head blob

	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), []byte("payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	refused := func() (r bool) {
		defer func() {
			if p := recover(); p != nil {
				r = true
				if !strings.Contains(fmt.Sprint(p), "corrupt head blob") {
					t.Errorf("the refusal must name its cause, got: %v", p)
				}
			}
		}()
		pushProfile(cs.url, name, pass, src)
		return false
	}()
	if !refused {
		t.Fatal("a seal over a CORRUPT head completed -- that is the demotion: it writes a bare legacy head over the vault")
	}

	// The whole point: the vault is still there to recover with.
	cs.clearCorrupt(head)
	if now := getRef(cs.url, headKey(cs.url, name, pass)); now != head {
		t.Fatalf("the head MOVED despite the refusal: %s -> %s", short(head), short(now))
	}
	v, isV := parseVault(getHeadBlob(cs.url, head))
	if !isV || v.RecoveryRef == "" || len(v.Slots) == 0 {
		t.Fatal("the vault (keyslots + recovery ref) did not survive the refused seal")
	}
}

// A genuine LEGACY head is not a vault and must still be served -- this refuses DAMAGE, not AGE. Without
// this case the fix could be "reject anything that is not a vault", which would brick every pre-vault
// profile in the field.
func TestLegacyHeadStillReadsAsLegacy(t *testing.T) {
	cs := newCorruptibleStore(t)
	const body = "not-a-vault: a pre-vault sealed manifest"
	legacy := postBlob(cs.url, []byte(body))
	b := getHeadBlob(cs.url, legacy) // must NOT refuse
	if _, isV := parseVault(b); isV {
		t.Fatal("fixture is wrong: these bytes must not parse as a vault")
	}
	if string(b) != body {
		t.Fatalf("legacy head bytes altered: %q", string(b))
	}
}

// --- getHeadBlob itself ---------------------------------------------------------------------------------

func TestGetHeadBlobRetriesBeforeGivingUp(t *testing.T) {
	cs := newCorruptibleStore(t)
	h := postBlob(cs.url, []byte("some head bytes"))
	cs.setCorrupt(h)
	func() {
		defer func() { recover() }()
		getHeadBlob(cs.url, h)
	}()
	if got := cs.getCount(h); got < 2 {
		t.Fatalf("a transient bad replica must be retried, not failed on the first read: %d GET(s)", got)
	}
}

func TestIsContentHash(t *testing.T) {
	good := strings.Repeat("ab12", 16) // 64 hex chars
	if !isContentHash(good) {
		t.Fatalf("a 64-char lowercase hex string is a content hash: %q", good)
	}
	for _, bad := range []string{
		"",
		strings.Repeat("ab", 31), // 62 chars
		strings.Repeat("ab", 33), // 66 chars
		strings.ToUpper(good),    // uppercase is not what postBlob emits
		strings.Repeat("g", 64),  // right length, not hex
	} {
		if isContentHash(bad) {
			t.Errorf("not a content hash, but accepted: %q", bad)
		}
	}
}
