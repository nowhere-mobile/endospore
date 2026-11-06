package main

import (
	"os"
	"path/filepath"
	"time"
)

// NWP-20261107-12 (Q037, dn-1104 #2, 2026-10-21): the re-check timer. A reap whose user record never goes, or cannot
// be seen, keeps that user's /data/system/users/<uid> (cleartext, settings_ssaid.xml included) and queues the uid in
// roamd's $STATE/userdir-pending. roamd re-checks the queue before every read-write-lane op; with no sign-in or
// sign-out after the reap nothing runs, so every userdirRecheckEvery the daemon sends the credless `userdirrecheck` op
// -- ONLY while that file is non-empty. An idle phone with nothing queued runs no worker op at all. The tick stats the
// file and never reads it: its content is roamd's. A Go timer does not wake a suspended phone: a power-off or a sleep
// before the tick leaves the folder to the next read-write op or the boot, as before. The op's wait is capped at 30 s
// (workerWaitCap): on a busy lane the tick gives up, and the next read-write op re-checks anyway.
// Started only through goSafeLoop in loginDaemon.
const userdirRecheckEvery = 5 * time.Minute

// userdirRecheckEnabled lets the package's tests keep a stray tick off the RW lane (failed_signin_scrub_hook_test.go).
var userdirRecheckEnabled = true

// userdirRecheckSleep is the loop's wait; tests replace it.
var userdirRecheckSleep = time.Sleep

// userdirRecheckTick sends one `userdirrecheck` when a uid is queued, and reports whether it sent one. The daemon sends
// no name and uid 0: the op is credless and sits before roamd's name/uid guard.
func userdirRecheckTick(dest string) bool {
	if !userdirRecheckEnabled {
		return false
	}
	fi, err := os.Stat(filepath.Join(dest, "userdir-pending"))
	if err != nil || !fi.Mode().IsRegular() || fi.Size() == 0 {
		return false
	}
	triggerRoamWorker(dest, "userdirrecheck", "x", "", "0", "", nil)
	return true
}

func userdirRecheckLoop(dest string) {
	for {
		userdirRecheckSleep(userdirRecheckEvery)
		userdirRecheckTick(dest)
	}
}
