package main

import (
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

// NWP-20261205-08 -- evidence for the backlog row "A new video in a media folder whose files are still downloading
// plays poorly while mediad downloads that folder". mediad counts its own FUSE reads by duration bucket, split by
// whether a background run (a materialize or the #media lander) was active, with the range-mapped stub reads in a
// row of their own; it adds the background runs' files, bytes and time and its own CPU time. It writes that as one
// line to $NOWHERE_STATE/media.iostat, and an in-session issue report carries the line as `media_io`.
//
// NUMBERS ONLY: no file, folder, app or profile name is ever counted, written or merged. Nothing here changes how
// mediad serves, fetches or schedules.

const mediaIOFile = "media.iostat" // in $NOWHERE_STATE (the state tmpfs), never /data/nowhere

// mediaIOEvery is how often mediad rewrites media.iostat. A var so a test can shorten it.
var mediaIOEvery = 30 * time.Second

const mediaIOBuckets = 5 // <1 ms, <10 ms, <50 ms, <250 ms, >=250 ms

type mediaIOStats struct {
	rd, rdbg, stub   [mediaIOBuckets]atomic.Int64 // read counts per bucket: no run active, a run active, stub reads
	active           atomic.Int64                 // background runs active now (a gauge: runs can overlap)
	bgRuns, bgMs     atomic.Int64
	bgFiles, bgBytes atomic.Int64
}

var mediaIO mediaIOStats

// mediaIOStart is when this process started counting; `up` is measured from it.
var mediaIOStart = time.Now()

// mediaIOCPU is a seam: production reads getrusage, a test pins the value.
var mediaIOCPU = mediaIOCPUms

func mediaIOBucket(d time.Duration) int {
	switch {
	case d < time.Millisecond:
		return 0
	case d < 10*time.Millisecond:
		return 1
	case d < 50*time.Millisecond:
		return 2
	case d < 250*time.Millisecond:
		return 3
	}
	return 4
}

// mediaIOLat is the go-fuse LatencyMap of every overlay mount. FUSE serves each op on its own goroutine, so it is
// lock-free.
type mediaIOLat struct{}

var _ fuse.LatencyMap = mediaIOLat{}

func (mediaIOLat) Add(name string, dt time.Duration) {
	if name != "READ" {
		return
	}
	if mediaIO.active.Load() > 0 {
		mediaIO.rdbg[mediaIOBucket(dt)].Add(1)
		return
	}
	mediaIO.rd[mediaIOBucket(dt)].Add(1)
}

// mediaIOStub counts one read of a range-mapped deferred file (a placeholder whose bytes may still be fetched).
func mediaIOStub(dt time.Duration) {
	mediaIO.stub[mediaIOBucket(dt)].Add(1)
}

func mediaBgBegin() time.Time {
	mediaIO.active.Add(1)
	return time.Now()
}

// mediaBgEnd adds the run's totals, then drops the gauge LAST, so a reader that sees no run active also sees them.
func mediaBgEnd(start time.Time, files int, bytes int64) {
	mediaIO.bgRuns.Add(1)
	mediaIO.bgMs.Add(time.Since(start).Milliseconds())
	mediaIO.bgFiles.Add(int64(files))
	mediaIO.bgBytes.Add(bytes)
	mediaIO.active.Add(-1)
}

// mediaIOCPUms is this process's user + system CPU time in ms, 0 when unreadable.
func mediaIOCPUms() int64 {
	var ru syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &ru); err != nil {
		return 0
	}
	return (int64(ru.Utime.Sec)+int64(ru.Stime.Sec))*1000 + (int64(ru.Utime.Usec)+int64(ru.Stime.Usec))/1000
}

func mediaIORow(r *[mediaIOBuckets]atomic.Int64) string {
	s := make([]string, mediaIOBuckets)
	for i := range r {
		s[i] = strconv.FormatInt(r[i].Load(), 10)
	}
	return strings.Join(s, "/")
}

