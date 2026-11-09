package main

// Full-catalog F-Droid SEARCH + install (Phase B, docs/store-fdroid-search.md). The store's "Get apps" search
// covers the WHOLE F-Droid catalog (~4000 apps), not just the ~12 curated entries. On-device + private: a
// Nowhere-SIGNED TRIMMED index (a `catalog` in the same schema) is baked in /system and lazily refreshed to /data;
// search + install run locally so our servers never learn WHAT a user installs. Icons ship in a baked ZIP served
// LOCALLY (zero browse leak). Trust: the trim job pins F-Droid's repo cert -> our SEPARATE index key signs the
// trimmed index -> the device verifies -> per-app sha256 + signer -> FETCH-APP verifies the download.
//
// Deliberately reuses catalog.go's `catalog`/`catalogEntry`/`catalogAPK` structs + fetchAndVerify + stageapp path,
// so a search install is byte-for-byte the same trust chain as a curated install.

import (
	"archive/zip"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

var (
	indexSystemPath = "/system/etc/nowhere/index.json" // baked trimmed F-Droid index (rides verified boot)
	indexDataPath   = "/data/nowhere/index.json"       // lazily refreshed signed copy of the public index; DURABLE by design (NWP-20261017-34)
	iconPackPath    = "/system/etc/nowhere/icons.pack" // baked icon pack: a ZIP keyed by pkg, served LOCALLY
)

// indexDataPath is NOT wiped at power-off (/data is not; only /data/nowhere/state is tmpfs) and nothing removes it, by
// design (NWP-20261017-34): it is the same public Nowhere-signed trimmed index for every device, verified against the
// key currentIndexKey selects on every read and ignored when older than the baked index (loadIndexBytes). Staleness
// (maxIndexStaleness) is checked only when an index is FETCHED (refreshIndex): refusing a stale /data index on read
// would only fall back to the baked one, which is older still. The shape of catalogDataPath. One honest residual:
// its mtime survives power-off and, since NWP-20261102-11, is the publisher's Last-Modified of the copy fetched (set
// after the write; refreshIndex sends it back as If-Modified-Since), the same for every device that fetched that copy
// -- not when a session refreshed. A copy written before that, or from a response with no valid Last-Modified, keeps
// its write time until the next 200 replaces it; the content is the same public file for every device.

// indexPubKey is a SEPARATE ed25519 key from catalogPubKey (domain separation). It signs the trimmed index, which
// an automated job re-publishes every few hours from an ONLINE key -- so a leak can push a poisoned index but can
// NOT forge a catalog /data override (that needs catalogPubKey). Private half held by Chester, on the signing host.
var indexPubKey = "jq+90FnJ+wsMhe0JfTschNScn6Au6xLCY6JzxY9rllM="

// maxIndexStaleness bounds how OLD a refreshed /data index may be, so the refresh channel can't replay a months-
// old (but validly-signed) index. The baked /system index has no such bound (it's the OS's own, trusted floor).
const maxIndexStaleness = 45 * 86400 // 45 days (F-Droid publishes many times a day; a fresh mirror is hours old)

// verifyEd25519 reports whether sig is a valid ed25519 signature over msg by the base64 pubkey pubB64. sig may be
// the raw 64 bytes OR their base64. Empty pubkey -> false. (Shared by verifyCatalogSig + verifyIndexSig.)
func verifyEd25519(pubB64 string, msg, sig []byte) bool {
	pk := strings.TrimSpace(pubB64)
	if pk == "" {
		return false
	}
	pub, err := base64.StdEncoding.DecodeString(pk)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return false
	}
	s := sig
	if len(s) != ed25519.SignatureSize {
		if d, e := base64.StdEncoding.DecodeString(strings.TrimSpace(string(sig))); e == nil {
			s = d
		}
	}
	return len(s) == ed25519.SignatureSize && ed25519.Verify(pub, msg, s)
}

func verifyIndexSig(msg, sig []byte) bool { return verifyEd25519(indexPubKey, msg, sig) }

// indexGeneratedOf parses ONLY the `generated` field (cheap; used for the rollback comparison without a full parse).
func indexGeneratedOf(b []byte) int64 {
	if len(b) == 0 {
		return 0
	}
	var g struct {
		Generated int64 `json:"generated"`
	}
	_ = json.Unmarshal(b, &g)
	return g.Generated
}

