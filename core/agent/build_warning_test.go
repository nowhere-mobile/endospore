package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

const bwNow = int64(1767312000)

// bwUseKey swaps buildWarningKey for the seed-7 test key and restores it on cleanup.
func bwUseKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	k := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{7}, 32))
	old := buildWarningKey
	buildWarningKey = base64.RawURLEncoding.EncodeToString(k.Public().(ed25519.PublicKey))
	t.Cleanup(func() { buildWarningKey = old })
	return k
}

func bwSign(k ed25519.PrivateKey, body []byte) string {
	return base64.RawURLEncoding.EncodeToString(ed25519.Sign(k, append([]byte(buildWarningDomain), body...)))
}

func bwBody(seq, issued, expires int64, versions ...string) []byte {
	b, _ := json.Marshal(map[string]any{"schema": 1, "seq": seq, "issued": issued, "expires": expires, "versions": versions})
	return b
}

func bwGood(versions ...string) []byte {
	if len(versions) == 0 {
		versions = []string{"0.5.45"}
	}
	return bwBody(7, bwNow-86400, bwNow+30*86400, versions...)
}

func bwVerify(t *testing.T, k ed25519.PrivateKey, body []byte, floor int64) (*buildWarning, error) {
	t.Helper()
	return verifyBuildWarning(buildWarningKey, buildWarningEnvelope(body, bwSign(k, body)), bwNow, floor)
}

func bwRefused(t *testing.T, k ed25519.PrivateKey, body []byte, floor int64, want string) {
	t.Helper()
	w, err := bwVerify(t, k, body, floor)
	if err == nil || w != nil {
		t.Fatalf("accepted %s", body)
	}
	if want != "" && !strings.Contains(err.Error(), want) {
		t.Fatalf("error %q does not mention %q", err, want)
	}
}

func TestBuildWarning_W1_GoodObject(t *testing.T) {
	k := bwUseKey(t)
	w, err := bwVerify(t, k, bwGood(), 6)
	if err != nil {
		t.Fatal(err)
	}
	if !w.affects("0.5.45") || w.affects("0.5.44") {
		t.Fatalf("affects wrong: %+v", w)
	}
	if (*buildWarning)(nil).affects("0.5.45") {
		t.Fatal("a nil warning affects nothing")
	}
}

func TestBuildWarning_W2_BodyOnlySignatureRefused(t *testing.T) {
	k := bwUseKey(t)
	body := bwGood()
	sig := base64.RawURLEncoding.EncodeToString(ed25519.Sign(k, body))
	if _, err := verifyBuildWarning(buildWarningKey, buildWarningEnvelope(body, sig), bwNow, 0); err == nil {
		t.Fatal("a signature without the domain prefix passed")
	}
}

func TestBuildWarning_W3_WrongKeyRefused(t *testing.T) {
	bwUseKey(t)
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{8}, 32))
	bwRefused(t, other, bwGood(), 0, "signature")
}

func TestBuildWarning_W4_FlippedByteRefused(t *testing.T) {
	k := bwUseKey(t)
	body := bwGood()
	sig := bwSign(k, body)
	i := bytes.Index(body, []byte(`"seq":7`)) + len(`"seq":`)
	bad := append([]byte(nil), body...)
	bad[i] = '8'
	if _, err := verifyBuildWarning(buildWarningKey, buildWarningEnvelope(bad, sig), bwNow, 0); err == nil {
		t.Fatal("a flipped body byte passed")
	}
}

func TestBuildWarning_W5_EnvelopeShape(t *testing.T) {
	k := bwUseKey(t)
	body := bwGood()
	sig := bwSign(k, body)
	wrong := []byte("nowhere-ota-release 1\n" + sig + "\n" + string(body))
	if _, err := verifyBuildWarning(buildWarningKey, wrong, bwNow, 0); err == nil {
		t.Fatal("wrong magic passed")
	}
	trunc := []byte(buildWarningMagic + "\n" + sig)
	if _, err := verifyBuildWarning(buildWarningKey, trunc, bwNow, 0); err == nil {
		t.Fatal("a truncated envelope passed")
	}
}

func TestBuildWarning_W6_SeqFloor(t *testing.T) {
	k := bwUseKey(t)
	bwRefused(t, k, bwGood(), 7, "replay")
	bwRefused(t, k, bwGood(), 8, "replay")
	if _, err := bwVerify(t, k, bwGood(), 6); err != nil {
		t.Fatal(err)
	}
}

func TestBuildWarning_W7_Freshness(t *testing.T) {
	k := bwUseKey(t)
	bwRefused(t, k, bwBody(7, bwNow-maxIndexStaleness-1, bwNow+86400, "0.5.45"), 0, "stale")
	bwRefused(t, k, bwBody(7, bwNow+2*86400, bwNow+3*86400, "0.5.45"), 0, "future")
	if _, err := bwVerify(t, k, bwBody(7, bwNow-maxIndexStaleness, bwNow+86400, "0.5.45"), 0); err != nil {
		t.Fatal(err)
	}
}

