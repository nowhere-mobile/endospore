package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// FREE-MEDIA-FOLDER (NWP-20261207-14, h51 #4, docs/product-decisions.md 2026-11-01): "Free on this phone" for one
// top-level folder row of the Storage screen. FREE-MEDIA-CACHE frees every fetched copy; this frees only the fetched
// copies of the named folder's on-demand files. A fetch-cache entry is named by cacheKey of its deferred file, so the
// daemon, the only side that can open the #media head, lists those keys in the state tmpfs and roamd's freemediakeys
// deletes exactly them. A cache entry is content-addressed from the store, so freeing it never loses a change: the
// user's own files are in .under/ and parked app data in .nowhere-odhold, and roamd never names either.

// freeMediaManifestOf is the store-reading seam of FREE-MEDIA-FOLDER (the pattern of footprint_list.go's
// storeFolderBytesOf): the handler hardcodes the "s3" store, so only a test can substitute what it reads.
var freeMediaManifestOf = func(base, profile, pass string, se []byte) (chunkManifest, bool) {
	return scopeManifest(base, profile+"#media", pass, se)
}

// freeMediaFolderMu serializes FREE-MEDIA-FOLDER calls. Every call uses the one path dest/freemedia.keys and takes the
// RW slot only after it has written the list, so without it call A's worker could run on call B's list: A would free
// B's folder and B would find no list.
var freeMediaFolderMu sync.Mutex

// validMediaFolder says f can name a folder row: one non-empty path component of at most 255 bytes with no control
// byte, never "." or "..", and never Android (isMediaFolderRel leaves Android/ to the app rows).
func validMediaFolder(f string) bool {
	if f == "" || len(f) > 255 || f == "." || f == ".." || f == "Android" {
		return false
	}
	for i := 0; i < len(f); i++ {
		if b := f[i]; b == '/' || b < 0x20 || b == 0x7f {
			return false
		}
	}
	return true
}

// folderCacheKeys is the fetch-cache entry names of folder's on-demand files in a #media manifest: cacheKey of every
// Deferred rel under that top-level folder, deduplicated (two files with the same chunks share one entry) and sorted.
// Ess files are never fetched through the cache, so they are never listed.
func folderCacheKeys(m chunkManifest, folder string) []string {
	seen := map[string]bool{}
	for rel, d := range m.Deferred {
		if isMediaFolderRel(rel) && mediaFolderOf(rel) == folder {
			seen[cacheKey(d)] = true
		}
	}
	keys := make([]string, 0, len(seen))
	for k := range seen {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// freeMediaKeysPath is the key list roamd's freemediakeys reads: $STATE/freemedia.keys on the state tmpfs, as
// sealdelta.idx is. A list a crash leaves goes at the reap (isSessionCache).
func freeMediaKeysPath(dest string) string { return filepath.Join(dest, "freemedia.keys") }

// writeFreeMediaKeys writes one key per line, 0600, through a temp file and a rename.
func writeFreeMediaKeys(path string, keys []string) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(strings.Join(keys, "\n")+"\n"), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// freeListedKeys writes the list, runs roamd's freemediakeys and removes the list, all under freeMediaFolderMu, so
// the list a worker run reads is always the list of the call that started it.
func freeListedKeys(dest, name, uid string, keys []string) string {
	freeMediaFolderMu.Lock()
	defer freeMediaFolderMu.Unlock()
	p := freeMediaKeysPath(dest)
	defer os.Remove(p)
	defer os.Remove(p + ".tmp")
	if err := writeFreeMediaKeys(p, keys); err != nil {
		return "ERR-WORKER"
	}
	out := strings.TrimSpace(triggerRoamWorker(dest, "freemediakeys", name, "", uid, "", nil))
	if out == "" {
		return "ERR-WORKER"
	}
	return out
}

// handleFreeMediaFolder backs FREE-MEDIA-FOLDER. The folder is on the second line, so it never sits on the verb line.
// Reply: NONE | LOCAL | ERR-FOLDER | ERR-HEAD | OK <bytes> | the worker's ERR token. An unread head frees nothing: it
// never falls back to the all-cache purge. The log line holds counts and the reply token only, never the folder name
// (user data) nor a key.
func handleFreeMediaFolder(conn net.Conn, r *bufio.Reader, dest string) {
	nm, ps, uid := readRoamSession(dest)
	if nm == "" || uid == "" {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	if isLocalSession(dest) {
		fmt.Fprint(conn, "LOCAL\n")
		return
	}
	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	line, _ := r.ReadString('\n')
	folder := strings.TrimRight(line, "\r\n")
	n, tok := 0, ""
	defer func() {
		fmt.Fprintf(os.Stderr, "[agent] free-media-folder: %d key(s) listed, reply %s\n", n, tok)
	}()
	reply := func(s string) {
		if f := strings.Fields(s); len(f) > 1 && f[0] == "OK" {
			tok = f[0] + " " + f[1]
		} else if len(f) > 0 {
			tok = f[0]
		}
		fmt.Fprintf(conn, "%s\n", s)
	}
	if !validMediaFolder(folder) {
		reply("ERR-FOLDER")
		return
	}
	loadFido2HmacEnv(dest) // a 2FA head opens via the enrolled key's cached hmac, as LIST-MEDIA-APPS
	m, ok := freeMediaManifestOf("s3", nm, ps, seFromSession(dest))
	if !ok {
		reply("ERR-HEAD")
		return
	}
	keys := folderCacheKeys(m, folder)
	n = len(keys)
	if n == 0 {
		reply("OK 0")
		return
	}
	reply(freeListedKeys(dest, nm, uid, keys))
}
