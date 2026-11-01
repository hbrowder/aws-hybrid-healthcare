#!/usr/bin/env python3
"""
lab.py - drive the PAN-OS lab firewalls from Claude Code (or by hand).

Copied from panlab-kit for the AWS Hybrid Healthcare lab. One change: `load`
masks VPN pre-shared keys in what it prints, because the .set files here
contain them.

    python lab.py hosts
    python lab.py show  <host|all> "<op command>"
    python lab.py dump  <host|all>                 -> configs/<host>.set.txt (RUNNING) + .state.txt + .candidate-diff.txt
    python lab.py load  <host> <file.set>          -> loads set commands into the CANDIDATE, no commit
    python lab.py diff  <host>                     -> what is in the candidate vs running
    python lab.py commit <host>
    python lab.py revert <host>                    -> throw the candidate away
    python lab.py snapshot <host|all> <name>       -> save config to <name>.xml on the firewall
    python lab.py restore  <host> <name>           -> load <name>.xml into candidate (then commit)

Credentials: environment variables PANLAB_USER and PANLAB_PASS, or you are prompted.
Hosts and management IPs: inventory.json next to this file.
Requires: pip install netmiko
"""
import json, os, re, sys, time, getpass, datetime, pathlib
from netmiko import ConnectHandler

HERE = pathlib.Path(__file__).resolve().parent
INV  = json.loads((HERE / "inventory.json").read_text())
OUT  = HERE / "configs"; OUT.mkdir(exist_ok=True)

def DEVTYPE(h):
    """netmiko device_type per host; PAN-OS unless inventory.json says otherwise.
    'all' only ever means the PAN-OS boxes - dump/snapshot etc. are PAN-OS only."""
    return h.get("device_type", "paloalto_panos")

def creds():
    u = os.environ.get("PANLAB_USER") or input("lab username: ")
    p = os.environ.get("PANLAB_PASS") or getpass.getpass("lab password: ")
    return u, p

def hosts_for(arg):
    if arg == "all":
        live = [n for n, h in INV["hosts"].items()
                if not h["mgmt"].startswith("FILL") and DEVTYPE(h) == "paloalto_panos"
                and h.get("firewall", True)]
        skipped = [n for n in INV["hosts"] if n not in live]
        if skipped:
            print(f"(skipping {', '.join(skipped)} - no management IP)")
        return live
    if arg not in INV["hosts"]:
        sys.exit(f"unknown host '{arg}'. known: {', '.join(INV['hosts'])}")
    return [arg]

def connect(name, u, p, tries=3):
    """PA-VMs in EVE-NG are slow to answer SSH, and slower still when hit
    several times in a row. Long timeouts, and a pause-then-retry."""
    ip = INV["hosts"][name]["mgmt"]
    dt = DEVTYPE(INV["hosts"][name])
    # per-host credential override, e.g. PANLAB_PANORAMA_USER / PANLAB_PANORAMA_PASS
    tag = re.sub(r"[^A-Z0-9]", "_", name.upper())
    u = os.environ.get(f"PANLAB_{tag}_USER", u)
    p = os.environ.get(f"PANLAB_{tag}_PASS", p)
    if ip.startswith("FILL"):
        sys.exit(f"{name}: management IP not set in inventory.json")
    last = None
    for attempt in range(1, tries + 1):
        try:
            c = ConnectHandler(device_type=dt, host=ip,
                               username=u, password=p, fast_cli=False,
                               conn_timeout=45, banner_timeout=90, auth_timeout=90,
                               read_timeout_override=120)
            if dt == "paloalto_panos":
                c.send_command("set cli pager off")
                c.send_command("set cli scripting-mode on")
            elif dt.startswith("cisco"):
                c.send_command("terminal length 0")
            return c
        except Exception as e:                      # banner EOF, timeout, etc.
            last = e
            print(f"{name}: attempt {attempt}/{tries} failed ({type(e).__name__}); "
                  f"waiting 20 s before retry", flush=True)
            time.sleep(20)
    sys.exit(f"{name}: could not connect after {tries} tries: {last}")

def op(c, cmd, timeout=120):
    return c.send_command(cmd, read_timeout=timeout)

# ------------------------------------------------------------------ commands
def cmd_hosts(_):
    for n, h in INV["hosts"].items():
        print(f"{n:12s} {h['mgmt']:16s} {h.get('role','')}")

def cmd_show(args):
    target, command = args[0], " ".join(args[1:])
    u, p = creds()
    for h in hosts_for(target):
        c = connect(h, u, p)
        print(f"\n===== {h} : {command}\n{op(c, command)}")
        c.disconnect()

