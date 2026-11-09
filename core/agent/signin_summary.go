package main

// NWP-20261122-09: A SIGN-IN'S RESTORE AND PARKED SUMMARY AS ISSUE-REPORT STATUS KEYS.
//
// The backlog row "An issue report's logs sections keep only the last 299 lines of each log, so a sign-in's own
// summary lines ... roll out under the Auto sweep's per-app lines before the report is sent": the `restore:` line,
// the Q106 share line (mediaUserShareLine) and od_parked_report's "IN parked data of ..." line go only to the logs,
// and after a long Auto sweep the report's trimmed tail no longer holds them. Status keys are never trimmed.
//
// So the `in` op writes them a second time, to $STATE/signin-summary.<uid> (the state tmpfs). The `in` arm exports
// NOWHERE_SIGNIN_SUMMARY for that uid only; every sign-in is a new user, so a refused or later attempt writes
// another uid's file and never touches a live or parked session's. Three writers append, one line each:
//
//	v=1 scope=<vault|de|media|apps|sys> ms=<n> chunks=<n> cached=<n> fetched=<n> heal_ms=<n> store_reads=<n> cap_calls=<n>
//	    (scope=media only) ... user_files=<n> user_bytes=<n> other_files=<n> other_bytes=<n>, or ... indexed=0   signinSummaryAppend
//	v=1 parked apps=<n> ce_kib=<n> de_kib=<n>, or v=1 parked apps=<n> size=unknown   od_parked_report (roamd)
//	v=1 phase=<in|reap|reown|acct> ms=<n>                                            _ssum (roamd)
//
// The scope line's fields are mandatory: the file is on the tmpfs, so the image that reads it is the image that wrote it.
//
// An in-session report reads the file of ITS session's uid into these keys, digits only:
//
//	signin_<scope>_ms        "<n>" the restore's restore=<n>ms LESS its heal, for scope vault, de, media, apps or sys
//	signin_<scope>_chunks    "<n>" the head's chunk count
//	signin_<scope>_cached    "<n>" chunks read from the chunk cache
//	signin_<scope>_fetched   "<n>" chunks fetched from the store
//	signin_<scope>_store_reads "<n>" store object reads of that whole restore process, head and retries included
//	signin_<scope>_cap_calls "<n>" gateway cap round trips of that whole restore process, single and batch
//	signin_heal_ms           "<n>" the heal's time, summed over the scopes (the vault and #de heal; any scope line gives it)
//	signin_media_user_files  "<n>" Q106 user-media essential files (mediaUserShare)
//	signin_media_user_bytes  "<n>" their plaintext bytes
//	signin_media_other_files "<n>" the other essential files
//	signin_media_other_bytes "<n>" their plaintext bytes
//	signin_media_indexed     "1" the head carries the per-file index, "0" it does not
//	signin_parked_apps       "<n>" On-demand/Auto apps whose data the restores fetched only to park
//	signin_parked_ce_kib     "<n>" their CE size (absent when du gave no size)
//	signin_parked_de_kib     "<n>" their DE size (likewise)
//	signin_in_ms             "<n>" this roamd run from its start to the `in` arm's OK reply (no key on a sign-in that did not land)
//	signin_reap_ms           "<n>" reap_retry_run and userdir_recheck before the arm, plus reap_stale_ondemand and reap_orphan_provisioned
//	signin_reown_ms          "<n>" the reown and relabel of the CE and #de trees and the #media tail, added
//	signin_acct_ms           "<n>" acct_restore, which holds the #sys restore
//
// NWP-20261130-08 (backlog: The sign-in summary still cannot say where a fifth of op=in goes): the keys account for the op:
//
//	signin_in_ms = vault_ms + heal_ms + de_ms + media_ms + apps_ms + reown_ms + acct_ms + reap_ms + the rest
//
// signin_sys_ms is NOT in that sum, because it is inside signin_acct_ms. The rest is not timed: each restore's head and
// key resolution, keystore_restore, hold_ondemand and the small steps of the arm.
//
// A missing file gives no keys. Any other read error, an oversized file or ANY line of another shape gives
// signin_summary=unreadable alone. It never copies any other text: no profile name, no path, no package.
// Diagnostics only: nothing about what is restored, or when, changes.

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
)

// signinSummaryPrefix names a sign-in's file in the state tmpfs: signin-summary.<uid>.
const signinSummaryPrefix = "signin-summary."

// signinSummaryMaxBytes bounds what a report reads of the file. The thirteen lines a sign-in writes (five scopes, parked,
// three reown, two reap and the other two phases) fit at their widest (TestSigninSummaryWidestFits).
const signinSummaryMaxBytes = 4096

// signinSummaryScope is the CLOSED map from the roam worker's NOWHERE_PHASE to a scope word. Any other phase writes
// nothing.
var signinSummaryScope = map[string]string{
	"apps":     "vault",
	"secure":   "de",
	"media":    "media",
	"appcode":  "apps",
	"accounts": "sys",
}

// signinSummaryScopeRe, signinSummaryParkedRe and signinSummaryPhaseRe are the file's only accepted line shapes.
var signinSummaryScopeRe = regexp.MustCompile(`^v=1 scope=(vault|de|media|apps|sys) ms=([0-9]{1,12}) chunks=([0-9]{1,12}) cached=([0-9]{1,12}) fetched=([0-9]{1,12}) heal_ms=([0-9]{1,12}) store_reads=([0-9]{1,12}) cap_calls=([0-9]{1,12})(?: user_files=([0-9]{1,12}) user_bytes=([0-9]{1,15}) other_files=([0-9]{1,12}) other_bytes=([0-9]{1,15})| (indexed=0))?$`)
var signinSummaryParkedRe = regexp.MustCompile(`^v=1 parked apps=([0-9]{1,9})(?: ce_kib=([0-9]{1,12}) de_kib=([0-9]{1,12})| (size=unknown))$`)
var signinSummaryPhaseRe = regexp.MustCompile(`^v=1 phase=(in|reap|reown|acct) ms=([0-9]{1,12})$`)

