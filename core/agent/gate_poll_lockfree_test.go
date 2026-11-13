package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261117-23: the gate's media and prefetch polls (GET-MEDIA-STATUS, GET-MEDIA-APP-PROGRESS,
// GET-PREFETCH-METERED) answer while sessionMu is held. Serialized, every poll timed out behind a materialise: the
// icon rings and the media notice blinked off, and an empty GET-PREFETCH-METERED re-kicked the Auto sweep on mobile
// data.

// gatePollHeldReply is replyWhileHeld with a dest the caller has planted (replyWhileHeld makes its own t.TempDir()).
// The caller holds sessionMu. d is a hang guard, never a timing claim.
func gatePollHeldReply(t *testing.T, dest string, d time.Duration, req, what string) string {
	t.Helper()
	c := driveLoginAsync(t, dest, req)
	select {
	case got := <-c:
		return got
	case <-time.After(d):
		sessionMu.Unlock()
		late := <-c
		sessionMu.Lock() // the caller's deferred Unlock still has a lock to release
		t.Fatalf("%s: no reply within %v while sessionMu was held (it waited for the lock, then replied %q)", what, d, late)
	}
	return ""
}

func gatePollPlant(t *testing.T, dest, file, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dest, file), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

// gatePollMark records a roam session for uid 12 under a profile name no other test uses.
func gatePollMark(t *testing.T, dest string) {
	t.Helper()
	if err := markRoamSession(dest, "gatepollmetered", "pw-gatepoll-23", "12", ""); err != nil {
		t.Fatal(err)
	}
}

// TestGatePollVerbsAnswerWhileSessionMuIsHeld: each of the three verbs gives its real answer while a session op
// holds sessionMu, and the same answer with the lock free (the control).
func TestGatePollVerbsAnswerWhileSessionMuIsHeld(t *testing.T) {
	progress := "LOADING 10 100 2 a b.mwm\nDAMAGED 1 x.mwm\nINCOMPLETE 1 org.example.app\n"
	appprog := "org.example.maps 10 100 FETCHING\norg.example.music 3 9 FETCHING\n"
	cases := []struct {
		name, req, want string
		plant           func(t *testing.T, dest string)
	}{
		{"media status, three lines", "GET-MEDIA-STATUS\n", strings.TrimSuffix(progress, "\n"),
			func(t *testing.T, dest string) { gatePollPlant(t, dest, mediaProgressFile, progress) }},
		{"media app progress, two lines", "GET-MEDIA-APP-PROGRESS\n", strings.TrimSuffix(appprog, "\n"),
			func(t *testing.T, dest string) { gatePollPlant(t, dest, mediaAppProgFile, appprog) }},
		{"media status, no file", "GET-MEDIA-STATUS\n", "IDLE", func(t *testing.T, dest string) {}},
		{"media app progress, no file", "GET-MEDIA-APP-PROGRESS\n", "IDLE", func(t *testing.T, dest string) {}},
		{"metered on for the session", "GET-PREFETCH-METERED\n", "1", func(t *testing.T, dest string) {
			gatePollMark(t, dest)
			gatePollPlant(t, dest, prefetchMeteredOut, "12 1\n")
		}},
		{"metered off for the session", "GET-PREFETCH-METERED\n", "0", func(t *testing.T, dest string) {
			gatePollMark(t, dest)
			gatePollPlant(t, dest, prefetchMeteredOut, "12 0\n")
		}},
		{"metered on for another uid", "GET-PREFETCH-METERED\n", "0", func(t *testing.T, dest string) {
			gatePollMark(t, dest)
			gatePollPlant(t, dest, prefetchMeteredOut, "13 1\n")
		}},
		{"metered on, no session", "GET-PREFETCH-METERED\n", "0", func(t *testing.T, dest string) {
			gatePollPlant(t, dest, prefetchMeteredOut, "12 1\n")
		}},
		{"save mode wifi for the session", "GET-SAVE-MODE\n", "wifi", func(t *testing.T, dest string) {
			gatePollMark(t, dest)
			gatePollPlant(t, dest, saveModeOut, "12 wifi\n")
		}},
		{"save mode off for the session", "GET-SAVE-MODE\n", "off", func(t *testing.T, dest string) {
			gatePollMark(t, dest)
			gatePollPlant(t, dest, saveModeOut, "12 off\n")
		}},
		{"save mode off for another uid", "GET-SAVE-MODE\n", "always", func(t *testing.T, dest string) {
			gatePollMark(t, dest)
			gatePollPlant(t, dest, saveModeOut, "13 off\n")
		}},
		{"save mode off, no session", "GET-SAVE-MODE\n", "always", func(t *testing.T, dest string) {
			gatePollPlant(t, dest, saveModeOut, "12 off\n")
		}},
		{"save mode, no file", "GET-SAVE-MODE\n", "always", func(t *testing.T, dest string) {
			gatePollMark(t, dest)
		}},
	}
	for _, c := range cases {
		dest := t.TempDir()
		c.plant(t, dest) // before sessionMu: the planting is not under test
		func() {
			sessionMu.Lock()
			defer sessionMu.Unlock()
			if got := gatePollHeldReply(t, dest, 5*time.Second, c.req, c.name); got != c.want {
				t.Errorf("%s: sessionMu held, replied %q, want %q", c.name, got, c.want)
			}
		}()
		if got := driveLogin(t, dest, c.req); got != c.want {
			t.Errorf("%s: sessionMu free (control), replied %q, want %q", c.name, got, c.want)
		}
	}
}

