package blindrsa

// Known-answer tests for the two parameters that the round-trip tests cannot see.
//
// TestInteropWithStdlibPSS hard-codes crypto.SHA384 but takes the package's own saltLen, and Blind/Verify
// share that constant, so two edits kept the suite green: `const saltLen = 48` changed (Blind encodes and
// Verify checks with the new value, the round trip still holds, but the gateway checks 48 and answers 402 for
// every token the phone finalizes), and Verify's `SaltLength: saltLen` changed to rsa.PSSSaltLengthAuto
// (accepts any salt). Both mutants SURVIVED the pre-change tests (test-blindrsa-kat.sh runs them against
// origin/main's test files; K1 and K2 both survive there, and are convicted with this file).
//
// TWIN: nowhere-cloud internal/blindrsa/blindrsa_kat_test.go holds the SAME constants. Both files must stay
// identical in every constant below; changing one is a protocol change for both halves (device finalizes,
// gateway verifies), never an edit to one repo.
//
// The EMSA-PSS vector below was computed with Python 3's standard library only (never Go), following RFC 8017
// section 9.1.1 (mHash = SHA-384("nowhere-blindrsa-kat-v1"), salt = 0x00..0x2f, emBits = 2047), the way
// storekey_test.go's goldens were "computed independently, outside Go". To re-run it:
//
//	import hashlib
//
//	H = hashlib.sha384
//	m_hash = H(b"nowhere-blindrsa-kat-v1").digest()
//	salt = bytes(range(48))
//	em_bits = 2047
//	em_len = (em_bits + 7) // 8                      # 256
//	h_len, s_len = len(m_hash), len(salt)
//
//
//	def mgf1(seed, length):
//	    out = b""
//	    counter = 0
//	    while len(out) < length:
//	        out += H(seed + counter.to_bytes(4, "big")).digest()
//	        counter += 1
//	    return out[:length]
//
//
//	h = H(b"\x00" * 8 + m_hash + salt).digest()      # M' = 8 zero bytes || mHash || salt
//	db = b"\x00" * (em_len - s_len - h_len - 2) + b"\x01" + salt
//	masked = bytes(a ^ b for a, b in zip(db, mgf1(h, em_len - h_len - 1)))
//	masked = bytes([masked[0] & (0xFF >> (8 * em_len - em_bits))]) + masked[1:]
//	em = masked + h + b"\xbc"
//	print(len(em), em.hex())

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha512"
	"encoding/hex"
	"testing"
)

// katSHA384abc is the FIPS 180-2 SHA-384 digest of "abc".
const katSHA384abc = "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"

// katEM is the 256-byte EM for emsaPSSEncode(SHA-384("nowhere-blindrsa-kat-v1"), 0x00..0x2f, 2047).
const katEM = "" +
	"76648a156e5144732fb73c6709c95fc605e44c0455f3897b8a0eafea7899fb61" +
	"3bb202b37504a81df8b0fc59b9d9ef59b730fc2a9ad38fab4775ca0d1945cb50" +
	"27661c5c633cccdba92b3d02b462a1eda36cf130137e9d7cca300078704f6d90" +
	"391dbeb809b0029b731c8383cb460f05cf2c4746fd3466cae6e35a3f72262f99" +
	"cd01a7d022dd01e4da46fd821e4deabddb50b4b3b2a7db554c970603aae3a9f0" +
	"b405c670a2e3403d72ee8074c33151b40560825846afc651e41cd4b7af79eb0f" +
	"a5de2f9c1a84572b8bc88f9c1827462990e9e998d9056572b7b8644095741e37" +
	"daa1d4547e2777c635f14852b3730e8268d895b5ceed314d5ca87edda530d5bc"

func TestKAT_SaltAndHash(t *testing.T) {
	if saltLen != 48 {
		t.Fatalf("saltLen = %d, want 48 (the gateway verifies with 48)", saltLen)
	}
	h := newHash()
	if h.Size() != 48 {
		t.Fatalf("newHash().Size() = %d, want 48 (SHA-384)", h.Size())
	}
	h.Write([]byte("abc"))
	if got := hex.EncodeToString(h.Sum(nil)); got != katSHA384abc {
		t.Fatalf("newHash() of abc = %s, want SHA-384 %s", got, katSHA384abc)
	}

	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	pub := &priv.PublicKey
	msg := []byte("1GBmo|abcd1234|1750000000")
	mh := sha512.Sum384(msg)
	sign := func(salt int) []byte {
		sig, err := rsa.SignPSS(rand.Reader, priv, crypto.SHA384, mh[:], &rsa.PSSOptions{SaltLength: salt, Hash: crypto.SHA384})
		if err != nil {
			t.Fatalf("SignPSS salt %d: %v", salt, err)
		}
		return sig
	}
	if err := Verify(pub, msg, sign(48)); err != nil {
		t.Fatalf("Verify refused a stdlib PSS signature with a 48-byte salt: %v", err)
	}
	for _, salt := range []int{32, 64} {
		if err := Verify(pub, msg, sign(salt)); err == nil {
			t.Fatalf("Verify accepted a stdlib PSS signature with a %d-byte salt", salt)
		}
	}
}

func TestKAT_EmsaPSSEncode(t *testing.T) {
	want, err := hex.DecodeString(katEM)
	if err != nil || len(want) != 256 {
		t.Fatalf("katEM is not 256 hex-decoded bytes: len %d err %v", len(want), err)
	}
	mHash := sha512.Sum384([]byte("nowhere-blindrsa-kat-v1"))
	salt := make([]byte, 48)
	for i := range salt {
		salt[i] = byte(i)
	}
	got, err := emsaPSSEncode(mHash[:], salt, 2047)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("emsaPSSEncode =\n%x\nwant (Python, RFC 8017 9.1.1)\n%x", got, want)
	}
}
