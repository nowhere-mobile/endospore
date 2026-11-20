package main

// NWP-20261208-16 (h57 #6, docs/product-decisions.md 2026-11-04): REMOVE-FIDO2-KEY-NFC is the NFC tap of the key
// removal. These tests drive it through handleLogin over net.Pipe with nfcAssert stubbed, on rktVault profiles whose
// sign-in cached key A in .fido2hmac. The permitted rule (h53 #3) is removeFido2KeyTapped's, unchanged. No test here
// reaches a real NFC key. test-remove-key-tap.sh re-runs these against mutants of fido2_nfc_remove.go.

import (
	"bufio"
	"encoding/hex"
	"go/ast"
	"go/parser"
	"go/token"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

type rknArm struct {
	name, pass, dest string
	keys             []rktKey
	calls            int
	slots            []fido2SlotInfo // what the last nfcAssert call got
}

// rknSetup is a stored session of name with one key per tag, whose sign-in cached the first key's hmac in
// .fido2hmac and in NOWHERE_FIDO2_HMAC. nfcAssert answers nothing until a test calls stub.
func rknSetup(t *testing.T, name string, tags ...string) *rknArm {
	t.Helper()
	a := &rknArm{name: name, pass: "pw " + name, dest: t.TempDir()}
	a.keys = rktVault(t, a.name, a.pass, tags...)
	t.Setenv("NOWHERE_STATE", a.dest)
	if err := markRoamSession(a.dest, a.name, a.pass, euUID, ""); err != nil {
		t.Fatal(err)
	}
	a.cache(t, a.keys[0].hmac)
	a.stub(t, nil, nil)
	return a
}

// cache writes h as the hmac the sign-in cached, in .fido2hmac and in the env (t.Setenv restores the env).
func (a *rknArm) cache(t *testing.T, h []byte) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(a.dest, ".fido2hmac"), []byte(hex.EncodeToString(h)), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(h))
}

// stub replaces nfcAssert with one that answers (tap, tapErr) and records its calls and the slots it got.
func (a *rknArm) stub(t *testing.T, tap []byte, tapErr error) {
	t.Helper()
	old := nfcAssert
	nfcAssert = func(_ transceiver, slots []fido2SlotInfo) ([]byte, error) {
		a.calls++
		a.slots = slots
		return tap, tapErr
	}
	t.Cleanup(func() { nfcAssert = old })
}

func (a *rknArm) send(t *testing.T, credID string) string {
	t.Helper()
	cli, srv := net.Pipe()
	done := make(chan struct{})
	go func() { handleLogin(srv, a.dest); close(done) }()
	if _, err := cli.Write([]byte("REMOVE-FIDO2-KEY-NFC\n" + credID + "\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	line, err := bufio.NewReader(cli).ReadString('\n')
	cli.Close()
	<-done
	if err != nil {
		t.Fatalf("REMOVE-FIDO2-KEY-NFC: no reply line (%v), got %q", err, line)
	}
	return strings.TrimSpace(line)
}

// rknStash is the .fido2hmac contents, "" when it is absent.
func rknStash(t *testing.T, dest string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dest, ".fido2hmac"))
	if err != nil {
		return ""
	}
	return string(b)
}

func TestRemoveKeyNFCN1RemainingKeyRemoves(t *testing.T) {
	a := rknSetup(t, "rkn-n1", "rkn-n1-a", "rkn-n1-b")
	a.stub(t, a.keys[1].hmac, nil)
	if got := a.send(t, a.keys[0].cred); got != "OK true" {
		t.Fatalf("remove A with an NFC tap of B: reply %q, want OK true", got)
	}
	if _, creds := rktHead(t, a.name, a.pass); len(creds) != 1 || creds[0] != a.keys[1].cred {
		t.Errorf("after removing A the head holds %v, want only B", creds)
	}
	if rknStash(t, a.dest) != hex.EncodeToString(a.keys[1].hmac) {
		t.Error(".fido2hmac does not hold the tapped key B's hmac: the session's next seal opens with no key it still has")
	}
	if a.calls != 1 || len(a.slots) != 2 {
		t.Errorf("nfcAssert ran %d time(s) with %d slot(s), want once with both enrolled slots", a.calls, len(a.slots))
	}
}

func TestRemoveKeyNFCN2KeyBeingRemovedRefused(t *testing.T) {
	a := rknSetup(t, "rkn-n2", "rkn-n2-a", "rkn-n2-b")
	head, _ := rktHead(t, a.name, a.pass)
	a.stub(t, a.keys[0].hmac, nil)
	if got := a.send(t, a.keys[0].cred); got != "ERR-WRONGKEY" {
		t.Errorf("remove A with an NFC tap of A: reply %q, want ERR-WRONGKEY", got)
	}
	rktUnchanged(t, a.name, a.pass, head, 2)
}

