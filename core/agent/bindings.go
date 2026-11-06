package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// #136 A3: SIM -> profile bindings. A physical SIM is tied (in owner mode) to ONE OR MORE owning profiles
// (many-to-many): inbound telephony on the SIM seals to EACH owner's telephony pubkey, and a shared SIM
// mirrors both directions to every owner (docs/telephony-owner-mode.md). The per-SIM visibility dial governs
// what a stranger at the gate sees. Persisted to /data/nowhere/bindings.conf -- persistent user-0 state (a
// deliberate exception to "nothing kept after a reboot": it's config, not content, and non-secret -- opaque refs +
// PUBLIC keys + labels; the device-owner key beside it, owner_key.go, is the other, since NWP-20260928-01).
// LF-only, 0600. Written by the owner-mode UI via the daemon; read at the gate by the arrival side.

var bindingsPath = "/data/nowhere/bindings.conf" // var so tests point it at a temp file

type bindingOwner struct {
	ProfileRef string // profileRefV2 (hex)
	TelPub     string // base64 raw X25519 public key (vault.TelPub)
}
type simBinding struct {
	SubID      int
	ICCID      string
	Label      string // owner-set display name (shown at the gate)
	Visibility string // "open" | "notify" | "private"
	Owners     []bindingOwner
}

func normVisibility(v string) string {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "notify":
		return "notify"
	case "private":
		return "private"
	default:
		return "open"
	}
}

// serialize: one line per SIM -- sub_id|iccid|label_b64|visibility|ref1:pub1,ref2:pub2 . The delimiters | : ,
// are absent from hex (ref) and base64 (pub, label_b64) alphabets, so they never collide. SIMs with no owners
// are dropped (a binding with nobody to deliver to is meaningless).
func serializeBindings(bs []simBinding) string {
	var sb strings.Builder
	sb.WriteString("v1\n")
	for _, b := range bs {
		if line := serializeLine(b); line != "" {
			sb.WriteString(line)
			sb.WriteByte('\n')
		}
	}
	return sb.String()
}

// serializeLine is one SIM's line, with no newline, or "" when it has no owner to write. NWP-20260930-04: it is also
// the reference a line is read back against (parseLineStrict, bindings_check.go): a line is trusted only when this
// writes it back byte for byte. The ICCID and the label go in as they are, so a writer refuses a record whose fields
// would not read back (setBindingOwner): written, it would be a damaged line.
func serializeLine(b simBinding) string {
	parts := make([]string, 0, len(b.Owners))
	for _, o := range b.Owners {
		if o.ProfileRef != "" && o.TelPub != "" {
			parts = append(parts, o.ProfileRef+":"+o.TelPub)
		}
	}
	if len(parts) == 0 {
		return ""
	}
	return strconv.Itoa(b.SubID) + "|" + b.ICCID + "|" + base64.StdEncoding.EncodeToString([]byte(b.Label)) + "|" +
		normVisibility(b.Visibility) + "|" + strings.Join(parts, ",")
}

// parseBindings is the lines of s that read back byte for byte, in file order. NWP-20260930-04: a line that does not
// is left out here and kept as damaged by parseBindingsText (bindings_check.go), for the readers that must not read
// its SIM as unbound. Before, a half-parsed line was kept with its bad fields defaulted -- a label that was not base64
// became "", a visibility other than the three became "open", the least private dial -- and an owner pair that did
// not parse was dropped, taking a co-owner with it.
func parseBindings(s string) []simBinding {
	return parseBindingsText(s).lines
}

// readBindings is the lines that read back (NWP-20260930-04, bindings_check.go), and none for a file that cannot be
// read at all, as for a missing one. A damaged line elsewhere does not change what the good lines answer: TEL-OWNER
// and the TEL-OWNED lists are the #158 outbound gate and the #176 SIM scope, which the chooser acts on.
func readBindings() []simBinding {
	bs, err := readBindingsChecked()
	if err != nil {
		return nil
	}
	return bs
}

