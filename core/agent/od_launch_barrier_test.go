package main

import (
	"bufio"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261130-03 (RF-011): a package installed without materializeapp (nApps, Aurora, Play, sideload) reaches
// RESTORE-ODDATA with its data still in the store. A seal can hold the RW lane for minutes, so the block must run on the
// RO lane BEFORE the odrestore op waits for its slot, and nothing in the daemon may lift it after a failed fetch.

// barrierLog records the odblock and odrestore ops in the order the handler ran them.
type barrierLog struct {
	mu  sync.Mutex
	ops []string
}

func (l *barrierLog) add(op string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.ops = append(l.ops, op)
}

func (l *barrierLog) snapshot() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]string(nil), l.ops...)
}

// barrierFakes replaces both workers. restoreReply answers the odrestore op; hold (when not nil) delays it until closed.
func barrierFakes(t *testing.T, barrierReply, restoreReply string, hold <-chan struct{}, rec *struct{ pass, se, lane string }) *barrierLog {
	t.Helper()
	log := &barrierLog{}
	oldB, oldR := odBarrierWorker, odRestoreWorker
	t.Cleanup(func() { odBarrierWorker, odRestoreWorker = oldB, oldR })
	odBarrierWorker = func(dest, op, name, pass, uid, seSecret, kind, srcUnit, intent string, onProg func(string)) string {
		if rec != nil {
			rec.pass, rec.se, rec.lane = pass, seSecret, laneFor(op).svc
		}
		log.add(op + " " + srcUnit)
		return barrierReply + "\n"
	}
	odRestoreWorker = func(dest, op, name, pass, uid, seSecret, kind, srcUnit, intent string, onProg func(string)) string {
		log.add(op + " " + srcUnit)
		if hold != nil {
			<-hold
		}
		return restoreReply + "\n"
	}
	return log
}

