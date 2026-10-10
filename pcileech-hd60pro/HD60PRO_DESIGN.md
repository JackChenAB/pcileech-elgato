# HD60 Pro Behaviour Reproduction — Design (Rev.3 subsystem)

**Date:** 2026-10-10
**Repo:** Cvar1984/pcileech-elgato (`pcileech-hd60pro/`, stock PCILeech FPGA 4.14 + obfuscated `pcileech_com_e.v`)
**Target:** all four boards (PCIeSquirrel XC7A35T, Enigma-X1 / Captain 75T XC7A75T, Screamer M2)
**Goal:** the FPGA enumerates and behaves as an **Elgato Game Capture HD60 Pro Rev.3** (YUAN MZ0380) with **no input signal**, speaking the exact mailbox / BAR / interrupt / DMA protocol the Elgato (e60MZ0380.X64.SYS) and YUAN firmware stack uses.

Sources of truth (no donor card, per decision):

- Wolffyx `hd60pro-linux-driver` — RE-derived register map (`src/mz0380-reg.h`), DMA/interrupt behaviour (`src/mz0380-dma.c`, `RE_FINDINGS.md`), no-signal splash generator (`scripts/mz0380-no-signal-generate.py`), EDID (`src/mz0380-edid-hd60pro.txt`).
- Driver-confirmed facts are marked (M##) referencing RE_FINDINGS.md milestone numbers.

---

## 1. PCIe identity (all four boards)

Per-board `pcie_7x_0.xci` edits (4 files, keys under `CONFIG.`):

| Key | Current | New |
|---|---|---|
| Vendor_ID | 10EE | **12AB** |
| Device_ID | 0666 | **0381** |
| Subsystem_Vendor_ID | 10EE | **1CFA** |
| Subsystem_ID | 0007 | **0010** |
| Class_Code_Base / Sub / Interface | 02/00/00 | **04/80/00** |
| Revision_ID | 02 | **01** |

Rev.3 identity per the driver's PCI ID table: `{vendor 0x12ab, device 0x0381, subvendor 0x1cfa, subdevice 0x0010}` (`mz0380-pci.c`). Class 048000 = multimedia video controller, matching `PCI\VEN_12AB&DEV_0381&SUBSYS_00101CFA` hardware IDs.

Additional edits:

- `src/pcileech_pcie_cfg_a7.sv`: DSN dword `rw[127:64]` set to a stable value `64'h0000000101000381` (YUAN-format prefix + device id), documented for later tuning against real-card dumps.
- BARs: **BAR0 = 1 MiB, BAR5 = 4 KiB, others disabled**, 32-bit non-prefetchable (sizes from `MZ0380_BAR_MMIO_SIZE` / `MZ0380_BAR_CFG_SIZE`; the driver hard-fails on smaller BARs).
- Link: stays gen2 x1 (matches real card, which is x1 PCIe 2.0).
- MSI: capability stays enabled (the bridge IP advertises MSI by default); the emulation core drives **INTx** as the working interrupt path, matching the real card (Windows `Interrupt_Handler` is INTx-based; driver comment: "Windows uses INTx").

## 2. BAR0/BAR5 emulation core — `pcileech_bar_impl_mz0380.sv` (new)

One module plugged into `pcileech_tlps128_bar_controller`'s BAR0 port, containing two decoders:

### BAR0 — command mailbox (1 MiB window, low 512 B decoded)

Registers (all 32-bit, from `mz0380-reg.h` Section A):

| Offset | Register | Behaviour |
|---|---|---|
| 0x00 | DOORBELL | write 0x800 = fire command, 0x400 = ack event |
| 0x04 | OPCODE/PARAM0 | last written opcode |
| 0x08 | PARAM1..PARAM10 (0x08..0x2c... see below) | stored as written |
| 0x2c | STATUS | boot stamp `0xdddddddd` at reset; on fire: runs op, then stamps `0xaaaaaaaa` (success) |
| 0x30 | EVENT | event bits (see §4) |
| 0x40-0x4c | EVT_PAYLOAD0..3 | per-channel frame-completion nibbles |
| 0x50+ | ENC_STATUS | per-channel handshake bytes |

Implemented opcodes (FSM on doorbell fire):

| Opcode | Name | Card-side action in emulation |
|---|---|---|
| 0x01 | CMD_INIT | stamp STATUS ok, set EVENT bit11 (CMD_DONE) |
| 0x0a | GET_BOARD_VERSION | PARAM2/PARAM3 ← fw version words (v195-style: `0x000000c3` / `0x00000000`) |
| 0x02/03/04/05/08 | SET_BUF_x | capture up to 4 {phys_hi, phys_lo} pairs + slot count + window id from params |
| 0x29 | SET_VIC | store width/height/fps/input; if w or h = 0, mark no_signal (always, in this emulation) |
| 0x2d / 0x2f | SET_ENC / SET_ENC_PARAMS_POST | store mask + encoder knobs; no functional effect |
| 0x31 | POST_PROC | store preview params; no functional effect |
| 0x06 | START_STREAMING | arm frame-delivery engine (§4) |
| 0x07 | STOP_STREAMING | disarm, clear EVENT video bits |
| 0x2a | SET_AIC_PARAMS | store audio params + on flag |
| 0x1a/0x1b | REG_READ/REG_WRITE | tiny register file: bridge regs 0x10 (IRQ main, read-to-clear), 0x12 (SIGNAL: bit0 = 0), 0x13-0x15 (per-source IRQ, read-to-clear), 0x18/0x19 |
| 0x14/0x15/0x17 | GPIO_READ/SET/DIR | 16-bit GPIO shadow: HPD pin1, EDID mux pin2, RX enable pin3, RX reset pin9 |
| 0x1e/0x1f/0x20 | I2C read/write/bulk | MST3367 model (§3) and EDID RAM behind dev 0xa0 |
| 0x6e | LOAD_FILES | 16-byte r/w against a fixed 16 KiB scratch (PIC_ENC stand-in) |

Unknown opcodes: STATUS stamped ok, no side effects (matches ep.ko dispatcher default behaviour).

### BAR5 — CFG / SDK property window (4 KiB)

- Property words: `0x40` input mask, `0x58` record mode, `0x5c` bitrate, `0x60` quality, `0x80` gop, `0x84` qp step, `0x88` b-frames — plain RW storage (driver reads these back; Windows driver caches them).
- `0x30` / `0x38`: NOTIFY_PTR0/1 — RW storage (host programs BAR0 phys addresses; card ignores in emulation).
- `0xdc`: INT_FLAG — card sets `1` on event (§4); host writes `2` to ack, and the ack sequence (`BAR0[0x30]=0; BAR0[0x00]=0x400`) is honoured by the mailbox FSM.
- All other words: read as zero, writes ignored (safe).

## 3. MST3367 HDMI receiver model + EDID (behind mailbox I2C ops)

The Elgato driver stack probes the receiver through mailbox I2C proxy ops (`0x1a` read / `0x1b` write, dev `0x9c`). The emulation implements a minimal but accurate MST3367:

- **Banked register file**: banks 0-2 live, bank 3 zeros + bank-select echo (matches M44 findings).
- **No-signal state** (this emulation's constant state): `B0_DETECT` (0x55) reads `0x03`, `B0_HPD` (0xb7) follows the HPD GPIO pin (pin 1, active-low per M69), timing counters read as torn/zero (vtot=5, htot=656 class of values, per M67's no-signal observations).
- **Signal-locked state** (optional, triggered by writing EDID + raising HPD): `DETECT` reads `0x5f`, hperiod/vperiod decode to 1080p60, hactive = 1920. Reserved for a later "signal present" mode; not in this deliverable.
- **EDID RAM** behind I2C dev `0xa0`: 256 bytes, defaults to the driver's shipped HD60 Pro EDID (`src/mz0380-edid-hd60pro.txt`), rewritable via the 32-byte-chunk bulk write op `0x1f`.

## 4. Frame-delivery engine — locally generated MemWr TLPs

New module `pcileech_dma_engine.sv`, driven by the mailbox FSM's captured buffer table:

- **Buffer model**: video window 0x02: 4 slots, command-declared YUV422 0x2f7600 B frame in 0x466000 B slots; H.264 window 0x04: 4 slots of 0x97f00 declared / 0x100000 backing; audio window 0x03: 4 slots of 0x1000. The card only latches 32-bit halves per 4 GiB-aligned IOVA (M25/M26), so each slot's {hi, lo} pair is stored as-is.
- **Engine**: on START, DMA-writes the **no-signal splash** into slot 0 of the active window: Y plane 720x1080 filled `0x11` with the embedded 320x240 logo (NOSG_LOGO_Y, sha256 `dfce4efd...` — byte-identical to the card's own asset, extracted in the Wolffyx project), UV plane `0x80`, `0xff` junk fill to the 1920x1107-based burst size `0x30a5c0`, landing in buf0 within ~450 ms of START (M36/M50 timing).
- **TLP generation**: builds 256 B-payload MemWr TLPs (Fmt=010, type=00000, 10 dwords data), header from `pcie_id`, address = slot phys base + burst offset, and injects them via a new 5th input on `pcileech_tlps128_sink_mux1` in `pcileech_pcie_tlp_a7.sv`. Flow control: back-pressured by `tready`, and the engine idles while `cfg_interrupt_rdy` is low to avoid stepping on interrupt TLPs.
- **Completion**: after the burst: EVENT bit `MZ0380_VIDEO_EVENT_BIT` set, `EVT_PAYLOAD0` nibble = buf token, ENC_STATUS[0] = 1 (host must write 0 to ack, per M40), BAR5 INT_FLAG = 1, then fires `cfg_interrupt` (INTx assert/deassert via the existing `pcileech_pcie_cfg_a7` rw bits).
- **Encore behaviour**: after the one-shot splash, engine parks (matches M39: a fresh START yields exactly one more frame). A `poll` mode (re-arm on ENC_STATUS clear) can be enabled later via a rw bit; off by default.
- **Payload BRAM**: the 320x240 logo (76,800 B) lives in block RAM initialised by a generated `.mem`/COE from the same SHA-256-verified asset; the fill/geometry logic generates the rest of the frame. Total BRAM cost ≈ 27 BRAM36, well within the 35T.

## 5. Interrupt path

- Event sources OR into a single EVENT word (BAR0+0x30): bit11 CMD_DONE, bit0 video ch0 (frame completion), bits 16-19 audio slots (per M246 layout).
- INTx via the existing `pcileech_pcie_cfg_a7` interrupt rw bits (`rw[205]` assert, `rw[206]` interrupt), strobed by the delivery engine and by the mailbox FSM on EVENT set.
- Host ack: BAR5[0xdc]=2 → BAR0[0x30]=0 → BAR0[0x00]=0x400 — the FSM treats the 0x400 doorbell as "clear EVENT + deassert INTx".
- MSI stays advertised but never fired (matching the real card's observed behaviour).

## 6. Per-board integration

- New files `src/pcileech_bar_impl_mz0380.sv` (mailbox + CFG + MST3367 + EDID) and `src/pcileech_dma_engine.sv` (TLP burst engine + logo BRAM), shared by all four tops.
- `pcileech_tlps128_bar_controller.sv`: BAR0 port switches `pcileech_bar_impl_zerowrite4k` → `pcileech_bar_impl_mz0380`; BAR5 (currently the loopback example) → the CFG window half of the same module.
- `pcileech_pcie_tlp_a7.sv`: `pcileech_tlps128_sink_mux1` gains a 5th input (`tlps_in5`), wired to the DMA engine; engine instantiated in `pcileech_pcie_a7.sv` next to the TLP block, `pcie_id` and `cfg_interrupt_rdy` routed in.
- Each `vivado_generate_project_*.tcl`: add the two new source files to the file list (4 tcl files). The generate-project .bat files (Vivado 2024.2 path) stay as-is.
- `vivado_build.tcl` unchanged.

## 7. Build + verification

- Here: lint both new modules with iverilog/verilator (structural; no vendors IP), plus a Python sanity check of the generated logo `.mem` against the SHA-256.
- You (Windows, Vivado 2023.2+): `generate - *.bat` → `vivado_build.tcl` → flash each board.
- Acceptance: `lspci -nn -d 12ab:0381` shows `0480` class + subsys `1cfa:0010`; the Wolffyx driver (or Elgato 4K Capture Utility on Windows) probes cleanly: firmware handshake completes, no-signal state is reported, and a START produces one no-signal splash frame delivered through the real mailbox/DMA path.
- Known non-goals (documented in build.md): real HDMI-in, HDCP, H.264 encode of live video — those live on the card's Mozart ARM SoC, not reproducible on the Artix-7 PCILeech boards.

## Risks / open questions

1. **sink_mux1 5th input** touches a shared file in all 4 builds; the mux's 1-cycle-latency assumption must hold for the engine (it will: engine presents a full TLP per cycle with stable handshake).
2. **cfg_interrupt_rdy gating**: if the interrupt path stalls the mux longer than expected, the splash latency (~450 ms budget) has margin; even 1 MB at gen2 x1 saturates in <100 ms.
3. **PARAM1..PARAM10 exact meaning** for SET_BUF variants (which window id, slot counts) comes from RE_FINDINGS.md M17's 12-word command shape: {opcode, channel, stride, 4 x {hi, lo}}. If Elgato's Windows driver deviates (different count), only the parameter unpacker changes, isolated in one FSM state.
4. The EDID default is the Wolffyx dump; byte-exact to that project's hardware, may differ from a retail unit's EDID (Cosmetic; the Windows driver rewrites EDID at init anyway).
