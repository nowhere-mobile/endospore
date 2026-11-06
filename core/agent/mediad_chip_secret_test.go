package main

import (
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261007-16: mediad needs the session's chip secret to serve a TIED profile. Found on lynx 2026100702: in the
// session that tied, the daemon's next start exited ("profile does not open on this phone") and left its mounts
// dead under the seal walk, so #media refused; in the next, tied session it exited at every start.

func TestKickMediadCarriesTheChipSecret(t *testing.T) {
	for _, se := range []string{"0a1b2c3d", ""} {
		dest := t.TempDir()
		if err := markRoamSession(dest, "nm", "pw", "10", se); err != nil {
			t.Fatal(err)
		}
		kickMediad(dest)
		b, err := os.ReadFile(filepath.Join(dest, "mediad.req"))
		if err != nil {
			t.Fatalf("se=%q: no mediad.req: %v", se, err)
		}
		if got, want := string(b), "nm\npw\n10\n"+se+"\n"; got != want {
			t.Fatalf("se=%q: mediad.req = %q, want %q (line 4 is the session's chip secret)", se, got, want)
		}
	}
}

func TestAdoptStagedSESecret(t *testing.T) {
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	staged := filepath.Join(state, ".pw.mediad.abc123")
	if err := os.WriteFile(staged, []byte("c0ffee"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_SE_SECRET", argFilePrefix+staged)
	adoptStagedSESecret()
	if got := os.Getenv("NOWHERE_SE_SECRET"); got != "c0ffee" {
		t.Fatalf("a staged secret resolves to %q, want the file's contents", got)
	}
	if _, err := os.Stat(staged); !os.IsNotExist(err) {
		t.Fatal("the staged secret file is still there: it must be consumed at startup")
	}

	t.Setenv("NOWHERE_SE_SECRET", "deadbeef") // roamd passes the value itself: untouched
	adoptStagedSESecret()
	if got := os.Getenv("NOWHERE_SE_SECRET"); got != "deadbeef" {
		t.Fatalf("a literal secret became %q", got)
	}

	other := filepath.Join(state, "nowhere.conf") // not one of ours: neither read nor unlinked
	os.WriteFile(other, []byte("x"), 0o600)
	t.Setenv("NOWHERE_SE_SECRET", argFilePrefix+other)
	adoptStagedSESecret()
	if got := os.Getenv("NOWHERE_SE_SECRET"); got != argFilePrefix+other {
		t.Fatalf("a path that is not a staged secret was resolved to %q", got)
	}
	if _, err := os.Stat(other); err != nil {
		t.Fatal("a path that is not a staged secret was unlinked")
	}

	// And main resolves it for every verb, right beside the @file: arguments.
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "\tos.Args = resolveArgFiles(os.Args)\n\tadoptStagedSESecret()\n\tswitch os.Args[1] {") {
		t.Fatal("main no longer calls adoptStagedSESecret before the dispatch: mediad would read the path as the secret")
	}
}

// mediad's own check (scopeOwnerLocked) passes a tied profile only with this phone's chip secret.
func TestMediadOpensATiedProfileWithTheChip(t *testing.T) {
	_, name, pass, _ := tieFixture(t, hex.EncodeToString(seA))
	if err := sessionTie("s3", name, pass, seA); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_SE_SECRET", "")
	if l, u := scopeOwnerLocked("s3", name+"#media", pass); !l || u {
		t.Fatal("control: without the chip secret a tied profile should read as locked to another phone")
	}
	t.Setenv("NOWHERE_SE_SECRET", hex.EncodeToString(seA))
	if l, u := scopeOwnerLocked("s3", name+"#media", pass); l || u {
		t.Fatal("with this phone's chip secret mediad still reads the tied profile as locked: it would exit")
	}
}

// The launcher stages the secret from mediad.req line 4 before the exec, as a file, never as a value.
func TestMediadLauncherStagesTheChipSecret(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "vendor-common", "bin", "nowhere_mediad.sh"))
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	read := "IFS= read -r sesec; } < \"$REQ\"   # line 4, NWP-20261007-16: the session's chip secret, empty when there is none\n"
	consume := "rm -f \"$REQ\"                          # consume creds immediately"
	export := "\n[ -n \"$sesec\" ] && export NOWHERE_SE_SECRET=\"$(pw \"$sesec\")\"\nunset sesec\n"
	exec := "exec \"$AGENT\" mediad s3"
	for _, want := range []string{read, consume, export, exec} {
		if strings.Count(src, want) < 1 {
			t.Fatalf("nowhere_mediad.sh lacks %q", want)
		}
	}
	if !(strings.Index(src, read) < strings.Index(src, consume) &&
		strings.Index(src, consume) < strings.Index(src, export) &&
		strings.Index(src, export) < strings.Index(src, exec)) {
		t.Fatal("nowhere_mediad.sh must read line 4, consume the req, stage the secret, THEN exec the agent")
	}
	if strings.Count(src, "NOWHERE_SE_SECRET=") != 1 {
		t.Fatal("nowhere_mediad.sh sets NOWHERE_SE_SECRET more than once: a second, literal export would put the value in the daemon's environment")
	}
}

