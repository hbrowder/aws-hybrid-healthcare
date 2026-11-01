# AWS Hybrid Healthcare · answer key · Hospital A, basement to AWS

A lab modeling a healthcare SaaS vendor's hybrid network. The vendor side is **Downrange Cloud**,
in AWS; the hospitals are its customers.

Everything needed to stand up the full path and prove it works:
Linux client → Palo Alto in EVE-NG → AT&T gateway → two IPsec tunnels with BGP →
downrange-cloud-tgw → downrange-cloud-app, which reports that it sees the client as 100.64.1.10.

| Folder / file | What it is |
|---|---|
| terraform/ | The whole AWS side (35 resources, including the monitoring in monitoring.tf) **and** the complete Palo Alto config, generated with your live tunnel IPs and keys |
| configs/ | Where the generated firewall config lands (git-ignored: it holds the VPN keys) |
| docs/eve-ng-build-sheet.md | Nodes, links, console bootstrap, Linux client config |
| eve-ng/mgmt-network.sh | One-time setup of the 10.99.0.0/24 management network on the EVE-NG VM |
| lab.py, requirements.txt | The panlab-kit tool: snapshot, load, diff, commit, show, dump. Masks pre-shared keys in its output |
| inventory.json | The hosts lab.py may manage (hospital-a-fw at 10.99.0.11) plus the lab's addresses. No passwords |
| CLAUDE.md | Kit's rules for this folder |
| docs/KIT-PROMPTS.txt | The prompts to give Kit, in order |

## This repo is public

Nothing secret is committed, by design. `.gitignore` keeps out everything that holds keys or personal details:
`terraform.tfvars` (your public IP and email), `*.tfstate*` and `tfplan*` (contain the VPN pre-shared keys),
`.terraform/`, and `configs/` (the generated firewall config, with keys). A gitleaks scan runs on every pull
request to catch anything that slips through. Placeholders like `<EVE_NG_IP>` stand in for home-network details.

## Run order

### Phase 0 · Once only

1. AWS command line ready (lab tab **Setup · AWS command line on Windows**): `aws sts get-caller-identity` works with profile `lab`.
2. EVE-NG VM resized to 2 × 6 vCPUs and 96 GB, and rebooted.
3. Management network: run `eve-ng/mgmt-network.sh` as root on the EVE-NG VM.
   Reserve the EVE-NG VM's home-LAN address (`<EVE_NG_IP>`) in AT&T **Home Network → IP Allocation**. Then on your laptop, from an admin prompt:
   `route -p add 10.99.0.0 mask 255.255.255.0 <EVE_NG_IP>`. Check: `ping 10.99.0.1`.
4. AT&T custom services **IKE** (UDP 500) and **IPsec-NAT-T** (UDP 4500) exist. Already done.
5. Python and lab.py, in PowerShell in this folder:
   ```powershell
   python --version                     # 3.11 or newer
   pip install -r requirements.txt
   ```

### Phase 1 · Build (about an hour the first time)

**Step 1 · AWS (PowerShell, in terraform/), about 10 minutes.** Run it while EVE-NG boots.
```powershell
aws sso login --profile lab
$env:AWS_PROFILE = "lab"
aws sts get-caller-identity
Copy-Item terraform.tfvars.example terraform.tfvars    # then set home_ip
terraform init
terraform validate
terraform plan        # expect 35 to add, 0 to change, 0 to destroy
terraform apply
```

**Step 2 · EVE-NG (you).** Create lab **AWS Hybrid Healthcare** from `docs/eve-ng-build-sheet.md`.
Do the Palo Alto console bootstrap **before** connecting eth1 to Cloud0. Check: browse to https://10.99.0.11.

**Step 3 · Generate the firewall config.**
```powershell
terraform output -raw palo_alto_config | Out-File -Encoding ascii ..\configs\hospital-a-fw.set
```
`-Encoding ascii` matters: Windows PowerShell 5 otherwise writes UTF-16.

**Step 4 · Prove lab.py can reach the firewall, then hand over to Kit.**
```powershell
cd C:\Users\Asus\aws-hybrid-healthcare
$env:PANLAB_USER = "admin"
$env:PANLAB_PASS = Read-Host -AsSecureString | ConvertFrom-SecureString -AsPlainText
python lab.py hosts
python lab.py show hospital-a-fw "show system info"     # hostname hospital-a-fw
claude --dangerously-skip-permissions                     # Kit drives; see docs/KIT-PROMPTS.txt
```
`ConvertFrom-SecureString -AsPlainText` needs PowerShell 7; in Windows PowerShell 5, leave
PANLAB_PASS unset and lab.py prompts for it. Give Kit the prompts in `docs/KIT-PROMPTS.txt`
one at a time. He snapshots, loads the config, shows you the diff, and commits only when you say so.

