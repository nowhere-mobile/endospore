package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// #98 v2: daemon-side Wi-Fi capture. The chooser-side capture (WifiMirror.java) proved DEAD ON ARRIVAL for
// the flow that matters: getPrivilegedConfiguredNetworks returns an EMPTY list inside a roamed user (the
// call soft-fails without a per-user fine-location runtime grant -- Android's Wi-Fi APIs return empty
// instead of throwing). The ROOT daemon doesn't need any of that: a network joined inside a session is a
// per-user PRIVATE config stored in that user's CE at
// /data/misc_ce/<uid>/apexdata/com.android.wifi/WifiConfigStore.xml, readable here while the user is still
// alive. Capture runs at every exit verb (LOGOUT, COLD-LOCK, RELOGIN) BEFORE the user stops, so every path
// is covered uniformly -- including the #97 "Load my saved data" flow the chooser hook missed.
//
// Only quoted-ASCII PSKs and open networks mirror (a raw 64-hex PSK can't ride the gate's quoted re-add);
// EAP/enterprise configs are skipped (the gate has its own advanced-join UI for those, and mirroring an
// identity+password pair wholesale is not obviously wanted). WPA3/SAE passphrases mirror fine -- the gate
// re-adds them as PSK, which joins any mixed-mode AP.
const wifiStorePerUser = "/data/misc_ce/%s/apexdata/com.android.wifi/WifiConfigStore.xml"

// captureWifiMirror reads the live session's private Wi-Fi store and queues ssid\tpsk lines in the RAM
// tmpfs for the gate (same .wifimirror file + GET-WIFI-MIRROR contract as the chooser-side WIFI-MIRROR
// verb). Best-effort: any failure just means no mirror this time.
func captureWifiMirror(dest string) {
	_, _, uid := readRoamSession(dest)
	if uid == "" {
		return
	}
	// Say WHY when nothing is captured. Returning silently is what let this path look healthy while being
	// INERT: on this Android saved networks live device-wide in /data/misc/apexdata/com.android.wifi, so the
	// per-user store parses to ZERO entries every time and #467's MAC third field never rode. Measured on
	// lynx: 616 chooser-path mirrors vs 0 from here, with no log line to say so. A no-op that logs nothing is
	// indistinguishable from a no-op that never ran.
	b, err := os.ReadFile(fmt.Sprintf(wifiStorePerUser, uid))
	if err != nil {
		fmt.Fprintf(os.Stderr, "[logind] wifi-mirror: no per-user store for user %s (%v) -- chooser capture is the live path\n", uid, err)
		return
	}
	ents := parseWifiStore(b)
	if len(ents) == 0 {
		fmt.Fprintf(os.Stderr, "[logind] wifi-mirror: per-user store for user %s has NO mirrorable networks (%d bytes) -- chooser capture is the live path\n", uid, len(b))
		return
	}
	var sb strings.Builder
	for _, e := range ents {
		sb.WriteString(e.ssid)
		sb.WriteByte('\t')
		sb.WriteString(e.psk)
		// #118: carry the per-network MAC-randomization mode as a THIRD field so the gate re-adds the network
		// with the SAME mode. Without it a "phone MAC" (RANDOMIZATION_NONE) network the owner joined in-session
		// reconnects at user 0 with a randomized MAC, which a MAC-allowlist AP (common at work) rejects -> the
		// gate silently can't get back on Wi-Fi. Emitted only when the store actually recorded a setting; absent
		// -> a 2-field line, so the gate keeps the platform default (backward-compatible with old mirrors).
		if e.mac >= 0 {
			sb.WriteByte('\t')
			sb.WriteString(strconv.Itoa(e.mac))
		}
		sb.WriteByte('\n')
	}
	if err := os.WriteFile(filepath.Join(dest, ".wifimirror"), []byte(sb.String()), 0o600); err == nil {
		fmt.Fprintf(os.Stderr, "[logind] wifi-mirror: %d network(s) captured from user %s store\n", len(ents), uid)
	}
}

type wifiEnt struct {
	ssid, psk string
	// #118 macRandomizationSetting from the store (0=NONE/real MAC, 1=PERSISTENT, 2=ENHANCED, 3=AUTO).
	// -1 = the store did not record one -> don't override the gate's platform default on re-add.
	mac int
}

