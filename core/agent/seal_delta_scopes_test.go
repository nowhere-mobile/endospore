package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261113-08, backlog row "Your data's save copy says the wrong thing in four cases", case (2): after a
// shrink-guard refusal of the vault, Your data blamed a concurrent change, because SEAL-DELTA told the chooser
// only the verdict word and `parts`. SEAL-DELTA now serves the last verdict's SCOPE lines, the guard picked as
// GET-LOGOFF-REFUSAL picks it. Every assertion reads the handler's JSON, never the global.

// sdsEnv starts a stored session of this file's own profile with an empty $NOWHERE_STATE.
func sdsEnv(t *testing.T) string {
	t.Helper()
	tr := trackGoSafe(t)
	siresetEnv(t)
	siresetJoin(t, tr)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Cleanup(func() { resetSealStatus(); resetSealSignals() })
	dest := t.TempDir()
	if err := markRoamSession(dest, "sdscopes-a", "pw-sdscopes", "31", ""); err != nil {
		t.Fatal(err)
	}
	return dest
}

// sdsStash writes the refusal-reasons stash the seal process leaves for recordSeal ("<scope> <guard>" lines).
func sdsStash(t *testing.T, lines ...string) {
	t.Helper()
	p := filepath.Join(os.Getenv("NOWHERE_STATE"), refusalReasonsFile)
	if err := os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// sdsReply asks SEAL-DELTA and returns its "scopes" value and whether the key is present at all.
func sdsReply(t *testing.T, dest string) (string, bool) {
	t.Helper()
	reply := ropReply(t, func(c net.Conn) { handleSealDelta(c, dest) })
	nl := strings.IndexByte(reply, '\n')
	if nl < 0 || !strings.HasPrefix(reply, "OK ") {
		t.Fatalf("SEAL-DELTA reply %q", reply)
	}
	body := reply[nl+1:]
	if want := fmt.Sprintf("OK %d", len(body)); reply[:nl] != want {
		t.Fatalf("frame %q for a %d-byte body", reply[:nl], len(body))
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(body), &m); err != nil {
		t.Fatal(err)
	}
	v, has := m["scopes"]
	if !has {
		return "", false
	}
	s, ok := v.(string)
	if !ok {
		t.Fatalf("scopes = %#v, want a string", v)
	}
	return s, true
}

func sdsWant(t *testing.T, dest, want string) {
	t.Helper()
	got, has := sdsReply(t, dest)
	if !has || got != want {
		t.Fatalf("SEAL-DELTA scopes = %q (present %v), want %q", got, has, want)
	}
}

func sdsWantNone(t *testing.T, dest string) {
	t.Helper()
	if got, has := sdsReply(t, dest); has {
		t.Fatalf("SEAL-DELTA scopes = %q, want no \"scopes\" key", got)
	}
}

func TestSealDeltaScopesShrinkGuardOnVault(t *testing.T) {
	dest := sdsEnv(t)
	sdsStash(t, "vault shrink")
	recordSeal("ERR-REFUSED PARTIAL:vault=refused")
	sdsWant(t, dest, "SCOPE vault refused:shrink 0")
}

func TestSealDeltaScopesNoStash(t *testing.T) {
	dest := sdsEnv(t)
	recordSeal("OK PARTIAL:apps=refused")
	sdsWant(t, dest, "SCOPE apps refused 0")
}

func TestSealDeltaScopesCleanOKClears(t *testing.T) {
	dest := sdsEnv(t)
	sdsStash(t, "vault shrink")
	recordSeal("ERR-REFUSED PARTIAL:vault=refused")
	sdsWant(t, dest, "SCOPE vault refused:shrink 0")
	recordSeal("OK")
	sdsWantNone(t, dest)
}

func TestSealDeltaScopesSupersededKeeps(t *testing.T) {
	dest := sdsEnv(t)
	sdsStash(t, "vault shrink")
	recordSeal("ERR-REFUSED PARTIAL:vault=refused")
	recordSeal("SKIP-SUPERSEDED")
	sdsWant(t, dest, "SCOPE vault refused:shrink 0")
}

func TestSealDeltaScopesFinalGuardWins(t *testing.T) {
	dest := sdsEnv(t)
	sdsStash(t, "vault stale", "vault shrink", "de fence")
	recordSeal("ERR-REFUSED PARTIAL:vault=refused,de=refused")
	sdsWant(t, dest, "SCOPE vault refused:shrink 0\nSCOPE de refused:fence 0")
}

func TestSealDeltaScopesResetSealSignalsClears(t *testing.T) {
	dest := sdsEnv(t)
	sdsStash(t, "vault shrink")
	recordSeal("ERR-REFUSED PARTIAL:vault=refused")
	sdsWant(t, dest, "SCOPE vault refused:shrink 0")
	resetSealSignals() // a new sign-in: the last session's scope lines must not reach it (NOWHERE-923's rule)
	sdsWantNone(t, dest)
}

func TestSealDeltaScopesAbsentWhenEmpty(t *testing.T) {
	dest := sdsEnv(t)
	sdsWantNone(t, dest)
	b, err := json.Marshal(sealDeltaReply{V: 1})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), `"scopes"`) {
		t.Fatalf("an empty reply carries a scopes key: %s", b)
	}
}
