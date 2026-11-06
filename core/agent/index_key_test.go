package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

const iktNow = int64(1767312000)

// iktUseKey swaps indexKeyObjectKey for the seed-9 test release key and restores it on cleanup.
func iktUseKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	k := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{9}, 32))
	old := indexKeyObjectKey
	indexKeyObjectKey = base64.RawURLEncoding.EncodeToString(k.Public().(ed25519.PublicKey))
	t.Cleanup(func() { indexKeyObjectKey = old })
	return k
}

func iktSign(k ed25519.PrivateKey, domain string, body []byte) string {
	return base64.RawURLEncoding.EncodeToString(ed25519.Sign(k, append([]byte(domain), body...)))
}

// iktIndexKey is the STANDARD base64 of a seeded ed25519 public key: the spelling indexPubKey uses.
func iktIndexKey(seed byte) string {
	k := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{seed}, 32))
	return base64.StdEncoding.EncodeToString(k.Public().(ed25519.PublicKey))
}

func iktBody(m map[string]any) []byte {
	b, _ := json.Marshal(m)
	return b
}

// iktFields is a good body's fields; a case changes or deletes some of them.
func iktFields() map[string]any {
	return map[string]any{"schema": 1, "seq": 3, "issued": iktNow - 3600, "key": iktIndexKey(1), "revoked": []string{iktIndexKey(2)}}
}

func iktVerify(t *testing.T, k ed25519.PrivateKey, body []byte, floor int64) (*indexKeyObject, error) {
	t.Helper()
	return verifyIndexKeyObject(indexKeyObjectKey, indexKeyEnvelope(body, iktSign(k, indexKeyDomain, body)), iktNow, floor)
}

func iktRefused(t *testing.T, name string, obj *indexKeyObject, err error) {
	t.Helper()
	if err == nil || obj != nil {
		t.Fatalf("%s: accepted (obj %+v, err %v)", name, obj, err)
	}
	t.Logf("%s: %v", name, err)
}

// iktAltSpelling returns the same 32 key bytes in another spelling: the last data character with a spare bit flipped,
// which the standard decoder ignores, or failing that the key padded with spaces, which it trims.
func iktAltSpelling(t *testing.T, key string) string {
	t.Helper()
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	want, err := indexKeyBytes(key)
	if err != nil {
		t.Fatal(err)
	}
	same := func(s string) bool {
		b, err := indexKeyBytes(s)
		return s != key && err == nil && bytes.Equal(b, want)
	}
	i := strings.IndexByte(alphabet, key[42])
	alt := key[:42] + string(alphabet[i^1]) + key[43:]
	if same(alt) {
		return alt
	}
	alt = " " + key + "\n"
	if !same(alt) {
		t.Fatalf("no other spelling of %q found", key)
	}
	return alt
}

func TestIndexKeyObjectKeyIsReleaseKey(t *testing.T) {
	if indexKeyObjectKey != releasePubKey {
		t.Fatalf("indexKeyObjectKey is %q, not releasePubKey", indexKeyObjectKey)
	}
}

func TestIndexKeyGoodRollover(t *testing.T) {
	k := iktUseKey(t)
	obj, err := iktVerify(t, k, iktBody(iktFields()), 2)
	if err != nil {
		t.Fatal(err)
	}
	if obj.Key != iktIndexKey(1) || obj.Seq != 3 || obj.Issued != iktNow-3600 || obj.Schema != 1 {
		t.Fatalf("wrong object: %+v", obj)
	}
	if len(obj.Revoked) != 1 || obj.Revoked[0] != iktIndexKey(2) {
		t.Fatalf("wrong revoked list: %+v", obj.Revoked)
	}
}

func TestIndexKeyGoodRevocation(t *testing.T) {
	k := iktUseKey(t)
	f := iktFields()
	delete(f, "key")
	obj, err := iktVerify(t, k, iktBody(f), 0)
	if err != nil {
		t.Fatal(err)
	}
	if obj.Key != "" || len(obj.Revoked) != 1 || obj.Revoked[0] != iktIndexKey(2) {
		t.Fatalf("wrong object: %+v", obj)
	}
}

