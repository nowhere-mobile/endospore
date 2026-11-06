package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// NWP-20261127-03 (docs/backlog.md, "The sign-out renewal's login.log line keeps the profile name in cleartext until
// the next reap or boot: it is written after the reap's log scrub"): handleLogout's "logout-wallet" goroutine runs
// beside reapOrReboot, so every line it writes lands after the reap's log scrub. Those lines name only the user.
// Every planted name below is multi-word with a double quote in it, so its %q, qn, path- and query-escaped
// spellings all differ from the raw one, and each test has its own (the caches are keyed by the profile's DK).

const signoutLogNamesUID = "10"

// signoutLogNamesNone fails when any spelling of name (nameSpellings) is in out.
func signoutLogNamesNone(t *testing.T, out, name string) {
	t.Helper()
	for _, sp := range nameSpellings(name) {
		if strings.Contains(out, sp) {
			t.Errorf("the log names the profile (spelling %q):\n%s", sp, out)
		}
	}
}

// signoutLogNamesLine fails unless one line of out starts at want's prefix and holds want whole.
func signoutLogNamesLine(t *testing.T, out, want string) {
	t.Helper()
	for _, l := range strings.Split(out, "\n") {
		if strings.Contains(l, want) {
			return
		}
	}
	t.Errorf("no line holds %q:\n%s", want, out)
}

// signoutLogNamesCapSetup is a cap-mode profile with a little data stored, and the wallet w at walletPathFor(dest),
// given tokens faucet tokens when tokens > 0 and its restore proof. The pushes print the raw name; they run before
// any capture.
func signoutLogNamesCapSetup(t *testing.T, name, pass string, w *Wallet, tokens int) (dest string) {
	t.Helper()
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	blobCache = nil
	old := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = old; capReadCache = map[string]capEntry{} })
	freeRenewedThrough = map[string]int64{}
	dest = t.TempDir()
	wp := walletPathFor(dest)
	t.Setenv("NOWHERE_STATE", dest)
	t.Setenv("NOWHERE_WALLET", wp)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(10)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wp, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("sign-out log names"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", name, pass, src)
	if tokens > 0 {
		w.Tokens = toks[:tokens]
	}
	if err := saveWallet(wp, w); err != nil {
		t.Fatal(err)
	}
	provenWallet(t, wp)
	return dest
}

// signoutLogNamesRun runs renewAtSignOut for the session at dest, as handleLogout's goroutine does, and returns what
// it logged.
func signoutLogNamesRun(t *testing.T, dest, name, pass string) string {
	t.Helper()
	return captureStderr(t, func() {
		renewAtSignOut(dest, name, pass, nil, walletGeneration(walletPathFor(dest)), signoutLogNamesUID)
	})
}

// N1 (the row's CLOSES WHEN): a free-tier profile over its allowance signs out. The gateway answers the free lease
// 402, billing's error names the profile, and neither the renewal's line nor the wallet step's names it.
func TestSignoutLogNames_TheFreeTier402LineNamesOnlyTheUser(t *testing.T) {
	name, pass := `Planted "Q1" Name`, "sign out log names one"
	dest := signoutLogNamesCapSetup(t, name, pass, &Wallet{}, 0)
	capStoreLeaseStatus = func(r leaseReq) (int, string) {
		if r.Free {
			return 402, `{"error":"free tier over quota"}`
		}
		return 0, ""
	}
	out := signoutLogNamesRun(t, dest, name, pass)
	signoutLogNamesLine(t, out, "[logind] signout-renewal user "+signoutLogNamesUID+
		`: error (pay-rent: free tier unavailable for "<name>" (HTTP 402`)
	signoutLogNamesNone(t, out, name)

	wp := walletPathFor(dest)
	var err error
	wout := captureStderr(t, func() {
		_, err = sealLogoutWalletAndDrop(dest, name, pass, nil, walletGeneration(wp), signoutLogNamesUID)
	})
	if !strings.Contains(wout, "[logind] logout wallet user "+signoutLogNamesUID+": ") {
		t.Errorf("the wallet step logged no line for user %s (err %v):\n%s", signoutLogNamesUID, err, wout)
	}
	signoutLogNamesNone(t, wout, name)
}

