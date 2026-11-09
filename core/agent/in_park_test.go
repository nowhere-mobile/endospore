package main

import (
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

// NWP-20261129-17 (docs/backlog.md, "A sign-in whose restore fails has already moved the live or cold-locked session's
// per-login state out of `$STATE`"; h59 #2): roamd keeps the park on OK, and the daemon drops it or restores it. The K4
// cases use the seams of worker_abandoned_test.go, which are package vars: none of these tests may run in parallel.

// inParkWrite creates path with body, and its parent directories.
func inParkWrite(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

// inParkPlant gives dir the six names, each holding tag, with tag as the one receipt.
func inParkPlant(t *testing.T, dir, tag string) {
	t.Helper()
	inParkWrite(t, filepath.Join(dir, "restore-receipts", "roster."+tag), tag)
	for _, n := range inParkNames[1:] {
		inParkWrite(t, filepath.Join(dir, n), tag)
	}
}

// inParkHeld returns "" when dir holds all six names as inParkPlant wrote them with tag, else what differs.
func inParkHeld(dir, tag string) string {
	ents, err := os.ReadDir(filepath.Join(dir, "restore-receipts"))
	if err != nil {
		return err.Error()
	}
	if len(ents) != 1 || ents[0].Name() != "roster."+tag {
		return "restore-receipts is not exactly roster." + tag
	}
	for _, n := range inParkNames[1:] {
		b, err := os.ReadFile(filepath.Join(dir, n))
		if err != nil {
			return err.Error()
		}
		if string(b) != tag {
			return n + " holds " + string(b)
		}
	}
	return ""
}

func inParkExists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

// K1
func TestInParkPutBackRestoresOverTheAttempt(t *testing.T) {
	dest := t.TempDir()
	park := filepath.Join(dest, inParkDir)
	inParkPlant(t, dest, "attempt")
	inParkPlant(t, park, "session")
	os.Remove(filepath.Join(park, ".fido2slots")) // the session had none, so the attempt's must not survive
	var n int
	logs := captureStderr(t, func() { n = putBackInPark(dest, "the why") })
	if n != 5 {
		t.Errorf("putBackInPark returned %d, want 5", n)
	}
	if inParkExists(park) {
		t.Error("the park survives the put-back")
	}
	if inParkExists(filepath.Join(dest, ".fido2slots")) {
		t.Error("a name the park lacks still holds the attempt's entry")
	}
	inParkWrite(t, filepath.Join(dest, ".fido2slots"), "session") // inParkHeld checks all six
	if why := inParkHeld(dest, "session"); why != "" {
		t.Errorf("the session's entries are not back: %s", why)
	}
	if want := "[logind] the why: per-login state put back (5 entries) (h59 #2)"; !strings.Contains(logs, want) {
		t.Errorf("log lacks %q:\n%s", want, logs)
	}
}

// K2
func TestInParkPutBackWithNoParkTouchesNothing(t *testing.T) {
	dest := t.TempDir()
	inParkPlant(t, dest, "live")
	var n int
	logs := captureStderr(t, func() { n = putBackInPark(dest, "the why") })
	if n != 0 {
		t.Errorf("putBackInPark returned %d, want 0", n)
	}
	if why := inParkHeld(dest, "live"); why != "" {
		t.Errorf("no park, yet $STATE changed: %s", why)
	}
	if strings.Contains(logs, "h59 #2") {
		t.Errorf("no park, yet a log line:\n%s", logs)
	}
}

// K3
func TestInParkDropLeavesTheState(t *testing.T) {
	dest := t.TempDir()
	inParkPlant(t, dest, "new")
	inParkPlant(t, filepath.Join(dest, inParkDir), "old")
	logs := captureStderr(t, func() { dropInPark(dest) })
	if inParkExists(filepath.Join(dest, inParkDir)) {
		t.Error("the park survives the drop")
	}
	if why := inParkHeld(dest, "new"); why != "" {
		t.Errorf("the drop changed $STATE: %s", why)
	}
	if strings.Count(logs, "h59 #2") != 1 {
		t.Errorf("want one log line for a park that was there:\n%s", logs)
	}
	if logs = captureStderr(t, func() { dropInPark(dest) }); strings.Contains(logs, "h59 #2") {
		t.Errorf("no park, yet a log line:\n%s", logs)
	}
}

// inParkAbandoned runs the next op on the RW lane with recorded as the abandoned op, the instance stopped, the attempt's
// entries in $STATE and a park. It returns the op's answer, and what differs from the session's entries in $STATE and in
// the park at the moment the op's request reached roamd ("" when each holds them).
func inParkAbandoned(t *testing.T, recorded, lateReply string) (out, stateDiff, parkDiff string) {
	t.Helper()
	resetAbandoned(t, map[string]string{laneRW.svc: recorded})
	f := abFakeInit(t, []abPlan{{lane: laneRW, text: "OK-NEXT"}})
	inParkPlant(t, f.dest, "attempt")
	inParkPlant(t, filepath.Join(f.dest, inParkDir), "session")
	if lateReply != "" {
		inParkWrite(t, filepath.Join(f.dest, laneRW.res), lateReply+"\n")
	}
	start := workerStart
	workerStart = func(svc string) {
		stateDiff = inParkHeld(f.dest, "session")
		parkDiff = inParkHeld(filepath.Join(f.dest, inParkDir), "session")
		start(svc)
	}
	out = abRun(t, f, "materializeapp")
	return out, stateDiff, parkDiff
}

// K4
func TestInParkAbandonedInPutsTheParkBack(t *testing.T) {
	for _, late := range []string{"OK 12", ""} { // a late OK; an instance killed before it answered
		out, state, park := inParkAbandoned(t, "in", late)
		if out != "OK-NEXT" {
			t.Fatalf("late %q: the next op answered %q, want its own answer", late, out)
		}
		if state != "" {
			t.Errorf("late %q: at the next op's start the session's entries are not back: %s", late, state)
		}
		if park == "" {
			t.Errorf("late %q: at the next op's start the park still stands", late)
		}
	}
}

func TestInParkOtherAbandonedOpsLeaveThePark(t *testing.T) {
	for _, op := range []string{"out", "(daemon start)"} {
		out, state, park := inParkAbandoned(t, op, "OK 12")
		if out != "OK-NEXT" {
			t.Fatalf("%s: the next op answered %q, want its own answer", op, out)
		}
		if state == "" {
			t.Errorf("%s: the park was put back", op)
		}
		if park != "" {
			t.Errorf("%s: the park was touched: %s", op, park)
		}
	}
}

func TestInParkStaysWhileTheAbandonedInRuns(t *testing.T) {
	resetAbandoned(t, map[string]string{laneRW.svc: "in"})
	f := abFakeInit(t, nil)
	f.setRunning(laneRW.svc, true)
	inParkPlant(t, filepath.Join(f.dest, inParkDir), "session")
	if out := abRun(t, f, "materializeapp"); out != workerBusy {
		t.Fatalf("got %q, want %q", out, workerBusy)
	}
	if why := inParkHeld(filepath.Join(f.dest, inParkDir), "session"); why != "" {
		t.Errorf("the hook ran while the instance runs: %s", why)
	}
	if got := laneAbandonedOp(laneRW); got != "in" {
		t.Errorf("the record is %q after a busy answer, want in", got)
	}
}

// K5
func TestInParkNamesMatchRoamd(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "vendor-common", "bin", "nowhere_roamd.sh"))
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	m := regexp.MustCompile(`(?m)^ +for _pn in (restore-receipts [^;]*); do$`).FindAllStringSubmatch(src, -1)
	if len(m) != 1 {
		t.Fatalf("roamd's put-back loop: found %d, want 1", len(m))
	}
	if got := strings.Fields(m[0][1]); !reflect.DeepEqual(got, inParkNames) {
		t.Errorf("roamd's put-back names %v, inParkNames %v", got, inParkNames)
	}
	const okLine = `echo "OK $uid" > "$RES"; _inres=OK`
	if strings.Count(src, okLine) != 1 {
		t.Fatalf("the in op's OK line not found exactly once: %s", okLine)
	}
	arm := src[strings.Index(src, okLine):]
	end := strings.Index(arm, "\n    fi\n")
	if end < 0 {
		t.Fatal("the end of the in op's OK arm not found")
	}
	if strings.Contains(arm[:end], `rm -rf "$PARK"`) {
		t.Errorf("the in op's OK arm removes the park:\n%s", arm[:end])
	}
}

