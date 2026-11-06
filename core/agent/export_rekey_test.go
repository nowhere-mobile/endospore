package main

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261010-02: the data export's device half (docs/data-export-rekey.md §2-§4). The keys are derived from the
// name AND the passphrase; every key the export writes is marked "export" through the lease's `expire`; Delete and a
// committed passphrase change empty the export and mark it "now"; a tied profile's media export is made with the
// session's chip secret; no key or proof reaches a log; the CLI readers read the new keys.

// Hooks mockCapStore (cap_test.go) consults, reset for every store it builds.
var (
	capStoreQuote         func(h http.Header, q *quoteInfo) // GET /quote: its Date header and its body, which the export epoch is read from
	capStoreIgnoresExpire bool                              // a gateway older than `expire`: it ignores the field and names nothing
)

// expireShapeRefusal is the gateway's `expire` rule (nowhere-cloud refuseExpire): the profile-less arm takes none, and
// each entry names a leased ref, carries a `when` it knows, and a 64-lowercase-hex proof whose exportKey is the ref.
func expireShapeRefusal(req leaseReq) string {
	if !req.Free && req.Profile == "" {
		return "expire requires profile"
	}
	for ref, e := range req.Expire {
		if _, ok := req.Refs[ref]; !ok {
			return "expire ref not in refs"
		}
		if e.When != expireExport && e.When != expireNow {
			return "bad expire when"
		}
		p, err := hex.DecodeString(e.Proof)
		if err != nil || hex.EncodeToString(p) != e.Proof || len(p) != 32 || exportKey(p) != ref {
			return "bad expire proof"
		}
	}
	return ""
}

// exportTestDay is 2026-10-10, the day of storekey's bundle golden.
const exportTestDay int64 = 20736

// pinExportDay makes day e both the gateway's epoch (a daily epoch_seconds and the Date on /quote) and the device's
// (exportClock). Call it after the store is built: mockCapStore resets its hooks.
func pinExportDay(t *testing.T, e int64) {
	t.Helper()
	at := time.Unix(e*exportDaySeconds+12*3600, 0).UTC()
	capStoreQuote = func(h http.Header, q *quoteInfo) {
		h.Set("Date", at.Format(http.TimeFormat))
		q.EpochSeconds = exportDaySeconds
	}
	old := exportClock
	exportClock = func() time.Time { return at }
	t.Cleanup(func() { exportClock = old })
}

// leaseLog records every /lease body the mock gateway reads, in order.
type leaseLog struct {
	mu   sync.Mutex
	reqs []leaseReq
}

func recordLeases() *leaseLog {
	l := &leaseLog{}
	capStoreLeaseSeen = func(req leaseReq) {
		l.mu.Lock()
		defer l.mu.Unlock()
		l.reqs = append(l.reqs, req)
	}
	return l
}

func (l *leaseLog) all() []leaseReq {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]leaseReq(nil), l.reqs...)
}

// marked is every lease that carried an `expire`.
func (l *leaseLog) marked() []leaseReq {
	var out []leaseReq
	for _, r := range l.all() {
		if len(r.Expire) > 0 {
			out = append(out, r)
		}
	}
	return out
}

func exportSortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func exportKeysOf(rs ...exportRef) []string {
	out := make([]string, 0, len(rs))
	for _, r := range rs {
		out = append(out, r.key)
	}
	sort.Strings(out)
	return out
}

// expectMarks checks one lease's `expire`: exactly rs, each with its own proof and `when`.
func expectMarks(t *testing.T, what string, req leaseReq, when string, rs ...exportRef) {
	t.Helper()
	if got, want := exportSortedKeys(req.Expire), exportKeysOf(rs...); strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("%s: the lease marked %d ref(s), want exactly the %d export ref(s) -- the marks are per ref, never "+
			"the wallet fold's or anything else in the flush", what, len(got), len(want))
	}
	for _, r := range rs {
		e := req.Expire[r.key]
		if e.When != when || e.Proof != hex.EncodeToString(r.proof) {
			t.Fatalf("%s: a mark carries when=%q and a proof that is not its key's own (want when=%q)", what, e.When, when)
		}
	}
}

// exportSession is a cap-mode device with (name, pass) created in the store and signed in at dest.
func exportSession(t *testing.T, name, pass string) (dest string, objs map[string][]byte, mu *sync.Mutex) {
	t.Helper()
	objs, mu = capLockEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_SE_SECRET", "")
	freeRenewedThrough = map[string]int64{}
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	pushFenceSeq, pushFenceSampled = 0, false // see rotateFixture: one test binary shares the fence sample
	dest = t.TempDir()
	if err := markRoamSession(dest, name, pass, "11", ""); err != nil {
		t.Fatal(err)
	}
	provenWallet(t, capWalletPath()) // NWP-20261013-20: a session whose restore landed
	return dest, objs, mu
}

// verb runs one daemon handler over a pipe and returns its reply.
func verb(fn func(net.Conn)) string {
	cli, srv := net.Pipe()
	go func() { fn(srv); srv.Close() }()
	b, _ := io.ReadAll(cli)
	return dropCreateProgress(strings.TrimSpace(string(b)))
}

func exportVerb(dest string, bundle []byte) string {
	return verb(func(c net.Conn) { handleExport(c, dest, bundle) })
}

func objAt(objs map[string][]byte, mu *sync.Mutex, key string) ([]byte, bool) {
	mu.Lock()
	defer mu.Unlock()
	b, ok := objs[key]
	return b, ok
}

func setObj(objs map[string][]byte, mu *sync.Mutex, key string, b []byte) {
	mu.Lock()
	defer mu.Unlock()
	objs[key] = b
}

// noLegacyExportKeys fails if anything was written at a name-keyed export key.
func noLegacyExportKeys(t *testing.T, objs map[string][]byte, mu *sync.Mutex) {
	t.Helper()
	mu.Lock()
	defer mu.Unlock()
	for k := range objs {
		if strings.Contains(k, "export/") {
			t.Fatalf("an object was written at a name-keyed export key (%d bytes of key) -- the export must write the "+
				"re-keyed refs only", len(k))
		}
	}
}

