package main

// On-device DNS for the agent. The agent is built CGO_ENABLED=0, so Go's pure resolver reads
// /etc/resolv.conf -- which Android does not provide (and the net.dns* props are empty) -- and otherwise
// falls back to localhost:53, where nothing listens, so every hostname lookup fails ("dial ... [::1]:53:
// connection refused"). DNS on Android lives in netd, which a cgo-less Go binary can't reach. We instead
// point net.DefaultResolver at a real nameserver, PREFERRING the device's own per-network DNS (discovered
// from the connectivity service, so queries don't leave the network the device is already on) over a
// public fallback. This supersedes the previous fixed NOWHERE_DNS=1.1.1.1:53 default the launcher scripts
// set, which sent every lookup to Cloudflare.
//
// NWP-20260904-12: the resolver also honours the device's PRIVATE DNS posture. nowhere_provision.sh sets
// private_dns_mode=hostname + private_dns_specifier=dns.mullvad.net (strict DNS-over-TLS) so the network never
// sees a query in plaintext -- but that setting lives in netd's resolver, which this cgo-less binary cannot
// reach, so until this slice every agent lookup (store, gateway, OTA) went as plain UDP:53 to the network's own
// resolvers, in every mode. The connectivity dump carries the posture per network (LinkProperties.toString(),
// see parsePrivateDNS), and in strict mode the Dial below returns a TLS connection to <host>:853 instead of a
// UDP socket: Go's pure resolver uses stream framing on any non-PacketConn, which is exactly DoT (RFC 7858).
// Strict mode FAILS CLOSED, as the OS does -- a network that blocks 853 leaves the agent with no DNS, never
// with a silent downgrade to plaintext. Opportunistic mode (UsePrivateDns without a hostname) stays plain.

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// installResolver overrides the process resolver when the platform has no usable resolv.conf. Precedence:
// an explicit NOWHERE_DNS operator override > a working /etc/resolv.conf (a normal Linux host / the build
// VM: no-op, so tests and native tools are unaffected) > the device's discovered per-network DNS > a
// public fallback. Call once, early in main(), before any network use.
func installResolver() {
	if dns := strings.TrimSpace(os.Getenv("NOWHERE_DNS")); dns != "" {
		setResolver([]string{withPort53(dns)}) // explicit operator override (host or host:port)
		return
	}
	if hasResolvConf("/etc/resolv.conf") {
		return // normal host: Go's resolver already works -- leave it alone
	}
	seedDNSFromCache()   // NWP-20260822-06: start warm if the daemon published a list this boot
	setResolverDynamic() // on-device: re-discover per-lookup (TTL-cached) so a snapshot taken during the
	// login/roam settling window (or a SIM/network change) self-heals instead of staying wedged.
	goSafeLoop("netlink watch", watchNetChanges) // + proactively re-discover on kernel network-change events (best-effort netlink)
}

// dnsTTL bounds how long a discovered server list is reused before re-reading the connectivity service. Short,
// because the list a fresh login snapshots is often wrong: at login/user-switch the validated Wi-Fi route isn't
// up yet (every server ENETUNREACHes for a second or two) or -- with a second SIM -- competing cellular/v6 routes
// make the agent's outbound flap. Re-discovering on this cadence (and immediately on a total dial failure) lets
// the resolver recover within seconds once the network settles, rather than staying wedged for the whole process
// lifetime (the old one-shot snapshot -- which surfaced as a false "You're offline" that never cleared).
const dnsTTL = 4 * time.Second

// dnsKeepMax bounds how long a discovered list may be KEPT across empty discoveries (#64). ~2.5x the gate's own
// network-settling grace, so it spans the user-switch / Wi-Fi re-association window and nothing longer. Past
// that, a persistently empty discovery is not a transient -- it is a broken dumpsys, or a network we cannot
// read -- and the public bootstrap is a better answer than a list we can no longer justify.
// ⚠ SUPERSEDED by NWP-20261113-19: the bound was measured from the last NON-EMPTY discovery (dnsGoodAt). Discovery
// runs only when a lookup needs it, so a daemon idle for longer than dnsKeepMax had an old dnsGoodAt, and the first
// empty discovery of a switch window dropped a list that was valid one lookup ago (device-disproven on lynx
// 2026102201, NWP-20261024-18: Wi-Fi off 3 s at a periodic seal's start, the daemon logged
// `src=PUBLIC-FALLBACK (discovery empty, nothing cached)` minutes after `src=discovered`, and no `src=kept`).
// The rule now: a list is kept for at most dnsKeepMax of CONTINUOUS empty discovery, measured from the first empty
// one (dnsEmptySince). Idle time with no lookups is not emptiness.
const dnsKeepMax = 20 * time.Second

var (
	netMu      sync.Mutex
	dnsServers []string
	netIface   string
	netAt      time.Time
	// NWP-20260822-04 (#64). A "last good" list is good only while it still plausibly belongs to the network we
	// are on, so the keep below is BOUNDED. What the old clobber cost was bounded at ~dnsTTL (the next
	// successful discovery undid it); an unbounded keep would trade that for an UNBOUNDED failure, which is a
	// worse deal and is exactly the shape of #219 above.
	// dnsGoodAt is when dnsServers was last set from a REAL discovery (zero = never), or a seed's honest age. Since
	// NWP-20261113-19 it is only the "ever discovered" key and the seed's age, no longer the bound's clock:
	// dnsEmptySince is, so an idle daemon's first empty discovery keeps a list that was good one lookup ago.
	dnsGoodAt     time.Time
	dnsEmptySince time.Time // first empty discovery of the current empty run; zero = the last discovery was not empty
	// NWP-20261119-25: the egress interface the seeded list was discovered on, from the cache file's iface line.
	// "" = no seed, a seed with no interface, or a real discovery has replaced the seed. A seeded fork has
	// netIface "", so the interface-change key cannot fire for it; this one does.
	dnsSeedIface string
	// dnsFromVPN: dnsServers are scoped to the session VPN's tunnel, not discovered; resolver dials follow it (dnsEgress).
	dnsFromVPN bool
	// NWP-20260904-12: the strict private-DNS posture of the network we resolve on. dotHost is the
	// PrivateDnsServerName the connectivity dump prints for that network ("" = plain DNS); dotAddrs are its
	// ip:853 endpoints when already known -- the OS-validated ValidatedPrivateDnsAddresses when the dump has
	// them, else whatever an earlier bootstrap cached -- and empty when the first DoT dial must bootstrap.
	dotHost  string
	dotAddrs []string
	// NWP-20260925-03: the session VPN, kept APART from netIface (which is always the physical default network's
	// interface now). bindControl decides per connection (egressFor): a destination this VPN takes by its routes
	// rides its tun; anything else the physical network. Zero when no usable VPN is up.
	vpnEg vpnEgress
	// vpnStateLogged is the last VPN classification logged ("<iface> full" / "<iface> split" / "<iface> unreadable",
	// "" for none), so the line is change-only, like the egress line.
	vpnStateLogged string
)

// vpnIfaceUsable is ifaceUsable behind a seam, so a test can hold a tun "up" that does not exist on the host.
var vpnIfaceUsable = ifaceUsable

