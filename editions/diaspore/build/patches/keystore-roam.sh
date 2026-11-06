#!/usr/bin/env bash
# keystore-roam.sh -- #210 part 2: let every app's Keystore keys survive a roam, ON THIS DEVICE. Every app
# namespace is carried; there is no opt-in. This file carries the export (dump at user removal and at a
# namespace clear), both import paths, and the app-namespace key census.
# (Superseded by NWP-20260830-03: this header used to read "let an opted-in app's Keystore keys survive" and
# "INCREMENT 1 of 2: the EXPORT half (dump at user removal). The import half lands separately".)
#
# THE PROBLEM. #210 made an app's SSAID roam, which was necessary and not sufficient: Amazon still signs out
# on every login because MAP seals its token under Keystore keys (aliases IDENTITY_MAP_KEYSTORE_ALIAS,
# mshop_rcs_master_key, widget_cache_key -- observed on lynx), and keystore entries are namespaced by app uid,
# so they are deleted with the roamed user.
#
# WHY THIS IS POSSIBLE AT ALL (verified in this tree, not assumed):
#   - The TEE has NO concept of Android users. A KeyMint blob is DEVICE-bound, not uid-bound. Ownership is
#     pure sqlite bookkeeping -- `Domain::APP => KeyDescriptor { nspace: caller_uid.0, .. }` in database.rs.
#   - Enforcements::super_encryption_required returns None unless the key is auth-bound (UserSecureID),
#     UnlockedDeviceRequired, or boot-level. Amazon's keys are NO_AUTH_REQUIRED, so their blobs are RAW
#     KeyMint blobs, carryable as bytes.
#
# WHY NOT migrateKeyNamespace, which already exists: it forces an APP destination to the CALLER's uid
# (maintenance.rs migrate_key_namespace -> database.rs), so only the app itself could migrate a key into its
# own namespace. A daemon cannot. And parking keys in a SELINUX namespace only survives while /data does --
# boot-wipe (P2) is mandatory in the lock model, at which point only a store-backed bundle survives. So the
# bundle is the design that outlives what the OS is committed to becoming.
#
# WHAT IS REFUSED. A blob carrying a BlobMetaEntry EncryptedBy row (tag 0 -- the variant order is
# EncryptedBy=0, Salt=1, Iv=2, AeadTag=3, KmUuid=4) is superencrypted under the OLD user's LSKF-derived super
# key, which the next user does not have. Restoring one yields a key that EXISTS BUT CANNOT BE USED, and apps
# handle that far worse than a missing key. Detected directly from the metadata rather than by re-deriving
# keystore2's policy, so it holds whatever the policy reason was.
#
# WHERE IT HOOKS. SuperKeyManager::remove_user, immediately BEFORE db.unbind_keys_for_user -- the last moment
# these blobs exist. roamd pushes what lands in the dump dir as the name#keys scope after the reap.
#
# Tree-agnostic, idempotent (a marker check), and inert without the roamd half: roamd writes the keystore-
# readable unit-id mirror, and without it `unit_or_skip` skips the export, so nothing is dumped.
# (Superseded by NWP-20260830-03: the reason given here was "with no keep-list, the export finds nothing to
# do". There is no keep-list any more; the missing unit id is what keeps the export inert.)
#
# Usage: keystore-roam.sh <tree-root>
set -euo pipefail
TREE="${1:?usage: keystore-roam.sh <tree-root>}"
KS="$TREE/system/security/keystore2"
DB="$KS/src/database.rs"
SK="$KS/src/super_key.rs"
LIB="$KS/src/lib.rs"
for f in "$DB" "$SK" "$LIB"; do [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }; done

MARKER="nowhere_dump_user_keys"
# Bump whenever the patch BODY changes. Without a version the skip below is a TRAP: a tree still carrying an
# older application of this patch looks "patched", the script skips, and the build silently ships WITHOUT the
# new fix -- which then presents on-device as the bug being unfixed, sending you after a ghost (the same class
# as the stale-flashed-binary hunt in #108). Re-applying over an already-patched tree cannot work either, since
# every step below is a textual replace against PRISTINE anchors -- so the only correct move is to say so and
# stop. NB the version string must be one this script actually writes INTO $DB -- for this version that is the
# comment inside nowhere_dump_user_keys explaining the empty-slice inversion. The self-check at the bottom of
# this script verifies exactly that, so a bump that forgets to stamp fails loudly instead of self-bricking.
PATCH_VERSION="NWP-20260830-03"
if grep -qF "$MARKER" "$DB"; then
  if grep -qF "$PATCH_VERSION" "$DB"; then
    echo "[keystore-roam] already patched ($PATCH_VERSION) -- skipped"
    exit 0
  fi
  echo "[keystore-roam] ERROR: tree carries an OLDER keystore-roam patch (missing $PATCH_VERSION)." >&2
  echo "[keystore-roam] Revert the keystore2 sources, then re-run this script:" >&2
  echo "    git -C \"$KS\" checkout -- src/ && rm -f \"$KS/src/nowhere_roam.rs\"" >&2
  echo "[keystore-roam] Refusing to skip: skipping here would ship a build WITHOUT the newer fix." >&2
  exit 1
fi

# --- 1. the new module -------------------------------------------------------------------------------
cat > "$KS/src/nowhere_roam.rs" <<'RUST'
// Copyright (C) 2026 Nowhere Mobile LLC

//! #210 part 2: carry an opted-in app's Keystore keys across a roam, on THIS device.
//!
//! An app's login can survive a roam only if BOTH halves of its device identity survive: its SSAID (#210,
//! shipped) and the Keystore keys its token is sealed under (this). Keystore entries are namespaced by app
//! uid and are deleted with the roamed user, so without this an app that seals to Keystore signs out on
//! every single login no matter how stable its SSAID is.
//!
//! This module owns POLICY and FILE I/O; the SQL lives in database.rs (its transaction helper is private).
//!
//! SAFETY POSTURE. Everything here is best-effort and must never fail a user removal: losing an export costs
//! the carry-over, while an error propagating out of remove_user would break user deletion, which is a core
//! amnesia guarantee. Every entry point therefore swallows its errors after logging them.

use crate::database::{KeystoreDB, NowhereCell, NowhereKey};
use crate::utils::{AndroidUserId, AID_USER_OFFSET};
use android_system_keystore2::aidl::android::system::keystore2::Domain::Domain;
use anyhow::Result;
use std::io::Write;

/// Where a dump lands: one file per namespace, `<ns>.keys`. nowhere_roamd pushes these as the name#keys
/// scope after the reap and then clears the directory.
const DUMP_DIR: &str = "/data/misc/keystore/nowhere-export";

/// This device's unit id, stamped into every bundle. The import side refuses a bundle stamped for another
/// device: a KeyMint blob from another handset's TEE cannot be unwrapped here, and installing one would give
/// the app a key that exists but fails on use -- worse than no key at all.
/// ⚠ MUST be under /data/misc/keystore (keystore_data_file): keystore2 runs as the `keystore` UNIX user, NOT
/// root, so it cannot read /data/nowhere/unit-id (root:root 0600, and the nowhere_data_file SELinux type is
/// unreachable from the keystore domain). read_unit() silently returned "" there and every export no-op'd.
/// nowhere_roamd mirrors the id here (keystore_unit), where the keystore domain CAN read it. (The removed
/// KEEP_PATH opt-in file was a keystore_data_file for the same reason -- NWP-20260830-03.)
const UNIT_PATH: &str = "/data/misc/keystore/nowhere-unit-id";

fn read_unit() -> String {
    std::fs::read_to_string(UNIT_PATH).map(|s| s.trim().to_string()).unwrap_or_default()
}

/// Dump the carryable keys of ALL of `user`'s app namespaces. A fallback for the BULK user-removal path
/// (SuperKeyManager::remove_user). NB in practice a roamed app's keys are usually already gone by here --
/// see export_for_namespace, the primary hook.
///
/// NWP-20260830-03: there is no longer an opt-in. "Keep me signed in" was removed because it named an
/// outcome it could not deliver -- an app's session may live in Keystore, in app data, or both, and the
/// switch only ever governed the first, so turning it OFF left apps signed in anyway. Keys now roam
/// unconditionally, on the same rule as app data.
pub fn export_for_user(db: &mut KeystoreDB, user: AndroidUserId) {
    let unit = match unit_or_skip(&format!("user {user:?}")) {
        Some(u) => u,
        None => return,
    };
    // Empty slice = every namespace belonging to this user. The SQL already scopes to domain APP, live
    // client keys, this user, and carryable-only, so "all" here is still a tightly bounded set.
    match db.nowhere_dump_user_keys(user, &[]) {
        Ok(dumped) => write_dumped(&unit, dumped),
        Err(e) => log::warn!("nowhere: keystore export for {user:?} failed: {e:?}"),
    }
}

