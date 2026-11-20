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
//	    fetched_bytes=<n> wait_ms=<n> write_ms=<n> unfetched_pkgs=<n> unfetched_bytes=<n> unfetched_chunks=<n>
//	    (scope=media only) ... user_files=<n> user_bytes=<n> other_files=<n> other_bytes=<n>, or ... indexed=0   signinSummaryAppend
//	v=1 parked apps=<n> ce_kib=<n> de_kib=<n>, or v=1 parked apps=<n> size=unknown   od_parked_report (roamd)
//	v=1 phase=<in|reap|reown|acct> ms=<n>                                            _ssum (roamd)
//	v=1 appsindex pkgs=<n>                                                           signinSummaryAppendApps
//	v=1 appsseal stored=<n> dormant=<n> adopted=<n> carried=<n> dropped=<n> published=<n> lost=<n> vanished=<n>
//	    guard=<none|passed|refused>                                                  signinSummaryAppendApps (apps_seal_evidence.go)
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
//	signin_<scope>_fetched_bytes "<n>" sealed bytes fetched from the store by that whole restore process, heal included (pairs with _fetched)
//	signin_<scope>_wait_ms   "<n>" the ordered writer waiting for the next chunk from the store
//	signin_<scope>_write_ms  "<n>" the untar consuming the chunks: its creates, writes and per-file fsync
//	signin_<scope>_unfetched_pkgs "<n>" packages the parked skip left unfetched (0 when the skip is off)
//	signin_<scope>_unfetched_bytes "<n>" their plaintext bytes
//	signin_<scope>_unfetched_chunks "<n>" their chunks
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
//	signin_reown_ms          "<n>" the wait for the CE reown and relabel (a background job beside the #de restore, so only the wait counts, NWP-20261210-04), the #de tree's reown and relabel and the #media tail, added
//	signin_acct_ms           "<n>" acct_restore, which holds the #sys restore
//	signin_apps_index_pkgs   "<n>" the restored #apps head's app-index lines (the placeholders the sign-in can raise)
//
// NWP-20261208-01 (backlog: "P1: On-demand apps that are not on the phone at a sign-out are dropped from the `#apps`
// code list, ..."): the lastseal keys describe the last #apps seal of THIS profile on THIS handset since boot. The
// record sits in the state tmpfs, which is wiped at power-off, so a sign-in after a reboot has no lastseal keys,
// never zeros. A seal refused before its carry block leaves no record either.
//
//	lastseal_apps_stored     "<n>" the app-index lines of the head that seal read
//	lastseal_apps_dormant    "<n>" the dormant lines roamd offered (NOWHERE_APPS_DORMANT; 0 when it offered none)
//	lastseal_apps_adopted    "<n>" the dormant packages adopted over a head with no line for them
//	lastseal_apps_carried    "<n>" the packages the index union carried that the handset did not stage
//	lastseal_apps_dropped    "<n>" the packages the union dropped as deleted from the account
//	lastseal_apps_published  "<n>" the app-index lines of the head that seal built (0 when it stopped before it)
//	lastseal_apps_lost       "<n>" the packages that kept their deferred bytes but lost their index line
//	lastseal_apps_vanished   "<n>" the packages absent with nothing declaring their removal
//	lastseal_apps_guard      "none" the seal stopped before the presence guard, "passed" the guard let it
//	                         through (not proof of the upload), "refused" the guard refused it
//
// NWP-20261130-08 (backlog: The sign-in summary still cannot say where a fifth of op=in goes): the keys account for the op:
//
//	signin_in_ms = vault_ms + heal_ms + de_ms + media_ms + apps_ms + reown_ms + acct_ms + reap_ms + the rest
//
// signin_sys_ms is NOT in that sum, because it is inside signin_acct_ms. The rest is not timed: each restore's head and
// key resolution, keystore_restore, hold_ondemand and the small steps of the arm.
//
// NWP-20261203-09 (backlog: A sign-in fetches every CE vault chunk fresh: nothing is cached across sessions, so a large
// profile spends 5-7 minutes on the vault alone): the six fields after cap_calls split each restore into the network
// (wait_ms, fetched_bytes) and the untar (write_ms), and carry the parked skip's counts (restore_split.go). They are
// mandatory: a scope line without them is unreadable.
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

// signinSummaryMaxBytes bounds what a report reads of the file. The fifteen lines a sign-in writes (five scopes, parked,
// three reown, two reap, the other two phases, appsindex and appsseal) fit at their widest (TestSigninSummaryWidestFits).
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