// refreshNet re-reads the connectivity service ONCE and updates both the DNS server list and the validated
// default network's egress interface. A read that yields nothing for a field keeps that field's last good value.
// refreshNet re-reads the network and updates the cached resolver list. force=true means "every cached address
// just failed to connect" (dnsAddrs' retry path), which is itself evidence the cached list is dead -- so a
// forced refresh never keeps it.
func refreshNet(force bool) {
	dump := dumpsysConnectivity()
	iface := parseDefaultIface(dump)
	// #159 (DIA-20260721): when the roamed session has a VPN up, route the daemon's OS roam traffic THROUGH its
	// tunnel -- bind outbound sockets to the VPN's tun AND scope DNS to the VPN's own resolvers, so a network
	// observer sees only the encrypted tunnel, never that the device talks to the store/gateway. A system-UID
	// socket SO_BINDTODEVICE'd to the VpnService tun egresses via the VPN even cross-user (proven on lynx) --
	// the same bindControl mechanism as a physical iface, just a different device, so no new routing/netd/
	// sepolicy machinery. Login-restore bootstraps DIRECT (user 0, no session VPN yet); once the session VPN
	// validates, the netlink watcher re-discovers and every subsequent seal rides the tun. With no VPN up it
	// falls back to the physical validated default (the two-SIM fix).
	// ⚠ SUPERSEDED IN PART by NWP-20260925-03: "bind outbound sockets to the VPN's tun" is now decided PER
	// CONNECTION -- a destination the VPN takes by its routes rides the tun, anything else the physical network -- and
	// "scope DNS to the VPN's own resolvers" now holds only for a tunnel that is full in intent (below).
	// #219 (DIA-20260728, found on odtest4): only scope to the VPN if its tunnel is REALLY usable. dumpsys can
	// report "ni{VPN CONNECTED" for a registered-but-dead tunnel (e.g. an always-on VpnService whose transport
	// dropped); adopting it replaced the whole server list with the tunnel's own ULA resolver (fc00:a:a::400),
	// which ENETUNREACHes for every lookup -- and because the list then held ONLY that server, the on-failure
	// re-discovery picked it again, wedging DNS for the process. Every gateway call failed, so seals reported
	// ERR-PUSH (misread as a storage/quota problem) and cost real wallet credit. Verify the interface exists,
	// is UP and has an address before trusting it. NOTE we deliberately do NOT fall back to the physical DNS
	// while a REAL tunnel is up -- that would leak lookups outside it, defeating #159 -- so this only skips a
	// VPN that isn't actually carrying traffic.
	// ⚠ SUPERSEDED IN PART by NWP-20260925-03: the NOTE now applies to a FULL tunnel only. A split tunnel is
	// up and real but cannot carry public lookups, so under one the physical resolvers are used.
	// NWP-20260925-03 (found on lynx 2026092603, 2026-09-25): Tailscale without an exit node is a SPLIT tunnel --
	// its tun routes only the tailnet's 100.x hosts -- and #159 bound every daemon socket to it: every store and
	// gateway call went into a tunnel with no route to them (`ping -I tun1 1.1.1.1` 100% loss while wlan0 answered
	// in 24 ms), every seal failed on every scope, and a Profile screen waiting on GET-ENTITLEMENT froze. So:
	//   * A tunnel is FULL IN INTENT (vpnFullInIntent) when its own `->` routes leave at most one /8 of public IPv4
	//     to the physical network, or when it is a v6-only full tunnel. Anything else is split.
	//   * CONNECTIONS are decided per destination (egressFor, from bindControl): longest-prefix match against the
	//     VPN's own routes. A `->` route rides the tun; a `throw` carve-out, or no match, goes out the physical
	//     network. An `unreachable` entry is Android's family-wide block for a family the VPN does not carry
	//     (Vpn.makeLinkProperties adds `::/0 unreachable` or `0.0.0.0/0 unreachable` to any VpnService that
	//     configures nothing of that family and does not allowFamily() it, split or full -- read from source, not
	//     observed; WireGuard allows both families unless its one peer routes a default). In a full tunnel it means
	//     the VPN refuses that family,
	//     so the connection stays in the tun and fails there, exactly as the whole-tunnel bind did; in a split
	//     tunnel it goes physical like the rest, per the decision below -- rev 4 held a v4-only split tunnel's IPv6
	//     in the tun, which on an IPv6-only 464XLAT network leaves the daemon no path at all. That is exact for a
	//     full tunnel, a split tunnel, and a full tunnel with carve-outs alike (a whole-tunnel test read
	//     WireGuard's "Exclude private IPs" set, and then shadowsocks' bypass list, as split).
	//   * DNS rides the tunnel only when it is full in intent: its own resolvers, or -- when it names none -- the
	//     public fallback resolvers, through it. The physical network's resolvers are typically its router's or its
	//     operator's, which may not answer through the tunnel, and asking them outside it would leak the lookups
	//     #159 hides. A split tunnel's resolvers may answer only its own names, so under one the physical resolvers
	//     are used. Every VPN's own resolvers -- split, unreadable, dead (#219), or with no interface -- are kept out
	//     of the all-networks fallback tier. Resolver dials follow the list's provenance (dnsEgress,
	//     keyed on dnsFromVPN), not their destination: a physical resolver goes out the physical interface even
	//     when a split tunnel's routes cover its address (a corporate VPN routing 192.168/16 on a home Wi-Fi whose
	//     router is 192.168.1.1 would otherwise swallow every lookup).
	//   * A dump that describes no network at all (a failed read: dumpsysConnectivity returns "") keeps the last
	//     VPN state and its list's provenance -- decided under the lock that commits it -- rather than dropping a
	//     full tunnel's traffic onto the physical network for a TTL.
	//   * A VPN block with no interface is no VPN. Android drops the InterfaceName while an IKEv2 VPN reconnects
	//     (Vpn's session-lost path), so the daemon uses the physical network until it is back, as with #219's dead
	//     tunnel; parseVpnNetwork reads only the VPN's own block, where an unbounded search had taken the NEXT
	//     network's interface for the tunnel's.
	// A split tunnel therefore does not carry the daemon's public traffic, even under the VPN's lockdown -- decided
	// by Chester 2026-09-26 (docs/product-decisions.md): the session's data keeps being saved, at the cost that an
	// observer of the local network sees the phone reach the store and gateway.
	usedVPN, vpnGone := false, true
	var nextVPN vpnEgress
	vpnState := ""
	tunnelPublic := false // the list is the public fallback, asked through a full tunnel that names no resolvers
	// NWP-20260904-12: the private-DNS posture of the network whose interface we bind to. The block is the
	// default network's, or the VPN's once its resolvers are adopted below (the OS applies the global setting to
	// every network, and a DoT dial bound to the tun must be the tun's posture). An ABSENT block -- the user-switch
	// window, where the dump reports no active default at all -- KEEPS the previous posture rather than reading
	// as "off": that transient must never become a plaintext lookup (the same keep rule as the server list).
	netBlock := defaultNetworkBlock(dump)
	var vDNS []string
	var vFull bool
	dumpOK := strings.Contains(dump, "NetworkAgentInfo{")
	if !dumpOK {
		vpnGone = false // a failed read is not evidence the VPN went away
	}
	// Every VPN's own resolvers are kept out of the all-networks fallback tier, whether or not the VPN is taken: one
	// that is split, unreadable, dead (#219) or has no interface (an IKEv2 reconnect) may answer only through it.
	vpnDNSExclude := parseDnsAddresses(vpnNetworkBlock(dump))
	if vIf, vd := parseVpnNetwork(dump); vIf != "" {
		vDNS = vd
		vBlock := vpnNetworkBlock(dump)
		if !vpnIfaceUsable(vIf) {
			vpnGone = false // #219, unchanged: a reported-but-dead tunnel does not by itself retire a VPN-scoped list
			fmt.Fprintf(os.Stderr, "[resolver] VPN %q reported CONNECTED but the tunnel is not usable -- staying on the physical network (#219)\n", vIf)
		} else if routes := parseVpnRoutes(vBlock); len(routes) == 0 {
			vpnState = vIf + " unreadable" // no route we can read: send it nothing we cannot show it takes
		} else {
			nextVPN = vpnEgress{iface: vIf, routes: routes}
			if vpnFullInIntent(routes) {
				vFull = true
				nextVPN.full = true
				vpnGone = false
				netBlock = vBlock
				vpnState = vIf + " full"
			} else {
				vpnState = vIf + " split"
			}
		}
	}
	// NWP-20260822-04 (#64): DISCOVER only -- no public fallback here. Whether to fall back is a decision that
	// needs the CACHED list too, and it is made by dnsAdopt below. The VPN's own resolvers are kept out of the
	// all-networks fallback tier only (never out of the default network's own list).
	servers := discoveredDNSExcluding("", getpropMulti("net.dns1", "net.dns2", "dhcp.wlan0.dns1", "dhcp.wlan0.dns2"), parseDefaultNetworkDNS(dump), dump, vpnDNSExclude)
	if vFull {
		servers = vDNS
		if len(servers) == 0 {
			servers = tunnelFallbackDNS(nextVPN) // the tunnel names none: public resolvers, asked through it
			tunnelPublic = true
		}
		usedVPN = true // provenance: this list is scoped to the tunnel, so it must not outlive it (#219)
	}
	addrs := make([]string, len(servers))
	for i, s := range servers {
		addrs[i] = net.JoinHostPort(s, plainPort)
	}
	// Resolve the posture BEFORE taking netMu: dotTargetFor consults the DoT memory (dotMu) and the cache file,
	// and dotMu must never be acquired under netMu -- see the lock-order rule at dotMu. The review of this slice
	// caught the cycle: a bootstrap's plaintext dial runs its Control -> defaultNetIface -> netMu (bindControl
	// then; dnsBindControl -> dnsEgress since NWP-20260925-03), so a refresh that waited for dotMu while holding
	// netMu, with the bootstrap waiting for netMu, stalled every socket in the process until the lookup's context
	// expired -- and failed a lookup whose DoT server was reachable.
	postureKnown := netBlock != ""
	var nextHost string
	var nextAddrs []string
	if postureKnown {
		nextHost, nextAddrs = dotTargetFor(parsePrivateDNS(netBlock))
	}
	netMu.Lock()
	if !dumpOK && dnsFromVPN {
		// A failed read decides nothing about the VPN: its tunnel-scoped list is kept rather than replaced by a props
		// read. Decided HERE, under the lock that commits it, so a concurrent good read cannot land between the
		// decision and the commit and leave a list bound to a tunnel it does not belong to.
		addrs, usedVPN, tunnelPublic = nil, true, false
	}
	prevDNS, prevIface := strings.Join(dnsServers, ","), netIface
	// NWP-20260822-04 (#64): adopt what we discovered, else KEEP the last good list, else -- cold start only --
	// the public fallback. The old form was `if len(addrs) > 0 { dnsServers = addrs }`, which read as the
	// keep-last-good rule dnsAddrs documents but could never fire, because pickDNS always returned something.
	// Vet the cached list BEFORE offering it as "last good". dnsAdopt stays pure; the question of whether the
	// cache is still trustworthy is stateful and belongs here. Each key closes a way an unbounded keep could
	// wedge DNS for the whole process -- the #219 failure, reached from the cache instead of from the dump.
	if len(addrs) == 0 && dnsEmptySince.IsZero() {
		dnsEmptySince = time.Now() // NWP-20261113-19: the empty run starts here; later empties do not move it
	}
	keep := dnsServers
	switch {
	case dnsGoodAt.IsZero():
		keep = nil // nothing was ever discovered, so the cache can only be a previous bootstrap
	case !dnsEmptySince.IsZero() && time.Since(dnsEmptySince) > dnsKeepMax:
		keep = nil // empty for longer than a switch window: a broken dumpsys, or a network we cannot read
	case iface != "" && netIface != "" && iface != netIface:
		keep = nil // different egress network -- this list was never validated for it
	case dnsSeedIface != "" && iface != "" && iface != dnsSeedIface:
		keep = nil // NWP-20261119-25: the seed belongs to another network -- the daemon discovered it on dnsSeedIface
	case dnsFromVPN && vpnGone:
		keep = nil // #219: the ULA is filtered out of discoveredDNS, so it could never be re-derived
	case force:
		keep = nil // every cached address just failed to dial; handing it back is a guaranteed-identical retry
	}
	adopted, usedFallback := dnsAdopt(addrs, keep, fallbackAddrs())
	dnsServers = adopted
	prevDoT := dotHost
	if postureKnown {
		dotHost, dotAddrs = nextHost, nextAddrs
	}
	if len(addrs) > 0 {
		dnsGoodAt = time.Now()
		dnsEmptySince = time.Time{} // NWP-20261113-19: a good discovery ends the empty run
		// NWP-20261119-25: this process's own discovery owns the list now, and netIface keys it from here on.
		dnsSeedIface = ""
		if !usedVPN {
			// NWP-20260822-06: publish for short-lived forks. NOT a VPN-scoped list -- that is per-session and
			// per-user, and handing it to another process would both leak the tunnel's resolver and risk the
			// #219 shape in a process that cannot see whether the tunnel is still up. The DoT posture rides
			// along so a fork born in the switch window resolves over TLS from its first lookup.
			saveDNSCache(addrs, dotHost, stripPorts(dotAddrs), iface)
		}
	}
	dnsFromVPN = usedVPN
	if iface != "" {
		netIface = iface
	}
	if dumpOK {
		vpnEg = nextVPN
		if vpnState != vpnStateLogged {
			if vpnState != "" {
				fmt.Fprintln(os.Stderr, vpnStateLine(vpnState))
			}
			vpnStateLogged = vpnState
		}
	}
	netAt = time.Now()
	// Record the chosen resolvers + egress interface to stderr (login.log) ONLY when they change -- the signal
	// that was missing when the multi-network false-offline (#180) was hard to diagnose -- without a line per TTL.
	if strings.Join(dnsServers, ",") != prevDNS || netIface != prevIface || dotHost != prevDoT {
		// Say WHICH list this is. A public-fallback list and a discovered one were previously indistinguishable
		// in the log except by recognising the IPs, which is how the clobbering above went unnoticed.
		src := "discovered"
		if usedFallback {
			src = "PUBLIC-FALLBACK (discovery empty, nothing cached)"
		} else if len(addrs) == 0 {
			src = "kept (discovery empty, cache still valid)"
		} else if tunnelPublic {
			src = "PUBLIC-VIA-TUNNEL (the VPN names no resolvers)"
		}
		fmt.Fprintln(os.Stderr, egressLine(netIface, dnsServers, src, dotHost))
	}
	netMu.Unlock()
}

// egressLine is the change-only resolver log line. dot= names the strict private-DNS HOST or "off" -- a
// hostname, never an address.
//
// NWP-20261011-36: the server list is printed as resolvers=[...], each server that is one of publicFallbackDNS
// VERBATIM and every other as <net4>/<net6> with its port. The old dns=[...] printed every network's own
// resolver addresses into login.log, which is on plain /data, survives the boot-wipe and ships in issue
// reports; emitted change-only, its 1 MB tail was a de-duplicated travel history (docs/backlog.md, the
// `dns=[...]` row). The public addresses stay readable because they ARE the diagnosis: a list of them is the
// clobbered cold-start fallback (see dnsAdopt), a list of placeholders is a discovered one. The key is new so
// that no line written today matches the legacy form, which log_scrub (LOG_SCRUB_DNS_SED) and the issue
// reporter (reIssueLegacyDNS) redact as the lines already on a device. A platform interface prints bare and any
// other quoted (ifaceTok, NWP-20261116-24), so the sign-out scrub keeps wlan0 and still meets a user-named tunnel.
func egressLine(iface string, dns []string, src, dot string) string {
	if dot == "" {
		dot = "off"
	}
	return fmt.Sprintf("[resolver] egress iface=%s resolvers=%s src=%s dot=%s", ifaceTok(iface), logResolvers(dns), src, dot)
}

// logResolvers renders a host:port server list for egressLine: a public fallback server as written, any other
// as <net4>:port or <net6>:port, and anything that does not parse as an address as <net>.
func logResolvers(dns []string) string {
	var pub []net.IP
	for _, s := range publicFallbackDNS() {
		pub = append(pub, net.ParseIP(s))
	}
	out := make([]string, len(dns))
	for i, s := range dns {
		out[i] = "<net>"
		host, port, err := net.SplitHostPort(s)
		if err != nil {
			continue
		}
		ip := net.ParseIP(host)
		if ip == nil {
			continue
		}
		public := false
		for _, p := range pub {
			public = public || p.Equal(ip)
		}
		switch {
		case public:
			out[i] = s
		case ip.To4() != nil:
			out[i] = "<net4>:" + port
		default:
			out[i] = "<net6>:" + port
		}
	}
	return "[" + strings.Join(out, " ") + "]"
}

