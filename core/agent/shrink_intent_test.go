package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Off-device (no NOWHERE_STATE) the whole mechanism must be INERT: no marker is written and the guard sees
// nothing, so host CLI + every existing test keep the pre-DIA-20260804-03 seal behaviour exactly.
func TestShrinkIntentInertWithoutStateDir(t *testing.T) {
	t.Setenv("NOWHERE_STATE", "")
	if got := shrinkIntentFile("deadbeef"); got != "" {
		t.Errorf("shrinkIntentFile off-device = %q, want \"\"", got)
	}
	markShrinkIntent("deadbeef") // must not panic, must not create anything
	if haveShrinkIntent("deadbeef") {
		t.Error("haveShrinkIntent must be false off-device")
	}
}

// An empty ref must never resolve to a path -- otherwise a caller with no session would mark the DIRECTORY
// itself and, worse, haveShrinkIntent("") would report true and disable the guard for an unkeyed scope.
func TestShrinkIntentRejectsEmptyRef(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	if got := shrinkIntentFile(""); got != "" {
		t.Errorf("shrinkIntentFile(\"\") = %q, want \"\"", got)
	}
	if haveShrinkIntent("") {
		t.Error("an empty ref must never look intentional")
	}
}

// The lifecycle the seal path depends on: mark -> the guard honours it -> the seal commits and clears it ->
// the guard is armed again. The clear step is what stops one deliberate deletion from disabling the shrink
// guard for the rest of the session.
func TestShrinkIntentMarkThenClear(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const ref = "abc123"
	if haveShrinkIntent(ref) {
		t.Fatal("fresh state dir must start with no intent")
	}
	markShrinkIntent(ref)
	if !haveShrinkIntent(ref) {
		t.Fatal("mark did not take")
	}
	clearShrinkIntent(ref)
	if haveShrinkIntent(ref) {
		t.Error("clear must re-arm the guard")
	}
	// Clearing a ref that was never marked is a normal path (every ordinary seal calls it) and must be a
	// silent no-op, not an error or a panic.
	clearShrinkIntent("never-marked")
}

// markProfileShrinkIntent must cover every scope a clearing action can shrink -- dropping an app from the
// keep-set removes its CE data, its DE data AND its captured APK bytes -- but must NOT touch #keys, whose
// kilobytes no clearing action targets and whose guard should stay armed.
func TestMarkProfileShrinkIntentCoversClearableScopes(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const profile, pass = "alice", "hunter2"
	markProfileShrinkIntent(profile, pass)

	for _, scope := range []string{profile, profile + "#de", profile + "#media", profile + "#apps"} {
		if !haveShrinkIntent(profileRefV2(scope, pass)) {
			t.Errorf("scope %q not marked -- its seal would be refused after a deliberate clear", scope)
		}
	}
	if haveShrinkIntent(profileRefV2(profile+"#keys", pass)) {
		t.Error("#keys must stay guarded: no clearing action targets it")
	}
	// A different profile's scopes must be untouched -- the marker is per-scope precisely so clearing one
	// profile cannot open a hole in another's seal.
	if haveShrinkIntent(profileRefV2("bob", pass)) {
		t.Error("another profile must not be marked")
	}
	// No session -> nothing marked at all.
	markProfileShrinkIntent("", pass)
	if _, err := os.Stat(shrinkIntentFile(profileRefV2("", pass))); err == nil {
		t.Error("an empty profile must not produce a marker")
	}
}

// NWP-20261021-15: EXPECT-SHRINK / EXPECT-SHRINK-INFERRED answer OK only when every marker they meant to write
// exists, and a failed call leaves every marker byte-identical to before it.

const esProfile, esPass = "alice", "hunter2"

func esScopes() []string {
	return []string{esProfile, esProfile + "#de", esProfile + "#media", esProfile + "#apps"}
}

func esMarker(scope string) string { return shrinkIntentFile(profileRefV2(scope, esPass)) }

// esSession returns a dest dir holding a complete .roamsession for the test profile.
func esSession(t *testing.T) string {
	t.Helper()
	dest := t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, roamSessionFile), []byte(esProfile+"\n"+esPass+"\n10\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return dest
}

// esReply drives a handler over a pipe and returns its reply line.
func esReply(t *testing.T, serve func(net.Conn)) string {
	t.Helper()
	cli, srv := net.Pipe()
	got := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(cli)
		got <- strings.TrimSpace(string(b))
	}()
	serve(srv)
	srv.Close()
	r := <-got
	cli.Close()
	return r
}

func esExpectShrink(t *testing.T, dest string) string {
	return esReply(t, func(c net.Conn) { handleExpectShrink(c, dest) })
}

func esInferred(t *testing.T, dest, payload string) string {
	return esReply(t, func(c net.Conn) {
		handleExpectShrinkInferred(c, bufio.NewReader(strings.NewReader(payload)), dest)
	})
}

// esStderr runs fn and returns what it wrote to stderr (dlog's sink): the login.log line a handler leaves.
func esStderr(t *testing.T, fn func()) string {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "stderr")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	orig := os.Stderr
	os.Stderr = f
	fn()
	os.Stderr = orig
	b, _ := os.ReadFile(f.Name())
	return string(b)
}

func esRead(t *testing.T, f string) string {
	t.Helper()
	b, err := os.ReadFile(f)
	if err != nil {
		t.Fatalf("read %s: %v", f, err)
	}
	return string(b)
}

func esExists(f string) bool { _, err := os.Lstat(f); return err == nil }

// (a) a writable state dir -> OK and four deliberate markers.
func TestExpectShrinkWritableAnswersOKAndMarksAllScopes(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	dest := esSession(t)
	if got := esExpectShrink(t, dest); got != "OK" {
		t.Fatalf("reply = %q, want OK", got)
	}
	for _, sc := range esScopes() {
		if got := esRead(t, esMarker(sc)); !strings.HasPrefix(got, "deliberate\n") || !strings.Contains(got, "\ngen=") {
			t.Errorf("scope %q marker = %q, want deliberate with its generation", sc, got)
		}
	}
}

