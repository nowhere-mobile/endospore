package main

import (
	"fmt"
	"net"
	"os"
	"strings"
)

// NWP-20261006-10 -- a stored profile that does not open on THIS phone signs in as a blank throwaway, and none of its
// scopes are restored.
//
// Found on 2026-10-06 by the cross-phone test of NWP-20261006-09: a profile tied to lynx's secure element, signed in on
// husky with the right name and passphrase, became a REAL session there. The decision records (2026-09-15, 2026-10-05,
// 2026-10-06) all say phone B "lands as a blank throwaway", and the code did not:
//
//   - ROAM-IN called a login real when a head EXISTS at the ref (name, passphrase) locate -- never asking whether it
//     opened. A tied profile's head exists everywhere.
//   - roamd's CE restore is described as "the login GATE", but `restore` prints "empty -> nothing" and exits 0 when no
//     slot opens, so the scope restores after it ran anyway. And the scope heads (#de, #sys, #media, #apps, #keys) are
//     keyed by deriveKey(name#scope, passphrase), not by the data key the chip guards (scope_index.go), so they
//     restored onto husky in full.
//   - Its seals then failed only for the vault (PARTIAL:vault=failed) and SUCCEEDED for every other scope: a second
//     phone overwrote the profile's scope data with its own.
//
// "Does not open" means: the head is a vault and no slot opens it with what this caller holds -- the passphrase slot,
// this phone's chip, an asserted security key. A legacy bare head (not a vault) opens by passphrase, so it is never
// locked. A 2FA vault with no key asserted never gets here: roamd answers NEEDKEY first.
//
// NWP-20261124-07 (#5 of the 2026-11-02 entry, docs/product-decisions.md): a bare head that cannot be READ -- the ref or
// its blob fails, a 403 included -- is a store failure, never "not locked" and never a throwaway. Before this a failed
// blob read answered "not locked", so a profile tied to another phone's chip restored its passphrase-keyed scopes here
// while the store blipped, and a failed ref read made a real sign-in a throwaway that never sealed. Each caller now:
//
//   - the sign-in (handleRoamIn) answers BLANK NET, the gate's retry, before anything records the sign-in;
//   - the CLI `restore` of a scope exits exitStoreUnreachable, which roamd maps to BLANK NET;
//   - `restore-app` exits exitStoreUnreachable and writes nothing;
//   - mediad serves nothing;
//   - scopeHeadMayBeCreated answers false, so no scope head is created.
//
// A definite 404 stays absence, so a genuinely absent head is still a throwaway. The answer does not depend on the
// credential: a wrong passphrase on the same failing store fails the same read.

// vaultHeadLocked reads `head` and reports whether it names a vault that `open` cannot open (locked), or could not be
// read at all (unreadable). A missing head ("") and a legacy non-vault head are neither: they keep the behaviour they
// had (a throwaway for a missing head, a passphrase open for a legacy one). A failed or panicking blob read is
// unreadable, never "not locked" (NWP-20261124-07): the caller refuses as a store failure.
func vaultHeadLocked(base, head string, open func(*vault) []byte) (locked, unreadable bool) {
	if head == "" {
		return false, false
	}
	v, err := readHeadVault(base, head)
	if err != nil {
		return false, true
	}
	return vaultLocked(v, open), false
}

// readHeadVault reads and parses the head blob. A nil vault with a nil error is a legacy (non-vault) head; any failure
// of the read -- the store, a missing blob, getHeadBlob's #116 corrupt-head refusal -- is the error.
func readHeadVault(base, head string) (v *vault, err error) {
	err = recovered(func() {
		// Q036 (NWP-20261113-12): through the head-blob cache. cacheRead re-hashes every hit, and a miss is getHeadBlob
		// with its #116 corrupt-head refusal, so a scope restore no longer refetches the vault blob the bare restore
		// cached.
		if pv, isV := parseVault(headBlobGet(base, head)); isV {
			v = pv
		}
	})
	if err != nil {
		return nil, err
	}
	return v, nil
}

// vaultLocked is vaultHeadLocked for a vault the caller has already read and parsed: no store read. A nil vault (a
// legacy head, or no head) is never locked.
func vaultLocked(v *vault, open func(*vault) []byte) bool {
	return v != nil && open(v) == nil
}

// probeStrict is refProbeStrict through the memo. A memo HIT is a read this invocation completed, so it answers with
// no request (Q036). A miss reads strictly: only a definite not-found is absent, and any other failure panics. The
// hits-only rule of refProbeMemo applies unchanged: an absence is never recorded, so an unknown name and a wrong
// passphrase make the same requests in the same order. A nil memo is plain refProbeStrict.
func (m refProbeMemo) probeStrict(base, ref string) (exists bool, val string, haveVal bool) {
	if m == nil {
		return refProbeStrict(base, ref)
	}
	if r, ok := m[ref]; ok {
		return r.exists, r.val, true
	}
	ex, v, have := refProbeStrict(base, ref)
	if ex {
		m[ref] = refProbeRead{exists: true, val: v}
	}
	return ex, v, have
}

