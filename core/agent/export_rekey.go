package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/minio/minio-go/v7"
)

// NWP-20261010-02: the data export's keys, the device half (docs/data-export-rekey.md §2-§4).
//
// The export used to live at ref/export/<name> and ref/export/<name>#media: the profile name in clear, so anyone could
// probe which names had exported, overwrite or roll back an export by name, and the gateway's ledger joined the name to
// the profile's billing key. Every key the export writes is now the hash of a PROOF only (name, passphrase) derives:
//
//	K                 = deriveKey(name, pass)
//	proof(docs)       = HMAC-SHA256(K, "nowhere-export-docs-v1")
//	proof(media)      = HMAC-SHA256(K, "nowhere-export-media-v1")
//	proof(bundle, E)  = HMAC-SHA256(K, "nowhere-export-bundle-v1\x00" || decimal(E))
//	key(proof)        = "ref/" + hex SHA-256("nowhere-export-key-v1\x00" || proof)
//
// E is an epoch. On a managed store it is the GATEWAY's: the time on the Date header of its /quote reply over the
// epoch_seconds that reply states, the clock its `expire` marks are counted in -- a UTC day on the daily clock
// DefaultConfig sets, the unit the page renders a bundle's date in. On a self-hosted store, which has no gateway, it is
// a UTC day of the device clock. The docs pointer holds E as ASCII decimal; the bundle of epoch E is a REF holding the
// sealed zip itself (read raw: getRefBytes); the media pointer holds the pinned #media manifest's hash.
//
// ⚠ VERBATIM WITH THE GATEWAY AND THE PAGE. nowhere-cloud internal/storekey (ExportDocsProof, ExportMediaProof,
// ExportBundleProof, ExportKey) is the statement the gateway verifies marks with and cmd/exportwasm finds an export
// with. A byte of difference and the page cannot find what the phone exported, or the gateway refuses every mark as
// `bad expire proof`. export_rekey_test.go pins storekey's own golden vectors.
const (
	exportKeyLabel    = "nowhere-export-key-v1\x00"
	exportDocsLabel   = "nowhere-export-docs-v1"
	exportMediaLabel  = "nowhere-export-media-v1"
	exportBundleLabel = "nowhere-export-bundle-v1\x00"
	// exportBundleEpochs is how many epochs of bundles Delete and a passphrase change name: E-8 .. E. The gateway
	// marks an export's rows now + 7 EPOCHS (its ExportEpochs) and collects them after the epoch the mark names, so an
	// export lives at least 7 epochs and under 8 (plus a GC interval), and nine epochs cover every bundle a gateway that
	// marks them can still hold, whatever length its epoch is (docs/data-export-rekey.md §4, §8).
	exportBundleEpochs = 9
	// exportDaySeconds is a self-hosted store's epoch: a UTC day of the device clock, the unit the page renders E in.
	// A managed store's epoch is the gateway's own epoch_seconds (gatewayExportEpoch), never this.
	exportDaySeconds = 86400
)

func exportMAC(k []byte, label string) []byte {
	mac := hmac.New(sha256.New, k)
	mac.Write([]byte(label))
	return mac.Sum(nil)
}

func exportDocsProof(k []byte) []byte  { return exportMAC(k, exportDocsLabel) }
func exportMediaProof(k []byte) []byte { return exportMAC(k, exportMediaLabel) }

// exportBundleProof is the proof of the bundle an export made in epoch e writes: one bundle per profile per epoch, so
// Delete and a passphrase change name every bundle of the last epochs by deriving them, with no record to read.
func exportBundleProof(k []byte, e int64) []byte {
	return exportMAC(k, exportBundleLabel+strconv.FormatInt(e, 10))
}

// exportKey is the store key a proof certifies: a ref/<64 hex>, so the holder rule applies to it like any head.
func exportKey(proof []byte) string {
	h := sha256.New()
	h.Write([]byte(exportKeyLabel))
	h.Write(proof)
	return "ref/" + hex.EncodeToString(h.Sum(nil))
}

