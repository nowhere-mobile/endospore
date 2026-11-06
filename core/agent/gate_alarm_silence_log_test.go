package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261028-12: SILENCE-GATE-ALARM reported every outcome with fmt.Printf only -- login.log, which a gate-filed
// report excludes -- and the silence-* verbs gate.log declares were written by nothing. These tests drive the verb
// through the dispatcher and pin, for each outcome, the reply (unchanged) AND the gate.log lines it leaves.

// gateAlarmSilenceLines is gate.log with each line's d=, m= and s= tokens dropped: those buckets are elapsed time
// and say nothing about the outcome.
func gateAlarmSilenceLines(t *testing.T, p string) []string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		t.Fatalf("read gate.log: %v", err)
	}
	var out []string
	for _, l := range strings.Split(strings.TrimRight(string(b), "\n"), "\n") {
		if l == "" {
			continue
		}
		var keep []string
		for _, tok := range strings.Fields(l) {
			if strings.HasPrefix(tok, "d=") || strings.HasPrefix(tok, "m=") || strings.HasPrefix(tok, "s=") {
				continue
			}
			keep = append(keep, tok)
		}
		out = append(out, strings.Join(keep, " "))
	}
	return out
}

func gateAlarmSilenceWant(t *testing.T, dest, p, wantReply string, wantLines ...string) {
	t.Helper()
	if got := evictConn(t, dest, "SILENCE-GATE-ALARM\n"); got != wantReply {
		t.Errorf("reply = %q, want %q", got, wantReply)
	}
	got := gateAlarmSilenceLines(t, p)
	if strings.Join(got, "|") != strings.Join(wantLines, "|") {
		t.Errorf("gate.log lines = %q, want %q", got, wantLines)
	}
}

func gateAlarmSilenceStash(t *testing.T, dest, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dest, "gate-alarm-src"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func gateAlarmSilenceColdLock(t *testing.T, dest, profile, uid string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dest, ".coldlock"), []byte(profile+"\n"+uid+"\n\n\n\n\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestGateAlarmSilenceLog_NoTarget(t *testing.T) {
	p := gateLogTestFile(t)
	dest := t.TempDir()
	gateAlarmSilenceWant(t, dest, p, "NONE", "silence-req", "silence-notarget")
}

func TestGateAlarmSilenceLog_BadStash(t *testing.T) {
	p := gateLogTestFile(t)
	dest := t.TempDir()
	gateAlarmSilenceStash(t, dest, "x\tpkg\n")
	gateAlarmSilenceWant(t, dest, p, "ERR-ARG", "silence-req", "silence-err fields=2")
}

func TestGateAlarmSilenceLog_ColdLockOK(t *testing.T) {
	p := gateLogTestFile(t)
	dest := t.TempDir()
	gateAlarmSilenceStash(t, dest, "15\tcom.android.deskclock\n")
	gateAlarmSilenceColdLock(t, dest, "silencelogcoldok", "15")
	ops := cutoffWorker(t, dest, map[string]string{"silence-alarm": "OK"}, nil)
	gateAlarmSilenceWant(t, dest, p, "OK", "silence-req", "silence-coldlock", "silence-ok")
	if got := strings.Join(ops(), ","); got != "silence-alarm" {
		t.Errorf("roamd was handed %q, want one silence-alarm", got)
	}
}

func TestGateAlarmSilenceLog_ColdLockLive(t *testing.T) {
	p := gateLogTestFile(t)
	dest := t.TempDir()
	gateAlarmSilenceStash(t, dest, "15\tcom.android.deskclock\n")
	gateAlarmSilenceColdLock(t, dest, "silencelogcoldlive", "15")
	cutoffWorker(t, dest, map[string]string{"silence-alarm": "ERR-LIVE"}, nil)
	gateAlarmSilenceWant(t, dest, p, "ERR-LIVE", "silence-req", "silence-coldlock", "silence-live")
}

func TestGateAlarmSilenceLog_Stale(t *testing.T) {
	p := gateLogTestFile(t)
	dest := t.TempDir()
	gateAlarmSilenceStash(t, dest, "15\tcom.android.deskclock\n")
	if err := markRoamSession(dest, "silencelogstale", "correct horse", "16", ""); err != nil {
		t.Fatal(err)
	}
	gateAlarmSilenceWant(t, dest, p, "ERR-STALE", "silence-req", "silence-stale")
}

func TestGateAlarmSilenceLog_NoSession(t *testing.T) {
	p := gateLogTestFile(t)
	dest := t.TempDir()
	gateAlarmSilenceStash(t, dest, "15\tcom.android.deskclock\n")
	gateAlarmSilenceWant(t, dest, p, "NONE", "silence-req", "silence-nosession")
}

func TestGateAlarmSilenceLog_RoamdRefusal(t *testing.T) {
	p := gateLogTestFile(t)
	dest := t.TempDir()
	gateAlarmSilenceStash(t, dest, "15\tcom.android.deskclock\n")
	gateAlarmSilenceColdLock(t, dest, "silencelogrefuse", "15")
	cutoffWorker(t, dest, map[string]string{"silence-alarm": "ERR-PKG"}, nil)
	gateAlarmSilenceWant(t, dest, p, "ERR-PKG", "silence-req", "silence-coldlock", "silence-err")
}

// The closed-grammar property: after every outcome above, with each line's d=/m=/s= buckets removed, gate.log names
// no user, package or profile. (The raw bytes are not checked: the line's gap tokens say nothing about the target.)
func TestGateAlarmSilenceLog_NeverNamesTheTarget(t *testing.T) {
	p := gateLogTestFile(t)
	const profile = "silencelogleak"
	for _, c := range []struct{ stash, uid, answer string }{
		{"15\tcom.android.deskclock\n", "15", "OK"},
		{"15\tcom.android.deskclock\n", "15", "ERR-LIVE"},
		{"15\tcom.android.deskclock\n", "15", "ERR-PKG"},
		{"15\tcom.android.deskclock\n", "16", ""},
	} {
		dest := t.TempDir()
		gateAlarmSilenceStash(t, dest, c.stash)
		if c.answer == "" {
			if err := markRoamSession(dest, profile, "correct horse", c.uid, ""); err != nil {
				t.Fatal(err)
			}
		} else {
			gateAlarmSilenceColdLock(t, dest, profile, c.uid)
			cutoffWorker(t, dest, map[string]string{"silence-alarm": c.answer}, nil)
		}
		evictConn(t, dest, "SILENCE-GATE-ALARM\n")
	}
	lines := gateAlarmSilenceLines(t, p)
	if len(lines) < 4 {
		t.Fatalf("gate.log has %d lines after four requests, want at least 4: %q", len(lines), lines)
	}
	text := strings.ToLower(strings.Join(lines, "\n"))
	for _, bad := range []string{"15", "16", "deskclock", profile} {
		if strings.Contains(text, bad) {
			t.Errorf("gate.log names %q (d=/m=/s= removed):\n%s", bad, text)
		}
	}
}
