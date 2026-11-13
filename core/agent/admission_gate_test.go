package main

import (
	"crypto/rand"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
)

// The one admission gate (Q082, FREE-1, decided 2026-10-20): installHeadroom sums EVERY scope of the profile
// (the gateway is asked about the bare ref alone, so the phone is the only party that knows the whole total)
// and measures it against coverage(), which on a lapse is the free allowance and not the entitled 0. These
// tests drive that through installHeadroom itself, with measured scope sizes, and pin by source that the
// store install is its only caller.

// admGateGateway answers POST /entitlement with reply and records the profile ref of every request.
func admGateGateway(t *testing.T, reply entitlementInfo) (*gatewayClient, *[]string) {
	t.Helper()
	var mu sync.Mutex
	seen := []string{}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /entitlement", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Profile string `json:"profile"`
		}
		json.NewDecoder(r.Body).Decode(&req)
		mu.Lock()
		seen = append(seen, req.Profile)
		mu.Unlock()
		json.NewEncoder(w).Encode(reply)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return newGatewayClient(srv.URL, gwDefault), &seen
}

func admGateRandomDir(t *testing.T, n int) string {
	t.Helper()
	dir := t.TempDir()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "payload.bin"), b, 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

// admGateProfile makes a profile with random bytes in the bare vault and in #media, and returns the MEASURED
// bare-scope bytes and whole-profile bytes (never assumed: sealing overhead varies).
func admGateProfile(t *testing.T, base, name, pass string, bareBytes, mediaBytes int) (bare, total int64) {
	t.Helper()
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	pushProfile(base, name, pass, admGateRandomDir(t, bareBytes))
	pushProfile(base, name+"#media", pass, admGateRandomDir(t, mediaBytes))
	bareRefs := map[string]int64{}
	if scopeFootprint(base, name, pass, nil, bareRefs) {
		t.Fatal("bare scope footprint is blind")
	}
	all, measured := profileFootprint(base, name, pass, nil)
	if !measured {
		t.Fatal("profile footprint not measured")
	}
	for _, sz := range bareRefs {
		if sz > 0 {
			bare += sz
		}
	}
	for _, sz := range all {
		if sz > 0 {
			total += sz
		}
	}
	if bare <= 0 || total-bare <= 0 {
		t.Fatalf("bare=%d total=%d: the profile is not split across scopes", bare, total)
	}
	return bare, total
}

func admGateWallet(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "wallet.json")
	saveWallet(p, &Wallet{})
	return p
}

// (a) a free profile whose bytes are split across scopes, each under the allowance and together over it.
func TestAdmissionGateSumsEveryScope(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "admgate-split", "horse battery staple correct"
	bare, total := admGateProfile(t, base, name, pass, 1<<20, 1<<20)
	media := total - bare
	c := bare + media/2
	if !(bare < c && media < c && c < total) {
		t.Fatalf("bare=%d media=%d covered=%d total=%d: need each scope under covered and the sum over it", bare, media, c, total)
	}
	g, seen := admGateGateway(t, entitlementInfo{FreeBytes: c, CoveredBytes: c})
	w := admGateWallet(t)

	fits, short, used, covered := installHeadroom(g, base, name, pass, w, 0, nil)
	if fits || used != total || covered != c || short != total-c {
		t.Errorf("fits=%v short=%d used=%d covered=%d, want false %d %d %d", fits, short, used, covered, total-c, total, c)
	}
	if want := []string{profileRefV2(name, pass)}; len(*seen) != 1 || (*seen)[0] != want[0] {
		t.Errorf("gateway was asked %v, want exactly the bare ref %v (Q082: the gateway stays per scope ref)", *seen, want)
	}
	const k = 4096
	if fits, short, _, _ := installHeadroom(g, base, name, pass, w, k, nil); fits || short != total+k-c {
		t.Errorf("with an add of %d: fits=%v short=%d, want false %d", k, fits, short, total+k-c)
	}
}

