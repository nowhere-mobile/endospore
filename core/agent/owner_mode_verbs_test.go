package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20260930-01: the owner-mode verbs answer only the user-0 gate (backlog: "The owner-mode verbs accept a caller in
// any Android user, not only the user-0 gate"). A roamed session's chooser shares the gate's appId and SELinux domain,
// so the accept-time pin alone cannot tell the two apart; ownerCallerOK can, and the owner-key verbs already use it.

var ownerModeVerbs = []string{"GET-TELPUB", "SET-BINDING", "GET-BINDINGS", "DELETE-BINDING", "GET-NOTICE-NUMBER", "SET-NOTICE-NUMBER",
	"REPAIR-BINDINGS", "SET-SIM-MINE"}

// ownerModeRequest is one well-formed request per owner-mode verb.
func ownerModeRequest(verb, pub string) string {
	switch verb {
	case "GET-TELPUB":
		return "GET-TELPUB\nalice\nnot-a-real-passphrase\n"
	case "SET-BINDING":
		return "SET-BINDING\n3\n" + iccidY + "\n" + b64s("L") + "\nopen\nrefC\n" + pub + "\n"
	case "DELETE-BINDING":
		return "DELETE-BINDING\n" + iccidX + "\n\n"
	case "SET-NOTICE-NUMBER":
		return "SET-NOTICE-NUMBER\n1\n"
	case "SET-SIM-MINE":
		return "SET-SIM-MINE\n" + iccidY + "\n1\n"
	}
	return verb + "\n"
}

func useTempNoticeNumber(t *testing.T) string {
	t.Helper()
	old := noticeNumberPath
	noticeNumberPath = filepath.Join(t.TempDir(), "notice-number")
	t.Cleanup(func() { noticeNumberPath = old })
	return noticeNumberPath
}

// replyWithin runs a request in the background and fails the test if no reply comes within d.
func replyWithin(t *testing.T, d time.Duration, req, what string) string {
	t.Helper()
	select {
	case got := <-driveLoginAsync(t, t.TempDir(), req):
		return got
	case <-time.After(d):
		t.Fatalf("%s: no reply within %v", what, d)
	}
	return ""
}

// TestOwnerModeCmdIsTheEightVerbs: exactly the eight owner-mode verbs, and none of the verbs around them.
func TestOwnerModeCmdIsTheEightVerbs(t *testing.T) {
	for _, v := range ownerModeVerbs {
		if !ownerModeCmd(v) {
			t.Errorf("%s is an owner-mode verb", v)
		}
	}
	for _, v := range []string{"OWNER-KEY-NEW", "OWNER-KEY-ENSURE", "SEAL-TEL", "SEAL-MMS", "GET-TELINGEST", "TEL-OWNER",
		"TEL-OWNED-ICCIDS", "TEL-OWNED-LABELS", "STATUS", "LOGIN", "DELETE", "", "get-bindings", "GET-BINDINGS "} {
		if ownerModeCmd(v) {
			t.Errorf("%q is not an owner-mode verb", v)
		}
	}
}

// TestOwnerModeVerbsRefuseAnyoneButTheGate is the row's closing test, one case per verb and per kind of caller: each
// answers DENIED, and a refused caller changes no binding, no pending record and no setting.
func TestOwnerModeVerbsRefuseAnyoneButTheGate(t *testing.T) {
	unassignFixture(t) // bindings for X and Y, sealed records and mailboxes for both
	notice := useTempNoticeNumber(t)
	v, _ := vaultWithTelKey(t)
	bindingsBefore, err := os.ReadFile(bindingsPath)
	if err != nil {
		t.Fatal(err)
	}
	censusBefore := recordCensus(t)
	for _, c := range []struct {
		what string
		uid  int
	}{
		{"the chooser in a roamed user", 1010123},
		{"the chooser in another roamed user", 1110123},
		{"another app in user 0", 10200},
		{"root", 0},
		{"system", 1000},
		{"shell", 2000},
		{"a peer with no uid", -1},
	} {
		asCaller(t, c.uid, 10123)
		for _, verb := range ownerModeVerbs {
			if got := replyWithin(t, 5*time.Second, ownerModeRequest(verb, v.TelPub), c.what+" "+verb); got != "DENIED" {
				t.Errorf("%s: %s answered %q, want DENIED", c.what, verb, got)
			}
		}
	}
	if b, _ := os.ReadFile(bindingsPath); !bytes.Equal(b, bindingsBefore) {
		t.Error("a refused caller changed bindings.conf")
	}
	if got := recordCensus(t); got != censusBefore {
		t.Errorf("a refused caller changed the pending records:\nbefore %s\nafter  %s", censusBefore, got)
	}
	if _, err := os.Stat(notice); !os.IsNotExist(err) {
		t.Error("a refused caller wrote the notice-number setting")
	}
}

// TestOwnerModeRefusalReadsNothingAndSkipsSessionMu: the refusal comes before the request is read and before
// sessionMu, so it answers at once with no request body while a login holds the lock -- where DELETE-BINDING would
// otherwise answer BUSY and the other verbs would wait.
func TestOwnerModeRefusalReadsNothingAndSkipsSessionMu(t *testing.T) {
	telFixture(t)
	useTempNoticeNumber(t)
	asCaller(t, 1010123, 10123)
	sessionMu.Lock()
	defer sessionMu.Unlock()
	for _, verb := range ownerModeVerbs {
		if got := replyWithin(t, 3*time.Second, verb+"\n", verb+" with no body, sessionMu held"); got != "DENIED" {
			t.Errorf("%s answered %q with no body while sessionMu was held, want DENIED", verb, got)
		}
	}
}

// TestOwnerModeVerbsServeTheGate is the control: all eight verbs still work for the user-0 gate. GET-TELPUB's full
// answer needs a profile store, so it is asked with a name and passphrase and no store configured, which only its own
// handler answers NOSTORE: the legacy login it would otherwise fall through to answers BLANK, and a refused caller
// gets DENIED.
func TestOwnerModeVerbsServeTheGate(t *testing.T) {
	unassignFixture(t)
	notice := useTempNoticeNumber(t)
	v, _ := vaultWithTelKey(t)
	asGate(t)
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ENDPOINT", "")
	if got := driveLogin(t, t.TempDir(), ownerModeRequest("GET-TELPUB", "")); got != "NOSTORE" {
		t.Fatalf("GET-TELPUB for the gate answered %q, want NOSTORE with no store configured", got)
	}
	if got := driveLogin(t, t.TempDir(), "GET-BINDINGS\n"); !strings.HasPrefix(got, "OK") {
		t.Fatalf("GET-BINDINGS for the gate answered %q", got)
	}
	if got := driveLogin(t, t.TempDir(), ownerModeRequest("SET-BINDING", v.TelPub)); got != "OK" {
		t.Fatalf("SET-BINDING for the gate answered %q", got)
	}
	if b, ok := bindingForSubID(-1, iccidY); !ok || len(b.Owners) != 2 {
		t.Fatal("SET-BINDING for the gate did not add the owner")
	}
	if got := driveLogin(t, t.TempDir(), "SET-NOTICE-NUMBER\n1\n"); got != "OK" {
		t.Fatalf("SET-NOTICE-NUMBER for the gate answered %q", got)
	}
	if _, err := os.Stat(notice); err != nil {
		t.Fatal("SET-NOTICE-NUMBER for the gate wrote nothing")
	}
	if got := driveLogin(t, t.TempDir(), "GET-NOTICE-NUMBER\n"); got != "1" {
		t.Fatalf("GET-NOTICE-NUMBER for the gate answered %q, want 1", got)
	}
	if got := driveLogin(t, t.TempDir(), "DELETE-BINDING\n89449999999999999999\n\n"); got != "NOTFOUND" {
		t.Fatalf("DELETE-BINDING for the gate answered %q, want NOTFOUND for an unbound ICCID", got)
	}
	if got := driveLogin(t, t.TempDir(), "REPAIR-BINDINGS\n"); got != "OK CLEAN" {
		t.Fatalf("REPAIR-BINDINGS for the gate answered %q, want OK CLEAN for a clean file", got)
	}
	if got := driveLogin(t, t.TempDir(), ownerModeRequest("SET-SIM-MINE", "")); got != "OK NOTREBUILT" {
		t.Fatalf("SET-SIM-MINE for the gate answered %q, want OK NOTREBUILT for a file that is not rebuilt", got)
	}
}

// TestOwnerModeRefusalSourcePins: handleLogin refuses a non-gate caller of an owner-mode verb before it takes
// sessionMu, and before any owner-mode arm reads its request.
func TestOwnerModeRefusalSourcePins(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	h := stripComments(funcBody(t, string(b), "handleLogin"))
	idx := func(s string) int {
		for i, l := range h {
			if strings.Contains(l, s) {
				return i
			}
		}
		return -1
	}
	guard := idx("refusedOwnerModeCaller(conn, name)")
	if guard < 0 {
		t.Fatal("handleLogin never calls refusedOwnerModeCaller")
	}
	for _, later := range []string{"sessionMu.TryLock()", "sessionMu.Lock()", `name == "GET-TELPUB"`, `name == "SET-BINDING"`,
		`name == "GET-BINDINGS"`, `name == "DELETE-BINDING" {`, `name == "GET-NOTICE-NUMBER"`, `name == "SET-NOTICE-NUMBER"`,
		`name == "REPAIR-BINDINGS" {`, `name == "SET-SIM-MINE" {`} {
		if i := idx(later); i < 0 || i < guard {
			t.Errorf("handleLogin reaches %s (line %d of its body) before the owner-mode refusal (line %d)", later, i, guard)
		}
	}
}