func TestRemoveKeyNFCN3UnenrolledTapRefused(t *testing.T) {
	a := rknSetup(t, "rkn-n3", "rkn-n3-a", "rkn-n3-b")
	head, _ := rktHead(t, a.name, a.pass)
	a.stub(t, rktNewKey(t, "rkn-n3-stranger").hmac, nil)
	if got := a.send(t, a.keys[0].cred); got != "ERR-NOKEY" {
		t.Errorf("remove A with a never-enrolled key's tap: reply %q, want ERR-NOKEY", got)
	}
	rktUnchanged(t, a.name, a.pass, head, 2)
	if rknStash(t, a.dest) != hex.EncodeToString(a.keys[0].hmac) {
		t.Error("a tap that opens no slot replaced the .fido2hmac that still opens the vault")
	}
}

func TestRemoveKeyNFCN4LinkLost(t *testing.T) {
	a := rknSetup(t, "rkn-n4", "rkn-n4-a", "rkn-n4-b")
	head, _ := rktHead(t, a.name, a.pass)
	a.stub(t, nil, &nfcLinkError{"rkn-n4: tag lost"})
	if got := a.send(t, a.keys[0].cred); got != "ERR-NOKEY" {
		t.Errorf("remove A with the NFC link lost: reply %q, want ERR-NOKEY", got)
	}
	rktUnchanged(t, a.name, a.pass, head, 2)
	if rknStash(t, a.dest) != hex.EncodeToString(a.keys[0].hmac) {
		t.Error("a lost NFC link changed .fido2hmac")
	}
}

func TestRemoveKeyNFCN5CachedHmacIsNotATap(t *testing.T) {
	a := rknSetup(t, "rkn-n5", "rkn-n5-a", "rkn-n5-b")
	a.cache(t, a.keys[1].hmac) // B is a permitted key for removing A, but only as a fresh tap
	head, _ := rktHead(t, a.name, a.pass)
	a.stub(t, nil, nil)
	if got := a.send(t, a.keys[0].cred); got != "ERR-NOKEY" {
		t.Errorf("remove A with no tap and B's hmac cached: reply %q, want ERR-NOKEY", got)
	}
	rktUnchanged(t, a.name, a.pass, head, 2)
}

func TestRemoveKeyNFCN6LastKeyWithItsOwnTap(t *testing.T) {
	a := rknSetup(t, "rkn-n6", "rkn-n6-a")
	a.stub(t, a.keys[0].hmac, nil)
	if got := a.send(t, a.keys[0].cred); got != "OK false" {
		t.Fatalf("remove the last key A with an NFC tap of A: reply %q, want OK false", got)
	}
	if _, creds := rktHead(t, a.name, a.pass); len(creds) != 0 {
		t.Errorf("after removing the last key the head still holds %v", creds)
	}
	if _, err := os.Stat(filepath.Join(a.dest, ".fido2hmac")); !os.IsNotExist(err) {
		t.Error(".fido2hmac is still there after the last key went: a later cold lock binds a keyless vault to a key")
	}
	if os.Getenv("NOWHERE_FIDO2_HMAC") != "" {
		t.Error("NOWHERE_FIDO2_HMAC is still set after the last key went")
	}
}

func TestRemoveKeyNFCN7NoStoredSession(t *testing.T) {
	a := rknSetup(t, "rkn-n7", "rkn-n7-a", "rkn-n7-b")
	head, _ := rktHead(t, a.name, a.pass)
	a.stub(t, a.keys[1].hmac, nil)
	stored := a.dest
	a.dest = t.TempDir() // no .roamsession
	t.Setenv("NOWHERE_STATE", a.dest)
	if got := a.send(t, a.keys[0].cred); got != "ERR-NOSESSION" {
		t.Errorf("no session: reply %q, want ERR-NOSESSION", got)
	}
	a.dest = stored
	t.Setenv("NOWHERE_STATE", a.dest)
	for i, mark := range []func(string){markLocalSession, markOfflineSession} {
		mark(a.dest)
		if got := a.send(t, a.keys[0].cred); got != "ERR-NOTSTORED" {
			t.Errorf("%s session: reply %q, want ERR-NOTSTORED", []string{"local", "offline"}[i], got)
		}
	}
	if a.calls != 0 {
		t.Errorf("nfcAssert ran %d time(s) for a session with no stored profile", a.calls)
	}
	rktUnchanged(t, a.name, a.pass, head, 2)
}