// writeBindings publishes bs, followed by the damaged lines it carries forward, each marked with a leading "#" so that
// it can never read back as a good line with an owner missing (NWP-20260930-04). It writes no marks: the four writers
// below call writeBindingsMarked, and this keeps the shape test fixtures write a file in.
func writeBindings(bs []simBinding, damaged []string) error {
	return writeBindingsMarked(bs, damaged, bindingsMarks{})
}

// bindingsMarks are the records a write puts after the good lines and before the carried damaged lines
// (NWP-20261110-01, bindings_check.go "THE REBUILT MARK").
type bindingsMarks struct {
	rebuilt bool
	mine    []string
}

// marksAfter is what a writer writes back of the file it read: any rewrite of a flawed file (a damaged line, no header,
// an empty file) writes a REBUILT one, a rebuilt file stays rebuilt, and the mine records carry as they are. An absent
// file is the zero state, so a first bind writes an unmarked file. Two inferences Chester did not state: (a) a bind or
// unbind leaves a SIM's mine record as it is, a good line taking precedence while it exists; (b) the rule covers more
// than the three cases Q031 names -- "Unbind all" of the ICCID a damaged line names, and a bind or rename over a flawed
// file, also mark it rebuilt, from the decision's rule that damage never routes a profile's texts to the device owner.
func marksAfter(st bindingsState) bindingsMarks {
	return bindingsMarks{rebuilt: st.rebuilt || st.flawed, mine: st.mine}
}

// writeBindingsMarked is writeBindings with the marks: "#rebuilt" once, then one "#mine|<iccid>|" per SIM, written
// after the good lines and before the damaged ones. A mine ICCID that would not read back is refused before any write.
func writeBindingsMarked(bs []simBinding, damaged []string, m bindingsMarks) error {
	for _, iccid := range m.mine {
		if !mineICCIDStorable(iccid) {
			return errBindingUnstorable
		}
	}
	dir := filepath.Dir(bindingsPath)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	// NWP-20260930-04: synced before and after the rename, as the owner key is, so a power loss leaves the old file
	// or the new one -- a file that had never reached the disk used to come back empty or half-written.
	tmp := filepath.Join(dir, ".bindings.conf.tmp")
	fh, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	body := serializeBindings(bs)
	if m.rebuilt {
		body += bindingsRebuiltMark + "\n"
	}
	for _, iccid := range m.mine {
		body += bindingsMinePrefix + iccid + "|\n"
	}
	for _, row := range damaged {
		if !strings.HasPrefix(row, "#") {
			row = "#" + row
		}
		body += row + "\n"
	}
	_, werr := fh.WriteString(body)
	serr := fh.Sync()
	cerr := fh.Close()
	if err := errors.Join(werr, serr, cerr); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, bindingsPath); err != nil { // atomic publish
		os.Remove(tmp)
		return err
	}
	if d, err := os.Open(dir); err == nil {
		d.Sync()
		d.Close()
	}
	return nil
}

