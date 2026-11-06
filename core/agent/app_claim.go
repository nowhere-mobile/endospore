package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

// Per-app concurrency claims (`NWP-20260910-25`) -- who currently holds an app, published in the head.
//
// THE PRODUCT RULE. `docs/product-decisions.md` (2026-09-08, DECIDED): one profile across devices, and
// concurrency arbitrated PER APP rather than per account -- an app in use on one handset is not launchable on
// another. The ENFORCEMENT half already exists on the chooser side (`AppClaim.java`, `NWP-20260910-24`): it can
// hold an app shut and say so. This is the other half: the record that says WHO holds what, and it is the only
// thing that can tell one handset about the other.
//
// WHY IT RIDES THE HEAD AND ADDS NO CHANNEL. The same argument as the account-level tombstones next door
// (`app_tombstone.go`): every device reads the stored head on every seal, so a fact written there propagates
// with no new endpoint, no messaging and no second ref. Devices meet through the store roughly every
// `syncIntervalDefault` seconds, so a claim is knowable minutes late -- which the decision already accepts in
// its `Lease latency` bullet.
//
// ⚠⚠ THE FAILURE THIS IS BUILT AROUND: A CLAIM WITH NO WAY BACK STRANDS AN APP FOREVER.
// `app_tombstone.go` states the general form of this trap -- "a permanent record with no way back is how a
// tombstone design goes wrong" -- and the decision names this instance of it directly: "an amnesiac device
// that powers off without releasing must not strand an app forever." A device that is switched off, runs out
// of battery, or is wiped mid-session NEVER gets to publish a release. So a claim must not be a flag that
// someone has to clear; it must LAPSE ON ITS OWN.
//
// Hence the heartbeat: a claim carries the unix second it was last refreshed, every seal refreshes the claims
// this handset still holds, and a claim older than `claimTTL` is ignored and dropped at the next publish. A
// powered-off handset simply stops refreshing and its claims expire by arithmetic. There is no release
// message to lose, no cleanup job to schedule, and no state that can outlive the device that made it.
//
// WHY THERE IS NO WRITE CONFLICT, which is what makes this safe on a last-writer-wins head. The map is keyed
// by PACKAGE, but every entry NAMES THE UNIT that holds it, and a publish only ever rewrites entries whose
// unit is THIS handset -- every other unit's entry is carried forward verbatim. So two handsets sealing
// concurrently are writing disjoint halves of one map and neither can undo the other. That is the property
// the `#media` carry lacks, and it is why this cannot settle into the permanent 2-cycle recorded there: there
// is nothing for the two devices to disagree about.
//
// ⚠ FIRST DEVICE WINS, and this is where that decision actually lands. `docs/product-decisions.md`
// (2026-09-10, DECIDED): when two handsets genuinely diverge the FIRST one wins and the loser's changes are
// DISCARDED. A second handset that asks to hold a package already held by a LIVE claim does not take it --
// the existing claim is kept and the request is REFUSED, and `claimsToPublish` returns those refusals so the
// caller can tell the user rather than failing silently. Telling the user is the unbuilt half of that
// decision (`docs/backlog.md`, section C) and it is what makes the discard acceptable.

// claimTTL is how long a claim survives without a refresh, in seconds.
//
// The tension is real and this value is the whole of it. Too SHORT and a claim lapses while the app is
// genuinely in use, so both handsets edit it and the decision's discard fires for no reason. Too LONG and a
// handset that powered off holds its apps shut on every other device for that long. 15 minutes is roughly
// seven `syncIntervalDefault` cycles, so a claim survives a handset that is merely slow, offline for a few
// cycles, or between seals -- while a device that is actually gone releases everything well inside the time
// it takes a user to walk to their other phone.
//
// ⚠ It is deliberately NOT derived from the sync interval. That interval is per-device and configurable
// (`syncIntervalGet` reads a settings file, then the env, then this default, and clamps to [15, 86400]), so
// one handset cannot know another's cadence -- a TTL computed from the local value would mean something
// different on each device, which is exactly how a distributed timeout becomes unanalysable.
const claimTTL int64 = 15 * 60

// appClaim is one package's holder. Short JSON keys, like essRegion next door: this map is published in every
// head and a package name is already the long half of each entry.
type appClaim struct {
	Unit string `json:"u"` // the unit id holding it -- deviceUnitID() of the handset that claimed it
	At   int64  `json:"t"` // unix seconds of the last refresh; the heartbeat this whole design rests on
}

// live reports whether this claim still counts at time now.
func (c appClaim) live(now int64) bool {
	return now-c.At < claimTTL
}

