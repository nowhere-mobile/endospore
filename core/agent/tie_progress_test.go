package main

import (
	"bufio"
	"encoding/hex"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261008-04: slice 3b -- the Tie screen's progress for the background re-key (SE-PROGRESS), the gate's reason
// for holding it back, and the re-key at sign-in for a profile tied before its small scopes were.

// seVerbAll drives handleSETie as caller peer and returns its whole reply.
func seVerbAll(t *testing.T, dest, verb string, peer int) string {
	t.Helper()
	old := seTiePeerUID
	seTiePeerUID = func(net.Conn) int { return peer }
	defer func() { seTiePeerUID = old }()
	server, client := net.Pipe()
	defer client.Close()
	go func() {
		handleSETie(server, bufio.NewReader(strings.NewReader("")), dest, verb)
		server.Close()
	}()
	client.SetDeadline(time.Now().Add(30 * time.Second))
	b, _ := io.ReadAll(client)
	return string(b)
}

// progressLine is the reply's line for scope label (MEDIA or APPS), without the numbers when bare is true.
func progressLine(t *testing.T, reply, label string, bare bool) string {
	t.Helper()
	for _, l := range strings.Split(reply, "\n") {
		if f := strings.Fields(l); len(f) == 4 && f[0] == label {
			if bare {
				return f[0] + " " + f[1]
			}
			return l
		}
	}
	t.Fatalf("SE-PROGRESS has no %s line: %q", label, reply)
	return ""
}

const tieSelf = 12*100000 + 116

func TestSEProgressFollowsTheJob(t *testing.T) {
	dest, name, pass := tiedWithMedia(t)
	reply := seVerbAll(t, dest, "SE-PROGRESS", tieSelf)
	if !strings.HasPrefix(reply, "OK\n") {
		t.Fatalf("SE-PROGRESS on a tied profile = %q", reply)
	}
	if got := progressLine(t, reply, "MEDIA", true); got != "MEDIA waiting" {
		t.Fatalf("before the gate says anything: %q, want waiting", got)
	}
	os.WriteFile(filepath.Join(dest, rekeyWaitFile), []byte("12 wifi\n"), 0o600)
	if got := progressLine(t, seVerbAll(t, dest, "SE-PROGRESS", tieSelf), "MEDIA", true); got != "MEDIA wifi" {
		t.Fatalf("with the gate waiting for Wi-Fi: %q", got)
	}
	os.WriteFile(filepath.Join(dest, rekeyWaitFile), []byte("13 battery\n"), 0o600) // another session's reason
	if got := progressLine(t, seVerbAll(t, dest, "SE-PROGRESS", tieSelf), "MEDIA", true); got != "MEDIA waiting" {
		t.Fatalf("another session's reason was shown for this one: %q", got)
	}
	os.Remove(filepath.Join(dest, rekeyWaitFile))
	os.WriteFile(filepath.Join(dest, rekeyArmedFile), []byte("12\n"), 0o600)
	rekeyOnce(dest)
	f := strings.Fields(progressLine(t, seVerbAll(t, dest, "SE-PROGRESS", tieSelf), "MEDIA", false))
	if f[1] != "running" || f[3] == "0" || f[2] == "0" {
		t.Fatalf("armed, after a batch: %v, want running with bytes done and a total", f)
	}
	stepUntilSwitched(t, name, pass, 80)
	if got := progressLine(t, seVerbAll(t, dest, "SE-PROGRESS", tieSelf), "MEDIA", true); got != "MEDIA done" {
		t.Fatalf("after the switch: %q, want done", got)
	}
	rekeyStateMu.Lock()
	rekeyStateUID, rekeyLastErr = "12", errInsufficientCredit
	rekeyStateMu.Unlock()
	t.Cleanup(func() { rekeyStateMu.Lock(); rekeyLastErr = nil; rekeyStateMu.Unlock() })
	if got := progressLine(t, seVerbAll(t, dest, "SE-PROGRESS", tieSelf), "APPS", true); got != "APPS credit" {
		t.Fatalf("out of credit: %q, want credit", got)
	}
}

func TestSEProgressOnAnUntiedProfile(t *testing.T) {
	dest, _, _, _ := tieFixture(t, hex.EncodeToString(seA))
	if got := seVerbAll(t, dest, "SE-PROGRESS", tieSelf); got != "OK NONE\n" {
		t.Fatalf("SE-PROGRESS on an untied profile = %q", got)
	}
	if got := seVerbAll(t, dest, "SE-PROGRESS", 13*100000+116); got != "ERR-CALLER\n" {
		t.Fatalf("SE-PROGRESS from another user's app = %q", got)
	}
}

// A profile tied before its small scopes were (TIED PARTIAL) is finished once its sign-in lands.
func TestFinishTieAtSignIn(t *testing.T) {
	dest, name, pass, dk0 := tieFixture(t, hex.EncodeToString(seA))
	old := tieFinishDelay
	tieFinishDelay = 0
	t.Cleanup(func() { tieFinishDelay = old })

	finishTieAtSignIn(dest) // untied: nothing to finish
	if got := seVerb(t, dest, "SE-STATUS", "", tieSelf); got != "OK UNTIED" {
		t.Fatalf("an untied profile changed at sign-in: %q", got)
	}

	sealDEInSession(t, name, pass, "app data")
	if err := sessionTie("s3", name, pass, seA); err != nil {
		t.Fatal(err)
	}
	capWrite(name, pass, dk0, func() { // one scope left passphrase-keyed, as a tie from before -12 leaves them
		if err := untieScopeHeads("s3", name, pass, seA, []string{"#de"}); err != nil {
			t.Fatal(err)
		}
	})
	if got := seVerb(t, dest, "SE-STATUS", "", tieSelf); got != "OK TIED PARTIAL" {
		t.Fatalf("precondition: %q, want OK TIED PARTIAL", got)
	}
	finishTieAtSignIn(dest)
	if got := seVerb(t, dest, "SE-STATUS", "", tieSelf); got != "OK TIED" {
		t.Fatalf("after the sign-in finish: %q, want OK TIED", got)
	}
	if _, ok := readScopeFile(t, "s3", name+"#de", pass, nil); ok {
		t.Fatal("after the sign-in finish the passphrase alone still opens #de")
	}
	// And the sign-in starts it: GRANT-PERMS, the chooser's last login step, right after mediad.
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), `	kickMediad(dest)
	// NWP-20261008-04: a profile tied before its small scopes were (TIED PARTIAL) finishes its tie now, once, in the
	// background -- the 2026-10-06 decision (docs/tie-scope-keys.md §5 Q3).
	goSafe("finish-tie", func() { finishTieAtSignIn(dest) })`) {
		t.Fatal("handleGrantPerms no longer starts finishTieAtSignIn after a sign-in lands")
	}
}

