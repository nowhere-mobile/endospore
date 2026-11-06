package main

// NWP-20261114-17 (backlog §D, "A delete leaves the profile's encrypted blobs in the store until their leases lapse
// and the plan's hold ends"): handleDelete opened the vault with openVaultDK, which in the login daemon has only the
// pass slot and an environment with no NOWHERE_SE_SECRET and, after a restart, no NOWHERE_FIDO2_HMAC. A tied or a
// key-only profile therefore deleted with a nil DK and released nothing. handleDelete now adopts the cached key hmac
// (loadFido2HmacEnv) and passes the session's chip secret (deleteSessionSE) to the vault open. These tests drive the
// real handleDelete and the real deleteForSession on a test store; test-delete-release-se.sh --mutate re-runs them
// against broken copies of main.go.

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"net"
	"strings"
	"testing"
	"time"
)

// drseCall is one call the recorder saw: the DK (a copy) and the vault releaseDeletedProfileFn was handed.
type drseCall struct {
	dk []byte
	v  *vault
}

// drseResult is what one driven DELETE produced.
type drseResult struct {
	reply   string
	verdict string
	se      []byte
	calls   []drseCall
}

// drseRun drives handleDelete for (name, typed) over a .roamsession marker for (name, pass, mbUID, seHex), with
// deleteForSessionFn routed to the REAL deleteForSession on base and releaseDeletedProfileFn recorded.
func drseRun(t *testing.T, base, name, pass, typed, seHex, dest string) *drseResult {
	t.Helper()
	e := newRfpEnv(t)
	ropReapReset(t)
	reapSwitchWait = 200 * time.Millisecond
	r := &drseResult{}
	oldFn := deleteForSessionFn
	deleteForSessionFn = func(_, n, p, ln, lp string, se []byte) string {
		r.se = se
		r.verdict = deleteForSession(base, n, p, ln, lp, se)
		return r.verdict
	}
	t.Cleanup(func() { deleteForSessionFn = oldFn })
	oldRel := releaseDeletedProfileFn
	releaseDeletedProfileFn = func(_ string, dk []byte, v *vault, _ []deletedScopeHead) {
		r.calls = append(r.calls, drseCall{append([]byte(nil), dk...), v})
	}
	t.Cleanup(func() { releaseDeletedProfileFn = oldRel })
	if err := markRoamSession(dest, name, pass, mbUID, seHex); err != nil {
		t.Fatal(err)
	}
	// A verified delete reaps; the fallback must reach rebootHook before newRfpEnv's cleanup restores it.
	t.Cleanup(func() {
		if r.verdict != "deleted" {
			return
		}
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			for _, why := range e.rebooted() {
				if strings.Contains(why, "delete reap NOT consumed") {
					return
				}
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Errorf("the fallback never reached rebootHook (got %q)", e.rebooted())
	})
	r.reply = ropReply(t, func(c net.Conn) { handleDelete(c, dest, name, typed, -1) })
	return r
}

// drseVault reads the profile's bare vault head as it stands before the delete.
func drseVault(t *testing.T, base, name, pass string) *vault {
	t.Helper()
	v, ok := parseVault(getBlob(base, getRef(base, headKey(base, name, pass))))
	if !ok {
		t.Fatal("setup: no vault head")
	}
	return v
}

// drseWantReleased checks that the delete answered OK and released the vault's own blobs under its own DK.
func drseWantReleased(t *testing.T, r *drseResult, before *vault, wantDK []byte) {
	t.Helper()
	if r.reply != "OK" {
		t.Errorf("reply %q, want OK", r.reply)
	}
	if r.verdict != "deleted" {
		t.Errorf("deleteForSession verdict %q, want deleted", r.verdict)
	}
	if len(r.calls) != 1 {
		t.Fatalf("release calls = %d, want 1", len(r.calls))
	}
	c := r.calls[0]
	if len(c.dk) == 0 {
		t.Fatal("the release got a nil DK: the vault did not open, so nothing is released early")
	}
	if !bytes.Equal(c.dk, wantDK) {
		t.Error("the release got a DK that is not the vault's own")
	}
	if c.v == nil || c.v.Manifest != before.Manifest {
		t.Error("the release did not get the deleted vault")
	}
}

func TestDeleteReleaseSE_TiedProfileReleases(t *testing.T) {
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_SE_SECRET", "")
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	base := newHTTPStore(t)
	name, pass := "drse-tied", "drse tied passphrase"
	createVault(base, name, pass)
	se := make([]byte, 32)
	for i := range se {
		se[i] = byte(i) + 7
	}
	if err := enrollSE(base, name, pass, se); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}
	before := drseVault(t, base, name, pass)
	if openVaultDK(before, name, pass) != nil {
		t.Fatal("setup: the tied vault opens without the chip secret")
	}
	wantDK, _, ok := resolveKeySE(base, name, pass, se)
	if !ok {
		t.Fatal("setup: the chip secret does not open the tied vault")
	}
	r := drseRun(t, base, name, pass, pass, hex.EncodeToString(se), t.TempDir())
	drseWantReleased(t, r, before, wantDK)
}

