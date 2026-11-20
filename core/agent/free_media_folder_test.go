package main

import (
	"bufio"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261207-14 (h51 #4): FREE-MEDIA-FOLDER frees one top-level folder's streamed copies and nothing else. The
// handler cases drive the real verb over a pipe against a worker fake that records each op and the key list it saw.
// None may run in parallel (the RW lane and freeMediaFolderMu are package state).

// fmfKeysManifest holds a deferred file in every shape the folder filter must tell apart, plus an Ess file whose
// chunks would make a cache key if the filter ever read the essential index.
func fmfKeysManifest() chunkManifest {
	return chunkManifest{
		Chunks: []string{"e1", "e2"},
		Sizes:  []int64{1, 1},
		EssIdx: true,
		Ess:    map[string]essRegion{"Download/g": {S: 0, E: 2}},
		Deferred: map[string]deferredFile{
			"Download/a":        {Chunks: []string{"c1", "c2"}},
			"Download/sub/b":    {Chunks: []string{"c3"}},
			"Download/c":        {Chunks: []string{"c1", "c2"}},
			"Downloads/d":       {Chunks: []string{"c4"}},
			"Pictures/e":        {Chunks: []string{"c5"}},
			"x":                 {Chunks: []string{"c6"}},
			"Android/data/p/f":  {Chunks: []string{"c7"}},
			"Android/media/q/h": {Chunks: []string{"c8"}},
		},
	}
}

func fmfKey(chunks ...string) string { return cacheKey(deferredFile{Chunks: chunks}) }

// fmfDownloadKeys is "Download"'s two cache keys, sorted.
func fmfDownloadKeys() []string {
	k := []string{fmfKey("c1", "c2"), fmfKey("c3")}
	sort.Strings(k)
	return k
}

// fmfWorker answers the RW lane, records each op and, for a freemediakeys request, the key list on disk at that
// moment. With a gate it waits on the gate before it reads the list.
type fmfWorker struct {
	mu    sync.Mutex
	ops   []string
	lists []string
}

func (w *fmfWorker) snapshot() ([]string, []string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]string(nil), w.ops...), append([]string(nil), w.lists...)
}

func startFreeMediaKeysWorker(t *testing.T, dest, answer string, gate chan struct{}) *fmfWorker {
	t.Helper()
	w := &fmfWorker{}
	done, finished := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(finished)
		for {
			if b, err := os.ReadFile(filepath.Join(dest, laneRW.req)); err == nil && strings.Count(string(b), "\n") >= 7 {
				os.Remove(filepath.Join(dest, laneRW.req))
				op := strings.SplitN(string(b), "\n", 2)[0]
				w.mu.Lock()
				w.ops = append(w.ops, op)
				w.mu.Unlock()
				if op == "freemediakeys" {
					if gate != nil {
						select {
						case <-gate:
						case <-done:
							return
						}
					}
					l, err := os.ReadFile(freeMediaKeysPath(dest))
					if err != nil {
						l = []byte("<no list>")
					}
					w.mu.Lock()
					w.lists = append(w.lists, string(l))
					w.mu.Unlock()
				}
				os.WriteFile(filepath.Join(dest, laneRW.res), []byte(answer+"\n"), 0o600)
			}
			select {
			case <-done:
				return
			case <-time.After(10 * time.Millisecond):
			}
		}
	}()
	t.Cleanup(func() { close(done); <-finished })
	return w
}

