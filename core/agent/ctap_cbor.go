package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"sort"
)

// Minimal CTAP2 canonical CBOR (#81 P4a). CTAP2 messages are CBOR maps with small-integer (and a few
// string) keys; we encode/decode only the subset the FIDO2 hmac-secret flow needs -- unsigned/negative
// ints, byte strings, text strings, arrays, maps, bool, null. Hand-rolled + stdlib-only, in character with
// the blind-RSA work; the whole point is that the wire format is unit-testable WITHOUT a security key.
//
// Value model (Go <-> CBOR): uint64 | int64(<0) | []byte | string | bool | nil | []any | *cborMap.
// Maps use *cborMap (an ordered key/value list) so encoding is CTAP2-CANONICAL and deterministic: keys are
// sorted by their encoded bytes, shorter-first then bytewise (the CTAP2 ctap2CanonicalCBOR rule).

type cborKV struct {
	K any // uint64 (integer key) or string (text key)
	V any
}

type cborMap struct{ kv []cborKV }

func newCBORMap() *cborMap { return &cborMap{} }

func (m *cborMap) put(k, v any) *cborMap { m.kv = append(m.kv, cborKV{k, v}); return m }

// get returns the value for an integer or string key, or nil.
func (m *cborMap) get(k any) any {
	for _, e := range m.kv {
		if e.K == k {
			return e.V
		}
	}
	return nil
}

// ---- encode ----

