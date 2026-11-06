package main

import "fmt"

// otaVersionsLine is the OTA-VERSIONS reply (NWP-20261019-12). The first eight fields are the fielded shape,
// `running X checked N lasterr E store S`, in that order and spelling: the chooser and any older parser scan the line
// as key/value pairs. Two keys follow them:
//
//	tried_ms    when the last store check FINISHED, success or not, in unix milliseconds (-1 = never tried)
//	refreshing  1 while a refresh is in flight (its notes and mandatory-metadata fetches included), else 0
//
// They are what a waiter needs and OTA-REFRESH cannot give: every OTA-REFRESH call starts a refresh when none is in
// flight, so polling that verb would start a store check per poll. A tap on "Check for updates" instead sends
// OTA-REFRESH once and watches these two keys for an attempt that finished after the tap.
//
// Memory only: no network I/O, and the lock is released before the reply is written.
func otaVersionsLine(running string) string {
	checked, lastErr, triedMs, refreshing := int64(-1), "none", int64(-1), 0
	otaCacheMu.Lock()
	if !otaCacheAt.IsZero() {
		checked = otaCacheAt.Unix()
	}
	if otaLastErr != "" {
		lastErr = otaLastErr
	}
	if !otaLastTry.IsZero() {
		triedMs = otaLastTry.UnixMilli()
	}
	if otaRefreshing {
		refreshing = 1
	}
	otaCacheMu.Unlock()
	store := "no"
	if storeConfigured() {
		store = "yes"
	}
	return fmt.Sprintf("running %s checked %d lasterr %s store %s tried_ms %d refreshing %d\n",
		running, checked, lastErr, store, triedMs, refreshing)
}
