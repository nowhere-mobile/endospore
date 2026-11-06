package main

import (
	"bytes"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20260904-08: the .roamsession marker must distinguish absent / complete / damaged and say which. Before
// this slice readRoamSession padded a short marker to three fields, so a marker that had lost its uid read
// exactly like a complete one -- no error, no log line -- and markRoamSession ignored both of its write
// errors. These tests pin the three states, the once-per-damage log, and the surfaced write error.

// captureStderr runs fn with os.Stderr redirected to a pipe and returns what it wrote. The marker code logs
// with fmt.Fprintf(os.Stderr, ...), resolving the variable at call time, so a swap is enough.
func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	old := os.Stderr
	os.Stderr = w
	var buf bytes.Buffer
	done := make(chan struct{})
	go func() {
		io.Copy(&buf, r)
		close(done)
	}()
	func() {
		defer func() { os.Stderr = old }()
		fn()
	}()
	w.Close()
	<-done
	r.Close()
	return buf.String()
}

// writeMarker lays the raw bytes down as the marker, bypassing markRoamSession, so a damaged shape can be
// staged exactly as a fault would leave it.
func writeMarker(t *testing.T, dest, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dest, ".roamsession"), []byte(body), 0o600); err != nil {
		t.Fatalf("stage marker: %v", err)
	}
}

// Distinctive fixture values, so a leak of a VALUE into the log is caught by a substring check.
const (
	tName = "fixture-name-zq7"
	tPass = "fixture-pass-xk3"
	tSE   = "fixture-se-pm9"
)

func TestRoamSessionMarkerAbsent(t *testing.T) {
	dest := t.TempDir()
	var n, p, u string
	var st roamSessionState
	log := captureStderr(t, func() {
		n, p, u, st = readRoamSessionState(dest)
	})
	if st != roamSessionAbsent || n != "" || p != "" || u != "" {
		t.Fatalf("absent: got (%q,%q,%q,%v)", n, p, u, st)
	}
	if n, p, u := readRoamSession(dest); n != "" || p != "" || u != "" {
		t.Fatalf("readRoamSession on absent: got (%q,%q,%q)", n, p, u)
	}
	if readRoamSessionSE(dest) != "" {
		t.Fatal("readRoamSessionSE on absent must be empty")
	}
	if log != "" {
		t.Fatalf("absent is not damage; logged %q", log)
	}
}

func TestRoamSessionMarkerComplete3Lines(t *testing.T) {
	dest := t.TempDir()
	writeMarker(t, dest, tName+"\n"+tPass+"\n11\n") // the pre-Endospore shape: no se line
	var n, p, u string
	var st roamSessionState
	log := captureStderr(t, func() {
		n, p, u, st = readRoamSessionState(dest)
	})
	if st != roamSessionComplete || n != tName || p != tPass || u != "11" {
		t.Fatalf("3-line: got (%q,%q,%q,%v)", n, p, u, st)
	}
	if n, p, u := readRoamSession(dest); n != tName || p != tPass || u != "11" {
		t.Fatalf("readRoamSession 3-line: got (%q,%q,%q)", n, p, u)
	}
	if se := readRoamSessionSE(dest); se != "" {
		t.Fatalf("3-line marker has no se; got %q", se)
	}
	if n, _, u := liveSession(dest); n != tName || u != "11" {
		t.Fatalf("liveSession: got (%q,%q)", n, u)
	}
	if log != "" {
		t.Fatalf("complete is not damage; logged %q", log)
	}
	// No trailing newline at all is still the same three fields.
	writeMarker(t, dest, tName+"\n"+tPass+"\n11")
	if _, _, u, st := readRoamSessionState(dest); st != roamSessionComplete || u != "11" {
		t.Fatalf("3-line, no trailing newline: got (%q,%v)", u, st)
	}
}

