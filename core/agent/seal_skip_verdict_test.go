package main

import "testing"

// NWP-20261108-20: a periodic seal skipped as superseded ran no seal, so recordSeal must leave the verdict the last
// real seal recorded (and the stashes the superseding seal will take) untouched.

func skipVerdictSetup(t *testing.T) {
	t.Helper()
	resetVerdictGlobals(t)
	prev := lastSealOKAt.Load()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	clearCreditReason()
	clearRefusalReasons()
	t.Cleanup(func() {
		resetVerdictGlobals(t)
		lastSealOKAt.Store(prev)
		clearCreditReason()
		clearRefusalReasons()
		disarmLogoffRefusal()
		resetScopeSavedAt()
	})
}

func skipVerdictNoCredit(t *testing.T) {
	t.Helper()
	stashCreditReason("free quota exceeded")
	recordSeal("ERR-NOCREDIT PARTIAL:apps=refused")
	recordSeal("SKIP-SUPERSEDED")
}

func TestSealSkipVerdict_SupersededKeepsANoCreditVerdict(t *testing.T) {
	skipVerdictSetup(t)
	skipVerdictNoCredit(t)
	if got := sealStatusGet(); got != "nocredit" {
		t.Errorf("status = %q, want nocredit", got)
	}
	if got := sealPartsGet(); got != "apps=refused" {
		t.Errorf("parts = %q, want apps=refused", got)
	}
	if got := sealReasonGet(); got != "free quota exceeded" {
		t.Errorf("reason = %q, want the stashed text", got)
	}
}

func TestSealSkipVerdict_SupersededKeepsAnOK(t *testing.T) {
	skipVerdictSetup(t)
	recordSeal("OK")
	lastSealOKAt.Store(12345)
	recordSeal("SKIP-SUPERSEDED")
	if got := sealStatusGet(); got != "ok" {
		t.Errorf("status = %q, want ok", got)
	}
	if got := lastSealOKAt.Load(); got != 12345 {
		t.Errorf("lastSealOKAt = %d, want it unchanged at 12345", got)
	}
}

func TestSealSkipVerdict_GetSyncStatusStillSaysNoCredit(t *testing.T) {
	skipVerdictSetup(t)
	dest := t.TempDir()
	if err := markRoamSession(dest, "skipverdict3", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	skipVerdictNoCredit(t)
	if got := evictConn(t, dest, "GET-SYNC-STATUS\n"); got != "STALE NOCREDIT" {
		t.Errorf("GET-SYNC-STATUS = %q, want STALE NOCREDIT", got)
	}
}

func TestSealSkipVerdict_AStashBeforeASkipIsTakenByTheNextVerdict(t *testing.T) {
	skipVerdictSetup(t)
	stashCreditReason("no live lease for ref")
	recordSeal("SKIP-SUPERSEDED")
	recordSeal("ERR-NOCREDIT")
	if got := sealStatusGet(); got != "nocredit" {
		t.Errorf("status = %q, want nocredit", got)
	}
	if got := sealReasonGet(); got != "no live lease for ref" {
		t.Errorf("reason = %q, want the text stashed before the skip", got)
	}
}

func TestSealSkipVerdict_OtherSkipsAndFailuresStillRecordFail(t *testing.T) {
	for _, v := range []string{"SKIP-REAPING", workerBusy, "ERR-PUSH", "ERR-TIMEOUT"} {
		t.Run(v, func(t *testing.T) {
			skipVerdictSetup(t)
			recordSeal("OK")
			recordSeal(v)
			if got := sealStatusGet(); got != "fail" {
				t.Errorf("%s recorded %q, want fail", v, got)
			}
		})
	}
}
