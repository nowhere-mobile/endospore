package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20260928-01: the device-owner telephony key (owner_key.go).

const ownerTestPass = "correct-horse-owner-42"

var ownerTestPepper = bytes.Repeat([]byte{0x5a}, ownerPepperLen)

// useTempOwnerKey points the key file at a fresh temp dir.
func useTempOwnerKey(t *testing.T) string {
	t.Helper()
	old := ownerKeyPath
	ownerKeyPath = filepath.Join(t.TempDir(), "owner-key")
	t.Cleanup(func() { ownerKeyPath = old })
	return ownerKeyPath
}

// asCaller makes the handler see peer uid `uid`, with `pinned` as the pinned chooser appId.
func asCaller(t *testing.T, uid, pinned int) {
	t.Helper()
	oldPeer, oldPin := ownerPeerUID, pinnedChooserApp
	ownerPeerUID = func(net.Conn) int { return uid }
	pinnedChooserApp = pinned
	t.Cleanup(func() { ownerPeerUID, pinnedChooserApp = oldPeer, oldPin })
}

// asGate makes the caller the user-0 gate chooser.
func asGate(t *testing.T) { asCaller(t, 10123, 10123) }

func ownerReq(verb string, pepper []byte, pass string) string {
	p := "-"
	if pepper != nil {
		p = base64.StdEncoding.EncodeToString(pepper)
	}
	return verb + "\nv1\n" + p + "\n" + base64.StdEncoding.EncodeToString([]byte(pass)) + "\n"
}

func ensure(t *testing.T, pepper []byte, pass string) string {
	t.Helper()
	return driveLogin(t, t.TempDir(), ownerReq("OWNER-KEY-ENSURE", pepper, pass))
}

func mustReadOwnerKey(t *testing.T) (ownerKeyFile, []byte) {
	t.Helper()
	f, st, err := readOwnerKey()
	if err != nil || st != ownerKeyValid {
		t.Fatalf("owner key state %v, err %v; want a valid file", st, err)
	}
	b, err := os.ReadFile(ownerKeyPath)
	if err != nil {
		t.Fatal(err)
	}
	return f, b
}

