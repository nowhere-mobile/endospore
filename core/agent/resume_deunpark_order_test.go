package main

import (
	"os"
	"strings"
	"testing"
)

// NWP-20261005-23: a cold-locked session's accounts_de.db is parked in RAM for the lock, and handleResume puts it
// back with the `deunpark` worker op. Its PLACE is the whole safety argument, so it is pinned:
//   - AFTER `verify` has accepted the entry. Run on the local proof alone, it would be an extra worker op for right
//     answers only -- a timing oracle that skips the keyguard's throttling (the decoy credential exists to prevent
//     exactly that).
//   - BEFORE the reply that lets the chooser switch (start) the user, i.e. before markRoamSession: a user started
//     without its DE file builds an empty one and AccountManagerService deletes its CE accounts.
//   - and a failure must RETURN, never fall through to the resume.
func TestResumeUnparksAfterVerifyBeforeStart(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := strings.Join(stripComments(funcBody(t, string(b), "handleResume")), "\n")
	iVerify := strings.Index(body, `triggerRoamWorker(dest, "verify"`)
	iUnpark := strings.Index(body, `triggerRoamWorker(dest, "deunpark", "x", "", uid, "", nil)`)
	iMark := strings.Index(body, "markRoamSession(dest, name, pass, uid, se)")
	if iVerify < 0 || iMark < 0 {
		t.Fatalf("handleResume no longer has its verify (%d) or its markRoamSession (%d) -- this test is stale", iVerify, iMark)
	}
	if iUnpark < 0 {
		t.Fatal("handleResume does not restore the parked account file -- a resumed user would start without accounts_de.db")
	}
	if !(iVerify < iUnpark && iUnpark < iMark) {
		t.Fatalf("deunpark is out of place (verify %d, deunpark %d, markRoamSession %d): it must run after verify and before the session is marked live", iVerify, iUnpark, iMark)
	}
	// The refusal block between verify and deunpark returns on every failed verify, so deunpark is reached only by
	// an accepted entry; and deunpark's own failure returns ERR-RESTORE.
	tail := body[iUnpark:iMark]
	if !strings.Contains(tail, `fmt.Fprint(conn, "ERR-RESTORE\n")`) || !strings.Contains(tail, "return") {
		t.Fatal("a failed deunpark does not stop the resume with ERR-RESTORE")
	}
	if strings.Count(body, `"deunpark"`) != 1 {
		t.Fatal("deunpark is called more than once in handleResume -- one call, after verify, is the design")
	}
}