// signinSummaryAppend appends this restore's summary line to NOWHERE_SIGNIN_SUMMARY, called once in the restore
// verb's CDC branch, after its `restore:` line. restMs holds healMs, so ms takes it out and heal_ms carries it: a heal
// must count once in the sum the file header states. Every error is ignored: a diagnostic never fails a restore.
func signinSummaryAppend(m chunkManifest, restMs, healMs int64) {
	path := os.Getenv("NOWHERE_SIGNIN_SUMMARY")
	if path == "" || !filepath.IsAbs(path) {
		return
	}
	word, ok := signinSummaryScope[os.Getenv("NOWHERE_PHASE")] // a scope word, never a profile name
	if !ok {
		return
	}
	ms := restMs - healMs
	if ms < 0 { // a negative value would make the reader refuse the whole file
		ms = 0
	}
	line := fmt.Sprintf("v=1 scope=%s ms=%d chunks=%d cached=%d fetched=%d heal_ms=%d store_reads=%d cap_calls=%d", word, ms, len(m.Chunks),
		atomic.LoadInt64(&chunkHits), atomic.LoadInt64(&chunkMiss), healMs, atomic.LoadInt64(&traceGetN), atomic.LoadInt64(&traceCapN))
	if word == "media" {
		if uf, ub, of, ob, indexed := mediaUserShare(m); indexed {
			line += fmt.Sprintf(" user_files=%d user_bytes=%d other_files=%d other_bytes=%d", uf, ub, of, ob)
		} else {
			line += " indexed=0"
		}
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return
	}
	_, _ = f.Write([]byte(line + "\n"))
	_ = f.Close()
}

// signinSummaryStatus renders a sign-in's summary file as the status keys the file header lists.
func signinSummaryStatus(path string) map[string]string {
	unreadable := map[string]string{"signin_summary": "unreadable"}
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]string{}
	}
	if err != nil {
		return unreadable
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, signinSummaryMaxBytes+1))
	if err != nil || len(b) > signinSummaryMaxBytes {
		return unreadable
	}
	out := map[string]string{}
	if len(b) == 0 {
		return out
	}
	heal := map[string]int64{}  // per scope: a later line of a scope replaces its earlier one, as every other key does
	phase := map[string]int64{} // per word: the reown lines add
	for _, l := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
		if m := signinSummaryScopeRe.FindStringSubmatch(l); m != nil {
			s := m[1]
			if (s == "media") != (m[9] != "" || m[13] != "") {
				return unreadable // the share extras or indexed=0 belong to, and are required on, the media line only
			}
			out["signin_"+s+"_ms"], out["signin_"+s+"_chunks"] = m[2], m[3]
			out["signin_"+s+"_cached"], out["signin_"+s+"_fetched"] = m[4], m[5]
			out["signin_"+s+"_store_reads"], out["signin_"+s+"_cap_calls"] = m[7], m[8]
			heal[s], _ = strconv.ParseInt(m[6], 10, 64) // at most 12 digits, so it cannot fail
			if s != "media" {
				continue
			}
			// A later media line replaces the earlier one whole, so the keys always describe one line.
			for _, k := range []string{"user_files", "user_bytes", "other_files", "other_bytes", "indexed"} {
				delete(out, "signin_media_"+k)
			}
			if m[9] != "" {
				out["signin_media_user_files"], out["signin_media_user_bytes"] = m[9], m[10]
				out["signin_media_other_files"], out["signin_media_other_bytes"] = m[11], m[12]
				out["signin_media_indexed"] = "1"
			} else {
				out["signin_media_indexed"] = "0"
			}
			continue
		}
		if m := signinSummaryParkedRe.FindStringSubmatch(l); m != nil {
			delete(out, "signin_parked_ce_kib")
			delete(out, "signin_parked_de_kib")
			out["signin_parked_apps"] = m[1]
			if m[4] == "" {
				out["signin_parked_ce_kib"], out["signin_parked_de_kib"] = m[2], m[3]
			}
			continue
		}
		if m := signinSummaryPhaseRe.FindStringSubmatch(l); m != nil {
			n, _ := strconv.ParseInt(m[2], 10, 64) // at most 12 digits, so it cannot fail
			phase[m[1]] += n
			continue
		}
		return unreadable
	}
	if len(heal) > 0 {
		var sum int64
		for _, n := range heal {
			sum += n
		}
		out["signin_heal_ms"] = strconv.FormatInt(sum, 10)
	}
	for w, n := range phase {
		out["signin_"+w+"_ms"] = strconv.FormatInt(n, 10)
	}
	return out
}

// mergeSigninSummary adds the summary of the session's own sign-in (uid) to an in-session report's status, after
// buildIssueReportWith (so outside its size trim: about 2 KiB at most). It deletes every caller-sent signin_* key
// first, so only this file can set one. Never at device scope: a gate report carries no sign-in's numbers.
func mergeSigninSummary(status map[string]string, uid string, deviceScope bool) {
	if deviceScope || status == nil || uid == "" || strings.Trim(uid, "0123456789") != "" {
		return
	}
	for k := range status {
		if strings.HasPrefix(k, "signin_") {
			delete(status, k)
		}
	}
	for k, v := range signinSummaryStatus(filepath.Join(loginStateDir(), signinSummaryPrefix+uid)) {
		status[k] = v
	}
}
