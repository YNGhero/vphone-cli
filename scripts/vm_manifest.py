#!/usr/bin/env python3
from __future__ import annotations
"""
vm_manifest.py — Generate VM manifest plist for vphone-cli.

Compatible with security-pcc's VMBundle.Config format.
"""

import argparse
import plistlib
import secrets
import sys
from pathlib import Path


def random_local_mac() -> str:
    # Locally administered, unicast address.  Keep the OUI-ish prefix stable so
    # vphone-generated MACs are easy to recognize while still unique per VM.
    tail = secrets.token_bytes(5)
    return "02:" + ":".join(f"{b:02x}" for b in tail)


def normalize_mac(value: str) -> str:
    text = (value or "").strip().lower().replace("-", ":")
    parts = text.split(":")
    if len(parts) != 6:
        raise ValueError(f"invalid MAC address: {value}")
    nums = []
    for part in parts:
        if len(part) != 2:
            raise ValueError(f"invalid MAC address: {value}")
        nums.append(int(part, 16))
    if nums[0] & 1:
        raise ValueError(f"multicast MAC is not valid for a VM: {value}")
    nums[0] |= 0x02
    nums[0] &= 0xFE
    return ":".join(f"{n:02x}" for n in nums)


def create_manifest(
    vm_dir: Path,
    cpu_count: int,
    memory_mb: int,
    disk_size_gb: int,
    network_mode: str = "nat",
    network_interface: str = "",
    mac_address: str = "",
    platform_fusing: str | None = None,
):
    """
    Create a VM manifest plist file.

    Args:
        vm_dir: Path to VM directory
        cpu_count: Number of CPU cores
        memory_mb: Memory size in MB
        disk_size_gb: Disk size in GB
        network_mode: Network mode (nat, bridged, none)
        network_interface: BSD interface for bridged mode, e.g. en0
        mac_address: Stable virtual NIC MAC address. Empty means generate one.
        platform_fusing: Platform fusing mode (prod/dev) or None for auto-detect
    """
    # Convert to manifest units
    memory_bytes = memory_mb * 1024 * 1024

    # ROM filenames
    rom_file = "AVPBooter.vresearch1.bin"
    sep_rom_file = "AVPSEPBooter.vresearch1.bin"
    mac_address = normalize_mac(mac_address) if mac_address else random_local_mac()

    manifest = {
        "platformType": "vresearch101",
        # "platformFusing": platform_fusing,  # None = auto-detect from host OS
        "machineIdentifier": b"",  # Generated on first boot, then persisted to manifest
        "cpuCount": cpu_count,
        "memorySize": memory_bytes,
        "screenConfig": {
            "width": 1290,
            "height": 2796,
            "pixelsPerInch": 460,
            "scale": 3.0,
        },
        "networkConfig": {
            "mode": network_mode,
            "macAddress": mac_address,
        },
        "diskImage": "Disk.img",
        "nvramStorage": "nvram.bin",
        "romImages": {
            "avpBooter": rom_file,
            "avpSEPBooter": sep_rom_file,
        },
        "sepStorage": "SEPStorage",
    }

    if platform_fusing is not None:
        manifest["platformFusing"] = platform_fusing

    if network_interface:
        manifest["networkConfig"]["bridgedInterface"] = network_interface

    # Write to config.plist
    config_path = vm_dir / "config.plist"
    with open(config_path, "wb") as f:
        plistlib.dump(manifest, f)

    print(f"[5/4] Created VM manifest: {config_path}")
    return config_path


def main():
    parser = argparse.ArgumentParser(
        description="Generate VM manifest plist for vphone-cli"
    )
    parser.add_argument(
        "--vm-dir",
        type=Path,
        default=Path("vm"),
        help="VM directory path (default: vm)",
    )
    parser.add_argument(
        "--cpu",
        type=int,
        default=8,
        help="CPU core count (default: 8)",
    )
    parser.add_argument(
        "--memory",
        type=int,
        default=8192,
        help="Memory size in MB (default: 8192)",
    )
    parser.add_argument(
        "--disk-size",
        type=int,
        default=64,
        help="Disk size in GB (default: 64)",
    )
    parser.add_argument(
        "--network-mode",
        type=str,
        choices=["nat", "bridged", "none"],
        default="nat",
        help="Network mode (default: nat)",
    )
    parser.add_argument(
        "--network-interface",
        type=str,
        default="",
        help="BSD interface for bridged mode, e.g. en0",
    )
    parser.add_argument(
        "--mac-address",
        type=str,
        default="",
        help="Stable virtual NIC MAC address. Empty means generate one.",
    )
    parser.add_argument(
        "--platform-fusing",
        type=str,
        choices=["prod", "dev"],
        default=None,
        help="Platform fusing mode (default: auto-detect from host OS)",
    )

    args = parser.parse_args()

    if not args.vm_dir.exists():
        print(f"Error: VM directory does not exist: {args.vm_dir}", file=sys.stderr)
        sys.exit(1)

    try:
        create_manifest(
            vm_dir=args.vm_dir,
            cpu_count=args.cpu,
            memory_mb=args.memory,
            disk_size_gb=args.disk_size,
            network_mode=args.network_mode,
            network_interface=args.network_interface,
            mac_address=args.mac_address,
            platform_fusing=args.platform_fusing,
        )
    except Exception as e:
        print(f"Error creating manifest: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
