package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A message arriving while a stored session signs out seals to the inbox with NO "LIVE <uid>" token, so the
// chooser's SmsDeliverReceiver posts the gate notice. That holds because handleLogout removes `.roamsession`
// BEFORE it replies OK and before the seal starts: liveSession then answers "no session". (ROAM-OUT is the one
// verb that keeps the marker through its seal; no chooser code sends it.) A failed logoff re-arms the marker --
// a different, separately tracked case.

// Drives a real LOGOUT whose worker is held at the cutoff (the seal is in flight), then delivers an SMS for the
// profile that owns the bound SIM.
func TestLogoffMarker_AnArrivalMidLogoffSealsWithoutLive(t *testing.T) {
	telFixture(t)
	users := t.TempDir()
	if err := os.Mkdir(filepath.Join(users, "11"), 0o700); err != nil {
		t.Fatal(err)
	}
	old := androidUsersDir
	androidUsersDir = users // uid 11 reads as a live Android user, without `pm`
	t.Cleanup(func() { androidUsersDir = old })

	dest := cutoffSession(t, "11") // marks alice / "correct horse" as uid 11
	v, _ := vaultWithTelKey(t)
	ref := profileRefV2("alice", "correct horse")
	if err := setBindingOwner(2, iccidX, "Personal", "open", ref, v.TelPub); err != nil {
		t.Fatal(err)
	}
	sms := []string{"sms", "2", iccidX, "+15551234567", "1720000000000", "aGk=", "0", "0"}

	// Control: before the sign-out the same arrival goes LIVE, so the assertion below is not vacuous.
	if f := strings.Fields(driveSealTel(t, dest, sms)); len(f) != 6 || f[4] != "LIVE" || f[5] != "11" {
		t.Fatalf("before the logoff the reply is %q, want LIVE 11", f)
	}

	cutoffWorker(t, dest, map[string]string{"cutoff": "OK 0", "sweepmedia": "OK", "out": "OK"},
		map[string]time.Duration{"cutoff": 2 * time.Second})
	if got := ropReply(t, func(c net.Conn) { handleLogout(c, dest) }); got != "OK" {
		t.Fatalf("LOGOUT replied %q", got)
	}
	pendingReapMu.Lock()
	inFlight := sealInFlight
	pendingReapMu.Unlock()
	if !inFlight {
		t.Fatal("the logoff's seal is not in flight after the OK -- the test is not exercising the window")
	}
	if _, err := os.Stat(filepath.Join(dest, ".roamsession")); err == nil {
		t.Fatal(".roamsession is still present after the LOGOUT reply")
	}

	sms[4] = "1720000000001"
	reply := driveSealTel(t, dest, sms)
	if f := strings.Fields(reply); len(f) != 4 || f[0] != "OK" || f[3] == "" {
		t.Fatalf("an arrival mid-logoff replied %q, want 'OK <vis> <label> <n>' with no LIVE (the receiver posts the gate notice)", reply)
	}
	if strings.Contains(reply, "LIVE") {
		t.Fatalf("an arrival mid-logoff replied %q: LIVE suppresses the gate notice", reply)
	}

	deadline := time.Now().Add(15 * time.Second)
	for {
		pendingReapMu.Lock()
		reap := pendingReapUID
		pendingReapMu.Unlock()
		if reap == "11" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the sign-out never queued its reap")
		}
		time.Sleep(50 * time.Millisecond)
	}
	ackReapAction("SWITCH", "11")
	ackReapAction("REAP", "11")
	logoffDone(t, "11", 30*time.Second)
}

// In handleLogout's stored-session arm the marker's removal precedes the OK reply (and so the seal). Moving it
// after either lets liveSession answer a session during the seal, and the arrival goes LIVE with no notice.
func TestLogoffMarker_RemovedBeforeTheOKReply(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := funcBody(t, string(b), "handleLogout")
	rm, sealing, reply := -1, -1, -1
	for i, l := range body {
		s := strings.TrimSpace(l)
		if strings.HasPrefix(s, "//") {
			continue
		}
		if strings.Contains(s, `os.Remove(filepath.Join(dest, ".roamsession"))`) {
			rm = i // the LAST one is the stored-session arm (the throwaway arm's comes first)
		}
		if strings.Contains(s, "sealing in background") {
			sealing = i
		}
		if sealing >= 0 && reply < 0 && strings.Contains(s, `fmt.Fprint(conn, "OK\n")`) {
			reply = i
		}
	}
	if rm < 0 || sealing < 0 || reply < 0 {
		t.Fatalf("handleLogout's shape changed: remove=%d sealing-log=%d reply=%d", rm, sealing, reply)
	}
	if rm > reply {
		t.Errorf(".roamsession is removed after the OK reply (line %d vs %d) -- an arrival mid-logoff would go LIVE", rm, reply)
	}
	for _, l := range body[reply:] {
		if s := strings.TrimSpace(l); !strings.HasPrefix(s, "//") && strings.Contains(s, `os.Remove(filepath.Join(dest, ".roamsession"))`) {
			t.Error("handleLogout removes .roamsession again after the reply -- the marker must go before the seal")
		}
	}
}
