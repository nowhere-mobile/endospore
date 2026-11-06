package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// NWP-20261014-67: roamd's _cause turns the agent's exit code into the per-scope token of a seal verdict
// (" PARTIAL:sys=<cause>"), and acct_seal / appcode_seal hand it the #sys / #apps push's code verbatim. 5 is
// exitStoreUnreachable (NWP-20261006-21) -- and it was also acct_seal's own pending-placement wait, which
// _cause mapped to `pending-placement`, the one token benignSealParts drops as saved (decided 2026-10-08). So a
// #sys push that lost the network counted as saved and the cold-lock re-check wiped a session whose account head
// was never stored. These tests read roamd's table out of the script and hold it against the agent's codes;
// test-roamd-cause-vocab.sh holds the same table from the shell side.

func roamdSource(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "vendor-common", "bin", "nowhere_roamd.sh"))
	if err != nil {
		t.Fatalf("cannot read nowhere_roamd.sh: %v", err) // never a skip: a missing table must not read as a pass
	}
	return strings.ReplaceAll(string(b), "\r\n", "\n")
}

// roamdCauseArms parses _cause's case arms: pattern -> token.
func roamdCauseArms(t *testing.T, src string) map[string]string {
	t.Helper()
	i := strings.Index(src, "\n_cause() {\n")
	if i < 0 {
		t.Fatal("top-level _cause() not found in nowhere_roamd.sh")
	}
	body := src[i+1:]
	k := strings.Index(body, "\n}\n")
	if k < 0 {
		t.Fatal("_cause() has no closing brace at column 0")
	}
	body = body[:k]
	arms := map[string]string{}
	for _, m := range regexp.MustCompile(`(?m)^\s+([0-9]+|\*)\)\s+echo ([a-z-]+) ;;`).FindAllStringSubmatch(body, -1) {
		arms[m[1]] = m[2]
	}
	if arms["0"] != "ok" || arms["*"] == "" {
		t.Fatalf("_cause parsed to %v: the arm syntax changed, so this table is not the script's", arms)
	}
	return arms
}

func causeOf(arms map[string]string, code int) string {
	if c, ok := arms[strconv.Itoa(code)]; ok {
		return c
	}
	return arms["*"]
}

// roamdPendingCode is the code acct_seal's pending-placement branch returns: the first `return N` after its log line.
func roamdPendingCode(t *testing.T, src string) int {
	t.Helper()
	i := strings.Index(src, "\nacct_seal() {\n")
	if i < 0 {
		t.Fatal("acct_seal() not found in nowhere_roamd.sh")
	}
	fn := src[i:]
	j := strings.Index(fn, "#sys accounts PENDING-PLACEMENT")
	if j < 0 {
		t.Fatal("acct_seal's PENDING-PLACEMENT branch not found")
	}
	m := regexp.MustCompile(`(?m)^\s+return ([0-9]+)$`).FindStringSubmatch(fn[j:])
	if m == nil {
		t.Fatal("no return after acct_seal's PENDING-PLACEMENT log line")
	}
	n, _ := strconv.Atoi(m[1])
	return n
}

// agentExitCodes is every code the agent exits with: its exit* constants and every os.Exit(<literal>) in the
// package's non-test sources.
func agentExitCodes(t *testing.T) map[int]bool {
	t.Helper()
	codes := map[int]bool{1: true, exitNoCredit: true, exitSealRefused: true, exitStoreUnreachable: true, exitSealStopped: true}
	files, _ := filepath.Glob("*.go")
	lit := regexp.MustCompile(`os\.Exit\(([0-9]+)\)`)
	n := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range lit.FindAllStringSubmatch(string(b), -1) {
			c, _ := strconv.Atoi(m[1])
			codes[c] = true
			n++
		}
	}
	if n == 0 {
		t.Fatal("found no os.Exit literal in the agent sources: the scan is not reading them")
	}
	return codes
}

// Every code the agent exits with on failure maps to a part the daemon KEEPS, for both helper-sealed scopes.
func TestNoAgentExitCodeIsABenignSealPart(t *testing.T) {
	arms := roamdCauseArms(t, roamdSource(t))
	if got := causeOf(arms, exitStoreUnreachable); got != "unreachable" {
		t.Errorf("_cause %d (exitStoreUnreachable) = %q, want unreachable", exitStoreUnreachable, got)
	}
	if got := causeOf(arms, exitNoCredit); got != "nocredit" {
		t.Errorf("_cause %d (exitNoCredit) = %q, want nocredit", exitNoCredit, got)
	}
	if got := causeOf(arms, exitSealRefused); got != "refused" {
		t.Errorf("_cause %d (exitSealRefused) = %q, want refused", exitSealRefused, got)
	}
	if got := causeOf(arms, exitSealStopped); got != "stopped" { // h47 #1 (NWP-20261117-01)
		t.Errorf("_cause %d (exitSealStopped) = %q, want stopped", exitSealStopped, got)
	}
	if got := causeOf(arms, 1); got != "failed" {
		t.Errorf("_cause 1 = %q, want failed", got)
	}
	codes := agentExitCodes(t)
	codes[124], codes[137] = true, true // the `timeout -k` wrapper roamd runs the #sys and #apps pushes under
	for c := range codes {
		if c == 0 {
			continue // the call sites note only a non-zero code
		}
		for _, scope := range []string{"sys", "apps"} {
			part := scope + "=" + causeOf(arms, c)
			if benignSealParts[part] {
				t.Errorf("agent exit %d renders as %q, which benignSealParts drops: a push that stored nothing counts as saved", c, part)
			}
			if got := sealPartsOf("OK PARTIAL:" + part); got != part {
				t.Errorf("sealPartsOf(%q) = %q, want the part kept", "OK PARTIAL:"+part, got)
			}
		}
	}
}