// TestSetPrefetchMeteredWritesByRename: SET-PREFETCH-METERED publishes by temp + rename, so a lock-free reader never
// sees a truncated file, and a failed publish leaves no temp file behind.
func TestSetPrefetchMeteredWritesByRename(t *testing.T) {
	dest := t.TempDir()
	if err := setPrefetchMetered(dest, "12", true); err != nil {
		t.Fatal(err)
	}
	ents, err := os.ReadDir(dest)
	if err != nil {
		t.Fatal(err)
	}
	if len(ents) != 1 || ents[0].Name() != prefetchMeteredOut {
		var names []string
		for _, e := range ents {
			names = append(names, e.Name())
		}
		t.Fatalf("after setPrefetchMetered the state dir holds %q, want only %s", names, prefetchMeteredOut)
	}
	if b, _ := os.ReadFile(filepath.Join(dest, prefetchMeteredOut)); string(b) != "12 1\n" {
		t.Fatalf("%s holds %q, want %q", prefetchMeteredOut, b, "12 1\n")
	}

	// A directory at the path: the rename fails (TestSetSyncIntervalFailedRenameLeavesNoTemp's way).
	bad := t.TempDir()
	p := filepath.Join(bad, prefetchMeteredOut)
	if err := os.MkdirAll(p, 0o700); err != nil {
		t.Fatal(err)
	}
	gatePollPlant(t, p, "keep", "x")
	if err := setPrefetchMetered(bad, "12", false); err == nil {
		t.Fatal("setPrefetchMetered over a directory returned nil, want an error")
	}
	ents, err = os.ReadDir(bad)
	if err != nil {
		t.Fatal(err)
	}
	if len(ents) != 1 || ents[0].Name() != prefetchMeteredOut {
		var names []string
		for _, e := range ents {
			names = append(names, e.Name())
		}
		t.Fatalf("a failed setPrefetchMetered left %q in the state dir, want only the directory %s", names, prefetchMeteredOut)
	}

	// Source pin: the publish is a rename, never a direct write of the live file.
	src, err := os.ReadFile(filepath.Join(agentDir(), "media_tier.go"))
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	from := strings.Index(s, "\nfunc setPrefetchMetered(")
	if from < 0 {
		t.Fatal("media_tier.go: setPrefetchMetered not found")
	}
	to := strings.Index(s[from:], "\n}\n")
	if to < 0 {
		t.Fatal("media_tier.go: setPrefetchMetered has no closing brace")
	}
	body := s[from : from+to]
	if !strings.Contains(body, "os.Rename(") {
		t.Error("setPrefetchMetered does not call os.Rename: a lock-free GET-PREFETCH-METERED can read a truncated file")
	}
	if strings.Contains(body, "os.WriteFile(filepath.Join(dest, prefetchMeteredOut)") {
		t.Error("setPrefetchMetered writes prefetch-metered.out directly: a lock-free GET-PREFETCH-METERED can read a truncated file")
	}
}