// exportRef is one export key and the proof that certifies it. The proof is what a lease's `expire` entry carries, so
// it is as sensitive as the key: neither is ever printed (redactNameIn takes a ref/<64 hex> out of an error line).
type exportRef struct {
	key   string // "ref/<64 hex>"
	proof []byte
}

// name is the ref as putRef and getRef take it, without the "ref/" prefix.
func (r exportRef) name() string { return strings.TrimPrefix(r.key, "ref/") }

func newExportRef(proof []byte) exportRef { return exportRef{key: exportKey(proof), proof: proof} }

func exportDocsRef(k []byte) exportRef            { return newExportRef(exportDocsProof(k)) }
func exportMediaRef(k []byte) exportRef           { return newExportRef(exportMediaProof(k)) }
func exportBundleRef(k []byte, e int64) exportRef { return newExportRef(exportBundleProof(k, e)) }

// exportDeleteRefs is every key an export of (name, pass) can have written that a gateway may still hold in epoch e:
// both pointers and the bundles of epochs e-8 .. e. Derived, never read from the store -- an earlier draft kept a record
// of the bundles in the pointer, which a reader of the pointer could learn and rewrite (docs/data-export-rekey.md §10).
func exportDeleteRefs(name, pass string, e int64) []exportRef {
	k := deriveKey(name, pass)
	out := []exportRef{exportDocsRef(k), exportMediaRef(k)}
	for d := e - (exportBundleEpochs - 1); d <= e; d++ {
		out = append(out, exportBundleRef(k, d))
	}
	return out
}

// exportViaLease says the export's writes to base ride a cap lease: the managed store. A self-hosted store (S3
// credentials on the device) and the plain HTTP store write directly and have no gateway, so no lease, no `expire`
// and no 7 days (docs/data-export-rekey.md §8).
func exportViaLease(base string) bool { return isS3(base) && capMode() }

// exportClock is the device clock a self-hosted store's export epochs come from. A var so a test can pin a day.
var exportClock = time.Now

// exportEpoch is the current export epoch E for base: the gateway's on a managed store (gatewayExportEpoch), a UTC
// day of the device clock on a self-hosted one.
// ⚠ FAIL CLOSED: a managed store whose gateway's epoch cannot be read is an error, never the device clock. A phone with
// a wrong clock would otherwise file the bundle under an epoch the gateway's marks and the page's lookup disagree with,
// and Delete would name the wrong nine epochs.
func exportEpoch(base string) (int64, error) {
	if !exportViaLease(base) {
		return exportClock().Unix() / exportDaySeconds, nil
	}
	return newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault).gatewayExportEpoch()
}

// gatewayExportEpoch reads the gateway's current epoch from one cheap GET (/quote): the time on the reply's Date header
// -- the gateway's own clock, which Go's server stamps on every reply -- over the epoch_seconds the reply states, the
// length the gateway counts its `expire` marks in. Either one missing is an error: no epoch is guessed.
func (g *gatewayClient) gatewayExportEpoch() (int64, error) {
	resp, err := g.hc.Get(g.base + "/quote")
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("gateway /quote: %s", resp.Status)
	}
	var q quoteInfo
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<16)).Decode(&q); err != nil {
		return 0, fmt.Errorf("gateway /quote does not parse: %w", err)
	}
	if q.EpochSeconds <= 0 {
		return 0, errors.New("the gateway's /quote states no epoch_seconds")
	}
	d := resp.Header.Get("Date")
	if d == "" {
		return 0, errors.New("the gateway's reply carried no Date header")
	}
	t, err := http.ParseTime(d)
	if err != nil {
		return 0, fmt.Errorf("the gateway's Date header does not parse: %w", err)
	}
	return t.Unix() / q.EpochSeconds, nil
}

// maxExportEpochDigits keeps ParseInt clear of overflow; a UTC day number has five digits until the year 2243.
const maxExportEpochDigits = 18

// parseExportEpoch reads the docs pointer's content, ASCII decimal E, as the page does (cmd/exportwasm
// parseExportEpoch): surrounding whitespace tolerated, anything but digits refused.
func parseExportEpoch(s string) (int64, bool) {
	s = strings.TrimSpace(s)
	if s == "" || len(s) > maxExportEpochDigits {
		return 0, false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
	}
	e, err := strconv.ParseInt(s, 10, 64)
	return e, err == nil
}