func TestBuildWarning_W8_Expiry(t *testing.T) {
	k := bwUseKey(t)
	bwRefused(t, k, bwBody(7, bwNow-86400, bwNow, "0.5.45"), 0, "expired")
	bwRefused(t, k, bwBody(7, bwNow+3600, bwNow+1800, "0.5.45"), 0, "before it was issued")
}

func TestBuildWarning_W9_RequiredFields(t *testing.T) {
	k := bwUseKey(t)
	iss, exp := bwNow-86400, bwNow+86400
	for name, body := range map[string]string{
		"missing seq":     fmt.Sprintf(`{"schema":1,"issued":%d,"expires":%d,"versions":["0.5.45"]}`, iss, exp),
		"zero seq":        fmt.Sprintf(`{"schema":1,"seq":0,"issued":%d,"expires":%d,"versions":["0.5.45"]}`, iss, exp),
		"zero issued":     fmt.Sprintf(`{"schema":1,"seq":7,"issued":0,"expires":%d,"versions":["0.5.45"]}`, exp),
		"missing expires": fmt.Sprintf(`{"schema":1,"seq":7,"issued":%d,"versions":["0.5.45"]}`, iss),
	} {
		t.Run(name, func(t *testing.T) { bwRefused(t, k, []byte(body), -1, "absent or zero") })
	}
	bwRefused(t, k, []byte(fmt.Sprintf(`{"schema":2,"seq":7,"issued":%d,"expires":%d,"versions":["0.5.45"]}`, iss, exp)), 0, "schema")
	bwRefused(t, k, []byte(fmt.Sprintf(`{"seq":7,"issued":%d,"expires":%d,"versions":["0.5.45"]}`, iss, exp)), 0, "schema")
}

func TestBuildWarning_W10_Versions(t *testing.T) {
	k := bwUseKey(t)
	many := func(n int) []string {
		var v []string
		for i := 0; i < n; i++ {
			v = append(v, fmt.Sprintf("0.5.%d", i))
		}
		return v
	}
	bwRefused(t, k, bwBody(7, bwNow-86400, bwNow+86400), 0, "0 versions")
	bwRefused(t, k, bwGood(many(65)...), 0, "")
	if _, err := bwVerify(t, k, bwGood(many(64)...), 0); err != nil {
		t.Fatal(err)
	}
	bwRefused(t, k, bwGood("0.5.45", "0.5.45"), 0, "twice")
	if _, err := bwVerify(t, k, bwGood("0.5"), 0); err != nil {
		t.Fatal(err)
	}
	bwRefused(t, k, bwGood("v0.5.45"), 0, "malformed")
	bwRefused(t, k, bwGood("0.5.45 "), 0, "malformed")
}

func TestBuildWarning_W11_OversizeBeforeSignature(t *testing.T) {
	k := bwUseKey(t)
	body := bytes.Repeat([]byte{' '}, buildWarningMaxBytes+1)
	bwRefused(t, k, body, 0, "bytes")
	_, err := verifyBuildWarning(buildWarningKey, buildWarningEnvelope(body, "garbage"), bwNow, 0)
	if err == nil || strings.Contains(err.Error(), "signature") {
		t.Fatalf("size must be refused before the signature is checked: %v", err)
	}
}

// The vector NOWHERE-991 pins: ed25519 is deterministic, so the signature is a literal.
const (
	bwVecBody = `{"schema":1,"seq":7,"issued":1767225600,"expires":1769904000,"versions":["0.5.45","0.5.46"]}`
	bwVecSig  = "UOE4jP_K0tHdrVvlhA4VfatNeDi56xYRNrNKsRXwdHGh1E_RS9s_tvC0sPYCV4BFf4yu6AKQSC2e-zIk9MzpBA"
	bwVecEnv  = "nowhere-build-warning 1\n" + bwVecSig + "\n" + bwVecBody
)

func TestBuildWarning_W12_Vector(t *testing.T) {
	k := bwUseKey(t)
	if got := bwSign(k, []byte(bwVecBody)); got != bwVecSig {
		t.Fatalf("signature %s", got)
	}
	if got := string(buildWarningEnvelope([]byte(bwVecBody), bwVecSig)); got != bwVecEnv {
		t.Fatalf("envelope %q", got)
	}
	w, err := verifyBuildWarning(buildWarningKey, []byte(bwVecEnv), 1767312000, 6)
	if err != nil {
		t.Fatal(err)
	}
	if w.Seq != 7 || !w.affects("0.5.45") || !w.affects("0.5.46") || w.affects("0.5.47") {
		t.Fatalf("%+v", w)
	}
}