// dotTargetFor turns a network's printed private-DNS posture into the resolver's (host, endpoints) pair.
// Only STRICT mode (a PrivateDnsServerName -- DnsManager.updatePrivateDnsStatus prints the hostname for strict
// mode only) yields a host; opportunistic mode (UsePrivateDns: true alone) is left plain, as the OS leaves it
// best-effort. Endpoints come, in order, from the OS's own ValidatedPrivateDnsAddresses (zero plaintext
// queries from us -- the OS already resolved and validated them), else from an earlier bootstrap this process
// or the daemon cached; nil means the first DoT dial bootstraps.
func dotTargetFor(pd privateDNS) (string, []string) {
	if pd.Host == "" {
		return "", nil
	}
	if net.ParseIP(pd.Host) != nil {
		return pd.Host, []string{net.JoinHostPort(pd.Host, dotPort)} // an IP-literal specifier needs no bootstrap
	}
	if len(pd.Validated) > 0 {
		a := dotEndpointsOf(pd.Validated)
		rememberDoT(pd.Host, a)
		return pd.Host, a
	}
	return pd.Host, knownDoT(pd.Host)
}

// dotEndpointsOf is a list of bare IPs as ip:853 endpoints, IPv4 first for the same reason discoveredDNS
// prefers v4: on a multi-network device the v6 path routinely ENETUNREACHes and only burns a dial.
func dotEndpointsOf(ips []string) []string {
	var v4, v6 []string
	for _, s := range ips {
		ip := net.ParseIP(s)
		switch {
		case ip == nil:
			continue
		case ip.To4() != nil:
			v4 = append(v4, net.JoinHostPort(s, dotPort))
		default:
			v6 = append(v6, net.JoinHostPort(s, dotPort))
		}
	}
	return dedupeStr(append(v4, v6...))
}

// stripPorts is the inverse of dotEndpointsOf, for the cache file (which stores bare IPs so the port stays a
// property of the reader, not of the record).
func stripPorts(addrs []string) []string {
	out := make([]string, 0, len(addrs))
	for _, a := range addrs {
		if h, _, err := net.SplitHostPort(a); err == nil {
			out = append(out, h)
		}
	}
	return out
}

// seedDNSFromCache pre-populates this process's list from whatever the daemon last discovered, so a
// short-lived fork's FIRST lookup has known-good servers rather than the cold-start public fallback.
//
// It seeds the CACHE, not the discovery: dnsGoodAt is back-dated to the file's mtime and a file older than
// dnsKeepMax is not seeded. Since NWP-20261113-19 a seeded list is kept, like any other, for at most dnsKeepMax of
// continuous empty discovery in this process (dnsEmptySince stays zero here), so it is at most 2 x dnsKeepMax old
// when dropped. This process's own discovery -- which runs on
// the very first dnsAddrs call, because netAt is still zero -- supersedes it the moment it succeeds. The seed
// therefore only ever decides what happens when discovery comes back EMPTY, which is exactly the window it
// exists for.
// ⚠ SUPERSEDED by NWP-20261119-25: "a file older than dnsKeepMax is not seeded" and "at most 2 x dnsKeepMax old
// when dropped" no longer hold. A cache of ANY age seeds, because the file is per-boot tmpfs. NWP-20261113-19
// retired the age rule for the daemon, and a fork that kept applying it started cold after any idle spell. The
// cache now records its egress interface (`iface <name>`), and a fork drops the seed when its own discovery names
// another interface (dnsSeedIface, refreshNet's keep switch).
// A seed from an unnamed interface (an older file) is bounded by the other keys, as before.
func seedDNSFromCache() {
	// NWP-20260904-12: the DoT posture seeds from the file REGARDLESS of the server list's age. The age bound
	// exists because a server list belongs to a network, and the device may have left that network; the posture
	// is a device-global setting and the file is per-boot tmpfs, so there is no network for it to have left.
	// Gating it on the servers' age (the first cut did) dropped it whenever the daemon had been idle for
	// dnsKeepMax -- and a fork born in the switch window then saw no default block, kept an EMPTY posture, and
	// made its first lookups in plaintext through the public fallback: the exact downgrade strict mode exists to
	// rule out, on the exact log signature the originating ticket showed. The fork's own refreshNet supersedes
	// this the moment it reads a default block (present-but-off clears it, as for a long-lived process).
	// ⚠ SUPERSEDED by NWP-20261119-25: the servers have no age bound either now; the interface key replaced it.
	// NWP-20261113-19 retired the age rule for the daemon, and a fork that kept applying it started cold after any
	// idle spell.
	if host, ips, ok := loadDoTCache(); ok {
		eps := dotEndpointsOf(ips)
		rememberDoT(host, eps) // dotMu -- taken OUTSIDE netMu, see the lock-order rule at dotMu
		netMu.Lock()
		dotHost, dotAddrs = host, eps
		netMu.Unlock()
	}
	addrs, _, _, age, ok, iface := readDNSCache()
	if !ok {
		return // absent -- start cold, exactly as before; NWP-20261119-25: a cache of any age seeds
	}
	netMu.Lock()
	dnsServers = addrs
	dnsGoodAt = time.Now().Add(-age) // honest age; non-zero = something was discovered (the keep's IsZero key)
	dnsSeedIface = iface             // NWP-20261119-25: refreshNet drops the seed on another interface
	netMu.Unlock()
	fmt.Fprintf(os.Stderr, "[resolver] seeded %d server(s) from the shared cache, %dms old (NWP-20260822-06)\n",
		len(addrs), age.Milliseconds())
}

// dnsCacheFile is the leaf, under NOWHERE_STATE, where the daemon publishes the nameservers it last
// DISCOVERED, so a short-lived agent fork can start warm instead of cold.
//
// WHY (NWP-20260822-06): installResolver runs ONCE PER PROCESS, and the restores are separate short-lived
// forks -- roamd runs `NOWHERE_PHASE=media "$AGENT" restore ...` per scope. Each one therefore begins with an
// EMPTY cache, so NWP-20260822-04's "keep the last good list" -- which only helps a process that already has
// one -- could never help them: their first refreshNet takes the cold-start branch straight to the public
// fallback. That is the gap the adversarial pass named as the reason the resolver fix could not move #80.
//
// tmpfs is the RIGHT home, not a compromise: NOWHERE_STATE dies at power-off, and a nameserver list SHOULD
// NOT outlive a boot -- the phone may wake on a different network entirely. (Contrast the wallet, where tmpfs
// cost real credit; a per-boot cache is exactly what this wants.)
//
// The seed is treated as CACHED, never as discovered: it is offered to dnsAdopt as the `cached` argument and
// is subject to every vetting key, including the dnsKeepMax age bound measured from the FILE'S OWN MTIME. So
// a fork inheriting a list from a network the device has since left cannot wedge on it, and a fork whose own
// discovery succeeds ignores the seed entirely.
// ⚠ SUPERSEDED by NWP-20261119-25: the seed has no age bound now, from the file's mtime or otherwise.
// NWP-20261113-19 retired the age rule for the daemon, and a fork that kept applying it started cold after any
// idle spell. The cache now records its egress interface (`iface <name>`), and a fork drops the seed when its own
// discovery names another interface. A seed is still subject to every other vetting key.
//
// NWP-20260904-12: the file also carries the strict private-DNS posture as one extra line,
//
//	dot <host> <ip>[,<ip>...]
//
// (bare IPs; the port is the reader's). loadDNSCache skips it, loadDoTCache reads it, and the bootstrap
// rewrites it in place WITHOUT touching the file's mtime, so the server list's age stays honest. The posture
// line is NOT subject to the age bound -- see seedDNSFromCache for why.
// ⚠ SUPERSEDED by NWP-20261119-25: no line is subject to an age bound now. The file also carries one more line,
//
//	iface <name>
//
// the egress interface the servers were discovered on ([A-Za-z0-9._-]{1,15}; absent when unknown or invalid).
// The bootstrap's rewrite keeps it, with the mtime, and seedDNSFromCache records it in dnsSeedIface.
const dnsCacheFile = ".dnscache"

// dnsCacheDoTPrefix marks the DoT line inside dnsCacheFile.
const dnsCacheDoTPrefix = "dot "

// dnsCacheIfacePrefix marks the line inside dnsCacheFile that names the egress interface the servers were
// discovered on (NWP-20261119-25).
const dnsCacheIfacePrefix = "iface "

