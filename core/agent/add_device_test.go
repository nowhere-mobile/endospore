package main

import (
	"bytes"
	"strings"
	"testing"
)

// seSlotsOpenableBy reports how many `se` slots the given device secret can open.
func seSlotsOpenableBy(t *testing.T, base, name, pass string, se []byte) int {
	t.Helper()
	v, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if !isV {
		t.Fatal("head is not a vault")
	}
	n := 0
	for _, s := range v.Slots {
		if s.Kind != "se" {
			continue
		}
		if _, ok := unwrap(kekSE(name, pass, se), s.Wrapped); ok {
			n++
		}
	}
	return n
}

// TestTwoHandsetsBothWorkAfterAddDevice is the whole point of NWP-20260915-09, and it is the test that used
// to fail by design.
//
// Before this, a hardened profile on a second handset had exactly one way in -- recoverVault -- which rebuilds
// the vault through buildVault and REPLACES the slot list. So handset B's recovery discarded handset A's `se`
// slot and locked A out in turn, and the two alternated being locked out indefinitely. Measured, not reasoned.
//
// enrollSEViaRecovery opens the EXISTING vault through its `recovery` slot and APPENDS B's slot. Nothing is
// rebuilt, so nothing is evicted.
func TestTwoHandsetsBothWorkAfterAddDevice(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "twodev", "horse battery staple correct"
	mnemonic := createVault(base, name, pass)
	if mnemonic == "" {
		t.Fatal("createVault returned no recovery code")
	}
	seA := []byte("handset-A-strongbox-secret")
	seB := []byte("handset-B-strongbox-secret")
	seC := []byte("handset-C-strongbox-secret")
	// NWP-20261114-24: each handset's chip slot carries that handset's label, sealed under the DK.
	useTempDeviceLabel(t)
	handsets := []handsetLabel{{"Phone A", seA}, {"Phone B", seB}, {"Phone C", seC}}

	// Handset A hardens, which is what happens at create on a StrongBox device.
	writeDeviceLabelFile(t, "Phone A\n")
	if err := enrollSE(base, name, pass, seA); err != nil {
		t.Fatalf("A enrollSE: %v", err)
	}
	if _, _, ok := resolveKey(base, name, pass); ok {
		t.Fatal("precondition: a passphrase should NOT open a hardened vault")
	}

	checkSlotLabels(t, base, name, pass, handsets[:1])

	// Handset B adds itself with the 12 words. No passphrase change, no rebuild.
	writeDeviceLabelFile(t, "Phone B\n")
	if err := enrollSEViaRecovery(base, name, mnemonic, pass, seB); err != nil {
		t.Fatalf("B enrollSEViaRecovery: %v", err)
	}

	// BOTH handsets must now open it. This is the assertion the old path could never satisfy.
	if n := seSlotsOpenableBy(t, base, name, pass, seA); n != 1 {
		t.Errorf("handset A opens %d se slots, want 1 -- adding B EVICTED A, which is the bug this fixes", n)
	}
	if n := seSlotsOpenableBy(t, base, name, pass, seB); n != 1 {
		t.Errorf("handset B opens %d se slots, want 1", n)
	}
	// ...and the passphrase alone still must not, or the whole point of hardening is gone.
	if _, _, ok := resolveKey(base, name, pass); ok {
		t.Error("the passphrase opens the vault after add-device -- a `pass` slot survived and the profile is " +
			"offline-brute-forceable again")
	}

	checkSlotLabels(t, base, name, pass, handsets[:2])

	// A third handset is the same operation, and must not evict either of the first two.
	writeDeviceLabelFile(t, "Phone C\n")
	if err := enrollSEViaRecovery(base, name, mnemonic, pass, seC); err != nil {
		t.Fatalf("C enrollSEViaRecovery: %v", err)
	}
	for _, d := range []struct {
		label string
		se    []byte
	}{{"A", seA}, {"B", seB}, {"C", seC}} {
		if n := seSlotsOpenableBy(t, base, name, pass, d.se); n != 1 {
			t.Errorf("after adding a third handset, %s opens %d se slots, want 1", d.label, n)
		}
	}
	checkSlotLabels(t, base, name, pass, handsets)
}

// handsetLabel is one handset of TestTwoHandsetsBothWorkAfterAddDevice: the label its file held when it minted its slot.
type handsetLabel struct {
	label string
	se    []byte
}

