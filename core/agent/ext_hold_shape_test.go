package main

import "testing"

// The EXTERNAL on-demand hold (DIA-20260816-19).
//
// roamd's hold_ondemand parks an on-demand app's external app-data at
//
//	Android/{data,obb}/com.nowhere.chooser/.nowhere-odhold/<pkg>
//
// so that reap_stale_ondemand's login-time `pm uninstall` (USER_ALL) cannot delete it. That uninstall used to
// take the whole of /data/media/<uid>/Android/data/<pkg> with it -- measured on lynx 2026081605, seven seconds
// after the #media restore had written 88 MB into exactly that directory, on every login for weeks.
//
// These pin the two ways the new shape can silently do the wrong thing. Both failure modes are ORDERING bugs
// in a Go switch, which is why they get tests rather than trust: the pre-existing generic
// `Android/{data,obb}/<pkg>` case matches the hold path too, with parts[2] == "com.nowhere.chooser".

func TestDropReachesTheExternalHold(t *testing.T) {
	drop := map[string]bool{"net.peakgames.toonblast": true}

	// The hold DIR itself must be dropped -- this is what makes the walk SkipDir the subtree.
	for _, rel := range []string{
		"Android/data/com.nowhere.chooser/.nowhere-odhold/net.peakgames.toonblast",
		"Android/obb/com.nowhere.chooser/.nowhere-odhold/net.peakgames.toonblast",
	} {
		if !dropPkgForRel(rel, drop) {
			t.Errorf("%s: a dropped app's held external data must be dropped, not carried", rel)
		}
	}

	// And every FILE under it. Without the new case the generic Android case answers
	// drop["com.nowhere.chooser"] == false, and the switched-off app's largest bytes keep roaming -- and keep
	// being BILLED -- forever, which is the exact failure dropPkgForFileRel was written to prevent.
	for _, rel := range []string{
		"Android/data/com.nowhere.chooser/.nowhere-odhold/net.peakgames.toonblast/files/ContentDownload/blob.dat",
		"Android/obb/com.nowhere.chooser/.nowhere-odhold/net.peakgames.toonblast/main.obb",
	} {
		if !dropPkgForFileRel(rel, drop) {
			t.Errorf("%s: file under a dropped app's external hold must be dropped", rel)
		}
	}

	// A DIFFERENT app's hold must survive. The shape must key on parts[4], not merely match the prefix.
	keep := "Android/data/com.nowhere.chooser/.nowhere-odhold/org.example.other/f.dat"
	if dropPkgForFileRel(keep, drop) {
		t.Errorf("%s: only the dropped package's hold may be dropped", keep)
	}

	// The new case must SHADOW the generic one, not merely sit beside it.
	//
	// The generic `Android/{data,obb}/<pkg>` rule reads parts[2], which on a hold path is the chooser. So if
	// the chooser ever appeared on a drop list, the generic rule would match every app's held external data at
	// once and the seal would stop carrying all of it -- one entry silently dropping every on-demand app's
	// bytes. The new case is listed first precisely so parts[4] decides, and this is that guarantee.
	chooserDropped := map[string]bool{chooserPkg: true}
	for _, rel := range []string{
		"Android/data/com.nowhere.chooser/.nowhere-odhold/org.example.other/f.dat",
		"Android/obb/com.nowhere.chooser/.nowhere-odhold/net.peakgames.toonblast/main.obb",
	} {
		if dropPkgForFileRel(rel, chooserDropped) {
			t.Errorf("%s: dropping the chooser must not drop the apps whose data it merely HOLDS", rel)
		}
	}
}

func TestExternalHoldBillsToTheAppNotTheChooser(t *testing.T) {
	// attrPkgForRel decides which row a byte lands on in the storage screen. The generic Android case would
	// answer "com.nowhere.chooser" for every held byte -- and for an on-demand app the hold IS the profile
	// (88 MB for one game), so the biggest row would name the wrong app in a screen whose entire job is
	// telling the user what costs what.
	cases := map[string]string{
		"Android/data/com.nowhere.chooser/.nowhere-odhold/net.peakgames.toonblast":                 "net.peakgames.toonblast",
		"Android/data/com.nowhere.chooser/.nowhere-odhold/net.peakgames.toonblast/files/a/b/c.dat": "net.peakgames.toonblast",
		"Android/obb/com.nowhere.chooser/.nowhere-odhold/net.peakgames.toonblast/main.obb":         "net.peakgames.toonblast",

		// unchanged shapes, asserted here so the new case cannot have stolen them
		"Android/data/net.peakgames.toonblast/files/x":       "net.peakgames.toonblast",
		"Android/media/net.peakgames.toonblast/pic.jpg":      "net.peakgames.toonblast",
		"com.nowhere.chooser/.nowhere-odhold/org.x/files/y":  "org.x",
		"Android/data/com.nowhere.chooser/files/settings.db": "com.nowhere.chooser",
	}
	for rel, want := range cases {
		if got := attrPkgForRel(rel); got != want {
			t.Errorf("attrPkgForRel(%q) = %q, want %q", rel, got, want)
		}
	}
}