/// PRIMARY hook (#210, DIA-20260728-16): dump an app's carryable keys when its NAMESPACE is cleared --
/// keystore2 clear_namespace(APP, ns), which fires when the app is UNINSTALLED. This is the real moment a
/// roamed app's keys die: on a reap the app is uninstalled (roamd reap-uninstall) BEFORE the bulk
/// remove_user runs, so by the time export_for_user could fire the keys are already gone. Placing the export
/// here, immediately before unbind_keys_for_namespace, catches them at the actual deletion point.
/// Only opted-in APP namespaces are touched; everything else returns immediately.
pub fn export_for_namespace(db: &mut KeystoreDB, domain: Domain, nspace: i64) {
    if domain != Domain::APP {
        return; // SELINUX / other namespaces are never app identities we carry
    }
    // NWP-20260830-03: no opt-in gate. Every app namespace is carried -- see export_for_user for why.
    let unit = match unit_or_skip(&format!("ns {nspace}")) {
        Some(u) => u,
        None => return,
    };
    // Reuse the user-scoped dump filtered to exactly this one namespace: it selects keys whose
    // namespace/AID_USER_OFFSET == user AND namespace is in the keep list, so keep=[nspace] yields just nspace.
    let user = AndroidUserId((nspace / AID_USER_OFFSET as i64) as i32);
    match db.nowhere_dump_user_keys(user, &[nspace]) {
        Ok(dumped) => write_dumped(&unit, dumped),
        Err(e) => log::warn!("nowhere: keystore export ns {nspace} failed: {e:?}"),
    }
}

/// Read the device unit id or log why the export is being skipped. A bundle we couldn't safely re-import
/// (no device stamp) is worse than no bundle -- the import would reject it anyway, or worse install an
/// unusable key -- so a missing unit id skips the export.
fn unit_or_skip(who: &str) -> Option<String> {
    let unit = read_unit();
    if unit.is_empty() {
        log::warn!("nowhere: keystore export for {who} skipped -- no unit id");
        None
    } else {
        Some(unit)
    }
}

/// Write each dumped namespace's bundle to DUMP_DIR. Shared by the namespace-clear and user-removal hooks.
fn write_dumped(unit: &str, dumped: Vec<(i64, String)>) {
    if dumped.is_empty() {
        return;
    }
    if let Err(e) = std::fs::create_dir_all(DUMP_DIR) {
        log::warn!("nowhere: keystore export dir {DUMP_DIR}: {e:?}");
        return;
    }
    for (ns, body) in dumped {
        let path = format!("{DUMP_DIR}/{ns}.keys");
        match write_bundle(&path, ns, unit, &body) {
            Ok(n) => log::info!("nowhere: keystore exported ns {ns} -> {path} ({n} key rows) (#210)"),
            Err(e) => log::warn!("nowhere: keystore export ns {ns} failed: {e:?}"),
        }
    }
}

/// Where nowhere_roamd stages a restored bundle for import: `<ns>.keys`, keyed by the NEW login's app uid.
const IMPORT_DIR: &str = "/data/misc/keystore/nowhere-import";

/// Try to import a staged bundle for `namespace`, called on a key-lookup MISS for a Domain::APP key.
/// Returns true if anything was imported, in which case the caller retries the lookup once.
///
/// Lazy-on-miss rather than at a fixed moment because there is no earlier point at which the new login's app
/// uid is even known: the app is reinstalled during the roam and its appId is assigned then. This mirrors
/// what LegacyImporter already does for old-format blobs.
///
/// ONE-SHOT: the file is removed whatever happens -- imported, rejected or malformed -- so a bundle can never
/// be replayed onto a later, unrelated uid that happens to reuse the number.
pub fn try_import(db: &mut KeystoreDB, namespace: i64) -> bool {
    let path = format!("{IMPORT_DIR}/{namespace}.keys");
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(_) => return false, // the overwhelmingly common case: no bundle for this uid
    };
    let _ = std::fs::remove_file(&path);
    let unit = read_unit();
    match parse_bundle(&text, &unit, namespace) {
        Ok(keys) if keys.is_empty() => false,
        Ok(keys) => match db.nowhere_import_keys(namespace, &keys) {
            Ok(n) => {
                log::info!("nowhere: keystore imported {n} key(s) into ns {namespace} (#210)");
                n > 0
            }
            Err(e) => {
                log::warn!("nowhere: keystore import into ns {namespace} failed: {e:?}");
                false
            }
        },
        Err(e) => {
            log::warn!("nowhere: keystore bundle for ns {namespace} rejected: {e}");
            false
        }
    }
}

/// Parse + VET a v1 bundle. Rejects rather than imports whenever anything is off, because the failure this
/// guards against is asymmetric: a missing key makes an app ask you to sign in, while a key that is present
/// but unusable makes it fail on use -- often in a retry loop with no path back to a login screen.
fn parse_bundle(text: &str, unit: &str, want_ns: i64) -> std::result::Result<Vec<NowhereKey>, String> {
    let mut lines = text.lines();
    if lines.next() != Some("v1") {
        return Err("not a v1 bundle".into());
    }
    let mut saw_unit = false;
    let mut keys: Vec<NowhereKey> = Vec::new();
    let mut idx: std::collections::HashMap<i64, usize> = Default::default();
    for line in lines {
        let f: Vec<&str> = line.split('\t').collect();
        match f.first().copied() {
            Some("unit") => {
                // The device gate. A KeyMint blob is bound to the TEE that made it, so a bundle from another
                // handset can only ever produce keys that fail on first use.
                if f.len() < 2 || unit.is_empty() || f[1] != unit {
                    return Err("bundle is stamped for a different device".into());
                }
                saw_unit = true;
            }
            Some("ns") => {
                // #210 p2 (BUG B, DIA-20260729): the bundle stamps the EXPORTING uid, but the app is
                // reinstalled every roam and assigned a FRESH appId, so its uid -- which IS the keystore
                // namespace -- differs on import. The real target is `want_ns` (the current uid):
                // nowhere_import_keys inserts under it, roamd already named the file by it, and the unit
                // stamp binds the device. So the internal ns is informational -- do NOT reject on a
                // mismatch, which is the NORMAL cross-roam case (rejecting refused EVERY carried bundle;
                // roamd's staging comment always intended keystore2 to adapt the ns "to match its own
                // view", not to reject it).
                if f.get(1).and_then(|s| s.parse::<i64>().ok()) != Some(want_ns) {
                    log::debug!("nowhere: roam bundle ns {:?} adapted to target {want_ns} (uid drifts per roam)", f.get(1));
                }
            }
            Some("key") if f.len() >= 6 => {
                idx.insert(f[1].parse().map_err(|_| "bad key id")?, keys.len());
                keys.push(NowhereKey {
                    alias_hex: f[2].to_string(),
                    key_type: f[3].parse().map_err(|_| "bad key_type")?,
                    km_uuid_hex: f[5].to_string(),
                    params: Vec::new(),
                    meta: Vec::new(),
                    blobs: Vec::new(),
                    blob_meta: Vec::new(),
                });
            }
            Some("kp") | Some("km") if f.len() >= 6 => {
                let k = *idx.get(&f[1].parse().map_err(|_| "bad kp key id")?).ok_or("orphan row")?;
                let cell = NowhereCell { ty: f[4].to_string(), val: f[5].to_string() };
                let tag: i64 = f[2].parse().map_err(|_| "bad tag")?;
                if f[0] == "kp" {
                    keys[k].params.push((tag, f[3].parse().unwrap_or(-1), cell));
                } else {
                    keys[k].meta.push((tag, cell));
                }
            }
            Some("blob") if f.len() >= 6 => {
                let k = *idx.get(&f[1].parse().map_err(|_| "bad blob key id")?).ok_or("orphan blob")?;
                keys[k].blobs.push((
                    f[2].parse().map_err(|_| "bad blob id")?,
                    f[3].parse().map_err(|_| "bad subcomponent")?,
                    f[4].parse().unwrap_or(0),
                    f[5].to_string(),
                ));
            }
            Some("bm") if f.len() >= 6 => {
                let k = *idx.get(&f[1].parse().map_err(|_| "bad bm key id")?).ok_or("orphan bm")?;
                // Defence in depth: the export already refuses superencrypted keys, but a bundle is a file on
                // disk and this is the last chance to notice one before it becomes an unusable key.
                let tag: i64 = f[3].parse().map_err(|_| "bad bm tag")?;
                if tag == 0 {
                    return Err("bundle contains a superencrypted blob (EncryptedBy)".into());
                }
                keys[k].blob_meta.push((
                    f[2].parse().map_err(|_| "bad bm blob id")?,
                    tag,
                    NowhereCell { ty: f[4].to_string(), val: f[5].to_string() },
                ));
            }
            _ => {}
        }
    }
    if !saw_unit {
        return Err("bundle carries no device stamp".into());
    }
    Ok(keys)
}

