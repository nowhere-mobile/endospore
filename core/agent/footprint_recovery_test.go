package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tyler-smith/go-bip39"
)

// NWP-20260918-10/-11: a HARDENED vault -- which is every Endospore profile, because the chooser hardens at
// create -- has no `pass` slot, so it opens only by the secure element or the 12-word recovery code. The SE
// is reachable only from a live session, and profile-export-restore.md section 5 requires an export run with
// the profile LOGGED OFF. Those two correct requirements made a complete footprint of a hardened profile
// impossible, and the CLI silently returned a SHORT one.
//
// ⚠ THIS IS NOT A HYPOTHETICAL SHAPE. Measured on the throwaway odtest56 on 2026-09-18, against a build
// whose agent predated the NWP-20260918-01 guard: the CLI produced 53 objects where the daemon produced 65 --
// 12 blobs and 744,067 B, 22.3% of the profile, absent without a word, including a photo added minutes
// earlier. The next step in that test was to DELETE the profile.
//
// hardenedWithRecovery is hardenedWithData plus the recovery code, which the fixture there discards.
func hardenedWithRecovery(t *testing.T, base, name, pass string) (se []byte, mnemonic string) {
	t.Helper()
	mnemonic = createVault(base, name, pass)
	if mnemonic == "" {
		t.Fatal("createVault returned no recovery code -- fixture bug, the rest proves nothing")
	}
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), bytes.Repeat([]byte("payload"), 900), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	se = []byte("this-handsets-strongbox-secret")
	if err := enrollSE(base, name, pass, se); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}
	return se, mnemonic
}

// TestTheRecoveryCodeEnumeratesAHardenedProfileOffHandset is the whole slice.
//
// The three arms are deliberately asserted together, because any one alone would pass against a broken
// implementation: "unmeasured without the code" alone passes if the code does nothing; "measured with the
// code" alone passes if the guard were simply removed; and only the SUPERSET comparison shows that what the
// code bought is the chunks rather than a flag flip.
func TestTheRecoveryCodeEnumeratesAHardenedProfileOffHandset(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "hardexport", "horse battery staple correct"
	_, mnemonic := hardenedWithRecovery(t, base, name, pass)

	entropy, err := bip39.EntropyFromMnemonic(mnemonic)
	if err != nil {
		t.Fatalf("EntropyFromMnemonic: %v", err)
	}

	// (1) TODAY'S BEHAVIOUR, and the precondition that makes the rest meaningful. se=nil is what the CLI
	// passes and what a logged-off export has: no session, so no secure element.
	short, measured := profileFootprint(base, name, pass, nil)
	if measured {
		t.Fatal("a HARDENED vault reported itself measured with no secure element and no recovery code -- " +
			"the fixture is not actually hardened, so every other assertion here is vacuous")
	}

	// (2) WITH THE CODE it must open, off-handset, with no session.
	full, fullMeasured := profileFootprintRec(base, name, pass, nil, entropy)
	if !fullMeasured {
		t.Fatal("the recovery code did not open a hardened vault -- this is the whole point of the slice: " +
			"an export runs LOGGED OFF, so the secure element is never available and the code is the only " +
			"credential that can reach the vault")
	}

	// (3) AND IT MUST BUY CHUNKS, NOT JUST A FLAG. The short walk still adds the head pointer and head blob,
	// which is exactly why it looks like a small profile rather than a broken one.
	if len(full) <= len(short) {
		t.Errorf("the recovery code produced %d refs against %d without it -- it flipped `measured` without "+
			"adding the scope's chunks, which is the short-list failure wearing a success message",
			len(full), len(short))
	}
	for k := range short {
		if _, ok := full[k]; !ok {
			t.Errorf("%q is in the short footprint but NOT the complete one -- the complete walk must be a "+
				"SUPERSET; losing a ref here would delete data a copy already had", k)
		}
	}
	var shortBytes, fullBytes int64
	for _, v := range short {
		shortBytes += v
	}
	for _, v := range full {
		fullBytes += v
	}
	if fullBytes <= shortBytes {
		t.Errorf("complete=%d B, short=%d B -- the code added refs but no BYTES, so the chunks are still "+
			"missing and a copy driven from this would still lose the scope", fullBytes, shortBytes)
	}
	t.Logf("hardened profile: short=%d refs/%d B, with recovery code=%d refs/%d B",
		len(short), shortBytes, len(full), fullBytes)
}

// TestAWrongRecoveryCodeDoesNotSilentlyProduceAShortList: the failure has to stay LOUD.
//
// A wrong code must leave `measured` false, never flip it while quietly enumerating nothing. Getting this
// backwards would be worse than having no recovery rung at all -- a caller would hold a confident short list
// and delete the profile behind it, which is precisely the accident NWP-20260918-10 records.
func TestAWrongRecoveryCodeDoesNotSilentlyProduceAShortList(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "wrongcode", "horse battery staple correct"
	hardenedWithRecovery(t, base, name, pass)

	// A VALID mnemonic that belongs to a different profile -- not a malformed one, which the CLI rejects
	// before it ever reaches here. This is the dangerous input: well-formed and wrong.
	other := createVault(newHTTPStore(t), "someone-else", pass)
	if other == "" {
		t.Fatal("fixture: no second recovery code")
	}
	entropy, err := bip39.EntropyFromMnemonic(other)
	if err != nil {
		t.Fatalf("EntropyFromMnemonic: %v", err)
	}

	if _, measured := profileFootprintRec(base, name, pass, nil, entropy); measured {
		t.Error("a recovery code from a DIFFERENT profile reported the vault as measured -- the walk would " +
			"return heads with no chunks and the caller would act on it")
	}
}

// TestRecoveryEntropyDoesNotReachTheScopeHeads pins a deliberate omission, so a later reader does not
// "complete" it.
//
// profileFootprintRec threads the entropy into the BARE scope only. The five scope heads are located AND
// keyed by deriveKey(name#scope, pass), so the passphrase already opens them and the recovery code never
// could -- kekRecovery is keyed on (name, entropy) with no scope suffix. Passing it to the fan-out would
// read like a fallback and imply the code alone suffices; it does not, and section 4 says so.
func TestRecoveryEntropyDoesNotReachTheScopeHeads(t *testing.T) {
	b, err := os.ReadFile("billing.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(b)
	i := strings.Index(body, "func profileFootprintRec(")
	if i < 0 {
		t.Fatal("profileFootprintRec is gone -- this test is now vacuous")
	}
	fn := body[i:]
	if j := strings.Index(fn[1:], "\nfunc "); j >= 0 {
		fn = fn[:j+1]
	}
	for _, scope := range []string{`profile+"#de"`, `profile+"#sys"`, `profile+"#media"`, `profile+"#apps"`, `profile+"#keys"`} {
		line := ""
		for _, l := range strings.Split(fn, "\n") {
			if strings.Contains(l, scope) {
				line = l
				break
			}
		}
		if line == "" {
			t.Errorf("the fan-out no longer mentions %s", scope)
			continue
		}
		if strings.Contains(line, "recEntropy") {
			t.Errorf("the %s fan-out was given recEntropy. The recovery code cannot open a scope head -- it "+
				"is keyed on (name, entropy) with no scope suffix -- so this reads as a fallback that does "+
				"not exist, and invites a caller to supply the code ALONE and get a silently short list", scope)
		}
	}
}
