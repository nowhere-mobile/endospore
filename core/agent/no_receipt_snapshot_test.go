package main

import (
	"crypto/rand"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// NWP-20261203-16: every no-receipt seal refusal prints a codes-only snapshot of the receipts state, so the next
// device proof names why the receipt was missing (docs/backlog.md, "When the sign-out reap restarts the system
// server, the `#keys` seal that follows is refused for want of a restore-completion receipt ...").

// snapFill writes receipts for base, base#apps and base#keys, plus a roster, a walked roster and a temp file that
// are not receipts.
func snapFill(t *testing.T, base, pass string) {
	t.Helper()
	for _, n := range []string{base, base + "#apps", base + "#keys"} {
		writeRestoreReceipt(profileRefV2(n, pass), "head")
	}
	ref := profileRefV2(base, pass)
	for _, n := range []string{"roster." + ref, "walked." + ref, ref + ".tmp"} {
		if err := os.WriteFile(filepath.Join(restoreReceiptDir(), n), []byte("x\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

// snapPark makes $STATE/.in-park/restore-receipts and, when this is set, this profile's receipt in it.
func snapPark(t *testing.T, st, profile, pass string, this bool) {
	t.Helper()
	pr := filepath.Join(st, inParkDir, "restore-receipts")
	if err := os.MkdirAll(pr, 0o700); err != nil {
		t.Fatal(err)
	}
	f := filepath.Join(pr, profileRefV2(profile, pass))
	if this {
		if err := os.WriteFile(f, []byte("head\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	} else {
		os.Remove(f)
	}
}

func TestNoReceiptSnapshot_Shapes(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	base, pass := "snapshape", "snapshot shape horse battery"
	profile := base + "#keys"

	// (a) no receipts dir, no park.
	if got, want := receiptSnapshot(profile, pass), "dir=absent files=0 have=none park=absent"; got != want {
		t.Fatalf("(a) snapshot = %q, want %q", got, want)
	}

	// (b) three receipts and three entries that are not receipts.
	snapFill(t, base, pass)
	if got, want := receiptSnapshot(profile, pass), "dir=present files=3 have=vault,apps,keys park=absent"; got != want {
		t.Fatalf("(b) snapshot = %q, want %q", got, want)
	}

	// (c) a park with a receipts dir, with and without this profile's receipt.
	snapPark(t, st, profile, pass, true)
	if got := receiptSnapshot(profile, pass); !strings.HasSuffix(got, " park=present+rcpt+this") {
		t.Fatalf("(c) snapshot = %q, want park=present+rcpt+this", got)
	}
	snapPark(t, st, profile, pass, false)
	if got := receiptSnapshot(profile, pass); !strings.HasSuffix(got, " park=present+rcpt") {
		t.Fatalf("(c) snapshot = %q, want park=present+rcpt", got)
	}
	if err := os.RemoveAll(filepath.Join(st, inParkDir, "restore-receipts")); err != nil {
		t.Fatal(err)
	}
	if got := receiptSnapshot(profile, pass); !strings.HasSuffix(got, " park=present") {
		t.Fatalf("(c) snapshot = %q, want park=present", got)
	}

	// (d) the receipts path is a regular file.
	if err := os.RemoveAll(restoreReceiptDir()); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(restoreReceiptDir(), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := receiptSnapshot(profile, pass); !strings.HasPrefix(got, "dir=unreadable files=0 have=none ") {
		t.Fatalf("(d) snapshot = %q, want dir=unreadable files=0 have=none", got)
	}

	// (e) receipts are off.
	t.Setenv("NOWHERE_STATE", "")
	if got := receiptSnapshot(profile, pass); got != "" {
		t.Fatalf("(e) snapshot with NOWHERE_STATE unset = %q, want empty", got)
	}
}

func TestNoReceiptSnapshot_NoIdentity(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	base, pass := "snapnoid", "snapshot identity horse battery"
	profile := base + "#keys"
	snapFill(t, base, pass)
	snapPark(t, st, profile, pass, true)
	got := receiptSnapshot(profile, pass)
	if got == "" {
		t.Fatal("snapshot is empty with receipts on")
	}
	for _, bad := range []string{profile, base, st, restoreReceiptDir()} {
		if strings.Contains(got, bad) {
			t.Fatalf("snapshot %q holds an identity or a path", got)
		}
	}
	if regexp.MustCompile(`[0-9a-f]{64}`).MatchString(got) {
		t.Fatalf("snapshot %q holds a ref", got)
	}
}

func TestNoReceiptSnapshot_RefusalPrints(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Cleanup(func() { sealRefused = false; sealRefusedWhy = "" })
	base := newHTTPStore(t)
	name, pass := "snaprefuse", "snapshot refusal horse battery"
	profile := name + "#keys"
	createVault(base, name, pass)

	src1 := t.TempDir()
	big := make([]byte, 1<<20)
	if _, err := rand.Read(big); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src1, "one.bin"), big, 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, profile, pass, src1)
	head1 := headOf(base, profile, pass)
	if head1 == "" {
		t.Fatal("first #keys seal did not establish a head")
	}

	os.RemoveAll(restoreReceiptDir())
	src2 := t.TempDir()
	if err := os.WriteFile(filepath.Join(src2, "two.txt"), []byte("new bundle"), 0o600); err != nil {
		t.Fatal(err)
	}
	out := captureStdout(t, func() { pushProfile(base, profile, pass, src2) })
	if !strings.Contains(out, "SEAL REFUSED -- no restore-completion receipt") {
		t.Fatalf("no SEAL REFUSED line; output:\n%s", out)
	}
	if !strings.Contains(out, "push: #keys no-receipt snapshot: dir=absent") {
		t.Fatalf("no no-receipt snapshot line after the refusal; output:\n%s", out)
	}
	for _, l := range strings.Split(out, "\n") {
		if strings.Contains(l, "no-receipt snapshot:") && (strings.Contains(l, name) || strings.Contains(l, `"`)) {
			t.Fatalf("the snapshot line names the profile: %q", l)
		}
	}
	if got := headOf(base, profile, pass); got != head1 {
		t.Fatalf("the refused #keys seal moved the head (%s -> %s)", short(head1), short(got))
	}
}