/// v1 bundle: a header naming the format, the device and the namespace, then the rows database.rs produced.
/// Line-based and hex-encoded so it survives shell tooling intact -- the same shape the roamd prototype
/// wrote, so bundles from either producer are readable by the same eye.
fn write_bundle(path: &str, ns: i64, unit: &str, body: &str) -> Result<usize> {
    let mut f = std::fs::File::create(path)?;
    writeln!(f, "v1")?;
    writeln!(f, "unit\t{unit}")?;
    writeln!(f, "ns\t{ns}")?;
    f.write_all(body.as_bytes())?;
    f.sync_all()?;
    let mut perms = std::fs::metadata(path)?.permissions();
    std::os::unix::fs::PermissionsExt::set_mode(&mut perms, 0o600);
    std::fs::set_permissions(path, perms)?;
    Ok(body.lines().filter(|l| l.starts_with("key\t")).count())
}

/// #210 p2 (nowhere): CREATE-PATH import. Apps like Amazon's MAP create their identity keys directly via
/// generateKey and never do a get_key_entry lookup first, so the lazy get_key_entry import (try_import)
/// never fires for them -- their fresh keys shadow the carried ones and the app signs out on every roam.
/// generate_key calls this BEFORE it mints. If a staged bundle for `namespace` carries exactly `alias_hex`,
/// import that ONE key (so the app receives the carried key, not a fresh one) and consume it from the
/// bundle; the file is removed once empty. Returns true iff a key was imported, in which case the caller
/// loads it back and returns its metadata instead of generating. Returns false -- and generation proceeds
/// normally -- for any alias no bundle carries and for every app with no bundle (the common case: a stat).
///
/// Per-alias, not whole-bundle, because an app creates its aliases at different times; each is consumed as
/// it is asked for, and a later regeneration of an already-consumed alias correctly mints fresh. The daemon
/// stages the bundle keystore-owned so keystore2 can rewrite/remove it here.
pub fn try_import_create(db: &mut KeystoreDB, namespace: i64, alias_hex: &str) -> bool {
    let path = format!("{IMPORT_DIR}/{namespace}.keys");
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(_) => return false, // the overwhelmingly common case: no bundle staged for this uid
    };
    let unit = read_unit();
    let keys = match parse_bundle(&text, &unit, namespace) {
        Ok(k) => k,
        Err(e) => {
            log::warn!("nowhere: keystore create bundle for ns {namespace} rejected: {e}");
            let _ = std::fs::remove_file(&path); // a bad bundle is rejected once, never retried
            return false;
        }
    };
    let want = match keys.iter().find(|k| k.alias_hex.eq_ignore_ascii_case(alias_hex)) {
        Some(k) => k,
        None => return false, // bundle carries other aliases, not this one -> mint normally, keep it
    };
    match db.nowhere_import_keys(namespace, std::slice::from_ref(want)) {
        Ok(n) if n > 0 => {
            log::info!("nowhere: keystore create-imported 1 key into ns {namespace} (#210)");
            consume_alias(&path, &text, alias_hex);
            true
        }
        Ok(_) => false,
        Err(e) => {
            log::warn!("nowhere: keystore create-import into ns {namespace} failed: {e:?}");
            false
        }
    }
}

/// Remove one just-imported alias's rows from a staged bundle so each alias is consumed exactly once; the
/// file is deleted once no `key` rows remain. Every row (`key`/`kp`/`km`/`blob`/`bm`) carries its key's
/// bundle-local id in field 1, so dropping the alias means dropping every row whose id matches the `key`
/// row that bears `alias_hex`. Best-effort: a failed rewrite risks only a duplicate import on a later
/// regenerate, never a wrong key. Requires the bundle keystore-writable (nowhere_roamd stages it so).
fn consume_alias(path: &str, text: &str, alias_hex: &str) {
    let mut drop_ids: std::collections::HashSet<&str> = Default::default();
    for line in text.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        if f.first().copied() == Some("key") && f.len() >= 3 && f[2].eq_ignore_ascii_case(alias_hex) {
            drop_ids.insert(f[1]);
        }
    }
    let mut kept_key = false;
    let mut out = String::new();
    for line in text.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        let is_row = matches!(f.first().copied(), Some("key" | "kp" | "km" | "blob" | "bm"));
        if is_row && f.len() >= 2 && drop_ids.contains(f[1]) {
            continue; // a row belonging to the consumed alias
        }
        if f.first().copied() == Some("key") {
            kept_key = true;
        }
        out.push_str(line);
        out.push('\n');
    }
    if kept_key {
        if let Err(e) = std::fs::write(path, out) {
            log::warn!("nowhere: keystore bundle rewrite {path} failed: {e:?}");
        }
    } else {
        let _ = std::fs::remove_file(path); // last alias consumed
    }
}
RUST

# --- 2. register the module --------------------------------------------------------------------------
if ! grep -qF "pub mod nowhere_roam;" "$LIB"; then
  sed -i 's|^pub mod metrics;|pub mod metrics;\npub mod nowhere_roam;|' "$LIB"
  grep -qF "pub mod nowhere_roam;" "$LIB" || { echo "[keystore-roam] failed to register module in lib.rs" >&2; exit 1; }
fi

# --- 3. the DB half: dump rows for the opted-in namespaces of one user --------------------------------
# (Superseded by NWP-20260830-03: there is no opt-in; this dumps every APP namespace of the user. The Rust
# doc comments injected below and in step 4 still say "opted-in"; they are patched source, so changing them
# would mean a PATCH_VERSION bump and a build-host revert for no behaviour change.)
python3 - "$DB" <<'PY'
import sys, io
path = sys.argv[1]
src = io.open(path, encoding='utf-8').read()
sig = "    pub fn list_past_alias("
assert sig in src, "list_past_alias anchor not found -- upstream moved it, patch by hand"

# Anchor on list_past_alias's DOC BLOCK plus its signature, not the bare signature. Anchoring on the
# signature alone inserted our method between that function's `///` block and the function itself: rustc then
# read those docs as documenting OUR method and failed the crate's deny(missing_docs) on the now-undocumented
# original. Walk back over the contiguous `///` lines so the pair stays intact.
lines = src.split("\n")
idx = next(i for i, l in enumerate(lines) if l.startswith(sig))
start = idx
while start > 0 and lines[start - 1].lstrip().startswith("///"):
    start -= 1
anchor = "\n".join(lines[start:idx + 1])

