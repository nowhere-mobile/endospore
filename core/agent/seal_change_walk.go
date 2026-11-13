package main

// NWP-20261202-06: the change mode of sealdeltawalk, the input of the h62 #4 change test (decision 2026-11-09 item
// 4, option A, as amended 2026-11-10: the periodic save runs every N minutes and a test decides if it seals). The
// daemon gate (M07ab) asks `sealdeltawalk <uid> "<since> change"`, with since the announce stamp of the last seal
// that landed, and seals when any count below is non-zero, or at its 60-minute floor.
//
// Change mode is the plain walk (rules A and B, the deletion pass, the seal's skipped dirs) plus four rules:
//
//	the directory rule: a walked dir whose own mtime is at or after since counts in changedDirs. It catches a
//	        small file created, deleted or renamed, which rule B and the listed deletion pass miss.
//	the save's own writes: the out op rewrites its captures, the claims list and the media-scan list under the
//	        vault AFTER its announce, at every seal. Rule B skips exactly those files (sealChangeSelfWritten) and
//	        counts them in selfSkipped; the directory rule skips only their dir. Without this every cycle reads
//	        as changed. Every other file in that dir (the chooser's own roamed choices) still counts.
//	state files: the files Android writes for an account, settings, Bluetooth, sync or package event, which the
//	        captures, acct_seal and appcode_seal read outside the three walk roots (stateChanged).
//	app code: /data/app and each direct child; an install, update or uninstall creates or removes one
//	        (appsChanged).
//
// It over-counts by design (a touched-but-unchanged file, a dir whose mtime moved, a state file Android rewrote
// for its own reasons): every error is toward "save". It reads no file content, only stats and dir lists. A path
// it cannot stat counts in blind, and the gate saves on blind; so a state path is listed only where an endospore.te
// allow lets endospore_priv stat its dir. The time zone (/data/property/persistent_properties, property_data_file,
// no allow) is therefore NOT an input: a zone change waits for the 60-minute floor. #keys is not sealed by a
// periodic save, so the keystore is no input either; the wallet is the gate's own dirty mark.

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// sealChangeSelfDir is the vault rel of the dir the out op writes into: the chooser's files dir.
const sealChangeSelfDir = "com.nowhere.chooser/files"

// sealChangeSelfWritten lists every file the out op itself writes under the walk roots between its announce and its
// verdict, as vault rels. Each is derived from its writer in nowhere_roamd.sh (TestSealChangeWalkP1 pins a writer
// for every entry). Exact names only: never a prefix of the whole dir.
var sealChangeSelfWritten = []string{
	sealChangeSelfDir + "/nowhere-nav", // nav_seal_capture
	sealChangeSelfDir + "/nowhere-nav.tmp",
	sealChangeSelfDir + "/nowhere-aod", // aod_seal_capture
	sealChangeSelfDir + "/nowhere-aod.tmp",
	sealChangeSelfDir + "/nowhere-a11y", // a11y_seal_capture
	sealChangeSelfDir + "/nowhere-a11y.tmp",
	sealChangeSelfDir + "/nowhere-autofill", // autofill_seal_capture
	sealChangeSelfDir + "/nowhere-autofill.tmp",
	sealChangeSelfDir + "/nowhere-lasttz", // tz_seal_capture
	sealChangeSelfDir + "/nowhere-lasttz.tmp",
	sealChangeSelfDir + "/nowhere-vpn", // vpn_seal_capture
	sealChangeSelfDir + "/nowhere-vpn.tmp",
	sealChangeSelfDir + "/nowhere-sync", // sync_seal_capture
	sealChangeSelfDir + "/nowhere-sync.tmp",
	sealChangeSelfDir + "/nowhere-sync.raw",
	sealChangeSelfDir + "/nowhere-sync-in.tmp",
	sealChangeSelfDir + "/nowhere-sync-pending", // sync_take_pend, sync_keep_lines
	sealChangeSelfDir + "/nowhere-sync-pending.tmp",
	sealChangeSelfDir + "/nowhere-sync-pending.new",
	sealChangeSelfDir + "/nowhere-sync-apply.tmp", // sync_apply_retry -> sync_apply_once
	sealChangeSelfDir + "/nowhere-sync-retry",     // sync_keep_lines
	sealChangeSelfDir + "/nowhere-sync-retry.tmp",
	sealChangeSelfDir + "/nowhere-settings-roam", // sroam_seal_capture
	sealChangeSelfDir + "/nowhere-settings-roam.tmp",
	sealChangeSelfDir + "/nowhere-claims", // the vault push (CLAIMSOUT, writeClaimsToNamed)
	sealChangeSelfDir + "/nowhere-claims.tmp",
	sealChangeSelfDir + "/nowhere-mediascan.list", // the out arm's _msdst
}

// sealChangeSelfWrittenPrefixes are bt_seal_capture's per-file outputs (bt-bond-<file>, bt-name-<id>-<key>, each
// with its .tmp). A prefix matches a file directly in sealChangeSelfDir only.
var sealChangeSelfWrittenPrefixes = []string{
	sealChangeSelfDir + "/bt-bond-",
	sealChangeSelfDir + "/bt-name-",
}

