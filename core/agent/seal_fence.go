package main

// Publish fence (#144) -- the invariant that makes "delete" actually mean deleted.
//
// THE PROBLEM. deleteProfile tombstones every scope ref and VERIFIES each reads empty. That verification is
// honest at the instant it runs, and worthless a second later, because a seal already in flight publishes
// its pointers at the END of a run that began minutes earlier:
//
//	pushProfile samples the head        (main.go, `head := getRef(base, ref)`)
//	    ... walk + chunk + upload, MINUTES ...
//	capFlush "PUT the pointers LAST"    (main.go, the deferred flush)
//
// Nothing between those two points re-reads the head. A delete landing in the gap is verified empty and then
// silently overwritten -- and the seal runs in roamd, a SEPARATE PROCESS, so no in-process mutex can order
// them. Three confirmed P0s live in that gap:
//
//	a) the vault scope republishes the bare head AND the recovery ref. profileDeleted() then reads false,
//	   which disables the restore gate (#19/#139), the heal-at-refusal (#687) and createVault's purge (#142)
//	   all at once -- every safety net built for a half-delete, switched off by the same write.
//	b) the tombstone guard in pushProfile is gated on `!strings.Contains(profile, "#")`, so #de / #media /
//	   #sys / #apps / #keys have NO tombstone check at all and re-create their ref from an empty head.
//	c) the delete's OWN teardown re-seals #keys: cleanUserStorage -> CLEAN-STORAGE -> keystore_push, and the
//	   SKIP-REAPING clobber guard is `op == "out"`-only. Deterministic, not a race, and it fires minutes
//	   AFTER handleDelete replied OK -- so no entry-time guard can ever reach it.
//
// WHY NOT A BUSY CHECK. The obvious fix -- make DELETE refuse while a seal runs -- cannot work. The guard
// would be read at push start and the pointer is written at flush time, so a read-time condition loses by
// construction; (c) is not even in flight when DELETE is called. It also has no way to see a periodic seal:
// syncLoop only READS sealInFlight, and nothing about a seal holds sessionMu. Fence the PUBLISH instead.
//
// THE MECHANISM. A delete ARMS a marker for every ref key it is about to tombstone, BEFORE the first
// tombstone lands. Every point that publishes a pointer -- putRef directly, and capFlush's buffered batch --
// re-checks the marker at the moment of writing and refuses. A seal that started before the delete therefore
// still refuses at the end, which is the only ordering that is safe without cross-process locking.
//
// THE SEQUENCE COUNTER closes the recreate case. createVault LIFTS the fence for a name being re-created
// (otherwise a legitimate new profile could never publish), and a lift bumps the same counter an arm does.
// A push samples the counter at its start and refuses if it moved -- so an in-flight push cannot publish the
// OLD profile's vault over the NEW head at the same ref, which would be #142 again with the new DK destroyed.
// Arm and lift must therefore ALWAYS bump together; changing one without the other reopens that hole.
// The counter fails closed like the markers (NWP-20261112-09): a `.seq` that exists but cannot be read, or
// holds anything but a decimal integer, reads -1, which every publish check treats as "the fence moved". A
// bump replaces `.seq` by temp + rename, so no reader ever sees it empty, and a lift that cannot bump removes
// nothing: a lift can never clear a marker without moving the sequence.
//
// LIFETIME is per-boot: the markers live in the RAM state tmpfs (NOWHERE_STATE), so a power-off clears them
// along with the daemon, roamd and any push they were fencing -- the three things that could have raced. Off
// device (host CLI, unit tests) NOWHERE_STATE is unset, sealFenceDir() is "", and the whole mechanism is
// INERT, exactly like restore_receipt.go's gate.
//
// FAIL CLOSED. A fence we cannot READ is treated as fencing. "I could not tell" and "not deleted" must never
// render the same -- that conflation is its own recurring bug class here (#93, #103, and the cap-403 case).
// Arming is best-effort by contrast: if it fails the delete still proceeds and says so loudly, because the
// tombstone-and-verify path is unchanged and the fence is defence in depth, not the primary mechanism.
//
// WHAT IT DOES NOT COVER. The fence guards the moment this device PUTs. It cannot recall a write already on
// the wire, nor revoke an issued write cap, and the gateway leases purely from the ledger with no tombstone
// awareness -- so one round trip of exposure remains. Narrowing that to zero needs a gateway-side refusal at
// the PUT path, which is #143's fencing clause. This is the client-side half, and it is the ONLY half a
// self-hosted (BYO-store) device will ever have.

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

