#!/bin/sh

#
# iptables example configuration script
#

/etc/init.d/iptables start

# Flush all current rules from iptables
#
 iptables -F
#
# Set default policies for INPUT, FORWARD and OUTPUT chains
#
 iptables -P INPUT DROP
 iptables -P FORWARD DROP
 iptables -P OUTPUT ACCEPT
#
# Set access for localhost
#
 iptables -A INPUT -i lo -j ACCEPT
#
# Accept packets belonging to established and related connections
#
 iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Accept pings
 iptables -A INPUT -p icmp -j ACCEPT

# Accept tcp packets on destination port 22 (SSH)
 iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Accept tcp and udp packets for destination port 53 (DNS)
# iptables -A INPUT -p tcp --dport 53 -j ACCEPT
# iptables -A INPUT -p udp --dport 53 -j ACCEPT

# Accept tcp packets for destination ports 80 and 443 (HTTP[S])
 iptables -A INPUT -p tcp --dport 80 -j ACCEPT
 iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# Accept tcp packets for destination ports 110 and 995 (POP3[S])
# iptables -A INPUT -p tcp --dport 110 -j ACCEPT
# iptables -A INPUT -p tcp --dport 995 -j ACCEPT

# Accept tcp packets for destination ports 25 and 465 (SMTP[S])
# iptables -A INPUT -p tcp --dport 25 -j ACCEPT
# iptables -A INPUT -p tcp --dport 465 -j ACCEPT

#
# Save settings
#
/etc/init.d/iptables save
#
# List rules
#
 iptables -L -v

