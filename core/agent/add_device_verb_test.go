package main

import (
	"encoding/hex"
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tyler-smith/go-bip39"
)

// addDeviceVerb drives the daemon handler over a pipe and returns the single-word reply, so what is pinned
// is the bytes the chooser actually reads -- not a Go error the wire never carries.
func addDeviceVerb(t *testing.T, name, pass, mnemonic, seHex string) string {
	t.Helper()
	c1, c2 := net.Pipe()
	go func() {
		handleAddDevice(c2, name, pass, mnemonic, seHex)
		c2.Close()
	}()
	raw, err := io.ReadAll(c1)
	if err != nil {
		t.Fatalf("reading the ADD-DEVICE reply: %v", err)
	}
	return strings.TrimSpace(string(raw))
}

// TestAddDeviceVerbNamesWhichCredentialWasWrong pins the wire contract of ADD-DEVICE (NWP-20260915-09).
//
// ⚠ WHY THIS VERB TELLS THE USER WHICH FIELD WAS WRONG when the gate's other recovery screen deliberately
// will not. buildRecoverScreen answers a failed RECOVER with "check the name and recovery code", on purpose:
// there, saying which would turn the screen into a profile-existence oracle, and the absence of that oracle
// IS the blind-login property. Here it is not, and the difference is worth stating once rather than
// rediscovering it as a "bug" later:
//
//   - ERR-BADPHRASE is decided from the typed words alone, before the store is touched at all.
//   - ERR-NOPROFILE is the JOINT failure of name AND phrase, so it cannot separate an unknown name from
//     wrong words -- which is exactly the separation an oracle would need.
//   - ERR-BADPASS is reachable ONLY by someone already holding this profile's 12 words, and they can take
//     the profile outright with RECOVER. It discloses nothing they could not already obtain.
//
// The cost of collapsing them is concrete: a user who typed their recovery code correctly and their
// passphrase wrongly would be told to go and check the recovery code.
//
// Runs in CAP MODE because the handler writes through the managed-store path, which is the entire fielded
// fleet and the only mode in which the last four bracket bugs were reachable.
func TestAddDeviceVerbNamesWhichCredentialWasWrong(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	capReadCache = map[string]capEntry{}
	t.Setenv("NOWHERE_STATE", t.TempDir())
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}

	const name, pass = "verbadd", "horse battery staple correct"
	mnemonic := createVault("s3", name, pass)
	if mnemonic == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	if err := enrollSE("s3", name, pass, []byte("handset-A-secret")); err != nil {
		t.Fatalf("A enrollSE: %v", err)
	}
	seB := hex.EncodeToString([]byte("handset-B-secret"))

	// ⚠ ORDER MATTERS: the success case runs LAST, because it is the only one that changes the vault.
	for _, tc := range []struct {
		label, nm, pw, mn, se, want, why string
	}{
		{"no profile name", "", pass, mnemonic, seB, "BLANK",
			"an empty field is the caller's bug, not a credential answer"},
		{"no recovery code", name, pass, "", seB, "BLANK", "same"},
		{"no secure element", name, pass, mnemonic, "", "ERR-BADSECRET",
			"seSecretHex returns \"\" with no StrongBox, so there is nothing to add this device BY"},
		{"the words are not a recovery code", name, pass, "not a mnemonic at all", seB, "ERR-BADPHRASE",
			"decided from the words alone, before the store is touched"},
		{"unknown name + phrase", "nobody-here", pass, mnemonic, seB, "ERR-NOPROFILE",
			"the JOINT failure -- it must not separate an unknown name from wrong words"},
		{"right code, wrong passphrase", name, "not the right passphrase", mnemonic, seB, "ERR-BADPASS",
			"only reachable by someone holding the 12 words, so it is not an oracle"},
		{"all three right", name, pass, mnemonic, seB, "OK", "the phone is added"},
	} {
		if got := addDeviceVerb(t, tc.nm, tc.pw, tc.mn, tc.se); got != tc.want {
			t.Errorf("%s: ADD-DEVICE replied %q, want %q (%s)", tc.label, got, tc.want, tc.why)
		}
	}

	// The success above must be real in the PUBLISHED head, and must not have cost handset A its slot.
	if n := seSlotsOpenableBy(t, "s3", name, pass, []byte("handset-B-secret")); n != 1 {
		t.Errorf("after an OK reply handset B opens %d slots in the published head, want 1", n)
	}
	if n := seSlotsOpenableBy(t, "s3", name, pass, []byte("handset-A-secret")); n != 1 {
		t.Errorf("after an OK reply handset A opens %d slots, want 1 -- adding B evicted A", n)
	}
}

