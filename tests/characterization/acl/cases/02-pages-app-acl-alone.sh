# Every call the LuCI pages make, for a user holding the luci-base group
# alone next to the app's own: the app's ACL is enough for its pages, with
# no help from luci-base-network-status, and grants nothing they do not
# call (the last block)
ACL_BASE=luci-base
checks() {
	# status.js, simple.js
	access ubus ha-cluster status
	access ubus ha-cluster generate_key
	# simple.js and keepalived-advanced.js, directly and through LuCI's
	# network module (network.getDevices)
	access ubus network.interface dump
	access ubus luci-rpc getNetworkDevices
	access ubus luci-rpc getBoardJSON
	access ubus luci-rpc getWirelessDevices
	access ubus luci-rpc getHostHints
	# fs.stat, fs.list, fs.read, fs.write and fs.remove
	access ubus file stat
	access ubus file list
	access ubus file read
	access ubus file write
	access ubus file remove
	access uci ha-cluster read
	access uci ha-cluster write
	access uci dhcp read
	access uci network read
	file_call stat /usr/bin/owsync
	file_call stat /usr/sbin/lease-sync
	file_call list /etc/hotplug.d/keepalived
	file_call read /etc/hotplug.d/keepalived/01-ubus
	file_call write /etc/hotplug.d/keepalived/99-char '"data":"#!/bin/sh\n"'
	file_call remove /etc/hotplug.d/keepalived/99-char

	# Not called by any page
	access ubus ha-cluster apply
	access ubus keepalived dump
	access ubus service list
	access uci keepalived read
	access uci owsync read
	access uci lease-sync read
	access uci wireless read
	access uci dhcp write
	file_call write /etc/config/ha-cluster '"data":"x"'
	file_call read /etc/shadow
}
