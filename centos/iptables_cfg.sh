#!/bin/sh

#
# iptables example configuration script must be run as sudo or root.
#

# Location of iptables binary
IPTABLES=/sbin/iptables

/etc/init.d/iptables start

# Flush all current rules from iptables
#
 $IPTABLES -F
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
/etc/init.d/iptables save
#
# List rules
#
 $IPTABLES -L -v
