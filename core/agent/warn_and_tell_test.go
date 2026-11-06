package main

// NWP-20261016-47 (docs/product-decisions.md, 2026-10-16, "warn and tell"): the two endings that told the user nothing
// about a session's lost credit.
//
//   - WARN: a sign-in that supersedes a parked cold-locked session (#123) ends it, and nothing publishes its wallet. The
//     gate asks GET-PARKED-CREDIT before it creates the new user, and warns when the answer is LOST. The answer is the
//     same for a stored session and a throwaway in the same wallet state, so it is no existence oracle.
//   - TELL: "Restart without saving" clears the state tmpfs where the gate's notice lives. A restart that loses credit
//     leaves the notice at restartCreditLostPath instead, shown by the gate after the boot and cleared from its OK.
//
// core/agent/test-warn-and-tell.sh runs these and, with --mutate, convicts a broken copy of each rule.

import (
	"go/ast"
	"go/parser"
	"go/token"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

// ---- WARN: GET-PARKED-CREDIT ----

// parkedFixture is a gate with (or without) a parked session whose wallet file is in a given state. No store: the
// question reads only the cold-lock marker and the wallet's generation, proof and file; the supersede's log line reads
// the throwaway mark too.
type parkedFixture struct {
	name     string
	parked   bool // a .coldlock marker names user 15
	local    bool // the parked session is a throwaway
	offline  bool // ... and an offline sign-in (both marks, as handleRoamInOffline leaves them)
	restored bool // its generation earned its restore proof
	credit   bool // its wallet file holds tokens
	lost     bool // what GET-PARKED-CREDIT must answer
}

// logged is whether the supersede logs its lost-credit line: a stored session's loss only, the gate's wipe's rule.
func (c parkedFixture) logged() bool { return c.lost && !c.local }

var parkedCases = []parkedFixture{
	{name: "a parked stored session that never read its wallet, holding credit", parked: true, credit: true, lost: true},
	{name: "the same session holding nothing", parked: true},
	{name: "a parked session whose restore landed", parked: true, restored: true, credit: true},
	// A throwaway's credit (claimed before "Save to your store") is never saved, and the supersede loses it too.
	{name: "a parked throwaway holding credit", parked: true, local: true, credit: true, lost: true},
	{name: "a parked throwaway holding nothing", parked: true, local: true},
	{name: "a parked offline session holding credit", parked: true, local: true, offline: true, credit: true, lost: true},
	{name: "nothing parked, a never-read wallet holding credit", credit: true},
}

func (c parkedFixture) setup(t *testing.T) string {
	t.Helper()
	dest := t.TempDir()
	wp := walletPathFor(dest)
	if c.credit {
		if err := appendTokens(wp, newBlindTokens()); err != nil {
			t.Fatal(err)
		}
	}
	if c.restored {
		if err := markWalletRestoreLanded(wp, walletGeneration(wp)); err != nil {
			t.Fatal(err)
		}
	}
	if c.local {
		markLocalSession(dest)
	}
	if c.offline {
		markOfflineSession(dest)
	}
	if c.parked {
		if err := os.WriteFile(filepath.Join(dest, ".coldlock"), []byte("parkedone\n15\n\n\n\n\n\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dest
}

// listing is every file under dest with its content, to show a verb wrote nothing.
func listing(t *testing.T, dest string) string {
	t.Helper()
	var out []string
	filepath.Walk(dest, func(p string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			b, _ := os.ReadFile(p)
			out = append(out, p+"="+string(b))
		}
		return nil
	})
	sort.Strings(out)
	return strings.Join(out, "\n")
}

// The gate's answer is LOST exactly when the supersede would lose credit no publish has carried -- a stored session's
// that never read its wallet, a throwaway's, an offline session's -- and the supersede logs its line for the stored
// one only, from the same question: for every case, the line is logged if and only if the gate was answered LOST and
// the session is not a throwaway. Nothing is written.
func TestWarnAndTell_ParkedCreditIsLostOnlyForAParkedSessionHoldingUnsavedCredit(t *testing.T) {
	asGate(t)
	for _, c := range parkedCases {
		t.Run(c.name, func(t *testing.T) {
			dest := c.setup(t)
			before := listing(t, dest)
			got := driveLogin(t, dest, "GET-PARKED-CREDIT\n")
			want := "NONE"
			if c.lost {
				want = "LOST"
			}
			if got != want {
				t.Fatalf("GET-PARKED-CREDIT = %q, want %s", got, want)
			}
			if after := listing(t, dest); after != before {
				t.Fatalf("GET-PARKED-CREDIT changed the state dir:\nbefore:\n%s\nafter:\n%s", before, after)
			}
			out := captureStderr(t, func() { noteSupersededColdLockCredit(dest, "21", isLocalSession(dest)) })
			if logged := strings.Contains(out, supersededLine); logged != c.logged() {
				t.Fatalf("the supersede logged its lost-credit line: %v, want %v (the gate was answered %s, throwaway %v)",
					logged, c.logged(), got, c.local)
			}
		})
	}
}

// BLIND LOGIN. "Welcome back, <name>" is the same for a parked stored session and for the throwaway a wrong passphrase
// lands in, and anyone at the gate can ask GET-PARKED-CREDIT (tap "Not you?", type anything, Cancel). So for every
// wallet state the answer must be the same whichever kind is parked: the same marker and the same wallet, with no
// throwaway mark, with one, and with an offline sign-in's two, give the same GET-COLDLOCK and the same
// GET-PARKED-CREDIT. An answer that differed would be an existence oracle (docs/identity-model.md).
func TestWarnAndTell_ParkedCreditDoesNotTellAThrowawayFromAStoredProfile(t *testing.T) {
	asGate(t)
	for _, restored := range []bool{false, true} {
		for _, credit := range []bool{false, true} {
			var seen []string
			for _, kind := range []parkedFixture{
				{name: "stored"},
				{name: "throwaway", local: true},
				{name: "offline", local: true, offline: true},
			} {
				c := kind
				c.parked, c.restored, c.credit = true, restored, credit
				dest := c.setup(t)
				seen = append(seen, c.name+": "+driveLogin(t, dest, "GET-COLDLOCK\n")+" / "+
					driveLogin(t, dest, "GET-PARKED-CREDIT\n"))
			}
			for _, s := range seen[1:] {
				if strings.SplitN(s, ": ", 2)[1] != strings.SplitN(seen[0], ": ", 2)[1] {
					t.Errorf("restored %v, credit %v: the gate can tell the kind of the parked session apart:\n  %s",
						restored, credit, strings.Join(seen, "\n  "))
					break
				}
			}
		}
	}
}

// Only the gate (user 0) is answered: a roamed session's apps learn nothing of a parked session.
func TestWarnAndTell_ParkedCreditServesOnlyUserZero(t *testing.T) {
	dest := parkedCases[0].setup(t)
	for _, c := range []struct {
		what string
		uid  int
	}{
		{"the chooser in a roamed user", 1010123},
		{"an app in another roamed user", 1110200},
		{"a peer with no uid", -1},
	} {
		asCaller(t, c.uid, 10123)
		if got := driveLogin(t, dest, "GET-PARKED-CREDIT\n"); got != "NONE" {
			t.Errorf("%s: GET-PARKED-CREDIT = %q, want NONE", c.what, got)
		}
	}
	asGate(t)
	if got := driveLogin(t, dest, "GET-PARKED-CREDIT\n"); got != "LOST" {
		t.Fatalf("fixture: the gate reads %q, want LOST", got)
	}
}

// ---- TELL: the restart's notice, outside the state tmpfs ----

// restartNotice redirects restartCreditLostPath to a temp file for a test that does not run through euSetup.
func restartNotice(t *testing.T) string {
	t.Helper()
	old := restartCreditLostPath
	restartCreditLostPath = filepath.Join(t.TempDir(), "restart-credit-lost")
	t.Cleanup(func() { restartCreditLostPath = old })
	return restartCreditLostPath
}

// creditLostRestart is a session whose sign-in never read its stored wallet, holding credit if credit, whose media
// sweep failed twice: RESTART-UNSAVED goes ahead with OK-CREDIT-LOST. The reboot hook does nothing, so the restart is
// pending until the fixture's watchdog is released.
func creditLostRestart(t *testing.T, credit bool) (*euFixture, string) {
	t.Helper()
	f := euSetup(t)
	logoffSweepFailed("alice", euUID)
	logoffSweepFailed("alice", euUID)
	f.walletEr = errWalletNotRestored
	if credit {
		if err := appendTokens(walletPathFor(f.dest), newBlindTokens()); err != nil {
			t.Fatal(err)
		}
	}
	return f, ropReply(t, func(c net.Conn) { handleRestartUnsaved(c, f.dest) })
}

func noticeOnDisk(t *testing.T) (string, bool) {
	t.Helper()
	b, err := os.ReadFile(restartCreditLostPath)
	if err != nil {
		return "", false
	}
	return string(b), true
}

// The restart leaves a time and nothing else on durable storage, carries the same time in its marker, is NOT shown while
// its reboot has not happened, and after the boot -- a fresh state tmpfs, the daemon's start steps run -- the gate is
// shown it once and clears it from OK.
func TestWarnAndTell_ARestartThatLosesCreditTellsTheGateAfterTheBoot(t *testing.T) {
	f, got := creditLostRestart(t, true)
	if got != endUnsavedCreditLost {
		t.Fatalf("RESTART-UNSAVED = %q, want %s", got, endUnsavedCreditLost)
	}
	stamp, ok := noticeOnDisk(t)
	if !ok {
		t.Fatal("a restart that loses credit left no notice outside the state tmpfs: the gate is never told")
	}
	if stamp == "" || strings.Trim(stamp, "0123456789") != "" {
		t.Fatalf("the restart's notice holds more than a time: %q", stamp)
	}
	if fi, err := os.Stat(restartCreditLostPath); err != nil {
		t.Fatal(err)
	} else if fi.Mode().Perm() != 0o600 {
		t.Fatalf("the restart's notice on /data/nowhere is %v, want 0600", fi.Mode().Perm())
	}
	if got := restartMarkerTell(f.dest); got != stamp {
		t.Fatalf("the restart marker carries %q, the notice %q: a reboot that does not happen could not take it back",
			got, stamp)
	}
	asGate(t)
	if got := driveLogin(t, f.dest, "GET-CREDIT-LOST\n"); got != "NONE" {
		t.Fatalf("before the reboot GET-CREDIT-LOST = %q, want NONE: the restart is still pending", got)
	}
	// The boot: a new state tmpfs, and the daemon's start.
	booted := t.TempDir()
	dropRestartCreditLostTmp()
	recoverRestartMarker(booted)
	if _, ok := noticeOnDisk(t); !ok {
		t.Fatal("the daemon's start removed the restart's notice before the gate read it")
	}
	if got := driveLogin(t, booted, "GET-CREDIT-LOST\n"); got != "NOTICE "+stamp {
		t.Fatalf("after the boot GET-CREDIT-LOST = %q, want NOTICE %s", got, stamp)
	}
	if got := driveLogin(t, booted, "GET-CREDIT-LOST\n"); got != "NOTICE "+stamp {
		t.Fatalf("a second read = %q: the read consumed the notice before the gate's OK", got)
	}
	if got := driveLogin(t, booted, "CLEAR-CREDIT-LOST\n"+stamp+"\n"); got != "OK" {
		t.Fatalf("the gate's CLEAR-CREDIT-LOST = %q, want OK", got)
	}
	if _, ok := noticeOnDisk(t); ok {
		t.Fatal("the restart's notice survived the gate's OK")
	}
	if got := driveLogin(t, booted, "GET-CREDIT-LOST\n"); got != "NONE" {
		t.Fatalf("after the gate's OK GET-CREDIT-LOST = %q, want NONE", got)
	}
}

// A roamed caller can neither read the restart's notice nor clear it.
func TestWarnAndTell_TheRestartNoticeServesOnlyUserZero(t *testing.T) {
	restartNotice(t)
	noteRestartCreditLost("1760000000")
	dest := t.TempDir()
	asCaller(t, 1010123, 10123)
	if got := driveLogin(t, dest, "GET-CREDIT-LOST\n"); got != "NONE" {
		t.Errorf("a roamed caller's GET-CREDIT-LOST = %q, want NONE", got)
	}
	if got := driveLogin(t, dest, "CLEAR-CREDIT-LOST\n1760000000\n"); got != "DENIED" {
		t.Errorf("a roamed caller's CLEAR-CREDIT-LOST = %q, want DENIED", got)
	}
	if _, ok := noticeOnDisk(t); !ok {
		t.Fatal("a refused CLEAR-CREDIT-LOST removed the restart's notice")
	}
}

// The notice is written whole and private: a new file put in place by rename, 0600 whatever was there before and
// whatever the umask, with no .tmp left behind. An older notice the gate has not shown yet is replaced (the newest
// wins). Umask 0, so the mode is the code's own and not the runner's; the older file is 0644, so a write in place
// (which keeps an existing file's mode) is seen.
func TestWarnAndTell_TheRestartNoticeIsWrittenWholeAndPrivate(t *testing.T) {
	old := unix.Umask(0)
	defer unix.Umask(old)
	p := restartNotice(t)
	for _, c := range []struct {
		what  string
		older bool
	}{{"a first notice", false}, {"over an older notice", true}} {
		os.Remove(p)
		if c.older {
			if err := os.WriteFile(p, []byte("1700000000"), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(p, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		noteRestartCreditLost("1760000000")
		fi, err := os.Stat(p)
		if err != nil {
			t.Fatalf("%s: %v", c.what, err)
		}
		if fi.Mode().Perm() != 0o600 {
			t.Fatalf("%s: the notice is %v, want 0600 -- written in place or with a looser mode", c.what, fi.Mode().Perm())
		}
		if s, _ := noticeOnDisk(t); s != "1760000000" {
			t.Fatalf("%s: the notice holds %q, want the new time", c.what, s)
		}
		if _, err := os.Stat(p + ".tmp"); !os.IsNotExist(err) {
			t.Fatalf("%s: a .tmp is left beside the notice (stat err %v)", c.what, err)
		}
	}
}

// A restart whose reboot does not happen takes its notice back: the watchdog's give-back, and a daemon restart that
// finds the marker (the session is given back in both, so nothing was lost).
func TestWarnAndTell_ARestartWhoseRebootDoesNotHappenTakesItsNoticeBack(t *testing.T) {
	t.Run("the watchdog gives the session back", func(t *testing.T) {
		f, got := creditLostRestart(t, true)
		if got != endUnsavedCreditLost {
			t.Fatalf("RESTART-UNSAVED = %q", got)
		}
		if _, ok := noticeOnDisk(t); !ok {
			t.Fatal("fixture: no notice after the restart")
		}
		f.endWatchdog()
		if got := ropReply(t, func(c net.Conn) { handleRestartStatus(c, f.dest) }); got != "FAILED" {
			t.Fatalf("fixture: RESTART-STATUS = %q, want FAILED", got)
		}
		if s, ok := noticeOnDisk(t); ok {
			t.Fatalf("the restart did not happen and the session was given back, but its notice %q stayed: the next "+
				"boot would say credit was lost that the session still holds", s)
		}
	})
	t.Run("the daemon restarts while it is pending", func(t *testing.T) {
		f, got := creditLostRestart(t, true)
		if got != endUnsavedCreditLost {
			t.Fatalf("RESTART-UNSAVED = %q", got)
		}
		recoverRestartMarker(f.dest)
		if isLocalSession(f.dest) {
			t.Fatal("a marker carrying the restart's notice was not honoured at the daemon's start: the session stays " +
				"local, with no seals")
		}
		if s, ok := noticeOnDisk(t); ok {
			t.Fatalf("the daemon's start gave the session back and left the restart's notice %q", s)
		}
	})
}

// The notice is written only once the restart can no longer refuse, and a refusal takes back only its own notice: an
// older one, waiting from an earlier boot, still reaches the gate.
func TestWarnAndTell_ARefusedRestartTellsNothingAndLeavesAnOlderNotice(t *testing.T) {
	t.Run("the marker cannot be written", func(t *testing.T) {
		f := euSetup(t)
		logoffSweepFailed("alice", euUID)
		logoffSweepFailed("alice", euUID)
		f.walletEr = errWalletNotRestored
		if err := appendTokens(walletPathFor(f.dest), newBlindTokens()); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(filepath.Join(f.dest, restartMarkerFile), 0o700); err != nil {
			t.Fatal(err)
		}
		if got := ropReply(t, func(c net.Conn) { handleRestartUnsaved(c, f.dest) }); got != "ERR-STATE" {
			t.Fatalf("RESTART-UNSAVED with an unwritable marker = %q, want ERR-STATE", got)
		}
		if s, ok := noticeOnDisk(t); ok {
			t.Fatalf("a restart refused before anything changed left a notice %q: the next boot would report a loss "+
				"that never happened", s)
		}
	})
	t.Run("the keystore stash cannot be removed", func(t *testing.T) {
		f := euSetup(t)
		logoffSweepFailed("alice", euUID)
		logoffSweepFailed("alice", euUID)
		f.walletEr = errWalletNotRestored
		if err := appendTokens(walletPathFor(f.dest), newBlindTokens()); err != nil {
			t.Fatal(err)
		}
		const older = "1700000000"
		if err := os.WriteFile(restartCreditLostPath, []byte(older), 0o600); err != nil {
			t.Fatal(err)
		}
		ks := filepath.Join(f.dest, ksLogoffCredsFile)
		os.Remove(ks)
		if err := os.MkdirAll(filepath.Join(ks, "x"), 0o700); err != nil { // a non-empty directory: os.Remove fails
			t.Fatal(err)
		}
		if got := ropReply(t, func(c net.Conn) { handleRestartUnsaved(c, f.dest) }); got != "ERR-KEYS" {
			t.Fatalf("RESTART-UNSAVED with an unremovable stash = %q, want ERR-KEYS", got)
		}
		if s, ok := noticeOnDisk(t); !ok || s != older {
			t.Fatalf("after a refused restart the notice on disk is %q (present %v), want the earlier boot's %q, "+
				"untouched", s, ok, older)
		}
	})
}

// A restart that loses nothing tells nothing: the wallet was saved first, or the never-read wallet holds nothing.
func TestWarnAndTell_ARestartThatLosesNothingTellsNothing(t *testing.T) {
	t.Run("the wallet was saved", func(t *testing.T) {
		f := euSetup(t)
		logoffSweepFailed("alice", euUID)
		logoffSweepFailed("alice", euUID)
		if err := appendTokens(walletPathFor(f.dest), newBlindTokens()); err != nil {
			t.Fatal(err)
		}
		if got := ropReply(t, func(c net.Conn) { handleRestartUnsaved(c, f.dest) }); got != "OK" {
			t.Fatalf("RESTART-UNSAVED = %q, want OK", got)
		}
		if s, ok := noticeOnDisk(t); ok {
			t.Fatalf("a restart that saved the wallet left a lost-credit notice %q", s)
		}
		if got := restartMarkerTell(f.dest); got != "" {
			t.Fatalf("its marker carries a notice time %q", got)
		}
	})
	t.Run("the never-read wallet holds nothing", func(t *testing.T) {
		_, got := creditLostRestart(t, false)
		if got != endUnsavedCreditLost {
			t.Fatalf("RESTART-UNSAVED = %q, want %s", got, endUnsavedCreditLost)
		}
		if s, ok := noticeOnDisk(t); ok {
			t.Fatalf("a restart with no credit held left a lost-credit notice %q", s)
		}
	})
}

// The restart's notice and the tmpfs one are each shown and cleared by their own time, the restart's first; a restart
// notice whose reboot has not happened is neither shown nor counted, nor cleared by another notice's OK.
func TestWarnAndTell_TheTwoNoticesAreShownAndClearedOneAtATime(t *testing.T) {
	restartNotice(t)
	dest := t.TempDir()
	noteRestartCreditLost("100")
	noteCreditLost(dest)
	tmpfs := strings.TrimPrefix(func() string { b, _ := os.ReadFile(creditLostPath(dest)); return "NOTICE " + string(b) }(), "NOTICE ")
	if got := creditLostReply(dest); got != "NOTICE 100" {
		t.Fatalf("with both recorded GET-CREDIT-LOST = %q, want the restart's NOTICE 100 first", got)
	}
	if got := clearCreditLost(dest, "100"); got != "STALE" {
		t.Fatalf("clearing the restart's notice = %q, want STALE: the tmpfs one is still to be shown", got)
	}
	if got := creditLostReply(dest); got != "NOTICE "+tmpfs {
		t.Fatalf("after the restart's OK GET-CREDIT-LOST = %q, want NOTICE %s", got, tmpfs)
	}
	if got := clearCreditLost(dest, tmpfs); got != "OK" {
		t.Fatalf("clearing the tmpfs notice = %q, want OK", got)
	}
	if got := creditLostReply(dest); got != "NONE" {
		t.Fatalf("after both OKs GET-CREDIT-LOST = %q, want NONE", got)
	}

	// A restart pending in this boot: its notice waits for the reboot.
	noteRestartCreditLost("200")
	if err := writeRestartMarkerTell(dest, "alice", euUID, "200"); err != nil {
		t.Fatal(err)
	}
	if got := creditLostReply(dest); got != "NONE" {
		t.Fatalf("with the restart still pending GET-CREDIT-LOST = %q, want NONE", got)
	}
	noteCreditLost(dest)
	b, _ := os.ReadFile(creditLostPath(dest))
	if got := creditLostReply(dest); got != "NOTICE "+string(b) {
		t.Fatalf("a tmpfs notice beside a pending restart reads %q, want NOTICE %s", got, b)
	}
	if got := clearCreditLost(dest, string(b)); got != "OK" {
		t.Fatalf("clearing it = %q, want OK: the pending restart's notice is not one the gate has to show", got)
	}
	if s, ok := noticeOnDisk(t); !ok || s != "200" {
		t.Fatalf("the pending restart's notice is %q (present %v) after another notice's OK, want 200", s, ok)
	}
}

// The daemon's start drops a .tmp a crash left between the write and the rename, and never the notice: loginDaemon
// runs the drop exactly once, and the drop removes only the .tmp.
func TestWarnAndTell_TheDaemonStartDropsOnlyAnOrphanedTmp(t *testing.T) {
	af, err := parser.ParseFile(token.NewFileSet(), filepath.Join(agentDir(), "main.go"), nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	daemon, calls := false, 0
	for _, d := range af.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok && fd.Recv == nil && fd.Name.Name == "loginDaemon" {
			daemon = true
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				if ce, ok := n.(*ast.CallExpr); ok {
					if id, ok := ce.Fun.(*ast.Ident); ok && id.Name == "dropRestartCreditLostTmp" {
						calls++
					}
				}
				return true
			})
		}
	}
	if !daemon || calls != 1 {
		t.Fatalf("loginDaemon found %v, and it calls dropRestartCreditLostTmp %d time(s), want once: a .tmp a crash "+
			"left mid-write would never go", daemon, calls)
	}

	p := restartNotice(t)
	if err := os.WriteFile(p, []byte("300"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p+".tmp", []byte("301"), 0o600); err != nil {
		t.Fatal(err)
	}
	dropRestartCreditLostTmp()
	if _, err := os.Stat(p + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("the orphaned .tmp survived the daemon's start (stat err %v)", err)
	}
	if s, ok := noticeOnDisk(t); !ok || s != "300" {
		t.Fatalf("the notice is %q (present %v) after the daemon's start, want 300", s, ok)
	}
}

// Nothing but the gate's OK and a restart's own take-back removes the notice: in the agent only the five notice
// functions name restartCreditLostPath, nothing else in the tree names the file, and no shell script or init file
// empties /data/nowhere wholesale (the boot sweep included).
func TestWarnAndTell_NothingElseRemovesTheRestartNotice(t *testing.T) {
	want := []string{"clearCreditLost", "creditLostReply", "dropRestartCreditLostTmp", "noteRestartCreditLost",
		"retractRestartCreditLost"}
	fset := token.NewFileSet()
	var users []string
	files, _ := filepath.Glob(filepath.Join(agentDir(), "*.go"))
	for _, p := range files {
		if strings.HasSuffix(p, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, p, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range af.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok {
				continue
			}
			named := false
			ast.Inspect(fd, func(n ast.Node) bool {
				if id, ok := n.(*ast.Ident); ok && id.Name == "restartCreditLostPath" {
					named = true
				}
				return true
			})
			if named {
				users = append(users, fd.Name.Name)
			}
		}
	}
	sort.Strings(users)
	if strings.Join(users, " ") != strings.Join(want, " ") {
		t.Fatalf("the functions naming restartCreditLostPath are %v, want %v: a new one could remove the notice before "+
			"the gate reads it", users, want)
	}

	root := filepath.Join(agentDir(), "..", "..")
	exts := map[string]bool{".go": true, ".sh": true, ".rc": true, ".java": true, ".te": true, ".mk": true, ".bp": true,
		".xml": true, ".py": true}
	wipe := regexp.MustCompile(`\brm\b[^#\n]*/data/nowhere(/\*|/\.\*|/\.\[|["']?(\s|;|$))|\bfind\s+["']?/data/nowhere["']?\s|` +
		`[A-Za-z_]\w*=["']?/data/nowhere/?["']?(\s|;|$)`)
	goWipe := regexp.MustCompile(`Remove(All)?\(\s*(issueLogDir\(\)|"/data/nowhere/?")\s*\)`)
	var names []string
	scanned := 0
	for _, top := range []string{"core", "editions"} {
		filepath.Walk(filepath.Join(root, top), func(p string, info os.FileInfo, err error) error {
			if err != nil || info.IsDir() || !exts[filepath.Ext(p)] {
				return nil
			}
			rel, _ := filepath.Rel(root, p)
			base := filepath.Base(p)
			parts := strings.Split(filepath.ToSlash(rel), "/")
			if strings.HasSuffix(base, "_test.go") || strings.HasPrefix(base, "test-") || strings.HasPrefix(base, "test_") {
				return nil
			}
			for _, part := range parts {
				if part == "tests" || part == "test" {
					return nil
				}
			}
			b, err := os.ReadFile(p)
			if err != nil {
				return nil
			}
			scanned++
			for i, line := range strings.Split(string(b), "\n") {
				if strings.Contains(line, "restart-credit-lost") {
					names = append(names, filepath.ToSlash(rel))
				}
				code := line
				if strings.HasPrefix(strings.TrimSpace(code), "#") || strings.HasPrefix(strings.TrimSpace(code), "//") {
					continue
				}
				switch filepath.Ext(p) {
				case ".sh", ".rc":
					if wipe.MatchString(code) {
						t.Errorf("%s:%d empties or aliases /data/nowhere wholesale, which would remove the restart's "+
							"notice before the gate reads it: %s", rel, i+1, strings.TrimSpace(code))
					}
				case ".go":
					if goWipe.MatchString(code) {
						t.Errorf("%s:%d removes /data/nowhere itself: %s", rel, i+1, strings.TrimSpace(code))
					}
				}
			}
			return nil
		})
	}
	if scanned < 100 {
		t.Fatalf("only %d source files scanned under %s: the tree moved", scanned, root)
	}
	if strings.Join(names, " ") != "core/agent/wallet_restore.go" {
		t.Fatalf("the notice's file name appears in %v, want only core/agent/wallet_restore.go (its var)", names)
	}
}