method = r'''
    /// #210 p2 (nowhere): dump the CARRYABLE keys of `user`'s opted-in APP namespaces as
    /// (namespace, bundle-body). Called from SuperKeyManager::remove_user IMMEDIATELY BEFORE
    /// unbind_keys_for_user deletes these rows -- the last moment the blobs exist.
    ///
    /// A key is carryable only if NO blob of it carries a BlobMetaEntry EncryptedBy row (tag 0). Such a blob
    /// is superencrypted under the OLD user's LSKF-derived super key, which the next login's user does not
    /// have, so restoring it would give the app a key that EXISTS BUT CANNOT BE USED -- an outcome apps
    /// handle far worse than a missing key (InvalidKeyException, often with no re-login path). The check is
    /// made against the metadata directly rather than by re-deriving super_encryption_required, so it stays
    /// correct whichever policy caused the wrapping.
    ///
    /// Read-only. Types are preserved (`data ANY` columns can be integer, text, blob or null) so the import
    /// can reconstruct rows exactly; blobs are hex so the bundle stays line-oriented.
    pub fn nowhere_dump_user_keys(
        &mut self,
        user: AndroidUserId,
        keep: &[i64],
    ) -> Result<Vec<(i64, String)>> {
        let _wp = wd::watch("KeystoreDB::nowhere_dump_user_keys");
        // NWP-20260830-03: an EMPTY `keep` now means EVERY namespace of this user, where it used to mean
        // NONE. That inversion is the whole "always carry" change, and it is safe because the query below is
        // already tightly scoped -- domain APP, live client keys, this user, and carryable-only (no
        // hardware-bound blob). export_for_namespace still passes a single-element slice, so it is unaffected.
        let carryable = "NOT EXISTS (SELECT 1 FROM persistent.blobentry be
                              JOIN persistent.blobmetadata bm ON bm.blobentryid = be.id
                             WHERE be.keyentryid = ke.id AND bm.tag = 0)";
        let key_q = format!(
            "SELECT ke.id, ke.namespace, hex(ke.alias), ke.key_type, ke.state, hex(ke.km_uuid)
               FROM persistent.keyentry ke
              WHERE ke.domain = ? AND ke.key_type = ? AND ke.state = ?
                AND cast ( (ke.namespace/{AID_USER_OFFSET}) as int) = ?
                AND {carryable};"
        );
        self.with_transaction(TransactionBehavior::Deferred, |tx| {
            let mut keys: Vec<(i64, i64, String)> = Vec::new(); // (key id, namespace, header line)
            {
                let mut stmt = tx.prepare(&key_q).context(ks_err!("prepare key query"))?;
                let mut rows = stmt
                    .query(params![
                        Domain::APP.0 as u32,
                        KeyType::Client,
                        KeyLifeCycle::Live,
                        user.0
                    ])
                    .context(ks_err!("query keys"))?;
                db_utils::with_rows_extract_all(&mut rows, |row| {
                    let id: i64 = row.get(0).context("key id")?;
                    let ns: i64 = row.get(1).context("namespace")?;
                    let alias: String = row.get(2).context("alias")?;
                    let kt: i64 = row.get(3).context("key_type")?;
                    let st: i64 = row.get(4).context("state")?;
                    let uuid: String = row.get(5).context("km_uuid")?;
                    if keep.is_empty() || keep.contains(&ns) {
                        keys.push((id, ns, format!("key\t{id}\t{alias}\t{kt}\t{st}\t{uuid}\n")));
                    }
                    Ok(())
                })
                .context(ks_err!("extract keys"))?;
            }
            if keys.is_empty() {
                return Ok(Vec::new()).no_gc();
            }
            // `data ANY` -> keep the sqlite type tag so the import round-trips integers, text, blobs and
            // nulls faithfully instead of guessing from the byte pattern.
            let typed = "typeof(t.data), case typeof(t.data)
                             when 'integer' then cast(t.data as text)
                             when 'null'    then ''
                             else hex(t.data) end";
            let mut out: std::collections::BTreeMap<i64, String> = std::collections::BTreeMap::new();
            for (id, ns, header) in keys {
                // Built locally, then appended: a closure capturing `body` would hold a mutable borrow
                // across the blob queries below, which borrowck rejects.
                let mut body = String::new();
                body.push_str(&header);
                for (tag, sql) in [
                    (
                        // security_level is an INTEGER; cast to text so the shared extractor below (which
                        // reads column 1 as a String, matching km's '' literal) doesn't hit
                        // "Invalid column type Integer". The import parses it back with .parse().
                        "kp",
                        format!(
                            "SELECT t.tag, cast(ifnull(t.security_level,-1) as text), {typed}
                               FROM persistent.keyparameter t WHERE t.keyentryid = ?;"
                        ),
                    ),
                    (
                        "km",
                        format!(
                            "SELECT t.tag, '', {typed}
                               FROM persistent.keymetadata t WHERE t.keyentryid = ?;"
                        ),
                    ),
                ] {
                    let mut stmt = tx.prepare(&sql).context(ks_err!("prepare row query"))?;
                    let mut rows = stmt.query(params![id]).context(ks_err!("query rows"))?;
                    db_utils::with_rows_extract_all(&mut rows, |row| {
                        let a: i64 = row.get(0).context("tag")?;
                        let b: String = row.get(1).context("sec")?;
                        let c: String = row.get(2).context("type")?;
                        let d: String = row.get(3).context("data")?;
                        body.push_str(&format!("{tag}\t{id}\t{a}\t{b}\t{c}\t{d}\n"));
                        Ok(())
                    })
                    .context(ks_err!("extract rows"))?;
                }
                {
                    let mut stmt = tx
                        .prepare(
                            "SELECT b.id, b.subcomponent_type, ifnull(b.state,0), hex(b.blob)
                               FROM persistent.blobentry b WHERE b.keyentryid = ?;",
                        )
                        .context(ks_err!("prepare blob query"))?;
                    let mut rows = stmt.query(params![id]).context(ks_err!("query blobs"))?;
                    db_utils::with_rows_extract_all(&mut rows, |row| {
                        let bid: i64 = row.get(0).context("blob id")?;
                        let sub: i64 = row.get(1).context("subcomponent")?;
                        let st: i64 = row.get(2).context("state")?;
                        let hex: String = row.get(3).context("blob")?;
                        body.push_str(&format!("blob\t{id}\t{bid}\t{sub}\t{st}\t{hex}\n"));
                        Ok(())
                    })
                    .context(ks_err!("extract blobs"))?;
                }
                {
                    let mut stmt = tx
                        .prepare(
                            "SELECT m.blobentryid, m.tag, typeof(m.data), case typeof(m.data)
                                        when 'integer' then cast(m.data as text)
                                        when 'null'    then ''
                                        else hex(m.data) end
                               FROM persistent.blobmetadata m
                               JOIN persistent.blobentry b ON b.id = m.blobentryid
                              WHERE b.keyentryid = ?;",
                        )
                        .context(ks_err!("prepare blobmeta query"))?;
                    let mut rows = stmt.query(params![id]).context(ks_err!("query blobmeta"))?;
                    db_utils::with_rows_extract_all(&mut rows, |row| {
                        let bid: i64 = row.get(0).context("blobentryid")?;
                        let tag: i64 = row.get(1).context("tag")?;
                        let ty: String = row.get(2).context("type")?;
                        let val: String = row.get(3).context("data")?;
                        body.push_str(&format!("bm\t{id}\t{bid}\t{tag}\t{ty}\t{val}\n"));
                        Ok(())
                    })
                    .context(ks_err!("extract blobmeta"))?;
                }
                out.entry(ns).or_default().push_str(&body);
            }
            Ok(out.into_iter().collect::<Vec<_>>()).no_gc()
        })
    }

'''
src = src.replace(anchor, method + anchor, 1)
io.open(path, 'w', encoding='utf-8', newline='\n').write(src)
print("[keystore-roam] database.rs: added nowhere_dump_user_keys")
PY

# --- 4. hook it in, at the last moment the blobs exist ------------------------------------------------
python3 - "$SK" <<'PY'
import sys, io
path = sys.argv[1]
src = io.open(path, encoding='utf-8').read()
anchor = '        db.unbind_keys_for_user(user).context(ks_err!("Error in unbinding keys for {user:?}"))?;'
assert anchor in src, "remove_user anchor not found -- patch by hand"
hook = '''        // #210 p2 (nowhere): dump the opted-in apps' carryable keys BEFORE they are deleted -- this is
        // the last moment the blobs exist. Best-effort by construction: export_for_user swallows its own
        // errors, because losing a carry-over is a missing convenience while a failure escaping remove_user
        // would break user deletion, which is a core amnesia guarantee.
        crate::nowhere_roam::export_for_user(db, user);
'''
src = src.replace(anchor, hook + anchor, 1)
io.open(path, 'w', encoding='utf-8', newline='\n').write(src)
print("[keystore-roam] super_key.rs: export hooked into remove_user")
PY

# --- 4b. PRIMARY hook: clear_namespace (per-app uninstall) -- the real moment a roamed app's keys die ---
python3 - "$KS/src/maintenance.rs" <<'PY'
import sys, io
path = sys.argv[1]
src = io.open(path, encoding='utf-8').read()
anchor = '        DB.with(|db| db.borrow_mut().unbind_keys_for_namespace(domain, nspace))'
assert anchor in src, "clear_namespace anchor not found -- upstream moved it, patch by hand"
hook = '''        // #210 p2 (nowhere, DIA-20260728-16): PRIMARY export hook. A roamed app is UNINSTALLED during the
        // reap, which lands here (clear_namespace) BEFORE the bulk remove_user, so this is where an opted-in
        // app's keys actually die -- dump them immediately before unbind. Best-effort: export_for_namespace
        // swallows its own errors and only touches opted-in APP namespaces, so it never disturbs a clear.
        DB.with(|db| crate::nowhere_roam::export_for_namespace(&mut db.borrow_mut(), domain, nspace));
'''
src = src.replace(anchor, hook + anchor, 1)
io.open(path, 'w', encoding='utf-8', newline='\n').write(src)
print("[keystore-roam] maintenance.rs: export hooked into clear_namespace (primary)")
PY

# --- 5. the import half: bundle row types + the insert ------------------------------------------------
python3 - "$DB" <<'PY'
import sys, io
path = sys.argv[1]
src = io.open(path, encoding='utf-8').read()

# Module-level types, appended at the end of the file: no anchor to rot, and nothing to insert between a
# doc comment and the item it documents.
types = r'''

/// #210 p2 (nowhere): one `data ANY` cell carried in a roam bundle -- the sqlite type tag plus its value as
/// text (decimal for integers, hex otherwise). Keeping the tag is what lets an import reconstruct the row
/// EXACTLY rather than guessing a type from the byte pattern.
pub struct NowhereCell {
    /// sqlite typeof(): "integer", "text", "blob" or "null".
    pub ty: String,
    /// Decimal for integers, hex for text/blob, empty for null.
    pub val: String,
}

/// #210 p2 (nowhere): one key from a roam bundle, with every row needed to rebuild it under a new uid.
pub struct NowhereKey {
    /// hex of the original alias blob -- the name the app looks the key up by, so it must survive verbatim.
    pub alias_hex: String,
    /// keyentry.key_type.
    pub key_type: i64,
    /// hex of the owning KeyMint instance uuid.
    pub km_uuid_hex: String,
    /// (tag, security_level, value) from keyparameter.
    pub params: Vec<(i64, i64, NowhereCell)>,
    /// (tag, value) from keymetadata.
    pub meta: Vec<(i64, NowhereCell)>,
    /// (bundle-local blob id, subcomponent_type, state, hex blob) from blobentry.
    pub blobs: Vec<(i64, i64, i64, String)>,
    /// (bundle-local blob id, tag, value) from blobmetadata.
    pub blob_meta: Vec<(i64, i64, NowhereCell)>,
}

/// Decode the hex a roam bundle carries. Rejects odd lengths and non-hex rather than truncating: a silently
/// half-decoded key blob would install a key that fails only when the app tries to use it.
fn nowhere_hex(s: &str) -> Result<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return Err(KsError::sys()).context(ks_err!("odd-length hex in roam bundle"));
    }
    (0..s.len())
        .step_by(2)
        .map(|i| {
            u8::from_str_radix(&s[i..i + 2], 16)
                .map_err(|_| KsError::sys())
                .context(ks_err!("bad hex in roam bundle"))
        })
        .collect()
}

/// Bind a bundle cell back to the sqlite value it came from.
fn nowhere_value(c: &NowhereCell) -> Result<rusqlite::types::Value> {
    use rusqlite::types::Value;
    Ok(match c.ty.as_str() {
        "integer" => Value::Integer(
            c.val.parse().map_err(|_| KsError::sys()).context(ks_err!("bad integer in bundle"))?,
        ),
        "null" => Value::Null,
        "text" => Value::Text(
            String::from_utf8(nowhere_hex(&c.val)?)
                .map_err(|_| KsError::sys())
                .context(ks_err!("bad utf8 in bundle"))?,
        ),
        _ => Value::Blob(nowhere_hex(&c.val)?),
    })
}
'''
src = src + types