// validCacheIface reports whether name can be an interface name in the cache file: 1-15 of [A-Za-z0-9._-].
func validCacheIface(name string) bool {
	if len(name) == 0 || len(name) > 15 {
		return false
	}
	for _, c := range name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// saveDNSCache publishes a freshly DISCOVERED list for other processes, plus the DoT posture it was discovered
// with (host "" = plain) and the egress interface it was discovered on (NWP-20261119-25). Best-effort and deliberately quiet: this is an optimisation, and a process that
// cannot write it simply leaves the next fork cold.
func saveDNSCache(addrs []string, dotHost string, dotIPs []string, iface string) {
	st := os.Getenv("NOWHERE_STATE")
	if st == "" || len(addrs) == 0 {
		return
	}
	writeDNSCache(st, addrs, dotHost, dotIPs, time.Time{}, iface)
}

// writeDNSCache renders and atomically replaces the cache file. A non-zero keepMtime is restored onto the
// new file, for a writer that changes only the DoT line and must not refresh the server list's age. iface is
// written as the iface line only when validCacheIface accepts it (NWP-20261119-25).
func writeDNSCache(st string, addrs []string, dotHost string, dotIPs []string, keepMtime time.Time, iface string) {
	body := strings.Join(addrs, "\n") + "\n"
	if dotHost != "" {
		body += dnsCacheDoTPrefix + dotHost + " " + strings.Join(dotIPs, ",") + "\n"
	}
	if validCacheIface(iface) {
		body += dnsCacheIfacePrefix + iface + "\n"
	}
	tmp := filepath.Join(st, dnsCacheFile+".tmp")
	if os.WriteFile(tmp, []byte(body), 0o600) != nil {
		return
	}
	if !keepMtime.IsZero() {
		_ = os.Chtimes(tmp, keepMtime, keepMtime)
	}
	os.Rename(tmp, filepath.Join(st, dnsCacheFile)) // atomic: a torn read must never yield half a server
}

// loadDNSCache returns the published list and how old it is. Age comes from the file's mtime so the caller can
// apply the SAME staleness bound a long-lived process applies to its own cache -- there is no second, laxer
// trust rule for the cross-process path.
// ⚠ SUPERSEDED by NWP-20261119-25: no caller applies an age bound to the age now; seedDNSFromCache uses it only
// to back-date dnsGoodAt honestly. NWP-20261113-19 retired the age rule for the daemon, and a fork that kept
// applying it started cold after any idle spell.
func loadDNSCache() (addrs []string, age time.Duration, ok bool) {
	addrs, _, _, age, ok, _ = readDNSCache()
	return addrs, age, ok
}

// loadDoTCache returns the DoT posture the cache file carries: the strict host and its bootstrapped IPs.
// ok is false when the file is absent or has no DoT line.
func loadDoTCache() (host string, ips []string, ok bool) {
	_, host, ips, _, _, _ = readDNSCache()
	return host, ips, host != ""
}

// readDNSCache parses the whole file: the server lines, the optional DoT line, the optional iface line
// (NWP-20261119-25; a malformed name reads as "") and the file's age. ok follows the server list -- a file with
// only DoT and iface lines is no server cache.
func readDNSCache() (addrs []string, dotHost string, dotIPs []string, age time.Duration, ok bool, iface string) {
	st := os.Getenv("NOWHERE_STATE")
	if st == "" {
		return nil, "", nil, 0, false, ""
	}
	f := filepath.Join(st, dnsCacheFile)
	fi, err := os.Stat(f)
	if err != nil {
		return nil, "", nil, 0, false, ""
	}
	b, err := os.ReadFile(f)
	if err != nil {
		return nil, "", nil, 0, false, ""
	}
	for _, ln := range strings.Split(string(b), "\n") {
		ln = strings.TrimSpace(ln)
		switch {
		case ln == "":
		case strings.HasPrefix(ln, dnsCacheDoTPrefix):
			f := strings.Fields(ln[len(dnsCacheDoTPrefix):])
			if len(f) == 0 || !validDoTHost(f[0]) {
				continue
			}
			dotHost, dotIPs = f[0], nil
			if len(f) > 1 {
				for _, ip := range strings.Split(f[1], ",") {
					if net.ParseIP(ip) != nil {
						dotIPs = append(dotIPs, ip)
					}
				}
			}
		case strings.HasPrefix(ln, dnsCacheIfacePrefix):
			if name := strings.TrimSpace(ln[len(dnsCacheIfacePrefix):]); validCacheIface(name) {
				iface = name
			}
		default:
			addrs = append(addrs, ln)
		}
	}
	age = time.Since(fi.ModTime())
	return addrs, dotHost, dotIPs, age, len(addrs) > 0, iface
}

// saveDoTCache records a bootstrap result in the cache file for later forks, leaving the server lines, the iface
// line (NWP-20261119-25) AND the file's mtime exactly as they were: the DoT server's addresses are the provider's anycast, not a property of
// the network, so refreshing the age of the per-network list on their account would be a lie.
func saveDoTCache(host string, ips []string) {
	st := os.Getenv("NOWHERE_STATE")
	if st == "" || len(ips) == 0 {
		return
	}
	addrs, _, _, age, ok, iface := readDNSCache()
	if !ok {
		return // no server cache to attach the posture to; the daemon's next refresh writes both
	}
	writeDNSCache(st, addrs, host, ips, time.Now().Add(-age), iface)
}

// fallbackAddrs is publicFallbackDNS as host:port, matching the cached list's shape.
func fallbackAddrs() []string {
	f := publicFallbackDNS()
	out := make([]string, len(f))
	for i, s := range f {
		out[i] = net.JoinHostPort(s, "53")
	}
	return out
}

// ifaceUsable reports whether a named interface exists, is UP and carries at least one address -- i.e. whether
// traffic bound to it can actually leave. Used to reject a VPN the connectivity service reports as CONNECTED
// but whose tun is gone//down (#219). Fails CLOSED (false) on any error: a VPN we can't verify is one we don't
// scope DNS to, which is the safe direction -- we stay on the physical network rather than wedging on a dead one.
func ifaceUsable(name string) bool {
	ifi, err := net.InterfaceByName(name)
	if err != nil || ifi.Flags&net.FlagUp == 0 {
		return false
	}
	addrs, err := ifi.Addrs()
	return err == nil && len(addrs) > 0
}

// watchNetChanges blocks on a NETLINK_ROUTE socket and forces a resolver re-discovery the instant the kernel
// reports a link / route / address change -- so the egress interface and DNS the daemon binds to track the OS
// default network PROACTIVELY (e.g. hop to Wi-Fi the moment it validates and becomes the default), instead of
// only lazily on the next lookup's dnsTTL expiry. Without it a network change leaves the daemon bound to the
// old, now-unreachable network until some lookup happens to fire, and that first post-change dial wastes a full
// timeout before the on-failure force-refresh kicks in (surfaced as a brief stall on the first op after Wi-Fi
// comes up / drops). Best-effort and long-lived: if the netlink socket can't be opened or bound (e.g. an edition
// whose sepolicy doesn't grant the daemon domain netlink_route_socket) it just returns and the dnsTTL self-heal
// stays the only path -- so it is safe to start unconditionally. Started once from installResolver.
func watchNetChanges() {
	// rtnetlink multicast groups: link up/down + IPv4/IPv6 address and route changes.
	const groups = 0x1 | 0x10 | 0x40 | 0x100 | 0x400 // RTMGRP_LINK|IPV4_IFADDR|IPV4_ROUTE|IPV6_IFADDR|IPV6_ROUTE
	fd, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, syscall.NETLINK_ROUTE)
	if err != nil {
		return // best-effort: e.g. netlink_route_socket denied -> rely on the dnsTTL self-heal
	}
	defer syscall.Close(fd)
	if err := syscall.Bind(fd, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK, Groups: groups}); err != nil {
		return
	}
	buf := make([]byte, 8192)
	for {
		// Block with near-zero cost until the kernel reports a change.
		if _, _, err := syscall.Recvfrom(fd, buf, 0); err != nil {
			if err == syscall.EINTR {
				continue
			}
			return // socket error -> stop watching; the dnsTTL self-heal still covers us
		}
		// A single transition emits a BURST of messages. Let it settle (the new default needs a moment to
		// validate), then drain the rest non-blocking so we re-discover ONCE per event, not once per message.
		time.Sleep(400 * time.Millisecond)
		for {
			if _, _, err := syscall.Recvfrom(fd, buf, syscall.MSG_DONTWAIT); err != nil {
				break // EAGAIN: the queue is drained
			}
		}
		refreshNet(false) // re-read connectivity; change-only-logs a fresh "[resolver] egress iface=... resolvers=..."
	}
}

// dnsAddrs returns the cached DNS server list, refreshing (via refreshNet) when forced or older than dnsTTL. A
// refresh that yields nothing keeps the last good list rather than blanking it.
func dnsAddrs(force bool) []string {
	netMu.Lock()
	stale := force || len(dnsServers) == 0 || time.Since(netAt) > dnsTTL
	netMu.Unlock()
	if stale {
		refreshNet(force)
	}
	netMu.Lock()
	defer netMu.Unlock()
	return dnsServers
}

// defaultNetIface returns the validated default network's egress interface (e.g. "wlan0"), cached with the same
// TTL. Used to pin outbound sockets so a multi-network device (two SIMs + Wi-Fi) can't route the agent's traffic
// down an ambiguous fwmark path.
func defaultNetIface() string {
	netMu.Lock()
	stale := netIface == "" || time.Since(netAt) > dnsTTL
	netMu.Unlock()
	if stale {
		refreshNet(false)
	}
	netMu.Lock()
	defer netMu.Unlock()
	return netIface
}

// parseDefaultIface extracts the egress interface of the active default network from `dumpsys connectivity`:
// "Active default network: 102" then that network{102} block's "InterfaceName: wlan0". Empty if not found.
func parseDefaultIface(s string) string {
	const k = "Active default network:"
	i := strings.Index(s, k)
	if i < 0 {
		return ""
	}
	f := strings.Fields(s[i+len(k):])
	if len(f) == 0 {
		return ""
	}
	j := strings.Index(s, "network{"+f[0]+"}") // the default network's NetworkAgentInfo block
	if j < 0 {
		return ""
	}
	m := strings.Index(s[j:], "InterfaceName:")
	if m < 0 {
		return ""
	}
	nf := strings.Fields(s[j+m+len("InterfaceName:"):])
	if len(nf) == 0 {
		return ""
	}
	return strings.TrimRight(nf[0], ",")
}

// parseDefaultNetworkDNS returns the DnsAddresses (bare IPs, in order) of the ACTIVE DEFAULT network only -- the
// same network{N} block whose InterfaceName parseDefaultIface binds sockets to. Scoping the resolver to this one
// network keeps every server we dial reachable over the interface we SO_BINDTODEVICE to. A resolver advertised by
// a *different* up network -- e.g. a private cellular DNS like 172.26.x while Wi-Fi is the default, or an IMS
// PDN's fc00::/7 link-local -- is unreachable the moment we bind to the default iface, so it only burns a dial
// timeout and, when it happens to sort first (or a Wi-Fi flap blips the reachable one), surfaces as the
// multi-network "You're offline" / seal stall (#180). Empty if the marker, its block, or its DnsAddresses is absent.
func parseDefaultNetworkDNS(s string) []string {
	const k = "Active default network:"
	i := strings.Index(s, k)
	if i < 0 {
		return nil
	}
	f := strings.Fields(s[i+len(k):])
	if len(f) == 0 {
		return nil
	}
	j := strings.Index(s, "network{"+f[0]+"}") // the default network's NetworkAgentInfo block
	if j < 0 {
		return nil
	}
	m := strings.Index(s[j:], "DnsAddresses:") // the first (this network's) DnsAddresses after the block start
	if m < 0 {
		return nil
	}
	rest := s[j+m+len("DnsAddresses:"):]
	lb := strings.Index(rest, "[")
	rb := strings.Index(rest, "]")
	if lb < 0 || rb < 0 || rb < lb {
		return nil
	}
	var out []string
	for _, t := range strings.FieldsFunc(rest[lb+1:rb], func(r rune) bool {
		return r == ',' || r == ' ' || r == '\t' || r == '\n'
	}) {
		t = strings.TrimPrefix(strings.TrimSpace(t), "/")
		if net.ParseIP(t) != nil {
			out = append(out, t)
		}
	}
	return out
}

// privateDNS is the private-DNS posture LinkProperties.toString() prints for ONE network. Source of record
// (packages/modules/Connectivity, identical on LineageOS and GrapheneOS):
//
//	framework/src/android/net/LinkProperties.java:950-957 (toString)
//	    if (mUsePrivateDns)              resultJoiner.add("UsePrivateDns: true");
//	    if (mPrivateDnsServerName != null) { resultJoiner.add("PrivateDnsServerName:"); resultJoiner.add(mPrivateDnsServerName); }
//	    ...ValidatedPrivateDnsAddresses: [<getHostAddress>,<...>]     (:965-972, no leading slash, no spaces)
//	service/.../connectivity/DnsManager.java:302-322 (updatePrivateDnsStatus)
//	    tlsHostname     = strictMode ? cfg.hostname : null     -> the name is printed in STRICT mode ONLY
//	    usingPrivateDns = strictMode || validated               -> "true" alone is opportunistic-and-validated
//	service/.../connectivity/NetworkAgentInfo.java:1619 (toString)   "  lp{" + linkProperties + "}"
//	service/.../ConnectivityService.java:4840-4842 (dumpNetworks)    pw.println(nai.toString())
//
// so the `lp{{...}}` block the agent already parses for DnsAddresses is LinkProperties.toString() verbatim, and
// the fragments sit right after DnsAddresses: [...] in the same block.
type privateDNS struct {
	Host      string   // PrivateDnsServerName -- present means STRICT mode; "" = off or opportunistic
	Use       bool     // UsePrivateDns: true -- strict, or opportunistic with a validated server
	Validated []string // ValidatedPrivateDnsAddresses -- the OS-validated addresses of the DoT server, bare IPs
}

// parsePrivateDNS reads the posture out of one network's block (see defaultNetworkBlock / vpnNetworkBlock).
// The block MUST be bounded to one NetworkAgentInfo: every fragment here is optional, so an unbounded search
// would read the next network's hostname into this one.
func parsePrivateDNS(block string) privateDNS {
	var pd privateDNS
	if block == "" {
		return pd
	}
	pd.Use = strings.Contains(block, "UsePrivateDns: true")
	const hk = "PrivateDnsServerName:"
	if m := strings.Index(block, hk); m >= 0 {
		if f := strings.Fields(block[m+len(hk):]); len(f) > 0 && validDoTHost(strings.ToLower(f[0])) {
			pd.Host = strings.ToLower(f[0])
		}
	}
	const vk = "ValidatedPrivateDnsAddresses: ["
	if m := strings.Index(block, vk); m >= 0 {
		r := block[m+len(vk):]
		if rb := strings.IndexByte(r, ']'); rb >= 0 {
			for _, t := range strings.FieldsFunc(r[:rb], func(c rune) bool { return c == ',' || c == ' ' }) {
				if t = strings.TrimPrefix(t, "/"); net.ParseIP(t) != nil {
					pd.Validated = append(pd.Validated, t)
				}
			}
		}
	}
	return pd
}

