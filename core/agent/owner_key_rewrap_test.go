package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261021-11: OWNER-KEY-REWRAP, the device-owner key's passphrase change (owner_key.go).

const (
	ownerTestNewPass   = "a-new-owner-credential-7"
	ownerTestThirdPass = "a-third-owner-credential-9"
)

var ownerTestNewPepper = bytes.Repeat([]byte{0xa5}, ownerPepperLen)

func rwB64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

func pepperLine(p []byte) string {
	if p == nil {
		return "-"
	}
	return rwB64(p)
}

func rewrapReq(oldPepper []byte, oldPass string, newPepper []byte, newPass string) string {
	return "OWNER-KEY-REWRAP\nv1\n" + pepperLine(oldPepper) + "\n" + rwB64([]byte(oldPass)) + "\n" +
		pepperLine(newPepper) + "\n" + rwB64([]byte(newPass)) + "\n"
}

func rewrap(t *testing.T, oldPepper []byte, oldPass string, newPepper []byte, newPass string) string {
	t.Helper()
	return driveLogin(t, t.TempDir(), rewrapReq(oldPepper, oldPass, newPepper, newPass))
}

// inboxOpens reports whether the owner inbox's own opener (ownerKeyFromRequest) opens blob under the passphrase.
func inboxOpens(t *testing.T, blob string, pepper []byte, pass string) bool {
	t.Helper()
	req := "v1\n" + pepperLine(pepper) + "\n" + rwB64([]byte(pass)) + "\n"
	priv, err := ownerKeyFromRequest(bufio.NewReader(strings.NewReader(req)))
	if err != nil {
		t.Fatal(err)
	}
	if priv == nil {
		return false
	}
	defer clear(priv)
	it, err := openTelItem(priv, blob)
	return err == nil && it.Body == testSMS.Body
}

func lineCount(b []byte) int { return strings.Count(string(b), "\n") }

// countRenames wraps ownerKeyRename and counts the publishes until the test ends.
func countRenames(t *testing.T) *atomic.Int32 {
	t.Helper()
	var n atomic.Int32
	old := ownerKeyRename
	ownerKeyRename = func(a, b string) error { n.Add(1); return old(a, b) }
	t.Cleanup(func() { ownerKeyRename = old })
	return &n
}

// sealedBeforeRewrap makes a key under ownerTestPass and seals an item to it.
func sealedBeforeRewrap(t *testing.T) (blob string, v1 ownerKeyFile) {
	t.Helper()
	useTempOwnerKey(t)
	asGate(t)
	if got := ensure(t, nil, ownerTestPass); got != "CREATED" {
		t.Fatalf("ENSURE replied %q, want CREATED", got)
	}
	v1, _ = mustReadOwnerKey(t)
	blob, err := sealTelItem(v1.pub, testSMS)
	if err != nil {
		t.Fatal(err)
	}
	return blob, v1
}

// (a) a rewrap over a v1 key keeps the keypair: the seven-line v2, pub unchanged, an item sealed before opens under both.
func TestOwnerKeyRewrap_OverV1KeepsTheKey(t *testing.T) {
	blob, v1 := sealedBeforeRewrap(t)
	if got := rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass); got != "OK" {
		t.Fatalf("REWRAP replied %q, want OK", got)
	}
	f, b := mustReadOwnerKey(t)
	s := string(b)
	if lineCount(b) != 7 || !strings.HasPrefix(s, "nowhere-owner-key v2\n") || strings.Contains(s, "\r") {
		t.Fatalf("the file is not the seven-line v2: %d lines", lineCount(b))
	}
	if f.pub != v1.pub || f.old == nil {
		t.Fatal("the rewrap changed the public half or kept no old wrapping")
	}
	if f.old.wrapped != v1.wrapped || !bytes.Equal(f.old.salt, v1.salt) {
		t.Fatal("the old wrapping is not the one the old passphrase opened")
	}
	if bytes.Equal(f.salt, v1.salt) || f.wrapped == v1.wrapped {
		t.Fatal("the new wrapping reuses the old salt or wrapped value")
	}
	if !inboxOpens(t, blob, nil, ownerTestPass) || !inboxOpens(t, blob, nil, ownerTestNewPass) {
		t.Fatal("an item sealed before the rewrap does not open under both passphrases")
	}
	if inboxOpens(t, blob, nil, ownerTestThirdPass) {
		t.Fatal("a third passphrase opens the inbox")
	}
	if pub, ok := ownerPubForSeal(); !ok || pub != v1.pub {
		t.Fatal("a v2 file does not seal to its shared pub")
	}
}

