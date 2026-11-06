package main

// NWP-20261127-02 (h53 #3, docs/product-decisions.md 2026-11-02): removing a security key needs a FRESH tap -- of a
// remaining key, or of the key itself when it is the last one -- never the hmac cached at sign-in. The function tests
// drive removeFido2KeyTapped with NOWHERE_FIDO2_HMAC empty, so only the tap can open the vault. The arm tests drive
// REMOVE-FIDO2-KEY through handleLogin with roamd's fido2adopt stubbed (adoptFido2Worker): no test here reaches a
// real worker. Every test has its own profile on its own fake store. test-remove-key-tap.sh re-runs these against
// mutants of fido2.go and main.go.

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type rktKey struct {
	cred, salt string
	hmac       []byte
}

func rktNewKey(t *testing.T, tag string) rktKey {
	t.Helper()
	h := make([]byte, fido2HMACLen)
	s := make([]byte, 32)
	if _, err := rand.Read(h); err != nil {
		t.Fatal(err)
	}
	if _, err := rand.Read(s); err != nil {
		t.Fatal(err)
	}
	return rktKey{base64.StdEncoding.EncodeToString([]byte(tag)), base64.StdEncoding.EncodeToString(s), h}
}

// rktVault makes a vault for name on its own cap-mode fake store and enrols one key per tag. It leaves
// NOWHERE_FIDO2_HMAC empty, so nothing but a tap opens the vault once its pass slot is gone.
func rktVault(t *testing.T, name, pass string, tags ...string) []rktKey {
	t.Helper()
	capLockEnv(t)
	contentCache = nil
	t.Cleanup(clearStaleHit)
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	sessionVaultForTest(t, name, pass)
	var keys []rktKey
	for _, tag := range tags {
		k := rktNewKey(t, tag)
		if err := enrollFido2("s3", name, pass, k.cred, k.salt, hex.EncodeToString(k.hmac), false, "usb", nil); err != nil {
			t.Fatalf("enrol %s: %v", tag, err)
		}
		keys = append(keys, k)
		t.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(keys[0].hmac)) // the next enrol opens with the first key
	}
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	return keys
}

// rktHead is the head the profile's vault is at now, and its fido2 credential ids.
func rktHead(t *testing.T, name, pass string) (string, []string) {
	t.Helper()
	hd, v, ok := readVaultHead("s3", name, pass)
	if hd.val == "" || !ok {
		t.Fatalf("%s: no vault head", name)
	}
	var creds []string
	for _, s := range listFido2Slots(v) {
		creds = append(creds, s.CredID)
	}
	return hd.val, creds
}

func rktUnchanged(t *testing.T, name, pass, head string, n int) {
	t.Helper()
	got, creds := rktHead(t, name, pass)
	if got != head || len(creds) != n {
		t.Errorf("the head moved (or lost a key) on a refused removal: %d key(s) left, want %d", len(creds), n)
	}
}

func TestRemoveKeyTapT1RemainingKeyRemoves(t *testing.T) {
	const name, pass = "rkt-t1", "pw rkt-t1"
	k := rktVault(t, name, pass, "rkt-t1-a", "rkt-t1-b")
	still, err := removeFido2KeyTapped("s3", name, pass, k[1].cred, k[0].hmac, nil)
	if err != nil || !still {
		t.Fatalf("remove B with a tap of A: still=%v err=%v, want true, nil", still, err)
	}
	if _, creds := rktHead(t, name, pass); len(creds) != 1 || creds[0] != k[0].cred {
		t.Errorf("after removing B the head holds %v, want only A", creds)
	}
}

func TestRemoveKeyTapT2KeyBeingRemovedRefused(t *testing.T) {
	const name, pass = "rkt-t2", "pw rkt-t2"
	k := rktVault(t, name, pass, "rkt-t2-a", "rkt-t2-b")
	head, _ := rktHead(t, name, pass)
	if _, err := removeFido2KeyTapped("s3", name, pass, k[1].cred, k[1].hmac, nil); !errors.Is(err, errKeyTapWrong) {
		t.Fatalf("remove B with a tap of B: err=%v, want errKeyTapWrong", err)
	}
	rktUnchanged(t, name, pass, head, 2)
}

