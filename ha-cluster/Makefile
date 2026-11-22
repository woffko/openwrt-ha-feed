# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>

include $(TOPDIR)/rules.mk

PKG_NAME:=ha-cluster
PKG_VERSION:=2.0.0
PKG_RELEASE:=18

PKG_MAINTAINER:=Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/ha-cluster
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=IP Addresses and Names
  TITLE:=High Availability Cluster Management
  DEPENDS:=+keepalived +nftables-json +ip
  PKGARCH:=all
endef

define Package/ha-cluster/description
  Meta-package for managing high availability clusters on OpenWrt.
  Orchestrates keepalived (VRRP) and owsync (config sync) to provide
  seamless failover for routers.
  For DHCP lease synchronization, also install lease-sync and dnsmasq-ha.
endef

define Package/ha-cluster/conffiles
/etc/config/ha-cluster
/etc/ha-cluster/dhcp-backend
/etc/hotplug.d/keepalived/
/etc/keepalived/scripts/
/etc/keepalived/keys/
/etc/keepalived.user
endef

define Build/Compile
	# Nothing to compile - shell scripts only
endef

define Package/ha-cluster/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/ha-cluster.config $(1)/etc/config/ha-cluster

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/ha-cluster.init $(1)/etc/init.d/ha-cluster

	$(INSTALL_DIR) $(1)/usr/lib/ha-cluster
	$(INSTALL_BIN) ./files/ha-cluster.sh $(1)/usr/lib/ha-cluster/
	$(INSTALL_BIN) ./files/check-dataplane.sh $(1)/usr/lib/ha-cluster/check-dataplane

	# The handler is installed twice. /etc/hotplug.d/keepalived/ is kept
	# across sysupgrade as a whole (see conffiles), so the copy there may be
	# the one of the previous image; the uci-defaults script restores it
	# from the copy under /usr/lib.
	$(INSTALL_BIN) ./files/ipv6-backup-guard.hotplug $(1)/usr/lib/ha-cluster/ipv6-backup-guard
	$(INSTALL_DIR) $(1)/etc/hotplug.d/keepalived
	$(INSTALL_BIN) ./files/ipv6-backup-guard.hotplug $(1)/etc/hotplug.d/keepalived/20-ipv6-backup-guard

	# With Kea as the DHCP server: Kea reads its config again when an
	# interface it listens on has come up
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/kea-reload.hotplug $(1)/etc/hotplug.d/iface/60-ha-cluster-kea

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/ha-cluster.uci-defaults $(1)/etc/uci-defaults/60_ha-cluster-sync-model
	# The same script for the init script, which runs it when the files it
	# changed were put back after the first boot
	$(INSTALL_BIN) ./files/ha-cluster.uci-defaults $(1)/usr/lib/ha-cluster/migrate-config
endef

define Package/ha-cluster/prerm
#!/bin/sh
# Disabled first: the stop of a service that still starts at boot keeps the
# IPv6 BACKUP guard closed, and nothing would open it once the package is gone
if [ -z "$${IPKG_INSTROOT}" ]; then
	/etc/init.d/ha-cluster disable >/dev/null 2>&1
	/etc/init.d/ha-cluster stop >/dev/null 2>&1
fi
exit 0
endef

define Package/ha-cluster/postinst
#!/bin/sh
rm -f "$${IPKG_INSTROOT}/etc/hotplug.d/keepalived/20-dhcpv6-backup-guard"
rm -f "$${IPKG_INSTROOT}/etc/hotplug.d/keepalived/21-RA-backup-guard"
exit 0
endef

$(eval $(call BuildPackage,ha-cluster))
