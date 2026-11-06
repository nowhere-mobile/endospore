package main

import (
	"encoding/hex"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// #135 telephony sealed inbox -- on-device buffer + ingest (docs/telephony-owner-mode.md).
//
// When an inbound call/SMS lands for a bound SIM whose owning profile is NOT live, the device handler
// seals the item to that profile's telephony pubkey (telephony_seal.go) and buffers the CIPHERTEXT
// here; at the owner's next login (or cold-lock resume) the agent, which then holds DK, decrypts the buffer
// and stages the items for the roamed user's own chooser to insert (stageTelInbox, telephony_ingest.go).
// The buffer lives on the tmpfs state dir, so it is RAM-only and gone on power-off/reboot, and never as
// readable plaintext at rest on user-0 (only the sealed box, addressed to one profile, sits here).
//
// WHO MAY REMOVE A RECORD (product-decisions.md 2026-09-24, Chester verbatim): "bound - it should get wiped
// after it lands to the assigned sim profile store"; "unbound - it shouldnt get wiped by any profile (only
// the owner or a reboot can clean it)". So a sealed blob is dropped only after its hand-off to the session is
// written (dropSealed), and the whole telephony subtree is spared by wipeSessionState -- another profile's
// create, login or logoff never touches it.

// stateDirDefault is the agent's session-state tmpfs (nowhere.rc mounts it; loginDaemon's dest when
// NOWHERE_STATE is unset). telStateSubdir is the ONE subdirectory of it that holds telephony records, and
// wipeSessionState spares it. Both telephony bases live under it; TestTelBasesLiveUnderTheSparedSubdir pins
// that, so moving one base without the other fails a test instead of silently re-exposing it to the wipes.
const (
	stateDirDefault = "/data/nowhere/state"
	telStateSubdir  = "tel"
)

// telInboxBase is the parent of the per-profile buffer dirs. A var so tests can point it at a temp dir
// (mirrors storeConfPath).
var telInboxBase = filepath.Join(stateDirDefault, telStateSubdir, "inbox")

// wipeSessionState empties the session-state dir EXCEPT the telephony subtree, then makes sure the dir
// exists. It replaces the legacy paths' os.RemoveAll(dest): handleCreate, the legacy handleLogoff and the
// legacy login fallthrough all ran that wipe, and because the sealed inbox and the per-uid hand-off live
// under dest, a stranger enrolling at the gate destroyed every other profile's undelivered record.
//
// ⚠ THE WALLET IS NOT SWEPT WITH THE REST (NWP-20261010-04). Nothing named wallet.json* is touched here: the
// wallet and a save's temp file go through removeWallet, which bumps the generation first so a departed writer
// cannot save over the arriving profile; the generation file is that writer's only way to know; and the .lock
// is never removed at all -- a waiter that reopened an unlinked lock file would lock a different inode. The
// removal comes AFTER the loop has removed the session marker, which maybePayRent's read order relies on.
func wipeSessionState(dest string) { wipeSessionStateWallet(dest, false) }

// wipeSessionStateKeepWallet is the wipe for a create made while a session is live or cold-locked
// (NWP-20261010-04): wallet.json is that session's and is kept. The wipe still removes the session's .coldlock and
// .roamsession, as it has since 78fa06a4c, so the session cannot resume after it; keeping the wallet matters only
// if the sign-in that follows the create fails.
func wipeSessionStateKeepWallet(dest string) { wipeSessionStateWallet(dest, true) }

func wipeSessionStateWallet(dest string, keepWallet bool) {
	wp := walletPathFor(dest)
	if ents, err := os.ReadDir(dest); err == nil {
		for _, e := range ents {
			if e.Name() == telStateSubdir || strings.HasPrefix(e.Name(), filepath.Base(wp)) {
				continue
			}
			os.RemoveAll(filepath.Join(dest, e.Name()))
		}
	}
	if _, err := os.Stat(dest); err == nil && !keepWallet {
		removeWallet(wp)
	}
	os.MkdirAll(dest, 0o700)
}

// telInboxDir is a profile's buffer directory, keyed by the stable profileRefV2 (hex -> filesystem
// safe). The same ref the SIM binding maps to, so the login side and the arrival side agree.
func telInboxDir(profileRef string) string {
	return filepath.Join(telInboxBase, profileRef)
}

// bufferSealed writes one sealed blob (base64) into the profile's buffer as "<simTag>.<rand>.seal", creating the
// dir on demand. The tag is the SIM the record came in on (NWP-20260924-07), so an unassign can delete exactly
// that SIM's records without opening anyone's blob; an empty tag writes an untagged "<rand>.seal". Published
// atomically via a dotfile + rename so a concurrent listSealed never sees a half-written blob. Best-effort at the
// call site: a dropped item is better than blocking the radio.
func bufferSealed(profileRef, tag, sealedB64 string) error {
	// Slice D: the bound inbox's hard budget. A flood on a bound SIM whose owner is offline can no longer fill the
	// 256 MiB state tmpfs the wallet and a live session share; the dropped owner is counted as a seal failure.
	if telStoreUsage(telInboxBase)+int64(len(sealedB64)) > telBoundBudgetHard {
		telClassNote(telClassBoundFull)
		return errTelBoundFull
	}
	dir := telInboxDir(profileRef)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	name := hex.EncodeToString(randBytes(8)) + ".seal"
	if isSimTag(tag) {
		name = tag + "." + name
	}
	return writeAtomic(filepath.Join(dir, "."+name), filepath.Join(dir, name), []byte(sealedB64))
}

// sealedName matches a tagged blob's file name, and sealedTempName its in-flight temp (a leftover of a failed
// publish). An untagged "<rand>.seal" matches neither and is never deleted by an unassign.
var sealedName = regexp.MustCompile(`^([0-9a-f]{16})\.[0-9a-f]{16}\.seal$`)
var sealedTempName = regexp.MustCompile(`^\.([0-9a-f]{16})\.[0-9a-f]{16}\.seal$`)

// blobTag is the SIM a sealed blob came in on, read from its file name; "" for an untagged blob.
func blobTag(path string) string {
	if m := sealedName.FindStringSubmatch(filepath.Base(path)); m != nil {
		return m[1]
	}
	if m := pendName.FindStringSubmatch(filepath.Base(path)); m != nil { // NWP-20261006-05: a pending copy keeps its tag
		return m[1]
	}
	return ""
}

// deleteSimBlobs deletes every sealed blob -- in every profile's buffer -- that came in on the SIM with this tag,
// including a failed publish's leftover temp, then removes any buffer dir that leaves empty (its mtime would
// otherwise record the last arrival). No owner lookup: a blob tagged T was only ever sealed to T's owners.
// Returns how many files it removed; the first error it met, if any.
func deleteSimBlobs(tag string) (int, error) {
	if !isSimTag(tag) {
		return 0, nil
	}
	dirs, err := os.ReadDir(telInboxBase)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	n := 0
	var first error
	for _, d := range dirs {
		if !d.IsDir() {
			continue
		}
		dir := filepath.Join(telInboxBase, d.Name())
		ents, err := os.ReadDir(dir)
		if err != nil {
			if first == nil {
				first = err
			}
			continue
		}
		for _, e := range ents {
			m := sealedName.FindStringSubmatch(e.Name())
			if m == nil {
				m = sealedTempName.FindStringSubmatch(e.Name())
			}
			if m == nil {
				m = pendName.FindStringSubmatch(e.Name()) // NWP-20261006-05: an unassign deletes the SIM's pending copies too
			}
			if m == nil || m[1] != tag {
				continue
			}
			if err := os.Remove(filepath.Join(dir, e.Name())); err != nil {
				if first == nil {
					first = err
				}
				continue
			}
			n++
		}
		os.Remove(dir) // non-recursive: only when the unassign emptied it
	}
	return n, first
}

// writeAtomic publishes data at dst via tmp + rename, and removes tmp if either step fails. Nothing else
// removes a leftover temp file before the reboot any more: listSealed skips dotfiles, dropSealed removes only
// the blobs it opened, and the session-state wipes spare the telephony subtree -- and the failure that leaves
// one is usually ENOSPC, so the leftover would go on holding the space that caused it.
func writeAtomic(tmp, dst string, data []byte) error {
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, dst); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// isTelSubtreeItem reports whether a store item, once joined under dest, would land ON or INSIDE the telephony
// subtree -- or on dest itself, whose tar could carry tel/ entries. It compares the resolved path, not the
// raw name: "tel/", "./tel", "x/../tel", "tel/inbox" and "." all pass safeJoin's escape check.
func isTelSubtreeItem(dest, itemDir string) bool {
	rel, err := filepath.Rel(filepath.Clean(dest), filepath.Clean(itemDir))
	return err != nil || rel == "." || rel == telStateSubdir || strings.HasPrefix(rel, telStateSubdir+string(filepath.Separator))
}

// sealItemToInbox seals a telItem to the profile's public key and buffers it, tagged with the SIM it came in on.
// This is the arrival-side entry point (the daemon calls it from the SMS/call handler when the owner is not live).
func sealItemToInbox(profileRef, pubB64, tag string, it telItem) error {
	blob, err := sealBoundCopy(pubB64, it)
	if err != nil {
		return err
	}
	return bufferSealed(profileRef, tag, blob)
}

// sealBoundCopy seals it for the bound store. An MMS whose sealed copy would cross the bound soft line is sealed
// without its media (Parts dropped, Note "too-large"; sender, subject and time kept) -- the 2026-09-30 decision,
// mirroring sealUnboundToOwner. Any other kind has no media to shed and is sealed whole, Note untouched. Used by
// both bound sealed-copy sites (the offline buffer and the live session's pending copy); the live mailbox row is
// never passed through it.
func sealBoundCopy(pubB64 string, it telItem) (string, error) {
	blob, err := sealTelItem(pubB64, it)
	if err != nil {
		return "", err
	}
	if it.Kind == "mms" && telStoreUsage(telInboxBase)+int64(len(blob)) > telBoundBudgetSoft {
		stripped := it
		stripped.Parts = nil
		stripped.Note = "too-large"
		return sealTelItem(pubB64, stripped)
	}
	return blob, nil
}

// listSealed returns the profile's sealed-blob file paths, sorted for a stable order. Skips dotfiles
// (in-flight temp writes) and non-.seal entries; a missing dir yields an empty slice.
func listSealed(profileRef string) []string {
	ents, err := os.ReadDir(telInboxDir(profileRef))
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		n := e.Name()
		if e.IsDir() || strings.HasPrefix(n, ".") || !strings.HasSuffix(n, ".seal") {
			continue
		}
		out = append(out, filepath.Join(telInboxDir(profileRef), n))
	}
	sort.Strings(out)
	return out
}