func TestRoamSessionMarkerComplete4LinesSE(t *testing.T) {
	dest := t.TempDir()
	// Written by the real writer: 4 lines, se set.
	if err := markRoamSession(dest, tName, tPass, "12", tSE); err != nil {
		t.Fatalf("markRoamSession: %v", err)
	}
	var n, p, u string
	var st roamSessionState
	log := captureStderr(t, func() {
		n, p, u, st = readRoamSessionState(dest)
	})
	if st != roamSessionComplete || n != tName || p != tPass || u != "12" {
		t.Fatalf("4-line: got (%q,%q,%q,%v)", n, p, u, st)
	}
	if se := readRoamSessionSE(dest); se != tSE {
		t.Fatalf("se: got %q want %q", se, tSE)
	}
	if log != "" {
		t.Fatalf("complete is not damage; logged %q", log)
	}
	// The writer's own shape with an EMPTY se line (every non-hardened login) is complete too.
	if err := markRoamSession(dest, tName, tPass, "12", ""); err != nil {
		t.Fatalf("markRoamSession (no se): %v", err)
	}
	if _, _, u, st := readRoamSessionState(dest); st != roamSessionComplete || u != "12" {
		t.Fatalf("4-line, empty se: got (%q,%v)", u, st)
	}
	if b, _ := os.ReadFile(filepath.Join(dest, ".roamsession")); string(b) != tName+"\n"+tPass+"\n12\n\n" {
		t.Fatalf("writer shape changed: %q", b)
	}
}

// damagedCase stages one damaged shape and asserts: state damaged, readRoamSession returns ALL-empty (never the
// old padded partial), readRoamSessionSE empty, and the log line carries the shape and no value.
func damagedCase(t *testing.T, body, wantShape string) {
	t.Helper()
	dest := t.TempDir()
	writeMarker(t, dest, body)
	var st roamSessionState
	var n, p, u string
	log := captureStderr(t, func() {
		_, _, _, st = readRoamSessionState(dest)
		n, p, u = readRoamSession(dest)
	})
	if st != roamSessionDamaged {
		t.Fatalf("%q: state %v want damaged", body, st)
	}
	if n != "" || p != "" || u != "" {
		t.Fatalf("%q: readRoamSession must return nothing on a damaged marker, got (%q,%q,%q)", body, n, p, u)
	}
	if se := readRoamSessionSE(dest); se != "" {
		t.Fatalf("%q: readRoamSessionSE must be empty on a damaged marker, got %q", body, se)
	}
	if n, _, u := liveSession(dest); n != "" || u != "" {
		t.Fatalf("%q: liveSession must not deliver into a damaged marker, got (%q,%q)", body, n, u)
	}
	want := "[logind] .roamsession DAMAGED: " + wantShape
	if !strings.Contains(log, want) {
		t.Fatalf("%q: log %q does not carry %q", body, log, want)
	}
	for _, secret := range []string{tName, tPass, tSE} {
		if strings.Contains(log, secret) {
			t.Fatalf("%q: log leaked a marker VALUE: %q", body, log)
		}
	}
}

func TestRoamSessionMarkerShort(t *testing.T) {
	damagedCase(t, "", "0 line(s), name=empty, pass=empty, uid=empty")
	damagedCase(t, "\n", "0 line(s), name=empty, pass=empty, uid=empty")
	damagedCase(t, tName+"\n", "1 line(s), name=set, pass=empty, uid=empty")
	damagedCase(t, tName+"\n"+tPass+"\n", "2 line(s), name=set, pass=set, uid=empty")
	damagedCase(t, tName+"\n"+tPass, "2 line(s), name=set, pass=set, uid=empty")
}

func TestRoamSessionMarkerEmptyUID(t *testing.T) {
	// The frankel shape: name and pass present, the uid line blank. With a trailing se line the file is still
	// 4 lines; without one the blank uid collapses into the trailing newlines and it reads as 2.
	damagedCase(t, tName+"\n"+tPass+"\n\n"+tSE+"\n", "4 line(s), name=set, pass=set, uid=empty")
	damagedCase(t, tName+"\n"+tPass+"\n\n", "2 line(s), name=set, pass=set, uid=empty")
}

func TestRoamSessionMarkerEmptyName(t *testing.T) {
	damagedCase(t, "\n"+tPass+"\n11\n", "3 line(s), name=empty, pass=set, uid=set")
	damagedCase(t, "\n"+tPass+"\n11\n"+tSE+"\n", "4 line(s), name=empty, pass=set, uid=set")
}

func TestRoamSessionMarkerEmptyPass(t *testing.T) {
	damagedCase(t, tName+"\n\n11\n", "3 line(s), name=set, pass=empty, uid=set")
}

