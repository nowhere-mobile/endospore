package main

import (
	"encoding/base64"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261017-03: a keyed cold-lock resume hands NOTHING of the typed entry to the worker, the store or the KDF
// cache before coldResumeProof has accepted it (residual 6 of NWP-20260924-01's design review). Before this slice
// the key re-assert wrote the entry into roam.req, roamd's `fido2hmac` op fell back to a store lookup that derived
// head refs from it, and the FIDO2-NFC-RESUME arm resolved a head through the cached KDF -- so a stranger's guesses
// at a keyed phone's resume prompt left the device as derived refs, and sat in the cache.
//
// These drive the REAL handleResume (and the REAL dispatcher for the NFC verb) against a marker built by the real
// cold-lock teardown, with the fake roamd of cold_resume_test.go.

var crKeyedKinds = []crKind{
	{name: "pin+key", pin: "4821", keyed: true},
	{name: "key-nopin", keyed: true},
}

// P1. The re-assert request carries no byte of the entry -- right or wrong -- and the entry never enters the KDF
// cache. A control: the key step ran, once, and the right entry still resumes.
func TestKeyedResumeReassertCarriesNoEntry(t *testing.T) {
	for _, k := range crKeyedKinds {
		for _, right := range []bool{false, true} {
			name := k.name + "/wrong"
			if right {
				name = k.name + "/right"
			}
			t.Run(name, func(t *testing.T) {
				l := crLock(t, k)
				entry := "stranger-guess-7391"
				want := "WRONGPASS"
				if right {
					entry, want = l.unlock, "OK 10"
				}
				f := &crFake{mode: "keyguard", keyguard: l.keyguard, hmacHex: l.h1, entry: entry}
				crStartFake(t, l.dest, f)
				if got := crResume(t, l.dest, entry); got != want {
					t.Fatalf("resume replied %q, want %q", got, want)
				}
				ops := f.opsNamed("fido2hmac")
				if len(ops) != 1 {
					t.Fatalf("control failed: %d key re-asserts, want 1", len(ops))
				}
				if strings.Contains(ops[0].raw, entry) {
					t.Errorf("the key re-assert request carried the typed entry: %q", ops[0].raw)
				}
				if ops[0].entryCached {
					t.Error("the typed entry was in the KDF cache when the key re-assert ran")
				}
				for _, o := range f.snapshot() {
					if o.op == "fido2hmac" || o.op == "verify" || o.op == "resumeclear" {
						continue
					}
					if !right && strings.Contains(o.raw, entry) {
						t.Errorf("op %s carried the unproven entry: %q", o.op, o.raw)
					}
				}
			})
		}
	}
}

// P2. A keyed marker with no usable slot spec is refused BEFORE any worker call, with the same token as a wrong
// entry -- whatever was typed -- and nothing is derived from the entry.
func TestKeyedResumeWithoutASlotSpecIsRefusedBeforeAnyWorkerCall(t *testing.T) {
	for _, k := range crKeyedKinds {
		k.noSpec = true
		for _, entry := range []string{"stranger-guess-7391", ""} {
			t.Run(k.name+"/"+entry, func(t *testing.T) {
				l := crLock(t, k)
				if got := coldLockSlots(l.dest); got != "" {
					t.Fatalf("control failed: the marker carries a spec %q", got)
				}
				if entry == "" {
					entry = l.unlock // the owner's own right entry: the refusal does not depend on the entry
				}
				f := &crFake{mode: "keyguard", keyguard: l.keyguard, hmacHex: l.h1, entry: entry}
				crStartFake(t, l.dest, f)
				missesBefore := deriveKeyMisses
				if got := crResume(t, l.dest, entry); got != "WRONGPASS" {
					t.Fatalf("resume replied %q, want WRONGPASS (the refusal token of every other refusal)", got)
				}
				if ops := f.snapshot(); len(ops) != 0 {
					t.Errorf("the worker was called %d time(s) before the refusal: %v", len(ops), ops)
				}
				if deriveKeyMisses != missesBefore {
					t.Error("the refusal ran a KDF derivation")
				}
				crAssertUntouched(t, l)
			})
		}
	}
}

// nfcResumeConn sends FIDO2-NFC-RESUME through the real dispatcher and returns the reply.
func nfcResumeConn(t *testing.T, dest, name, pass string) string {
	t.Helper()
	return evictConn(t, dest, "FIDO2-NFC-RESUME\n"+name+"\n"+pass+"\n")
}

// P3. FIDO2-NFC-RESUME on a keyed, no-PIN marker with an empty slot spec answers ERR and resolves no head: the
// typed passphrase is neither derived (it would enter the KDF cache) nor sent to the store.
func TestNFCResumeWithoutASlotSpecResolvesNoHead(t *testing.T) {
	l := crLock(t, crKind{name: "key-nopin", keyed: true, noSpec: true})
	if _, _, _, ckeyed, cpin, _ := readColdLock(l.dest); !ckeyed || cpin {
		t.Fatalf("control failed: marker keyed=%v pin=%v, want a keyed no-PIN marker", ckeyed, cpin)
	}
	if got := coldLockSlots(l.dest); got != "" {
		t.Fatalf("control failed: the marker carries a spec %q", got)
	}
	const guess = "stranger-guess-7391"
	missesBefore := deriveKeyMisses
	if got := nfcResumeConn(t, l.dest, "alice", guess); got != "ERR" {
		t.Fatalf("FIDO2-NFC-RESUME replied %q, want ERR", got)
	}
	if deriveKeyMisses != missesBefore {
		t.Error("the NFC resume derived a key from the typed entry (a head lookup)")
	}
	deriveKeyMu.Lock()
	defer deriveKeyMu.Unlock()
	for ck := range deriveKeyCache {
		if strings.HasSuffix(ck, "\x00"+guess) {
			t.Error("the typed entry entered the KDF cache")
		}
	}
}

// P4. RF-001: an enrol or a removal leaves the cold-resume slot spec EQUAL to the enrolled set it committed -- from
// the committed vault, not from a second store read that a hiccup could fail. A keyed resume takes its spec from the
// marker only, so a stale one would strand the owner; the last removal deletes it.
func TestEnrolAndRemoveKeepTheColdResumeSlotSpecInStep(t *testing.T) {
	base := newHTTPStore(t)
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	defer os.Unsetenv("NOWHERE_FIDO2_HMAC")
	const name, pass = "stashstep", "correct horse battery staple"
	createVault(base, name, pass)
	dest := t.TempDir()

	enrol := func(tag string) (cred string, hm string) {
		raw := make([]byte, fido2HMACLen)
		for i := range raw {
			raw[i] = byte(len(tag) + i)
		}
		salt := make([]byte, 32)
		copy(salt, tag)
		cred = preproofB64([]byte(tag))
		hm = hex.EncodeToString(raw)
		if err := enrollFido2(base, name, pass, cred, preproofB64(salt), hm, false, "usb", nil, dest); err != nil {
			t.Fatalf("enrol %s: %v", tag, err)
		}
		return cred, hm
	}
	stash := func() string {
		b, _ := os.ReadFile(filepath.Join(dest, ".fido2slots"))
		return string(b)
	}
	vaultSpec := func() string {
		v, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
		return encodeSlotSpec(listFido2Slots(v))
	}
	c1, h1 := enrol("key-1")
	if stash() == "" || stash() != vaultSpec() {
		t.Fatalf("after the first enrol the stash is %q, the vault has %q", stash(), vaultSpec())
	}
	os.Setenv("NOWHERE_FIDO2_HMAC", h1)
	c2, h2 := enrol("key-22")
	if got, want := stash(), vaultSpec(); got != want || len(parseSlotSpec(got)) != 2 {
		t.Fatalf("after the second enrol the stash is %q, the vault has %q (want both keys)", got, want)
	}
	if still, err := removeFido2Key(base, name, pass, c1, nil, dest); err != nil || !still {
		t.Fatalf("remove key 1: still=%v err=%v", still, err)
	}
	if got, want := stash(), vaultSpec(); got != want || len(parseSlotSpec(got)) != 1 || !strings.HasPrefix(got, c2+":") {
		t.Fatalf("after removing key 1 the stash is %q, the vault has %q (want key 2 alone)", got, want)
	}
	os.Setenv("NOWHERE_FIDO2_HMAC", h2) // key 1 is gone: only key 2's hmac opens the vault now
	if still, err := removeFido2Key(base, name, pass, c2, nil, dest); err != nil || still {
		t.Fatalf("remove the last key: still=%v err=%v", still, err)
	}
	if _, err := os.Stat(filepath.Join(dest, ".fido2slots")); !os.IsNotExist(err) {
		t.Errorf("the last removal left the slot stash behind (%v)", err)
	}
}

func preproofB64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

// P-e (RF-001). The enroll/removal stash sync is atomic and REPORTS a failure: a stale line 7 behind an OK
// would strand the owner now that a keyed resume has no head-resolved fallback.
func TestSyncFido2SlotsStashReportsFailures(t *testing.T) {
	slots := []fido2SlotInfo{{CredID: "Y3JlZA==", Salt: "c2FsdA=="}}
	dir := t.TempDir()
	if err := syncFido2SlotsStash(dir, slots); err != nil {
		t.Fatalf("write: %v", err)
	}
	if got, want := readFido2SlotsStash(dir), encodeSlotSpec(slots); got != want {
		t.Fatalf("stash = %q, want %q", got, want)
	}
	if _, err := os.Stat(filepath.Join(dir, ".fido2slots.tmp")); err == nil {
		t.Error("the temp file was left behind")
	}
	if err := syncFido2SlotsStash(filepath.Join(dir, "missing"), slots); err == nil {
		t.Error("a write into a missing state dir reported success")
	}
	if err := syncFido2SlotsStash(dir, nil); err != nil {
		t.Fatalf("clear: %v", err)
	}
	if err := syncFido2SlotsStash(dir, nil); err != nil {
		t.Errorf("clearing an absent stash must succeed: %v", err)
	}
	// a removal that cannot happen (a non-empty directory squats the name) must be reported, not swallowed
	sq := filepath.Join(dir, ".fido2slots")
	if err := os.MkdirAll(filepath.Join(sq, "x"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := syncFido2SlotsStash(dir, nil); err == nil {
		t.Error("a failed stash removal reported success")
	}
}