func TestRemoveKeyTapT3UnenrolledKeyRefused(t *testing.T) {
	const name, pass = "rkt-t3", "pw rkt-t3"
	k := rktVault(t, name, pass, "rkt-t3-a", "rkt-t3-b")
	head, _ := rktHead(t, name, pass)
	stranger := rktNewKey(t, "rkt-t3-stranger")
	if _, err := removeFido2KeyTapped("s3", name, pass, k[1].cred, stranger.hmac, nil); !errors.Is(err, errKeyTapWrong) {
		t.Fatalf("remove B with a never-enrolled key's tap: err=%v, want errKeyTapWrong", err)
	}
	rktUnchanged(t, name, pass, head, 2)
}

func TestRemoveKeyTapT4CachedHmacIsNotATap(t *testing.T) {
	const name, pass = "rkt-t4", "pw rkt-t4"
	k := rktVault(t, name, pass, "rkt-t4-a", "rkt-t4-b")
	head, _ := rktHead(t, name, pass)
	t.Setenv("NOWHERE_FIDO2_HMAC", hex.EncodeToString(k[0].hmac)) // the answer cached at sign-in
	for _, tap := range [][]byte{nil, {}} {
		if _, err := removeFido2KeyTapped("s3", name, pass, k[1].cred, tap, nil); !errors.Is(err, errKeyTapMissing) {
			t.Fatalf("remove B with no tap and A's hmac cached: err=%v, want errKeyTapMissing", err)
		}
	}
	rktUnchanged(t, name, pass, head, 2)
}

func TestRemoveKeyTapT5LastKeyWithItsOwnTap(t *testing.T) {
	const name, pass = "rkt-t5", "pw rkt-t5"
	k := rktVault(t, name, pass, "rkt-t5-a")
	head, _ := rktHead(t, name, pass)
	stranger := rktNewKey(t, "rkt-t5-stranger")
	if _, err := removeFido2KeyTapped("s3", name, pass, "", stranger.hmac, nil); !errors.Is(err, errKeyTapWrong) {
		t.Fatalf("remove every key with a never-enrolled key's tap: err=%v, want errKeyTapWrong", err)
	}
	rktUnchanged(t, name, pass, head, 1)
	still, err := removeFido2KeyTapped("s3", name, pass, k[0].cred, k[0].hmac, nil)
	if err != nil || still {
		t.Fatalf("remove the last key A with a tap of A: still=%v err=%v, want false, nil", still, err)
	}
	v, err := readSessionVault("s3", name, pass)
	if err != nil {
		t.Fatal(err)
	}
	if len(listFido2Slots(v)) != 0 || unwrapDK(v, "pass", deriveKey(name, pass)) == nil {
		t.Error("after the last key's removal the head still has a key slot, or no pass slot")
	}
}

// The remove-all case with two keys permits any one enrolled key: an inference, not stated by Chester (fido2.go).
func TestRemoveKeyTapT5bRemoveAllWithAnyKey(t *testing.T) {
	const name, pass = "rkt-t5b", "pw rkt-t5b"
	k := rktVault(t, name, pass, "rkt-t5b-a", "rkt-t5b-b")
	still, err := removeFido2KeyTapped("s3", name, pass, "", k[1].hmac, nil)
	if err != nil || still {
		t.Fatalf("remove every key with a tap of B: still=%v err=%v, want false, nil", still, err)
	}
	if _, creds := rktHead(t, name, pass); len(creds) != 0 {
		t.Errorf("after removing every key the head still holds %v", creds)
	}
}

// --- the REMOVE-FIDO2-KEY arm ---

type rktArm struct {
	name, pass, dest string
	keys             []rktKey
	reply            string // what the stubbed fido2adopt answers
	write            []byte // the hmac it writes to .fido2hmac before it answers OK; nil writes nothing
	calls            []string
}

// rktArmSetup is a stored session of name with keys A and B, whose sign-in cached A's hmac in .fido2hmac (ten
// seconds old), and a stubbed fido2adopt.
func rktArmSetup(t *testing.T, name string) *rktArm {
	t.Helper()
	a := &rktArm{name: name, pass: "pw " + name, dest: t.TempDir(), reply: "OK"}
	a.keys = rktVault(t, a.name, a.pass, name+"-a", name+"-b")
	t.Setenv("NOWHERE_STATE", a.dest)
	if err := markRoamSession(a.dest, a.name, a.pass, euUID, ""); err != nil {
		t.Fatal(err)
	}
	stash := filepath.Join(a.dest, ".fido2hmac")
	if err := os.WriteFile(stash, []byte(hex.EncodeToString(a.keys[0].hmac)), 0o600); err != nil {
		t.Fatal(err)
	}
	past := time.Now().Add(-10 * time.Second)
	if err := os.Chtimes(stash, past, past); err != nil {
		t.Fatal(err)
	}
	old := adoptFido2Worker
	t.Cleanup(func() { adoptFido2Worker = old })
	adoptFido2Worker = func(dest, op, name, pass, uid, se string, onProg func(string)) string {
		a.calls = append(a.calls, op)
		if a.reply == "OK" && a.write != nil {
			if err := os.WriteFile(stash, []byte(hex.EncodeToString(a.write)), 0o600); err != nil {
				t.Error(err)
			}
			future := time.Now().Add(10 * time.Second)
			if err := os.Chtimes(stash, future, future); err != nil {
				t.Error(err)
			}
		}
		return a.reply
	}
	return a
}

