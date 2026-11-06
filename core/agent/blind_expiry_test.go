package main

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"strings"
	"testing"
	"time"
)

// NWP-20261031-08 (Q085): every blind token the phone mints carries the one fixed expiry, 1 Jan 2100.

func TestBlindExpiryConstantIs2100(t *testing.T) {
	got := time.Unix(blindTokenExpiry, 0).UTC().Format(time.RFC3339)
	if got != "2100-01-01T00:00:00Z" {
		t.Fatalf("blindTokenExpiry decodes to %s, want 2100-01-01T00:00:00Z", got)
	}
}

func TestBlindExpiryIssueBatchSignsTheFixedExpiry(t *testing.T) {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	srv := blindGateway(t, priv, "CLAIM-EXPIRY", 6)
	defer srv.Close()
	g := newGatewayClient(srv.URL, gwDefault)

	for call := 0; call < 2; call++ {
		toks, _, code, err := g.issueBatch(&priv.PublicKey, "1GBmo", "CLAIM-EXPIRY", 3)
		if err != nil || code != 200 {
			t.Fatalf("call %d: issueBatch code=%d err=%v", call, code, err)
		}
		if len(toks) != 3 {
			t.Fatalf("call %d: %d tokens, want 3", call, len(toks))
		}
		for _, tk := range toks {
			m, err := base64.StdEncoding.DecodeString(tk.Msg)
			if err != nil {
				t.Fatalf("call %d: msg is not base64: %v", call, err)
			}
			parts := strings.Split(string(m), "|")
			if len(parts) != 3 || parts[2] != "4102444800" {
				t.Fatalf("call %d: message %q, want a third field of exactly 4102444800", call, m)
			}
		}
		if call == 0 {
			time.Sleep(1100 * time.Millisecond) // a second apart: a clock-derived exp would differ
		}
	}
}