// clearTelInbox removes a profile's whole buffer dir. Its one caller is the authenticated profile delete
// (purgeLocalProfileState); delivery never uses it -- see dropSealed.
func clearTelInbox(profileRef string) {
	os.RemoveAll(telInboxDir(profileRef))
}

// readTelInbox opens the profile's telephony private key (vault + DK) and decrypts every buffered item. It
// returns the items and the paths of the blobs it opened, and REMOVES NOTHING: the caller drops `opened`
// (dropSealed) only once the hand-off to the session is written. A blob that will not read or open
// (corrupt, or sealed to another key) is skipped and LEFT -- it cannot be delivered, and it is ciphertext on
// the tmpfs, so the reboot takes it. Returns nil, nil when there is no keypair or nothing buffered.
func readTelInbox(v *vault, dk []byte, profileRef string) (items []telItem, opened []string) {
	priv := telephonyPriv(v, dk)
	if priv == nil {
		return nil, nil
	}
	// NWP-20261006-05: and the pending copies -- handed to a session earlier and never acknowledged.
	for _, p := range append(listSealed(profileRef), listPending(profileRef)...) {
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		it, err := openTelItem(priv, string(b))
		if err != nil {
			continue
		}
		items = append(items, it)
		opened = append(opened, p)
	}
	return items, opened
}