// NWP-20261112-29: mediad holds the FIDO2 hmac for the whole session on a 2FA profile, so it is staged like the chip
// secret: only the path stays in /proc/<pid>/environ, and the agent adopts the value before the dispatch.
func TestAdoptStagedFido2Hmac(t *testing.T) {
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	t.Setenv("NOWHERE_SE_SECRET", "")
	hmacHex := strings.Repeat("a5", fido2HMACLen)
	staged := filepath.Join(state, ".pw.mediad.hm4c01")
	if err := os.WriteFile(staged, []byte(hmacHex+"\n"), 0o600); err != nil { // pw writes with print -r: one newline
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_FIDO2_HMAC", argFilePrefix+staged)
	adoptStagedSESecret()
	if got := os.Getenv("NOWHERE_FIDO2_HMAC"); got != hmacHex {
		t.Fatalf("a staged hmac resolves to %q, want the file's contents", got)
	}
	if _, err := os.Stat(staged); !os.IsNotExist(err) {
		t.Fatal("the staged hmac file is still there: it must be consumed at startup")
	}
	want, _ := hex.DecodeString(hmacHex)
	if got := fido2HMAC(); len(got) != fido2HMACLen || string(got) != string(want) {
		t.Fatalf("after adoption fido2HMAC() = %x, want the staged %d bytes: mediad could not open the 2FA vault", got, fido2HMACLen)
	}

	t.Setenv("NOWHERE_FIDO2_HMAC", hmacHex) // roamd passes the value itself: untouched
	adoptStagedSESecret()
	if got := os.Getenv("NOWHERE_FIDO2_HMAC"); got != hmacHex {
		t.Fatalf("a literal hmac became %q", got)
	}

	other := filepath.Join(state, "nowhere.conf") // not one of ours: neither read nor unlinked
	if err := os.WriteFile(other, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_FIDO2_HMAC", argFilePrefix+other)
	adoptStagedSESecret()
	if got := os.Getenv("NOWHERE_FIDO2_HMAC"); got != argFilePrefix+other {
		t.Fatalf("a path that is not a staged hmac was resolved to %q", got)
	}
	if _, err := os.Stat(other); err != nil {
		t.Fatal("a path that is not a staged hmac was unlinked")
	}
}

// The launcher stages the hmac through pw before the exec, as a file, never as a value.
func TestMediadLauncherStagesTheHmac(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "vendor-common", "bin", "nowhere_mediad.sh"))
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	line := "\n[ -f \"$STATE/.fido2hmac\" ] && export NOWHERE_FIDO2_HMAC=\"$(pw \"$(cat \"$STATE/.fido2hmac\")\")\"\n"
	if n := strings.Count(src, line); n != 1 {
		t.Fatalf("nowhere_mediad.sh holds the staged hmac export %d times, want exactly once: %q", n, line)
	}
	if strings.Count(src, "NOWHERE_FIDO2_HMAC=") != 1 {
		t.Fatal("nowhere_mediad.sh sets NOWHERE_FIDO2_HMAC more than once: a second, literal export would put the value in the daemon's environment")
	}
	def := strings.Index(src, "\npw() {\n")
	if def < 0 || def > strings.Index(src, line) {
		t.Fatal("nowhere_mediad.sh must define pw() before it stages the hmac")
	}
	if strings.Index(src, line) > strings.Index(src, "exec \"$AGENT\" mediad s3") {
		t.Fatal("nowhere_mediad.sh must stage the hmac BEFORE it execs the agent")
	}
}
