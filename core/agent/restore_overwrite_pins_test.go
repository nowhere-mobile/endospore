package main

// NWP-20261003-02: an empty sign-in, a CREATE or a "Save to your store" must not replace a restored profile.
//
// The review of the web restore feared exactly that: the storefront puts a profile back, and the phone then
// seals an empty one over it. Read against the code, the phone already refuses once the restore's heads have
// landed -- but nothing pinned any of those refusals, so a refactor could drop one with every test green:
//
//   - CREATE and CREATE-CODE probe the head for the FULL (name, pass) and answer EXISTS, writing nothing
//     (CREATE-CODE before it redeems the code).
//   - PROMOTE and PROMOTE2 ("Save to your store") answer ERR-EXISTS, PROMOTE2 before it re-keys the keyguard.
//   - A sign-in that finds no head is a LOCAL throwaway: every seal entry point tests .localsession first,
//     so it is never written to the store and cannot replace anything.
//
// Each refusal was reverted by hand and the test below it failed; the reversions and the failure text are
// recorded in worklog.md (NWP-20261003-02).
//
// ⚠ WHAT THIS DOES NOT CLOSE. Each probe runs once and then writes. A CREATE whose probe lands after the
// storefront's restoreCaps re-checked the heads, and before the browser's head PUTs, sees an empty head. That
// residual race is an OPEN row in docs/backlog.md waiting on the maintainer's decision. The restore-in-progress
// sentinel stays retired (docs/backlog.md, NWP-20260918-04); do not rebuild it to make a test here pass.

import (
	"bytes"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	ropName = "restored"
	ropPass = "horse battery staple correct" // clears the floor: these tests run with production gating
	ropNew  = "violet anchor meadow thunder" // PROMOTE2's typed passphrase, also above the floor
)

// ropStore is a cap-mode store (the fielded fleet's mode) with a funded wallet, so a write that a refusal
// failed to stop actually lands. Without credit a reverted guard would fall through to NOCREDIT and the
// tests would convict it only by accident.
func ropStore(t *testing.T) (*httptest.Server, map[string][]byte, *sync.Mutex) {
	t.Helper()
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "") // no creds -> capMode() -> storeConfigured()
	capReadCache = map[string]capEntry{}
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_ENROLL_STATE", filepath.Join(t.TempDir(), "enroll")) // never the host's /data
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	return srv, objs, mu
}

// ropRestored stands a real profile at (name, pass) -- what a completed restore leaves -- and returns its head.
func ropRestored(t *testing.T, name, pass string) string {
	t.Helper()
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault returned no recovery code -- the fixture profile was not created")
	}
	capReadCache = map[string]capEntry{}
	head := getRef("s3", headKey("s3", name, pass))
	if head == "" {
		t.Fatal("the fixture profile has no head -- the store harness is not doing what these tests assume")
	}
	return head
}

// ropSnapshot copies the store, so "nothing was written" is checked byte for byte, not by object count.
func ropSnapshot(objs map[string][]byte, mu *sync.Mutex) map[string][]byte {
	mu.Lock()
	defer mu.Unlock()
	out := make(map[string][]byte, len(objs))
	for k, v := range objs {
		out[k] = append([]byte(nil), v...)
	}
	return out
}

func ropUnchanged(t *testing.T, what string, before map[string][]byte, objs map[string][]byte, mu *sync.Mutex) {
	t.Helper()
	after := ropSnapshot(objs, mu)
	for k, v := range after {
		if b, ok := before[k]; !ok {
			t.Errorf("%s wrote a new store object %q -- a refusal must write nothing", what, k)
		} else if !bytes.Equal(b, v) {
			t.Errorf("%s rewrote store object %q -- the restored profile was modified", what, k)
		}
	}
	for k := range before {
		if _, ok := after[k]; !ok {
			t.Errorf("%s deleted store object %q", what, k)
		}
	}
}