// The derivations, byte for byte, against nowhere-cloud internal/storekey's goldens (computed there outside Go, from
// K = the bytes 0..31). A label, the order of the hash input or the epoch's spelling that drifts fails here, before the
// phone and the page disagree about where an export is.
func TestExportKeyGoldens(t *testing.T) {
	k := make([]byte, 32)
	for i := range k {
		k[i] = byte(i)
	}
	for _, c := range []struct {
		name, proof, key string
		got              []byte
	}{
		{"docs", "328b592f83e2935e06d10374e55357880f7ed97cb7ea0633b49f421f03dbb2a8",
			"ref/55a200228a4bfdc087c87d339161e25d1199eb1d5aec0ca262dab31a073c43a7", exportDocsProof(k)},
		{"media", "75fcdad7fe9e82e680fb9cfd4e1f4acb8a38d9732d45aa42464efa6e378ead02",
			"ref/0fbde8eec61d436b439e683367561841e82eca4c8caf7dd65e96091170df2977", exportMediaProof(k)},
		{"bundle@20736", "db534aa4bf152bf3d5df0759af30d3024ecc451b703817ca4a3dde78d86776ae",
			"ref/6b2e2441aedbb72b6af3900202fc4698bc5e32fcd922d71ad71e64e0d1cb07d8", exportBundleProof(k, exportTestDay)},
	} {
		if hex.EncodeToString(c.got) != c.proof {
			t.Errorf("%s proof = %x, want %s", c.name, c.got, c.proof)
		}
		if got := exportKey(c.got); got != c.key {
			t.Errorf("%s key = %s, want %s", c.name, got, c.key)
		}
	}
	// The ref helpers apply the same derivations, and Delete's list is both pointers and days E-8 .. E, in that order.
	if r := exportDocsRef(k); r.key != "ref/55a200228a4bfdc087c87d339161e25d1199eb1d5aec0ca262dab31a073c43a7" ||
		r.name() != strings.TrimPrefix(r.key, "ref/") {
		t.Errorf("exportDocsRef = %s", r.key)
	}
	deriveKeyCache["goldenname\x00goldenpass"] = k // K for (goldenname, goldenpass) is the golden K
	t.Cleanup(func() { delete(deriveKeyCache, "goldenname\x00goldenpass") })
	rs := exportDeleteRefs("goldenname", "goldenpass", exportTestDay)
	if len(rs) != 2+exportBundleEpochs || exportBundleEpochs != 9 {
		t.Fatalf("exportDeleteRefs names %d refs, want both pointers and nine epochs of bundles", len(rs))
	}
	if rs[0].key != exportKey(exportDocsProof(k)) || rs[1].key != exportKey(exportMediaProof(k)) ||
		rs[len(rs)-1].key != "ref/6b2e2441aedbb72b6af3900202fc4698bc5e32fcd922d71ad71e64e0d1cb07d8" ||
		rs[2].key != exportKey(exportBundleProof(k, exportTestDay-8)) {
		t.Error("exportDeleteRefs is not docs, media, then the bundles of E-8 .. E")
	}
}

// The day is the gateway's, from its Date header, and the docs pointer holds it as plain decimal -- the page parses
// exactly that (cmd/exportwasm parseExportEpoch).
func TestParseExportEpochIsThePagesParser(t *testing.T) {
	for s, want := range map[string]int64{"20736": 20736, " 20736\n": 20736, "0020736": 20736} {
		if e, ok := parseExportEpoch(s); !ok || e != want {
			t.Errorf("parseExportEpoch(%q) = %d, %v", s, e, ok)
		}
	}
	for _, s := range []string{"", "-1", "1.5", "0x10", "20 736", "1234567890123456789"} {
		if _, ok := parseExportEpoch(s); ok {
			t.Errorf("parseExportEpoch(%q) accepted", s)
		}
	}
}

// The docs export writes the bundle of today's day and the pointer naming that day -- at the re-keyed refs and
// nowhere else, never ref/export/<name> -- and marks exactly those two "export", not the wallet the same flush folds.
func TestExportWritesOnlyTheRekeyedKeysAndMarksThem(t *testing.T) {
	const name, pass = "exporter", "correct horse export staple"
	dest, objs, mu := exportSession(t, name, pass)
	pinExportDay(t, exportTestDay)
	leases := recordLeases()
	bundle := []byte("PK\x03\x04 contacts.vcf calendar.ics -- an export bundle")

	if got := exportVerb(dest, bundle); got != "OK bytes="+itoa(len(bundle))+" words=0 expire=1 store=managed" {
		t.Fatalf("EXPORT replied %q", got)
	}
	k := deriveKey(name, pass)
	docs, b := exportDocsRef(k), exportBundleRef(k, exportTestDay)
	if v, ok := objAt(objs, mu, docs.key); !ok || string(v) != "20736" {
		t.Fatalf("the docs pointer holds %q (present %v), want the day 20736 in decimal", v, ok)
	}
	raw, ok := objAt(objs, mu, b.key)
	if !ok {
		t.Fatal("no bundle at the key of today's day")
	}
	dk := resolveDK("s3", name, pass, nil)
	if pt := unseal(dk, raw); !bytes.Equal(pt, bundle) {
		t.Fatal("the bundle does not open to the bytes exported")
	}
	noLegacyExportKeys(t, objs, mu)

	m := leases.marked()
	if len(m) != 1 {
		t.Fatalf("%d lease(s) carried expire, want the export's one", len(m))
	}
	expectMarks(t, "export", m[0], expireExport, docs, b)
	unmarked := 0
	for ref := range m[0].Refs {
		if _, ok := m[0].Expire[ref]; !ok {
			unmarked++
		}
	}
	if unmarked == 0 {
		t.Fatal("precondition: the export's flush folded no wallet, so this test cannot show the fold stays unmarked")
	}
}

// expire rides EVERY lease the flush makes: the free one, the entitled one after a 402, and the token-less retry after
// a 409. A mark that rode only the first would leave an export written through the paid arm to its ordinary life.
func TestExportExpireRidesEveryLeaseArm(t *testing.T) {
	for _, tc := range []struct {
		label  string
		plan   bool               // a funded plan waiting: planPending skips the free probe
		status func(leaseReq) int // the gateway's verdict; 0 = the mock's default handling
		want   int                // leases the flush makes
		check  func(t *testing.T, rs []leaseReq)
	}{
		{"free", false, nil, 1, func(t *testing.T, rs []leaseReq) {
			if !rs[0].Free {
				t.Fatal("the lease was not the free one")
			}
		}},
		{"entitled after a 402", false, func(r leaseReq) int {
			if r.Free {
				return http.StatusPaymentRequired
			}
			return http.StatusOK
		}, 2, func(t *testing.T, rs []leaseReq) {
			if !rs[0].Free || rs[1].Free {
				t.Fatal("want the free lease, then the entitled one")
			}
		}},
		{"the token-less retry after a 409", true, func(r leaseReq) int {
			if r.BuyGB > 0 {
				return http.StatusConflict
			}
			return http.StatusOK
		}, 2, func(t *testing.T, rs []leaseReq) {
			if rs[0].BuyGB == 0 || rs[1].BuyGB != 0 {
				t.Fatal("want the purchase, then the retry that withdraws it")
			}
		}},
	} {
		t.Run(tc.label, func(t *testing.T) {
			const name, pass = "exportarms", "every arm carries the mark"
			dest, _, _ := exportSession(t, name, pass)
			pinExportDay(t, exportTestDay)
			if tc.plan {
				toks, err := newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault).buyFaucet(5)
				if err != nil {
					t.Fatal(err)
				}
				if err := saveWallet(os.Getenv("NOWHERE_WALLET"), &Wallet{Tokens: toks, PlanGB: 1, PlanPeriods: 1}); err != nil {
					t.Fatal(err)
				}
			}
			if tc.status != nil {
				capStoreLeaseStatus = func(r leaseReq) (int, string) {
					if len(r.Expire) == 0 {
						return 0, ""
					}
					return tc.status(r), ""
				}
			}
			leases := recordLeases()
			if got := exportVerb(dest, []byte("bundle bytes")); !strings.HasPrefix(got, "OK ") || !strings.Contains(got, " expire=1") {
				t.Fatalf("EXPORT replied %q", got)
			}
			rs := leases.all()
			if len(rs) != tc.want {
				t.Fatalf("the flush made %d lease(s), want %d", len(rs), tc.want)
			}
			tc.check(t, rs)
			k := deriveKey(name, pass)
			for i, r := range rs {
				expectMarks(t, "lease "+itoa(i+1), r, expireExport, exportDocsRef(k), exportBundleRef(k, exportTestDay))
			}
		})
	}
}