func TestIndexKeyRefusals(t *testing.T) {
	k := iktUseKey(t)
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{8}, 32))
	good := iktBody(iktFields())

	short := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{5}, 31))
	urlKey := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0xfb}, 32))
	if !strings.ContainsAny(urlKey, "-_") || strings.Contains(urlKey, "=") {
		t.Fatalf("the base64url case %q is also standard base64", urlKey)
	}
	var many []string
	for i := 0; i < 17; i++ {
		many = append(many, iktIndexKey(byte(20+i)))
	}
	with := func(edit func(map[string]any)) []byte {
		f := iktFields()
		edit(f)
		return iktBody(f)
	}
	over := append(append([]byte(nil), good...), bytes.Repeat([]byte{' '}, indexKeyMaxBytes+1-len(good))...)

	envs := map[string][]byte{
		"bad signature": indexKeyEnvelope(good, iktSign(other, indexKeyDomain, good)),
		"build-warning domain": func() []byte {
			b := bwBody(7, iktNow-86400, iktNow+30*86400, "0.5.45")
			return indexKeyEnvelope(b, iktSign(k, buildWarningDomain, b))
		}(),
		"body signed with no domain": indexKeyEnvelope(good, iktSign(k, "", good)),
	}
	for name, env := range envs {
		obj, err := verifyIndexKeyObject(indexKeyObjectKey, env, iktNow, 0)
		iktRefused(t, name, obj, err)
	}

	bodies := map[string]struct {
		body  []byte
		floor int64
	}{
		"schema 2":                {with(func(f map[string]any) { f["schema"] = 2 }), 0},
		"schema absent":           {with(func(f map[string]any) { delete(f, "schema") }), 0},
		"seq absent":              {with(func(f map[string]any) { delete(f, "seq") }), 0},
		"seq zero":                {with(func(f map[string]any) { f["seq"] = 0 }), -1},
		"issued absent":           {with(func(f map[string]any) { delete(f, "issued") }), 0},
		"seq == floor":            {good, 3},
		"seq below floor":         {good, 4},
		"issued in the future":    {with(func(f map[string]any) { f["issued"] = iktNow + 86400 + 1 }), 0},
		"a 31-byte key":           {with(func(f map[string]any) { f["key"] = short }), 0},
		"a 31-byte revoked":       {with(func(f map[string]any) { f["revoked"] = []string{short} }), 0},
		"a base64url-only key":    {with(func(f map[string]any) { f["key"] = urlKey }), 0},
		"the new key revoked":     {with(func(f map[string]any) { f["revoked"] = []string{iktIndexKey(2), iktIndexKey(1)} }), 0},
		"duplicate revoked":       {with(func(f map[string]any) { f["revoked"] = []string{iktIndexKey(2), iktIndexKey(2)} }), 0},
		"17 revoked":              {with(func(f map[string]any) { delete(f, "key"); f["revoked"] = many }), 0},
		"neither key nor revoked": {with(func(f map[string]any) { delete(f, "key"); delete(f, "revoked") }), 0},
		"empty revoked, no key":   {with(func(f map[string]any) { delete(f, "key"); f["revoked"] = []string{} }), 0},
		"a body over the bound":   {over, 0},
		"not JSON":                {[]byte("not json"), 0},
	}
	for name, c := range bodies {
		obj, err := iktVerify(t, k, c.body, c.floor)
		iktRefused(t, name, obj, err)
	}
}