// N2: every other branch of renewAtSignOut, the recover's two splits included, names only the user.
func TestSignoutLogNames_EveryOtherBranchNamesOnlyTheUser(t *testing.T) {
	head := "[logind] signout-renewal user " + signoutLogNamesUID
	deadGW := func(t *testing.T) string {
		t.Setenv("GATEWAY_URL", "http://127.0.0.1:1")
		return t.TempDir()
	}
	engaged := func(t *testing.T, f func()) {
		signOutRenewalEngaged = f
		t.Cleanup(func() { signOutRenewalEngaged = nil })
	}
	for _, c := range []struct {
		sub, name, want string
		setup           func(t *testing.T, name, pass string) string
	}{
		{"skipped", `Planted "Q2" Name`, ": skipped -- an unsaved sign-out or restart is in progress",
			func(t *testing.T, _, _ string) string {
				dest := deadGW(t)
				if !holdRentForExit() {
					t.Fatal("holdRentForExit: the rent gate is already held")
				}
				t.Cleanup(releaseRent)
				return dest
			}},
		{"never-engaged", `Planted "Q3" Name`, ": skipped (never engaged the managed store)",
			func(t *testing.T, _, _ string) string {
				dest := deadGW(t)
				t.Setenv("S3_ACCESS_KEY", "x")
				if err := saveWallet(walletPathFor(dest), &Wallet{}); err != nil {
					t.Fatal(err)
				}
				return dest
			}},
		{"wallet-load-error", `Planted "Q4" Name`, ": error (",
			func(t *testing.T, _, _ string) string {
				dest := deadGW(t)
				if err := os.WriteFile(walletPathFor(dest), []byte("{not json"), 0o600); err != nil {
					t.Fatal(err)
				}
				return dest
			}},
		{"already-renewed", `Planted "Q5" Name`, ": skipped (already renewed this epoch, or nothing stored)",
			func(t *testing.T, name, pass string) string {
				return signoutLogNamesCapSetup(t, name, pass, &Wallet{PaidThrough: 92, RenewedEpoch: 42}, 5)
			}},
		{"paid", `Planted "Q6" Name`, ": paid through epoch 46 (1 token(s) spent)",
			func(t *testing.T, name, pass string) string {
				return signoutLogNamesCapSetup(t, name, pass, &Wallet{}, 5)
			}},
		{"renewed", `Planted "Q7" Name`, ": renewed",
			func(t *testing.T, name, pass string) string {
				dest := signoutLogNamesCapSetup(t, name, pass, &Wallet{}, 0)
				capStoreLeaseStatus = func(r leaseReq) (int, string) {
					if r.Free {
						return 200, ""
					}
					return 0, ""
				}
				return dest
			}},
		{"recover-store-unreachable", `Planted "Q8" Name`, ` -> skipped: store read FAILED after retries (` + errStoreUnreachable.Error() + `: GET for "<name>")`,
			func(t *testing.T, name, _ string) string {
				dest := deadGW(t)
				engaged(t, func() { panic(fmt.Errorf("%w: GET for %q", errStoreUnreachable, name)) })
				return dest
			}},
		{"recover-other", `Planted "Q9" Name`, " -> skipped: unexpected failure (details withheld)",
			func(t *testing.T, name, _ string) string {
				dest := deadGW(t)
				engaged(t, func() { panic("boom " + name) })
				return dest
			}},
	} {
		t.Run(c.sub, func(t *testing.T) {
			pass := "sign out log names " + c.sub
			dest := c.setup(t, c.name, pass)
			out := signoutLogNamesRun(t, dest, c.name, pass)
			signoutLogNamesLine(t, out, head+c.want)
			signoutLogNamesNone(t, out, c.name)
		})
	}
}

// N3: the wallet step's error line, with an error that names the profile, prints <name> in its place.
func TestSignoutLogNames_TheWalletStepErrorRedactsTheName(t *testing.T) {
	f := walletFailSetup(t)
	f.session(t)
	logoutHooks(t, func() { panic(errors.New("read of " + strconv.Quote(walletFailName) + " failed")) }, nil)
	_, err, log := f.logoutStep(t, f.gen())
	if err == nil {
		t.Fatalf("the wallet step returned no error from a panicking capture hook:\n%s", log)
	}
	signoutLogNamesLine(t, log, "[logind] logout wallet user "+logoutUID+`: NOT published, kept (panic: read of "<name>" failed)`)
	signoutLogNamesNone(t, log, walletFailName)
}

// N4: a sign-out renewal whose renewal batches do not all land prints payRentGenRule's short-batch line with no
// spelling of the name; the same branch under the periodic rule still prints logProfile(name).
func TestSignoutLogNames_PayRentLinesUnderTheSignOutRule(t *testing.T) {
	short := ": 1 of 3 renewal batches did not land"
	run := func(t *testing.T, name string, pay func(f *renewBatchFixture) (leaseInfo, bool, error)) (*renewBatchFixture, string) {
		f := renewBatchSetup(t, name, 2)
		n := len(renewBatchFootprint(t, f))
		leaseBatchRefs = (n + 2) / 3
		f.failAt[1] = true
		var paid bool
		var err error
		out := captureStderr(t, func() { _, paid, err = pay(f) })
		if err != nil || !paid {
			t.Fatalf("paid=%v err=%v, want a paid renewal despite the short batch:\n%s", paid, err, out)
		}
		return f, out
	}
	t.Run("sign-out", func(t *testing.T) {
		name := `Planted "Q4a" Name`
		_, out := run(t, name, func(f *renewBatchFixture) (leaseInfo, bool, error) {
			return payRentGenSignOut(f.gw, f.base, f.name, f.p2, f.wpath, nil, walletGeneration(f.wpath))
		})
		signoutLogNamesLine(t, out, "[agent] pay-rent (sign-out renewal)"+short)
		signoutLogNamesNone(t, out, name)
	})
	t.Run("periodic", func(t *testing.T) {
		name := `Planted "Q4b" Name`
		_, out := run(t, name, func(f *renewBatchFixture) (leaseInfo, bool, error) {
			return payRentGen(f.gw, f.base, f.name, f.p2, f.wpath, nil, walletGeneration(f.wpath))
		})
		signoutLogNamesLine(t, out, "[agent] pay-rent "+logProfile(name)+short)
	})
	t.Run("error-text", func(t *testing.T) {
		name := `Planted "Q4c" Name`
		s := "the wallet head of " + strconv.Quote(name) + " and " + name
		signoutLogNamesNone(t, payRentErrText(renewSignOut, name, s), name)
		if got := payRentErrText(renewPeriodic, name, s); got != s {
			t.Errorf("payRentErrText on the periodic rule = %q, want %q unchanged", got, s)
		}
	})
}
