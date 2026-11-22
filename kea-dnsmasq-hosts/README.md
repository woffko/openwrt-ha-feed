# kea-dnsmasq-hosts

The names of ISC Kea's DHCP clients in dnsmasq's DNS.

dnsmasq answers for the names of the clients of its own DHCP leases, and
takes no DDNS updates. Once Kea gives out the leases, the names of its
clients no longer resolve: `laptop.lan` stops working. This package writes
them into a hosts file that dnsmasq reads, `/tmp/hosts/kea-leases`.

It does not depend on ha-cluster and is of use on a single router with Kea
as well as on a cluster.

## How it works

- Kea's run script hook (`libdhcp_run_script.so`, package
  `kea-hook-run-script`) calls `/usr/share/kea/scripts/kea-dnsmasq-hosts`
  for each lease event. The script only notes that leases changed. Kea 3
  takes the scripts of this hook from `/usr/share/kea/scripts` only, and
  refuses its config otherwise.
- The service (`/etc/init.d/kea-dnsmasq-hosts`, `/usr/sbin/kea-dnsmasq-hosts
  run`) rebuilds the hosts file then, at most every five seconds, and every
  `interval` seconds (60) without an event. It reads the lease files of the
  Kea DHCP daemons that run on the node (`"lease-database"` `"name"` of
  their config, else `/var/lib/kea/kea-leases4.csv` and `kea-leases6.csv`,
  with what Kea's lease file cleanup leaves beside them), and has dnsmasq
  read the file again (SIGHUP) when it changed.
- In a Kea high-availability pair the lease files of each node hold the
  leases its partner gave out too: Kea's hook does not run for those, the
  periodic rebuild takes them in, so each node answers for every name, also
  after a failover.
- A lease counts when it is active, has not run out, is an address
  (DHCPv6: IA_NA) and has a host name of letters, digits, hyphens and dots.
  A name with dots is written as it is and by its first label, which
  dnsmasq qualifies with its domain (`expand-hosts`).
- With no Kea DHCP daemon running, the file is removed: dnsmasq, back as the
  DHCP server, answers for its own leases. Stopping or disabling the service
  removes it too.

Static leases of `/etc/config/dhcp` with `dns '1'` resolve as before:
dnsmasq writes their names itself.

## Setting the hook in Kea

In the config of each Kea DHCP daemon whose clients are to resolve, under
`"hooks-libraries"`:

```json
{
	"library": "/usr/lib/kea/hooks/libdhcp_run_script.so",
	"parameters": {
		"name": "/usr/share/kea/scripts/kea-dnsmasq-hosts",
		"sync": false
	}
}
```

luci-app-kea does it with its "Client names in DNS" switch. Restart Kea
afterwards. Kea does not start when the library or the script named there
is missing: remove the entry before removing either package.

## Configuration

`/etc/config/kea-dnsmasq-hosts`:

| Option | Default | Meaning |
|---|---|---|
| `enabled` | `1` | `0` stops the service and removes the hosts file |
| `interval` | `60` | seconds between two rebuilds without an event of Kea's hook |

## Files

```
/etc/config/kea-dnsmasq-hosts          configuration
/etc/init.d/kea-dnsmasq-hosts          procd init script (START=99)
/usr/sbin/kea-dnsmasq-hosts            run | rebuild | clear
/usr/share/kea/scripts/kea-dnsmasq-hosts  the script for Kea's run script hook
/tmp/hosts/kea-leases                  the hosts file dnsmasq reads
```

## License

MIT