// validDoTHost accepts what the private_dns_specifier setting can sensibly hold: a DNS hostname (lower-case
// letters, digits, dots, hyphens) or an IP literal. Anything else -- an empty specifier prints the NEXT
// fragment's key as the "name" -- is treated as no hostname.
func validDoTHost(h string) bool {
	if h == "" || strings.HasSuffix(h, ":") {
		return false
	}
	if net.ParseIP(h) != nil {
		return true
	}
	for _, c := range h {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '-') {
			return false
		}
	}
	return h[0] != '.' && h[0] != '-'
}

// defaultNetworkBlock returns the ACTIVE DEFAULT network's NetworkAgentInfo text -- the same network{N} block
// parseDefaultIface and parseDefaultNetworkDNS read -- bounded at the next NetworkAgentInfo. "" when the marker
// or the block is absent (the user-switch window), which callers treat as "unknown", never as "off".
func defaultNetworkBlock(s string) string {
	const k = "Active default network:"
	i := strings.Index(s, k)
	if i < 0 {
		return ""
	}
	f := strings.Fields(s[i+len(k):])
	if len(f) == 0 {
		return ""
	}
	j := strings.Index(s, "network{"+f[0]+"}")
	if j < 0 {
		return ""
	}
	return boundNetworkBlock(s[j:])
}

// vpnNetworkBlock returns the connected VpnService network's block (the one parseVpnNetwork reads), bounded
// the same way. "" when no VPN is up.
func vpnNetworkBlock(s string) string {
	i := strings.Index(s, "ni{VPN CONNECTED")
	if i < 0 {
		return ""
	}
	return boundNetworkBlock(s[i:])
}

// boundNetworkBlock cuts rest at the start of the next NetworkAgentInfo, so per-network fragments cannot bleed
// across networks.
func boundNetworkBlock(rest string) string {
	if e := strings.Index(rest, "NetworkAgentInfo{"); e >= 0 {
		return rest[:e]
	}
	return rest
}

// routeKind is what a VPN route entry does with the traffic it matches. On a tie at one prefix length the higher
// kind wins: a block over a bypass over a route -- never claim more than the entries show.
type routeKind int

const (
	kindRoute       routeKind = iota // `->`: into the tunnel
	kindThrow                        // `throw`: out of the VPN's table, i.e. the physical network
	kindUnreachable                  // `unreachable`: Android's block for a family the VPN does not carry
)

// vpnRoute is one entry of a VPN network's routes: its destination prefix and its kind.
type vpnRoute struct {
	dst  *net.IPNet
	bits int
	kind routeKind
}

// vpnEgress is a usable session VPN: its tun, its parsed routes, and whether it is full in intent.
type vpnEgress struct {
	iface  string
	routes []vpnRoute
	full   bool
}

// takes reports whether the VPN takes ip. A `->` route does. An `unreachable` block does only in a tunnel that is
// full in intent, where it is the VPN refusing that family and the connection fails closed in the tun. In a split
// tunnel Android blocks that family for the session's apps too, but the 2026-09-26 decision -- a split tunnel does
// not carry the daemon -- sends the daemon's connection physical. A `throw` carve-out, or no match, leaves the
// destination to the physical network.
func (v vpnEgress) takes(ip net.IP) bool {
	switch v.match(ip) {
	case kindRoute:
		return true
	case kindUnreachable:
		return v.full
	}
	return false
}

// match is the kind of ip's longest-prefix match among the VPN's routes, kindThrow when nothing matches (the
// physical network either way).
func (v vpnEgress) match(ip net.IP) routeKind {
	best, kind := -1, kindThrow
	for _, r := range v.routes {
		if !r.dst.Contains(ip) || r.bits < best {
			continue
		}
		if r.bits > best || r.kind > kind {
			kind = r.kind
		}
		best = r.bits
	}
	return kind
}

// tunnelFallbackDNS is the public fallback resolvers for a full tunnel that names none of its own: those the
// tunnel routes (a `->` match, so not carved out or blocked), or all of them if it routes none.
func tunnelFallbackDNS(v vpnEgress) []string {
	var out []string
	for _, s := range publicFallbackDNS() {
		if ip := net.ParseIP(s); ip != nil && v.match(ip) == kindRoute {
			out = append(out, s)
		}
	}
	if len(out) == 0 {
		return publicFallbackDNS()
	}
	return out
}

// parseVpnRoutes reads a VPN network block's `Routes: [ <dest> -> <gw> <iface> mtu <n>,... ]` (RouteInfo.toString),
// IPv4 and IPv6, with `throw` (a carve-out) or `unreachable` (a block) in place of `-> ...`. Entries it cannot parse
// are skipped; no parseable entry at all is an empty result, by which the VPN takes nothing.
func parseVpnRoutes(block string) []vpnRoute {
	m := strings.Index(block, "Routes: [")
	if m < 0 {
		return nil
	}
	r := block[m+len("Routes: ["):]
	e := strings.Index(r, "]")
	if e < 0 {
		return nil
	}
	var out []vpnRoute
	for _, ent := range strings.Split(r[:e], ",") {
		f := strings.Fields(ent)
		if len(f) < 2 {
			continue
		}
		_, n, err := net.ParseCIDR(f[0])
		if err != nil {
			continue
		}
		ones, _ := n.Mask.Size()
		switch f[1] {
		case "->":
			out = append(out, vpnRoute{dst: n, bits: ones, kind: kindRoute})
		case "throw":
			out = append(out, vpnRoute{dst: n, bits: ones, kind: kindThrow})
		case "unreachable":
			out = append(out, vpnRoute{dst: n, bits: ones, kind: kindUnreachable})
		}
	}
	return out
}

// vpnFullGapMax is how much public IPv4 a tunnel's own `->` routes may leave to the physical network and still be
// full in intent (vpnFullInIntent): one /8's worth. A split tunnel leaves nearly all of it; a full tunnel with
// deliberate carve-outs (its own server, a LAN, a couple of public resolver ranges -- shadowsocks' bypass list leaves
// two /24s) leaves a sliver.
const vpnFullGapMax = uint64(1) << 24

// vpnFullGapMax6 is the IPv6 counterpart for a v6-only full tunnel: the same share of global unicast (2000::/3, 2^125
// addresses) as one /8 is of IPv4 -- 1/256 of it.
var vpnFullGapMax6 = new(big.Int).Lsh(big.NewInt(1), 117)

// vpnFullInIntent reports whether the tunnel is meant to carry everything: its own `->` routes leave at most one /8
// of public IPv4 to the physical network, or it is a v6-only full tunnel -- Android blocks IPv4 in it (a family-wide
// `0.0.0.0/0 unreachable`) and its `->` routes leave at most 1/256 of global unicast IPv6 (2000::/3) to the physical
// network, by the same longest-prefix arithmetic (so `::/0`, `2000::/3`, and OpenVPN's `2000::/4` + `3000::/4` all
// count).
func vpnFullInIntent(routes []vpnRoute) bool {
	if vpnPublicGap(routes) <= vpnFullGapMax {
		return true
	}
	v4Blocked := false
	for _, r := range routes {
		if ones, size := r.dst.Mask.Size(); r.kind == kindUnreachable && size == 8*net.IPv4len && ones == 0 {
			v4Blocked = true
		}
	}
	return v4Blocked && vpnPublicGap6(routes).Cmp(vpnFullGapMax6) <= 0
}

// vpnPublicGap6 is vpnPublicGap for IPv6: how much of global unicast (2000::/3) the VPN's own `->` routes do not
// take, segment by segment between prefix boundaries.
func vpnPublicGap6(routes []vpnRoute) *big.Int {
	type prefix6 struct {
		start, end *big.Int
		bits       int
		kind       routeKind
	}
	lo := new(big.Int).SetBytes(net.ParseIP("2000::").To16())
	hi := new(big.Int).Add(lo, new(big.Int).Lsh(big.NewInt(1), 125))
	bounds := []*big.Int{lo, hi}
	var ps []prefix6
	for _, r := range routes {
		if len(r.dst.Mask) != net.IPv6len || r.dst.IP.To4() != nil {
			continue
		}
		start := new(big.Int).SetBytes(r.dst.IP.To16())
		end := new(big.Int).Add(start, new(big.Int).Lsh(big.NewInt(1), uint(128-r.bits)))
		ps = append(ps, prefix6{start: start, end: end, bits: r.bits, kind: r.kind})
		for _, b := range []*big.Int{start, end} {
			if b.Cmp(lo) > 0 && b.Cmp(hi) < 0 {
				bounds = append(bounds, b)
			}
		}
	}
	sort.Slice(bounds, func(i, j int) bool { return bounds[i].Cmp(bounds[j]) < 0 })
	gap := new(big.Int)
	for i := 0; i+1 < len(bounds); i++ {
		a := bounds[i]
		if a.Cmp(bounds[i+1]) == 0 {
			continue
		}
		best, kind := -1, kindThrow
		for _, pf := range ps {
			if a.Cmp(pf.start) < 0 || a.Cmp(pf.end) >= 0 || pf.bits < best {
				continue
			}
			if pf.bits > best || pf.kind > kind {
				kind = pf.kind
			}
			best = pf.bits
		}
		if best < 0 || kind != kindRoute {
			gap.Add(gap, new(big.Int).Sub(bounds[i+1], a))
		}
	}
	return gap
}

// vpnPublicGap counts the public IPv4 addresses the VPN's own `->` routes do not take: those whose longest-prefix
// match among routes is a `throw`, an `unreachable` block, or nothing. It splits the address space at every prefix
// boundary; within one segment every address matches the same prefixes, so the segment's first address decides
// all of it.
func vpnPublicGap(routes []vpnRoute) uint64 {
	var v4 []ipv4Prefix
	for _, r := range routes {
		if ip4 := r.dst.IP.To4(); ip4 != nil && len(r.dst.Mask) == net.IPv4len {
			v4 = append(v4, ipv4Prefix{start: ipv4Uint(ip4), bits: r.bits, kind: r.kind})
		}
	}
	bounds := map[uint64]bool{0: true, 1 << 32: true}
	for _, pf := range append(append([]ipv4Prefix(nil), v4...), ipv4NotPublic...) {
		bounds[uint64(pf.start)] = true
		bounds[uint64(pf.start)+pf.size()] = true
	}
	cuts := make([]uint64, 0, len(bounds))
	for b := range bounds {
		cuts = append(cuts, b)
	}
	sort.Slice(cuts, func(i, j int) bool { return cuts[i] < cuts[j] })
	var gap uint64
	for i := 0; i+1 < len(cuts); i++ {
		a := uint32(cuts[i])
		if ipv4InAny(a, ipv4NotPublic) {
			continue
		}
		best, kind := -1, kindThrow
		for _, pf := range v4 {
			if !pf.contains(a) || pf.bits < best {
				continue
			}
			if pf.bits > best || pf.kind > kind {
				kind = pf.kind
			}
			best = pf.bits
		}
		if best < 0 || kind != kindRoute {
			gap += cuts[i+1] - cuts[i]
		}
	}
	return gap
}

// ipv4Prefix is an IPv4 prefix as a start address and a length, for vpnPublicGap's segment arithmetic.
type ipv4Prefix struct {
	start uint32
	bits  int
	kind  routeKind
}

func (p ipv4Prefix) size() uint64 { return uint64(1) << uint(32-p.bits) }

func (p ipv4Prefix) contains(a uint32) bool {
	return uint64(a) >= uint64(p.start) && uint64(a) < uint64(p.start)+p.size()
}

func ipv4Uint(ip4 net.IP) uint32 {
	return uint32(ip4[0])<<24 | uint32(ip4[1])<<16 | uint32(ip4[2])<<8 | uint32(ip4[3])
}

