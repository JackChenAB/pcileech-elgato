//
// PCILeech FPGA - MZ0380 (Elgato HD60 Pro) emulation package.
//
// Constants reverse-engineered from the real card by the Wolffyx
// hd60pro-linux-driver project (mz0380-reg.h + RE_FINDINGS.md milestones,
// cited per constant). Spec: HD60PRO_DESIGN.md section 2.
// Geometry constants have their single source of truth in
// tools/gen_logo_mem.py; this package repeats them for the FPGA side.
//
// Byte offsets here are BAR0 mailbox byte addresses (MB_*); word indices in
// pcileech_bar_impl_mz0380_mb are offset >> 2.
//

package mz0380_pkg;

    // ---- mailbox doorbell values (M4/M17) --------------------------------
    localparam bit [31:0] MZ_FIRE           = 32'h0000_0800;  // command fire
    localparam bit [31:0] MZ_ACK            = 32'h0000_0400;  // event ack

    // ---- STATUS stamps (M4: success 0xaaaaaaaa, boot 0xdddddddd) ---------
    localparam bit [31:0] MZ_OK_STAMP       = 32'hAAAA_AAAA;
    localparam bit [31:0] MZ_BOOT_STAMP     = 32'hDDDD_DDDD;

    // ---- mailbox register offsets (BAR0) ---------------------------------
    localparam int unsigned MB_DOORBELL     = 'h00;
    localparam int unsigned MB_OPCODE       = 'h04;   // PARAM0
    localparam int unsigned MB_PARAM_BASE   = 'h04;   // PARAM(i) = base + 4*i
    localparam int unsigned MB_STATUS       = 'h2c;   // PARAM10 slot shared; fw uses PARAM1..3 only
    localparam int unsigned MB_EVENT        = 'h30;
    localparam int unsigned MB_EVT_PAYLOAD0 = 'h40;   // frame token word
    localparam int unsigned MB_EVT_PAYLOAD1 = 'h44;
    localparam int unsigned MB_EVT_PAYLOAD2 = 'h48;
    localparam int unsigned MB_EVT_PAYLOAD3 = 'h4c;   // audio token nibbles
    localparam int unsigned MB_ENC_STATUS   = 'h50;   // +N, 16 bytes, host-clears (M40)

    // ---- EVENT bits (M17/M246) -------------------------------------------
    localparam int unsigned MZ_EVENT_CMD_DONE = 11;   // bit11
    localparam int unsigned MZ_EVENT_VIDEO    = 0;    // bit0  video ch0 frame done
    localparam int unsigned MZ_EVENT_AUDIO_LO = 16;   // bits 19:16 audio slots

    // ---- opcodes (reg.h + RE_FINDINGS fw 1.11 dispatcher) ----------------
    localparam bit [7:0] MZ_CMD_INIT              = 8'h01;
    localparam bit [7:0] MZ_CMD_SET_BUF_VID       = 8'h02;  // window 0, raw video
    localparam bit [7:0] MZ_CMD_SET_BUF_AUD       = 8'h03;  // window 3, 4x4KiB audio (M246)
    localparam bit [7:0] MZ_CMD_SET_BUF_H264      = 8'h04;  // window 1, H.264
    localparam bit [7:0] MZ_CMD_SET_BUF_5         = 8'h05;
    localparam bit [7:0] MZ_CMD_START_STREAMING   = 8'h06;
    localparam bit [7:0] MZ_CMD_STOP_STREAMING    = 8'h07;
    localparam bit [7:0] MZ_CMD_SET_BUF_8         = 8'h08;
    localparam bit [7:0] MZ_CMD_GET_BOARD_VERSION = 8'h0a;
    localparam bit [7:0] MZ_CMD_GPIO_READ         = 8'h14;
    localparam bit [7:0] MZ_CMD_GPIO_SET          = 8'h15;
    localparam bit [7:0] MZ_CMD_GPIO_DIR          = 8'h17;
    localparam bit [7:0] MZ_CMD_REG_READ          = 8'h1a;
    localparam bit [7:0] MZ_CMD_REG_WRITE         = 8'h1b;
    localparam bit [7:0] MZ_CMD_I2C_READ_S        = 8'h1e;
    localparam bit [7:0] MZ_CMD_I2C_WRITE_S       = 8'h1f;  // EDID bulk write
    localparam bit [7:0] MZ_CMD_I2C_COMBO         = 8'h20;
    localparam bit [7:0] MZ_CMD_SET_VIC           = 8'h29;
    localparam bit [7:0] MZ_CMD_SET_AIC           = 8'h2a;
    localparam bit [7:0] MZ_CMD_SET_ENC           = 8'h2d;
    localparam bit [7:0] MZ_CMD_SET_ENC_POST      = 8'h2f;
    localparam bit [7:0] MZ_CMD_POST_PROC         = 8'h31;
    localparam bit [7:0] MZ_CMD_SET_BAR           = 8'h51;
    localparam bit [7:0] MZ_CMD_SET_VIDEO_INVIS   = 8'h52;
    localparam bit [7:0] MZ_CMD_SET_LOGO          = 8'h62;
    localparam bit [7:0] MZ_CMD_LOAD_FILES        = 8'h6e;

    // ---- board/fw identity (M4: fw 1.11 -> PARAM1=1 PARAM2=0x0b) ---------
    localparam bit [31:0] MZ_FW_VERSION_MAJOR = 32'h0000_0001;
    localparam bit [31:0] MZ_FW_VERSION_MINOR = 32'h0000_000B;

    // ---- splash / burst geometry (M50; source of truth: gen_logo_mem.py) --
    localparam bit [31:0] MZ_BURST_SIZE    = 32'h0030_A5C0;  // 1920*1107*1.5
    localparam bit [31:0] MZ_FRAME_SIZE    = 32'h0011_CC40;  // 720*1080*1.5
    localparam bit [31:0] MZ_UV_OFFSET     = 32'h000B_DD80;  // frame*2/3
    localparam int unsigned MZ_CANVAS_W    = 720;
    localparam int unsigned MZ_CANVAS_H    = 1080;
    localparam int unsigned MZ_TILE_W      = 320;
    localparam int unsigned MZ_TILE_H      = 240;
    localparam int unsigned MZ_TILE_X      = 200;            // centred
    localparam int unsigned MZ_TILE_Y      = 420;
    localparam int unsigned MZ_STRIDE      = 720;

    // ---- H.264 window geometry (reg.h M246 section) -----------------------
    localparam bit [31:0] MZ_H264_SET_BUF_SIZE = 32'h0009_7F00;

    // ---- engine handshake -------------------------------------------------
    localparam int unsigned MZ_NR_BUFS = 4;   // SET_BUF carries 4 {hi,lo} pairs (M17)

endpackage