// sealFenceDir is where per-ref publish-fence markers live, or "" when the fence is not in use (no roaming
// state dir -> host CLI / tests -> inert, behaviour unchanged).
func sealFenceDir() string {
	st := os.Getenv("NOWHERE_STATE")
	if st == "" {
		return ""
	}
	return filepath.Join(st, "seal-fence")
}

// fenceRefOK reports whether r may name a marker file. Every legitimate fence ref -- profileRefV2/Legacy,
// unitHeadRef, accountDirRef, recoveryRef, an export key's name -- is a 64-char lowercase hex digest, and
// isContentHash is already the gate this codebase puts on store-supplied refs (repoint.go, getHeadBlob).
// Anything else NEVER reaches the filesystem: v.RecoveryRef is a plaintext field of a blob the STORE served,
// and filepath.Join cleans "..", so "../../nowhere.conf" would otherwise write (arm), remove (lift) or
// stat (blocks) /data/nowhere/nowhere.conf -- de-enrollment (#144; docs/backlog.md §H, NWP-20261011-09).
func fenceRefOK(r string) bool { return isContentHash(r) }

// sealFenceSeqName is the counter file inside sealFenceDir. Refs are hex sha256, so a leading dot cannot
// collide with one.
const sealFenceSeqName = ".seq"

// sealFenceSeqTmpName is the bump's temp file, renamed over sealFenceSeqName (bumpSealFenceSeqLocked).
const sealFenceSeqTmpName = ".seq.tmp"

var sealFenceMu sync.Mutex

// pushFenceSeq / pushFenceSampled are sampled once at the top of pushProfile. In the DAEMON they stay unset,
// so the daemon's own putRef callers (createVault, migrateVault, rotateVault) are governed by the per-ref
// markers alone -- which is correct: those are one-shot writes, not long-running publishes, and createVault
// lifts before it writes. Do not "fix" that asymmetry; it is the point.
var pushFenceSeq int64
var pushFenceSampled bool

// sealFenceHit records that a publish was actually refused, so the `push` verb can exit exitSealRefused
// rather than reporting success. Reset per push alongside sealRefused.
//
// ⚠ BRACKET-INTERNAL (NWP-20261009-07). Outside the `push` process, which runs one bracket, a caller reads
// its capWrite's capVerdict.FenceHit: a bracket queued behind it resets this the moment its own ends.
// TestBracketVerdictGlobalsAreReadOnlyInsideABracket names every place allowed to touch it.
// Guard reads and writes with sealExpectMu (NWP-20261011-79; docs/backlog.md §D).
// The push verb reads after pushProfile returns, with no concurrent writer.
// If both locks are needed, take sealExpectMu inside capWriteMu. This fixes the
// data race, not refusal attribution from direct writers outside a bracket.
var sealFenceHit bool

// sealFenceSeqLocked reads `.seq` in d. 0 only for a definite "does not exist" (of the file or of the fence
// dir); the counter when it holds a non-negative decimal integer; -1 for anything else -- a read error other
// than "does not exist" (EIO, a directory in its place) or content that does not parse (empty, garbled,
// overflowing). -1 is never a value a bump writes, so it cannot be mistaken for any sampled sequence.
func sealFenceSeqLocked(d string) int64 {
	b, err := os.ReadFile(filepath.Join(d, sealFenceSeqName))
	if errors.Is(err, fs.ErrNotExist) {
		return 0
	}
	if err != nil {
		return -1 // unreadable: FAIL CLOSED
	}
	s := strings.TrimSpace(string(b))
	if s == "" || strings.Trim(s, "0123456789") != "" {
		return -1 // not a decimal integer: FAIL CLOSED
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return -1 // overflow: FAIL CLOSED
	}
	return n
}

// sealFenceSeq reads the arm/lift counter: 0 when the fence is disabled or `.seq` definitely does not exist
// (nothing armed this boot), -1 when it could not be read (sealFenceSeqLocked), which every check treats as
// "the fence moved".
func sealFenceSeq() int64 {
	d := sealFenceDir()
	if d == "" {
		return 0
	}
	sealFenceMu.Lock()
	defer sealFenceMu.Unlock()
	return sealFenceSeqLocked(d)
}

