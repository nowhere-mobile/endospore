package main

import "testing"

// DIA-20260812-08 (#111). #657 made a refused seal FAIL instead of silently succeeding, which stopped the data
// loss -- the logoff path checks `out != "OK"` and so keeps the session signed in instead of reaping it. What
// it did not do is tell the user WHICH failure they hit, and the single message they got ("check your
// connection and try again") is the wrong instruction for a refusal in the most costly way available: the guard
// is deterministic, so every retry reproduces it, and a user who retries until they give up and power off
// destroys the session the guard was protecting. These tests pin the cause surviving to the UI.

func TestSealFailSuffixNamesTheCausesThatNeedDifferentAdvice(t *testing.T) {
	for _, c := range []struct{ out, want string }{
		{"ERR-REFUSED", "REFUSED"},   // store reachable, write withheld on purpose -> retrying is futile
		{"ERR-NOCREDIT", "NOCREDIT"}, // retrying is futile too, but the user CAN fix it: add storage
	} {
		if got := sealFailSuffix(c.out); got != c.want {
			t.Errorf("sealFailSuffix(%q) = %q, want %q", c.out, got, c.want)
		}
	}
}

func TestSealFailSuffixIsEmptyForEveryTransientFailure(t *testing.T) {
	// "" is what keeps this backward compatible: callers emit the BARE verb (FAILED / STALE), which is exactly
	// what a chooser predating the suffix reads. A new verdict string must therefore fall through to "" rather
	// than leak an unrecognised token into the UI, where it would select no message at all.
	for _, out := range []string{"ERR-PUSH", "ERR-TIMEOUT", "ERR-VAULT", "ERR-STALLED", "OK", "", "ERR-SOMETHING-NEW"} {
		if got := sealFailSuffix(out); got != "" {
			t.Errorf("sealFailSuffix(%q) = %q, want \"\" -- an unrecognised verdict must degrade to the "+
				"generic message, not emit a token no chooser branches on", out, got)
		}
	}
}

func TestRecordSealKeepsRefusedDistinctFromAGenericFailure(t *testing.T) {
	// GET-SYNC-STATUS drives the background "Not backed up" notice, whose generic text promises the changes
	// "will sync once you're back online". For a refusal that is a false reassurance about data that is not
	// being stored -- so "refused" must NOT collapse into "fail".
	for _, c := range []struct{ out, want string }{
		{"OK", "ok"},
		{"OK 13", "ok"}, // the worker's result line carries the uid on some ops
		{"ERR-NOCREDIT", "nocredit"},
		{"ERR-REFUSED", "refused"},
		{"ERR-PUSH", "fail"},
		{"ERR-TIMEOUT", "fail"},
	} {
		recordSeal(c.out)
		if got := sealStatusGet(); got != c.want {
			t.Errorf("recordSeal(%q) -> sealStatusGet() = %q, want %q", c.out, got, c.want)
		}
	}
}

func TestResetSealStatusClearsARefusal(t *testing.T) {
	// Login resets this ("we just restored, so we're current"). A refusal that survived the reset would keep
	// the notice up on a session that has not sealed anything yet, and its advice -- report this -- would be
	// about a previous session entirely.
	recordSeal("ERR-REFUSED")
	resetSealStatus()
	if got := sealStatusGet(); got != "" {
		t.Errorf("sealStatusGet() = %q after resetSealStatus(), want \"\"", got)
	}
}