// loadIndexBytes returns the trusted raw trimmed-index bytes, or nil. Mirrors loadCatalogBytes with ONE extra
// guard: a signed /data refresh wins over the baked /system copy ONLY when it is NEWER (generated >= baked) -- so a
// replayed OLD signed index (stale URLs, a reverted removal) can't roll the device back. When a key is baked the
// /system copy must ALSO carry a matching .sig (defense in depth); no key => the read-only baked copy rides
// verified boot. Called on a getIndex cache MISS only, so the extra parse of `generated` is not a per-search cost.
// The /data copy is checked with the key currentIndexKey selects (NWP-20261129-18, #8); see loadIndexBytesWith.
func loadIndexBytes() []byte {
	return loadIndexBytesWith(currentIndexKey(time.Now().Unix()))
}

// loadIndexBytesWith is loadIndexBytes with the /data key already selected, so one refresh judges with one key. dataKey
// checks ONLY the /data copy, and "" means "no /data refresh is accepted", never "unsigned". The baked /system copy
// rides verified boot and is signed by the baked key, so every other branch here keeps reading indexPubKey: a revoked
// key still serves the baked copy, and a phone with no key baked still trusts it unsigned.
func loadIndexBytesWith(dataKey string) []byte {
	baked, _ := os.ReadFile(indexSystemPath)
	if indexPubKey != "" {
		if dataKey == "" {
			fmt.Fprintln(os.Stderr, "[index] no /data refresh key is selected -- ignoring any /data refresh")
		} else if d, err := os.ReadFile(indexDataPath); err == nil {
			if sig, e := os.ReadFile(indexDataPath + ".sig"); e == nil && verifyEd25519(dataKey, d, sig) {
				if indexGeneratedOf(d) >= indexGeneratedOf(baked) {
					return d
				}
				fmt.Fprintln(os.Stderr, "[index] /data refresh is older than the baked index -- ignoring (rollback guard)")
			} else {
				fmt.Fprintln(os.Stderr, "[index] /data refresh present but signature invalid -- ignoring")
			}
		}
	}
	if baked == nil {
		return nil
	}
	if indexPubKey == "" {
		return baked
	}
	if sig, e := os.ReadFile(indexSystemPath + ".sig"); e == nil && verifyIndexSig(baked, sig) {
		return baked
	}
	fmt.Fprintln(os.Stderr, "[index] baked /system index signature missing/invalid -- refusing")
	return nil
}

// --- In-memory parsed cache: parse the ~2.7 MB index ONCE, keyed by the served file's identity, so every
// keystroke-driven SEARCH is a cheap in-memory scan, not a re-parse. Busted when a refresh changes the file. ---

type indexCacheT struct {
	mu      sync.RWMutex
	key     string         // indexCacheKey() of the files it stats when entries was parsed
	entries []catalogEntry // resident parsed index
	gen     int64          // parsed `generated` of the resident index (for the search reply's staleness hint)
}

var indexCache indexCacheT

// indexCacheKey is a CHEAP key from a stat of EVERY file loadIndexBytes reads to choose what it serves: the baked
// index, its .sig, the /data refresh, its .sig and the held index-key pair (NO read/verify) -- so a cache HIT costs six
// os.Stat calls, not a re-read + full ed25519 verify of the ~3 MB index on every search keystroke. A refresh (new /data
// pair) or an OTA (new /system pair) changes a stat -> the key changes -> getIndex re-parses via loadIndexBytes (which
// does the read + sig-verify + /data-vs-/system choice). The .sig files are in the key because refreshIndex installs
// the index and its signature in TWO renames, index first: a getIndex between them (or after a crash between them) sees
// the new index beside the old signature and falls back to the baked index, and the .sig rename that follows must
// change the key, or that fallback stays resident until index.json changes again (refreshIndex re-stamps its mtime only
// when the publisher sent a Last-Modified and the Chtimes worked). The floor and the held envelope are in the key
// because they choose the key that checks the /data copy (NWP-20261129-18): a held object that arrives, changes or goes
// must drop a parse the old key accepted. acceptIndexKey writes them in two renames, so a parse between the two (no
// /data key) is dropped by the second. Each file has its own prefix letter, so a missing file and a present one never
// render the same key. If none of the six files is present the key is "" (no cache).
func indexCacheKey() string {
	k := ""
	for _, f := range []struct{ tag, path string }{
		{"s", indexSystemPath}, {"S", indexSystemPath + ".sig"},
		{"d", indexDataPath}, {"D", indexDataPath + ".sig"},
		{"q", indexKeySeqPath}, {"h", indexKeyHeldPath},
	} {
		if fi, err := os.Stat(f.path); err == nil {
			k += fmt.Sprintf("%s%d:%d;", f.tag, fi.ModTime().UnixNano(), fi.Size())
		}
	}
	return k
}

