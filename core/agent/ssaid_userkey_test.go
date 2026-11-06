package main

import (
	"encoding/hex"
	"os"
	"regexp"
	"strings"
	"testing"
)

// The #210 userkey derivation is pinned: any change to the domain, hash, encoding or case changes every
// app's ANDROID_ID on the next roam and drops every device-bound login, with no build break and no log line.

func ssaidTestKey() []byte {
	dk := make([]byte, 32)
	for i := range dk {
		dk[i] = byte(i)
	}
	return dk
}

func TestSsaidUserKeyVector(t *testing.T) {
	const want = "7DCBA3F4E42C19170B3AE368C42068E9D40CE4698ECC8C724AB53215B709E691"
	dk := ssaidTestKey()
	got := ssaidUserKey(dk)
	if got != want {
		t.Fatalf("ssaidUserKey = %s, want %s", got, want)
	}
	if len(got) != 64 {
		t.Fatalf("length %d, want 64", len(got))
	}
	if !regexp.MustCompile(`^[0-9A-F]{64}$`).MatchString(got) {
		t.Fatalf("not upper-case hex: %s", got)
	}
	if got == hex.EncodeToString(dk) || strings.EqualFold(got, hex.EncodeToString(dk)) {
		t.Fatal("userkey equals the raw key")
	}
}

func TestHandleSeedSsaidUsesHelper(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "func handleSeedSsaid(")
	if i < 0 {
		t.Fatal("handleSeedSsaid not found")
	}
	body := src[i:]
	if j := strings.Index(body, "\n}\n"); j >= 0 {
		body = body[:j]
	}
	// NWP-20261122-12: the handler picks the key through seedSsaidKey, whose default is ssaidUserKey.
	if !strings.Contains(body, "seedSsaidKey(nm, pw)") {
		t.Fatal("handleSeedSsaid does not pick the userkey through seedSsaidKey")
	}
	if strings.Contains(body, "sha256.") {
		t.Fatal("handleSeedSsaid derives inline again")
	}
	k := strings.Index(src, "func seedSsaidKey(")
	if k < 0 {
		t.Fatal("seedSsaidKey not found")
	}
	pick := src[k:]
	if j := strings.Index(pick, "\n}\n"); j >= 0 {
		pick = pick[:j]
	}
	if !strings.Contains(pick, "ssaidUserKey(deriveKey(nm, pw))") {
		t.Fatal("seedSsaidKey does not default to ssaidUserKey")
	}
	if strings.Contains(pick, "sha256.") {
		t.Fatal("seedSsaidKey derives inline")
	}
}
