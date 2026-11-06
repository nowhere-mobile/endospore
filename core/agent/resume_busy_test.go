package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261023-03: a cold-lock resume whose RW lane is busy answers workerBusy, not WRONGPASS or NEEDKEY.
//
// Since NWP-20261022-02 runWorkerHeld answers ERR-WORKER-BUSY, writing nothing, while an RW op this daemon gave up on
// still runs. handleResume read every reply but OK from its two RW ops as a refusal, so the owner's right PIN was
// called wrong (or a keyed USB resume said "couldn't read your security key"), and one who gives up and signs in fresh
// has the cold-locked session reaped with its unsaved work. Busy is decided from the lane before any request is
// written, so it must read the same for a proven and an unproven entry.

// rbBusyLane marks the RW lane as holding an abandoned op whose roamd instance still runs. It is called AFTER crLock,
// so the cold-lock teardown itself is not answered busy.
func rbBusyLane(t *testing.T) {
	t.Helper()
	resetAbandoned(t, map[string]string{laneRW.svc: "out"})
	prev := workerState
	workerState = func(svc string) string { return "running" }
	t.Cleanup(func() { workerState = prev })
}

func rbResumeLines(out string) string {
	var b strings.Builder
	for _, ln := range strings.Split(out, "\n") {
		if strings.Contains(ln, "[logind] resume ") {
			b.WriteString(ln + "\n")
		}
	}
	return b.String()
}

func TestResumeBusy_AnswersBusyForProvenAndUnprovenAlike(t *testing.T) {
	for _, k := range []crKind{{name: "plain"}, {name: "pin", pin: "4821"}} {
		t.Run(k.name, func(t *testing.T) {
			logs := map[string]string{}
			wrong := "0000"
			if k.pin == "" {
				wrong = "not-the-passphrase"
			}
			for _, tc := range []string{"proven", "unproven"} {
				t.Run(tc, func(t *testing.T) {
					l := crLock(t, k)
					f := &crFake{mode: "keyguard", keyguard: l.keyguard}
					crStartFake(t, l.dest, f)
					rbBusyLane(t)
					entry := l.unlock
					if tc == "unproven" {
						entry = wrong
					}
					var got string
					out := captureStderr(t, func() { got = crResume(t, l.dest, entry) })
					if got != workerBusy {
						t.Fatalf("resume replied %q with the lane busy, want %q", got, workerBusy)
					}
					if n := len(f.verifies()); n != 0 {
						t.Errorf("%d verify request(s) reached roamd; a busy lane is answered before any is written", n)
					}
					crAssertUntouched(t, l)
					logs[tc] = rbResumeLines(out)
					for label, secret := range map[string]string{"the PIN": "4821", "the passphrase": crPass,
						"the typed wrong entry": wrong, "the marker's proof": strings.Split(string(l.marker), "\n")[5]} {
						if secret != "" && strings.Contains(out, secret) {
							t.Errorf("the log carries %s", label)
						}
					}
				})
			}
			if logs["proven"] == "" {
				t.Fatal("control failed: no resume log line was captured, so the comparison below proves nothing")
			}
			if logs["proven"] != logs["unproven"] {
				t.Errorf("a busy PROVEN entry and a busy UNPROVEN one logged differently -- the log is an oracle:"+
					"\n proven:   %q\n unproven: %q", logs["proven"], logs["unproven"])
			}
		})
	}
}

func TestResumeBusy_NFCStashIsConsumedAndNoKeyMaterialRemains(t *testing.T) {
	l := crLock(t, crKind{name: "pin+key", pin: "4821", keyed: true})
	f := &crFake{mode: "keyguard", keyguard: l.keyguard}
	crStartFake(t, l.dest, f)
	rbBusyLane(t)
	if err := os.WriteFile(filepath.Join(l.dest, ".fido2hmac.resume"), []byte(l.h1), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := crResume(t, l.dest, l.unlock); got != workerBusy {
		t.Fatalf("resume replied %q with the lane busy, want %q", got, workerBusy)
	}
	if clwExists(l.dest, ".fido2hmac.resume") {
		t.Error(".fido2hmac.resume survived a busy answer: the next attempt would skip the tap")
	}
	if n := len(f.verifies()); n != 0 {
		t.Errorf("%d verify request(s) reached roamd", n)
	}
	crAssertUntouched(t, l) // .fido2hmac gone and NOWHERE_FIDO2_HMAC unset
}

func TestResumeBusy_KeyStepOnTheUSBPathIsBusyNotNeedKey(t *testing.T) {
	l := crLock(t, crKind{name: "pin+key", pin: "4821", keyed: true})
	f := &crFake{mode: "keyguard", keyguard: l.keyguard, hmacHex: l.h1}
	crStartFake(t, l.dest, f)
	rbBusyLane(t)
	if got := crResume(t, l.dest, l.unlock); got != workerBusy {
		t.Fatalf("resume replied %q with the lane busy, want %q (NEEDKEY tells the owner their key is at fault)", got, workerBusy)
	}
	if n := len(f.opsNamed("fido2hmac")); n != 0 {
		t.Errorf("%d fido2hmac request(s) reached roamd; a busy lane is answered before any is written", n)
	}
	crAssertUntouched(t, l)
}

// CONTROL: with no lane recorded the same resume reaches roamd and a refusing keyguard still gives WRONGPASS.
func TestResumeBusy_ControlRefusalIsStillWrongpassWhenNoLaneIsBusy(t *testing.T) {
	l := crLock(t, crKind{name: "pin", pin: "4821"})
	f := &crFake{mode: "openAny", verifyOut: "FAIL"}
	crStartFake(t, l.dest, f)
	resetAbandoned(t, nil)
	if got := crResume(t, l.dest, l.unlock); got != "WRONGPASS" {
		t.Fatalf("resume replied %q against a refusing keyguard with no busy lane, want WRONGPASS", got)
	}
	if n := len(f.verifies()); n != 1 {
		t.Errorf("verify ran %d times, want 1", n)
	}
	crAssertUntouched(t, l)
}