// ropWorker stands in for roamd: it answers any request a handler hands the worker (all three lanes) with an
// error, at once, and records the op. A refusal hands it nothing, so the list must stay empty; a reverted one
// is caught in about half a second instead of hanging on the worker's 150 s stall timeout.
func ropWorker(t *testing.T, dest string) (stop func() []string) {
	t.Helper()
	lanes := []workerLane{laneRW, laneRO, laneCred}
	var mu sync.Mutex
	var ops []string
	done := make(chan struct{})
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		for {
			for _, l := range lanes {
				b, err := os.ReadFile(filepath.Join(dest, l.req))
				if err != nil {
					continue
				}
				os.Remove(filepath.Join(dest, l.req))
				mu.Lock()
				ops = append(ops, strings.SplitN(string(b), "\n", 2)[0])
				mu.Unlock()
				os.WriteFile(filepath.Join(dest, l.res), []byte("ERR-PIN-TEST\n"), 0o600)
			}
			select {
			case <-done:
				return
			case <-time.After(20 * time.Millisecond):
			}
		}
	}()
	return func() []string {
		close(done)
		<-finished
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), ops...)
	}
}

// ropReply drives a daemon handler over a pipe and returns everything the chooser would read.
func ropReply(t *testing.T, h func(net.Conn)) string {
	t.Helper()
	cli, srv := net.Pipe()
	go func() { h(srv); srv.Close() }()
	raw, err := io.ReadAll(cli)
	if err != nil {
		t.Fatalf("reading the reply: %v", err)
	}
	return dropCreateProgress(strings.TrimSpace(string(raw)))
}

// ropReapReset clears the package-global reap queue around a test that may set it.
func ropReapReset(t *testing.T) {
	t.Helper()
	reset := func() {
		pendingReapMu.Lock()
		pendingReapUID, pendingSwitchUID, pendingRearmUID = "", "", ""
		pendingReapMu.Unlock()
	}
	reset()
	t.Cleanup(reset)
}

// TestCreateRefusesARestoredProfile: CREATE with the restored (name, pass) answers EXISTS and writes nothing.
func TestCreateRefusesARestoredProfile(t *testing.T) {
	_, objs, mu := ropStore(t)
	head := ropRestored(t, ropName, ropPass)
	before := ropSnapshot(objs, mu)
	dest := t.TempDir()

	got := ropReply(t, func(c net.Conn) { handleCreate(c, dest, ropName, ropPass) })
	if got != "EXISTS" {
		t.Fatalf("CREATE over a restored profile replied %q, want EXISTS. Without the head probe in handleCreate "+
			"a CREATE with the restored name and passphrase seals an EMPTY profile over the restore.", got)
	}
	ropUnchanged(t, "CREATE", before, objs, mu)
	capReadCache = map[string]capEntry{}
	if now := getRef("s3", headKey("s3", ropName, ropPass)); now != head {
		t.Errorf("the restored head moved from %q to %q", head, now)
	}
	if _, err := os.Stat(filepath.Join(dest, ".roamsession")); err == nil {
		t.Error("a refused CREATE recorded a session")
	}

	// Control, so the refusal above is not vacuous: the same harness DOES create when no head stands there.
	if got := ropReply(t, func(c net.Conn) { handleCreate(c, t.TempDir(), "fresh", ropPass) }); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("control CREATE on an empty slot replied %q, want OK -- the harness cannot reach the write, so the "+
			"refusal above proves nothing", got)
	}
}

// TestCreateCodeRefusesARestoredProfileBeforeRedeeming: CREATE-CODE answers EXISTS before it touches the code.
func TestCreateCodeRefusesARestoredProfileBeforeRedeeming(t *testing.T) {
	srv, objs, mu := ropStore(t)
	ropRestored(t, ropName, ropPass)
	before := ropSnapshot(objs, mu)

	// Every request the gateway sees from here on, except the object reads the probe itself needs. A claim
	// redemption is a gateway call; the refusal must come before any.
	var gmu sync.Mutex
	var calls []string
	spy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/cap" && r.URL.Path != "/caps" && r.URL.Path != "/obj" { // /caps: readCap's read cap (NWP-20261009-02)
			gmu.Lock()
			calls = append(calls, r.Method+" "+r.URL.Path)
			gmu.Unlock()
		}
		srv.Config.Handler.ServeHTTP(w, r)
	}))
	t.Cleanup(spy.Close)
	t.Setenv("GATEWAY_URL", spy.URL)
	capReadCache = map[string]capEntry{}

	got := ropReply(t, func(c net.Conn) { handleCreateCode(c, t.TempDir(), ropName, ropPass, "ABCD1234ABCD1234ABCD1234") })
	if got != "EXISTS" {
		t.Fatalf("CREATE-CODE over a restored profile replied %q, want EXISTS -- the head probe must refuse "+
			"BEFORE the code is redeemed and before anything is created", got)
	}
	gmu.Lock()
	defer gmu.Unlock()
	if len(calls) != 0 {
		t.Errorf("CREATE-CODE called the gateway before refusing (%v) -- a refused create must not burn the code", calls)
	}
	ropUnchanged(t, "CREATE-CODE", before, objs, mu)
}