// (b) shrink-intent is a regular file: nothing can be written -> ERR, no marker.
func TestExpectShrinkBlockedStateDirAnswersERR(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	if err := os.WriteFile(filepath.Join(st, "shrink-intent"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	var got string
	logged := esStderr(t, func() { got = esExpectShrink(t, esSession(t)) })
	if got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	if !strings.Contains(logged, "directory unavailable") || strings.Contains(logged, "directory busy") {
		t.Errorf("login.log line = %q, want the reason \"directory unavailable\"", logged)
	}
	for _, sc := range esScopes() {
		if esExists(esMarker(sc)) {
			t.Errorf("scope %q has a marker after a failed call", sc)
		}
	}
}

// (c) one middle scope's commit fails after the earlier scopes landed: ERR and the markers this call wrote
// elsewhere are taken back (the rollback is what removes them).
func TestExpectShrinkPartialFailureTakesBackWhatItWrote(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	failNthRename(t, 3) // bare and #de committed; #media fails
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	for _, sc := range []string{esProfile, esProfile + "#de", esProfile + "#media", esProfile + "#apps"} {
		if esExists(esMarker(sc)) {
			t.Errorf("scope %q keeps a marker this failed call wrote", sc)
		}
	}
	esNoStrays(t)
}

// (d) pre-existing markers survive a failed call byte-for-byte: an inferred #apps stays inferred, a deliberate
// #de stays deliberate.
func TestExpectShrinkFailureRestoresPreExistingMarkers(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const inferred = "inferred\np.one\n"
	apps, de := esMarker(esProfile+"#apps"), esMarker(esProfile+"#de")
	for f, body := range map[string]string{apps: inferred, de: "deliberate\n"} {
		if err := os.MkdirAll(filepath.Dir(f), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	failNthRename(t, 3) // bare and #de committed (#de over its deliberate marker); #media fails
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	if got := esRead(t, apps); got != inferred {
		t.Errorf("#apps marker = %q, want the inferred one untouched", got)
	}
	if got := esRead(t, de); got != "deliberate\n" {
		t.Errorf("#de marker = %q, want deliberate untouched", got)
	}
	if esExists(esMarker(esProfile)) {
		t.Error("the bare scope keeps a marker this failed call wrote")
	}
}

// (e) the inferred arm, driven through handleLogin so the verb dispatch is covered too.
func TestExpectShrinkInferred(t *testing.T) {
	login := func(dest string) string {
		cli, srv := net.Pipe()
		go cli.Write([]byte("EXPECT-SHRINK-INFERRED\np.one p.two\n"))
		got := make(chan string, 1)
		go func() { b, _ := io.ReadAll(cli); got <- strings.TrimSpace(string(b)) }()
		handleLogin(srv, dest)
		r := <-got
		cli.Close()
		return r
	}
	t.Run("blocked", func(t *testing.T) {
		st := t.TempDir()
		t.Setenv("NOWHERE_STATE", st)
		os.WriteFile(filepath.Join(st, "shrink-intent"), []byte("x"), 0o600)
		if got := login(esSession(t)); got != "ERR" {
			t.Fatalf("reply = %q, want ERR", got)
		}
		if esExists(esMarker(esProfile + "#apps")) {
			t.Error("#apps marker exists after a failed call")
		}
	})
	t.Run("keeps deliberate", func(t *testing.T) {
		t.Setenv("NOWHERE_STATE", t.TempDir())
		f := esMarker(esProfile + "#apps")
		if err := os.MkdirAll(filepath.Dir(f), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(f, []byte("deliberate\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		// The inferred marker commits, then the flag cannot be removed: the rollback restores the deliberate one.
		origDrop, failed := shrinkDrop, false
		shrinkDrop = func(n string) error {
			if strings.HasSuffix(n, shrinkTxnName) && !failed {
				failed = true
				return syscall.EIO
			}
			return origDrop(n)
		}
		t.Cleanup(func() { shrinkDrop = origDrop })
		if got := login(esSession(t)); got != "ERR" {
			t.Fatalf("reply = %q, want ERR", got)
		}
		if got := esRead(t, f); got != "deliberate\n" {
			t.Errorf("marker = %q, want deliberate restored", got)
		}
	})
	t.Run("writable", func(t *testing.T) {
		t.Setenv("NOWHERE_STATE", t.TempDir())
		if got := login(esSession(t)); got != "OK" {
			t.Fatalf("reply = %q, want OK", got)
		}
		if got := esRead(t, esMarker(esProfile+"#apps")); !strings.HasPrefix(got, "inferred\np.one\np.two\n") {
			t.Errorf("marker = %q, want inferred naming the packages", got)
		}
	})
}

// (f) off-device: inert, OK.
func TestExpectShrinkInertWithoutStateDirAnswersOK(t *testing.T) {
	t.Setenv("NOWHERE_STATE", "")
	if got := esExpectShrink(t, esSession(t)); got != "OK" {
		t.Fatalf("reply = %q, want OK", got)
	}
	if got := esInferred(t, esSession(t), "p.one\n"); got != "OK" {
		t.Fatalf("inferred reply = %q, want OK", got)
	}
}

// failNthWrite makes the nth staging write fail (a full tmpfs) and restores the seam after the test.
func failNthWrite(t *testing.T, n int) {
	t.Helper()
	orig, calls := shrinkWriteFile, 0
	shrinkWriteFile = func(name string, b []byte, m os.FileMode) error {
		calls++
		if calls == n {
			return syscall.ENOSPC
		}
		return orig(name, b, m)
	}
	t.Cleanup(func() { shrinkWriteFile = orig })
}

// failNthRename makes the nth commit rename fail and restores the seam after the test.
func failNthRename(t *testing.T, n int) {
	t.Helper()
	orig, calls := shrinkRename, 0
	shrinkRename = func(a, b string) error {
		calls++
		if calls == n {
			return syscall.EIO
		}
		return orig(a, b)
	}
	t.Cleanup(func() { shrinkRename = orig })
}

func esSeed(t *testing.T, scope, body string) string {
	t.Helper()
	f := esMarker(scope)
	if err := os.MkdirAll(filepath.Dir(f), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return f
}

func esNoStrays(t *testing.T) {
	t.Helper()
	ents, _ := os.ReadDir(filepath.Join(os.Getenv("NOWHERE_STATE"), "shrink-intent"))
	for _, e := range ents {
		if strings.HasSuffix(e.Name(), ".new") || strings.HasSuffix(e.Name(), ".old") || strings.HasSuffix(e.Name(), ".abs") {
			t.Errorf("stray staging file %s", e.Name())
		}
	}
}

// (c') a staging write fails (ENOSPC) part way through the four scopes: ERR, and existing markers are
// byte-identical (never truncated), absent ones stay absent.
func TestExpectShrinkStagingFailureLeavesMarkersByteIdentical(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const inferred = "inferred\np.one\n"
	apps := esSeed(t, esProfile+"#apps", inferred)
	de := esSeed(t, esProfile+"#de", "deliberate\n")
	// Writes: txn.new, bare .abs.new, bare .new, #de .old.new (fails)
	failNthWrite(t, 4)
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	if got := esRead(t, apps); got != inferred {
		t.Errorf("#apps = %q, want the inferred marker untouched", got)
	}
	if got := esRead(t, de); got != "deliberate\n" {
		t.Errorf("#de = %q, want untouched", got)
	}
	for _, sc := range []string{esProfile, esProfile + "#media"} {
		if esExists(esMarker(sc)) {
			t.Errorf("scope %q has a marker after a failed call", sc)
		}
	}
	esNoStrays(t)
}

// (c”) a commit rename fails after earlier scopes landed: they are put back, existing ones to their bytes.
func TestExpectShrinkCommitFailureTakesBackCommittedMarkers(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const inferred = "inferred\np.one\n"
	apps := esSeed(t, esProfile+"#apps", inferred)
	de := esSeed(t, esProfile+"#de", "deliberate\nold\n")
	failNthRename(t, 4) // bare, #de, #media committed; #apps fails
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	if got := esRead(t, apps); got != inferred {
		t.Errorf("#apps = %q, want the inferred marker untouched", got)
	}
	if got := esRead(t, de); got != "deliberate\nold\n" {
		t.Errorf("#de = %q, want its previous bytes", got)
	}
	for _, sc := range []string{esProfile, esProfile + "#media"} {
		if esExists(esMarker(sc)) {
			t.Errorf("scope %q keeps a marker this failed call wrote", sc)
		}
	}
	esNoStrays(t)
}

// (e') the inferred arm: a failing staging write leaves a pre-existing deliberate marker byte-identical.
func TestExpectShrinkInferredStagingFailureKeepsDeliberate(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	f := esSeed(t, esProfile+"#apps", "deliberate\n")
	failNthWrite(t, 2) // txn.new written; the marker's .old.new record fails
	if got := esInferred(t, esSession(t), "p.one\n"); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	if got := esRead(t, f); got != "deliberate\n" {
		t.Errorf("marker = %q, want deliberate untouched", got)
	}
	esNoStrays(t)
}

// An unreadable (non-absent) marker is a failed snapshot, not an absent one: it is neither overwritten nor removed.
func TestExpectShrinkUnsnapshottableMarkerIsNotTreatedAsAbsent(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	if err := os.MkdirAll(esMarker(esProfile+"#media"), 0o700); err != nil {
		t.Fatal(err)
	}
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	if fi, err := os.Lstat(esMarker(esProfile + "#media")); err != nil || !fi.IsDir() {
		t.Errorf("the squatting directory was disturbed: %v", err)
	}
}

// A commit rename fails AND every restoring rename fails too (persistent I/O error): the committed markers are
// still put back, by in-place rewrite or remove, so the call leaves every marker byte-identical.
func TestExpectShrinkRollbackSurvivesFailingRestoreRename(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const inferred = "inferred\np.one\n"
	apps := esSeed(t, esProfile+"#apps", inferred)
	de := esSeed(t, esProfile+"#de", "deliberate\nold\n")
	orig, calls := shrinkRename, 0
	shrinkRename = func(a, b string) error {
		calls++
		if calls == 4 || strings.HasSuffix(a, ".old") {
			return syscall.EIO
		}
		return orig(a, b)
	}
	t.Cleanup(func() { shrinkRename = orig })
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	if got := esRead(t, apps); got != inferred {
		t.Errorf("#apps = %q, want the inferred marker untouched", got)
	}
	if got := esRead(t, de); got != "deliberate\nold\n" {
		t.Errorf("#de = %q, want its previous bytes", got)
	}
	for _, sc := range []string{esProfile, esProfile + "#media"} {
		if esExists(esMarker(sc)) {
			t.Errorf("scope %q keeps a marker this failed call wrote", sc)
		}
	}
	esNoStrays(t)
}

// A restore step that fails transiently is retried: the committed markers still end byte-identical.
func TestExpectShrinkRestoreRetriesTransientFailure(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	de := esSeed(t, esProfile+"#de", "deliberate\nold\n")
	origRn, origRw, origRm := shrinkRename, shrinkRewrite, shrinkRemove
	t.Cleanup(func() { shrinkRename, shrinkRewrite, shrinkRemove = origRn, origRw, origRm })
	calls, rmFails, rwFails := 0, 0, 0
	shrinkRename = func(a, b string) error {
		calls++
		if calls == 4 || strings.HasSuffix(a, ".old") {
			return syscall.EIO
		}
		return origRn(a, b)
	}
	shrinkRewrite = func(n string, b []byte, m os.FileMode) error {
		if rwFails++; rwFails == 1 {
			return syscall.EIO
		}
		return origRw(n, b, m)
	}
	shrinkRemove = func(n string) error {
		if strings.HasSuffix(n, ".new") || strings.HasSuffix(n, ".old") {
			return origRm(n)
		}
		if rmFails++; rmFails == 1 {
			return syscall.EIO
		}
		return origRm(n)
	}
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	if got := esRead(t, de); got != "deliberate\nold\n" {
		t.Errorf("#de = %q, want its previous bytes", got)
	}
	for _, sc := range []string{esProfile, esProfile + "#media"} {
		if esExists(esMarker(sc)) {
			t.Errorf("scope %q keeps a marker this failed call wrote", sc)
		}
	}
	esNoStrays(t)
}

// esPersistentFailure makes the filesystem refuse every way back for the live markers: the 4th commit rename
// (so the first three markers are committed and then must be taken back), every restoring rename, every
// staged rewrite, and every remove of a live marker. The returned func heals it.
func esPersistentFailure(t *testing.T) (heal func()) {
	t.Helper()
	origRn, origRw, origRm := shrinkRename, shrinkRewrite, shrinkRemove
	heal = func() { shrinkRename, shrinkRewrite, shrinkRemove = origRn, origRw, origRm }
	t.Cleanup(heal)
	calls := 0
	shrinkRename = func(a, b string) error {
		calls++
		if calls == 4 || strings.HasSuffix(a, ".old") {
			return syscall.EIO
		}
		return origRn(a, b)
	}
	shrinkRewrite = func(string, []byte, os.FileMode) error { return syscall.EIO }
	shrinkRemove = func(n string) error { return syscall.EIO }
	return heal
}

// esAllowed asks the guard what the seal path asks (main.go: haveShrinkIntent, then shrinkIntentProvenance and
// shrinkIntentAllowed) about a shrink that removed p.one AND p.two. A deliberate marker allows it; an inferred
// one names no p.two, so it does not.
func esAllowed(scope string) bool {
	ref := profileRefV2(scope, esPass)
	if !haveShrinkIntent(ref) {
		return false
	}
	kind, declared := shrinkIntentProvenance(ref)
	old := map[string]int64{"p.one": 10, "p.two": 10, "p.keep": 10}
	nw := map[string]int64{"p.keep": 10}
	ok, _ := shrinkIntentAllowed(kind, declared, old, nw, nil)
	return ok
}

// The filesystem refuses the restoring rename, the in-place rewrite AND the remove for the whole rollback:
// nothing can put the live markers back, so the call answers ERR and keeps the recovery record of every marker
// it changed -- and the guard's DECISION is the acceptance criterion: no scope gains authority (#media, which
// held none, included), and the inferred #apps marker, never committed, still vouches only for its package.
func TestExpectShrinkPersistentRollbackFailureGrantsNoAuthority(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const inferred = "inferred\np.one\n"
	apps := esSeed(t, esProfile+"#apps", inferred)
	bare := esSeed(t, esProfile, "deliberate\nbare\n")
	de := esSeed(t, esProfile+"#de", "deliberate\nold\n")
	media := esMarker(esProfile + "#media")
	esPersistentFailure(t)
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	if got := esRead(t, bare+".old"); got != "deliberate\nbare\n" {
		t.Errorf("bare record = %q, want its previous bytes kept", got)
	}
	if got := esRead(t, de+".old"); got != "deliberate\nold\n" {
		t.Errorf("#de record = %q, want its previous bytes kept", got)
	}
	if !esExists(media + ".abs") {
		t.Error("#media (absent before) lost its record")
	}
	for _, sc := range []string{esProfile, esProfile + "#de", esProfile + "#media"} {
		if haveShrinkIntent(profileRefV2(sc, esPass)) {
			t.Errorf("scope %q: haveShrinkIntent trusts a marker whose rollback is unfinished", sc)
		}
		if esAllowed(sc) {
			t.Errorf("scope %q: the guard allows a shrink the failed call did not authorize", sc)
		}
		if k, _ := shrinkIntentProvenance(profileRefV2(sc, esPass)); k == "deliberate" {
			t.Errorf("scope %q reads as deliberate intent after ERR", sc)
		}
	}
	if got := esRead(t, apps); got != inferred {
		t.Errorf("#apps = %q, want the inferred marker untouched", got)
	}
	// The inferred marker still vouches for p.one only: p.one+p.two vanishing is refused, p.one alone is not.
	ref := profileRefV2(esProfile+"#apps", esPass)
	kind, declared := shrinkIntentProvenance(ref)
	if kind != "inferred" || len(declared) != 1 || declared[0] != "p.one" {
		t.Fatalf("#apps provenance = %q %v, want inferred [p.one]", kind, declared)
	}
	if ok, _ := shrinkIntentAllowed(kind, declared, map[string]int64{"p.one": 1, "p.two": 1, "p.k": 1}, map[string]int64{"p.k": 1}, nil); ok {
		t.Error("the inferred marker now allows a package it never named")
	}
	if ok, _ := shrinkIntentAllowed(kind, declared, map[string]int64{"p.one": 1, "p.k": 1}, map[string]int64{"p.k": 1}, nil); !ok {
		t.Error("the inferred marker stopped vouching for its own package")
	}
}

// A recoverable failure restores the previous bytes, and the guard then sees exactly what it saw before: a
// marker that was absent stays absent and allows nothing; the deliberate one still does.
func TestExpectShrinkRecoverableFailureGuardDecisionUnchanged(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	esSeed(t, esProfile+"#de", "deliberate\n")
	failNthRename(t, 3) // bare and #de were committed; #media fails
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	if !esAllowed(esProfile + "#de") {
		t.Error("the pre-existing deliberate #de marker no longer authorizes")
	}
	for _, sc := range []string{esProfile, esProfile + "#media", esProfile + "#apps"} {
		if esAllowed(sc) || haveShrinkIntent(profileRefV2(sc, esPass)) {
			t.Errorf("scope %q gained authority from a failed call", sc)
		}
	}
	esNoStrays(t)
}

// (h) The daemon restarts while the filesystem is still refusing: the startup pass cannot finish the
// transaction, so every marker stays non-authorizing; a repeated request is refused without overwriting the
// records. Once the filesystem heals, the pass ENDS every marker absent -- the previous body is not restored, the
// cost the backlog row names -- and a repeated EXPECT-SHRINK behaves as on a clean state.
func TestExpectShrinkPersistentFailureAcrossRestartAndRepeat(t *testing.T) {
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	bare := esSeed(t, esProfile, "deliberate\nbare\n")
	media := esMarker(esProfile + "#media")
	heal := esPersistentFailure(t)
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	// restart, filesystem still broken
	if n := recoverShrinkMarkers(state); n != 3 {
		t.Errorf("startup pass left %d unfinished, want 3 (bare, #de, #media)", n)
	}
	for _, sc := range esScopes() {
		if esAllowed(sc) {
			t.Errorf("scope %q authorizes while its transaction is unfinished", sc)
		}
	}
	// a repeated request must not clobber the records with the live (new) bytes
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("repeated reply = %q, want ERR", got)
	}
	if got := esRead(t, bare+".old"); got != "deliberate\nbare\n" {
		t.Errorf("repeat overwrote the record: %q", got)
	}
	// the filesystem heals; the next restart ends the transaction
	heal()
	if n := recoverShrinkMarkers(state); n != 0 {
		t.Fatalf("startup pass left %d unfinished on a healthy filesystem", n)
	}
	if esExists(bare) || esAllowed(esProfile) {
		t.Errorf("bare survives the start pass as %q: a restart cannot tell it from a spent token (RF-010)", esRead(t, bare))
	}
	if esExists(media) {
		t.Error("#media (absent before) is back after recovery")
	}
	esNoStrays(t)
	// and a repeated request now behaves as on a clean state
	if got := esExpectShrink(t, esSession(t)); got != "OK" {
		t.Fatalf("reply after recovery = %q, want OK", got)
	}
	for _, sc := range esScopes() {
		if !esAllowed(sc) {
			t.Errorf("scope %q not armed after a clean EXPECT-SHRINK", sc)
		}
	}
}

// A repeated request that meets an unfinished transaction on a healed filesystem recovers it first, then writes.
func TestExpectShrinkRepeatRecoversUnfinishedTransaction(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	esSeed(t, esProfile, "deliberate\nbare\n")
	heal := esPersistentFailure(t)
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	heal()
	if got := esExpectShrink(t, esSession(t)); got != "OK" {
		t.Fatalf("reply = %q, want OK", got)
	}
	esNoStrays(t)
	if !esAllowed(esProfile + "#media") {
		t.Error("#media not armed")
	}
}

// A seal that commits consumes the intent: its recovery records go with the marker, so a later recovery
// cannot bring a consumed marker back.
func TestClearShrinkIntentDropsRecords(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	ref := profileRefV2(esProfile, esPass)
	f := esSeed(t, esProfile, "deliberate\n")
	os.WriteFile(f+".old", []byte("deliberate\n"), 0o600)
	clearShrinkIntent(ref)
	if esExists(f) || esExists(f+".old") {
		t.Error("clearShrinkIntent left the marker or its record")
	}
	if n := recoverShrinkMarkers(os.Getenv("NOWHERE_STATE")); n != 0 || esExists(f) {
		t.Errorf("recovery resurrected a consumed marker (left %d)", n)
	}
}

// RF-001: the forward renames all land and then the filesystem refuses to remove the recovery records. The
// transaction is not finished, so the call must not answer OK (the chooser would change the keep-set while the
// leftover records make the markers non-authorizing): it rolls back, answers ERR, and a scope that held no marker
// before authorizes nothing -- by the guard's actual decision -- until recovery has cleared its record.
func TestExpectShrinkRecordRemovalFailureAnswersERR(t *testing.T) {
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	bare := esSeed(t, esProfile, "deliberate\nbare\n")
	orig := shrinkDrop
	shrinkDrop = func(n string) error { // refuses only a record that exists, so the snapshot step still passes
		if _, err := os.Lstat(n); err != nil {
			return orig(n)
		}
		return syscall.EIO
	}
	healed := false
	heal := func() {
		if !healed {
			shrinkDrop, healed = orig, true
		}
	}
	t.Cleanup(heal)
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	if got := esRead(t, bare); got != "deliberate\nbare\n" {
		t.Errorf("bare = %q, want its previous bytes back", got)
	}
	for _, sc := range []string{esProfile + "#de", esProfile + "#media", esProfile + "#apps"} {
		if esAllowed(sc) || haveShrinkIntent(profileRefV2(sc, esPass)) {
			t.Errorf("scope %q authorizes after a call that answered ERR", sc)
		}
	}
	heal()
	if n := recoverShrinkMarkers(state); n != 0 {
		t.Fatalf("startup pass left %d unfinished on a healthy filesystem", n)
	}
	for _, sc := range []string{esProfile + "#de", esProfile + "#media", esProfile + "#apps"} {
		if esExists(esMarker(sc)) {
			t.Errorf("scope %q has a marker the failed call wrote", sc)
		}
	}
	esNoStrays(t)
}

// RF-002: the daemon dies part way through writing a recovery record. The record is published by rename, so the
// short body is only ever a .new side file, which the startup pass removes: the inferred marker is neither
// replaced by a truncated body (which would read as deliberate) nor upgraded.
func TestExpectShrinkCrashWritingRecoveryRecordKeepsInferred(t *testing.T) {
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	const inferred = "inferred\np.one\n"
	apps := esSeed(t, esProfile+"#apps", inferred)
	ref := profileRefV2(esProfile+"#apps", esPass)
	orig := shrinkWriteFile
	shrinkWriteFile = func(name string, b []byte, m os.FileMode) error {
		if strings.Contains(name, ".old") {
			orig(name, b[:5], m)
			panic("daemon killed")
		}
		return orig(name, b, m)
	}
	t.Cleanup(func() { shrinkWriteFile = orig })
	func() {
		defer func() { recover() }()
		markShrinkIntent(ref)
	}()
	shrinkWriteFile = orig
	recoverShrinkMarkers(state)
	if got := esRead(t, apps); got != inferred {
		t.Errorf("#apps = %q, want the inferred marker untouched", got)
	}
	kind, declared := shrinkIntentProvenance(ref)
	if kind != "inferred" || len(declared) != 1 || declared[0] != "p.one" {
		t.Errorf("provenance after restart = %q %v, want inferred [p.one]", kind, declared)
	}
	esNoStrays(t)
}

// RF-003: every forward rename lands, the transaction's flag cannot be removed, and nothing can put the markers
// back. Records of the markers are never retired before the flag, so the bare marker (inferred before) cannot
// read as deliberate, and no absent scope authorizes, through the ERR, a repeated request and a restart; once the
// filesystem heals the startup pass ends every marker absent (nothing is restored).
func TestExpectShrinkFlagRemovalAndRollbackFailureGrantsNoAuthority(t *testing.T) {
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	const inferred = "inferred\np.one\n"
	bare := esSeed(t, esProfile, inferred)
	origDrop, origRn, origRw, origRm := shrinkDrop, shrinkRename, shrinkRewrite, shrinkRemove
	heal := func() { shrinkDrop, shrinkRename, shrinkRewrite, shrinkRemove = origDrop, origRn, origRw, origRm }
	t.Cleanup(heal)
	shrinkDrop = func(n string) error {
		if strings.HasSuffix(n, shrinkTxnName) {
			return syscall.EIO
		}
		return origDrop(n)
	}
	shrinkRename = func(a, b string) error {
		if strings.HasSuffix(a, ".old") {
			return syscall.EIO
		}
		return origRn(a, b)
	}
	shrinkRewrite = func(string, []byte, os.FileMode) error { return syscall.EIO }
	shrinkRemove = func(string) error { return syscall.EIO }
	check := func(when string) {
		t.Helper()
		if k, _ := shrinkIntentProvenance(profileRefV2(esProfile, esPass)); k == "deliberate" {
			t.Errorf("%s: the inferred bare marker reads as deliberate", when)
		}
		for _, sc := range []string{esProfile, esProfile + "#de", esProfile + "#media", esProfile + "#apps"} {
			if esAllowed(sc) {
				t.Errorf("%s: scope %q allows a shrink after ERR", when, sc)
			}
		}
	}
	for i := 0; i < 2; i++ {
		if got := esExpectShrink(t, esSession(t)); got != "ERR" {
			t.Fatalf("request %d: reply = %q, want ERR", i, got)
		}
		check("after ERR")
	}
	if n := recoverShrinkMarkers(state); n == 0 {
		t.Fatal("the startup pass claims a finished transaction on a refusing filesystem")
	}
	check("after a restart")
	heal()
	if n := recoverShrinkMarkers(state); n != 0 {
		t.Fatalf("startup pass left %d unfinished on a healthy filesystem", n)
	}
	// the start pass never restores a previous body as authority (RF-010): the marker is gone, not replayed
	if esExists(bare) || esAllowed(esProfile) {
		t.Errorf("bare survives the start pass as %q", esRead(t, bare))
	}
	for _, sc := range []string{esProfile + "#de", esProfile + "#media", esProfile + "#apps"} {
		if esExists(esMarker(sc)) {
			t.Errorf("scope %q has a marker the failed call wrote", sc)
		}
	}
	esNoStrays(t)
}

// RF-006: a seal consumes (clearShrinkIntent) a marker while an EXPECT call that snapshotted it is mid-flight, and
// the call then fails. The rollback must not put the consumed authority back: the clear waits for the transaction
// and then removes whatever the marker holds once it has settled.
func TestExpectShrinkRollbackDoesNotResurrectConsumedIntent(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	ref := profileRefV2(esProfile, esPass)
	f := esSeed(t, esProfile, "deliberate\n")
	orig, calls := shrinkRename, 0
	done := make(chan struct{})
	shrinkRename = func(a, b string) error {
		calls++
		if calls == 2 { // the bare scope has been committed over the old marker; the next target fails
			go func() { clearShrinkIntent(ref); close(done) }()
			time.Sleep(150 * time.Millisecond) // long enough for an unserialized clear to run
			return syscall.EIO
		}
		return orig(a, b)
	}
	t.Cleanup(func() { shrinkRename = orig })
	if err := markProfileShrinkIntent(esProfile, esPass); err == nil {
		t.Fatal("markProfileShrinkIntent answered nil although its rename failed")
	}
	<-done
	if haveShrinkIntent(ref) || esExists(f) {
		t.Error("a failed EXPECT resurrected a marker a concurrent seal had consumed")
	}
}

// RF-007: a seal authorizes against the marker it saw, then a NEWER successful EXPECT commits and answers OK (the
// chooser's drop follows it); the older seal's commit-time clear must not consume the fresh marker.
func TestSealClearDoesNotConsumeNewerExpectMarker(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	ref := profileRefV2(esProfile, esPass)
	if err := markProfileShrinkIntent(esProfile, esPass); err != nil {
		t.Fatal(err)
	}
	seen := readShrinkIntent(ref) // the seal's guard read: authorized
	if !seen.armed {
		t.Fatal("the seed marker does not authorize")
	}
	if err := markProfileShrinkIntent(esProfile, esPass); err != nil { // a newer EXPECT, OK
		t.Fatal(err)
	}
	clearShrinkIntentGen(ref, seen.token, true) // the older seal commits
	if !haveShrinkIntent(ref) {
		t.Error("an older seal's clear consumed the intent a newer EXPECT-SHRINK committed")
	}
	clearShrinkIntentGen(ref, readShrinkIntent(ref).token, true) // a seal that did use this generation consumes it
	if haveShrinkIntent(ref) {
		t.Error("a seal's clear of the generation it used left the marker")
	}
}

// ---- the seal is another PROCESS ------------------------------------------------------------------------
//
// roamd runs every seal as its own `agent push`; the login daemon's memory is invisible to it. These tests run the
// seal side in a child (this test binary re-executed with NWP_SHRINK_CHILD) so only the state directory is shared.

// TestShrinkIntentChildHelper is the child's body; it does nothing in a normal run.
//
//	clear: note "started", then clear the marker unconditionally (the seal's clear without a generation)
//	read:  report whether the marker authorizes
//	seal:  read the marker, publish its token, wait for "go", then clear only that token
func TestShrinkIntentChildHelper(t *testing.T) {
	mode := os.Getenv("NWP_SHRINK_CHILD")
	if mode == "" {
		return
	}
	if os.Getenv("NWP_SHRINK_SHORT_WAIT") != "" {
		shrinkLockWait = 300 * time.Millisecond
	}
	ref, sig := os.Getenv("NWP_SHRINK_REF"), os.Getenv("NWP_SHRINK_SIG")
	touch := func(name, body string) {
		if err := os.WriteFile(filepath.Join(sig, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	switch mode {
	case "clear":
		touch("started", "")
		clearShrinkIntent(ref)
	case "read":
		touch("armed", fmt.Sprint(readShrinkIntent(ref).armed))
	case "sealclear":
		// The seal's commit-time clear of a token it read earlier (the token comes from a file: bodies hold newlines),
		// with the filesystem faulted as NWP_SHRINK_FAULT says.
		tok, err := os.ReadFile(filepath.Join(sig, "tokin"))
		if err != nil {
			t.Fatal(err)
		}
		esChildFault(sig, os.Getenv("NWP_SHRINK_FAULT"))
		clearShrinkIntentGen(ref, string(tok), true)
	case "seal":
		in := readShrinkIntent(ref)
		touch("tok", in.token)
		if !esWaitFile(filepath.Join(sig, "go")) {
			t.Fatal("no go")
		}
		clearShrinkIntentGen(ref, in.token, true)
	}
}

// esChildFault faults the child's filesystem seams: "persist" refuses every rename, rewrite and remove (drops work);
// "killdrop" lets a record drop land and then hangs, so the parent kills the child right after it; "killremove" hangs
// BEFORE a live marker is removed. The hang is signalled by a file in sig.
func esChildFault(sig, fault string) {
	hang := func(name string) {
		os.WriteFile(filepath.Join(sig, name), nil, 0o600)
		select {}
	}
	switch fault {
	case "persist":
		shrinkRename = func(string, string) error { return syscall.EIO }
		shrinkRewrite = func(string, []byte, os.FileMode) error { return syscall.EIO }
		shrinkRemove = func(string) error { return syscall.EIO }
	case "killdrop":
		od := shrinkDrop
		shrinkDrop = func(n string) error {
			err := od(n)
			if err == nil && (strings.HasSuffix(n, shrinkOldSuffix) || strings.HasSuffix(n, shrinkAbsSuffix)) {
				hang("dropped")
			}
			return err
		}
	case "killremove":
		shrinkRemove = func(string) error { hang("removing"); return nil }
	}
}

func esWaitFile(f string) bool {
	for i := 0; i < 1000; i++ {
		if esExists(f) {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return false
}

func esChild(t *testing.T, mode, ref, sig string, env ...string) *exec.Cmd {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(exe, "-test.run=^TestShrinkIntentChildHelper$", "-test.count=1", "-test.testlogfile=")
	cmd.Env = append(os.Environ(), append([]string{"NWP_SHRINK_CHILD=" + mode, "NWP_SHRINK_REF=" + ref, "NWP_SHRINK_SIG=" + sig, "GOTMPDIR=" + sig}, env...)...)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	return cmd
}

// A seal in another process waits for a marker transaction: its clear lands after the lock is released, not while
// the transaction is open.
func TestShrinkIntentLockExcludesSealProcess(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	sig := t.TempDir()
	ref := profileRefV2(esProfile, esPass)
	f := esSeed(t, esProfile, "deliberate\n")
	unlock, err := lockShrinkDir(filepath.Dir(f), true)
	if err != nil {
		t.Fatal(err)
	}
	cmd := esChild(t, "clear", ref, sig)
	if !esWaitFile(filepath.Join(sig, "started")) {
		t.Fatal("child never started")
	}
	time.Sleep(200 * time.Millisecond)
	if !esExists(f) {
		t.Error("another process cleared the marker while a transaction held the lock")
	}
	unlock()
	if err := cmd.Wait(); err != nil {
		t.Fatalf("child: %v", err)
	}
	if esExists(f) {
		t.Error("the seal's clear never ran after the lock was released")
	}
}

// RF-006 across processes: a seal in another process consumes the marker while this process's EXPECT-SHRINK is
// mid-transaction, and the transaction then fails. The seal's clear waits; the marker it finally consumes is the
// settled one, so the rollback cannot put spent authority back.
func TestExpectShrinkRollbackDoesNotResurrectIntentConsumedByAnotherProcess(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	sig := t.TempDir()
	ref := profileRefV2(esProfile, esPass)
	f := esSeed(t, esProfile, "deliberate\n")
	orig, calls := shrinkRename, 0
	var cmd *exec.Cmd
	shrinkRename = func(a, b string) error {
		calls++
		if calls == 2 { // bare committed over the old marker; the next target fails
			cmd = esChild(t, "clear", ref, sig)
			esWaitFile(filepath.Join(sig, "started"))
			time.Sleep(200 * time.Millisecond) // long enough for an unlocked clear to run
			return syscall.EIO
		}
		return orig(a, b)
	}
	t.Cleanup(func() { shrinkRename = orig })
	if err := markProfileShrinkIntent(esProfile, esPass); err == nil {
		t.Fatal("markProfileShrinkIntent answered nil although its rename failed")
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("child: %v", err)
	}
	if esExists(f) || haveShrinkIntent(ref) {
		t.Error("a failed EXPECT resurrected a marker another process had consumed")
	}
}

// RF-007 across processes: the seal authorizes against the marker it read, a newer EXPECT-SHRINK commits, and the
// seal's clear (in its own process, with no memory of the daemon) must leave the newer marker.
func TestSealProcessClearDoesNotConsumeNewerExpectMarker(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	sig := t.TempDir()
	ref := profileRefV2(esProfile, esPass)
	if got := esExpectShrink(t, esSession(t)); got != "OK" {
		t.Fatalf("reply = %q, want OK", got)
	}
	cmd := esChild(t, "seal", ref, sig)
	if !esWaitFile(filepath.Join(sig, "tok")) {
		t.Fatal("the seal never read the marker")
	}
	if got := esExpectShrink(t, esSession(t)); got != "OK" { // a newer EXPECT; the chooser's drop follows
		t.Fatalf("reply = %q, want OK", got)
	}
	os.WriteFile(filepath.Join(sig, "go"), nil, 0o600)
	if err := cmd.Wait(); err != nil {
		t.Fatalf("child: %v", err)
	}
	if !haveShrinkIntent(ref) {
		t.Error("an older seal in another process consumed the intent a newer EXPECT-SHRINK committed")
	}
}

// A lock that cannot be had within the bound FAILS CLOSED: the seal's read reports no authority and its clear
// leaves the marker for the next seal.
func TestShrinkIntentLockTimeoutFailsClosed(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	sig := t.TempDir()
	ref := profileRefV2(esProfile, esPass)
	f := esSeed(t, esProfile, "deliberate\n")
	unlock, err := lockShrinkDir(filepath.Dir(f), true)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	if err := esChild(t, "read", ref, sig, "NWP_SHRINK_SHORT_WAIT=1").Wait(); err != nil {
		t.Fatalf("read child: %v", err)
	}
	if got := esRead(t, filepath.Join(sig, "armed")); got != "false" {
		t.Errorf("a reader that could not take the lock reported armed=%s", got)
	}
	if err := esChild(t, "clear", ref, sig, "NWP_SHRINK_SHORT_WAIT=1").Wait(); err != nil {
		t.Fatalf("clear child: %v", err)
	}
	if !esExists(f) {
		t.Error("a clear that could not take the lock removed the marker anyway")
	}
}

// A transaction that cannot take the lock answers ERR and touches nothing.
func TestExpectShrinkLockTimeoutAnswersERR(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	f := esSeed(t, esProfile, "deliberate\nbare\n")
	unlock, err := lockShrinkDir(filepath.Dir(f), true)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	orig := shrinkLockWait
	shrinkLockWait = 100 * time.Millisecond
	t.Cleanup(func() { shrinkLockWait = orig })
	var got string
	logged := esStderr(t, func() { got = esExpectShrink(t, esSession(t)) })
	if got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	if !strings.Contains(logged, "directory busy") || strings.Contains(logged, "directory unavailable") {
		t.Errorf("login.log line = %q, want the reason \"directory busy\"", logged)
	}
	if got := esRead(t, f); got != "deliberate\nbare\n" {
		t.Errorf("marker = %q, want untouched", got)
	}
}

// P1 #3: after a persistent failure of the four-scope call, a later call on OTHER targets (the logoff's
// EXPECT-SHRINK-INFERRED on #apps, or another profile's EXPECT-SHRINK) must not remove the flag and un-block the
// markers the failed call changed: it answers ERR, and bare, #de and #media still authorize nothing.
func TestExpectShrinkLaterCallCannotUnblockEarlierFailure(t *testing.T) {
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	heal := esPersistentFailure(t)
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	check := func(when string) {
		t.Helper()
		for _, sc := range []string{esProfile, esProfile + "#de", esProfile + "#media"} {
			if esAllowed(sc) || haveShrinkIntent(profileRefV2(sc, esPass)) {
				t.Errorf("%s: scope %q authorizes a shrink only an ERR-answered call wrote", when, sc)
			}
		}
	}
	if got := esInferred(t, esSession(t), "p.one\n"); got != "ERR" {
		t.Errorf("inferred call over an unrecovered transaction = %q, want ERR", got)
	}
	check("after an inferred-only call")
	other := t.TempDir()
	os.WriteFile(filepath.Join(other, roamSessionFile), []byte("bob\nswordfish\n11\n"), 0o600)
	if got := esExpectShrink(t, other); got != "ERR" {
		t.Errorf("another profile's call over an unrecovered transaction = %q, want ERR", got)
	}
	check("after another profile's call")
	heal()
	if n := recoverShrinkMarkers(state); n != 0 {
		t.Fatalf("recovery left %d unfinished on a healthy filesystem", n)
	}
	check("after recovery")
}

// P2 #4: a marker that exists but cannot be read is no authority (it used to read as "deliberate").
func TestShrinkIntentUnreadableMarkerIsNoAuthority(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	ref := profileRefV2(esProfile, esPass)
	f := esMarker(esProfile)
	if err := os.MkdirAll(f, 0o700); err != nil { // stat succeeds, read fails
		t.Fatal(err)
	}
	if haveShrinkIntent(ref) {
		t.Error("an unreadable marker authorizes")
	}
	if k, _ := shrinkIntentProvenance(ref); k == "deliberate" {
		t.Error("an unreadable marker reads as deliberate")
	}
}

// P7: a record that survives a failed unlink is not replayed by a later transaction. A stale <marker>.old beside a
// scope that holds no marker would be preferred over the new .abs by recovery and rebuild a marker; the call
// refuses to start while it cannot drop the stale record.
func TestExpectShrinkStaleRecordIsNotReplayed(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	esSeed(t, esProfile, "deliberate\nbare\n")
	media := esMarker(esProfile + "#media")
	if err := os.WriteFile(media+".old", []byte("deliberate\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	orig := shrinkDrop
	shrinkDrop = func(n string) error {
		if n == media+".old" {
			return syscall.EIO
		}
		return orig(n)
	}
	t.Cleanup(func() { shrinkDrop = orig })
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	if esExists(filepath.Join(filepath.Dir(media), shrinkTxnName)) {
		t.Error("a transaction was published over a stale record")
	}
	shrinkDrop = orig
	// healed: the stale record is dropped. The next call fails with no way back (esPersistentFailure), the filesystem
	// heals and recovery runs: the stale body must not have become a live #media marker.
	heal := esPersistentFailure(t)
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	heal()
	if n := recoverShrinkMarkers(os.Getenv("NOWHERE_STATE")); n != 0 {
		t.Fatalf("recovery left %d unfinished on a healthy filesystem", n)
	}
	if esExists(media) || esExists(media+".old") || esAllowed(esProfile+"#media") {
		t.Error("a stale record became a live marker, or survived recovery")
	}
}

// A stale record of ANOTHER scope or profile (not one of the next call's targets) that cannot be dropped must stop
// the next transaction too: otherwise the directory-wide flag it publishes gives that record a transaction to be
// replayed in, and recovery would recreate intent a seal already consumed.
func TestExpectShrinkStaleRecordOfAnotherProfileBlocksTransaction(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	other := profileRefV2("other-profile", esPass)
	otherMarker := shrinkIntentFile(other)
	if err := os.MkdirAll(filepath.Dir(otherMarker), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(otherMarker+".old", []byte("deliberate\n"), 0o600); err != nil { // consumed intent's stale record
		t.Fatal(err)
	}
	orig := shrinkDrop
	shrinkDrop = func(n string) error {
		if n == otherMarker+".old" {
			return syscall.EIO
		}
		return orig(n)
	}
	t.Cleanup(func() { shrinkDrop = orig })
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR while another scope's stale record cannot be dropped", got)
	}
	if esExists(filepath.Join(filepath.Dir(otherMarker), shrinkTxnName)) {
		t.Error("a transaction was published over another profile's stale record")
	}
	if n := recoverShrinkMarkers(os.Getenv("NOWHERE_STATE")); n == 0 {
		t.Error("the startup pass reported a stale record it could not drop as finished")
	}
	shrinkDrop = orig
	// healed: the record goes. The next call fails with no way back, the filesystem heals and recovery runs: the
	// other profile's stale body must not have become a live marker.
	heal := esPersistentFailure(t)
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Fatalf("reply = %q, want ERR", got)
	}
	heal()
	if n := recoverShrinkMarkers(os.Getenv("NOWHERE_STATE")); n != 0 {
		t.Fatalf("recovery left %d unfinished on a healthy filesystem", n)
	}
	if esExists(otherMarker) || esExists(otherMarker+".old") || haveShrinkIntent(other) {
		t.Error("another profile's stale record became a live marker, or survived recovery")
	}
}

// A seal's clear whose recovery record cannot be dropped still consumes the marker: the guard's verdict afterwards
// grants nothing, and the stale record blocks the next transaction instead of being replayed.
func TestSealClearConsumesMarkerWhenRecordCannotBeDropped(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	ref := profileRefV2(esProfile+"#media", esPass)
	f := esSeed(t, esProfile+"#media", "deliberate\n")
	if err := os.WriteFile(f+".old", []byte("deliberate\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	orig := shrinkDrop
	shrinkDrop = func(n string) error {
		if n == f+".old" {
			return syscall.EIO
		}
		return orig(n)
	}
	t.Cleanup(func() { shrinkDrop = orig })
	if !haveShrinkIntent(ref) {
		t.Fatal("setup: the marker should be armed before the clear")
	}
	clearShrinkIntent(ref)
	if haveShrinkIntent(ref) {
		t.Error("the guard still sees armed intent after the seal consumed it")
	}
	if kind, _ := shrinkIntentProvenance(ref); kind != "inferred" {
		t.Errorf("provenance %q after the clear: a consumed marker must carry no user authority", kind)
	}
	if n := recoverShrinkDir(filepath.Dir(f)); n == 0 {
		t.Error("the stale record that could not be dropped was reported as finished")
	}
}

// A spent marker that can neither have its record dropped nor be removed is overwritten with a tombstone.
func TestSealClearTombstonesMarkerThatCannotBeRemoved(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	ref := profileRefV2(esProfile+"#media", esPass)
	f := esSeed(t, esProfile+"#media", "deliberate\n")
	if err := os.WriteFile(f+".old", []byte("deliberate\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	origDrop, origRemove := shrinkDrop, shrinkRemove
	shrinkDrop = func(n string) error { return syscall.EIO }
	shrinkRemove = func(n string) error { return syscall.EIO }
	t.Cleanup(func() { shrinkDrop, shrinkRemove = origDrop, origRemove })
	clearShrinkIntent(ref)
	if haveShrinkIntent(ref) {
		t.Error("a spent marker that could not be removed still authorizes a shrink")
	}
}

// ---- a record that holds the spent token (RF: spent authority replayed by recovery) ------------------------
//
// A persistently failed EXPECT-SHRINK leaves <marker>.old holding the body the marker had before: the very token a
// seal in flight authorized against. The seal's clear must neutralise that record too, or recovery (daemon start,
// or a later call) writes the spent authority back.

// ---- a directory that cannot be listed is not a clean one ----------------------------------------------

func TestUnlistableIntentDirIsNeverClean(t *testing.T) {
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	ref := profileRefV2(esProfile, esPass)
	f := esSeed(t, esProfile, "deliberate\n")
	origRd, origSt := shrinkReadDir, shrinkLstat
	t.Cleanup(func() { shrinkReadDir, shrinkLstat = origRd, origSt })

	shrinkReadDir = func(string) ([]os.DirEntry, error) { return nil, syscall.EMFILE }
	if n := recoverShrinkDir(filepath.Dir(f)); n == 0 {
		t.Error("recoverShrinkDir reported an unlistable directory as finished")
	}
	if n := recoverShrinkMarkers(state); n == 0 {
		t.Error("the startup pass reported an unlistable directory as finished")
	}
	before := esRead(t, f)
	if got := esExpectShrink(t, esSession(t)); got != "ERR" {
		t.Errorf("EXPECT-SHRINK over an unlistable directory = %q, want ERR", got)
	}
	if got := esInferred(t, esSession(t), "p.one\n"); got != "ERR" {
		t.Errorf("EXPECT-SHRINK-INFERRED over an unlistable directory = %q, want ERR", got)
	}
	if esRead(t, f) != before || esExists(esMarker(esProfile+"#de")) {
		t.Error("a refused call changed the markers")
	}
	shrinkReadDir = origRd

	// a flag that cannot be looked at fails the readers closed
	shrinkLstat = func(n string) (os.FileInfo, error) {
		if strings.HasSuffix(n, ".txn") {
			return nil, syscall.EIO
		}
		return origSt(n)
	}
	if haveShrinkIntent(ref) {
		t.Error("a marker whose transaction flag cannot be looked at still authorizes")
	}
	if kind, _ := shrinkIntentProvenance(ref); kind != "inferred" {
		t.Errorf("provenance %q with an unreadable flag, want a marker with no user authority", kind)
	}
	shrinkLstat = origSt

	// and so does a record that cannot be looked at while a transaction is open
	if err := os.WriteFile(filepath.Join(filepath.Dir(f), ".txn"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	shrinkLstat = func(n string) (os.FileInfo, error) {
		if strings.HasSuffix(n, ".old") {
			return nil, syscall.EIO
		}
		return origSt(n)
	}
	if haveShrinkIntent(ref) {
		t.Error("a marker whose recovery record cannot be looked at still authorizes")
	}
	shrinkLstat = origSt
	os.Remove(filepath.Join(filepath.Dir(f), ".txn"))
	if !haveShrinkIntent(ref) {
		t.Error("control: the marker should authorize again once the flag can be looked at")
	}
}

// RF-011: an absent-marker record that cannot be looked at (Lstat EIO) must never leave the uncommitted live marker
// authoritative. While the failure lasts the marker is pending (shrinkLstat fails closed); recovery does not
// consult the record at all -- it ends the marker absent and drops the record -- so healing needs no second pass.
func TestRecoveryEndsMarkerWhoseAbsentRecordCannotBeLookedAt(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	ref := profileRefV2(esProfile, esPass)
	f := esSeed(t, esProfile, "deliberate\n")
	dir := filepath.Dir(f)
	for _, n := range []string{f + shrinkAbsSuffix, filepath.Join(dir, shrinkTxnName)} {
		if err := os.WriteFile(n, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	origSt := shrinkLstat
	t.Cleanup(func() { shrinkLstat = origSt })
	shrinkLstat = func(n string) (os.FileInfo, error) {
		if strings.HasSuffix(n, shrinkAbsSuffix) {
			return nil, syscall.EIO
		}
		return origSt(n)
	}
	if haveShrinkIntent(ref) || esAllowed(esProfile) {
		t.Fatal("the uncommitted marker authorizes while its record cannot be looked at")
	}
	if n := recoverShrinkDir(dir); n != 0 || esExists(f) || esExists(f+shrinkAbsSuffix) || esExists(filepath.Join(dir, shrinkTxnName)) {
		t.Errorf("recovery: left=%d, marker present=%v, record present=%v", n, esExists(f), esExists(f+shrinkAbsSuffix))
	}
	if haveShrinkIntent(ref) || esAllowed(esProfile) {
		t.Error("a marker authorizes after recovery ended its transaction")
	}
}

// ---- pushProfile's wiring of the generation (main.go) ---------------------------------------------------
//
// The seal children above call the helpers directly. These drive the real `push` verb in a child against an
// in-process store, with a marker present, and assert which marker survives.

func esPush(t *testing.T, store, name, pass, src, state string) (int, string) {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^TestPushVerbHelperProcess$", "-test.count=1")
	env := []string{"NOWHERE_PUSH_VERB_HELPER=" + strings.Join([]string{store, name, pass, src}, "\n")}
	for _, kv := range os.Environ() {
		switch kv[:strings.IndexByte(kv+"=", '=')] {
		case "GATEWAY_URL", "S3_ACCESS_KEY", "NOWHERE_CHUNK_CACHE", "NOWHERE_STATE", "NOWHERE_PHASE", "NOWHERE_COMPRESS":
			continue
		}
		env = append(env, kv)
	}
	cmd.Env = append(env, "NOWHERE_STATE="+state)
	out, err := cmd.CombinedOutput()
	if err == nil {
		return 0, string(out)
	}
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		t.Fatalf("running the agent: %v", err)
	}
	return ee.ExitCode(), string(out)
}

// esSeedTree writes a tree of incompressible files big enough to span many chunks.
func esSeedTree(t *testing.T, files, size int) string {
	t.Helper()
	dir := t.TempDir()
	rng := rand.New(rand.NewSource(7))
	for i := 0; i < files; i++ {
		b := make([]byte, size)
		rng.Read(b)
		if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("f%02d.bin", i)), b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestPushVerbClearsOnlyTheMarkerItAuthorizedAgainst(t *testing.T) {
	for _, vault := range []bool{true, false} {
		for _, newer := range []bool{false, true} {
			name := fmt.Sprintf("vault=%v/newer=%v", vault, newer)
			t.Run(name, func(t *testing.T) {
				state := t.TempDir()
				t.Setenv("NOWHERE_STATE", state)
				store := newHTTPStore(t)
				prof, pass := "pushwire", "push wire horse battery staple"
				createVault(store, prof, pass)
				if !vault {
					prof += "#apps" // a scope of the vault: sealed by the non-vault arm
				}
				ref := profileRefV2(prof, pass)
				big, small := esSeedTree(t, 60, 400<<10), t.TempDir()
				os.WriteFile(filepath.Join(small, "a.txt"), []byte("what is left"), 0o600)
				if code, out := esPush(t, store, prof, pass, big, state); code != 0 {
					t.Fatalf("setup push exited %d\n%s", code, out)
				}
				// without the intent the shrink is refused: the control that the marker is what lets it through
				if code, out := esPush(t, store, prof, pass, small, state); code != exitSealRefused {
					t.Fatalf("control: a shrinking push without intent exited %d, want %d\n%s", code, exitSealRefused, out)
				}
				if err := markShrinkIntent(ref); err != nil {
					t.Fatal(err)
				}
				fwd := store
				if newer {
					// a newer EXPECT-SHRINK lands while the seal uploads, after the guard has read its marker
					u, _ := url.Parse(store)
					proxy := httputil.NewSingleHostReverseProxy(u)
					fired := false
					srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
						if r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/ref/") && !fired {
							fired = true
							if err := markShrinkIntent(ref); err != nil {
								t.Error(err)
							}
						}
						proxy.ServeHTTP(w, r)
					}))
					t.Cleanup(srv.Close)
					fwd = srv.URL
				}
				before := readShrinkIntent(ref).token
				if code, out := esPush(t, fwd, prof, pass, small, state); code != 0 {
					t.Fatalf("the push with intent exited %d\n%s", code, out)
				}
				after := readShrinkIntent(ref)
				switch {
				case newer && (!after.armed || after.token == before):
					t.Errorf("the seal consumed the newer EXPECT-SHRINK's marker (armed=%v)", after.armed)
				case !newer && after.armed:
					t.Error("the seal left the marker it authorized against armed")
				}
			})
		}
	}
}

// esRecoverInProcess is the recovery a later call runs in a live process (memory of this process intact), as
// opposed to recoverShrinkMarkers, the daemon-start pass.
func esRecoverInProcess(state string) int {
	dir := filepath.Join(state, "shrink-intent")
	unlock, err := lockShrinkDir(dir, false)
	if err != nil {
		return 1
	}
	defer unlock()
	return recoverShrinkDir(dir)
}

// ---- round 3: a marker an ERR-answering call left behind never becomes authority -------------------------------
//
// The seal's clear and the recovery of an earlier transaction are the two places a marker and its record change
// together. The rules these tests pin: the live marker is neutralised FIRST and the record dropped only when that
// worked; a recovery of an earlier transaction ends the marker absent and never restores a previous body.

// esSealClear runs the seal's clear of token in a re-exec'd child (another process, as on a device) with the
// filesystem faulted as fault says. killOn names the file the child signals when it hangs; the child is then killed.
func esSealClear(t *testing.T, ref, token, fault, killOn string) {
	t.Helper()
	sig := t.TempDir()
	if err := os.WriteFile(filepath.Join(sig, "tokin"), []byte(token), 0o600); err != nil {
		t.Fatal(err)
	}
	cmd := esChild(t, "sealclear", ref, sig, "NWP_SHRINK_FAULT="+fault)
	if killOn != "" {
		if !esWaitFile(filepath.Join(sig, killOn)) {
			t.Fatalf("the child never reached %q", killOn)
		}
		cmd.Process.Kill()
		cmd.Wait()
		return
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("child: %v", err)
	}
}

// esSealStates builds the two on-disk states a seal's clear can meet after an EXPECT-SHRINK that answered ERR, and
// returns the seal's token (the body it authorized against before the call) and a heal for the parent's seams.
//
//	"erred": EXPECT-SHRINK #2 under esPersistentFailure: bare holds the call's body, bare.old the seal's token
//	"crash": the call died after staging, before any marker renamed: bare still holds the token, with its record
func esSealStates(t *testing.T, state string) (token string, heal func()) {
	t.Helper()
	ref := profileRefV2(esProfile, esPass)
	if err := markShrinkIntent(ref); err != nil {
		t.Fatal(err)
	}
	token = readShrinkIntent(ref).token
	if token == "" {
		t.Fatal("setup: the seeded marker does not authorize")
	}
	switch state {
	case "erred":
		heal = esPersistentFailure(t)
		if got := esExpectShrink(t, esSession(t)); got != "ERR" {
			t.Fatalf("setup: reply = %q, want ERR", got)
		}
	case "crash":
		heal = func() {}
		f := esMarker(esProfile)
		if err := os.WriteFile(f+shrinkOldSuffix, []byte(token), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(filepath.Dir(f), shrinkTxnName), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if esAllowed(esProfile) {
		t.Fatalf("setup %q: the marker authorizes before the seal's clear", state)
	}
	return token, heal
}

// Finding 1 (round 3): the seal's clear over a marker its ERR-answering predecessor left pending must not leave
// authority behind -- not while the failure lasts, not when the seal is killed between its steps, and not after the
// filesystem heals and recovery ends the transaction.
func TestSealClearAfterERRLeavesNoAuthority(t *testing.T) {
	for _, state := range []string{"erred", "crash"} {
		for _, c := range []struct{ fault, killOn string }{{"persist", ""}, {"killdrop", "dropped"}, {"killremove", "removing"}} {
			if state == "erred" && c.killOn != "" {
				continue // the clear sees the call's body, not its token, and touches nothing: there is no step to be killed in
			}
			t.Run(state+"/"+c.fault, func(t *testing.T) {
				st := t.TempDir()
				t.Setenv("NOWHERE_STATE", st)
				token, heal := esSealStates(t, state)
				esSealClear(t, profileRefV2(esProfile, esPass), token, c.fault, c.killOn)
				if esAllowed(esProfile) {
					t.Error("authority while the failure lasts")
				}
				heal()
				if n := recoverShrinkMarkers(st); n != 0 {
					t.Fatalf("recovery left %d unfinished on a healthy filesystem", n)
				}
				if esAllowed(esProfile) || esExists(esMarker(esProfile)) {
					t.Errorf("after heal and recovery: allowed=%v, marker present=%v", esAllowed(esProfile), esExists(esMarker(esProfile)))
				}
			})
		}
	}
}

// Finding 2 (round 3): the seal's clear runs in `agent push`, a process that exits, so nothing it remembers reaches
// the daemon. A clear that lost every write leaves the spent token in the record; the logoff's
// EXPECT-SHRINK-INFERRED (a later call in the daemon) must not restore it into the live marker.
func TestSealClearThenInferredDropDoesNotReplaySpentToken(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	token, _ := esSealStates(t, "crash")
	esSealClear(t, profileRefV2(esProfile, esPass), token, "persist", "")
	if got := esInferred(t, esSession(t), "p.one\n"); got != "OK" {
		t.Fatalf("EXPECT-SHRINK-INFERRED = %q, want OK", got)
	}
	if esExists(esMarker(esProfile)) || esAllowed(esProfile) {
		t.Errorf("the spent token came back as a live marker: %q", esRead(t, esMarker(esProfile)))
	}
	if kind, declared := shrinkIntentProvenance(profileRefV2(esProfile+"#apps", esPass)); kind != "inferred" || len(declared) != 1 || declared[0] != "p.one" {
		t.Errorf("#apps provenance = %q %v, want inferred [p.one]", kind, declared)
	}
}

// Finding 4 (round 3): authority only to a body that is whole. An empty or cut-short body (a write that died
// half way, the tombstone) must not read as whole-scope deliberate intent, which would upgrade a package-scoped
// inferred marker.
func TestIncompleteMarkerBodyIsNoAuthority(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	ref := profileRefV2(esProfile, esPass)
	for body, want := range map[string]bool{
		"deliberate\ngen=00\n": true, "inferred\np.one\ngen=00\n": true, "deliberate\n": true,
		"": false, "consu": false, "consumed\n": false, "deliberate": false, "inferred\np.one": false, "garbage\n": false,
	} {
		esSeed(t, esProfile, body)
		if got := haveShrinkIntent(ref); got != want {
			t.Errorf("body %q: authorizes=%v, want %v", body, got, want)
		}
		if !want {
			if k, _ := shrinkIntentProvenance(ref); k == "deliberate" {
				t.Errorf("body %q reads as deliberate intent", body)
			}
		}
	}
}

// Finding 4 (round 3): a write that truncates its file and THEN fails (ENOSPC, EIO) must reach neither the live
// marker nor a record. The failed clear leaves the inferred marker byte-identical, and a recovery over an emptied
// record restores nothing.
func TestTruncatingWriteFailureDamagesNoMarkerOrRecord(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	ref := profileRefV2(esProfile, esPass)
	const inferred = "inferred\np.one\n"
	f := esSeed(t, esProfile, inferred)
	origRw, origRm := shrinkRewrite, shrinkRemove
	t.Cleanup(func() { shrinkRewrite, shrinkRemove = origRw, origRm })
	shrinkRewrite = func(n string, b []byte, m os.FileMode) error {
		os.WriteFile(n, nil, m) // truncate, then fail
		return syscall.EIO
	}
	shrinkRemove = func(string) error { return syscall.EIO }
	clearShrinkIntentGen(ref, inferred, true)
	if got := esRead(t, f); got != inferred {
		t.Errorf("a failed clear changed the marker to %q", got)
	}
	if k, d := shrinkIntentProvenance(ref); k != "inferred" || len(d) != 1 {
		t.Errorf("provenance %q %v after a failed clear, want inferred [p.one]", k, d)
	}
	esNoStrays(t)
	// an emptied record (a record written in place that died) is never restored
	shrinkRewrite, shrinkRemove = origRw, origRm
	for _, n := range []string{f + shrinkOldSuffix, filepath.Join(filepath.Dir(f), shrinkTxnName)} {
		if err := os.WriteFile(n, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if n := recoverShrinkMarkers(st); n != 0 {
		t.Fatalf("recovery left %d", n)
	}
	if esExists(f) || haveShrinkIntent(ref) {
		t.Error("recovery restored an emptied record as a live marker")
	}
}

// M25, deterministically: while a marker transaction is open its lock is held. A raw non-blocking flock on a fresh
// descriptor, taken from inside the rename hook, must be refused; the sleep-window tests stay as end-to-end checks.
func TestExpectShrinkHoldsTheLockWhileTheTransactionIsOpen(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	lock := filepath.Join(filepath.Dir(esMarker(esProfile)), shrinkLockName)
	orig, probed := shrinkRename, 0
	t.Cleanup(func() { shrinkRename = orig })
	shrinkRename = func(a, b string) error {
		probed++
		fd, err := os.OpenFile(lock, os.O_RDWR, 0)
		if err != nil {
			t.Errorf("probe: %v", err)
		} else {
			if syscall.Flock(int(fd.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) == nil {
				t.Error("the lock was free while the transaction was open")
			}
			fd.Close()
		}
		return orig(a, b)
	}
	if err := markProfileShrinkIntent(esProfile, esPass); err != nil {
		t.Fatal(err)
	}
	if probed == 0 {
		t.Fatal("the probe never ran")
	}
}
