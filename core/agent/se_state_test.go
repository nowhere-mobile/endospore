package main

import "testing"

// seStateOf drives SE-STATUS (NWP-20261006-09; built for the gate's SE-STATE, NWP-20261005-27): a tie is offered only
// for what SE-TIE can do from the passphrase -- a vault with a pass slot that is not yet hardened -- and an untie only
// for a hardened one; a vault with no pass slot that is not hardened (a security-key profile) is neither.
func TestSEStateOf(t *testing.T) {
	cases := []struct {
		v    vault
		want string
		why  string
	}{
		{vault{Slots: []keyslot{{Kind: "pass"}, {Kind: "recovery"}}}, "PASSONLY", "a pass-only vault can be bound"},
		{vault{Hardened: true, Slots: []keyslot{{Kind: "se"}, {Kind: "recovery"}}}, "HARDENED", "already bound"},
		{vault{Hardened: true, Slots: []keyslot{{Kind: "pass"}, {Kind: "se"}}}, "HARDENED", "the flag wins over a stray pass slot"},
		{vault{Slots: []keyslot{{Kind: "fido2"}, {Kind: "recovery"}}}, "OTHER", "no pass slot: ENROLL-SE cannot open it"},
		{vault{}, "OTHER", "no slots at all"},
	}
	for _, c := range cases {
		if got := seStateOf(&c.v); got != c.want {
			t.Errorf("seStateOf = %q, want %q -- %s", got, c.want, c.why)
		}
	}
}
