package main

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
)

// NWP-20260919-09: REFUSE A DESTINATION WHERE THIS PROFILE IS ALREADY LIVE.
//
// profile-export-restore.md §2 rests on "the destination is always empty", reasoned from "a device points
// at one store at a time", and §3 retires FOUR safety properties on that basis: collision policy, the
// restore-in-progress sentinel, head-publication order, and "restoring over a newer version is a silent
// rollback". ⚠⚠ THAT PREMISE IS ABOUT WHERE THE USER AIMS THE RESTORE, NOT AN ENFORCED PROPERTY -- and
// NWP-20260919-04 makes it worse, because a destination PICKER makes the most dangerous target (the store
// the device is already on) also the most natural one to choose.
//
// ⚠ A RESTORE REACHES NO DEVICE-SIDE GUARD. It is a raw object copy: pushProfile's restore-receipt gate and
// the vault's monotonic Version both live in the agent's SEAL path, and at the store layer a ref is an
// ordinary object whose PUT is unconditional. A blob is protected by the STORE: its write cap is bound
// (NWP-20261009-02, docs/store-write-authorization.md R1) -- create-only, so an overwrite of an existing blob
// is refused, and content-bound, so nobody can get a cap that writes other bytes under a blob's key. THE REFS
// ARE NOT: a head is overwritten by every seal, so its cap can be neither. Restoring over a live profile
// overwrites its heads with the export's older values and orphans everything sealed since, in one step,
// with nothing on the path saying a word.
//
// ⚠⚠ "NON-EMPTY DESTINATION" MEANS THIS PROFILE'S REFS, NOT THE BUCKET. A managed store holds every
// customer's objects; refusing because the bucket has other data in it would make this guard useless and
// would be refused around within a week. The only question that matters is whether THESE refs already
// resolve to something else here.
//
// ✅ AND THE ROLLBACK DIRECTION IS DETECTABLE WITHOUT CREDENTIALS, which is what makes the refusal
// actionable rather than merely cautious: the vault head blob is `vaultMagic` + PLAINTEXT JSON, so
// parseVault reads its monotonic `Version` with no DK. A destination whose head is NEWER than the export's
// is the silent rollback §3 names; an OLDER one is a stale destination being refreshed. Both are refused --
// only the operator knows which they meant -- but the report says which it is.

// PreflightVerdict is one ref's answer at the destination.
type PreflightVerdict struct {
	Key string
	// State is one of: "absent" (safe: a definite 404), "same" (already restored, safe), "differs" (REFUSE),
	// "tombstone" (present but empty -- the profile was deleted here), "unreadable" (REFUSE: the destination
	// did not answer the read, so nothing is known about what it holds).
	State string
	// Reason is the error class of an unreadable read: a fixed vocabulary, never the error text, because a
	// transport error carries the presigned URL and its query string is a live credential.
	Reason string
	// DestVersion/SrcVersion are the monotonic vault versions when both heads could be read as vaults.
	// Zero means "not a vault head, or unreadable" -- absence of a version is never treated as agreement.
	DestVersion uint64
	SrcVersion  uint64
}

// PreflightReport is the whole answer. Safe() is the only thing a caller should branch on.
type PreflightReport struct {
	Verdicts []PreflightVerdict
	// Blocking counts the refs that would be overwritten with a different value, or whose current value
	// could not be read.
	Blocking int
	// Tombstoned counts refs the destination holds as deleted. Not blocking on its own -- restoring over
	// a delete is a legitimate thing to want -- but named, because it is invisible otherwise.
	Tombstoned int
}

func (p *PreflightReport) Safe() bool { return p.Blocking == 0 }

// preflightRestore asks, for every ref the manifest names, what the destination already holds.
//
// It reads ONLY refs and (when a head differs) the two head blobs. No credentials, no writes. A ref the
// destination does not answer is "unreadable" and blocks: see preflightReadRef.
func preflightRestore(base string, m *ExportManifest) *PreflightReport {
	rep := &PreflightReport{}
	if m == nil {
		return rep
	}
	for _, r := range m.Refs {
		name, ok := strings.CutPrefix(r.Key, "ref/")
		if !ok {
			continue
		}
		v := PreflightVerdict{Key: r.Key}
		b, present, err := preflightReadRef(base, name)
		got := strings.TrimSpace(string(b))
		switch {
		case err != nil:
			v.State = "unreadable"
			v.Reason = preflightReadClass(err)
			rep.Blocking++ // an unreadable head blocks: it is never evidence that the destination is empty
		case !present:
			v.State = "absent"
		case got == "":
			// ⚠ ABSENT AND TOMBSTONED ARE DIFFERENT STATES AND THE CODE TURNS ON THE DIFFERENCE ELSEWHERE:
			// a tombstone is a ref that EXISTS holding "", a 404 is a ref that does not. The separation matters
			// here -- "nothing here" invites the copy, while "deleted here" is a fact the operator should see
			// before overwriting it.
			v.State = "tombstone"
			rep.Tombstoned++
		case got == r.Value:
			// Byte-identical: either this copy already ran, or both sides descend from the same seal.
			// Writing it again is a no-op, so this must NOT block -- a re-run after a partial transfer is
			// exactly the case an operator needs to be able to repeat.
			v.State = "same"
		default:
			v.State = "differs"
			rep.Blocking++
			// Both heads are plaintext vault JSON when they are vault heads, so the direction is readable
			// with no key. Failure to read either one leaves the version at zero and changes nothing about
			// the refusal -- an unreadable head is never evidence of agreement.
			v.DestVersion = headVersionOf(base, got)
			v.SrcVersion = headVersionOf(base, r.Value)
		}
		rep.Verdicts = append(rep.Verdicts, v)
	}
	return rep
}