// getIndex returns the resident parsed index, (re)parsing only when a candidate file changed (or first call).
func getIndex() []catalogEntry {
	key := indexCacheKey()
	indexCache.mu.RLock()
	if key != "" && indexCache.key == key {
		e := indexCache.entries
		indexCache.mu.RUnlock()
		return e
	}
	indexCache.mu.RUnlock()

	b := loadIndexBytes()
	var c catalog
	if b == nil || json.Unmarshal(b, &c) != nil {
		indexCache.mu.Lock()
		indexCache.key, indexCache.entries, indexCache.gen = key, nil, 0
		indexCache.mu.Unlock()
		return nil
	}
	indexCache.mu.Lock()
	indexCache.key, indexCache.entries, indexCache.gen = key, c.Entries, c.Generated
	indexCache.mu.Unlock()
	return c.Entries
}

// cachedGenerated returns the `generated` of the currently-resident index (refreshing the cache first).
func cachedGenerated() int64 {
	getIndex()
	indexCache.mu.RLock()
	defer indexCache.mu.RUnlock()
	return indexCache.gen
}

// findIndexEntry returns the index entry for pkg (matching versionCode when vc>0; else latest), or nil.
func findIndexEntry(pkg string, vc int64) *catalogEntry {
	idx := getIndex() // capture once; a concurrent refresh keeps this slice alive for the returned pointer
	for i := range idx {
		if idx[i].Pkg == pkg && (vc == 0 || idx[i].VersionCode == vc) {
			return &idx[i]
		}
	}
	return nil
}

// findAppEntry: FETCH-APP resolves a pkg from the curated catalog FIRST (featured, hand-vetted), then falls back
// to the full trimmed index. For an index (long-tail) app a requested vc is ADVISORY -- pin it if that exact
// version is still indexed, else fall back to the latest indexed version rather than failing (F-Droid ages old
// versions out; docs/store-fdroid-search.md). The returned entry's OWN signingCert is what installStagedApk pins.
func findAppEntry(pkg string, vc int64) *catalogEntry {
	if e := findCatalogEntry(pkg, vc); e != nil {
		return e
	}
	if vc != 0 {
		if e := findIndexEntry(pkg, vc); e != nil {
			return e
		}
	}
	return findIndexEntry(pkg, 0) // latest indexed
}

// --- SEARCH-APPS: scan the resident index, rank, cap. Reply is a catalog-shaped JSON the chooser's renderCatalog
// consumes directly. apks are OMITTED (FETCH-APP re-resolves url/sha at install; smaller reply, no needless hash
// exposure) but signingCert/minSdk/antiFeatures are KEPT (client signer-pin + compat + anti-feature badges). ---

const searchMaxResults = 50
const searchMaxQuery = 100

type searchReply struct {
	Schema    int            `json:"schema"`
	Generated int64          `json:"generated,omitempty"`
	Query     string         `json:"query"`
	Truncated bool           `json:"truncated"`
	Entries   []catalogEntry `json:"entries"`
}

func rankScore(e *catalogEntry, q string) int {
	pkg, label, sum := strings.ToLower(e.Pkg), strings.ToLower(e.Label), strings.ToLower(e.Description)
	switch {
	case pkg == q || label == q:
		return 0
	case strings.HasPrefix(label, q):
		return 1
	case strings.Contains(" "+label, " "+q): // word-start inside the label
		return 2
	case strings.Contains(label, q) || strings.Contains(sum, q):
		return 3
	case strings.Contains(pkg, q) || strings.Contains(strings.ToLower(e.Category), q):
		return 4
	}
	return -1 // no match
}

