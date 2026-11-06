package main

import "testing"

// #400: the media-daemon caches (.nowhere-media CE, .nowhere-media-ext external #media) must never contribute
// deferred manifest entries. isMediaCachePath is the drop predicate that (a) matches a cache path wherever it
// nests and (b) NEVER matches a legit app rel -- the safety invariant that lets pushProfile drop such entries
// from the present-not-deleted carry without risking real user media.
func TestIsMediaCachePath(t *testing.T) {
	cache := []string{
		"com.nowhere.chooser/files/.nowhere-media/blob/ab",                                                                                        // CE cache
		"com.nowhere.chooser/files/.nowhere-media-ext/.fetch-3499227703",                                                                          // ext fetch scratch
		"com.nowhere.chooser/files/.nowhere-media-ext/.under/Android_data_app.organicmaps_files_260527/US_New Jersey_South.mwm.ready.downloading", // the alice repro
		".nowhere-media-ext/Android/data/app.organicmaps/files/x.mwm",                                                                             // ext cache at the root
	}
	for _, rel := range cache {
		if !isMediaCachePath(rel) {
			t.Errorf("isMediaCachePath(%q) = false, want true (a media-daemon cache path)", rel)
		}
	}
	legit := []string{
		"app.organicmaps/files/260527/US_New Jersey_South.mwm", // the CLEAN #media rel -> must NOT be dropped
		"Android/data/app.organicmaps/files/x.mwm",
		"media/0/DCIM/x.jpg",
		"com.nowhere.chooser/files/nowhere-tickets.json", // near-miss: no ".nowhere-media" segment
		"com.example.nowheremedia/files/x",               // near-miss: pkg contains the substring, not a segment prefix
	}
	for _, rel := range legit {
		if isMediaCachePath(rel) {
			t.Errorf("isMediaCachePath(%q) = true, want false (a legit app rel must never be dropped)", rel)
		}
	}
}
