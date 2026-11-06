package main

// NWP-20261104-11: the vault head's bytes and signature, and the chunk manifest's json names, pinned to values
// computed OUTSIDE Go (Python: HMAC-SHA256 under HMAC-SHA256(DK, "nowhere-head-sig") over the bytes, base64) from the
// struct order on main. Every other agent test signs and verifies with the same struct, so a reorder is
// self-consistent there and invisible; here it is not.
//
// The Minimal and ImportShape literals are the ones nowhere-cloud cmd/importwasm must also produce (NOWHERE-858).
// Changing the field order of vault, a json tag, vaultMagic or the HMAC label is a STORE MIGRATION: after it every
// stored head re-serializes differently from what was signed and fails verifyVault on every device. Never "fix" a
// golden by pasting Go's new output.

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"reflect"
	"sort"
	"strings"
	"testing"
)

var (
	vaultGoldM = strings.Repeat("a", 64)
	vaultGoldR = strings.Repeat("b", 64)
	vaultGoldC = strings.Repeat("c", 64)
)

func vaultGoldDK() []byte {
	dk := make([]byte, 32)
	for i := range dk {
		dk[i] = byte(i)
	}
	return dk
}

func vaultGoldMinimal() *vault {
	return &vault{
		V:           1,
		Slots:       []keyslot{{Kind: "pass", Wrapped: "cGFzcw=="}, {Kind: "recovery", Wrapped: "cmVj"}},
		Manifest:    vaultGoldM,
		RecoveryRef: vaultGoldR,
		Version:     1,
	}
}

// vaultGoldCheck asserts the unsigned bytes (literal, length, sha256), then re-signs from a signed head and asserts
// the Sig and that verifyVault accepts it.
func vaultGoldCheck(t *testing.T, v *vault, wantBytes string, wantLen int, wantSHA, wantSig string) {
	t.Helper()
	dk := vaultGoldDK()
	v.Sig = ""
	b := serializeVault(v)
	if string(b) != wantBytes {
		t.Fatalf("serializeVault bytes changed (a store migration):\n got %s\nwant %s\n got %q", b, wantBytes, b)
	}
	if len(b) != wantLen {
		t.Fatalf("serializeVault length %d, want %d: %s", len(b), wantLen, b)
	}
	sum := sha256.Sum256(b)
	if got := hex.EncodeToString(sum[:]); got != wantSHA {
		t.Fatalf("serializeVault sha256 %s, want %s: %s", got, wantSHA, b)
	}
	v.Sig = "stale"
	signVault(v, dk)
	if v.Sig != wantSig {
		t.Fatalf("signVault Sig %q, want %q over %s", v.Sig, wantSig, b)
	}
	if !verifyVault(v, dk) {
		t.Fatalf("verifyVault rejects its own re-signed head: %s", b)
	}
	if v.Sig != wantSig {
		t.Fatalf("verifyVault left Sig %q, want %q", v.Sig, wantSig)
	}
}

const vaultGoldMinimalHead = `DSPRVLT1{"v":1,"slots":[{"kind":"pass","wrapped":"cGFzcw=="},{"kind":"recovery","wrapped":"cmVj"}],"manifest":"%M","recovery_ref":"%R","version":1,"sig":""`

func vaultGoldExpand(s string) string {
	return strings.NewReplacer("%M", vaultGoldM, "%R", vaultGoldR, "%C", vaultGoldC).Replace(s)
}

func TestVaultGoldenMinimal(t *testing.T) {
	vaultGoldCheck(t, vaultGoldMinimal(), vaultGoldExpand(vaultGoldMinimalHead+"}"), 280,
		"f10fc9dae7c6af5f2585cc2c2bcbfa4cb27dee5adead4b3aa78a8ffa3baa1f85",
		"uYgaOBpFY3eskOtxj6Yv5MTbBNyG2ZXZ8n+K26JVuLo=")
}

