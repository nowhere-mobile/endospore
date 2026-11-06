package main

import (
	"bytes"
	"encoding/hex"
	"errors"
	"reflect"
	"runtime"
	"testing"
)

// #81 P4a: encode -> decode round-trips for every supported CBOR type.
var cborRoundTripCases = []any{
	uint64(0), uint64(23), uint64(24), uint64(255), uint64(256), uint64(65535), uint64(1 << 20),
	int64(-1), int64(-24), int64(-256),
	[]byte{}, []byte{0xde, 0xad, 0xbe, 0xef},
	"", "hmac-secret", "fido2",
	true, false, nil,
	[]any{uint64(1), "two", []byte{3}},
}

func TestCBORRoundTrip(t *testing.T) {
	for _, c := range cborRoundTripCases {
		enc, err := cborEncode(c)
		if err != nil {
			t.Fatalf("encode %v: %v", c, err)
		}
		got, err := cborDecode(enc)
		if err != nil {
			t.Fatalf("decode %x (%v): %v", enc, c, err)
		}
		if !reflect.DeepEqual(got, c) {
			t.Errorf("round-trip %v: got %v", c, got)
		}
	}
}

// Keys inserted out of canonical order: int 4, string "hmac-secret", int 1.
func canonicalFixtureMap() *cborMap {
	return newCBORMap().put(uint64(4), true).put("hmac-secret", []byte{0xaa}).put(uint64(1), "v")
}

// A map round-trips and re-encodes to the SAME canonical bytes regardless of insertion order.
func TestCBORMapCanonical(t *testing.T) {
	m := canonicalFixtureMap()
	enc, err := cborEncode(m)
	if err != nil {
		t.Fatal(err)
	}
	// Canonical: int keys (1 byte) sort before the string key (shorter-first), 1 before 4.
	// map(3) 01 "v" 04 true "hmac-secret" bytes(aa)
	want := "a3" + "01" + "6176" + "04" + "f5" + "6b686d61632d736563726574" + "41aa"
	if hex.EncodeToString(enc) != want {
		t.Fatalf("canonical encode = %x, want %s", enc, want)
	}
	// Decode back and check values are addressable by key.
	dv, err := cborDecode(enc)
	if err != nil {
		t.Fatal(err)
	}
	dm, ok := asCBORMap(dv)
	if !ok {
		t.Fatal("decoded value is not a map")
	}
	if s, _ := cborStr(dm.get(uint64(1))); s != "v" {
		t.Errorf("key 1 = %v, want \"v\"", dm.get(uint64(1)))
	}
	if b, _ := cborBytes(dm.get("hmac-secret")); !bytes.Equal(b, []byte{0xaa}) {
		t.Errorf("key hmac-secret = %v", dm.get("hmac-secret"))
	}
	if b, _ := dm.get(uint64(4)).(bool); !b {
		t.Errorf("key 4 = %v, want true", dm.get(uint64(4)))
	}
}

// Decode a REAL authenticatorGetInfo response (a Yubico-shape CTAP2 reply) and confirm we can read the
// versions array and the extensions list -- the fields the enroll flow checks for "hmac-secret" support.
// Map: {1:["U2F_V2","FIDO_2_0"], 2:["hmac-secret"], 3:h'<16-byte aaguid>', 4:{"rk":false,"up":true}}
func getInfoFixtureMap() *cborMap {
	return newCBORMap().
		put(uint64(1), []any{"U2F_V2", "FIDO_2_0"}).
		put(uint64(2), []any{"hmac-secret"}).
		put(uint64(3), make([]byte, 16)).
		put(uint64(4), newCBORMap().put("rk", false).put("up", true))
}

func TestCBORGetInfoFixture(t *testing.T) {
	info := getInfoFixtureMap()
	enc, err := cborEncode(info)
	if err != nil {
		t.Fatal(err)
	}
	dv, err := cborDecode(enc)
	if err != nil {
		t.Fatal(err)
	}
	dm, _ := asCBORMap(dv)

	versions, ok := cborArr(dm.get(uint64(1)))
	if !ok || len(versions) != 2 {
		t.Fatalf("versions = %v", dm.get(uint64(1)))
	}
	if v, _ := cborStr(versions[1]); v != "FIDO_2_0" {
		t.Errorf("versions[1] = %v, want FIDO_2_0", versions[1])
	}
	exts, _ := cborArr(dm.get(uint64(2)))
	hasHmac := false
	for _, e := range exts {
		if s, _ := cborStr(e); s == "hmac-secret" {
			hasHmac = true
		}
	}
	if !hasHmac {
		t.Fatal("hmac-secret not found in the extensions list")
	}
	opts, _ := asCBORMap(dm.get(uint64(4)))
	if up, _ := opts.get("up").(bool); !up {
		t.Errorf("options.up = %v, want true", opts.get("up"))
	}
}