STATE_CMDS = [
    "show system info",
    "show interface all",
    "show routing route",
    "show routing protocol bgp summary",
    "show routing protocol bgp peer",
    "show routing protocol bgp loc-rib",
    "show vpn ike-sa",
    "show vpn ipsec-sa",
    "show vpn flow",
    "show running nat-policy",
]

def cmd_dump(args):
    u, p = creds()
    stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H%M")
    for h in hosts_for(args[0]):
        c = connect(h, u, p)
        # RUNNING config (not the candidate) in set format, op mode.
        # Keep only network / zone / nat / security - no admins, no mgmt.
        c.send_command("set cli config-output-format set")
        raw = op(c, "show config running", timeout=240)
        keep = ("set network ", "set zone ", "set rulebase nat ", "set rulebase security ",
                "set vsys vsys1 zone ", "set vsys vsys1 rulebase ", "set vsys vsys1 import ")
        lines = [l for l in raw.splitlines() if l.startswith(keep)]
        lines = [l for l in lines
                 if "pre-shared-key" not in l and "phash" not in l and "snmp" not in l]
        (OUT / f"{h}.set.txt").write_text("### RUNNING config, set format\n" + "\n".join(lines) + "\n")
        # anything pending in the candidate? record it so nobody is surprised
        pend = op(c, "show config diff", timeout=120)
        (OUT / f"{h}.candidate-diff.txt").write_text(pend)
        if "+" in pend or "-" in pend:
            print(f"{h}: !! candidate differs from running - see configs/{h}.candidate-diff.txt", flush=True)
        # live state
        st = [f"### {h}  {stamp}\n"]
        for cmd in STATE_CMDS:
            st.append(f"\n### {cmd}\n{op(c, cmd)}\n")
        (OUT / f"{h}.state.txt").write_text("".join(st))
        c.disconnect()
        print(f"{h}: wrote configs/{h}.set.txt, {h}.state.txt, {h}.candidate-diff.txt", flush=True)
        time.sleep(5)   # let the PA-VM breathe before the next login

def cmd_load(args):
    h, f = args[0], pathlib.Path(args[1])
    lines = [l.strip() for l in f.read_text().splitlines()
             if l.strip() and not l.strip().startswith("#")]
    u, p = creds()
    c = connect(h, u, p)
    out = c.send_config_set(lines, exit_config_mode=True, read_timeout=120)
    c.disconnect()
    # never echo VPN pre-shared keys back to the screen or to Claude Code
    out = re.sub(r"(pre-shared-key key\s+)\S+", r"\1********", out)
    print(out)
    bad = [l for l in out.splitlines() if "Invalid" in l or "Unknown" in l or "error" in l.lower()]
    print("\n---- loaded into CANDIDATE, NOT committed. Run: python lab.py diff", h)
    if bad:
        print("!!!! the firewall rejected some lines:"); print("\n".join(bad))

def cmd_diff(args):
    """candidate vs running - op mode on PAN-OS 11.x"""
    h = args[0]; u, p = creds()
    c = connect(h, u, p)
    print(op(c, "show config diff", timeout=120))
    c.disconnect()

def cmd_commit(args):
    h = args[0]; u, p = creds()
    c = connect(h, u, p)
    print(c.commit(read_timeout=900))  # PA-VM commits in EVE can take 5+ minutes
    c.disconnect()

def cmd_revert(args):
    h = args[0]; u, p = creds()
    c = connect(h, u, p)
    c.config_mode()
    print(c.send_command("revert config", expect_string=r"#"))
    c.exit_config_mode(); c.disconnect()

def cmd_snapshot(args):
    target, name = args[0], args[1]; u, p = creds()
    for h in hosts_for(target):
        c = connect(h, u, p)
        c.config_mode()
        print(f"{h}: {c.send_command(f'save config to {name}.xml', expect_string=r'#')}")
        c.exit_config_mode(); c.disconnect()

def cmd_restore(args):
    h, name = args[0], args[1]; u, p = creds()
    c = connect(h, u, p)
    c.config_mode()
    print(c.send_command(f"load config from {name}.xml", expect_string=r"#", read_timeout=120))
    c.exit_config_mode(); c.disconnect()
    print(f"---- {name}.xml loaded into CANDIDATE. Now: python lab.py commit {h}")

CMDS = {"hosts": cmd_hosts, "show": cmd_show, "dump": cmd_dump, "load": cmd_load,
        "diff": cmd_diff, "commit": cmd_commit, "revert": cmd_revert,
        "snapshot": cmd_snapshot, "restore": cmd_restore}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        print(__doc__); sys.exit(1)
    CMDS[sys.argv[1]](sys.argv[2:])