// vaultNeedsWords says the page will ask for the 12 words to open this vault: it has no `pass` slot (tied, or with
// security keys), the page's own test (cmd/exportwasm needsRecoveryCode). A legacy bare head (nil) opens by passphrase.
func vaultNeedsWords(v *vault) bool {
	if v == nil {
		return false
	}
	for _, s := range v.Slots {
		if s.Kind == "pass" {
			return false
		}
	}
	return true
}

// containsAll reports whether list names every key in want.
func containsAll(list []string, want ...string) bool {
	have := make(map[string]bool, len(list))
	for _, k := range list {
		have[k] = true
	}
	for _, k := range want {
		if !have[k] {
			return false
		}
	}
	return len(want) > 0
}

// exportOutcome is what an export tells the phone, appended to its OK reply (NWP-20261010-02):
//
//	words=1   the vault has no pass slot, so the page needs the 12 words to open the export
//	expire=1  the gateway marked every ref this export wrote for about 7 days (expire_applied named them all)
//	store=self|managed  where it went: the page reads only the managed store
//
// Appended after the fields older choosers parse, so a chooser that predates them reads the reply as before.
type exportOutcome struct {
	words, expires, managed bool
}

func (o exportOutcome) flags() string {
	b := func(x bool) int {
		if x {
			return 1
		}
		return 0
	}
	store := "self"
	if o.managed {
		store = "managed"
	}
	return fmt.Sprintf(" words=%d expire=%d store=%s", b(o.words), b(o.expires), store)
}

// logNote is the outcome for the daemon's own line: no key, no proof, no name.
func (o exportOutcome) logNote() string {
	switch {
	case !o.managed:
		return "self-hosted store, no expiry"
	case o.expires:
		return "7-day expiry applied"
	}
	return "the gateway applied no expiry"
}

// exportDocs files bundle as the docs export of (name, pass): sealed under dk into the bundle of the current epoch E, then
// the docs pointer naming E, both marked "export" for about 7 days (docs/data-export-rekey.md §4). v is the vault dk
// came from (nil for a legacy head), for the 12-words flag. It panics on a store failure, as every bracket does.
//
// ⚠ THE BUNDLE IS BUFFERED FIRST. capFlush PUTs a bracket's refs in the order they were buffered, so the pointer can
// only ever name a bundle that landed. And it is a REF, not a blob: its key is derived from K and its epoch, which is what
// lets Delete and a passphrase change name it with no record -- and a ref is held in RAM until the flush, which is
// where the bundle already is (the EXPORT verb reads it whole, at most 64 MiB).
func exportDocs(base, name, pass string, dk []byte, v *vault, bundle []byte) (exportOutcome, error) {
	e, err := exportEpoch(base)
	if err != nil {
		return exportOutcome{}, fmt.Errorf("the export epoch could not be read: %w", err)
	}
	k := deriveKey(name, pass)
	docs, b := exportDocsRef(k), exportBundleRef(k, e)
	sealed := seal(dk, bundle) // nonce || AES-256-GCM(bundle), as the page opens it
	prior := exportPrior(v, dk)
	verdict := capWrite(name, pass, dk, func() {
		capSetSessionPrior(prior)
		putRefBytes(base, b.name(), sealed) // no string round trip: the bundle can be 64 MiB
		putRef(base, docs.name(), strconv.FormatInt(e, 10))
		capMarkExpire(b.key, b.proof, expireExport)
		capMarkExpire(docs.key, docs.proof, expireExport)
	})
	if verdict.Refused() {
		return exportOutcome{}, errors.New("the store refused the export's pointer")
	}
	return exportOutcome{words: vaultNeedsWords(v), managed: exportViaLease(base),
		expires: containsAll(verdict.ExpireApplied, b.key, docs.key)}, nil
}