func TestVaultGoldenImportShape(t *testing.T) {
	v := vaultGoldMinimal()
	v.TelPub, v.TelPriv = "dGVscHVi", "dGVscHJpdg=="
	vaultGoldCheck(t, v, vaultGoldExpand(vaultGoldMinimalHead+`,"tel_pub":"dGVscHVi","tel_priv":"dGVscHJpdg=="}`), 327,
		"b47bf34d720822a7182fe74da77008c8e161f37f38aad7c087e38d7ce359662e",
		"poM3A3cYWovBpyx7QBiA2onvT3xvg98PQsehZP1Vh5k=")
}

// vaultGoldSlotsCover fails for any keyslot field that no slot in slots sets: a field belongs to one slot kind (the
// fido2 metadata, the se slot's LabelSealed), so the golden covers each field on the kind that carries it.
func vaultGoldSlotsCover(t *testing.T, slots []keyslot) {
	t.Helper()
	typ := reflect.TypeOf(keyslot{})
	for i := 0; i < typ.NumField(); i++ {
		set := false
		for _, s := range slots {
			set = set || !reflect.ValueOf(s).Field(i).IsZero()
		}
		if !set {
			t.Errorf("keyslot.%s is zero in the every-field golden", typ.Field(i).Name)
		}
	}
}

// vaultGoldNonZero fails for any field of the struct value s that is its zero value.
func vaultGoldNonZero(t *testing.T, s reflect.Value) {
	t.Helper()
	for i := 0; i < s.NumField(); i++ {
		if s.Field(i).IsZero() {
			t.Errorf("%s.%s is zero in the every-field golden", s.Type().Name(), s.Type().Field(i).Name)
		}
	}
}

func TestVaultGoldenEveryField(t *testing.T) {
	v := &vault{
		V: 1,
		Slots: []keyslot{
			{Kind: "se", Wrapped: "c2U=", LabelSealed: "c2VhbGVk"},
			{Kind: "fido2", Wrapped: "Zmlkbw==", CredID: "Y3JlZA==", Salt: "c2FsdA==", UV: true, Added: 1700000001, Label: "key", Transport: "nfc"},
			{Kind: "recovery", Wrapped: "cmVj"},
		},
		Manifest:    vaultGoldM,
		RecoveryRef: vaultGoldR,
		Version:     7,
		LastSeal:    1700000000,
		History:     []headSnap{{Version: 6, Manifest: vaultGoldC, Time: 1699990000, Kind: "manual"}},
		HeadKind:    "manual",
		Hardened:    true,
		Pin:         "cGlu",
		TelPub:      "dGVscHVi",
		TelPriv:     "dGVscHJpdg==",
		ReleaseGen:  3,
		Scopes:      "c2NvcGVz",
	}
	vaultGoldSlotsCover(t, v.Slots)
	vaultGoldNonZero(t, reflect.ValueOf(v.History[0]))
	// every field but Sig (the check clears it) must be set, so the golden really covers them all
	for i := 0; i < reflect.ValueOf(*v).NumField(); i++ {
		if name := reflect.TypeOf(*v).Field(i).Name; name != "Sig" && reflect.ValueOf(*v).Field(i).IsZero() {
			t.Errorf("vault.%s is zero in the every-field golden", name)
		}
	}
	if t.Failed() {
		return
	}
	want := `DSPRVLT1{"v":1,"slots":[{"kind":"se","wrapped":"c2U=","label_sealed":"c2VhbGVk"},{"kind":"fido2","wrapped":"Zmlkbw==","cred_id":"Y3JlZA==","salt":"c2FsdA==","uv":true,"added":1700000001,"label":"key","transport":"nfc"},{"kind":"recovery","wrapped":"cmVj"}],"manifest":"%M","recovery_ref":"%R","version":7,"last_seal":1700000000,"history":[{"version":6,"manifest":"%C","time":1699990000,"kind":"manual"}],"head_kind":"manual","sig":"","hardened":true,"pin":"cGlu","tel_pub":"dGVscHVi","tel_priv":"dGVscHJpdg==","release_gen":3,"scopes":"c2NvcGVz"}`
	vaultGoldCheck(t, v, vaultGoldExpand(want), 732,
		"7bfa98656b75a357b1c25d20067d7529abc79b7222175e298c7680ed0f7aa631",
		"2YdyZi0pHvzynRDV+21MKkDPbuy1Eke66Ip7VSraBK8=")
}