func TestRoamSessionMarkerTooManyLines(t *testing.T) {
	// Not a shape markRoamSession ever writes.
	damagedCase(t, tName+"\n"+tPass+"\n11\n"+tSE+"\nextra\n", "5 line(s), name=set, pass=set, uid=set")
}

func TestRoamSessionMarkerUnreadable(t *testing.T) {
	// The marker path exists but is a directory: that is damage, not "nobody signed in".
	dest := t.TempDir()
	if err := os.Mkdir(filepath.Join(dest, ".roamsession"), 0o700); err != nil {
		t.Fatal(err)
	}
	var st roamSessionState
	log := captureStderr(t, func() {
		_, _, _, st = readRoamSessionState(dest)
	})
	if st != roamSessionDamaged {
		t.Fatalf("directory marker: state %v want damaged", st)
	}
	if !strings.Contains(log, "[logind] .roamsession DAMAGED: unreadable:") {
		t.Fatalf("directory marker: log %q", log)
	}
}

func TestRoamSessionMarkerCRLF(t *testing.T) {
	dest := t.TempDir()
	writeMarker(t, dest, tName+"\r\n"+tPass+"\r\n11\r\n")
	if n, p, u, st := readRoamSessionState(dest); st != roamSessionComplete || n != tName || p != tPass || u != "11" {
		t.Fatalf("CRLF 3-line: got (%q,%q,%q,%v)", n, p, u, st)
	}
	writeMarker(t, dest, tName+"\r\n"+tPass+"\r\n11\r\n"+tSE+"\r\n")
	if n, p, u, st := readRoamSessionState(dest); st != roamSessionComplete || n != tName || p != tPass || u != "11" {
		t.Fatalf("CRLF 4-line: got (%q,%q,%q,%v)", n, p, u, st)
	}
	if se := readRoamSessionSE(dest); se != tSE {
		t.Fatalf("CRLF se: got %q", se)
	}
}

func TestRoamSessionMarkerDamageLoggedOnce(t *testing.T) {
	dest := t.TempDir()
	writeMarker(t, dest, tName+"\n"+tPass+"\n")
	count := func(s string) int { return strings.Count(s, "[logind] .roamsession DAMAGED:") }
	// The periodic seal reads the marker every couple of minutes: the same damaged file logs exactly once.
	log := captureStderr(t, func() {
		for i := 0; i < 5; i++ {
			readRoamSession(dest)
		}
		readRoamSessionState(dest)
		readRoamSessionSE(dest)
	})
	if got := count(log); got != 1 {
		t.Fatalf("same damage read 7 times: logged %d time(s), want 1: %q", got, log)
	}
	// A DIFFERENT damage is a new event.
	log = captureStderr(t, func() {
		writeMarker(t, dest, tName+"\n")
		readRoamSession(dest)
		readRoamSession(dest)
	})
	if got := count(log); got != 1 || !strings.Contains(log, "1 line(s)") {
		t.Fatalf("new damage: logged %d time(s), want 1 with the new shape: %q", got, log)
	}
	// Healed -> silence; damaged again -> a new event, even though the shape repeats.
	log = captureStderr(t, func() {
		if err := markRoamSession(dest, tName, tPass, "11", ""); err != nil {
			t.Errorf("markRoamSession: %v", err)
		}
		readRoamSession(dest)
		writeMarker(t, dest, tName+"\n"+tPass+"\n")
		readRoamSession(dest)
		readRoamSession(dest)
	})
	if got := count(log); got != 1 {
		t.Fatalf("heal then re-damage: logged %d time(s), want 1: %q", got, log)
	}
	// Absent -> silence, and the memory is cleared for the next stretch.
	log = captureStderr(t, func() {
		os.Remove(filepath.Join(dest, ".roamsession"))
		readRoamSession(dest)
	})
	if log != "" {
		t.Fatalf("absent after damage must not log: %q", log)
	}
}