// (b) the ENSURE under the new passphrase prunes the old wrapping.
func TestOwnerKeyRewrap_EnsureNewPrunes(t *testing.T) {
	blob, v1 := sealedBeforeRewrap(t)
	rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass)
	var got string
	out := captureStderr(t, func() { got = ensure(t, nil, ownerTestNewPass) })
	if got != "REPAIRED" {
		t.Fatalf("ENSURE(new) replied %q, want REPAIRED", got)
	}
	if !strings.Contains(out, "owner-key pruned the old wrapping") {
		t.Fatalf("control: the prune line is missing from %q", out)
	}
	f, b := mustReadOwnerKey(t)
	if lineCount(b) != 5 || !strings.HasPrefix(string(b), "nowhere-owner-key v1\n") || f.old != nil || f.pub != v1.pub {
		t.Fatal("the pruned file is not the five-line v1 with the same pub")
	}
	if _, _, ok := ownerKeyOpen(f, []byte(ownerTestPass), nil); ok {
		t.Fatal("the old passphrase still opens the pruned file")
	}
	if !inboxOpens(t, blob, nil, ownerTestNewPass) || inboxOpens(t, blob, nil, ownerTestPass) {
		t.Fatal("after the prune the item must open under the new passphrase only")
	}
}

// (c) the race: the verify's ENSURE(old) landing after the rewrap writes nothing.
func TestOwnerKeyRewrap_EnsureOldWritesNothing(t *testing.T) {
	blob, _ := sealedBeforeRewrap(t)
	rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass)
	_, before := mustReadOwnerKey(t)
	renames := countRenames(t)
	if got := ensure(t, nil, ownerTestPass); got != "OK" {
		t.Fatalf("ENSURE(old) over a v2 file replied %q, want OK", got)
	}
	if _, after := mustReadOwnerKey(t); !bytes.Equal(before, after) || renames.Load() != 0 {
		t.Fatal("ENSURE(old) wrote the v2 file")
	}
	if got := ensure(t, nil, ownerTestNewPass); got != "REPAIRED" {
		t.Fatalf("ENSURE(new) after the race replied %q, want REPAIRED", got)
	}
	f, b := mustReadOwnerKey(t)
	if lineCount(b) != 5 || f.old != nil {
		t.Fatal("ENSURE(new) did not prune to v1")
	}
	if !inboxOpens(t, blob, nil, ownerTestNewPass) {
		t.Fatal("the item does not open under the new passphrase after the race")
	}
}

// (d) an old passphrase that opens nothing is WRONG, over a v1 and over a v2 file; nothing is replaced.
func TestOwnerKeyRewrap_WrongOldPass(t *testing.T) {
	blob, _ := sealedBeforeRewrap(t)
	renames := countRenames(t)
	for round := 0; round < 2; round++ {
		_, before := mustReadOwnerKey(t)
		if got := rewrap(t, nil, ownerTestThirdPass, nil, ownerTestNewPass); got != "WRONG" {
			t.Fatalf("round %d: REWRAP with a wrong old passphrase replied %q, want WRONG", round, got)
		}
		if _, after := mustReadOwnerKey(t); !bytes.Equal(before, after) || renames.Load() != 0 {
			t.Fatalf("round %d: a WRONG rewrap wrote the file", round)
		}
		if got := ensure(t, nil, ownerTestPass); got != "OK" {
			t.Fatalf("round %d: ENSURE afterwards replied %q, want OK (the key was not replaced)", round, got)
		}
		if round == 0 {
			if got := rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass); got != "OK" {
				t.Fatalf("REWRAP replied %q", got)
			}
			renames.Store(0)
		}
	}
	if !inboxOpens(t, blob, nil, ownerTestPass) {
		t.Fatal("the item was lost")
	}
}