// ipv4NotPublic are the ranges no tunnel is expected to carry: this-network, RFC 1918, CGNAT (Tailscale's own
// space), loopback, link-local, the IANA special-purpose blocks (IETF protocol assignments, the three
// documentation nets, 6to4 relay anycast, benchmarking) and multicast/reserved.
var ipv4NotPublic = func() []ipv4Prefix {
	var out []ipv4Prefix
	for _, c := range []string{"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
		"172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16", "198.18.0.0/15",
		"198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/3"} {
		if _, n, err := net.ParseCIDR(c); err == nil {
			ones, _ := n.Mask.Size()
			out = append(out, ipv4Prefix{start: ipv4Uint(n.IP.To4()), bits: ones})
		}
	}
	return out
}()

func ipv4InAny(a uint32, ps []ipv4Prefix) bool {
	for _, p := range ps {
		if p.contains(a) {
			return true
		}
	}
	return false
}

// parseVpnNetwork returns the tun InterfaceName + DnsAddresses of an ACTIVE per-user VPN (a VpnService network)
// from `dumpsys connectivity`, or ("", nil) if none is up. #159: a roamed session's VPN appears as a connected
// NetworkAgentInfo whose ni{ is "VPN CONNECTED" and whose lp{{ carries the tun InterfaceName (tun0) + the VPN's
// own DnsAddresses; note the "Active default network" stays the PHYSICAL underlay (the daemon/system UID isn't
// inside the VPN's per-user UID range), so the VPN must be found by its own block, not via parseDefaultIface.
// When present, refreshNet keeps it as the session VPN and bindControl sends it every connection it takes by its
// routes (NWP-20260925-03: per destination, not the whole tunnel), so seal/restore/gateway traffic the tunnel
// carries -- or, in a full tunnel, blocks -- rides it instead of leaking to the local network.
// NWP-20260925-03: both fields are read from the VPN's OWN block (vpnNetworkBlock). The search used to run to the
// end of the dump, and while an IKEv2 VPN reconnects Android drops its InterfaceName (Vpn's session-lost path), so
// the next network's interface -- wlan0 -- was taken for the tunnel's. A block with no interface is no VPN.
func parseVpnNetwork(s string) (string, []string) {
	rest := vpnNetworkBlock(s) // the connected VpnService network's NetworkAgentInfo block
	if rest == "" {
		return "", nil
	}
	iface := ""
	if m := strings.Index(rest, "InterfaceName:"); m >= 0 {
		if nf := strings.Fields(rest[m+len("InterfaceName:"):]); len(nf) > 0 {
			iface = strings.TrimRight(nf[0], ",")
		}
	}
	if iface == "" {
		return "", nil
	}
	return iface, parseDnsAddresses(rest)
}

// parseDnsAddresses reads a network block's `DnsAddresses: [ /a,/b ]`, whatever else the block holds.
func parseDnsAddresses(block string) []string {
	var dns []string
	if m := strings.Index(block, "DnsAddresses:"); m >= 0 {
		r2 := block[m+len("DnsAddresses:"):]
		lb, rb := strings.Index(r2, "["), strings.Index(r2, "]")
		if lb >= 0 && rb > lb {
			for _, t := range strings.FieldsFunc(r2[lb+1:rb], func(r rune) bool {
				return r == ',' || r == ' ' || r == '\t' || r == '\n'
			}) {
				t = strings.TrimPrefix(strings.TrimSpace(t), "/")
				if net.ParseIP(t) != nil {
					dns = append(dns, t)
				}
			}
		}
	}
	return dns
}

// bindControl pins a socket to the validated default network's egress interface (SO_BINDTODEVICE) before it
// connects. On a multi-network device (two SIMs + Wi-Fi) an UNBOUND cgo-less socket gets ambiguous fwmark
// routing and its connections stall mid-flight (TLS handshakes, then the HTTP response never arrives); binding
// to the default interface makes egress deterministic. Best-effort: if the interface is unknown or the bind is
// denied (needs CAP_NET_RAW / a sepolicy net_raw grant), the socket is left unbound rather than failing the dial.
//
// NWP-20260925-03: the interface is chosen PER DESTINATION (egressFor): a session VPN gets exactly the destinations
// it takes (vpnEgress.takes: a `->` route, or -- in a tunnel that is full in intent -- an `unreachable` block), and
// everything else goes out on the physical default network. Resolver dials are the exception -- they are bound by
// provenance (dnsBindControl).
func bindControl(network, address string, c syscall.RawConn) error {
	if iface := egressFor(address); iface != "" {
		bindToIface(c, iface)
	}
	return nil
}

// bindToIface pins a socket to iface (SO_BINDTODEVICE), best-effort. A variable only so a test can read which
// interface a dial chose without binding it: the tunnels a test describes do not exist on the test host.
var bindToIface = func(c syscall.RawConn, iface string) {
	_ = c.Control(func(fd uintptr) {
		_ = syscall.SetsockoptString(int(fd), syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, iface)
	})
}

// egressFor is the interface a socket dialling address ("ip:port", as Dialer.Control receives it) is bound to:
// the session VPN's tun when the VPN takes that destination (vpnEgress.takes), else the physical default network's
// interface. A destination that does not parse as an IP -- a link-local address with a zone, say -- belongs to the
// physical link and never rides the tunnel.
func egressFor(address string) string {
	phys := defaultNetIface() // refreshes netIface and vpnEg when stale
	netMu.Lock()
	v := vpnEg
	netMu.Unlock()
	if v.iface == "" {
		return phys
	}
	host := address
	if h, _, err := net.SplitHostPort(address); err == nil {
		host = h
	}
	if ip := net.ParseIP(host); ip != nil && v.takes(ip) {
		return v.iface
	}
	return phys
}

// dnsBindControl is the Control of every resolver dial: it binds by the list's provenance (dnsEgress), not by the
// resolver's address.
func dnsBindControl(network, address string, c syscall.RawConn) error {
	if iface := dnsEgress(); iface != "" {
		bindToIface(c, iface)
	}
	return nil
}

// dnsEgress is the interface every resolver dial -- plain :53 and DoT, bootstrap included -- is bound to: the VPN's
// tun while the resolver list in force is scoped to it (dnsFromVPN: a full tunnel's own resolvers, or the public
// ones it is asked through), else the physical default interface.
func dnsEgress() string {
	phys := defaultNetIface() // refreshes when stale
	netMu.Lock()
	defer netMu.Unlock()
	if dnsFromVPN && vpnEg.iface != "" {
		return vpnEg.iface
	}
	return phys
}

// vpnStateLine is the change-only line for a VPN classification ("<iface> full|split|unreadable").
func vpnStateLine(state string) string {
	i := strings.LastIndex(state, " ")
	iface, kind := state[:i], state[i+1:]
	switch kind {
	case "full":
		return fmt.Sprintf("[resolver] VPN %q is a full tunnel -- it carries the daemon's traffic and resolves its lookups (NWP-20260925-03)", iface)
	case "split":
		return fmt.Sprintf("[resolver] VPN %q does not route all public IPv4 (a split tunnel) -- only the destinations it routes ride it; the rest, and the physical network's own resolvers, use the physical network (NWP-20260925-03)", iface)
	default:
		return fmt.Sprintf("[resolver] VPN %q: its routes are unreadable -- the daemon stays on the physical network (NWP-20260925-03)", iface)
	}
}

// setResolverDynamic installs a resolver that re-discovers the device's DNS servers on a short TTL and, on a
// total dial failure, forces one immediate re-discovery + retry. This self-heals across the login/roam settling
// window and SIM/network changes, where the old one-shot startup snapshot would stay wedged for the process life.
//
// NWP-20260904-12: in strict private-DNS mode the Dial hands Go's resolver a TLS stream to the configured host
// instead of a UDP socket (dialDNS). A DoT failure is returned as-is -- it is NOT retried through the plain
// re-discovery path, because that path's whole purpose is to find OTHER plain servers, and strict mode has
// no other server. The dnsTTL refresh still picks up a posture change (the user turning private DNS off).
func setResolverDynamic() {
	net.DefaultResolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			d := &net.Dialer{Timeout: 5 * time.Second, Control: dnsBindControl} // bound by the list's provenance (NWP-20260925-03)
			c, err := dialDNS(ctx, network, dnsTargetFor(false), d)
			if err == nil {
				return c, nil
			}
			var de *dotError
			if errors.As(err, &de) {
				return nil, err // fail CLOSED: strict private DNS never degrades to plaintext
			}
			return dialDNS(ctx, network, dnsTargetFor(true), d) // all servers failed -> re-discover once (settling / net change) and retry
		},
	}
}

// dnsTarget is a snapshot of where this process resolves: the plain servers and, in strict private-DNS mode,
// the DoT host with its known endpoints.
type dnsTarget struct {
	plain    []string // host:53 -- the network's own resolvers or the cold-start fallback
	dot      string   // strict private-DNS hostname; "" = plain DNS
	dotAddrs []string // ip:853 endpoints for dot, when already known; empty = the first dial bootstraps
}

// dnsTargetFor returns the current snapshot, refreshing under the same rules as dnsAddrs.
func dnsTargetFor(force bool) dnsTarget {
	plain := dnsAddrs(force)
	netMu.Lock()
	defer netMu.Unlock()
	return dnsTarget{plain: plain, dot: dotHost, dotAddrs: append([]string(nil), dotAddrs...)}
}

// dotPort is the DNS-over-TLS port (RFC 7858). A variable only so the tests can stand a DoT server on an
// ephemeral port.
var dotPort = "853"

// plainPort is the port a DISCOVERED plain resolver is dialled on. A variable for the same reason as dotPort:
// so a test can drive the production resolver -- setResolverDynamic, dnsBindControl and all -- against a plain
// server on an ephemeral port, which is the only way to exercise the Dial closure every device lookup runs.
var plainPort = "53"

// dotTLSConfig builds the client TLS configuration for a DoT endpoint: the configured hostname is the
// ServerName, so the server's certificate is verified against the NAME the user configured, whichever address
// the bootstrap produced -- an on-path resolver that lies about the A record still cannot pass. A variable so
// the tests can trust their own self-signed server; the device uses the system roots.
var dotTLSConfig = func(host string) *tls.Config {
	return &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12}
}

// dotError marks a failure of the strict private-DNS path, so the caller can tell "the DoT server is
// unreachable" (fail closed) from "the plain servers failed" (re-discover and retry).
type dotError struct {
	host string
	err  error
}

func (e *dotError) Error() string { return "DoT " + e.host + " unreachable: " + e.err.Error() }
func (e *dotError) Unwrap() error { return e.err }

// dialDNS opens the connection Go's resolver will send one query over. Plain mode: a UDP/TCP socket to the
// first reachable server. Strict mode: a TLS stream to the DoT host, bootstrapping its addresses first when
// nothing is cached. When every known endpoint fails it re-bootstraps ONCE (bypassing the caches, in case the
// provider moved) and retries only if that produced a different set; then it fails, closed. Every failure
// path in strict mode returns a *dotError and never touches the plain servers for the actual query.
func dialDNS(ctx context.Context, network string, t dnsTarget, d *net.Dialer) (net.Conn, error) {
	if t.dot == "" {
		return dialPlain(ctx, network, t.plain, d)
	}
	addrs := t.dotAddrs
	if len(addrs) == 0 {
		var err error
		if addrs, err = dotEndpoints(ctx, t.dot, t.plain, d, false); err != nil {
			return nil, dotUnreachable(t.dot, err)
		}
	}
	c, err := dialDoT(ctx, t.dot, addrs, d)
	if err == nil {
		return c, nil
	}
	if fresh, berr := dotEndpoints(ctx, t.dot, t.plain, d, true); berr == nil && !sameStrings(fresh, addrs) {
		if c, err = dialDoT(ctx, t.dot, fresh, d); err == nil {
			return c, nil
		}
	}
	return nil, dotUnreachable(t.dot, err)
}

