package main

import (
	"os"
	"path/filepath"
	"testing"
)

// DIA-20260812-06 (#111). The guards that REFUSE a seal used to print their reason and return with no error,
// so the agent exited 0 and roamd logged "sealed" while nothing had been stored. These tests pin the verdict
// flag the exit code is derived from -- the thing that makes a refusal distinguishable from success.
//
// Why the flag and not the exit status: os.Exit cannot be observed from a test, and pushProfile must NOT call
// it (its defers -- capFlush, then the push summary -- have to run first). main() reads sealRefused after
// pushProfile returns, so the flag IS the contract and asserting on it asserts on the behaviour.

func TestSealRefusedIsFalseOnAHealthySeal(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir()) // activates the receipt gate, as the real device has it
	base := newHTTPStore(t)
	name, pass := "alice", "correct horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	if sealRefused {
		t.Fatal("a healthy seal was flagged REFUSED -- roamd would now wrongly tell the user nothing was saved")
	}
}

func TestSealRefusedIsClearedPerCall(t *testing.T) {
	// The flag is package-level. A logoff seals five scopes in a row, so one refused scope must not mark
	// every later scope refused. pushProfile resets it on entry; this is the only thing keeping that true.
	t.Setenv("NOWHERE_STATE", t.TempDir())
	base := newHTTPStore(t)
	name, pass := "alice", "correct horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)

	sealRefused = true // poison, as a previously-refused scope would leave it
	pushProfile(base, name, pass, src)
	if sealRefused {
		t.Error("sealRefused survived a healthy pushProfile -- the per-call reset is missing, so one refused " +
			"scope would report every later scope as refused too")
	}
}