// claimsToPublish merges what THIS unit holds into the stored head's claim map.
//
// Three rules, in order, and each is load-bearing:
//
//  1. A LAPSED claim is dropped, whoever owns it. This is the escape hatch, and it must run before anything
//     else so a dead handset's claim cannot block a live one.
//  2. Another unit's LIVE claim is carried forward verbatim, and if this unit asked for that package the
//     request is REFUSED rather than taken -- first device wins.
//  3. This unit's own entries are rebuilt from `held`, never merged. That is how a release propagates: an app
//     this handset no longer holds simply stops appearing, and the entry is gone at the next publish.
//
// Returns the map to publish and the packages this unit asked for but did not get. A nil map is returned when
// there is nothing to record, so `omitempty` leaves a manifest byte-identical to one from before this existed.
func claimsToPublish(old map[string]appClaim, unit string, held []string, now int64) (map[string]appClaim, []string) {
	out := map[string]appClaim{}
	for pkg, c := range old {
		if !c.live(now) {
			continue // rule 1: lapsed, whoever owned it
		}
		if c.Unit == unit {
			continue // rule 3: ours, and rebuilt below only if we still hold it
		}
		out[pkg] = c // rule 2: someone else's, and not ours to touch
	}
	var refused []string
	for _, pkg := range held {
		if pkg == "" {
			continue
		}
		if _, taken := out[pkg]; taken {
			refused = append(refused, pkg) // another unit holds it and is still live: first wins
			continue
		}
		out[pkg] = appClaim{Unit: unit, At: now}
	}
	if len(out) == 0 {
		return nil, refused
	}
	return out, refused
}