// setBindingOwner adds/updates ONE owner on a SIM (creating the SIM record if new) and sets the SIM's label +
// visibility. Keyed by ICCID (stable across reboots). This is the owner-mode "bind profile P to SIM S" op;
// calling it again with another profileRef makes the SIM many-to-many.
func setBindingOwner(subID int, iccid, label, visibility, profileRef, telPub string) error {
	if normICCID(iccid) == "" || profileRef == "" || telPub == "" {
		return errors.New("binding: iccid, profileRef and telPub required")
	}
	st := readBindingsState() // NWP-20260930-04: a file that cannot be read is refused; a damaged line is carried forward
	if st.unreadable {
		return errBindingsDamaged
	}
	bs := st.lines
	prev := linkSnapshot(bs)
	var target *simBinding
	for i := range bs {
		if normICCID(bs[i].ICCID) == normICCID(iccid) { // NWP-20260924-07: padded and unpadded are one SIM
			target = &bs[i]
			break
		}
	}
	if target == nil {
		bs = append(bs, simBinding{ICCID: iccid})
		target = &bs[len(bs)-1]
	}
	target.SubID = subID
	target.Label = label
	target.Visibility = normVisibility(visibility)
	found := false
	for i := range target.Owners {
		if target.Owners[i].ProfileRef == profileRef {
			target.Owners[i].TelPub = telPub // re-bind (e.g. after a keypair rotation)
			found = true
			break
		}
	}
	if !found {
		target.Owners = append(target.Owners, bindingOwner{ProfileRef: profileRef, TelPub: telPub})
	}
	if _, ok := parseLineStrict(serializeLine(*target)); !ok { // a field that would not read back: an ICCID holding '|'
		return errBindingUnstorable
	}
	if err := writeBindingsMarked(bs, st.damaged, marksAfter(st)); err != nil {
		return err
	}
	// NWP-20260930-04: if the SIM had no good line before this bind but a damaged line named it, its owners just
	// before now were unknown -- an arrival stamped earlier must be UNRESOLVED, not resolved against this new owner.
	recordLinkChanges(prev, linkSnapshot(bs), damagedOnlyTag(prev, st.damaged, iccid))
	return nil
}

// damagedOnlyTag returns [simTag(iccid)] when, before a bind, the SIM had no good line (prev) but a damaged line named
// it -- the "unknownBefore" case for recordLinkChanges -- else nil.
func damagedOnlyTag(prev map[string]map[string]bool, damaged []string, iccid string) []string {
	tag := simTag(iccid)
	if len(prev[tag]) > 0 {
		return nil
	}
	for _, row := range damaged {
		if damagedLineICCID(row) == normICCID(iccid) {
			return []string{tag}
		}
	}
	return nil
}

// removeBindingOwner drops one owner from a SIM, or the whole SIM if profileRef == "", and returns how many SIM
// records changed. NWP-20260924-07: the ICCID is compared normalised (normICCID) -- the chooser's form and the
// stored one may differ by a filler 'f', and an exact compare made "Unbind all" a silent no-op -- and nothing is
// written when nothing matched, so a no-op never mints an empty bindings.conf (the rule removeBindingOwnerEverywhere
// already follows).
func removeBindingOwner(iccid, profileRef string) (int, error) {
	st := readBindingsState() // NWP-20260930-04: a file that cannot be read is refused; a damaged line is carried forward
	if st.unreadable {
		return 0, errBindingsDamaged
	}
	bs := st.lines
	prev := linkSnapshot(bs)
	want := normICCID(iccid)
	changed := 0
	out := bs[:0]
	for _, b := range bs {
		if want != "" && normICCID(b.ICCID) == want {
			if profileRef == "" {
				changed++
				continue // drop the whole SIM
			}
			kept := b.Owners[:0]
			for _, o := range b.Owners {
				if o.ProfileRef != profileRef {
					kept = append(kept, o)
				}
			}
			if len(kept) != len(b.Owners) {
				changed++
			}
			b.Owners = kept
			if len(b.Owners) == 0 {
				continue // last owner removed -> drop the SIM
			}
		}
		out = append(out, b)
	}
	damaged := st.damaged
	var unknown []string
	if profileRef == "" && want != "" { // NWP-20260930-04, the repair: "Unbind all" of the ICCID a damaged line names
		damaged = nil
		for _, row := range st.damaged {
			if damagedLineICCID(row) == want {
				changed++
				if len(prev[simTag(iccid)]) == 0 {
					// the SIM's only line was the damaged one: after the repair it is clean, but its owners
					// just before were unknown, so an arrival stamped earlier must be UNRESOLVED, not unbound.
					unknown = []string{simTag(iccid)}
				}
				continue
			}
			damaged = append(damaged, row)
		}
	}
	if changed == 0 {
		return 0, nil
	}
	if err := writeBindingsMarked(out, damaged, marksAfter(st)); err != nil {
		return changed, err
	}
	recordLinkChanges(prev, linkSnapshot(out), unknown)
	return changed, nil
}