// checkSlotLabels reads the head and checks that it has exactly one `se` slot per handset, that each opens under that
// handset's KEK to a label that is that handset's under the DK, and that the encoded head holds no label in the clear.
func checkSlotLabels(t *testing.T, base, name, pass string, hs []handsetLabel) {
	t.Helper()
	blob := getHeadBlob(base, getRef(base, headKey(base, name, pass)))
	v, isV := parseVault(blob)
	if !isV {
		t.Fatal("head is not a vault")
	}
	dk := unwrapDK(v, "se", kekSE(name, pass, hs[0].se))
	if dk == nil {
		t.Fatal("handset A does not open the vault")
	}
	se := 0
	for _, s := range v.Slots {
		if s.Kind != "se" {
			if s.LabelSealed != "" {
				t.Errorf("a %s slot carries a label", s.Kind)
			}
			continue
		}
		se++
		owner := ""
		for _, h := range hs {
			if _, ok := unwrap(kekSE(name, pass, h.se), s.Wrapped); ok {
				owner = h.label
			}
		}
		if got := openSlotLabel(dk, s.LabelSealed); owner == "" || got != owner {
			t.Errorf("an se slot of handset %q carries the label %q", owner, got)
		}
	}
	if se != len(hs) {
		t.Errorf("the vault has %d se slots, want %d", se, len(hs))
	}
	for _, h := range hs {
		if bytes.Contains(blob, []byte(h.label)) {
			t.Errorf("the stored head holds %q in the clear", h.label)
		}
	}
}

// TestAddDeviceIsIdempotent: re-running it for a handset that already has a slot must write nothing. Without
// this, a UI that offers "add this phone" twice -- or any retry -- appends a duplicate slot and bumps Version
// each time, growing the vault and paying for a metered store write per attempt.
func TestAddDeviceIsIdempotent(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "adddupe", "horse battery staple correct"
	mnemonic := createVault(base, name, pass)
	se := []byte("this-device-secret")
	if err := enrollSEViaRecovery(base, name, mnemonic, pass, se); err != nil {
		t.Fatalf("first add: %v", err)
	}
	v1, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	slots, ver := len(v1.Slots), v1.Version

	if err := enrollSEViaRecovery(base, name, mnemonic, pass, se); err != nil {
		t.Fatalf("second add: %v", err)
	}
	v2, _ := parseVault(getHeadBlob(base, getRef(base, headKey(base, name, pass))))
	if len(v2.Slots) != slots {
		t.Errorf("slot count grew on a repeat add: %d -> %d", slots, len(v2.Slots))
	}
	if v2.Version != ver {
		t.Errorf("Version bumped on a no-op add: %d -> %d (that is a metered store write for nothing)", ver, v2.Version)
	}
}

// TestAddDeviceRejectsAWrongPassphrase pins the cross-check, and the failure it prevents is the nasty kind.
//
// The recovery code resolves the head through ref/<RecoveryRef>, which is keyed on name+entropy and says
// NOTHING about the passphrase. But kekSE is passphrase-bound and the head publishes at
// profileRefV2(name, pass) -- so a wrong-but-plausible passphrase would mint a slot under the wrong KEK and
// write the head at a ref nobody reads, leaving the real profile untouched while the user is told it worked.
func TestAddDeviceRejectsAWrongPassphrase(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "addwrong", "horse battery staple correct"
	mnemonic := createVault(base, name, pass)
	seA := []byte("handset-A-secret")
	if err := enrollSE(base, name, pass, seA); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}
	before := getRef(base, headKey(base, name, pass))

	err := enrollSEViaRecovery(base, name, mnemonic, "not the right passphrase", []byte("handset-B-secret"))
	if err == nil {
		t.Fatal("add-device ACCEPTED a wrong passphrase -- it would have published a head at a ref nobody " +
			"reads and reported success")
	}
	if !strings.Contains(err.Error(), "does not match this profile") {
		t.Errorf("refused as %q; the user typed the right 12 words and the wrong passphrase, and only a "+
			"message naming the passphrase sends them to the field they got wrong", err.Error())
	}
	if after := getRef(base, headKey(base, name, pass)); after != before {
		t.Error("the real head moved despite the refusal")
	}
	if n := seSlotsOpenableBy(t, base, name, pass, seA); n != 1 {
		t.Error("handset A's slot was disturbed by a refused add")
	}
}