func TestDeleteReleaseSE_KeyOnlyProfileReleases(t *testing.T) {
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_SE_SECRET", "")
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	base := newHTTPStore(t)
	name, pass := "drse-key", "drse key passphrase"
	createVault(base, name, pass)
	hmac := make([]byte, fido2HMACLen)
	rand.Read(hmac)
	salt := make([]byte, 32)
	rand.Read(salt)
	credID := base64.StdEncoding.EncodeToString([]byte("drse-cred"))
	if err := enrollFido2(base, name, pass, credID, base64.StdEncoding.EncodeToString(salt), hex.EncodeToString(hmac), true, "", nil); err != nil {
		t.Fatalf("enrollFido2: %v", err)
	}
	t.Setenv("NOWHERE_FIDO2_HMAC", "") // a daemon restart: nothing has adopted the cached hmac yet
	before := drseVault(t, base, name, pass)
	if openVaultDK(before, name, pass) != nil {
		t.Fatal("setup: the key-only vault opens without the key's hmac")
	}
	wantDK := fido2DKWith(before, deriveKey(name, pass), hmac)
	if wantDK == nil {
		t.Fatal("setup: the hmac does not open the key-only vault")
	}
	dest := t.TempDir()
	if err := stashFido2Hmac(dest, hmac); err != nil {
		t.Fatal(err)
	}
	r := drseRun(t, base, name, pass, pass, "", dest)
	drseWantReleased(t, r, before, wantDK)
}

func TestDeleteReleaseSE_SessionSecretOnlyForTheSessionsOwnProfile(t *testing.T) {
	se := []byte{1, 2, 3, 4, 5, 6, 7, 8}
	h := hex.EncodeToString(se)
	if got := deleteSessionSE("drse-own", "own pass", "drse-own", "own pass", h); !bytes.Equal(got, se) {
		t.Errorf("the session's own creds got %d byte(s), want the session's secret", len(got))
	}
	for _, tc := range []struct{ label, name, pass, seHex string }{
		{"another name", "drse-other", "own pass", h},
		{"another passphrase", "drse-own", "other pass", h},
		{"no secret", "drse-own", "own pass", ""},
	} {
		if got := deleteSessionSE(tc.name, tc.pass, "drse-own", "own pass", tc.seHex); got != nil {
			t.Errorf("%s: got %d byte(s), want nil", tc.label, len(got))
		}
	}
}

func TestDeleteReleaseSE_PassOnlyAndWrongPassphraseUnchanged(t *testing.T) {
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_SE_SECRET", "")
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	t.Run("pass-only releases", func(t *testing.T) {
		base := newHTTPStore(t)
		name, pass := "drse-pass", "drse pass passphrase"
		createVault(base, name, pass)
		before := drseVault(t, base, name, pass)
		wantDK := openVaultDK(before, name, pass)
		if wantDK == nil {
			t.Fatal("setup: the pass slot does not open")
		}
		r := drseRun(t, base, name, pass, pass, "", t.TempDir())
		drseWantReleased(t, r, before, wantDK)
	})
	t.Run("wrong passphrase releases nothing", func(t *testing.T) {
		base := newHTTPStore(t)
		name, pass := "drse-wrong", "drse wrong passphrase"
		createVault(base, name, pass)
		se := bytes.Repeat([]byte{9}, 32)
		r := drseRun(t, base, name, pass, "not the passphrase", hex.EncodeToString(se), t.TempDir())
		if r.reply != "NOTFOUND" {
			t.Errorf("reply %q, want NOTFOUND", r.reply)
		}
		if r.verdict != "wrongpass" {
			t.Errorf("verdict %q, want wrongpass", r.verdict)
		}
		if len(r.calls) != 0 {
			t.Errorf("release calls = %d, want 0", len(r.calls))
		}
		if r.se != nil {
			t.Error("the session's chip secret was handed to a delete of other creds")
		}
		if getRef(base, headKey(base, name, pass)) == "" {
			t.Error("the profile's head is gone after a wrong passphrase")
		}
	})
}
