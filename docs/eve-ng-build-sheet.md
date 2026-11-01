# EVE-NG build sheet · lab "AWS Hybrid Healthcare" · Hospital A

## Nodes

| Node | EVE-NG template | CPU / RAM | Notes |
|---|---|---|---|
| hospital-a-fw | Palo Alto (PA-VM) | 2 vCPU / 7 GB | Set **First Eth MAC Address** to `50:00:0a:00:01:00` so rebuilds keep the same MAC |
| hospital-a-client | Linux (any small Ubuntu or Debian image) | 1 vCPU / 1 GB | Plays the clinical system |

## Networks

| Network object | Type | What it is |
|---|---|---|
| Cloud0 | Management (Cloud0) = pnet0 | Your home LAN, 192.168.1.0/24, through the AT&T gateway |
| Cloud9 | Cloud9 = pnet9 | Lab management network 10.99.0.0/24 (gateway 10.99.0.1 on the EVE-NG VM) |
| hospital-a-lan | Bridge | Hospital A's inside network, 10.0.1.0/24, exists only in EVE-NG |

## Links

| From | Interface in EVE-NG | PAN-OS name | To |
|---|---|---|---|
| hospital-a-fw | Mgmt (first interface) | management | Cloud9 |
| hospital-a-fw | eth1 | ethernet1/1 (untrust) | Cloud0, **connect it only after the console bootstrap below** |
| hospital-a-fw | eth2 | ethernet1/2 (trust) | hospital-a-lan |
| hospital-a-client | e0 / eth0 | | hospital-a-lan |

## Palo Alto console bootstrap (before ethernet1/1 is connected)

PA-VM takes several minutes to boot. Wait for the `PA-VM login:` prompt, sign in
as admin / admin and set a new password when asked. Then:

```
configure
set deviceconfig system type static
set deviceconfig system ip-address 10.99.0.11 netmask 255.255.255.0 default-gateway 10.99.0.1
set deviceconfig system dns-setting servers primary 8.8.8.8
set deviceconfig system hostname hospital-a-fw
commit
```

From your laptop: `ping 10.99.0.11`, then browse to https://10.99.0.11. Now connect
eth1 to Cloud0. The full config (from Terraform) turns on DHCP with the hostname.

## Linux client

Ubuntu with netplan, as root:

```
cat > /etc/netplan/60-lab.yaml <<'EOF'
network:
  version: 2
  ethernets:
    ens3:
      addresses: [10.0.1.10/24]
      routes:
        - to: default
          via: 10.0.1.5
      nameservers:
        addresses: [8.8.8.8]
EOF
netplan apply
```

Check the interface name first with `ip link`; it may not be ens3. On any other
Linux, the quick non-persistent version is:

```
ip addr add 10.0.1.10/24 dev eth0
ip route add default via 10.0.1.5
```

## Later: Hospitals B and C

| Node | Template | Mgmt (Cloud9) | Outside (Cloud0) | Inside bridge | Client |
|---|---|---|---|---|---|
| hospital-b-fw | Cisco ASAv | 10.99.0.12 | DHCP | hospital-b-lan 10.0.1.0/24 | 10.0.1.10 |
| hospital-c-fw | FortiGate | 10.99.0.13 | DHCP | hospital-c-lan 172.16.1.0/24 | 172.16.1.10 |

Hospital B deliberately reuses Hospital A's 10.0.1.0/24. That overlap is the point of the NAT design.
