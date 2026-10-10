#!/usr/bin/env python3
"""Patch the PCIe bridge IP identity in a pcie_7x_0.xci to the MZ0380 (HD60
Pro Rev.3) values. Idempotent: running twice changes nothing the second time.

Usage:
  python3 tools/patch_xci.py --xci ip/pcie_7x_0.xci [--dry-run]

Identity (Wolffyx hd60pro-linux-driver mz0380-pci.c PCI table, Rev.3):
  Vendor_ID 12AB, Device_ID 0381, Subsystem_Vendor_ID 1CFA,
  Subsystem_ID 0010, Revision_ID 01, Class 04/80/00.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# key -> (expected current, new)
PATCHES = {
    "Vendor_ID": ("10EE", "12AB"),
    "Device_ID": ("0666", "0381"),
    "Subsystem_Vendor_ID": ("10EE", "1CFA"),
    "Subsystem_ID": ("0007", "0010"),
    "Revision_ID": ("02", "01"),
    "Class_Code_Base": ("02", "04"),
    "Class_Code_Sub": ("00", "80"),
    # Class_Code_Interface stays 00; validated below, not rewritten.
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--xci", required=True, type=Path)
    ap.add_argument("--dry-run", action="store_true",
                    help="print planned changes, never write")
    args = ap.parse_args()

    text = args.xci.read_text(encoding="utf-8")
    orig = text
    changes: list[str] = []
    missing: list[str] = []

    for key, (cur, new) in PATCHES.items():
        # match: "Key": [ { "value": "CUR"  (the user-set entry at top of file)
        pat = re.compile(rf'("{key}":\s*\[\s*\{{\s*"value":\s*")({cur})(")')
        if pat.search(text):
            if cur != new:
                text = pat.sub(rf'\g<1>{new}\g<3>', text)
                changes.append(f"{key}: {cur} -> {new}")
            else:
                changes.append(f"{key}: already {new}")
            continue
        # already patched?
        pat_new = re.compile(rf'("{key}":\s*\[\s*\{{\s*"value":\s*")({new})(")')
        if pat_new.search(text):
            changes.append(f"{key}: already {new}")
            continue
        missing.append(key)

    # interface code must be 00
    if not re.search(r'"Class_Code_Interface":\s*\[\s*\{\s*"value":\s*"00"', text):
        missing.append("Class_Code_Interface (expected 00)")

    if missing:
        print(f"patch_xci: expected values not found for: {', '.join(missing)}", file=sys.stderr)
        print("refusing to patch (file layout unexpected)", file=sys.stderr)
        return 1

    for c in changes:
        print(f"  {c}")

    if args.dry_run:
        print("dry-run: no changes written")
        return 0

    if text == orig:
        print("patch_xci: already patched, no changes")
        return 0

    args.xci.write_text(text, encoding="utf-8")
    print(f"patch_xci: wrote {args.xci}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
