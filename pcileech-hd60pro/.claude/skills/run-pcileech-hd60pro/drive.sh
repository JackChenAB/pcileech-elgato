#!/usr/bin/env bash
#
# Build and run the MZ0380 RTL driver testbenches with Verilator.
# Drives the changed submodules through their real interfaces (BAR0 register
# bus, AXIS TLP source) -- no vendor PCIe IP, no FPGA, no Vivado. The full
# board top still needs Vivado + hardware; this covers the behavioural RTL.
#
set -uo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SKILL_DIR/../../../src" && pwd)"
OUT="$(mktemp -d)"
cd "$SRC"                      # $readmemh reads mz0380_logo.mem / mz0380_edid.mem from cwd

build_run () {   # <name> <topmodule> <outsub> <extra-src...>
  local name="$1" top="$2" sub="$3"; shift 3
  echo "== $name: build =="
  if ! verilator --binary --timing -Wno-fatal -I. --top-module "$top" \
        --Mdir "$OUT/$sub" -o "sim_$sub" \
        pcileech_mz0380_pkg.sv "$@" "$SKILL_DIR/tb_$sub.sv" >"$OUT/build_$sub.log" 2>&1; then
    echo "BUILD FAILED ($name):"; tail -25 "$OUT/build_$sub.log"; return 2
  fi
  echo "== $name: run =="
  "$OUT/$sub/sim_$sub" 2>&1 | tee "$OUT/run_$sub.log" | grep -vE '^- .*\$finish'
  grep -q "RESULT: PASS" "$OUT/run_$sub.log"
}

rc=0
build_run "DMA engine" tb_dma_engine dma_engine \
  pcileech_dma_engine.sv || rc=1
build_run "mailbox + periph" tb_mailbox mailbox \
  pcileech_mz0380_periph.sv pcileech_bar_impl_mz0380_mb.sv || rc=1

echo "== summary =="
if [ "$rc" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$rc"