// The phone promises the 7 days only when the gateway says it applied them: an older gateway ignores `expire` and
// names nothing, and the reply then says expire=0 -- for the docs half and the media half alike.
func TestExportReportsOnlyTheExpiryTheGatewayApplied(t *testing.T) {
	const name, pass = "olderwire", "the gateway predates expire"
	dest, _, _ := exportSession(t, name, pass)
	pinExportDay(t, exportTestDay)
	sealMediaScope(t, "s3", name, pass)
	capStoreIgnoresExpire = true
	if got := exportVerb(dest, []byte("bundle")); !strings.HasSuffix(got, " words=0 expire=0 store=managed") {
		t.Fatalf("EXPORT against an older gateway replied %q, want expire=0", got)
	}
	if got := verb(func(c net.Conn) { handleExportMedia(c, dest) }); !strings.HasSuffix(got, " words=0 expire=0 store=managed") {
		t.Fatalf("EXPORT-MEDIA against an older gateway replied %q, want expire=0", got)
	}
}

// ⚠ FAIL CLOSED: on the managed store the day is the gateway's, and a reply with no Date is an error -- never the
// device's clock, which would file the bundle under a day Delete and the page could disagree with.
func TestExportWithoutTheGatewaysDayWritesNothing(t *testing.T) {
	const name, pass = "nodate", "no date header today"
	dest, objs, mu := exportSession(t, name, pass)
	capStoreQuote = func(h http.Header, _ *quoteInfo) { h["Date"] = nil } // suppresses the server's own Date
	mu.Lock()
	before := len(objs)
	mu.Unlock()
	leases := recordLeases()
	if got := exportVerb(dest, []byte("bundle")); got != "ERR-STORE" {
		t.Fatalf("EXPORT with no gateway Date replied %q, want ERR-STORE", got)
	}
	if n := len(leases.all()); n != 0 {
		t.Fatalf("%d lease(s) were made for an export whose day could not be read", n)
	}
	mu.Lock()
	after := len(objs)
	mu.Unlock()
	if after != before {
		t.Fatalf("%d object(s) were written for an export whose day could not be read", after-before)
	}
}

// sealMediaScope seals a small #media tree for (name, pass) on base.
func sealMediaScope(t *testing.T, base, name, pass string) {
	t.Helper()
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload#media"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name+"#media", pass, d)
	pushFenceSeq, pushFenceSampled = 0, false
}

// The media export marks its pointer "export" and nothing it names: the manifest and chunks are the profile's own
// live media, kept by its footprint.
func TestMediaExportMarksItsPointerOnly(t *testing.T) {
	const name, pass = "mediaexporter", "pin the media manifest"
	dest, objs, mu := exportSession(t, name, pass)
	sealMediaScope(t, "s3", name, pass)
	leases := recordLeases()
	got := verb(func(c net.Conn) { handleExportMedia(c, dest) })
	if !strings.HasPrefix(got, "OK files=") || !strings.HasSuffix(got, " words=0 expire=1 store=managed") {
		t.Fatalf("EXPORT-MEDIA replied %q", got)
	}
	r := exportMediaRef(deriveKey(name, pass))
	m := leases.marked()
	if len(m) != 1 {
		t.Fatalf("%d lease(s) carried expire, want one", len(m))
	}
	expectMarks(t, "media export", m[0], expireExport, r)
	manHash, _, st := mediaHeadManifest("s3", name, pass, nil)
	if v, ok := objAt(objs, mu, r.key); st != mediaHeadOpen || !ok || string(v) != manHash {
		t.Fatal("the media pointer does not name the current #media manifest")
	}
	noLegacyExportKeys(t, objs, mu)
}

// tieMediaScope ties (name, pass) to tieSE1 and re-keys its #media scope to a random key only the chip and the index
// hold -- what a tie's background re-key leaves (docs/tie-scope-keys.md). Either store: the re-seal runs in a bracket
// of its own, which on the managed store leases and uploads what it re-sealed and on a direct one is a pass-through.
func tieMediaScope(t *testing.T, base, name, pass string) {
	t.Helper()
	v, dk, idx := sessionKeys(t, base, name, pass)
	var rk *scopeRekey
	var err error
	capWrite(name, pass, dk, func() { rk, err = prepareScopeRekey(base, name, pass, "#media", tieSE1, randBytes(32)) })
	if err != nil {
		t.Fatalf("prepare #media: %v", err)
	}
	v.Scopes = sealScopeIndex(dk, rekeyedIndex(idx, dk, []*scopeRekey{rk}))
	tieSlots(v, name, pass, tieSE1, dk)
	if err := publishSessionVault(base, name, pass, v, dk); err != nil {
		t.Fatal(err)
	}
	capWrite(name, pass, dk, func() { publishScopeRekeys(base, name, pass, []*scopeRekey{rk}) })
}

// A tied profile's media export is made with the session's chip secret (it was silently not made since
// NWP-20261008-03), and a #media head that exists but does not open is an error -- never "nothing sealed".
func TestTiedMediaExportIsMadeWithTheSessionSecret(t *testing.T) {
	const name, pass = "tiedmedia", "tied photos export too"
	t.Setenv("NOWHERE_SE_SECRET", "") // the daemon's environment: the secret only as an argument
	base := newHTTPStore(t)
	sealScopeFixture(t, base, name, pass)
	sealMediaScope(t, base, name, pass)
	pushFenceSeq, pushFenceSampled = 0, false
	tieMediaScope(t, base, name, pass)

	if _, _, _, err := exportMedia(base, name, pass, nil); err != errExportMediaLocked {
		t.Fatalf("a tied #media head opened by no key this call holds answered %v, want errExportMediaLocked -- the "+
			"phone would say there is nothing to export about a profile whose photos are in the store", err)
	}
	_, size, out, err := exportMedia(base, name, pass, tieSE1)
	if err != nil || size == 0 {
		t.Fatalf("the tied profile's media export was not made with its chip secret: %d bytes, err=%v", size, err)
	}
	if !out.words || out.managed {
		t.Fatalf("outcome %+v: a tied vault has no pass slot, so the page needs the 12 words; and this store is self-hosted", out)
	}
	manHash, _, st := mediaHeadManifest(base, name, pass, tieSE1)
	if got := getRef(base, exportMediaRef(deriveKey(name, pass)).name()); st != mediaHeadOpen || got != manHash {
		t.Fatal("the media pointer does not name the tied #media manifest")
	}

	const other = "nomediayet"
	createVault(base, other, pass)
	if _, _, _, err := exportMedia(base, other, pass, nil); err != errExportNoMedia {
		t.Fatalf("a profile with nothing under #media answered %v, want errExportNoMedia (NOMEDIA)", err)
	}
}

