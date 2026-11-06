package main

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

// NWP-20260916-01: the login daemon opened the profile for LIST-MEDIA-APPS through resolveKey, which reaches a
// tied vault's `se` slot only via NOWHERE_SE_SECRET -- exported by the roamd worker alone. So a tied profile
// with no security key answered ERR, and the Offline media screen called that "nothing to manage".

// resolveKeySession opens a tied vault with the session's secret and no environment, which is the daemon's
// situation; the plain form does not, and nil keeps the plain form's behaviour.
func TestResolveKeySessionOpensATiedVaultWithoutTheEnv(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "alice", "correct horse battery staple"
	createVault(base, name, pass)
	dk0, _, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatal("setup: the untied vault should open with its passphrase")
	}
	se := bytes.Repeat([]byte{7}, 32)
	if err := enrollSE(base, name, pass, se); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}
	t.Setenv("NOWHERE_SE_SECRET", "") // the daemon's environment

	if _, _, ok := resolveKey(base, name, pass); ok {
		t.Fatal("control: a tied vault opened with the passphrase alone, so this test cannot tell the two forms apart")
	}
	dk, _, ok := resolveKeySession(base, name, pass, se)
	if !ok || !bytes.Equal(dk, dk0) {
		t.Fatal("resolveKeySession did not open the tied vault with the session's secret")
	}
	if _, _, ok := resolveKeySession(base, name, pass, nil); ok {
		t.Fatal("resolveKeySession with no secret opened a tied vault: nil must walk the plain ladder")
	}
	if _, _, ok := resolveKeySession(base, name, pass, bytes.Repeat([]byte{8}, 32)); ok {
		t.Fatal("a wrong secret opened the tied vault")
	}
}

// The handler takes the session's secret, and uses it for BOTH opens: the vault and the #media scope.
func TestListMediaAppsOpensWithTheSessionSecret(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, `if name == "LIST-MEDIA-APPS" {`)
	if i < 0 {
		t.Fatal("LIST-MEDIA-APPS handler not found")
	}
	h := src[i:]
	h = h[:strings.Index(h, `if name == "PIN-MATERIALIZE" {`)]
	if !strings.Contains(h, "se := seFromSession(dest)") {
		t.Error("LIST-MEDIA-APPS no longer reads the session's secure-element secret")
	}
	if n := strings.Count(h, `resolveKeySession("s3", `); n != 2 {
		t.Errorf("LIST-MEDIA-APPS opens %d head(s) with the session secret, want 2 (the vault and #media)", n)
	}
	if strings.Contains(h, `resolveKey("s3"`) {
		t.Error("LIST-MEDIA-APPS still opens a head without the session secret")
	}
}
