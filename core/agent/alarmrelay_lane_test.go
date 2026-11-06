package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

// NWP-20261108-02 (Q183): alarmrelay rides the read-only lane. The cold-lock teardown asks for it while it holds the RW
// slot; on the RW lane an abandoned (ERR-TIMEOUT) op whose roamd instance still runs made the ask answer
// ERR-WORKER-BUSY, so no alarm was relayed and the gate had nothing to ring. The seams are package vars: none of these
// tests may run in parallel.

func TestAlarmRelayRidesTheReadOnlyLaneWithATeardownSizedCap(t *testing.T) {
	if got := laneFor("alarmrelay"); got.svc != laneRO.svc {
		t.Errorf("laneFor(alarmrelay).svc = %q, want the RO lane %q", got.svc, laneRO.svc)
	}
	c := workerWaitCap("alarmrelay")
	if c <= 0 || c > coldLockAlarmWait {
		t.Errorf("workerWaitCap(alarmrelay) = %s, want 0 < cap <= coldLockAlarmWait (%s): the teardown holds the RW slot while it asks",
			c, coldLockAlarmWait)
	}
}

func TestAlarmRelayRunsWhileTheRWLaneIsAbandonedAndHeld(t *testing.T) {
	resetAbandoned(t, nil)
	release := make(chan struct{})
	f := abFakeInit(t, []abPlan{{lane: laneRW, text: "OK", release: release}, {lane: laneRO, text: "OK"}})
	abAbandon(t, f, "out")
	t.Cleanup(func() { // let the old instance answer before the fake's directory goes
		close(release)
		f.waitStopped(t, laneRW.svc)
	})

	laneRW.slot <- struct{}{} // the teardown's hold
	t.Cleanup(func() { <-laneRW.slot })

	startsBefore := len(f.snapshot())
	if out := coldLockDispatch(f.dest, "alarmrelay", "x", "", "15", "", true); out != "OK" {
		t.Fatalf("alarmrelay behind an abandoned RW op returned %q, want OK", out)
	}
	var honoured []abStart
	for _, s := range f.snapshot()[startsBefore:] {
		if !s.ignored {
			honoured = append(honoured, s)
		}
	}
	if len(honoured) != 1 || honoured[0].svc != laneRO.svc || honoured[0].reqOp != "alarmrelay" {
		t.Fatalf("starts after the abandon = %+v, want exactly one honoured start of %s carrying op alarmrelay",
			honoured, laneRO.svc)
	}
}

func TestAlarmRelayAnswersBusyWithinItsCapWhenTheROLaneIsHeld(t *testing.T) {
	resetAbandoned(t, nil)
	f := abFakeInit(t, nil)
	laneRO.slot <- struct{}{} // a storage walk
	t.Cleanup(func() { <-laneRO.slot })
	laneRW.slot <- struct{}{}
	t.Cleanup(func() { <-laneRW.slot })

	ch := make(chan string, 1)
	t0 := time.Now()
	go func() { ch <- coldLockDispatch(f.dest, "alarmrelay", "x", "", "15", "", true) }()
	select {
	case out := <-ch:
		if out != workerBusy {
			t.Fatalf("alarmrelay with the RO lane held returned %q, want %q", out, workerBusy)
		}
		if d := time.Since(t0); d > workerWaitCap("alarmrelay")+time.Second {
			t.Errorf("answered busy after %s, want within the cap (%s) plus 1s", d, workerWaitCap("alarmrelay"))
		}
	case <-time.After(6 * time.Second):
		t.Fatal("alarmrelay waited past 6s for the held RO lane -- it has no cap")
	}
}

// The two comments that state where the teardown's ops run must say the alarm rides the read-only lane: the old
// "Both run inside the RW hold" sent the next reader looking for the alarm in the RW slot, and the dispatch's
// no-deadlock argument covered only RW->Cred nesting.
func TestAlarmRelayLaneIsWhatTheTeardownCommentsSay(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	m := string(b)
	if strings.Contains(m, "// Both run inside the RW hold, like btpark below.") {
		t.Error("coldLockTeardown still says the alarm relay runs inside the RW hold; it rides the read-only lane")
	}
	for _, want := range []string{
		"\t// The sweep runs inside the RW hold, like btpark above; the alarm rides the read-only lane with its own capped\n",
		"// and RW->Cred and RW->RO nesting cannot deadlock because the lanes' slots are distinct channels\n",
	} {
		if !strings.Contains(m, want) {
			t.Errorf("main.go lost %q", want)
		}
	}
}
