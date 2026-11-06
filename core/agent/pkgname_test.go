package main

import (
	"io"
	"net"
	"strings"
	"testing"
)

func TestValidPkgName(t *testing.T) {
	good := []string{"org.fossify.math", "com.nowhere.chooser", "a.b", "A.B_c9", "com.example.app_1",
		"org.example." + strings.Repeat("seg.", 40) + "app"}
	bad := []string{"", ".", "..", ".a", "a.", "a.b.", "a..b", "-a", "a/b", "a\\b", "a b", "a\tb", "a\nb", "../etc",
		"a.b/../c", "a", "1a.b", "a.1b", "a._b", "é.b", "a.bé", "a.b-c", strings.Repeat("a", 254) + ".b"}
	for _, s := range good {
		if !validPkgName(s) {
			t.Errorf("validPkgName(%q) = false, want true", s)
		}
	}
	for _, s := range bad {
		if validPkgName(s) {
			t.Errorf("validPkgName(%q) = true, want false", s)
		}
	}
	if !validPkgName(strings.Repeat("a", 253) + ".b") {
		t.Errorf("255-byte name refused")
	}
}

// TestAppCodeVerbsRefuseDotNames: the three path-building verbs answer ERR-PKG for "." / ".." and friends before
// any session read (dest is an empty dir, so a verb that got past the guard would answer NONE instead).
func TestAppCodeVerbsRefuseDotNames(t *testing.T) {
	dest := t.TempDir()
	run := func(name string, h func(net.Conn)) {
		cli, srv := net.Pipe()
		go func() { h(srv); srv.Close() }()
		b, _ := io.ReadAll(cli)
		if got := strings.TrimSpace(string(b)); got != "ERR-PKG" {
			t.Errorf("%s: got %q want ERR-PKG", name, got)
		}
	}
	for _, bad := range []string{".", "..", ".a", "a..b", "single", "a/b"} {
		run("materialize "+bad, func(c net.Conn) { handleMaterializeApp(c, dest, bad, false) })
		run("materialize-prog "+bad, func(c net.Conn) { handleMaterializeApp(c, dest, bad, true) })
		run("restore-oddata "+bad, func(c net.Conn) { handleRestoreOdData(c, dest, bad) })
		run("fetch-app "+bad, func(c net.Conn) { handleFetchApp(c, dest, bad+" 3") })
	}
}
