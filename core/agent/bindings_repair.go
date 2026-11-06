package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strconv"
)

// NWP-20261110-02: REPAIR-BINDINGS and SET-SIM-MINE, the two owner-mode verbs Q031 decided (docs/product-decisions.md;
// backlog: "A damaged line of bindings.conf leaves its SIM's arrivals unkept, and some damage cannot be repaired from
// the phone"). Before them no verb repaired bindings.conf: an unreadable file was refused by every writer, so every
// arrival on every SIM was lost, every owner's outbound was blocked and a profile delete could not remove its binding,
// until a factory reset. The repair keeps every good line and mine record, drops the damaged lines, replaces an
// unreadable file, and marks the file rebuilt (bindings_check.go "THE REBUILT MARK"); in a rebuilt file a SIM no good
// line names is nobody's until it is bound or the owner marks it mine with SET-SIM-MINE. Both run under telMu, and both
// are in handleLogin's TryLock set, so a held sessionMu answers BUSY, never a queued write the owner did not see land.
// No log line here names a path, an ICCID or a SIM tag (the telClassNote rule): a count or an errno only.

// repairBindings is REPAIR-BINDINGS: "OK CLEAN" (no file, or a file that is not flawed: nothing is written, so no file
// is minted), "OK REPAIRED <n>" (a flawed, readable file rewritten with its good lines and mine records, its n damaged
// lines dropped, marked rebuilt), "OK REPLACED" (an unreadable file replaced by an empty rebuilt one) or "ERR io" (the
// write failed: a storage or SELinux-label fault, a directory at the path included; the old file is left as it was).
// Caller holds telMu.
func repairBindings() string {
	st := readBindingsState()
	if !st.flawed { // absent, or clean (rebuilt or not)
		return "OK CLEAN\n"
	}
	if st.unreadable {
		// Nothing about the file is known, so nothing is carried. Every SIM is then unresolved until it is bound or
		// marked mine, and each of those records its own link change, so no earlier arrival resolves to the device
		// owner.
		if err := writeBindingsMarked(nil, nil, bindingsMarks{rebuilt: true}); err != nil {
			return bindingsWriteFailed(err)
		}
		fmt.Fprint(os.Stderr, "[logind] bindings.conf repair: replaced an unreadable file with an empty rebuilt one\n")
		return "OK REPLACED\n"
	}
	prev := linkSnapshot(st.lines)
	// removeBindingOwner's repair rule: a SIM whose only line was a damaged one had unknown owners just before, so an
	// arrival stamped before the repair must stay UNRESOLVED, not resolve against the file as repaired.
	var unknown []string
	seen := map[string]bool{}
	for _, row := range st.damaged {
		ic := damagedLineICCID(row)
		if ic == "" {
			continue
		}
		if tag := simTag(ic); len(prev[tag]) == 0 && !seen[tag] {
			seen[tag] = true
			unknown = append(unknown, tag)
		}
	}
	if err := writeBindingsMarked(st.lines, nil, bindingsMarks{rebuilt: true, mine: st.mine}); err != nil {
		return bindingsWriteFailed(err)
	}
	recordLinkChanges(prev, prev, unknown)
	fmt.Fprintf(os.Stderr, "[logind] bindings.conf repair: %d damaged line(s) dropped, file marked rebuilt\n", len(st.damaged))
	return "OK REPAIRED " + strconv.Itoa(len(st.damaged)) + "\n"
}

// simMineRefusal is SET-SIM-MINE's refusal of a malformed request, given before the file is read: "ERR\n" for an ICCID
// that cannot be a mine record (normICCID empties it, or it holds '|', a CR or a LF) or a flag other than "0" or "1",
// else "".
func simMineRefusal(iccid, flag string) string {
	if !mineICCIDStorable(iccid) || (flag != "0" && flag != "1") {
		return "ERR\n"
	}
	return ""
}

// setSimMine is SET-SIM-MINE: it adds (mine) or removes the "#mine|<iccid>|" record of one SIM in a rebuilt file,
// matched by simTag, so a padded ICCID and an unpadded one are one SIM. "ERR damaged" for an unreadable file, "ERR
// repair" while the file is flawed (arrivalLine answers DAMAGED for a SIM no good line names there, so the mark could not
// take effect), "OK NOTREBUILT" for a file that is not rebuilt (a SIM no line names is already the owner's line),
// "OK UNCHANGED" when the record is already so; nothing is written for any of those. Else "OK" after the write, or
// "ERR io". Caller holds telMu, and has checked the request with simMineRefusal.
func setSimMine(iccid string, mine bool) string {
	st := readBindingsState()
	if st.unreadable {
		return "ERR damaged\n"
	}
	if st.flawed {
		return "ERR repair\n"
	}
	if !st.rebuilt {
		return "OK NOTREBUILT\n"
	}
	tag := simTag(iccid)
	if st.mineTag(tag) == mine {
		return "OK UNCHANGED\n"
	}
	var next []string
	for _, m := range st.mine {
		if simTag(m) != tag {
			next = append(next, m)
		}
	}
	if mine {
		next = append(next, iccid)
	}
	if err := writeBindingsMarked(st.lines, nil, bindingsMarks{rebuilt: true, mine: next}); err != nil {
		return bindingsWriteFailed(err)
	}
	// The mark changes which inbox an arrival on this SIM resolves to, so, as for a bind, only arrivals from now on
	// follow it: one stamped while the SIM was unresolved stays UNRESOLVED rather than becoming the device owner's.
	snap := linkSnapshot(st.lines)
	recordLinkChanges(snap, snap, []string{tag})
	return "OK\n"
}

// bindingsMarksReply is GET-BINDINGS' marks from the state it already read: "REBUILT" when the file is rebuilt, then
// one "MINE <iccid>" per mine record, in file order. A chooser from before NWP-20261110-02 skips both, as it skips any
// line without five '|' fields; a mine ICCID never holds a '|' (mineICCIDStorable).
func bindingsMarksReply(st bindingsState) string {
	out := ""
	if st.rebuilt {
		out += "REBUILT\n"
	}
	for _, m := range st.mine {
		out += "MINE " + m + "\n"
	}
	return out
}

// bindingsWriteFailed logs a failed bindings.conf write as its operation and errno, never the path (ownerKeyIOErr's
// shape), and answers ERR io.
func bindingsWriteFailed(err error) string {
	why := "write"
	var pe *fs.PathError
	var le *os.LinkError
	switch {
	case errors.As(err, &pe):
		why = pe.Op + " " + pe.Err.Error()
	case errors.As(err, &le):
		why = le.Op + " " + le.Err.Error()
	}
	fmt.Fprintf(os.Stderr, "[logind] bindings.conf write failed: %s\n", why)
	return "ERR io\n"
}
