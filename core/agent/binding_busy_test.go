package main

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// NWP-20261011-43: the binding verbs never wait for sessionMu, which a materialise, a login or a CLEAN-STORAGE holds
// for minutes (20.8 s measured on lynx 2026092402). The four bindings.conf reads and GET-TELPUB, the Bind button's first
// call, run lock-free (concurrentSafeCmd), and SET-BINDING, a write, answers BUSY while the lock is held, as
// DELETE-BINDING already did.

// bindingBusyFixture binds carol to X with label "L" and returns bindings.conf as written.
func bindingBusyFixture(t *testing.T) []byte {
	t.Helper()
	asGate(t) // GET-BINDINGS and SET-BINDING are owner-mode verbs: only the user-0 gate may call them
	useTempInbox(t)
	useTempIngest(t)
	useTempBindings(t)
	if err := setBindingOwner(3, iccidX, "L", "open", profileRefV2("carol", "pw-carol"), "pubC"); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(bindingsPath)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// replyWhileHeld sends req with sessionMu held by the caller and returns its reply. A reply that does not come within
// d fails the test instead of hanging it: the lock is released, the stuck handler is let finish -- so it never writes
// after the test has restored bindingsPath -- and the test stops.
func replyWhileHeld(t *testing.T, d time.Duration, req, what string) string {
	t.Helper()
	c := driveLoginAsync(t, t.TempDir(), req)
	select {
	case got := <-c:
		return got
	case <-time.After(d):
		sessionMu.Unlock()
		late := <-c
		sessionMu.Lock() // the caller's deferred Unlock still has a lock to release
		t.Fatalf("%s: no reply within %v while sessionMu was held (it waited for the lock, then replied %q)", what, d, late)
	}
	return ""
}

// TestSetBindingAnswersBusyWhileSessionMuIsHeld: a Bind tapped during a long session op answers BUSY at once and
// writes nothing, and the same request binds once the lock is free (the control: the request itself is good).
func TestSetBindingAnswersBusyWhileSessionMuIsHeld(t *testing.T) {
	before := bindingBusyFixture(t)
	req := "SET-BINDING\n4\n" + iccidY + "\n" + b64s("L") + "\nopen\nrefB\npubB\n"
	func() {
		sessionMu.Lock()
		defer sessionMu.Unlock()
		if got := replyWhileHeld(t, 5*time.Second, req, "SET-BINDING"); got != "BUSY" {
			t.Fatalf("SET-BINDING while sessionMu is held replied %q, want BUSY", got)
		}
	}()
	if after, _ := os.ReadFile(bindingsPath); !bytes.Equal(after, before) {
		t.Fatalf("a BUSY SET-BINDING changed bindings.conf:\nbefore %q\nafter  %q", before, after)
	}
	if got := driveLogin(t, t.TempDir(), req); got != "OK" {
		t.Fatalf("SET-BINDING with sessionMu free replied %q, want OK", got)
	}
	if after, _ := os.ReadFile(bindingsPath); !strings.Contains(string(after), iccidY) {
		t.Fatal("the control SET-BINDING replied OK but did not bind Y")
	}
}

// TestBindingReadsAnswerWhileSessionMuIsHeld: GET-BINDINGS, the TEL-OWNER probes and GET-TELPUB give their normal
// answers while sessionMu is held -- the owner-mode SIM lines screen, the sign-in outbound verdict and the Bind
// button's first call no longer wait for a materialise or a clean-up.
func TestBindingReadsAnswerWhileSessionMuIsHeld(t *testing.T) {
	bindingBusyFixture(t)
	t.Setenv("GATEWAY_URL", "") // no store, so GET-TELPUB answers from its own handler (TestOwnerModeVerbsServeTheGate)
	t.Setenv("S3_ENDPOINT", "")
	sessionMu.Lock()
	defer sessionMu.Unlock()
	for _, c := range []struct{ req, want string }{
		{"GET-BINDINGS\n", "OK\n3|" + iccidX + "|" + b64s("L") + "|open|1"},
		{"TEL-OWNER\ncarol\npw-carol\n", "YES"},
		{"TEL-OWNER\nstranger\npw\n", "NO"},
		{"TEL-OWNED-ICCIDS\ncarol\npw-carol\n", "OK\n" + iccidX},
		{"TEL-OWNED-LABELS\ncarol\npw-carol\n", "OK\nL " + b64s("L")},
		// The Bind button's first call: with no store configured only its own handler answers NOSTORE, so this
		// proves the dispatch does not wait for sessionMu (the store read itself is pure, see concurrentSafeCmd).
		{"GET-TELPUB\nalice\nnot-a-real-passphrase\n", "NOSTORE"},
	} {
		verb := strings.SplitN(c.req, "\n", 2)[0]
		if got := replyWhileHeld(t, 5*time.Second, c.req, verb); got != c.want {
			t.Errorf("%s while sessionMu is held replied %q, want %q", verb, got, c.want)
		}
	}
}

// TestSetBindingIsTryLocked pins SET-BINDING into handleLogin's TryLock set by source, beside the behavioural BUSY
// above, as TestDeleteBindingIsTryLocked does for DELETE-BINDING.
func TestSetBindingIsTryLocked(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := stripComments(funcBody(t, string(b), "handleLogin"))
	for i, l := range body {
		if strings.Contains(l, `name == "BACKUP" || name == "DELETE"`) {
			set := l
			if i+1 < len(body) {
				set += body[i+1] // the condition runs onto a second line
			}
			if !strings.Contains(set, `name == "SET-BINDING"`) {
				t.Fatal("SET-BINDING must answer BUSY rather than wait for sessionMu")
			}
			return
		}
	}
	t.Fatal("the TryLock set was not found -- this test is stale, not the code")
}

// TestBindButtonShowsBusy pins the chooser's side from the source, which has no Java test surface: the Bind button
// maps a BUSY reply to its own result and says the phone is busy -- the DELETE-BINDING wording -- instead of the
// generic "couldn't save the binding", and only OK clears the form.
func TestBindButtonShowsBusy(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "chooser", "src", "com", "nowhere", "chooser", "ChooserActivity.java"))
	if err != nil {
		t.Fatalf("ChooserActivity.java must be readable from core/agent: %v", err)
	}
	src := string(b)
	for _, want := range []string{
		`(sr != null && sr.startsWith("BUSY")) ? "BUSY"`,
		`else if ("BUSY".equals(result)) StatusLine.error(msg, "the phone is busy saving — try again in a moment");`,
		`if ("BUSY".equals(r)) StatusLine.error(msg, "the phone is busy saving — try again in a moment");`, // the unbind's wording, the same
	} {
		if !strings.Contains(src, want) {
			t.Errorf("the bind form does not show a BUSY reply as busy: missing %q", want)
		}
	}
	// Only OK clears the form. Matched across line breaks: NWP-20261021-04 spread the OK branch over several lines.
	if !regexp.MustCompile(`if \("OK"\.equals\(result\)\) \{\s*passF\.setText\(""\); nameF\.setText\(""\);`).MatchString(src) {
		t.Errorf("the bind form's OK branch no longer starts by clearing the passphrase and name fields")
	}
}