// bumpSealFenceSeqLocked advances the counter by one. It writes `.seq.tmp` and renames it over `.seq`, so a
// reader sees the old value or the new one, never an empty or torn file, and the temp is removed on failure
// (writeAtomic). A counter that reads -1 is not advanced: the error is returned and nothing is written.
func bumpSealFenceSeqLocked(d string) error {
	cur := sealFenceSeqLocked(d)
	if cur < 0 {
		return errors.New("fence sequence unreadable: not advanced")
	}
	return writeAtomic(filepath.Join(d, sealFenceSeqTmpName), filepath.Join(d, sealFenceSeqName), []byte(strconv.FormatInt(cur+1, 10)+"\n"))
}

// armSealFence marks every ref in refs as un-publishable and bumps the sequence. Call it BEFORE the first
// tombstone of a delete: a fence armed after the purge leaves exactly the window it exists to close.
// Returns false if the markers could not be written -- the caller should say so loudly and carry on, since
// the tombstone-and-verify path is unaffected. It also returns false when a ref was refused because it is not
// a content hash (fenceRefOK): nothing is written for it, the rest are still armed, and the one stderr line
// carries a count but never the string, which is store-controlled. A sequence that could not be bumped also
// returns false; the markers already written stay, and they block by themselves.
func armSealFence(refs []string) bool {
	d := sealFenceDir()
	if d == "" {
		return true // inert off-device
	}
	sealFenceMu.Lock()
	defer sealFenceMu.Unlock()
	if err := os.MkdirAll(d, 0o700); err != nil {
		return false
	}
	ok := true
	refused := 0
	for _, r := range refs {
		if r == "" {
			continue
		}
		if !fenceRefOK(r) {
			refused++
			ok = false
			continue
		}
		if os.WriteFile(filepath.Join(d, r), []byte("1\n"), 0o600) != nil {
			ok = false
		}
	}
	if refused > 0 {
		fmt.Fprintf(os.Stderr, "[agent] fence: %d ref(s) that are not content hashes were refused by the fence -- nothing was written for them (#144)\n", refused)
	}
	if bumpSealFenceSeqLocked(d) != nil {
		ok = false
	}
	return ok
}

// liftSealFence clears the markers for refs -- createVault re-creating a deleted name, which must be able to
// publish. It bumps the sequence ONLY when at least one marker exists, so an ordinary create cannot
// spuriously refuse an unrelated in-flight seal; when it does bump, any push that sampled an earlier
// sequence refuses, which is what stops the old profile's vault landing on the new head.
//
// ORDER (NWP-20261112-09): the bump comes FIRST and the markers are removed only after it succeeded. A bump
// that fails removes nothing and returns false, so the markers go on refusing every publish of these refs:
// a lift can never clear a marker without moving the sequence. A marker whose stat fails for any reason but
// "does not exist" counts as present, as sealFenceBlocks counts it as fencing. Nothing to lift returns true.
func liftSealFence(refs []string) bool {
	d := sealFenceDir()
	if d == "" {
		return true
	}
	sealFenceMu.Lock()
	defer sealFenceMu.Unlock()
	var present []string
	for _, r := range refs {
		if r == "" {
			continue
		}
		if !fenceRefOK(r) {
			continue // the arm refused it, so it was never a marker: nothing to lift and nothing to say
		}
		if _, err := os.Lstat(filepath.Join(d, r)); !errors.Is(err, fs.ErrNotExist) {
			present = append(present, r)
		}
	}
	if len(present) == 0 {
		return true
	}
	if bumpSealFenceSeqLocked(d) != nil {
		return false
	}
	removeSealFenceMarkersLocked(d, present)
	return true
}

// removeSealFenceMarkersLocked removes each marker in refs from d. One that cannot be removed stays and blocks.
func removeSealFenceMarkersLocked(d string, refs []string) {
	for _, r := range refs {
		os.Remove(filepath.Join(d, r))
	}
}

// sealFenceBlocks reports whether ref is fenced. FAIL CLOSED: a stat error that is not "does not exist"
// (an unreadable or non-directory fence dir) counts as fenced, because we cannot prove it is safe to publish.
// A ref that is not a content hash is never fenced and is never stat-ed: the arm refuses it, so it cannot be a
// publish key the fence governs, and a stat of it would read outside the fence dir (fenceRefOK). So under an
// unreadable dir such a key now reads as not fenced; no production publish key has that shape, and the
// sequence check in sealFencePublishBlocked still applies to every publish.
func sealFenceBlocks(ref string) bool {
	d := sealFenceDir()
	if d == "" || ref == "" {
		return false
	}
	if !fenceRefOK(ref) {
		return false
	}
	_, err := os.Stat(filepath.Join(d, ref))
	if err == nil {
		return true
	}
	return !os.IsNotExist(err)
}