// sealChangeIsSelf reports whether a walked file is one the out op itself writes.
func sealChangeIsSelf(scope, rel string) bool {
	if scope != "vault" {
		return false
	}
	for _, s := range sealChangeSelfWritten {
		if rel == s {
			return true
		}
	}
	for _, p := range sealChangeSelfWrittenPrefixes {
		if strings.HasPrefix(rel, p) && !strings.Contains(rel[len(p):], "/") {
			return true
		}
	}
	return false
}

// sealChangeStatePaths lists the state files of the events the change test must see, outside the walk roots. A path
// is here only if a capture, acct_seal or appcode_seal reads it or Android writes it for that event, AND an
// endospore.te allow lets endospore_priv stat its dir (system_data_file, bluetooth_data_file): a refused stat would
// be blind on every walk. A var so tests point it at a temp dir.
var sealChangeStatePaths = func(uid string) []string {
	return []string{
		"/data/system_ce/" + uid + "/accounts_ce.db", // acct_seal (#sys): an account added, removed or changed
		"/data/system_ce/" + uid + "/accounts_ce.db-wal",
		"/data/system_de/" + uid + "/accounts_de.db",
		"/data/system_de/" + uid + "/accounts_de.db-wal",
		"/data/system/users/" + uid + "/settings_secure.xml", // nav, aod, a11y, autofill, VPN, settings-roam
		"/data/system/users/" + uid + "/settings_system.xml", // settings-roam's system rows
		"/data/system/users/0/settings_global.xml",           // settings-roam's global rows
		"/data/misc/bluedroid/bt_config.conf",                // bt_seal_capture (BT_FILES)
		"/data/misc/bluedroid/bt_remote_dev_info.conf",
		"/data/system/sync/accounts.xml", // sync_seal_capture: the account sync switches
		"/data/system/packages.xml",      // appcode_seal (#apps): an install, update or uninstall
	}
}

// sealChangeAppDir is where installed app code lives (a var for tests).
var sealChangeAppDir = "/data/app"

type sealChangeCounts struct {
	ChangedDirs  int64
	StateChanged int64
	AppsChanged  int64
	SelfSkipped  int64
}

// sealChangeWalkOut is change mode's JSON: every sealDeltaWalkOut field first, then the change counts. The daemon
// gate (M07ab) parses these key names; keep them byte-exact.
type sealChangeWalkOut struct {
	sealDeltaWalkOut
	Mode         string `json:"mode"`
	ChangedDirs  int64  `json:"changedDirs"`
	StateChanged int64  `json:"stateChanged"`
	AppsChanged  int64  `json:"appsChanged"`
	SelfSkipped  int64  `json:"selfSkipped"`
}

// sealChangeStateCount stats each state path: an mtime at or after since is a change, an absent file is nothing
// (that event never happened on this phone), any other error is blind.
func sealChangeStateCount(paths []string, since int64) (changed, blind int64) {
	for _, p := range paths {
		fi, err := os.Stat(p)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			blind++
			continue
		}
		if fi.ModTime().Unix() >= since {
			changed++
		}
	}
	return changed, blind
}

// sealChangeAppCount stats the app dir and each direct child: an mtime at or after since is a change. An absent
// dir is nothing; any other error is blind.
func sealChangeAppCount(dir string, since int64) (changed, blind int64) {
	fi, err := os.Stat(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return 0, 0
	}
	if err != nil {
		return 0, 1
	}
	if fi.ModTime().Unix() >= since {
		changed++
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return changed, blind + 1
	}
	for _, e := range ents {
		ci, err := os.Lstat(filepath.Join(dir, e.Name()))
		if err != nil {
			if !errors.Is(err, fs.ErrNotExist) {
				blind++
			}
			continue
		}
		if ci.ModTime().Unix() >= since {
			changed++
		}
	}
	return changed, blind
}

// sealChangeParse reads the since argument. Exactly two fields, the second "change" and the first > 0, select
// change mode. Anything else is the plain mode with its old parse, byte for byte.
func sealChangeParse(sinceArg string) (since int64, change bool) {
	if f := strings.Fields(sinceArg); len(f) == 2 && f[1] == "change" {
		if n, err := strconv.ParseInt(f[0], 10, 64); err == nil && n > 0 {
			return n, true
		}
	}
	since, _ = strconv.ParseInt(strings.TrimSpace(sinceArg), 10, 64)
	return since, false
}

// sealDeltaWalkJSON is the walk's one-line answer for either mode. A marshal error answers {}.
func sealDeltaWalkJSON(uid, sinceArg string, roots, unders map[string]string, idx map[string]sealDeltaIdxEnt, listed map[string]int64) []byte {
	since, change := sealChangeParse(sinceArg)
	var b []byte
	var err error
	if !change {
		b, err = json.Marshal(sealDeltaWalk(roots, unders, idx, listed, since))
	} else {
		w, cc := sealDeltaWalkMode(roots, unders, idx, listed, since, true)
		out := sealChangeWalkOut{sealDeltaWalkOut: w, Mode: "change", ChangedDirs: cc.ChangedDirs, SelfSkipped: cc.SelfSkipped}
		var blind int64
		out.StateChanged, blind = sealChangeStateCount(sealChangeStatePaths(uid), since)
		out.Blind += blind
		out.AppsChanged, blind = sealChangeAppCount(sealChangeAppDir, since)
		out.Blind += blind
		b, err = json.Marshal(out)
	}
	if err != nil {
		return []byte("{}")
	}
	return b
}
