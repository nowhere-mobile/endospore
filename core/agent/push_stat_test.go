package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261123-06: the push stat each push leaves for roamd, and the seal split the daemon appends to the periodic
// seal line (push_stat.go).

// zeroCapFlushForPushStat zeroes the process-global capFlush figures for one test and restores them after it. They
// are only ever added to, and every test in the package shares them (the TestPushClockSplit pattern).
func zeroCapFlushForPushStat(t *testing.T) {
	t.Helper()
	n, w, b := atomic.LoadInt64(&capFlushNanos), atomic.LoadInt64(&capFlushWallNanos), atomic.LoadInt64(&capFlushBytes)
	t.Cleanup(func() {
		atomic.StoreInt64(&capFlushNanos, n)
		atomic.StoreInt64(&capFlushWallNanos, w)
		atomic.StoreInt64(&capFlushBytes, b)
	})
	atomic.StoreInt64(&capFlushNanos, 0)
	atomic.StoreInt64(&capFlushWallNanos, 0)
	atomic.StoreInt64(&capFlushBytes, 0)
}

// pushStatFreshCaches gives a pushing test its own blob and content caches.
func pushStatFreshCaches(t *testing.T) {
	t.Helper()
	blobCache = nil
	contentCache = nil
	contentCacheLoadedTag = ""
	atomic.StoreInt64(&contentCacheHits, 0)
	atomic.StoreInt64(&blobCacheHits, 0)
	t.Setenv("NOWHERE_BLOBCACHE", t.TempDir())
}

var pushStatLine = regexp.MustCompile(`^kib=[0-9]+ up=[0-9]+ local=[0-9]+\n$`)

func TestPushStatFiguresMatchPushSplit(t *testing.T) {
	zeroCapFlushForPushStat(t)
	atomic.StoreInt64(&capFlushNanos, int64(5*time.Second))
	atomic.StoreInt64(&capFlushWallNanos, int64(5*time.Second))
	atomic.StoreInt64(&capFlushBytes, 2048<<10)
	t0 := time.Now().Add(-10 * time.Second)
	kib, up, local := pushStatFigures(t0)
	if kib != 2048 || up != 5000 || local < 4900 || local > 6000 {
		t.Fatalf("pushStatFigures = kib %d up %d local %d, want 2048, 5000, about 5000", kib, up, local)
	}
	if got, want := pushSplit(t0), "upload 5s/2048KiB, local "; !strings.HasPrefix(got, want) {
		t.Fatalf("pushSplit = %q, want prefix %q (the same figures)", got, want)
	}
	atomic.StoreInt64(&capFlushNanos, int64(time.Hour))
	if _, _, local := pushStatFigures(time.Now()); local != 0 {
		t.Fatalf("local = %d for an upload longer than the push, want 0 (pushSplit's clamp)", local)
	}
}

func TestPushStatWriterFormat(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "pushstat.vault")
	if err := writePushStat(p, 12, 345, 6789); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "kib=12 up=345 local=6789\n" {
		t.Fatalf("push stat = %q, want %q", b, "kib=12 up=345 local=6789\n")
	}
	ents, _ := os.ReadDir(d)
	if len(ents) != 1 {
		t.Fatalf("the writer left %d entries, want only the stat file (no .tmp)", len(ents))
	}
}

func pushStatSource(t *testing.T) string {
	t.Helper()
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f"), []byte("push stat payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	return src
}

func TestPushStatFromPushWhenSet(t *testing.T) {
	zeroCapFlushForPushStat(t)
	pushStatFreshCaches(t)
	base := newHTTPStore(t)
	name, pass := "pstatset", "push stat set horse battery staple"
	createVault(base, name, pass)
	p := filepath.Join(t.TempDir(), "pushstat.vault")
	t.Setenv("NOWHERE_PUSH_STAT", p)
	pushProfile(base, name, pass, pushStatSource(t))
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("a push with NOWHERE_PUSH_STAT set wrote no stat file: %v", err)
	}
	if !pushStatLine.Match(b) {
		t.Fatalf("push stat = %q, want kib=<n> up=<n> local=<n>", b)
	}
}

func TestPushStatNotWrittenWhenUnset(t *testing.T) {
	zeroCapFlushForPushStat(t)
	pushStatFreshCaches(t)
	base := newHTTPStore(t)
	name, pass := "pstatunset", "push stat unset horse battery staple"
	createVault(base, name, pass)
	d := t.TempDir()
	t.Setenv("NOWHERE_PUSH_STAT", "")
	cwd, _ := os.Getwd()
	if err := os.Chdir(d); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chdir(cwd) })
	pushProfile(base, name, pass, pushStatSource(t))
	if ents, _ := os.ReadDir(d); len(ents) != 0 {
		t.Fatalf("NOWHERE_PUSH_STAT unset, yet the push wrote %d file(s)", len(ents))
	}
}