// (e) no key, kept files, and a publish that fails: nothing is written.
func TestOwnerKeyRewrap_NoKeyAndKeptFiles(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	if got := rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass); got != "NOKEY" {
		t.Fatalf("REWRAP with no key replied %q, want NOKEY", got)
	}
	if _, err := os.Stat(ownerKeyPath); !os.IsNotExist(err) {
		t.Fatal("a NOKEY rewrap created a file")
	}
	ensure(t, nil, ownerTestPass)
	v1, v1b := mustReadOwnerKey(t)
	_ = v1
	rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass)
	_, v2b := mustReadOwnerKey(t)
	v2lines := strings.Split(strings.TrimSuffix(string(v2b), "\n"), "\n")
	short := strings.Join(v2lines[:6], "\n") + "\n"
	shortSalt := strings.Join(append(append([]string{}, v2lines[:5]...), "old.salt="+rwB64(make([]byte, 5)), v2lines[6]), "\n") + "\n"
	for what, content := range map[string]string{
		"junk":                  "junk",
		"a v2 missing its tail": short,
		"a v2 with a short old": shortSalt,
		"a v1 with seven lines": strings.Replace(string(v2b), "v2", "v1", 1),
	} {
		if err := os.WriteFile(ownerKeyPath, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if st := func() ownerKeyState { _, st, _ := readOwnerKey(); return st }(); st != ownerKeyUnreadable {
			t.Fatalf("%s: classed %v, want unreadable", what, st)
		}
		if got := rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass); got != "NOKEY" {
			t.Fatalf("%s: REWRAP replied %q, want NOKEY", what, got)
		}
		if b, _ := os.ReadFile(ownerKeyPath); string(b) != content {
			t.Fatalf("%s: REWRAP changed the file", what)
		}
	}
	newer := "nowhere-owner-key v3\nwhatever the newer format holds\n"
	os.WriteFile(ownerKeyPath, []byte(newer), 0o600)
	if got := rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass); got != "ERR version" {
		t.Fatalf("REWRAP over a v3 file replied %q, want ERR version", got)
	}
	if b, _ := os.ReadFile(ownerKeyPath); string(b) != newer {
		t.Fatal("REWRAP changed a newer-format file")
	}
	os.WriteFile(ownerKeyPath, v1b, 0o600)
	old := ownerKeyRename
	ownerKeyRename = func(string, string) error { return os.ErrPermission }
	defer func() { ownerKeyRename = old }()
	if got := rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass); got != "ERR io" {
		t.Fatalf("a failed publish replied %q, want ERR io", got)
	}
	if b, _ := os.ReadFile(ownerKeyPath); !bytes.Equal(b, v1b) {
		t.Fatal("a failed publish changed the file")
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(ownerKeyPath), ".owner-key.tmp")); !os.IsNotExist(err) {
		t.Fatal("a failed publish left its temp file")
	}
}

// (f) the pepper mode is the file's: never a pepperless wrapping on a StrongBox file, no mode change.
func TestOwnerKeyRewrap_ModeMismatch(t *testing.T) {
	useTempOwnerKey(t)
	asGate(t)
	ensure(t, ownerTestPepper, ownerTestPass)
	_, sb := mustReadOwnerKey(t)
	runs := ownerKEKRuns.Load()
	for what, req := range map[string]string{
		"a pepperless old on a StrongBox file": rewrapReq(nil, ownerTestPass, ownerTestNewPepper, ownerTestNewPass),
		"a pepperless new on a StrongBox file": rewrapReq(ownerTestPepper, ownerTestPass, nil, ownerTestNewPass),
	} {
		if got := driveLogin(t, t.TempDir(), req); got != "ERR mode" {
			t.Fatalf("%s: replied %q, want ERR mode", what, got)
		}
		if _, b := mustReadOwnerKey(t); !bytes.Equal(b, sb) {
			t.Fatalf("%s: the file changed", what)
		}
	}
	ensure(t, nil, ownerTestPass) // ERR mode too: neither the mode checks nor the refusals above derived
	if ownerKEKRuns.Load() != runs {
		t.Fatal("a mode check derived")
	}
	// positive: a StrongBox rewrap keeps the mode, and the new wrapping needs its pepper.
	if got := rewrap(t, ownerTestPepper, ownerTestPass, ownerTestNewPepper, ownerTestNewPass); got != "OK" {
		t.Fatalf("StrongBox REWRAP replied %q, want OK", got)
	}
	f, _ := mustReadOwnerKey(t)
	if f.pepper != "strongbox" {
		t.Fatalf("pepper=%s after a StrongBox rewrap", f.pepper)
	}
	if _, _, ok := ownerKeyOpen(f, []byte(ownerTestNewPass), nil); ok {
		t.Fatal("the new wrapping opens without its pepper")
	}
	if _, _, ok := ownerKeyOpen(f, []byte(ownerTestNewPass), ownerTestNewPepper); !ok {
		t.Fatal("the new wrapping does not open with its pepper")
	}
	// a pepperless file refuses a pepper on either side.
	if err := os.Remove(ownerKeyPath); err != nil {
		t.Fatal(err)
	}
	ensure(t, nil, ownerTestPass)
	_, nb := mustReadOwnerKey(t)
	for what, req := range map[string]string{
		"a pepper on both":    rewrapReq(ownerTestPepper, ownerTestPass, ownerTestNewPepper, ownerTestNewPass),
		"a pepper on the new": rewrapReq(nil, ownerTestPass, ownerTestNewPepper, ownerTestNewPass),
		"a pepper on the old": rewrapReq(ownerTestPepper, ownerTestPass, nil, ownerTestNewPass),
	} {
		if got := driveLogin(t, t.TempDir(), req); got != "ERR mode" {
			t.Fatalf("pepperless file, %s: replied %q, want ERR mode", what, got)
		}
		if _, b := mustReadOwnerKey(t); !bytes.Equal(b, nb) {
			t.Fatalf("pepperless file, %s: the file changed", what)
		}
	}
}