// preflightReadRef reads one destination ref strictly: (bytes, true, nil) present -- an empty object is a
// tombstone --, (nil, false, nil) a definite 404, and an error for anything else. One read answers both the
// value and the presence question.
//
// ⚠ getRef/refExists are NOT used here: in cap mode both reach capGet, which reads a 403 on a FRESH cap as a
// definitive miss (the hide-existence rule blind login needs), so a destination whose store answered 403 to
// every presigned GET (a cap minted under rotated credentials, a skewed clock) read as empty and SAFE, and the
// copy overwrote the live heads. getRefBytesStrict is capGetStrict in cap mode (NWP-20261013-20).
//
// ACCEPTED CONSEQUENCE: on a store that hides existence behind a 403, a cap-mode preflight now refuses an EMPTY
// destination as unreadable. That is fail-closed, as the wallet restore chose. Blind login keeps capGet.
func preflightReadRef(base, name string) (b []byte, present bool, err error) {
	err = recovered(func() { b, present = getRefBytesStrict(base, name) })
	return b, present, err
}

var preflightStatusRE = regexp.MustCompile(`status (\d{3})`)

// preflightReadClass names why a read failed from a fixed vocabulary. The error text is never echoed: a
// transport error carries the presigned URL.
func preflightReadClass(err error) string {
	msg := err.Error()
	if strings.Contains(msg, "-> 403") {
		return "403 Forbidden on a freshly fetched read cap"
	}
	if m := preflightStatusRE.FindStringSubmatch(msg); m != nil {
		return "HTTP status " + m[1]
	}
	if errors.Is(err, errStoreUnreachable) {
		return "store unreachable after retries"
	}
	return "read failed"
}

// headVersionOf reads a head blob and returns its monotonic vault Version, or 0 if it is not a readable
// vault. Zero is "unknown", never "version zero". A read the store does not answer is also 0 (NWP-20261120-20):
// getBlobSoft panics on a transport failure in S3 and cap mode, and the CLI arm has no recover, so the panic
// used to lose the whole report, the rollback verdict included.
func headVersionOf(base, blobHash string) uint64 {
	if len(blobHash) != 64 {
		return 0
	}
	var b []byte
	var ok bool
	if err := recovered(func() { b, ok = getBlobSoft(base, blobHash) }); err != nil || !ok {
		return 0
	}
	v, ok := parseVault(b)
	if !ok {
		return 0
	}
	return v.Version
}

// summary renders the report. It always prints the counts, so a pass is auditable rather than merely green.
func (p *PreflightReport) summary() string {
	var b strings.Builder
	n := map[string]int{}
	for _, v := range p.Verdicts {
		n[v.State]++
	}
	fmt.Fprintf(&b, "destination holds: %d absent, %d identical, %d tombstoned, %d DIFFERENT, %d UNREADABLE (of %d refs)\n",
		n["absent"], n["same"], n["tombstone"], n["differs"], n["unreadable"], len(p.Verdicts))
	for _, v := range p.Verdicts {
		switch v.State {
		case "differs":
			fmt.Fprintf(&b, "  DIFFERS   %s\n", v.Key)
			switch {
			case v.DestVersion > v.SrcVersion && v.SrcVersion > 0:
				fmt.Fprintf(&b, "            destination head is version %d, the export is version %d -- "+
					"⚠ WRITING THIS WOULD ROLL THE PROFILE BACK by %d version(s) and orphan everything "+
					"sealed since.\n", v.DestVersion, v.SrcVersion, v.DestVersion-v.SrcVersion)
			case v.SrcVersion > v.DestVersion && v.DestVersion > 0:
				fmt.Fprintf(&b, "            destination head is version %d, the export is version %d -- "+
					"the destination is STALE and this copy would move it forward.\n",
					v.DestVersion, v.SrcVersion)
			default:
				fmt.Fprintf(&b, "            versions could not be compared (dest=%d src=%d, 0 = unreadable) "+
					"-- refusing anyway: an unreadable head is not agreement.\n", v.DestVersion, v.SrcVersion)
			}
		case "unreadable":
			fmt.Fprintf(&b, "  UNREADABLE %s -- the destination did not answer this read (%s); refusing: an unreadable "+
				"head is never evidence that it is empty\n", v.Key, v.Reason)
		case "tombstone":
			fmt.Fprintf(&b, "  TOMBSTONE %s (deleted here -- restoring over a delete is allowed, but say so)\n", v.Key)
		}
	}
	return b.String()
}