// TestPushStatNoChangeMediaPushIsZeroKiB pins the stat FILE for a no-change #media push. Against newHTTPStore
// (direct mode) capFlush never runs, so kib is 0 for EVERY push, the first one too: this test does not prove that the
// push uploaded nothing. What it pins (NOWHERE-1442) is that a no-change #media push still WRITES its stat file, so
// roamd prints media=<ms>ms/0KiB and not media=<ms>ms/?KiB. A no-change early return in pushProfile must set summary
// (or write the stat) to keep this passing.
func TestPushStatNoChangeMediaPushIsZeroKiB(t *testing.T) {
	zeroCapFlushForPushStat(t)
	pushStatFreshCaches(t)
	base := newHTTPStore(t)
	name, pass := "pstatmedia", "push stat media horse battery staple"
	createVault(base, name, pass)
	src := pushStatSource(t)
	p := filepath.Join(t.TempDir(), "pushstat.media")
	t.Setenv("NOWHERE_PUSH_STAT", p)
	pushProfile(base, name+"#media", pass, src)
	os.Remove(p)
	pushProfile(base, name+"#media", pass, src) // the same tree: nothing changed
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("a no-change #media push wrote no stat file, so roamd would print media=<ms>ms/?KiB: %v", err)
	}
	if !strings.HasPrefix(string(b), "kib=0 up=0 local=") || !pushStatLine.Match(b) {
		t.Fatalf("no-change #media push stat = %q, want kib=0 up=0 local=<n>", b)
	}
}

func plantSealSplit(t *testing.T, dest, s string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dest, sealSplitFile), []byte(s), 0o600); err != nil {
		t.Fatal(err)
	}
}

const sealSplitGood = "vault=1200ms/11KiB,de=300ms/22KiB,media=4500ms/0KiB,sys=80ms/?KiB,apps=stage 900ms+push 1500ms/55KiB"

func TestSealSplitReaderGuard(t *testing.T) {
	for _, c := range []struct{ why, in, want string }{
		{"a valid split", sealSplitGood + "\n", sealSplitGood},
		{"a valid split without a newline", sealSplitGood, sealSplitGood},
		{"a profile-like string (upper case)", "vault=1ms/2KiB,Alice", ""},
		{"a profile-like string (lower case)", "vault=1ms/2KiB,alice", ""},
		{"a profile-like label", "alice=1ms/2KiB", ""},
		{"a profile-like string (lower case, with a quote)", `vault=1ms/2KiB,"alice"`, ""},
		{"a path", "/data/user/10", ""},
		{"a pipe", "vault=1ms/2KiB|de", ""},
		{"a second line", "vault=1ms/2KiB\nde=1ms/2KiB", ""},
		{"300 bytes", strings.Repeat("a", 300), ""},
		{"300 bytes of valid entries", strings.Repeat("de=1ms/2KiB,", 25) + "de=1ms/2KiB", ""},
		{"an empty file", "", ""},
	} {
		dest := t.TempDir()
		plantSealSplit(t, dest, c.in)
		if got := readSealSplit(dest); got != c.want {
			t.Errorf("%s: readSealSplit = %q, want %q", c.why, got, c.want)
		}
		if got := takeSealSplit(dest); got != c.want {
			t.Errorf("%s: takeSealSplit = %q, want %q", c.why, got, c.want)
		}
		if _, err := os.Stat(filepath.Join(dest, sealSplitFile)); !os.IsNotExist(err) {
			t.Errorf("%s: takeSealSplit left the seal-split file (err %v); every row must remove it", c.why, err)
		}
	}
	if got := readSealSplit(t.TempDir()); got != "" {
		t.Errorf("no file: readSealSplit = %q, want empty", got)
	}
	exact := "vault=" + strings.Repeat("1", sealSplitMax-13) + "ms/0KiB" // a valid entry of exactly 256 bytes
	dest := t.TempDir()
	plantSealSplit(t, dest, exact+"\n")
	if got := readSealSplit(dest); got != exact {
		t.Errorf("a 256-byte split is inside the bound: readSealSplit = %d bytes, want %d", len(got), len(exact))
	}
	plantSealSplit(t, dest, "vault="+strings.Repeat("1", sealSplitMax-12)+"ms/0KiB\n")
	if got := readSealSplit(dest); got != "" {
		t.Errorf("a valid entry of 257 bytes: readSealSplit = %d bytes, want it dropped", len(got))
	}
}

// sealSplitPeriodicLine builds the periodic line the way syncLoop does.
func sealSplitPeriodicLine(name, uid, out, split string) string {
	return fmt.Sprintf("[logind] periodic seal %q user %s -> %s%s\n", name, uid, sealVerdictLog(out),
		sealSplitSuffixFor(out, split))
}

