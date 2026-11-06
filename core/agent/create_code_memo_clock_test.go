package main

import (
	"testing"
	"time"
)

// NWP-20261123-28: the recovery-code memo (Q048, h46 #7) measures its 5-minute window on CLOCK_BOOTTIME, so time the
// phone spends asleep counts. These tests drive bootNowMs and leave createCodeMemoNow at its production default.

const cmcBase = int64(3_600_000) // one hour since boot, in ms

// cmcBoot makes bootNowMs read *clk, starting at cmcBase, and restores it in Cleanup.
func cmcBoot(t *testing.T) *int64 {
	t.Helper()
	if createCodeMemoNow == nil {
		t.Fatal("createCodeMemoNow is nil")
	}
	clk := cmcBase
	old := bootNowMs
	bootNowMs = func() int64 { return clk }
	t.Cleanup(func() { bootNowMs = old; forgetCreatedCodes() })
	forgetCreatedCodes()
	return &clk
}

// cmcHas reports whether the memo holds an entry under k.
func cmcHas(k string) bool {
	createCodeMemoMu.Lock()
	defer createCodeMemoMu.Unlock()
	_, ok := createCodeMemo[k]
	return ok
}

// cmcLen is the number of entries in the memo.
func cmcLen() int {
	createCodeMemoMu.Lock()
	defer createCodeMemoMu.Unlock()
	return len(createCodeMemo)
}

const cmcWords = "w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12"

func TestCreateCodeMemoClockSuspendExpiresCreate(t *testing.T) {
	clk := cmcBoot(t)
	n, p := "cmc-suspend-create", "cmc suspend create passphrase"
	rememberCreatedCode(n, p, cmcWords)
	*clk = cmcBase + (6 * time.Minute).Milliseconds() // asleep for 6 minutes
	if got := takeCreatedCode(n, p); got != "" {
		t.Fatalf("take after a 6-minute suspend = %q, want nothing", got)
	}
	*clk = cmcBase
	rememberCreatedCode(n, p, cmcWords)
	*clk = cmcBase + (4 * time.Minute).Milliseconds()
	if got := takeCreatedCode(n, p); got != cmcWords {
		t.Fatalf("take after 4 minutes = %q, want the words", got)
	}
}

func TestCreateCodeMemoClockSuspendExpiresPromote(t *testing.T) {
	clk := cmcBoot(t)
	n, p := "cmc-suspend-promote", "cmc suspend promote passphrase"
	rememberPromotedCode(n, p, cmcWords)
	*clk = cmcBase + (6 * time.Minute).Milliseconds()
	if got := takePromotedCode(n, p); got != "" {
		t.Fatalf("take after a 6-minute suspend = %q, want nothing", got)
	}
	*clk = cmcBase
	rememberPromotedCode(n, p, cmcWords)
	*clk = cmcBase + (4 * time.Minute).Milliseconds()
	if got := takePromotedCode(n, p); got != cmcWords {
		t.Fatalf("take after 4 minutes = %q, want the words", got)
	}
}

func TestCreateCodeMemoClockSuspendPurges(t *testing.T) {
	clk := cmcBoot(t)
	n, p := "cmc-suspend-purge", "cmc suspend purge passphrase"
	rememberCreatedCode(n, p, cmcWords)
	*clk = cmcBase + (6 * time.Minute).Milliseconds()
	purgeExpiredCreatedCodes()
	if cmcHas(createCodeMemoKey(n, p)) {
		t.Fatal("the purge after a 6-minute suspend kept the entry")
	}
}

func TestCreateCodeMemoClockUnreadableKeepsNothing(t *testing.T) {
	n, p := "cmc-unreadable", "cmc unreadable passphrase"
	t.Run("remember", func(t *testing.T) {
		clk := cmcBoot(t)
		*clk = 0
		rememberCreatedCode(n, p, cmcWords)
		if cmcHas(createCodeMemoKey(n, p)) {
			t.Fatal("an unreadable boot clock stored the words")
		}
		*clk = cmcBase
		if got := takeCreatedCode(n, p); got != "" {
			t.Fatalf("take = %q, want nothing", got)
		}
	})
	t.Run("take", func(t *testing.T) {
		clk := cmcBoot(t)
		rememberCreatedCode(n, p, cmcWords)
		*clk = 0
		if got := takeCreatedCode(n, p); got != "" {
			t.Fatalf("take on an unreadable boot clock = %q, want nothing", got)
		}
		if cmcHas(createCodeMemoKey(n, p)) {
			t.Fatal("the entry outlived a take on an unreadable boot clock")
		}
	})
	t.Run("purge", func(t *testing.T) {
		clk := cmcBoot(t)
		rememberCreatedCode(n, p, cmcWords)
		*clk = 0
		purgeExpiredCreatedCodes()
		if l := cmcLen(); l != 0 {
			t.Fatalf("the purge on an unreadable boot clock kept %d entries", l)
		}
	})
}
