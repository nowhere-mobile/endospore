package main

import (
	"bytes"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261117-20 (#53, decided 2026-10-22): FETCH-APP holds periodic seals back from the tap until its stageapp
// replies, with the per-package materialise lease (od_window.go). The lease is opened after the entry checks,
// renewed while the handler runs, held for the install after an OK the chooser read, and ended on every other exit.
// Every case runs the handler through the stageapp lane against startOdWorker, and asserts states, never wall time.

var fahBody = bytes.Repeat([]byte("h"), 8<<10)

// fahServer serves fahBody at /ok.apk, the same body held until release at /held.apk, and a 500 at /fail.apk.
type fahServer struct {
	srv     *httptest.Server
	started chan struct{}
	release chan struct{}
	once    sync.Once
	onFail  func() // runs inside the /fail.apk handler, before the 500
}

func (s *fahServer) releaseAll() { s.once.Do(func() { close(s.release) }) }

// fahServe starts the server. srv.Close's cleanup is registered before the release's, so the release runs first.
func fahServe(t *testing.T) *fahServer {
	t.Helper()
	s := &fahServer{started: make(chan struct{}, 1), release: make(chan struct{})}
	mux := http.NewServeMux()
	mux.HandleFunc("/ok.apk", func(w http.ResponseWriter, r *http.Request) { w.Write(fahBody) })
	mux.HandleFunc("/held.apk", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		select {
		case s.started <- struct{}{}:
		default:
		}
		select {
		case <-s.release:
			w.Write(fahBody)
		case <-r.Context().Done():
		}
	})
	mux.HandleFunc("/fail.apk", func(w http.ResponseWriter, r *http.Request) {
		if s.onFail != nil {
			s.onFail()
		}
		http.Error(w, "no", http.StatusInternalServerError)
	})
	s.srv = httptest.NewServer(mux)
	t.Cleanup(s.srv.Close)
	t.Cleanup(s.releaseAll)
	return s
}

// fahStage records what the fake worker saw: the ops, and pkg's lease while the stage op ran.
type fahStage struct {
	mu    sync.Mutex
	ops   []string
	lease time.Time
}

func (f *fahStage) seen() ([]string, time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.ops...), f.lease
}

// fahCase is one test's fixture: a goSafe tracker, the od state with a one-minute fetch lease and no renewal in the
// test's lifetime, a server, a catalog entry for pkg at route, a session, and a worker answering stageapp with answer.
type fahCase struct {
	pkg       string
	dest      string
	raiseDest string
	srv       *fahServer
	stage     *fahStage
}

func fahSetup(t *testing.T, profile, pkg, route, answer string) *fahCase {
	t.Helper()
	tr := trackGoSafe(t)
	t.Cleanup(func() { tr.wait(t, 5*time.Second) })
	odState(t)
	odFetchLease, odRenewEvery, odInstallLease = time.Minute, time.Hour, 10*time.Minute
	c := &fahCase{pkg: pkg, srv: fahServe(t), stage: &fahStage{}}
	c.dest, _, c.raiseDest = fsoFixture(t, profile, pkg,
		[]catalogAPK{{Name: "base.apk", URL: c.srv.srv.URL + route, Sha256: fabSha(fahBody), Size: int64(len(fahBody))}},
		30*time.Second)
	startOdWorker(t, c.dest, 0, func(op string) string {
		c.stage.mu.Lock()
		c.stage.ops = append(c.stage.ops, op)
		c.stage.lease = odLease(pkg)
		c.stage.mu.Unlock()
		if strings.HasPrefix(op, "stageapp") {
			return answer
		}
		return "ERR-UNEXPECTED"
	})
	return c
}

// run starts FETCH-APP for the case's package. read=false closes the client end at once, as a chooser that timed out
// or died leaves it; the handler writes nothing before its final reply. The returned func waits for the handler.
func (c *fahCase) run(read bool) func() string {
	cli, srv := net.Pipe()
	done := make(chan struct{})
	go func() {
		handleFetchApp(srv, c.dest, c.pkg+" 3")
		srv.Close()
		close(done)
	}()
	if !read {
		cli.Close()
		return func() string { <-done; return "" }
	}
	got := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(cli)
		got <- strings.TrimSpace(string(b))
	}()
	return func() string { <-done; return <-got }
}

