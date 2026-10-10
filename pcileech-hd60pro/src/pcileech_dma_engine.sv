//
// PCILeech FPGA - MZ0380 no-signal splash DMA engine.
//
// On mailbox START (mz_arm rising) streams the card's "NO SIGNAL" splash
// burst (0x30a5c0 bytes of payload, geometry per tools/gen_logo_mem.py,
// M50/M127b) into video slot 0 as MemWr TLPs, then pulses mz_frame_done,
// sets the frame token, requests INTx, and parks until the next START
// (M38/M39: exactly one frame per stream-on).
//
// TLP TX conventions (reference: pcileech_tlps128_bar_rdengine/wrengine
// in pcileech_tlps128_bar_controller.sv):
//   - tdata dwords are packed LSB-dword-first; WITHIN a dword the byte
//     order on the wire is tdata[7:0] first (little-endian beats).
//   - Header dword values are written into tdata naturally:
//     tdata[31:0] = DW0, [63:32] = DW1, [95:64] = DW2, [127:96] = DW3
//     (4DW header: DW3 = address hi). Data dwords follow from beat 1.
//     The rdengine packs pcie_id as {pcie_id[7:0], pcie_id[15:8]} - the
//     16-bit ID occupies [15:0] of the dword in natural bit order.
//   - has_data is held high for the whole active burst so the sink mux
//     grants tready; a single beat is outstanding at a time (tvalid =
//     beat_presented), retired the clk it is accepted (beat_accept).
//
// Beat layout per MemWr TLP (Max_Payload_Size = 512B, 16B per 128b beat):
//   beat 0            : DW0, DW1, DW2, DW3                (tkeepdw 1111)
//   beats 1..N-1      : 16 data bytes each                (tkeepdw 1111)
//                       the last data beat asserts tlast
//   Both payload sizes are exact multiples of 16B, so there is no partial
//   tail beat:
//   full TLP: N=33 beats (1 hdr + 32 data), 32*16 = 512 bytes, Length=128 dw
//   tail TLP: N=29 beats (1 hdr + 28 data), 28*16 = 448 bytes, Length=112 dw
//   6226 full + 1 tail = 6227 TLPs = 0x30a5c0 bytes exactly.
//
// One frame per START; STOP mid-send aborts at the next TLP boundary.
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"
import mz0380_pkg::*;

