package blindrsa

// NWP-20261122-16: Finalize verifies the unblinded signature before it returns it, so a /issue reply the device cannot
// use fails closed instead of landing in the wallet as credit the gateway refuses at /lease. No test reached that
// refusal before: the round-trip tests call Verify themselves and always sign with the right key. These tests pin
// the refusal only. They pin neither the salt length nor the hash: that is blindrsa_kat_test.go's job, and
// test-blindrsa-kat.sh requires K1 and K2 to survive without it.

import (
	"crypto/rand"
	"crypto/rsa"
	"math/big"
	"testing"
)

func finalizeKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

// finalizeRefused asserts Finalize refused: a non-nil error and a nil signature.
func finalizeRefused(t *testing.T, what string, sig []byte, err error) {
	t.Helper()
	if err == nil || sig != nil {
		t.Fatalf("%s: Finalize returned sig=%d bytes err=%v, want a refusal (nil sig, non-nil error)", what, len(sig), err)
	}
}

// (a) a blind signature made with key B, finalized under key A's public key, is refused.
func TestFinalizeRefusesAnotherKeysSignature(t *testing.T) {
	a, b := finalizeKey(t), finalizeKey(t)
	msg := []byte("1GBmo|finalize-wrong-key|1900000000")
	blinded, inv, err := Blind(&a.PublicKey, msg)
	if err != nil {
		t.Fatal(err)
	}
	// Raw RSA with B over the blinded value, reduced mod B's modulus: BlindSign(b, ...) would refuse a value at or
	// above that modulus about half the time, and this test must always reach Finalize.
	z := new(big.Int).Mod(new(big.Int).SetBytes(blinded), b.N)
	bsig := i2osp(new(big.Int).Exp(z, b.D, b.N), (b.N.BitLen()+7)/8)
	sig, err := Finalize(&a.PublicKey, msg, bsig, inv)
	finalizeRefused(t, "another key's signature", sig, err)
}

// (b) random bytes of the right length as blindSig are refused.
func TestFinalizeRefusesRandomBytes(t *testing.T) {
	a := finalizeKey(t)
	msg := []byte("1GBmo|finalize-random|1900000000")
	_, inv, err := Blind(&a.PublicKey, msg)
	if err != nil {
		t.Fatal(err)
	}
	junk := make([]byte, (a.N.BitLen()+7)/8)
	if _, err := rand.Read(junk); err != nil {
		t.Fatal(err)
	}
	sig, err := Finalize(&a.PublicKey, msg, junk, inv)
	finalizeRefused(t, "random bytes", sig, err)
}

// (c) a blindSig or blindInv one byte short or long is refused with an error, never a panic.
func TestFinalizeRefusesWrongLengths(t *testing.T) {
	a := finalizeKey(t)
	msg := []byte("1GBmo|finalize-lengths|1900000000")
	blinded, inv, err := Blind(&a.PublicKey, msg)
	if err != nil {
		t.Fatal(err)
	}
	bsig, err := BlindSign(a, blinded)
	if err != nil {
		t.Fatal(err)
	}
	long := func(p []byte) []byte { return append(append([]byte{}, p...), 0) }
	for _, c := range []struct {
		label     string
		sig, binv []byte
	}{
		{"blindSig one byte short", bsig[:len(bsig)-1], inv},
		{"blindSig one byte long", long(bsig), inv},
		{"blindInv one byte short", bsig, inv[:len(inv)-1]},
		{"blindInv one byte long", bsig, long(inv)},
	} {
		t.Run(c.label, func(t *testing.T) {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("%s: Finalize panicked: %v", c.label, r)
				}
			}()
			sig, err := Finalize(&a.PublicKey, msg, c.sig, c.binv)
			finalizeRefused(t, c.label, sig, err)
		})
	}
}

// (d) the control: a correct blind signature finalizes, and the result verifies.
func TestFinalizeAcceptsAGoodSignature(t *testing.T) {
	a := finalizeKey(t)
	msg := []byte("1GBmo|finalize-good|1900000000")
	blinded, inv, err := Blind(&a.PublicKey, msg)
	if err != nil {
		t.Fatal(err)
	}
	bsig, err := BlindSign(a, blinded)
	if err != nil {
		t.Fatal(err)
	}
	sig, err := Finalize(&a.PublicKey, msg, bsig, inv)
	if err != nil || sig == nil {
		t.Fatalf("Finalize refused a good signature: sig=%d bytes err=%v", len(sig), err)
	}
	if err := Verify(&a.PublicKey, msg, sig); err != nil {
		t.Fatalf("the finalized signature does not verify: %v", err)
	}
}