# The insert method, next to its export twin. Anchored on our OWN doc comment, which we control.
anchor = "    /// #210 p2 (nowhere): dump the CARRYABLE keys"
assert anchor in src, "export method missing -- run the export half first"

method = r'''    /// #210 p2 (nowhere): insert a VETTED roam bundle's keys under `namespace`, live and usable.
    ///
    /// The rows go back exactly as they came out, and keystore2's own load_key_parameters then rebuilds the
    /// typed KeyParameters from them -- so the round trip is faithful by construction rather than by our
    /// parsing being right. Ids are re-allocated through insert_with_retry (the same allocator the normal
    /// creation path uses), and blobmetadata is remapped onto the NEW blobentry ids, because the bundle's
    /// ids belong to a database that no longer exists.
    ///
    /// The caller has already checked the device stamp and rejected superencrypted blobs.
    pub fn nowhere_import_keys(&mut self, namespace: i64, keys: &[NowhereKey]) -> Result<usize> {
        let _wp = wd::watch("KeystoreDB::nowhere_import_keys");
        self.with_transaction(TransactionBehavior::Immediate("TX_nowhere_import"), |tx| {
            let mut done = 0usize;
            let mut need_gc = false;
            for k in keys {
                // #210 p2 (DIA-20260729, ROOT CAUSE of "app signs out on every roam"): keyentry.alias has
                // BLOB affinity but no coercion, so a bound value keeps its own storage class. Every keystore
                // lookup binds the alias from KeyDescriptor.alias (a String) as TEXT, and SQLite never equates
                // a BLOB to a TEXT even when the bytes are identical. Binding the alias as bytes stored it as a
                // BLOB, so load_key_entry_id's `alias = ?` (TEXT) never matched the imported row -> KEY_NOT_FOUND
                // -> generate_key fell through and minted a fresh key that shadowed the carried one, every roam.
                // Aliases are UTF-8 Strings over the AIDL, so rebuild the String and let it bind as TEXT, exactly
                // as the stock create path stores it. A non-UTF-8 alias could never match a TEXT lookup anyway.
                let alias = String::from_utf8(nowhere_hex(&k.alias_hex)?)
                    .ok()
                    .ok_or_else(KsError::sys)
                    .context(ks_err!("roam bundle alias is not valid UTF-8"))?;
                let uuid = nowhere_hex(&k.km_uuid_hex)?;
                // #210 p2 (DIA-20260803, ROOT CAUSE of "an on-demand app signs out on the tap"): the app can
                // already be RUNNING before its bundle lands, so the alias we are about to insert may ALREADY
                // exist. On the on-demand tap path gmscompat binds a Play-Services client's
                // GmsCompatClientService the moment installApks completes -- a minute before RESTORE-ODDATA
                // stages the bundle -- so the app starts against a still-empty namespace and mints its own
                // keys (proven odtest4: Ring's _androidx_security_master_key_ carries the install-instant
                // creation stamp). keyentry has NO UNIQUE on (domain, namespace, alias), so a bare INSERT then
                // leaves TWO Live rows for that alias and every later lookup dies in with_rows_extract_one
                // ("Unexpected row" -> SYSTEM_ERROR) -- which the app reads as a corrupt vault, so it
                // regenerates the lot and signs the user out: the exact failure the carry exists to prevent.
                // The CARRIED key is the user's real key (the fresh one only ever encrypted an empty vault),
                // so it WINS: unreference whatever holds this alias first, exactly as the stock create path's
                // rebind_alias does -- alias/domain/namespace NULLed and state Unreferenced, so the row is
                // unfindable and the GC reclaims its blob -- then insert ours as the only Live row.
                let shadowed = tx
                    .execute(
                        "UPDATE persistent.keyentry
                         SET alias = NULL, domain = NULL, namespace = NULL, state = ?
                         WHERE alias = ? AND domain = ? AND namespace = ? AND key_type = ?;",
                        params![
                            KeyLifeCycle::Unreferenced,
                            &alias,
                            Domain::APP.0 as u32,
                            namespace,
                            k.key_type
                        ],
                    )
                    .context(ks_err!("unreferencing a shadowing keyentry before import"))?;
                if shadowed > 0 {
                    // Unreferencing leaves the row's blobentry -- and its KeyMint-resident key -- alive until a
                    // GC pass runs, and only notify_gc starts one, which is why the stock create path threads
                    // rebind_alias's row count into do_gc rather than dropping it. Carry the same signal out.
                    // Log it as well: this displacement IS the fix firing, and the bug it repairs took a
                    // logcat + persistent.sqlite session to localise -- it should not land silently.
                    need_gc = true;
                    log::info!(
                        "nowhere: displaced {shadowed} shadowing key(s) for alias {alias} in ns {namespace} (#210)"
                    );
                }
                let key_id = Self::insert_with_retry(|id| {
                    tx.execute(
                        "INSERT into persistent.keyentry
                         (id, key_type, domain, namespace, alias, state, km_uuid)
                         VALUES(?, ?, ?, ?, ?, ?, ?);",
                        params![
                            id,
                            k.key_type,
                            Domain::APP.0 as u32,
                            namespace,
                            &alias,
                            KeyLifeCycle::Live,
                            &uuid
                        ],
                    )
                })
                .context(ks_err!("inserting imported keyentry"))?;

                for (tag, sec, cell) in &k.params {
                    tx.execute(
                        "INSERT into persistent.keyparameter (keyentryid, tag, data, security_level)
                         VALUES (?, ?, ?, ?);",
                        params![key_id, tag, nowhere_value(cell)?, sec],
                    )
                    .context(ks_err!("inserting imported keyparameter"))?;
                }
                for (tag, cell) in &k.meta {
                    tx.execute(
                        "INSERT into persistent.keymetadata (keyentryid, tag, data) VALUES (?, ?, ?);",
                        params![key_id, tag, nowhere_value(cell)?],
                    )
                    .context(ks_err!("inserting imported keymetadata"))?;
                }
                let mut blob_ids: std::collections::HashMap<i64, i64> = Default::default();
                for (old_id, sub, state, hex) in &k.blobs {
                    tx.execute(
                        "INSERT into persistent.blobentry (subcomponent_type, keyentryid, blob, state)
                         VALUES (?, ?, ?, ?);",
                        params![sub, key_id, nowhere_hex(hex)?, state],
                    )
                    .context(ks_err!("inserting imported blobentry"))?;
                    blob_ids.insert(*old_id, tx.last_insert_rowid());
                }
                for (old_blob, tag, cell) in &k.blob_meta {
                    // An orphan would silently drop the KmUuid that tells keystore2 which KeyMint instance
                    // owns the blob, so refuse the whole import rather than land a key missing its metadata.
                    let new_blob = blob_ids.get(old_blob).ok_or_else(KsError::sys).context(ks_err!(
                        "roam bundle blobmetadata references an absent blob"
                    ))?;
                    tx.execute(
                        "INSERT into persistent.blobmetadata (blobentryid, tag, data) VALUES (?, ?, ?);",
                        params![new_blob, tag, nowhere_value(cell)?],
                    )
                    .context(ks_err!("inserting imported blobmetadata"))?;
                }
                done += 1;
            }
            Ok(done).do_gc(need_gc)
        })
    }

'''
src = src.replace(anchor, method + anchor, 1)
io.open(path, 'w', encoding='utf-8', newline='\n').write(src)
print("[keystore-roam] database.rs: added nowhere_import_keys + bundle types")
PY