// stagedLive asserts the worker saw exactly one stageapp op and that pkg's lease was live while it ran.
func (c *fahCase) stagedLive(t *testing.T) {
	t.Helper()
	ops, lease := c.stage.seen()
	if len(ops) != 1 || !strings.HasPrefix(ops[0], "stageapp") {
		t.Fatalf("the worker saw %q, want one stageapp", ops)
	}
	if lease.IsZero() {
		t.Errorf("%s held no seal-hold lease while its stageapp ran", c.pkg)
	}
}

func (c *fahCase) leaseEnded(t *testing.T, why string) {
	t.Helper()
	if l := odLease(c.pkg); !l.IsZero() {
		t.Errorf("%s: %s's lease is still live until %v, want it ended", why, c.pkg, l)
	}
}

func fahWaitStarted(t *testing.T, s *fahServer) {
	t.Helper()
	select {
	case <-s.started:
	case <-time.After(10 * time.Second):
		s.releaseAll()
		t.Fatal("the download never started")
	}
}

// fahHoldSlot takes the RW lane's slot, as a periodic seal holding it would, and frees it in Cleanup if the test did
// not. The returned func frees it.
func fahHoldSlot(t *testing.T) func() {
	t.Helper()
	laneRW.slot <- struct{}{}
	var once sync.Once
	free := func() { once.Do(func() { <-laneRW.slot }) }
	t.Cleanup(free)
	return free
}

func TestFetchAppHold_HeldDuringTheDownload(t *testing.T) {
	c := fahSetup(t, "fah-held", "org.example.fahheld", "/held.apk", "OK")
	wait := c.run(true)
	fahWaitStarted(t, c.srv)
	if !odLive() {
		t.Error("no materialise window is live while the store Get downloads")
	}
	if r := periodicAt(time.Now()); r != "materialise" {
		t.Errorf("periodic seal defer reason during the download = %q, want materialise", r)
	}
	c.srv.releaseAll()
	if got := wait(); got != "OK "+c.pkg+" "+fsoSigner {
		t.Fatalf("reply = %q, want OK", got)
	}
	c.stagedLive(t)
}

func TestFetchAppHold_RenewsWhileInFlight(t *testing.T) {
	c := fahSetup(t, "fah-renew", "org.example.fahrenew", "/ok.apk", "OK")
	odRenewEvery = 20 * time.Millisecond
	renewed := make(chan struct{}, 1)
	odRenewHook = func() {
		select {
		case renewed <- struct{}{}:
		default:
		}
	}
	free := fahHoldSlot(t)
	wait := c.run(true)
	select {
	case <-renewed:
	case <-time.After(10 * time.Second):
		free()
		wait()
		t.Fatal("the store Get's lease was never renewed while its stageapp waited for the slot")
	}
	free()
	if got := wait(); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("reply = %q, want OK", got)
	}
	c.stagedLive(t)
}

func TestFetchAppHold_OKHoldsTheInstallLease(t *testing.T) {
	c := fahSetup(t, "fah-ok", "org.example.fahok", "/ok.apk", "OK")
	if got := c.run(true)(); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("reply = %q, want OK", got)
	}
	c.stagedLive(t)
	// The open and any renewal reach at most their tick + odFetchLease, and every tick was before this time.Now(),
	// so only the install lease (now + 10 min) can put the lease past it.
	if l := odLease(c.pkg); !l.After(time.Now().Add(odFetchLease)) {
		t.Errorf("after an OK the chooser read, %s's lease ends %v, want the install lease (past %v from now)",
			c.pkg, l, odFetchLease)
	}
	if !odLive() {
		t.Error("no materialise window is live for the install")
	}
}

