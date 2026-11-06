package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Multi-device account (#91, slice 1: ref derivation + the account directory). One identity (name, pass)
// used on several units (FP3, a future Pixel/Endospore, ...). DECISIONS (2026-07-03): per-UNIT identity
// (each physical device is its own lineage; a replacement phone = a new enrollment + clone), so each unit
// SEALS TO ITS OWN HEAD (dissolves the split-brain the single head had, relaxing #73 to per-lineage). App
// data (CE/DE) stays per-unit ALWAYS (schema-coupled to the app/Android version; a live cross-unit merge
// would corrupt), surfaced as a point-in-time restore from that unit's tab. The MEDIA tree is shared at the
// ACCOUNT level (the CE/#de/#media seal split already drew that seam). Prefs + wallet are per-unit.
//
// All refs derive from K = deriveKey(name, pass) (the #80 Argon2 key, memoized -> free) with distinct HMAC
// domains -- no store existence oracle, and a fresh device re-derives every ref from name+pass alone.
//
// This file is the PURE data model + derivations; wiring it into login/seal/the tabbed Restore UI is a later
// slice (kept isolated + unit-tested first, like the #80 refs and the #81 vault slot).

// unitHeadRef is where a specific UNIT's head lives -- the per-lineage analog of profileRefV2. unitID is the
// stable per-device id (a random id minted at enrollment, carried in the account directory with its label).
func unitHeadRef(name, pass, unitID string) string {
	mac := hmac.New(sha256.New, deriveKey(name, pass))
	mac.Write([]byte("nowhere-unit-head-v1\x00"))
	mac.Write([]byte(unitID))
	return hex.EncodeToString(mac.Sum(nil))
}

// accountDirRef is the account directory's location: the small object listing every unit (id + label +
// head ref) and the shared-media ref. Written at enrollment/clone; read to populate the tabbed Restore.
func accountDirRef(name, pass string) string {
	mac := hmac.New(sha256.New, deriveKey(name, pass))
	mac.Write([]byte("nowhere-account-dir-v1"))
	return hex.EncodeToString(mac.Sum(nil))
}

// NWP-20260907-23: sharedMediaRef IS GONE, and nothing should reintroduce it. It derived an ACCOUNT-level
// media head for slice 5b to promote <name>#media into -- but #media is ALREADY one shared ref that both
// lineages read and write (isPerUnitRef excludes it under both flag settings), so the promotion would have
// moved a shared head to a differently-named shared head and changed nothing. Slice 5b itself is withdrawn:
// see docs/multi-device.md slice 5 for what two handsets actually do to each other's media, measured.

// unitEntry is one lineage in the account directory.
type unitEntry struct {
	ID      string `json:"id"`                // stable per-unit id (minted at enrollment)
	Label   string `json:"label"`             // user-editable ("Chester's FP3", "Pixel 10")
	Edition string `json:"edition"`           // deviceEdition(): "diaspore" | "endospore", else the bare codename or "unknown" -- informational
	Added   int64  `json:"added"`             // unix time enrolled
	Retired bool   `json:"retired,omitempty"` // a replaced/lost unit kept for its restorable head, not offered as live
}

// accountDir is the directory object (sealed under DK before it hits the store, like every other head).
type accountDir struct {
	Version int         `json:"version"` // bumped on every mutation
	Units   []unitEntry `json:"units"`   // sorted by Added for a stable tab order
}

// newAccountDir starts a directory with the enrolling unit as the sole lineage.
func newAccountDir(u unitEntry) *accountDir {
	return &accountDir{Version: 1, Units: []unitEntry{u}}
}

// addUnit adds (or, by ID, replaces) a lineage and bumps the version. Idempotent on the same ID -- a
// re-clone updates the label/edition rather than duplicating the tab.
func (d *accountDir) addUnit(u unitEntry) {
	for i := range d.Units {
		if d.Units[i].ID == u.ID {
			d.Units[i] = u
			d.Version++
			d.sortUnits()
			return
		}
	}
	d.Units = append(d.Units, u)
	d.Version++
	d.sortUnits()
}

func (d *accountDir) sortUnits() {
	sort.SliceStable(d.Units, func(i, j int) bool { return d.Units[i].Added < d.Units[j].Added })
}

// liveUnits returns the non-retired lineages (the ones offered as live tabs; retired units still restore).
func (d *accountDir) liveUnits() []unitEntry {
	out := make([]unitEntry, 0, len(d.Units))
	for _, u := range d.Units {
		if !u.Retired {
			out = append(out, u)
		}
	}
	return out
}

// sealAccountDir / openAccountDir move the directory through the store as ciphertext under the identity DK
// (same convergent seal as every head, so the store learns only an opaque blob + the unguessable ref).
func sealAccountDir(dk []byte, d *accountDir) []byte {
	b, err := json.Marshal(d)
	check(err)
	return seal(dk, b)
}

func openAccountDir(dk, blob []byte) (*accountDir, bool) {
	defer func() { recover() }() // unseal fails loudly; treat a bad/foreign blob as "no directory"
	var d accountDir
	if err := json.Unmarshal(unseal(dk, blob), &d); err != nil {
		return nil, false
	}
	return &d, true
}

// --- slice 3: per-unit head model (GATED). headKey/putHead consult these so the risky migration ships OFF by
// default (existing single-device profiles byte-for-byte unchanged) and is proven on a test profile via the
// env flag before it becomes the default. ---

// multiDeviceEnabled gates the per-unit head model (#91 slice 3). OFF unless $NOWHERE_MULTIDEVICE=1. When off,
// headKey/putHead keep their exact legacy single-head behavior -- zero risk to shipped profiles.
func multiDeviceEnabled() bool {
	return os.Getenv("NOWHERE_MULTIDEVICE") == "1"
}

// isPerUnitRef reports whether a profile ref seals PER-UNIT (app data: name, name#de, name#wallet -- each
// device its own head, no cross-device clobber) vs account-SHARED (name#media, which stays at its legacy
// location permanently -- the slice-5 promotion this comment used to anticipate is withdrawn, NWP-20260907-23,
// so #media is account-shared HERE and nowhere else). name#apps (#199 captured
// app CODE) is likewise account-SHARED: the whole point is that a kept app reappears on a DIFFERENT device, so
// its head must be the single account head, not a per-device one (a per-unit #apps would never roam to a new
// phone).
func isPerUnitRef(name string) bool {
	return !strings.HasSuffix(name, "#media") && !strings.HasSuffix(name, "#apps")
}

// unitSrcOverride (#91 slice 4b): when NOWHERE_UNIT_SRC=<unitID> is set, headKey resolves the READ head from
// ANOTHER lineage's unit head -- the "restore from <device>" point-in-time restore. Safe cross-device: the
// pass-KEK is deterministic from (name,pass), so this device opens the source unit's vault -> its DK -> its
// chunks, regardless of its own head. WRITES (putHead) are NEVER overridden -- this device's seals always land
// on its OWN head, so the restore is a COPY, not a live link. roamd exports it only around the restore agent
// call, so a seal never sees it.
func unitSrcOverride() string {
	return os.Getenv("NOWHERE_UNIT_SRC")
}

// --- slice 2: THIS device's lineage identity + implicit enrollment into the account directory ---

// unitIDPath is where this device's stable lineage id persists. Device-local and PERSISTENT (NOT the per-boot
// tmpfs $STATE) so it survives reboots/power-off; a factory reset / reflash wipes it -> a new lineage, which
// is exactly "a replacement phone is a new enrollment + clone", not a resurrection. A var (not const) so a
// test can point it at a temp file.
var unitIDPath = "/data/nowhere/unit-id"

// deviceUnitID returns this device's stable unit id, minting + persisting one on first use. A readable
// unitIDPath is read on every call (no cache), so roamd's keystore_unit and the agent agree on the file.
// If it can't be read or persisted, fallbackUnitID gives ONE id for the whole boot, shared by every agent
// process through $NOWHERE_STATE/unit-id.boot (tmpfs, gone at power-off), and one id per process only when
// there is no state dir. It never blocks a login. A per-CALL id is not safe: pushProfile stamps every seal's
// claim index with this id (claimsToPublish, claimsHeldByOthers, writeClaimsTo in app_claim.go), and every
// seal is its own process, so a new id per call makes the next seal read this phone's own claims as another
// handset's live claims and hold its own apps shut.
func deviceUnitID() string {
	id, err := readOrMintUnitID(unitIDPath)
	if err == nil {
		return id
	}
	return fallbackUnitID(unitIDPath)
}

// readOrMintUnitID reads the id at path, or mints a random 128-bit id (0600) when absent/empty. The mint
// publishes FIRST-WRITER-WINS: the id goes to a synced temp in the same dir, then os.Link puts it at path,
// which never replaces a file. On EEXIST another process won (or a file appeared since the read), so the
// file's id is returned, never ours. An existing EMPTY file is replaced by os.Rename. A link the filesystem
// or policy refuses falls back to os.Rename only while path is still absent or empty, so such a phone still
// persists its id. A non-empty id is never rewritten in place. The temp is always removed.
// Every agent publish holds an exclusive flock on the directory and decides absent / empty / taken from a
// read made UNDER that lock, so a caller that saw the empty file before another caller replaced it returns
// the other caller's id instead of renaming over it. Without the lock (lockUnitIDDir failed) only the link
// publish runs, which needs no lock; a replace by rename then returns an error. A read error other than
// absence returns that error: an unreadable id is never replaced. Pure (takes the path) so it is unit-testable.
func readOrMintUnitID(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err == nil {
		if id := strings.TrimSpace(string(b)); id != "" {
			return id, nil
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return "", err
	}
	id := randomUnitID()
	f, err := os.CreateTemp(filepath.Dir(path), ".unit-id.*")
	if err != nil {
		return "", err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return "", err
	}
	if _, err := f.WriteString(id); err != nil {
		f.Close()
		return "", err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return "", err
	}
	if err := f.Close(); err != nil {
		return "", err
	}
	if unitIDBeforeLock != nil {
		unitIDBeforeLock(path)
	}
	unlock, lerr := lockUnitIDDir(filepath.Dir(path))
	locked := lerr == nil
	if locked {
		defer unlock()
	}
	cur, empty, err := unitIDFileState(path)
	if err != nil {
		return "", err
	}
	if cur != "" {
		return cur, nil
	}
	if unitIDBeforePublish != nil {
		unitIDBeforePublish(path)
	}
	if empty {
		return renameUnitID(tmp, path, locked)
	}
	err = unitIDLink(tmp, path)
	if err == nil {
		return id, nil
	}
	if errors.Is(err, fs.ErrExist) {
		return readUnitIDFile(path)
	}
	// The link was refused for another reason. Publish by rename, but only over an absent or empty path.
	if cur, _, err = unitIDFileState(path); err != nil {
		return "", err
	}
	if cur != "" {
		return cur, nil
	}
	return renameUnitID(tmp, path, locked)
}

// unitIDFileState reads path: its non-empty id, or empty=true for an existing blank file, or neither for an
// absent one. Any other read error is returned, so an unreadable id is never taken for absent.
func unitIDFileState(path string) (id string, empty bool, err error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	id = strings.TrimSpace(string(b))
	return id, id == "", nil
}

// renameUnitID publishes tmp over an absent or empty path. It runs only under the directory lock: a rename
// replaces whatever is there, so without the lock it could replace an id another caller already returned.
func renameUnitID(tmp, path string, locked bool) (string, error) {
	if !locked {
		return "", errors.New("unit-id: cannot replace the file without the directory lock")
	}
	if err := os.Rename(tmp, path); err != nil {
		return "", err
	}
	return readUnitIDFile(path)
}

// lockUnitIDDir takes an exclusive flock on dir, so the agent processes that mint an id in it publish one
// at a time. Both domains hold lock on nowhere_data_file dirs (create_dir_perms in nowhere.te and
// endospore.te). The returned func releases the lock.
func lockUnitIDDir(dir string) (func(), error) {
	d, err := os.Open(dir)
	if err != nil {
		return nil, err
	}
	for {
		err = syscall.Flock(int(d.Fd()), syscall.LOCK_EX)
		if err != syscall.EINTR {
			break
		}
	}
	if err != nil {
		d.Close()
		return nil, err
	}
	return func() {
		syscall.Flock(int(d.Fd()), syscall.LOCK_UN)
		d.Close()
	}, nil
}

// readUnitIDFile reads a published id back; a blank file is an error (the caller falls back).
func readUnitIDFile(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	id := strings.TrimSpace(string(b))
	if id == "" {
		return "", errors.New("unit-id: published file is empty")
	}
	return id, nil
}

func randomUnitID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// Test seams for readOrMintUnitID. unitIDBeforeLock (nil in production) runs after the temp is synced and
// closed, before the directory lock; unitIDBeforePublish (nil in production) runs under the lock, after the
// locked read, before the publish; unitIDLink is the publish call.
var (
	unitIDBeforeLock    func(path string)
	unitIDBeforePublish func(path string)
	unitIDLink          = os.Link
)

// unitFallback is the per-process tier of fallbackUnitID, keyed by the unitIDPath it fell back from so a
// test that swaps unitIDPath gets a fresh id. One logged flag for both tiers keeps its stderr line to one per
// process, naming the tier of the first fallback.
var unitFallback struct {
	mu       sync.Mutex
	from, id string
	logged   bool
}

// fallbackUnitID is deviceUnitID's id when unitIDPath cannot be read or persisted: the per-boot id at
// $NOWHERE_STATE/unit-id.boot (read-or-minted like unitIDPath, so every process of the boot shares it), else
// one random id for the life of this process. Its log lines are fixed text: never the id, never an error.
func fallbackUnitID(from string) string {
	unitFallback.mu.Lock()
	defer unitFallback.mu.Unlock()
	if unitFallback.from != from {
		unitFallback.from, unitFallback.id = from, ""
		unitFallback.logged = false
	}
	if state := os.Getenv("NOWHERE_STATE"); state != "" {
		if id, err := readOrMintUnitID(filepath.Join(state, "unit-id.boot")); err == nil {
			if !unitFallback.logged {
				unitFallback.logged = true
				fmt.Fprintln(os.Stderr, "[agent] unit-id: the persistent unit id could not be read or written; using the per-boot id in the state dir")
			}
			return id
		}
	}
	if unitFallback.id == "" {
		unitFallback.id = randomUnitID()
	}
	if !unitFallback.logged {
		unitFallback.logged = true
		fmt.Fprintln(os.Stderr, "[agent] unit-id: the persistent unit id could not be read or written and there is no usable state dir; using a per-process id")
	}
	return unitFallback.id
}

// resetUnitIDFallback clears the per-process tier; tests use it to model a second process.
func resetUnitIDFallback() {
	unitFallback.mu.Lock()
	defer unitFallback.mu.Unlock()
	unitFallback.from, unitFallback.id = "", ""
	unitFallback.logged = false
}

// deviceEditions maps every device-tree codename to its OS edition -- one row per
// editions/<edition>/devices/<codename> dir. TestEveryDeviceDirHasAnEdition walks that tree and fails CI when a
// device dir has no row, a row names the wrong edition, or a row names a device the tree no longer has.
var deviceEditions = map[string]string{
	"fp3":      "diaspore",
	"lynx":     "endospore",
	"frankel":  "endospore",
	"tegu":     "endospore",
	"stallion": "endospore",
	"husky":    "endospore",
}

// osRefPath is the baked per-device os-ref ("os-<codename>"); a var so tests can point it at a fixture.
var osRefPath = "/system/etc/nowhere/os-ref"

// osRefDefault is what a MISSING os-ref means: the FP3 bakes none (only Endospore's endospore.mk copies one, and
// build-device.sh refuses an image without it), so nowhere_otad.sh and otaVersionRef already read absence as
// os-fp3. TestEveryDeviceDirHasAnEdition pins that fp3 is the only device dir without a vendor/etc/os-ref.
const osRefDefault = "os-fp3"

// editionForOSRef maps os-ref contents ("os-<codename>", whitespace and the os- prefix optional) to the device's
// edition through deviceEditions. It never guesses: empty contents -> "unknown", and a codename with no row
// reports the codename itself, so an unlisted device shows what it is instead of borrowing another edition.
func editionForOSRef(osref string) string {
	dev := strings.TrimPrefix(strings.TrimSpace(osref), "os-")
	if dev == "" {
		return "unknown"
	}
	if e, ok := deviceEditions[dev]; ok {
		return e
	}
	return dev
}

// deviceEdition names this device's OS edition for the directory tab, overridable via $NOWHERE_EDITION.
// Otherwise it is editionForOSRef of the baked os-ref: a missing file is osRefDefault (the FP3), any other
// read failure is "unknown". Informational only.
func deviceEdition() string {
	if e := strings.TrimSpace(os.Getenv("NOWHERE_EDITION")); e != "" {
		return e
	}
	b, err := os.ReadFile(osRefPath)
	if errors.Is(err, fs.ErrNotExist) {
		return editionForOSRef(osRefDefault)
	}
	if err != nil {
		return "unknown"
	}
	return editionForOSRef(string(b))
}

// loadAccountDir reads + opens the account directory (nil,false when none exists yet or the DK doesn't fit).
func loadAccountDir(base, name, pass string, dk []byte) (*accountDir, bool) {
	ref := getRef(base, accountDirRef(name, pass))
	if ref == "" {
		return nil, false
	}
	blob := getBlob(base, ref)
	if len(blob) == 0 {
		return nil, false
	}
	return openAccountDir(dk, blob)
}

// writeAccountDir seals + stores the directory under accountDirRef. In cap mode the CALLER must wrap this in a
// capBegin/capFlush payment bracket (like every other store write); the ref is already KDF-derived, so there's
// no legacy-ref migration to do (unlike headKey/putHead).
func writeAccountDir(base, name, pass string, dk []byte, d *accountDir) {
	writeAccountDirGuarded(base, name, pass, dk, d, nil)
}

// writeAccountDirGuarded is writeAccountDir with mayWrite (nil = always) checked before each store write begins (h46
// #1, late_work.go): before the blob upload, and again after it returns and before the ref PUT, because the upload can
// block long enough for the late job to be abandoned. On the direct S3 path it is also asked before every request of
// both PUTs, retries included (s3PutGuarded). It reports whether the ref was written. In cap mode both writes only
// buffer; capFlush asks the bracket's own guard (capSetSessionMayWrite) before each real request and each retry.
func writeAccountDirGuarded(base, name, pass string, dk []byte, d *accountDir, mayWrite func() bool) bool {
	if !lateMayWrite(mayWrite) {
		return false
	}
	blob, ok := postBlobGuarded(base, sealAccountDir(dk, d), mayWrite)
	if !ok {
		return false
	}
	// putRefBytesGuarded asks the guard again before the ref PUT begins. When it says no, the blob just uploaded is
	// content-addressed and unreferenced: inert, collected at lease lapse.
	return putRefBytesGuarded(base, accountDirRef(name, pass), []byte(blob), mayWrite)
}

// defaultUnitLabel is the initial user-facing name for a lineage in the tabbed restore ("Diaspore · da4bf24d"):
// the capitalized edition plus a short id so an account's two same-edition devices are still distinguishable.
// Slice-4b UI lets the user rename it.
func defaultUnitLabel(edition, unitID string) string {
	e := edition
	if e != "" {
		e = strings.ToUpper(e[:1]) + e[1:]
	}
	short := unitID
	if len(short) > 8 {
		short = short[:8]
	}
	return strings.TrimSpace(e + " · " + short)
}

// enrollUnitAtLogin records THIS device in the account directory at login (#91 slice 4). GATED + best-effort:
// a failure must NEVER un-gate a valid login (recover()), and the directory write rides its OWN capWrite
// bracket -- in cap mode its payment bracket, as every cap-mode store write's is (the #45/#101 rule). Idempotent, so it's
// a one-time paid write per (account, device), not per login. No-op unless the per-unit head model is enabled.
func enrollUnitAtLogin(base, name, pass string, se []byte) {
	enrollUnitAtLoginGuarded(base, name, pass, se, nil)
}

// enrollUnitAtLoginGuarded is enrollUnitAtLogin as a sign-in's late step (h46 #1, late_work.go). mayWrite (nil =
// always) is checked FIRST, before resolveDK or any store read, so a step that starts after its job was abandoned
// derives no key and the KDF cache a sign-out forgot stays forgotten (dn-1106 #1). It is checked again just before
// each store write (writeAccountDirGuarded); in cap mode the bracket carries it to capFlush (capSetSessionMayWrite).
func enrollUnitAtLoginGuarded(base, name, pass string, se []byte, mayWrite func() bool) {
	defer func() { recover() }()
	if !lateMayWrite(mayWrite) {
		return
	}
	if !multiDeviceEnabled() {
		return
	}
	dk := resolveDK(base, name, pass, se)
	if dk == nil {
		return
	}
	uid := deviceUnitID()
	edition := deviceEdition()
	// NWP-20261011-52: through capWrite, in both modes, so a refused directory write is at least said. Still
	// best-effort -- a refusal is logged and nothing more, and the next login simply tries again. No name or ref
	// in the line: the login daemon's stderr must not say which profiles exist.
	if vd := capWrite(name, pass, dk, func() {
		capSetSessionMayWrite(mayWrite) // inside the bracket: capWrite rebuilt the session struct before fn
		ensureUnitInDirectoryGuarded(base, name, pass, dk, uid, defaultUnitLabel(edition, uid), edition, mayWrite)
	}); vd.Refused() {
		fmt.Fprintln(os.Stderr, "[agent] enroll-unit: the account directory write was refused at publish; the next login retries")
	}
}

// ensureUnitInDirectory records THIS device as a lineage in the account directory when it isn't already one --
// the implicit enrollment on the first login of this account on this device. Idempotent: later logins find the
// unit present and write NOTHING, so it costs one store write per (account, device), not per login. Returns
// the directory and whether it wrote. BEST-EFFORT at the call site: a failure must never un-gate an otherwise
// valid login (mirror autoPublish -- wrap the call in recover()).
func ensureUnitInDirectory(base, name, pass string, dk []byte, unitID, label, edition string) (*accountDir, bool) {
	return ensureUnitInDirectoryGuarded(base, name, pass, dk, unitID, label, edition, nil)
}

// ensureUnitInDirectoryGuarded is ensureUnitInDirectory with mayWrite (nil = always) checked just before each
// directory write (h46 #1, writeAccountDirGuarded): when it says no, nothing is written and the write is reported as
// not made.
func ensureUnitInDirectoryGuarded(base, name, pass string, dk []byte, unitID, label, edition string, mayWrite func() bool) (*accountDir, bool) {
	d, ok := loadAccountDir(base, name, pass, dk)
	if !ok {
		d = newAccountDir(unitEntry{ID: unitID, Label: label, Edition: edition, Added: time.Now().Unix()})
		if !writeAccountDirGuarded(base, name, pass, dk, d, mayWrite) {
			return nil, false
		}
		return d, true
	}
	for _, u := range d.Units {
		if u.ID == unitID {
			return d, false // already enrolled -> nothing to write
		}
	}
	d.addUnit(unitEntry{ID: unitID, Label: label, Edition: edition, Added: time.Now().Unix()})
	if !writeAccountDirGuarded(base, name, pass, dk, d, mayWrite) {
		return d, false
	}
	return d, true
}

// syncAccountKeyslots republishes the ACCOUNT head carrying THIS vault's keyslots and the ACCOUNT
// head's OWN manifest. It is the #91 "identity anchor" rule, decided by Chester 2026-09-06.
//
// WHY IT HAS TO EXIST. With multi-device on, a keyslot change writes only THIS unit's head -- enrolling
// or REVOKING a FIDO2 key (fido2.go), setting the session PIN (pin.go). The account head keeps whatever
// vault it last held, and headRef falls through to it for any device with no unit head of its own. So a
// key you revoked BECAUSE YOU LOST IT still opens the account through the account fallback -- the same
// revocation-failure shape as NWP-20260906-05, one ref further out.
//
// WHY IT COPIES SLOTS AND NOT THE WHOLE VAULT, which is the decision and not an implementation detail.
// A vault carries keyslots and a manifest pointer TOGETHER, so republishing this device's whole vault to
// the account head would drag its DATA there too. The account head is written only at create / migrate /
// harden and is never advanced by a seal (pinned by TestFlagOnCreateStillSealsToItsOwnUnitHead), so it is
// deliberately frozen at creation state: its jobs are to prove the account EXISTS -- otherwise a second
// device gets a blank login, indistinguishable from a wrong passphrase -- and to carry keyslots that
// unwrap the DK. Advancing its manifest would make a not-yet-sealed device silently ADOPT the last
// writer's app data, which crosses the 2026-07-03 decision that app data is per-unit ALWAYS and
// cross-unit access is an explicit point-in-time restore, never a live merge.
//
// So: identity travels, data does not. Slots, Hardened and Pin are identity. Manifest, History, LastSeal
// and HeadKind stay the account head's own.
//
// Safe to re-sign: keyslots wrap the DK, the DK is minted once and never re-minted, and Sig is an HMAC
// over the header keyed by that same DK -- so the account vault verifies after the swap.
//
// No-op with the flag off, where putHead already writes the account head directly.
func syncAccountKeyslots(base, name, pass string, dk []byte, cur *vault) {
	if !multiDeviceEnabled() || cur == nil || dk == nil {
		return
	}
	// Read the account head through the SAME ladder headRef uses for it -- v2 first, then legacy -- so an
	// un-migrated profile whose account head still sits at the legacy ref is not silently skipped, which
	// would leave exactly the hole this closes.
	head := getRef(base, profileRefV2(name, pass))
	if head == "" {
		head = getRef(base, profileRefLegacy(name, pass))
	}
	if head == "" {
		return // no account head to sync
	}
	av, isV := parseVault(getHeadBlob(base, head))
	if !isV {
		return // legacy bare-manifest head: no keyslots to carry
	}
	// IDENTITY ONLY.
	av.Slots = cur.Slots
	av.Hardened = cur.Hardened
	av.Pin = cur.Pin
	av.Version++
	signVault(av, dk)
	putHeadSingle(base, name, pass, postBlob(base, serializeVault(av)))
}

// accountDeleteRefs returns every #91 ref a delete must purge that scopedDeleteRefs does not: the
// per-unit head of EVERY enrolled lineage -- not merely this device's -- and the account directory.
//
// WHY IT HAS TO EXIST. seal_fence.go says this about itself: the fence covers the per-unit heads and
// "the PURGE does not", and "fencing them without purging them makes a multi-device build LOOK fixed
// while the refs survive". That is exactly what happened -- deleteProfile appended sealFenceUnitKeys to
// the FENCE set and iterated only `scoped` for the tombstones and the verify. So delete reported
// "deleted (all scopes purged + verified)" while every lineage's heads stayed live, and on an amnesiac
// device "delete" is the one verb whose whole promise is that nothing survives.
//
// EVERY LINEAGE, NOT JUST THIS ONE. sealFenceUnitKeys derives from deviceUnitID(), so it can only ever
// name the acting handset. The other lineages' ids live in the account directory, which is why this
// takes the DK and reads it. RETIRED units are purged too: a retired lineage keeps its head precisely so
// it stays restorable, which is the opposite of what a delete must leave behind.
//
// THE DIRECTORY ITSELF IS LAST IN THE LIST AND MUST BE ENUMERATED BEFORE IT IS TOMBSTONED -- it is the
// only thing that names the other lineages. It is also the only object here that would otherwise survive
// a delete entirely: accountDirRef appears in no footprint, so it is neither leased nor purged, and it is
// a sealed list of the user's devices.
//
// ⚠ WITHOUT A DK THIS CAN ONLY REACH THIS DEVICE'S OWN LINEAGE. A delete driven from a device that
// cannot open the vault (a hardened profile on foreign hardware) enumerates nothing, so the other
// lineages' heads survive and the verify below will not catch it -- it never sees them. Normal deletes
// run after a resolved login and do have the DK; the gap is stated rather than hidden.
func accountDeleteRefs(base, name, pass string, dk []byte) []string {
	if !multiDeviceEnabled() {
		return nil
	}
	ids := map[string]bool{deviceUnitID(): true}
	if dk != nil {
		if d, ok := loadAccountDir(base, name, pass, dk); ok && d != nil {
			for _, u := range d.Units {
				if u.ID != "" {
					ids[u.ID] = true // retired included, deliberately
				}
			}
		}
	}
	out := make([]string, 0, len(ids)*len(deleteScopeSuffixes)+1)
	for id := range ids {
		for _, s := range deleteScopeSuffixes {
			if scoped := name + s; isPerUnitRef(scoped) {
				out = append(out, unitHeadRef(scoped, pass, id))
			}
		}
	}
	sort.Strings(out) // deterministic, so a delete is reproducible in a log and in a test
	return append(out, accountDirRef(name, pass))
}

// headWriteRef is THE decision about where a write for (name, pass) lands: this unit's head when #91 is on
// and the scope is per-unit, else the account (v2) ref. perUnit reports which branch it took, so putHead can
// keep the extra work the account branch owes (the legacy tombstone, in putHeadSingle) without a second copy
// of the condition.
//
// It exists because ONE caller cannot use putHead itself: capFlush's wallet fold needs the KEY rather than
// the write, since it stages the pointer into the batch that the same flush leases and PUTs. It hand-rolled
// the choice as `profileRefV2(name+"#wallet", pass)` instead -- written before #91 and never revisited.
//
// NWP-20260906-12. #wallet IS per-unit (isPerUnitRef), so with multi-device on the two disagreed: the fold
// wrote v2 while the restore (walletHeadKey -> headKey -> headRef) and sealWalletDurable (putHead) both
// used the UNIT head. headRef probes the unit head FIRST, so from the first durable wallet seal onward every
// later fold wrote where nothing reads.
//
// ⚠ AND IN CAP MODE THE FOLD IS THE ONLY ROUTINE PUBLISHER -- sealWallet returns immediately there ("the
// wallet rides the seal flush"), and the on-disk wallet is tmpfs. So post-spend wallet state would never have
// become durable: the next login would restore the wallet from before the spend and resurrect tokens the
// gateway then refuses as spent nonces. That is the NWP-20260829-14 shape. Money, silently.
//
// ⚠ THE V2 WRITE WAS ALSO A CROSS-DEVICE TOKEN LEAK. headRef falls through to v2 for a device with no unit
// head of its own, so a second handset restored THIS one's bearer tokens -- the exact thing headRef refuses
// to do deliberately three lines up, where it exempts #wallet from the "restore from another unit" override
// because "the wallet is per-unit (bearer tokens -> never restored from another device)".
func headWriteRef(name, passphrase string) (ref string, perUnit bool) {
	if multiDeviceEnabled() && isPerUnitRef(name) {
		return unitHeadRef(name, passphrase, deviceUnitID()), true
	}
	return profileRefV2(name, passphrase), false
}