// (b) a lapsed profile (entitled 0, covered = free) is read-only over the free allowance.
func TestAdmissionGateLapsedIsReadOnlyOverTheFreeAllowance(t *testing.T) {
	cases := []struct {
		name    string
		profile string
		over    bool
		noCov   bool
	}{
		{"over", "admgate-lapse-over", true, false},
		{"under", "admgate-lapse-under", false, false},
		{"under, gateway without covered_bytes", "admgate-lapse-nocov", false, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			base := newHTTPStore(t)
			const pass = "horse battery staple correct"
			bare, total := admGateProfile(t, base, c.profile, pass, 1<<20, 1<<20)
			free := total + 4096
			if c.over {
				free = bare + (total-bare)/2
				if !(bare < free && free < total) {
					t.Fatalf("bare=%d free=%d total=%d: need bare < free < total", bare, free, total)
				}
			}
			ent := entitlementInfo{FreeBytes: free, EntitledBytes: 0, CoveredBytes: free}
			if c.noCov {
				ent.CoveredBytes = 0
			}
			g, _ := admGateGateway(t, ent)
			fits, short, _, covered := installHeadroom(g, base, c.profile, pass, admGateWallet(t), 1, nil)
			if covered != free {
				t.Errorf("covered=%d, want the free allowance %d on a lapse", covered, free)
			}
			if c.over {
				if fits || short != total+1-free {
					t.Errorf("fits=%v short=%d, want false %d", fits, short, total+1-free)
				}
			} else if !fits || short != 0 {
				t.Errorf("fits=%v short=%d, want true 0", fits, short)
			}
		})
	}
}

// (c) a lapsed profile under the allowance is refused by the size of the add alone.
func TestAdmissionGateLapsedRefusesByTheAddAlone(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "admgate-lapse-add", "horse battery staple correct"
	bare, total := admGateProfile(t, base, name, pass, 1<<20, 1<<20)
	const slack = 8192
	free := total + slack
	add := int64(slack + 4096)
	if !(add > slack && add <= free-bare) {
		t.Fatalf("add=%d slack=%d free-bare=%d: need slack < add <= free-bare so one scope alone would still fit", add, int64(slack), free-bare)
	}
	g, _ := admGateGateway(t, entitlementInfo{FreeBytes: free, CoveredBytes: free})
	w := admGateWallet(t)

	fits, short, used, _ := installHeadroom(g, base, name, pass, w, add, nil)
	if fits || used != total || short != total+add-free {
		t.Errorf("fits=%v short=%d used=%d, want false %d %d", fits, short, used, total+add-free, total)
	}
	if fits, short, _, _ := installHeadroom(g, base, name, pass, w, slack, nil); !fits || short != 0 {
		t.Errorf("an add of exactly the slack: fits=%v short=%d, want true 0", fits, short)
	}
}

// admGateFuncs maps every top-level func in the non-test sources to its comment-stripped body.
func admGateFuncs(t *testing.T) map[string]string {
	t.Helper()
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		// A body runs from its func line to the next top-level func line (or the end of the file), which
		// is coarser than funcBody but also reads the one-line funcs funcBody cannot close.
		lines := strings.Split(string(b), "\n")
		start, name := -1, ""
		flush := func(end int) {
			if start >= 0 {
				out[name] = strings.Join(stripComments(lines[start:end]), "\n")
			}
		}
		for i, l := range lines {
			if !strings.HasPrefix(l, "func ") {
				continue
			}
			flush(i)
			start, name = i, l // a method keeps its whole signature line as its key
			rest := l[len("func "):]
			if j := strings.Index(rest, "("); j > 0 {
				name = rest[:j]
			}
		}
		flush(len(lines))
	}
	return out
}

// (d) installHeadroom is called by the store install and the Keep switch (KEEP-HEADROOM, Q025) and nothing else; seals and DELETE never reach it.
func TestAdmissionGateHasOneCaller(t *testing.T) {
	funcs := admGateFuncs(t)
	var callers []string
	for n, body := range funcs {
		if n == "installHeadroom" {
			continue
		}
		if strings.Contains(body, "installHeadroom(") {
			callers = append(callers, n)
		}
	}
	sort.Strings(callers)
	if want := []string{"handleFetchApp", "keepHeadroomReply"}; strings.Join(callers, " ") != strings.Join(want, " ") {
		t.Errorf("installHeadroom is called from %v, want exactly %v", callers, want)
	}
	for _, n := range []string{"pushProfile", "handleBackup", "handleLogoff", "handleLogout",
		"handlePromote", "handlePromote2", "handleSealDelta", "handleSealDeltaWalk", "handleDelete",
		"handleDeleteSnapshot", "handleMaterializeApp", "restoreAppCode"} {
		body, ok := funcs[n]
		if !ok {
			t.Fatalf("func %s not found -- this test is stale, not the code", n)
		}
		if strings.Contains(body, "installHeadroom(") {
			t.Errorf("%s calls installHeadroom: a seal, a delete and a materialise are never gated", n)
		}
	}
}