// mediaIOLine is the one line mediad publishes. Fixed keys in a fixed order; mediaIOLineRE is its grammar.
func mediaIOLine(uid int, now time.Time) string {
	up := int64(now.Sub(mediaIOStart) / time.Second)
	if up < 0 {
		up = 0
	}
	return "v=1 u=" + strconv.Itoa(uid) +
		" up=" + strconv.FormatInt(up, 10) +
		" rd=" + mediaIORow(&mediaIO.rd) +
		" rdbg=" + mediaIORow(&mediaIO.rdbg) +
		" stub=" + mediaIORow(&mediaIO.stub) +
		" bg=" + strconv.FormatInt(mediaIO.bgRuns.Load(), 10) +
		" bgms=" + strconv.FormatInt(mediaIO.bgMs.Load(), 10) +
		" bgfiles=" + strconv.FormatInt(mediaIO.bgFiles.Load(), 10) +
		" bgbytes=" + strconv.FormatInt(mediaIO.bgBytes.Load(), 10) +
		" cpums=" + strconv.FormatInt(mediaIOCPU(), 10)
}

// mediaIOWrite replaces $stateDir/media.iostat by temp + rename, 0600, so a reader sees a whole line.
func mediaIOWrite(stateDir string, uid int) error {
	f, err := os.CreateTemp(stateDir, ".media.iostat.*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	_, err = f.WriteString(mediaIOLine(uid, time.Now()) + "\n")
	if err == nil {
		err = f.Chmod(0o600)
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, filepath.Join(stateDir, mediaIOFile))
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}

var mediaIOWarned atomic.Bool

// mediaIOPublish is the `media iostat` loop: it writes first, so a report taken soon after start has data, and
// never returns. A failed write logs one line per process.
func mediaIOPublish(stateDir string, uid int) {
	for {
		if err := mediaIOWrite(stateDir, uid); err != nil && mediaIOWarned.CompareAndSwap(false, true) {
			dlog("mediad: media.iostat not written: %v (NWP-20261205-08)", errCode(err))
		}
		time.Sleep(mediaIOEvery)
	}
}

// mediaMountServe is fs.Mount with the read-latency map set BEFORE the serve loop starts: the loop reads the map
// without a lock, so setting it after fs.Mount returns would race it.
func mediaMountServe(dir string, root fs.InodeEmbedder, opts *fs.Options) (*fuse.Server, error) {
	rawFS := fs.NewNodeFS(root, opts)
	var mountOpts *fuse.MountOptions
	if opts != nil {
		mountOpts = &opts.MountOptions
	}
	server, err := fuse.NewServer(rawFS, dir, mountOpts)
	if err != nil {
		return nil, err
	}
	server.RecordLatencies(mediaIOLat{})
	goSafe("media fuse serve", server.Serve)
	if err := server.WaitMount(); err != nil {
		return nil, err // as fs.Mount: a failed mount ends its own serve loop
	}
	return server, nil
}

var mediaIOLineRE = regexp.MustCompile(`^v=1 u=([0-9]+) up=[0-9]+ rd=[0-9]+(?:/[0-9]+){4} rdbg=[0-9]+(?:/[0-9]+){4} stub=[0-9]+(?:/[0-9]+){4} bg=[0-9]+ bgms=[0-9]+ bgfiles=[0-9]+ bgbytes=[0-9]+ cpums=[0-9]+$`)

const mediaIOMaxBytes = 1024

// mergeMediaIO sets the report's `media_io` from mediad's line: session scope only, this session's uid only. A
// caller-sent value is always dropped. A line of another session's uid adds nothing; a file that fails the grammar
// adds `unreadable`.
func mergeMediaIO(status map[string]string, dest, uid string, deviceScope bool) {
	delete(status, "media_io") // a nil map is safe
	if deviceScope || status == nil || uid == "" {
		return
	}
	p := filepath.Join(dest, mediaIOFile)
	f, err := os.Open(p)
	if err != nil {
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		status["media_io"] = "unreadable"
		return
	}
	b, err := io.ReadAll(io.LimitReader(f, mediaIOMaxBytes+1))
	if err != nil || len(b) > mediaIOMaxBytes {
		status["media_io"] = "unreadable"
		return
	}
	line := strings.TrimSuffix(string(b), "\n")
	m := mediaIOLineRE.FindStringSubmatch(line)
	if m == nil {
		status["media_io"] = "unreadable"
		return
	}
	if m[1] != uid {
		return
	}
	age := int64(time.Since(fi.ModTime()) / time.Second)
	if age < 0 {
		age = 0
	}
	status["media_io"] = line + " age=" + strconv.FormatInt(age, 10)
}