// TestAddDeviceRejectsAWrongMnemonic: the other credential, same standard -- refuse, write nothing.
//
// ⚠ IT ALSO PINS THE MESSAGE, and that is deliberate rather than brittleness. Three guards can each refuse
// this call, so refusing is over-determined: a mutation run found that deleting the name+phrase check leaves
// every one of these cases still failing, just with the WRONG reason attached. That matters because the
// reason is the only thing the user can act on -- "no profile for that name + phrase" sends them back to the
// name and the 12 words, while "that passphrase does not match" sends them to the passphrase they typed
// correctly. Pinning the text is what keeps that guard from decaying into dead code.
//
// ⚠ AND THE DISTINCTION DOES NOT BREAK BLIND LOGIN. Telling the two apart requires the name AND the matching
// 12 words already, so neither message reveals whether a profile exists to anyone who could not already open
// it outright with recoverVault.
func TestAddDeviceRejectsAWrongMnemonic(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "addbadcode", "horse battery staple correct"
	createVault(base, name, pass)
	other := createVault(base, "someone-else", pass) // a VALID mnemonic, wrong profile
	if other == "" {
		t.Fatal("createVault returned no recovery code")
	}
	for _, tc := range []struct {
		label, mnemonic, want string
	}{
		{"another profile's recovery code", other, "no profile for that name"},
		{"a malformed recovery code", "not a mnemonic at all", "invalid recovery phrase"},
	} {
		err := enrollSEViaRecovery(base, name, tc.mnemonic, pass, []byte("se"))
		if err == nil {
			t.Errorf("add-device accepted %s", tc.label)
			continue
		}
		if !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s was refused as %q, want a reason containing %q -- the user is sent to the wrong "+
				"field by that message", tc.label, err.Error(), tc.want)
		}
	}
}

// TestAddDeviceRefusesWhenThePublishIsFenced pins the refusal arm, which is the one that decides what the
// USER is told when the store does not take the new head.
//
// Without it hardenVaultTo would return nil after a publish that never landed, and the chooser would say
// "this phone has been added" about a vault that is unchanged in the store -- so the user puts the phone
// down, and the next login still shows a blank. A silent success is worse here than a loud failure, because
// blind login gives the user no second signal to read.
//
// ⚠ IT DRIVES THE MECHANISM, NOT THE FLAG. It used to set sealFenceHit/sealStaleHit directly before
// the call, and said so -- a cheap companion that proved the arm was reached but not that a real refusal
// reaches it. NWP-20260915-14 made that technique WRONG rather than merely weak: capWrite now clears both
// flags as it opens, because in the login daemon (one process per boot) a refusal would otherwise latch
// for every later operation. A flag set BEFORE the bracket is exactly what that reset discards. So these
// cases arm the real guards instead, which is what the old comment wished for.
func TestAddDeviceRefusesWhenThePublishIsFenced(t *testing.T) {
	base := newHTTPStore(t)
	const pass = "horse battery staple correct"
	t.Setenv("NOWHERE_STATE", t.TempDir())    // armSealFence needs a state dir to put its markers in
	pushFenceSeq, pushFenceSampled = 0, false // no sampled sequence from an earlier test in this binary

	// ⚠ A PROFILE PER CASE, and this is the second time this test has had to learn it. The cases used
	// to share one profile and differ only by secret, because the FIRST case still reaches the store before
	// its refusal is reported -- the verdict is only known after the write -- so a shared secret made the
	// second case take hardenVaultTo's idempotent early return and pass having tested nothing.
	//
	// A distinct secret is not enough either, and a surviving mutant is what showed it: the fence covers
	// the HEAD ref, so the recovery ref in the same bracket is NOT refused and lands -- pointing at the
	// hardened vault, whose `pass` slot hardening has just dropped. The second case then fails inside
	// enrollSEViaRecovery before any publish, reports an error, and goes green over an arm it never
	// reached. Two profiles cost one extra createVault and remove the whole class.
	for _, tc := range []struct {
		label string
		name  string
		arm   func(head string)
	}{
		// A delete landed while this add-device was in flight: the fence refuses the head publish.
		{"fence", "addfence", func(head string) { armSealFence([]string{head}) }},
		// The stale arm is now covered by a real move: T2 in add_device_edit_test.go (NWP-20261111-10).
	} {
		t.Run(tc.label, func(t *testing.T) {
			mnemonic := createVault(base, tc.name, pass)
			if mnemonic == "" {
				t.Fatal("createVault returned no recovery code")
			}
			if err := enrollSE(base, tc.name, pass, []byte("handset-A-secret")); err != nil {
				t.Fatalf("enrollSE: %v", err)
			}
			head := profileRefV2(tc.name, pass) // where hardenVaultTo publishes the account vault
			tc.arm(head)
			t.Cleanup(func() {
				liftSealFence([]string{head})
				clearSealExpectations()
				sealFenceHit = false
			})
			if err := enrollSEViaRecovery(base, tc.name, mnemonic, pass, []byte("handset-B-secret")); err == nil {
				t.Error("add-device reported SUCCESS over a refused publish -- the user would be told the " +
					"phone was added while the store still holds the old vault, and blind login gives them " +
					"no way to notice")
			}
			if !sealFenceHit && !sealStaleHit {
				t.Error("nothing was actually refused, so this case proved nothing: the error it saw came " +
					"from somewhere other than the publish guard it armed")
			}
		})
	}
}