module pcileech_dma_engine (
    input               rst,
    input               clk,            // clk_pcie domain
    input  [15:0]       pcie_id,
    IfAXIS128.source    tlps_out,       // 5th input of pcileech_tlps128_sink_mux1
    // buffer table from the mailbox (via bar_controller)
    input  [255:0]      mz_vid_base,    // 4 x {hi,lo} phys, video window (op 0x02)
    input  [2:0]        mz_vid_slots,
    input               mz_arm,         // START level
    input               mz_int_ack,     // BAR0 doorbell 0x400 pulse
    // completion to mailbox
    output bit          mz_frame_done,  // 1-cycle pulse
    output bit [31:0]   mz_frame_token,
    // interrupt request to cfg block (via pcie_a7)
    output bit          mz_int_req      // level; cleared by mz_int_ack
);

    // ------------------------------------------------------------------
    // burst geometry
    // ------------------------------------------------------------------
    localparam int unsigned TLP_FULL   = 6226;                  // full 512B-payload TLPs
    localparam bit [9:0]    DWLEN_FULL = 10'd128;               // 512B data
    localparam bit [9:0]    DWLEN_TAIL = 10'd112;               // 448B data
    localparam bit [5:0]    BEATS_FULL = 6'd33;                 // 1 hdr + 32 data
    localparam bit [5:0]    BEATS_TAIL = 6'd29;                 // 1 hdr + 28 data

    // ------------------------------------------------------------------
    // splash byte generator (matches tools/gen_logo_mem.py exactly)
    // ------------------------------------------------------------------
    (* rom_style = "block" *)
    reg [31:0] tile [0:19199];
    initial $readmemh("mz0380_logo.mem", tile);

    function automatic bit [7:0] splash_byte( input bit [21:0] off );
        bit [21:0] r, c;
        bit [16:0] toff;
        begin
            if ( off >= MZ_FRAME_SIZE )
                splash_byte = 8'hff;                             // junk fill
            else if ( off >= MZ_UV_OFFSET )
                splash_byte = 8'h80;                             // neutral chroma
            else begin
                r = off / MZ_STRIDE;
                c = off % MZ_STRIDE;
                if ( (r >= MZ_TILE_Y) && (r < (MZ_TILE_Y + MZ_TILE_H)) &&
                     (c >= MZ_TILE_X) && (c < (MZ_TILE_X + MZ_TILE_W)) ) begin
                    toff = (17'((r - MZ_TILE_Y) * 22'(MZ_TILE_W) + (c - MZ_TILE_X)));
                    case ( toff[1:0] )                           // .mem words: LE bytes
                        2'd0:    splash_byte = tile[toff[16:2]][7:0];
                        2'd1:    splash_byte = tile[toff[16:2]][15:8];
                        2'd2:    splash_byte = tile[toff[16:2]][23:16];
                        default: splash_byte = tile[toff[16:2]][31:24];
                    endcase
                end
                else
                    splash_byte = 8'h11;                         // background
            end
        end
    endfunction

    // ------------------------------------------------------------------
    // FSM + datapath state
    // ------------------------------------------------------------------
    localparam bit [1:0] S_IDLE = 2'd0, S_SEND = 2'd1, S_DONE = 2'd2;

    bit [1:0]   state;
    bit [12:0]  tlp_cnt;                                     // 0..6226
    bit [5:0]   beat_cnt;                                    // beats emitted in TLP
    bit [31:0]  addr_lo;                                     // TLP byte addr, low 32
    bit [21:0]  byte_idx;                                    // burst offset, next 16B group
    bit [31:0]  frame_cnt;

    // output registers (engine -> mux)
    bit         first_q;
    bit         tlast_q;
    bit [3:0]   tkeepdw_q;
    bit [127:0] tdata_q;
    bit         beat_presented;                              // a beat sits in the regs

    wire        arm_rise  = (state == S_IDLE) && mz_arm && (mz_vid_slots != 3'd0);
    wire        mid_tlp   = (beat_cnt != 6'd0) || beat_presented;  // a TLP is in flight
    wire        burst_active = (state == S_SEND) && (mz_arm || mid_tlp);  // sending, or finishing one after STOP
    wire        last_tlp  = (tlp_cnt == TLP_FULL);
    wire [9:0]  cur_dwlen = last_tlp ? DWLEN_TAIL : DWLEN_FULL;
    wire [5:0]  cur_beats = last_tlp ? BEATS_TAIL : BEATS_FULL;

    // header dwords (natural bit order; see conventions above)
    // DW0: Fmt=011 (4DW hdr+data), Type=00000, TC=0, LD/TH=0, Attr=00, EP/TD=0,
    //      rsvd[13:12]=00, Length[9:0]=cur_dwlen
    wire [31:0] dw0 = { 3'b011, 5'b00000, 3'b000, 1'b0, 1'b0, 1'b0, 2'b00, 1'b0, 1'b0, 2'b00, 2'b00, cur_dwlen };
    wire [31:0] dw1 = { pcie_id, 8'h00, 4'hf, 4'hf };        // ReqID, Tag, BE all-f
    wire [31:0] dw2 = { addr_lo[31:2], 2'b00 };
    wire [31:0] dw3 = mz_vid_base[95:64];                    // slot0 hi

    // ------------------------------------------------------------------
    // output + packet count (pcileech_tlps128_src_fifo shape)
    // ------------------------------------------------------------------
    assign tlps_out.tdata      = tdata_q;
    assign tlps_out.tkeepdw    = tkeepdw_q;
    assign tlps_out.tlast      = tlast_q;
    assign tlps_out.tuser[0]   = first_q;
    assign tlps_out.tuser[8:1] = 8'h0;

    wire        beat_ready     = tlps_out.tready;
    wire        beat_accept    = beat_presented && beat_ready;  // mux takes the beat this clk
    // has_data must be high before the first beat is presented, otherwise the
    // mux never grants tready and the source deadlocks: assert it for the whole
    // active burst. One beat is outstanding at a time (tvalid = beat_presented).
    assign tlps_out.has_data   = burst_active;
    assign tlps_out.tvalid     = beat_presented;

    // ------------------------------------------------------------------
    // main sequential logic
    // ------------------------------------------------------------------
    always @ ( posedge clk ) begin
        if ( rst ) begin
            state          <= S_IDLE;
            tlp_cnt        <= 13'd0;
            beat_cnt       <= 6'd0;
            addr_lo        <= 32'h0;
            byte_idx       <= 22'd0;
            frame_cnt      <= 32'h0;
            first_q        <= 1'b0;
            tlast_q        <= 1'b0;
            tkeepdw_q      <= 4'b0000;
            tdata_q        <= 128'h0;
            beat_presented <= 1'b0;
            mz_frame_done  <= 1'b0;
            mz_frame_token <= 32'h0;
            mz_int_req     <= 1'b0;
        end
        else begin
            mz_frame_done <= 1'b0;                               // default pulse low

            // interrupt handshake: level until host acks via 0x400 doorbell
            if ( mz_int_ack )
                mz_int_req <= 1'b0;

            // ---- FSM ----
            case ( state )
                S_IDLE: begin
                    tlp_cnt        <= 13'd0;
                    beat_cnt       <= 6'd0;
                    byte_idx       <= 22'd0;
                    beat_presented <= 1'b0;                      // never carry a beat into idle
                    tlast_q        <= 1'b0;
                    addr_lo        <= mz_vid_base[31:0];         // slot0 lo
                    if ( arm_rise )
                        state <= S_SEND;
                end

                S_SEND: begin
                    if ( beat_accept && tlast_q ) begin
                        // current TLP has fully drained onto the wire
                        if ( last_tlp ) begin
                            state          <= S_DONE;
                            mz_frame_done  <= 1'b1;
                            frame_cnt      <= frame_cnt + 32'd1;
                            mz_frame_token <= { frame_cnt[28:0], 3'b000 };  // buf idx 0 (M17)
                            mz_int_req     <= 1'b1;
                        end
                        else if ( !mz_arm ) begin
                            // STOP: honour it here, at the TLP boundary, so the
                            // in-flight TLP is never truncated (no completion).
                            state <= S_IDLE;
                        end
                        else begin
                            tlp_cnt  <= tlp_cnt + 13'd1;
                            beat_cnt <= 6'd0;
                            // address advance: 512B per TLP, low-half wrap (M25/M26)
                            addr_lo  <= addr_lo + 32'h200;
                        end
                    end
                    else if ( !mz_arm && !mid_tlp ) begin
                        // STOP before any beat of the next TLP started: idle now
                        state <= S_IDLE;
                    end
                end

                S_DONE: begin
                    if ( !mz_arm )                               // STOP rearms
                        state <= S_IDLE;
                end
                default: begin
                    state <= S_IDLE;
                end
            endcase

            // ---- beat present / retire ----
            // One beat outstanding at a time. Load the next beat when the slot
            // is free or is being accepted this clk (back-to-back). Both TLP
            // payload sizes (512B full, 448B tail) are 16B-aligned, so every
            // data beat is a full 16-byte beat (tkeepdw 1111); only the last
            // data beat of the TLP asserts tlast.
            //   beat 0                : header (DW0..DW3)
            //   beats 1..cur_beats-1  : 16 data bytes, last one sets tlast
            // On STOP (mz_arm low) a TLP already in flight is still driven to
            // completion (burst_active stays set via mid_tlp); only the next
            // TLP is withheld. Once all cur_beats are presented the load guard
            // falls through and the single retire arm frees the slot when the
            // final beat is accepted.
            if ( burst_active && (!beat_presented || beat_accept) && (beat_cnt < cur_beats) ) begin
                if ( beat_cnt == 6'd0 ) begin
                    // header beat
                    tdata_q        <= { dw3, dw2, dw1, dw0 };
                    tkeepdw_q      <= 4'b1111;
                    first_q        <= 1'b1;
                    tlast_q        <= 1'b0;
                    beat_presented <= 1'b1;
                    beat_cnt       <= 6'd1;
                end
                else begin
                    // full data beat: 16 splash bytes; final data beat ends TLP
                    for ( int b = 0; b < 16; b++ )
                        tdata_q[8*b +: 8] <= splash_byte(byte_idx + 22'(b));
                    tkeepdw_q      <= 4'b1111;
                    first_q        <= 1'b0;
                    tlast_q        <= ( beat_cnt == (cur_beats - 6'd1) );
                    beat_presented <= 1'b1;
                    beat_cnt       <= beat_cnt + 6'd1;
                    byte_idx       <= byte_idx + 22'd16;
                end
            end
            else if ( beat_accept ) begin
                // last beat of the TLP taken (or slot idle): free it
                beat_presented <= 1'b0;
            end
        end
    end

endmodule
