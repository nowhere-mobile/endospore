package main

import (
	"bufio"
	"encoding/hex"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261006-09: tying a profile to this phone's secure element is opt-in from the session's settings (SE-TIE), and
// undoable (SE-UNTIE). These pin the slot changes both ways, the verbs' refusals, and the seal exclusion.

// tieFixture is a cap-mode store with a created profile and a live session marker for it, as user 12.
func tieFixture(t *testing.T, se string) (dest, name, pass string, dk0 []byte) {
	t.Helper()
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	// Every fixture seals the same name and passphrase, so the same chunk ids, into a NEW store: a blob confirmed in
	// an earlier test's store would otherwise be skipped here and never reach this one.
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	name, pass = "tiesse", "horse battery staple correct"
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	v, err := readSessionVault("s3", name, pass)
	if err != nil {
		t.Fatal(err)
	}
	if dk0 = unwrapDK(v, "pass", deriveKey(name, pass)); dk0 == nil {
		t.Fatal("a new profile does not open by passphrase")
	}
	dest = t.TempDir()
	if err := markRoamSession(dest, name, pass, "12", se); err != nil {
		t.Fatal(err)
	}
	return dest, name, pass, dk0
}

var seA = []byte("phone-a-se-secret")

func tieSlotKinds(v *vault) map[string]int {
	m := map[string]int{}
	for _, s := range v.Slots {
		m[s.Kind]++
	}
	return m
}

func TestTieThenUntieRoundTrip(t *testing.T) {
	_, name, pass, dk0 := tieFixture(t, hex.EncodeToString(seA))
	if err := sessionTie("s3", name, pass, seA); err != nil {
		t.Fatal(err)
	}
	v, _ := readSessionVault("s3", name, pass)
	k := tieSlotKinds(v)
	if !v.Hardened || k["pass"] != 0 || k["se"] != 1 || k["recovery"] != 1 {
		t.Fatalf("after a tie: hardened=%v slots=%v, want hardened, one se, the recovery slot, no pass slot", v.Hardened, k)
	}
	if string(unwrapDK(v, "se", kekSE(name, pass, seA))) != string(dk0) {
		t.Fatal("the tied vault does not open through this phone's chip to the same data key")
	}
	if st, _ := seSessionStatus("s3", name, pass, seA); st != seStatusTied {
		t.Fatalf("status after a tie = %s", st)
	}
	if err := sessionUntie("s3", name, pass, seA); err != nil {
		t.Fatal(err)
	}
	v, _ = readSessionVault("s3", name, pass)
	k = tieSlotKinds(v)
	if v.Hardened || k["se"] != 0 || k["pass"] != 1 || k["recovery"] != 1 {
		t.Fatalf("after an untie: hardened=%v slots=%v, want a pass slot and the recovery slot only", v.Hardened, k)
	}
	if string(unwrapDK(v, "pass", deriveKey(name, pass))) != string(dk0) {
		t.Fatal("the untied vault does not open by passphrase alone to the same data key")
	}
	if st, _ := seSessionStatus("s3", name, pass, seA); st != seStatusUntied {
		t.Fatalf("status after an untie = %s", st)
	}
}

// Untie needs THIS phone's chip: another phone's secret opens nothing, and the vault stays tied.
func TestUntieRefusesAnotherPhonesChip(t *testing.T) {
	_, name, pass, _ := tieFixture(t, hex.EncodeToString(seA))
	if err := sessionTie("s3", name, pass, seA); err != nil {
		t.Fatal(err)
	}
	if err := sessionUntie("s3", name, pass, []byte("phone-b-se-secret")); err != errNotTiedHere {
		t.Fatalf("untie with another phone's chip = %v, want errNotTiedHere", err)
	}
	if v, _ := readSessionVault("s3", name, pass); !v.Hardened {
		t.Fatal("a refused untie un-hardened the vault")
	}
}

// A security-key profile stays key-protected through an untie: no pass-only slot appears beside its keys.
func TestUntieSlotsKeepsAKeyProfileKeyOnly(t *testing.T) {
	v := &vault{Hardened: true, Slots: []keyslot{{Kind: "se"}, {Kind: "se"}, {Kind: "fido2"}, {Kind: "recovery"}}}
	untieSlots(v, "n", "p", make([]byte, 32))
	k := tieSlotKinds(v)
	if v.Hardened || k["se"] != 0 || k["pass"] != 0 || k["fido2"] != 1 || k["recovery"] != 1 {
		t.Fatalf("untie of a key profile: hardened=%v slots=%v, want the key and recovery slots only", v.Hardened, k)
	}
	v = &vault{Slots: []keyslot{{Kind: "pass"}, {Kind: "fido2"}, {Kind: "recovery"}}}
	tieSlots(v, "n", "p", seA, make([]byte, 32))
	k = tieSlotKinds(v)
	if !v.Hardened || k["pass"] != 0 || k["se"] != 1 || k["fido2"] != 1 {
		t.Fatalf("tie keeps a key slot and drops the pass slot: slots=%v", k)
	}
}

// seVerb drives handleSETie as caller `peer` and returns its one-line reply.
func seVerb(t *testing.T, dest, verb, body string, peer int) string {
	t.Helper()
	old := seTiePeerUID
	seTiePeerUID = func(net.Conn) int { return peer }
	defer func() { seTiePeerUID = old }()
	server, client := net.Pipe()
	defer client.Close()
	go func() {
		handleSETie(server, bufio.NewReader(strings.NewReader(body)), dest, verb)
		server.Close()
	}()
	client.SetDeadline(time.Now().Add(30 * time.Second))
	l, _ := bufio.NewReader(client).ReadString('\n')
	return strings.TrimSpace(l)
}

func TestSETieVerbs(t *testing.T) {
	dest, name, pass, _ := tieFixture(t, hex.EncodeToString(seA))
	const self, other = 12*100000 + 116, 13*100000 + 116
	for _, c := range []struct {
		verb, body, want string
		peer             int
	}{
		{"SE-STATUS", "", "ERR-CALLER", other}, // another user's app
		{"SE-STATUS", "", "ERR-CALLER", 1116},  // the gate (user 0)
		{"SE-STATUS", "", "OK UNTIED", self},
		{"SE-TIE", "wrong pass\n", "ERR-PASS", self},
		{"SE-STATUS", "", "OK UNTIED", self},         // the refused tie changed nothing
		{"SE-UNTIE", pass + "\n", "ERR-STATE", self}, // nothing to untie
		{"SE-TIE", pass + "\n", "OK", self},
		{"SE-STATUS", "", "OK TIED", self},
		{"SE-TIE", pass + "\n", "ERR-STATE", self}, // already tied
		{"SE-UNTIE", "wrong pass\n", "ERR-PASS", self},
		{"SE-UNTIE", pass + "\n", "OK", self},
		{"SE-STATUS", "", "OK UNTIED", self},
	} {
		if got := seVerb(t, dest, c.verb, c.body, c.peer); got != c.want {
			t.Fatalf("%s %q as %d -> %q, want %q", c.verb, strings.TrimSpace(c.body), c.peer, got, c.want)
		}
	}
	_ = name
}

func TestSETieWithoutAChipOrASession(t *testing.T) {
	dest, _, pass, _ := tieFixture(t, "")
	const self = 12*100000 + 116
	if got := seVerb(t, dest, "SE-STATUS", "", self); got != "OK NOCHIP" {
		t.Fatalf("status on a phone with no chip = %q", got)
	}
	if got := seVerb(t, dest, "SE-TIE", pass+"\n", self); got != "ERR-NOCHIP" {
		t.Fatalf("tie on a phone with no chip = %q", got)
	}
	if got := seVerb(t, t.TempDir(), "SE-STATUS", "", self); got != "ERR-NOSESSION" {
		t.Fatalf("status with no session = %q", got)
	}
}

// A tie waits for the worker's read-write slot -- a seal in flight -- and answers busy rather than racing it.
func TestSETieWaitsForASealInFlight(t *testing.T) {
	dest, name, pass, _ := tieFixture(t, hex.EncodeToString(seA))
	old := seTieSlotWait
	seTieSlotWait = 50 * time.Millisecond
	defer func() { seTieSlotWait = old }()
	laneRW.slot <- struct{}{} // a seal holds the slot
	got := seVerb(t, dest, "SE-TIE", pass+"\n", 12*100000+116)
	<-laneRW.slot
	if got != workerBusy {
		t.Fatalf("a tie during a seal = %q, want %s", got, workerBusy)
	}
	if v, _ := readSessionVault("s3", name, pass); v.Hardened {
		t.Fatal("a tie refused as busy still tied the vault")
	}
}

// NWP-20261007-12: the verbs drive the scope re-key (docs/tie-scope-keys.md §8), in cap mode as on the phone.

// sealDEInSession seals a #de scope holding f.txt = body, as a seal in the session would.
func sealDEInSession(t *testing.T, name, pass, body string) {
	t.Helper()
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", name+"#de", pass, d)
	pushFenceSeq, pushFenceSampled = 0, false // see rotateFixture
}

func TestSETieProtectsTheScopeData(t *testing.T) {
	dest, name, pass, _ := tieFixture(t, hex.EncodeToString(seA))
	const self = 12*100000 + 116
	sealDEInSession(t, name, pass, "app data")
	if got := seVerb(t, dest, "SE-TIE", pass+"\n", self); got != "OK" {
		t.Fatalf("SE-TIE -> %q", got)
	}
	if got := seVerb(t, dest, "SE-STATUS", "", self); got != "OK TIED" {
		t.Fatalf("after a tie the status is %q, want OK TIED (every small scope re-keyed)", got)
	}
	if _, ok := readScopeFile(t, "s3", name+"#de", pass, nil); ok {
		t.Fatal("after SE-TIE the passphrase alone still opens #de")
	}
	if got, ok := readScopeFile(t, "s3", name+"#de", pass, seA); !ok || got != "app data" {
		t.Fatalf("after SE-TIE this phone reads #de as %q (%v)", got, ok)
	}
}

func TestSETieFinishesAPartlyTiedProfile(t *testing.T) {
	dest, name, pass, dk0 := tieFixture(t, hex.EncodeToString(seA))
	const self = 12*100000 + 116
	sealDEInSession(t, name, pass, "app data")
	if got := seVerb(t, dest, "SE-TIE", pass+"\n", self); got != "OK" {
		t.Fatalf("SE-TIE -> %q", got)
	}
	// One scope left behind: its head opens by passphrase again, as a tie that could not re-key it would leave it.
	capWrite(name, pass, dk0, func() {
		if err := untieScopeHeads("s3", name, pass, seA, []string{"#de"}); err != nil {
			t.Fatal(err)
		}
	})
	if got := seVerb(t, dest, "SE-STATUS", "", self); got != "OK TIED PARTIAL" {
		t.Fatalf("with #de passphrase-keyed the status is %q, want OK TIED PARTIAL", got)
	}
	if got := seVerb(t, dest, "SE-TIE", pass+"\n", self); got != "OK" {
		t.Fatalf("SE-TIE on a partly tied profile -> %q, want it to finish the scopes", got)
	}
	if got := seVerb(t, dest, "SE-STATUS", "", self); got != "OK TIED" {
		t.Fatalf("after finishing the status is %q", got)
	}
	if _, ok := readScopeFile(t, "s3", name+"#de", pass, nil); ok {
		t.Fatal("after finishing the passphrase alone still opens #de")
	}
}

func TestSEUntieReopensTheScopesByPassphrase(t *testing.T) {
	dest, name, pass, _ := tieFixture(t, hex.EncodeToString(seA))
	const self = 12*100000 + 116
	sealDEInSession(t, name, pass, "app data")
	if got := seVerb(t, dest, "SE-TIE", pass+"\n", self); got != "OK" {
		t.Fatalf("SE-TIE -> %q", got)
	}
	if got := seVerb(t, dest, "SE-UNTIE", pass+"\n", self); got != "OK" {
		t.Fatalf("SE-UNTIE -> %q", got)
	}
	if got := seVerb(t, dest, "SE-STATUS", "", self); got != "OK UNTIED" {
		t.Fatalf("after untie the status is %q", got)
	}
	if got, ok := readScopeFile(t, "s3", name+"#de", pass, nil); !ok || got != "app data" {
		t.Fatalf("after SE-UNTIE the passphrase reads #de as %q (%v)", got, ok)
	}
}
