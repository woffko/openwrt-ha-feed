# Changelog

All notable changes to this feed are documented in this file. Each entry
is a feed release (git tag `vX.Y.Z`) and lists the package versions it
ships. lease-sync and owsync live in their own repositories: this file
gives their version and links to their changelog.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Feed tags follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html):
the major version changes when an upgrade needs action (configuration
schema change, all nodes upgraded together). Each package keeps its own
version.

## Fork changes (woffko/openwrt-ha-feed) on top of 2.0.0

This fork merges upstream 2.0.0 and carries the changes below. Its
packages are `ha-cluster` 2.0.0-r15, `luci-app-ha-cluster` 2.0.0-r11,
`lease-sync` 1.2.1-r6, `owsync` 1.3.0-r5 and `dnsmasq-ha` 2.93-r4. See
[Notes for this fork](ha-cluster/README.md#notes-for-this-fork) before
upgrading a node.

### ha-cluster
- Sync encryption is fail closed. A sync daemon that has work does not
  start without a valid `encryption_key`, and ha-cluster refuses to
  start; plain mode is the explicit `sync_encryption '0'`, never a
  fallback.
- Generated configs live in `/var/run/ha-cluster`, a directory created
  0700 and checked for its owner; files holding keys or passwords are
  created 0600.
- Package-managed dataplane health checks (`check_type 'dataplane'`):
  carrier, optional LACP membership and interface-bound reachability,
  attached to the VRRP instances a check lists.
- IPv6 BACKUP guard: a BACKUP node drops its Router Advertisements and
  incoming DHCPv6 requests, so that clients neither route through it nor
  get addresses from it. With unicast VRRP, which since 2.0.0 keeps both
  families in one instance, the guard follows that instance. It is
  rebuilt after every start and reload, since keepalived reports no state
  for an instance that a reload keeps or removes.
- A node that is stopped but still part of the cluster keeps the guard
  closed. Before, `ha-cluster stop` removed the rules and restarted
  dnsmasq, which then sent Router Advertisements from the node's own
  address: clients routed through a standby. The rules are removed when
  the node leaves the cluster: HA disabled in the config, the service
  disabled, or the package removed.
- The upgrade script puts the guard handler of the installed release
  back after a sysupgrade that kept `/etc/hotplug.d/keepalived/`.
- `dhcp_backend 'kea'`: ISC Kea as the DHCP server of the cluster
  interfaces. lease-sync does not run, the checks that only its dnsmasq
  side needs are skipped, and the guard leaves DHCPv6 to Kea while it keeps
  guarding Router Advertisements. ha-cluster neither runs nor configures
  Kea: its high availability is set up in Kea. See
  [Kea as the DHCP Server](ha-cluster/README.md#kea-as-the-dhcp-server).
- The device of a logical interface is taken from the network config
  while netifd has not brought the interface up. ha-cluster starts at boot
  right after netifd; when it came first, the logical name (`lan`) went
  into the keepalived config in place of the device (`br-lan`), keepalived
  waited for a device of that name, and the node stayed in FAULT until
  ha-cluster was restarted. A config that names devices was not affected.
- With `dhcp_backend 'kea'`, help for Kea's own high availability:
  - a Kea DHCP daemon is told to read its config again when an interface
    has come up on a device it listens on and the device is not the one
    it was. Kea does not notice that netifd made a device anew (`ifdown`
    and `ifup`, a network restart): it goes on running, calls its sockets
    ready and hears nothing, while its partner still reaches it and does
    not take over;
  - the status reports, for each Kea DHCP daemon, whether it is enabled,
    whether its DHCP sockets are open, and the state of its high
    availability, and the cluster is `DEGRADED` when an enabled daemon is
    stopped, not listening on a device of the cluster, alone
    (`partner-down`) or has ended its HA;
  - warnings at start for a Kea config without the high-availability hook,
    for a `"url"` of that hook without a port, with which the two servers
    never find each other, and for a config without socket retries, with
    which a Kea that starts before its interface is up never listens;
  - a `nodes` call that names the nodes alike on every node and gives
    their addresses, for setting up Kea's HA.
- The cluster's own traffic is let through the firewall by ha-cluster:
  rules named `HA-Cluster-...` in `/etc/config/firewall`, visible in LuCI
  like any rule, for VRRP on the devices of the instances and, from the
  addresses of the nodes, for owsync, lease-sync, the listeners of Kea's
  high availability and ping. Every node writes the same rules, so a
  synced firewall config stays right. `firewall '0'` turns this off, and
  `/etc/init.d/ha-cluster firewall` brings the rules up to date without
  touching a daemon. See [Firewall](ha-cluster/README.md#firewall).
- A warning at start for each entry of a sync group that starts with a
  slash: owsync syncs only the files of `/etc/config` and matches entries
  against their names there, so `/etc/config/apcontroller` or
  `/root/.ssh` sync nothing, silently. An entry under `/etc/config` is
  named with what to write instead. Nothing is changed in the config.
- Link-local IPv6 VIPs are written first in an instance: keepalived
  wants the first IPv6 address to be link-local, and warned when the
  sections came in another order.
- `/etc/init.d/ha-cluster start` and `reload` fail when the start fails
  (a config that does not validate); they returned 0 with no daemon
  running, and LuCI's apply reported success.
- A config of the releases before 2.0 found at a start is migrated then,
  with a warning, as the upgrade does, and the guard handlers in
  `/etc/hotplug.d/keepalived/` are brought in line with the release. The
  upgrade migrates once, at the first boot of the image; files put back
  after it (a restored backup, or the kept settings unpacked again because
  a first-boot script rebooted before the boot ended) left the node with
  no file and no lease sync and the status `HEALTHY`. Until the config is
  migrated the status is `DEGRADED` and lists what it found in
  `earlier_model`.
- `dhcp_backend` switches the DHCPv4 server of the cluster interfaces
  between dnsmasq and Kea, and has a third value, `auto`, the new default:
  Kea once its init script starts kea-dhcp4 and kea-dhcp4 listens on a
  cluster interface, dnsmasq otherwise. On the way to Kea the static leases
  of dnsmasq are imported into Kea first (luci-app-kea 0.11.0), the entries
  left are named in the log and the status, dnsmasq's DHCPv4 is switched off
  in the pools of the cluster interfaces (`dhcpv4 'disabled'`, the old value
  kept in `ha_cluster_dhcpv4`), and Kea is restarted (a Kea started while
  dnsmasq held the DHCP port of the interface could not bind its fallback
  socket); if it does not run and
  listen within ten seconds everything is put back and the status says
  why. With `kea` and `dnsmasq` ha-cluster also turns kea-dhcp4 on or off in
  `/etc/config/kea`. A switch is refused, before anything changes, when Kea
  does not listen on a cluster interface, has no subnet for it, or dnsmasq
  gives out DHCPv6 there. The node keeps the server it runs in
  `/etc/ha-cluster/dhcp-backend`; a node that never switched runs Kea only
  with `dhcp_backend 'kea'`, as before. luci-app-kea's `kea.service` event
  makes a running cluster check its server (`/etc/init.d/ha-cluster
  kea_changed`). Before, `kea` only told ha-cluster that Kea was the server,
  and the pools and Kea were the user's to switch. The status gives
  `dhcp_backend` (the server the node runs), `dhcp_backend_mode`,
  `dhcp_backend_problem` and `kea_import`, and is `DEGRADED` when the pools
  say otherwise than the node's server (another node switched alone, or
  two servers on a cluster interface).
- Whether a Kea DHCP daemon listens on a device is read from its
  `interfaces-config` when the config is plain JSON; a device named only in
  a subnet no longer counts.

### luci-app-ha-cluster
- "Encrypt Sync Traffic" switch on the General page, for the backend's
  `sync_encryption`.
- Dataplane health checks on the Keepalived (Advanced) page.
- The peer address is passed to ping after `--`.
- "DHCP Server" on the General page, for `dhcp_backend`; with Kea the
  Status page lists the Kea DHCP daemons, with what each says about its
  sockets and its high availability.
- "Firewall Rules" on the General page, for `firewall`.
- The help of a sync group's files no longer offers absolute paths,
  which owsync never syncs.
- Removing a VRRP instance on the Advanced VRRP page takes it out of the
  health checks that track it, and is refused while a dataplane check
  tracks nothing else; removing a health check takes it out of the
  instances' Track Scripts. A name left behind failed the backend's
  validation, and the cluster did not start.
- The Status page says when `/etc/config/ha-cluster` is still in the form
  of the releases before 2.0 (`earlier_model` of the status).
- "DHCP Server" on the General page offers Automatic, the default; the
  Status page shows the server the node runs, why a switch was not made,
  and the static leases of dnsmasq the import left for luci-app-kea.

### kea-dnsmasq-hosts (new, 1.0.0-r2)
- The names of Kea's DHCP clients in dnsmasq's DNS, which takes no DDNS
  updates: a service rebuilds `/tmp/hosts/kea-leases` from the lease files
  of the Kea DHCP daemons that run on the node, when Kea's run script hook
  says leases changed (at most every five seconds) and every minute, and
  sends dnsmasq SIGHUP when it changed. In a Kea HA pair each node's lease
  files hold its partner's leases too, so every node answers for every
  name. Needs `kea-hook-run-script`, which OpenWrt's Kea package does not
  build; the hook is set in Kea's config (luci-app-kea's "Client names in
  DNS"). Independent of ha-cluster.

### lease-sync, owsync, dnsmasq-ha
- lease-sync: DHCPv6 leases identified by DUID and IAID, the echo of a
  deletion asked of dnsmasq suppressed, peers checked before a message
  is used.
  A DHCPv6 renewal served by a node after a failover, or after its
  lease-sync restarted, is taken over and sent to the peer; before, it
  was dropped as the echo of a peer's lease, and the lease was lost when
  the other copy ran out.
  No echo is expected after a lease is injected: dnsmasq-ha runs no
  script for it, and waiting for one dropped the next real event for
  that address within ten seconds.
- owsync: connections accepted from the configured peers only, a cap on
  the frame size before the handshake, peer file states validated, and a
  fix for the crash when a tombstone expires.
- dnsmasq-ha: DHCPv6 leases carry the client DUID over ubus; the
  dhcp-script forwards only `NAME=value` lines to hotplug. The log line
  of an injected DHCPv6 lease shows the whole client id; it showed its
  first byte.

### Tests
- `tests/unit`: host-side tests, no container needed.
- `tests/scripts/run-characterization-rootless.sh`: the T24 cases
  without podman or docker, in a bubblewrap sandbox over an unpacked
  OpenWrt rootfs. The expected outputs are the fork's; cases for the
  fork's own behaviour are added.
- T28, the DHCPv6 BACKUP guard scenario.
- `tests/unit/test-kea-dnsmasq-hosts.sh`: the hosts file of kea-dnsmasq-hosts
  from Kea's lease files.

## [2.0.0] - 2026-10-24

Before upgrading from 1.0.x, read
[Upgrading from 1.0.x to 2.0.0](ha-cluster/README.md#upgrading): the
configuration is migrated in place, and all nodes must be upgraded
together, BACKUP nodes first: the upgrade restarts keepalived once.

Builds for OpenWrt 25.12 should use the feed's new `openwrt-25.12`
branch: `master` now follows OpenWrt `main` (see
[Add the Feed](README.md#add-the-feed)).

| Package | 1.0.0 | 2.0.0 |
|---------|-------|-------|
| `ha-cluster` | 1.0.0 | 2.0.0 |
| `luci-app-ha-cluster` | 1.0.0 | 2.0.0 |
| `lease-sync` | 1.0.0 | 1.2.1 ([changelog](https://github.com/pgaufillet/lease-sync/blob/v1.2.1/CHANGELOG.md)) |
| `owsync` | 1.2.0 | 1.3.0 ([changelog](https://github.com/pgaufillet/owsync/blob/v1.3.0/CHANGELOG.md)) |
| `dnsmasq-ha` | 2.90 | 2.93 |

### Platform
- Feed branches: `master` follows OpenWrt `main`, `openwrt-25.12` follows
  OpenWrt 25.12.
- OpenWrt 25.12 and its apk package manager. OpenWrt 24.10 (opkg) is no
  longer supported.
- Docker build environment based on the OpenWrt SDK, for any target and
  stable release, with parallel and incremental builds.
- The feed can be hosted as a signed apk repository (key generation in
  the README).
- `scripts/install-ha-cluster.sh` installs the cluster on a router and
  swaps dnsmasq for dnsmasq-ha once every dependency is in place. It no
  longer installs `kmod-ipt-ipset`.

### dnsmasq-ha
- Updated to dnsmasq 2.93: fixes CVE-2026-2291, CVE-2026-4890,
  CVE-2026-4891, CVE-2026-4892, CVE-2026-4893 and CVE-2026-5172.
- Follows the stock OpenWrt 25.12 dnsmasq package: same `files/` and
  patches, built with the dnsmasq-full default options (nftset, no ipset,
  TFTP).
- ubus lease methods: fixed an out-of-bounds write in the `get_leases`
  MAC formatting, hardened input handling, and `add_lease` rejects an
  `is_temporary` mismatch.

### ha-cluster
Configuration (breaking, migrated on upgrade except the first item):
- VRRP settings move to `vrrp_instance` sections; each VIP names its
  instance, and the VIPs of an instance fail over together. A
  configuration from the 1.0.0 tag, with `vrid` and `priority` on each
  VIP, is not converted: recreate its VIPs after upgrading.
- `service` sections become `sync_group` sections.
- Lease sync has its own global switch, `lease_sync`, instead of the DHCP
  group's `sync_leases`.
- Peer `sync_enabled '0'` becomes `vrrp_only '1'`.
- Removed: the wireless sync group, `sync_method`,
  `lease_sync_persist_interval`.

Behaviour:
- A VIP without an `enabled` option is enabled, as LuCI shows it.
- owsync and lease-sync are optional: each runs only when installed and
  needed. A daemon that is needed but not installed is logged as a
  warning.
- With unicast peers, an IPv6-only instance runs as `<name>` with its own
  VRID (no longer `<name>_v6` with VRID+128); with IPv6 unicast peers and
  IPv4 VIPs only, the instance advertises no address. Unicast VRRP keeps
  one address family per instance.
- A warning when dnsmasq is authoritative while leases or the DHCP
  configuration are synced.
- keepalived is reloaded on a configuration change, dnsmasq is restarted
  only when its overlay changed, and package upgrades keep the boot state.
- The generated `keepalived.conf` is created with mode 0600.

### luci-app-ha-cluster
- Pages follow the new configuration model: VRRP instances, VIPs per
  instance (IPv4 and IPv6), sync groups.
- Status page: role per VRRP instance, the daemons the configuration
  needs, and a retried keepalived dump (the role is no longer shown as
  UNKNOWN after an empty dump).
- Layout for phones, theme fixes, no default values written to the
  configuration, corrected unicast help texts.

### lease-sync package
- The standalone init script passes the security options to the daemon
  and keeps the boot state across upgrades.

### Documentation
- Package links in the README and a dnsmasq-ha README.
- Upgrade notes, attended sysupgrade, DHCP prerequisites, and the known
  limits (one dnsmasq section, unicast derivation).

## [1.0.0] - 2026-03-02

Initial release, for OpenWrt 24.10: `ha-cluster` 1.0.0,
`luci-app-ha-cluster` 1.0.0, `lease-sync` 1.0.0, `owsync` 1.2.0,
`dnsmasq-ha` 2.90.
