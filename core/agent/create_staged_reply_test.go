package main

import (
	"net/http"
	"os"
	"strings"
	"testing"

	"net"
)

// NWP-20261101-10 (Q122): a create that fails after CREATE-CODE drained the code answers "<verb> STAGED" while the
// claim sits staged for the asker's own name and passphrase, so the gate can say the credit is held until a restart.
// Without a staged claim the reply is the bare verb, as before.

const csrName, csrPass = "staged-reply-sam", "the staged-reply passphrase"

func TestCreateStagedReplyFailureAfterTheDrainSaysStaged(t *testing.T) {
	dest, _ := createCodeEnv(t, "PAIDCODEPAIDCODEPAIDCODE", 3)
	t.Cleanup(func() { capStoreLeaseStatus = nil })
	refuseLeasesOf(csrName, csrPass, http.StatusInternalServerError)
	got := verb(func(c net.Conn) { handleCreateCode(c, dest, csrName, csrPass, "PAIDCODEPAIDCODEPAIDCODE") })
	if got != "BLANK STAGED" && got != "NOCREDIT STAGED" {
		t.Fatalf("a create that failed after the drain replied %q, want BLANK STAGED or NOCREDIT STAGED", got)
	}
	if _, err := os.Stat(createStagingPath(csrName, csrPass)); err != nil {
		t.Fatalf("the reply says STAGED but no claim is staged: %v", err)
	}
	// The retry with the same credential still creates with it: the reply changed nothing it relies on.
	capStoreLeaseStatus = nil
	if r := verb(func(c net.Conn) { handleCreate(c, dest, csrName, csrPass) }); !strings.HasPrefix(r, "OK ") {
		t.Errorf("the retry replied %q, want OK", r)
	}
}

func TestCreateStagedReplyFailureWithNothingStagedStaysBare(t *testing.T) {
	dest, _ := createCodeEnv(t, "UNUSED", 1)
	t.Cleanup(func() { capStoreLeaseStatus = nil })
	const n, p = "staged-reply-ida", "the other staged-reply passphrase"
	refuseLeasesOf(n, p, http.StatusInternalServerError)
	got := verb(func(c net.Conn) { handleCreate(c, dest, n, p) })
	if got != "BLANK" && got != "NOCREDIT" {
		t.Fatalf("a create that failed with no staged claim replied %q, want the bare BLANK or NOCREDIT", got)
	}
	if _, err := os.Stat(createStagingPath(n, p)); err == nil {
		t.Fatal("control: a claim is staged, so the bare reply proves nothing")
	}
}

func TestCreateStagedReplyLine(t *testing.T) {
	staged := t.TempDir() + "/claim"
	if got := createFailReply("NOCREDIT", staged); got != "NOCREDIT\n" {
		t.Errorf("no file: %q", got)
	}
	if err := os.WriteFile(staged, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, v := range []string{"BLANK", "NOCREDIT"} {
		if got := createFailReply(v, staged); got != v+" STAGED\n" {
			t.Errorf("%s with a file: %q", v, got)
		}
	}
}
