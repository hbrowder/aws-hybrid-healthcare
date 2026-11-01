#!/usr/bin/env bash
# One-time setup on the EVE-NG VM (run as root): lab management network
# 10.99.0.0/24 on bridge pnet9, routed to your home LAN, with internet access for
# firewall licensing and updates. Safe to run more than once.
#
# Everything is (re)built at every boot by pnet9-mgmt.service, which runs
# /usr/local/sbin/lab-mgmt-up.sh. Nothing depends on /etc/network/interfaces or
# on iptables-persistent: on this EVE-NG neither worked for this job (no pnet9
# bridge by default; the nat table is nft-managed, so iptables-save skipped it).
set -euo pipefail

cat > /usr/local/sbin/lab-mgmt-up.sh <<'SCRIPT'
#!/bin/sh
# Lab management network: pnet9 = 10.99.0.1/24, routed to the home LAN,
# NAT to the internet (not to the home LAN). Re-runnable.
MGMT_IP=10.99.0.1
MGMT_NET=10.99.0.0/24
HOME_NET=192.168.1.0/24
UPLINK=pnet0

ip link show pnet9 >/dev/null 2>&1 || ip link add pnet9 type bridge
ip addr replace ${MGMT_IP}/24 dev pnet9
ip link set pnet9 up
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Own nftables table, rebuilt from scratch each time
nft delete table ip labmgmt 2>/dev/null || true
nft -f - <<EOF
table ip labmgmt {
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "pnet9" accept
    oifname "pnet9" accept
  }
  chain postrouting {
    type nat hook postrouting priority 100; policy accept;
    ip saddr ${MGMT_NET} ip daddr != ${HOME_NET} oifname "${UPLINK}" masquerade
  }
}
EOF

# Belt and braces: if another tool (e.g. Docker) sets the iptables FORWARD policy
# to DROP, an accept in our own table isn't enough, so allow pnet9 there too.
iptables -C FORWARD -i pnet9 -j ACCEPT 2>/dev/null || iptables -I FORWARD -i pnet9 -j ACCEPT 2>/dev/null || true
iptables -C FORWARD -o pnet9 -j ACCEPT 2>/dev/null || iptables -I FORWARD -o pnet9 -j ACCEPT 2>/dev/null || true
exit 0
SCRIPT
chmod 755 /usr/local/sbin/lab-mgmt-up.sh

cat > /etc/systemd/system/pnet9-mgmt.service <<'EOF'
[Unit]
Description=Lab management network: pnet9 10.99.0.1/24, forwarding and NAT
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/lab-mgmt-up.sh

[Install]
WantedBy=multi-user.target
EOF

echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-lab-mgmt.conf
systemctl daemon-reload
systemctl enable pnet9-mgmt.service
systemctl restart pnet9-mgmt.service

echo
ip -4 addr show pnet9 | grep inet
nft list table ip labmgmt
echo "Done. On your laptop (admin prompt), if not already added:"
echo "  route -p add 10.99.0.0 mask 255.255.255.0 $(ip -4 -o addr show pnet0 | awk '{print $4}' | cut -d/ -f1)"
