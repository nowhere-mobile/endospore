package main

import "testing"

// TestConcurrentSafeCmd pins the #197-hardening invariant: only pure-read probes may run outside sessionMu. The
// telephony verbs (SEAL-TEL/SEAL-MMS/GET-TELINGEST/ACK-TELINGEST/RESTAGE-TELINGEST) never reach concurrentSafeCmd:
// since NWP-20260927-09 handleLogin dispatches them to handleTelCmd first, under telMu, and
// TestTelVerbsNeverWaitForSessionMu is what guards that dispatch. They stay in mustSerialize as defence in depth
// only: they WRITE under $NOWHERE_STATE, so if that dispatch were ever removed they must fall back to sessionMu,
// never run free.
func TestConcurrentSafeCmd(t *testing.T) {
	// Writers + anything unrecognized (an unknown command falls through to the legacy login, which wipes the
	// session state dir -- wipeSessionState).
	mustSerialize := []string{
		"SEAL-TEL", "SEAL-MMS", "GET-TELINGEST", "ACK-TELINGEST", "RESTAGE-TELINGEST",
		// SET-BINDING/DELETE-BINDING write bindings.conf: they answer BUSY from the TryLock set, never run free.
		"LOGIN", "LOGOFF", "GET-GATE-ALARM", "SET-BINDING", "DELETE-BINDING", "EVICT-RECHECK-SAVED", "",
	}
	for _, c := range mustSerialize {
		if concurrentSafeCmd(c) {
			t.Errorf("%q must serialize (writes the state dir or is unrecognized), got concurrent-safe", c)
		}
	}
	// Pure reads: stat/read only, race-tolerant, keep the gate responsive while a writer holds sessionMu.
	// GET-SESSION-TYPE/GET-OFFLINE: the Profile screen's pre-draw probes -- serialized they blank the screen
	// for a whole materialise download (odtest4 2026-07-28).
	mayRunFree := []string{"STATUS", "GET-SEAL-BLIND", "GET-COLDLOCK", "OTA-STATUS", "OTA-VERSIONS", "OTA-REFRESH", "GET-OTA-AUTO",
		"GET-SESSION-TYPE", "GET-OFFLINE",
		// NWP-20260901-25 (#145 S1): pure reads of pendingReapMu/sealMu state + one tmpfs file. Serialized,
		// a progress poll during a login or materialise froze the very bar it was feeding.
		"SEAL-STATUS", "GET-SYNC-STATUS", "GET-SWEEP", "AUTO-SWEEP", "AUTO-SWEEP-APP",
		"PLACEHOLDER-OUTCOMES", // NWP-20261127-08: a sign-in sends it while it holds sessionMu
		"TELINGEST-SEEN",       // NWP-20261129-02: a session whose seals hold sessionMu for minutes sends it
		// NWP-20261117-27: one atomic read; a materialise or a sign-in holds sessionMu for minutes.
		"GET-SEAL-LANDED",
		"COLD-LOCK-STATUS",     // NWP-20261005-09: explains a lock queued behind a seal, which holds sessionMu
		"GET-COLDLOCK-PENDING", // NWP-20261022-25: asked at the sign-in tap, while a prefix or a materialise holds sessionMu
		// NWP-20261005-10: the keyguard armer's calls; serialised they timed out behind the AUTO sweep.
		"GET-SESSION-PIN", "ARM-PIN",
		// NWP-20261011-05: "Sign out & install" sends its request the moment before LOGOUT, when a seal may hold sessionMu.
		"OTA-AFTER-LOGOFF", "OTA-APPLY-AFTER-LOGOFF",
		// NWP-20261011-05: asked right after a reap, while CLEAN-STORAGE holds sessionMu; a timed-out read still consumed the creds.
		"GET-RELOGIN",
		// NWP-20261007-06: a writer, under its own gateAlarmMu -- see concurrentSafeCmd. Serialised, the relay sent
		// at logoff and cold lock timed out behind a seal and the alarm never rang.
		"SET-GATE-ALARM",
		// NWP-20261011-43: pure reads of bindings.conf, published by rename. Serialized, the SIM lines screen and the
		// sign-in outbound verdict waited behind a materialise or a clean-up (20.8 s on lynx 2026092402).
		"GET-BINDINGS", "TEL-OWNER", "TEL-OWNED-ICCIDS", "TEL-OWNED-LABELS",
		// NWP-20261011-43: the Bind button's first call, a pure store read; serialized, a Bind never reached SET-BINDING's BUSY.
		"GET-TELPUB",
		// NWP-20261013-20: the gate's lost-credit notice, asked right after a reap, under its own creditLostMu.
		"GET-CREDIT-LOST", "CLEAR-CREDIT-LOST",
		// NWP-20261019-11: two pure computations, and the sync cadence's device-level read and write (own mutex).
		"CHECK-PASSPHRASE", "GEN-PASSPHRASE", "GET-SYNC-INTERVAL", "SET-SYNC-INTERVAL",
		// NWP-20261021-07: the automatic-install and caller's-number switches and the install time -- one device-level
		// file each, published by rename under deviceFlagMu.
		"GET-OTA-TIME", "SET-OTA-AUTO", "SET-OTA-TIME", "GET-NOTICE-NUMBER", "SET-NOTICE-NUMBER",
		// NWP-20261016-45: the Location services switch -- the SET-SEAL-HOLD case; its one write is roamd's, ordered by
		// the RW slot and re-checked under it (locClaimRefusal).
		"APPLY-LOCATION",
		// NWP-20261026-06: the Mobile data switch, for the same reason.
		"APPLY-MOBILE-DATA",
		// NWP-20261016-47: asked at the sign-in tap over a parked session, a pure read; serialized, the tap would wait
		// behind the gate's orphan-sweep clean-up.
		"GET-PARKED-CREDIT",
		// NWP-20261020-31: a count the gate has measured (the GATE-TIMING case), sent while CLEAN-STORAGE may hold sessionMu.
		"WIFI-ADOPT",
		// NWP-20261106-07 (Q065): the gate's shown-failure record, a writer under its own mutex, sent while a stalled sign-in may hold sessionMu.
		"SIGNIN-SHOWN",
		// NWP-20261114-13: the first-run agreement screen's ring probe, a pure os.Getenv read (the GET-STOREFRONT case).
		"GET-OS-AGREEMENT",
		// NWP-20261114-16: asked at the tap; a head read, nothing written (the SEAL-DELTA case).
		"APP-FETCH-SIZE",
		// NWP-20261118-11: asked before the switch, while GRANT-PERMS can hold sessionMu for the grant op.
		"GET-PREFS",
		// NWP-20261117-23: the gate's media and prefetch polls, each a read of one RAM file published by rename.
		"GET-MEDIA-STATUS", "GET-MEDIA-APP-PROGRESS", "GET-PREFETCH-METERED",
		// NWP-20261118-06: the kept storage count; a RAM read and a goSafe start.
		"STORAGE-COUNT-START", "GET-STORAGE-BREAKDOWN-CACHED",
		// NWP-20261125-15: one RAM phase under pendingReapMu; the gate calls it while a DELETE may hold sessionMu.
		"RERUN-REAP"}
	for _, c := range mayRunFree {
		if !concurrentSafeCmd(c) {
			t.Errorf("%q is a pure read and should run outside sessionMu, got serialized", c)
		}
	}
}