// Delete empties the export -- both pointers and the bundles of the last nine days that exist -- in one lease that
// names them with sizes 0 and marks them "now" with their proofs, then verifies them empty. It leaves a bundle older
// than nine days and the legacy name-keyed pointers alone, and leases no export ref that does not exist.
func TestDeletePurgesTheExport(t *testing.T) {
	const name, pass = "deleteexport", "delete takes the export"
	dest, objs, mu := exportSession(t, name, pass)
	pinExportDay(t, exportTestDay)
	sealMediaScope(t, "s3", name, pass)
	if got := exportVerb(dest, []byte("bundle")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("EXPORT replied %q", got)
	}
	if got := verb(func(c net.Conn) { handleExportMedia(c, dest) }); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("EXPORT-MEDIA replied %q", got)
	}
	k := deriveKey(name, pass)
	older, oldest, outside := exportBundleRef(k, exportTestDay-3), exportBundleRef(k, exportTestDay-8),
		exportBundleRef(k, exportTestDay-9)
	for _, r := range []exportRef{older, oldest, outside} {
		setObj(objs, mu, r.key, []byte("an earlier day's sealed bundle"))
	}
	legacy := map[string]string{"ref/export/" + name: "a stranger's pointer", "ref/export/" + name + "#media": "theirs too"}
	for key, v := range legacy {
		setObj(objs, mu, key, []byte(v))
	}
	leases := recordLeases()

	if got := deleteProfile("s3", name, pass); got != "deleted" {
		t.Fatalf("deleteProfile = %q, want deleted", got)
	}
	want := []exportRef{exportDocsRef(k), exportMediaRef(k), exportBundleRef(k, exportTestDay), older, oldest}
	m := leases.marked()
	if len(m) != 1 {
		t.Fatalf("%d lease(s) carried expire, want Delete's one", len(m))
	}
	expectMarks(t, "delete", m[0], expireNow, want...)
	if got, w := exportSortedKeys(m[0].Refs), exportKeysOf(want...); strings.Join(got, ",") != strings.Join(w, ",") {
		t.Fatalf("Delete's export lease named %d ref(s), want exactly the %d export refs that exist", len(got), len(w))
	}
	for _, size := range m[0].Refs {
		if size != 0 {
			t.Fatalf("Delete's export lease names a ref with size %d, want 0", size)
		}
	}
	for _, r := range want {
		if v, ok := objAt(objs, mu, r.key); !ok || len(v) != 0 {
			t.Fatal("an export ref still holds data after Delete")
		}
	}
	if v, _ := objAt(objs, mu, outside.key); string(v) != "an earlier day's sealed bundle" {
		t.Fatal("Delete touched a bundle older than nine days")
	}
	for key, v := range legacy {
		if got, _ := objAt(objs, mu, key); string(got) != v {
			t.Fatal("Delete touched a legacy name-keyed export pointer -- names collide, it may be a stranger's")
		}
	}
}

// One row held by another profile refuses the whole lease 403 (X1). Delete then leases one ref at a time, so every
// other ref is still emptied and marked, and reports the refused one: "unverified", never "deleted".
func TestDeleteLeasesOneRefAtATimeAfterA403(t *testing.T) {
	const name, pass = "foreignrow", "one row is not ours"
	dest, objs, mu := exportSession(t, name, pass)
	pinExportDay(t, exportTestDay)
	l := installHolderLedger()
	if got := exportVerb(dest, []byte("bundle")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("EXPORT replied %q", got)
	}
	k := deriveKey(name, pass)
	foreign := exportBundleRef(k, exportTestDay-2)
	setObj(objs, mu, foreign.key, []byte("held by somebody else"))
	// ...and one more bundle whose own lease meets a 503: a failure the purge must not call a refusal.
	broken := exportBundleRef(k, exportTestDay-4)
	setObj(objs, mu, broken.key, []byte("an older bundle"))
	ledger := capStoreLeaseStatus
	capStoreLeaseStatus = func(req leaseReq) (int, string) {
		if _, ok := req.Expire[broken.key]; ok && len(req.Refs) == 1 {
			return http.StatusServiceUnavailable, `{"error":"ledger unavailable"}`
		}
		return ledger(req)
	}
	l.mu.Lock()
	l.tags[foreign.key] = strings.Repeat("f", 64)
	l.mu.Unlock()
	leases := recordLeases()

	var got string
	logged := captureStderr(t, func() { got = deleteProfile("s3", name, pass) })
	if got != "unverified" {
		t.Fatalf("deleteProfile = %q with one export row held by another profile, want unverified", got)
	}
	if !strings.Contains(logged, "1 still refused by the gateway") || !strings.Contains(logged, "and 1 failed") {
		t.Fatalf("the purge did not tell the foreign row's 403 from the other ref's 503: %q", logged)
	}
	var single int
	for _, r := range leases.marked() {
		if len(r.Refs) == 1 {
			single++
		}
	}
	if single != 4 {
		t.Fatalf("%d one-ref lease(s) followed the 403, want one per export ref (4)", single)
	}
	for _, r := range []exportRef{exportDocsRef(k), exportBundleRef(k, exportTestDay)} {
		if v, ok := objAt(objs, mu, r.key); !ok || len(v) != 0 {
			t.Fatal("an export ref the profile holds was left with data after the 403 -- the one-ref retry did not run")
		}
	}
	if v, _ := objAt(objs, mu, foreign.key); string(v) != "held by somebody else" {
		t.Fatal("the foreign row's object was written")
	}
}

// problem is the verify rule: a gateway that honours `expire` names every entry, so one that named some but not all
// is not a purge; an older gateway names none, and its empty writes are what make the pointers read empty.
func TestExportPurgeProblem(t *testing.T) {
	two := exportPurge{sent: []string{"ref/a", "ref/b"}, applied: map[string]bool{}}
	if why := two.problem(); why != "" {
		t.Fatalf("an older gateway's purge (nothing named) reported %q", why)
	}
	two.applied["ref/a"] = true
	if two.problem() == "" {
		t.Fatal("a purge whose gateway marked one of two refs passed as done")
	}
	two.applied["ref/b"] = true
	if why := two.problem(); why != "" {
		t.Fatalf("a fully marked purge reported %q", why)
	}
	if (exportPurge{refused: []string{"ref/a"}}).problem() == "" || (exportPurge{err: errExportNone}).problem() == "" {
		t.Fatal("a refused ref or a failed purge passed as done")
	}
}