// ropThrowaway seats a LOCAL session for (name, pass) the way handleRoamIn does when it finds no head.
func ropThrowaway(t *testing.T, name, pass string) string {
	t.Helper()
	dest := t.TempDir()
	if err := markRoamSession(dest, name, pass, "12", ""); err != nil {
		t.Fatal(err)
	}
	markLocalSession(dest)
	return dest
}

// TestPromoteRefusesARestoredProfile: "Save to your store" from a throwaway whose (name, pass) now has a head
// -- the restore landed after the sign-in -- answers ERR-EXISTS, writes nothing and stays a throwaway.
func TestPromoteRefusesARestoredProfile(t *testing.T) {
	_, objs, mu := ropStore(t)
	ropReapReset(t)
	dest := ropThrowaway(t, ropName, ropPass)
	head := ropRestored(t, ropName, ropPass)
	before := ropSnapshot(objs, mu)

	stop := ropWorker(t, dest)
	got := ropReply(t, func(c net.Conn) { handlePromote(c, dest) })
	time.Sleep(700 * time.Millisecond) // a reverted guard seals in a goroutine; give it time to ask
	ops := stop()

	if got != "ERR-EXISTS" {
		t.Fatalf("PROMOTE over a restored profile replied %q, want ERR-EXISTS. Without promoteToStore's head "+
			"probe the throwaway's empty data is sealed over the restore.", got)
	}
	if !isLocalSession(dest) {
		t.Error("a refused PROMOTE flipped the session to stored -- the next periodic seal would overwrite the restore")
	}
	if len(ops) != 0 {
		t.Errorf("a refused PROMOTE handed the worker %v", ops)
	}
	ropUnchanged(t, "PROMOTE", before, objs, mu)
	capReadCache = map[string]capEntry{}
	if now := getRef("s3", headKey("s3", ropName, ropPass)); now != head {
		t.Errorf("the restored head moved from %q to %q", head, now)
	}
}

// TestPromote2RefusesARestoredProfileBeforeRekeying: the Save ceremony with a typed passphrase that resolves
// to a restored profile answers ERR-EXISTS before it re-keys the live keyguard or rewrites the session marker.
func TestPromote2RefusesARestoredProfileBeforeRekeying(t *testing.T) {
	_, objs, mu := ropStore(t)
	ropReapReset(t)
	dest := ropThrowaway(t, ropName, ropPass)
	ropRestored(t, ropName, ropNew)
	before := ropSnapshot(objs, mu)

	stop := ropWorker(t, dest)
	got := ropReply(t, func(c net.Conn) { handlePromote2(c, dest, ropNew) })
	time.Sleep(700 * time.Millisecond)
	ops := stop()

	if got != "ERR-EXISTS" {
		t.Fatalf("PROMOTE2 onto a restored (name, passphrase) replied %q, want ERR-EXISTS -- the probe must run "+
			"before the keyguard re-key, so a save that is about to be refused never changes the lock", got)
	}
	if len(ops) != 0 {
		t.Errorf("a refused PROMOTE2 handed the worker %v -- the keyguard must not be re-keyed for a refused save", ops)
	}
	if _, p, _ := readRoamSession(dest); p != ropPass {
		t.Error("a refused PROMOTE2 rewrote the session marker's passphrase")
	}
	if !isLocalSession(dest) {
		t.Error("a refused PROMOTE2 flipped the session to stored")
	}
	ropUnchanged(t, "PROMOTE2", before, objs, mu)
}

