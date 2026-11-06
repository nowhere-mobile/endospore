package main

import (
	"bytes"
	"strings"
	"testing"
)

// authData builds rpIdHash(32) | flags | signCount(4) | tail.
func authData(flags byte, tail ...[]byte) []byte {
	a := append(make([]byte, 32), flags, 0, 0, 0, 1)
	for _, t := range tail {
		a = append(a, t...)
	}
	return a
}

// attHead is aaguid(16) | credIdLen(2) | credId.
func attHead(id []byte) []byte {
	h := append(make([]byte, 16), byte(len(id)>>8), byte(len(id)))
	return append(h, id...)
}

func TestParseAuthData(t *testing.T) {
	cose := mustCBOR(t, newCBORMap().put(uint64(1), uint64(2)).put(uint64(3), int64(-7)))
	extMap := mustCBOR(t, newCBORMap().put("hmac-secret", []byte{1, 2, 3}))
	id := []byte{9, 8, 7, 6}

	errCases := []struct {
		name string
		in   []byte
		want string
	}{
		{"shorter than 37", make([]byte, 36), "too short"},
		{"AT under 55 bytes", authData(0x40, make([]byte, 17)), "truncated attested-cred header"},
		{"credential id past the end", authData(0x40, append(make([]byte, 16), 0x00, 0x20, 1, 2)), "truncated credential id"},
		{"public key declares a 2^63 array", authData(0x40, attHead(id), []byte{0x9b, 0x80, 0, 0, 0, 0, 0, 0, 0}), "bad credential public key"},
		{"ED with a non-map", authData(0x80, []byte{0x01}), "extensions not a map"},
	}
	for _, c := range errCases {
		_, _, err := parseAuthData(c.in)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err = %v, want %q", c.name, err, c.want)
		}
	}

	_, ext, err := parseAuthData(authData(0x80, extMap))
	if err != nil || ext == nil {
		t.Fatalf("ED map: ext=%v err=%v", ext, err)
	}
	if b, _ := ext.get("hmac-secret").([]byte); !bytes.Equal(b, []byte{1, 2, 3}) {
		t.Errorf("hmac-secret = %v", ext.get("hmac-secret"))
	}

	cid, ext, err := parseAuthData(authData(0xc0, attHead(id), cose, extMap))
	if err != nil || !bytes.Equal(cid, id) || ext == nil {
		t.Fatalf("AT+ED: cid=%x ext=%v err=%v", cid, ext, err)
	}
	if b, _ := ext.get("hmac-secret").([]byte); !bytes.Equal(b, []byte{1, 2, 3}) {
		t.Errorf("AT+ED hmac-secret = %v", ext.get("hmac-secret"))
	}
}

func mustCBOR(t *testing.T, v any) []byte {
	t.Helper()
	b, err := cborEncode(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