// fmfSetup makes a state dir with a live session marker and a seam that answers m (ok as given).
func fmfSetup(t *testing.T, profile string, m chunkManifest, ok bool) string {
	t.Helper()
	dest := t.TempDir()
	t.Setenv("NOWHERE_STATE", dest)
	resetAbandoned(t, nil)
	if err := os.WriteFile(filepath.Join(dest, ".roamsession"), []byte(profile+"\npass-"+profile+"\n10\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := freeMediaManifestOf
	freeMediaManifestOf = func(base, p, pass string, se []byte) (chunkManifest, bool) { return m, ok }
	t.Cleanup(func() { freeMediaManifestOf = old })
	t.Cleanup(func() {
		for end := time.Now().Add(5 * time.Second); len(laneRW.slot) > 0 && time.Now().Before(end); {
			time.Sleep(10 * time.Millisecond)
		}
	})
	return dest
}

// fmfDrive sends the folder line to handleFreeMediaFolder and returns its reply only after the handler has returned,
// so its deferred removals and its log line have run.
func fmfDrive(t *testing.T, dest, folder string) string {
	t.Helper()
	reply, returned := fmfDriveRaw(dest, folder)
	if !returned {
		t.Fatal("handleFreeMediaFolder did not return")
	}
	return reply
}

// fmfDriveRaw is fmfDrive for a goroutine the test starts: it reports a handler that did not return in 5 s.
func fmfDriveRaw(dest, folder string) (string, bool) {
	client, server := net.Pipe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer server.Close()
		handleFreeMediaFolder(server, bufio.NewReader(server), dest)
	}()
	go client.Write([]byte(folder + "\n")) // a NONE or LOCAL reply never reads it
	client.SetReadDeadline(time.Now().Add(20 * time.Second))
	line, _ := bufio.NewReader(client).ReadString('\n')
	client.Close()
	select {
	case <-done:
		return strings.TrimRight(line, "\n"), true
	case <-time.After(5 * time.Second):
		return strings.TrimRight(line, "\n"), false
	}
}

func fmfNoList(t *testing.T, dest string) {
	t.Helper()
	for _, p := range []string{freeMediaKeysPath(dest), freeMediaKeysPath(dest) + ".tmp"} {
		if _, err := os.Lstat(p); err == nil {
			t.Errorf("%s is still on the state tmpfs after the reply", filepath.Base(p))
		}
	}
}

func TestFreeMediaFolderValid(t *testing.T) {
	for _, f := range []string{"Download", "Pictures", "My Files", "a.b", "...", strings.Repeat("a", 255)} {
		if !validMediaFolder(f) {
			t.Errorf("validMediaFolder(%q) = false, want true", f)
		}
	}
	for _, f := range []string{"", strings.Repeat("a", 256), "a/b", "/", ".", "..", "Android", "a\x00b", "a\nb",
		"a\x1fb", "a\x7fb"} {
		if validMediaFolder(f) {
			t.Errorf("validMediaFolder(%q) = true, want false", f)
		}
	}
}

func TestFreeMediaFolderKeys(t *testing.T) {
	m := fmfKeysManifest()
	if got, want := folderCacheKeys(m, "Download"), fmfDownloadKeys(); !reflect.DeepEqual(got, want) {
		t.Errorf("Download keys = %v, want exactly %v (a and c share one entry; Downloads/d and the Ess file are out)", got, want)
	}
	if got, want := folderCacheKeys(m, "Pictures"), []string{fmfKey("c5")}; !reflect.DeepEqual(got, want) {
		t.Errorf("Pictures keys = %v, want %v", got, want)
	}
	if got := folderCacheKeys(m, "Android"); len(got) != 0 {
		t.Errorf("Android keys = %v, want none: Android/ belongs to the app rows", got)
	}
	if got := folderCacheKeys(m, "Music"); len(got) != 0 {
		t.Errorf("Music keys = %v, want none", got)
	}
}

func TestFreeMediaFolderHandler(t *testing.T) {
	dest := fmfSetup(t, "fmf-handler", fmfKeysManifest(), true)
	w := startFreeMediaKeysWorker(t, dest, "OK 123", nil)
	if got := fmfDrive(t, dest, "Download"); got != "OK 123" {
		t.Errorf("reply = %q, want OK 123", got)
	}
	ops, lists := w.snapshot()
	if !reflect.DeepEqual(ops, []string{"freemediakeys"}) {
		t.Errorf("worker ops = %v, want exactly [freemediakeys] (never the all-cache freemedia)", ops)
	}
	want := strings.Join(fmfDownloadKeys(), "\n") + "\n"
	if len(lists) != 1 || lists[0] != want {
		t.Errorf("the list the worker saw = %q, want %q", lists, want)
	}
	fmfNoList(t, dest)
}

func TestFreeMediaFolderRefusals(t *testing.T) {
	for _, c := range []struct {
		name, folder, want string
		ok                 bool
	}{
		{"bad folder", "../x", "ERR-FOLDER", true},
		{"head unread", "Download", "ERR-HEAD", false},
		{"no deferred file", "Music", "OK 0", true},
	} {
		t.Run(c.name, func(t *testing.T) {
			dest := fmfSetup(t, "fmf-refuse-"+strings.ReplaceAll(c.name, " ", "-"), fmfKeysManifest(), c.ok)
			w := startFreeMediaKeysWorker(t, dest, "OK 999", nil)
			if got := fmfDrive(t, dest, c.folder); got != c.want {
				t.Errorf("reply = %q, want %q", got, c.want)
			}
			time.Sleep(100 * time.Millisecond) // a stray request would be seen by now
			if ops, _ := w.snapshot(); len(ops) != 0 {
				t.Errorf("worker ops = %v, want none", ops)
			}
			fmfNoList(t, dest)
		})
	}
	t.Run("no session", func(t *testing.T) {
		dest := fmfSetup(t, "fmf-refuse-none", fmfKeysManifest(), true)
		os.Remove(filepath.Join(dest, ".roamsession"))
		if got := fmfDrive(t, dest, "Download"); got != "NONE" {
			t.Errorf("reply = %q, want NONE", got)
		}
	})
	t.Run("local session", func(t *testing.T) {
		dest := fmfSetup(t, "fmf-refuse-local", fmfKeysManifest(), true)
		if err := os.WriteFile(filepath.Join(dest, ".localsession"), nil, 0o600); err != nil {
			t.Fatal(err)
		}
		if got := fmfDrive(t, dest, "Download"); got != "LOCAL" {
			t.Errorf("reply = %q, want LOCAL", got)
		}
	})
}

func TestFreeMediaFolderLogNamesNoFolder(t *testing.T) {
	m := fmfKeysManifest()
	m.Deferred["SecretTrip/p.jpg"] = deferredFile{Chunks: []string{"c9"}}
	dest := fmfSetup(t, "fmf-log", m, true)
	startFreeMediaKeysWorker(t, dest, "OK 1", nil)
	var reply string
	out := captureStderr(t, func() { reply = fmfDrive(t, dest, "SecretTrip") })
	if reply != "OK 1" {
		t.Errorf("reply = %q, want OK 1", reply)
	}
	if !strings.Contains(out, "free-media-folder: 1 key(s) listed, reply OK 1") {
		t.Errorf("no free-media-folder line in stderr: %q", out)
	}
	if strings.Contains(out, "SecretTrip") || strings.Contains(out, fmfKey("c9")) {
		t.Errorf("stderr names the folder or a key: %q", out)
	}
}

func TestFreeMediaFolderConcurrent(t *testing.T) {
	dest := fmfSetup(t, "fmf-concurrent", fmfKeysManifest(), true)
	gate := make(chan struct{})
	w := startFreeMediaKeysWorker(t, dest, "OK 7", gate)
	var ra, rb string
	var okA, okB bool
	doneA, doneB := make(chan struct{}), make(chan struct{})
	go func() { defer close(doneA); ra, okA = fmfDriveRaw(dest, "Download") }()
	for end := time.Now().Add(5 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		if ops, _ := w.snapshot(); len(ops) == 1 {
			break
		}
		if time.Now().After(end) {
			close(gate)
			t.Fatal("call A's request never reached the worker")
		}
	}
	go func() { defer close(doneB); rb, okB = fmfDriveRaw(dest, "Pictures") }()
	time.Sleep(300 * time.Millisecond) // without the lock, B writes its list now
	close(gate)
	for _, d := range []chan struct{}{doneA, doneB} {
		select {
		case <-d:
		case <-time.After(15 * time.Second):
			t.Fatal("a call did not return")
		}
	}
	if !okA || !okB {
		t.Fatal("a handler did not return")
	}
	if ra != "OK 7" || rb != "OK 7" {
		t.Errorf("replies = %q, %q, want OK 7 twice", ra, rb)
	}
	_, lists := w.snapshot()
	wantA := strings.Join(fmfDownloadKeys(), "\n") + "\n"
	wantB := fmfKey("c5") + "\n"
	if len(lists) != 2 || lists[0] != wantA || lists[1] != wantB {
		t.Errorf("the lists the worker saw = %q, want [%q %q]: each run must read its own call's list", lists, wantA, wantB)
	}
	fmfNoList(t, dest)
}