func TestFetchAppHold_ErrStageEndsTheLease(t *testing.T) {
	c := fahSetup(t, "fah-stage", "org.example.fahstage", "/ok.apk", "ERR-STAGE")
	if got := c.run(true)(); got != "ERR-STAGE" {
		t.Fatalf("reply = %q, want ERR-STAGE", got)
	}
	c.stagedLive(t)
	c.leaseEnded(t, "ERR-STAGE")
}

func TestFetchAppHold_ErrFetchEndsTheLease(t *testing.T) {
	c := fahSetup(t, "fah-fetch", "org.example.fahfetch", "/fail.apk", "OK")
	var during time.Time
	c.srv.onFail = func() { during = odLease(c.pkg) }
	if got := c.run(true)(); got != "ERR-FETCH" {
		t.Fatalf("reply = %q, want ERR-FETCH", got)
	}
	if during.IsZero() {
		t.Errorf("%s held no seal-hold lease during its download", c.pkg)
	}
	if ops, _ := c.stage.seen(); len(ops) != 0 {
		t.Errorf("the worker saw %q after a failed download, want nothing", ops)
	}
	c.leaseEnded(t, "ERR-FETCH")
}

func TestFetchAppHold_ErrCancelledEndsTheLease(t *testing.T) {
	c := fahSetup(t, "fah-cancel", "org.example.fahcancel", "/held.apk", "OK")
	wait := c.run(true)
	fahWaitStarted(t, c.srv)
	if l := odLease(c.pkg); l.IsZero() {
		t.Errorf("%s held no seal-hold lease during its download", c.pkg)
	}
	signOutRaise(c.raiseDest)
	if got := wait(); got != "ERR-CANCELLED" {
		t.Fatalf("reply = %q, want ERR-CANCELLED", got)
	}
	c.leaseEnded(t, "ERR-CANCELLED")
}

func TestFetchAppHold_UnreadReplyEndsTheLease(t *testing.T) {
	c := fahSetup(t, "fah-unread", "org.example.fahunread", "/ok.apk", "OK")
	c.run(false)()
	c.stagedLive(t)
	c.leaseEnded(t, "an OK the chooser never read")
}

func TestFetchAppHold_OtherPackageUntouched(t *testing.T) {
	c := fahSetup(t, "fah-other", "org.example.fahone", "/ok.apk", "ERR-STAGE")
	const other = "org.example.fahother"
	now := time.Now()
	settleOdMaterialise(other, beginOdMaterialise(other, now), odInstalling, now)
	before := odLease(other)
	if before.IsZero() {
		t.Fatal("the other package's install lease did not open")
	}
	if got := c.run(true)(); got != "ERR-STAGE" {
		t.Fatalf("reply = %q, want ERR-STAGE", got)
	}
	c.stagedLive(t)
	c.leaseEnded(t, "ERR-STAGE")
	if after := odLease(other); !after.Equal(before) {
		t.Errorf("the other package's lease moved from %v to %v", before, after)
	}
}

func TestFetchAppHold_StageWaitsBehindTheSlot(t *testing.T) {
	c := fahSetup(t, "fah-slot", "org.example.fahslot", "/ok.apk", "OK")
	free := fahHoldSlot(t)
	wait := c.run(true)
	for deadline := time.Now().Add(10 * time.Second); userOpWaiting.Load() == 0; time.Sleep(5 * time.Millisecond) {
		if time.Now().After(deadline) {
			free()
			wait()
			t.Fatal("the stageapp never queued for the RW slot")
		}
	}
	if ops, _ := c.stage.seen(); len(ops) != 0 {
		t.Errorf("the worker ran %q while the slot was held", ops)
	}
	if !odLive() {
		t.Error("no materialise window is live while the stageapp waits for the slot")
	}
	if r := periodicAt(time.Now()); r != "materialise" {
		t.Errorf("periodic seal defer reason while the stageapp waits = %q, want materialise", r)
	}
	free()
	if got := wait(); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("reply = %q, want OK", got)
	}
	c.stagedLive(t)
}
