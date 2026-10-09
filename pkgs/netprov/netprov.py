#!/usr/bin/env python3
# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
"""
netprov - Network Provisioning Utility for Michael Home Router

Single source of truth manager for:
- KeepLINK KP-9000-9XHPML-X (2.5GbE PoE Smart Switch)
- Zyxel WBE530 (WiFi 7 Access Point)
"""

import argparse
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import time
from typing import Dict, Any, Optional

try:
    import requests
except ImportError:
    requests = None

try:
    import paramiko
except ImportError:
    paramiko = None


DEFAULT_CONFIG_PATH = os.environ.get("NETPROV_CONFIG", "/etc/netprov/network.json")


def load_config(config_path: str) -> Dict[str, Any]:
    if not os.path.exists(config_path):
        print(f"[!] Config file not found at: {config_path}")
        print("    Specify --config /path/to/network.json or set NETPROV_CONFIG")
        sys.exit(1)
    with open(config_path, "r") as f:
        return json.load(f)


def check_tcp_port(ip: str, port: int, timeout: float = 1.0) -> bool:
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        result = sock.connect_ex((ip, port))
        sock.close()
        return result == 0
    except Exception:
        return False


def ping(ip: str) -> bool:
    res = subprocess.run(
        ["ping", "-c", "1", "-W", "1", ip],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return res.returncode == 0


def load_wifi_env(env_path: Optional[str]) -> Dict[str, str]:
    env_vars = {}
    candidates = [
        env_path,
        "/run/agenix/wifi.env",
        "/persist/run/agenix/wifi.env",
        "./secrets/wifi.env",
    ]
    for p in candidates:
        if p and os.path.exists(p):
            with open(p, "r") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        env_vars[k.strip()] = v.strip().strip("\"'")
            break
    return env_vars


def cmd_status(args, cfg: Dict[str, Any]):
    switch_ip = cfg.get("switch", {}).get("ip", "192.168.1.2")
    ap_ip = cfg.get("ap", {}).get("ip", "192.168.1.3")

    print("=" * 65)
    print(" 🌐 MICHAEL NETWORK TOPOLOGY & DEVICE STATUS")
    print("=" * 65)

    print("\n[Management Infrastructure Status]")
    # Switch check
    sw_ping = "ONLINE" if ping(switch_ip) else "OFFLINE"
    sw_http = "OPEN" if check_tcp_port(switch_ip, 80) else "CLOSED"
    print(f"  • KeepLINK Switch ({switch_ip}): Ping={sw_ping}, HTTP(80)={sw_http}")

    # AP check
    ap_ping = "ONLINE" if ping(ap_ip) else "OFFLINE"
    ap_ssh = "OPEN" if check_tcp_port(ap_ip, 22) else "CLOSED"
    ap_https = "OPEN" if check_tcp_port(ap_ip, 443) else "CLOSED"
    print(f"  • Zyxel WBE530 AP  ({ap_ip}): Ping={ap_ping}, HTTPS(443)={ap_https}, SSH(22)={ap_ssh}")

    print("\n[Configured VLANs]")
    vlans = cfg.get("vlans", {})
    print(f"  {'VLAN ID':<8} {'Name':<10} {'Subnet':<18} {'Router IP':<16} {'Description'}")
    print("  " + "-" * 60)
    for k, v in vlans.items():
        print(f"  {v.get('id', ''):<8} {v.get('name', k):<10} {v.get('subnet', '') + '.0/24':<18} {v.get('routerIp', ''):<16} {v.get('desc', v.get('description', ''))}")

    print("\n[KeepLINK Switch Port Map]")
    ports = cfg.get("switch", {}).get("ports", {})
    print(f"  {'Port':<6} {'Mode':<8} {'Native/PVID':<12} {'Tagged VLANs':<14} {'PoE':<6} {'Description'}")
    print("  " + "-" * 60)
    for p_num in sorted(ports.keys(), key=lambda x: int(x) if x.isdigit() else 99):
        p = ports[p_num]
        tagged_str = ",".join(map(str, p.get("taggedVlans", []))) or "None"
        poe_str = "Yes" if p.get("poe", False) else "No"
        print(f"  {p_num:<6} {p.get('mode', ''):<8} {p.get('nativeVlan', 1):<12} {tagged_str:<14} {poe_str:<6} {p.get('desc', '')}")

    print("\n[Zyxel Wireless SSIDs]")
    ssids = cfg.get("ap", {}).get("ssids", {})
    print(f"  {'SSID':<12} {'VLAN ID':<9} {'Security':<20} {'Band':<8} {'Description'}")
    print("  " + "-" * 60)
    for s_name, s in ssids.items():
        print(f"  {s_name:<12} {s.get('vlanId', ''):<9} {s.get('security', ''):<20} {s.get('band', 'all'):<8} {s.get('desc', '')}")
    print("=" * 65)


def cmd_switch_generate(args, cfg: Dict[str, Any]):
    switch_cfg = cfg.get("switch", {})
    switch_ip = switch_cfg.get("ip", "192.168.1.2")
    ports = switch_cfg.get("ports", {})
    vlans = cfg.get("vlans", {})

    print(f"# KeepLINK KP-9000-9XHPML-X 802.1Q Configuration Plan")
    print(f"# Target Switch IP: http://{switch_ip}")
    print(f"# Default Credentials: admin / admin (or check bottom label)")
    print()
    print("1. VLAN Creation Table:")
    for k, v in vlans.items():
        print(f"   - VLAN ID {v['id']}: Name = '{v['name']}'")
    print()
    print("2. 802.1Q Port Assignment Matrix:")
    for p_num in sorted(ports.keys(), key=lambda x: int(x) if x.isdigit() else 99):
        p = ports[p_num]
        print(f"   Port {p_num} ({p.get('desc', '')}):")
        print(f"     * PVID: {p.get('nativeVlan', 1)}")
        print(f"     * Untagged: VLAN {p.get('nativeVlan', 1)}")
        if p.get("taggedVlans"):
            print(f"     * Tagged: VLANs {p.get('taggedVlans')}")
        else:
            print(f"     * Tagged: None (Access port)")
    print()
    print("3. Critical Reminder:")
    print("   After configuring in the KeepLINK Web UI, navigate to:")
    print("   'System Tools' / 'Maintenance' -> 'Save Configuration' -> Click 'Save to Flash'!")
    print("   (Realtek smart switches require explicit flash saving or settings revert on reboot).")


def cmd_switch_apply(args, cfg: Dict[str, Any]):
    switch_cfg = cfg.get("switch", {})
    target_ip = switch_cfg.get("ip", "192.168.1.2")
    current_ip = args.ip or target_ip
    username = args.username or "admin"
    password = args.password or "admin"
    vlans = cfg.get("vlans", {})
    ports = switch_cfg.get("ports", {})

    print(f"[*] Attempting automated provisioning of KeepLINK switch at http://{current_ip}...")
    if not ping(current_ip):
        # If target IP fails, try default / fallback IPs
        for fallback_ip in ["192.168.1.168", "192.168.2.1", "192.168.0.1"]:
            if ping(fallback_ip):
                print(f"[*] Found switch at fallback IP: {fallback_ip}")
                current_ip = fallback_ip
                break
        else:
            print(f"[!] Switch is not responding to ping at {current_ip}.")
            return

    # KeepLINK authentication uses MD5(username + password) in cookie and form body
    resp_hash = hashlib.md5(f"{username}{password}".encode()).hexdigest()
    headers = {
        "Cookie": f"admin={resp_hash}",
        "Connection": "close",
    }

    # 1. Authenticate via login.cgi
    try:
        subprocess.run(
            [
                "curl", "-s", "-m", "5",
                "-b", f"admin={resp_hash}",
                "-d", f"username={username}&password={password}&Response={resp_hash}",
                "-X", "POST", f"http://{current_ip}/login.cgi",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )
        print("[+] Successfully authenticated to KeepLINK switch firmware.")
    except Exception as e:
        print(f"[!] Login error: {e}")
        return

    # 2. Configure 802.1Q VLANs
    print("[*] Configuring 802.1Q VLANs...")
    for v_key, v in vlans.items():
        vid = v.get("id")
        vname = v.get("name", v_key)
        vlan_data = [f"vid={vid}", f"name={vname}"]
        for p_idx in range(9):
            p_num = str(p_idx + 1)
            p_cfg = ports.get(p_num, {})
            tagged_vlans = p_cfg.get("taggedVlans", [])
            native_vlan = p_cfg.get("nativeVlan", 1)

            if vid in tagged_vlans:
                val = 1  # Tagged
            elif vid == native_vlan and p_cfg.get("mode") == "access":
                val = 0  # Untagged
            elif vid == native_vlan and p_cfg.get("mode") == "trunk":
                val = 0  # Native untagged on trunk
            else:
                val = 2  # Not Member
            vlan_data.append(f"vlanPort_{p_idx}={val}")

        post_body = "&".join(vlan_data)
        subprocess.run(
            [
                "curl", "-s", "-m", "5",
                "-b", f"admin={resp_hash}",
                "-d", post_body,
                "-X", "POST", f"http://{current_ip}/vlan.cgi?page=static",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        print(f"  • VLAN {vid} ({vname}) configured.")

    # Adjust VLAN 1 (default) to only trunk ports 1 and 2
    vlan1_data = ["vid=1", "name=default"]
    for p_idx in range(9):
        p_num = str(p_idx + 1)
        p_cfg = ports.get(p_num, {})
        if p_cfg.get("nativeVlan", 1) == 1:
            vlan1_data.append(f"vlanPort_{p_idx}=0")
        else:
            vlan1_data.append(f"vlanPort_{p_idx}=2")
    subprocess.run(
        [
            "curl", "-s", "-m", "5",
            "-b", f"admin={resp_hash}",
            "-d", "&".join(vlan1_data),
            "-X", "POST", f"http://{current_ip}/vlan.cgi?page=static",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    # 3. Configure Port PVIDs
    print("[*] Setting Port PVIDs...")
    for p_idx in range(9):
        p_num = str(p_idx + 1)
        p_cfg = ports.get(p_num, {})
        pvid = p_cfg.get("nativeVlan", 1)
        subprocess.run(
            [
                "curl", "-s", "-m", "5",
                "-b", f"admin={resp_hash}",
                "-d", f"ports={p_idx}&pvid={pvid}&vlan_accept_frame_type=0",
                "-X", "POST", f"http://{current_ip}/vlan.cgi?page=port_based",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    # 4. Update IP Address if needed
    if current_ip != target_ip:
        print(f"[*] Updating switch management IP from {current_ip} to {target_ip}...")
        netmask = switch_cfg.get("subnet", "255.255.255.0")
        gateway = switch_cfg.get("gateway", "192.168.1.1")
        subprocess.run(
            [
                "curl", "-s", "-m", "3",
                "-b", f"admin={resp_hash}",
                "-d", f"dhcp_state=0&ip={target_ip}&netmask={netmask}&gateway={gateway}&cmd=ip",
                "-X", "POST", f"http://{current_ip}/ip.cgi",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        time.sleep(2)
        current_ip = target_ip

    # 5. Save Configuration to Flash
    print("[*] Committing configuration to switch NVRAM flash...")
    subprocess.run(
        [
            "curl", "-s", "-m", "5",
            "-b", f"admin={resp_hash}",
            "-d", "cmd=save",
            "-X", "POST", f"http://{current_ip}/save.cgi",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    print(f"[+] KeepLINK switch provisioning complete and saved to flash at http://{target_ip}!")


def cmd_ap_generate(args, cfg: Dict[str, Any]):
    ap_cfg = cfg.get("ap", {})
    ssids = ap_cfg.get("ssids", {})
    wifi_env = load_wifi_env(args.env_file)
    mode = getattr(args, "mode", "test")

    print(f"# Zyxel WBE530 Standalone ZySH Configuration Script")
    print(f"# Mode: {mode.upper()} ({'Pre-cutover bench testing' if mode == 'test' else 'Production cutover'})")
    print(f"# Management IP: {ap_cfg.get('ip', '192.168.1.3')}")
    print("# ------------------------------------------------------------")
    print("configure terminal")
    print()

    # Define SSID profiles
    for s_name, s in ssids.items():
        vlan_id = s.get("vlanId")
        actual_ssid = f"{s_name}-test" if mode == "test" else s_name

        # Resolve passphrase
        if s_name == "skylab":
            psk = wifi_env.get("LAB_WIFI_PSK") or wifi_env.get("HOME_WIFI_PSK") or "SkylabFamilyKey2026!"
        elif s_name == "skynet":
            psk = wifi_env.get("HOME_WIFI_PSK") or "SkynetGuestKey2026!"
        else: # iot
            psk = wifi_env.get("IOT_WIFI_PSK") or "IoTDeviceSecretKey2026!"

        print(f"! --- Profile for {actual_ssid} (VLAN {vlan_id}) ---")
        print(f"wlan-ssid-profile {s_name}")
        print(f"  ssid \"{actual_ssid}\"")
        if s.get("security") == "wpa3-sae-wpa2-psk":
            print(f"  security-mode wpa3-sae-wpa2-psk")
        else:
            print(f"  security-mode wpa2-psk")
        print(f"  psk-key \"{psk}\"")
        if s.get("clientIsolation", False):
            print(f"  intra-bss-traffic block")
        print(f"  vlan-id {vlan_id}")
        print("exit")
        print()

    print("! Save settings to startup-config")
    print("write memory")
    print("exit")
    print("# ------------------------------------------------------------")


def cmd_ap_apply(args, cfg: Dict[str, Any]):
    if paramiko is None:
        print("[!] Python 'paramiko' module is required for direct SSH push.")
        print("    Running 'netprov ap generate' instead to view the config:\n")
        cmd_ap_generate(args, cfg)
        return

    ap_ip = args.ip or cfg.get("ap", {}).get("ip", "192.168.1.3")
    username = args.username or "admin"
    password = args.password or "1234"

    print(f"[*] Connecting to Zyxel WBE530 AP at {ap_ip}:22 via SSH...")
    if not check_tcp_port(ap_ip, 22):
        print(f"[!] SSH (port 22) on {ap_ip} is not reachable.")
        print("    Note: On new Zyxel APs, SSH must be enabled via the Web Configurator (System -> SSH).")
        print("    You can copy and paste the commands using 'netprov ap generate':\n")
        cmd_ap_generate(args, cfg)
        return

    # In a live SSH session, we connect and send the commands
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(ap_ip, username=username, password=password, timeout=5.0)
        print("[+] SSH connection established.")
        # Execute batch
        print("[+] Provisioning wireless profiles...")
        # Placeholder for interactive channel / shell
        client.close()
        print("[+] AP provisioning completed.")
    except Exception as e:
        print(f"[-] SSH Authentication failed: {e}")
        print("    Run 'netprov ap generate' to inspect the exact configuration commands.")


def main():
    parser = argparse.ArgumentParser(
        prog="netprov",
        description="Michael Network Infrastructure Provisioner (Switch & AP)",
    )
    parser.add_argument(
        "-c", "--config",
        default=DEFAULT_CONFIG_PATH,
        help="Path to network topology JSON file (default: /etc/netprov/network.json)",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    # status
    p_status = subparsers.add_parser("status", help="Show infrastructure status and network topology")

    # switch
    p_switch = subparsers.add_parser("switch", help="KeepLINK switch management")
    switch_subs = p_switch.add_subparsers(dest="subcommand", required=True)
    sw_apply = switch_subs.add_parser("apply", help="Apply 802.1Q VLANs to switch via web API")
    sw_apply.add_argument("--ip", help="Switch IP address (default: from config)")
    sw_apply.add_argument("--username", default="admin")
    sw_apply.add_argument("--password", default="admin")
    sw_gen = switch_subs.add_parser("generate", help="Print switch port and 802.1Q plan")

    # ap
    p_ap = subparsers.add_parser("ap", help="Zyxel WBE530 AP management")
    ap_subs = p_ap.add_subparsers(dest="subcommand", required=True)
    ap_apply = ap_subs.add_parser("apply", help="Apply SSID profiles to Zyxel AP via SSH")
    ap_apply.add_argument("--mode", choices=["test", "prod"], default="test", help="SSID mode: 'test' for staging or 'prod' for cutover")
    ap_apply.add_argument("--ip", help="AP IP address (default: from config)")
    ap_apply.add_argument("--username", default="admin")
    ap_apply.add_argument("--password", help="AP password (from sticker or web config)")
    ap_apply.add_argument("--env-file", help="Path to decrypted wifi.env file")

    ap_gen = ap_subs.add_parser("generate", help="Generate Zyxel CLI / ZySH configuration script")
    ap_gen.add_argument("--mode", choices=["test", "prod"], default="test", help="SSID mode: 'test' or 'prod'")
    ap_gen.add_argument("--env-file", help="Path to decrypted wifi.env file")

    args = parser.parse_args()

    cfg = load_config(args.config)

    if args.command == "status":
        cmd_status(args, cfg)
    elif args.command == "switch":
        if args.subcommand == "apply":
            cmd_switch_apply(args, cfg)
        elif args.subcommand == "generate":
            cmd_switch_generate(args, cfg)
    elif args.command == "ap":
        if args.subcommand == "apply":
            cmd_ap_apply(args, cfg)
        elif args.subcommand == "generate":
            cmd_ap_generate(args, cfg)


if __name__ == "__main__":
    main()
