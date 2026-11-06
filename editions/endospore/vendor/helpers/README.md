# roamd's app_process helpers (Endospore)

Two small Java programs `nowhere_roamd.sh` runs as uid 0 through `app_process`, because what they do has no
shell command: a binder call into `system_server` on behalf of a roamed user. `Android.bp` builds them from source
into `/system_ext/framework`; `endospore.mk` puts both in `PRODUCT_PACKAGES`. Diaspore ships neither, and roamd
treats a missing jar as "not carried on this image" and says so in `roam.log`.

The design -- record formats, pend lines, the gates (apply marker, retry, fingerprint, backoff) and the trade-offs
-- is [`docs/sync-vpn-carry.md`](../../../../docs/sync-vpn-carry.md). The one to know before changing anything: only a
carried 1 is ever pending, and it lands only over a live 0, so a user who turns sync on before the next seal keeps it;
the price is that an app which switches its own sync on at first run beats a carried explicit 0.

| Jar | Class | Used by | What it does |
| --- | --- | --- | --- |
| `nowhere-vpnao.jar` | `np.VpnAlwaysOn` | the `vpnup` op (#159, `NWP-20261010-15`) | `IVpnManager.setAlwaysOnVpnPackage(user, pkg, lockdown)`, or with `defer` the VPN app's consent `setVpnPackageAuthorization(pkg, user, TYPE_VPN_SERVICE)`, which on Endospore sets always-on and arms the block at the tunnel's first connection (`vpn-lockdown-on-first-connect.sh`) |
| `nowhere-syncroam.jar` | `np.SyncRoam` | `sync_apply` after the account restore, `sync_apply_retry` + `sync_seal_capture` at the seal, gated on a fingerprint (`NWP-20261010-15`) | captures and re-applies master auto-sync and every per-account, per-authority sync switch through `IContentService`, enumerating accounts through `IAccountManager`. Started as root, it drops to the system uid (1000) and relaunches itself: as root ContentService silently refuses every per-account switch (`hasAccountAccess` is false for a uid with no package), and the binder driver keeps the credentials of whoever opened `/dev/binder`, which app_process did before `main()`. A switch whose account or adapter package is absent this session comes back as a `pend` line, which the capture lands the first time the framework can take it |

Run by hand on a device (root):

    CLASSPATH=/system_ext/framework/nowhere-vpnao.jar app_process /system/bin np.VpnAlwaysOn <uid> <pkg|""> <0|1|defer>
    CLASSPATH=/system_ext/framework/nowhere-syncroam.jar app_process /system/bin np.SyncRoam capture <uid> < /dev/null
    CLASSPATH=/system_ext/framework/nowhere-syncroam.jar app_process /system/bin np.SyncRoam apply <uid> < <capture>
    CLASSPATH=/system_ext/framework/nowhere-syncroam.jar app_process /system/bin np.SyncRoam retry <uid> < <fix lines | capture>

⚠ A `SyncRoam capture` prints the user's account NAMES (that is the capture), and so do the `pend` lines after an
`apply`'s answer line. Redirect them to a file; never paste them into a ticket or a log. Everything else either helper
prints is counts, package names, or `ERR <exception class>`.

On an enforcing build roamd's domain `endospore_priv` needs, for these to run at all: `rx_file_perms` on
`zygote_exec` (`app_process64`'s label) and `find` on `vpn_management_service`, `content_service` and `account_service`,
plus the ART runtime grants and dontaudits the platform gives its own in-domain app_process users (incidentd,
tradeinmode). All are in `editions/endospore/vendor/sepolicy/endospore.te`. A missing `find` shows as
`ERR: no vpn_management service` or `ERR no-content-service` in `roam.log`, never as a false success: roamd reads every
result back. The tests are `core/vendor-common/bin/test-roam-helpers-java.sh` (compiled and run against fakes that
refuse a root caller per switch, as the framework does) and `core/vendor-common/bin/test-sync-vpn-roam.sh` (roamd's
half).