// (g) a rewrap over a v2 file keeps the wrapping the old passphrase opened.
func TestOwnerKeyRewrap_OverV2(t *testing.T) {
	blob, v1 := sealedBeforeRewrap(t)
	rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass)
	first, firstB := mustReadOwnerKey(t)
	if got := rewrap(t, nil, ownerTestPass, nil, ownerTestThirdPass); got != "OK" {
		t.Fatalf("REWRAP(old->third) over v2 replied %q", got)
	}
	f, b := mustReadOwnerKey(t)
	if lineCount(b) != 7 || f.pub != v1.pub || f.old.wrapped != first.old.wrapped || !bytes.Equal(f.old.salt, first.old.salt) {
		t.Fatal("opened at the old wrapping: want v2 {third, that old}")
	}
	if !inboxOpens(t, blob, nil, ownerTestThirdPass) || !inboxOpens(t, blob, nil, ownerTestPass) || inboxOpens(t, blob, nil, ownerTestNewPass) {
		t.Fatal("opened at the old wrapping: the item must open under the third and the original, not the dropped middle")
	}
	if err := os.WriteFile(ownerKeyPath, firstB, 0o600); err != nil {
		t.Fatal(err)
	}
	if got := rewrap(t, nil, ownerTestNewPass, nil, ownerTestThirdPass); got != "OK" {
		t.Fatalf("REWRAP(new->third) over v2 replied %q", got)
	}
	f, b = mustReadOwnerKey(t)
	if lineCount(b) != 7 || f.pub != v1.pub || f.old.wrapped != first.wrapped || !bytes.Equal(f.old.salt, first.salt) {
		t.Fatal("opened at the new wrapping: want v2 {third, that new}")
	}
	if !inboxOpens(t, blob, nil, ownerTestThirdPass) || !inboxOpens(t, blob, nil, ownerTestNewPass) || inboxOpens(t, blob, nil, ownerTestPass) {
		t.Fatal("opened at the new wrapping: the item must open under the third and the middle, not the original")
	}
}

// (h1) the kekOwner derivations per OK.
func TestOwnerKeyRewrap_KEKRuns(t *testing.T) {
	sealedBeforeRewrap(t)
	runs := func(f func()) int64 { n := ownerKEKRuns.Load(); f(); return ownerKEKRuns.Load() - n }
	if d := runs(func() { rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass) }); d != 2 {
		t.Fatalf("a rewrap over a v1 file derived %d times, want 2", d)
	}
	_, v2 := mustReadOwnerKey(t)
	if d := runs(func() { rewrap(t, nil, ownerTestPass, nil, ownerTestThirdPass) }); d != 3 {
		t.Fatalf("a rewrap over a v2 file, old wrapping opened, derived %d times, want 3", d)
	}
	os.WriteFile(ownerKeyPath, v2, 0o600)
	if d := runs(func() { rewrap(t, nil, ownerTestNewPass, nil, ownerTestThirdPass) }); d != 2 {
		t.Fatalf("a rewrap over a v2 file, new wrapping opened, derived %d times, want 2", d)
	}
}