func TestIndexKeyRefusesTheNewKeyRevokedInAnotherSpelling(t *testing.T) {
	k := iktUseKey(t)
	f := iktFields()
	f["revoked"] = []string{iktAltSpelling(t, iktIndexKey(1))}
	obj, err := iktVerify(t, k, iktBody(f), 0)
	iktRefused(t, "the new key revoked in another spelling", obj, err)
	f["revoked"] = []string{iktIndexKey(2), iktAltSpelling(t, iktIndexKey(2))}
	obj, err = iktVerify(t, k, iktBody(f), 0)
	iktRefused(t, "a revoked key listed twice in two spellings", obj, err)
}

func TestIndexKeyBoundaries(t *testing.T) {
	k := iktUseKey(t)
	f := iktFields()
	f["issued"] = iktNow + 86400
	if _, err := iktVerify(t, k, iktBody(f), 0); err != nil {
		t.Fatalf("issued exactly one day ahead refused: %v", err)
	}
	good := iktBody(iktFields())
	full := append(append([]byte(nil), good...), bytes.Repeat([]byte{' '}, indexKeyMaxBytes-len(good))...)
	if _, err := iktVerify(t, k, full, 0); err != nil {
		t.Fatalf("a body of exactly %d bytes refused: %v", len(full), err)
	}
	var sixteen []string
	for i := 0; i < 16; i++ {
		sixteen = append(sixteen, iktIndexKey(byte(40+i)))
	}
	f = iktFields()
	f["revoked"] = sixteen
	if _, err := iktVerify(t, k, iktBody(f), 0); err != nil {
		t.Fatalf("16 revoked keys refused: %v", err)
	}
}

func TestIndexKeySignatureCheckedFirst(t *testing.T) {
	iktUseKey(t)
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{8}, 32))
	f := iktFields()
	f["schema"] = 2
	body := iktBody(f)
	obj, err := verifyIndexKeyObject(indexKeyObjectKey, indexKeyEnvelope(body, iktSign(other, indexKeyDomain, body)), iktNow, 0)
	iktRefused(t, "bad signature over a schema-2 body", obj, err)
	if !strings.Contains(err.Error(), "signature") {
		t.Fatalf("a body was judged before its signature: %v", err)
	}
}

func TestIndexKeyOtherEnvelopes(t *testing.T) {
	k := iktUseKey(t)
	b := bwBody(7, iktNow-86400, iktNow+30*86400, "0.5.45")
	envs := map[string][]byte{
		"a build-warning envelope": buildWarningEnvelope(b, iktSign(k, buildWarningDomain, b)),
		"a truncated envelope":     []byte(indexKeyMagic + "\nsig-with-no-body"),
		"empty":                    nil,
	}
	for name, env := range envs {
		obj, err := verifyIndexKeyObject(indexKeyObjectKey, env, iktNow, 0)
		iktRefused(t, name, obj, err)
	}
}

func TestIndexKeyActive(t *testing.T) {
	baked := iktIndexKey(3)
	if got := activeIndexKey(baked, nil); got != baked {
		t.Fatalf("no object: got %q, want the baked key", got)
	}
	roll := &indexKeyObject{Schema: 1, Seq: 1, Issued: iktNow, Key: iktIndexKey(1), Revoked: []string{baked}}
	if got := activeIndexKey(baked, roll); got != iktIndexKey(1) {
		t.Fatalf("rollover: got %q, want the new key", got)
	}
	other := &indexKeyObject{Schema: 1, Seq: 1, Issued: iktNow, Revoked: []string{iktIndexKey(2)}}
	if got := activeIndexKey(baked, other); got != baked {
		t.Fatalf("revocation of another key: got %q, want the baked key", got)
	}
	mine := &indexKeyObject{Schema: 1, Seq: 1, Issued: iktNow, Revoked: []string{iktIndexKey(2), baked}}
	if got := activeIndexKey(baked, mine); got != "" {
		t.Fatalf("revocation of the baked key: got %q, want no key", got)
	}
	alt := iktAltSpelling(t, baked)
	if got := activeIndexKey(alt, mine); got != "" {
		t.Fatalf("revocation of the baked key, baked spelled %q: got %q, want no key", alt, got)
	}
}
