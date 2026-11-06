package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// NWP-20261021-08: the replay table survives a daemon restart (telephony_arrival.go). A restart is simulated by
// emptying every per-run variable of the table and the link history while the files stay, as
// TestV2AfterADaemonRestartIsUnresolved does for the link history.

// persistFixture is telFixture with the telephony inbox in a directory of its own, so the files beside it are the
// only ones the replay table and the link floor put there. It returns the driven clock.
func persistFixture(t *testing.T) *int64 {
	t.Helper()
	telFixture(t)
	old := telInboxBase
	telInboxBase = filepath.Join(t.TempDir(), telStateSubdir, "inbox")
	t.Cleanup(func() { telInboxBase = old })
	return useArrivalState(t)
}

// restartDaemon forgets everything the daemon holds in memory about the table and the links. The files stay.
func restartDaemon(t *testing.T) {
	t.Helper()
	if telInboxBase == filepath.Join(stateDirDefault, telStateSubdir, "inbox") {
		t.Fatal("restartDaemon with the production telephony inbox")
	}
	telReplays, telReplayOrder = map[[32]byte]*telReplay{}, nil
	telReplayKey, telReplayLoaded, telReplayKeyOn, telReplayNoDisk, telReplayDirty, telReplayLines, telReplayWarned =
		nil, false, false, false, false, 0, false
	linkHistory, linkHorizon, linkFloor = nil, map[string]int64{}, -1
}

func replaysFile(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(telReplayPath())
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func replayKeyFile(t *testing.T) []byte {
	t.Helper()
	b, err := os.ReadFile(telReplayKeyPath())
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func replayDirNames(t *testing.T) []string {
	t.Helper()
	ents, err := os.ReadDir(telReplayDir())
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range ents {
		out = append(out, e.Name())
	}
	sort.Strings(out)
	return out
}

func wantSealed(t *testing.T, ref string, n int) {
	t.Helper()
	if got := len(listSealed(ref)); got != n {
		t.Fatalf("%d sealed blobs for %s, want %d", got, ref, n)
	}
}

func TestTelReplayPersist_SmsRetryAcrossARestartSealsOnce(t *testing.T) {
	persistFixture(t)
	bindFor(t, iccidX, "refA")
	req := v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")
	first := driveLogin(t, t.TempDir(), req)
	if !strings.HasPrefix(first, "OK ") {
		t.Fatalf("replied %q", first)
	}
	restartDaemon(t)
	if got := driveLogin(t, t.TempDir(), req); got != first {
		t.Fatalf("the retry across the restart replied %q, want %q", got, first)
	}
	wantSealed(t, "refA", 1)
	if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(2), "sms", 2, iccidX, "+1", late, "x")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("a new arrival replied %q", got)
	}
	wantSealed(t, "refA", 2)
}

func TestTelReplayPersist_MmsRetryAcrossARestartSealsOnce(t *testing.T) {
	persistFixture(t)
	bindFor(t, iccidX, "refA")
	req := v2Mms(arrivalID(1), 2, iccidX, late, "p")
	first := driveLogin(t, t.TempDir(), req)
	if !strings.HasPrefix(first, "OK ") {
		t.Fatalf("replied %q", first)
	}
	restartDaemon(t)
	if got := driveLogin(t, t.TempDir(), req); got != first {
		t.Fatalf("the retry across the restart replied %q, want %q", got, first)
	}
	wantSealed(t, "refA", 1)
	if got := driveLogin(t, t.TempDir(), v2Mms(arrivalID(2), 2, iccidX, late, "p")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("a new arrival replied %q", got)
	}
	wantSealed(t, "refA", 2)
}

func TestTelReplayPersist_UnassignThenRestartAnswersRemoved(t *testing.T) {
	persistFixture(t)
	bindFor(t, iccidX, "refA")
	req := v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")
	if got := driveLogin(t, t.TempDir(), req); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("replied %q", got)
	}
	if got := driveLogin(t, t.TempDir(), "DELETE-BINDING\n"+iccidX+"\n\n"); !strings.HasPrefix(got, "OK") {
		t.Fatalf("the unassign replied %q", got)
	}
	restartDaemon(t)
	if got := driveLogin(t, t.TempDir(), req); got != "REMOVED" {
		t.Fatalf("the repeat after the unassign and the restart replied %q, want REMOVED", got)
	}
}