// removeBindingOwnerEverywhere drops a profileRef from EVERY SIM, and is the delete case (#136 A3 /
// NWP-20260903-21): removeBindingOwner above is keyed by ICCID because the owner-mode UI unbinds ONE SIM,
// but a deleted profile is gone from the device entirely and no SIM may still name it. Returns how many
// SIMs changed.
//
// Writes NOTHING when nothing matched -- including when there is no bindings.conf at all. That matters
// because writeBindings does MkdirAll + create, so an unconditional write would MINT an empty bindings.conf
// on any device (or build host) that never had one, turning a no-op delete into new persistent state.
func removeBindingOwnerEverywhere(profileRef string) (int, error) {
	if profileRef == "" {
		return 0, nil
	}
	st := readBindingsState() // NWP-20260930-04: a file that cannot be read is refused; a damaged line is carried forward
	if st.unreadable {
		return 0, errBindingsDamaged
	}
	bs := st.lines
	if len(bs) == 0 && len(st.damaged) == 0 {
		return 0, nil
	}
	prev := linkSnapshot(bs)
	changed := 0
	out := bs[:0]
	for _, sim := range bs {
		kept := sim.Owners[:0]
		for _, o := range sim.Owners {
			if o.ProfileRef != profileRef {
				kept = append(kept, o)
			}
		}
		if len(kept) != len(sim.Owners) {
			changed++
		}
		sim.Owners = kept
		if len(sim.Owners) == 0 {
			continue // last owner gone -> drop the SIM, same rule as removeBindingOwner
		}
		out = append(out, sim)
	}
	// A deleted profile leaves no identity in a damaged line either (NWP-20260903-21). Reduce every damaged line to
	// its sub_id and ICCID, dropping all owner tokens: the deleted profile's ref, a co-owner's -- which dropping the
	// line whole would take with it, losing that co-owner's SIM (it would read unbound, not DAMAGED) -- and a hex
	// prefix of a ref left by a cut-short line, which Contains(profileRef+":") would miss. A line that names no ICCID
	// is dropped: it carries no SIM and no repair handle, and the write leaves the file rebuilt (marksAfter, NWP-20261110-01),
	// so the SIM it held reads unresolved, not the device owner's. The SIMs the surviving markers name stay DAMAGED.
	var damaged []string
	for _, row := range st.damaged {
		redacted := redactDamagedIdentity(row)
		if redacted != row {
			changed++
		}
		if redacted != "" {
			damaged = append(damaged, redacted)
		}
	}
	if changed == 0 {
		return 0, nil
	}
	if err := writeBindingsMarked(out, damaged, marksAfter(st)); err != nil {
		return changed, err
	}
	recordLinkChanges(prev, linkSnapshot(out), nil)
	return changed, nil
}

// bindingForSubID is the arrival-side lookup. An arrival that carries an ICCID is matched by it and by nothing else:
// a SIM that names itself and matches no binding is UNBOUND, whatever sub_id it has. Only an arrival with no ICCID
// falls back to the sub_id -- the chooser sends "" exactly when it cannot read one (iccidForSub for texts,
// resolveSubIccid for calls) -- and a sub_id below 0 never matches, because a SIM bound by hand stores -1.
// NWP-20260924-07: it used to try the sub_id first and always, and sub_ids renumber across reboots, so one SIM's
// records could be sealed to another SIM's owners -- and, now that every record is tagged with its SIM, under the
// other SIM's tag, which only the wrong unassign deletes.
func bindingForSubID(subID int, iccid string) (simBinding, bool) {
	bs := readBindings()
	if want := normICCID(iccid); want != "" {
		for _, b := range bs {
			if normICCID(b.ICCID) == want {
				return b, true
			}
		}
		return simBinding{}, false
	}
	if subID < 0 {
		return simBinding{}, false
	}
	for _, b := range bs {
		if b.SubID == subID {
			return b, true
		}
	}
	return simBinding{}, false
}

