package main

import (
	"os"
	"strings"
	"testing"
)

// NWP-20261129-52: the wallet's side files leave the state tmpfs with it. wallet.json.moving holds the time of the
// departed profile's unsettled credential change, and a process that died between noteWalletSeen's write and its
// rename leaves wallet.json.seen.tmp (plain token nonces, hashed blind messages).

// sideFilesPlant writes both side files beside wpath. Plant after f.session: its sign-in runs removeWallet, and its
// saves overwrite and rename the temp file.
func sideFilesPlant(t *testing.T, wpath string) {
	t.Helper()
	notePlanMoving(wpath, planMovingNow())
	if err := os.WriteFile(wpath+".seen.tmp", []byte("gen\nt:not-a-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(planMovingPath(wpath)); err != nil {
		t.Fatalf("fixture: the marker was not written: %v", err)
	}
}

// D1: a landed sign-out removes both, and leaves the .gen and the .lock.
func TestSignOutSideFiles_ALandedSignOutRemovesBoth(t *testing.T) {
	f := walletFailSetup(t)
	f.session(t)
	gen := f.gen()
	sideFilesPlant(t, f.wpath)
	dropped, err, log := f.logoutStep(t, gen)
	if err != nil || !dropped {
		t.Fatalf("dropped=%v err=%v; stderr:\n%s", dropped, err, log)
	}
	assertGone(t, f.wpath, planMovingPath(f.wpath), f.wpath+".seen.tmp")
	for _, keep := range []string{f.wpath + ".gen", f.wpath + ".lock"} {
		if _, serr := os.Stat(keep); serr != nil {
			t.Errorf("the drop removed %s: %v", keep, serr)
		}
	}
}

// D2: removeWallet removes both.
func TestSignOutSideFiles_RemoveWalletRemovesBoth(t *testing.T) {
	_, wpath := chainFixture(t)
	sideFilesPlant(t, wpath)
	removeWallet(wpath)
	assertGone(t, wpath, planMovingPath(wpath), wpath+".seen.tmp")
}

// D3: a refused drop removes neither. The hook writes the file directly: saveWallet would consume the planted temp
// file through noteWalletSeen, and this test would then fail for the wrong reason.
func TestSignOutSideFiles_ARefusedDropRemovesNothing(t *testing.T) {
	f := walletFailSetup(t)
	f.session(t)
	gen := f.gen()
	sideFilesPlant(t, f.wpath)
	logoutHooks(t, nil, func() {
		if err := os.WriteFile(f.wpath, append(logoutRead(t, f.wpath), '\n'), 0o600); err != nil {
			t.Error(err)
		}
	})
	dropped, err, log := f.logoutStep(t, gen)
	if err != nil || dropped {
		t.Fatalf("dropped=%v err=%v; stderr:\n%s", dropped, err, log)
	}
	if !strings.Contains(log, "published, kept (the wallet changed since it was published)") {
		t.Errorf("stderr:\n%s", log)
	}
	for _, keep := range []string{f.wpath, planMovingPath(f.wpath), f.wpath + ".seen.tmp"} {
		if _, serr := os.Stat(keep); serr != nil {
			t.Errorf("the refused drop removed %s: %v", keep, serr)
		}
	}
}
