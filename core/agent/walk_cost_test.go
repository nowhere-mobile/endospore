package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

// NWP-20261202-15 (h49 #4 step 2): the walk cost line every incremental push logs beside the group-cache line.
// test-walk-cost.sh runs these plain and with --mutate.

// wcStubRusage makes walkCostRusage return user, sys and ok until the test ends.
func wcStubRusage(t *testing.T, user, sys time.Duration, ok bool) {
	t.Helper()
	old := walkCostRusage
	walkCostRusage = func() (time.Duration, time.Duration, bool) { return user, sys, ok }
	t.Cleanup(func() { walkCostRusage = old })
}

// wcPSI writes the PSI fixture files (name -> content) into dir and points walkCostPSIDir at dir until the test ends.
func wcPSI(t *testing.T, dir string, files map[string]string) {
	t.Helper()
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	old := walkCostPSIDir
	walkCostPSIDir = dir
	t.Cleanup(func() { walkCostPSIDir = old })
}

// wcPSIFile is one PSI file in the kernel's format; a negative full omits the full line, as an older kernel's cpu.
func wcPSIFile(some, full int64) string {
	s := "some avg10=0.00 avg60=0.00 avg300=0.00 total=" + strconv.FormatInt(some, 10) + "\n"
	if full >= 0 {
		s += "full avg10=0.00 avg60=0.00 avg300=0.00 total=" + strconv.FormatInt(full, 10) + "\n"
	}
	return s
}

func wcV(d time.Duration) walkCostVal { return walkCostVal{d, true} }

// wcPush runs one vault push and returns its whole stdout.
func wcPush(t *testing.T, name, src string) string {
	t.Helper()
	out := captureStdout(t, func() {
		defer func() {
			if r := recover(); r != nil {
				t.Errorf("push %q failed: %v", name, r)
			}
		}()
		pushProfile("s3", name, fpgPass, src)
	})
	pushFenceSeq, pushFenceSampled = 0, false // see sealDEInSession
	if t.Failed() {
		t.FailNow()
	}
	return out
}

// wcLine returns the one walk cost line of a push's stdout.
func wcLine(t *testing.T, out string) string {
	t.Helper()
	var lines []string
	for _, l := range strings.Split(out, "\n") {
		if strings.Contains(l, " walk cost: ") {
			lines = append(lines, l)
		}
	}
	if len(lines) != 1 {
		t.Fatalf("want exactly one walk cost line, got %d in:\n%s", len(lines), out)
	}
	return lines[0]
}

var wcReadRE = regexp.MustCompile(`walk cost: (\d+) group\(s\) read in `)

// wcRead parses the groups-read count of a walk cost line.
func wcRead(t *testing.T, line string) int {
	t.Helper()
	m := wcReadRE.FindStringSubmatch(line)
	if m == nil {
		t.Fatalf("no groups-read count in %q", line)
	}
	n, _ := strconv.Atoi(m[1])
	return n
}

func TestWalkCost_LineShape(t *testing.T) {
	before := walkCostSnap{user: wcV(10 * time.Second), sys: wcV(time.Second)}
	before.psi = [3][2]walkCostVal{
		{wcV(time.Second), wcV(500 * time.Millisecond)},
		{wcV(0), wcV(0)},
		{wcV(10 * time.Microsecond), wcV(7 * time.Millisecond)},
	}
	after := walkCostSnap{user: wcV(13 * time.Second), sys: wcV(1200 * time.Millisecond)}
	after.psi = [3][2]walkCostVal{
		{wcV(1250 * time.Millisecond), wcV(600 * time.Millisecond)},
		{wcV(2 * time.Millisecond), wcV(0)},
		{wcV(5*time.Second + 10*time.Microsecond), wcV(7 * time.Millisecond)},
	}
	got := walkCostLine(before, after, 7, 1500400*time.Microsecond, 4*time.Second)
	want := "walk cost: 7 group(s) read in 1.5s, rest of walk 2.5s; cpu user 3s sys 200ms; stall some/full io 250ms/100ms memory 2ms/0s cpu 5s/0s"
	if got != want {
		t.Fatalf("line:\n got %q\nwant %q", got, want)
	}
	// A read time above the walk time (clock skew between the two readings) clamps the rest to 0s.
	if got := walkCostLine(before, after, 1, 5*time.Second, 4*time.Second); !strings.Contains(got, " read in 5s, rest of walk 0s;") {
		t.Fatalf("negative rest not clamped: %q", got)
	}
}

func TestWalkCost_Delta(t *testing.T) {
	wcPSI(t, t.TempDir(), nil)
	wcStubRusage(t, 10*time.Second, time.Second, true)
	before := walkCostNow()
	wcStubRusage(t, 12500*time.Millisecond, 1250*time.Millisecond, true)
	after := walkCostNow()
	if got := walkCostLine(before, after, 0, 0, time.Second); !strings.Contains(got, "; cpu user 2.5s sys 250ms; ") {
		t.Fatalf("cpu delta: %q", got)
	}
}

func TestWalkCost_PSISomeVsFull(t *testing.T) {
	wcStubRusage(t, 0, 0, true)
	dir := t.TempDir()
	wcPSI(t, dir, map[string]string{
		"io":     wcPSIFile(1000000, 400000),
		"memory": wcPSIFile(50000, 20000),
		"cpu":    wcPSIFile(9000, 1000),
	})
	before := walkCostNow()
	wcPSI(t, dir, map[string]string{
		"io":     wcPSIFile(1300000, 500000),
		"memory": wcPSIFile(90000, 30000),
		"cpu":    wcPSIFile(16000, 4000),
	})
	after := walkCostNow()
	got := walkCostLine(before, after, 0, 0, time.Second)
	if !strings.HasSuffix(got, "; stall some/full io 300ms/100ms memory 40ms/10ms cpu 7ms/3ms") {
		t.Fatalf("stall deltas: %q", got)
	}
}

