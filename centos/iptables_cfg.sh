#!/bin/sh

#
# iptables example configuration script must be run as sudo or root.
# For IPv6 support see the commented section at the end of the script.
#

# Location of iptables binary
IPTABLES=/sbin/iptables

/sbin/service iptables start

# Flush all current rules from iptables
#
 $IPTABLES -F
 $IPTABLES -X
#
# Set default policies for INPUT, FORWARD and OUTPUT chains
#
 $IPTABLES -P INPUT DROP
 $IPTABLES -P FORWARD DROP
 $IPTABLES -P OUTPUT ACCEPT
#
# Set access for localhost
#
 $IPTABLES -A INPUT -i lo -j ACCEPT
#
# Accept packets belonging to established and related connections
#
 $IPTABLES -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Accept pings
 $IPTABLES -A INPUT -p icmp -m state --state NEW -j ACCEPT

# Accept tcp packets on destination port 22 (SSH)
 $IPTABLES -A INPUT -p tcp --dport 22 -m state --state NEW -j ACCEPT

# Accept tcp and udp packets for destination port 53 (DNS)
# $IPTABLES -A INPUT -p tcp --dport 53 -m state --state NEW -j ACCEPT
# $IPTABLES -A INPUT -p udp --dport 53 -m state --state NEW -j ACCEPT

# Accept tcp packets for destination ports 80 and 443 (HTTP[S])
 $IPTABLES -A INPUT -p tcp --dport 80 -m state --state NEW -j ACCEPT
 $IPTABLES -A INPUT -p tcp --dport 443 -m state --state NEW -j ACCEPT

# Accept tcp packets for destination ports 110 and 995 (POP3[S])
# $IPTABLES -A INPUT -p tcp --dport 110 -m state --state NEW -j ACCEPT
# $IPTABLES -A INPUT -p tcp --dport 995 -m state --state NEW -j ACCEPT

# Accept tcp packets for destination ports 25 and 465 (SMTP[S])
# $IPTABLES -A INPUT -p tcp --dport 25 -m state --state NEW -j ACCEPT
# $IPTABLES -A INPUT -p tcp --dport 465 -m state --state NEW -j ACCEPT

#
# Save settings
#
/sbin/service iptables save
#
# List rules
#
 $IPTABLES -L -v

#
# IPv6 Support - Basically put, IPv6 uses separate tables to IPv4, so you have
# to Have a separate configuration for IPv6.  You can just copy the  above
# configuration or you can get more control by utilizing the massive IPv6 block
# you have to only open up certain ports for certain IPs.  I won't put a lot of
# examples here, you can basically copy them from above and just tweak a bit.
#
#
# Location of ip6tables binary
#IP6TABLES=/sbin/ip6tables
#/sbin/service ip6tables start
#
#
# Flush all current rules from ip6tables
#
# $IP6TABLES -F
# $IP6TABLES -X
#
# Set default policies for INPUT, FORWARD and OUTPUT chains
#
#$IP6TABLES -P INPUT DROP
#$IP6TABLES -P FORWARD DROP
#$IP6TABLES -P OUTPUT ACCEPT
#
# Set access for localhost
#
#$IP6TABLES -A INPUT -i lo -j ACCEPT
#
# Accept packets belonging to established and related connections
#
#$IP6TABLES -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
#
# Accept pings and other icmpv6 packets
# Note: DO NOT remove this line or certain icmpv6 packets that are required
# for IPv6 to work will be blocked!
#$IP6TABLES -A INPUT -p icmpv6 -j ACCEPT
#
# Example rule to accept tcp packets on destination port 22 (SSH)
# -d 1234:abcd::1 is the IPv6 address you want this rule to work for.  You can
# have as many -d's as you want in a single line for multiple IPs or omit them
# alltogether for this rule to work on all IPs.
#$IP6TABLES -A INPUT -p tcp -d 1234:abcd::1 --dport 22 -m state --state NEW -j ACCEPT
#
#
# Save settings
#
#/sbin/service ip6tables save
#
# List rules
#
#$IP6TABLES -L -v