// bindingLabels returns the line label of every SIM record whose ICCID normalises to this one, in file order; a
// repeat is harmless, since the chooser collects them into a set. The unassign reply carries them so owner mode
// can clear the gate notices posted under them: a notice names its line only by label. NWP-20260924-08, Chester
// 2026-09-24: "unbind all should clear it".
func bindingLabels(iccid string) []string {
	want := normICCID(iccid)
	if want == "" {
		return nil
	}
	var out []string
	for _, b := range readBindings() {
		if normICCID(b.ICCID) == want {
			out = append(out, b.Label)
		}
	}
	return out
}

// renameBindingOwnerEverywhere moves a profile's ownership of every SIM from oldRef to newRef, and is the credential
// change case (NWP-20261013-21): a rotation or a recovery changes profileRefV2(name, pass) but keeps the telephony
// keypair, so the owner's TelPub stays right and only the ref is stale. Left alone, TEL-OWNER answers NO for the new
// ref (outbound blocked), arrivals are sealed under a ref the next sign-in never reads, a later delete leaves oldRef
// behind, and a re-bind adds a second owner. Returns how many SIMs changed.
//
// Follows removeBindingOwnerEverywhere's rules: writes NOTHING when nothing matched (so no bindings.conf is minted),
// refuses a file it cannot read, and carries damaged lines forward untouched. A SIM newRef already owns keeps that
// entry and just loses oldRef's -- merged, never duplicated. The operation holds telMu; the publish is writeBindings'
// rename, which the lock-free readers depend on.
func renameBindingOwnerEverywhere(oldRef, newRef string) (int, error) {
	telMu.Lock()
	defer telMu.Unlock()
	return renameBindingOwnerEverywhereLocked(oldRef, newRef)
}

// renameBindingOwnerEverywhereLocked is the same operation inside a larger atomic telephony change. Caller holds
// telMu. Keeping the lock-taking entry point above means a future standalone caller cannot publish unlocked.
func renameBindingOwnerEverywhereLocked(oldRef, newRef string) (int, error) {
	if oldRef == "" || newRef == "" || oldRef == newRef {
		return 0, nil
	}
	st := readBindingsState()
	if st.unreadable {
		return 0, errBindingsDamaged
	}
	bs := st.lines
	if len(bs) == 0 {
		return 0, nil
	}
	changed := 0
	changedTags := map[string]bool{}
	for i := range bs {
		var owners []bindingOwner
		hasNew, hasOld := false, false
		for _, o := range bs[i].Owners {
			if o.ProfileRef == newRef {
				hasNew = true
			}
			if o.ProfileRef == oldRef {
				hasOld = true
			}
		}
		if !hasOld {
			continue
		}
		for _, o := range bs[i].Owners {
			if o.ProfileRef == oldRef {
				if hasNew {
					continue // newRef already owns this SIM: merge
				}
				o.ProfileRef = newRef
			}
			owners = append(owners, o)
		}
		bs[i].Owners = owners
		changed++
		changedTags[simTag(bs[i].ICCID)] = true
	}
	if changed == 0 {
		return 0, nil
	}
	if err := writeBindingsMarked(bs, st.damaged, marksAfter(st)); err != nil {
		return changed, err
	}
	// This is the same owner continuing under a new credential, not an unbind/rebind. Rewrite that identity in the
	// in-memory link history instead of recording remove(oldRef)+add(newRef): an MMS can be stamped before the
	// rotation and reach the daemon afterwards, and the latter would classify it REMOVED and discard it.
	renameLinkHistoryOwner(changedTags, oldRef, newRef)
	return changed, nil
}