// dialPlain is the pre-existing plain-DNS dial. NWP-20260822-04: report EVERY server's failure, not just the
// last one.
//
// This loop used to keep only the final error, so a total failure was reported as whatever address happened
// to be last in the list. That is how the #64 investigation lost a day: the captured error named
// `[2001:4860:4860::8888]:53` (the last entry of the public fallback), which read as "IPv6 is the problem"
// when the truth was "all four servers failed and v6 was simply last". A one-line change makes the next
// capture say which servers were tried and how each one failed -- the difference between a diagnosis and a
// guess.
func dialPlain(ctx context.Context, network string, addrs []string, d *net.Dialer) (net.Conn, error) {
	pe := &plainDialError{}
	for _, a := range addrs {
		c, e := d.DialContext(ctx, network, a)
		if e == nil {
			return c, nil
		}
		pe.addrs = append(pe.addrs, a)
		pe.errs = append(pe.errs, e)
	}
	if len(pe.errs) == 0 {
		return nil, errors.New("resolver: no dns servers configured")
	}
	return nil, pe
}

// plainDialError is dialPlain's total failure: every server and how it failed. Error() is the addressed text
// above (the plain path's diagnostic); kinds() is the same failure with the addresses left out, for the strict
// path, whose failures land in login.log and must not name a network's resolvers.
type plainDialError struct {
	addrs []string
	errs  []error
}

func (e *plainDialError) Error() string {
	parts := make([]string, len(e.errs))
	for i, err := range e.errs {
		parts[i] = e.addrs[i] + ": " + err.Error()
	}
	return "resolver: all " + strconv.Itoa(len(parts)) + " dns server(s) failed [" + strings.Join(parts, "; ") + "]"
}

func (e *plainDialError) kinds() []string {
	out := make([]string, len(e.errs))
	for i, err := range e.errs {
		out[i] = describeDialErr(err)
	}
	return out
}

// dialDoT connects to the first reachable DoT endpoint and completes the TLS handshake as host. The returned
// *tls.Conn is a stream, not a net.PacketConn, so Go's resolver frames the query with the 2-byte length prefix
// of DNS-over-TCP -- which is the DoT wire format. Per-endpoint errors are reported WITHOUT the address (the
// login.log travel-history rule): the host, the count, and each failure's kind.
func dialDoT(ctx context.Context, host string, addrs []string, d *net.Dialer) (net.Conn, error) {
	var errs []string
	for _, a := range addrs {
		raw, err := d.DialContext(ctx, "tcp", a)
		if err != nil {
			errs = append(errs, describeDialErr(err))
			continue
		}
		tc := tls.Client(raw, dotTLSConfig(host))
		if err := tc.HandshakeContext(ctx); err != nil {
			raw.Close()
			// A handshake that dies on the wire (a middlebox that accepts 853 and resets, EOF, a timeout) is a
			// net.OpError carrying the DEVICE'S OWN ip:port on that network as well as the endpoint's -- strip
			// it like a dial error. Certificate and alert errors carry no addresses and pass through.
			errs = append(errs, "tls: "+describeDialErr(err))
			continue
		}
		return tc, nil
	}
	if len(errs) == 0 {
		return nil, errors.New("no endpoints")
	}
	return nil, errors.New("all " + strconv.Itoa(len(errs)) + " endpoint(s) failed [" + strings.Join(errs, "; ") + "]")
}

// describeDialErr is a dial error minus its address: "dial: connection refused" rather than
// "dial tcp 1.2.3.4:853: connect: connection refused". A *net.AddrError (a server string that does not parse:
// no port, a bad literal) is stripped too -- its text is "address <the string>: <why>", so only the why is kept:
// "dial: missing port in address".
func describeDialErr(err error) string {
	var oe *net.OpError
	var ae *net.AddrError
	if errors.As(err, &ae) {
		if errors.As(err, &oe) {
			return oe.Op + ": " + ae.Err
		}
		return ae.Err
	}
	if errors.As(err, &oe) && oe.Err != nil {
		if se, ok := oe.Err.(*os.SyscallError); ok && se.Syscall == oe.Op {
			return oe.Op + ": " + se.Err.Error() // "read: connection reset by peer", not "read: read: ..."
		}
		return oe.Op + ": " + oe.Err.Error()
	}
	return err.Error()
}

// describeBootstrapErr is a failed plaintext bootstrap minus every address. Go's resolver reports a lookup
// failure as a *net.DNSError whose Err TEXT embeds whatever failed underneath: our own dialPlain text (the
// network's resolver addresses, verbatim) or a read/write OpError ("read udp <device ip:port>-><resolver>:53:
// <kind>"). The strict path prints its failure to login.log, so none of that may pass through: the dial kinds
// are taken from the typed failures dialPlain recorded (dialKinds), a read/write failure keeps only its final
// kind, and the two lookup outcomes Go flags are named as such.
func describeBootstrapErr(err error, dialKinds []string) string {
	var de *net.DNSError
	isDNS := errors.As(err, &de)
	switch {
	case isDNS && de.IsNotFound:
		return "no such host"
	case isDNS && de.IsTimeout:
		return "timeout"
	case len(dialKinds) > 0:
		return "all " + strconv.Itoa(len(dialKinds)) + " plain dial(s) failed [" + strings.Join(dedupeStr(dialKinds), "; ") + "]"
	case isDNS:
		s := de.Err
		if i := strings.LastIndex(s, ": "); i >= 0 {
			s = s[i+2:] // "read udp a->b: read: connection refused" -> "connection refused"
		}
		return s
	}
	return describeDialErr(err)
}

// The DoT memory. LOCK ORDER: dotMu is a LEAF lock -- it is never held while acquiring netMu, while dialling,
// or while a lookup runs, and netMu is never held while acquiring it (refreshNet and seedDNSFromCache resolve
// the posture before they take netMu). The cycle this rules out was found in review: a bootstrap's plaintext
// dial runs its Control -> defaultNetIface -> netMu (bindControl then; dnsBindControl -> dnsEgress since
// NWP-20260925-03), and refreshNet ran dotTargetFor -> knownDoT -> dotMu while holding netMu, so a bootstrap that
// held dotMu across its lookup and any concurrent refresh (the netlink watcher, a sibling AAAA goroutine, any
// dial's stale Control) waited for each other until the lookup's context expired -- a spurious fail-closed on a
// working DoT network, and a process-wide dial stall.
var (
	dotMu     sync.Mutex
	dotBoot   = map[string][]string{}  // host -> ip:853 endpoints, from the OS-validated list or a bootstrap
	dotBootAt = map[string]time.Time{} // host -> when a plaintext bootstrap last ran (bounds the re-bootstrap)
	dotLogAt  = map[string]time.Time{}
	dotFlight = map[string]*dotBootstrap{} // host -> the plaintext bootstrap in progress, if any
)

// dotBootstrap is one in-flight plaintext bootstrap of a host. Concurrent callers (Go's A and AAAA goroutines
// for the same lookup, or two lookups) wait on done and share the result instead of each bootstrapping.
type dotBootstrap struct {
	done  chan struct{}
	addrs []string // ip:853
	bare  []string // the same addresses without the port, for the cache file
	err   error
}

// dotUnreachable logs the strict-mode failure -- at most once per host per dnsKeepMax, since on a network
// that blocks 853 EVERY lookup fails and login.log does not need one line each -- and returns it typed.
func dotUnreachable(host string, err error) error {
	dotMu.Lock()
	if time.Since(dotLogAt[host]) > dnsKeepMax {
		dotLogAt[host] = time.Now()
		fmt.Fprintf(os.Stderr, "[resolver] DoT %s unreachable: %v\n", host, err)
	}
	dotMu.Unlock()
	return &dotError{host: host, err: err}
}

// rememberDoT records a host's endpoints in this process's memory (the shared file is written by refreshNet
// with the server list, and by the bootstrap).
func rememberDoT(host string, addrs []string) {
	if len(addrs) == 0 {
		return
	}
	dotMu.Lock()
	dotBoot[host] = addrs
	dotMu.Unlock()
}

// knownDoT returns the endpoints already known for host -- this process's memory first, then the shared cache
// file -- or nil.
func knownDoT(host string) []string {
	dotMu.Lock()
	a := dotBoot[host]
	dotMu.Unlock()
	if len(a) > 0 {
		return a
	}
	if h, ips, ok := loadDoTCache(); ok && h == host {
		if a = dotEndpointsOf(ips); len(a) > 0 {
			dotMu.Lock()
			dotBoot[host] = a
			dotMu.Unlock()
		}
	}
	return a
}

// dotEndpoints resolves the DoT host to ip:853 endpoints. Cached answers (memory, then the shared file) win
// unless bypass is set; otherwise it BOOTSTRAPS: one plaintext A/AAAA lookup of the DoT hostname through the
// plain servers -- exactly the one query the OS's own resolver makes in plaintext in strict mode, and the only
// one this process makes. One bootstrap per host is in flight at a time (dotFlight): Go's concurrent A and
// AAAA goroutines cannot both bootstrap -- the second waits for the first's answer -- and dotMu is NOT held
// while the lookup runs, because its dials take netMu through dnsBindControl (the lock-order rule at dotMu). A
// bypass (every endpoint just failed) re-bootstraps at most once per dnsKeepMax: on a network that blocks 853
// every lookup fails, and Go retries each one several times, so an unbounded re-bootstrap would turn one
// blocked lookup into a burst of plaintext queries.
func dotEndpoints(ctx context.Context, host string, plain []string, d *net.Dialer, bypass bool) ([]string, error) {
	if net.ParseIP(host) != nil {
		return []string{net.JoinHostPort(host, dotPort)}, nil
	}
	if !bypass {
		if a := knownDoT(host); len(a) > 0 {
			return a, nil
		}
	}
	dotMu.Lock()
	if a := dotBoot[host]; len(a) > 0 && (!bypass || time.Since(dotBootAt[host]) < dnsKeepMax) {
		dotMu.Unlock()
		return a, nil // a concurrent caller bootstrapped meanwhile, or the re-bootstrap is still fresh
	}
	if f := dotFlight[host]; f != nil {
		dotMu.Unlock()
		select { // join the bootstrap already running, or give up when our own caller does
		case <-f.done:
			return f.addrs, f.err
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if len(plain) == 0 {
		dotMu.Unlock()
		return nil, errors.New("no plain server to bootstrap through")
	}
	f := &dotBootstrap{done: make(chan struct{})}
	dotFlight[host] = f
	dotMu.Unlock()

	f.addrs, f.bare, f.err = bootstrapDoT(ctx, host, plain, d) // no lock held: this dials

	dotMu.Lock()
	delete(dotFlight, host)
	changed := false
	if f.err == nil {
		changed = !sameStrings(dotBoot[host], f.addrs)
		dotBoot[host] = f.addrs
		dotBootAt[host] = time.Now()
	}
	dotMu.Unlock()
	close(f.done)
	if f.err == nil {
		saveDoTCache(host, f.bare)
		if changed {
			fmt.Fprintf(os.Stderr, "[resolver] DoT %s bootstrapped: %d address(es) via a plaintext lookup of the name (NWP-20260904-12)\n", host, len(f.addrs))
		}
	}
	return f.addrs, f.err
}

// bootstrapDoT is the plaintext A/AAAA lookup of the DoT hostname through the plain servers. Its failure text
// is address-free (describeBootstrapErr): it is what dotUnreachable prints to login.log.
func bootstrapDoT(ctx context.Context, host string, plain []string, d *net.Dialer) (addrs, bare []string, err error) {
	var (
		kindsMu   sync.Mutex
		dialKinds []string // every total dial failure, without addresses
	)
	r := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			c, err := dialPlain(ctx, network, plain, d)
			var pe *plainDialError
			if errors.As(err, &pe) {
				kindsMu.Lock()
				dialKinds = append(dialKinds, pe.kinds()...)
				kindsMu.Unlock()
			}
			return c, err
		},
	}
	ips, err := r.LookupIPAddr(ctx, host)
	if err != nil {
		kindsMu.Lock()
		defer kindsMu.Unlock()
		return nil, nil, errors.New("bootstrap: " + describeBootstrapErr(err, dialKinds))
	}
	bare = make([]string, 0, len(ips))
	for _, ip := range ips {
		bare = append(bare, ip.IP.String())
	}
	if addrs = dotEndpointsOf(bare); len(addrs) == 0 {
		return nil, nil, errors.New("bootstrap: no addresses")
	}
	return addrs, bare, nil
}

