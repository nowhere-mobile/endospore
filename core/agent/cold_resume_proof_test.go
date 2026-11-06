package main

import (
	"bytes"
	"encoding/base64"
	"strings"
	"testing"
)

// NWP-20260924-01: the pieces the resume proof is built from, each tested on its own.

// U1. coldResumeProof opens line 6 only with the right unlock secret and (keyed) the right hmac, returns the
// passphrase -- and for a no-PIN session also requires the plaintext to BE the entry.
func TestColdResumeProofTable(t *testing.T) {
	h := bytes.Repeat([]byte{7}, fido2HMACLen)
	h2 := bytes.Repeat([]byte{9}, fido2HMACLen)
	wrapOf := func(secret string, hm []byte, pass string) string {
		return base64.StdEncoding.EncodeToString(seal(coldWrapKey("alice", secret, hm), []byte(pass)))
	}
	pinKeyed := wrapOf("4821", h, "pw-real")
	noPin := wrapOf("pw-real", nil, "pw-real")
	noPinMismatch := wrapOf("pw-real", nil, "something-else")
	cases := []struct {
		name   string
		entry  string
		hm     []byte
		hasPin bool
		wrap   string
		want   string
		ok     bool
	}{
		{"PIN, key: right", "4821", h, true, pinKeyed, "pw-real", true},
		{"PIN, key: wrong PIN", "0000", h, true, pinKeyed, "", false},
		{"PIN, key: wrong key", "4821", h2, true, pinKeyed, "", false},
		{"PIN, key: no key on a keyed wrap", "4821", nil, true, pinKeyed, "", false},
		{"no PIN: right", "pw-real", nil, false, noPin, "pw-real", true},
		{"no PIN: wrong", "pw-wrong", nil, false, noPin, "", false},
		{"no PIN: plaintext is not the entry", "pw-real", nil, false, noPinMismatch, "", false},
		{"empty wrap", "4821", h, true, "", "", false},
		{"garbage base64", "4821", h, true, "!!!not base64!!!", "", false},
	}
	for _, c := range cases {
		got, ok := coldResumeProof(deriveKeyUncached("alice", c.entry), c.hm, c.entry, c.hasPin, c.wrap)
		if got != c.want || ok != c.ok {
			t.Errorf("%s: got (%q, %v), want (%q, %v)", c.name, got, ok, c.want, c.ok)
		}
		if !c.ok && got == c.entry {
			t.Errorf("%s: a failed proof returned the ENTRY -- the old fallback that made a wrong entry the passphrase", c.name)
		}
	}
}

// U2. deriveKeyUncached derives the same key as deriveKey, never touches the cache, and counts as one miss.
func TestDeriveKeyUncachedLeavesTheCacheAlone(t *testing.T) {
	deriveKeyForget()
	t.Cleanup(deriveKeyForget)
	deriveKeyMu.Lock()
	m0, n0 := deriveKeyMisses, len(deriveKeyCache)
	deriveKeyMu.Unlock()
	k := deriveKeyUncached("alice", "4821")
	deriveKeyMu.Lock()
	m1, n1 := deriveKeyMisses, len(deriveKeyCache)
	_, cached := deriveKeyCache["alice\x004821"]
	deriveKeyMu.Unlock()
	if m1-m0 != 1 {
		t.Errorf("deriveKeyUncached counted %d misses, want 1", m1-m0)
	}
	if n1 != n0 || cached {
		t.Error("deriveKeyUncached wrote the typed secret into the KDF cache")
	}
	if !bytes.Equal(k, deriveKey("alice", "4821")) {
		t.Error("deriveKeyUncached and deriveKey disagree")
	}
}

// U3. The FromKey variants are byte-identical to the originals, so a marker written by one opens with the other.
func TestColdFromKeyVariantsMatch(t *testing.T) {
	h := bytes.Repeat([]byte{3}, fido2HMACLen)
	k := deriveKey("alice", "4821")
	if coldCredFromKey(k, h) != coldCredPIN("alice", "4821", h) {
		t.Error("coldCredFromKey != coldCredPIN")
	}
	if !bytes.Equal(coldWrapKeyFromKey(k, h), coldWrapKey("alice", "4821", h)) {
		t.Error("coldWrapKeyFromKey != coldWrapKey")
	}
	if !bytes.Equal(coldWrapKeyFromKey(k, nil), coldWrapKey("alice", "4821", nil)) {
		t.Error("coldWrapKeyFromKey != coldWrapKey without a key")
	}
}

// U4. The decoy is 16 decimal digits and fresh each time.
func TestResumeDecoyCredIsSixteenFreshDigits(t *testing.T) {
	a, b := resumeDecoyCred(), resumeDecoyCred()
	for _, d := range []string{a, b} {
		if len(d) != 16 || strings.Trim(d, "0123456789") != "" {
			t.Errorf("decoy %q is not 16 decimal digits", d)
		}
	}
	if a == b {
		t.Error("two decoys were identical -- the keyguard would see a repeatable value")
	}
}

// U5. A resume assertion and a login assertion never share a file.
func TestNFCHmacStashIsScopedToTheVerb(t *testing.T) {
	if nfcHmacStash(true) != ".fido2hmac.resume" || nfcHmacStash(false) != ".fido2hmac.pre" {
		t.Errorf("stash names: resume=%q login=%q", nfcHmacStash(true), nfcHmacStash(false))
	}
}