// renameLinkHistoryOwner carries a continuing owner's identity through the arrival resolver's history. Caller holds
// telMu and has successfully published the matching bindings rename. Unlike a real link change this deliberately
// does not advance the persistent link floor: an arrival already in flight still belongs to this same owner.
func renameLinkHistoryOwner(tags map[string]bool, oldRef, newRef string) {
	for i := range linkHistory {
		if !tags[linkHistory[i].tag] {
			continue
		}
		for _, refs := range []map[string]bool{linkHistory[i].before, linkHistory[i].after} {
			if refs[oldRef] {
				delete(refs, oldRef)
				refs[newRef] = true
			}
		}
	}
}

// bindingRefsByTelPub is the ref of every owner, on any SIM, whose TelPub is pub -- distinct, in file order. A
// recovery has no old passphrase and so cannot derive its old ref; the kept keypair names it instead.
func bindingRefsByTelPubLocked(pub string) []string {
	if pub == "" {
		return nil
	}
	st := readBindingsState()
	if st.unreadable {
		return nil
	}
	var refs []string
	seen := map[string]bool{}
	for _, b := range st.lines {
		for _, o := range b.Owners {
			if o.TelPub == pub && !seen[o.ProfileRef] {
				seen[o.ProfileRef] = true
				refs = append(refs, o.ProfileRef)
			}
		}
	}
	return refs
}

// carryTelephonyRef moves a profile's SIM bindings and its sealed inbox (pending copies included) from oldRef to
// newRef, under telMu so no seal lands between the two. Called only after the credential change has committed. Logs
// counts, never refs.
func carryTelephonyRef(oldRef, newRef string) {
	if oldRef == "" || newRef == "" || oldRef == newRef {
		return
	}
	telMu.Lock()
	defer telMu.Unlock()
	n, err := renameBindingOwnerEverywhereLocked(oldRef, newRef)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[logind] credential change: could NOT carry %d SIM binding line(s) to the new passphrase (NWP-20261013-21)\n", n)
	} else if n > 0 {
		fmt.Fprintf(os.Stderr, "[logind] credential change: carried %d SIM binding line(s) to the new passphrase (NWP-20261013-21)\n", n)
	}
	moved, err := moveTelInboxLocked(oldRef, newRef)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[logind] credential change: carried %d sealed item(s), then the inbox move failed (NWP-20261013-21)\n", moved)
	} else if moved > 0 {
		fmt.Fprintf(os.Stderr, "[logind] credential change: carried %d sealed item(s) to the new passphrase (NWP-20261013-21)\n", moved)
	}
}

// carryTelephonyByTelPub is the recovery form: oldRef is the one owner whose TelPub is the vault's. No match, or
// more than one, changes nothing -- a guess could hand a SIM to the wrong profile.
func carryTelephonyByTelPub(telPub, newRef string) {
	telMu.Lock()
	defer telMu.Unlock()
	refs := bindingRefsByTelPubLocked(telPub)
	if len(refs) != 1 {
		fmt.Fprintf(os.Stderr, "[logind] recover: telephony key matched %d bound owner ref(s) -- binding(s) left as they were (NWP-20261013-21)\n", len(refs))
		return
	}
	oldRef := refs[0]
	n, err := renameBindingOwnerEverywhereLocked(oldRef, newRef)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[logind] recover: could NOT carry %d SIM binding line(s) to the new passphrase (NWP-20261013-21)\n", n)
	} else if n > 0 {
		fmt.Fprintf(os.Stderr, "[logind] recover: carried %d SIM binding line(s) to the new passphrase (NWP-20261013-21)\n", n)
	}
	moved, err := moveTelInboxLocked(oldRef, newRef)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[logind] recover: carried %d sealed item(s), then the inbox move failed (NWP-20261013-21)\n", moved)
	} else if moved > 0 {
		fmt.Fprintf(os.Stderr, "[logind] recover: carried %d sealed item(s) to the new passphrase (NWP-20261013-21)\n", moved)
	}
}
