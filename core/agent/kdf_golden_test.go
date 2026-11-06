package main

import (
	"encoding/hex"
	"os"
	"reflect"
	"regexp"
	"strings"
	"testing"

	"github.com/tyler-smith/go-bip39"
)

// NWP-20261104-04: the agent's profile derivations are pinned to the vectors the gateway and the web pages hold.
//
// Where the vectors come from: nowhere-cloud 5f8d7fb -- internal/storekey/storekey_test.go TestDerivationGoldens
// (the profile keys and refs, the scope heads of the operator deny-set), cmd/exportwasm/recovery_test.go
// (kekRecovery and the 12 words) and cmd/importwasm/scope_refs_test.go (the scope list); cmd/importwasm/write.go
// recoveryRef holds the same formula as the agent's recoveryRef, and its vector was computed in Python as the sha256 of
// "nowhere-recovery-ref:goldenprofile", a NUL byte and the entropy's lowercase hex.
//
// A deliberate change to any derivation here is a STORE MIGRATION (every stored profile, recovery pointer and
// operator head is addressed by these values), never a test update: change the gateway and the web pages in step.

type kdfGoldRow struct{ name, pass, v2, legacy, key string }

var kdfGoldRows = []kdfGoldRow{
	{"os-lynx", "nowhere-os", "f70e4d6695838ca7673fe8d136478c71f9cd460b41acbe42f8c9018a4fe1d0df", "190f08601f3411a00dd73307faaed1ad4cf06ac09d03722558eb35162dffe535", "6b2fcf955f365129e448b4a427dc1906262a700aae23b860546ec097fcc2ff06"},
	{"Alice Example", "correct horse", "0902e6d3864d0bc22b6e7c8fd580ce10c85d2a464bc0ed6fc070af9f87e2f0ef", "e4d20b6af91afdc1b0d293c6d0040c07b07866fe6f3411a5fc082e52ec7296a3", "5237afecd5e3991e1b3eb0b6227c2dcf0fdcdc74a7f962a5f36e5fd405c5a5f0"},
	{"goldenprofile", "goldenpass", "983bb46a1feac98750edf39a5bd85a2e36dc5dff84ea3c96901cac4c160ee97d", "ea49756ab1bca2f920c29458f294c42a25f732a6799119ba927dad8e7201845e", "5994f95be6056672ffdd9609c2c418177b3696e78ea8173a79b6bcad90ae477f"},
}

func TestKDFGoldens(t *testing.T) {
	deriveKeyForget()
	t.Cleanup(deriveKeyForget)
	for _, r := range kdfGoldRows {
		if got := hex.EncodeToString(deriveKeyUncached(r.name, r.pass)); got != r.key {
			t.Errorf("argon2Key(%q): %s, want %s -- a KDF change strands every stored profile", r.name, got, r.key)
		}
		if got := profileRefV2(r.name, r.pass); got != r.v2 {
			t.Errorf("profileRefV2(%q): %s, want %s", r.name, got, r.v2)
		}
		if got := profileRefLegacy(r.name, r.pass); got != r.legacy {
			t.Errorf("profileRefLegacy(%q): %s, want %s", r.name, got, r.legacy)
		}
		if r.v2 == r.legacy {
			t.Errorf("%q: v2 and legacy refs are equal", r.name)
		}
	}
	// The suffix goes on the NAME, as the gateway's deny-set derives a scope head.
	if got, want := profileRefV2("os-lynx#media", "nowhere-os"), "4a762fa4a3ab3f52cd6f4689254263b0a9abdb79f2383bab8beddc8f686cf65e"; got != want {
		t.Errorf("v2 head os-lynx#media: %s, want %s", got, want)
	}
	if got, want := profileRefLegacy("os-lynx#wallet", "nowhere-os"), "c0d1b79f964583df6a78154e0240e6de3db946578b45fb31142b62bc808aa6de"; got != want {
		t.Errorf("legacy head os-lynx#wallet: %s, want %s", got, want)
	}
}

func TestKDFGoldens_Recovery(t *testing.T) {
	entropy, err := hex.DecodeString("00070e151c232a31383f464d545b6269")
	if err != nil {
		t.Fatal(err)
	}
	const words = "abandon debris luxury debate crawl blush thought trip essence people sudden stadium"
	m, err := bip39.NewMnemonic(entropy)
	if err != nil || m != words {
		t.Errorf("NewMnemonic: %q, %v, want %q", m, err, words)
	}
	back, err := bip39.EntropyFromMnemonic(words)
	if err != nil || hex.EncodeToString(back) != hex.EncodeToString(entropy) {
		t.Errorf("EntropyFromMnemonic: %x, %v, want %x", back, err, entropy)
	}
	if got, want := hex.EncodeToString(kekRecovery("goldenprofile", entropy)), "ffc649227152b646e4ac64a086d52362cbec9ef7ab1b3dbca73a4cf3f0b97454"; got != want {
		t.Errorf("kekRecovery: %s, want %s", got, want)
	}
	if got, want := recoveryRef("goldenprofile", entropy), "741a6840e4c7c00048341a57beb2bf833b55ebaf2b0cb34785f83fad9cea0174"; got != want {
		t.Errorf("recoveryRef: %s, want %s -- every existing recovery code would be stranded", got, want)
	}
}

func TestKDFGoldens_ScopeSuffixes(t *testing.T) {
	want := []string{"", "#de", "#media", "#sys", "#apps", "#keys", "#wallet"}
	if !reflect.DeepEqual(deleteScopeSuffixes, want) {
		t.Errorf("deleteScopeSuffixes = %q, want %q: a new scope must be added to nowhere-cloud internal/storekey ScopeSuffixes and to cmd/importwasm importScopeSuffixes in the same change", deleteScopeSuffixes, want)
	}
}

// kdfGoldOSPass matches an OSPASS assignment anywhere on a line (e4-ota-publish.sh writes it after a `;`).
var kdfGoldOSPass = regexp.MustCompile(`(^|[;[:space:]])OSPASS=([^[:space:];]*)`)

func TestKDFGoldens_OSPassphrase(t *testing.T) {
	for _, f := range []string{"../vendor-common/bin/nowhere_otad.sh", "../../editions/endospore/build/e4-ota-publish.sh"} {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		var vals []string
		for _, line := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "#") {
				continue
			}
			for _, m := range kdfGoldOSPass.FindAllStringSubmatch(line, -1) {
				vals = append(vals, m[2])
			}
		}
		if len(vals) != 1 {
			t.Errorf("%s: %d OSPASS= assignments, want exactly 1", f, len(vals))
		} else if vals[0] != "nowhere-os" {
			t.Errorf("%s: OSPASS=%q, want nowhere-os (storekey.OSPass, the deny-set's passphrase)", f, vals[0])
		}
	}
}