// sealFencePublishBlocked is the check every publish point makes at the moment of writing: this ref is
// fenced, OR the fence moved (arm or lift) since this push sampled it. storeKey may be a bare ref or the
// "ref/<hash>" store key form used by putRef and the capFlush batch. A sequence that reads -1 now, or read -1
// when the push sampled it, blocks: an unreadable counter cannot prove the fence did not move.
func sealFencePublishBlocked(storeKey string) bool {
	ref := strings.TrimPrefix(storeKey, "ref/")
	if sealFenceBlocks(ref) {
		return true
	}
	if !pushFenceSampled {
		return false
	}
	cur := sealFenceSeq()
	if cur < 0 || pushFenceSeq < 0 {
		return true
	}
	return cur != pushFenceSeq
}

// noteSealFenceRefusal records the refusal and explains it once, in the vocabulary the rest of the seal
// guards use (#111: a refusal is never reported as success).
func noteSealFenceRefusal(what, storeKey string) {
	sealExpectMu.Lock()
	sealFenceHit = true
	sealExpectMu.Unlock()
	ref := strings.TrimPrefix(storeKey, "ref/")
	short := ref
	if len(short) > 12 {
		short = short[:12]
	}
	fmt.Printf("%s: PUBLISH REFUSED for ref %s -- this profile was DELETED while the seal was in flight; "+
		"writing this pointer would resurrect it (#144). Nothing was published for this ref.\n", what, short)
}

// sealFenceRefKeys returns every store ref key a delete of (name, pass) covers -- both KDF generations of
// every scope, plus this device's per-unit heads when #91 multi-device is on. The recovery ref is NOT here:
// it is only reachable by parsing the vault, so deleteProfile appends it.
//
// ⚠ deleteScopeSuffixes is the shared source of truth. When #91 ships ON, its per-unit heads must join the
// PURGE too, not just this fence -- fencing them without purging them makes a multi-device build LOOK fixed
// while the refs survive. That gap is recorded at deleteScopeSuffixes itself.
func sealFenceRefKeys(name, pass string) []string {
	return append(scopedDeleteRefs(name, pass), sealFenceUnitKeys(name, pass)...)
}

