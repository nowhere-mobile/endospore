package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
)

// KEEP-HEADROOM (Q025 [BA], decided 2026-10-20): turning on Keep counts the app's own size against the plan, and
// refuses when the app would push the profile over it, not only when the profile is already over (the chooser's
// overPlan reads GET-ENTITLEMENT's used > covered and never adds the app). The size goes through installHeadroom,
// the one add gate, exactly as FETCH-APP's does: same 25% allowance, same growth-only charge for a held package,
// same refusal text. The chooser measures the installed APK set and asks before a Keep add.
const (
	keepHeadroomMaxEntries = 16
	keepHeadroomMaxBytes   = 1 << 34 // 16 GiB: no installed APK set is bigger
)

type keepEntry struct {
	pkg   string
	bytes int64
}

// parseKeepHeadroom reads "<pkg>:<bytes>[ <pkg>:<bytes>...]". ok=false on an empty payload, more than
// keepHeadroomMaxEntries entries, a bad package name, bytes that are not plain decimal digits within range, or a
// package named twice.
func parseKeepHeadroom(payload string) ([]keepEntry, bool) {
	fields := strings.Fields(payload)
	if len(fields) == 0 || len(fields) > keepHeadroomMaxEntries {
		return nil, false
	}
	seen := map[string]bool{}
	out := make([]keepEntry, 0, len(fields))
	for _, f := range fields {
		pkg, num, found := strings.Cut(f, ":")
		if !found || !validPkgName(pkg) || seen[pkg] {
			return nil, false
		}
		// digits only: ParseInt alone would accept a leading sign
		if num == "" || len(num) > 11 || strings.Trim(num, "0123456789") != "" {
			return nil, false
		}
		b, err := strconv.ParseInt(num, 10, 64)
		if err != nil || b > keepHeadroomMaxBytes {
			return nil, false
		}
		seen[pkg] = true
		out = append(out, keepEntry{pkg, b})
	}
	return out, true
}

// keepHeadroomReply is the session-free answer: "ERR-ARG" | "OK add=<n>" | the FETCH-APP over-plan refusal. stored
// and measured are storedAppsCached's answer, passed in so a caller decides whether to wait for it.
func keepHeadroomReply(g *gatewayClient, base, name, pass, walletPath, payload string, stored map[string]int64, measured bool, se []byte) string {
	entries, ok := parseKeepHeadroom(payload)
	if !ok {
		return "ERR-ARG"
	}
	var add int64
	for _, e := range entries {
		est := e.bytes - e.bytes/4 // the ~25% seal/dedup allowance FETCH-APP charges
		add += fetchAppAddBytes(est, stored, measured, e.pkg)
	}
	fits, short, used, covered := installHeadroom(g, base, name, pass, walletPath, add, se)
	if fits {
		return fmt.Sprintf("OK add=%d", add)
	}
	reply := overPlanReply(short, used, covered, add)
	// The four numbers only -- no package and no profile, as FETCH-APP logs.
	fmt.Fprintf(os.Stderr, "[keepheadroom] refused: %s\n", reply)
	return reply
}

// handleKeepHeadroom: payload line, then "NONE" (no session, or no gateway: no plan) | "LOCAL" (throwaway) | the
// keepHeadroomReply line. gwProbe, not gwDefault: the check fails open, so waiting is pure cost.
func handleKeepHeadroom(conn net.Conn, r *bufio.Reader, dest string) {
	pl, _ := r.ReadString('\n')
	payload := strings.TrimRight(pl, "\r\n")
	name, pass, _ := readRoamSession(dest)
	if name == "" {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	if isLocalSession(dest) {
		fmt.Fprint(conn, "LOCAL\n")
		return
	}
	gw := strings.TrimRight(os.Getenv("GATEWAY_URL"), "/")
	if gw == "" {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	se := seFromSession(dest)
	// The first call after a sign-in answers unknown (and kicks an async fetch): that attempt is charged the full
	// estimate, as FETCH-APP's is.
	stored, measured := storedAppsCached(name, pass, se)
	fmt.Fprintf(conn, "%s\n", keepHeadroomReply(newGatewayClient(gw, gwProbe), "s3", name, pass, capWalletPath(), payload, stored, measured, se))
}
