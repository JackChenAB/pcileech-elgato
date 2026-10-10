PCILeech PCIeSquirrel Build
=================
This readme details some customizations that are possible to perform prior to building/flashing the FPGA. For general information please check out the general [readme](readme.md).

Building:
=================
1) Install Xilinx Vivado WebPACK 2023.2 or later.
2) Open Vivado Tcl Shell command prompt.
3) cd into the PCIeSquirrel directory of the cloned or unpacked code (forward slash instead of backslash in path).
4) Run `source vivado_generate_project.tcl -notrace` to generate required project files.
5) Run `source vivado_build.tcl -notrace` to generate Xilinx proprietary IP cores and build bitstream.
6) Finished !!!

Building the project may take a very long time (~1 hour). Sometimes the build will fail if the directory path is too long. If build fails try re-run it while pcileech-fpga is placed in C:\Temp or any other place with short directory path.

The PCIe device will show as Xilinx Ethernet Adapter with Device ID 0x0666 on the target system by default. For instructions how to change the device id and other advanced build properties check out the section below for information.

Customizing PCIe device type, vendor ID and product ID:
=================
Please note that many combinations of device types, vendor IDs and product IDs will make computers not boot, hang and otherwise perform badly when the PCIe device is connected. If that happens please try another combination of values.

Please also note that changing the device and vendor ID is not in itself sufficient to make the device "undetectable" by software looking for malicious DMA devices. There are, more settings that are or aren't, directly modifiable in the PCIe configuration wizard that will alter the device PCIe configuration space.

* Please first generate the initial project as outlined in points 1-4 above.
* Open the project in Vivado by double clicking on `pcileech_squirrel.xpr` in the generated pcileech_squirrel sub-folder.
* In the PROJECT MANAGER - PCIeSquirrel window expand: Design Sources > pcileech_squirrel_top > i_pcileech_pcie_a7.
* Double click on i_pcie_7x_0 shown in the expanded hierarchy from above to open the PCIe core designer GUI.
* Navigate to the IDs tab. Alter ID Initial Values and Class Code to custom values.
* (Optionally navigate to the BARs tab and alter the Bar0 Enabled memory values currently set to 4kB. It is not recommended to disable or go lower than 4kB).
* Click OK to save the changes to the PCIe core. Click Generate in the following dialogue.
* After the PCIe core is rebuilt - exit Vivado and resume building of the project from point 5 in the Building section above. (Optionally one may keep Vivado open and build the project by clicking on Generate Bitstream in the lower left instead).


#### Device Serial Number (DSN):

It may also be a good idea to modify the device serial number (DSN) by editing the line below in the file: `src/pcileech_pcie_cfg_a7.sv`
```verilog
rw[127:64]  <= 64'h0000000101000A35;    // cfg_dsn
```


#### Configuration Space:

It's possible to partly change the PCIe configuration space of the device. This is achieved by altering the value below from `1'b1` to `1'b0` in the file `src/pcileech_fifo.sv` (please see below). The PCIe configuration space is configured by editing the file `ip/pcileech_cfgspace.coe`. Please note that the Xilinx PCIe core will in-part override user-configured values.

in `src/pcileech_fifo.sv` change:
```verilog
rw[203]     <= 1'b1;                        //       CFGTLP ZERO DATA
```
into:
```verilog
rw[203]     <= 1'b0;                        //       CFGTLP ZERO DATA (0 = CUSTOM CONFIGURATION SPACE ENABLED)
```

It's not currently possible to read the custom configuration space from within PCILeech, but on a Linux system it's possible to view it using the `lspci` command. The command line, if the vendor/device id is the default 10ee:0666, is:

Linux lspci command line: `lspci -d 10ee:0666 -xxxx`.



#### BAR PIO Memory Regions:

It's possible to implement a custom BAR PIO memory region, commonly used by devices. Properly implemented BAR PIO memory regions may allow for more complete device emulation.

First, edit the Xilinx PCIe core in Vivado. By default there is one BAR, BAR0 which have 4kB of all-zero read/write memory assigned. This is possible to change.

Secondly, edit the file: `pcileech_tlps128_bar_controller.sv` and follow the instructions in the file to implement custom BAR PIO memory regions.

HD60 Pro (MZ0380) Emulation
=================
This tree emulates an Elgato Game Capture HD60 Pro Rev.3 (YUAN MZ0380) with **no
input signal**: the device enumerates as `12ab:0381`, subsystem `1cfa:0010`,
class `048000`, and speaks the card's real mailbox / BAR / interrupt / DMA
protocol (reverse-engineered register map courtesy of the Wolffyx
hd60pro-linux-driver project, RE_FINDINGS.md milestones cited in the source).

What the FPGA does:
- BAR0 (1 MiB): command mailbox - INIT, GET_BOARD_VERSION (fw 1.11), SET_BUF
  (buffer table capture), SET_VIC/SET_ENC/POST_PROC (accept + store),
  START/STOP streaming, GPIO shadow, bridge register file, MST3367 HDMI
  receiver model (no-signal detect values), EDID RAM (256B, real dump),
  LOAD_FILES scratch.
- BAR5 (4 KiB): SDK property window + INT flag handshake
  (BAR5[0xdc]=1 on event; ack = write 2, BAR0[0x30]=0, BAR0[0x00]=0x400).
- On START_STREAMING: one 0x30a5c0-byte "NO SIGNAL" splash burst (NV12
  720x1080 inside a 1920x1107-based frame, byte geometry per the real card)
  DMA'd into video slot 0 as 512B-payload MemWr TLPs, then EVENT + frame
  token + INTx. One frame per START, exactly like the real card's
  fake-frame path (M38/M39).
- INTx is the interrupt path (matches the real card); MSI stays advertised
  but is never fired.

Build steps are unchanged (points 1-6 above). All four board targets carry the
emulation; the `generate - *.bat` files launch each Vivado project.

Bench expectations:
- Linux: `lspci -nn -d 12ab:0381` shows subsystem `1cfa:0010` and class `0480`.
- Wolffyx hd60pro driver: probe completes the mailbox handshake
  (STATUS stamps), reads fw version 1.11, reports no input signal.
- Elgato 4K Capture Utility (Windows): enumerates the device as an HD60 Pro
  and shows the no-signal state; a stream start delivers one splash frame.

Non-goals (live HDMI input, HDCP, H.264 encoding of live video): those run on
the card's Mozart ARM SoC and are not reproducible on these PCILeech boards.

No-signal splash asset: the generator draws an equivalent "NO SIGNAL" tile.
For the byte-identical vendor splash, extract `NOSG_LOGO_Y` from the card's
tinyvenc5 ELF (offset 0x5B10C, sha256
dfce4efd5139298f544d23473f85a42fb7115a3c5e4ba65b71c070d59883a30b, procedure in
the Wolffyx RE_FINDINGS.md M127b), then regenerate via
`python3 tools/gen_logo_mem.py --verify`.