// TestGatePollersNeverWaitOnTheSession (the fence): every verb the gate's two pollers send runs outside sessionMu.
// startSyncStatusWatcher and startMediaRingPoller read on 5 s caps; a verb that waits on sessionMu times out behind
// any materialise, and the empty reply reads as "nothing to show".
func TestGatePollersNeverWaitOnTheSession(t *testing.T) {
	const file = "ChooserActivity.java"
	src, err := os.ReadFile(filepath.Join(chooserSrcDir(), "com", "nowhere", "chooser", file))
	if err != nil {
		t.Fatal(err)
	}
	toks := lexJava(string(src))
	arms := parseLoginArms(t)
	// Writes sent once per state change. They stay serialized (not NWP-20261117-23's call) and still land once the
	// lock frees.
	pinned := map[string]bool{"PREFETCH-ARM": false, "PREFETCH-DISARM": false, "REKEY-DISARM": false}
	// The REKEY-* family, sent as a variable: `pollDaemon(rekeyWant + "\n")`.
	pinnedArg := []jtok{{kind: "id", text: "rekeyWant"}, {kind: "p", text: "+"}, {kind: "str", text: "\n"}}
	pinnedArgSeen := false
	found := map[string]bool{}
	for _, method := range []string{"startSyncStatusWatcher", "startMediaRingPoller"} {
		var spans []methodSpan
		for _, sp := range methodSpans(toks) {
			if sp.name == method {
				spans = append(spans, sp)
			}
		}
		if len(spans) != 1 {
			t.Fatalf("%s: %d methods named %s, want exactly 1", file, len(spans), method)
		}
		ms := spans[0]
		for i := ms.from; i < ms.to; i++ {
			spec, ok := senderFor(toks, i, file)
			if !ok || toks[i+1].kind != "p" || toks[i+1].text != "(" {
				continue
			}
			arg := nthArg(toks, i+1, spec.arg)
			var verbs []string
			for _, a := range arg {
				if a.kind != "str" {
					continue
				}
				v, _, _ := strings.Cut(a.text, "\n")
				if verbRe.MatchString(v) {
					verbs = append(verbs, v)
				}
			}
			if len(verbs) == 0 {
				if gatePollSameToks(arg, pinnedArg) {
					pinnedArgSeen = true
					continue
				}
				t.Errorf("%s:%d (%s): %s(...) sends a request this fence cannot resolve to a verb", file, toks[i].line, method, toks[i].text)
				continue
			}
			for _, v := range verbs {
				found[v] = true
				if _, ok := pinned[v]; ok {
					pinned[v] = true
					continue
				}
				if gatePollWaits(concurrentSafeCmd(v), arms.has(v), chooserVerbsAwaitingArm[v]) {
					t.Errorf("%s:%d (%s): the gate polls %s, which waits on sessionMu: behind a materialise its 5 s read times out empty", file, toks[i].line, method, v)
				}
			}
		}
	}
	for _, v := range []string{"GET-SYNC-STATUS", "GET-MEDIA-STATUS", "GET-MEDIA-APP-PROGRESS"} {
		if !found[v] {
			t.Errorf("control: the pollers' scan did not find %s, so it cannot be trusted", v)
		}
	}
	for v, seen := range pinned {
		if !seen {
			t.Errorf("stale pin: the pollers no longer send %s; drop it from the pinned set", v)
		}
	}
	if !pinnedArgSeen {
		t.Error(`stale pin: the pollers no longer send rekeyWant + "\n"; drop the pinned argument`)
	}
}

// gatePollWaits is the fence's verdict on one polled verb. A verb outside concurrentSafeCmd waits on sessionMu, unless
// it awaits its arm and handleLogin does not serve it yet: no handler exists to judge. The arm ends that exemption.
func gatePollWaits(safe, armed, awaitingArm bool) bool {
	return !safe && (armed || !awaitingArm)
}

func gatePollSameToks(a, b []jtok) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].kind != b[i].kind || a[i].text != b[i].text {
			return false
		}
	}
	return true
}
