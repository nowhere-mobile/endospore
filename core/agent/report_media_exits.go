package main

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

// NWP-20261208-06: why this session's media service (MediaProvider) exited, from the framework's own record
// (ApplicationExitInfo), for an in-session issue report. Evidence for the backlog row "In a long session the
// alarm-clock app's list and the photo gallery read empty for minutes although the data is there": media_probe says
// whether the provider answers now, this says why it stopped. A provider that crashed and restarted shows a crash
// reason; one restarted by the MEDIA-RESTART Fix (media_restart.go, `am force-stop`) shows USER_REQUESTED and
// FORCE_STOP; one that hung shows no fresh record at all. No rule, no notice, no fix.
//
// PRIVACY: as gmsexits (report_gms_exits.go). Session scope only; only the two fixed media module names, both under
// the one label `media`; only this session's user; only records younger than this session. The description, trace,
// memory and state fields are never read. roamd's `mediaexits` op (read-only lane) pipes one dump per module name into
// `nowhere_agent mediaexits <uid>`, which keeps the words and the digits and nothing else.

// mediaExitLabels holds the only two processes a report may name, both as one label: the AOSP module name (GrapheneOS)
// and the Google module name.
var mediaExitLabels = map[string]string{
	"com.android.providers.media.module":        "media",
	"com.google.android.providers.media.module": "media",
}

// mediaExitLineRe is the fixed shape of one media_exit_<n> value; the cap and the words are gmsexits's.
var mediaExitLineRe = regexp.MustCompile(`^media reason=(?:[A-Z_]{1,40}|unparsed) sub=(?:[A-Z_]{1,40}|unparsed) imp=\d{1,9} age_s=(\d{1,12})$`)

// mediaExitsWait bounds how long a report waits for the worker: a wedged worker costs one honest key, never the report.
var mediaExitsWait = 15 * time.Second

// mediaExitsWorker is the read-only-lane request; a var so that a test can stand in for the lane. Never a passphrase.
var mediaExitsWorker = func(dest, name, uid string) string {
	return triggerRoamWorker(dest, "mediaexits", name, "", uid, "", nil)
}

// fetchMediaExits asks the worker for this session's records. The op runs on in its goroutine if the wait expires; it
// only reads, and the lane's own slot keeps it from piling up.
func fetchMediaExits(dest, name, uid string) string {
	if uid == "" || strings.Trim(uid, "0123456789") != "" {
		return ""
	}
	ch := make(chan string, 1)
	goSafe("mediaexits", func() { ch <- mediaExitsWorker(dest, name, uid) })
	select {
	case r := <-ch:
		return r
	case <-time.After(mediaExitsWait):
		return fmt.Sprintf("ERR-TIMEOUT the worker did not answer within %s", mediaExitsWait)
	}
}

// mergeMediaExits adds the media_exits and media_exit_<n> keys to an in-session report's status (mergeExitInfo says
// how). A device-scope report carries none and loses any caller-sent one.
func mergeMediaExits(status map[string]string, fetch func() string, dest string, deviceScope bool) {
	mergeExitInfo(status, "media_exit", mediaExitLineRe, fetch, dest, deviceScope)
}