// (h2) the derivations run while telMu is held elsewhere; the publishing rename takes it.
func TestOwnerKeyRewrap_DerivesOutsideTelMu(t *testing.T) {
	sealedBeforeRewrap(t)
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
	runs := ownerKEKRuns.Load()
	telMu.Lock()
	locked := true
	defer func() {
		if locked {
			telMu.Unlock()
		}
	}()
	done := make(chan string, 1)
	go func() { done <- rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass) }()
	deadline := time.Now().Add(20 * time.Second)
	for ownerKEKRuns.Load()-runs < 2 {
		if time.Now().After(deadline) {
			t.Fatal("the derivations did not run while telMu was held")
		}
		time.Sleep(10 * time.Millisecond)
	}
	telMu.Unlock()
	locked = false
	select {
	case got := <-done:
		if got != "OK" {
			t.Fatalf("REWRAP replied %q, want OK", got)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("REWRAP did not finish after telMu was released")
	}
	if ensure(t, nil, ownerTestNewPass) != "REPAIRED" {
		t.Fatal("ENSURE(new) did not prune")
	}
	if calls.Load() != 2 || free.Load() {
		t.Fatalf("%d publish(es), free=%v: both the rewrap and the prune must publish under telMu", calls.Load(), free.Load())
	}
}

// (h3) a rewrap never waits for sessionMu.
func TestOwnerKeyRewrap_NeverWaitsForSessionMu(t *testing.T) {
	sealedBeforeRewrap(t)
	sessionMu.Lock()
	held := true
	defer func() {
		if held {
			sessionMu.Unlock()
		}
	}()
	done := make(chan string, 1)
	go func() { done <- rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass) }()
	select {
	case got := <-done:
		if got != "OK" {
			t.Fatalf("REWRAP replied %q", got)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("REWRAP waited on sessionMu")
	}
	sessionMu.Unlock()
	held = false
}

// (h4) anyone but the user-0 gate is refused before a byte of the request is read.
func TestOwnerKeyRewrap_RefusesAnyoneButTheGate(t *testing.T) {
	sealedBeforeRewrap(t)
	_, before := mustReadOwnerKey(t)
	runs := ownerKEKRuns.Load()
	asCaller(t, 1010123, 10123)
	done := make(chan string, 1)
	go func() { done <- driveLogin(t, t.TempDir(), "OWNER-KEY-REWRAP\n") }() // no body at all
	select {
	case got := <-done:
		if got != "DENIED" {
			t.Fatalf("a roamed chooser got %q, want DENIED", got)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the refusal waited for a request body")
	}
	if got := rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass); got != "DENIED" {
		t.Fatalf("a full request from a roamed chooser got %q, want DENIED", got)
	}
	if _, after := mustReadOwnerKey(t); !bytes.Equal(before, after) || ownerKEKRuns.Load() != runs {
		t.Fatal("a refused caller changed the key or derived")
	}
}

// (h5) a malformed request derives nothing and writes nothing.
func TestOwnerKeyRewrap_BadRequests(t *testing.T) {
	sealedBeforeRewrap(t)
	_, before := mustReadOwnerKey(t)
	runs := ownerKEKRuns.Load()
	p, q := rwB64([]byte(ownerTestPass)), rwB64([]byte(ownerTestNewPass))
	for what, req := range map[string]string{
		"a wrong version":      "OWNER-KEY-REWRAP\nv2\n-\n" + p + "\n-\n" + q + "\n",
		"a raw old passphrase": "OWNER-KEY-REWRAP\nv1\n-\n" + ownerTestPass + "!\n-\n" + q + "\n",
		"a new pepper not b64": "OWNER-KEY-REWRAP\nv1\n-\n" + p + "\n?\n" + q + "\n",
		"a 31-byte old pepper": "OWNER-KEY-REWRAP\nv1\n" + rwB64(make([]byte, 31)) + "\n" + p + "\n-\n" + q + "\n",
		"an empty new secret":  "OWNER-KEY-REWRAP\nv1\n-\n" + p + "\n-\n\n",
		"an oversize old":      "OWNER-KEY-REWRAP\nv1\n-\n" + rwB64([]byte(strings.Repeat("x", ownerPassMax+1))) + "\n-\n" + q + "\n",
		"an oversize new":      "OWNER-KEY-REWRAP\nv1\n-\n" + p + "\n-\n" + rwB64([]byte(strings.Repeat("x", ownerPassMax+1))) + "\n",
	} {
		if got := driveLogin(t, t.TempDir(), req); got != "ERR request" {
			t.Fatalf("%s: replied %q, want ERR request", what, got)
		}
	}
	if _, _, _, _, err := readOwnerKeyRewrapRequest(bufio.NewReader(strings.NewReader("v1\n-\n" + p + "\n-\n"))); err == nil {
		t.Fatal("a request cut short was accepted")
	}
	if _, after := mustReadOwnerKey(t); !bytes.Equal(before, after) || ownerKEKRuns.Load() != runs {
		t.Fatal("a bad request changed the key or derived")
	}
}

