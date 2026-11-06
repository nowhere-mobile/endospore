package main

import (
	"crypto/sha256"
	"encoding/hex"
	"path/filepath"
	"testing"
)

// TestCapModeEnrollSE asks whether E.3b hardening has ever worked on the fielded fleet.
//
// enrollSE writes the store -- postBlob, putHeadSingle, putRef -- with no capBegin/capFlush bracket, exactly
// the defect NWP-20260915-03 fixed in recoverVault and DIA-20260704-35d fixed in rotateVault before it. In
// cap mode postBlob's buffered path calls fail() outside a bracket, fail panics, and handleEnrollSE's
// daemonVaultOp turns the panic into a plain "ERR" reply.
//
// ⚠ AND THE CHOOSER DISCARDS THAT REPLY: `if (!se.isEmpty()) sendDaemon("ENROLL-SE\n...")` in
// ChooserActivity.java's roamLogin ignores the return value entirely. So if this test fails, hardening has been
// silently failing on every managed device since E.3b shipped -- every Endospore profile would still carry
// its pass slot with Hardened=false, and docs/threat-model.md's edition claim ("the passphrase is *not*
// offline-brute-forceable") would be false for the whole fleet rather than just for recovered profiles.
//
// docs/backlog.md already flags the field half of this as UNKNOWN: "whether any fielded profile actually
// carries hardened: true. The call site is unconditional on StrongBox, but only the code path was verified,
// not the field."
func TestCapModeEnrollSE(t *testing.T) {
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

	const name, pass = "capse", "horse battery staple correct"
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}

	// The daemon's own wrapper, so what is pinned is the reply the chooser gets (and throws away).
	if ok := daemonVaultOp(func() error { return enrollSE("s3", name, pass, []byte("se-secret-bytes")) }); !ok {
		t.Fatal("cap-mode ENROLL-SE FAILED. enrollSE writes the store outside any capBegin/capFlush bracket, " +
			"so postBlob calls fail(), which panics, and the handler answers ERR -- a reply the chooser " +
			"discards. E.3b hardening therefore never happens on a managed device, which is the entire " +
			"fielded fleet.")
	}
	// ...and it must have actually hardened: the pass slot dropped, the flag set.
	v, isV := parseVault(getHeadBlob("s3", getRef("s3", headKey("s3", name, pass))))
	if !isV {
		t.Fatal("head is not a vault after ENROLL-SE")
	}
	if !v.Hardened {
		t.Error("ENROLL-SE reported success but the vault is not marked Hardened")
	}
	for _, s := range v.Slots {
		if s.Kind == "pass" {
			t.Error("ENROLL-SE reported success but a `pass` slot survives -- the vault is still " +
				"offline-brute-forceable by passphrase, which is the thing hardening exists to remove")
		}
	}
}

// TestCapModeMigrateVault is enrollSE's quieter twin. migrateVault had the same missing bracket, but its
// LOGIN caller wraps it in `defer func(){ recover() }()` -- so on a managed device a legacy profile simply
// never became a vault, with no error surfacing anywhere. It therefore never got a recovery code, and since
// NWP-20260915-02 it never got a scope index either.
func TestCapModeMigrateVault(t *testing.T) {
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
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

	// A LEGACY profile: a head ref pointing straight at a sealed manifest blob, with no vault in front of it.
	const name, pass = "capmig", "horse battery staple correct"
	key := deriveKey(name, pass)
	body := seal(key, []byte("legacy manifest bytes"))
	sum := sha256.Sum256(body)
	blob := hex.EncodeToString(sum[:])
	mu.Lock()
	objs["blob/"+blob] = body
	objs["ref/"+profileRefV2(name, pass)] = []byte(blob)
	mu.Unlock()

	m, migrated := migrateVault("s3", name, pass)
	if !migrated || m == "" {
		t.Fatal("cap-mode migrateVault did NOT migrate. It writes the store outside any capBegin/capFlush " +
			"bracket, so postBlob calls fail() and panics -- and the login caller recover()s that panic, so a " +
			"legacy profile on a managed device silently stays legacy: no vault, no recovery code, and since " +
			"NWP-20260915-02 no scope index either.")
	}
	if _, isV := parseVault(getHeadBlob("s3", getRef("s3", headKey("s3", name, pass)))); !isV {
		t.Error("migrateVault reported success but the head is still not a vault")
	}
}

// TestCapModeEnrollSEViaRecovery is the third member of the same family, filed before it can bite.
//
// The add-a-second-handset path (NWP-20260915-09) is a NEW store-writing path, and this repo has now shipped
// four separate instances of the same defect -- rotateVault, recoverVault (-03), enrollSE and migrateVault
// (-06) -- each one a vault publish with no capBegin/capFlush bracket, each one silent on a managed device
// and only on a managed device, which is the entire fielded fleet. The new path rides hardenVaultTo's
// bracket precisely so it cannot be the fifth. This test is what keeps that true.
func TestCapModeEnrollSEViaRecovery(t *testing.T) {
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

	const name, pass = "capadd", "horse battery staple correct"
	mnemonic := createVault("s3", name, pass)
	if mnemonic == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	// Handset A hardens first, so the vault B meets is one B genuinely cannot open by passphrase.
	if err := enrollSE("s3", name, pass, []byte("handset-A-secret")); err != nil {
		t.Fatalf("A enrollSE: %v", err)
	}

	seB := []byte("handset-B-secret")
	if ok := daemonVaultOp(func() error {
		return enrollSEViaRecovery("s3", name, mnemonic, pass, seB)
	}); !ok {
		t.Fatal("cap-mode add-device FAILED. An unbracketed postBlob calls fail(), which panics, and " +
			"daemonVaultOp answers ERR -- so adding a second handset would be broken on managed devices " +
			"only, exactly like enrollSE was until NWP-20260915-06")
	}
	// The PUBLISHED head must really carry B's slot -- a bracket that buffers and never flushes would leave
	// the in-memory vault correct and the store unchanged, which is the exact shape of the earlier four bugs.
	if n := seSlotsOpenableBy(t, "s3", name, pass, seB); n != 1 {
		t.Errorf("add-device reported success in cap mode but the published head has %d slots handset B can "+
			"open, want 1", n)
	}
	if n := seSlotsOpenableBy(t, "s3", name, pass, []byte("handset-A-secret")); n != 1 {
		t.Errorf("handset A opens %d slots in the published head, want 1 -- the add evicted it", n)
	}
}