// exportPrior is the `prior` an export's lease names: the vault's !bill-retag record, the billing keys this profile's
// rows may still be tagged with -- what a bare seal and Delete send. An export's keys are derived from (name, pass),
// so a change A->B->A brings the export back to keys whose rows B's lease may still hold: the passphrase change
// re-tags the OLD export's rows to the new key when it marks them (retireOldExport), and until GC collects them a
// lease that does not name B is refused 403 (docs/data-export-rekey.md X1). The change back to A records B, so naming
// the record is what lets that export through. Nil for a legacy head, a vault this key does not open, or no index.
func exportPrior(v *vault, dk []byte) []string {
	if v == nil || dk == nil {
		return nil
	}
	if idx, ok := openScopeIndex(dk, v.Scopes); ok {
		return billRetagOf(idx)
	}
	return nil
}

// storeRefExists reports whether the object at ref exists -- an empty one (a tombstone) included -- WITHOUT reading
// it: a bundle can be megabytes, and a Delete probes nine of them. An error is a read that could not tell.
func storeRefExists(base, ref string) (bool, error) {
	key := "ref/" + ref
	switch {
	case exportViaLease(base):
		return capRefExists(key)
	case isS3(base):
		return s3ExistsErr(key)
	case base == "disco":
		_, ok := discoGet(key)
		return ok, nil
	}
	resp, err := http.Get(base + "/ref/" + ref)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	switch {
	case resp.StatusCode == http.StatusNotFound:
		return false, nil
	case resp.StatusCode/100 == 2:
		return true, nil
	}
	return false, fmt.Errorf("GET ref -> status %d", resp.StatusCode)
}

// capRefExists is storeRefExists on the managed store: a GET of one byte through a free read cap (a cap is presigned
// for GET, so a HEAD would fail its signature -- the reason capSize does the same). 200 and 206 are a present object;
// 416 is one with no byte 0, an EMPTY object, which exists; 404 is absent. The first 403 may be a stale cached presign,
// so it drops the cap and retries once. A 403 on a FRESH cap is a read that could not tell (h50 #9), as s3ExistsErr
// and storeRefExists's HTTP arm rule it, never absence: it wraps errStorePermanent, so retryStore stops there. Anything
// else retries, then is returned.
func capRefExists(key string) (bool, error) {
	var exists bool
	fresh403 := false
	err := retryStore("cap GET "+key, func() error {
		exists = false
		u, err := capReadURL(key)
		if err != nil {
			return err
		}
		req, err := http.NewRequest(http.MethodGet, u, nil)
		if err != nil {
			return err
		}
		req.Header.Set("Range", "bytes=0-0")
		resp, err := storeHTTP.Do(req)
		if err != nil {
			capInvalidate(key)
			return err
		}
		defer resp.Body.Close()
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<10)) // a store that ignores Range sends it all: stop
		switch resp.StatusCode {
		case http.StatusOK, http.StatusPartialContent, http.StatusRequestedRangeNotSatisfiable:
			exists = true
			return nil
		case http.StatusNotFound:
			return nil
		case http.StatusForbidden:
			if !fresh403 {
				fresh403 = true
				capInvalidate(key)
				return fmt.Errorf("cap GET %s -> 403 on a possibly-stale cap (refetching)", key)
			}
			return fmt.Errorf("%w: cap GET -> 403 on a fresh cap: the store would not say whether the object exists",
				errStorePermanent)
		}
		capInvalidate(key)
		return fmt.Errorf("cap GET %s -> status %d", key, resp.StatusCode)
	})
	return exists, err
}

// s3ExistsErr is s3Exists that returns the failure instead of reading it as absent: a Delete must not skip a bundle it
// could not see -- on a self-hosted store nothing else would ever empty it.
func s3ExistsErr(key string) (bool, error) {
	cl, bk := s3Init()
	exists := false
	err := retryStore("STAT "+key, func() error {
		_, err := cl.StatObject(context.Background(), bk, key, minio.StatObjectOptions{})
		if err != nil {
			er := minio.ToErrorResponse(err)
			if er.Code == "NoSuchKey" || er.StatusCode == 404 {
				return nil
			}
			return err
		}
		exists = true
		return nil
	})
	return exists, err
}

