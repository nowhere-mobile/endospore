package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

// NWP-20261101-03 (Q048): a lost create reply hands its recovery code over once on the retry.

func memoClock(t *testing.T) *time.Time {
	t.Helper()
	now := time.Unix(1_800_000_000, 0)
	old := createCodeMemoNow
	createCodeMemoNow = func() time.Time { return now }
	t.Cleanup(func() { createCodeMemoNow = old; forgetCreatedCodes() })
	forgetCreatedCodes()
	return &now
}

func TestCreateCodeMemoTakeReturnsOnce(t *testing.T) {
	memoClock(t)
	rememberCreatedCode("memo-ann", "memo ann passphrase", "one two three")
	if got := takeCreatedCode("memo-ann", "memo ann passphrase"); got != "one two three" {
		t.Fatalf("first take = %q", got)
	}
	if got := takeCreatedCode("memo-ann", "memo ann passphrase"); got != "" {
		t.Fatalf("second take = %q, want nothing", got)
	}
}

func TestCreateCodeMemoOtherCredentialGetsNothing(t *testing.T) {
	memoClock(t)
	rememberCreatedCode("memo-bea", "memo bea passphrase", "one two three")
	if got := takeCreatedCode("memo-bea", "another passphrase"); got != "" {
		t.Errorf("same name, other passphrase got %q", got)
	}
	if got := takeCreatedCode("memo-other", "memo bea passphrase"); got != "" {
		t.Errorf("other name, same passphrase got %q", got)
	}
	if got := takeCreatedCode("memo-bea", "memo bea passphrase"); got != "one two three" {
		t.Errorf("the owner's entry was disturbed: %q", got)
	}
}

func TestCreateCodeMemoExpiredGetsNothing(t *testing.T) {
	now := memoClock(t)
	rememberCreatedCode("memo-cy", "memo cy passphrase", "one two three")
	*now = now.Add(createCodeMemoTTL + time.Second)
	if got := takeCreatedCode("memo-cy", "memo cy passphrase"); got != "" {
		t.Fatalf("an expired entry gave %q", got)
	}
}

func TestCreateCodeMemoForgetClears(t *testing.T) {
	memoClock(t)
	rememberCreatedCode("memo-di", "memo di passphrase", "one two three")
	forgetCreatedCodes()
	if got := takeCreatedCode("memo-di", "memo di passphrase"); got != "" {
		t.Fatalf("after forget got %q", got)
	}
}

func memoCapture(t *testing.T) func() string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	prev := os.Stderr
	os.Stderr = w
	done := make(chan string)
	go func() { b, _ := io.ReadAll(r); done <- string(b) }()
	return func() string { os.Stderr = prev; w.Close(); return <-done }
}

func TestCreateCodeMemoRepeatCreateGetsTheCodeOnce(t *testing.T) {
	memoClock(t)
	dest, _ := createCodeEnv(t, "UNUSED", 1)
	const n, p = "memo-eve", "the memo eve passphrase"
	stop := memoCapture(t)
	first := verb(func(c net.Conn) { handleCreate(c, dest, n, p) })
	if !strings.HasPrefix(first, "OK 0 RECOVERY ") {
		stop()
		t.Fatalf("create replied %q", first)
	}
	words := strings.TrimPrefix(first, "OK 0 RECOVERY ")
	second := verb(func(c net.Conn) { handleCreate(c, dest, n, p) })
	third := verb(func(c net.Conn) { handleCreate(c, dest, n, p) })
	logs := stop()
	if second != "EXISTS RECOVERY "+words {
		t.Errorf("repeat create replied %q, want EXISTS RECOVERY <the same words>", second)
	}
	if third != "EXISTS" {
		t.Errorf("third create replied %q, want a bare EXISTS", third)
	}
	// A leak prints the code, or a run of it. A single word is not evidence: the mnemonic draws from BIP-39's English
	// list, so the resolver's own "(discovery empty, nothing cached)" line matched one word in a few runs out of a
	// hundred (NWP-20261021-25). So the logs must hold neither the phrase nor any two of its words in order.
	ws, lf := strings.Fields(words), strings.Fields(logs)
	if strings.Contains(logs, words) {
		t.Fatalf("a log line carries the recovery code:\n%s", logs)
	}
	for i := 0; i+1 < len(ws); i++ {
		for j := 0; j+1 < len(lf); j++ {
			if lf[j] == ws[i] && lf[j+1] == ws[i+1] {
				t.Fatalf("a log line carries the mnemonic words %q %q in order:\n%s", ws[i], ws[i+1], logs)
			}
		}
	}
}

