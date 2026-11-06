package main

import "testing"

// TestRecoverReplyRefusesABelowFloorPassphrase: RECOVER applies the passphrase floor to the new passphrase
// (docs/credential-tiers.md tier 1a, NWP-20261115-10), as the CLI `recover` does. The refusal comes before the
// words are parsed and before any store read, so it is the same for the right words, wrong words and an unknown
// name, and the store is unchanged. The reason is computed with passphraseStrong, never pinned here.
func TestRecoverReplyRefusesABelowFloorPassphrase(t *testing.T) {
	const weak = "1234"
	const oldPass = "old horse battery staple" // recoverReplyFixture's passphrase
	want := func(t *testing.T, name string) string {
		t.Helper()
		ok, reason := passphraseStrong(name, weak)
		if ok {
			t.Fatalf("%q must be below the floor for this test", weak)
		}
		return "WEAK " + reason
	}

	t.Run("right words: refused, nothing reset", func(t *testing.T) {
		t.Setenv("NOWHERE_PASS_FLOOR", "1")
		name, mn, _ := recoverReplyFixture(t)
		if got, w := recoverReply(name, mn, weak), want(t, name); got != w {
			t.Fatalf("a below-floor reset with the right words answered %q, want %q", got, w)
		}
		if ok, err := headExistsStrict("s3", name, oldPass); !ok || err != nil {
			t.Fatalf("after WEAK the old passphrase's head must still exist: ok=%v err=%v", ok, err)
		}
		if ok, err := headExistsStrict("s3", name, weak); ok || err != nil {
			t.Fatalf("after WEAK no head may exist for the refused passphrase: ok=%v err=%v", ok, err)
		}
	})

	t.Run("wrong words and an unknown name answer WEAK too", func(t *testing.T) {
		t.Setenv("NOWHERE_PASS_FLOOR", "1")
		name, mn, _ := recoverReplyFixture(t)
		if got, w := recoverReply(name, "not a mnemonic", weak), want(t, name); got != w {
			t.Fatalf("wrong words answered %q, want %q (no existence signal)", got, w)
		}
		if got, w := recoverReply("nobody", mn, weak), want(t, "nobody"); got != w {
			t.Fatalf("an unknown name answered %q, want %q (no existence signal)", got, w)
		}
	})

	t.Run("control: a passphrase above the floor still resets", func(t *testing.T) {
		t.Setenv("NOWHERE_PASS_FLOOR", "1")
		name, mn, _ := recoverReplyFixture(t)
		if got := recoverReply(name, mn, recNewPass); got != "OK" {
			t.Fatalf("a reset above the floor answered %q, want OK", got)
		}
	})

	t.Run("floor off: a below-floor reset goes through", func(t *testing.T) {
		t.Setenv("NOWHERE_PASS_FLOOR", "0")
		name, mn, _ := recoverReplyFixture(t)
		if got := recoverReply(name, mn, weak); got != "OK" {
			t.Fatalf("with NOWHERE_PASS_FLOOR=0 a below-floor reset answered %q, want OK", got)
		}
	})
}