func (a *rktArm) send(t *testing.T, credID string) string {
	t.Helper()
	cli, srv := net.Pipe()
	done := make(chan struct{})
	go func() { handleLogin(srv, a.dest); close(done) }()
	if _, err := cli.Write([]byte("REMOVE-FIDO2-KEY\n" + credID + "\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	line, err := bufio.NewReader(cli).ReadString('\n')
	cli.Close()
	<-done
	if err != nil {
		t.Fatalf("REMOVE-FIDO2-KEY: no reply line (%v), got %q", err, line)
	}
	return strings.TrimSpace(line)
}

func TestRemoveKeyTapT6NoKeyAnswered(t *testing.T) {
	a := rktArmSetup(t, "rkt-t6")
	a.reply = "ERR-NOKEY"
	head, _ := rktHead(t, a.name, a.pass)
	if got := a.send(t, a.keys[1].cred); got != "ERR-NOKEY" {
		t.Errorf("reply %q, want ERR-NOKEY", got)
	}
	if len(a.calls) != 1 || a.calls[0] != "fido2adopt" {
		t.Errorf("the worker ran %v, want fido2adopt once", a.calls)
	}
	rktUnchanged(t, a.name, a.pass, head, 2)
}

func TestRemoveKeyTapT7OKThatWroteNothing(t *testing.T) {
	a := rktArmSetup(t, "rkt-t7")
	head, _ := rktHead(t, a.name, a.pass)
	if got := a.send(t, a.keys[1].cred); got != "ERR-NOKEY" {
		t.Errorf("an OK that left the sign-in's .fido2hmac as it was: reply %q, want ERR-NOKEY", got)
	}
	rktUnchanged(t, a.name, a.pass, head, 2)
}

func TestRemoveKeyTapT8RemainingKeyTapRemoves(t *testing.T) {
	a := rktArmSetup(t, "rkt-t8")
	a.write = a.keys[0].hmac
	if got := a.send(t, a.keys[1].cred); got != "OK true" {
		t.Fatalf("remove B with a fresh tap of A: reply %q, want OK true", got)
	}
	if _, creds := rktHead(t, a.name, a.pass); len(creds) != 1 || creds[0] != a.keys[0].cred {
		t.Errorf("after removing B the head holds %v, want only A", creds)
	}
}

func TestRemoveKeyTapT8bKeyBeingRemovedRefused(t *testing.T) {
	a := rktArmSetup(t, "rkt-t8b")
	a.write = a.keys[1].hmac
	head, _ := rktHead(t, a.name, a.pass)
	if got := a.send(t, a.keys[1].cred); got != "ERR-WRONGKEY" {
		t.Errorf("remove B with a fresh tap of B: reply %q, want ERR-WRONGKEY", got)
	}
	rktUnchanged(t, a.name, a.pass, head, 2)
	if b, _ := os.ReadFile(filepath.Join(a.dest, ".fido2hmac")); string(b) != hex.EncodeToString(a.keys[1].hmac) {
		t.Error("a refused tap changed the .fido2hmac fido2adopt wrote")
	}
}

func TestRemoveKeyTapNotStored(t *testing.T) {
	for i, mark := range []func(string){markLocalSession, markOfflineSession} {
		a := rktArmSetup(t, []string{"rkt-local", "rkt-offline"}[i])
		mark(a.dest)
		if got := a.send(t, a.keys[1].cred); got != "ERR-NOTSTORED" {
			t.Errorf("reply %q, want ERR-NOTSTORED", got)
		}
		if len(a.calls) != 0 {
			t.Errorf("the worker ran %d times for a session with no stored profile", len(a.calls))
		}
	}
}