// TestAnEmptySignInIsLocalAndNeverSeals pins the LOCAL session: a sign-in that found no head is never written
// to the store, whichever way the session ends or is backed up. The two handlers that can be driven are
// driven; the two that cannot (an infinite loop, a reboot) are pinned in the source.
func TestAnEmptySignInIsLocalAndNeverSeals(t *testing.T) {
	_, objs, mu := ropStore(t)

	t.Run("logoff reaps without a seal", func(t *testing.T) {
		ropReapReset(t)
		dest := ropThrowaway(t, ropName, ropPass)
		before := ropSnapshot(objs, mu)
		stop := ropWorker(t, dest)
		got := ropReply(t, func(c net.Conn) { handleLogout(c, dest) })
		time.Sleep(700 * time.Millisecond)
		ops := stop()
		if got != "OK" {
			t.Fatalf("LOGOUT of a throwaway replied %q, want OK", got)
		}
		if len(ops) != 0 {
			t.Errorf("logging off a throwaway handed the worker %v -- a LOCAL session is never sealed", ops)
		}
		pendingReapMu.Lock()
		reap, sw := pendingReapUID, pendingSwitchUID
		pendingReapMu.Unlock()
		if reap != "12" || sw != "12" {
			t.Errorf("throwaway logoff did not queue the reap at once (reap=%q switch=%q)", reap, sw)
		}
		if isLocalSession(dest) {
			t.Error("the .localsession marker survived the logoff")
		}
		ropUnchanged(t, "a throwaway's logoff", before, objs, mu)
	})

	t.Run("back up now refuses", func(t *testing.T) {
		dest := ropThrowaway(t, ropName, ropPass)
		before := ropSnapshot(objs, mu)
		stop := ropWorker(t, dest)
		got := ropReply(t, func(c net.Conn) { handleBackup(c, dest) })
		ops := stop()
		if got != "LOCAL" {
			t.Fatalf("BACKUP of a throwaway replied %q, want LOCAL", got)
		}
		if len(ops) != 0 {
			t.Errorf("backing up a throwaway handed the worker %v", ops)
		}
		ropUnchanged(t, "a throwaway's backup", before, objs, mu)
	})

	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	index := func(body []string, fn, needle string) int {
		t.Helper()
		for i, l := range body {
			if strings.Contains(l, needle) {
				return i
			}
		}
		t.Fatalf("%s: %q not found -- the test is looking at the wrong function, or the code moved", fn, needle)
		return -1
	}

	t.Run("handleRoamIn marks an empty sign-in LOCAL", func(t *testing.T) {
		body := stripComments(funcBody(t, string(src), "handleRoamIn"))
		// NWP-20261124-07: the head is read strictly by roamInHead (locked_head.go); a definite absence answers "".
		probe := index(body, "handleRoamIn", `head, headVault, readable := roamInHead("s3", name, pass, srcUnit)`)
		arm := -1
		for i, l := range body {
			if strings.TrimSpace(l) == `if head == "" {` {
				arm = i
				break
			}
		}
		if arm < 0 || arm < probe {
			t.Fatalf("handleRoamIn: no `if head == \"\" {` arm after the head probe (probe at %d, arm at %d)", probe, arm)
		}
		marked := false
		for _, l := range body[arm+1:] {
			if strings.Contains(l, "markLocalSession(dest)") {
				marked = true
			}
			if strings.TrimSpace(l) == "return" {
				break
			}
		}
		if !marked {
			t.Error("handleRoamIn's empty-head arm returns without markLocalSession(dest) -- an empty sign-in would " +
				"be a STORED session and its first periodic seal would write an empty profile at that head")
		}
		if clr := index(body, "handleRoamIn", "clearLocalSession(dest)"); clr < arm {
			t.Error("handleRoamIn clears .localsession BEFORE the empty-head arm -- it must only clear it for a login that resolved")
		}
	})

	for _, fn := range []string{"syncLoop"} {
		t.Run(fn+" tests LOCAL before it seals", func(t *testing.T) {
			body := stripComments(funcBody(t, string(src), fn))
			gateExpr := "if localOnlySession(dest) {" // NWP-20261015-24: syncLoop honours both markers
			gate := index(body, fn, gateExpr)
			seal := index(body, fn, `(dest, "out"`)
			if gate > seal {
				t.Fatalf("%s seals (body line %d) before it tests .localsession (body line %d) -- a throwaway would be "+
					"written to the store", fn, seal+1, gate+1)
			}
			// The seal must sit OUTSIDE a fall-through from the LOCAL arm: syncLoop skips the cycle.
			want := "continue"
			if !strings.HasPrefix(strings.TrimSpace(body[gate+1]), want) { // the LOCAL arm IS the skip
				t.Errorf("%s: the LOCAL arm does not end in %q before the seal -- a throwaway falls through to the seal", fn, want)
			}
		})
	}
}

