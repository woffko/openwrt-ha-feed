# The network config names no device of its own for the interface (an alias
# of another interface): the name is written as it is, as before
: > /etc/config/network
uci set network.lan=interface
uci set network.lan.device=@wan