// exportRefsExisting keeps the refs of rs whose objects exist, in rs's order: one batched read -- the read caps in one
// /caps request, the probes at once -- so a profile that never exported creates nothing and costs two round trips.
// Any probe that cannot tell is an error for the whole set: a Delete that skipped a bundle it could not see would
// report a purge it did not make.
func exportRefsExisting(base string, rs []exportRef) ([]exportRef, error) {
	if len(rs) == 0 {
		return nil, nil
	}
	if exportViaLease(base) {
		keys := make([]string, len(rs))
		for i, r := range rs {
			keys[i] = r.key
		}
		prefetchReadCaps(keys)
	} else if isS3(base) {
		s3Init() // warm the store client once, before the probes; each probe's s3ExistsErr takes its own client and bucket
	}
	found := make([]bool, len(rs))
	errs := make([]error, len(rs))
	var wg sync.WaitGroup
	for i := range rs {
		wg.Add(1)
		goSafe("export-ref-probe", func() {
			defer wg.Done()
			errs[i] = recovered(func() {
				var err error
				found[i], err = storeRefExists(base, rs[i].name())
				check(err)
			})
		})
	}
	wg.Wait()
	var out []exportRef
	for i, r := range rs {
		if errs[i] != nil {
			return nil, errs[i]
		}
		if found[i] {
			out = append(out, r)
		}
	}
	return out, nil
}

// exportPurge is what emptying an export's refs came to.
type exportPurge struct {
	sent    []string        // every key the purge named
	applied map[string]bool // the keys a landed lease's expire_applied named
	refused []string        // keys whose one-ref lease the gateway still refused 403: a row another profile holds (X1)
	failed  []string        // keys whose one-ref lease failed otherwise: a 5xx, a store or transport error
	err     error           // the purge failed outright: a store or gateway error, a self-hosted write
}

// problem is why the purge cannot be called done, or "". On a gateway that honours `expire` -- one whose lease named
// anything in expire_applied -- every key must have been named, so a mark that did not land is not reported as one.
// An older gateway names nothing: its empty writes still make the pointers read empty (docs/data-export-rekey.md §8).
func (p exportPurge) problem() string {
	if p.err != nil {
		return "a store or gateway error"
	}
	if len(p.refused) > 0 || len(p.failed) > 0 {
		return fmt.Sprintf("one ref at a time, %d still refused by the gateway (held by another profile) and %d "+
			"failed (a store or gateway error)", len(p.refused), len(p.failed))
	}
	if len(p.applied) > 0 {
		for _, k := range p.sent {
			if !p.applied[k] {
				return "the gateway marked only some of the export's refs"
			}
		}
	}
	return ""
}

// purgeExportRefs empties rs and, on the managed store, marks them "now" for the next GC, as (name, pass) -- the
// profile the lease is made as -- naming prior, so a row a credential change left tagged with an older key changes
// hands to this one (docs/data-export-rekey.md §4). dk is the vault's key, or nil; it never folds the wallet.
//
// ONE bracket with walletNotOurs: a fold would republish the wallet of a profile that is being deleted, and could buy
// a pending plan -- and once Delete has fenced the wallet head, a fold is refused and skips the bracket's PUTs. Its
// lease names the refs with sizes 0 and `expire: now` -- which also mints the write caps -- and the empty PUTs follow,
// so the pointers read empty at once. If that lease answers 403 -- one row held by another profile refuses the whole
// request (X1) -- each ref is retried in a lease of its own, and the ones still refused (403) and the ones that failed
// otherwise are reported apart.
//
// A self-hosted store has no lease: the refs are written empty, and that is all (docs/data-export-rekey.md §8).
func purgeExportRefs(base, name, pass string, dk []byte, prior []string, rs []exportRef) exportPurge {
	p := exportPurge{applied: map[string]bool{}}
	for _, r := range rs {
		p.sent = append(p.sent, r.key)
	}
	if len(rs) == 0 {
		return p
	}
	if !exportViaLease(base) {
		p.err = emptyExportRefsDirect(base, rs)
		return p
	}
	note := func(v capVerdict) {
		for _, k := range v.ExpireApplied {
			p.applied[k] = true
		}
	}
	v, err := leaseEmptyExportRefs(base, name, pass, dk, prior, rs)
	if err == nil {
		note(v)
		return p
	}
	if v.LeaseRefused != http.StatusForbidden {
		p.err = err
		return p
	}
	for _, r := range rs {
		v1, err1 := leaseEmptyExportRefs(base, name, pass, dk, prior, []exportRef{r})
		switch {
		case err1 == nil:
			note(v1)
		case v1.LeaseRefused == http.StatusForbidden:
			p.refused = append(p.refused, r.key)
		default:
			p.failed = append(p.failed, r.key)
		}
	}
	return p
}