func TestWalkCost_Unknown(t *testing.T) {
	t.Run("no PSI dir", func(t *testing.T) {
		wcStubRusage(t, time.Second, time.Second, true)
		wcPSI(t, filepath.Join(t.TempDir(), "absent"), nil)
		got := walkCostLine(walkCostNow(), walkCostNow(), 0, 0, time.Second)
		if !strings.HasSuffix(got, "; cpu user 0s sys 0s; stall some/full io n/a/n/a memory n/a/n/a cpu n/a/n/a") {
			t.Fatalf("missing PSI: %q", got)
		}
	})
	t.Run("cpu without full", func(t *testing.T) {
		wcStubRusage(t, time.Second, time.Second, true)
		dir := t.TempDir()
		wcPSI(t, dir, map[string]string{"io": wcPSIFile(1000, 1000), "memory": wcPSIFile(1000, 1000), "cpu": wcPSIFile(1000, -1)})
		before := walkCostNow()
		wcPSI(t, dir, map[string]string{"io": wcPSIFile(3000, 2000), "memory": wcPSIFile(4000, 1000), "cpu": wcPSIFile(3000, -1)})
		got := walkCostLine(before, walkCostNow(), 0, 0, time.Second)
		if !strings.HasSuffix(got, "; stall some/full io 2ms/1ms memory 3ms/0s cpu 2ms/n/a") {
			t.Fatalf("cpu full line missing: %q", got)
		}
	})
	t.Run("unparsable total", func(t *testing.T) {
		wcStubRusage(t, time.Second, time.Second, true)
		dir := t.TempDir()
		bad := "some avg10=0.00 avg60=0.00 avg300=0.00 total=5000\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=x\n"
		wcPSI(t, dir, map[string]string{"io": wcPSIFile(0, 0), "memory": bad, "cpu": wcPSIFile(0, 0)})
		before := walkCostNow()
		wcPSI(t, dir, map[string]string{"memory": "some avg10=0.00 avg60=0.00 avg300=0.00 total=9000\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=x\n"})
		got := walkCostLine(before, walkCostNow(), 0, 0, time.Second)
		if !strings.HasSuffix(got, "; stall some/full io 0s/0s memory 4ms/n/a cpu 0s/0s") {
			t.Fatalf("unparsable total: %q", got)
		}
	})
	t.Run("rusage fails", func(t *testing.T) {
		wcPSI(t, t.TempDir(), nil)
		wcStubRusage(t, 0, 0, false)
		got := walkCostLine(walkCostNow(), walkCostNow(), 0, 0, time.Second)
		if !strings.Contains(got, "; cpu user n/a sys n/a; ") {
			t.Fatalf("failed rusage: %q", got)
		}
	})
}

func TestWalkCost_GroupsRead(t *testing.T) {
	t.Setenv("NOWHERE_SEAL_FULL_EVERY", "0") // forceFull pinned off
	fpgEnv(t, "wc-groups-read")
	src := gcTree(t, 5, 10)
	if n := wcRead(t, wcLine(t, wcPush(t, "wc-groups-read", src))); n <= 0 {
		t.Fatalf("first push read %d group(s), want > 0", n)
	}
	l := wcLine(t, wcPush(t, "wc-groups-read", src))
	if !strings.Contains(l, " 0 group(s) read in ") {
		t.Fatalf("no-change push: %q", l)
	}
	t.Logf("no-change push: %s", l)
	p := filepath.Join(src, "d2", "f", "003.txt")
	mt := gcBase.Add(77 * time.Hour)
	if err := os.Chtimes(p, mt, mt); err != nil {
		t.Fatal(err)
	}
	if l := wcLine(t, wcPush(t, "wc-groups-read", src)); !strings.Contains(l, " 1 group(s) read in ") {
		t.Fatalf("one-file change: %q", l)
	}
}

func TestWalkCost_ReadResetPerWalk(t *testing.T) {
	gcReset(t)
	src := gcTree(t, 5, 10)
	sc := newFileScanCache(gcDK(t.Name()))
	store := map[string][]byte{}
	o := gcWalk(t, src, sc, store, false)
	if n, _ := sc.groupReadStats(); n <= 0 {
		t.Fatalf("first walk read %d group(s), want > 0", n)
	}
	gcRefresh(sc, o)
	gcWalk(t, src, sc, store, false)
	if n, d := sc.groupReadStats(); n != 0 || d != 0 {
		t.Fatalf("second walk over the same cache: %d group(s) read in %s, want 0 in 0s", n, d)
	}
}

func TestWalkCost_OneLinePerPush(t *testing.T) {
	t.Setenv("NOWHERE_SEAL_FULL_EVERY", "0")
	fpgEnv(t, "wc-one-line")
	src := gcTree(t, 3, 4)
	for i := 0; i < 2; i++ {
		out := wcPush(t, "wc-one-line", src)
		lines := strings.Split(out, "\n")
		n := 0
		for j, l := range lines {
			if !strings.Contains(l, " walk cost: ") {
				continue
			}
			n++
			if j == 0 || !strings.Contains(lines[j-1], " group cache: ") {
				t.Fatalf("push %d: the walk cost line does not follow the group-cache line:\n%s", i+1, out)
			}
			if !strings.HasPrefix(l, "push: profile ") || strings.Contains(l, "d0/") || strings.Contains(l, ".txt") {
				t.Fatalf("push %d: line shape or a rel: %q", i+1, l)
			}
		}
		if n != 1 {
			t.Fatalf("push %d: %d walk cost line(s), want 1:\n%s", i+1, n, out)
		}
	}
}
