package main

import (
	"reflect"
	"testing"
)

// NWP-20260829-04. deferredDirs() keys by path.Dir(rel), so a profile with WhatsApp yields BOTH
// ".../Media/WhatsApp Images" and ".../Media/WhatsApp Images/Sent". Overlaying each is broken in both mount
// orders -- ancestor-first fails MS_PRIVATE with EACCES (the bind inherits the overlay's SELinux type and
// nothing grants `dir mounton` on it), child-first leaves the child mount unreachable because mounts are
// keyed (parent-mount, dentry). The leftover mount goes dead when mediad is SIGKILLed at logoff, the seal
// walk then gets ENOTCONN, and the #media guard refuses a short manifest FOREVER: the profile cannot log
// off. serveMediaScope ranged over the map, so which failure you got was a coin flip per session.
//
// mediaMountRoots collapses the set to its maximal dirs, which removes nothing that ever worked.

func dirSet(ds ...string) map[string][]string {
	m := map[string][]string{}
	for _, d := range ds {
		m[d] = []string{"f.dat"}
	}
	return m
}

func TestMediaMountRootsCollapsesNestedDirs(t *testing.T) {
	got := mediaMountRoots(dirSet(
		"Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images",
		"Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/Sent",
		"Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video",
		"Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video/Private",
		"DCIM/Camera",
	))
	want := []string{
		"Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images",
		"Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video",
		"DCIM/Camera",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("nested dirs must collapse into their maximal ancestor:\n got  %q\n want %q", got, want)
	}
}

// The whole bug was ORDER-DEPENDENT because the source was a Go map. The planner must be deterministic, or
// the wedge simply becomes a rarer coin flip instead of being fixed.
func TestMediaMountRootsIsDeterministic(t *testing.T) {
	in := dirSet("b/x", "a", "a/b", "a/b/c", "c", "a/bb")
	first := mediaMountRoots(in)
	for i := 0; i < 50; i++ { // map range order varies per iteration; the output must not
		if got := mediaMountRoots(in); !reflect.DeepEqual(got, first) {
			t.Fatalf("iteration %d differed:\n got  %q\n want %q", i, got, first)
		}
	}
}

// Component safety: "a/SentX" shares a STRING prefix with "a/Sent" but is not inside it. Swallowing it would
// silently stop serving a real deferred dir -- the failure mode this fix exists to avoid, reintroduced.
func TestMediaMountRootsIsComponentSafe(t *testing.T) {
	got := mediaMountRoots(dirSet("a/Sent", "a/SentX", "a/Sent/deep"))
	want := []string{"a/Sent", "a/SentX"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("a sibling sharing a string prefix must survive:\n got  %q\n want %q", got, want)
	}
}

// A dir with no ancestor in the set is its own root, and an ancestor is never invented: synthesizing a
// common parent that holds no deferred files would widen the overlaid surface for nothing.
func TestMediaMountRootsKeepsUnrelatedDirsAndInventsNothing(t *testing.T) {
	got := mediaMountRoots(dirSet("x/y/one", "x/y/two", "z"))
	want := []string{"x/y/one", "x/y/two", "z"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("unrelated dirs must each stay a root and no ancestor may be invented:\n got  %q\n want %q", got, want)
	}
	if len(mediaMountRoots(map[string][]string{})) != 0 {
		t.Fatal("empty set must yield no roots")
	}
}

// Deep chains must collapse to the single outermost dir, not merely one level.
func TestMediaMountRootsCollapsesDeepChains(t *testing.T) {
	got := mediaMountRoots(dirSet("a", "a/b", "a/b/c", "a/b/c/d"))
	if want := []string{"a"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("a chain must collapse to its outermost dir:\n got  %q\n want %q", got, want)
	}
}