// claimsHeldByOthers is what the ENFORCEMENT side needs: every package a LIVE claim assigns to some other
// unit, mapped to the unit holding it. This handset must refuse to launch exactly these.
//
// Deliberately keyed by package rather than filtered to a list the caller supplies: the chooser has to be able
// to hold an app it has never heard of, and a package it does not know about is precisely the case where
// asking it first would silently skip.
func claimsHeldByOthers(m map[string]appClaim, unit string, now int64) map[string]string {
	out := map[string]string{}
	for pkg, c := range m {
		if c.Unit == unit || !c.live(now) {
			continue
		}
		out[pkg] = c.Unit
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// labelsToPublish is the unit-to-label map this seal publishes beside `claims` (h54 #1, decided 2026-11-02 in
// `docs/product-decisions.md`). `claims` is the map this seal publishes, so a lapsed claim is already gone from it.
//
// The same disjoint-halves rule as claimsToPublish: another unit's entry is carried forward VERBATIM while that
// unit holds at least one claim in `claims`, and dropped once it holds none, so a label leaves the live manifest
// with its unit's claims. This unit's entry is rewritten from `label`, and only while this unit holds a claim and
// the label is valid. Returns nil when empty, so `omitempty` leaves a manifest without holds byte-identical to one
// from before this existed.
func labelsToPublish(old map[string]string, claims map[string]appClaim, unit, label string) map[string]string {
	holds := map[string]bool{}
	for _, c := range claims {
		holds[c.Unit] = true
	}
	out := map[string]string{}
	for u, l := range old {
		if u != unit && holds[u] {
			out[u] = l // another unit's, still holding: not ours to touch
		}
	}
	if holds[unit] && validDeviceLabel(label) {
		out[unit] = label
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// holderNames is the comparison h54 #1 puts in the agent, so the chooser never reads labels: unit -> the trimmed
// label of each unit whose label is valid and differs from this phone's own. An equal, absent or invalid label
// gives no entry, and the chooser then says "your other device" (the `NWP-20260912-01` naming rule). The
// validation runs HERE, on read, because another unit's label is carried verbatim: a tab or newline in it must
// never reach the claim file, where it would split a line.
func holderNames(labels map[string]string, own string) map[string]string {
	own = strings.TrimSpace(own)
	out := map[string]string{}
	for u, l := range labels {
		if !validDeviceLabel(l) {
			continue
		}
		if t := strings.TrimSpace(l); t != own {
			out[u] = t
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// ---- the two files that join this to the rest of the system ---------------------------------------------
//
// The seal runs in a SEPARATE `nowhere_agent` process that roamd spawns, so the login daemon's RAM is
// invisible to it. The established handoff for exactly this is a file the chooser writes and roamd points at
// with an env var -- `fileDropList` / `NOWHERE_DROP_LIST` is the same shape, and the drop list taught the
// defensive parsing below: a "package name" containing a path separator means the producer wrote paths, and
// matching it as a basename could act on an unrelated subtree.
//
// ⚠ WHICH SCOPE CARRIES THE CLAIMS IS ROAMD'S CHOICE, NOT THIS FILE'S. roamd exports NOWHERE_HELD_LIST for
// ONE push, the same way it exports NOWHERE_DROP_LIST for the vault push, so the claim index rides the bare
// vault head -- the scope that is sealed every cycle and read at every login. Nothing here assumes that; a
// push with no held list simply publishes what it read, which is how every other scope leaves it alone.

// fileHeldList is the packages THIS handset currently holds, as written by the chooser and pointed at by
// roamd. Absent or unreadable means "hold nothing", which is the safe direction: a handset that cannot say
// what it holds must not hold anything, or a stale file would keep another device locked out.
func fileHeldList() []string {
	p := os.Getenv("NOWHERE_HELD_LIST")
	if p == "" {
		return nil
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return nil
	}
	var out []string
	seen := map[string]bool{}
	for _, ln := range strings.Split(string(b), "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" || strings.HasPrefix(ln, "#") || strings.ContainsAny(ln, "/\\") {
			continue
		}
		if !seen[ln] {
			seen[ln] = true
			out = append(out, ln)
		}
	}
	return out
}

// writeClaimsOut publishes, to a file the chooser reads, every package a LIVE claim assigns to ANOTHER unit.
// That is the enforcement list: exactly what this handset must refuse to launch.
//
// Written on every seal, and written EVEN WHEN EMPTY -- an empty file is the instruction to release, and
// skipping the write would leave the last non-empty list in place forever, so an app released on the other
// handset would stay shut here for the rest of the session. A file that only ever grows is how this design
// would stop being reversible.
//
// Best-effort: a failure here must never fail a seal. It costs the user a stale hold until the next cycle,
// which the TTL bounds anyway.
func writeClaimsOut(m map[string]appClaim, unit string, now int64) {
	writeClaimsOutNamed(m, unit, now, nil)
}

// writeClaimsOutNamed is writeClaimsOut with the holders' names (holderNames): the seal's call (h54 #1).
func writeClaimsOutNamed(m map[string]appClaim, unit string, now int64, names map[string]string) {
	p := os.Getenv("NOWHERE_CLAIMS_OUT")
	if p == "" {
		return
	}
	writeClaimsToNamed(p, m, unit, now, true, names)
}

// writeClaimsTo is writeClaimsOut's writer with the path as a parameter, and it returns how many packages it
// wrote and the error of the write that failed. The seal passes adopt=true, so the file lands owned by the
// chooser's uid. The sign-in seed passes adopt=false: it lands in roamd's tmpfs, and roamd installs it into
// the chooser's files dir with the owner of record once the roam-in deletes are done.
func writeClaimsTo(p string, m map[string]appClaim, unit string, now int64, adopt bool) (int, error) {
	return writeClaimsToNamed(p, m, unit, now, adopt, nil)
}

// writeClaimsToNamed is writeClaimsTo with the holders' names. A line is `pkg\tunit\tname` when names[unit] is
// set, else `pkg\tunit`. The seal passes holderNames (h54 #1); the sign-in seed passes none and stays two
// columns (moderator ruling 2026-11-03), so a package held at sign-in keeps "your other device" until released.
func writeClaimsToNamed(p string, m map[string]appClaim, unit string, now int64, adopt bool, names map[string]string) (int, error) {
	held := claimsHeldByOthers(m, unit, now)
	var sb strings.Builder
	sb.WriteString("# pkg\tunit -- written by the seal; empty means nothing is held elsewhere\n")
	rels := make([]string, 0, len(held))
	for pkg := range held {
		rels = append(rels, pkg)
	}
	sort.Strings(rels) // deterministic, so an unchanged claim set produces an unchanged file
	for _, pkg := range rels {
		sb.WriteString(pkg)
		sb.WriteString("\t")
		sb.WriteString(held[pkg])
		if n := names[held[pkg]]; n != "" {
			sb.WriteString("\t")
			sb.WriteString(n)
		}
		sb.WriteString("\n")
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, []byte(sb.String()), 0o600); err != nil {
		return 0, err
	}
	// ⚠ THE READER IS AN APP, NOT ROOT, AND UNTIL NWP-20260911-02 IT COULD NOT OPEN THIS FILE AT ALL.
	// The seal runs as root (`nowhere.rc`: user root, seclabel u:r:su:s0) and this file lands inside the
	// CHOOSER's own files dir, so the 0600 file written above is root:root and the chooser's app uid gets
	// EACCES. AppClaim.readClaims used to swallow that as "nothing is held elsewhere", so the enforcement
	// was INERT: no claim was ever read, so no hold was ever taken, so the receipt was never written, so
	// the release arm was never reached either -- while roamd went on logging "claims: N package(s) held
	// elsewhere" and every layer reported success.
	//
	// ⚠ AND THE HAZARD IS THE OTHER DIRECTION, WHICH THIS COMMENT ORIGINALLY GOT BACKWARDS (corrected in
	// NWP-20260912-03, same night, by an audit of what had just merged). Because an empty record is the
	// instruction to RELEASE, a failed read WOULD drop every hold a session was holding -- and the same bug
	// guaranteed it was holding none. Saying it "dropped every hold, on every device" turned a prospective
	// hazard into observed history, and the device evidence four lines below refutes it: the applier never
	// ran once and no receipt was ever written. The chooser half of the fix is what forecloses the hazard.
	//
	// Device-proven on lynx 2026-09-11, both directions: root-owned, the applier never ran once across an
	// evening of claim cycles and no receipt was ever written; chowned to the app uid, it suspended the
	// package on the first kick and released it on the next. Same shape as the keystore import dir, where
	// root:root 0700 blocked try_import silently (DIA-20260729, `nowhere_roamd.sh`).
	//
	// BEFORE THE RENAME, so the file is never visible to the reader under the wrong owner.
	if adopt {
		adoptOwnerOf(filepath.Dir(p), tmp)
	}
	if os.Rename(tmp, p) != nil {
		err := os.WriteFile(p, []byte(sb.String()), 0o600)
		if adopt {
			adoptOwnerOf(filepath.Dir(p), p)
		}
		os.Remove(tmp)
		if err != nil {
			return 0, err
		}
	}
	return len(held), nil
}

// seedClaimsAtRestore stages, for roamd to install, the claim file a sign-in starts with: the same bytes the
// seal would write from the map the bare-vault restore has just decrypted, so enforcement has something to
// read before this handset's first seal. NWP-20261029-06.
//
// It does nothing unless roamd asked (NOWHERE_CLAIMS_SEED) and unless this is a restore of THIS unit's own
// head: a restore from another unit (NOWHERE_UNIT_SRC) opens a foreign point-in-time head, and its claims are
// not the truth about now. The caller passes only the bare vault. An EMPTY map is written too -- a header-only
// file means "hold nothing", which is the truth for a vault nobody has claimed from.
//
// Best-effort: a failure costs the first seal's worth of enforcement and must never fail a sign-in. The log
// carries a COUNT only, never a package name: roam.log sits outside every wipe.
func seedClaimsAtRestore(m map[string]appClaim) {
	p := os.Getenv("NOWHERE_CLAIMS_SEED")
	if p == "" || unitSrcOverride() != "" {
		return
	}
	n, err := writeClaimsTo(p, m, deviceUnitID(), time.Now().Unix(), false)
	if err != nil {
		fmt.Printf("restore: claims seed: NOT written (nothing is held until the first seal): %v\n", err)
		return
	}
	fmt.Printf("restore: claims seed: %d package(s) held by other handsets\n", n)
}

// chownFile is a SEAM, and it exists because the obvious test is inert: a test process cannot chown to
// another uid, and comparing the written file’s owner to its directory’s passes identically with and
// without the fix (both are the test user). Substituting this records that the call was MADE, with the
// directory's ids -- which is the thing that was missing.
var chownFile = os.Chown

// adoptOwnerOf gives path the uid/gid of dir, so a file the root seal writes into an app-private directory
// is readable by the app that owns it. A no-op when dir cannot be stat’d; LOUD when root itself is
// refused, because a silent failure here is precisely the outcome this function exists to end.
func adoptOwnerOf(dir, path string) {
	st, err := os.Stat(dir)
	if err != nil {
		return
	}
	sys, ok := st.Sys().(*syscall.Stat_t)
	if !ok {
		return
	}
	if err := chownFile(path, int(sys.Uid), int(sys.Gid)); err != nil && os.Geteuid() == 0 {
		// Says what the chooser will actually DO, not what it used to: since NWP-20260911-02 an unreadable
		// record returns null rather than an empty map, and applyFromFile then changes nothing. This line
		// prints at the exact moment someone is debugging a failed handoff, so it must not describe the
		// behaviour of the version it replaced.
		fmt.Fprintf(os.Stderr, "claims: %s could not be given to uid %d -- the chooser cannot read it, so it "+
			"will change nothing this cycle: no new hold is taken and any hold already in force stays: %v\n",
			path, sys.Uid, err)
	}
}
