package main

import (
	"net"
	"os"
	"strings"
	"testing"
)

// NWP-20261125-14 (h55 #1): a claim code is 24 base64url characters (nowhere-cloud newClaimCode: 18 random bytes,
// RawURLEncoding). CREATE-CODE refuses any other code with ERR-NOCODE before the store, the throttle and the gateway.

const (
	ccsFunded  = "ccsFundedCode_0123456-Az" // the code createCodeEnv funds
	ccsUnknown = "ccsUnknownCode-987654_Zz" // well formed, but the fake gateway does not fund it
	ccsPass    = "a passphrase for the claim code shape case"
)

func TestClaimCodeShape_Table(t *testing.T) {
	for _, c := range []struct {
		code string
		want bool
	}{
		{"q3Zr-8_kLmN0pQ1sT2uV3wXy", true},
		{"ABCDEFGHIJKLMNOPQRSTUVWX", true},
		{"YZabcdefghijklmnopqrstuv", true},
		{"wxyz0123456789-_-_-_-_-_", true},
		{ccsFunded, true},
		{ccsUnknown, true},
		{"", false},
		{"PAID-CODE", false},
		{"q3Zr-8_kLmN0pQ1sT2uV3wX", false},   // 23
		{"q3Zr-8_kLmN0pQ1sT2uV3wXyz", false}, // 25
		{"q3Zr-8_kLmN0pQ1sT2uV3wX+", false},  // std base64 '+'
		{"q3Zr-8_kLmN0pQ1sT2uV3wX/", false},  // std base64 '/'
		{"q3Zr-8_kLmN0pQ1sT2uV3wX=", false},  // padding
		{"q3Zr-8_kLmN0 Q1sT2uV3wXy", false},  // a space inside
		{"q3Zr-8_kLmN0pQ1sT2uV3wé", false},   // 22 ASCII + a 2-byte rune = 24 bytes
		{"q3Zr-8_kLmN0pQ1sT2uV3wXé", false},  // 24 runes, 25 bytes
	} {
		if got := claimCodeWellFormed(c.code); got != c.want {
			t.Errorf("claimCodeWellFormed(%q) = %v, want %v", c.code, got, c.want)
		}
	}
}

// A malformed code is refused with ERR-NOCODE and nothing else happens: no store read, no gateway request, no
// throttle charge, no staged claim, the wallet untouched.
func TestClaimCodeShape_CreateCodeRefusesBeforeAnything(t *testing.T) {
	const name = "ccshape-a"
	dest, wpath := createCodeEnv(t, ccsFunded, 3)
	seen := clSpy(t)
	fundWallet(t, wpath, 4)
	walletBefore, _ := os.ReadFile(wpath)
	t.Setenv("NOWHERE_ENROLL_MAX", "1")
	blobCache, contentCache = nil, nil
	before := len(seen())

	for _, code := range []string{
		"PAID-CODE",
		ccsFunded[:23],
		ccsFunded + "A",
		ccsFunded[:23] + "+",
		ccsFunded[:23] + "/",
		ccsFunded[:23] + "=",
		ccsFunded[:11] + " " + ccsFunded[12:],
		ccsFunded[:22] + "é",
	} {
		if got := verb(func(c net.Conn) { handleCreateCode(c, dest, name, ccsPass, code) }); got != "ERR-NOCODE" {
			t.Errorf("CREATE-CODE with %q replied %q, want ERR-NOCODE", code, got)
		}
		if _, err := os.Stat(createStagingPath(name, ccsPass)); err == nil {
			t.Errorf("CREATE-CODE with %q staged a claim", code)
		}
	}
	if got := seen()[before:]; len(got) != 0 {
		t.Errorf("a malformed code reached the store or the gateway: %v", got)
	}
	if ok, _ := enrollAllow(); !ok {
		t.Error("a malformed code took a throttle charge")
	}
	if b, err := os.ReadFile(wpath); err != nil || string(b) != string(walletBefore) {
		t.Errorf("a malformed code touched the wallet (err %v)", err)
	}
}

// Control: a well-formed code the gateway does not know still takes today's path -- it reaches /issue and the
// gateway's refusal answers ERR-NOCODE.
func TestClaimCodeShape_WellFormedUnknownCodeReachesTheGateway(t *testing.T) {
	const name = "ccshape-b"
	dest, _ := createCodeEnv(t, ccsFunded, 3)
	seen := clSpy(t)
	blobCache, contentCache = nil, nil
	if got := verb(func(c net.Conn) { handleCreateCode(c, dest, name, ccsPass, ccsUnknown) }); got != "ERR-NOCODE" {
		t.Fatalf("CREATE-CODE with an unknown well-formed code replied %q, want ERR-NOCODE", got)
	}
	issued := false
	for _, p := range seen() {
		if strings.HasPrefix(p, "/issue") {
			issued = true
		}
	}
	if !issued {
		t.Errorf("an unknown well-formed code never reached the gateway's /issue: %v", seen())
	}
}