// A self-hosted store has no lease: Delete writes the export's refs empty, the bundles of the last nine days that
// exist included, and the "gone" path of a second Delete empties one the first left behind.
func TestDeleteEmptiesTheExportOnASelfHostedStore(t *testing.T) {
	const name, pass = "selfhosteddel", "no gateway here"
	base := newHTTPStore(t)
	pinExportDay(t, exportTestDay)
	createVault(base, name, pass)
	dk, v := resolveDKVault(base, name, pass, nil)
	out, err := exportDocs(base, name, pass, dk, v, []byte("bundle"))
	if err != nil || out.managed || out.expires {
		t.Fatalf("exportDocs on a self-hosted store: %+v, %v", out, err)
	}
	k := deriveKey(name, pass)
	older, outside := exportBundleRef(k, exportTestDay-5), exportBundleRef(k, exportTestDay-9)
	putRef(base, older.name(), "an earlier bundle")
	putRef(base, outside.name(), "a bundle from before the window")
	putRef(base, "export/"+name, "a legacy pointer")

	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("deleteProfile = %q", got)
	}
	for _, r := range []exportRef{exportDocsRef(k), exportBundleRef(k, exportTestDay), older} {
		if got, ok := getRefBytes(base, r.name()); !ok || len(got) != 0 {
			t.Fatal("an export ref still holds data after Delete on a self-hosted store")
		}
	}
	if getRef(base, outside.name()) == "" || getRef(base, "export/"+name) == "" {
		t.Fatal("Delete touched a bundle older than nine days, or the legacy pointer")
	}
	if ok, _ := storeRefExists(base, exportMediaRef(k).name()); ok {
		t.Fatal("Delete created the media pointer of a profile that never exported media")
	}

	putRef(base, older.name(), "left behind")
	if got := deleteProfile(base, name, pass); got != "gone" {
		t.Fatalf("second deleteProfile = %q, want gone", got)
	}
	if getRef(base, older.name()) != "" {
		t.Fatal("the gone path did not empty an export bundle the first Delete left behind")
	}
}

// A committed passphrase change empties and marks the OLD passphrase's export, in a lease of its own AFTER the
// rotation's, made as the new profile naming the old one as prior. A refused rotation marks nothing, and a "change" to
// the same passphrase leaves the live export alone.
func TestRotationRetiresTheOldExportOnlyAfterItCommits(t *testing.T) {
	const newpass = "the new passphrase for the export"
	t.Run("committed", func(t *testing.T) {
		const name, oldpass = "rotexport", "the old passphrase"
		dest, objs, mu := exportSession(t, name, oldpass)
		pinExportDay(t, exportTestDay)
		if got := exportVerb(dest, []byte("bundle")); !strings.HasPrefix(got, "OK ") {
			t.Fatalf("EXPORT replied %q", got)
		}
		leases := recordLeases()
		if _, err := rotateVault("s3", name, oldpass, newpass, nil, true); err != nil {
			t.Fatalf("rotateVault: %v", err)
		}
		k := deriveKey(name, oldpass)
		docs, b := exportDocsRef(k), exportBundleRef(k, exportTestDay)
		all := leases.all()
		if len(all) < 2 {
			t.Fatalf("%d lease(s) after a rotation", len(all))
		}
		last := all[len(all)-1]
		expectMarks(t, "the old export's mark", last, expireNow, docs, b)
		if last.Profile != profileRefV2(name, newpass) || strings.Join(last.Prior, ",") != profileRefV2(name, oldpass) {
			t.Fatal("the old export's lease is not made as the new profile naming the old one as prior")
		}
		for _, r := range all[:len(all)-1] {
			if len(r.Expire) > 0 {
				t.Fatal("a mark rode the rotation's own lease -- a rotation refused at publish would then have marked the export of the passphrase the user keeps")
			}
		}
		for _, r := range []exportRef{docs, b} {
			if v, ok := objAt(objs, mu, r.key); !ok || len(v) != 0 {
				t.Fatal("the old passphrase's export still holds data after the change")
			}
		}
	})
	t.Run("refused", func(t *testing.T) {
		const name, oldpass = "rotrefused", "the old passphrase"
		dest, objs, mu := exportSession(t, name, oldpass)
		pinExportDay(t, exportTestDay)
		if got := exportVerb(dest, []byte("bundle")); !strings.HasPrefix(got, "OK ") {
			t.Fatalf("EXPORT replied %q", got)
		}
		head := profileRefV2(name, newpass)
		t.Cleanup(func() {
			liftSealFence([]string{head})
			sealFenceHit = false
			clearSealExpectations()
		})
		if !armSealFence([]string{head}) {
			t.Fatal("precondition: could not arm the publish fence")
		}
		leases := recordLeases()
		if _, err := rotateVault("s3", name, oldpass, newpass, nil, true); err == nil {
			t.Fatal("precondition: the rotation was not refused")
		}
		if n := len(leases.marked()); n != 0 {
			t.Fatalf("%d lease(s) carried expire after a REFUSED rotation -- the export of the passphrase the user keeps", n)
		}
		k := deriveKey(name, oldpass)
		if v, _ := objAt(objs, mu, exportDocsRef(k).key); string(v) != "20736" {
			t.Fatal("a refused rotation emptied the export of the passphrase the user keeps")
		}
	})
	t.Run("same passphrase", func(t *testing.T) {
		const name, pass = "rotsame", "the only passphrase"
		dest, objs, mu := exportSession(t, name, pass)
		pinExportDay(t, exportTestDay)
		if got := exportVerb(dest, []byte("bundle")); !strings.HasPrefix(got, "OK ") {
			t.Fatalf("EXPORT replied %q", got)
		}
		leases := recordLeases()
		if _, err := rotateVault("s3", name, pass, pass, nil, true); err != nil {
			t.Fatalf("rotateVault to the same passphrase: %v", err)
		}
		if n := len(leases.marked()); n != 0 {
			t.Fatalf("%d lease(s) carried expire after a change to the SAME passphrase -- that export is the live one", n)
		}
		if v, _ := objAt(objs, mu, exportDocsRef(deriveKey(name, pass)).key); string(v) != "20736" {
			t.Fatal("a change to the same passphrase emptied the live export")
		}
	})
}

// On a self-hosted store the old passphrase's export is written empty inside the rotation's retire pass -- and a
// rotation refused at publish empties nothing.
func TestDirectRotationEmptiesTheOldExportInItsRetirePass(t *testing.T) {
	const oldpass, newpass = "the old direct passphrase", "the new direct passphrase"
	for _, refuse := range []bool{false, true} {
		t.Run(map[bool]string{false: "committed", true: "refused"}[refuse], func(t *testing.T) {
			name := map[bool]string{false: "directrot", true: "directrefused"}[refuse]
			t.Setenv("NOWHERE_STATE", t.TempDir())
			base := newHTTPStore(t)
			pinExportDay(t, exportTestDay)
			createVault(base, name, oldpass)
			pushFenceSeq, pushFenceSampled = 0, false
			dk, v := resolveDKVault(base, name, oldpass, nil)
			if _, err := exportDocs(base, name, oldpass, dk, v, []byte("bundle")); err != nil {
				t.Fatal(err)
			}
			if refuse {
				head := profileRefV2(name, newpass)
				t.Cleanup(func() {
					liftSealFence([]string{head})
					sealFenceHit = false
					clearSealExpectations()
				})
				if !armSealFence([]string{head}) {
					t.Fatal("precondition: could not arm the publish fence")
				}
			}
			_, err := rotateVault(base, name, oldpass, newpass, nil, true)
			if refuse != (err != nil) {
				t.Fatalf("rotateVault: %v (refused=%v)", err, refuse)
			}
			k := deriveKey(name, oldpass)
			docs := getRef(base, exportDocsRef(k).name())
			bundle := getRef(base, exportBundleRef(k, exportTestDay).name())
			if refuse && (docs != "20736" || bundle == "") {
				t.Fatal("a refused rotation emptied the export of the passphrase the user keeps")
			}
			if !refuse && (docs != "" || bundle != "") {
				t.Fatal("a committed rotation left the old passphrase's export readable on a self-hosted store")
			}
		})
	}
}