// sameStrings reports whether two lists hold the same entries in the same order.
func sameStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// setResolver routes all DNS through the given server addresses (host:port), tried in order until one
// connects. PreferGo forces the pure resolver (cgo is off anyway); the network arg (udp/tcp) is honored --
// only the server address is overridden.
func setResolver(addrs []string) {
	net.DefaultResolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			d := net.Dialer{Timeout: 5 * time.Second}
			var err error
			for _, a := range addrs {
				var c net.Conn
				if c, err = d.DialContext(ctx, network, a); err == nil {
					return c, nil
				}
			}
			if err == nil {
				err = errors.New("resolver: no dns servers configured")
			}
			return nil, err
		},
	}
}

// withPort53 ensures an address has a port, defaulting to 53.
func withPort53(s string) string {
	if _, _, err := net.SplitHostPort(s); err == nil {
		return s
	}
	return net.JoinHostPort(s, "53")
}

// hasResolvConf reports whether path declares at least one nameserver (an absent/empty file means Go's
// resolver has nothing to resolve with and would fall back to localhost).
func hasResolvConf(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if strings.HasPrefix(strings.TrimSpace(sc.Text()), "nameserver ") {
			return true
		}
	}
	return false
}

// pickDNS chooses nameserver IPs (IPv4 first, de-duped) from, in priority order: an explicit override, then
// Android system properties, then the ACTIVE DEFAULT network's own resolvers (defaultDNS -- reachable over the
// interface a resolver dial is pinned to), and only then the union of every network's DnsAddresses. A public
// resolver is the last resort so the agent still works if discovery yields nothing. Pure (no I/O), so the selection
// logic is unit-testable; the real getprop/dumpsys reads are injected by installResolver.
// pickDNS is discoveredDNS plus the cold-start public fallback, i.e. "give me something dialable no matter
// what". Kept for callers that have no cached list to fall back on; refreshNet deliberately does NOT use it
// (see dnsAdopt).
func pickDNS(override string, props []string, defaultDNS []string, dumpsysOut string) []string {
	if out := discoveredDNS(override, props, defaultDNS, dumpsysOut); len(out) > 0 {
		return out
	}
	return publicFallbackDNS()
}

// discoveredDNS returns ONLY nameservers actually discovered from this device -- an explicit override, then
// Android system properties, then the ACTIVE DEFAULT network's own resolvers, then the union of every
// network's DnsAddresses -- or nil when discovery found nothing. The absence of a fallback here is the point:
// the caller must be able to tell "found nothing" from "found the public list".
func discoveredDNS(override string, props []string, defaultDNS []string, dumpsysOut string) []string {
	return discoveredDNSExcluding(override, props, defaultDNS, dumpsysOut, nil)
}

// discoveredDNSExcluding is discoveredDNS with unionExclude kept out of the LAST tier only -- the union of every
// network's DnsAddresses. NWP-20260925-03: a split VPN's resolvers belong to that union but may answer only the
// VPN's own names; the default network's own resolvers, and props, are never filtered, so a physical resolver that
// happens to share an address with the VPN's is still used -- and dnsEgress sends it out the physical interface.
func discoveredDNSExcluding(override string, props []string, defaultDNS []string, dumpsysOut string, unionExclude []string) []string {
	var v4, v6 []string
	add := func(tok string) {
		tok = strings.TrimPrefix(strings.TrimSpace(tok), "/") // dumpsys prints addrs as "/1.2.3.4"
		ip := net.ParseIP(tok)
		if ip == nil {
			return
		}
		// Never adopt an fc00::/7 ULA resolver on the PHYSICAL path. A cellular/IMS PDN advertises a private
		// ULA DNS (fc00:a:a::400) reachable ONLY over that radio's IMS APN -- never over the validated default
		// iface a resolver dial SO_BINDTODEVICEs to -- so once the Wi-Fi default momentarily yields to cellular (or
		// the union path picks it up), pickDNS returns that lone fc00 v6 server and every subsequent lookup
		// ENETUNREACHes and the resolver wedges on it. Device-observed 2026-07-30: the agent's gateway
		// cap-refresh egressed on [fc00:a:a::400]:53 -> "network is unreachable", forcing a fall back / retry on
		// the reachable DNS. A REAL VPN's ULA resolver is legitimate but is set DIRECTLY by refreshNet's
		// parseVpnNetwork branch (which bypasses pickDNS), so dropping it here cannot break #159. Falls through
		// to a reachable v4 / the public fallback.
		if ip.To4() == nil && (ip[0]&0xfe) == 0xfc {
			return
		}
		if ip.To4() != nil {
			v4 = append(v4, tok)
		} else {
			v6 = append(v6, tok)
		}
	}
	addAll := func(s string) {
		for _, t := range strings.FieldsFunc(s, func(r rune) bool { return r == ',' || r == ' ' || r == '\t' || r == '\n' }) {
			add(t)
		}
	}
	addAll(override)
	if len(v4)+len(v6) == 0 {
		for _, p := range props {
			addAll(p)
		}
	}
	if len(v4)+len(v6) == 0 {
		// Prefer the ACTIVE DEFAULT network's OWN resolvers -- the same network{N} a resolver dial
		// SO_BINDTODEVICEs to -- so every server we dial is reachable over the interface we bind. A resolver
		// from a *different* up network (a private cellular DNS while Wi-Fi is default, an IMS fc00 link-local)
		// is unreachable once bound and only burns a dial timeout: the multi-network false-offline (#180). Fall
		// through to the all-networks union below only when the default block advertised no DnsAddresses.
		for _, s := range defaultDNS {
			add(s)
		}
	}
	if len(v4)+len(v6) == 0 {
		skip := map[string]bool{}
		for _, x := range unionExclude {
			skip[x] = true
		}
		for _, t := range parseDumpsysDNS(dumpsysOut) {
			if !skip[strings.TrimPrefix(strings.TrimSpace(t), "/")] {
				add(t)
			}
		}
	}
	// Prefer IPv4-ONLY when any v4 nameserver was found. On a multi-network device (two SIMs + Wi-Fi) the v6
	// nameservers routinely ENETUNREACH -- there are competing v6 default routes and the cgo-less agent's socket
	// isn't pinned to the validated network -- so keeping them just burns dial attempts on dead servers, and a
	// v6-primary lookup surfaces the v6 failure as the returned error. v4 (plain :53) is reachable over whatever
	// validated default route exists. Fall back to v6 only when NO v4 nameserver exists (a genuinely v6-only net).
	out := dedupeStr(v4)
	if len(out) == 0 {
		out = dedupeStr(v6)
	}
	return out
}

// publicFallbackDNS is the last-resort resolver list for a COLD START -- no override, no props, no network
// yet, and nothing cached. v4 first, then v6, so a single unreachable IP -- or an IPv6-primary network with no
// usable v4 default route -- can't kill DNS.
//
// NWP-20260822-04: this used to live INSIDE pickDNS, which made pickDNS incapable of returning empty -- and
// that silently disabled refreshNet's "a refresh that yields nothing keeps the last good list" rule, because
// its guard is `len(addrs) > 0`. See dnsAdopt.
func publicFallbackDNS() []string {
	return []string{"1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "2001:4860:4860::8888"}
}

// dnsAdopt decides what the cached resolver list becomes after a discovery pass, and is the fix for #64.
//
// THE BUG IT REPLACES: refreshNet has always read `if len(addrs) > 0 { dnsServers = addrs }`, and dnsAddrs
// documents the intent as "a refresh that yields nothing keeps the last good list rather than blanking it".
// But pickDNS appended a public fallback when discovery found nothing, so it NEVER returned empty, so that
// guard NEVER fired. A momentary empty discovery -- which is exactly what the user-switch window produces,
// where dumpsys reports no active default network at all (`[resolver] egress iface=""`) -- therefore REPLACED
// a perfectly good discovered list with the public one.
//
// Device-observed on lynx, one boot, both lines present:
//
//	[resolver] egress iface="wlan0" resolvers=[<net4>:53 <net4>:53]                               <- healthy
//	[resolver] egress iface="wlan0" resolvers=[1.1.1.1:53 8.8.8.8:53 [2606:...]:53 [2001:...]:53] <- clobbered
//
// (Captured as dns=[...] with the network's addresses; egressLine prints discovered servers as placeholders
// since NWP-20261011-36, and the public ones verbatim, so this contrast still reads.)
//
// ⚠ WHAT THIS DOES **NOT** CLAIM, because the first draft of this comment got it wrong. The captured error
// `dial udp [2001:4860:4860::8888]:53: connect: network is unreachable` does NOT show that the public v6
// entries caused anything: the dial loop tries EVERY server and returns the LAST error, so that address is
// merely the last entry of the fallback list. Its appearance proves all four failed, not that v6 was the
// problem. The clobber is real and worth fixing on its own merits -- discarding servers we proved reachable
// is wrong -- but it is NOT established as the cause of #64/#80, and this fix should not be read as closing
// them. See the backlog rows.
//
// The rule, in priority order: adopt what we just discovered; else KEEP what we already had; else -- and only
// then -- the public fallback, which is a cold-start bootstrap and not a substitute for a known-good list.
// Pure, so the decision is table-testable rather than buried in a lock section.
func dnsAdopt(discovered, cached, fallback []string) (out []string, usedFallback bool) {
	switch {
	case len(discovered) > 0:
		return discovered, false
	case len(cached) > 0:
		return cached, false // the good list survives a transient empty discovery -- the whole point
	default:
		return fallback, true
	}
}

// parseDumpsysDNS extracts DnsAddresses from EVERY network in `dumpsys connectivity`, formatted per network as:
//
//	DnsAddresses: [ /2001:4860:4860::8888,/192.0.2.53 ]
//
// A device commonly has several networks up at once -- e.g. an IMS-only cellular PDN whose DNS is a private
// link-local resolver reachable ONLY over that radio, alongside the validated Wi-Fi. Taking just the first
// network (the dump often lists cellular first) picked that unreachable IMS DNS and broke every lookup. We
// collect ALL of them and let pickDNS's IPv4-first ordering try the reachable general resolver first.
func parseDumpsysDNS(s string) []string {
	var out []string
	const key = "DnsAddresses:"
	for {
		i := strings.Index(s, key)
		if i < 0 {
			break
		}
		s = s[i+len(key):] // always advance past this occurrence, so a malformed block can't loop forever
		l := strings.IndexByte(s, '[')
		r := strings.IndexByte(s, ']')
		if l < 0 || r < 0 || r <= l {
			continue
		}
		out = append(out, strings.FieldsFunc(s[l+1:r], func(c rune) bool { return c == ',' || c == ' ' || c == '\t' })...)
		s = s[r+1:]
	}
	return out
}

func dedupeStr(in []string) []string {
	seen := map[string]bool{}
	out := in[:0:0]
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// getpropMulti reads several Android system properties, dropping empty/missing ones.
func getpropMulti(names ...string) []string {
	out := make([]string, 0, len(names))
	for _, n := range names {
		if v := getprop(n); v != "" {
			out = append(out, v)
		}
	}
	return out
}

func getprop(name string) string {
	b, err := exec.Command("getprop", name).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// dumpsysConnectivity reads the connectivity service's dump. A variable so a test can feed refreshNet a
// captured dump instead of exec'ing dumpsys.
var dumpsysConnectivity = func() string {
	b, err := exec.Command("dumpsys", "connectivity").Output()
	if err != nil {
		return ""
	}
	return string(b)
}