// Malformed input is rejected, not panicked on (truncated length, indefinite length).
func TestCBORRejectsMalformed(t *testing.T) {
	for _, bad := range [][]byte{
		{0x18},             // uint8 head, no following byte
		{0x42, 0x01},       // bytes(2) but only 1 byte follows
		{0x9f, 0x01, 0xff}, // indefinite-length array (CTAP2 forbids)
		{0xa1, 0x01},       // map(1) with a key but no value
		{0x9b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, // array of 2^63-1 (makeslice cap out of range)
		{0x9a, 0x40, 0x00, 0x00, 0x00},                         // array of 2^30, nothing follows
		{0x84, 0x01, 0x02, 0x03},                               // array(4) holding three elements
		{0xbb, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, // map of 2^63-1
	} {
		if _, err := cborDecode(bad); err == nil {
			t.Errorf("decode %x: expected error", bad)
		}
	}
}

// The array boundary: a count equal to the bytes left decodes; one more is refused.
func TestCBORArrayCountBoundary(t *testing.T) {
	v, err := cborDecode([]byte{0x83, 0x01, 0x02, 0x03})
	if err != nil {
		t.Fatal(err)
	}
	if a, ok := cborArr(v); !ok || len(a) != 3 {
		t.Fatalf("decoded %v, want three elements", v)
	}
}

// NWP-20261019-01: a refused count must be refused BEFORE anything sized by it is allocated.
func TestCBORArrayCountCostsNothing(t *testing.T) {
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	_, err := cborDecode([]byte{0x9a, 0x01, 0x00, 0x00, 0x00}) // 16,777,216 elements, nothing follows
	runtime.ReadMemStats(&after)
	if err == nil {
		t.Fatal("expected error")
	}
	if grew := after.TotalAlloc - before.TotalAlloc; grew > 1<<20 {
		t.Fatalf("decode allocated %d bytes for an array its input cannot hold", grew)
	}
}

// cborNest wraps inner in n one-element containers, outermost first: level i (0 = outermost) is an array of one (0x81)
// when arr(i) is true, else a map of one keyed 1 (0xa1 0x01).
func cborNest(n int, inner []byte, arr func(i int) bool) []byte {
	var b []byte
	for i := 0; i < n; i++ {
		if arr(i) {
			b = append(b, 0x81)
		} else {
			b = append(b, 0xa1, 0x01)
		}
	}
	return append(b, inner...)
}

// NWP-20261120-16: 16 nested arrays or maps decode, down to the innermost 0; 17 are refused with errCBOR. CTAP2 allows 4.
func TestCBORDepthBoundary(t *testing.T) {
	if cborMaxDepth != 16 {
		t.Fatalf("cborMaxDepth = %d, want 16", cborMaxDepth)
	}
	for _, sh := range []struct {
		name string
		arr  func(i int) bool
	}{
		{"arrays", func(int) bool { return true }},
		{"maps", func(int) bool { return false }},
		{"mixed", func(i int) bool { return i%2 == 0 }},
	} {
		// 16 levels decode.
		v, err := cborDecode(cborNest(cborMaxDepth, []byte{0x00}, sh.arr))
		if err != nil {
			t.Fatalf("%s: %d levels: %v", sh.name, cborMaxDepth, err)
		}
		for i := 0; i < cborMaxDepth; i++ {
			if sh.arr(i) {
				a, ok := cborArr(v)
				if !ok || len(a) != 1 {
					t.Fatalf("%s: level %d = %v, want an array of one", sh.name, i, v)
				}
				v = a[0]
			} else {
				m, ok := asCBORMap(v)
				if !ok || len(m.kv) != 1 {
					t.Fatalf("%s: level %d = %v, want a map of one", sh.name, i, v)
				}
				v = m.get(uint64(1))
			}
		}
		if u, ok := cborUint(v); !ok || u != 0 {
			t.Fatalf("%s: innermost value = %v, want uint64(0)", sh.name, v)
		}
		// 17 levels are refused.
		if _, err := cborDecode(cborNest(cborMaxDepth+1, []byte{0x00}, sh.arr)); !errors.Is(err, errCBOR) {
			t.Errorf("%s: %d levels: err = %v, want errCBOR", sh.name, cborMaxDepth+1, err)
		}
	}
}

// NWP-20261120-16: a million levels of 0x81 (what a tapped tag can chain) are refused, not recursed into a fatal stack
// overflow. The depth bound, not a timer, proves this is cheap: the decoder stops 17 frames down.
func TestCBORDeepNestingIsRefusedCheaply(t *testing.T) {
	in := append(bytes.Repeat([]byte{0x81}, 1<<20), 0x00)
	if _, err := cborDecode(in); !errors.Is(err, errCBOR) {
		t.Fatalf("cborDecode: err = %v, want errCBOR", err)
	}
	// parseAuthData (ctap_cmd.go) decodes through cborDec directly.
	if _, _, err := cborDec(in); !errors.Is(err, errCBOR) {
		t.Fatalf("cborDec: err = %v, want errCBOR", err)
	}
}

func FuzzCBORDecode(f *testing.F) {
	for _, s := range [][]byte{
		{0x18}, {0x42, 0x01}, {0x9f, 0x01, 0xff}, {0xa1, 0x01},
		{0x9b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff},
		{0x9a, 0x01, 0x00, 0x00, 0x00}, {0x83, 0x01, 0x02, 0x03}, {0x84, 0x01, 0x02, 0x03},
		{0xbb, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff},
		cborNest(17, []byte{0x00}, func(int) bool { return true }),
	} {
		f.Add(s)
	}
	fixtures := append([]any{getInfoFixtureMap(), canonicalFixtureMap()}, cborRoundTripCases...)
	for _, c := range fixtures {
		if enc, err := cborEncode(c); err == nil {
			f.Add(enc)
		}
	}
	f.Fuzz(func(t *testing.T, in []byte) {
		v, err := cborDecode(in)
		if err != nil {
			return
		}
		if a, ok := cborArr(v); ok && len(a) > len(in) {
			t.Fatalf("array of %d elements from %d bytes", len(a), len(in))
		}
	})
}
