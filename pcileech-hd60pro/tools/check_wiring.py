#!/usr/bin/env python3
"""Static wiring checks for the MZ0380 emulation integration.

Populated in Task 7 of docs/superpowers/plans/2026-10-10-hd60pro-behaviour.md.
Verifies: module instantiation port connections, mux 5th input, the
mz_int_req chain, and that every board tcl lists the new sources.
Exits non-zero listing all failures.
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent      # pcileech-hd60pro/
SRC = REPO / "src"

BOARDS = [
    "vivado_generate_project_squirrel.tcl",
    "vivado_generate_project_enigma_x1.tcl",
    "vivado_generate_project_captain_75T.tcl",
    "vivado_generate_project_m2.tcl",
]

NEW_SOURCES = [
    "src/pcileech_mz0380_pkg.sv",
    "src/pcileech_bar_impl_mz0380_mb.sv",
    "src/pcileech_bar_impl_mz0380_cfg.sv",
    "src/pcileech_mz0380_periph.sv",
    "src/pcileech_dma_engine.sv",
    "src/mz0380_logo.mem",
    "src/mz0380_edid.mem",
]


def read(name: str) -> str:
    return (SRC / name).read_text(encoding="utf-8")


def main() -> int:
    failures: list[str] = []

    def check(cond: bool, msg: str) -> None:
        if not cond:
            failures.append(msg)

    # ---- a: mz0380 modules exist and are instantiated by name ----
    for mod in ("pcileech_mz0380_pkg", "pcileech_bar_impl_mz0380_mb",
                "pcileech_bar_impl_mz0380_cfg", "pcileech_mz0380_periph",
                "pcileech_dma_engine"):
        check((SRC / f"{mod}.sv").exists(), f"missing source file {mod}.sv")

    bar = read("pcileech_tlps128_bar_controller.sv")
    tlp = read("pcileech_pcie_tlp_a7.sv")
    a7 = read("pcileech_pcie_a7.sv")
    cfg = read("pcileech_pcie_cfg_a7.sv")

    check("pcileech_bar_impl_mz0380_mb i_bar0" in bar,
          "bar_controller: mb module not instantiated as i_bar0")
    check("pcileech_bar_impl_mz0380_cfg i_bar5" in bar,
          "bar_controller: cfg module not instantiated as i_bar5")
    for port in ("mz_vid_base", "mz_vid_slots", "mz_arm", "mz_int_ack",
                 "mz_frame_done", "mz_frame_token"):
        check(port in bar, f"bar_controller: missing mz port {port}")

    # ---- b: mux 5th input + engine wired ----
    check("tlps_in5" in tlp, "tlp_a7: sink mux has no tlps_in5")
    check("pcileech_dma_engine i_mz_dma" in tlp,
          "tlp_a7: dma engine not instantiated")
    check("tlps_in5" in tlp.split("module pcileech_tlps128_sink_mux1")[1]
          if "module pcileech_tlps128_sink_mux1" in tlp else False,
          "tlp_a7: mux module declaration lacks tlps_in5")

    # ---- c: mz_int_req chain ----
    check("mz_int_req" in tlp, "tlp_a7: mz_int_req not present")
    check("mz_int_req" in a7, "pcie_a7: mz_int_req not routed")
    check("mz_int_req" in cfg, "pcie_cfg_a7: mz_int_req input missing")
    check("0000000101000381" in cfg.lower().replace("_", ""),
          "pcie_cfg_a7: DSN 64'h0000000101000381 not set")

    # ---- d: tcl source lists ----
    for b in BOARDS:
        p = REPO / b
        check(p.exists(), f"missing board tcl {b}")
        if not p.exists():
            continue
        t = p.read_text(encoding="utf-8")
        for s in NEW_SOURCES:
            check(s in t, f"{b}: does not list {s}")

    if failures:
        print(f"check_wiring: FAIL ({len(failures)})")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("check_wiring: OK (modules, mux 5th input, int chain, DSN, tcl lists)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