func TestSealSplitDaemonLine(t *testing.T) {
	name, uid := "sealsplitline", "10"
	old := fmt.Sprintf("[logind] periodic seal %q user %s -> %s\n", name, uid, sealVerdictLog("OK"))
	dest := t.TempDir()
	if got := sealSplitPeriodicLine(name, uid, "OK", takeSealSplit(dest)); got != old {
		t.Fatalf("no seal-split file: line = %q, want today's %q byte for byte", got, old)
	}
	plantSealSplit(t, dest, sealSplitGood+"\n")
	want := strings.TrimSuffix(old, "\n") + " split: " + sealSplitGood + "\n"
	if got := sealSplitPeriodicLine(name, uid, "OK", takeSealSplit(dest)); got != want {
		t.Fatalf("with a seal-split file: line = %q, want %q", got, want)
	}
	if _, err := os.Stat(filepath.Join(dest, sealSplitFile)); !os.IsNotExist(err) {
		t.Fatalf("the daemon left seal-split behind (err %v): the next periodic line would print this save's split", err)
	}
	if got := sealSplitPeriodicLine(name, uid, "OK", takeSealSplit(dest)); got != old {
		t.Fatalf("the next cycle read a removed split: line = %q, want %q", got, old)
	}
}

// TestSealSplitVerdictGate: a split prints only beside a verdict roamd's out arm wrote in this run. Any other reply
// comes from the daemon without that arm, so a planted file then belongs to another run and the line stays as today.
func TestSealSplitVerdictGate(t *testing.T) {
	name, uid := "sealsplitgate", "10"
	for _, c := range []struct {
		out   string
		split bool
	}{
		{"ERR-TIMEOUT", false},
		{"SKIP-SUPERSEDED", false},
		{"SKIP-REAPING", false},
		{"SKIP-ENDED", false},
		{"ERR-LANE", false},
		{workerBusy, false},
		{"ERR-REQ", false},
		{"OK", true},
		{"OK PARTIAL:apps=refused", true},
		{"SKIP-STOPPED", true},
		{"ERR-NOCREDIT", true},
		{"ERR-REFUSED PARTIAL:x", true},
		{"ERR-PUSH", true},
	} {
		dest := t.TempDir()
		plantSealSplit(t, dest, sealSplitGood+"\n")
		split := takeSealSplit(dest)
		got := sealSplitPeriodicLine(name, uid, c.out, split)
		old := fmt.Sprintf("[logind] periodic seal %q user %s -> %s\n", name, uid, sealVerdictLog(c.out))
		want := old
		if c.split {
			want = strings.TrimSuffix(old, "\n") + " split: " + sealSplitGood + "\n"
		}
		if got != want {
			t.Errorf("out %q: line = %q, want %q (a stale split must not print beside a reply roamd's out arm did not write)", c.out, got, want)
		}
		if _, err := os.Stat(filepath.Join(dest, sealSplitFile)); !os.IsNotExist(err) {
			t.Errorf("out %q: seal-split not removed (err %v)", c.out, err)
		}
	}
}

// TestSealSplitSyncLoopDiscardsFirst pins syncLoop's order: drop any earlier run's split before the periodic run,
// take this run's after it, and print it through the verdict-gated formatter. Without the discard a sign-out's or a
// timed-out run's split would print beside the next periodic save.
func TestSealSplitSyncLoopDiscardsFirst(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "\nfunc syncLoop(")
	if i < 0 {
		t.Fatal("syncLoop not found in main.go")
	}
	body := src[i+1:]
	if j := strings.Index(body, "\nfunc "); j >= 0 {
		body = body[:j]
	}
	k := strings.Index(body, "out := func() (out string) {")
	if k < 0 {
		t.Fatal("syncLoop's periodic run (out := func() (out string) {) not found")
	}
	lo := k - 400
	if lo < 0 {
		lo = 0
	}
	before, after := body[lo:k], body[k:]
	discard := regexp.MustCompile(`(?m)^\s*takeSealSplit\(dest\)\s*$`)
	if !discard.MatchString(before) {
		t.Error("syncLoop does not discard an earlier run's seal-split (a bare takeSealSplit(dest)) before the periodic run: a stale split would print beside this save")
	}
	if !strings.Contains(after, "split := takeSealSplit(dest)") {
		t.Error("syncLoop does not take this run's seal-split (split := takeSealSplit(dest)) after the periodic run")
	}
	if !strings.Contains(after, `"[logind] periodic seal %q user %s -> %s%s\n"`) ||
		!strings.Contains(after, "sealSplitSuffixFor(out, split)") {
		t.Error("the periodic seal line does not print the split through sealSplitSuffixFor(out, split)")
	}
}