// TestAddDeviceVerbRefusesWithNoStore: the daemon must answer NOSTORE rather than reaching for a store that
// is not configured. An un-enrolled device reaching the add-a-phone screen is a real state -- the store conf
// is provisioned, not baked -- and a panic there would surface as a bare ERR, sending the user to re-check
// credentials that were never the problem.
func TestAddDeviceVerbRefusesWithNoStore(t *testing.T) {
	for _, k := range []string{"GATEWAY_URL", "S3_ENDPOINT", "S3_BUCKET", "S3_ACCESS_KEY", "S3_SECRET_KEY"} {
		t.Setenv(k, "")
	}
	if got := addDeviceVerb(t, "someone", "pass", "twelve words go here", "aabb"); got != "NOSTORE" {
		t.Errorf("ADD-DEVICE with no store replied %q, want NOSTORE", got)
	}
}

// TestAddDeviceVerbNeverReadsAStoreFAILUREAsSUCCESS closes a gap a mutation found, not one I reasoned my way
// to: replacing daemonVaultErr's recover() body with a bare `_ = recover()` left the named return at nil, so
// a store panic came back as "no error" and the handler answered OK. Every test passed, because the only
// no-store test returns at the storeConfigured() guard and never reaches the panic path at all.
//
// The failure it allows is the bad kind: the chooser says "this phone has been added", the user puts the
// phone down, and the next login still shows a blank -- which blind login makes indistinguishable from a
// wrong passphrase, so they have no way to work out that nothing was written.
//
// A CONFIGURED BUT UNREACHABLE store is the ordinary case here, not an exotic one: cap mode is the whole
// fielded fleet and a phone with no signal is a Tuesday.
func TestAddDeviceVerbNeverReadsAStoreFAILUREAsSUCCESS(t *testing.T) {
	// Configured, and every connection is dropped. The listener stays OPEN for the whole test: a closed
	// server freed its port, and on a busy CI box another process bound it inside the 3 s of retries, so the
	// last attempt got a real 404 and the reply was ERR-NOPROFILE (affected-CI run c8d7bddd, NWP-20261122-10).
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	t.Setenv("GATEWAY_URL", "http://"+ln.Addr().String())
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode() -> storeConfigured() is TRUE
	capReadCache = map[string]capEntry{}
	t.Setenv("NOWHERE_STATE", t.TempDir())

	// A REAL mnemonic, or the call is refused for bad words before the store is ever touched and the test
	// proves nothing.
	mnemonic, err := bip39.NewMnemonic(make([]byte, 16))
	if err != nil {
		t.Fatal(err)
	}
	got := addDeviceVerb(t, "someone", "horse battery staple correct", mnemonic, "aabb")
	if got == "OK" {
		t.Fatal("ADD-DEVICE answered OK against a store it could not reach -- the user is told the phone was " +
			"added, and blind login gives them no way to discover that nothing was written")
	}
	// ...and it must be the STORE bucket, not a credential one. Answering ERR-NOPROFILE here would send
	// someone with three correct credentials off to re-check their 12 words over a signal problem.
	if got != "ERR" {
		t.Errorf("an unreachable store answered %q; a store failure must not be reported as a bad credential", got)
	}
}