// searchIndex merges the curated catalog (so play/nowhere-source + featured apps surface too, curated winning on a
// pkg collision) with the trimmed F-Droid index, ranks by relevance, and caps. An empty query returns the curated
// featured set (the storefront's default view). apks stripped from every returned entry.
func searchIndex(query string) searchReply {
	q := strings.ToLower(strings.TrimSpace(query))
	var curated catalog
	if b := loadCatalogBytes(); b != nil {
		_ = json.Unmarshal(b, &curated)
	}
	strip := func(e catalogEntry) catalogEntry { e.APKs = nil; return e }

	if q == "" { // default view = the featured/curated set
		out := make([]catalogEntry, 0, len(curated.Entries))
		for _, e := range curated.Entries {
			out = append(out, strip(e))
		}
		return searchReply{Schema: catalogSchema, Query: "", Entries: out}
	}

	seen := map[string]bool{}
	type scored struct {
		e catalogEntry
		s int
	}
	var hits []scored
	consider := func(e catalogEntry, fromIndex bool) {
		if seen[e.Pkg] {
			return
		}
		if s := rankScore(&e, q); s >= 0 {
			seen[e.Pkg] = true
			e.APKs = nil
			// Mark EVERY index result with iconRef == pkg. This does two jobs: (1) routes the icon to the LOCAL
			// pack (the chooser's FETCH-ICON <iconRef> becomes FETCH-ICON <pkg> -> servePackIcon, no f-droid.org
			// fetch/leak; a pkg absent from the pack -> nil -> the chooser's placeholder), and (2) is the marker
			// the chooser uses to show the "Not curated by Nowhere" trust badge. It MUST be set even when the
			// trimmed entry has NO iconRef (~10% of F-Droid apps ship no icon) -- otherwise those uncurated apps
			// would render badge-less and look vetted. Curated entries keep their own iconRef (a data: URI like
			// Signal's, or a featured f-droid URL) and get no badge.
			if fromIndex {
				e.IconRef = e.Pkg
			}
			hits = append(hits, scored{e, s})
		}
	}
	for _, e := range curated.Entries { // curated first -> wins pkg collisions
		consider(e, false)
	}
	idx := getIndex()
	for i := range idx {
		consider(idx[i], true)
	}
	sort.SliceStable(hits, func(i, j int) bool { return hits[i].s < hits[j].s })
	truncated := len(hits) > searchMaxResults
	if truncated {
		hits = hits[:searchMaxResults]
	}
	out := make([]catalogEntry, len(hits))
	for i := range hits {
		out[i] = hits[i].e
	}
	indexCache.mu.RLock()
	gen := indexCache.gen // populated by the getIndex() call above
	indexCache.mu.RUnlock()
	return searchReply{Schema: catalogSchema, Generated: gen, Query: query, Truncated: truncated, Entries: out}
}

// handleSearchApps: "SEARCH-APPS\n<query>\n" -> "OK <nbytes>\n<json>" | NONE (no index/catalog). Public metadata,
// ungated like GET-CATALOG. The query is sanitized (control chars stripped, then at most searchMaxQuery bytes,
// cut at a rune boundary) and results capped
// server-side, so a broad query can't turn into an unbounded scan/response.
func handleSearchApps(conn net.Conn, query string) {
	query = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, query)
	if len(query) > searchMaxQuery { // cut at a rune boundary: a split rune lowercases to U+FFFD and matches nothing
		cut := searchMaxQuery
		for cut > 0 && !utf8.RuneStart(query[cut]) {
			cut--
		}
		query = query[:cut]
	}
	rep := searchIndex(query)
	if rep.Entries == nil && strings.TrimSpace(query) != "" {
		rep.Entries = []catalogEntry{}
	}
	b, err := json.Marshal(rep)
	if err != nil {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	fmt.Fprintf(conn, "OK %d\n", len(b))
	conn.Write(b)
}

// --- REFRESH-INDEX: pull a fresh SIGNED trimmed index to /data so the app list + download URLs stay current
// (F-Droid drops old versions; a stale baked URL would 404). Mirrors refreshCatalog with a bigger read cap and a
// generation write-guard. LAZY: the client fires this in the background; SEARCH never blocks on it. A repeat refresh
// is conditional (If-Modified-Since), so an unchanged index costs one 304. ---

func indexRefreshURL() string {
	if u := strings.TrimRight(os.Getenv("INDEX_URL"), "/"); u != "" {
		return u
	}
	// GATEWAY_URL fallback: the gateway serves the index under the /fdroid/ prefix (GET /fdroid/{name},
	// nowhere-cloud #112), so derive "<gw>/fdroid/index.json" -- NOT "<gw>/index.json", which the gateway 404s.
	// This lets a device carrying only GATEWAY_URL (the common ring config) refresh without a separate INDEX_URL.
	if gw := strings.TrimRight(os.Getenv("GATEWAY_URL"), "/"); gw != "" {
		return gw + "/fdroid/index.json"
	}
	return ""
}