func TestVaultGoldenFieldCounts(t *testing.T) {
	for _, c := range []struct {
		name string
		got  int
		want int
	}{
		{"vault", reflect.TypeOf(vault{}).NumField(), 15},
		{"keyslot", reflect.TypeOf(keyslot{}).NumField(), 9},
		{"headSnap", reflect.TypeOf(headSnap{}).NumField(), 4},
	} {
		if c.got != c.want {
			t.Errorf("%s has %d fields, the goldens know %d: SET the new field in TestVaultGoldenEveryField's golden first, "+
				"recompute its bytes, sha256 and Sig OUTSIDE Go (Python, from the struct order), then raise this count. "+
				"A new omitempty field left out of every golden leaves every golden green, and an older image cannot "+
				"verify a head that carries it.", c.name, c.got, c.want)
		}
	}
}

func TestManifestWireNames(t *testing.T) {
	const wire = `{"v":2,"chunks":["aaa","bbb"],"sz":[111,222],"deferred":{"Pictures/x.jpg":{"c":["ccc"],"z":[333],"p":[30],"s":333,"m":420,"t":1700000000}},"pkg":{"com.example":1},"ess":{"DCIM/a.bin":{"s":0,"e":1,"z":5,"t":1700000000,"m":384}},"essidx":true,"pspan":{"com.example":[[0,1]]}}`
	var m chunkManifest
	if err := json.Unmarshal([]byte(wire), &m); err != nil {
		t.Fatal(err)
	}
	if m.Version != 2 || !reflect.DeepEqual(m.Chunks, []string{"aaa", "bbb"}) || !reflect.DeepEqual(m.Sizes, []int64{111, 222}) {
		t.Errorf("v/chunks/sz did not reach their fields: %+v", m)
	}
	wantDef := deferredFile{Chunks: []string{"ccc"}, Sz: []int64{333}, Pz: []int64{30}, Size: 333, Mode: 420, MTime: 1700000000}
	if got := m.Deferred["Pictures/x.jpg"]; len(m.Deferred) != 1 || !reflect.DeepEqual(got, wantDef) {
		t.Errorf("deferred entry %+v, want %+v", got, wantDef)
	}
	if len(m.Pkg) != 1 || m.Pkg["com.example"] != 1 {
		t.Errorf("pkg %+v", m.Pkg)
	}
	wantEss := essRegion{S: 0, E: 1, Size: 5, MT: 1700000000, Mode: 384}
	if got := m.Ess["DCIM/a.bin"]; len(m.Ess) != 1 || got != wantEss {
		t.Errorf("ess entry %+v, want %+v", got, wantEss)
	}
	if !m.EssIdx {
		t.Errorf("essidx did not reach EssIdx")
	}
	if !reflect.DeepEqual(m.PkgSpan, map[string][][2]int{"com.example": {{0, 1}}}) {
		t.Errorf("pspan did not reach PkgSpan: %+v", m.PkgSpan)
	}
	out, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(out, &keys); err != nil {
		t.Fatal(err)
	}
	var got []string
	for k := range keys {
		got = append(got, k)
	}
	sort.Strings(got)
	want := []string{"chunks", "deferred", "ess", "essidx", "pkg", "pspan", "sz", "v"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("marshalled top-level keys %v, want %v: %s", got, want, out)
	}
	if !bytes.Equal(cdcMagic, []byte("DSPRCDC1")) || !bytes.Equal(vaultMagic, []byte("DSPRVLT1")) {
		t.Errorf("magics changed: cdc %q vault %q", cdcMagic, vaultMagic)
	}
}
