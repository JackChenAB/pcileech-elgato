//
// PCILeech FPGA - MZ0380 (Elgato HD60 Pro) BAR5 CFG / SDK property window.
//
// 4 KiB window: SDK property words the host driver caches, notify pointers,
// and the INT flag handshake register (BAR5[0xdc]: card sets 1 on event;
// host ack = write 2, then BAR0[0x30]=0, BAR0[0x00]=0x400 - M17/FUN_140284380).
// Spec: HD60PRO_DESIGN.md section 2 (BAR5).
//
// Sits in the i_bar5 slot of pcileech_tlps128_bar_controller: 2-cycle read
// latency matching pcileech_bar_impl_zerowrite4k.
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"
import mz0380_pkg::*;

module pcileech_bar_impl_mz0380_cfg (
    input               rst,
    input               clk,
    // standard bar_controller interface (2-cycle read latency)
    input  [31:0]       wr_addr,
    input  [3:0]        wr_be,
    input  [31:0]       wr_data,
    input               wr_valid,
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid,
    // mz0380 interrupt handshake
    input               mz_int_flag_set, // level: engine raises on frame done
    input               mz_int_ack,      // 1-cycle pulse: BAR0 doorbell 0x400
    output bit          mz_int_flag      // state, readable at 0xdc
);

    // ------------------------------------------------------------------
    // word registers (byte addr / 4)
    //   0xdc word 55  : INT_FLAG (0xdc)
    //   0x30 word 12  : NOTIFY_PTR0 (0x30)
    //   0x38 word 14  : NOTIFY_PTR1 (0x38)
    //   0x10 word 16  : PROP_INPUT (0x40)  - reset 2 = HDMI
    //   0x16 word 22  : PROP_RECORD_MODE (0x58)
    //   0x17 word 23  : PROP_BITRATE (0x5c)
    //   0x18 word 24  : PROP_QUALITY (0x60)
    //   0x20 word 32  : PROP_GOP (0x80)
    //   0x21 word 33  : PROP_QP_STEP (0x84)
    //   0x22 word 34  : PROP_B_FRAMES (0x88)
    // ------------------------------------------------------------------
    localparam int unsigned W_INT_FLAG   = 32'hdc >> 2;   // 55
    localparam int unsigned W_NOTIFY0    = 32'h30 >> 2;   // 12
    localparam int unsigned W_NOTIFY1    = 32'h38 >> 2;   // 14
    localparam int unsigned W_INPUT      = 32'h40 >> 2;   // 16
    localparam int unsigned W_RECORD     = 32'h58 >> 2;   // 22
    localparam int unsigned W_BITRATE    = 32'h5c >> 2;   // 23
    localparam int unsigned W_QUALITY    = 32'h60 >> 2;   // 24
    localparam int unsigned W_GOP        = 32'h80 >> 2;   // 32
    localparam int unsigned W_QP_STEP    = 32'h84 >> 2;   // 33
    localparam int unsigned W_B_FRAMES   = 32'h88 >> 2;   // 34

    bit [31:0]  prop [0:55];     // covers up to 0xdc

    // ------------------------------------------------------------------
    // write decode: only the property words accept host writes; the INT
    // flag word accepts "write 2 = clear" (M17 ack sequence) and ignores
    // everything else.
    // ------------------------------------------------------------------
    wire [9:0]  wr_word      = wr_addr[11:2];       // 0..1023 (full 4 KiB)
    wire        wr_known     = wr_known_word(wr_word);   // single known-word list

    always @ ( posedge clk ) begin
        if ( rst ) begin
            prop[W_INT_FLAG] <= 32'h0;
            prop[W_NOTIFY0]  <= 32'h0;
            prop[W_NOTIFY1]  <= 32'h0;
            prop[W_INPUT]    <= 32'h2;      // input mask: HDMI
            prop[W_RECORD]   <= 32'h0;
            prop[W_BITRATE]  <= 32'h0;
            prop[W_QUALITY]  <= 32'h0;
            prop[W_GOP]      <= 32'h0;
            prop[W_QP_STEP]  <= 32'h0;
            prop[W_B_FRAMES] <= 32'h0;
            mz_int_flag      <= 1'b0;
        end
        else begin
            // card raises the flag on frame completion (engine level)
            if ( mz_int_flag_set ) begin
                mz_int_flag      <= 1'b1;
                prop[W_INT_FLAG] <= 32'h1;
            end
            // host clear paths: BAR0 doorbell ack pulse, or BAR5[0xdc] = 2
            if ( mz_int_ack || (wr_valid && (wr_word == W_INT_FLAG) && (wr_data == 32'h2)) ) begin
                mz_int_flag      <= 1'b0;
                prop[W_INT_FLAG] <= 32'h0;
            end

            // all known words are < 64, so the low 6 bits index prop[] without
            // loss; the full-width wr_known guard above rejects 4 KiB aliases.
            if ( wr_valid && wr_known && (wr_word != W_INT_FLAG) ) begin
                prop[wr_word[5:0]] <= wr_data;
            end
        end
    end

    // ------------------------------------------------------------------
    // read path: 2-cycle pipeline; only known words read back, else 0
    // ------------------------------------------------------------------
    bit [87:0]  rd_req_ctx_1;
    bit [31:0]  rd_req_addr_1;
    bit         rd_req_valid_1;
    bit [31:0]  rd_word;

    always @ ( posedge clk ) begin
        if ( rst ) begin
            rd_req_ctx_1    <= 88'h0;
            rd_req_addr_1   <= 32'h0;
            rd_req_valid_1  <= 1'b0;
        end
        else begin
            rd_req_ctx_1    <= rd_req_ctx;
            rd_req_addr_1   <= rd_req_addr;
            rd_req_valid_1  <= rd_req_valid;
            rd_word         <= (wr_known_word(rd_req_addr_1[11:2])) ?
                                prop[rd_req_addr_1[7:2]] : 32'h0;
        end
    end

    always @ ( posedge clk ) begin
        rd_rsp_ctx      <= rd_req_ctx_1;
        rd_rsp_data     <= rd_word;
        rd_rsp_valid    <= rd_req_valid_1;
    end

    function automatic bit wr_known_word( input bit [9:0] w );
        case ( w )
            W_INT_FLAG, W_NOTIFY0, W_NOTIFY1, W_INPUT, W_RECORD,
            W_BITRATE, W_QUALITY, W_GOP, W_QP_STEP, W_B_FRAMES:
                return 1'b1;
            default:
                return 1'b0;
        endcase
    endfunction

endmodule
