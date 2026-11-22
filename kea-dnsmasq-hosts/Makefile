# SPDX-License-Identifier: MIT
# Copyright (c) 2026 woffko

include $(TOPDIR)/rules.mk

PKG_NAME:=kea-dnsmasq-hosts
PKG_VERSION:=1.0.0
PKG_RELEASE:=3

PKG_MAINTAINER:=woffko
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/kea-dnsmasq-hosts
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=IP Addresses and Names
  TITLE:=Names of Kea's DHCP clients in dnsmasq's DNS
  DEPENDS:=+kea-hook-run-script
  PKGARCH:=all
endef

define Package/kea-dnsmasq-hosts/description
  dnsmasq answers for the names of the clients of its own DHCP leases, and
  takes no DDNS updates, so the names of the clients of ISC Kea do not
  resolve. This package writes them into a hosts file of dnsmasq: a small
  service rebuilds /tmp/hosts/kea-leases from the lease files of the Kea
  DHCP servers that run on the node, when Kea's run script hook says that
  leases changed and once a minute, and has dnsmasq read it again.
  The hook is set in Kea's config (luci-app-kea's "Client names in DNS").
endef

define Package/kea-dnsmasq-hosts/conffiles
/etc/config/kea-dnsmasq-hosts
endef

define Build/Compile
	# Nothing to compile - shell scripts only
endef

define Package/kea-dnsmasq-hosts/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/kea-dnsmasq-hosts.config $(1)/etc/config/kea-dnsmasq-hosts
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/kea-dnsmasq-hosts.init $(1)/etc/init.d/kea-dnsmasq-hosts
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/kea-dnsmasq-hosts.sh $(1)/usr/sbin/kea-dnsmasq-hosts
	# Kea 3 runs scripts of its run script hook from this directory only
	$(INSTALL_DIR) $(1)/usr/share/kea/scripts
	$(INSTALL_BIN) ./files/kea-hook.sh $(1)/usr/share/kea/scripts/kea-dnsmasq-hosts
endef

$(eval $(call BuildPackage,kea-dnsmasq-hosts))