func TestTelReplayPersist_RestartThenUnassignAnswersRemoved(t *testing.T) {
	persistFixture(t)
	bindFor(t, iccidX, "refA")
	req := v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")
	if got := driveLogin(t, t.TempDir(), req); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("replied %q", got)
	}
	restartDaemon(t)
	if got := driveLogin(t, t.TempDir(), "DELETE-BINDING\n"+iccidX+"\n\n"); !strings.HasPrefix(got, "OK") {
		t.Fatalf("the unassign replied %q", got)
	}
	if got := driveLogin(t, t.TempDir(), req); got != "REMOVED" {
		t.Fatalf("the repeat after the restart and the unassign replied %q, want REMOVED", got)
	}
}

func TestTelReplayPersist_AnExpiredEntryIsNotReplayedAndLeavesTheFile(t *testing.T) {
	clk := persistFixture(t)
	bindFor(t, iccidX, "refA")
	req := v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")
	if got := driveLogin(t, t.TempDir(), req); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("replied %q", got)
	}
	id := telReplayID("SEAL-TEL", arrivalID(1))
	*clk += telReplayTTL.Milliseconds() + 60_000
	restartDaemon(t)
	telReplayLoad()
	if _, ok := telReplays[id]; ok {
		t.Fatal("the load kept an expired entry")
	}
	if got := replaysFile(t); got != "" {
		t.Fatalf("the load left the expired entry in the file: %q", got)
	}
	if got := driveLogin(t, t.TempDir(), req); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("the expired arrival replied %q", got)
	}
	wantSealed(t, "refA", 2)
}

func TestTelReplayPersist_DamagedLinesAreSkippedAndATornTailRepaired(t *testing.T) {
	persistFixture(t)
	bindFor(t, iccidX, "refA")
	seal := func(n int) string {
		return driveLogin(t, t.TempDir(), v2Tel(arrivalID(n), "sms", 2, iccidX, "+1", late, "x"))
	}
	r1 := seal(1)
	appendReplays := func(s string) {
		f, err := os.OpenFile(telReplayPath(), os.O_WRONLY|os.O_APPEND, 0o600)
		if err != nil {
			t.Fatal(err)
		}
		defer f.Close()
		if _, err := f.WriteString(s); err != nil {
			t.Fatal(err)
		}
	}
	appendReplays("zz 1 - x\n") // a whole line that does not parse
	r2 := seal(2)
	lines := strings.Split(strings.TrimSpace(replaysFile(t)), "\n")
	appendReplays(lines[len(lines)-1][:40]) // half a line, no newline
	restartDaemon(t)
	for n, want := range map[int]string{1: r1, 2: r2} {
		if got := seal(n); got != want {
			t.Fatalf("arrival %d across the restart replied %q, want %q", n, got, want)
		}
	}
	wantSealed(t, "refA", 2)
	r3 := seal(3)
	wantSealed(t, "refA", 3)
	restartDaemon(t)
	if got := seal(3); got != r3 {
		t.Fatalf("arrival 3 across the second restart replied %q, want %q", got, r3)
	}
	wantSealed(t, "refA", 3)
}

func TestTelReplayPersist_TheTableKeepsTheNewestTelReplayMax(t *testing.T) {
	persistFixture(t)
	for i := 0; i <= telReplayMax; i++ {
		telReplayPut(telReplayID("SEAL-TEL", arrivalID(i)), "NONE\n", "")
	}
	restartDaemon(t)
	telReplayLoad()
	if len(telReplays) != telReplayMax {
		t.Fatalf("%d entries after the restart, want %d", len(telReplays), telReplayMax)
	}
	if _, ok := telReplayGet(telReplayID("SEAL-TEL", arrivalID(0))); ok {
		t.Fatal("the oldest entry survived the cap")
	}
	if _, ok := telReplayGet(telReplayID("SEAL-TEL", arrivalID(telReplayMax))); !ok {
		t.Fatal("the newest entry is gone")
	}
}