// leaseEmptyExportRefs is purgeExportRefs' one bracket: an empty value and an `expire: now` mark per ref.
func leaseEmptyExportRefs(base, name, pass string, dk []byte, prior []string, rs []exportRef) (v capVerdict, err error) {
	err = recovered(func() {
		capWriteTo(&v, name, pass, dk, true, func() {
			capSetSessionPrior(prior)
			for _, r := range rs {
				putRef(base, r.name(), "")
				capMarkExpire(r.key, r.proof, expireNow)
			}
		})
	})
	return v, err
}

// emptyExportRefsDirect writes an empty body to each ref, on a store the device writes directly. It opens no bracket,
// so a direct-mode rotation calls it from inside its own.
func emptyExportRefsDirect(base string, rs []exportRef) error {
	return recovered(func() {
		for _, r := range rs {
			putRef(base, r.name(), "")
		}
	})
}

// exportRefsToPurge is every export ref of (name, pass) that exists on base today: the pointers and the last nine
// epochs' bundles.
func exportRefsToPurge(base, name, pass string) ([]exportRef, error) {
	e, err := exportEpoch(base)
	if err != nil {
		return nil, fmt.Errorf("the export epoch could not be read: %w", err)
	}
	return exportRefsExisting(base, exportDeleteRefs(name, pass, e))
}

// retireOldExport is a committed passphrase change's best-effort mark on the managed store (docs/data-export-rekey.md
// §4): the OLD passphrase's export refs that exist, emptied and marked "now" in a lease of their own, made as the NEW
// profile naming the old one as prior -- which holds whether or not /rebind has already moved the old key's rows to
// the new one. Separate from the rotation's own lease ON PURPOSE: that lease lands before any PUT, so a rotation
// refused at publish would already have marked the export of the passphrase the user keeps, and one foreign row would
// 403 the whole passphrase change. The caller runs it only after the change committed, and never for a change to the
// same passphrase. It only logs: the rotation is done whatever happens here.
func retireOldExport(base, name, oldpass, newpass string, dk []byte, oldV2 string) {
	err := recovered(func() {
		rs, err := exportRefsToPurge(base, name, oldpass)
		check(err)
		if len(rs) == 0 {
			return
		}
		if why := purgeExportRefs(base, name, newpass, dk, []string{oldV2}, rs).problem(); why != "" {
			fmt.Fprintf(os.Stderr, "[agent] rotate: the old passphrase's export (%d ref(s)) was not retired: %s -- "+
				"it lives out its days\n", len(rs), why)
			return
		}
		fmt.Fprintf(os.Stderr, "[agent] rotate: the old passphrase's export retired (%d ref(s))\n", len(rs))
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "[agent] rotate: the old passphrase's export was not retired: %s -- it lives out its days\n",
			logSafeStoreErr("", err))
	}
}

// retireOldExportDirect is retireOldExport on a store the device writes directly: inside the rotation's own bracket,
// in its retire pass, the old passphrase's export refs that exist are written empty. Opens no bracket; never panics.
func retireOldExportDirect(base, name, oldpass string) {
	err := recovered(func() {
		rs, err := exportRefsToPurge(base, name, oldpass)
		check(err)
		check(emptyExportRefsDirect(base, rs))
		if len(rs) > 0 {
			fmt.Fprintf(os.Stderr, "[agent] rotate: the old passphrase's export emptied (%d ref(s))\n", len(rs))
		}
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "[agent] rotate: the old passphrase's export was not emptied: %s\n", logSafeStoreErr("", err))
	}
}