// acct_seal's own wait has a code of its own, which _cause maps to the benign token -- and no agent path exits with.
func TestAcctSealPendingCodeIsItsOwn(t *testing.T) {
	src := roamdSource(t)
	arms, code := roamdCauseArms(t, src), roamdPendingCode(t, src)
	if got := causeOf(arms, code); got != "pending-placement" {
		t.Errorf("acct_seal's pending branch returns %d, which _cause maps to %q, want pending-placement", code, got)
	}
	codes := agentExitCodes(t)
	for _, c := range []int{0, 124, 126, 127, 137} {
		codes[c] = true
	}
	if codes[code] {
		t.Errorf("acct_seal's pending code %d is also an agent/timeout/shell exit code: that failure would read as pending-placement", code)
	}
	// Control: the decided benign token is still dropped (NWP-20261008-07), so the table above is not passing by
	// making every part non-benign.
	if got := sealPartsOf("OK PARTIAL:sys=pending-placement"); got != "" {
		t.Errorf("control: sealPartsOf drops sys=pending-placement no longer (got %q)", got)
	}
}

// End to end through the daemon: a save whose #sys push could not reach the store keeps a cold-locked session
// whose CE stayed readable; the decided pending-placement still wipes (coldlock_pending_placement_test.go).
func TestColdLockKeepsASessionWhoseSysPushWasUnreachable(t *testing.T) {
	dest, calls := evictSetup(t, "ERR-EVICT-INCOMPLETE /data/system_ce/15/accounts_ce.db(PLAINTEXT)")
	sealMu.Lock()
	oldReason := sealReason
	sealMu.Unlock()
	t.Cleanup(func() {
		sealMu.Lock()
		sealReason = oldReason
		sealMu.Unlock()
	})
	t.Setenv("NOWHERE_STATE", t.TempDir())
	arms := roamdCauseArms(t, roamdSource(t))
	sys := "OK PARTIAL:sys=" + causeOf(arms, exitStoreUnreachable)
	for _, c := range []struct{ verdict, want string }{
		{sys, "KEEP UNSAVED last-save-partial"},
		{"OK PARTIAL:sys=pending-placement", "WIPE 15"},
	} {
		recordSeal(c.verdict)
		if got := evictConn(t, dest, "EVICT-RECHECK\n15\n"); got != c.want {
			t.Errorf("a failed eviction after %q -> %q, want %q", c.verdict, got, c.want)
		}
	}
	if *calls != 2 {
		t.Errorf("evictcheck ran %d times, want 2", *calls)
	}
}

// TestPushVerbHelperProcess is not a test: it is the agent, re-executed from the test binary by
// TestAPushThatCannotReachTheStoreExits5, running the real `push` verb through main() so the exit code is the one
// acct_seal and appcode_seal hand to _cause.
func TestPushVerbHelperProcess(t *testing.T) {
	a := os.Getenv("NOWHERE_PUSH_VERB_HELPER")
	if a == "" {
		return
	}
	os.Args = append([]string{"nowhere_agent", "push"}, strings.Split(a, "\n")...)
	main()
	os.Exit(0)
}

// THE PREMISE: a push whose store cannot be reached exits exitStoreUnreachable -- the same 5 acct_seal used for
// its wait. Controls: the same push against a live store exits 0.
func TestAPushThatCannotReachTheStoreExits5(t *testing.T) {
	name, pass := "vocabpush", "vocab push horse battery staple"
	live := newHTTPStore(t)
	createVault(live, name, pass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("a session's account db, standing in"), 0o600); err != nil {
		t.Fatal(err)
	}
	run := func(store string) (int, string) {
		cmd := exec.Command(os.Args[0], "-test.run=^TestPushVerbHelperProcess$", "-test.count=1")
		env := []string{"NOWHERE_PUSH_VERB_HELPER=" + strings.Join([]string{store, name, pass, src}, "\n")}
		for _, kv := range os.Environ() {
			k := kv[:strings.IndexByte(kv+"=", '=')]
			switch k {
			case "GATEWAY_URL", "S3_ACCESS_KEY", "NOWHERE_CHUNK_CACHE", "NOWHERE_STATE", "NOWHERE_PHASE", "NOWHERE_COMPRESS":
				continue // a plain-HTTP store, no cache, no session state
			}
			env = append(env, kv)
		}
		cmd.Env = append(env, "NOWHERE_STATE="+t.TempDir())
		out, err := cmd.CombinedOutput()
		if err == nil {
			return 0, string(out)
		}
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("running the agent: %v", err)
		}
		return ee.ExitCode(), string(out)
	}
	if code, out := run(deadStore(t)); code != exitStoreUnreachable {
		t.Errorf("push to a store that refuses the dial exited %d, want exitStoreUnreachable (%d)\n%s", code, exitStoreUnreachable, out)
	}
	if code, out := run(live); code != 0 {
		t.Errorf("control: push to a live store exited %d, want 0\n%s", code, out)
	}
}