func TestMarkRoamSessionWriteError(t *testing.T) {
	// dest is a FILE, so the temp write fails (ENOTDIR on every platform): the error must come back.
	notDir := filepath.Join(t.TempDir(), "notadir")
	if err := os.WriteFile(notDir, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := markRoamSession(notDir, tName, tPass, "11", "")
	if err == nil {
		t.Fatal("markRoamSession into a non-directory must fail")
	}
	if !strings.Contains(err.Error(), ".roamsession") {
		t.Fatalf("error must name the marker: %v", err)
	}
	for _, secret := range []string{tName, tPass} {
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("error leaked a marker value: %v", err)
		}
	}

	// The temp write succeeds but the rename cannot land: the target is a non-empty directory. The error
	// must come back and the temp file must not be left behind.
	dest := t.TempDir()
	if err := os.Mkdir(filepath.Join(dest, ".roamsession"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, ".roamsession", "occupant"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := markRoamSession(dest, tName, tPass, "11", ""); err == nil {
		t.Fatal("markRoamSession whose rename cannot land must fail")
	}
	if _, err := os.Stat(filepath.Join(dest, ".roamsession.tmp")); !os.IsNotExist(err) {
		t.Fatalf("failed write left the temp file behind: %v", err)
	}

	// The writer refuses a marker that would read back as damaged, before touching the file.
	dest = t.TempDir()
	for _, c := range [][3]string{{"", tPass, "11"}, {tName, "", "11"}, {tName, tPass, ""}} {
		if err := markRoamSession(dest, c[0], c[1], c[2], ""); err == nil {
			t.Fatalf("markRoamSession(%q,%q,%q) must refuse an incomplete marker", c[0], c[1], c[2])
		}
		if _, err := os.Stat(filepath.Join(dest, ".roamsession")); !os.IsNotExist(err) {
			t.Fatalf("a refused marker must not be written: %v", err)
		}
	}

	// And the normal case succeeds, landing a complete marker.
	if err := markRoamSession(dest, tName, tPass, "11", tSE); err != nil {
		t.Fatalf("markRoamSession normal: %v", err)
	}
	if n, p, u, st := readRoamSessionState(dest); st != roamSessionComplete || n != tName || p != tPass || u != "11" {
		t.Fatalf("after a good write: got (%q,%q,%q,%v)", n, p, u, st)
	}
	if _, err := os.Stat(filepath.Join(dest, ".roamsession.tmp")); !os.IsNotExist(err) {
		t.Fatalf("good write left the temp file behind: %v", err)
	}
}

func TestRearmRoamSessionLogsWriteFailure(t *testing.T) {
	notDir := filepath.Join(t.TempDir(), "notadir")
	if err := os.WriteFile(notDir, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	log := captureStderr(t, func() {
		rearmRoamSession(notDir, tName, tPass, "11", "", "logout seal failed, re-arm")
	})
	if !strings.Contains(log, "[logind] .roamsession WRITE FAILED:") || !strings.Contains(log, "logout seal failed, re-arm") {
		t.Fatalf("re-arm failure must be loud with its reason: %q", log)
	}
	for _, secret := range []string{tName, tPass} {
		if strings.Contains(log, secret) {
			t.Fatalf("re-arm log leaked a marker value: %q", log)
		}
	}
	// And a good re-arm is silent.
	dest := t.TempDir()
	if log := captureStderr(t, func() { rearmRoamSession(dest, tName, tPass, "11", "", "rollback failed, re-arm") }); log != "" {
		t.Fatalf("a good re-arm must be silent: %q", log)
	}
	if _, _, u := readRoamSession(dest); u != "11" {
		t.Fatal("re-arm did not land the marker")
	}
}

// The mandated single retry: a first attempt that fails for a transient reason must not fail the login when
// the second lands, and a persistent fault stops after exactly two attempts with the prior marker untouched.
func TestMarkRoamSessionRetriesOnce(t *testing.T) {
	orig := roamSessionWriteFile
	defer func() { roamSessionWriteFile = orig }()
	dest := t.TempDir()
	calls := 0
	roamSessionWriteFile = func(name string, data []byte, perm os.FileMode) error {
		calls++
		if calls == 1 {
			return errors.New("injected transient fault")
		}
		return os.WriteFile(name, data, perm)
	}
	if err := markRoamSession(dest, tName, tPass, "11", ""); err != nil {
		t.Fatalf("a transient first-attempt fault must be retried, got %v", err)
	}
	if calls != 2 {
		t.Fatalf("retry: %d write attempt(s), want 2", calls)
	}
	if n, p, u, st := readRoamSessionState(dest); st != roamSessionComplete || n != tName || p != tPass || u != "11" {
		t.Fatalf("the retried write did not land a complete marker: (%q,%q,%q,%v)", n, p, u, st)
	}
	// A persistent fault: two attempts, then the error, and the marker that was there stays exactly as it was.
	calls = 0
	roamSessionWriteFile = func(string, []byte, os.FileMode) error {
		calls++
		return errors.New("injected persistent fault")
	}
	err := markRoamSession(dest, tName, tPass, "12", "")
	if err == nil {
		t.Fatal("a persistent write fault must come back as an error")
	}
	if calls != 2 {
		t.Fatalf("persistent fault: %d write attempt(s), want exactly 2", calls)
	}
	if !strings.Contains(err.Error(), "after 2 attempts") || !strings.Contains(err.Error(), "injected persistent fault") {
		t.Fatalf("error must say it retried and carry the cause: %v", err)
	}
	if _, _, u, st := readRoamSessionState(dest); st != roamSessionComplete || u != "11" {
		t.Fatalf("a failed write must leave the prior marker untouched: (%q,%v)", u, st)
	}
	if _, err := os.Stat(filepath.Join(dest, ".roamsession.tmp")); !os.IsNotExist(err) {
		t.Fatalf("failed write left the temp file behind: %v", err)
	}
}

// pinMarker stages a raw marker and pins its mtime, so two stagings are told apart by NOTHING but their
// bytes: the once-per-damage key must then rest on the shape, not on a fresh mtime.
func pinMarker(t *testing.T, dest, body string) {
	t.Helper()
	writeMarker(t, dest, body)
	pin := time.Unix(1700000000, 0)
	if err := os.Chtimes(filepath.Join(dest, ".roamsession"), pin, pin); err != nil {
		t.Fatalf("pin mtime: %v", err)
	}
}

// A DIFFERENT damaged shape of the SAME size and mtime is a new event: the key carries the shape.
func TestRoamSessionMarkerDamageKeyIsShape(t *testing.T) {
	dest := t.TempDir()
	uidLost := tName + "\n" + tPass + "\n\n"  // 2 line(s), pass=set, uid=empty
	passLost := tName + "\n\n" + tPass + "\n" // 3 line(s), pass=empty, uid=set -- same byte length
	if len(uidLost) != len(passLost) {
		t.Fatalf("fixture: the two shapes must be the same size (%d vs %d)", len(uidLost), len(passLost))
	}
	log := captureStderr(t, func() {
		pinMarker(t, dest, uidLost)
		readRoamSession(dest)
		readRoamSession(dest)
		pinMarker(t, dest, passLost)
		readRoamSession(dest)
		readRoamSession(dest)
	})
	if got := strings.Count(log, "[logind] .roamsession DAMAGED:"); got != 2 {
		t.Fatalf("two distinct shapes, same size+mtime: logged %d time(s), want 2: %q", got, log)
	}
	if !strings.Contains(log, "2 line(s), name=set, pass=set, uid=empty") || !strings.Contains(log, "3 line(s), name=set, pass=empty, uid=set") {
		t.Fatalf("both shapes must be named: %q", log)
	}
}

// A complete read CLEARS the memory: the identical damage (same bytes, same size, same pinned mtime) after a
// heal is its own event, not a repeat of the one before the heal.
func TestRoamSessionMarkerDamageForgetOnHeal(t *testing.T) {
	dest := t.TempDir()
	body := tName + "\n" + tPass + "\n"
	log := captureStderr(t, func() {
		pinMarker(t, dest, body)
		readRoamSession(dest)
		if err := markRoamSession(dest, tName, tPass, "11", ""); err != nil {
			t.Errorf("heal: %v", err)
		}
		readRoamSession(dest)
		pinMarker(t, dest, body)
		readRoamSession(dest)
		readRoamSession(dest)
	})
	if got := strings.Count(log, "[logind] .roamsession DAMAGED:"); got != 2 {
		t.Fatalf("damage, heal, identical damage: logged %d time(s), want 2: %q", got, log)
	}
	// And the same for an absent stretch in between.
	log = captureStderr(t, func() {
		os.Remove(filepath.Join(dest, ".roamsession"))
		readRoamSession(dest)
		pinMarker(t, dest, body)
		readRoamSession(dest)
	})
	if got := strings.Count(log, "[logind] .roamsession DAMAGED:"); got != 1 {
		t.Fatalf("absent then identical damage: logged %d time(s), want 1: %q", got, log)
	}
}

// Review (NWP-20260904-08): the legacy Arc-1 login fallthrough wipes (wipeSessionState) the SHARED state tmpfs on
// its way to a restore (DIA-20260704-33). Its guard used to be "readRoamSession returned a name", which a
// damaged marker no longer does -- so a stray or version-skewed request during a session whose marker had
// lost its uid would have destroyed the wallet, the fido2 stash and the marker itself. The guard is the
// marker EXISTING: damaged and complete are both refused with BLANK and the state dir untouched.
func TestLegacyLoginRefusedWhileMarkerExists(t *testing.T) {
	for _, c := range []struct{ label, body string }{
		{"damaged (uid lost)", tName + "\n" + tPass + "\n\n"},
		{"damaged (1 line)", tName + "\n"},
		{"complete", tName + "\n" + tPass + "\n11\n\n"},
	} {
		dest := t.TempDir()
		writeMarker(t, dest, c.body)
		sentinel := filepath.Join(dest, "wallet.json")
		if err := os.WriteFile(sentinel, []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
		cli, srv := net.Pipe()
		go cli.Write([]byte("someone-else\nsome passphrase\n")) // not a verb: the legacy login path
		reply := make(chan string, 1)
		go func() {
			b, _ := io.ReadAll(cli) // ends when handleLogin closes its end
			reply <- string(b)
		}()
		handleLogin(srv, dest) // closes srv itself
		got := strings.TrimSpace(<-reply)
		cli.Close()
		if got != "BLANK" {
			t.Fatalf("%s: reply %q, want BLANK", c.label, got)
		}
		if _, err := os.Stat(sentinel); err != nil {
			t.Fatalf("%s: the legacy login destroyed the live session's state dir: %v", c.label, err)
		}
		if b, err := os.ReadFile(filepath.Join(dest, ".roamsession")); err != nil || string(b) != c.body {
			t.Fatalf("%s: the marker was touched (%q, %v)", c.label, b, err)
		}
		if !roamSessionExists(dest) {
			t.Fatalf("%s: roamSessionExists must be true", c.label)
		}
	}
	if roamSessionExists(t.TempDir()) {
		t.Fatal("roamSessionExists on an absent marker must be false")
	}
}

// Review (NWP-20260904-08): handleDelete must feed deleteForSession the PARTIAL creds of a damaged marker.
// On the frankel shape (name+pass kept, uid lost) a mistyped confirm passphrase has to stay "wrongpass"
// (NOTFOUND, nothing happens) -- with empty login creds it would fall to "noop", reply OK, and reboot for a
// profile that survives, the DIA-20260616-50 guard broken on exactly the shape this slice is about.
func TestDeleteSessionCredsOnDamagedMarker(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "dana", "correct horse battery"
	createVault(base, name, pass)

	dest := t.TempDir()
	writeMarker(t, dest, name+"\n"+pass+"\n\n") // the frankel shape
	ln, lp, uid := deleteSessionCreds(dest)
	if ln != name || lp != pass || uid != "" {
		t.Fatalf("damaged marker creds: got (%q,%q,%q), want the partial name+pass and no uid", ln, lp, uid)
	}
	if got := deleteForSession(base, name, "wrong-pass", ln, lp, nil); got != "wrongpass" {
		t.Fatalf("damaged marker + wrong confirm: got %q, want \"wrongpass\"", got)
	}
	if getRef(base, headKey(base, name, pass)) == "" {
		t.Fatal("a wrong confirm on a damaged marker deleted the profile")
	}

	// A complete marker and an absent one behave as before.
	if err := markRoamSession(dest, name, pass, "11", ""); err != nil {
		t.Fatal(err)
	}
	if ln, lp, uid := deleteSessionCreds(dest); ln != name || lp != pass || uid != "11" {
		t.Fatalf("complete marker creds: got (%q,%q,%q)", ln, lp, uid)
	}
	os.Remove(filepath.Join(dest, ".roamsession"))
	if ln, lp, uid := deleteSessionCreds(dest); ln != "" || lp != "" || uid != "" {
		t.Fatalf("absent marker creds: got (%q,%q,%q), want none", ln, lp, uid)
	}
	if got := deleteForSession(base, name, "wrong-pass", "", "", nil); got != "noop" {
		t.Fatalf("no session creds + wrong confirm: got %q, want \"noop\"", got)
	}
}