# --- 6. hook the import onto a key-lookup miss --------------------------------------------------------
python3 - "$KS/src/service.rs" <<'PY'
import sys, io
path = sys.argv[1]
src = io.open(path, encoding='utf-8').read()
anchor = """        let (key_id_guard, mut key_entry) = DB
            .with(|db| {
                LEGACY_IMPORTER.with_try_import(key, caller_uid, super_key, || {
                    db.borrow_mut().load_key_entry(
                        key,
                        KeyType::Client,
                        KeyEntryLoadBits::PUBLIC,
                        caller_uid,
                        |k, av| check_key_permission(KeyPerm::GetInfo, k, &av),
                    )
                })
            })
            .context(ks_err!("while trying to load key info."))?;"""
assert anchor in src, "get_key_entry anchor not found -- patch by hand"

new = """        // #210 p2 (nowhere): an app whose keys were carried across a roam looks them up here FIRST, and
        // misses -- the keys live in a bundle in the store, not yet in this database. On a miss, try to
        // import the bundle staged for this uid and look up exactly once more. Lazy-on-miss because the
        // app's uid is not knowable any earlier: it is reinstalled during the roam and assigned a fresh
        // appId. Same shape as LEGACY_IMPORTER's with_try_import, which solves the same problem for
        // old-format blobs. try_import is a cheap stat() when there is no bundle, which is the normal case.
        // super_key is cloned rather than moved so this closure stays Fn and can run twice -- once before
        // the import attempt and once after.
        let load = |db: &std::cell::RefCell<crate::database::KeystoreDB>| {
            LEGACY_IMPORTER.with_try_import(key, caller_uid, super_key.clone(), || {
                db.borrow_mut().load_key_entry(
                    key,
                    KeyType::Client,
                    KeyEntryLoadBits::PUBLIC,
                    caller_uid,
                    |k, av| check_key_permission(KeyPerm::GetInfo, k, &av),
                )
            })
        };
        let (key_id_guard, mut key_entry) = DB
            .with(|db| {
                // #210 p2 (DIA-20260803): consume a staged bundle BEFORE the lookup, not only after a miss.
                // On-miss alone is not enough once an app can RUN before its bundle lands (the on-demand tap
                // path: gmscompat binds a Play-Services client's GmsCompatClientService at install, a minute
                // before RESTORE-ODDATA stages the bundle), because the app mints the very aliases it will
                // then look up -- so the lookup HITS its own fresh key, never misses, and the carried bundle
                // is never consumed at all: the user is silently signed out with their real keys sitting
                // unread on disk. Importing first makes the carry authoritative regardless of whether the app
                // reads or creates first, which is the invariant this whole carry depends on (nowhere_roam's
                // import unreferences a shadowing alias, so the carried key replaces the minted one). Still a
                // cheap stat() and ONE-SHOT -- the bundle is removed on the first attempt, so this is a stat
                // on every APP lookup and real work only in the one beat after a roam. The on-miss retry
                // below is kept: it costs nothing once the bundle is gone and preserves the proven
                // login-path behaviour for a bundle staged mid-lookup.
                if key.domain == Domain::APP {
                    crate::nowhere_roam::try_import(&mut db.borrow_mut(), caller_uid.0);
                }
                load(db).or_else(|e| {
                    if key.domain == Domain::APP
                        && crate::nowhere_roam::try_import(&mut db.borrow_mut(), caller_uid.0)
                    {
                        load(db)
                    } else {
                        Err(e)
                    }
                })
            })
            .context(ks_err!("while trying to load key info."))?;"""
# DIA-20260730: get_key_entry(miss) import hook RE-ENABLED for EAGER import. The clean-cycle trace (odtest9
# user28->29, correct key carried) proved MAP's LocalDataStorageEncryptor LOADS its RSA key on launch, MISSES
# (the create-hook fires only on generate_key), and CLEARS the account DB + regenerates a few ms BEFORE the
# create-hook lands the key -- so the account is wiped regardless of the now-correct key. Importing on the LOOKUP
# miss puts the key in place BEFORE MAP decides to clear. The odtest6 "dup" that got this disabled was a BLOB-alias
# artifact (the import stored the alias as a BLOB, so MAP's re-lookup STILL missed and it minted fresh); with the
# BLOB->TEXT fix (section on nowhere_import_keys) the imported key is findable, so the re-lookup returns it and
# nothing mints a duplicate. The create-hook (section 7) stays ON to cover any pure generate_key path.
src = src.replace(anchor, new, 1)
io.open(path, 'w', encoding='utf-8', newline='\n').write(src)
print("[keystore-roam] service.rs: get_key_entry miss-hook RE-ENABLED (eager import before MAP's clear, DIA-20260730)")
PY

# --- 7. CREATE-PATH import: generate_key returns a carried key instead of minting -----------------------
# The get_key_entry hook (section 6) only fires when an app LOOKS UP a key and misses. Amazon's MAP creates
# its identity keys directly via generateKey and never does that lookup, so that hook never fires for it and
# its fresh keys shadow the carried ones -- proven on lynx (DIA-20260728-19..): with the perms fixed the
# bundle staged and MAP still minted fresh, ns unchanged, no import line. This hooks the CREATE path too.
python3 - "$KS/src/security_level.rs" <<'PY'
import sys, io
path = sys.argv[1]
src = io.open(path, encoding='utf-8').read()

# (a) call the create-path import at the top of generate_key, just after the Rebind permission gate and
#     before any attestation/generation. Anchored on generate_key's unique Rebind + attestation_key_info pair
#     (import_key's Rebind carries a different ks_err! message; the third Rebind is followed by other code).
call_anchor = '''        check_key_permission(KeyPerm::Rebind, &key, &None).context(ks_err!())?;

        let attestation_key_info = match (key.domain, attest_key_descriptor) {'''
assert call_anchor in src, "generate_key Rebind/attestation anchor not found -- patch by hand"
call = '''        check_key_permission(KeyPerm::Rebind, &key, &None).context(ks_err!())?;

        // #210 p2 (nowhere): before minting, hand back a roam-carried key if a bundle is staged for this
        // exact (app namespace, alias). MAP and apps like it create their identity keys directly here,
        // never via a get_key_entry lookup, so the get_key_entry import (section 6) cannot fire for them --
        // without this their fresh keys shadow the carried ones and the app signs out on every roam.
        // Fail-safe: returns None (fall through to normal generation) for any alias no bundle carries and
        // every app with no bundle. AppUid is rebuilt from the field so `caller_uid` is not moved.
        if key.domain == Domain::APP {
            if let Some(km) = self.nowhere_import_on_create(&key, AppUid(caller_uid.0)) {
                return Ok(km);
            }
        }

        let attestation_key_info = match (key.domain, attest_key_descriptor) {'''
src = src.replace(call_anchor, call, 1)

# (b) the method, inserted just before store_new_key in the same inherent impl block.
method_anchor = '''    fn store_new_key(
        &self,
        key: KeyDescriptor,
        creation_result: KeyCreationResult,'''
assert method_anchor in src, "store_new_key anchor not found -- patch by hand"
method = '''    /// #210 p2 (nowhere): on the CREATE path, return a roam-carried key instead of minting a fresh one.
    /// generate_key calls this before it generates. If a staged bundle carries exactly this (namespace,
    /// alias), import that one key and return its metadata in the same shape store_new_key would -- a
    /// KEY_ID descriptor plus the key's own authorizations -- so the app receives the carried key and can
    /// decrypt what it sealed before the roam. Returns None (and generation proceeds normally) for any
    /// alias no bundle carries, for every app with no bundle, and on ANY error: a broken or missing bundle
    /// must never fail a legitimate key generation.
    fn nowhere_import_on_create(
        &self,
        key: &KeyDescriptor,
        caller_uid: AppUid,
    ) -> Option<KeyMetadata> {
        let alias = key.alias.as_ref()?;
        let alias_hex: String = alias.as_bytes().iter().map(|b| format!("{b:02X}")).collect();
        let ns = caller_uid.0;
        DB.with::<_, Option<KeyMetadata>>(|db| {
            if !crate::nowhere_roam::try_import_create(&mut db.borrow_mut(), ns, &alias_hex) {
                return None;
            }
            // The carried key now lives under (APP, ns, alias). Load it back and return the same metadata
            // shape the normal creation path does. Any failure here yields None -> normal generation.
            let (key_id_guard, mut key_entry) = match db.borrow_mut().load_key_entry(
                key,
                KeyType::Client,
                KeyEntryLoadBits::PUBLIC,
                caller_uid,
                |k, av| check_key_permission(KeyPerm::Rebind, k, &av),
            ) {
                Ok(v) => v,
                Err(e) => {
                    log::warn!("nowhere: keystore create-import load-back for ns {ns} failed: {e:?}");
                    return None;
                }
            };
            let modification = key_entry.metadata().creation_date().map(|d| d.to_millis_epoch())?;
            Some(KeyMetadata {
                key: KeyDescriptor {
                    domain: Domain::KEY_ID,
                    nspace: key_id_guard.id(),
                    ..Default::default()
                },
                keySecurityLevel: self.security_level,
                certificate: key_entry.take_cert(),
                certificateChain: key_entry.take_cert_chain(),
                authorizations: crate::utils::key_parameters_to_authorizations(
                    key_entry.into_key_parameters(),
                ),
                modificationTimeMs: modification,
            })
        })
    }

'''
src = src.replace(method_anchor, method + method_anchor, 1)
io.open(path, 'w', encoding='utf-8', newline='\n').write(src)
print("[keystore-roam] security_level.rs: create-path import hooked into generate_key")
PY