func TestRemoveKeyNFCN8MissingCredIDLine(t *testing.T) {
	dest := t.TempDir()
	t.Setenv("NOWHERE_STATE", dest)
	a := &rknArm{dest: dest}
	a.stub(t, make([]byte, fido2HMACLen), nil)
	for _, req := range []string{"REMOVE-FIDO2-KEY-NFC\n", "REMOVE-FIDO2-KEY-NFC\nAAAA"} {
		if got := strings.TrimSpace(strictArgDrive(t, dest, req)); got != "ERR" {
			t.Errorf("%q (the credID line has no LF): reply %q, want ERR before the session read", req, got)
		}
	}
	if got := strings.TrimSpace(strictArgDrive(t, dest, "REMOVE-FIDO2-KEY-NFC\nAAAA\n")); got != "ERR-NOSESSION" {
		t.Errorf("control, a terminated credID line with no session: reply %q, want ERR-NOSESSION", got)
	}
	if a.calls != 0 {
		t.Errorf("nfcAssert ran %d time(s) on a request with no session", a.calls)
	}
}

// N9 reads fido2_nfc_remove.go as source: the tapped removal only, no log line that formats a secret or the
// profile, and a long deadline set again after the assert (nfcShuttle sets 30 s on every APDU, #744).
func TestRemoveKeyNFCN9Source(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "fido2_nfc_remove.go", nil, 0)
	if err != nil {
		t.Fatalf("fido2_nfc_remove.go: %v", err)
	}
	var fn *ast.FuncDecl
	for _, d := range f.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok && fd.Name.Name == "handleRemoveFido2KeyNFC" {
			fn = fd
		}
	}
	if fn == nil {
		t.Fatal("fido2_nfc_remove.go declares no handleRemoveFido2KeyNFC")
	}
	secret := map[string]bool{"nm": true, "ps": true, "cid": true, "h": true, "err": true, "rmErr": true}
	tapped, plain := 0, 0
	var assertAt, vaultOpAt token.Pos
	var deadlines []token.Pos
	ast.Inspect(fn.Body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		switch fun := call.Fun.(type) {
		case *ast.Ident:
			switch fun.Name {
			case "removeFido2KeyTapped":
				tapped++
			case "removeFido2Key":
				plain++
			case "nfcAssert":
				if assertAt == token.NoPos {
					assertAt = call.Pos()
				}
			case "daemonVaultOp":
				vaultOpAt = call.Pos()
			}
		case *ast.SelectorExpr:
			x, _ := fun.X.(*ast.Ident)
			if x == nil {
				return true
			}
			if x.Name == "fmt" && strings.HasPrefix(fun.Sel.Name, "Fprint") && len(call.Args) > 0 {
				if w, ok := call.Args[0].(*ast.SelectorExpr); ok && w.Sel.Name == "Stderr" {
					for _, arg := range call.Args[1:] {
						ast.Inspect(arg, func(m ast.Node) bool {
							if id, ok := m.(*ast.Ident); ok && secret[id.Name] {
								t.Errorf("%s: a log line formats %s, which can carry the profile, a credID or an hmac", fset.Position(call.Pos()), id.Name)
							}
							return true
						})
					}
				}
			}
			if x.Name == "conn" && fun.Sel.Name == "SetDeadline" && rknDeadlineSecs(call) >= 120 {
				deadlines = append(deadlines, call.Pos())
			}
		}
		return true
	})
	if tapped != 1 || plain != 0 {
		t.Errorf("removeFido2KeyTapped called %d time(s), removeFido2Key %d: want the tapped removal once, never the untapped one", tapped, plain)
	}
	if assertAt == token.NoPos || vaultOpAt == token.NoPos {
		t.Fatal("no nfcAssert call or no daemonVaultOp call")
	}
	ok := false
	for _, p := range deadlines {
		if p > assertAt && p < vaultOpAt {
			ok = true
		}
	}
	if !ok {
		t.Error("no conn.SetDeadline of 120 s or more between nfcAssert and daemonVaultOp: the APDU shuttle left a 30 s deadline, so a removal that completes after it loses its reply (#744)")
	}
}

// rknDeadlineSecs reads N from conn.SetDeadline(time.Now().Add(N * time.Second)); 0 for any other shape.
func rknDeadlineSecs(call *ast.CallExpr) int {
	if len(call.Args) != 1 {
		return 0
	}
	add, ok := call.Args[0].(*ast.CallExpr)
	if !ok || len(add.Args) != 1 {
		return 0
	}
	mul, ok := add.Args[0].(*ast.BinaryExpr)
	if !ok || mul.Op != token.MUL {
		return 0
	}
	lit, ok := mul.X.(*ast.BasicLit)
	if !ok {
		return 0
	}
	n, _ := strconv.Atoi(lit.Value)
	return n
}