// (h6) the routing and the source order the behavioural tests cannot see.
func TestOwnerKeyRewrap_SourcePins(t *testing.T) {
	if !ownerKeyCmd("OWNER-KEY-REWRAP") || ownerModeCmd("OWNER-KEY-REWRAP") {
		t.Fatal("OWNER-KEY-REWRAP must be an owner-key verb and not an owner-mode verb")
	}
	b, err := os.ReadFile("owner_key.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "func handleOwnerKey(")
	h := src[i : i+strings.Index(src[i:], "\n}\n")]
	if c, r := strings.Index(h, "ownerCallerOK("), strings.Index(h, "readOwnerKeyRewrapRequest("); c < 0 || r < c {
		t.Fatal("the rewrap request is read before the caller is checked")
	}
	if strings.Contains(h, "sessionMu") {
		t.Fatal("handleOwnerKey takes sessionMu")
	}
}

// (i) no branch logs a passphrase, a pepper, or anything in either file shape, and every line survives the scrubber.
func TestOwnerKeyRewrap_LogsNoSecret(t *testing.T) {
	useTempOwnerKey(t)
	var bodies [][]byte
	snap := func() { _, b := mustReadOwnerKey(t); bodies = append(bodies, b) }
	out := captureStderr(t, func() {
		asGate(t)
		ensure(t, nil, ownerTestPass)
		snap()
		rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass) // rewrapped
		snap()
		rewrap(t, nil, ownerTestThirdPass, nil, ownerTestNewPass)        // refused (did not open)
		rewrap(t, ownerTestPepper, ownerTestPass, nil, ownerTestNewPass) // pepper mismatch
		ensure(t, nil, ownerTestNewPass)                                 // pruned
		snap()
		os.WriteFile(ownerKeyPath, []byte("junk"), 0o600)
		rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass) // no key
		os.WriteFile(ownerKeyPath, []byte("nowhere-owner-key v3\nx\n"), 0o600)
		rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass) // newer
		driveLogin(t, t.TempDir(), "OWNER-KEY-REWRAP\nv1\n-\n"+ownerTestPass+"!\n-\n"+rwB64([]byte(ownerTestNewPass))+"\n")
		asCaller(t, 1010123, 10123)
		rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass) // refused
		ownerKeyPath = filepath.Join(t.TempDir(), "missing", "owner-key")
		asGate(t)
		rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass) // NOKEY
		ensure(t, nil, ownerTestPass)                        // creates nothing? the dir is missing: ERR io
	})
	for _, want := range []string{"owner-key rewrapped", "owner-key pruned the old wrapping", "owner-key rewrap refused (did not open)",
		"owner-key refused a rewrap whose pepper does not match the key", "owner-key rewrap found no key", "owner-key kept a newer-format file",
		"owner-key bad request (bad old secret field)", "owner-key refused (caller is not the user-0 gate)"} {
		if !strings.Contains(out, want) {
			t.Fatalf("control: %q is missing from %q", want, out)
		}
	}
	secrets := []string{ownerTestPass, ownerTestNewPass, ownerTestThirdPass, rwB64([]byte(ownerTestPass)), rwB64([]byte(ownerTestNewPass)),
		rwB64(ownerTestPepper)}
	for _, b := range bodies {
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

// A v2 header now has a grammar: a malformed v2 file is UNREADABLE, so ENSURE replaces it as it does a malformed v1.
func TestOwnerKeyRewrap_EnsureReplacesAMalformedV2(t *testing.T) {
	sealedBeforeRewrap(t)
	rewrap(t, nil, ownerTestPass, nil, ownerTestNewPass)
	_, b := mustReadOwnerKey(t)
	lines := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
	if err := os.WriteFile(ownerKeyPath, []byte(strings.Join(lines[:6], "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := ensure(t, nil, ownerTestNewPass); got != "REPLACED" {
		t.Fatalf("ENSURE over a malformed v2 file replied %q, want REPLACED", got)
	}
	if f, _ := mustReadOwnerKey(t); f.old != nil {
		t.Fatal("the replacement is not a v1 file")
	}
}