// Neither an export key nor a proof reaches the daemon's log: a cap error that names the key it was about is
// redacted on the way out.
func TestExportErrorsCarryNoKey(t *testing.T) {
	const name, pass = "quietlog", "keys stay out of the log"
	dest, _, _ := exportSession(t, name, pass)
	pinExportDay(t, exportTestDay)
	k := deriveKey(name, pass)
	docs, b := exportDocsRef(k), exportBundleRef(k, exportTestDay)
	capStoreLeasePresent = []string{docs.key} // capFlush refuses a pointer listed as present, naming its key
	var reply string
	logged := captureStderr(t, func() { reply = exportVerb(dest, []byte("bundle")) })
	if reply != "ERR-STORE" {
		t.Fatalf("EXPORT replied %q, want ERR-STORE", reply)
	}
	if !strings.Contains(logged, "ref/<ref>") {
		t.Fatalf("precondition: the export's error line does not name a redacted key, so this test shows nothing: %q", logged)
	}
	for _, s := range []string{docs.name(), b.name(), hex.EncodeToString(docs.proof), hex.EncodeToString(b.proof)} {
		if strings.Contains(logged, s) {
			t.Fatal("an export key or proof reached the log")
		}
	}
	h := strings.Repeat("ab", 32)
	if got := redactNameIn("cap GET ref/"+h+" -> 500; ref%2F"+strings.ToUpper(h)+" too", "someone"); strings.Contains(strings.ToLower(got), h) {
		t.Fatalf("redactNameIn left a ref/<64 hex> in %q", got)
	}
	if got := redactNameIn(`Put "https://r2.example/b/ref/x?X-Amz-Credential=cred&X-Amz-Signature=sig": EOF`, "someone"); strings.Contains(got, "X-Amz-") {
		t.Fatalf("redactNameIn left a presigned URL's query in %q", got)
	}
}

// sealedStartsWithSpace finds a bundle whose sealed form begins with a whitespace byte -- what a trimming reader cuts.
func sealedStartsWithSpace(t *testing.T, dk []byte) []byte {
	t.Helper()
	for i := 0; i < 20000; i++ {
		b := []byte("PK bundle " + itoa(i))
		if s := seal(dk, b); s[0] == ' ' || s[0] == '\n' || s[0] == '\t' || s[0] == '\r' {
			return b
		}
	}
	t.Fatal("no bundle with a leading-whitespace seal found")
	return nil
}

// export-fetch reads the bundle of the pointer's day RAW (getRef trims, and a sealed byte can be whitespace), and
// falls back to the legacy name-keyed pointer only when no re-keyed export is there.
func TestExportFetchReadsTheRekeyedBundleRaw(t *testing.T) {
	const name, pass = "fetchdocs", "the cli reads the new keys"
	base := newHTTPStore(t)
	pinExportDay(t, exportTestDay)
	createVault(base, name, pass)
	dk, v := resolveDKVault(base, name, pass, nil)

	legacy := []byte("a bundle an older agent exported")
	putRef(base, "export/"+name, postBlob(base, seal(dk, legacy)))
	if got, err := exportFetchDocs(base, name, pass); err != nil || !bytes.Equal(got, legacy) {
		t.Fatalf("with only a legacy export, export-fetch read %q, %v", got, err)
	}

	bundle := sealedStartsWithSpace(t, dk)
	if _, err := exportDocs(base, name, pass, dk, v, bundle); err != nil {
		t.Fatal(err)
	}
	got, err := exportFetchDocs(base, name, pass)
	if err != nil || !bytes.Equal(got, bundle) {
		t.Fatalf("export-fetch read %q, %v; want the re-keyed bundle, read raw, ahead of the legacy one", got, err)
	}
	if _, err := exportFetchDocs(base, name, "wrong passphrase"); err != errExportNoProfile {
		t.Fatalf("a wrong passphrase answered %v", err)
	}
}

