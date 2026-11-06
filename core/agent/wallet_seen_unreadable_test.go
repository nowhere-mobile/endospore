package main

// NWP-20261118-12: a wallet seen-set that is there but cannot be read whole poisons its generation. noteWalletSeen
// used to treat it as no set at all and rewrite it from the current wallet alone; the next publish then took a token
// this session held and spent back from the stored copy, as the other phone's credit. A short set is worse than none
// (decided 2026-10-20 Q107), so an unreadable set poisons the generation as a failed write does. An absent set, or one
// of another generation, still starts afresh.

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// seenUnreadableWallet makes a fresh wallet path and generation in the test's own temp dir, so the process-global
// poison map cannot carry one test's verdict into another.
func seenUnreadableWallet(t *testing.T) (wpath, gen string) {
	t.Helper()
	wpath = filepath.Join(t.TempDir(), "wallet.json")
	if err := bumpWalletGeneration(wpath); err != nil {
		t.Fatal(err)
	}
	return wpath, walletGeneration(wpath)
}

// seenFileIsOnly reports whether .seen is exactly the generation line followed by the one key.
func seenFileIsOnly(t *testing.T, wpath, gen, key string) bool {
	t.Helper()
	raw, err := os.ReadFile(wpath + ".seen")
	if err != nil {
		return false
	}
	return string(raw) == gen+"\n"+key+"\n"
}

// assertSeenUnreadablePoisons is the verdict every unreadable case shares: the save is not refused, the generation
// is poisoned, walletSeen answers nil, and .seen was not rewritten as a set holding only B.
func assertSeenUnreadablePoisons(t *testing.T, wpath, gen string) {
	t.Helper()
	if err := noteWalletSeen(wpath, &Wallet{Tokens: []Token{{Nonce: "B"}}}); err != nil {
		t.Fatalf("noteWalletSeen = %v, want nil (the poison marker could be written)", err)
	}
	if !isSeenPoisoned(wpath, gen) {
		t.Fatal("a seen-set that could not be read whole did not poison its generation")
	}
	if s := walletSeen(wpath, gen); s != nil {
		t.Fatalf("walletSeen = %v after the poison, want nil", s)
	}
	if seenFileIsOnly(t, wpath, gen, "t:B") {
		t.Fatal("the unreadable seen-set was rewritten as a SHORT set holding only t:B")
	}
}

func TestWalletSeenUnreadable_ByLength(t *testing.T) {
	wpath, gen := seenUnreadableWallet(t)
	var b bytes.Buffer
	b.WriteString(gen + "\nt:A\n")
	b.Write(bytes.Repeat([]byte("x"), 16*1024*1024+1)) // past the scanner's 16 MiB cap: bufio.ErrTooLong
	b.WriteString("\n")
	if err := os.WriteFile(wpath+".seen", b.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	assertSeenUnreadablePoisons(t, wpath, gen)
	stored := &Wallet{Tokens: []Token{{Nonce: "A"}, {Nonce: "B"}}}
	local := &Wallet{Tokens: []Token{{Nonce: "B"}}}
	got := walletForPublish(stored, local, walletSeen(wpath, gen))
	for _, tok := range got.Tokens {
		if tok.Nonce == "A" {
			t.Fatalf("the spent token A came back from the stored copy: %v", got.Tokens)
		}
	}
}

func TestWalletSeenUnreadable_Empty(t *testing.T) {
	wpath, gen := seenUnreadableWallet(t)
	if err := os.WriteFile(wpath+".seen", nil, 0o600); err != nil {
		t.Fatal(err)
	}
	assertSeenUnreadablePoisons(t, wpath, gen)
}

func TestWalletSeenUnreadable_ByOpen(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("as root, chmod-000 denies nothing")
	}
	wpath, gen := seenUnreadableWallet(t)
	seen := wpath + ".seen"
	if err := os.WriteFile(seen, []byte(gen+"\nt:A\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(seen, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(seen, 0o600) })
	assertSeenUnreadablePoisons(t, wpath, gen)
}

// assertSeenStartsOrGrows checks a case that must NOT poison: the save lands, no marker is written, and walletSeen
// reads exactly want.
func assertSeenStartsOrGrows(t *testing.T, wpath, gen string, want ...string) {
	t.Helper()
	if err := noteWalletSeen(wpath, &Wallet{Tokens: []Token{{Nonce: "B"}}}); err != nil {
		t.Fatalf("noteWalletSeen = %v, want nil", err)
	}
	if isSeenPoisoned(wpath, gen) {
		t.Fatal("a readable or absent seen-set poisoned its generation")
	}
	if _, err := os.Stat(seenBadPath(wpath)); err == nil {
		t.Fatal("a poison marker was written for a readable or absent seen-set")
	}
	s := walletSeen(wpath, gen)
	if len(s) != len(want) {
		t.Fatalf("walletSeen = %v, want %v", s, want)
	}
	for _, k := range want {
		if !s[k] {
			t.Fatalf("walletSeen = %v, want %v", s, want)
		}
	}
}

func TestWalletSeenUnreadable_AnotherGenerationStartsAfresh(t *testing.T) {
	wpath, gen := seenUnreadableWallet(t)
	if err := os.WriteFile(wpath+".seen", []byte("an-older-generation\nt:X\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	assertSeenStartsOrGrows(t, wpath, gen, "t:B")
}

func TestWalletSeenUnreadable_AbsentStartsAfresh(t *testing.T) {
	wpath, gen := seenUnreadableWallet(t)
	assertSeenStartsOrGrows(t, wpath, gen, "t:B")
	if !seenFileIsOnly(t, wpath, gen, "t:B") {
		t.Fatal("an absent seen-set was not written as the generation and t:B")
	}
}

func TestWalletSeenUnreadable_AReadableSetGrows(t *testing.T) {
	wpath, gen := seenUnreadableWallet(t)
	if err := os.WriteFile(wpath+".seen", []byte(gen+"\nt:A\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	assertSeenStartsOrGrows(t, wpath, gen, "t:A", "t:B")
}
