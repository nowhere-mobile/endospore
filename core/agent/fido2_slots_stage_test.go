package main

import (
	"io"
	"os"
	"path/filepath"
	"testing"
)

// Tests for stashFido2SlotsPre and its callers (NWP-20261112-15). A committing keyed sign-in must stage its slot
// spec: roamd promotes .fido2slots.pre at commit, the cold lock bakes it into marker line 7, and a keyed resume
// takes its slots from that line only. So the stage is atomic (temp + rename, never a torn file), and a stage
// that fails stops the NFC fresh login (before the key is asserted) and the adopt, instead of committing a
// session whose first cold lock cannot resume.

var (
	slotStageSpecA = []fido2SlotInfo{{CredID: "QQ==", Salt: "c2FsdEE=", UV: true}}
	slotStageSpecB = []fido2SlotInfo{{CredID: "Qg==", Salt: "c2FsdEI="}}
)

// slotStagePlantTmpDir puts a non-empty DIRECTORY where the stage's temp file goes, so neither the write nor
// the rename can succeed and the stage's cleanup cannot clear it.
func slotStagePlantTmpDir(t *testing.T, dir string) {
	t.Helper()
	d := filepath.Join(dir, ".fido2slots.pre.tmp")
	if err := os.MkdirAll(d, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, "x"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func slotStageRead(t *testing.T, dir string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, ".fido2slots.pre"))
	if err != nil {
		t.Fatalf("read .fido2slots.pre: %v", err)
	}
	return string(b)
}

func TestSlotStageReplacesThePreSpecAtomically(t *testing.T) {
	dir := t.TempDir()
	if err := stashFido2SlotsPre(dir, slotStageSpecA); err != nil {
		t.Fatalf("staging A: %v", err)
	}
	f, err := os.Open(filepath.Join(dir, ".fido2slots.pre"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := stashFido2SlotsPre(dir, slotStageSpecB); err != nil {
		t.Fatalf("staging B: %v", err)
	}
	old, err := io.ReadAll(f)
	if err != nil {
		t.Fatal(err)
	}
	if string(old) != encodeSlotSpec(slotStageSpecA) {
		t.Fatalf("the file A was read from now holds %q: the stage rewrote it in place, so a reader can see a torn spec", old)
	}
	if got := slotStageRead(t, dir); got != encodeSlotSpec(slotStageSpecB) {
		t.Fatalf(".fido2slots.pre = %q, want B's spec", got)
	}
	if _, err := os.Stat(filepath.Join(dir, ".fido2slots.pre.tmp")); !os.IsNotExist(err) {
		t.Fatalf("the stage left its temp file behind: %v", err)
	}
}

func TestSlotStageFailedWriteKeepsTheOldSpecAndSaysSo(t *testing.T) {
	dir := t.TempDir()
	if err := stashFido2SlotsPre(dir, slotStageSpecA); err != nil {
		t.Fatalf("staging A: %v", err)
	}
	slotStagePlantTmpDir(t, dir)
	if err := stashFido2SlotsPre(dir, slotStageSpecB); err == nil {
		t.Error("a stage that could not be written returned no error")
	}
	if got := slotStageRead(t, dir); got != encodeSlotSpec(slotStageSpecA) {
		t.Fatalf(".fido2slots.pre = %q after a failed stage, want A's spec untouched", got)
	}
}

// slotStageNFCRun signs a fresh fido2 profile in over NFC, with or without the plant, through a stub that
// records whether the key was asserted.
func slotStageNFCRun(t *testing.T, name string, plant bool) (reply string, asserted bool, e *nfcVerbEnv) {
	t.Helper()
	e = newNFCVerbEnv(t)
	const pass = "slot stage passphrase"
	e.fido2Profile(t, name, pass)
	old := nfcAssert
	t.Cleanup(func() { nfcAssert = old })
	nfcAssert = func(transceiver, []fido2SlotInfo) ([]byte, error) {
		asserted = true
		return nfcVerbHmac, nil
	}
	if plant {
		slotStagePlantTmpDir(t, e.dest)
	}
	reply = e.run(t, "FIDO2-NFC-ASSERT", name, pass) // run waits for the handler, so asserted is settled
	return reply, asserted, e
}

func TestSlotStageNFCFreshLoginRefusesWhenTheSpecIsNotStaged(t *testing.T) {
	reply, asserted, e := slotStageNFCRun(t, "slotstage-c2", false)
	if reply != "OK\n" || !asserted {
		t.Fatalf("control failed: reply %q, asserted %v; want OK after an assert", reply, asserted)
	}
	reply, asserted, e = slotStageNFCRun(t, "slotstage-c", true)
	if reply != "ERR\n" {
		t.Errorf("reply %q with the spec not staged, want the generic ERR", reply)
	}
	if asserted {
		t.Error("the key was asserted although the login could not stage its spec")
	}
	if e.has(".fido2hmac.pre") {
		t.Error("a login that could not stage its spec left .fido2hmac.pre for roamd to commit")
	}
}

func TestSlotStageAdoptRefusesWhenTheSpecIsNotStaged(t *testing.T) {
	base, st := adoptSetup(t)
	const name, pass = "slotstage-d", "slot stage adopt passphrase"
	h := adoptEnrolKeyOnly(t, base, name, pass)
	adoptStub(t, func(credID, salt []byte, uv bool) ([]byte, error) { return h, nil })
	slotStagePlantTmpDir(t, st)
	got, err := adoptFido2Key(base, name, pass, st)
	if err == nil {
		t.Error("an adopt that could not stage its spec returned no error")
	}
	if got != nil {
		t.Error("an adopt that could not stage its spec returned the hmac")
	}
}
