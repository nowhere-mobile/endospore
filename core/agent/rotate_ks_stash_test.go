package main

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261019-29: a committed rotation re-keys roamd's keystore-push stash ($STATE/ks-logoff-creds), so an
// orphan-sweep reap that runs no `out` first does not seal `name#keys` under the retired passphrase.

const (
	ksName = "ksstashrot"
	ksOld  = "horse battery staple correct"
	ksNew  = "a completely different passphrase"
	ksSE   = "0123456789abcdef"
)

func ksStashBody(name, pass string) []byte {
	return []byte(name + "\n" + pass + "\n10\n" + ksSE + "\n")
}

func plantKsStash(t *testing.T, dest string, body []byte) string {
	t.Helper()
	p := filepath.Join(dest, ksLogoffCredsFile)
	if err := os.WriteFile(p, body, 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func wantKsStash(t *testing.T, p string, want []byte) {
	t.Helper()
	got, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("reading the stash: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Errorf("stash = %q, want %q", got, want)
	}
}

// captureStderr returns what fn wrote to os.Stderr.
func ksCaptureStderr(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	saved := os.Stderr
	os.Stderr = w
	done := make(chan string)
	go func() { b, _ := io.ReadAll(r); done <- string(b) }()
	fn()
	os.Stderr = saved
	w.Close()
	return <-done
}

// ksLiveRotation stands up a live session for (ksName, ksOld), and returns the dest.
func ksLiveRotation(t *testing.T) string {
	t.Helper()
	dest := capRotateFixture(t)
	stubRekey(t, "OK")
	if createVault("s3", ksName, ksOld) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	liveMarker(t, dest, ksName, ksOld, "10", "")
	return dest
}

func TestRotateRekeysTheKeystorePushStash(t *testing.T) {
	dest := ksLiveRotation(t)
	p := plantKsStash(t, dest, ksStashBody(ksName, ksOld))
	var logs string
	var got string
	logs = ksCaptureStderr(t, func() { got = rotateVerb(t, dest, ksName, ksOld, ksNew) })
	if !strings.HasPrefix(got, "OK") {
		t.Fatalf("rotation replied %q, want OK*", got)
	}
	wantKsStash(t, p, ksStashBody(ksName, ksNew))
	if !strings.Contains(logs, "[logind] rotate: keystore-push stash re-keyed to the new passphrase") {
		t.Errorf("no re-key log line in %q", logs)
	}
	// (g) neither passphrase reaches the log.
	for _, secret := range []string{ksOld, ksNew, ksName} {
		if strings.Contains(logs, secret) {
			t.Errorf("the log carries %q", secret)
		}
	}
}

func TestRotateLeavesAnotherPassphrasesStashAlone(t *testing.T) {
	dest := ksLiveRotation(t)
	body := ksStashBody(ksName, "some other passphrase")
	p := plantKsStash(t, dest, body)
	if got := rotateVerb(t, dest, ksName, ksOld, ksNew); !strings.HasPrefix(got, "OK") {
		t.Fatalf("rotation replied %q, want OK*", got)
	}
	wantKsStash(t, p, body)
}

func TestRotateLeavesAnotherNamesStashAlone(t *testing.T) {
	dest := ksLiveRotation(t)
	body := ksStashBody("someone-else", ksOld)
	p := plantKsStash(t, dest, body)
	if got := rotateVerb(t, dest, ksName, ksOld, ksNew); !strings.HasPrefix(got, "OK") {
		t.Fatalf("rotation replied %q, want OK*", got)
	}
	wantKsStash(t, p, body)
}

func TestRotateWithoutAStashCreatesNone(t *testing.T) {
	dest := ksLiveRotation(t)
	if got := rotateVerb(t, dest, ksName, ksOld, ksNew); !strings.HasPrefix(got, "OK") {
		t.Fatalf("rotation replied %q, want OK*", got)
	}
	if _, err := os.Stat(filepath.Join(dest, ksLogoffCredsFile)); !os.IsNotExist(err) {
		t.Errorf("a rotation with no stash left one behind (stat err %v)", err)
	}
}

// A refused keyguard re-key never reaches the vault.
func TestRefusedKeyguardRekeyLeavesTheStash(t *testing.T) {
	dest := capRotateFixture(t)
	stubRekey(t, "ERR")
	if createVault("s3", ksName, ksOld) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	liveMarker(t, dest, ksName, ksOld, "10", "")
	body := ksStashBody(ksName, ksOld)
	p := plantKsStash(t, dest, body)
	if got := rotateVerb(t, dest, ksName, ksOld, ksNew); got != "ERR-REKEY" {
		t.Fatalf("rotation replied %q, want ERR-REKEY", got)
	}
	wantKsStash(t, p, body)
}

// A rotation the vault refuses before any retirement. The stash sits at exactly the (name, oldpass) the request
// carries, so only the call site -- not the helper's own match -- keeps it as it was.
func TestRejectedRotationLeavesTheStash(t *testing.T) {
	dest := capRotateFixture(t)
	stubRekey(t, "OK")
	if createVault("s3", ksName, "the real passphrase of this profile") == "" {
		t.Fatal("createVault returned no recovery code")
	}
	liveMarker(t, dest, ksName, ksOld, "10", "")
	body := ksStashBody(ksName, ksOld)
	p := plantKsStash(t, dest, body)
	if got := rotateVerb(t, dest, ksName, ksOld, ksNew); strings.HasPrefix(got, "OK") {
		t.Fatal("the rotation under a passphrase that opens nothing was accepted")
	}
	wantKsStash(t, p, body)
}

func TestPartialRetireRekeysTheStash(t *testing.T) {
	rb := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = rb })

	dest := ksLiveRotation(t)
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", ksName, ksOld, d)
	p := plantKsStash(t, dest, ksStashBody(ksName, ksOld))

	victim := ""
	capStorePutHook = func(key string, body []byte) error {
		if victim == "" && strings.HasPrefix(key, "ref/") && len(body) == 0 {
			victim = key
		}
		if key == victim {
			return errTestStoreRefused
		}
		return nil
	}
	got := rotateVerb(t, dest, ksName, ksOld, ksNew)
	capStorePutHook = nil
	if victim == "" {
		t.Fatal("precondition: no retirement was attempted")
	}
	if got != "ERR-SESSION" {
		t.Fatalf("partial commit replied %q, want ERR-SESSION", got)
	}
	wantKsStash(t, p, ksStashBody(ksName, ksNew))
}