# --- 8. NWP-20260826-11: the app-namespace key CENSUS ---------------------------------------------------
# WHY THIS EXISTS. "Keep me signed in" (nowhere-keepkeys.list -> #keys) is offered on every kept, non-Google
# app, and for most of them it is INERT: an app that never touches Android Keystore has nothing to carry, so
# the switch promises something it cannot deliver. Chester, 2026-08-25: "not have this option unless its
# something similar to Amazon as the current setting is misleading/invalid."
# (Superseded by NWP-20260830-03: the switch and nowhere-keepkeys.list are gone, every namespace is carried,
# and nothing reads this census any more. Retiring it is tracked as NWP-20260830-04.)
#
# WHY THE CHOOSER CANNOT JUST ASK. There is no way to ask keystore2 "does namespace N hold any keys". The
# AIDL surface is per-CALLER by construction -- listEntries is gated on the caller OWNING the namespace
# (check_key_permission(KeyPerm::GetInfo) against the caller uid), so an app can enumerate its own keys and
# nothing else can enumerate anybody's. There is no device-owner door and no signature door. Same shape as
# the GosPackageState read problem in NWP-20260821-17, and the same answer: patch the daemon.
#
# WHAT THIS ADDS. keystore2 writes an append-only census of the app namespaces that have held a key, one
# decimal uid per line at /data/misc/keystore/nowhere-ns-keys, plus a bootstrap scan at start so the file is
# a derived VIEW of the database rather than a cache nobody re-checks.
#
# WHY A FILE, NOT A NEW AIDL METHOD. A new call means a new interface, a new permission, and a SELinux hole
# from a shell domain into the keystore domain -- for a boolean the chooser needs only to paint a switch. A
# 0644 file under keystore_data_file is the channel this module ALREADY uses in both directions (UNIT_PATH is
# written by roamd and read here; the removed KEEP_PATH was the same shape), and endospore_priv already holds
# read on that type, so
# the census needs no sepolicy change at all.
#
# PRIVACY. Uids, never package names -- keystore2 has no PackageManager and should not grow one. A uid is
# user-scoped (user * AID_USER_OFFSET + appid), so an entry can only ever match the session that created it:
# a later session reads its own uids and finds nothing of its predecessor. NOTHING here says whether a
# profile exists, so it cannot touch the blind-login property.
python3 - "$KS/src/nowhere_roam.rs" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8', newline='').read()
if 'nowhere-ns-keys' in s:
    sys.exit('nowhere_roam.rs already carries the census')
s += r'''
// ---------------------------------------------------------------------------------------------------
// NWP-20260826-11: the app-namespace key census. See the section header in keystore-roam.sh for the why.
// ---------------------------------------------------------------------------------------------------

/// Every app namespace (uid) known to hold a key, one decimal per line. Read by the nowhere_roamd RO-lane
/// worker (`keystorens`) and served to the chooser as GET-KEYSTORE-NS.
const CENSUS_PATH: &str = "/data/misc/keystore/nowhere-ns-keys";

/// The uids already written. Process-global on purpose: `KeystoreDB` is THREAD-LOCAL here (globals.rs
/// `thread_local! { pub static DB }`), so a per-DB set would be per-binder-thread and would re-append the
/// same uid once per thread. A `Mutex<HashSet>` is contended only on the first key of each uid.
static CENSUS: std::sync::OnceLock<std::sync::Mutex<std::collections::HashSet<i64>>> =
    std::sync::OnceLock::new();

fn census_cell() -> &'static std::sync::Mutex<std::collections::HashSet<i64>> {
    CENSUS.get_or_init(|| std::sync::Mutex::new(std::collections::HashSet::new()))
}

fn append_ns(ns: i64) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o644) // as UNIT_PATH: the reader is root, so this is symmetry rather than access control
        .open(CENSUS_PATH)?;
    writeln!(f, "{ns}")
}

/// Record that `ns` holds a key. Called from every path that inserts a keyentry row.
///
/// BEST-EFFORT AND SILENT BY DESIGN. This runs INSIDE the key-creation transaction, so it must never fail a
/// key creation: every error is swallowed, and a poisoned mutex is stepped over rather than propagated.
///
/// IT CAN OVER-REPORT, AND THAT IS THE SAFE DIRECTION. Hooking inside the transaction means a rollback --
/// or one of `with_transaction`'s BUSY retries -- can leave a uid recorded whose key was never committed.
/// The cost of a false positive is a switch that does nothing, which is exactly today's behaviour for every
/// app; the cost of a false NEGATIVE is a working switch hidden from the user. Hooking the single choke
/// point rather than the three success paths trades the first for the second on purpose, and keeps a future
/// caller of `create_key_entry_internal` counted without anyone remembering to add it.
pub fn note_app_key(domain: Domain, ns: i64) {
    if domain != Domain::APP || ns <= 0 {
        return; // SELINUX namespaces are not apps and have no switch to paint
    }
    let mut set = match census_cell().lock() {
        Ok(s) => s,
        Err(poisoned) => poisoned.into_inner(),
    };
    if set.contains(&ns) {
        return; // steady state: one hash lookup, no I/O
    }
    // Insert only AFTER the append lands. Recording it first would mean a failed write is never retried and
    // the uid is missing from the census forever, with nothing anywhere to say so.
    match append_ns(ns) {
        Ok(()) => {
            set.insert(ns);
        }
        Err(e) => log::warn!("nowhere: keystore census append {ns} failed: {e:?} (NWP-20260826-11)"),
    }
}

/// Seed the census from the database at start and rewrite the file as the union of disk and database.
///
/// WHY, when /data is wiped at boot and the append hook sees every creation after that: because without it
/// the file is a CACHE that can silently drift -- a partial write, a truncation, a reap that clears it while
/// the database still holds rows, or a keystore2 restart that leaves the in-memory set empty while the file
/// keeps growing. Rewriting from the database once per boot makes it a derived view that self-heals, for the
/// price of one DISTINCT over keyentry. A census that is quietly wrong is worse than none: it hides a switch
/// that works, and there is no symptom to chase.
pub fn bootstrap(db: &mut KeystoreDB) {
    let mut set: std::collections::HashSet<i64> = match std::fs::read_to_string(CENSUS_PATH) {
        Ok(s) => s.lines().filter_map(|l| l.trim().parse::<i64>().ok()).collect(),
        Err(_) => std::collections::HashSet::new(),
    };
    let from_disk = set.len();
    match db.nowhere_app_namespaces() {
        Ok(rows) => set.extend(rows),
        Err(e) => {
            // The file we already read stays authoritative; a failed scan must not blank the census.
            log::warn!("nowhere: keystore census scan failed: {e:?} (NWP-20260826-11)");
        }
    }
    let mut sorted: Vec<i64> = set.iter().copied().collect();
    sorted.sort_unstable(); // deterministic file: a census that reshuffles is a diff nobody can read
    let mut out = String::with_capacity(sorted.len() * 8);
    for ns in &sorted {
        out.push_str(&format!("{ns}\n"));
    }
    // Rename onto the path so a reader never sees a half-written census.
    let tmp = format!("{CENSUS_PATH}.tmp");
    let wrote = std::fs::write(&tmp, out.as_bytes())
        .and_then(|()| {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o644))
        })
        .and_then(|()| std::fs::rename(&tmp, CENSUS_PATH));
    match wrote {
        Ok(()) => {
            log::info!(
                "nowhere: keystore census {} ns ({from_disk} from disk) (NWP-20260826-11)",
                sorted.len()
            );
            if let Ok(mut m) = census_cell().lock() {
                *m = set;
            }
        }
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            log::warn!("nowhere: keystore census rewrite failed: {e:?} (NWP-20260826-11)");
        }
    }
}
'''
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('[keystore-roam] census module appended')
PY

# --- 9. the census read: which APP namespaces hold a live key -------------------------------------------
python3 - "$DB" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8', newline='').read()
if 'nowhere_app_namespaces' in s:
    sys.exit('database.rs already carries nowhere_app_namespaces')