// scopeOwnerLocked reports whether `profile` is a SCOPE ("name#suffix") whose profile's head does not open with what
// this process holds (locked): the passphrase, NOWHERE_SE_SECRET (this phone's chip, exported by roamd),
// NOWHERE_FIDO2_HMAC; or whose head could not be read (unreadable, NWP-20261124-07). The CLI `restore` refuses such a
// scope, as it refuses a deleted profile's.
func scopeOwnerLocked(base, profile, pass string) (locked, unreadable bool) {
	return scopeOwnerLockedWith(base, profile, pass, nil)
}

// scopeOwnerLockedWith is scopeOwnerLocked resolving the bare head through the restore invocation's ref memo (Q036,
// NWP-20261113-12).
func scopeOwnerLockedWith(base, profile, pass string, memo refProbeMemo) (locked, unreadable bool) {
	_, locked, unreadable = scopeOwnerHeadWith(base, profile, pass, memo)
	return locked, unreadable
}

// scopeOwnerHeadWith is scopeOwnerLockedWith that also returns the bare head it read ("" when there is none). The
// ladder is headRefWith's own with memo.probeStrict as its probe, never a copy of it: a memo hit is the read
// profileDeletedWith completed moments earlier in this invocation, so it is not read again; a miss reads strictly, so a
// failed read is unreadable and only a definite not-found is "no head" (NWP-20261124-07). A rung the memo never probed
// (the per-unit heads under NOWHERE_MULTIDEVICE=1) reads live. Not a scope: no head, neither locked nor unreadable.
func scopeOwnerHeadWith(base, profile, pass string, memo refProbeMemo) (head string, locked, unreadable bool) {
	i := strings.IndexByte(profile, '#')
	if i <= 0 {
		return "", false, false
	}
	bare := profile[:i]
	if err := recovered(func() { _, head, _ = headRefWith(base, bare, pass, memo.probeStrict) }); err != nil {
		return "", false, true
	}
	locked, unreadable = vaultHeadLocked(base, head, func(v *vault) []byte {
		return openVaultDK(v, bare, pass)
	})
	return head, locked, unreadable
}

// roamInHead is the sign-in's strict read of the bare head (NWP-20261124-07): the head ref through headRefWith's ladder
// with refProbeStrict, and, when there is a head, its blob, parsed. readable=false is a failed read of either: the
// caller answers BLANK NET. ("", nil, true) is a definite absence or a delete tombstone: the throwaway, as before. A nil
// vault with a head is a legacy head.
func roamInHead(base, name, pass, srcUnit string) (head string, v *vault, readable bool) {
	if err := recovered(func() {
		_, head, _ = headRefWith(base, name, pass, refProbeStrict)
		if head == "" && srcUnit != "" {
			// #91 slice 4b: a "restore from <device>" login has no head of its OWN yet (this device hasn't sealed);
			// the SOURCE unit's head is what it restored from, so it is a REAL session, not a throwaway -- its seal
			// must persist to THIS device's head. (The ladder above deliberately reads this device's head, not the
			// override, so the seal-side migrate/wallet paths stay on THIS device.)
			if b, ok := getRefBytesStrict(base, unitHeadRef(name, pass, srcUnit)); ok {
				head = strings.TrimSpace(string(b))
			}
		}
	}); err != nil {
		return "", nil, false
	}
	if head == "" {
		return "", nil, true
	}
	v, err := readHeadVault(base, head)
	if err != nil {
		return "", nil, false
	}
	return head, v, true
}

// roamInHeadUnreadable is the sign-in's reply when roamInHead could not read the bare head: BLANK NET, through the same
// steps as handleRoamIn's own BLANK NET arm and in its order. It runs before anything records the sign-in, so the only
// thing to undo is the park roamd kept on its OK (NWP-20261129-17). A helper, not inline, because no session exists yet
// and the failed-sign-in scrub is correct here, while handleRoamIn's success part must never schedule one (TestFailedSigninScrub_SourcePins).
func roamInHeadUnreadable(conn net.Conn, dest, name string) {
	fmt.Fprintf(os.Stderr, "[logind] roam-in BLANK NET %q (the stored head could not be read) (NWP-20261124-07)\n", name)
	putBackInPark(dest, "roam-in BLANK NET after the restore")
	fmt.Fprint(conn, "BLANK NET\n")
	scheduleFailedSigninScrub(dest) // NWP-20261027-02
	forgetSessionKeys("blank sign-in")
}