// export-fetch-media opens the pinned manifest through the vault's scope index -- here its Prev: the export was pinned
// after a passphrase change (the scope keeps its ORIGINAL key) and before a tie re-keyed the scope to a random key, so
// neither the current #media head's key nor deriveKey(name#media, pass) opens it.
func TestExportFetchMediaOpensThroughTheScopeIndex(t *testing.T) {
	const name, oldpass, pass = "fetchmedia", "the first passphrase", "the passphrase after the change"
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_SE_SECRET", "")
	base := newHTTPStore(t)
	sealScopeFixture(t, base, name, oldpass)
	sealMediaScope(t, base, name, oldpass)
	if _, err := rotateVault(base, name, oldpass, pass, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	if _, _, _, err := exportMedia(base, name, pass, nil); err != nil {
		t.Fatalf("exportMedia: %v", err)
	}
	tieMediaScope(t, base, name, pass)
	t.Setenv("NOWHERE_SE_SECRET", hex.EncodeToString(tieSE1)) // the CLI on the device: the worker's environment
	if k, _, ok := resolveKey(base, name+"#media", pass); ok {
		if pt, err := func() (p []byte, err error) {
			err = recovered(func() { p = unseal(k, getBlob(base, exportMediaPointer(base, name, pass))) })
			return
		}(); err == nil && len(pt) > 0 {
			t.Fatal("precondition: the current #media head's key opens the pinned manifest, so the index is not needed")
		}
	}
	out := t.TempDir()
	if err := exportFetchMedia(base, name, pass, out); err != nil {
		t.Fatalf("exportFetchMedia: %v", err)
	}
	if b, err := os.ReadFile(filepath.Join(out, "f.txt")); err != nil || string(b) != "payload#media" {
		t.Fatalf("the media export restored %q (%v)", b, err)
	}
}

// The phone's copy reads the flags the daemon writes (no Java harness exists, so these pin the source, as
// se_optin_pin_test.go does): the result line promises "about 7 days" only on expire=1, says nothing of the website
// on a self-hosted store, names the 12 words on words=1 -- and the field names it parses are the ones exportOutcome
// writes. The Leave screen no longer promises the export "for as long as your plan runs".
func TestTheChooserReadsTheExportFlags(t *testing.T) {
	prof := chooserCode(t, "ProfileActivity.java")
	if !strings.Contains(prof, `exportWhereLine(docsOk ? r : null, mediaOk ? mr : null)`) {
		t.Fatal("the export result line no longer takes what it promises from the replies of the halves that landed")
	}
	if strings.Contains(prof, `"your export stays available for about 7 days."`) {
		t.Fatal("the export result line promises 7 days unconditionally again")
	}
	for _, want := range []string{
		`if (!any || self) return "";`,
		`(words ? " and your 12-word recovery code" : "")`,
		`(expire ? " — it stays available for about 7 days." : ".")`,
		`expire &= "1".equals(exportFlag(r, "expire"));`,
	} {
		if !strings.Contains(prof, want) {
			t.Errorf("exportWhereLine lost %q", want)
		}
	}
	flags := exportOutcome{words: true, expires: true, managed: true}.flags() + exportOutcome{}.flags()
	for _, m := range regexp.MustCompile(`exportFlag\(r, "([a-z]+)"\)`).FindAllStringSubmatch(prof, -1) {
		if !strings.Contains(flags, " "+m[1]+"=") {
			t.Errorf("the chooser parses %q, which the daemon's reply never carries", m[1])
		}
	}
	for _, v := range []string{"words=1", "expire=1", "store=managed", "words=0", "expire=0", "store=self"} {
		if !strings.Contains(flags, " "+v) {
			t.Errorf("the daemon's reply flags lost %q", v)
		}
	}
	gate := chooserCode(t, "ChooserActivity.java")
	if strings.Contains(gate, "for as long as your plan runs") || !strings.Contains(gate, "for about 7 days after it is made") ||
		!strings.Contains(gate, "On the nowhere store, the export page") || !strings.Contains(gate, "12-word recovery code") {
		t.Fatal("the Leave screen promises the export for as long as the plan runs, or not in words true of every store and profile")
	}
}

// The export reads its bracket's verdict: a publish the store refused (here the delete fence on the docs pointer) is an
// error the phone shows, never "Exported".
func TestExportReportsARefusedPublish(t *testing.T) {
	const name, pass = "refusedexport", "the pointer is fenced"
	dest, _, _ := exportSession(t, name, pass)
	pinExportDay(t, exportTestDay)
	docs := exportDocsRef(deriveKey(name, pass))
	t.Cleanup(func() {
		liftSealFence([]string{docs.name()})
		sealFenceHit = false
	})
	if !armSealFence([]string{docs.name()}) {
		t.Fatal("precondition: could not arm the publish fence")
	}
	if got := exportVerb(dest, []byte("bundle")); got != "ERR-STORE" {
		t.Fatalf("EXPORT whose pointer the store refused replied %q, want ERR-STORE", got)
	}
}

// Delete verifies the export the way it verifies every scope: each ref it emptied must READ empty. A store that answers
// 2xx to the empty PUT without writing it leaves the export readable, and that is "unverified", never "deleted".
func TestDeleteVerifiesTheExportReadsEmpty(t *testing.T) {
	const name, pass = "unwrittenexport", "the store says yes and does nothing"
	dest, _, _ := exportSession(t, name, pass)
	pinExportDay(t, exportTestDay)
	if got := exportVerb(dest, []byte("bundle")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("EXPORT replied %q", got)
	}
	b := exportBundleRef(deriveKey(name, pass), exportTestDay).key
	capStorePutStatus = func(key string, _ http.Header) (int, string) {
		if key == b {
			return http.StatusOK, "" // acknowledged, not written
		}
		return 0, ""
	}
	if got := deleteProfile("s3", name, pass); got != "unverified" {
		t.Fatalf("deleteProfile = %q while the export's bundle still reads back, want unverified", got)
	}
}

// A passphrase change A->B marks A's export for the next GC in a lease made as B, so until GC runs those rows are held
// by B. Changed back to A before then, the export is at A's keys again -- and its lease must name B, which the change
// back recorded as !bill-retag, or the gateway refuses it 403 (X1). Both halves carry the record, as a bare seal does.
func TestExportAfterAChangeBackNamesTheRecordedKey(t *testing.T) {
	const name, passA, passB = "changeback", "the first passphrase", "the passphrase in between"
	dest, _, _ := exportSession(t, name, passA)
	pinExportDay(t, exportTestDay)
	l := installHolderLedger()
	sealMediaScope(t, "s3", name, passA)
	if got := exportVerb(dest, []byte("bundle")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("EXPORT replied %q", got)
	}
	if got := verb(func(c net.Conn) { handleExportMedia(c, dest) }); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("EXPORT-MEDIA replied %q", got)
	}
	if _, err := rotateVault("s3", name, passA, passB, nil, true); err != nil {
		t.Fatalf("rotateVault A->B: %v", err)
	}
	pushFenceSeq, pushFenceSampled = 0, false
	if _, err := rotateVault("s3", name, passB, passA, nil, true); err != nil {
		t.Fatalf("rotateVault B->A: %v", err)
	}
	k, keyB := deriveKey(name, passA), profileRefV2(name, passB)
	for _, r := range []exportRef{exportDocsRef(k), exportMediaRef(k), exportBundleRef(k, exportTestDay)} {
		if l.tag(r.key) != keyB {
			t.Fatal("precondition: an export row of A's is not held by the intermediate key B")
		}
	}
	if _, dk, idx := sessionKeys(t, "s3", name, passA); dk == nil || !containsString(billRetagOf(idx), keyB) {
		t.Fatal("precondition: the change back to A did not record B as !bill-retag")
	}
	leases := recordLeases()
	if got := exportVerb(dest, []byte("bundle again")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("EXPORT after A->B->A replied %q -- refused on the rows B still holds", got)
	}
	if got := verb(func(c net.Conn) { handleExportMedia(c, dest) }); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("EXPORT-MEDIA after A->B->A replied %q -- refused on the row B still holds", got)
	}
	m := leases.marked()
	if len(m) != 2 {
		t.Fatalf("%d export lease(s), want the docs and the media one", len(m))
	}
	for _, r := range m {
		if !containsString(r.Prior, keyB) {
			t.Fatal("an export lease did not name the recorded key B as prior")
		}
	}
}