// loginLiftRefs is every ref deleteProfile ARMED, as seen from a login that has just proven the head LIVE.
// resolveKeyHeadForLogin is its only caller.
//
// ⚠⚠ THE ARM SET AND THE LIFT SET MUST BE THE SAME SET. This file already says arm and lift must always bump
// the sequence together; NWP-20260921-06 is what happens when they bump together and cover DIFFERENT refs.
// deleteProfile arms scopedDeleteRefs + accountDeleteRefs + THE RECOVERY REF (main.go). The lift passed
// sealFenceRefKeys, whose doc three lines up says in as many words that the recovery ref is not in it. So one
// marker survived every lift -- and pushProfile re-PUTs v.RecoveryRef on EVERY vault seal, so that one
// stranded marker refused the whole seal. Chester on lynx 2026-09-21: logged in, and could never log off.
// Each retry uploaded its chunks first and was refused at the pointer, burning store objects per attempt
// (the #120 cost shape, second sighting).
//
// ⚠ NWP-20260910-18 COULD NOT HAVE CAUGHT THIS, and its own verification recorded the residue as success:
// the markers went 15 -> 1 and the seal landed, so 1 read as "clean enough". That case RE-CREATED the name
// in the browser, which mints a vault with FRESH entropy and therefore a DIFFERENT recovery ref -- the fenced
// one is simply never written again. A RESTORE puts the SAME vault bytes back, so its recovery ref is
// byte-identical to the one the delete fenced. Restore is the only path that reproduces it.
//
// Reading the recovery ref needs no key: it is a plaintext vault field (a hash, and the vault type says so).
// headBlobGet is the prefetch cache resolveKeyHead just populated for this same head, so it costs nothing.
// dk is that call's data key, which is what lets accountDeleteRefs reach the account's OTHER lineages; it is
// nil-safe and returns nil outright while #91 multi-device is off, which is everywhere today. That arm-set
// member is therefore latent rather than live -- covered here so it cannot become the next one of these.
// loginFenceArmed reports whether this login has anything to lift. resolveKeyHeadForLogin is its only
// caller, and it runs on EVERY login, so it must stay cheap on the overwhelmingly common unfenced path:
// two ref derivations and a stat apiece (the pre-existing cost), plus one parse of a head blob the
// prefetch cache is already holding.
//
// ⚠⚠ THE TRIGGER MUST NOT BE THE BARE PAIR ALONE, BECAUSE THE LIFT REMOVES THE BARE PAIR.
// `deleteScopeSuffixes[0]` is "", so `scopedDeleteRefs` -- and therefore `loginLiftRefs` -- starts with
// exactly the two markers a bare-pair test looks at. A trigger reading only those is CONSUMED by the
// first lift, which makes the whole mechanism ONE-SHOT per name per boot: any marker still armed
// afterwards can never be lifted again, because the condition that would reach it is already gone.
// Found by an adversarial pass on the first cut of NWP-20260921-06, which fixed the SET the lift covers
// and left the trigger reading the same two refs it always had.
//
// The stranded marker is reachable in one boot: delete a profile (arming its recovery ref R), re-create
// or import the name OFF the device so it mints FRESH entropy and a different recovery ref, log in once
// (the lift fires, clears the bare pair, and removes a recovery ref that was never armed -- R survives),
// and then bring the ORIGINAL vault bytes back. That head carries R, `pushProfile` re-PUTs it on every
// vault seal, and nothing can lift it any more. `createVault`'s own lift disarms the trigger the same way.
//
// ⚠ ONE ROUTE TO THAT LAST STEP IS CURRENTLY BLOCKED ELSEWHERE, AND THAT IS NOT A REASON TO RELY ON IT:
// the storefront refuses a restore whose destination holds a different head (`pfDiffers`, and a 409 from
// its cap endpoint). That is a guarantee in ANOTHER REPO, and this file's own header states the case it
// does not cover -- a self-hosted (BYO-store) device, where the client-side fence "is the ONLY half" and
// nothing preflights a direct write to the store.
//
// Checking R costs no key: `RecoveryRef` is a plaintext vault field, the same property `loginLiftRefs`
// relies on. Safety is unchanged -- this only decides WHETHER to lift, and the lift itself is still
// gated on `ok`, i.e. a live head that opened for this passphrase.
func loginFenceArmed(base, name, pass, head string) bool {
	if sealFenceBlocks(profileRefV2(name, pass)) || sealFenceBlocks(profileRefLegacy(name, pass)) {
		return true
	}
	if v, isV := parseVault(headBlobGet(base, head)); isV && v.RecoveryRef != "" {
		return sealFenceBlocks(v.RecoveryRef)
	}
	return false
}

func loginLiftRefs(base, name, pass string, dk []byte, head string) []string {
	refs := append(sealFenceRefKeys(name, pass), accountDeleteRefs(base, name, pass, dk)...)
	if v, isV := parseVault(headBlobGet(base, head)); isV && v.RecoveryRef != "" {
		refs = append(refs, v.RecoveryRef)
	}
	return refs
}

// sealFenceUnitKeys is the #91 per-unit head for each scope, or nil when multi-device is off (everywhere,
// today).
//
// ⚠ ITS OWN WARNING IS NOW SPENT, and saying so matters more than deleting it. This used to read
// "Separate from scopedDeleteRefs because the fence covers these and the PURGE does not" -- which was
// true, and was the bug: delete tombstoned and verified only `scoped`, so it reported success while
// every lineage's heads stayed live. NWP-20260906-11 closed it. deleteProfile now appends
// accountDeleteRefs (multidevice.go) to `scoped` itself, so the fence, the tombstones and the verify
// all cover the same set.
//
// This function is still the FENCE's own list and is deliberately narrower: it derives from
// deviceUnitID(), so it can only ever name THIS handset. accountDeleteRefs reads the account directory
// and reaches every lineage, which is what a purge needs and what a publish fence does not.
func sealFenceUnitKeys(name, pass string) []string {
	if !multiDeviceEnabled() {
		return nil
	}
	keys := make([]string, 0, len(deleteScopeSuffixes))
	for _, s := range deleteScopeSuffixes {
		if scoped := name + s; isPerUnitRef(scoped) {
			keys = append(keys, unitHeadRef(scoped, pass, deviceUnitID()))
		}
	}
	return keys
}
