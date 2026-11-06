package main

import (
	"archive/tar"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// NWP-20261008-03: slice 3a of protecting a tied profile's scopes (docs/tie-scope-keys.md §9). `#media` and `#apps`
// are re-keyed to the chip in the BACKGROUND, in batches, because they can be gigabytes: the small-scope re-key
// (prepareScopeRekey) re-seals a whole scope inside one capWrite bracket, which buffers it all in memory, and a
// deferred chunk is not on the phone at all. A batch re-seals a bounded slice of the scope's chunks, uploads it in
// its own bracket, and records how far it got in the scope's index entry, so a sign-out halfway loses nothing:
//
//	scopeRec.Next      the new key K', wrapped under kekScopes(DK) -- minted by the first batch, reused after
//	scopeRec.Progress  a record sealed under K': every old chunk hash already re-sealed, and its new blob
//
// Wrapped keeps the current key until the switch, so every existing reader, seal, credential change and recovery
// sees the scope exactly as before. The footprint leases the record and every chunk it maps (addRekeyProgress), so
// work done across sessions is not reaped by the gateway GC before the switch. The switch itself is the small
// scopes' crash-safe order: the vault with {Wrapped: K', Prev: K, Minted}, then the head as an se-only vault.

// largeScopes are the scopes a tie re-keys in the background (the 2026-10-06 decision: the small three at tie
// time, photos and files and installed apps after).
var largeScopes = []string{"#media", "#apps"}

// rekeyBatchBytes bounds one batch: what it holds in memory (the bracket buffers its uploads) and how long it keeps
// the worker slot from a seal. A var so a test can make a small scope span several batches.
var rekeyBatchBytes int64 = 16 << 20

// rekeyProgress is the record a batch leaves behind, sealed under K'.
type rekeyProgress struct {
	Chunks map[string]rekeyedChunk `json:"chunks"`
}

// rekeyedChunk is one old chunk's re-sealed blob under K', with its stored size (so the footprint leases it
// without a store round trip per chunk).
type rekeyedChunk struct {
	H string `json:"h"`
	N int64  `json:"n"`
}

// rekeyStep is what one call of largeScopeRekeyStep did.
type rekeyStep struct {
	Suf         string
	Done, Total int64 // sealed bytes of the scope's chunks: re-sealed so far, and in all
	Switched    bool  // the head is now an se-only vault under K' (this call, or already)
	Batched     bool  // this call uploaded a batch
}

// rekeyAfterRead is nil in production. A test sets it to move the vault or the scope head between a step's reads and
// its publish.
var rekeyAfterRead func()

// errNoScopeIndex: the vault has no scope index yet, so there is nowhere to record a re-key. The next bare seal
// mints one (NWP-20260915-02); the job waits for it.
var errNoScopeIndex = errors.New("no scope index yet")

// largeScopeRekeyStep runs ONE step of the background re-key of scope suf: a batch if chunks remain, otherwise the
// switch. The caller holds the worker slot. It requires the vault to open through this phone's chip -- a tied
// session -- and answers errNotTiedHere otherwise.
func largeScopeRekeyStep(base, name, pass string, se []byte, suf string) (st rekeyStep, err error) {
	st.Suf = suf
	err = recovered(func() {
		// NWP-20261009-07: hd is what was read -- the value at the vault ref it writes first, then the vault -- and
		// each bracket below opens with capHoldHead(hd): another phone's batch, or any publisher in this process
		// that ran while this step waited for the lock, refuses the step rather than being overwritten by it.
		// The readings are the bracket's own, and disarmed before it ends (capExpect), not after.
		hd, v, verr := readSessionVaultHead(base, name, pass)
		if verr != nil {
			panic(verr)
		}
		dk := unwrapDK(v, "se", kekSE(name, pass, se))
		if dk == nil || len(se) == 0 {
			panic(errNotTiedHere)
		}
		idx, ok := openScopeIndex(dk, v.Scopes)
		if !ok {
			panic(errNoScopeIndex)
		}
		kek := kekScopes(dk)
		rec := idx[suf]
		scoped := name + suf
		writeRef, _ := headWriteRef(scoped, pass)
		writeOld := getRef(base, writeRef)
		_, head, have := headRef(base, scoped, pass)
		if !have {
			head = getRef(base, writeRef)
		}
		if rekeyAfterRead != nil {
			rekeyAfterRead() // tests only: another phone's batch, or a seal, landing between our reads and our publish
		}

		var oldKey []byte
		var ov *vault
		if head == "" {
			if refExists(base, writeRef) {
				panic(fmt.Errorf("%s: its ref is a delete tombstone", suf))
			}
		} else if hv, isV := parseVault(getHeadBlob(base, head)); isV {
			if scopeTiedHere(hv, scoped, pass, se) != nil {
				st.Switched = true // already protected on this phone
				if rec.Next != "" || rec.Progress != "" {
					// The switch landed: only now is it safe to forget the job (see the switch below).
					rec.Next, rec.Progress = "", ""
					idx[suf] = rec
					vd := capWrite(name, pass, dk, func() {
						if !capHoldHead(base, "re-key step", hd) {
							capAbort()
							return
						}
						v.Scopes = sealScopeIndex(dk, idx)
						publishSessionVaultIn(base, name, pass, v, dk)
					})
					if vd.Refused() {
						panic(errors.New("refused at publish: the store did not accept the new head"))
					}
				}
				return
			}
			oldKey = openVaultDKSE(hv, scoped, pass, se)
			if oldKey == nil {
				panic(fmt.Errorf("%s: no slot opens its head", suf))
			}
			if hv.Sig != "" && !verifyVault(hv, oldKey) {
				panic(fmt.Errorf("%s: its head does not verify", suf))
			}
			ov = hv
		} else {
			oldKey = deriveKey(scoped, pass) // a bare head IS the manifest, sealed under the passphrase key
		}

		newKey := randBytes(32)
		if rec.Next != "" {
			k, ok := unwrap(kek, rec.Next)
			if !ok {
				panic(fmt.Errorf("%s: the recorded re-key does not open under this profile's key", suf))
			}
			newKey = k
		}
		prog := rekeyProgress{Chunks: map[string]rekeyedChunk{}}
		if rec.Progress != "" {
			if err := recovered(func() {
				check(json.Unmarshal(unseal(newKey, getBlob(base, rec.Progress)), &prog))
			}); err != nil || prog.Chunks == nil {
				// An unreadable record (reaped, say, after a long pause) only costs the work it described: start over
				// under the same K', and every chunk already uploaded dedups at the flush.
				fmt.Fprintf(os.Stderr, "[agent] rekey %s: progress record unreadable (%s) -- starting the map again\n", suf, logSafeErrText(err))
				prog = rekeyProgress{Chunks: map[string]rekeyedChunk{}}
			}
		}

		// The old chunks the head names: the live manifest, its deferred regions, every retained snapshot.
		var manifests []string
		if ov != nil {
			manifests = append(manifests, ov.Manifest)
			for _, sn := range ov.History {
				manifests = append(manifests, sn.Manifest)
			}
		} else if head != "" {
			manifests = append(manifests, head)
		}
		var todo []string
		sizes := map[string]int64{}
		for _, mh := range manifests {
			for _, c := range manifestChunkSizes(base, oldKey, mh) {
				if _, seen := sizes[c.H]; seen {
					continue
				}
				sizes[c.H] = c.N
				st.Total += c.N
				if _, done := prog.Chunks[c.H]; done {
					st.Done += c.N
				} else {
					todo = append(todo, c.H)
				}
			}
		}

		if len(todo) > 0 {
			// A batch: re-seal up to rekeyBatchBytes of what is left, record it, publish the vault.
			vd := capWrite(name, pass, dk, func() {
				if !capHoldHead(base, "re-key step", hd) { // another phone's batch, or a verb here: refuse, the next step re-reads
					capAbort()
					return
				}
				var n int64
				for _, h := range todo {
					if n >= rekeyBatchBytes {
						break
					}
					sb := seal(newKey, unseal(oldKey, getChunk(base, h)))
					prog.Chunks[h] = rekeyedChunk{H: postBlob(base, sb), N: int64(len(sb))}
					n += int64(len(sb)) // what this batch holds, whether or not the manifest knew the size
					st.Done += sizes[h]
				}
				js, err := json.Marshal(prog)
				check(err)
				rec.Next = wrap(kek, newKey)
				rec.Progress = postBlob(base, seal(newKey, js))
				idx[suf] = rec
				v.Scopes = sealScopeIndex(dk, idx)
				publishSessionVaultIn(base, name, pass, v, dk)
			})
			if vd.Refused() {
				panic(errors.New("refused at publish: the store did not accept the new head"))
			}
			st.Batched = true
			fmt.Fprintf(os.Stderr, "[agent] rekey %s: %d of %d bytes (NWP-20261008-03)\n", suf, st.Done, st.Total)
			return
		}

		// The switch: every chunk is mapped. Build the manifests under K' from the map, then publish in the
		// crash-safe order -- the vault carrying {Wrapped: K', Prev: K, Minted}, then the scope head.
		vd := capWrite(name, pass, dk, func() {
			if !capHoldHead(base, "re-key step", hd) {
				capAbort()
				return
			}
			var manifest string
			var history []headSnap
			if head == "" {
				// A scope never sealed gets a placeholder, an empty archive under K', or its first seal would
				// create a passphrase-keyed head (as prepareScopeRekey does for the small scopes).
				var buf bytes.Buffer
				tw := tar.NewWriter(&buf)
				tw.Close()
				manifest = postBlob(base, seal(newKey, buf.Bytes()))
			} else {
				manifest = remapManifest(base, oldKey, newKey, manifests[0], prog.Chunks)
				if ov != nil {
					for _, sn := range ov.History {
						sn.Manifest = remapManifest(base, oldKey, newKey, sn.Manifest, prog.Chunks)
						history = append(history, sn)
					}
				}
			}
			var cur uint64
			if ov != nil {
				cur = ov.Version
			}
			nv := &vault{V: 1, Slots: []keyslot{{Kind: "se", Wrapped: wrap(kekSE(scoped, pass, se), newKey)}},
				Manifest: manifest, History: history, Version: scopeVersion(scoped, pass, cur), Hardened: true}
			signVault(nv, newKey)
			newHead := postBlob(base, serializeVault(nv))
			rec.Ref, rec.Wrapped, rec.Minted, rec.Observed = writeRef, wrap(kek, newKey), true, true
			rec.Prev = ""
			if oldKey != nil {
				rec.Prev = wrap(kek, oldKey)
			}
			// Next and Progress STAY until a later step sees the head switched. A refused pointer skips only itself
			// (capFlush), so if a seal moved the head since we read it, this vault still lands while the head does
			// not -- and a job cleared here would start over under a fresh key and pay for every upload again.
			idx[suf] = rec
			v.Scopes = sealScopeIndex(dk, idx)
			publishSessionVaultIn(base, name, pass, v, dk)
			capExpect("re-key step", writeRef, writeOld) // a seal of this scope since we read it: refuse, the next step maps the rest
			putHead(base, scoped, pass, newHead)
		})
		if vd.Refused() {
			panic(errors.New("refused at publish: the store did not accept the new head"))
		}
		st.Switched = true
		fmt.Fprintf(os.Stderr, "[agent] rekey %s: switched to the chip (NWP-20261008-03)\n", suf)
	})
	return st, err
}

// manifestChunkSizes lists the chunks a manifest names -- its own chunks and its deferred regions -- each with its
// sealed size from the manifest (0 when a pre-#85 manifest carries none). A legacy pre-CDC head (the blob is the
// archive itself) names no chunks: the switch re-seals it whole.
func manifestChunkSizes(base string, key []byte, manifestHash string) []rekeyedChunk {
	if manifestHash == "" {
		return nil
	}
	pt := unseal(key, getBlob(base, manifestHash))
	if !bytes.HasPrefix(pt, cdcMagic) {
		return nil
	}
	var m chunkManifest
	if err := json.Unmarshal(pt[len(cdcMagic):], &m); err != nil {
		panic(fmt.Errorf("a manifest decrypts but will not parse: %v", err))
	}
	var out []rekeyedChunk
	for i, h := range m.Chunks {
		var n int64
		if len(m.Sizes) == len(m.Chunks) {
			n = m.Sizes[i]
		}
		out = append(out, rekeyedChunk{H: h, N: n})
	}
	for _, rel := range sortedDeferredRels(m.Deferred) {
		d := m.Deferred[rel]
		for i, h := range d.Chunks {
			var n int64
			if len(d.Sz) == len(d.Chunks) {
				n = d.Sz[i]
			}
			out = append(out, rekeyedChunk{H: h, N: n})
		}
	}
	return out
}

// sortedDeferredRels is a deferred index's paths in a stable order, so batches walk a scope the same way each time.
func sortedDeferredRels(d map[string]deferredFile) []string {
	out := make([]string, 0, len(d))
	for rel := range d {
		out = append(out, rel)
	}
	sort.Strings(out)
	return out
}

// remapManifest re-seals one manifest under newKey with every chunk replaced by its re-sealed blob from the map.
// A chunk the map lacks means the head moved after the map was built; that is a panic, and the next step maps it.
// A legacy pre-CDC head is re-sealed whole, as resealManifest does.
func remapManifest(base string, oldKey, newKey []byte, manifestHash string, mapped map[string]rekeyedChunk) string {
	if manifestHash == "" {
		return ""
	}
	pt := unseal(oldKey, getBlob(base, manifestHash))
	if !bytes.HasPrefix(pt, cdcMagic) {
		return postBlob(base, seal(newKey, pt))
	}
	var m chunkManifest
	if err := json.Unmarshal(pt[len(cdcMagic):], &m); err != nil {
		panic(fmt.Errorf("a manifest decrypts but will not parse: %v", err))
	}
	to := func(h string) string {
		c, ok := mapped[h]
		if !ok {
			panic(fmt.Errorf("chunk %s is not re-sealed yet", short(h)))
		}
		return c.H
	}
	for i, h := range m.Chunks {
		m.Chunks[i] = to(h)
	}
	for rel, d := range m.Deferred {
		cs := make([]string, len(d.Chunks))
		for i, h := range d.Chunks {
			cs[i] = to(h)
		}
		d.Chunks = cs
		m.Deferred[rel] = d
	}
	js, err := json.Marshal(m)
	check(err)
	out := append(append([]byte{}, cdcMagic...), js...)
	return postBlob(base, seal(newKey, out))
}

// addRekeyProgress leases a re-key in flight: the progress record of every scope with one, and each chunk it maps
// (docs/tie-scope-keys.md §9 -- otherwise the GC reaps work done across sessions before the switch). Best-effort
// like the rest of the footprint: an unreadable record leases nothing. A record read that fails in transport raises
// errStoreUnreachable like the footprint's head reads (footprintSkip, NWP-20261117-14).
func addRekeyProgress(base string, dk []byte, sealedIndex string, refs map[string]int64) {
	idx, ok := openScopeIndex(dk, sealedIndex)
	if !ok {
		return
	}
	kek := kekScopes(dk)
	for _, suf := range scopeIndexSuffixesSorted(idx) {
		rec := idx[suf]
		if rec.Next == "" || rec.Progress == "" {
			continue
		}
		func() {
			defer footprintSkip()
			k, ok := unwrap(kek, rec.Next)
			if !ok {
				return
			}
			pb := getBlob(base, rec.Progress)
			refs["blob/"+rec.Progress] = int64(len(pb))
			var p rekeyProgress
			if json.Unmarshal(unseal(k, pb), &p) != nil {
				return
			}
			for _, c := range p.Chunks {
				refs["blob/"+c.H] = c.N
			}
		}()
	}
}

// clearRekeyJobs drops every re-key in flight from an index (an untie: nothing was switched, and the uploaded
// blobs simply lapse). Reports whether anything was cleared.
func clearRekeyJobs(idx map[string]scopeRec) bool {
	cleared := false
	for suf, rec := range idx {
		if rec.Next != "" || rec.Progress != "" {
			rec.Next, rec.Progress = "", ""
			idx[suf] = rec
			cleared = true
		}
	}
	return cleared
}

// ---- the daemon side: when the job runs ----

// rekeyArmedFile is the gate's go-ahead, written by REKEY-ARM as "<uid>": the network the profile allows (Wi-Fi, or
// any when its "download over mobile data" switch is on) and a battery at 20% or more or charging -- Chester's two
// decisions of 2026-10-08. The chooser judges both; the daemon only obeys. The uid ties it to one session.
const rekeyArmedFile = "rekey.armed"

func rekeyArmedFor(dest, uid string) bool {
	b, err := os.ReadFile(filepath.Join(dest, rekeyArmedFile))
	return err == nil && uid != "" && strings.TrimSpace(string(b)) == uid
}

// rekeyWaitFile is why the gate is NOT arming (NWP-20261008-04), written by REKEY-WAIT-* as "<uid> <reason>": wifi (no
// Wi-Fi and the profile does not allow mobile data), net (no connection at all), battery (under 20% and not
// charging). The gate judged it, so the Tie screen can say it rather than guess.
const rekeyWaitFile = "rekey.wait"

// rekeyWaitFor is this session's waiting reason, or "" when none is recorded.
func rekeyWaitFor(dest, uid string) string {
	b, err := os.ReadFile(filepath.Join(dest, rekeyWaitFile))
	if err != nil || uid == "" {
		return ""
	}
	f := strings.Fields(string(b))
	if len(f) != 2 || f[0] != uid {
		return ""
	}
	return f[1]
}

// rekeyState is the last thing the job knows per scope, for the Tie screen (SE-PROGRESS). rekeyStateUID is the
// session it describes: every login mints a new user, so a value from an earlier session is never shown for this one.
var (
	rekeyStateMu  sync.Mutex
	rekeyState    = map[string]rekeyStep{}
	rekeyStateUID string
	rekeyLastErr  error
)

// rekeyTick is how often the daemon looks for re-key work. One batch per tick, so a seal never waits behind more
// than one.
var rekeyTick = 20 * time.Second

// sessionVerbsInFlight counts the session verbs pending in the daemon that publish under a reply deadline -- see
// rekeyHoldingVerb -- from before they wait for sessionMu until they have answered (NWP-20261009-07). A re-key batch
// holds capBracketMu for a 16 MiB fetch, re-seal and upload, and every one of those verbs opens a bracket, so one
// that waited behind a string of batches could answer after its client had stopped reading. rekeyOnce starts no
// batch while any is pending, which bounds the wait at the one batch that may already be open.
var sessionVerbsInFlight atomic.Int32

// rekeyHoldingVerb reports whether daemon verb name holds the re-key off while it is pending: the verbs that open a
// cap bracket under sessionMu with a client waiting on the reply. DELETE joined them with NWP-20261010-02, whose
// purge of the data export is a bracket of its own; it answers BUSY rather than wait for sessionMu, so the
// dispatcher counts it once it holds the lock. END-UNSAVED joined them with NWP-20261010-10: it saves the wallet in
// a bracket of its own before it ends the session, and it too answers BUSY rather than wait. RESTART-UNSAVED likewise. DELETE-SNAPSHOT (NWP-20261027-04) reseals the
// vault in a bracket of its own, as ROLLBACK does. ROTATE, SET-PIN and FIDO2-NFC-ENROLL-FINISH now answer BUSY
// rather than wait (NWP-20261124-10), so the dispatcher counts them once it holds the lock, as DELETE.
func rekeyHoldingVerb(name string) bool {
	switch name {
	case "ROTATE", "SET-PIN", "REMOVE-FIDO2-KEY", "FIDO2-NFC-ENROLL-FINISH", "ROLLBACK", "DELETE-SNAPSHOT", "EXPORT", "EXPORT-MEDIA", "DELETE", "END-UNSAVED", "RESTART-UNSAVED":
		return true
	}
	return false
}

// rekeyLoop runs the background re-key for the live session, one batch per tick, whenever the gate has armed it and
// nothing else needs the worker slot. Started once with the daemon.
func rekeyLoop(dest string) {
	for {
		time.Sleep(rekeyTick)
		rekeyOnce(dest)
	}
}

// rekeyOnce is one tick of rekeyLoop. It stands down for anything that must not be delayed by a batch: a sign-out,
// a reap or switch, a seal, a cold lock, a throwaway session, a session verb pending (sessionVerbsInFlight) -- and
// for an unarmed gate. The worker slot is only TRIED: a seal holding it wins, and the job comes back next tick.
func rekeyOnce(dest string) {
	name, pass, uid := readRoamSession(dest)
	if name == "" || uid == "" || localOnlySession(dest) || !rekeyArmedFor(dest, uid) {
		return
	}
	se := seFromSession(dest)
	if len(se) == 0 {
		return // no chip, so no tie to finish
	}
	pendingReapMu.Lock()
	busy := sealInFlight || pendingReapUID != "" || pendingSwitchUID != ""
	pendingReapMu.Unlock()
	if busy || coldLockInFlight() || sessionVerbsInFlight.Load() > 0 {
		return
	}
	select {
	case laneRW.slot <- struct{}{}:
	default:
		return
	}
	defer func() { <-laneRW.slot }()
	rekeyStateMu.Lock()
	if rekeyStateUID != uid {
		rekeyStateUID, rekeyState, rekeyLastErr = uid, map[string]rekeyStep{}, nil
	}
	rekeyStateMu.Unlock()
	for _, suf := range largeScopes {
		st, err := largeScopeRekeyStep("s3", name, pass, se, suf)
		rekeyStateMu.Lock()
		if err == nil {
			rekeyState[suf] = st
		}
		rekeyLastErr = err
		rekeyStateMu.Unlock()
		if err != nil {
			if !errors.Is(err, errNotTiedHere) && !errors.Is(err, errNoScopeIndex) {
				fmt.Fprintf(os.Stderr, "[logind] rekey %s: %s\n", suf, logSafeErrText(err)) // never the name
			}
			return
		}
		if st.Batched || (st.Switched && st.Total > 0) {
			return // one unit of work per tick: the next scope waits for the next tick
		}
	}
}

// seProgressReply answers SE-PROGRESS for the Tie screen (NWP-20261008-04): "OK NONE" when the profile is not tied,
// otherwise "OK" and one line per large scope, "<MEDIA|APPS> <state> <done> <total>" (bytes), state one of
//
//	done      the scope opens only through this phone's chip
//	running   the gate has armed the job; done/total are the job's last step this session (0 0 before its first)
//	wifi, net, battery   the gate is holding it back, and why
//	credit    the profile's storage plan has no room for the re-saved data
//	waiting   not armed, and no reason recorded yet
//
// ⚠ IT ANSWERS WITHOUT THE STORE (NWP-20261008-05). The checks against the store -- is the profile tied, is a scope
// switched -- fail exactly when the phone has no connection, and that is when the screen most needs the gate's
// reason: on lynx 2026100802, Wi-Fi off and the LTE link carrying IMS only, every poll answered ERR, the screen
// kept its last "protecting… n%" line, and "waiting for Wi-Fi" never showed. So an unreachable store answers from
// what this session already knows: a scope it has seen switched stays done (rememberSwitched), the rest take the
// gate's state. The screen polls only while it shows a tied profile, so "tied" is not in doubt there.
func seProgressReply(base, name, pass, uid string, se []byte, dest string) string {
	// The store read PANICS on a refused connection rather than returning an error (capGet's fail), and handleLogin's
	// recover() would then close the connection with no reply at all -- which is what the screen saw. Contain it here.
	var st string
	err := recovered(func() {
		var serr error
		if st, serr = seSessionStatus(base, name, pass, se); serr != nil {
			panic(serr)
		}
	})
	reachable := err == nil
	if reachable && st != seStatusTied && st != seStatusPartial {
		forgetSwitched(uid) // untied: nothing this session saw switched is switched any more
		return "OK NONE\n"
	}
	rekeyStateMu.Lock()
	known := map[string]rekeyStep{}
	var lastErr error
	if rekeyStateUID == uid {
		for k, v := range rekeyState {
			known[k] = v
		}
		lastErr = rekeyLastErr
	}
	rekeyStateMu.Unlock()
	var b strings.Builder
	b.WriteString("OK\n")
	for _, suf := range largeScopes {
		label := strings.ToUpper(strings.TrimPrefix(suf, "#"))
		if known[suf].Switched || (reachable && scopeTiedOnThisPhone(base, name+suf, pass, se)) {
			rememberSwitched(uid, suf)
			fmt.Fprintf(&b, "%s done 0 0\n", label)
			continue
		}
		s := known[suf]
		state := "waiting"
		switch {
		case lastErr != nil && errors.Is(lastErr, errInsufficientCredit):
			state = "credit"
		case rekeyArmedFor(dest, uid):
			state = "running"
		case rekeyWaitFor(dest, uid) != "":
			state = rekeyWaitFor(dest, uid)
		}
		fmt.Fprintf(&b, "%s %s %d %d\n", label, state, s.Done, s.Total)
	}
	return b.String()
}

// rememberSwitched records that this session has seen scope suf switched, so SE-PROGRESS can still say "done" when
// the store cannot be reached.
func rememberSwitched(uid, suf string) {
	rekeyStateMu.Lock()
	defer rekeyStateMu.Unlock()
	if rekeyStateUID != uid {
		rekeyStateUID, rekeyState, rekeyLastErr = uid, map[string]rekeyStep{}, nil
	}
	st := rekeyState[suf]
	st.Suf, st.Switched = suf, true
	rekeyState[suf] = st
}

// forgetSwitched drops what this session remembered as switched (an untie re-opens every scope by passphrase).
func forgetSwitched(uid string) {
	rekeyStateMu.Lock()
	defer rekeyStateMu.Unlock()
	if rekeyStateUID == uid {
		for suf, st := range rekeyState {
			st.Switched = false
			rekeyState[suf] = st
		}
	}
}

// tieFinishDelay is how long after a sign-in lands the daemon waits before finishing a partial tie, so it does not
// contend with the login's own tail (seed-home, armcred, the first periodic seal).
var tieFinishDelay = loginWindowTail + 5*time.Second

// finishTieAtSignIn re-keys the small scopes of a profile that is tied but not fully (TIED PARTIAL), once, after
// its sign-in lands (docs/tie-scope-keys.md §5 Q3, DECIDED: "at their next sign-in on the tied phone, once,
// automatically"). That is every profile tied before NWP-20261007-12. It is SE-TIE's own scope re-key, under the
// worker slot like SE-TIE, and a failure leaves TIED PARTIAL with the manual "Finish tying" on the Tie screen. The
// large scopes need nothing here: rekeyLoop picks them up for any tied session.
func finishTieAtSignIn(dest string) {
	time.Sleep(tieFinishDelay)
	name, pass, uid := readRoamSession(dest)
	if name == "" || uid == "" || localOnlySession(dest) {
		return
	}
	se := seFromSession(dest)
	if len(se) == 0 {
		return
	}
	// NWP-20261014-66: the status read is a store read, and a store read that cannot reach the store PANICS
	// (checkRead). Read outside daemonVaultErr, that panic ended the login daemon a few seconds after a sign-in whose
	// Wi-Fi had just dropped (lynx 2026101401), and the session went with it. Contained here, a read that fails
	// leaves the profile exactly as it was -- nothing has been written and the worker slot is not taken yet -- so it
	// stays TIED PARTIAL: the Tie screen still offers "Finish tying", and the next sign-in on this phone tries again.
	var st string
	err := daemonVaultErr(func() (e error) {
		st, e = seSessionStatus("s3", name, pass, se)
		return e
	})
	if errors.Is(err, errDaemonStore) {
		fmt.Fprintf(os.Stderr, "[logind] finish-tie user %s: the store could not be read -- left for Finish tying and the next sign-in (NWP-20261014-66)\n", uid)
		return
	}
	if err != nil || st != seStatusPartial {
		return
	}
	select {
	case laneRW.slot <- struct{}{}:
	case <-time.After(2 * time.Minute):
		fmt.Fprintf(os.Stderr, "[logind] finish-tie user %s: the worker stayed busy -- left for Finish tying\n", uid)
		return
	}
	defer func() { <-laneRW.slot }()
	// The session may have ended while we waited: a sign-out's seal is what held the slot.
	if n2, _, u2 := readRoamSession(dest); n2 != name || u2 != uid || coldLockInFlight() {
		return
	}
	if err := daemonVaultErr(func() error { return sessionTie("s3", name, pass, se) }); err != nil {
		fmt.Fprintf(os.Stderr, "[logind] finish-tie user %s: %v -- left for Finish tying\n", uid, err) // never the name
		return
	}
	fmt.Fprintf(os.Stderr, "[logind] finish-tie user %s: the small scopes are tied (NWP-20261008-04)\n", uid)
}
