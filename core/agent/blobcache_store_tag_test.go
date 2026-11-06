package main

import "testing"

// TestBlobCacheTagSeparatesManagedStores is the one way two otherwise-unrelated stores can touch.
//
// Two devices on two stores share nothing: refs derive from (name, passphrase) with no endpoint or bucket
// input, so the same identity computes the same refs everywhere -- but those refs live in different buckets,
// metered by different ledgers, with nothing coordinating them. Two universes that happen to use the same
// street addresses.
//
// Except inside the device. blobCachePath namespaces the "which chunks are already present in this store"
// cache on S3_ENDPOINT + S3_BUCKET -- and in CAP MODE both are empty, because a managed device holds no S3
// config at all, only GATEWAY_URL. So every managed store collapses to one tag. Move a device from one
// gateway to another and it carries "chunk abc is already present" into a store that has never seen it;
// postBlob then skips the upload with no store check, and the head it publishes references objects that do
// not exist.
//
// That is exactly the "move to a different store" use case, so it has to be a real separation.
func TestBlobCacheTagSeparatesManagedStores(t *testing.T) {
	t.Setenv("NOWHERE_BLOBCACHE", t.TempDir())
	// Cap mode: no S3 config whatsoever, which is what a managed device looks like.
	t.Setenv("S3_ENDPOINT", "")
	t.Setenv("S3_BUCKET", "")
	t.Setenv("S3_ACCESS_KEY", "")

	t.Setenv("GATEWAY_URL", "https://api-beta.nowhere.mobile")
	beta := blobCachePath()
	t.Setenv("GATEWAY_URL", "https://api.nowhere.mobile")
	prod := blobCachePath()

	if beta == "" || prod == "" {
		t.Fatal("blobCachePath returned empty with NOWHERE_BLOBCACHE set")
	}
	if beta == prod {
		t.Fatalf("TWO DIFFERENT MANAGED STORES SHARE ONE BLOB CACHE (%s). A device moving between gateways "+
			"carries its belief about the old store's chunks into the new one, and postBlob then skips those "+
			"uploads -- publishing a head that references objects the destination does not have.", beta)
	}

	// ...and direct mode must still separate by endpoint+bucket, which is what it always did.
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ENDPOINT", "https://s3.example.com")
	t.Setenv("S3_BUCKET", "one")
	one := blobCachePath()
	t.Setenv("S3_BUCKET", "two")
	two := blobCachePath()
	if one == two {
		t.Error("direct mode: two buckets on one endpoint share a cache tag")
	}
}