// signinSummaryScopeRe, signinSummaryParkedRe, signinSummaryPhaseRe, signinSummaryAppsIndexRe and
// signinSummaryAppsSealRe are the file's only accepted line shapes.
var signinSummaryScopeRe = regexp.MustCompile(`^v=1 scope=(vault|de|media|apps|sys) ms=([0-9]{1,12}) chunks=([0-9]{1,12}) cached=([0-9]{1,12}) fetched=([0-9]{1,12}) heal_ms=([0-9]{1,12}) store_reads=([0-9]{1,12}) cap_calls=([0-9]{1,12}) fetched_bytes=([0-9]{1,15}) wait_ms=([0-9]{1,12}) write_ms=([0-9]{1,12}) unfetched_pkgs=([0-9]{1,12}) unfetched_bytes=([0-9]{1,15}) unfetched_chunks=([0-9]{1,12})(?: user_files=([0-9]{1,12}) user_bytes=([0-9]{1,15}) other_files=([0-9]{1,12}) other_bytes=([0-9]{1,15})| (indexed=0))?$`)
var signinSummaryParkedRe = regexp.MustCompile(`^v=1 parked apps=([0-9]{1,9})(?: ce_kib=([0-9]{1,12}) de_kib=([0-9]{1,12})| (size=unknown))$`)
var signinSummaryPhaseRe = regexp.MustCompile(`^v=1 phase=(in|reap|reown|acct) ms=([0-9]{1,12})$`)
var signinSummaryAppsIndexRe = regexp.MustCompile(`^v=1 appsindex pkgs=([0-9]{1,9})$`)
var signinSummaryAppsSealRe = regexp.MustCompile(`^v=1 appsseal stored=([0-9]{1,9}) dormant=([0-9]{1,9}) adopted=([0-9]{1,9}) carried=([0-9]{1,9}) dropped=([0-9]{1,9}) published=([0-9]{1,9}) lost=([0-9]{1,9}) vanished=([0-9]{1,9}) guard=(none|passed|refused)$`)

// signinSummaryAppsSealKeys are the appsseal line's keys, in the order of its fields.
var signinSummaryAppsSealKeys = []string{"stored", "dormant", "adopted", "carried", "dropped", "published", "lost", "vanished", "guard"}

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
	line += fmt.Sprintf(" fetched_bytes=%d wait_ms=%d write_ms=%d unfetched_pkgs=%d unfetched_bytes=%d unfetched_chunks=%d", // NWP-20261203-09
		atomic.LoadInt64(&restoreFetchedBytes), atomic.LoadInt64(&restoreWaitNs)/1_000_000, atomic.LoadInt64(&restoreWriteNs)/1_000_000,
		atomic.LoadInt64(&restoreUnfetchedPkgs), atomic.LoadInt64(&restoreUnfetchedBytes), atomic.LoadInt64(&restoreUnfetchedChunks))
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
			if (s == "media") != (m[15] != "" || m[19] != "") {
				return unreadable // the share extras or indexed=0 belong to, and are required on, the media line only
			}
			out["signin_"+s+"_ms"], out["signin_"+s+"_chunks"] = m[2], m[3]
			out["signin_"+s+"_cached"], out["signin_"+s+"_fetched"] = m[4], m[5]
			out["signin_"+s+"_store_reads"], out["signin_"+s+"_cap_calls"] = m[7], m[8]
			out["signin_"+s+"_fetched_bytes"] = m[9]
			out["signin_"+s+"_wait_ms"], out["signin_"+s+"_write_ms"] = m[10], m[11]
			out["signin_"+s+"_unfetched_pkgs"], out["signin_"+s+"_unfetched_bytes"] = m[12], m[13]
			out["signin_"+s+"_unfetched_chunks"] = m[14]
			heal[s], _ = strconv.ParseInt(m[6], 10, 64) // at most 12 digits, so it cannot fail
			if s != "media" {
				continue
			}
			// A later media line replaces the earlier one whole, so the keys always describe one line.
			for _, k := range []string{"user_files", "user_bytes", "other_files", "other_bytes", "indexed"} {
				delete(out, "signin_media_"+k)
			}
			if m[15] != "" {
				out["signin_media_user_files"], out["signin_media_user_bytes"] = m[15], m[16]
				out["signin_media_other_files"], out["signin_media_other_bytes"] = m[17], m[18]
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
		if m := signinSummaryAppsIndexRe.FindStringSubmatch(l); m != nil {
			out["signin_apps_index_pkgs"] = m[1]
			continue
		}
		if m := signinSummaryAppsSealRe.FindStringSubmatch(l); m != nil {
			for i, k := range signinSummaryAppsSealKeys {
				out["lastseal_apps_"+k] = m[i+1]
			}
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
// buildIssueReportWith (so outside its size trim: about 3 KiB at most, the widest file's 83 keys). It deletes every
// caller-sent signin_* and lastseal_apps_* key first, so only this file can set one. Never at device scope: a gate report carries no
// sign-in's numbers.
func mergeSigninSummary(status map[string]string, uid string, deviceScope bool) {
	if deviceScope || status == nil || uid == "" || strings.Trim(uid, "0123456789") != "" {
		return
	}
	for k := range status {
		if strings.HasPrefix(k, "signin_") || strings.HasPrefix(k, "lastseal_apps_") {
			delete(status, k)
		}
	}
	for k, v := range signinSummaryStatus(filepath.Join(loginStateDir(), signinSummaryPrefix+uid)) {
		status[k] = v
	}
}