func TestCreateCodeMemoSignInBetweenForgets(t *testing.T) {
	memoClock(t)
	dest, _ := createCodeEnv(t, "UNUSED", 1)
	const n, p = "memo-fay", "the memo fay passphrase"
	first := verb(func(c net.Conn) { handleCreate(c, dest, n, p) })
	if !strings.HasPrefix(first, "OK 0 RECOVERY ") {
		t.Fatalf("create replied %q", first)
	}
	verb(func(c net.Conn) { handleRoamIn(c, dest, "", "", "", "", "") })
	if got := verb(func(c net.Conn) { handleCreate(c, dest, n, p) }); got != "EXISTS" {
		t.Errorf("repeat create after a sign-in replied %q, want a bare EXISTS", got)
	}
}

func memoLen() int {
	createCodeMemoMu.Lock()
	defer createCodeMemoMu.Unlock()
	return len(createCodeMemo)
}

func TestCreateCodeMemoPurgeDropsExpired(t *testing.T) {
	now := memoClock(t)
	rememberCreatedCode("memo-gus", "memo gus passphrase", "one two three")
	*now = now.Add(createCodeMemoTTL + time.Second)
	purgeExpiredCreatedCodes()
	if n := memoLen(); n != 0 {
		t.Fatalf("%d entries left after the purge, want none", n)
	}
}

func TestCreateCodeMemoPurgeKeepsLive(t *testing.T) {
	now := memoClock(t)
	rememberCreatedCode("memo-hal", "memo hal passphrase", "one two three")
	*now = now.Add(4 * time.Minute)
	purgeExpiredCreatedCodes()
	if got := takeCreatedCode("memo-hal", "memo hal passphrase"); got != "one two three" {
		t.Fatalf("a live entry was purged: %q", got)
	}
	if got := takeCreatedCode("memo-hal", "memo hal passphrase"); got != "" {
		t.Fatalf("second take = %q, want nothing", got)
	}
}

func TestCreateCodeMemoRememberPurgesOthers(t *testing.T) {
	now := memoClock(t)
	rememberCreatedCode("memo-ivy", "memo ivy passphrase", "one two three")
	*now = now.Add(6 * time.Minute)
	rememberCreatedCode("memo-jon", "memo jon passphrase", "four five six")
	createCodeMemoMu.Lock()
	_, hasA := createCodeMemo[createCodeMemoKey("memo-ivy", "memo ivy passphrase")]
	_, hasB := createCodeMemo[createCodeMemoKey("memo-jon", "memo jon passphrase")]
	n := len(createCodeMemo)
	createCodeMemoMu.Unlock()
	if hasA || !hasB || n != 1 {
		t.Fatalf("after remember: expired kept=%v, new kept=%v, entries=%d; want only the new one", hasA, hasB, n)
	}
}

// syncLoop must purge once per cycle, after its sleep and before it takes sessionMu.
func TestCreateCodeMemoSyncLoopPurges(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "main.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	sleep, purge, lock := token.NoPos, token.NoPos, token.NoPos
	for _, d := range f.Decls {
		fn, ok := d.(*ast.FuncDecl)
		if !ok || fn.Name.Name != "syncLoop" {
			continue
		}
		ast.Inspect(fn.Body, func(n ast.Node) bool {
			c, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			switch fx := c.Fun.(type) {
			case *ast.Ident:
				if fx.Name == "syncLoopSleep" && sleep == token.NoPos {
					sleep = c.Pos()
				}
				if fx.Name == "purgeExpiredCreatedCodes" && purge == token.NoPos {
					purge = c.Pos()
				}
			case *ast.SelectorExpr:
				if x, ok := fx.X.(*ast.Ident); ok && x.Name == "sessionMu" && fx.Sel.Name == "TryLock" && lock == token.NoPos {
					lock = c.Pos()
				}
			}
			return true
		})
	}
	if sleep == token.NoPos || purge == token.NoPos || lock == token.NoPos {
		t.Fatalf("syncLoop: sleep=%v purge=%v first TryLock=%v; all three calls must be there", sleep, purge, lock)
	}
	if !(sleep < purge && purge < lock) {
		t.Fatalf("syncLoop must call purgeExpiredCreatedCodes after syncLoopSleep and before the first sessionMu.TryLock")
	}
}
