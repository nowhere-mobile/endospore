package main

import (
	"os"
	"strings"
	"testing"
)

// NWP-20261007-06: the session relays its next alarm to the gate the moment before a logoff or a cold lock. Waiting
// on sessionMu there, behind a periodic seal, the chooser's read gave up and the alarm silently never rang. SET is
// off sessionMu; GET stays on it (TestConcurrentSafeCmd); the two are ordered by gateAlarmMu.
func TestGateAlarmVerbsNeverWaitOnTheSession(t *testing.T) {
	if !concurrentSafeCmd("SET-GATE-ALARM") {
		t.Error("SET-GATE-ALARM waits on sessionMu: a seal running at logoff or cold lock can make the alarm relay time out")
	}
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, v := range []string{"SET-GATE-ALARM", "GET-GATE-ALARM"} {
		i := strings.Index(src, `if name == "`+v+`" {`)
		if i < 0 {
			t.Fatalf("%s handler not found", v)
		}
		h := src[i:]
		h = h[:strings.Index(h, "\n\t}\n")]
		if !strings.Contains(h, "gateAlarmMu.Lock()") || !strings.Contains(h, "gateAlarmMu.Unlock()") {
			t.Errorf("%s no longer takes gateAlarmMu: off sessionMu, a GET could clear a SET that landed in between", v)
		}
	}
}
