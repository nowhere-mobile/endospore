package main

import "testing"

// NWP-20261020-07: dropBillPrev and dropBillRetag moved the vault head ALONE, leaving ref/<RecoveryRef> on the
// blob the head had before (or on another bracket's). They now publish the pair, as every other writer of the
// bare vault head does. Sequential, behind another bracket, and the control that a clear with nothing to clear
// writes nothing. test-recovery-ref-arm.sh M5-M7 remove the new putRef from each closure.

// billDropPrevProfile publishes a profile whose index holds a !bill-prev record.
func billDropPrevProfile(t *testing.T, name, pass string) []byte {
	t.Helper()
	v, dk := sessionVaultForTest(t, name, pass)
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("the new vault has no scope index")
	}
	idx[scopeBillPrevKey] = scopeRec{Ref: billRefPrefix + profileRefV2(name, "the passphrase before")}
	v.Scopes = sealScopeIndex(dk, idx)
	if err := publishSessionVault("s3", name, pass, v, dk); err != nil {
		t.Fatal(err)
	}
	return dk
}

// billDropRetagProfile publishes a profile whose index holds a !bill-retag record naming old.
func billDropRetagProfile(t *testing.T, name, pass, old string) []byte {
	t.Helper()
	v, dk := sessionVaultForTest(t, name, pass)
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("the new vault has no scope index")
	}
	v.Scopes = sealScopeIndex(dk, billRetagPush(idx, old, profileRefV2(name, pass)))
	if err := publishSessionVault("s3", name, pass, v, dk); err != nil {
		t.Fatal(err)
	}
	return dk
}

func requireRecoveryOnHead(t *testing.T, what, name, pass string) *vault {
	t.Helper()
	v, head, rec := headAndRecovery(t, name, pass)
	if rec != head {
		t.Errorf("%s: the recovery ref names %s while the head names %s", what, short(rec), short(head))
	}
	return v
}

func TestRecoveryRefArm_BillDropPrevMovesBoth(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "bdprev", "a carry clear moves both pointers"
	dk := billDropPrevProfile(t, name, pass)
	if !dropBillPrev("s3", name, pass, dk) {
		t.Fatal("the carry clear did not clear")
	}
	v := requireRecoveryOnHead(t, "plan-carry clear", name, pass)
	if idx, _ := openScopeIndex(dk, v.Scopes); billPrevOf(idx) != "" {
		t.Error("the record is still in the head's index")
	}
}

func TestRecoveryRefArm_BillDropRetagMovesBoth(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "bdrtg", "a re-tag clear moves both pointers"
	old := profileRefV2(name, "the passphrase before")
	dk := billDropRetagProfile(t, name, pass, old)
	if !dropBillRetag("s3", name, pass, dk, []string{old}) {
		t.Fatal("the re-tag clear did not clear")
	}
	v := requireRecoveryOnHead(t, "re-tag clear", name, pass)
	if idx, _ := openScopeIndex(dk, v.Scopes); len(billRetagOf(idx)) != 0 {
		t.Errorf("the record still holds %v", shortAll(billRetagOf(idx)))
	}
}

func TestRecoveryRefArm_BillDropPrevBehindAnotherBracket(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "bdprevb", "a carry clear behind a bracket"
	dk := billDropPrevProfile(t, name, pass)
	var cleared bool
	publishBehindAnotherBracket(t, name, pass, dk, func() { cleared = dropBillPrev("s3", name, pass, dk) })
	if !cleared {
		t.Fatal("the carry clear, arriving while another bracket held the lock, did not clear")
	}
	v := requireRecoveryOnHead(t, "plan-carry clear behind another bracket", name, pass)
	idx, _ := openScopeIndex(dk, v.Scopes)
	if v.TelPub != otherBracketMark || billPrevOf(idx) != "" {
		t.Errorf("the head is marked: %v, record %q; want the other bracket's mark and no record",
			v.TelPub == otherBracketMark, short(billPrevOf(idx)))
	}
}

func TestRecoveryRefArm_BillDropRetagBehindAnotherBracket(t *testing.T) {
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const name, pass = "bdrtgb", "a re-tag clear behind a bracket"
	old := profileRefV2(name, "the passphrase before")
	dk := billDropRetagProfile(t, name, pass, old)
	var cleared bool
	publishBehindAnotherBracket(t, name, pass, dk, func() {
		cleared = dropBillRetag("s3", name, pass, dk, []string{old})
	})
	if !cleared {
		t.Fatal("the re-tag clear, arriving while another bracket held the lock, did not clear")
	}
	v := requireRecoveryOnHead(t, "re-tag clear behind another bracket", name, pass)
	idx, _ := openScopeIndex(dk, v.Scopes)
	if v.TelPub != otherBracketMark || len(billRetagOf(idx)) != 0 {
		t.Errorf("the head is marked: %v, record %v; want the other bracket's mark and no record",
			v.TelPub == otherBracketMark, shortAll(billRetagOf(idx)))
	}
}

// Control: with no record outstanding a clear writes nothing and reports success.
func billDropNothingOutstanding(t *testing.T, name string, drop func(dk []byte, name, pass string) bool) {
	t.Helper()
	capLockEnv(t)
	t.Cleanup(clearStaleHit)
	const pass = "a clear with nothing to clear"
	_, dk := sessionVaultForTest(t, name, pass)
	_, head, rec := headAndRecovery(t, name, pass)
	if !drop(dk, name, pass) {
		t.Error("a clear with no record returned false")
	}
	_, head2, rec2 := headAndRecovery(t, name, pass)
	if head2 != head || rec2 != rec {
		t.Errorf("a clear with no record moved a pointer (head %s -> %s, recovery %s -> %s)", short(head),
			short(head2), short(rec), short(rec2))
	}
}

func TestRecoveryRefArm_BillDropPrevNothingOutstanding(t *testing.T) {
	billDropNothingOutstanding(t, "bdctlprev", func(dk []byte, n, p string) bool { return dropBillPrev("s3", n, p, dk) })
}

func TestRecoveryRefArm_BillDropRetagNothingOutstanding(t *testing.T) {
	billDropNothingOutstanding(t, "bdctlrtg", func(dk []byte, n, p string) bool {
		return dropBillRetag("s3", n, p, dk, []string{"gone"})
	})
}
