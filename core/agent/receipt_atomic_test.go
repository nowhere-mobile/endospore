package main

// NWP-20261112-20: restore receipts and login rosters are published by temp + rename (publishReceiptFile).
// writeRestoreReceipt and writeLoginRoster used to rewrite their file in place with os.WriteFile and drop the
// error, so a full state tmpfs left an EMPTY receipt (the existence gate passed, the stale-base guard read ""
// and was skipped) and a reader racing a rewrite could see a torn head. R1-R3 fail on the in-place writers;
// R4 and R5 are controls.

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var (
	receiptAtomicH1 = strings.Repeat("1f", 32)
	receiptAtomicH2 = strings.Repeat("2e", 32)
)

// plantNonEmptyDir puts a directory holding one file at p, so neither os.WriteFile(p) nor a rename over p
// can succeed.
func plantNonEmptyDir(t *testing.T, p string) {
	t.Helper()
	if err := os.MkdirAll(p, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(p, "x"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func assertNoTemp(t *testing.T, f string) {
	t.Helper()
	if _, err := os.Lstat(f + ".tmp"); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("%s.tmp is left behind (Lstat err=%v)", filepath.Base(f), err)
	}
}

// R1: a reader that opened the receipt before a rewrite reads the whole OLD receipt, never the new one or a
// truncated file.
func TestReceiptAtomic_ARewriteNeverTearsAnOpenRead(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	ref := strings.Repeat("a1", 32)
	writeRestoreReceipt(ref, receiptAtomicH1)
	f := receiptFile(ref)
	fd, err := os.Open(f)
	if err != nil {
		t.Fatal(err)
	}
	defer fd.Close()
	writeRestoreReceipt(ref, receiptAtomicH2)
	b, err := io.ReadAll(fd)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != receiptAtomicH1+"\n" {
		t.Fatalf("the open fd read %q, want the previous receipt %q: the receipt was rewritten in place", b, receiptAtomicH1+"\n")
	}
	if got := restoreReceiptHead(ref); got != receiptAtomicH2 {
		t.Fatalf("restoreReceiptHead = %q, want %q", got, receiptAtomicH2)
	}
	assertNoTemp(t, f)
}

// R2: a write that fails (here: the temp cannot be created) leaves the previous receipt exactly as it was.
func TestReceiptAtomic_AFailedWriteKeepsThePreviousReceipt(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	ref := strings.Repeat("b2", 32)
	writeRestoreReceipt(ref, receiptAtomicH1)
	plantNonEmptyDir(t, receiptFile(ref)+".tmp")
	writeRestoreReceipt(ref, receiptAtomicH2)
	if got := restoreReceiptHead(ref); got != receiptAtomicH1 {
		t.Fatalf("after a failed write restoreReceiptHead = %q, want the previous %q", got, receiptAtomicH1)
	}
	if !haveRestoreReceipt(ref) {
		t.Fatal("after a failed write the receipt is gone")
	}
}

// R3a: R1 for the login roster.
func TestReceiptAtomic_ALoginRosterRewriteNeverTearsAnOpenRead(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	ref := strings.Repeat("c3", 32)
	writeLoginRoster(ref, receiptAtomicH1)
	f := loginRosterFile(ref)
	fd, err := os.Open(f)
	if err != nil {
		t.Fatal(err)
	}
	defer fd.Close()
	writeLoginRoster(ref, receiptAtomicH2)
	b, err := io.ReadAll(fd)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != receiptAtomicH1 {
		t.Fatalf("the open fd read %q, want the previous roster %q: the roster was rewritten in place", b, receiptAtomicH1)
	}
	if got := loginRosterHead(ref); got != receiptAtomicH2 {
		t.Fatalf("loginRosterHead = %q, want %q", got, receiptAtomicH2)
	}
	assertNoTemp(t, f)
}

// R3b: a failed roster write keeps the old roster AND its walked roster (the pair the carry was built on); a
// successful one replaces the roster and removes the walked roster.
func TestReceiptAtomic_AFailedLoginRosterWriteKeepsTheRosterAndItsWalkedRoster(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	ref := strings.Repeat("d4", 32)
	dk := []byte(strings.Repeat("k", 32))
	writeLoginRoster(ref, receiptAtomicH1)
	recordWalkedRoster(ref, dk, []string{"DCIM/a.png"})
	w := walkedRosterFile(ref)
	if _, err := os.Stat(w); err != nil {
		t.Fatalf("setup: the walked roster was not recorded: %v", err)
	}
	planted := loginRosterFile(ref) + ".tmp"
	plantNonEmptyDir(t, planted)
	writeLoginRoster(ref, receiptAtomicH2)
	if got := loginRosterHead(ref); got != receiptAtomicH1 {
		t.Fatalf("after a failed write loginRosterHead = %q, want the previous %q", got, receiptAtomicH1)
	}
	if _, err := os.Stat(w); err != nil {
		t.Fatalf("after a failed roster write the walked roster is gone: %v", err)
	}
	if err := os.RemoveAll(planted); err != nil {
		t.Fatal(err)
	}
	writeLoginRoster(ref, receiptAtomicH2)
	if got := loginRosterHead(ref); got != receiptAtomicH2 {
		t.Fatalf("after a successful write loginRosterHead = %q, want %q", got, receiptAtomicH2)
	}
	if _, err := os.Stat(w); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("after a successful roster write the walked roster is still there (Stat err=%v)", err)
	}
}

// R4 (control): a first write creates the receipt; with NOWHERE_STATE unset nothing is written.
func TestReceiptAtomic_AFirstWriteCreatesTheReceipt(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	ref := strings.Repeat("e5", 32)
	if haveRestoreReceipt(ref) {
		t.Fatal("a fresh ref already has a receipt")
	}
	writeRestoreReceipt(ref, receiptAtomicH1)
	if !haveRestoreReceipt(ref) {
		t.Fatal("the first write did not create the receipt")
	}
	if got := restoreReceiptHead(ref); got != receiptAtomicH1 {
		t.Fatalf("restoreReceiptHead = %q, want %q", got, receiptAtomicH1)
	}
	assertNoTemp(t, receiptFile(ref))
	before, err := os.ReadDir(filepath.Join(st, "restore-receipts"))
	if err != nil {
		t.Fatal(err)
	}

	t.Setenv("NOWHERE_STATE", "")
	ref2 := strings.Repeat("e6", 32)
	if f := receiptFile(ref2); f != "" {
		t.Fatalf("receiptFile with NOWHERE_STATE unset = %q, want \"\"", f)
	}
	if f := loginRosterFile(ref2); f != "" {
		t.Fatalf("loginRosterFile with NOWHERE_STATE unset = %q, want \"\"", f)
	}
	writeRestoreReceipt(ref2, receiptAtomicH2)
	writeLoginRoster(ref2, receiptAtomicH2)
	after, err := os.ReadDir(filepath.Join(st, "restore-receipts"))
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != len(before) {
		t.Fatalf("with NOWHERE_STATE unset the receipts dir went from %d to %d entries", len(before), len(after))
	}
}

// R5 (control): when the temp write succeeds and the rename fails (a non-empty directory sits at the
// receipt path), the writer returns and leaves no temp behind.
func TestReceiptAtomic_AFailedRenameLeavesNoTemp(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	ref := strings.Repeat("f6", 32)
	f := receiptFile(ref)
	plantNonEmptyDir(t, f)
	writeRestoreReceipt(ref, receiptAtomicH2)
	assertNoTemp(t, f)

	ref2 := strings.Repeat("f7", 32)
	r := loginRosterFile(ref2)
	plantNonEmptyDir(t, r)
	writeLoginRoster(ref2, receiptAtomicH2)
	assertNoTemp(t, r)
}