// indexHTTPGet: like catalogHTTPGet but a generous 32 MiB cap (a trimmed index is ~3 MB now but headroom for
// growth; still bounded so a hostile huge body fails closed after the sig check, not before). With a non-zero since
// it asks If-Modified-Since and reports a 304 as notModified (NWP-20261102-11); lastMod is the response's parsed
// Last-Modified, zero when absent or invalid.
func indexHTTPGet(url string, since time.Time) (body []byte, lastMod time.Time, notModified bool, err error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	if !since.IsZero() {
		req.Header.Set("If-Modified-Since", since.UTC().Format(http.TimeFormat))
	}
	resp, err := fetchAppHTTP.Do(req)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotModified && !since.IsZero() {
		return nil, time.Time{}, true, nil
	}
	if resp.StatusCode != 200 {
		return nil, time.Time{}, false, fmt.Errorf("%s -> HTTP %d", url, resp.StatusCode)
	}
	if t, e := http.ParseTime(resp.Header.Get("Last-Modified")); e == nil {
		lastMod = t
	}
	body, err = io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	return body, lastMod, false, err
}

// servedIndexDataMtime is the /data index's mtime, but only when loadIndexBytes would select that copy: a key is
// baked, the /data signature verifies under the selected key and /data is not older than the baked index. Zero (so no
// If-Modified-Since) otherwise -- only the baked copy, no selected key, a missing or bad /data signature, or a
// rollback-guarded /data. The next fetch must then be a full 200, never a 304 against a copy that is not in use. The
// selection is validated here, not inferred from byte equality with loadIndexBytes: a rejected /data copy can match
// the baked bytes.
func servedIndexDataMtime() time.Time {
	return servedIndexDataMtimeWith(currentIndexKey(time.Now().Unix()))
}

// servedIndexDataMtimeWith is servedIndexDataMtime with the /data key already selected, as in loadIndexBytesWith.
func servedIndexDataMtimeWith(dataKey string) time.Time {
	if indexPubKey == "" || dataKey == "" {
		return time.Time{}
	}
	fi, err := os.Stat(indexDataPath)
	if err != nil {
		return time.Time{}
	}
	d, err := os.ReadFile(indexDataPath)
	if err != nil || len(d) == 0 {
		return time.Time{}
	}
	sig, err := os.ReadFile(indexDataPath + ".sig")
	if err != nil || !verifyEd25519(dataKey, d, sig) {
		return time.Time{}
	}
	baked, _ := os.ReadFile(indexSystemPath)
	if indexGeneratedOf(d) < indexGeneratedOf(baked) {
		return time.Time{}
	}
	return fi.ModTime()
}

// errRefreshOff marks a refresh that is not configured (no key baked, no source URL). REFRESH-INDEX and
// REFRESH-CATALOG answer NONE on it and on nothing else; an error's text never decides the reply (NWP-20261127-17).
var errRefreshOff = errors.New("refresh off")

