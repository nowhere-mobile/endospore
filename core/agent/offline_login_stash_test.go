package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// NWP-20260903-06. The OFFLINE login path inherited the previous session's RAM stashes.
//
// WHY THIS IS A SOURCE TEST. The defect is an ABSENCE -- three disposals that handleRoamIn performs and
// handleRoamInOffline did not -- and an absence has no runtime seam to assert against: both functions take a
// live net.Conn, shell out to the roam worker, and touch process-global env. A behavioural test would have to
// reconstruct a whole login to observe a file that should NOT exist. What actually went wrong is expressible
// directly: two sibling entry points diverged on which per-session state they dispose of. So that is the
// invariant, and it is checked where it lives.
//
// WHAT SHIPPED, because the class matters more than the instance. handleRoamIn disposes of .coldlock (#123),
// the session PIN stash (#81), and the fido2 hmac env. handleRoamInOffline disposed of none of them while
// carefully disposing of others (apps.out, prefs.out, Bluetooth bonds, .relogin) -- so the omission did not
// look like an omission. Its own btwipe comment states the exact hazard that damns it: an offline login
// "restores nothing", making it "the ONE way to reach a live session ... sitting on top of whatever bonds the
// previous session left behind." That reasoning was applied to bonds and stopped there.
//
// The sharp one was .sessionpin. GET-SESSION-PIN returns whatever is stashed with NO binding to the profile
// that stashed it, and the warm armer and cold-lock arm the keyguard from it -- so an offline sign-in armed
// the new session with the PREVIOUS profile's remembered PIN. Both directions are bad: the arriving user
// cannot unlock their own session, and the departing user's PIN opens it. On a device whose entire premise is
// that profiles cannot reach each other, that is the premise.
//
// This test generalises rather than pinning the three names: whatever dotfile state handleRoamIn disposes of,
// handleRoamInOffline must dispose of too, unless it is listed below with a reason. A disposal added to the
// online path in future fails here until the offline path is considered.

// dotStash matches the per-session RAM stash paths, e.g. filepath.Join(dest, ".sessionpin").
var dotStash = regexp.MustCompile(`filepath\.Join\(dest, "(\.[a-z0-9]+)"\)`)

// offlineExempt lists online-path stashes the offline path legitimately need not touch. Each needs a reason;
// an empty map is the honest default, and anything added here should be arguable in review.
var offlineExempt = map[string]string{}

// stashesDisposed returns the dotfile stashes a function body disposes of. "Disposes" means os.Remove on the
// path, since that is the idiom both paths use; the two non-Remove disposals (stashSessionPIN(dest, "") and
// loadFido2HmacEnv) are mapped onto their stash names so the comparison is like-for-like.
func stashesDisposed(body []string) map[string]bool {
	out := map[string]bool{}
	for _, l := range body {
		if strings.Contains(l, "os.Remove(") {
			for _, m := range dotStash.FindAllStringSubmatch(l, -1) {
				out[m[1]] = true
			}
		}
		// stashSessionPIN(dest, "") is the PIN stash's remove -- see stashSessionPIN in pin.go, where an
		// empty pin unlinks the file. Only the EMPTY form is a disposal; stashing a real PIN is the opposite.
		if strings.Contains(l, `stashSessionPIN(dest, "")`) {
			out[".sessionpin"] = true
		}
		// loadFido2HmacEnv reconciles NOWHERE_FIDO2_HMAC with the file, unsetting it when the file is absent.
		// It counts as disposal ONLY next to a remove of the file -- on its own it ADOPTS an inherited hmac,
		// which is the trap this slice had to reason through, so encoding it here keeps that reasoning.
		if strings.Contains(l, "loadFido2HmacEnv(dest)") {
			out[".fido2hmac.env"] = true
		}
		// NWP-20260915-12: the WALLET is a per-session stash too, and it is the one nothing ever removed. It
		// is not a dotfile, so dotStash cannot see it -- but it lives in the same boot-lifetime tmpfs, it is
		// inherited the same way, and what it carries is BEARER INSTRUMENTS the gateway cannot re-issue. A
		// profile that signs in after another must not find itself holding someone else's credit.
		// NWP-20261010-04: through removeWallet, which takes the wallet lock first -- a bare os.Remove could
		// land inside a flush's load-spend-save and be undone by its save.
		if strings.Contains(l, "removeWallet(walletPathFor(dest))") {
			out["wallet.json"] = true
		}
	}
	return out
}

func TestOfflineLoginDisposesInheritedSessionState(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)

	online := stashesDisposed(stripComments(funcBody(t, src, "handleRoamIn")))
	offline := stashesDisposed(stripComments(funcBody(t, src, "handleRoamInOffline")))

	if len(online) == 0 {
		t.Fatal("handleRoamIn disposes of no stash at all -- this test is looking at the wrong function")
	}

	for stash := range online {
		if offline[stash] {
			continue
		}
		if why, ok := offlineExempt[stash]; ok {
			t.Logf("exempt: %s (%s)", stash, why)
			continue
		}
		t.Errorf("handleRoamIn disposes of %s but handleRoamInOffline does not.\n"+
			"  An offline login restores nothing, so it is the path MOST likely to inherit the previous\n"+
			"  session's state, not least (NWP-20260903-06). Dispose of it there too, or add it to\n"+
			"  offlineExempt with a reason that survives review.", stash)
	}

	// The PIN is called out on its own because it is a CREDENTIAL and its inheritance crosses profiles:
	// GET-SESSION-PIN is not profile-bound, so a stale stash arms the next session's keyguard. If the loop
	// above is ever weakened, this must still fail.
	if !offline[".sessionpin"] {
		t.Error("handleRoamInOffline must clear the session PIN stash: GET-SESSION-PIN is not bound to the " +
			"profile that stashed it, so an inherited PIN arms the NEXT profile's keyguard with the PREVIOUS " +
			"profile's credential (NWP-20260903-06)")
	}
	// And the hmac file must be REMOVED, not merely reloaded -- loadFido2HmacEnv adopts an existing file.
	if offline[".fido2hmac.env"] && !offline[".fido2hmac"] {
		t.Error("handleRoamInOffline calls loadFido2HmacEnv without removing .fido2hmac first: that ADOPTS " +
			"the previous session's key assertion instead of dropping it (NWP-20260903-06)")
	}
	// NWP-20260915-12: the wallet, called out on its own for the same reason the PIN is -- it crosses
	// profiles and it is worth MONEY. The login restore cannot stand in for this: it returns early, leaving
	// the file exactly as it found it, whenever the ARRIVING profile has no #wallet head -- which is
	// precisely the profile that would otherwise spend someone else's blind tokens.
	for path, who := range map[string]map[string]bool{"handleRoamIn": online, "handleRoamInOffline": offline} {
		if !who["wallet.json"] {
			t.Errorf("%s does not dispose of the session wallet. Nothing else in the tree removes it and it "+
				"lives in the BOOT-lifetime state tmpfs, so the next profile to sign in runs on the previous "+
				"profile's wallet -- and blind tokens are bearer instruments the gateway cannot re-issue.", path)
		}
	}
}