// TestExistsRefusalsGiveANextStep pins the chooser copy for the two "already exists" answers: each tells the
// reader what to do next (sign in) and how to know a website restore is done (the verify message, the
// storefront's own words on its restore page). Since NWP-20261116-15 the Save ceremony's ERR-EXISTS text lives in
// PromoteCopy.java and ProfileActivity's EXISTS arm shows it, so the words are pinned in the one and the dialog in
// the other.
func TestExistsRefusalsGiveANextStep(t *testing.T) {
	dir := filepath.Join("..", "chooser", "src", "com", "nowhere", "chooser")
	for _, c := range []struct {
		file, anchor, end string
		words             bool // the block holds the message text
		shows             string
	}{
		{"ChooserActivity.java", `cr.startsWith("EXISTS")`, "return;", true, ""},
		{"PromoteCopy.java", `"ERR-EXISTS".equals(r)) return "`, `";`, true, ""},
		{"ProfileActivity.java", `case EXISTS:`, ".show();", false, "PromoteCopy.text(r)"},
	} {
		b, err := os.ReadFile(filepath.Join(dir, c.file))
		if err != nil {
			// FAIL, not skip: a skip reads as green in CI while pinning nothing (review finding).
			t.Fatalf("cannot read %s (%v) -- this test needs the source tree", c.file, err)
		}
		lines := strings.Split(string(b), "\n")
		at := -1
		for i, l := range lines {
			if s := strings.TrimSpace(l); strings.HasPrefix(s, "//") || strings.HasPrefix(s, "*") {
				continue
			}
			if strings.Contains(l, c.anchor) {
				if at >= 0 {
					t.Fatalf("%s: %s appears twice -- this test can no longer tell which branch is the refusal", c.file, c.anchor)
				}
				at = i
			}
		}
		if at < 0 {
			t.Fatalf("%s: %s not found -- the test is stale, not the code", c.file, c.anchor)
		}
		var block strings.Builder
		for _, l := range lines[at:] {
			if s := strings.TrimSpace(l); !strings.HasPrefix(s, "//") {
				block.WriteString(l)
				block.WriteString("\n")
			}
			if strings.Contains(l, c.end) {
				break
			}
		}
		text := strings.ToLower(block.String())
		if c.shows != "" && !strings.Contains(block.String(), c.shows) {
			t.Errorf("%s:%d: the %s refusal no longer shows %s -- the message it pins is not the one on screen",
				c.file, at+1, c.anchor, c.shows)
		}
		for _, want := range []string{"sign in", "verify message"} {
			if c.words && !strings.Contains(text, want) {
				t.Errorf("%s:%d: the %s refusal no longer says %q -- \"already exists\" alone leaves the reader with "+
					"no next step, and after a website restore the one they need is to wait for its verify message",
					c.file, at+1, c.anchor, want)
			}
		}
		// A TEXT TOAST cannot carry this message: Android 12+ cuts it to two lines, which drops the next step.
		if strings.Contains(block.String(), "Toast.makeText") {
			t.Errorf("%s:%d: the %s refusal is a Toast; Android 12+ truncates it to two lines", c.file, at+1, c.anchor)
		}
		for _, bad := range forbidden {
			if strings.Contains(block.String(), bad) {
				t.Errorf("%s:%d: the %s refusal contains %q (refusal_copy_test.go)", c.file, at+1, c.anchor, bad)
			}
		}
	}
}
