package main

import (
	"go/ast"
	"net"
	"net/http"
	"sync/atomic"
	"testing"
)

// NWP-20261015-24: a throwaway's and an offline session's only protection against being sealed into the store was
// the one tmpfs marker `.localsession`. An offline session carries BOTH markers by construction, so every seal gate
// tests either (localOnlySession): a lost `.localsession` must not let a stored profile's empty offline session
// write over the real head (#72).

func TestLocalOnlySessionTruthTable(t *testing.T) {
	for _, c := range []struct {
		local, offline, want bool
	}{{false, false, false}, {true, false, true}, {false, true, true}, {true, true, true}} {
		dest := t.TempDir()
		if c.local {
			markLocalSession(dest)
		}
		if c.offline {
			markOfflineSession(dest)
		}
		if got := localOnlySession(dest); got != c.want {
			t.Errorf("localOnlySession(local=%v, offline=%v) = %v, want %v", c.local, c.offline, got, c.want)
		}
	}
}

// lograwSession stands up a signed-in session carrying exactly the markers asked for.
func lograwSession(t *testing.T, local, offline bool) string {
	t.Helper()
	// A mock cap store, so the "neither marker" control that passes the gate lands on a store that answers.
	dest, _ := createCodeEnv(t, "CODE-UNUSED", 1)
	if err := markRoamSession(dest, "alice", "a session that is gated", "12", ""); err != nil {
		t.Fatal(err)
	}
	if local {
		markLocalSession(dest)
	}
	if offline {
		markOfflineSession(dest)
	}
	return dest
}

func TestSealGatesRefuseEitherMarker(t *testing.T) {
	verbs := map[string]func(net.Conn, string){
		"BACKUP":              func(c net.Conn, d string) { handleBackup(c, d) },
		"EXPORT":              func(c net.Conn, d string) { handleExport(c, d, nil) },
		"EXPORT-MEDIA":        func(c net.Conn, d string) { handleExportMedia(c, d) },
		"GET-EXPORT-MANIFEST": func(c net.Conn, d string) { handleGetExportManifest(c, d) },
		"ROLLBACK":            func(c net.Conn, d string) { handleRollback(c, d, "1") },
	}
	for name, h := range verbs {
		for _, c := range []struct {
			label          string
			local, offline bool
			wantLocal      bool
		}{
			{"offline marker only", false, true, true},
			{"local marker only", true, false, true},
			{"both markers", true, true, true},
			{"neither marker", false, false, false},
		} {
			t.Run(name+"/"+c.label, func(t *testing.T) {
				dest := lograwSession(t, c.local, c.offline)
				got := ropReply(t, func(conn net.Conn) { h(conn, dest) })
				if (got == "LOCAL") != c.wantLocal {
					t.Errorf("%s with %s replied %q, wantLocal=%v", name, c.label, got, c.wantLocal)
				}
			})
		}
	}
}

// A claim into an offline-only (or throwaway) session redeems into the live wallet but seals nothing: no store
// request, and the plain "OK <n>" a throwaway gets (the credit rides the promote).
func TestClaimSealsNothingForALocalOnlySession(t *testing.T) {
	for _, c := range []struct {
		label          string
		local, offline bool
	}{{"offline marker only", false, true}, {"local marker only", true, false}} {
		t.Run(c.label, func(t *testing.T) {
			dest, wpath := createCodeEnv(t, "CODE-LOCAL", 2)
			var puts atomic.Int32
			capStorePutSeen = func(string, http.Header) { puts.Add(1) }
			if err := markRoamSession(dest, "alice", "a session that is gated", "12", ""); err != nil {
				t.Fatal(err)
			}
			if c.local {
				markLocalSession(dest)
			}
			if c.offline {
				markOfflineSession(dest)
			}
			if err := saveWallet(wpath, &Wallet{}); err != nil {
				t.Fatal(err)
			}
			if got := ropReply(t, func(conn net.Conn) { handleClaim(conn, dest, "CODE-LOCAL", false) }); got != "OK 2" {
				t.Errorf("CLAIM replied %q, want OK 2", got)
			}
			if n := puts.Load(); n != 0 {
				t.Errorf("CLAIM wrote %d object(s) to the store from a local-only session", n)
			}
		})
	}
}

// syncLoop and rekeyOnce are a loop and a tick: assert their gate in the source.
func TestPeriodicGatesCallLocalOnlySession(t *testing.T) {
	_, files := agentSource(t)
	want := map[string]bool{"syncLoop": false, "rekeyOnce": false, "handleClaimMode": false}
	for _, af := range files {
		for _, d := range af.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Body == nil {
				continue
			}
			if _, tracked := want[fd.Name.Name]; !tracked {
				continue
			}
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				if c, ok := n.(*ast.CallExpr); ok {
					if id, ok := c.Fun.(*ast.Ident); ok {
						if id.Name == "localOnlySession" {
							want[fd.Name.Name] = true
						}
						if id.Name == "isLocalSession" {
							t.Errorf("%s gates on isLocalSession alone -- use localOnlySession", fd.Name.Name)
						}
					}
				}
				return true
			})
		}
	}
	for fn, ok := range want {
		if !ok {
			t.Errorf("%s does not call localOnlySession", fn)
		}
	}
}
