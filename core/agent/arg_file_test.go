package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// DIA-20260812-02 (#106). resolveArgFiles is the ONLY thing standing between the profile passphrase and
// /proc/<pid>/cmdline, so these tests pin the three properties that make it worth having: the value arrives
// byte-exact (a mangled passphrase does not open the vault), the file is gone afterwards (a lingering file is
// the leak wearing a different hat), and a read failure is loud rather than silently substituting garbage.

// writeLikeShell mirrors what roamd's `pw` helper actually does: `print -r -- "$secret" > file`, i.e. the
// bytes verbatim plus exactly one newline. Measured on lynx, not assumed -- see the note on pw().
func writeLikeShell(t *testing.T, dir, secret string) string {
	t.Helper()
	f := filepath.Join(dir, ".pw.roamd.abc123") // the basename pw() actually produces; the marker requires it
	if err := os.WriteFile(f, []byte(secret+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestResolveArgFilesSubstitutesAndUnlinks(t *testing.T) {
	dir := t.TempDir()
	const secret = "correct horse battery staple"
	f := writeLikeShell(t, dir, secret)

	got := resolveArgFiles([]string{"nowhere_agent", "push", "s3", "alice", argFilePrefix + f, "/stage"})

	if got[4] != secret {
		t.Errorf("value not substituted: got %q, want %q", got[4], secret)
	}
	if _, err := os.Stat(f); !os.IsNotExist(err) {
		t.Errorf("pass file still on disk after resolve (err=%v) -- the leak just moved from argv to the filesystem", err)
	}
	// Everything that is not a @file: argument must be untouched, or a verb's positional contract breaks.
	for i, want := range []string{"nowhere_agent", "push", "s3", "alice"} {
		if got[i] != want {
			t.Errorf("arg %d rewritten: got %q, want %q", i, got[i], want)
		}
	}
	if got[5] != "/stage" {
		t.Errorf("arg 5 rewritten: got %q", got[5])
	}
}

func TestResolveArgFilesIsByteExact(t *testing.T) {
	// A passphrase is arbitrary user text. Backslashes are the specific hazard: `echo` on Android's shell
	// collapses them, which is why the writer is `print -r --`. If anything in this path mangles bytes the
	// key derives wrong and the profile silently will not open -- so assert the awkward characters directly.
	for _, secret := range []string{
		`a\b`,
		`back\\slash`,
		"tab\there",
		`quote"and'apostrophe`,
		`%s %d -n -e`, // printf format chars and echo-style flags
		`trailing spaces   `,
		`üñïçø∂é`,
		`#apps`, // leading '#' -- looks like a scope, must not be treated as one
		`@file:/not/a/path`,
		"",
	} {
		dir := t.TempDir()
		f := writeLikeShell(t, dir, secret)
		got := resolveArgFiles([]string{"x", "v", argFilePrefix + f})
		if got[2] != secret {
			t.Errorf("mangled: got %q, want %q", got[2], secret)
		}
	}
}

func TestResolveArgFilesStripsExactlyOneNewline(t *testing.T) {
	// `print -r --` adds one newline, so one is stripped. Only one: a value that genuinely ends in a newline
	// must still be representable, and over-trimming would silently change the secret.
	dir := t.TempDir()
	f := filepath.Join(dir, ".pw.roamd.nl")
	if err := os.WriteFile(f, []byte("secret\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := resolveArgFiles([]string{"x", "v", argFilePrefix + f})[2]; got != "secret\n" {
		t.Errorf("got %q, want %q", got, "secret\n")
	}
}

func TestResolveArgFilesResolvesEveryMarkedArg(t *testing.T) {
	// rotate/recover carry TWO secrets (old+new, mnemonic+new). A loop that stopped at the first match would
	// leave the second in argv, which is exactly the bug -- half-fixed and looking fixed.
	dir := t.TempDir()
	a, b := filepath.Join(dir, ".pw.roamd.a"), filepath.Join(dir, ".pw.roamd.b")
	if err := os.WriteFile(a, []byte("oldpass\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(b, []byte("newpass\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got := resolveArgFiles([]string{"x", "rotate", "s3", "alice", argFilePrefix + a, argFilePrefix + b})
	if got[4] != "oldpass" || got[5] != "newpass" {
		t.Errorf("got [%q %q], want [oldpass newpass]", got[4], got[5])
	}
	for _, f := range []string{a, b} {
		if _, err := os.Stat(f); !os.IsNotExist(err) {
			t.Errorf("%s survived", f)
		}
	}
}

func TestResolveArgFilesFailsLoudlyOnUnreadable(t *testing.T) {
	// Carrying on with the literal "@file:/..." as the passphrase would derive a DIFFERENT key: a push would
	// write a head nobody can open, a restore would report the profile empty. Stopping is the safe answer.
	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("no panic on an unreadable pass file -- the agent would have run with a bogus passphrase")
		}
		if e, ok := r.(error); !ok || !strings.Contains(e.Error(), "cannot read") {
			t.Errorf("unhelpful failure: %v", r)
		}
	}()
	resolveArgFiles([]string{"x", "v", argFilePrefix + filepath.Join(t.TempDir(), ".pw.roamd.absent")})
}

// The rest of this file guards the trust boundary on the marker. Found by an adversarial review of the first
// cut of this change, which pointed out that resolving before the dispatch switch -- deliberately, so every
// verb is covered -- also covers arguments that are NOT credentials. The profile name is unvalidated text
// typed at the gate and reaches an argv position verbatim, so without a check the marker turned a text field
// into a root read-and-unlink primitive. These tests exist so that cannot come back.

func TestResolveArgFilesIgnoresAnAttackerControlledPath(t *testing.T) {
	// A profile named "@file:/data/nowhere/nowhere.conf": the agent must NOT read it and must NOT delete it.
	// Deleting nowhere.conf would de-enrol the device from its store.
	dir := t.TempDir()
	victim := filepath.Join(dir, "nowhere.conf")
	if err := os.WriteFile(victim, []byte("GATEWAY_URL=https://example\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_STATE", dir)

	got := resolveArgFiles([]string{"x", "restore", "s3", argFilePrefix + victim, "@file:/etc/passwd", "/dest"})

	if got[3] != argFilePrefix+victim {
		t.Errorf("attacker-controlled arg was resolved: %q", got[3])
	}
	if _, err := os.Stat(victim); err != nil {
		t.Errorf("THE AGENT DELETED A FILE IT WAS POINTED AT: %v", err)
	}
	if got[4] != "@file:/etc/passwd" {
		t.Errorf("absolute non-staged path was touched: %q", got[4])
	}
}

func TestResolveArgFilesRefusesAStagedNameOutsideTheStateDir(t *testing.T) {
	// A .pw. file in the wrong place is one of OURS, misplaced. Silently treating it as a literal would make
	// the string "@file:/..." the passphrase and derive a different key, so this must stop loudly instead.
	elsewhere := t.TempDir()
	f := filepath.Join(elsewhere, ".pw.roamd.xyz")
	if err := os.WriteFile(f, []byte("secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_STATE", t.TempDir()) // a DIFFERENT dir

	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("a staged file outside NOWHERE_STATE was accepted")
		}
		if e, ok := r.(error); !ok || !strings.Contains(e.Error(), "outside NOWHERE_STATE") {
			t.Errorf("unhelpful failure: %v", r)
		}
	}()
	resolveArgFiles([]string{"x", "v", argFilePrefix + f})
}

func TestResolveArgFilesAcceptsBothServicePrefixes(t *testing.T) {
	// roamd and mediad namespace their staged files so neither service's startup sweep can delete the
	// other's in-flight file. Both must still resolve.
	for _, base := range []string{".pw.roamd.QQ1234", ".pw.mediad.ZZ9876"} {
		dir := t.TempDir()
		t.Setenv("NOWHERE_STATE", dir)
		f := filepath.Join(dir, base)
		if err := os.WriteFile(f, []byte("the-secret\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := resolveArgFiles([]string{"x", "v", argFilePrefix + f})[2]; got != "the-secret" {
			t.Errorf("%s did not resolve: got %q", base, got)
		}
	}
}

func TestResolveArgFilesLeavesOrdinaryArgsAlone(t *testing.T) {
	// The prefix is deliberately distinctive so no real argument collides with it: profile names, store
	// bases, package names and paths all pass through, and a bare "@" is not a marker.
	in := []string{"nowhere_agent", "restore", "s3", "alice#media", "@notmarked", "/data/user/12", "@file", "file:/x"}
	cp := append([]string(nil), in...)
	got := resolveArgFiles(in)
	for i := range cp {
		if got[i] != cp[i] {
			t.Errorf("arg %d changed: %q -> %q", i, cp[i], got[i])
		}
	}
}