// parseWifiStore extracts mirrorable (ssid, psk) pairs from a WifiConfigStore.xml. Line-oriented scan --
// the store is machine-written, one element per line; a full XML parser buys nothing here. Per <Network>:
//
//	<string name="SSID">&quot;MyNet&quot;</string>      quoted = UTF-8 ssid (unquoted hex ssids are skipped)
//	<string name="PreSharedKey">&quot;pw&quot;</string>  quoted passphrase; raw 64-hex (no quotes) skipped
//	<null name="PreSharedKey" />                          open network -> empty psk
//	ConfigKey suffix "EAP"/"SUITE_B"...                   enterprise -> skipped
func parseWifiStore(b []byte) []wifiEnt {
	var out []wifiEnt
	var ssid, psk, confKey string
	pskSeen := false
	mac := -1 // #118: this <Network>'s macRandomizationSetting, -1 until the store records one
	flush := func() {
		defer func() { ssid, psk, confKey, pskSeen, mac = "", "", "", false, -1 }()
		s, ok := unquoteOnce(ssid)
		if !ok {
			return // absent or a non-UTF-8 (hex) ssid -- can't re-add via the quoted path
		}
		if strings.Contains(confKey, "EAP") || strings.Contains(confKey, "SUITE_B") {
			return // enterprise config -- not mirrored
		}
		p := ""
		if pskSeen && psk != "" {
			if p, ok = unquoteOnce(psk); !ok {
				return // raw 64-hex PSK -- can't ride the quoted re-add
			}
		}
		// The chooser's capture rule, WifiMirrorLine.encode (NWP-20261031-09, after NOWHERE-505): exactly one enclosing
		// quote pair is removed and nothing is trimmed; an SSID blank by Java's trim() or holding a tab or newline, or
		// a PSK holding a tab or newline, is skipped -- a tab would split the line's fields at the gate.
		if javaBlank(s) || strings.ContainsAny(s, "\t\n") || strings.ContainsAny(p, "\t\n") {
			return
		}
		// handleWifiMirror drops a chooser line over 256 bytes; this path stores the same set.
		n := len(s) + 1 + len(p)
		if mac >= 0 {
			n += 1 + len(strconv.Itoa(mac))
		}
		if n > 256 {
			return
		}
		out = append(out, wifiEnt{s, p, mac})
	}
	for _, ln := range strings.Split(string(b), "\n") {
		ln = strings.TrimSpace(ln)
		switch {
		case ln == "</Network>":
			if len(out) < 16 {
				flush()
			}
		case strings.Contains(ln, `name="SSID"`):
			ssid = xmlTagValue(ln)
		case strings.Contains(ln, `name="PreSharedKey"`):
			pskSeen = !strings.HasPrefix(ln, "<null") // <null .../> = open network (psk stays "")
			if pskSeen {
				psk = xmlTagValue(ln)
			}
		case strings.Contains(ln, `name="ConfigKey"`):
			confKey = xmlTagValue(ln)
		case strings.Contains(ln, `name="MacRandomizationSetting"`):
			mac = xmlIntAttr(ln) // #118: <int name="MacRandomizationSetting" value="N" />
		}
	}
	return out
}

// unquoteOnce is v without its one enclosing pair of double quotes (the first and last byte), ok=false when v is
// shorter than two bytes or not enclosed in them. strings.Trim would remove EVERY edge quote.
func unquoteOnce(v string) (string, bool) {
	if len(v) < 2 || v[0] != '"' || v[len(v)-1] != '"' {
		return "", false
	}
	return v[1 : len(v)-1], true
}

// javaBlank reports what Java's String.trim().isEmpty() does: every byte is <= 0x20 (or there are none).
func javaBlank(v string) bool {
	for i := 0; i < len(v); i++ {
		if v[i] > 0x20 {
			return false
		}
	}
	return true
}

// xmlIntAttr pulls the integer value="N" attribute from a self-closing element the store writes for ints,
// e.g. <int name="MacRandomizationSetting" value="0" />. Returns -1 if the attribute is absent or unparseable
// (the store normally always records it, but a missing/odd value just means "keep the gate's default").
func xmlIntAttr(ln string) int {
	const k = `value="`
	i := strings.Index(ln, k)
	if i < 0 {
		return -1
	}
	i += len(k)
	j := strings.IndexByte(ln[i:], '"')
	if j < 0 {
		return -1
	}
	n, err := strconv.Atoi(ln[i : i+j])
	if err != nil {
		return -1
	}
	return n
}

// xmlTagValue pulls the inner text of a one-line <string name="X">value</string> element and unescapes the
// XML entities the store writer emits.
func xmlTagValue(ln string) string {
	i := strings.Index(ln, ">")
	j := strings.LastIndex(ln, "</")
	if i < 0 || j <= i {
		return ""
	}
	v := ln[i+1 : j]
	for _, r := range [][2]string{{"&quot;", "\""}, {"&apos;", "'"}, {"&lt;", "<"}, {"&gt;", ">"}, {"&#10;", "\n"}, {"&#13;", "\r"}, {"&#9;", "\t"}, {"&amp;", "&"}} {
		v = strings.ReplaceAll(v, r[0], r[1])
	}
	return v
}
