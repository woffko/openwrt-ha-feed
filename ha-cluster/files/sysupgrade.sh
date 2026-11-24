# SPDX-License-Identifier: MIT
# ha-cluster, installed as /lib/upgrade/ha-cluster.sh. sysupgrade reads every
# /lib/upgrade/*.sh: /sbin/sysupgrade at its first stage, /lib/upgrade/stage2
# when the image has been checked and the upgrade can no longer be called
# off, before it stops the services, and do_stage2 in the ramdisk. Only the
# second one acts, once: this node's roles go to the peer while keepalived,
# Kea and netifd still run, so that the peer serves at once and the
# sessions of the 'master' uplinks are closed (PADT) before it dials.
# Bounded in time; never stops the upgrade. Defines nothing: the file is
# read by the upgrade's own shell.
case "$0" in
	*/lib/upgrade/stage2)
		if [ ! -e /tmp/.ha-cluster-sysupgrade ] && [ -x /usr/lib/ha-cluster/role ]; then
			: > /tmp/.ha-cluster-sysupgrade
			if command -v timeout >/dev/null 2>&1; then
				timeout 20 /usr/lib/ha-cluster/role sysupgrade </dev/null >/dev/null 2>&1
			else
				/usr/lib/ha-cluster/role sysupgrade </dev/null >/dev/null 2>&1
			fi
		fi
		;;
esac