// Only the four-line, newline-terminated shape roamd writes is re-keyed; a short, unterminated or over-long
// file that merely starts with (name, oldpass) is left byte for byte.
func TestRotateLeavesAMalformedStashAlone(t *testing.T) {
	for label, body := range map[string]string{
		"two lines":    ksName + "\n" + ksOld + "\n",
		"three lines":  ksName + "\n" + ksOld + "\n10\n",
		"unterminated": ksName + "\n" + ksOld + "\n10\n" + ksSE,
		"five lines":   ksName + "\n" + ksOld + "\n10\n" + ksSE + "\nextra\n",
		"empty":        "",
	} {
		t.Run(label, func(t *testing.T) {
			dest := ksLiveRotation(t)
			p := plantKsStash(t, dest, []byte(body))
			if got := rotateVerb(t, dest, ksName, ksOld, ksNew); !strings.HasPrefix(got, "OK") {
				t.Fatalf("rotation replied %q, want OK*", got)
			}
			wantKsStash(t, p, []byte(body))
		})
	}
}

// The re-keyed stash is 0600 even when a fixed-name temp of the old kind was left lying around with another
// mode, and no temp is left behind.
func TestRotatedStashIsPrivateAndLeavesNoTemp(t *testing.T) {
	dest := ksLiveRotation(t)
	p := plantKsStash(t, dest, ksStashBody(ksName, ksOld))
	if err := os.WriteFile(p+".tmp", []byte("junk"), 0o666); err != nil {
		t.Fatal(err)
	}
	if got := rotateVerb(t, dest, ksName, ksOld, ksNew); !strings.HasPrefix(got, "OK") {
		t.Fatalf("rotation replied %q, want OK*", got)
	}
	st, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Errorf("stash mode = %v, want 0600", st.Mode().Perm())
	}
	left, _ := filepath.Glob(p + ".tmp-*")
	if len(left) != 0 {
		t.Errorf("temp files left behind: %v", left)
	}
}