// The gate's reason file belongs to one session and names one of three reasons.
func TestRekeyWaitFor(t *testing.T) {
	dest := t.TempDir()
	if got := rekeyWaitFor(dest, "12"); got != "" {
		t.Fatalf("no file: %q", got)
	}
	for _, c := range []struct{ body, want string }{
		{"12 wifi\n", "wifi"}, {"12 battery\n", "battery"}, {"13 net\n", ""}, {"12\n", ""}, {"", ""},
	} {
		os.WriteFile(filepath.Join(dest, rekeyWaitFile), []byte(c.body), 0o600)
		if got := rekeyWaitFor(dest, "12"); got != c.want {
			t.Errorf("rekey.wait %q -> %q, want %q", c.body, got, c.want)
		}
	}
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	// Each reason is its own exact verb: an unknown verb falls through to the legacy login, which wipes the state dir.
	if !strings.Contains(string(src), `name == "REKEY-WAIT-WIFI" || name == "REKEY-WAIT-NET" || name == "REKEY-WAIT-BATTERY" {`) {
		t.Fatal("the daemon no longer accepts the three REKEY-WAIT verbs by exact name")
	}
}

// The chooser side: the gate says why it holds the job back, and the Tie screen renders the progress.
func TestTieProgressInTheChooser(t *testing.T) {
	gate := chooserCode(t, "ChooserActivity.java")
	for _, want := range []string{
		`String rekeyWant = !net ? (allowMetered ? "REKEY-WAIT-NET" : "REKEY-WAIT-WIFI")`,
		`: batteryAllowsRekey(app) ? "REKEY-ARM" : "REKEY-WAIT-BATTERY";`,
		`if (rekeySent != null) { pollDaemon("REKEY-DISARM\n"); rekeySent = null; }`,
	} {
		if !strings.Contains(gate, want) {
			t.Errorf("the gate lacks %q", want)
		}
	}
	prof := chooserCode(t, "ProfileActivity.java")
	for _, want := range []string{
		`final String r = sendDaemonMulti("SE-PROGRESS\n");`,
		`@Override public void onViewDetachedFromWindow(android.view.View v) { up.set(false); }`, // stops with the screen
		`? what + ": protecting… " + (done * 100 / total) + "% (" + humanBytes(done) + " of "`,
		`StatusLine.error(line, what + ": your storage plan is full — add storage to finish");`,
		`line.setText(what + ": waiting for Wi-Fi");`,
		`line.setText(what + ": waiting until the battery is above 20% or charging");`,
		`"Your photos and files and your installed apps move under the chip in the background. Until each "`,
		`"is done, your passphrase alone still opens it:");`,
	} {
		if !strings.Contains(prof, want) {
			t.Errorf("the Tie screen lacks %q", want)
		}
	}
}

// NWP-20261008-05: with no connection the store checks fail, and the screen still needs the gate's reason. Found on
// lynx 2026100802: Wi-Fi off, no data link, every poll answered ERR and "waiting for Wi-Fi" never showed.
func TestSEProgressAnswersWithoutTheStore(t *testing.T) {
	dest, name, pass := tiedWithMedia(t)
	os.WriteFile(filepath.Join(dest, rekeyArmedFile), []byte("12\n"), 0o600)
	rekeyOnce(dest) // one batch while online: the session knows its numbers
	stepUntilSwitched(t, name, pass, 80)
	if got := progressLine(t, seVerbAll(t, dest, "SE-PROGRESS", tieSelf), "MEDIA", true); got != "MEDIA done" {
		t.Fatalf("online after the switch: %q", got)
	}
	// Offline: the store is unreachable, and the gate says it is waiting for Wi-Fi.
	t.Setenv("GATEWAY_URL", "http://127.0.0.1:1")
	capReadCache = map[string]capEntry{}
	os.Remove(filepath.Join(dest, rekeyArmedFile))
	os.WriteFile(filepath.Join(dest, rekeyWaitFile), []byte("12 wifi\n"), 0o600)
	reply := seVerbAll(t, dest, "SE-PROGRESS", tieSelf)
	if !strings.HasPrefix(reply, "OK\n") {
		t.Fatalf("offline, SE-PROGRESS = %q: the screen would keep its last reading", reply)
	}
	if got := progressLine(t, reply, "MEDIA", true); got != "MEDIA done" {
		t.Fatalf("offline, a scope this session saw switched reads %q, want done", got)
	}
	if got := progressLine(t, reply, "APPS", true); got != "APPS wifi" {
		t.Fatalf("offline, a scope still to do reads %q, want the gate's reason", got)
	}
}
