package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261016-20: the gate's "Restore last good version" sent ROLLBACK-GATE with no secure-element secret, so
// no keyslot of a hardened vault opened and the gate answered ERR ("check your connection") on the one screen
// offering the way back to a good save. The secret now rides as the 3rd request line, as ROAM-IN's 4th does.
// test-rollback-gate-se.sh re-runs this file against copies of main.go with each link broken.

func TestRollbackGateReplyRollsAHardenedVaultOnlyWithItsSecret(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "gatese", "horse battery staple correct"
	se := hardenedWithData(t, base, name, pass)
	if got := rollbackGateReply(base, name, pass, nil); got != "ERR" {
		t.Fatalf("without the secret the hardened vault answered %q, want ERR", got)
	}
	if got := rollbackGateReply(base, name, pass, se); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("with its secret the hardened vault answered %q, want OK <v>", got)
	}
}

func TestRollbackGateReplyStillRollsAPassOnlyProfile(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "gateplain", "horse battery staple correct"
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), bytes.Repeat([]byte("payload"), 900), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	if got := rollbackGateReply(base, name, pass, seFromHex("")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("a pass-only profile answered %q with an empty secret, want OK <v>", got)
	}
}

func TestRollbackGateReplyWithNoEarlierVersionIsNOSNAP(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "gatenone", "horse battery staple correct"
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if got := rollbackGateReply(base, name, pass, nil); got != "NOSNAP" {
		t.Fatalf("a profile with no earlier version answered %q, want NOSNAP", got)
	}
}

// The wiring a behavioural test cannot reach: the dispatcher and handler hardcode the "s3" store.
func TestRollbackGateWireCarriesTheSecret(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, `if name == "ROLLBACK-GATE" {`)
	if i < 0 {
		t.Fatal("the ROLLBACK-GATE arm is gone -- this test is stale, not the code")
	}
	arm := strings.Join(stripComments(strings.Split(src[i:i+2000], "\n")), "\n")
	arm = arm[:strings.Index(arm, "return")]
	if n := strings.Count(arm, "r.ReadString('\\n')"); n != 3 {
		t.Errorf("the ROLLBACK-GATE arm reads %d lines, want 3 (name, pass, secret)", n)
	}
	if !strings.Contains(arm, `strings.TrimRight(gs, "\r\n"))`) {
		t.Errorf("the ROLLBACK-GATE arm does not hand the third line to handleRollbackGate:\n%s", arm)
	}
	h := strings.Join(stripComments(funcBody(t, src, "handleRollbackGate")), "\n")
	if !strings.Contains(h, `rollbackGateReply("s3", name, pass, seFromHex(se))`) {
		t.Errorf("handleRollbackGate does not hand seFromHex(se) to the helper:\n%s", h)
	}
	r := strings.Join(stripComments(funcBody(t, src, "rollbackGateReply")), "\n")
	if !strings.Contains(r, "rollbackHead(base, name, pass, 0, se)") {
		t.Errorf("rollbackGateReply does not hand the secret to rollbackHead:\n%s", r)
	}
}