# Anchor on our OWN import method, which this script controls, rather than on a stock item whose neighbours
# can move between releases.
#
# But anchor on its DOC BLOCK plus the signature, not the bare signature -- exactly as section 3 does, and for
# exactly the reason recorded there. Inserting at the signature alone lands BETWEEN nowhere_import_keys's ///
# block and the function itself: rustc then reads those docs as documenting OUR method and fails the crate's
# deny(missing_docs) on the now-undocumented original. Confirmed the hard way on 2026-08-26 --
#     error: missing documentation for a method
#        --> system/security/keystore2/src/database.rs:2845:5
#            pub fn nowhere_import_keys(...)
# Walk back over the contiguous /// lines so the pair stays intact.
sig = '    pub fn nowhere_import_keys('
assert s.count(sig) == 1, 'no unique anchor for nowhere_app_namespaces'
lines = s[: s.index(sig)].split('\n')
k = len(lines) - 1  # lines[-1] is the empty partial line at the split point, never a /// line
while k > 0 and lines[k - 1].lstrip().startswith('///'):
    k -= 1
anchor = '\n'.join(lines[k:]) + sig
assert s.count(anchor) == 1, 'doc-block anchor is not unique'
NEW = r'''    /// Every APP namespace that currently holds a live key. Backs the census bootstrap -- see
    /// nowhere_roam::bootstrap for why the census file is a derived view and not a cache.
    ///
    /// (Deliberately unstamped with the patch version: keystore-roam.sh greps THIS file for PATCH_VERSION to
    /// decide whether a tree is up to date, so the stamp has to live in the last section that writes here.)
    ///
    /// Deliberately NOT filtered by key_type. The question this answers is "would carrying keys for this app
    /// do anything at all", not "which keys" -- a namespace holding only an attestation key is still an app
    /// that talks to Keystore, and excluding it would hide a switch that works.
    pub fn nowhere_app_namespaces(&mut self) -> Result<Vec<i64>> {
        let _wp = wd::watch("KeystoreDB::nowhere_app_namespaces");
        self.with_transaction(TransactionBehavior::Deferred, |tx| {
            let mut stmt = tx
                .prepare(
                    "SELECT DISTINCT namespace FROM persistent.keyentry
                     WHERE domain = ? AND state = ?;",
                )
                .context(ks_err!("Failed to prepare."))?;
            let mut rows = stmt
                .query(params![Domain::APP.0 as u32, KeyLifeCycle::Live])
                .context(ks_err!("Failed to query."))?;
            let mut out: Vec<i64> = Vec::new();
            db_utils::with_rows_extract_all(&mut rows, |row| {
                out.push(row.get(0).context("Trying to extract namespace.")?);
                Ok(())
            })
            .context(ks_err!("Failed to extract rows."))?;
            Ok(out).no_gc()
        })
        .context(ks_err!())
    }

'''
s = s.replace(anchor, NEW + anchor, 1)
# PROVE the doc block stayed attached rather than trusting the walk-back above. The bare-signature version of
# this anchor silently stole nowhere_import_keys's /// block twice -- once as the bug section 3 already
# records, once again here in 2026-08-26 -- and the only symptom either time was a deny(missing_docs) failure
# 3 minutes into a build. A one-line check at patch time costs nothing and names the problem exactly.
for fn in ('    pub fn nowhere_app_namespaces(', '    pub fn nowhere_import_keys('):
    before = s[: s.index(fn)].rstrip('\n').split('\n')[-1].lstrip()
    assert before.startswith('///'), 'doc block lost from %s -- got %r' % (fn.strip(), before[:60])
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('[keystore-roam] nowhere_app_namespaces added')
PY

# ORDER MATTERS: the globals.rs bootstrap goes in BEFORE the database.rs hooks, because the hooks are the
# last thing this script writes into $DB and they carry PATCH_VERSION. The staleness gate at the top greps
# $DB for that string, so if the stamp landed in an EARLIER section a failure after it would leave a tree
# that reads as fully patched and silently builds without the rest -- the exact trap the gate exists for.
# --- 10. bootstrap the census once per boot --------------------------------------------------------------
# DB_INIT.call_once is keystore2's own "first touch since boot" block: it already holds a KeystoreDB, runs
# exactly once per process, and runs before any key op. Hooking the thread-local constructor WITHOUT the
# call_once would rewrite the file once per binder thread.
python3 - "$KS/src/globals.rs" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8', newline='').read()
if 'nowhere_roam::bootstrap' in s:
    sys.exit('globals.rs already carries the census bootstrap')
a = ('        if n != 0 {\n'
     '            info!("Cleaned up {n} failed entries, indicating keystore crash on key generation");\n'
     '        }\n')
assert s.count(a) == 1, 'DB_INIT anchor is not unique'
s = s.replace(a, a + (
    '        // NWP-20260826-11: seed the app-namespace key census from the database, once per boot.\n'
    '        crate::nowhere_roam::bootstrap(&mut db);\n'), 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('[keystore-roam] census bootstrap hooked')
PY

# --- 11. hook the census onto the two paths that insert a keyentry row -----------------------------------
# create_key_entry_internal is the SINGLE choke point for the stock paths -- store_new_key and
# store_new_certificate are its only callers, and it takes domain + namespace directly. nowhere_import_keys
# (section 5) does its own INSERT and so needs its own call: without it the census would be EMPTY for exactly
# the apps that already opted in, right after a login, and their working switch would disappear.
python3 - "$DB" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8', newline='').read()
if 'nowhere_roam::note_app_key' in s:
    sys.exit('database.rs already carries the census hooks')

# The domain gate ALONE is not unique -- stock rebind_alias carries a byte-identical copy, so anchoring on
# it would have put the census call in the wrong function. Include the signature so the anchor names one site.
a = ('    fn create_key_entry_internal(\n'
     '        tx: &Transaction,\n'
     '        domain: &Domain,\n'
     '        namespace: &i64,\n'
     '        key_type: KeyType,\n'
     '        km_uuid: &Uuid,\n'
     '    ) -> Result<KeyIdGuard> {\n'
     '        match *domain {\n'
     '            Domain::APP | Domain::SELINUX => {}\n'
     '            _ => {\n'
     '                return Err(KsError::sys())\n'
     '                    .context(ks_err!("Domain {:?} must be either App or SELinux.", domain));\n'
     '            }\n'
     '        }\n')
assert s.count(a) == 1, 'create_key_entry_internal anchor is not unique'
s = s.replace(a, a + (
    '        // NWP-20260826-11: count this namespace. Placed after the domain gate so SELINUX namespaces are\n'
    '        // filtered by the stock check rather than a second copy of it, and before the INSERT because the\n'
    '        // census tolerates over-reporting (a rolled-back transaction) far better than under-reporting.\n'
    '        crate::nowhere_roam::note_app_key(*domain, *namespace);\n'), 1)

b = ('    pub fn nowhere_import_keys(&mut self, namespace: i64, keys: &[NowhereKey]) -> Result<usize> {\n'
     '        let _wp = wd::watch("KeystoreDB::nowhere_import_keys");\n')
assert s.count(b) == 1, 'nowhere_import_keys anchor is not unique'
s = s.replace(b, b + (
    '        // NWP-20260826-11: a carried key landing for this namespace counts too. This is the ONLY path that\n'
    '        // populates the census immediately after a login, before the app has run -- which is what keeps an\n'
    '        // already-opted-in app\'s switch on screen instead of vanishing until the user next opens the app.\n'
    '        crate::nowhere_roam::note_app_key(Domain::APP, namespace);\n'), 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('[keystore-roam] census hooks installed')
PY
grep -qF "$MARKER" "$DB" || { echo "[keystore-roam] verification failed" >&2; exit 1; }
grep -qF "nowhere_import_keys" "$DB" || { echo "[keystore-roam] import method missing" >&2; exit 1; }
# The staleness gate at the top greps $DB for PATCH_VERSION, so that string MUST actually be written into the
# patched source. Enforce it HERE rather than trusting the author to keep the two in step: if a later revision
# bumps PATCH_VERSION but forgets to stamp it into a body below, the gate would find the marker, not find the
# version, and refuse to run on a tree it had itself just patched -- bricking every subsequent build with a
# message pointing at the wrong problem. Failing at patch time says exactly what is wrong, once.
grep -qF "$PATCH_VERSION" "$DB" || {
  echo "[keystore-roam] PATCH_VERSION ($PATCH_VERSION) is not stamped into $DB --" >&2
  echo "[keystore-roam] stamp it in a patched body (or align PATCH_VERSION), else the staleness gate self-bricks." >&2
  exit 1
}
grep -qF "try_import_create" "$KS/src/nowhere_roam.rs" || { echo "[keystore-roam] create-import fn missing" >&2; exit 1; }
grep -qF "nowhere_import_on_create" "$KS/src/security_level.rs" || { echo "[keystore-roam] create-path hook missing" >&2; exit 1; }
grep -qF "nowhere-ns-keys" "$KS/src/nowhere_roam.rs" || { echo "[keystore-roam] census module missing" >&2; exit 1; }
grep -qF "nowhere_roam::note_app_key" "$DB" || { echo "[keystore-roam] census hooks missing" >&2; exit 1; }
grep -qF "nowhere_roam::bootstrap" "$KS/src/globals.rs" || { echo "[keystore-roam] census bootstrap missing" >&2; exit 1; }
echo "[keystore-roam] OK -- export + import (get_key_entry miss + generate_key create) + ns census installed"