func refreshIndex() error {
	if strings.TrimSpace(indexPubKey) == "" {
		return fmt.Errorf("index refresh disabled: no index key baked: %w", errRefreshOff)
	}
	url := indexRefreshURL()
	if url == "" {
		return fmt.Errorf("index refresh: no source (set INDEX_URL or GATEWAY_URL): %w", errRefreshOff)
	}
	// The key the object selects (NWP-20261129-18, decision #8), read once: one refresh judges with one key. "" means the
	// phone accepts no /data refresh, so nothing is asked of the network. Not errRefreshOff: REFRESH-INDEX answers ERR.
	k := currentIndexKey(time.Now().Unix())
	if k == "" {
		return errors.New("index refresh: no /data refresh key is selected -- refusing")
	}
	body, lastMod, notModified, err := indexHTTPGet(url, servedIndexDataMtimeWith(k))
	if err != nil {
		return err
	}
	if notModified {
		return nil // 304: the served /data copy is current -- no .sig fetch, nothing written (NWP-20261102-11)
	}
	sig, _, _, err := indexHTTPGet(url+".sig", time.Time{}) // always unconditional
	if err != nil {
		return err
	}
	if !verifyEd25519(k, body, sig) {
		return fmt.Errorf("index refresh: fetched index signature invalid -- refusing")
	}
	var c catalog
	if json.Unmarshal(body, &c) != nil || c.Schema != catalogSchema {
		return fmt.Errorf("index refresh: fetched index is not a valid schema-%d catalog", catalogSchema)
	}
	// Anti-rollback + freshness + sanity. The /data copy is durable (NWP-20261017-34) and, with the baked /system
	// generation as the floor, is the high-water mark: refreshIndex compares against loadIndexBytes, which includes
	// /data. Bound how STALE a fetched index may be so a MITM / compromised mirror can't replay a months-old but
	// validly-signed index (freezing the device on a catalog that still lists a since-pulled or known-vulnerable app
	// -- authentic bytes/signer, so the per-app gates don't catch it). Residual: an attacker controlling the channel can still freeze within [now-maxIndexStaleness, now]; that
	// is bounded, not eliminated (a durable sealed high-water mark would be the full fix -- follow-up).
	now := time.Now().Unix()
	if c.Generated <= 0 || c.Generated > now+86400 {
		return fmt.Errorf("index refresh: bad generated=%d", c.Generated)
	}
	if c.Generated < now-maxIndexStaleness {
		return fmt.Errorf("index refresh: too stale (generated=%d, older than %dd) -- refusing", c.Generated, maxIndexStaleness/86400)
	}
	if c.Generated <= indexGeneratedOf(loadIndexBytesWith(k)) {
		return nil // already current or older -> no-op (not an error)
	}
	os.MkdirAll(filepath.Dir(indexDataPath), 0o700)
	if err := writeAtomicFile(indexDataPath, body); err != nil {
		return err
	}
	if err := writeAtomicFile(indexDataPath+".sig", sig); err != nil {
		return err
	}
	// Stamp the publisher's Last-Modified so the next If-Modified-Since compares server time with server time, not
	// the phone's clock (NWP-20261102-11). A failure costs only that; the signed files are installed.
	if !lastMod.IsZero() {
		if err := os.Chtimes(indexDataPath, lastMod, lastMod); err != nil {
			fmt.Fprintf(os.Stderr, "[index] refresh: could not stamp Last-Modified: %v\n", err)
		}
	}
	return nil
}

// handleRefreshIndex: "OK" (refreshed or already-current) | "NONE" (not configured: errRefreshOff) | "ERR" (fetch/verify failed).
func handleRefreshIndex(conn net.Conn) {
	err := refreshIndex()
	if err == nil {
		fmt.Fprint(conn, "OK\n")
		return
	}
	if errors.Is(err, errRefreshOff) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	fmt.Fprintf(os.Stderr, "[index] refresh: %v\n", err)
	fmt.Fprint(conn, "ERR\n")
}

// --- Icon pack: the baked icons.pack (ZIP, entry name == pkg) is served LOCALLY -- browsing the store never hits
// f-droid.org (the privacy win). Baked in /system => rides verified boot. Cached open (central directory + a
// pkg->entry map), rebuilt when the file changes. A pkg not in the pack (e.g. a brand-new app from a refresh) ->
// nil -> the client shows a placeholder (NEVER a live fetch, which would reintroduce the leak). ---

const packIconCap = 512 << 10 // an icon is a few KB; cap the per-entry read

type packCacheT struct {
	mu    sync.Mutex
	key   string
	rc    *zip.ReadCloser
	files map[string]*zip.File
}

var packCache packCacheT

func packFor(pkg string) *zip.File {
	if pkg == "" || strings.ContainsAny(pkg, "/\\") {
		return nil
	}
	fi, err := os.Stat(iconPackPath)
	if err != nil {
		return nil
	}
	key := fmt.Sprintf("%d:%d", fi.ModTime().UnixNano(), fi.Size())
	packCache.mu.Lock()
	defer packCache.mu.Unlock()
	if packCache.key != key || packCache.rc == nil {
		if packCache.rc != nil {
			packCache.rc.Close()
			packCache.rc = nil
		}
		rc, err := zip.OpenReader(iconPackPath)
		if err != nil {
			packCache.key, packCache.files = "", nil
			return nil
		}
		m := make(map[string]*zip.File, len(rc.File))
		for _, f := range rc.File {
			m[f.Name] = f
		}
		packCache.key, packCache.rc, packCache.files = key, rc, m
	}
	return packCache.files[pkg]
}

// servePackIcon returns the packed icon bytes for pkg, or nil if not present.
func servePackIcon(pkg string) []byte {
	f := packFor(pkg)
	if f == nil {
		return nil
	}
	rc, err := f.Open()
	if err != nil {
		return nil
	}
	defer rc.Close()
	b, err := io.ReadAll(io.LimitReader(rc, packIconCap))
	if err != nil || len(b) == 0 {
		return nil
	}
	return b
}