**Step 5 · AT&T gateway.** Device List shows **hospital-a-fw**. In NAT/Gaming, assign
**IKE** and **IPsec-NAT-T** to it. Hosted Applications lists both.

### Phase 2 · Prove it, bottom up. Stop at the first failure.

| # | Where | Command | Pass when |
|---|---|---|---|
| 1 | Palo Alto | `show interface ethernet1/1` | 192.168.1.x from DHCP |
| 2 | Palo Alto | `show vpn ike-sa` | aws-t1 and aws-t2 established |
| 3 | Palo Alto | `show vpn ipsec-sa` | Both tunnels have SAs |
| 4 | Palo Alto | `show routing protocol bgp summary` | Both peers Established |
| 5 | Palo Alto | `show routing route type bgp` | 10.100.0.0/16 active via tunnel.1; tunnel.2 is standby (no ECMP). Check 10 proves the failover |
| 6 | PowerShell | `aws ec2 describe-vpn-connections --vpn-connection-ids (terraform output -raw vpn_connection_id) --query "VpnConnections[0].VgwTelemetry[].{IP:OutsideIpAddress,Status:Status,Routes:AcceptedRouteCount}" --output table` | Both UP, 1 route each |
| 7 | PowerShell | `aws ec2 search-transit-gateway-routes --transit-gateway-route-table-id (terraform output -raw rt_vendor_id) --filters Name=type,Values=propagated` | 100.64.1.0/24 present |
| 8 | Linux client | `ping -c 3 10.100.11.10` | Replies |
| 9 | Linux client | `curl http://10.100.11.10:8080` | **sees you as 100.64.1.10** |
| 10 | Palo Alto | Disable aws-t1 (`set network ike gateway aws-t1 disabled yes`, commit), rerun 9, re-enable | Still works on tunnel 2 |

Checks 1–5 run through Kit (`python lab.py show hospital-a-fw "<command>"`). Checks 8–9 run on the Linux client's EVE-NG console.

Check 9 is the whole design in one line: the tunnel, BGP, the Transit Gateway
isolation, the return route and the overlapping-address NAT all have to be right.

**If a check fails:**
- 1 → DHCP or the Cloud0 link
- 2 → Local Identification, the pre-shared key, or the port forwards
- 3 → crypto profiles
- 4 → tunnel interface addresses
- 5–7 → the discard route, redistribution, or Transit Gateway propagation
- 8–9 → the vendor route table, the downrange-cloud-app security group, or the NAT rule

### Phase 2b · Watch it from the AWS side (monitoring.tf)

`terraform output` prints four `watch_*` links. Open them while you test:

| View | What it shows | Try this |
|---|---|---|
| **watch_dashboard** (CloudWatch) | Tunnel state, tunnel bytes, latest VPC flows, AWS-side IKE log | Run the curl; watch bytes rise and the flow appear |
| **watch_vpn_tunnels** | Each tunnel UP/DOWN, BGP routes accepted | Compare with `show vpn ike-sa` on the Palo Alto |
| **watch_network_manager** | Drawn topology of the Transit Gateway, VPC and VPN; events timeline | Disable aws-t1 (check 10) and find the event |
| **watch_log_groups** in Logs Insights | Raw VPC, Transit Gateway and IKE logs | `fields @timestamp, srcAddr, dstAddr, dstPort, action \| sort @timestamp desc` |

Email alarms: AWS first sends **"AWS Notification - Subscription Confirmation"** to the `alert_email` in terraform.tfvars.
Click it. You'll then get ALARM when a tunnel is down for 3 minutes and OK when it recovers, so expect an
ALARM/OK pair on every build (tunnels start down until the firewall is loaded).

### Phase 3 · Tear down

```powershell
terraform destroy
```
Shut down the EVE-NG nodes or leave them. Next session, `terraform apply` creates
new tunnel IPs and keys, so regenerate `configs/hospital-a-fw.set` and have Kit load, diff
and commit it again. On a re-load, the `delete` lines at the top fail harmlessly because the objects are in use.

**Cost while up:** about $0.20 an hour (VPN connection, two Transit Gateway
attachments, t3.micro). Destroy at the end of every session.

## Not tested from here

The Terraform was syntax-checked and the Palo Alto template was rendered with sample
values. Neither has run against a real AWS account or PAN-OS, because both are
blocked from where it was written. `terraform validate`, `terraform plan`, and the
commit output on the Palo Alto are the real tests. If a line fails, send the exact error.

## Next: Hospitals B and C

The AWS code extends with one more customer gateway, VPN and route table per hospital.
One real constraint first: all three lab firewalls share **one** AT&T public IP, and
the port forwards for UDP 500 and 4500 can point at only one device. Hospital A gets
them. B and C must start their own tunnels outbound, and you'd set their AWS tunnels
to `startup_action = "add"` so AWS waits for them. That usually works but is less
robust. Prove Hospital A first, then add B to test exactly this.