// errExportNoProfile and errExportNone are the CLI readers' two misses: the credentials open nothing, or they do
// and no export was made (or it expired).
var (
	errExportNoProfile = errors.New("profile not found or wrong pass")
	errExportNone      = errors.New("no export (expired or never made)")
)

// exportFetchDocs is the docs half of the `export-fetch` verb, the reference for what the page does (docs/data-export-
// rekey.md §5): the docs pointer names epoch E, the bundle of epoch E is read RAW and opened under the profile's DK. It
// falls back to the legacy ref/export/<name> pointer -- what agents before this slice wrote -- until the legacy shape
// is removed, and only when the re-keyed export is missing or leads nowhere, so where both exist the new one is read.
func exportFetchDocs(base, name, pass string) ([]byte, error) {
	dk := resolveDK(base, name, pass, nil)
	if dk == nil {
		return nil, errExportNoProfile
	}
	k := deriveKey(name, pass)
	if e, ok := parseExportEpoch(getRef(base, exportDocsRef(k).name())); ok {
		if raw, ok := getRefBytes(base, exportBundleRef(k, e).name()); ok && len(raw) > 0 {
			return unseal(dk, raw), nil
		}
	}
	h := getRef(base, "export/"+name) // legacy: a pointer to a blob, keyed by the name alone
	if h == "" {
		return nil, errExportNone
	}
	return unseal(dk, getBlob(base, h)), nil
}

// exportMediaPointer is the pinned #media manifest's hash the media export names: the re-keyed pointer, else the
// legacy ref/export/<name>#media one. "" when neither holds one.
func exportMediaPointer(base, name, pass string) string {
	if h := getRef(base, exportMediaRef(deriveKey(name, pass)).name()); isContentHash(h) {
		return h
	}
	if h := getRef(base, "export/"+name+"#media"); isContentHash(h) {
		return h
	}
	return ""
}

// openMediaExportManifest opens a pinned #media manifest by every key the profile can still name, in the page's order
// (cmd/exportwasm openMediaExport, docs/data-export-rekey.md §5): the vault's scope index -- its #media entry's Wrapped
// key, then its Prev (a manifest pinned before a re-key switched the head) -- then the current #media head's own slot
// (a vault whose index is missing or stale), then deriveKey(name#media, pass) (no index, or a legacy bare profile).
// GCM authenticates, so a key either opens the manifest or does not: the order is a cost, never a guess. It returns
// the key that opened it -- every chunk the manifest names is sealed under that key -- and the plaintext.
//
// The current head's key is not enough on its own, and was all this reader used: a tie's background re-key moves the
// scope to a key only the chip and the index hold, and a passphrase change keeps the scope's ORIGINAL key behind a slot
// the new passphrase opens. A manifest pinned under either opens through the index.
func openMediaExportManifest(base, name, pass string, blob []byte) (key, pt []byte, err error) {
	try := func(k []byte) bool {
		if len(k) == 0 {
			return false
		}
		var out []byte
		if recovered(func() { out = unseal(k, blob) }) != nil {
			return false
		}
		key, pt = k, out
		return true
	}
	if dk, v := resolveDKVault(base, name, pass, nil); dk != nil && v != nil {
		if idx, ok := openScopeIndex(dk, v.Scopes); ok {
			rec, kek := idx["#media"], kekScopes(dk)
			for _, w := range []string{rec.Wrapped, rec.Prev} {
				if w == "" {
					continue
				}
				if k, ok := unwrap(kek, w); ok && try(k) {
					return key, pt, nil
				}
			}
		}
	}
	var hk []byte
	if recovered(func() { hk, _, _ = resolveKey(base, name+"#media", pass) }) == nil && try(hk) {
		return key, pt, nil
	}
	if try(deriveKey(name+"#media", pass)) {
		return key, pt, nil
	}
	return nil, nil, errors.New("no key this profile holds opens the media export")
}
