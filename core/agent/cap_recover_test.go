package main

import (
	"path/filepath"
	"testing"
)

// TestCapModeRecover (NWP-20260915-03) is the direct twin of TestCapModeRotate, for the one credential-change
// path that never got the same treatment.
//
// rotateVault was given a capBegin/capFlush bracket by DIA-20260704-35d, whose comment records the symptom
// exactly: "a cap-mode change-passphrase hit an unbracketed postBlob and failed, and the gate showed a FALSE
// 'wrong passphrase'". recoverVault does the same class of store write -- postBlob, putHead, putHeadSingle,
// putRef -- with no bracket at all (recoverVault, main.go), and every OTHER vault op has one (rotateVault,
// rollbackHeadStore, handleExportMedia, setStoredPIN, handleExport).
//
// The chain that follows, each link read at source: in cap mode postBlob takes the buffered path and calls
// fail("cap-mode postBlob outside a capBegin/capFlush bracket: blob/"+key); fail panics; daemonVaultOp
// recovers the panic and returns ok=false; the RECOVER verb (handleLogin's `name == "RECOVER"` arm, main.go) then answers BLANK. ⚠ BLANK
// is the blind-login WRONG-CREDENTIALS reply, so a user holding a CORRECT 12-word code on a managed device is
// told their recovery phrase is wrong, with no way to tell the difference. The whole fielded fleet is cap mode
// -- a managed device holds no store credentials by construction.
//
// The assertion deliberately goes through daemonVaultOp rather than reading recoverVault's error, so what is
// pinned is the reply the USER gets (OK vs BLANK) and not an internal value the daemon never surfaces.
func TestCapModeRecover(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode()
	capReadCache = map[string]capEntry{}
	t.Setenv("NOWHERE_STATE", t.TempDir()) // anchor/receipt local state
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}

	const name, pass, newpass = "caprec", "old horse battery staple", "new maple stone cloud lantern"
	mnemonic := createVault("s3", name, pass)
	if mnemonic == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	if _, _, ok := resolveKey("s3", name, pass); !ok {
		t.Fatal("pre-recover: the original passphrase should open the vault")
	}

	if ok := daemonVaultOp(func() error { return recoverVault("s3", name, mnemonic, newpass) }); !ok {
		t.Fatal("cap-mode RECOVER answered BLANK for a CORRECT recovery phrase.\n" +
			"\tThat is the blind-login wrong-credentials reply, so on a managed device a user who kept their\n" +
			"\t12 words is told the words are wrong. recoverVault writes the store outside any\n" +
			"\tcapBegin/capFlush bracket; postBlob then calls fail(), which panics, and daemonVaultOp turns\n" +
			"\tthe panic into BLANK. Fix: wrap the body in capWrite(name, newpass, dk, ...) exactly as\n" +
			"\trotateVault does in main.go.")
	}
	if _, _, ok := resolveKey("s3", name, newpass); !ok {
		t.Fatal("post-recover: the NEW passphrase does not open the vault -- the recovery reported success " +
			"but published nothing readable")
	}
}