// barrierLists makes this session's odfetch dir with one list naming pkg (empty when pkg is "").
func barrierLists(t *testing.T, dest, pkg string) string {
	t.Helper()
	dir := filepath.Join(dest, "odfetch.11")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	body := ""
	if pkg != "" {
		body = pkg + "\n"
	}
	if err := os.WriteFile(filepath.Join(dir, odUnfetchedDE), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, odUnfetchedCE), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

func barrierWaitOps(t *testing.T, log *barrierLog, n int) []string {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if ops := log.snapshot(); len(ops) >= n {
			return ops
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("waited for %d worker ops, saw %v", n, log.snapshot())
	return nil
}

// The barrier runs while odrestore is still delayed, and a failed fetch's ERR-NOTREADY sends no other op.
func TestOdBarrier_DelayedWorkerAndFailedFetch(t *testing.T) {
	dest := t.TempDir()
	odListSession(t, dest, "barrierdelay")
	barrierLists(t, dest, "org.example.parked")
	hold := make(chan struct{})
	var got struct{ pass, se, lane string }
	log := barrierFakes(t, "OK BLOCKED", "ERR-NOTREADY", hold, &got)
	lines, done := odListServe(dest, "org.example.parked")

	ops := barrierWaitOps(t, log, 2) // odrestore has started and is delayed
	if ops[0] != "odblock org.example.parked" || ops[1] != "odrestore org.example.parked" {
		t.Fatalf("op order = %v, want odblock before odrestore", ops)
	}
	if got.pass != "" || got.se != "" || got.lane != laneRO.svc {
		t.Errorf("barrier op pass=%q se=%q lane=%q, want no credential on the RO lane", got.pass, got.se, got.lane)
	}
	select {
	case l := <-lines:
		t.Fatalf("reply %q arrived while odrestore was still delayed", l)
	case <-time.After(50 * time.Millisecond):
	}
	close(hold)
	if l := <-lines; l != "ERR-NOTREADY" {
		t.Fatalf("reply = %q, want ERR-NOTREADY", l)
	}
	<-done
	if ops := log.snapshot(); len(ops) != 2 {
		t.Errorf("ops after the failed fetch = %v, want no further op (nothing lifts the block)", ops)
	}
}

// A package on neither list gets no barrier: the tap and the sweep have fetched first, so their RESTORE-ODDATA pays nothing.
func TestOdBarrier_NotListed(t *testing.T) {
	dest := t.TempDir()
	odListSession(t, dest, "barriernone")
	barrierLists(t, dest, "")
	log := barrierFakes(t, "OK BLOCKED", "OK org.example.other", nil, nil)
	lines, done := odListServe(dest, "org.example.other")
	if l := <-lines; l != "OK org.example.other" {
		t.Fatalf("reply = %q", l)
	}
	<-done
	if ops := log.snapshot(); len(ops) != 1 || ops[0] != "odrestore org.example.other" {
		t.Errorf("ops = %v, want only odrestore", ops)
	}
}

// With the dir present and a list missing, the state is unknown: the barrier runs.
func TestOdBarrier_UnreadableList(t *testing.T) {
	dest := t.TempDir()
	odListSession(t, dest, "barrierlost")
	dir := barrierLists(t, dest, "")
	if err := os.Remove(filepath.Join(dir, odUnfetchedCE)); err != nil {
		t.Fatal(err)
	}
	log := barrierFakes(t, "OK BLOCKED", "OK org.example.x", nil, nil)
	lines, done := odListServe(dest, "org.example.x")
	<-lines
	<-done
	if ops := log.snapshot(); len(ops) != 2 || ops[0] != "odblock org.example.x" {
		t.Errorf("ops = %v, want odblock then odrestore", ops)
	}
}

// A busy RO lane does not stop the restore: odrestore blocks the app itself once it has the RW slot.
func TestOdBarrier_BusyStillRestores(t *testing.T) {
	dest := t.TempDir()
	odListSession(t, dest, "barrierbusy")
	barrierLists(t, dest, "org.example.parked")
	log := barrierFakes(t, workerBusy, "OK org.example.parked", nil, nil)
	lines, done := odListServe(dest, "org.example.parked")
	if l := <-lines; l != "OK org.example.parked" {
		t.Fatalf("reply = %q", l)
	}
	<-done
	if ops := log.snapshot(); len(ops) != 2 || ops[1] != "odrestore org.example.parked" {
		t.Errorf("ops = %v, want odblock then odrestore", ops)
	}
}

// In the list form, each listed package's barrier runs before that package's own odrestore.
func TestOdBarrier_ListForm(t *testing.T) {
	dest := t.TempDir()
	odListSession(t, dest, "barrierlist")
	barrierLists(t, dest, "org.example.b")
	log := barrierFakes(t, "OK BLOCKED", "OK", nil, nil)
	lines, done := odListServe(dest, "org.example.a org.example.b")
	for range lines {
	}
	<-done
	want := []string{"odrestore org.example.a", "odblock org.example.b", "odrestore org.example.b"}
	ops := log.snapshot()
	if len(ops) != len(want) {
		t.Fatalf("ops = %v, want %v", ops, want)
	}
	for i := range want {
		if ops[i] != want[i] {
			t.Fatalf("ops = %v, want %v", ops, want)
		}
	}
}

// odblock rides the RO lane with a bound below the conn window its handler renewed.
func TestOdBarrier_Lane(t *testing.T) {
	if got := laneFor("odblock"); got.svc != laneRO.svc {
		t.Errorf("laneFor(odblock) = %q, want the RO lane", got.svc)
	}
	if c := workerWaitCap("odblock"); c <= 0 || c >= odRestoreConnWindow {
		t.Errorf("workerWaitCap(odblock) = %s, want 0 < cap < %s", c, odRestoreConnWindow)
	}
}

// RF-011: a busy RO lane does not end the barrier: the tries go on while odrestore waits for the RW lane, and end once one
// is answered.
func TestOdBarrier_BusyRetriesWhileRestoreWaits(t *testing.T) {
	old := odBarrierRetryEvery
	odBarrierRetryEvery = time.Millisecond
	t.Cleanup(func() { odBarrierRetryEvery = old })
	dest := t.TempDir()
	odListSession(t, dest, "barrierretry")
	barrierLists(t, dest, "org.example.parked")
	hold := make(chan struct{})
	log := barrierFakes(t, "", "OK org.example.parked", hold, nil)
	var mu sync.Mutex
	tries := 0
	odBarrierWorker = func(dest, op, name, pass, uid, seSecret, kind, srcUnit, intent string, onProg func(string)) string {
		mu.Lock()
		defer mu.Unlock()
		tries++
		log.add(op + " " + srcUnit)
		if tries < 3 {
			return workerBusy + "\n"
		}
		return "OK BLOCKED\n"
	}
	lines, done := odListServe(dest, "org.example.parked")
	barrierWaitOps(t, log, 4) // odrestore is queued, and three tries have run while it waits
	time.Sleep(20 * time.Millisecond)
	close(hold)
	if l := <-lines; l != "OK org.example.parked" {
		t.Fatalf("reply = %q", l)
	}
	<-done
	blocks := 0
	for _, op := range log.snapshot() {
		if op == "odblock org.example.parked" {
			blocks++
		}
	}
	if blocks != 3 {
		t.Errorf("odblock ran %d times, want 3 (two busy, one answered, none after it)", blocks)
	}
}

// RF-011: the tries end when the op returns, or a busy lane would run them for the rest of the session.
func TestOdBarrier_TriesEndWithTheRestore(t *testing.T) {
	old := odBarrierRetryEvery
	odBarrierRetryEvery = time.Millisecond
	t.Cleanup(func() { odBarrierRetryEvery = old })
	dest := t.TempDir()
	odListSession(t, dest, "barrierend")
	barrierLists(t, dest, "org.example.parked")
	log := barrierFakes(t, workerBusy, "OK org.example.parked", nil, nil)
	lines, done := odListServe(dest, "org.example.parked")
	if l := <-lines; l != "OK org.example.parked" {
		t.Fatalf("reply = %q", l)
	}
	<-done
	time.Sleep(20 * time.Millisecond) // a try in flight when the op returned ends here
	n := len(log.snapshot())
	time.Sleep(50 * time.Millisecond)
	if m := len(log.snapshot()); m != n {
		t.Errorf("odblock ran on after the restore returned: %d ops, then %d", n, m)
	}
}

// RF-011: PackageManager's refusal is the same every time, so it is not tried again, and the restore still runs.
func TestOdBarrier_RefusalIsNotRetried(t *testing.T) {
	old := odBarrierRetryEvery
	odBarrierRetryEvery = time.Millisecond
	t.Cleanup(func() { odBarrierRetryEvery = old })
	dest := t.TempDir()
	odListSession(t, dest, "barrierrefused")
	barrierLists(t, dest, "org.example.parked")
	hold := make(chan struct{})
	log := barrierFakes(t, "ERR-NOBLOCK", "ERR-NOTREADY", hold, nil)
	lines, done := odListServe(dest, "org.example.parked")
	barrierWaitOps(t, log, 2) // odrestore is waiting for the RW lane
	time.Sleep(30 * time.Millisecond)
	close(hold)
	if l := <-lines; l != "ERR-NOTREADY" {
		t.Fatalf("reply = %q", l)
	}
	<-done
	if ops := log.snapshot(); len(ops) != 2 {
		t.Errorf("ops = %v, want one odblock and one odrestore", ops)
	}
}

// RF-011: a store Get's stageapp fetches the parked data first; a stageapp that failed or found its lane busy reaches the
// chooser as its own non-OK reply, which it reads as "no install" (StoreService.getApp).
func TestFetchApp_FailedStageIsNotOK(t *testing.T) {
	for _, tc := range []struct{ profile, pkg, answer string }{
		{"fas-failed", "org.example.fasfailed", "ERR-STAGE"},
		{"fas-busy", "org.example.fasbusy", workerBusy},
	} {
		c := fahSetup(t, tc.profile, tc.pkg, "/ok.apk", tc.answer)
		if got := c.run(true)(); got != tc.answer {
			t.Errorf("reply = %q, want %q", got, tc.answer)
		}
	}
}

// odPendingAsk runs OD-DATA-PENDING over a pipe and returns its reply line.
func odPendingAsk(t *testing.T, dest, pkg string) string {
	t.Helper()
	cli, srv := net.Pipe()
	defer cli.Close()
	go func() { handleOdDataPending(srv, dest, pkg); srv.Close() }()
	l, err := bufio.NewReader(cli).ReadString('\n')
	if err != nil {
		t.Fatalf("reading the reply: %v", err)
	}
	return strings.TrimRight(l, "\n")
}

// A listed package is out; so is a package whose list line is gone but whose fetch marker stands (a nApps install waiting
// for its odrestore). A package on neither is untouched, and a lost list is UNKNOWN, never NO.
func TestOdDataPending_Reply(t *testing.T) {
	const pkg = "org.example.parked"
	barrierFakes(t, "OK BLOCKED", "OK", nil, nil) // a verb that queued a worker op must not hang this test
	dest := t.TempDir()
	odListSession(t, dest, "pendingreply")
	if got := odPendingAsk(t, dest, pkg); got != "NO" {
		t.Errorf("no odfetch dir: %q, want NO", got)
	}
	dir := barrierLists(t, dest, pkg)
	if got := odPendingAsk(t, dest, pkg); got != "YES" {
		t.Errorf("a list names it: %q, want YES", got)
	}
	if got := odPendingAsk(t, dest, "org.example.other"); got != "NO" {
		t.Errorf("on neither list: %q, want NO", got)
	}
	barrierLists(t, dest, "")
	if err := os.WriteFile(filepath.Join(dir, odPendingName(pkg)), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if got := odPendingAsk(t, dest, pkg); got != "YES" {
		t.Errorf("fetched, odrestore not finished: %q, want YES", got)
	}
	if err := os.Remove(filepath.Join(dir, odPendingName(pkg))); err != nil {
		t.Fatal(err)
	}
	if got := odPendingAsk(t, dest, pkg); got != "NO" {
		t.Errorf("odrestore finished: %q, want NO", got)
	}
	if err := os.Remove(filepath.Join(dir, odUnfetchedDE)); err != nil {
		t.Fatal(err)
	}
	if got := odPendingAsk(t, dest, pkg); got != "UNKNOWN" {
		t.Errorf("a lost list: %q, want UNKNOWN", got)
	}
	if err := os.Remove(filepath.Join(dir, odUnfetchedCE)); err != nil {
		t.Fatal(err)
	}
	if got := odPendingAsk(t, dest, pkg); got != "UNKNOWN" {
		t.Errorf("both lists lost: %q, want UNKNOWN", got)
	}
}

func TestOdDataPending_NoSessionAndBadName(t *testing.T) {
	barrierFakes(t, "OK BLOCKED", "OK", nil, nil)
	dest := t.TempDir()
	if got := odPendingAsk(t, dest, "org.example.a"); got != "NO" {
		t.Errorf("nobody signed in: %q, want NO", got)
	}
	if got := odPendingAsk(t, dest, "../x"); got != "ERR-PKG" {
		t.Errorf("a bad name: %q, want ERR-PKG", got)
	}
}

// The verb runs outside sessionMu and touches no worker lane: a test that replaced both workers would see no op.
func TestOdDataPending_TakesNoLane(t *testing.T) {
	dest := t.TempDir()
	odListSession(t, dest, "pendingfree")
	barrierLists(t, dest, "org.example.parked")
	log := barrierFakes(t, "OK BLOCKED", "OK", nil, nil)
	if got := odPendingAsk(t, dest, "org.example.parked"); got != "YES" {
		t.Fatalf("got %q", got)
	}
	if ops := log.snapshot(); len(ops) != 0 {
		t.Errorf("OD-DATA-PENDING ran worker ops %v", ops)
	}
	if !concurrentSafeCmd("OD-DATA-PENDING") {
		t.Error("OD-DATA-PENDING is serialized behind sessionMu")
	}
}

// roamd writes the marker the verb reads: the one roamd place that names it must agree with the agent.
func TestOdPendingNameMatchesRoamd(t *testing.T) {
	b, err := os.ReadFile("../vendor-common/bin/nowhere_roamd.sh")
	if err != nil {
		t.Fatal(err)
	}
	fn := regexp.MustCompile(`(?s)\nod_pending_path\(\) \{\n(.*?)\n\}`).FindSubmatch(b)
	if fn == nil {
		t.Fatal("no od_pending_path in nowhere_roamd.sh")
	}
	if !strings.Contains(string(fn[1]), `"$STATE/odfetch.$1/pending.$2"`) {
		t.Errorf("od_pending_path does not print $STATE/odfetch.<uid>/pending.<pkg>:\n%s", fn[1])
	}
	if odPendingName("a.b") != "pending.a.b" {
		t.Errorf("the agent's marker name drifted from roamd's: %s", odPendingName("a.b"))
	}
}