// On a self-hosted store a "change" to the same passphrase leaves the export alone: it is the live one.
func TestDirectRotationToTheSamePassphraseKeepsTheExport(t *testing.T) {
	const name, pass = "directsame", "the only direct passphrase"
	t.Setenv("NOWHERE_STATE", t.TempDir())
	base := newHTTPStore(t)
	pinExportDay(t, exportTestDay)
	createVault(base, name, pass)
	pushFenceSeq, pushFenceSampled = 0, false
	dk, v := resolveDKVault(base, name, pass, nil)
	if _, err := exportDocs(base, name, pass, dk, v, []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	if _, err := rotateVault(base, name, pass, pass, nil, true); err != nil {
		t.Fatalf("rotateVault to the same passphrase: %v", err)
	}
	k := deriveKey(name, pass)
	if getRef(base, exportDocsRef(k).name()) != "20736" || getRef(base, exportBundleRef(k, exportTestDay).name()) == "" {
		t.Fatal("a change to the same passphrase emptied the live export on a self-hosted store")
	}
}

// ⚠ A DELETE WHOSE EXPORT PURGE FAILS DELETES NOTHING. "unverified" reaches the chooser as "nothing was deleted", so
// the purge runs before every tombstone and before the fence: when it fails, the head and the recovery ref still
// resolve, and the session can still seal (no fence was armed).
func TestDeleteWhoseExportPurgeFailsLeavesTheProfileWhole(t *testing.T) {
	const name, pass = "purgefails", "the export purge meets a 503"
	dest, _, _ := exportSession(t, name, pass)
	pinExportDay(t, exportTestDay)
	if got := exportVerb(dest, []byte("bundle")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("EXPORT replied %q", got)
	}
	capStoreLeaseStatus = func(req leaseReq) (int, string) {
		if len(req.Expire) > 0 {
			return http.StatusServiceUnavailable, `{"error":"ledger unavailable"}`
		}
		return 0, ""
	}
	if got := deleteProfile("s3", name, pass); got != "unverified" {
		t.Fatalf("deleteProfile = %q while the export purge failed, want unverified", got)
	}
	if _, _, ok := resolveKey("s3", name, pass); !ok {
		t.Fatal("the profile's head no longer resolves after a Delete that answered: nothing was deleted")
	}
	v, err := readSessionVault("s3", name, pass)
	if err != nil || v.RecoveryRef == "" || getRef("s3", v.RecoveryRef) == "" {
		t.Fatal("the recovery ref no longer resolves after a Delete that answered: nothing was deleted")
	}
	t.Cleanup(func() { liftSealFence(scopedDeleteRefs(name, pass)) })
	if sealFenceBlocks(profileRefV2(name, pass)) {
		t.Fatal("the failed Delete armed the publish fence: the session that is still signed in can no longer seal")
	}
}

// DELETE answers BUSY rather than wait for sessionMu, so the dispatcher counts it once it holds the lock: while it runs,
// no re-key batch starts (its export purge is a bracket). Driven through the dispatcher, as the chooser sends it.
func TestDeleteVerbHoldsTheReKeyOffWhileItRuns(t *testing.T) {
	const name, pass = "deletecounts", "the delete holds the re-key off"
	dest, _, _ := exportSession(t, name, pass)
	var during atomic.Int32
	during.Store(-1)
	capStoreQuote = func(h http.Header, _ *quoteInfo) {
		during.Store(sessionVerbsInFlight.Load()) // the export purge reads the gateway's epoch first
		h["Date"] = nil                           // ...and fails there, so nothing is deleted
	}
	if got := driveLogin(t, dest, "DELETE\n"+name+"\n"+pass+"\n"); got != "ERR-STORE" {
		t.Fatalf("DELETE replied %q, want ERR-STORE (the purge could not read the epoch)", got)
	}
	if n := during.Load(); n < 1 {
		t.Fatalf("while DELETE ran, %d session verb(s) were counted in flight -- a re-key batch could start under it", n)
	}
	if n := sessionVerbsInFlight.Load(); n != 0 {
		t.Fatalf("%d session verb(s) still counted after DELETE answered", n)
	}
}

// ROTATE answers BEFORE the old passphrase's export is retired: the retirement is a gateway read, a probe and leases,
// and inside the 75s reply budget it could make a committed change read as a dead socket.
func TestRotateRepliesBeforeItRetiresTheOldExport(t *testing.T) {
	const name, oldpass, newpass = "rotatereply", "the passphrase before", "the passphrase after the change"
	dest, objs, mu := exportSession(t, name, oldpass)
	pinExportDay(t, exportTestDay)
	stubRekey(t, "OK")
	if got := exportVerb(dest, []byte("bundle")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("EXPORT replied %q", got)
	}
	replied := make(chan struct{})
	var beforeReply, marked atomic.Bool
	capStoreLeaseSeen = func(req leaseReq) {
		if len(req.Expire) == 0 {
			return
		}
		marked.Store(true)
		select {
		case <-replied:
		case <-time.After(3 * time.Second):
			beforeReply.Store(true) // the retirement ran while the client was still waiting for its answer
		}
	}
	c1, c2 := net.Pipe()
	done := make(chan struct{})
	go func() {
		handleRotate(c2, dest, name, oldpass, newpass)
		c2.Close()
		close(done)
	}()
	line, _ := bufio.NewReader(c1).ReadString('\n')
	close(replied)
	go io.Copy(io.Discard, c1)
	<-done
	c1.Close()
	if !strings.HasPrefix(line, "OK ") {
		t.Fatalf("ROTATE replied %q", line)
	}
	if beforeReply.Load() {
		t.Fatal("the old passphrase's export was retired BEFORE ROTATE answered")
	}
	if !marked.Load() {
		t.Fatal("the old passphrase's export was never retired after the reply")
	}
	if v, ok := objAt(objs, mu, exportDocsRef(deriveKey(name, oldpass)).key); !ok || len(v) != 0 {
		t.Fatal("the old passphrase's docs pointer still holds data after the change")
	}
}

// The media export VERB of a tied session, on the managed store: made with the chip secret from the session marker
// (both the #media head and the vault open only with it), and its reply names the 12 words -- the vault has no
// passphrase slot.
func TestTiedSessionMediaExportVerbNamesTheTwelveWords(t *testing.T) {
	const name, pass = "tiedverb", "a tied profile exports its photos"
	dest, _, _ := exportSession(t, name, pass)
	pinExportDay(t, exportTestDay)
	sealMediaScope(t, "s3", name, pass)
	tieMediaScope(t, "s3", name, pass)
	if err := markRoamSession(dest, name, pass, "11", hex.EncodeToString(tieSE1)); err != nil {
		t.Fatal(err)
	}
	got := verb(func(c net.Conn) { handleExportMedia(c, dest) })
	if !strings.HasPrefix(got, "OK files=") || !strings.HasSuffix(got, " words=1 expire=1 store=managed") {
		t.Fatalf("EXPORT-MEDIA of a tied session replied %q, want OK ... words=1 expire=1 store=managed", got)
	}
}

// The export epoch is the GATEWAY's, in the gateway's own epoch length (the /quote reply's epoch_seconds), not a day
// the device assumes; a reply that states no epoch_seconds is an error, not a guess.
func TestExportEpochIsTheGatewaysOwnEpoch(t *testing.T) {
	const name, pass = "hourlyepoch", "the gateway counts in hours"
	dest, objs, mu := exportSession(t, name, pass)
	at := time.Unix(exportTestDay*exportDaySeconds+5*3600+120, 0).UTC()
	capStoreQuote = func(h http.Header, q *quoteInfo) {
		h.Set("Date", at.Format(http.TimeFormat))
		q.EpochSeconds = 3600
	}
	if got := exportVerb(dest, []byte("bundle")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("EXPORT replied %q", got)
	}
	e := at.Unix() / 3600
	if v, _ := objAt(objs, mu, exportDocsRef(deriveKey(name, pass)).key); string(v) != strconv.FormatInt(e, 10) {
		t.Fatalf("the docs pointer names epoch %q, want the gateway's hourly epoch %d", v, e)
	}
	capStoreQuote = func(h http.Header, q *quoteInfo) {
		h.Set("Date", at.Format(http.TimeFormat))
		q.EpochSeconds = 0
	}
	if got := exportVerb(dest, []byte("bundle")); got != "ERR-STORE" {
		t.Fatalf("EXPORT against a /quote with no epoch_seconds replied %q, want ERR-STORE", got)
	}
}
