package main

import (
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// recoverReplyFixture builds a cap-mode profile with a funded wallet and returns its name, recovery phrase
// and the store server's close func (NWP-20261013-23).
func recoverReplyFixture(t *testing.T) (name, mnemonic string, closeStore func()) {
	t.Helper()
	srv, _, _ := mockCapStore(t)
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
	name = "recreply"
	mnemonic = createVault("s3", name, "old horse battery staple")
	if mnemonic == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	capReadCache = map[string]capEntry{}
	return name, mnemonic, srv.Close
}

const recNewPass = "new maple stone cloud lantern"

// TestRecoverReply_StoreFailureAfterUnwrap: the right phrase whose publish the store refuses is ERR-STORE,
// not the blind-login BLANK that tells the user their correct words are wrong.
func TestRecoverReply_StoreFailureAfterUnwrap(t *testing.T) {
	name, mn, _ := recoverReplyFixture(t)
	capStorePutStatus = func(string, http.Header) (int, string) { return http.StatusInternalServerError, "boom" }
	if got := recoverReply(name, mn, recNewPass); got != "ERR-STORE" {
		t.Fatalf("correct phrase + store failure after the unwrap answered %q, want ERR-STORE", got)
	}
}

// TestRecoverReply_RefusedPublishAfterUnwrap: the store ANSWERING with a refusal (no panic) is the same reply --
// the error return after the unwrap is wrapped, not only the panic.
func TestRecoverReply_RefusedPublishAfterUnwrap(t *testing.T) {
	name, mn, _ := recoverReplyFixture(t)
	head := profileRefV2(name, recNewPass)
	if !armSealFence([]string{head}) || !sealFenceBlocks(head) {
		t.Fatal("could not arm the seal fence")
	}
	t.Cleanup(func() {
		liftSealFence([]string{head})
		sealFenceHit = false
		clearSealExpectations()
	})
	if got := recoverReply(name, mn, recNewPass); got != "ERR-STORE" {
		t.Fatalf("a refused publish after the unwrap answered %q, want ERR-STORE", got)
	}
}

// TestRecoverReply_PanicAfterUnwrap: a panic once the code has unwrapped is the same refusal.
func TestRecoverReply_PanicAfterUnwrap(t *testing.T) {
	name, mn, _ := recoverReplyFixture(t)
	recoverAfterUnwrapHook = func() { panic("injected store panic") }
	t.Cleanup(func() { recoverAfterUnwrapHook = nil })
	if got := recoverReply(name, mn, recNewPass); got != "ERR-STORE" {
		t.Fatalf("panic after the unwrap answered %q, want ERR-STORE", got)
	}
}

// TestRecoverReply_WrongPhraseBlank: a wrong phrase stays the blind-login BLANK.
func TestRecoverReply_WrongPhraseBlank(t *testing.T) {
	name, _, _ := recoverReplyFixture(t)
	other := createVault("s3", "recreply-other", "another horse battery staple")
	if other == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if got := recoverReply(name, other, recNewPass); got != "BLANK" {
		t.Fatalf("wrong phrase answered %q, want BLANK", got)
	}
	if got := recoverReply("nobody", other, recNewPass); got != "BLANK" {
		t.Fatalf("unknown profile answered %q, want BLANK", got)
	}
}

// TestRecoverReply_StoreFailureBeforeUnwrap: the store down before the code unwraps proves nothing about the
// words, so it is BLANK -- and a panic there must not be reported as a credential-proven failure.
func TestRecoverReply_StoreFailureBeforeUnwrap(t *testing.T) {
	name, mn, closeStore := recoverReplyFixture(t)
	closeStore()
	if got := recoverReply(name, mn, recNewPass); got != "BLANK" {
		t.Fatalf("store down before the unwrap answered %q, want BLANK", got)
	}
}

// TestRecoverReply_Correct: the happy path still answers OK.
func TestRecoverReply_Correct(t *testing.T) {
	name, mn, _ := recoverReplyFixture(t)
	if got := recoverReply(name, mn, recNewPass); got != "OK" {
		t.Fatalf("correct recovery answered %q, want OK", got)
	}
}

// TestRecoverReply_NoReplyIsAPrefixOfAnother: the chooser matches on equality and on "WEAK " (RecoverCopy), so no
// code may be a prefix of another.
func TestRecoverReply_NoReplyIsAPrefixOfAnother(t *testing.T) {
	codes := []string{"OK", "BLANK", "ERR-STORE", "WEAK"}
	for i, a := range codes {
		for j, b := range codes {
			if i != j && strings.HasPrefix(b, a) {
				t.Fatalf("%q is a prefix of %q", a, b)
			}
		}
	}
}

// TestRecoverReply_ChooserBranchPosition is a source scan: the ERR-STORE arm of the Reset passphrase screen's copy
// (RecoverCopy.failText since NWP-20261115-10) matches by equality, says the code was accepted, and comes ahead of
// the no-answer and generic "couldn't reset" texts; and buildRecoverScreen renders its failure through it.
func TestRecoverReply_ChooserBranchPosition(t *testing.T) {
	b, err := os.ReadFile("../chooser/src/com/nowhere/chooser/RecoverCopy.java")
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(`(?s)"ERR-STORE"\.equals\(r\)\)\s*return\s*"Your recovery code was accepted, but the phone couldn't reach your storage\. Try again\.";.*?r\.isEmpty\(\).*?couldn't reset`)
	if !re.Match(b) {
		t.Fatal("RecoverCopy.failText must test \"ERR-STORE\".equals(r) before the empty-reply and generic couldn't-reset branches")
	}
	if strings.Contains(string(b), "Your recovery code was accepted, but the phone couldn't reach your storage. Try again. Nothing") {
		t.Fatal("the message must not claim nothing changed")
	}
	a, err := os.ReadFile("../chooser/src/com/nowhere/chooser/ChooserActivity.java")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(a), "RecoverCopy.failText(r)") {
		t.Fatal("ChooserActivity's RECOVER failure branch must render through RecoverCopy.failText(r)")
	}
}