func TestTelReplayPersist_FilesAreOwnerOnlyAndHoldNoArrivalID(t *testing.T) {
	persistFixture(t)
	bindFor(t, iccidX, "refA")
	before := map[string]bool{}
	for _, n := range replayDirNames(t) {
		before[n] = true
	}
	if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("replied %q", got)
	}
	var added []string
	for _, n := range replayDirNames(t) {
		if !before[n] && n != "inbox" {
			added = append(added, n)
		}
	}
	if strings.Join(added, " ") != ".replay-key .replays" {
		t.Fatalf("the seal added %v, want the key and the table only", added)
	}
	for _, p := range []string{telReplayKeyPath(), telReplayPath()} {
		st, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if st.Mode().Perm() != 0o600 {
			t.Fatalf("%s is %v, want 0600", filepath.Base(p), st.Mode().Perm())
		}
	}
	if n := len(replayKeyFile(t)); n != 32 {
		t.Fatalf("the key is %d bytes, want 32", n)
	}
	got := strings.ToLower(replaysFile(t))
	if strings.Contains(got, arrivalID(1)) {
		t.Fatal("the table holds the arrival id")
	}
}

func TestTelReplayPersist_AnUnwritableTableStillSealsAndWarnsOnce(t *testing.T) {
	persistFixture(t)
	bindFor(t, iccidX, "refA")
	if err := os.Mkdir(telReplayPath(), 0o700); err != nil { // .replays is a directory: every append fails
		t.Fatal(err)
	}
	var got1, got2 string
	out := captureStderr(t, func() {
		got1 = driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x"))
		got2 = driveLogin(t, t.TempDir(), v2Tel(arrivalID(2), "sms", 2, iccidX, "+1", late, "x"))
	})
	for _, g := range []string{got1, got2} {
		if !strings.HasPrefix(g, "OK ") {
			t.Fatalf("replied %q", g)
		}
	}
	wantSealed(t, "refA", 2)
	if n := strings.Count(out, "could not persist the replay table"); n != 1 {
		t.Fatalf("%d persist warnings in %q, want 1", n, out)
	}
	for _, leak := range []string{arrivalID(1), arrivalID(2), simTag(iccidX), b64s("L"), telReplayDir()} {
		if strings.Contains(out, leak) {
			t.Fatalf("the persist warning leaks %q: %q", leak, out)
		}
	}
	if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")); got != got1 {
		t.Fatalf("the in-memory table replied %q on a repeat, want %q", got, got1)
	}
}

func TestTelReplayPersist_ATornKeyIsReplacedAndItsEntriesDropped(t *testing.T) {
	persistFixture(t)
	bindFor(t, iccidX, "refA")
	seal := func(n int) string {
		return driveLogin(t, t.TempDir(), v2Tel(arrivalID(n), "sms", 2, iccidX, "+1", late, "x"))
	}
	if got := seal(1); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("replied %q", got)
	}
	old := replayKeyFile(t)
	if err := os.WriteFile(telReplayKeyPath(), old[:16], 0o600); err != nil {
		t.Fatal(err)
	}
	restartDaemon(t)
	seal(1) // its id was made under the old key: sealed again, the documented consequence
	wantSealed(t, "refA", 2)
	nk := replayKeyFile(t)
	if len(nk) != 32 || string(nk[:16]) == string(old[:16]) {
		t.Fatalf("the torn key was not replaced by a fresh one (%d bytes)", len(nk))
	}
	if n := strings.Count(replaysFile(t), "\n"); n != 1 {
		t.Fatalf("%d lines in the table, want only the new entry", n)
	}
	seal(2)
	wantSealed(t, "refA", 3)
	restartDaemon(t)
	seal(2)
	wantSealed(t, "refA", 3)
}
