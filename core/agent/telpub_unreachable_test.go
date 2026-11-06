package main

import (
	"fmt"
	"syscall"
	"testing"
)

// NWP-20261120-13: GET-TELPUB's store read, seen from the gate. A read that fails in transport answers ERR-NET
// (it used to answer nothing, and the Bind form read the silence as wrong credentials); every other reply is
// unchanged. Each case swaps telPubHeadOf, so no case waits out retryStore's backoff or capGetRetryWindow.

// withTelPubHead points GET-TELPUB at a configured direct-S3 store whose head read is head, as the gate.
func withTelPubHead(t *testing.T, head func(name, pass string) []byte) {
	t.Helper()
	asGate(t)
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ENDPOINT", "http://127.0.0.1:9")
	t.Setenv("S3_BUCKET", "telpub-test")
	t.Setenv("S3_ACCESS_KEY", "test-access")
	t.Setenv("S3_SECRET_KEY", "test-secret")
	old := telPubHeadOf
	telPubHeadOf = head
	t.Cleanup(func() { telPubHeadOf = old })
}

func telPubReq(name, pass string) string { return "GET-TELPUB\n" + name + "\n" + pass + "\n" }

func TestTelPubStoreUnreachableAnswersErrNet(t *testing.T) {
	withTelPubHead(t, func(name, pass string) []byte {
		panic(storeReadErr{fmt.Errorf("dial tcp 127.0.0.1:9: %w", syscall.ECONNREFUSED)})
	})
	if got := driveLogin(t, t.TempDir(), telPubReq("telpub-net-a", "telpub-pass-a")); got != "ERR-NET" {
		t.Fatalf("GET-TELPUB with the store unreachable = %q, want exactly ERR-NET", got)
	}
}

func TestTelPubHeadWithoutKeyAnswersNoKey(t *testing.T) {
	var gotName, gotPass string
	withTelPubHead(t, func(name, pass string) []byte {
		gotName, gotPass = name, pass
		return serializeVault(&vault{V: 1, Slots: []keyslot{{Kind: "pass"}}})
	})
	if got := driveLogin(t, t.TempDir(), telPubReq("telpub-net-b", "telpub-pass-b")); got != "NOKEY" {
		t.Fatalf("GET-TELPUB on a head with no TelPub = %q, want NOKEY", got)
	}
	if gotName != "telpub-net-b" || gotPass != "telpub-pass-b" {
		t.Fatalf("the head read got (%q, %q), want the request's name and passphrase", gotName, gotPass)
	}
}

func TestTelPubAbsentHeadAnswersNone(t *testing.T) {
	withTelPubHead(t, func(name, pass string) []byte { return nil })
	if got := driveLogin(t, t.TempDir(), telPubReq("telpub-net-c", "telpub-pass-c")); got != "NONE" {
		t.Fatalf("GET-TELPUB with no head = %q, want NONE", got)
	}
}

func TestTelPubHeadWithKeyAnswersOK(t *testing.T) {
	v, _ := vaultWithTelKey(t)
	v.V, v.Slots = 1, []keyslot{{Kind: "pass"}}
	blob := serializeVault(v)
	withTelPubHead(t, func(name, pass string) []byte { return blob })
	const name, pass = "telpub-net-d", "telpub-pass-d"
	want := "OK " + v.TelPub + " " + profileRefV2(name, pass)
	if got := driveLogin(t, t.TempDir(), telPubReq(name, pass)); got != want {
		t.Fatalf("GET-TELPUB on a head with a TelPub = %q, want %q", got, want)
	}
}

// A panic that is not a failed store read is a bug: it must not be dressed up as ERR-NET. It ends the
// connection with no reply, as before, and recoverConnPanic logs it.
func TestTelPubOtherPanicIsNotErrNet(t *testing.T) {
	withTelPubHead(t, func(name, pass string) []byte { panic("telpub test: not a store error") })
	got := driveLogin(t, t.TempDir(), telPubReq("telpub-net-e", "telpub-pass-e"))
	if got != "" {
		t.Fatalf("GET-TELPUB after a non-store panic = %q, want no reply", got)
	}
}