// TestOwnerKeyEnsureCreatesAndOpens: the first verify mints a key, the file has exactly the v1 grammar, and the
// private half opens under the passphrase and opens what the existing seal code seals to the public half.
func TestOwnerKeyEnsureCreatesAndOpens(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	if got := ensure(t, nil, ownerTestPass); got != "CREATED" {
		t.Fatalf("ENSURE on no file replied %q, want CREATED", got)
	}
	fi, err := os.Stat(ownerKeyPath)
	if err != nil {
		t.Fatalf("no key file after CREATED: %v", err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("key file mode %v, want 0600", fi.Mode().Perm())
	}
	f, b := mustReadOwnerKey(t)
	if s := string(b); strings.Count(s, "\n") != 5 || !strings.HasSuffix(s, "\n") || strings.Contains(s, "\r") {
		t.Fatalf("key file is not five LF-terminated lines: %q", s)
	}
	if f.pepper != "none" {
		t.Fatalf("pepper=%s, want none", f.pepper)
	}
	priv, pub, ok := ownerKeyOpen(f, []byte(ownerTestPass), nil)
	if !ok || pub != f.pub {
		t.Fatalf("the key does not open, or its public half differs (ok %v)", ok)
	}
	blob, err := sealTelItem(f.pub, testSMS)
	if err != nil {
		t.Fatal(err)
	}
	it, err := openTelItem(priv, blob)
	if err != nil || it.Body != testSMS.Body {
		t.Fatalf("seal-to-owner round trip failed: %v", err)
	}
}

// TestOwnerKeyEnsureIsIdempotent: a second verify with the same passphrase writes nothing.
func TestOwnerKeyEnsureIsIdempotent(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	ensure(t, nil, ownerTestPass)
	_, before := mustReadOwnerKey(t)
	runs := ownerKEKRuns.Load()
	renames := 0
	old := ownerKeyRename
	ownerKeyRename = func(a, b string) error { renames++; return old(a, b) }
	defer func() { ownerKeyRename = old }()
	if got := ensure(t, nil, ownerTestPass); got != "OK" {
		t.Fatalf("second ENSURE replied %q, want OK", got)
	}
	if _, after := mustReadOwnerKey(t); !bytes.Equal(before, after) || renames != 0 {
		t.Fatalf("an ENSURE that opened the key wrote the file (%d publish(es))", renames)
	}
	if d := ownerKEKRuns.Load() - runs; d != 1 {
		t.Fatalf("a second ENSURE derived %d times, want 1", d)
	}
}

// TestOwnerKeyEnsureReplacesAKeyThatDoesNotOpen: a verify has admitted this passphrase, so a key it cannot open can
// never be opened by anyone the verify admits; it is replaced, not kept.
func TestOwnerKeyEnsureReplacesAKeyThatDoesNotOpen(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	ensure(t, nil, ownerTestPass)
	old, _ := mustReadOwnerKey(t)
	if got := ensure(t, nil, "another owner secret"); got != "REPLACED" {
		t.Fatalf("ENSURE with a passphrase the key does not open replied %q, want REPLACED", got)
	}
	f, _ := mustReadOwnerKey(t)
	if f.pub == old.pub {
		t.Fatal("the replacement kept the old keypair")
	}
	if _, _, ok := ownerKeyOpen(f, []byte("another owner secret"), nil); !ok {
		t.Fatal("the replacement does not open with the verified passphrase")
	}
	if _, _, ok := ownerKeyOpen(f, []byte(ownerTestPass), nil); ok {
		t.Fatal("the replacement opens with the old passphrase")
	}
}

// TestOwnerKeyNewAlwaysMints: an enrol is a new owner, so NEW mints whatever is there -- even a newer-format file.
func TestOwnerKeyNewAlwaysMints(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	if got := driveLogin(t, t.TempDir(), ownerReq("OWNER-KEY-NEW", nil, ownerTestPass)); got != "CREATED" {
		t.Fatalf("NEW on no file replied %q, want CREATED", got)
	}
	a, _ := mustReadOwnerKey(t)
	if got := driveLogin(t, t.TempDir(), ownerReq("OWNER-KEY-NEW", nil, ownerTestPass)); got != "REPLACED" {
		t.Fatalf("NEW over a key replied %q, want REPLACED", got)
	}
	b, _ := mustReadOwnerKey(t)
	if a.pub == b.pub || bytes.Equal(a.salt, b.salt) {
		t.Fatal("NEW reused the keypair or the salt")
	}
	if err := os.WriteFile(ownerKeyPath, []byte("nowhere-owner-key v3\nx\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := driveLogin(t, t.TempDir(), ownerReq("OWNER-KEY-NEW", nil, ownerTestPass)); got != "REPLACED" {
		t.Fatalf("NEW over a newer-format file replied %q, want REPLACED", got)
	}
	mustReadOwnerKey(t)
}

// TestOwnerKeyNeverTouchesDeriveKey: deriveKey's cache is keyed by the plaintext secret; the owner key must never
// put the owner passphrase there.
func TestOwnerKeyNeverTouchesDeriveKey(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	deriveKeyMu.Lock()
	misses, cached := deriveKeyMisses, len(deriveKeyCache)
	deriveKeyMu.Unlock()
	ensure(t, nil, ownerTestPass)
	ensure(t, nil, ownerTestPass)
	ensure(t, ownerTestPepper, ownerTestPass)
	driveLogin(t, t.TempDir(), ownerReq("OWNER-KEY-NEW", nil, ownerTestPass))
	deriveKeyMu.Lock()
	defer deriveKeyMu.Unlock()
	if deriveKeyMisses != misses || len(deriveKeyCache) != cached {
		t.Fatalf("the owner-key verbs used deriveKey (misses %d->%d, cache %d->%d)", misses, deriveKeyMisses, cached, len(deriveKeyCache))
	}
	for k := range deriveKeyCache {
		if strings.Contains(k, ownerTestPass) {
			t.Fatal("the owner passphrase is a deriveKey cache key")
		}
	}
}

// TestOwnerKeyReplacesAnUnreadableFile: a file that is not exactly the v1 grammar is replaced at the next verify.
func TestOwnerKeyReplacesAnUnreadableFile(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	ensure(t, nil, ownerTestPass)
	_, good := mustReadOwnerKey(t)
	g := string(good)
	lines := strings.Split(strings.TrimSuffix(g, "\n"), "\n")
	for what, body := range map[string]string{
		"empty":            "",
		"truncated":        g[:len(g)/2],
		"no final newline": strings.TrimSuffix(g, "\n"),
		"CRLF":             strings.ReplaceAll(g, "\n", "\r\n"),
		"an extra line":    g + "x=y\n",
		"a missing line":   strings.Join(lines[:4], "\n") + "\n",
		"bad base64 pub":   strings.Replace(g, lines[1], "pub=!!!", 1),
		"short salt":       strings.Replace(g, lines[3], "salt="+base64.StdEncoding.EncodeToString(make([]byte, 16)), 1),
		"unknown pepper":   strings.Replace(g, lines[2], "pepper=maybe", 1),
		"a v1-ish header":  strings.Replace(g, lines[0], "nowhere-owner-key v1.1", 1),
	} {
		if err := os.WriteFile(ownerKeyPath, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := ensure(t, nil, ownerTestPass); got != "REPLACED" {
			t.Fatalf("%s: ENSURE replied %q, want REPLACED", what, got)
		}
		mustReadOwnerKey(t)
	}
}

// TestOwnerKeyKeepsANewerFile: an older agent after a rollback must not destroy a key a newer build can open.
func TestOwnerKeyKeepsANewerFile(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	newer := []byte("nowhere-owner-key v3\nwhatever the newer format holds\n")
	if err := os.WriteFile(ownerKeyPath, newer, 0o600); err != nil {
		t.Fatal(err)
	}
	if got := ensure(t, nil, ownerTestPass); got != "ERR version" {
		t.Fatalf("ENSURE over a newer-format file replied %q, want ERR version", got)
	}
	if b, _ := os.ReadFile(ownerKeyPath); !bytes.Equal(b, newer) {
		t.Fatal("ENSURE changed a newer-format file")
	}
}

// TestOwnerKeyRepairsAPublicHalf: wrap() carries no AAD, so a pub= that does not match the private half it wraps is
// rewritten from the private half.
func TestOwnerKeyRepairsAPublicHalf(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	ensure(t, nil, ownerTestPass)
	f, b := mustReadOwnerKey(t)
	other, _, err := newTelephonyKeypair()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ownerKeyPath, []byte(strings.Replace(string(b), "pub="+f.pub, "pub="+other, 1)), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := ensure(t, nil, ownerTestPass); got != "REPAIRED" {
		t.Fatalf("ENSURE over a swapped public half replied %q, want REPAIRED", got)
	}
	if g, _ := mustReadOwnerKey(t); g.pub != f.pub || g.wrapped != f.wrapped {
		t.Fatal("the repair did not restore the public half from the wrapped private half")
	}
}

// TestOwnerKeyPepper: on a StrongBox phone the wrap also needs the gate's StrongBox pepper, and a key is never
// downgraded to pepperless.
func TestOwnerKeyPepper(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	if got := ensure(t, ownerTestPepper, ownerTestPass); got != "CREATED" {
		t.Fatalf("ENSURE with a pepper replied %q", got)
	}
	f, b := mustReadOwnerKey(t)
	if f.pepper != "strongbox" {
		t.Fatalf("pepper=%s, want strongbox", f.pepper)
	}
	if _, _, ok := ownerKeyOpen(f, []byte(ownerTestPass), nil); ok {
		t.Fatal("a StrongBox key opens without its pepper")
	}
	if got := ensure(t, nil, ownerTestPass); got != "ERR mode" {
		t.Fatalf("a pepperless ENSURE on a StrongBox key replied %q, want ERR mode", got)
	}
	if after, _ := os.ReadFile(ownerKeyPath); !bytes.Equal(after, b) {
		t.Fatal("a pepperless ENSURE changed a StrongBox key")
	}
	if got := ensure(t, bytes.Repeat([]byte{0x33}, ownerPepperLen), ownerTestPass); got != "REPLACED" {
		t.Fatalf("ENSURE with another pepper replied %q, want REPLACED", got)
	}
	useTempOwnerKey(t)
	ensure(t, nil, ownerTestPass)
	if got := ensure(t, ownerTestPepper, ownerTestPass); got != "REPLACED" {
		t.Fatalf("ENSURE with a pepper on a pepperless key replied %q, want REPLACED", got)
	}
	if g, _ := mustReadOwnerKey(t); g.pepper != "strongbox" {
		t.Fatal("the key did not become a StrongBox key")
	}
}

// TestOwnerCallerOK: only the user-0 gate chooser -- not a roamed session's chooser (same appId, another user), not
// root (which skips the accept-time pin), not a system uid that became the pin by connecting first, not a failed
// peer lookup (-1) against an unpinned daemon.
func TestOwnerCallerOK(t *testing.T) {
	old := pinnedChooserApp
	t.Cleanup(func() { pinnedChooserApp = old })
	pinnedChooserApp = 10123
	for uid, want := range map[int]bool{10123: true, 10124: false, 1010123: false, 110123: false, 0: false, 1000: false, -1: false} {
		if got := ownerCallerOK(uid); got != want {
			t.Fatalf("ownerCallerOK(%d) = %v with the chooser pinned at 10123, want %v", uid, got, want)
		}
	}
	pinnedChooserApp = -1
	if ownerCallerOK(10123) {
		t.Fatal("an unpinned daemon admitted a caller")
	}
	// Only the floor refuses these: the uid equals the pin.
	for _, pin := range []int{1000, 2000, 0, -1} {
		pinnedChooserApp = pin
		if ownerCallerOK(pin) {
			t.Fatalf("ownerCallerOK(%d) admitted a caller below the app-uid floor pinned at %d", pin, pin)
		}
	}
}

// TestOwnerKeyRefusesAnyoneButTheGate: a refused caller gets DENIED before the request body is read, nothing is
// derived or written, and the reply is the same whether or not a key exists.
func TestOwnerKeyRefusesAnyoneButTheGate(t *testing.T) {
	useTempOwnerKey(t)
	asCaller(t, 1010123, 10123) // the chooser, in a roamed user
	runs := ownerKEKRuns.Load()
	done := make(chan string, 1)
	go func() { done <- driveLogin(t, t.TempDir(), "OWNER-KEY-ENSURE\n") }() // no body at all
	select {
	case got := <-done:
		if got != "DENIED" {
			t.Fatalf("a roamed chooser got %q, want DENIED", got)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the refusal waited for a request body")
	}
	if _, err := os.Stat(ownerKeyPath); !os.IsNotExist(err) || ownerKEKRuns.Load() != runs {
		t.Fatal("a refused caller created a key or derived")
	}
	asGate(t)
	ensure(t, nil, ownerTestPass)
	_, before := mustReadOwnerKey(t)
	asCaller(t, 1010123, 10123)
	if got := ensure(t, nil, "attacker"); got != "DENIED" {
		t.Fatalf("with a key present a roamed chooser got %q, want the same DENIED", got)
	}
	if _, after := mustReadOwnerKey(t); !bytes.Equal(before, after) {
		t.Fatal("a refused caller changed the key")
	}
	// The real peer lookup: net.Pipe has no peer uid, so it is refused too.
	oldPeer := ownerPeerUID
	ownerPeerUID = peerUID
	defer func() { ownerPeerUID = oldPeer }()
	if got := ensure(t, nil, ownerTestPass); got != "DENIED" {
		t.Fatalf("a caller with no peer uid got %q, want DENIED", got)
	}
}

// TestOwnerKeyNeverWaitsForSessionMu: an owner verify must not stall behind a login or a 43.6 s CLEAN-STORAGE.
func TestOwnerKeyNeverWaitsForSessionMu(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	sessionMu.Lock()
	held := true
	defer func() {
		if held {
			sessionMu.Unlock()
		}
	}()
	done := make(chan string, 1)
	go func() { done <- ensure(t, nil, ownerTestPass) }()
	select {
	case got := <-done:
		if got != "CREATED" {
			t.Fatalf("ENSURE replied %q", got)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("ENSURE waited on sessionMu")
	}
	sessionMu.Unlock()
	held = false
}

// TestOwnerKeyDerivesOutsideTelMu: the Argon2 derivation runs while telMu is held elsewhere (an arrival must never
// wait on it), and ENSURE completes once telMu is released. TestOwnerKeyPublishesUnderTelMu pins that the publishing
// rename takes telMu.
func TestOwnerKeyDerivesOutsideTelMu(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	runs := ownerKEKRuns.Load()
	telMu.Lock()
	locked := true
	defer func() {
		if locked {
			telMu.Unlock()
		}
	}()
	done := make(chan string, 1)
	go func() { done <- ensure(t, nil, ownerTestPass) }()
	deadline := time.Now().Add(20 * time.Second)
	for ownerKEKRuns.Load() == runs {
		if time.Now().After(deadline) {
			t.Fatal("the derivation did not run while telMu was held")
		}
		time.Sleep(10 * time.Millisecond)
	}
	telMu.Unlock()
	locked = false
	select {
	case got := <-done:
		if got != "CREATED" {
			t.Fatalf("ENSURE replied %q, want CREATED", got)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("ENSURE did not finish after telMu was released")
	}
}

// TestOwnerKeyPublishesUnderTelMu: the publishing rename runs with telMu held -- checked at the rename itself, so it
// does not depend on how long Argon2 takes. Nothing else holds telMu here (no test in the package runs in parallel).
func TestOwnerKeyPublishesUnderTelMu(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	var free atomic.Bool
	var calls atomic.Int32
	old := ownerKeyRename
	ownerKeyRename = func(a, b string) error {
		calls.Add(1)
		if telMu.TryLock() {
			telMu.Unlock()
			free.Store(true)
		}
		return old(a, b)
	}
	defer func() { ownerKeyRename = old }()
	for _, req := range []string{ownerReq("OWNER-KEY-NEW", nil, ownerTestPass), ownerReq("OWNER-KEY-ENSURE", nil, "another owner secret")} {
		if got := driveLogin(t, t.TempDir(), req); got != "CREATED" && got != "REPLACED" {
			t.Fatalf("replied %q", got)
		}
	}
	if n := calls.Load(); n != 2 {
		t.Fatalf("control: %d publish(es) went through ownerKeyRename, want 2 -- the telMu check saw nothing", n)
	}
	if free.Load() {
		t.Fatal("the key file was published without telMu held")
	}
}

// TestOwnerKeySourcePins pins what the behavioural tests cannot see: the route comes before sessionMu, the reply is
// written after ownerKeyMu is released, only the rename is under telMu, and nothing uses the agent's cached KDF.
func TestOwnerKeySourcePins(t *testing.T) {
	read := func(f string) string {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	at := func(lines []string, s string) int {
		for i, l := range lines {
			if strings.Contains(l, s) {
				return i
			}
		}
		return -1
	}
	login := stripComments(funcBody(t, read("main.go"), "handleLogin"))
	if r, s := at(login, "ownerKeyCmd(name)"), at(login, "sessionMu.TryLock"); r < 0 || s < 0 || r > s {
		t.Fatalf("the owner-key route (%d) must come before sessionMu (%d)", r, s)
	}
	src := read("owner_key.go")
	h := stripComments(funcBody(t, src, "handleOwnerKey"))
	// The lock lives only inside the reply closure, and the reply is written after the closure has returned -- a
	// `defer ownerKeyMu.Unlock()` in the handler body would pass a mere line-order check while writing under the lock.
	open, closed := at(h, "reply := func() string {"), -1
	for i := open + 1; open >= 0 && i < len(h); i++ {
		if strings.TrimSpace(h[i]) == "}()" {
			closed = i
			break
		}
	}
	if w := at(h, `fmt.Fprintf(conn, "%s\n", reply)`); open < 0 || closed < 0 || w < closed {
		t.Fatal("handleOwnerKey writes its reply before the locked closure has returned")
	}
	for i, l := range h {
		if strings.Contains(l, "ownerKeyMu.") && (i <= open || i >= closed) {
			t.Fatalf("handleOwnerKey touches ownerKeyMu outside the reply closure: %s", strings.TrimSpace(l))
		}
	}
	if c, rd := at(h, "ownerCallerOK("), at(h, "readOwnerKeyRequest("); c < 0 || rd < 0 || c > rd {
		t.Fatal("handleOwnerKey reads the request before it checks the caller")
	}
	w := stripComments(funcBody(t, src, "ownerKeyWrite"))
	if strings.Count(strings.Join(w, "\n"), "underTelMu(") != 1 || !strings.Contains(w[at(w, "underTelMu(")], "ownerKeyRename(") {
		t.Fatal("ownerKeyWrite must take telMu once, around the rename only")
	}
	code := strings.Join(stripComments(strings.Split(src, "\n")), "\n")
	for _, bad := range []string{"deriveKey(", "argon2Key(", "deriveKeyUncached("} {
		if strings.Contains(code, bad) {
			t.Fatalf("owner_key.go calls %s", bad)
		}
	}
}

// TestOwnerKeyConcurrentEnsures: two verifies at once end with one keypair.
func TestOwnerKeyConcurrentEnsures(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	var wg sync.WaitGroup
	replies := make([]string, 2)
	for i := range replies {
		wg.Add(1)
		go func(i int) { defer wg.Done(); replies[i] = ensure(t, nil, ownerTestPass) }(i)
	}
	wg.Wait()
	if !(replies[0] == "CREATED" && replies[1] == "OK" || replies[0] == "OK" && replies[1] == "CREATED") {
		t.Fatalf("two concurrent ENSUREs replied %v, want one CREATED and one OK", replies)
	}
	f, _ := mustReadOwnerKey(t)
	if _, _, ok := ownerKeyOpen(f, []byte(ownerTestPass), nil); !ok {
		t.Fatal("the key does not open")
	}
}

// TestOwnerKeyWriteFailureKeepsTheOldFile: a failed publish leaves the old file byte-identical and no temp file.
func TestOwnerKeyWriteFailureKeepsTheOldFile(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	ensure(t, nil, ownerTestPass)
	_, before := mustReadOwnerKey(t)
	old := ownerKeyRename
	ownerKeyRename = func(string, string) error { return os.ErrPermission }
	defer func() { ownerKeyRename = old }()
	if got := ensure(t, nil, "another owner secret"); got != "ERR io" {
		t.Fatalf("a failed publish replied %q, want ERR io", got)
	}
	if _, after := mustReadOwnerKey(t); !bytes.Equal(before, after) {
		t.Fatal("a failed publish changed the old file")
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(ownerKeyPath), ".owner-key.tmp")); !os.IsNotExist(err) {
		t.Fatal("a failed publish left its temp file")
	}
}

// TestOwnerKeyBadRequests: a malformed request derives nothing and writes nothing.
func TestOwnerKeyBadRequests(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	b64 := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
	runs := ownerKEKRuns.Load()
	for what, req := range map[string]string{
		"an unknown version": "OWNER-KEY-ENSURE\nv2\n-\n" + b64(ownerTestPass) + "\n",
		"a raw passphrase":   "OWNER-KEY-ENSURE\nv1\n-\n" + ownerTestPass + "!\n",
		"an empty secret":    "OWNER-KEY-ENSURE\nv1\n-\n\n",
		"an oversize secret": "OWNER-KEY-ENSURE\nv1\n-\n" + b64(strings.Repeat("x", ownerPassMax+1)) + "\n",
		"a 31-byte pepper":   "OWNER-KEY-ENSURE\nv1\n" + base64.StdEncoding.EncodeToString(make([]byte, 31)) + "\n" + b64(ownerTestPass) + "\n",
		"a pepper not b64":   "OWNER-KEY-ENSURE\nv1\n?\n" + b64(ownerTestPass) + "\n",
	} {
		if got := driveLogin(t, t.TempDir(), req); got != "ERR request" {
			t.Fatalf("%s: replied %q, want ERR request", what, got)
		}
	}
	if _, _, err := readOwnerKeyRequest(bufio.NewReader(strings.NewReader("v1\n-\n"))); err == nil {
		t.Fatal("a request cut short was accepted")
	}
	if _, err := os.Stat(ownerKeyPath); !os.IsNotExist(err) || ownerKEKRuns.Load() != runs {
		t.Fatal("a bad request created a key or derived")
	}
}

// TestOwnerKeyLogsNoSecret: no branch logs the passphrase, the pepper or anything in the key file, and every line it
// does log survives the issue-report scrubber.
func TestOwnerKeyLogsNoSecret(t *testing.T) {
	useTempOwnerKey(t)
	var fileBytes [][]byte
	out := captureStderr(t, func() {
		asGate(t)
		ensure(t, nil, ownerTestPass) // created
		_, b := mustReadOwnerKey(t)
		fileBytes = append(fileBytes, b)
		ensure(t, nil, "another owner secret") // replaced (did not open)
		os.WriteFile(ownerKeyPath, []byte("junk"), 0o600)
		ensure(t, ownerTestPepper, ownerTestPass) // replaced (unreadable file)
		_, b = mustReadOwnerKey(t)
		fileBytes = append(fileBytes, b)
		ensure(t, nil, ownerTestPass)                                                         // ERR mode
		driveLogin(t, t.TempDir(), "OWNER-KEY-ENSURE\nv1\n-\n"+ownerTestPass+"!\n")           // bad request
		driveLogin(t, t.TempDir(), ownerReq("OWNER-KEY-NEW", ownerTestPepper, ownerTestPass)) // minted at enrol
		asCaller(t, 1010123, 10123)
		ensure(t, nil, ownerTestPass) // refused
		// A real OS error: the key's directory does not exist, and ownerKeyWrite never creates it.
		ownerKeyPath = filepath.Join(t.TempDir(), "missing", "owner-key")
		asGate(t)
		if got := ensure(t, nil, ownerTestPass); got != "ERR io" {
			t.Errorf("a missing key directory replied %q, want ERR io", got)
		}
	})
	if !strings.Contains(out, "owner-key write or read failed: open ") {
		t.Fatalf("control: the ERR io line is missing from %q", out)
	}
	if !strings.Contains(out, "owner-key created") {
		t.Fatalf("control: the created line is missing from %q", out)
	}
	secrets := []string{ownerTestPass, "another owner secret", base64.StdEncoding.EncodeToString([]byte(ownerTestPass)),
		base64.StdEncoding.EncodeToString(ownerTestPepper)}
	for _, b := range fileBytes {
		for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n")[1:] {
			_, v, _ := strings.Cut(l, "=")
			secrets = append(secrets, v)
		}
	}
	for _, s := range secrets {
		if strings.Contains(out, s) {
			t.Fatalf("the log carries a secret or a key-file value (%d bytes)", len(s))
		}
	}
	for _, l := range strings.Split(strings.TrimSpace(out), "\n") {
		if strings.Contains(l, "owner-key ") {
			if s, keep := scrubIssueLine(l, nil); !keep || s != l {
				t.Fatalf("the issue-report scrubber drops or rewrites %q -> %q", l, s)
			}
		}
	}
}

// TestOwnerKDFParameters pins the production derivation: Argon2id t=3, 64 MiB, 4 lanes, a 32-byte random salt.
func TestOwnerKDFParameters(t *testing.T) {
	if ownerKDFTime != 3 || ownerKDFMemKiB != 64*1024 || ownerKDFThreads != 4 || ownerSaltLen != 32 {
		t.Fatalf("owner KDF is t=%d m=%d p=%d salt=%d, want t=3 m=65536 p=4 salt=32", ownerKDFTime, ownerKDFMemKiB, ownerKDFThreads, ownerSaltLen)
	}
}
