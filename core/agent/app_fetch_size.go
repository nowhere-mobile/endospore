package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"strings"
)

// appFetchSizeMaxPkgs bounds one APP-FETCH-SIZE request. A Play group is the tapped app plus a few stack members.
const appFetchSizeMaxPkgs = 16

// handleAppFetchSize answers APP-FETCH-SIZE (NWP-20261114-16, DECIDED 2026-10-24 dn-1023 #5: the first tap on an
// on-demand app that needs Play shows the size and asks before the fetch starts). The chooser sends the packages it
// is about to materialise; this reads the session's name#apps head and replies with what MATERIALIZE-APP of each
// would fetch, before any fetch starts. restoreAppCode sums the same bytes only once its fetch has begun.
// "APP-FETCH-SIZE\n<pkg>[ <pkg>...]\n" -> "OK <bytes> <files>" | NONE | LOCAL | ERR-PKG | ERR.
// It logs nothing: no package, profile name or ref leaves this function.
func handleAppFetchSize(conn net.Conn, dest string, r *bufio.Reader) {
	line, _ := r.ReadString('\n')
	pkgs := strings.Fields(strings.TrimRight(line, "\r\n"))
	if len(pkgs) == 0 || len(pkgs) > appFetchSizeMaxPkgs {
		fmt.Fprint(conn, "ERR-PKG\n")
		return
	}
	for _, p := range pkgs {
		if !validPkgName(p) {
			fmt.Fprint(conn, "ERR-PKG\n")
			return
		}
	}
	name, pass, _ := readRoamSession(dest)
	if name == "" {
		fmt.Fprint(conn, "NONE\n") // nobody signed in
		return
	}
	if isLocalSession(dest) {
		fmt.Fprint(conn, "LOCAL\n") // a throwaway/offline session has no store to fetch from
		return
	}
	loadFido2HmacEnv(dest) // a 2FA head opens via the enrolled key's cached hmac (the LIST-MEDIA-APPS case)
	// resolveKeySession and unseal panic on a damaged head: a blob whose hash does not match, a blob too short for
	// a nonce, a manifest that fails GCM. Each is ERR on the wire, never a dropped connection.
	var key, mb, pt []byte
	var ok bool
	if recovered(func() { key, mb, ok = resolveKeySession("s3", name+"#apps", pass, seFromSession(dest)) }) != nil || !ok {
		fmt.Fprint(conn, "ERR\n")
		return
	}
	if recovered(func() { pt = unseal(key, mb) }) != nil {
		fmt.Fprint(conn, "ERR\n")
		return
	}
	var m chunkManifest
	if len(pt) < len(cdcMagic) || string(pt[:len(cdcMagic)]) != string(cdcMagic) ||
		json.Unmarshal(pt[len(cdcMagic):], &m) != nil {
		fmt.Fprint(conn, "ERR\n")
		return
	}
	b, n := appFetchBytes(m, pkgs)
	fmt.Fprintf(conn, "OK %d %d\n", b, n)
}