func cborEncode(v any) ([]byte, error) {
	var b bytes.Buffer
	if err := cborEnc(&b, v); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

func cborEnc(b *bytes.Buffer, v any) error {
	switch t := v.(type) {
	case uint64:
		cborHead(b, 0, t)
	case int:
		return cborEnc(b, int64(t))
	case int64:
		if t < 0 {
			cborHead(b, 1, uint64(-1-t))
		} else {
			cborHead(b, 0, uint64(t))
		}
	case []byte:
		cborHead(b, 2, uint64(len(t)))
		b.Write(t)
	case string:
		cborHead(b, 3, uint64(len(t)))
		b.WriteString(t)
	case []any:
		cborHead(b, 4, uint64(len(t)))
		for _, e := range t {
			if err := cborEnc(b, e); err != nil {
				return err
			}
		}
	case *cborMap:
		return cborEncMap(b, t)
	case bool:
		if t {
			b.WriteByte(0xf5)
		} else {
			b.WriteByte(0xf4)
		}
	case nil:
		b.WriteByte(0xf6)
	default:
		return fmt.Errorf("cbor: unsupported type %T", v)
	}
	return nil
}

func cborEncMap(b *bytes.Buffer, m *cborMap) error {
	// Encode each pair, then sort by encoded KEY (CTAP2 canonical: shorter first, then bytewise).
	type enc struct{ key, val []byte }
	encs := make([]enc, 0, len(m.kv))
	for _, e := range m.kv {
		var kb bytes.Buffer
		if err := cborEnc(&kb, e.K); err != nil {
			return err
		}
		var vb bytes.Buffer
		if err := cborEnc(&vb, e.V); err != nil {
			return err
		}
		encs = append(encs, enc{kb.Bytes(), vb.Bytes()})
	}
	sort.SliceStable(encs, func(i, j int) bool {
		if len(encs[i].key) != len(encs[j].key) {
			return len(encs[i].key) < len(encs[j].key)
		}
		return bytes.Compare(encs[i].key, encs[j].key) < 0
	})
	cborHead(b, 5, uint64(len(encs)))
	for _, e := range encs {
		b.Write(e.key)
		b.Write(e.val)
	}
	return nil
}

// cborHead writes a CBOR head: major type (0-7) in the top 3 bits + the argument in the minimal-length form.
func cborHead(b *bytes.Buffer, major byte, arg uint64) {
	mt := major << 5
	switch {
	case arg < 24:
		b.WriteByte(mt | byte(arg))
	case arg < 1<<8:
		b.WriteByte(mt | 24)
		b.WriteByte(byte(arg))
	case arg < 1<<16:
		b.WriteByte(mt | 25)
		var t [2]byte
		binary.BigEndian.PutUint16(t[:], uint16(arg))
		b.Write(t[:])
	case arg < 1<<32:
		b.WriteByte(mt | 26)
		var t [4]byte
		binary.BigEndian.PutUint32(t[:], uint32(arg))
		b.Write(t[:])
	default:
		b.WriteByte(mt | 27)
		var t [8]byte
		binary.BigEndian.PutUint64(t[:], arg)
		b.Write(t[:])
	}
}

// ---- decode ----

var errCBOR = errors.New("cbor: malformed")

// cborMaxDepth bounds how deep arrays and maps may nest (NWP-20261120-16). CTAP2 limits a message to four levels of
// nested maps/arrays; 16 is headroom for any real authenticator. The response is the security key's, and over NFC the
// decode runs inside the login daemon, so without this bound a tag-chosen response nests one level per byte (0x81 0x81
// ...) and recurses the daemon into a fatal stack overflow, which no recover catches. The count bound beside it is
// NWP-20261019-01's, in the array arm.
const cborMaxDepth = 16

func cborDecode(data []byte) (any, error) {
	v, rest, err := cborDecDepth(data, 0)
	if err != nil {
		return nil, err
	}
	if len(rest) != 0 {
		return nil, fmt.Errorf("cbor: %d trailing bytes", len(rest))
	}
	return v, nil
}

// cborDec decodes one item from the top level; ctap_cmd.go's parseAuthData calls it for the COSE key and extensions.
func cborDec(data []byte) (any, []byte, error) { return cborDecDepth(data, 0) }

// cborDecDepth decodes one item that sits inside depth arrays/maps.
func cborDecDepth(data []byte, depth int) (any, []byte, error) {
	if len(data) == 0 {
		return nil, nil, errCBOR
	}
	ib := data[0]
	major := ib >> 5
	arg, rest, err := cborArg(ib&0x1f, data[1:])
	if err != nil {
		return nil, nil, err
	}
	// NWP-20261120-16: a container past cborMaxDepth is refused before any element of it is decoded.
	if (major == 4 || major == 5) && depth >= cborMaxDepth {
		return nil, nil, errCBOR
	}
	switch major {
	case 0: // unsigned int
		return arg, rest, nil
	case 1: // negative int
		return int64(-1 - int64(arg)), rest, nil
	case 2: // byte string
		if uint64(len(rest)) < arg {
			return nil, nil, errCBOR
		}
		out := make([]byte, arg) // non-nil even for arg==0 (an empty byte string is not a null)
		copy(out, rest[:arg])
		return out, rest[arg:], nil
	case 3: // text string
		if uint64(len(rest)) < arg {
			return nil, nil, errCBOR
		}
		return string(rest[:arg]), rest[arg:], nil
	case 4: // array
		// NWP-20261019-01: the count is the security key's, and over NFC this runs inside the login daemon, so an
		// unbounded count is an allocation any tapped tag can choose (9a 40 00 00 00 asked for 16 GiB). Every
		// element takes at least one byte, so a count past the bytes left cannot be honest.
		if arg > uint64(len(rest)) {
			return nil, nil, errCBOR
		}
		out := make([]any, 0, arg)
		for i := uint64(0); i < arg; i++ {
			var e any
			e, rest, err = cborDecDepth(rest, depth+1)
			if err != nil {
				return nil, nil, err
			}
			out = append(out, e)
		}
		return out, rest, nil
	case 5: // map
		m := newCBORMap()
		for i := uint64(0); i < arg; i++ {
			var k, v any
			k, rest, err = cborDecDepth(rest, depth+1)
			if err != nil {
				return nil, nil, err
			}
			v, rest, err = cborDecDepth(rest, depth+1)
			if err != nil {
				return nil, nil, err
			}
			m.kv = append(m.kv, cborKV{k, v})
		}
		return m, rest, nil
	case 7: // simple values
		switch ib & 0x1f {
		case 20:
			return false, rest, nil
		case 21:
			return true, rest, nil
		case 22, 23:
			return nil, rest, nil // null / undefined
		}
	}
	return nil, nil, fmt.Errorf("cbor: unsupported major/simple 0x%02x", ib)
}

// cborArg reads the argument that follows an initial-byte's low 5 bits (the count/value), returning it and
// the remaining bytes. Rejects indefinite-length (0x1f) -- CTAP2 canonical CBOR forbids it.
func cborArg(lo byte, data []byte) (uint64, []byte, error) {
	switch {
	case lo < 24:
		return uint64(lo), data, nil
	case lo == 24:
		if len(data) < 1 {
			return 0, nil, errCBOR
		}
		return uint64(data[0]), data[1:], nil
	case lo == 25:
		if len(data) < 2 {
			return 0, nil, errCBOR
		}
		return uint64(binary.BigEndian.Uint16(data)), data[2:], nil
	case lo == 26:
		if len(data) < 4 {
			return 0, nil, errCBOR
		}
		return uint64(binary.BigEndian.Uint32(data)), data[4:], nil
	case lo == 27:
		if len(data) < 8 {
			return 0, nil, errCBOR
		}
		return binary.BigEndian.Uint64(data), data[8:], nil
	}
	return 0, nil, fmt.Errorf("cbor: bad/indefinite length 0x%02x", lo)
}

// ---- typed accessors used by the CTAP2 command layer (P4b) ----

func cborUint(v any) (uint64, bool)  { u, ok := v.(uint64); return u, ok }
func cborBytes(v any) ([]byte, bool) { b, ok := v.([]byte); return b, ok }
func cborStr(v any) (string, bool)   { s, ok := v.(string); return s, ok }
func cborArr(v any) ([]any, bool)    { a, ok := v.([]any); return a, ok }
func asCBORMap(v any) (*cborMap, bool) {
	m, ok := v.(*cborMap)
	return m, ok
}