// inParkFunc returns the text of file from the line starting `func name(` up to the next top-level closing brace.
func inParkFunc(t *testing.T, file, name string) string {
	t.Helper()
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	i := strings.Index(s, "\nfunc "+name+"(")
	if i < 0 {
		t.Fatalf("%s not found in %s", name, file)
	}
	j := strings.Index(s[i:], "\n}\n")
	if j < 0 {
		t.Fatalf("the end of %s not found", name)
	}
	return s[i : i+j]
}

// K6
func TestInParkSourcePins(t *testing.T) {
	body := inParkFunc(t, "main.go", "handleRoamIn")
	blk := regexp.MustCompile(`(?s)if err := markRoamSession\(dest, name, pass, uid, seSecret\); err != nil \{.*?\n\t\t\}`).FindString(body)
	if blk == "" {
		t.Fatal("handleRoamIn's markRoamSession failure branch not found")
	}
	put := strings.Index(blk, `putBackInPark(dest, "roam-in user "+uid+" not recorded")`)
	if reply := strings.Index(blk, `fmt.Fprint(conn, "ERR-UNRECORDED\n")`); put < 0 || reply < put {
		t.Errorf("the ERR-UNRECORDED block must put the park back before its reply:\n%s", blk)
	}
	after := body[strings.Index(body, blk)+len(blk):]
	drop := strings.Index(after, "\n\t\tdropInPark(dest)")
	reset := strings.Index(after, "resetSealSignals()")
	if drop != 0 || reset < 0 {
		t.Errorf("dropInPark must be the first statement after the marker's nil check, before resetSealSignals (drop=%d reset=%d)", drop, reset)
	}

	unread := inParkFunc(t, "locked_head.go", "roamInHeadUnreadable")
	put = strings.Index(unread, `putBackInPark(dest, "roam-in BLANK NET after the restore")`)
	if reply := strings.Index(unread, `fmt.Fprint(conn, "BLANK NET\n")`); put < 0 || reply < put {
		t.Errorf("roamInHeadUnreadable must put the park back before its reply:\n%s", unread)
	}

	held := inParkFunc(t, "main.go", "runWorkerHeld")
	hook := strings.Index(held, `putBackInPark(dest, "worker lane "+lane.svc+": the abandoned in op")`)
	clr := strings.Index(held, "clearLaneAbandoned(lane)")
	write := strings.Index(held, `writeAtomic(req+".tmp", req,`)
	if hook < 0 || clr < hook || write < clr {
		t.Errorf("the abandoned-lane hook must precede clearLaneAbandoned and the request write (hook=%d clear=%d write=%d)", hook, clr, write)
	}
}