// dropSealed removes exactly the blobs a readTelInbox opened -- not the profile's whole directory, so a blob
// buffered after the read survives for the next delivery instead of being deleted unread. NWP-20261006-05: delivery no
// longer drops at the hand-off (stageTelInbox renames to a pending copy, and an acknowledgement deletes it); the
// tests that exercise readTelInbox use this to clear what they opened.
func dropSealed(paths []string) {
	for _, p := range paths {
		os.Remove(p)
	}
}

// moveTelInbox renames a profile's buffer dir -- sealed blobs and pending copies alike -- from oldRef's to newRef's,
// merging file by file when newRef already has one, and returns how many files moved. Nothing to move is not an
// error. It takes telMu like every other inbox writer (NWP-20261013-21).
func moveTelInbox(oldRef, newRef string) (int, error) {
	telMu.Lock()
	defer telMu.Unlock()
	return moveTelInboxLocked(oldRef, newRef)
}

// moveTelInboxLocked is the same operation inside a combined binding + inbox carry. Caller holds telMu.
func moveTelInboxLocked(oldRef, newRef string) (int, error) {
	if oldRef == "" || newRef == "" || oldRef == newRef {
		return 0, nil
	}
	src, dst := telInboxDir(oldRef), telInboxDir(newRef)
	ents, err := os.ReadDir(src)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	if _, err := os.Stat(dst); os.IsNotExist(err) {
		if err := os.Rename(src, dst); err != nil {
			return 0, err
		}
		return len(ents), nil
	} else if err != nil {
		return 0, err
	}
	moved := 0
	var first error
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		from := filepath.Join(src, e.Name())
		to := filepath.Join(dst, e.Name())
		// A pending copy keeps the original sealed blob's random id, so a profile that was rebound under newRef
		// can already have the same name. os.Rename would silently replace that destination on Linux. Keep both:
		// only this credential carry knows that the two directories are being merged.
		if _, err := os.Lstat(to); err == nil {
			for {
				to = filepath.Join(dst, inboxMergeName(e.Name()))
				if _, err = os.Lstat(to); os.IsNotExist(err) {
					break
				} else if err != nil {
					if first == nil {
						first = err
					}
					to = ""
					break
				}
			}
		} else if !os.IsNotExist(err) {
			if first == nil {
				first = err
			}
			continue
		}
		if to == "" {
			continue
		}
		if err := os.Rename(from, to); err != nil {
			if first == nil {
				first = err
			}
			continue
		}
		moved++
	}
	os.Remove(src) // only if it emptied
	return moved, first
}

// inboxMergeName gives a colliding inbox file a fresh random id while preserving every part of its name that
// listSealed/listPending interpret (the SIM tag, pending uid/key hash, and an in-flight dot). Random ids are the
// namespace bufferSealed and bufferPending already use; retry until the caller's destination does not exist.
func inboxMergeName(name string) string {
	prefix, suffix := "", ""
	if m := pendName.FindStringSubmatch(name); m != nil {
		if m[1] != "" {
			prefix = m[1] + "."
		}
		suffix = "." + m[3] + "." + m[4] + ".pend"
	} else if m := sealedName.FindStringSubmatch(name); m != nil {
		prefix = m[1] + "."
		suffix = ".seal"
	} else if m := sealedTempName.FindStringSubmatch(name); m != nil {
		prefix = "." + m[1] + "."
		suffix = ".seal"
	} else if strings.HasPrefix(name, ".") && strings.HasSuffix(name, ".seal") {
		prefix, suffix = ".", ".seal"
	} else if strings.HasSuffix(name, ".seal") {
		suffix = ".seal"
	} else {
		prefix, suffix = ".moved-", "-"+name
	}
	return prefix + hex.EncodeToString(randBytes(8)) + suffix
}
